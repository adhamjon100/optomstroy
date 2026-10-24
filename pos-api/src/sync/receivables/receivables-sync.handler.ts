import type pg from 'pg';
import { isOnecError } from '../../integrations/onec/onec-error.js';
import type { OnecGateway } from '../../integrations/onec/onec-gateway.js';
import type { SyncEntityHandler, SyncHandlerResult, SyncRunContext } from '../../jobs/sync/sync-handler.js';
import { SyncRunError } from '../../jobs/sync/sync-handler.js';
import { writeSyncError } from '../../jobs/sync-errors.writer.js';
import { OnecReceivablesFormatError, parseOnecReceivables } from './onec-receivables.parser.js';
import { writeReceivablesSnapshotTx } from './receivables-snapshot.writer.js';

export interface ReceivablesSyncOptions {
  /** Таймаут одного запроса долга клиента, мс (по умолчанию 15 000 — фоновый прогон, не касса). */
  readonly timeoutMs?: number;
  /** Параллельных запросов к 1С (по умолчанию 2; ≤ `ONEC_MAX_CONCURRENCY`). */
  readonly concurrency?: number;
  /** Окно «активных клиентов», мес. (05 SYNC-016: «с заказами/долгом за 12 мес»). */
  readonly activeMonths?: number;
  /** Вариант C-2 (`ONEC_INBOUND_ENABLED=true`): снимки приходят входящим обменом — прогон не обращается к 1С. */
  readonly inboundMode?: boolean;
}

interface Target {
  readonly id: string;
  readonly onec_ref: string;
}

/**
 * Прогон `sync.receivables` (05 SYNC-016, D-29: каждые 30 мин; в режиме расширения — опрос среза, SYNC-011):
 * снимок долга по активным клиентам 1С — карточка не помечена на удаление и (есть отсрочка, есть снимок, заказы POS
 * или реализации 1С за `activeMonths` мес.). По каждому клиенту — `GET /pos/v1/customers/{ref}/receivables`, запись
 * снимка целиком в своей транзакции (`writeReceivablesSnapshot`). Ошибка по клиенту не обнуляет его снимок —
 * остаётся прежний с прежним `onec_snapshot_at` (AC-SYNC-016), строка `sync_errors`, прогон `partial`; 1С
 * недоступна для всех клиентов — прогон `failed` (`ONEC_UNAVAILABLE`). Клиента нет в 1С (404) — пропуск.
 */
export class ReceivablesSyncHandler implements SyncEntityHandler {
  constructor(
    private readonly pool: pg.Pool,
    private readonly gateway: OnecGateway,
    private readonly opts: ReceivablesSyncOptions = {},
  ) {}

  async run(ctx: SyncRunContext): Promise<SyncHandlerResult> {
    if (this.opts.inboundMode) {
      ctx.log.info({ entity: ctx.entity }, 'sync.receivables: вариант C-2 — снимки приходят входящим обменом');
      return { implemented: false, counts: {} };
    }
    const months = this.opts.activeMonths ?? 12;
    const targets = (
      await this.pool.query<Target>(
        `SELECT c.id, c.onec_ref FROM customers c
          WHERE c.onec_ref IS NOT NULL AND NOT c.deletion_mark AND c.deleted_at IS NULL AND NOT c.is_retail_default
            AND (c.credit_allowed
                 OR EXISTS (SELECT 1 FROM receivables r WHERE r.customer_id = c.id)
                 OR EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id
                              AND o.created_at >= now() - make_interval(months => $1))
                 OR EXISTS (SELECT 1 FROM shipments s WHERE s.customer_id = c.id
                              AND s.onec_date >= now() - make_interval(months => $1)))
          ORDER BY c.id`,
        [months],
      )
    ).rows;
    const counts = { fetched: 0, updated: 0, skipped: 0, notInOnec: 0, errors: 0, unavailable: 0 };
    let next = 0;
    const worker = async (): Promise<void> => {
      for (;;) {
        const t = targets[next++];
        if (!t) return;
        await this.one(ctx, t, counts);
        if ((counts.fetched + counts.errors) % 50 === 0) await ctx.touch(counts);
      }
    };
    const n = Math.max(1, Math.min(this.opts.concurrency ?? 2, targets.length || 1));
    await Promise.all(Array.from({ length: n }, () => worker()));
    if (targets.length > 0 && counts.unavailable === targets.length) {
      throw new SyncRunError('ONEC_UNAVAILABLE', `1С недоступна: снимки долга не обновлены (${targets.length})`);
    }
    return {
      implemented: true,
      status: counts.errors > 0 ? 'partial' : 'success',
      counts: { ...counts, total: targets.length },
    };
  }

  private async one(
    ctx: SyncRunContext,
    t: Target,
    counts: {
      fetched: number;
      updated: number;
      skipped: number;
      notInOnec: number;
      errors: number;
      unavailable: number;
    },
  ): Promise<void> {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), this.opts.timeoutMs ?? 15_000);
    try {
      const res = await this.gateway.getCustomerReceivables(t.onec_ref, { signal: ac.signal, requestId: ctx.jobId });
      counts.fetched += 1;
      const parsed = parseOnecReceivables(res.body, t.onec_ref, { receivedAt: new Date() });
      const w = await writeReceivablesSnapshotTx(this.pool, t.id, parsed, 'sync');
      if (w.applied) counts.updated += 1;
      else counts.skipped += 1;
    } catch (e) {
      if (isOnecError(e) && e.status === 404) {
        counts.notInOnec += 1;
        return;
      }
      counts.errors += 1;
      const transport = isOnecError(e) && e.retryable;
      if (transport || ac.signal.aborted) counts.unavailable += 1;
      await writeSyncError(this.pool, {
        entity: 'receivables',
        errorCode: e instanceof OnecReceivablesFormatError ? 'VALIDATION' : transport ? 'ONEC_UNAVAILABLE' : 'OTHER',
        severity: 'warning',
        syncRunId: ctx.runId,
        message: `снимок долга клиента не обновлён: ${e instanceof Error ? e.message : String(e)}`.slice(0, 500),
        payload: { customerId: t.id, onecRef: t.onec_ref },
      }).catch((err: unknown) => ctx.log.error({ err }, 'sync.receivables.error_write_failed'));
    } finally {
      clearTimeout(timer);
    }
  }
}

import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import type pg from 'pg';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { PG_POOL } from '../../common/db/database.module.js';
import {
  RECEIVABLES_CLOCK_SKEW_MS,
  type ReceivableDocumentView,
  type ReceivablesRefreshOutcome,
  type ReceivablesSnapshotPort,
  type ReceivablesSnapshotView,
  type SalesActor,
  type SalesTx,
} from '../../common/ports/index.js';
import { SettingsReader } from '../../common/settings/settings-reader.js';
import { isOnecError } from '../../integrations/onec/onec-error.js';
import { ONEC_GATEWAY, type OnecGateway } from '../../integrations/onec/onec-gateway.js';
import { OnecReceivablesFormatError, parseOnecReceivables } from '../../sync/receivables/onec-receivables.parser.js';
import { writeReceivablesSnapshotTx } from '../../sync/receivables/receivables-snapshot.writer.js';
import { ReceivablesRepository, type ReceivablesRow } from './receivables.repository.js';

/** Ключ `app_settings` порога устаревания снимка (ядро §17.7). */
export const RECEIVABLES_MAX_AGE_KEY = 'receivables.max_age_minutes';

const MINUTE_MS = 60_000;

type Config = Pick<AppConfig, 'RECEIVABLES_MAX_AGE_MIN' | 'ONEC_SYNC_CHECK_TIMEOUT_MS' | 'ONEC_INBOUND_ENABLED'>;

/** Исключение таймаута вызова 1С. */
class OnecTimeoutError extends Error {
  override readonly name = 'OnecTimeoutError';
}

/**
 * `ReceivablesSnapshotPort` (RM-G-002, RM-G-011; 06 §7.4 `ReceivablesService`) — снимок долга клиента из 1С.
 *
 * - `maxAgeMinutes` — `app_settings.receivables.max_age_minutes` (целое ≥ 1), иначе env `RECEIVABLES_MAX_AGE_MIN`
 *   (60, R0 §16 п. 2);
 * - `snapshot` — строка `receivables` с возрастом и признаками `isStale`, `usableForCredit` (DEBT-006, DEBT-012);
 * - `refresh` — синхронный `OnecGateway.getCustomerReceivables` с таймаутом `ONEC_SYNC_CHECK_TIMEOUT_MS` (SYNC-073),
 *   запись снимка в собственной транзакции; **single-flight** по клиенту (параллельные вызовы получают один исход,
 *   08 §2.9 RL-RECV-REFRESH); исключений при недоступности 1С не бросает: `unavailable` с прежним снимком
 *   (SYNC-016). Вариант C-2 (`ONEC_INBOUND_ENABLED=true`, ONEC-065) — вызов 1С не выполняется (`unavailable`).
 *   Клиент без `onec_ref` или неизвестный 1С (404) — `not_in_onec`.
 */
@Injectable()
export class ReceivablesSnapshotService implements ReceivablesSnapshotPort {
  private readonly logger = new Logger('receivables');
  private readonly inflight = new Map<string, Promise<ReceivablesRefreshOutcome>>();
  /** Источник времени (подмена — тесты). */
  now: () => Date = () => new Date();

  constructor(
    private readonly repo: ReceivablesRepository,
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    @Inject(APP_CONFIG) private readonly config: Config,
    private readonly settings: SettingsReader,
    @Optional() @Inject(ONEC_GATEWAY) private readonly onec?: OnecGateway,
  ) {}

  async maxAgeMinutes(): Promise<number> {
    const v = await this.settings.get(RECEIVABLES_MAX_AGE_KEY);
    return typeof v === 'number' && Number.isInteger(v) && v >= 1 ? v : this.config.RECEIVABLES_MAX_AGE_MIN;
  }

  async snapshot(tx: SalesTx | null, customerId: string, now?: Date): Promise<ReceivablesSnapshotView | null> {
    const row = await this.repo.snapshot(tx, customerId);
    return row ? this.view(customerId, row, await this.maxAgeMinutes(), now ?? this.now()) : null;
  }

  /** Представление строки снимка с возрастом (без повторного чтения). */
  view(customerId: string, row: ReceivablesRow, maxAgeMinutes: number, now: Date): ReceivablesSnapshotView {
    const ageMs = now.getTime() - row.snapshotAt.getTime();
    const ageMinutes = Math.max(0, Math.floor(ageMs / MINUTE_MS));
    // Как `decideCredit`: свежий — `now − snapshotAt ≤ maxAge` (DEBT-006: «> RECEIVABLES_MAX_AGE_MIN» — устарел);
    // метка «из будущего» сверх допуска часов — непригодна (ревью G-credit-2).
    const isStale = ageMs > maxAgeMinutes * MINUTE_MS || ageMs < -RECEIVABLES_CLOCK_SKEW_MS;
    return {
      customerId,
      balance: row.balance,
      overdueAmount: row.overdueAmount,
      overdueDays: row.overdueDays,
      oldestDueDate: row.oldestDueDate,
      snapshotAt: row.snapshotAt,
      ageMinutes,
      isStale,
      usableForCredit: !isStale && row.overdueAmount !== null,
      maxAgeMinutes,
    };
  }

  async documents(tx: SalesTx | null, customerId: string): Promise<readonly ReceivableDocumentView[]> {
    return this.repo.documents(tx, customerId);
  }

  async openOrdersAmount(tx: SalesTx | null, customerId: string): Promise<string> {
    return this.repo.openOrdersAmount(tx, customerId);
  }

  refresh(
    customerId: string,
    opts: { readonly actor?: SalesActor; readonly timeoutMs?: number } = {},
  ): Promise<ReceivablesRefreshOutcome> {
    const running = this.inflight.get(customerId);
    if (running) return running;
    const p = this.doRefresh(customerId, opts).finally(() => this.inflight.delete(customerId));
    this.inflight.set(customerId, p);
    return p;
  }

  /** Идёт ли сейчас обновление снимка клиента (single-flight). */
  isRefreshing(customerId: string): boolean {
    return this.inflight.has(customerId);
  }

  private async doRefresh(
    customerId: string,
    opts: { readonly actor?: SalesActor; readonly timeoutMs?: number },
  ): Promise<ReceivablesRefreshOutcome> {
    const customer = await this.repo.customer(null, customerId);
    if (!customer || customer.onecRef === null) return { kind: 'not_in_onec' };
    const unavailable = async (reason: string): Promise<ReceivablesRefreshOutcome> => ({
      kind: 'unavailable',
      snapshot: await this.snapshot(null, customerId),
      reason,
    });
    if (this.config.ONEC_INBOUND_ENABLED) return unavailable('onec_inbound_mode');
    if (!this.onec) return unavailable('onec_gateway_missing');
    const timeoutMs = opts.timeoutMs ?? this.config.ONEC_SYNC_CHECK_TIMEOUT_MS;
    const ac = new AbortController();
    let timer: NodeJS.Timeout | undefined;
    try {
      const call = this.onec.getCustomerReceivables(customer.onecRef, {
        signal: ac.signal,
        ...(opts.actor?.requestId ? { requestId: opts.actor.requestId } : {}),
      });
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          ac.abort();
          reject(new OnecTimeoutError(`1С не ответила за ${timeoutMs} мс`));
        }, timeoutMs);
      });
      const res = await Promise.race([call, timeout]);
      const parsed = parseOnecReceivables(res.body, customer.onecRef, { receivedAt: this.now() });
      await writeReceivablesSnapshotTx(this.pool, customerId, parsed);
      const snap = await this.snapshot(null, customerId);
      // Снимок записан (или в БД уже более новый) — строка есть всегда.
      return { kind: 'refreshed', snapshot: snap as ReceivablesSnapshotView };
    } catch (e) {
      if (isOnecError(e) && e.status === 404) return { kind: 'not_in_onec' };
      const reason =
        e instanceof OnecTimeoutError
          ? 'timeout'
          : e instanceof OnecReceivablesFormatError
            ? 'invalid_response'
            : isOnecError(e)
              ? e.code
              : 'error';
      this.logger.warn(
        { event: 'receivables.refresh_failed', customerId, reason, err: e instanceof Error ? e.message : String(e) },
        'receivables: снимок долга не обновлён, прежний сохранён (SYNC-016)',
      );
      return unavailable(reason);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}

import { randomUUID } from 'node:crypto';
import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import type { OnecConfirmedPayload, OnecFailedPayload } from '../../common/jobs/contracts/queues.js';
import { NOTIFICATIONS_PORT, type NotificationsPort, PortNotBoundError } from '../../common/ports/index.js';
import { isOnecError } from '../../integrations/onec/onec-error.js';
import { ONEC_GATEWAY, type OnecGateway, type OnecJsonObject } from '../../integrations/onec/onec-gateway.js';
import { isOnecReturnStatus } from '../domain/return-status.js';
import { ReturnsRepository } from '../returns.repository.js';
import { type OnecReturnState, ReturnOnecProjector } from './return-onec-projector.js';

export type ReturnsResultOutcome = 'applied' | 'skipped';

function str(v: unknown): string | null {
  return typeof v === 'string' && v !== '' ? v : null;
}

/** Состояние заявки из тела ответа 1С (`ReturnRequestState`); нераспознанный статус — `null`. */
export function parseOnecReturnState(body: OnecJsonObject | null | undefined): OnecReturnState | null {
  const b = (body ?? {}) as Record<string, unknown>;
  if (!isOnecReturnStatus(b.status)) return null;
  return { ref: str(b.ref), number: str(b.number), status: b.status, onecStatus: str(b.onecStatus) };
}

/**
 * Результаты 1С по заявкам на возврат (05 §6.4, ONEC-067; 07 §8.2; 06 §7.4 п. (б)):
 * - `returns.onec-confirmed` — 1С приняла заявку (`POST /pos/v1/returns` → ref, номер, статус): ссылка 1С и проекция;
 * - `returns.onec-failed` — бизнес-отказ 1С (элемент outbox `failed`): автору — уведомление `return_status`, заявка
 *   остаётся `submitted` (отклонить в POS можно — RET-013 (а); повтор — `/sync/outbox/{id}/retry`);
 * - опрос `GET /pos/v1/returns/{uuid}/status` открытых заявок, переданных в 1С (прогон `return_docs`, 05 §7.3 — 5 мин).
 */
@Injectable()
export class ReturnsOnecService {
  private readonly logger = new Logger('returns.onec');
  private readonly repo = new ReturnsRepository();
  private readonly projector: ReturnOnecProjector;
  private readonly notifications: NotificationsPort | null;

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'ONEC_TIMEOUT_MS'>,
    @Inject(NOTIFICATIONS_PORT) notifications: NotificationsPort,
    @Optional() @Inject(ONEC_GATEWAY) private readonly gateway?: OnecGateway,
  ) {
    this.notifications = safeNotifications(notifications, this.logger);
    this.projector = new ReturnOnecProjector(this.notifications, {
      warn: (o, m) => this.logger.warn(o, m),
    });
  }

  async onConfirmed(p: OnecConfirmedPayload): Promise<ReturnsResultOutcome> {
    return this.db.transaction(async (tx) => {
      const ob = await tx.execute<{
        aggregate_type: string;
        aggregate_id: string;
        status: string;
        onec_response: unknown;
      }>(
        sql`SELECT aggregate_type::text AS aggregate_type, aggregate_id, status::text AS status, onec_response
              FROM onec_outbox WHERE id = ${p.outboxId}::uuid`,
      );
      const row = ob.rows[0];
      if (!row || row.aggregate_type !== 'return_request' || (row.status !== 'sent' && row.status !== 'confirmed')) {
        return 'skipped';
      }
      const r = await this.repo.findById(tx, row.aggregate_id, true);
      if (!r) return 'skipped';
      const body = (row.onec_response ?? {}) as OnecJsonObject;
      const state = parseOnecReturnState({
        ...body,
        ref: str((body as Record<string, unknown>).ref) ?? p.onecRef,
        number: str((body as Record<string, unknown>).number) ?? p.onecNumber,
        status: str((body as Record<string, unknown>).status) ?? p.onecStatus ?? 'submitted',
      });
      await this.projector.apply(
        tx,
        r,
        state ?? { ref: p.onecRef, number: p.onecNumber, status: 'submitted' },
        'onec_response',
      );
      return 'applied';
    });
  }

  async onFailed(p: OnecFailedPayload): Promise<ReturnsResultOutcome> {
    return this.db.transaction(async (tx) => {
      const ob = await tx.execute<{
        aggregate_type: string;
        aggregate_id: string;
        status: string;
        last_error: string | null;
      }>(
        sql`SELECT aggregate_type::text AS aggregate_type, aggregate_id, status::text AS status, last_error
              FROM onec_outbox WHERE id = ${p.outboxId}::uuid`,
      );
      const row = ob.rows[0];
      if (!row || row.aggregate_type !== 'return_request' || row.status !== 'failed') return 'skipped';
      const r = await this.repo.findById(tx, row.aggregate_id);
      if (!r) return 'skipped';
      await this.notifyFailure(tx, r.created_by_user_id, r.id, r.public_number, row.last_error);
      return 'applied';
    });
  }

  /** Опрос статусов открытых заявок, переданных в 1С (`submitted`/`accepted` с элементом outbox `sent`/`confirmed`). */
  async pollOpen(limit = 100): Promise<{ checked: number; changed: number; failed: number }> {
    const out = { checked: 0, changed: 0, failed: 0 };
    if (!this.gateway) return out;
    const open = await this.db.execute<{ id: string }>(sql`
      SELECT r.id FROM return_requests r
        JOIN onec_outbox o ON o.aggregate_type = 'return_request' AND o.aggregate_id = r.id AND o.operation = 'create'
       WHERE r.status IN ('submitted','accepted') AND o.status IN ('sent','confirmed')
       ORDER BY r.updated_at LIMIT ${limit}`);
    for (const { id } of open.rows) {
      out.checked += 1;
      // `X-Request-Id` — новый UUID на каждый вызов (контракт `XRequestId`: Uuid; ТЗ для 1С 4.4/4.8; разбор 98 п. 71);
      // контекст опроса и id заявки — в журнал, по `requestId` вызов находится в журнале расширения 1С.
      const requestId = randomUUID();
      this.logger.debug({ event: 'returns.poll', requestId, returnRequestId: id }, 'returns.poll.request');
      try {
        const res = await this.gateway.getReturnRequestStatus(id, {
          signal: AbortSignal.timeout(this.config.ONEC_TIMEOUT_MS),
          requestId,
        });
        const state = parseOnecReturnState(res.body);
        if (!state) continue;
        const steps = await this.db.transaction(async (tx) => {
          const r = await this.repo.findById(tx, id, true);
          return r ? this.projector.apply(tx, r, state, 'onec_status') : [];
        });
        if (steps.length > 0) out.changed += 1;
      } catch (e) {
        out.failed += 1;
        this.logger.warn(
          {
            event: 'returns.poll',
            requestId,
            returnRequestId: id,
            err: isOnecError(e) ? `${e.status} ${e.code}` : String(e),
          },
          'returns.poll.failed',
        );
      }
    }
    return out;
  }

  private async notifyFailure(
    tx: Parameters<Parameters<Database['transaction']>[0]>[0],
    userId: string,
    id: string,
    number: string,
    error: string | null,
  ): Promise<void> {
    if (!this.notifications) return;
    await this.notifications.notify(tx, {
      userId,
      kind: 'return_status',
      severity: 'error',
      title: `1С не приняла заявку на возврат ${number}`,
      body: error ? `Ответ 1С: ${error.slice(0, 500)}` : 'Оформите возврат в 1С вручную или отклоните заявку.',
      payload: { returnRequestId: id, status: 'submitted' },
      dedupeKey: `return_status:${id}:onec_failed`,
    });
  }
}

/** Порт уведомлений, если он привязан (модуль notifications подключён); иначе `null` — уведомления пропускаются. */
function safeNotifications(p: NotificationsPort | null, log: Logger): NotificationsPort | null {
  if (!p) return null;
  return {
    notify: async (tx, input) => {
      try {
        return await p.notify(tx, input);
      } catch (e) {
        if (e instanceof PortNotBoundError) {
          log.warn({ kind: input.kind }, 'returns.notify_skipped: NotificationsPort не привязан');
          return { id: '', created: false };
        }
        throw e;
      }
    },
    notifyRole: (tx, role, input) => p.notifyRole(tx, role, input),
  };
}

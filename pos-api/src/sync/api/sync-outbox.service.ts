import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type pg from 'pg';
import { type AuditContext, applyAuditGucs } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { DRIZZLE, PG_POOL, type Database } from '../../common/db/database.module.js';
import { isOutboxAggregate, isOutboxStatus, type OutboxAggregate, type OutboxStatus } from '../../common/enums.js';
import { ORDER_STATUS_PORT, type OrderStatusPort, PortNotBoundError } from '../../common/ports/index.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import {
  CURSOR_TS_SQL,
  type Page,
  parseLimit,
  parseUuid,
  SyncCursorCodec,
  toPage,
  validation,
} from './sync-api.common.js';
import { OUTBOX_COLUMNS, type OutboxRowDb, presentOutbox } from './sync-api.presenters.js';

/** Отказ ручного повтора по текущему статусу (08 §4.17.3: 409 `ORDER_STATE_INVALID`, `resource: outbox_item`). */
const RETRY_REFUSAL: Readonly<Partial<Record<OutboxStatus, string>>> = {
  sent: 'already_delivered',
  confirmed: 'already_delivered',
  cancelled: 'withdrawn',
  sending: 'in_progress',
  pending: 'invalid_transition',
};

const RETRYABLE: readonly OutboxStatus[] = ['failed', 'dead'];

/**
 * Очередь «в 1С» (08 §4.17.3; ядро §22.1, §22.10, §19.4; R0 §18.2 п. 11; 05 SYNC-046): `sync.outbox.manage` —
 * `admin` и `senior_seller`, **все** элементы (фильтра «свой магазин» нет), **без step-up** (это повтор отправки,
 * а не запуск синхронизации). Ручной повтор — только `failed`/`dead` → `pending` (`attempts=0`,
 * `next_attempt_at=now`); внешний ключ для 1С прежний (`externalId`), дубль в 1С невозможен.
 */
@Injectable()
export class SyncOutboxService {
  private readonly logger = new Logger('sync.outbox');
  private readonly cursor: SyncCursorCodec;

  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    @Inject(DRIZZLE) private readonly db: Database,
    private readonly audit: AuditService,
    hmac: OtpHmacService,
    /** Порт модуля orders: шаги заказа при повторе (ORD-027); нет модуля продаж (стенд этапа E) — без них. */
    @Optional() @Inject(ORDER_STATUS_PORT) private readonly orders?: OrderStatusPort,
  ) {
    this.cursor = new SyncCursorCodec(hmac, 'sync_outbox');
  }

  async list(q: Record<string, unknown>): Promise<Page<Record<string, unknown>>> {
    const statuses = parseStatuses(q.status);
    let aggregate: string | undefined;
    if (q.aggregateType !== undefined && q.aggregateType !== '') {
      if (!isOutboxAggregate(q.aggregateType)) {
        throw validation('aggregateType', 'enum', 'Значение вне перечня outbox_aggregate.');
      }
      aggregate = q.aggregateType;
    }
    const limit = parseLimit(q.limit);
    const after = this.cursor.decode(q.cursor);
    const params: unknown[] = [statuses];
    const where = ['o.status::text = ANY($1::text[])'];
    if (aggregate) {
      params.push(aggregate);
      where.push(`o.aggregate_type = $${params.length}::outbox_aggregate`);
    }
    if (after) {
      params.push(after.createdAt, after.id);
      where.push(`(o.created_at, o.id) < ($${params.length - 1}::timestamptz, $${params.length}::uuid)`);
    }
    params.push(limit + 1);
    const r = await this.pool.query<OutboxRowDb>(
      `SELECT ${OUTBOX_COLUMNS}, ${CURSOR_TS_SQL('o.created_at')} AS cursor_ts
         FROM onec_outbox o WHERE ${where.join(' AND ')}
        ORDER BY o.created_at DESC, o.id DESC LIMIT $${params.length}`,
      params,
    );
    return toPage(r.rows, limit, this.cursor, presentOutbox);
  }

  /** `POST /sync/outbox/{id}/retry` → 202 `OutboxItem` (status=pending). Аудит `outbox.retried` в той же транзакции. */
  async retry(principal: AuthenticatedPrincipal, rawId: string, ctx: AuditContext): Promise<Record<string, unknown>> {
    const id = parseUuid(rawId, 'id');
    const result = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const cur = await tx.execute<{
        status: OutboxStatus;
        attempts: number;
        last_error_code: string | null;
        aggregate_type: OutboxAggregate;
        aggregate_id: string;
        operation: string;
      }>(
        sql`SELECT status::text AS status, attempts, last_error_code, aggregate_type::text AS aggregate_type,
                   aggregate_id::text AS aggregate_id, operation
              FROM onec_outbox WHERE id = ${id} FOR UPDATE`,
      );
      const before = cur.rows[0];
      if (!before) throw new ProblemException('NOT_FOUND', { detail: 'Элемент очереди «в 1С» не найден.' });
      if (!RETRYABLE.includes(before.status)) {
        throw new ProblemException('ORDER_STATE_INVALID', {
          detail: 'Повтор доступен только для элементов в статусе «ошибка» или «не доставлен».',
          resource: 'outbox_item',
          reason: RETRY_REFUSAL[before.status] ?? 'invalid_transition',
          currentStatus: before.status,
        });
      }
      await tx.execute(sql`
        UPDATE onec_outbox
           SET status = 'pending', attempts = 0, next_attempt_at = now(), lease_until = NULL, locked_by = NULL,
               dead_at = NULL, requested_by_user_id = ${principal.userId}::uuid, updated_at = now()
         WHERE id = ${id}`);
      // Заказ: технический повтор отклонённого заказа (10 ORD-027) — переход заказа и восстановленная корзина в
      // той же транзакции; отказ модуля orders (409) откатывает повтор (ревью F-orders-1c-1).
      if (before.aggregate_type === 'order' && (before.operation === 'create' || before.operation === 'cancel')) {
        await this.orderRetryStep(tx, {
          orderId: before.aggregate_id,
          operation: before.operation,
          actor: { userId: principal.userId, roles: principal.roles, isCustomer: false },
          requestId: ctx.requestId ?? null,
        });
      }
      await this.audit.write(
        ctx,
        {
          action: 'outbox.retried',
          entityType: 'onec_outbox',
          entityId: id,
          before: { status: before.status, attempts: Number(before.attempts), lastErrorCode: before.last_error_code },
          after: { status: 'pending', attempts: 0 },
        },
        tx,
      );
      return before;
    });
    this.logger.log({ event: 'outbox.retried', outboxId: id, previousStatus: result.status });
    const r = await this.pool.query<OutboxRowDb>(
      `SELECT ${OUTBOX_COLUMNS}, ${CURSOR_TS_SQL('o.created_at')} AS cursor_ts FROM onec_outbox o WHERE o.id = $1`,
      [id],
    );
    return presentOutbox(r.rows[0]);
  }

  private async orderRetryStep(
    tx: Parameters<OrderStatusPort['onOutboxRetry']>[0],
    input: Parameters<OrderStatusPort['onOutboxRetry']>[1],
  ): Promise<void> {
    if (!this.orders) return;
    try {
      await this.orders.onOutboxRetry(tx, input);
    } catch (e) {
      if (e instanceof PortNotBoundError) {
        this.logger.warn(
          { orderId: input.orderId },
          'sync.outbox.retry: модуль orders не подключён — шаги заказа пропущены',
        );
        return;
      }
      throw e;
    }
  }
}

function parseStatuses(raw: unknown): string[] {
  if (raw === undefined || raw === '') return ['failed', 'dead'];
  const parts = (Array.isArray(raw) ? raw : [raw]).flatMap((v) => String(v).split(',')).map((v) => v.trim());
  if (parts.length === 0 || parts.length > 50 || parts.some((p) => !isOutboxStatus(p))) {
    throw validation('status', 'enum', 'Значения вне перечня outbox_status.');
  }
  return [...new Set(parts)];
}

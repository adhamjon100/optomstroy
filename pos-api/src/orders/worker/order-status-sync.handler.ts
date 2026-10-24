import { sql } from 'drizzle-orm';
import { applyAuditGucs, systemActor } from '../../common/audit/audit-context.js';
import type { NotificationsPort, PaymentsPort } from '../../common/ports/index.js';
import { PortNotBoundError, SYSTEM_ACTOR } from '../../common/ports/index.js';
import type { PosDatabase } from '../../db/database.js';
import { isOnecError } from '../../integrations/onec/onec-error.js';
import type { OnecGateway } from '../../integrations/onec/onec-gateway.js';
import {
  type SyncEntityHandler,
  type SyncHandlerResult,
  type SyncRunContext,
  SyncRunError,
} from '../../jobs/sync/sync-handler.js';
import { isSalesDomainError } from '../../sales-domain/domain-error.js';
import { assertOutboxTransition } from '../../sales-domain/outbox/outbox-status.js';
import { OrderProjector, type OnecOrderDocument, parseOnecOrderDocument } from '../order-projection.js';
import { findOrder, findOrderOutbox } from '../order.repository.js';
import type { OrdersWorkerLog } from './order-onec-results.handler.js';

export interface OrderStatusSyncDeps {
  readonly db: PosDatabase;
  readonly gateway: OnecGateway;
  readonly notifications: NotificationsPort | null;
  readonly payments: PaymentsPort | null;
  readonly log: OrdersWorkerLog;
  /** Таймаут пакетного запроса статусов (мс). */
  readonly timeoutMs: number;
  /** Размер пакета `POST /pos/v1/orders/status` (контракт: ≤ 200). */
  readonly batchSize?: number;
  /** Предел заказов за прогон. */
  readonly maxOrders?: number;
}

/** Документ не найден спустя это время после `sent` → `onec_sync_state=missing` (07 §8.2, 05 SYNC-045). */
const MISSING_AFTER_MS = 30 * 60_000;

/**
 * Синхронизация статусов заказов из 1С — сущность `order_status` (job `sync.order_status` по расписанию этапа E,
 * 5 мин; 05 §5.1b ONEC-021, SYNC-017, SYNC-045; 10 ORD-040/ORD-041; 07 §6.3, §6.5): пакет
 * `POST /pos/v1/orders/status` по `externalId` открытых заказов, переданных в 1С. Для каждого найденного документа —
 * факты (M1–M8) → проекция D-20 (`source=onec_sync`, история, уведомление `order_status`), `onec_sync_state`
 * `pending → linked`, элемент outbox `create` `sent → confirmed` (без повторной проекции, ядро §23 п. 2).
 * Не найден (M10) — `missing` + `sync_errors (OUTBOX_UNCONFIRMED)`, статус не меняется; статус вне таблицы (M11) —
 * `sync_errors`, статус прежний.
 */
export class OrderStatusSyncHandler implements SyncEntityHandler {
  private readonly projector: OrderProjector;

  constructor(private readonly d: OrderStatusSyncDeps) {
    this.projector = new OrderProjector(d.notifications, (msg, data) => d.log.warn(data ?? {}, msg));
  }

  async run(ctx: SyncRunContext): Promise<SyncHandlerResult> {
    const open = await this.d.db.execute<{ id: string }>(sql`
      SELECT o.id FROM orders o
       WHERE o.status NOT IN ('draft','submit_failed','closed','cancelled')
         AND (o.onec_ref IS NOT NULL OR EXISTS (
               SELECT 1 FROM onec_outbox x WHERE x.aggregate_type = 'order' AND x.aggregate_id = o.id
                  AND x.operation = 'create' AND x.status IN ('sent','confirmed')))
       ORDER BY o.onec_last_sync_at NULLS FIRST, o.created_at
       LIMIT ${this.d.maxOrders ?? 2000}`);
    const ids = open.rows.map((r) => r.id);
    const counts = { checked: 0, changed: 0, confirmed: 0, missing: 0, unknownStatus: 0, errors: 0 };
    const size = Math.min(200, this.d.batchSize ?? 200);
    for (let i = 0; i < ids.length; i += size) {
      const chunk = ids.slice(i, i + size);
      let body: Record<string, unknown>;
      try {
        body = (await this.d.gateway.getOrderStatusBatch(chunk, { signal: AbortSignal.timeout(this.d.timeoutMs) }))
          .body;
      } catch (e) {
        const msg = isOnecError(e) ? `${e.status} ${e.code}: ${e.message}` : String(e);
        throw new SyncRunError('ONEC_UNAVAILABLE', `статусы заказов 1С недоступны: ${msg}`.slice(0, 500));
      }
      const items = Array.isArray(body.items) ? (body.items as Record<string, unknown>[]) : [];
      const notFound = Array.isArray(body.notFound)
        ? (body.notFound as unknown[]).filter((x) => typeof x === 'string')
        : [];
      for (const item of items) {
        const externalId = typeof item.externalId === 'string' ? item.externalId : null;
        if (!externalId || !chunk.includes(externalId)) continue;
        counts.checked++;
        try {
          const r = await this.applyDocument(externalId, parseOnecOrderDocument(item), ctx.runId);
          if (r.changed) counts.changed++;
          if (r.confirmed) counts.confirmed++;
          if (r.unknownStatus) counts.unknownStatus++;
        } catch (e) {
          counts.errors++;
          ctx.log.warn({ err: e, orderId: externalId }, 'orders.status_sync.apply_failed');
        }
      }
      for (const id of notFound) {
        if (!chunk.includes(id)) continue;
        counts.checked++;
        if (await this.markMissing(id, ctx.runId)) counts.missing++;
      }
      await ctx.touch(counts);
    }
    return { implemented: true, status: counts.errors > 0 ? 'partial' : 'success', counts };
  }

  /** Применение документа 1С к заказу (также используется входящим обменом/`orders.onec-status-changed`). */
  async applyDocument(
    orderId: string,
    doc: OnecOrderDocument,
    syncRunId: string | null,
  ): Promise<{ changed: boolean; confirmed: boolean; unknownStatus: boolean }> {
    return this.d.db.transaction(async (tx) => {
      await applyAuditGucs(tx, systemActor('sync'));
      const o = await findOrder(tx, orderId, true);
      if (!o) return { changed: false, confirmed: false, unknownStatus: false };
      if (o.onec_ref && doc.ref && o.onec_ref !== doc.ref) {
        await tx.execute(sql`
          INSERT INTO sync_errors (sync_run_id, entity, onec_ref, local_id, error_code, message, severity)
          VALUES (${syncRunId}::uuid, 'order_status', ${doc.ref}::uuid, ${o.id}::uuid, 'ORDER_MATCH_AMBIGUOUS',
                  'Документ 1С по externalId не совпадает с привязанным к заказу', 'warning')`);
        return { changed: false, confirmed: false, unknownStatus: false };
      }
      let changed = false;
      let unknownStatus = false;
      try {
        const r = await this.projector.apply(tx, {
          orderId: o.id,
          source: 'onec_sync',
          actorUserId: null,
          onec: doc,
          syncState: 'linked',
          locked: o,
          syncRunId,
        });
        changed = r.from !== r.to;
        if (r.unrecognizedStatus !== null) {
          unknownStatus = true;
          await tx.execute(sql`
            INSERT INTO sync_errors (sync_run_id, entity, onec_ref, local_id, error_code, message, payload, severity)
            VALUES (${syncRunId}::uuid, 'order_status', ${doc.ref}::uuid, ${o.id}::uuid, 'OTHER',
                    ${`Неизвестный статус 1С «${r.unrecognizedStatus}» — статус заказа не изменён (ONEC-021)`},
                    ${JSON.stringify({ onecStatus: r.unrecognizedStatus })}::jsonb, 'warning')`);
        }
        if (r.becameCancelled && this.d.payments) {
          try {
            await this.d.payments.voidOpenForOrderCancel(tx, { orderId: o.id, actor: SYSTEM_ACTOR });
          } catch (e) {
            if (!(e instanceof PortNotBoundError)) throw e;
          }
        }
      } catch (e) {
        if (!isSalesDomainError(e)) throw e;
        await tx.execute(sql`
          INSERT INTO sync_errors (sync_run_id, entity, onec_ref, local_id, error_code, message, payload, severity)
          VALUES (${syncRunId}::uuid, 'order_status', ${doc.ref}::uuid, ${o.id}::uuid, 'OTHER',
                  ${e.detail.slice(0, 2000)}, ${JSON.stringify(e.extensions)}::jsonb, 'warning')`);
      }
      // Элемент outbox `create`: `sent → confirmed` (документ прочитан и сопоставлен по externalId; ядро §22.1).
      let confirmed = false;
      const ob = await findOrderOutbox(tx, o.id, 'create');
      if (ob && ob.status === 'sent') {
        assertOutboxTransition('sent', 'confirmed', 'confirmed_by_sync');
        await tx.execute(sql`
          UPDATE onec_outbox SET status = 'confirmed', confirmed_at = now(), updated_at = now()
           WHERE id = ${ob.id}::uuid AND status = 'sent'`);
        confirmed = true;
      }
      return { changed, confirmed, unknownStatus };
    });
  }

  private async markMissing(orderId: string, syncRunId: string): Promise<boolean> {
    return this.d.db.transaction(async (tx) => {
      await applyAuditGucs(tx, systemActor('sync'));
      const o = await findOrder(tx, orderId, true);
      if (!o || !o.onec_ref || o.onec_sync_state === 'missing') return false;
      const ob = await findOrderOutbox(tx, o.id, 'create');
      const sentAt = ob?.sent_at ? new Date(ob.sent_at).getTime() : 0;
      if (o.onec_sync_state !== 'linked' && Date.now() - sentAt < MISSING_AFTER_MS) return false;
      await tx.execute(sql`
        UPDATE orders SET onec_sync_state = 'missing', row_version = row_version + 1, updated_at = now()
         WHERE id = ${o.id}::uuid`);
      await tx.execute(sql`
        INSERT INTO sync_errors (sync_run_id, entity, onec_ref, local_id, error_code, message, severity)
        VALUES (${syncRunId}::uuid, 'order_status', ${o.onec_ref}::uuid, ${o.id}::uuid, 'OUTBOX_UNCONFIRMED',
                ${`Документ 1С заказа ${o.public_number} не найден (onec_sync_state=missing)`}, 'error')`);
      if (this.d.notifications) {
        try {
          await this.d.notifications.notifyRole(tx, 'admin', {
            kind: 'sync_error',
            severity: 'error',
            title: `Заказ ${o.public_number}: документ 1С не найден`,
            body: `Документ 1С заказа ${o.public_number} не найден при синхронизации статусов.`,
            payload: { orderId: o.id },
            dedupeKey: `order_missing:${o.id}`,
          });
        } catch (e) {
          if (!(e instanceof PortNotBoundError)) throw e;
        }
      }
      return true;
    });
  }
}

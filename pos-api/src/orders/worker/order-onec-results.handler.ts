import { sql } from 'drizzle-orm';
import { type AuditContext, applyAuditGucs, systemActor } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { OnecConfirmedPayload, OnecFailedPayload } from '../../common/jobs/contracts/queues.js';
import {
  type CartReader,
  type NotificationsPort,
  type PaymentsPort,
  PortNotBoundError,
  type SalesTx,
  SYSTEM_ACTOR,
} from '../../common/ports/index.js';
import type { PosDatabase } from '../../db/database.js';
import type { OutboxRow } from '../../jobs/outbox/outbox-delivery.port.js';
import { isSalesDomainError } from '../../sales-domain/domain-error.js';
import { assertOutboxTransition } from '../../sales-domain/outbox/outbox-status.js';
import type { OutboxStatus } from '../../common/enums.js';
import { OrderProjector, parseOnecOrderDocument } from '../order-projection.js';
import { findOrder, findOutboxById, type OrderRow } from '../order.repository.js';

/** Минимальный журнал (pino-совместимый). */
export interface OrdersWorkerLog {
  info(obj: object, msg?: string): void;
  warn(obj: object, msg?: string): void;
  error(obj: object, msg?: string): void;
}

export interface OrderOnecResultsDeps {
  readonly db: PosDatabase;
  readonly notifications: NotificationsPort | null;
  /** Восстановление состава в корзину (ORD-027); `null` — порт корзины в процессе недоступен (FQ-ORD-05). */
  readonly cart: CartReader | null;
  /** Аннулирование неполученных платежей при отмене/отказе; `null` — недоступен в процессе. */
  readonly payments: PaymentsPort | null;
  readonly log: OrdersWorkerLog;
}

export type ResultOutcome = 'applied' | 'skipped' | 'error';

const OUTBOX_AUDIT: AuditContext = systemActor('outbox');

/**
 * Обработчики событий результата outbox для агрегата `order` (06 §7.4 п. (б); 07 §8.2; ядро §22.1, §23 п. 2) —
 * отдельная транзакция на событие, идемпотентно по `outboxId` (повторная доставка ничего не меняет):
 * - `orders.onec-confirmed` / `create`: `onec_ref`, номер, статус 1С → проекция P8/P9/P10, история
 *   (`onec_response`), аудит `order.submitted`, уведомление `order_status`; пометка удаления → `cancelled` (ONEC-020);
 * - `orders.onec-confirmed` / `cancel`: факты ответа 1С (пометка/«Закрыт») → `cancelled`, неполученные платежи → `voided`;
 * - `orders.onec-failed` / `create`: `submit_failed` (P3) с восстановлением корзины (ORD-027) или `cancelled` (P2,
 *   деньги получены — кассиру уведомление, ядро §22.9); `cancel`: отказ 1С — `cancelRequested` снимается, автору
 *   уведомление (08 §4.8.4);
 * - `dead` элемента заказа: уведомление `sync_error` администраторам и автору (10 ORD-031, 07 §8.2);
 * - `outbox.reconcile-aggregates`: повторное применение «потерянных» результатов (07 §8.2).
 */
export class OrderOnecResultsHandler {
  private readonly projector: OrderProjector;
  private readonly audit: AuditService;

  constructor(private readonly d: OrderOnecResultsDeps) {
    this.projector = new OrderProjector(d.notifications, (msg, data) => d.log.warn(data ?? {}, msg));
    this.audit = new AuditService(d.db);
  }

  async onConfirmed(p: OnecConfirmedPayload): Promise<ResultOutcome> {
    return this.guarded(p.outboxId, async (tx) => {
      const ob = await findOutboxById(tx, p.outboxId);
      if (!ob || ob.aggregate_type !== 'order' || (ob.status !== 'sent' && ob.status !== 'confirmed')) return 'skipped';
      const o = await findOrder(tx, ob.aggregate_id, true);
      if (!o) return 'skipped';
      const body = { ...(ob.onec_response ?? {}) } as Record<string, unknown>;
      // Ссылка документа: из ответа 1С, иначе — из события диспетчера (`p.onecRef`); пустое значение — `null`.
      const doc = parseOnecOrderDocument({
        ...body,
        ref: (body.ref as string | undefined) ?? p.onecRef,
        number: (body.number as string | undefined) ?? p.onecNumber,
        status: (body.status as string | undefined) ?? p.onecStatus,
      });
      if (ob.operation === 'create') {
        if (o.onec_ref !== null) return 'skipped';
        const r = await this.projector.apply(tx, {
          orderId: o.id,
          source: 'onec_response',
          actorUserId: null,
          onec: doc,
          locked: o,
        });
        await this.syncErrorIfUnknown(tx, o, r.unrecognizedStatus, ob.id);
        if (r.becameCancelled) await this.afterCancelled(tx, o);
        await this.audit.write(
          OUTBOX_AUDIT,
          {
            action: 'order.submitted',
            entityType: 'order',
            entityId: o.id,
            onecRef: doc.ref,
            before: { status: o.status },
            after: { status: r.to, onecNumber: doc.number, onecStatus: doc.status, attempt: p.attempt },
          },
          tx,
        );
        return 'applied';
      }
      // operation = cancel: ответ 1С на отмену (документ помечен/закрыт → подтверждённая отмена).
      if (o.status === 'cancelled') return 'skipped';
      const r = await this.projector.apply(tx, {
        orderId: o.id,
        source: 'onec_response',
        actorUserId: null,
        onec: { ...doc, ref: o.onec_ref ?? doc.ref },
        locked: o,
      });
      if (r.becameCancelled) {
        await this.afterCancelled(tx, o);
        await this.audit.write(
          OUTBOX_AUDIT,
          {
            action: 'order.cancelled',
            entityType: 'order',
            entityId: o.id,
            before: { status: o.status },
            after: { status: 'cancelled', confirmedBy: 'onec' },
          },
          tx,
        );
      }
      return 'applied';
    });
  }

  async onFailed(p: OnecFailedPayload): Promise<ResultOutcome> {
    return this.guarded(p.outboxId, async (tx) => {
      const ob = await findOutboxById(tx, p.outboxId);
      if (!ob || ob.aggregate_type !== 'order' || ob.status !== 'failed') return 'skipped';
      const o = await findOrder(tx, ob.aggregate_id, true);
      if (!o) return 'skipped';
      const message = humanReason(ob.last_error, ob.onec_response);
      if (ob.operation === 'cancel') {
        if (o.cancel_requested_at === null) return 'skipped';
        await tx.execute(sql`
          UPDATE orders SET cancel_requested_at = NULL, row_version = row_version + 1, updated_at = now()
           WHERE id = ${o.id}::uuid`);
        for (const userId of new Set([o.created_by_user_id, o.cancel_requested_by_user_id].filter(isStr))) {
          await this.notify(tx, {
            userId,
            kind: 'order_status',
            severity: 'warning',
            title: `Заказ ${o.public_number}: 1С отклонила отмену`,
            body: `1С не отменила заказ ${o.public_number}: ${message}`,
            payload: { orderId: o.id, status: o.status },
            // Отмену можно запросить снова (строка cancel переотправляется) — ключ включает момент запроса.
            dedupeKey: `order_cancel_rejected:${o.id}:${ob.id}:${new Date(o.cancel_requested_at).getTime()}`,
          });
        }
        return 'applied';
      }
      if (o.status !== 'submitting' || o.onec_ref !== null) return 'skipped';
      const r = await this.projector.apply(tx, {
        orderId: o.id,
        source: 'onec_response',
        actorUserId: null,
        rejected: { code: p.errorCode, message },
        locked: o,
        reason: message,
      });
      if (r.to === 'submit_failed' || r.to === 'cancelled') {
        // Документ в 1С не создан: отменять нечего — зависимая задача `cancel` отзывается (05 SYNC-042).
        await this.withdrawDependentCancel(tx, o, ob.id, message);
      }
      if (r.to === 'submit_failed') {
        await this.voidOpenPayments(tx, o);
        await this.restoreCart(tx, o);
      } else if (r.to === 'cancelled') {
        // Деньги получены — заказ отклонён 1С (10 ORD-035 п. 2, ядро §22.9; ревью F-orders-1c-2): платёж остаётся
        // `received`; задача outbox заказа (`failed`) и неотправленные задачи платежей → `cancelled` (технический
        // повтор ORD-027 не выполняется); состав → корзина автора `parked`; уведомление `payment_status` кассиру,
        // принявшему деньги, и автору заказа.
        await this.withdrawOutbox(tx, o.id, ob.id);
        await this.afterCancelled(tx, o);
        await this.restoreCart(tx, o, true);
        const receivers = await tx.execute<{ user_id: string }>(sql`
          SELECT DISTINCT received_by_user_id::text AS user_id FROM payments
           WHERE order_id = ${o.id}::uuid AND status = 'received' AND received_by_user_id IS NOT NULL`);
        const recipients = new Set([o.created_by_user_id, ...receivers.rows.map((x) => x.user_id)]);
        for (const userId of recipients) {
          await this.notify(tx, {
            userId,
            kind: 'payment_status',
            severity: 'error',
            title: `Заказ ${o.public_number} отклонён 1С, деньги получены`,
            body: `Заказ ${o.public_number} отменён: ${message}. Оформите в 1С возврат или аванс клиенту.`,
            payload: { orderId: o.id, status: 'cancelled', task: 'refund_or_advance' },
            dedupeKey: `order_rejected_paid:${o.id}`,
          });
        }
      }
      return 'applied';
    });
  }

  /** `dead` элемента outbox заказа: уведомление `sync_error` администраторам и автору (ORD-031). */
  async onDead(
    row: Pick<OutboxRow, 'id' | 'aggregateType' | 'aggregateId' | 'operation'>,
    reason: string,
  ): Promise<void> {
    if (row.aggregateType !== 'order') return;
    try {
      const o = await findOrder(this.d.db, row.aggregateId);
      if (!o) return;
      const input = {
        kind: 'sync_error' as const,
        severity: 'error' as const,
        title: `Заказ ${o.public_number} не доставлен в 1С`,
        body: `Задача 1С (${row.operation}) по заказу ${o.public_number} остановлена: ${reason}. Нужен ручной повтор.`,
        payload: { orderId: o.id, outboxId: row.id },
        dedupeKey: `outbox_dead:${row.id}`,
      };
      await this.notifyRole(null, 'admin', input);
      await this.notify(null, { ...input, userId: o.created_by_user_id });
    } catch (e) {
      this.d.log.error({ err: e, outboxId: row.id }, 'orders.outbox_dead.notify_failed');
    }
  }

  /**
   * Сверщик `outbox.reconcile-aggregates` (07 §8.2): результаты, не перенесённые в заказ (потеря job), —
   * `sent/confirmed` с `onec_ref` при пустом `orders.onec_ref` и `failed` ONEC_REJECTED у заказа `submitting`.
   */
  async reconcile(): Promise<{ confirmed: number; failed: number }> {
    const sent = await this.d.db.execute<{ id: string; onec_ref: string; attempts: number }>(sql`
      SELECT x.id, x.onec_ref::text AS onec_ref, x.attempts FROM onec_outbox x JOIN orders o ON o.id = x.aggregate_id
       WHERE x.aggregate_type = 'order' AND x.operation = 'create' AND x.status IN ('sent','confirmed')
         AND x.onec_ref IS NOT NULL AND o.onec_ref IS NULL
       LIMIT 200`);
    let confirmed = 0;
    for (const s of sent.rows) {
      const r = await this.onConfirmed({
        outboxId: s.id,
        aggregateId: '',
        onecRef: s.onec_ref,
        onecNumber: null,
        onecStatus: null,
        attempt: Number(s.attempts),
      });
      if (r === 'applied') confirmed++;
    }
    const failedRows = await this.d.db.execute<{ id: string; attempts: number }>(sql`
      SELECT x.id, x.attempts FROM onec_outbox x JOIN orders o ON o.id = x.aggregate_id
       WHERE x.aggregate_type = 'order' AND x.operation = 'create' AND x.status = 'failed'
         AND x.last_error_code = 'ONEC_REJECTED' AND o.status = 'submitting' AND o.onec_ref IS NULL
       LIMIT 200`);
    let failed = 0;
    for (const f of failedRows.rows) {
      const r = await this.onFailed({
        outboxId: f.id,
        aggregateId: '',
        errorCode: 'ONEC_REJECTED',
        attempt: Number(f.attempts),
      });
      if (r === 'applied') failed++;
    }
    return { confirmed, failed };
  }

  private async guarded(outboxId: string, fn: (tx: SalesTx) => Promise<ResultOutcome>): Promise<ResultOutcome> {
    try {
      return await this.d.db.transaction(async (tx) => {
        await applyAuditGucs(tx, OUTBOX_AUDIT);
        return fn(tx);
      });
    } catch (e) {
      if (isSalesDomainError(e)) {
        // Недопустимый переход по таблице 07 §6.3 — не повторять бесконечно: журнал синхронизации.
        this.d.log.warn({ outboxId, code: e.code, detail: e.detail }, 'orders.onec_result.transition_rejected');
        await this.d.db.execute(sql`
          INSERT INTO sync_errors (outbox_id, entity, error_code, message, payload, severity)
          VALUES (${outboxId}::uuid, 'order_status', 'OTHER', ${e.detail.slice(0, 2000)},
                  ${JSON.stringify(e.extensions)}::jsonb, 'warning')`);
        return 'error';
      }
      throw e;
    }
  }

  private async afterCancelled(tx: SalesTx, o: OrderRow): Promise<void> {
    await this.voidOpenPayments(tx, o);
  }

  private async voidOpenPayments(tx: SalesTx, o: OrderRow): Promise<void> {
    if (!this.d.payments) return;
    try {
      await this.d.payments.voidOpenForOrderCancel(tx, { orderId: o.id, actor: SYSTEM_ACTOR });
    } catch (e) {
      if (e instanceof PortNotBoundError) return;
      throw e;
    }
  }

  /**
   * ORD-035 п. 2: задача outbox заказа `failed` и неотправленные задачи платежей заказа → `cancelled`
   * (`aggregate_cancelled`, 07 §6.5) — строка больше не повторяется ни вручную, ни сверщиком.
   */
  private async withdrawOutbox(tx: SalesTx, orderId: string, orderOutboxId: string): Promise<void> {
    const rowsToCancel = await tx.execute<{ id: string; status: OutboxStatus }>(sql`
      SELECT id, status::text AS status FROM onec_outbox
       WHERE (id = ${orderOutboxId}::uuid)
          OR (aggregate_type = 'payment'
              AND aggregate_id IN (SELECT id FROM payments WHERE order_id = ${orderId}::uuid)
              AND status IN ('pending', 'failed', 'dead'))
       FOR UPDATE`);
    for (const row of rowsToCancel.rows) {
      if (row.status === 'cancelled') continue;
      assertOutboxTransition(row.status, 'cancelled', 'aggregate_cancelled');
      await tx.execute(sql`
        UPDATE onec_outbox SET status = 'cancelled', cancelled_at = now(), next_attempt_at = NULL, lease_until = NULL,
               locked_by = NULL, updated_at = now()
         WHERE id = ${row.id}::uuid`);
    }
  }

  /**
   * 05 SYNC-042: отмена, запрошенная, пока `create` был в `sending`, ставится элементом `cancel`, зависящим от
   * `create`; при исходе `create` в `failed` (1С отклонила создание — документа в 1С нет) этот элемент → `cancelled`
   * (`aggregate_cancelled`, 07 §6.5), `orders.cancel_requested_at` снимается (заказ уже `submit_failed`/`cancelled`),
   * автору запроса отмены (если это не автор заказа, которому пришло уведомление об отказе) — `order_status`.
   * В той же транзакции, что проекция отказа: повтор job/сверщик идемпотентны. Исход `dead` (результат неизвестен)
   * здесь не обрабатывается — known_issues G-KI-12 (остаток SYNC-042, решение владельца 05/10).
   */
  private async withdrawDependentCancel(
    tx: SalesTx,
    o: OrderRow,
    createOutboxId: string,
    message: string,
  ): Promise<void> {
    const rows = await tx.execute<{ id: string; status: OutboxStatus }>(sql`
      SELECT id, status::text AS status FROM onec_outbox
       WHERE depends_on_outbox_id = ${createOutboxId}::uuid AND aggregate_type = 'order'
         AND aggregate_id = ${o.id}::uuid AND operation = 'cancel' AND status = 'pending'
       FOR UPDATE`);
    const cancel = rows.rows[0];
    if (!cancel) return;
    assertOutboxTransition(cancel.status, 'cancelled', 'aggregate_cancelled');
    await tx.execute(sql`
      UPDATE onec_outbox SET status = 'cancelled', cancelled_at = now(), next_attempt_at = NULL, lease_until = NULL,
             locked_by = NULL,
             last_error = left(${`Отозван: 1С отклонила создание заказа (${message}) — отменять в 1С нечего (05 SYNC-042).`}, 2000),
             updated_at = now()
       WHERE id = ${cancel.id}::uuid`);
    if (o.cancel_requested_at === null) return;
    await tx.execute(sql`
      UPDATE orders SET cancel_requested_at = NULL, row_version = row_version + 1, updated_at = now()
       WHERE id = ${o.id}::uuid`);
    this.d.log.info(
      { orderId: o.id, outboxId: cancel.id, dependsOn: createOutboxId },
      'orders.cancel_withdrawn: create отклонён 1С — зависимая отмена отозвана (SYNC-042)',
    );
    // Автору заказа уже пришло уведомление об отказе 1С (проекция) — отдельно только автору запроса отмены.
    const requesters = [o.cancel_requested_by_user_id].filter(isStr).filter((u) => u !== o.created_by_user_id);
    for (const userId of requesters) {
      await this.notify(tx, {
        userId,
        kind: 'order_status',
        severity: 'warning',
        title: `Заказ ${o.public_number}: запрос отмены снят`,
        body: `1С отклонила создание заказа ${o.public_number}: ${message}. Документа в 1С нет — запрос отмены снят.`,
        payload: { orderId: o.id, outboxId: cancel.id },
        dedupeKey: `order_cancel_withdrawn:${o.id}:${cancel.id}`,
      });
    }
  }

  private async restoreCart(tx: SalesTx, o: OrderRow, forceParked = false): Promise<void> {
    if (!this.d.cart) {
      this.d.log.warn({ orderId: o.id }, 'orders.restore_cart.skipped: CartReader недоступен в pos-worker (FQ-ORD-05)');
      return;
    }
    try {
      await this.d.cart.restoreFromOrder(tx, {
        orderId: o.id,
        ownerUserId: o.created_by_user_id,
        ...(forceParked ? { forceParked: true } : {}),
      });
    } catch (e) {
      if (e instanceof PortNotBoundError) return;
      throw e;
    }
  }

  private async syncErrorIfUnknown(tx: DbExecutor, o: OrderRow, raw: string | null, outboxId: string): Promise<void> {
    if (raw === null) return;
    await tx.execute(sql`
      INSERT INTO sync_errors (outbox_id, entity, onec_ref, local_id, error_code, message, payload, severity)
      VALUES (${outboxId}::uuid, 'order_status', ${o.onec_ref}::uuid, ${o.id}::uuid, 'OTHER',
              ${`Неизвестный статус 1С «${raw}» — статус заказа не изменён (ONEC-021)`.slice(0, 2000)},
              ${JSON.stringify({ onecStatus: raw })}::jsonb, 'warning')`);
  }

  private async notify(tx: SalesTx | null, input: Parameters<NotificationsPort['notify']>[1]): Promise<void> {
    if (!this.d.notifications) return;
    try {
      await this.d.notifications.notify(tx, input);
    } catch (e) {
      if (!(e instanceof PortNotBoundError)) throw e;
    }
  }

  private async notifyRole(
    tx: SalesTx | null,
    role: string,
    input: Parameters<NotificationsPort['notifyRole']>[2],
  ): Promise<void> {
    if (!this.d.notifications) return;
    try {
      await this.d.notifications.notifyRole(tx, role, input);
    } catch (e) {
      if (!(e instanceof PortNotBoundError)) throw e;
    }
  }
}

function isStr(v: string | null): v is string {
  return typeof v === 'string';
}

/** Человекочитаемая причина отказа 1С (текст 1С без ПДн, 05 §6.5). */
function humanReason(lastError: string | null, response: Record<string, unknown> | null): string {
  const m = response && typeof response.message === 'string' ? response.message : null;
  return (m ?? lastError ?? 'отказ 1С').slice(0, 500);
}

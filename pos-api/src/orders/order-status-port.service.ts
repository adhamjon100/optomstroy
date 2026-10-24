import { Inject, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { StatusChangeSource } from '../common/enums.js';
import { Money } from '../common/money/money.js';
import {
  CART_READER,
  type CartReader,
  NOTIFICATIONS_PORT,
  type NotificationsPort,
  type OrderPaymentView,
  type OrderStatusChangeResult,
  type OrderStatusPort,
  type SalesActor,
  type SalesTx,
} from '../common/ports/index.js';
import { isSalesDomainError } from '../sales-domain/domain-error.js';
import { OrderProjector } from './order-projection.js';
import { clearSubmitError, orderStateInvalid, releaseRestoredCart } from './order-retry.js';
import { findOrder } from './order.repository.js';

/**
 * `OrderStatusPort` (= 06 §7.4 `OrderPaymentLedger`) для модуля `payments`: блокировка заказа под платёж, учёт
 * полученных денег (`paid_amount`, однократный `paid_at` — триггер `trg_orders_paid_at_once`) и пересчёт проекции
 * D-20 (P8 → P9/P10, 10 §2.2 правило 3–4; ядро §22.5). Запись истории и уведомление — `OrderProjector`.
 */
@Injectable()
export class OrderStatusPortService implements OrderStatusPort {
  private readonly logger = new Logger('orders.ledger');
  private readonly projector: OrderProjector;

  constructor(
    @Inject(NOTIFICATIONS_PORT) private readonly notifications: NotificationsPort,
    @Inject(CART_READER) private readonly cart: CartReader,
  ) {
    this.projector = new OrderProjector(notifications, (msg, data) => this.logger.warn(data ?? {}, msg));
  }

  /**
   * Технический повтор задачи outbox заказа (10 ORD-027; ревью F-orders-1c-1): вызывается `SyncOutboxService.retry`
   * в той же транзакции **после** `failed | dead → pending`. Заказ `cancelled` (ORD-035 — деньги получены, заказ
   * отклонён) не повторяется; `submit_failed` возвращается в отправку только при неизменённой восстановленной корзине.
   */
  async onOutboxRetry(
    tx: SalesTx,
    input: {
      readonly orderId: string;
      readonly operation: 'create' | 'cancel';
      readonly actor: SalesActor;
      readonly requestId?: string | null;
    },
  ): Promise<void> {
    if (input.operation !== 'create') return;
    const o = await findOrder(tx, input.orderId, true);
    if (!o) return;
    if (o.status === 'cancelled') {
      throw orderStateInvalid(o.status, 'order_cancelled', 'Заказ отменён — повтор отправки в 1С не выполняется.');
    }
    if (o.status !== 'submit_failed') return;
    await releaseRestoredCart(tx, { cart: this.cart, notifications: this.notifications }, o, 'retry');
    await this.projector.apply(tx, {
      orderId: o.id,
      source: 'pos_user',
      actorUserId: input.actor.userId,
      preSteps: [{ from: 'submit_failed', to: 'submitting' }],
      syncState: 'pending',
      locked: o,
      requestId: input.requestId ?? null,
      reason: 'технический повтор отправки в 1С (ORD-027)',
    });
    await clearSubmitError(tx, o.id);
  }

  async lockForPayment(tx: SalesTx, orderId: string): Promise<OrderPaymentView | null> {
    const o = await findOrder(tx, orderId, true);
    if (!o || o.status === 'draft') return null;
    return {
      orderId: o.id,
      publicNumber: o.public_number,
      status: o.status,
      paymentMethod: o.payment_method,
      customerId: o.customer_id,
      createdByUserId: o.created_by_user_id,
      createdVia: o.created_via,
      onecRef: o.onec_ref,
      total: o.total,
      paidAmount: o.paid_amount,
      isPaid: o.is_paid,
      cancelRequested: o.cancel_requested_at !== null,
    };
  }

  async applyReceived(
    tx: SalesTx,
    input: {
      readonly orderId: string;
      readonly amount: string;
      readonly paymentId: string;
      readonly actor: SalesActor;
    },
  ): Promise<{ readonly paidAt: Date | null; readonly statusChange: OrderStatusChangeResult | null }> {
    const o = await findOrder(tx, input.orderId, true);
    if (!o) throw new Error(`orders: заказ ${input.orderId} не найден`);
    const paid = Money.of(o.paid_amount).plus(Money.of(input.amount));
    const settlesNow = o.paid_at === null && paid.compare(Money.of(o.total)) >= 0;
    const upd = await tx.execute<{ paid_at: Date | null }>(sql`
      UPDATE orders SET paid_amount = ${paid.toString()}::numeric,
             paid_at = CASE WHEN ${settlesNow}::boolean THEN now() ELSE paid_at END,
             row_version = row_version + 1, updated_at = now()
       WHERE id = ${o.id}::uuid
      RETURNING paid_at`);
    const paidAt = settlesNow ? (upd.rows[0]?.paid_at ?? null) : null;
    const change = await this.recompute(tx, { orderId: o.id, source: 'pos_system', actor: input.actor });
    return { paidAt, statusChange: change };
  }

  async recompute(
    tx: SalesTx,
    input: { readonly orderId: string; readonly source: StatusChangeSource; readonly actor: SalesActor | null },
  ): Promise<OrderStatusChangeResult | null> {
    let r;
    try {
      r = await this.projector.apply(tx, {
        orderId: input.orderId,
        source: input.source,
        actorUserId: input.actor?.userId ?? null,
      });
    } catch (e) {
      // Недопустимый переход (07 §6.3) не должен откатывать приём денег: статус останется прежним до синхронизации.
      if (isSalesDomainError(e)) {
        this.logger.warn({ orderId: input.orderId, code: e.code, detail: e.detail }, 'orders.recompute.skipped');
        return null;
      }
      throw e;
    }
    if (!r.change) return null;
    return { from: r.from, to: r.to, historySteps: r.change.history.length };
  }
}

import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../../src/common/audit/db-executor.js';
import { FixedClock } from '../../../src/common/auth/clock.js';
import { Money } from '../../../src/common/money/money.js';
import {
  NOTIFICATIONS_PORT,
  ORDER_STATUS_PORT,
  type OrderPaymentView,
  type OrderStatusChangeResult,
  type OrderStatusPort,
  type SalesActor,
} from '../../../src/common/ports/index.js';
import { PaymentsModule } from '../../../src/payments/payments.module.js';
import { QrStatusService } from '../../../src/payments/qr/qr-status.service.js';
import { type PosActor, type PosFixtureOptions, PosTestApp } from '../../support/pos-fixture.js';
import { InMemoryNotifications } from '../../support/sales-ports.fakes.js';

/**
 * `OrderStatusPort` поверх БД для тестов платежей (**тестовая реализация**, не модуль orders): блокировка строки
 * заказа и учёт полученных денег (`paid_amount`, однократный `paid_at`). Проекцию D-20 не пересчитывает — это
 * ответственность модуля orders (RM-F-002); тесты платежей проверяют только вызовы порта и денежные поля.
 */
export class SqlOrderStatusPort implements OrderStatusPort {
  readonly received: { orderId: string; amount: string; paymentId: string }[] = [];

  async lockForPayment(tx: DbExecutor, orderId: string): Promise<OrderPaymentView | null> {
    const r = await tx.execute<Record<string, unknown>>(sql`
      SELECT id, public_number, status::text AS status, payment_method::text AS payment_method, customer_id,
             created_by_user_id, created_via, onec_ref, total::text AS total, paid_amount::text AS paid_amount, is_paid,
             cancel_requested_at IS NOT NULL AS cancel_requested
        FROM orders WHERE id = ${orderId}::uuid FOR UPDATE`);
    const o = r.rows[0];
    if (!o) return null;
    return {
      orderId: String(o.id),
      publicNumber: String(o.public_number),
      status: o.status as OrderPaymentView['status'],
      paymentMethod: o.payment_method as OrderPaymentView['paymentMethod'],
      customerId: String(o.customer_id),
      createdByUserId: String(o.created_by_user_id),
      createdVia: o.created_via as 'staff' | 'customer',
      onecRef: typeof o.onec_ref === 'string' ? o.onec_ref : null,
      total: String(o.total),
      paidAmount: String(o.paid_amount),
      isPaid: Boolean(o.is_paid),
      cancelRequested: Boolean(o.cancel_requested),
    };
  }

  async applyReceived(
    tx: DbExecutor,
    input: { orderId: string; amount: string; paymentId: string; actor: SalesActor },
  ): Promise<{ paidAt: Date | null; statusChange: OrderStatusChangeResult | null }> {
    this.received.push({ orderId: input.orderId, amount: input.amount, paymentId: input.paymentId });
    const r = await tx.execute<{ paid_at: Date | null }>(sql`
      UPDATE orders SET paid_amount = paid_amount + ${Money.of(input.amount).toString()}::numeric,
             paid_at = CASE WHEN paid_at IS NULL AND paid_amount + ${Money.of(input.amount).toString()}::numeric >= total
                            THEN now() ELSE paid_at END,
             row_version = row_version + 1, updated_at = now()
       WHERE id = ${input.orderId}::uuid RETURNING paid_at`);
    return { paidAt: r.rows[0]?.paid_at ?? null, statusChange: null };
  }

  recompute(): Promise<null> {
    return Promise.resolve(null);
  }

  onOutboxRetry(): Promise<void> {
    return Promise.resolve();
  }
}

export interface PaymentsTestOptions extends PosFixtureOptions {
  /** Использовать реальный `OrderStatusPort` модуля orders, если он привязан (по умолчанию — тестовый SQL). */
  readonly realOrders?: boolean;
}

/**
 * Стенд тестов платежей: `PosTestApp` с модулем `PaymentsModule` (по умолчанию — без чужих модулей F, чтобы
 * тест не зависел от их готовности), `SqlOrderStatusPort` и `InMemoryNotifications`.
 */
export class PaymentsTestApp extends PosTestApp {
  readonly orderPort = new SqlOrderStatusPort();
  readonly notifications = new InMemoryNotifications();

  async startPayments(opts: PaymentsTestOptions = {}): Promise<this> {
    await this.start({ modules: [PaymentsModule], ...opts });
    // pos-fixture.seedOrder берёт номер платежа из orders_number_seq (FQ-BASE-01): сдвигаем свою
    // последовательность, чтобы номера `next_payment_public_number()` не пересекались с номерами стенда.
    await this.pool.query(`SELECT setval('payments_number_seq', 500000)`);
    if (!(opts.realOrders && this.registry.isBound(ORDER_STATUS_PORT))) {
      this.replacePort(ORDER_STATUS_PORT, this.orderPort);
    }
    this.replacePort(NOTIFICATIONS_PORT, this.notifications);
    return this;
  }

  get qrStatus(): QrStatusService {
    return this.app.get(QrStatusService, { strict: false });
  }

  async payment(id: string) {
    return (
      await this.q<{
        id: string;
        status: string;
        method: string;
        amount: string;
        review_reason: string | null;
        void_reason: string | null;
        voided_by_user_id: string | null;
        bank_amount: string | null;
        bank_reference: string | null;
        qr_provider: string | null;
        qr_provider_ref: string | null;
        qr_provider_status_raw: string | null;
        qr_expires_at: Date | null;
        received_amount: string | null;
        change_amount: string | null;
        received_by_user_id: string | null;
        manual_confirmed_by_user_id: string | null;
        public_number: string;
      }>(
        `SELECT id, status::text AS status, method::text AS method, amount::text AS amount, review_reason, void_reason,
                voided_by_user_id, bank_amount::text AS bank_amount, bank_reference, qr_provider, qr_provider_ref,
                qr_provider_status_raw, qr_expires_at, received_amount::text AS received_amount,
                change_amount::text AS change_amount, received_by_user_id, manual_confirmed_by_user_id, public_number
           FROM payments WHERE id = $1`,
        [id],
      )
    )[0];
  }

  async orderMoney(orderId: string) {
    return (
      await this.q<{ paid_amount: string; is_paid: boolean; paid_at: Date | null; total: string }>(
        `SELECT paid_amount::text AS paid_amount, is_paid, paid_at, total::text AS total FROM orders WHERE id = $1`,
        [orderId],
      )
    )[0];
  }

  async transactionsOf(paymentId: string) {
    return this.q<{ kind: string; amount: string; actor_user_id: string | null; dedupe_key: string }>(
      `SELECT kind::text AS kind, amount::text AS amount, actor_user_id, dedupe_key FROM transactions
        WHERE payment_id = $1 ORDER BY created_at`,
      [paymentId],
    );
  }

  /** Перевести платёж в статус напрямую (подготовка: `qr_expired`, `manual_confirm`, `received`, `credit`). */
  async forcePayment(id: string, patch: Record<string, unknown>): Promise<void> {
    const keys = Object.keys(patch);
    const set = keys.map((k, i) => `${k} = $${i + 2}${k === 'status' ? '::payment_status' : ''}`).join(', ');
    await this.pool.query(`UPDATE payments SET ${set} WHERE id = $1`, [id, ...keys.map((k) => patch[k])]);
  }

  async setOrderStatus(orderId: string, status: string): Promise<void> {
    await this.pool.query(
      `UPDATE orders SET status = $2::order_status, row_version = row_version + 1,
              onec_sync_state = CASE WHEN onec_ref IS NULL THEN onec_sync_state ELSE 'linked'::onec_sync_state END
        WHERE id = $1`,
      [orderId, status],
    );
  }

  /** Тело `POST /orders/{id}/payments` с новым ключом. */
  pay(a: PosActor, orderId: string, body: Record<string, unknown>, idem: string = randomUUID()) {
    return this.req('post', `/orders/${orderId}/payments`, a, { idem }).send(body);
  }
}

export { FixedClock };

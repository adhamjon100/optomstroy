import { createHash, randomUUID } from 'node:crypto';
import pino from 'pino';
import { sql } from 'drizzle-orm';
import { Money, Quantity } from '../../../src/common/money/money.js';
import {
  CART_READER,
  type CartReader,
  type CheckoutConflict,
  type CheckoutLineSnapshot,
  type CheckoutValidation,
  type CheckoutValidationInput,
  type InitialPaymentInput,
  PAYMENTS_PORT,
  type PaymentSummary,
  type PaymentsPort,
  type QrAfterCommitResult,
  type SalesActor,
  type SalesTx,
} from '../../../src/common/ports/index.js';
import { ProblemException } from '../../../src/common/problem-details/problem.exception.js';
import { OnecError } from '../../../src/integrations/onec/onec-error.js';
import type {
  OnecCallOptions,
  OnecExternalIdsQuery,
  OnecJsonObject,
  OnecResult,
} from '../../../src/integrations/onec/onec-gateway.js';
import { OutboxDispatcher } from '../../../src/jobs/outbox/outbox-dispatcher.js';
import { OrdersModule } from '../../../src/orders/orders.module.js';
import { OrderOnecResultsHandler } from '../../../src/orders/worker/order-onec-results.handler.js';
import { OrderStatusSyncHandler } from '../../../src/orders/worker/order-status-sync.handler.js';
import { initialPaymentStatus } from '../../../src/sales-domain/payment/payment-status.js';
import { priceCart } from '../../../src/sales-domain/pricing/cart-pricing.js';
import { schedulerConfigFromEnv } from '../../../src/sync/scheduler/scheduler.config.js';
import { OnecOutboxDelivery } from '../../../src/sync/outbox/onec-outbox.delivery.js';
import { type PosActor, type PosFixtureOptions, PosTestApp, RETAIL_CUSTOMER_ID } from '../../support/pos-fixture.js';
import { ScriptedOnecGateway } from '../../support/scripted-onec.gateway.js';

/**
 * Стенд тестов модуля `orders` (**тестовые данные**): `PosTestApp` только с `OrdersModule` (+ каталог и порты),
 * порты чужих модулей — заглушки: корзина — `TestCartReader` (снимок по реальным ценам каталога движком `priceCart`,
 * `/check` 1С — через `ScriptedOnecGateway` с таймаутом `ONEC_SYNC_CHECK_TIMEOUT_MS`), платежи — `DbPaymentsPort`
 * (строки `payments` в транзакции заказа), уведомления — `InMemoryNotifications`. Воркер outbox — `OutboxDispatcher` +
 * `OnecOutboxDelivery` + `OrderOnecResultsHandler` (события результата — синхронно после тика).
 */

/** Ref/номер документа 1С, детерминированные по `externalId` (повтор `POST` → тот же документ, POS_E_DUPLICATE). */
export function onecRefFor(externalId: string): string {
  const h = createHash('sha256').update(`ref:${externalId}`).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

export function onecNumberFor(externalId: string): string {
  const h = createHash('sha256').update(`num:${externalId}`).digest();
  return `ОС00-${String(h.readUInt32BE(0) % 1_000_000).padStart(6, '0')}`;
}

const FIXTURE_ORDER_REF = 'b2c3d4e5-0000-4000-8000-000000000010';

/** Фейк 1С: ответ `createOrder` по фикстуре получает уникальные `ref`/`number` заказа (одна база — много заказов). */
export class OrdersOnecGateway extends ScriptedOnecGateway {
  /** Очередь ответов `listExternalIds` (`ScriptedOnecGateway` эту операцию не сценарирует): тело или сбой сети. */
  readonly externalIds: (OnecJsonObject | 'transport')[] = [];

  override listExternalIds(query: OnecExternalIdsQuery, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    const step = this.externalIds.shift();
    if (step === undefined) return super.listExternalIds(query, opts);
    this.calls.push({ operation: 'listExternalIds', args: [query, opts] });
    if (step === 'transport')
      return Promise.reject(new OnecError('listExternalIds', 0, 'TRANSPORT', 'сбой сети (тест)'));
    return Promise.resolve({ status: 200, body: step });
  }

  override reset(): void {
    super.reset();
    this.externalIds.length = 0;
  }

  override async createOrder(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    const r = await super.createOrder(request, opts);
    const ext = typeof request.externalId === 'string' ? request.externalId : '';
    if (r.body.ref === FIXTURE_ORDER_REF && ext) {
      return { ...r, body: { ...r.body, ref: onecRefFor(ext), number: onecNumberFor(ext), externalId: ext } };
    }
    return r;
  }
}

export class OrdersTestApp extends PosTestApp {
  override readonly onec = new OrdersOnecGateway();
}

export interface TestCart {
  readonly cartId: string;
  rowVersion: number;
  readonly ownerUserId: string;
  customerId: string | null;
  manualDiscountPercent: string;
  lines: CheckoutLineSnapshot[];
  status: 'active' | 'converted';
  conflicts: CheckoutConflict[];
  /** `ok` — /check выполнен; `unavailable` — 1С недоступна; `rejected` — отказ /check; `gateway` — вызвать фейк 1С. */
  onec: 'ok' | 'unavailable' | 'rejected' | 'gateway';
}

/** Заглушка `CartReader` с реальными ценами каталога (снимок для `order_items`) — только тестовые данные. */
export class TestCartReader implements CartReader {
  readonly carts = new Map<string, TestCart>();
  readonly converted: { cartId: string; orderId: string }[] = [];
  readonly restored: { orderId: string; ownerUserId: string; forceParked?: boolean }[] = [];
  /** Сбой `markConverted` (проверка атомарности транзакции заказа). */
  failConvert = false;

  constructor(
    private readonly t: PosTestApp,
    private readonly checkTimeoutMs: () => number,
  ) {}

  async create(
    owner: Pick<PosActor, 'userId'>,
    items: readonly { readonly variantId: string; readonly quantity: string }[],
    opts: { customerId?: string | null; manualDiscountPercent?: string; onec?: TestCart['onec'] } = {},
  ): Promise<TestCart> {
    const cart: TestCart = {
      cartId: randomUUID(),
      rowVersion: 1,
      ownerUserId: owner.userId,
      customerId: opts.customerId ?? null,
      manualDiscountPercent: opts.manualDiscountPercent ?? '0.00',
      lines: [],
      status: 'active',
      conflicts: [],
      onec: opts.onec ?? 'ok',
    };
    cart.lines = await this.price(items, cart.manualDiscountPercent, cart.customerId);
    this.carts.set(cart.cartId, cart);
    return cart;
  }

  private async price(
    items: readonly { readonly variantId: string; readonly quantity: string }[],
    manual: string,
    customerId: string | null,
  ): Promise<CheckoutLineSnapshot[]> {
    const pl = await this.t.defaultPriceListId();
    const info = await this.t.q<{
      variant_id: string;
      product_id: string;
      product_name: string;
      unit_code: string;
      price: string;
    }>(
      `SELECT v.id AS variant_id, p.id AS product_id, p.name AS product_name, u.code AS unit_code, pr.price::text AS price
         FROM product_variants v JOIN products p ON p.id = v.product_id JOIN units u ON u.id = p.base_unit_id
         JOIN prices pr ON pr.variant_id = v.id AND pr.price_list_id = $2::uuid AND pr.packaging_id IS NULL
        WHERE v.id = ANY($1::uuid[])`,
      [items.map((i) => i.variantId), pl],
    );
    const byId = new Map(info.map((r) => [r.variant_id, r]));
    const custDisc = customerId
      ? ((
          await this.t.q<{ d: string | null }>(`SELECT discount_percent::text AS d FROM customers WHERE id = $1`, [
            customerId,
          ])
        )[0]?.d ?? null)
      : null;
    const priced = priceCart({
      lines: items.map((i, idx) => ({
        lineNo: idx + 1,
        variantId: i.variantId,
        packagingId: null,
        quantity: Quantity.of(i.quantity),
        unitPrice: Money.of(byId.get(i.variantId)!.price),
      })),
      customerDiscountPercent: custDisc,
      manualDiscountPercent: manual,
    });
    return priced.lines.map((l) => {
      const r = byId.get(l.variantId)!;
      return {
        lineNo: l.lineNo,
        variantId: l.variantId,
        productId: r.product_id,
        packagingId: null,
        quantity: l.quantity.toString(),
        baseQuantity: l.quantity.toString(),
        unitPrice: l.unitPrice.toString(),
        lineSubtotal: l.lineSubtotal.toString(),
        customerDiscountAmount: l.customerDiscountAmount.toString(),
        manualDiscountAmount: l.manualDiscountAmount.toString(),
        discountAmount: l.discountAmount.toString(),
        lineTotal: l.lineTotal.toString(),
        unitCode: r.unit_code,
        packagingName: null,
        packagingFactor: null,
        productName: r.product_name,
        variantName: null,
        sku: null,
        barcode: null,
      };
    });
  }

  /** Изменение корзины (новая версия). */
  bump(cart: TestCart): void {
    cart.rowVersion += 1;
  }

  async validateForCheckout(
    _tx: SalesTx | null,
    actor: SalesActor,
    input: CheckoutValidationInput,
  ): Promise<CheckoutValidation> {
    const cart = input.cartId ? this.carts.get(input.cartId) : undefined;
    if (!cart || cart.ownerUserId !== actor.userId || cart.status !== 'active') {
      throw new ProblemException('NOT_FOUND', { detail: 'Корзина не найдена.' });
    }
    if (cart.lines.length === 0) throw new ProblemException('CART_EMPTY', { detail: 'Корзина пуста.' });
    let onecCheck: CheckoutValidation['onecCheck'];
    if (cart.onec === 'gateway') {
      try {
        await this.t.onec.checkCart({ lines: [] }, { signal: AbortSignal.timeout(this.checkTimeoutMs()) });
        onecCheck = { performed: true, at: new Date(), result: 'ok' };
      } catch {
        onecCheck = { performed: false, at: null, result: 'unavailable' };
      }
    } else {
      onecCheck = {
        performed: cart.onec !== 'unavailable',
        at: cart.onec === 'unavailable' ? null : new Date(),
        result: cart.onec,
      };
    }
    const sum = (k: keyof CheckoutLineSnapshot) =>
      cart.lines.reduce((a, l) => a.plus(Money.of(String(l[k]))), Money.ZERO).toString();
    const subtotal = sum('lineSubtotal');
    const customerDiscountTotal = sum('customerDiscountAmount');
    const manualDiscountTotal = sum('manualDiscountAmount');
    const discountTotal = sum('discountAmount');
    const total = sum('lineTotal');
    return {
      ok: cart.conflicts.length === 0,
      conflicts: cart.conflicts,
      cart: {
        cartId: cart.cartId,
        rowVersion: cart.rowVersion,
        ownerUserId: cart.ownerUserId,
        customerId: cart.customerId,
        warehouseId: await this.t.defaultWarehouseId(),
        priceListId: await this.t.defaultPriceListId(),
        customerDiscountPercent: '0.00',
        manualDiscountPercent: cart.manualDiscountPercent,
        // Как корзина этапа F: подтверждение сверх лимита из этого запроса (step-up проверен) применено — подтверждающий
        // и причина в снимке (контракт CartReader; ревью G-credit-5).
        discountApprovedByUserId: input.discountOverride && input.stepUpVerified ? actor.userId : null,
        discountOverrideReason: input.discountOverride && input.stepUpVerified ? input.discountOverride.reason : null,
        subtotal,
        customerDiscountTotal,
        manualDiscountTotal,
        discountTotal,
        total,
        lines: cart.lines,
      },
      allowedPaymentMethods: actor.isCustomer
        ? this.t.config.QR_PROVIDER === 'none'
          ? ['cash']
          : ['cash', 'qr_bakai']
        : ['cash', 'qr_bakai', 'credit'],
      onecCheck,
      credit: null,
      warnings: [],
    };
  }

  markConverted(_tx: SalesTx, input: { cartId: string; expectedRowVersion: number; orderId: string }): Promise<void> {
    const cart = this.carts.get(input.cartId);
    if (this.failConvert) return Promise.reject(new Error('сбой markConverted (тест)'));
    if (!cart || cart.rowVersion !== input.expectedRowVersion || cart.status !== 'active') {
      return Promise.reject(new ProblemException('VERSION_CONFLICT', { detail: 'Корзина изменилась.' }));
    }
    cart.status = 'converted';
    this.converted.push({ cartId: input.cartId, orderId: input.orderId });
    return Promise.resolve();
  }

  restoreFromOrder(
    _tx: SalesTx,
    input: { orderId: string; ownerUserId: string; forceParked?: boolean },
  ): Promise<{ cartId: string; status: 'active' | 'parked' }> {
    this.restored.push(input);
    return Promise.resolve({ cartId: randomUUID(), status: 'parked' });
  }

  /** Повтор/привязка отклонённого заказа (ORD-027): `modified` — восстановленная корзина «изменена» (тест). */
  releaseResult: 'none' | 'cleared' | 'modified' = 'none';
  readonly released: string[] = [];

  releaseRestored(
    _tx: SalesTx,
    input: { orderId: string },
  ): Promise<{ outcome: 'none' | 'cleared' | 'modified'; cartIds: string[] }> {
    if (this.releaseResult !== 'modified') this.released.push(input.orderId);
    return Promise.resolve({ outcome: this.releaseResult, cartIds: [] });
  }
}

/** `PaymentsPort` над таблицей `payments` в транзакции заказа (тестовая реализация, без QR-провайдера). */
export class DbPaymentsPort implements PaymentsPort {
  failNext = false;
  readonly afterCommitCalls: string[] = [];

  constructor(private readonly t: PosTestApp) {}

  async createInitial(tx: SalesTx, input: InitialPaymentInput): Promise<PaymentSummary> {
    if (this.failNext) {
      this.failNext = false;
      throw new Error('сбой создания платежа (тест)');
    }
    const status = initialPaymentStatus(input.method);
    const r = await tx.execute<{ id: string; public_number: string }>(sql`
      INSERT INTO payments (public_number, order_id, customer_id, method, qr_provider, status, amount, created_by_user_id,
                            idempotency_key)
      VALUES (next_payment_public_number(), -- генератор 07 §5.40 (FQ-PAY-02), как PaymentsRepository
              ${input.orderId}::uuid, ${input.customerId}::uuid, ${input.method}::payment_method,
              ${input.method === 'qr_bakai' ? this.t.config.QR_PROVIDER : null}, ${status}::payment_status,
              ${input.amount}::numeric, ${input.actor.userId}::uuid, ${input.idempotencyKey})
      RETURNING id, public_number`);
    const row = r.rows[0];
    return {
      paymentId: row.id,
      publicNumber: row.public_number,
      method: input.method,
      status,
      amount: Money.of(input.amount).toString(),
      receivedAt: null,
      reviewReason: null,
      qrProvider: input.method === 'qr_bakai' ? this.t.config.QR_PROVIDER : null,
    };
  }

  async afterCommit(paymentId: string): Promise<QrAfterCommitResult> {
    this.afterCommitCalls.push(paymentId);
    const [p] = await this.listBy(`id = $1`, [paymentId]);
    return { payment: p, warnings: [] };
  }

  listForOrder(orderId: string): Promise<readonly PaymentSummary[]> {
    return this.listBy(`order_id = $1`, [orderId]);
  }

  async receivedTotal(_tx: SalesTx | null, orderId: string): Promise<string> {
    const r = await this.t.q<{ s: string | null }>(
      `SELECT sum(amount)::text AS s FROM payments WHERE order_id = $1 AND status = 'received'`,
      [orderId],
    );
    return Money.of(r[0]?.s ?? '0').toString();
  }

  async voidOpenForOrderCancel(tx: SalesTx, input: { orderId: string }): Promise<readonly string[]> {
    const r = await tx.execute<{ id: string }>(sql`
      UPDATE payments SET status = 'voided', voided_at = now(), void_reason = 'order_cancelled'
       WHERE order_id = ${input.orderId}::uuid
         AND status IN ('cash_pending','qr_pending','qr_shown','qr_expired','manual_confirm')
      RETURNING id`);
    return r.rows.map((x) => x.id);
  }

  private async listBy(where: string, params: unknown[]): Promise<PaymentSummary[]> {
    const rows = await this.t.q<{
      id: string;
      public_number: string;
      method: PaymentSummary['method'];
      status: PaymentSummary['status'];
      amount: string;
      received_at: Date | null;
      review_reason: PaymentSummary['reviewReason'];
      qr_provider: PaymentSummary['qrProvider'];
    }>(
      `SELECT id, public_number, method::text AS method, status::text AS status, amount::text AS amount, received_at,
              review_reason, qr_provider FROM payments WHERE ${where} ORDER BY created_at`,
      params,
    );
    return rows.map((p) => ({
      paymentId: p.id,
      publicNumber: p.public_number,
      method: p.method,
      status: p.status,
      amount: p.amount,
      receivedAt: p.received_at,
      reviewReason: p.review_reason,
      qrProvider: p.qr_provider,
    }));
  }
}

/** Публикации воркера в транзакции результата (`orders.onec-confirmed|failed`). */
export interface Published {
  readonly name: string;
  readonly data: Record<string, unknown>;
}

export interface OrdersHarness {
  readonly t: OrdersTestApp;
  readonly cart: TestCartReader;
  readonly payments: DbPaymentsPort;
  readonly dispatcher: OutboxDispatcher;
  readonly results: OrderOnecResultsHandler;
  readonly statusSync: OrderStatusSyncHandler;
  readonly published: Published[];
  readonly dead: { outboxId: string; reason: string }[];
  /** Тик диспетчера + обработка опубликованных результатов (как `pos-worker`). */
  drain(): Promise<{ claimed: number; sent: number; retried: number; failed: number; dead: number }>;
  /** Сделать `pending` строки готовыми к захвату (вместо ожидания backoff). */
  makeDue(): Promise<void>;
}

export async function startOrders(
  opts: PosFixtureOptions & { outbox?: { maxAttempts?: number } } = {},
): Promise<OrdersHarness> {
  const t = new OrdersTestApp();
  await t.start({ ...opts, modules: opts.modules ?? [OrdersModule], fakePorts: true });
  const cart = new TestCartReader(t, () => t.config.ONEC_SYNC_CHECK_TIMEOUT_MS);
  const payments = new DbPaymentsPort(t);
  t.replacePort(CART_READER, cart);
  t.replacePort(PAYMENTS_PORT, payments);
  const published: Published[] = [];
  const dead: { outboxId: string; reason: string }[] = [];
  const log = pino({ level: 'silent' });
  const notifications = t.fakes!.notifications;
  const results = new OrderOnecResultsHandler({ db: t.db, notifications, cart, payments, log });
  const cfg = schedulerConfigFromEnv(t.config, { outbox: { ...(opts.outbox ?? {}) } }).outbox;
  const dispatcher = new OutboxDispatcher(
    t.pool,
    new OnecOutboxDelivery(t.onec, { timeoutMs: t.config.ONEC_SYNC_CHECK_TIMEOUT_MS }),
    {
      send: (name: string, data: object) => {
        published.push({ name, data: data as Record<string, unknown> });
        return Promise.resolve(randomUUID());
      },
    },
    cfg,
    'test-worker',
    log,
    {
      onDead: async (row, info) => {
        dead.push({ outboxId: row.id, reason: info.reason });
        await results.onDead(row, `${info.code}: ${info.reason}`);
      },
    },
  );
  const statusSync = new OrderStatusSyncHandler({
    db: t.db,
    gateway: t.onec,
    notifications,
    payments,
    log,
    timeoutMs: t.config.ONEC_SYNC_CHECK_TIMEOUT_MS,
  });
  let handled = 0;
  return {
    t,
    cart,
    payments,
    dispatcher,
    results,
    statusSync,
    published,
    dead,
    async drain() {
      const r = await dispatcher.tick();
      while (handled < published.length) {
        const p = published[handled++];
        if (p.name === 'orders.onec-confirmed') await results.onConfirmed(p.data as never);
        if (p.name === 'orders.onec-failed') await results.onFailed(p.data as never);
      }
      return r;
    },
    async makeDue() {
      await t.pool.query(
        `UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE status = 'pending'`,
      );
    },
  };
}

/** Тело `POST /orders` по тестовой корзине (без цен — их считает сервер). */
export function orderBody(cart: TestCart, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    cartId: cart.cartId,
    cartRowVersion: cart.rowVersion,
    receiver: { kind: 'customer' },
    delivery: { method: 'pickup' },
    paymentMethod: 'cash',
    items: cart.lines.map((l) => ({
      variantId: l.variantId,
      quantity: { value: l.quantity, unitId: randomUUID(), packagingId: null },
    })),
    ...extra,
  };
}

/** Тело `Order` в ответе API (поля, которые проверяют тесты). */
export interface OrderDto {
  readonly id: string;
  readonly status: string;
  readonly createdVia: string;
  readonly total: { readonly amount: string };
  readonly payments: readonly { readonly id: string; readonly method: string; readonly status: string }[];
  readonly [field: string]: unknown;
}

/** Идентификаторы элементов страницы (`Page<…>.items`). */
export function ids(body: unknown): string[] {
  return ((body as { items: { id: string }[] }).items ?? []).map((x) => x.id);
}

export { RETAIL_CUSTOMER_ID };

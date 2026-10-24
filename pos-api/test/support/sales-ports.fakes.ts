import { randomUUID } from 'node:crypto';
import type {
  CartReader,
  CatalogPricingPort,
  CheckoutValidation,
  CheckoutValidationInput,
  DocumentsPort,
  InitialPaymentInput,
  InventoryCheckOutcome,
  InventoryCheckPort,
  NotificationInput,
  NotificationsPort,
  OnecOutboxWriter,
  OrderCreator,
  OrderPaymentView,
  OrderStatusPort,
  OutboxEnqueueInput,
  OutboxItemView,
  PaymentsPort,
  PaymentSummary,
  SalesActor,
  SalesPortMap,
  SalesPortToken,
  VariantQuote,
} from '../../src/common/ports/index.js';
import {
  CART_READER,
  CATALOG_PRICING_PORT,
  DOCUMENTS_PORT,
  INVENTORY_CHECK_PORT,
  NOTIFICATIONS_PORT,
  ONEC_OUTBOX_WRITER,
  ORDER_CREATOR,
  ORDER_STATUS_PORT,
  PAYMENTS_PORT,
  SalesPortRegistry,
} from '../../src/common/ports/index.js';
import { Money } from '../../src/common/money/money.js';
import { createSalesPortRegistry } from '../../src/sales-domain/sales-ports.module.js';
import { initialPaymentStatus } from '../../src/sales-domain/payment/payment-status.js';
import { assertOutboxTransition } from '../../src/sales-domain/outbox/outbox-status.js';

/**
 * Заглушки портов этапа F для unit/e2e тестов агентов (in-memory, без БД; **тестовые данные**). Каждая хранит журнал
 * вызовов, чтобы тест проверял взаимодействие. Подключение в Nest: `registry.replace(TOKEN, fake)` или
 * `createFakeSalesRegistry({...})`.
 */

export class InMemoryNotifications implements NotificationsPort {
  readonly items: (NotificationInput & { id: string })[] = [];

  notify(_tx: unknown, input: NotificationInput): Promise<{ id: string; created: boolean }> {
    const dup = this.items.find((n) => n.userId === input.userId && n.dedupeKey === input.dedupeKey);
    if (dup) return Promise.resolve({ id: dup.id, created: false });
    const id = randomUUID();
    this.items.push({ ...input, id });
    return Promise.resolve({ id, created: true });
  }

  /** `userIds` для роли задаёт тест (`roleMembers`). */
  readonly roleMembers = new Map<string, string[]>();

  async notifyRole(tx: unknown, role: string, input: Omit<NotificationInput, 'userId'>): Promise<string[]> {
    const ids: string[] = [];
    for (const userId of this.roleMembers.get(role) ?? []) ids.push((await this.notify(tx, { ...input, userId })).id);
    return ids;
  }

  of(userId: string): readonly NotificationInput[] {
    return this.items.filter((n) => n.userId === userId);
  }
}

interface OutboxRowFake extends OutboxItemView {
  readonly input: OutboxEnqueueInput;
}

/** In-memory `onec_outbox` с проверкой переходов по автомату 07 §6.5. */
export class InMemoryOutboxWriter implements OnecOutboxWriter {
  readonly rows: OutboxRowFake[] = [];
  kicks = 0;

  enqueue(_tx: unknown, input: OutboxEnqueueInput): Promise<OutboxItemView> {
    const existing = this.rows.find(
      (r) =>
        r.input.aggregateType === input.aggregateType &&
        r.input.aggregateId === input.aggregateId &&
        r.input.operation === input.operation,
    );
    if (existing) return Promise.resolve(view(existing));
    const row: OutboxRowFake = { outboxId: randomUUID(), status: 'pending', attempts: 0, onecRef: null, input };
    this.rows.push(row);
    return Promise.resolve(view(row));
  }

  lock(
    _tx: unknown,
    key: { aggregateType: string; aggregateId: string; operation: 'create' | 'cancel' },
  ): Promise<OutboxItemView | null> {
    const r = this.rows.find(
      (x) =>
        x.input.aggregateType === key.aggregateType &&
        x.input.aggregateId === key.aggregateId &&
        x.input.operation === key.operation,
    );
    return Promise.resolve(r ? view(r) : null);
  }

  cancel(_tx: unknown, outboxId: string): Promise<void> {
    this.update(outboxId, (r) => {
      assertOutboxTransition(r.status, 'cancelled', 'aggregate_cancelled');
      return { ...r, status: 'cancelled' };
    });
    return Promise.resolve();
  }

  requeue(
    _tx: unknown,
    input: { outboxId: string; payload?: Readonly<Record<string, unknown>> },
  ): Promise<OutboxItemView> {
    this.update(input.outboxId, (r) => {
      assertOutboxTransition(r.status, 'pending', 'manual_retry');
      return {
        ...r,
        status: 'pending',
        attempts: 0,
        input: input.payload ? { ...r.input, payload: input.payload } : r.input,
      };
    });
    const row = this.rows.find((r) => r.outboxId === input.outboxId)!;
    return Promise.resolve(view(row));
  }

  markSentManually(_tx: unknown, input: { outboxId: string; onecRef: string }): Promise<void> {
    this.update(input.outboxId, (r) => {
      assertOutboxTransition(r.status, 'sent', 'manual_link');
      return { ...r, status: 'sent', onecRef: input.onecRef };
    });
    return Promise.resolve();
  }

  kickAfterCommit(): Promise<void> {
    this.kicks += 1;
    return Promise.resolve();
  }

  /** Тестовое изменение состояния строки (имитация воркера). */
  setState(outboxId: string, patch: Partial<Pick<OutboxItemView, 'status' | 'attempts' | 'onecRef'>>): void {
    this.update(outboxId, (r) => ({ ...r, ...patch }));
  }

  private update(id: string, fn: (r: OutboxRowFake) => OutboxRowFake): void {
    const i = this.rows.findIndex((r) => r.outboxId === id);
    if (i < 0) throw new Error(`outbox ${id} не найден`);
    this.rows[i] = fn(this.rows[i]);
  }
}

function view(r: OutboxRowFake): OutboxItemView {
  return { outboxId: r.outboxId, status: r.status, attempts: r.attempts, onecRef: r.onecRef };
}

/** Заглушка `PaymentsPort`: начальный платёж в статусе по способу (`initialPaymentStatus`), без БД. */
export class StubPaymentsPort implements PaymentsPort {
  readonly payments: (PaymentSummary & { orderId: string; idempotencyKey: string })[] = [];
  private seq = 0;

  createInitial(_tx: unknown, input: InitialPaymentInput): Promise<PaymentSummary> {
    this.seq += 1;
    const p = {
      paymentId: randomUUID(),
      publicNumber: `PAY-2026-${String(this.seq).padStart(6, '0')}`,
      method: input.method,
      status: initialPaymentStatus(input.method),
      amount: Money.of(input.amount).toString(),
      receivedAt: null,
      reviewReason: null,
      qrProvider: input.method === 'qr_bakai' ? ('none' as const) : null,
      orderId: input.orderId,
      idempotencyKey: input.idempotencyKey,
    };
    this.payments.push(p);
    return Promise.resolve(p);
  }

  afterCommit(paymentId: string): Promise<{ payment: PaymentSummary; warnings: [] }> {
    const p = this.payments.find((x) => x.paymentId === paymentId);
    if (!p) return Promise.reject(new Error(`payment ${paymentId} не найден`));
    return Promise.resolve({ payment: p, warnings: [] });
  }

  listForOrder(orderId: string): Promise<PaymentSummary[]> {
    return Promise.resolve(this.payments.filter((p) => p.orderId === orderId));
  }

  receivedTotal(_tx: unknown, orderId: string): Promise<string> {
    return Promise.resolve(
      this.payments
        .filter((p) => p.orderId === orderId && p.status === 'received')
        .reduce((a, p) => a.plus(Money.of(p.amount)), Money.ZERO)
        .toString(),
    );
  }

  voidOpenForOrderCancel(_tx: unknown, input: { orderId: string }): Promise<string[]> {
    const ids: string[] = [];
    for (const p of this.payments) {
      if (
        p.orderId === input.orderId &&
        ['cash_pending', 'qr_pending', 'qr_shown', 'qr_expired', 'manual_confirm'].includes(p.status)
      ) {
        (p as { status: string }).status = 'voided';
        ids.push(p.paymentId);
      }
    }
    return Promise.resolve(ids);
  }
}

/** Заглушка `OrderStatusPort` над картой заказов (тест платежей без модуля orders). */
export class StubOrderStatusPort implements OrderStatusPort {
  readonly orders = new Map<string, OrderPaymentView>();
  readonly received: { orderId: string; amount: string; paymentId: string }[] = [];

  lockForPayment(_tx: unknown, orderId: string): Promise<OrderPaymentView | null> {
    return Promise.resolve(this.orders.get(orderId) ?? null);
  }

  applyReceived(
    _tx: unknown,
    input: { orderId: string; amount: string; paymentId: string; actor: SalesActor },
  ): Promise<{ paidAt: Date | null; statusChange: null }> {
    const o = this.orders.get(input.orderId);
    if (!o) return Promise.reject(new Error(`order ${input.orderId} не найден`));
    this.received.push({ orderId: input.orderId, amount: input.amount, paymentId: input.paymentId });
    const paid = Money.of(o.paidAmount).plus(Money.of(input.amount));
    const firstPaid = !o.isPaid && paid.compare(Money.of(o.total)) >= 0;
    this.orders.set(input.orderId, { ...o, paidAmount: paid.toString(), isPaid: paid.compare(Money.of(o.total)) >= 0 });
    return Promise.resolve({ paidAt: firstPaid ? new Date() : null, statusChange: null });
  }

  recompute(): Promise<null> {
    return Promise.resolve(null);
  }

  onOutboxRetry(): Promise<void> {
    return Promise.resolve();
  }
}

/** Заглушка `CartReader`: возвращает заданный результат проверки (`result`), фиксирует конвертации. */
export class StubCartReader implements CartReader {
  result: CheckoutValidation | null = null;
  readonly converted: { cartId: string; orderId: string }[] = [];
  readonly restored: { orderId: string; ownerUserId: string }[] = [];

  validateForCheckout(_tx: unknown, _actor: SalesActor, _input: CheckoutValidationInput): Promise<CheckoutValidation> {
    if (!this.result) return Promise.reject(new Error('StubCartReader.result не задан'));
    return Promise.resolve(this.result);
  }

  markConverted(_tx: unknown, input: { cartId: string; expectedRowVersion: number; orderId: string }): Promise<void> {
    this.converted.push({ cartId: input.cartId, orderId: input.orderId });
    return Promise.resolve();
  }

  restoreFromOrder(
    _tx: unknown,
    input: { orderId: string; ownerUserId: string },
  ): Promise<{ cartId: string; status: 'parked' }> {
    this.restored.push(input);
    return Promise.resolve({ cartId: randomUUID(), status: 'parked' });
  }

  releaseRestored(): Promise<{ outcome: 'none'; cartIds: string[] }> {
    return Promise.resolve({ outcome: 'none', cartIds: [] });
  }
}

export class StubDocumentsPort implements DocumentsPort {
  availability(
    orderId: string,
  ): Promise<{ invoice: string; receipt: null; waybill: { available: false; reason: string } }> {
    return Promise.resolve({
      invoice: `/api/v1/orders/${orderId}/documents/invoice.pdf`,
      receipt: null,
      waybill: { available: false, reason: 'waybill_from_onec' },
    });
  }

  render(
    kind: 'invoice' | 'receipt',
    orderId: string,
  ): Promise<{ contentType: 'application/pdf'; fileName: string; body: Buffer }> {
    return Promise.resolve({
      contentType: 'application/pdf',
      fileName: `${kind}-${orderId}.pdf`,
      body: Buffer.from('%PDF-1.3\n%stub\n'),
    });
  }
}

/** Заглушка `InventoryCheckPort`: нехватки/недоступные варианты задаёт тест. */
export class StubInventoryCheck implements InventoryCheckPort {
  outcome: InventoryCheckOutcome = { ok: true, shortages: [], unavailable: [] };
  readonly calls: unknown[] = [];

  check(_actor: SalesActor, input: unknown): Promise<InventoryCheckOutcome> {
    this.calls.push(input);
    return Promise.resolve(this.outcome);
  }
}

/** Заглушка `CatalogPricingPort`: котировки по `variantId` задаёт тест. */
export class StubCatalogPricing implements CatalogPricingPort {
  priceListId: string | null = '00000000-0000-7000-8000-000000000101';
  readonly quotes = new Map<string, VariantQuote>();

  resolvePriceList(): Promise<string | null> {
    return Promise.resolve(this.priceListId);
  }

  quote(
    _tx: unknown,
    input: { items: readonly { variantId: string; packagingId: string | null }[] },
  ): Promise<VariantQuote[]> {
    return Promise.resolve(
      input.items.map((i) => {
        const q = this.quotes.get(i.variantId);
        if (!q) throw new Error(`StubCatalogPricing: нет котировки ${i.variantId}`);
        return q;
      }),
    );
  }
}

export class StubOrderCreator implements OrderCreator {
  createFromCart(): Promise<never> {
    return Promise.reject(new Error('StubOrderCreator: задайте реализацию в тесте'));
  }
}

export interface FakeSalesPorts {
  readonly registry: SalesPortRegistry;
  readonly notifications: InMemoryNotifications;
  readonly outbox: InMemoryOutboxWriter;
  readonly payments: StubPaymentsPort;
  readonly orders: StubOrderStatusPort;
  readonly cart: StubCartReader;
  readonly documents: StubDocumentsPort;
  readonly inventory: StubInventoryCheck;
  readonly pricing: StubCatalogPricing;
}

/**
 * Реестр со всеми заглушками (долг — fail-closed по умолчанию). `keep` — токены, которые НЕ подменять (например,
 * свой порт, привязанный модулем под тестом).
 */
export function createFakeSalesRegistry(
  registry: SalesPortRegistry = createSalesPortRegistry(),
  keep: readonly SalesPortToken[] = [],
): FakeSalesPorts {
  const ports = {
    notifications: new InMemoryNotifications(),
    outbox: new InMemoryOutboxWriter(),
    payments: new StubPaymentsPort(),
    orders: new StubOrderStatusPort(),
    cart: new StubCartReader(),
    documents: new StubDocumentsPort(),
    inventory: new StubInventoryCheck(),
    pricing: new StubCatalogPricing(),
  };
  const put = <K extends SalesPortToken>(token: K, impl: SalesPortMap[K]) => {
    if (!keep.includes(token)) registry.replace(token, impl);
  };
  put(NOTIFICATIONS_PORT, ports.notifications);
  put(ONEC_OUTBOX_WRITER, ports.outbox);
  put(PAYMENTS_PORT, ports.payments);
  put(ORDER_STATUS_PORT, ports.orders);
  put(ORDER_CREATOR, new StubOrderCreator());
  put(CART_READER, ports.cart);
  put(DOCUMENTS_PORT, ports.documents);
  put(INVENTORY_CHECK_PORT, ports.inventory);
  put(CATALOG_PRICING_PORT, ports.pricing);
  return { registry, ...ports };
}

export { SalesPortRegistry };

import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CartModule } from '../../src/cart/cart.module.js';
import { CREDIT_DECISION_SERVICE, ORDER_CREATOR, PAYMENTS_PORT } from '../../src/common/ports/index.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import type { PosActor } from '../support/pos-fixture.js';
import { DbPaymentsPort, OrdersTestApp } from './support/orders-fixture.js';

type Cart = { id: string; rowVersion: number; items: unknown[] };
type V = { variantId: string; unitId: string };

/**
 * Сценарии 12 этапа F, которых не было в наборах cart/orders (ревью F-trace-1, раунд 2) — **тестовые данные**:
 * embedded PostgreSQL 17, синтетический каталог, реальная корзина (`CartModule`) и заказы (`OrdersModule`).
 * - T-CART-009 (в), T-CART-021: прямой `POST /orders` по пустой серверной корзине → `422 CART_EMPTY`, заказа нет;
 * - T-ORD-005: адрес доставки 300 символов принимается, 301 → `400 VALIDATION_FAILED` (`checkout-preview` и
 *   `POST /orders`), комментарий курьеру 201 → 400;
 * - T-DISC-010: смена клиента сохраняет ручную скидку, скидка клиента пересчитывается;
 * - T-DISC-002: одна ручная скидка в % на документ: 5 % → 200, 12,345 % → 400 (не более 2 знаков, MV-26);
 * - T-ORD-026, T-SEC-041 (часть «PUT/PATCH»): изменить созданный заказ, платёж или журнал операций нельзя —
 *   маршрутов `PUT/PATCH /orders/{id}`, `/payments/{id}`, `/transactions/{id}` нет (404/405), заказ не изменён.
 */
describe('этап F: недостающие сценарии 12 (корзина → заказ)', () => {
  const t = new OrdersTestApp();
  let seller: PosActor;
  let variants: V[];

  beforeAll(async () => {
    await t.start({ modules: [CartModule, OrdersModule], fakePorts: true, env: { ONEC_SYNC_CHECK_TIMEOUT_MS: '700' } });
    t.replacePort(PAYMENTS_PORT, new DbPaymentsPort(t));
    seller = await t.actor({ role: 'seller' });
    variants = await t.saleableVariants(6);
  });
  afterAll(async () => {
    await t.stop();
  });

  const current = async (actor: PosActor) => {
    const r = await t.req('get', '/cart', actor);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return r.body as Cart;
  };
  async function put(actor: PosActor, v: V, value: string): Promise<Cart> {
    const before = await current(actor);
    const r = await t.req('put', `/cart/items/${v.variantId}`, actor).send({
      quantity: { value, unitId: v.unitId, packagingId: null },
      rowVersion: before.rowVersion,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return r.body as Cart;
  }
  const orderBody = (cart: Cart, v: V, qty: string, extra: Record<string, unknown> = {}) => ({
    cartId: cart.id,
    cartRowVersion: cart.rowVersion,
    receiver: { kind: 'customer' },
    delivery: { method: 'pickup' },
    paymentMethod: 'cash',
    items: [{ variantId: v.variantId, quantity: { value: qty, unitId: v.unitId, packagingId: null } }],
    ...extra,
  });
  const ordersOf = async (cartId: string) =>
    (await t.q<{ n: string }>(`SELECT count(*)::text AS n FROM orders WHERE cart_id = $1`, [cartId]))[0].n;

  // T-CART-009 (в), T-CART-021: CART_EMPTY при прямом вызове — корзина на сервере пуста (очищена на другом устройстве).
  it('T-CART-009 (в), T-CART-021: POST /orders по пустой серверной корзине → 422 CART_EMPTY, заказа нет', async () => {
    const s = await t.actor({ role: 'seller' });
    const v = variants[0];
    const filled = await put(s, v, '1');
    const cleared = await t.req('delete', `/cart?rowVersion=${filled.rowVersion}`, s);
    expect(cleared.status, JSON.stringify(cleared.body)).toBe(200);
    const empty = await current(s);
    expect(empty.items).toHaveLength(0);
    const res = await t.req('post', '/orders', s, { idem: true }).send(orderBody(empty, v, '1'));
    expect(res.status, JSON.stringify(res.body)).toBe(422);
    expect(res.body.code).toBe('CART_EMPTY');
    expect(await ordersOf(empty.id)).toBe('0');
    const preview = await t.req('post', '/cart/checkout-preview', s).send({
      cartId: empty.id,
      cartRowVersion: empty.rowVersion,
      paymentMethod: 'cash',
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
    });
    expect(preview.status).toBe(422);
    expect(preview.body.code).toBe('CART_EMPTY');
  });

  // T-ORD-005: адрес ≤ 300, комментарий курьеру ≤ 200 (08 §4.8.1; 10 ORD-021).
  it('T-ORD-005: доставка — адрес 300 символов принимается, 301 → 400; комментарий 201 → 400 (preview и POST /orders)', async () => {
    const s = await t.actor({ role: 'seller' });
    const v = variants[1];
    const cart = await put(s, v, '1');
    const delivery = (address: string, courierComment = 'Позвонить за час') => ({
      method: 'delivery',
      address,
      recipientPhone: '+996555123456',
      courierComment,
      desiredDate: '2026-10-30',
      timeFrom: '10:00',
      timeTo: '12:00',
    });
    const preview = (d: Record<string, unknown>) =>
      t.req('post', '/cart/checkout-preview', s).send({
        cartId: cart.id,
        cartRowVersion: cart.rowVersion,
        paymentMethod: 'cash',
        receiver: { kind: 'customer' },
        delivery: d,
      });
    const ok = await preview(delivery('а'.repeat(300)));
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    const long = await preview(delivery('а'.repeat(301)));
    expect(long.status).toBe(400);
    expect(long.body.code).toBe('VALIDATION_FAILED');
    expect(long.body.errors).toEqual(
      expect.arrayContaining([expect.objectContaining({ field: 'delivery.address', rule: 'max_length' })]),
    );
    const comment = await preview(delivery('ул. Токтогула, 1', 'к'.repeat(201)));
    expect(comment.status).toBe(400);
    expect(comment.body.errors).toEqual(
      expect.arrayContaining([expect.objectContaining({ field: 'delivery.courierComment' })]),
    );
    const order = await t
      .req('post', '/orders', s, { idem: true })
      .send(orderBody(cart, v, '1', { delivery: delivery('а'.repeat(301)) }));
    expect(order.status).toBe(400);
    expect(order.body.code).toBe('VALIDATION_FAILED');
    expect(await ordersOf(cart.id)).toBe('0');
  });

  // T-ORD-008 (часть backend): выбор печати после создания — `printOptions` заказа (08 §4.8.1; 10 ORD-009, PRINT-009):
  // отмеченные «счёт»/«товарный чек» сохраняются в заказе, неуказанные — по умолчанию true; без printOptions — всё
  // true. Накладная — «из 1С» (`available: false`, PRINT-004) — documents.e2e; чекбоксы на устройстве — pos-app.
  it('T-ORD-008: printOptions заказа — {invoice, receipt} из тела, waybill по умолчанию; без тела — все true', async () => {
    const s = await t.actor({ role: 'seller' });
    const v = variants[5];
    const c1 = await put(s, v, '1');
    const r1 = await t
      .req('post', '/orders', s, { idem: true })
      .send(orderBody(c1, v, '1', { printOptions: { invoice: true, receipt: false } }));
    expect(r1.status, JSON.stringify(r1.body)).toBeLessThan(300);
    expect(r1.body.printOptions).toEqual({ invoice: true, waybill: true, receipt: false });
    const got = await t.req('get', `/orders/${r1.body.id}`, s);
    expect(got.body.printOptions).toEqual({ invoice: true, waybill: true, receipt: false });
    const c2 = await put(s, v, '2');
    const r2 = await t
      .req('post', '/orders', s, { idem: true })
      .send(orderBody(c2, v, '2', { confirmDuplicate: true }));
    expect(r2.status, JSON.stringify(r2.body)).toBeLessThan(300);
    expect(r2.body.printOptions).toEqual({ invoice: true, waybill: true, receipt: true });
  });

  // T-DISC-002: одна ручная скидка в процентах на документ; не более 2 знаков (10 DISC-002; MV-26).
  it('T-DISC-002: POST /cart/discount 5 % → 200 (одна скидка на документ); 12,345 % → 400, корзина не изменена', async () => {
    const s = await t.actor({ role: 'seller' });
    const cart = await put(s, variants[2], '2');
    const bad = await t.req('post', '/cart/discount', s).send({ percent: '12.345', rowVersion: cart.rowVersion });
    expect(bad.status).toBe(400);
    expect(bad.body.code).toBe('VALIDATION_FAILED');
    expect(bad.body.errors[0]).toMatchObject({ field: 'percent', rule: 'percent_range' });
    expect((await current(s)).rowVersion).toBe(cart.rowVersion);
    const ok = await t.req('post', '/cart/discount', s).send({ percent: '5.00', rowVersion: cart.rowVersion });
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body.appliedDiscountPercent).toBe('5.00');
    // Вторая скидка заменяет первую (одна ручная скидка на документ), а не складывается.
    const again = await t.req('post', '/cart/discount', s).send({ percent: '3.00', rowVersion: ok.body.rowVersion });
    expect(again.status, JSON.stringify(again.body)).toBe(200);
    expect(again.body).toMatchObject({ requestedDiscountPercent: '3.00', appliedDiscountPercent: '3.00' });
  });

  // T-DISC-010: смена клиента сохраняет ручную скидку (в лимите), скидка клиента пересчитывается (10 DISC-010).
  it('T-DISC-010: ручная 5 % → выбор клиента со скидкой 3 % → ручная сохранена, скидка клиента 3 %; снятие клиента — 0 %', async () => {
    const c = await t.actor({ role: 'cashier' });
    const cart = await put(c, variants[4], '2');
    const d = await t.req('post', '/cart/discount', c).send({ percent: '5.00', rowVersion: cart.rowVersion });
    expect(d.status, JSON.stringify(d.body)).toBe(200);
    const customerId = await t.createOnecCustomer({ discountPercent: '3.00', phoneE164: '+996555000777' });
    const set = await t
      .req('post', '/cart/customer', c)
      .send({ customerId, receiver: { kind: 'customer' }, rowVersion: d.body.rowVersion });
    expect(set.status, JSON.stringify(set.body)).toBe(200);
    expect(set.body).toMatchObject({
      customerDiscountPercent: '3.00',
      requestedDiscountPercent: '5.00',
      appliedDiscountPercent: '5.00',
    });
    const off = await t.req('delete', '/cart/customer', c);
    expect(off.status, JSON.stringify(off.body)).toBe(200);
    expect(off.body).toMatchObject({ customerDiscountPercent: '0.00', appliedDiscountPercent: '5.00' });
  });

  // RM-F-009 (ветви создания заказа, ревью F-trace-2): порт ORDER_CREATOR.createFromCart (06 §7.4) — внутренний
  // вызов без HTTP: минимальная команда (значения по умолчанию), полная команда (доставка, получатель, комментарий,
  // ручная скидка в лимите) и режим клиента (своя подтверждённая карточка или «Розничный покупатель»).
  it('ORDER_CREATOR.createFromCart: минимальная и полная команда; режим клиента', async () => {
    const creator = t.registry.get(ORDER_CREATOR);
    const s1 = await t.actor({ role: 'seller' });
    const c1 = await put(s1, variants[0], '1');
    const r1 = await creator.createFromCart({
      actor: { userId: s1.userId, roles: ['seller'], isCustomer: false },
      idempotencyKey: randomUUID(),
      cartRowVersion: c1.rowVersion,
      paymentMethod: 'cash',
      deliveryMethod: 'pickup',
    });
    expect([201, 202]).toContain(r1.httpStatus);
    expect(r1).toMatchObject({ status: 'submitting' });
    expect(r1.paymentId).not.toBeNull();
    expect(r1.publicNumber).toMatch(/^POS-\d{4}-\d{6}$/);
    const s2 = await t.actor({ role: 'seller' });
    const c2 = await put(s2, variants[1], '2');
    const r2 = await creator.createFromCart({
      actor: { userId: s2.userId, roles: ['seller'], isCustomer: false, requestId: randomUUID() },
      idempotencyKey: randomUUID(),
      cartRowVersion: c2.rowVersion,
      paymentMethod: 'cash',
      customerId: null,
      deliveryMethod: 'delivery',
      receiver: { kind: 'other_person', name: 'Получатель Тестовый', phoneE164: '+996555123457' },
      delivery: {
        address: 'г. Бишкек, ул. Тестовая, 1',
        phoneE164: '+996555123458',
        comment: 'Позвонить',
        date: '2026-10-30',
        timeFrom: '10:00',
        timeTo: '12:00',
      },
      comment: 'Заказ через порт',
      manualDiscountPercent: '2.00',
      discountOverride: null,
      creditOverride: null,
      confirmDuplicate: true,
    });
    expect([201, 202]).toContain(r2.httpStatus);
    const row = await t.q<{ delivery_method: string; manual_discount_total: string; comment: string }>(
      `SELECT delivery_method::text AS delivery_method, manual_discount_total::text AS manual_discount_total, comment
         FROM orders WHERE id = $1`,
      [r2.orderId],
    );
    expect(row[0]).toMatchObject({ delivery_method: 'delivery', comment: 'Заказ через порт' });
    expect(row[0].manual_discount_total).not.toBe('0.00');
    const cust = await t.actor({ role: 'customer' });
    const c3 = await put(cust, variants[2], '1');
    const r3 = await creator.createFromCart({
      actor: { userId: cust.userId, roles: ['customer'], isCustomer: true },
      idempotencyKey: randomUUID(),
      cartRowVersion: c3.rowVersion,
      paymentMethod: 'cash',
      deliveryMethod: 'pickup',
    });
    expect([201, 202]).toContain(r3.httpStatus);
    const via = await t.q<{ created_via: string }>(
      `SELECT created_via::text AS created_via FROM orders WHERE id = $1`,
      [r3.orderId],
    );
    expect(via[0].created_via).toBe('customer');
  });

  // RM-F-009 (ветви создания заказа): подтверждения сверх лимита в POST /orders — режим клиента, нет права, step-up.
  it('POST /orders: override в режиме клиента и без права → 403; creditOverride без step-up → STEP_UP_REQUIRED, со step-up — принят', async () => {
    const reason = { reason: 'Подтверждаю (тест)' };
    const cust = await t.actor({ role: 'customer' });
    const cc = await put(cust, variants[0], '1');
    const r1 = await t
      .req('post', '/orders', cust, { idem: true })
      .send(orderBody(cc, variants[0], '1', { discountOverride: reason }));
    expect(r1.status, JSON.stringify(r1.body)).toBe(403);
    const s = await t.actor({ role: 'seller' });
    const sc = await put(s, variants[1], '1');
    for (const extra of [{ discountOverride: reason }, { creditOverride: reason }]) {
      const r = await t.req('post', '/orders', s, { idem: true }).send(orderBody(sc, variants[1], '1', extra));
      expect(r.status, JSON.stringify(r.body)).toBe(403);
      expect(r.body.code).toBe('FORBIDDEN');
    }
    const senior = await t.actor({ role: 'senior_seller' });
    const ssc = await put(senior, variants[2], '1');
    const noStep = await t
      .req('post', '/orders', senior, { idem: true })
      .send(orderBody(ssc, variants[2], '1', { creditOverride: reason }));
    expect(noStep.status).toBe(403);
    expect(noStep.body.code).toBe('STEP_UP_REQUIRED');
    const stepUp = await t.stepUp(senior, 'credit.sale.approve');
    const ok = await t
      .req('post', '/orders', senior, { idem: true, stepUp })
      .send(orderBody(ssc, variants[2], '1', { creditOverride: reason }));
    expect([201, 202], JSON.stringify(ok.body)).toContain(ok.status);
    expect(await ordersOf(cc.id)).toBe('0');
    expect(await ordersOf(sc.id)).toBe('0');
  });

  // RM-F-009 (ветви CheckoutPolicy — долг, ревью F-trace-2) и T-ORD-006 / T-PAY-033: ответы CreditDecisionService в
  // checkout-preview (нестрогий режим — в теле; строгий — 422), право на override у кассира (нет → 403).
  it('checkout-preview credit: разрешено с остатком лимита; лимит / устаревший снимок / роль — в теле; strict → 422; override без права → 403', async () => {
    const cashier = await t.actor({ role: 'cashier' });
    const senior = await t.actor({ role: 'senior_seller' });
    const customerId = await t.createOnecCustomer({ creditAllowed: true, creditLimit: '100000.00' });
    const prep = async (actor: PosActor) => {
      const c0 = await put(actor, variants[5], '1');
      const set = await t.req('post', '/cart/customer', actor).send({ customerId, rowVersion: c0.rowVersion });
      expect(set.status, JSON.stringify(set.body)).toBe(200);
      return set.body as Cart;
    };
    const preview = (actor: PosActor, cart: Cart, extra: Record<string, unknown> = {}) =>
      t.req('post', '/cart/checkout-preview', actor).send({
        cartId: cart.id,
        cartRowVersion: cart.rowVersion,
        paymentMethod: 'credit',
        receiver: { kind: 'customer' },
        delivery: { method: 'pickup' },
        ...extra,
      });
    const decide = (r: Record<string, unknown>) =>
      t.replacePort(CREDIT_DECISION_SERVICE, { check: () => Promise.resolve(r as never) });
    const deny = (code: string, creditReason: string | null, limitRemaining: string | null = null) => ({
      allowed: false,
      code,
      detail: `${code} (тест)`,
      creditReason,
      overrideUsed: false,
      limitRemaining,
      receivablesAsOf: null,
    });
    try {
      const cc = await prep(cashier);
      decide({ allowed: true, overrideUsed: false, limitRemaining: '500.00', receivablesAsOf: new Date() });
      let r = await preview(cashier, cc);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(r.body.paymentChecks).toMatchObject({ creditAllowed: true, limitRemaining: { amount: '500.00' } });
      decide(deny('CREDIT_LIMIT_EXCEEDED', 'limit_exceeded', '10.00'));
      r = await preview(cashier, cc);
      expect(r.status).toBe(200);
      expect(r.body.paymentChecks).toMatchObject({
        creditAllowed: false,
        creditReason: 'limit_exceeded',
        limitRemaining: { amount: '10.00' },
        receivablesStale: false,
      });
      r = await preview(cashier, cc, { strict: true });
      expect(r.status).toBe(422);
      expect(r.body).toMatchObject({ code: 'CREDIT_LIMIT_EXCEEDED', limitRemaining: { amount: '10.00' } });
      decide(deny('RECEIVABLES_STALE', 'receivables_stale'));
      r = await preview(cashier, cc);
      expect(r.body.paymentChecks).toMatchObject({ creditAllowed: false, receivablesStale: true });
      decide(deny('FORBIDDEN', null));
      r = await preview(cashier, cc);
      expect(r.body.paymentChecks).toMatchObject({ creditAllowed: false, creditReason: 'forbidden_role' });
      // Кассир без credit.sale.approve не может просить override (11 §4.4).
      r = await preview(cashier, cc, { creditOverride: { reason: 'договорённость' } });
      expect(r.status).toBe(403);
      expect(r.body.code).toBe('FORBIDDEN');
      // Старший продавец: блокировка, снимаемая override, — в needsOverride / permissions предпросмотра.
      const sc = await prep(senior);
      decide(deny('CREDIT_BLOCKED', 'overdue'));
      r = await preview(senior, sc);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(r.body.paymentChecks).toMatchObject({ creditAllowed: false, creditReason: 'overdue' });
      expect(JSON.stringify(r.body)).toContain('credit');
    } finally {
      t.registry.unbind(CREDIT_DECISION_SERVICE);
    }
  });

  // T-ORD-026, T-SEC-041: созданный заказ, платёж и журнал операций не изменяются через API (10 ORD-026, TXN-004).
  it('T-ORD-026, T-SEC-041: PUT/PATCH заказа, платежа и операции → 404/405; заказ и платёж не изменены', async () => {
    const v = variants[3];
    const cart = await put(seller, v, '2');
    const created = await t.req('post', '/orders', seller, { idem: true }).send(orderBody(cart, v, '2'));
    expect([201, 202], JSON.stringify(created.body)).toContain(created.status);
    const orderId = created.body.id as string;
    const paymentId = created.body.payments[0].id as string;
    const before = await t.q<{ total: string; n: string }>(
      `SELECT total::text AS total, (SELECT count(*)::text FROM order_items WHERE order_id = o.id) AS n
         FROM orders o WHERE id = $1`,
      [orderId],
    );
    const items = [{ variantId: v.variantId, quantity: { value: '20', unitId: v.unitId, packagingId: null } }];
    const tx = await t.q<{ id: string }>(`SELECT id FROM transactions WHERE order_id = $1 LIMIT 1`, [orderId]);
    expect(tx).toHaveLength(1);
    const attempts = [
      ['patch', `/orders/${orderId}`, { items }],
      ['put', `/orders/${orderId}`, { items }],
      ['patch', `/payments/${paymentId}`, { amount: '1.00' }],
      ['put', `/payments/${paymentId}`, { amount: '1.00' }],
      ['patch', `/transactions/${tx[0].id}`, { amount: '1.00' }],
      ['put', `/transactions/${tx[0].id}`, { amount: '1.00' }],
    ] as const;
    for (const [method, path, body] of attempts) {
      const r = await t.req(method, path, seller, { idem: true }).send(body);
      expect([404, 405], `${method.toUpperCase()} ${path}: ${r.status}`).toContain(r.status);
    }
    const after = await t.q<{ total: string; n: string }>(
      `SELECT total::text AS total, (SELECT count(*)::text FROM order_items WHERE order_id = o.id) AS n
         FROM orders o WHERE id = $1`,
      [orderId],
    );
    expect(after).toEqual(before);
    const pay = await t.q<{ amount: string }>(`SELECT amount::text AS amount FROM payments WHERE id = $1`, [paymentId]);
    expect(pay[0].amount).toBe(created.body.payments[0].amount.amount);
    // Корректировка — отмена и новый заказ (10 ORD-026): отмена своего submitting доступна автору.
    const cancel = await t
      .req('post', `/orders/${orderId}/cancel`, seller, { idem: randomUUID() })
      .send({ reason: 'Исправить состав', reasonCode: 'error' });
    expect([200, 202], JSON.stringify(cancel.body)).toContain(cancel.status);
  });
});

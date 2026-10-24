import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { Money } from '../../src/common/money/money.js';
import { CREDIT_DECISION_SERVICE } from '../../src/common/ports/index.js';
import type { PosActor } from '../support/pos-fixture.js';
import { type OrdersHarness, orderBody, RETAIL_CUSTOMER_ID, startOrders, ids } from './support/orders-fixture.js';

/**
 * `POST /orders` (08 §4.8.1; ядро §22.3; RM-F-002 п. 1–2, RM-F-012 п. 2, RM-F-015; 12 T-ORD-009, T-ORD-010,
 * T-ORD-011, T-ORD-012, T-ORD-033, T-ORD-034) — **тестовые данные**: embedded PostgreSQL 17, синтетический каталог,
 * FakeOnecGateway. Документ 1С синхронно не создаётся: заказ `submitting`, outbox `pending`.
 */
describe('POST /orders — создание заказа', () => {
  let h: OrdersHarness;
  let a: Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;

  beforeAll(async () => {
    h = await startOrders({ env: { QR_PROVIDER: 'none', ONEC_SYNC_CHECK_TIMEOUT_MS: '800' } });
    a = await h.t.actors();
  });
  afterAll(async () => {
    if (process.env.ORDERS_DEBUG) {
      const { writeFileSync } = await import('node:fs');
      writeFileSync(process.env.ORDERS_DEBUG, h.t.logs.text);
    }
    await h?.t.stop();
  });

  const variants = async (n = 2) => (await h.t.saleableVariants(n + 4)).slice(0, n);

  // 12: T-ORD-004 («Розничный покупатель» по умолчанию), T-PAY-011 (начальный платёж в транзакции заказа), T-SYNC-031 (outbox pending, external_id = orders.id, operation=create), T-ORD-016 (статус заказа ≠ оплата), T-TXN-001 (order_created), T-TXN-011 (аудит order.created: актор)
  it('успех (cash): 201, submitting, снимок цен сервера, платёж cash_pending, outbox pending, история, аудит', async () => {
    const [v1, v2] = await variants(2);
    const cart = await h.cart.create(a.seller, [
      { variantId: v1.variantId, quantity: '2' },
      { variantId: v2.variantId, quantity: '3' },
    ]);
    const key = randomUUID();
    const res = await h.t.req('post', '/orders', a.seller, { idem: key }).send(orderBody(cart));
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    const o = res.body;
    expect(o).toMatchObject({
      status: 'submitting',
      onecSyncState: 'pending',
      paymentMethod: 'cash',
      createdVia: 'staff',
    });
    expect(o.onec.number).toBeNull();
    expect(o.publicNumber).toMatch(/^POS-\d{4}-\d{6}$/);
    expect(o.customer.id).toBe(RETAIL_CUSTOMER_ID);
    expect(o.payments).toHaveLength(1);
    expect(o.payments[0]).toMatchObject({ method: 'cash', status: 'cash_pending' });
    expect(o.payments[0].amount.amount).toBe(o.total.amount);
    expect((o.history as { status: string }[]).map((x) => x.status)).toEqual(['submitting']);
    expect(o.history[0].source).toBe('pos_system');
    // Снимок цен — из корзины сервера (D-23): цена позиции = цена каталога, итог = Σ строк.
    const items = await h.t.q<{ variant_id: string; unit_price: string; quantity: string; line_total: string }>(
      `SELECT variant_id, unit_price::text AS unit_price, quantity::text AS quantity, line_total::text AS line_total
         FROM order_items WHERE order_id = $1 ORDER BY line_no`,
      [o.id],
    );
    expect(items.map((i) => i.unit_price)).toEqual([v1.price, v2.price]);
    expect(items.map((i) => i.quantity)).toEqual(['2.000', '3.000']);
    expect(o.total.amount).toBe(cart.lines.reduce((s, l) => s.plus(Money.of(l.lineTotal)), Money.ZERO).toString());
    // outbox create: pending, external_id = orders.id, тело 1С с externalId и строками.
    const ob = await h.t.q<{
      status: string;
      external_id: string;
      operation: string;
      payload: Record<string, unknown>;
    }>(`SELECT status::text AS status, external_id, operation, payload FROM onec_outbox WHERE aggregate_id = $1`, [
      o.id,
    ]);
    expect(ob).toHaveLength(1);
    expect(ob[0]).toMatchObject({ status: 'pending', external_id: o.id, operation: 'create' });
    expect(ob[0].payload).toMatchObject({ externalId: o.id, paymentMethod: 'cash', paymentTerms: 'prepayment' });
    expect((ob[0].payload.lines as unknown[]).length).toBe(2);
    expect(String(ob[0].payload.comment)).toContain(`POS ${o.id}`);
    const tx = await h.t.q<{ kind: string }>(`SELECT kind::text AS kind FROM transactions WHERE order_id = $1`, [o.id]);
    expect(tx.map((x) => x.kind)).toEqual(['order_created']);
    const audit = await h.t.auditRows('order.created', o.id);
    expect(audit).toHaveLength(1);
    expect(audit[0].actor_user_id).toBe(a.seller.userId);
    expect(h.cart.converted.find((c) => c.cartId === cart.cartId)?.orderId).toBe(o.id);
    const row = await h.t.q<{ idempotency_key: string; status: string; submitted_at: Date | null }>(
      `SELECT idempotency_key, status::text AS status, submitted_at FROM orders WHERE id = $1`,
      [o.id],
    );
    expect(row[0]).toMatchObject({ idempotency_key: key, status: 'submitting' });
    expect(row[0].submitted_at).not.toBeNull();
  });

  // 12: T-CART-009 (а) (повтор с тем же ключом — один заказ), T-ORD-014 (поиск GET /orders?idempotencyKey=)
  it('идемпотентность: тот же ключ и тело → тот же заказ (Idempotent-Replayed); другое тело → 422; поиск по ключу', async () => {
    const [v1] = await variants(1);
    const cart = await h.cart.create(a.cashier, [{ variantId: v1.variantId, quantity: '1' }]);
    const key = randomUUID();
    const body = orderBody(cart);
    const r1 = await h.t.req('post', '/orders', a.cashier, { idem: key }).send(body);
    expect(r1.status).toBe(201);
    const r2 = await h.t.req('post', '/orders', a.cashier, { idem: key }).send(body);
    expect(r2.status).toBe(201);
    expect(r2.headers['idempotent-replayed']).toBe('true');
    expect(r2.body.id).toBe(r1.body.id);
    const cnt = await h.t.q<{ n: string }>(`SELECT count(*)::text AS n FROM orders WHERE idempotency_key = $1`, [key]);
    expect(cnt[0].n).toBe('1');
    const r3 = await h.t.req('post', '/orders', a.cashier, { idem: key }).send({ ...body, comment: 'другое тело' });
    expect(r3.status).toBe(422);
    expect(r3.body.code).toBe('IDEMPOTENCY_KEY_REUSED');
    // После перезапуска клиента — поиск по ключу (ядро §22.6): только свои заказы.
    const mine = await h.t.req('get', `/orders?idempotencyKey=${key}`, a.cashier);
    expect(mine.status).toBe(200);
    expect(ids(mine.body)).toEqual([r1.body.id]);
    const other = await h.t.req('get', `/orders?idempotencyKey=${key}`, a.senior_seller);
    expect(other.body.items).toHaveLength(0);
  });

  it('запрещённые денежные поля → 400 forbidden_field + аудит price.override_attempt; созданный канал из тела игнорируется', async () => {
    const [v1] = await variants(1);
    const cart = await h.cart.create(a.seller, [{ variantId: v1.variantId, quantity: '1' }]);
    const res = await h.t.req('post', '/orders', a.seller, { idem: true }).send({ ...orderBody(cart), total: '1.00' });
    expect(res.status).toBe(400);
    expect(res.body.errors[0]).toMatchObject({ field: 'total', rule: 'forbidden_field' });
    const audit = await h.t.q<{ result: string }>(
      `SELECT result FROM audit_logs WHERE action = 'price.override_attempt' AND actor_user_id = $1`,
      [a.seller.userId],
    );
    expect(audit.length).toBeGreaterThanOrEqual(1);
    const items = orderBody(cart).items as Record<string, unknown>[];
    const res2 = await h.t
      .req('post', '/orders', a.seller, { idem: true })
      .send({ ...orderBody(cart), items: [{ ...items[0], unitPrice: '1.00' }] });
    expect(res2.status).toBe(400);
    expect(res2.body.errors[0].field).toBe('items[0].unitPrice');
    const ok = await h.t
      .req('post', '/orders', a.seller, { idem: true })
      .send({ ...orderBody(cart), createdVia: 'customer' });
    expect(ok.status).toBe(201);
    expect(ok.body.createdVia).toBe('staff');
  });

  // 12: T-CART-007 (STOCK_INSUFFICIENT при оформлении), T-SYNC-041 (PRICE_CHANGED с conflicts[])
  it('конфликты цен/остатков → 422 с conflicts[]; корзина не конвертируется; VERSION_CONFLICT при чужой версии', async () => {
    const [v1, v2] = await variants(2);
    const cart = await h.cart.create(a.seller, [
      { variantId: v1.variantId, quantity: '1' },
      { variantId: v2.variantId, quantity: '1' },
    ]);
    cart.conflicts = [
      { variantId: v1.variantId, kind: 'price_changed', oldPrice: '10.00', newPrice: '12.00' },
      { variantId: v2.variantId, kind: 'stock_insufficient', available: '0.000' },
    ];
    const res = await h.t.req('post', '/orders', a.seller, { idem: true }).send(orderBody(cart));
    expect(res.status).toBe(422);
    expect(res.body.code).toBe('PRICE_CHANGED');
    expect(res.body.conflicts).toHaveLength(2);
    expect(cart.status).toBe('active');
    cart.conflicts = [];
    const stale = await h.t
      .req('post', '/orders', a.seller, { idem: true })
      .send({ ...orderBody(cart), cartRowVersion: 99 });
    expect(stale.status).toBe(409);
    expect(stale.body.code).toBe('VERSION_CONFLICT');
    const wrongItems = orderBody(cart);
    (wrongItems.items as { quantity: { value: string } }[])[0].quantity.value = '5';
    const mismatch = await h.t.req('post', '/orders', a.seller, { idem: true }).send(wrongItems);
    expect(mismatch.status).toBe(409);
    expect(mismatch.body.code).toBe('VERSION_CONFLICT');
  });

  // 12: T-FAIL-008 (1С недоступна → 202, submitting), T-SYNC-041 (/pos/v1/check с таймаутом), T-SYNC-042 (submitting — backend)
  it('1С не ответила на /check за таймаут → 202 + Location + warnings[STALE_DATA], заказ submitting, outbox pending', async () => {
    const [v1] = await variants(1);
    const cart = await h.cart.create(a.seller, [{ variantId: v1.variantId, quantity: '7' }], { onec: 'gateway' });
    h.t.onec.script('checkCart', { hang: true });
    const res = await h.t.req('post', '/orders', a.seller, { idem: true }).send(orderBody(cart));
    expect(res.status, JSON.stringify(res.body)).toBe(202);
    expect(res.headers.location).toBe(`/api/v1/orders/${res.body.id}`);
    expect(res.body.status).toBe('submitting');
    expect((res.body.warnings as { code: string }[]).map((w) => w.code)).toContain('STALE_DATA');
    const ob = await h.t.q<{ status: string }>(
      `SELECT status::text AS status FROM onec_outbox WHERE aggregate_id = $1`,
      [res.body.id],
    );
    expect(ob[0].status).toBe('pending');
    // /check выполнен → 201.
    const cart2 = await h.cart.create(a.seller, [{ variantId: v1.variantId, quantity: '8' }], { onec: 'gateway' });
    const res2 = await h.t.req('post', '/orders', a.seller, { idem: true }).send(orderBody(cart2));
    expect(res2.status).toBe(201);
  });

  // 12: T-SYNC-031 (заказ + outbox + платёж — всё или ничего), T-FAIL-013 (сбой посреди финансовой транзакции)
  it('транзакционность: сбой платежа или конвертации корзины → нет заказа, платежа, outbox (откат всего)', async () => {
    const [v1] = await variants(1);
    const before = await h.t.q<{ o: string; p: string; x: string }>(
      `SELECT (SELECT count(*) FROM orders)::text AS o, (SELECT count(*) FROM payments)::text AS p,
              (SELECT count(*) FROM onec_outbox)::text AS x`,
    );
    const cart = await h.cart.create(a.seller, [{ variantId: v1.variantId, quantity: '1' }]);
    h.payments.failNext = true;
    const r1 = await h.t
      .req('post', '/orders', a.seller, { idem: true })
      .send(orderBody(cart, { confirmDuplicate: true }));
    expect(r1.status).toBe(500);
    h.cart.failConvert = true;
    const r2 = await h.t
      .req('post', '/orders', a.seller, { idem: true })
      .send(orderBody(cart, { confirmDuplicate: true }));
    h.cart.failConvert = false;
    expect(r2.status).toBe(500);
    const after = await h.t.q<{ o: string; p: string; x: string }>(
      `SELECT (SELECT count(*) FROM orders)::text AS o, (SELECT count(*) FROM payments)::text AS p,
              (SELECT count(*) FROM onec_outbox)::text AS x`,
    );
    expect(after).toEqual(before);
    expect(cart.status).toBe('active');
  });

  it('мягкая защита от дубля: тот же состав за 60 с с другим ключом → 409 possible_duplicate; confirmDuplicate → 201', async () => {
    const [v1] = await variants(1);
    const seller2 = await h.t.actor({ role: 'seller' });
    const c1 = await h.cart.create(seller2, [{ variantId: v1.variantId, quantity: '4' }]);
    const r1 = await h.t.req('post', '/orders', seller2, { idem: true }).send(orderBody(c1));
    expect(r1.status).toBe(201);
    const c2 = await h.cart.create(seller2, [{ variantId: v1.variantId, quantity: '4' }]);
    const r2 = await h.t.req('post', '/orders', seller2, { idem: true }).send(orderBody(c2));
    expect(r2.status).toBe(409);
    expect(r2.body).toMatchObject({
      code: 'ORDER_STATE_INVALID',
      reason: 'possible_duplicate',
      possibleDuplicateOrderId: r1.body.id,
      // OpenAPI 1.2.0 (08 §4.8.1 п. 4; UI-21-029): номер и момент создания похожего заказа.
      possibleDuplicatePublicNumber: r1.body.publicNumber,
      possibleDuplicateCreatedAt: r1.body.audit.createdAt,
    });
    expect(new Date(r2.body.possibleDuplicateCreatedAt as string).toISOString()).toBe(
      r2.body.possibleDuplicateCreatedAt,
    );
    const r3 = await h.t
      .req('post', '/orders', seller2, { idem: true })
      .send(orderBody(c2, { confirmDuplicate: true }));
    expect(r3.status).toBe(201);
  });

  // 12: T-ORD-004 (credit недоступен «Розничному покупателю»), T-ORD-006, T-PAY-033
  it('долг: «Розничный покупатель» → CUSTOMER_NOT_IDENTIFIED; до этапа G — fail-closed CREDIT_BLOCKED; разрешён → платёж credit', async () => {
    const [v1] = await variants(1);
    const retail = await h.cart.create(a.cashier, [{ variantId: v1.variantId, quantity: '1' }]);
    const r1 = await h.t
      .req('post', '/orders', a.cashier, { idem: true })
      .send(orderBody(retail, { paymentMethod: 'credit' }));
    expect(r1.status).toBe(422);
    expect(r1.body.code).toBe('CUSTOMER_NOT_IDENTIFIED');
    const customerId = await h.t.createOnecCustomer({ creditAllowed: true, creditLimit: '100000.00', creditDays: 14 });
    const c2 = await h.cart.create(a.cashier, [{ variantId: v1.variantId, quantity: '1' }], { customerId });
    const r2 = await h.t
      .req('post', '/orders', a.cashier, { idem: true })
      .send(orderBody(c2, { paymentMethod: 'credit' }));
    expect(r2.status).toBe(422);
    expect(r2.body.code).toBe('CREDIT_BLOCKED');
    h.t.replacePort(CREDIT_DECISION_SERVICE, {
      check: () =>
        Promise.resolve({ allowed: true, overrideUsed: false, limitRemaining: null, receivablesAsOf: new Date() }),
    });
    const r3 = await h.t
      .req('post', '/orders', a.cashier, { idem: true })
      .send(orderBody(c2, { paymentMethod: 'credit' }));
    expect(r3.status, JSON.stringify(r3.body)).toBe(201);
    expect(r3.body.payments[0].status).toBe('credit');
    expect(r3.body.paymentDueDate).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    h.t.registry.unbind(CREDIT_DECISION_SERVICE);
  });

  // RM-F-009 (ветви создания заказа, ревью F-trace-2): подтверждения в самом POST /orders — скидка сверх лимита со
  // step-up (transactions.discount_override, approvedIn=order), долг с creditOverride (credit_sale_approved), отказ
  // CreditDecisionService с creditReason/limitRemaining → 422 и аудит credit.sale_blocked.
  it('подтверждения в заказе: discount_override (order), credit_sale_approved; отказ по долгу с creditReason', async () => {
    const [v1] = await variants(1);
    const c1 = await h.cart.create(a.senior_seller, [{ variantId: v1.variantId, quantity: '3' }], {
      manualDiscountPercent: '12.00',
    });
    const stepDisc = await h.t.stepUp(a.senior_seller, 'discount.approve.over_limit');
    const r1 = await h.t
      .req('post', '/orders', a.senior_seller, { idem: true, stepUp: stepDisc })
      .send(orderBody(c1, { discountOverride: { reason: 'постоянный клиент' } }));
    expect(r1.status, JSON.stringify(r1.body)).toBeLessThan(300);
    const tx1 = await h.t.q<{ kind: string; details: Record<string, unknown> }>(
      `SELECT kind::text AS kind, details FROM transactions WHERE order_id = $1 ORDER BY kind`,
      [r1.body.id],
    );
    expect(tx1.find((x) => x.kind === 'discount_override')?.details).toMatchObject({ approvedIn: 'order' });
    const customerId = await h.t.createOnecCustomer({ creditAllowed: true, creditLimit: '100000.00' });
    const c2 = await h.cart.create(a.senior_seller, [{ variantId: v1.variantId, quantity: '1' }], { customerId });
    h.t.replacePort(CREDIT_DECISION_SERVICE, {
      check: () =>
        Promise.resolve({ allowed: true, overrideUsed: true, limitRemaining: null, receivablesAsOf: new Date() }),
    });
    const stepCredit = await h.t.stepUp(a.senior_seller, 'credit.sale.approve');
    const r2 = await h.t
      .req('post', '/orders', a.senior_seller, { idem: true, stepUp: stepCredit })
      .send(orderBody(c2, { paymentMethod: 'credit', creditOverride: { reason: 'договорённость' } }));
    expect(r2.status, JSON.stringify(r2.body)).toBeLessThan(300);
    const tx2 = await h.t.q<{ kind: string }>(`SELECT kind::text AS kind FROM transactions WHERE order_id = $1`, [
      r2.body.id,
    ]);
    expect(tx2.map((x) => x.kind)).toContain('credit_sale_approved');
    h.t.replacePort(CREDIT_DECISION_SERVICE, {
      check: () =>
        Promise.resolve({
          allowed: false,
          code: 'CREDIT_LIMIT_EXCEEDED',
          detail: 'Лимит превышен (тест).',
          creditReason: 'limit_exceeded',
          overrideUsed: false,
          limitRemaining: '10.00',
          receivablesAsOf: new Date(),
        }),
    });
    const c3 = await h.cart.create(a.cashier, [{ variantId: v1.variantId, quantity: '1' }], { customerId });
    const r3 = await h.t
      .req('post', '/orders', a.cashier, { idem: true })
      .send(orderBody(c3, { paymentMethod: 'credit' }));
    expect(r3.status).toBe(422);
    expect(r3.body).toMatchObject({ code: 'CREDIT_LIMIT_EXCEEDED', creditReason: 'limit_exceeded' });
    const audit = await h.t.q<{ after: Record<string, unknown> }>(
      `SELECT after FROM audit_logs WHERE action = 'credit.sale_blocked' AND actor_user_id = $1 ORDER BY id DESC LIMIT 1`,
      [a.cashier.userId],
    );
    expect(audit[0].after).toMatchObject({ refusalCode: 'CREDIT_LIMIT_EXCEEDED', limitRemaining: '10.00' });
    h.t.registry.unbind(CREDIT_DECISION_SERVICE);
  });

  // 12: T-SEC-022 (скидка сверх лимита без step-up → STEP_UP_REQUIRED)
  it('права: owner не создаёт заказ (403); скидка сверх лимита без step-up → STEP_UP_REQUIRED', async () => {
    const [v1] = await variants(1);
    const cart = await h.cart.create(a.owner, [{ variantId: v1.variantId, quantity: '1' }]);
    const r1 = await h.t.req('post', '/orders', a.owner, { idem: true }).send(orderBody(cart));
    expect(r1.status).toBe(403);
    const c2 = await h.cart.create(a.senior_seller, [{ variantId: v1.variantId, quantity: '1' }]);
    const r2 = await h.t
      .req('post', '/orders', a.senior_seller, { idem: true })
      .send(orderBody(c2, { discountOverride: { reason: 'постоянный клиент' } }));
    expect(r2.status).toBe(403);
    expect(r2.body.code).toBe('STEP_UP_REQUIRED');
    const r3 = await h.t.req('post', '/orders', a.seller, { idem: true }).send(
      orderBody(await h.cart.create(a.seller, [{ variantId: v1.variantId, quantity: '1' }]), {
        discountOverride: { reason: 'x' },
      }),
    );
    expect(r3.status).toBe(403);
    expect(r3.body.code).toBe('FORBIDDEN');
  });

  describe('режим клиента (RM-F-015; 08 AC-API-179; ядро §24.2)', () => {
    it('credit → 403 forbidden_role; ручная скидка → 403; чужая карточка → 403; QR при QR_PROVIDER=none → 422 payment_method_unavailable', async () => {
      const [v1] = await variants(1);
      const cart = await h.cart.create(a.customer, [{ variantId: v1.variantId, quantity: '1' }]);
      const r1 = await h.t
        .req('post', '/orders', a.customer, { idem: true })
        .send(orderBody(cart, { paymentMethod: 'credit' }));
      expect(r1.status).toBe(403);
      expect(r1.body).toMatchObject({ code: 'FORBIDDEN', creditReason: 'forbidden_role' });
      const r2 = await h.t
        .req('post', '/orders', a.customer, { idem: true })
        .send(orderBody(cart, { manualDiscountPercent: '3.00' }));
      expect(r2.status).toBe(403);
      const someone = await h.t.createOnecCustomer();
      const r3 = await h.t
        .req('post', '/orders', a.customer, { idem: true })
        .send(orderBody(cart, { customerId: someone }));
      expect(r3.status).toBe(403);
      // QR_PROVIDER=none (этот стенд): QR клиенту недоступен; при `onec` → 201 — orders-ops.e2e.spec.ts.
      const r4 = await h.t
        .req('post', '/orders', a.customer, { idem: true })
        .send(orderBody(cart, { paymentMethod: 'qr_bakai' }));
      expect(r4.status).toBe(422);
      expect(r4.body.errors[0].rule).toBe('payment_method_unavailable');
    });

    it('заявка клиента: created_via=customer (тело игнорируется), клиент — подтверждённая карточка, «заявка клиента» в 1С', async () => {
      const [v1] = await variants(1);
      const buyer = await h.t.actor({ role: 'customer' });
      const card = await h.t.createOnecCustomer({ name: 'ОсОО «Покупатель»' });
      await h.t.linkCustomer(buyer.userId, card, 'confirmed');
      const cart = await h.cart.create(buyer, [{ variantId: v1.variantId, quantity: '2' }]);
      const res = await h.t
        .req('post', '/orders', buyer, { idem: true })
        .send(orderBody(cart, { createdVia: 'staff' }));
      expect(res.status, JSON.stringify(res.body)).toBe(201);
      expect(res.body.createdVia).toBe('customer');
      expect(res.body.customer.id).toBe(card);
      const row = await h.t.q<{ created_via: string }>(`SELECT created_via FROM orders WHERE id = $1`, [res.body.id]);
      expect(row[0].created_via).toBe('customer');
      const ob = await h.t.q<{ payload: { comment: string } }>(
        `SELECT payload FROM onec_outbox WHERE aggregate_id = $1`,
        [res.body.id],
      );
      expect(ob[0].payload.comment).toContain('заявка клиента');
      // Чужой клиент-покупатель заказ не видит (404), свой — видит.
      expect((await h.t.req('get', `/orders/${res.body.id}`, a.customer)).status).toBe(404);
      expect((await h.t.req('get', `/orders/${res.body.id}`, buyer)).status).toBe(200);
      // Без подтверждённой привязки — «Розничный покупатель».
      const fresh = await h.t.actor({ role: 'customer' });
      const c2 = await h.cart.create(fresh, [{ variantId: v1.variantId, quantity: '1' }]);
      const r2 = await h.t.req('post', '/orders', fresh, { idem: true }).send(orderBody(c2));
      expect(r2.status).toBe(201);
      expect(r2.body.customer.id).toBe(RETAIL_CUSTOMER_ID);
      // Чужая корзина недоступна.
      const r3 = await h.t.req('post', '/orders', fresh, { idem: true }).send(orderBody(cart));
      expect(r3.status).toBe(404);
    });
  });
});

import { randomUUID } from 'node:crypto';
import { APP_INTERCEPTOR } from '@nestjs/core';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CartModule } from '../../src/cart/cart.module.js';
import { HTTP_RATE_LIMITS, HttpRateLimitInterceptor } from '../../src/common/rate-limit/http-rate-limit.js';
import { PAYMENTS_PORT } from '../../src/common/ports/index.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import type { PosActor } from '../support/pos-fixture.js';
import { DbPaymentsPort, OrdersTestApp } from './support/orders-fixture.js';

type Cart = { id: string; rowVersion: number };
type V = { variantId: string; unitId: string };

/**
 * Денежные правила `POST /orders` с **реальной** корзиной (`CartModule`, CheckoutPolicy) — тестовые данные:
 * Трассировка 12: T-ORD-007 (суммы заказа = суммы checkout-preview), T-ORD-010 и T-CART-008 (ключ, параллельно),
 * T-SEC-023 (без ключа → 400), T-DISC-001 и T-SEC-021 (денежные поля от клиента), T-DISC-004 и T-DISC-008 (сверх
 * лимита: подтверждение, журнал, аудит), T-CART-017 (расхождение состава → VERSION_CONFLICT), T-PAY-022 / T-SEC-042
 * (долг fail-closed, аудит отказа; полная матрица — этап G).
 * - `previewToken` (10 ORD-020, AC-ORD-020; 04 AC-FLOW-014-04): итог изменился после предпросмотра,
 *   подделанный токен → `422 PRICE_CHANGED`, заказ не создан, корзина сохранена (ревью F-money-rules-1);
 * - подтверждение скидки сверх лимита в корзине действует только на одобренный процент (DISC-010, DISC-012;
 *   T-DISC-004; F-money-rules-2), причина/транзакция/аудит переносятся в заказ (F-money-rules-3);
 * - `cash_rounding=to_som` не расходит предпросмотр и заказ (Q-016; F-money-rules-4);
 * - запрещённые денежные поля `lineTotal`/`discountAmount` (DISC-011; F-money-rules-6);
 * - `items[]` с иным третьим знаком количества → `VERSION_CONFLICT` (F-money-rules-7);
 * - идемпотентность: без ключа → 400, два одновременных запроса с одним ключом → один заказ (08 §2.7;
 *   T-ORD-010, T-SEC-023, T-CART-008; F-trace-8);
 * - отказ в долг → аудит `credit.sale_blocked` (11 §7.2; F-security-5).
 */
describe('orders: денежные правила с реальной корзиной', () => {
  const t = new OrdersTestApp();
  let cashier: PosActor;
  let senior: PosActor;
  let variants: V[];

  beforeAll(async () => {
    await t.start({ modules: [CartModule, OrdersModule], fakePorts: true, env: { ONEC_SYNC_CHECK_TIMEOUT_MS: '700' } });
    t.replacePort(PAYMENTS_PORT, new DbPaymentsPort(t));
    cashier = await t.actor({ role: 'cashier' });
    senior = await t.actor({ role: 'senior_seller' });
    variants = await t.saleableVariants(12);
    await t.q(
      `UPDATE role_discount_limits SET approve_max_percent = 20, row_version = row_version + 1 WHERE role = 'senior_seller'`,
    );
  });
  afterAll(async () => {
    await t.stop();
  });

  async function put(actor: PosActor, v: V, value: string): Promise<Cart> {
    const before = await t.req('get', '/cart', actor);
    expect(before.status, JSON.stringify(before.body)).toBe(200);
    const r = await t.req('put', `/cart/items/${v.variantId}`, actor).send({
      quantity: { value, unitId: v.unitId, packagingId: null },
      rowVersion: (before.body as Cart).rowVersion,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return r.body as Cart;
  }
  const current = async (actor: PosActor) => (await t.req('get', '/cart', actor)).body as Cart;
  const orderBody = (cart: Cart, v: V, qty: string, extra: Record<string, unknown> = {}) => ({
    cartId: cart.id,
    cartRowVersion: cart.rowVersion,
    receiver: { kind: 'customer' },
    delivery: { method: 'pickup' },
    paymentMethod: 'cash',
    items: [{ variantId: v.variantId, quantity: { value: qty, unitId: v.unitId, packagingId: null } }],
    ...extra,
  });
  const preview = (actor: PosActor, cart: Cart, paymentMethod = 'cash') =>
    t.req('post', '/cart/checkout-preview', actor).send({
      cartId: cart.id,
      cartRowVersion: cart.rowVersion,
      paymentMethod,
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
    });
  const ordersOf = async (cartId: string) =>
    (await t.q<{ n: string }>(`SELECT count(*)::text AS n FROM orders WHERE cart_id = $1`, [cartId]))[0].n;

  it('previewToken: итог изменился после предпросмотра (скидка клиента) → 422 PRICE_CHANGED; подделка → 422; актуальный → 201', async () => {
    const v = variants[0];
    const customerId = await t.createOnecCustomer({ discountPercent: '0' });
    await put(cashier, v, '10');
    const c0 = await current(cashier);
    expect(
      (await t.req('post', '/cart/customer', cashier).send({ customerId, rowVersion: c0.rowVersion })).status,
    ).toBe(200);
    const cart = await current(cashier);
    const pv = await preview(cashier, cart);
    expect(pv.status, JSON.stringify(pv.body)).toBe(200);
    expect(pv.body.ok).toBe(true);
    // Вход расчёта меняется без price_changed по строкам: скидка клиента 1С.
    await t.q(`UPDATE customers SET discount_percent = 10 WHERE id = $1`, [customerId]);
    const stale = await t
      .req('post', '/orders', cashier, { idem: true })
      .send(orderBody(cart, v, '10', { previewToken: pv.body.previewToken }));
    expect(stale.status, JSON.stringify(stale.body)).toBe(422);
    expect(stale.body).toMatchObject({
      code: 'PRICE_CHANGED',
      reason: 'preview_total_changed',
      conflicts: [],
      previewTotal: pv.body.total,
    });
    expect(await ordersOf(cart.id)).toBe('0');
    const forged = await t
      .req('post', '/orders', cashier, { idem: true })
      // Подпись подменена: тело токена прежнее, HMAC — чужой.
      .send(orderBody(cart, v, '10', { previewToken: String(pv.body.previewToken).split('.')[0] + '.forged' }));
    expect(forged.status).toBe(422);
    expect(forged.body).toMatchObject({ code: 'PRICE_CHANGED', reason: 'preview_token_invalid' });
    // Токен на другой способ оплаты — тоже расхождение предпросмотра.
    const pvQr = await preview(cashier, cart, 'qr_bakai');
    const otherMethod = await t
      .req('post', '/orders', cashier, { idem: true })
      .send(orderBody(cart, v, '10', { previewToken: pvQr.body.previewToken }));
    expect(otherMethod.body).toMatchObject({ code: 'PRICE_CHANGED', reason: 'preview_payment_method_changed' });
    expect(await ordersOf(cart.id)).toBe('0');
    // Корзина сохранена; новый предпросмотр → заказ на показанную сумму.
    const pv2 = await preview(cashier, cart);
    expect(pv2.body.total.amount).not.toBe(pv.body.total.amount);
    const ok = await t
      .req('post', '/orders', cashier, { idem: true })
      .send(orderBody(cart, v, '10', { previewToken: pv2.body.previewToken }));
    expect([201, 202], JSON.stringify(ok.body)).toContain(ok.status);
    expect(ok.body.total).toEqual(pv2.body.total);
  });

  it('скидка сверх лимита: одобрение 15 % в корзине не распространяется на 20 % (422 DISCOUNT_LIMIT_EXCEEDED); 15 % → причина, discount_override и аудит по заказу', async () => {
    const v = variants[1];
    const c = await put(senior, v, '2');
    const d = await t
      .req('post', '/cart/discount', senior, { stepUp: await t.stepUp(senior, 'discount.approve.over_limit') })
      .send({ percent: '15', rowVersion: c.rowVersion, override: { reason: 'постоянный клиент' } });
    expect(d.status, JSON.stringify(d.body)).toBe(200);
    const cart = await current(senior);
    const more = await t
      .req('post', '/orders', senior, { idem: true })
      .send(orderBody(cart, v, '2', { manualDiscountPercent: '20' }));
    expect(more.status, JSON.stringify(more.body)).toBe(422);
    expect(more.body.code).toBe('DISCOUNT_LIMIT_EXCEEDED');
    // Меньше одобренного, но выше лимита роли (10 %) — тоже нужен discountOverride.
    const less = await t
      .req('post', '/orders', senior, { idem: true })
      .send(orderBody(cart, v, '2', { manualDiscountPercent: '12' }));
    expect(less.body.code).toBe('DISCOUNT_LIMIT_EXCEEDED');
    expect(await ordersOf(cart.id)).toBe('0');
    const res = await t
      .req('post', '/orders', senior, { idem: true })
      .send(orderBody(cart, v, '2', { manualDiscountPercent: '15' }));
    expect([201, 202], JSON.stringify(res.body)).toContain(res.status);
    expect(res.body.discountPercent).toBe('15.00');
    const row = await t.q<{ p: string; by: string; reason: string | null }>(
      `SELECT discount_percent::text AS p, discount_approved_by_user_id AS by, discount_reason AS reason
         FROM orders WHERE id = $1`,
      [res.body.id],
    );
    expect(row[0]).toEqual({ p: '15.00', by: senior.userId, reason: 'постоянный клиент' });
    const tx = await t.q<{ kind: string; actor: string }>(
      `SELECT kind::text AS kind, actor_user_id AS actor FROM transactions WHERE order_id = $1 ORDER BY kind`,
      [res.body.id],
    );
    expect(tx).toContainEqual({ kind: 'discount_override', actor: senior.userId });
    const audit = await t.auditRows('discount.over_limit_approved', res.body.id);
    expect(audit).toHaveLength(1);
    expect(audit[0].after).toMatchObject({ percent: '15.00', approvedIn: 'cart', approverUserId: senior.userId });
  });

  // 12: T-PAY-009 (округление наличных: в R1 без округления, Q-016)
  it('cash_rounding=to_som: предпросмотр и заказ — одна сумма к оплате (Q-016: в R1 без округления)', async () => {
    const pl = await t.defaultPriceListId();
    const fractional = await t.q<{ id: string }>(
      `SELECT variant_id AS id FROM prices WHERE price_list_id = $1 AND packaging_id IS NULL AND price <> round(price)
        AND variant_id = ANY($2::uuid[]) LIMIT 1`,
      [pl, variants.map((x) => x.variantId)],
    );
    const v = fractional[0] ? variants.find((x) => x.variantId === fractional[0].id)! : variants[2];
    if (!fractional[0]) await t.setPrice(v.variantId, '1157.55');
    await t.setSetting('cash_rounding', '"to_som"');
    try {
      const s = await t.actor({ role: 'seller' });
      const cart = await put(s, v, '1');
      const pv = await preview(s, cart);
      expect(pv.status).toBe(200);
      expect(pv.body.cashRounding).toBe('0.00');
      expect(pv.body.totalToPay).toEqual(pv.body.total);
      const res = await t
        .req('post', '/orders', s, { idem: true })
        .send(orderBody(cart, v, '1', { previewToken: pv.body.previewToken }));
      expect([201, 202], JSON.stringify(res.body)).toContain(res.status);
      expect(res.body.totalToPay).toEqual(pv.body.totalToPay);
      const pay = await t.q<{ amount: string }>(`SELECT amount::text AS amount FROM payments WHERE order_id = $1`, [
        res.body.id,
      ]);
      expect(pay[0].amount).toBe(pv.body.totalToPay.amount);
    } finally {
      await t.setSetting('cash_rounding', '"none"');
    }
  });

  it('запрещённые денежные поля lineTotal/discountAmount → 400 forbidden_field и аудит price.override_attempt', async () => {
    const v = variants[3];
    const cart = await put(cashier, v, '1');
    const body = orderBody(cart, v, '1', { discountAmount: '1.00' }) as Record<string, unknown>;
    (body.items as Record<string, unknown>[])[0].lineTotal = '1.00';
    const res = await t.req('post', '/orders', cashier, { idem: true }).send(body);
    expect(res.status).toBe(400);
    expect(res.body.errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ field: 'discountAmount', rule: 'forbidden_field' }),
        expect.objectContaining({ field: 'items[0].lineTotal', rule: 'forbidden_field' }),
      ]),
    );
    const audit = await t.q<{ after: { fields: string[] } }>(
      `SELECT after FROM audit_logs WHERE action = 'price.override_attempt' AND actor_user_id = $1 ORDER BY seq DESC LIMIT 1`,
      [cashier.userId],
    );
    expect(audit[0].after.fields).toEqual(expect.arrayContaining(['discountAmount', 'items[0].lineTotal']));
    expect(await ordersOf(cart.id)).toBe('0');
  });

  it('items[] с другим третьим знаком количества → 409 VERSION_CONFLICT (Quantity, не Money)', async () => {
    const rows = await t.q<{ variant_id: string; unit_id: string }>(
      `SELECT v.id AS variant_id, p.base_unit_id AS unit_id FROM product_variants v JOIN products p ON p.id = v.product_id
         JOIN units u ON u.id = p.base_unit_id JOIN prices pr ON pr.variant_id = v.id AND pr.packaging_id IS NULL
          AND pr.price_list_id = $2::uuid
         JOIN stock_balances sb ON sb.variant_id = v.id AND sb.available > 10 AND sb.warehouse_id = $1::uuid
        WHERE u.qty_precision = 3 AND NOT v.deletion_mark AND NOT p.deletion_mark AND p.is_sellable
          AND v.is_default = NOT p.has_variants AND p.multiplicity IS NULL AND p.min_qty IS NULL LIMIT 1`,
      [await t.defaultWarehouseId(), await t.defaultPriceListId()],
    );
    expect(rows.length, 'в синтетическом каталоге есть вариант с точностью 3 знака').toBe(1);
    const v = { variantId: rows[0].variant_id, unitId: rows[0].unit_id };
    const s = await t.actor({ role: 'seller' });
    const cart = await put(s, v, '1.234');
    const res = await t.req('post', '/orders', s, { idem: true }).send(orderBody(cart, v, '1.231'));
    expect(res.status, JSON.stringify(res.body)).toBe(409);
    expect(res.body.code).toBe('VERSION_CONFLICT');
    expect(await ordersOf(cart.id)).toBe('0');
  });

  // 12: T-CART-009 (а), T-FAIL-013 (повтор тем же ключом — один заказ)
  it('идемпотентность POST /orders: без Idempotency-Key → 400; два одновременных запроса с одним ключом → один заказ, один платёж, одна задача outbox', async () => {
    const v = variants[4];
    const s = await t.actor({ role: 'seller' });
    const cart = await put(s, v, '3');
    const noKey = await t.req('post', '/orders', s).send(orderBody(cart, v, '3'));
    expect(noKey.status).toBe(400);
    expect(noKey.body.errors[0]).toMatchObject({ field: 'Idempotency-Key', rule: 'idempotency_key_required' });
    expect(await ordersOf(cart.id)).toBe('0');
    const key = randomUUID();
    const body = orderBody(cart, v, '3');
    const [r1, r2] = await Promise.all([
      t.req('post', '/orders', s, { idem: key }).send(body),
      t.req('post', '/orders', s, { idem: key }).send(body),
    ]);
    const statuses = [r1.status, r2.status].sort();
    const created = [r1, r2].filter((r) => r.status === 201 || r.status === 202);
    expect(created.length, JSON.stringify([r1.body, r2.body])).toBeGreaterThanOrEqual(1);
    for (const r of [r1, r2]) {
      if (r.status === 409) expect(r.body.code).toBe('IDEMPOTENCY_IN_PROGRESS');
      else expect([201, 202], JSON.stringify(statuses)).toContain(r.status);
    }
    if (created.length === 2) expect(created[0].body.id).toBe(created[1].body.id);
    expect(await ordersOf(cart.id)).toBe('1');
    const orderId = created[0].body.id as string;
    const pays = await t.q<{ n: string }>(`SELECT count(*)::text AS n FROM payments WHERE order_id = $1`, [orderId]);
    expect(pays[0].n).toBe('1');
    const ob = await t.q<{ n: string }>(`SELECT count(*)::text AS n FROM onec_outbox WHERE aggregate_id = $1`, [
      orderId,
    ]);
    expect(ob[0].n).toBe('1');
    // Повтор после завершения — тот же заказ (Idempotent-Replayed).
    const replay = await t.req('post', '/orders', s, { idem: key }).send(body);
    expect(replay.body.id).toBe(orderId);
  });

  it('отказ в продаже в долг (fail-closed до этапа G) → 422 CREDIT_BLOCKED и аудит credit.sale_blocked', async () => {
    const v = variants[5];
    const customerId = await t.createOnecCustomer({
      creditAllowed: true,
      creditLimit: '1000000.00',
      receivables: { balance: '0.00', overdue: '0.00' },
    });
    const c0 = await put(cashier, v, '1');
    const withC = await t.req('post', '/cart/customer', cashier).send({ customerId, rowVersion: c0.rowVersion });
    expect(withC.status).toBe(200);
    const cart = await current(cashier);
    const res = await t
      .req('post', '/orders', cashier, { idem: true })
      .send(orderBody(cart, v, '1', { paymentMethod: 'credit', customerId }));
    expect(res.status, JSON.stringify(res.body)).toBe(422);
    expect(res.body.code).toBe('CREDIT_BLOCKED');
    const audit = await t.q<{ result: string; after: Record<string, unknown> }>(
      `SELECT result::text AS result, after FROM audit_logs WHERE action = 'credit.sale_blocked' AND actor_user_id = $1`,
      [cashier.userId],
    );
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({ result: 'denied', after: { refusalCode: 'CREDIT_BLOCKED', customerId } });
  });
});

/**
 * RL-FIN (08 §2.9: 60/мин на пользователя, хранилище memory; 11 §3; ревью F-security-2) — интерцептор приложения
 * с уменьшенным лимитом (3/мин) на стенде заказов: 4-й финансовый запрос пользователя в минуту → 429 `RATE_LIMITED`
 * с `Retry-After`; другой пользователь и чтение — не затронуты.
 */
describe('orders: лимит частоты RL-FIN', () => {
  const t = new OrdersTestApp();

  beforeAll(async () => {
    await t.start({
      modules: [OrdersModule],
      fakePorts: true,
      jobs: false,
      providers: [
        { provide: APP_INTERCEPTOR, useClass: HttpRateLimitInterceptor },
        { provide: HTTP_RATE_LIMITS, useValue: { 'RL-FIN': 3 } },
      ],
    });
  });
  afterAll(async () => {
    await t.stop();
  });

  it('4-й POST /orders/{id}/cancel за минуту → 429 RATE_LIMITED c Retry-After; другой пользователь — без отказа', async () => {
    const s = await t.actor({ role: 'cashier' });
    const body = { reason: 'Клиент передумал', reasonCode: 'customer_refused' };
    const statuses: number[] = [];
    for (let i = 0; i < 3; i++) {
      statuses.push((await t.req('post', `/orders/${randomUUID()}/cancel`, s, { idem: true }).send(body)).status);
    }
    expect(statuses).toEqual([404, 404, 404]);
    const limited = await t.req('post', `/orders/${randomUUID()}/cancel`, s, { idem: true }).send(body);
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
    expect(Number(limited.headers['retry-after'])).toBeGreaterThan(0);
    // POST /orders — та же группа: тоже 429.
    expect((await t.req('post', '/orders', s, { idem: true }).send({})).status).toBe(429);
    // Чтение (RL-READ) и другой пользователь не затронуты.
    expect((await t.req('get', '/orders', s)).status).toBe(200);
    const other = await t.actor({ role: 'cashier' });
    expect((await t.req('post', `/orders/${randomUUID()}/cancel`, other, { idem: true }).send(body)).status).toBe(404);
  });
});

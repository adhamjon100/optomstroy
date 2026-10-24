import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CartJobsHandler } from '../../src/cart/cart-jobs.js';
import { CART_READER, type SalesActor } from '../../src/common/ports/index.js';
import type { PosActor, PosTestApp, SaleableVariant } from '../support/pos-fixture.js';
import { getCart, setItem, startCartApp } from './cart-support.js';

const PICKUP = { method: 'pickup' } as const;
const SELF = { kind: 'customer' } as const;

function salesActor(a: PosActor): SalesActor {
  return { userId: a.userId, roles: a.role ? [a.role] : [], isCustomer: a.kind === 'customer' };
}

/**
 * RM-F-015 (режим клиента: корзина, способы оплаты API-179, ручная скидка, чужие корзины), минимальный
 * `GET /search/customers` (ядро §19.4, 11 SEC-042), порт `CartReader` для заказов (CheckoutPolicy, `markConverted`,
 * `restoreFromOrder`) и фоновые задачи корзины — **тестовые данные** стенда pos-fixture.
 */
describe('cart: режим клиента, QR_PROVIDER=none (RM-F-015, 08 API-179)', () => {
  let t: PosTestApp;
  let v: SaleableVariant[];

  beforeAll(async () => {
    t = await startCartApp({ env: { QR_PROVIDER: 'none' } });
    v = await t.saleableVariants(6);
  });
  afterAll(async () => {
    await t?.stop();
  });

  it('без подтверждённой привязки: цены по умолчанию, Cart.customer = null; остатки — только статус (customer_stock_display=status)', async () => {
    const c = await t.actor({ role: 'customer' });
    const cart = await setItem(t, c, v[0], '1');
    expect(cart).toMatchObject({
      customer: null,
      priceListId: await t.defaultPriceListId(),
      discountLimitPercent: '0.00',
    });
    expect(cart.items[0].available).toBeUndefined();
    expect(cart.items[0].remainingAvailable).toBeUndefined();
    await t.setStock(v[0].variantId, '0', v[0].warehouseId);
    const after = await getCart(t, c);
    const w = after.warnings.find((x) => x.kind === 'stock_insufficient');
    expect(w).toMatchObject({ variantId: v[0].variantId, stockLevel: 'out' });
    expect(w).not.toHaveProperty('available');
    expect(w).not.toHaveProperty('requested');
    await t.setStock(v[0].variantId, '100', v[0].warehouseId);
  });

  it('подтверждённая привязка: своя карточка (CustomerViewSelf), вид цены и скидка 1С; чужой клиент → 403; своя — 200', async () => {
    const c = await t.actor({ role: 'customer' });
    const pl = (await t.q<{ id: string }>(`SELECT id FROM price_lists WHERE NOT is_default ORDER BY id LIMIT 1`))[0].id;
    await t.setPrice(v[1].variantId, '500.00', pl);
    const own = await t.createOnecCustomer({ priceListId: pl, discountPercent: '2.00', phoneE164: '+996555222333' });
    await t.linkCustomer(c.userId, own, 'confirmed');
    const cart = await setItem(t, c, v[1], '2');
    expect(cart.customer).toMatchObject({ id: own, phones: [{ value: '+996555222333' }], discountPercent: '2.00' });
    expect(cart.customer).not.toHaveProperty('onecStatus');
    expect(cart.customer).not.toHaveProperty('receivable');
    expect(cart).toMatchObject({ priceListId: pl, customerDiscountPercent: '2.00', total: { amount: '980.00' } });
    const other = await t.createOnecCustomer();
    const forb = await t.req('post', '/cart/customer', c).send({ customerId: other, rowVersion: cart.rowVersion });
    expect(forb.status).toBe(403);
    const ok = await t.req('post', '/cart/customer', c).send({
      customerId: own,
      receiver: { kind: 'other_person', name: 'Айбек', phone: '+996700555444' },
      rowVersion: cart.rowVersion,
    });
    expect(ok.status).toBe(200);
    expect(ok.body.receiver.kind).toBe('other_person');
  });

  it('checkout-preview клиента: allowedPaymentMethods=[cash]; credit → forbidden_role (strict → 403); QR при none → 422; ручная скидка → 403', async () => {
    const c = await t.actor({ role: 'customer' });
    const cart = await setItem(t, c, v[2], '1');
    const base = { cartId: cart.id, cartRowVersion: cart.rowVersion, delivery: PICKUP, receiver: SELF };
    const cash = await t.req('post', '/cart/checkout-preview', c).send({ ...base, paymentMethod: 'cash' });
    expect(cash.status).toBe(200);
    expect(cash.body.permissions).toMatchObject({
      allowedPaymentMethods: ['cash'],
      canApplyDiscount: false,
      canSellOnCredit: false,
      discountLimitPercent: '0.00',
    });
    const credit = await t.req('post', '/cart/checkout-preview', c).send({ ...base, paymentMethod: 'credit' });
    expect(credit.status).toBe(200);
    expect(credit.body.paymentChecks).toMatchObject({ creditAllowed: false, creditReason: 'forbidden_role' });
    const strict = await t
      .req('post', '/cart/checkout-preview', c)
      .send({ ...base, paymentMethod: 'credit', strict: true });
    expect(strict.status).toBe(403);
    expect(strict.body).toMatchObject({ code: 'FORBIDDEN', creditReason: 'forbidden_role' });
    const qr = await t.req('post', '/cart/checkout-preview', c).send({ ...base, paymentMethod: 'qr_bakai' });
    expect(qr.status).toBe(422);
    expect(qr.body.errors[0]).toMatchObject({ field: 'paymentMethod', rule: 'payment_method_unavailable' });
    const disc = await t
      .req('post', '/cart/checkout-preview', c)
      .send({ ...base, paymentMethod: 'cash', manualDiscountPercent: '1.00' });
    expect(disc.status).toBe(403);
    // Чужая корзина → 404.
    const other = await t.actor({ role: 'customer' });
    const foreign = await t.req('post', '/cart/checkout-preview', other).send({ ...base, paymentMethod: 'cash' });
    expect(foreign.status).toBe(404);
  });

  it('customer_stock_display=quantity: клиент видит available, без колонок остатка/резерва', async () => {
    await t.setSetting('customer_stock_display', '"quantity"');
    const c = await t.actor({ role: 'customer' });
    const cart = await setItem(t, c, v[3], '1');
    expect(cart.items[0].available).toMatch(/^\d+\.\d{3}$/);
    await t.setSetting('customer_stock_display', '"status"');
  });

  it('GET /search/customers: seller — только полный номер/код (0555 → 400 search_scope_role, маска); cashier — от 4 цифр и 2 букв; customer → 403', async () => {
    const seller = await t.actor({ role: 'seller' });
    const cashier = await t.actor({ role: 'cashier' });
    const id = await t.createOnecCustomer({ name: 'ОсОО «Сантехмир»', phoneE164: '+996555987654' });
    const code = (await t.q<{ c: string }>(`SELECT onec_code AS c FROM customers WHERE id = $1`, [id]))[0].c;
    const part = await t.req('get', '/search/customers?q=0555', seller);
    expect(part.status).toBe(400);
    expect(part.body.errors[0]).toMatchObject({ rule: 'search_scope_role' });
    const full = await t.req('get', `/search/customers?q=${encodeURIComponent('+996555987654')}`, seller);
    expect(full.status).toBe(200);
    expect(full.headers['cache-control']).toBe('no-store');
    expect(full.body.items[0]).toMatchObject({
      id,
      matchType: 'phone',
      phoneMasked: '+996 5** *** *54',
      hasDebt: false,
    });
    expect(full.body.items[0].phones).toBeUndefined();
    expect(full.body.items[0].receivable).toBeUndefined();
    const byCode = await t.req('get', `/search/customers?q=${encodeURIComponent(code)}`, seller);
    expect(byCode.body.items[0]).toMatchObject({ id, matchType: 'code' });
    const four = await t.req('get', '/search/customers?q=9876', cashier);
    expect(four.status).toBe(200);
    expect((four.body.items as { id: string }[]).map((x) => x.id)).toContain(id);
    expect((four.body.items as { id: string; phones?: unknown }[]).find((x) => x.id === id)?.phones).toEqual([
      { value: '+996555987654', verified: false },
    ]);
    const name = await t.req('get', `/search/customers?q=${encodeURIComponent('Сантех')}&include=receivable`, cashier);
    expect(name.body.items[0]).toMatchObject({ id, matchType: 'name' });
    expect(name.body.items[0].receivable).toBeUndefined();
    expect((await t.req('get', '/search/customers?q=С', cashier)).status).toBe(400);
    expect((await t.req('get', '/search/customers?q=123', cashier)).status).toBe(400);
    expect((await t.req('get', '/search/customers?q=Сантех', await t.actor({ role: 'customer' }))).status).toBe(403);
    expect((await t.req('get', '/search/customers?q=Сантех&limit=51', cashier)).status).toBe(400);
  });

  it('CartReader.validateForCheckout: снимок корзины для order_items; конфликты → ok=false; сверх лимита → DISCOUNT_LIMIT_EXCEEDED; customer + credit → 403', async () => {
    const reader = t.registry.get(CART_READER);
    const s = await t.actor({ role: 'seller' });
    const cart = await setItem(t, s, v[4], '3');
    const r = await reader.validateForCheckout(null, salesActor(s), {
      cartId: cart.id,
      expectedRowVersion: cart.rowVersion,
      paymentMethod: 'cash',
    });
    expect(r.ok).toBe(true);
    expect(r.cart).toMatchObject({
      cartId: cart.id,
      rowVersion: cart.rowVersion,
      ownerUserId: s.userId,
      total: cart.total.amount,
    });
    expect(r.cart.lines[0]).toMatchObject({
      lineNo: 1,
      variantId: v[4].variantId,
      quantity: '3.000',
      unitPrice: v[4].price,
    });
    expect(r.onecCheck).toMatchObject({ performed: true, result: 'ok' });
    await expect(
      reader.validateForCheckout(null, salesActor(s), { cartId: cart.id, expectedRowVersion: cart.rowVersion - 1 }),
    ).rejects.toMatchObject({ code: 'VERSION_CONFLICT' });
    await t.setPrice(v[4].variantId, '777.77');
    const c2 = await reader.validateForCheckout(null, salesActor(s), { cartId: cart.id, paymentMethod: 'cash' });
    expect(c2.ok).toBe(false);
    expect(c2.conflicts[0]).toMatchObject({ variantId: v[4].variantId, kind: 'price_changed' });
    await expect(
      reader.validateForCheckout(null, salesActor(s), {
        cartId: cart.id,
        paymentMethod: 'cash',
        manualDiscountPercent: '7',
      }),
    ).rejects.toMatchObject({ code: 'DISCOUNT_LIMIT_EXCEEDED' });
    const cust = await t.actor({ role: 'customer' });
    const cc = await setItem(t, cust, v[5], '1');
    await expect(
      reader.validateForCheckout(null, salesActor(cust), { cartId: cc.id, paymentMethod: 'credit' }),
    ).rejects.toMatchObject({ code: 'FORBIDDEN' });
    await expect(
      reader.validateForCheckout(null, salesActor(cust), { cartId: cc.id, paymentMethod: 'qr_bakai' }),
    ).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
  });

  it('CartReader.markConverted / restoreFromOrder: converted (повтор — без ошибки, чужая версия — 409); восстановление заказа в active / parked', async () => {
    const reader = t.registry.get(CART_READER);
    const s = await t.actor({ role: 'cashier' });
    const cart = await setItem(t, s, v[5], '2');
    const order = await t.seedOrder({ createdBy: s, method: 'cash', status: 'submit_failed' });
    await expect(
      t.db.transaction((tx) =>
        reader.markConverted(tx, { cartId: cart.id, expectedRowVersion: cart.rowVersion - 1, orderId: order.orderId }),
      ),
    ).rejects.toMatchObject({ code: 'VERSION_CONFLICT' });
    await t.db.transaction((tx) =>
      reader.markConverted(tx, { cartId: cart.id, expectedRowVersion: cart.rowVersion, orderId: order.orderId }),
    );
    await t.db.transaction((tx) =>
      reader.markConverted(tx, { cartId: cart.id, expectedRowVersion: cart.rowVersion, orderId: order.orderId }),
    );
    const row = await t.q<{ status: string; converted_order_id: string }>(
      `SELECT status::text, converted_order_id FROM carts WHERE id = $1`,
      [cart.id],
    );
    expect(row[0]).toEqual({ status: 'converted', converted_order_id: order.orderId });
    await expect(
      t.db.transaction((tx) =>
        reader.markConverted(tx, { cartId: cart.id, expectedRowVersion: cart.rowVersion + 1, orderId: randomUUID() }),
      ),
    ).rejects.toMatchObject({ code: 'ORDER_STATE_INVALID' });
    // Новая active — пустая → восстановление в active (restoredFromOrderId).
    const fresh = await getCart(t, s);
    expect(fresh.id).not.toBe(cart.id);
    const restored = await t.db.transaction((tx) =>
      reader.restoreFromOrder(tx, { orderId: order.orderId, ownerUserId: s.userId }),
    );
    expect(restored.status).toBe('active');
    const now = await getCart(t, s);
    expect(now).toMatchObject({ id: restored.cartId, restoredFromOrderId: order.orderId, rowVersion: 1 });
    // OpenAPI 1.2.0 Cart.restoredFromOrder (08 §3.8 п. 4): номер заказа; причины отказа 1С у заказа нет → null.
    expect(now.restoredFromOrder).toEqual({ number: order.publicNumber, reason: null });
    expect(now.items).toHaveLength(2);
    const again = await t.db.transaction((tx) =>
      reader.restoreFromOrder(tx, { orderId: order.orderId, ownerUserId: s.userId }),
    );
    expect(again.cartId).toBe(restored.cartId);
    const order2 = await t.seedOrder({ createdBy: s, method: 'cash', status: 'submit_failed' });
    await t.q(`UPDATE orders SET submit_error_code = 'ONEC_REJECTED', submit_error_message = $2 WHERE id = $1`, [
      order2.orderId,
      'Превышен лимит скидки',
    ]);
    const parked = await t.db.transaction((tx) =>
      reader.restoreFromOrder(tx, { orderId: order2.orderId, ownerUserId: s.userId }),
    );
    expect(parked.status).toBe('parked');
    const list = await t.req('get', '/cart/parked', s);
    expect(list.body.items[0]).toMatchObject({ id: parked.cartId, restoredFromOrderId: order2.orderId });
    expect(list.body.items[0].name).toBe(`Восстановлена из заказа № ${order2.publicNumber}`);
    // Причина отказа 1С (orders.submit_error_message) — в Cart.restoredFromOrder.reason возобновлённой корзины.
    const resumed = await t.req('post', `/cart/parked/${parked.cartId}/resume`, s).send({ replaceActive: true });
    expect(resumed.status).toBe(200);
    expect(resumed.body).toMatchObject({
      id: parked.cartId,
      restoredFromOrderId: order2.orderId,
      restoredFromOrder: { number: order2.publicNumber, reason: 'Превышен лимит скидки' },
    });
  });

  // 12: T-CART-028 (истёкшая отложенная → cleared; уведомление за сутки), T-CART-006
  it('job catalog.prices-changed / catalog.stock-changed: флаги строк и уведомление владельцу (однократно); cart.parked_expire', async () => {
    const jobs = t.app.get(CartJobsHandler);
    const s = await t.actor({ role: 'seller' });
    const cart = await setItem(t, s, v[3], '2');
    await t.setPrice(v[3].variantId, '4321.00');
    const r1 = await jobs.catalogChanged('prices', { variantIds: [v[3].variantId] });
    expect(r1.notified).toBeGreaterThanOrEqual(1);
    const flags = await t.q<{ price_changed: boolean }>(`SELECT price_changed FROM cart_items WHERE cart_id = $1`, [
      cart.id,
    ]);
    expect(flags[0].price_changed).toBe(true);
    const mine = t.fakes!.notifications.of(s.userId);
    expect(mine).toHaveLength(1);
    expect(mine[0]).toMatchObject({ kind: 'cart_price_changed', payload: { cartId: cart.id } });
    await jobs.catalogChanged('prices', { variantIds: [v[3].variantId] });
    expect(t.fakes!.notifications.of(s.userId)).toHaveLength(1);
    // Версия корзины фоновой задачей не меняется.
    expect((await getCart(t, s)).rowVersion).toBe(cart.rowVersion);
    await t.setStock(v[3].variantId, '1', v[3].warehouseId);
    await jobs.catalogChanged('stock', { variantIds: [v[3].variantId] });
    expect(t.fakes!.notifications.of(s.userId).map((n) => n.kind)).toContain('cart_stock_changed');
    // Отложенные: за сутки до срока — уведомление (system), истёкшие → cleared.
    const p = await setItem(t, s, v[4], '1');
    const parked = await t.req('post', '/cart/park', s, { idem: true }).send({ rowVersion: p.rowVersion });
    expect(parked.status).toBe(201);
    await t.db.execute(sql`UPDATE carts SET expires_at = now() + interval '2 hours' WHERE id = ${p.id}::uuid`);
    const r2 = await jobs.parkedExpire();
    expect(r2.notified).toBe(1);
    expect(
      t
        .fakes!.notifications.of(s.userId)
        .some((n) => n.kind === 'system' && n.dedupeKey === `cart_parked_expire:${p.id}`),
    ).toBe(true);
    await t.db.execute(sql`UPDATE carts SET expires_at = now() - interval '1 minute' WHERE id = ${p.id}::uuid`);
    const r3 = await jobs.parkedExpire();
    expect(r3.cleared).toBe(1);
    expect((await t.q<{ s: string }>(`SELECT status::text AS s FROM carts WHERE id = $1`, [p.id]))[0].s).toBe(
      'cleared',
    );
  });
});

describe('cart: режим клиента, QR_PROVIDER=onec (ядро §24.4)', () => {
  let t: PosTestApp;

  beforeAll(async () => {
    t = await startCartApp({ env: { QR_PROVIDER: 'onec' } });
  });
  afterAll(async () => {
    await t?.stop();
  });

  it('customer: allowedPaymentMethods=[cash, qr_bakai]; QR допустим; staff — по праву credit.sale.create', async () => {
    const [x] = await t.saleableVariants(1);
    const c = await t.actor({ role: 'customer' });
    const cart = await setItem(t, c, x, '1');
    const res = await t.req('post', '/cart/checkout-preview', c).send({
      cartId: cart.id,
      cartRowVersion: cart.rowVersion,
      paymentMethod: 'qr_bakai',
      delivery: PICKUP,
      receiver: SELF,
    });
    expect(res.status).toBe(200);
    expect(res.body.permissions.allowedPaymentMethods).toEqual(['cash', 'qr_bakai']);
    const s = await t.actor({ role: 'cashier' });
    const sc = await setItem(t, s, x, '1');
    const staff = await t.req('post', '/cart/checkout-preview', s).send({
      cartId: sc.id,
      cartRowVersion: sc.rowVersion,
      paymentMethod: 'qr_bakai',
      delivery: PICKUP,
      receiver: SELF,
    });
    expect(staff.body.permissions.allowedPaymentMethods).toEqual(['cash', 'qr_bakai', 'credit']);
  });
});

import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { PosActor, PosTestApp, SaleableVariant } from '../support/pos-fixture.js';
import { RETAIL_CUSTOMER_ID } from '../support/pos-fixture.js';
import { getCart, setItem, startCartApp } from './cart-support.js';

const PICKUP = { method: 'pickup' } as const;
const SELF = { kind: 'customer' } as const;

/**
 * RM-F-001, RM-F-012 — клиент корзины, склад, скидка сверх лимита, отложенные корзины, checkout-preview, матрица ролей
 * (08 §4.7.4…§4.7.9; 10 CART-020, CART-030…035, DISC-010; 11 §4.3) — **тестовые данные** стенда pos-fixture.
 */
describe('cart: клиент, склад, скидка, отложенные, checkout-preview', () => {
  let t: PosTestApp;
  let a: Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;
  let v: SaleableVariant[];

  beforeAll(async () => {
    t = await startCartApp();
    a = await t.actors();
    v = await t.saleableVariants(10);
  });
  afterAll(async () => {
    await t?.stop();
  });

  it('матрица ролей: owner → 403 на корзину; customer → 403 на отложенные и скидку; 401 без токена', async () => {
    expect((await t.req('get', '/cart')).status).toBe(401);
    expect((await t.req('get', '/cart', a.owner)).status).toBe(403);
    expect((await t.req('post', '/cart/discount', a.owner).send({ percent: '1', rowVersion: 1 })).status).toBe(403);
    expect((await t.req('post', '/cart/park', a.owner, { idem: true }).send({ rowVersion: 1 })).status).toBe(403);
    expect((await t.req('delete', `/cart/parked/${randomUUID()}`, a.owner)).status).toBe(403);
    for (const role of ['seller', 'cashier', 'senior_seller', 'admin', 'customer'] as const) {
      expect((await t.req('get', '/cart', a[role])).status, role).toBe(200);
    }
    const cc = await getCart(t, a.customer);
    expect(
      (await t.req('post', '/cart/discount', a.customer).send({ percent: '1', rowVersion: cc.rowVersion })).status,
    ).toBe(403);
    expect(
      (await t.req('post', '/cart/park', a.customer, { idem: true }).send({ rowVersion: cc.rowVersion })).status,
    ).toBe(403);
    expect((await t.req('get', '/cart/parked', a.customer)).status).toBe(403);
    expect((await t.req('delete', `/cart/parked/${randomUUID()}`, a.customer)).status).toBe(403);
    expect((await t.req('post', `/cart/parked/${randomUUID()}/resume`, a.customer)).status).toBe(403);
    // owner — только чтение всех отложенных (cart.parked.read.all).
    expect((await t.req('get', '/cart/parked?scope=all', a.owner)).status).toBe(200);
    expect((await t.req('get', '/cart/parked?scope=all', a.seller)).status).toBe(403);
  });

  // 12: T-CART-020 (выбор клиента пересчитывает корзину), T-DISC-005 (скидка клиента 1С применяется сервером)
  it('POST/DELETE /cart/customer: вид цены и скидка клиента пересчитаны, цены строк → price_changed; повтор — без версии', async () => {
    const s = await t.actor({ role: 'cashier' });
    await setItem(t, s, v[0], '2');
    const other = await t.q<{ id: string }>(
      `SELECT id FROM price_lists WHERE NOT is_default AND NOT deletion_mark ORDER BY id LIMIT 1`,
    );
    const plId = other[0].id;
    await t.setPrice(v[0].variantId, '999.00', plId);
    await t.pool.query(
      `UPDATE price_lists SET visible_to_roles = visible_to_roles || '{cashier}'::role_code[] WHERE id = $1`,
      [plId],
    );
    const customerId = await t.createOnecCustomer({
      priceListId: plId,
      discountPercent: '3.00',
      phoneE164: '+996555000111',
    });
    const c = await getCart(t, s);
    const set = await t
      .req('post', '/cart/customer', s)
      .send({ customerId, receiver: { kind: 'customer' }, rowVersion: c.rowVersion });
    expect(set.status).toBe(200);
    expect(set.body).toMatchObject({ priceListId: plId, customerDiscountPercent: '3.00' });
    expect(set.body.customer).toMatchObject({ id: customerId, phones: [{ value: '+996555000111' }], hasDebt: false });
    expect(set.body.customer.receivable).toBeUndefined();
    expect(set.body.items[0].unitPrice.amount).toBe('999.00');
    expect(set.body.warnings).toContainEqual(
      expect.objectContaining({
        kind: 'price_changed',
        oldPrice: { amount: v[0].price, currency: 'KGS' },
        newPrice: { amount: '999.00', currency: 'KGS' },
      }),
    );
    // 999 × 2 = 1998, скидка клиента 3 % = 59.94.
    expect(set.body.discountTotal.amount).toBe('59.94');
    const again = await t
      .req('post', '/cart/customer', s)
      .send({ customerId, receiver: { kind: 'customer' }, rowVersion: 0 });
    expect(again.status).toBe(200);
    expect(again.body.rowVersion).toBe(set.body.rowVersion);
    const bad = await t
      .req('post', '/cart/customer', s)
      .send({ customerId, receiver: { kind: 'other_person', name: 'Иван' }, rowVersion: set.body.rowVersion });
    expect(bad.status).toBe(400);
    const other2 = await t.req('post', '/cart/customer', s).send({
      customerId,
      receiver: { kind: 'other_person', name: 'Иван', phone: '+996700123456' },
      rowVersion: set.body.rowVersion,
    });
    expect(other2.status).toBe(200);
    expect(other2.body.receiver).toEqual({ kind: 'other_person', name: 'Иван', phone: '+996700123456' });
    expect(
      (await t.req('post', '/cart/customer', s).send({ customerId: randomUUID(), rowVersion: other2.body.rowVersion }))
        .status,
    ).toBe(404);
    const unset = await t.req('delete', '/cart/customer', s);
    expect(unset.status).toBe(200);
    expect(unset.body).toMatchObject({
      customer: null,
      priceListId: await t.defaultPriceListId(),
      customerDiscountPercent: '0.00',
    });
    // seller — маскированный телефон, без phones.
    const sel = await t.actor({ role: 'seller' });
    const sc = await getCart(t, sel);
    const sv = await t.req('post', '/cart/customer', sel).send({ customerId, rowVersion: sc.rowVersion });
    expect(sv.status).toBe(200);
    expect(sv.body.customer.phoneMasked).toBe('+996 5** *** *11');
    expect(sv.body.customer.phones).toBeUndefined();
  });

  // 12: T-CART-031 (смена склада: доступность пересчитана)
  it('PATCH /cart {warehouseId}: доступность пересчитана, позиции не удалены; тот же склад — без версии; лишнее поле → 400; неизвестный склад → 404', async () => {
    const s = await t.actor({ role: 'seller' });
    const c = await setItem(t, s, v[1], '3');
    const wh2 = (
      await t.q<{ id: string }>(
        `SELECT id FROM warehouses WHERE is_active AND NOT deletion_mark AND id <> $1 ORDER BY id LIMIT 1`,
        [c.warehouseId],
      )
    )[0].id;
    await t.setStock(v[1].variantId, '1', wh2);
    const res = await t.req('patch', '/cart', s).send({ warehouseId: wh2, rowVersion: c.rowVersion });
    expect(res.status).toBe(200);
    expect(res.body.warehouseId).toBe(wh2);
    expect(res.body.rowVersion).toBe(c.rowVersion + 1);
    expect(res.body.items).toHaveLength(1);
    expect(res.body.items[0]).toMatchObject({
      available: '1.000',
      remainingAvailable: '0.000',
      warnings: ['stock_insufficient'],
    });
    const flags = await t.q<{ stock_insufficient: boolean; stock_snapshot: string }>(
      `SELECT stock_insufficient, stock_snapshot::text FROM cart_items WHERE cart_id = $1`,
      [c.id],
    );
    expect(flags[0]).toMatchObject({ stock_insufficient: true, stock_snapshot: '1.000' });
    const same = await t.req('patch', '/cart', s).send({ warehouseId: wh2, rowVersion: 0 });
    expect(same.status).toBe(200);
    expect(same.body.rowVersion).toBe(res.body.rowVersion);
    const extra = await t
      .req('patch', '/cart', s)
      .send({ warehouseId: wh2, rowVersion: res.body.rowVersion, customerId: randomUUID() });
    expect(extra.status).toBe(400);
    expect(extra.body.errors[0]).toMatchObject({ field: 'customerId', rule: 'forbidden_field' });
    expect(
      (await t.req('patch', '/cart', s).send({ warehouseId: randomUUID(), rowVersion: res.body.rowVersion })).status,
    ).toBe(404);
    const stale = await t.req('patch', '/cart', s).send({ warehouseId: c.warehouseId, rowVersion: c.rowVersion });
    expect(stale.status).toBe(409);
  });

  // 12: T-SEC-022 (скидка сверх лимита роли: 422 / подтверждение со step-up / аудит), T-DISC-003
  it('скидка сверх лимита: senior_seller без override → 422 (requiresRole); override без step-up → STEP_UP_REQUIRED; seller с override → 403; со step-up → применена и аудит', async () => {
    await t.pool.query(
      `UPDATE role_discount_limits SET approve_max_percent = 20, row_version = row_version + 1 WHERE role = 'senior_seller'`,
    );
    const s = a.senior_seller;
    const c = await setItem(t, s, v[2], '1');
    const over = await t.req('post', '/cart/discount', s).send({ percent: '15', rowVersion: c.rowVersion });
    expect(over.status).toBe(422);
    expect(over.body).toMatchObject({
      code: 'DISCOUNT_LIMIT_EXCEEDED',
      limitPercent: '10.00',
      requiresRole: 'admin',
    });
    const noStep = await t
      .req('post', '/cart/discount', s)
      .send({ percent: '15', rowVersion: c.rowVersion, override: { reason: 'постоянный клиент' } });
    expect(noStep.status).toBe(403);
    expect(noStep.body).toMatchObject({
      code: 'STEP_UP_REQUIRED',
      stepUp: { operation: 'discount.approve.over_limit' },
    });
    const sc = await setItem(t, a.seller, v[2], '1');
    const sellerOverride = await t
      .req('post', '/cart/discount', a.seller, { stepUp: await t.stepUp(a.seller, 'discount.approve.over_limit') })
      .send({ percent: '7', rowVersion: sc.rowVersion, override: { reason: 'постоянный клиент' } });
    expect(sellerOverride.status).toBe(403);
    expect(sellerOverride.body.code).toBe('FORBIDDEN');
    const ok = await t
      .req('post', '/cart/discount', s, { stepUp: await t.stepUp(s, 'discount.approve.over_limit') })
      .send({ percent: '15', rowVersion: c.rowVersion, override: { reason: 'постоянный клиент' } });
    expect(ok.status).toBe(200);
    expect(ok.body).toMatchObject({ requestedDiscountPercent: '15.00', appliedDiscountPercent: '15.00' });
    const row = await t.q<{ by: string; reason: string }>(
      `SELECT discount_approved_by_user_id AS by, discount_override_reason AS reason FROM carts WHERE id = $1`,
      [c.id],
    );
    expect(row[0]).toEqual({ by: s.userId, reason: 'постоянный клиент' });
    const audit = await t.auditRows('discount.over_limit_approved', c.id);
    expect(audit).toHaveLength(1);
    expect(audit[0].step_up_method).toBe('pin');
    expect(
      (await t.req('post', '/cart/discount', s).send({ percent: '101', rowVersion: ok.body.rowVersion })).status,
    ).toBe(400);
  });

  // 12: T-CART-025 (park → parked, новая active), T-CART-026 (список: свои / все), T-CART-027 (возобновление, replaceActive), T-CART-029 (чужая: cart.parked.resume.any, аудит; seller → 403), T-CART-030 (удаление своей / чужой → 403)
  it('park / parked / resume / delete: своя и чужая (cart.parked.resume.any), аудит, replaceActive', async () => {
    const s = await t.actor({ role: 'seller' });
    const senior = await t.actor({ role: 'senior_seller' });
    const c = await setItem(t, s, v[3], '2');
    const noKey = await t.req('post', '/cart/park', s).send({ rowVersion: c.rowVersion });
    expect(noKey.status).toBe(400);
    const park = await t
      .req('post', '/cart/park', s, { idem: true })
      .send({ name: 'Иван, доставка', rowVersion: c.rowVersion });
    expect(park.status).toBe(201);
    expect(park.body.parked).toMatchObject({ id: c.id, status: 'parked', name: 'Иван, доставка', itemsCount: 1 });
    expect(park.body.parked.expiresAt).not.toBeNull();
    expect(park.body.active).toMatchObject({ status: 'active', items: [] });
    expect(await t.auditRows('cart.parked', c.id)).toHaveLength(1);
    // Пустую не откладывают.
    expect(
      (await t.req('post', '/cart/park', s, { idem: true }).send({ rowVersion: park.body.active.rowVersion })).status,
    ).toBe(422);
    // Второй отложенный: имя по умолчанию «Без клиента · HH:MM».
    const c2 = await setItem(t, s, v[4], '1');
    const p2 = await t.req('post', '/cart/park', s, { idem: true }).send({ rowVersion: c2.rowVersion });
    expect(p2.body.parked.name).toMatch(/^Без клиента · \d{2}:\d{2}$/);
    const own = await t.req('get', '/cart/parked', s);
    expect(own.status).toBe(200);
    expect((own.body.items as { id: string }[]).map((x) => x.id)).toEqual([c2.id, c.id]);
    expect(own.body.items[1]).toMatchObject({ owner: { id: s.userId }, itemsCount: 1, total: { currency: 'KGS' } });
    expect(own.body.items[1].items).toBeUndefined();
    const page1 = await t.req('get', '/cart/parked?limit=1', s);
    expect(page1.body.hasMore).toBe(true);
    const page2 = await t.req('get', `/cart/parked?limit=1&cursor=${encodeURIComponent(page1.body.nextCursor)}`, s);
    expect(page2.body.items[0].id).toBe(c.id);
    expect((await t.req('get', '/cart/parked?cursor=forged.x', s)).status).toBe(400);
    const all = await t.req('get', '/cart/parked?scope=all', senior);
    expect((all.body.items as { id: string }[]).map((x) => x.id)).toEqual(expect.arrayContaining([c.id, c2.id]));
    // Чужая без права: resume/delete → 404 (существование не раскрывается).
    const other = await t.actor({ role: 'cashier' });
    expect((await t.req('post', `/cart/parked/${c.id}/resume`, other)).status).toBe(404);
    expect((await t.req('delete', `/cart/parked/${c.id}`, other)).status).toBe(404);
    // Возобновление своей при непустой активной → 409 active_not_empty; replaceActive=true — автосохранение.
    await setItem(t, s, v[5], '1');
    const busy = await t.req('post', `/cart/parked/${c.id}/resume`, s).send({});
    expect(busy.status).toBe(409);
    expect(busy.body).toMatchObject({ code: 'ORDER_STATE_INVALID', resource: 'cart', reason: 'active_not_empty' });
    const resumed = await t.req('post', `/cart/parked/${c.id}/resume`, s).send({ replaceActive: true });
    expect(resumed.status).toBe(200);
    expect(resumed.body).toMatchObject({ id: c.id, status: 'active', parkedAt: null, expiresAt: null });
    const auto = (await t.req('get', '/cart/parked', s)).body.items as { name: string }[];
    expect(auto.some((x) => /^Автосохранение \d{2}:\d{2}$/.test(x.name))).toBe(true);
    expect(await t.auditRows('cart.resumed', c.id)).toHaveLength(1);
    // Повтор resume уже активной → 200 с текущей.
    const again = await t.req('post', `/cart/parked/${c.id}/resume`, s);
    expect(again.status).toBe(200);
    expect(again.body.id).toBe(c.id);
    // DELETE активной → 409 not_parked.
    const notParked = await t.req('delete', `/cart/parked/${c.id}`, s);
    expect(notParked.status).toBe(409);
    expect(notParked.body.reason).toBe('not_parked');
    // Чужая с правом: senior_seller возобновляет (аудит resumed_foreign, владелец меняется) и удаляет чужую.
    const foreign = await t.req('post', `/cart/parked/${c2.id}/resume`, senior);
    expect(foreign.status).toBe(200);
    expect(foreign.body.ownerId).toBe(senior.userId);
    const fa = await t.auditRows('cart.resumed_foreign', c2.id);
    expect(fa).toHaveLength(1);
    expect(fa[0].after).toMatchObject({ ownerId: s.userId, resumedBy: senior.userId });
    const row = await t.q<{ created_by_user_id: string }>(`SELECT created_by_user_id FROM carts WHERE id = $1`, [
      c2.id,
    ]);
    expect(row[0].created_by_user_id).toBe(s.userId);
    const autoId = (await t.req('get', '/cart/parked', s)).body.items[0].id as string;
    const del = await t.req('delete', `/cart/parked/${autoId}`, senior);
    expect(del.status).toBe(204);
    expect((await t.req('delete', `/cart/parked/${autoId}`, senior)).status).toBe(204);
    const da = await t.auditRows('cart.cleared', autoId);
    expect(da[0].after).toMatchObject({ parked: true, foreign: true, ownerId: s.userId });
    expect((await t.req('get', '/cart/parked', s)).body.items).toHaveLength(0);
    expect((await t.req('delete', '/cart/parked/not-uuid', s)).status).toBe(400);
  });

  // 12: T-CART-009 (в) (CART_EMPTY), T-DISC-011 (итоги: только ручная скидка и скидка клиента)
  it('checkout-preview: CART_EMPTY; изменение цены → conflicts с обеими ценами (RM-F-001 п. 4); итоги, permissions, previewToken', async () => {
    const s = await t.actor({ role: 'cashier' });
    const empty = await getCart(t, s);
    const e = await t.req('post', '/cart/checkout-preview', s).send({
      cartId: empty.id,
      cartRowVersion: empty.rowVersion,
      paymentMethod: 'cash',
      delivery: PICKUP,
      receiver: SELF,
    });
    expect(e.status).toBe(422);
    expect(e.body.code).toBe('CART_EMPTY');
    const c = await setItem(t, s, v[6], '2');
    const ok = await t
      .req('post', '/cart/checkout-preview', s)
      .send({ cartId: c.id, cartRowVersion: c.rowVersion, paymentMethod: 'cash', delivery: PICKUP, receiver: SELF });
    expect(ok.status).toBe(200);
    expect(ok.body).toMatchObject({
      cartId: c.id,
      cartRowVersion: c.rowVersion,
      ok: true,
      conflicts: [],
      cashRounding: '0.00',
      paymentMethod: 'cash',
      onecCheck: { performed: true, result: 'ok' },
      permissions: {
        canCreateOrder: true,
        canApplyDiscount: true,
        discountLimitPercent: '5.00',
        canSellOnCredit: true,
        needsOverride: [],
        allowedPaymentMethods: ['cash', 'qr_bakai', 'credit'],
      },
    });
    expect(ok.body.items[0]).toMatchObject({ lineNo: 1, variantId: v[6].variantId, baseQuantity: '2.000' });
    expect(typeof ok.body.previewToken).toBe('string');
    expect(new Date(ok.body.validUntil).getTime()).toBeGreaterThan(Date.now());
    const newPrice = '1234.56';
    await t.setPrice(v[6].variantId, newPrice);
    const changed = await t
      .req('post', '/cart/checkout-preview', s)
      .send({ cartId: c.id, cartRowVersion: c.rowVersion, paymentMethod: 'cash', delivery: PICKUP, receiver: SELF });
    expect(changed.status).toBe(200);
    expect(changed.body.ok).toBe(false);
    expect(changed.body.conflicts).toContainEqual({
      variantId: v[6].variantId,
      kind: 'price_changed',
      oldPrice: { amount: v[6].price, currency: 'KGS' },
      newPrice: { amount: newPrice, currency: 'KGS' },
    });
    expect(changed.body.total.amount).toBe('2469.12');
    expect(changed.body.permissions.canCreateOrder).toBe(false);
    // Без побочных эффектов: версия корзины не изменилась.
    expect((await getCart(t, s)).rowVersion).toBe(c.rowVersion);
    // «Принять новые цены» — PUT с priceSnapshot (CART-013) снимает конфликт.
    const accept = await t.req('put', `/cart/items/${v[6].variantId}`, s).send({
      quantity: { value: '2', unitId: v[6].unitId },
      priceSnapshot: { amount: newPrice, currency: 'KGS' },
      rowVersion: c.rowVersion,
    });
    expect(accept.status).toBe(200);
    expect(accept.body.warnings).toEqual([]);
    const stale = await t
      .req('post', '/cart/checkout-preview', s)
      .send({ cartId: c.id, cartRowVersion: c.rowVersion, paymentMethod: 'cash', delivery: PICKUP, receiver: SELF });
    expect(stale.status).toBe(409);
    expect(
      (
        await t
          .req('post', '/cart/checkout-preview', s)
          .send({ cartId: randomUUID(), cartRowVersion: 1, paymentMethod: 'cash', delivery: PICKUP, receiver: SELF })
      ).status,
    ).toBe(404);
  });

  // 12: T-CART-007 (нехватка блокирует оформление), T-CART-015 (VARIANT_UNAVAILABLE)
  it('checkout-preview: нехватка и недоступность (все конфликты одним ответом), доставка без адреса → 400, geo → forbidden_field, total от клиента → аудит', async () => {
    const s = await t.actor({ role: 'cashier' });
    await setItem(t, s, v[7], '5');
    const c = await setItem(t, s, v[8], '1');
    await t.setStock(v[7].variantId, '3', v[7].warehouseId);
    await t.pool.query(`UPDATE product_variants SET deletion_mark = true WHERE id = $1`, [v[8].variantId]);
    const res = await t
      .req('post', '/cart/checkout-preview', s)
      .send({ cartId: c.id, cartRowVersion: c.rowVersion, paymentMethod: 'cash', delivery: PICKUP, receiver: SELF });
    expect(res.status).toBe(200);
    expect(res.body.ok).toBe(false);
    expect(res.body.conflicts).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ variantId: v[7].variantId, kind: 'stock_insufficient', available: '3.000' }),
        expect.objectContaining({ variantId: v[8].variantId, kind: 'variant_unavailable' }),
      ]),
    );
    await t.pool.query(`UPDATE product_variants SET deletion_mark = false WHERE id = $1`, [v[8].variantId]);
    const noAddr = await t.req('post', '/cart/checkout-preview', s).send({
      cartId: c.id,
      cartRowVersion: c.rowVersion,
      paymentMethod: 'cash',
      delivery: { method: 'delivery' },
      receiver: SELF,
    });
    expect(noAddr.status).toBe(400);
    expect((noAddr.body.errors as { field: string }[]).map((x) => x.field)).toEqual(
      expect.arrayContaining(['delivery.address', 'delivery.recipientPhone']),
    );
    const geo = await t.req('post', '/cart/checkout-preview', s).send({
      cartId: c.id,
      cartRowVersion: c.rowVersion,
      paymentMethod: 'cash',
      delivery: { method: 'pickup', geo: { lat: 1, lng: 2 } },
      receiver: SELF,
    });
    expect(geo.status).toBe(400);
    expect(geo.body.errors[0]).toMatchObject({ field: 'delivery.geo', rule: 'forbidden_field' });
    const total = await t.req('post', '/cart/checkout-preview', s).send({
      cartId: c.id,
      cartRowVersion: c.rowVersion,
      paymentMethod: 'cash',
      delivery: PICKUP,
      receiver: SELF,
      total: '1.00',
    });
    expect(total.status).toBe(400);
    expect(
      await t.q(`SELECT 1 FROM audit_logs WHERE action = 'price.override_attempt' AND actor_user_id = $1`, [s.userId]),
    ).toHaveLength(1);
  });

  // 12: T-ORD-006 (доступность «Без оплаты · долг» по ответу сервера), T-PAY-033 (порядок PAY-031: шаг 1 и fail-closed)
  it('checkout-preview: продажа в долг — CUSTOMER_NOT_IDENTIFIED; fail-closed до G (creditAllowed=false; strict → 422 CREDIT_BLOCKED); admin (без credit.sale.create) → forbidden_role (strict → 403)', async () => {
    const s = await t.actor({ role: 'cashier' });
    const c = await setItem(t, s, v[9], '1');
    const body = {
      cartId: c.id,
      cartRowVersion: c.rowVersion,
      paymentMethod: 'credit',
      delivery: PICKUP,
      receiver: SELF,
    };
    const noCustomer = await t.req('post', '/cart/checkout-preview', s).send(body);
    expect(noCustomer.status).toBe(422);
    expect(noCustomer.body.code).toBe('CUSTOMER_NOT_IDENTIFIED');
    const retail = await t
      .req('post', '/cart/customer', s)
      .send({ customerId: RETAIL_CUSTOMER_ID, rowVersion: c.rowVersion });
    expect(retail.status).toBe(200);
    expect(
      (await t.req('post', '/cart/checkout-preview', s).send({ ...body, cartRowVersion: retail.body.rowVersion })).body
        .code,
    ).toBe('CUSTOMER_NOT_IDENTIFIED');
    const customerId = await t.createOnecCustomer({
      creditAllowed: true,
      creditLimit: '100000.00',
      receivables: { balance: '0.00', overdue: '0.00' },
    });
    const withC = await t.req('post', '/cart/customer', s).send({ customerId, rowVersion: retail.body.rowVersion });
    const soft = await t
      .req('post', '/cart/checkout-preview', s)
      .send({ ...body, cartRowVersion: withC.body.rowVersion });
    expect(soft.status).toBe(200);
    expect(soft.body.paymentChecks).toMatchObject({ creditAllowed: false });
    expect(soft.body.permissions.canSellOnCredit).toBe(true);
    // Отказ по долгу без права override → «Создать заказ» недоступна (10 ORD-007; ревью F-money-rules-8).
    expect(soft.body.permissions).toMatchObject({ canCreateOrder: false, needsOverride: [] });
    const strict = await t
      .req('post', '/cart/checkout-preview', s)
      .send({ ...body, cartRowVersion: withC.body.rowVersion, strict: true });
    expect(strict.status).toBe(422);
    expect(strict.body.code).toBe('CREDIT_BLOCKED');
    const sel = await t.actor({ role: 'admin' });
    const sc = await setItem(t, sel, v[9], '1');
    const sb = {
      cartId: sc.id,
      cartRowVersion: sc.rowVersion,
      paymentMethod: 'credit',
      delivery: PICKUP,
      receiver: SELF,
    };
    const forb = await t.req('post', '/cart/checkout-preview', sel).send(sb);
    expect(forb.status).toBe(200);
    expect(forb.body.paymentChecks).toMatchObject({ creditAllowed: false, creditReason: 'forbidden_role' });
    expect(forb.body.permissions).toMatchObject({
      canSellOnCredit: false,
      allowedPaymentMethods: ['cash', 'qr_bakai'],
    });
    const forbStrict = await t.req('post', '/cart/checkout-preview', sel).send({ ...sb, strict: true });
    expect(forbStrict.status).toBe(403);
    expect(forbStrict.body).toMatchObject({ code: 'FORBIDDEN', creditReason: 'forbidden_role' });
  });

  // 12: T-FAIL-008 (1С недоступна → unavailable + STALE_DATA), T-SYNC-041 (/check при оформлении)
  it('checkout-preview: 1С недоступна (таймаут/503) → onecCheck.result=unavailable + STALE_DATA; syncCheckWithOnec=false — без вызова', async () => {
    const s = await t.actor({ role: 'senior_seller' });
    const c = await setItem(t, s, v[0], '1');
    t.onec.script('checkCart', { error: 503 });
    const res = await t.req('post', '/cart/checkout-preview', s).send({
      cartId: c.id,
      cartRowVersion: c.rowVersion,
      paymentMethod: 'qr_bakai',
      delivery: PICKUP,
      receiver: SELF,
    });
    expect(res.status).toBe(200);
    expect(res.body.onecCheck).toMatchObject({ performed: true, result: 'unavailable' });
    expect(res.body.warnings).toContainEqual(expect.objectContaining({ code: 'STALE_DATA' }));
    const calls = t.onec.callsOf('checkCart').length;
    const skip = await t.req('post', '/cart/checkout-preview', s).send({
      cartId: c.id,
      cartRowVersion: c.rowVersion,
      paymentMethod: 'cash',
      delivery: PICKUP,
      receiver: SELF,
      syncCheckWithOnec: false,
    });
    expect(skip.body.onecCheck.performed).toBe(false);
    expect(t.onec.callsOf('checkCart').length).toBe(calls);
  });

  it('реплика каталога не загружена (нет активного склада) → GET /cart 503 ONEC_UNAVAILABLE catalog_not_loaded с Retry-After, не 500', async () => {
    const s = await t.actor({ role: 'seller' });
    const active = await t.q<{ id: string }>(`SELECT id FROM warehouses WHERE is_active`);
    await t.q(`UPDATE warehouses SET is_active = false WHERE is_active`);
    try {
      const res = await t.req('get', '/cart', s);
      expect(res.status, JSON.stringify(res.body)).toBe(503);
      expect(res.body).toMatchObject({ code: 'ONEC_UNAVAILABLE', reason: 'catalog_not_loaded' });
      expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
    } finally {
      await t.q(`UPDATE warehouses SET is_active = true WHERE id = ANY($1::uuid[])`, [active.map((x) => x.id)]);
    }
    expect((await t.req('get', '/cart', s)).status).toBe(200);
  });
});

import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { Money } from '../../src/common/money/money.js';
import type { PosActor, PosTestApp, SaleableVariant } from '../support/pos-fixture.js';
import { getCart, setItem, startCartApp, variantWithPackaging } from './cart-support.js';

/**
 * RM-F-001 / RM-F-012 / T-CART-001…T-CART-024 — корзина 08 §4.7.1…§4.7.3 на стенде pos-fixture (**тестовые данные**):
 * создание активной корзины, PUT/DELETE позиций (упаковки, `packagingId`), `rowVersion` → `VERSION_CONFLICT`,
 * идемпотентность `mode=increment`, запрет цен от клиента (`forbidden_field` + аудит), остатки (`remainingAvailable`,
 * неизвестный остаток → `STOCK_INSUFFICIENT`), очистка с аудитом, денежный критерий RM-F-001 п. 1–3, `max_items`.
 */
describe('cart: позиции, версии, деньги (08 §4.7.1–§4.7.3)', () => {
  let t: PosTestApp;
  let seller: PosActor;
  let v: SaleableVariant[];

  beforeAll(async () => {
    t = await startCartApp({ skuCount: 260 });
    seller = await t.actor({ role: 'seller' });
    v = await t.saleableVariants(12);
  });
  afterAll(async () => {
    await t?.stop();
  });

  // 12: T-CART-013 (сервер — источник истины: одна active на пользователя, GET /cart)
  it('GET /cart: всегда 200 — пустая active корзина создаётся один раз (одна active на пользователя)', async () => {
    const a = await t.actor({ role: 'cashier' });
    const first = await t.req('get', '/cart', a);
    expect(first.status).toBe(200);
    expect(first.headers['cache-control']).toBe('no-store');
    expect(first.body).toMatchObject({
      status: 'active',
      items: [],
      itemsCount: 0,
      ownerId: a.userId,
      warehouseId: await t.defaultWarehouseId(),
      priceListId: await t.defaultPriceListId(),
      subtotal: { amount: '0.00', currency: 'KGS' },
      total: { amount: '0.00', currency: 'KGS' },
      restoredFromOrderId: null,
      restoredFromOrder: null,
      customer: null,
      receiver: { kind: 'customer', name: null, phone: null },
      discountLimitPercent: '5.00',
    });
    const second = await t.req('get', '/cart', a);
    expect(second.body.id).toBe(first.body.id);
    const n = await t.q<{ n: number }>(
      `SELECT count(*)::int AS n FROM carts WHERE owner_user_id = $1 AND status = 'active'`,
      [a.userId],
    );
    expect(n[0].n).toBe(1);
  });

  // 12: T-CART-003 (PUT /cart/items, итог пересчитан сервером), T-MNY-031 (деньги строкой + KGS)
  it('PUT: строка добавлена, цены — с сервера, rowVersion +1, remainingAvailable = available − количество', async () => {
    const a = await t.actor({ role: 'seller' });
    const before = await getCart(t, a);
    const reservedBefore = await t.q<{ r: string }>(
      `SELECT reserved::text AS r FROM stock_balances WHERE variant_id = $1 AND warehouse_id = $2`,
      [v[0].variantId, v[0].warehouseId],
    );
    const res = await t
      .req('put', `/cart/items/${v[0].variantId}`, a)
      .send({ quantity: { value: '2', unitId: v[0].unitId }, rowVersion: before.rowVersion });
    expect(res.status).toBe(200);
    expect(res.body.rowVersion).toBe(before.rowVersion + 1);
    const item = res.body.items[0];
    expect(item).toMatchObject({
      variantId: v[0].variantId,
      quantity: { value: '2.000', unitId: v[0].unitId, packagingId: null, baseValue: '2.000' },
      unitPrice: { amount: v[0].price, currency: 'KGS' },
      priceSnapshot: { amount: v[0].price, currency: 'KGS' },
      lineTotal: { amount: Money.of(v[0].price).times('2').toString(), currency: 'KGS' },
      warnings: [],
    });
    const avail = (
      await t.q<{ a: string }>(
        `SELECT available::text AS a FROM stock_balances WHERE variant_id = $1 AND warehouse_id = $2`,
        [v[0].variantId, v[0].warehouseId],
      )
    )[0].a;
    expect(item.available).toBe(Number(avail).toFixed(3)); // money-double: allow — сравнение формата количества в тесте
    expect(item.remainingAvailable).toBe((Number(avail) - 2).toFixed(3)); // money-double: allow — тест формата
    expect(res.body.subtotal.amount).toBe(Money.of(v[0].price).times('2').toString());
    // Корзина не резервирует (T-CART-019, INV-024).
    const reserved = await t.q<{ r: string }>(
      `SELECT reserved::text AS r FROM stock_balances WHERE variant_id = $1 AND warehouse_id = $2`,
      [v[0].variantId, v[0].warehouseId],
    );
    expect(reserved[0].r).toBe(reservedBefore[0].r);
  });

  it('VERSION_CONFLICT: устаревший rowVersion → 409 с current: Cart; повтор того же set — 200 без изменения версии', async () => {
    const a = await t.actor({ role: 'seller' });
    const c1 = await setItem(t, a, v[1], '1');
    await setItem(t, a, v[2], '1');
    const stale = await t
      .req('put', `/cart/items/${v[1].variantId}`, a)
      .send({ quantity: { value: '3', unitId: v[1].unitId }, rowVersion: c1.rowVersion - 1 });
    expect(stale.status).toBe(409);
    expect(stale.body.code).toBe('VERSION_CONFLICT');
    expect(stale.body.current).toMatchObject({ id: c1.id, itemsCount: 2 });
    const cur = await getCart(t, a);
    const same = await t
      .req('put', `/cart/items/${v[1].variantId}`, a)
      .send({ quantity: { value: '1', unitId: v[1].unitId }, rowVersion: 0 });
    expect(same.status).toBe(200);
    expect(same.body.rowVersion).toBe(cur.rowVersion);
  });

  it('mode=increment: без Idempotency-Key → 400; с ключом повтор увеличивает один раз (Idempotent-Replayed)', async () => {
    const a = await t.actor({ role: 'seller' });
    const c = await setItem(t, a, v[3], '1');
    const body = { quantity: { value: '2', unitId: v[3].unitId }, rowVersion: c.rowVersion, mode: 'increment' };
    const noKey = await t.req('put', `/cart/items/${v[3].variantId}`, a).send(body);
    expect(noKey.status).toBe(400);
    expect(noKey.body.errors[0]).toMatchObject({ rule: 'idempotency_key_required' });
    const key = randomUUID();
    const r1 = await t.req('put', `/cart/items/${v[3].variantId}`, a, { idem: key }).send(body);
    expect(r1.status).toBe(200);
    expect(r1.body.items[0].quantity.value).toBe('3.000');
    const r2 = await t.req('put', `/cart/items/${v[3].variantId}`, a, { idem: key }).send(body);
    expect(r2.status).toBe(200);
    expect(r2.headers['idempotent-replayed']).toBe('true');
    expect((await getCart(t, a)).items[0].quantity.value).toBe('3.000');
    const reused = await t
      .req('put', `/cart/items/${v[3].variantId}`, a, { idem: key })
      .send({ ...body, quantity: { value: '5', unitId: v[3].unitId } });
    expect(reused.status).toBe(422);
    expect(reused.body.code).toBe('IDEMPOTENCY_KEY_REUSED');
  });

  it('цена от клиента → 400 forbidden_field + аудит price.override_attempt; лишнее поле → additional_properties', async () => {
    const a = await t.actor({ role: 'seller' });
    const c = await getCart(t, a);
    const res = await t
      .req('put', `/cart/items/${v[4].variantId}`, a)
      .send({ quantity: { value: '1', unitId: v[4].unitId }, rowVersion: c.rowVersion, unitPrice: '1.00' });
    expect(res.status).toBe(400);
    expect(res.body.errors).toContainEqual(expect.objectContaining({ field: 'unitPrice', rule: 'forbidden_field' }));
    const audit = await t.q<{ actor_user_id: string; result: string }>(
      `SELECT actor_user_id, result FROM audit_logs WHERE action = 'price.override_attempt' AND actor_user_id = $1`,
      [a.userId],
    );
    expect(audit).toHaveLength(1);
    expect(audit[0].result).toBe('denied');
    const extra = await t
      .req('put', `/cart/items/${v[4].variantId}`, a)
      .send({ quantity: { value: '1', unitId: v[4].unitId }, rowVersion: c.rowVersion, foo: 1 });
    expect(extra.status).toBe(400);
    expect(extra.body.errors[0]).toMatchObject({ field: 'foo', rule: 'additional_properties' });
    expect((await t.req('put', '/cart/items/not-a-uuid', a).send({})).status).toBe(400);
  });

  // 12: T-CART-015 (422 VARIANT_UNAVAILABLE)
  it('ошибки PUT: неизвестный вариант → 422 VARIANT_UNAVAILABLE; дробное «шт» → 400 qty_precision; чужая единица → 400', async () => {
    const a = await t.actor({ role: 'seller' });
    const c = await getCart(t, a);
    const unknown = await t
      .req('put', `/cart/items/${randomUUID()}`, a)
      .send({ quantity: { value: '1', unitId: v[5].unitId }, rowVersion: c.rowVersion });
    expect(unknown.status).toBe(422);
    expect(unknown.body.code).toBe('VARIANT_UNAVAILABLE');
    const frac = await t
      .req('put', `/cart/items/${v[5].variantId}`, a)
      .send({ quantity: { value: '1.5', unitId: v[5].unitId }, rowVersion: c.rowVersion });
    expect(frac.status).toBe(400);
    expect(frac.body.errors[0]).toMatchObject({ rule: 'qty_precision' });
    const unit = await t
      .req('put', `/cart/items/${v[5].variantId}`, a)
      .send({ quantity: { value: '1', unitId: randomUUID() }, rowVersion: c.rowVersion });
    expect(unit.status).toBe(400);
    expect(unit.body.errors[0]).toMatchObject({ rule: 'unit_mismatch' });
  });

  // 12: T-CART-007 (нехватка — warnings stock_insufficient, «Доступно N»)
  it('остатки: сверх остатка — не ошибка (warnings stock_insufficient); неизвестный остаток → 422 stock_unknown', async () => {
    const a = await t.actor({ role: 'seller' });
    const [x] = await t.saleableVariants(1, {});
    await t.setStock(v[6].variantId, '2', v[6].warehouseId);
    const over = await setItem(t, a, v[6], '3');
    expect(over.items[0].warnings).toEqual(['stock_insufficient']);
    expect(over.items[0].remainingAvailable).toBe('0.000');
    expect(over.warnings).toContainEqual(
      expect.objectContaining({
        variantId: v[6].variantId,
        kind: 'stock_insufficient',
        available: '2.000',
        stockLevel: 'low',
      }),
    );
    await t.pool.query(`DELETE FROM stock_balances WHERE variant_id = $1 AND warehouse_id = $2`, [
      v[7].variantId,
      v[7].warehouseId,
    ]);
    const c = await getCart(t, a);
    const unknown = await t
      .req('put', `/cart/items/${v[7].variantId}`, a)
      .send({ quantity: { value: '1', unitId: v[7].unitId }, rowVersion: c.rowVersion });
    expect(unknown.status).toBe(422);
    expect(unknown.body).toMatchObject({ code: 'STOCK_INSUFFICIENT', reason: 'stock_unknown' });
    expect(unknown.body.conflicts[0]).toMatchObject({ variantId: v[7].variantId, available: null });
    expect(x).toBeDefined();
  });

  // 12: T-CART-002 (DELETE /cart/items/{variantId}?packagingId=), T-CART-023 (адресация строки с упаковкой)
  it('упаковки: строка = вариант + упаковка; remainingAvailable по всем упаковкам; DELETE с packagingId — только эта строка', async () => {
    const a = await t.actor({ role: 'seller' });
    const p = await variantWithPackaging(t);
    await setItem(t, a, { variantId: p.variantId, unitId: p.unitId }, '2');
    const both = await setItem(
      t,
      a,
      { variantId: p.variantId, unitId: p.unitId },
      '1',
      p.packagingId,
      p.packagingUnitId,
    );
    expect(both.items).toHaveLength(2);
    const pack = both.items.find((i) => i.quantity.packagingId === p.packagingId)!;
    const factor = Number(p.factor); // money-double: allow — коэффициент упаковки в тесте
    expect(pack.quantity.baseValue).toBe(factor.toFixed(3)); // money-double: allow — тест формата
    expect(pack.packaging).toMatchObject({ id: p.packagingId });
    expect(pack.unitPrice.amount).toBe(Money.of(p.price).times(p.factor).toString());
    const base = both.items.find((i) => i.quantity.packagingId === null)!;
    expect(base.remainingAvailable).toBe(pack.remainingAvailable);
    expect(Number(base.available) - Number(base.remainingAvailable)).toBe(factor + 2); // money-double: allow — тест
    // MV-07 (10 §18.1): дробное количество упаковок (2,5 кор) — ошибка, «Количество упаковок должно быть целым».
    const half = await t.req('put', `/cart/items/${p.variantId}`, a).send({
      quantity: { value: '2.5', unitId: p.packagingUnitId, packagingId: p.packagingId },
      rowVersion: both.rowVersion,
    });
    expect(half.status).toBe(400);
    expect(half.body.errors[0]).toMatchObject({ field: 'quantity.value', rule: 'qty_precision' });
    const del = await t.req('delete', `/cart/items/${p.variantId}?packagingId=${p.packagingId}`, a);
    expect(del.status).toBe(200);
    expect(del.body.items).toHaveLength(1);
    expect(del.body.items[0].quantity.packagingId).toBeNull();
    const again = await t.req('delete', `/cart/items/${p.variantId}?packagingId=${p.packagingId}`, a);
    expect(again.status).toBe(200);
    expect(again.body.rowVersion).toBe(del.body.rowVersion);
    expect((await t.req('delete', `/cart/items/${p.variantId}?packagingId=xyz`, a)).status).toBe(400);
    await setItem(t, a, { variantId: p.variantId, unitId: p.unitId }, '1', p.packagingId, p.packagingUnitId);
    const all = await t.req('delete', `/cart/items/${p.variantId}`, a);
    expect(all.body.items).toHaveLength(0);
    // Упаковка — целое число (INV-006).
    const c = await getCart(t, a);
    const frac = await t.req('put', `/cart/items/${p.variantId}`, a).send({
      quantity: { value: '1.5', unitId: p.packagingUnitId, packagingId: p.packagingId },
      rowVersion: c.rowVersion,
    });
    expect(frac.status).toBe(400);
  });

  it('кратность и минимальная партия: QTY_NOT_MULTIPLE / QTY_BELOW_MIN (422)', async () => {
    const a = await t.actor({ role: 'seller' });
    await t.pool.query(`UPDATE products SET multiplicity = 4 WHERE id = $1`, [v[8].productId]);
    await t.pool.query(`UPDATE products SET min_qty = 5 WHERE id = $1`, [v[9].productId]);
    const c = await getCart(t, a);
    const m = await t
      .req('put', `/cart/items/${v[8].variantId}`, a)
      .send({ quantity: { value: '6', unitId: v[8].unitId }, rowVersion: c.rowVersion });
    expect(m.status).toBe(422);
    expect(m.body.code).toBe('QTY_NOT_MULTIPLE');
    const ok = await t
      .req('put', `/cart/items/${v[8].variantId}`, a)
      .send({ quantity: { value: '8', unitId: v[8].unitId }, rowVersion: c.rowVersion });
    expect(ok.status).toBe(200);
    const min = await t
      .req('put', `/cart/items/${v[9].variantId}`, a)
      .send({ quantity: { value: '2', unitId: v[9].unitId }, rowVersion: ok.body.rowVersion });
    expect(min.status).toBe(422);
    expect(min.body.code).toBe('QTY_BELOW_MIN');
    await t.pool.query(`UPDATE products SET multiplicity = NULL, min_qty = NULL WHERE id = ANY($1)`, [
      [v[8].productId, v[9].productId],
    ]);
  });

  // 12: T-CART-014 (DELETE /cart → cleared, аудит cart.cleared)
  it('DELETE /cart: rowVersion обязателен; устаревший → 409; очистка → новая пустая active, аудит cart.cleared', async () => {
    const a = await t.actor({ role: 'seller' });
    const c = await setItem(t, a, v[10], '1');
    expect((await t.req('delete', '/cart', a)).status).toBe(400);
    const stale = await t.req('delete', `/cart?rowVersion=${c.rowVersion - 1}`, a);
    expect(stale.status).toBe(409);
    const ok = await t.req('delete', `/cart?rowVersion=${c.rowVersion}`, a);
    expect(ok.status).toBe(200);
    expect(ok.body).toMatchObject({ status: 'active', items: [] });
    expect(ok.body.id).not.toBe(c.id);
    const old = await t.q<{ status: string }>(`SELECT status::text FROM carts WHERE id = $1`, [c.id]);
    expect(old[0].status).toBe('cleared');
    const audit = await t.auditRows('cart.cleared', c.id);
    expect(audit).toHaveLength(1);
    expect(audit[0].after).toMatchObject({ itemsCount: 1, parked: false });
    // Повтор для пустой корзины — 200 без проверки rowVersion.
    const repeat = await t.req('delete', '/cart?rowVersion=999', a);
    expect(repeat.status).toBe(200);
    expect(repeat.body.id).toBe(ok.body.id);
  });

  // 12: T-ORD-027 (корзина макета: 16 850 / 842,50 / 16 007,50), T-DISC-003 (7 % под seller → 422), T-DISC-007 (Σ строк = скидка документа)
  it('RM-F-001 п. 1–3: 5 товаров 16 850 сом, скидка 5 % → 842,50 / 16 007,50; Σ строк = итог; 7 % под seller → DISCOUNT_LIMIT_EXCEEDED', async () => {
    const prices = ['2350.00', '3000.00', '4150.00', '2500.00', '2500.00'];
    const qty = ['2', '1', '1', '1', '1'];
    const vs = (await t.saleableVariants(12)).slice(7, 12);
    for (let i = 0; i < 5; i++) {
      await t.setPrice(vs[i].variantId, prices[i]);
      await t.setStock(vs[i].variantId, '100', vs[i].warehouseId);
      await setItem(t, seller, vs[i], qty[i]);
    }
    const c = await getCart(t, seller);
    expect(c.subtotal.amount).toBe('16850.00');
    const d = await t.req('post', '/cart/discount', seller).send({ percent: '5', rowVersion: c.rowVersion });
    expect(d.status).toBe(200);
    expect(d.body).toMatchObject({
      requestedDiscountPercent: '5.00',
      appliedDiscountPercent: '5.00',
      discountTotal: { amount: '842.50' },
      total: { amount: '16007.50' },
    });
    const sum = (d.body.items as { lineTotal: { amount: string } }[]).reduce(
      (s, i) => s.plus(Money.of(i.lineTotal.amount)),
      Money.ZERO,
    );
    expect(sum.toString()).toBe('16007.50');
    const discSum = (d.body.items as { lineDiscount: { amount: string } }[]).reduce(
      (s, i) => s.plus(Money.of(i.lineDiscount.amount)),
      Money.ZERO,
    );
    expect(discSum.toString()).toBe('842.50');
    const over = await t.req('post', '/cart/discount', seller).send({ percent: '7', rowVersion: d.body.rowVersion });
    expect(over.status).toBe(422);
    expect(over.body).toMatchObject({
      code: 'DISCOUNT_LIMIT_EXCEEDED',
      limitPercent: '5.00',
      requiresRole: 'senior_seller',
    });
    const applied = await t.auditRows('discount.applied', c.id);
    expect(applied.at(-1)?.after).toMatchObject({ percent: '5.00', total: '16007.50' });
  });

  // 12: T-CART-022 (201-я строка → 400 max_items, корзина не изменена)
  it('max_items: 201-я строка → 400 VALIDATION_FAILED (rule max_items), корзина не изменена', async () => {
    const a = await t.actor({ role: 'cashier' });
    const c = await getCart(t, a);
    await t.pool.query(
      `INSERT INTO cart_items (cart_id, variant_id, packaging_id, quantity, base_quantity, price_snapshot, line_no)
       SELECT $1, x.id, NULL, 1, 1, 1, row_number() OVER (ORDER BY x.id)
         FROM (SELECT v.id FROM product_variants v WHERE v.id <> $2 ORDER BY v.id LIMIT 200) x`,
      [c.id, v[11].variantId],
    );
    const pre = await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM cart_items WHERE cart_id = $1`, [c.id]);
    expect(pre[0].n).toBe(200);
    const res = await t
      .req('put', `/cart/items/${v[11].variantId}`, a)
      .send({ quantity: { value: '1', unitId: v[11].unitId }, rowVersion: c.rowVersion });
    expect(res.status).toBe(400);
    expect(res.body.errors[0]).toMatchObject({ rule: 'max_items' });
    const n = await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM cart_items WHERE cart_id = $1`, [c.id]);
    expect(n[0].n).toBe(200);
  });
});

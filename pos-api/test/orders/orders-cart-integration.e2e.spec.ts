import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CartModule } from '../../src/cart/cart.module.js';
import { PAYMENTS_PORT } from '../../src/common/ports/index.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { PaymentsModule } from '../../src/payments/payments.module.js';
import type { PosActor } from '../support/pos-fixture.js';
import { DbPaymentsPort, OrdersTestApp } from './support/orders-fixture.js';

/**
 * Сквозной сценарий с **реальной** корзиной (`CartModule`, порт `CartReader` агента F-be-cart) — тестовые данные:
 * `PUT /cart/items` → `POST /orders` (снимок цен из корзины сервера, `/check` 1С внутри `validateForCheckout`,
 * корзина → `converted`); 1С не ответила за `ONEC_SYNC_CHECK_TIMEOUT_MS` → `202` + `STALE_DATA` (RM-F-012 п. 2).
 */
describe('orders + реальная корзина (CartReader)', () => {
  const t = new OrdersTestApp();
  let seller: PosActor;

  beforeAll(async () => {
    await t.start({ modules: [CartModule, OrdersModule], fakePorts: true, env: { ONEC_SYNC_CHECK_TIMEOUT_MS: '700' } });
    t.replacePort(PAYMENTS_PORT, new DbPaymentsPort(t));
    seller = await t.actor({ role: 'seller' });
  });
  afterAll(async () => {
    await t.stop();
  });

  async function fillCart(actor: PosActor, quantity: string) {
    const [v] = await t.saleableVariants(1);
    const before = await t.req('get', '/cart', actor);
    expect(before.status, JSON.stringify(before.body)).toBe(200);
    const put = await t.req('put', `/cart/items/${v.variantId}`, actor).send({
      quantity: { value: quantity, unitId: v.unitId, packagingId: null },
      rowVersion: (before.body as { rowVersion: number }).rowVersion,
    });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    const cart = await t.req('get', '/cart', actor);
    expect(cart.status).toBe(200);
    return { v, cart: cart.body as { id: string; rowVersion: number } };
  }

  it('POST /orders по корзине сервера: 201, цены снимка = цены каталога, корзина converted', async () => {
    const { v, cart } = await fillCart(seller, '3');
    const res = await t.req('post', '/orders', seller, { idem: true }).send({
      cartId: cart.id,
      cartRowVersion: cart.rowVersion,
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
      paymentMethod: 'cash',
      items: [{ variantId: v.variantId, quantity: { value: '3', unitId: v.unitId, packagingId: null } }],
    });
    expect([201, 202], JSON.stringify(res.body)).toContain(res.status);
    const items = await t.q<{ unit_price: string }>(
      `SELECT unit_price::text AS unit_price FROM order_items WHERE order_id = $1`,
      [res.body.id],
    );
    expect(items[0].unit_price).toBe(v.price);
    const c = await t.q<{ status: string; converted_order_id: string }>(
      `SELECT status::text AS status, converted_order_id FROM carts WHERE id = $1`,
      [cart.id],
    );
    expect(c[0]).toEqual({ status: 'converted', converted_order_id: res.body.id });
  });

  // 12: T-FAIL-008, T-SYNC-041
  it('1С не ответила на /check за таймаут → 202 + Location + warnings[STALE_DATA]; заказ submitting', async () => {
    const { v, cart } = await fillCart(seller, '5');
    t.onec.always('checkCart', { hang: true });
    try {
      const res = await t.req('post', '/orders', seller, { idem: true }).send({
        cartId: cart.id,
        cartRowVersion: cart.rowVersion,
        receiver: { kind: 'customer' },
        delivery: { method: 'pickup' },
        paymentMethod: 'cash',
        items: [{ variantId: v.variantId, quantity: { value: '5', unitId: v.unitId, packagingId: null } }],
      });
      expect(res.status, JSON.stringify(res.body)).toBe(202);
      expect(res.headers.location).toBe(`/api/v1/orders/${res.body.id}`);
      expect((res.body.warnings as { code: string }[]).map((w) => w.code)).toContain('STALE_DATA');
      expect(res.body.status).toBe('submitting');
    } finally {
      t.onec.always('checkCart', null);
    }
  });
});

/**
 * Сквозной сценарий с **реальными** корзиной и платежами (`PaymentsModule`, порт `PaymentsPort` агента F-be-payments,
 * QR через 1С `QR_PROVIDER=onec`) — тестовые данные: начальный платёж `qr_bakai` создаётся в транзакции заказа,
 * QR формируется после COMMIT (`afterCommit`), повтор ключа возвращает текущее представление с QR (08 §4.8.1).
 */
describe('orders + реальные корзина и платежи (QR через 1С)', () => {
  const t = new OrdersTestApp();
  let cashier: PosActor;

  beforeAll(async () => {
    await t.start({
      modules: [CartModule, OrdersModule, PaymentsModule],
      fakePorts: true,
      env: { ONEC_SYNC_CHECK_TIMEOUT_MS: '700', QR_PROVIDER: 'onec' },
    });
    cashier = await t.actor({ role: 'cashier' });
  });
  afterAll(async () => {
    await t.stop();
  });

  // 12: T-PAY-011 (qr_bakai: платёж в составе POST /orders), T-PAY-037 (QR после COMMIT)
  it('qr_bakai: платёж в составе POST /orders, QR после COMMIT; повтор ключа — тот же заказ с QR', async () => {
    const [v] = await t.saleableVariants(1);
    const before = await t.req('get', '/cart', cashier);
    const put = await t.req('put', `/cart/items/${v.variantId}`, cashier).send({
      quantity: { value: '2', unitId: v.unitId, packagingId: null },
      rowVersion: (before.body as { rowVersion: number }).rowVersion,
    });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    const cart = (await t.req('get', '/cart', cashier)).body as { id: string; rowVersion: number };
    const body = {
      cartId: cart.id,
      cartRowVersion: cart.rowVersion,
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
      paymentMethod: 'qr_bakai',
      items: [{ variantId: v.variantId, quantity: { value: '2', unitId: v.unitId, packagingId: null } }],
    };
    const key = '9b0f6c1e-3a7d-4c2e-8f10-2d5e6a7b8c9d';
    const res = await t.req('post', '/orders', cashier, { idem: key }).send(body);
    expect([201, 202], JSON.stringify(res.body)).toContain(res.status);
    const pay = (res.body.payments as { id: string; method: string; status: string }[])[0];
    expect(pay.method).toBe('qr_bakai');
    expect(['qr_shown', 'qr_pending']).toContain(pay.status);
    const replay = await t.req('post', '/orders', cashier, { idem: key }).send(body);
    expect(replay.status).toBe(res.status);
    expect(replay.body.id).toBe(res.body.id);
    expect((replay.body.payments as { id: string }[])[0].id).toBe(pay.id);
    const rows = await t.q<{ n: string }>(`SELECT count(*)::text AS n FROM payments WHERE order_id = $1`, [
      res.body.id,
    ]);
    expect(rows[0].n).toBe('1');
  });
});

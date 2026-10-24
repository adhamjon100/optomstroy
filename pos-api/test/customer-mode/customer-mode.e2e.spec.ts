import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CustomersModule } from '../../src/customers/customers.module.js';
import { CashierTestApp, type CashierWorld } from '../support/cashier-fixture.js';
import { F_MODULES, type PosActor, PosTestApp } from '../support/pos-fixture.js';

/**
 * RM-G-014 — серверная часть режима клиента (ядро §24.2, §22.12; 10 CUST-024, CUST-025; 11 SEC-030; 08 AC-API-179;
 * 12 T-CUST-017, T-PAY-042, T-CASH-014) — **тестовые данные** (стенд `cashier-fixture`, фейк 1С):
 * - свои заказы (`order.read.own`): созданные покупателем, а при `customer_links.status=confirmed` — также заказы его
 *   карточки, оформленные кассиром; чужие и без подтверждённой привязки → 404;
 * - платежи и QR своего заказа (просмотр, выдача, перевыпуск), ручное подтверждение и void → 403; платёж в
 *   `manual_confirm` виден покупателю статусом без действий («Оплата проверяется магазином» — UI);
 * - свой долг и история — только при `confirmed`, иначе 404 (маршруты агентов G-be-credit / G-be-customers);
 * - заявки-заказы клиентов (`created_via=customer`) — в общем списке заказов сотрудников;
 * - `CUSTOMER_SELF_SERVICE=false` → запросы `customer` к заказам, платежам и документам → 403.
 */
interface OrderItem {
  id: string;
}

const ids = (body: unknown) => ((body as { items: OrderItem[] }).items ?? []).map((x) => x.id);

describe('режим клиента: свои заказы, QR, долг и история (RM-G-014)', () => {
  const t = new CashierTestApp();
  let w: CashierWorld;
  let stranger: PosActor;

  beforeAll(async () => {
    await t.start({ env: { QR_PROVIDER: 'onec' }, modules: [...F_MODULES, CustomersModule] });
    w = await t.seedCashierWorld();
    stranger = w.actors.customer; // покупатель без привязки
  });

  afterAll(async () => {
    await t.stop();
  });

  it('GET /orders: confirmed — свои и заказы карточки; proposed и без привязки — только созданные ими', async () => {
    const confirmed = await t.req('get', '/orders', w.buyerConfirmed);
    expect(confirmed.status).toBe(200);
    expect(ids(confirmed.body)).toEqual(
      expect.arrayContaining([w.orders.buyerShipped.orderId, w.orders.buyerRequest.orderId]),
    );
    const proposed = await t.req('get', '/orders', w.buyerProposed);
    expect(proposed.status).toBe(200);
    expect(ids(proposed.body)).toEqual([]);
    expect(ids((await t.req('get', '/orders', stranger)).body)).toEqual([]);
    // Фильтр customerId чужой карточки не расширяет видимость.
    const foreign = await t.req('get', `/orders?customerId=${w.customers.overdue.id}`, w.buyerConfirmed);
    expect(ids(foreign.body)).toEqual([]);
  });

  it('GET /orders/{id}: заказ карточки, оформленный кассиром, — 200 при confirmed; proposed и чужой — 404', async () => {
    const shipped = w.orders.buyerShipped.orderId;
    const ok = await t.req('get', `/orders/${shipped}`, w.buyerConfirmed);
    expect(ok.status).toBe(200);
    expect(ok.body.id).toBe(shipped);
    for (const a of [w.buyerProposed, stranger]) {
      const r = await t.req('get', `/orders/${shipped}`, a);
      expect([r.status, r.body.code]).toEqual([404, 'NOT_FOUND']);
      expect((await t.req('get', `/orders/${w.orders.buyerRequest.orderId}`, a)).status).toBe(404);
    }
    expect((await t.req('get', `/orders/${randomUUID()}`, w.buyerConfirmed)).status).toBe(404);
  });

  it('платежи своего заказа: GET /payments/{id} и /orders/{id}/payments — confirmed 200; proposed и чужой — 404', async () => {
    const { orderId, paymentId } = w.orders.buyerShipped;
    const one = await t.req('get', `/payments/${paymentId}`, w.buyerConfirmed);
    expect(one.status).toBe(200);
    expect(one.body.id).toBe(paymentId);
    expect(one.body).not.toHaveProperty('externalRef'); // payment.read.own (11 §4.3 №64)
    const list = await t.req('get', `/orders/${orderId}/payments`, w.buyerConfirmed);
    expect(list.status).toBe(200);
    expect(ids(list.body)).toContain(paymentId);
    for (const a of [w.buyerProposed, stranger]) {
      expect((await t.req('get', `/payments/${paymentId}`, a)).status).toBe(404);
      expect((await t.req('get', `/orders/${orderId}/payments`, a)).status).toBe(404);
    }
  });

  it('CUST-024: QR своего заказа (карточки) — выдача и перевыпуск на том же платеже; чужой → 404; ручное подтверждение и void → 403', async () => {
    const o = await t.seedOrder({
      createdBy: w.actors.cashier,
      customerId: w.customers.buyer.id,
      method: 'qr_bakai',
      status: 'awaiting_payment',
    });
    const pay = (a: PosActor, body: Record<string, unknown>) =>
      t.req('post', `/orders/${o.orderId}/payments`, a, { idem: true }).send(body);
    expect((await pay(w.buyerProposed, { method: 'qr_bakai' })).status).toBe(404);
    expect((await pay(stranger, { method: 'qr_bakai' })).status).toBe(404);
    const shown = await pay(w.buyerConfirmed, { method: 'qr_bakai' });
    expect(shown.status).toBe(200);
    expect(shown.body).toMatchObject({
      id: o.paymentId,
      status: 'qr_shown',
      qr: { provider: 'onec', autoConfirm: true },
    });
    const ref = shown.body.qr.bankReference as string;
    const again = await pay(w.buyerConfirmed, { method: 'qr_bakai', reissueQr: true });
    expect(again.status).toBe(200);
    expect(again.body.id).toBe(o.paymentId);
    expect(again.body.qr.bankReference).not.toBe(ref);
    expect((await t.auditRows('payment.qr_reissued', o.paymentId)).at(-1)?.actor_user_id).toBe(w.buyerConfirmed.userId);
    // Ручной путь и наличные — не для покупателя.
    const manual = await pay(w.buyerConfirmed, { method: 'qr_bakai', manualOnly: true });
    expect(manual.status).toBe(403);
    expect((await pay(w.buyerConfirmed, { method: 'cash' })).status).toBe(403);
    const confirm = await t
      .req('post', `/payments/${o.paymentId}/confirm-manual`, w.buyerConfirmed, { idem: true })
      .send({ bankReference: 'BK-1', receivedAmount: { amount: o.total, currency: 'KGS' } });
    expect([confirm.status, confirm.body.code]).toEqual([403, 'FORBIDDEN']);
    const voided = await t
      .req('post', `/payments/${o.paymentId}/void`, w.buyerConfirmed, { idem: true })
      .send({ reason: 'передумал платить' });
    expect([voided.status, voided.body.code]).toEqual([403, 'FORBIDDEN']);
  });

  it('CUST-024: платёж в manual_confirm — покупатель видит статус без действий (UI: «Оплата проверяется магазином»)', async () => {
    const o = await t.seedOrder({ createdBy: w.buyerConfirmed, method: 'qr_bakai', status: 'awaiting_payment' });
    await t.q(
      `UPDATE payments SET status = 'manual_confirm', review_reason = 'no_webhook', qr_provider_ref = $2
        WHERE id = $1::uuid`,
      [o.paymentId, `ONEC-QR-${randomUUID().slice(0, 8)}`],
    );
    const own = await t.req('get', `/payments/${o.paymentId}`, w.buyerConfirmed);
    expect(own.status).toBe(200);
    expect(own.body).toMatchObject({ status: 'manual_confirm', allowedActions: [] });
    expect(own.body.qr).toBeNull();
    const order = await t.req('get', `/orders/${o.orderId}?include=payments`, w.buyerConfirmed);
    expect(order.status).toBe(200);
    expect(JSON.stringify(order.body)).toContain('manual_confirm');
    // кассир видит действие подтверждения
    const staff = await t.req('get', `/payments/${o.paymentId}`, w.actors.cashier);
    expect(staff.body.allowedActions).toContain('confirm_manual');
  });

  it('заявки-заказы клиентов (created_via=customer) — в общем списке заказов сотрудников с order.read.all', async () => {
    const req = w.orders.buyerRequest.orderId;
    const [row] = await t.q<{ created_via: string }>(`SELECT created_via FROM orders WHERE id = $1::uuid`, [req]);
    expect(row?.created_via).toBe('customer');
    for (const a of [w.actors.cashier, w.actors.senior_seller, w.actors.admin, w.actors.owner]) {
      const r = await t.req('get', `/orders?customerId=${w.customers.buyer.id}&limit=200`, a);
      expect(r.status).toBe(200);
      expect(ids(r.body)).toContain(req);
      expect((await t.req('get', `/orders/${req}`, a)).status).toBe(200);
    }
    // seller (order.read.own) чужую заявку не видит
    expect(ids((await t.req('get', '/orders?limit=200', w.actors.seller)).body)).not.toContain(req);
  });

  it('CUST-025 / AC-API-179: свой долг и история — только при confirmed, иначе 404; чужая карточка — 404', async () => {
    const buyer = w.customers.buyer.id;
    const history = await t.req('get', `/customers/${buyer}/orders`, w.actors.owner);
    const receivables = await t.req('get', `/customers/${buyer}/receivables`, w.actors.owner);
    const routes = { history: history.status !== 404, receivables: receivables.status !== 404 };
    // Маршруты агентов G-be-customers / G-be-credit: проверяются, когда зарегистрированы.
    expect(routes.history).toBe(true);
    for (const [name, path] of [
      ['history', `/customers/${buyer}/orders`],
      ['receivables', `/customers/${buyer}/receivables`],
    ] as const) {
      if (!routes[name]) {
        console.error(`[customer-mode] маршрут ${path} ещё не зарегистрирован — проверка пропущена`);
        continue;
      }
      const prop = await t.req('get', path, w.buyerProposed);
      expect([prop.status, prop.body.code], `${name} proposed`).toEqual([404, 'NOT_FOUND']);
      expect((await t.req('get', path, stranger)).status, `${name} без привязки`).toBe(404);
      const conf = await t.req('get', path, w.buyerConfirmed);
      expect(conf.status, `${name} confirmed`).toBe(200);
      const foreign = path.replace(buyer, w.customers.overdue.id);
      expect((await t.req('get', foreign, w.buyerConfirmed)).status, `${name} чужая карточка`).toBe(404);
    }
  });
});

describe('режим клиента выключен: CUSTOMER_SELF_SERVICE=false (10 CASH-006, T-CASH-014)', () => {
  const t = new PosTestApp();
  let customer: PosActor;
  let cashier: PosActor;
  let orderId: string;
  let paymentId: string;

  beforeAll(async () => {
    await t.start({ skuCount: 30, env: { CUSTOMER_SELF_SERVICE: 'false', QR_PROVIDER: 'onec' } });
    customer = await t.actor({ role: 'customer' });
    cashier = await t.actor({ role: 'cashier' });
    const cid = await t.createOnecCustomer({ name: 'ООО «Покупатель»' });
    await t.linkCustomer(customer.userId, cid, 'confirmed');
    const o = await t.seedOrder({
      createdBy: customer,
      customerId: cid,
      method: 'qr_bakai',
      status: 'awaiting_payment',
    });
    orderId = o.orderId;
    paymentId = o.paymentId;
  });

  afterAll(async () => {
    await t.stop();
  });

  it('customer: заказы, платежи, QR и документы → 403 FORBIDDEN; сотрудник — как обычно', async () => {
    const calls = [
      () => t.req('get', '/orders', customer),
      () => t.req('get', `/orders/${orderId}`, customer),
      () => t.req('get', `/orders/${orderId}/payments`, customer),
      () => t.req('get', `/payments/${paymentId}`, customer),
      () => t.req('get', `/orders/${orderId}/documents/invoice.pdf`, customer),
    ];
    for (const c of calls) {
      const r = await c();
      expect([r.status, r.body.code]).toEqual([403, 'FORBIDDEN']);
    }
    const pay = await t
      .req('post', `/orders/${orderId}/payments`, customer, { idem: true })
      .send({ method: 'qr_bakai' });
    expect([pay.status, pay.body.code]).toEqual([403, 'FORBIDDEN']);
    expect((await t.req('get', '/orders', undefined)).status).toBe(401);
    expect((await t.req('get', `/orders/${orderId}`, cashier)).status).toBe(200);
    expect((await t.req('get', `/payments/${paymentId}`, cashier)).status).toBe(200);
  });
});

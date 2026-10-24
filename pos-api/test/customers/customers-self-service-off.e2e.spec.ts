import { CustomersTestApp } from './support/customers-app.js';

/**
 * RM-G-001 / RM-G-014 (агент G-be-customers), **тестовые данные**: при `CUSTOMER_SELF_SERVICE=false` (10 CASH-006)
 * клиент-покупатель не читает даже свою подтверждённую карточку и историю — `403 FORBIDDEN`; сотрудники — как обычно.
 */
let t: CustomersTestApp;

beforeAll(async () => {
  t = await new CustomersTestApp().start({ env: { QR_PROVIDER: 'none', CUSTOMER_SELF_SERVICE: 'false' } });
}, 600_000);

afterAll(async () => {
  await t?.stop();
});

it('CUSTOMER_SELF_SERVICE=false: GET /customers/{id} и /orders клиента → 403; кассир → 200', async () => {
  const card = await t.createOnecCustomer({ name: 'ОсОО «Без Режима Клиента»', phoneE164: '+996555660001' });
  const buyer = await t.actor({ role: 'customer' });
  await t.linkCustomer(buyer.userId, card, 'confirmed');
  expect((await t.req('get', `/customers/${card}`, buyer)).status).toBe(403);
  expect((await t.req('get', `/customers/${card}/orders`, buyer)).status).toBe(403);
  const cashier = await t.actor({ role: 'cashier' });
  expect((await t.req('get', `/customers/${card}`, cashier)).status).toBe(200);
});

// 10 CASH-006, 11 §4.2, T-CASH-014 (ревью G-security-2): долг, условия и правила скидок клиента — тоже 403.
it('CUSTOMER_SELF_SERVICE=false: свой долг, скидки/условия и правила скидок клиента → 403; кассир → 200', async () => {
  const card = await t.createOnecCustomer({
    name: 'ОсОО «Без Режима Клиента 2»',
    phoneE164: '+996555660002',
    creditAllowed: true,
    creditLimit: '30000.00',
    creditDays: 14,
  });
  await t.setReceivables(card, { balance: '4500.00', overdue: '0.00', ageMinutes: 5 });
  const buyer = await t.actor({ role: 'customer' });
  await t.linkCustomer(buyer.userId, card, 'confirmed');
  for (const path of [`/customers/${card}/receivables`, `/customers/${card}/discounts`, '/discounts/rules']) {
    const r = await t.req('get', path, buyer);
    expect([r.status, r.body.code], path).toEqual([403, 'FORBIDDEN']);
    expect(JSON.stringify(r.body), path).not.toContain('4500');
  }
  const cashier = await t.actor({ role: 'cashier' });
  expect((await t.req('get', `/customers/${card}/receivables`, cashier)).status).toBe(200);
  expect((await t.req('get', `/customers/${card}/discounts`, cashier)).status).toBe(200);
});

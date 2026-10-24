import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { ORDER_STATUS_PORT } from '../../src/common/ports/index.js';
import { F_MODULES, type PosActor } from '../support/pos-fixture.js';
import { PaymentsTestApp } from './support/payments-app.js';

/**
 * Сквозная связка с реальными модулями этапа F (orders — `OrderStatusPort`, notifications — по умолчанию стенда
 * заменён `InMemoryNotifications`): приём наличных и ручное подтверждение QR пересчитывают `paid_amount`/`paid_at`
 * и проекцию статуса заказа модулем orders (07 §6.4 правило 3, 10 §2.2 P8 → P9/P10) — **тестовые данные**.
 * Если модуль orders порт не привязал (параллельная разработка), набор пропускается.
 */
describe('payments + orders (реальный OrderStatusPort)', () => {
  const t = new PaymentsTestApp();
  let cashier: PosActor;
  let seller: PosActor;
  let bound = false;

  beforeAll(async () => {
    await t.startPayments({ env: { QR_PROVIDER: 'none' }, modules: F_MODULES, realOrders: true });
    bound = t.registry.get(ORDER_STATUS_PORT) !== t.orderPort;
    cashier = await t.actor({ role: 'cashier' });
    seller = await t.actor({ role: 'seller' });
  });
  afterAll(async () => {
    await t.stop();
  });

  // 12: T-PAY-005 (заказ оплачен — флаг is_paid, статус по 10 §2.2), T-ORD-016 (оплата — флаг, не статус заказа)
  it('наличные по заказу awaiting_payment → received; заказ оплачен, история статусов от orders', async (ctx) => {
    if (!bound) ctx.skip();
    const o = await t.seedOrder({ createdBy: seller, method: 'cash', status: 'awaiting_payment' });
    const res = await t.pay(cashier, o.orderId, { method: 'cash' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'received', order: { isPaid: true } });
    const money = await t.orderMoney(o.orderId);
    expect(money).toMatchObject({ is_paid: true, paid_amount: o.total });
    expect(money.paid_at).not.toBeNull();
  });

  it('QR (none) → confirm-manual со step-up → received; заказ оплачен', async (ctx) => {
    if (!bound) ctx.skip();
    const o = await t.seedOrder({ createdBy: seller, method: 'qr_bakai', status: 'submitting' });
    expect((await t.pay(seller, o.orderId, { method: 'qr_bakai' })).body.status).toBe('qr_shown');
    const stepUp = await t.stepUp(cashier, 'payment.qr.confirm_manual');
    const res = await t
      .req('post', `/payments/${o.paymentId}/confirm-manual`, cashier, { idem: true, stepUp })
      .send({ bankReference: 'BK-INT-1', receivedAmount: { amount: o.total, currency: 'KGS' } });
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('received');
    expect(await t.orderMoney(o.orderId)).toMatchObject({ is_paid: true });
  });
});

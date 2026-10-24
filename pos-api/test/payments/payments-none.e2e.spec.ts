import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { FixedClock } from '../../src/common/auth/clock.js';
import { PAYMENTS_PORT } from '../../src/common/ports/index.js';
import { type PosActor, RETAIL_CUSTOMER_ID } from '../support/pos-fixture.js';
import { PaymentsTestApp } from './support/payments-app.js';

type Actors = Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;

/**
 * Платежи при `QR_PROVIDER=none` (запасной вариант R1, ядро §24.4) — **тестовые данные**: приём наличных,
 * статический QR и ручное подтверждение со step-up, void, смена способа с системным аннулированием, права,
 * идемпотентность, long-polling (RM-F-003 критерии 1–6, RM-F-012 п. 5, RM-F-015 п. 1).
 */
describe('payments: QR_PROVIDER=none (RM-F-003)', () => {
  const t = new PaymentsTestApp();
  const clock = new FixedClock(new Date());
  let a: Actors;

  beforeAll(async () => {
    await t.startPayments({ env: { QR_PROVIDER: 'none' }, clock, jobs: false });
    a = await t.actors();
  });
  afterAll(async () => {
    await t.stop();
  });

  // ------------------------------------------------------------------------------------------------ наличные

  // 12: T-PAY-001 (приём наличных кассиром: cash_pending → received, тот же id, сдача), T-PAY-035 (четыре статуса, cash), T-PAY-005 (paid_amount = Σ received, is_paid), T-PAY-031 (журнал и аудит), T-TXN-001 (payment_received)
  it('наличные в четырёх статусах ядра §22.5: cash_pending → received (200, тот же id), сдача, журнал, аудит', async () => {
    for (const status of ['submitting', 'pending_approval', 'awaiting_payment'] as const) {
      const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status });
      const due = Number(o.total); // money-double: allow — только для построения строки «получено» в тесте
      const received = (due + 100).toFixed(2); // money-double: allow — тестовая строка суммы
      const res = await t.pay(a.cashier, o.orderId, {
        method: 'cash',
        receivedAmount: { amount: received, currency: 'KGS' },
      });
      expect(res.status, status).toBe(200);
      expect(res.body).toMatchObject({
        id: o.paymentId,
        status: 'received',
        confirmationKind: 'cash',
        amount: { amount: o.total, currency: 'KGS' },
        receivedAmount: { amount: received },
        changeAmount: { amount: '100.00' },
        order: { paidAmount: { amount: o.total }, isPaid: true },
      });
      expect(res.body.confirmedBy).toMatchObject({ id: a.cashier.userId });
      const money = await t.orderMoney(o.orderId);
      expect(money).toMatchObject({ paid_amount: o.total, is_paid: true });
      expect(money.paid_at).not.toBeNull();
      const tx = await t.transactionsOf(o.paymentId);
      expect(tx).toEqual([expect.objectContaining({ kind: 'payment_received', amount: o.total })]);
      const audit = await t.auditRows('payment.received', o.paymentId);
      expect(audit).toHaveLength(1);
      expect(audit[0].actor_user_id).toBe(a.cashier.userId);
    }
    // approved — четвёртый статус (через смену статуса заказа).
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    await t.setOrderStatus(o.orderId, 'approved');
    const res = await t.pay(a.senior_seller, o.orderId, { method: 'cash' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'received', receivedAmount: null, changeAmount: null });
  });

  // 12: T-PAY-004 (вторая оплата новым ключом → 409)
  it('заказ вне статусов ядра §22.5 → 409 ORDER_STATE_INVALID; оплаченный → already_paid; повтор → PAYMENT/ORDER_STATE_INVALID', async () => {
    const failed = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'submit_failed' });
    let res = await t.pay(a.cashier, failed.orderId, { method: 'cash' });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'ORDER_STATE_INVALID', reason: 'order_not_payable' });
    for (const st of ['shipped', 'closed', 'cancelled'] as const) {
      const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_shipment' });
      await t.setOrderStatus(o.orderId, st);
      res = await t.pay(a.cashier, o.orderId, { method: 'cash' });
      expect(res.status, st).toBe(409);
      expect(res.body.code).toBe('ORDER_STATE_INVALID');
    }
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    expect((await t.pay(a.cashier, o.orderId, { method: 'cash' })).status).toBe(200);
    res = await t.pay(a.cashier, o.orderId, { method: 'cash' });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'ORDER_STATE_INVALID', reason: 'already_paid' });
  });

  // 12: T-PAY-003 (лишние поля amount → 400), T-PAY-006 (частичная оплата → 422 received_less_than_due)
  it('сумма только с сервера: лишние поля → 400; получено меньше суммы → 422 received_less_than_due', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    let res = await t.pay(a.cashier, o.orderId, { method: 'cash', amount: { amount: '1.00', currency: 'KGS' } });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
    res = await t.pay(a.cashier, o.orderId, { method: 'cash', receivedAmount: { amount: '0.01', currency: 'KGS' } });
    expect(res.status).toBe(422);
    expect(res.body.errors[0]).toMatchObject({ field: 'receivedAmount', rule: 'received_less_than_due' });
    expect((await t.payment(o.paymentId)).status).toBe('cash_pending');
    res = await t.req('post', `/orders/${o.orderId}/payments`, a.cashier).send({ method: 'cash' });
    expect(res.status).toBe(400);
    expect(res.body.errors[0]).toMatchObject({ rule: 'idempotency_key_required' });
  });

  // 12: T-PAY-002 (продавец не подтверждает наличные сам → 403)
  it('права: seller — наличные 403; admin/owner — 403; чужой заказ для seller/customer — 404', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    for (const role of ['seller', 'admin', 'owner', 'customer'] as const) {
      const res = await t.pay(a[role], o.orderId, { method: 'cash' });
      expect(res.status, role).toBe(403);
      expect(res.body.code).toBe('FORBIDDEN');
    }
    const other = await t.actor({ role: 'seller' });
    const res = await t.pay(other, o.orderId, { method: 'qr_bakai' });
    expect(res.status).toBe(404);
  });

  // 12: T-PAY-008 (POST /orders/{id}/payments: Idempotent-Replayed, одна запись)
  it('idempotency: повтор с тем же ключом → Idempotent-Replayed, одна запись платежа', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    const key = randomUUID();
    const first = await t.pay(a.cashier, o.orderId, { method: 'cash' }, key);
    expect(first.status).toBe(201);
    const again = await t.pay(a.cashier, o.orderId, { method: 'cash' }, key);
    expect(again.status).toBe(201);
    expect(again.headers['idempotent-replayed']).toBe('true');
    expect(again.body.id).toBe(first.body.id);
    const rows = await t.q<{ n: string }>(`SELECT count(*)::text AS n FROM payments WHERE order_id = $1`, [o.orderId]);
    expect(rows[0].n).toBe('2');
  });

  // --------------------------------------------------------------------------------------- QR без провайдера

  // 12: T-PAY-013 (статический QR торговой точки, autoConfirm=false), T-PAY-018 (autoConfirm — backend)
  it('QR (none): qr_pending → qr_shown, autoConfirm=false, статический QR из настроек; к 1С не обращаемся', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'submitting' });
    let res = await t.pay(a.seller, o.orderId, { method: 'qr_bakai' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      id: o.paymentId,
      status: 'qr_shown',
      qr: { provider: 'none', payload: null, autoConfirm: false, expiresAt: null },
      warnings: [],
    });
    await t.setSetting('qr.static_payload', JSON.stringify('ELQR-STATIC-TEST-0001'));
    res = await t.req('get', `/payments/${o.paymentId}`, a.cashier);
    expect(res.status).toBe(200);
    expect(res.body.qr).toMatchObject({
      provider: 'elqr_static',
      payload: 'ELQR-STATIC-TEST-0001',
      autoConfirm: false,
    });
    expect(res.body.allowedActions).toEqual(expect.arrayContaining(['confirm_manual', 'void']));
    expect(t.onec.callsOf('createQrPayment')).toHaveLength(0);
    expect(t.onec.callsOf('getQrPaymentStatus')).toHaveLength(0);
    await t.setSetting('qr.static_payload', JSON.stringify(''));
  });

  // 12: T-PAY-017 (ручное подтверждение QR: без step-up → 403, seller → 403, со step-up → received, manual_qr_confirm, аудит), T-PAY-008 (/confirm-manual тем же ключом), T-TXN-005 (повтор — одна транзакция и один аудит), T-TXN-011 (актор, step_up_method)
  it('confirm-manual: без step-up → 403 STEP_UP_REQUIRED; со step-up → received, no_webhook, аудит и транзакция', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    expect((await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' })).status).toBe(200);
    const body = {
      bankReference: 'BK-77123',
      receivedAmount: { amount: o.total, currency: 'KGS' },
      comment: 'выписка 09:20',
    };
    let res = await t.req('post', `/payments/${o.paymentId}/confirm-manual`, a.cashier, { idem: true }).send(body);
    expect(res.status).toBe(403);
    expect(res.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: 'payment.qr.confirm_manual' } });
    // seller без права — 403 FORBIDDEN раньше step-up
    res = await t.req('post', `/payments/${o.paymentId}/confirm-manual`, a.seller, { idem: true }).send(body);
    expect(res.body.code).toBe('FORBIDDEN');
    const stepUp = await t.stepUp(a.cashier, 'payment.qr.confirm_manual');
    // лишнее поле прежней редакции → 400 (после step-up)
    res = await t
      .req('post', `/payments/${o.paymentId}/confirm-manual`, a.cashier, { idem: true, stepUp })
      .send({ ...body, acceptMismatch: true });
    expect(res.status).toBe(400);
    const confirmKey = randomUUID();
    res = await t
      .req('post', `/payments/${o.paymentId}/confirm-manual`, a.cashier, { idem: confirmKey, stepUp })
      .send(body);
    expect(res.status).toBe(200);
    // T-PAY-008, T-TXN-005: повтор confirm-manual тем же ключом — тот же ответ (Idempotent-Replayed), одна запись
    // аудита и одна транзакция manual_qr_confirm (проверки ниже — после повтора).
    const replay = await t
      .req('post', `/payments/${o.paymentId}/confirm-manual`, a.cashier, { idem: confirmKey, stepUp })
      .send(body);
    expect(replay.status).toBe(200);
    expect(replay.headers['idempotent-replayed']).toBe('true');
    expect(replay.body.id).toBe(res.body.id);
    expect(res.body).toMatchObject({
      status: 'received',
      confirmationKind: 'manual',
      reviewReason: 'no_webhook',
      bankAmount: { amount: o.total },
      confirmedBy: { id: a.cashier.userId },
    });
    const p = await t.payment(o.paymentId);
    expect(p).toMatchObject({ status: 'received', review_reason: 'no_webhook', bank_reference: 'BK-77123' });
    expect(p.manual_confirmed_by_user_id).toBe(a.cashier.userId);
    const audit = await t.auditRows('payment.manual_qr_confirmed', o.paymentId);
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({ actor_user_id: a.cashier.userId, step_up_method: 'pin', result: 'ok' });
    expect(await t.transactionsOf(o.paymentId)).toEqual([
      expect.objectContaining({ kind: 'manual_qr_confirm', amount: o.total, actor_user_id: a.cashier.userId }),
    ]);
    expect(await t.orderMoney(o.orderId)).toMatchObject({ is_paid: true, paid_amount: o.total });
  });

  it('confirm-manual: сумма ≠ amount → 200 manual_confirm amount_mismatch + warning; затем полная сумма → received', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    const stepUp = await t.stepUp(a.senior_seller, 'payment.qr.confirm_manual');
    let res = await t
      .req('post', `/payments/${o.paymentId}/confirm-manual`, a.senior_seller, { idem: true, stepUp })
      .send({ bankReference: 'BK-1', receivedAmount: { amount: '1.00', currency: 'KGS' } });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      status: 'manual_confirm',
      reviewReason: 'amount_mismatch',
      bankAmount: { amount: '1.00' },
      warnings: [expect.objectContaining({ code: 'PAYMENT_AMOUNT_MISMATCH' })],
    });
    expect(await t.orderMoney(o.orderId)).toMatchObject({ is_paid: false });
    res = await t
      .req('post', `/payments/${o.paymentId}/confirm-manual`, a.senior_seller, { idem: true, stepUp })
      .send({ bankReference: 'BK-2', receivedAmount: { amount: o.total, currency: 'KGS' } });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'received', reviewReason: 'amount_mismatch' });
    expect(await t.orderMoney(o.orderId)).toMatchObject({ is_paid: true });
  });

  it('confirm-manual: из qr_expired → 409 qr_expired_reissue_required; из cash_pending/received → PAYMENT_STATE_INVALID', async () => {
    const stepUp = await t.stepUp(a.cashier, 'payment.qr.confirm_manual');
    const q = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    await t.forcePayment(q.paymentId, { status: 'qr_expired' });
    const body = { bankReference: 'BK-3', receivedAmount: { amount: q.total, currency: 'KGS' } };
    let res = await t
      .req('post', `/payments/${q.paymentId}/confirm-manual`, a.cashier, { idem: true, stepUp })
      .send(body);
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'PAYMENT_STATE_INVALID', reason: 'qr_expired_reissue_required' });
    const c = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    res = await t.req('post', `/payments/${c.paymentId}/confirm-manual`, a.cashier, { idem: true, stepUp }).send(body);
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('PAYMENT_STATE_INVALID');
  });

  // ---------------------------------------------------------------------------------------------------- void

  // 12: T-PAY-027 (void до получения денег: step-up, seller/admin → 403, payment_voided, аудит с reason), T-PAY-008 (/void тем же ключом)
  it('void: без step-up → 403; seller/admin → 403 FORBIDDEN; со step-up → voided; повтор ключа → тот же ответ', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    const body = { reason: 'ошибка кассира', reasonCode: 'cashier_error' };
    let res = await t.req('post', `/payments/${o.paymentId}/void`, a.cashier, { idem: true }).send(body);
    expect(res.status).toBe(403);
    expect(res.body.code).toBe('STEP_UP_REQUIRED');
    for (const role of ['seller', 'admin', 'owner', 'customer'] as const) {
      res = await t.req('post', `/payments/${o.paymentId}/void`, a[role], { idem: true }).send(body);
      expect(res.status, role).toBe(403);
      expect(res.body.code, role).toBe('FORBIDDEN');
    }
    const stepUp = await t.stepUp(a.cashier, 'payment.void');
    const key = randomUUID();
    res = await t.req('post', `/payments/${o.paymentId}/void`, a.cashier, { idem: key, stepUp }).send(body);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'voided', voidReason: 'cashier_error' });
    const again = await t.req('post', `/payments/${o.paymentId}/void`, a.cashier, { idem: key, stepUp }).send(body);
    expect(again.status).toBe(200);
    expect(again.headers['idempotent-replayed']).toBe('true');
    const audit = await t.auditRows('payment.voided', o.paymentId);
    expect(audit[0]).toMatchObject({ actor_user_id: a.cashier.userId, step_up_method: 'pin' });
    expect(await t.transactionsOf(o.paymentId)).toEqual([
      expect.objectContaining({ kind: 'payment_voided', amount: `-${o.total}` }),
    ]);
    // после ручного void — новый приём наличных
    expect((await t.pay(a.cashier, o.orderId, { method: 'cash' })).status).toBe(201);
  });

  // 12: T-PAY-028 (void полученного → 409 PAYMENT_STATE_INVALID), T-SEC-041 (void уже voided/received → 409)
  it('void полученного (любой способ, в т. ч. наличные) и credit → 409 PAYMENT_STATE_INVALID', async () => {
    const stepUp = await t.stepUp(a.cashier, 'payment.void');
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    await t.pay(a.cashier, o.orderId, { method: 'cash' });
    let res = await t
      .req('post', `/payments/${o.paymentId}/void`, a.cashier, { idem: true, stepUp })
      .send({ reason: 'ошибка', reasonCode: 'other' });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'PAYMENT_STATE_INVALID', reason: 'received_void_forbidden' });
    const cust = await t.createOnecCustomer({ creditAllowed: true, creditLimit: '1000000.00' });
    const cr = await t.seedOrder({
      createdBy: a.cashier,
      method: 'credit',
      status: 'awaiting_payment',
      customerId: cust,
    });
    res = await t
      .req('post', `/payments/${cr.paymentId}/void`, a.cashier, { idem: true, stepUp })
      .send({ reason: 'ошибка', reasonCode: 'other' });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'PAYMENT_STATE_INVALID', reason: 'credit_terminal' });
  });

  // ------------------------------------------------------------------------------------------ смена способа

  // 12: T-PAY-036 (1)–(2) (системный void method_changed без step-up)
  it('смена способа: cash_pending → QR (201) и qr_shown → наличные (201) — системный void method_changed без step-up', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    let res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({ method: 'qr_bakai', status: 'qr_shown' });
    expect(res.body.id).not.toBe(o.paymentId);
    const old = await t.payment(o.paymentId);
    expect(old).toMatchObject({ status: 'voided', void_reason: 'method_changed', voided_by_user_id: null });
    const audit = await t.auditRows('payment.voided', o.paymentId);
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({ actor_user_id: null, step_up_method: null });
    const qrId = res.body.id as string;
    res = await t.pay(a.cashier, o.orderId, { method: 'cash', receivedAmount: { amount: o.total, currency: 'KGS' } });
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({ method: 'cash', status: 'received', changeAmount: { amount: '0.00' } });
    expect(await t.payment(qrId)).toMatchObject({ status: 'voided', void_reason: 'method_changed' });
  });

  // 12: T-PAY-036 (3) (сначала решение кассира)
  it('смена способа при qr_expired / manual_confirm → 409 open_payment_exists; ручной void со step-up, затем 201', async () => {
    for (const st of ['qr_expired', 'manual_confirm'] as const) {
      const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
      await t.forcePayment(
        o.paymentId,
        st === 'manual_confirm' ? { status: st, review_reason: 'amount_mismatch' } : { status: st },
      );
      let res = await t.pay(a.cashier, o.orderId, { method: 'cash' });
      expect(res.status, st).toBe(409);
      expect(res.body).toMatchObject({
        code: 'PAYMENT_STATE_INVALID',
        reason: 'open_payment_exists',
        openPaymentId: o.paymentId,
      });
      const stepUp = await t.stepUp(a.cashier, 'payment.void');
      res = await t
        .req('post', `/payments/${o.paymentId}/void`, a.cashier, { idem: true, stepUp })
        .send({ reason: 'клиент оплатит наличными', reasonCode: 'customer_refused' });
      expect(res.status).toBe(200);
      expect((await t.pay(a.cashier, o.orderId, { method: 'cash' })).status).toBe(201);
    }
  });

  it('credit в POST /orders/{id}/payments и заказ в долг → 409 ORDER_STATE_INVALID payment_method_mismatch', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    let res = await t.pay(a.cashier, o.orderId, { method: 'credit' });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'ORDER_STATE_INVALID', reason: 'payment_method_mismatch' });
    const cust = await t.createOnecCustomer({ creditAllowed: true, creditLimit: '1000000.00' });
    const cr = await t.seedOrder({
      createdBy: a.cashier,
      method: 'credit',
      status: 'awaiting_payment',
      customerId: cust,
    });
    res = await t.pay(a.cashier, cr.orderId, { method: 'cash' });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'ORDER_STATE_INVALID', reason: 'payment_method_mismatch' });
  });

  it('маршрута вебхука банка нет: POST /payments/qr/webhook → 404', async () => {
    const res = await t.req('post', '/payments/qr/webhook').send({ eventId: 'e1' });
    expect(res.status).toBe(404);
  });

  // ------------------------------------------------------------------------------------------- чтение, права

  it('GET /payments/{id}: admin → 403; seller — свой без externalRef, чужой → 404; owner — без qr; 400 wait вне 1…25', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    expect((await t.req('get', `/payments/${o.paymentId}`, a.admin)).status).toBe(403);
    const own = await t.req('get', `/payments/${o.paymentId}`, a.seller);
    expect(own.status).toBe(200);
    expect(own.body).not.toHaveProperty('externalRef');
    expect(own.body.qr).not.toBeNull();
    const other = await t.actor({ role: 'seller' });
    expect((await t.req('get', `/payments/${o.paymentId}`, other)).status).toBe(404);
    const owner = await t.req('get', `/payments/${o.paymentId}`, a.owner);
    expect(owner.status).toBe(200);
    expect(owner.body.qr).toBeNull();
    expect(owner.body).toHaveProperty('externalRef');
    for (const w of ['0', '26', 'x']) {
      const r = await t.req('get', `/payments/${o.paymentId}?wait=${w}`, a.cashier);
      expect(r.status, w).toBe(400);
    }
    expect((await t.req('get', `/payments/${randomUUID()}`, a.cashier)).status).toBe(404);
  });

  it('GET /orders/{id}/payments: все платежи заказа; чужой заказ seller → 404; admin (order.read.all) — без qr', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    const res = await t.req('get', `/orders/${o.orderId}/payments`, a.seller);
    expect(res.status).toBe(200);
    const items = res.body.items as { status: string }[];
    expect(items.map((p) => p.status)).toEqual(['voided', 'qr_shown']);
    const other = await t.actor({ role: 'seller' });
    expect((await t.req('get', `/orders/${o.orderId}/payments`, other)).status).toBe(404);
    const adm = await t.req('get', `/orders/${o.orderId}/payments`, a.admin);
    expect(adm.status).toBe(200);
    expect(adm.body.items[1].qr).toBeNull();
  });

  // -------------------------------------------------------------------------------------------- long-polling

  it('long-polling: ответ сразу после подтверждения с другого устройства; второй ожидающий → 429', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    const started = Date.now();
    const waiting = t.req('get', `/payments/${o.paymentId}?wait=25`, a.seller).then((r) => r);
    await new Promise((r) => setTimeout(r, 400));
    const second = await t.req('get', `/payments/${o.paymentId}?wait=25`, a.seller);
    expect(second.status).toBe(429);
    expect(second.body.code).toBe('RATE_LIMITED');
    const stepUp = await t.stepUp(a.cashier, 'payment.qr.confirm_manual');
    const conf = await t
      .req('post', `/payments/${o.paymentId}/confirm-manual`, a.cashier, { idem: true, stepUp })
      .send({ bankReference: 'BK-LP', receivedAmount: { amount: o.total, currency: 'KGS' } });
    expect(conf.status).toBe(200);
    const done = await waiting;
    expect(done.status).toBe(200);
    expect(done.body.status).toBe('received');
    expect(Date.now() - started).toBeLessThan(8_000);
    // слот освобождён — новый ожидающий запрос принимается (статус уже не меняется → по часам)
    const later = t.req('get', `/payments/${o.paymentId}?wait=25`, a.seller).then((r) => r);
    await new Promise((r) => setTimeout(r, 300));
    clock.advance(25_000);
    const res = await later;
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('received');
  });

  it('long-polling без смены статуса: 200 с прежним статусом не позднее 25 с по Clock', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    const t0 = Date.now();
    const waiting = t.req('get', `/payments/${o.paymentId}?wait=25`, a.cashier).then((r) => r);
    await new Promise((r) => setTimeout(r, 500));
    clock.advance(24_000);
    await new Promise((r) => setTimeout(r, 500));
    let settled = false;
    void waiting.then(() => (settled = true));
    await new Promise((r) => setTimeout(r, 300));
    expect(settled).toBe(false);
    clock.advance(1_000);
    const res = await waiting;
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('cash_pending');
    expect(Date.now() - t0).toBeLessThan(10_000);
  });

  it('long-polling: отключение клиента освобождает слот ожидания (следующий запрос — не 429)', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    const first = t.req('get', `/payments/${o.paymentId}?wait=25`, a.cashier);
    const settled = first.then(
      () => 'done',
      () => 'aborted',
    );
    await new Promise((r) => setTimeout(r, 400));
    first.abort();
    await settled;
    await new Promise((r) => setTimeout(r, 600));
    const again = t.req('get', `/payments/${o.paymentId}?wait=25`, a.cashier).then((r) => r);
    await new Promise((r) => setTimeout(r, 300));
    clock.advance(25_000);
    const res = await again;
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('cash_pending');
  });

  // --------------------------------------------------------------------------------------- режим клиента

  it('customer: QR при QR_PROVIDER=none → 422 payment_method_unavailable; наличные → 403; чужой заказ → 404', async () => {
    const own = await t.seedOrder({ createdBy: a.customer, method: 'qr_bakai', status: 'submitting' });
    let res = await t.pay(a.customer, own.orderId, { method: 'qr_bakai' });
    expect(res.status).toBe(422);
    expect(res.body.errors[0]).toMatchObject({ rule: 'payment_method_unavailable' });
    res = await t.pay(a.customer, own.orderId, { method: 'cash' });
    expect(res.status).toBe(403);
    const view = await t.req('get', `/payments/${own.paymentId}`, a.customer);
    expect(view.status).toBe(200);
    const foreign = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'submitting' });
    expect((await t.req('get', `/payments/${foreign.paymentId}`, a.customer)).status).toBe(404);
  });

  // --------------------------------------------------------------------------------------- порт для orders

  // 12: T-PAY-011 (начальный платёж по способу: cash_pending / qr / credit)
  it('PaymentsPort: createInitial по способу; afterCommit (none) → qr_shown; credit — шаг 1 PAY-031', async () => {
    const port = t.registry.get(PAYMENTS_PORT);
    const actor = { userId: a.cashier.userId, roles: ['cashier'], isCustomer: false };
    const mk = async (method: 'cash' | 'qr_bakai' | 'credit', customerId = RETAIL_CUSTOMER_ID, act = actor) => {
      const o = await t.seedOrder({ createdBy: a.cashier, method: 'cash', status: 'submitting' });
      await t.forcePayment(o.paymentId, { status: 'voided' });
      return t.db.transaction((tx) =>
        port.createInitial(tx, {
          orderId: o.orderId,
          customerId,
          method,
          amount: o.total,
          actor: act,
          idempotencyKey: `order:${randomUUID()}`,
        }),
      );
    };
    expect((await mk('cash')).status).toBe('cash_pending');
    const qr = await mk('qr_bakai');
    expect(qr).toMatchObject({ status: 'qr_pending', qrProvider: 'none' });
    const after = await port.afterCommit(qr.paymentId, actor);
    expect(after).toMatchObject({ payment: { status: 'qr_shown' }, warnings: [] });
    await expect(mk('credit')).rejects.toMatchObject({ code: 'CUSTOMER_NOT_IDENTIFIED' });
    const noCredit = await t.createOnecCustomer({ creditAllowed: false });
    await expect(mk('credit', noCredit)).rejects.toMatchObject({ code: 'CREDIT_BLOCKED' });
    const ok = await t.createOnecCustomer({ creditAllowed: true, creditLimit: '1000000.00' });
    expect((await mk('credit', ok)).status).toBe('credit');
    const cust = { userId: a.customer.userId, roles: ['customer'], isCustomer: true };
    await expect(mk('credit', ok, cust)).rejects.toMatchObject({ code: 'FORBIDDEN' });
  });

  // RM-F-009 (ветви сценария «платёж», ревью F-trace-2): форма тела и права по способу, перевыпуск без QR, повтор
  // показа QR, QR при платеже на разборе (08 §4.8.6; 07 §6.4; ядро §22.5).
  it('POST /orders/{id}/payments: форма тела по способу, права на QR, перевыпуск без QR, повтор показа, разбор → 409', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    let res = await t.pay(a.cashier, o.orderId, { method: 'cash', reissueQr: true });
    expect(res.status).toBe(400);
    expect(res.body.errors[0]).toMatchObject({ field: 'method', rule: 'not_applicable' });
    res = await t.pay(a.cashier, o.orderId, {
      method: 'qr_bakai',
      receivedAmount: { amount: o.total, currency: 'KGS' },
    });
    expect(res.status).toBe(400);
    expect(res.body.errors[0]).toMatchObject({ field: 'receivedAmount', rule: 'not_applicable' });
    for (const role of ['admin', 'owner'] as const) {
      res = await t.pay(a[role], o.orderId, { method: 'qr_bakai' });
      expect(res.status, role).toBe(403);
      expect(res.body.code).toBe('FORBIDDEN');
    }
    // reissueQr при открытом наличном платеже — QR-платежа для перевыпуска нет.
    res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai', reissueQr: true });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'PAYMENT_STATE_INVALID', reason: 'transition_not_allowed' });
    expect((await t.payment(o.paymentId)).status).toBe('cash_pending');
    // QR показан → повторный запрос без reissueQr: тот же платёж (200), без нового QR.
    const q = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    const shown = await t.pay(a.cashier, q.orderId, { method: 'qr_bakai' });
    expect(shown.status).toBe(200);
    const again = await t.pay(a.cashier, q.orderId, { method: 'qr_bakai' });
    expect(again.status).toBe(200);
    expect(again.body.id).toBe(shown.body.id);
    expect(again.body.status).toBe('qr_shown');
    // Платёж на разборе (manual_confirm): повтор QR → 409 open_payment_exists.
    const stepUp = await t.stepUp(a.senior_seller, 'payment.qr.confirm_manual');
    const mc = await t
      .req('post', `/payments/${q.paymentId}/confirm-manual`, a.senior_seller, { idem: true, stepUp })
      .send({ bankReference: 'BK-9', receivedAmount: { amount: '1.00', currency: 'KGS' } });
    expect(mc.body.status).toBe('manual_confirm');
    res = await t.pay(a.cashier, q.orderId, { method: 'qr_bakai' });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'PAYMENT_STATE_INVALID', reason: 'open_payment_exists' });
  });

  // RM-F-009 (100 % ветвей критичного сценария «платёж», ревью F-trace-2): граничные ветви PaymentsPort.
  it('PaymentsPort: повтор ключа — тот же платёж; сумма 0 → 422; без инициатора — ошибка; afterCommit — не QR / нет права / не найден', async () => {
    const port = t.registry.get(PAYMENTS_PORT);
    const actor = { userId: a.cashier.userId, roles: ['cashier'], isCustomer: false };
    const o = await t.seedOrder({ createdBy: a.cashier, method: 'cash', status: 'submitting' });
    await t.forcePayment(o.paymentId, { status: 'voided' });
    const key = `order:${randomUUID()}`;
    const input = {
      orderId: o.orderId,
      customerId: RETAIL_CUSTOMER_ID,
      method: 'cash' as const,
      amount: o.total,
      actor,
      idempotencyKey: key,
    };
    const first = await t.db.transaction((tx) => port.createInitial(tx, input));
    const again = await t.db.transaction((tx) => port.createInitial(tx, input));
    expect(again.paymentId).toBe(first.paymentId);
    const rows = await t.q<{ n: string }>(`SELECT count(*)::text AS n FROM payments WHERE idempotency_key = $1`, [key]);
    expect(rows[0].n).toBe('1');
    await expect(
      t.db.transaction((tx) =>
        port.createInitial(tx, { ...input, amount: '0.00', idempotencyKey: `order:${randomUUID()}` }),
      ),
    ).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
    await expect(
      t.db.transaction((tx) =>
        port.createInitial(tx, {
          ...input,
          actor: { userId: null, roles: [], isCustomer: false },
          idempotencyKey: `order:${randomUUID()}`,
        }),
      ),
    ).rejects.toThrow(/инициатор/);
    // afterCommit: наличные — без QR; QR без права payment.qr.show (owner) — без выдачи; уже показан — без повтора.
    const cash = await port.afterCommit(first.paymentId, actor);
    expect(cash).toMatchObject({ payment: { status: 'cash_pending' }, warnings: [] });
    await expect(port.afterCommit(randomUUID(), actor)).rejects.toMatchObject({ code: 'NOT_FOUND' });
    await t.forcePayment(first.paymentId, { status: 'voided' });
    const qr = await t.db.transaction((tx) =>
      port.createInitial(tx, { ...input, method: 'qr_bakai', idempotencyKey: `order:${randomUUID()}` }),
    );
    const owner = { userId: a.owner.userId, roles: ['owner'], isCustomer: false };
    expect(await port.afterCommit(qr.paymentId, owner)).toMatchObject({
      payment: { status: 'qr_pending' },
      warnings: [],
    });
    expect((await port.afterCommit(qr.paymentId, actor)).payment.status).toBe('qr_shown');
    expect((await port.afterCommit(qr.paymentId, actor)).payment.status).toBe('qr_shown');
    // Список без QR-платежей — без статического QR; voidOpenForOrderCancel пропускает конечные статусы.
    const c2 = await t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_payment' });
    expect((await t.pay(a.cashier, c2.orderId, { method: 'cash' })).status).toBe(200);
    expect((await port.listForOrder(c2.orderId)).map((p) => p.status)).toEqual(['received']);
    const none = await t.db.transaction((tx) =>
      port.voidOpenForOrderCancel(tx, { orderId: c2.orderId, actor: { userId: null, roles: [], isCustomer: false } }),
    );
    expect(none).toEqual([]);
  });

  it('PaymentsPort.voidOpenForOrderCancel: неполученные → voided (order_cancelled), credit остаётся', async () => {
    const port = t.registry.get(PAYMENTS_PORT);
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    const ids = await t.db.transaction((tx) =>
      port.voidOpenForOrderCancel(tx, {
        orderId: o.orderId,
        actor: { userId: a.cashier.userId, roles: ['cashier'], isCustomer: false },
      }),
    );
    expect(ids).toEqual([o.paymentId]);
    expect(await t.payment(o.paymentId)).toMatchObject({ status: 'voided', void_reason: 'order_cancelled' });
    expect(await port.receivedTotal(null, o.orderId)).toBe('0.00');
    expect((await port.listForOrder(o.orderId)).map((p) => p.status)).toEqual(['voided']);
  });
});

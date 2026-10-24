import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { systemActor } from '../../src/common/audit/audit-context.js';
import { PAYMENTS_PORT } from '../../src/common/ports/index.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { PaymentNotifier } from '../../src/payments/infra/payment-notifier.js';
import type { PaymentRow } from '../../src/payments/infra/payments.repository.js';
import { QrIssuer } from '../../src/payments/qr/qr-issuer.service.js';
import type { PosActor } from '../support/pos-fixture.js';
import { PaymentsTestApp } from './support/payments-app.js';

type Actors = Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;

/**
 * QR-оплата через 1С (`QR_PROVIDER=onec`, RM-F-016; ядро §24.4; 08 API-183…API-185) на `ScriptedOnecGateway` —
 * **тестовые данные**: выдача QR после COMMIT, перевыпуск на том же `payment_id`, отказ/таймаут 1С →
 * `warnings[QR_UNAVAILABLE]` и ручной путь, опрос статуса (оплачено / расхождение / неизвестный референс / истечение /
 * поздняя оплата), отмена QR в 1С при смене способа, элемент плана обмена, `refreshStatus`.
 */
describe('payments: QR через 1С (RM-F-016)', () => {
  const t = new PaymentsTestApp();
  let a: Actors;

  beforeAll(async () => {
    await t.startPayments({ env: { QR_PROVIDER: 'onec', ONEC_SYNC_CHECK_TIMEOUT_MS: '800' }, jobs: false });
    a = await t.actors();
    t.notifications.roleMembers.set('cashier', [a.cashier.userId]);
    t.notifications.roleMembers.set('admin', [a.admin.userId]);
  });
  beforeEach(() => {
    t.onec.reset();
  });
  afterAll(async () => {
    await t.stop();
  });

  async function qrOrder(by: PosActor = a.seller) {
    const o = await t.seedOrder({ createdBy: by, method: 'qr_bakai', status: 'awaiting_payment' });
    const res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('qr_shown');
    return { ...o, ref: res.body.qr.bankReference as string };
  }

  // 12: T-PAY-037 (QR через 1С: provider onec, сумма заказа), T-PAY-039 (2) (перевыпуск — тот же платёж, новый референс), T-PAY-018 (autoConfirm=true при onec)
  it('AC-API-183: QR от 1С — provider onec, autoConfirm, сумма заказа; «Обновить QR» — тот же платёж, новый референс', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    const res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      id: o.paymentId,
      status: 'qr_shown',
      qr: { provider: 'onec', autoConfirm: true, amount: { amount: o.total } },
      warnings: [],
    });
    expect(res.body.qr.payload).toBeTruthy();
    expect(new Date(res.body.qr.expiresAt).getTime()).toBeGreaterThan(Date.now());
    const create = t.onec.callsOf('createQrPayment');
    expect(create).toHaveLength(1);
    expect(create[0][0]).toMatchObject({ externalId: o.paymentId, orderExternalId: o.orderId, amount: o.total });
    const ref1 = res.body.qr.bankReference as string;
    const re = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai', reissueQr: true });
    expect(re.status).toBe(200);
    expect(re.body.id).toBe(o.paymentId);
    expect(re.body.qr.bankReference).not.toBe(ref1);
    expect(await t.auditRows('payment.qr_reissued', o.paymentId)).toHaveLength(1);
    expect((await t.payment(o.paymentId)).qr_provider).toBe('onec');
    // 12 T-PAY-016; PAY-025 / SYNC-078 (ревью F-orders-1c-5): прежний QR отменён в 1С (reason=reissue), референс — в истории.
    const cancels = t.onec.callsOf('cancelQrPayment');
    expect(cancels).toHaveLength(1);
    expect(cancels[0][0]).toBe(o.paymentId);
    expect(cancels[0][1]).toBe('reissue');
    const hist = await t.q<{ h: string[] }>(`SELECT qr_ref_history AS h FROM payments WHERE id = $1`, [o.paymentId]);
    expect(hist[0].h).toEqual([ref1]);
    // Оплата по заменённому референсу — тот же payment_id, разбор как поздней оплаты (qr_shown → manual_confirm).
    t.onec.qrPaidAfterPolls(1, { reference: ref1 });
    await t.qrStatus.pollOnce(o.paymentId);
    expect(await t.payment(o.paymentId)).toMatchObject({ status: 'manual_confirm', review_reason: 'late_payment' });
  });

  // 12: T-PAY-039 (4) (оплата по прежнему референсу при перевыпуске)
  it('перевыпуск: прежний QR уже оплачен (ответ отмены 1С «paid») → оплата применена, новый QR не выдаётся', async () => {
    const o = await qrOrder();
    t.onec.script('cancelQrPayment', {
      respond: { body: { externalId: o.paymentId, status: 'paid', paidAmount: o.total, bankReference: 'BK-REISSUE' } },
    });
    const re = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai', reissueQr: true });
    expect(re.status).toBe(200);
    expect(t.onec.callsOf('createQrPayment')).toHaveLength(1);
    expect(await t.payment(o.paymentId)).toMatchObject({ status: 'received', bank_reference: 'BK-REISSUE' });
  });

  // 12: T-PAY-039 (1) (qr_shown → qr_expired)
  it('05 §6.7.3: 1С сообщила cancelled без запроса backend → qr_shown → qr_expired сразу, опрос прекращён', async () => {
    const o = await qrOrder();
    t.onec.always('getQrPaymentStatus', {
      respond: {
        body: {
          externalId: o.paymentId,
          status: 'cancelled',
          reference: o.ref,
          amount: o.total,
          paidAmount: null,
          paidAt: null,
          bankReference: null,
          expiresAt: null,
          documentRef: null,
          documentType: null,
        },
      },
    });
    try {
      const r = await t.qrStatus.pollOnce(o.paymentId);
      expect(r).toMatchObject({ continue: false, status: 'qr_expired' });
    } finally {
      t.onec.always('getQrPaymentStatus', null);
    }
    const p = await t.payment(o.paymentId);
    expect(p.status).toBe('qr_expired');
    expect(new Date(p.qr_expires_at as string | Date).getTime()).toBeLessThanOrEqual(Date.now());
  });

  // 12: T-PAY-042 (6) (клиенту статический QR не предлагается)
  it('клиенту-покупателю статический QR не показывается (PAY-022, CUST-024): manualOnly кассира → qr=null, без reissue; QR 1С — виден', async () => {
    const prev = await t.q<{ value: unknown }>(`SELECT value FROM app_settings WHERE key = 'qr.static_payload'`);
    await t.setSetting('qr.static_payload', '"ELQR-STATIC-TEST"');
    try {
      const o = await t.seedOrder({ createdBy: a.customer, method: 'qr_bakai', status: 'awaiting_payment' });
      const manual = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai', manualOnly: true });
      expect(manual.body).toMatchObject({
        status: 'qr_shown',
        qr: { provider: 'elqr_static', payload: 'ELQR-STATIC-TEST' },
      });
      const one = await t.req('get', `/payments/${o.paymentId}`, a.customer);
      expect(one.status).toBe(200);
      expect(one.body.qr).toBeNull();
      expect(one.body.allowedActions).not.toContain('reissue_qr');
      const list = await t.req('get', `/orders/${o.orderId}/payments`, a.customer);
      expect(list.status).toBe(200);
      const items = (list.body.items ?? list.body) as { id: string; qr: unknown }[];
      expect(items.find((x) => x.id === o.paymentId)?.qr).toBeNull();
      // Кассир по-прежнему видит статический QR.
      expect((await t.req('get', `/payments/${o.paymentId}`, a.cashier)).body.qr).toMatchObject({
        provider: 'elqr_static',
      });
      // Динамический QR 1С клиенту показывается.
      const dyn = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai', reissueQr: true });
      expect(dyn.body.qr).toMatchObject({ provider: 'onec' });
      expect((await t.req('get', `/payments/${o.paymentId}`, a.customer)).body.qr).toMatchObject({ provider: 'onec' });
    } finally {
      // Настройка общая для набора: вернуть прежнее состояние (иначе соседние тесты видят статический QR).
      if (prev[0]) await t.setSetting('qr.static_payload', JSON.stringify(prev[0].value));
      else {
        await t.q(`DELETE FROM app_settings WHERE key = 'qr.static_payload'`);
        t.app.get(SettingsReader, { strict: false }).invalidate();
      }
    }
  });

  // 12: T-PAY-041 (1) (qr_pending без qr + QR_UNAVAILABLE; ручной путь), T-FAIL-008
  it('AC-API-185: 1С недоступна (503) → qr_pending без qr + QR_UNAVAILABLE; manualOnly → qr_shown autoConfirm=false; confirm-manual → received', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    t.onec.script('createQrPayment', { fixture: 'payments-qr.503' });
    let res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      status: 'qr_pending',
      qr: null,
      warnings: [expect.objectContaining({ code: 'QR_UNAVAILABLE' })],
    });
    res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai', manualOnly: true });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'qr_shown', qr: { autoConfirm: false, provider: 'none' } });
    expect(t.onec.callsOf('createQrPayment')).toHaveLength(1);
    // ручной QR не опрашивается у 1С
    expect((await t.qrStatus.pollOnce(o.paymentId)).continue).toBe(false);
    expect(t.onec.callsOf('getQrPaymentStatus')).toHaveLength(0);
    const stepUp = await t.stepUp(a.cashier, 'payment.qr.confirm_manual');
    res = await t
      .req('post', `/payments/${o.paymentId}/confirm-manual`, a.cashier, { idem: true, stepUp })
      .send({ bankReference: 'BK-FALLBACK', receivedAmount: { amount: o.total, currency: 'KGS' } });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'received', confirmationKind: 'manual', reviewReason: 'no_webhook' });
  });

  // 12: T-PAY-041 (2) (повтор после восстановления — тот же платёж → qr_shown)
  it('таймаут метода QR (ONEC_SYNC_CHECK_TIMEOUT_MS) и транспорт → QR_UNAVAILABLE; повтор после восстановления → qr_shown', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'submitting' });
    t.onec.script('createQrPayment', { hang: true }, { transport: true });
    const t0 = Date.now();
    let res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    expect(res.body).toMatchObject({
      status: 'qr_pending',
      warnings: [expect.objectContaining({ code: 'QR_UNAVAILABLE' })],
    });
    expect(Date.now() - t0).toBeLessThan(5_000);
    res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    expect(res.body.status).toBe('qr_pending');
    res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    expect(res.body).toMatchObject({ status: 'qr_shown', warnings: [] });
  });

  // 12: T-PAY-041 (прежний QR сохраняется + QR_UNAVAILABLE)
  it('перевыпуск при недоступной 1С: прежний QR и статус сохраняются + QR_UNAVAILABLE', async () => {
    const o = await qrOrder();
    t.onec.script('createQrPayment', { error: 503, code: 'POS_E_QR_UNAVAILABLE' });
    const res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai', reissueQr: true });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      status: 'qr_shown',
      qr: { bankReference: o.ref },
      warnings: [{ code: 'QR_UNAVAILABLE' }],
    });
  });

  // 12: T-PAY-038 (1) (received не позднее 2 опросов, опрос прекращается)
  it('AC-API-184: «оплачено, сумма = amount» → received не позднее 2 опросов; опрос прекращается', async () => {
    const o = await qrOrder();
    t.onec.qrPaidAfterPolls(2);
    expect(await t.qrStatus.pollOnce(o.paymentId)).toMatchObject({ continue: true, status: 'qr_shown' });
    expect(await t.qrStatus.pollOnce(o.paymentId)).toMatchObject({ continue: false, status: 'received' });
    expect(t.onec.qrPollCount(o.paymentId)).toBe(2);
    const p = await t.payment(o.paymentId);
    expect(p).toMatchObject({ status: 'received', bank_amount: o.total, received_by_user_id: null });
    expect(await t.orderMoney(o.orderId)).toMatchObject({ is_paid: true, paid_amount: o.total });
    expect(await t.transactionsOf(o.paymentId)).toEqual([expect.objectContaining({ kind: 'payment_received' })]);
    const audit = await t.auditRows('payment.received', o.paymentId);
    expect(audit).toHaveLength(1);
    expect(audit[0].actor_user_id).toBeNull();
    const view = await t.req('get', `/payments/${o.paymentId}`, a.cashier);
    expect(view.body).toMatchObject({ status: 'received', confirmationKind: 'webhook' });
    expect(t.notifications.of(a.seller.userId).some((n) => n.kind === 'payment_status')).toBe(true);
    // выход из qr_shown — дальше 1С не опрашивается
    expect((await t.qrStatus.pollOnce(o.paymentId)).continue).toBe(false);
    expect(t.onec.qrPollCount(o.paymentId)).toBe(2);
  });

  // 12: T-PAY-040 (а) (amount_mismatch → manual_confirm)
  it('«оплачено, сумма ≠ amount» → manual_confirm amount_mismatch, bank_amount; заказ не оплачен', async () => {
    const o = await qrOrder();
    t.onec.qrPaidAfterPolls(1, { paidAmount: '100.00' });
    await t.qrStatus.pollOnce(o.paymentId);
    expect(await t.payment(o.paymentId)).toMatchObject({
      status: 'manual_confirm',
      review_reason: 'amount_mismatch',
      bank_amount: '100.00',
    });
    expect(await t.orderMoney(o.orderId)).toMatchObject({ is_paid: false });
  });

  // 12: T-PAY-040 (б) (unknown_reference)
  it('оплата по неизвестному референсу (нет ни в текущем, ни в истории) → manual_confirm unknown_reference', async () => {
    const o = await qrOrder();
    t.onec.qrPaidAfterPolls(1, { reference: 'QR-OLD-REFERENCE' });
    await t.qrStatus.pollOnce(o.paymentId);
    expect(await t.payment(o.paymentId)).toMatchObject({
      status: 'manual_confirm',
      review_reason: 'unknown_reference',
    });
  });

  // 12: T-PAY-039 (1) (истечение по сроку), T-PAY-040 (в) (late_payment)
  it('истечение: «pending» после qr_expires_at → qr_expired; оплата после истечения → manual_confirm late_payment', async () => {
    const o = await qrOrder();
    await t.forcePayment(o.paymentId, { qr_expires_at: new Date(Date.now() - 1_000) });
    const r1 = await t.qrStatus.pollOnce(o.paymentId);
    // Опрос прекращается при выходе из qr_shown (RM-F-016 п. 5, PAY-023; ревью F-orders-1c-6).
    expect(r1).toMatchObject({ continue: false, status: 'qr_expired' });
    const polls = t.onec.qrPollCount(o.paymentId);
    expect((await t.qrStatus.pollOnce(o.paymentId)).continue).toBe(false);
    expect(t.onec.qrPollCount(o.paymentId)).toBe(polls);
    // Поздняя оплата после истечения — планом обмена или явным refreshStatus.
    t.onec.qrPaidAfterPolls(1);
    expect(await t.qrStatus.refresh(o.paymentId)).toBe(true);
    expect(await t.payment(o.paymentId)).toMatchObject({ status: 'manual_confirm', review_reason: 'late_payment' });
    // после разбора — «Обновить QR» из manual_confirm недопустим, а из qr_expired — тот же платёж
    const o2 = await qrOrder();
    await t.forcePayment(o2.paymentId, { status: 'qr_expired' });
    const re = await t.pay(a.cashier, o2.orderId, { method: 'qr_bakai', reissueQr: true });
    expect(re.body).toMatchObject({ id: o2.paymentId, status: 'qr_shown' });
    expect(re.body.qr.bankReference).not.toBe(o2.ref);
  });

  // 12: T-PAY-039 (истечение — только по наступившему сроку)
  it('«срок истёк» от 1С до qr_expires_at статус не меняет; job payments.qr_expire истекает только наступившие', async () => {
    const o = await qrOrder();
    t.onec.always('getQrPaymentStatus', { fixture: 'payments-status.expired.200' });
    await t.qrStatus.pollOnce(o.paymentId);
    expect((await t.payment(o.paymentId)).status).toBe('qr_shown');
    expect(await t.qrStatus.expireDue()).toBe(0);
    await t.forcePayment(o.paymentId, { qr_expires_at: new Date(Date.now() - 1_000) });
    expect(await t.qrStatus.expireDue()).toBeGreaterThanOrEqual(1);
    expect((await t.payment(o.paymentId)).status).toBe('qr_expired');
    // за горизонтом expiresAt + 60 с опрос прекращается
    await t.forcePayment(o.paymentId, { qr_expires_at: new Date(Date.now() - 120_000) });
    expect((await t.qrStatus.pollOnce(o.paymentId)).continue).toBe(false);
  });

  // 12: T-PAY-036 (смена способа при qr_shown: void method_changed, отмена QR в 1С)
  it('смена способа при qr_shown: системный void method_changed и отмена QR в 1С; ответ «уже оплачено» — разбор', async () => {
    const o = await qrOrder();
    const res = await t.pay(a.cashier, o.orderId, { method: 'cash' });
    expect(res.status).toBe(201);
    await new Promise((r) => setTimeout(r, 300));
    expect(t.onec.callsOf('cancelQrPayment')).toHaveLength(1);
    expect(await t.payment(o.paymentId)).toMatchObject({
      status: 'voided',
      void_reason: 'method_changed',
      qr_provider_status_raw: 'cancelled',
    });
    const o2 = await qrOrder();
    t.onec.script('cancelQrPayment', { fixture: 'payments-qr-cancel.200.paid' });
    const stepUp = await t.stepUp(a.cashier, 'payment.void');
    const v = await t
      .req('post', `/payments/${o2.paymentId}/void`, a.cashier, { idem: true, stepUp })
      .send({ reason: 'клиент ушёл', reasonCode: 'customer_refused' });
    expect(v.status).toBe(200);
    await new Promise((r) => setTimeout(r, 300));
    expect(await t.payment(o2.paymentId)).toMatchObject({ status: 'voided', qr_provider_status_raw: 'paid' });
    expect(t.notifications.items.some((n) => n.dedupeKey === `payment_status:${o2.paymentId}:voided_paid`)).toBe(true);
    // 05 §6.7.3, AC-SYNC-078, 12 T-SEC-039 (а) (ревью F-orders-1c-4): журнал синхронизации и уведомления кассиру и администратору.
    const errs = await t.q<{ error_code: string; entity: string; payload: Record<string, unknown> }>(
      `SELECT error_code, entity::text AS entity, payload FROM sync_errors WHERE local_id = $1`,
      [o2.paymentId],
    );
    expect(errs).toHaveLength(1);
    // 07 §6.1.1 (15 кодов, миграция 0013, ADR-103): код журнала — QR_PAID_AFTER_VOID, не OTHER.
    expect(errs[0]).toMatchObject({
      error_code: 'QR_PAID_AFTER_VOID',
      entity: 'payment_docs',
      payload: { code: 'QR_PAID_AFTER_VOID', paymentId: o2.paymentId },
    });
    // 05 §6.7.3: кассиру и администратору (роли), а также аннулировавшему и автору заказа — не только автору.
    for (const u of [a.cashier.userId, a.admin.userId, a.seller.userId]) {
      expect(
        t.notifications.of(u).some((n) => n.dedupeKey.startsWith(`payment_status:${o2.paymentId}:voided_paid`)),
        u,
      ).toBe(true);
    }
    // Тот же факт планом обмена — без второй записи.
    await t.qrStatus.applyOnecQrStatus({
      externalId: o2.paymentId,
      status: 'paid',
      reference: o2.ref,
      paidAmount: o2.total,
      paidAt: new Date().toISOString(),
      bankReference: 'BK-2',
    } as never);
    expect(await t.q(`SELECT 1 FROM sync_errors WHERE local_id = $1`, [o2.paymentId])).toHaveLength(1);
  });

  // 12: T-PAY-040 (г) (paid для voided: статус не меняется, sync_errors QR_PAID_AFTER_VOID)
  it('оплата по аннулированному QR из плана обмена (отмена в 1С не дошла) → статус не меняется, sync_errors и уведомления', async () => {
    const o = await qrOrder();
    t.onec.always('cancelQrPayment', { error: 503, code: 'POS_E_UNAVAILABLE' });
    try {
      const res = await t.pay(a.cashier, o.orderId, { method: 'cash' });
      expect(res.status).toBe(201);
      await new Promise((r) => setTimeout(r, 300));
      expect((await t.payment(o.paymentId)).status).toBe('voided');
      // Повтор отмены — 1, 2, 5 мин до expiresAt (SYNC-078).
      const next = await t.qrStatus.pollOnce(o.paymentId);
      expect(next).toMatchObject({ continue: true, delaySeconds: 60, status: 'voided' });
    } finally {
      t.onec.always('cancelQrPayment', null);
    }
    const r = await t.qrStatus.applyOnecQrStatus({
      externalId: o.paymentId,
      status: 'paid',
      reference: o.ref,
      paidAmount: o.total,
      paidAt: new Date().toISOString(),
      bankReference: 'BK-LATE',
    } as never);
    expect(r).toBe('voided_paid');
    expect(await t.payment(o.paymentId)).toMatchObject({
      status: 'voided',
      qr_provider_status_raw: 'paid',
      bank_reference: 'BK-LATE',
    });
    const errs = await t.q<{ error_code: string; payload: Record<string, unknown> }>(
      `SELECT error_code, payload FROM sync_errors WHERE local_id = $1`,
      [o.paymentId],
    );
    expect(errs).toEqual([
      expect.objectContaining({
        error_code: 'QR_PAID_AFTER_VOID',
        payload: expect.objectContaining({ code: 'QR_PAID_AFTER_VOID' }),
      }),
    ]);
    expect(t.notifications.of(a.admin.userId).some((n) => n.payload?.paymentId === o.paymentId)).toBe(true);
    // Отмена в 1С больше не повторяется (факт оплаты известен).
    expect((await t.qrStatus.pollOnce(o.paymentId)).continue).toBe(false);
  });

  // 07 §5.53 (FIX-F-06): строка, записанная до миграции 0013 как OTHER + payload.code, считается той же записью.
  it('оплата по аннулированному QR: прежняя запись OTHER + payload.code = QR_PAID_AFTER_VOID — вторая строка не пишется', async () => {
    const o = await qrOrder();
    t.onec.always('cancelQrPayment', { error: 503, code: 'POS_E_UNAVAILABLE' });
    try {
      expect((await t.pay(a.cashier, o.orderId, { method: 'cash' })).status).toBe(201);
      await new Promise((r) => setTimeout(r, 300));
    } finally {
      t.onec.always('cancelQrPayment', null);
    }
    await t.q(
      `INSERT INTO sync_errors (entity, local_id, error_code, message, payload, severity)
       VALUES ('payment_docs', $1::uuid, 'OTHER', 'QR_PAID_AFTER_VOID: legacy', $2::jsonb, 'error')`,
      [o.paymentId, JSON.stringify({ code: 'QR_PAID_AFTER_VOID', paymentId: o.paymentId })],
    );
    const r = await t.qrStatus.applyOnecQrStatus({
      externalId: o.paymentId,
      status: 'paid',
      reference: o.ref,
      paidAmount: o.total,
      paidAt: new Date().toISOString(),
      bankReference: 'BK-LEGACY',
    } as never);
    expect(r).toBe('voided_paid');
    const errs = await t.q<{ error_code: string }>(`SELECT error_code FROM sync_errors WHERE local_id = $1`, [
      o.paymentId,
    ]);
    expect(errs).toEqual([{ error_code: 'OTHER' }]);
  });

  // Ревью F, RC-9: «одна запись на платёж» — и для уведомлений. Аннулированный QR-платёж, отмена в 1С не дошла (503).
  async function voidedQr() {
    const o = await qrOrder();
    t.onec.always('cancelQrPayment', { error: 503, code: 'POS_E_UNAVAILABLE' });
    try {
      expect((await t.pay(a.cashier, o.orderId, { method: 'cash' })).status).toBe(201);
      await new Promise((r) => setTimeout(r, 300));
    } finally {
      t.onec.always('cancelQrPayment', null);
    }
    expect(await t.payment(o.paymentId)).toMatchObject({ status: 'voided' });
    return o;
  }

  /** Ответ отмены QR приходит после того, как опрос / план обмена уже записал оплату (гонка путей, RC-9). */
  function paidReportDuringCancel(o: Awaited<ReturnType<typeof qrOrder>>, bankReference: string) {
    const gw = t.onec;
    const orig = gw.cancelQrPayment.bind(gw);
    gw.cancelQrPayment = async (...args: Parameters<typeof orig>) => {
      expect(
        await t.qrStatus.applyOnecQrStatus({
          externalId: o.paymentId,
          status: 'paid',
          reference: o.ref,
          paidAmount: o.total,
          paidAt: new Date().toISOString(),
          bankReference,
        } as never),
      ).toBe('voided_paid');
      return orig(...args);
    };
    return () => Reflect.deleteProperty(gw, 'cancelQrPayment');
  }

  function voidedPaidCalls(spy: { mock: { calls: unknown[][] } }, paymentId: string, role?: string) {
    return spy.mock.calls.filter((c) => {
      const n = (role === undefined ? c[0] : c[1]) as { paymentId: string; event: string };
      return (role === undefined || c[0] === role) && n.paymentId === paymentId && n.event === 'voided_paid';
    });
  }

  it('RC-9: оплата пришла опросом, пока шла отмена QR («уже оплачено») — одна запись журнала, уведомления один раз', async () => {
    const o = await voidedQr();
    const notifier = t.app.get(PaymentNotifier, { strict: false });
    const roleSpy = vi.spyOn(notifier, 'notifyRole');
    const userSpy = vi.spyOn(notifier, 'notify');
    const restore = paidReportDuringCancel(o, 'BK-POLL');
    try {
      t.onec.script('cancelQrPayment', { fixture: 'payments-qr-cancel.200.paid' });
      expect(await t.qrStatus.cancelAtProvider(o.paymentId, 'method_changed')).toBe('done');
    } finally {
      restore();
    }
    try {
      // Первым факт записал опрос: его референс банка не перезаписан ответом отмены.
      expect(await t.payment(o.paymentId)).toMatchObject({
        status: 'voided',
        qr_provider_status_raw: 'paid',
        bank_reference: 'BK-POLL',
      });
      const errs = await t.q<{ payload: Record<string, unknown> }>(
        `SELECT payload FROM sync_errors WHERE local_id = $1`,
        [o.paymentId],
      );
      expect(errs).toEqual([{ payload: expect.objectContaining({ source: 'status_report' }) }]);
      expect(voidedPaidCalls(roleSpy, o.paymentId, 'cashier')).toHaveLength(1);
      expect(voidedPaidCalls(roleSpy, o.paymentId, 'admin')).toHaveLength(1);
      // Аннулировавший и автор заказа (seller) — по одному вызову на получателя.
      const users = voidedPaidCalls(userSpy, o.paymentId).map((c) => (c[0] as { userId: string }).userId);
      expect(users).toContain(a.seller.userId);
      expect(users).toHaveLength(new Set(users).size);
    } finally {
      roleSpy.mockRestore();
      userSpy.mockRestore();
    }
  });

  it('RC-9: факт оплаты (`qr_provider_status_raw = paid`) не перезаписывается итогом отмены `cancelled`', async () => {
    const o = await voidedQr();
    const restore = paidReportDuringCancel(o, 'BK-PAID-FIRST');
    try {
      // Без сценария — ответ отмены по умолчанию: QR отменён.
      expect(await t.qrStatus.cancelAtProvider(o.paymentId, 'method_changed')).toBe('done');
    } finally {
      restore();
    }
    expect(await t.payment(o.paymentId)).toMatchObject({
      status: 'voided',
      qr_provider_status_raw: 'paid',
      bank_reference: 'BK-PAID-FIRST',
    });
    expect((await t.qrStatus.pollOnce(o.paymentId)).continue).toBe(false);
  });

  it('RC-9: параллельные сообщения об оплате аннулированного QR — одна строка sync_errors, уведомления один раз', async () => {
    const o = await voidedQr();
    const svc = t.qrStatus as unknown as {
      readonly repo: { findById(db: unknown, id: string): Promise<PaymentRow | null> };
      readonly db: unknown;
      reportPaidAfterVoid(
        p: PaymentRow,
        d: { bankReference: string | null; paidAmount: string | null; source: string },
      ): Promise<void>;
    };
    const p = await svc.repo.findById(svc.db, o.paymentId);
    expect(p).not.toBeNull();
    const notifier = t.app.get(PaymentNotifier, { strict: false });
    const roleSpy = vi.spyOn(notifier, 'notifyRole');
    try {
      await Promise.all(
        Array.from({ length: 6 }, (_, i) =>
          svc.reportPaidAfterVoid(p as PaymentRow, { bankReference: `BK-${i}`, paidAmount: o.total, source: 'race' }),
        ),
      );
      expect(await t.q(`SELECT 1 FROM sync_errors WHERE local_id = $1`, [o.paymentId])).toHaveLength(1);
      expect(voidedPaidCalls(roleSpy, o.paymentId, 'cashier')).toHaveLength(1);
    } finally {
      roleSpy.mockRestore();
    }
  });

  // 12: T-PAY-038 (2)–(3) (paid из /changes раньше опроса; повтор идемпотентен)
  it('элемент плана обмена QrPaymentStatus (payments.onec-qr-status): оплачено → received; повтор идемпотентен', async () => {
    const o = await qrOrder();
    const payload = {
      externalId: o.paymentId,
      status: 'paid' as const,
      reference: o.ref,
      amount: o.total,
      paidAmount: o.total,
      paidAt: new Date().toISOString(),
      bankReference: 'BK-CHANGES-1',
    };
    expect(await t.qrStatus.applyOnecQrStatus(payload)).toBe('received');
    expect(await t.qrStatus.applyOnecQrStatus(payload)).toBe('review_only');
    expect(await t.transactionsOf(o.paymentId)).toHaveLength(1);
    expect(await t.orderMoney(o.orderId)).toMatchObject({ paid_amount: o.total });
  });

  it('GET ?refreshStatus=true: синхронный опрос 1С; 1С недоступна → текущее состояние + STALE_DATA', async () => {
    const o = await qrOrder();
    t.onec.script('getQrPaymentStatus', { transport: true });
    let res = await t.req('get', `/payments/${o.paymentId}?refreshStatus=true`, a.cashier);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'qr_shown', warnings: [{ code: 'STALE_DATA' }] });
    t.onec.qrPaidAfterPolls(1);
    res = await t.req('get', `/payments/${o.paymentId}?refreshStatus=true`, a.cashier);
    expect(res.body).toMatchObject({ status: 'received', warnings: [] });
  });

  // 12: T-PAY-037 (createPaymentQr после COMMIT, вне транзакции), T-PAY-041 (отказ → QR_UNAVAILABLE, заказ создаётся)
  it('PaymentsPort.afterCommit при onec: QR у 1С после COMMIT; отказ → QR_UNAVAILABLE (заказ создаётся)', async () => {
    const port = t.registry.get(PAYMENTS_PORT);
    const actor = { userId: a.seller.userId, roles: ['seller'], isCustomer: false };
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'submitting' });
    let r = await port.afterCommit(o.paymentId, actor);
    expect(r).toMatchObject({ payment: { status: 'qr_shown', qrProvider: 'onec' }, warnings: [] });
    const o2 = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'submitting' });
    t.onec.script('createQrPayment', { error: 422, code: 'POS_E_VALIDATION' });
    r = await port.afterCommit(o2.paymentId, actor);
    expect(r).toMatchObject({ payment: { status: 'qr_pending' }, warnings: [{ code: 'QR_UNAVAILABLE' }] });
  });

  // Контракт 1С v1 `QrCreateRequest.orderExternalId` обязателен (ТЗ для 1С §6.14; разбор 98 п. 75): платёж без заказа
  // (оплата долга, Q-152) QR у 1С не запрашивает — явный отказ QR_UNAVAILABLE; статический QR (manualOnly) выдаётся.
  it('QR без заказа: запрос в 1С не уходит (нет orderExternalId), QR_UNAVAILABLE; manualOnly → статический QR', async () => {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'submitting' });
    await t.forcePayment(o.paymentId, { order_id: null });
    const issuer = t.app.get(QrIssuer, { strict: false });
    const audit = systemActor('test');
    const r = await issuer.issue({ paymentId: o.paymentId, manualOnly: false, actorUserId: a.cashier.userId, audit });
    expect(r.warnings).toEqual([{ code: 'QR_UNAVAILABLE', message: expect.any(String) }]);
    expect(r.payment).toMatchObject({ id: o.paymentId, status: 'qr_pending', orderId: null });
    expect(t.onec.callsOf('createQrPayment')).toHaveLength(0);
    expect((await t.payment(o.paymentId)).status).toBe('qr_pending');
    const m = await issuer.issue({ paymentId: o.paymentId, manualOnly: true, actorUserId: a.cashier.userId, audit });
    expect(m.warnings).toEqual([]);
    expect(m.payment).toMatchObject({ status: 'qr_shown', qrProviderRef: null });
    expect(t.onec.callsOf('createQrPayment')).toHaveLength(0);
  });

  // 12: T-PAY-042 (1), (4) (клиент: QR своего заказа; manualOnly → 403)
  it('режим клиента при onec: QR по своему заказу → qr_shown; manualOnly → 403; вебхук банка → 404', async () => {
    const o = await t.seedOrder({ createdBy: a.customer, method: 'qr_bakai', status: 'submitting' });
    let res = await t.pay(a.customer, o.orderId, { method: 'qr_bakai' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'qr_shown', qr: { provider: 'onec', autoConfirm: true } });
    expect(res.body).not.toHaveProperty('externalRef');
    res = await t.pay(a.customer, o.orderId, { method: 'qr_bakai', manualOnly: true });
    expect(res.status).toBe(403);
    expect((await t.req('post', '/payments/qr/webhook').send({})).status).toBe(404);
  });
});

/** Полный путь через pg-boss: выдача QR → задача `payments.qr_onec_poll` → оплата → long-polling будится. */
describe('payments: опрос QR воркером (pg-boss, WORKERS_ENABLED=true)', () => {
  const t = new PaymentsTestApp();
  let a: Actors;

  beforeAll(async () => {
    await t.startPayments({ env: { QR_PROVIDER: 'onec', WORKERS_ENABLED: 'true', QR_ONEC_POLL_SECONDS: '1' } });
    a = await t.actors();
  });
  afterAll(async () => {
    await t.stop();
  });

  // 12: T-PAY-038 (опрос воркером pg-boss → received)
  it('QR → опрос каждые QR_ONEC_POLL_SECONDS → received; GET ?wait=25 отвечает при смене статуса', async () => {
    t.onec.qrPaidAfterPolls(2);
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    const res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    expect(res.body.status).toBe('qr_shown');
    const t0 = Date.now();
    let status = 'qr_shown';
    while (status === 'qr_shown' && Date.now() - t0 < 40_000) {
      const r = await t.req('get', `/payments/${o.paymentId}?wait=25`, a.seller);
      expect(r.status).toBe(200);
      status = r.body.status;
    }
    expect(status).toBe('received');
    expect(t.onec.qrPollCount(o.paymentId)).toBeGreaterThanOrEqual(2);
    expect(await t.orderMoney(o.orderId)).toMatchObject({ is_paid: true });
  });
});

import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pino from 'pino';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { AdminReportsService } from '../../src/admin/reports/admin-reports.service.js';
import { CLOCK, type Clock } from '../../src/common/auth/clock.js';
import { ONEC_OUTBOX_WRITER } from '../../src/common/ports/index.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { BANK_QR_API } from '../../src/integrations/payments/bank/bank-qr-api.js';
import type { SandboxBankQrApi } from '../../src/integrations/payments/bank/sandbox-bank-qr.api.js';
import { signWebhook } from '../../src/integrations/payments/bank/webhook-signature.js';
import { OutboxDispatcher } from '../../src/jobs/outbox/outbox-dispatcher.js';
import { BankQrHttpModule } from '../../src/payments/bank/bank-qr-http.module.js';
import { QrReconciliationService } from '../../src/payments/bank/qr-reconciliation.service.js';
import { PaymentOnecDocument } from '../../src/payments/onec/payment-onec-document.js';
import { PaymentsJobsBridge } from '../../src/payments/jobs/payments-jobs.bridge.js';
import { OnecOutboxDelivery } from '../../src/sync/outbox/onec-outbox.delivery.js';
import { OnecOutboxWriterService } from '../../src/sync/outbox/onec-outbox.writer.js';
import { schedulerConfigFromEnv } from '../../src/sync/scheduler/scheduler.config.js';
import { contractErrors } from '../cashier-foundation/support/onec-contract.js';
import type { PosActor } from '../support/pos-fixture.js';
import { PaymentsTestApp } from './support/payments-app.js';

type Actors = Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;

/** Секрет подписи вебхука — **тестовое значение**, файл во временном каталоге (секреты — только `*_FILE`). */
const SECRET = randomBytes(24).toString('hex');

/**
 * QR напрямую от банка через наш сервер (`QR_PROVIDER=bank`, `BANK_QR_ADAPTER=sandbox`; ADR-123, P-004) — **тестовые
 * данные** на песочнице банка и фикстурах 1С (`ONEC_MODE=fixtures`, `ScriptedOnecGateway`): выдача QR, вебхук с
 * подписью по сырому телу и IP-allowlist, идемпотентность, расхождения (`amount_mismatch`, `late_payment`,
 * `unknown_reference`), ручное подтверждение со step-up, документ оплаты в `onec_outbox` и его доставка в 1С,
 * ежедневная сверка QR. Банк `[НЕ ПОДТВЕРЖДЕНО: Q-381]` — проверяется наш порт, а не протокол настоящего банка.
 */
describe('payments: QR банка через наш сервер (ADR-123)', () => {
  const t = new PaymentsTestApp();
  let a: Actors;
  let secretsDir: string;
  let bank: SandboxBankQrApi;

  beforeAll(async () => {
    secretsDir = mkdtempSync(join(tmpdir(), 'pos-bank-secrets-'));
    const secretFile = join(secretsDir, 'qr_webhook_secret');
    writeFileSync(secretFile, SECRET, { mode: 0o600 });
    await t.startPayments({
      env: {
        QR_PROVIDER: 'bank',
        BANK_QR_ADAPTER: 'sandbox',
        QR_WEBHOOK_ENABLED: 'true',
        QR_WEBHOOK_SECRET_FILE: secretFile,
        // supertest ходит с петлевого адреса; песочница доставляет вебхук «с» 127.0.0.1.
        QR_WEBHOOK_ALLOWED_IPS: '127.0.0.1,::1',
      },
      jobs: false,
      modulesFor: (c) => [BankQrHttpModule.forRoot(c)],
    });
    // Документ оплаты ставится через порт ONEC_OUTBOX_WRITER (в приложении его привязывает модуль orders).
    t.replacePort(ONEC_OUTBOX_WRITER, new OnecOutboxWriterService());
    a = await t.actors();
    t.notifications.roleMembers.set('cashier', [a.cashier.userId]);
    t.notifications.roleMembers.set('admin', [a.admin.userId]);
    bank = t.app.get<SandboxBankQrApi>(BANK_QR_API, { strict: false });
  });
  afterAll(async () => {
    await t.stop();
    rmSync(secretsDir, { recursive: true, force: true });
  });

  async function qrOrder() {
    const o = await t.seedOrder({ createdBy: a.seller, method: 'qr_bakai', status: 'awaiting_payment' });
    const res = await t.pay(a.cashier, o.orderId, { method: 'qr_bakai' });
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('qr_shown');
    return { ...o, ref: res.body.qr.bankReference as string, qr: res.body.qr as Record<string, unknown> };
  }

  function webhook(event: Record<string, unknown>, opts: { secret?: string; ip?: string; tsShift?: number } = {}) {
    const raw = JSON.stringify(event);
    const ts = String(Math.floor((Date.now() + (opts.tsShift ?? 0)) / 1000));
    let r = request(t.app.getHttpServer())
      .post('/api/v1/payments/qr/webhook')
      .set('Content-Type', 'application/json')
      .set('X-Timestamp', ts)
      .set('X-Signature', signWebhook(opts.secret ?? SECRET, ts, raw));
    if (opts.ip) r = r.set('X-Forwarded-For', opts.ip);
    return r.send(raw);
  }

  function event(ref: string, amount: string, extra: Record<string, unknown> = {}) {
    return {
      eventId: `evt-${randomUUID()}`,
      eventType: 'payment.succeeded',
      reference: ref,
      operationId: `OP-${randomUUID().slice(0, 8)}`,
      amount,
      currency: 'KGS',
      paidAt: new Date().toISOString(),
      ...extra,
    };
  }

  async function outboxOf(paymentId: string) {
    return t.q<{
      id: string;
      status: string;
      operation: string;
      payload: Record<string, unknown>;
      depends_on_outbox_id: string | null;
    }>(
      `SELECT id, status::text AS status, operation, payload, depends_on_outbox_id FROM onec_outbox
        WHERE aggregate_type = 'payment' AND aggregate_id = $1`,
      [paymentId],
    );
  }

  // 12: T-PAY-012 (динамический QR банка), T-PAY-014 (автоотметка по вебхуку), T-PAY-019 (один документ поступления), T-PAY-047 (e2e заказ → QR → вебхук → received → onec_outbox → 1С)
  it('T-PAY-047: заказ → QR банка → оплата в песочнице → подписанный вебхук → received → payments-create в onec_outbox → 1С (фикстуры)', async () => {
    const o = await qrOrder();
    expect(o.qr).toMatchObject({ provider: 'bakai', autoConfirm: true, amount: { amount: o.total } });
    expect(String(o.qr.payload)).toMatch(/^SANDBOX-QR\|/);
    expect((await t.payment(o.paymentId)).qr_provider).toBe('bakai');
    // Методы QR 1С при QR_PROVIDER=bank не вызываются (ADR-123 п. 6).
    expect(t.onec.callsOf('createQrPayment')).toHaveLength(0);
    // Заказ уже в очереди в 1С: документ оплаты зависит от него (05 SYNC-042).
    const orderOutbox = await t.q<{ id: string; status: string }>(
      `SELECT id, status::text AS status FROM onec_outbox
        WHERE aggregate_type = 'order' AND aggregate_id = $1 AND operation = 'create'`,
      [o.orderId],
    );
    expect(orderOutbox).toHaveLength(1);

    const pay = await t.req('post', `/sandbox/bank/qr/${o.ref}/pay`, a.cashier).send({});
    expect(pay.status).toBe(200);
    expect(pay.body).toMatchObject({
      operation: { reference: o.ref, amount: { amount: o.total, currency: 'KGS' } },
      webhook: { delivered: true, httpStatus: 200, result: 'received' },
    });
    const p = await t.payment(o.paymentId);
    expect(p).toMatchObject({
      status: 'received',
      bank_reference: pay.body.operation.operationId,
      review_reason: null,
    });
    expect((await t.transactionsOf(o.paymentId)).map((x) => x.kind)).toContain('payment_received');
    expect(await t.auditRows('payment.webhook_received', o.paymentId)).toHaveLength(1);
    const ev = await t.q<{ payment_id: string; signature_valid: boolean; processed_at: Date | null }>(
      `SELECT payment_id, signature_valid, processed_at FROM payment_webhook_events WHERE payment_id = $1`,
      [o.paymentId],
    );
    expect(ev).toHaveLength(1);
    expect(ev[0]).toMatchObject({ signature_valid: true });
    expect(ev[0].processed_at).not.toBeNull();

    const ob = await outboxOf(o.paymentId);
    expect(ob).toHaveLength(1);
    expect(ob[0]).toMatchObject({ status: 'pending', operation: 'create', depends_on_outbox_id: orderOutbox[0].id });
    expect(ob[0].payload).toMatchObject({
      externalId: o.paymentId,
      kind: 'qr_bakai',
      amount: o.total,
      currency: 'KGS',
      orderExternalId: o.orderId,
      cashierUserCode: 'system',
      post: true,
      bankReference: pay.body.operation.operationId,
      allocations: [],
    });
    expect(String(ob[0].payload.receivedAt)).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+06:00$/);

    // Доставка outbox → 1С (фикстуры): `POST /pos/v1/payments` по контракту 1С, строка → sent.
    const cfg = schedulerConfigFromEnv(t.config).outbox;
    const dispatcher = new OutboxDispatcher(
      t.pool,
      new OnecOutboxDelivery(t.onec, { timeoutMs: 5000 }),
      { send: () => Promise.resolve(randomUUID()) },
      cfg,
      'worker-bank',
      pino({ level: 'silent' }),
    );
    await dispatcher.tick();
    const calls = t.onec.callsOf('createPayment');
    expect(calls).toHaveLength(1);
    const sent = calls[0][0] as Record<string, unknown>;
    expect(sent).toMatchObject({ externalId: o.paymentId, kind: 'qr_bakai', amount: o.total });
    expect(contractErrors('PaymentCreateRequest', sent)).toEqual([]);
    expect((await outboxOf(o.paymentId))[0].status).toBe('sent');

    // Повтор того же события (банк повторяет доставку) — 200 без побочных эффектов.
    const evBody = await t.q<{ payload: Record<string, unknown> }>(
      `SELECT payload FROM payment_webhook_events WHERE payment_id = $1`,
      [o.paymentId],
    );
    const again = await webhook({ ...evBody[0].payload, payer: { masked: '***' } });
    expect(again.status).toBe(200);
    expect(again.body).toEqual({ received: true });
    expect(await outboxOf(o.paymentId)).toHaveLength(1);
    expect(await t.auditRows('payment.webhook_received', o.paymentId)).toHaveLength(1);
    expect((await t.transactionsOf(o.paymentId)).filter((x) => x.kind === 'payment_received')).toHaveLength(1);
  });

  // 12: T-PAY-014 (повтор вебхука — одна запись; неверная подпись → 401, платёж не меняется), T-PAY-044 (IP вне allowlist → 403)
  it('T-PAY-014: неверная подпись → 401 WEBHOOK_SIGNATURE_INVALID, платёж не меняется; T-PAY-044: IP вне allowlist → 403', async () => {
    const o = await qrOrder();
    const ev = event(o.ref, o.total);
    let res = await webhook(ev, { secret: randomBytes(24).toString('hex') });
    expect(res.status).toBe(401);
    expect(res.body.code).toBe('WEBHOOK_SIGNATURE_INVALID');
    res = await webhook(ev, { tsShift: -10 * 60_000 });
    expect(res.status).toBe(401);
    // Подписано одно тело — отправлено другое (сумма изменена): подпись по сырому телу не сходится.
    const ts = String(Math.floor(Date.now() / 1000));
    res = await request(t.app.getHttpServer())
      .post('/api/v1/payments/qr/webhook')
      .set('Content-Type', 'application/json')
      .set('X-Timestamp', ts)
      .set('X-Signature', signWebhook(SECRET, ts, JSON.stringify(ev)))
      .send(JSON.stringify({ ...ev, amount: '1.00' }));
    expect(res.status).toBe(401);
    res = await webhook(ev, { ip: '203.0.113.9' });
    expect(res.status).toBe(403);
    expect(res.body.code).toBe('FORBIDDEN');
    expect(await t.payment(o.paymentId)).toMatchObject({ status: 'qr_shown', bank_reference: null });
    expect((await t.auditRows('payment.webhook_rejected')).length).toBeGreaterThanOrEqual(4);
    // Отклонённое по подписи событие не занимает eventId: настоящее событие с тем же eventId принимается.
    res = await webhook(ev);
    expect(res.status).toBe(200);
    expect((await t.payment(o.paymentId)).status).toBe('received');
  });

  // 12: T-PAY-015 (частичная сумма → manual_confirm amount_mismatch), T-PAY-017 (ручное подтверждение без step-up → 403)
  it('T-PAY-015: частичная оплата → manual_confirm (amount_mismatch), документа в 1С нет; confirm-manual без step-up → 403, со step-up → received и документ', async () => {
    const o = await qrOrder();
    const part = (Number(o.total) - 1).toFixed(2); // money-double: allow — тестовая сумма на 1 сом меньше
    const pay = await t.req('post', `/sandbox/bank/qr/${o.ref}/pay`, a.cashier).send({ amount: part });
    expect(pay.body.webhook).toMatchObject({ delivered: true, result: 'manual_confirm:amount_mismatch' });
    expect(await t.payment(o.paymentId)).toMatchObject({
      status: 'manual_confirm',
      review_reason: 'amount_mismatch',
      bank_amount: part,
    });
    expect(await outboxOf(o.paymentId)).toHaveLength(0);
    const body = {
      bankReference: pay.body.operation.operationId,
      receivedAmount: { amount: o.total, currency: 'KGS' },
      comment: 'доплата наличными',
    };
    let res = await t.req('post', `/payments/${o.paymentId}/confirm-manual`, a.cashier, { idem: true }).send(body);
    expect(res.status).toBe(403);
    expect(res.body.code).toBe('STEP_UP_REQUIRED');
    expect((await t.payment(o.paymentId)).status).toBe('manual_confirm');
    const stepUp = await t.stepUp(a.cashier, 'payment.qr.confirm_manual');
    res = await t.req('post', `/payments/${o.paymentId}/confirm-manual`, a.cashier, { idem: true, stepUp }).send(body);
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('received');
    const ob = await outboxOf(o.paymentId);
    expect(ob).toHaveLength(1);
    expect(ob[0].payload).toMatchObject({ kind: 'qr_bakai', cashierUserCode: a.cashier.userId });
  });

  // 12: T-PAY-016 (оплата после истечения QR → late_payment), T-PAY-045 (неизвестный референс)
  it('T-PAY-016: оплата после истечения QR → qr_expired → manual_confirm (late_payment); T-PAY-045: неизвестный референс → 200 unknown_reference', async () => {
    const o = await qrOrder();
    await t.forcePayment(o.paymentId, { qr_expires_at: new Date(Date.now() - 60_000) });
    expect(await t.qrStatus.expireDue()).toBeGreaterThanOrEqual(1);
    expect((await t.payment(o.paymentId)).status).toBe('qr_expired');
    let res = await webhook(event(o.ref, o.total));
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ received: true });
    expect(await t.payment(o.paymentId)).toMatchObject({ status: 'manual_confirm', review_reason: 'late_payment' });
    expect(await outboxOf(o.paymentId)).toHaveLength(0);

    const unknown = event('SBX-NOSUCHREF', '100.00');
    res = await webhook(unknown);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ received: true, status: 'unknown_reference' });
    const row = await t.q<{ payment_id: string | null; processing_error: string | null }>(
      `SELECT payment_id, processing_error FROM payment_webhook_events WHERE provider_event_id = $1`,
      [unknown.eventId],
    );
    expect(row).toEqual([{ payment_id: null, processing_error: 'unknown_reference' }]);
    // Повтор неизвестного события — тот же ответ, без второй строки.
    res = await webhook(unknown);
    expect(res.body).toEqual({ received: true, status: 'unknown_reference' });
    // 08 §6 «Сопоставление» (POS-053): уведомление кассирам и администраторам (system), по одному на операцию.
    for (const user of [a.cashier, a.admin]) {
      const n = t.notifications
        .of(user.userId)
        .filter((x) => x.dedupeKey.startsWith(`qr_unknown_reference:${unknown.operationId}`));
      expect(n).toHaveLength(1);
      expect(n[0]).toMatchObject({ kind: 'system', severity: 'warning', payload: { target: null } });
    }
    // Отчёт сверки (08 §4.18.8): строка unknownOperations при status=unmatched; при manual — пусто.
    const reports = new AdminReportsService(
      t.db,
      t.config,
      t.app.get<Clock>(CLOCK, { strict: false }),
      t.app.get(SettingsReader, { strict: false }),
    );
    const period = { from: new Date(Date.now() - 3600_000), to: new Date(Date.now() + 60_000) };
    const report = (await reports.qrReconciliation(period, 'unmatched')) as {
      unknownOperations: { operationId: string | null }[];
      summary: { unknownReference: number };
    };
    expect(report.unknownOperations).toContainEqual(
      expect.objectContaining({
        operationId: unknown.operationId,
        reference: 'SBX-NOSUCHREF',
        amount: { amount: '100.00', currency: 'KGS' },
        source: 'webhook',
      }),
    );
    expect(report.summary.unknownReference).toBe(report.unknownOperations.length);
    const manualOnly = (await reports.qrReconciliation(period, 'manual')) as { unknownOperations: unknown[] };
    expect(manualOnly.unknownOperations).toEqual([]);
  });

  // 12: T-PAY-046 (ежедневная сверка QR), T-PAY-020 (сверка: операции банка против платежей)
  it('T-PAY-046: сверка дня — оплата без вебхука применяется (received + документ), повтор сверки без дублей', async () => {
    const o = await qrOrder();
    // Банк зачислил деньги, но вебхук не дошёл (оплата в песочнице без доставки).
    const op = bank.pay({ reference: o.ref }).operation;
    expect((await t.payment(o.paymentId)).status).toBe('qr_shown');
    const day = new Date(Date.now() + 6 * 3600_000).toISOString().slice(0, 10);
    const recon = t.app.get(QrReconciliationService, { strict: false });
    const first = await recon.reconcileDay(day);
    expect(first.bankOperations).toBeGreaterThanOrEqual(1);
    expect(first.discrepancies).toContainEqual(
      expect.objectContaining({ kind: 'applied_late', paymentId: o.paymentId, operationId: op.operationId }),
    );
    expect(await t.payment(o.paymentId)).toMatchObject({ status: 'received', bank_reference: op.operationId });
    expect(await outboxOf(o.paymentId)).toHaveLength(1);
    const second = await recon.reconcileDay(day);
    expect(second.applied).toBe(0);
    expect(second.discrepancies.filter((d) => d.paymentId === o.paymentId)).toEqual([]);
    expect(await outboxOf(o.paymentId)).toHaveLength(1);
    expect((await t.transactionsOf(o.paymentId)).filter((x) => x.kind === 'payment_received')).toHaveLength(1);
  });

  // 12: T-PAY-020 (сверка: вторая операция банка по одному платежу — расхождение)
  it('T-PAY-020: сверка — две операции по одному платежу (прежний и новый референс QR) → duplicate_payment, уведомление; ручной QR без операции — не missing_in_bank', async () => {
    const o = await qrOrder();
    // Прежний референс (до перевыпуска) — в истории; покупатель оплатил и прежний, и новый QR.
    const oldRef = `SBX-OLD-${randomUUID().slice(0, 8)}`;
    await t.forcePayment(o.paymentId, { qr_ref_history: [oldRef] });
    const pay = await t.req('post', `/sandbox/bank/qr/${o.ref}/pay`, a.cashier).send({});
    expect(pay.body.webhook).toMatchObject({ delivered: true, result: 'received' });
    // Вебхук по второй операции не дошёл — её видит только выписка банка.
    const dup = {
      operationId: `SBX-OP-DUP-${randomUUID().slice(0, 8)}`,
      reference: oldRef,
      merchantPaymentId: o.paymentId,
      merchantOrderId: null,
      amount: o.total,
      currency: 'KGS' as const,
      paidAt: new Date().toISOString(),
    };
    const real = bank.listOperations.bind(bank);
    const spy = vi.spyOn(bank, 'listOperations').mockImplementation(async (day) => [...(await real(day)), dup]);
    // Ручное подтверждение без динамического QR (статический QR / manualOnly): операции банка нет — не расхождение.
    const manual = await qrOrder();
    await t.forcePayment(manual.paymentId, {
      status: 'received',
      qr_provider_ref: null,
      received_at: new Date(),
      bank_reference: 'выписка-1',
    });
    const day = new Date(Date.now() + 6 * 3600_000).toISOString().slice(0, 10);
    const recon = t.app.get(QrReconciliationService, { strict: false });
    const titled = (userId: string) =>
      t.notifications.of(userId).filter((n) => n.title === 'Сверка QR: повторная оплата');
    try {
      const first = await recon.reconcileDay(day);
      expect(first.discrepancies.filter((d) => d.paymentId === o.paymentId)).toEqual([
        expect.objectContaining({ kind: 'duplicate_payment', operationId: dup.operationId, reference: oldRef }),
      ]);
      expect(first.discrepancies.filter((d) => d.paymentId === manual.paymentId)).toEqual([]);
      expect(first.manualWithoutBankQr).toBeGreaterThanOrEqual(1);
      const row = await t.q<{ payment_id: string; processing_error: string }>(
        `SELECT payment_id, processing_error FROM payment_webhook_events WHERE provider_event_id = $1`,
        [`recon:${dup.operationId}`],
      );
      expect(row).toEqual([{ payment_id: o.paymentId, processing_error: 'duplicate_payment' }]);
      expect(titled(a.admin.userId)).toHaveLength(1);
      expect(titled(a.cashier.userId)).toHaveLength(1);
      expect(
        t.notifications
          .of(a.admin.userId)
          .filter((n) => (n.payload as { paymentId?: string } | undefined)?.paymentId === manual.paymentId),
      ).toEqual([]);
      // Повтор сверки: расхождение снова в итоге, уведомление не дублируется, платёж не меняется.
      const second = await recon.reconcileDay(day);
      expect(second.discrepancies.filter((d) => d.paymentId === o.paymentId).map((d) => d.kind)).toEqual([
        'duplicate_payment',
      ]);
      expect(titled(a.admin.userId)).toHaveLength(1);
      expect(await t.payment(o.paymentId)).toMatchObject({
        status: 'received',
        bank_reference: pay.body.operation.operationId,
      });
    } finally {
      spy.mockRestore();
    }
  });

  // 12: T-PAY-044 (RL-WEBHOOK: 600/мин с IP → 429)
  it('T-PAY-044: RL-WEBHOOK — лимит запросов с одного IP исчерпан → 429 RATE_LIMITED до проверки IP и подписи', async () => {
    const ip = '198.51.100.77';
    // Счётчик текущего и следующего окна заполнен (граница минуты во время теста не влияет).
    const minute = Math.floor(Date.now() / 60_000) * 60_000;
    for (const start of [minute, minute + 60_000]) {
      await t.pool.query(
        `INSERT INTO rate_limit_counters (scope, subject, window_start, count, window_end)
         VALUES ('webhook_ip_1m', $1, $2, 600, $3)
         ON CONFLICT (scope, subject, window_start) DO UPDATE SET count = 600`,
        [ip, new Date(start), new Date(start + 60_000)],
      );
    }
    const before = (await t.auditRows('payment.webhook_rejected')).length;
    const res = await webhook(event('SBX-ANY', '1.00'), { ip });
    expect(res.status).toBe(429);
    expect(res.body.code).toBe('RATE_LIMITED');
    expect(res.headers['retry-after']).toBeDefined();
    // Отказ по лимиту журнал и аудит не растит.
    expect((await t.auditRows('payment.webhook_rejected')).length).toBe(before);
  });

  // 12: T-PAY-047 (документ оплаты в 1С: ссылка 1С уже у другого платежа)
  it('T-PAY-047: payments.onec-confirmed — Ref 1С уже у другого платежа → ref_conflict, sync_errors и уведомление; фикстуры дают Ref по externalId', async () => {
    const p1 = await qrOrder();
    const p2 = await qrOrder();
    for (const o of [p1, p2]) {
      const pay = await t.req('post', `/sandbox/bank/qr/${o.ref}/pay`, a.cashier).send({});
      expect(pay.body.webhook).toMatchObject({ result: 'received' });
    }
    const ob1 = (await outboxOf(p1.paymentId))[0];
    const ob2 = (await outboxOf(p2.paymentId))[0];
    const doc = t.app.get(PaymentOnecDocument, { strict: false });
    const ref = randomUUID();
    const base = { onecNumber: 'ПКО0-000731', onecStatus: null, attempt: 1 };
    const confirm = (outboxId: string, aggregateId: string) =>
      doc.onConfirmed({ ...base, outboxId, aggregateId, onecRef: ref });
    expect(await confirm(ob1.id, p1.paymentId)).toBe('linked');
    expect(await confirm(ob1.id, p1.paymentId)).toBe('unchanged');
    expect(await confirm(ob2.id, p2.paymentId)).toBe('ref_conflict');
    expect(await confirm(ob2.id, p2.paymentId)).toBe('ref_conflict');
    const errs = await t.q<{ error_code: string; payload: Record<string, unknown> }>(
      `SELECT error_code, payload FROM sync_errors WHERE local_id = $1 AND entity = 'payment_docs'`,
      [p2.paymentId],
    );
    expect(errs).toHaveLength(1);
    expect(errs[0]).toMatchObject({
      error_code: 'DUPLICATE_SUSPECTED',
      payload: { code: 'ONEC_REF_CONFLICT', otherPaymentId: p1.paymentId },
    });
    expect(
      t.notifications
        .of(a.admin.userId)
        .filter((n) => n.dedupeKey.startsWith(`payment_status:${p2.paymentId}:onec_ref_conflict`)),
    ).toHaveLength(1);
    const p2row = await t.q<{ onec_ref: string | null }>(`SELECT onec_ref FROM payments WHERE id = $1`, [p2.paymentId]);
    expect(p2row).toEqual([{ onec_ref: null }]);
    // Стенд с фикстурами 1С: разные платежи — разные документы, повтор — тот же Ref.
    const r1 = await t.onec.createPayment({ externalId: p1.paymentId });
    const r2 = await t.onec.createPayment({ externalId: p2.paymentId });
    const r1again = await t.onec.createPayment({ externalId: p1.paymentId });
    expect(r1.body.ref).not.toBe(r2.body.ref);
    expect(r1again.body.ref).toBe(r1.body.ref);
    expect(r1.body.ref).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  // 12: T-PAY-048 (служебные маршруты песочницы: права и ошибки), T-PAY-043 (features.qrWebhook по факту)
  it('T-PAY-048: песочница — только с правом payment.qr.confirm_manual; неизвестный референс → 404; повторная оплата → 422', async () => {
    const o = await qrOrder();
    let res = await t.req('post', `/sandbox/bank/qr/${o.ref}/pay`, a.seller).send({});
    expect(res.status).toBe(403);
    res = await t.req('post', '/sandbox/bank/qr/SBX-NOPE/pay', a.cashier).send({});
    expect(res.status).toBe(404);
    res = await t.req('post', `/sandbox/bank/qr/${o.ref}/pay`, a.cashier).send({ amount: '1.5' });
    expect(res.status).toBe(400);
    res = await t.req('post', `/sandbox/bank/qr/${o.ref}/pay`, a.cashier).send({});
    expect(res.status).toBe(200);
    res = await t.req('post', `/sandbox/bank/qr/${o.ref}/pay`, a.cashier).send({});
    expect(res.status).toBe(422);
    res = await t.req('get', '/sandbox/bank/operations', a.owner);
    expect(res.status).toBe(200);
    expect((res.body.items as { reference: string }[]).map((x) => x.reference)).toContain(o.ref);
    res = await t.req('get', '/sandbox/bank/operations?day=24.11.2026', a.owner);
    expect(res.status).toBe(400);
    // Без песочницы в процессе задачи банка исполняет этот процесс (pos-api): опрос и сверка — здесь.
    expect(t.app.get(PaymentsJobsBridge, { strict: false }).jobGroups()).toMatchObject({ poll: true, reconcile: true });
  });
});

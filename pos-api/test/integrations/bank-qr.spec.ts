import { randomBytes } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { ConfigError, configWarnings, loadAppConfig } from '../../src/common/config/app-config.js';
import { qrProviderCode } from '../../src/common/config/qr-provider.js';
import { jsonBodyType } from '../../src/common/http/raw-body.js';
import { BankApiError } from '../../src/integrations/payments/bank/bank-qr-api.js';
import { SandboxBankQrApi } from '../../src/integrations/payments/bank/sandbox-bank-qr.api.js';
import {
  signWebhook,
  verifyWebhookSignature,
  WEBHOOK_SIGNATURE_HEADER,
  WEBHOOK_TIMESTAMP_HEADER,
} from '../../src/integrations/payments/bank/webhook-signature.js';
import { BankQrProvider } from '../../src/integrations/payments/bank-qr.provider.js';
import { createBankQrApi, createPaymentProvider } from '../../src/integrations/payments/payment-provider.factory.js';
import { QrProviderUnavailableError } from '../../src/integrations/payments/payment-provider.js';
import { BankSandboxController } from '../../src/payments/bank/bank-sandbox.controller.js';
import { bankQrControllers } from '../../src/payments/bank/bank-qr-http.module.js';
import { BankWebhookController } from '../../src/payments/bank/bank-webhook.controller.js';
import { parseEvent } from '../../src/payments/bank/bank-webhook.service.js';
import { previousBishkekDay } from '../../src/payments/bank/qr-reconciliation.service.js';
import { PaymentsJobsBridge } from '../../src/payments/jobs/payments-jobs.bridge.js';
import type { QrStatusService } from '../../src/payments/qr/qr-status.service.js';
import { TEST_ENV } from '../support/test-app.js';

/**
 * QR банка через наш сервер (ADR-123, P-004) — модульные проверки без БД: конфигурация и отказ в старте, синоним
 * `bakai`, песочница банка (**тестовая реализация**, не API банка), подпись вебхука, адаптер `BankQrProvider`, выбор
 * маршрутов и задач по конфигурации. Тестовые данные; банк `[НЕ ПОДТВЕРЖДЕНО: Q-381]`.
 */
/** Ключ подписи вебхука — случайное тестовое значение на прогон. */
const SECRET = randomBytes(24).toString('hex');

function config(env: Record<string, string>) {
  return loadAppConfig({ ...TEST_ENV, ...env });
}

function problems(env: Record<string, string>): string {
  try {
    config(env);
  } catch (e) {
    if (e instanceof ConfigError) return e.problems.join('\n');
    throw e;
  }
  return '';
}

describe('ADR-123: конфигурация QR банка (16 §4.3; 11 SEC-135)', () => {
  // 12: T-PAY-043 (синоним bakai и отказ в старте)
  it('T-PAY-043: QR_PROVIDER=bakai — устаревший синоним: внутри bank, предупреждение при старте; коды хранения — bakai', () => {
    const c = config({ QR_PROVIDER: 'bakai' });
    expect(c.QR_PROVIDER).toBe('bank');
    expect(qrProviderCode(c.QR_PROVIDER)).toBe('bakai');
    expect(configWarnings({ QR_PROVIDER: 'bakai' })).toEqual([expect.stringContaining('устаревшее значение')]);
    expect(configWarnings({ QR_PROVIDER: 'bank' })).toEqual([]);
    expect(config({ QR_PROVIDER: 'bank' }).QR_PROVIDER).toBe('bank');
    expect(config({}).BANK_QR_ADAPTER).toBe('sandbox');
    expect(configWarnings({ QR_PROVIDER: 'bank', BANK_QR_MERCHANT_ID: 'M-1' }).join(' ')).toMatch(
      /не используются песочницей/,
    );
    expect(qrProviderCode('onec')).toBe('onec');
    expect(qrProviderCode('none')).toBe('none');
  });

  it('T-PAY-043: QR_WEBHOOK_ENABLED=true без секрета подписи → отказ в старте; при onec/none — отказ', () => {
    expect(problems({ QR_PROVIDER: 'bank', QR_WEBHOOK_ENABLED: 'true', QR_WEBHOOK_ALLOWED_IPS: '127.0.0.1' })).toMatch(
      /QR_WEBHOOK_SECRET/,
    );
    expect(
      problems({
        QR_PROVIDER: 'onec',
        QR_WEBHOOK_ENABLED: 'true',
        QR_WEBHOOK_SECRET: SECRET,
        QR_WEBHOOK_ALLOWED_IPS: '127.0.0.1',
      }),
    ).toMatch(/QR_WEBHOOK_ENABLED: true допустимо только при QR_PROVIDER=bank/);
    expect(problems({ QR_PROVIDER: 'bank', QR_WEBHOOK_ENABLED: 'true', QR_WEBHOOK_SECRET: SECRET })).toMatch(
      /QR_WEBHOOK_ALLOWED_IPS/,
    );
    expect(
      problems({
        QR_PROVIDER: 'bank',
        QR_WEBHOOK_ENABLED: 'true',
        QR_WEBHOOK_SECRET: SECRET,
        QR_WEBHOOK_ALLOWED_IPS: '127.0.0.1, 10.0.0.0/33',
      }),
    ).toMatch(/QR_WEBHOOK_ALLOWED_IPS/);
    expect(
      problems({
        QR_PROVIDER: 'bakai',
        QR_WEBHOOK_ENABLED: 'true',
        QR_WEBHOOK_SECRET: SECRET,
        QR_WEBHOOK_ALLOWED_IPS: '127.0.0.1, 203.0.113.0/24, ::1',
      }),
    ).toBe('');
  });

  it('T-PAY-043: APP_ENV=prod и BANK_QR_ADAPTER=sandbox → отказ в старте (схема env и фабрика)', () => {
    const prodEnv = {
      APP_ENV: 'prod',
      PUBLIC_BASE_URL: 'https://api.example.kg',
      ONEC_MODE: 'extension',
      SMS_PROVIDER: 'smspro',
      QR_PROVIDER: 'bank',
    };
    expect(problems(prodEnv)).toMatch(/BANK_QR_ADAPTER: sandbox \(песочница банка\) запрещён при APP_ENV=prod/);
    expect(() => createBankQrApi({ QR_PROVIDER: 'bank', APP_ENV: 'prod', BANK_QR_ADAPTER: 'sandbox' })).toThrow(
      ConfigError,
    );
    expect(() =>
      createPaymentProvider(
        { QR_PROVIDER: 'bank', ONEC_MODE: 'extension', ONEC_INBOUND_ENABLED: false, APP_ENV: 'prod' },
        { bankApi: new SandboxBankQrApi() },
      ),
    ).toThrow(ConfigError);
    expect(createBankQrApi({ QR_PROVIDER: 'onec' })).toBeNull();
    const api = createBankQrApi({ QR_PROVIDER: 'bank', APP_ENV: 'staging', BANK_QR_ADAPTER: 'sandbox' });
    expect(api).toBeInstanceOf(SandboxBankQrApi);
    expect(
      createPaymentProvider(
        { QR_PROVIDER: 'bank', ONEC_MODE: 'fixtures', ONEC_INBOUND_ENABLED: false },
        { bankApi: api },
      ),
    ).toBeInstanceOf(BankQrProvider);
  });

  it('маршруты банка регистрируются только при флагах: вебхук — bank + QR_WEBHOOK_ENABLED; песочница — sandbox и не prod', () => {
    const base = {
      QR_PROVIDER: 'bank',
      QR_WEBHOOK_ENABLED: true,
      BANK_QR_ADAPTER: 'sandbox',
      APP_ENV: 'staging',
    } as const;
    expect(bankQrControllers(base)).toEqual([BankWebhookController, BankSandboxController]);
    expect(bankQrControllers({ ...base, QR_WEBHOOK_ENABLED: false })).toEqual([BankSandboxController]);
    expect(bankQrControllers({ ...base, APP_ENV: 'prod' })).toEqual([BankWebhookController]);
    expect(bankQrControllers({ ...base, QR_PROVIDER: 'onec' })).toEqual([]);
    expect(bankQrControllers({ ...base, QR_PROVIDER: 'none' })).toEqual([]);
  });

  it('задачи банка при песочнице исполняет pos-api (песочница в его памяти), pos-worker их не берёт', () => {
    const qr = {} as QrStatusService;
    const bridge = (env: Record<string, string>, role: 'api' | 'worker') =>
      new PaymentsJobsBridge(config(env), qr, undefined, undefined, role).jobGroups();
    expect(bridge({ QR_PROVIDER: 'bank' }, 'api')).toEqual({ core: false, poll: true, reconcile: true });
    expect(bridge({ QR_PROVIDER: 'bank', WORKERS_ENABLED: 'true' }, 'worker')).toEqual({
      core: true,
      poll: false,
      reconcile: false,
    });
    // Прежнее поведение при onec: всё — у процесса с WORKERS_ENABLED=true.
    expect(bridge({ QR_PROVIDER: 'onec', WORKERS_ENABLED: 'true' }, 'worker')).toEqual({
      core: true,
      poll: true,
      reconcile: false,
    });
    expect(bridge({ QR_PROVIDER: 'onec' }, 'api')).toEqual({ core: false, poll: false, reconcile: false });
  });

  it('сырое тело вебхука не разбирается общим JSON-парсером (подпись — по байтам)', () => {
    const h = { 'content-type': 'application/json; charset=utf-8' };
    expect(jsonBodyType({ headers: h, originalUrl: '/api/v1/payments/qr/webhook' })).toBe(false);
    expect(jsonBodyType({ headers: h, originalUrl: '/api/v1/orders?x=1' })).toBe(true);
    expect(jsonBodyType({ headers: { 'content-type': 'text/xml' }, originalUrl: '/api/v1/orders' })).toBe(false);
  });
});

describe('ADR-123: подпись вебхука (08 §6, вариант (а)) и тело события', () => {
  const body = Buffer.from('{"eventId":"evt-1","amount":"10.00"}');
  const now = Date.parse('2026-11-24T10:00:00Z');
  const ts = String(now / 1000);

  // 12: T-PAY-014 (неверная подпись), T-SEC класса A — подпись по сырому телу
  it('T-PAY-014: HMAC-SHA256(secret, timestamp + "." + rawBody): верная — ok; изменённое тело, чужой секрет, сдвиг > 5 мин — отказ', () => {
    const sig = signWebhook(SECRET, ts, body);
    const v = (o: Partial<Parameters<typeof verifyWebhookSignature>[0]>) =>
      verifyWebhookSignature({ secret: SECRET, rawBody: body, signature: sig, timestamp: ts, nowMs: now, ...o });
    expect(v({})).toEqual({ ok: true });
    expect(v({ signature: `sha256=${sig.toUpperCase()}` })).toEqual({ ok: true });
    expect(v({ rawBody: Buffer.from('{"eventId":"evt-1","amount":"99.00"}') })).toEqual({
      ok: false,
      reason: 'mismatch',
    });
    // Тот же JSON с другими пробелами — другие байты: подпись по разобранному JSON не принималась бы.
    expect(v({ rawBody: Buffer.from('{"eventId": "evt-1","amount":"10.00"}') })).toEqual({
      ok: false,
      reason: 'mismatch',
    });
    expect(v({ secret: randomBytes(24).toString('hex') })).toEqual({ ok: false, reason: 'mismatch' });
    expect(v({ nowMs: now + 5 * 60_000 + 1000 })).toEqual({ ok: false, reason: 'timestamp_skew' });
    expect(v({ nowMs: now - 5 * 60_000 + 1000 })).toEqual({ ok: true });
    expect(v({ signature: undefined })).toEqual({ ok: false, reason: 'missing' });
    expect(v({ timestamp: 'вчера' })).toEqual({ ok: false, reason: 'timestamp_format' });
    expect(
      v({ timestamp: new Date(now).toISOString(), signature: signWebhook(SECRET, new Date(now).toISOString(), body) }),
    ).toEqual({ ok: true });
  });

  it('тело события: обязательные поля, сумма строкой с двумя знаками, только KGS; лишнее — без ПДн', () => {
    const ok = parseEvent(
      Buffer.from(
        JSON.stringify({
          eventId: 'evt-1',
          eventType: 'payment.succeeded',
          reference: 'SBX-1',
          amount: '16007.50',
          currency: 'KGS',
          paidAt: '2026-11-24T10:00:00Z',
          payer: { masked: '***' },
        }),
      ),
    );
    expect(ok).toMatchObject({ eventId: 'evt-1', reference: 'SBX-1', amount: '16007.50', operationId: null });
    const bad = (o: Record<string, unknown>) => () =>
      parseEvent(
        Buffer.from(
          JSON.stringify({
            eventId: 'e',
            eventType: 'payment.succeeded',
            reference: 'r',
            amount: '1.00',
            currency: 'KGS',
            ...o,
          }),
        ),
      );
    expect(bad({ amount: '1.5' })).toThrow();
    expect(bad({ currency: 'USD' })).toThrow();
    expect(bad({ eventType: 'refund' })).toThrow();
    expect(bad({ reference: undefined })).toThrow();
    expect(() => parseEvent(Buffer.from('не json'))).toThrow();
  });
});

describe('ADR-123: песочница банка (тестовая реализация) и адаптер BankQrProvider', () => {
  function clock(start: string) {
    let t = Date.parse(start);
    return { now: () => new Date(t), advance: (ms: number) => (t += ms) };
  }
  const REQ = {
    merchantPaymentId: '0192f5a1-4444-7eee-8fff-000000000001',
    merchantOrderId: 'POS-2026-000123',
    amount: '16007.50',
    currency: 'KGS' as const,
    purpose: 'Оплата заказа POS-2026-000123',
    ttlSeconds: 900,
  };

  // 12: T-PAY-012 (динамический QR банка: сумма, срок, перевыпуск на том же платеже)
  it('T-PAY-012: QR с суммой и сроком; повтор при действующем QR — тот же; после истечения — новый референс', async () => {
    const c = clock('2026-11-24T04:00:00Z');
    const bank = new SandboxBankQrApi({ webhookSecret: SECRET, now: c.now });
    const a = await bank.createQr(REQ);
    expect(a).toMatchObject({ amount: '16007.50', expiresAt: '2026-11-24T04:15:00.000Z' });
    expect(a.payload).toMatch(/^SANDBOX-QR\|ref=SBX-/);
    expect((await bank.createQr(REQ)).reference).toBe(a.reference);
    c.advance(16 * 60_000);
    expect((await bank.getStatus(REQ.merchantPaymentId))?.status).toBe('expired');
    const b = await bank.createQr(REQ);
    expect(b.reference).not.toBe(a.reference);
    expect((await bank.cancel(REQ.merchantPaymentId))?.status).toBe('cancelled');
    expect(() => bank.pay({ reference: b.reference })).toThrow(BankApiError);
    expect(await bank.getStatus('нет-такого')).toBeNull();
    await expect(bank.createQr({ ...REQ, amount: '0.00' })).rejects.toBeInstanceOf(BankApiError);
  });

  it('оплата: частичная сумма, отказ по истёкшему QR без allowExpired, операции дня (Бишкек), подписанный вебхук', async () => {
    const c = clock('2026-11-24T17:30:00Z'); // 23:30 в Бишкеке
    const bank = new SandboxBankQrApi({ webhookSecret: SECRET, now: c.now });
    const qr = await bank.createQr(REQ);
    const r = bank.pay({ reference: qr.reference, amount: '16000.00' });
    expect(r.operation).toMatchObject({
      reference: qr.reference,
      amount: '16000.00',
      merchantOrderId: 'POS-2026-000123',
    });
    expect(() => bank.pay({ reference: qr.reference })).toThrow(/уже оплачен/);
    const w = r.webhook;
    expect(w).not.toBeNull();
    if (!w) return;
    const check = verifyWebhookSignature({
      secret: SECRET,
      rawBody: w.rawBody,
      signature: w.headers[WEBHOOK_SIGNATURE_HEADER],
      timestamp: w.headers[WEBHOOK_TIMESTAMP_HEADER],
      nowMs: c.now().getTime(),
    });
    expect(check).toEqual({ ok: true });
    expect(parseEvent(w.rawBody)).toMatchObject({
      eventType: 'payment.succeeded',
      reference: qr.reference,
      amount: '16000.00',
      operationId: r.operation.operationId,
    });
    expect(await bank.listOperations('2026-11-24')).toHaveLength(1);
    expect(await bank.listOperations('2026-11-25')).toHaveLength(0);
    expect((await bank.getStatus(REQ.merchantPaymentId))?.status).toBe('paid');
    // Истёкший QR: без allowExpired — отказ, с allowExpired — поздняя оплата.
    const other = { ...REQ, merchantPaymentId: '0192f5a1-4444-7eee-8fff-000000000002' };
    const late = await bank.createQr(other);
    c.advance(40 * 60_000); // 00:10 25.11 по Бишкеку
    expect(() => bank.pay({ reference: late.reference })).toThrow(/срок QR истёк/);
    expect(bank.pay({ reference: late.reference, allowExpired: true }).operation.amount).toBe('16007.50');
    expect(await bank.listOperations('2026-11-25')).toHaveLength(1);
    expect(new SandboxBankQrApi({ now: c.now }).signedEvent(r.operation)).toBeNull();
  });

  it('BankQrProvider: provider=bakai (исторический код), сумма с сервера, статус paid → референс оплаты и операция банка', async () => {
    const bank = new SandboxBankQrApi({ webhookSecret: SECRET });
    const p = new BankQrProvider(bank);
    const req = {
      paymentId: REQ.merchantPaymentId,
      orderExternalId: '0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a8b',
      orderRef: null,
      customerRef: null,
      orderPublicNumber: 'POS-2026-000123',
      amount: '16007.5',
      currency: 'KGS' as const,
      purpose: 'Оплата заказа POS-2026-000123',
      ttlSeconds: 900,
      cashierUserCode: 'system',
    };
    const issued = await p.issue(req);
    expect(issued).toMatchObject({
      provider: 'bakai',
      amount: '16007.50',
      autoConfirm: true,
      providerStatusRaw: 'pending',
    });
    expect(p.mode).toBe('bank');
    expect((await p.status(REQ.merchantPaymentId)).state).toBe('pending');
    const op = bank.pay({ reference: issued.providerRef ?? '' }).operation;
    expect(await p.status(REQ.merchantPaymentId)).toMatchObject({
      state: 'paid',
      providerRef: issued.providerRef,
      paidAmount: '16007.50',
      bankReference: op.operationId,
    });
    expect((await p.cancel(REQ.merchantPaymentId, 'voided')).state).toBe('paid');
    expect((await p.status('0192f5a1-4444-7eee-8fff-00000000ffff')).state).toBe('unknown');
    const down = new BankQrProvider({
      adapter: 'sandbox',
      createQr: () => Promise.reject(new BankApiError('NET', true, 'сеть')),
      getStatus: () => Promise.reject(new Error('сбой')),
      cancel: () => Promise.resolve(null),
      listOperations: () => Promise.resolve([]),
    });
    await expect(down.issue(req)).rejects.toBeInstanceOf(QrProviderUnavailableError);
    await expect(down.status(req.paymentId)).rejects.toBeInstanceOf(QrProviderUnavailableError);
    expect((await down.cancel(req.paymentId, 'voided')).state).toBe('not_applicable');
  });

  it('сверка — за прошедший день по Бишкеку', () => {
    expect(previousBishkekDay(new Date('2026-11-24T18:30:00Z'))).toBe('2026-11-24'); // 00:30 25.11 в Бишкеке
    expect(previousBishkekDay(new Date('2026-11-24T10:00:00Z'))).toBe('2026-11-23');
  });
});

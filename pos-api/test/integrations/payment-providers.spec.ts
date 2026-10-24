import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ConfigError } from '../../src/common/config/app-config.js';
import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import { ManualQrProvider } from '../../src/integrations/payments/manual-qr.provider.js';
import { OnecQrProvider } from '../../src/integrations/payments/onec-qr.provider.js';
import { createPaymentProvider } from '../../src/integrations/payments/payment-provider.factory.js';
import {
  PAYMENT_PROVIDER,
  type PaymentProvider,
  type QrIssueRequest,
  QrProviderRejectedError,
  QrProviderUnavailableError,
} from '../../src/integrations/payments/payment-provider.js';
import { Test } from '@nestjs/testing';
import { ConfigModule } from '../../src/common/config/config.module.js';
import { PG_POOL } from '../../src/common/db/database.module.js';
import { ONEC_GATEWAY } from '../../src/integrations/onec/onec-gateway.js';
import { OnecGatewayModule } from '../../src/integrations/onec/onec.module.js';
import { PaymentProviderModule } from '../../src/integrations/payments/payment-provider.module.js';
import { SMS_GATEWAY, type SmsGateway } from '../../src/integrations/sms/sms-gateway.js';
import { SmsGatewayModule } from '../../src/integrations/sms/sms.module.js';
import { Global, Module } from '@nestjs/common';
import { testConfig } from '../support/test-app.js';
import { FakeSmsGateway } from '../../src/integrations/sms/fake-sms.gateway.js';

describe('Nest-модули портов (DI): SmsGatewayModule, OnecGatewayModule, PaymentProviderModule', () => {
  it('ONEC_MODE=fixtures, QR_PROVIDER=onec, SMS_PROVIDER=fake → FakeOnecGateway, OnecQrProvider, FakeSmsGateway', async () => {
    @Global()
    @Module({
      providers: [{ provide: PG_POOL, useValue: { query: () => Promise.resolve({ rows: [] }) } }],
      exports: [PG_POOL],
    })
    class FakePoolModule {}
    const config = testConfig({ ONEC_MODE: 'fixtures', QR_PROVIDER: 'onec', SMS_PROVIDER: 'fake' });
    const ref = await Test.createTestingModule({
      imports: [
        ConfigModule.forRoot(config),
        FakePoolModule,
        SmsGatewayModule,
        OnecGatewayModule,
        PaymentProviderModule.forRoot(OnecGatewayModule),
      ],
    }).compile();
    expect(ref.get(ONEC_GATEWAY, { strict: false })).toBeInstanceOf(FakeOnecGateway);
    expect(ref.get<PaymentProvider>(PAYMENT_PROVIDER, { strict: false })).toBeInstanceOf(OnecQrProvider);
    expect(ref.get<SmsGateway>(SMS_GATEWAY, { strict: false })).toBeInstanceOf(FakeSmsGateway);
    await ref.close();
  });
});

const PAYMENTS_DIR = fileURLToPath(new URL('../../src/integrations/payments/', import.meta.url));

const REQ: QrIssueRequest = {
  paymentId: '0192f601-0000-7000-8000-0000000000b1',
  orderExternalId: '0192f601-0000-7000-8000-0000000000a1',
  orderRef: null,
  customerRef: null,
  amount: '16007.50',
  currency: 'KGS',
  purpose: 'Оплата заказа POS',
  ttlSeconds: 900,
  cashierUserCode: 'cashier-test',
};

describe('PaymentProvider (ARCH-063, ядро v1.9 §24.4)', () => {
  it('OnecQrProvider через FakeOnecGateway: issue → QrInfo provider=onec, autoConfirm; status pending → paid; cancel', async () => {
    const onec = new FakeOnecGateway();
    const qr = new OnecQrProvider(onec, { now: () => new Date('2026-10-21T08:05:00Z') });
    const issued = await qr.issue(REQ);
    expect(issued).toMatchObject({
      provider: 'onec',
      autoConfirm: true,
      providerRef: 'QR-7F3A9C21',
      amount: '16007.50',
      issuedAt: '2026-10-21T08:05:00.000Z',
    });
    expect(issued.payload).toBeTruthy();
    expect(onec.calls[0]?.args[0]).toMatchObject({ externalId: REQ.paymentId, requestedTtlSeconds: 900 });

    expect((await qr.status(REQ.paymentId)).state).toBe('pending');
    onec.useFixture('getQrPaymentStatus', 'payments-status.paid.200');
    const paid = await qr.status(REQ.paymentId);
    expect(paid).toMatchObject({ state: 'paid', paidAmount: '16007.50', bankReference: 'BK-20261021-000123' });

    expect((await qr.cancel(REQ.paymentId, 'method_changed')).state).toBe('cancelled');
    onec.useFixture('cancelQrPayment', 'payments-qr-cancel.200.paid');
    expect((await qr.cancel(REQ.paymentId, 'method_changed')).state).toBe('paid');
  });

  it('OnecQrProvider: 503 → QrProviderUnavailableError (qr_pending + QR_UNAVAILABLE); 409 → QrProviderRejectedError', async () => {
    const onec = new FakeOnecGateway({ scenario: { createQrPayment: 'payments-qr.503' } });
    const qr = new OnecQrProvider(onec);
    const e503 = await qr.issue(REQ).catch((e: unknown) => e);
    expect(e503).toBeInstanceOf(QrProviderUnavailableError);
    expect((e503 as QrProviderUnavailableError).retryable).toBe(true);
    onec.useFixture('createQrPayment', 'payments-qr.409');
    const e409 = await qr.issue(REQ).catch((e: unknown) => e);
    expect(e409).toBeInstanceOf(QrProviderRejectedError);
    expect((e409 as QrProviderRejectedError).httpStatus).toBe(409);
  });

  it('ManualQrProvider: без внешних вызовов, autoConfirm=false; статический QR → elqr_static, иначе none', async () => {
    const none = await new ManualQrProvider().issue(REQ);
    expect(none).toMatchObject({ provider: 'none', payload: null, autoConfirm: false, amount: null, expiresAt: null });
    const st = await new ManualQrProvider({ staticPayload: '000201-STATIC-TEST' }).issue(REQ);
    expect(st).toMatchObject({ provider: 'elqr_static', payload: '000201-STATIC-TEST', autoConfirm: false });
    expect((await new ManualQrProvider().status(REQ.paymentId)).state).toBe('unknown');
    expect((await new ManualQrProvider().cancel()).state).toBe('not_applicable');
  });

  it('createPaymentProvider: onec/none по QR_PROVIDER; bakai (R2) и onec при odata_only / C-2 → ConfigError', () => {
    const onec = new FakeOnecGateway();
    const base = { ONEC_MODE: 'fixtures', ONEC_INBOUND_ENABLED: false } as const;
    expect(createPaymentProvider({ ...base, QR_PROVIDER: 'onec' }, { onecGateway: onec })).toBeInstanceOf(
      OnecQrProvider,
    );
    expect(createPaymentProvider({ ...base, QR_PROVIDER: 'none' })).toBeInstanceOf(ManualQrProvider);
    expect(() => createPaymentProvider({ ...base, QR_PROVIDER: 'bakai' })).toThrow(ConfigError);
    expect(() =>
      createPaymentProvider(
        { QR_PROVIDER: 'onec', ONEC_MODE: 'odata_only', ONEC_INBOUND_ENABLED: false },
        {
          onecGateway: onec,
        },
      ),
    ).toThrow(/ONEC_MODE=extension/);
    expect(() =>
      createPaymentProvider(
        { QR_PROVIDER: 'onec', ONEC_MODE: 'extension', ONEC_INBOUND_ENABLED: true },
        {
          onecGateway: onec,
        },
      ),
    ).toThrow(/ONEC_INBOUND_ENABLED/);
  });

  it('AC-ARCH-063 п. 4: integrations/payments/** импортирует из integrations/onec/** только типы (import type); BakaiQrProvider нет', () => {
    const files = readdirSync(PAYMENTS_DIR).filter((f) => f.endsWith('.ts'));
    expect(files.some((f) => /bakai/i.test(f))).toBe(false);
    for (const f of files) {
      const src = readFileSync(join(PAYMENTS_DIR, f), 'utf8');
      const imports = [...src.matchAll(/^import\s+(type\s+)?[^;]*?from\s+'([^']+)';/gms)];
      for (const m of imports.filter((x) => (x[2] ?? '').includes('/onec/'))) {
        expect(m[1], `${f}: ${m[0]}`).toBe('type ');
      }
      expect(src).not.toMatch(/class\s+BakaiQrProvider/);
    }
  });
});

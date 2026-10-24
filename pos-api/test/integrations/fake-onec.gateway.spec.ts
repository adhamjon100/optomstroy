import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ConfigError } from '../../src/common/config/app-config.js';
import {
  DEFAULT_ONEC_FIXTURES_DIR,
  DEFAULT_ONEC_SCENARIO,
  FakeOnecGateway,
} from '../../src/integrations/onec/fake-onec.gateway.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import { createOnecGateway } from '../../src/integrations/onec/onec-gateway.factory.js';
import { ONEC_OPERATIONS, type OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import { testConfig } from '../support/test-app.js';

const PAYMENT_ID = '0192f600-0000-7000-8000-00000000c0de';

describe('FakeOnecGateway на фикстурах contracts/onec/fixtures (RM-C-008, 05 ONEC-023)', () => {
  const onec = new FakeOnecGateway();

  afterEach(() => onec.reset());

  it('загружает все фикстуры каталога, каждая помечена «тестовые данные»; _note не попадает в ответ', async () => {
    const files = readdirSync(DEFAULT_ONEC_FIXTURES_DIR).filter((f) => f.endsWith('.json'));
    expect(files.length).toBeGreaterThanOrEqual(58);
    expect(onec.fixtureNames()).toHaveLength(files.length);
    for (const f of files) {
      expect(JSON.parse(readFileSync(join(DEFAULT_ONEC_FIXTURES_DIR, f), 'utf8'))._note).toBe('тестовые данные');
    }
    const health = await onec.getHealth();
    expect(health.status).toBe(200);
    expect(health.body.apiVersion).toBe('1');
    expect(JSON.stringify(health.body)).not.toContain('_note');
    expect(onec.mode).toBe('fixtures');
  });

  // 12 T-ONEC-001 (FakeOnecGateway воспроизводит /pos/v1/* по фикстурам)
  it('сценарий по умолчанию покрывает все JSON-операции контракта, а фикстура соответствует операции', () => {
    const ops = Object.keys(ONEC_OPERATIONS);
    expect(ops).toHaveLength(21); // 05 §6.3: 21 операция
    const withoutJsonFixture = ops.filter((op) => !(op in DEFAULT_ONEC_SCENARIO));
    expect(withoutJsonFixture.sort()).toEqual(['getImage', 'reregisterChanges']);
    expect(() => onec.useFixture('getHealth', 'payments-qr.201')).toThrow(/не является ответом операции getHealth/);
    expect(() => onec.useFixture('createQrPayment', 'payments-qr.request')).toThrow(/не является ответом/);
  });

  it('каталог из фикстур: страница 1 (hasMore) → по cursor страница 2 (hasMore=false) → ack', async () => {
    const p1 = await onec.getChanges({ since: 5120 });
    expect(p1.body.hasMore).toBe(true);
    expect(p1.body.items.some((i) => i.type === 'Catalog_Номенклатура' && i.sku === 'KX-1245')).toBe(true);
    const p2 = await onec.getChanges({ since: 5120, cursor: p1.body.cursor ?? undefined });
    expect(p2.body.hasMore).toBe(false);
    expect(p2.body.messageNumber).toBe(p1.body.messageNumber);
    const ack = await onec.ackChanges(p1.body.messageNumber);
    expect(ack.body.messageNumber).toBe(p1.body.messageNumber);
    const card = await onec.getCatalogCard('a1b2c3d4-0000-4000-8000-000000000001');
    expect(card.body).toHaveProperty('product');
    expect(onec.calls.map((c) => c.operation)).toEqual(['getChanges', 'getChanges', 'ackChanges', 'getCatalogCard']);
  });

  it('QR через 1С: externalId запроса переносится в ответ; статус переключается pending → paid', async () => {
    const qr = await onec.createQrPayment({
      externalId: PAYMENT_ID,
      orderExternalId: '0192f600-0000-7000-8000-0000000000aa',
      orderRef: null,
      customerRef: null,
      amount: '16007.50',
      currency: 'KGS',
      purpose: 'Оплата заказа POS',
      requestedTtlSeconds: 900,
      cashierUserCode: 'cashier-test',
    });
    expect(qr.status).toBe(201);
    expect(qr.body.externalId).toBe(PAYMENT_ID);
    expect(qr.body.qrPayload).toBeTruthy();
    expect((await onec.getQrPaymentStatus(PAYMENT_ID)).body.status).toBe('pending');
    onec.useFixture('getQrPaymentStatus', 'payments-status.paid.200');
    const paid = await onec.getQrPaymentStatus(PAYMENT_ID);
    expect(paid.body).toMatchObject({ externalId: PAYMENT_ID, status: 'paid', paidAmount: '16007.50' });
  });

  // 12 T-ONEC-014 (коды из тела ошибки, признак повтора)
  it('фикстура ошибки → OnecError с кодом POS_E_* из её тела; признак повтора для временных кодов', async () => {
    onec.useFixture('createOrder', 'orders-create.503.locked');
    const locked = await onec.createOrder({ externalId: PAYMENT_ID }).catch((e: unknown) => e);
    expect(locked).toBeInstanceOf(OnecError);
    expect(locked).toMatchObject({ status: 503, operation: 'createOrder' });
    expect((locked as OnecError).retryable).toBe(true);

    onec.useFixture('getOrderStatus', 'orders-status.404');
    const nf = (await onec.getOrderStatus(PAYMENT_ID).catch((e: unknown) => e)) as OnecError;
    expect(nf.code).toBe('POS_E_NOT_FOUND');
    expect(nf.retryable).toBe(false);

    await expect(onec.getImage('a1b2c3d4-0000-4000-8000-0000000000f1')).rejects.toMatchObject({ status: 404 });
  });

  it('фикстура без маркировки «тестовые данные» не загружается', async () => {
    const { mkdtempSync, writeFileSync, rmSync } = await import('node:fs');
    const { tmpdir } = await import('node:os');
    const dir = mkdtempSync(join(tmpdir(), 'onec-fx-'));
    try {
      writeFileSync(join(dir, 'health.200.json'), JSON.stringify({ operation: 'GET /pos/v1/health', status: 200 }));
      expect(() => new FakeOnecGateway({ fixturesDir: dir })).toThrow(/без маркировки/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('createOnecGateway — выбор по ONEC_MODE и запрет fixtures в prod', () => {
  // 12 T-ONEC-001 (ONEC_MODE=fixtures)
  it('fixtures в dev/staging → FakeOnecGateway', () => {
    const gw = createOnecGateway(testConfig({ ONEC_MODE: 'fixtures' }));
    expect(gw).toBeInstanceOf(FakeOnecGateway);
    expect(createOnecGateway({ APP_ENV: 'staging', ONEC_MODE: 'fixtures', ONEC_ODATA_WRITE_ENABLED: false }).mode).toBe(
      'fixtures',
    );
  });

  it('fixtures при APP_ENV=prod → ConfigError даже в обход схемы env (второй рубеж OPS-027)', () => {
    expect(() =>
      createOnecGateway({ APP_ENV: 'prod', ONEC_MODE: 'fixtures', ONEC_ODATA_WRITE_ENABLED: false }),
    ).toThrow(ConfigError);
  });

  it('ONEC_ODATA_WRITE_ENABLED=true допустим только при odata_only (05 ONEC-028)', () => {
    const err = (() => {
      try {
        createOnecGateway({ APP_ENV: 'dev', ONEC_MODE: 'fixtures', ONEC_ODATA_WRITE_ENABLED: true });
      } catch (e) {
        return e as ConfigError;
      }
      return undefined;
    })();
    expect(err?.problems.join('\n')).toContain('ONEC_ODATA_WRITE_ENABLED');
    const stub = { mode: 'odata_only' } as OnecGateway;
    expect(
      createOnecGateway(
        { APP_ENV: 'prod', ONEC_MODE: 'odata_only', ONEC_ODATA_WRITE_ENABLED: true },
        { odataOnly: () => stub },
      ),
    ).toBe(stub);
  });

  it('extension/odata_only без подключённого адаптера → понятная ConfigError (RM-E-001)', () => {
    expect(() =>
      createOnecGateway({ APP_ENV: 'prod', ONEC_MODE: 'extension', ONEC_ODATA_WRITE_ENABLED: false }),
    ).toThrow(/OnecExtensionGateway ещё не подключён/);
  });

  it('ONEC_ODATA_WRITE_ENABLED по умолчанию false (16 §4.3)', () => {
    expect(testConfig().ONEC_ODATA_WRITE_ENABLED).toBe(false);
  });
});

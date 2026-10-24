import { ConfigError } from '../../src/common/config/app-config.js';
import { onecAdapters } from '../../src/integrations/onec/onec-adapters.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import { OnecExtensionGateway } from '../../src/integrations/onec/onec-extension.gateway.js';
import { createOnecGateway } from '../../src/integrations/onec/onec-gateway.factory.js';
import { NodeOnecTransport, OnecTransportError } from '../../src/integrations/onec/onec-http-transport.js';
import { OnecODataGateway } from '../../src/integrations/onec/onec-odata.gateway.js';
import { testConfig } from '../support/test-app.js';
import { type MockResponse, OnecMockServer } from './support/onec-mock-server.js';

const REQ_ID = '0192f5c3-aaaa-7000-8000-000000000042';
const PRODUCT = 'a1b2c3d4-0000-4000-8000-000000000001';

describe('OnecExtensionGateway — HTTP-клиент /pos/v1/* против локального мока на фикстурах (RM-E-001, тестовые данные)', () => {
  const mock = new OnecMockServer('/ut11/hs');
  const transport = new NodeOnecTransport({ allowInsecureHttp: true, connectTimeoutMs: 2_000 });
  let gw: OnecExtensionGateway;

  beforeAll(async () => {
    await mock.start();
    gw = new OnecExtensionGateway(
      {
        baseUrl: mock.baseUrl,
        hsPath: 'ut11/hs',
        user: 'pos_hs',
        password: 'test-only-password', // check-secrets: allow — фиктивное значение теста/приёмки на мок-сервере
        clientKey: 'test-only-client-key',
        retry: { maxAttempts: 3, baseDelayMs: 1 },
        timeoutMs: 2_000,
      },
      transport,
    );
  });
  afterAll(async () => {
    transport.close();
    await mock.stop();
  });
  beforeEach(() => {
    mock.reset();
  });

  // 12 T-ONEC-003 (L1, мок), T-ONEC-016 (X-Request-Id)
  it('успех: GET /health — тело фикстуры, Basic pos_hs + X-POS-Client-Key, X-Request-Id передаётся и возвращается', async () => {
    const r = await gw.getHealth({ requestId: REQ_ID });
    expect(r.status).toBe(200);
    expect(r.body.apiVersion).toBe('1');
    expect(r.body.lastAckMessageNumber).toBe(5120);
    expect(r.requestId).toBe(REQ_ID);
    const seen = mock.seen[0];
    expect(seen.path).toBe('/pos/v1/health');
    expect(seen.headers['x-request-id']).toBe(REQ_ID);
    expect(seen.headers['x-pos-client-key']).toBe('test-only-client-key');
    expect(seen.headers.authorization).toBe(`Basic ${Buffer.from('pos_hs:test-only-password').toString('base64')}`);
  });

  // 12 T-ONEC-016
  it('X-Request-Id генерируется (UUID в нижнем регистре), если вызывающий его не передал', async () => {
    await gw.getHealth();
    expect(mock.seen[0].headers['x-request-id']).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
  });

  // 12 T-ONEC-004 (L1, мок)
  it('GET /changes: since/limit/cursor в query; страница фикстуры; неизвестные поля ответа не мешают (ONEC-058)', async () => {
    const page1 = OnecMockServer.fixture('changes.catalog.page1.200').body as Record<string, unknown>;
    mock.on('GET', /^\/pos\/v1\/changes$/, (req) =>
      req.query.get('cursor') === 'abc'
        ? {
            status: 200,
            body: { ...page1, futureField: { x: 1 }, items: [{ ...(page1.items as object[])[0], newAttr: 42 }] },
          }
        : undefined,
    );
    const r = await gw.getChanges({ since: 5120, limit: 500 });
    expect(r.body.messageNumber).toBe(5121);
    expect(r.body.items.length).toBeGreaterThan(5);
    expect(mock.seen[0].query.get('since')).toBe('5120');
    expect(mock.seen[0].query.get('limit')).toBe('500');
    const r2 = await gw.getChanges({ since: 5120, cursor: 'abc' });
    expect(r2.body.items).toHaveLength(1);
    expect((r2.body as unknown as Record<string, unknown>).futureField).toEqual({ x: 1 });
    expect(r2.body.items[0].newAttr).toBe(42);
  });

  // 12 T-ONEC-014 (401 — без ретрая)
  it('401 POS_E_UNAUTHORIZED → OnecError без повтора (не временная ошибка)', async () => {
    mock.on('GET', /^\/pos\/v1\/health$/, () => ({ status: 401, body: OnecMockServer.fixture('error.401').body }));
    const e = await gw.getHealth().catch((x: unknown) => x);
    expect(e).toBeInstanceOf(OnecError);
    expect((e as OnecError).status).toBe(401);
    expect((e as OnecError).code).toBe('POS_E_UNAUTHORIZED');
    expect((e as OnecError).retryable).toBe(false);
    expect(mock.seen).toHaveLength(1);
  });

  // 12 T-ONEC-014 (временные → ретрай)
  // 12: T-FAIL-009 (1С в режиме обслуживания: повтор GET, затем временная ошибка), T-SYNC-F02
  it('503 POS_E_MAINTENANCE: идемпотентный GET повторяется (3 попытки), затем OnecError retryable', async () => {
    mock.on('GET', /^\/pos\/v1\/changes$/, () => ({
      status: 503,
      body: OnecMockServer.fixture('error.503.maintenance').body,
    }));
    const e = await gw.getChanges({ since: 1 }, { requestId: REQ_ID }).catch((x: unknown) => x);
    expect(e).toBeInstanceOf(OnecError);
    expect((e as OnecError).code).toBe('POS_E_MAINTENANCE');
    expect((e as OnecError).retryable).toBe(true);
    expect(mock.seen).toHaveLength(3);
    // Повтор — с тем же X-Request-Id (один логический запрос).
    expect(new Set(mock.seen.map((s) => s.headers['x-request-id']))).toEqual(new Set([REQ_ID]));
  });

  it('503 → затем 200: повтор GET успешен', async () => {
    let n = 0;
    mock.on('GET', /^\/pos\/v1\/health$/, () =>
      ++n === 1 ? { status: 503, body: { code: 'POS_E_MAINTENANCE', message: 'x', requestId: REQ_ID } } : undefined,
    );
    const r = await gw.getHealth();
    expect(r.status).toBe(200);
    expect(mock.seen).toHaveLength(2);
  });

  it('POST (ack) при 503 не повторяется — запись не ретраится адаптером', async () => {
    mock.on('POST', /^\/pos\/v1\/changes\/ack$/, () => ({
      status: 503,
      body: { code: 'POS_E_LOCKED', message: 'монопольный режим', requestId: REQ_ID },
    }));
    const e = await gw.ackChanges(5121).catch((x: unknown) => x);
    expect((e as OnecError).code).toBe('POS_E_LOCKED');
    expect(mock.seen).toHaveLength(1);
    expect(JSON.parse(mock.seen[0].body)).toEqual({ messageNumber: 5121 });
  });

  // 12 T-ONEC-004 (ack, номер больше выданного → 409)
  it('ack 200 и 409 POS_E_ACK_OUT_OF_ORDER (код из тела ошибки)', async () => {
    const ok = await gw.ackChanges(5121);
    expect(ok.body.messageNumber).toBe(5121);
    mock.on('POST', /^\/pos\/v1\/changes\/ack$/, () => ({
      status: 409,
      body: OnecMockServer.fixture('changes-ack.409').body,
    }));
    const e = await gw.ackChanges(5130).catch((x: unknown) => x);
    expect((e as OnecError).code).toBe('POS_E_ACK_OUT_OF_ORDER');
  });

  it('не-2xx без тела → код по HTTP-статусу; 2xx не по контракту → INVALID_RESPONSE', async () => {
    mock.on('GET', /^\/pos\/v1\/health$/, () => ({ status: 500, raw: Buffer.from('oops') }));
    expect(await gw.getHealth().catch((x: unknown) => (x as OnecError).code)).toBe('POS_E_INTERNAL');
    mock.on('GET', /^\/pos\/v1\/health$/, () => ({ status: 200, body: { hello: 'world' } }));
    expect(await gw.getHealth().catch((x: unknown) => (x as OnecError).code)).toBe('INVALID_RESPONSE');
  });

  it('карточка каталога GET /catalog/{ref} (фикстура) и 404 POS_E_NOT_FOUND', async () => {
    const r = await gw.getCatalogCard(PRODUCT);
    expect(mock.seen[0].path).toBe(`/pos/v1/catalog/${PRODUCT}`);
    expect((r.body.product as Record<string, unknown>).sku).toBe('KX-1245');
    mock.on('GET', /^\/pos\/v1\/catalog\//, () => ({
      status: 404,
      body: OnecMockServer.fixture('catalog-card.404').body,
    }));
    const e = await gw.getCatalogCard(PRODUCT).catch((x: unknown) => x);
    expect((e as OnecError).code).toBe('POS_E_NOT_FOUND');
  });

  it('ссылка не UUID → POS_E_BAD_REQUEST без обращения к 1С', async () => {
    await expect(gw.getCatalogCard('../../etc/passwd')).rejects.toMatchObject({ code: 'POS_E_BAD_REQUEST' });
    expect(mock.seen).toHaveLength(0);
  });

  // 12 T-ONEC-012 (L1, мок)
  it('изображения: байты + ETag; If-None-Match → 304 (body null)', async () => {
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
    mock.on('GET', /^\/pos\/v1\/images\//, (req): MockResponse => {
      if (req.headers['if-none-match'] === '"abc"') return { status: 304, headers: { ETag: '"abc"' } };
      return { status: 200, raw: png, headers: { ETag: '"abc"', 'Content-Type': 'image/png' } };
    });
    const r = await gw.getImage('a1b2c3d4-0000-4000-8000-0000000000f1');
    expect(r.status).toBe(200);
    expect(r.body?.etag).toBe('"abc"');
    expect(r.body?.contentType).toBe('image/png');
    expect(Buffer.from(r.body!.data)).toEqual(png);
    const r304 = await gw.getImage('a1b2c3d4-0000-4000-8000-0000000000f1', '"abc"');
    expect(r304.status).toBe(304);
    expect(r304.body).toBeNull();
    expect(mock.seen[1].headers['if-none-match']).toBe('"abc"');
  });

  it('прочие методы контракта: заказ (POST), статус (GET), QR, клиенты, долг, возвраты, /check, external-ids', async () => {
    const order = await gw.createOrder({ externalId: '0192f5b1-1111-7aaa-8bbb-000000000001' });
    expect([200, 201]).toContain(order.status);
    expect((await gw.getOrderStatus('0192f5b1-1111-7aaa-8bbb-000000000001')).status).toBe(200);
    expect((await gw.getOrderStatusBatch(['0192f5b1-1111-7aaa-8bbb-000000000001'])).status).toBe(200);
    expect(Array.isArray((await gw.findCustomersByPhone('+996700123456')).body)).toBe(true);
    expect(mock.seen.find((s) => s.path === '/pos/v1/customers')!.query.get('phone')).toBe('+996700123456');
    expect((await gw.checkCart({ lines: [] })).status).toBe(200);
    expect((await gw.listExternalIds({ limit: 10 })).status).toBe(200);
    mock.on('POST', /^\/pos\/v1\/changes\/reregister$/, () => ({ status: 202 }));
    const reregister = await gw.reregisterChanges();
    expect(reregister.status).toBe(202);
    expect(reregister.body).toBeNull();
  });

  it('таймаут транспорта → OnecError(status 0, TRANSPORT), временная', async () => {
    const slow = new OnecExtensionGateway(
      { baseUrl: mock.baseUrl, hsPath: 'ut11/hs', timeoutMs: 100, retry: { maxAttempts: 1, baseDelayMs: 0 } },
      transport,
    );
    mock.on('GET', /^\/pos\/v1\/health$/, () => ({ status: 200, body: {}, delayMs: 500 }));
    const e = await slow.getHealth().catch((x: unknown) => x);
    expect((e as OnecError).status).toBe(0);
    expect((e as OnecError).code).toBe('TRANSPORT');
    expect((e as OnecError).retryable).toBe(true);
  });

  it('http:// без allowInsecureHttp отвергается транспортом (ONEC-081: только HTTPS)', async () => {
    const strict = new NodeOnecTransport();
    await expect(
      strict.request({ method: 'GET', url: `${mock.baseUrl}/x`, headers: {}, timeoutMs: 1000 }),
    ).rejects.toBeInstanceOf(OnecTransportError);
    strict.close();
  });
});

describe('Фабрика ONEC_MODE с боевыми адаптерами (onecAdapters)', () => {
  // 12 T-ONEC-001 (реализации переключаются env)
  it('extension → OnecExtensionGateway; без ONEC_HS_* → ConfigError при старте', () => {
    const c = testConfig({
      ONEC_MODE: 'extension',
      ONEC_BASE_URL: 'https://host-1c.local',
      ONEC_HS_PATH: 'ut11/hs',
      ONEC_HS_USER: 'pos_hs',
      ONEC_HS_PASSWORD: 'x',
      ONEC_HS_TOKEN: 'k',
      QR_PROVIDER: 'none',
    });
    expect(createOnecGateway(c, onecAdapters(c))).toBeInstanceOf(OnecExtensionGateway);
    const bad = testConfig({ ONEC_MODE: 'extension', ONEC_BASE_URL: 'https://host-1c.local', QR_PROVIDER: 'none' });
    expect(() => createOnecGateway(bad, onecAdapters(bad))).toThrow(ConfigError);
  });

  it('odata_only → OnecODataGateway (HS-методы недоступны: 501)', async () => {
    const c = testConfig({
      ONEC_MODE: 'odata_only',
      ONEC_BASE_URL: 'https://host-1c.local',
      ONEC_USER: 'pos_integration',
      ONEC_PASSWORD: 'x',
      QR_PROVIDER: 'none',
    });
    const g = createOnecGateway(c, onecAdapters(c));
    expect(g).toBeInstanceOf(OnecODataGateway);
    await expect(g.getChanges({ since: 0 })).rejects.toMatchObject({ status: 501, code: 'POS_E_NOT_FOUND' });
  });
});

import { ConfigError } from '../../src/common/config/app-config.js';
import { createSmsGateway } from '../../src/integrations/sms/sms-gateway.factory.js';
import { SmsGatewayError } from '../../src/integrations/sms/sms-gateway.js';
import { NodeHttpsTransport } from '../../src/integrations/sms/sms-http-transport.js';
import { createSmsTelemetry, SMS_METRICS, type SmsTelemetry } from '../../src/integrations/sms/sms-telemetry.js';
import { type SmsProConfig, SmsProXmlGateway } from '../../src/integrations/sms/smspro-xml.gateway.js';
import { testConfig } from '../support/test-app.js';
import { CaptureLogger } from './support/capture-logger.js';
import {
  drReply,
  infoReply,
  messageReply,
  MockSmsPro,
  TEST_LOGIN,
  TEST_PASSWORD,
  textOf,
} from './support/mock-smspro.js';

const OTP = '583921';
const TEXT = `Kod: ${OTP}. Optomstroy`;
const PHONE = '+996700123456';

/**
 * `SmsProXmlGateway` против локального HTTPS-стенда (T-SMS-001…T-SMS-007, AC-AUTH-025…AC-AUTH-030):
 * формат запроса, разбор, маппинг всех кодов status, таймаут/мусор/5xx, circuit-breaker, `/dr`, `/info`,
 * отсутствие секретов, текста и кода в логах.
 */
describe('SmsProXmlGateway на локальном HTTPS-стенде SMSPro', () => {
  const mock = new MockSmsPro();
  let logger: CaptureLogger;
  let telemetry: SmsTelemetry;
  let clockMs = Date.parse('2026-10-22T10:00:00Z');
  const now = () => clockMs;

  const cfg = (over: Partial<SmsProConfig> = {}): SmsProConfig => ({
    SMSPRO_BASE_URL: mock.baseUrl,
    SMSPRO_LOGIN: TEST_LOGIN,
    SMSPRO_PASSWORD: TEST_PASSWORD,
    SMSPRO_SENDER: 'Optomstroy',
    SMSPRO_TEST_FLAG: false,
    SMSPRO_TIMEOUT_MS: 1500,
    SMSPRO_RETRY_MAX: 3,
    SMSPRO_CB_OPEN_MINUTES: 5,
    APP_ENV: 'staging',
    ...over,
  });
  const gateway = (over: Partial<SmsProConfig> = {}) =>
    new SmsProXmlGateway(cfg(over), { transport: new NodeHttpsTransport({ agent: mock.agent() }), telemetry, now });
  const send = (gw: SmsProXmlGateway, transactionId = 'A88726B4C9D1', attempt = 1) =>
    gw.send({
      transactionId,
      sender: 'Optomstroy',
      text: TEXT,
      phone: PHONE,
      test: false,
      attempt,
      purpose: 'otp_login',
    });

  beforeAll(async () => {
    await mock.start();
  });
  afterAll(async () => {
    await mock.stop();
  });
  beforeEach(() => {
    mock.reset();
    logger = new CaptureLogger();
    telemetry = createSmsTelemetry(logger, now);
    clockMs = Date.parse('2026-10-22T10:00:00Z');
  });
  afterEach(() => {
    // Ни в одной записи лога — ни текста SMS, ни кода, ни логина/пароля, ни полного номера (SMS-023, AC-AUTH-012).
    const text = logger.text;
    for (const secret of [OTP, TEXT, TEST_LOGIN, TEST_PASSWORD, '700123456']) expect(text).not.toContain(secret);
  });

  it('T-SMS-020, AC-AUTH-025: POST {base}/message, Content-Type application/xml, ровно теги документации, phone без «+»', async () => {
    const res = await send(gateway());
    expect(res).toMatchObject({ outcome: 'ACCEPTED', providerStatus: 0, phonesRecognized: 1, smsParts: 1, attempt: 1 });
    const [req] = mock.to('message');
    expect(req?.method).toBe('POST');
    expect(req?.headers['content-type']).toBe('application/xml');
    expect(req?.body.startsWith('<?xml version="1.0" encoding="UTF-8"?>')).toBe(true);
    expect(req?.xml?.name).toBe('message');
    expect(req?.xml?.children.map((c) => c.name)).toEqual(['login', 'pwd', 'id', 'sender', 'text', 'phones']);
    expect(textOf(req?.xml, 'id')).toBe('A88726B4C9D1');
    expect(textOf(req?.xml, 'login')).toBe(TEST_LOGIN);
    expect(textOf(req?.xml, 'text')).toBe(TEXT);
    expect(req?.xml?.children[5]?.children.map((p) => p.text)).toEqual(['996700123456']);
    // SMSPRO_TEST_FLAG=true → <test>1</test>; ответ 11 — ACCEPTED_TEST без алерта
    const testGw = gateway({ SMSPRO_TEST_FLAG: true });
    mock.enqueue('message', messageReply(11, 'A88726B4C9D2'));
    const t = await testGw.send({
      transactionId: 'A88726B4C9D2',
      sender: 'Optomstroy',
      text: TEXT,
      phone: PHONE,
      test: true,
    });
    expect(t.outcome).toBe('ACCEPTED_TEST');
    expect(textOf(mock.to('message')[1]?.xml, 'test')).toBe('1');
    expect(logger.events('sms.alert')).toHaveLength(0);
    // лог отправки — только разрешённые поля
    const [entry] = logger.events('sms.send');
    expect(Object.keys(entry ?? {}).sort()).toEqual(
      [
        'event',
        'transactionId',
        'phoneMasked',
        'purpose',
        'providerStatus',
        'outcome',
        'smscnt',
        'phonesRecognized',
        'latencyMs',
        'attempt',
      ].sort(),
    );
    expect(entry?.phoneMasked).toBe('+996 7** *** *56');
  });

  const table: [number, string, string | null][] = [
    [0, 'ACCEPTED', null],
    [1, 'PERMANENT', 'smspro_request_format'],
    [2, 'CONFIG_ERROR', 'smspro_auth_failed'],
    [3, 'CONFIG_ERROR', 'smspro_ip_not_allowed'],
    [4, 'INSUFFICIENT_FUNDS', 'smspro_insufficient_funds'],
    [5, 'CONFIG_ERROR', 'smspro_sender_rejected'],
    [6, 'PERMANENT', 'smspro_stop_words'],
    [7, 'INVALID_PHONE', null],
    [8, 'PERMANENT', 'smspro_request_format'],
    [9, 'RETRYABLE', null],
    [10, 'DUPLICATE_ID', null],
    [11, 'ACCEPTED_TEST', 'smspro_test_flag_leaked'],
    [12, 'PERMANENT', 'smspro_unknown_status'],
  ];
  it.each(table)('AC-AUTH-027: status=%i → %s (алерт: %s)', async (status, outcome, alert) => {
    mock.enqueue(
      'message',
      messageReply(status, 'A88726B4C9D1', 1, 1, status === 7 ? 'bad phone 996555123456' : undefined),
    );
    const res = await send(gateway());
    expect(res.outcome).toBe(outcome);
    expect(res.providerStatus).toBe(status);
    const kinds = logger.events('sms.alert').map((a) => a.alert);
    if (alert) expect(kinds).toContain(alert);
    else expect(kinds.filter((k) => k !== 'sms_circuit_open')).toEqual([]);
    if (status === 7) expect(res.providerMessage).toBe('bad phone +996 5** *** *56'); // номер из <message> маскирован
    if (outcome === 'CONFIG_ERROR' || outcome === 'INSUFFICIENT_FUNDS') expect(kinds).toContain('sms_circuit_open');
  });

  it('T-SMS-006: таймаут → RETRYABLE (timeout); мусор → RETRYABLE (bad_response); HTTP 5xx → RETRYABLE (http_5xx) + алерт', async () => {
    const gw = gateway({ SMSPRO_TIMEOUT_MS: 1000 });
    mock.enqueue('message', { hang: true });
    const started = Date.now();
    const t = await send(gw);
    expect(t).toMatchObject({ outcome: 'RETRYABLE', failure: 'timeout', providerStatus: null });
    expect(Date.now() - started).toBeLessThan(5000);
    mock.enqueue('message', { body: '<html>oops' });
    expect(await send(gw)).toMatchObject({ outcome: 'RETRYABLE', failure: 'bad_response' });
    mock.enqueue('message', { httpStatus: 502, body: 'Bad gateway' });
    expect(await send(gw)).toMatchObject({ outcome: 'RETRYABLE', failure: 'http_5xx', httpStatus: 502 });
    expect(logger.events('sms.alert').map((a) => a.alert)).toContain('smspro_http_5xx');
    mock.enqueue('message', { httpStatus: 404, body: '' });
    expect(await send(gw)).toMatchObject({ outcome: 'PERMANENT', failure: 'http_status' });
    // все попытки — с тем же id (повторы выполняет воркер, адаптер id не меняет)
    expect(new Set(mock.to('message').map((r) => textOf(r.xml, 'id')))).toEqual(new Set(['A88726B4C9D1']));
  });

  it('AC-AUTH-030: CONFIG_ERROR открывает breaker → 2-й send без HTTP, sms_circuit_open=1, алерт; half-open через SMSPRO_CB_OPEN_MINUTES', async () => {
    const gw = gateway();
    mock.enqueue('message', messageReply(2));
    expect((await send(gw)).outcome).toBe('CONFIG_ERROR');
    expect(telemetry.metrics.value(SMS_METRICS.circuitOpen)).toBe(1);
    const second = await send(gw, 'A88726B4C9D2');
    expect(second).toMatchObject({ outcome: 'RETRYABLE', failure: 'circuit_open', providerStatus: null });
    expect(mock.to('message')).toHaveLength(1); // без HTTP-запроса
    expect(logger.events('sms.alert').map((a) => a.alert)).toEqual(
      expect.arrayContaining(['smspro_auth_failed', 'sms_circuit_open']),
    );
    clockMs += 4 * 60_000;
    expect((await send(gw, 'A88726B4C9D3')).failure).toBe('circuit_open');
    expect(mock.to('message')).toHaveLength(1);
    clockMs += 61_000; // > 5 мин — half-open: один пробный запрос
    expect(gw.circuitState().state).toBe('half_open');
    const probe = await send(gw, 'A88726B4C9D4');
    expect(probe.outcome).toBe('ACCEPTED');
    expect(mock.to('message')).toHaveLength(2);
    expect(gw.circuitState().state).toBe('closed');
    expect(telemetry.metrics.value(SMS_METRICS.circuitOpen)).toBe(0);
  });

  it('breaker: неудачный пробный запрос снова открывает; ≥ 50 % RETRYABLE за минуту (≥ 4 вызовов) открывает', async () => {
    const gw = gateway();
    mock.enqueue('message', messageReply(4));
    await send(gw);
    clockMs += 5 * 60_000 + 1;
    mock.enqueue('message', messageReply(4));
    expect((await send(gw, 'A88726B4C9D2')).outcome).toBe('INSUFFICIENT_FUNDS');
    expect(gw.circuitState()).toMatchObject({ state: 'open', reason: 'insufficient_funds' });

    const gw2 = gateway();
    mock.enqueue('message', messageReply(0), messageReply(9), messageReply(0), messageReply(9));
    for (const id of ['B00000000001', 'B00000000002', 'B00000000003']) await send(gw2, id);
    expect(gw2.circuitState().state).toBe('closed'); // 3 вызова < minSamples
    await send(gw2, 'B00000000004');
    expect(gw2.circuitState()).toMatchObject({ state: 'open', reason: 'retryable_ratio' });
    const before = mock.to('message').length;
    expect((await send(gw2, 'B00000000005')).failure).toBe('circuit_open');
    expect(mock.to('message')).toHaveLength(before);
  });

  it('до сети: неверный id → PERMANENT, номер вне КР → INVALID_PHONE (HTTP-запросов нет)', async () => {
    const gw = gateway();
    expect(await send(gw, 'short')).toMatchObject({ outcome: 'PERMANENT', failure: 'invalid_request' });
    expect(
      await gw.send({ transactionId: 'A88726B4C9D1', sender: 'S', text: TEXT, phone: '+79120000000', test: false }),
    ).toMatchObject({ outcome: 'INVALID_PHONE', failure: 'invalid_request' });
    expect(mock.requests).toHaveLength(0);
  });

  it('/api/dr: запрос с phone; status 0 → отчёты; 4 → [] / status=4; иной статус → SmsGatewayError', async () => {
    const gw = gateway();
    mock.enqueue(
      'dr',
      drReply(0, [{ number: '996700123456', report: 3, sendTime: '20261022160000', rcvTime: '20261022160005' }]),
    );
    const reports = await gw.getDeliveryReport('A88726B4C9D1', PHONE);
    expect(reports).toEqual([
      {
        number: '996700123456',
        report: 3,
        sendTime: '2026-10-22T10:00:00.000Z',
        rcvTime: '2026-10-22T10:00:05.000Z',
        state: 'DELIVERED',
      },
    ]);
    const [req] = mock.to('dr');
    expect(req?.xml?.children.map((c) => c.name)).toEqual(['login', 'pwd', 'id', 'phone']);
    expect(textOf(req?.xml, 'phone')).toBe('996700123456');
    expect(await gw.getDeliveryReport('A88726B4C9D1', PHONE)).toEqual([]); // по умолчанию стенд — status=4
    expect(await gw.queryDeliveryReport('A88726B4C9D1', PHONE)).toEqual({ status: 4, reports: [] });
    mock.enqueue('dr', drReply(5));
    await expect(gw.getDeliveryReport('A88726B4C9D1', PHONE)).rejects.toBeInstanceOf(SmsGatewayError);
    expect(telemetry.metrics.value(SMS_METRICS.deliveryReportTotal, { report: 3 })).toBe(1);
  });

  it('/api/info: тело с namespace; баланс и состояние', async () => {
    const gw = gateway();
    mock.enqueue('info', infoReply(0, 0, '250.00', '1.58'));
    expect(await gw.getAccountInfo()).toEqual({ status: 0, state: 0, account: '250.00', smsprice: '1.58' });
    const [req] = mock.to('info');
    expect(req?.body).toContain('<info xmlns="http://Giper.mobi/schema/Info">');
    mock.enqueue('info', { hang: true });
    const quick = gateway({ SMSPRO_TIMEOUT_MS: 1000 });
    await expect(quick.getAccountInfo()).rejects.toMatchObject({ kind: 'timeout', endpoint: 'info' });
  });

  it('T-SMS-014: конфигурация — http://, имя отправителя 12 символов, нет SMSPRO_LOGIN_FILE → ConfigError без секретов', () => {
    expect(() => gateway({ SMSPRO_BASE_URL: 'http://smspro.nikita.kg/api' })).toThrow(/только https/);
    expect(() => gateway({ SMSPRO_SENDER: 'Optomstroy12' })).toThrow(/SMSPRO_SENDER/);
    expect(() => gateway({ SMSPRO_SENDER: '99655512345678' })).not.toThrow(); // 14 цифр — допустимо
    try {
      gateway({ SMSPRO_LOGIN: undefined, SMSPRO_SENDER: 'Bad Sender!!' });
      expect.unreachable();
    } catch (e) {
      expect(e).toBeInstanceOf(ConfigError);
      expect(String(e)).toContain('SMSPRO_LOGIN_FILE');
      expect(String(e)).not.toContain(TEST_PASSWORD);
    }
    // фабрика: SMS_PROVIDER=smspro → боевой адаптер (без сетевых вызовов при создании)
    const gw = createSmsGateway({
      ...testConfig({ SMS_PROVIDER: 'smspro', SMSPRO_SENDER: 'Optomstroy' }),
      SMSPRO_LOGIN: TEST_LOGIN,
      SMSPRO_PASSWORD: TEST_PASSWORD,
    });
    expect(gw).toBeInstanceOf(SmsProXmlGateway);
    expect(JSON.stringify(gw)).not.toContain(TEST_PASSWORD);
    expect(mock.requests).toHaveLength(0);
  });

  it('транспорт отвергает не-HTTPS и не доверяет чужому сертификату', async () => {
    const t = new NodeHttpsTransport();
    await expect(t.post(`${mock.baseUrl}/message`, '<x/>', 1000)).rejects.toMatchObject({ kind: 'network' });
    await expect(t.post('http://127.0.0.1:1/api/message', '<x/>', 1000)).rejects.toMatchObject({
      causeCode: 'NOT_HTTPS',
    });
  });
});

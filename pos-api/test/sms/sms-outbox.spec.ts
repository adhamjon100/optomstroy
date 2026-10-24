import { randomBytes } from 'node:crypto';
import { PgBoss } from 'pg-boss';
import { generateProviderMessageId, parseSecretRing } from '../../src/common/crypto/index.js';
import { PG_BOSS_SCHEMA } from '../../src/common/jobs/pg-boss.service.js';
import { NodeHttpsTransport } from '../../src/integrations/sms/sms-http-transport.js';
import { SMS_METRICS } from '../../src/integrations/sms/sms-telemetry.js';
import {
  latestBalanceSnapshot,
  SMS_QUEUES,
  SmsRuntime,
  type SmsDeliveryListener,
  type SmsDeliveryReportEvent,
  type SmsRuntimeConfig,
  type SmsSendJob,
  type SmsSendSettledEvent,
} from '../../src/notifications/sms/index.js';
import { FoundationDb, seedSubject } from '../foundation/support/foundation-db.js';
import { testConfig } from '../support/test-app.js';
import { waitFor } from '../worker/helpers.js';
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

const OTP = '604217';
const TEXT = `Kod: ${OTP}. Optomstroy`;
const OTP_SECRET = randomBytes(32).toString('hex');

/**
 * SMS-контур notifications на PostgreSQL 17 + локальный HTTPS-стенд SMSPro (T-SMS-004, -005, -007, -008, -010,
 * -011, -012, -013; AC-AUTH-028, -029, -031, -032, -036, -037): постановка `sms_outbox` + `sms.send` в одной
 * транзакции, ретраи по кодам с тем же `id`, дедупликация `id` через `/dr`, DLR-опрос, баланс, журнал без текста.
 */
describe('notifications/sms: sms_outbox, воркер отправки, DLR, баланс', () => {
  const db = new FoundationDb();
  const mock = new MockSmsPro();
  let boss: PgBoss;
  let logger: CaptureLogger;
  let rt: SmsRuntime;
  let sleeps: number[];
  let settled: SmsSendSettledEvent[];
  let reports: SmsDeliveryReportEvent[];
  let phoneSeq = 0;
  const phone = () => `+99670${String(9_100_000 + ++phoneSeq).padStart(7, '0')}`;

  const config = (over: Partial<SmsRuntimeConfig> = {}): SmsRuntimeConfig => ({
    ...testConfig({ SMS_PROVIDER: 'smspro' }),
    APP_ENV: 'staging',
    SMSPRO_BASE_URL: mock.baseUrl,
    SMSPRO_LOGIN: TEST_LOGIN,
    SMSPRO_PASSWORD: TEST_PASSWORD,
    SMSPRO_SENDER: 'Optomstroy',
    SMSPRO_TIMEOUT_MS: 1000,
    OTP_HMAC_SECRET: OTP_SECRET,
    OTP_HMAC_SECRET_VERSION: 1,
    ...over,
  });

  const listener: SmsDeliveryListener = {
    onSendSettled: (e) => {
      settled.push(e);
      return Promise.resolve();
    },
    onDeliveryReport: (e) => {
      reports.push(e);
      return Promise.resolve();
    },
  };

  const runtime = (over: Partial<SmsRuntimeConfig> = {}) => {
    const r = new SmsRuntime({
      config: config(over),
      pool: db.pool,
      db: db.db,
      logger,
      otpSecretRing: parseSecretRing('OTP_HMAC_SECRET', OTP_SECRET, 1, 'staging'),
      transport: new NodeHttpsTransport({ agent: mock.agent() }),
      listener,
      sleep: (ms) => {
        sleeps.push(ms);
        return Promise.resolve();
      },
      pollingIntervalSeconds: 0.5,
    });
    r.attach(boss);
    return r;
  };

  /** Строка sms_outbox + payload задания так же, как их ставит enqueue (без ожидания pg-boss). */
  const enqueue = async (r: SmsRuntime, p = phone()) => {
    const q = await r.outbox.enqueue({ phone: p, templateKey: 'otp_login', text: TEXT });
    const job: SmsSendJob = { smsOutboxId: q.id, sealedText: r.sealer.seal(q.id, TEXT) };
    return { ...q, job, phone: p };
  };
  const row = async (id: string) =>
    (await db.pool.query('SELECT * FROM sms_outbox WHERE id = $1', [id])).rows[0] as Record<string, unknown>;

  beforeAll(async () => {
    await mock.start();
    await db.start('pos_sms_outbox');
    boss = new PgBoss({ connectionString: db.url, schema: PG_BOSS_SCHEMA, supervise: false, schedule: false });
    boss.on('error', () => undefined);
    await boss.start();
  });
  afterAll(async () => {
    await boss?.stop({ graceful: false }).catch(() => undefined);
    await db.stop();
    await mock.stop();
  });
  beforeEach(() => {
    mock.reset();
    logger = new CaptureLogger();
    sleeps = [];
    settled = [];
    reports = [];
    rt = runtime();
  });
  afterEach(() => {
    // SMS-023 / AC-AUTH-012: в логах нет кода, текста, логина/пароля и полного номера.
    for (const s of [OTP, TEXT, TEST_LOGIN, TEST_PASSWORD, '+99670']) expect(logger.text).not.toContain(s);
  });

  it('T-SMS-012: enqueue: sms_outbox(queued) + задание sms.send в одной транзакции; откат — ни строки, ни задания; текст не в БД', async () => {
    const p = phone();
    const q = await rt.outbox.enqueue({ phone: p.slice(1), templateKey: 'otp_login', text: TEXT, requestId: 'r-1' });
    expect(q.providerMessageId).toMatch(/^[A-Za-z0-9]{12}$/);
    const r = await row(q.id);
    expect(r).toMatchObject({
      phone_e164: p,
      template_key: 'otp_login',
      provider: 'smspro',
      status: 'queued',
      attempts: 0,
    });
    expect(Object.keys(r).filter((k) => /^(text|code|otp|body|sms_text)$/.test(k))).toEqual([]); // AC-AUTH-036
    const jobs = await db.pool.query(`SELECT data FROM ${PG_BOSS_SCHEMA}.job WHERE name = $1 AND singleton_key = $2`, [
      SMS_QUEUES.send,
      q.id,
    ]);
    expect(jobs.rows).toHaveLength(1);
    const data = jobs.rows[0].data as SmsSendJob;
    expect(data.smsOutboxId).toBe(q.id);
    expect(JSON.stringify(data)).not.toContain(OTP); // текст в payload — только шифртекст
    expect(rt.sealer.open(q.id, data.sealedText)).toBe(TEXT);
    expect(() => rt.sealer.open(randomUUIDLike(), data.sealedText)).toThrow(); // AAD = id строки

    const p2 = phone();
    await expect(
      db.db.transaction(async (tx) => {
        await rt.outbox.enqueue({ phone: p2, templateKey: 'otp_login', text: TEXT }, tx);
        throw new Error('rollback');
      }),
    ).rejects.toThrow('rollback');
    expect((await db.pool.query('SELECT 1 FROM sms_outbox WHERE phone_e164 = $1', [p2])).rowCount).toBe(0);
    const orphan = await db.pool.query(
      `SELECT 1 FROM ${PG_BOSS_SCHEMA}.job j WHERE j.name = $1 AND NOT EXISTS (SELECT 1 FROM sms_outbox s WHERE s.id::text = j.singleton_key)`,
      [SMS_QUEUES.send],
    );
    expect(orphan.rowCount).toBe(0);
    await expect(rt.outbox.enqueue({ phone: '+79120000000', templateKey: 'otp_login', text: TEXT })).rejects.toThrow(
      /КР/,
    );
  });

  it('AC-AUTH-028: status 9, 9, 0 → три запроса с одним id, паузы 5 и 10 с, ACCEPTED (attempt=3), DLR-опросы поставлены', async () => {
    const q = await enqueue(rt);
    mock.enqueue('message', messageReply(9), messageReply(9), messageReply(0));
    const res = await rt.processor.process(q.job);
    expect(res).toMatchObject({ status: 'sent', outcome: 'ACCEPTED', attempts: 3 });
    expect(mock.to('message').map((r) => textOf(r.xml, 'id'))).toEqual([
      q.providerMessageId,
      q.providerMessageId,
      q.providerMessageId,
    ]);
    expect(sleeps).toEqual([5000, 10_000]);
    expect(await row(q.id)).toMatchObject({
      status: 'sent',
      attempts: 3,
      outcome: 'ACCEPTED',
      provider_status_code: 0,
      sms_parts: 1,
      phones_recognized: 1,
    });
    expect((await row(q.id)).sent_at).toBeInstanceOf(Date);
    expect(settled).toEqual([expect.objectContaining({ smsOutboxId: q.id, status: 'sent', outcome: 'ACCEPTED' })]);
    const polls = await db.pool.query(
      `SELECT data, start_after - created_on AS delay FROM ${PG_BOSS_SCHEMA}.job WHERE name = $1 AND data->>'smsOutboxId' = $2 ORDER BY start_after`,
      [SMS_QUEUES.dlrPoll, q.id],
    );
    expect(polls.rows.map((r) => (r.data as { round: number }).round)).toEqual([0, 1, 2]);
    expect(rt.telemetry.metrics.value(SMS_METRICS.retryTotal)).toBe(2);
    // повтор того же задания (pg-boss retry) — строка уже не queued, отправки нет
    expect(await rt.processor.process(q.job)).toMatchObject({ status: 'skipped' });
    expect(mock.to('message')).toHaveLength(3);
  });

  it('AC-AUTH-028: 4 ответа status=9 → 4 запроса, failed (PERMANENT), challenge — failed_delivery через listener', async () => {
    const q = await enqueue(rt);
    mock.enqueue('message', messageReply(9), messageReply(9), messageReply(9), messageReply(9));
    const res = await rt.processor.process(q.job);
    expect(res).toMatchObject({ status: 'failed', outcome: 'PERMANENT', error: 'status_9_exhausted', attempts: 4 });
    expect(sleeps).toEqual([5000, 10_000, 10_000]);
    expect(await row(q.id)).toMatchObject({ status: 'failed', outcome: 'PERMANENT', attempts: 4 });
    expect(settled).toEqual([expect.objectContaining({ status: 'failed', outcome: 'PERMANENT' })]);
  });

  it('T-SMS-005, AC-AUTH-029 (а): таймаут, затем status=10, /dr → status 0 + report 1 → ACCEPTED, новой отправки нет', async () => {
    const q = await enqueue(rt);
    mock.enqueue('message', { hang: true }, messageReply(10));
    mock.enqueue('dr', drReply(0, [{ number: q.phone.slice(1), report: 1, sendTime: '20261022160000' }]));
    const res = await rt.processor.process(q.job);
    expect(res).toMatchObject({ status: 'sent', outcome: 'ACCEPTED', attempts: 2, regeneratedIds: 0 });
    expect(mock.to('message').map((r) => textOf(r.xml, 'id'))).toEqual([q.providerMessageId, q.providerMessageId]);
    expect(textOf(mock.to('dr')[0]?.xml, 'id')).toBe(q.providerMessageId);
    expect(await row(q.id)).toMatchObject({
      status: 'sent',
      outcome: 'ACCEPTED',
      provider_message_id: q.providerMessageId,
      delivery_status: '1',
      attempts: 2,
    });
  });

  it('T-SMS-005, AC-AUTH-029 (б): таймаут, status=10, /dr → status 4 → новая отправка с НОВЫМ id; (в) иной /dr → failed + алерт', async () => {
    const q = await enqueue(rt);
    mock.enqueue('message', { hang: true }, messageReply(10), messageReply(0));
    mock.enqueue('dr', drReply(4));
    const res = await rt.processor.process(q.job);
    expect(res).toMatchObject({ status: 'sent', regeneratedIds: 1, attempts: 3 });
    const ids = mock.to('message').map((r) => textOf(r.xml, 'id'));
    expect(ids[0]).toBe(q.providerMessageId);
    expect(ids[1]).toBe(q.providerMessageId);
    expect(ids[2]).toMatch(/^[A-Za-z0-9]{12}$/);
    expect(ids[2]).not.toBe(q.providerMessageId);
    expect((await row(q.id)).provider_message_id).toBe(ids[2]);

    // отдельный процесс: в этом уже 2 RETRYABLE из 4 попыток за минуту — breaker открыт бы по доле (SMS-015)
    const other = runtime();
    const q2 = await enqueue(other);
    mock.enqueue('message', { hang: true }, messageReply(10));
    mock.enqueue('dr', drReply(2));
    expect(await other.processor.process(q2.job)).toMatchObject({ status: 'failed', error: 'duplicate_id_unresolved' });
    expect(logger.events('sms.alert').map((a) => a.alert)).toContain('smspro_duplicate_id');
  });

  it('T-SMS-006: таймауты до SMSPRO_RETRY_MAX → failed RETRYABLE; 5xx трижды → failed PERMANENT', async () => {
    const quick = runtime({ SMSPRO_RETRY_MAX: 2 });
    const q = await enqueue(quick);
    mock.enqueue('message', { body: 'not xml' }, { body: '<html/>' }, { body: '' });
    expect(await quick.processor.process(q.job)).toMatchObject({
      status: 'failed',
      outcome: 'RETRYABLE',
      error: 'retry_exhausted',
      attempts: 3,
    });
    expect(new Set(mock.to('message').map((r) => textOf(r.xml, 'id')))).toEqual(new Set([q.providerMessageId]));

    mock.reset();
    const fresh = runtime({ SMSPRO_RETRY_MAX: 2 }); // в первом процессе breaker открыт долей RETRYABLE
    expect(quick.gateway.provider).toBe('smspro');
    const q2 = await enqueue(fresh);
    mock.enqueue('message', { httpStatus: 503 }, { httpStatus: 503 }, { httpStatus: 503 });
    expect(await fresh.processor.process(q2.job)).toMatchObject({
      status: 'failed',
      outcome: 'PERMANENT',
      error: 'http_5xx_repeated',
      attempts: 3,
    });
  });

  it('T-SMS-007: CONFIG_ERROR → failed; availability() → 503-признак; следующее задание — без HTTP (breaker)', async () => {
    const q = await enqueue(rt);
    mock.enqueue('message', messageReply(2));
    expect(await rt.processor.process(q.job)).toMatchObject({
      status: 'failed',
      outcome: 'CONFIG_ERROR',
      error: 'status_2',
    });
    expect(await rt.outbox.availability()).toMatchObject({ blocked: true, reason: 'config_error' });
    const q2 = await enqueue(rt);
    const before = mock.to('message').length;
    expect(await rt.processor.process(q2.job)).toMatchObject({ status: 'failed', error: 'circuit_open', attempts: 0 });
    expect(mock.to('message')).toHaveLength(before);
    expect(rt.telemetry.metrics.value(SMS_METRICS.circuitOpen)).toBe(1);
    expect(logger.events('sms.alert').map((a) => a.alert)).toEqual(
      expect.arrayContaining(['smspro_auth_failed', 'sms_circuit_open']),
    );
    // принятая отправка после trip снимает признак (межпроцессный half-open)
    const fresh = runtime();
    const q3 = await enqueue(fresh);
    expect(await fresh.processor.process(q3.job)).toMatchObject({ status: 'sent' });
    expect(await fresh.outbox.availability()).toEqual({ blocked: false });
  });

  it('T-SMS-008, AC-AUTH-032: DLR-опрос report 0 → 1 → 3: sent → delivered; 2/4/5 → failed; 7 → expired; повтор — без изменений', async () => {
    const q = await enqueue(rt);
    await rt.processor.process(q.job);
    const num = q.phone.slice(1);
    mock.enqueue(
      'dr',
      drReply(0, [{ number: num, report: 0 }]),
      drReply(0, [{ number: num, report: 1, sendTime: '20261022160000' }]),
      drReply(0, [{ number: num, report: 3, sendTime: '20261022160000', rcvTime: '20261022160007' }]),
    );
    expect(await rt.dlr.poll({ smsOutboxId: q.id, round: 0 })).toMatchObject({ report: 0, changed: true });
    expect(await row(q.id)).toMatchObject({ status: 'sent', delivery_status: '0' });
    await rt.dlr.poll({ smsOutboxId: q.id, round: 1 });
    expect(await row(q.id)).toMatchObject({ status: 'sent', delivery_status: '1' });
    await rt.dlr.poll({ smsOutboxId: q.id, round: 2 });
    const done = await row(q.id);
    expect(done).toMatchObject({ status: 'delivered', delivery_status: '3' });
    expect((done.delivered_at as Date).toISOString()).toBe('2026-10-22T10:00:07.000Z');
    expect(await rt.dlr.poll({ smsOutboxId: q.id, round: 2 })).toMatchObject({ skipped: 'not_sent' });
    const dr = mock.to('dr');
    expect(dr.every((r) => textOf(r.xml, 'phone') === num && textOf(r.xml, 'id') === q.providerMessageId)).toBe(true);
    expect(reports.map((r) => r.state)).toEqual(['PENDING', 'PENDING', 'DELIVERED']);

    for (const [report, status] of [
      [2, 'failed'],
      [4, 'failed'],
      [5, 'failed'],
      [7, 'expired'],
    ] as const) {
      const x = await enqueue(rt);
      await rt.processor.process(x.job);
      mock.enqueue('dr', drReply(0, [{ number: x.phone.slice(1), report }]));
      await rt.dlr.poll({ smsOutboxId: x.id, round: 0 });
      expect(await row(x.id)).toMatchObject({ status, delivery_status: String(report) });
    }
    // /dr status=4 (ещё нет отчёта) и 5 (очередь) — статус не меняется
    const y = await enqueue(rt);
    await rt.processor.process(y.job);
    mock.enqueue('dr', drReply(4), drReply(5));
    expect(await rt.dlr.poll({ smsOutboxId: y.id, round: 0 })).toMatchObject({ providerStatus: 4 });
    expect(await rt.dlr.poll({ smsOutboxId: y.id, round: 1 })).toMatchObject({ skipped: 'busy' });
    expect(await row(y.id)).toMatchObject({ status: 'sent', delivery_status: null });
  });

  // 12: T-FAIL-011 (исчерпан баланс SMSPro: алерт администратору)
  it('T-SMS-010, AC-AUTH-031: баланс 250 < 300 → sms_balance_som=250, алерт, in-app уведомление администраторам (раз в сутки); state=1 → алерт', async () => {
    const admin = await seedSubject(db.db, { kind: 'staff', role: 'admin' });
    const seller = await seedSubject(db.db, { kind: 'staff', role: 'seller' });
    mock.enqueue('info', infoReply(0, 0, '250.00', '1.58'), infoReply(0, 0, '240.00'));
    const s = await rt.balance.poll();
    expect(s).toMatchObject({
      providerStatus: 0,
      state: 0,
      account: '250.00',
      belowThreshold: true,
      thresholdSom: 300,
    });
    expect(rt.telemetry.metrics.value(SMS_METRICS.balanceSom)).toBe(250);
    expect(logger.events('sms.alert').map((a) => a.alert)).toContain('sms_balance_low');
    const notes = await db.pool.query(
      `SELECT user_id, kind, severity, title_ru, body_ru, dedupe_key FROM notifications WHERE dedupe_key LIKE 'sms.balance_low:%'`,
    );
    expect(notes.rows.map((r: { user_id: string }) => r.user_id)).toEqual([admin.userId]);
    expect(notes.rows[0]).toMatchObject({ kind: 'system', severity: 'warning', title_ru: 'Низкий баланс SMS' });
    expect(notes.rows[0].body_ru).toContain('250.00');
    expect(notes.rows.map((r: { user_id: string }) => r.user_id)).not.toContain(seller.userId);
    await rt.balance.poll(); // те же сутки — новое уведомление не создаётся
    expect(
      (await db.pool.query(`SELECT 1 FROM notifications WHERE dedupe_key LIKE 'sms.balance_low:%'`)).rowCount,
    ).toBe(1);
    expect(mock.to('info')).toHaveLength(2);

    mock.enqueue('info', infoReply(0, 1, '5000.00'));
    const inactive = await runtime().balance.poll();
    expect(inactive).toMatchObject({ state: 1, belowThreshold: false });
    expect(logger.events('sms.alert').map((a) => a.alert)).toContain('sms_account_inactive');
    mock.enqueue('info', infoReply(2, 1, '0', '0'));
    expect(await runtime().balance.poll()).toMatchObject({ providerStatus: 2, account: null, belowThreshold: false });
    expect(logger.events('sms.alert').map((a) => a.alert)).toContain('smspro_auth_failed');
  });

  it('T-SMS-011, AC-AUTH-037: 100 000 id — ровно 12 [A-Za-z0-9], уникальны; UNIQUE в sms_outbox отвергает повтор', async () => {
    const ids = new Set<string>();
    for (let i = 0; i < 100_000; i++) {
      const id = generateProviderMessageId();
      expect(id).toMatch(/^[A-Za-z0-9]{12}$/);
      ids.add(id);
    }
    expect(ids.size).toBe(100_000);
    const q = await enqueue(rt);
    await expect(
      db.pool.query(
        `INSERT INTO sms_outbox (phone_e164, template_key, provider_message_id) VALUES ($1, 'otp_login', $2)`,
        [q.phone, q.providerMessageId],
      ),
    ).rejects.toMatchObject({ code: '23505' });
    await expect(
      db.pool.query(
        `INSERT INTO sms_outbox (phone_e164, template_key, provider_message_id) VALUES ($1, 'otp_login', $2)`,
        [q.phone, '0190a1b2-c3d4'],
      ),
    ).rejects.toMatchObject({ code: '23514' }); // CHECK: не UUID
  });

  it('pos-worker: SmsRuntime.register — задание из enqueue отправлено через pg-boss; баланс — снимок в output задания', async () => {
    const workerBoss = new PgBoss({
      connectionString: db.url,
      schema: PG_BOSS_SCHEMA,
      supervise: false,
      schedule: false,
    });
    workerBoss.on('error', () => undefined);
    await workerBoss.start();
    try {
      const w = runtime();
      await w.register(workerBoss);
      const q = await rt.outbox.enqueue({ phone: phone(), templateKey: 'otp_step_up', text: TEXT, requestId: 'rq-7' });
      const sent = await waitFor(
        async () => {
          const r = await row(q.id);
          return r.status === 'sent' ? r : undefined;
        },
        { what: 'sms_outbox → sent' },
      );
      expect(sent).toMatchObject({ status: 'sent', template_key: 'otp_step_up', attempts: 1 });
      expect(textOf(mock.to('message').at(-1)?.xml, 'id')).toBe(q.providerMessageId);
      const schedules = await workerBoss.getSchedules();
      expect(schedules.find((s) => s.name === SMS_QUEUES.balancePoll)?.cron).toBe('*/15 * * * *');
      mock.enqueue('info', infoReply(0, 0, '777.70'));
      await workerBoss.send(SMS_QUEUES.balancePoll, {});
      const snap = await waitFor(async () => (await latestBalanceSnapshot(db.pool)) ?? undefined, {
        what: 'снимок баланса',
      });
      expect(snap).toMatchObject({ account: '777.70', providerStatus: 0, belowThreshold: false });
    } finally {
      await workerBoss.stop({ graceful: false }).catch(() => undefined);
    }
  });
});

function randomUUIDLike(): string {
  return '01900000-0000-7000-8000-000000000000';
}

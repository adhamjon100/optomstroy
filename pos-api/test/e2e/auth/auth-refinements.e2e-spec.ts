import { randomUUID } from 'node:crypto';
import { bootstrapFirstAdmin } from '../../../src/admin/bootstrap/first-admin.js';
import { OtpService } from '../../../src/auth/otp/otp.service.js';
import { OTP_HMAC_SECRET_RING, type SecretRing } from '../../../src/common/crypto/index.js';
import { SMS_GATEWAY, type SmsGateway } from '../../../src/integrations/sms/sms-gateway.js';
import { createOtpDeliveryListener } from '../../../src/jobs/otp/otp-delivery-listener.js';
import type { SmsSendJob } from '../../../src/notifications/sms/sms-queues.js';
import { SmsRuntime } from '../../../src/notifications/sms/sms-runtime.js';
import { ANDROID, AuthE2e, freshDevice, freshIp, freshPhone, type JsonBody } from './support/auth-e2e.js';

/**
 * Остатки этапа D (D_authentication_report §5.3 DQ-01…DQ-03, INT-01; миграция 0003_auth_refinements.sql):
 * лимиты RL-OTP-SEND-IP/-DEV/-GLOBAL, RL-OTP-VERIFY и RL-PIN — в `rate_limit_counters` (переживают перезапуск
 * процесса), `locked_at`, `issued_jti` (повтор verify после рестарта), `sms_outbox.request_id`; доставка OTP через
 * очередь pos-worker с сохранением нейтрального ответа, лимитов и возврата квоты номера при `failed`.
 */

function claims(token: string): JsonBody {
  return JSON.parse(Buffer.from(token.split('.')[1] ?? '', 'base64url').toString()) as JsonBody;
}

describe('auth e2e: уточнения схемы 0003 — лимиты в PostgreSQL, locked_at, issued_jti, request_id', () => {
  const t = new AuthE2e();
  const PIN = '482913';

  beforeAll(async () => {
    await t.start('auth_refine_e2e', {}, { otpVerifyPerIp10m: 3, pinPer10m: 2 });
  });
  afterAll(async () => {
    await t.stop();
  });
  beforeEach(() => {
    t.tick();
    t.clearAuthCache();
  });

  async function counters(scope: string, subject: string): Promise<number> {
    const r = await t.pool.query<{ n: number }>(
      `SELECT coalesce(sum(count), 0)::int AS n FROM rate_limit_counters WHERE scope = $1 AND subject = $2`,
      [scope, subject],
    );
    return r.rows[0]?.n ?? 0;
  }

  it('DQ-01: RL-OTP-SEND-IP/-DEV/-GLOBAL — счётчики rate_limit_counters; лимит IP 20 / 10 мин переживает перезапуск pos-api; request_id в sms_outbox', async () => {
    t.alignClock(10 * 60_000);
    const ip = freshIp();
    const dev = freshDevice();
    const phone = freshPhone();
    const requestId = randomUUID();
    const first = await t.http
      .post('/api/v1/auth/otp/request')
      .set('X-Device-Id', dev)
      .set('X-Forwarded-For', ip)
      .set('X-Request-Id', requestId)
      .send({ phone, purpose: 'login_or_register', locale: 'ru' });
    expect(first.status).toBe(202);
    expect(await counters('otp_ip_10m', ip)).toBe(1);
    expect(await counters('otp_ip_24h', ip)).toBe(1);
    expect(await counters('otp_device_10m', dev)).toBe(1);
    expect(await counters('otp_device_24h', dev)).toBe(1);
    expect(await counters('otp_global_1m', 'global')).toBeGreaterThanOrEqual(1);
    expect(await counters('otp_phone_15m', t.app.get(OtpService).phoneSubject(phone))).toBe(1);
    // 07 §5.12: сырой номер в subject не хранится
    // Ищется сам номер (9 цифр абонента), а не «996»: случайные hex-субъекты (HMAC, id устройства) могут содержать
    // подстроку «996» — прежняя проверка была нестабильной (упала в прогоне test:cov:f при исправлении ревью F).
    const raw = await t.pool.query(`SELECT 1 FROM rate_limit_counters WHERE subject LIKE '%' || $1 || '%'`, [
      phone.replace(/\D/g, '').slice(-9),
    ]);
    expect(raw.rows).toHaveLength(0);
    // SMS-Q-06 / 11 SEC-064: сквозной requestId в sms_outbox
    await t.drainSms();
    const sms = await t.pool.query<JsonBody>(
      `SELECT s.request_id AS sms_request_id, c.request_id AS ch_request_id
         FROM otp_challenges c JOIN sms_outbox s ON s.id = c.sms_outbox_id WHERE c.id = $1`,
      [first.body.challengeId],
    );
    expect(sms.rows[0]).toEqual({ sms_request_id: requestId, ch_request_id: requestId });

    for (let i = 0; i < 9; i++) expect((await t.otpRequest(freshPhone(), freshDevice(), ip)).status).toBe(202);
    await t.restart(); // in-memory состояние сброшено, счётчики в БД остались
    for (let i = 0; i < 10; i++) expect((await t.otpRequest(freshPhone(), freshDevice(), ip)).status).toBe(202);
    const denied = await t.otpRequest(freshPhone(), freshDevice(), ip);
    expect(denied.status).toBe(429);
    expect(denied.body.code).toBe('RATE_LIMITED');
    expect(Number(denied.headers['retry-after'])).toBeGreaterThan(0);
    expect(await counters('otp_ip_10m', ip)).toBe(20); // отказ квоту не расходует
  });

  it('DQ-01: RL-OTP-VERIFY (IP) — otp_verify_ip_10m, переживает перезапуск', async () => {
    t.alignClock(10 * 60_000);
    const ip = freshIp();
    for (let i = 0; i < 2; i++) {
      expect((await t.otpVerify(randomUUID(), '123456', freshDevice(), ip)).status).toBe(404);
    }
    await t.restart();
    expect((await t.otpVerify(randomUUID(), '123456', freshDevice(), ip)).status).toBe(404);
    const denied = await t.otpVerify(randomUUID(), '123456', freshDevice(), ip);
    expect(denied.status).toBe(429);
    expect(denied.body.code).toBe('RATE_LIMITED');
    expect(await counters('otp_verify_ip_10m', ip)).toBe(3);
  });

  it('DQ-03: блокировка кода ставит locked_at (от него — пауза номера 09 §5.4)', async () => {
    const phone = freshPhone();
    const dev = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(phone, dev, ip);
    expect(req.status).toBe(202);
    const code = await t.codeFor(req.body.challengeId as string);
    t.tick(5_000);
    // каждая попытка — с нового IP: в этом наборе RL-OTP-VERIFY = 3 / 10 мин на IP
    for (let i = 0; i < 5; i++) {
      await t.otpVerify(req.body.challengeId, code === '000000' ? '111111' : '000000', dev, freshIp());
    }
    const row = await t.pool.query<JsonBody>('SELECT status, locked_at, created_at FROM otp_challenges WHERE id = $1', [
      req.body.challengeId,
    ]);
    expect(row.rows[0]?.status).toBe('locked');
    expect((row.rows[0]?.locked_at as Date).getTime()).toBe(t.clock.now().getTime());
    expect((row.rows[0]?.locked_at as Date).getTime()).toBeGreaterThan((row.rows[0]?.created_at as Date).getTime());
  });

  it('DQ-03 (auth A-15, FX-11): issued_jti в otp_challenges — повтор verify после перезапуска отзывает прежний access', async () => {
    const u = await t.seedUser({ role: 'seller' });
    const r = await t.login(u.phone);
    expect(r.status).toBe(200);
    const firstJti = claims(r.body.accessToken as string).jti as string;
    const ch = await t.pool.query<JsonBody>('SELECT issued_jti FROM otp_challenges WHERE id = $1', [r.challengeId]);
    expect(ch.rows[0]?.issued_jti).toBe(firstJti);
    await t.restart(); // прежде jti жил только в памяти процесса
    t.tick(10_000);
    const replay = await t.otpVerify(r.challengeId, r.code, r.deviceKey, r.ip);
    expect(replay.status).toBe(200);
    expect(replay.body.sid).toBe(r.body.sid);
    const secondJti = claims(replay.body.accessToken as string).jti as string;
    expect(secondJti).not.toBe(firstJti);
    const denied = await t.pool.query<JsonBody>('SELECT reason, token_kind FROM token_denylist WHERE jti = $1', [
      firstJti,
    ]);
    expect(denied.rows[0]).toEqual({ reason: 'revoked', token_kind: 'access' });
    const after = await t.pool.query<JsonBody>('SELECT issued_jti FROM otp_challenges WHERE id = $1', [r.challengeId]);
    expect(after.rows[0]?.issued_jti).toBe(secondJti);
  });

  it('INT-02: приглашение bootstrap-admin → первый вход по OTP → staff с ролью admin, nextStep=set_pin', async () => {
    const phone = freshPhone();
    const r = await bootstrapFirstAdmin(t.fdb.db, {
      phone,
      fullName: 'Тестов Первый Администратор',
      ttlDays: 7,
      requestId: randomUUID(),
      now: t.clock.now(),
    });
    expect(r.kind).toBe('created');
    const login = await t.login(phone);
    expect(login.status).toBe(200);
    expect(login.body).toMatchObject({ status: 'authenticated', nextStep: 'set_pin', roleSource: 'invitation' });
    expect(claims(login.body.accessToken as string).roles).toEqual(['admin']);
    const inv = await t.pool.query<JsonBody>(`SELECT status FROM user_invitations WHERE phone_e164 = $1`, [phone]);
    expect(inv.rows[0]?.status).toBe('accepted');
    // активный admin появился — повторная процедура ничего не делает
    const again = await bootstrapFirstAdmin(t.fdb.db, {
      phone: freshPhone(),
      fullName: 'Тестов Второй',
      ttlDays: 7,
      requestId: randomUUID(),
    });
    expect(again.kind).toBe('admin_exists');
  });

  it('DQ-01: RL-PIN — pin_user_device_10m (userId:deviceId), переживает перезапуск; 429 до проверки PIN', async () => {
    t.alignClock(10 * 60_000);
    const u = await t.seedUser({ role: 'seller' });
    await t.setPin(u.userId, PIN);
    const r = await t.login(u.phone);
    expect(r.status).toBe(200);
    const stepUp = (access: string) =>
      t
        .bearer('post', '/auth/step-up', access, r.deviceKey)
        .send({ method: 'pin', pin: '000000', operation: 'profile.pin.set' });
    expect((await stepUp(r.body.accessToken as string)).body.code).toBe('PIN_INVALID');
    await t.restart(); // ключи JWT dev эфемерны — новый вход на том же устройстве
    t.tick(61_000);
    const r2 = await t.login(u.phone, { deviceKey: r.deviceKey });
    expect(r2.status).toBe(200);
    expect((await stepUp(r2.body.accessToken as string)).body.code).toBe('PIN_INVALID');
    const failedBefore = async () =>
      (await t.pool.query<JsonBody>('SELECT failed_attempts FROM app_pins WHERE user_id = $1', [u.userId])).rows[0]
        ?.failed_attempts as number;
    const fa = await failedBefore();
    const denied = await stepUp(r2.body.accessToken as string);
    expect(denied.status).toBe(429);
    expect(denied.body.code).toBe('RATE_LIMITED');
    expect(await counters('pin_user_device_10m', `${u.userId}:${r.deviceKey}`)).toBe(2);
    expect(await failedBefore()).toBe(fa); // третья попытка PIN не проверялась
  });
});

describe('auth e2e: доставка OTP через очередь pos-worker (INT-01; 09 §6.8) — нейтральный ответ, лимиты, итог воркера', () => {
  const t = new AuthE2e();
  let runtime: SmsRuntime;

  beforeAll(async () => {
    await t.start('auth_refine_queued', {}, {}, 'queued');
    const ring = t.app.get<SecretRing>(OTP_HMAC_SECRET_RING);
    const silent = { log: () => undefined, warn: () => undefined, error: () => undefined };
    // pos-worker: тот же SmsRuntime и слушатель, что в src/worker.ts; шлюз — FakeSmsGateway приложения (dev_outbox)
    runtime = new SmsRuntime({
      config: t.config,
      pool: t.pool,
      db: t.fdb.db,
      logger: silent,
      otpSecretRing: ring,
      gateway: t.app.get<SmsGateway>(SMS_GATEWAY),
      listener: createOtpDeliveryListener({ config: t.config, pool: t.pool, otpSecretRing: ring, clock: t.clock }),
      clock: t.clock,
      sleep: () => Promise.resolve(),
    });
    const fakeBoss = {
      getQueue: () => Promise.resolve({}),
      createQueue: () => Promise.resolve(),
      send: () => Promise.resolve(randomUUID()),
    };
    runtime.attach(fakeBoss as never);
  });
  afterAll(async () => {
    await t.stop();
  });
  beforeEach(() => {
    t.tick();
  });

  function jobFor(smsOutboxId: string): SmsSendJob {
    const job = t.publishedJobs.find((j) => j.queue === 'sms.send' && j.data.smsOutboxId === smsOutboxId);
    if (!job) throw new Error(`нет задания sms.send для ${smsOutboxId}`);
    return job.data as unknown as SmsSendJob;
  }

  async function outboxOf(challengeId: string): Promise<JsonBody> {
    const r = await t.pool.query<JsonBody>(
      `SELECT s.id, s.status, s.request_id, c.status AS ch_status
         FROM otp_challenges c JOIN sms_outbox s ON s.id = c.sms_outbox_id WHERE c.id = $1`,
      [challengeId],
    );
    return r.rows[0] ?? {};
  }

  it('ответ /auth/otp/request нейтрален (существующий и новый номер); воркер отправляет — код из SMS проходит verify; cooldown сохраняется', async () => {
    const existing = await t.seedUser({ role: 'seller' });
    const dev = freshDevice();
    const ip = freshIp();
    const a = await t.otpRequest(existing.phone, dev, ip);
    const b = await t.otpRequest(freshPhone(), freshDevice(), freshIp());
    expect(a.status).toBe(202);
    expect(b.status).toBe(202);
    expect(Object.keys(a.body).sort()).toEqual(Object.keys(b.body).sort());
    const pick = (x: JsonBody) => ({
      resendAfterSec: x.resendAfterSec,
      otpTtlSec: x.otpTtlSec,
      codeLength: x.codeLength,
      deliveryHint: x.deliveryHint,
    });
    expect(pick(a.body)).toEqual(pick(b.body));
    // API SMSPro не вызывает: строка queued, задание поставлено в транзакции выпуска кода
    const queued = await outboxOf(a.body.challengeId as string);
    expect(queued.status).toBe('queued');
    expect(queued.request_id).toEqual(expect.any(String));
    expect(t.publishedJobs.find((j) => j.data.smsOutboxId === queued.id)?.inTx).toBe(true);

    const res = await runtime.processor.process(jobFor(queued.id as string));
    expect(res.status).toBe('sent');
    expect((await outboxOf(a.body.challengeId as string)).status).toBe('sent');
    const code = await t.codeFor(a.body.challengeId as string);
    const v = await t.otpVerify(a.body.challengeId as string, code, dev, ip, ANDROID);
    expect(v.status).toBe(200);
    expect(v.body.status).toBe('authenticated');

    t.tick(10_000);
    const again = await t.otpRequest(existing.phone, dev, ip);
    expect(again.status).toBe(429);
    expect(again.body.code).toBe('OTP_RATE_LIMITED');
  });

  it('очередь недоступна → нейтральный 503 SMS_PROVIDER_ERROR, челлендж не создан, квоты не израсходованы', async () => {
    const phone = freshPhone();
    const dev = freshDevice();
    t.failPublish = true;
    try {
      const r = await t.otpRequest(phone, dev, freshIp());
      expect(r.status).toBe(503);
      expect(r.body.code).toBe('SMS_PROVIDER_ERROR');
    } finally {
      t.failPublish = false;
    }
    const ch = await t.pool.query('SELECT 1 FROM otp_challenges WHERE phone_e164 = $1', [phone]);
    expect(ch.rows).toHaveLength(0);
    const used = await t.pool.query(
      `SELECT 1 FROM rate_limit_counters WHERE scope = 'otp_device_10m' AND subject = $1 AND count > 0`,
      [dev],
    );
    expect(used.rows).toHaveLength(0);
    expect((await t.otpRequest(phone, dev, freshIp())).status).toBe(202);
  });

  it('итог задания failed в pos-worker → failed_delivery и возврат квоты номера (слушатель createOtpDeliveryListener)', async () => {
    const phone = '+996700000004'; // FakeSmsGateway: status=4 → неудача без повтора
    const r = await t.otpRequest(phone, freshDevice(), freshIp());
    expect(r.status).toBe(202);
    const subject = t.app.get(OtpService).phoneSubject(phone);
    const before = await t.pool.query<{ n: number }>(
      `SELECT coalesce(sum(count), 0)::int AS n FROM rate_limit_counters WHERE scope = 'otp_phone_15m' AND subject = $1`,
      [subject],
    );
    expect(before.rows[0]?.n).toBe(1);
    const sms = await outboxOf(r.body.challengeId as string);
    const res = await runtime.processor.process(jobFor(sms.id as string));
    expect(res.status).toBe('failed');
    const row = await outboxOf(r.body.challengeId as string);
    expect(row).toMatchObject({ status: 'failed', ch_status: 'failed_delivery' });
    const after = await t.pool.query<{ n: number }>(
      `SELECT coalesce(sum(count), 0)::int AS n FROM rate_limit_counters WHERE scope = 'otp_phone_15m' AND subject = $1`,
      [subject],
    );
    expect(after.rows[0]?.n).toBe(0);
  });
});

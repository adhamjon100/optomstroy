import { OtpCircuitBreaker } from '../../../src/auth/otp/otp-circuit-breaker.js';
import { ANDROID, AuthE2e, freshDevice, freshIp, type JsonBody, WINDOWS } from './support/auth-e2e.js';

/**
 * RM-D-016 (09 §6.13 п. 3, SMS-035; 11 SEC-131, SEC-043, §7.2.1; AC-AUTH-086; 12 T-ADMIN-010): вход сотрудника по
 * аварийному коду администратора — сквозной сценарий выдача (`POST /admin/users/{id}/emergency-login-code`, admin со
 * step-up по PIN) → `/auth/otp/request` (202 с challengeId кода, без SMS и cooldown, привязка к устройству) →
 * `/auth/otp/verify` (`amr=admin_code`, `unlocked_until=now()` при PIN, аудит `auth.emergency_code.used`) →
 * повтор отклоняется → через 10 мин код не принимается. Ревью D-MJ-01.
 */
describe('auth e2e: вход по аварийному коду администратора (RM-D-016)', () => {
  const t = new AuthE2e();
  const PIN = '482913';
  let admin: { access: string; refresh: string; deviceKey: string };

  beforeAll(async () => {
    await t.start('auth_emergency_e2e', {}, {}, 'in_process', { admin: true });
    const a = await t.seedUser({ role: 'admin' });
    await t.setPin(a.userId, PIN);
    const r = await t.login(a.phone);
    expect(r.status).toBe(200);
    admin = { access: r.body.accessToken as string, refresh: r.body.refreshToken as string, deviceKey: r.deviceKey };
  });
  afterAll(async () => {
    await t.stop();
  });
  beforeEach(() => {
    t.tick();
    t.clearAuthCache();
  });

  function claims(token: string): JsonBody {
    return JSON.parse(Buffer.from(token.split('.')[1] ?? '', 'base64url').toString()) as JsonBody;
  }

  /** Выдача кода администратором (step-up PIN; access администратора перевыпускается — часы идут вперёд). */
  async function issueCode(targetUserId: string): Promise<{ code: string; expiresAt: string }> {
    const fresh = await t.refresh(admin.refresh, admin.deviceKey);
    expect(fresh.status).toBe(200);
    admin = { ...admin, access: fresh.body.accessToken as string, refresh: fresh.body.refreshToken as string };
    const su = await t
      .bearer('post', '/auth/step-up', admin.access, admin.deviceKey)
      .send({ method: 'pin', pin: PIN, operation: 'users.emergency_code.issue' });
    expect(su.status).toBe(200);
    const r = await t
      .bearer('post', `/admin/users/${targetUserId}/emergency-login-code`, admin.access, admin.deviceKey)
      .set('X-Step-Up-Token', su.body.stepUpToken as string)
      .send({ reason: 'sms_unavailable' });
    expect(r.status).toBe(201);
    expect(r.body.code).toMatch(/^\d{6}$/);
    return { code: r.body.code as string, expiresAt: r.body.expiresAt as string };
  }

  async function smsCount(): Promise<number> {
    const r = await t.pool.query<{ n: number }>('SELECT count(*)::int AS n FROM sms_outbox');
    return r.rows[0]?.n ?? 0;
  }

  it('T-ADMIN-010 (в): request → 202 с challengeId кода без SMS (и при открытом circuit-breaker), verify → amr=admin_code, UNLOCK_REQUIRED до PIN, аудит used', async () => {
    const target = await t.seedUser({ role: 'seller' });
    await t.setPin(target.userId, PIN);
    const { code } = await issueCode(target.userId);
    const issuedId = (
      await t.pool.query<{ id: string }>(
        `SELECT id FROM otp_challenges WHERE user_id = $1 AND status = 'sent' AND sms_outbox_id IS NULL`,
        [target.userId],
      )
    ).rows[0]?.id;
    expect(issuedId).toBeDefined();

    // SMS «недоступны»: circuit-breaker открыт — обычный запрос кода дал бы 503, аварийный — 202 без SMS
    t.app.get(OtpCircuitBreaker).open('config_error', 5);
    const before = await smsCount();
    const deviceKey = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(target.phone, deviceKey, ip);
    expect(req.status).toBe(202);
    expect(req.body).toMatchObject({ challengeId: issuedId, codeLength: 6, deliveryHint: 'sms' });
    expect(req.body.otpTtlSec).toBeGreaterThan(9 * 60);
    expect(req.body.otpTtlSec).toBeLessThanOrEqual(10 * 60);
    // повтор с того же устройства — тот же challengeId, без 429 cooldown и без аннулирования
    const again = await t.otpRequest(target.phone, deviceKey, ip);
    expect(again.status).toBe(202);
    expect(again.body.challengeId).toBe(issuedId);
    expect(await smsCount()).toBe(before);
    const row = (await t.pool.query<JsonBody>('SELECT * FROM otp_challenges WHERE id = $1', [issuedId])).rows[0];
    expect(row).toMatchObject({ status: 'sent', device_key: deviceKey, sms_outbox_id: null });
    t.app.get(OtpCircuitBreaker).reset();

    const v = await t.otpVerify(issuedId, code, deviceKey, ip, ANDROID);
    expect(v.status).toBe(200);
    expect(v.body.status).toBe('authenticated');
    const access = v.body.accessToken as string;
    expect(claims(access).amr).toEqual(['admin_code']);
    const session = (await t.pool.query<JsonBody>('SELECT * FROM sessions WHERE id = $1', [v.body.sid])).rows[0];
    expect(new Date(session.unlocked_until).getTime()).toBeLessThanOrEqual(t.clock.now().getTime());
    expect(session.created_from_challenge_id).toBe(issuedId);
    // миграция 0003 (DQ-02, DQ-03): `admin_code` хранится в sessions.amr; выдавший — otp_challenges.issued_by_user_id
    expect(session.amr).toEqual(['admin_code']);
    const issuedBy = await t.pool.query<JsonBody>('SELECT issued_by_user_id FROM otp_challenges WHERE id = $1', [
      issuedId,
    ]);
    expect(issuedBy.rows[0]?.issued_by_user_id).toEqual(expect.any(String));

    // второй фактор: PIN установлен → первый рабочий запрос → 401 UNLOCK_REQUIRED; /auth/unlock PIN → работа
    const blocked = await t.bearer('get', '/probe/work', access, deviceKey);
    expect(blocked.status).toBe(401);
    expect(blocked.body).toMatchObject({ code: 'UNLOCK_REQUIRED', reason: 'emergency_code' });
    const unlocked = await t.unlock({ method: 'pin', pin: PIN, refreshToken: v.body.refreshToken }, deviceKey);
    expect(unlocked.status).toBe(200);
    expect(unlocked.body.amr).toEqual(['pin']); // схема ответа — sms|bio|pin; admin_code — в JWT
    expect(claims(unlocked.body.accessToken as string).amr).toEqual(['admin_code', 'pin']);
    expect((await t.pool.query<JsonBody>('SELECT amr FROM sessions WHERE id = $1', [v.body.sid])).rows[0]?.amr).toEqual(
      ['admin_code', 'pin'],
    );
    expect((await t.bearer('get', '/probe/work', unlocked.body.accessToken as string, deviceKey)).status).toBe(200);
    // ротация сохраняет признак аварийного входа
    t.tick(5_000);
    const refreshed = await t.refresh(unlocked.body.refreshToken as string, deviceKey);
    expect(refreshed.status).toBe(200);
    expect(claims(refreshed.body.accessToken as string).amr).toEqual(['admin_code', 'pin']);

    const used = await t.pool.query<JsonBody>(
      `SELECT actor_user_id, severity, after FROM audit_logs WHERE action = 'auth.emergency_code.used' AND entity_id = $1`,
      [target.userId],
    );
    expect(used.rows).toHaveLength(1);
    expect(used.rows[0]).toMatchObject({
      actor_user_id: target.userId,
      after: { challengeId: issuedId, sid: v.body.sid, deviceId: deviceKey, amr: ['admin_code'], unlockRequired: true },
    });
    const login = await t.pool.query<JsonBody>(
      `SELECT after FROM audit_logs WHERE action = 'auth.login' AND entity_id = $1`,
      [v.body.sid],
    );
    expect(login.rows[0]?.after).toMatchObject({ amr: ['admin_code'] });
    // код не попадает в логи и аудит (SEC-078)
    const standalone = new RegExp(`(?<![0-9])${code}(?![0-9])`);
    expect(t.logs.text).not.toMatch(standalone);
    const audit = await t.pool.query('SELECT * FROM audit_logs');
    expect(JSON.stringify(audit.rows)).not.toMatch(standalone);
  });

  it('T-ADMIN-010 (г, тот же код): повторное использование кода отклоняется; новый request после входа — обычный OTP по SMS', async () => {
    const target = await t.seedUser({ role: 'seller' });
    await t.setPin(target.userId, PIN);
    const { code } = await issueCode(target.userId);
    const deviceKey = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(target.phone, deviceKey, ip);
    expect(req.status).toBe(202);
    const v = await t.otpVerify(req.body.challengeId as string, code, deviceKey, ip);
    expect(v.status).toBe(200);
    // сессия использована (unlock) → сетевой повтор verify уже не принимается (09 §5.6)
    expect((await t.unlock({ method: 'pin', pin: PIN, refreshToken: v.body.refreshToken }, deviceKey)).status).toBe(
      200,
    );
    const second = await t.otpVerify(req.body.challengeId as string, code, deviceKey, ip);
    expect(second.status).toBe(422);
    expect(second.body.code).toBe('OTP_EXPIRED');
    // другое устройство — тоже отказ
    const other = await t.otpVerify(req.body.challengeId as string, code, freshDevice(), ip);
    expect([409, 422]).toContain(other.status);
    // аварийный код израсходован: новый запрос идёт обычным путём (SMS), другой challengeId
    t.tick(61_000);
    const before = await smsCount();
    const normal = await t.otpRequest(target.phone, deviceKey, ip);
    expect(normal.status).toBe(202);
    expect(normal.body.challengeId).not.toBe(req.body.challengeId);
    await t.drainSms();
    expect(await smsCount()).toBe(before + 1);
    const used = await t.pool.query(
      `SELECT 1 FROM audit_logs WHERE action = 'auth.emergency_code.used' AND entity_id = $1`,
      [target.userId],
    );
    expect(used.rows).toHaveLength(1);
  });

  it('T-ADMIN-010 (г, D2): привязка к первому устройству — request/verify с другого устройства → 409 DEVICE_MISMATCH', async () => {
    const target = await t.seedUser({ role: 'seller' });
    const { code } = await issueCode(target.userId);
    const d1 = freshDevice();
    const ip = freshIp();
    const first = await t.otpRequest(target.phone, d1, ip);
    expect(first.status).toBe(202);
    const intruder = await t.otpRequest(target.phone, freshDevice(), freshIp());
    expect(intruder.status).toBe(409);
    expect(intruder.body.code).toBe('DEVICE_MISMATCH');
    const v2 = await t.otpVerify(first.body.challengeId as string, code, freshDevice(), ip);
    expect(v2.status).toBe(409);
    expect(v2.body.code).toBe('DEVICE_MISMATCH');
    // законное устройство по-прежнему входит; PIN не задан → set_pin, без UNLOCK_REQUIRED
    const ok = await t.otpVerify(first.body.challengeId as string, code, d1, ip, WINDOWS);
    expect(ok.status).toBe(200);
    expect(ok.body.nextStep).toBe('set_pin');
    expect(claims(ok.body.accessToken as string).amr).toEqual(['admin_code']);
  });

  it('09 §6.13 (TTL 10 мин): через 10 мин код не принимается (OTP_EXPIRED), а request идёт обычным путём', async () => {
    const target = await t.seedUser({ role: 'seller' });
    const { code } = await issueCode(target.userId);
    const deviceKey = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(target.phone, deviceKey, ip);
    expect(req.status).toBe(202);
    t.tick(10 * 60_000 + 1_000);
    const late = await t.otpVerify(req.body.challengeId as string, code, deviceKey, ip);
    expect(late.status).toBe(422);
    expect(late.body.code).toBe('OTP_EXPIRED');

    const target2 = await t.seedUser({ role: 'seller' });
    const issued2 = await issueCode(target2.userId);
    t.tick(10 * 60_000 + 1_000);
    const before = await smsCount();
    const r = await t.otpRequest(target2.phone, freshDevice(), freshIp());
    expect(r.status).toBe(202);
    await t.drainSms();
    expect(await smsCount()).toBe(before + 1); // живого аварийного кода нет — обычная SMS
    expect(issued2.code).toMatch(/^\d{6}$/);
  });

  it('09 §6.13 (PIN заблокирован): PIN заблокирован — достаточно кода: PIN_LOCKED снимается, UNLOCK_REQUIRED нет', async () => {
    const target = await t.seedUser({ role: 'seller' });
    await t.setPin(target.userId, PIN);
    await t.pool.query(
      `UPDATE app_pins SET failed_attempts = 5, locked_until = now() + interval '365 days' WHERE user_id = $1`,
      [target.userId],
    );
    const { code } = await issueCode(target.userId);
    const deviceKey = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(target.phone, deviceKey, ip);
    const v = await t.otpVerify(req.body.challengeId as string, code, deviceKey, ip);
    expect(v.status).toBe(200);
    const pin = (await t.pool.query<JsonBody>('SELECT * FROM app_pins WHERE user_id = $1', [target.userId])).rows[0];
    expect(pin).toMatchObject({ failed_attempts: 0, locked_until: null });
    expect((await t.bearer('get', '/probe/work', v.body.accessToken as string, deviceKey)).status).toBe(200);
  });

  it('аварийный код не открывает регистрацию и чужой аккаунт: заблокированный сотрудник → 403', async () => {
    const target = await t.seedUser({ role: 'seller' });
    const { code } = await issueCode(target.userId);
    await t.pool.query(`UPDATE users SET status = 'blocked' WHERE id = $1`, [target.userId]);
    const deviceKey = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(target.phone, deviceKey, ip);
    expect(req.status).toBe(202);
    const v = await t.otpVerify(req.body.challengeId as string, code, deviceKey, ip);
    expect(v.status).toBe(403);
    expect(v.body.code).toBe('FORBIDDEN');
  });
});

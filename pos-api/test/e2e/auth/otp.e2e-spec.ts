import { createHmac } from 'node:crypto';
import { RegistrationTokenService } from '../../../src/auth/login/registration-token.service.js';
import { OtpCircuitBreaker } from '../../../src/auth/otp/otp-circuit-breaker.js';
import { OTP_HMAC_SECRET_RING } from '../../../src/common/crypto/crypto.module.js';
import { OtpHmacService } from '../../../src/common/crypto/otp-hmac.service.js';
import type { SecretRing } from '../../../src/common/crypto/secret-ring.js';
import { AuthE2e, freshDevice, freshIp, freshPhone, WINDOWS } from './support/auth-e2e.js';

/**
 * RM-D-001 / RM-D-014 / RM-D-017 — e2e OTP на embedded PostgreSQL 17 (12 T-AUTH-001…007, 011, 013…017, 020…022,
 * 026…028, 036, 040, 044, 045). SMS — FakeSmsGateway (dev_outbox), часы — FixedClock.
 */
describe('auth/otp e2e (RM-D-001, RM-D-014, RM-D-017)', () => {
  const t = new AuthE2e();

  beforeAll(async () => {
    await t.start('auth_otp_e2e', {
      AUTH_OTP_TEST_MODE: 'true',
      AUTH_OTP_TEST_CODE: '246810',
      AUTH_OTP_TEST_PHONES: '+996700000001',
    });
  });
  afterAll(async () => {
    await t.stop();
  });
  beforeEach(() => {
    t.tick();
    t.app.get(OtpCircuitBreaker).reset();
  });

  it('T-AUTH-001: вход существующего active-пользователя → 202, затем 200 authenticated с токенами и Me', async () => {
    const { userId, phone } = await t.seedUser({ role: 'seller' });
    await t.setPin(userId, '482913');
    const r = await t.login(phone);
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({
      status: 'authenticated',
      tokenType: 'Bearer',
      accessExpiresIn: 900,
      nextStep: 'none',
      biometricRefreshOffered: true,
      user: { id: userId, kind: 'staff', status: 'active', roles: ['seller'], security: { pinSet: true } },
    });
    expect(r.body.refreshToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(r.body.user.permissions).toContain('order.create');
    expect(r.body.roleSource).toBeUndefined();
    const me = await t.bearer('get', '/auth/sessions', r.body.accessToken, r.deviceKey);
    expect(me.status).toBe(200);
    expect(me.body.items).toHaveLength(1);
    expect(me.body.items[0]).toMatchObject({ id: r.body.sid, isCurrent: true, platform: 'android', kind: 'standard' });
    const actions = await t.auditActions({ actorUserId: userId });
    expect(actions).toEqual(expect.arrayContaining(['auth.otp.verified', 'auth.login']));
  });

  it('T-SEC-006, T-AUTH-011/T-AUTH-045: ответ request одинаков для существующего, приглашённого и нового номера', async () => {
    const existing = await t.seedUser();
    const invited = freshPhone();
    await t.invite(invited, 'cashier', 'Приглашённый Кассир', new Date(t.clock.now().getTime() + 86_400_000));
    const shapes: string[] = [];
    for (const phone of [existing.phone, invited, freshPhone()]) {
      const r = await t.otpRequest(phone, freshDevice(), freshIp());
      expect(r.status).toBe(202);
      expect(Object.keys(r.body).sort()).toEqual(
        ['challengeId', 'codeLength', 'deliveryHint', 'otpTtlSec', 'phoneMasked', 'resendAfterSec'].sort(),
      );
      expect(r.body).toMatchObject({ resendAfterSec: 60, otpTtlSec: 300, codeLength: 6, deliveryHint: 'sms' });
      expect(r.body.phoneMasked).toMatch(/^\+996 7\*\* \*\*\* \*\d\d$/);
      shapes.push(JSON.stringify({ ...r.body, challengeId: 'x', phoneMasked: 'x' }));
    }
    expect(new Set(shapes).size).toBe(1);
  });

  it('T-AUTH-002/RM-D-017 п.1: номер без аккаунта и приглашения → registration_required (одноразовый токен 15 мин)', async () => {
    const r = await t.login(freshPhone());
    expect(r.status).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(['phoneMasked', 'registrationExpiresIn', 'registrationToken', 'status']);
    expect(r.body).toMatchObject({ status: 'registration_required', registrationExpiresIn: 900 });
    const row = await t.pool.query(
      'SELECT registration_token_hash, registration_token_expires_at, status FROM otp_challenges WHERE id = $1',
      [r.challengeId],
    );
    expect(row.rows[0].status).toBe('verified');
    expect(row.rows[0].registration_token_hash).toHaveLength(32);
    const users = await t.pool.query(
      'SELECT 1 FROM users WHERE id IN (SELECT user_id FROM otp_challenges WHERE id = $1)',
      [r.challengeId],
    );
    expect(users.rowCount).toBe(0);
  });

  it('T-AUTH-044/RM-D-017 п.2 (AC-API-181): номер с приглашением → staff с ролью и ФИО приглашения, accepted, set_pin, pin_not_set', async () => {
    const phone = freshPhone();
    const invId = await t.invite(
      phone,
      'seller',
      'Иванов Иван Иванович',
      new Date(t.clock.now().getTime() + 86_400_000),
    );
    const r = await t.login(phone);
    expect(r.status).toBe(200);
    expect(r.body.registrationToken).toBeUndefined();
    expect(r.body).toMatchObject({
      status: 'authenticated',
      roleSource: 'invitation',
      nextStep: 'set_pin',
      biometricRefreshOffered: false,
      user: { kind: 'staff', status: 'active', roles: ['seller'], security: { pinSet: false } },
    });
    const userId = r.body.user.id as string;
    const inv = await t.pool.query('SELECT status, accepted_user_id FROM user_invitations WHERE id = $1', [invId]);
    expect(inv.rows[0]).toEqual({ status: 'accepted', accepted_user_id: userId });
    const prof = await t.pool.query('SELECT full_name, birth_year FROM user_profiles WHERE user_id = $1', [userId]);
    expect(prof.rows[0]).toEqual({ full_name: 'Иванов Иван Иванович', birth_year: null });
    const u = await t.pool.query('SELECT invitation_id, phone_verified_at FROM users WHERE id = $1', [userId]);
    expect(u.rows[0].invitation_id).toBe(invId);
    expect(u.rows[0].phone_verified_at).not.toBeNull();
    const audit = await t.auditActions({ entityId: userId });
    expect(audit).toContain('user.created');
    // До установки PIN: /auth/* разрешены, прочее → 403 FORBIDDEN reason pin_not_set (08 §4.1.2).
    const own = await t.bearer('get', '/auth/sessions', r.body.accessToken, r.deviceKey);
    expect(own.status).toBe(200);
    const other = await t.bearer('get', '/probe/work', r.body.accessToken, r.deviceKey);
    expect(other.status).toBe(403);
    expect(other.body).toMatchObject({ code: 'FORBIDDEN', reason: 'pin_not_set' });
    await t.setPin(userId, '502817');
    const after = await t.bearer('get', '/probe/work', r.body.accessToken, r.deviceKey);
    expect(after.status).toBe(200);
  });

  it('T-AUTH-045: отозванное и истёкшее приглашение не создают staff — ветка регистрации клиента', async () => {
    const revoked = freshPhone();
    await t.invite(
      revoked,
      'cashier',
      'Отозванный Сотрудник',
      new Date(t.clock.now().getTime() + 86_400_000),
      'revoked',
    );
    const expired = freshPhone();
    await t.invite(expired, 'cashier', 'Истёкший Сотрудник', new Date(t.clock.now().getTime() - 1000));
    for (const phone of [revoked, expired]) {
      const r = await t.login(phone);
      expect(r.body.status).toBe('registration_required');
      const u = await t.pool.query('SELECT 1 FROM users WHERE phone_e164 = $1', [phone]);
      expect(u.rowCount).toBe(0);
    }
  });

  it('pending_activation (CUSTOMER_SELF_SERVICE=false): токены ограниченной сессии', async () => {
    const { phone } = await t.seedUser({ kind: 'customer', status: 'pending_activation' });
    const r = await t.login(phone);
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ status: 'pending_activation', user: { status: 'pending_activation' } });
    expect(r.body.accessToken).toBeTruthy();
    expect(r.body.user.permissions).toEqual(['profile.manage.own', 'session.manage.own', 'settings.public.read']);
  });

  it('T-SEC-001, T-AUTH-003 + T-AUTH-006 (RM-D-001 п.2): неверный код → 422 attemptsLeft; 6-я попытка → 423 OTP_LOCKED; аккаунт не блокируется', async () => {
    const { userId, phone } = await t.seedUser();
    const dev = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(phone, dev, ip);
    const code = await t.codeFor(req.body.challengeId);
    const wrong = code === '000000' ? '111111' : '000000';
    for (let i = 1; i <= 5; i++) {
      const v = await t.otpVerify(req.body.challengeId, wrong, dev, ip);
      expect(v.status).toBe(422);
      expect(v.body).toMatchObject({ code: 'OTP_INVALID', attemptsLeft: 5 - i });
    }
    const sixth = await t.otpVerify(req.body.challengeId, code, dev, ip);
    expect(sixth.status).toBe(423);
    expect(sixth.body.code).toBe('OTP_LOCKED');
    expect(typeof sixth.body.retryAfter).toBe('number');
    const row = await t.pool.query('SELECT status, attempts FROM otp_challenges WHERE id = $1', [req.body.challengeId]);
    expect(row.rows[0]).toEqual({ status: 'locked', attempts: 5 });
    const u = await t.pool.query('SELECT status FROM users WHERE id = $1', [userId]);
    expect(u.rows[0].status).toBe('active');
    expect(await t.auditActions({ entityId: req.body.challengeId })).toEqual(
      expect.arrayContaining(['auth.otp.sent', 'auth.otp.failed', 'auth.otp.locked']),
    );
  });

  it('T-SEC-003, T-AUTH-004: истёкший код (часы + TTL) → 422 OTP_EXPIRED, status=expired', async () => {
    const { phone } = await t.seedUser();
    const dev = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(phone, dev, ip);
    const code = await t.codeFor(req.body.challengeId);
    t.tick(301_000);
    const v = await t.otpVerify(req.body.challengeId, code, dev, ip);
    expect(v.status).toBe(422);
    expect(v.body.code).toBe('OTP_EXPIRED');
    const row = await t.pool.query('SELECT status FROM otp_challenges WHERE id = $1', [req.body.challengeId]);
    expect(row.rows[0].status).toBe('expired');
  });

  it('T-SEC-002, T-AUTH-005 (RM-D-001 п.4–5): повтор кода ≤ 60 с — ротация той же сессии; повтор повтора, > 60 с и другое устройство — отказ', async () => {
    const { phone } = await t.seedUser();
    const first = await t.login(phone);
    expect(first.status).toBe(200);
    // (б) другой X-Device-Id → 409 DEVICE_MISMATCH
    const other = await t.otpVerify(first.challengeId, first.code, freshDevice(), first.ip);
    expect(other.status).toBe(409);
    expect(other.body.code).toBe('DEVICE_MISMATCH');
    // (в) ≤ 60 с, тот же D1, сессия не использована → 200, тот же sid, новые токены
    t.tick(10_000);
    const replay = await t.otpVerify(first.challengeId, first.code, first.deviceKey, first.ip);
    expect(replay.status).toBe(200);
    expect(replay.body.sid).toBe(first.body.sid);
    expect(replay.body.refreshToken).not.toBe(first.body.refreshToken);
    expect(replay.body.accessToken).not.toBe(first.body.accessToken);
    const count = await t.pool.query('SELECT count(*)::int AS n FROM sessions WHERE created_from_challenge_id = $1', [
      first.challengeId,
    ]);
    expect(count.rows[0].n).toBe(1);
    // прежний refresh → reuse (вытеснен), прежний access — в denylist
    const oldAccess = await t.bearer('get', '/auth/sessions', first.body.accessToken, first.deviceKey);
    expect(oldAccess.status).toBe(401);
    const deniedJti = await t.pool.query(
      `SELECT count(*)::int AS n FROM token_denylist WHERE token_kind = 'access' AND session_id = $1`,
      [first.body.sid],
    );
    expect(deniedJti.rows[0].n).toBe(1);
    // (г) повтор повтора → OTP_EXPIRED
    const again = await t.otpVerify(first.challengeId, first.code, first.deviceKey, first.ip);
    expect(again.status).toBe(422);
    expect(again.body.code).toBe('OTP_EXPIRED');
    // (а) > 60 с → OTP_EXPIRED (на новом челлендже)
    t.tick(61_000);
    const second = await t.login(phone);
    t.tick(61_000);
    const late = await t.otpVerify(second.challengeId, second.code, second.deviceKey, second.ip);
    expect(late.status).toBe(422);
    expect(late.body.code).toBe('OTP_EXPIRED');
    // (д) ≤ 60 с, но сессия уже использована → OTP_EXPIRED
    t.tick(61_000);
    const third = await t.login(phone);
    const used = await t.bearer('get', '/auth/sessions', third.body.accessToken, third.deviceKey);
    expect(used.status).toBe(200);
    const usedReplay = await t.otpVerify(third.challengeId, third.code, third.deviceKey, third.ip);
    expect(usedReplay.status).toBe(422);
    expect(usedReplay.body.code).toBe('OTP_EXPIRED');
  });

  it('T-AUTH-005: повтор ветки регистрации ≤ 60 с → новый registration_token, прежний перестаёт совпадать', async () => {
    const r = await t.login(freshPhone());
    const replay = await t.otpVerify(r.challengeId, r.code, r.deviceKey, r.ip);
    expect(replay.status).toBe(200);
    expect(replay.body.status).toBe('registration_required');
    expect(replay.body.registrationToken).not.toBe(r.body.registrationToken);
    const denied = await t.pool.query<{ reason: string }>(
      `SELECT reason FROM token_denylist WHERE token_kind = 'registration'`,
    );
    expect(denied.rows.map((x) => x.reason)).toContain('revoked');
  });

  it('registration_token (для RM-D-004): погашается один раз; другое устройство и > 15 мин → REGISTRATION_TOKEN_INVALID', async () => {
    const svc = t.app.get(RegistrationTokenService);
    const r = await t.login(freshPhone());
    const token = r.body.registrationToken as string;
    await expect(
      t.fdb.db.transaction((tx) => svc.consume(token, { deviceKey: freshDevice() }, tx)),
    ).rejects.toMatchObject({
      code: 'REGISTRATION_TOKEN_INVALID',
    });
    const used = await t.fdb.db.transaction((tx) => svc.consume(token, { deviceKey: r.deviceKey }, tx));
    expect(used).toMatchObject({ challengeId: r.challengeId, deviceKey: r.deviceKey });
    expect(used.phoneE164).toMatch(/^\+99677\d{7}$/);
    await expect(t.fdb.db.transaction((tx) => svc.consume(token, {}, tx))).rejects.toMatchObject({
      code: 'REGISTRATION_TOKEN_INVALID',
    });
    const row = await t.pool.query(`SELECT reason, token_kind FROM token_denylist WHERE jti = $1`, [used.jti]);
    expect(row.rows[0]).toEqual({ reason: 'used', token_kind: 'registration' });
    t.tick(61_000);
    const late = await t.login(freshPhone());
    t.tick(15 * 60_000 + 6_000);
    await expect(
      t.fdb.db.transaction((tx) => svc.consume(late.body.registrationToken as string, {}, tx)),
    ).rejects.toMatchObject({ code: 'REGISTRATION_TOKEN_INVALID' });
    await expect(t.fdb.db.transaction((tx) => svc.consume('not-a-jwt', {}, tx))).rejects.toMatchObject({
      code: 'REGISTRATION_TOKEN_INVALID',
    });
  });

  it('T-AUTH-020/T-AUTH-028: порядок проверок 404 → DEVICE_MISMATCH (попытка учтена) → OTP_INVALID', async () => {
    const { phone } = await t.seedUser();
    const dev = freshDevice();
    const ip = freshIp();
    const nf = await t.otpVerify('0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55', '123456', dev, ip);
    expect(nf.status).toBe(404);
    expect(nf.body.code).toBe('NOT_FOUND');
    const req = await t.otpRequest(phone, dev, ip);
    const code = await t.codeFor(req.body.challengeId);
    const mm = await t.otpVerify(req.body.challengeId, code, freshDevice(), ip);
    expect(mm.status).toBe(409);
    expect(mm.body.code).toBe('DEVICE_MISMATCH');
    const row = await t.pool.query('SELECT attempts, status FROM otp_challenges WHERE id = $1', [req.body.challengeId]);
    expect(row.rows[0]).toEqual({ attempts: 1, status: 'sent' });
    const bad = await t.otpVerify(req.body.challengeId, code === '999999' ? '999998' : '999999', dev, ip);
    expect(bad.body).toMatchObject({ code: 'OTP_INVALID', attemptsLeft: 3 });
    const ok = await t.otpVerify(req.body.challengeId, code, dev, ip);
    expect(ok.status).toBe(200);
  });

  it('T-AUTH-013: в otp_challenges только HMAC-SHA-256(secret, challenge_id:code) и pepper_version', async () => {
    const phone = freshPhone();
    const req = await t.otpRequest(phone, freshDevice(), freshIp());
    const code = await t.codeFor(req.body.challengeId);
    const row = await t.pool.query('SELECT * FROM otp_challenges WHERE id = $1', [req.body.challengeId]);
    const ring = t.app.get<SecretRing>(OTP_HMAC_SECRET_RING);
    const expected = createHmac('sha256', ring.get(row.rows[0].pepper_version)!)
      .update(`${req.body.challengeId}:${code}`)
      .digest();
    expect(Buffer.compare(row.rows[0].code_hmac, expected)).toBe(0);
    for (const v of Object.values(row.rows[0])) {
      if (typeof v === 'string') expect(v.includes(code)).toBe(false);
    }
  });

  it('T-SEC-005, T-SEC-025, T-AUTH-014/T-AUTH-015 (RM-D-001 п.3): cooldown 60 с → 429; 4-я отправка за 15 мин → 429 OTP_RATE_LIMITED + Retry-After', async () => {
    t.alignClock(15 * 60_000);
    const phone = freshPhone();
    const dev = freshDevice();
    const ip = freshIp();
    const r1 = await t.otpRequest(phone, dev, ip);
    expect(r1.status).toBe(202);
    t.tick(30_000);
    const early = await t.otpRequest(phone, dev, ip);
    expect(early.status).toBe(429);
    expect(early.body).toMatchObject({ code: 'OTP_RATE_LIMITED' });
    expect(early.body.retryAfter).toBeGreaterThan(0);
    expect(early.body.retryAfter).toBeLessThanOrEqual(30);
    expect(early.headers['retry-after']).toBe(String(early.body.retryAfter));
    t.tick(31_000);
    const r2 = await t.otpRequest(phone, dev, ip);
    expect(r2.status).toBe(202);
    const old = await t.pool.query('SELECT status FROM otp_challenges WHERE id = $1', [r1.body.challengeId]);
    expect(old.rows[0].status).toBe('superseded');
    t.tick(61_000);
    expect((await t.otpRequest(phone, dev, ip)).status).toBe(202);
    t.tick(61_000);
    const fourth = await t.otpRequest(phone, dev, ip);
    expect(fourth.status).toBe(429);
    expect(fourth.body.code).toBe('OTP_RATE_LIMITED');
    expect(Number(fourth.headers['retry-after'])).toBeGreaterThan(0);
    const audit = await t.pool.query(
      `SELECT count(*)::int AS n FROM audit_logs WHERE action = 'auth.otp.rate_limited'`,
    );
    expect(audit.rows[0].n).toBeGreaterThan(0);
  });

  it('T-AUTH-016: пауза номера 30 мин после 3 заблокированных кодов подряд → 423 OTP_LOCKED', async () => {
    const phone = freshPhone();
    for (let k = 0; k < 3; k++) {
      t.tick(16 * 60_000); // новое окно 15 мин
      const dev = freshDevice();
      const ip = freshIp();
      const req = await t.otpRequest(phone, dev, ip);
      expect(req.status).toBe(202);
      const code = await t.codeFor(req.body.challengeId);
      for (let i = 0; i < 5; i++)
        await t.otpVerify(req.body.challengeId, code === '000000' ? '111111' : '000000', dev, ip);
    }
    t.tick(61_000);
    const paused = await t.otpRequest(phone, freshDevice(), freshIp());
    expect(paused.status).toBe(423);
    expect(paused.body.code).toBe('OTP_LOCKED');
    expect(paused.body.retryAfter).toBeGreaterThan(25 * 60);
    t.tick(30 * 60_000);
    expect((await t.otpRequest(phone, freshDevice(), freshIp())).status).toBe(202);
  });

  it('T-AUTH-016: лимит 10 / сутки на номер', async () => {
    t.alignClock(24 * 3600_000, 60_000);
    const phone = freshPhone();
    let last = 0;
    for (let i = 1; i <= 11; i++) {
      t.tick(16 * 60_000);
      last = (await t.otpRequest(phone, freshDevice(), freshIp())).status;
      if (i <= 10) expect(last).toBe(202);
    }
    expect(last).toBe(429);
  });

  it('T-AUTH-017: лимиты IP (20 / 10 мин) и устройства (5 / 10 мин) → 429 RATE_LIMITED без раскрытия номера', async () => {
    const ip = freshIp();
    for (let i = 0; i < 20; i++) expect((await t.otpRequest(freshPhone(), freshDevice(), ip)).status).toBe(202);
    const ipDenied = await t.otpRequest(freshPhone(), freshDevice(), ip);
    expect(ipDenied.status).toBe(429);
    expect(ipDenied.body.code).toBe('RATE_LIMITED');
    t.tick(11 * 60_000);
    const dev = freshDevice();
    for (let i = 0; i < 5; i++) expect((await t.otpRequest(freshPhone(), dev, freshIp())).status).toBe(202);
    const devDenied = await t.otpRequest(freshPhone(), dev, freshIp());
    expect(devDenied.status).toBe(429);
    expect(devDenied.body.code).toBe('RATE_LIMITED');
  });

  // 12: T-FAIL-010 (SMSPro недоступен: нейтральный ответ, circuit-breaker)
  it('T-SEC-050, T-AUTH-007/T-AUTH-021: ошибка SMSPro (status 2/4) → 202, статус failed, challenge failed_delivery, квота номера возвращена, circuit-breaker', async () => {
    for (const phone of ['+996700000002', '+996700000004']) {
      t.app.get(OtpCircuitBreaker).reset();
      t.tick(16 * 60_000);
      const dev = freshDevice();
      const ip = freshIp();
      const r = await t.otpRequest(phone, dev, ip);
      expect(r.status).toBe(202);
      await t.drainSms();
      const st = await t.http.get(`/api/v1/auth/otp/challenges/${r.body.challengeId}`).set('X-Device-Id', dev);
      expect(st.status).toBe(200);
      expect(st.body).toMatchObject({
        challengeId: r.body.challengeId,
        delivery: 'failed',
        resendAfterSec: 0,
        channel: 'sms',
      });
      expect(JSON.stringify(st.body)).not.toContain(phone.slice(4));
      const row = await t.pool.query('SELECT status FROM otp_challenges WHERE id = $1', [r.body.challengeId]);
      expect(row.rows[0].status).toBe('failed_delivery');
      const sms = await t.pool.query('SELECT status, outcome FROM sms_outbox WHERE otp_challenge_id = $1', [
        r.body.challengeId,
      ]);
      expect(sms.rows[0].status).toBe('failed');
      // circuit-breaker открыт (CONFIG_ERROR/INSUFFICIENT_FUNDS) → синхронный нейтральный 503
      const next = await t.otpRequest(freshPhone(), freshDevice(), freshIp());
      expect(next.status).toBe(503);
      expect(next.body.code).toBe('SMS_PROVIDER_ERROR');
    }
  });

  it('T-AUTH-021 (RM-D-014 п.1): статус доставки — queued/sent без ПДн; чужое устройство и неизвестный id → 404', async () => {
    const phone = freshPhone();
    const dev = freshDevice();
    const r = await t.otpRequest(phone, dev, freshIp());
    await t.drainSms();
    const ok = await t.http.get(`/api/v1/auth/otp/challenges/${r.body.challengeId}`).set('X-Device-Id', dev);
    expect(ok.status).toBe(200);
    expect(ok.body.delivery).toBe('sent');
    expect(ok.body.resendAfterSec).toBeGreaterThan(0);
    expect(JSON.stringify(ok.body)).not.toContain(phone.slice(-4));
    const foreign = await t.http
      .get(`/api/v1/auth/otp/challenges/${r.body.challengeId}`)
      .set('X-Device-Id', freshDevice());
    expect(foreign.status).toBe(404);
    const unknown = await t.http
      .get('/api/v1/auth/otp/challenges/0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55')
      .set('X-Device-Id', dev);
    expect(unknown.status).toBe(404);
    const bad = await t.http.get('/api/v1/auth/otp/challenges/not-a-uuid').set('X-Device-Id', dev);
    expect(bad.status).toBe(400);
  });

  it('T-SEC-007, T-AUTH-022: тестовый режим — номер allowlist получает фиксированный код без SMS', async () => {
    const dev = freshDevice();
    const ip = freshIp();
    const r = await t.otpRequest('+996700000001', dev, ip);
    expect(r.status).toBe(202);
    // D AU-03: и в тестовом режиме тело — ровно поля AuthOtpRequestResponse, без devCode и кода (09 §4.6, R1)
    expect(Object.keys(r.body).sort()).toEqual(
      ['challengeId', 'codeLength', 'deliveryHint', 'otpTtlSec', 'phoneMasked', 'resendAfterSec'].sort(),
    );
    expect(r.body).not.toHaveProperty('devCode');
    expect(JSON.stringify(r.body)).not.toContain('246810');
    const row = await t.pool.query('SELECT sms_outbox_id, status FROM otp_challenges WHERE id = $1', [
      r.body.challengeId,
    ]);
    expect(row.rows[0]).toEqual({ sms_outbox_id: null, status: 'sent' });
    const v = await t.otpVerify(r.body.challengeId, '246810', dev, ip);
    expect(v.status).toBe(200);
    expect(v.body.status).toBe('registration_required');
  });

  it('T-AUTH-026: нормализация номера (0…, 996…, пробелы); не-KG и стационарные → 400 phone_e164; purpose ≠ login_or_register → 400', async () => {
    const forms = ['0 (700) 123-456', '996700123457', '+996 700 123 458'];
    for (const phone of forms) {
      t.tick();
      expect((await t.otpRequest(phone, freshDevice(), freshIp())).status).toBe(202);
    }
    const stored = await t.pool.query<{ phone_e164: string }>(
      `SELECT phone_e164 FROM otp_challenges WHERE phone_e164 LIKE '+99670012345%'`,
    );
    expect(stored.rows.map((x) => x.phone_e164).sort()).toEqual(['+996700123456', '+996700123457', '+996700123458']);
    for (const phone of ['+79161234567', '+996312123456', '12345']) {
      const r = await t.otpRequest(phone, freshDevice(), freshIp());
      expect(r.status).toBe(400);
      expect(r.body.errors[0]).toMatchObject({ field: 'phone', rule: 'phone_e164' });
    }
    const login = await t.otpRequest(freshPhone(), freshDevice(), freshIp(), { purpose: 'login' });
    expect(login.status).toBe(400);
    expect(login.body.errors[0]).toMatchObject({ field: 'purpose', rule: 'purpose' });
    const noDevice = await t.http
      .post('/api/v1/auth/otp/request')
      .send({ phone: freshPhone(), purpose: 'login_or_register' });
    expect(noDevice.status).toBe(400);
    expect(noDevice.body.errors[0]).toMatchObject({ field: 'X-Device-Id', rule: 'uuid' });
  });

  it('T-SESS-018, T-AUTH-027: заблокированный пользователь — до верного кода нейтрально, после — 403 FORBIDDEN', async () => {
    const { phone } = await t.seedUser({ status: 'blocked' });
    const dev = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(phone, dev, ip);
    expect(req.status).toBe(202);
    const code = await t.codeFor(req.body.challengeId);
    const wrong = await t.otpVerify(req.body.challengeId, code === '000000' ? '111111' : '000000', dev, ip);
    expect(wrong.body.code).toBe('OTP_INVALID');
    const right = await t.otpVerify(req.body.challengeId, code, dev, ip);
    expect(right.status).toBe(403);
    expect(right.body.code).toBe('FORBIDDEN');
  });

  it('T-AUTH-036: attestation игнорируется; Windows-вход: biometricRefreshOffered=false', async () => {
    const { userId, phone } = await t.seedUser();
    await t.setPin(userId, '682014');
    const dev = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(phone, dev, ip, { attestation: 'garbage-token-value' });
    expect(req.status).toBe(202);
    const code = await t.codeFor(req.body.challengeId);
    const v = await t.otpVerify(req.body.challengeId, code, dev, ip, WINDOWS);
    expect(v.body).toMatchObject({ status: 'authenticated', biometricRefreshOffered: false });
    expect(v.body.user.security.biometricsPlatform).toBe('windows_hello_gate');
    expect(t.logs.text).not.toContain('garbage-token-value');
  });

  it('T-SEC-029, T-AUTH-040 (AC-AUTH-012): коды, выданные FakeSmsGateway, не встречаются в логах и audit_logs', async () => {
    const codes = await t.pool.query<{ text: string }>('SELECT text FROM dev_outbox');
    const all = codes.rows.map((r) => /(\d{6})/.exec(r.text)?.[1]).filter((c): c is string => c !== undefined);
    expect(all.length).toBeGreaterThan(10);
    const audit = await t.pool.query<{ j: string }>(
      `SELECT (to_jsonb(a) - 'row_hash' - 'prev_hash')::text AS j FROM audit_logs a`,
    );
    const auditText = audit.rows.map((r) => r.j).join('\n');
    for (const c of all) {
      // Отдельное 6-значное число (не часть дробных секунд, UUID, IP или более длинного числа).
      const re = new RegExp(`(?<![\\d.:a-f-])${c}(?![\\d])`);
      expect(re.test(t.logs.text)).toBe(false);
      expect(re.test(auditText)).toBe(false);
    }
    expect(t.logs.text).not.toMatch(/\+99677\d{7}/); // полный номер не логируется
  });

  it('G-KI-16 (R1-N-01, F-KI-16): HMAC-псевдоним номера с фрагментом «996»+9 цифр — не сырой телефон: 202, а не 500', async () => {
    // Первопричина нестабильности: проверка «сырой телефон в subject» RateLimitService искала `\+?996\d{9}` в любом
    // месте строки и срабатывала на hex-псевдоним номера (64 hex, секрет случайный на прогон) с вероятностью ≈ 1.7e-4
    // на номер → RangeError → 500 на `POST /auth/otp/request` в случайном тесте (в F — :588, в G — :61).
    const hmac = t.app.get(OtpHmacService);
    let phone = '';
    for (let n = 0; n < 2_000_000 && phone === ''; n++) {
      const candidate = `+99655${String(n).padStart(7, '0')}`;
      if (/\+?996\d{9}/.test(hmac.pseudonym('phone', candidate))) phone = candidate;
    }
    expect(phone).not.toBe('');
    const r = await t.otpRequest(phone, freshDevice(), freshIp());
    expect(r.status, JSON.stringify(r.body)).toBe(202);
    const counters = await t.pool.query<{ n: number }>(
      `SELECT count(*)::int AS n FROM rate_limit_counters WHERE subject = $1`,
      [hmac.pseudonym('phone', phone)],
    );
    expect(counters.rows[0].n).toBe(2); // otp_phone_15m и otp_phone_24h — квота учтена по псевдониму
  });

  it('T-SEC-008 (класс A, SEC-062, SEC-078): HMAC кода и текст SMS не встречаются в логах и аудите (метрик и трасс в R1 нет — только pino)', async () => {
    const rows = await t.pool.query<{ code_hmac: Buffer }>('SELECT code_hmac FROM otp_challenges');
    expect(rows.rows.length).toBeGreaterThan(10);
    const sms = await t.pool.query<{ text: string }>('SELECT text FROM dev_outbox');
    const audit = await t.pool.query<{ j: string }>(
      `SELECT (to_jsonb(a) - 'row_hash' - 'prev_hash')::text AS j FROM audit_logs a`,
    );
    const auditText = audit.rows.map((r) => r.j).join('\n');
    for (const r of rows.rows) {
      for (const enc of [
        r.code_hmac.toString('hex'),
        r.code_hmac.toString('base64'),
        r.code_hmac.toString('base64url'),
      ]) {
        expect(t.logs.text).not.toContain(enc);
        expect(auditText).not.toContain(enc);
      }
    }
    // текст SMS (шаблон SMS_OTP_TEMPLATE с кодом) — только в dev_outbox FakeSmsGateway
    for (const m of sms.rows) {
      expect(t.logs.text).not.toContain(m.text);
      expect(auditText).not.toContain(m.text);
    }
    expect(t.logs.text).not.toContain('Kod:');
    expect(auditText).not.toContain('Kod:');
  });
});

describe('auth/otp e2e: глобальный лимит OTP_GLOBAL_PER_MIN (T-AUTH-018)', () => {
  const t = new AuthE2e();
  beforeAll(async () => {
    await t.start('auth_otp_global', { OTP_GLOBAL_PER_MIN: '5' });
  });
  afterAll(async () => {
    await t.stop();
  });

  it('6-й запрос за минуту на разные номера → нейтральный 503 SMS_PROVIDER_ERROR, circuit-breaker 5 мин', async () => {
    for (let i = 0; i < 5; i++) expect((await t.otpRequest(freshPhone(), freshDevice(), freshIp())).status).toBe(202);
    const denied = await t.otpRequest(freshPhone(), freshDevice(), freshIp());
    expect(denied.status).toBe(503);
    expect(denied.body.code).toBe('SMS_PROVIDER_ERROR');
    expect(Object.keys(denied.body)).not.toContain('reason');
    t.tick(2 * 60_000);
    expect((await t.otpRequest(freshPhone(), freshDevice(), freshIp())).status).toBe(503);
    t.tick(4 * 60_000);
    expect((await t.otpRequest(freshPhone(), freshDevice(), freshIp())).status).toBe(202);
  });
});

import { createPrivateKey, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decodeJwt, SignJWT, UnsecuredJWT } from 'jose';
import { JWT_AUDIENCE, JWT_ISSUER } from '../../../src/common/auth/jwt.service.js';
import { pemPair, publicSet } from '../../foundation/support/keys.js';
import { ANDROID, AuthE2e, freshDevice, freshIp, type JsonBody, type LoginResult } from './support/auth-e2e.js';

/**
 * Ревью D-MJ-02 (RM-D-011 п. 1): недостающие P1/P2 сценарии 12 модуля auth на embedded PostgreSQL 17 —
 * T-SESS-001 (проверка access-JWT end-to-end), T-SESS-002 (TTL 15 мин), T-AUTH-019 (счётчики лимитов
 * переживают перезапуск pos-api), T-AUTH-042 (вход клиента), T-SESS-017 / T-SEC-038 (полнота аудита `auth.*`:
 * `request_id`, маска телефона, без OTP/токенов/HMAC).
 */
describe('auth e2e: токены, перезапуск, аудит auth.* (T-SESS-001/002/017, T-AUTH-019/042, T-SEC-038)', () => {
  const t = new AuthE2e();
  const PIN = '482913';
  const KID = 'e2e-2026-10';
  const key = pemPair();
  const foreign = pemPair();
  const dir = mkdtempSync(join(tmpdir(), 'pos-auth-jwt-'));

  beforeAll(async () => {
    const file = (name: string, content: string) => {
      const p = join(dir, name);
      writeFileSync(p, content, { mode: 0o600 });
      return p;
    };
    await t.start('auth_tokens_audit_e2e', {
      JWT_PRIVATE_KEY_FILE: file('jwt.pem', key.privatePem),
      JWT_PUBLIC_KEY_FILE: file('jwt.json', publicSet({ [KID]: key })),
      JWT_KEY_ID: KID,
    });
  });
  afterAll(async () => {
    await t.stop();
    rmSync(dir, { recursive: true, force: true });
  });
  beforeEach(() => {
    t.tick();
    t.clearAuthCache();
  });

  const sessions = (token: string, deviceKey: string) => t.bearer('get', '/auth/sessions', token, deviceKey);

  async function signedIn(role: 'seller' | 'cashier' = 'seller'): Promise<LoginResult & { userId: string }> {
    const u = await t.seedUser({ role });
    await t.setPin(u.userId, PIN);
    const r = await t.login(u.phone);
    expect(r.status).toBe(200);
    return { ...r, userId: u.userId };
  }

  it('T-SESS-001 / T-SEC-009: принимается только EdDSA с известным kid, iss/aud/exp, denylist, permissionsVersion, users.status; claims без ПДн', async () => {
    const s = await signedIn();
    const access = s.body.accessToken as string;
    expect((await sessions(access, s.deviceKey)).status).toBe(200);
    const claims = decodeJwt(access);
    expect(Object.keys(claims).sort()).toEqual(
      [
        'amr',
        'aud',
        'deviceId',
        'exp',
        'iat',
        'iss',
        'jti',
        'kind',
        'permissionsVersion',
        'roles',
        'sid',
        'sub',
      ].sort(),
    );
    expect(JSON.stringify(claims)).not.toMatch(/\+996|Тестов/); // ни телефона, ни ФИО

    const now = Math.floor(t.clock.now().getTime() / 1000);
    const base = { ...claims, iat: now, exp: now + 600, jti: randomUUID() };
    const sign = (payload: Record<string, unknown>, pem: string, kid = KID) =>
      new SignJWT(payload).setProtectedHeader({ alg: 'EdDSA', typ: 'JWT', kid }).sign(createPrivateKey(pem));
    // контроль: собственноручно подписанный нашим ключом токен с теми же claims принимается
    expect((await sessions(await sign(base, key.privatePem), s.deviceKey)).status).toBe(200);
    const [h, , sig] = access.split('.');
    const tampered = `${h}.${Buffer.from(JSON.stringify({ ...claims, roles: ['admin'] })).toString('base64url')}.${sig}`;
    const bad: Record<string, string> = {
      alg_none: new UnsecuredJWT(base).encode(),
      tampered,
      foreign_key_same_kid: await sign(base, foreign.privatePem),
      unknown_kid: await sign(base, key.privatePem, 'other-kid'),
      wrong_iss: await sign({ ...base, iss: 'evil' }, key.privatePem),
      wrong_aud: await sign({ ...base, aud: 'other-api' }, key.privatePem),
      expired: await sign({ ...base, iat: now - 1000, exp: now - 10 }, key.privatePem),
    };
    expect(base.iss).toBe(JWT_ISSUER);
    expect(base.aud).toBe(JWT_AUDIENCE);
    for (const [name, token] of Object.entries(bad)) {
      const r = await sessions(token, s.deviceKey);
      expect(r.status, name).toBe(401);
      expect(r.body.code, name).toBe('UNAUTHENTICATED');
    }

    // permissionsVersion++ → TOKEN_STALE; блокировка пользователя → SESSION_REVOKED; logout → denylist
    await t.pool.query('UPDATE users SET permissions_version = permissions_version + 1 WHERE id = $1', [s.userId]);
    t.clearAuthCache();
    expect((await sessions(access, s.deviceKey)).body.code).toBe('TOKEN_STALE');
    const s2 = await signedIn();
    expect((await t.bearer('post', '/auth/logout', s2.body.accessToken as string, s2.deviceKey).send({})).status).toBe(
      204,
    );
    expect((await sessions(s2.body.accessToken as string, s2.deviceKey)).status).toBe(401);
    const s3 = await signedIn();
    await t.pool.query(`UPDATE users SET status = 'blocked' WHERE id = $1`, [s3.userId]);
    t.clearAuthCache();
    const blocked = await sessions(s3.body.accessToken as string, s3.deviceKey);
    expect(blocked.status).toBe(401);
    expect(blocked.body.code).toBe('SESSION_REVOKED');
  });

  it('T-SESS-002: access живёт 15 мин — 14:59 → 200, после 15:00 + допуск часов 5 с → 401 UNAUTHENTICATED; refresh выдаёт новый', async () => {
    const s = await signedIn();
    const access = s.body.accessToken as string;
    expect(s.body.accessExpiresIn).toBe(900);
    t.tick(14 * 60_000 + 59_000);
    t.clearAuthCache();
    expect((await sessions(access, s.deviceKey)).status).toBe(200);
    t.tick(7_000); // 15:06: exp + допуск расхождения часов 5 с (JwtService, 09 §8.1)
    t.clearAuthCache();
    const late = await sessions(access, s.deviceKey);
    expect(late.status).toBe(401);
    expect(late.body.code).toBe('UNAUTHENTICATED');
    const r = await t.refresh(s.body.refreshToken as string, s.deviceKey);
    expect(r.status).toBe(200);
    expect((await sessions(r.body.accessToken as string, s.deviceKey)).status).toBe(200);
  });

  it('T-AUTH-019: счётчики номера (3 / 15 мин) и cooldown переживают перезапуск pos-api (rate_limit_counters, otp_challenges)', async () => {
    t.alignClock(15 * 60_000);
    const u = await t.seedUser();
    const deviceKey = freshDevice();
    expect((await t.otpRequest(u.phone, deviceKey, freshIp())).status).toBe(202);
    t.tick(61_000);
    expect((await t.otpRequest(u.phone, deviceKey, freshIp())).status).toBe(202);
    await t.restart();
    // cooldown после рестарта тоже в силе (otp_challenges.created_at)
    const cooldown = await t.otpRequest(u.phone, deviceKey, freshIp());
    expect(cooldown.status).toBe(429);
    t.tick(61_000);
    expect((await t.otpRequest(u.phone, deviceKey, freshIp())).status).toBe(202); // 3-й за 15 мин
    t.tick(61_000);
    const fourth = await t.otpRequest(u.phone, deviceKey, freshIp());
    expect(fourth.status).toBe(429);
    expect(fourth.body.code).toBe('OTP_RATE_LIMITED');
    const rows = await t.pool.query<{ scope: string; count: number }>(
      `SELECT scope, count FROM rate_limit_counters WHERE scope = 'otp_phone_15m' ORDER BY updated_at DESC LIMIT 1`,
    );
    expect(rows.rows[0]?.count).toBe(3);
  });

  it('T-AUTH-042: вход зарегистрированного клиента — roles=[customer], kind=customer, биометрия предлагается (Android class3)', async () => {
    const u = await t.seedUser({ kind: 'customer' });
    const r = await t.login(u.phone, { device: ANDROID });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ status: 'authenticated', user: { kind: 'customer', roles: ['customer'] } });
    expect(decodeJwt(r.body.accessToken as string)).toMatchObject({ kind: 'customer', roles: ['customer'] });
    expect(r.body.nextStep).toBe('none');
  });

  it('T-SESS-017 / T-SEC-038 (auth.*): каждое событие входа/отказа/блокировки/step-up/выхода — в audit_logs с request_id, маской телефона, без OTP/токенов/HMAC', async () => {
    const since = (await t.pool.query<{ s: string }>('SELECT coalesce(max(chain_seq), 0)::text AS s FROM audit_logs'))
      .rows[0]?.s;
    const secrets: string[] = [];
    // вход (auth.otp.sent, auth.otp.verified, auth.login), неверный код (auth.otp.failed), блокировка кода (auth.otp.locked)
    const s = await signedIn();
    secrets.push(s.code, s.body.accessToken as string, s.body.refreshToken as string);
    const u = await t.seedUser();
    const dk = freshDevice();
    const ip = freshIp();
    const req = await t.otpRequest(u.phone, dk, ip);
    const code = await t.codeFor(req.body.challengeId as string);
    secrets.push(code);
    const wrong = code === '000000' ? '111111' : '000000';
    for (let i = 0; i < 5; i++) await t.otpVerify(req.body.challengeId as string, wrong, dk, ip);
    // лимит (auth.otp.rate_limited): повтор в cooldown
    expect((await t.otpRequest(u.phone, dk, ip)).status).toBe(429);
    // step-up ok / failed; PIN заблокирован (auth.pin.locked)
    const access = s.body.accessToken as string;
    const su = (pin: string) =>
      t
        .bearer('post', '/auth/step-up', access, s.deviceKey)
        .send({ method: 'pin', pin, operation: 'session.logout_all' });
    const ok = await su(PIN);
    expect(ok.status).toBe(200);
    secrets.push(ok.body.stepUpToken as string);
    for (let i = 0; i < 5; i++) await su('000000');
    // unlock (PIN заблокирован → отказ), reuse refresh (session.reuse_detected), logout
    const s2 = await signedIn();
    secrets.push(s2.body.refreshToken as string);
    const r1 = await t.refresh(s2.body.refreshToken as string, s2.deviceKey);
    secrets.push(r1.body.refreshToken as string);
    await t.bearer('get', '/auth/sessions', r1.body.accessToken as string, s2.deviceKey);
    t.tick(31_000);
    expect((await t.refresh(s2.body.refreshToken as string, s2.deviceKey)).body.code).toBe('SESSION_REVOKED');
    const s3 = await signedIn();
    const okUnlock = await t.unlock({ method: 'pin', pin: PIN, refreshToken: s3.body.refreshToken }, s3.deviceKey);
    expect(okUnlock.status).toBe(200);
    expect(
      (await t.bearer('post', '/auth/logout', okUnlock.body.accessToken as string, s3.deviceKey).send({})).status,
    ).toBe(204);
    // заблокированный сотрудник после верного кода (auth.otp.verified denied)
    const blocked = await t.seedUser({ status: 'blocked' });
    const b = await t.login(blocked.phone);
    expect(b.status).toBe(403);

    const rows = await t.pool.query<JsonBody>(
      `SELECT action, result, request_id, actor_user_id, (to_jsonb(a) - 'row_hash' - 'prev_hash')::text AS j
         FROM audit_logs a WHERE chain_seq > $1::bigint ORDER BY chain_seq`,
      [since],
    );
    const actions = new Set(rows.rows.map((r) => r.action as string));
    const expected = [
      'auth.otp.sent',
      'auth.otp.verified',
      'auth.login',
      'auth.otp.failed',
      'auth.otp.locked',
      'auth.otp.rate_limited',
      'auth.step_up.ok',
      'auth.step_up.failed',
      'auth.pin.locked',
      'session.reuse_detected',
      'auth.unlock',
      'auth.logout',
    ];
    expect(expected.filter((a) => !actions.has(a))).toEqual([]);
    // события модуля auth (служебные записи сидирования тестовых данных — без запроса — не входят)
    for (const r of rows.rows.filter((x) => /^(auth|session)\./.test(x.action as string))) {
      expect(r.request_id, r.action as string).toBeTruthy();
      const j = r.j as string;
      expect(j, r.action as string).not.toMatch(/\+99677\d{7}/); // телефон — только маска
      for (const sec of secrets) {
        const re = new RegExp(`(?<![\\d.:a-f-])${sec.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\\d])`);
        expect(re.test(j), `${r.action as string}: секрет в аудите`).toBe(false);
      }
    }
    const sent = rows.rows.find((r) => r.action === 'auth.otp.sent');
    expect(sent?.j as string).toMatch(/\+996 \*\*\* \*\* \d\d/);
    const login = rows.rows.find((r) => r.action === 'auth.login');
    expect(login?.actor_user_id).toBeTruthy();
  });
});

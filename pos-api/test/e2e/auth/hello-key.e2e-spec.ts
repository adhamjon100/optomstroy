import { generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { and, eq } from 'drizzle-orm';
import { HELLO_CHALLENGE_PREFIX } from '../../../src/common/auth/hello-key.js';
import { PinHasher } from '../../../src/common/crypto/pin-hasher.service.js';
import { generateOpaqueToken, sha256 } from '../../../src/common/crypto/random.js';
import { appPins, auditLogs, devices, helloKeys, sessions, userProfiles } from '../../../src/db/schema/index.js';
import { DevicesRepository } from '../../../src/users/devices.repository.js';
import { HelloKeysRepository } from '../../../src/users/hello-keys.repository.js';
import { SessionsRepository } from '../../../src/users/sessions.repository.js';
import { seedSubject } from '../../foundation/support/foundation-db.js';
import {
  cleanupSecrets,
  completeBody,
  CONSENT_VERSION,
  createHarness,
  FoundationDb,
  type Harness,
  harnessConfig,
  LogCapture,
  OTP_TEST_CODE,
  OTP_TEST_PHONES,
  postComplete,
  seedRegistration,
  stepUpToken,
} from '../../registration/support/harness.js';
import { validateAgainst } from '../../settings/support/openapi-check.js';
import { FixedClock } from '../../../src/common/auth/clock.js';

/**
 * Вход по ключу Windows Hello без PIN приложения — вариант W2, сервер (15 ADR-116 п. 3, п. 4; ответ владельца 2026-11-08
 * на Q-355 «Лицо без PIN (Рекоменд.)»; 08 §4.1.5, §4.1.8, §4.1.10, §4.3.3, §4.3.5, §4.3.6, §4.18.3, API-196…API-199,
 * API-201; 09 §9.2 «Вход по ключу Windows Hello», BIO-038…BIO-041; 07 §5.66, §13.3; 11 SEC-146, RR-10; пакет LF-2-06 —
 * 13 §3.14). **Тестовые данные:** embedded PostgreSQL 17 со всеми миграциями (0024 — `hello_keys`), тестовые пары
 * RSA-2048 (RSASSA-PKCS1-v1_5, SHA-256) создаются в процессе теста, номера — тестовые номера OTP (`AUTH_OTP_TEST_PHONES`,
 * код фиксирован, SMS не уходит) и синтетические `+99655…`.
 *
 * Три приложения на одной БД с общими часами — три значения `AUTH_WINDOWS_HELLO_KEY`: `hPersonal` — `personal` (с
 * админ-разделом пользователей), `hAll` — `all`, `hOff` — `off` (по умолчанию). Рестарт с другим значением = запрос к
 * другому приложению на тех же данных.
 * - T-BIO-035: включение ключа (`off`, `personal`, оба источника, без PIN, Android, RSA-1024/EC/экспонента 3, замена),
 *   challenge (замена, 120 с, refresh не ротирован; прежний refresh в окне грации и поздний повтор — challenge и
 *   разблокировка «вбок»; отказы по сессии — `SESSION_REVOKED`, как у `POST /auth/unlock`, доработка 2026-11-18),
 *   разблокировка подписью, отказы, `DELETE /me/pin`, аудит, `helloKeyInvalidated`, `GET /me` и `user` ответа входа;
 * - T-BIO-037: правило `personal` (вход другого пользователя, его попытка включить ключ, окно 30 дней), ключ переживает
 *   выход, `SESSION_REVOKED` и конец срока сессии (challenge по отозванной и истёкшей сессии — `SESSION_REVOKED`, ключ
 *   жив), отзыв `logout-all` (свой и администратором), сменой номера, `off`, блокировкой и сбросом PIN администратором
 *   (`blocked`, `pin_reset`) и блокировкой отзывом согласия `personal_data` (`blocked`); при `all` вход другого ключ не
 *   отзывает; подключение планшета — test/kiosk/lifecycle-*.spec.ts;
 * - T-SEC-076: чужой ключ, изменённая строка, повтор подписи, challenge другой сессии, без challenge, Android, сочетания
 *   полей; RL-PIN не трогает счётчик неверных PIN; планшет — test/kiosk/access.spec.ts.
 */

type Body = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

interface TestKey {
  readonly spki: string;
  signChallenge(challenge: string): string;
}

/** Тестовая пара RSA (закрытый ключ — только в памяти теста; на сервер уходит SPKI). */
function rsaKey(bits = 2048, publicExponent = 65537): TestKey {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: bits, publicExponent });
  return {
    spki: publicKey.export({ type: 'spki', format: 'der' }).toString('base64url'),
    signChallenge: (challenge) => sign('sha256', Buffer.from(challenge, 'utf8'), privateKey).toString('base64url'),
  };
}

interface Win {
  readonly userId: string;
  readonly sid: string;
  readonly deviceKey: string;
  readonly access: string;
  /** Текущий refresh (обновляется после ротации вызывающим). */
  refresh: string;
  readonly phone: string;
}

const PIN = '583920'; // PIN completeBody

let ipSeq = 0;
function ip(): string {
  ipSeq += 1;
  return `10.77.${Math.floor(ipSeq / 250) % 250}.${(ipSeq % 250) + 1}`;
}

describe('ключ Windows Hello (W2, ADR-116): POST /me/biometrics helloKey, POST /auth/unlock/challenge, POST /auth/unlock hello_key', () => {
  const fdb = new FoundationDb();
  const logs = new LogCapture();
  const clock = new FixedClock(new Date());
  let hPersonal: Harness;
  let hAll: Harness;
  let hOff: Harness;
  const key = rsaKey();

  beforeAll(async () => {
    await fdb.start('hello_key_e2e');
    const env = { OTP_MAX_SENDS_PER_PHONE_15M: '50', OTP_GLOBAL_PER_MIN: '1000' };
    hPersonal = await createHarness(fdb, {
      config: harnessConfig({ ...env, AUTH_WINDOWS_HELLO_KEY: 'personal' }),
      logs,
      clock,
      admin: true,
    });
    hAll = await createHarness(fdb, { config: harnessConfig({ ...env, AUTH_WINDOWS_HELLO_KEY: 'all' }), logs, clock });
    hOff = await createHarness(fdb, { config: harnessConfig(env), logs, clock });
  });

  afterAll(async () => {
    await hPersonal?.app.close();
    await hAll?.app.close();
    await hOff?.app.close();
    await fdb.stop();
    cleanupSecrets();
  });

  // ---------- помощники ----------

  /** Покупатель, зарегистрированный на установке `deviceKey` (Windows); PIN задан при регистрации. */
  async function windowsCustomer(
    h: Harness,
    o: { readonly deviceKey?: string; readonly phone?: string; readonly platform?: 'windows' | 'android' } = {},
  ): Promise<Win> {
    const s = await seedRegistration(fdb.db, h.jwt, {
      ...(o.deviceKey ? { deviceKey: o.deviceKey } : {}),
      ...(o.phone ? { phone: o.phone } : {}),
      verifiedAt: clock.now(),
    });
    const r = await postComplete(h, completeBody(s.token, { platform: o.platform ?? 'windows' }), s.deviceKey).set(
      'X-Forwarded-For',
      ip(),
    );
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return {
      userId: r.body.user.id,
      sid: r.body.sid,
      deviceKey: s.deviceKey,
      access: r.body.accessToken,
      refresh: r.body.refreshToken,
      phone: s.phone,
    };
  }

  const bearer = (h: Harness, method: 'get' | 'post' | 'delete', path: string, s: Win, stepUp?: string) => {
    let r = h
      .http()
      [method](`/api/v1${path}`)
      .set('Authorization', `Bearer ${s.access}`)
      .set('X-Device-Id', s.deviceKey)
      .set('X-Forwarded-For', ip());
    if (stepUp) r = r.set('X-Step-Up-Token', stepUp);
    return r;
  };

  async function enableKey(
    h: Harness,
    s: Win,
    k: TestKey = key,
    o: {
      readonly source?: 'windows_hello' | 'webauthn_prf';
      readonly publicKey?: string;
      readonly klass?: string;
    } = {},
  ) {
    const su = await stepUpToken(h.jwt, s, 'profile.biometrics.toggle', 'pin');
    return bearer(h, 'post', '/me/biometrics', s, su).send({
      enabled: true,
      biometricClass: o.klass ?? 'windows_hello',
      helloKey: { publicKey: o.publicKey ?? k.spki, algorithm: 'RS256', source: o.source ?? 'windows_hello' },
      consent: { kind: 'biometrics_device', version: CONSENT_VERSION, granted: true },
    });
  }

  async function disableKey(h: Harness, s: Win) {
    const su = await stepUpToken(h.jwt, s, 'profile.biometrics.toggle', 'pin');
    return bearer(h, 'post', '/me/biometrics', s, su).send({ enabled: false });
  }

  const challenge = (h: Harness, refreshToken: string, deviceKey: string) =>
    h
      .http()
      .post('/api/v1/auth/unlock/challenge')
      .set('X-Device-Id', deviceKey)
      .set('X-Forwarded-For', ip())
      .send({ method: 'hello_key', refreshToken });

  const unlock = (h: Harness, body: Body, deviceKey: string) =>
    h.http().post('/api/v1/auth/unlock').set('X-Device-Id', deviceKey).set('X-Forwarded-For', ip()).send(body);

  const unlockKey = (h: Harness, s: Win, signature: string, refreshToken = s.refresh) =>
    unlock(h, { method: 'hello_key', refreshToken, signature }, s.deviceKey);

  /** Challenge → подпись → разблокировка; при успехе refresh субъекта обновляется. */
  async function keyUnlock(h: Harness, s: Win, k: TestKey = key) {
    const c = await challenge(h, s.refresh, s.deviceKey);
    expect(c.status, JSON.stringify(c.body)).toBe(200);
    const r = await unlockKey(h, s, k.signChallenge(c.body.challenge as string));
    if (r.status === 200) s.refresh = r.body.refreshToken as string;
    return r;
  }

  async function pinUnlock(h: Harness, s: Win, extra: Body = {}, pin = PIN) {
    const r = await unlock(h, { method: 'pin', refreshToken: s.refresh, pin, ...extra }, s.deviceKey);
    if (r.status === 200) s.refresh = r.body.refreshToken as string;
    return r;
  }

  /** Вход по SMS (тестовый номер OTP) на установке `deviceKey`. */
  async function smsLogin(h: Harness, phone: string, deviceKey: string): Promise<Win & { readonly body: Body }> {
    clock.advance(61_000); // cooldown повторной отправки кода на тот же номер (09 §5.4)
    const from = ip();
    const req = await h
      .http()
      .post('/api/v1/auth/otp/request')
      .set('X-Device-Id', deviceKey)
      .set('X-Forwarded-For', from)
      .send({ phone, purpose: 'login_or_register' });
    expect(req.status, JSON.stringify(req.body)).toBe(202);
    const v = await h
      .http()
      .post('/api/v1/auth/otp/verify')
      .set('X-Device-Id', deviceKey)
      .set('X-Forwarded-For', from)
      .send({
        challengeId: req.body.challengeId,
        code: OTP_TEST_CODE,
        device: { name: 'Касса-2', platform: 'windows', appVersion: '1.4.2', biometricClass: 'windows_hello' },
      });
    expect(v.status, JSON.stringify(v.body)).toBe(200);
    return {
      userId: v.body.user.id,
      sid: v.body.sid,
      deviceKey,
      access: v.body.accessToken,
      refresh: v.body.refreshToken,
      phone,
      body: v.body as Body,
    };
  }

  const keysOf = (userId: string) => fdb.db.select().from(helloKeys).where(eq(helloKeys.userId, userId));
  const liveKeys = async (userId: string) => (await keysOf(userId)).filter((k) => k.revokedAt === null);
  const sessionRow = async (sid: string) => (await fdb.db.select().from(sessions).where(eq(sessions.id, sid)))[0];
  const auditOf = async (action: string, entityId?: string) =>
    (await fdb.db.select().from(auditLogs).where(eq(auditLogs.action, action))).filter(
      (a) => entityId === undefined || a.entityId === entityId,
    );
  const reasonOf = (r: { body: Body }): unknown[] => [r.body.code as unknown, r.body.reason as unknown];
  /** Значимые поля problem+json (без идентификаторов запроса). */
  const problem = (r: { status: number; body: Body }) => ({
    status: r.status,
    code: r.body.code,
    reason: r.body.reason,
    detail: r.body.detail,
  });

  /**
   * Администратор с PIN (D-48: без PIN сотрудник ограничен `pin_not_set`) в приложении `hPersonal` (админ-раздел
   * пользователей): access и step-up на операцию — для `/admin/users/{id}/…`.
   */
  async function adminActor() {
    const admin = await seedSubject(fdb.db, { role: 'admin' });
    await seedPin(admin.userId, '730518');
    const access = await hPersonal.jwt.signAccess({
      sub: admin.userId,
      kind: 'staff',
      roles: ['admin'],
      permissionsVersion: 1,
      deviceId: admin.deviceKey,
      sid: admin.session.id,
    });
    const send = async (method: 'post' | 'delete', path: string, operation: string, body: Body) => {
      const su = await stepUpToken(
        hPersonal.jwt,
        { userId: admin.userId, sid: admin.session.id, deviceKey: admin.deviceKey },
        operation,
        'pin',
      );
      return hPersonal
        .http()
        [method](`/api/v1/admin/users${path}`)
        .set('Authorization', `Bearer ${access.token}`)
        .set('X-Device-Id', admin.deviceKey)
        .set('X-Step-Up-Token', su)
        .send(body);
    };
    return { userId: admin.userId, send };
  }

  async function seedPin(userId: string, pin: string) {
    const h = await hPersonal.app.get(PinHasher).hash(pin, userId);
    await fdb.db.insert(appPins).values({
      userId,
      pinHash: h.pinHash,
      pepperVersion: h.pepperVersion,
      pinLength: h.pinLength,
      changedAt: new Date(),
    });
  }

  // ---------- T-BIO-035: включение ----------

  it('T-BIO-035 (1): off → hello_key_disabled; personal → 200 без токена, только SPKI/RS256/источник; замена ключа устройства (replaced); webauthn_prf; аудит без ключа', async () => {
    const off = await windowsCustomer(hOff);
    const r0 = await enableKey(hOff, off);
    expect(r0.status).toBe(200);
    expect(r0.body).toEqual({ enabled: false, reason: 'hello_key_disabled' });
    expect(await keysOf(off.userId)).toHaveLength(0);

    const a = await windowsCustomer(hPersonal);
    const r1 = await enableKey(hPersonal, a);
    expect(r1.status, JSON.stringify(r1.body)).toBe(200);
    expect(r1.body).toEqual({ enabled: true });
    const bio = await fdb.db
      .select()
      .from(sessions)
      .where(and(eq(sessions.userId, a.userId), eq(sessions.kind, 'biometric')));
    expect(bio).toHaveLength(0); // biometric_refresh на Windows не выдаётся
    const [k1] = await liveKeys(a.userId);
    expect(k1).toMatchObject({ algorithm: 'RS256', source: 'windows_hello', revokedAt: null, challenge: null });
    expect(k1?.publicKey.toString('base64url')).toBe(key.spki);
    const [dev] = await fdb.db.select().from(devices).where(eq(devices.id, k1.deviceId));
    expect(dev?.deviceKey).toBe(a.deviceKey);
    expect(dev?.biometricEnrolledAt).not.toBeNull();

    // Повтор с новым ключом браузера на Windows (веб-демо, BIO-041): прежний — replaced, живой — один.
    const prf = rsaKey();
    const r2 = await enableKey(hPersonal, a, prf, { source: 'webauthn_prf' });
    expect(r2.body).toEqual({ enabled: true });
    const all = await keysOf(a.userId);
    expect(all.filter((k) => k.revokedAt === null).map((k) => k.source)).toEqual(['webauthn_prf']);
    expect(all.find((k) => k.id === k1.id)?.revokeReason).toBe('replaced');

    const enabled = await auditOf('auth.biometrics.enabled');
    const mine = enabled.filter((e) => e.actorUserId === a.userId).map((e) => e.after);
    expect(mine).toHaveLength(2);
    expect(mine).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ biometricClass: 'windows_hello', keySource: 'windows_hello', replacedKeys: 0 }),
        expect.objectContaining({ biometricClass: 'windows_hello', keySource: 'webauthn_prf', replacedKeys: 1 }),
      ]),
    );
    const replaced = await auditOf('auth.biometrics.disabled', k1.deviceId);
    expect(replaced.map((e) => e.after)).toEqual([expect.objectContaining({ reason: 'replaced' })]);
    const dump = JSON.stringify([...enabled, ...replaced]);
    expect(dump).not.toContain(key.spki.slice(0, 40));
    expect(dump).not.toContain(prf.spki.slice(0, 40));
  });

  it('T-BIO-035 (1): без PIN → 400 pin_required; Android → biometric_class; RSA-1024, EC, экспонента 3 → hello_key_format; helloKey с class3 → hello_key; windows_hello без helloKey — прежний no_crypto_binding_on_platform', async () => {
    const noPin = await windowsCustomer(hPersonal);
    await fdb.db.delete(appPins).where(eq(appPins.userId, noPin.userId));
    const r1 = await enableKey(hPersonal, noPin);
    expect(r1.status).toBe(400);
    expect(r1.body.errors).toEqual([expect.objectContaining({ field: 'biometricClass', rule: 'pin_required' })]);

    const android = await windowsCustomer(hPersonal, { platform: 'android' });
    const r2 = await enableKey(hPersonal, android);
    expect(r2.status).toBe(400);
    expect(r2.body.errors).toEqual([expect.objectContaining({ field: 'biometricClass', rule: 'biometric_class' })]);

    const c = await windowsCustomer(hPersonal);
    const ec = generateKeyPairSync('ec', { namedCurve: 'P-256' })
      .publicKey.export({ type: 'spki', format: 'der' })
      .toString('base64url');
    for (const publicKey of [rsaKey(1024).spki, ec, rsaKey(2048, 3).spki, `${key.spki.slice(0, -4)}AAAA`]) {
      const r = await enableKey(hPersonal, c, key, { publicKey });
      expect(r.status, publicKey.length.toString()).toBe(400);
      expect(r.body.errors).toEqual([expect.objectContaining({ rule: 'hello_key_format' })]);
    }
    expect(await keysOf(c.userId)).toHaveLength(0);
    const big = await enableKey(hPersonal, c, rsaKey(4096));
    expect(big.body).toEqual({ enabled: true });

    const wrongClass = await enableKey(hPersonal, c, key, { klass: 'class3' });
    expect(wrongClass.status).toBe(400);
    expect(wrongClass.body.errors).toEqual([expect.objectContaining({ field: 'helloKey', rule: 'hello_key' })]);
    const su = await stepUpToken(hPersonal.jwt, c, 'profile.biometrics.toggle', 'pin');
    const gate = await bearer(hPersonal, 'post', '/me/biometrics', c, su).send({
      enabled: true,
      biometricClass: 'windows_hello',
      consent: { kind: 'biometrics_device', version: CONSENT_VERSION, granted: true },
    });
    expect(gate.body).toEqual({ enabled: false, reason: 'no_crypto_binding_on_platform' });
  });

  // ---------- T-BIO-035: challenge и разблокировка ----------

  it('T-BIO-035 (2)–(3): второй challenge заменяет первый, 120 с, refresh не ротирован; верная подпись → 200, amr [sms,bio], unlocked_until +30 мин, last_used_at; прежний refresh (грация, поздний повтор) → challenge и разблокировка «вбок»; неизвестный → SESSION_REVOKED; вытесненный → reuse_detected; ключ жив', async () => {
    const a = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, a)).status).toBe(200);
    const before = await sessionRow(a.sid);
    const c1 = await challenge(hPersonal, a.refresh, a.deviceKey);
    expect(c1.status).toBe(200);
    expect(c1.body.challenge).toMatch(/^optomstroy-hello-unlock\/v1:[A-Za-z0-9_-]{43}$/);
    expect(new Date(c1.body.expiresAt as string).getTime() - clock.now().getTime()).toBe(120_000);
    expect(validateAgainst('AuthUnlockChallengeResponse', c1.body)).toEqual([]);
    const c2 = await challenge(hPersonal, a.refresh, a.deviceKey);
    expect(c2.body.challenge).not.toBe(c1.body.challenge);
    const after = await sessionRow(a.sid);
    expect(after?.refreshHash.equals(before.refreshHash)).toBe(true);

    // Подпись первого (заменённого) challenge → hello_key_invalid, второй challenge погашен этим отказом.
    const stale = await unlockKey(hPersonal, a, key.signChallenge(c1.body.challenge as string));
    expect(stale.status).toBe(401);
    expect(reasonOf(stale)).toEqual(['UNLOCK_REQUIRED', 'hello_key_invalid']);
    const [k] = await liveKeys(a.userId);
    expect(k?.challenge).toBeNull();

    const ok = await keyUnlock(hPersonal, a);
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body.amr).toEqual(['sms', 'bio']);
    expect(ok.body.sid).toBe(a.sid);
    expect(validateAgainst('AuthUnlockResponse', ok.body)).toEqual([]);
    const row = await sessionRow(a.sid);
    expect(row?.unlockedUntil?.getTime()).toBe(clock.now().getTime() + 30 * 60_000);
    expect(row?.amr).toEqual(['sms', 'bio']);
    expect((await liveKeys(a.userId))[0]?.lastUsedAt?.getTime()).toBe(clock.now().getTime());
    // Доступ с новым access (рабочий экран без PIN).
    const me = await bearer(hPersonal, 'get', '/me', { ...a, access: ok.body.accessToken as string });
    expect(me.status).toBe(200);
    expect(me.body.security).toMatchObject({ biometricsPlatform: 'windows_hello_key', windowsHelloKeyAllowed: true });

    // Прежний refresh (потерянный ответ, доработка 2026-11-18): сессия проверяется как в POST /auth/unlock — в окне
    // грации и при позднем повторе challenge выдаётся этой же сессии, разблокировка ключом принимает тот же refresh
    // «вбок» (как PIN, 08 §4.1.8); ключ не трогается (09 BIO-040).
    const prevRefresh = a.refresh;
    expect((await pinUnlock(hPersonal, a)).status).toBe(200);
    const byPrev = await challenge(hPersonal, prevRefresh, a.deviceKey);
    expect(byPrev.status, JSON.stringify(byPrev.body)).toBe(200);
    const aside = await unlockKey(hPersonal, a, key.signChallenge(byPrev.body.challenge as string), prevRefresh);
    expect(aside.status, JSON.stringify(aside.body)).toBe(200);
    expect(aside.body.sid).toBe(a.sid);
    a.refresh = aside.body.refreshToken as string;
    const beforeLate = a.refresh;
    expect((await pinUnlock(hPersonal, a)).status).toBe(200);
    clock.advance(31_000); // вне окна грации 30 с — поздний повтор (`replay`)
    const byLate = await challenge(hPersonal, beforeLate, a.deviceKey);
    expect(byLate.status, JSON.stringify(byLate.body)).toBe(200);
    const superseded = a.refresh; // вытесняется ротацией «вбок» ниже
    const late = await unlockKey(hPersonal, a, key.signChallenge(byLate.body.challenge as string), beforeLate);
    expect(late.status, JSON.stringify(late.body)).toBe(200);
    a.refresh = late.body.refreshToken as string;
    const keyPaths = (await auditOf('auth.unlock', a.sid))
      .filter((e) => e.result === 'ok' && (e.after as Body).method === 'hello_key')
      .map((e) => String((e.after as Body).path))
      .sort();
    expect(keyPaths).toEqual(['current', 'grace', 'replay']);

    // Неизвестный refresh — SESSION_REVOKED (как POST /auth/unlock), сессия жива; ключ работает дальше.
    const unknown = await challenge(hPersonal, generateOpaqueToken(), a.deviceKey);
    expect(problem(unknown)).toEqual({
      status: 401,
      code: 'SESSION_REVOKED',
      reason: undefined,
      detail: 'Сессия завершена. Войдите снова.',
    });
    expect((await sessionRow(a.sid))?.revokedAt).toBeNull();
    expect((await keyUnlock(hPersonal, a)).status).toBe(200);
    // Вытесненный refresh — reuse-detection, как у POST /auth/unlock: семья отозвана, аудит; ключ жив.
    const reuse = await challenge(hPersonal, superseded, a.deviceKey);
    expect(reasonOf(reuse)).toEqual(['SESSION_REVOKED', 'reuse_detected']);
    expect((await sessionRow(a.sid))?.revokeReason).toBe('reuse_detected');
    expect((await auditOf('session.reuse_detected', a.sid)).map((e) => String((e.after as Body).mode))).toEqual([
      'unlock_challenge',
    ]);
    expect(await liveKeys(a.userId)).toHaveLength(1);
  });

  it('T-BIO-035 (4), T-SEC-076 (1)–(4): чужой ключ, изменённая строка, повтор подписи, challenge старше 120 с, challenge другой сессии, без challenge → hello_key_invalid; refresh не ротирован, сессия жива, счётчик PIN не растёт', async () => {
    const a = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, a)).status).toBe(200);
    const other = rsaKey();
    const expectInvalid = async (signature: string, refreshToken = a.refresh) => {
      const before = await sessionRow(a.sid);
      const r = await unlockKey(hPersonal, a, signature, refreshToken);
      expect(r.status, JSON.stringify(r.body)).toBe(401);
      expect(reasonOf(r)).toEqual(['UNLOCK_REQUIRED', 'hello_key_invalid']);
      expect(r.body.accessToken).toBeUndefined();
      const now = await sessionRow(a.sid);
      expect(now?.refreshHash.equals(before.refreshHash)).toBe(true);
      expect(now?.revokedAt).toBeNull();
      expect((await liveKeys(a.userId))[0]?.challenge).toBeNull(); // погашен при любом исходе
    };

    // (1) подпись чужим ключом; подпись изменённой строки challenge
    let c = await challenge(hPersonal, a.refresh, a.deviceKey);
    await expectInvalid(other.signChallenge(c.body.challenge as string));
    c = await challenge(hPersonal, a.refresh, a.deviceKey);
    await expectInvalid(key.signChallenge(`${c.body.challenge as string}x`));
    c = await challenge(hPersonal, a.refresh, a.deviceKey);
    await expectInvalid(key.signChallenge((c.body.challenge as string).replace(HELLO_CHALLENGE_PREFIX, '')));
    // (2) повтор той же подписи после успеха — challenge погашен
    c = await challenge(hPersonal, a.refresh, a.deviceKey);
    const sig = key.signChallenge(c.body.challenge as string);
    const ok = await unlockKey(hPersonal, a, sig);
    expect(ok.status).toBe(200);
    a.refresh = ok.body.refreshToken as string;
    await expectInvalid(sig);
    // challenge старше 120 с
    c = await challenge(hPersonal, a.refresh, a.deviceKey);
    clock.advance(121_000);
    await expectInvalid(key.signChallenge(c.body.challenge as string));
    // (4) без выданного challenge
    await expectInvalid(key.signChallenge(`${HELLO_CHALLENGE_PREFIX}${'A'.repeat(43)}`));
    // (3) challenge другой сессии: выдан по сессии S1, затем новый вход того же пользователя на установке → S2.
    const s1 = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, s1)).status).toBe(200);
    const c1 = await challenge(hPersonal, s1.refresh, s1.deviceKey);
    expect(c1.status).toBe(200);
    const s2 = await seedSecondSession(s1);
    const cross = await unlockKey(hPersonal, s2, key.signChallenge(c1.body.challenge as string));
    expect(reasonOf(cross)).toEqual(['UNLOCK_REQUIRED', 'hello_key_invalid']);

    // Счётчик неверных PIN не тронут; PIN по-прежнему работает (RL-PIN — общий лимит, не PIN_LOCKED).
    const [pin] = await fdb.db.select().from(appPins).where(eq(appPins.userId, a.userId));
    expect(pin?.failedAttempts).toBe(0);
    expect((await pinUnlock(hPersonal, a)).status).toBe(200);
    const denied = (await auditOf('auth.unlock', a.sid)).filter((e) => e.result === 'denied');
    expect(denied.length).toBeGreaterThanOrEqual(6);
    expect(denied.every((e) => (e.after as Body).method === 'hello_key')).toBe(true);
    expect(JSON.stringify(denied)).not.toMatch(/optomstroy-hello-unlock|signature/);
  });

  /** Вторая стандартная сессия того же пользователя на той же установке (как новый вход; прежняя — отозвана). */
  async function seedSecondSession(s: Win): Promise<Win> {
    const device = await new DevicesRepository(fdb.db).findByKey(s.userId, s.deviceKey);
    await new SessionsRepository(fdb.db).revoke(s.sid, 'logout');
    const refresh = generateOpaqueToken();
    const row = await new SessionsRepository(fdb.db).create({
      userId: s.userId,
      deviceId: device!.id,
      refreshHash: sha256(refresh),
      expiresAt: new Date(clock.now().getTime() + 7 * 24 * 3600_000),
      idleExpiresAt: new Date(clock.now().getTime() + 24 * 3600_000),
    });
    return { ...s, sid: row.id, refresh };
  }

  it('T-BIO-035 (4): отозванный ключ → hello_key_unavailable; T-BIO-035 (5): DELETE /me/pin при живом ключе → 400 hello_key_active, после выключения — прежние правила; (7) PIN + helloKeyInvalidated → ключ invalidated', async () => {
    const a = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, a)).status).toBe(200);
    const su = await stepUpToken(hPersonal.jwt, a, 'profile.pin.set');
    const del = await bearer(hPersonal, 'delete', '/me/pin', a, su);
    expect(del.status).toBe(400);
    expect(del.body.errors).toEqual([expect.objectContaining({ field: 'pin', rule: 'hello_key_active' })]);
    expect(await fdb.db.select().from(appPins).where(eq(appPins.userId, a.userId))).toHaveLength(1);

    // Выключение (SCR-42) → disabled; challenge → unavailable; DELETE /me/pin — как прежде (на Windows S нет → 422).
    expect((await disableKey(hPersonal, a)).body).toEqual({ enabled: false });
    const [k] = await keysOf(a.userId);
    expect(k?.revokeReason).toBe('disabled');
    const off = await challenge(hPersonal, a.refresh, a.deviceKey);
    expect(reasonOf(off)).toEqual(['UNLOCK_REQUIRED', 'hello_key_unavailable']);
    const unl = await unlockKey(hPersonal, a, key.signChallenge(`${HELLO_CHALLENGE_PREFIX}${'B'.repeat(43)}`));
    expect(reasonOf(unl)).toEqual(['UNLOCK_REQUIRED', 'hello_key_unavailable']);
    const del2 = await bearer(hPersonal, 'delete', '/me/pin', a, su);
    expect(del2.status).toBe(422);
    expect(del2.body.errors[0].rule).toBe('login_protection_required');
    const me = await bearer(hPersonal, 'get', '/me', a);
    expect(me.body.security).toMatchObject({ biometricsEnabled: false, biometricsPlatform: 'windows_hello_gate' });
    const disabled = await auditOf('auth.biometrics.disabled', k.deviceId);
    expect(disabled.map((e) => e.after)).toEqual([
      expect.objectContaining({ biometricClass: 'windows_hello', keySource: 'windows_hello', revokedHelloKeys: 1 }),
    ]);

    // (7) ключ пропал в Windows: неверный PIN — ключ жив; верный PIN с helloKeyInvalidated — invalidated.
    const b = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, b)).status).toBe(200);
    expect((await pinUnlock(hPersonal, b, { helloKeyInvalidated: true }, '111111')).status).toBe(401);
    expect(await liveKeys(b.userId)).toHaveLength(1);
    const inv = await pinUnlock(hPersonal, b, { helloKeyInvalidated: true });
    expect(inv.status).toBe(200);
    expect(inv.body.amr).toEqual(['sms', 'pin']);
    expect((await keysOf(b.userId))[0]?.revokeReason).toBe('invalidated');
  });

  it('T-BIO-035 (6), T-SEC-076 (5), (6): аудит auth.unlock {method: hello_key, keySource}; Android и стандартные правила полей: signature с pin → 400 method, без signature → required, helloKeyInvalidated с hello_key → method, pin с hello_key → forbidden_field', async () => {
    const a = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, a, key, { source: 'webauthn_prf' })).status).toBe(200);
    expect((await keyUnlock(hPersonal, a)).status).toBe(200);
    const ok = (await auditOf('auth.unlock', a.sid)).filter((e) => e.result === 'ok');
    expect(ok.map((e) => e.after)).toEqual([
      expect.objectContaining({ method: 'hello_key', keySource: 'webauthn_prf' }),
    ]);
    expect(JSON.stringify(ok)).not.toMatch(/optomstroy-hello-unlock|signature|publicKey/);

    const sig = 'A'.repeat(342);
    const rules = async (body: Body) => {
      const r = await unlock(hPersonal, { refreshToken: a.refresh, ...body }, a.deviceKey);
      expect(r.status).toBe(400);
      return (r.body.errors as { field: string; rule: string }[]).map((e) => `${e.field}:${e.rule}`);
    };
    expect(await rules({ method: 'pin', pin: PIN, signature: sig })).toEqual(['signature:method']);
    expect(await rules({ method: 'biometric', signature: sig })).toEqual(['signature:method']);
    expect(await rules({ method: 'hello_key' })).toEqual(['signature:required']);
    expect(await rules({ method: 'hello_key', signature: sig, helloKeyInvalidated: true })).toEqual([
      'helloKeyInvalidated:method',
    ]);
    expect(await rules({ method: 'hello_key', signature: sig, pin: PIN })).toEqual(['pin:forbidden_field']);
    expect(await rules({ method: 'hello_key', signature: 'не base64url' })).toEqual(['signature:max_length']);
    const badChallenge = await hPersonal
      .http()
      .post('/api/v1/auth/unlock/challenge')
      .set('X-Device-Id', a.deviceKey)
      .send({ method: 'pin', refreshToken: a.refresh });
    expect(badChallenge.status).toBe(400);
    expect(badChallenge.body.errors[0]).toMatchObject({ field: 'method', rule: 'enum' });

    // (5) устройство Android (ключа быть не может): challenge и hello_key → hello_key_unavailable, сессия жива.
    const android = await windowsCustomer(hPersonal, { platform: 'android' });
    const ch = await challenge(hPersonal, android.refresh, android.deviceKey);
    expect(reasonOf(ch)).toEqual(['UNLOCK_REQUIRED', 'hello_key_unavailable']);
    const un = await unlockKey(hPersonal, android, sig);
    expect(reasonOf(un)).toEqual(['UNLOCK_REQUIRED', 'hello_key_unavailable']);
    expect((await sessionRow(android.sid))?.revokedAt).toBeNull();
    // Пользователь не `active` challenge не получает (08 §4.1.10). Статус меняется прямо в БД, мимо
    // POST /admin/users/{id}/block, поэтому ключ жив; отзыв блокировкой (`blocked`) — T-BIO-037 (10), (12).
    // `blocked` — как у POST /auth/unlock: SESSION_REVOKED {reason: blocked} без отзыва; `pending_activation` —
    // отказ по субъекту, hello_key_unavailable.
    await fdb.pool.query(`UPDATE users SET status = 'blocked' WHERE id = $1`, [a.userId]);
    expect(reasonOf(await challenge(hPersonal, a.refresh, a.deviceKey))).toEqual(['SESSION_REVOKED', 'blocked']);
    await fdb.pool.query(`UPDATE users SET status = 'pending_activation' WHERE id = $1`, [a.userId]);
    expect(reasonOf(await challenge(hPersonal, a.refresh, a.deviceKey))).toEqual([
      'UNLOCK_REQUIRED',
      'hello_key_unavailable',
    ]);
    expect(await liveKeys(a.userId)).toHaveLength(1);
    await fdb.pool.query(`UPDATE users SET status = 'active' WHERE id = $1`, [a.userId]);
    expect((await sessionRow(a.sid))?.revokedAt).toBeNull();
    // Отказы по сессии — как у POST /auth/unlock (доработка 2026-11-18): неизвестный refresh → SESSION_REVOKED без
    // отзыва; чужой X-Device-Id → отзыв `device_mismatch` с аудитом session.revoked; ключ жив.
    const unknown = await challenge(hPersonal, generateOpaqueToken(), a.deviceKey);
    expect(reasonOf(unknown)).toEqual(['SESSION_REVOKED', undefined]);
    expect((await sessionRow(a.sid))?.revokedAt).toBeNull();
    const foreign = await challenge(hPersonal, a.refresh, randomUUID());
    expect(reasonOf(foreign)).toEqual(['SESSION_REVOKED', 'device_mismatch']);
    expect((await sessionRow(a.sid))?.revokeReason).toBe('device_mismatch');
    expect((await auditOf('session.revoked', a.sid)).map((e) => String((e.after as Body).reason))).toEqual([
      'device_mismatch',
    ]);
    expect(await liveKeys(a.userId)).toHaveLength(1);
  });

  // ---------- GET /me и ответ входа ----------

  it('T-BIO-035, API-201: GET /me — windowsHelloKeyAllowed по переменной, платформе и правилу personal; windows_hello_key после включения; ответ входа по SMS — те же поля; схема Me', async () => {
    const cases: [Harness, Win, boolean][] = [
      [hOff, await windowsCustomer(hOff), false],
      [hAll, await windowsCustomer(hAll), true],
      [hPersonal, await windowsCustomer(hPersonal), true],
      [hPersonal, await windowsCustomer(hPersonal, { platform: 'android' }), false],
    ];
    for (const [h, s, allowed] of cases) {
      const me = await bearer(h, 'get', '/me', s);
      expect(me.status).toBe(200);
      expect(me.body.security.windowsHelloKeyAllowed).toBe(allowed);
      expect(validateAgainst('Me', me.body)).toEqual([]);
    }
    const a = await windowsCustomer(hAll, { phone: OTP_TEST_PHONES[3] });
    expect((await enableKey(hAll, a)).status).toBe(200);
    const me = await bearer(hAll, 'get', '/me', a);
    expect(me.body.security).toEqual({
      pinSet: true,
      biometricsEnabled: true,
      biometricsPlatform: 'windows_hello_key',
      biometricWeakAllowed: false,
      windowsHelloKeyAllowed: true,
    });
    expect(validateAgainst('Me', me.body)).toEqual([]);
    // Вход по SMS на той же установке: `user.security` ответа входа — живой ключ устройства.
    const again = await smsLogin(hAll, a.phone, a.deviceKey);
    expect(again.body.user.security).toMatchObject({
      biometricsPlatform: 'windows_hello_key',
      windowsHelloKeyAllowed: true,
    });
    expect((await keyUnlock(hAll, again)).status).toBe(200);
  });

  // ---------- T-BIO-037: правило personal и отзыв ----------

  it('T-BIO-037 (1), (2): personal — вход B по SMS на установке A отзывает ключ A (shared_device), challenge A → hello_key_unavailable, PIN работает; B включить ключ не может (hello_key_shared_device)', async () => {
    const a = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, a)).status).toBe(200);
    const b = await windowsCustomer(hPersonal, { phone: OTP_TEST_PHONES[0] }); // B — на своей установке
    const bOnD = await smsLogin(hPersonal, b.phone, a.deviceKey);
    const [k] = await keysOf(a.userId);
    expect(k?.revokeReason).toBe('shared_device');
    expect(bOnD.body.user.security).toMatchObject({ windowsHelloKeyAllowed: false });
    const shared = await auditOf('auth.biometrics.disabled', k.deviceId);
    expect(shared.map((e) => e.after)).toEqual([
      expect.objectContaining({ reason: 'shared_device', keySource: 'windows_hello', userId: a.userId }),
    ]);
    const c = await challenge(hPersonal, a.refresh, a.deviceKey);
    expect(reasonOf(c)).toEqual(['UNLOCK_REQUIRED', 'hello_key_unavailable']);
    expect((await pinUnlock(hPersonal, a)).status).toBe(200);
    const meA = await bearer(hPersonal, 'get', '/me', a);
    expect(meA.body.security).toMatchObject({
      windowsHelloKeyAllowed: false,
      biometricsPlatform: 'windows_hello_gate',
    });

    const r = await enableKey(hPersonal, bOnD);
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ enabled: false, reason: 'hello_key_shared_device' });
    expect(await keysOf(bOnD.userId)).toHaveLength(0);
  });

  it('T-BIO-037 (3), (9): ключ переживает «Выйти», SESSION_REVOKED, конец срока сессии и новый вход по SMS (challenge по отозванной и истёкшей сессии → SESSION_REVOKED, ключ жив); другой пользователь 31 день назад — ключ принимается, 10 дней назад — нет (окно 30 дней [НЕ ПОДТВЕРЖДЕНО])', async () => {
    const a = await windowsCustomer(hPersonal, { phone: OTP_TEST_PHONES[1] });
    expect((await enableKey(hPersonal, a)).status).toBe(200);
    expect((await bearer(hPersonal, 'post', '/auth/logout', a).send({})).status).toBe(204);
    expect(await liveKeys(a.userId)).toHaveLength(1);
    const a2 = await smsLogin(hPersonal, a.phone, a.deviceKey);
    expect((await keyUnlock(hPersonal, a2)).status).toBe(200);
    await fdb.pool.query(`UPDATE sessions SET revoked_at = now(), revoke_reason = 'admin' WHERE user_id = $1`, [
      a.userId,
    ]);
    expect((await unlockKey(hPersonal, a2, 'A'.repeat(342))).body.code).toBe('SESSION_REVOKED');
    // Challenge по отозванной сессии — тоже SESSION_REVOKED (не hello_key_unavailable: приложение ключ не удаляет).
    expect(reasonOf(await challenge(hPersonal, a2.refresh, a2.deviceKey))).toEqual(['SESSION_REVOKED', undefined]);
    expect(await liveKeys(a.userId)).toHaveLength(1);
    const a3 = await smsLogin(hPersonal, a.phone, a.deviceKey);
    expect((await keyUnlock(hPersonal, a3)).status).toBe(200);
    // Idle-срок сессии вышел (как после выходных): challenge → SESSION_REVOKED {reason: expired}, сессия отозвана
    // (`expired`), ключ жив; после нового входа по SMS ключ снова работает.
    await fdb.pool.query('UPDATE sessions SET idle_expires_at = $2 WHERE id = $1', [
      a3.sid,
      new Date(clock.now().getTime() - 1_000),
    ]);
    expect(reasonOf(await challenge(hPersonal, a3.refresh, a3.deviceKey))).toEqual(['SESSION_REVOKED', 'expired']);
    expect((await sessionRow(a3.sid))?.revokeReason).toBe('expired');
    expect(await liveKeys(a.userId)).toHaveLength(1);
    const a4 = await smsLogin(hPersonal, a.phone, a.deviceKey);
    expect((await keyUnlock(hPersonal, a4)).status).toBe(200);

    // Окно правила personal: сессия другого пользователя на этой установке 31 день назад не мешает, 10 дней — мешает.
    const d = randomUUID();
    const other = await seedSubject(fdb.db, { kind: 'customer', role: 'customer' });
    const dev = await new DevicesRepository(fdb.db).upsert({ userId: other.userId, deviceKey: d, platform: 'windows' });
    const old = await new SessionsRepository(fdb.db).create({
      userId: other.userId,
      deviceId: dev.id,
      refreshHash: sha256(generateOpaqueToken()),
      expiresAt: new Date(clock.now().getTime() + 86_400_000),
      idleExpiresAt: new Date(clock.now().getTime() + 86_400_000),
    });
    await fdb.pool.query('UPDATE sessions SET issued_at = $2 WHERE id = $1', [
      old.id,
      new Date(clock.now().getTime() - 31 * 86_400_000),
    ]);
    const c = await windowsCustomer(hPersonal, { deviceKey: d });
    expect((await enableKey(hPersonal, c)).body).toEqual({ enabled: true });
    expect((await keyUnlock(hPersonal, c)).status).toBe(200);
    await fdb.pool.query('UPDATE sessions SET issued_at = $2 WHERE id = $1', [
      old.id,
      new Date(clock.now().getTime() - 10 * 86_400_000),
    ]);
    const late = await challenge(hPersonal, c.refresh, c.deviceKey);
    expect(reasonOf(late)).toEqual(['UNLOCK_REQUIRED', 'hello_key_unavailable']);
    expect((await keysOf(c.userId))[0]?.revokeReason).toBe('shared_device');
  });

  it('T-BIO-037 (4), (5): POST /auth/logout-all и POST /admin/users/{id}/logout-all → logout_all на всех устройствах; смена номера → phone_changed', async () => {
    // (4) свой logout-all (step-up): ключи на двух установках пользователя (вторая — строкой БД)
    const a = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, a)).status).toBe(200);
    const second = await new DevicesRepository(fdb.db).upsert({
      userId: a.userId,
      deviceKey: randomUUID(),
      platform: 'windows',
    });
    await new HelloKeysRepository(fdb.db).insert({
      userId: a.userId,
      deviceId: second.id,
      publicKey: Buffer.from(rsaKey().spki, 'base64url'),
      algorithm: 'RS256',
      source: 'windows_hello',
    });
    const su = await stepUpToken(hPersonal.jwt, a, 'session.logout_all', 'pin');
    expect((await bearer(hPersonal, 'post', '/auth/logout-all', a, su).send({})).status).toBe(204);
    expect((await keysOf(a.userId)).map((k) => k.revokeReason)).toEqual(['logout_all', 'logout_all']);
    const logoutAll = await auditOf('auth.logout_all', a.userId);
    expect(logoutAll.map((e) => e.after)).toEqual([expect.objectContaining({ revokedHelloKeys: 2 })]);

    // администратор: logout-all цели
    const target = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, target)).status).toBe(200);
    const admin = await adminActor();
    const r = await admin.send('post', `/${target.userId}/logout-all`, 'session.revoke.any', {});
    expect(r.status, JSON.stringify(r.body)).toBe(204);
    expect((await keysOf(target.userId)).map((k) => k.revokeReason)).toEqual(['logout_all']);
    const byAdmin = (await auditOf('auth.biometrics.disabled')).filter(
      (e) => (e.after as Body).userId === target.userId,
    );
    expect(byAdmin.map((e) => [e.actorUserId, String((e.after as Body).reason)])).toEqual([
      [admin.userId, 'logout_all'],
    ]);

    // (5) смена номера: ключ текущего устройства тоже отзывается
    const p = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, p)).status).toBe(200);
    const pSu = await stepUpToken(hPersonal.jwt, p, 'profile.phone.change');
    const req = await bearer(hPersonal, 'post', '/me/phone/change/request', p, pSu).send({
      newPhone: OTP_TEST_PHONES[2],
    });
    expect(req.status, JSON.stringify(req.body)).toBe(202);
    const conf = await bearer(hPersonal, 'post', '/me/phone/change/confirm', p).send({
      challengeId: req.body.challengeId,
      code: OTP_TEST_CODE,
    });
    expect(conf.status, JSON.stringify(conf.body)).toBe(200);
    expect((await keysOf(p.userId)).map((k) => k.revokeReason)).toEqual(['phone_changed']);
    expect(reasonOf(await challenge(hPersonal, p.refresh, p.deviceKey))).toEqual([
      'UNLOCK_REQUIRED',
      'hello_key_unavailable',
    ]);
  });

  it('T-BIO-037 (10), (11): блокировка администратором → blocked (разблокировка ключ не возвращает); сброс PIN администратором → pin_reset, повтор сброса и сброс без PIN — без отзыва', async () => {
    const admin = await adminActor();
    const disabledReasons = async (userId: string) =>
      (await auditOf('auth.biometrics.disabled'))
        .filter((e) => (e.after as Body).userId === userId)
        .map((e) => [e.actorUserId, String((e.after as Body).reason)]);

    // (10) покупатель с ключом: блокировка отзывает ключ вместе с сессиями
    const a = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, a)).status).toBe(200);
    const blocked = await admin.send('post', `/${a.userId}/block`, 'users.manage', {
      blocked: true,
      reason: 'проверка блокировки',
    });
    expect(blocked.status, JSON.stringify(blocked.body)).toBe(200);
    expect((await keysOf(a.userId)).map((k) => k.revokeReason)).toEqual(['blocked']);
    expect(await disabledReasons(a.userId)).toEqual([[admin.userId, 'blocked']]);
    // запись сервиса (вторую, `{id, status}`, пишет триггер аудита users) — по `revokedSessions`
    const blockAudit = (await auditOf('user.blocked', a.userId)).map((e) => e.after as Body);
    expect(blockAudit.filter((e) => 'revokedSessions' in e)).toEqual([
      expect.objectContaining({ status: 'blocked', revokedHelloKeys: 1 }),
    ]);
    expect((await sessionRow(a.sid))?.revokeReason).toBe('blocked');
    expect((await bearer(hPersonal, 'get', '/me', a)).status).toBe(401);
    // разблокировка ключ не возвращает: включить заново — SCR-42 после нового входа
    const unblocked = await admin.send('post', `/${a.userId}/block`, 'users.manage', {
      blocked: false,
      reason: 'проверка разблокировки',
    });
    expect(unblocked.status, JSON.stringify(unblocked.body)).toBe(200);
    expect(await liveKeys(a.userId)).toHaveLength(0);
    // Сессия отозвана блокировкой — SESSION_REVOKED; новая сессия на той же установке — ключа нет.
    expect(reasonOf(await challenge(hPersonal, a.refresh, a.deviceKey))).toEqual(['SESSION_REVOKED', undefined]);
    const aNew = await seedSecondSession(a);
    expect(reasonOf(await challenge(hPersonal, aNew.refresh, aNew.deviceKey))).toEqual([
      'UNLOCK_REQUIRED',
      'hello_key_unavailable',
    ]);

    // (11) сотрудник на Windows с PIN, ключом и стандартной сессией: сброс PIN администратором отзывает ключ
    const staff = await seedSubject(fdb.db, { role: 'seller' });
    await seedPin(staff.userId, '418263');
    const deviceKey = randomUUID();
    const dev = await new DevicesRepository(fdb.db).upsert({ userId: staff.userId, deviceKey, platform: 'windows' });
    const refresh = generateOpaqueToken();
    const now = clock.now().getTime();
    await new SessionsRepository(fdb.db).create({
      userId: staff.userId,
      deviceId: dev.id,
      refreshHash: sha256(refresh),
      expiresAt: new Date(now + 7 * 24 * 3600_000),
      idleExpiresAt: new Date(now + 24 * 3600_000),
    });
    const staffKey = rsaKey();
    await new HelloKeysRepository(fdb.db).insert({
      userId: staff.userId,
      deviceId: dev.id,
      publicKey: Buffer.from(staffKey.spki, 'base64url'),
      algorithm: 'RS256',
      source: 'windows_hello',
    });
    expect((await challenge(hPersonal, refresh, deviceKey)).status).toBe(200);
    const reset = await admin.send('delete', `/${staff.userId}/pin`, 'users.pin.reset', { reason: 'забыл PIN' });
    expect(reset.status, JSON.stringify(reset.body)).toBe(204);
    const [revokedKey] = await keysOf(staff.userId);
    expect(revokedKey).toMatchObject({ revokeReason: 'pin_reset', challenge: null, challengeSessionId: null });
    expect(await disabledReasons(staff.userId)).toEqual([[admin.userId, 'pin_reset']]);
    expect((await auditOf('auth.pin.reset', staff.userId)).map((e) => e.after)).toEqual([
      { pinSet: false, revokedHelloKeys: 1 },
    ]);
    expect(reasonOf(await challenge(hPersonal, refresh, deviceKey))).toEqual([
      'UNLOCK_REQUIRED',
      'hello_key_unavailable',
    ]);
    // повтор сброса (PIN уже нет) — 204 без аудита и без отзыва; новый ключ при отсутствии PIN тоже не трогается
    await new HelloKeysRepository(fdb.db).insert({
      userId: staff.userId,
      deviceId: dev.id,
      publicKey: Buffer.from(rsaKey().spki, 'base64url'),
      algorithm: 'RS256',
      source: 'windows_hello',
    });
    expect((await admin.send('delete', `/${staff.userId}/pin`, 'users.pin.reset', { reason: 'повтор' })).status).toBe(
      204,
    );
    expect(await liveKeys(staff.userId)).toHaveLength(1);
    expect(await auditOf('auth.pin.reset', staff.userId)).toHaveLength(1);
  });

  it('T-BIO-037 (12): отзыв согласия personal_data (блокировка самим пользователем) отзывает ключ (blocked), как блокировка администратором; разблокировка ключ не возвращает', async () => {
    const a = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, a)).status).toBe(200);
    const su = await stepUpToken(hPersonal.jwt, a, 'profile.consent.revoke', 'otp');
    const revoked = await bearer(hPersonal, 'post', '/me/consents', a, su).send({
      kind: 'personal_data',
      version: CONSENT_VERSION,
      granted: false,
    });
    expect(revoked.status, JSON.stringify(revoked.body)).toBe(200);
    const [k] = await keysOf(a.userId);
    expect(k?.revokeReason).toBe('blocked');
    const disabled = (await auditOf('auth.biometrics.disabled')).filter((e) => (e.after as Body).userId === a.userId);
    expect(disabled.map((e) => [e.actorUserId, String((e.after as Body).reason)])).toEqual([[a.userId, 'blocked']]);
    expect((await auditOf('consent.revoked')).filter((e) => e.actorUserId === a.userId).map((e) => e.after)).toEqual([
      expect.objectContaining({ kind: 'personal_data', revokedHelloKeys: 1 }),
    ]);
    const [profile] = await fdb.db.select().from(userProfiles).where(eq(userProfiles.userId, a.userId));
    expect(profile?.biometricsEnabled).toBe(false);
    const [device] = await fdb.db.select().from(devices).where(eq(devices.id, k.deviceId));
    expect(device?.biometricEnrolledAt).toBeNull();
    expect((await sessionRow(a.sid))?.revokeReason).toBe('blocked');
    expect(reasonOf(await challenge(hPersonal, a.refresh, a.deviceKey))).toEqual(['SESSION_REVOKED', undefined]);

    // Разблокировка администратором ключ не возвращает: новая сессия на той же установке → hello_key_unavailable.
    const admin = await adminActor();
    const unblocked = await admin.send('post', `/${a.userId}/block`, 'users.manage', {
      blocked: false,
      reason: 'проверка разблокировки после отзыва согласия',
    });
    expect(unblocked.status, JSON.stringify(unblocked.body)).toBe(200);
    expect(await liveKeys(a.userId)).toHaveLength(0);
    const again = await seedSecondSession(a);
    expect(reasonOf(await challenge(hPersonal, again.refresh, again.deviceKey))).toEqual([
      'UNLOCK_REQUIRED',
      'hello_key_unavailable',
    ]);
  });

  it('T-BIO-037 (7), (8): off после рестарта — challenge отзывает ключ (policy_off), PIN работает; all — вход другого пользователя ключ не отзывает', async () => {
    const a = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, a)).status).toBe(200);
    const c = await challenge(hOff, a.refresh, a.deviceKey);
    expect(c.status).toBe(401);
    expect(reasonOf(c)).toEqual(['UNLOCK_REQUIRED', 'hello_key_unavailable']);
    const [k] = await keysOf(a.userId);
    expect(k?.revokeReason).toBe('policy_off');
    expect(
      (await auditOf('auth.biometrics.disabled', k.deviceId)).map((e) => String((e.after as Body).reason)),
    ).toEqual(['policy_off']);
    expect((await pinUnlock(hOff, a)).status).toBe(200);

    // off и подпись при живом ключе (challenge выдан при personal): unlock тоже отзывает ключ.
    const b = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, b)).status).toBe(200);
    const cb = await challenge(hPersonal, b.refresh, b.deviceKey);
    const ub = await unlockKey(hOff, b, key.signChallenge(cb.body.challenge as string));
    expect(reasonOf(ub)).toEqual(['UNLOCK_REQUIRED', 'hello_key_unavailable']);
    expect((await keysOf(b.userId))[0]?.revokeReason).toBe('policy_off');

    // (8) all: вход другого пользователя на установке A ключ не отзывает
    const x = await windowsCustomer(hAll);
    expect((await enableKey(hAll, x)).status).toBe(200);
    await windowsCustomer(hAll, { deviceKey: x.deviceKey }); // регистрация другого на той же установке
    expect(await liveKeys(x.userId)).toHaveLength(1);
    expect((await keyUnlock(hAll, x)).status).toBe(200);
    // при personal та же регистрация (выдача сессии) отзывает ключ — /registration/complete тоже вход (08 §4.1.2)
    const y = await windowsCustomer(hPersonal);
    expect((await enableKey(hPersonal, y)).status).toBe(200);
    await windowsCustomer(hPersonal, { deviceKey: y.deviceKey });
    expect((await keysOf(y.userId))[0]?.revokeReason).toBe('shared_device');
  });

  it('07 §13.3: retention — истёкший challenge очищается, отозванные ключи старше 90 дней удаляются; живые и свежие — нет', async () => {
    const a = await windowsCustomer(hAll);
    expect((await enableKey(hAll, a)).status).toBe(200);
    expect((await challenge(hAll, a.refresh, a.deviceKey)).status).toBe(200);
    const [live] = await liveKeys(a.userId);
    await fdb.pool.query(`UPDATE hello_keys SET challenge_expires_at = now() - interval '1 second' WHERE id = $1`, [
      live.id,
    ]);
    const b = await windowsCustomer(hAll);
    expect((await enableKey(hAll, b)).status).toBe(200);
    expect((await disableKey(hAll, b)).status).toBe(200);
    const [old] = await keysOf(b.userId);
    await fdb.pool.query(`UPDATE hello_keys SET revoked_at = now() - interval '91 days' WHERE id = $1`, [old.id]);
    const c = await windowsCustomer(hAll);
    expect((await enableKey(hAll, c)).status).toBe(200);
    expect((await disableKey(hAll, c)).status).toBe(200);

    const r = await hAll.app.get(HelloKeysRepository).purge();
    expect(r.challenges).toBeGreaterThanOrEqual(1);
    expect(r.keys).toBeGreaterThanOrEqual(1);
    expect((await liveKeys(a.userId))[0]).toMatchObject({ challenge: null, challengeSessionId: null });
    expect(await keysOf(b.userId)).toHaveLength(0);
    expect(await keysOf(c.userId)).toHaveLength(1);
    expect((await hAll.app.get(HelloKeysRepository).purge()).keys).toBe(0);
  });
});

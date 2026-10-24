import { randomUUID } from 'node:crypto';
import { and, count, eq } from 'drizzle-orm';
import { base64url } from 'jose';
import { AuditAnchorService } from '../../src/common/audit/audit-anchor.service.js';
import {
  appPins,
  auditLogs,
  consents,
  customerLinks,
  devices,
  sessions,
  tokenDenylist,
  userInvitations,
  userProfiles,
  users,
} from '../../src/db/schema/index.js';
import { CONSENT_CATALOG } from '../../src/profile/consents/consent-catalog.js';
import { UserRolesRepository } from '../../src/users/user-roles.repository.js';
import { seedSubject } from '../foundation/support/foundation-db.js';
import {
  cleanupSecrets,
  list,
  completeBody,
  CONSENT_VERSION,
  createHarness,
  FailingCustomerMatching,
  FoundationDb,
  type Harness,
  harnessConfig,
  linksOf,
  LogCapture,
  postComplete,
  seedCustomer,
  seedRegistration,
} from './support/harness.js';

const PD = { kind: 'personal_data', version: CONSENT_VERSION };
const BIO = { kind: 'biometrics_device', version: CONSENT_VERSION };
const SPHERE = { kind: 'activity_sphere', version: CONSENT_VERSION };

describe('POST /registration/complete, GET /registration/customer-match (RM-D-004, RM-D-014, RM-D-017; 12 T-REG)', () => {
  const fdb = new FoundationDb();
  const logs = new LogCapture();
  let h: Harness; // CUSTOMER_SELF_SERVICE=true (по умолчанию), порт customers — заглушка
  let off: Harness; // CUSTOMER_SELF_SERVICE=false, порта нет (запасной путь)

  beforeAll(async () => {
    await fdb.start('registration_e2e');
    h = await createHarness(fdb, { matching: 'customers', logs });
    off = await createHarness(fdb, {
      config: harnessConfig({ CUSTOMER_SELF_SERVICE: 'false' }),
      matching: 'customers',
      logs,
    });
  });

  afterAll(async () => {
    await h?.app.close();
    await off?.app.close();
    await fdb.stop();
    cleanupSecrets();
  });

  const userByPhone = async (phone: string) => (await fdb.db.select().from(users).where(eq(users.phoneE164, phone)))[0];

  it('T-REG-026 (2), RM-D-004 п. 2, T-REG-015 (в): номер без приглашения → customer active, роль customer, токены работают (GET /me)', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    const r = await postComplete(h, completeBody(s.token), s.deviceKey);
    expect(r.status).toBe(201);
    expect(r.body).toMatchObject({
      status: 'authenticated',
      tokenType: 'Bearer',
      accessExpiresIn: 900,
      nextStep: 'none',
      customerMatch: { status: 'none', linkId: null, nextStep: 'none' },
      user: { kind: 'customer', status: 'active', roles: ['customer'], permissionsVersion: 1 },
    });
    expect(r.body.roleSource).toBeUndefined();
    expect(r.body.user.security).toMatchObject({ pinSet: true, biometricsEnabled: false });
    expect(r.body.user.permissions).toContain('customer.link.self_resolve');
    expect(typeof r.body.refreshToken).toBe('string');
    const me = await h
      .http()
      .get('/api/v1/me')
      .set('Authorization', `Bearer ${r.body.accessToken}`)
      .set('X-Device-Id', s.deviceKey);
    expect(me.status).toBe(200);
    expect(me.body).toMatchObject({ id: r.body.user.id, kind: 'customer', session: { sid: r.body.sid, amr: ['sms'] } });
    const u = await userByPhone(s.phone);
    expect(u).toMatchObject({ kind: 'customer', status: 'active' });
    expect(u?.phoneVerifiedAt).not.toBeNull();
    const [sess] = await fdb.db.select().from(sessions).where(eq(sessions.id, r.body.sid));
    expect(sess?.createdFromChallengeId).toBe(s.challengeId);
    expect(sess?.refreshHash.toString('hex')).not.toContain(r.body.refreshToken);
  });

  it('RM-D-004 п. 2, T-REG-015 (б): CUSTOMER_SELF_SERVICE=false → pending_activation, staff без ролей; /registration/customer-match → none', async () => {
    const s = await seedRegistration(fdb.db, off.jwt);
    const r = await postComplete(off, completeBody(s.token, { pin: '850193' }), s.deviceKey);
    expect(r.status).toBe(201);
    expect(r.body).toMatchObject({
      status: 'pending_activation',
      user: { kind: 'staff', status: 'pending_activation', roles: [] },
    });
    expect(r.body.user.permissions).toEqual(['profile.manage.own', 'session.manage.own', 'settings.public.read']);
    expect(r.body.customerMatch).toBeUndefined();
    const cm = await off
      .http()
      .get('/api/v1/registration/customer-match')
      .set('Authorization', `Bearer ${r.body.accessToken}`)
      .set('X-Device-Id', s.deviceKey);
    expect(cm.status).toBe(200);
    expect(cm.body).toEqual({ status: 'none', linkId: null, customer: null, nextStep: 'none' });
  });

  it('T-SEC-044, T-AUTH-038, RM-D-004 п. 7, T-REG-009: staff (pending_activation) без PIN → 422 login_protection_required; 4-значный PIN staff → 400 pin_weak', async () => {
    const s = await seedRegistration(fdb.db, off.jwt);
    const noPin = await postComplete(
      off,
      completeBody(s.token, { pin: null, biometricsEnabled: true, biometricClass: 'class3', consents: [PD, BIO] }),
      s.deviceKey,
    );
    expect(noPin.status).toBe(422);
    expect(noPin.body.code).toBe('VALIDATION_FAILED');
    expect(noPin.body.errors[0]).toMatchObject({ field: 'security', rule: 'login_protection_required' });
    const short = await postComplete(off, completeBody(s.token, { pin: '5830' }), s.deviceKey);
    expect(short.status).toBe(400);
    expect(short.body.errors[0]).toMatchObject({ field: 'security.pin', rule: 'pin_weak' });
    expect(await userByPhone(s.phone)).toBeUndefined();
  });

  it('RM-D-004 п. 1 (защитная ветвь D-07): приглашение появилось после выдачи токена → staff с ролью приглашения, приглашение accepted, customer_links нет', async () => {
    const admin = await seedSubject(fdb.db, { role: 'admin' });
    const s = await seedRegistration(fdb.db, h.jwt);
    await fdb.db.insert(userInvitations).values({
      phoneE164: s.phone,
      role: 'cashier',
      fullName: 'Кассиров Касым',
      invitedByUserId: admin.userId,
      expiresAt: new Date(Date.now() + 86_400_000),
    });
    const noPin = await postComplete(
      h,
      completeBody(s.token, { pin: null, biometricsEnabled: true, biometricClass: 'class3', consents: [PD, BIO] }),
      s.deviceKey,
    );
    expect(noPin.status).toBe(422);
    expect(noPin.body.errors[0].rule).toBe('login_protection_required');
    const r = await postComplete(h, completeBody(s.token, { pin: '730518' }), s.deviceKey);
    expect(r.status).toBe(201);
    expect(r.body).toMatchObject({
      status: 'authenticated',
      roleSource: 'invitation',
      user: { kind: 'staff', roles: ['cashier'], status: 'active' },
    });
    expect(r.body.customerMatch).toBeUndefined();
    expect(await linksOf(fdb.db, r.body.user.id)).toHaveLength(0);
    const [inv] = await fdb.db.select().from(userInvitations).where(eq(userInvitations.phoneE164, s.phone));
    expect(inv).toMatchObject({ status: 'accepted', acceptedUserId: r.body.user.id });
    expect(await new UserRolesRepository(fdb.db).activeRoleCodes(r.body.user.id)).toEqual(['cashier']);
  });

  it('RM-D-004 п. 3, T-REG-001: токен старше 15 мин → 401 REGISTRATION_TOKEN_INVALID; подделка подписи и чужой номер в claims → 401', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    h.clock.advance(15 * 60_000 + 1_000);
    try {
      const r = await postComplete(h, completeBody(s.token), s.deviceKey);
      expect(r.status).toBe(401);
      expect(r.body.code).toBe('REGISTRATION_TOKEN_INVALID');
    } finally {
      h.clock.advance(-(15 * 60_000 + 1_000));
    }
    const s2 = await seedRegistration(fdb.db, h.jwt);
    const [hd, pl] = s2.token.split('.');
    const forged = `${hd}.${pl}.${base64url.encode(Buffer.alloc(64, 7))}`;
    expect((await postComplete(h, completeBody(forged), s2.deviceKey)).body.code).toBe('REGISTRATION_TOKEN_INVALID');
    // Токен с challengeId чужого челленджа (другой номер): хэш токена не совпадает с registration_token_hash
    const s3 = await seedRegistration(fdb.db, h.jwt);
    const alien = await h.jwt.signPurpose('registration', {
      ttlSeconds: 900,
      claims: { challengeId: s3.challengeId, deviceId: s3.deviceKey },
    });
    const foreign = await postComplete(h, completeBody(alien.token), s3.deviceKey);
    expect(foreign.status).toBe(401);
    expect(foreign.body.code).toBe('REGISTRATION_TOKEN_INVALID');
    const otherDevice = await postComplete(h, completeBody(s2.token), randomUUID());
    expect(otherDevice.body.code).toBe('REGISTRATION_TOKEN_INVALID');
    const accessAsReg = await postComplete(h, completeBody('x'), s2.deviceKey);
    expect(accessAsReg.status).toBe(401);
  });

  it('RM-D-004 п. 5, п. 4; T-REG-012: повтор того же токена → 401; номер уже зарегистрирован (новый токен) → 409; одна строка users', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    expect((await postComplete(h, completeBody(s.token), s.deviceKey)).status).toBe(201);
    const reuse = await postComplete(h, completeBody(s.token), s.deviceKey); // новый Idempotency-Key
    expect(reuse.status).toBe(401);
    expect(reuse.body.code).toBe('REGISTRATION_TOKEN_INVALID');
    const [deny] = await fdb.db.select().from(tokenDenylist).where(eq(tokenDenylist.jti, s.jti));
    expect(deny).toMatchObject({ tokenKind: 'registration', reason: 'used' });
    const again = await seedRegistration(fdb.db, h.jwt, { phone: s.phone });
    const dup = await postComplete(h, completeBody(again.token), again.deviceKey);
    expect(dup.status).toBe(409);
    expect(dup.body.code).toBe('PHONE_ALREADY_REGISTERED');
    const [{ n }] = (await fdb.db.select({ n: count() }).from(users).where(eq(users.phoneE164, s.phone))) as [
      { n: number },
    ];
    expect(n).toBe(1);
  });

  it('T-SEC-024, T-REG-012: два параллельных запроса с одним токеном (разные ключи) → один 201, второй 401; одна строка users', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    const [a, b] = await Promise.all([
      postComplete(h, completeBody(s.token), s.deviceKey),
      postComplete(h, completeBody(s.token), s.deviceKey),
    ]);
    expect([a.status, b.status].sort()).toEqual([201, 401]);
    const [{ n }] = (await fdb.db.select({ n: count() }).from(users).where(eq(users.phoneE164, s.phone))) as [
      { n: number },
    ];
    expect(n).toBe(1);
  });

  it('T-SEC-024: идемпотентность (08 §2.7, B-AR-01): тот же ключ → 201 Idempotent-Replayed, та же сессия, новые токены; другое тело → 422; без ключа → 400', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    const key = randomUUID();
    const first = await postComplete(h, completeBody(s.token), s.deviceKey, key);
    expect(first.status).toBe(201);
    const replay = await postComplete(h, completeBody(s.token), s.deviceKey, key);
    expect(replay.status).toBe(201);
    expect(replay.headers['idempotent-replayed']).toBe('true');
    expect(replay.body.sid).toBe(first.body.sid);
    expect(replay.body.user.id).toBe(first.body.user.id);
    expect(replay.body.refreshToken).not.toBe(first.body.refreshToken);
    expect(replay.body.accessToken).not.toBe(first.body.accessToken);
    const me = await h
      .http()
      .get('/api/v1/me')
      .set('Authorization', `Bearer ${replay.body.accessToken}`)
      .set('X-Device-Id', s.deviceKey);
    expect(me.status).toBe(200);
    const stored = await fdb.pool.query<{ body: string }>(
      `SELECT response_body::text AS body FROM idempotency_keys WHERE key = $1`,
      [key],
    );
    expect(stored.rows[0]?.body).not.toContain(first.body.refreshToken);
    expect(stored.rows[0]?.body).not.toContain(first.body.accessToken);
    expect(stored.rows[0]?.body).not.toContain('Token');
    const reused = await postComplete(h, completeBody(s.token, { birthYear: 1991 }), s.deviceKey, key);
    expect(reused.status).toBe(422);
    expect(reused.body.code).toBe('IDEMPOTENCY_KEY_REUSED');
    // Токен привязан к устройству (claim deviceId): другой X-Device-Id → 401 ещё до проверки ключа
    const otherDevice = await postComplete(h, completeBody(s.token), randomUUID(), key);
    expect(otherDevice.status).toBe(401);
    const s2 = await seedRegistration(fdb.db, h.jwt);
    const noKey = await postComplete(h, completeBody(s2.token), s2.deviceKey, null);
    expect(noKey.status).toBe(400);
    expect(noKey.body.errors[0]).toMatchObject({ field: 'Idempotency-Key', rule: 'idempotency_key_required' });
    const noDevice = await h
      .http()
      .post('/api/v1/registration/complete')
      .set('Idempotency-Key', randomUUID())
      .send(completeBody(s2.token));
    expect(noDevice.status).toBe(400);
    expect(noDevice.body.errors[0]).toMatchObject({ field: 'X-Device-Id', rule: 'uuid' });
  });

  it('T-REG-012 / ревью D-MN-02: повтор с тем же ключом — один раз и только для неиспользованной сессии; прежний access — в denylist', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    const key = randomUUID();
    const first = await postComplete(h, completeBody(s.token), s.deviceKey, key);
    expect(first.status).toBe(201);
    const replay = await postComplete(h, completeBody(s.token), s.deviceKey, key);
    expect(replay.status).toBe(201);
    // второй повтор — отказ без ротации (сессия уже выдана повтором)
    const again = await postComplete(h, completeBody(s.token), s.deviceKey, key);
    expect(again.status).toBe(409);
    expect(again.body).toMatchObject({ code: 'PHONE_ALREADY_REGISTERED', reason: 'registration_replay_used' });
    const me = (token: string) =>
      h.http().get('/api/v1/me').set('Authorization', `Bearer ${token}`).set('X-Device-Id', s.deviceKey);
    expect((await me(first.body.accessToken as string)).status).toBe(401);
    expect((await me(replay.body.accessToken as string)).status).toBe(200);
    const row = await fdb.pool.query<{ superseded: boolean }>(
      'SELECT superseded_refresh_hash IS NOT NULL AS superseded FROM sessions WHERE id = $1',
      [first.body.sid],
    );
    expect(row.rows[0]?.superseded).toBe(true);

    // сессия уже использовалась (запрос с access) → повтор не выдаёт токенов
    const s2 = await seedRegistration(fdb.db, h.jwt);
    const key2 = randomUUID();
    const first2 = await postComplete(h, completeBody(s2.token), s2.deviceKey, key2);
    expect(first2.status).toBe(201);
    expect(
      (
        await h
          .http()
          .get('/api/v1/me')
          .set('Authorization', `Bearer ${first2.body.accessToken}`)
          .set('X-Device-Id', s2.deviceKey)
      ).status,
    ).toBe(200);
    const used = await postComplete(h, completeBody(s2.token), s2.deviceKey, key2);
    expect(used.status).toBe(409);
    expect(used.body.code).toBe('PHONE_ALREADY_REGISTERED');
  });

  it('RM-D-014 п. 2, T-REG-005: birthYear 1919 и текущий−13 → 400 birth_year_range; 1920 и текущий−14 → 201', async () => {
    const y = new Date().getUTCFullYear();
    for (const bad of [1919, y - 13]) {
      const s = await seedRegistration(fdb.db, h.jwt);
      const r = await postComplete(h, completeBody(s.token, { birthYear: bad }), s.deviceKey);
      expect(r.status).toBe(400);
      expect(r.body.code).toBe('VALIDATION_FAILED');
      expect(list<{ rule: string }>(r.body.errors).map((e) => e.rule)).toContain('birth_year_range');
    }
    for (const ok of [1920, y - 14]) {
      const s = await seedRegistration(fdb.db, h.jwt);
      const r = await postComplete(h, completeBody(s.token, { birthYear: ok, pin: '850193' }), s.deviceKey);
      expect(r.status).toBe(201);
    }
  });

  it('T-SEC-021, T-REG-026 (1), RM-D-014 п. 2, T-REG-011: consents[].kind=biometric_unlock, лишние поля role/phone, без consents, face_scan → 400 VALIDATION_FAILED', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    const legacy = await postComplete(
      h,
      completeBody(s.token, { consents: [PD, { kind: 'biometric_unlock', version: CONSENT_VERSION }] }),
      s.deviceKey,
    );
    expect(legacy.status).toBe(400);
    expect(legacy.body.errors[0].field).toBe('consents[1].kind');
    const extra = await postComplete(
      h,
      completeBody(s.token, { extra: { role: 'admin', phone: '+996700000009' } }),
      s.deviceKey,
    );
    expect(extra.status).toBe(400);
    expect(
      list<{ field: string }>(extra.body.errors)
        .map((e) => e.field)
        .sort(),
    ).toEqual(['phone', 'role']);
    const none = await postComplete(h, completeBody(s.token, { consents: [] }), s.deviceKey);
    expect(none.status).toBe(400);
    const face = await postComplete(
      h,
      completeBody(s.token, { consents: [PD, { kind: 'face_scan', version: CONSENT_VERSION }] }),
      s.deviceKey,
    );
    expect(face.status).toBe(400);
    expect(face.body.errors[0].rule).toBe('consent_kind');
    const name = await postComplete(h, completeBody(s.token, { fullName: 'Тест 123' }), s.deviceKey);
    expect(name.status).toBe(400);
    expect(name.body.errors[0]).toMatchObject({ field: 'fullName', rule: 'full_name_format' });
    const sphere = await postComplete(
      h,
      completeBody(s.token, { activitySphere: 'astronaut', consents: [PD, SPHERE] }),
      s.deviceKey,
    );
    expect(sphere.status).toBe(400);
    expect(sphere.body.errors[0]).toMatchObject({ field: 'activitySphere', rule: 'activity_sphere' });
    // Токен не израсходован ошибками валидации
    expect((await postComplete(h, completeBody(s.token), s.deviceKey)).status).toBe(201);
  });

  it('T-REG-006, T-REG-007, 08 §4.2.1: без personal_data → 422 CONSENT_REQUIRED; activitySphere без согласия → 422; без поля и согласия → 201', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    const noPd = await postComplete(h, completeBody(s.token, { consents: [SPHERE] }), s.deviceKey);
    expect(noPd.status).toBe(422);
    expect(noPd.body.code).toBe('CONSENT_REQUIRED');
    const oldVersion = await postComplete(
      h,
      completeBody(s.token, { consents: [{ kind: 'personal_data', version: '2025-01-01' }] }),
      s.deviceKey,
    );
    expect(oldVersion.body.code).toBe('CONSENT_REQUIRED');
    const sphereNoConsent = await postComplete(h, completeBody(s.token, { activitySphere: 'plumber' }), s.deviceKey);
    expect(sphereNoConsent.status).toBe(422);
    expect(sphereNoConsent.body.code).toBe('CONSENT_REQUIRED');
    const bioNoConsent = await postComplete(
      h,
      completeBody(s.token, { biometricsEnabled: true, biometricClass: 'class3' }),
      s.deviceKey,
    );
    expect(bioNoConsent.body.code).toBe('CONSENT_REQUIRED');
    const ok = await postComplete(h, completeBody(s.token), s.deviceKey);
    expect(ok.status).toBe(201);
    expect(ok.body.user.profile).toMatchObject({ activitySphere: null, birthYear: 1990, fullName: 'Тестов Тест' });

    const s2 = await seedRegistration(fdb.db, h.jwt);
    const withSphere = await postComplete(
      h,
      completeBody(s2.token, {
        activitySphere: 'plumber',
        consents: [PD, SPHERE, { kind: 'sms', version: CONSENT_VERSION }],
      }),
      s2.deviceKey,
    );
    expect(withSphere.status).toBe(201);
    expect(withSphere.body.user.profile.activitySphere).toBe('plumber');
    const kinds = list<{ kind: string }>(withSphere.body.user.consents)
      .map((c) => c.kind)
      .sort();
    expect(kinds).toEqual(['activity_sphere', 'personal_data']); // sms при регистрации не записывается (09 §7.3)
  });

  it('T-SEC-048 (часть D), RM-D-004 п. 6, DATA-113: согласие хранится с версией, SHA-256 текста, временем, устройством (biometrics_device) и challenge', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    const r = await postComplete(
      h,
      completeBody(s.token, { biometricsEnabled: true, biometricClass: 'class3', consents: [PD, BIO] }),
      s.deviceKey,
    );
    expect(r.status).toBe(201);
    const rows = await fdb.db.select().from(consents).where(eq(consents.userId, r.body.user.id));
    expect(rows).toHaveLength(2);
    const [dev] = await fdb.db.select().from(devices).where(eq(devices.userId, r.body.user.id));
    for (const row of rows) {
      expect(row.version).toBe(CONSENT_VERSION);
      expect(row.textSha256.toString('hex')).toBe(CONSENT_CATALOG[row.kind]?.versions[0]?.sha256);
      expect(row.grantedAt).toBeInstanceOf(Date);
      expect(row.revokedAt).toBeNull();
      expect(row.otpChallengeId).toBe(s.challengeId);
      expect(row.deviceId).toBe(row.kind === 'biometrics_device' ? dev?.id : null);
    }
  });

  it('T-REG-025 (а, б, в, е): 08 API-182, AC-API-182: клиент без PIN и без биометрии → 400 login_protection_required; только биометрия Android class3 → 201 (pinSet=false); Windows без PIN → 400', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    const nothing = await postComplete(h, completeBody(s.token, { pin: null }), s.deviceKey);
    expect(nothing.status).toBe(400);
    expect(nothing.body.errors[0]).toMatchObject({ field: 'security', rule: 'login_protection_required' });
    const win = await postComplete(
      h,
      completeBody(s.token, {
        pin: null,
        biometricsEnabled: true,
        platform: 'windows',
        biometricClass: 'windows_hello',
        consents: [PD, BIO],
      }),
      s.deviceKey,
    );
    expect(win.status).toBe(400);
    expect(win.body.errors[0].rule).toBe('login_protection_required');
    const class2 = await postComplete(
      h,
      completeBody(s.token, { pin: null, biometricsEnabled: true, biometricClass: 'class2', consents: [PD, BIO] }),
      s.deviceKey,
    );
    expect(class2.status).toBe(400);
    const bio = await postComplete(
      h,
      completeBody(s.token, { pin: null, biometricsEnabled: true, biometricClass: 'class3', consents: [PD, BIO] }),
      s.deviceKey,
    );
    expect(bio.status).toBe(201);
    expect(bio.body.biometricRefreshOffered).toBe(true);
    expect(bio.body.user.security.pinSet).toBe(false);
    expect(await fdb.db.select().from(appPins).where(eq(appPins.userId, bio.body.user.id))).toHaveLength(0);
  });

  it('T-BIO-011 (регистрация): слабые PIN → 400 pin_weak; RM-D-004 п. 9 — в app_pins только Argon2id-хэш с pepper_version, PIN нет ни в БД, ни в логах', async () => {
    for (const weak of ['0000', '1234', '111111', '123456', '654321', '1990']) {
      const s = await seedRegistration(fdb.db, h.jwt);
      const r = await postComplete(h, completeBody(s.token, { pin: weak, birthYear: 1990 }), s.deviceKey);
      expect(r.status, weak).toBe(400);
      expect(r.body.errors[0]).toMatchObject({ field: 'security.pin', rule: 'pin_weak' });
    }
    const s = await seedRegistration(fdb.db, h.jwt);
    const pin = '804613';
    const r = await postComplete(h, completeBody(s.token, { pin }), s.deviceKey);
    expect(r.status).toBe(201);
    const [row] = await fdb.db.select().from(appPins).where(eq(appPins.userId, r.body.user.id));
    expect(row?.pinHash).toMatch(/^\$argon2id\$v=19\$m=19456,t=2,p=1\$/);
    expect(row).toMatchObject({ pepperVersion: 1, pinLength: 6, failedAttempts: 0, lockedUntil: null });
    expect(row?.pinHash).not.toContain(pin);
    const dump = await fdb.pool.query<{ t: string }>(
      `SELECT row_to_json(a)::text AS t FROM app_pins a WHERE user_id = $1`,
      [r.body.user.id],
    );
    expect(dump.rows[0]?.t).not.toContain(`"${pin}"`);
    const audit = await fdb.pool.query<{ t: string }>(
      `SELECT coalesce(string_agg(after::text, ' '), '') AS t FROM audit_logs WHERE actor_user_id = $1 OR entity_id = $1`,
      [r.body.user.id],
    );
    expect(audit.rows[0]?.t).not.toContain(pin);
    expect(logs.text).not.toContain(pin);
    expect(logs.text).not.toContain(s.phone);
    expect(logs.text).not.toContain(r.body.refreshToken);
    expect(logs.text).not.toContain(s.token);
  });

  it('аудит 11 §7.2: user.created (система, roleSource=self, телефон — маска), consent.granted, auth.pin.set; цепочка аудита цела', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    const r = await postComplete(
      h,
      completeBody(s.token, { activitySphere: 'foreman', consents: [PD, SPHERE] }),
      s.deviceKey,
    );
    expect(r.status).toBe(201);
    const uid = r.body.user.id as string;
    const rows = await fdb.db.select().from(auditLogs).where(eq(auditLogs.level, 'app'));
    const mine = rows.filter((a) => a.entityId === uid || a.actorUserId === uid);
    const created = mine.find((a) => a.action === 'user.created');
    expect(created).toMatchObject({ actorUserId: null, entityType: 'users', result: 'ok' });
    expect(created?.after).toMatchObject({ kind: 'customer', status: 'active', roleSource: 'self' });
    expect(JSON.stringify(created?.after)).not.toContain(s.phone);
    expect(mine.filter((a) => a.action === 'consent.granted')).toHaveLength(2);
    expect(mine.find((a) => a.action === 'auth.pin.set')).toMatchObject({ actorUserId: uid, actorRole: 'customer' });
    const chain = await h.app.get(AuditAnchorService).verifyChain();
    expect(chain.ok).toBe(true);
  });

  it('T-AUTH-043, RM-D-005/REG-039 через CustomerLinksService модуля customers: 0 → none, 1 → proposed (маска, без id), ≥ 2 → conflict; GET /registration/customer-match без финансов', async () => {
    const s1 = await seedRegistration(fdb.db, h.jwt);
    await seedCustomer(fdb.db, 'ОсОО «Строймаркет»', s1.phone);
    const one = await postComplete(h, completeBody(s1.token), s1.deviceKey);
    expect(one.status).toBe(201);
    expect(one.body.customerMatch).toMatchObject({ status: 'proposed', linkId: expect.any(String) });
    expect(['confirm_or_reject', 'wait_admin']).toContain(one.body.customerMatch.nextStep);
    expect(one.body.user.customerLink).toEqual({
      linkId: one.body.customerMatch.linkId,
      status: 'proposed',
      displayNameMasked: 'ОсОО «Стр***»',
    });
    const cm = await h
      .http()
      .get('/api/v1/registration/customer-match')
      .set('Authorization', `Bearer ${one.body.accessToken}`)
      .set('X-Device-Id', s1.deviceKey);
    expect(cm.status).toBe(200);
    expect(cm.body).toMatchObject({
      status: 'proposed',
      linkId: one.body.customerMatch.linkId,
      customer: { displayNameMasked: 'ОсОО «Стр***»' },
    });
    expect(JSON.stringify(cm.body)).not.toMatch(/Строймаркет|receivable|balance|debt/);
    const post = await h
      .http()
      .post('/api/v1/registration/customer-match')
      .set('Authorization', `Bearer ${one.body.accessToken}`)
      .set('X-Device-Id', s1.deviceKey)
      .send({});
    expect(post.status).toBe(405);

    const none = await seedRegistration(fdb.db, h.jwt);
    const zero = await postComplete(h, completeBody(none.token), none.deviceKey);
    expect(zero.body.customerMatch).toEqual({ status: 'none', linkId: null, nextStep: 'none' });

    const s2 = await seedRegistration(fdb.db, h.jwt);
    await seedCustomer(fdb.db, 'ИП Абдыкадыров', s2.phone, 'entrepreneur');
    await seedCustomer(fdb.db, 'ОсОО «Ак-Төө»', s2.phone);
    const two = await postComplete(h, completeBody(s2.token), s2.deviceKey);
    expect(two.body.customerMatch).toMatchObject({ status: 'conflict', nextStep: 'wait_admin' });
    expect(await linksOf(fdb.db, two.body.user.id)).toHaveLength(2);
  });

  it('сбой порта привязки не ломает регистрацию (customerMatch none + предупреждение); без порта — none и registration.customer_match_unavailable', async () => {
    const failing = new FailingCustomerMatching();
    const broken = await createHarness(fdb, { matching: failing, logs });
    const noPort = await createHarness(fdb, { logs });
    try {
      const s = await seedRegistration(fdb.db, broken.jwt);
      const r = await postComplete(broken, completeBody(s.token), s.deviceKey);
      expect(r.status).toBe(201);
      expect(r.body.customerMatch).toEqual({ status: 'none', linkId: null, nextStep: 'none' });
      expect(failing.calls.at(-1)).toMatchObject({ userId: r.body.user.id, phoneE164: s.phone });
      expect(logs.text).toContain('registration.customer_match_failed');

      const s2 = await seedRegistration(fdb.db, noPort.jwt);
      const r2 = await postComplete(noPort, completeBody(s2.token), s2.deviceKey);
      expect(r2.status).toBe(201);
      expect(r2.body.customerMatch).toEqual({ status: 'none', linkId: null, nextStep: 'none' });
      expect(logs.text).toContain('registration.customer_match_unavailable');
      // Me.customerLink читает customer_links напрямую (подтверждённая привязка — с id и наименованием)
      const cid = await seedCustomer(fdb.db, 'ОсОО «Бетонстрой»', s2.phone);
      await fdb.db
        .insert(customerLinks)
        .values({ userId: r2.body.user.id, customerId: cid, status: 'confirmed', matchMethod: 'manual_admin' });
      const me = await noPort
        .http()
        .get('/api/v1/me')
        .set('Authorization', `Bearer ${r2.body.accessToken}`)
        .set('X-Device-Id', s2.deviceKey);
      expect(me.body.customerLink).toEqual({
        linkId: expect.any(String),
        status: 'confirmed',
        displayNameMasked: 'ОсОО «Бет***»',
        customerId: cid,
        displayName: 'Бетонстрой', // PR-09: как Customer.displayName (08 §3.7)
      });
    } finally {
      await broken.app.close();
      await noPort.app.close();
    }
  });

  it('профиль создаётся из формы (ФИО нормализуется), устройство — из device, время — из часов сервера', async () => {
    const s = await seedRegistration(fdb.db, h.jwt);
    const r = await postComplete(h, completeBody(s.token, { fullName: "  O'Neil-Smith   Джон " }), s.deviceKey);
    expect(r.status).toBe(201);
    const [p] = await fdb.db.select().from(userProfiles).where(eq(userProfiles.userId, r.body.user.id));
    expect(p?.fullName).toBe("O'Neil-Smith Джон");
    const [d] = await fdb.db
      .select()
      .from(devices)
      .where(and(eq(devices.userId, r.body.user.id), eq(devices.deviceKey, s.deviceKey)));
    expect(d).toMatchObject({
      platform: 'android',
      displayName: 'Тестовый телефон',
      appVersion: '1.0.0+1',
      osVersion: '14',
    });
    expect(r.body.user.session).toMatchObject({ deviceId: s.deviceKey, deviceName: 'Тестовый телефон' });
  });
});

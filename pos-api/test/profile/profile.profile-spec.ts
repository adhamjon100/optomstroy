import { randomUUID } from 'node:crypto';
import { and, eq, isNull } from 'drizzle-orm';
import { AuditAnchorService } from '../../src/common/audit/audit-anchor.service.js';
import { verify } from '@node-rs/argon2';
import {
  appPins,
  auditLogs,
  consents,
  customerLinks,
  devices,
  notifications,
  sessions,
  userProfiles,
  users,
  warehouses,
} from '../../src/db/schema/index.js';
import type { RoleCode } from '../../src/users/users.types.js';
import { seedSubject } from '../foundation/support/foundation-db.js';
import { validateAgainst } from '../settings/support/openapi-check.js';
import {
  cleanupSecrets,
  list,
  completeBody,
  CONSENT_VERSION,
  createHarness,
  harnessConfig,
  OTP_TEST_CODE,
  OTP_TEST_PHONES,
  FoundationDb,
  type Harness,
  LogCapture,
  postComplete,
  regPhone,
  seedCustomer,
  seedRegistration,
  stepUpToken,
} from '../registration/support/harness.js';

interface Subject {
  readonly userId: string;
  readonly sid: string;
  readonly deviceKey: string;
  readonly access: string;
  readonly phone?: string;
}

const PD = { kind: 'personal_data', version: CONSENT_VERSION };
const BIO = { kind: 'biometrics_device', version: CONSENT_VERSION };

describe('модуль profile: /me, /me/profile, /me/settings, /me/pin, /me/biometrics, /me/consents, /me/phone/change (RM-D-004, RM-D-014; 08 §4.3)', () => {
  const fdb = new FoundationDb();
  const logs = new LogCapture();
  let h: Harness;

  beforeAll(async () => {
    await fdb.start('profile_e2e');
    h = await createHarness(fdb, { logs });
  });

  afterAll(async () => {
    await h?.app.close();
    await fdb.stop();
    cleanupSecrets();
  });

  /** Новый access-токен той же сессии (после сдвига часов > 15 мин прежний истекает — AUTH_ACCESS_TTL_SECONDS). */
  async function reissue(s: Subject, kind: 'staff' | 'customer', roles: RoleCode[]): Promise<Subject> {
    const t = await h.jwt.signAccess({
      sub: s.userId,
      kind,
      roles,
      permissionsVersion: 1,
      deviceId: s.deviceKey,
      sid: s.sid,
    });
    return { ...s, access: t.token };
  }

  async function registerCustomer(
    o: Parameters<typeof completeBody>[1] & { platform?: 'android' | 'ios' | 'windows' } = {},
  ): Promise<Subject> {
    const s = await seedRegistration(fdb.db, h.jwt);
    const r = await postComplete(h, completeBody(s.token, o), s.deviceKey);
    expect(r.status).toBe(201);
    return {
      userId: r.body.user.id,
      sid: r.body.sid,
      deviceKey: s.deviceKey,
      access: r.body.accessToken,
      phone: s.phone,
    };
  }

  async function staff(
    role: RoleCode = 'seller',
    status: 'active' | 'pending_activation' = 'active',
  ): Promise<Subject> {
    const s = await seedSubject(fdb.db, { role, status });
    await fdb.db.insert(userProfiles).values({ userId: s.userId, fullName: 'Продавцов Пётр' });
    const access = await h.jwt.signAccess({
      sub: s.userId,
      kind: 'staff',
      roles: status === 'pending_activation' ? [] : [role],
      permissionsVersion: 1,
      deviceId: s.deviceKey,
      sid: s.session.id,
    });
    return { userId: s.userId, sid: s.session.id, deviceKey: s.deviceKey, access: access.token };
  }

  const call = (method: 'get' | 'post' | 'patch' | 'put' | 'delete', path: string, s: Subject, stepUp?: string) => {
    let r = h
      .http()
      [method](`/api/v1${path}`)
      .set('Authorization', `Bearer ${s.access}`)
      .set('X-Device-Id', s.deviceKey);
    if (stepUp) r = r.set('X-Step-Up-Token', stepUp);
    return r;
  };

  const auditOf = async (userId: string, action: string) =>
    (
      await fdb.db
        .select()
        .from(auditLogs)
        .where(and(eq(auditLogs.action, action), eq(auditLogs.level, 'app')))
    ).filter((a) => a.entityId === userId || a.actorUserId === userId);

  describe('GET /me (08 §4.3.1)', () => {
    it('customer: роли, permissions, профиль с телефоном, настройки по умолчанию, защита входа, согласия, сессия', async () => {
      const c = await registerCustomer();
      const r = await call('get', '/me', c);
      expect(r.status).toBe(200);
      expect(r.headers['cache-control']).toBe('no-store');
      expect(r.body).toMatchObject({
        id: c.userId,
        kind: 'customer',
        status: 'active',
        roles: ['customer'],
        permissionsVersion: 1,
        profile: {
          fullName: 'Тестов Тест',
          phone: c.phone,
          birthYear: 1990,
          activitySphere: null,
          avatarUrl: null,
          rowVersion: 1,
        },
        customerLink: { status: 'none', linkId: null },
        settings: {
          locale: 'ru',
          scanner: { mode: 'camera', suffix: 'enter' },
          scanAddsToCart: false,
          printer: { defaultFormat: 'a4', autoPrint: false },
          catalogView: 'grid',
          defaultWarehouseId: null,
          idleLockMinutes: 60,
          rowVersion: 1,
        },
        security: { pinSet: true, biometricsEnabled: false, biometricsPlatform: 'none' },
        consents: [{ kind: 'personal_data', version: CONSENT_VERSION, granted: true, revokedAt: null }],
        session: { sid: c.sid, deviceId: c.deviceKey, deviceName: 'Тестовый телефон', amr: ['sms'] },
        apiVersion: '1.0',
      });
      expect(r.body.permissions).toContain('profile.manage.own');
      expect(r.body.permissions).not.toContain('users.manage');
      expect(r.body.discountLimitPercent).toBeUndefined();
    });

    it('staff cashier: scanAddsToCart=true, thermal80, idle 30; pending_activation — усечённый DTO (псевдо-набор прав)', async () => {
      const cashier = await staff('cashier');
      const r = await call('get', '/me', cashier);
      expect(r.status).toBe(200);
      expect(r.body.settings).toMatchObject({
        scanAddsToCart: true,
        printer: { defaultFormat: 'thermal80' },
        idleLockMinutes: 30,
      });
      expect(r.body.customerLink).toBeUndefined();
      expect(r.body.security.pinSet).toBe(false);
      const pending = await staff('seller', 'pending_activation');
      const p = await call('get', '/me', pending);
      expect(p.status).toBe(200);
      expect(p.body).toMatchObject({ status: 'pending_activation', roles: ['seller'] });
      expect(p.body.permissions).toEqual(['profile.manage.own', 'session.manage.own', 'settings.public.read']);
      expect(p.body.discountLimitPercent).toBeUndefined();
      expect((await h.http().get('/api/v1/me')).status).toBe(401);
    });
  });

  describe('PATCH /me/profile (08 §4.3.2)', () => {
    it('rowVersion: применяется с rowVersion+1, устаревший → 409 VERSION_CONFLICT с current; аудит profile.updated — только имена полей', async () => {
      const c = await registerCustomer();
      const ok = await call('patch', '/me/profile', c).send({
        fullName: 'Новиков Новик',
        birthYear: 1985,
        rowVersion: 1,
      });
      expect(ok.status).toBe(200);
      expect(ok.body).toMatchObject({ fullName: 'Новиков Новик', birthYear: 1985, rowVersion: 2, phone: c.phone });
      const stale = await call('patch', '/me/profile', c).send({ fullName: 'Другой Иван', rowVersion: 1 });
      expect(stale.status).toBe(409);
      expect(stale.body.code).toBe('VERSION_CONFLICT');
      expect(stale.body.current).toMatchObject({ fullName: 'Новиков Новик', rowVersion: 2 });
      const [audit] = await auditOf(c.userId, 'profile.updated');
      expect(audit?.after).toEqual({ fields: ['fullName', 'birthYear'] });
      expect(JSON.stringify(audit)).not.toContain('Новиков');
    });

    it('phone/roles/status → 400 forbidden_field; birthYear вне диапазона → 400 birth_year_range; activitySphere без согласия → 422 CONSENT_REQUIRED', async () => {
      const c = await registerCustomer();
      const forbidden = await call('patch', '/me/profile', c).send({
        phone: '+996700000001',
        roles: ['admin'],
        status: 'active',
        rowVersion: 1,
      });
      expect(forbidden.status).toBe(400);
      expect(
        list<{ field: string; rule: string }>(forbidden.body.errors)
          .map((e) => `${e.field}:${e.rule}`)
          .sort(),
      ).toEqual(['phone:forbidden_field', 'roles:forbidden_field', 'status:forbidden_field']);
      const year = await call('patch', '/me/profile', c).send({
        birthYear: new Date().getUTCFullYear() - 10,
        rowVersion: 1,
      });
      expect(year.status).toBe(400);
      expect(year.body.errors[0].rule).toBe('birth_year_range');
      const sphere = await call('patch', '/me/profile', c).send({ activitySphere: 'plumber', rowVersion: 1 });
      expect(sphere.status).toBe(422);
      expect(sphere.body.code).toBe('CONSENT_REQUIRED');
      const grant = await call('post', '/me/consents', c).send({
        kind: 'activity_sphere',
        version: CONSENT_VERSION,
        granted: true,
      });
      expect(grant.status).toBe(200);
      const ok = await call('patch', '/me/profile', c).send({ activitySphere: 'plumber', rowVersion: 1 });
      expect(ok.status).toBe(200);
      expect(ok.body.activitySphere).toBe('plumber');
    });

    it('T-REG-021: профиль приложения меняется, карточка 1С (customers) — нет', async () => {
      const c = await registerCustomer();
      const cid = await seedCustomer(fdb.db, 'ОсОО «Неизменный»', c.phone ?? regPhone());
      await fdb.db
        .insert(customerLinks)
        .values({ userId: c.userId, customerId: cid, status: 'confirmed', matchMethod: 'phone' });
      const r = await call('patch', '/me/profile', c).send({ fullName: 'Переименов Пётр', rowVersion: 1 });
      expect(r.status).toBe(200);
      const res = await fdb.pool.query<{ name: string }>('SELECT name FROM customers WHERE id = $1', [cid]);
      expect(res.rows[0]?.name).toBe('ОсОО «Неизменный»');
      const me = await call('get', '/me', c);
      expect(me.body.customerLink).toMatchObject({
        status: 'confirmed',
        customerId: cid,
        displayName: 'Неизменный', // PR-09: значимая часть без формы собственности (08 §3.7)
      });
    });
  });

  describe('PUT /me/settings (08 §4.3.4)', () => {
    it('полная замена с rowVersion; устаревший → 409; staff idle > 30 → 400; customer 60 — можно; неизвестный склад → 400', async () => {
      const s = await staff('seller');
      const v0 = (await call('get', '/me', s)).body.settings.rowVersion as number;
      expect(v0).toBe(1); // = user_profiles.row_version
      const body = {
        locale: 'ky',
        scanner: { mode: 'hid', suffix: 'tab' },
        scanAddsToCart: true,
        printer: { defaultFormat: 'thermal80', autoPrint: true },
        catalogView: 'list',
        defaultWarehouseId: null,
        idleLockMinutes: 15,
        rowVersion: v0,
      };
      const ok = await call('put', '/me/settings', s).send(body);
      expect(ok.status).toBe(200);
      expect(ok.body).toEqual({ ...body, rowVersion: 2 });
      const me = await call('get', '/me', s);
      expect(me.body.settings).toEqual({ ...body, rowVersion: 2 });
      expect(me.body.profile.rowVersion).toBe(2); // общая версия строки user_profiles (07 §8.3)
      const stale = await call('put', '/me/settings', s).send(body);
      expect(stale.status).toBe(409);
      expect(stale.body.current.rowVersion).toBe(2);
      const tooLong = await call('put', '/me/settings', s).send({ ...body, idleLockMinutes: 31, rowVersion: 2 });
      expect(tooLong.status).toBe(400);
      expect(tooLong.body.errors[0]).toMatchObject({ field: 'idleLockMinutes', rule: 'idle_lock_range' });
      const tooShort = await call('put', '/me/settings', s).send({ ...body, idleLockMinutes: 4, rowVersion: 2 });
      expect(tooShort.status).toBe(400);
      const unknownWh = await call('put', '/me/settings', s).send({
        ...body,
        defaultWarehouseId: randomUUID(),
        rowVersion: 2,
      });
      expect(unknownWh.status).toBe(400);
      expect(unknownWh.body.errors[0].rule).toBe('warehouse_unknown');
      const [wh] = await fdb.db
        .insert(warehouses)
        .values({ onecRef: randomUUID(), name: 'Основной склад', syncedAt: new Date(), sourceHash: 'test' })
        .returning({ id: warehouses.id });
      const withWh = await call('put', '/me/settings', s).send({ ...body, defaultWarehouseId: wh?.id, rowVersion: 2 });
      expect(withWh.status).toBe(200);
      expect(withWh.body).toMatchObject({ defaultWarehouseId: wh?.id, rowVersion: 3 });
      const missing = await call('put', '/me/settings', s).send({ locale: 'ru', rowVersion: 3 });
      expect(missing.status).toBe(400);
      const c = await registerCustomer();
      const cust = await call('put', '/me/settings', c).send({ ...body, idleLockMinutes: 60, rowVersion: 1 });
      expect(cust.status).toBe(200);
    });
  });

  describe('POST /me/pin, DELETE /me/pin (08 §4.3.5; D-48; 09 §9.6)', () => {
    it('T-BIO-013 «Забыли PIN?»: PIN заблокирован → step-up по OTP (pin_reset) → POST /me/pin → новый хэш, блокировка снята, аудит auth.pin.changed (otp)', async () => {
      const s = await staff('cashier');
      await fdb.db.insert(appPins).values({
        userId: s.userId,
        pinHash: 'locked-placeholder-hash',
        pepperVersion: 1,
        pinLength: 6,
        failedAttempts: 5,
        lockedUntil: new Date(Date.now() + 365 * 24 * 3600_000),
        changedAt: new Date(),
      });
      // без step-up — 403 (сброс PIN = смена при существующем PIN)
      expect((await call('post', '/me/pin', s).send({ newPin: '583092' })).body.code).toBe('STEP_UP_REQUIRED');
      const su = await stepUpToken(h.jwt, s, 'profile.pin.set', 'otp');
      const r = await call('post', '/me/pin', s, su).send({ newPin: '583092' });
      expect(r.status).toBe(204);
      const [row] = await fdb.db.select().from(appPins).where(eq(appPins.userId, s.userId));
      expect(row).toMatchObject({ failedAttempts: 0, lockedUntil: null, pinLength: 6 });
      expect(row?.pinHash).not.toBe('locked-placeholder-hash');
      const [audit] = await auditOf(s.userId, 'auth.pin.changed');
      expect(audit).toMatchObject({ stepUpMethod: 'otp', result: 'ok' });
    });

    it('первый PIN после OTP-входа (≤ 15 мин, pinSet=false) — без step-up; смена — 403 STEP_UP_REQUIRED, со step-up — 204 и новый хэш', async () => {
      const c = await registerCustomer({
        pin: null,
        biometricsEnabled: true,
        biometricClass: 'class3',
        consents: [PD, BIO],
      });
      const first = await call('post', '/me/pin', c).send({ newPin: '5830' });
      expect(first.status).toBe(204);
      const [row1] = await fdb.db.select().from(appPins).where(eq(appPins.userId, c.userId));
      expect(row1).toMatchObject({ pinLength: 4, pepperVersion: 1 });
      expect((await auditOf(c.userId, 'auth.pin.set')).length).toBe(1);

      const again = await call('post', '/me/pin', c).send({ newPin: '9471' });
      expect(again.status).toBe(403);
      expect(again.body).toMatchObject({
        code: 'STEP_UP_REQUIRED',
        stepUp: { operation: 'profile.pin.set', allowedMethods: ['pin', 'otp'] },
      });
      const wrongScope = await stepUpToken(h.jwt, c, 'profile.phone.change');
      expect((await call('post', '/me/pin', c, wrongScope).send({ newPin: '9471' })).status).toBe(403);
      const otherSession = await stepUpToken(h.jwt, { ...c, sid: randomUUID() }, 'profile.pin.set');
      expect((await call('post', '/me/pin', c, otherSession).send({ newPin: '9471' })).status).toBe(403);
      const su = await stepUpToken(h.jwt, c, 'profile.pin.set', 'pin');
      const changed = await call('post', '/me/pin', c, su).send({ newPin: '9471' });
      expect(changed.status).toBe(204);
      const [row2] = await fdb.db.select().from(appPins).where(eq(appPins.userId, c.userId));
      expect(row2?.pinHash).not.toBe(row1?.pinHash);
      const [changedAudit] = await auditOf(c.userId, 'auth.pin.changed');
      expect(changedAudit).toMatchObject({ stepUpMethod: 'pin', result: 'ok' });
      // Повтор того же PIN → 204 без смены хэша (аудит — повторно, 08 §4.3.5)
      expect((await call('post', '/me/pin', c, su).send({ newPin: '9471' })).status).toBe(204);
      const [row3] = await fdb.db.select().from(appPins).where(eq(appPins.userId, c.userId));
      expect(row3?.pinHash).toBe(row2?.pinHash);
    });

    it('priority 403 STEP_UP_REQUIRED раньше 400 (08 §2.4); окно OTP истекло → step-up обязателен и для первого PIN', async () => {
      const s0 = await staff('seller');
      h.clock.advance(16 * 60_000);
      try {
        const s = await reissue(s0, 'staff', ['seller']);
        const r = await call('post', '/me/pin', s).send({ newPin: 'abc' });
        expect(r.status).toBe(403);
        expect(r.body.stepUp).toEqual({ operation: 'profile.pin.set', allowedMethods: ['pin', 'otp'] });
        const su = await stepUpToken(h.jwt, s, 'profile.pin.set', 'otp');
        const ok = await call('post', '/me/pin', s, su).send({ newPin: '804613' });
        expect(ok.status).toBe(204);
      } finally {
        h.clock.advance(-16 * 60_000);
      }
    });

    it('T-BIO-011: слабые PIN → 400 pin_weak; staff — 6 цифр (PIN_MIN_LENGTH_STAFF); хэш Argon2id m=19456,t=2,p=1 с pepper; PIN нет в логах', async () => {
      const s = await staff('cashier');
      for (const weak of ['0000', '1234', '111111', '123456', '654321', '5830']) {
        const r = await call('post', '/me/pin', s).send({ newPin: weak });
        expect(r.status, weak).toBe(400);
        expect(r.body.errors[0]).toMatchObject({ field: 'newPin', rule: 'pin_weak' });
      }
      const bad = await call('post', '/me/pin', s).send({ newPin: '12ab' });
      expect(bad.status).toBe(400);
      expect(bad.body.errors[0].rule).toBe('pin_weak');
      const ok = await call('post', '/me/pin', s).send({ newPin: '730518' });
      expect(ok.status).toBe(204);
      const [row] = await fdb.db.select().from(appPins).where(eq(appPins.userId, s.userId));
      expect(row?.pinHash).toMatch(/^\$argon2id\$v=19\$m=19456,t=2,p=1\$/);
      // Хэш без pepper не сходится: в материале — pepper ‖ pin ‖ user_id (07 §5.13)
      expect(await verify(row?.pinHash ?? '', Buffer.from(`730518${s.userId}`))).toBe(false);
      expect(logs.text).not.toContain('730518');
      const me = await call('get', '/me', s);
      expect(me.body.security.pinSet).toBe(true);
    });

    it('DELETE /me/pin: staff → 403 pin_required_for_staff; customer без биометрии → 422 login_protection_required; с биометрией и step-up → 204', async () => {
      const s = await staff('seller');
      await call('post', '/me/pin', s).send({ newPin: '730518' });
      const suS = await stepUpToken(h.jwt, s, 'profile.pin.set');
      const staffDel = await call('delete', '/me/pin', s, suS);
      expect(staffDel.status).toBe(403);
      expect(staffDel.body).toMatchObject({ code: 'FORBIDDEN', reason: 'pin_required_for_staff' });

      const c = await registerCustomer({ consents: [PD, BIO], biometricsEnabled: true, biometricClass: 'class3' });
      const su = await stepUpToken(h.jwt, c, 'profile.pin.set');
      expect((await call('delete', '/me/pin', c)).status).toBe(403);
      const noBio = await call('delete', '/me/pin', c, su);
      expect(noBio.status).toBe(422);
      expect(noBio.body.errors[0].rule).toBe('login_protection_required');
      const en = await call('post', '/me/biometrics', c).send({ enabled: true, biometricClass: 'class3' });
      expect(en.status).toBe(200);
      expect((await call('delete', '/me/pin', c, su)).status).toBe(204);
      expect((await call('delete', '/me/pin', c, su)).status).toBe(204);
      expect(await fdb.db.select().from(appPins).where(eq(appPins.userId, c.userId))).toHaveLength(0);
      expect((await auditOf(c.userId, 'auth.pin.removed')).length).toBe(1);
    });
  });

  describe('POST /me/biometrics (08 §4.3.6; 09 §9.5; D-13)', () => {
    it('включение сразу после OTP-регистрации без step-up: biometric_refresh отдельной семьи, enrolled, повтор — новый токен и отзыв прежней семьи', async () => {
      const c = await registerCustomer();
      const en = await call('post', '/me/biometrics', c).send({
        enabled: true,
        biometricClass: 'class3',
        consent: { kind: 'biometrics_device', version: CONSENT_VERSION, granted: true },
      });
      expect(en.status).toBe(200);
      expect(en.body).toMatchObject({
        enabled: true,
        biometricRefreshToken: expect.any(String),
        expiresAt: expect.any(String),
      });
      const bio = await fdb.db
        .select()
        .from(sessions)
        .where(and(eq(sessions.userId, c.userId), eq(sessions.kind, 'biometric'), isNull(sessions.revokedAt)));
      expect(bio).toHaveLength(1);
      const [std] = await fdb.db.select().from(sessions).where(eq(sessions.id, c.sid));
      expect(bio[0]?.familyId).not.toBe(std?.familyId);
      expect(bio[0]?.expiresAt.getTime()).toBeLessThanOrEqual(std?.expiresAt.getTime() ?? 0);
      expect(bio[0]?.amr).toEqual(['sms', 'bio']);
      const me = await call('get', '/me', c);
      expect(me.body.security).toMatchObject({ biometricsEnabled: true, biometricsPlatform: 'android_class3' });
      expect(list<{ kind: string }>(me.body.consents).find((x) => x.kind === 'biometrics_device')).toMatchObject({
        granted: true,
      });

      const again = await call('post', '/me/biometrics', c)
        .set('Idempotency-Key', randomUUID())
        .send({ enabled: true, biometricClass: 'class3' });
      expect(again.status).toBe(200);
      expect(again.body.biometricRefreshToken).not.toBe(en.body.biometricRefreshToken);
      const all = await fdb.db
        .select()
        .from(sessions)
        .where(and(eq(sessions.userId, c.userId), eq(sessions.kind, 'biometric')));
      expect(all.filter((x) => x.revokedAt === null)).toHaveLength(1);
      expect(all.find((x) => x.id === bio[0]?.id)?.revokeReason).toBe('session_limit');
      const stored = await fdb.pool.query<{ n: string }>(
        `SELECT count(*) AS n FROM idempotency_keys WHERE user_id = $1 AND route LIKE '%biometrics%'`,
        [c.userId],
      );
      expect(stored.rows[0]?.n).toBe('0'); // токен не попадает в idempotency_keys
      expect((await auditOf(c.userId, 'auth.biometrics.enabled')).length).toBe(2);
    });

    it('без согласия → 422 CONSENT_REQUIRED; Windows → enabled=false (no_crypto_binding_on_platform); после окна OTP — 403 STEP_UP_REQUIRED', async () => {
      const c = await registerCustomer();
      const noConsent = await call('post', '/me/biometrics', c).send({ enabled: true });
      expect(noConsent.status).toBe(422);
      expect(noConsent.body.code).toBe('CONSENT_REQUIRED');
      const badClass = await call('post', '/me/biometrics', c).send({
        enabled: true,
        biometricClass: 'ios',
        consent: { kind: 'biometrics_device', version: CONSENT_VERSION, granted: true },
      });
      expect(badClass.status).toBe(400);
      const w = await registerCustomer({ platform: 'windows' });
      const win = await call('post', '/me/biometrics', w).send({ enabled: true, biometricClass: 'windows_hello' });
      expect(win.status).toBe(200);
      expect(win.body).toEqual({ enabled: false, reason: 'no_crypto_binding_on_platform' });
      h.clock.advance(16 * 60_000);
      try {
        const c2 = await reissue(c, 'customer', ['customer']);
        const late = await call('post', '/me/biometrics', c2).send({ enabled: true });
        expect(late.status).toBe(403);
        expect(late.body.stepUp.operation).toBe('profile.biometrics.toggle');
        const su = await stepUpToken(h.jwt, c2, 'profile.biometrics.toggle', 'pin');
        const ok = await call('post', '/me/biometrics', c2, su).send({
          enabled: true,
          consent: { kind: 'biometrics_device', version: CONSENT_VERSION, granted: true },
        });
        expect(ok.status).toBe(200);
      } finally {
        h.clock.advance(-16 * 60_000);
      }
    });

    it('T-BIO-002: выключение — отзыв biometric-семьи, enrolled=NULL, отзыв согласия; повтор — 200 без изменений; клиент без PIN не может выключить последний способ', async () => {
      const c = await registerCustomer();
      await call('post', '/me/biometrics', c).send({
        enabled: true,
        consent: { kind: 'biometrics_device', version: CONSENT_VERSION, granted: true },
      });
      const off = await call('post', '/me/biometrics', c).send({ enabled: false });
      expect(off.status).toBe(200);
      expect(off.body).toEqual({ enabled: false });
      const active = await fdb.db
        .select()
        .from(sessions)
        .where(and(eq(sessions.userId, c.userId), eq(sessions.kind, 'biometric'), isNull(sessions.revokedAt)));
      expect(active).toHaveLength(0);
      const [d] = await fdb.db.select().from(devices).where(eq(devices.userId, c.userId));
      expect(d?.biometricEnrolledAt).toBeNull();
      const [cons] = await fdb.db
        .select()
        .from(consents)
        .where(and(eq(consents.userId, c.userId), eq(consents.kind, 'biometrics_device')));
      expect(cons?.revokedAt).not.toBeNull();
      expect((await call('post', '/me/biometrics', c).send({ enabled: false })).body).toEqual({ enabled: false });
      expect((await auditOf(c.userId, 'auth.biometrics.disabled')).length).toBe(1);

      const bioOnly = await registerCustomer({
        pin: null,
        biometricsEnabled: true,
        biometricClass: 'class3',
        consents: [PD, BIO],
      });
      expect((await call('post', '/me/biometrics', bioOnly).send({ enabled: true })).status).toBe(200);
      const last = await call('post', '/me/biometrics', bioOnly).send({ enabled: false });
      expect(last.status).toBe(422);
      expect(last.body.errors[0].rule).toBe('login_protection_required');
    });
  });

  describe('GET/POST /me/consents (08 §4.3.7, API-050; T-BIO-016)', () => {
    it('GET: items + required (personal_data, текущая версия); выдача — 200, повтор — без новой записи; неизвестная версия / face_scan → 400', async () => {
      const c = await registerCustomer();
      const list = await call('get', '/me/consents', c);
      expect(list.status).toBe(200);
      expect(list.body.required).toEqual([{ kind: 'personal_data', currentVersion: CONSENT_VERSION }]);
      expect(list.body.items).toHaveLength(1);
      const g1 = await call('post', '/me/consents', c).send({ kind: 'sms', version: CONSENT_VERSION, granted: true });
      expect(g1.status).toBe(200);
      expect(g1.body).toMatchObject({ kind: 'sms', version: CONSENT_VERSION, granted: true, revokedAt: null });
      const g2 = await call('post', '/me/consents', c).send({ kind: 'sms', version: CONSENT_VERSION, granted: true });
      expect(g2.body.grantedAt).toBe(g1.body.grantedAt);
      const rows = await fdb.db
        .select()
        .from(consents)
        .where(and(eq(consents.userId, c.userId), eq(consents.kind, 'sms')));
      expect(rows).toHaveLength(1);
      expect(
        (await auditOf(c.userId, 'consent.granted')).filter((a) => (a.after as { kind?: string }).kind === 'sms'),
      ).toHaveLength(1);
      const badVersion = await call('post', '/me/consents', c).send({
        kind: 'sms',
        version: '1999-01-01',
        granted: true,
      });
      expect(badVersion.status).toBe(400);
      expect(badVersion.body.errors[0].rule).toBe('consent_version');
      const face = await call('post', '/me/consents', c).send({
        kind: 'face_scan',
        version: CONSENT_VERSION,
        granted: true,
      });
      expect(face.status).toBe(400);
      const legacy = await call('post', '/me/consents', c).send({
        kind: 'biometric_unlock',
        version: CONSENT_VERSION,
        granted: true,
      });
      expect(legacy.status).toBe(400);
    });

    it('отзыв activity_sphere обнуляет сферу; отзыв biometrics_device выключает биометрию устройства', async () => {
      const s = await seedRegistration(fdb.db, h.jwt);
      const r = await postComplete(
        h,
        completeBody(s.token, {
          activitySphere: 'reseller',
          consents: [PD, { kind: 'activity_sphere', version: CONSENT_VERSION }],
        }),
        s.deviceKey,
      );
      const c: Subject = {
        userId: r.body.user.id,
        sid: r.body.sid,
        deviceKey: s.deviceKey,
        access: r.body.accessToken,
      };
      const rev = await call('post', '/me/consents', c).send({
        kind: 'activity_sphere',
        version: CONSENT_VERSION,
        granted: false,
      });
      expect(rev.status).toBe(200);
      expect(rev.body).toMatchObject({ kind: 'activity_sphere', granted: false, revokedAt: expect.any(String) });
      const me = await call('get', '/me', c);
      expect(me.body.profile.activitySphere).toBeNull();
      const again = await call('post', '/me/consents', c).send({
        kind: 'activity_sphere',
        version: CONSENT_VERSION,
        granted: false,
      });
      expect(again.status).toBe(200);
      expect((await auditOf(c.userId, 'consent.revoked')).length).toBe(1);

      await call('post', '/me/biometrics', c).send({
        enabled: true,
        consent: { kind: 'biometrics_device', version: CONSENT_VERSION, granted: true },
      });
      const revBio = await call('post', '/me/consents', c).send({
        kind: 'biometrics_device',
        version: CONSENT_VERSION,
        granted: false,
      });
      expect(revBio.status).toBe(200);
      const me2 = await call('get', '/me', c);
      expect(me2.body.security.biometricsEnabled).toBe(false);
      const bio = await fdb.db
        .select()
        .from(sessions)
        .where(and(eq(sessions.userId, c.userId), eq(sessions.kind, 'biometric'), isNull(sessions.revokedAt)));
      expect(bio).toHaveLength(0);
    });

    it('отзыв personal_data: без step-up → 403 STEP_UP_REQUIRED (profile.consent.revoke); со step-up → blocked, сессии отозваны, токен → 401 SESSION_REVOKED; уведомление admin (PR-06)', async () => {
      const admin = await staff('admin');
      const blockedAdmin = await staff('admin');
      await fdb.db.update(users).set({ status: 'blocked' }).where(eq(users.id, blockedAdmin.userId));
      const c = await registerCustomer();
      const noSu = await call('post', '/me/consents', c).send({
        kind: 'personal_data',
        version: CONSENT_VERSION,
        granted: false,
      });
      expect(noSu.status).toBe(403);
      expect(noSu.body.stepUp.operation).toBe('profile.consent.revoke');
      const su = await stepUpToken(h.jwt, c, 'profile.consent.revoke', 'otp');
      const ok = await call('post', '/me/consents', c, su).send({
        kind: 'personal_data',
        version: CONSENT_VERSION,
        granted: false,
      });
      expect(ok.status).toBe(200);
      expect(ok.body.granted).toBe(false);
      const [u] = await fdb.db.select().from(users).where(eq(users.id, c.userId));
      expect(u).toMatchObject({ status: 'blocked', blockReason: 'consent_personal_data_revoked' });
      const after = await call('get', '/me', c);
      expect(after.status).toBe(401);
      expect(after.body.code).toBe('SESSION_REVOKED');
      const [audit] = await auditOf(c.userId, 'consent.revoked');
      expect(audit).toMatchObject({ stepUpMethod: 'otp' });

      // D PR-06 (08 §4.3.7 «…с уведомлением администратора»): in-app уведомление активным admin, без ПДн
      const sent = await fdb.db
        .select()
        .from(notifications)
        .where(eq(notifications.dedupeKey, `consent.personal_data.revoked:${audit?.entityId}`));
      expect(sent.map((n) => n.userId)).toContain(admin.userId);
      expect(sent.map((n) => n.userId)).not.toContain(blockedAdmin.userId);
      expect(sent.map((n) => n.userId)).not.toContain(c.userId);
      const mine = sent.find((n) => n.userId === admin.userId);
      expect(mine).toMatchObject({ kind: 'system', severity: 'warning' });
      expect(mine?.payload).toEqual({ target: null, userId: c.userId, reason: 'consent_personal_data_revoked' });
      const text = `${mine?.titleRu} ${mine?.bodyRu} ${JSON.stringify(mine?.payload)}`;
      expect(text).not.toContain(c.phone?.slice(4) ?? '—');
      const [profile] = await fdb.db.select().from(userProfiles).where(eq(userProfiles.userId, c.userId));
      if (profile?.fullName) expect(text).not.toContain(profile.fullName);
    });
  });

  describe('POST /me/phone/change/request|confirm (08 §4.3.3; 09 §4.7; T-REG-022)', () => {
    it('T-AUTH-029: request без step-up → 403; занятый номер → 409; со step-up → 202; confirm неверным кодом → 422 OTP_INVALID; верным → 200, другие сессии отозваны, confirmed → proposed', async () => {
      const c = await registerCustomer();
      const other = await registerCustomer();
      // Новый номер — из AUTH_OTP_TEST_PHONES (тестовый режим OtpService 09 §5.8: код фиксирован, SMS не уходит)
      const newPhone = OTP_TEST_PHONES[0];
      const noSu = await call('post', '/me/phone/change/request', c).send({ newPhone });
      expect(noSu.status).toBe(403);
      expect(noSu.body.stepUp.operation).toBe('profile.phone.change');
      const su = await stepUpToken(h.jwt, c, 'profile.phone.change', 'pin');
      const taken = await call('post', '/me/phone/change/request', c, su).send({ newPhone: other.phone });
      expect(taken.status).toBe(409);
      expect(taken.body.code).toBe('PHONE_ALREADY_REGISTERED');
      const badFormat = await call('post', '/me/phone/change/request', c, su).send({ newPhone: '0555123456' });
      expect(badFormat.status).toBe(400);
      expect(badFormat.body.errors[0].rule).toBe('phone_e164');
      const req = await call('post', '/me/phone/change/request', c, su).send({ newPhone });
      expect(req.status).toBe(202);
      expect(req.body).toMatchObject({ challengeId: expect.any(String), resendAfterSec: 60, otpTtlSec: 300 });

      // Подготовка: вторая сессия пользователя c и подтверждённая привязка
      const second = await seedSubjectSession(c.userId);
      const cid = await seedCustomer(fdb.db, 'ОсОО «Старый номер»', c.phone ?? regPhone());
      await fdb.db
        .insert(customerLinks)
        .values({ userId: c.userId, customerId: cid, status: 'confirmed', matchMethod: 'phone' });
      await call('post', '/me/biometrics', c).send({
        enabled: true,
        consent: { kind: 'biometrics_device', version: CONSENT_VERSION, granted: true },
      });

      const wrong = await call('post', '/me/phone/change/confirm', c).send({
        challengeId: req.body.challengeId,
        code: '000001',
      });
      expect(wrong.status).toBe(422);
      expect(wrong.body).toMatchObject({ code: 'OTP_INVALID', attemptsLeft: 4 });
      const noCode = await call('post', '/me/phone/change/confirm', c).send({ challengeId: req.body.challengeId });
      expect(noCode.status).toBe(400);
      expect(noCode.body.errors[0].rule).toBe('otp_format');
      const ok = await call('post', '/me/phone/change/confirm', c).send({
        challengeId: req.body.challengeId,
        code: OTP_TEST_CODE,
      });
      expect(ok.status).toBe(200);
      expect(ok.body).toEqual({ phone: newPhone, sessionsRevoked: true });
      const reuse = await call('post', '/me/phone/change/confirm', c).send({
        challengeId: req.body.challengeId,
        code: OTP_TEST_CODE,
      });
      expect(reuse.status).toBe(422);
      expect(reuse.body.code).toBe('OTP_EXPIRED');

      const [u] = await fdb.db.select().from(users).where(eq(users.id, c.userId));
      expect(u?.phoneE164).toBe(newPhone);
      const [sec] = await fdb.db.select().from(sessions).where(eq(sessions.id, second));
      expect(sec?.revokeReason).toBe('phone_changed');
      const bio = await fdb.db
        .select()
        .from(sessions)
        .where(and(eq(sessions.userId, c.userId), eq(sessions.kind, 'biometric'), isNull(sessions.revokedAt)));
      expect(bio).toHaveLength(0);
      const me = await call('get', '/me', c);
      expect(me.status).toBe(200); // текущая сессия продолжает жить
      expect(me.body.profile.phone).toBe(newPhone);
      expect(me.body.security.biometricsEnabled).toBe(false);
      expect(me.body.customerLink.status).toBe('proposed');
      const [audit] = await auditOf(c.userId, 'user.phone_changed');
      const text = JSON.stringify(audit);
      expect(text).not.toContain(newPhone);
      expect(text).not.toContain(c.phone ?? 'x');
      expect((audit?.after as { phone?: string }).phone).toMatch(/^\+996 \*\*\* \*\* \d\d$/);
      expect((await auditOf(c.userId, 'user.phone_change_requested')).length).toBeGreaterThanOrEqual(1);
      expect((await h.app.get(AuditAnchorService).verifyChain()).ok).toBe(true);
      expect(logs.text).not.toContain(newPhone);
    });

    it('лимиты OtpService: повторный запрос в cooldown → 429 OTP_RATE_LIMITED; код чужого устройства → 409 DEVICE_MISMATCH', async () => {
      const c = await registerCustomer();
      const su = await stepUpToken(h.jwt, c, 'profile.phone.change', 'otp');
      const newPhone = OTP_TEST_PHONES[1];
      const first = await call('post', '/me/phone/change/request', c, su).send({ newPhone });
      expect(first.status).toBe(202);
      const again = await call('post', '/me/phone/change/request', c, su).send({ newPhone });
      expect(again.status).toBe(429);
      expect(again.body.code).toBe('OTP_RATE_LIMITED');
      expect(again.headers['retry-after']).toEqual(expect.any(String));
      const audit = await auditOf(c.userId, 'user.phone_change_requested');
      expect(audit.length).toBe(1);
      const sameAsCurrent = await call('post', '/me/phone/change/request', c, su).send({ newPhone: c.phone });
      expect(sameAsCurrent.status).toBe(400);
      expect(sameAsCurrent.body.errors[0].rule).toBe('phone_same');
    });
  });

  /**
   * Уровень W Android — «лицо или отпечаток» (Class 2) без криптопривязки (15 ADR-116 п. 2; 08 §4.3.1, §4.3.5,
   * §4.3.6, API-200, API-201; 09 BIO-030, BIO-031; 11 SEC-144; 07 DATA-306; 12 §3.24 T-BIO-022, T-BIO-025 (2)–(4),
   * T-BIO-034; пакет LF-2-01). Три приложения на одной БД — три значения `AUTH_BIO_ALLOW_WEAK`: `h` — `off` (по
   * умолчанию), `hAll` — `all`, `hCustomer` — `customer`. Разблокировка семьи W (срок 24 ч, PIN, запрет) —
   * test/e2e/auth/sessions.e2e-spec.ts (T-BIO-023, T-BIO-024).
   */
  describe('уровень W Android: POST /me/biometrics class2, GET /me, DELETE /me/pin (ADR-116)', () => {
    const DAY = 24 * 3600_000;
    let hAll: Harness;
    let hCustomer: Harness;

    beforeAll(async () => {
      hAll = await createHarness(fdb, { config: harnessConfig({ AUTH_BIO_ALLOW_WEAK: 'all' }), logs });
      hCustomer = await createHarness(fdb, { config: harnessConfig({ AUTH_BIO_ALLOW_WEAK: 'customer' }), logs });
    });

    afterAll(async () => {
      await hAll?.app.close();
      await hCustomer?.app.close();
    });

    const on = (
      hx: Harness,
      method: 'get' | 'post' | 'delete',
      path: string,
      s: Subject,
      stepUp?: string,
    ): ReturnType<typeof call> => {
      let r = hx
        .http()
        [method](`/api/v1${path}`)
        .set('Authorization', `Bearer ${s.access}`)
        .set('X-Device-Id', s.deviceKey);
      if (stepUp) r = r.set('X-Step-Up-Token', stepUp);
      return r;
    };

    async function customerOn(
      hx: Harness,
      o: Parameters<typeof completeBody>[1] & { platform?: 'android' | 'ios' | 'windows' } = {},
    ): Promise<Subject> {
      const s = await seedRegistration(fdb.db, hx.jwt);
      const r = await postComplete(hx, completeBody(s.token, o), s.deviceKey);
      expect(r.status).toBe(201);
      return { userId: r.body.user.id, sid: r.body.sid, deviceKey: s.deviceKey, access: r.body.accessToken };
    }

    /** Сотрудник (`seller`, Android) с PIN — первый PIN в окне 15 мин после входа без step-up (08 §4.3.5). */
    async function staffOn(hx: Harness): Promise<Subject> {
      const s = await seedSubject(fdb.db, { role: 'seller' });
      await fdb.db.insert(userProfiles).values({ userId: s.userId, fullName: 'Продавцов Пётр' });
      const access = await hx.jwt.signAccess({
        sub: s.userId,
        kind: 'staff',
        roles: ['seller'],
        permissionsVersion: 1,
        deviceId: s.deviceKey,
        sid: s.session.id,
      });
      const subject = { userId: s.userId, sid: s.session.id, deviceKey: s.deviceKey, access: access.token };
      expect((await on(hx, 'post', '/me/pin', subject).send({ newPin: '730518' })).status).toBe(204);
      return subject;
    }

    const enable = (hx: Harness, s: Subject, biometricClass: 'class2' | 'class3', stepUp?: string) =>
      on(hx, 'post', '/me/biometrics', s, stepUp).send({
        enabled: true,
        biometricClass,
        consent: { kind: 'biometrics_device', version: CONSENT_VERSION, granted: true },
      });

    const bioFamilies = (userId: string) =>
      fdb.db
        .select()
        .from(sessions)
        .where(and(eq(sessions.userId, userId), eq(sessions.kind, 'biometric')));

    it('T-BIO-022 (1)–(3): off → enabled=false weak_biometrics_disabled; customer — только покупателю; all → токен семьи W с weak_reauth_due_at = now + 24 ч, аудит biometricClass=class2', async () => {
      // (1) off (приложение h): токена нет, семья и согласие не создаются
      const offC = await customerOn(h);
      const off = await enable(h, offC, 'class2');
      expect(off.status).toBe(200);
      expect(off.body).toEqual({ enabled: false, reason: 'weak_biometrics_disabled' });
      expect(await bioFamilies(offC.userId)).toHaveLength(0);
      const offConsent = await fdb.db
        .select()
        .from(consents)
        .where(and(eq(consents.userId, offC.userId), eq(consents.kind, 'biometrics_device')));
      expect(offConsent).toHaveLength(0);

      // (2) customer: сотруднику — тот же отказ, покупателю — токен
      const staffC = await staffOn(hCustomer);
      expect((await enable(hCustomer, staffC, 'class2')).body).toEqual({
        enabled: false,
        reason: 'weak_biometrics_disabled',
      });
      expect(await bioFamilies(staffC.userId)).toHaveLength(0);
      const custC = await customerOn(hCustomer);
      const custOk = await enable(hCustomer, custC, 'class2');
      expect(custOk.status).toBe(200);
      expect(custOk.body).toMatchObject({ enabled: true, biometricRefreshToken: expect.any(String) });

      // (3) all: покупатель и сотрудник — семья kind=biometric уровня W
      for (const s of [await customerOn(hAll), await staffOn(hAll)]) {
        const en = await enable(hAll, s, 'class2');
        expect(en.status).toBe(200);
        expect(en.body).toMatchObject({
          enabled: true,
          biometricRefreshToken: expect.any(String),
          expiresAt: expect.any(String),
        });
        const fam = (await bioFamilies(s.userId)).filter((x) => x.revokedAt === null);
        expect(fam).toHaveLength(1);
        expect(fam[0]?.weakReauthDueAt?.getTime()).toBe(hAll.clock.now().getTime() + DAY);
        expect(fam[0]?.amr).toEqual(['sms', 'bio']);
        const [std] = await fdb.db.select().from(sessions).where(eq(sessions.id, s.sid));
        expect(std?.weakReauthDueAt).toBeNull(); // CHECK sessions_weak_reauth_chk: срок — только у kind=biometric
        const audit = await auditOf(s.userId, 'auth.biometrics.enabled');
        expect(audit.map((a) => a.after)).toEqual([
          expect.objectContaining({ biometricClass: 'class2', platform: 'android' }),
        ]);
      }
    });

    it('T-BIO-022 (4)–(7): без PIN → 400 pin_required; class2 на iOS/Windows → 400 biometric_class; позже 15 мин без step-up → STEP_UP_REQUIRED; W поверх S отзывает семью S', async () => {
      // (4) покупатель без PIN (вход только по биометрии S при регистрации)
      const bioOnly = await customerOn(hAll, {
        pin: null,
        biometricsEnabled: true,
        biometricClass: 'class3',
        consents: [PD, BIO],
      });
      const noPin = await enable(hAll, bioOnly, 'class2');
      expect(noPin.status).toBe(400);
      expect(noPin.body.errors).toEqual([expect.objectContaining({ field: 'biometricClass', rule: 'pin_required' })]);

      // (5) class2 — только Android
      for (const platform of ['ios', 'windows'] as const) {
        const s = await customerOn(hAll, { platform });
        const r = await enable(hAll, s, 'class2');
        expect(r.status).toBe(400);
        expect(r.body.errors).toEqual([expect.objectContaining({ field: 'biometricClass', rule: 'biometric_class' })]);
      }

      // (6) окно OTP истекло (сессия выдана 16 мин назад по часам сервиса): step-up обязателен, как для class3
      const late = await customerOn(hAll);
      await fdb.pool.query('UPDATE sessions SET issued_at = $2 WHERE id = $1', [
        late.sid,
        new Date(hAll.clock.now().getTime() - 16 * 60_000),
      ]);
      const lateR = await enable(hAll, late, 'class2');
      expect(lateR.status).toBe(403);
      expect(lateR.body).toMatchObject({
        code: 'STEP_UP_REQUIRED',
        stepUp: { operation: 'profile.biometrics.toggle' },
      });
      expect(await bioFamilies(late.userId)).toHaveLength(0);
      const lateSu = await stepUpToken(hAll.jwt, late, 'profile.biometrics.toggle', 'pin');
      expect((await enable(hAll, late, 'class2', lateSu)).status).toBe(200);

      // (7) семья S устройства → включение W отзывает её (как повтор включения, 08 §4.3.6)
      const sw = await customerOn(hAll);
      const strong = await enable(hAll, sw, 'class3');
      expect(strong.status).toBe(200);
      const weak = await enable(hAll, sw, 'class2');
      expect(weak.status).toBe(200);
      const fams = await bioFamilies(sw.userId);
      expect(fams.filter((x) => x.revokedAt === null).map((x) => x.weakReauthDueAt !== null)).toEqual([true]);
      expect(fams.find((x) => x.weakReauthDueAt === null)?.revokeReason).toBe('session_limit');
    });

    it('T-BIO-025 (2)–(4): GET /me — biometricWeakAllowed по переменной, виду и платформе; android_class2 после включения W; /registration/complete с class2 уровень W не включает', async () => {
      // (2) customer: покупатель на Android — true; сотрудник на Android и покупатель на Windows — false; off — false
      const cases: [Harness, Subject, boolean][] = [
        [hCustomer, await customerOn(hCustomer), true],
        [hCustomer, await staffOn(hCustomer), false],
        [hCustomer, await customerOn(hCustomer, { platform: 'windows' }), false],
        [hAll, await staffOn(hAll), true],
        [hAll, await customerOn(hAll, { platform: 'ios' }), false],
        [h, await customerOn(h), false],
      ];
      for (const [hx, s, allowed] of cases) {
        const me = await on(hx, 'get', '/me', s);
        expect(me.status).toBe(200);
        expect(me.body.security.biometricWeakAllowed).toBe(allowed);
        expect(validateAgainst('Me', me.body)).toEqual([]);
      }

      // (3) после включения W — biometricsPlatform = android_class2
      const c = await customerOn(hAll);
      expect((await on(hAll, 'get', '/me', c)).body.security).toMatchObject({
        biometricsEnabled: false,
        biometricsPlatform: 'none',
        biometricWeakAllowed: true,
      });
      expect((await enable(hAll, c, 'class2')).status).toBe(200);
      const me = await on(hAll, 'get', '/me', c);
      expect(me.body.security).toEqual({
        pinSet: true,
        biometricsEnabled: true,
        biometricsPlatform: 'android_class2',
        biometricWeakAllowed: true,
        windowsHelloKeyAllowed: false, // ключ Windows Hello (W2, ADR-116) — только platform=windows
      });
      expect(validateAgainst('Me', me.body)).toEqual([]);

      // (4) регистрация с class2: биометрия без криптопривязки не включается и не предлагается
      const withPin = await seedRegistration(fdb.db, hAll.jwt);
      const reg = await postComplete(
        hAll,
        completeBody(withPin.token, { biometricsEnabled: true, biometricClass: 'class2', consents: [PD, BIO] }),
        withPin.deviceKey,
      );
      expect(reg.status).toBe(201);
      expect(reg.body.biometricRefreshOffered).toBe(false);
      expect(await bioFamilies(reg.body.user.id)).toHaveLength(0);
      const noPin = await seedRegistration(fdb.db, hAll.jwt);
      const refused = await postComplete(
        hAll,
        completeBody(noPin.token, {
          pin: null,
          biometricsEnabled: true,
          biometricClass: 'class2',
          consents: [PD, BIO],
        }),
        noPin.deviceKey,
      );
      expect(refused.status).toBe(400);
      expect(refused.body.errors[0].rule).toBe('login_protection_required');
    });

    it('T-BIO-034: DELETE /me/pin при живой семье W → 400 weak_biometrics_active (PIN цел); после выключения W — прежние правила (422 / 204); сотрудник — 403 pin_required_for_staff', async () => {
      // (1) покупатель с семьёй W
      const c = await customerOn(hAll);
      expect((await enable(hAll, c, 'class2')).status).toBe(200);
      const su = await stepUpToken(hAll.jwt, c, 'profile.pin.set');
      const del = await on(hAll, 'delete', '/me/pin', c, su);
      expect(del.status).toBe(400);
      expect(del.body).toMatchObject({ code: 'VALIDATION_FAILED' });
      expect(del.body.errors).toEqual([expect.objectContaining({ field: 'pin', rule: 'weak_biometrics_active' })]);
      expect(await fdb.db.select().from(appPins).where(eq(appPins.userId, c.userId))).toHaveLength(1);
      expect(await auditOf(c.userId, 'auth.pin.removed')).toHaveLength(0);

      // (2) выключить W → биометрии S на устройстве нет → 422; включить S → 204
      expect((await on(hAll, 'post', '/me/biometrics', c).send({ enabled: false })).body).toEqual({ enabled: false });
      const noProtection = await on(hAll, 'delete', '/me/pin', c, su);
      expect(noProtection.status).toBe(422);
      expect(noProtection.body.errors[0].rule).toBe('login_protection_required');
      expect((await enable(hAll, c, 'class3')).status).toBe(200);
      expect((await on(hAll, 'delete', '/me/pin', c, su)).status).toBe(204);

      // семья W истекла, но не отозвана: «живой» нет, устройство уровня S не имеет → 422, PIN цел
      const expired = await customerOn(hAll);
      expect((await enable(hAll, expired, 'class2')).status).toBe(200);
      const past = new Date(hAll.clock.now().getTime() - 60_000); // сроки — по часам сервиса (CLOCK)
      await fdb.pool.query(
        `UPDATE sessions SET expires_at = $2, idle_expires_at = $2 WHERE user_id = $1 AND kind = 'biometric'`,
        [expired.userId, past],
      );
      const suE = await stepUpToken(hAll.jwt, expired, 'profile.pin.set');
      const expiredDel = await on(hAll, 'delete', '/me/pin', expired, suE);
      expect(expiredDel.status).toBe(422);
      expect(expiredDel.body.errors[0].rule).toBe('login_protection_required');

      // (3) сотрудник с семьёй W — как прежде 403 (D-48)
      const s = await staffOn(hAll);
      expect((await enable(hAll, s, 'class2')).status).toBe(200);
      const suS = await stepUpToken(hAll.jwt, s, 'profile.pin.set');
      const staffDel = await on(hAll, 'delete', '/me/pin', s, suS);
      expect(staffDel.status).toBe(403);
      expect(staffDel.body).toMatchObject({ code: 'FORBIDDEN', reason: 'pin_required_for_staff' });
    });
  });

  /** Вторая сессия пользователя на другом устройстве (для проверки отзыва «других» сессий). */
  async function seedSubjectSession(userId: string): Promise<string> {
    const { DevicesRepository } = await import('../../src/users/devices.repository.js');
    const { SessionsRepository } = await import('../../src/users/sessions.repository.js');
    const { generateOpaqueToken, sha256 } = await import('../../src/common/crypto/random.js');
    const d = await new DevicesRepository(fdb.db).upsert({ userId, deviceKey: randomUUID(), platform: 'android' });
    const s = await new SessionsRepository(fdb.db).create({
      userId,
      deviceId: d.id,
      refreshHash: sha256(generateOpaqueToken()),
      expiresAt: new Date(Date.now() + 86_400_000),
      idleExpiresAt: new Date(Date.now() + 86_400_000),
    });
    return s.id;
  }
});

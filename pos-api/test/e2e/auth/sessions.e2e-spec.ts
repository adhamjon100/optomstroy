import { StepUpService } from '../../../src/auth/step-up/step-up.service.js';
import { JwtService } from '../../../src/common/auth/jwt.service.js';
import type { AuthenticatedPrincipal } from '../../../src/common/auth/principal.js';
import { generateOpaqueToken, sha256 } from '../../../src/common/crypto/random.js';
import { SessionsRepository } from '../../../src/users/sessions.repository.js';
import { UsersRepository } from '../../../src/users/users.repository.js';
import { UserRolesRepository } from '../../../src/users/user-roles.repository.js';
import type { RoleCode, UserKind } from '../../../src/users/users.types.js';
import { ANDROID, AuthE2e, type DeviceBody, freshDevice, type JsonBody, WINDOWS } from './support/auth-e2e.js';

/**
 * RM-D-003 — сессии, refresh-ротация, reuse-detection, logout, step-up, unlock (12 T-SESS-004…009, 011, 013, 014,
 * 016, 020, 023; RM-D-003 критерии 1–3, 5, 6) на embedded PostgreSQL 17 с подменой часов.
 */
describe('auth/sessions e2e (RM-D-003)', () => {
  const t = new AuthE2e();
  const PIN = '482913';

  beforeAll(async () => {
    await t.start('auth_sessions_e2e');
  });
  afterAll(async () => {
    await t.stop();
  });
  beforeEach(() => {
    t.tick();
    t.clearAuthCache();
  });

  async function signedIn(
    opts: { kind?: UserKind; role?: RoleCode; pin?: string | null; device?: DeviceBody; deviceKey?: string } = {},
  ) {
    const u = await t.seedUser({ kind: opts.kind ?? 'staff', role: opts.role ?? 'seller' });
    if (opts.pin !== null) await t.setPin(u.userId, opts.pin ?? PIN);
    const r = await t.login(u.phone, {
      device: opts.device ?? ANDROID,
      ...(opts.deviceKey ? { deviceKey: opts.deviceKey } : {}),
    });
    expect(r.status).toBe(200);
    return {
      ...u,
      ...r,
      access: r.body.accessToken as string,
      refresh: r.body.refreshToken as string,
      sid: r.body.sid as string,
    };
  }

  async function stepUp(access: string, deviceKey: string, operation: string, pin = PIN) {
    return t.bearer('post', '/auth/step-up', access, deviceKey).send({ method: 'pin', pin, operation });
  }

  async function sessionRow(sid: string): Promise<JsonBody> {
    const r = await t.pool.query<JsonBody>('SELECT * FROM sessions WHERE id = $1', [sid]);
    return r.rows[0] ?? {};
  }

  it('T-SESS-004: refresh — 256 бит base64url, в БД только SHA-256; ротация выдаёт новую пару в той же сессии', async () => {
    const s = await signedIn();
    const row = await sessionRow(s.sid);
    expect(Buffer.compare(row.refresh_hash, sha256(s.refresh))).toBe(0);
    expect(JSON.stringify(row)).not.toContain(s.refresh);
    const r = await t.refresh(s.refresh, s.deviceKey);
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ sid: s.sid, accessExpiresIn: 900, permissionsVersion: 1 });
    expect(r.body.refreshToken).not.toBe(s.refresh);
    const after = await sessionRow(s.sid);
    expect(Buffer.compare(after.prev_refresh_hash, sha256(s.refresh))).toBe(0);
    expect((await t.bearer('get', '/auth/sessions', r.body.accessToken, s.deviceKey)).status).toBe(200);
  });

  it('T-SEC-010, T-SESS-005 (RM-D-003 п.1): повтор старого refresh после использования нового → SESSION_REVOKED для всей семьи + аудит', async () => {
    const s = await signedIn();
    const r2 = await t.refresh(s.refresh, s.deviceKey);
    expect(r2.status).toBe(200);
    const r3 = await t.refresh(r2.body.refreshToken, s.deviceKey); // R2 использован
    expect(r3.status).toBe(200);
    // R2 теперь prev, R3 текущий; R3 используем запросом → предъявление R2 = reuse
    expect((await t.bearer('get', '/auth/sessions', r3.body.accessToken, s.deviceKey)).status).toBe(200);
    const reuse = await t.refresh(r2.body.refreshToken, s.deviceKey);
    expect(reuse.status).toBe(401);
    expect(reuse.body).toMatchObject({ code: 'SESSION_REVOKED', reason: 'reuse_detected' });
    const row = await sessionRow(s.sid);
    expect(row.revoke_reason).toBe('reuse_detected');
    const cur = await t.refresh(r3.body.refreshToken, s.deviceKey);
    expect(cur.status).toBe(401);
    expect(cur.body.code).toBe('SESSION_REVOKED');
    expect(await t.auditActions({ entityId: s.sid })).toContain('session.reuse_detected');
  });

  it('T-SESS-006: окно грации 30 с — первый повтор → новая ротация той же сессии, второй → отзыв семьи', async () => {
    const s = await signedIn();
    const r2 = await t.refresh(s.refresh, s.deviceKey);
    t.tick(10_000);
    const grace = await t.refresh(s.refresh, s.deviceKey);
    expect(grace.status).toBe(200);
    expect(grace.body.sid).toBe(s.sid);
    expect(grace.body.refreshToken).not.toBe(r2.body.refreshToken);
    const again = await t.refresh(s.refresh, s.deviceKey);
    expect(again.status).toBe(401);
    expect(again.body.reason).toBe('reuse_detected');
    expect((await sessionRow(s.sid)).revoke_reason).toBe('reuse_detected');
  });

  it('T-SESS-023 (а,б): повтор после окна грации, PIN есть → 401 UNLOCK_REQUIRED без отзыва; unlock(R1, PIN) → R3, затем R2 → reuse', async () => {
    const s = await signedIn();
    const r2 = await t.refresh(s.refresh, s.deviceKey);
    expect(r2.status).toBe(200);
    t.tick(60_000);
    const late = await t.refresh(s.refresh, s.deviceKey);
    expect(late.status).toBe(401);
    expect(late.body).toMatchObject({ code: 'UNLOCK_REQUIRED', reason: 'refresh_replay' });
    expect((await sessionRow(s.sid)).revoked_at).toBeNull();
    expect(await t.auditActions({ entityId: s.sid })).not.toContain('session.reuse_detected');
    const unlocked = await t.unlock({ method: 'pin', refreshToken: s.refresh, pin: PIN }, s.deviceKey);
    expect(unlocked.status).toBe(200);
    expect(unlocked.body).toMatchObject({ sid: s.sid, amr: ['sms', 'pin'] });
    const r2again = await t.refresh(r2.body.refreshToken, s.deviceKey);
    expect(r2again.status).toBe(401);
    expect(r2again.body.reason).toBe('reuse_detected');
  });

  it('T-SESS-023 (в,г,д): использованный текущий → reuse; другое устройство → device_mismatch; customer без PIN → refresh_replay, отозвана только S', async () => {
    const a = await signedIn();
    const a2 = await t.refresh(a.refresh, a.deviceKey);
    expect((await t.bearer('get', '/auth/sessions', a2.body.accessToken, a.deviceKey)).status).toBe(200);
    t.tick(60_000);
    const used = await t.refresh(a.refresh, a.deviceKey);
    expect(used.body).toMatchObject({ code: 'SESSION_REVOKED', reason: 'reuse_detected' });

    const b = await signedIn();
    await t.refresh(b.refresh, b.deviceKey);
    t.tick(60_000);
    const other = await t.refresh(b.refresh, freshDevice());
    expect(other.body).toMatchObject({ code: 'SESSION_REVOKED', reason: 'device_mismatch' });
    expect((await sessionRow(b.sid)).revoke_reason).toBe('device_mismatch');

    const c = await signedIn({ kind: 'customer', role: 'customer', pin: null });
    const c2 = await t.refresh(c.refresh, c.deviceKey);
    t.tick(60_000);
    const replay = await t.refresh(c.refresh, c.deviceKey);
    expect(replay.body).toMatchObject({ code: 'SESSION_REVOKED', reason: 'refresh_replay' });
    expect((await sessionRow(c.sid)).revoked_at).not.toBeNull();
    // миграция 0003 (DQ-03 / auth A-08): причина отзыва — refresh_replay, а не reuse_detected
    expect((await sessionRow(c.sid)).revoke_reason).toBe('refresh_replay');
    expect(await t.auditActions({ entityId: c.sid })).not.toContain('session.reuse_detected');
    expect(c2.status).toBe(200);
  });

  it('T-SEC-010, T-SESS-007: refresh с чужим X-Device-Id → отзыв сессии (device_mismatch)', async () => {
    const s = await signedIn();
    const r = await t.refresh(s.refresh, freshDevice());
    expect(r.status).toBe(401);
    expect(r.body.reason).toBe('device_mismatch');
    expect((await sessionRow(s.sid)).revoke_reason).toBe('device_mismatch');
    expect((await t.refresh(s.refresh, s.deviceKey)).status).toBe(401);
  });

  it('T-SEC-011, T-SESS-008: абсолютный срок 7 дней (staff) и idle 14 дней (customer) — отказ после сроков', async () => {
    const s = await signedIn();
    let token = s.refresh;
    for (let i = 0; i < 7; i++) {
      t.tick(23 * 3600_000); // idle 24 ч не истекает
      const r = await t.refresh(token, s.deviceKey);
      expect(r.status).toBe(200);
      token = r.body.refreshToken as string;
    }
    t.tick(7 * 24 * 3600_000);
    const dead = await t.refresh(token, s.deviceKey);
    expect(dead.status).toBe(401);
    expect(dead.body.code).toBe('SESSION_REVOKED');

    const c = await signedIn({ kind: 'customer', role: 'customer', pin: null });
    t.tick(14 * 24 * 3600_000 + 60_000);
    const idle = await t.refresh(c.refresh, c.deviceKey);
    expect(idle.status).toBe(401);
    expect((await sessionRow(c.sid)).revoke_reason).toBe('expired');
  });

  it('T-SEC-011, T-SESS-009: staff — не более 3 устройств; вход с 4-го отзывает самую старую (session_limit)', async () => {
    const u = await t.seedUser();
    await t.setPin(u.userId, PIN);
    const sids: string[] = [];
    for (let i = 0; i < 4; i++) {
      t.tick(16 * 60_000); // лимит номера 3 / 15 мин
      const r = await t.login(u.phone);
      sids.push(r.body.sid as string);
    }
    const rows = await t.pool.query('SELECT id, revoke_reason FROM sessions WHERE user_id = $1 ORDER BY issued_at', [
      u.userId,
    ]);
    expect(rows.rows.filter((x) => x.revoke_reason === null)).toHaveLength(3);
    expect(rows.rows.find((x) => x.id === sids[0])?.revoke_reason).toBe('session_limit');
  });

  it('T-SESS-011 (RM-D-003 п.5): список; DELETE чужого устройства без step-up → STEP_UP_REQUIRED, со step-up → 204; PATCH имени; текущая = logout', async () => {
    const u = await t.seedUser();
    await t.setPin(u.userId, PIN);
    const d1 = await t.login(u.phone);
    t.tick();
    const d2 = await t.login(u.phone);
    const list = await t.bearer('get', '/auth/sessions', d2.body.accessToken, d2.deviceKey);
    expect(list.status).toBe(200);
    expect(list.body.items).toHaveLength(2);
    const items = list.body.items as { id: string; isCurrent: boolean }[];
    expect(items.find((x) => x.isCurrent)?.id).toBe(d2.body.sid);
    expect(list.body.items[0].ipLast).toMatch(/^\d+\.\*\*\*\.\*\*\*\.\d+$/);

    const noStep = await t.bearer('delete', `/auth/sessions/${d1.body.sid}`, d2.body.accessToken, d2.deviceKey);
    expect(noStep.status).toBe(403);
    expect(noStep.body).toMatchObject({
      code: 'STEP_UP_REQUIRED',
      stepUp: { operation: 'session.revoke.other', allowedMethods: ['pin', 'otp'] },
    });
    const su = await stepUp(d2.body.accessToken, d2.deviceKey, 'session.revoke.other');
    expect(su.status).toBe(200);
    const del = await t
      .bearer('delete', `/auth/sessions/${d1.body.sid}`, d2.body.accessToken, d2.deviceKey)
      .set('X-Step-Up-Token', su.body.stepUpToken);
    expect(del.status).toBe(204);
    expect((await sessionRow(d1.body.sid)).revoked_at).not.toBeNull();
    const foreign = await signedIn();
    const nf = await t.bearer('delete', `/auth/sessions/${foreign.sid}`, d2.body.accessToken, d2.deviceKey);
    expect(nf.status).toBe(404);

    const ren = await t
      .bearer('patch', `/auth/sessions/${d2.body.sid}`, d2.body.accessToken, d2.deviceKey)
      .send({ deviceName: 'Касса-2 (Windows)' });
    expect(ren.status).toBe(200);
    expect(ren.body).toMatchObject({ id: d2.body.sid, deviceName: 'Касса-2 (Windows)', isCurrent: true });
    const badRen = await t
      .bearer('patch', `/auth/sessions/${d2.body.sid}`, d2.body.accessToken, d2.deviceKey)
      .send({ deviceName: 'x', extra: 1 });
    expect(badRen.status).toBe(400);

    const self = await t.bearer('delete', `/auth/sessions/${d2.body.sid}`, d2.body.accessToken, d2.deviceKey);
    expect(self.status).toBe(204);
    expect((await sessionRow(d2.body.sid)).revoke_reason).toBe('logout');
  });

  it('T-SEC-012, T-SESS-013 (RM-D-003 п.2): logout — jti в denylist; logout-all со step-up отзывает все сессии, включая biometric', async () => {
    const u = await t.seedUser();
    await t.setPin(u.userId, PIN);
    const d1 = await t.login(u.phone);
    t.tick();
    const d2 = await t.login(u.phone);
    const sessions = new SessionsRepository(t.fdb.db);
    const bioRefresh = generateOpaqueToken();
    const devRow = await t.pool.query('SELECT device_id FROM sessions WHERE id = $1', [d2.body.sid]);
    const bio = await sessions.create({
      userId: u.userId,
      deviceId: devRow.rows[0].device_id,
      refreshHash: sha256(bioRefresh),
      kind: 'biometric',
      expiresAt: new Date(t.clock.now().getTime() + 86_400_000),
      idleExpiresAt: new Date(t.clock.now().getTime() + 86_400_000),
    });

    const out = await t.bearer('post', '/auth/logout', d1.body.accessToken, d1.deviceKey).send({ reason: 'user' });
    expect(out.status).toBe(204);
    const denied = await t.pool.query(
      `SELECT reason FROM token_denylist WHERE session_id = $1 AND token_kind = 'access'`,
      [d1.body.sid],
    );
    expect(denied.rows[0].reason).toBe('logout');
    const afterLogout = await t.bearer('get', '/auth/sessions', d1.body.accessToken, d1.deviceKey);
    expect(afterLogout.status).toBe(401);
    // 09 §8.6: access после logout → SESSION_REVOKED (не UNAUTHENTICATED) — регрессия A-13
    expect(afterLogout.body.code).toBe('SESSION_REVOKED');
    expect((await t.bearer('post', '/auth/logout', d1.body.accessToken, d1.deviceKey)).status).toBe(401);

    const noStep = await t.bearer('post', '/auth/logout-all', d2.body.accessToken, d2.deviceKey);
    expect(noStep.status).toBe(403);
    expect(noStep.body.code).toBe('STEP_UP_REQUIRED');
    const su = await stepUp(d2.body.accessToken, d2.deviceKey, 'session.logout_all');
    const all = await t
      .bearer('post', '/auth/logout-all', d2.body.accessToken, d2.deviceKey)
      .set('X-Step-Up-Token', su.body.stepUpToken);
    expect(all.status).toBe(204);
    const rows = await t.pool.query('SELECT id, revoke_reason FROM sessions WHERE user_id = $1', [u.userId]);
    expect(rows.rows.every((r) => r.revoke_reason !== null)).toBe(true);
    expect(rows.rows.find((r) => r.id === bio.id)?.revoke_reason).toBe('logout_all');
    expect((await t.refresh(d2.body.refreshToken, d2.deviceKey)).status).toBe(401);
    expect(await t.auditActions({ actorUserId: u.userId })).toEqual(
      expect.arrayContaining(['auth.logout', 'auth.logout_all', 'auth.step_up.ok']),
    );
  });

  it('T-SEC-013, T-SESS-014: смена роли (permissionsVersion++) → 401 TOKEN_STALE; refresh → новые роли', async () => {
    const s = await signedIn({ role: 'seller' });
    await new UserRolesRepository(t.fdb.db).assignRole(s.userId, 'cashier', null);
    await new UsersRepository(t.fdb.db).bumpPermissionsVersion(s.userId);
    t.clearAuthCache();
    const stale = await t.bearer('get', '/auth/sessions', s.access, s.deviceKey);
    expect(stale.status).toBe(401);
    expect(stale.body.code).toBe('TOKEN_STALE');
    const r = await t.refresh(s.refresh, s.deviceKey);
    expect(r.status).toBe(200);
    expect(r.body.permissionsVersion).toBe(2);
    const payload = JSON.parse(Buffer.from(String(r.body.accessToken).split('.')[1], 'base64url').toString());
    expect(payload.roles).toEqual(['cashier']);
    expect(payload).not.toHaveProperty('phone');
    expect((await t.bearer('get', '/auth/sessions', r.body.accessToken, s.deviceKey)).status).toBe(200);
  });

  it('T-SEC-020, T-SESS-016 (RM-D-003 п.3): stepUpToken многоразовый 15 мин в своей области; чужая область, истечение, смена прав → STEP_UP_REQUIRED', async () => {
    const s = await signedIn();
    const su = await stepUp(s.access, s.deviceKey, 'session.revoke.other');
    expect(su.status).toBe(200);
    expect(su.body).toMatchObject({ method: 'pin', scope: ['session.manage.own'] });
    const svc = t.app.get(StepUpService);
    const principal = async (access: string): Promise<AuthenticatedPrincipal> => {
      const c = await t.app.get(JwtService).verifyAccess(access);
      return {
        userId: c.sub,
        kind: c.kind,
        roles: c.roles,
        status: 'active' as const,
        sessionId: c.sid,
        deviceId: c.deviceId,
        jti: c.jti,
        permissionsVersion: c.permissionsVersion,
        amr: c.amr,
        tokenExpiresAt: new Date(c.exp * 1000),
      };
    };
    const p = await principal(s.access);
    // многоразовый в своей области
    await expect(svc.verify(su.body.stepUpToken, p, 'session.revoke.other')).resolves.toMatchObject({ method: 'pin' });
    await expect(svc.verify(su.body.stepUpToken, p, 'session.revoke.other')).resolves.toBeTruthy();
    // другая область
    await expect(svc.verify(su.body.stepUpToken, p, 'session.logout_all')).rejects.toMatchObject({
      code: 'STEP_UP_REQUIRED',
    });
    // чужая сессия
    const other = await signedIn();
    await expect(
      svc.verify(su.body.stepUpToken, await principal(other.access), 'session.revoke.other'),
    ).rejects.toMatchObject({
      code: 'STEP_UP_REQUIRED',
    });
    // смена прав (permissionsVersion) → не принимается
    await expect(
      svc.verify(su.body.stepUpToken, { ...p, permissionsVersion: p.permissionsVersion + 1 }, 'session.revoke.other'),
    ).rejects.toMatchObject({ code: 'STEP_UP_REQUIRED' });
    // через 15 мин — истёк
    t.tick(14 * 60_000);
    await expect(svc.verify(su.body.stepUpToken, p, 'session.revoke.other')).resolves.toBeTruthy();
    t.tick(66_000); // 15 мин + допуск часов JWT 5 с
    await expect(svc.verify(su.body.stepUpToken, p, 'session.revoke.other')).rejects.toMatchObject({
      code: 'STEP_UP_REQUIRED',
    });
  });

  it('step-up: валидация method/operation, право на операцию, PIN не задан, OTP-вариант (202 → 200)', async () => {
    const s = await signedIn();
    const bio = await t
      .bearer('post', '/auth/step-up', s.access, s.deviceKey)
      .send({ method: 'bio+pin', pin: PIN, operation: 'session.logout_all' });
    expect(bio.status).toBe(400);
    expect(bio.body.errors[0]).toMatchObject({ field: 'method', rule: 'method' });
    const op = await t
      .bearer('post', '/auth/step-up', s.access, s.deviceKey)
      .send({ method: 'pin', pin: PIN, operation: 'phone_change' });
    expect(op.body.errors[0]).toMatchObject({ field: 'operation', rule: 'operation' });
    const notAllowed = await stepUp(s.access, s.deviceKey, 'users.manage');
    expect(notAllowed.status).toBe(403);
    expect(notAllowed.body).toMatchObject({ code: 'FORBIDDEN', reason: 'operation_not_permitted' });

    const c = await signedIn({ kind: 'customer', role: 'customer', pin: null });
    const noPin = await stepUp(c.access, c.deviceKey, 'profile.pin.set');
    expect(noPin.status).toBe(403);
    expect(noPin.body).toMatchObject({ code: 'FORBIDDEN', reason: 'pin_not_set' });
    const s1 = await t
      .bearer('post', '/auth/step-up', c.access, c.deviceKey)
      .send({ method: 'otp', operation: 'profile.pin.set' });
    expect(s1.status).toBe(202);
    expect(s1.body).toMatchObject({ resendAfterSec: 60, otpTtlSec: 300 });
    const code = await t.codeFor(s1.body.challengeId);
    const ch = await t.pool.query('SELECT purpose, user_id FROM otp_challenges WHERE id = $1', [s1.body.challengeId]);
    expect(ch.rows[0]).toEqual({ purpose: 'step_up', user_id: c.userId });
    const s2 = await t
      .bearer('post', '/auth/step-up', c.access, c.deviceKey)
      .send({ method: 'otp', operation: 'profile.pin.set', challengeId: s1.body.challengeId, code });
    expect(s2.status).toBe(200);
    expect(s2.body).toMatchObject({ method: 'otp', scope: ['profile.manage.own'] });
    const row = await sessionRow(c.sid);
    expect(row.step_up_method).toBe('otp');
  });

  // 08 §4.11.5 («step-up для всех ролей без исключений, включая customer»), 11 §4.1 п. 7 (область finance_view), §4.2,
  // SEC-033 (ревью G-security-3): клиент получает step-up на детализацию своего долга по праву
  // customer.self.receivables.read; роль без прав на долг (seller) — нет.
  it('step-up детализации долга: customer → 200 (scope customer.receivables.read.detail); seller → 403 operation_not_permitted', async () => {
    const c = await signedIn({ kind: 'customer', role: 'customer' });
    const ok = await stepUp(c.access, c.deviceKey, 'customer.receivables.read.detail');
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body).toMatchObject({ method: 'pin', scope: ['customer.receivables.read.detail'] });
    const s = await signedIn({ role: 'seller' });
    const no = await stepUp(s.access, s.deviceKey, 'customer.receivables.read.detail');
    expect(no.status).toBe(403);
    expect(no.body).toMatchObject({ code: 'FORBIDDEN', reason: 'operation_not_permitted' });
  });

  it('T-SEC-044, RM-D-003 п.6 / D-48: unlock без Bearer — верный PIN → новая пара; неверный → 401 PIN_INVALID (сессия жива); 5-я → 423 PIN_LOCKED; OTP-вход снимает блок', async () => {
    const s = await signedIn();
    const ok = await t.unlock({ method: 'pin', refreshToken: s.refresh, pin: PIN }, s.deviceKey);
    expect(ok.status).toBe(200);
    expect(ok.body).toMatchObject({ sid: s.sid, amr: ['sms', 'pin'], accessExpiresIn: 900 });
    let refresh = ok.body.refreshToken as string;
    for (let i = 1; i <= 4; i++) {
      const bad = await t.unlock({ refreshToken: refresh, pin: '000000' }, s.deviceKey);
      expect(bad.status).toBe(401);
      expect(bad.body).toMatchObject({ code: 'PIN_INVALID', attemptsLeft: 5 - i });
    }
    expect((await sessionRow(s.sid)).revoked_at).toBeNull();
    const fifth = await t.unlock({ refreshToken: refresh, pin: '000000' }, s.deviceKey);
    expect(fifth.status).toBe(423);
    expect(fifth.body.code).toBe('PIN_LOCKED');
    const locked = await t.unlock({ refreshToken: refresh, pin: PIN }, s.deviceKey);
    expect(locked.status).toBe(423);
    expect(await t.auditActions({ entityId: s.sid })).toContain('auth.pin.locked');
    // Вход по OTP снимает блокировку PIN
    t.tick();
    const relogin = await t.login(s.phone, { deviceKey: s.deviceKey });
    expect(relogin.status).toBe(200);
    refresh = relogin.body.refreshToken as string;
    const again = await t.unlock({ refreshToken: refresh, pin: PIN }, s.deviceKey);
    expect(again.status).toBe(200);
  });

  it('unlock: PIN не задан → 403 pin_not_set; поля refresh kind/amr → 400 forbidden_field; нет X-Device-Id → 400', async () => {
    const c = await signedIn({ kind: 'customer', role: 'customer', pin: null });
    const r = await t.unlock({ refreshToken: c.refresh, pin: '1357' }, c.deviceKey);
    expect(r.status).toBe(403);
    expect(r.body).toMatchObject({ code: 'FORBIDDEN', reason: 'pin_not_set' });
    const kind = await t.http
      .post('/api/v1/auth/refresh')
      .set('X-Device-Id', c.deviceKey)
      .send({ refreshToken: c.refresh, kind: 'biometric' });
    expect(kind.status).toBe(400);
    expect(kind.body.errors[0]).toMatchObject({ field: 'kind', rule: 'forbidden_field' });
    const noDev = await t.http.post('/api/v1/auth/refresh').send({ refreshToken: c.refresh });
    expect(noDev.status).toBe(400);
    expect(noDev.body.errors[0]).toMatchObject({ field: 'X-Device-Id', rule: 'uuid' });
  });

  it('биометрия: biometric_refresh на /auth/refresh → 400 use_unlock; unlock {method: biometric} → amr sms+bio; biometricInvalidated отзывает семью', async () => {
    const s = await signedIn();
    const devRow = await t.pool.query('SELECT device_id FROM sessions WHERE id = $1', [s.sid]);
    const bioRefresh = generateOpaqueToken();
    const bio = await new SessionsRepository(t.fdb.db).create({
      userId: s.userId,
      deviceId: devRow.rows[0].device_id,
      refreshHash: sha256(bioRefresh),
      kind: 'biometric',
      expiresAt: new Date(t.clock.now().getTime() + 7 * 86_400_000),
      idleExpiresAt: new Date(t.clock.now().getTime() + 86_400_000),
    });
    const viaRefresh = await t.refresh(bioRefresh, s.deviceKey);
    expect(viaRefresh.status).toBe(400);
    expect(viaRefresh.body.errors[0].rule).toBe('use_unlock');
    const u = await t.unlock({ method: 'biometric', refreshToken: bioRefresh }, s.deviceKey);
    expect(u.status).toBe(200);
    expect(u.body).toMatchObject({ sid: bio.id, amr: ['sms', 'bio'] });
    const standardAsBio = await t.unlock({ method: 'biometric', refreshToken: s.refresh }, s.deviceKey);
    expect(standardAsBio.status).toBe(400);
    const inv = await t.unlock(
      { method: 'pin', refreshToken: s.refresh, pin: PIN, biometricInvalidated: true },
      s.deviceKey,
    );
    expect(inv.status).toBe(200);
    expect((await sessionRow(bio.id)).revoke_reason).toBe('biometric_invalidated');
  });

  it('T-SESS-020: staff на Windows — refresh без действующей разблокировки → 401 UNLOCK_REQUIRED (не отозвана); unlock PIN → 200; затем refresh 200', async () => {
    const s = await signedIn({ device: WINDOWS });
    const fresh = await t.refresh(s.refresh, s.deviceKey);
    expect(fresh.status).toBe(200); // сразу после OTP-входа unlocked_until действует
    t.tick(31 * 60_000);
    const locked = await t.refresh(fresh.body.refreshToken, s.deviceKey);
    expect(locked.status).toBe(401);
    expect(locked.body.code).toBe('UNLOCK_REQUIRED');
    expect((await sessionRow(s.sid)).revoked_at).toBeNull();
    const un = await t.unlock({ method: 'pin', refreshToken: fresh.body.refreshToken, pin: PIN }, s.deviceKey);
    expect(un.status).toBe(200);
    const row = await sessionRow(s.sid);
    expect(new Date(row.unlocked_until).getTime()).toBe(t.clock.now().getTime() + 30 * 60_000);
    const after = await t.refresh(un.body.refreshToken, s.deviceKey);
    expect(after.status).toBe(200);
    const bio = await t.unlock({ method: 'biometric', refreshToken: after.body.refreshToken }, s.deviceKey);
    expect(bio.status).toBe(400);
  });
});

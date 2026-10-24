import { randomUUID } from 'node:crypto';
import { generateOpaqueToken, sha256 } from '../../src/common/crypto/random.js';
import { PgAuthStateReader } from '../../src/users/auth-state.reader.js';
import { DevicesRepository } from '../../src/users/devices.repository.js';
import { SessionsRepository } from '../../src/users/sessions.repository.js';
import { TokenDenylistRepository } from '../../src/users/token-denylist.repository.js';
import { UserProfilesRepository } from '../../src/users/user-profiles.repository.js';
import { UserRolesRepository } from '../../src/users/user-roles.repository.js';
import { UsersRepository } from '../../src/users/users.repository.js';
import { FoundationDb, seedSubject, testPhone } from './support/foundation-db.js';

describe('src/users: репозитории users, user_roles, user_profiles, devices, sessions, token_denylist (07 §5.1–§5.10)', () => {
  const fdb = new FoundationDb();
  let users: UsersRepository;
  let roles: UserRolesRepository;
  let profiles: UserProfilesRepository;
  let devices: DevicesRepository;
  let sessions: SessionsRepository;
  let denylist: TokenDenylistRepository;

  beforeAll(async () => {
    await fdb.start('foundation_users');
    users = new UsersRepository(fdb.db);
    roles = new UserRolesRepository(fdb.db);
    profiles = new UserProfilesRepository(fdb.db);
    devices = new DevicesRepository(fdb.db);
    sessions = new SessionsRepository(fdb.db);
    denylist = new TokenDenylistRepository(fdb.db);
  });

  afterAll(async () => {
    await fdb.stop();
  });

  it('users: create/findByPhone/setStatus/bumpPermissionsVersion', async () => {
    const phone = testPhone();
    const u = await users.create({ phoneE164: phone, kind: 'customer', status: 'active', phoneVerifiedAt: new Date() });
    expect(u.permissionsVersion).toBe(1);
    expect((await users.findByPhone(phone))?.id).toBe(u.id);
    expect(await users.bumpPermissionsVersion(u.id)).toBe(2);
    const blocked = await users.setStatus(u.id, 'blocked', { blockReason: 'тест' });
    expect(blocked).toMatchObject({ status: 'blocked', blockReason: 'тест' });
    expect(blocked?.blockedAt).toBeInstanceOf(Date);
    const active = await users.setStatus(u.id, 'active');
    expect(active).toMatchObject({ status: 'active', blockedAt: null, blockReason: null });
    await expect(users.create({ phoneE164: phone, kind: 'staff', status: 'active' })).rejects.toThrow();
  });

  it('user_roles: одна активная роль; смена роли — история сохраняется; та же роль — без изменений', async () => {
    const u = await users.create({ phoneE164: testPhone(), kind: 'staff', status: 'active' });
    expect((await roles.assignRole(u.id, 'seller', null)).changed).toBe(true);
    expect((await roles.assignRole(u.id, 'seller', null)).changed).toBe(false);
    expect((await roles.assignRole(u.id, 'cashier', null)).changed).toBe(true);
    expect(await roles.activeRoleCodes(u.id)).toEqual(['cashier']);
    const hist = await fdb.pool.query(`SELECT count(*)::int AS n FROM user_roles WHERE user_id = $1`, [u.id]);
    expect(hist.rows[0].n).toBe(2);
    expect(await roles.revokeAll(u.id)).toBe(1);
    expect(await roles.activeRoleCodes(u.id)).toEqual([]);
  });

  it('user_profiles: create/update с row_version (конфликт версии → undefined)', async () => {
    const u = await users.create({ phoneE164: testPhone(), kind: 'customer', status: 'active' });
    const p = await profiles.create({ userId: u.id, fullName: 'Асанов Бакыт', birthYear: 1990 });
    expect(p.rowVersion).toBe(1);
    const p2 = await profiles.update(u.id, { activitySphere: 'строительство' }, 1);
    expect(p2?.rowVersion).toBe(2);
    expect(await profiles.update(u.id, { activitySphere: 'другое' }, 1)).toBeUndefined();
    await profiles.setBiometricsEnabled(u.id, true);
    expect((await profiles.findByUserId(u.id))?.biometricsEnabled).toBe(true);
  });

  it('devices: upsert по (user_id, device_key) — одна строка, метаданные обновляются, отзыв снимается повторным входом', async () => {
    const u = await users.create({ phoneE164: testPhone(), kind: 'staff', status: 'active' });
    const key = randomUUID();
    const d1 = await devices.upsert({ userId: u.id, deviceKey: key, platform: 'windows', model: 'POS-1' });
    expect(await devices.revoke(d1.id, null)).toBe(true);
    expect(await devices.listActive(u.id)).toHaveLength(0);
    const d2 = await devices.upsert({
      userId: u.id,
      deviceKey: key.toUpperCase(),
      platform: 'windows',
      appVersion: '1.3.0',
    });
    expect(d2.id).toBe(d1.id);
    expect(d2).toMatchObject({ model: 'POS-1', appVersion: '1.3.0', revokedAt: null, deviceKey: key });
    await expect(devices.upsert({ userId: u.id, deviceKey: 'not-a-uuid', platform: 'android' })).rejects.toThrow();
  });

  it('sessions: create → rotate (CAS) → повтор старого хэша не ротирует; revokeFamily/revokeAllForUser', async () => {
    const s = await seedSubject(fdb.db);
    const newToken = generateOpaqueToken();
    const rotated = await sessions.rotate(s.session.id, {
      expectedRefreshHash: sha256(s.refreshToken),
      newRefreshHash: sha256(newToken),
      idleExpiresAt: new Date(Date.now() + 3600_000),
    });
    expect(rotated?.prevRefreshHash?.equals(sha256(s.refreshToken))).toBe(true);
    expect(
      await sessions.rotate(s.session.id, {
        expectedRefreshHash: sha256(s.refreshToken),
        newRefreshHash: sha256(generateOpaqueToken()),
        idleExpiresAt: new Date(),
      }),
    ).toBeUndefined();
    expect((await sessions.findByPrevRefreshHash(sha256(s.refreshToken)))?.id).toBe(s.session.id);
    expect((await sessions.findByRefreshHash(sha256(newToken)))?.id).toBe(s.session.id);

    const second = await sessions.create({
      userId: s.userId,
      deviceId: s.deviceRowId,
      familyId: s.session.familyId,
      refreshHash: sha256(generateOpaqueToken()),
      kind: 'biometric',
      expiresAt: new Date(Date.now() + 3600_000),
      idleExpiresAt: new Date(Date.now() + 3600_000),
      amr: ['sms', 'bio'],
    });
    expect((await sessions.listActive(s.userId)).map((r) => r.id).sort()).toEqual([s.session.id, second.id].sort());
    expect((await sessions.revokeFamily(s.session.familyId, 'reuse_detected')).sort()).toEqual(
      [s.session.id, second.id].sort(),
    );
    expect(await sessions.revoke(s.session.id, 'logout')).toBe(false);
    expect((await sessions.findById(second.id))?.revokeReason).toBe('reuse_detected');

    const other = await seedSubject(fdb.db);
    expect(await sessions.revokeAllForUser(other.userId, 'logout_all', { exceptSessionId: other.session.id })).toEqual(
      [],
    );
    expect(await sessions.revokeAllForUser(other.userId, 'logout_all')).toEqual([other.session.id]);
  });

  it('token_denylist: add идемпотентен (одноразовость registration_token), isDenied, CHECK reason=used только для registration', async () => {
    const jti = randomUUID();
    const exp = new Date(Date.now() + 15 * 60_000);
    expect(await denylist.add({ jti, tokenKind: 'registration', expiresAt: exp, reason: 'used' })).toBe(true);
    expect(await denylist.add({ jti, tokenKind: 'registration', expiresAt: exp, reason: 'used' })).toBe(false);
    expect(await denylist.isDenied(jti)).toBe(true);
    expect(await denylist.isDenied(randomUUID())).toBe(false);
    await expect(
      denylist.add({ jti: randomUUID(), tokenKind: 'access', expiresAt: exp, reason: 'used' }),
    ).rejects.toThrow();
    const old = randomUUID();
    await denylist.add({ jti: old, tokenKind: 'access', expiresAt: new Date(Date.now() - 1000), reason: 'logout' });
    expect(await denylist.isDenied(old)).toBe(false);
    expect(await denylist.purgeExpired()).toBeGreaterThanOrEqual(1);
  });

  it('PgAuthStateReader: снимок пользователя, сессии с device_key и отзыва jti одним запросом', async () => {
    const s = await seedSubject(fdb.db, { role: 'cashier' });
    const reader = new PgAuthStateReader(fdb.db);
    const jti = randomUUID();
    const snap = await reader.snapshot({ userId: s.userId, sessionId: s.session.id, jti });
    expect(snap).toMatchObject({
      user: { status: 'active', kind: 'staff', permissionsVersion: 1 },
      session: { userId: s.userId, revokedAt: null, deviceKey: s.deviceKey },
      jtiDenied: false,
    });
    await denylist.add({ jti, tokenKind: 'access', expiresAt: new Date(Date.now() + 60_000), reason: 'logout' });
    expect((await reader.snapshot({ userId: s.userId, sessionId: s.session.id, jti })).jtiDenied).toBe(true);
    expect(await reader.snapshot({ userId: randomUUID(), sessionId: randomUUID(), jti })).toEqual({
      user: null,
      session: null,
      jtiDenied: true,
    });
  });
});

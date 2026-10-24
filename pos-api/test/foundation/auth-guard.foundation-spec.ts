import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Controller, Get, Global, Module } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import { base64url } from 'jose';
import request from 'supertest';
import { configureHttpApp } from '../../src/bootstrap/create-app.js';
import { AuditModule } from '../../src/common/audit/audit.module.js';
import { AuthCoreModule, AUTH_APP_GUARD } from '../../src/common/auth/auth-core.module.js';
import { CurrentUser, Public } from '../../src/common/auth/auth.decorators.js';
import { AuthStateCache } from '../../src/common/auth/auth-state.js';
import { CLOCK, FixedClock } from '../../src/common/auth/clock.js';
import { JwtService } from '../../src/common/auth/jwt.service.js';
import type { AuthenticatedPrincipal } from '../../src/common/auth/principal.js';
import { loadAppConfig } from '../../src/common/config/app-config.js';
import { ConfigModule } from '../../src/common/config/config.module.js';
import { CryptoModule } from '../../src/common/crypto/crypto.module.js';
import { PinHasher } from '../../src/common/crypto/pin-hasher.service.js';
import { DRIZZLE, PG_POOL } from '../../src/common/db/database.module.js';
import { LoggingModule } from '../../src/common/logging/logging.module.js';
import { ProblemDetailsFilter } from '../../src/common/problem-details/problem-details.filter.js';
import { RateLimitModule } from '../../src/common/rate-limit/rate-limit.module.js';
import { RequirePermission } from '../../src/common/rbac/rbac.decorators.js';
import { RbacGuard } from '../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../src/common/rbac/rbac.module.js';
import { DEFAULT_READ_ONLY_ALLOWLIST, READ_ONLY_ALLOWLIST } from '../../src/common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from '../../src/common/read-only/read-only.guard.js';
import { createValidationPipe } from '../../src/common/validation/validation.js';
import { SessionsRepository } from '../../src/users/sessions.repository.js';
import { TokenDenylistRepository } from '../../src/users/token-denylist.repository.js';
import { UserRolesRepository } from '../../src/users/user-roles.repository.js';
import { UsersModule } from '../../src/users/users.module.js';
import { UsersRepository } from '../../src/users/users.repository.js';
import type { RoleCode } from '../../src/users/users.types.js';
import { LogCapture } from '../support/test-app.js';
import { FoundationDb, seedSubject, type SeededSubject } from './support/foundation-db.js';
import { pemPair, publicSet, testSecret } from './support/keys.js';

@Controller('probe')
class ProbeController {
  @Public()
  @Get('public')
  pub() {
    return { ok: true };
  }

  /** `order.create` — у seller/cashier есть, у pending_activation — нет (permissions.yaml). */
  @RequirePermission('order.create')
  @Get('me')
  me(@CurrentUser() p: AuthenticatedPrincipal) {
    return { userId: p.userId, roles: p.roles, status: p.status, sid: p.sessionId, jti: p.jti };
  }

  /** `users.manage` — только admin. */
  @RequirePermission('users.manage')
  @Get('admin')
  admin() {
    return { ok: true };
  }
}

describe('common/auth AuthGuard + RbacGuard на embedded PostgreSQL 17 (08 §2.2, §2.4; 09 §8.1, §8.7)', () => {
  const fdb = new FoundationDb();
  const clock = new FixedClock(new Date());
  const logs = new LogCapture();
  const secretsDir = mkdtempSync(join(tmpdir(), 'pos-foundation-secrets-'));
  const k1 = pemPair();
  let app: NestExpressApplication;
  let jwt: JwtService;
  let cache: AuthStateCache;

  async function tokenFor(s: SeededSubject, role: RoleCode = 'seller', permissionsVersion = 1) {
    return (
      await jwt.signAccess({
        sub: s.userId,
        kind: role === 'customer' ? 'customer' : 'staff',
        roles: [role],
        permissionsVersion,
        deviceId: s.deviceKey,
        sid: s.session.id,
      })
    ).token;
  }

  const get = (path: string, token?: string, deviceId?: string) => {
    let r = request(app.getHttpServer()).get(`/api/v1/probe/${path}`);
    if (token) r = r.set('Authorization', `Bearer ${token}`);
    if (deviceId) r = r.set('X-Device-Id', deviceId);
    return r;
  };

  beforeAll(async () => {
    await fdb.start('foundation_guard');
    const file = (name: string, content: string) => {
      const p = join(secretsDir, name);
      writeFileSync(p, content, { mode: 0o600 });
      return p;
    };
    // staging: секреты — только файлами *_FILE (эфемерные ключи запрещены), как на тестовом контуре
    const config = loadAppConfig({
      APP_ENV: 'staging',
      PUBLIC_BASE_URL: 'https://pos-test.example.kg',
      LOG_LEVEL: 'info',
      MIN_APP_VERSION: 'android=1.0.0,windows=1.0.0',
      DATABASE_URL_FILE: file('database_url', fdb.url),
      JWT_PRIVATE_KEY_FILE: file('jwt_private.pem', k1.privatePem),
      JWT_PUBLIC_KEY_FILE: file('jwt_public.json', publicSet({ 'stg-2026-10': k1 })),
      JWT_KEY_ID: 'stg-2026-10',
      PIN_PEPPER_FILE: file('pin_pepper', testSecret()),
      OTP_HMAC_SECRET_FILE: file('otp_hmac', testSecret()),
    });

    @Global()
    @Module({
      providers: [
        { provide: PG_POOL, useValue: fdb.pool },
        { provide: DRIZZLE, useValue: fdb.db },
      ],
      exports: [PG_POOL, DRIZZLE],
    })
    class TestDbModule {}

    @Module({
      imports: [
        ConfigModule.forRoot(config),
        LoggingModule.forRoot(config, logs),
        TestDbModule,
        RbacModule,
        CryptoModule,
        AuditModule,
        AuthCoreModule,
        RateLimitModule,
        UsersModule,
      ],
      controllers: [ProbeController],
      providers: [
        { provide: READ_ONLY_ALLOWLIST, useValue: DEFAULT_READ_ONLY_ALLOWLIST },
        // Порядок как в app.module GLOBAL_PROVIDERS после интеграции: ReadOnly → Auth → RBAC
        { provide: APP_GUARD, useClass: ReadOnlyGuard },
        AUTH_APP_GUARD,
        { provide: APP_GUARD, useClass: RbacGuard },
        { provide: APP_FILTER, useClass: ProblemDetailsFilter },
        { provide: APP_PIPE, useFactory: createValidationPipe },
      ],
    })
    class FoundationRootModule {}

    const moduleRef = await Test.createTestingModule({ imports: [FoundationRootModule] })
      .overrideProvider(CLOCK)
      .useValue(clock)
      .compile();
    app = moduleRef.createNestApplication<NestExpressApplication>({ bodyParser: false, bufferLogs: true });
    configureHttpApp(app);
    await app.init();
    jwt = app.get(JwtService);
    cache = app.get(AuthStateCache);
  });

  afterAll(async () => {
    await app?.close();
    await fdb.stop();
    rmSync(secretsDir, { recursive: true, force: true });
  });

  it('ключи из JWT_*_FILE (staging): текущий kid из JWT_KEY_ID; CryptoModule поднят из *_FILE', async () => {
    expect(jwt.currentKid).toBe('stg-2026-10');
    const pin = app.get(PinHasher);
    const h = await pin.hash('9137', randomUUID());
    expect(h.pepperVersion).toBe(1);
  });

  it('@Public без токена → 200; защищённый маршрут без Bearer → 401 UNAUTHENTICATED (раньше 403)', async () => {
    expect((await get('public')).status).toBe(200);
    for (const path of ['me', 'admin']) {
      const r = await get(path);
      expect(r.status).toBe(401);
      expect(r.body.code).toBe('UNAUTHENTICATED');
    }
  });

  it('валидный токен: principal из claims + статус из БД; RBAC по permissions.yaml: seller → order.create 200, users.manage 403', async () => {
    const s = await seedSubject(fdb.db);
    const t = await tokenFor(s);
    const ok = await get('me', t, s.deviceKey);
    expect(ok.status).toBe(200);
    expect(ok.body).toMatchObject({ userId: s.userId, roles: ['seller'], status: 'active', sid: s.session.id });
    const denied = await get('admin', t, s.deviceKey);
    expect(denied.status).toBe(403);
    expect(denied.body.code).toBe('FORBIDDEN');
  });

  it('X-Device-Id: нет → 400 VALIDATION_FAILED (rule uuid); чужой → 401 SESSION_REVOKED', async () => {
    const s = await seedSubject(fdb.db);
    const t = await tokenFor(s);
    const no = await get('me', t);
    expect(no.status).toBe(400);
    expect(no.body.code).toBe('VALIDATION_FAILED');
    expect(no.body.errors[0]).toMatchObject({ field: 'X-Device-Id', rule: 'uuid' });
    const other = await get('me', t, randomUUID());
    expect(other.status).toBe(401);
    expect(other.body.code).toBe('SESSION_REVOKED');
  });

  it('T-SESS-001: подпись: alg=none, чужой ключ, истёкший токен → 401 UNAUTHENTICATED', async () => {
    const s = await seedSubject(fdb.db);
    const t = await tokenFor(s);
    const [, payload] = t.split('.');
    const none = `${base64url.encode(JSON.stringify({ alg: 'none', typ: 'JWT' }))}.${payload}.`;
    expect((await get('me', none, s.deviceKey)).body.code).toBe('UNAUTHENTICATED');
    const [h, p] = t.split('.');
    const forged = `${h}.${p}.${base64url.encode(Buffer.alloc(64, 1))}`;
    expect((await get('me', forged, s.deviceKey)).body.code).toBe('UNAUTHENTICATED');
    clock.advance(16 * 60_000);
    try {
      const r = await get('me', t, s.deviceKey);
      expect(r.status).toBe(401);
      expect(r.body.code).toBe('UNAUTHENTICATED');
    } finally {
      clock.advance(-16 * 60_000);
    }
  });

  it('смена ролей: permissions_version++ → старый токен 401 TOKEN_STALE после кэша 60 с (или сразу при invalidateUser)', async () => {
    const s = await seedSubject(fdb.db);
    const t = await tokenFor(s);
    expect((await get('me', t, s.deviceKey)).status).toBe(200);
    await new UserRolesRepository(fdb.db).assignRole(s.userId, 'cashier', null);
    await new UsersRepository(fdb.db).bumpPermissionsVersion(s.userId);
    expect((await get('me', t, s.deviceKey)).status).toBe(200); // кэш ≤ 60 с (09 §8.7, остаточный риск)
    clock.advance(61_000);
    const stale = await get('me', t, s.deviceKey);
    expect(stale.status).toBe(401);
    expect(stale.body.code).toBe('TOKEN_STALE');
    const fresh = await tokenFor(s, 'cashier', 2);
    expect((await get('me', fresh, s.deviceKey)).body.roles).toEqual(['cashier']);

    const s2 = await seedSubject(fdb.db);
    const t2 = await tokenFor(s2);
    expect((await get('me', t2, s2.deviceKey)).status).toBe(200);
    await new UsersRepository(fdb.db).bumpPermissionsVersion(s2.userId);
    cache.invalidateUser(s2.userId);
    expect((await get('me', t2, s2.deviceKey)).body.code).toBe('TOKEN_STALE');
  });

  it('отзыв: сессия revoked, jti в token_denylist, блокировка пользователя → 401 SESSION_REVOKED', async () => {
    const s = await seedSubject(fdb.db);
    const t = await tokenFor(s);
    expect((await get('me', t, s.deviceKey)).status).toBe(200);
    await new SessionsRepository(fdb.db).revoke(s.session.id, 'logout');
    cache.invalidateSession(s.session.id);
    expect((await get('me', t, s.deviceKey)).body.code).toBe('SESSION_REVOKED');

    const s2 = await seedSubject(fdb.db);
    const issued = await jwt.signAccess({
      sub: s2.userId,
      kind: 'staff',
      roles: ['seller'],
      permissionsVersion: 1,
      deviceId: s2.deviceKey,
      sid: s2.session.id,
    });
    expect((await get('me', issued.token, s2.deviceKey)).status).toBe(200);
    await new TokenDenylistRepository(fdb.db).add({
      jti: issued.jti,
      tokenKind: 'access',
      expiresAt: issued.expiresAt,
      reason: 'logout',
      sessionId: s2.session.id,
    });
    cache.denyJti(issued.jti, issued.expiresAt);
    expect((await get('me', issued.token, s2.deviceKey)).body.code).toBe('SESSION_REVOKED');
    // другой процесс без локального denyJti увидит запись БД после TTL кэша
    cache.clear();
    expect((await get('me', issued.token, s2.deviceKey)).body.code).toBe('SESSION_REVOKED');

    const s3 = await seedSubject(fdb.db);
    const t3 = await tokenFor(s3);
    await new UsersRepository(fdb.db).setStatus(s3.userId, 'blocked', { blockReason: 'тест' });
    cache.invalidateUser(s3.userId);
    expect((await get('me', t3, s3.deviceKey)).body.code).toBe('SESSION_REVOKED');
  });

  it('A-13 (регрессия): denyJti без кэшированного снимка → 401 SESSION_REVOKED, а не UNAUTHENTICATED', async () => {
    const s = await seedSubject(fdb.db);
    const issued = await jwt.signAccess({
      sub: s.userId,
      kind: 'staff',
      roles: ['seller'],
      permissionsVersion: 1,
      deviceId: s.deviceKey,
      sid: s.session.id,
    });
    // Токен ни разу не предъявлялся: снимка в кэше нет, локальный denylist (logout в этом процессе) — есть.
    cache.clear();
    cache.denyJti(issued.jti, issued.expiresAt);
    const snap = await cache.snapshot({ userId: s.userId, sessionId: s.session.id, jti: issued.jti });
    expect(snap).toEqual({ user: null, session: null, jtiDenied: true });
    const denied = await get('me', issued.token, s.deviceKey);
    expect(denied.status).toBe(401);
    expect(denied.body.code).toBe('SESSION_REVOKED');
    expect(logs.text).toMatch(/"reason":"jti_denied"/);
    cache.clear();
  });

  it('pending_activation: субъект аутентифицирован, права — псевдо-набор (order.create нет → 403)', async () => {
    const s = await seedSubject(fdb.db, { kind: 'customer', role: 'customer', status: 'pending_activation' });
    const t = await tokenFor(s, 'customer');
    const r = await get('me', t, s.deviceKey);
    expect(r.status).toBe(403);
    expect(r.body.code).toBe('FORBIDDEN');
  });

  it('kind токена ≠ users.kind, sid чужой сессии → 401', async () => {
    const s = await seedSubject(fdb.db);
    const wrongKind = await jwt.signAccess({
      sub: s.userId,
      kind: 'customer',
      roles: ['customer'],
      permissionsVersion: 1,
      deviceId: s.deviceKey,
      sid: s.session.id,
    });
    expect((await get('me', wrongKind.token, s.deviceKey)).body.code).toBe('UNAUTHENTICATED');
    const other = await seedSubject(fdb.db);
    const foreignSid = await jwt.signAccess({
      sub: s.userId,
      kind: 'staff',
      roles: ['seller'],
      permissionsVersion: 1,
      deviceId: s.deviceKey,
      sid: other.session.id,
    });
    expect((await get('me', foreignSid.token, s.deviceKey)).body.code).toBe('SESSION_REVOKED');
  });

  it('логи: событие auth.rejected с причиной и requestId; частей токена в логах нет', async () => {
    const s = await seedSubject(fdb.db);
    const t = await tokenFor(s);
    await get('me', t, randomUUID());
    const rejected = logs.json().filter((l) => l.event === 'auth.rejected');
    expect(rejected.length).toBeGreaterThan(0);
    expect(rejected.some((l) => l.reason === 'device_mismatch')).toBe(true);
    expect(logs.text).not.toContain(t.split('.')[2]);
    expect(logs.text).not.toContain(t.split('.')[1]);
  });
});

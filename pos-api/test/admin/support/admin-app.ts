import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Global, Module } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { AdminAuditModule } from '../../../src/admin/audit/admin-audit.module.js';
import { AdminSettingsModule } from '../../../src/admin/settings/admin-settings.module.js';
import { ADMIN_RATE_LIMIT, AdminRateLimitModule } from '../../../src/admin/shared/admin-rate-limit.js';
import { AdminUsersModule } from '../../../src/admin/users/admin-users.module.js';
import { configureHttpApp } from '../../../src/bootstrap/create-app.js';
import { AuditModule } from '../../../src/common/audit/audit.module.js';
import { AUTH_APP_GUARD, AuthCoreModule } from '../../../src/common/auth/auth-core.module.js';
import { CLOCK, FixedClock } from '../../../src/common/auth/clock.js';
import { JwtService } from '../../../src/common/auth/jwt.service.js';
import { loadAppConfig } from '../../../src/common/config/app-config.js';
import { ConfigModule } from '../../../src/common/config/config.module.js';
import { CryptoModule } from '../../../src/common/crypto/crypto.module.js';
import { DRIZZLE, PG_POOL } from '../../../src/common/db/database.module.js';
import { AUDIT_QUERY_PORT, SalesPortRegistry } from '../../../src/common/ports/index.js';
import { createSalesPortRegistry } from '../../../src/sales-domain/sales-ports.module.js';
import { IdempotencyInterceptor } from '../../../src/common/idempotency/idempotency.interceptor.js';
import { IdempotencyModule } from '../../../src/common/idempotency/idempotency.module.js';
import { LoggingModule } from '../../../src/common/logging/logging.module.js';
import { ProblemDetailsFilter } from '../../../src/common/problem-details/problem-details.filter.js';
import { RateLimitModule } from '../../../src/common/rate-limit/rate-limit.module.js';
import { RbacGuard } from '../../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../../src/common/rbac/rbac.module.js';
import { DEFAULT_READ_ONLY_ALLOWLIST, READ_ONLY_ALLOWLIST } from '../../../src/common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from '../../../src/common/read-only/read-only.guard.js';
import { SettingsModule } from '../../../src/common/settings/settings.module.js';
import { createValidationPipe } from '../../../src/common/validation/validation.js';
import { UserProfilesRepository } from '../../../src/users/user-profiles.repository.js';
import { UsersModule } from '../../../src/users/users.module.js';
import type { RoleCode, UserKind, UserStatusValue } from '../../../src/users/users.types.js';
import { LogCapture } from '../../support/test-app.js';
import { FoundationDb, seedSubject, type SeededSubject } from '../../foundation/support/foundation-db.js';
import { pemPair, publicSet, testSecret } from '../../foundation/support/keys.js';

export interface Actor extends SeededSubject {
  readonly role: RoleCode;
  readonly kind: UserKind;
  readonly phone: string;
  token: string;
}

/**
 * Приложение для e2e админ-раздела: тот же порядок глобальных guard'ов, что в AppModule после интеграции этапа D
 * (ReadOnly → Auth → RBAC), реальная идемпотентность на PostgreSQL (`idempotency_keys`), фундамент auth/crypto/audit
 * и AdminUsersModule (+ приглашения), AdminSettingsModule (`/admin/settings`). Время — FixedClock (CLOCK).
 */
export class AdminTestApp {
  readonly fdb = new FoundationDb();
  readonly clock = new FixedClock(new Date());
  readonly logs = new LogCapture();
  private readonly secretsDir = mkdtempSync(join(tmpdir(), 'pos-admin-secrets-'));
  app!: NestExpressApplication;
  jwt!: JwtService;

  /**
   * `adminRateLimit` — лимит RL-ADMIN в минуту (по умолчанию 120 по 08 §2.9); `audit` — журнал аудита этапа G
   * (`AdminAuditModule`: `GET /admin/audit-logs`, порт `AuditQueryPort` в реестре портов, как `SalesPortsModule`).
   */
  async start(
    dbName: string,
    opts: { readonly adminRateLimit?: number; readonly audit?: boolean } = {},
  ): Promise<this> {
    await this.fdb.start(dbName);
    const k1 = pemPair();
    const file = (name: string, content: string) => {
      const p = join(this.secretsDir, name);
      writeFileSync(p, content, { mode: 0o600 });
      return p;
    };
    const config = loadAppConfig({
      APP_ENV: 'staging',
      PUBLIC_BASE_URL: 'https://pos-test.example.kg',
      LOG_LEVEL: 'debug',
      MIN_APP_VERSION: 'android=1.0.0,windows=1.0.0',
      DATABASE_URL_FILE: file('database_url', this.fdb.url),
      JWT_PRIVATE_KEY_FILE: file('jwt_private.pem', k1.privatePem),
      JWT_PUBLIC_KEY_FILE: file('jwt_public.json', publicSet({ 'stg-admin': k1 })),
      JWT_KEY_ID: 'stg-admin',
      PIN_PEPPER_FILE: file('pin_pepper', testSecret()),
      OTP_HMAC_SECRET_FILE: file('otp_hmac', testSecret()),
    });
    const fdb = this.fdb;

    @Global()
    @Module({
      providers: [
        { provide: PG_POOL, useValue: fdb.pool },
        { provide: DRIZZLE, useValue: fdb.db },
        ...(opts.adminRateLimit !== undefined ? [{ provide: ADMIN_RATE_LIMIT, useValue: opts.adminRateLimit }] : []),
        ...(opts.audit
          ? [
              { provide: SalesPortRegistry, useFactory: createSalesPortRegistry },
              {
                provide: AUDIT_QUERY_PORT,
                inject: [SalesPortRegistry],
                useFactory: (r: SalesPortRegistry) => r.proxy(AUDIT_QUERY_PORT),
              },
            ]
          : []),
      ],
      exports: [
        PG_POOL,
        DRIZZLE,
        ...(opts.adminRateLimit !== undefined ? [ADMIN_RATE_LIMIT] : []),
        ...(opts.audit ? [SalesPortRegistry, AUDIT_QUERY_PORT] : []),
      ],
    })
    class TestDbModule {}

    @Module({
      imports: [
        ConfigModule.forRoot(config),
        LoggingModule.forRoot(config, this.logs),
        TestDbModule,
        RbacModule,
        IdempotencyModule,
        CryptoModule,
        AuditModule,
        AuthCoreModule,
        RateLimitModule,
        UsersModule,
        // RL-ADMIN (08 §2.9) — как в AdminModule
        AdminRateLimitModule,
        AdminUsersModule,
        // /admin/settings (08 §4.18.6; RM-D-015 п. 2): SettingsReader — глобальный, как в AppModule
        SettingsModule,
        AdminSettingsModule,
        ...(opts.audit ? [AdminAuditModule] : []),
      ],
      providers: [
        { provide: READ_ONLY_ALLOWLIST, useValue: DEFAULT_READ_ONLY_ALLOWLIST },
        { provide: APP_GUARD, useClass: ReadOnlyGuard },
        AUTH_APP_GUARD,
        { provide: APP_GUARD, useClass: RbacGuard },
        { provide: APP_INTERCEPTOR, useClass: IdempotencyInterceptor },
        { provide: APP_FILTER, useClass: ProblemDetailsFilter },
        { provide: APP_PIPE, useFactory: createValidationPipe },
      ],
    })
    class AdminRootModule {}

    const moduleRef = await Test.createTestingModule({ imports: [AdminRootModule] })
      .overrideProvider(CLOCK)
      .useValue(this.clock)
      .compile();
    this.app = moduleRef.createNestApplication<NestExpressApplication>({ bodyParser: false, bufferLogs: true });
    configureHttpApp(this.app);
    await this.app.init();
    this.jwt = this.app.get(JwtService);
    return this;
  }

  async stop(): Promise<void> {
    await this.app?.close();
    await this.fdb.stop();
    rmSync(this.secretsDir, { recursive: true, force: true });
  }

  /** Пользователь с ролью, устройством, сессией, профилем (ФИО) и access-токеном. */
  async actor(
    role: RoleCode,
    opts: { readonly status?: UserStatusValue; readonly kind?: UserKind; readonly fullName?: string } = {},
  ): Promise<Actor> {
    const kind = opts.kind ?? (role === 'customer' ? 'customer' : 'staff');
    const s = await seedSubject(this.fdb.db, { role, kind, status: opts.status ?? 'active' });
    await new UserProfilesRepository(this.fdb.db).create({
      userId: s.userId,
      fullName: opts.fullName ?? `Тестов ${role} Тестович`,
    });
    const phone = (
      await this.fdb.pool.query<{ p: string }>('SELECT phone_e164 AS p FROM users WHERE id=$1', [s.userId])
    ).rows[0].p;
    const a: Actor = { ...s, role, kind, phone, token: '' };
    a.token = await this.accessToken(a);
    return a;
  }

  async accessToken(a: Pick<Actor, 'userId' | 'deviceKey' | 'session' | 'role' | 'kind'>, permissionsVersion?: number) {
    const v =
      permissionsVersion ??
      (await this.fdb.pool.query<{ v: number }>('SELECT permissions_version AS v FROM users WHERE id=$1', [a.userId]))
        .rows[0].v;
    return (
      await this.jwt.signAccess({
        sub: a.userId,
        kind: a.kind,
        roles: [a.role] as never,
        permissionsVersion: v,
        deviceId: a.deviceKey,
        sid: a.session.id,
      })
    ).token;
  }

  /**
   * stepUpToken (как выдаёт `POST /auth/step-up`, 08 §2.12): `sid`, `deviceId`, `scope`, `method`, `pv` (текущий
   * `permissions_version`); 15 мин. `overrides` со значением `undefined` удаляет claim.
   */
  async stepUp(
    a: Pick<Actor, 'userId' | 'deviceKey' | 'session'>,
    scope: string | readonly string[],
    method: 'pin' | 'otp' = 'pin',
    overrides: Record<string, unknown> = {},
  ): Promise<string> {
    const pv = (
      await this.fdb.pool.query<{ v: number }>('SELECT permissions_version AS v FROM users WHERE id=$1', [a.userId])
    ).rows[0].v;
    const claims: Record<string, unknown> = {
      sid: a.session.id,
      deviceId: a.deviceKey,
      scope: Array.isArray(scope) ? scope : [scope],
      method,
      pv,
      ...overrides,
    };
    for (const k of Object.keys(claims)) if (claims[k] === undefined) delete claims[k];
    return (await this.jwt.signPurpose('step_up', { sub: a.userId, ttlSeconds: 900, claims })).token;
  }

  /** Запрос от имени субъекта: Bearer, X-Device-Id, опционально X-Step-Up-Token и Idempotency-Key. */
  req(
    method: 'get' | 'post' | 'put' | 'patch' | 'delete',
    path: string,
    a?: Pick<Actor, 'token' | 'deviceKey'>,
    opts: { readonly stepUp?: string; readonly idem?: string | true } = {},
  ) {
    let r = request(this.app.getHttpServer())[method](`/api/v1${path}`);
    if (a) r = r.set('Authorization', `Bearer ${a.token}`).set('X-Device-Id', a.deviceKey);
    if (opts.stepUp) r = r.set('X-Step-Up-Token', opts.stepUp);
    if (opts.idem) r = r.set('Idempotency-Key', opts.idem === true ? randomUUID() : opts.idem);
    return r;
  }

  async q<T extends Record<string, unknown>>(text: string, params: unknown[] = []): Promise<T[]> {
    return (await this.fdb.pool.query<T>(text, params)).rows;
  }

  async auditRows(action: string, entityId?: string) {
    return this.q<{
      action: string;
      result: string;
      reason: string | null;
      before: Record<string, unknown> | null;
      after: Record<string, unknown> | null;
      actor_user_id: string | null;
      step_up_method: string | null;
      entity_id: string | null;
      level: string;
    }>(
      `SELECT action, result, reason, before, after, actor_user_id, step_up_method, entity_id, level
         FROM audit_logs WHERE action = $1 ${entityId ? 'AND entity_id = $2' : ''} ORDER BY chain_seq`,
      entityId ? [action, entityId] : [action],
    );
  }
}

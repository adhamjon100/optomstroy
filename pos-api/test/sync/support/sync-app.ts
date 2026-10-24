import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Global, Module } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import pg from 'pg';
import request from 'supertest';
import { configureHttpApp } from '../../../src/bootstrap/create-app.js';
import { AuditModule } from '../../../src/common/audit/audit.module.js';
import { AUTH_APP_GUARD, AuthCoreModule } from '../../../src/common/auth/auth-core.module.js';
import { JwtService } from '../../../src/common/auth/jwt.service.js';
import { type AppConfig, loadAppConfig } from '../../../src/common/config/app-config.js';
import { ConfigModule } from '../../../src/common/config/config.module.js';
import { CryptoModule } from '../../../src/common/crypto/crypto.module.js';
import { DRIZZLE, PG_POOL } from '../../../src/common/db/database.module.js';
import { IdempotencyInterceptor } from '../../../src/common/idempotency/idempotency.interceptor.js';
import { IdempotencyModule } from '../../../src/common/idempotency/idempotency.module.js';
import { PgBossService } from '../../../src/common/jobs/pg-boss.service.js';
import { LoggingModule } from '../../../src/common/logging/logging.module.js';
import { ProblemDetailsFilter } from '../../../src/common/problem-details/problem-details.filter.js';
import { RateLimitModule } from '../../../src/common/rate-limit/rate-limit.module.js';
import { RbacGuard } from '../../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../../src/common/rbac/rbac.module.js';
import { DEFAULT_READ_ONLY_ALLOWLIST, READ_ONLY_ALLOWLIST } from '../../../src/common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from '../../../src/common/read-only/read-only.guard.js';
import { SettingsReader } from '../../../src/common/settings/settings-reader.js';
import { outboxPayloadHash } from '../../../src/sync/outbox/onec-outbox.writer.js';
import { createValidationPipe } from '../../../src/common/validation/validation.js';
import { createDatabase, type PosDatabase } from '../../../src/db/database.js';
import { createSyncWorkerWiring, type SyncWorkerWiring } from '../../../src/jobs/sync/sync-worker.wiring.js';
import type { SyncEntityHandler } from '../../../src/jobs/sync/sync-handler.js';
import { WorkerRuntime } from '../../../src/jobs/worker-runtime.js';
import { SyntheticCatalogSource } from '../../../src/sync/apply/catalog-source.js';
import { SYNC_JOB_SENDER, type SyncApiOptions } from '../../../src/sync/api/sync-api.common.js';
import { SyncApiModule } from '../../../src/sync/api/sync-api.module.js';
import { schedulerConfigFromEnv } from '../../../src/sync/scheduler/scheduler.config.js';
import type { SyncEntity } from '../../../src/common/enums.js';
import { UserProfilesRepository } from '../../../src/users/user-profiles.repository.js';
import { UsersModule } from '../../../src/users/users.module.js';
import type { RoleCode } from '../../../src/users/users.types.js';
import { seedSubject, type SeededSubject } from '../../foundation/support/foundation-db.js';
import { pemPair, publicSet, testSecret } from '../../foundation/support/keys.js';
import { type CatalogFixture, startCatalogFixture } from '../../support/catalog-fixture.js';
import { EmbeddedPg } from '../../support/embedded-pg.js';
import { LogCapture } from '../../support/test-app.js';
import { capturedLogger, type CapturedLogger } from '../../worker/helpers.js';

/** cron, не срабатывающий во время теста (1 января 00:00) — задания запускаются тестом явно. */
export const NEVER = '0 0 1 1 *';

export interface Actor extends SeededSubject {
  readonly role: RoleCode;
  token: string;
}

/**
 * Стенд RM-E-002: один кластер embedded PostgreSQL 17, БД со всеми миграциями и синтетическим каталогом
 * (startCatalogFixture, FakeOnecGateway в режиме каталога — «на фикстурах, не реальная интеграция»), Nest-приложение
 * с `SyncApiModule` (порядок guard'ов как в AppModule: ReadOnly → Auth → RBAC; идемпотентность на PostgreSQL) и
 * `pos-worker` (`WorkerRuntime` + `createSyncWorkerWiring`) с pg-boss в той же БД. Отправитель job API — pg-boss
 * worker'а (та же схема `pgboss`).
 */
export class SyncTestApp {
  readonly server = new EmbeddedPg();
  readonly logs = new LogCapture();
  readonly worker: CapturedLogger = capturedLogger();
  private readonly secretsDir = mkdtempSync(join(tmpdir(), 'pos-sync-secrets-'));
  fixture!: CatalogFixture;
  pool!: pg.Pool;
  db!: PosDatabase;
  app!: NestExpressApplication;
  jwt!: JwtService;
  /** Изменяемая копия конфигурации (переключение `ONEC_INBOUND_ENABLED` в тесте). */
  config!: AppConfig & Record<string, unknown>;
  runtime!: WorkerRuntime;
  wiring!: SyncWorkerWiring;

  async start(
    opts: {
      readonly handlers?: Partial<Record<SyncEntity, SyncEntityHandler>>;
      readonly api?: Partial<SyncApiOptions>;
    } = {},
  ): Promise<this> {
    await this.server.start();
    this.fixture = await startCatalogFixture({
      pg: this.server,
      database: 'pos_sync',
      skuCount: 80,
      includeFixtures: false,
    });
    this.pool = new pg.Pool({ connectionString: this.fixture.url, max: 20 });
    this.db = createDatabase(this.pool);
    const k = pemPair();
    const file = (name: string, content: string) => {
      const p = join(this.secretsDir, name);
      writeFileSync(p, content, { mode: 0o600 });
      return p;
    };
    this.config = {
      ...loadAppConfig({
        APP_ENV: 'staging',
        PUBLIC_BASE_URL: 'https://pos-test.example.kg',
        LOG_LEVEL: 'info',
        MIN_APP_VERSION: 'android=1.0.0,windows=1.0.0',
        DATABASE_URL_FILE: file('database_url', this.fixture.url),
        JWT_PRIVATE_KEY_FILE: file('jwt_private.pem', k.privatePem),
        JWT_PUBLIC_KEY_FILE: file('jwt_public.json', publicSet({ 'stg-sync': k })),
        JWT_KEY_ID: 'stg-sync',
        PIN_PEPPER_FILE: file('pin_pepper', testSecret()),
        OTP_HMAC_SECRET_FILE: file('otp_hmac', testSecret()),
        ONEC_MODE: 'fixtures',
        WORKERS_ENABLED: 'true',
      }),
    };

    // --- pos-worker (pg-boss, обработчики синхронизации RM-E-002) ---
    const schedulerCfg = schedulerConfigFromEnv(this.config, {
      pollingIntervalSeconds: 0.5,
      scheduleRefreshMs: 3_600_000,
      cron: {
        stock: NEVER,
        prices: NEVER,
        orderStatus: NEVER,
        master: NEVER,
        images: NEVER,
        reconcile: NEVER,
        countCheck: NEVER,
      },
      sync: { retryLimit: 2, retryDelay: 0, retryBackoff: false },
    });
    this.wiring = createSyncWorkerWiring({
      config: this.config,
      pool: this.pool,
      log: this.worker.log,
      scheduler: schedulerCfg,
      gateway: this.fixture.gateway,
      source: new SyntheticCatalogSource(this.fixture.gateway),
      ...(opts.handlers ? { handlers: opts.handlers } : {}),
    });
    this.runtime = new WorkerRuntime({
      enabled: true,
      connectionString: this.fixture.url,
      pool: this.pool,
      settings: new SettingsReader(this.pool),
      scheduler: schedulerCfg,
      log: this.worker.log,
      handlers: this.wiring.handlers,
      jobs: this.wiring.jobs,
      onRunFinished: this.wiring.onRunFinished,
      workerId: 'sync-test-worker',
    });
    if (!(await this.runtime.start())) throw new Error('worker не запущен');

    // --- pos-api (SyncApiModule) ---
    const pool = this.pool;
    const db = this.db;
    const config = this.config;
    const bossForStatus = new PgBossService(this.fixture.url, { autoStart: false });

    @Global()
    @Module({
      providers: [
        { provide: PG_POOL, useValue: pool },
        { provide: DRIZZLE, useValue: db },
        { provide: PgBossService, useValue: bossForStatus },
      ],
      exports: [PG_POOL, DRIZZLE, PgBossService],
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
        SyncApiModule.forRoot({ ...(opts.api ? { options: opts.api } : {}) }),
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
    class SyncRootModule {}

    const runtime = this.runtime;
    const moduleRef = await Test.createTestingModule({ imports: [SyncRootModule] })
      .overrideProvider(SYNC_JOB_SENDER)
      .useValue({
        send: (name: string, data: object, options?: { singletonKey?: string }) =>
          runtime.boss.send(name, data, options),
      })
      .compile();
    this.app = moduleRef.createNestApplication<NestExpressApplication>({ bodyParser: false, bufferLogs: true });
    configureHttpApp(this.app);
    await this.app.init();
    this.jwt = this.app.get(JwtService);
    return this;
  }

  async stop(): Promise<void> {
    await this.app?.close().catch(() => undefined);
    await this.runtime?.stop().catch(() => undefined);
    await this.pool?.end().catch(() => undefined);
    await this.fixture?.stop().catch(() => undefined);
    await this.server.stop();
    rmSync(this.secretsDir, { recursive: true, force: true });
  }

  async actor(role: RoleCode): Promise<Actor> {
    const s = await seedSubject(this.db, { role, kind: role === 'customer' ? 'customer' : 'staff', status: 'active' });
    await new UserProfilesRepository(this.db).create({ userId: s.userId, fullName: `Тестов ${role} Тестович` });
    const a: Actor = { ...s, role, token: '' };
    const v = (
      await this.pool.query<{ v: number }>('SELECT permissions_version AS v FROM users WHERE id=$1', [s.userId])
    ).rows[0].v;
    a.token = (
      await this.jwt.signAccess({
        sub: s.userId,
        kind: role === 'customer' ? 'customer' : 'staff',
        roles: [role] as never,
        permissionsVersion: v,
        deviceId: s.deviceKey,
        sid: s.session.id,
      })
    ).token;
    return a;
  }

  /** stepUpToken как от `POST /auth/step-up` (08 §2.12). */
  async stepUp(a: Actor, operation = 'sync.run.full'): Promise<string> {
    const pv = (
      await this.pool.query<{ v: number }>('SELECT permissions_version AS v FROM users WHERE id=$1', [a.userId])
    ).rows[0].v;
    return (
      await this.jwt.signPurpose('step_up', {
        sub: a.userId,
        ttlSeconds: 900,
        claims: { sid: a.session.id, deviceId: a.deviceKey, scope: [operation], method: 'pin', pv },
      })
    ).token;
  }

  req(
    method: 'get' | 'post',
    path: string,
    a?: Actor,
    opts: { readonly stepUp?: string; readonly idem?: string | true } = {},
  ) {
    let r = request(this.app.getHttpServer())[method](`/api/v1${path}`);
    if (a) r = r.set('Authorization', `Bearer ${a.token}`).set('X-Device-Id', a.deviceKey);
    if (opts.stepUp) r = r.set('X-Step-Up-Token', opts.stepUp);
    if (opts.idem) r = r.set('Idempotency-Key', opts.idem === true ? randomUUID() : opts.idem);
    return r;
  }

  async q<T extends Record<string, unknown>>(text: string, params: unknown[] = []): Promise<T[]> {
    return (await this.pool.query<T>(text, params)).rows;
  }

  /** Ожидание завершения прогона (`success|partial|failed`). */
  async waitRun(id: string, timeoutMs = 60_000): Promise<{ status: string; counts: Record<string, unknown> }> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const [r] = await this.q<{ status: string; counts: Record<string, unknown> }>(
        `SELECT status::text AS status, counts FROM sync_runs WHERE id = $1`,
        [id],
      );
      if (r && ['success', 'partial', 'failed'].includes(r.status)) return r;
      if (Date.now() > deadline) throw new Error(`прогон ${id} не завершился: ${r?.status}`);
      await new Promise((res) => setTimeout(res, 100));
    }
  }

  /** Строка onec_outbox (агрегат — синтетический UUID; FK на агрегат в DDL нет). */
  async outbox(status: string, opts: { attempts?: number; payload?: object } = {}): Promise<string> {
    const aggregateId = randomUUID();
    const [r] = await this.q<{ id: string }>(
      `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
              attempts, lease_until, locked_by, onec_ref, sent_at, dead_at, last_error_code, last_error)
       VALUES ('order', $1::uuid, $1::text, 'create', $2::jsonb, $5::bytea, $3::outbox_status,
              $4, CASE WHEN $3 = 'sending' THEN now() + interval '5 min' END,
              CASE WHEN $3 = 'sending' THEN 'other-worker' END,
              CASE WHEN $3 IN ('sent','confirmed') THEN gen_random_uuid() END,
              CASE WHEN $3 IN ('sent','confirmed') THEN now() END,
              CASE WHEN $3 = 'dead' THEN now() END,
              CASE WHEN $3 = 'dead' THEN 'ONEC_UNAVAILABLE' WHEN $3 = 'failed' THEN 'ONEC_REJECTED' END,
              CASE WHEN $3 IN ('dead','failed') THEN 'тестовая ошибка' END)
       RETURNING id`,
      [
        aggregateId,
        JSON.stringify(opts.payload ?? { mode: 'ok' }),
        status,
        opts.attempts ?? 0,
        // payload_hash — как OnecOutboxWriterService (диспетчер сверяет его, DATA-228).
        outboxPayloadHash((opts.payload ?? { mode: 'ok' }) as Record<string, unknown>),
      ],
    );
    return r.id;
  }
}

import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Controller, Get, Global, Module, Param, type Type } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import { sql } from 'drizzle-orm';
import { configureHttpApp } from '../../../src/bootstrap/create-app.js';
import { CatalogApiModule } from '../../../src/catalog/api/catalog-api.module.js';
import { CatalogRecentModule } from '../../../src/catalog/recent/recent.module.js';
import { RecordsRecentView } from '../../../src/catalog/recent/recent-view.interceptor.js';
import { CatalogSyncModule } from '../../../src/catalog/sync/catalog-sync.module.js';
import { AppVersionModule } from '../../../src/common/app-version/app-version.module.js';
import { AuditModule } from '../../../src/common/audit/audit.module.js';
import { AUTH_APP_GUARD, AuthCoreModule } from '../../../src/common/auth/auth-core.module.js';
import { JwtService } from '../../../src/common/auth/jwt.service.js';
import { type AppConfig, loadAppConfig } from '../../../src/common/config/app-config.js';
import { ConfigModule } from '../../../src/common/config/config.module.js';
import { CryptoModule } from '../../../src/common/crypto/crypto.module.js';
import { generateOpaqueToken, sha256 } from '../../../src/common/crypto/random.js';
import { DRIZZLE, PG_POOL } from '../../../src/common/db/database.module.js';
import { IdempotencyInterceptor } from '../../../src/common/idempotency/idempotency.interceptor.js';
import { IdempotencyModule } from '../../../src/common/idempotency/idempotency.module.js';
import { LoggingModule } from '../../../src/common/logging/logging.module.js';
import { ProblemDetailsFilter } from '../../../src/common/problem-details/problem-details.filter.js';
import { RateLimitModule } from '../../../src/common/rate-limit/rate-limit.module.js';
import { RequirePermission } from '../../../src/common/rbac/rbac.decorators.js';
import { RbacGuard } from '../../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../../src/common/rbac/rbac.module.js';
import { DEFAULT_READ_ONLY_ALLOWLIST, READ_ONLY_ALLOWLIST } from '../../../src/common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from '../../../src/common/read-only/read-only.guard.js';
import { SettingsReader } from '../../../src/common/settings/settings-reader.js';
import { SettingsModule } from '../../../src/common/settings/settings.module.js';
import { createValidationPipe } from '../../../src/common/validation/validation.js';
import { FavoritesModule } from '../../../src/customers/favorites/favorites.module.js';
import { createDatabase, type PosDatabase } from '../../../src/db/database.js';
import { DevicesRepository } from '../../../src/users/devices.repository.js';
import { SessionsRepository } from '../../../src/users/sessions.repository.js';
import { UserRolesRepository } from '../../../src/users/user-roles.repository.js';
import { UsersModule } from '../../../src/users/users.module.js';
import { UsersRepository } from '../../../src/users/users.repository.js';
import type { RoleCode, UserKind } from '../../../src/users/users.types.js';
import { pemPair, publicSet, testSecret } from '../../foundation/support/keys.js';
import { type CatalogFixture, type CatalogFixtureOptions, startCatalogFixture } from '../../support/catalog-fixture.js';
import { LogCapture } from '../../support/test-app.js';

export interface Actor {
  readonly userId: string;
  readonly deviceKey: string;
  readonly role: RoleCode;
  readonly token: string;
}

/**
 * Тестовая «карточка товара» с побочным эффектом «Недавние» (08 §4.4.3): тот же декоратор, что ставится на
 * `GET /catalog/products/{id}` (RM-E-004). Маршрут `/test/card/:id` — только тесты (право `catalog.read`).
 */
@Controller('test/card')
class TestCardController {
  @Get(':id')
  @RequirePermission('catalog.read')
  @RecordsRecentView()
  card(@Param('id') id: string): { id: string } {
    return { id };
  }
}

let phoneSeq = 0;
function nextPhone(): string {
  phoneSeq += 1;
  return `+99655${String(phoneSeq).padStart(7, '0')}`;
}

/**
 * Nest-приложение этапа E для тестов RM-E-015/RM-E-006: фундамент (Config, Logging, БД, Rbac, Crypto, Audit,
 * AuthCore, RateLimit, Users, Settings, AppVersion, Idempotency) + `CatalogRecentModule`, `CatalogSyncModule`, `CatalogApiModule`
 * (как в `CatalogModule`: недавние — до `products/:id`) и `FavoritesModule`; порядок guard'ов — ReadOnly → Auth → RBAC; интерсептор `Idempotency-Key` (08 §2.7).
 * БД — `startCatalogFixture` (embedded PostgreSQL 17, все миграции, синтетический каталог через конвейер 1С).
 * **Тестовые данные**: синтетика и фикстуры 1С, не реальная интеграция.
 */
export class CatalogApiTestApp {
  readonly logs = new LogCapture();
  /** Каталог файлов секретов — создаётся в `start()` (не при сборе пропущенных наборов), удаляется в `stop()`. */
  secretsDir = '';
  f!: CatalogFixture;
  app!: NestExpressApplication;
  db!: PosDatabase;
  jwt!: JwtService;
  config!: AppConfig;

  async start(
    database: string,
    fixture: CatalogFixtureOptions = {},
    env: Record<string, string> = {},
    extraControllers: Type[] = [],
  ): Promise<this> {
    this.secretsDir = mkdtempSync(join(tmpdir(), 'pos-catalog-secrets-'));
    this.f = await startCatalogFixture({ database, ...fixture });
    this.db = createDatabase(this.f.pool);
    const k = pemPair();
    const file = (name: string, content: string) => {
      const p = join(this.secretsDir, name);
      writeFileSync(p, content, { mode: 0o600 });
      return p;
    };
    this.config = loadAppConfig({
      APP_ENV: 'staging',
      PUBLIC_BASE_URL: 'https://pos-test.example.kg',
      LOG_LEVEL: 'info',
      MIN_APP_VERSION: 'android=1.2.0,windows=1.2.0',
      DATABASE_URL_FILE: file('database_url', this.f.url),
      JWT_PRIVATE_KEY_FILE: file('jwt_private.pem', k.privatePem),
      JWT_PUBLIC_KEY_FILE: file('jwt_public.json', publicSet({ 'stg-catalog': k })),
      JWT_KEY_ID: 'stg-catalog',
      PIN_PEPPER_FILE: file('pin_pepper', testSecret()),
      OTP_HMAC_SECRET_FILE: file('otp_hmac', testSecret()),
      ONEC_MODE: 'fixtures',
      CUSTOMER_SELF_SERVICE: 'true',
      ...env,
    });
    const pool = this.f.pool;
    const db = this.db;

    @Global()
    @Module({
      providers: [
        { provide: PG_POOL, useValue: pool },
        { provide: DRIZZLE, useValue: db },
      ],
      exports: [PG_POOL, DRIZZLE],
    })
    class TestDbModule {}

    @Module({
      imports: [
        ConfigModule.forRoot(this.config),
        LoggingModule.forRoot(this.config, this.logs),
        TestDbModule,
        RbacModule,
        CryptoModule,
        AuditModule,
        AuthCoreModule,
        RateLimitModule,
        UsersModule,
        SettingsModule,
        AppVersionModule,
        IdempotencyModule,
        CatalogRecentModule,
        CatalogSyncModule,
        CatalogApiModule,
        FavoritesModule,
      ],
      controllers: [TestCardController, ...extraControllers],
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
    class CatalogRootModule {}

    const moduleRef = await Test.createTestingModule({ imports: [CatalogRootModule] }).compile();
    this.app = moduleRef.createNestApplication<NestExpressApplication>({ bodyParser: false, bufferLogs: true });
    configureHttpApp(this.app);
    await this.app.init();
    this.jwt = this.app.get(JwtService);
    return this;
  }

  async stop(): Promise<void> {
    if (this.secretsDir) rmSync(this.secretsDir, { recursive: true, force: true });
    try {
      await this.app?.close();
    } finally {
      await this.f?.stop();
    }
  }

  /** Пользователь с ролью, устройством, сессией и access-токеном. */
  async actor(role: RoleCode, kind?: UserKind): Promise<Actor> {
    const k: UserKind = kind ?? (role === 'customer' ? 'customer' : 'staff');
    const user = await new UsersRepository(this.db).create({
      phoneE164: nextPhone(),
      kind: k,
      status: 'active',
      phoneVerifiedAt: new Date(),
    });
    await new UserRolesRepository(this.db).assignRole(user.id, role, null);
    const deviceKey = randomUUID();
    const device = await new DevicesRepository(this.db).upsert({ userId: user.id, deviceKey, platform: 'android' });
    const session = await new SessionsRepository(this.db).create({
      userId: user.id,
      deviceId: device.id,
      refreshHash: sha256(generateOpaqueToken()),
      expiresAt: new Date(Date.now() + 7 * 24 * 3600_000),
      idleExpiresAt: new Date(Date.now() + 24 * 3600_000),
    });
    const { token } = await this.jwt.signAccess({
      sub: user.id,
      kind: k,
      roles: [role],
      permissionsVersion: user.permissionsVersion,
      deviceId: deviceKey,
      sid: session.id,
    });
    return { userId: user.id, deviceKey, role, token };
  }

  /** Значение `app_settings` (вставка/замена) со сбросом кэша SettingsReader. */
  async setSetting(key: string, value: unknown, valueType: string): Promise<void> {
    await this.db.execute(sql`
      INSERT INTO app_settings (key, value, value_type, description_ru)
      VALUES (${key}, ${JSON.stringify(value)}::jsonb, ${valueType}, 'тест')
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`);
    this.app.get(SettingsReader).invalidate();
  }

  async rows<T extends Record<string, unknown>>(text: string, params: unknown[] = []): Promise<T[]> {
    return (await this.f.pool.query<T>(text, params)).rows;
  }
}

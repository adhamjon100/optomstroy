import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Global, Module } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import pg from 'pg';
import { configureHttpApp } from '../../../src/bootstrap/create-app.js';
import { CatalogModule } from '../../../src/catalog/catalog.module.js';
import { AppVersionModule } from '../../../src/common/app-version/app-version.module.js';
import { AuditModule } from '../../../src/common/audit/audit.module.js';
import { AUTH_APP_GUARD, AuthCoreModule } from '../../../src/common/auth/auth-core.module.js';
import { JwtService } from '../../../src/common/auth/jwt.service.js';
import { type AppConfig, loadAppConfig } from '../../../src/common/config/app-config.js';
import { ConfigModule } from '../../../src/common/config/config.module.js';
import { CryptoModule } from '../../../src/common/crypto/crypto.module.js';
import { generateOpaqueToken, sha256 } from '../../../src/common/crypto/random.js';
import { DRIZZLE, PG_POOL } from '../../../src/common/db/database.module.js';
import { LoggingModule } from '../../../src/common/logging/logging.module.js';
import { ProblemDetailsFilter } from '../../../src/common/problem-details/problem-details.filter.js';
import { RateLimitModule } from '../../../src/common/rate-limit/rate-limit.module.js';
import { RbacGuard } from '../../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../../src/common/rbac/rbac.module.js';
import { DEFAULT_READ_ONLY_ALLOWLIST, READ_ONLY_ALLOWLIST } from '../../../src/common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from '../../../src/common/read-only/read-only.guard.js';
import { SettingsReader } from '../../../src/common/settings/settings-reader.js';
import { SettingsModule } from '../../../src/common/settings/settings.module.js';
import { createValidationPipe } from '../../../src/common/validation/validation.js';
import { createDatabase, type PosDatabase } from '../../../src/db/database.js';
import { DevicesRepository } from '../../../src/users/devices.repository.js';
import { SessionsRepository } from '../../../src/users/sessions.repository.js';
import { UserRolesRepository } from '../../../src/users/user-roles.repository.js';
import { UsersModule } from '../../../src/users/users.module.js';
import { UsersRepository } from '../../../src/users/users.repository.js';
import type { RoleCode, UserKind, UserStatusValue } from '../../../src/users/users.types.js';
import { pemPair, publicSet, testSecret } from '../../foundation/support/keys.js';
import { type CatalogFixture, startCatalogFixture } from '../../support/catalog-fixture.js';
import { LogCapture } from '../../support/test-app.js';
import {
  HTTP_RATE_LIMITS,
  type HttpRateLimitGroup,
  HttpRateLimitModule,
} from '../../../src/common/rate-limit/http-rate-limit.js';

export interface Actor {
  readonly userId: string;
  readonly deviceKey: string;
  readonly role: RoleCode | null;
  readonly token: string;
}

let phoneSeq = 0;
function nextPhone(): string {
  phoneSeq += 1;
  return `+99678${String(phoneSeq).padStart(7, '0')}`;
}

/**
 * Nest-приложение для e2e каталога (RM-E-004, RM-E-014, RM-E-017): фундамент этапа D (Config, Logging, БД, Rbac,
 * Crypto, Audit, AuthCore, RateLimit, Users, Settings, AppVersion) + `CatalogModule`; guard'ы — ReadOnly → Auth →
 * RBAC, как в app.module. БД — `startCatalogFixture` (все миграции + каталог, загруженный конвейером 1С из
 * `FakeOnecGateway` в режиме синтетики). **Тестовые данные**, не реальная интеграция.
 */
export class CatalogTestApp {
  readonly logs = new LogCapture();
  readonly secretsDir = mkdtempSync(join(tmpdir(), 'pos-catalog-secrets-'));
  fx!: CatalogFixture;
  pool!: pg.Pool;
  db!: PosDatabase;
  app!: NestExpressApplication;
  jwt!: JwtService;
  config!: AppConfig;

  async start(
    opts: {
      skuCount?: number;
      env?: Record<string, string>;
      /** Подключить лимиты RL-READ/RL-SEARCH/RL-CART (08 §2.9) с переопределёнными значениями. */
      rateLimits?: Partial<Record<HttpRateLimitGroup, number>>;
    } = {},
  ): Promise<this> {
    this.fx = await startCatalogFixture({ skuCount: opts.skuCount ?? 300, database: 'pos_catalog_api' });
    this.pool = new pg.Pool({ connectionString: this.fx.url, max: 20 });
    this.db = createDatabase(this.pool);
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
      DATABASE_URL_FILE: file('database_url', this.fx.url),
      JWT_PRIVATE_KEY_FILE: file('jwt_private.pem', k.privatePem),
      JWT_PUBLIC_KEY_FILE: file('jwt_public.json', publicSet({ 'stg-cat': k })),
      JWT_KEY_ID: 'stg-cat',
      PIN_PEPPER_FILE: file('pin_pepper', testSecret()),
      OTP_HMAC_SECRET_FILE: file('otp_hmac', testSecret()),
      ONEC_MODE: 'fixtures',
      ...opts.env,
    });
    const pool = this.pool;
    const db = this.db;

    @Global()
    @Module({
      providers: [
        { provide: PG_POOL, useValue: pool },
        { provide: DRIZZLE, useValue: db },
        ...(opts.rateLimits ? [{ provide: HTTP_RATE_LIMITS, useValue: opts.rateLimits }] : []),
      ],
      exports: [PG_POOL, DRIZZLE, ...(opts.rateLimits ? [HTTP_RATE_LIMITS] : [])],
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
        CatalogModule,
        ...(opts.rateLimits ? [HttpRateLimitModule] : []),
      ],
      providers: [
        { provide: READ_ONLY_ALLOWLIST, useValue: DEFAULT_READ_ONLY_ALLOWLIST },
        { provide: APP_GUARD, useClass: ReadOnlyGuard },
        AUTH_APP_GUARD,
        { provide: APP_GUARD, useClass: RbacGuard },
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
    // Системные ключи app_settings, которые читает каталог (seeds/0001_defaults.sql — значения по умолчанию).
    await this.pool.query(
      `INSERT INTO app_settings (key, value, value_type, description_ru) VALUES
         ('low_stock_threshold', '5', 'integer', 'Порог «мало» (тест)'),
         ('customer_stock_display', '"status"', 'string', 'Показ остатков клиенту (тест)')
       ON CONFLICT (key) DO NOTHING`,
    );
    return this;
  }

  async stop(): Promise<void> {
    await this.app?.close();
    await this.pool?.end().catch(() => undefined);
    await this.fx?.stop();
    rmSync(this.secretsDir, { recursive: true, force: true });
  }

  invalidateSettings(): void {
    this.app.get(SettingsReader).invalidate();
  }

  async setSetting(key: string, json: string): Promise<void> {
    await this.pool.query(`UPDATE app_settings SET value = $2::jsonb WHERE key = $1`, [key, json]);
    this.invalidateSettings();
  }

  /** Пользователь с ролью (или без — pending_activation), устройством, сессией и access-токеном. */
  async actor(
    opts: { readonly kind?: UserKind; readonly role?: RoleCode | null; readonly status?: UserStatusValue } = {},
  ): Promise<Actor> {
    const kind = opts.kind ?? (opts.role === 'customer' ? 'customer' : 'staff');
    const role = opts.role === undefined ? (kind === 'customer' ? 'customer' : 'seller') : opts.role;
    const user = await new UsersRepository(this.db).create({
      phoneE164: nextPhone(),
      kind,
      status: opts.status ?? 'active',
      phoneVerifiedAt: new Date(),
    });
    if (role) await new UserRolesRepository(this.db).assignRole(user.id, role, null);
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
      kind,
      roles: role ? [role] : [],
      permissionsVersion: user.permissionsVersion,
      deviceId: deviceKey,
      sid: session.id,
    });
    return { userId: user.id, deviceKey, role, token };
  }

  /** Карточка клиента 1С с видом цены и подтверждённой (или иной) привязкой пользователя. */
  async linkCustomer(
    userId: string,
    priceListId: string | null,
    status: 'proposed' | 'confirmed' | 'rejected' = 'confirmed',
  ): Promise<string> {
    const c = await this.pool.query<{ id: string }>(
      `INSERT INTO customers (onec_ref, onec_code, source, name, customer_type, synced_at, source_hash, onec_status,
                              default_price_list_id)
       VALUES ($1::uuid, $2, 'onec', 'Тестовый клиент', 'individual', now(), 'test', 'n_a', $3::uuid) RETURNING id`,
      [randomUUID(), `T-${randomUUID().slice(0, 8)}`, priceListId],
    );
    await this.pool.query(
      `INSERT INTO customer_links (user_id, customer_id, status, match_method, matched_phone_e164, confirmed_at)
       VALUES ($1::uuid, $2::uuid, $3::text::customer_link_status, 'phone', '+996700000999', CASE WHEN $3::text = 'confirmed' THEN now() END)`,
      [userId, c.rows[0].id, status],
    );
    return c.rows[0].id;
  }

  /** id строки реплики по ссылке 1С. */
  async idByRef(table: 'products' | 'warehouses' | 'price_lists' | 'categories', ref: string): Promise<string> {
    const r = await this.pool.query<{ id: string }>(`SELECT id FROM ${table} WHERE onec_ref = $1::uuid`, [ref]);
    if (!r.rows[0]) throw new Error(`нет ${table} с onec_ref ${ref}`);
    return r.rows[0].id;
  }
}

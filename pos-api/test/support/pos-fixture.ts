import { randomUUID } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { type DynamicModule, Global, Module, type Provider, type Type } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import pg from 'pg';
import request from 'supertest';
import { configureHttpApp } from '../../src/bootstrap/create-app.js';
import { CartModule } from '../../src/cart/cart.module.js';
import { CatalogModule } from '../../src/catalog/catalog.module.js';
import { AppVersionModule } from '../../src/common/app-version/app-version.module.js';
import { AuditModule } from '../../src/common/audit/audit.module.js';
import { AUTH_APP_GUARD, AuthCoreModule } from '../../src/common/auth/auth-core.module.js';
import { CLOCK, type FixedClock } from '../../src/common/auth/clock.js';
import { JwtService } from '../../src/common/auth/jwt.service.js';
import { type AppConfig, loadAppConfig } from '../../src/common/config/app-config.js';
import { ConfigModule } from '../../src/common/config/config.module.js';
import { CryptoModule } from '../../src/common/crypto/crypto.module.js';
import { generateOpaqueToken, sha256 } from '../../src/common/crypto/random.js';
import { DRIZZLE, PG_POOL } from '../../src/common/db/database.module.js';
import { IdempotencyInterceptor } from '../../src/common/idempotency/idempotency.interceptor.js';
import { IdempotencyModule } from '../../src/common/idempotency/idempotency.module.js';
import { PgBossService } from '../../src/common/jobs/pg-boss.service.js';
import { LoggingModule } from '../../src/common/logging/logging.module.js';
import { Money, Quantity } from '../../src/common/money/money.js';
import { type SalesPortMap, SalesPortRegistry, type SalesPortToken } from '../../src/common/ports/index.js';
import { ProblemDetailsFilter } from '../../src/common/problem-details/problem-details.filter.js';
import { RateLimitModule } from '../../src/common/rate-limit/rate-limit.module.js';
import { RbacGuard } from '../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../src/common/rbac/rbac.module.js';
import { DEFAULT_READ_ONLY_ALLOWLIST, READ_ONLY_ALLOWLIST } from '../../src/common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from '../../src/common/read-only/read-only.guard.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { SettingsModule } from '../../src/common/settings/settings.module.js';
import { createValidationPipe } from '../../src/common/validation/validation.js';
import { createDatabase, type PosDatabase } from '../../src/db/database.js';
import { ONEC_GATEWAY } from '../../src/integrations/onec/onec-gateway.js';
import { NotificationsModule } from '../../src/notifications/notifications.module.js';
import { DocumentsModule } from '../../src/orders/documents/documents.module.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { PaymentsModule } from '../../src/payments/payments.module.js';
import type { PaymentMethod } from '../../src/common/enums.js';
import { initialPaymentStatus } from '../../src/sales-domain/payment/payment-status.js';
import { priceCart } from '../../src/sales-domain/pricing/cart-pricing.js';
import { SalesPortsModule } from '../../src/sales-domain/sales-ports.module.js';
import { outboxPayloadHash } from '../../src/sync/outbox/onec-outbox.writer.js';
import { DevicesRepository } from '../../src/users/devices.repository.js';
import { SessionsRepository } from '../../src/users/sessions.repository.js';
import { UserRolesRepository } from '../../src/users/user-roles.repository.js';
import { UsersModule } from '../../src/users/users.module.js';
import { UsersRepository } from '../../src/users/users.repository.js';
import type { RoleCode, UserKind } from '../../src/users/users.types.js';
import { pemPair, publicSet, testSecret } from '../foundation/support/keys.js';
import { type CatalogFixture, startCatalogFixture } from './catalog-fixture.js';
import { type FakeSalesPorts, createFakeSalesRegistry } from './sales-ports.fakes.js';
import { ScriptedOnecGateway } from './scripted-onec.gateway.js';
import { LogCapture } from './test-app.js';

/**
 * Тестовый стенд этапа F (корзина, заказы, платежи, документы, уведомления) — **тестовые данные**:
 * - БД: embedded PostgreSQL 17 со всеми миграциями и синтетическим каталогом (`startCatalogFixture`, конвейер 1С
 *   этапа E) + seed `seeds/0001_defaults.sql` (лимиты скидок по ролям Q-015, «Розничный покупатель», app_settings);
 * - Nest-приложение с фундаментом D (Config, Logging, БД, Rbac, Crypto, Audit, AuthCore, RateLimit, Users,
 *   Settings, AppVersion, Idempotency), каталогом E, `SalesPortsModule` и модулями этапа F (по умолчанию все);
 *   глобальные guard'ы — ReadOnly → Auth → RBAC, Idempotency-интерсептор, ProblemDetails, ValidationPipe;
 * - `onec` — `ScriptedOnecGateway` под токеном `ONEC_GATEWAY` (успех, 409, 422, 503, задержка, оплата QR через N
 *   опросов); `clock` — `FixedClock` под `CLOCK`, если передан;
 * - пользователи всех ролей с устройством, сессией и access-токеном; step-up токены; клиенты 1С с долгом/лимитом;
 *   готовые к продаже варианты; заказ напрямую в БД (`seedOrder`) — для агентов платежей/документов до модуля orders.
 *
 * ```ts
 * const t = await new PosTestApp().start({ env: { QR_PROVIDER: 'none' } });
 * const cashier = await t.actor({ role: 'cashier' });
 * const res = await t.req('get', '/cart', cashier);
 * await t.stop();
 * ```
 */
export const RETAIL_CUSTOMER_ID = '00000000-0000-7000-8000-000000000201';

export const F_MODULES: readonly (Type | DynamicModule)[] = [
  CartModule,
  OrdersModule,
  PaymentsModule,
  NotificationsModule,
  DocumentsModule,
];

export interface PosActor {
  readonly userId: string;
  readonly deviceKey: string;
  readonly deviceId: string;
  readonly sessionId: string;
  readonly role: RoleCode | null;
  readonly kind: UserKind;
  readonly token: string;
}

export interface PosFixtureOptions {
  readonly skuCount?: number;
  /** Переопределения env (например, `QR_PROVIDER`, `ONEC_SYNC_CHECK_TIMEOUT_MS`, `OUTBOX_MAX_ATTEMPTS`). */
  readonly env?: Record<string, string>;
  /** Модули этапа F (по умолчанию `F_MODULES`); `[]` — только каталог и порты. */
  readonly modules?: readonly (Type | DynamicModule)[];
  readonly providers?: readonly Provider[];
  readonly controllers?: readonly Type[];
  readonly clock?: FixedClock;
  /** Запускать pg-boss (публикация job, `outbox.dispatch`); по умолчанию `true`. */
  readonly jobs?: boolean;
  /**
   * Подменить порты заглушками (`sales-ports.fakes.ts`): `true` — все, кроме привязанных модулями; массив — токены,
   * которые оставить реальными (свои). По умолчанию — без подмены.
   */
  readonly fakePorts?: boolean | readonly SalesPortToken[];
}

export interface SaleableVariant {
  readonly variantId: string;
  readonly productId: string;
  readonly productName: string;
  readonly unitId: string;
  readonly unitCode: string;
  readonly qtyPrecision: number; // money-double: allow — число знаков единицы (0…3), не количество
  readonly price: string;
  readonly available: string;
  readonly warehouseId: string;
  readonly priceListId: string;
}

export interface OnecCustomerOptions {
  readonly name?: string;
  readonly creditAllowed?: boolean;
  /** `null` — лимит не задан. */
  readonly creditLimit?: string | null;
  readonly creditDays?: number;
  readonly discountPercent?: string | null;
  readonly priceListId?: string | null;
  readonly phoneE164?: string;
  /** Снимок долга; не задан — снимка нет. */
  readonly receivables?: {
    readonly balance: string;
    /** `null` — просрочка неизвестна (снимок неполон). */
    readonly overdue: string | null;
    readonly ageMinutes?: number;
  };
}

export interface SeedOrderOptions {
  readonly createdBy: PosActor;
  readonly customerId?: string;
  readonly method: PaymentMethod;
  readonly status?: 'submitting' | 'awaiting_payment' | 'pending_approval' | 'awaiting_shipment' | 'submit_failed';
  readonly items?: readonly { readonly variantId: string; readonly quantity: string }[];
  readonly createdVia?: 'staff' | 'customer';
  readonly discountPercent?: string;
}

export interface SeededOrder {
  readonly orderId: string;
  readonly publicNumber: string;
  readonly total: string;
  readonly paymentId: string;
  readonly outboxId: string;
}

let phoneSeq = 0;
function nextPhone(): string {
  phoneSeq += 1;
  return `+99677${String(phoneSeq).padStart(7, '0')}`;
}

const SEED_FILE = fileURLToPath(new URL('../../seeds/0001_defaults.sql', import.meta.url));

export class PosTestApp {
  readonly logs = new LogCapture();
  readonly secretsDir = mkdtempSync(join(tmpdir(), 'pos-sales-secrets-'));
  readonly onec = new ScriptedOnecGateway();
  fx!: CatalogFixture;
  pool!: pg.Pool;
  db!: PosDatabase;
  app!: NestExpressApplication;
  jwt!: JwtService;
  config!: AppConfig;
  registry!: SalesPortRegistry;
  fakes: FakeSalesPorts | undefined;
  private boss: PgBossService | undefined;

  async start(opts: PosFixtureOptions = {}): Promise<this> {
    this.fx = await startCatalogFixture({ skuCount: opts.skuCount ?? 120, database: 'pos_sales' });
    this.pool = new pg.Pool({ connectionString: this.fx.url, max: 20 });
    this.db = createDatabase(this.pool);
    await this.applySeeds();
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
      JWT_PUBLIC_KEY_FILE: file('jwt_public.json', publicSet({ 'stg-sales': k })),
      JWT_KEY_ID: 'stg-sales',
      PIN_PEPPER_FILE: file('pin_pepper', testSecret()),
      OTP_HMAC_SECRET_FILE: file('otp_hmac', testSecret()),
      ONEC_MODE: 'fixtures',
      SMS_PROVIDER: 'fake',
      ...opts.env,
    });
    const pool = this.pool;
    const db = this.db;
    const boss = opts.jobs === false ? undefined : new PgBossService(this.fx.url, { retryDelayMs: 1000 });
    this.boss = boss;

    @Global()
    @Module({
      providers: [
        { provide: PG_POOL, useValue: pool },
        { provide: DRIZZLE, useValue: db },
        ...(boss ? [{ provide: PgBossService, useValue: boss }] : []),
        { provide: ONEC_GATEWAY, useValue: this.onec },
      ],
      exports: [PG_POOL, DRIZZLE, ONEC_GATEWAY, ...(boss ? [PgBossService] : [])],
    })
    class PosTestInfraModule {}

    @Module({
      imports: [
        ConfigModule.forRoot(this.config),
        LoggingModule.forRoot(this.config, this.logs),
        PosTestInfraModule,
        SettingsModule,
        RbacModule,
        IdempotencyModule,
        CryptoModule,
        AuditModule,
        AuthCoreModule,
        RateLimitModule,
        UsersModule,
        AppVersionModule,
        CatalogModule,
        SalesPortsModule,
        ...(opts.modules ?? F_MODULES),
      ],
      controllers: [...(opts.controllers ?? [])],
      providers: [
        { provide: READ_ONLY_ALLOWLIST, useValue: DEFAULT_READ_ONLY_ALLOWLIST },
        { provide: APP_GUARD, useClass: ReadOnlyGuard },
        AUTH_APP_GUARD,
        { provide: APP_GUARD, useClass: RbacGuard },
        { provide: APP_INTERCEPTOR, useClass: IdempotencyInterceptor },
        { provide: APP_FILTER, useClass: ProblemDetailsFilter },
        { provide: APP_PIPE, useFactory: createValidationPipe },
        ...(opts.providers ?? []),
      ],
    })
    class PosRootModule {}

    let builder = Test.createTestingModule({ imports: [PosRootModule] })
      .overrideProvider(ONEC_GATEWAY)
      .useValue(this.onec);
    if (opts.clock) builder = builder.overrideProvider(CLOCK).useValue(opts.clock);
    const moduleRef = await builder.compile();
    this.app = moduleRef.createNestApplication<NestExpressApplication>({ bodyParser: false, bufferLogs: true });
    configureHttpApp(this.app);
    await this.app.init();
    if (boss) await boss.start();
    this.jwt = this.app.get(JwtService);
    this.registry = this.app.get(SalesPortRegistry);
    if (opts.fakePorts) {
      const bound = (opts.fakePorts === true ? [] : opts.fakePorts) as SalesPortToken[];
      const keep = [...bound, ...this.boundTokens()];
      this.fakes = createFakeSalesRegistry(this.registry, keep);
    }
    return this;
  }

  /** Токены, привязанные модулями приложения (реальные реализации). */
  boundTokens(): SalesPortToken[] {
    const all: SalesPortToken[] = [
      'sales.CartReader',
      'sales.CatalogPricingPort',
      'sales.InventoryCheckPort',
      'sales.OrderCreator',
      'sales.OrderStatusPort',
      'sales.PaymentsPort',
      'sales.OnecOutboxWriter',
      'sales.DocumentsPort',
      'sales.NotificationsPort',
      'sales.CreditDecisionService',
    ];
    return all.filter((t) => this.registry.isBound(t));
  }

  async stop(): Promise<void> {
    await this.app?.close();
    await this.boss?.onApplicationShutdown().catch(() => undefined);
    await this.pool?.end().catch(() => undefined);
    await this.fx?.stop();
    rmSync(this.secretsDir, { recursive: true, force: true });
  }

  private async applySeeds(): Promise<void> {
    const sql = readFileSync(SEED_FILE, 'utf8');
    const c = await this.pool.connect();
    try {
      await c.query('BEGIN');
      await c.query(`SELECT set_config('app.system', 'migration', true)`);
      // Синтетический каталог не помечает вид цены и склад по умолчанию (это делает администратор/синхронизация):
      // «Розничная» с наибольшим числом цен → `is_default` (видна и `customer`), склад с наибольшим числом остатков
      // → `is_default_for_pos`. Тогда seed не создаёт пустой вид цены «Розничная».
      await c.query(
        `UPDATE price_lists SET is_default = true,
                visible_to_roles = (SELECT array_agg(DISTINCT r) FROM unnest(visible_to_roles || '{customer}'::role_code[]) r)
          WHERE id = (SELECT pl.id FROM price_lists pl LEFT JOIN prices p ON p.price_list_id = pl.id
                       WHERE NOT pl.deletion_mark AND NOT EXISTS (SELECT 1 FROM price_lists d WHERE d.is_default)
                       GROUP BY pl.id, pl.name
                       ORDER BY (lower(pl.name) LIKE 'розничн%') DESC, count(p.id) DESC, pl.id LIMIT 1)`,
      );
      await c.query(
        `UPDATE warehouses SET is_default_for_pos = true
          WHERE id = (SELECT w.id FROM warehouses w LEFT JOIN stock_balances s ON s.warehouse_id = w.id
                       WHERE w.is_active AND NOT w.deletion_mark
                         AND NOT EXISTS (SELECT 1 FROM warehouses d WHERE d.is_default_for_pos)
                       GROUP BY w.id ORDER BY count(s.variant_id) DESC, w.id LIMIT 1)`,
      );
      await c.query(sql);
      await c.query('COMMIT');
    } catch (e) {
      await c.query('ROLLBACK').catch(() => undefined);
      throw e;
    } finally {
      c.release();
    }
  }

  // ------------------------------------------------------------------------------------------------- субъекты

  /** Пользователь роли с устройством, сессией и access-токеном (как в e2e этапов D/E). */
  async actor(opts: { readonly role?: RoleCode | null; readonly kind?: UserKind } = {}): Promise<PosActor> {
    const kind = opts.kind ?? (opts.role === 'customer' ? 'customer' : 'staff');
    const role = opts.role === undefined ? (kind === 'customer' ? 'customer' : 'seller') : opts.role;
    const user = await new UsersRepository(this.db).create({
      phoneE164: nextPhone(),
      kind,
      status: 'active',
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
    const fresh = await new UsersRepository(this.db).findById(user.id);
    const { token } = await this.jwt.signAccess({
      sub: user.id,
      kind,
      roles: role ? [role] : [],
      permissionsVersion: fresh?.permissionsVersion ?? user.permissionsVersion,
      deviceId: deviceKey,
      sid: session.id,
    });
    return { userId: user.id, deviceKey, deviceId: device.id, sessionId: session.id, role, kind, token };
  }

  /** По одному пользователю каждой роли (`integration` не создаётся — вход только техническим токеном). */
  async actors(): Promise<Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>> {
    return {
      seller: await this.actor({ role: 'seller' }),
      cashier: await this.actor({ role: 'cashier' }),
      senior_seller: await this.actor({ role: 'senior_seller' }),
      admin: await this.actor({ role: 'admin' }),
      owner: await this.actor({ role: 'owner' }),
      customer: await this.actor({ role: 'customer' }),
    };
  }

  /**
   * `X-Step-Up-Token` как выдаёт `POST /auth/step-up` (08 §2.12): `sid`, `deviceId`, `scope = [operation]`, `method`,
   * `pv`; 15 мин. `overrides` со значением `undefined` удаляет claim.
   */
  async stepUp(
    a: Pick<PosActor, 'userId' | 'deviceKey' | 'sessionId'>,
    operation: string,
    method: 'pin' | 'otp' = 'pin',
    overrides: Record<string, unknown> = {},
  ): Promise<string> {
    const pv = (await this.q<{ v: number }>('SELECT permissions_version AS v FROM users WHERE id = $1', [a.userId]))[0]
      ?.v;
    const claims: Record<string, unknown> = {
      sid: a.sessionId,
      deviceId: a.deviceKey,
      scope: [operation],
      method,
      pv,
      ...overrides,
    };
    for (const key of Object.keys(claims)) if (claims[key] === undefined) delete claims[key];
    return (await this.jwt.signPurpose('step_up', { sub: a.userId, ttlSeconds: 900, claims })).token;
  }

  /** HTTP-запрос `/api/v1…` от имени субъекта: Bearer, `X-Device-Id`, опционально step-up и `Idempotency-Key`. */
  req(
    method: 'get' | 'post' | 'put' | 'patch' | 'delete',
    path: string,
    a?: Pick<PosActor, 'token' | 'deviceKey'>,
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

  async setSetting(key: string, json: string): Promise<void> {
    await this.pool.query(
      `INSERT INTO app_settings (key, value, value_type, description_ru) VALUES ($1, $2::jsonb, 'json', 'тест')
       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
      [key, json],
    );
    this.app.get(SettingsReader).invalidate();
  }

  async auditRows(action: string, entityId?: string) {
    return this.q<{
      action: string;
      result: string;
      actor_user_id: string | null;
      step_up_method: string | null;
      entity_id: string | null;
      after: Record<string, unknown> | null;
    }>(
      `SELECT action, result, actor_user_id, step_up_method, entity_id, after FROM audit_logs
        WHERE action = $1 ${entityId ? 'AND entity_id = $2' : ''} ORDER BY chain_seq`,
      entityId ? [action, entityId] : [action],
    );
  }

  // ------------------------------------------------------------------------------------------------- данные

  async defaultPriceListId(): Promise<string> {
    const r = await this.q<{ id: string }>(
      `SELECT id FROM price_lists WHERE is_default AND NOT deletion_mark ORDER BY sort_order, id LIMIT 1`,
    );
    if (!r[0]) throw new Error('нет вида цены по умолчанию');
    return r[0].id;
  }

  async defaultWarehouseId(): Promise<string> {
    const r = await this.q<{ id: string }>(
      `SELECT id FROM warehouses WHERE is_active AND NOT deletion_mark
        ORDER BY is_default_for_pos DESC, sort_order, name, id LIMIT 1`,
    );
    if (!r[0]) throw new Error('нет активного склада');
    return r[0].id;
  }

  /**
   * Варианты, готовые к продаже: продаваемый вариант, цена за базовую единицу в виде цены (по умолчанию —
   * `is_default`), остаток > 0 на складе (по умолчанию — склад POS), единица с `qty_precision = 0` (штуки).
   */
  async saleableVariants(
    n: number, // money-double: allow — число строк выборки, не количество товара
    opts: { readonly priceListId?: string; readonly warehouseId?: string } = {},
  ): Promise<SaleableVariant[]> {
    const priceListId = opts.priceListId ?? (await this.defaultPriceListId());
    const warehouseId = opts.warehouseId ?? (await this.defaultWarehouseId());
    const rows = await this.q<{
      variant_id: string;
      product_id: string;
      product_name: string;
      unit_id: string;
      unit_code: string;
      qty_precision: number;
      price: string;
      available: string;
    }>(
      `SELECT v.id AS variant_id, p.id AS product_id, p.name AS product_name, u.id AS unit_id, u.code AS unit_code,
              u.qty_precision, pr.price::text AS price, sb.available::text AS available
         FROM product_variants v
         JOIN products p ON p.id = v.product_id
         JOIN units u ON u.id = p.base_unit_id
         JOIN prices pr ON pr.variant_id = v.id AND pr.price_list_id = $1::uuid AND pr.packaging_id IS NULL
         JOIN stock_balances sb ON sb.variant_id = v.id AND sb.warehouse_id = $2::uuid
        WHERE NOT v.deletion_mark AND NOT p.deletion_mark AND p.is_sellable AND v.is_default = NOT p.has_variants
          AND sb.available > 10 AND pr.price > 0 AND u.qty_precision = 0
        ORDER BY p.name, v.id LIMIT $3`,
      [priceListId, warehouseId, n],
    );
    return rows.map((r) => ({
      variantId: r.variant_id,
      productId: r.product_id,
      productName: r.product_name,
      unitId: r.unit_id,
      unitCode: r.unit_code,
      qtyPrecision: Number(r.qty_precision), // money-double: allow — число знаков единицы, не количество
      price: Money.of(r.price).toString(),
      available: r.available,
      warehouseId,
      priceListId,
    }));
  }

  /** Изменить цену варианта (по умолчанию в виде цены `is_default`) — для `PRICE_CHANGED`. */
  async setPrice(variantId: string, price: string, priceListId?: string): Promise<void> {
    const pl = priceListId ?? (await this.defaultPriceListId());
    await this.pool.query(
      `INSERT INTO prices (variant_id, price_list_id, packaging_id, price, synced_at, source_hash)
       VALUES ($1::uuid, $2::uuid, NULL, $3::numeric, now(), 'test')
       ON CONFLICT (variant_id, price_list_id, packaging_id) DO UPDATE SET price = EXCLUDED.price, synced_at = now()`,
      [variantId, pl, Money.of(price).toString()],
    );
  }

  /** Задать доступный остаток варианта на складе (`available_onec`) — для `STOCK_INSUFFICIENT`. */
  async setStock(variantId: string, available: string, warehouseId?: string): Promise<void> {
    const wh = warehouseId ?? (await this.defaultWarehouseId());
    await this.pool.query(
      `INSERT INTO stock_balances (variant_id, warehouse_id, quantity, reserved, available_onec, onec_snapshot_at, synced_at, source_hash)
       VALUES ($1::uuid, $2::uuid, $3::numeric, 0, $3::numeric, now(), now(), 'test')
       ON CONFLICT (variant_id, warehouse_id) DO UPDATE SET quantity = EXCLUDED.quantity, reserved = 0,
              available_onec = EXCLUDED.available_onec, synced_at = now()`,
      [variantId, wh, Quantity.of(available).toString()],
    );
  }

  /** Клиент 1С (`source='onec'`, `onec_ref`) с условиями отсрочки и (опционально) снимком долга. */
  async createOnecCustomer(o: OnecCustomerOptions = {}): Promise<string> {
    const r = await this.q<{ id: string }>(
      `INSERT INTO customers (onec_ref, onec_code, source, name, customer_type, synced_at, source_hash, onec_status,
                              credit_allowed, credit_limit, credit_days, discount_percent, default_price_list_id,
                              primary_phone_e164, phones_norm)
       VALUES ($1::uuid, $2, 'onec', $3, 'legal', now(), 'test', 'n_a', $4, $5::numeric, $6, $7::numeric, $8::uuid,
               $9, CASE WHEN $9::text IS NULL THEN '{}'::text[] ELSE ARRAY[$9::text] END)
       RETURNING id`,
      [
        randomUUID(),
        `T-${randomUUID().slice(0, 8)}`,
        o.name ?? 'ООО «Тестовый клиент»',
        o.creditAllowed ?? false,
        o.creditLimit === undefined ? null : o.creditLimit,
        o.creditDays ?? null,
        o.discountPercent ?? null,
        o.priceListId === undefined ? null : o.priceListId,
        o.phoneE164 ?? null,
      ],
    );
    const id = r[0].id;
    if (o.receivables) {
      await this.setReceivables(id, o.receivables);
    }
    return id;
  }

  async setReceivables(
    customerId: string,
    s: { readonly balance: string; readonly overdue: string | null; readonly ageMinutes?: number },
  ): Promise<void> {
    await this.pool.query(
      `INSERT INTO receivables (customer_id, balance, overdue_amount, onec_snapshot_at, synced_at, source_hash)
       VALUES ($1::uuid, $2::numeric, $3::numeric, now() - make_interval(mins => $4), now(), 'test')
       ON CONFLICT (customer_id) DO UPDATE SET balance = EXCLUDED.balance, overdue_amount = EXCLUDED.overdue_amount,
              onec_snapshot_at = EXCLUDED.onec_snapshot_at, synced_at = now()`,
      [customerId, s.balance, s.overdue, s.ageMinutes ?? 0],
    );
  }

  /** Привязка пользователя-клиента к карточке (`customer_links`). */
  async linkCustomer(
    userId: string,
    customerId: string,
    status: 'proposed' | 'confirmed' | 'rejected' = 'confirmed',
  ): Promise<void> {
    await this.pool.query(
      `INSERT INTO customer_links (user_id, customer_id, status, match_method, matched_phone_e164, confirmed_at)
       VALUES ($1::uuid, $2::uuid, $3::text::customer_link_status, 'phone', '+996700000999',
               CASE WHEN $3::text = 'confirmed' THEN now() END)`,
      [userId, customerId, status],
    );
  }

  /**
   * Заказ напрямую в БД (минуя модуль orders) с начальным платежом и строкой outbox `create` — для тестов платежей и
   * документов до готовности `POST /orders`. Суммы — движком `priceCart` (как сервер). Статусы и `onec_sync_state` —
   * согласованно с CHECK 07: `submitting` — outbox `pending`; созданные в 1С — `onec_ref`, outbox `sent`;
   * `submit_failed` — outbox `failed` (`ONEC_REJECTED`).
   */
  async seedOrder(o: SeedOrderOptions): Promise<SeededOrder> {
    const status = o.status ?? 'submitting';
    const warehouseId = await this.defaultWarehouseId();
    const priceListId = await this.defaultPriceListId();
    const variants =
      o.items ?? (await this.saleableVariants(2)).map((v, i) => ({ variantId: v.variantId, quantity: String(i + 1) }));
    const info = await this.q<{
      variant_id: string;
      product_id: string;
      product_name: string;
      unit_code: string;
      price: string;
    }>(
      `SELECT v.id AS variant_id, p.id AS product_id, p.name AS product_name, u.code AS unit_code, pr.price::text AS price
         FROM product_variants v JOIN products p ON p.id = v.product_id JOIN units u ON u.id = p.base_unit_id
         JOIN prices pr ON pr.variant_id = v.id AND pr.price_list_id = $2::uuid AND pr.packaging_id IS NULL
        WHERE v.id = ANY($1::uuid[])`,
      [variants.map((v) => v.variantId), priceListId],
    );
    const byId = new Map(info.map((r) => [r.variant_id, r]));
    const priced = priceCart({
      lines: variants.map((v, i) => {
        const r = byId.get(v.variantId);
        if (!r) throw new Error(`seedOrder: нет цены варианта ${v.variantId}`);
        return {
          lineNo: i + 1,
          variantId: v.variantId,
          packagingId: null,
          quantity: Quantity.of(v.quantity),
          unitPrice: Money.of(r.price),
        };
      }),
      customerDiscountPercent: null,
      manualDiscountPercent: o.discountPercent ?? '0',
    });
    const customerId = o.customerId ?? RETAIL_CUSTOMER_ID;
    const createdInOnec = status !== 'submitting' && status !== 'submit_failed';
    const onecRef = createdInOnec ? randomUUID() : null;
    const syncState = status === 'submit_failed' ? 'unknown' : 'pending';
    const c = await this.pool.connect();
    try {
      await c.query('BEGIN');
      const num = await c.query<{ n: string }>(`SELECT nextval('orders_number_seq')::text AS n`);
      const publicNumber = `POS-${new Date().getUTCFullYear()}-${num.rows[0].n.padStart(6, '0')}`;
      const orderId = randomUUID();
      await c.query(
        `INSERT INTO orders (id, public_number, status, customer_id, created_by_user_id, created_via, warehouse_id,
                             price_list_id, subtotal, discount_percent, customer_discount_total, manual_discount_total,
                             discount_total, total, payment_method, delivery_method, onec_ref, onec_number,
                             onec_status_raw, onec_sync_state, submitted_at, idempotency_key)
         VALUES ($1::uuid, $2, $3::order_status, $4::uuid, $5::uuid, $6, $7::uuid, $8::uuid, $9::numeric, $10::numeric,
                 $11::numeric, $12::numeric, $13::numeric, $14::numeric, $15::payment_method, 'pickup', $16::uuid,
                 $17, $18, $19::onec_sync_state, now(), $20)`,
        [
          orderId,
          publicNumber,
          status,
          customerId,
          o.createdBy.userId,
          o.createdVia ?? (o.createdBy.kind === 'customer' ? 'customer' : 'staff'),
          warehouseId,
          priceListId,
          priced.subtotal.toString(),
          priced.manualDiscountPercent,
          priced.customerDiscountTotal.toString(),
          priced.manualDiscountTotal.toString(),
          priced.discountTotal.toString(),
          priced.total.toString(),
          o.method,
          onecRef,
          onecRef ? `ОС00-${num.rows[0].n.padStart(6, '0')}` : null,
          status === 'awaiting_shipment' ? 'КВыполнению' : onecRef ? 'НеСогласован' : null,
          syncState,
          randomUUID(),
        ],
      );
      for (const l of priced.lines) {
        const r = byId.get(l.variantId)!;
        await c.query(
          `INSERT INTO order_items (order_id, line_no, variant_id, product_id, quantity, base_quantity, unit_code_snapshot,
                                    unit_price, line_subtotal, discount_percent, customer_discount_amount,
                                    manual_discount_amount, discount_amount, line_total, product_name_snapshot)
           VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5::numeric, $5::numeric, $6, $7::numeric, $8::numeric,
                   $9::numeric, $10::numeric, $11::numeric, $12::numeric, $13::numeric, $14)`,
          [
            orderId,
            l.lineNo,
            l.variantId,
            r.product_id,
            l.quantity.toString(),
            r.unit_code,
            l.unitPrice.toString(),
            l.lineSubtotal.toString(),
            priced.manualDiscountPercent,
            l.customerDiscountAmount.toString(),
            l.manualDiscountAmount.toString(),
            l.discountAmount.toString(),
            l.lineTotal.toString(),
            r.product_name,
          ],
        );
      }
      await c.query(
        `INSERT INTO order_status_history (order_id, from_status, to_status, source, actor_user_id)
         VALUES ($1::uuid, 'draft', 'submitting', 'pos_system', $2::uuid)`,
        [orderId, o.createdBy.userId],
      );
      const paymentId = randomUUID();
      const payStatus = initialPaymentStatus(o.method);
      await c.query(
        `INSERT INTO payments (id, public_number, order_id, customer_id, method, qr_provider, status, amount,
                               created_by_user_id, idempotency_key)
         VALUES ($1::uuid, next_payment_public_number(), $2::uuid, $3::uuid, $4::payment_method, $5,
                 $6::payment_status, $7::numeric, $8::uuid, $9)`,
        // Номер платежа — генератор 07 §5.40 (`payments_number_seq`, миграция 0011), как PaymentsRepository: номера
        // сидов не пересекаются с платежами, созданными API (F_spec_sync §3, FQ-PAY-02).
        [
          paymentId,
          orderId,
          customerId,
          o.method,
          o.method === 'qr_bakai' ? this.config.QR_PROVIDER : null,
          payStatus,
          priced.total.toString(),
          o.createdBy.userId,
          `order:${randomUUID()}`,
        ],
      );
      const outboxStatus = status === 'submitting' ? 'pending' : status === 'submit_failed' ? 'failed' : 'sent';
      const ob = await c.query<{ id: string }>(
        `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash, status,
                                  onec_ref, sent_at, last_error_code, requested_by_user_id, warehouse_id)
         VALUES ('order', $1::uuid, $1::text, 'create', $2::jsonb, $7::bytea, $3::outbox_status,
                 $4::uuid, CASE WHEN $3::text = 'sent' THEN now() END,
                 CASE WHEN $3::text = 'failed' THEN 'ONEC_REJECTED' END, $5::uuid, $6::uuid)
         RETURNING id`,
        [
          orderId,
          JSON.stringify({ externalId: orderId }),
          outboxStatus,
          onecRef,
          o.createdBy.userId,
          warehouseId,
          // payload_hash — как OnecOutboxWriterService (диспетчер сверяет его, DATA-228).
          outboxPayloadHash({ externalId: orderId }),
        ],
      );
      await c.query('COMMIT');
      return { orderId, publicNumber, total: priced.total.toString(), paymentId, outboxId: ob.rows[0].id };
    } catch (e) {
      await c.query('ROLLBACK').catch(() => undefined);
      throw e;
    } finally {
      c.release();
    }
  }

  /** Подменить реализацию порта (тесты). */
  replacePort<K extends SalesPortToken>(token: K, impl: SalesPortMap[K]): void {
    this.registry.replace(token, impl);
  }
}

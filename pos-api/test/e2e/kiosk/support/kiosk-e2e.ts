import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { INestApplication } from '@nestjs/common';
import { ModulesContainer } from '@nestjs/core';
import request from 'supertest';
import { createApp } from '../../../../src/bootstrap/create-app.js';
import { AuthStateCache } from '../../../../src/common/auth/auth-state.js';
import { JwtService } from '../../../../src/common/auth/jwt.service.js';
import type { AppConfig } from '../../../../src/common/config/app-config.js';
import { PinHasher } from '../../../../src/common/crypto/pin-hasher.service.js';
import { SettingsReader } from '../../../../src/common/settings/settings-reader.js';
import { createDatabase, type PosDatabase } from '../../../../src/db/database.js';
import { FakeOnecGateway } from '../../../../src/integrations/onec/fake-onec.gateway.js';
import { ONEC_GATEWAY } from '../../../../src/integrations/onec/onec-gateway.js';
import { OnecGatewayModule } from '../../../../src/integrations/onec/onec.module.js';
import type { RoleCode } from '../../../../src/users/users.types.js';
import { seedSubject } from '../../../foundation/support/foundation-db.js';
import { type CatalogFixture, startCatalogFixture } from '../../../support/catalog-fixture.js';
import { LogCapture, testConfig } from '../../../support/test-app.js';

/**
 * Стенд сквозных тестов планшета магазина на **всём приложении** AppModule (P-002, ADR-115; 12 §3.23, ворота
 * TAB-1/TAB-2): `createApp` — все модули, глобальные guard-ы ReadOnly → Auth → SessionActivity → KioskAccess → RBAC
 * (`GLOBAL_PROVIDERS`), интерсептор идемпотентности, фильтр Problem; embedded PostgreSQL 17 со всеми миграциями
 * (0001…0023) и seed `seeds/0001_defaults.sql`; синтетический каталог загружен конвейером применения 1С из
 * `FakeOnecGateway` (`startCatalogFixture`). **Тестовые данные**: номера — вымышленные `+996 555 0xx xxx` и
 * `+99670…` фундамента; «1С» — фейк `ONEC_MODE=fixtures`; код SMS — тестовый режим 09 §5.8 (`AUTH_OTP_TEST_MODE`,
 * `APP_ENV=dev`, номер «*» — ADR-109), SMS не отправляется.
 *
 * Планшет подключается настоящим `POST /admin/store-tablets` (08 §4.18.11) со step-up `kiosk.manage` по PIN через
 * `POST /auth/step-up`: сессия администратора на устройстве завершается, устройство становится планшетом.
 */
export const OTP_TEST_CODE = '246810';
export const NOTICE_VERSION = '2026-11-04';
export const STAFF_PIN = '482913';
const SEED_FILE = fileURLToPath(new URL('../../../../seeds/0001_defaults.sql', import.meta.url));

/** Заголовки клиента 08 §2.2 (версия выше `MIN_APP_VERSION` тестового окружения). */
export const CLIENT_HEADERS: Readonly<Record<string, string>> = { 'X-App-Version': '99.0.0', 'X-Platform': 'android' };

export type Method = 'get' | 'post' | 'put' | 'patch' | 'delete';

export interface Subject {
  readonly userId: string;
  readonly token: string;
  readonly deviceKey: string;
  readonly sessionId: string;
}

/** Подключённый планшет: ответ `KioskTokens` (08 §3.17) и устройство подключения. */
export interface Tablet extends Subject {
  readonly tabletId: string;
  readonly name: string;
  readonly warehouseId: string;
  readonly refreshToken: string;
  readonly exitCode: string;
}

export interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
  readonly headers: Record<string, string | string[] | undefined>;
  readonly text: string;
}

export interface CallOpts {
  readonly body?: unknown;
  readonly idem?: string | true;
  readonly stepUp?: string;
  readonly headers?: Readonly<Record<string, string>>;
}

export interface SaleableVariant {
  readonly variantId: string;
  readonly productId: string;
  readonly productName: string;
  readonly unitId: string;
  readonly price: string;
}

/** Попытка заявки: код, корзина и предпросмотр (как SCR-52 перед «Отправить заявку»). */
export interface KioskAttempt {
  readonly challengeId: string;
  readonly code: string;
  readonly cartId: string;
  readonly cartRowVersion: number;
  readonly previewToken: string;
}

let phoneSeq = 0;
/** Вымышленный мобильный номер КР `+996 555 0{prefix} xxx` (тестовые данные). */
export function buyerPhone(prefix = '09'): string {
  phoneSeq += 1;
  return `+9965550${prefix}${String(100 + (phoneSeq % 900)).padStart(3, '0')}`;
}

export class KioskE2eApp {
  readonly logs = new LogCapture();
  fx!: CatalogFixture;
  db!: PosDatabase;
  app!: INestApplication;
  config!: AppConfig;
  private tabletSeq = 0;

  /** Стенд: БД `database`, каталог `skuCount` SKU, окружение поверх тестового (`KIOSK_MODE=true` по умолчанию). */
  async start(database: string, env: Record<string, string> = {}, skuCount = 30): Promise<this> {
    this.fx = await startCatalogFixture({ skuCount, database });
    this.db = createDatabase(this.fx.pool);
    await this.applyDefaults();
    this.config = testConfig({
      DATABASE_URL: this.fx.url,
      LOG_LEVEL: 'info',
      ONEC_MODE: 'fixtures',
      SMS_PROVIDER: 'fake',
      QR_PROVIDER: 'none',
      KIOSK_MODE: 'true',
      AUTH_OTP_TEST_MODE: 'true',
      AUTH_OTP_TEST_PHONES: '*',
      AUTH_OTP_TEST_CODE: OTP_TEST_CODE,
      OTP_GLOBAL_PER_MIN: '1000',
      ...env,
    });
    this.app = await createApp(this.config, { logStream: this.logs });
    // Поиск карточки 1С по номеру — пустой ответ (иначе фикстура customers-search.200 вернёт свою карточку): решение
    // о карточке заявки — по реплике (P-002 §8.6).
    for (const gw of this.onecGateways()) gw.useFixture('findCustomersByPhone', 'customers-search.empty.200');
    return this;
  }

  async stop(): Promise<void> {
    await this.app?.close();
    await this.fx?.stop();
  }

  /** Фейк 1С `OnecGatewayModule` (`ONEC_MODE=fixtures`): корзина, заказы, платежи — `/check` и outbox. */
  onec(): FakeOnecGateway {
    return this.app.select(OnecGatewayModule).get<FakeOnecGateway>(ONEC_GATEWAY, { strict: true });
  }

  /**
   * Все экземпляры фейка 1С приложения: `OnecGatewayModule` и свой провайдер модуля поиска карточки
   * (`CustomerMatchingModule.forRoot({ onec: 'auto' })`).
   */
  onecGateways(): FakeOnecGateway[] {
    const out = new Set<FakeOnecGateway>();
    for (const mod of this.app.get(ModulesContainer).values()) {
      const p = mod.providers.get(ONEC_GATEWAY);
      if (p?.instance instanceof FakeOnecGateway) out.add(p.instance);
    }
    return [...out];
  }

  /** Как `pos-fixture`: вид цены и склад по умолчанию синтетического каталога, затем seed значений по умолчанию. */
  private async applyDefaults(): Promise<void> {
    const c = await this.fx.pool.connect();
    try {
      await c.query('BEGIN');
      await c.query(`SELECT set_config('app.system', 'migration', true)`);
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
      await c.query(readFileSync(SEED_FILE, 'utf8'));
      await c.query('COMMIT');
    } catch (e) {
      await c.query('ROLLBACK').catch(() => undefined);
      throw e;
    } finally {
      c.release();
    }
  }

  async q<T extends Record<string, unknown>>(text: string, params: unknown[] = []): Promise<T[]> {
    return (await this.fx.pool.query<T>(text, params)).rows;
  }

  /** Значение `app_settings` (JSON) и сброс кэша настроек приложения. */
  async setSetting(key: string, json: string | null): Promise<void> {
    if (json === null) await this.q(`DELETE FROM app_settings WHERE key = $1`, [key]);
    else {
      await this.q(
        `INSERT INTO app_settings (key, value, value_type, description_ru) VALUES ($1, $2::jsonb, 'json', 'тест')
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
        [key, json],
      );
    }
    this.app.get(SettingsReader).invalidate();
  }

  /** Сброс кэша состояния субъектов AuthGuard (60 с) — после правки `sessions`/`token_denylist` в БД теста. */
  clearAuthCache(): void {
    this.app.get(AuthStateCache, { strict: false }).clear();
  }

  // ------------------------------------------------------------------------------------------------- субъекты

  /** Сотрудник или покупатель: пользователь, роль, устройство, сессия; сотруднику — PIN (иначе 403 pin_not_set). */
  async subject(role: RoleCode): Promise<Subject> {
    const kind = role === 'customer' ? 'customer' : 'staff';
    const s = await seedSubject(this.db, { role, kind });
    if (kind === 'staff') {
      const h = await this.app.get(PinHasher).hash(STAFF_PIN, s.userId);
      await this.q(
        `INSERT INTO app_pins (user_id, pin_hash, pepper_version, pin_length, changed_at) VALUES ($1, $2, $3, $4, now())`,
        [s.userId, h.pinHash, h.pepperVersion, h.pinLength],
      );
    }
    const token = (
      await this.app.get(JwtService).signAccess({
        sub: s.userId,
        kind,
        roles: [role],
        permissionsVersion: 1,
        deviceId: s.deviceKey,
        sid: s.session.id,
      })
    ).token;
    return { userId: s.userId, token, deviceKey: s.deviceKey, sessionId: s.session.id };
  }

  /** Номер телефона пользователя (тестовые данные фундамента). */
  async phoneOf(userId: string): Promise<string> {
    return (await this.q<{ p: string }>(`SELECT phone_e164 AS p FROM users WHERE id = $1`, [userId]))[0].p;
  }

  /** `X-Step-Up-Token` по PIN через `POST /auth/step-up` (08 §2.12). */
  async stepUp(a: Subject, operation: string): Promise<string> {
    const r = await this.call('post', '/auth/step-up', a, { body: { method: 'pin', operation, pin: STAFF_PIN } });
    if (r.status !== 200 || typeof r.body.stepUpToken !== 'string') {
      throw new Error(`step-up ${operation}: ${r.status} ${JSON.stringify(r.body)}`);
    }
    return r.body.stepUpToken;
  }

  /** Подключение планшета настоящим `POST /admin/store-tablets` с устройства отдельного администратора. */
  async enroll(opts: { readonly name?: string; readonly warehouseId?: string } = {}): Promise<Tablet> {
    this.tabletSeq += 1;
    const name = opts.name ?? `Планшет e2e ${this.tabletSeq}`;
    const warehouseId = opts.warehouseId ?? (await this.defaultWarehouseId());
    const admin = await this.subject('admin');
    const r = await this.call('post', '/admin/store-tablets', admin, {
      body: { name, warehouseId },
      stepUp: await this.stepUp(admin, 'kiosk.manage'),
      idem: true,
    });
    if (r.status !== 201) throw new Error(`POST /admin/store-tablets: ${r.status} ${JSON.stringify(r.body)}`);
    const tabletId = String(r.body.tablet.id);
    const row = await this.q<{ user_id: string }>(`SELECT user_id FROM store_tablets WHERE id = $1`, [tabletId]);
    return {
      userId: row[0].user_id,
      token: String(r.body.accessToken),
      deviceKey: admin.deviceKey,
      sessionId: String(r.body.sid),
      tabletId,
      name,
      warehouseId,
      refreshToken: String(r.body.refreshToken),
      exitCode: String(r.body.exitCode),
    };
  }

  /** Отключение планшета администратором (`POST /admin/store-tablets/{id}/revoke`, step-up `kiosk.manage`). */
  async revoke(tabletId: string): Promise<Res> {
    const admin = await this.subject('admin');
    return this.call('post', `/admin/store-tablets/${tabletId}/revoke`, admin, {
      body: {},
      stepUp: await this.stepUp(admin, 'kiosk.manage'),
      idem: true,
    });
  }

  // ------------------------------------------------------------------------------------------------- HTTP

  /** Запрос `/api/v1{path}` (служебные `/health*` — без префикса API, как в контракте и `local-stack`). */
  req(method: Method, path: string, a?: Pick<Subject, 'token' | 'deviceKey'>, o: CallOpts = {}) {
    const url = path.startsWith('/health') ? path : `/api/v1${path}`;
    let r = request(this.app.getHttpServer())[method](url).set(CLIENT_HEADERS);
    if (a) r = r.set('Authorization', `Bearer ${a.token}`).set('X-Device-Id', a.deviceKey);
    if (o.idem) r = r.set('Idempotency-Key', o.idem === true ? randomUUID() : o.idem);
    if (o.stepUp) r = r.set('X-Step-Up-Token', o.stepUp);
    for (const [k, v] of Object.entries(o.headers ?? {})) r = r.set(k, v);
    return r;
  }

  async call(method: Method, path: string, a?: Pick<Subject, 'token' | 'deviceKey'>, o: CallOpts = {}): Promise<Res> {
    const r = this.req(method, path, a, o);
    const res = await (o.body !== undefined ? r.send(o.body as object) : r);
    return { status: res.status, body: (res.body ?? {}) as Res['body'], headers: res.headers, text: res.text ?? '' };
  }

  // ------------------------------------------------------------------------------------------------- данные

  async defaultWarehouseId(): Promise<string> {
    const r = await this.q<{ id: string }>(
      `SELECT id FROM warehouses WHERE is_active AND NOT deletion_mark
        ORDER BY is_default_for_pos DESC, sort_order, name, id LIMIT 1`,
    );
    if (!r[0]) throw new Error('нет активного склада');
    return r[0].id;
  }

  async defaultPriceListId(): Promise<string> {
    const r = await this.q<{ id: string }>(
      `SELECT id FROM price_lists WHERE is_default AND NOT deletion_mark ORDER BY sort_order, id LIMIT 1`,
    );
    if (!r[0]) throw new Error('нет вида цены по умолчанию');
    return r[0].id;
  }

  /** Простые продаваемые товары (штуки) с ценой вида по умолчанию и остатком > 10 на складе POS. */
  async saleableVariants(n: number): Promise<SaleableVariant[]> {
    const rows = await this.q<{
      variant_id: string;
      product_id: string;
      product_name: string;
      unit_id: string;
      price: string;
    }>(
      `SELECT v.id AS variant_id, p.id AS product_id, p.name AS product_name, u.id AS unit_id, pr.price::text AS price
         FROM product_variants v
         JOIN products p ON p.id = v.product_id
         JOIN units u ON u.id = p.base_unit_id
         JOIN prices pr ON pr.variant_id = v.id AND pr.price_list_id = $1::uuid AND pr.packaging_id IS NULL
         JOIN stock_balances sb ON sb.variant_id = v.id AND sb.warehouse_id = $2::uuid
        WHERE NOT v.deletion_mark AND NOT p.deletion_mark AND p.is_sellable AND v.is_default = NOT p.has_variants
          AND sb.available > 10 AND pr.price > 0 AND u.qty_precision = 0
        ORDER BY p.name, v.id LIMIT $3`,
      [await this.defaultPriceListId(), await this.defaultWarehouseId(), n],
    );
    if (rows.length < n) throw new Error(`продаваемых вариантов ${rows.length} < ${n}`);
    return rows.map((r) => ({
      variantId: r.variant_id,
      productId: r.product_id,
      productName: r.product_name,
      unitId: r.unit_id,
      price: r.price,
    }));
  }

  /** Товар в корзину планшета (`PUT /cart/items/{variantId}`, режим `set`). */
  async putItem(tab: Pick<Subject, 'token' | 'deviceKey'>, v: SaleableVariant, value = '1'): Promise<Res> {
    const c0 = await this.call('get', '/cart', tab);
    const r = await this.call('put', `/cart/items/${v.variantId}`, tab, {
      body: { quantity: { value, unitId: v.unitId, packagingId: null }, rowVersion: c0.body.rowVersion as number },
    });
    if (r.status !== 200) throw new Error(`PUT /cart/items: ${r.status} ${JSON.stringify(r.body)}`);
    return r;
  }

  /** Предпросмотр планшета (08 §4.7.7 «Предпросмотр на планшете»): наличные, самовывоз, покупатель. */
  async preview(tab: Pick<Subject, 'token' | 'deviceKey'>): Promise<Res> {
    const c = await this.call('get', '/cart', tab);
    return this.call('post', '/cart/checkout-preview', tab, {
      body: {
        cartId: c.body.id as string,
        cartRowVersion: c.body.rowVersion as number,
        paymentMethod: 'cash',
        delivery: { method: 'pickup' },
        receiver: { kind: 'customer' },
      },
    });
  }

  /** `POST /kiosk/order-otp` на номер покупателя для текущей корзины планшета. */
  async orderOtp(tab: Pick<Subject, 'token' | 'deviceKey'>, phone: string, o: CallOpts = {}): Promise<Res> {
    const c = await this.call('get', '/cart', tab);
    return this.call('post', '/kiosk/order-otp', tab, {
      ...o,
      body: { phone, cartId: c.body.id as string, noticeVersion: NOTICE_VERSION },
    });
  }

  /** Код (тестовый) и свежий предпросмотр — попытка заявки. */
  async attempt(tab: Pick<Subject, 'token' | 'deviceKey'>, phone: string): Promise<KioskAttempt> {
    const otp = await this.orderOtp(tab, phone);
    if (otp.status !== 202) throw new Error(`POST /kiosk/order-otp: ${otp.status} ${JSON.stringify(otp.body)}`);
    const p = await this.preview(tab);
    if (p.status !== 200) throw new Error(`POST /cart/checkout-preview: ${p.status} ${JSON.stringify(p.body)}`);
    return {
      challengeId: String(otp.body.challengeId),
      code: OTP_TEST_CODE,
      cartId: String(p.body.cartId),
      cartRowVersion: Number(p.body.cartRowVersion),
      previewToken: String(p.body.previewToken),
    };
  }

  /** `POST /kiosk/orders` (08 §4.25.2) попыткой `a` с ключом идемпотентности `key`. */
  submit(tab: Pick<Subject, 'token' | 'deviceKey'>, a: KioskAttempt, key: string = randomUUID()): Promise<Res> {
    return this.call('post', '/kiosk/orders', tab, { body: a, idem: key });
  }
}

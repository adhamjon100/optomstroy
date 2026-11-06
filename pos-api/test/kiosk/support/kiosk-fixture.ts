import { CartModule } from '../../../src/cart/cart.module.js';
import { KIOSK_ACCESS_GUARD } from '../../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../../src/kiosk/kiosk.module.js';
import { OrdersModule } from '../../../src/orders/orders.module.js';
import { ProfileModule } from '../../../src/profile/profile.module.js';
import { PublicSettingsModule } from '../../../src/settings/public-settings.module.js';
import { type PosActor, PosTestApp } from '../../support/pos-fixture.js';

/**
 * Стенд серверных тестов планшета магазина (P-002, ADR-115; 12 §2.15, этап K) поверх `pos-fixture` — **тестовые
 * данные**: embedded PostgreSQL 17 со всеми миграциями (в том числе 0021…0023), синтетический каталог, seed
 * `seeds/0001_defaults.sql`; модули корзины, заказов, профиля (`GET /me`, через него — `auth`), публичных настроек и
 * `kiosk`; глобальные guard-ы ReadOnly → Auth → **KioskAccessGuard** → RBAC (как `GLOBAL_PROVIDERS` app.module без
 * SessionActivityGuard: у сотрудников стенда нет PIN, правило D-48 к планшету не относится). `KIOSK_MODE` — env
 * стенда (переключение — перезапуском, 06 AC-ARCH-067 (2)).
 */

/** Пять операций `/kiosk/*` (08 §4.25.1–§4.25.5) — метод и путь для запроса стенда. */
export const KIOSK_OPERATIONS = [
  { method: 'post', path: '/kiosk/order-otp' },
  { method: 'post', path: '/kiosk/orders' },
  { method: 'get', path: '/kiosk/orders' },
  { method: 'post', path: '/kiosk/reset' },
  { method: 'post', path: '/kiosk/exit' },
] as const;

export interface KioskFixtureOptions {
  /** env `KIOSK_MODE` стенда (по умолчанию `true`). */
  readonly kioskMode?: boolean;
  readonly env?: Record<string, string>;
  readonly skuCount?: number;
}

/** Планшет стенда: технический пользователь `kind=kiosk` с токеном и строка `store_tablets`. */
export interface KioskTablet extends PosActor {
  readonly tabletId: string;
  readonly name: string;
  readonly warehouseId: string | null;
}

let tabletSeq = 0;

export class KioskTestApp extends PosTestApp {
  async startKiosk(opts: KioskFixtureOptions = {}): Promise<this> {
    return this.start({
      env: { QR_PROVIDER: 'none', KIOSK_MODE: String(opts.kioskMode ?? true), ...opts.env },
      skuCount: opts.skuCount ?? 40,
      modules: [CartModule, OrdersModule, ProfileModule, PublicSettingsModule, KioskModule],
      guards: [KIOSK_ACCESS_GUARD],
      fakePorts: true,
      jobs: false,
    });
  }

  /**
   * Подключённый планшет (как после `POST /admin/store-tablets`, 08 §4.18.11): технический пользователь без телефона
   * с ролью `kiosk`, устройством, сессией и access-токеном `kind=kiosk`; профиль с именем и складом
   * (`home_warehouse_id`, по умолчанию — склад POS); строка `store_tablets` (`active`). Хэш аварийного кода — метка
   * стенда, не код (аварийный выход проверяют тесты WP-S2B через подключение).
   */
  async tablet(opts: { readonly name?: string; readonly warehouseId?: string | null } = {}): Promise<KioskTablet> {
    tabletSeq += 1;
    const name = opts.name ?? `Планшет стенда ${tabletSeq}`;
    const warehouseId = opts.warehouseId === undefined ? await this.defaultWarehouseId() : opts.warehouseId;
    const a = await this.actor({ kind: 'kiosk' });
    const admin = await this.actor({ role: 'admin' });
    await this.q(`INSERT INTO user_profiles (user_id, full_name, home_warehouse_id) VALUES ($1, $2, $3)`, [
      a.userId,
      name,
      warehouseId,
    ]);
    const rows = await this.q<{ id: string }>(
      `INSERT INTO store_tablets (user_id, device_id, exit_code_hash, exit_code_pepper_version, enrolled_by_user_id)
       VALUES ($1, $2, 'fixture-exit-code-placeholder', 1, $3) RETURNING id`,
      [a.userId, a.deviceId, admin.userId],
    );
    const tabletId = rows[0]?.id;
    if (!tabletId) throw new Error('tablet: INSERT store_tablets не вернул строку');
    return { ...a, tabletId, name, warehouseId };
  }

  /** Отключить планшет в БД (как `POST /admin/store-tablets/{id}/revoke`, 07 §5.65: `revoked` + причина). */
  async revokeTablet(tabletId: string): Promise<void> {
    await this.q(
      `UPDATE store_tablets SET status = 'revoked', revoked_at = now(), revoke_reason = 'kiosk.revoked' WHERE id = $1`,
      [tabletId],
    );
  }
}

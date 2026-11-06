import { Inject, Injectable } from '@nestjs/common';
import type pg from 'pg';
import {
  bySubjectKind,
  isBuyerLike,
  isSubjectKind,
  type SubjectKind,
  switchSubjectKind,
} from '../../common/auth/subject-kind.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { PG_POOL } from '../../common/db/database.module.js';
import type { Principal } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { SettingsReader } from '../../common/settings/settings-reader.js';
import { fieldError } from './catalog-query.js';

/**
 * Режим показа остатков (08 §3.6, 10 CUST-022, 11 §4.4): `full` — staff (остаток, резерв, доступно);
 * `status` — customer, только `stockLevel`; `quantity` — customer, `stockLevel` + `available`.
 */
export type StockDisplay = 'full' | 'status' | 'quantity';

export interface PriceListRefRow {
  readonly id: string;
  readonly name: string;
}

export interface WarehouseRefRow {
  readonly id: string;
  readonly name: string;
}

/** Кто смотрит каталог и по каким правилам ему считать цены и остатки (вычисляется на запрос). */
export interface CatalogViewer {
  readonly userId: string;
  /** Активная роль (R1 — одна, 08 §2.2). */
  readonly role: string;
  readonly isCustomer: boolean;
  /** `catalog.prices.read` — цена по правилам роли. */
  readonly canReadPrice: boolean;
  /** `catalog.prices.read.all` — `prices[]` всех видов и параметр `priceListId`. */
  readonly canReadAllPrices: boolean;
  /** Вид цены запроса (null — видов цен нет). */
  readonly priceList: PriceListRefRow | null;
  /** Склад запроса (цена/остаток карточки; null — складов нет). */
  readonly warehouse: WarehouseRefRow | null;
  readonly stockDisplay: StockDisplay;
  /** Порог «мало» в базовых единицах (`app_settings.low_stock_threshold`). */
  readonly lowStockThreshold: string;
  /**
   * Склад закреплён (планшет магазина `kind=kiosk`, ADR-115 п. 23; 10 KIOSK-007): `warehouse` — только склад планшета
   * `user_profiles.home_warehouse_id`; остатки и проверки — только по нему (не «все склады»), параметр `warehouseId`
   * запроса — `403`. Не задано — `false` (сотрудник, покупатель).
   */
  readonly warehouseLocked?: boolean;
}

export interface ViewerOptions {
  readonly priceListId?: string;
  readonly warehouseId?: string;
}

export const LOW_STOCK_THRESHOLD_DEFAULT = 5;

/**
 * Правила выбора вида цены и склада (08 §3.6, §4.4; 10 INV-025, INV-030, CUST-021; R0 §24.2):
 * - `customer`: параметр `priceListId` не принимается (`403 FORBIDDEN`); вид цены — `customers.default_price_list_id`
 *   карточки 1С **только** при `customer_links.status='confirmed'` → `price_lists.is_default` → розничный;
 * - `staff`: `priceListId` — только с `catalog.prices.read.all` (иначе `403`), вид цены должен быть видим роли
 *   (`price_lists.visible_to_roles`); без параметра — вид цены клиента активной корзины → `is_default` → розничный;
 * - `kiosk` (планшет магазина, ADR-115; 08 §3.6 «Цены и остатки для планшета», §4.25): покупатель без привязки —
 *   обычная цена (`is_default` → розничный, без вида цены клиента), остатки по `customer_stock_display`; параметры
 *   `priceListId` и `warehouseId` → `403 FORBIDDEN`; склад — только `user_profiles.home_warehouse_id` (без
 *   `settings.defaultWarehouseId` и запасных складов), не задан или неактивен → `403 FORBIDDEN`
 *   `reason: kiosk_warehouse_unavailable` (отступление от ядра §22.10 только для `kind=kiosk`);
 * - «розничный» вид цены — первый неудалённый `price_lists` с названием «Розничн…» (признака в 07 нет — EQ-CAT-03);
 * - склад: `warehouseId` → `user_profiles.settings.defaultWarehouseId` → `user_profiles.home_warehouse_id` →
 *   `warehouses.is_default_for_pos` → первый активный склад (EQ-CAT-04);
 * - при `CUSTOMER_SELF_SERVICE=false` строки матрицы для `customer` не действуют → `403 FORBIDDEN` (10 CASH-006); к
 *   `kind=kiosk` это правило не относится — планшет проверяет только `KIOSK_MODE` (06 ARCH-067; иначе
 *   `403 KIOSK_DISABLED`, как guard планшета).
 * Вид субъекта разбирается исчерпывающе (06 ARCH-065): вид вне `staff | customer | kiosk` (в том числе служебный
 * `integration`) — `403`.
 */
@Injectable()
export class CatalogViewerService {
  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    private readonly permissions: PermissionCatalog,
    private readonly settings: SettingsReader,
    @Inject(APP_CONFIG)
    private readonly config: Pick<AppConfig, 'CUSTOMER_SELF_SERVICE'> & Partial<Pick<AppConfig, 'KIOSK_MODE'>>,
  ) {}

  /** Проверка допуска роли к режиму каталога (без запросов к БД). */
  assertAllowed(principal: Principal | undefined): asserts principal is Principal {
    if (!principal) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    switchSubjectKind(subjectKindOf(principal), {
      staff: () => undefined,
      customer: () => {
        if (!this.config.CUSTOMER_SELF_SERVICE) {
          throw new ProblemException('FORBIDDEN', { detail: 'Режим клиента выключен.' });
        }
      },
      kiosk: () => {
        if (this.config.KIOSK_MODE !== true) {
          throw new ProblemException('KIOSK_DISABLED', {
            detail: 'Сервис временно недоступен. Обратитесь к продавцу.',
          });
        }
      },
    });
  }

  /**
   * Ветка покупателя: `customer` или планшет магазина `kiosk` — покупатель без привязки (11 SEC-137 (6)); роль
   * `customer` при виде `staff` — тоже покупатель (как до ADR-115).
   */
  isCustomer(principal: Principal): boolean {
    return isBuyerLike(subjectKindOf(principal)) || principal.roles.includes('customer');
  }

  async resolve(principal: Principal | undefined, opts: ViewerOptions = {}): Promise<CatalogViewer> {
    this.assertAllowed(principal);
    const kiosk = bySubjectKind(subjectKindOf(principal), { staff: false, customer: false, kiosk: true });
    if (kiosk && (opts.priceListId !== undefined || opts.warehouseId !== undefined)) {
      // 10 KIOSK-006, KIOSK-007: на планшете — только обычная цена и склад планшета (свой склад параметром — тоже 403).
      throw new ProblemException('FORBIDDEN', { detail: 'На планшете магазина выбор вида цены и склада недоступен.' });
    }
    const granted = this.permissions.effectivePermissions(principal);
    const isCustomer = this.isCustomer(principal);
    const role = principal.roles[0] ?? (isCustomer ? 'customer' : '');
    const canReadAllPrices = !isCustomer && granted.has('catalog.prices.read.all');
    if (opts.priceListId !== undefined && !canReadAllPrices) {
      throw new ProblemException('FORBIDDEN', { detail: 'Выбор вида цены недоступен для вашей роли.' });
    }
    const [priceList, warehouse, display, threshold] = await Promise.all([
      this.priceListFor(principal.userId, role, kiosk ? 'none' : isCustomer ? 'link' : 'cart', opts.priceListId),
      kiosk ? this.kioskWarehouse(principal.userId) : this.warehouseFor(principal.userId, opts.warehouseId),
      isCustomer ? this.settings.get('customer_stock_display') : Promise.resolve('full'),
      this.settings.get('low_stock_threshold'),
    ]);
    return {
      userId: principal.userId,
      role,
      isCustomer,
      canReadPrice: granted.has('catalog.prices.read'),
      canReadAllPrices,
      priceList,
      warehouse,
      stockDisplay: isCustomer ? (display === 'quantity' ? 'quantity' : 'status') : 'full',
      lowStockThreshold: String(
        typeof threshold === 'number' && Number.isInteger(threshold) && threshold >= 0
          ? threshold
          : LOW_STOCK_THRESHOLD_DEFAULT,
      ),
      ...(kiosk ? { warehouseLocked: true } : {}),
    };
  }

  /**
   * Склад планшета магазина — только `user_profiles.home_warehouse_id`, активный и не помеченный на удаление; иначе
   * `403 FORBIDDEN` `reason: kiosk_warehouse_unavailable` (ADR-115 п. 23; запасного склада нет).
   */
  private async kioskWarehouse(userId: string): Promise<WarehouseRefRow> {
    const res = await this.pool.query<WarehouseRefRow>(
      `SELECT w.id, w.name FROM user_profiles up JOIN warehouses w ON w.id = up.home_warehouse_id
        WHERE up.user_id = $1::uuid AND w.is_active AND NOT w.deletion_mark`,
      [userId],
    );
    const row = res.rows[0];
    if (!row) {
      throw new ProblemException('FORBIDDEN', {
        detail: 'Склад планшета не задан или неактивен. Обратитесь к администратору.',
        reason: 'kiosk_warehouse_unavailable',
      });
    }
    return row;
  }

  /**
   * Вид цены зрителя; `preferredFrom` — откуда вид цены клиента: `link` — своя карточка покупателя при подтверждённой
   * привязке; `cart` — клиент активной корзины сотрудника; `none` — без клиента (планшет магазина: обычная цена
   * магазина и до, и после кода — 10 KIOSK-006).
   */
  private async priceListFor(
    userId: string,
    role: string,
    preferredFrom: 'link' | 'cart' | 'none',
    requested: string | undefined,
  ): Promise<PriceListRefRow | null> {
    if (requested !== undefined) {
      const res = await this.pool.query<{ id: string; name: string; visible: boolean }>(
        `SELECT id, name, $2::text = ANY(visible_to_roles::text[]) AS visible
           FROM price_lists WHERE id = $1::uuid AND NOT deletion_mark`,
        [requested, role],
      );
      const row = res.rows[0];
      if (!row) fieldError('priceListId', 'unknown_reference', 'Вид цены не найден.');
      if (!row.visible) throw new ProblemException('FORBIDDEN', { detail: 'Вид цены недоступен для вашей роли.' });
      return { id: row.id, name: row.name };
    }
    // Вид цены клиента: customer — своя карточка при подтверждённой привязке; staff — клиент активной корзины;
    // планшет — без клиента (строк нет: `is_default` → розничный).
    const preferred =
      preferredFrom === 'link'
        ? `SELECT c.default_price_list_id FROM customer_links l JOIN customers c ON c.id = l.customer_id
             WHERE l.user_id = $1::uuid AND l.status = 'confirmed' AND NOT c.deletion_mark LIMIT 1`
        : preferredFrom === 'cart'
          ? `SELECT c.default_price_list_id FROM carts ca JOIN customers c ON c.id = ca.customer_id
               WHERE ca.owner_user_id = $1::uuid AND ca.status = 'active' AND NOT c.deletion_mark LIMIT 1`
          : `SELECT NULL::uuid AS default_price_list_id WHERE $1::uuid IS NULL`;
    const res = await this.pool.query<PriceListRefRow>(
      `WITH pref AS (${preferred})
       SELECT pl.id, pl.name FROM price_lists pl
        WHERE NOT pl.deletion_mark AND pl.id = COALESCE(
          (SELECT x.id FROM price_lists x JOIN pref ON pref.default_price_list_id = x.id WHERE NOT x.deletion_mark),
          (SELECT x.id FROM price_lists x WHERE x.is_default AND NOT x.deletion_mark ORDER BY x.sort_order, x.id LIMIT 1),
          (SELECT x.id FROM price_lists x WHERE NOT x.deletion_mark AND lower(x.name) LIKE 'розничн%'
            ORDER BY x.sort_order, x.name, x.id LIMIT 1))`,
      [userId],
    );
    return res.rows[0] ?? null;
  }

  private async warehouseFor(userId: string, requested: string | undefined): Promise<WarehouseRefRow | null> {
    if (requested !== undefined) {
      const res = await this.pool.query<WarehouseRefRow>(
        `SELECT id, name FROM warehouses WHERE id = $1::uuid AND NOT deletion_mark AND is_active`,
        [requested],
      );
      const row = res.rows[0];
      if (!row) fieldError('warehouseId', 'unknown_reference', 'Склад не найден.');
      return row;
    }
    const res = await this.pool.query<WarehouseRefRow>(
      `WITH prof AS (
         SELECT CASE WHEN up.settings->>'defaultWarehouseId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                     THEN (up.settings->>'defaultWarehouseId')::uuid END AS settings_wh,
                up.home_warehouse_id
           FROM user_profiles up WHERE up.user_id = $1::uuid)
       SELECT w.id, w.name FROM warehouses w
        WHERE w.id = COALESCE(
          (SELECT x.id FROM warehouses x JOIN prof ON prof.settings_wh = x.id WHERE x.is_active AND NOT x.deletion_mark),
          (SELECT x.id FROM warehouses x JOIN prof ON prof.home_warehouse_id = x.id WHERE x.is_active AND NOT x.deletion_mark),
          (SELECT x.id FROM warehouses x WHERE x.is_default_for_pos AND x.is_active AND NOT x.deletion_mark LIMIT 1),
          (SELECT x.id FROM warehouses x WHERE x.is_active AND NOT x.deletion_mark ORDER BY x.sort_order, x.name, x.id LIMIT 1))`,
      [userId],
    );
    return res.rows[0] ?? null;
  }
}

/**
 * Вид субъекта зрителя (06 ARCH-065): `staff | customer | kiosk`; вид вне перечня (в том числе служебный
 * `integration`) — `403 FORBIDDEN` (отказ по умолчанию).
 */
function subjectKindOf(principal: Principal): SubjectKind {
  if (!isSubjectKind(principal.kind)) {
    throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
  }
  return principal.kind;
}

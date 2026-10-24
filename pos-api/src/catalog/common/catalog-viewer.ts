import { Inject, Injectable } from '@nestjs/common';
import type pg from 'pg';
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
 * - «розничный» вид цены — первый неудалённый `price_lists` с названием «Розничн…» (признака в 07 нет — EQ-CAT-03);
 * - склад: `warehouseId` → `user_profiles.settings.defaultWarehouseId` → `user_profiles.home_warehouse_id` →
 *   `warehouses.is_default_for_pos` → первый активный склад (EQ-CAT-04);
 * - при `CUSTOMER_SELF_SERVICE=false` строки матрицы для `customer` не действуют → `403 FORBIDDEN` (10 CASH-006).
 */
@Injectable()
export class CatalogViewerService {
  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    private readonly permissions: PermissionCatalog,
    private readonly settings: SettingsReader,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'CUSTOMER_SELF_SERVICE'>,
  ) {}

  /** Проверка допуска роли к режиму каталога (без запросов к БД). */
  assertAllowed(principal: Principal | undefined): asserts principal is Principal {
    if (!principal) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    if (principal.kind === 'customer' && !this.config.CUSTOMER_SELF_SERVICE) {
      throw new ProblemException('FORBIDDEN', { detail: 'Режим клиента выключен.' });
    }
  }

  isCustomer(principal: Principal): boolean {
    return principal.kind === 'customer' || principal.roles.includes('customer');
  }

  async resolve(principal: Principal | undefined, opts: ViewerOptions = {}): Promise<CatalogViewer> {
    this.assertAllowed(principal);
    const granted = this.permissions.effectivePermissions(principal);
    const isCustomer = this.isCustomer(principal);
    const role = principal.roles[0] ?? (isCustomer ? 'customer' : '');
    const canReadAllPrices = !isCustomer && granted.has('catalog.prices.read.all');
    if (opts.priceListId !== undefined && !canReadAllPrices) {
      throw new ProblemException('FORBIDDEN', { detail: 'Выбор вида цены недоступен для вашей роли.' });
    }
    const [priceList, warehouse, display, threshold] = await Promise.all([
      this.priceListFor(principal.userId, role, isCustomer, opts.priceListId),
      this.warehouseFor(principal.userId, opts.warehouseId),
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
    };
  }

  private async priceListFor(
    userId: string,
    role: string,
    isCustomer: boolean,
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
    // Вид цены клиента: customer — своя карточка при подтверждённой привязке; staff — клиент активной корзины.
    const preferred = isCustomer
      ? `SELECT c.default_price_list_id FROM customer_links l JOIN customers c ON c.id = l.customer_id
           WHERE l.user_id = $1::uuid AND l.status = 'confirmed' AND NOT c.deletion_mark LIMIT 1`
      : `SELECT c.default_price_list_id FROM carts ca JOIN customers c ON c.id = ca.customer_id
           WHERE ca.owner_user_id = $1::uuid AND ca.status = 'active' AND NOT c.deletion_mark LIMIT 1`;
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

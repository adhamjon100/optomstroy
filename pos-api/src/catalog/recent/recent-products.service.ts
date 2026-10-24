import { Inject, Injectable, Logger } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../../common/db/database.module.js';
import type { Principal } from '../../common/http/request-context.js';
import { SettingsReader } from '../../common/settings/settings-reader.js';
import { CatalogProductsService, type ProductSummaryDto } from '../api/catalog-products.service.js';
import { CatalogViewerService } from '../common/catalog-viewer.js';

/**
 * Ключ `app_settings` с предельным числом недавних товаров на пользователя (10 FAV-005, 07 DATA-148: 50
 * [НЕ ПОДТВЕРЖДЕНО: Q-176]). Ключа нет в seed RM-C-006 — без строки действует значение по умолчанию (EQ-CSYNC-05).
 */
export const RECENT_MAX_ITEMS_KEY = 'recent_products.max_items';
export const RECENT_MAX_ITEMS_DEFAULT = 50;
/** Верхняя граница значения ключа (страница API — ≤ 200, ядро §19.2). */
export const RECENT_MAX_ITEMS_CAP = 200;
/** `limit` `GET /catalog/products/recent`: 1…50, по умолчанию 20 (08 §4.4.5, OpenAPI). */
export const RECENT_LIMIT_DEFAULT = 20;
export const RECENT_LIMIT_MAX = 50;

export type RecentProductDto = ProductSummaryDto & { readonly viewedAt: string };

/**
 * Недавние товары пользователя (RM-E-006; 08 §4.4.5, 10 FAV-005, 07 §5.49 DATA-148): серверная копия
 * `recent_products`, только собственный список. Запись — при открытии карточки товара (побочный эффект
 * `GET /catalog/products/{id}`, 08 §4.4.3 — асинхронно, на ответ не влияет; `RecentViewInterceptor`) и при
 * добавлении в корзину (вызов `recordView` модулем cart/orders, 06 §7.4). После записи у пользователя остаётся не
 * более N последних (N — `app_settings.recent_products.max_items`, по умолчанию 50): «job оставляет 50» выполняется
 * сразу. Список упорядочен по `last_viewed_at` убыванию; товары с `deletion_mark` не показываются. «Очистить» —
 * удаление всех строк пользователя, идемпотентно. Аудит не пишется (08 §4.4.5).
 */
@Injectable()
export class RecentProductsService {
  private readonly logger = new Logger('catalog.recent');

  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    private readonly settings: SettingsReader,
    private readonly viewers: CatalogViewerService,
    private readonly products: CatalogProductsService,
  ) {}

  /** N из `app_settings` (целое 1…200), иначе 50. */
  async maxItems(): Promise<number> {
    const v = await this.settings.get(RECENT_MAX_ITEMS_KEY);
    const n = typeof v === 'number' ? v : typeof v === 'string' && /^\d{1,4}$/.test(v) ? Number(v) : NaN;
    return Number.isInteger(n) && n >= 1 ? Math.min(n, RECENT_MAX_ITEMS_CAP) : RECENT_MAX_ITEMS_DEFAULT;
  }

  /**
   * Отметка просмотра (upsert `last_viewed_at`, `view_count + 1`) и обрезка списка до N. Несуществующий товар или
   * пользователь — `false` без исключения, запись не создаётся.
   */
  async recordView(userId: string, productId: string): Promise<boolean> {
    const n = await this.maxItems();
    try {
      const ins = await this.pool.query(
        `INSERT INTO recent_products AS r (user_id, product_id, last_viewed_at, view_count)
         SELECT $1::uuid, p.id, clock_timestamp(), 1 FROM products p WHERE p.id = $2::uuid
         ON CONFLICT (user_id, product_id)
           DO UPDATE SET last_viewed_at = clock_timestamp(), view_count = r.view_count + 1`,
        [userId, productId],
      );
      if (ins.rowCount === 0) return false;
    } catch (e) {
      if ((e as { code?: string }).code === '23503') return false;
      throw e;
    }
    await this.pool.query(
      `DELETE FROM recent_products r
        WHERE r.user_id = $1::uuid
          AND (r.last_viewed_at, r.product_id) < (
            SELECT k.last_viewed_at, k.product_id FROM recent_products k WHERE k.user_id = $1::uuid
             ORDER BY k.last_viewed_at DESC, k.product_id DESC OFFSET $2::int - 1 LIMIT 1)`,
      [userId, n],
    );
    return true;
  }

  /** Отметка просмотра в фоне (побочный эффект карточки товара: ошибка не влияет на ответ, лог без ПДн). */
  recordViewInBackground(userId: string, productId: string): void {
    this.recordView(userId, productId).catch((err: unknown) => {
      this.logger.warn(
        { event: 'catalog.recent.record_failed', err },
        'recent_products: отметка просмотра не записана',
      );
    });
  }

  /** `GET /catalog/products/recent`: не более min(limit, N) товаров, по убыванию времени просмотра. */
  async list(principal: Principal | undefined, limit: number): Promise<{ items: RecentProductDto[] }> {
    const viewer = await this.viewers.resolve(principal);
    const n = Math.min(limit, await this.maxItems());
    const rows = (
      await this.pool.query<{ product_id: string; last_viewed_at: Date }>(
        `SELECT r.product_id, r.last_viewed_at
           FROM recent_products r JOIN products p ON p.id = r.product_id AND NOT p.deletion_mark
          WHERE r.user_id = $1::uuid
          ORDER BY r.last_viewed_at DESC, r.product_id DESC
          LIMIT $2::int`,
        [viewer.userId, n],
      )
    ).rows;
    const summaries = await this.products.summaries(
      viewer,
      rows.map((r) => r.product_id),
    );
    const items: RecentProductDto[] = [];
    for (const r of rows) {
      const s = summaries.get(r.product_id);
      if (s) items.push({ ...s, viewedAt: r.last_viewed_at.toISOString() });
    }
    return { items };
  }

  /** `DELETE /catalog/products/recent`: удалить все строки пользователя (повтор — то же, 204). */
  async clear(principal: Principal | undefined): Promise<void> {
    this.viewers.assertAllowed(principal);
    await this.pool.query(`DELETE FROM recent_products WHERE user_id = $1::uuid`, [principal.userId]);
  }
}

import { Inject, Injectable } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../../common/db/database.module.js';
import type { Principal } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { CatalogProductsService, type ProductSummaryDto } from '../../catalog/api/catalog-products.service.js';
import { CatalogCursorCodec } from '../../catalog/common/catalog-cursor.js';
import { CatalogViewerService } from '../../catalog/common/catalog-viewer.js';

export const FAVORITES_LIMIT_DEFAULT = 50;
export const FAVORITES_LIMIT_MAX = 200;
/** Код сортировки курсора списка (08 §2.5: курсор другой сортировки/списка → `cursor_sort_mismatch`). */
const CURSOR_SORT = 'favorites.products:created_desc';

export interface FavoritesPage {
  readonly items: ProductSummaryDto[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
  /** Всего избранных товаров (бейдж «Избранное N»; снятые с продажи в 1С — `deletion_mark` — не считаются). */
  readonly count: number;
}

export interface FavoritesListQuery {
  readonly limit: number;
  readonly cursor?: string;
  readonly warehouseId?: string;
}

/**
 * Избранные товары пользователя (RM-E-006; 08 §4.13.1–§4.13.2, 10 FAV-001…FAV-004, 07 §5.47 DATA-146):
 * серверная копия, только собственный список; `PUT` и `DELETE` идемпотентны по семантике (повтор → 204) — клиентский
 * outbox (D-32, `favorite.add`/`favorite.remove`) повторяет без ключа. Товар не существует → `404 NOT_FOUND`;
 * для `customer` снятый с продажи товар (`deletion_mark`) тоже не существует (как карточка, 08 §4.4.3). Список и
 * счётчик — без товаров с `deletion_mark` (T-FAV-003); порядок — по времени добавления, новые сверху.
 * `customer` — при `CUSTOMER_SELF_SERVICE=true` (иначе 403, `CatalogViewerService.assertAllowed`). В 1С не уходит
 * (FAV-008). Аудит не пишется.
 */
@Injectable()
export class FavoritesProductsService {
  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    private readonly viewers: CatalogViewerService,
    private readonly products: CatalogProductsService,
    private readonly cursors: CatalogCursorCodec,
  ) {}

  async list(principal: Principal | undefined, q: FavoritesListQuery): Promise<FavoritesPage> {
    const viewer = await this.viewers.resolve(
      principal,
      q.warehouseId !== undefined ? { warehouseId: q.warehouseId } : {},
    );
    const after = q.cursor !== undefined ? this.cursors.decode(q.cursor, CURSOR_SORT) : undefined;
    const params: unknown[] = [viewer.userId, q.limit + 1];
    let keyset = '';
    if (after) {
      params.push(after.s, after.id);
      keyset = `AND (f.created_at, f.product_id) < ($3::timestamptz, $4::uuid)`;
    }
    const [rows, total] = await Promise.all([
      this.pool.query<{ product_id: string; ts: string }>(
        `SELECT f.product_id,
                to_char(f.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS ts
           FROM favorites_products f JOIN products p ON p.id = f.product_id AND NOT p.deletion_mark
          WHERE f.user_id = $1::uuid ${keyset}
          ORDER BY f.created_at DESC, f.product_id DESC
          LIMIT $2::int`,
        params,
      ),
      this.pool.query<{ n: number }>(
        `SELECT count(*)::int AS n
           FROM favorites_products f JOIN products p ON p.id = f.product_id AND NOT p.deletion_mark
          WHERE f.user_id = $1::uuid`,
        [viewer.userId],
      ),
    ]);
    const hasMore = rows.rows.length > q.limit;
    const page = hasMore ? rows.rows.slice(0, q.limit) : rows.rows;
    const summaries = await this.products.summaries(
      viewer,
      page.map((r) => r.product_id),
    );
    const items: ProductSummaryDto[] = [];
    for (const r of page) {
      const s = summaries.get(r.product_id);
      if (s) items.push(s);
    }
    const last = page.at(-1);
    return {
      items,
      nextCursor: hasMore && last ? this.cursors.encode({ o: CURSOR_SORT, s: last.ts, id: last.product_id }) : null,
      hasMore,
      count: total.rows[0]?.n ?? 0,
    };
  }

  /** `PUT /favorites/products/{id}`: добавить (уже есть → без изменений). */
  async add(principal: Principal | undefined, productId: string): Promise<void> {
    const userId = await this.assertProduct(principal, productId);
    await this.pool.query(
      `INSERT INTO favorites_products (user_id, product_id) VALUES ($1::uuid, $2::uuid)
       ON CONFLICT (user_id, product_id) DO NOTHING`,
      [userId, productId],
    );
  }

  /** `DELETE /favorites/products/{id}`: удалить (нет в избранном → без изменений). */
  async remove(principal: Principal | undefined, productId: string): Promise<void> {
    const userId = await this.assertProduct(principal, productId);
    await this.pool.query(`DELETE FROM favorites_products WHERE user_id = $1::uuid AND product_id = $2::uuid`, [
      userId,
      productId,
    ]);
  }

  private async assertProduct(principal: Principal | undefined, productId: string): Promise<string> {
    this.viewers.assertAllowed(principal);
    const res = await this.pool.query<{ deletion_mark: boolean }>(
      `SELECT deletion_mark FROM products WHERE id = $1::uuid`,
      [productId],
    );
    const row = res.rows[0];
    if (!row || (row.deletion_mark && this.viewers.isCustomer(principal))) {
      throw new ProblemException('NOT_FOUND', { detail: 'Товар не найден.' });
    }
    return principal.userId;
  }
}

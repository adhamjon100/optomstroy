import { Inject, Injectable } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../../common/db/database.module.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { imageOf, isoOf, latest } from '../common/catalog-format.js';
import type { CatalogViewer } from '../common/catalog-viewer.js';
import { type UnitDto, unitDto } from './catalog-products.service.js';

export interface CategoryNodeDto {
  readonly id: string;
  readonly parentId: string | null;
  readonly name: string;
  readonly code?: string;
  readonly productCount: number;
  readonly sortOrder: number;
  readonly iconKey?: string;
  readonly imageUrl: string | null;
  readonly hasChildren: boolean;
  readonly deletionMark: boolean;
  readonly onecRef?: string;
  readonly children?: CategoryNodeDto[];
}

export interface CategoriesQuery {
  readonly parentId?: string;
  readonly depth?: number;
  readonly includeEmpty: boolean;
  readonly inStockOnly: boolean;
}

export interface CategoriesResponse {
  readonly items: CategoryNodeDto[];
  readonly asOf?: string;
  readonly snapshotVersion: string;
}

interface CategoryRow {
  id: string;
  parent_id: string | null;
  name: string;
  onec_code: string | null;
  onec_ref: string | null;
  sort_order: number;
  icon_key: string | null;
  product_count_cache: number;
  img_sha: Buffer | null;
}

/**
 * Справочники каталога (08 §4.4.1, §4.4.6): дерево категорий со счётчиками, единицы, виды цен (только staff),
 * склады. Реплика 1С, только чтение (D-28). Скрытые (`is_visible=false`) и помеченные на удаление категории не
 * отдаются; `productCount` — активные продаваемые товары поддерева (`product_count_cache`, пересчитывает конвейер
 * синхронизации, EQ-ONEC-14), при `inStockOnly` — товары с `available > 0` на складе зрителя (считается на запрос).
 */
@Injectable()
export class CatalogReferenceService {
  constructor(@Inject(PG_POOL) private readonly pool: pg.Pool) {}

  async categories(viewer: CatalogViewer, q: CategoriesQuery): Promise<CategoriesResponse> {
    const [rows, meta, live] = await Promise.all([
      this.pool.query<CategoryRow>(
        `SELECT c.id, c.parent_id, c.name, c.onec_code, c.onec_ref::text AS onec_ref, c.sort_order, c.icon_key,
                c.product_count_cache, img.checksum_sha256 AS img_sha
           FROM categories c
           LEFT JOIN product_images img ON img.id = c.image_id AND img.deleted_at IS NULL AND img.status = 'ready'
          WHERE NOT c.deletion_mark AND c.is_visible
          ORDER BY c.sort_order, c.name, c.id`,
      ),
      this.pool.query<{ max_updated: Date | null; n: string; ok: Date | null; synced: Date | null }>(
        `SELECT max(updated_at) AS max_updated, count(*)::text AS n, max(synced_at) AS synced,
                (SELECT last_success_at FROM sync_state WHERE entity = 'categories') AS ok
           FROM categories`,
      ),
      q.inStockOnly ? this.inStockCounts(viewer) : Promise.resolve(undefined),
    ]);
    const byId = new Map(rows.rows.map((r) => [r.id, r]));
    const children = new Map<string | null, CategoryRow[]>();
    for (const r of rows.rows) {
      // Родитель скрыт/удалён → узел не показывается (вместе с поддеревом).
      const parent =
        r.parent_id !== null && byId.has(r.parent_id) ? r.parent_id : r.parent_id === null ? null : undefined;
      if (parent === undefined) continue;
      (children.get(parent) ?? children.set(parent, []).get(parent)!).push(r);
    }
    // Счётчики: кэш поддерева или «в наличии» — сумма по поддереву (сам узел + потомки).
    const count = new Map<string, number>();
    const subtree = (id: string): number => {
      const cached = count.get(id);
      if (cached !== undefined) return cached;
      let n = live ? (live.get(id) ?? 0) : (byId.get(id)?.product_count_cache ?? 0);
      if (live) for (const c of children.get(id) ?? []) n += subtree(c.id);
      count.set(id, n);
      return n;
    };
    if (q.parentId !== undefined && !byId.has(q.parentId)) {
      throw new ProblemException('NOT_FOUND', { detail: 'Категория не найдена.' });
    }
    const build = (parent: string | null, level: number): CategoryNodeDto[] => {
      const out: CategoryNodeDto[] = [];
      for (const r of children.get(parent) ?? []) {
        const productCount = subtree(r.id);
        if (!q.includeEmpty && productCount === 0) continue;
        const kids = (children.get(r.id) ?? []).filter((c) => q.includeEmpty || subtree(c.id) > 0);
        const deeper = q.depth === undefined || level < q.depth;
        const image = imageOf({ sha: r.img_sha });
        out.push({
          id: r.id,
          parentId: r.parent_id,
          name: r.name,
          ...(r.onec_code ? { code: r.onec_code } : {}),
          productCount,
          sortOrder: r.sort_order,
          ...(r.icon_key ? { iconKey: r.icon_key } : {}),
          imageUrl: image ? image.cardUrl : null,
          hasChildren: kids.length > 0,
          deletionMark: false,
          ...(r.onec_ref ? { onecRef: r.onec_ref } : {}),
          ...(deeper && kids.length > 0 ? { children: build(r.id, level + 1) } : {}),
        });
      }
      return out;
    };
    const m = meta.rows[0];
    const asOf = isoOf(latest(m?.ok, m?.synced));
    return {
      items: build(q.parentId ?? null, 1),
      ...(asOf ? { asOf } : {}),
      snapshotVersion: `cat:${isoOf(m?.max_updated) ?? '-'}:${m?.n ?? '0'}`,
    };
  }

  /** Товары с `available > 0` на складе зрителя по категориям (прямое членство). */
  private async inStockCounts(viewer: CatalogViewer): Promise<Map<string, number>> {
    const res = await this.pool.query<{ category_id: string; n: string }>(
      `SELECT p.category_id, count(DISTINCT p.id)::text AS n
         FROM products p
         JOIN product_variants v ON v.product_id = p.id AND NOT v.deletion_mark AND v.is_default = NOT p.has_variants
         JOIN stock_balances b ON b.variant_id = v.id AND b.warehouse_id = $1::uuid AND b.available > 0
        WHERE NOT p.deletion_mark AND p.is_sellable AND p.category_id IS NOT NULL
        GROUP BY p.category_id`,
      [viewer.warehouse?.id ?? null],
    );
    return new Map(res.rows.map((r) => [r.category_id, Number(r.n)]));
  }

  async units(): Promise<{ items: UnitDto[] }> {
    const res = await this.pool.query<{ id: string; code: string; name: string; qty_precision: number }>( // money-double: allow — число знаков после запятой (0…3), не количество
      `SELECT id, code, name, qty_precision FROM units WHERE NOT deletion_mark ORDER BY name, id`,
    );
    return { items: res.rows.map((u) => unitDto(u.id, u.code, u.name, u.qty_precision)) };
  }

  /** Виды цен, видимые роли (`price_lists.visible_to_roles`, 07 §5.26); `customer` сюда не допускается. */
  async priceLists(viewer: CatalogViewer): Promise<{ items: Record<string, unknown>[] }> {
    if (viewer.isCustomer) {
      throw new ProblemException('FORBIDDEN', { detail: 'Справочник видов цен недоступен для вашей роли.' });
    }
    const res = await this.pool.query<{
      id: string;
      name: string;
      onec_code: string | null;
      currency: string;
      is_default: boolean;
      roles: string[];
    }>(
      `SELECT id, name, onec_code, currency, is_default, visible_to_roles::text[] AS roles
         FROM price_lists WHERE NOT deletion_mark AND $1::text = ANY(visible_to_roles::text[])
        ORDER BY sort_order, name, id`,
      [viewer.role],
    );
    return {
      items: res.rows.map((r) => ({
        id: r.id,
        name: r.name,
        ...(r.onec_code ? { code: r.onec_code } : {}),
        currency: 'KGS',
        isDefault: r.is_default,
        visibleToRoles: r.roles,
      })),
    };
  }

  async warehouses(): Promise<{ items: Record<string, unknown>[] }> {
    const res = await this.pool.query<{
      id: string;
      name: string;
      onec_code: string | null;
      is_active: boolean;
      is_default_for_pos: boolean;
    }>(
      `SELECT id, name, onec_code, is_active, is_default_for_pos FROM warehouses
        WHERE NOT deletion_mark ORDER BY sort_order, name, id`,
    );
    return {
      items: res.rows.map((w) => ({
        id: w.id,
        name: w.name,
        ...(w.onec_code ? { code: w.onec_code } : {}),
        isActive: w.is_active,
        isDefaultForPos: w.is_default_for_pos,
      })),
    };
  }
}

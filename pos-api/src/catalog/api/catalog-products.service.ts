import { Inject, Injectable } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../../common/db/database.module.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { CatalogCursorCodec } from '../common/catalog-cursor.js';
import { dec, type ImageDto, imageOf, isoOf, latest, type MoneyDto, moneyOf, qtyOf } from '../common/catalog-format.js';
import { type CatalogSnapshot, CatalogSnapshotService } from '../common/catalog-snapshot.js';
import type { CatalogViewer } from '../common/catalog-viewer.js';
import { availableTotalOf, projectStock, type StockBalanceDto } from '../common/stock-projection.js';
import type { ProductFilters, ProductPageParams, ProductSort } from './product-filters.js';

// ------------------------------------------------------------------ DTO (OpenAPI components/schemas)

export interface UnitDto {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly shortName: string;
  readonly qtyPrecision: number; // money-double: allow — число знаков после запятой (0…3), не количество
}

export interface PriceDto {
  readonly priceListId: string;
  readonly priceListName: string;
  readonly packagingId: string | null;
  readonly price: MoneyDto;
  readonly validFrom?: string;
  readonly asOf?: string;
}

export interface ProductSummaryDto {
  readonly id: string;
  readonly name: string;
  readonly sku?: string;
  readonly categoryId?: string;
  readonly brand?: string;
  readonly hasVariants: boolean;
  readonly defaultVariantId?: string;
  readonly baseUnit: UnitDto;
  readonly primaryImage?: ImageDto;
  readonly price?: PriceDto;
  readonly priceRange?: { readonly min: MoneyDto; readonly max: MoneyDto };
  readonly stock?: StockBalanceDto;
  readonly isFavorite: boolean;
  readonly updatedAt: string;
}

export interface VariantDto {
  readonly id: string;
  readonly productId: string;
  readonly isDefault: boolean;
  readonly name: string;
  readonly sku?: string;
  readonly attributes: Record<string, string>;
  readonly price?: PriceDto;
  readonly stock?: StockBalanceDto;
  readonly stockByWarehouse: StockBalanceDto[];
  readonly barcodes: string[];
  readonly images: ImageDto[];
  readonly multiplicity: string | null;
  readonly sortOrder: number;
  readonly deletionMark: boolean;
}

export interface PackagingDto {
  readonly id: string;
  readonly unitId: string;
  readonly name: string;
  readonly factor: string;
  readonly isDefault: boolean;
  readonly allowFraction: boolean;
  readonly barcode: string | null;
}

export type ProductDto = ProductSummaryDto & {
  readonly description?: string;
  readonly attributes: Record<string, string>;
  readonly images?: ImageDto[];
  readonly variants?: VariantDto[];
  readonly packagings: PackagingDto[];
  readonly barcodes: string[];
  readonly stockByWarehouse?: StockBalanceDto[];
  readonly prices?: PriceDto[];
  readonly availableTotal?: string | null;
  readonly minQuantity: string | null;
  readonly onecCode?: string;
  readonly deletionMark: boolean;
};

export interface AttributeKeyDto {
  readonly key: string;
  readonly name: string;
  readonly values: string[];
}

export interface FacetValueDto {
  readonly value: string;
  readonly count: number;
}

export interface ProductPage {
  readonly items: ProductSummaryDto[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
  readonly totalEstimate: number | null; // money-double: allow — число строк (count), не деньги
  readonly isEstimate: boolean;
  readonly asOf: string | null;
  readonly facets?: {
    readonly brands: FacetValueDto[];
    readonly attrs: Record<string, FacetValueDto[]>;
    readonly priceRange?: { readonly min: MoneyDto; readonly max: MoneyDto };
  };
}

export type CardBlock = 'variants' | 'prices' | 'stockByWarehouse' | 'images';
export const CARD_BLOCKS: readonly CardBlock[] = ['variants', 'prices', 'stockByWarehouse', 'images'];

// ------------------------------------------------------------------ SQL-помощники

/** Накопитель параметров запроса: `$n` по порядку. */
export class SqlParams {
  readonly values: unknown[] = [];
  add(v: unknown): string {
    this.values.push(v);
    return `$${this.values.length}`;
  }
}

type SortAgg = 'price' | 'stock' | 'popularity';

interface SortSpec {
  readonly expr: string;
  readonly dir: 'ASC' | 'DESC';
  readonly cast: 'numeric' | 'text' | 'bigint' | 'timestamptz';
  /** Ключ может отсутствовать (нет цены, снимка остатка, артикула) — такие строки в конце (`NULLS LAST`). */
  readonly nullable: boolean;
  /** Ключ — агрегат по вариантам (считается для всей выборки), иначе — столбец товара (индекс 0006). */
  readonly agg?: SortAgg;
}

/**
 * Ключи сортировки (08 §4.4.2; ядро §19.2): `id` — всегда последний ключ (в направлении сортировки); товары без
 * значения ключа (без цены, без снимка остатка, без артикула) — в конце (`NULLS LAST`).
 */
const SORTS: Readonly<Record<ProductSort, SortSpec>> = {
  'price:asc': { expr: 'pr.pmin', dir: 'ASC', cast: 'numeric', nullable: true, agg: 'price' },
  'price:desc': { expr: 'pr.pmax', dir: 'DESC', cast: 'numeric', nullable: true, agg: 'price' },
  'name:asc': { expr: 'p.name', dir: 'ASC', cast: 'text', nullable: false },
  'name:desc': { expr: 'p.name', dir: 'DESC', cast: 'text', nullable: false },
  // [НЕ ПОДТВЕРЖДЕНО, Q-023]: популярность — число строк заказов POS по товару.
  'popularity:desc': {
    expr: 'COALESCE(pop.n, 0)::bigint',
    dir: 'DESC',
    cast: 'bigint',
    nullable: false,
    agg: 'popularity',
  },
  'updatedAt:desc': { expr: 'p.updated_at', dir: 'DESC', cast: 'timestamptz', nullable: false },
  'available:desc': { expr: 'st.avail', dir: 'DESC', cast: 'numeric', nullable: true, agg: 'stock' },
  'sku:asc': { expr: 'p.sku', dir: 'ASC', cast: 'text', nullable: true },
};

/**
 * Свободный остаток товара — сумма `available` продаваемых вариантов. У товара с характеристиками отрицательный
 * свободный остаток варианта (резерв 1С больше остатка) не вычитается из остатков других вариантов: вариант,
 * который можно продать, не должен давать товару «Нет в наличии» и выпадать из `inStock`/`available:desc`
 * (08 §3.6 — уровень по балансу; 10 INV-022, INV-052; ревью E-api-4). У товара без характеристик — баланс как есть.
 */
export const PRODUCT_AVAILABLE_SUM = (b: string, p: string): string =>
  `sum(CASE WHEN ${p}.has_variants THEN greatest(${b}.available, 0) ELSE ${b}.available END)`;

/** Продаваемые варианты товара: характеристики, если они есть, иначе служебный вариант (EQ-ONEC-07). */
const SELLABLE = (v: string, p: string) => `NOT ${v}.deletion_mark AND ${v}.is_default = NOT ${p}.has_variants`;

/**
 * Условия фильтров `ProductFilters` по товару с псевдонимом `p` (без `deletion_mark`/`is_sellable` — их добавляет
 * вызывающий). Экспорт — для `/search/products` (те же фильтры, RM-E-014).
 */
export function productFilterSql(
  params: SqlParams,
  filters: ProductFilters,
  viewer: Pick<CatalogViewer, 'userId'>,
  p = 'p',
): string[] {
  const where: string[] = [];
  if (filters.categoryId) {
    const cat = params.add(filters.categoryId);
    where.push(
      filters.includeSubcategories
        ? `${p}.category_id IN (SELECT c.id FROM categories c JOIN categories root ON root.id = ${cat}::uuid
             WHERE NOT c.deletion_mark AND (c.id = root.id OR c.path LIKE root.path || '/%'))`
        : `${p}.category_id = ${cat}::uuid`,
    );
  }
  if (filters.brand?.length) where.push(`${p}.brand = ANY(${params.add(filters.brand)}::text[])`);
  if (filters.favorite === true) {
    where.push(
      `EXISTS (SELECT 1 FROM favorites_products fp WHERE fp.user_id = ${params.add(viewer.userId)}::uuid AND fp.product_id = ${p}.id)`,
    );
  }
  if (filters.hasImage === true) {
    where.push(
      `EXISTS (SELECT 1 FROM product_images i WHERE i.product_id = ${p}.id AND i.deleted_at IS NULL AND i.status = 'ready')`,
    );
  }
  for (const [key, value] of Object.entries(filters.attr ?? {})) {
    const k = params.add(key);
    const alts = [`vav.value_text_norm = norm_search(${params.add(value)}::text)`];
    if (/^-?\d+([.,]\d+)?$/.test(value))
      alts.push(`vav.value_number = ${params.add(value.replace(',', '.'))}::numeric`);
    if (/^(true|false|да|нет)$/i.test(value)) {
      alts.push(`vav.value_bool = ${params.add(/^(true|да)$/i.test(value))}::boolean`);
    }
    where.push(
      `EXISTS (SELECT 1 FROM product_variants av
                 JOIN variant_attribute_values vav ON vav.variant_id = av.id
                 JOIN product_attributes pa ON pa.id = vav.attribute_id
                WHERE av.product_id = ${p}.id AND NOT av.deletion_mark AND pa.code = ${k}::text
                  AND (${alts.join(' OR ')}))`,
    );
  }
  return where;
}

// ------------------------------------------------------------------ сервис

interface SummaryRow {
  id: string;
  name: string;
  sku: string | null;
  category_id: string | null;
  brand: string | null;
  has_variants: boolean;
  deletion_mark: boolean;
  updated_at: Date;
  unit_id: string;
  unit_code: string;
  unit_name: string;
  qty_precision: number; // money-double: allow — число знаков после запятой (0…3), не количество
  default_variant_id: string | null;
  img_sha: Buffer | null;
  img_w: number | null;
  img_h: number | null;
  is_favorite: boolean;
  price: string | null;
  price_valid_from: Date | null;
  price_synced: Date | null;
  pmin: string | null;
  pmax: string | null;
  sq: string | null;
  sr: string | null;
  sa: string | null;
  srows: string;
  sat: Date | null;
}

interface WarehouseRow {
  id: string;
  name: string;
}

/**
 * Товары каталога (08 §4.4.2–§4.4.4; RM-E-004, RM-E-014, RM-E-017): список с фильтрами, сортировками и курсором,
 * карточка, варианты. Цена — по виду цены зрителя (`CatalogViewer.priceList`, 08 §3.6), `available` и его суммы
 * считает сервер (D-22), количества для `customer` — по `customer_stock_display` (`projectStock`).
 * Товары с `deletion_mark` в списке не возвращаются; карточка снятого товара — 404 для `customer`, staff получает
 * её с `deletionMark=true`.
 */
@Injectable()
export class CatalogProductsService {
  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    private readonly cursors: CatalogCursorCodec,
    private readonly snapshots: CatalogSnapshotService,
  ) {}

  // ---------------------------------------------------------------- список

  async list(
    viewer: CatalogViewer,
    filters: ProductFilters,
    page: ProductPageParams,
    snapshot?: CatalogSnapshot,
  ): Promise<ProductPage> {
    const snap = snapshot ?? (await this.snapshots.read());
    const sort = SORTS[page.sort];
    const after = page.cursor ? this.cursors.decode(page.cursor, page.sort) : undefined;
    const filterAggs = new Set<SortAgg>();
    if (filters.inStock === true) filterAggs.add('stock');
    if (filters.priceMin !== undefined || filters.priceMax !== undefined) filterAggs.add('price');
    // Сортировка по агрегату считает ключ для всей выборки — тогда и фильтры по цене/остатку берутся из агрегатов;
    // сортировка по столбцу товара идёт по индексу с ранней остановкой на LIMIT — фильтры коррелированные.
    const aggs = sort.agg ? new Set<SortAgg>([sort.agg, ...filterAggs]) : new Set<SortAgg>();
    const params = new SqlParams();
    const base = this.selection(viewer, filters, params, aggs);
    const keyset: string[] = [];
    const cmp = sort.dir === 'ASC' ? '>' : '<';
    if (after) {
      const id = `${params.add(after.id)}::uuid`;
      if (after.s === null) keyset.push(`(${sort.expr} IS NULL AND p.id ${cmp} ${id})`);
      else {
        const row = `(${sort.expr}, p.id) ${cmp} (${params.add(after.s)}::${sort.cast}, ${id})`;
        keyset.push(sort.nullable ? `(${row} OR ${sort.expr} IS NULL)` : row);
      }
    }
    const limit = params.add(page.limit + 1);
    const nulls = sort.nullable ? ' NULLS LAST' : '';
    const sql = `${base.with}
      SELECT p.id, (${sort.expr})::text AS k
        FROM products p ${base.joins}
       WHERE ${[...base.where, ...keyset].join(' AND ')}
       ORDER BY ${sort.expr} ${sort.dir}${nulls}, p.id ${sort.dir}
       LIMIT ${limit}`;
    const res = await this.pool.query<{ id: string; k: string | null }>(sql, params.values);
    const hasMore = res.rows.length > page.limit;
    const rows = hasMore ? res.rows.slice(0, page.limit) : res.rows;
    const [summaries, total, facets] = await Promise.all([
      this.summaries(
        viewer,
        rows.map((r) => r.id),
        { snapshot: snap },
      ),
      // «Найдено: N» — точный счёт на первой странице; на следующих — null (08 §2.5: «только там, где дёшево»).
      after ? Promise.resolve(null) : this.count(viewer, filters, filterAggs),
      after ? Promise.resolve(undefined) : this.facets(viewer, filters),
    ]);
    const last = rows.at(-1);
    return {
      items: rows.map((r) => summaries.get(r.id)).filter((s): s is ProductSummaryDto => s !== undefined),
      nextCursor: hasMore && last ? this.cursors.encode({ o: page.sort, s: last.k, id: last.id }) : null,
      hasMore,
      totalEstimate: total,
      isEstimate: false,
      asOf: isoOf(snap.dataAsOf) ?? null,
      ...(facets ? { facets } : {}),
    };
  }

  private async count(viewer: CatalogViewer, filters: ProductFilters, aggs: ReadonlySet<SortAgg>): Promise<number> {
    const params = new SqlParams();
    const base = this.selection(viewer, filters, params, aggs);
    const res = await this.pool.query<{ n: string }>(
      `${base.with} SELECT count(*)::text AS n FROM products p ${base.joins} WHERE ${base.where.join(' AND ')}`,
      params.values,
    );
    return Number(res.rows[0]?.n ?? 0);
  }

  /**
   * Выборка товаров списка: условия по товару (`productFilterSql`), агрегаты по продаваемым вариантам в CTE
   * (`aggs`: цена вида цены зрителя, `available` на складе зрителя, популярность) и фильтры по цене/наличию —
   * через агрегаты, если они посчитаны, иначе коррелированными подзапросами по строке товара.
   */
  private selection(
    viewer: CatalogViewer,
    filters: ProductFilters,
    params: SqlParams,
    aggs: ReadonlySet<SortAgg>,
  ): { with: string; joins: string; where: string[] } {
    const productWhere = ['NOT p.deletion_mark', 'p.is_sellable', ...productFilterSql(params, filters, viewer)];
    const needPl = aggs.has('price') || filters.priceMin !== undefined || filters.priceMax !== undefined;
    const pl = needPl ? params.add(viewer.canReadPrice ? (viewer.priceList?.id ?? null) : null) : '';
    const wh = aggs.has('stock') || filters.inStock === true ? params.add(viewer.warehouse?.id ?? null) : '';
    const ctes: string[] = [];
    const joins: string[] = [];
    const scope = `FROM products p JOIN product_variants v ON v.product_id = p.id AND ${SELLABLE('v', 'p')}`;
    if (aggs.has('price')) {
      ctes.push(`pr AS (SELECT v.product_id, min(x.price) AS pmin, max(x.price) AS pmax ${scope}
        JOIN prices x ON x.variant_id = v.id AND x.price_list_id = ${pl}::uuid AND x.packaging_id IS NULL
       WHERE ${productWhere.join(' AND ')} GROUP BY v.product_id)`);
      joins.push('LEFT JOIN pr ON pr.product_id = p.id');
    }
    if (aggs.has('stock')) {
      ctes.push(`st AS (SELECT v.product_id, ${PRODUCT_AVAILABLE_SUM('b', 'p')} AS avail ${scope}
        JOIN stock_balances b ON b.variant_id = v.id AND b.warehouse_id = ${wh}::uuid
       WHERE ${productWhere.join(' AND ')} GROUP BY v.product_id)`);
      joins.push('LEFT JOIN st ON st.product_id = p.id');
    }
    if (aggs.has('popularity')) {
      ctes.push(`pop AS (SELECT oi.product_id, count(*) AS n FROM order_items oi GROUP BY oi.product_id)`);
      joins.push('LEFT JOIN pop ON pop.product_id = p.id');
    }
    const where = [...productWhere];
    const priceAgg = (fn: 'min' | 'max') =>
      aggs.has('price')
        ? `pr.p${fn}`
        : `(SELECT ${fn}(x.price) FROM product_variants v JOIN prices x ON x.variant_id = v.id
              AND x.price_list_id = ${pl}::uuid AND x.packaging_id IS NULL
            WHERE v.product_id = p.id AND ${SELLABLE('v', 'p')})`;
    if (filters.priceMin !== undefined) where.push(`${priceAgg('max')} >= ${params.add(filters.priceMin)}::numeric`);
    if (filters.priceMax !== undefined) where.push(`${priceAgg('min')} <= ${params.add(filters.priceMax)}::numeric`);
    if (filters.inStock === true) {
      where.push(
        aggs.has('stock')
          ? 'st.avail > 0'
          : `(SELECT ${PRODUCT_AVAILABLE_SUM('b', 'p')} FROM product_variants v JOIN stock_balances b ON b.variant_id = v.id
               AND b.warehouse_id = ${wh}::uuid WHERE v.product_id = p.id AND ${SELLABLE('v', 'p')}) > 0`,
      );
    }
    return { with: ctes.length ? `WITH ${ctes.join(', ')}` : '', joins: joins.join(' '), where };
  }

  /** Фасеты первой страницы (08 §4.4.2, необязательные): бренды, фильтруемые свойства, диапазон цен. */
  private async facets(viewer: CatalogViewer, filters: ProductFilters): Promise<NonNullable<ProductPage['facets']>> {
    const params = new SqlParams();
    const pl = params.add(viewer.canReadPrice ? (viewer.priceList?.id ?? null) : null);
    const where = ['NOT p.deletion_mark', 'p.is_sellable', ...productFilterSql(params, filters, viewer)];
    const res = await this.pool.query<{ kind: string; key: string | null; value: string | null; n: string | null }>(
      `WITH f AS (SELECT p.id, p.brand, p.has_variants FROM products p WHERE ${where.join(' AND ')})
       SELECT 'brand' AS kind, NULL AS key, f.brand AS value, count(*)::text AS n FROM f WHERE f.brand IS NOT NULL
        GROUP BY f.brand
       UNION ALL
       SELECT 'attr', pa.code, vav.value_text, count(DISTINCT f.id)::text
         FROM f JOIN product_variants v ON v.product_id = f.id AND NOT v.deletion_mark
         JOIN variant_attribute_values vav ON vav.variant_id = v.id AND vav.value_text IS NOT NULL
         JOIN product_attributes pa ON pa.id = vav.attribute_id AND pa.is_filterable AND NOT pa.deletion_mark
        GROUP BY pa.code, vav.value_text
       UNION ALL
       SELECT 'price_min', NULL, min(x.price)::text, NULL
         FROM f JOIN product_variants v ON v.product_id = f.id AND ${SELLABLE('v', 'f')}
         JOIN prices x ON x.variant_id = v.id AND x.price_list_id = ${pl}::uuid AND x.packaging_id IS NULL
       UNION ALL
       SELECT 'price_max', NULL, max(x.price)::text, NULL
         FROM f JOIN product_variants v ON v.product_id = f.id AND ${SELLABLE('v', 'f')}
         JOIN prices x ON x.variant_id = v.id AND x.price_list_id = ${pl}::uuid AND x.packaging_id IS NULL`,
      params.values,
    );
    const brands: FacetValueDto[] = [];
    const attrs: Record<string, FacetValueDto[]> = {};
    let min: string | null = null;
    let max: string | null = null;
    for (const r of res.rows) {
      if (r.kind === 'brand' && r.value !== null) brands.push({ value: r.value, count: Number(r.n) });
      else if (r.kind === 'attr' && r.key !== null && r.value !== null) {
        (attrs[r.key] ??= []).push({ value: r.value, count: Number(r.n) });
      } else if (r.kind === 'price_min') min = r.value;
      else if (r.kind === 'price_max') max = r.value;
    }
    const byCount = (a: FacetValueDto, b: FacetValueDto) => b.count - a.count || (a.value < b.value ? -1 : 1);
    brands.sort(byCount);
    for (const list of Object.values(attrs)) list.sort(byCount);
    return {
      brands,
      attrs,
      ...(min !== null && max !== null ? { priceRange: { min: moneyOf(min), max: moneyOf(max) } } : {}),
    };
  }

  // ---------------------------------------------------------------- краткие карточки (ProductSummary)

  /**
   * `ProductSummary` по id в порядке запроса (для списка, поиска, «Недавних», избранного). Товары с
   * `deletion_mark` возвращаются только при `includeDeleted`.
   */
  async summaries(
    viewer: CatalogViewer,
    ids: readonly string[],
    opts: { readonly includeDeleted?: boolean; readonly snapshot?: CatalogSnapshot } = {},
  ): Promise<Map<string, ProductSummaryDto>> {
    const out = new Map<string, ProductSummaryDto>();
    if (ids.length === 0) return out;
    const snap = opts.snapshot ?? (await this.snapshots.read());
    const rows = await this.summaryRows(viewer, ids, opts.includeDeleted === true);
    for (const r of rows) out.set(r.id, this.summaryOf(viewer, r, snap));
    return out;
  }

  private async summaryRows(
    viewer: CatalogViewer,
    ids: readonly string[],
    includeDeleted: boolean,
  ): Promise<SummaryRow[]> {
    const res = await this.pool.query<SummaryRow>(
      `SELECT p.id, p.name, p.sku, p.category_id, p.brand, p.has_variants, p.deletion_mark, p.updated_at,
              u.id AS unit_id, u.code AS unit_code, u.name AS unit_name, u.qty_precision,
              dv.id AS default_variant_id,
              img.checksum_sha256 AS img_sha, img.width AS img_w, img.height AS img_h,
              EXISTS (SELECT 1 FROM favorites_products fp WHERE fp.user_id = $2::uuid AND fp.product_id = p.id) AS is_favorite,
              prd.price::text AS price, prd.valid_from AS price_valid_from, prd.synced_at AS price_synced,
              prr.pmin::text AS pmin, prr.pmax::text AS pmax,
              st.sq::text AS sq, st.sr::text AS sr, st.sa::text AS sa, st.n::text AS srows, st.at AS sat
         FROM products p
         JOIN units u ON u.id = p.base_unit_id
         LEFT JOIN product_variants dv ON dv.product_id = p.id AND dv.is_default
         LEFT JOIN LATERAL (
           SELECT i.checksum_sha256, i.width, i.height FROM product_images i
            WHERE i.product_id = p.id AND i.variant_id IS NULL AND i.deleted_at IS NULL AND i.status = 'ready'
              AND i.checksum_sha256 IS NOT NULL
            ORDER BY i.is_primary DESC, i.sort_order, i.id LIMIT 1) img ON true
         LEFT JOIN LATERAL (
           SELECT x.price, x.valid_from, x.synced_at FROM prices x
            WHERE NOT p.has_variants AND x.variant_id = dv.id AND x.price_list_id = $3::uuid AND x.packaging_id IS NULL
            LIMIT 1) prd ON true
         LEFT JOIN LATERAL (
           SELECT min(x.price) AS pmin, max(x.price) AS pmax FROM product_variants v
             JOIN prices x ON x.variant_id = v.id AND x.price_list_id = $3::uuid AND x.packaging_id IS NULL
            WHERE v.product_id = p.id AND ${SELLABLE('v', 'p')}) prr ON true
         LEFT JOIN LATERAL (
           SELECT sum(b.quantity) AS sq, sum(b.reserved) AS sr, ${PRODUCT_AVAILABLE_SUM('b', 'p')} AS sa, count(*) AS n,
                  max(b.onec_snapshot_at) AS at
             FROM product_variants v JOIN stock_balances b ON b.variant_id = v.id AND b.warehouse_id = $4::uuid
            WHERE v.product_id = p.id AND ${SELLABLE('v', 'p')}) st ON true
        WHERE p.id = ANY($1::uuid[]) ${includeDeleted ? '' : 'AND NOT p.deletion_mark'}`,
      [ids, viewer.userId, viewer.canReadPrice ? (viewer.priceList?.id ?? null) : null, viewer.warehouse?.id ?? null],
    );
    return res.rows;
  }

  private summaryOf(viewer: CatalogViewer, r: SummaryRow, snap: CatalogSnapshot): ProductSummaryDto {
    const image = imageOf({ sha: r.img_sha, is_primary: true, width: r.img_w, height: r.img_h });
    const price =
      !r.has_variants && r.price !== null && viewer.priceList
        ? this.priceDto(viewer.priceList, null, r.price, r.price_valid_from, latest(r.price_synced, snap.pricesAsOf))
        : undefined;
    const stock =
      viewer.warehouse && r.default_variant_id
        ? projectStock(
            viewer,
            {
              variantId: r.default_variant_id,
              warehouseId: viewer.warehouse.id,
              warehouseName: viewer.warehouse.name,
              unitId: r.unit_id,
            },
            Number(r.srows) > 0 && r.sa !== null
              ? { quantity: r.sq ?? '0', reserved: r.sr ?? '0', available: r.sa, asOf: latest(r.sat, snap.stockAsOf) }
              : null,
          )
        : undefined;
    return {
      id: r.id,
      name: r.name,
      ...(r.sku ? { sku: r.sku } : {}),
      ...(r.category_id ? { categoryId: r.category_id } : {}),
      ...(r.brand ? { brand: r.brand } : {}),
      hasVariants: r.has_variants,
      ...(r.default_variant_id ? { defaultVariantId: r.default_variant_id } : {}),
      baseUnit: unitDto(r.unit_id, r.unit_code, r.unit_name, r.qty_precision),
      ...(image ? { primaryImage: image } : {}),
      ...(price ? { price } : {}),
      ...(r.has_variants && r.pmin !== null && r.pmax !== null && viewer.canReadPrice
        ? { priceRange: { min: moneyOf(r.pmin), max: moneyOf(r.pmax) } }
        : {}),
      ...(stock ? { stock } : {}),
      isFavorite: r.is_favorite,
      updatedAt: r.updated_at.toISOString(),
    };
  }

  private priceDto(
    list: { id: string; name: string },
    packagingId: string | null,
    price: string,
    validFrom: Date | null,
    asOf: Date | undefined,
  ): PriceDto {
    const vf = isoOf(validFrom);
    const at = isoOf(asOf);
    return {
      priceListId: list.id,
      priceListName: list.name,
      packagingId,
      price: moneyOf(price),
      ...(vf ? { validFrom: vf } : {}),
      ...(at ? { asOf: at } : {}),
    };
  }

  // ---------------------------------------------------------------- карточка

  async card(
    viewer: CatalogViewer,
    productId: string,
    include: ReadonlySet<CardBlock>,
    snapshot?: CatalogSnapshot,
  ): Promise<ProductDto> {
    const snap = snapshot ?? (await this.snapshots.read());
    const [row] = await this.summaryRows(viewer, [productId], !viewer.isCustomer);
    if (!row) throw new ProblemException('NOT_FOUND', { detail: 'Товар не найден.' });
    const summary = this.summaryOf(viewer, row, snap);
    const ext = await this.pool.query<{
      description: string | null;
      attributes: Record<string, { name?: string; value?: unknown }> | null;
      onec_code: string | null;
      multiplicity: string | null;
      min_qty: string | null;
    }>(
      `SELECT description, attributes, onec_code, multiplicity::text AS multiplicity, min_qty::text AS min_qty
         FROM products WHERE id = $1::uuid`,
      [productId],
    );
    const p = ext.rows[0];
    const warehouses = await this.activeWarehouses();
    const [variants, packagings, barcodes, images, prices, stockRows] = await Promise.all([
      include.has('variants') ? this.variantRows(viewer, row, p.multiplicity, warehouses, snap, false) : undefined,
      this.packagings(productId),
      this.pool.query<{ value: string }>(
        `SELECT value FROM barcodes WHERE product_id = $1::uuid AND NOT deletion_mark ORDER BY value`,
        [productId],
      ),
      include.has('images') ? this.images(productId, null) : undefined,
      include.has('prices') && viewer.canReadAllPrices && !row.has_variants && row.default_variant_id
        ? this.allPrices(viewer, row.default_variant_id, snap)
        : undefined,
      this.productStockByWarehouse(row),
    ]);
    const byWh = new Map(stockRows.map((s) => [s.warehouse_id, s]));
    const stockByWarehouse = row.default_variant_id
      ? warehouses.map((w) => {
          const s = byWh.get(w.id);
          return projectStock(
            viewer,
            {
              variantId: row.default_variant_id as string,
              warehouseId: w.id,
              warehouseName: w.name,
              unitId: row.unit_id,
            },
            s ? { quantity: s.q, reserved: s.r, available: s.a, asOf: latest(s.at, snap.stockAsOf) } : null,
          );
        })
      : [];
    // Product.availableTotal — Σ available по активным складам (складам роли; в R1 ограничений по складам нет).
    const total = stockRows.length > 0 ? stockRows.reduce((acc, s) => acc.plus(s.a), dec(0)).toFixed(3) : null;
    const attributes: Record<string, string> = {};
    for (const a of Object.values(p.attributes ?? {})) {
      const text = scalarText(a?.value);
      if (a && typeof a.name === 'string' && text !== undefined) attributes[a.name] = text;
    }
    return {
      ...summary,
      ...(p.description ? { description: p.description } : {}),
      attributes,
      ...(images ? { images } : {}),
      ...(variants ? { variants } : {}),
      packagings,
      barcodes: barcodes.rows.map((b) => b.value),
      ...(include.has('stockByWarehouse') ? { stockByWarehouse } : {}),
      ...(prices ? { prices } : {}),
      ...availableTotalOf(viewer, total),
      minQuantity: p.min_qty !== null ? qtyOf(p.min_qty) : null,
      ...(p.onec_code ? { onecCode: p.onec_code } : {}),
      deletionMark: row.deletion_mark,
    };
  }

  // ---------------------------------------------------------------- варианты

  async variants(
    viewer: CatalogViewer,
    productId: string,
    inStockOnly: boolean,
    snapshot?: CatalogSnapshot,
  ): Promise<{ items: VariantDto[]; attributeKeys: AttributeKeyDto[]; asOf: string | null }> {
    const snap = snapshot ?? (await this.snapshots.read());
    const [row] = await this.summaryRows(viewer, [productId], !viewer.isCustomer);
    if (!row) throw new ProblemException('NOT_FOUND', { detail: 'Товар не найден.' });
    const ext = await this.pool.query<{ multiplicity: string | null }>(
      `SELECT multiplicity::text AS multiplicity FROM products WHERE id = $1::uuid`,
      [productId],
    );
    const warehouses = await this.activeWarehouses();
    let items = await this.variantRows(viewer, row, ext.rows[0]?.multiplicity ?? null, warehouses, snap, true);
    if (inStockOnly) items = items.filter((v) => v.inStock);
    const keys = await this.attributeKeys(items.map((v) => v.dto));
    return { items: items.map((v) => v.dto), attributeKeys: keys, asOf: isoOf(snap.dataAsOf) ?? null };
  }

  private async variantRows(
    viewer: CatalogViewer,
    product: SummaryRow,
    multiplicity: string | null,
    warehouses: readonly WarehouseRow[],
    snap: CatalogSnapshot,
    withFlags: true,
  ): Promise<{ dto: VariantDto; inStock: boolean }[]>;
  private async variantRows(
    viewer: CatalogViewer,
    product: SummaryRow,
    multiplicity: string | null,
    warehouses: readonly WarehouseRow[],
    snap: CatalogSnapshot,
    withFlags: false,
  ): Promise<VariantDto[]>;
  private async variantRows(
    viewer: CatalogViewer,
    product: SummaryRow,
    multiplicity: string | null,
    warehouses: readonly WarehouseRow[],
    snap: CatalogSnapshot,
    withFlags: boolean,
  ): Promise<VariantDto[] | { dto: VariantDto; inStock: boolean }[]> {
    const res = await this.pool.query<{
      id: string;
      is_default: boolean;
      name: string;
      sku: string | null;
      attributes: Record<string, unknown> | null;
      sort_order: number;
      deletion_mark: boolean;
      price: string | null;
      valid_from: Date | null;
      price_synced: Date | null;
    }>(
      `SELECT v.id, v.is_default, v.name, v.sku, v.attributes, v.sort_order, v.deletion_mark,
              x.price::text AS price, x.valid_from, x.synced_at AS price_synced
         FROM product_variants v
         JOIN products p ON p.id = v.product_id
         LEFT JOIN prices x ON x.variant_id = v.id AND x.price_list_id = $2::uuid AND x.packaging_id IS NULL
        WHERE v.product_id = $1::uuid AND ${SELLABLE('v', 'p')}
        ORDER BY v.sort_order, v.name, v.id`,
      [product.id, viewer.canReadPrice ? (viewer.priceList?.id ?? null) : null],
    );
    const ids = res.rows.map((r) => r.id);
    const [stock, barcodes, images] = await Promise.all([
      this.pool.query<{ variant_id: string; warehouse_id: string; q: string; r: string; a: string; at: Date }>(
        `SELECT variant_id, warehouse_id, quantity::text AS q, reserved::text AS r, available::text AS a,
                onec_snapshot_at AS at
           FROM stock_balances WHERE variant_id = ANY($1::uuid[])`,
        [ids],
      ),
      this.pool.query<{ variant_id: string; value: string }>(
        `SELECT variant_id, value FROM barcodes
          WHERE variant_id = ANY($1::uuid[]) AND packaging_id IS NULL AND NOT deletion_mark ORDER BY value`,
        [ids],
      ),
      this.pool.query<{
        variant_id: string;
        sha: Buffer;
        is_primary: boolean;
        width: number | null;
        height: number | null;
      }>(
        `SELECT variant_id, checksum_sha256 AS sha, is_primary, width, height FROM product_images
          WHERE variant_id = ANY($1::uuid[]) AND deleted_at IS NULL AND status = 'ready' AND checksum_sha256 IS NOT NULL
          ORDER BY is_primary DESC, sort_order, id`,
        [ids],
      ),
    ]);
    const stockOf = new Map<string, (typeof stock.rows)[number]>();
    for (const s of stock.rows) stockOf.set(`${s.variant_id}|${s.warehouse_id}`, s);
    const group = <T extends { variant_id: string }>(rows: readonly T[]) => {
      const m = new Map<string, T[]>();
      for (const r of rows) (m.get(r.variant_id) ?? m.set(r.variant_id, []).get(r.variant_id)!).push(r);
      return m;
    };
    const bc = group(barcodes.rows);
    const im = group(images.rows);
    const mult = multiplicity !== null ? qtyOf(multiplicity) : null;
    const out = res.rows.map((v) => {
      const figures = (whId: string) => {
        const s = stockOf.get(`${v.id}|${whId}`);
        return s ? { quantity: s.q, reserved: s.r, available: s.a, asOf: latest(s.at, snap.stockAsOf) } : null;
      };
      const key = (w: WarehouseRow) => ({
        variantId: v.id,
        warehouseId: w.id,
        warehouseName: w.name,
        unitId: product.unit_id,
      });
      const here = viewer.warehouse ? figures(viewer.warehouse.id) : null;
      const attributes: Record<string, string> = {};
      for (const [k, val] of Object.entries(v.attributes ?? {})) {
        const text = scalarText(val);
        if (text !== undefined) attributes[k] = text;
      }
      const dto: VariantDto = {
        id: v.id,
        productId: product.id,
        isDefault: v.is_default,
        name: v.name !== '' ? v.name : product.name,
        ...(v.sku ? { sku: v.sku } : v.is_default && product.sku ? { sku: product.sku } : {}),
        attributes,
        ...(v.price !== null && viewer.priceList
          ? {
              price: this.priceDto(
                viewer.priceList,
                null,
                v.price,
                v.valid_from,
                latest(v.price_synced, snap.pricesAsOf),
              ),
            }
          : {}),
        ...(viewer.warehouse ? { stock: projectStock(viewer, key(viewer.warehouse), here) } : {}),
        stockByWarehouse: warehouses.map((w) => projectStock(viewer, key(w), figures(w.id))),
        barcodes: (bc.get(v.id) ?? []).map((b) => b.value),
        images: (im.get(v.id) ?? [])
          .map((i) => imageOf({ sha: i.sha, is_primary: i.is_primary, width: i.width, height: i.height }))
          .filter((i): i is ImageDto => i !== undefined),
        multiplicity: mult,
        sortOrder: v.sort_order,
        deletionMark: v.deletion_mark,
      };
      return { dto, inStock: here !== null && dec(here.available).gt(0) };
    });
    return withFlags ? out : out.map((o) => o.dto);
  }

  /** Оси выбора варианта (08 §4.4.4): коды свойств характеристик, значения — в порядке вариантов. */
  private async attributeKeys(variants: readonly VariantDto[]): Promise<AttributeKeyDto[]> {
    const order: string[] = [];
    const values = new Map<string, string[]>();
    for (const v of variants) {
      if (v.isDefault) continue;
      for (const [k, val] of Object.entries(v.attributes)) {
        if (!values.has(k)) {
          values.set(k, []);
          order.push(k);
        }
        const list = values.get(k)!;
        if (!list.includes(val)) list.push(val);
      }
    }
    if (order.length === 0) return [];
    const res = await this.pool.query<{ code: string; name: string }>(
      `SELECT code, name FROM product_attributes WHERE code = ANY($1::text[])`,
      [order],
    );
    const names = new Map(res.rows.map((r) => [r.code, r.name]));
    return order.map((k) => ({ key: k, name: names.get(k) ?? k, values: values.get(k) ?? [] }));
  }

  // ---------------------------------------------------------------- блоки карточки

  async activeWarehouses(): Promise<WarehouseRow[]> {
    const res = await this.pool.query<WarehouseRow>(
      `SELECT id, name FROM warehouses WHERE is_active AND NOT deletion_mark ORDER BY sort_order, name, id`,
    );
    return res.rows;
  }

  private async productStockByWarehouse(
    product: SummaryRow,
  ): Promise<{ warehouse_id: string; q: string; r: string; a: string; at: Date }[]> {
    const res = await this.pool.query<{ warehouse_id: string; q: string; r: string; a: string; at: Date }>(
      `SELECT b.warehouse_id, sum(b.quantity)::text AS q, sum(b.reserved)::text AS r,
              (${PRODUCT_AVAILABLE_SUM('b', 'p')})::text AS a,
              max(b.onec_snapshot_at) AS at
         FROM product_variants v
         JOIN products p ON p.id = v.product_id
         JOIN stock_balances b ON b.variant_id = v.id
         JOIN warehouses w ON w.id = b.warehouse_id AND w.is_active AND NOT w.deletion_mark
        WHERE v.product_id = $1::uuid AND ${SELLABLE('v', 'p')}
        GROUP BY b.warehouse_id`,
      [product.id],
    );
    return res.rows;
  }

  private async packagings(productId: string): Promise<PackagingDto[]> {
    const res = await this.pool.query<{
      id: string;
      unit_id: string;
      name: string;
      factor: string;
      is_default: boolean;
      allow_fraction: boolean;
      barcode: string | null;
    }>(
      `SELECT k.id, k.unit_id, k.name, k.factor::text AS factor, k.is_default, k.allow_fraction,
              (SELECT b.value FROM barcodes b WHERE b.packaging_id = k.id AND NOT b.deletion_mark ORDER BY b.value LIMIT 1) AS barcode
         FROM packagings k WHERE k.product_id = $1::uuid AND NOT k.deletion_mark
        ORDER BY k.sort_order, k.factor, k.id`,
      [productId],
    );
    return res.rows.map((k) => ({
      id: k.id,
      unitId: k.unit_id,
      name: k.name,
      factor: qtyOf(k.factor),
      isDefault: k.is_default,
      allowFraction: k.allow_fraction,
      barcode: k.barcode,
    }));
  }

  private async images(productId: string, variantId: string | null): Promise<ImageDto[]> {
    const res = await this.pool.query<{
      sha: Buffer;
      is_primary: boolean;
      width: number | null;
      height: number | null;
    }>(
      `SELECT checksum_sha256 AS sha, is_primary, width, height FROM product_images
        WHERE product_id = $1::uuid AND variant_id IS NOT DISTINCT FROM $2::uuid AND deleted_at IS NULL
          AND status = 'ready' AND checksum_sha256 IS NOT NULL
        ORDER BY is_primary DESC, sort_order, id`,
      [productId, variantId],
    );
    return res.rows
      .map((i) => imageOf({ sha: i.sha, is_primary: i.is_primary, width: i.width, height: i.height }))
      .filter((i): i is ImageDto => i !== undefined);
  }

  /** `prices[]` всех видов цен, видимых роли (`price_lists.visible_to_roles`), — только `catalog.prices.read.all`. */
  private async allPrices(viewer: CatalogViewer, variantId: string, snap: CatalogSnapshot): Promise<PriceDto[]> {
    const res = await this.pool.query<{
      list_id: string;
      list_name: string;
      packaging_id: string | null;
      price: string;
      valid_from: Date | null;
      synced_at: Date;
    }>(
      `SELECT pl.id AS list_id, pl.name AS list_name, x.packaging_id, x.price::text AS price, x.valid_from, x.synced_at
         FROM prices x
         JOIN price_lists pl ON pl.id = x.price_list_id AND NOT pl.deletion_mark
          AND $2::text = ANY(pl.visible_to_roles::text[])
         LEFT JOIN packagings k ON k.id = x.packaging_id
        WHERE x.variant_id = $1::uuid AND (x.packaging_id IS NULL OR NOT k.deletion_mark)
        ORDER BY pl.sort_order, pl.name, pl.id, x.packaging_id NULLS FIRST`,
      [variantId, viewer.role],
    );
    return res.rows.map((r) =>
      this.priceDto(
        { id: r.list_id, name: r.list_name },
        r.packaging_id,
        r.price,
        r.valid_from,
        latest(r.synced_at, snap.pricesAsOf),
      ),
    );
  }
}

/** Значение свойства строкой (строка/число/логическое); пустое и составное — нет значения. */
function scalarText(v: unknown): string | undefined {
  if (typeof v === 'string') return v.trim() === '' ? undefined : v;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  return undefined;
}

/** `precision` — число знаков после запятой единицы (0…3), не количество. */
export function unitDto(id: string, code: string, name: string, precision: number): UnitDto {
  return { id, code, name, shortName: name, qtyPrecision: precision };
}

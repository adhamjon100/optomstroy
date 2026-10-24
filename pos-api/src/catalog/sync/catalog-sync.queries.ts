import type pg from 'pg';
import { tsText } from './catalog-sync.horizon.js';
import type { SyncPosition } from './catalog-sync.cursor.js';
import type { CatalogSyncEntity } from './catalog-sync.types.js';

/**
 * SQL страниц `GET /catalog/sync/{entity}` (08 §4.24): keyset по `(updated_at, <ключ>)` по возрастанию до горизонта
 * (`catalog-sync.horizon.ts`), индексы `(updated_at, id)` — миграция 0007. Каждая строка несёт `__ts` (метка курсора с
 * микросекундами), `__k0`/`__k1` (ключ) и `__live` (`false` — строка уходит в `deleted[]`). Производные поля
 * (штрихкоды товара, фото, вариант по умолчанию) вычисляются во внешнем запросе только для строк страницы —
 * коррелированными подзапросами по индексам (без hash join по всей таблице).
 */
export interface SyncRow {
  readonly __ts: string;
  readonly __k0: string;
  readonly __k1?: string;
  readonly __live: boolean;
  readonly [column: string]: unknown;
}

export interface PageQuery {
  readonly entity: CatalogSyncEntity;
  readonly position?: SyncPosition;
  readonly horizon: string;
  /** Строк к выборке (limit + 1 — признак `hasMore`). */
  readonly fetch: number;
  /** Запрос с `since` (инкремент): ставшие невидимыми роли виды цен уходят в `deleted[]`. */
  readonly hasSince: boolean;
  /** Виды цен, разрешённые роли (`prices`, `price_lists`). */
  readonly priceListIds: readonly string[];
  /** `priceListIds` — все строки `price_lists` (в т. ч. помеченные на удаление): фильтр цен не нужен. */
  readonly allPriceLists?: boolean;
  /** Склад (`stock`, параметр `warehouseId`). */
  readonly warehouseId?: string;
}

/** Длина ключа после `updated_at` (для курсора). */
export function keyLengthOf(entity: CatalogSyncEntity): number {
  return entity === 'stock' ? 2 : 1;
}

class Params {
  readonly values: unknown[] = [];
  add(v: unknown, cast: string): string {
    this.values.push(v);
    return `$${this.values.length}::${cast}`;
  }
}

interface StreamSpec {
  readonly from: string;
  readonly ts: string;
  readonly keys: readonly string[];
  readonly where?: readonly string[];
  readonly live: string;
  readonly cols: string;
}

function inner(p: Params, s: StreamSpec, q: PageQuery): string {
  const where = [...(s.where ?? []), `${s.ts} < ${p.add(q.horizon, 'timestamptz')}`];
  if (q.position) {
    const keys = q.position.key.map((k) => p.add(k, 'uuid'));
    where.push(`(${s.ts}, ${s.keys.join(', ')}) > (${p.add(q.position.ts, 'timestamptz')}, ${keys.join(', ')})`);
  }
  const keyCols = s.keys.map((k, i) => `${k}::text AS __k${i}`).join(', ');
  return `SELECT ${s.cols}, ${tsText(s.ts)} AS __ts, ${keyCols}, (${s.live}) AS __live
            FROM ${s.from}
           WHERE ${where.join(' AND ')}
           ORDER BY ${s.ts}, ${s.keys.join(', ')}
           LIMIT ${p.add(q.fetch, 'int')}`;
}

function order(keys: number): string {
  const k = keys === 2 ? ', s.__k1 COLLATE "C"' : '';
  return `ORDER BY s.__ts COLLATE "C", s.__k0 COLLATE "C"${k}`;
}

async function run(db: Pick<pg.Pool, 'query'>, p: Params, sql: string): Promise<SyncRow[]> {
  return (await db.query<SyncRow>(sql, p.values)).rows;
}

/** Слияние двух упорядоченных потоков (строки таблицы + журнал удалений) по `(__ts, __k0)`. */
function merge(a: readonly SyncRow[], b: readonly SyncRow[], fetch: number): SyncRow[] {
  const out: SyncRow[] = [];
  let i = 0;
  let j = 0;
  while (out.length < fetch && (i < a.length || j < b.length)) {
    if (j >= b.length) out.push(a[i++]);
    else if (i >= a.length) out.push(b[j++]);
    else {
      const x = a[i];
      const y = b[j];
      const before = x.__ts < y.__ts || (x.__ts === y.__ts && x.__k0 <= y.__k0);
      out.push(before ? a[i++] : b[j++]);
    }
  }
  return out;
}

const deletions = (entity: 'prices' | 'images', extraWhere: readonly string[]): StreamSpec => ({
  from: 'catalog_sync.deletions t',
  ts: 't.deleted_at',
  keys: ['t.id'],
  where: [`t.entity = '${entity}'`, ...extraWhere],
  live: 'false',
  cols: 't.id',
});

/** Страница сущности: строки (`limit + 1`) в порядке курсора. */
export async function fetchSyncPage(db: Pick<pg.Pool, 'query'>, q: PageQuery): Promise<SyncRow[]> {
  const p = new Params();
  switch (q.entity) {
    case 'units':
      return run(
        db,
        p,
        inner(
          p,
          {
            from: 'units t',
            ts: 't.updated_at',
            keys: ['t.id'],
            live: 'NOT t.deletion_mark',
            cols: 't.id, t.code, t.name, t.qty_precision',
          },
          q,
        ),
      );
    case 'warehouses':
      return run(
        db,
        p,
        inner(
          p,
          {
            from: 'warehouses t',
            ts: 't.updated_at',
            keys: ['t.id'],
            live: 'NOT t.deletion_mark',
            cols: 't.id, t.name, t.short_name, t.onec_code, t.is_active, t.is_default_for_pos, t.allow_sales, t.sort_order',
          },
          q,
        ),
      );
    case 'categories': {
      const sql = inner(
        p,
        {
          from: 'categories t',
          ts: 't.updated_at',
          keys: ['t.id'],
          live: 'NOT t.deletion_mark',
          cols: `t.id, t.parent_id, t.name, t.onec_code, t.onec_ref, t.product_count_cache, t.sort_order, t.icon_key,
                 t.image_id, t.path, t.depth, t.is_visible, t.updated_at`,
        },
        q,
      );
      return run(
        db,
        p,
        `SELECT s.*,
                EXISTS (SELECT 1 FROM categories c WHERE c.parent_id = s.id AND NOT c.deletion_mark) AS has_children,
                (SELECT encode(pi.checksum_sha256, 'hex') FROM product_images pi
                  WHERE pi.id = s.image_id AND pi.deleted_at IS NULL AND pi.status = 'ready') AS image_sha
           FROM (${sql}) s ${order(1)}`,
      );
    }
    case 'products': {
      const sql = inner(
        p,
        {
          from: 'products t',
          ts: 't.updated_at',
          keys: ['t.id'],
          live: 'NOT t.deletion_mark',
          cols: `t.id, t.name, t.sku, t.category_id, t.brand, t.has_variants, t.description, t.attributes,
                 t.min_qty::text AS min_qty, t.multiplicity::text AS multiplicity, t.is_sellable, t.onec_code,
                 t.base_unit_id, t.updated_at`,
        },
        q,
      );
      return run(
        db,
        p,
        `SELECT s.*, u.code AS unit_code, u.name AS unit_name, u.qty_precision,
                (SELECT v.id FROM product_variants v WHERE v.product_id = s.id AND v.is_default
                  ORDER BY v.id LIMIT 1) AS default_variant_id,
                coalesce((SELECT (array_agg(b.value ORDER BY b.value))[1:100] FROM barcodes b
                           WHERE b.product_id = s.id AND NOT b.deletion_mark), '{}') AS barcodes,
                coalesce((SELECT (array_agg(pi.id::text ORDER BY pi.is_primary DESC, pi.sort_order, pi.id))[1:50]
                            FROM product_images pi
                           WHERE pi.product_id = s.id AND pi.deleted_at IS NULL AND pi.status = 'ready'
                             AND pi.checksum_sha256 IS NOT NULL), '{}') AS image_ids
           FROM (${sql}) s JOIN units u ON u.id = s.base_unit_id ${order(1)}`,
      );
    }
    case 'variants': {
      const sql = inner(
        p,
        {
          from: 'product_variants t',
          ts: 't.updated_at',
          keys: ['t.id'],
          live: 'NOT t.deletion_mark',
          cols: 't.id, t.product_id, t.is_default, t.name, t.sku, t.attributes, t.sort_order',
        },
        q,
      );
      return run(
        db,
        p,
        `SELECT s.*, pr.multiplicity::text AS multiplicity, pr.base_unit_id,
                coalesce((SELECT (array_agg(b.value ORDER BY b.value))[1:100] FROM barcodes b
                           WHERE b.variant_id = s.id AND NOT b.deletion_mark), '{}') AS barcodes
           FROM (${sql}) s
           JOIN LATERAL (SELECT x.multiplicity, x.base_unit_id FROM products x WHERE x.id = s.product_id OFFSET 0) pr
             ON true ${order(1)}`,
      );
    }
    case 'packagings': {
      const sql = inner(
        p,
        {
          from: 'packagings t',
          ts: 't.updated_at',
          keys: ['t.id'],
          where: ['t.product_id IS NOT NULL'],
          live: 'NOT t.deletion_mark',
          cols: `t.id, t.product_id, t.unit_id, t.name, t.factor::text AS factor, t.allow_fraction, t.is_default,
                 t.sort_order`,
        },
        q,
      );
      return run(
        db,
        p,
        // Служебный вариант — по частичному индексу `product_variants_default_uq`, запасной — `product_variants_product_idx`.
        `SELECT s.*,
                coalesce(
                  (SELECT v.id FROM product_variants v WHERE v.product_id = s.product_id AND v.is_default LIMIT 1),
                  (SELECT v.id FROM product_variants v WHERE v.product_id = s.product_id AND NOT v.deletion_mark
                    ORDER BY v.id LIMIT 1)) AS variant_id,
                (SELECT (array_agg(b.value ORDER BY b.value))[1] FROM barcodes b
                  WHERE b.packaging_id = s.id AND NOT b.deletion_mark) AS barcode
           FROM (${sql}) s ${order(1)}`,
      );
    }
    case 'barcodes':
      return run(
        db,
        p,
        inner(
          p,
          {
            from: 'barcodes t',
            ts: 't.updated_at',
            keys: ['t.id'],
            live: 'NOT t.deletion_mark',
            cols: 't.id, t.value, t.product_id, t.variant_id, t.packaging_id, t.type::text AS type',
          },
          q,
        ),
      );
    case 'price_lists': {
      const ids = p.add(q.priceListIds, 'uuid[]');
      const where = q.hasSince ? [] : [`t.id = ANY(${ids})`];
      return run(
        db,
        p,
        inner(
          p,
          {
            from: 'price_lists t',
            ts: 't.updated_at',
            keys: ['t.id'],
            where,
            live: `NOT t.deletion_mark AND t.id = ANY(${ids})`,
            cols: `t.id, t.name, t.onec_code, t.currency, t.is_default, t.visible_to_roles::text[] AS visible_to_roles,
                   t.sort_order`,
          },
          q,
        ),
      );
    }
    case 'prices': {
      const live = new Params();
      const liveSql = inner(
        live,
        {
          from: 'prices t',
          ts: 't.updated_at',
          keys: ['t.id'],
          // Все виды цен видимы роли → без фильтра: упорядоченный обход `(updated_at, id)` с LIMIT (с фильтром по
          // `price_list_id` планировщик без свежей статистики выбирает BitmapAnd по всей таблице и сортировку).
          where: q.allPriceLists ? [] : [`t.price_list_id = ANY(${live.add(q.priceListIds, 'uuid[]')})`],
          live: 'true',
          cols: `t.id, t.variant_id, t.price_list_id, t.packaging_id, t.price::text AS price, t.valid_from, t.synced_at`,
        },
        q,
      );
      const gone = new Params();
      const goneIds = gone.add(q.priceListIds, 'uuid[]');
      const goneSql = inner(gone, deletions('prices', [`t.price_list_id = ANY(${goneIds})`]), q);
      const [a, b] = await Promise.all([
        run(
          db,
          live,
          `SELECT s.*, pl.name AS price_list_name FROM (${liveSql}) s
             JOIN price_lists pl ON pl.id = s.price_list_id ${order(1)}`,
        ),
        run(db, gone, goneSql),
      ]);
      return merge(a, b, q.fetch);
    }
    case 'stock': {
      // Склады выгрузки — активные неудалённые (или `warehouseId`). Если это все склады, фильтр не ставится:
      // упорядоченный обход индекса `(updated_at, variant_id, warehouse_id)` с LIMIT без соединения в keyset-запросе
      // (с соединением/фильтром планировщик без свежей статистики сортирует весь срез остатков).
      const wh = (
        await db.query<{ ids: string[]; all_wh: boolean }>(
          `SELECT coalesce(array_agg(id::text) FILTER (WHERE is_active AND NOT deletion_mark
                                                       AND ($1::uuid IS NULL OR id = $1::uuid)), '{}') AS ids,
                  bool_and(is_active AND NOT deletion_mark AND ($1::uuid IS NULL OR id = $1::uuid)) AS all_wh
             FROM warehouses`,
          [q.warehouseId ?? null],
        )
      ).rows[0];
      if (!wh || wh.ids.length === 0) return [];
      const where = wh.all_wh ? [] : [`t.warehouse_id = ANY(${p.add(wh.ids, 'uuid[]')})`];
      const sql = inner(
        p,
        {
          from: 'stock_balances t',
          ts: 't.updated_at',
          keys: ['t.variant_id', 't.warehouse_id'],
          where,
          live: 'true',
          cols: `t.variant_id, t.warehouse_id, t.quantity::text AS quantity, t.reserved::text AS reserved,
                 t.available::text AS available, t.onec_snapshot_at`,
        },
        q,
      );
      return run(
        db,
        p,
        `SELECT s.*,
                (SELECT w.name FROM warehouses w WHERE w.id = s.warehouse_id) AS warehouse_name,
                (SELECT x.base_unit_id FROM product_variants v JOIN products x ON x.id = v.product_id
                  WHERE v.id = s.variant_id) AS unit_id
           FROM (${sql}) s ${order(2)}`,
      );
    }
    case 'attributes': {
      // Момент изменения свойства — наибольший из `product_attributes.updated_at` и `updated_at` его значений
      // (07 §5.19: значения — производная таблица; новые значения меняют `values[]`). Свойств — десятки строк.
      const sql = inner(
        p,
        {
          from: `(SELECT pa.id, pa.code, pa.name, pa.value_type::text AS value_type, pa.unit_label, pa.is_filterable,
                         pa.is_variant_axis, pa.sort_order, pa.deletion_mark,
                         greatest(pa.updated_at, (SELECT max(v.updated_at) FROM variant_attribute_values v
                                                   WHERE v.attribute_id = pa.id)) AS updated_at
                    FROM product_attributes pa) t`,
          ts: 't.updated_at',
          keys: ['t.id'],
          live: 'NOT t.deletion_mark',
          cols: 't.id, t.code, t.name, t.value_type, t.unit_label, t.is_filterable, t.is_variant_axis, t.sort_order',
        },
        q,
      );
      return run(
        db,
        p,
        `SELECT s.*,
                ARRAY(SELECT x FROM (SELECT DISTINCT coalesce(v.value_text, trim_scale(v.value_number)::text,
                                                              v.value_bool::text) AS x
                                       FROM variant_attribute_values v WHERE v.attribute_id = s.id) d
                       WHERE x IS NOT NULL ORDER BY x LIMIT 500) AS attr_values
           FROM (${sql}) s ${order(1)}`,
      );
    }
    case 'images': {
      const live = new Params();
      const liveSql = inner(
        live,
        {
          from: 'product_images t',
          ts: 't.updated_at',
          keys: ['t.id'],
          where: ['t.product_id IS NOT NULL'],
          live: `t.deleted_at IS NULL AND t.status = 'ready' AND t.checksum_sha256 IS NOT NULL`,
          cols: `t.id, t.product_id, t.variant_id, encode(t.checksum_sha256, 'hex') AS sha, t.is_primary, t.width,
                 t.height, t.sort_order`,
        },
        q,
      );
      const gone = new Params();
      const goneSql = inner(gone, deletions('images', []), q);
      const [a, b] = await Promise.all([run(db, live, liveSql), run(db, gone, goneSql)]);
      return merge(a, b, q.fetch);
    }
  }
}

import type pg from 'pg';
import type { ApplyState } from './catalog-applier.js';

/**
 * Производные поля каталога после применения (в той же транзакции):
 * - `categories.path`/`depth` — materialized path из `id` предков, «пересчитывается sync-воркером после upsert всех
 *   групп» (07 §5.15); глубина ≤ 10 (CHECK);
 * - `products.category_path_text` — «Сантехника / Смесители» для FTS веса C (07 §5.16, §10);
 * - `products.has_variants` — есть ли живые характеристики (07 §5.16);
 * - `categories.product_count_cache` — активные продаваемые товары поддерева, «пересчёт после каждого sync products»
 *   (07 §5.15, DATA-114).
 * Обновляются только изменившиеся значения (`IS DISTINCT FROM`), чтобы не сдвигать `updated_at` зря.
 */
export async function refreshCatalogDerived(
  client: Pick<pg.PoolClient, 'query'>,
  state: ApplyState,
  options: { counters?: boolean } = {},
): Promise<void> {
  const { dirty } = state;
  const countersNeeded = dirty.counters || dirty.categories || dirty.products.size > 0;
  if (dirty.categories) {
    await client.query(
      `WITH RECURSIVE t AS (
         SELECT id, '/' || id::text AS path, 0 AS depth FROM categories WHERE parent_id IS NULL
         UNION ALL
         SELECT c.id, t.path || '/' || c.id::text, t.depth + 1 FROM categories c JOIN t ON c.parent_id = t.id WHERE t.depth < 10)
       UPDATE categories c SET path = t.path, depth = t.depth FROM t
        WHERE c.id = t.id AND (c.path IS DISTINCT FROM t.path OR c.depth IS DISTINCT FROM t.depth)`,
    );
  }
  if (dirty.categories || dirty.products.size > 0) {
    const onlyIds = dirty.categories ? null : [...dirty.products];
    await client.query(
      `WITH cp AS (
         SELECT c.id, string_agg(a.name, ' / ' ORDER BY a.depth) AS txt
           FROM categories c JOIN categories a ON (c.path = a.path OR c.path LIKE a.path || '/%')
          GROUP BY c.id)
       UPDATE products p SET category_path_text = cp.txt FROM cp
        WHERE p.category_id = cp.id AND p.category_path_text IS DISTINCT FROM cp.txt
          AND ($1::uuid[] IS NULL OR p.id = ANY($1::uuid[]))`,
      [onlyIds],
    );
    await client.query(
      `UPDATE products SET category_path_text = NULL
        WHERE category_id IS NULL AND category_path_text IS NOT NULL AND ($1::uuid[] IS NULL OR id = ANY($1::uuid[]))`,
      [onlyIds],
    );
  }
  const owners = new Set([...dirty.variantOwners, ...dirty.products]);
  if (owners.size > 0) {
    await client.query(
      `UPDATE products p SET has_variants = x.hv
         FROM (SELECT p2.id, EXISTS (SELECT 1 FROM product_variants v
                                      WHERE v.product_id = p2.id AND NOT v.is_default AND NOT v.deletion_mark) AS hv
                 FROM products p2 WHERE p2.id = ANY($1::uuid[])) x
        WHERE p.id = x.id AND p.has_variants IS DISTINCT FROM x.hv`,
      [[...owners]],
    );
  }
  if (countersNeeded && options.counters === false) {
    // Полная загрузка: счётчики — один раз в конце прогона, а не на каждой странице.
    dirty.counters = true;
  } else if (countersNeeded) {
    dirty.counters = false;
    await client.query(
      `WITH direct AS (
         SELECT category_id, count(*)::int AS n FROM products
          WHERE NOT deletion_mark AND is_sellable AND category_id IS NOT NULL GROUP BY category_id),
       tot AS (
         SELECT c.id, coalesce(sum(d.n), 0)::int AS n
           FROM categories c
           LEFT JOIN categories s ON (s.path = c.path OR s.path LIKE c.path || '/%') AND NOT s.deletion_mark
           LEFT JOIN direct d ON d.category_id = s.id
          GROUP BY c.id)
       UPDATE categories c SET product_count_cache = tot.n FROM tot
        WHERE c.id = tot.id AND c.product_count_cache IS DISTINCT FROM tot.n`,
    );
  }
  dirty.categories = false;
  dirty.products.clear();
  dirty.variantOwners.clear();
}

-- 0006_catalog_sort_indexes.sql — индексы сортировок списка товаров `GET /catalog/products` (RM-E-004, RM-E-014;
-- 08 §4.4.2, ядро §19.2). Keyset-пагинация «ключ, id» по столбцам товара идёт по индексу с ранней остановкой на
-- LIMIT вместо сортировки всей выборки (на 50 000 SKU).
--
-- Состав (частичные — та же выборка, что у списка: товары без deletion_mark и продаваемые):
--   1. `products (name, id)` — `sort=name:asc` / `name:desc` (обратный проход индекса);
--   2. `products (sku, id)` — `sort=sku:asc` (NULLS LAST — порядок по умолчанию для ASC).
-- `sort=updatedAt:desc` использует `products_updated_at_id_idx (updated_at, id)` из 0007_catalog_sync.sql;
-- `price:*`, `available:desc`, `popularity:desc` — агрегаты по вариантам, считаются для всей выборки.
--
-- Expand-only (forward-only, 07 §13): только новые индексы. Идемпотентно: CREATE INDEX IF NOT EXISTS — повторное
-- применение даёт 0 изменений (tools/pg/run-sql.mjs --repeat-strict).

BEGIN;

CREATE INDEX IF NOT EXISTS products_catalog_name_id_idx
  ON products (name, id) WHERE NOT deletion_mark AND is_sellable;

CREATE INDEX IF NOT EXISTS products_catalog_sku_id_idx
  ON products (sku, id) WHERE NOT deletion_mark AND is_sellable;

COMMIT;

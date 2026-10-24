-- 0007_catalog_sync.sql — офлайн-API каталога `GET /catalog/sync/{entity}` (RM-E-015; 08 §4.24, ядро §22.7).
--
-- 1. Индексы keyset-выгрузки `(updated_at, id)` для 12 сущностей (курсор монотонен по `(updated_at, id)`, 08 §4.24):
--    существующие индексы `(updated_at)` 0001 упорядочивают только по времени — при пакетной загрузке тысячи строк
--    получают один `updated_at`, и сравнение строк `(updated_at, id) > ($1, $2)` без второго столбца дочитывает
--    и сортирует всю группу. У `prices` и `stock_balances` индекса по `updated_at` не было совсем.
-- 2. Журнал физических удалений `catalog_sync.deletions` для `deleted[]` (08 §4.24: «исчезнувших из среза после
--    `since`»): `prices` — производная таблица-срез с физическим удалением (07 DATA-006, DATA-126), без журнала
--    удалённая цена не попала бы в `deleted[]` офлайн-кэша. Запись — statement-триггером AFTER DELETE (код sync/apply
--    не меняется); `product_images` — страховка на случай физического удаления (по 07 — `deleted_at`).
--    Срок хранения — 31 день (08 §4.24: курсор старше 30 дней → 409 `cursor_expired`; +1 день запаса на долгие
--    транзакции применения). Очистка — тем же триггером.
--    Отдельная схема `catalog_sync`, а не `public`: в `public` ровно 64 таблицы 07 §5 (scripts/check_tables.sql,
--    migrations/NOTES.md §1 п. 1); таблица — служебная проекция API, вопрос владельцу 07 — EQ-CSYNC-01
--    (docs/stages/E_spec_questions.md).
--
-- Expand-only, идемпотентно (IF NOT EXISTS / CREATE OR REPLACE): повторное применение — 0 изменений.

BEGIN;

-- 1. Индексы keyset-выгрузки.
CREATE INDEX IF NOT EXISTS units_updated_at_id_idx ON units (updated_at, id);
CREATE INDEX IF NOT EXISTS warehouses_updated_at_id_idx ON warehouses (updated_at, id);
CREATE INDEX IF NOT EXISTS categories_updated_at_id_idx ON categories (updated_at, id);
CREATE INDEX IF NOT EXISTS products_updated_at_id_idx ON products (updated_at, id);
CREATE INDEX IF NOT EXISTS product_variants_updated_at_id_idx ON product_variants (updated_at, id);
CREATE INDEX IF NOT EXISTS product_attributes_updated_at_id_idx ON product_attributes (updated_at, id);
CREATE INDEX IF NOT EXISTS packagings_updated_at_id_idx ON packagings (updated_at, id);
CREATE INDEX IF NOT EXISTS barcodes_updated_at_id_idx ON barcodes (updated_at, id);
CREATE INDEX IF NOT EXISTS price_lists_updated_at_id_idx ON price_lists (updated_at, id);
CREATE INDEX IF NOT EXISTS prices_updated_at_id_idx ON prices (updated_at, id);
CREATE INDEX IF NOT EXISTS product_images_updated_at_id_idx ON product_images (updated_at, id);
CREATE INDEX IF NOT EXISTS stock_balances_updated_at_key_idx ON stock_balances (updated_at, variant_id, warehouse_id);
-- `attributes.values[]` и момент изменения свойства — по значениям характеристик (max(updated_at) на свойство).
CREATE INDEX IF NOT EXISTS variant_attribute_values_attr_updated_idx ON variant_attribute_values (attribute_id, updated_at);

-- 2. Журнал физических удалений.
CREATE SCHEMA IF NOT EXISTS catalog_sync;

CREATE TABLE IF NOT EXISTS catalog_sync.deletions (
  entity              text NOT NULL CONSTRAINT deletions_entity_chk CHECK (entity IN ('prices', 'images')),
  id                  uuid NOT NULL,
  price_list_id       uuid,
  product_id          uuid,
  deleted_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (entity, id)
);
CREATE INDEX IF NOT EXISTS deletions_entity_deleted_idx ON catalog_sync.deletions (entity, deleted_at, id);
CREATE INDEX IF NOT EXISTS deletions_deleted_at_idx ON catalog_sync.deletions (deleted_at);

-- deleted_at = now() (начало транзакции) — та же шкала, что updated_at строк (set_updated_at, DATA-002): горизонт
-- выгрузки (src/catalog/sync/catalog-sync.horizon.ts) одинаково защищает строки и записи об удалении.
CREATE OR REPLACE FUNCTION catalog_sync.log_prices_deleted() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  INSERT INTO catalog_sync.deletions AS d (entity, id, price_list_id, product_id, deleted_at)
  SELECT 'prices', o.id, o.price_list_id, NULL, now() FROM old_rows o
  ON CONFLICT (entity, id) DO UPDATE SET deleted_at = EXCLUDED.deleted_at, price_list_id = EXCLUDED.price_list_id;
  DELETE FROM catalog_sync.deletions WHERE deleted_at < now() - interval '31 days';
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION catalog_sync.log_images_deleted() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  INSERT INTO catalog_sync.deletions AS d (entity, id, price_list_id, product_id, deleted_at)
  SELECT 'images', o.id, NULL, o.product_id, now() FROM old_rows o WHERE o.product_id IS NOT NULL
  ON CONFLICT (entity, id) DO UPDATE SET deleted_at = EXCLUDED.deleted_at, product_id = EXCLUDED.product_id;
  DELETE FROM catalog_sync.deletions WHERE deleted_at < now() - interval '31 days';
  RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER trg_prices_catalog_sync_deleted
  AFTER DELETE ON prices REFERENCING OLD TABLE AS old_rows
  FOR EACH STATEMENT EXECUTE FUNCTION catalog_sync.log_prices_deleted();

CREATE OR REPLACE TRIGGER trg_product_images_catalog_sync_deleted
  AFTER DELETE ON product_images REFERENCING OLD TABLE AS old_rows
  FOR EACH STATEMENT EXECUTE FUNCTION catalog_sync.log_images_deleted();

-- Права (как у public в 0001 §11): pos_app пишет через триггер от своего имени, чтение — readonly/backup.
GRANT USAGE ON SCHEMA catalog_sync TO pos_app, pos_readonly, pos_backup;
GRANT SELECT, INSERT, UPDATE, DELETE ON catalog_sync.deletions TO pos_app;
GRANT SELECT ON catalog_sync.deletions TO pos_readonly, pos_backup;
GRANT EXECUTE ON FUNCTION catalog_sync.log_prices_deleted(), catalog_sync.log_images_deleted() TO pos_app;

COMMIT;

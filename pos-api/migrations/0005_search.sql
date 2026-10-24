-- 0005_search.sql — объекты поиска товаров RM-E-005 (D-31; 07 §10.2–§10.3; NFR-PERF-001).
--
-- Основание. В 0001_init.sql уже есть всё, что 07 §10.1–§10.2 требует для поиска: расширения pg_trgm/unaccent,
-- IMMUTABLE-функции norm_search/norm_sku/immutable_unaccent, конфигурация FTS public.ru_unaccent, generated-столбцы
-- products.name_norm/sku_norm/search_vector, product_variants.name_norm/sku_norm, GIN (search_vector), GIN
-- gin_trgm_ops (name_norm) и B-tree text_pattern_ops (sku_norm). Эта миграция добавляет то, что понадобилось
-- реализации алгоритма D-31 (src/catalog/search):
--   1. products.sku_norm, GIN gin_trgm_ops — ступень «триграммы» для артикула с опечаткой («SB1WJ» → «SB-1WH»).
--      Артикула нет в name_norm, а B-tree text_pattern_ops поддерживает только префикс.
--   2. product_variants.sku_norm, GIN gin_trgm_ops — то же для артикула характеристики.
--   3. products.name_norm, B-tree COLLATE "C" (частичный: продаваемые и не помеченные на удаление) — префикс
--      названия для GET /search/suggest. 07 §10.3 разрешает добавить его expand-миграцией, «если EXPLAIN покажет
--      необходимость». Побайтовый порядок "C" даёт и диапазон для LIKE 'смес%', и готовый порядок для
--      ORDER BY … LIMIT 10. Без него подсказка «смес» читает через GIN и сортирует ~10 % каталога.
--   4. search_words — словарь слов названий продаваемых товаров (materialized view) с GIN gin_trgm_ops.
--      Ступень «триграммы» сначала исправляет по нему слова запроса («смиситель» → «смеситель», это же
--      suggestedQuery 08 §4.5.1), затем ищет исправленный запрос по search_vector. Сравнивать с каждым названием
--      (word_similarity по ~3 000 названиям смесителей на 50 000 SKU) стоит ~80 мс на запрос, сравнение со
--      словарём — единицы мс (docs/perf/E_search_benchmark.md; EQ-SRCH-10, EQ-SRCH-14).
--      Обновление: refresh_search_words() — SECURITY DEFINER от владельца (роль миграций), EXECUTE выдан pos_app.
--      Её вызывает SearchService не чаще раза в минуту и только после изменения products. Внутри —
--      REFRESH … CONCURRENTLY под advisory-lock: несколько реплик API не обновляют словарь одновременно, чтение
--      во время обновления не блокируется.
--
-- Expand-only (forward-only, 07 §13): только новые индексы, представление и функция. Данные и столбцы не меняются,
-- старый код работает. Идемпотентно: CREATE … IF NOT EXISTS / CREATE OR REPLACE; права выдаются повторно без
-- изменений. Повторное применение даёт 0 изменений (tools/pg/run-sql.mjs --repeat-strict). На 50 000 SKU индексы
-- строятся за доли секунды. CONCURRENTLY при создании индексов не используется: файл выполняется в транзакции
-- мигратора, как 0001/0003.

BEGIN;

CREATE INDEX IF NOT EXISTS products_sku_norm_trgm
  ON products USING GIN (sku_norm gin_trgm_ops) WITH (fastupdate = off);

CREATE INDEX IF NOT EXISTS product_variants_sku_norm_trgm
  ON product_variants USING GIN (sku_norm gin_trgm_ops) WITH (fastupdate = off);

CREATE INDEX IF NOT EXISTS products_name_norm_prefix_idx
  ON products (name_norm COLLATE "C") WHERE NOT deletion_mark AND is_sellable;

-- Словарь слов названий: слово ≥ 3 символов, не число; freq — число товаров со словом (для выбора исправления).
CREATE MATERIALIZED VIEW IF NOT EXISTS search_words AS
  SELECT w.word, count(*)::integer AS freq
    FROM products p
   CROSS JOIN LATERAL regexp_split_to_table(p.name_norm, ' ') AS w(word)
   WHERE NOT p.deletion_mark AND p.is_sellable AND length(w.word) >= 3 AND w.word !~ '^[0-9]+$'
   GROUP BY w.word
  WITH DATA;

-- UNIQUE — обязательное условие REFRESH MATERIALIZED VIEW CONCURRENTLY.
CREATE UNIQUE INDEX IF NOT EXISTS search_words_word_uq ON search_words (word);
CREATE INDEX IF NOT EXISTS search_words_word_trgm ON search_words USING GIN (word gin_trgm_ops);

CREATE OR REPLACE FUNCTION refresh_search_words() RETURNS boolean
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  -- Одна реплика за раз; остальные пропускают обновление (false), чтение словаря не блокируется.
  IF NOT pg_try_advisory_xact_lock(hashtext('search_words.refresh')) THEN
    RETURN false;
  END IF;
  REFRESH MATERIALIZED VIEW CONCURRENTLY search_words;
  RETURN true;
END $$;

REVOKE ALL ON FUNCTION refresh_search_words() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION refresh_search_words() TO pos_app;
-- Права как у таблиц схемы (0001: GRANT … ON ALL TABLES IN SCHEMA public — включает и materialized view):
-- изменить словарь pos_app всё равно не может (запись в materialized view невозможна), только refresh_search_words().
GRANT SELECT, INSERT, UPDATE, DELETE ON search_words TO pos_app;
GRANT SELECT ON search_words TO pos_readonly, pos_backup;

COMMIT;

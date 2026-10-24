-- 0019_onec_sync_main_image_auth_pause.sql — синхронизация с 1С: главная картинка товара и пауза чтения после
-- отказа авторизации (разбор расхождений контракт ↔ 18 ↔ 05 ↔ реализация, docs/integration/onec_api/98_triage.md
-- пп. 14 и 89).
--
-- 1. `products.onec_image_file_ref` — `imageFileRef` элемента `Catalog_Номенклатура` (`ФайлКартинки_Key`, контракт
--    `NomenclatureChange.imageFileRef`; ТЗ для 1С 5.4): главным фото товара становится этот файл, если он
--    присоединён к этому же товару; иначе — по `sort_order` (как раньше). NULL — 1С поле не заполнила.
-- 2. `product_images.onec_is_main` — предложение `ImageFileChange.isMain` (`x-status: proposed`, вопрос 32 ТЗ):
--    признак главного файла от 1С; NULL — признак не передан (OData-список и 1С без поля его не меняют).
-- 3. `sync_node_state.auth_error_at` — момент последнего отказа авторизации 1С (401/403) при чтении (05 §6.5,
--    ТЗ А.1): задания чтения не обращаются к 1С 15 минут после него. `last_error_code` остаётся словарным
--    (`ONEC_REJECTED`), отдельного кода не вводится.
--
-- Expand-only (07 §13): nullable-столбцы без значения по умолчанию, существующие строки не меняются.
-- Идемпотентно (IF NOT EXISTS): повторное применение — 0 изменений.

BEGIN;

ALTER TABLE products ADD COLUMN IF NOT EXISTS onec_image_file_ref uuid;
ALTER TABLE product_images ADD COLUMN IF NOT EXISTS onec_is_main boolean;
ALTER TABLE sync_node_state ADD COLUMN IF NOT EXISTS auth_error_at timestamptz;

COMMIT;

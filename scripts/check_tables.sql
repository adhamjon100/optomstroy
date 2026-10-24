-- scripts/check_tables.sql — RM-B-005, проверка п. 2 (13_IMPLEMENTATION_ROADMAP §3.2):
-- в схеме public ровно 64 таблицы по списку 07_DATA_MODEL §5 = 56 таблиц ядра R0 §6 (включая опциональную
-- print_jobs) + 7 таблиц ядра §17.3 + sync_node_state (ядро §22.8). Дополнительно — 45 enum-типов 07 §6.1.
--
-- dev_outbox (07 §5.63) создаётся только в сеансе миграции с app.env IN ('dev','test') (B-AR-09, отказ закрыт).
-- Поэтому проверка зависит от того же параметра сеанса: dev/test — 64 таблицы, включая dev_outbox; иначе
-- (prod/staging, параметр не задан) — 63 таблицы и dev_outbox ОБЯЗАН отсутствовать (AC-DATA-169).
--
-- Запуск: node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql --check scripts/check_tables.sql
--         node tools/pg/run-sql.mjs pos-api/migrations/0001_init.sql --check scripts/check_tables.sql   (prod-режим: 63)
--     или PGOPTIONS='-c app.env=test' psql -v ON_ERROR_STOP=1 -f scripts/check_tables.sql (после применения миграции)
-- Результат: таблица расхождений (status = missing | extra) и итоговая сводка; при любом расхождении —
-- RAISE EXCEPTION (код выхода ≠ 0).

CREATE TEMP TABLE expected_tables (table_name text PRIMARY KEY, domain text NOT NULL, card text NOT NULL) ON COMMIT PRESERVE ROWS;
INSERT INTO expected_tables (table_name, domain, card) VALUES
  -- auth (07 §5.A) — 15
  ('users',                     'auth',     '5.1'),
  ('user_profiles',             'auth',     '5.2'),
  ('user_invitations',          'auth',     '5.3'),
  ('roles',                     'auth',     '5.4'),
  ('permissions',               'auth',     '5.5'),
  ('role_permissions',          'auth',     '5.6'),
  ('user_roles',                'auth',     '5.7'),
  ('devices',                   'auth',     '5.8'),
  ('sessions',                  'auth',     '5.9'),
  ('token_denylist',            'auth',     '5.10 (ядро §17.3)'),
  ('otp_challenges',            'auth',     '5.11'),
  ('rate_limit_counters',       'auth',     '5.12'),
  ('app_pins',                  'auth',     '5.13'),
  ('consents',                  'auth',     '5.14'),
  ('integration_tokens',        'auth',     '5.62 (ядро §17.3)'),
  -- catalog (07 §5.B) — 13
  ('categories',                'catalog',  '5.15'),
  ('products',                  'catalog',  '5.16'),
  ('product_variants',          'catalog',  '5.17'),
  ('product_attributes',        'catalog',  '5.18'),
  ('variant_attribute_values',  'catalog',  '5.19'),
  ('units',                     'catalog',  '5.20'),
  ('packagings',                'catalog',  '5.21'),
  ('barcodes',                  'catalog',  '5.22'),
  ('product_images',            'catalog',  '5.23'),
  ('warehouses',                'catalog',  '5.24'),
  ('stock_balances',            'catalog',  '5.25'),
  ('price_lists',               'catalog',  '5.26'),
  ('prices',                    'catalog',  '5.27'),
  -- customers/finance (07 §5.C) — 7
  ('customers',                 'customers','5.28'),
  ('customer_contacts',         'customers','5.29'),
  ('customer_links',            'customers','5.30'),
  ('receivables',               'customers','5.31'),
  ('receivable_documents',      'customers','5.32'),
  ('discount_rules',            'customers','5.33'),
  ('role_discount_limits',      'customers','5.34'),
  -- sales (07 §5.D) — 15
  ('carts',                     'sales',    '5.35'),
  ('cart_items',                'sales',    '5.36'),
  ('orders',                    'sales',    '5.37'),
  ('order_items',               'sales',    '5.38'),
  ('order_status_history',      'sales',    '5.39'),
  ('payments',                  'sales',    '5.40'),
  ('payment_webhook_events',    'sales',    '5.41 (ядро §17.3, условно Q-014)'),
  ('shipments',                 'sales',    '5.42 (ядро §17.3)'),
  ('shipment_items',            'sales',    '5.43 (ядро §17.3)'),
  ('transactions',              'sales',    '5.44'),
  ('return_requests',           'sales',    '5.45'),
  ('return_request_items',      'sales',    '5.46'),
  ('favorites_products',        'sales',    '5.47'),
  ('favorites_customers',       'sales',    '5.48'),
  ('recent_products',           'sales',    '5.49'),
  -- sync/audit/служебные (07 §5.E) — 14
  ('notifications',             'sync',     '5.50'),
  ('sync_runs',                 'sync',     '5.51'),
  ('sync_state',                'sync',     '5.52'),
  ('sync_errors',               'sync',     '5.53'),
  ('sync_entity_versions',      'sync',     '5.54'),
  ('onec_outbox',               'sync',     '5.55'),
  ('idempotency_keys',          'sync',     '5.56'),
  ('audit_logs',                'sync',     '5.57'),
  ('audit_anchors',             'sync',     '5.58 (ядро §17.3)'),
  ('app_settings',              'sync',     '5.59'),
  ('print_jobs',                'sync',     '5.60 (опционально)'),
  ('sms_outbox',                'sync',     '5.61'),
  ('dev_outbox',                'sync',     '5.63 (ядро §17.3, только dev/test)'),
  ('sync_node_state',           'sync',     '5.64 (ядро §22.8)');

-- Вне dev/test dev_outbox не ожидается (и не должен существовать) — B-AR-09, AC-DATA-169
CREATE TEMP TABLE check_mode ON COMMIT PRESERVE ROWS AS
  SELECT coalesce(current_setting('app.env', true), '') IN ('dev', 'test') AS dev_schema,
         coalesce(NULLIF(current_setting('app.env', true), ''), '<не задан>') AS app_env;
DELETE FROM expected_tables WHERE table_name = 'dev_outbox' AND NOT (SELECT dev_schema FROM check_mode);
SELECT app_env, dev_schema, CASE WHEN dev_schema THEN 64 ELSE 63 END AS expected_total FROM check_mode;

CREATE TEMP VIEW actual_tables AS
  SELECT c.relname::text AS table_name
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p');

-- Расхождения (пусто — всё совпало)
SELECT 'missing' AS status, e.table_name, e.domain, e.card
  FROM expected_tables e WHERE e.table_name NOT IN (SELECT table_name FROM actual_tables)
UNION ALL
SELECT 'extra', a.table_name, NULL, NULL
  FROM actual_tables a WHERE a.table_name NOT IN (SELECT table_name FROM expected_tables)
ORDER BY 1, 2;

-- Сводка по доменам
SELECT e.domain, count(*) AS expected, count(a.table_name) AS present
  FROM expected_tables e LEFT JOIN actual_tables a USING (table_name)
 GROUP BY e.domain ORDER BY e.domain;

SELECT (SELECT count(*) FROM expected_tables) AS expected_tables,
       (SELECT count(*) FROM actual_tables)   AS actual_tables;

DO $$
DECLARE v_expected int; v_actual int; v_missing text; v_extra text; v_dev boolean; v_total int;
BEGIN
  SELECT dev_schema INTO v_dev FROM check_mode;
  v_total := CASE WHEN v_dev THEN 64 ELSE 63 END;
  SELECT count(*) INTO v_expected FROM expected_tables;
  SELECT count(*) INTO v_actual FROM actual_tables;
  SELECT string_agg(table_name, ', ' ORDER BY table_name) INTO v_missing
    FROM expected_tables WHERE table_name NOT IN (SELECT table_name FROM actual_tables);
  SELECT string_agg(table_name, ', ' ORDER BY table_name) INTO v_extra
    FROM actual_tables WHERE table_name NOT IN (SELECT table_name FROM expected_tables);
  IF v_expected <> v_total THEN
    RAISE EXCEPTION 'check_tables: список ожидаемых таблиц содержит % строк вместо %', v_expected, v_total;
  END IF;
  IF v_missing IS NOT NULL OR v_extra IS NOT NULL OR v_actual <> v_total THEN
    RAISE EXCEPTION 'check_tables: найдено % таблиц из %; нет: [%]; лишние: [%]',
      v_actual, v_total, coalesce(v_missing, ''), coalesce(v_extra, '');
  END IF;
  IF NOT v_dev AND to_regclass('public.dev_outbox') IS NOT NULL THEN
    RAISE EXCEPTION 'check_tables: dev_outbox есть в схеме без app.env dev/test (AC-DATA-169)';
  END IF;
  RAISE NOTICE 'check_tables: OK — % из % таблиц, лишних нет (%)', v_actual, v_total,
    CASE WHEN v_dev THEN 'dev/test-схема, dev_outbox есть' ELSE 'prod-схема, dev_outbox нет' END;
END $$;

-- Enum-ы 07 §6.1: ровно 45 типов (имена; значения сверяет scripts/check_enums.py с contracts/enums.json)
CREATE TEMP TABLE expected_enums (type_name text PRIMARY KEY) ON COMMIT PRESERVE ROWS;
INSERT INTO expected_enums VALUES
  ('user_kind'), ('user_status'), ('role_code'), ('customer_link_status'), ('cart_status'), ('order_status'),
  ('delivery_method'), ('receiver_kind'), ('payment_method'), ('payment_status'), ('return_request_status'),
  ('transaction_kind'), ('sync_entity'), ('sync_mode'), ('sync_run_status'), ('outbox_status'), ('notification_kind'),
  ('invitation_status'), ('device_platform'), ('session_kind'), ('step_up_method'), ('otp_purpose'), ('otp_status'),
  ('consent_kind'), ('attribute_value_type'), ('barcode_type'), ('image_status'), ('customer_source'),
  ('customer_type'), ('customer_onec_status'), ('contact_kind'), ('link_match_method'), ('discount_source'),
  ('discount_kind'), ('status_change_source'), ('transaction_source'), ('return_reason'), ('sync_trigger'),
  ('outbox_aggregate'), ('idempotency_status'), ('audit_level'), ('print_document_kind'), ('print_job_status'),
  ('sms_status'), ('onec_sync_state');

SELECT CASE WHEN e.type_name IS NULL THEN 'extra' ELSE 'missing' END AS status,
       coalesce(e.type_name, t.typname::text) AS type_name
  FROM expected_enums e
  FULL JOIN (SELECT t.typname FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
              WHERE n.nspname = 'public' AND t.typtype = 'e') t ON t.typname = e.type_name
 WHERE e.type_name IS NULL OR t.typname IS NULL
 ORDER BY 1, 2;

DO $$
DECLARE v_expected int; v_actual int; v_diff text;
BEGIN
  SELECT count(*) INTO v_expected FROM expected_enums;
  SELECT count(*) INTO v_actual FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
   WHERE n.nspname = 'public' AND t.typtype = 'e';
  SELECT string_agg(coalesce(e.type_name, t.typname::text), ', ') INTO v_diff
    FROM expected_enums e
    FULL JOIN (SELECT t.typname FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                WHERE n.nspname = 'public' AND t.typtype = 'e') t ON t.typname = e.type_name
   WHERE e.type_name IS NULL OR t.typname IS NULL;
  IF v_expected <> 45 OR v_actual <> 45 OR v_diff IS NOT NULL THEN
    RAISE EXCEPTION 'check_tables: enum-типов % (ожидается 45); расхождения: [%]', v_actual, coalesce(v_diff, '');
  END IF;
  RAISE NOTICE 'check_tables: OK — 45 из 45 enum-типов 07 §6.1';
END $$;

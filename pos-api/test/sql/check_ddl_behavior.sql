-- =====================================================================================================
-- pos-api/test/sql/check_ddl_behavior.sql (до RM-C-006 — scripts/) — поведенческие (негативные и позитивные) проверки DDL
-- всех pos-api/migrations/*.sql (0001_init.sql + 0002 и следующие; режим «Планшет магазина» — 0021/0022, раздел 6;
-- вход по лицу — 0024, раздел 7).
--
-- B-AR-10 (б) (docs/reviews/B_architecture_review.md): перенос в репозиторий scratch-проверок RM-B-005
-- (pos-api/migrations/NOTES.md §9) и проверки исправлений B-AR-01, B-AR-03, B-AR-05, B-AR-09, B-AR-19, B-AR-20.
-- Каждый негативный сценарий — pg_temp.expect_error(sql, метка): ожидается отказ CHECK/UNIQUE/FK/триггера;
-- pg_temp.expect_constraint(sql, ограничение, метка) — отказ именно этого ограничения (раздел 6, T-KIOSK-025);
-- если отказа нет — RAISE EXCEPTION (код выхода раннера 1). Позитивные инварианты — DO-блоки с RAISE.
-- В конце — сводка числа сценариев; файл ничего не оставляет «наполовину»: ошибка = падение проверки.
--
-- Запуск (одноразовый кластер, схема dev/test — нужна для проверки dev_outbox; миграции — все, по порядку имён):
--   node tools/pg/run-sql.mjs --set app.env=test <pos-api/migrations/*.sql по порядку> \
--        pos-api/db/migrations-dev/0001_dev_outbox.sql --check pos-api/test/sql/check_ddl_behavior.sql
-- С RM-C-006 п. 7 файл лежит в pos-api/test/sql/ (ранее scripts/) и запускается в CI (contracts-lint, RM-C-011) и в
-- npm run test:db (test/db/ddl-behavior.db-spec.ts); dev_outbox создаёт dev-миграция db/migrations-dev/ (C-MJ-05).
-- Данные — вымышленные (UUID вида 00000000-0000-7000-8000-…, телефоны +99670000000x).
-- =====================================================================================================

CREATE TEMP TABLE ddl_check_log (n serial, label text NOT NULL, outcome text NOT NULL) ON COMMIT PRESERVE ROWS;

-- helper: ожидается ошибка; результат пишется в ddl_check_log
CREATE OR REPLACE FUNCTION pg_temp.expect_error(p_sql text, p_label text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN others THEN
    v := p_label || ': rejected (' || SQLSTATE || ') ' || left(SQLERRM, 90);
    INSERT INTO ddl_check_log (label, outcome) VALUES (p_label, 'rejected ' || SQLSTATE);
    RETURN v;
  END;
  RAISE EXCEPTION 'EXPECTED ERROR NOT RAISED: %', p_label;
END $$;

-- helper: позитивная проверка (условие обязано быть истинным)
CREATE OR REPLACE FUNCTION pg_temp.expect_true(p_cond boolean, p_label text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'EXPECTED TRUE: %', p_label; END IF;
  INSERT INTO ddl_check_log (label, outcome) VALUES (p_label, 'ok');
  RETURN p_label || ': ok';
END $$;

-- helper: ожидается отказ ИМЕННО указанного ограничения (CHECK/UNIQUE/FK; имя — GET STACKED DIAGNOSTICS
-- CONSTRAINT_NAME): строка не должна «случайно» отклоняться соседним ограничением (T-KIOSK-025 — CHECK канала)
CREATE OR REPLACE FUNCTION pg_temp.expect_constraint(p_sql text, p_constraint text, p_label text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_con text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
    IF v_con IS DISTINCT FROM p_constraint THEN
      RAISE EXCEPTION 'WRONG REJECTION: % — ожидался отказ %, получен % (%) %',
        p_label, p_constraint, coalesce(NULLIF(v_con, ''), '<без ограничения>'), SQLSTATE, left(SQLERRM, 120);
    END IF;
    INSERT INTO ddl_check_log (label, outcome) VALUES (p_label, 'rejected ' || SQLSTATE);
    RETURN p_label || ': rejected (' || SQLSTATE || ') ' || v_con;
  END;
  RAISE EXCEPTION 'EXPECTED ERROR NOT RAISED: %', p_label;
END $$;

-- =====================================================================================================
-- 1. Структура (FK, типы, права ролей БД)
-- =====================================================================================================
SELECT count(*) AS cascade_fks FROM pg_constraint WHERE contype = 'f' AND confdeltype = 'c'
  AND connamespace = 'public'::regnamespace;
SELECT count(*) AS restrict_fks FROM pg_constraint WHERE contype = 'f' AND confdeltype = 'r' AND confupdtype = 'r'
  AND connamespace = 'public'::regnamespace;
SELECT count(*) AS non_restrict_non_cascade FROM pg_constraint WHERE contype = 'f' AND confdeltype NOT IN ('r','c')
  AND connamespace = 'public'::regnamespace;
SELECT table_name, column_name, data_type FROM information_schema.columns
 WHERE table_schema = 'public' AND data_type IN ('real','double precision','money','timestamp without time zone');
SELECT count(*) AS onec_ref_partial_uq FROM pg_indexes WHERE schemaname='public' AND indexname LIKE '%onec_ref_uq';
SELECT c.relname AS table_without_pk FROM pg_class c WHERE c.relnamespace='public'::regnamespace AND c.relkind='r'
  AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid=c.oid AND k.contype='p');
SELECT count(*) AS triggers FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
 WHERE c.relnamespace='public'::regnamespace AND NOT t.tgisinternal;
SELECT count(*) AS tables_without_updated_at_trigger FROM information_schema.columns col
 WHERE col.table_schema='public' AND col.column_name='updated_at'
   AND NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname = 'trg_' || col.table_name || '_set_updated_at');
SELECT 'pos_app' AS role,
  has_table_privilege('pos_app','audit_logs','INSERT') AS audit_ins, has_table_privilege('pos_app','audit_logs','SELECT') AS audit_sel,
  has_table_privilege('pos_app','audit_logs','UPDATE') AS audit_upd, has_table_privilege('pos_app','audit_logs','DELETE') AS audit_del,
  has_table_privilege('pos_app','transactions','UPDATE') AS txn_upd, has_table_privilege('pos_app','order_status_history','DELETE') AS osh_del,
  has_table_privilege('pos_app','receivable_documents','DELETE') AS recdoc_del, has_table_privilege('pos_app','orders','UPDATE') AS orders_upd,
  has_table_privilege('pos_app','orders','TRUNCATE') AS orders_trunc, has_schema_privilege('pos_app','public','CREATE') AS ddl;

DO $$ BEGIN
  IF (SELECT count(*) FROM pg_constraint WHERE contype='f' AND confdeltype='c' AND connamespace='public'::regnamespace) <> 2 THEN RAISE EXCEPTION 'cascade fk count'; END IF;
  IF has_table_privilege('pos_app','audit_logs','UPDATE') OR has_table_privilege('pos_app','audit_logs','DELETE')
     OR NOT has_table_privilege('pos_app','audit_logs','INSERT') THEN RAISE EXCEPTION 'audit rights'; END IF;
  IF has_table_privilege('pos_app','transactions','UPDATE') OR has_table_privilege('pos_app','order_status_history','DELETE')
     OR has_table_privilege('pos_app','receivable_documents','DELETE') THEN RAISE EXCEPTION 'insert-only rights'; END IF;
  IF has_schema_privilege('pos_app','public','CREATE') THEN RAISE EXCEPTION 'pos_app has DDL'; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
             AND data_type IN ('real','double precision','money','timestamp without time zone')) THEN RAISE EXCEPTION 'forbidden types'; END IF;
END $$;

-- 2. functions
SELECT norm_sku('СМ-12 a') AS sku_norm, norm_search('  Смеситель   Ёлка-café ') AS name_norm,
       round_half_up(0.005, 2) AS r1, round_half_up(-0.005, 2) AS r2, round_half_up(2.345, 2) AS r3;
DO $$ DECLARE a uuid; b uuid; i int; BEGIN
  IF norm_sku('СМ-12 a') <> 'СМ12A' THEN RAISE EXCEPTION 'norm_sku'; END IF;
  IF round_half_up(0.005,2) <> 0.01 OR round_half_up(-0.005,2) <> -0.01 THEN RAISE EXCEPTION 'round_half_up'; END IF;
  a := uuid_generate_v7();
  IF substr(a::text, 15, 1) <> '7' OR substr(a::text, 20, 1) NOT IN ('8','9','a','b') THEN RAISE EXCEPTION 'uuid v7 version/variant %', a; END IF;
  FOR i IN 1..10000 LOOP b := uuid_generate_v7();
    IF substr(b::text,1,13) < substr(a::text,1,13) THEN RAISE EXCEPTION 'uuid v7 not monotonic'; END IF; a := b; END LOOP;
END $$;
SELECT show_trgm(norm_search('Смеситель'))::text <> '{}' AS trigrams_cyr,
       to_tsvector('ru_unaccent', 'Смесители для кухни') AS fts;

-- 3. data scenario: users, invitations, catalog, customer, cart, order, payment, outbox, returns
INSERT INTO users (id, phone_e164, kind, status) VALUES
  ('00000000-0000-7000-8000-000000000001', '+996700000001', 'staff', 'active'),
  ('00000000-0000-7000-8000-000000000002', '+996700000002', 'customer', 'active');
SELECT pg_temp.expect_error($q$INSERT INTO users (phone_e164, kind) VALUES ('+79990000000','staff')$q$, 'users phone E.164 (AC-DATA-100)');
SELECT pg_temp.expect_error($q$INSERT INTO users (phone_e164, kind) VALUES ('+996700000001','staff')$q$, 'users phone unique');
INSERT INTO user_invitations (phone_e164, role, full_name, invited_by_user_id, expires_at)
VALUES ('+996700000009', 'cashier', 'Иван Кассир', '00000000-0000-7000-8000-000000000001', now() + interval '30 days');
SELECT pg_temp.expect_error($q$INSERT INTO user_invitations (phone_e164, role, full_name, invited_by_user_id, expires_at)
  VALUES ('+996700000009','seller','Иван','00000000-0000-7000-8000-000000000001', now())$q$, 'one pending invitation (AC-DATA-102)');
SELECT pg_temp.expect_error($q$INSERT INTO user_invitations (phone_e164, role, full_name, invited_by_user_id, expires_at)
  VALUES ('+996700000008','customer','Иван','00000000-0000-7000-8000-000000000001', now())$q$, 'invitation role customer');
-- роли и права — из 0002_rbac_seed.sql (7 ролей, 77 кодов, 231 пара) и дельты 0023_kiosk_rbac_seed.sql (роль kiosk,
-- коды №77–81, 12 пар; ADR-115 п. 14): 8 ролей, 82 кода, 243 пары; kiosk — sort_order 8, не назначается (AC-DATA-103)
SELECT pg_temp.expect_true((SELECT count(*) FROM roles) = 8 AND (SELECT count(*) FROM permissions) = 82
                           AND (SELECT count(*) FROM role_permissions) = 243
                           AND EXISTS (SELECT 1 FROM roles WHERE code = 'kiosk' AND sort_order = 8 AND NOT is_assignable),
                           'rbac seed 8/82/243 (RM-B-008, 0023 — ADR-115)');
SELECT pg_temp.expect_error($q$DELETE FROM roles WHERE code='admin'$q$, 'system role delete (AC-DATA-103)');
SELECT pg_temp.expect_error($q$UPDATE roles SET code='owner' WHERE code='admin'$q$, 'system role rename (AC-DATA-103)');
SELECT pg_temp.expect_error($q$INSERT INTO permissions (code, description_ru) VALUES ('Cart.Write','x')$q$, 'permission code format (AC-DATA-104)');
-- user_roles: одна активная роль в R1 (AC-DATA-106); повторная выдача отозванной роли — новая строка (B-AR-03)
INSERT INTO user_roles (user_id, role_id) SELECT '00000000-0000-7000-8000-000000000001', id FROM roles WHERE code = 'cashier';
SELECT pg_temp.expect_error($q$INSERT INTO user_roles (user_id, role_id) SELECT '00000000-0000-7000-8000-000000000001', id FROM roles WHERE code='owner'$q$, 'one active role (AC-DATA-106)');
SELECT pg_temp.expect_error($q$INSERT INTO user_roles (user_id, role_id) SELECT '00000000-0000-7000-8000-000000000001', id FROM roles WHERE code='cashier'$q$, 'same role active twice (B-AR-03)');
UPDATE user_roles SET revoked_at = now() WHERE user_id = '00000000-0000-7000-8000-000000000001' AND revoked_at IS NULL;
INSERT INTO user_roles (user_id, role_id) SELECT '00000000-0000-7000-8000-000000000001', id FROM roles WHERE code = 'seller';
UPDATE user_roles SET revoked_at = now() WHERE user_id = '00000000-0000-7000-8000-000000000001' AND revoked_at IS NULL;
INSERT INTO user_roles (user_id, role_id) SELECT '00000000-0000-7000-8000-000000000001', id FROM roles WHERE code = 'cashier';
SELECT pg_temp.expect_true(
  (SELECT count(*) FROM user_roles WHERE user_id = '00000000-0000-7000-8000-000000000001') = 3
  AND (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
        WHERE ur.user_id = '00000000-0000-7000-8000-000000000001' AND r.code = 'cashier') = 2
  AND (SELECT count(*) FROM user_roles WHERE user_id = '00000000-0000-7000-8000-000000000001' AND revoked_at IS NULL) = 1,
  'cashier -> seller -> cashier keeps history (B-AR-03)');
SELECT pg_temp.expect_true((SELECT count(*) FROM audit_logs WHERE action = 'user.role_changed') >= 5,
  'user.role_changed audited for each grant/revoke (07 §9.2)');
INSERT INTO devices (id, user_id, device_key, platform) VALUES
  ('00000000-0000-7000-8000-0000000000d1', '00000000-0000-7000-8000-000000000001', '3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e0f', 'windows');
SELECT pg_temp.expect_error($q$INSERT INTO devices (user_id, device_key, platform) VALUES ('00000000-0000-7000-8000-000000000001','ABC','android')$q$, 'device_key uuid v4');

-- integration tokens: third active → error (AC-DATA-168)
INSERT INTO integration_tokens (name, token_hash, token_prefix, expires_at) VALUES ('t1', '\x01', 'abcdefgh', now() + interval '10 days');
INSERT INTO integration_tokens (name, token_hash, token_prefix, expires_at) VALUES ('t2', '\x02', 'abcdefgi', now() + interval '10 days');
SELECT pg_temp.expect_error($q$INSERT INTO integration_tokens (name, token_hash, token_prefix, expires_at) VALUES ('t3','\x03','abcdefgj', now() + interval '10 days')$q$, 'third active integration token');
SELECT pg_temp.expect_error($q$INSERT INTO integration_tokens (name, token_hash, token_prefix, expires_at) VALUES ('t4','\x04','abcdefgk', now() + interval '181 days')$q$, 'integration token ttl 180d');

-- catalog
INSERT INTO units (id, synced_at, source_hash, code, name, qty_precision) VALUES ('00000000-0000-7000-8000-0000000000a1', now(), 'h', 'шт', 'Штука', 0);
INSERT INTO warehouses (id, synced_at, source_hash, name, is_default_for_pos) VALUES ('00000000-0000-7000-8000-0000000000a2', now(), 'h', 'Основной', true);
SELECT pg_temp.expect_error($q$INSERT INTO warehouses (synced_at, source_hash, name, is_default_for_pos) VALUES (now(),'h','Второй',true)$q$, 'one default warehouse (AC-DATA-123)');
INSERT INTO categories (id, synced_at, source_hash, name, path, depth) VALUES
  ('00000000-0000-7000-8000-0000000000a3', now(), 'h', 'Смесители', '/00000000-0000-7000-8000-0000000000a3', 0);
INSERT INTO products (id, synced_at, source_hash, sku, name, brand, category_id, category_path_text, base_unit_id, description)
VALUES ('00000000-0000-7000-8000-0000000000a4', now(), 'h', 'СМ-12 a', 'Смеситель для кухни Хром', 'Grohe', '00000000-0000-7000-8000-0000000000a3', 'Сантехника / Смесители', '00000000-0000-7000-8000-0000000000a1', 'Описание');
SELECT sku_norm, name_norm, search_vector @@ websearch_to_tsquery('ru_unaccent', 'смесители') AS fts_hit,
       name_norm % norm_search('смеситль для кухни') AS trgm_hit FROM products;
INSERT INTO product_variants (id, synced_at, source_hash, product_id, is_default) VALUES
  ('00000000-0000-7000-8000-0000000000a5', now(), 'h', '00000000-0000-7000-8000-0000000000a4', true);
SELECT pg_temp.expect_error($q$INSERT INTO product_variants (synced_at, source_hash, product_id, is_default) VALUES (now(),'h','00000000-0000-7000-8000-0000000000a4', true)$q$, 'second default variant (AC-DATA-116)');
INSERT INTO barcodes (synced_at, source_hash, value, product_id, variant_id, type) VALUES (now(), 'h', '4601234567890', '00000000-0000-7000-8000-0000000000a4', '00000000-0000-7000-8000-0000000000a5', 'EAN13');
INSERT INTO barcodes (synced_at, source_hash, value, product_id, variant_id) VALUES (now(), 'h', 'AB-12.3 x', '00000000-0000-7000-8000-0000000000a4', '00000000-0000-7000-8000-0000000000a5');
SELECT pg_temp.expect_error($q$INSERT INTO barcodes (synced_at, source_hash, value, product_id, variant_id) VALUES (now(),'h','ab#1','00000000-0000-7000-8000-0000000000a4','00000000-0000-7000-8000-0000000000a5')$q$, 'barcode value regex');
INSERT INTO price_lists (id, synced_at, source_hash, name, is_default) VALUES ('00000000-0000-7000-8000-0000000000a6', now(), 'h', 'Розничная', true);
SELECT pg_temp.expect_error($q$INSERT INTO price_lists (synced_at, source_hash, name, currency) VALUES (now(),'h','USD','USD')$q$, 'price list currency KGS (AC-DATA-217)');
INSERT INTO prices (variant_id, price_list_id, price, synced_at, source_hash) VALUES ('00000000-0000-7000-8000-0000000000a5', '00000000-0000-7000-8000-0000000000a6', 100.00, now(), 'h');
SELECT pg_temp.expect_error($q$INSERT INTO prices (variant_id, price_list_id, price, synced_at, source_hash) VALUES ('00000000-0000-7000-8000-0000000000a5','00000000-0000-7000-8000-0000000000a6',90,now(),'h')$q$, 'prices NULLS NOT DISTINCT unique');
INSERT INTO stock_balances (variant_id, warehouse_id, quantity, reserved, onec_snapshot_at, synced_at, source_hash)
VALUES ('00000000-0000-7000-8000-0000000000a5', '00000000-0000-7000-8000-0000000000a2', 10, 3, now(), now(), 'h');
SELECT available FROM stock_balances;

-- customer + receivables
INSERT INTO customers (id, source, name, customer_type, phones_norm) VALUES
  ('00000000-0000-7000-8000-0000000000c1', 'pos', 'ООО Ромашка', 'legal', '{+996555000111}');
SELECT pg_temp.expect_error($q$INSERT INTO receivables (customer_id, balance, overdue_amount, onec_snapshot_at, synced_at, source_hash) VALUES ('00000000-0000-7000-8000-0000000000c1', 100, -1, now(), now(), 'h')$q$, 'overdue_amount -1 (AC-DATA-130)');
INSERT INTO receivables (customer_id, balance, overdue_amount, onec_snapshot_at, synced_at, source_hash) VALUES ('00000000-0000-7000-8000-0000000000c1', 100, NULL, now(), now(), 'h');

-- order + items + deferred totals
INSERT INTO orders (id, public_number, status, customer_id, created_by_user_id, warehouse_id, price_list_id, subtotal,
                    discount_total, customer_discount_total, manual_discount_total, total, payment_method, delivery_method)
VALUES ('00000000-0000-7000-8000-0000000000e1', 'POS-2026-000001', 'draft', '00000000-0000-7000-8000-0000000000c1',
        '00000000-0000-7000-8000-000000000001', '00000000-0000-7000-8000-0000000000a2', '00000000-0000-7000-8000-0000000000a6',
        300.00, 15.00, 0, 15.00, 285.00, 'cash', 'pickup');
INSERT INTO order_items (order_id, line_no, variant_id, product_id, quantity, base_quantity, unit_code_snapshot, unit_price,
                         line_subtotal, manual_discount_amount, discount_amount, line_total, product_name_snapshot)
VALUES ('00000000-0000-7000-8000-0000000000e1', 1, '00000000-0000-7000-8000-0000000000a5', '00000000-0000-7000-8000-0000000000a4',
        3, 3, 'шт', 100.00, 300.00, 15.00, 15.00, 285.00, 'Смеситель');
UPDATE orders SET status = 'submitting', submitted_at = now(), onec_sync_state = 'pending' WHERE id = '00000000-0000-7000-8000-0000000000e1';
SELECT pg_temp.expect_error($q$UPDATE orders SET total = 1 WHERE id = '00000000-0000-7000-8000-0000000000e1'$q$, 'orders total_chk');
SELECT pg_temp.expect_error($q$UPDATE orders SET discount_percent = 5 WHERE id = '00000000-0000-7000-8000-0000000000e1'$q$, 'orders frozen after submit (AC-DATA-136)');
SELECT pg_temp.expect_error($q$UPDATE orders SET onec_sync_state = 'linked' WHERE id = '00000000-0000-7000-8000-0000000000e1'$q$, 'linked without onec_ref');
SELECT pg_temp.expect_error($q$UPDATE orders SET onec_sync_state = 'unknown', status='approved' WHERE id = '00000000-0000-7000-8000-0000000000e1'$q$, 'unknown with approved');
SELECT pg_temp.expect_error($q$UPDATE orders SET cancel_requested_at = now() WHERE id = '00000000-0000-7000-8000-0000000000e1'$q$, 'cancel request without code');
SELECT pg_temp.expect_error($q$UPDATE orders SET refund_intent = 'foo' WHERE id = '00000000-0000-7000-8000-0000000000e1'$q$, 'refund_intent foo');
SELECT pg_temp.expect_error($q$UPDATE order_items SET quantity = 2, line_subtotal = 200, line_total = 185 WHERE order_id = '00000000-0000-7000-8000-0000000000e1'$q$, 'order_items frozen after submit');
UPDATE order_items SET shipped_quantity = 3 WHERE order_id = '00000000-0000-7000-8000-0000000000e1';
UPDATE orders SET paid_amount = 285, paid_at = now() WHERE id = '00000000-0000-7000-8000-0000000000e1';
SELECT pg_temp.expect_error($q$UPDATE orders SET paid_at = now() + interval '1 hour' WHERE id = '00000000-0000-7000-8000-0000000000e1'$q$, 'paid_at once');
SELECT pg_temp.expect_error($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method)
  VALUES ('POS-2026-000002','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000002','customer','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',10,10,'credit','pickup')$q$, 'customer channel credit (orders_customer_channel_chk)');
SELECT pg_temp.expect_error($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method)
  VALUES ('POS-2026-000003','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000001','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',10,10,'cash','delivery')$q$, 'delivery without address/phone');
-- line_subtotal must equal round(unit_price*quantity)
SELECT pg_temp.expect_error($q$INSERT INTO orders (id, public_number, status, customer_id, created_by_user_id, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method)
  VALUES ('00000000-0000-7000-8000-0000000000e2','POS-2026-000004','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000001','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',10,10,'cash','pickup');
  INSERT INTO order_items (order_id, line_no, variant_id, product_id, quantity, base_quantity, unit_code_snapshot, unit_price, line_subtotal, line_total, product_name_snapshot)
  VALUES ('00000000-0000-7000-8000-0000000000e2',1,'00000000-0000-7000-8000-0000000000a5','00000000-0000-7000-8000-0000000000a4',1,1,'шт',10,11,11,'x')$q$, 'line_subtotal calc');

-- deferred totals trigger: a transaction with mismatching Σ line_total must fail at COMMIT
SELECT pg_temp.expect_error($q$
  INSERT INTO orders (id, public_number, status, customer_id, created_by_user_id, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method, onec_sync_state)
  VALUES ('00000000-0000-7000-8000-0000000000e3','POS-2026-000005','submitting','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000001','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',200,200,'cash','pickup','pending');
  INSERT INTO order_items (order_id, line_no, variant_id, product_id, quantity, base_quantity, unit_code_snapshot, unit_price, line_subtotal, line_total, product_name_snapshot)
  VALUES ('00000000-0000-7000-8000-0000000000e3',1,'00000000-0000-7000-8000-0000000000a5','00000000-0000-7000-8000-0000000000a4',1,1,'шт',100,100,100,'x');
  SET CONSTRAINTS trg_order_items_totals IMMEDIATE$q$, 'sum(line_total) <> total (trg_order_items_totals)');

-- payments
INSERT INTO payments (id, public_number, order_id, method, status, amount, created_by_user_id, idempotency_key, received_amount, change_amount)
VALUES ('00000000-0000-7000-8000-0000000000f1', 'PAY-2026-000001', '00000000-0000-7000-8000-0000000000e1', 'cash', 'cash_pending', 285.00,
        '00000000-0000-7000-8000-000000000001', 'k-0000000000000001', NULL, NULL);
SELECT pg_temp.expect_error($q$INSERT INTO payments (public_number, order_id, method, amount, created_by_user_id, idempotency_key) VALUES ('PAY-2026-000002','00000000-0000-7000-8000-0000000000e1','cash',1,'00000000-0000-7000-8000-000000000001','k-0000000000000002')$q$, 'one open payment per order');
SELECT pg_temp.expect_error($q$INSERT INTO payments (public_number, customer_id, method, amount, created_by_user_id, idempotency_key) VALUES ('PAY-2026-000003','00000000-0000-7000-8000-0000000000c1','qr_bakai',1,'00000000-0000-7000-8000-000000000001','k-0000000000000003')$q$, 'qr without qr_provider');
SELECT pg_temp.expect_error($q$INSERT INTO payments (public_number, customer_id, method, qr_provider, amount, created_by_user_id, idempotency_key) VALUES ('PAY-2026-000004','00000000-0000-7000-8000-0000000000c1','cash','onec',1,'00000000-0000-7000-8000-000000000001','k-0000000000000004')$q$, 'cash with qr_provider');
SELECT pg_temp.expect_error($q$UPDATE payments SET review_reason = 'foo' WHERE id='00000000-0000-7000-8000-0000000000f1'$q$, 'review_reason foo');
SELECT pg_temp.expect_error($q$UPDATE payments SET received_amount = 100 WHERE id='00000000-0000-7000-8000-0000000000f1'$q$, 'received_amount < amount');
UPDATE payments SET status = 'received', received_at = now(), received_amount = 300.00, change_amount = 15.00 WHERE id = '00000000-0000-7000-8000-0000000000f1';
SELECT pg_temp.expect_error($q$UPDATE payments SET amount = 1 WHERE id='00000000-0000-7000-8000-0000000000f1'$q$, 'payment frozen after received');
SELECT pg_temp.expect_error($q$DELETE FROM payments WHERE id='00000000-0000-7000-8000-0000000000f1'$q$, 'payment delete forbidden');

-- outbox
INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash)
VALUES ('order', '00000000-0000-7000-8000-0000000000e1', '00000000-0000-7000-8000-0000000000e1', 'create', '{}', '\x00');
SELECT pg_temp.expect_error($q$INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash) VALUES ('order','00000000-0000-7000-8000-0000000000e1','00000000-0000-7000-8000-0000000000e1','update_status','{}','\x00')$q$, 'outbox operation update_status');
-- 12 T-SYNC-040 (10 SYNC-031, DATA-2xx): мастер-данные (товар, цена) из POS в 1С через outbox не уходят — enum outbox_aggregate.
SELECT pg_temp.expect_error($q$INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash) VALUES ('product','00000000-0000-7000-8000-0000000000e2','00000000-0000-7000-8000-0000000000e2','create','{}','\x00')$q$, 'outbox aggregate product (T-SYNC-040)');
SELECT pg_temp.expect_error($q$INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash) VALUES ('price','00000000-0000-7000-8000-0000000000e3','00000000-0000-7000-8000-0000000000e3','create','{}','\x00')$q$, 'outbox aggregate price (T-SYNC-040)');
SELECT pg_temp.expect_error($q$UPDATE onec_outbox SET status = 'sending'$q$, 'sending without lease');
SELECT pg_temp.expect_error($q$INSERT INTO sync_errors (entity, error_code, message, severity) VALUES ('products','FOO','x','error')$q$, 'sync error code dictionary');

-- shipments + returns
INSERT INTO shipments (id, onec_ref, synced_at, source_hash, onec_doc_type, onec_date, posted, customer_id, total)
VALUES ('00000000-0000-7000-8000-0000000000b1', gen_random_uuid(), now(), 'h', 'РеализацияТоваровУслуг', now(), true, '00000000-0000-7000-8000-0000000000c1', 100.00);
INSERT INTO shipment_items (id, shipment_id, onec_line_no, variant_id, product_name_snapshot, quantity, base_quantity, unit_price, line_total, discount_amount, synced_at, source_hash)
VALUES ('00000000-0000-7000-8000-0000000000b2', '00000000-0000-7000-8000-0000000000b1', 1, '00000000-0000-7000-8000-0000000000a5', 'x', 3, 3, 33.34, 100.00, 0, now(), 'h');
INSERT INTO return_requests (id, public_number, shipment_id, customer_id, reason, total, created_by_user_id)
VALUES ('00000000-0000-7000-8000-0000000000b3', 'RET-2026-000001', '00000000-0000-7000-8000-0000000000b1', '00000000-0000-7000-8000-0000000000c1', 'defect', 100.00, '00000000-0000-7000-8000-000000000001');
SELECT pg_temp.expect_error($q$INSERT INTO return_requests (public_number, shipment_id, customer_id, reason, total, created_by_user_id) VALUES ('RET-2026-000002','00000000-0000-7000-8000-0000000000b1','00000000-0000-7000-8000-0000000000c1','other',0,'00000000-0000-7000-8000-000000000001')$q$, 'reason other without comment');
SELECT pg_temp.expect_error($q$INSERT INTO return_request_items (return_request_id, shipment_item_id, variant_id, quantity, unit_price, line_total, product_name_snapshot) VALUES ('00000000-0000-7000-8000-0000000000b3','00000000-0000-7000-8000-0000000000b2','00000000-0000-7000-8000-0000000000a5',4,33.33,133.33,'x')$q$, 'return quantity over shipped');
SELECT pg_temp.expect_error($q$INSERT INTO return_request_items (return_request_id, shipment_item_id, variant_id, quantity, unit_price, line_total, product_name_snapshot) VALUES ('00000000-0000-7000-8000-0000000000b3','00000000-0000-7000-8000-0000000000b2','00000000-0000-7000-8000-0000000000a5',3,33.33,99.99,'x')$q$, 'return line_total 99.99 (must be 100.00)');
INSERT INTO return_request_items (return_request_id, shipment_item_id, variant_id, quantity, unit_price, line_total, product_name_snapshot)
VALUES ('00000000-0000-7000-8000-0000000000b3', '00000000-0000-7000-8000-0000000000b2', '00000000-0000-7000-8000-0000000000a5', 3, 33.33, 100.00, 'x');
UPDATE return_requests SET status = 'submitted', submitted_at = now(), row_version = row_version + 1 WHERE id = '00000000-0000-7000-8000-0000000000b3';
SELECT pg_temp.expect_error($q$UPDATE return_request_items SET product_name_snapshot = 'y'$q$, 'return items frozen after submit (AC-DATA-145)');

-- sync_node_state
UPDATE sync_node_state SET last_message_number = 5 WHERE node = 'pos';
SELECT pg_temp.expect_error($q$UPDATE sync_node_state SET last_message_number = last_message_number - 1 WHERE node='pos'$q$, 'sync_node_state monotonic (AC-DATA-170)');

-- transactions / order_status_history append-only
INSERT INTO transactions (kind, source, order_id, amount, status_snapshot, title_ru, occurred_at, dedupe_key)
VALUES ('order_created', 'pos', '00000000-0000-7000-8000-0000000000e1', 285.00, 'submitting', 'Заказ создан', now(), 'order_created:e1:1');
SELECT pg_temp.expect_error($q$UPDATE transactions SET amount = 1$q$, 'transactions append-only');
INSERT INTO order_status_history (order_id, from_status, to_status, source) VALUES ('00000000-0000-7000-8000-0000000000e1', 'draft', 'submitting', 'pos_system');
SELECT pg_temp.expect_error($q$DELETE FROM order_status_history$q$, 'order_status_history append-only');

-- 4. pos_app role: row_version enforcement, audit diff with actor (AC-SEC-074), INSERT-only audit
GRANT pos_app TO current_user;
DO $$ BEGIN
  SET LOCAL ROLE pos_app;
  PERFORM set_config('app.actor_id', '00000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.actor_role', 'cashier', true);
  PERFORM set_config('app.request_id', 'req-1', true);
  PERFORM set_config('app.ip', '10.0.0.1', true);
  BEGIN
    UPDATE customers SET comment = 'no row_version bump' WHERE id = '00000000-0000-7000-8000-0000000000c1';
    RAISE EXCEPTION 'row_version not enforced';
  EXCEPTION WHEN check_violation THEN NULL; END;
  UPDATE customers SET comment = 'ok', row_version = row_version + 1 WHERE id = '00000000-0000-7000-8000-0000000000c1';
  UPDATE payments SET bank_reference = 'BR-1' WHERE id = '00000000-0000-7000-8000-0000000000f1';
  BEGIN
    UPDATE audit_logs SET reason = 'tamper';
    RAISE EXCEPTION 'audit update allowed for pos_app';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    DELETE FROM transactions;
    RAISE EXCEPTION 'transactions delete allowed for pos_app';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    DELETE FROM receivable_documents;
    RAISE EXCEPTION 'receivable_documents delete allowed for pos_app';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    CREATE TABLE pos_app_ddl_probe (id int);
    RAISE EXCEPTION 'pos_app can create tables';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

-- users block → user.blocked; settings audit; rbac audit present
UPDATE users SET status = 'blocked', blocked_at = now() WHERE id = '00000000-0000-7000-8000-000000000002';
UPDATE users SET phone_e164 = '+996700000003' WHERE id = '00000000-0000-7000-8000-000000000001';
INSERT INTO app_settings (key, value, value_type, description_ru) VALUES ('customer_stock_display', '"status"', 'string', 'x');
UPDATE app_settings SET value = '"quantity"', row_version = row_version + 1 WHERE key = 'customer_stock_display';
UPDATE warehouses SET is_active = false WHERE id = '00000000-0000-7000-8000-0000000000a2';

SELECT chain_seq, level, action, entity_type, actor_user_id IS NOT NULL AS has_actor, actor_role, ip, request_id, severity,
       before, after
  FROM audit_logs ORDER BY chain_seq;

SELECT pg_temp.expect_error($q$UPDATE audit_logs SET reason = 'x'$q$, 'audit_logs immutable for superuser too');
SELECT * FROM audit_verify_chain(1, 1000000);

DO $$ BEGIN
  IF NOT (SELECT ok FROM audit_verify_chain(1, 1000000)) THEN RAISE EXCEPTION 'audit chain broken'; END IF;
  IF NOT EXISTS (SELECT 1 FROM audit_logs WHERE action='rbac.matrix_changed') THEN RAISE EXCEPTION 'rbac audit missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM audit_logs WHERE action='db.payments.update' AND actor_user_id IS NOT NULL
                 AND after ? 'bank_reference' AND request_id='req-1') THEN RAISE EXCEPTION 'payments db audit with actor missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM audit_logs WHERE action='user.blocked') THEN RAISE EXCEPTION 'user.blocked missing'; END IF;
  IF EXISTS (SELECT 1 FROM audit_logs WHERE after::text LIKE '%+996700000003%') THEN RAISE EXCEPTION 'phone not masked'; END IF;
  IF NOT EXISTS (SELECT 1 FROM audit_logs WHERE action='settings.changed' AND entity_type='warehouses') THEN RAISE EXCEPTION 'admin audit missing'; END IF;
END $$;

-- tamper detection: disable immutability as superuser, change a row, verify reports broken
ALTER TABLE audit_logs DISABLE TRIGGER trg_audit_logs_immutable;
UPDATE audit_logs SET reason = 'tampered' WHERE chain_seq = (SELECT min(chain_seq) + 1 FROM audit_logs);
ALTER TABLE audit_logs ENABLE TRIGGER trg_audit_logs_immutable;
SELECT * FROM audit_verify_chain(1, 1000000);
DO $$ BEGIN
  IF (SELECT ok FROM audit_verify_chain(1, 1000000)) THEN RAISE EXCEPTION 'tamper not detected'; END IF;
END $$;

-- =====================================================================================================
-- 5. Исправления архитектурной проверки этапа B
-- =====================================================================================================

-- B-AR-01: idempotency_keys — скоуп subject_key; публичная регистрация без пользователя
INSERT INTO idempotency_keys (key, subject_key, user_id, route, request_hash) VALUES
  ('3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e01', 'reg:' || encode(digest('jti-registration-1', 'sha256'), 'hex'), NULL,
   'POST /registration/complete', '\x01');
INSERT INTO idempotency_keys (key, subject_key, user_id, route, request_hash) VALUES
  ('3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e01', 'reg:' || encode(digest('jti-registration-2', 'sha256'), 'hex'), NULL,
   'POST /registration/complete', '\x02');
INSERT INTO idempotency_keys (key, subject_key, user_id, route, request_hash) VALUES
  ('3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e01', 'user:00000000-0000-7000-8000-000000000001', '00000000-0000-7000-8000-000000000001',
   'POST /orders', '\x03');
SELECT pg_temp.expect_error($q$INSERT INTO idempotency_keys (key, subject_key, user_id, route, request_hash) VALUES ('3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e01', 'reg:' || encode(digest('jti-registration-1','sha256'),'hex'), NULL, 'POST /registration/complete', '\x09')$q$, 'idempotency duplicate (key, subject_key, route) (B-AR-01)');
SELECT pg_temp.expect_error($q$INSERT INTO idempotency_keys (key, subject_key, user_id, route, request_hash) VALUES ('3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e02', 'user:00000000-0000-7000-8000-000000000001', NULL, 'POST /orders', '\x01')$q$, 'idempotency user: without user_id (B-AR-01)');
SELECT pg_temp.expect_error($q$INSERT INTO idempotency_keys (key, subject_key, user_id, route, request_hash) VALUES ('3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e03', 'user:00000000-0000-7000-8000-000000000002', '00000000-0000-7000-8000-000000000001', 'POST /orders', '\x01')$q$, 'idempotency user: mismatch user_id (B-AR-01)');
SELECT pg_temp.expect_error($q$INSERT INTO idempotency_keys (key, subject_key, user_id, route, request_hash) VALUES ('3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e04', 'reg:' || encode(digest('x','sha256'),'hex'), '00000000-0000-7000-8000-000000000001', 'POST /registration/complete', '\x01')$q$, 'idempotency reg: with user_id (B-AR-01)');
SELECT pg_temp.expect_error($q$INSERT INTO idempotency_keys (key, subject_key, route, request_hash) VALUES ('3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e05', 'anon:1', 'POST /orders', '\x01')$q$, 'idempotency subject_key format (B-AR-01)');
SELECT pg_temp.expect_error($q$INSERT INTO idempotency_keys (key, subject_key, route, request_hash) VALUES ('short', 'reg:' || encode(digest('y','sha256'),'hex'), 'POST /registration/complete', '\x01')$q$, 'idempotency key length 16..128');

-- B-AR-05: sync_entity_versions — ключ onec_key для наборов записей регистров (штрихкоды)
INSERT INTO sync_runs (id, entity, mode, "trigger", status, started_at)
VALUES ('00000000-0000-7000-8000-0000000000aa', 'barcodes', 'incremental', 'schedule', 'running', now());
INSERT INTO sync_entity_versions (entity, onec_key, onec_ref, content_hash, seen_in_run_id, last_seen_at, first_seen_at)
VALUES ('barcodes', '4601234567890', NULL, '\x01', '00000000-0000-7000-8000-0000000000aa', now(), now()),
       ('products', '8d2e0000-0000-0000-0000-000000000001', '8d2e0000-0000-0000-0000-000000000001', '\x02',
        '00000000-0000-7000-8000-0000000000aa', now(), now());
SELECT pg_temp.expect_error($q$INSERT INTO sync_entity_versions (entity, onec_key, onec_ref, content_hash, seen_in_run_id, last_seen_at, first_seen_at) VALUES ('barcodes','4601234567890',NULL,'\x03','00000000-0000-7000-8000-0000000000aa',now(),now())$q$, 'sync_entity_versions duplicate (entity, onec_key) (B-AR-05)');
SELECT pg_temp.expect_error($q$INSERT INTO sync_entity_versions (entity, onec_key, onec_ref, content_hash, seen_in_run_id, last_seen_at, first_seen_at) VALUES ('products','other-key','8d2e0000-0000-0000-0000-000000000002','\x03','00000000-0000-7000-8000-0000000000aa',now(),now())$q$, 'sync_entity_versions onec_key <> onec_ref::text (B-AR-05)');
SELECT pg_temp.expect_error($q$INSERT INTO sync_entity_versions (entity, onec_key, content_hash, seen_in_run_id, last_seen_at, first_seen_at) VALUES ('barcodes', repeat('7', 151), '\x03','00000000-0000-7000-8000-0000000000aa',now(),now())$q$, 'sync_entity_versions onec_key > 150 (B-AR-05)');

-- B-AR-19: главное фото — одно на товар/вариант и одно на КАЖДУЮ категорию
INSERT INTO categories (id, synced_at, source_hash, name, path, depth) VALUES
  ('00000000-0000-7000-8000-0000000000a7', now(), 'h', 'Краны', '/00000000-0000-7000-8000-0000000000a7', 0);
INSERT INTO product_images (category_id, source_ref, is_primary) VALUES
  ('00000000-0000-7000-8000-0000000000a3', 'img-cat-1', true),
  ('00000000-0000-7000-8000-0000000000a7', 'img-cat-2', true);
INSERT INTO product_images (product_id, source_ref, is_primary) VALUES ('00000000-0000-7000-8000-0000000000a4', 'img-prod-1', true);
SELECT pg_temp.expect_error($q$INSERT INTO product_images (category_id, source_ref, is_primary) VALUES ('00000000-0000-7000-8000-0000000000a3', 'img-cat-1b', true)$q$, 'second primary photo of one category (B-AR-19)');
SELECT pg_temp.expect_error($q$INSERT INTO product_images (product_id, source_ref, is_primary) VALUES ('00000000-0000-7000-8000-0000000000a4', 'img-prod-2', true)$q$, 'second primary photo of one product');

-- B-AR-20: row_version растёт при любом писателе; «ровно +1» проверяется только для pos_app без app.system
CREATE TEMP TABLE rv_probe ON COMMIT PRESERVE ROWS AS
  SELECT (SELECT row_version FROM customers WHERE id = '00000000-0000-7000-8000-0000000000c1') AS c0,
         (SELECT row_version FROM payments WHERE id = '00000000-0000-7000-8000-0000000000f1') AS p0;
UPDATE customers SET comment = 'superuser/migration writer' WHERE id = '00000000-0000-7000-8000-0000000000c1';
DO $$ BEGIN
  SET LOCAL ROLE pos_app;
  PERFORM set_config('app.system', 'sync', true);
  UPDATE customers SET comment = 'sync worker without explicit bump' WHERE id = '00000000-0000-7000-8000-0000000000c1';
END $$;
UPDATE payments SET bank_reference = 'BR-2' WHERE id = '00000000-0000-7000-8000-0000000000f1';
UPDATE payments SET bank_reference = 'BR-3', row_version = row_version + 1 WHERE id = '00000000-0000-7000-8000-0000000000f1';
SELECT pg_temp.expect_true(
  (SELECT row_version FROM customers WHERE id = '00000000-0000-7000-8000-0000000000c1') = (SELECT c0 FROM rv_probe) + 2,
  'customers.row_version bumped for system writers (B-AR-20)');
SELECT pg_temp.expect_true(
  (SELECT row_version FROM payments WHERE id = '00000000-0000-7000-8000-0000000000f1') = (SELECT p0 FROM rv_probe) + 2,
  'payments.row_version bumped once per UPDATE (B-AR-20)');
DO $$ BEGIN
  SET LOCAL ROLE pos_app;
  BEGIN
    UPDATE customers SET comment = 'api without bump' WHERE id = '00000000-0000-7000-8000-0000000000c1';
    RAISE EXCEPTION 'row_version not enforced for pos_app';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
INSERT INTO ddl_check_log (label, outcome) VALUES ('pos_app UPDATE customers without row_version+1 (07 §8.3)', 'rejected 23514');

-- B-AR-09: dev_outbox есть только в dev/test-схеме (этот прогон — app.env=test)
SELECT pg_temp.expect_true(current_setting('app.env', true) IN ('dev', 'test') AND to_regclass('public.dev_outbox') IS NOT NULL,
  'dev_outbox present in dev/test schema (app.env=' || coalesce(current_setting('app.env', true), '<не задан>') || ')');

-- =====================================================================================================
-- 6. Режим «Планшет магазина» (P-002, ADR-115): 0021_kiosk_enum_values.sql, 0022_kiosk_schema.sql
--    (07 §5.65, §5.1, §5.9, §5.11, §5.12, §5.37, §5.61; DATA-171, DATA-300…DATA-303, DATA-305; 12 T-KIOSK-025)
-- =====================================================================================================

-- 6.1 Значения enum-ов 0021 — в конце перечней (07 §6.1); типов по-прежнему 45 (scripts/check_tables.sql)
SELECT pg_temp.expect_true(
  enum_range(NULL::user_kind)::text[] = ARRAY['staff','customer','kiosk']
  AND (enum_range(NULL::role_code)::text[])[8] = 'kiosk'
  AND (enum_range(NULL::otp_purpose)::text[])[6] = 'kiosk_order'
  AND (enum_range(NULL::notification_kind)::text[])[9] = 'kiosk_order',
  'enum values kiosk / kiosk_order appended (0021, 07 §6.1)');
SELECT pg_temp.expect_true(
  (SELECT data_type FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'orders' AND column_name = 'created_via') = 'text',
  'orders.created_via stays text with CHECK, not enum (ADR-115 п. 15)');

-- 6.2 Технический пользователь планшета — без телефона (users_kiosk_phone_chk, AC-DATA-300)
INSERT INTO users (id, kind, status) VALUES
  ('00000000-0000-7000-8000-000000000101', 'kiosk', 'active'),
  ('00000000-0000-7000-8000-000000000102', 'kiosk', 'active');
SELECT pg_temp.expect_constraint($q$INSERT INTO users (phone_e164, kind, status) VALUES ('+996700000101','kiosk','active')$q$,
  'users_kiosk_phone_chk', 'kiosk user with phone (AC-DATA-300)');
SELECT pg_temp.expect_constraint($q$UPDATE users SET phone_e164 = '+996700000101' WHERE id = '00000000-0000-7000-8000-000000000101'$q$,
  'users_kiosk_phone_chk', 'kiosk user gets a phone later');
INSERT INTO devices (id, user_id, device_key, platform) VALUES
  ('00000000-0000-7000-8000-0000000001d1', '00000000-0000-7000-8000-000000000101', '3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e11', 'android'),
  ('00000000-0000-7000-8000-0000000001d2', '00000000-0000-7000-8000-000000000102', '3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e12', 'android');

-- 6.3 store_tablets (DATA-171): один планшет на пользователя, статус ↔ revoked_at, формат revoke_reason
INSERT INTO store_tablets (id, user_id, device_id, exit_code_hash, exit_code_pepper_version, enrolled_by_user_id) VALUES
  ('00000000-0000-7000-8000-0000000001a1', '00000000-0000-7000-8000-000000000101', '00000000-0000-7000-8000-0000000001d1',
   'stub-argon2id-hash-1', 1, '00000000-0000-7000-8000-000000000001'),
  ('00000000-0000-7000-8000-0000000001a2', '00000000-0000-7000-8000-000000000102', '00000000-0000-7000-8000-0000000001d2',
   'stub-argon2id-hash-2', 1, '00000000-0000-7000-8000-000000000001');
SELECT pg_temp.expect_true(
  (SELECT count(*) FROM store_tablets WHERE status = 'active' AND exit_failed_attempts = 0 AND lock_task_enabled IS NULL
      AND enrolled_at IS NOT NULL AND revoked_at IS NULL) = 2,
  'store_tablets defaults: active, 0 attempts, lock_task_enabled NULL until X-Kiosk-Lock (07 §5.65)');
SELECT pg_temp.expect_constraint($q$INSERT INTO store_tablets (user_id, device_id, exit_code_hash, exit_code_pepper_version, enrolled_by_user_id)
  VALUES ('00000000-0000-7000-8000-000000000101','00000000-0000-7000-8000-0000000001d1','h',1,'00000000-0000-7000-8000-000000000001')$q$,
  'store_tablets_user_id_uq', 'second tablet row for one kiosk user');
SELECT pg_temp.expect_constraint($q$INSERT INTO store_tablets (user_id, device_id, exit_code_hash, exit_code_pepper_version, enrolled_by_user_id)
  VALUES (gen_random_uuid(),'00000000-0000-7000-8000-0000000001d1','h',1,'00000000-0000-7000-8000-000000000001')$q$,
  'store_tablets_user_id_fk', 'store_tablets user FK');
SELECT pg_temp.expect_constraint($q$UPDATE store_tablets SET status = 'paused' WHERE id = '00000000-0000-7000-8000-0000000001a1'$q$,
  'store_tablets_status_chk', 'store_tablets status outside active|revoked');
SELECT pg_temp.expect_constraint($q$UPDATE store_tablets SET status = 'revoked' WHERE id = '00000000-0000-7000-8000-0000000001a1'$q$,
  'store_tablets_revoked_chk', 'store_tablets revoked without revoked_at');
SELECT pg_temp.expect_constraint($q$UPDATE store_tablets SET revoked_at = now() WHERE id = '00000000-0000-7000-8000-0000000001a1'$q$,
  'store_tablets_revoked_chk', 'store_tablets active with revoked_at');
SELECT pg_temp.expect_constraint($q$UPDATE store_tablets SET exit_failed_attempts = -1 WHERE id = '00000000-0000-7000-8000-0000000001a1'$q$,
  'store_tablets_exit_failed_attempts_chk', 'store_tablets exit_failed_attempts < 0');
SELECT pg_temp.expect_constraint($q$UPDATE store_tablets SET status = 'revoked', revoked_at = now(), revoke_reason = 'Отключён администратором'
  WHERE id = '00000000-0000-7000-8000-0000000001a1'$q$,
  'store_tablets_revoke_reason_chk', 'store_tablets revoke_reason not an audit event name');
-- Аварийный выход со связью → revoked (revoked_by_user_id NULL), затем подключение заново — та же строка (07 §5.65)
UPDATE store_tablets SET status = 'revoked', revoked_at = now(), revoke_reason = 'kiosk.exit_code_used', exit_code_used_at = now()
 WHERE id = '00000000-0000-7000-8000-0000000001a2';
UPDATE store_tablets SET status = 'active', revoked_at = NULL, revoked_by_user_id = NULL, revoke_reason = NULL,
       exit_code_hash = 'stub-argon2id-hash-3', exit_code_used_at = NULL, exit_failed_attempts = 0, exit_locked_until = NULL,
       lock_task_enabled = NULL, reconnected_at = now(), reconnected_by_user_id = '00000000-0000-7000-8000-000000000001'
 WHERE id = '00000000-0000-7000-8000-0000000001a2';
SELECT pg_temp.expect_true(
  (SELECT status = 'active' AND reconnected_by_user_id IS NOT NULL AND revoke_reason IS NULL
     FROM store_tablets WHERE id = '00000000-0000-7000-8000-0000000001a2')
  AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_store_tablets_set_updated_at' AND NOT tgisinternal)
  AND has_table_privilege('pos_app', 'store_tablets', 'SELECT') AND has_table_privilege('pos_app', 'store_tablets', 'INSERT')
  AND has_table_privilege('pos_app', 'store_tablets', 'UPDATE') AND has_table_privilege('pos_readonly', 'store_tablets', 'SELECT')
  AND NOT has_table_privilege('pos_readonly', 'store_tablets', 'UPDATE'),
  'store_tablets exit → reconnect keeps the row; updated_at trigger; pos_app/pos_readonly rights');

-- 6.4 CHECK-перечни auth/sms, дополненные 0022 (прежние значения сохранены)
INSERT INTO sessions (user_id, device_id, family_id, refresh_hash, expires_at, idle_expires_at, amr, revoked_at, revoke_reason) VALUES
  ('00000000-0000-7000-8000-000000000101', '00000000-0000-7000-8000-0000000001d1', gen_random_uuid(), '\x0a01',
   now() + interval '180 days', now() + interval '7 days', '{pin}', now(), 'kiosk_revoked'),
  ('00000000-0000-7000-8000-000000000101', '00000000-0000-7000-8000-0000000001d1', gen_random_uuid(), '\x0a02',
   now() + interval '180 days', now() + interval '7 days', '{pin}', now(), 'refresh_replay');
SELECT pg_temp.expect_constraint($q$INSERT INTO sessions (user_id, device_id, family_id, refresh_hash, expires_at, idle_expires_at, revoked_at, revoke_reason)
  VALUES ('00000000-0000-7000-8000-000000000101','00000000-0000-7000-8000-0000000001d1',gen_random_uuid(),'\x0a03',now(),now(),now(),'tablet_revoked')$q$,
  'sessions_revoke_reason_chk', 'session revoke_reason outside list (kiosk_revoked only)');
INSERT INTO rate_limit_counters (scope, subject, window_start, count, window_end) VALUES
  ('otp_kiosk_tablet_1h', '00000000-0000-7000-8000-0000000001a1', date_trunc('hour', now()), 1, date_trunc('hour', now()) + interval '1 hour'),
  ('otp_kiosk_tablet_24h', '00000000-0000-7000-8000-0000000001a1', date_trunc('day', now()), 1, date_trunc('day', now()) + interval '1 day'),
  ('admin_user_1m', '00000000-0000-7000-8000-000000000001', date_trunc('minute', now()), 1, date_trunc('minute', now()) + interval '1 minute');
SELECT pg_temp.expect_constraint($q$INSERT INTO rate_limit_counters (scope, subject, window_start, count, window_end)
  VALUES ('otp_kiosk_tablet_10m','x',now(),1,now())$q$, 'rate_limit_counters_scope_chk', 'rate limit scope outside list');
INSERT INTO sms_outbox (phone_e164, template_key, provider, provider_message_id) VALUES ('+996700000101', 'otp_kiosk_order', 'fake', 'KIOSK0000001');
SELECT pg_temp.expect_constraint($q$INSERT INTO sms_outbox (phone_e164, template_key, provider, provider_message_id)
  VALUES ('+996700000101','otp_kiosk','fake','KIOSK0000002')$q$, 'sms_outbox_template_key_chk', 'sms template_key outside list');
INSERT INTO notifications (user_id, kind, severity, title_ru, body_ru, dedupe_key)
VALUES ('00000000-0000-7000-8000-000000000001', 'kiosk_order', 'info', 'Заявка с планшета', 'POS-2026-000101', 'kiosk_order:POS-2026-000101');

-- 6.5 Код kiosk_order (DATA-301): планшет + корзина + версия текста, без пользователя; один действующий на планшет
INSERT INTO carts (id, owner_user_id, created_by_user_id, device_id, warehouse_id, price_list_id) VALUES
  ('00000000-0000-7000-8000-0000000001c1', '00000000-0000-7000-8000-000000000101', '00000000-0000-7000-8000-000000000101',
   '00000000-0000-7000-8000-0000000001d1', '00000000-0000-7000-8000-0000000000a2', '00000000-0000-7000-8000-0000000000a6'),
  ('00000000-0000-7000-8000-0000000001c2', '00000000-0000-7000-8000-000000000102', '00000000-0000-7000-8000-000000000102',
   '00000000-0000-7000-8000-0000000001d2', '00000000-0000-7000-8000-0000000000a2', '00000000-0000-7000-8000-0000000000a6');
INSERT INTO otp_challenges (id, phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status,
                            kiosk_tablet_id, cart_id, notice_version, device_key)
VALUES ('00000000-0000-7000-8000-0000000001e1', '+996700000101', 'kiosk_order', '\x01', '\x01', 1, now() + interval '5 minutes', 'sent',
        '00000000-0000-7000-8000-0000000001a1', '00000000-0000-7000-8000-0000000001c1', '2026-11-04', '3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e11');
SELECT pg_temp.expect_constraint($q$INSERT INTO otp_challenges (phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status, kiosk_tablet_id, notice_version)
  VALUES ('+996700000103','kiosk_order','\x01','\x01',1,now(),'sent','00000000-0000-7000-8000-0000000001a2','2026-11-04')$q$,
  'otp_challenges_kiosk_chk', 'kiosk_order code without cart (AC-DATA-301)');
SELECT pg_temp.expect_constraint($q$INSERT INTO otp_challenges (phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status, cart_id, notice_version)
  VALUES ('+996700000103','kiosk_order','\x01','\x01',1,now(),'sent','00000000-0000-7000-8000-0000000001c2','2026-11-04')$q$,
  'otp_challenges_kiosk_chk', 'kiosk_order code without tablet');
SELECT pg_temp.expect_constraint($q$INSERT INTO otp_challenges (phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status, kiosk_tablet_id, cart_id)
  VALUES ('+996700000103','kiosk_order','\x01','\x01',1,now(),'sent','00000000-0000-7000-8000-0000000001a2','00000000-0000-7000-8000-0000000001c2')$q$,
  'otp_challenges_kiosk_chk', 'kiosk_order code without notice version');
SELECT pg_temp.expect_constraint($q$INSERT INTO otp_challenges (phone_e164, user_id, purpose, code_hmac, salt, pepper_version, expires_at, status, kiosk_tablet_id, cart_id, notice_version)
  VALUES ('+996700000103','00000000-0000-7000-8000-000000000101','kiosk_order','\x01','\x01',1,now(),'sent','00000000-0000-7000-8000-0000000001a2','00000000-0000-7000-8000-0000000001c2','2026-11-04')$q$,
  'otp_challenges_kiosk_chk', 'kiosk_order code bound to a user account');
-- выдавший администратор: отклоняют и otp_challenges_issued_by_chk (0003), и otp_challenges_kiosk_chk
SELECT pg_temp.expect_error($q$INSERT INTO otp_challenges (phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status, kiosk_tablet_id, cart_id, notice_version, issued_by_user_id)
  VALUES ('+996700000103','kiosk_order','\x01','\x01',1,now(),'sent','00000000-0000-7000-8000-0000000001a2','00000000-0000-7000-8000-0000000001c2','2026-11-04','00000000-0000-7000-8000-000000000001')$q$,
  'kiosk_order code issued by an admin');
SELECT pg_temp.expect_constraint($q$INSERT INTO otp_challenges (phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status, kiosk_tablet_id)
  VALUES ('+996700000103','login_or_register','\x01','\x01',1,now(),'sent','00000000-0000-7000-8000-0000000001a2')$q$,
  'otp_challenges_kiosk_chk', 'login code with kiosk_tablet_id');
SELECT pg_temp.expect_constraint($q$INSERT INTO otp_challenges (phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status, kiosk_tablet_id, cart_id, notice_version)
  VALUES ('+996700000103','kiosk_order','\x01','\x01',1,now(),'sent',gen_random_uuid(),'00000000-0000-7000-8000-0000000001c2','2026-11-04')$q$,
  'otp_challenges_kiosk_tablet_id_fk', 'kiosk_order code of an unknown tablet');
SELECT pg_temp.expect_constraint($q$INSERT INTO otp_challenges (phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status, kiosk_tablet_id, cart_id, notice_version)
  VALUES ('+996700000104','kiosk_order','\x01','\x01',1,now(),'sent','00000000-0000-7000-8000-0000000001a1','00000000-0000-7000-8000-0000000001c1','2026-11-04')$q$,
  'otp_challenges_kiosk_active_uq', 'second sent kiosk_order code of one tablet (AC-DATA-301)');
-- другой планшет — свой действующий код; прежний код планшета superseded → новый допустим
INSERT INTO otp_challenges (phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status, kiosk_tablet_id, cart_id, notice_version)
VALUES ('+996700000105', 'kiosk_order', '\x01', '\x01', 1, now() + interval '5 minutes', 'sent',
        '00000000-0000-7000-8000-0000000001a2', '00000000-0000-7000-8000-0000000001c2', '2026-11-04');
UPDATE otp_challenges SET status = 'superseded' WHERE id = '00000000-0000-7000-8000-0000000001e1';
INSERT INTO otp_challenges (phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status, kiosk_tablet_id, cart_id, notice_version)
VALUES ('+996700000104', 'kiosk_order', '\x01', '\x01', 1, now() + interval '5 minutes', 'sent',
        '00000000-0000-7000-8000-0000000001a1', '00000000-0000-7000-8000-0000000001c1', '2026-11-04');
SELECT pg_temp.expect_true(
  (SELECT count(*) FROM otp_challenges WHERE purpose = 'kiosk_order' AND status = 'sent') = 2
  AND (SELECT count(*) FROM otp_challenges WHERE kiosk_tablet_id IS NULL AND cart_id IS NULL AND notice_version IS NULL)
      = (SELECT count(*) FROM otp_challenges WHERE purpose <> 'kiosk_order'),
  'one sent kiosk_order code per tablet; other purposes keep kiosk columns empty');

-- 6.6 T-KIOSK-025: CHECK канала kiosk (orders_kiosk_channel_chk) — наличные, самовывоз, без ручной скидки и долга;
--     скидку клиента 1С (customer_discount_*) CHECK не ограничивает (Р-05 (а)); kiosk_customer_match — только у kiosk
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method, kiosk_customer_match, receiver_phone_e164)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','kiosk','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,100,'credit','pickup','single','+996700000101')$q$,
  'orders_kiosk_channel_chk', 'T-KIOSK-025 kiosk order on credit');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method, kiosk_customer_match, receiver_phone_e164)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','kiosk','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,100,'qr_bakai','pickup','single','+996700000101')$q$,
  'orders_kiosk_channel_chk', 'T-KIOSK-025 kiosk order paid by QR (cash only)');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, discount_percent, total, payment_method, delivery_method, kiosk_customer_match, receiver_phone_e164)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','kiosk','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,5,100,'cash','pickup','single','+996700000101')$q$,
  'orders_kiosk_channel_chk', 'T-KIOSK-025 kiosk order with discount_percent');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, manual_discount_total, discount_total, total, payment_method, delivery_method, kiosk_customer_match, receiver_phone_e164)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','kiosk','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,10,10,90,'cash','pickup','single','+996700000101')$q$,
  'orders_kiosk_channel_chk', 'T-KIOSK-025 kiosk order with manual discount');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method, kiosk_customer_match, receiver_phone_e164, discount_approved_by_user_id)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','kiosk','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,100,'cash','pickup','single','+996700000101','00000000-0000-7000-8000-000000000001')$q$,
  'orders_kiosk_channel_chk', 'T-KIOSK-025 kiosk order with discount approval');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method, kiosk_customer_match, receiver_phone_e164, credit_approved_by_user_id)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','kiosk','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,100,'cash','pickup','single','+996700000101','00000000-0000-7000-8000-000000000001')$q$,
  'orders_kiosk_channel_chk', 'T-KIOSK-025 kiosk order with credit approval');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method, delivery_address, delivery_recipient_phone_e164, kiosk_customer_match, receiver_phone_e164)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','kiosk','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,100,'cash','delivery','г. Бишкек, ул. Токтогула, 1','+996700000101','single','+996700000101')$q$,
  'orders_kiosk_channel_chk', 'T-KIOSK-025 kiosk order with delivery (pickup only)');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method, receiver_phone_e164)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','kiosk','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,100,'cash','pickup','+996700000101')$q$,
  'orders_kiosk_match_chk', 'kiosk order without kiosk_customer_match (AC-DATA-302)');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method, kiosk_customer_match)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000001','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,100,'cash','pickup','single')$q$,
  'orders_kiosk_match_chk', 'staff order with kiosk_customer_match (AC-DATA-302)');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method, kiosk_customer_match, receiver_phone_e164)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','kiosk','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,100,'cash','pickup','many','+996700000101')$q$,
  'orders_kiosk_customer_match_chk', 'kiosk_customer_match outside single|ambiguous|none');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','tablet','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,100,'cash','pickup')$q$,
  'orders_created_via_chk', 'created_via outside staff|customer|kiosk');
SELECT pg_temp.expect_constraint($q$INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id, subtotal, total, payment_method, delivery_method, kiosk_customer_match, pd_notice_version, pd_notice_sha256, receiver_phone_e164)
  VALUES ('POS-2026-000102','draft','00000000-0000-7000-8000-0000000000c1','00000000-0000-7000-8000-000000000101','kiosk','00000000-0000-7000-8000-0000000000a2','00000000-0000-7000-8000-0000000000a6',100,100,'cash','pickup','none','2026-11-04','ABC','+996700000101')$q$,
  'orders_pd_notice_sha256_chk', 'pd_notice_sha256 not 64 lowercase hex');
-- допустимая заявка с планшета: наличные, самовывоз, скидка клиента 1С 5 % (Р-05 (а)), принята сервером (submitting)
INSERT INTO orders (id, public_number, status, customer_id, created_by_user_id, created_via, device_id, warehouse_id, price_list_id,
                    subtotal, customer_discount_percent, customer_discount_total, discount_total, total, payment_method, delivery_method,
                    kiosk_customer_match, pd_notice_version, pd_notice_sha256, receiver_phone_e164, submitted_at, onec_sync_state)
VALUES ('00000000-0000-7000-8000-0000000001b1', 'POS-2026-000101', 'submitting', '00000000-0000-7000-8000-0000000000c1',
        '00000000-0000-7000-8000-000000000101', 'kiosk', '00000000-0000-7000-8000-0000000001d1', '00000000-0000-7000-8000-0000000000a2',
        '00000000-0000-7000-8000-0000000000a6', 100.00, 5.00, 5.00, 5.00, 95.00, 'cash', 'pickup', 'single', '2026-11-04',
        encode(digest('kiosk_order_notice 2026-11-04', 'sha256'), 'hex'), '+996700000101', now(), 'pending');
SELECT pg_temp.expect_true(
  (SELECT count(*) FROM orders WHERE created_via = 'kiosk' AND customer_discount_total = 5.00 AND kiosk_customer_match = 'single') = 1
  AND (SELECT count(*) FROM orders WHERE created_via <> 'kiosk' AND kiosk_customer_match IS NOT NULL) = 0,
  'T-KIOSK-025 kiosk order: cash + pickup + 1C customer discount accepted');

-- 6.7 Маскирование номера через 90 дней (DATA-303): маска — в receiver_phone_masked, E.164 → NULL одним UPDATE;
--     CHECK E.164 receiver_phone_e164 не ослаблен; триггер заморозки финансовых полей маскированию не мешает
SELECT pg_temp.expect_constraint($q$UPDATE orders SET receiver_phone_masked = '+996 7** *** *01' WHERE id = '00000000-0000-7000-8000-0000000001b1'$q$,
  'orders_receiver_phone_masked_null_chk', 'masked phone together with E.164 (AC-DATA-303)');
SELECT pg_temp.expect_constraint($q$UPDATE orders SET receiver_phone_e164 = '+996 7** *** *01' WHERE id = '00000000-0000-7000-8000-0000000001b1'$q$,
  'orders_receiver_phone_e164_chk', 'mask written into receiver_phone_e164 (AC-DATA-303)');
SELECT pg_temp.expect_constraint($q$UPDATE orders SET receiver_phone_e164 = NULL, receiver_phone_masked = '+996 *** ** 01' WHERE id = '00000000-0000-7000-8000-0000000001b1'$q$,
  'orders_receiver_phone_masked_chk', 'masked phone in a wrong format');
UPDATE orders SET receiver_phone_e164 = NULL, receiver_phone_masked = '+996 7** *** *01' WHERE id = '00000000-0000-7000-8000-0000000001b1';
SELECT pg_temp.expect_true(
  (SELECT receiver_phone_e164 IS NULL AND receiver_phone_masked = '+996 7** *** *01' AND submitted_at IS NOT NULL
     FROM orders WHERE id = '00000000-0000-7000-8000-0000000001b1'),
  'kiosk order phone masked after submit (DATA-303)');

-- =====================================================================================================
-- 7. Вход по лицу на всех платформах (15 ADR-116): 0024_face_login.sql — уровень W Android (sessions.weak_reauth_due_at,
--    biometric_weak_disabled) и ключ Windows Hello (hello_keys); 07 §5.9, §5.66, DATA-306, DATA-308; 12 T-DATA-003
-- =====================================================================================================

-- 7.1 Срок уровня W — только у биометрической семьи (sessions_weak_reauth_chk, AC-DATA-306)
INSERT INTO devices (id, user_id, device_key, platform) VALUES
  ('00000000-0000-7000-8000-0000000002d1', '00000000-0000-7000-8000-000000000002', '3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e31', 'android');
SELECT pg_temp.expect_constraint($q$INSERT INTO sessions (user_id, device_id, family_id, refresh_hash, kind, expires_at, idle_expires_at, weak_reauth_due_at)
  VALUES ('00000000-0000-7000-8000-000000000002','00000000-0000-7000-8000-0000000002d1',gen_random_uuid(),'\x0b01','standard',now() + interval '30 days',now() + interval '14 days',now())$q$,
  'sessions_weak_reauth_chk', 'standard session with weak_reauth_due_at (AC-DATA-306)');
INSERT INTO sessions (id, user_id, device_id, family_id, refresh_hash, kind, expires_at, idle_expires_at, amr, weak_reauth_due_at) VALUES
  ('00000000-0000-7000-8000-0000000002f1', '00000000-0000-7000-8000-000000000002', '00000000-0000-7000-8000-0000000002d1',
   gen_random_uuid(), '\x0b02', 'biometric', now() + interval '30 days', now() + interval '14 days', '{sms,bio}', now() + interval '24 hours');
SELECT pg_temp.expect_constraint($q$UPDATE sessions SET kind = 'standard' WHERE id = '00000000-0000-7000-8000-0000000002f1'$q$,
  'sessions_weak_reauth_chk', 'weak family turned into a standard session');
-- 7.2 Причина отзыва: + biometric_weak_disabled (прежние 14 значений сохранены, 'weak_off' — вне перечня)
UPDATE sessions SET revoked_at = now(), revoke_reason = 'biometric_weak_disabled' WHERE id = '00000000-0000-7000-8000-0000000002f1';
SELECT pg_temp.expect_constraint($q$INSERT INTO sessions (user_id, device_id, family_id, refresh_hash, expires_at, idle_expires_at, revoked_at, revoke_reason)
  VALUES ('00000000-0000-7000-8000-000000000002','00000000-0000-7000-8000-0000000002d1',gen_random_uuid(),'\x0b03',now(),now(),now(),'weak_off')$q$,
  'sessions_revoke_reason_chk', 'session revoke_reason outside list (biometric_weak_disabled only)');
SELECT pg_temp.expect_true(
  EXISTS (SELECT 1 FROM sessions WHERE revoke_reason = 'kiosk_revoked')
  AND EXISTS (SELECT 1 FROM sessions WHERE revoke_reason = 'refresh_replay')
  AND (SELECT kind = 'biometric' AND weak_reauth_due_at IS NOT NULL FROM sessions WHERE id = '00000000-0000-7000-8000-0000000002f1'),
  'weak family revoked with biometric_weak_disabled; earlier reasons still valid (DATA-306)');

-- 7.3 hello_keys (DATA-172): RS256 и SPKI 256…1024 байт, источник, один живой ключ на устройство, challenge вместе с
--     сессией и сроком и не у отозванного, revoked_at ↔ revoke_reason, FK, триггер updated_at, права
INSERT INTO sessions (id, user_id, device_id, family_id, refresh_hash, expires_at, idle_expires_at) VALUES
  ('00000000-0000-7000-8000-0000000002f2', '00000000-0000-7000-8000-000000000001', '00000000-0000-7000-8000-0000000000d1',
   gen_random_uuid(), '\x0b04', now() + interval '7 days', now() + interval '24 hours');
INSERT INTO hello_keys (id, user_id, device_id, public_key, algorithm, source) VALUES
  ('00000000-0000-7000-8000-0000000002b1', '00000000-0000-7000-8000-000000000001', '00000000-0000-7000-8000-0000000000d1',
   decode(repeat('ab', 294), 'hex'), 'RS256', 'windows_hello');
SELECT pg_temp.expect_constraint($q$INSERT INTO hello_keys (user_id, device_id, public_key, algorithm, source)
  VALUES ('00000000-0000-7000-8000-000000000001','00000000-0000-7000-8000-0000000000d1',decode(repeat('cd', 294),'hex'),'RS256','windows_hello')$q$,
  'hello_keys_device_live_uq', 'second live hello key on one device');
SELECT pg_temp.expect_constraint($q$INSERT INTO hello_keys (user_id, device_id, public_key, algorithm, source)
  VALUES ('00000000-0000-7000-8000-000000000002','00000000-0000-7000-8000-0000000002d1',decode(repeat('ab', 294),'hex'),'ES256','windows_hello')$q$,
  'hello_keys_algorithm_chk', 'hello key algorithm outside RS256');
SELECT pg_temp.expect_constraint($q$INSERT INTO hello_keys (user_id, device_id, public_key, algorithm, source)
  VALUES ('00000000-0000-7000-8000-000000000002','00000000-0000-7000-8000-0000000002d1',decode(repeat('ab', 294),'hex'),'RS256','browser')$q$,
  'hello_keys_source_chk', 'hello key source outside windows_hello|webauthn_prf');
SELECT pg_temp.expect_constraint($q$INSERT INTO hello_keys (user_id, device_id, public_key, algorithm, source)
  VALUES ('00000000-0000-7000-8000-000000000002','00000000-0000-7000-8000-0000000002d1',decode(repeat('ab', 91),'hex'),'RS256','webauthn_prf')$q$,
  'hello_keys_public_key_len_chk', 'hello key public_key shorter than 256 bytes (RSA-1024 / EC)');
SELECT pg_temp.expect_constraint($q$INSERT INTO hello_keys (user_id, device_id, public_key, algorithm, source)
  VALUES (gen_random_uuid(),'00000000-0000-7000-8000-0000000002d1',decode(repeat('ab', 294),'hex'),'RS256','webauthn_prf')$q$,
  'hello_keys_user_id_fk', 'hello key user FK');
SELECT pg_temp.expect_constraint($q$UPDATE hello_keys SET challenge = decode(repeat('01', 32),'hex') WHERE id = '00000000-0000-7000-8000-0000000002b1'$q$,
  'hello_keys_challenge_chk', 'challenge without session and expiry');
SELECT pg_temp.expect_constraint($q$UPDATE hello_keys SET challenge = decode(repeat('01', 31),'hex'), challenge_session_id = '00000000-0000-7000-8000-0000000002f2',
  challenge_expires_at = now() + interval '120 seconds' WHERE id = '00000000-0000-7000-8000-0000000002b1'$q$,
  'hello_keys_challenge_chk', 'challenge of 31 bytes (32 required)');
SELECT pg_temp.expect_constraint($q$UPDATE hello_keys SET challenge = decode(repeat('01', 32),'hex'), challenge_session_id = gen_random_uuid(),
  challenge_expires_at = now() + interval '120 seconds' WHERE id = '00000000-0000-7000-8000-0000000002b1'$q$,
  'hello_keys_challenge_session_id_fk', 'challenge session FK');
UPDATE hello_keys SET challenge = decode(repeat('01', 32), 'hex'), challenge_session_id = '00000000-0000-7000-8000-0000000002f2',
       challenge_expires_at = now() + interval '120 seconds'
 WHERE id = '00000000-0000-7000-8000-0000000002b1';
SELECT pg_temp.expect_constraint($q$UPDATE hello_keys SET revoked_at = now(), revoke_reason = 'disabled' WHERE id = '00000000-0000-7000-8000-0000000002b1'$q$,
  'hello_keys_challenge_chk', 'revoked hello key keeps a challenge');
SELECT pg_temp.expect_constraint($q$UPDATE hello_keys SET challenge = NULL, challenge_session_id = NULL, challenge_expires_at = NULL, revoked_at = now()
  WHERE id = '00000000-0000-7000-8000-0000000002b1'$q$,
  'hello_keys_revoked_chk', 'hello key revoked_at without revoke_reason');
SELECT pg_temp.expect_constraint($q$UPDATE hello_keys SET challenge = NULL, challenge_session_id = NULL, challenge_expires_at = NULL, revoked_at = now(),
  revoke_reason = 'expired' WHERE id = '00000000-0000-7000-8000-0000000002b1'$q$,
  'hello_keys_revoke_reason_chk', 'hello key revoke_reason outside list');
-- Отзыв (challenge гасится тем же UPDATE) → новый живой ключ на том же устройстве допустим (повторного «включения» строки нет)
UPDATE hello_keys SET challenge = NULL, challenge_session_id = NULL, challenge_expires_at = NULL, revoked_at = now(), revoke_reason = 'replaced'
 WHERE id = '00000000-0000-7000-8000-0000000002b1';
INSERT INTO hello_keys (user_id, device_id, public_key, algorithm, source) VALUES
  ('00000000-0000-7000-8000-000000000001', '00000000-0000-7000-8000-0000000000d1', decode(repeat('cd', 294), 'hex'), 'RS256', 'webauthn_prf');
SELECT pg_temp.expect_true(
  (SELECT count(*) FROM hello_keys WHERE device_id = '00000000-0000-7000-8000-0000000000d1') = 2
  AND (SELECT count(*) FROM hello_keys WHERE device_id = '00000000-0000-7000-8000-0000000000d1' AND revoked_at IS NULL) = 1
  AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_hello_keys_set_updated_at' AND NOT tgisinternal)
  AND EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'hello_keys_user_live_idx')
  AND EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'devices_device_key_idx')
  AND has_table_privilege('pos_app', 'hello_keys', 'SELECT') AND has_table_privilege('pos_app', 'hello_keys', 'INSERT')
  AND has_table_privilege('pos_app', 'hello_keys', 'UPDATE') AND has_table_privilege('pos_app', 'hello_keys', 'DELETE')
  AND has_table_privilege('pos_readonly', 'hello_keys', 'SELECT') AND NOT has_table_privilege('pos_readonly', 'hello_keys', 'UPDATE'),
  'hello_keys: revoke then new live key on the same device; updated_at trigger; indexes; pos_app/pos_readonly rights (DATA-172)');

-- =====================================================================================================
-- 8. Сводка
-- =====================================================================================================
SELECT outcome LIKE 'rejected%' AS negative, count(*) AS scenarios FROM ddl_check_log GROUP BY 1 ORDER BY 1;
DO $$
DECLARE v_neg int; v_pos int;
BEGIN
  SELECT count(*) FILTER (WHERE outcome LIKE 'rejected%'), count(*) FILTER (WHERE outcome = 'ok') INTO v_neg, v_pos FROM ddl_check_log;
  IF v_neg < 60 THEN RAISE EXCEPTION 'check_ddl_behavior: выполнено % негативных сценариев (ожидается ≥ 60)', v_neg; END IF;
  RAISE NOTICE 'check_ddl_behavior: OK — негативных сценариев %, позитивных инвариантов %', v_neg, v_pos;
END $$;

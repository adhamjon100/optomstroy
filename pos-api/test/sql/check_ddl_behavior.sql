-- =====================================================================================================
-- pos-api/test/sql/check_ddl_behavior.sql (до RM-C-006 — scripts/) — поведенческие (негативные и позитивные) проверки DDL 0001_init.sql + 0002.
--
-- B-AR-10 (б) (docs/reviews/B_architecture_review.md): перенос в репозиторий scratch-проверок RM-B-005
-- (pos-api/migrations/NOTES.md §9) и проверки исправлений B-AR-01, B-AR-03, B-AR-05, B-AR-09, B-AR-19, B-AR-20.
-- Каждый негативный сценарий — pg_temp.expect_error(sql, метка): ожидается отказ CHECK/UNIQUE/FK/триггера;
-- если отказа нет — RAISE EXCEPTION (код выхода раннера 1). Позитивные инварианты — DO-блоки с RAISE.
-- В конце — сводка числа сценариев; файл ничего не оставляет «наполовину»: ошибка = падение проверки.
--
-- Запуск (одноразовый кластер, схема dev/test — нужна для проверки dev_outbox):
--   node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql \
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
-- роли и права — из 0002_rbac_seed.sql (7 ролей, 77 кодов, 231 пара)
SELECT pg_temp.expect_true((SELECT count(*) FROM roles) = 7 AND (SELECT count(*) FROM permissions) = 77
                           AND (SELECT count(*) FROM role_permissions) = 231, 'rbac seed 7/77/231 (RM-B-008)');
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
-- 6. Сводка
-- =====================================================================================================
SELECT outcome LIKE 'rejected%' AS negative, count(*) AS scenarios FROM ddl_check_log GROUP BY 1 ORDER BY 1;
DO $$
DECLARE v_neg int; v_pos int;
BEGIN
  SELECT count(*) FILTER (WHERE outcome LIKE 'rejected%'), count(*) FILTER (WHERE outcome = 'ok') INTO v_neg, v_pos FROM ddl_check_log;
  IF v_neg < 60 THEN RAISE EXCEPTION 'check_ddl_behavior: выполнено % негативных сценариев (ожидается ≥ 60)', v_neg; END IF;
  RAISE NOTICE 'check_ddl_behavior: OK — негативных сценариев %, позитивных инвариантов %', v_neg, v_pos;
END $$;

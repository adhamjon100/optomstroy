-- docs/erd/schema_v1.sql — DDL схемы БД «Оптомстрой POS» после migrations/0001+0002+0003+0005+0006+0007+0009+0011+0012+0013+0017+0018+0019+0020
-- (RM-C-006 п. 5). Аналог `pg_dump --schema-only`: в embedded-postgres нет клиента pg_dump, Docker на машине
-- нет — DDL выгружен из каталога (pg_get_functiondef/pg_get_constraintdef/pg_get_indexdef/pg_get_triggerdef)
-- скриптом pos-api/test/db/support/schema-dump.ts; проверка — повторное применение к пустой БД даёт тот же
-- отпечаток схемы (test/db/migrate-seed.db-spec.ts, шаг 9). Без данных (seed — migrations/0002, seeds/*.sql).
-- PostgreSQL 17.10; app.env=dev (dev_outbox есть; в prod-схеме её нет — B-AR-09); владелец
-- объектов — pos_migrate; схема pos_meta — журнал мигратора. Источник истины — migrations/*.sql, не этот файл.
-- Перегенерация: cd pos-api && UPDATE_SCHEMA_DUMP=1 npx vitest run --config test/db/vitest.config.ts

SET check_function_bodies = false;
SET client_min_messages = warning;

-- ----------------------------------------------------------------------------------------------------
-- Расширения
-- ----------------------------------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public; -- версия 1.6
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public; -- версия 1.3
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public; -- версия 1.1

-- ----------------------------------------------------------------------------------------------------
-- Роли БД (кластерные объекты; создаются migrations/0001_init.sql или эксплуатацией, 16 §4.3)
-- ----------------------------------------------------------------------------------------------------
-- ROLE pos_app LOGIN
-- ROLE pos_backup LOGIN
-- ROLE pos_migrate LOGIN
-- ROLE pos_readonly LOGIN

-- ----------------------------------------------------------------------------------------------------
-- Схемы
-- ----------------------------------------------------------------------------------------------------
CREATE SCHEMA catalog_sync;
CREATE SCHEMA pos_meta;

-- ----------------------------------------------------------------------------------------------------
-- Enum-типы
-- ----------------------------------------------------------------------------------------------------
CREATE TYPE public.attribute_value_type AS ENUM ('text', 'number', 'boolean', 'list');
CREATE TYPE public.audit_level AS ENUM ('app', 'db');
CREATE TYPE public.barcode_type AS ENUM ('EAN13', 'EAN8', 'UPC', 'CODE128', 'CODE39', 'QR', 'other');
CREATE TYPE public.cart_status AS ENUM ('active', 'parked', 'converted', 'cleared');
CREATE TYPE public.consent_kind AS ENUM ('personal_data', 'sms', 'biometrics_device', 'activity_sphere', 'face_scan');
CREATE TYPE public.contact_kind AS ENUM ('phone', 'address', 'email', 'other');
CREATE TYPE public.customer_link_status AS ENUM ('proposed', 'confirmed', 'rejected', 'conflict');
CREATE TYPE public.customer_onec_status AS ENUM ('n_a', 'pending', 'confirmed', 'rejected', 'duplicate');
CREATE TYPE public.customer_source AS ENUM ('onec', 'pos');
CREATE TYPE public.customer_type AS ENUM ('individual', 'entrepreneur', 'legal');
CREATE TYPE public.delivery_method AS ENUM ('pickup', 'delivery');
CREATE TYPE public.device_platform AS ENUM ('android', 'ios', 'windows');
CREATE TYPE public.discount_kind AS ENUM ('percent', 'fixed_amount', 'price_list');
CREATE TYPE public.discount_source AS ENUM ('onec', 'pos');
CREATE TYPE public.idempotency_status AS ENUM ('in_progress', 'completed');
CREATE TYPE public.image_status AS ENUM ('pending', 'downloading', 'ready', 'failed', 'missing_source');
CREATE TYPE public.invitation_status AS ENUM ('pending', 'accepted', 'revoked', 'expired');
CREATE TYPE public.link_match_method AS ENUM ('phone', 'manual_admin', 'onec_created');
CREATE TYPE public.notification_kind AS ENUM ('sync_error', 'order_status', 'cart_price_changed', 'cart_stock_changed', 'credit_blocked', 'system', 'payment_status', 'return_status');
CREATE TYPE public.onec_sync_state AS ENUM ('unknown', 'pending', 'linked', 'missing', 'ambiguous');
CREATE TYPE public.order_status AS ENUM ('draft', 'submitting', 'submit_failed', 'pending_approval', 'awaiting_payment', 'approved', 'awaiting_shipment', 'shipped', 'partially_returned', 'closed', 'cancelled');
CREATE TYPE public.otp_purpose AS ENUM ('login_or_register', 'step_up', 'phone_change_old', 'phone_change_new', 'customer_link');
CREATE TYPE public.otp_status AS ENUM ('sent', 'verified', 'expired', 'locked', 'failed_delivery', 'superseded');
CREATE TYPE public.outbox_aggregate AS ENUM ('order', 'payment', 'customer', 'return_request');
CREATE TYPE public.outbox_status AS ENUM ('pending', 'sending', 'sent', 'confirmed', 'failed', 'dead', 'cancelled');
CREATE TYPE public.payment_method AS ENUM ('cash', 'qr_bakai', 'credit');
CREATE TYPE public.payment_status AS ENUM ('initiated', 'cash_pending', 'qr_pending', 'qr_shown', 'qr_expired', 'manual_confirm', 'credit', 'received', 'voided', 'refunded');
CREATE TYPE public.print_document_kind AS ENUM ('invoice', 'waybill', 'receipt');
CREATE TYPE public.print_job_status AS ENUM ('queued', 'ready', 'failed', 'unavailable_onec');
CREATE TYPE public.receiver_kind AS ENUM ('customer', 'other_person');
CREATE TYPE public.return_reason AS ENUM ('defect', 'wrong_item', 'not_suitable', 'surplus', 'seller_error', 'other');
CREATE TYPE public.return_request_status AS ENUM ('draft', 'submitted', 'accepted', 'rejected', 'completed');
CREATE TYPE public.role_code AS ENUM ('seller', 'cashier', 'senior_seller', 'admin', 'owner', 'customer', 'integration');
CREATE TYPE public.session_kind AS ENUM ('standard', 'biometric');
CREATE TYPE public.sms_status AS ENUM ('queued', 'sent', 'delivered', 'failed', 'expired');
CREATE TYPE public.status_change_source AS ENUM ('pos_user', 'pos_system', 'onec_sync', 'onec_response');
CREATE TYPE public.step_up_method AS ENUM ('pin', 'biometric', 'otp');
CREATE TYPE public.sync_entity AS ENUM ('categories', 'products', 'variants', 'attributes', 'units', 'barcodes', 'images', 'warehouses', 'stock', 'prices', 'customers', 'receivables', 'sales_history', 'order_status', 'discounts', 'payment_docs', 'return_docs');
CREATE TYPE public.sync_mode AS ENUM ('full', 'incremental', 'manual', 'reconcile');
CREATE TYPE public.sync_run_status AS ENUM ('queued', 'running', 'success', 'partial', 'failed');
CREATE TYPE public.sync_trigger AS ENUM ('schedule', 'manual', 'retry', 'dependency');
CREATE TYPE public.transaction_kind AS ENUM ('order_created', 'order_cancelled', 'payment_received', 'payment_voided', 'refund', 'discount_override', 'credit_sale_approved', 'manual_qr_confirm', 'return_requested');
CREATE TYPE public.transaction_source AS ENUM ('pos', 'onec');
CREATE TYPE public.user_kind AS ENUM ('staff', 'customer');
CREATE TYPE public.user_status AS ENUM ('pending', 'pending_activation', 'active', 'blocked', 'deleted');

-- ----------------------------------------------------------------------------------------------------
-- Конфигурации полнотекстового поиска
-- ----------------------------------------------------------------------------------------------------
CREATE TEXT SEARCH CONFIGURATION public.ru_unaccent (PARSER = pg_catalog."default");
ALTER TEXT SEARCH CONFIGURATION public.ru_unaccent ADD MAPPING FOR asciihword, asciiword, hword_asciipart WITH pg_catalog.english_stem;
ALTER TEXT SEARCH CONFIGURATION public.ru_unaccent ADD MAPPING FOR email, file, float, host, hword_numpart, int, numhword, numword, sfloat, uint, url, url_path, version WITH pg_catalog.simple;
ALTER TEXT SEARCH CONFIGURATION public.ru_unaccent ADD MAPPING FOR hword, hword_part, word WITH public.unaccent, pg_catalog.russian_stem;

-- ----------------------------------------------------------------------------------------------------
-- Последовательности (кроме identity)
-- ----------------------------------------------------------------------------------------------------
CREATE SEQUENCE public.audit_logs_chain_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1;
CREATE SEQUENCE public.orders_number_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1;
CREATE SEQUENCE public.payments_number_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1;
CREATE SEQUENCE public.return_requests_number_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1;

-- ----------------------------------------------------------------------------------------------------
-- Функции (не зависящие от типов-строк таблиц)
-- ----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.append_only_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = 'insufficient_privilege'; END $function$;

CREATE OR REPLACE FUNCTION public.audit_db_changes()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_old jsonb; v_new jsonb; v_row jsonb; v_actions text[]; v_action text;
        v_keep text[]; v_cols text[]; v_filter text; v_before jsonb; v_after jsonb; v_eid uuid; k text;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN v_old := to_jsonb(OLD); END IF;
  IF TG_OP IN ('INSERT','UPDATE') THEN v_new := to_jsonb(NEW); END IF;
  v_row := coalesce(v_new, v_old);
  v_filter := NULLIF(TG_ARGV[2], '');
  IF v_filter IS NOT NULL AND (v_row ->> split_part(v_filter, '=', 1)) IS DISTINCT FROM split_part(v_filter, '=', 2) THEN
    RETURN NULL;
  END IF;
  v_actions := string_to_array(TG_ARGV[0], '|');
  v_action := CASE WHEN cardinality(v_actions) = 1 THEN v_actions[1]
                   WHEN TG_OP = 'INSERT' THEN v_actions[1]
                   WHEN TG_OP = 'UPDATE' THEN v_actions[2]
                   ELSE v_actions[3] END;
  IF coalesce(v_action, '') = '' THEN RETURN NULL; END IF;
  v_keep := string_to_array(NULLIF(TG_ARGV[1], ''), ',');
  IF TG_NARGS > 3 THEN v_cols := TG_ARGV[3:TG_NARGS - 1]; END IF;
  SELECT d.before, d.after INTO v_before, v_after FROM audit_row_diff(v_old, v_new, v_cols, v_keep) d;
  IF v_before IS NULL AND v_after IS NULL THEN RETURN NULL; END IF;
  FOREACH k IN ARRAY coalesce(v_keep, '{}') LOOP
    IF (v_row ->> k) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      v_eid := (v_row ->> k)::uuid;
      EXIT;
    END IF;
  END LOOP;
  PERFORM audit_db_write(v_action, TG_TABLE_NAME, v_eid, v_before, v_after);
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.audit_db_write(p_action text, p_entity_type text, p_entity_id uuid, p_before jsonb, p_after jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE v_actor uuid := audit_guc_uuid('app.actor_id');
        v_role_txt text := audit_guc('app.actor_role');
        v_role role_code;
BEGIN
  IF v_role_txt IS NOT NULL AND v_role_txt = ANY (enum_range(NULL::role_code)::text[]) THEN
    v_role := v_role_txt::role_code;
  END IF;
  INSERT INTO audit_logs (level, actor_user_id, actor_role, session_id, device_id, ip, request_id,
                          action, entity_type, entity_id, before, after, result, severity)
  VALUES ('db', v_actor, v_role, audit_guc_uuid('app.session_id'), audit_guc_uuid('app.device_id'),
          audit_guc_inet('app.ip'), audit_guc('app.request_id'),
          p_action, p_entity_type, p_entity_id, audit_mask_pii(p_before), audit_mask_pii(p_after), 'ok',
          CASE WHEN v_actor IS NULL AND audit_guc('app.system') IS NULL THEN 'warning' ELSE 'info' END);
END $function$;

CREATE OR REPLACE FUNCTION public.audit_guc(p_name text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT NULLIF(current_setting(p_name, true), '')
$function$;

CREATE OR REPLACE FUNCTION public.audit_guc_inet(p_name text)
 RETURNS inet
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v text := NULLIF(current_setting(p_name, true), '');
BEGIN
  RETURN v::inet;
EXCEPTION WHEN others THEN
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.audit_guc_uuid(p_name text)
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE WHEN v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN v::uuid END
    FROM (SELECT NULLIF(current_setting(p_name, true), '') AS v) s
$function$;

CREATE OR REPLACE FUNCTION public.audit_jsonb_pick(j jsonb, p_cols text[], p_keep text[])
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE WHEN j IS NULL THEN NULL ELSE
    (SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
       FROM jsonb_each(j) e
      WHERE CASE WHEN coalesce(cardinality(p_cols), 0) > 0
                 THEN e.key = ANY (p_cols) OR e.key = ANY (coalesce(p_keep, '{}'))
                 ELSE e.key NOT IN ('created_at','updated_at','row_version') END) END
$function$;

CREATE OR REPLACE FUNCTION public.audit_logs_chain()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE prev bytea;
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'audit_logs: insert requires READ COMMITTED';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('audit_chain'));
  NEW.chain_seq := nextval('audit_logs_chain_seq');
  SELECT row_hash INTO prev FROM audit_logs ORDER BY chain_seq DESC LIMIT 1;
  NEW.prev_hash := coalesce(prev, decode(repeat('00', 32), 'hex'));
  NEW.row_hash  := digest(NEW.prev_hash || convert_to(audit_canon(NEW), 'UTF8'), 'sha256');
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.audit_mask_phone(v jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE jsonb_typeof(v)
    WHEN 'string' THEN to_jsonb('+996 *** ** ' || right(v #>> '{}', 2))
    WHEN 'array'  THEN (SELECT coalesce(jsonb_agg(CASE WHEN jsonb_typeof(e) = 'string'
                                                      THEN to_jsonb('+996 *** ** ' || right(e #>> '{}', 2)) ELSE e END), '[]'::jsonb)
                          FROM jsonb_array_elements(v) e)
    ELSE v END
$function$;

CREATE OR REPLACE FUNCTION public.audit_mask_pii(j jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE WHEN j IS NULL THEN NULL ELSE
    (SELECT coalesce(jsonb_object_agg(e.key,
              CASE WHEN e.key LIKE '%phone%' AND e.key NOT LIKE '%hmac%' THEN audit_mask_phone(e.value) ELSE e.value END),
            '{}'::jsonb)
       FROM jsonb_each(j) e) END
$function$;

CREATE OR REPLACE FUNCTION public.audit_row_diff(p_old jsonb, p_new jsonb, p_cols text[], p_keep text[], OUT before jsonb, OUT after jsonb)
 RETURNS record
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE v_old jsonb := audit_jsonb_pick(p_old, p_cols, p_keep);
        v_new jsonb := audit_jsonb_pick(p_new, p_cols, p_keep);
        v_changed text[];
BEGIN
  IF v_old IS NOT NULL AND v_new IS NOT NULL THEN
    SELECT array_agg(o.key) INTO v_changed FROM jsonb_each(v_old) o
     WHERE o.value IS DISTINCT FROM v_new -> o.key AND NOT (o.key = ANY (coalesce(p_keep, '{}')));
    IF v_changed IS NULL THEN RETURN; END IF;
    v_changed := v_changed || coalesce(p_keep, '{}');
    SELECT jsonb_object_agg(key, value) INTO before FROM jsonb_each(v_old) WHERE key = ANY (v_changed);
    SELECT jsonb_object_agg(key, value) INTO after FROM jsonb_each(v_new) WHERE key = ANY (v_changed);
  ELSE
    before := v_old;
    after := v_new;
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION public.audit_system_write(p_action text, p_entity_type text, p_entity_id uuid, p_onec_ref uuid, p_after jsonb, p_result text, p_severity text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE v_role_txt text := audit_guc('app.actor_role');
        v_role role_code;
BEGIN
  IF v_role_txt IS NOT NULL AND v_role_txt = ANY (enum_range(NULL::role_code)::text[]) THEN
    v_role := v_role_txt::role_code;
  END IF;
  INSERT INTO audit_logs (level, actor_user_id, actor_role, session_id, device_id, ip, request_id,
                          action, entity_type, entity_id, onec_ref, before, after, result, severity)
  VALUES ('db', audit_guc_uuid('app.actor_id'), v_role, audit_guc_uuid('app.session_id'),
          audit_guc_uuid('app.device_id'), audit_guc_inet('app.ip'), audit_guc('app.request_id'),
          p_action, p_entity_type, p_entity_id, p_onec_ref, NULL, audit_mask_pii(p_after), p_result, p_severity);
END $function$;

CREATE OR REPLACE FUNCTION public.audit_verify_chain(from_chain_seq bigint, to_chain_seq bigint)
 RETURNS TABLE(ok boolean, broken_at_chain_seq bigint, gaps integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE r audit_logs; prev bytea; prev_seq bigint; g integer := 0;
BEGIN
  SELECT a.row_hash, a.chain_seq INTO prev, prev_seq
    FROM audit_logs a WHERE a.chain_seq < from_chain_seq ORDER BY a.chain_seq DESC LIMIT 1;
  prev := coalesce(prev, decode(repeat('00', 32), 'hex'));
  FOR r IN SELECT * FROM audit_logs a WHERE a.chain_seq BETWEEN from_chain_seq AND to_chain_seq ORDER BY a.chain_seq LOOP
    IF prev_seq IS NOT NULL AND r.chain_seq > prev_seq + 1 THEN g := g + 1; END IF;
    IF r.prev_hash IS DISTINCT FROM prev
       OR r.row_hash IS DISTINCT FROM digest(r.prev_hash || convert_to(audit_canon(r), 'UTF8'), 'sha256') THEN
      RETURN QUERY SELECT false, r.chain_seq, g; RETURN;
    END IF;
    prev := r.row_hash; prev_seq := r.chain_seq;
  END LOOP;
  RETURN QUERY SELECT true, NULL::bigint, g;
END $function$;

CREATE OR REPLACE FUNCTION public.bump_row_version()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.row_version IS NOT DISTINCT FROM OLD.row_version THEN
    NEW.row_version := OLD.row_version + 1;
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION catalog_sync.log_images_deleted()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN
  INSERT INTO catalog_sync.deletions AS d (entity, id, price_list_id, product_id, deleted_at)
  SELECT 'images', o.id, NULL, o.product_id, now() FROM old_rows o WHERE o.product_id IS NOT NULL
  ON CONFLICT (entity, id) DO UPDATE SET deleted_at = EXCLUDED.deleted_at, product_id = EXCLUDED.product_id;
  DELETE FROM catalog_sync.deletions WHERE deleted_at < now() - interval '31 days';
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION catalog_sync.log_prices_deleted()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN
  INSERT INTO catalog_sync.deletions AS d (entity, id, price_list_id, product_id, deleted_at)
  SELECT 'prices', o.id, o.price_list_id, NULL, now() FROM old_rows o
  ON CONFLICT (entity, id) DO UPDATE SET deleted_at = EXCLUDED.deleted_at, price_list_id = EXCLUDED.price_list_id;
  DELETE FROM catalog_sync.deletions WHERE deleted_at < now() - interval '31 days';
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.check_row_version()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF current_user = 'pos_app' AND coalesce(current_setting('app.system', true), '') = '' THEN
    IF NEW.row_version IS DISTINCT FROM OLD.row_version + 1 THEN
      RAISE EXCEPTION '%: row_version must be incremented by 1 (VERSION_CONFLICT protection)', TG_TABLE_NAME
        USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.row_version IS NOT DISTINCT FROM OLD.row_version THEN
    NEW.row_version := OLD.row_version + 1;
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.immutable_unaccent(text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$ SELECT public.unaccent('public.unaccent', $1) $function$;

CREATE OR REPLACE FUNCTION public.integration_tokens_max_active()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('integration_tokens_max_active'));
  IF (SELECT count(*) FROM integration_tokens WHERE revoked_at IS NULL AND expires_at > now()) > 2 THEN
    RAISE EXCEPTION 'integration_tokens: no more than two active tokens are allowed' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.next_payment_public_number(p_at timestamp with time zone DEFAULT now())
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
  n bigint;
  candidate text;
BEGIN
  LOOP
    n := nextval('payments_number_seq');
    candidate := 'PAY-' || to_char(p_at AT TIME ZONE 'Asia/Bishkek', 'YYYY') || '-'
      || lpad((n % 1000000)::text, 6, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM payments WHERE public_number = candidate);
  END LOOP;
  RETURN candidate;
END $function$;

CREATE OR REPLACE FUNCTION public.next_return_public_number(p_at timestamp with time zone DEFAULT now())
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
  n bigint;
  candidate text;
BEGIN
  LOOP
    n := nextval('return_requests_number_seq');
    candidate := 'RET-' || to_char(p_at AT TIME ZONE 'Asia/Bishkek', 'YYYY') || '-'
      || lpad((n % 1000000)::text, 6, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM return_requests WHERE public_number = candidate);
  END LOOP;
  RETURN candidate;
END $function$;

CREATE OR REPLACE FUNCTION public.norm_search(text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$ SELECT trim(regexp_replace(immutable_unaccent(replace(replace(lower($1),'ё','е'),'Ё','Е')), '[[:space:][:punct:]]+', ' ', 'g')) $function$;

CREATE OR REPLACE FUNCTION public.norm_sku(text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$ SELECT upper(regexp_replace($1, '[[:space:]\-_./]+', '', 'g')) $function$;

CREATE OR REPLACE FUNCTION public.onec_outbox_audit()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_action text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NULL;
  END IF;
  v_action := CASE NEW.status
    WHEN 'confirmed' THEN 'outbox.confirmed'
    WHEN 'failed' THEN 'outbox.rejected'
    WHEN 'dead' THEN 'outbox.dead'
    WHEN 'cancelled' THEN 'outbox.cancelled'
  END;
  IF v_action IS NULL THEN
    RETURN NULL;
  END IF;
  PERFORM audit_system_write(
    v_action, 'onec_outbox', NEW.id, NEW.onec_ref,
    jsonb_build_object(
      'aggregateType', NEW.aggregate_type, 'aggregateId', NEW.aggregate_id, 'operation', NEW.operation,
      'statusBefore', OLD.status, 'status', NEW.status, 'attempts', NEW.attempts, 'errorCode', NEW.last_error_code),
    CASE WHEN NEW.status IN ('failed', 'dead') THEN 'error' ELSE 'ok' END,
    CASE WHEN NEW.status = 'dead' THEN 'critical' WHEN NEW.status = 'failed' THEN 'warning' ELSE 'info' END);
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.order_items_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_submitted timestamptz; v_old jsonb; v_new jsonb;
BEGIN
  IF current_setting('app.system', true) IS NOT DISTINCT FROM 'migration' THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;
  SELECT submitted_at INTO v_submitted FROM orders WHERE id = OLD.order_id;
  IF v_submitted IS NOT NULL THEN
    IF TG_OP = 'DELETE' THEN
      RAISE EXCEPTION 'order_items: lines are immutable after submit (order %)', OLD.order_id USING ERRCODE = 'check_violation';
    END IF;
    v_old := to_jsonb(OLD) - ARRAY['shipped_quantity','returned_quantity','onec_line_no','onec_line_total','updated_at'];
    v_new := to_jsonb(NEW) - ARRAY['shipped_quantity','returned_quantity','onec_line_no','onec_line_total','updated_at'];
    IF v_old IS DISTINCT FROM v_new THEN
      RAISE EXCEPTION 'order_items: lines are immutable after submit (order %)', OLD.order_id USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.order_items_totals()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_order uuid; v_status order_status; v_total numeric; v_sum numeric;
BEGIN
  FOREACH v_order IN ARRAY (CASE TG_OP WHEN 'INSERT' THEN ARRAY[NEW.order_id]
                                       WHEN 'DELETE' THEN ARRAY[OLD.order_id]
                                       ELSE ARRAY[OLD.order_id, NEW.order_id] END) LOOP
    SELECT status, total INTO v_status, v_total FROM orders WHERE id = v_order;
    CONTINUE WHEN NOT FOUND OR v_status = 'draft';
    SELECT coalesce(sum(line_total), 0) INTO v_sum FROM order_items WHERE order_id = v_order;
    IF v_sum <> v_total THEN
      RAISE EXCEPTION 'order_items: sum of line_total (%) <> orders.total (%) for order %', v_sum, v_total, v_order
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.orders_audit()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_action text; d record;
        v_cols text[] := ARRAY['status','subtotal','discount_percent','customer_discount_percent','customer_discount_total',
                               'manual_discount_total','discount_total','total','discount_rule_id',
                               'discount_approved_by_user_id','discount_approved_at','discount_reason',
                               'credit_approved_by_user_id','credit_approved_at','credit_reason','credit_due_date',
                               'cancel_reason','cancel_reason_code','cancel_requested_at','cancel_requested_by_user_id',
                               'refund_intent','cancelled_at'];
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT * INTO d FROM audit_row_diff(to_jsonb(OLD), NULL, v_cols, ARRAY['id','public_number']);
    PERFORM audit_db_write('db.orders.delete', TG_TABLE_NAME, OLD.id, d.before, d.after);
    RETURN NULL;
  END IF;
  SELECT * INTO d FROM audit_row_diff(to_jsonb(OLD), to_jsonb(NEW), v_cols, ARRAY['id','public_number']);
  IF d.before IS NULL AND d.after IS NULL THEN RETURN NULL; END IF;
  v_action := CASE
    WHEN NEW.status IS DISTINCT FROM OLD.status THEN 'order.status_changed'
    WHEN NEW.cancel_requested_at IS DISTINCT FROM OLD.cancel_requested_at THEN 'order.cancel_requested'
    ELSE 'db.orders.update' END;
  PERFORM audit_db_write(v_action, TG_TABLE_NAME, NEW.id, d.before, d.after);
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.orders_freeze_financials()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.submitted_at IS NOT NULL AND current_setting('app.system', true) IS DISTINCT FROM 'migration' AND (
       NEW.subtotal IS DISTINCT FROM OLD.subtotal OR NEW.discount_total IS DISTINCT FROM OLD.discount_total
    OR NEW.total IS DISTINCT FROM OLD.total OR NEW.discount_percent IS DISTINCT FROM OLD.discount_percent
    OR NEW.customer_id IS DISTINCT FROM OLD.customer_id OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
    OR NEW.price_list_id IS DISTINCT FROM OLD.price_list_id OR NEW.payment_method IS DISTINCT FROM OLD.payment_method) THEN
    RAISE EXCEPTION 'orders: financial fields are frozen after submit (order %)', OLD.public_number
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.orders_paid_at_once()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.paid_at IS NOT NULL AND NEW.paid_at IS DISTINCT FROM OLD.paid_at
     AND current_setting('app.system', true) IS DISTINCT FROM 'migration' THEN
    RAISE EXCEPTION 'orders: paid_at is set once (order %)', OLD.public_number USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.payments_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'payments: DELETE is forbidden (payment %)', OLD.public_number USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF OLD.status = 'received' AND current_setting('app.system', true) IS DISTINCT FROM 'migration' AND (
       NEW.amount IS DISTINCT FROM OLD.amount OR NEW.method IS DISTINCT FROM OLD.method
    OR NEW.order_id IS DISTINCT FROM OLD.order_id OR NEW.customer_id IS DISTINCT FROM OLD.customer_id
    OR NEW.received_amount IS DISTINCT FROM OLD.received_amount OR NEW.change_amount IS DISTINCT FROM OLD.change_amount) THEN
    RAISE EXCEPTION 'payments: amount/method/order/customer are frozen after received (payment %)', OLD.public_number
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.payments_notify_status()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM pg_notify('payments_status', NEW.id::text);
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.refresh_search_words()
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- Одна реплика за раз; остальные пропускают обновление (false), чтение словаря не блокируется.
  IF NOT pg_try_advisory_xact_lock(hashtext('search_words.refresh')) THEN
    RETURN false;
  END IF;
  REFRESH MATERIALIZED VIEW CONCURRENTLY search_words;
  RETURN true;
END $function$;

CREATE OR REPLACE FUNCTION public.return_request_items_guard()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_status return_request_status; si record; v_other numeric;
BEGIN
  SELECT status INTO v_status FROM return_requests
   WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.return_request_id ELSE NEW.return_request_id END;
  IF FOUND AND v_status <> 'draft' AND current_setting('app.system', true) IS DISTINCT FROM 'migration' THEN
    RAISE EXCEPTION 'return_request_items: lines are immutable after submit (return request is %)', v_status
      USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;

  -- Сериализация по строке реализации (G-KI-14): блокировка до подсчёта других открытых заявок.
  SELECT quantity, returned_quantity, line_total INTO si FROM shipment_items WHERE id = NEW.shipment_item_id
    FOR NO KEY UPDATE;
  SELECT coalesce(sum(i.quantity), 0) INTO v_other
    FROM return_request_items i JOIN return_requests r ON r.id = i.return_request_id
   WHERE i.shipment_item_id = NEW.shipment_item_id AND i.return_request_id <> NEW.return_request_id
     AND r.status IN ('draft','submitted','accepted');
  IF NEW.quantity > si.quantity - si.returned_quantity - v_other THEN
    RAISE EXCEPTION 'return_request_items: quantity % exceeds returnable % (shipment item %)',
      NEW.quantity, si.quantity - si.returned_quantity - v_other, NEW.shipment_item_id USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.line_total IS DISTINCT FROM round_half_up(si.line_total * NEW.quantity / si.quantity, 2) THEN
    RAISE EXCEPTION 'return_request_items: line_total % <> round_half_up(shipment line_total × quantity / shipped quantity, 2) = %',
      NEW.line_total, round_half_up(si.line_total * NEW.quantity / si.quantity, 2) USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.roles_protect_system()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.is_system AND coalesce(current_setting('app.system', true), '') IS DISTINCT FROM 'migration'
     AND (TG_OP = 'DELETE' OR NEW.code IS DISTINCT FROM OLD.code) THEN
    RAISE EXCEPTION 'roles: system role % cannot be deleted or renamed', OLD.code USING ERRCODE = 'restrict_violation';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.round_half_up(v numeric, s integer)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$ SELECT round(v, s) $function$;

CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN NEW.updated_at := now(); RETURN NEW; END $function$;

CREATE OR REPLACE FUNCTION public.sync_node_state_monotonic()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.last_message_number < OLD.last_message_number
     AND current_setting('app.system', true) IS DISTINCT FROM 'migration' THEN
    RAISE EXCEPTION 'sync_node_state: last_message_number must not decrease (node %)', OLD.node
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.sync_run_count(p_counts jsonb, p_key text)
 RETURNS bigint
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE WHEN jsonb_typeof(p_counts -> p_key) = 'number' THEN floor((p_counts ->> p_key)::numeric)::bigint
              ELSE 0 END
$function$;

CREATE OR REPLACE FUNCTION public.sync_runs_audit()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_after jsonb;
        v_changed bigint;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status NOT IN ('success', 'partial', 'failed') THEN
    RETURN NULL;
  END IF;
  v_after := jsonb_build_object(
    'entity', NEW.entity, 'mode', NEW.mode, 'trigger', NEW."trigger", 'status', NEW.status,
    'fetched', sync_run_count(NEW.counts, 'fetched'), 'inserted', sync_run_count(NEW.counts, 'inserted'),
    'updated', sync_run_count(NEW.counts, 'updated'), 'markedDeleted', sync_run_count(NEW.counts, 'markedDeleted'),
    'errors', sync_run_count(NEW.counts, 'errors'), 'durationMs', NEW.duration_ms);
  IF NEW.status = 'failed' THEN
    PERFORM audit_system_write('sync.run.failed', 'sync_runs', NEW.id, NULL, v_after, 'error', 'warning');
    RETURN NULL;
  END IF;
  PERFORM audit_system_write('sync.run.finished', 'sync_runs', NEW.id, NULL, v_after, 'ok', 'info');
  IF NEW.entity IN ('prices', 'stock') THEN
    v_changed := sync_run_count(NEW.counts, 'inserted') + sync_run_count(NEW.counts, 'updated')
               + sync_run_count(NEW.counts, 'markedDeleted');
    IF v_changed > 0 THEN
      PERFORM audit_system_write(
        CASE NEW.entity WHEN 'prices' THEN 'sync.prices.applied' ELSE 'sync.stock.applied' END,
        'sync_runs', NEW.id, NULL,
        jsonb_build_object(
          'syncRunId', NEW.id, 'entity', NEW.entity, 'mode', NEW.mode, 'changed', v_changed,
          'inserted', sync_run_count(NEW.counts, 'inserted'), 'updated', sync_run_count(NEW.counts, 'updated'),
          'markedDeleted', sync_run_count(NEW.counts, 'markedDeleted'),
          'syncedFrom', coalesce(NEW.started_at, NEW.created_at), 'syncedTo', coalesce(NEW.finished_at, now())),
        'ok', 'info');
    END IF;
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.users_audit()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_action text; d record;
BEGIN
  v_action := CASE
    WHEN NEW.status IS DISTINCT FROM OLD.status AND NEW.status = 'deleted' THEN 'user.deleted'
    WHEN NEW.status IS DISTINCT FROM OLD.status AND NEW.status = 'blocked' THEN 'user.blocked'
    WHEN NEW.status IS DISTINCT FROM OLD.status AND OLD.status = 'blocked' AND NEW.status = 'active' THEN 'user.unblocked'
    WHEN NEW.phone_e164 IS DISTINCT FROM OLD.phone_e164 THEN 'user.phone_changed'
  END;
  IF v_action IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO d FROM audit_row_diff(to_jsonb(OLD), to_jsonb(NEW), ARRAY['status','phone_e164'], ARRAY['id']);
  IF d.before IS NULL AND d.after IS NULL THEN RETURN NULL; END IF;
  PERFORM audit_db_write(v_action, TG_TABLE_NAME, NEW.id, d.before, d.after);
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.uuid_generate_v7()
 RETURNS uuid
 LANGUAGE sql
 PARALLEL SAFE
AS $function$
  SELECT encode(
    set_bit(set_bit(
      overlay(uuid_send(gen_random_uuid())
              placing substring(int8send((extract(epoch from clock_timestamp()) * 1000)::bigint) from 3)
              from 1 for 6),
      52, 1), 53, 1), 'hex')::uuid
$function$;


-- ----------------------------------------------------------------------------------------------------
-- Таблицы
-- ----------------------------------------------------------------------------------------------------
CREATE TABLE catalog_sync.deletions (
    entity text NOT NULL,
    id uuid NOT NULL,
    price_list_id uuid,
    product_id uuid,
    deleted_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE pos_meta.schema_migrations (
    version text NOT NULL,
    name text NOT NULL,
    checksum text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_by text DEFAULT CURRENT_USER NOT NULL,
    duration_ms integer NOT NULL
);

CREATE TABLE public.app_pins (
    user_id uuid NOT NULL,
    pin_hash text NOT NULL,
    pepper_version smallint NOT NULL,
    pin_length smallint NOT NULL,
    failed_attempts smallint DEFAULT 0 NOT NULL,
    locked_until timestamp with time zone,
    changed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.app_settings (
    key text NOT NULL,
    value jsonb NOT NULL,
    value_type text NOT NULL,
    is_secret boolean DEFAULT false NOT NULL,
    description_ru text NOT NULL,
    requires_step_up boolean DEFAULT true NOT NULL,
    updated_by_user_id uuid,
    row_version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.audit_anchors (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    anchor_date date NOT NULL,
    last_chain_seq bigint NOT NULL,
    last_row_hash bytea NOT NULL,
    rows_count bigint NOT NULL,
    exported_at timestamp with time zone,
    export_location text,
    verified_at timestamp with time zone,
    verify_result text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.audit_logs (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    seq bigint GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME public.audit_logs_seq_seq START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1) NOT NULL,
    chain_seq bigint NOT NULL,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    level audit_level NOT NULL,
    actor_user_id uuid,
    actor_role role_code,
    on_behalf_of_user_id uuid,
    session_id uuid,
    device_id uuid,
    ip inet,
    app_version text,
    client_platform text,
    request_id text,
    action text NOT NULL,
    entity_type text,
    entity_id uuid,
    onec_ref uuid,
    before jsonb,
    after jsonb,
    result text NOT NULL,
    step_up_method step_up_method,
    reason text,
    severity text NOT NULL,
    prev_hash bytea,
    row_hash bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.barcodes (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    value text NOT NULL,
    product_id uuid NOT NULL,
    variant_id uuid NOT NULL,
    packaging_id uuid,
    type barcode_type DEFAULT 'other'::barcode_type NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.cart_items (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    cart_id uuid NOT NULL,
    variant_id uuid NOT NULL,
    packaging_id uuid,
    quantity numeric(14,3) NOT NULL,
    base_quantity numeric(14,3) NOT NULL,
    price_snapshot numeric(14,2) NOT NULL,
    stock_snapshot numeric(14,3),
    price_changed boolean DEFAULT false NOT NULL,
    stock_insufficient boolean DEFAULT false NOT NULL,
    line_no smallint NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL,
    local_item_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.carts (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    owner_user_id uuid NOT NULL,
    created_by_user_id uuid NOT NULL,
    device_id uuid,
    customer_id uuid,
    warehouse_id uuid NOT NULL,
    price_list_id uuid NOT NULL,
    status cart_status DEFAULT 'active'::cart_status NOT NULL,
    name text,
    requested_discount_percent numeric(5,2) DEFAULT 0 NOT NULL,
    discount_approved_by_user_id uuid,
    discount_approved_at timestamp with time zone,
    comment text,
    items_count_cache integer DEFAULT 0 NOT NULL,
    subtotal_cache numeric(14,2) DEFAULT 0 NOT NULL,
    last_price_check_at timestamp with time zone,
    converted_order_id uuid,
    restored_from_order_id uuid,
    parked_at timestamp with time zone,
    resumed_at timestamp with time zone,
    cleared_at timestamp with time zone,
    expires_at timestamp with time zone,
    row_version integer DEFAULT 1 NOT NULL,
    local_cart_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    receiver_kind receiver_kind DEFAULT 'customer'::receiver_kind NOT NULL,
    receiver_name text,
    receiver_phone_e164 text,
    discount_override_reason text
);

CREATE TABLE public.categories (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    parent_id uuid,
    name text NOT NULL,
    name_norm text GENERATED ALWAYS AS (norm_search(name)) STORED,
    path text NOT NULL,
    depth smallint NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    image_id uuid,
    icon_key text,
    product_count_cache integer DEFAULT 0 NOT NULL,
    is_visible boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.consents (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    user_id uuid NOT NULL,
    kind consent_kind NOT NULL,
    version text NOT NULL,
    text_sha256 bytea NOT NULL,
    granted_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    device_id uuid,
    ip inet,
    app_version text,
    otp_challenge_id uuid,
    face_scan_completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.customer_contacts (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    customer_id uuid NOT NULL,
    kind contact_kind NOT NULL,
    label text,
    value text NOT NULL,
    value_norm text,
    is_primary boolean DEFAULT false NOT NULL,
    onec_line_key text,
    synced_at timestamp with time zone,
    source_hash text,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.customer_links (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    user_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    status customer_link_status DEFAULT 'proposed'::customer_link_status NOT NULL,
    match_method link_match_method NOT NULL,
    matched_phone_e164 text,
    proposed_at timestamp with time zone DEFAULT now() NOT NULL,
    confirmed_by_user_id uuid,
    confirmed_at timestamp with time zone,
    rejected_at timestamp with time zone,
    conflict_candidates uuid[],
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.customers (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone,
    source_hash text,
    source customer_source NOT NULL,
    onec_counterparty_ref uuid,
    onec_agreement_ref uuid,
    name text NOT NULL,
    name_norm text GENERATED ALWAYS AS (norm_search(name)) STORED,
    customer_type customer_type NOT NULL,
    inn text,
    primary_phone_e164 text,
    phones_norm text[] DEFAULT '{}'::text[] NOT NULL,
    default_price_list_id uuid,
    discount_percent numeric(5,2),
    credit_allowed boolean DEFAULT false NOT NULL,
    credit_limit numeric(14,2),
    credit_days smallint,
    is_retail_default boolean DEFAULT false NOT NULL,
    segment text,
    comment text,
    created_by_user_id uuid,
    force_reason text,
    onec_status customer_onec_status DEFAULT 'n_a'::customer_onec_status NOT NULL,
    row_version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.dev_outbox (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    transaction_id text NOT NULL,
    sms_outbox_id uuid,
    phone_e164 text NOT NULL,
    template_key text NOT NULL,
    text text NOT NULL,
    simulated_status_code smallint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.devices (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    user_id uuid NOT NULL,
    device_key text NOT NULL,
    platform device_platform NOT NULL,
    model text,
    os_version text,
    app_version text,
    display_name text,
    biometric_enrolled_at timestamp with time zone,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_seen_at timestamp with time zone,
    last_ip inet,
    revoked_at timestamp with time zone,
    revoked_by_user_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.discount_rules (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone,
    source_hash text,
    source discount_source NOT NULL,
    name text NOT NULL,
    kind discount_kind NOT NULL,
    value numeric(14,2) NOT NULL,
    conditions jsonb DEFAULT '{}'::jsonb NOT NULL,
    applies_automatically boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    valid_from date,
    valid_to date,
    description_ru text,
    row_version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.favorites_customers (
    user_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.favorites_products (
    user_id uuid NOT NULL,
    product_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.idempotency_keys (
    key text NOT NULL,
    subject_key text NOT NULL,
    user_id uuid,
    route text NOT NULL,
    request_hash bytea NOT NULL,
    status idempotency_status DEFAULT 'in_progress'::idempotency_status NOT NULL,
    response_status smallint,
    response_body jsonb,
    resource_id uuid,
    expires_at timestamp with time zone DEFAULT (now() + '24:00:00'::interval) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.integration_tokens (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    name text NOT NULL,
    token_hash bytea NOT NULL,
    token_prefix text NOT NULL,
    scope text DEFAULT 'onec_inbound'::text NOT NULL,
    source text DEFAULT 'operator_script'::text NOT NULL,
    created_by_user_id uuid,
    expires_at timestamp with time zone NOT NULL,
    grace_until timestamp with time zone,
    revoked_at timestamp with time zone,
    revoked_by_user_id uuid,
    revoke_reason text,
    last_used_at timestamp with time zone,
    last_used_ip inet,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.notifications (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    user_id uuid NOT NULL,
    kind notification_kind NOT NULL,
    severity text NOT NULL,
    title_ru text NOT NULL,
    body_ru text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    dedupe_key text NOT NULL,
    read_at timestamp with time zone,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.onec_outbox (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    aggregate_type outbox_aggregate NOT NULL,
    aggregate_id uuid NOT NULL,
    external_id text NOT NULL,
    operation text NOT NULL,
    payload jsonb NOT NULL,
    payload_hash bytea NOT NULL,
    status outbox_status DEFAULT 'pending'::outbox_status NOT NULL,
    attempts smallint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now(),
    lease_until timestamp with time zone,
    locked_by text,
    last_error_code text,
    last_error text,
    onec_response jsonb,
    onec_ref uuid,
    sent_at timestamp with time zone,
    confirmed_at timestamp with time zone,
    dead_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    depends_on_outbox_id uuid,
    priority smallint DEFAULT 100 NOT NULL,
    requested_by_user_id uuid,
    warehouse_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.order_items (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    order_id uuid NOT NULL,
    line_no smallint NOT NULL,
    variant_id uuid NOT NULL,
    product_id uuid NOT NULL,
    packaging_id uuid,
    quantity numeric(14,3) NOT NULL,
    base_quantity numeric(14,3) NOT NULL,
    unit_code_snapshot text NOT NULL,
    packaging_name_snapshot text,
    packaging_factor_snapshot numeric(14,3),
    unit_price numeric(14,2) NOT NULL,
    line_subtotal numeric(14,2) NOT NULL,
    discount_percent numeric(5,2) DEFAULT 0 NOT NULL,
    customer_discount_amount numeric(14,2) DEFAULT 0 NOT NULL,
    manual_discount_amount numeric(14,2) DEFAULT 0 NOT NULL,
    discount_amount numeric(14,2) DEFAULT 0 NOT NULL,
    line_total numeric(14,2) NOT NULL,
    product_name_snapshot text NOT NULL,
    variant_name_snapshot text,
    sku_snapshot text,
    barcode_snapshot text,
    onec_line_no smallint,
    onec_line_total numeric(14,2),
    shipped_quantity numeric(14,3) DEFAULT 0 NOT NULL,
    returned_quantity numeric(14,3) DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.order_status_history (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    order_id uuid NOT NULL,
    from_status order_status,
    to_status order_status NOT NULL,
    source status_change_source NOT NULL,
    actor_user_id uuid,
    onec_status_raw text,
    reason text,
    error_code text,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    request_id text,
    sync_run_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.orders (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    public_number text NOT NULL,
    cart_id uuid,
    status order_status DEFAULT 'draft'::order_status NOT NULL,
    customer_id uuid NOT NULL,
    customer_name_snapshot text,
    customer_phone_snapshot text,
    created_by_user_id uuid NOT NULL,
    created_via text DEFAULT 'staff'::text NOT NULL,
    device_id uuid,
    warehouse_id uuid NOT NULL,
    price_list_id uuid NOT NULL,
    currency character(3) DEFAULT 'KGS'::bpchar NOT NULL,
    subtotal numeric(14,2) NOT NULL,
    discount_percent numeric(5,2) DEFAULT 0 NOT NULL,
    customer_discount_percent numeric(5,2),
    customer_discount_total numeric(14,2) DEFAULT 0 NOT NULL,
    manual_discount_total numeric(14,2) DEFAULT 0 NOT NULL,
    discount_total numeric(14,2) DEFAULT 0 NOT NULL,
    total numeric(14,2) NOT NULL,
    onec_total numeric(14,2),
    totals_differ boolean GENERATED ALWAYS AS (((onec_total IS NOT NULL) AND (onec_total <> total))) STORED,
    discount_rule_id uuid,
    discount_approved_by_user_id uuid,
    discount_approved_at timestamp with time zone,
    discount_reason text,
    payment_method payment_method NOT NULL,
    credit_approved_by_user_id uuid,
    credit_approved_at timestamp with time zone,
    credit_reason text,
    credit_due_date date,
    paid_amount numeric(14,2) DEFAULT 0 NOT NULL,
    paid_at timestamp with time zone,
    is_paid boolean GENERATED ALWAYS AS (((paid_amount >= total) AND (total > (0)::numeric))) STORED,
    delivery_method delivery_method NOT NULL,
    receiver_kind receiver_kind DEFAULT 'customer'::receiver_kind NOT NULL,
    receiver_name text,
    receiver_phone_e164 text,
    delivery_recipient_phone_e164 text,
    delivery_address text,
    delivery_geo point,
    delivery_comment text,
    delivery_date date,
    delivery_time_from time without time zone,
    delivery_time_to time without time zone,
    print_options jsonb DEFAULT '{"invoice": true, "receipt": true, "waybill": true}'::jsonb NOT NULL,
    comment text,
    onec_number text,
    onec_date timestamp with time zone,
    onec_status_raw text,
    onec_last_sync_at timestamp with time zone,
    onec_linked_by_user_id uuid,
    onec_linked_at timestamp with time zone,
    onec_sync_state onec_sync_state DEFAULT 'unknown'::onec_sync_state NOT NULL,
    price_check_at timestamp with time zone,
    onec_check_result jsonb,
    submitted_at timestamp with time zone,
    approved_at timestamp with time zone,
    shipped_at timestamp with time zone,
    closed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    cancel_reason text,
    cancel_reason_code text,
    refund_intent text,
    cancel_requested_at timestamp with time zone,
    cancel_requested_by_user_id uuid,
    submit_error_code text,
    submit_error_message text,
    idempotency_key text,
    row_version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.otp_challenges (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    phone_e164 text NOT NULL,
    user_id uuid,
    purpose otp_purpose NOT NULL,
    code_hmac bytea NOT NULL,
    salt bytea NOT NULL,
    pepper_version smallint NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    attempts smallint DEFAULT 0 NOT NULL,
    status otp_status NOT NULL,
    verified_at timestamp with time zone,
    replayed_at timestamp with time zone,
    registration_token_hash bytea,
    registration_token_expires_at timestamp with time zone,
    sms_outbox_id uuid,
    device_key text,
    ip inet,
    request_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    issued_by_user_id uuid,
    locked_at timestamp with time zone,
    issued_jti uuid
);

CREATE TABLE public.packagings (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    product_id uuid,
    packaging_set_ref uuid,
    unit_id uuid NOT NULL,
    name text NOT NULL,
    factor numeric(14,3) NOT NULL,
    allow_fraction boolean DEFAULT false NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.payment_webhook_events (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    provider text DEFAULT 'bakai'::text NOT NULL,
    provider_event_id text NOT NULL,
    payment_id uuid,
    signature_valid boolean NOT NULL,
    payload jsonb NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    processing_error text,
    source_ip inet,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.payments (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    public_number text NOT NULL,
    order_id uuid,
    customer_id uuid,
    method payment_method NOT NULL,
    qr_provider text,
    status payment_status DEFAULT 'initiated'::payment_status NOT NULL,
    amount numeric(14,2) NOT NULL,
    currency character(3) DEFAULT 'KGS'::bpchar NOT NULL,
    created_by_user_id uuid NOT NULL,
    received_by_user_id uuid,
    received_at timestamp with time zone,
    received_amount numeric(14,2),
    change_amount numeric(14,2),
    bank_amount numeric(14,2),
    qr_payload text,
    qr_expires_at timestamp with time zone,
    qr_provider_ref text,
    bank_reference text,
    qr_status_checked_at timestamp with time zone,
    qr_provider_status_raw text,
    manual_confirmed_by_user_id uuid,
    manual_confirmed_at timestamp with time zone,
    manual_reason text,
    review_reason text,
    voided_by_user_id uuid,
    voided_at timestamp with time zone,
    void_reason text,
    allocation jsonb,
    onec_doc_type text,
    onec_number text,
    onec_date timestamp with time zone,
    idempotency_key text NOT NULL,
    request_id text,
    row_version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    qr_issued_at timestamp with time zone,
    qr_ref_history text[] DEFAULT '{}'::text[] NOT NULL
);

CREATE TABLE public.permissions (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    code text NOT NULL,
    description_ru text NOT NULL,
    requires_step_up boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.price_lists (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    name text NOT NULL,
    currency character(3) DEFAULT 'KGS'::bpchar NOT NULL,
    price_includes_vat boolean,
    is_used_for_sales boolean DEFAULT true NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    visible_to_roles role_code[] DEFAULT '{seller,cashier,senior_seller,admin,owner}'::role_code[] NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.prices (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    variant_id uuid NOT NULL,
    price_list_id uuid NOT NULL,
    packaging_id uuid,
    price numeric(14,2) NOT NULL,
    valid_from timestamp with time zone,
    onec_document_ref uuid,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.print_jobs (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    order_id uuid,
    payment_id uuid,
    document_kind print_document_kind NOT NULL,
    paper text NOT NULL,
    status print_job_status NOT NULL,
    storage_key text,
    sha256 bytea,
    version smallint DEFAULT 1 NOT NULL,
    requested_by_user_id uuid NOT NULL,
    error text,
    printed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.product_attributes (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    value_type attribute_value_type NOT NULL,
    unit_label text,
    is_filterable boolean DEFAULT false NOT NULL,
    is_variant_axis boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.product_images (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    product_id uuid,
    variant_id uuid,
    category_id uuid,
    source_ref text NOT NULL,
    source_version text,
    checksum_sha256 bytea,
    storage_key text,
    original_mime text,
    original_bytes integer,
    width integer,
    height integer,
    sizes jsonb,
    sort_order integer DEFAULT 0 NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    status image_status DEFAULT 'pending'::image_status NOT NULL,
    error text,
    attempts smallint,
    next_attempt_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    onec_is_main boolean
);

CREATE TABLE public.product_variants (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    product_id uuid NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    sku text,
    sku_norm text GENERATED ALWAYS AS (norm_sku(sku)) STORED,
    name_norm text GENERATED ALWAYS AS (norm_search(name)) STORED,
    sort_order integer DEFAULT 0 NOT NULL,
    attributes jsonb DEFAULT '{}'::jsonb NOT NULL,
    primary_image_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.products (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    sku text,
    sku_norm text GENERATED ALWAYS AS (norm_sku(sku)) STORED,
    name text NOT NULL,
    full_name text,
    name_norm text GENERATED ALWAYS AS (norm_search(name)) STORED,
    description text,
    brand text,
    category_id uuid,
    category_path_text text,
    base_unit_id uuid NOT NULL,
    has_variants boolean DEFAULT false NOT NULL,
    is_weighted boolean DEFAULT false NOT NULL,
    multiplicity numeric(14,3),
    min_qty numeric(14,3),
    attributes jsonb DEFAULT '{}'::jsonb NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS ((((setweight(to_tsvector('ru_unaccent'::regconfig, COALESCE(name, ''::text)), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, COALESCE(sku, ''::text)), 'B'::"char")) || setweight(to_tsvector('ru_unaccent'::regconfig, ((COALESCE(brand, ''::text) || ' '::text) || COALESCE(category_path_text, ''::text))), 'C'::"char")) || setweight(to_tsvector('ru_unaccent'::regconfig, COALESCE(description, ''::text)), 'D'::"char"))) STORED,
    primary_image_id uuid,
    is_sellable boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    onec_image_file_ref uuid
);

CREATE TABLE public.rate_limit_counters (
    scope text NOT NULL,
    subject text NOT NULL,
    window_start timestamp with time zone NOT NULL,
    count integer DEFAULT 0 NOT NULL,
    window_end timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.receivable_documents (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    customer_id uuid NOT NULL,
    onec_ref uuid NOT NULL,
    doc_type text NOT NULL,
    kind text NOT NULL,
    status text NOT NULL,
    doc_number text NOT NULL,
    doc_date date NOT NULL,
    amount numeric(14,2) NOT NULL,
    paid numeric(14,2) DEFAULT 0 NOT NULL,
    remaining numeric(14,2) NOT NULL,
    due_date date,
    overdue_days integer,
    order_id uuid,
    onec_snapshot_at timestamp with time zone NOT NULL,
    superseded_at timestamp with time zone,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.receivables (
    customer_id uuid NOT NULL,
    balance numeric(14,2) DEFAULT 0 NOT NULL,
    overdue_amount numeric(14,2),
    overdue_days integer,
    oldest_due_date date,
    currency character(3) DEFAULT 'KGS'::bpchar NOT NULL,
    onec_snapshot_at timestamp with time zone NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.recent_products (
    user_id uuid NOT NULL,
    product_id uuid NOT NULL,
    last_viewed_at timestamp with time zone DEFAULT now() NOT NULL,
    view_count integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.return_request_items (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    return_request_id uuid NOT NULL,
    shipment_item_id uuid NOT NULL,
    variant_id uuid NOT NULL,
    quantity numeric(14,3) NOT NULL,
    unit_price numeric(14,2) NOT NULL,
    line_total numeric(14,2) NOT NULL,
    reason_override return_reason,
    product_name_snapshot text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.return_requests (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    public_number text NOT NULL,
    shipment_id uuid NOT NULL,
    order_id uuid,
    customer_id uuid NOT NULL,
    status return_request_status DEFAULT 'draft'::return_request_status NOT NULL,
    reason return_reason NOT NULL,
    reason_comment text,
    total numeric(14,2) NOT NULL,
    refund_method_expected payment_method,
    created_by_user_id uuid NOT NULL,
    approved_by_user_id uuid,
    approved_at timestamp with time zone,
    accepted_at timestamp with time zone,
    accepted_by_user_id uuid,
    approval_reason text,
    submitted_at timestamp with time zone,
    completed_at timestamp with time zone,
    rejected_at timestamp with time zone,
    onec_number text,
    onec_date timestamp with time zone,
    onec_status_raw text,
    onec_result text,
    reject_reason text,
    rejected_by_user_id uuid,
    idempotency_key text,
    row_version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.role_discount_limits (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    role role_code NOT NULL,
    max_percent numeric(5,2) NOT NULL,
    can_approve_over_limit boolean DEFAULT false NOT NULL,
    approve_max_percent numeric(5,2),
    requires_reason_over_percent numeric(5,2),
    updated_by_user_id uuid,
    row_version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.role_permissions (
    role_id uuid NOT NULL,
    permission_id uuid NOT NULL,
    constraint_json jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.roles (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    code role_code NOT NULL,
    name_ru text NOT NULL,
    is_system boolean DEFAULT true NOT NULL,
    is_assignable boolean DEFAULT true NOT NULL,
    sort_order smallint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.sessions (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    family_id uuid NOT NULL,
    refresh_hash bytea NOT NULL,
    prev_refresh_hash bytea,
    kind session_kind DEFAULT 'standard'::session_kind NOT NULL,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    rotated_at timestamp with time zone,
    last_used_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    idle_expires_at timestamp with time zone NOT NULL,
    step_up_until timestamp with time zone,
    step_up_method step_up_method,
    unlocked_until timestamp with time zone,
    superseded_refresh_hash bytea,
    grace_used_at timestamp with time zone,
    created_from_challenge_id uuid,
    amr text[] DEFAULT '{sms}'::text[] NOT NULL,
    revoked_at timestamp with time zone,
    revoke_reason text,
    ip_last inet,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.shipment_items (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    shipment_id uuid NOT NULL,
    onec_line_no smallint NOT NULL,
    variant_id uuid,
    product_name_snapshot text NOT NULL,
    packaging_id uuid,
    quantity numeric(14,3) NOT NULL,
    base_quantity numeric(14,3) NOT NULL,
    unit_price numeric(14,2) NOT NULL,
    line_total numeric(14,2) NOT NULL,
    discount_amount numeric(14,2) NOT NULL,
    returned_quantity numeric(14,3) DEFAULT 0 NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.shipments (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid NOT NULL,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    onec_doc_type text NOT NULL,
    onec_date timestamp with time zone NOT NULL,
    posted boolean NOT NULL,
    order_id uuid,
    customer_id uuid NOT NULL,
    warehouse_id uuid,
    total numeric(14,2) NOT NULL,
    discount_total numeric(14,2) DEFAULT 0 NOT NULL,
    currency character(3) DEFAULT 'KGS'::bpchar NOT NULL,
    payment_due_date date,
    returned_total numeric(14,2) DEFAULT 0 NOT NULL,
    comment text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.sms_outbox (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    phone_e164 text NOT NULL,
    template_key text NOT NULL,
    provider text DEFAULT 'smspro'::text NOT NULL,
    provider_message_id text NOT NULL,
    provider_status_code smallint,
    delivery_status text,
    status sms_status DEFAULT 'queued'::sms_status NOT NULL,
    attempts smallint DEFAULT 0 NOT NULL,
    sent_at timestamp with time zone,
    delivered_at timestamp with time zone,
    error text,
    otp_challenge_id uuid,
    cost_units numeric(10,2),
    outcome text,
    sms_parts smallint,
    phones_recognized smallint,
    latency_ms integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    request_id text
);

CREATE TABLE public.stock_balances (
    variant_id uuid NOT NULL,
    warehouse_id uuid NOT NULL,
    quantity numeric(14,3) DEFAULT 0 NOT NULL,
    reserved numeric(14,3) DEFAULT 0 NOT NULL,
    available_onec numeric(14,3),
    available numeric(14,3) GENERATED ALWAYS AS (COALESCE(available_onec, (quantity - reserved))) STORED,
    onec_snapshot_at timestamp with time zone NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.sync_entity_versions (
    entity sync_entity NOT NULL,
    onec_key text NOT NULL,
    onec_ref uuid,
    data_version text,
    content_hash bytea NOT NULL,
    local_id uuid,
    seen_in_run_id uuid NOT NULL,
    last_seen_at timestamp with time zone NOT NULL,
    first_seen_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.sync_errors (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    sync_run_id uuid,
    outbox_id uuid,
    entity sync_entity NOT NULL,
    onec_ref uuid,
    onec_code text,
    local_id uuid,
    error_code text NOT NULL,
    message text NOT NULL,
    payload jsonb,
    severity text NOT NULL,
    resolved_at timestamp with time zone,
    resolved_by_user_id uuid,
    resolution text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.sync_node_state (
    node text NOT NULL,
    last_message_number bigint DEFAULT 0 NOT NULL,
    last_ack_at timestamp with time zone,
    last_error_code text,
    last_ping_at timestamp with time zone,
    extension_version text,
    api_version text,
    registration_backlog integer,
    clock_skew_sec integer,
    onec_reachable boolean DEFAULT true NOT NULL,
    unreachable_since timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    auth_error_at timestamp with time zone
);

CREATE TABLE public.sync_runs (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    entity sync_entity NOT NULL,
    mode sync_mode NOT NULL,
    trigger sync_trigger NOT NULL,
    triggered_by_user_id uuid,
    status sync_run_status DEFAULT 'queued'::sync_run_status NOT NULL,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    cursor_from text,
    cursor_to text,
    counts jsonb DEFAULT '{}'::jsonb NOT NULL,
    error_summary text,
    onec_endpoint text,
    worker_job_id text,
    duration_ms integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.sync_state (
    entity sync_entity NOT NULL,
    schedule_cron text NOT NULL,
    last_run_id uuid,
    last_success_run_id uuid,
    last_success_at timestamp with time zone,
    last_cursor text,
    last_source_total integer,
    last_local_total integer,
    consecutive_errors integer DEFAULT 0 NOT NULL,
    last_error_at timestamp with time zone,
    last_error text,
    paused boolean DEFAULT false NOT NULL,
    paused_reason text,
    max_age_warning_sec integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.token_denylist (
    jti uuid NOT NULL,
    token_kind text DEFAULT 'access'::text NOT NULL,
    session_id uuid,
    expires_at timestamp with time zone NOT NULL,
    reason text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.transactions (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    kind transaction_kind NOT NULL,
    source transaction_source NOT NULL,
    order_id uuid,
    payment_id uuid,
    return_request_id uuid,
    shipment_id uuid,
    customer_id uuid,
    actor_user_id uuid,
    amount numeric(14,2) NOT NULL,
    currency character(3) DEFAULT 'KGS'::bpchar NOT NULL,
    payment_method payment_method,
    status_snapshot text NOT NULL,
    title_ru text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    onec_number text,
    onec_doc_type text,
    dedupe_key text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.units (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    qty_precision smallint NOT NULL,
    is_integer_only boolean GENERATED ALWAYS AS ((qty_precision = 0)) STORED,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.user_invitations (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    phone_e164 text NOT NULL,
    role role_code NOT NULL,
    full_name text NOT NULL,
    invited_by_user_id uuid NOT NULL,
    status invitation_status DEFAULT 'pending'::invitation_status NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    accepted_user_id uuid,
    accepted_at timestamp with time zone,
    revoked_at timestamp with time zone,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.user_profiles (
    user_id uuid NOT NULL,
    full_name text NOT NULL,
    birth_year smallint,
    activity_sphere text,
    display_name text,
    locale text DEFAULT 'ru'::text NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    biometrics_enabled boolean DEFAULT false NOT NULL,
    home_warehouse_id uuid,
    row_version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.user_roles (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    user_id uuid NOT NULL,
    role_id uuid NOT NULL,
    granted_by_user_id uuid,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.users (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    phone_e164 text,
    phone_verified_at timestamp with time zone,
    kind user_kind NOT NULL,
    status user_status DEFAULT 'pending'::user_status NOT NULL,
    permissions_version integer DEFAULT 1 NOT NULL,
    invitation_id uuid,
    last_login_at timestamp with time zone,
    blocked_at timestamp with time zone,
    blocked_by_user_id uuid,
    block_reason text,
    deleted_at timestamp with time zone,
    deleted_phone_hmac bytea,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.variant_attribute_values (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    variant_id uuid NOT NULL,
    attribute_id uuid NOT NULL,
    value_text text,
    value_text_norm text GENERATED ALWAYS AS (norm_search(value_text)) STORED,
    value_number numeric(18,6),
    value_bool boolean,
    onec_value_ref uuid,
    synced_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.warehouses (
    id uuid DEFAULT uuid_generate_v7() NOT NULL,
    onec_ref uuid,
    onec_code text,
    onec_data_version text,
    deletion_mark boolean DEFAULT false NOT NULL,
    synced_at timestamp with time zone NOT NULL,
    source_hash text NOT NULL,
    name text NOT NULL,
    short_name text,
    is_active boolean DEFAULT true NOT NULL,
    is_default_for_pos boolean DEFAULT false NOT NULL,
    allow_sales boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


-- ----------------------------------------------------------------------------------------------------
-- Функции с типом-строкой таблицы в сигнатуре
-- ----------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.audit_canon(a audit_logs)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT jsonb_build_object(
    'chain_seq', a.chain_seq, 'occurred_at', to_char(a.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'level', a.level, 'actor_user_id', a.actor_user_id, 'actor_role', a.actor_role,
    'on_behalf_of_user_id', a.on_behalf_of_user_id, 'session_id', a.session_id, 'device_id', a.device_id,
    'ip', a.ip, 'request_id', a.request_id, 'action', a.action, 'entity_type', a.entity_type,
    'entity_id', a.entity_id, 'onec_ref', a.onec_ref, 'before', a.before, 'after', a.after,
    'result', a.result, 'step_up_method', a.step_up_method, 'reason', a.reason, 'severity', a.severity)::text
$function$;


-- ----------------------------------------------------------------------------------------------------
-- Представления и материализованные представления
-- ----------------------------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW public.search_words AS
SELECT w.word,
    count(*)::integer AS freq
   FROM products p
     CROSS JOIN LATERAL regexp_split_to_table(p.name_norm, ' '::text) w(word)
  WHERE NOT p.deletion_mark AND p.is_sellable AND length(w.word) >= 3 AND w.word !~ '^[0-9]+$'::text
  GROUP BY w.word
WITH NO DATA;


-- ----------------------------------------------------------------------------------------------------
-- Первичные ключи, UNIQUE, EXCLUDE, CHECK
-- ----------------------------------------------------------------------------------------------------
ALTER TABLE ONLY catalog_sync.deletions ADD CONSTRAINT deletions_pkey PRIMARY KEY (entity, id);
ALTER TABLE ONLY catalog_sync.deletions ADD CONSTRAINT deletions_entity_chk CHECK ((entity = ANY (ARRAY['prices'::text, 'images'::text])));
ALTER TABLE ONLY pos_meta.schema_migrations ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);
ALTER TABLE ONLY pos_meta.schema_migrations ADD CONSTRAINT schema_migrations_name_key UNIQUE (name);
ALTER TABLE ONLY pos_meta.schema_migrations ADD CONSTRAINT schema_migrations_checksum_check CHECK ((checksum ~ '^[0-9a-f]{64}$'::text));
ALTER TABLE ONLY pos_meta.schema_migrations ADD CONSTRAINT schema_migrations_duration_ms_check CHECK ((duration_ms >= 0));
ALTER TABLE ONLY pos_meta.schema_migrations ADD CONSTRAINT schema_migrations_version_check CHECK ((version ~ '^[0-9]{4}$'::text));
ALTER TABLE ONLY public.app_pins ADD CONSTRAINT app_pins_pkey PRIMARY KEY (user_id);
ALTER TABLE ONLY public.app_pins ADD CONSTRAINT app_pins_pin_length_chk CHECK (((pin_length >= 4) AND (pin_length <= 6)));
ALTER TABLE ONLY public.app_settings ADD CONSTRAINT app_settings_pkey PRIMARY KEY (key);
ALTER TABLE ONLY public.app_settings ADD CONSTRAINT app_settings_key_chk CHECK ((key ~ '^[a-z0-9_.]+$'::text));
ALTER TABLE ONLY public.app_settings ADD CONSTRAINT app_settings_value_type_chk CHECK ((value_type = ANY (ARRAY['boolean'::text, 'integer'::text, 'string'::text, 'json'::text, 'duration'::text, 'money'::text, 'percent'::text])));
ALTER TABLE ONLY public.audit_anchors ADD CONSTRAINT audit_anchors_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.audit_anchors ADD CONSTRAINT audit_anchors_anchor_date_uq UNIQUE (anchor_date);
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_chain_seq_uq UNIQUE (chain_seq);
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_seq_uq UNIQUE (seq);
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_action_chk CHECK ((action ~ '^[a-z_]+(\.[a-z_]+)+$'::text));
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_result_chk CHECK ((result = ANY (ARRAY['ok'::text, 'denied'::text, 'error'::text])));
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_severity_chk CHECK ((severity = ANY (ARRAY['info'::text, 'warning'::text, 'critical'::text])));
ALTER TABLE ONLY public.barcodes ADD CONSTRAINT barcodes_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.barcodes ADD CONSTRAINT barcodes_value_chk CHECK ((value ~ '^[0-9A-Za-z\-\.\ ]{4,64}$'::text));
ALTER TABLE ONLY public.cart_items ADD CONSTRAINT cart_items_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.cart_items ADD CONSTRAINT cart_items_line_uq UNIQUE (cart_id, line_no);
ALTER TABLE ONLY public.cart_items ADD CONSTRAINT cart_items_variant_pack_uq UNIQUE NULLS NOT DISTINCT (cart_id, variant_id, packaging_id);
ALTER TABLE ONLY public.cart_items ADD CONSTRAINT cart_items_base_quantity_chk CHECK ((base_quantity > (0)::numeric));
ALTER TABLE ONLY public.cart_items ADD CONSTRAINT cart_items_price_snapshot_chk CHECK ((price_snapshot >= (0)::numeric));
ALTER TABLE ONLY public.cart_items ADD CONSTRAINT cart_items_quantity_chk CHECK ((quantity > (0)::numeric));
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_comment_chk CHECK ((length(comment) <= 500));
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_discount_override_reason_chk CHECK ((length(discount_override_reason) <= 500));
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_name_chk CHECK ((length(name) <= 80));
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_receiver_chk CHECK (((receiver_kind = 'customer'::receiver_kind) OR ((receiver_name IS NOT NULL) AND (receiver_phone_e164 IS NOT NULL))));
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_receiver_name_chk CHECK ((length(receiver_name) <= 150));
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_receiver_phone_e164_chk CHECK ((receiver_phone_e164 ~ '^\+996[0-9]{9}$'::text));
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_requested_discount_percent_chk CHECK (((requested_discount_percent >= (0)::numeric) AND (requested_discount_percent <= (100)::numeric)));
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_depth_chk CHECK (((depth >= 0) AND (depth <= 10)));
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_path_chk CHECK ((path ~ '^(/[0-9a-f-]{36})+$'::text));
ALTER TABLE ONLY public.consents ADD CONSTRAINT consents_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.consents ADD CONSTRAINT consents_face_scan_chk CHECK (((face_scan_completed_at IS NULL) OR (kind = 'face_scan'::consent_kind)));
ALTER TABLE ONLY public.customer_contacts ADD CONSTRAINT customer_contacts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.customer_links ADD CONSTRAINT customer_links_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.customer_links ADD CONSTRAINT customer_links_user_customer_uq UNIQUE (user_id, customer_id);
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_credit_days_chk CHECK ((credit_days >= 0));
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_credit_limit_chk CHECK ((credit_limit >= (0)::numeric));
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_discount_percent_chk CHECK (((discount_percent >= (0)::numeric) AND (discount_percent <= (100)::numeric)));
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_force_reason_chk CHECK ((length(force_reason) <= 500));
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_inn_chk CHECK ((inn ~ '^[0-9]{14}$'::text));
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_name_chk CHECK (((length(name) >= 2) AND (length(name) <= 200)));
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_primary_phone_e164_chk CHECK ((primary_phone_e164 ~ '^\+996[0-9]{9}$'::text));
ALTER TABLE ONLY public.dev_outbox ADD CONSTRAINT dev_outbox_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.dev_outbox ADD CONSTRAINT dev_outbox_phone_e164_chk CHECK ((phone_e164 ~ '^\+996[0-9]{9}$'::text));
ALTER TABLE ONLY public.dev_outbox ADD CONSTRAINT dev_outbox_template_key_chk CHECK ((template_key = ANY (ARRAY['otp_login'::text, 'otp_step_up'::text, 'otp_phone_change'::text, 'otp_customer_link'::text])));
ALTER TABLE ONLY public.dev_outbox ADD CONSTRAINT dev_outbox_transaction_id_chk CHECK ((transaction_id ~ '^[A-Za-z0-9]{12}$'::text));
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_user_device_key_uq UNIQUE (user_id, device_key);
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_device_key_chk CHECK ((device_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'::text));
ALTER TABLE ONLY public.discount_rules ADD CONSTRAINT discount_rules_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.discount_rules ADD CONSTRAINT discount_rules_value_chk CHECK (((value >= (0)::numeric) AND ((kind <> 'percent'::discount_kind) OR (value <= (100)::numeric))));
ALTER TABLE ONLY public.favorites_customers ADD CONSTRAINT favorites_customers_pkey PRIMARY KEY (user_id, customer_id);
ALTER TABLE ONLY public.favorites_products ADD CONSTRAINT favorites_products_pkey PRIMARY KEY (user_id, product_id);
ALTER TABLE ONLY public.idempotency_keys ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY (key, subject_key, route);
ALTER TABLE ONLY public.idempotency_keys ADD CONSTRAINT idempotency_keys_key_chk CHECK (((length(key) >= 16) AND (length(key) <= 128)));
ALTER TABLE ONLY public.idempotency_keys ADD CONSTRAINT idempotency_keys_subject_key_chk CHECK ((subject_key ~ '^(user:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|reg:[0-9a-f]{64})$'::text));
ALTER TABLE ONLY public.idempotency_keys ADD CONSTRAINT idempotency_keys_subject_user_chk CHECK ((((subject_key ~~ 'user:%'::text) AND (user_id IS NOT NULL) AND (subject_key = ('user:'::text || (user_id)::text))) OR ((subject_key ~~ 'reg:%'::text) AND (user_id IS NULL))));
ALTER TABLE ONLY public.integration_tokens ADD CONSTRAINT integration_tokens_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.integration_tokens ADD CONSTRAINT integration_tokens_name_chk CHECK (((length(name) >= 2) AND (length(name) <= 100)));
ALTER TABLE ONLY public.integration_tokens ADD CONSTRAINT integration_tokens_revoke_reason_chk CHECK ((revoke_reason = ANY (ARRAY['rotated'::text, 'incident'::text, 'disabled'::text, 'expired'::text])));
ALTER TABLE ONLY public.integration_tokens ADD CONSTRAINT integration_tokens_scope_chk CHECK ((scope = 'onec_inbound'::text));
ALTER TABLE ONLY public.integration_tokens ADD CONSTRAINT integration_tokens_source_chk CHECK ((source = 'operator_script'::text));
ALTER TABLE ONLY public.integration_tokens ADD CONSTRAINT integration_tokens_token_prefix_chk CHECK ((length(token_prefix) = 8));
ALTER TABLE ONLY public.integration_tokens ADD CONSTRAINT integration_tokens_ttl_chk CHECK ((expires_at <= (created_at + '180 days'::interval)));
ALTER TABLE ONLY public.notifications ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.notifications ADD CONSTRAINT notifications_user_dedupe_key_uq UNIQUE (user_id, dedupe_key);
ALTER TABLE ONLY public.notifications ADD CONSTRAINT notifications_severity_chk CHECK ((severity = ANY (ARRAY['info'::text, 'warning'::text, 'error'::text])));
ALTER TABLE ONLY public.onec_outbox ADD CONSTRAINT onec_outbox_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.onec_outbox ADD CONSTRAINT onec_outbox_aggregate_op_uq UNIQUE (aggregate_type, aggregate_id, operation);
ALTER TABLE ONLY public.onec_outbox ADD CONSTRAINT onec_outbox_external_op_uq UNIQUE (external_id, operation);
ALTER TABLE ONLY public.onec_outbox ADD CONSTRAINT onec_outbox_external_is_aggregate_chk CHECK ((external_id = (aggregate_id)::text));
ALTER TABLE ONLY public.onec_outbox ADD CONSTRAINT onec_outbox_last_error_code_chk CHECK (((last_error_code = ANY (ARRAY['NOT_FOUND_LOCAL'::text, 'BARCODE_CONFLICT'::text, 'VALIDATION'::text, 'ONEC_REJECTED'::text, 'ONEC_UNAVAILABLE'::text, 'IMAGE_DOWNLOAD'::text, 'HASH_MISMATCH'::text, 'COUNT_MISMATCH'::text, 'DUPLICATE_SUSPECTED'::text, 'OUTBOX_UNCONFIRMED'::text, 'PAYMENT_DOC_VOIDED'::text, 'ORDER_MATCH_AMBIGUOUS'::text, 'NO_WRITE_CHANNEL'::text, 'QR_PAID_AFTER_VOID'::text, 'OTHER'::text])) OR (last_error_code IS NULL)));
ALTER TABLE ONLY public.onec_outbox ADD CONSTRAINT onec_outbox_lease_chk CHECK (((status <> 'sending'::outbox_status) OR (lease_until IS NOT NULL)));
ALTER TABLE ONLY public.onec_outbox ADD CONSTRAINT onec_outbox_operation_chk CHECK ((operation = ANY (ARRAY['create'::text, 'cancel'::text])));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_line_uq UNIQUE (order_id, line_no);
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_variant_pack_uq UNIQUE NULLS NOT DISTINCT (order_id, variant_id, packaging_id);
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_base_quantity_chk CHECK ((base_quantity > (0)::numeric));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_customer_discount_amount_chk CHECK ((customer_discount_amount >= (0)::numeric));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_discount_amount_chk CHECK (((discount_amount >= (0)::numeric) AND (discount_amount <= line_subtotal)));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_discount_percent_chk CHECK (((discount_percent >= (0)::numeric) AND (discount_percent <= (100)::numeric)));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_discount_split_chk CHECK ((discount_amount = (customer_discount_amount + manual_discount_amount)));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_line_no_chk CHECK ((line_no > 0));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_line_subtotal_calc_chk CHECK ((line_subtotal = round_half_up((unit_price * quantity), 2)));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_line_subtotal_chk CHECK ((line_subtotal >= (0)::numeric));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_manual_discount_amount_chk CHECK ((manual_discount_amount >= (0)::numeric));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_quantity_chk CHECK ((quantity > (0)::numeric));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_total_chk CHECK ((line_total = (line_subtotal - discount_amount)));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_unit_price_chk CHECK ((unit_price >= (0)::numeric));
ALTER TABLE ONLY public.order_status_history ADD CONSTRAINT order_status_history_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_cancel_reason_chk CHECK ((length(cancel_reason) <= 500));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_cancel_reason_code_chk CHECK ((cancel_reason_code = ANY (ARRAY['customer_refused'::text, 'duplicate'::text, 'error'::text, 'other'::text])));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_cancel_request_chk CHECK (((cancel_requested_at IS NULL) OR ((cancel_requested_by_user_id IS NOT NULL) AND (cancel_reason_code IS NOT NULL))));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_comment_chk CHECK ((length(comment) <= 500));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_created_via_chk CHECK ((created_via = ANY (ARRAY['staff'::text, 'customer'::text])));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_currency_chk CHECK ((currency = 'KGS'::bpchar));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_customer_channel_chk CHECK (((created_via <> 'customer'::text) OR ((payment_method = ANY (ARRAY['cash'::payment_method, 'qr_bakai'::payment_method])) AND (discount_percent = (0)::numeric) AND (manual_discount_total = (0)::numeric) AND (discount_approved_by_user_id IS NULL) AND (credit_approved_by_user_id IS NULL))));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_customer_discount_percent_chk CHECK (((customer_discount_percent >= (0)::numeric) AND (customer_discount_percent <= (100)::numeric)));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_customer_discount_total_chk CHECK ((customer_discount_total >= (0)::numeric));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_delivery_address_chk CHECK ((length(delivery_address) <= 300));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_delivery_chk CHECK (((delivery_method = 'pickup'::delivery_method) OR (delivery_address IS NOT NULL)));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_delivery_comment_chk CHECK ((length(delivery_comment) <= 200));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_delivery_phone_chk CHECK (((delivery_method <> 'delivery'::delivery_method) OR (delivery_recipient_phone_e164 IS NOT NULL)));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_delivery_recipient_phone_e164_chk CHECK ((delivery_recipient_phone_e164 ~ '^\+996[0-9]{9}$'::text));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_discount_percent_chk CHECK (((discount_percent >= (0)::numeric) AND (discount_percent <= (100)::numeric)));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_discount_split_chk CHECK ((discount_total = (customer_discount_total + manual_discount_total)));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_discount_total_chk CHECK (((discount_total >= (0)::numeric) AND (discount_total <= subtotal)));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_manual_discount_total_chk CHECK ((manual_discount_total >= (0)::numeric));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_onec_sync_ref_chk CHECK (
CASE onec_sync_state
    WHEN 'linked'::onec_sync_state THEN (onec_ref IS NOT NULL)
    WHEN 'missing'::onec_sync_state THEN (onec_ref IS NOT NULL)
    WHEN 'unknown'::onec_sync_state THEN (onec_ref IS NULL)
    WHEN 'ambiguous'::onec_sync_state THEN (onec_ref IS NULL)
    ELSE true
END);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_onec_sync_status_chk CHECK ((((status <> ALL (ARRAY['draft'::order_status, 'submit_failed'::order_status])) OR (onec_sync_state = 'unknown'::onec_sync_state)) AND ((onec_sync_state <> 'unknown'::onec_sync_state) OR (status = ANY (ARRAY['draft'::order_status, 'submitting'::order_status, 'submit_failed'::order_status, 'cancelled'::order_status]))) AND ((onec_sync_state <> 'ambiguous'::onec_sync_state) OR (status = 'submitting'::order_status))));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_paid_amount_chk CHECK ((paid_amount >= (0)::numeric));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_public_number_chk CHECK ((public_number ~ '^POS-[0-9]{4}-[0-9]{6}$'::text));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_receiver_chk CHECK (((receiver_kind = 'customer'::receiver_kind) OR ((receiver_name IS NOT NULL) AND (receiver_phone_e164 IS NOT NULL))));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_receiver_phone_e164_chk CHECK ((receiver_phone_e164 ~ '^\+996[0-9]{9}$'::text));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_refund_intent_chk CHECK ((refund_intent = ANY (ARRAY['none'::text, 'refund'::text, 'advance'::text])));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_subtotal_chk CHECK ((subtotal >= (0)::numeric));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_total_chk CHECK ((total = (subtotal - discount_total)));
ALTER TABLE ONLY public.otp_challenges ADD CONSTRAINT otp_challenges_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.otp_challenges ADD CONSTRAINT otp_challenges_issued_by_chk CHECK (((issued_by_user_id IS NULL) OR ((purpose = 'login_or_register'::otp_purpose) AND (sms_outbox_id IS NULL))));
ALTER TABLE ONLY public.packagings ADD CONSTRAINT packagings_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.packagings ADD CONSTRAINT packagings_factor_chk CHECK ((factor > (0)::numeric));
ALTER TABLE ONLY public.packagings ADD CONSTRAINT packagings_owner_chk CHECK (((product_id IS NOT NULL) OR (packaging_set_ref IS NOT NULL)));
ALTER TABLE ONLY public.payment_webhook_events ADD CONSTRAINT payment_webhook_events_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.payment_webhook_events ADD CONSTRAINT payment_webhook_events_provider_event_uq UNIQUE (provider, provider_event_id);
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_amount_chk CHECK ((amount > (0)::numeric));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_bank_amount_chk CHECK (((bank_amount IS NULL) OR (bank_amount > (0)::numeric)));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_cash_received_chk CHECK (((received_amount IS NULL) OR ((method = 'cash'::payment_method) AND (received_amount >= amount))));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_change_chk CHECK (((change_amount IS NULL) OR (change_amount = (received_amount - amount))));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_currency_chk CHECK ((currency = 'KGS'::bpchar));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_manual_chk CHECK (((status <> 'manual_confirm'::payment_status) OR (review_reason IS NOT NULL) OR (manual_confirmed_by_user_id IS NOT NULL)));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_public_number_chk CHECK ((public_number ~ '^PAY-[0-9]{4}-[0-9]{6}$'::text));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_qr_provider_chk CHECK (((method = 'qr_bakai'::payment_method) = (qr_provider IS NOT NULL)));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_qr_provider_status_raw_chk CHECK ((length(qr_provider_status_raw) <= 100));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_qr_provider_value_chk CHECK ((qr_provider = ANY (ARRAY['none'::text, 'onec'::text, 'bakai'::text])));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_review_reason_chk CHECK ((review_reason = ANY (ARRAY['amount_mismatch'::text, 'unknown_reference'::text, 'no_webhook'::text, 'late_payment'::text])));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_target_chk CHECK (((order_id IS NOT NULL) OR (customer_id IS NOT NULL)));
ALTER TABLE ONLY public.permissions ADD CONSTRAINT permissions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.permissions ADD CONSTRAINT permissions_code_chk CHECK ((code ~ '^[a-z_]+(\.[a-z_]+)+$'::text));
ALTER TABLE ONLY public.price_lists ADD CONSTRAINT price_lists_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.price_lists ADD CONSTRAINT price_lists_currency_chk CHECK ((currency = 'KGS'::bpchar));
ALTER TABLE ONLY public.prices ADD CONSTRAINT prices_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.prices ADD CONSTRAINT prices_price_chk CHECK ((price >= (0)::numeric));
ALTER TABLE ONLY public.print_jobs ADD CONSTRAINT print_jobs_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.print_jobs ADD CONSTRAINT print_jobs_document_version_uq UNIQUE NULLS NOT DISTINCT (order_id, payment_id, document_kind, paper, version);
ALTER TABLE ONLY public.print_jobs ADD CONSTRAINT print_jobs_paper_chk CHECK ((paper = ANY (ARRAY['a4'::text, 'thermal80'::text])));
ALTER TABLE ONLY public.print_jobs ADD CONSTRAINT print_jobs_target_chk CHECK ((num_nonnulls(order_id, payment_id) = 1));
ALTER TABLE ONLY public.product_attributes ADD CONSTRAINT product_attributes_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.product_images ADD CONSTRAINT product_images_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.product_images ADD CONSTRAINT product_images_owner_chk CHECK ((num_nonnulls(product_id, category_id) = 1));
ALTER TABLE ONLY public.product_images ADD CONSTRAINT product_images_variant_needs_product_chk CHECK (((variant_id IS NULL) OR (product_id IS NOT NULL)));
ALTER TABLE ONLY public.product_variants ADD CONSTRAINT product_variants_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.product_variants ADD CONSTRAINT product_variants_default_or_ref_chk CHECK ((is_default OR (onec_ref IS NOT NULL)));
ALTER TABLE ONLY public.products ADD CONSTRAINT products_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.products ADD CONSTRAINT products_min_qty_chk CHECK ((min_qty > (0)::numeric));
ALTER TABLE ONLY public.products ADD CONSTRAINT products_multiplicity_chk CHECK ((multiplicity > (0)::numeric));
ALTER TABLE ONLY public.rate_limit_counters ADD CONSTRAINT rate_limit_counters_pkey PRIMARY KEY (scope, subject, window_start);
ALTER TABLE ONLY public.rate_limit_counters ADD CONSTRAINT rate_limit_counters_scope_chk CHECK ((scope = ANY (ARRAY['otp_phone_15m'::text, 'otp_phone_24h'::text, 'otp_ip_1h'::text, 'otp_device_24h'::text, 'login_ip_1h'::text, 'step_up_user_1h'::text, 'webhook_ip_1m'::text, 'otp_ip_10m'::text, 'otp_ip_24h'::text, 'otp_device_10m'::text, 'otp_global_1m'::text, 'otp_verify_ip_10m'::text, 'pin_user_device_10m'::text, 'admin_user_1m'::text])));
ALTER TABLE ONLY public.receivable_documents ADD CONSTRAINT receivable_documents_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.receivable_documents ADD CONSTRAINT receivable_documents_customer_onec_ref_uq UNIQUE (customer_id, onec_ref);
ALTER TABLE ONLY public.receivable_documents ADD CONSTRAINT receivable_documents_kind_chk CHECK ((kind = ANY (ARRAY['invoice'::text, 'payment'::text, 'return'::text, 'discount'::text, 'adjustment'::text])));
ALTER TABLE ONLY public.receivable_documents ADD CONSTRAINT receivable_documents_status_chk CHECK ((status = ANY (ARRAY['posted'::text, 'not_posted'::text, 'due'::text])));
ALTER TABLE ONLY public.receivables ADD CONSTRAINT receivables_pkey PRIMARY KEY (customer_id);
ALTER TABLE ONLY public.receivables ADD CONSTRAINT receivables_overdue_amount_chk CHECK (((overdue_amount IS NULL) OR ((overdue_amount >= (0)::numeric) AND (overdue_amount <= GREATEST(balance, (0)::numeric)))));
ALTER TABLE ONLY public.receivables ADD CONSTRAINT receivables_overdue_days_chk CHECK ((overdue_days >= 0));
ALTER TABLE ONLY public.recent_products ADD CONSTRAINT recent_products_pkey PRIMARY KEY (user_id, product_id);
ALTER TABLE ONLY public.return_request_items ADD CONSTRAINT return_request_items_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.return_request_items ADD CONSTRAINT return_request_items_request_shipment_item_uq UNIQUE (return_request_id, shipment_item_id);
ALTER TABLE ONLY public.return_request_items ADD CONSTRAINT return_request_items_quantity_chk CHECK ((quantity > (0)::numeric));
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_approval_reason_chk CHECK ((approval_reason = 'return_threshold_exceeded'::text));
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_onec_result_chk CHECK ((onec_result = ANY (ARRAY['money_refunded'::text, 'offset_against_debt'::text, 'pending'::text])));
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_public_number_chk CHECK ((public_number ~ '^RET-[0-9]{4}-[0-9]{6}$'::text));
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_reason_comment_chk CHECK (((reason <> 'other'::return_reason) OR (reason_comment IS NOT NULL)));
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_reason_comment_len_chk CHECK ((length(reason_comment) <= 500));
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_total_chk CHECK ((total >= (0)::numeric));
ALTER TABLE ONLY public.role_discount_limits ADD CONSTRAINT role_discount_limits_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.role_discount_limits ADD CONSTRAINT role_discount_limits_approve_max_percent_chk CHECK (((approve_max_percent >= (0)::numeric) AND (approve_max_percent <= (100)::numeric)));
ALTER TABLE ONLY public.role_discount_limits ADD CONSTRAINT role_discount_limits_max_percent_chk CHECK (((max_percent >= (0)::numeric) AND (max_percent <= (100)::numeric)));
ALTER TABLE ONLY public.role_discount_limits ADD CONSTRAINT role_discount_limits_reason_percent_chk CHECK (((requires_reason_over_percent >= (0)::numeric) AND (requires_reason_over_percent <= (100)::numeric)));
ALTER TABLE ONLY public.role_permissions ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (role_id, permission_id);
ALTER TABLE ONLY public.roles ADD CONSTRAINT roles_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sessions ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sessions ADD CONSTRAINT sessions_amr_chk CHECK ((amr <@ ARRAY['sms'::text, 'pin'::text, 'bio'::text, 'admin_code'::text]));
ALTER TABLE ONLY public.sessions ADD CONSTRAINT sessions_revoke_reason_chk CHECK ((revoke_reason = ANY (ARRAY['logout'::text, 'logout_all'::text, 'reuse_detected'::text, 'admin'::text, 'phone_changed'::text, 'role_changed'::text, 'expired'::text, 'device_revoked'::text, 'blocked'::text, 'session_limit'::text, 'device_mismatch'::text, 'biometric_invalidated'::text, 'refresh_replay'::text])));
ALTER TABLE ONLY public.shipment_items ADD CONSTRAINT shipment_items_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.shipment_items ADD CONSTRAINT shipment_items_line_uq UNIQUE (shipment_id, onec_line_no);
ALTER TABLE ONLY public.shipments ADD CONSTRAINT shipments_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sms_outbox ADD CONSTRAINT sms_outbox_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sms_outbox ADD CONSTRAINT sms_outbox_latency_ms_chk CHECK ((latency_ms >= 0));
ALTER TABLE ONLY public.sms_outbox ADD CONSTRAINT sms_outbox_outcome_chk CHECK ((outcome = ANY (ARRAY['ACCEPTED'::text, 'ACCEPTED_TEST'::text, 'RETRYABLE'::text, 'PERMANENT'::text, 'CONFIG_ERROR'::text, 'INSUFFICIENT_FUNDS'::text, 'INVALID_PHONE'::text, 'DUPLICATE_ID'::text])));
ALTER TABLE ONLY public.sms_outbox ADD CONSTRAINT sms_outbox_phones_recognized_chk CHECK ((phones_recognized >= 0));
ALTER TABLE ONLY public.sms_outbox ADD CONSTRAINT sms_outbox_provider_chk CHECK ((provider = ANY (ARRAY['smspro'::text, 'fake'::text])));
ALTER TABLE ONLY public.sms_outbox ADD CONSTRAINT sms_outbox_provider_message_id_chk CHECK ((provider_message_id ~ '^[A-Za-z0-9]{12}$'::text));
ALTER TABLE ONLY public.sms_outbox ADD CONSTRAINT sms_outbox_sms_parts_chk CHECK ((sms_parts >= 0));
ALTER TABLE ONLY public.sms_outbox ADD CONSTRAINT sms_outbox_template_key_chk CHECK ((template_key = ANY (ARRAY['otp_login'::text, 'otp_step_up'::text, 'otp_phone_change'::text, 'otp_customer_link'::text])));
ALTER TABLE ONLY public.stock_balances ADD CONSTRAINT stock_balances_pkey PRIMARY KEY (variant_id, warehouse_id);
ALTER TABLE ONLY public.sync_entity_versions ADD CONSTRAINT sync_entity_versions_pkey PRIMARY KEY (entity, onec_key);
ALTER TABLE ONLY public.sync_entity_versions ADD CONSTRAINT sync_entity_versions_onec_key_chk CHECK (((length(onec_key) >= 1) AND (length(onec_key) <= 150)));
ALTER TABLE ONLY public.sync_entity_versions ADD CONSTRAINT sync_entity_versions_ref_key_chk CHECK (((onec_ref IS NULL) OR (onec_key = (onec_ref)::text)));
ALTER TABLE ONLY public.sync_errors ADD CONSTRAINT sync_errors_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sync_errors ADD CONSTRAINT sync_errors_error_code_chk CHECK ((error_code = ANY (ARRAY['NOT_FOUND_LOCAL'::text, 'BARCODE_CONFLICT'::text, 'VALIDATION'::text, 'ONEC_REJECTED'::text, 'ONEC_UNAVAILABLE'::text, 'IMAGE_DOWNLOAD'::text, 'HASH_MISMATCH'::text, 'COUNT_MISMATCH'::text, 'DUPLICATE_SUSPECTED'::text, 'OUTBOX_UNCONFIRMED'::text, 'PAYMENT_DOC_VOIDED'::text, 'ORDER_MATCH_AMBIGUOUS'::text, 'NO_WRITE_CHANNEL'::text, 'QR_PAID_AFTER_VOID'::text, 'OTHER'::text])));
ALTER TABLE ONLY public.sync_errors ADD CONSTRAINT sync_errors_severity_chk CHECK ((severity = ANY (ARRAY['warning'::text, 'error'::text])));
ALTER TABLE ONLY public.sync_node_state ADD CONSTRAINT sync_node_state_pkey PRIMARY KEY (node);
ALTER TABLE ONLY public.sync_node_state ADD CONSTRAINT sync_node_state_last_error_code_chk CHECK (((last_error_code = ANY (ARRAY['NOT_FOUND_LOCAL'::text, 'BARCODE_CONFLICT'::text, 'VALIDATION'::text, 'ONEC_REJECTED'::text, 'ONEC_UNAVAILABLE'::text, 'IMAGE_DOWNLOAD'::text, 'HASH_MISMATCH'::text, 'COUNT_MISMATCH'::text, 'DUPLICATE_SUSPECTED'::text, 'OUTBOX_UNCONFIRMED'::text, 'PAYMENT_DOC_VOIDED'::text, 'ORDER_MATCH_AMBIGUOUS'::text, 'NO_WRITE_CHANNEL'::text, 'QR_PAID_AFTER_VOID'::text, 'OTHER'::text])) OR (last_error_code IS NULL)));
ALTER TABLE ONLY public.sync_node_state ADD CONSTRAINT sync_node_state_last_message_number_chk CHECK ((last_message_number >= 0));
ALTER TABLE ONLY public.sync_node_state ADD CONSTRAINT sync_node_state_node_chk CHECK ((node ~ '^[a-z0-9_-]{1,40}$'::text));
ALTER TABLE ONLY public.sync_node_state ADD CONSTRAINT sync_node_state_registration_backlog_chk CHECK ((registration_backlog >= 0));
ALTER TABLE ONLY public.sync_runs ADD CONSTRAINT sync_runs_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sync_state ADD CONSTRAINT sync_state_pkey PRIMARY KEY (entity);
ALTER TABLE ONLY public.token_denylist ADD CONSTRAINT token_denylist_pkey PRIMARY KEY (jti);
ALTER TABLE ONLY public.token_denylist ADD CONSTRAINT token_denylist_reason_chk CHECK ((reason = ANY (ARRAY['logout'::text, 'logout_all'::text, 'role_changed'::text, 'blocked'::text, 'used'::text, 'revoked'::text])));
ALTER TABLE ONLY public.token_denylist ADD CONSTRAINT token_denylist_token_kind_chk CHECK ((token_kind = ANY (ARRAY['access'::text, 'registration'::text, 'step_up'::text])));
ALTER TABLE ONLY public.token_denylist ADD CONSTRAINT token_denylist_used_registration_chk CHECK (((reason <> 'used'::text) OR (token_kind = 'registration'::text)));
ALTER TABLE ONLY public.transactions ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.transactions ADD CONSTRAINT transactions_dedupe_key_uq UNIQUE (dedupe_key);
ALTER TABLE ONLY public.transactions ADD CONSTRAINT transactions_currency_chk CHECK ((currency = 'KGS'::bpchar));
ALTER TABLE ONLY public.transactions ADD CONSTRAINT transactions_link_chk CHECK ((num_nonnulls(order_id, payment_id, return_request_id, shipment_id) >= 1));
ALTER TABLE ONLY public.units ADD CONSTRAINT units_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.units ADD CONSTRAINT units_qty_precision_chk CHECK (((qty_precision >= 0) AND (qty_precision <= 3)));
ALTER TABLE ONLY public.user_invitations ADD CONSTRAINT user_invitations_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.user_invitations ADD CONSTRAINT user_invitations_full_name_chk CHECK (((length(full_name) >= 2) AND (length(full_name) <= 150)));
ALTER TABLE ONLY public.user_invitations ADD CONSTRAINT user_invitations_note_chk CHECK ((length(note) <= 200));
ALTER TABLE ONLY public.user_invitations ADD CONSTRAINT user_invitations_phone_e164_chk CHECK ((phone_e164 ~ '^\+996[0-9]{9}$'::text));
ALTER TABLE ONLY public.user_invitations ADD CONSTRAINT user_invitations_role_chk CHECK ((role = ANY (ARRAY['seller'::role_code, 'cashier'::role_code, 'senior_seller'::role_code, 'admin'::role_code, 'owner'::role_code])));
ALTER TABLE ONLY public.user_profiles ADD CONSTRAINT user_profiles_pkey PRIMARY KEY (user_id);
ALTER TABLE ONLY public.user_profiles ADD CONSTRAINT user_profiles_activity_sphere_chk CHECK ((length(activity_sphere) <= 100));
ALTER TABLE ONLY public.user_profiles ADD CONSTRAINT user_profiles_birth_year_chk CHECK (((birth_year >= 1920) AND (birth_year <= 2100)));
ALTER TABLE ONLY public.user_profiles ADD CONSTRAINT user_profiles_full_name_chk CHECK (((length(full_name) >= 2) AND (length(full_name) <= 150)));
ALTER TABLE ONLY public.user_profiles ADD CONSTRAINT user_profiles_locale_chk CHECK ((locale = ANY (ARRAY['ru'::text, 'ky'::text, 'en'::text])));
ALTER TABLE ONLY public.user_roles ADD CONSTRAINT user_roles_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.users ADD CONSTRAINT users_phone_e164_chk CHECK ((phone_e164 ~ '^\+996[0-9]{9}$'::text));
ALTER TABLE ONLY public.variant_attribute_values ADD CONSTRAINT variant_attribute_values_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.variant_attribute_values ADD CONSTRAINT variant_attribute_values_variant_attribute_uq UNIQUE (variant_id, attribute_id);
ALTER TABLE ONLY public.variant_attribute_values ADD CONSTRAINT variant_attribute_values_one_value_chk CHECK ((num_nonnulls(value_text, value_number, value_bool) = 1));
ALTER TABLE ONLY public.warehouses ADD CONSTRAINT warehouses_pkey PRIMARY KEY (id);

-- ----------------------------------------------------------------------------------------------------
-- Индексы
-- ----------------------------------------------------------------------------------------------------
CREATE INDEX deletions_deleted_at_idx ON catalog_sync.deletions USING btree (deleted_at);
CREATE INDEX deletions_entity_deleted_idx ON catalog_sync.deletions USING btree (entity, deleted_at, id);
CREATE INDEX audit_logs_action_idx ON public.audit_logs USING btree (action, occurred_at DESC);
CREATE INDEX audit_logs_actor_idx ON public.audit_logs USING btree (actor_user_id, occurred_at DESC);
CREATE INDEX audit_logs_entity_idx ON public.audit_logs USING btree (entity_type, entity_id, occurred_at);
CREATE INDEX audit_logs_occurred_brin ON public.audit_logs USING brin (occurred_at);
CREATE INDEX barcodes_packaging_idx ON public.barcodes USING btree (packaging_id);
CREATE INDEX barcodes_product_idx ON public.barcodes USING btree (product_id);
CREATE INDEX barcodes_updated_at_id_idx ON public.barcodes USING btree (updated_at, id);
CREATE INDEX barcodes_updated_at_idx ON public.barcodes USING btree (updated_at);
CREATE UNIQUE INDEX barcodes_value_uq ON public.barcodes USING btree (value);
CREATE INDEX barcodes_variant_idx ON public.barcodes USING btree (variant_id);
CREATE INDEX cart_items_variant_idx ON public.cart_items USING btree (variant_id);
CREATE UNIQUE INDEX carts_active_uq ON public.carts USING btree (owner_user_id) WHERE (status = 'active'::cart_status);
CREATE UNIQUE INDEX carts_local_id_uq ON public.carts USING btree (local_cart_id) WHERE (local_cart_id IS NOT NULL);
CREATE INDEX carts_owner_status_idx ON public.carts USING btree (owner_user_id, status);
CREATE INDEX carts_parked_customer_idx ON public.carts USING btree (customer_id) WHERE (status = 'parked'::cart_status);
CREATE INDEX carts_parked_expires_idx ON public.carts USING btree (status, expires_at) WHERE (status = 'parked'::cart_status);
CREATE INDEX categories_name_norm_trgm ON public.categories USING gin (name_norm gin_trgm_ops);
CREATE UNIQUE INDEX categories_onec_ref_uq ON public.categories USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX categories_parent_idx ON public.categories USING btree (parent_id) WHERE (NOT deletion_mark);
CREATE INDEX categories_path_idx ON public.categories USING btree (path text_pattern_ops);
CREATE INDEX categories_updated_at_id_idx ON public.categories USING btree (updated_at, id);
CREATE INDEX categories_updated_at_idx ON public.categories USING btree (updated_at);
CREATE UNIQUE INDEX consents_active_uq ON public.consents USING btree (user_id, kind, device_id) NULLS NOT DISTINCT WHERE (revoked_at IS NULL);
CREATE INDEX consents_device_idx ON public.consents USING btree (device_id);
CREATE INDEX consents_user_idx ON public.consents USING btree (user_id);
CREATE INDEX customer_contacts_customer_idx ON public.customer_contacts USING btree (customer_id);
CREATE UNIQUE INDEX customer_contacts_customer_kind_value_uq ON public.customer_contacts USING btree (customer_id, kind, value_norm) WHERE ((deleted_at IS NULL) AND (value_norm IS NOT NULL));
CREATE INDEX customer_contacts_phone_idx ON public.customer_contacts USING btree (value_norm) WHERE (kind = 'phone'::contact_kind);
CREATE UNIQUE INDEX customer_links_confirmed_uq ON public.customer_links USING btree (user_id) WHERE (status = 'confirmed'::customer_link_status);
CREATE INDEX customer_links_customer_status_idx ON public.customer_links USING btree (customer_id, status);
CREATE INDEX customer_links_queue_idx ON public.customer_links USING btree (status) WHERE (status = ANY (ARRAY['proposed'::customer_link_status, 'conflict'::customer_link_status]));
CREATE INDEX customers_default_price_list_idx ON public.customers USING btree (default_price_list_id);
CREATE INDEX customers_deletion_updated_idx ON public.customers USING btree (deletion_mark, updated_at);
CREATE INDEX customers_inn_idx ON public.customers USING btree (inn) WHERE (inn IS NOT NULL);
CREATE INDEX customers_name_norm_trgm ON public.customers USING gin (name_norm gin_trgm_ops);
CREATE UNIQUE INDEX customers_onec_code_uq ON public.customers USING btree (onec_code) WHERE (onec_code IS NOT NULL);
CREATE UNIQUE INDEX customers_onec_ref_uq ON public.customers USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX customers_phones_norm_gin ON public.customers USING gin (phones_norm);
CREATE INDEX customers_pos_pending_idx ON public.customers USING btree (source, onec_status) WHERE (source = 'pos'::customer_source);
CREATE UNIQUE INDEX customers_retail_default_uq ON public.customers USING btree (is_retail_default) WHERE is_retail_default;
CREATE INDEX dev_outbox_created_idx ON public.dev_outbox USING btree (created_at);
CREATE INDEX dev_outbox_phone_created_idx ON public.dev_outbox USING btree (phone_e164, created_at DESC);
CREATE INDEX dev_outbox_sms_outbox_idx ON public.dev_outbox USING btree (sms_outbox_id);
CREATE UNIQUE INDEX dev_outbox_transaction_id_uq ON public.dev_outbox USING btree (transaction_id);
CREATE INDEX devices_user_active_idx ON public.devices USING btree (user_id) WHERE (revoked_at IS NULL);
CREATE INDEX discount_rules_active_period_idx ON public.discount_rules USING btree (is_active, valid_from, valid_to);
CREATE INDEX discount_rules_conditions_gin ON public.discount_rules USING gin (conditions jsonb_path_ops);
CREATE UNIQUE INDEX discount_rules_onec_ref_uq ON public.discount_rules USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX favorites_customers_customer_idx ON public.favorites_customers USING btree (customer_id);
CREATE INDEX favorites_customers_user_created_idx ON public.favorites_customers USING btree (user_id, created_at DESC);
CREATE INDEX favorites_products_product_idx ON public.favorites_products USING btree (product_id);
CREATE INDEX favorites_products_user_created_idx ON public.favorites_products USING btree (user_id, created_at DESC);
CREATE INDEX idempotency_keys_expires_idx ON public.idempotency_keys USING btree (expires_at);
CREATE INDEX idempotency_keys_user_idx ON public.idempotency_keys USING btree (user_id) WHERE (user_id IS NOT NULL);
CREATE INDEX integration_tokens_expires_active_idx ON public.integration_tokens USING btree (expires_at) WHERE (revoked_at IS NULL);
CREATE UNIQUE INDEX integration_tokens_token_hash_uq ON public.integration_tokens USING btree (token_hash);
CREATE INDEX notifications_expires_idx ON public.notifications USING btree (expires_at);
CREATE INDEX notifications_user_unread_idx ON public.notifications USING btree (user_id, read_at, created_at DESC);
CREATE INDEX onec_outbox_aggregate_idx ON public.onec_outbox USING btree (aggregate_type, aggregate_id);
CREATE INDEX onec_outbox_attention_idx ON public.onec_outbox USING btree (status, created_at) WHERE (status = ANY (ARRAY['failed'::outbox_status, 'dead'::outbox_status]));
CREATE INDEX onec_outbox_confirmed_idx ON public.onec_outbox USING btree (confirmed_at);
CREATE INDEX onec_outbox_depends_on_idx ON public.onec_outbox USING btree (depends_on_outbox_id);
CREATE INDEX onec_outbox_dispatch_idx ON public.onec_outbox USING btree (status, next_attempt_at, priority) WHERE (status = 'pending'::outbox_status);
CREATE INDEX onec_outbox_lease_idx ON public.onec_outbox USING btree (lease_until) WHERE (status = 'sending'::outbox_status);
CREATE INDEX order_items_packaging_idx ON public.order_items USING btree (packaging_id);
CREATE INDEX order_items_product_created_idx ON public.order_items USING btree (product_id, created_at);
CREATE INDEX order_items_variant_idx ON public.order_items USING btree (variant_id);
CREATE INDEX order_status_history_order_occurred_idx ON public.order_status_history USING btree (order_id, occurred_at);
CREATE INDEX orders_created_brin ON public.orders USING brin (created_at);
CREATE INDEX orders_created_idx ON public.orders USING btree (created_at DESC);
CREATE INDEX orders_creator_idx ON public.orders USING btree (created_by_user_id, created_at DESC);
CREATE INDEX orders_customer_idx ON public.orders USING btree (customer_id, created_at DESC);
CREATE INDEX orders_customer_requests_idx ON public.orders USING btree (status, created_at DESC) WHERE (created_via = 'customer'::text);
CREATE UNIQUE INDEX orders_idem_uq ON public.orders USING btree (idempotency_key, created_by_user_id) WHERE (idempotency_key IS NOT NULL);
CREATE INDEX orders_onec_number_idx ON public.orders USING btree (onec_number) WHERE (onec_number IS NOT NULL);
CREATE UNIQUE INDEX orders_onec_ref_uq ON public.orders USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX orders_onec_sync_attention_idx ON public.orders USING btree (onec_sync_state) WHERE (onec_sync_state = ANY (ARRAY['missing'::onec_sync_state, 'ambiguous'::onec_sync_state]));
CREATE INDEX orders_open_status_idx ON public.orders USING btree (status) WHERE (status = ANY (ARRAY['submitting'::order_status, 'submit_failed'::order_status, 'pending_approval'::order_status, 'awaiting_payment'::order_status, 'approved'::order_status, 'awaiting_shipment'::order_status]));
CREATE UNIQUE INDEX orders_public_number_uq ON public.orders USING btree (public_number);
CREATE UNIQUE INDEX otp_challenges_active_uq ON public.otp_challenges USING btree (phone_e164, purpose) WHERE (status = 'sent'::otp_status);
CREATE INDEX otp_challenges_expires_idx ON public.otp_challenges USING btree (expires_at);
CREATE INDEX otp_challenges_issued_by_idx ON public.otp_challenges USING btree (issued_by_user_id) WHERE (issued_by_user_id IS NOT NULL);
CREATE INDEX otp_challenges_phone_created_idx ON public.otp_challenges USING btree (phone_e164, created_at DESC);
CREATE INDEX otp_challenges_registration_token_idx ON public.otp_challenges USING btree (registration_token_hash) WHERE (registration_token_hash IS NOT NULL);
CREATE UNIQUE INDEX packagings_onec_ref_uq ON public.packagings USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX packagings_product_idx ON public.packagings USING btree (product_id) WHERE (NOT deletion_mark);
CREATE UNIQUE INDEX packagings_product_unit_factor_uq ON public.packagings USING btree (product_id, unit_id, factor) WHERE (product_id IS NOT NULL);
CREATE INDEX packagings_set_ref_idx ON public.packagings USING btree (packaging_set_ref);
CREATE INDEX packagings_unit_idx ON public.packagings USING btree (unit_id);
CREATE INDEX packagings_updated_at_id_idx ON public.packagings USING btree (updated_at, id);
CREATE INDEX packagings_updated_at_idx ON public.packagings USING btree (updated_at);
CREATE INDEX payment_webhook_events_payment_idx ON public.payment_webhook_events USING btree (payment_id);
CREATE INDEX payment_webhook_events_unprocessed_idx ON public.payment_webhook_events USING btree (processed_at) WHERE (processed_at IS NULL);
CREATE INDEX payments_customer_created_idx ON public.payments USING btree (customer_id, created_at DESC);
CREATE UNIQUE INDEX payments_idem_uq ON public.payments USING btree (idempotency_key, created_by_user_id);
CREATE UNIQUE INDEX payments_one_open_per_order_uq ON public.payments USING btree (order_id) WHERE (status = ANY (ARRAY['initiated'::payment_status, 'cash_pending'::payment_status, 'qr_pending'::payment_status, 'qr_shown'::payment_status, 'qr_expired'::payment_status, 'manual_confirm'::payment_status]));
CREATE UNIQUE INDEX payments_onec_ref_uq ON public.payments USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX payments_order_idx ON public.payments USING btree (order_id);
CREATE UNIQUE INDEX payments_public_number_uq ON public.payments USING btree (public_number);
CREATE INDEX payments_qr_onec_poll_idx ON public.payments USING btree (qr_status_checked_at) WHERE ((qr_provider = 'onec'::text) AND (status = 'qr_shown'::payment_status));
CREATE UNIQUE INDEX payments_qr_provider_ref_uq ON public.payments USING btree (qr_provider, qr_provider_ref) WHERE (qr_provider_ref IS NOT NULL);
CREATE INDEX payments_received_idx ON public.payments USING btree (received_at DESC) WHERE (status = 'received'::payment_status);
CREATE INDEX payments_review_idx ON public.payments USING btree (review_reason, created_at) WHERE (review_reason IS NOT NULL);
CREATE INDEX payments_status_created_idx ON public.payments USING btree (status, created_at);
CREATE UNIQUE INDEX permissions_code_uq ON public.permissions USING btree (code);
CREATE UNIQUE INDEX price_lists_default_uq ON public.price_lists USING btree (is_default) WHERE is_default;
CREATE UNIQUE INDEX price_lists_onec_ref_uq ON public.price_lists USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX price_lists_updated_at_id_idx ON public.price_lists USING btree (updated_at, id);
CREATE INDEX price_lists_updated_at_idx ON public.price_lists USING btree (updated_at);
CREATE INDEX prices_list_variant_idx ON public.prices USING btree (price_list_id, variant_id);
CREATE INDEX prices_packaging_idx ON public.prices USING btree (packaging_id);
CREATE INDEX prices_synced_idx ON public.prices USING btree (synced_at);
CREATE INDEX prices_updated_at_id_idx ON public.prices USING btree (updated_at, id);
CREATE UNIQUE INDEX prices_variant_list_pack_uq ON public.prices USING btree (variant_id, price_list_id, packaging_id) NULLS NOT DISTINCT;
CREATE INDEX print_jobs_payment_idx ON public.print_jobs USING btree (payment_id);
CREATE INDEX print_jobs_queued_idx ON public.print_jobs USING btree (status) WHERE (status = 'queued'::print_job_status);
CREATE UNIQUE INDEX product_attributes_code_uq ON public.product_attributes USING btree (code);
CREATE INDEX product_attributes_filterable_idx ON public.product_attributes USING btree (is_filterable) WHERE is_filterable;
CREATE UNIQUE INDEX product_attributes_onec_ref_uq ON public.product_attributes USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX product_attributes_updated_at_id_idx ON public.product_attributes USING btree (updated_at, id);
CREATE INDEX product_attributes_updated_at_idx ON public.product_attributes USING btree (updated_at);
CREATE INDEX product_images_category_idx ON public.product_images USING btree (category_id);
CREATE INDEX product_images_checksum_idx ON public.product_images USING btree (checksum_sha256);
CREATE INDEX product_images_download_queue_idx ON public.product_images USING btree (status, next_attempt_at) WHERE (status = ANY (ARRAY['pending'::image_status, 'failed'::image_status]));
CREATE UNIQUE INDEX product_images_primary_uq ON public.product_images USING btree (product_id, variant_id, category_id) NULLS NOT DISTINCT WHERE (is_primary AND (deleted_at IS NULL));
CREATE INDEX product_images_product_sort_idx ON public.product_images USING btree (product_id, sort_order) WHERE (deleted_at IS NULL);
CREATE UNIQUE INDEX product_images_source_ref_uq ON public.product_images USING btree (source_ref) WHERE (deleted_at IS NULL);
CREATE INDEX product_images_updated_at_id_idx ON public.product_images USING btree (updated_at, id);
CREATE INDEX product_images_updated_at_idx ON public.product_images USING btree (updated_at);
CREATE INDEX product_images_variant_idx ON public.product_images USING btree (variant_id);
CREATE UNIQUE INDEX product_variants_default_uq ON public.product_variants USING btree (product_id) WHERE is_default;
CREATE INDEX product_variants_name_norm_trgm ON public.product_variants USING gin (name_norm gin_trgm_ops) WITH (fastupdate=off);
CREATE UNIQUE INDEX product_variants_onec_ref_uq ON public.product_variants USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX product_variants_product_idx ON public.product_variants USING btree (product_id) WHERE (NOT deletion_mark);
CREATE INDEX product_variants_sku_norm_idx ON public.product_variants USING btree (sku_norm text_pattern_ops) WHERE (sku_norm IS NOT NULL);
CREATE INDEX product_variants_sku_norm_trgm ON public.product_variants USING gin (sku_norm gin_trgm_ops) WITH (fastupdate=off);
CREATE INDEX product_variants_updated_at_id_idx ON public.product_variants USING btree (updated_at, id);
CREATE INDEX product_variants_updated_at_idx ON public.product_variants USING btree (updated_at);
CREATE INDEX products_base_unit_idx ON public.products USING btree (base_unit_id);
CREATE INDEX products_catalog_name_id_idx ON public.products USING btree (name, id) WHERE ((NOT deletion_mark) AND is_sellable);
CREATE INDEX products_catalog_sku_id_idx ON public.products USING btree (sku, id) WHERE ((NOT deletion_mark) AND is_sellable);
CREATE INDEX products_category_idx ON public.products USING btree (category_id) WHERE ((NOT deletion_mark) AND is_sellable);
CREATE INDEX products_name_norm_prefix_idx ON public.products USING btree (name_norm COLLATE "C") WHERE ((NOT deletion_mark) AND is_sellable);
CREATE INDEX products_name_norm_trgm ON public.products USING gin (name_norm gin_trgm_ops) WITH (fastupdate=off);
CREATE INDEX products_onec_code_idx ON public.products USING btree (onec_code);
CREATE UNIQUE INDEX products_onec_ref_uq ON public.products USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX products_search_vector_gin ON public.products USING gin (search_vector) WITH (fastupdate=off);
CREATE INDEX products_sku_norm_idx ON public.products USING btree (sku_norm text_pattern_ops) WHERE (sku_norm IS NOT NULL);
CREATE INDEX products_sku_norm_trgm ON public.products USING gin (sku_norm gin_trgm_ops) WITH (fastupdate=off);
CREATE INDEX products_updated_at_id_idx ON public.products USING btree (updated_at, id);
CREATE INDEX products_updated_at_idx ON public.products USING btree (updated_at);
CREATE INDEX rate_limit_counters_window_end_idx ON public.rate_limit_counters USING btree (window_end);
CREATE INDEX receivable_documents_current_idx ON public.receivable_documents USING btree (customer_id, due_date) WHERE (superseded_at IS NULL);
CREATE INDEX receivable_documents_order_idx ON public.receivable_documents USING btree (order_id);
CREATE INDEX receivables_balance_idx ON public.receivables USING btree (balance DESC);
CREATE INDEX receivables_overdue_idx ON public.receivables USING btree (overdue_amount) WHERE (overdue_amount > (0)::numeric);
CREATE INDEX recent_products_product_idx ON public.recent_products USING btree (product_id);
CREATE INDEX recent_products_user_viewed_idx ON public.recent_products USING btree (user_id, last_viewed_at DESC);
CREATE INDEX return_request_items_shipment_item_idx ON public.return_request_items USING btree (shipment_item_id);
CREATE INDEX return_request_items_variant_idx ON public.return_request_items USING btree (variant_id);
CREATE INDEX return_requests_author_created_idx ON public.return_requests USING btree (created_by_user_id, created_at DESC);
CREATE INDEX return_requests_customer_created_idx ON public.return_requests USING btree (customer_id, created_at DESC);
CREATE UNIQUE INDEX return_requests_onec_ref_uq ON public.return_requests USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX return_requests_open_idx ON public.return_requests USING btree (status) WHERE (status = ANY (ARRAY['draft'::return_request_status, 'submitted'::return_request_status, 'accepted'::return_request_status]));
CREATE INDEX return_requests_order_idx ON public.return_requests USING btree (order_id);
CREATE UNIQUE INDEX return_requests_public_number_uq ON public.return_requests USING btree (public_number);
CREATE INDEX return_requests_shipment_idx ON public.return_requests USING btree (shipment_id);
CREATE UNIQUE INDEX role_discount_limits_role_uq ON public.role_discount_limits USING btree (role);
CREATE INDEX role_permissions_permission_idx ON public.role_permissions USING btree (permission_id);
CREATE UNIQUE INDEX roles_code_uq ON public.roles USING btree (code);
CREATE INDEX search_words_word_trgm ON public.search_words USING gin (word gin_trgm_ops);
CREATE UNIQUE INDEX search_words_word_uq ON public.search_words USING btree (word);
CREATE INDEX sessions_created_from_challenge_idx ON public.sessions USING btree (created_from_challenge_id);
CREATE INDEX sessions_device_idx ON public.sessions USING btree (device_id);
CREATE INDEX sessions_expires_idx ON public.sessions USING btree (expires_at);
CREATE INDEX sessions_family_idx ON public.sessions USING btree (family_id);
CREATE INDEX sessions_prev_refresh_hash_idx ON public.sessions USING btree (prev_refresh_hash);
CREATE UNIQUE INDEX sessions_refresh_hash_uq ON public.sessions USING btree (refresh_hash);
CREATE INDEX sessions_superseded_idx ON public.sessions USING btree (superseded_refresh_hash) WHERE (superseded_refresh_hash IS NOT NULL);
CREATE INDEX sessions_user_active_idx ON public.sessions USING btree (user_id) WHERE (revoked_at IS NULL);
CREATE INDEX shipment_items_packaging_idx ON public.shipment_items USING btree (packaging_id);
CREATE INDEX shipment_items_variant_idx ON public.shipment_items USING btree (variant_id);
CREATE INDEX shipments_customer_date_idx ON public.shipments USING btree (customer_id, onec_date DESC);
CREATE INDEX shipments_date_idx ON public.shipments USING btree (onec_date DESC);
CREATE UNIQUE INDEX shipments_onec_ref_uq ON public.shipments USING btree (onec_ref);
CREATE INDEX shipments_order_idx ON public.shipments USING btree (order_id);
CREATE INDEX shipments_warehouse_idx ON public.shipments USING btree (warehouse_id);
CREATE INDEX sms_outbox_created_idx ON public.sms_outbox USING btree (created_at);
CREATE INDEX sms_outbox_otp_challenge_idx ON public.sms_outbox USING btree (otp_challenge_id);
CREATE INDEX sms_outbox_phone_created_idx ON public.sms_outbox USING btree (phone_e164, created_at DESC);
CREATE UNIQUE INDEX sms_outbox_provider_message_id_uq ON public.sms_outbox USING btree (provider_message_id);
CREATE INDEX sms_outbox_status_created_idx ON public.sms_outbox USING btree (status, created_at);
CREATE INDEX stock_balances_synced_idx ON public.stock_balances USING btree (synced_at);
CREATE INDEX stock_balances_updated_at_key_idx ON public.stock_balances USING btree (updated_at, variant_id, warehouse_id);
CREATE INDEX stock_balances_warehouse_idx ON public.stock_balances USING btree (warehouse_id);
CREATE INDEX stock_balances_wh_avail_idx ON public.stock_balances USING btree (warehouse_id) WHERE (available > (0)::numeric);
CREATE INDEX sync_entity_versions_last_seen_idx ON public.sync_entity_versions USING btree (entity, last_seen_at);
CREATE INDEX sync_entity_versions_run_idx ON public.sync_entity_versions USING btree (seen_in_run_id);
CREATE INDEX sync_entity_versions_seen_idx ON public.sync_entity_versions USING btree (entity, seen_in_run_id);
CREATE INDEX sync_errors_onec_ref_idx ON public.sync_errors USING btree (onec_ref);
CREATE INDEX sync_errors_open_idx ON public.sync_errors USING btree (entity, resolved_at) WHERE (resolved_at IS NULL);
CREATE INDEX sync_errors_outbox_idx ON public.sync_errors USING btree (outbox_id);
CREATE INDEX sync_errors_run_idx ON public.sync_errors USING btree (sync_run_id);
CREATE INDEX sync_runs_active_idx ON public.sync_runs USING btree (status) WHERE (status = ANY (ARRAY['queued'::sync_run_status, 'running'::sync_run_status]));
CREATE INDEX sync_runs_entity_started_idx ON public.sync_runs USING btree (entity, started_at DESC);
CREATE UNIQUE INDEX sync_runs_singleton_uq ON public.sync_runs USING btree (entity) WHERE (status = ANY (ARRAY['queued'::sync_run_status, 'running'::sync_run_status]));
CREATE INDEX sync_runs_started_brin ON public.sync_runs USING brin (started_at);
CREATE INDEX token_denylist_expires_idx ON public.token_denylist USING btree (expires_at);
CREATE INDEX token_denylist_session_idx ON public.token_denylist USING btree (session_id);
CREATE INDEX transactions_actor_occurred_idx ON public.transactions USING btree (actor_user_id, occurred_at DESC);
CREATE INDEX transactions_amount_idx ON public.transactions USING btree (amount DESC, id DESC);
CREATE INDEX transactions_customer_occurred_idx ON public.transactions USING btree (customer_id, occurred_at DESC);
CREATE INDEX transactions_kind_occurred_idx ON public.transactions USING btree (kind, occurred_at DESC);
CREATE INDEX transactions_occurred_idx ON public.transactions USING btree (occurred_at DESC);
CREATE UNIQUE INDEX transactions_onec_ref_uq ON public.transactions USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX transactions_order_idx ON public.transactions USING btree (order_id);
CREATE INDEX transactions_payment_idx ON public.transactions USING btree (payment_id);
CREATE UNIQUE INDEX units_code_uq ON public.units USING btree (code);
CREATE UNIQUE INDEX units_onec_ref_uq ON public.units USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX units_updated_at_id_idx ON public.units USING btree (updated_at, id);
CREATE INDEX units_updated_at_idx ON public.units USING btree (updated_at);
CREATE INDEX user_invitations_invited_by_idx ON public.user_invitations USING btree (invited_by_user_id);
CREATE UNIQUE INDEX user_invitations_phone_pending_uq ON public.user_invitations USING btree (phone_e164) WHERE (status = 'pending'::invitation_status);
CREATE INDEX user_invitations_status_expires_idx ON public.user_invitations USING btree (status, expires_at);
CREATE INDEX user_profiles_home_warehouse_idx ON public.user_profiles USING btree (home_warehouse_id);
CREATE UNIQUE INDEX user_roles_one_active_uq ON public.user_roles USING btree (user_id) WHERE (revoked_at IS NULL);
CREATE INDEX user_roles_role_active_idx ON public.user_roles USING btree (role_id) WHERE (revoked_at IS NULL);
CREATE INDEX user_roles_user_granted_idx ON public.user_roles USING btree (user_id, granted_at);
CREATE UNIQUE INDEX user_roles_user_role_active_uq ON public.user_roles USING btree (user_id, role_id) WHERE (revoked_at IS NULL);
CREATE INDEX users_deleted_phone_hmac_idx ON public.users USING btree (deleted_phone_hmac) WHERE (deleted_phone_hmac IS NOT NULL);
CREATE INDEX users_kind_status_idx ON public.users USING btree (kind, status);
CREATE UNIQUE INDEX users_phone_e164_uq ON public.users USING btree (phone_e164) WHERE ((phone_e164 IS NOT NULL) AND (deleted_at IS NULL));
CREATE INDEX variant_attribute_values_attr_number_idx ON public.variant_attribute_values USING btree (attribute_id, value_number);
CREATE INDEX variant_attribute_values_attr_text_idx ON public.variant_attribute_values USING btree (attribute_id, value_text_norm);
CREATE INDEX variant_attribute_values_attr_updated_idx ON public.variant_attribute_values USING btree (attribute_id, updated_at);
CREATE INDEX variant_attribute_values_synced_idx ON public.variant_attribute_values USING btree (synced_at);
CREATE UNIQUE INDEX warehouses_default_uq ON public.warehouses USING btree (is_default_for_pos) WHERE is_default_for_pos;
CREATE UNIQUE INDEX warehouses_onec_ref_uq ON public.warehouses USING btree (onec_ref) WHERE (onec_ref IS NOT NULL);
CREATE INDEX warehouses_updated_at_id_idx ON public.warehouses USING btree (updated_at, id);
CREATE INDEX warehouses_updated_at_idx ON public.warehouses USING btree (updated_at);

-- ----------------------------------------------------------------------------------------------------
-- Внешние ключи
-- ----------------------------------------------------------------------------------------------------
ALTER TABLE ONLY public.app_pins ADD CONSTRAINT app_pins_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.app_settings ADD CONSTRAINT app_settings_updated_by_user_id_fk FOREIGN KEY (updated_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_actor_user_id_fk FOREIGN KEY (actor_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.barcodes ADD CONSTRAINT barcodes_packaging_id_fk FOREIGN KEY (packaging_id) REFERENCES packagings(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.barcodes ADD CONSTRAINT barcodes_product_id_fk FOREIGN KEY (product_id) REFERENCES products(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.barcodes ADD CONSTRAINT barcodes_variant_id_fk FOREIGN KEY (variant_id) REFERENCES product_variants(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.cart_items ADD CONSTRAINT cart_items_cart_id_fk FOREIGN KEY (cart_id) REFERENCES carts(id) ON UPDATE RESTRICT ON DELETE CASCADE;
ALTER TABLE ONLY public.cart_items ADD CONSTRAINT cart_items_packaging_id_fk FOREIGN KEY (packaging_id) REFERENCES packagings(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.cart_items ADD CONSTRAINT cart_items_variant_id_fk FOREIGN KEY (variant_id) REFERENCES product_variants(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_converted_order_id_fk FOREIGN KEY (converted_order_id) REFERENCES orders(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_created_by_user_id_fk FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_customer_id_fk FOREIGN KEY (customer_id) REFERENCES customers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_device_id_fk FOREIGN KEY (device_id) REFERENCES devices(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_discount_approved_by_user_id_fk FOREIGN KEY (discount_approved_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_owner_user_id_fk FOREIGN KEY (owner_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_price_list_id_fk FOREIGN KEY (price_list_id) REFERENCES price_lists(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_restored_from_order_fk FOREIGN KEY (restored_from_order_id) REFERENCES orders(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.carts ADD CONSTRAINT carts_warehouse_id_fk FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_image_id_fk FOREIGN KEY (image_id) REFERENCES product_images(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_parent_id_fk FOREIGN KEY (parent_id) REFERENCES categories(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.consents ADD CONSTRAINT consents_device_id_fk FOREIGN KEY (device_id) REFERENCES devices(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.consents ADD CONSTRAINT consents_otp_challenge_id_fk FOREIGN KEY (otp_challenge_id) REFERENCES otp_challenges(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.consents ADD CONSTRAINT consents_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.customer_contacts ADD CONSTRAINT customer_contacts_customer_id_fk FOREIGN KEY (customer_id) REFERENCES customers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.customer_links ADD CONSTRAINT customer_links_confirmed_by_user_id_fk FOREIGN KEY (confirmed_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.customer_links ADD CONSTRAINT customer_links_customer_id_fk FOREIGN KEY (customer_id) REFERENCES customers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.customer_links ADD CONSTRAINT customer_links_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_created_by_user_id_fk FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_default_price_list_id_fk FOREIGN KEY (default_price_list_id) REFERENCES price_lists(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.dev_outbox ADD CONSTRAINT dev_outbox_sms_outbox_id_fk FOREIGN KEY (sms_outbox_id) REFERENCES sms_outbox(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_revoked_by_user_id_fk FOREIGN KEY (revoked_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.favorites_customers ADD CONSTRAINT favorites_customers_customer_id_fk FOREIGN KEY (customer_id) REFERENCES customers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.favorites_customers ADD CONSTRAINT favorites_customers_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.favorites_products ADD CONSTRAINT favorites_products_product_id_fk FOREIGN KEY (product_id) REFERENCES products(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.favorites_products ADD CONSTRAINT favorites_products_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.idempotency_keys ADD CONSTRAINT idempotency_keys_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.integration_tokens ADD CONSTRAINT integration_tokens_created_by_user_id_fk FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.integration_tokens ADD CONSTRAINT integration_tokens_revoked_by_user_id_fk FOREIGN KEY (revoked_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.notifications ADD CONSTRAINT notifications_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.onec_outbox ADD CONSTRAINT onec_outbox_depends_on_outbox_id_fk FOREIGN KEY (depends_on_outbox_id) REFERENCES onec_outbox(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.onec_outbox ADD CONSTRAINT onec_outbox_requested_by_user_id_fk FOREIGN KEY (requested_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.onec_outbox ADD CONSTRAINT onec_outbox_warehouse_id_fk FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_order_id_fk FOREIGN KEY (order_id) REFERENCES orders(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_packaging_id_fk FOREIGN KEY (packaging_id) REFERENCES packagings(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_product_id_fk FOREIGN KEY (product_id) REFERENCES products(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_variant_id_fk FOREIGN KEY (variant_id) REFERENCES product_variants(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.order_status_history ADD CONSTRAINT order_status_history_actor_user_id_fk FOREIGN KEY (actor_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.order_status_history ADD CONSTRAINT order_status_history_order_id_fk FOREIGN KEY (order_id) REFERENCES orders(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_cancel_requested_by_user_id_fk FOREIGN KEY (cancel_requested_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_created_by_user_id_fk FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_credit_approved_by_user_id_fk FOREIGN KEY (credit_approved_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_customer_id_fk FOREIGN KEY (customer_id) REFERENCES customers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_device_id_fk FOREIGN KEY (device_id) REFERENCES devices(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_discount_approved_by_user_id_fk FOREIGN KEY (discount_approved_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_discount_rule_id_fk FOREIGN KEY (discount_rule_id) REFERENCES discount_rules(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_onec_linked_by_user_id_fk FOREIGN KEY (onec_linked_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_price_list_id_fk FOREIGN KEY (price_list_id) REFERENCES price_lists(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_warehouse_id_fk FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.otp_challenges ADD CONSTRAINT otp_challenges_issued_by_user_id_fk FOREIGN KEY (issued_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.otp_challenges ADD CONSTRAINT otp_challenges_sms_outbox_id_fk FOREIGN KEY (sms_outbox_id) REFERENCES sms_outbox(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.otp_challenges ADD CONSTRAINT otp_challenges_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.packagings ADD CONSTRAINT packagings_product_id_fk FOREIGN KEY (product_id) REFERENCES products(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.packagings ADD CONSTRAINT packagings_unit_id_fk FOREIGN KEY (unit_id) REFERENCES units(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.payment_webhook_events ADD CONSTRAINT payment_webhook_events_payment_id_fk FOREIGN KEY (payment_id) REFERENCES payments(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_created_by_user_id_fk FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_customer_id_fk FOREIGN KEY (customer_id) REFERENCES customers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_manual_confirmed_by_user_id_fk FOREIGN KEY (manual_confirmed_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_order_id_fk FOREIGN KEY (order_id) REFERENCES orders(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_received_by_user_id_fk FOREIGN KEY (received_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_voided_by_user_id_fk FOREIGN KEY (voided_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.prices ADD CONSTRAINT prices_packaging_id_fk FOREIGN KEY (packaging_id) REFERENCES packagings(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.prices ADD CONSTRAINT prices_price_list_id_fk FOREIGN KEY (price_list_id) REFERENCES price_lists(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.prices ADD CONSTRAINT prices_variant_id_fk FOREIGN KEY (variant_id) REFERENCES product_variants(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.print_jobs ADD CONSTRAINT print_jobs_order_id_fk FOREIGN KEY (order_id) REFERENCES orders(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.print_jobs ADD CONSTRAINT print_jobs_payment_id_fk FOREIGN KEY (payment_id) REFERENCES payments(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.print_jobs ADD CONSTRAINT print_jobs_requested_by_user_id_fk FOREIGN KEY (requested_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.product_images ADD CONSTRAINT product_images_category_id_fk FOREIGN KEY (category_id) REFERENCES categories(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.product_images ADD CONSTRAINT product_images_product_id_fk FOREIGN KEY (product_id) REFERENCES products(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.product_images ADD CONSTRAINT product_images_variant_id_fk FOREIGN KEY (variant_id) REFERENCES product_variants(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.product_variants ADD CONSTRAINT product_variants_primary_image_id_fk FOREIGN KEY (primary_image_id) REFERENCES product_images(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.product_variants ADD CONSTRAINT product_variants_product_id_fk FOREIGN KEY (product_id) REFERENCES products(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.products ADD CONSTRAINT products_base_unit_id_fk FOREIGN KEY (base_unit_id) REFERENCES units(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.products ADD CONSTRAINT products_category_id_fk FOREIGN KEY (category_id) REFERENCES categories(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.products ADD CONSTRAINT products_primary_image_id_fk FOREIGN KEY (primary_image_id) REFERENCES product_images(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.receivable_documents ADD CONSTRAINT receivable_documents_customer_id_fk FOREIGN KEY (customer_id) REFERENCES receivables(customer_id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.receivable_documents ADD CONSTRAINT receivable_documents_order_id_fk FOREIGN KEY (order_id) REFERENCES orders(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.receivables ADD CONSTRAINT receivables_customer_id_fk FOREIGN KEY (customer_id) REFERENCES customers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.recent_products ADD CONSTRAINT recent_products_product_id_fk FOREIGN KEY (product_id) REFERENCES products(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.recent_products ADD CONSTRAINT recent_products_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.return_request_items ADD CONSTRAINT return_request_items_return_request_id_fk FOREIGN KEY (return_request_id) REFERENCES return_requests(id) ON UPDATE RESTRICT ON DELETE CASCADE;
ALTER TABLE ONLY public.return_request_items ADD CONSTRAINT return_request_items_shipment_item_id_fk FOREIGN KEY (shipment_item_id) REFERENCES shipment_items(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.return_request_items ADD CONSTRAINT return_request_items_variant_id_fk FOREIGN KEY (variant_id) REFERENCES product_variants(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_accepted_by_user_id_fk FOREIGN KEY (accepted_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_approved_by_user_id_fk FOREIGN KEY (approved_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_created_by_user_id_fk FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_customer_id_fk FOREIGN KEY (customer_id) REFERENCES customers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_order_id_fk FOREIGN KEY (order_id) REFERENCES orders(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_rejected_by_user_id_fk FOREIGN KEY (rejected_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.return_requests ADD CONSTRAINT return_requests_shipment_id_fk FOREIGN KEY (shipment_id) REFERENCES shipments(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.role_discount_limits ADD CONSTRAINT role_discount_limits_updated_by_user_id_fk FOREIGN KEY (updated_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.role_permissions ADD CONSTRAINT role_permissions_permission_id_fk FOREIGN KEY (permission_id) REFERENCES permissions(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.role_permissions ADD CONSTRAINT role_permissions_role_id_fk FOREIGN KEY (role_id) REFERENCES roles(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sessions ADD CONSTRAINT sessions_created_from_challenge_id_fk FOREIGN KEY (created_from_challenge_id) REFERENCES otp_challenges(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sessions ADD CONSTRAINT sessions_device_id_fk FOREIGN KEY (device_id) REFERENCES devices(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sessions ADD CONSTRAINT sessions_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.shipment_items ADD CONSTRAINT shipment_items_packaging_id_fk FOREIGN KEY (packaging_id) REFERENCES packagings(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.shipment_items ADD CONSTRAINT shipment_items_shipment_id_fk FOREIGN KEY (shipment_id) REFERENCES shipments(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.shipment_items ADD CONSTRAINT shipment_items_variant_id_fk FOREIGN KEY (variant_id) REFERENCES product_variants(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.shipments ADD CONSTRAINT shipments_customer_id_fk FOREIGN KEY (customer_id) REFERENCES customers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.shipments ADD CONSTRAINT shipments_order_id_fk FOREIGN KEY (order_id) REFERENCES orders(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.shipments ADD CONSTRAINT shipments_warehouse_id_fk FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sms_outbox ADD CONSTRAINT sms_outbox_otp_challenge_id_fk FOREIGN KEY (otp_challenge_id) REFERENCES otp_challenges(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.stock_balances ADD CONSTRAINT stock_balances_variant_id_fk FOREIGN KEY (variant_id) REFERENCES product_variants(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.stock_balances ADD CONSTRAINT stock_balances_warehouse_id_fk FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sync_entity_versions ADD CONSTRAINT sync_entity_versions_seen_in_run_id_fk FOREIGN KEY (seen_in_run_id) REFERENCES sync_runs(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sync_errors ADD CONSTRAINT sync_errors_outbox_id_fk FOREIGN KEY (outbox_id) REFERENCES onec_outbox(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sync_errors ADD CONSTRAINT sync_errors_resolved_by_user_id_fk FOREIGN KEY (resolved_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sync_errors ADD CONSTRAINT sync_errors_sync_run_id_fk FOREIGN KEY (sync_run_id) REFERENCES sync_runs(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sync_runs ADD CONSTRAINT sync_runs_triggered_by_user_id_fk FOREIGN KEY (triggered_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sync_state ADD CONSTRAINT sync_state_last_run_id_fk FOREIGN KEY (last_run_id) REFERENCES sync_runs(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.sync_state ADD CONSTRAINT sync_state_last_success_run_id_fk FOREIGN KEY (last_success_run_id) REFERENCES sync_runs(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.token_denylist ADD CONSTRAINT token_denylist_session_id_fk FOREIGN KEY (session_id) REFERENCES sessions(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.transactions ADD CONSTRAINT transactions_actor_user_id_fk FOREIGN KEY (actor_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.transactions ADD CONSTRAINT transactions_customer_id_fk FOREIGN KEY (customer_id) REFERENCES customers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.transactions ADD CONSTRAINT transactions_order_id_fk FOREIGN KEY (order_id) REFERENCES orders(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.transactions ADD CONSTRAINT transactions_payment_id_fk FOREIGN KEY (payment_id) REFERENCES payments(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.transactions ADD CONSTRAINT transactions_return_request_id_fk FOREIGN KEY (return_request_id) REFERENCES return_requests(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.transactions ADD CONSTRAINT transactions_shipment_id_fk FOREIGN KEY (shipment_id) REFERENCES shipments(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.user_invitations ADD CONSTRAINT user_invitations_accepted_user_id_fk FOREIGN KEY (accepted_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.user_invitations ADD CONSTRAINT user_invitations_invited_by_user_id_fk FOREIGN KEY (invited_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.user_profiles ADD CONSTRAINT user_profiles_home_warehouse_id_fk FOREIGN KEY (home_warehouse_id) REFERENCES warehouses(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.user_profiles ADD CONSTRAINT user_profiles_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.user_roles ADD CONSTRAINT user_roles_granted_by_user_id_fk FOREIGN KEY (granted_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.user_roles ADD CONSTRAINT user_roles_role_id_fk FOREIGN KEY (role_id) REFERENCES roles(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.user_roles ADD CONSTRAINT user_roles_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.users ADD CONSTRAINT users_blocked_by_user_id_fk FOREIGN KEY (blocked_by_user_id) REFERENCES users(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.users ADD CONSTRAINT users_invitation_id_fk FOREIGN KEY (invitation_id) REFERENCES user_invitations(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.variant_attribute_values ADD CONSTRAINT variant_attribute_values_attribute_id_fk FOREIGN KEY (attribute_id) REFERENCES product_attributes(id) ON UPDATE RESTRICT ON DELETE RESTRICT;
ALTER TABLE ONLY public.variant_attribute_values ADD CONSTRAINT variant_attribute_values_variant_id_fk FOREIGN KEY (variant_id) REFERENCES product_variants(id) ON UPDATE RESTRICT ON DELETE RESTRICT;

-- ----------------------------------------------------------------------------------------------------
-- Триггеры
-- ----------------------------------------------------------------------------------------------------
CREATE TRIGGER trg_app_pins_set_updated_at BEFORE UPDATE ON public.app_pins FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_app_settings_audit AFTER UPDATE ON public.app_settings FOR EACH ROW EXECUTE FUNCTION audit_db_changes('settings.changed', 'key', '');
CREATE TRIGGER trg_app_settings_row_version BEFORE UPDATE ON public.app_settings FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE TRIGGER trg_app_settings_set_updated_at BEFORE UPDATE ON public.app_settings FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_audit_anchors_set_updated_at BEFORE UPDATE ON public.audit_anchors FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_audit_logs_chain BEFORE INSERT ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION audit_logs_chain();
CREATE TRIGGER trg_audit_logs_immutable BEFORE DELETE OR UPDATE ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION append_only_immutable();
CREATE TRIGGER trg_barcodes_set_updated_at BEFORE UPDATE ON public.barcodes FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_cart_items_set_updated_at BEFORE UPDATE ON public.cart_items FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_carts_row_version BEFORE UPDATE ON public.carts FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE TRIGGER trg_carts_set_updated_at BEFORE UPDATE ON public.carts FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_categories_set_updated_at BEFORE UPDATE ON public.categories FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_consents_set_updated_at BEFORE UPDATE ON public.consents FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_customer_contacts_set_updated_at BEFORE UPDATE ON public.customer_contacts FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_customer_links_set_updated_at BEFORE UPDATE ON public.customer_links FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_customers_audit AFTER INSERT OR UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION audit_db_changes('customer.created|customer.updated', 'id', 'source=pos');
CREATE TRIGGER trg_customers_row_version BEFORE UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE TRIGGER trg_customers_set_updated_at BEFORE UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_dev_outbox_set_updated_at BEFORE UPDATE ON public.dev_outbox FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_devices_set_updated_at BEFORE UPDATE ON public.devices FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_discount_rules_audit AFTER INSERT OR DELETE OR UPDATE ON public.discount_rules FOR EACH ROW EXECUTE FUNCTION audit_db_changes('discount.rule_changed', 'id', 'source=pos');
CREATE TRIGGER trg_discount_rules_row_version BEFORE UPDATE ON public.discount_rules FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE TRIGGER trg_discount_rules_set_updated_at BEFORE UPDATE ON public.discount_rules FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_favorites_customers_set_updated_at BEFORE UPDATE ON public.favorites_customers FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_favorites_products_set_updated_at BEFORE UPDATE ON public.favorites_products FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_idempotency_keys_set_updated_at BEFORE UPDATE ON public.idempotency_keys FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_integration_tokens_max_active AFTER INSERT OR UPDATE OF revoked_at, expires_at ON public.integration_tokens FOR EACH ROW EXECUTE FUNCTION integration_tokens_max_active();
CREATE TRIGGER trg_integration_tokens_set_updated_at BEFORE UPDATE ON public.integration_tokens FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_notifications_set_updated_at BEFORE UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_onec_outbox_audit AFTER UPDATE OF status ON public.onec_outbox FOR EACH ROW EXECUTE FUNCTION onec_outbox_audit();
CREATE TRIGGER trg_onec_outbox_set_updated_at BEFORE UPDATE ON public.onec_outbox FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_order_items_freeze BEFORE DELETE OR UPDATE ON public.order_items FOR EACH ROW EXECUTE FUNCTION order_items_freeze();
CREATE TRIGGER trg_order_items_set_updated_at BEFORE UPDATE ON public.order_items FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE CONSTRAINT TRIGGER trg_order_items_totals AFTER INSERT OR DELETE OR UPDATE ON public.order_items DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_items_totals();
CREATE TRIGGER trg_order_status_history_immutable BEFORE DELETE OR UPDATE ON public.order_status_history FOR EACH ROW EXECUTE FUNCTION append_only_immutable();
CREATE TRIGGER trg_order_status_history_set_updated_at BEFORE UPDATE ON public.order_status_history FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_orders_audit AFTER DELETE OR UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION orders_audit();
CREATE TRIGGER trg_orders_freeze_financials BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION orders_freeze_financials();
CREATE TRIGGER trg_orders_paid_at_once BEFORE UPDATE OF paid_at ON public.orders FOR EACH ROW EXECUTE FUNCTION orders_paid_at_once();
CREATE TRIGGER trg_orders_row_version BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE TRIGGER trg_orders_set_updated_at BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_otp_challenges_set_updated_at BEFORE UPDATE ON public.otp_challenges FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_packagings_set_updated_at BEFORE UPDATE ON public.packagings FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_payment_webhook_events_set_updated_at BEFORE UPDATE ON public.payment_webhook_events FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_payments_audit AFTER DELETE OR UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION audit_db_changes('|db.payments.update|db.payments.delete', 'id,public_number', '', 'status', 'amount', 'method', 'order_id', 'customer_id', 'received_amount', 'change_amount', 'bank_amount', 'received_by_user_id', 'received_at', 'review_reason', 'manual_confirmed_by_user_id', 'manual_reason', 'voided_by_user_id', 'void_reason', 'qr_provider', 'qr_provider_ref', 'bank_reference', 'onec_ref');
CREATE TRIGGER trg_payments_freeze BEFORE DELETE OR UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION payments_freeze();
CREATE TRIGGER trg_payments_notify_status AFTER UPDATE OF status ON public.payments FOR EACH ROW WHEN ((old.status IS DISTINCT FROM new.status)) EXECUTE FUNCTION payments_notify_status();
CREATE TRIGGER trg_payments_row_version BEFORE UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION bump_row_version();
CREATE TRIGGER trg_payments_set_updated_at BEFORE UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_permissions_set_updated_at BEFORE UPDATE ON public.permissions FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_price_lists_admin_audit AFTER UPDATE ON public.price_lists FOR EACH ROW EXECUTE FUNCTION audit_db_changes('settings.changed', 'id', '', 'is_default', 'visible_to_roles', 'sort_order');
CREATE TRIGGER trg_price_lists_set_updated_at BEFORE UPDATE ON public.price_lists FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_prices_catalog_sync_deleted AFTER DELETE ON public.prices REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION catalog_sync.log_prices_deleted();
CREATE TRIGGER trg_prices_set_updated_at BEFORE UPDATE ON public.prices FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_print_jobs_set_updated_at BEFORE UPDATE ON public.print_jobs FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_product_attributes_admin_audit AFTER UPDATE ON public.product_attributes FOR EACH ROW EXECUTE FUNCTION audit_db_changes('settings.changed', 'id', '', 'code', 'is_filterable', 'is_variant_axis', 'sort_order');
CREATE TRIGGER trg_product_attributes_set_updated_at BEFORE UPDATE ON public.product_attributes FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_product_images_catalog_sync_deleted AFTER DELETE ON public.product_images REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION catalog_sync.log_images_deleted();
CREATE TRIGGER trg_product_images_set_updated_at BEFORE UPDATE ON public.product_images FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_product_variants_set_updated_at BEFORE UPDATE ON public.product_variants FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_products_set_updated_at BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_rate_limit_counters_set_updated_at BEFORE UPDATE ON public.rate_limit_counters FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_receivable_documents_set_updated_at BEFORE UPDATE ON public.receivable_documents FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_receivables_set_updated_at BEFORE UPDATE ON public.receivables FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_recent_products_set_updated_at BEFORE UPDATE ON public.recent_products FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_return_request_items_guard BEFORE INSERT OR DELETE OR UPDATE ON public.return_request_items FOR EACH ROW EXECUTE FUNCTION return_request_items_guard();
CREATE TRIGGER trg_return_request_items_set_updated_at BEFORE UPDATE ON public.return_request_items FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_return_requests_audit AFTER UPDATE ON public.return_requests FOR EACH ROW EXECUTE FUNCTION audit_db_changes('return.status_changed', 'id,public_number', '', 'status');
CREATE TRIGGER trg_return_requests_row_version BEFORE UPDATE ON public.return_requests FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE TRIGGER trg_return_requests_set_updated_at BEFORE UPDATE ON public.return_requests FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_role_discount_limits_audit AFTER INSERT OR DELETE OR UPDATE ON public.role_discount_limits FOR EACH ROW EXECUTE FUNCTION audit_db_changes('discount.limits_changed', 'id,role', '');
CREATE TRIGGER trg_role_discount_limits_row_version BEFORE UPDATE ON public.role_discount_limits FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE TRIGGER trg_role_discount_limits_set_updated_at BEFORE UPDATE ON public.role_discount_limits FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_role_permissions_audit AFTER INSERT OR DELETE OR UPDATE ON public.role_permissions FOR EACH ROW EXECUTE FUNCTION audit_db_changes('rbac.matrix_changed', 'role_id,permission_id', '');
CREATE TRIGGER trg_role_permissions_set_updated_at BEFORE UPDATE ON public.role_permissions FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_roles_protect_system BEFORE DELETE OR UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION roles_protect_system();
CREATE TRIGGER trg_roles_set_updated_at BEFORE UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sessions_set_updated_at BEFORE UPDATE ON public.sessions FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_shipment_items_set_updated_at BEFORE UPDATE ON public.shipment_items FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_shipments_set_updated_at BEFORE UPDATE ON public.shipments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sms_outbox_set_updated_at BEFORE UPDATE ON public.sms_outbox FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_stock_balances_set_updated_at BEFORE UPDATE ON public.stock_balances FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sync_entity_versions_set_updated_at BEFORE UPDATE ON public.sync_entity_versions FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sync_errors_set_updated_at BEFORE UPDATE ON public.sync_errors FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sync_node_state_monotonic BEFORE UPDATE OF last_message_number ON public.sync_node_state FOR EACH ROW EXECUTE FUNCTION sync_node_state_monotonic();
CREATE TRIGGER trg_sync_node_state_set_updated_at BEFORE UPDATE ON public.sync_node_state FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sync_runs_audit AFTER UPDATE OF status ON public.sync_runs FOR EACH ROW EXECUTE FUNCTION sync_runs_audit();
CREATE TRIGGER trg_sync_runs_set_updated_at BEFORE UPDATE ON public.sync_runs FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_sync_state_set_updated_at BEFORE UPDATE ON public.sync_state FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_token_denylist_set_updated_at BEFORE UPDATE ON public.token_denylist FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_transactions_immutable BEFORE DELETE OR UPDATE ON public.transactions FOR EACH ROW EXECUTE FUNCTION append_only_immutable();
CREATE TRIGGER trg_transactions_set_updated_at BEFORE UPDATE ON public.transactions FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_units_set_updated_at BEFORE UPDATE ON public.units FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_user_invitations_set_updated_at BEFORE UPDATE ON public.user_invitations FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_user_profiles_row_version BEFORE UPDATE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE TRIGGER trg_user_profiles_set_updated_at BEFORE UPDATE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_user_roles_audit AFTER INSERT OR UPDATE ON public.user_roles FOR EACH ROW EXECUTE FUNCTION audit_db_changes('user.role_changed', 'user_id,role_id,id', '');
CREATE TRIGGER trg_user_roles_set_updated_at BEFORE UPDATE ON public.user_roles FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_users_audit AFTER UPDATE OF status, phone_e164 ON public.users FOR EACH ROW EXECUTE FUNCTION users_audit();
CREATE TRIGGER trg_users_set_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_variant_attribute_values_set_updated_at BEFORE UPDATE ON public.variant_attribute_values FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_warehouses_admin_audit AFTER UPDATE ON public.warehouses FOR EACH ROW EXECUTE FUNCTION audit_db_changes('settings.changed', 'id', '', 'short_name', 'is_active', 'is_default_for_pos', 'sort_order');
CREATE TRIGGER trg_warehouses_set_updated_at BEFORE UPDATE ON public.warehouses FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ----------------------------------------------------------------------------------------------------
-- Права (GRANT); владелец объектов — роль мигратора
-- ----------------------------------------------------------------------------------------------------
GRANT USAGE ON SCHEMA catalog_sync TO pos_app;
GRANT USAGE ON SCHEMA catalog_sync TO pos_backup;
GRANT USAGE ON SCHEMA catalog_sync TO pos_readonly;
GRANT USAGE ON SCHEMA public TO pos_app;
GRANT USAGE ON SCHEMA public TO pos_backup;
GRANT USAGE ON SCHEMA public TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE catalog_sync.deletions TO pos_app;
GRANT SELECT ON TABLE catalog_sync.deletions TO pos_backup;
GRANT SELECT ON TABLE catalog_sync.deletions TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.app_pins TO pos_app;
GRANT SELECT ON TABLE public.app_pins TO pos_backup;
GRANT SELECT ON TABLE public.app_pins TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.app_settings TO pos_app;
GRANT SELECT ON TABLE public.app_settings TO pos_backup;
GRANT SELECT ON TABLE public.app_settings TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.audit_anchors TO pos_app;
GRANT SELECT ON TABLE public.audit_anchors TO pos_backup;
GRANT SELECT ON TABLE public.audit_anchors TO pos_readonly;
GRANT INSERT, SELECT ON TABLE public.audit_logs TO pos_app;
GRANT SELECT ON TABLE public.audit_logs TO pos_backup;
GRANT SELECT ON TABLE public.audit_logs TO pos_readonly;
GRANT SELECT ON SEQUENCE public.audit_logs_chain_seq TO pos_backup;
GRANT SELECT, USAGE ON SEQUENCE public.audit_logs_chain_seq TO pos_app;
GRANT SELECT ON SEQUENCE public.audit_logs_seq_seq TO pos_backup;
GRANT SELECT, USAGE ON SEQUENCE public.audit_logs_seq_seq TO pos_app;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.barcodes TO pos_app;
GRANT SELECT ON TABLE public.barcodes TO pos_backup;
GRANT SELECT ON TABLE public.barcodes TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.cart_items TO pos_app;
GRANT SELECT ON TABLE public.cart_items TO pos_backup;
GRANT SELECT ON TABLE public.cart_items TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.carts TO pos_app;
GRANT SELECT ON TABLE public.carts TO pos_backup;
GRANT SELECT ON TABLE public.carts TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.categories TO pos_app;
GRANT SELECT ON TABLE public.categories TO pos_backup;
GRANT SELECT ON TABLE public.categories TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.consents TO pos_app;
GRANT SELECT ON TABLE public.consents TO pos_backup;
GRANT SELECT ON TABLE public.consents TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.customer_contacts TO pos_app;
GRANT SELECT ON TABLE public.customer_contacts TO pos_backup;
GRANT SELECT ON TABLE public.customer_contacts TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.customer_links TO pos_app;
GRANT SELECT ON TABLE public.customer_links TO pos_backup;
GRANT SELECT ON TABLE public.customer_links TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.customers TO pos_app;
GRANT SELECT ON TABLE public.customers TO pos_backup;
GRANT SELECT ON TABLE public.customers TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.dev_outbox TO pos_app;
GRANT SELECT ON TABLE public.dev_outbox TO pos_backup;
GRANT SELECT ON TABLE public.dev_outbox TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.devices TO pos_app;
GRANT SELECT ON TABLE public.devices TO pos_backup;
GRANT SELECT ON TABLE public.devices TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.discount_rules TO pos_app;
GRANT SELECT ON TABLE public.discount_rules TO pos_backup;
GRANT SELECT ON TABLE public.discount_rules TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.favorites_customers TO pos_app;
GRANT SELECT ON TABLE public.favorites_customers TO pos_backup;
GRANT SELECT ON TABLE public.favorites_customers TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.favorites_products TO pos_app;
GRANT SELECT ON TABLE public.favorites_products TO pos_backup;
GRANT SELECT ON TABLE public.favorites_products TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.idempotency_keys TO pos_app;
GRANT SELECT ON TABLE public.idempotency_keys TO pos_backup;
GRANT SELECT ON TABLE public.idempotency_keys TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.integration_tokens TO pos_app;
GRANT SELECT ON TABLE public.integration_tokens TO pos_backup;
GRANT SELECT ON TABLE public.integration_tokens TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.notifications TO pos_app;
GRANT SELECT ON TABLE public.notifications TO pos_backup;
GRANT SELECT ON TABLE public.notifications TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.onec_outbox TO pos_app;
GRANT SELECT ON TABLE public.onec_outbox TO pos_backup;
GRANT SELECT ON TABLE public.onec_outbox TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.order_items TO pos_app;
GRANT SELECT ON TABLE public.order_items TO pos_backup;
GRANT SELECT ON TABLE public.order_items TO pos_readonly;
GRANT INSERT, SELECT ON TABLE public.order_status_history TO pos_app;
GRANT SELECT ON TABLE public.order_status_history TO pos_backup;
GRANT SELECT ON TABLE public.order_status_history TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.orders TO pos_app;
GRANT SELECT ON TABLE public.orders TO pos_backup;
GRANT SELECT ON TABLE public.orders TO pos_readonly;
GRANT SELECT ON SEQUENCE public.orders_number_seq TO pos_backup;
GRANT SELECT, USAGE ON SEQUENCE public.orders_number_seq TO pos_app;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.otp_challenges TO pos_app;
GRANT SELECT ON TABLE public.otp_challenges TO pos_backup;
GRANT SELECT ON TABLE public.otp_challenges TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.packagings TO pos_app;
GRANT SELECT ON TABLE public.packagings TO pos_backup;
GRANT SELECT ON TABLE public.packagings TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.payment_webhook_events TO pos_app;
GRANT SELECT ON TABLE public.payment_webhook_events TO pos_backup;
GRANT SELECT ON TABLE public.payment_webhook_events TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.payments TO pos_app;
GRANT SELECT ON TABLE public.payments TO pos_backup;
GRANT SELECT ON TABLE public.payments TO pos_readonly;
GRANT SELECT ON SEQUENCE public.payments_number_seq TO pos_backup;
GRANT SELECT, USAGE ON SEQUENCE public.payments_number_seq TO pos_app;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.permissions TO pos_app;
GRANT SELECT ON TABLE public.permissions TO pos_backup;
GRANT SELECT ON TABLE public.permissions TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.price_lists TO pos_app;
GRANT SELECT ON TABLE public.price_lists TO pos_backup;
GRANT SELECT ON TABLE public.price_lists TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.prices TO pos_app;
GRANT SELECT ON TABLE public.prices TO pos_backup;
GRANT SELECT ON TABLE public.prices TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.print_jobs TO pos_app;
GRANT SELECT ON TABLE public.print_jobs TO pos_backup;
GRANT SELECT ON TABLE public.print_jobs TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.product_attributes TO pos_app;
GRANT SELECT ON TABLE public.product_attributes TO pos_backup;
GRANT SELECT ON TABLE public.product_attributes TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.product_images TO pos_app;
GRANT SELECT ON TABLE public.product_images TO pos_backup;
GRANT SELECT ON TABLE public.product_images TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.product_variants TO pos_app;
GRANT SELECT ON TABLE public.product_variants TO pos_backup;
GRANT SELECT ON TABLE public.product_variants TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.products TO pos_app;
GRANT SELECT ON TABLE public.products TO pos_backup;
GRANT SELECT ON TABLE public.products TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.rate_limit_counters TO pos_app;
GRANT SELECT ON TABLE public.rate_limit_counters TO pos_backup;
GRANT SELECT ON TABLE public.rate_limit_counters TO pos_readonly;
GRANT INSERT, SELECT, UPDATE ON TABLE public.receivable_documents TO pos_app;
GRANT SELECT ON TABLE public.receivable_documents TO pos_backup;
GRANT SELECT ON TABLE public.receivable_documents TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.receivables TO pos_app;
GRANT SELECT ON TABLE public.receivables TO pos_backup;
GRANT SELECT ON TABLE public.receivables TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.recent_products TO pos_app;
GRANT SELECT ON TABLE public.recent_products TO pos_backup;
GRANT SELECT ON TABLE public.recent_products TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.return_request_items TO pos_app;
GRANT SELECT ON TABLE public.return_request_items TO pos_backup;
GRANT SELECT ON TABLE public.return_request_items TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.return_requests TO pos_app;
GRANT SELECT ON TABLE public.return_requests TO pos_backup;
GRANT SELECT ON TABLE public.return_requests TO pos_readonly;
GRANT SELECT ON SEQUENCE public.return_requests_number_seq TO pos_backup;
GRANT SELECT, USAGE ON SEQUENCE public.return_requests_number_seq TO pos_app;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.role_discount_limits TO pos_app;
GRANT SELECT ON TABLE public.role_discount_limits TO pos_backup;
GRANT SELECT ON TABLE public.role_discount_limits TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.role_permissions TO pos_app;
GRANT SELECT ON TABLE public.role_permissions TO pos_backup;
GRANT SELECT ON TABLE public.role_permissions TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.roles TO pos_app;
GRANT SELECT ON TABLE public.roles TO pos_backup;
GRANT SELECT ON TABLE public.roles TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.search_words TO pos_app;
GRANT SELECT ON TABLE public.search_words TO pos_backup;
GRANT SELECT ON TABLE public.search_words TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.sessions TO pos_app;
GRANT SELECT ON TABLE public.sessions TO pos_backup;
GRANT SELECT ON TABLE public.sessions TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.shipment_items TO pos_app;
GRANT SELECT ON TABLE public.shipment_items TO pos_backup;
GRANT SELECT ON TABLE public.shipment_items TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.shipments TO pos_app;
GRANT SELECT ON TABLE public.shipments TO pos_backup;
GRANT SELECT ON TABLE public.shipments TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.sms_outbox TO pos_app;
GRANT SELECT ON TABLE public.sms_outbox TO pos_backup;
GRANT SELECT ON TABLE public.sms_outbox TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.stock_balances TO pos_app;
GRANT SELECT ON TABLE public.stock_balances TO pos_backup;
GRANT SELECT ON TABLE public.stock_balances TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.sync_entity_versions TO pos_app;
GRANT SELECT ON TABLE public.sync_entity_versions TO pos_backup;
GRANT SELECT ON TABLE public.sync_entity_versions TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.sync_errors TO pos_app;
GRANT SELECT ON TABLE public.sync_errors TO pos_backup;
GRANT SELECT ON TABLE public.sync_errors TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.sync_node_state TO pos_app;
GRANT SELECT ON TABLE public.sync_node_state TO pos_backup;
GRANT SELECT ON TABLE public.sync_node_state TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.sync_runs TO pos_app;
GRANT SELECT ON TABLE public.sync_runs TO pos_backup;
GRANT SELECT ON TABLE public.sync_runs TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.sync_state TO pos_app;
GRANT SELECT ON TABLE public.sync_state TO pos_backup;
GRANT SELECT ON TABLE public.sync_state TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.token_denylist TO pos_app;
GRANT SELECT ON TABLE public.token_denylist TO pos_backup;
GRANT SELECT ON TABLE public.token_denylist TO pos_readonly;
GRANT INSERT, SELECT ON TABLE public.transactions TO pos_app;
GRANT SELECT ON TABLE public.transactions TO pos_backup;
GRANT SELECT ON TABLE public.transactions TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.units TO pos_app;
GRANT SELECT ON TABLE public.units TO pos_backup;
GRANT SELECT ON TABLE public.units TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.user_invitations TO pos_app;
GRANT SELECT ON TABLE public.user_invitations TO pos_backup;
GRANT SELECT ON TABLE public.user_invitations TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.user_profiles TO pos_app;
GRANT SELECT ON TABLE public.user_profiles TO pos_backup;
GRANT SELECT ON TABLE public.user_profiles TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.user_roles TO pos_app;
GRANT SELECT ON TABLE public.user_roles TO pos_backup;
GRANT SELECT ON TABLE public.user_roles TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.users TO pos_app;
GRANT SELECT ON TABLE public.users TO pos_backup;
GRANT SELECT ON TABLE public.users TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.variant_attribute_values TO pos_app;
GRANT SELECT ON TABLE public.variant_attribute_values TO pos_backup;
GRANT SELECT ON TABLE public.variant_attribute_values TO pos_readonly;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.warehouses TO pos_app;
GRANT SELECT ON TABLE public.warehouses TO pos_backup;
GRANT SELECT ON TABLE public.warehouses TO pos_readonly;

-- ----------------------------------------------------------------------------------------------------
-- Права по умолчанию для будущих объектов
-- ----------------------------------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA public GRANT DELETE, INSERT, SELECT, UPDATE ON TABLES TO pos_app;
ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA public GRANT SELECT ON TABLES TO pos_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA public GRANT SELECT ON TABLES TO pos_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA public GRANT SELECT, USAGE ON SEQUENCES TO pos_app;

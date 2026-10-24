-- =====================================================================================================
-- 0001_init.sql — RM-B-005: схема БД «Оптомстрой POS» (PostgreSQL 17)
--
-- Источник истины: docs/specification/07_DATA_MODEL.md v1.6 — карточки §5 (64 таблицы), enum-ы §6.1
-- (45 типов), CHECK-перечни §6.1.1, CHECK автоматов §6.3–§6.5, деньги §7.5, outbox §8.2, row_version §8.3,
-- аудит §9 (триггеры, хэш-цепочка, INSERT-only права), поиск §10, DDL-примеры §14; ядро R0 v1.9
-- (§6, §17.3, §22, §24). При расхождении примера §14 и карточки §5 действует карточка (DATA-285).
-- Решения по неоднозначностям ТЗ — pos-api/migrations/NOTES.md.
--
-- Порядок: расширения → роли БД → enum-ы → функции → таблицы (по FK) → отложенные FK → триггеры →
-- аудит БД → права → seed. Файл идемпотентен: IF NOT EXISTS / CREATE OR REPLACE / охранные DO-блоки,
-- повторное применение не меняет схему (проверка RM-C-006: run-sql.mjs --repeat-strict).
-- Применение: psql -v ON_ERROR_STOP=1 -f pos-api/migrations/0001_init.sql   (dev/test-таблица dev_outbox — pos-api/db/migrations-dev/)
--          dev/CI: PGOPTIONS='-c app.env=test' psql … или
--          node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql --check scripts/check_tables.sql
-- Поведенческие проверки: pos-api/test/sql/check_ddl_behavior.sql. Исправления по docs/reviews/B_architecture_review.md
-- (B-AR-01, -03, -05, -09, -19, -20) — NOTES.md §10.
-- =====================================================================================================

BEGIN;

-- -----------------------------------------------------------------------------------------------------
-- 1. Расширения (07 §2.1, §14.1): pgcrypto — digest() для хэш-цепочки аудита; pg_trgm, unaccent — поиск §10
-- -----------------------------------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- -----------------------------------------------------------------------------------------------------
-- 2. Роли БД (07 §2.1 «Схема прав БД», §9.4, §14.1). Создаются, только если их ещё нет (кластерные объекты;
--    пароли задаёт эксплуатация, 16). Права выдаются в разделе 12.
-- -----------------------------------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_migrate') THEN CREATE ROLE pos_migrate LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_app') THEN CREATE ROLE pos_app LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_readonly') THEN CREATE ROLE pos_readonly LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_backup') THEN CREATE ROLE pos_backup LOGIN; END IF;
END $$;

-- -----------------------------------------------------------------------------------------------------
-- 3. Enum-ы (07 §6.1): ровно 45 типов, имена и порядок значений — как в таблице §6.1
-- -----------------------------------------------------------------------------------------------------
DO $$
BEGIN
  -- 17 типов ядра §6 (с дополнениями значений ядра §17.3, v1.7 §22.1)
  IF to_regtype('public.user_kind') IS NULL THEN CREATE TYPE user_kind AS ENUM ('staff','customer'); END IF;
  IF to_regtype('public.user_status') IS NULL THEN CREATE TYPE user_status AS ENUM ('pending','pending_activation','active','blocked','deleted'); END IF;
  IF to_regtype('public.role_code') IS NULL THEN CREATE TYPE role_code AS ENUM ('seller','cashier','senior_seller','admin','owner','customer','integration'); END IF;
  IF to_regtype('public.customer_link_status') IS NULL THEN CREATE TYPE customer_link_status AS ENUM ('proposed','confirmed','rejected','conflict'); END IF;
  IF to_regtype('public.cart_status') IS NULL THEN CREATE TYPE cart_status AS ENUM ('active','parked','converted','cleared'); END IF;
  IF to_regtype('public.order_status') IS NULL THEN CREATE TYPE order_status AS ENUM ('draft','submitting','submit_failed','pending_approval','awaiting_payment','approved','awaiting_shipment','shipped','partially_returned','closed','cancelled'); END IF;
  IF to_regtype('public.delivery_method') IS NULL THEN CREATE TYPE delivery_method AS ENUM ('pickup','delivery'); END IF;
  IF to_regtype('public.receiver_kind') IS NULL THEN CREATE TYPE receiver_kind AS ENUM ('customer','other_person'); END IF;
  IF to_regtype('public.payment_method') IS NULL THEN CREATE TYPE payment_method AS ENUM ('cash','qr_bakai','credit'); END IF;
  IF to_regtype('public.payment_status') IS NULL THEN CREATE TYPE payment_status AS ENUM ('initiated','cash_pending','qr_pending','qr_shown','qr_expired','manual_confirm','credit','received','voided','refunded'); END IF;
  IF to_regtype('public.return_request_status') IS NULL THEN CREATE TYPE return_request_status AS ENUM ('draft','submitted','accepted','rejected','completed'); END IF;
  IF to_regtype('public.transaction_kind') IS NULL THEN CREATE TYPE transaction_kind AS ENUM ('order_created','order_cancelled','payment_received','payment_voided','refund','discount_override','credit_sale_approved','manual_qr_confirm','return_requested'); END IF;
  IF to_regtype('public.sync_entity') IS NULL THEN CREATE TYPE sync_entity AS ENUM ('categories','products','variants','attributes','units','barcodes','images','warehouses','stock','prices','customers','receivables','sales_history','order_status','discounts','payment_docs','return_docs'); END IF;
  IF to_regtype('public.sync_mode') IS NULL THEN CREATE TYPE sync_mode AS ENUM ('full','incremental','manual','reconcile'); END IF;
  IF to_regtype('public.sync_run_status') IS NULL THEN CREATE TYPE sync_run_status AS ENUM ('queued','running','success','partial','failed'); END IF;
  IF to_regtype('public.outbox_status') IS NULL THEN CREATE TYPE outbox_status AS ENUM ('pending','sending','sent','confirmed','failed','dead','cancelled'); END IF;
  IF to_regtype('public.notification_kind') IS NULL THEN CREATE TYPE notification_kind AS ENUM ('sync_error','order_status','cart_price_changed','cart_stock_changed','credit_blocked','system','payment_status','return_status'); END IF;
  -- 27 типов, канонизированных ядром §17.3 (§5 карточки)
  IF to_regtype('public.invitation_status') IS NULL THEN CREATE TYPE invitation_status AS ENUM ('pending','accepted','revoked','expired'); END IF;
  IF to_regtype('public.device_platform') IS NULL THEN CREATE TYPE device_platform AS ENUM ('android','ios','windows'); END IF;
  IF to_regtype('public.session_kind') IS NULL THEN CREATE TYPE session_kind AS ENUM ('standard','biometric'); END IF;
  IF to_regtype('public.step_up_method') IS NULL THEN CREATE TYPE step_up_method AS ENUM ('pin','biometric','otp'); END IF;
  IF to_regtype('public.otp_purpose') IS NULL THEN CREATE TYPE otp_purpose AS ENUM ('login_or_register','step_up','phone_change_old','phone_change_new','customer_link'); END IF;
  IF to_regtype('public.otp_status') IS NULL THEN CREATE TYPE otp_status AS ENUM ('sent','verified','expired','locked','failed_delivery','superseded'); END IF;
  IF to_regtype('public.consent_kind') IS NULL THEN CREATE TYPE consent_kind AS ENUM ('personal_data','sms','biometrics_device','activity_sphere','face_scan'); END IF;
  IF to_regtype('public.attribute_value_type') IS NULL THEN CREATE TYPE attribute_value_type AS ENUM ('text','number','boolean','list'); END IF;
  IF to_regtype('public.barcode_type') IS NULL THEN CREATE TYPE barcode_type AS ENUM ('EAN13','EAN8','UPC','CODE128','CODE39','QR','other'); END IF;
  IF to_regtype('public.image_status') IS NULL THEN CREATE TYPE image_status AS ENUM ('pending','downloading','ready','failed','missing_source'); END IF;
  IF to_regtype('public.customer_source') IS NULL THEN CREATE TYPE customer_source AS ENUM ('onec','pos'); END IF;
  IF to_regtype('public.customer_type') IS NULL THEN CREATE TYPE customer_type AS ENUM ('individual','entrepreneur','legal'); END IF;
  IF to_regtype('public.customer_onec_status') IS NULL THEN CREATE TYPE customer_onec_status AS ENUM ('n_a','pending','confirmed','rejected','duplicate'); END IF;
  IF to_regtype('public.contact_kind') IS NULL THEN CREATE TYPE contact_kind AS ENUM ('phone','address','email','other'); END IF;
  IF to_regtype('public.link_match_method') IS NULL THEN CREATE TYPE link_match_method AS ENUM ('phone','manual_admin','onec_created'); END IF;
  IF to_regtype('public.discount_source') IS NULL THEN CREATE TYPE discount_source AS ENUM ('onec','pos'); END IF;
  IF to_regtype('public.discount_kind') IS NULL THEN CREATE TYPE discount_kind AS ENUM ('percent','fixed_amount','price_list'); END IF;
  IF to_regtype('public.status_change_source') IS NULL THEN CREATE TYPE status_change_source AS ENUM ('pos_user','pos_system','onec_sync','onec_response'); END IF;
  IF to_regtype('public.transaction_source') IS NULL THEN CREATE TYPE transaction_source AS ENUM ('pos','onec'); END IF;
  IF to_regtype('public.return_reason') IS NULL THEN CREATE TYPE return_reason AS ENUM ('defect','wrong_item','not_suitable','surplus','seller_error','other'); END IF;
  IF to_regtype('public.sync_trigger') IS NULL THEN CREATE TYPE sync_trigger AS ENUM ('schedule','manual','retry','dependency'); END IF;
  IF to_regtype('public.outbox_aggregate') IS NULL THEN CREATE TYPE outbox_aggregate AS ENUM ('order','payment','customer','return_request'); END IF;
  IF to_regtype('public.idempotency_status') IS NULL THEN CREATE TYPE idempotency_status AS ENUM ('in_progress','completed'); END IF;
  IF to_regtype('public.audit_level') IS NULL THEN CREATE TYPE audit_level AS ENUM ('app','db'); END IF;
  IF to_regtype('public.print_document_kind') IS NULL THEN CREATE TYPE print_document_kind AS ENUM ('invoice','waybill','receipt'); END IF;
  IF to_regtype('public.print_job_status') IS NULL THEN CREATE TYPE print_job_status AS ENUM ('queued','ready','failed','unavailable_onec'); END IF;
  IF to_regtype('public.sms_status') IS NULL THEN CREATE TYPE sms_status AS ENUM ('queued','sent','delivered','failed','expired'); END IF;
  -- 1 тип ядра v1.5 §20.2 п.10
  IF to_regtype('public.onec_sync_state') IS NULL THEN CREATE TYPE onec_sync_state AS ENUM ('unknown','pending','linked','missing','ambiguous'); END IF;
END $$;

-- -----------------------------------------------------------------------------------------------------
-- 4. Общие функции (07 §14.1, §7.2, §10.1)
-- -----------------------------------------------------------------------------------------------------
-- UUID v7 (PG17 не имеет uuidv7(); на PG18 заменяется встроенной без изменения схемы — DATA-286)
CREATE OR REPLACE FUNCTION uuid_generate_v7() RETURNS uuid LANGUAGE sql VOLATILE PARALLEL SAFE AS $$
  SELECT encode(
    set_bit(set_bit(
      overlay(uuid_send(gen_random_uuid())
              placing substring(int8send((extract(epoch from clock_timestamp()) * 1000)::bigint) from 3)
              from 1 for 6),
      52, 1), 53, 1), 'hex')::uuid
$$;

-- updated_at обновляется триггером, не приложением (DATA-002)
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

-- округление «половина от нуля» (07 §7.2; round(numeric, int) PostgreSQL округляет половину от нуля)
CREATE OR REPLACE FUNCTION round_half_up(v numeric, s int) RETURNS numeric
  LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$ SELECT round(v, s) $$;

-- нормализация поиска (07 §10.1)
CREATE OR REPLACE FUNCTION immutable_unaccent(text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
  AS $$ SELECT public.unaccent('public.unaccent', $1) $$;

CREATE OR REPLACE FUNCTION norm_search(text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
  AS $$ SELECT trim(regexp_replace(immutable_unaccent(replace(replace(lower($1),'ё','е'),'Ё','Е')), '[[:space:][:punct:]]+', ' ', 'g')) $$;

CREATE OR REPLACE FUNCTION norm_sku(text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
  AS $$ SELECT upper(regexp_replace($1, '[[:space:]\-_./]+', '', 'g')) $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_ts_config WHERE cfgname = 'ru_unaccent' AND cfgnamespace = 'public'::regnamespace) THEN
    CREATE TEXT SEARCH CONFIGURATION public.ru_unaccent ( COPY = pg_catalog.russian );
    ALTER TEXT SEARCH CONFIGURATION public.ru_unaccent
      ALTER MAPPING FOR hword, hword_part, word WITH public.unaccent, russian_stem;
  END IF;
END $$;

-- =====================================================================================================
-- 5. Домен auth (07 §5.A)
-- =====================================================================================================

-- 5.1 users — DATA-100 (FK invitation_id → user_invitations добавляется после создания user_invitations)
CREATE TABLE IF NOT EXISTS users (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  phone_e164          text CONSTRAINT users_phone_e164_chk CHECK (phone_e164 ~ '^\+996[0-9]{9}$'),
  phone_verified_at   timestamptz,
  kind                user_kind NOT NULL,
  status              user_status NOT NULL DEFAULT 'pending',
  permissions_version integer NOT NULL DEFAULT 1,
  invitation_id       uuid,
  last_login_at       timestamptz,
  blocked_at          timestamptz,
  blocked_by_user_id  uuid CONSTRAINT users_blocked_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  block_reason        text,
  deleted_at          timestamptz,
  deleted_phone_hmac  bytea,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS users_phone_e164_uq ON users (phone_e164) WHERE phone_e164 IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS users_kind_status_idx ON users (kind, status);
CREATE INDEX IF NOT EXISTS users_deleted_phone_hmac_idx ON users (deleted_phone_hmac) WHERE deleted_phone_hmac IS NOT NULL;

-- 5.3 user_invitations — DATA-102
CREATE TABLE IF NOT EXISTS user_invitations (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  phone_e164          text NOT NULL CONSTRAINT user_invitations_phone_e164_chk CHECK (phone_e164 ~ '^\+996[0-9]{9}$'),
  role                role_code NOT NULL CONSTRAINT user_invitations_role_chk CHECK (role IN ('seller','cashier','senior_seller','admin','owner')),
  full_name           text NOT NULL CONSTRAINT user_invitations_full_name_chk CHECK (length(full_name) BETWEEN 2 AND 150),
  invited_by_user_id  uuid NOT NULL CONSTRAINT user_invitations_invited_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  status              invitation_status NOT NULL DEFAULT 'pending',
  expires_at          timestamptz NOT NULL,
  accepted_user_id    uuid CONSTRAINT user_invitations_accepted_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  accepted_at         timestamptz,
  revoked_at          timestamptz,
  note                text CONSTRAINT user_invitations_note_chk CHECK (length(note) <= 200),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS user_invitations_phone_pending_uq ON user_invitations (phone_e164) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS user_invitations_status_expires_idx ON user_invitations (status, expires_at);
CREATE INDEX IF NOT EXISTS user_invitations_invited_by_idx ON user_invitations (invited_by_user_id);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_invitation_id_fk' AND conrelid = 'public.users'::regclass) THEN
    ALTER TABLE users ADD CONSTRAINT users_invitation_id_fk FOREIGN KEY (invitation_id)
      REFERENCES user_invitations(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
  END IF;
END $$;

-- 5.4 roles — DATA-103 (строки — seed 0002_rbac_seed.sql)
CREATE TABLE IF NOT EXISTS roles (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  code                role_code NOT NULL,
  name_ru             text NOT NULL,
  is_system           boolean NOT NULL DEFAULT true,
  is_assignable       boolean NOT NULL DEFAULT true,
  sort_order          smallint NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS roles_code_uq ON roles (code);

-- 5.5 permissions — DATA-104 (словарь — 11 §4.3, seed 0002)
CREATE TABLE IF NOT EXISTS permissions (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  code                text NOT NULL CONSTRAINT permissions_code_chk CHECK (code ~ '^[a-z_]+(\.[a-z_]+)+$'),
  description_ru      text NOT NULL,
  requires_step_up    boolean NOT NULL DEFAULT false,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS permissions_code_uq ON permissions (code);

-- 5.6 role_permissions — DATA-105
CREATE TABLE IF NOT EXISTS role_permissions (
  role_id             uuid NOT NULL CONSTRAINT role_permissions_role_id_fk REFERENCES roles(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  permission_id       uuid NOT NULL CONSTRAINT role_permissions_permission_id_fk REFERENCES permissions(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  constraint_json     jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (role_id, permission_id)
);
CREATE INDEX IF NOT EXISTS role_permissions_permission_idx ON role_permissions (permission_id);

-- 5.7 user_roles — DATA-106. Суррогатный PK id вместо (user_id, role_id) — B-AR-03 (docs/reviews/B_architecture_review.md):
--     история назначений не удаляется (revoked_at), поэтому повторная выдача ранее отозванной роли
--     (cashier → seller → cashier) — новая строка; активная пара (user_id, role_id) уникальна частичным индексом.
--     Предложение владельцу 07 §5.7 — pos-api/migrations/NOTES.md §10.
CREATE TABLE IF NOT EXISTS user_roles (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id             uuid NOT NULL CONSTRAINT user_roles_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  role_id             uuid NOT NULL CONSTRAINT user_roles_role_id_fk REFERENCES roles(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  granted_by_user_id  uuid CONSTRAINT user_roles_granted_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  granted_at          timestamptz NOT NULL DEFAULT now(),
  revoked_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS user_roles_user_role_active_uq ON user_roles (user_id, role_id) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS user_roles_one_active_uq ON user_roles (user_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS user_roles_user_granted_idx ON user_roles (user_id, granted_at);
CREATE INDEX IF NOT EXISTS user_roles_role_active_idx ON user_roles (role_id) WHERE revoked_at IS NULL;

-- 5.8 devices — DATA-107
CREATE TABLE IF NOT EXISTS devices (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id             uuid NOT NULL CONSTRAINT devices_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  device_key          text NOT NULL CONSTRAINT devices_device_key_chk CHECK (device_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
  platform            device_platform NOT NULL,
  model               text,
  os_version          text,
  app_version         text,
  display_name        text,
  biometric_enrolled_at timestamptz,
  settings            jsonb NOT NULL DEFAULT '{}',
  last_seen_at        timestamptz,
  last_ip             inet,
  revoked_at          timestamptz,
  revoked_by_user_id  uuid CONSTRAINT devices_revoked_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT devices_user_device_key_uq UNIQUE (user_id, device_key)
);
CREATE INDEX IF NOT EXISTS devices_user_active_idx ON devices (user_id) WHERE revoked_at IS NULL;

-- 5.11 otp_challenges — DATA-110 (FK sms_outbox_id → sms_outbox добавляется после sms_outbox)
CREATE TABLE IF NOT EXISTS otp_challenges (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  phone_e164          text NOT NULL,
  user_id             uuid CONSTRAINT otp_challenges_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  purpose             otp_purpose NOT NULL,
  code_hmac           bytea NOT NULL,
  salt                bytea NOT NULL,
  pepper_version      smallint NOT NULL,
  expires_at          timestamptz NOT NULL,
  attempts            smallint NOT NULL DEFAULT 0,
  status              otp_status NOT NULL,
  verified_at         timestamptz,
  replayed_at         timestamptz,
  registration_token_hash bytea,
  registration_token_expires_at timestamptz,
  sms_outbox_id       uuid,
  device_key          text,
  ip                  inet,
  request_id          text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS otp_challenges_active_uq ON otp_challenges (phone_e164, purpose) WHERE status = 'sent';
CREATE INDEX IF NOT EXISTS otp_challenges_phone_created_idx ON otp_challenges (phone_e164, created_at DESC);
CREATE INDEX IF NOT EXISTS otp_challenges_expires_idx ON otp_challenges (expires_at);
CREATE INDEX IF NOT EXISTS otp_challenges_registration_token_idx ON otp_challenges (registration_token_hash) WHERE registration_token_hash IS NOT NULL;

-- 5.61 sms_outbox — DATA-160
CREATE TABLE IF NOT EXISTS sms_outbox (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  phone_e164          text NOT NULL,
  template_key        text NOT NULL CONSTRAINT sms_outbox_template_key_chk CHECK (template_key IN ('otp_login','otp_step_up','otp_phone_change','otp_customer_link')),
  provider            text NOT NULL DEFAULT 'smspro' CONSTRAINT sms_outbox_provider_chk CHECK (provider IN ('smspro','fake')),
  provider_message_id text NOT NULL CONSTRAINT sms_outbox_provider_message_id_chk CHECK (provider_message_id ~ '^[A-Za-z0-9]{12}$'),
  provider_status_code smallint,
  delivery_status     text,
  status              sms_status NOT NULL DEFAULT 'queued',
  attempts            smallint NOT NULL DEFAULT 0,
  sent_at             timestamptz,
  delivered_at        timestamptz,
  error               text,
  otp_challenge_id    uuid CONSTRAINT sms_outbox_otp_challenge_id_fk REFERENCES otp_challenges(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  cost_units          numeric(10,2),
  outcome             text CONSTRAINT sms_outbox_outcome_chk CHECK (outcome IN ('ACCEPTED','ACCEPTED_TEST','RETRYABLE','PERMANENT','CONFIG_ERROR','INSUFFICIENT_FUNDS','INVALID_PHONE','DUPLICATE_ID')),
  sms_parts           smallint CONSTRAINT sms_outbox_sms_parts_chk CHECK (sms_parts >= 0),
  phones_recognized   smallint CONSTRAINT sms_outbox_phones_recognized_chk CHECK (phones_recognized >= 0),
  latency_ms          integer CONSTRAINT sms_outbox_latency_ms_chk CHECK (latency_ms >= 0),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS sms_outbox_provider_message_id_uq ON sms_outbox (provider_message_id);
CREATE INDEX IF NOT EXISTS sms_outbox_status_created_idx ON sms_outbox (status, created_at);
CREATE INDEX IF NOT EXISTS sms_outbox_phone_created_idx ON sms_outbox (phone_e164, created_at DESC);
CREATE INDEX IF NOT EXISTS sms_outbox_created_idx ON sms_outbox (created_at);
CREATE INDEX IF NOT EXISTS sms_outbox_otp_challenge_idx ON sms_outbox (otp_challenge_id);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'otp_challenges_sms_outbox_id_fk' AND conrelid = 'public.otp_challenges'::regclass) THEN
    ALTER TABLE otp_challenges ADD CONSTRAINT otp_challenges_sms_outbox_id_fk FOREIGN KEY (sms_outbox_id)
      REFERENCES sms_outbox(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
  END IF;
END $$;

-- 5.9 sessions — DATA-108
CREATE TABLE IF NOT EXISTS sessions (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id             uuid NOT NULL CONSTRAINT sessions_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  device_id           uuid NOT NULL CONSTRAINT sessions_device_id_fk REFERENCES devices(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  family_id           uuid NOT NULL,
  refresh_hash        bytea NOT NULL,
  prev_refresh_hash   bytea,
  kind                session_kind NOT NULL DEFAULT 'standard',
  issued_at           timestamptz NOT NULL DEFAULT now(),
  rotated_at          timestamptz,
  last_used_at        timestamptz,
  expires_at          timestamptz NOT NULL,
  idle_expires_at     timestamptz NOT NULL,
  step_up_until       timestamptz,
  step_up_method      step_up_method,
  unlocked_until      timestamptz,
  superseded_refresh_hash bytea,
  grace_used_at       timestamptz,
  created_from_challenge_id uuid CONSTRAINT sessions_created_from_challenge_id_fk REFERENCES otp_challenges(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  amr                 text[] NOT NULL DEFAULT '{sms}' CONSTRAINT sessions_amr_chk CHECK (amr <@ ARRAY['sms','pin','bio']),
  revoked_at          timestamptz,
  revoke_reason       text CONSTRAINT sessions_revoke_reason_chk CHECK (revoke_reason IN ('logout','logout_all','reuse_detected','admin','phone_changed','role_changed','expired','device_revoked','blocked','session_limit','device_mismatch','biometric_invalidated')),
  ip_last             inet,
  user_agent          text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS sessions_refresh_hash_uq ON sessions (refresh_hash);
CREATE INDEX IF NOT EXISTS sessions_user_active_idx ON sessions (user_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS sessions_family_idx ON sessions (family_id);
CREATE INDEX IF NOT EXISTS sessions_expires_idx ON sessions (expires_at);
CREATE INDEX IF NOT EXISTS sessions_prev_refresh_hash_idx ON sessions (prev_refresh_hash);
CREATE INDEX IF NOT EXISTS sessions_superseded_idx ON sessions (superseded_refresh_hash) WHERE superseded_refresh_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS sessions_created_from_challenge_idx ON sessions (created_from_challenge_id);
CREATE INDEX IF NOT EXISTS sessions_device_idx ON sessions (device_id);

-- 5.10 token_denylist — DATA-109 [ядро §17.3]
CREATE TABLE IF NOT EXISTS token_denylist (
  jti                 uuid PRIMARY KEY,
  token_kind          text NOT NULL DEFAULT 'access' CONSTRAINT token_denylist_token_kind_chk CHECK (token_kind IN ('access','registration','step_up')),
  session_id          uuid CONSTRAINT token_denylist_session_id_fk REFERENCES sessions(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  expires_at          timestamptz NOT NULL,
  reason              text NOT NULL CONSTRAINT token_denylist_reason_chk CHECK (reason IN ('logout','logout_all','role_changed','blocked','used','revoked')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT token_denylist_used_registration_chk CHECK (reason <> 'used' OR token_kind = 'registration')
);
CREATE INDEX IF NOT EXISTS token_denylist_expires_idx ON token_denylist (expires_at);
CREATE INDEX IF NOT EXISTS token_denylist_session_idx ON token_denylist (session_id);

-- 5.12 rate_limit_counters — DATA-111
CREATE TABLE IF NOT EXISTS rate_limit_counters (
  scope               text NOT NULL CONSTRAINT rate_limit_counters_scope_chk CHECK (scope IN ('otp_phone_15m','otp_phone_24h','otp_ip_1h','otp_device_24h','login_ip_1h','step_up_user_1h','webhook_ip_1m')),
  subject             text NOT NULL,
  window_start        timestamptz NOT NULL,
  count               integer NOT NULL DEFAULT 0,
  window_end          timestamptz NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (scope, subject, window_start)
);
CREATE INDEX IF NOT EXISTS rate_limit_counters_window_end_idx ON rate_limit_counters (window_end);

-- 5.13 app_pins — DATA-112
CREATE TABLE IF NOT EXISTS app_pins (
  user_id             uuid PRIMARY KEY CONSTRAINT app_pins_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  pin_hash            text NOT NULL,
  pepper_version      smallint NOT NULL,
  pin_length          smallint NOT NULL CONSTRAINT app_pins_pin_length_chk CHECK (pin_length BETWEEN 4 AND 6),
  failed_attempts     smallint NOT NULL DEFAULT 0,
  locked_until        timestamptz,
  changed_at          timestamptz NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- 5.14 consents — DATA-113
CREATE TABLE IF NOT EXISTS consents (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id             uuid NOT NULL CONSTRAINT consents_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  kind                consent_kind NOT NULL,
  version             text NOT NULL,
  text_sha256         bytea NOT NULL,
  granted_at          timestamptz NOT NULL,
  revoked_at          timestamptz,
  device_id           uuid CONSTRAINT consents_device_id_fk REFERENCES devices(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  ip                  inet,
  app_version         text,
  otp_challenge_id    uuid CONSTRAINT consents_otp_challenge_id_fk REFERENCES otp_challenges(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  face_scan_completed_at timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT consents_face_scan_chk CHECK (face_scan_completed_at IS NULL OR kind = 'face_scan')
);
CREATE UNIQUE INDEX IF NOT EXISTS consents_active_uq ON consents (user_id, kind, device_id) NULLS NOT DISTINCT WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS consents_user_idx ON consents (user_id);
CREATE INDEX IF NOT EXISTS consents_device_idx ON consents (device_id);

-- 5.62 integration_tokens — DATA-168 [ядро §17.3]
CREATE TABLE IF NOT EXISTS integration_tokens (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  name                text NOT NULL CONSTRAINT integration_tokens_name_chk CHECK (length(name) BETWEEN 2 AND 100),
  token_hash          bytea NOT NULL,
  token_prefix        text NOT NULL CONSTRAINT integration_tokens_token_prefix_chk CHECK (length(token_prefix) = 8),
  scope               text NOT NULL DEFAULT 'onec_inbound' CONSTRAINT integration_tokens_scope_chk CHECK (scope IN ('onec_inbound')),
  source              text NOT NULL DEFAULT 'operator_script' CONSTRAINT integration_tokens_source_chk CHECK (source IN ('operator_script')),
  created_by_user_id  uuid CONSTRAINT integration_tokens_created_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  expires_at          timestamptz NOT NULL,
  grace_until         timestamptz,
  revoked_at          timestamptz,
  revoked_by_user_id  uuid CONSTRAINT integration_tokens_revoked_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  revoke_reason       text CONSTRAINT integration_tokens_revoke_reason_chk CHECK (revoke_reason IN ('rotated','incident','disabled','expired')),
  last_used_at        timestamptz,
  last_used_ip        inet,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT integration_tokens_ttl_chk CHECK (expires_at <= created_at + interval '180 days')
);
CREATE UNIQUE INDEX IF NOT EXISTS integration_tokens_token_hash_uq ON integration_tokens (token_hash);
CREATE INDEX IF NOT EXISTS integration_tokens_expires_active_idx ON integration_tokens (expires_at) WHERE revoked_at IS NULL;

-- =====================================================================================================
-- 6. Домен catalog — реплики 1С (07 §5.B). Стандартный набор полей реплики: onec_ref, onec_code,
--    onec_data_version, deletion_mark, synced_at, source_hash (07 §2.1); частичный UNIQUE по onec_ref.
-- =====================================================================================================

-- 5.20 units — DATA-119
CREATE TABLE IF NOT EXISTS units (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  code                text NOT NULL,
  name                text NOT NULL,
  qty_precision       smallint NOT NULL CONSTRAINT units_qty_precision_chk CHECK (qty_precision BETWEEN 0 AND 3),
  is_integer_only     boolean GENERATED ALWAYS AS (qty_precision = 0) STORED,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS units_code_uq ON units (code);
CREATE UNIQUE INDEX IF NOT EXISTS units_onec_ref_uq ON units (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS units_updated_at_idx ON units (updated_at);

-- 5.24 warehouses — DATA-123
CREATE TABLE IF NOT EXISTS warehouses (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  name                text NOT NULL,
  short_name          text,
  is_active           boolean NOT NULL DEFAULT true,
  is_default_for_pos  boolean NOT NULL DEFAULT false,
  allow_sales         boolean NOT NULL DEFAULT true,
  sort_order          integer NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS warehouses_onec_ref_uq ON warehouses (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS warehouses_default_uq ON warehouses (is_default_for_pos) WHERE is_default_for_pos;
CREATE INDEX IF NOT EXISTS warehouses_updated_at_idx ON warehouses (updated_at);

-- 5.15 categories — DATA-114 (FK image_id → product_images добавляется после product_images)
CREATE TABLE IF NOT EXISTS categories (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  parent_id           uuid CONSTRAINT categories_parent_id_fk REFERENCES categories(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  name                text NOT NULL,
  name_norm           text GENERATED ALWAYS AS (norm_search(name)) STORED,
  path                text NOT NULL CONSTRAINT categories_path_chk CHECK (path ~ '^(/[0-9a-f-]{36})+$'),
  depth               smallint NOT NULL CONSTRAINT categories_depth_chk CHECK (depth BETWEEN 0 AND 10),
  sort_order          integer NOT NULL DEFAULT 0,
  image_id            uuid,
  icon_key            text,
  product_count_cache integer NOT NULL DEFAULT 0,
  is_visible          boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS categories_onec_ref_uq ON categories (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS categories_parent_idx ON categories (parent_id) WHERE NOT deletion_mark;
CREATE INDEX IF NOT EXISTS categories_path_idx ON categories (path text_pattern_ops);
CREATE INDEX IF NOT EXISTS categories_name_norm_trgm ON categories USING GIN (name_norm gin_trgm_ops);
CREATE INDEX IF NOT EXISTS categories_updated_at_idx ON categories (updated_at);

-- 5.16 products — DATA-115 (FK primary_image_id → product_images добавляется после product_images)
CREATE TABLE IF NOT EXISTS products (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  sku                 text,
  sku_norm            text GENERATED ALWAYS AS (norm_sku(sku)) STORED,
  name                text NOT NULL,
  full_name           text,
  name_norm           text GENERATED ALWAYS AS (norm_search(name)) STORED,
  description         text,
  brand               text,
  category_id         uuid CONSTRAINT products_category_id_fk REFERENCES categories(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  category_path_text  text,
  base_unit_id        uuid NOT NULL CONSTRAINT products_base_unit_id_fk REFERENCES units(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  has_variants        boolean NOT NULL DEFAULT false,
  is_weighted         boolean NOT NULL DEFAULT false,
  multiplicity        numeric(14,3) CONSTRAINT products_multiplicity_chk CHECK (multiplicity > 0),
  min_qty             numeric(14,3) CONSTRAINT products_min_qty_chk CHECK (min_qty > 0),
  attributes          jsonb NOT NULL DEFAULT '{}',
  search_vector       tsvector GENERATED ALWAYS AS (
      setweight(to_tsvector('public.ru_unaccent', coalesce(name,'')), 'A') ||
      setweight(to_tsvector('simple', coalesce(sku,'')), 'B') ||
      setweight(to_tsvector('public.ru_unaccent', coalesce(brand,'') || ' ' || coalesce(category_path_text,'')), 'C') ||
      setweight(to_tsvector('public.ru_unaccent', coalesce(description,'')), 'D')) STORED,
  primary_image_id    uuid,
  is_sellable         boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS products_onec_ref_uq ON products (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS products_category_idx ON products (category_id) WHERE NOT deletion_mark AND is_sellable;
CREATE INDEX IF NOT EXISTS products_search_vector_gin ON products USING GIN (search_vector) WITH (fastupdate = off);
CREATE INDEX IF NOT EXISTS products_name_norm_trgm ON products USING GIN (name_norm gin_trgm_ops) WITH (fastupdate = off);
CREATE INDEX IF NOT EXISTS products_sku_norm_idx ON products (sku_norm text_pattern_ops) WHERE sku_norm IS NOT NULL;
CREATE INDEX IF NOT EXISTS products_onec_code_idx ON products (onec_code);
CREATE INDEX IF NOT EXISTS products_updated_at_idx ON products (updated_at);
CREATE INDEX IF NOT EXISTS products_base_unit_idx ON products (base_unit_id);

-- 5.17 product_variants — DATA-116 (name_norm + GIN — 07 §10.2)
CREATE TABLE IF NOT EXISTS product_variants (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  product_id          uuid NOT NULL CONSTRAINT product_variants_product_id_fk REFERENCES products(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  is_default          boolean NOT NULL DEFAULT false,
  name                text NOT NULL DEFAULT '',
  sku                 text,
  sku_norm            text GENERATED ALWAYS AS (norm_sku(sku)) STORED,
  name_norm           text GENERATED ALWAYS AS (norm_search(name)) STORED,
  sort_order          integer NOT NULL DEFAULT 0,
  attributes          jsonb NOT NULL DEFAULT '{}',
  primary_image_id    uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_variants_default_or_ref_chk CHECK (is_default OR onec_ref IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS product_variants_onec_ref_uq ON product_variants (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS product_variants_default_uq ON product_variants (product_id) WHERE is_default;
CREATE INDEX IF NOT EXISTS product_variants_product_idx ON product_variants (product_id) WHERE NOT deletion_mark;
CREATE INDEX IF NOT EXISTS product_variants_sku_norm_idx ON product_variants (sku_norm text_pattern_ops) WHERE sku_norm IS NOT NULL;
CREATE INDEX IF NOT EXISTS product_variants_name_norm_trgm ON product_variants USING GIN (name_norm gin_trgm_ops) WITH (fastupdate = off);
CREATE INDEX IF NOT EXISTS product_variants_updated_at_idx ON product_variants (updated_at);

-- 5.23 product_images — DATA-122 (внешний id — source_ref/source_version, стандартный набор не применяется)
CREATE TABLE IF NOT EXISTS product_images (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  product_id          uuid CONSTRAINT product_images_product_id_fk REFERENCES products(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  variant_id          uuid CONSTRAINT product_images_variant_id_fk REFERENCES product_variants(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  category_id         uuid CONSTRAINT product_images_category_id_fk REFERENCES categories(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  source_ref          text NOT NULL,
  source_version      text,
  checksum_sha256     bytea,
  storage_key         text,
  original_mime       text,
  original_bytes      integer,
  width               integer,
  height              integer,
  sizes               jsonb,
  sort_order          integer NOT NULL DEFAULT 0,
  is_primary          boolean NOT NULL DEFAULT false,
  status              image_status NOT NULL DEFAULT 'pending',
  error               text,
  attempts            smallint,
  next_attempt_at     timestamptz,
  deleted_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_images_variant_needs_product_chk CHECK (variant_id IS NULL OR product_id IS NOT NULL),
  CONSTRAINT product_images_owner_chk CHECK (num_nonnulls(product_id, category_id) = 1)
);
CREATE UNIQUE INDEX IF NOT EXISTS product_images_source_ref_uq ON product_images (source_ref) WHERE deleted_at IS NULL;
-- B-AR-19: category_id в ключе — у каждой категории своё главное фото (у категорийных фото product_id/variant_id NULL);
--          у фото товара category_id всегда NULL (product_images_owner_chk), поэтому правило для товаров не меняется.
CREATE UNIQUE INDEX IF NOT EXISTS product_images_primary_uq ON product_images (product_id, variant_id, category_id) NULLS NOT DISTINCT WHERE is_primary AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS product_images_product_sort_idx ON product_images (product_id, sort_order) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS product_images_variant_idx ON product_images (variant_id);
CREATE INDEX IF NOT EXISTS product_images_category_idx ON product_images (category_id);
CREATE INDEX IF NOT EXISTS product_images_checksum_idx ON product_images (checksum_sha256);
CREATE INDEX IF NOT EXISTS product_images_download_queue_idx ON product_images (status, next_attempt_at) WHERE status IN ('pending','failed');
CREATE INDEX IF NOT EXISTS product_images_updated_at_idx ON product_images (updated_at);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'categories_image_id_fk' AND conrelid = 'public.categories'::regclass) THEN
    ALTER TABLE categories ADD CONSTRAINT categories_image_id_fk FOREIGN KEY (image_id)
      REFERENCES product_images(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'products_primary_image_id_fk' AND conrelid = 'public.products'::regclass) THEN
    ALTER TABLE products ADD CONSTRAINT products_primary_image_id_fk FOREIGN KEY (primary_image_id)
      REFERENCES product_images(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'product_variants_primary_image_id_fk' AND conrelid = 'public.product_variants'::regclass) THEN
    ALTER TABLE product_variants ADD CONSTRAINT product_variants_primary_image_id_fk FOREIGN KEY (primary_image_id)
      REFERENCES product_images(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
  END IF;
END $$;

-- 5.18 product_attributes — DATA-117
CREATE TABLE IF NOT EXISTS product_attributes (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  code                text NOT NULL,
  name                text NOT NULL,
  value_type          attribute_value_type NOT NULL,
  unit_label          text,
  is_filterable       boolean NOT NULL DEFAULT false,
  is_variant_axis     boolean NOT NULL DEFAULT false,
  sort_order          integer NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS product_attributes_code_uq ON product_attributes (code);
CREATE UNIQUE INDEX IF NOT EXISTS product_attributes_onec_ref_uq ON product_attributes (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS product_attributes_filterable_idx ON product_attributes (is_filterable) WHERE is_filterable;
CREATE INDEX IF NOT EXISTS product_attributes_updated_at_idx ON product_attributes (updated_at);

-- 5.19 variant_attribute_values — DATA-118 (производная таблица-срез: физическое удаление, без deletion_mark)
CREATE TABLE IF NOT EXISTS variant_attribute_values (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  variant_id          uuid NOT NULL CONSTRAINT variant_attribute_values_variant_id_fk REFERENCES product_variants(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  attribute_id        uuid NOT NULL CONSTRAINT variant_attribute_values_attribute_id_fk REFERENCES product_attributes(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  value_text          text,
  value_text_norm     text GENERATED ALWAYS AS (norm_search(value_text)) STORED,
  value_number        numeric(18,6),
  value_bool          boolean,
  onec_value_ref      uuid,
  synced_at           timestamptz NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT variant_attribute_values_one_value_chk CHECK (num_nonnulls(value_text, value_number, value_bool) = 1),
  CONSTRAINT variant_attribute_values_variant_attribute_uq UNIQUE (variant_id, attribute_id)
);
CREATE INDEX IF NOT EXISTS variant_attribute_values_attr_text_idx ON variant_attribute_values (attribute_id, value_text_norm);
CREATE INDEX IF NOT EXISTS variant_attribute_values_attr_number_idx ON variant_attribute_values (attribute_id, value_number);
CREATE INDEX IF NOT EXISTS variant_attribute_values_synced_idx ON variant_attribute_values (synced_at);

-- 5.21 packagings — DATA-120
CREATE TABLE IF NOT EXISTS packagings (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  product_id          uuid CONSTRAINT packagings_product_id_fk REFERENCES products(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  packaging_set_ref   uuid,
  unit_id             uuid NOT NULL CONSTRAINT packagings_unit_id_fk REFERENCES units(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  name                text NOT NULL,
  factor              numeric(14,3) NOT NULL CONSTRAINT packagings_factor_chk CHECK (factor > 0),
  allow_fraction      boolean NOT NULL DEFAULT false,
  is_default          boolean NOT NULL DEFAULT false,
  sort_order          integer NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT packagings_owner_chk CHECK (product_id IS NOT NULL OR packaging_set_ref IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS packagings_onec_ref_uq ON packagings (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS packagings_product_unit_factor_uq ON packagings (product_id, unit_id, factor) WHERE product_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS packagings_product_idx ON packagings (product_id) WHERE NOT deletion_mark;
CREATE INDEX IF NOT EXISTS packagings_set_ref_idx ON packagings (packaging_set_ref);
CREATE INDEX IF NOT EXISTS packagings_unit_idx ON packagings (unit_id);
CREATE INDEX IF NOT EXISTS packagings_updated_at_idx ON packagings (updated_at);

-- 5.22 barcodes — DATA-121 (onec_ref не применим — NULL; ключ регистра = value)
CREATE TABLE IF NOT EXISTS barcodes (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  value               text NOT NULL CONSTRAINT barcodes_value_chk CHECK (value ~ '^[0-9A-Za-z\-\.\ ]{4,64}$'),
  product_id          uuid NOT NULL CONSTRAINT barcodes_product_id_fk REFERENCES products(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  variant_id          uuid NOT NULL CONSTRAINT barcodes_variant_id_fk REFERENCES product_variants(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  packaging_id        uuid CONSTRAINT barcodes_packaging_id_fk REFERENCES packagings(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  type                barcode_type NOT NULL DEFAULT 'other',
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS barcodes_value_uq ON barcodes (value);
CREATE INDEX IF NOT EXISTS barcodes_variant_idx ON barcodes (variant_id);
CREATE INDEX IF NOT EXISTS barcodes_product_idx ON barcodes (product_id);
CREATE INDEX IF NOT EXISTS barcodes_packaging_idx ON barcodes (packaging_id);
CREATE INDEX IF NOT EXISTS barcodes_updated_at_idx ON barcodes (updated_at);

-- 5.25 stock_balances — DATA-124 (составной ключ регистра; onec_ref не применим)
CREATE TABLE IF NOT EXISTS stock_balances (
  variant_id          uuid NOT NULL CONSTRAINT stock_balances_variant_id_fk REFERENCES product_variants(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  warehouse_id        uuid NOT NULL CONSTRAINT stock_balances_warehouse_id_fk REFERENCES warehouses(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  quantity            numeric(14,3) NOT NULL DEFAULT 0,
  reserved            numeric(14,3) NOT NULL DEFAULT 0,
  available_onec      numeric(14,3),
  available           numeric(14,3) GENERATED ALWAYS AS (coalesce(available_onec, quantity - reserved)) STORED,
  onec_snapshot_at    timestamptz NOT NULL,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (variant_id, warehouse_id)
);
CREATE INDEX IF NOT EXISTS stock_balances_wh_avail_idx ON stock_balances (warehouse_id) WHERE available > 0;
CREATE INDEX IF NOT EXISTS stock_balances_warehouse_idx ON stock_balances (warehouse_id);
CREATE INDEX IF NOT EXISTS stock_balances_synced_idx ON stock_balances (synced_at);

-- 5.26 price_lists — DATA-125
CREATE TABLE IF NOT EXISTS price_lists (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  name                text NOT NULL,
  currency            char(3) NOT NULL DEFAULT 'KGS' CONSTRAINT price_lists_currency_chk CHECK (currency = 'KGS'),
  price_includes_vat  boolean,
  is_used_for_sales   boolean NOT NULL DEFAULT true,
  is_default          boolean NOT NULL DEFAULT false,
  visible_to_roles    role_code[] NOT NULL DEFAULT '{seller,cashier,senior_seller,admin,owner}',
  sort_order          integer NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS price_lists_onec_ref_uq ON price_lists (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS price_lists_default_uq ON price_lists (is_default) WHERE is_default;
CREATE INDEX IF NOT EXISTS price_lists_updated_at_idx ON price_lists (updated_at);

-- 5.27 prices — DATA-126 (срез последних цен: физическое удаление; onec_ref не применим)
CREATE TABLE IF NOT EXISTS prices (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  variant_id          uuid NOT NULL CONSTRAINT prices_variant_id_fk REFERENCES product_variants(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  price_list_id       uuid NOT NULL CONSTRAINT prices_price_list_id_fk REFERENCES price_lists(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  packaging_id        uuid CONSTRAINT prices_packaging_id_fk REFERENCES packagings(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  price               numeric(14,2) NOT NULL CONSTRAINT prices_price_chk CHECK (price >= 0),
  valid_from          timestamptz,
  onec_document_ref   uuid,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS prices_variant_list_pack_uq ON prices (variant_id, price_list_id, packaging_id) NULLS NOT DISTINCT;
CREATE INDEX IF NOT EXISTS prices_list_variant_idx ON prices (price_list_id, variant_id);
CREATE INDEX IF NOT EXISTS prices_synced_idx ON prices (synced_at);
CREATE INDEX IF NOT EXISTS prices_packaging_idx ON prices (packaging_id);

-- 5.2 user_profiles — DATA-101 (после warehouses: FK home_warehouse_id)
CREATE TABLE IF NOT EXISTS user_profiles (
  user_id             uuid PRIMARY KEY CONSTRAINT user_profiles_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  full_name           text NOT NULL CONSTRAINT user_profiles_full_name_chk CHECK (length(full_name) BETWEEN 2 AND 150),
  birth_year          smallint CONSTRAINT user_profiles_birth_year_chk CHECK (birth_year BETWEEN 1920 AND 2100),
  activity_sphere     text CONSTRAINT user_profiles_activity_sphere_chk CHECK (length(activity_sphere) <= 100),
  display_name        text,
  locale              text NOT NULL DEFAULT 'ru' CONSTRAINT user_profiles_locale_chk CHECK (locale IN ('ru','ky','en')),
  settings            jsonb NOT NULL DEFAULT '{}',
  biometrics_enabled  boolean NOT NULL DEFAULT false,
  home_warehouse_id   uuid CONSTRAINT user_profiles_home_warehouse_id_fk REFERENCES warehouses(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  row_version         integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS user_profiles_home_warehouse_idx ON user_profiles (home_warehouse_id);

-- =====================================================================================================
-- 7. Домен customers/finance (07 §5.C)
-- =====================================================================================================

-- 5.28 customers — DATA-127 (реплика 1С при source='onec' или черновик POS при source='pos':
--      synced_at/source_hash допускают NULL у черновиков POS)
CREATE TABLE IF NOT EXISTS customers (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz,
  source_hash         text,
  source              customer_source NOT NULL,
  onec_counterparty_ref uuid,
  onec_agreement_ref  uuid,
  name                text NOT NULL CONSTRAINT customers_name_chk CHECK (length(name) BETWEEN 2 AND 200),
  name_norm           text GENERATED ALWAYS AS (norm_search(name)) STORED,
  customer_type       customer_type NOT NULL,
  inn                 text CONSTRAINT customers_inn_chk CHECK (inn ~ '^[0-9]{14}$'),
  primary_phone_e164  text CONSTRAINT customers_primary_phone_e164_chk CHECK (primary_phone_e164 ~ '^\+996[0-9]{9}$'),
  phones_norm         text[] NOT NULL DEFAULT '{}',
  default_price_list_id uuid CONSTRAINT customers_default_price_list_id_fk REFERENCES price_lists(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  discount_percent    numeric(5,2) CONSTRAINT customers_discount_percent_chk CHECK (discount_percent BETWEEN 0 AND 100),
  credit_allowed      boolean NOT NULL DEFAULT false,
  credit_limit        numeric(14,2) CONSTRAINT customers_credit_limit_chk CHECK (credit_limit >= 0),
  credit_days         smallint CONSTRAINT customers_credit_days_chk CHECK (credit_days >= 0),
  is_retail_default   boolean NOT NULL DEFAULT false,
  segment             text,
  comment             text,
  created_by_user_id  uuid CONSTRAINT customers_created_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  force_reason        text CONSTRAINT customers_force_reason_chk CHECK (length(force_reason) <= 500),
  onec_status         customer_onec_status NOT NULL DEFAULT 'n_a',
  row_version         integer NOT NULL DEFAULT 1,
  deleted_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS customers_onec_ref_uq ON customers (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS customers_onec_code_uq ON customers (onec_code) WHERE onec_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS customers_retail_default_uq ON customers (is_retail_default) WHERE is_retail_default;
CREATE INDEX IF NOT EXISTS customers_name_norm_trgm ON customers USING GIN (name_norm gin_trgm_ops);
CREATE INDEX IF NOT EXISTS customers_phones_norm_gin ON customers USING GIN (phones_norm);
CREATE INDEX IF NOT EXISTS customers_inn_idx ON customers (inn) WHERE inn IS NOT NULL;
CREATE INDEX IF NOT EXISTS customers_pos_pending_idx ON customers (source, onec_status) WHERE source = 'pos';
CREATE INDEX IF NOT EXISTS customers_deletion_updated_idx ON customers (deletion_mark, updated_at);
CREATE INDEX IF NOT EXISTS customers_default_price_list_idx ON customers (default_price_list_id);

-- 5.29 customer_contacts — DATA-128
CREATE TABLE IF NOT EXISTS customer_contacts (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  customer_id         uuid NOT NULL CONSTRAINT customer_contacts_customer_id_fk REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  kind                contact_kind NOT NULL,
  label               text,
  value               text NOT NULL,
  value_norm          text,
  is_primary          boolean NOT NULL DEFAULT false,
  onec_line_key       text,
  synced_at           timestamptz,
  source_hash         text,
  deleted_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS customer_contacts_customer_kind_value_uq ON customer_contacts (customer_id, kind, value_norm) WHERE deleted_at IS NULL AND value_norm IS NOT NULL;
CREATE INDEX IF NOT EXISTS customer_contacts_customer_idx ON customer_contacts (customer_id);
CREATE INDEX IF NOT EXISTS customer_contacts_phone_idx ON customer_contacts (value_norm) WHERE kind = 'phone';

-- 5.30 customer_links — DATA-129
CREATE TABLE IF NOT EXISTS customer_links (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id             uuid NOT NULL CONSTRAINT customer_links_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  customer_id         uuid NOT NULL CONSTRAINT customer_links_customer_id_fk REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  status              customer_link_status NOT NULL DEFAULT 'proposed',
  match_method        link_match_method NOT NULL,
  matched_phone_e164  text,
  proposed_at         timestamptz NOT NULL DEFAULT now(),
  confirmed_by_user_id uuid CONSTRAINT customer_links_confirmed_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  confirmed_at        timestamptz,
  rejected_at         timestamptz,
  conflict_candidates uuid[],
  reason              text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_links_user_customer_uq UNIQUE (user_id, customer_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS customer_links_confirmed_uq ON customer_links (user_id) WHERE status = 'confirmed';
CREATE INDEX IF NOT EXISTS customer_links_customer_status_idx ON customer_links (customer_id, status);
CREATE INDEX IF NOT EXISTS customer_links_queue_idx ON customer_links (status) WHERE status IN ('proposed','conflict');

-- 5.31 receivables — DATA-130 (снимок 1С; is_stale — не столбец, вычисляется в API)
CREATE TABLE IF NOT EXISTS receivables (
  customer_id         uuid PRIMARY KEY CONSTRAINT receivables_customer_id_fk REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  balance             numeric(14,2) NOT NULL DEFAULT 0,
  overdue_amount      numeric(14,2),
  overdue_days        integer CONSTRAINT receivables_overdue_days_chk CHECK (overdue_days >= 0),
  oldest_due_date     date,
  currency            char(3) NOT NULL DEFAULT 'KGS',
  onec_snapshot_at    timestamptz NOT NULL,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT receivables_overdue_amount_chk CHECK (overdue_amount IS NULL OR (overdue_amount >= 0 AND overdue_amount <= GREATEST(balance, 0)))
);
CREATE INDEX IF NOT EXISTS receivables_overdue_idx ON receivables (overdue_amount) WHERE overdue_amount > 0;
CREATE INDEX IF NOT EXISTS receivables_balance_idx ON receivables (balance DESC);

-- 5.33 discount_rules — DATA-132 (реплика 1С при source='onec' или правило POS при source='pos')
CREATE TABLE IF NOT EXISTS discount_rules (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz,
  source_hash         text,
  source              discount_source NOT NULL,
  name                text NOT NULL,
  kind                discount_kind NOT NULL,
  value               numeric(14,2) NOT NULL,
  conditions          jsonb NOT NULL DEFAULT '{}',
  applies_automatically boolean NOT NULL DEFAULT false,
  is_active           boolean NOT NULL DEFAULT true,
  valid_from          date,
  valid_to            date,
  description_ru      text,
  row_version         integer NOT NULL DEFAULT 1,
  deleted_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT discount_rules_value_chk CHECK (value >= 0 AND (kind <> 'percent' OR value <= 100))
);
CREATE UNIQUE INDEX IF NOT EXISTS discount_rules_onec_ref_uq ON discount_rules (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS discount_rules_active_period_idx ON discount_rules (is_active, valid_from, valid_to);
CREATE INDEX IF NOT EXISTS discount_rules_conditions_gin ON discount_rules USING GIN (conditions jsonb_path_ops);

-- 5.34 role_discount_limits — DATA-133 (строки для всех ролей — seed этапа C, RM-C-006)
CREATE TABLE IF NOT EXISTS role_discount_limits (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  role                role_code NOT NULL,
  max_percent         numeric(5,2) NOT NULL CONSTRAINT role_discount_limits_max_percent_chk CHECK (max_percent BETWEEN 0 AND 100),
  can_approve_over_limit boolean NOT NULL DEFAULT false,
  approve_max_percent numeric(5,2) CONSTRAINT role_discount_limits_approve_max_percent_chk CHECK (approve_max_percent BETWEEN 0 AND 100),
  requires_reason_over_percent numeric(5,2) CONSTRAINT role_discount_limits_reason_percent_chk CHECK (requires_reason_over_percent BETWEEN 0 AND 100),
  updated_by_user_id  uuid CONSTRAINT role_discount_limits_updated_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  row_version         integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS role_discount_limits_role_uq ON role_discount_limits (role);

-- =====================================================================================================
-- 8. Домен sales (07 §5.D)
-- =====================================================================================================

-- 5.35 carts — DATA-134 (FK converted_order_id / restored_from_order_id → orders добавляются после orders)
CREATE TABLE IF NOT EXISTS carts (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  owner_user_id       uuid NOT NULL CONSTRAINT carts_owner_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  created_by_user_id  uuid NOT NULL CONSTRAINT carts_created_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  device_id           uuid CONSTRAINT carts_device_id_fk REFERENCES devices(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  customer_id         uuid CONSTRAINT carts_customer_id_fk REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  warehouse_id        uuid NOT NULL CONSTRAINT carts_warehouse_id_fk REFERENCES warehouses(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  price_list_id       uuid NOT NULL CONSTRAINT carts_price_list_id_fk REFERENCES price_lists(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  status              cart_status NOT NULL DEFAULT 'active',
  name                text CONSTRAINT carts_name_chk CHECK (length(name) <= 80),
  requested_discount_percent numeric(5,2) NOT NULL DEFAULT 0 CONSTRAINT carts_requested_discount_percent_chk CHECK (requested_discount_percent BETWEEN 0 AND 100),
  discount_approved_by_user_id uuid CONSTRAINT carts_discount_approved_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  discount_approved_at timestamptz,
  comment             text CONSTRAINT carts_comment_chk CHECK (length(comment) <= 500),
  items_count_cache   integer NOT NULL DEFAULT 0,
  subtotal_cache      numeric(14,2) NOT NULL DEFAULT 0,
  last_price_check_at timestamptz,
  converted_order_id  uuid,
  restored_from_order_id uuid,
  parked_at           timestamptz,
  resumed_at          timestamptz,
  cleared_at          timestamptz,
  expires_at          timestamptz,
  row_version         integer NOT NULL DEFAULT 1,
  local_cart_id       uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS carts_active_uq ON carts (owner_user_id) WHERE status = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS carts_local_id_uq ON carts (local_cart_id) WHERE local_cart_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS carts_owner_status_idx ON carts (owner_user_id, status);
CREATE INDEX IF NOT EXISTS carts_parked_expires_idx ON carts (status, expires_at) WHERE status = 'parked';
CREATE INDEX IF NOT EXISTS carts_parked_customer_idx ON carts (customer_id) WHERE status = 'parked';

-- 5.36 cart_items — DATA-135 (ON DELETE CASCADE — одно из двух допустимых, 07 §2.1, DATA-004)
CREATE TABLE IF NOT EXISTS cart_items (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  cart_id             uuid NOT NULL CONSTRAINT cart_items_cart_id_fk REFERENCES carts(id) ON DELETE CASCADE ON UPDATE RESTRICT,
  variant_id          uuid NOT NULL CONSTRAINT cart_items_variant_id_fk REFERENCES product_variants(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  packaging_id        uuid CONSTRAINT cart_items_packaging_id_fk REFERENCES packagings(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  quantity            numeric(14,3) NOT NULL CONSTRAINT cart_items_quantity_chk CHECK (quantity > 0),
  base_quantity       numeric(14,3) NOT NULL CONSTRAINT cart_items_base_quantity_chk CHECK (base_quantity > 0),
  price_snapshot      numeric(14,2) NOT NULL CONSTRAINT cart_items_price_snapshot_chk CHECK (price_snapshot >= 0),
  stock_snapshot      numeric(14,3),
  price_changed       boolean NOT NULL DEFAULT false,
  stock_insufficient  boolean NOT NULL DEFAULT false,
  line_no             smallint NOT NULL,
  added_at            timestamptz NOT NULL DEFAULT now(),
  local_item_id       uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cart_items_variant_pack_uq UNIQUE NULLS NOT DISTINCT (cart_id, variant_id, packaging_id),
  CONSTRAINT cart_items_line_uq UNIQUE (cart_id, line_no)
);
CREATE INDEX IF NOT EXISTS cart_items_variant_idx ON cart_items (variant_id);

-- 5.37 orders — DATA-136
CREATE SEQUENCE IF NOT EXISTS orders_number_seq;

CREATE TABLE IF NOT EXISTS orders (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  public_number       text NOT NULL CONSTRAINT orders_public_number_chk CHECK (public_number ~ '^POS-[0-9]{4}-[0-9]{6}$'),
  cart_id             uuid,
  status              order_status NOT NULL DEFAULT 'draft',
  customer_id         uuid NOT NULL CONSTRAINT orders_customer_id_fk REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  customer_name_snapshot text,
  customer_phone_snapshot text,
  created_by_user_id  uuid NOT NULL CONSTRAINT orders_created_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  created_via         text NOT NULL DEFAULT 'staff' CONSTRAINT orders_created_via_chk CHECK (created_via IN ('staff','customer')),
  device_id           uuid CONSTRAINT orders_device_id_fk REFERENCES devices(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  warehouse_id        uuid NOT NULL CONSTRAINT orders_warehouse_id_fk REFERENCES warehouses(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  price_list_id       uuid NOT NULL CONSTRAINT orders_price_list_id_fk REFERENCES price_lists(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  currency            char(3) NOT NULL DEFAULT 'KGS' CONSTRAINT orders_currency_chk CHECK (currency = 'KGS'),
  subtotal            numeric(14,2) NOT NULL CONSTRAINT orders_subtotal_chk CHECK (subtotal >= 0),
  discount_percent    numeric(5,2) NOT NULL DEFAULT 0 CONSTRAINT orders_discount_percent_chk CHECK (discount_percent BETWEEN 0 AND 100),
  customer_discount_percent numeric(5,2) CONSTRAINT orders_customer_discount_percent_chk CHECK (customer_discount_percent BETWEEN 0 AND 100),
  customer_discount_total numeric(14,2) NOT NULL DEFAULT 0 CONSTRAINT orders_customer_discount_total_chk CHECK (customer_discount_total >= 0),
  manual_discount_total numeric(14,2) NOT NULL DEFAULT 0 CONSTRAINT orders_manual_discount_total_chk CHECK (manual_discount_total >= 0),
  discount_total      numeric(14,2) NOT NULL DEFAULT 0 CONSTRAINT orders_discount_total_chk CHECK (discount_total >= 0 AND discount_total <= subtotal),
  total               numeric(14,2) NOT NULL,
  onec_total          numeric(14,2),
  totals_differ       boolean GENERATED ALWAYS AS (onec_total IS NOT NULL AND onec_total <> total) STORED,
  discount_rule_id    uuid CONSTRAINT orders_discount_rule_id_fk REFERENCES discount_rules(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  discount_approved_by_user_id uuid CONSTRAINT orders_discount_approved_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  discount_approved_at timestamptz,
  discount_reason     text,
  payment_method      payment_method NOT NULL,
  credit_approved_by_user_id uuid CONSTRAINT orders_credit_approved_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  credit_approved_at  timestamptz,
  credit_reason       text,
  credit_due_date     date,
  paid_amount         numeric(14,2) NOT NULL DEFAULT 0 CONSTRAINT orders_paid_amount_chk CHECK (paid_amount >= 0),
  paid_at             timestamptz,
  is_paid             boolean GENERATED ALWAYS AS (paid_amount >= total AND total > 0) STORED,
  delivery_method     delivery_method NOT NULL,
  receiver_kind       receiver_kind NOT NULL DEFAULT 'customer',
  receiver_name       text,
  receiver_phone_e164 text CONSTRAINT orders_receiver_phone_e164_chk CHECK (receiver_phone_e164 ~ '^\+996[0-9]{9}$'),
  delivery_recipient_phone_e164 text CONSTRAINT orders_delivery_recipient_phone_e164_chk CHECK (delivery_recipient_phone_e164 ~ '^\+996[0-9]{9}$'),
  delivery_address    text CONSTRAINT orders_delivery_address_chk CHECK (length(delivery_address) <= 300),
  delivery_geo        point,
  delivery_comment    text CONSTRAINT orders_delivery_comment_chk CHECK (length(delivery_comment) <= 200),
  delivery_date       date,
  delivery_time_from  time,
  delivery_time_to    time,
  print_options       jsonb NOT NULL DEFAULT '{"invoice":true,"waybill":true,"receipt":true}',
  comment             text CONSTRAINT orders_comment_chk CHECK (length(comment) <= 500),
  onec_number         text,
  onec_date           timestamptz,
  onec_status_raw     text,
  onec_last_sync_at   timestamptz,
  onec_linked_by_user_id uuid CONSTRAINT orders_onec_linked_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  onec_linked_at      timestamptz,
  onec_sync_state     onec_sync_state NOT NULL DEFAULT 'unknown',
  price_check_at      timestamptz,
  onec_check_result   jsonb,
  submitted_at        timestamptz,
  approved_at         timestamptz,
  shipped_at          timestamptz,
  closed_at           timestamptz,
  cancelled_at        timestamptz,
  cancel_reason       text CONSTRAINT orders_cancel_reason_chk CHECK (length(cancel_reason) <= 500),
  cancel_reason_code  text CONSTRAINT orders_cancel_reason_code_chk CHECK (cancel_reason_code IN ('customer_refused','duplicate','error','other')),
  refund_intent       text CONSTRAINT orders_refund_intent_chk CHECK (refund_intent IN ('none','refund','advance')),
  cancel_requested_at timestamptz,
  cancel_requested_by_user_id uuid CONSTRAINT orders_cancel_requested_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  submit_error_code   text,
  submit_error_message text,
  idempotency_key     text,
  row_version         integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT orders_total_chk CHECK (total = subtotal - discount_total),
  CONSTRAINT orders_discount_split_chk CHECK (discount_total = customer_discount_total + manual_discount_total),
  CONSTRAINT orders_delivery_phone_chk CHECK (delivery_method <> 'delivery' OR delivery_recipient_phone_e164 IS NOT NULL),
  CONSTRAINT orders_onec_sync_ref_chk CHECK (CASE onec_sync_state
      WHEN 'linked' THEN onec_ref IS NOT NULL WHEN 'missing' THEN onec_ref IS NOT NULL
      WHEN 'unknown' THEN onec_ref IS NULL WHEN 'ambiguous' THEN onec_ref IS NULL
      ELSE true END),
  CONSTRAINT orders_onec_sync_status_chk CHECK (
      (status NOT IN ('draft','submit_failed') OR onec_sync_state = 'unknown')
      AND (onec_sync_state <> 'unknown' OR status IN ('draft','submitting','submit_failed','cancelled'))
      AND (onec_sync_state <> 'ambiguous' OR status = 'submitting')),
  CONSTRAINT orders_receiver_chk CHECK (receiver_kind = 'customer' OR (receiver_name IS NOT NULL AND receiver_phone_e164 IS NOT NULL)),
  CONSTRAINT orders_delivery_chk CHECK (delivery_method = 'pickup' OR delivery_address IS NOT NULL),
  CONSTRAINT orders_cancel_request_chk CHECK (cancel_requested_at IS NULL
      OR (cancel_requested_by_user_id IS NOT NULL AND cancel_reason_code IS NOT NULL)),
  CONSTRAINT orders_customer_channel_chk CHECK (created_via <> 'customer'
      OR (payment_method IN ('cash','qr_bakai') AND discount_percent = 0 AND manual_discount_total = 0
          AND discount_approved_by_user_id IS NULL AND credit_approved_by_user_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS orders_public_number_uq ON orders (public_number);
CREATE UNIQUE INDEX IF NOT EXISTS orders_onec_ref_uq ON orders (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS orders_idem_uq ON orders (idempotency_key, created_by_user_id) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS orders_customer_idx ON orders (customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_creator_idx ON orders (created_by_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_open_status_idx ON orders (status)
  WHERE status IN ('submitting','submit_failed','pending_approval','awaiting_payment','approved','awaiting_shipment');
CREATE INDEX IF NOT EXISTS orders_created_idx ON orders (created_at DESC);
CREATE INDEX IF NOT EXISTS orders_onec_number_idx ON orders (onec_number) WHERE onec_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS orders_onec_sync_attention_idx ON orders (onec_sync_state) WHERE onec_sync_state IN ('missing','ambiguous');
CREATE INDEX IF NOT EXISTS orders_customer_requests_idx ON orders (status, created_at DESC) WHERE created_via = 'customer';
CREATE INDEX IF NOT EXISTS orders_created_brin ON orders USING BRIN (created_at);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'carts_converted_order_id_fk' AND conrelid = 'public.carts'::regclass) THEN
    ALTER TABLE carts ADD CONSTRAINT carts_converted_order_id_fk FOREIGN KEY (converted_order_id)
      REFERENCES orders(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'carts_restored_from_order_fk' AND conrelid = 'public.carts'::regclass) THEN
    ALTER TABLE carts ADD CONSTRAINT carts_restored_from_order_fk FOREIGN KEY (restored_from_order_id)
      REFERENCES orders(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
  END IF;
END $$;

-- 5.38 order_items — DATA-137 (order_id — RESTRICT: строки draft-заказа удаляет прикладная логика, 07 §2.1)
CREATE TABLE IF NOT EXISTS order_items (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  order_id            uuid NOT NULL CONSTRAINT order_items_order_id_fk REFERENCES orders(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  line_no             smallint NOT NULL CONSTRAINT order_items_line_no_chk CHECK (line_no > 0),
  variant_id          uuid NOT NULL CONSTRAINT order_items_variant_id_fk REFERENCES product_variants(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  product_id          uuid NOT NULL CONSTRAINT order_items_product_id_fk REFERENCES products(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  packaging_id        uuid CONSTRAINT order_items_packaging_id_fk REFERENCES packagings(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  quantity            numeric(14,3) NOT NULL CONSTRAINT order_items_quantity_chk CHECK (quantity > 0),
  base_quantity       numeric(14,3) NOT NULL CONSTRAINT order_items_base_quantity_chk CHECK (base_quantity > 0),
  unit_code_snapshot  text NOT NULL,
  packaging_name_snapshot text,
  packaging_factor_snapshot numeric(14,3),
  unit_price          numeric(14,2) NOT NULL CONSTRAINT order_items_unit_price_chk CHECK (unit_price >= 0),
  line_subtotal       numeric(14,2) NOT NULL CONSTRAINT order_items_line_subtotal_chk CHECK (line_subtotal >= 0),
  discount_percent    numeric(5,2) NOT NULL DEFAULT 0 CONSTRAINT order_items_discount_percent_chk CHECK (discount_percent BETWEEN 0 AND 100),
  customer_discount_amount numeric(14,2) NOT NULL DEFAULT 0 CONSTRAINT order_items_customer_discount_amount_chk CHECK (customer_discount_amount >= 0),
  manual_discount_amount numeric(14,2) NOT NULL DEFAULT 0 CONSTRAINT order_items_manual_discount_amount_chk CHECK (manual_discount_amount >= 0),
  discount_amount     numeric(14,2) NOT NULL DEFAULT 0 CONSTRAINT order_items_discount_amount_chk CHECK (discount_amount >= 0 AND discount_amount <= line_subtotal),
  line_total          numeric(14,2) NOT NULL,
  product_name_snapshot text NOT NULL,
  variant_name_snapshot text,
  sku_snapshot        text,
  barcode_snapshot    text,
  onec_line_no        smallint,
  onec_line_total     numeric(14,2),
  shipped_quantity    numeric(14,3) NOT NULL DEFAULT 0,
  returned_quantity   numeric(14,3) NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT order_items_line_subtotal_calc_chk CHECK (line_subtotal = round_half_up(unit_price * quantity, 2)),
  CONSTRAINT order_items_total_chk CHECK (line_total = line_subtotal - discount_amount),
  CONSTRAINT order_items_discount_split_chk CHECK (discount_amount = customer_discount_amount + manual_discount_amount),
  CONSTRAINT order_items_line_uq UNIQUE (order_id, line_no),
  CONSTRAINT order_items_variant_pack_uq UNIQUE NULLS NOT DISTINCT (order_id, variant_id, packaging_id)
);
CREATE INDEX IF NOT EXISTS order_items_variant_idx ON order_items (variant_id);
CREATE INDEX IF NOT EXISTS order_items_product_created_idx ON order_items (product_id, created_at);
CREATE INDEX IF NOT EXISTS order_items_packaging_idx ON order_items (packaging_id);

-- 5.39 order_status_history — DATA-138 (INSERT-only для pos_app; sync_run_id — без FK: sync_runs удаляются ретенцией)
CREATE TABLE IF NOT EXISTS order_status_history (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  order_id            uuid NOT NULL CONSTRAINT order_status_history_order_id_fk REFERENCES orders(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  from_status         order_status,
  to_status           order_status NOT NULL,
  source              status_change_source NOT NULL,
  actor_user_id       uuid CONSTRAINT order_status_history_actor_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  onec_status_raw     text,
  reason              text,
  error_code          text,
  occurred_at         timestamptz NOT NULL DEFAULT now(),
  request_id          text,
  sync_run_id         uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS order_status_history_order_occurred_idx ON order_status_history (order_id, occurred_at);

-- 5.40 payments — DATA-139 (qr_provider и поля QR через 1С — ядро v1.9 §24.4)
CREATE TABLE IF NOT EXISTS payments (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  public_number       text NOT NULL CONSTRAINT payments_public_number_chk CHECK (public_number ~ '^PAY-[0-9]{4}-[0-9]{6}$'),
  order_id            uuid CONSTRAINT payments_order_id_fk REFERENCES orders(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  customer_id         uuid CONSTRAINT payments_customer_id_fk REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  method              payment_method NOT NULL,
  qr_provider         text CONSTRAINT payments_qr_provider_value_chk CHECK (qr_provider IN ('none','onec','bakai')),
  status              payment_status NOT NULL DEFAULT 'initiated',
  amount              numeric(14,2) NOT NULL CONSTRAINT payments_amount_chk CHECK (amount > 0),
  currency            char(3) NOT NULL DEFAULT 'KGS' CONSTRAINT payments_currency_chk CHECK (currency = 'KGS'),
  created_by_user_id  uuid NOT NULL CONSTRAINT payments_created_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  received_by_user_id uuid CONSTRAINT payments_received_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  received_at         timestamptz,
  received_amount     numeric(14,2),
  change_amount       numeric(14,2),
  bank_amount         numeric(14,2) CONSTRAINT payments_bank_amount_chk CHECK (bank_amount IS NULL OR bank_amount > 0),
  qr_payload          text,
  qr_expires_at       timestamptz,
  qr_provider_ref     text,
  bank_reference      text,
  qr_status_checked_at timestamptz,
  qr_provider_status_raw text CONSTRAINT payments_qr_provider_status_raw_chk CHECK (length(qr_provider_status_raw) <= 100),
  manual_confirmed_by_user_id uuid CONSTRAINT payments_manual_confirmed_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  manual_confirmed_at timestamptz,
  manual_reason       text,
  review_reason       text CONSTRAINT payments_review_reason_chk CHECK (review_reason IN ('amount_mismatch','unknown_reference','no_webhook','late_payment')),
  voided_by_user_id   uuid CONSTRAINT payments_voided_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  voided_at           timestamptz,
  void_reason         text,
  allocation          jsonb,
  onec_doc_type       text,
  onec_number         text,
  onec_date           timestamptz,
  idempotency_key     text NOT NULL,
  request_id          text,
  row_version         integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payments_target_chk CHECK (order_id IS NOT NULL OR customer_id IS NOT NULL),
  CONSTRAINT payments_manual_chk CHECK (status <> 'manual_confirm' OR review_reason IS NOT NULL OR manual_confirmed_by_user_id IS NOT NULL),
  CONSTRAINT payments_cash_received_chk CHECK (received_amount IS NULL OR (method = 'cash' AND received_amount >= amount)),
  CONSTRAINT payments_change_chk CHECK (change_amount IS NULL OR change_amount = received_amount - amount),
  CONSTRAINT payments_qr_provider_chk CHECK ((method = 'qr_bakai') = (qr_provider IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS payments_public_number_uq ON payments (public_number);
CREATE UNIQUE INDEX IF NOT EXISTS payments_onec_ref_uq ON payments (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS payments_idem_uq ON payments (idempotency_key, created_by_user_id);
CREATE UNIQUE INDEX IF NOT EXISTS payments_qr_provider_ref_uq ON payments (qr_provider, qr_provider_ref) WHERE qr_provider_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS payments_one_open_per_order_uq ON payments (order_id)
  WHERE status IN ('initiated','cash_pending','qr_pending','qr_shown','qr_expired','manual_confirm');
CREATE INDEX IF NOT EXISTS payments_order_idx ON payments (order_id);
CREATE INDEX IF NOT EXISTS payments_customer_created_idx ON payments (customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS payments_status_created_idx ON payments (status, created_at);
CREATE INDEX IF NOT EXISTS payments_received_idx ON payments (received_at DESC) WHERE status = 'received';
CREATE INDEX IF NOT EXISTS payments_review_idx ON payments (review_reason, created_at) WHERE review_reason IS NOT NULL;
CREATE INDEX IF NOT EXISTS payments_qr_onec_poll_idx ON payments (qr_status_checked_at) WHERE qr_provider = 'onec' AND status = 'qr_shown';

-- 5.41 payment_webhook_events — DATA-140 [ядро §17.3] (условная: только QR_PROVIDER=bakai — R2)
CREATE TABLE IF NOT EXISTS payment_webhook_events (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  provider            text NOT NULL DEFAULT 'bakai',
  provider_event_id   text NOT NULL,
  payment_id          uuid CONSTRAINT payment_webhook_events_payment_id_fk REFERENCES payments(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  signature_valid     boolean NOT NULL,
  payload             jsonb NOT NULL,
  received_at         timestamptz NOT NULL DEFAULT now(),
  processed_at        timestamptz,
  processing_error    text,
  source_ip           inet,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payment_webhook_events_provider_event_uq UNIQUE (provider, provider_event_id)
);
CREATE INDEX IF NOT EXISTS payment_webhook_events_payment_idx ON payment_webhook_events (payment_id);
CREATE INDEX IF NOT EXISTS payment_webhook_events_unprocessed_idx ON payment_webhook_events (processed_at) WHERE processed_at IS NULL;

-- 5.42 shipments — DATA-141 [ядро §17.3] (реплика 1С; onec_ref NOT NULL)
CREATE TABLE IF NOT EXISTS shipments (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid NOT NULL,
  onec_code           text,
  onec_data_version   text,
  deletion_mark       boolean NOT NULL DEFAULT false,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  onec_doc_type       text NOT NULL,
  onec_date           timestamptz NOT NULL,
  posted              boolean NOT NULL,
  order_id            uuid CONSTRAINT shipments_order_id_fk REFERENCES orders(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  customer_id         uuid NOT NULL CONSTRAINT shipments_customer_id_fk REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  warehouse_id        uuid CONSTRAINT shipments_warehouse_id_fk REFERENCES warehouses(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  total               numeric(14,2) NOT NULL,
  discount_total      numeric(14,2) NOT NULL DEFAULT 0,
  currency            char(3) NOT NULL DEFAULT 'KGS',
  payment_due_date    date,
  returned_total      numeric(14,2) NOT NULL DEFAULT 0,
  comment             text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS shipments_onec_ref_uq ON shipments (onec_ref);
CREATE INDEX IF NOT EXISTS shipments_customer_date_idx ON shipments (customer_id, onec_date DESC);
CREATE INDEX IF NOT EXISTS shipments_order_idx ON shipments (order_id);
CREATE INDEX IF NOT EXISTS shipments_date_idx ON shipments (onec_date DESC);
CREATE INDEX IF NOT EXISTS shipments_warehouse_idx ON shipments (warehouse_id);

-- 5.43 shipment_items — DATA-142 [ядро §17.3] (строки реализации; внешний id — (shipment_id, onec_line_no))
CREATE TABLE IF NOT EXISTS shipment_items (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  shipment_id         uuid NOT NULL CONSTRAINT shipment_items_shipment_id_fk REFERENCES shipments(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  onec_line_no        smallint NOT NULL,
  variant_id          uuid CONSTRAINT shipment_items_variant_id_fk REFERENCES product_variants(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  product_name_snapshot text NOT NULL,
  packaging_id        uuid CONSTRAINT shipment_items_packaging_id_fk REFERENCES packagings(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  quantity            numeric(14,3) NOT NULL,
  base_quantity       numeric(14,3) NOT NULL,
  unit_price          numeric(14,2) NOT NULL,
  line_total          numeric(14,2) NOT NULL,
  discount_amount     numeric(14,2) NOT NULL,
  returned_quantity   numeric(14,3) NOT NULL DEFAULT 0,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shipment_items_line_uq UNIQUE (shipment_id, onec_line_no)
);
CREATE INDEX IF NOT EXISTS shipment_items_variant_idx ON shipment_items (variant_id);
CREATE INDEX IF NOT EXISTS shipment_items_packaging_idx ON shipment_items (packaging_id);

-- 5.32 receivable_documents — DATA-131 (после orders: FK order_id; DELETE для pos_app запрещён — 06 EVO-007)
CREATE TABLE IF NOT EXISTS receivable_documents (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  customer_id         uuid NOT NULL CONSTRAINT receivable_documents_customer_id_fk REFERENCES receivables(customer_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  onec_ref            uuid NOT NULL,
  doc_type            text NOT NULL,
  kind                text NOT NULL CONSTRAINT receivable_documents_kind_chk CHECK (kind IN ('invoice','payment','return','discount','adjustment')),
  status              text NOT NULL CONSTRAINT receivable_documents_status_chk CHECK (status IN ('posted','not_posted','due')),
  doc_number          text NOT NULL,
  doc_date            date NOT NULL,
  amount              numeric(14,2) NOT NULL,
  paid                numeric(14,2) NOT NULL DEFAULT 0,
  remaining           numeric(14,2) NOT NULL,
  due_date            date,
  overdue_days        integer,
  order_id            uuid CONSTRAINT receivable_documents_order_id_fk REFERENCES orders(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  onec_snapshot_at    timestamptz NOT NULL,
  superseded_at       timestamptz,
  synced_at           timestamptz NOT NULL,
  source_hash         text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT receivable_documents_customer_onec_ref_uq UNIQUE (customer_id, onec_ref)
);
CREATE INDEX IF NOT EXISTS receivable_documents_current_idx ON receivable_documents (customer_id, due_date) WHERE superseded_at IS NULL;
CREATE INDEX IF NOT EXISTS receivable_documents_order_idx ON receivable_documents (order_id);

-- 5.45 return_requests — DATA-144
CREATE TABLE IF NOT EXISTS return_requests (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  public_number       text NOT NULL CONSTRAINT return_requests_public_number_chk CHECK (public_number ~ '^RET-[0-9]{4}-[0-9]{6}$'),
  shipment_id         uuid NOT NULL CONSTRAINT return_requests_shipment_id_fk REFERENCES shipments(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  order_id            uuid CONSTRAINT return_requests_order_id_fk REFERENCES orders(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  customer_id         uuid NOT NULL CONSTRAINT return_requests_customer_id_fk REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  status              return_request_status NOT NULL DEFAULT 'draft',
  reason              return_reason NOT NULL,
  reason_comment      text CONSTRAINT return_requests_reason_comment_len_chk CHECK (length(reason_comment) <= 500),
  total               numeric(14,2) NOT NULL CONSTRAINT return_requests_total_chk CHECK (total >= 0),
  refund_method_expected payment_method,
  created_by_user_id  uuid NOT NULL CONSTRAINT return_requests_created_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  approved_by_user_id uuid CONSTRAINT return_requests_approved_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  approved_at         timestamptz,
  accepted_at         timestamptz,
  accepted_by_user_id uuid CONSTRAINT return_requests_accepted_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  approval_reason     text CONSTRAINT return_requests_approval_reason_chk CHECK (approval_reason IN ('return_threshold_exceeded')),
  submitted_at        timestamptz,
  completed_at        timestamptz,
  rejected_at         timestamptz,
  onec_number         text,
  onec_date           timestamptz,
  onec_status_raw     text,
  onec_result         text CONSTRAINT return_requests_onec_result_chk CHECK (onec_result IN ('money_refunded','offset_against_debt','pending')),
  reject_reason       text,
  rejected_by_user_id uuid CONSTRAINT return_requests_rejected_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  idempotency_key     text,
  row_version         integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT return_requests_reason_comment_chk CHECK (reason <> 'other' OR reason_comment IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS return_requests_public_number_uq ON return_requests (public_number);
CREATE UNIQUE INDEX IF NOT EXISTS return_requests_onec_ref_uq ON return_requests (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS return_requests_shipment_idx ON return_requests (shipment_id);
CREATE INDEX IF NOT EXISTS return_requests_customer_created_idx ON return_requests (customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS return_requests_open_idx ON return_requests (status) WHERE status IN ('draft','submitted','accepted');
CREATE INDEX IF NOT EXISTS return_requests_order_idx ON return_requests (order_id);

-- 5.46 return_request_items — DATA-145 (ON DELETE CASCADE — второе из двух допустимых, только draft)
CREATE TABLE IF NOT EXISTS return_request_items (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  return_request_id   uuid NOT NULL CONSTRAINT return_request_items_return_request_id_fk REFERENCES return_requests(id) ON DELETE CASCADE ON UPDATE RESTRICT,
  shipment_item_id    uuid NOT NULL CONSTRAINT return_request_items_shipment_item_id_fk REFERENCES shipment_items(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  variant_id          uuid NOT NULL CONSTRAINT return_request_items_variant_id_fk REFERENCES product_variants(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  quantity            numeric(14,3) NOT NULL CONSTRAINT return_request_items_quantity_chk CHECK (quantity > 0),
  unit_price          numeric(14,2) NOT NULL,
  line_total          numeric(14,2) NOT NULL,
  reason_override     return_reason,
  product_name_snapshot text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT return_request_items_request_shipment_item_uq UNIQUE (return_request_id, shipment_item_id)
);
CREATE INDEX IF NOT EXISTS return_request_items_shipment_item_idx ON return_request_items (shipment_item_id);
CREATE INDEX IF NOT EXISTS return_request_items_variant_idx ON return_request_items (variant_id);

-- 5.44 transactions — DATA-143 (производный журнал; INSERT-only для pos_app)
CREATE TABLE IF NOT EXISTS transactions (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  onec_ref            uuid,
  kind                transaction_kind NOT NULL,
  source              transaction_source NOT NULL,
  order_id            uuid CONSTRAINT transactions_order_id_fk REFERENCES orders(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  payment_id          uuid CONSTRAINT transactions_payment_id_fk REFERENCES payments(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  return_request_id   uuid CONSTRAINT transactions_return_request_id_fk REFERENCES return_requests(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  shipment_id         uuid CONSTRAINT transactions_shipment_id_fk REFERENCES shipments(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  customer_id         uuid CONSTRAINT transactions_customer_id_fk REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  actor_user_id       uuid CONSTRAINT transactions_actor_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  amount              numeric(14,2) NOT NULL,
  currency            char(3) NOT NULL DEFAULT 'KGS' CONSTRAINT transactions_currency_chk CHECK (currency = 'KGS'),
  payment_method      payment_method,
  status_snapshot     text NOT NULL,
  title_ru            text NOT NULL,
  details             jsonb NOT NULL DEFAULT '{}',
  occurred_at         timestamptz NOT NULL,
  onec_number         text,
  onec_doc_type       text,
  dedupe_key          text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT transactions_link_chk CHECK (num_nonnulls(order_id, payment_id, return_request_id, shipment_id) >= 1),
  CONSTRAINT transactions_dedupe_key_uq UNIQUE (dedupe_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS transactions_onec_ref_uq ON transactions (onec_ref) WHERE onec_ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS transactions_occurred_idx ON transactions (occurred_at DESC);
CREATE INDEX IF NOT EXISTS transactions_customer_occurred_idx ON transactions (customer_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS transactions_actor_occurred_idx ON transactions (actor_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS transactions_kind_occurred_idx ON transactions (kind, occurred_at DESC);
CREATE INDEX IF NOT EXISTS transactions_order_idx ON transactions (order_id);
CREATE INDEX IF NOT EXISTS transactions_payment_idx ON transactions (payment_id);

-- 5.47 favorites_products — DATA-146
CREATE TABLE IF NOT EXISTS favorites_products (
  user_id             uuid NOT NULL CONSTRAINT favorites_products_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  product_id          uuid NOT NULL CONSTRAINT favorites_products_product_id_fk REFERENCES products(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, product_id)
);
CREATE INDEX IF NOT EXISTS favorites_products_user_created_idx ON favorites_products (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS favorites_products_product_idx ON favorites_products (product_id);

-- 5.48 favorites_customers — DATA-147
CREATE TABLE IF NOT EXISTS favorites_customers (
  user_id             uuid NOT NULL CONSTRAINT favorites_customers_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  customer_id         uuid NOT NULL CONSTRAINT favorites_customers_customer_id_fk REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, customer_id)
);
CREATE INDEX IF NOT EXISTS favorites_customers_user_created_idx ON favorites_customers (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS favorites_customers_customer_idx ON favorites_customers (customer_id);

-- 5.49 recent_products — DATA-148
CREATE TABLE IF NOT EXISTS recent_products (
  user_id             uuid NOT NULL CONSTRAINT recent_products_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  product_id          uuid NOT NULL CONSTRAINT recent_products_product_id_fk REFERENCES products(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  last_viewed_at      timestamptz NOT NULL DEFAULT now(),
  view_count          integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, product_id)
);
CREATE INDEX IF NOT EXISTS recent_products_user_viewed_idx ON recent_products (user_id, last_viewed_at DESC);
CREATE INDEX IF NOT EXISTS recent_products_product_idx ON recent_products (product_id);

-- =====================================================================================================
-- 9. Домен sync / audit / служебные (07 §5.E)
-- =====================================================================================================

-- 5.50 notifications — DATA-149
CREATE TABLE IF NOT EXISTS notifications (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id             uuid NOT NULL CONSTRAINT notifications_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  kind                notification_kind NOT NULL,
  severity            text NOT NULL CONSTRAINT notifications_severity_chk CHECK (severity IN ('info','warning','error')),
  title_ru            text NOT NULL,
  body_ru             text NOT NULL,
  payload             jsonb NOT NULL DEFAULT '{}',
  dedupe_key          text NOT NULL,
  read_at             timestamptz,
  expires_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notifications_user_dedupe_key_uq UNIQUE (user_id, dedupe_key)
);
CREATE INDEX IF NOT EXISTS notifications_user_unread_idx ON notifications (user_id, read_at, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_expires_idx ON notifications (expires_at);

-- 5.51 sync_runs — DATA-150
CREATE TABLE IF NOT EXISTS sync_runs (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  entity              sync_entity NOT NULL,
  mode                sync_mode NOT NULL,
  "trigger"           sync_trigger NOT NULL,
  triggered_by_user_id uuid CONSTRAINT sync_runs_triggered_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  status              sync_run_status NOT NULL DEFAULT 'queued',
  started_at          timestamptz,
  finished_at         timestamptz,
  cursor_from         text,
  cursor_to           text,
  counts              jsonb NOT NULL DEFAULT '{}',
  error_summary       text,
  onec_endpoint       text,
  worker_job_id       text,
  duration_ms         integer,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS sync_runs_singleton_uq ON sync_runs (entity) WHERE status IN ('queued','running');
CREATE INDEX IF NOT EXISTS sync_runs_entity_started_idx ON sync_runs (entity, started_at DESC);
CREATE INDEX IF NOT EXISTS sync_runs_active_idx ON sync_runs (status) WHERE status IN ('queued','running');
CREATE INDEX IF NOT EXISTS sync_runs_started_brin ON sync_runs USING BRIN (started_at);

-- 5.52 sync_state — DATA-151 (строки по enum sync_entity — seed этапа C: schedule_cron/max_age_warning_sec из env)
CREATE TABLE IF NOT EXISTS sync_state (
  entity              sync_entity PRIMARY KEY,
  schedule_cron       text NOT NULL,
  last_run_id         uuid CONSTRAINT sync_state_last_run_id_fk REFERENCES sync_runs(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  last_success_run_id uuid CONSTRAINT sync_state_last_success_run_id_fk REFERENCES sync_runs(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  last_success_at     timestamptz,
  last_cursor         text,
  last_source_total   integer,
  last_local_total    integer,
  consecutive_errors  integer NOT NULL DEFAULT 0,
  last_error_at       timestamptz,
  last_error          text,
  paused              boolean NOT NULL DEFAULT false,
  paused_reason       text,
  max_age_warning_sec integer NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- 5.55 onec_outbox — DATA-154 (автомат — 07 §6.5, ядро v1.7 §22.1)
CREATE TABLE IF NOT EXISTS onec_outbox (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  aggregate_type      outbox_aggregate NOT NULL,
  aggregate_id        uuid NOT NULL,
  external_id         text NOT NULL,
  operation           text NOT NULL CONSTRAINT onec_outbox_operation_chk CHECK (operation IN ('create','cancel')),
  payload             jsonb NOT NULL,
  payload_hash        bytea NOT NULL,
  status              outbox_status NOT NULL DEFAULT 'pending',
  attempts            smallint NOT NULL DEFAULT 0,
  next_attempt_at     timestamptz DEFAULT now(),
  lease_until         timestamptz,
  locked_by           text,
  last_error_code     text CONSTRAINT onec_outbox_last_error_code_chk CHECK (last_error_code IS NULL OR last_error_code IN (
                        'NOT_FOUND_LOCAL','BARCODE_CONFLICT','VALIDATION','ONEC_REJECTED','ONEC_UNAVAILABLE',
                        'IMAGE_DOWNLOAD','HASH_MISMATCH','COUNT_MISMATCH','DUPLICATE_SUSPECTED','OUTBOX_UNCONFIRMED',
                        'PAYMENT_DOC_VOIDED','ORDER_MATCH_AMBIGUOUS','NO_WRITE_CHANNEL','OTHER')),
  last_error          text,
  onec_response       jsonb,
  onec_ref            uuid,
  sent_at             timestamptz,
  confirmed_at        timestamptz,
  dead_at             timestamptz,
  cancelled_at        timestamptz,
  depends_on_outbox_id uuid CONSTRAINT onec_outbox_depends_on_outbox_id_fk REFERENCES onec_outbox(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  priority            smallint NOT NULL DEFAULT 100,
  requested_by_user_id uuid CONSTRAINT onec_outbox_requested_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  warehouse_id        uuid CONSTRAINT onec_outbox_warehouse_id_fk REFERENCES warehouses(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT onec_outbox_external_is_aggregate_chk CHECK (external_id = aggregate_id::text),
  CONSTRAINT onec_outbox_external_op_uq UNIQUE (external_id, operation),
  CONSTRAINT onec_outbox_aggregate_op_uq UNIQUE (aggregate_type, aggregate_id, operation),
  CONSTRAINT onec_outbox_lease_chk CHECK (status <> 'sending' OR lease_until IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS onec_outbox_dispatch_idx ON onec_outbox (status, next_attempt_at, priority) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS onec_outbox_lease_idx ON onec_outbox (lease_until) WHERE status = 'sending';
CREATE INDEX IF NOT EXISTS onec_outbox_attention_idx ON onec_outbox (status, created_at) WHERE status IN ('failed','dead');
CREATE INDEX IF NOT EXISTS onec_outbox_aggregate_idx ON onec_outbox (aggregate_type, aggregate_id);
CREATE INDEX IF NOT EXISTS onec_outbox_depends_on_idx ON onec_outbox (depends_on_outbox_id);
CREATE INDEX IF NOT EXISTS onec_outbox_confirmed_idx ON onec_outbox (confirmed_at);

-- 5.53 sync_errors — DATA-152 (словарь кодов — 07 §6.1.1)
CREATE TABLE IF NOT EXISTS sync_errors (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  sync_run_id         uuid CONSTRAINT sync_errors_sync_run_id_fk REFERENCES sync_runs(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  outbox_id           uuid CONSTRAINT sync_errors_outbox_id_fk REFERENCES onec_outbox(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  entity              sync_entity NOT NULL,
  onec_ref            uuid,
  onec_code           text,
  local_id            uuid,
  error_code          text NOT NULL CONSTRAINT sync_errors_error_code_chk CHECK (error_code IN (
                        'NOT_FOUND_LOCAL','BARCODE_CONFLICT','VALIDATION','ONEC_REJECTED','ONEC_UNAVAILABLE',
                        'IMAGE_DOWNLOAD','HASH_MISMATCH','COUNT_MISMATCH','DUPLICATE_SUSPECTED','OUTBOX_UNCONFIRMED',
                        'PAYMENT_DOC_VOIDED','ORDER_MATCH_AMBIGUOUS','NO_WRITE_CHANNEL','OTHER')),
  message             text NOT NULL,
  payload             jsonb,
  severity            text NOT NULL CONSTRAINT sync_errors_severity_chk CHECK (severity IN ('warning','error')),
  resolved_at         timestamptz,
  resolved_by_user_id uuid CONSTRAINT sync_errors_resolved_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  resolution          text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sync_errors_run_idx ON sync_errors (sync_run_id);
CREATE INDEX IF NOT EXISTS sync_errors_open_idx ON sync_errors (entity, resolved_at) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS sync_errors_onec_ref_idx ON sync_errors (onec_ref);
CREATE INDEX IF NOT EXISTS sync_errors_outbox_idx ON sync_errors (outbox_id);

-- 5.54 sync_entity_versions — DATA-153. Ключ объекта — onec_key text (B-AR-05): Ref_Key справочника/документа
--      в текстовом виде (= onec_ref::text) либо ключ набора записей регистра (например, значение штрихкода
--      регистра штрихкодов, 05 §6.2 п.1; ≤ 150 символов); onec_ref заполнен только у объектов с Ref_Key.
--      Предложение владельцу 07 §5.54 — pos-api/migrations/NOTES.md §10.
CREATE TABLE IF NOT EXISTS sync_entity_versions (
  entity              sync_entity NOT NULL,
  onec_key            text NOT NULL CONSTRAINT sync_entity_versions_onec_key_chk CHECK (length(onec_key) BETWEEN 1 AND 150),
  onec_ref            uuid,
  data_version        text,
  content_hash        bytea NOT NULL,
  local_id            uuid,
  seen_in_run_id      uuid NOT NULL CONSTRAINT sync_entity_versions_seen_in_run_id_fk REFERENCES sync_runs(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  last_seen_at        timestamptz NOT NULL,
  first_seen_at       timestamptz NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sync_entity_versions_ref_key_chk CHECK (onec_ref IS NULL OR onec_key = onec_ref::text),
  PRIMARY KEY (entity, onec_key)
);
CREATE INDEX IF NOT EXISTS sync_entity_versions_seen_idx ON sync_entity_versions (entity, seen_in_run_id);
CREATE INDEX IF NOT EXISTS sync_entity_versions_last_seen_idx ON sync_entity_versions (entity, last_seen_at);
CREATE INDEX IF NOT EXISTS sync_entity_versions_run_idx ON sync_entity_versions (seen_in_run_id);

-- 5.56 idempotency_keys — DATA-155. Скоуп ключа — subject_key (B-AR-01): 'user:<users.id>' для аутентифицированных
--      запросов; 'reg:<sha256(jti registration_token), hex>' для публичного POST /registration/complete, где
--      пользователя ещё нет (user_id NULL; созданный пользователь — resource_id). Предложение владельцам
--      07 §5.56 и 08 §2.7 «Скоуп» — pos-api/migrations/NOTES.md §10, contracts/openapi/NOTES.md §8.
CREATE TABLE IF NOT EXISTS idempotency_keys (
  key                 text NOT NULL CONSTRAINT idempotency_keys_key_chk CHECK (length(key) BETWEEN 16 AND 128),
  subject_key         text NOT NULL CONSTRAINT idempotency_keys_subject_key_chk
                        CHECK (subject_key ~ '^(user:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|reg:[0-9a-f]{64})$'),
  user_id             uuid CONSTRAINT idempotency_keys_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  route               text NOT NULL,
  request_hash        bytea NOT NULL,
  status              idempotency_status NOT NULL DEFAULT 'in_progress',
  response_status     smallint,
  response_body       jsonb,
  resource_id         uuid,
  expires_at          timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT idempotency_keys_subject_user_chk CHECK (
    (subject_key LIKE 'user:%' AND user_id IS NOT NULL AND subject_key = 'user:' || user_id::text)
    OR (subject_key LIKE 'reg:%' AND user_id IS NULL)),
  PRIMARY KEY (key, subject_key, route)
);
CREATE INDEX IF NOT EXISTS idempotency_keys_expires_idx ON idempotency_keys (expires_at);
CREATE INDEX IF NOT EXISTS idempotency_keys_user_idx ON idempotency_keys (user_id) WHERE user_id IS NOT NULL;

-- 5.57 audit_logs — DATA-156 (append-only, хэш-цепочка §9.3, INSERT-only для pos_app §9.4; DDL — §14.7)
CREATE SEQUENCE IF NOT EXISTS audit_logs_chain_seq AS bigint;

CREATE TABLE IF NOT EXISTS audit_logs (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  seq                 bigint GENERATED ALWAYS AS IDENTITY,
  chain_seq           bigint NOT NULL,
  occurred_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  level               audit_level NOT NULL,
  actor_user_id       uuid CONSTRAINT audit_logs_actor_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  actor_role          role_code,
  on_behalf_of_user_id uuid,
  session_id          uuid,
  device_id           uuid,
  ip                  inet,
  app_version         text,
  client_platform     text,
  request_id          text,
  action              text NOT NULL CONSTRAINT audit_logs_action_chk CHECK (action ~ '^[a-z_]+(\.[a-z_]+)+$'),
  entity_type         text,
  entity_id           uuid,
  onec_ref            uuid,
  before              jsonb,
  after               jsonb,
  result              text NOT NULL CONSTRAINT audit_logs_result_chk CHECK (result IN ('ok','denied','error')),
  step_up_method      step_up_method,
  reason              text,
  severity            text NOT NULL CONSTRAINT audit_logs_severity_chk CHECK (severity IN ('info','warning','critical')),
  prev_hash           bytea,
  row_hash            bytea NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT audit_logs_seq_uq UNIQUE (seq),
  CONSTRAINT audit_logs_chain_seq_uq UNIQUE (chain_seq)
);
CREATE INDEX IF NOT EXISTS audit_logs_entity_idx ON audit_logs (entity_type, entity_id, occurred_at);
CREATE INDEX IF NOT EXISTS audit_logs_actor_idx ON audit_logs (actor_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_action_idx ON audit_logs (action, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_occurred_brin ON audit_logs USING BRIN (occurred_at);

-- 5.58 audit_anchors — DATA-157 [ядро §17.3]
CREATE TABLE IF NOT EXISTS audit_anchors (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  anchor_date         date NOT NULL,
  last_chain_seq      bigint NOT NULL,
  last_row_hash       bytea NOT NULL,
  rows_count          bigint NOT NULL,
  exported_at         timestamptz,
  export_location     text,
  verified_at         timestamptz,
  verify_result       text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT audit_anchors_anchor_date_uq UNIQUE (anchor_date)
);

-- 5.59 app_settings — DATA-158 (ключи — seed этапа C, RM-C-006; секреты здесь не хранятся)
CREATE TABLE IF NOT EXISTS app_settings (
  key                 text PRIMARY KEY CONSTRAINT app_settings_key_chk CHECK (key ~ '^[a-z0-9_.]+$'),
  value               jsonb NOT NULL,
  value_type          text NOT NULL CONSTRAINT app_settings_value_type_chk CHECK (value_type IN ('boolean','integer','string','json','duration','money','percent')),
  is_secret           boolean NOT NULL DEFAULT false,
  description_ru      text NOT NULL,
  requires_step_up    boolean NOT NULL DEFAULT true,
  updated_by_user_id  uuid CONSTRAINT app_settings_updated_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  row_version         integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- 5.60 print_jobs (опционально) — DATA-159
CREATE TABLE IF NOT EXISTS print_jobs (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  order_id            uuid CONSTRAINT print_jobs_order_id_fk REFERENCES orders(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  payment_id          uuid CONSTRAINT print_jobs_payment_id_fk REFERENCES payments(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  document_kind       print_document_kind NOT NULL,
  paper               text NOT NULL CONSTRAINT print_jobs_paper_chk CHECK (paper IN ('a4','thermal80')),
  status              print_job_status NOT NULL,
  storage_key         text,
  sha256              bytea,
  version             smallint NOT NULL DEFAULT 1,
  requested_by_user_id uuid NOT NULL CONSTRAINT print_jobs_requested_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  error               text,
  printed_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT print_jobs_target_chk CHECK (num_nonnulls(order_id, payment_id) = 1),
  CONSTRAINT print_jobs_document_version_uq UNIQUE NULLS NOT DISTINCT (order_id, payment_id, document_kind, paper, version)
);
CREATE INDEX IF NOT EXISTS print_jobs_payment_idx ON print_jobs (payment_id);
CREATE INDEX IF NOT EXISTS print_jobs_queued_idx ON print_jobs (status) WHERE status = 'queued';

-- 5.64 sync_node_state — DATA-170 [ядро v1.7 §22.8]
CREATE TABLE IF NOT EXISTS sync_node_state (
  node                text PRIMARY KEY CONSTRAINT sync_node_state_node_chk CHECK (node ~ '^[a-z0-9_-]{1,40}$'),
  last_message_number bigint NOT NULL DEFAULT 0 CONSTRAINT sync_node_state_last_message_number_chk CHECK (last_message_number >= 0),
  last_ack_at         timestamptz,
  last_error_code     text CONSTRAINT sync_node_state_last_error_code_chk CHECK (last_error_code IS NULL OR last_error_code IN (
                        'NOT_FOUND_LOCAL','BARCODE_CONFLICT','VALIDATION','ONEC_REJECTED','ONEC_UNAVAILABLE',
                        'IMAGE_DOWNLOAD','HASH_MISMATCH','COUNT_MISMATCH','DUPLICATE_SUSPECTED','OUTBOX_UNCONFIRMED',
                        'PAYMENT_DOC_VOIDED','ORDER_MATCH_AMBIGUOUS','NO_WRITE_CHANNEL','OTHER')),
  last_ping_at        timestamptz,
  extension_version   text,
  api_version         text,
  registration_backlog integer CONSTRAINT sync_node_state_registration_backlog_chk CHECK (registration_backlog >= 0),
  clock_skew_sec      integer,
  onec_reachable      boolean NOT NULL DEFAULT true,
  unreachable_since   timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- 5.63 dev_outbox — DATA-169 [ядро §17.3]. Только dev/test-схема: DDL перенесён в
-- pos-api/db/migrations-dev/0001_dev_outbox.sql (RM-C-006 п. 6, 07 §5.63; ревью C-MJ-05). Каталог применяется
-- мигратором только при APP_ENV=dev и в prod-образ не копируется — в миграциях prod-образа DDL таблицы нет
-- (AC-DATA-169); на prod/staging-схеме to_regclass('dev_outbox') IS NULL.

-- =====================================================================================================
-- 10. Триггеры целостности (07 §2.1, §5, §7.5, §8.3, §9.2, §14)
-- =====================================================================================================

-- 10.1 updated_at — на каждой таблице со столбцом updated_at (DATA-002): trg_<table>_set_updated_at
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.table_name FROM information_schema.columns c
      JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
     WHERE c.table_schema = 'public' AND c.column_name = 'updated_at' AND t.table_type = 'BASE TABLE'
     ORDER BY c.table_name
  LOOP
    EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
                   'trg_' || r.table_name || '_set_updated_at', r.table_name);
  END LOOP;
END $$;

-- 10.2 row_version (07 §8.3): UPDATE под pos_app без инкремента запрещён, кроме системных обновлений
--      (SET LOCAL app.system = …). Таблицы — перечень §8.3. B-AR-20: версия растёт при ЛЮБОМ писателе —
--      системное обновление (воркер синхронизации с app.system, миграция, иная роль БД), не увеличившее
--      row_version само, получает +1 от триггера; иначе клиент с оптимистической блокировкой не увидит
--      изменение из 1С. Проверка «ровно +1» — только для pos_app без app.system (как в §8.3).
CREATE OR REPLACE FUNCTION check_row_version() RETURNS trigger LANGUAGE plpgsql AS $$
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
END $$;
-- payments.row_version (07 §5.40) вне перечня §8.3: проверки «ровно +1» нет, но версия растёт при любом UPDATE,
-- не увеличившем её явно (B-AR-20), — признак изменения для клиента. Переходы статусов платежа — условным
-- UPDATE … WHERE status IN (…) RETURNING (предложение 06 §7.6, NOTES.md §10).
CREATE OR REPLACE FUNCTION bump_row_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.row_version IS NOT DISTINCT FROM OLD.row_version THEN
    NEW.row_version := OLD.row_version + 1;
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER trg_carts_row_version BEFORE UPDATE ON carts FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE OR REPLACE TRIGGER trg_orders_row_version BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE OR REPLACE TRIGGER trg_user_profiles_row_version BEFORE UPDATE ON user_profiles FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE OR REPLACE TRIGGER trg_return_requests_row_version BEFORE UPDATE ON return_requests FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE OR REPLACE TRIGGER trg_customers_row_version BEFORE UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE OR REPLACE TRIGGER trg_discount_rules_row_version BEFORE UPDATE ON discount_rules FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE OR REPLACE TRIGGER trg_role_discount_limits_row_version BEFORE UPDATE ON role_discount_limits FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE OR REPLACE TRIGGER trg_app_settings_row_version BEFORE UPDATE ON app_settings FOR EACH ROW EXECUTE FUNCTION check_row_version();
CREATE OR REPLACE TRIGGER trg_payments_row_version BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION bump_row_version();

-- 10.3 roles: системные роли не удаляются и не меняют code (07 §5.4, AC-DATA-103)
CREATE OR REPLACE FUNCTION roles_protect_system() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.is_system AND coalesce(current_setting('app.system', true), '') IS DISTINCT FROM 'migration'
     AND (TG_OP = 'DELETE' OR NEW.code IS DISTINCT FROM OLD.code) THEN
    RAISE EXCEPTION 'roles: system role % cannot be deleted or renamed', OLD.code USING ERRCODE = 'restrict_violation';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER trg_roles_protect_system BEFORE UPDATE OR DELETE ON roles FOR EACH ROW EXECUTE FUNCTION roles_protect_system();

-- 10.4 integration_tokens: не более двух активных токенов (07 §5.62, DATA-168)
CREATE OR REPLACE FUNCTION integration_tokens_max_active() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('integration_tokens_max_active'));
  IF (SELECT count(*) FROM integration_tokens WHERE revoked_at IS NULL AND expires_at > now()) > 2 THEN
    RAISE EXCEPTION 'integration_tokens: no more than two active tokens are allowed' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;
CREATE OR REPLACE TRIGGER trg_integration_tokens_max_active AFTER INSERT OR UPDATE OF revoked_at, expires_at ON integration_tokens
  FOR EACH ROW EXECUTE FUNCTION integration_tokens_max_active();

-- 10.5 orders: заморозка финансовых полей после submit и однократный paid_at (07 §5.37, §9.2, §14.5)
CREATE OR REPLACE FUNCTION orders_freeze_financials() RETURNS trigger LANGUAGE plpgsql AS $$
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
END $$;
CREATE OR REPLACE TRIGGER trg_orders_freeze_financials BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION orders_freeze_financials();

CREATE OR REPLACE FUNCTION orders_paid_at_once() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.paid_at IS NOT NULL AND NEW.paid_at IS DISTINCT FROM OLD.paid_at
     AND current_setting('app.system', true) IS DISTINCT FROM 'migration' THEN
    RAISE EXCEPTION 'orders: paid_at is set once (order %)', OLD.public_number USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER trg_orders_paid_at_once BEFORE UPDATE OF paid_at ON orders FOR EACH ROW EXECUTE FUNCTION orders_paid_at_once();

-- 10.6 order_items: неизменяемы после orders.submitted_at, кроме shipped_quantity/returned_quantity/onec_*
--      (07 §5.38, §9.2); Σ line_total = orders.total при status <> 'draft' (trg_order_items_totals, §7.5) —
--      отложенный constraint-триггер, проверка при COMMIT.
CREATE OR REPLACE FUNCTION order_items_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
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
END $$;
CREATE OR REPLACE TRIGGER trg_order_items_freeze BEFORE UPDATE OR DELETE ON order_items FOR EACH ROW EXECUTE FUNCTION order_items_freeze();

CREATE OR REPLACE FUNCTION order_items_totals() RETURNS trigger LANGUAGE plpgsql AS $$
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
END $$;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_order_items_totals' AND tgrelid = 'public.order_items'::regclass) THEN
    CREATE CONSTRAINT TRIGGER trg_order_items_totals AFTER INSERT OR UPDATE OR DELETE ON order_items
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_items_totals();
  END IF;
END $$;

-- 10.7 payments: DELETE запрещён всегда; после received неизменяемы amount/method/order_id/customer_id/
--      received_amount/change_amount (07 §5.40, §7.5, §9.2)
CREATE OR REPLACE FUNCTION payments_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
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
END $$;
CREATE OR REPLACE TRIGGER trg_payments_freeze BEFORE UPDATE OR DELETE ON payments FOR EACH ROW EXECUTE FUNCTION payments_freeze();

-- 10.8 return_request_items: строки меняются только у draft-заявки; quantity ≤ отгружено − возвращено −
--      другие открытые заявки; line_total = round_half_up(si.line_total × quantity / si.quantity, 2) (07 §5.46, §7.5)
CREATE OR REPLACE FUNCTION return_request_items_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status return_request_status; si record; v_other numeric;
BEGIN
  SELECT status INTO v_status FROM return_requests
   WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.return_request_id ELSE NEW.return_request_id END;
  IF FOUND AND v_status <> 'draft' AND current_setting('app.system', true) IS DISTINCT FROM 'migration' THEN
    RAISE EXCEPTION 'return_request_items: lines are immutable after submit (return request is %)', v_status
      USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;

  SELECT quantity, returned_quantity, line_total INTO si FROM shipment_items WHERE id = NEW.shipment_item_id;
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
END $$;
CREATE OR REPLACE TRIGGER trg_return_request_items_guard BEFORE INSERT OR UPDATE OR DELETE ON return_request_items
  FOR EACH ROW EXECUTE FUNCTION return_request_items_guard();

-- 10.9 sync_node_state: last_message_number не уменьшается (07 §5.64, §14.6)
CREATE OR REPLACE FUNCTION sync_node_state_monotonic() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.last_message_number < OLD.last_message_number
     AND current_setting('app.system', true) IS DISTINCT FROM 'migration' THEN
    RAISE EXCEPTION 'sync_node_state: last_message_number must not decrease (node %)', OLD.node
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER trg_sync_node_state_monotonic BEFORE UPDATE OF last_message_number ON sync_node_state
  FOR EACH ROW EXECUTE FUNCTION sync_node_state_monotonic();

-- =====================================================================================================
-- 11. Аудит (07 §9): хэш-цепочка, append-only, триггеры уровня БД (level = 'db')
-- =====================================================================================================

-- 11.1 Канонизация строки (07 §9.3, §14.7): без id, seq, created_at, prev_hash, row_hash
CREATE OR REPLACE FUNCTION audit_canon(a audit_logs) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'chain_seq', a.chain_seq, 'occurred_at', to_char(a.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'level', a.level, 'actor_user_id', a.actor_user_id, 'actor_role', a.actor_role,
    'on_behalf_of_user_id', a.on_behalf_of_user_id, 'session_id', a.session_id, 'device_id', a.device_id,
    'ip', a.ip, 'request_id', a.request_id, 'action', a.action, 'entity_type', a.entity_type,
    'entity_id', a.entity_id, 'onec_ref', a.onec_ref, 'before', a.before, 'after', a.after,
    'result', a.result, 'step_up_method', a.step_up_method, 'reason', a.reason, 'severity', a.severity)::text
$$;

-- 11.2 Цепочка: блокировка → chain_seq → prev_hash предыдущей существующей строки → row_hash (§9.3)
CREATE OR REPLACE FUNCTION audit_logs_chain() RETURNS trigger LANGUAGE plpgsql AS $$
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
END $$;
CREATE OR REPLACE TRIGGER trg_audit_logs_chain BEFORE INSERT ON audit_logs FOR EACH ROW EXECUTE FUNCTION audit_logs_chain();

-- 11.3 Append-only: audit_logs, transactions, order_status_history (07 §9.2 trg_<t>_immutable) — для всех ролей
CREATE OR REPLACE FUNCTION append_only_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = 'insufficient_privilege'; END $$;
CREATE OR REPLACE TRIGGER trg_audit_logs_immutable BEFORE UPDATE OR DELETE ON audit_logs FOR EACH ROW EXECUTE FUNCTION append_only_immutable();
CREATE OR REPLACE TRIGGER trg_transactions_immutable BEFORE UPDATE OR DELETE ON transactions FOR EACH ROW EXECUTE FUNCTION append_only_immutable();
CREATE OR REPLACE TRIGGER trg_order_status_history_immutable BEFORE UPDATE OR DELETE ON order_status_history FOR EACH ROW EXECUTE FUNCTION append_only_immutable();

-- 11.4 Проверка цепочки (§9.3): обход по chain_seq; пропуски считаются, но не являются ошибкой
CREATE OR REPLACE FUNCTION audit_verify_chain(from_chain_seq bigint, to_chain_seq bigint)
RETURNS TABLE (ok boolean, broken_at_chain_seq bigint, gaps integer) LANGUAGE plpgsql STABLE AS $$
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
END $$;

-- 11.5 Запись уровня БД (07 §9.1): контекст из SET LOCAL app.actor_id / app.actor_role / app.session_id /
--      app.device_id / app.request_id / app.ip; без актора и без app.system — severity 'warning'.
CREATE OR REPLACE FUNCTION audit_guc(p_name text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting(p_name, true), '')
$$;

CREATE OR REPLACE FUNCTION audit_guc_uuid(p_name text) RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN v::uuid END
    FROM (SELECT NULLIF(current_setting(p_name, true), '') AS v) s
$$;

CREATE OR REPLACE FUNCTION audit_guc_inet(p_name text) RETURNS inet LANGUAGE plpgsql STABLE AS $$
DECLARE v text := NULLIF(current_setting(p_name, true), '');
BEGIN
  RETURN v::inet;
EXCEPTION WHEN others THEN
  RETURN NULL;
END $$;

-- маскирование телефонов в before/after (07 §9.5: «+996 *** ** 67»)
CREATE OR REPLACE FUNCTION audit_mask_phone(v jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE jsonb_typeof(v)
    WHEN 'string' THEN to_jsonb('+996 *** ** ' || right(v #>> '{}', 2))
    WHEN 'array'  THEN (SELECT coalesce(jsonb_agg(CASE WHEN jsonb_typeof(e) = 'string'
                                                      THEN to_jsonb('+996 *** ** ' || right(e #>> '{}', 2)) ELSE e END), '[]'::jsonb)
                          FROM jsonb_array_elements(v) e)
    ELSE v END
$$;

CREATE OR REPLACE FUNCTION audit_mask_pii(j jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN j IS NULL THEN NULL ELSE
    (SELECT coalesce(jsonb_object_agg(e.key,
              CASE WHEN e.key LIKE '%phone%' AND e.key NOT LIKE '%hmac%' THEN audit_mask_phone(e.value) ELSE e.value END),
            '{}'::jsonb)
       FROM jsonb_each(j) e) END
$$;

-- выбор столбцов: p_cols (если задан) ∪ p_keep; иначе все, кроме created_at/updated_at/row_version
CREATE OR REPLACE FUNCTION audit_jsonb_pick(j jsonb, p_cols text[], p_keep text[]) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN j IS NULL THEN NULL ELSE
    (SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
       FROM jsonb_each(j) e
      WHERE CASE WHEN coalesce(cardinality(p_cols), 0) > 0
                 THEN e.key = ANY (p_cols) OR e.key = ANY (coalesce(p_keep, '{}'))
                 ELSE e.key NOT IN ('created_at','updated_at','row_version') END) END
$$;

-- diff: для UPDATE — только изменившиеся столбцы (+ идентифицирующие p_keep); нет изменений → обе NULL
CREATE OR REPLACE FUNCTION audit_row_diff(p_old jsonb, p_new jsonb, p_cols text[], p_keep text[],
                                          OUT before jsonb, OUT after jsonb) LANGUAGE plpgsql IMMUTABLE AS $$
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
END $$;

CREATE OR REPLACE FUNCTION audit_db_write(p_action text, p_entity_type text, p_entity_id uuid,
                                          p_before jsonb, p_after jsonb) RETURNS void LANGUAGE plpgsql AS $$
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
END $$;

-- Универсальный триггер уровня БД. Аргументы: [0] действие ('a' или 'вставка|изменение|удаление', пусто —
-- не писать); [1] идентифицирующие столбцы через запятую (первый uuid → entity_id; всегда в before/after);
-- [2] фильтр строки 'столбец=значение' или ''; [3..] отслеживаемые столбцы (нет — все, кроме служебных).
CREATE OR REPLACE FUNCTION audit_db_changes() RETURNS trigger LANGUAGE plpgsql AS $$
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
END $$;

-- users: status → blocked/deleted, blocked → active, смена phone_e164 (07 §9.2; коды — 11 §7.2)
CREATE OR REPLACE FUNCTION users_audit() RETURNS trigger LANGUAGE plpgsql AS $$
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
END $$;

-- orders: статус, скидки, долг, итоги, отмена (07 §9.2); код события — 11 §7.2 либо db.orders.<op>
CREATE OR REPLACE FUNCTION orders_audit() RETURNS trigger LANGUAGE plpgsql AS $$
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
END $$;

CREATE OR REPLACE TRIGGER trg_orders_audit AFTER UPDATE OR DELETE ON orders
  FOR EACH ROW EXECUTE FUNCTION orders_audit();
CREATE OR REPLACE TRIGGER trg_payments_audit AFTER UPDATE OR DELETE ON payments
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('|db.payments.update|db.payments.delete', 'id,public_number', '',
    'status','amount','method','order_id','customer_id','received_amount','change_amount','bank_amount',
    'received_by_user_id','received_at','review_reason','manual_confirmed_by_user_id','manual_reason',
    'voided_by_user_id','void_reason','qr_provider','qr_provider_ref','bank_reference','onec_ref');
CREATE OR REPLACE TRIGGER trg_discount_rules_audit AFTER INSERT OR UPDATE OR DELETE ON discount_rules
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('discount.rule_changed', 'id', 'source=pos');
CREATE OR REPLACE TRIGGER trg_role_discount_limits_audit AFTER INSERT OR UPDATE OR DELETE ON role_discount_limits
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('discount.limits_changed', 'id,role', '');
CREATE OR REPLACE TRIGGER trg_user_roles_audit AFTER INSERT OR UPDATE ON user_roles
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('user.role_changed', 'user_id,role_id,id', '');
CREATE OR REPLACE TRIGGER trg_users_audit AFTER UPDATE OF status, phone_e164 ON users
  FOR EACH ROW EXECUTE FUNCTION users_audit();
CREATE OR REPLACE TRIGGER trg_role_permissions_audit AFTER INSERT OR UPDATE OR DELETE ON role_permissions
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('rbac.matrix_changed', 'role_id,permission_id', '');
CREATE OR REPLACE TRIGGER trg_app_settings_audit AFTER UPDATE ON app_settings
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('settings.changed', 'key', '');
CREATE OR REPLACE TRIGGER trg_customers_audit AFTER INSERT OR UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('customer.created|customer.updated', 'id', 'source=pos');
CREATE OR REPLACE TRIGGER trg_return_requests_audit AFTER UPDATE ON return_requests
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('return.status_changed', 'id,public_number', '', 'status');
CREATE OR REPLACE TRIGGER trg_warehouses_admin_audit AFTER UPDATE ON warehouses
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('settings.changed', 'id', '', 'short_name','is_active','is_default_for_pos','sort_order');
CREATE OR REPLACE TRIGGER trg_price_lists_admin_audit AFTER UPDATE ON price_lists
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('settings.changed', 'id', '', 'is_default','visible_to_roles','sort_order');
CREATE OR REPLACE TRIGGER trg_product_attributes_admin_audit AFTER UPDATE ON product_attributes
  FOR EACH ROW EXECUTE FUNCTION audit_db_changes('settings.changed', 'id', '', 'code','is_filterable','is_variant_axis','sort_order');

-- =====================================================================================================
-- 12. Права ролей БД (07 §2.1, §9.4, §14.1, §14.7; DATA-012, DATA-156, DATA-138, DATA-143, DATA-131)
-- =====================================================================================================
GRANT USAGE ON SCHEMA public TO pos_app, pos_readonly, pos_backup;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO pos_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO pos_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pos_readonly, pos_backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO pos_backup;

-- audit_logs: только INSERT и SELECT (append-only; UPDATE/DELETE также запрещены триггером для всех ролей)
REVOKE ALL ON audit_logs FROM pos_app;
GRANT INSERT, SELECT ON audit_logs TO pos_app;
GRANT USAGE ON SEQUENCE audit_logs_chain_seq TO pos_app;
-- transactions, order_status_history: INSERT-only для pos_app
REVOKE UPDATE, DELETE ON transactions, order_status_history FROM pos_app;
-- receivable_documents: без физического удаления (06 EVO-007)
REVOKE DELETE ON receivable_documents FROM pos_app;
GRANT SELECT ON audit_logs, audit_anchors TO pos_readonly;

-- объекты, которые pos_migrate создаст следующими миграциями
ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO pos_app;
ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO pos_app;
ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate IN SCHEMA public
  GRANT SELECT ON TABLES TO pos_readonly, pos_backup;

-- =====================================================================================================
-- 13. Seed (07 §5.64, §14.6): узел плана обмена — одна торговая точка (ядро §22.10)
-- =====================================================================================================
INSERT INTO sync_node_state (node) VALUES ('pos') ON CONFLICT (node) DO NOTHING;

COMMIT;

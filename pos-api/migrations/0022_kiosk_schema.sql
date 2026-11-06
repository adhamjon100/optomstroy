-- 0022_kiosk_schema.sql — схема режима «Планшет магазина» (P-002 ред. 5, ADR-115; задача TAB-1-01, часть «БД»).
--
-- Основание: 07 v1.17 — §5.65 `store_tablets` (DATA-171), §5.1 (`users_kiosk_phone_chk`), §5.9 (`kiosk_revoked`),
-- §5.11 (код `kiosk_order`, DATA-301), §5.12 (области `otp_kiosk_tablet_*`), §5.37 (канал `kiosk`, DATA-302, DATA-303),
-- §5.61 (шаблон `otp_kiosk_order`), §6.1.1, §12.2 (DATA-305), DDL §14.3 и §14.5. Если пример DDL §14 расходится с
-- карточкой §5, действует карточка (DATA-285).
-- Значения enum-ов (`user_kind`/`role_code` — `kiosk`, `otp_purpose`/`notification_kind` — `kiosk_order`) добавлены
-- отдельным файлом 0021_kiosk_enum_values.sql и к началу этой транзакции уже зафиксированы (07 §12.2). Роль `kiosk`
-- и её права — следующая миграция (seed RBAC 0023); 0002_rbac_seed.sql и seeds/ не меняются.
--
-- Состав:
--   1. Таблица `store_tablets` (07 §5.65, §14.3): строка на планшет и его технического пользователя `kind='kiosk'`;
--      хэш аварийного кода выхода с версией pepper, попытки и пауза выхода, отметки связи, версия приложения,
--      состояние закрепления (`lock_task_enabled`: NULL до первого `X-Kiosk-Lock`), подключение заново, отключение.
--      Имя и склад планшета — в `user_profiles` технического пользователя, здесь не дублируются.
--   2. `users`: CHECK `users_kiosk_phone_chk` — у технического пользователя планшета нет телефона.
--   3. CHECK `sessions_revoke_reason_chk` — + `kiosk_revoked` (прежние 13 значений, включая `refresh_replay` 0003).
--   4. CHECK `rate_limit_counters_scope_chk` — + `otp_kiosk_tablet_1h`, `otp_kiosk_tablet_24h` (прежние 14 значений).
--   5. CHECK `sms_outbox_template_key_chk` — + `otp_kiosk_order`. CHECK `dev_outbox` (db/migrations-dev) не меняется:
--      фейковый SMS-шлюз пишет туда `otp_login` (ADR-115 п. 25; dev-миграция не добавляется — эпоха веб-демо).
--   6. `otp_challenges`: `kiosk_tablet_id` (FK store_tablets), `cart_id` (FK carts — исключение DATA-031 для auth →
--      sales), `notice_version`; CHECK `otp_challenges_kiosk_chk`; один действующий код на планшет
--      (`otp_challenges_kiosk_active_uq`); индекс `otp_challenges_kiosk_created_idx` (алерт «≥ 10 кодов за 10 мин»).
--   7. `orders`: CHECK `orders_created_via_chk` — + `kiosk` (`created_via` остаётся текстом с CHECK, не enum);
--      CHECK канала `orders_kiosk_channel_chk` (только наличные, самовывоз, без ручной скидки и продажи в долг;
--      скидку клиента 1С не ограничивает — Р-05 (а)); `kiosk_customer_match` (+ CHECK значений и
--      `orders_kiosk_match_chk`), `pd_notice_version`, `pd_notice_sha256` (hex 64), `receiver_phone_masked`
--      (формат маски `+996 7** *** *NN` и «не вместе с E.164»); индекс `orders_kiosk_idx`. CHECK E.164
--      `orders_receiver_phone_e164_chk` и триггер `trg_orders_freeze_financials` не меняются (новые столбцы триггер
--      не охраняет — маскирование через 90 дней проходит и после submit).
--
-- Имена FK и CHECK — по соглашению 07 §2.1 (`<table>_<col>_fk`, `ON DELETE RESTRICT ON UPDATE RESTRICT`, как в 0001).
-- Expand-only (forward-only, 07 §13): новая таблица, новые столбцы допускают NULL; новые CHECK существующим строкам
-- не противоречат (у них `created_via IN ('staff','customer')`, новые столбцы пусты), старый код продолжает работать.
-- Идемпотентно: таблица, столбцы и индексы — IF NOT EXISTS, триггер — CREATE OR REPLACE, новые FK и CHECK — под
-- проверкой pg_constraint, CHECK-перечень пересоздаётся, только если в нём ещё нет нового значения (как
-- 0003_auth_refinements.sql:29-74, 0013_sync_error_code_qr_paid_after_void.sql:16-60). Повторное применение —
-- 0 изменений (tools/pg/run-sql.mjs --repeat-strict, двойной прогон CI).

BEGIN;

-- 1. store_tablets — DATA-171 (07 §5.65, §14.3).
CREATE TABLE IF NOT EXISTS store_tablets (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id             uuid NOT NULL CONSTRAINT store_tablets_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  device_id           uuid NOT NULL CONSTRAINT store_tablets_device_id_fk REFERENCES devices(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  status              text NOT NULL DEFAULT 'active' CONSTRAINT store_tablets_status_chk CHECK (status IN ('active','revoked')),
  exit_code_hash      text NOT NULL,
  exit_code_pepper_version smallint NOT NULL,
  exit_code_used_at   timestamptz,
  exit_failed_attempts smallint NOT NULL DEFAULT 0 CONSTRAINT store_tablets_exit_failed_attempts_chk CHECK (exit_failed_attempts >= 0),
  exit_locked_until   timestamptz,
  enrolled_by_user_id uuid NOT NULL CONSTRAINT store_tablets_enrolled_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  enrolled_at         timestamptz NOT NULL DEFAULT now(),
  last_seen_at        timestamptz,
  last_app_version    text,
  lock_task_enabled   boolean,
  reconnected_at      timestamptz,
  reconnected_by_user_id uuid CONSTRAINT store_tablets_reconnected_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  revoked_at          timestamptz,
  revoked_by_user_id  uuid CONSTRAINT store_tablets_revoked_by_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  revoke_reason       text CONSTRAINT store_tablets_revoke_reason_chk CHECK (revoke_reason ~ '^[a-z_]+(\.[a-z_]+)+$'),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT store_tablets_revoked_chk CHECK ((status = 'revoked') = (revoked_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS store_tablets_user_id_uq ON store_tablets (user_id);
CREATE INDEX IF NOT EXISTS store_tablets_device_idx ON store_tablets (device_id);
-- updated_at — триггером, как у всех таблиц 0001 (DATA-002; цикл 0001 раздел 10.1 новые таблицы не видит).
CREATE OR REPLACE TRIGGER trg_store_tablets_set_updated_at BEFORE UPDATE ON store_tablets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
-- Права как у таблиц схемы (0001 раздел 12: GRANT … ON ALL TABLES IN SCHEMA public — только для таблиц, созданных
-- до него; ALTER DEFAULT PRIVILEGES действует, лишь когда мигратор — pos_migrate), как 0005_search.sql:69-72.
GRANT SELECT, INSERT, UPDATE, DELETE ON store_tablets TO pos_app;
GRANT SELECT ON store_tablets TO pos_readonly, pos_backup;

-- 2. users: технический пользователь планшета — без телефона (07 §5.1, DATA-300).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'users_kiosk_phone_chk' AND conrelid = 'public.users'::regclass) THEN
    ALTER TABLE users ADD CONSTRAINT users_kiosk_phone_chk CHECK (kind <> 'kiosk' OR phone_e164 IS NULL);
  END IF;
END $$;

-- 3. Причина отзыва сессии: + kiosk_revoked (07 §5.9; 09 §8.9).
DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'sessions_revoke_reason_chk' AND conrelid = 'public.sessions'::regclass;
  IF def IS NULL OR position('kiosk_revoked' IN def) = 0 THEN
    ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_revoke_reason_chk;
    ALTER TABLE sessions ADD CONSTRAINT sessions_revoke_reason_chk CHECK (revoke_reason IN (
      'logout','logout_all','reuse_detected','admin','phone_changed','role_changed','expired','device_revoked',
      'blocked','session_limit','device_mismatch','biometric_invalidated','refresh_replay','kiosk_revoked'));
  END IF;
END $$;

-- 4. Области счётчиков лимитов: + лимиты кодов с планшета (07 §5.12; subject = store_tablets.id).
DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'rate_limit_counters_scope_chk' AND conrelid = 'public.rate_limit_counters'::regclass;
  IF def IS NULL OR position('otp_kiosk_tablet_1h' IN def) = 0 OR position('otp_kiosk_tablet_24h' IN def) = 0 THEN
    ALTER TABLE rate_limit_counters DROP CONSTRAINT IF EXISTS rate_limit_counters_scope_chk;
    ALTER TABLE rate_limit_counters ADD CONSTRAINT rate_limit_counters_scope_chk CHECK (scope IN (
      'otp_phone_15m','otp_phone_24h','otp_ip_1h','otp_device_24h','login_ip_1h','step_up_user_1h','webhook_ip_1m',
      'otp_ip_10m','otp_ip_24h','otp_device_10m','otp_global_1m','otp_verify_ip_10m','pin_user_device_10m',
      'admin_user_1m','otp_kiosk_tablet_1h','otp_kiosk_tablet_24h'));
  END IF;
END $$;

-- 5. Шаблон SMS: + otp_kiosk_order (07 §5.61; свой текст SMS — Р-21 (а)).
DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'sms_outbox_template_key_chk' AND conrelid = 'public.sms_outbox'::regclass;
  IF def IS NULL OR position('otp_kiosk_order' IN def) = 0 THEN
    ALTER TABLE sms_outbox DROP CONSTRAINT IF EXISTS sms_outbox_template_key_chk;
    ALTER TABLE sms_outbox ADD CONSTRAINT sms_outbox_template_key_chk CHECK (template_key IN (
      'otp_login','otp_step_up','otp_phone_change','otp_customer_link','otp_kiosk_order'));
  END IF;
END $$;

-- 6. otp_challenges: код заявки с планшета привязан к планшету, корзине и версии текста информирования
--    (07 §5.11, DATA-301).
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS kiosk_tablet_id uuid;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS cart_id uuid;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS notice_version text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'otp_challenges_kiosk_tablet_id_fk'
                    AND conrelid = 'public.otp_challenges'::regclass) THEN
    ALTER TABLE otp_challenges ADD CONSTRAINT otp_challenges_kiosk_tablet_id_fk FOREIGN KEY (kiosk_tablet_id)
      REFERENCES store_tablets(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
  END IF;
  -- Междоменная связь auth → sales — исключение DATA-031 (07 §5.11).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'otp_challenges_cart_id_fk'
                    AND conrelid = 'public.otp_challenges'::regclass) THEN
    ALTER TABLE otp_challenges ADD CONSTRAINT otp_challenges_cart_id_fk FOREIGN KEY (cart_id)
      REFERENCES carts(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
  END IF;
  -- У кода планшета всегда есть планшет, корзина и версия текста и нет пользователя и выдавшего администратора;
  -- у остальных целей три новых столбца пусты (07 §5.11, AC-DATA-301: «строка login_or_register с kiosk_tablet_id →
  -- ошибка CHECK»). Формула 07 дополнена вторым условием: без него код другой цели с одним или двумя из трёх
  -- столбцов проходил бы CHECK (равенство требует лишь «не все три»); предложение 07 — pos-api/migrations/NOTES.md §12.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'otp_challenges_kiosk_chk'
                    AND conrelid = 'public.otp_challenges'::regclass) THEN
    ALTER TABLE otp_challenges ADD CONSTRAINT otp_challenges_kiosk_chk CHECK (
      (purpose = 'kiosk_order') = (kiosk_tablet_id IS NOT NULL AND cart_id IS NOT NULL AND notice_version IS NOT NULL)
      AND (purpose = 'kiosk_order' OR (kiosk_tablet_id IS NULL AND cart_id IS NULL AND notice_version IS NULL))
      AND (purpose <> 'kiosk_order' OR (user_id IS NULL AND issued_by_user_id IS NULL)));
  END IF;
END $$;

-- Один действующий код на планшет: новый запрос сначала переводит прежний в superseded (07 §5.11).
CREATE UNIQUE INDEX IF NOT EXISTS otp_challenges_kiosk_active_uq ON otp_challenges (kiosk_tablet_id)
  WHERE purpose = 'kiosk_order' AND status = 'sent';
-- Алерт «≥ 10 кодов с одного планшета за 10 мин» (11 §6.2).
CREATE INDEX IF NOT EXISTS otp_challenges_kiosk_created_idx ON otp_challenges (kiosk_tablet_id, created_at)
  WHERE kiosk_tablet_id IS NOT NULL;

-- 7. orders: канал kiosk (07 §5.37, §14.5; DATA-302, DATA-303; T-KIOSK-025).
DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'orders_created_via_chk' AND conrelid = 'public.orders'::regclass;
  IF def IS NULL OR position('kiosk' IN def) = 0 THEN
    ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_created_via_chk;
    ALTER TABLE orders ADD CONSTRAINT orders_created_via_chk CHECK (created_via IN ('staff','customer','kiosk'));
  END IF;
END $$;

ALTER TABLE orders ADD COLUMN IF NOT EXISTS kiosk_customer_match text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS pd_notice_version text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS pd_notice_sha256 text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS receiver_phone_masked text;

DO $$
BEGIN
  -- Итог поиска карточки по номеру покупателя (только у канала kiosk; перечень — 07 §6.1.1).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'orders_kiosk_customer_match_chk' AND conrelid = 'public.orders'::regclass) THEN
    ALTER TABLE orders ADD CONSTRAINT orders_kiosk_customer_match_chk CHECK (kiosk_customer_match IN ('single','ambiguous','none'));
  END IF;
  -- SHA-256 текста информирования (hex, 64 символа; contracts/legal/notices_ru.md).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'orders_pd_notice_sha256_chk' AND conrelid = 'public.orders'::regclass) THEN
    ALTER TABLE orders ADD CONSTRAINT orders_pd_notice_sha256_chk CHECK (pd_notice_sha256 ~ '^[0-9a-f]{64}$');
  END IF;
  -- Маска номера после срока хранения: формат PhoneMasked контракта («+996 7** *** *01»).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'orders_receiver_phone_masked_chk' AND conrelid = 'public.orders'::regclass) THEN
    ALTER TABLE orders ADD CONSTRAINT orders_receiver_phone_masked_chk
      CHECK (receiver_phone_masked ~ '^\+996 [0-9]\*\* \*\*\* \*[0-9]{2}$');
  END IF;
  -- Канал kiosk: только наличные и самовывоз, без ручной скидки, её подтверждения и продажи в долг;
  -- скидка клиента 1С (customer_discount_*) допустима (Р-05 (а)).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'orders_kiosk_channel_chk' AND conrelid = 'public.orders'::regclass) THEN
    ALTER TABLE orders ADD CONSTRAINT orders_kiosk_channel_chk CHECK (created_via <> 'kiosk'
      OR (payment_method = 'cash' AND discount_percent = 0 AND manual_discount_total = 0
          AND discount_approved_by_user_id IS NULL AND credit_approved_by_user_id IS NULL
          AND delivery_method = 'pickup'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'orders_kiosk_match_chk' AND conrelid = 'public.orders'::regclass) THEN
    ALTER TABLE orders ADD CONSTRAINT orders_kiosk_match_chk CHECK ((created_via = 'kiosk') = (kiosk_customer_match IS NOT NULL));
  END IF;
  -- Маска и E.164 вместе не хранятся: задание ретенции ставит receiver_phone_e164 = NULL тем же UPDATE.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'orders_receiver_phone_masked_null_chk' AND conrelid = 'public.orders'::regclass) THEN
    ALTER TABLE orders ADD CONSTRAINT orders_receiver_phone_masked_null_chk
      CHECK (receiver_phone_masked IS NULL OR receiver_phone_e164 IS NULL);
  END IF;
END $$;

-- Заявки с планшета (SCR-24 «С планшета») и задание маскирования номера через 90 дней.
CREATE INDEX IF NOT EXISTS orders_kiosk_idx ON orders (status, created_at) WHERE created_via = 'kiosk';

COMMIT;

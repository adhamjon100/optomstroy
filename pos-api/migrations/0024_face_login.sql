-- 0024_face_login.sql — схема входа по лицу на всех платформах (15 ADR-116; ответы владельца 2026-11-07 и 2026-11-08
-- на Q-353, Q-355; пакет LF-2-01 дорожки LF, 13 §3.14).
--
-- Основание: 07 v1.18 — §5.8 (`devices_device_key_idx`), §5.9 (`weak_reauth_due_at`, `sessions_weak_reauth_chk`,
-- причина `biometric_weak_disabled`), §5.66 `hello_keys` (DATA-172), §5.G (DATA-306…DATA-308), §6.1.1, §12.2 «Вход по
-- лицу — миграция 0024_face_login.sql», DDL §14.3. Если пример DDL §14 расходится с карточкой §5, действует карточка
-- (DATA-285).
--
-- Состав:
--   1. `sessions.weak_reauth_due_at` — признак и срок уровня W Android (Class 2, без криптопривязки): NOT NULL ⇔ семья
--      уровня W; CHECK `sessions_weak_reauth_chk` — только у `kind = 'biometric'` (DATA-306).
--   2. CHECK `sessions_revoke_reason_chk` — + `biometric_weak_disabled` (уровень W запрещён `AUTH_BIO_ALLOW_WEAK`;
--      прежние 14 значений, включая `refresh_replay` 0003 и `kiosk_revoked` 0022, сохранены).
--   3. Таблица `hello_keys` (07 §5.66): открытый ключ входа через Windows Hello без PIN приложения (W2) и ключ браузера
--      на Windows в веб-демо; один живой ключ на строку `devices`; текущий challenge разблокировки — вместе с сессией и
--      сроком. Пишет и читает её сервер W2 (пакет LF-2-06); здесь — только схема. Причины отзыва `blocked` и
--      `pin_reset` (блокировка пользователя и сброс PIN администратором, 08 §4.18.3, §4.18.9) добавлены 2026-11-18 до
--      выпуска файла (пакет LF-2-06): ни одна среда 0024 ещё не применяла.
--   4. Индекс `devices_device_key_idx` — правило `personal` ключа Windows Hello (входил ли с этой установкой другой
--      пользователь, 08 §4.1.10). Без CONCURRENTLY: таблица мала и в перечень 07 §12.1 не входит.
--
-- Новых значений enum-типов нет — отдельного файла с `ALTER TYPE` (07 §12.2, DATA-305) не нужно; типов по-прежнему 45.
-- RBAC-сида нет: новых прав нет (путь challenge публичный, `POST /me/biometrics` — прежнее право). Применённые
-- 0001…0023, `seeds/` и `db/migrations-dev/` не меняются. Ключ эпохи веб-демо файл не меняет: в ключ входят миграции до
-- `EPOCH_MIGRATION_BASE` = `0020` (`demo/web/backend/demo-config.mjs`, `lib/epoch.mjs`), эту применяет мигратор на
-- тёплом старте (07 §12.2, DATA-308).
--
-- Имена FK и CHECK — по соглашению 07 §2.1 (`<table>_<col>_fk`, `ON DELETE RESTRICT ON UPDATE RESTRICT`, как в 0001).
-- Expand-only (forward-only, 07 §13): новый столбец допускает NULL, новая таблица пуста, новые CHECK существующим строкам
-- не противоречат (у них `weak_reauth_due_at IS NULL`), старый код продолжает работать.
-- Идемпотентно: столбец, таблица и индексы — IF NOT EXISTS, триггер — CREATE OR REPLACE, новый CHECK — под проверкой
-- pg_constraint, CHECK-перечень пересоздаётся, только если в нём ещё нет нового значения (как 0003_auth_refinements.sql
-- и 0022_kiosk_schema.sql). Повторное применение — 0 изменений (tools/pg/run-sql.mjs --repeat-strict, двойной прогон CI).

BEGIN;

-- 1. Уровень W Android: срок разблокировки лицом без PIN (07 §5.9; 09 BIO-031; 08 §4.1.8).
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS weak_reauth_due_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'sessions_weak_reauth_chk' AND conrelid = 'public.sessions'::regclass) THEN
    ALTER TABLE sessions ADD CONSTRAINT sessions_weak_reauth_chk CHECK (weak_reauth_due_at IS NULL OR kind = 'biometric');
  END IF;
END $$;

-- 2. Причина отзыва сессии: + biometric_weak_disabled (07 §5.9; 09 BIO-032).
DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'sessions_revoke_reason_chk' AND conrelid = 'public.sessions'::regclass;
  IF def IS NULL OR position('biometric_weak_disabled' IN def) = 0 THEN
    ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_revoke_reason_chk;
    ALTER TABLE sessions ADD CONSTRAINT sessions_revoke_reason_chk CHECK (revoke_reason IN (
      'logout','logout_all','reuse_detected','admin','phone_changed','role_changed','expired','device_revoked',
      'blocked','session_limit','device_mismatch','biometric_invalidated','refresh_replay','kiosk_revoked',
      'biometric_weak_disabled'));
  END IF;
END $$;

-- 3. hello_keys — DATA-172 (07 §5.66, §14.3). Перечни algorithm, source, revoke_reason — 07 §6.1.1
--    (contracts/enums.json: hello_key_algorithm, hello_key_source, hello_key_revoke_reason).
CREATE TABLE IF NOT EXISTS hello_keys (
  id                   uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id              uuid NOT NULL CONSTRAINT hello_keys_user_id_fk REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  device_id            uuid NOT NULL CONSTRAINT hello_keys_device_id_fk REFERENCES devices(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  public_key           bytea NOT NULL CONSTRAINT hello_keys_public_key_len_chk CHECK (octet_length(public_key) BETWEEN 256 AND 1024),
  algorithm            text NOT NULL CONSTRAINT hello_keys_algorithm_chk CHECK (algorithm IN ('RS256')),
  source               text NOT NULL CONSTRAINT hello_keys_source_chk CHECK (source IN ('windows_hello','webauthn_prf')),
  last_used_at         timestamptz,
  challenge            bytea,
  challenge_session_id uuid CONSTRAINT hello_keys_challenge_session_id_fk REFERENCES sessions(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  challenge_expires_at timestamptz,
  revoked_at           timestamptz,
  revoke_reason        text CONSTRAINT hello_keys_revoke_reason_chk CHECK (revoke_reason IN ('disabled','replaced',
                         'invalidated','policy_off','shared_device','logout_all','phone_changed','kiosk_connect',
                         'blocked','pin_reset')),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT hello_keys_revoked_chk CHECK ((revoked_at IS NULL) = (revoke_reason IS NULL)),
  -- challenge (32 байта CSPRNG), сессия и срок — все три или ни одного; у отозванного ключа challenge нет.
  CONSTRAINT hello_keys_challenge_chk CHECK (
    (challenge IS NULL AND challenge_session_id IS NULL AND challenge_expires_at IS NULL)
    OR (octet_length(challenge) = 32 AND challenge_session_id IS NOT NULL AND challenge_expires_at IS NOT NULL
        AND revoked_at IS NULL))
);
-- Не больше одного живого ключа на установку приложения (строку devices); отзыв всех ключей пользователя.
CREATE UNIQUE INDEX IF NOT EXISTS hello_keys_device_live_uq ON hello_keys (device_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS hello_keys_user_live_idx ON hello_keys (user_id) WHERE revoked_at IS NULL;
-- updated_at — триггером, как у всех таблиц 0001 (DATA-002; цикл 0001 раздел 10.1 новые таблицы не видит).
CREATE OR REPLACE TRIGGER trg_hello_keys_set_updated_at BEFORE UPDATE ON hello_keys
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
-- Права как у таблиц схемы (0001 раздел 12; как store_tablets в 0022): GRANT … ON ALL TABLES раздела 12 новые таблицы
-- не видит, ALTER DEFAULT PRIVILEGES действует, лишь когда мигратор — pos_migrate.
GRANT SELECT, INSERT, UPDATE, DELETE ON hello_keys TO pos_app;
GRANT SELECT ON hello_keys TO pos_readonly, pos_backup;

-- 4. devices: поиск установки по device_key без пользователя — правило personal (07 §5.8; 08 §4.1.10).
CREATE INDEX IF NOT EXISTS devices_device_key_idx ON devices (device_key);

COMMIT;

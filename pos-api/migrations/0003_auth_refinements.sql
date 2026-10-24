-- 0003_auth_refinements.sql — технические уточнения схемы авторизации по итогам этапа D (D_authentication_report §5.3:
-- DQ-01…DQ-03; D_spec_questions F-01, auth A-02/A-07/A-08/A-15, adm A-08/A-09/A-11, SMS-Q-06, FX-01, FX-11).
--
-- Основание: 09_AUTH_SMS_BIOMETRICS §17 п. 19(а) (правки 07: `revoke_reason = refresh_replay`, отметка выдавшего
-- аварийный код администратора в `otp_challenges`), 09 §6.13 п. 3 (`amr = admin_code`), 09 §5.4 / 16 §4.3 / 08 §2.9
-- (окна лимитов RL-OTP-SEND-IP/-DEV, RL-OTP-GLOBAL, RL-OTP-VERIFY, RL-PIN, RL-ADMIN — хранение в PostgreSQL), 11 SEC-064
-- (`request_id` в `sms_outbox`), 09 §5.4 (пауза номера считается от блокировки кода), 09 §5.6 (отзыв `jti` ранее
-- выданного токена при повторе verify). Бизнес-правила не меняются: только хранение того, что код уже делает.
--
-- Состав:
--   1. CHECK `rate_limit_counters_scope_chk` — + `otp_ip_10m`, `otp_ip_24h`, `otp_device_10m`, `otp_global_1m`,
--      `otp_verify_ip_10m`, `pin_user_device_10m`, `admin_user_1m` (прежние 7 значений сохранены).
--   2. CHECK `sessions_amr_chk` — + `admin_code` (вход по аварийному коду администратора).
--   3. CHECK `sessions_revoke_reason_chk` — + `refresh_replay` (поздний повтор refresh у пользователя без PIN).
--   4. `otp_challenges`: `issued_by_user_id` (FK users, кто выдал аварийный код; CHECK — только челлендж входа без
--      SMS), `locked_at` (момент блокировки кода), `issued_jti` (jti токена, выданного по челленджу). Заполнение
--      `issued_by_user_id` для уже выданных кодов — из аудита `auth.emergency_code.issued`; `sessions.amr` таких
--      входов: `sms` → `admin_code`.
--   5. `sms_outbox.request_id` — сквозной идентификатор запроса (11 SEC-064).
--
-- Expand-only (forward-only, 07 §13): новые столбцы допускают NULL, старый код (до 0003) продолжает работать.
-- Идемпотентно: столбцы/индексы — IF NOT EXISTS, CHECK пересоздаётся только если в нём нет нового значения,
-- заполнение — только строк с NULL. Повторное применение — 0 изменений (tools/pg/run-sql.mjs --repeat-strict).
-- contracts/enums.json (`rate_limit_scope`, `session_revoke_reason`) и OpenAPI (`amr`) этой миграцией не меняются —
-- расхождение записано в docs/stages/E_spec_questions.md (EQ-AUTH-*), владельцы — 07/08.

BEGIN;

-- 1. Области счётчиков лимитов (07 §5.12; DQ-01).
DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'rate_limit_counters_scope_chk' AND conrelid = 'public.rate_limit_counters'::regclass;
  IF def IS NULL OR position('admin_user_1m' IN def) = 0 THEN
    ALTER TABLE rate_limit_counters DROP CONSTRAINT IF EXISTS rate_limit_counters_scope_chk;
    ALTER TABLE rate_limit_counters ADD CONSTRAINT rate_limit_counters_scope_chk CHECK (scope IN (
      'otp_phone_15m','otp_phone_24h','otp_ip_1h','otp_device_24h','login_ip_1h','step_up_user_1h','webhook_ip_1m',
      'otp_ip_10m','otp_ip_24h','otp_device_10m','otp_global_1m','otp_verify_ip_10m','pin_user_device_10m',
      'admin_user_1m'));
  END IF;
END $$;

-- 2. amr сессии: + admin_code (09 §6.13 п. 3; DQ-02).
DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'sessions_amr_chk' AND conrelid = 'public.sessions'::regclass;
  IF def IS NULL OR position('admin_code' IN def) = 0 THEN
    ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_amr_chk;
    ALTER TABLE sessions ADD CONSTRAINT sessions_amr_chk CHECK (amr <@ ARRAY['sms','pin','bio','admin_code']);
  END IF;
END $$;

-- 3. Причина отзыва: + refresh_replay (09 §8.3, §17 п. 19(а); DQ-03).
DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'sessions_revoke_reason_chk' AND conrelid = 'public.sessions'::regclass;
  IF def IS NULL OR position('refresh_replay' IN def) = 0 THEN
    ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_revoke_reason_chk;
    ALTER TABLE sessions ADD CONSTRAINT sessions_revoke_reason_chk CHECK (revoke_reason IN (
      'logout','logout_all','reuse_detected','admin','phone_changed','role_changed','expired','device_revoked',
      'blocked','session_limit','device_mismatch','biometric_invalidated','refresh_replay'));
  END IF;
END $$;

-- 4. otp_challenges (07 §5.11; DQ-03).
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS issued_by_user_id uuid;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS locked_at timestamptz;
ALTER TABLE otp_challenges ADD COLUMN IF NOT EXISTS issued_jti uuid;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'otp_challenges_issued_by_user_id_fk'
                    AND conrelid = 'public.otp_challenges'::regclass) THEN
    ALTER TABLE otp_challenges ADD CONSTRAINT otp_challenges_issued_by_user_id_fk FOREIGN KEY (issued_by_user_id)
      REFERENCES users(id) ON DELETE RESTRICT ON UPDATE RESTRICT;
  END IF;
  -- Аварийный код (09 §6.13 п. 3) — только челлендж входа, доставляемый не по SMS.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'otp_challenges_issued_by_chk'
                    AND conrelid = 'public.otp_challenges'::regclass) THEN
    ALTER TABLE otp_challenges ADD CONSTRAINT otp_challenges_issued_by_chk
      CHECK (issued_by_user_id IS NULL OR (purpose = 'login_or_register' AND sms_outbox_id IS NULL));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS otp_challenges_issued_by_idx ON otp_challenges (issued_by_user_id)
  WHERE issued_by_user_id IS NOT NULL;

-- Заполнение для кодов, выданных до 0003: отметка — в записи аудита выдачи (append-only, та же транзакция).
UPDATE otp_challenges c
   SET issued_by_user_id = a.actor_user_id
  FROM audit_logs a
 WHERE c.issued_by_user_id IS NULL
   AND c.sms_outbox_id IS NULL
   AND c.purpose = 'login_or_register'
   AND a.action = 'auth.emergency_code.issued'
   AND a.entity_type = 'user'
   AND a.entity_id = c.user_id
   AND a.actor_user_id IS NOT NULL
   AND a.after ->> 'challengeId' = c.id::text;

-- Сессии входа по аварийному коду, созданные до 0003 (в `amr` записан `sms`, признак — челлендж администратора).
UPDATE sessions s
   SET amr = array_replace(s.amr, 'sms', 'admin_code')
  FROM otp_challenges c
 WHERE s.created_from_challenge_id = c.id
   AND c.issued_by_user_id IS NOT NULL
   AND 'sms' = ANY (s.amr)
   AND NOT ('admin_code' = ANY (s.amr));

-- Заблокированные до 0003 коды: момент блокировки неизвестен — последнее изменение строки (верхняя оценка).
UPDATE otp_challenges SET locked_at = updated_at WHERE status = 'locked' AND locked_at IS NULL;

-- 5. sms_outbox.request_id (11 SEC-064; SMS-Q-06).
ALTER TABLE sms_outbox ADD COLUMN IF NOT EXISTS request_id text;

COMMIT;

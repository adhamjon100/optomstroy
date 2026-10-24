-- 0011_payments.sql — платежи этапа F (RM-F-003, RM-F-016, RM-F-012; агент F-be-payments).
--
-- 1. Номер платежа `PAY-YYYY-NNNNNN` (07 §5.40, CHECK `payments_public_number_chk`): в 0001 последовательности для
--    номера платежа нет (FQ-BASE-01). `payments_number_seq` + функция `next_payment_public_number()`: год — по
--    часовому поясу магазина (Asia/Bishkek), шесть цифр — остаток номера по модулю 10^6; занятый номер (например,
--    записанный тестовым стендом или после переполнения) пропускается — UNIQUE `payments_public_number_uq` не
--    нарушается.
-- 2. `payments.qr_issued_at` — момент выдачи показанного QR (`QrInfo.issuedAt`, 08 §3.10 — обязательное поле
--    схемы): в 07 §5.40 столбца нет, `qr_status_checked_at` означает момент опроса статуса (FQ-PAY-01).
-- 3. `pg_notify('payments_status', <payments.id>)` при смене `payments.status` (триггер AFTER UPDATE OF status):
--    long-polling `GET /payments/{id}?wait=` (08 API-088) просыпается при переходе, выполненном любым процессом
--    (pos-api, pos-worker — опрос QR у 1С), уведомление доставляется только после COMMIT.
--
-- Expand-only, идемпотентно (IF NOT EXISTS / CREATE OR REPLACE): повторное применение — 0 изменений.

BEGIN;

-- 1. Номер платежа.
CREATE SEQUENCE IF NOT EXISTS payments_number_seq;

CREATE OR REPLACE FUNCTION next_payment_public_number(p_at timestamptz DEFAULT now()) RETURNS text
  LANGUAGE plpgsql VOLATILE AS $$
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
END $$;

-- 2. Момент выдачи QR.
ALTER TABLE payments ADD COLUMN IF NOT EXISTS qr_issued_at timestamptz;

-- 3. Уведомление о смене статуса платежа (long-polling).
CREATE OR REPLACE FUNCTION payments_notify_status() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('payments_status', NEW.id::text);
  RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER trg_payments_notify_status AFTER UPDATE OF status ON payments
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION payments_notify_status();

-- Права роли приложения (0001: ALTER DEFAULT PRIVILEGES действует только для объектов роли pos_migrate).
GRANT USAGE, SELECT ON SEQUENCE payments_number_seq TO pos_app;
GRANT SELECT ON SEQUENCE payments_number_seq TO pos_backup;
GRANT EXECUTE ON FUNCTION next_payment_public_number(timestamptz) TO pos_app;

COMMIT;

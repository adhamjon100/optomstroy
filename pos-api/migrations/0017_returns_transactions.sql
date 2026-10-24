-- 0017_returns_transactions.sql — заявки на возврат и журнал операций этапа G (RM-G-004, RM-G-005; агент G-be-txn-returns).
--
-- 1. Номер заявки на возврат `RET-YYYY-NNNNNN` (07 §5.45, CHECK `return_requests_public_number_chk`): в 0001 нет
--    последовательности и функции номера (как у платежей — 0011, FQ-BASE-01). `return_requests_number_seq` +
--    `next_return_public_number()`: год — по часовому поясу магазина (Asia/Bishkek), шесть цифр — остаток номера по
--    модулю 10^6; занятый номер пропускается — UNIQUE `return_requests_public_number_uq` не нарушается.
-- 2. Индекс автора заявки `(created_by_user_id, created_at DESC)`: object-level правило 11 SEC-030 (г) (кассир видит
--    и меняет свои черновики) и фильтр списка `GET /returns` (08 §4.15.2).
-- 3. Индекс журнала операций по сумме `(amount DESC, id DESC)` для сортировки `GET /transactions?sort=amount:desc`
--    (08 §4.14.1, keyset — 08 §2.5: последний ключ сортировки `id` в направлении сортировки).
--
-- Expand-only (forward-only, 07 §13), идемпотентно (IF NOT EXISTS / CREATE OR REPLACE): повторное применение — 0 изменений.

BEGIN;

-- 1. Номер заявки на возврат.
CREATE SEQUENCE IF NOT EXISTS return_requests_number_seq;

CREATE OR REPLACE FUNCTION next_return_public_number(p_at timestamptz DEFAULT now()) RETURNS text
  LANGUAGE plpgsql VOLATILE AS $$
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
END $$;

GRANT USAGE, SELECT ON SEQUENCE return_requests_number_seq TO pos_app;
GRANT SELECT ON SEQUENCE return_requests_number_seq TO pos_backup;
GRANT EXECUTE ON FUNCTION next_return_public_number(timestamptz) TO pos_app;

-- 2. Автор заявки (SEC-030 (г), фильтр списка).
CREATE INDEX IF NOT EXISTS return_requests_author_created_idx ON return_requests (created_by_user_id, created_at DESC);

-- 3. Сортировка журнала по сумме.
CREATE INDEX IF NOT EXISTS transactions_amount_idx ON transactions (amount DESC, id DESC);

COMMIT;

-- 0013_sync_error_code_qr_paid_after_void.sql — код журнала синхронизации QR_PAID_AFTER_VOID (закрытие этапа F, ADR-103).
--
-- Основание: 05 §6.7.3 и SYNC-078 (оплата QR после аннулирования платежа — `sync_errors` с кодом QR_PAID_AFTER_VOID);
-- 07 §5.53 «Код QR_PAID_AFTER_VOID» (FIX-F-06): «Добавление кода в CHECK и в SyncErrorCode контракта — одним изменением
-- (expand + MINOR)»; словарь — 07 §6.1.1 (15 кодов), 08 §2.4 «Коды журнала синхронизации»; contracts/enums.json 1.2.0
-- (`checkLists.sync_error_code`), OpenAPI 1.2.0 (`SyncErrorCode`). Бизнес-правила не меняются.
--
-- Expand-only (forward-only, 07 §13): CHECK трёх столбцов пересоздаётся с прежними 14 значениями и новым кодом;
-- существующие строки (в т. ч. `error_code = 'OTHER'` с `payload.code = 'QR_PAID_AFTER_VOID'`) остаются допустимыми,
-- код до перехода на новое значение продолжает работать. Порядок значений в CHECK не значим.
-- Идемпотентно: CHECK пересоздаётся, только если в нём ещё нет нового кода (повторное применение — 0 изменений).
-- `last_error_code` по-прежнему допускает NULL (`… IN (…) OR last_error_code IS NULL`, 07 §5.55, §5.64).

BEGIN;

DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'sync_errors_error_code_chk' AND conrelid = 'public.sync_errors'::regclass;
  IF def IS NULL OR position('QR_PAID_AFTER_VOID' IN def) = 0 THEN
    ALTER TABLE sync_errors DROP CONSTRAINT IF EXISTS sync_errors_error_code_chk;
    ALTER TABLE sync_errors ADD CONSTRAINT sync_errors_error_code_chk CHECK (error_code IN (
      'NOT_FOUND_LOCAL','BARCODE_CONFLICT','VALIDATION','ONEC_REJECTED','ONEC_UNAVAILABLE',
      'IMAGE_DOWNLOAD','HASH_MISMATCH','COUNT_MISMATCH','DUPLICATE_SUSPECTED','OUTBOX_UNCONFIRMED',
      'PAYMENT_DOC_VOIDED','ORDER_MATCH_AMBIGUOUS','NO_WRITE_CHANNEL','QR_PAID_AFTER_VOID','OTHER'));
  END IF;
END $$;

DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'onec_outbox_last_error_code_chk' AND conrelid = 'public.onec_outbox'::regclass;
  IF def IS NULL OR position('QR_PAID_AFTER_VOID' IN def) = 0 THEN
    ALTER TABLE onec_outbox DROP CONSTRAINT IF EXISTS onec_outbox_last_error_code_chk;
    ALTER TABLE onec_outbox ADD CONSTRAINT onec_outbox_last_error_code_chk CHECK (last_error_code IN (
      'NOT_FOUND_LOCAL','BARCODE_CONFLICT','VALIDATION','ONEC_REJECTED','ONEC_UNAVAILABLE',
      'IMAGE_DOWNLOAD','HASH_MISMATCH','COUNT_MISMATCH','DUPLICATE_SUSPECTED','OUTBOX_UNCONFIRMED',
      'PAYMENT_DOC_VOIDED','ORDER_MATCH_AMBIGUOUS','NO_WRITE_CHANNEL','QR_PAID_AFTER_VOID','OTHER') OR last_error_code IS NULL);
  END IF;
END $$;

DO $$
DECLARE
  def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO def
    FROM pg_constraint
   WHERE conname = 'sync_node_state_last_error_code_chk' AND conrelid = 'public.sync_node_state'::regclass;
  IF def IS NULL OR position('QR_PAID_AFTER_VOID' IN def) = 0 THEN
    ALTER TABLE sync_node_state DROP CONSTRAINT IF EXISTS sync_node_state_last_error_code_chk;
    ALTER TABLE sync_node_state ADD CONSTRAINT sync_node_state_last_error_code_chk CHECK (last_error_code IN (
      'NOT_FOUND_LOCAL','BARCODE_CONFLICT','VALIDATION','ONEC_REJECTED','ONEC_UNAVAILABLE',
      'IMAGE_DOWNLOAD','HASH_MISMATCH','COUNT_MISMATCH','DUPLICATE_SUSPECTED','OUTBOX_UNCONFIRMED',
      'PAYMENT_DOC_VOIDED','ORDER_MATCH_AMBIGUOUS','NO_WRITE_CHANNEL','QR_PAID_AFTER_VOID','OTHER') OR last_error_code IS NULL);
  END IF;
END $$;

COMMIT;

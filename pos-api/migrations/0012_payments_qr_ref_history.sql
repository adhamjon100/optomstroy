-- 0012_payments_qr_ref_history.sql — история референсов QR платежа (этап F, ревью F-orders-1c-5; 10 PAY-025).
--
-- 10 PAY-025: «предыдущие референсы сохраняются в истории платежа …; поступление по референсу, заменённому
-- перевыпуском, сопоставляется с тем же payment_id по истории референсов и разбирается как late_payment». В 07 §5.40
-- столбца для истории нет (`qr_provider_ref` при перевыпуске заменяется) — вопрос владельцу 07 (F_spec_questions,
-- FIX-F-05). Expand-only: столбец с пустым массивом по умолчанию, существующие строки не меняются.
--
-- Идемпотентно (IF NOT EXISTS): повторное применение — 0 изменений.

BEGIN;

ALTER TABLE payments ADD COLUMN IF NOT EXISTS qr_ref_history text[] NOT NULL DEFAULT '{}'::text[];

COMMIT;

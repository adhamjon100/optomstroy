-- 0009_cart.sql — корзина этапа F (RM-F-001, RM-F-012, RM-F-015; агент F-be-cart).
--
-- 1. Получатель корзины `Cart.receiver` (08 §3.8, §4.7.4: `POST /cart/customer {customerId, receiver}` возвращает
--    `Cart.receiver {kind, name, phone}`): в карточке 07 §5.35 полей получателя у `carts` нет, у `orders` они есть
--    (`receiver_kind`, `receiver_name`, `receiver_phone_e164`, CHECK `orders_receiver_chk`). Столбцы повторяют
--    ограничения `orders` (тот же enum `receiver_kind`, телефон E.164 +996, «другой человек» — имя и телефон
--    обязательны). Вопрос владельцу 07 — FQ-CART-01 (docs/stages/F_spec_questions.md).
-- 2. Причина подтверждения скидки сверх лимита `discount_override_reason` (08 §4.7.5 `override.reason`; 10 DISC-010:
--    «сервер записывает approved_by_user_id, причину, audit_logs и transactions.kind=discount_override»): у `carts`
--    есть `discount_approved_by_user_id`/`discount_approved_at`, причины нет, а запись `transactions` создаётся при
--    создании заказа (модуль orders) — причина должна дожить до `POST /orders`. ≤ 500 символов (08 §2.14 `reason`).
--
-- Expand-only, идемпотентно (ADD COLUMN IF NOT EXISTS, охранные DO-блоки): повторное применение — 0 изменений.

BEGIN;

ALTER TABLE carts ADD COLUMN IF NOT EXISTS receiver_kind receiver_kind NOT NULL DEFAULT 'customer';
ALTER TABLE carts ADD COLUMN IF NOT EXISTS receiver_name text;
ALTER TABLE carts ADD COLUMN IF NOT EXISTS receiver_phone_e164 text;
ALTER TABLE carts ADD COLUMN IF NOT EXISTS discount_override_reason text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'carts_receiver_name_chk' AND conrelid = 'public.carts'::regclass) THEN
    ALTER TABLE carts ADD CONSTRAINT carts_receiver_name_chk CHECK (length(receiver_name) <= 150);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'carts_receiver_phone_e164_chk' AND conrelid = 'public.carts'::regclass) THEN
    ALTER TABLE carts ADD CONSTRAINT carts_receiver_phone_e164_chk CHECK (receiver_phone_e164 ~ '^\+996[0-9]{9}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'carts_receiver_chk' AND conrelid = 'public.carts'::regclass) THEN
    ALTER TABLE carts ADD CONSTRAINT carts_receiver_chk
      CHECK (receiver_kind = 'customer' OR (receiver_name IS NOT NULL AND receiver_phone_e164 IS NOT NULL));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'carts_discount_override_reason_chk' AND conrelid = 'public.carts'::regclass) THEN
    ALTER TABLE carts ADD CONSTRAINT carts_discount_override_reason_chk CHECK (length(discount_override_reason) <= 500);
  END IF;
END $$;

COMMENT ON COLUMN carts.receiver_kind IS 'Получатель корзины (08 Cart.receiver.kind); переносится в orders.receiver_kind при POST /orders';
COMMENT ON COLUMN carts.discount_override_reason IS 'Причина скидки сверх лимита (08 §4.7.5 override.reason; 10 DISC-010)';

COMMIT;

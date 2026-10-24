-- seeds/0001_defaults.sql — RM-C-006: системные строки по умолчанию (07 §15 «порядок первичного применения»,
-- DATA-278). Роли, permissions и role_permissions — migrations/0002_rbac_seed.sql (RM-B-008), здесь не повторяются.
--
-- Применяет `node dist/migrate.js --seed` (src/db/migrator.ts → seed()): одна транзакция, SET LOCAL
-- app.system = 'migration' (аудит без актора пишется с severity info), параметры — GUC app.seed_<имя>.
-- Идемпотентно: каждая вставка — ON CONFLICT DO NOTHING; существующие значения НЕ перезаписываются
-- (их меняет администратор через /admin/settings со step-up). Повторный запуск — 0 вставок (AC-DATA-278).
--
-- Пометки: [НЕ ПОДТВЕРЖДЕНО: Q-NNN] — значение по рекомендуемому допущению ТЗ до ответа заказчика;
-- [ТИПОВО] — заглушка до первой синхронизации с 1С.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. app_settings — ровно ключи ядра R0 §17.7 + customer_stock_display (ядро v1.9 §24.2).
--    Типы и значения по умолчанию — 08 §4.18.6 (таблица соответствия ключей) и 07 §5.59.
--    JSON null = «не задано»: действует env (min_app_version → MIN_APP_VERSION, sync_interval.<entity> →
--    SYNC_*_CRON), так же читает AppVersionPolicy (null/'' → env). recommended_app_version по умолчанию не
--    создаётся (13 RM-C-006: значение берётся из env RECOMMENDED_APP_VERSION). Прочие ключи 07 §5.59
--    (otp.*, consent_texts, support_contacts, …) создаются задачами-потребителями, не этим seed.
-- ---------------------------------------------------------------------------------------------------------------
INSERT INTO app_settings (key, value, value_type, description_ru) VALUES
  ('low_stock_threshold', '5', 'integer',
   'Порог «мало» в базовых единицах (stockLevel=low) [НЕ ПОДТВЕРЖДЕНО: Q-021]'),
  ('cart_stale_minutes', '15', 'integer',
   'Возраст снимка цен/остатков корзины, после которого показывается баннер «данные устарели», мин (10 CART-016) [НЕ ПОДТВЕРЖДЕНО: Q-020]'),
  ('parked_cart_ttl_days', '7', 'integer',
   'Срок хранения отложенной корзины, дней (10 CART-033) [НЕ ПОДТВЕРЖДЕНО: Q-141]'),
  ('overpay_allowed', 'false', 'boolean',
   'Допуск переплаты долга (10 PAY-002) [НЕ ПОДТВЕРЖДЕНО: Q-173]'),
  ('return_approval_threshold', '{"amount": "10000.00", "currency": "KGS"}', 'money',
   'Сумма заявки на возврат, выше которой нужно подтверждение senior_seller/admin (ядро §20.2 п. 11) [НЕ ПОДТВЕРЖДЕНО: Q-174, Q-144]'),
  ('returns_enabled', 'true', 'boolean',
   'Заявки на возврат из приложения включены (ядро v1.6 §21 п. 1; передача в 1С — env RETURNS_FROM_POS_ENABLED) [НЕ ПОДТВЕРЖДЕНО: Q-018]'),
  ('cash_rounding', '"none"', 'string',
   'Округление наличных: none | to_som (10 MNY-005) [НЕ ПОДТВЕРЖДЕНО: Q-016]'),
  ('delivery_slots', '[]', 'json',
   'Интервалы доставки [{"from":"HH:MM","to":"HH:MM"}]; заполняет администратор'),
  ('receivables.max_age_minutes',
   to_jsonb(coalesce(NULLIF(current_setting('app.seed_receivables_max_age_min', true), '')::integer, 60)), 'integer',
   'Максимальный возраст снимка долга для продажи в долг, мин (D-24; по умолчанию — env RECEIVABLES_MAX_AGE_MIN)'),
  ('min_app_version', 'null', 'string',
   'Минимальная версия приложения по платформам «platform=semver,…» (D-46); null — действует env MIN_APP_VERSION'),
  ('secure_screens', '["SCR-21", "SCR-30", "SCR-32", "SCR-34", "SCR-36", "SCR-37", "SCR-38"]', 'json',
   'Экраны с запретом снимков (02 P-SECURE, 11 SEC-097; по умолчанию защита включена) [НЕ ПОДТВЕРЖДЕНО: Q-181]'),
  ('privacy_contact', 'null', 'string',
   'Контакт по вопросам персональных данных (GET /settings/public); заполняет администратор'),
  ('customer_stock_display', '"status"', 'string',
   'Что видит клиент о наличии: status — только «в наличии / мало / нет», quantity — с количеством (ядро v1.9 §24.2)')
ON CONFLICT DO NOTHING;

-- sync_interval.<entity> — по одному ключу на значение enum sync_entity (07 §6.1; 08 AdminSettingsValues), секунды
-- (60…86400); null — действует расписание env SYNC_*_CRON (D-29, 05 §7.3).
INSERT INTO app_settings (key, value, value_type, description_ru)
SELECT 'sync_interval.' || e::text, 'null'::jsonb, 'integer',
       'Интервал синхронизации «' || e::text || '», сек; null — расписание env SYNC_*_CRON (D-29)'
  FROM unnest(enum_range(NULL::sync_entity)) AS e
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. price_lists — вид цены по умолчанию «Розничная» [ТИПОВО] (07 §5.26: «Розничная», «Оптовая»; is_default —
--    вид цены корзины без клиента и клиента без соглашения, ядро v1.9 §24.2). onec_ref NULL до первой
--    синхронизации видов цен; synced_at/source_hash NOT NULL по карточке — заглушка 'seed:typical'. Связывание
--    с видом цены 1С (по имени) или замена — задача синхронизации (RM-E), Q-121 [НЕ ПОДТВЕРЖДЕНО].
--    Если вид цены по умолчанию уже есть (price_lists_default_uq), строка не вставляется.
-- ---------------------------------------------------------------------------------------------------------------
INSERT INTO price_lists (id, synced_at, source_hash, name, is_default, visible_to_roles, sort_order)
VALUES ('00000000-0000-7000-8000-000000000101', now(), 'seed:typical', 'Розничная', true,
        '{seller,cashier,senior_seller,admin,owner,customer}', 0)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. customers — системный клиент «Розничный покупатель» (Q-026, DATA-167): ровно один (customers_retail_default_uq),
--    без права продажи в долг, вид цены — по умолчанию.
-- ---------------------------------------------------------------------------------------------------------------
INSERT INTO customers (id, source, name, customer_type, is_retail_default, credit_allowed, default_price_list_id,
                       onec_status, comment)
VALUES ('00000000-0000-7000-8000-000000000201', 'pos', 'Розничный покупатель', 'individual', true, false,
        (SELECT id FROM price_lists WHERE is_default AND NOT deletion_mark ORDER BY sort_order, id LIMIT 1),
        'n_a', 'Системный клиент (Q-026): продажа без идентификации покупателя, долг запрещён')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. role_discount_limits — строки для всех ролей (07 §5.34, DATA-278). Значения — предложение Q-015
--    [НЕ ПОДТВЕРЖДЕНО: Q-015]: seller 5, cashier 5, senior_seller 10, admin 15, owner 0; can_approve_over_limit —
--    senior_seller, admin (07 §5.34). customer и integration — 0 (ручные скидки недоступны, ядро v1.9 §24.2).
--    approve_max_percent / requires_reason_over_percent — NULL по карточке (не заданы ТЗ).
-- ---------------------------------------------------------------------------------------------------------------
INSERT INTO role_discount_limits (role, max_percent, can_approve_over_limit) VALUES
  ('seller', 5, false),
  ('cashier', 5, false),
  ('senior_seller', 10, true),
  ('admin', 15, true),
  ('owner', 0, false),
  ('customer', 0, false),
  ('integration', 0, false)
ON CONFLICT DO NOTHING;

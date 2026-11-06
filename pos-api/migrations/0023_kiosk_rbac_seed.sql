-- 0023_kiosk_rbac_seed.sql — дельта seed RBAC: роль `kiosk` планшета магазина и коды №77–81 (P-002 ред. 5,
-- ADR-115 п. 14; задача TAB-1-01, часть «RBAC»).
--
-- Источник: contracts/rbac/permissions.yaml (версия 2), элементы с since: "0023" — проекция 11_SECURITY_PRIVACY
-- §4.2 (роль kiosk), §4.3 (№77–81), §4.4 (колонка kiosk; kiosk.read — admin, owner; kiosk.manage — admin).
-- Таблицы и колонки — 07_DATA_MODEL §5.4 roles, §5.5 permissions, §5.6 role_permissions.
-- Требует 0021_kiosk_enum_values.sql: значение 'kiosk' enum role_code зафиксировано раньше этой транзакции
-- (07 §12.2, DATA-305). Применённая 0002_rbac_seed.sql (7 ролей, 77 кодов, 231 пара) не меняется (07 §12.1,
-- ADR-115 п. 14). role_discount_limits для kiosk не создаётся (лимит 0 — 07 §5.34), app_settings — не здесь.
-- Права kiosk.order.submit, kiosk.self.read, kiosk.self.exit засчитываются только при kind=kiosk — это
-- проверяет код (11 SEC-138), а не seed.
--
-- Идемпотентно: каждая вставка — ON CONFLICT DO NOTHING; повторное применение не меняет данных.
-- Существующие строки не обновляются: изменение состава прав — только новой миграцией (11 SEC-027).
-- Явного BEGIN/COMMIT нет: транзакцию задаёт мигратор (одна транзакция на файл, 07 §12.1).
-- СГЕНЕРИРОВАНО scripts/gen_rbac_seed.py из permissions.yaml — вручную не править (B-AR-10);
-- проверка дрейфа — gen_rbac_seed.py --check, сверка с 11 и OpenAPI — scripts/check_api_permissions.py.

-- 1. Роли (07 §5.4; 11 §4.2): kiosk — sort_order по порядку enum role_code (07 §14.2).
--    Вручную не назначаются (is_assignable=false): kiosk.
INSERT INTO roles (code, name_ru, is_system, is_assignable, sort_order) VALUES
  ('kiosk'::role_code, 'Планшет магазина', true, false, 8)
ON CONFLICT DO NOTHING;

-- 2. Словарь permissions (07 §5.5): коды 11 §4.3 №77–81 (кодов: 5), requires_step_up = «S!» колонки Step-up.
INSERT INTO permissions (code, description_ru, requires_step_up) VALUES
  ('kiosk.read', 'Планшеты магазина: список (GET /admin/store-tablets) — имя, склад, статус, последняя связь, закрепление, версия приложения, срок подключения; без токенов и аварийного кода', false),
  ('kiosk.manage', 'Планшеты магазина: подключение текущего устройства (POST /admin/store-tablets), изменение имени и склада (PATCH /admin/store-tablets/{id}), отключение (POST /admin/store-tablets/{id}/revoke), подключение заново (POST /admin/store-tablets/{id}/reconnect); только admin', true),
  ('kiosk.order.submit', 'Планшет магазина: код для заявки (POST /kiosk/order-otp), заявка (POST /kiosk/orders), восстановление по ключу (GET /kiosk/orders?idempotencyKey=); вместе с cart.manage.own — сброс корзины (POST /kiosk/reset) и предпросмотр (POST /cart/checkout-preview вместо order.create); засчитывается только при kind=kiosk (SEC-138)', false),
  ('kiosk.self.read', 'Планшет магазина: GET /me в форме планшета (kind, tablet — id, имя, склад) без ПДн (SEC-141); засчитывается только при kind=kiosk (SEC-138)', false),
  ('kiosk.self.exit', 'Планшет магазина: аварийный выход со связью (POST /kiosk/exit, SEC-140); засчитывается только при kind=kiosk (SEC-138)', false)
ON CONFLICT DO NOTHING;

-- 3. Матрица роль × право (07 §5.6; 11 §4.4), пар: 12 — admin: 2, owner: 1, kiosk: 9.
--    constraint_json — как в 0002 ({"own": true}, {"maxPercentFrom": …}); прочие условия — в коде (NOTES.md).
INSERT INTO role_permissions (role_id, permission_id, constraint_json)
SELECT r.id, p.id, g.constraint_json
FROM (VALUES
  ('admin', 'kiosk.read', NULL::jsonb),
  ('admin', 'kiosk.manage', NULL::jsonb),
  ('owner', 'kiosk.read', NULL::jsonb),
  ('kiosk', 'catalog.read', NULL::jsonb),
  ('kiosk', 'catalog.prices.read', NULL::jsonb),
  ('kiosk', 'inventory.read', NULL::jsonb),
  ('kiosk', 'search.read', NULL::jsonb),
  ('kiosk', 'cart.manage.own', NULL::jsonb),
  ('kiosk', 'settings.public.read', NULL::jsonb),
  ('kiosk', 'kiosk.order.submit', NULL::jsonb),
  ('kiosk', 'kiosk.self.read', NULL::jsonb),
  ('kiosk', 'kiosk.self.exit', NULL::jsonb)
) AS g (role_code, permission_code, constraint_json)
JOIN roles r ON r.code = g.role_code::role_code
JOIN permissions p ON p.code = g.permission_code
ON CONFLICT DO NOTHING;

-- 4. Контроль: роли (1), коды (5) и пары (12) этой миграции присутствуют — опечатка
--    в коде или роли в VALUES иначе молча выпала бы из JOIN. Проверяется только «ожидаемое ⊆ фактическое»: строки
--    0002 и следующих миграций не мешают. Итог после миграции: ролей 8, кодов 82, пар 243.
DO $$
DECLARE
  missing_roles integer := 0;
  missing_perms integer := 0;
  missing_pairs integer := 0;
BEGIN
  SELECT count(*) INTO missing_roles
  FROM unnest(ARRAY['kiosk']) AS e(code)
  WHERE NOT EXISTS (SELECT 1 FROM roles r WHERE r.code::text = e.code);

  SELECT count(*) INTO missing_perms
  FROM unnest(ARRAY[
    'kiosk.read',
    'kiosk.manage',
    'kiosk.order.submit',
    'kiosk.self.read',
    'kiosk.self.exit'
  ]) AS e(code)
  WHERE NOT EXISTS (SELECT 1 FROM permissions p WHERE p.code = e.code);

  SELECT count(*) INTO missing_pairs
  FROM (VALUES
    ('admin', 'kiosk.read'),
    ('admin', 'kiosk.manage'),
    ('owner', 'kiosk.read'),
    ('kiosk', 'catalog.read'),
    ('kiosk', 'catalog.prices.read'),
    ('kiosk', 'inventory.read'),
    ('kiosk', 'search.read'),
    ('kiosk', 'cart.manage.own'),
    ('kiosk', 'settings.public.read'),
    ('kiosk', 'kiosk.order.submit'),
    ('kiosk', 'kiosk.self.read'),
    ('kiosk', 'kiosk.self.exit')
  ) AS e(role_code, permission_code)
  WHERE NOT EXISTS (
    SELECT 1 FROM role_permissions rp
    JOIN roles r ON r.id = rp.role_id
    JOIN permissions p ON p.id = rp.permission_id
    WHERE r.code::text = e.role_code AND p.code = e.permission_code);

  IF missing_roles > 0 OR missing_perms > 0 OR missing_pairs > 0 THEN
    RAISE EXCEPTION 'rbac seed 0023 incomplete: % roles, % permissions, % role_permissions pairs missing',
      missing_roles, missing_perms, missing_pairs;
  END IF;
END $$;

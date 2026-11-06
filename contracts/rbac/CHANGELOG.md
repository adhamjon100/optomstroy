# CHANGELOG — матрица прав RBAC (`contracts/rbac/permissions.yaml`)

Формат — по [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/); версия — поле `version` в `permissions.yaml`
(целое число: повышается при каждом изменении ролей, словаря кодов, `grants`, `constraints` или `pseudo_sets`).
Шаг 16 CI (`contracts-lint`, 13 §5.3 п. 2; `.github/workflows/ci.yml`) требует запись с новой версией при каждом
изменении `permissions.yaml`. Порядок правки — `NOTES.md` §2 п. 18–19: сначала документ-владелец (11 §4.1–§4.4, имена
ролей — 07 §5.4, enum `role_code` — 07 §14.2), затем `permissions.yaml`, генерация seed
`python -I -X utf8 scripts/gen_rbac_seed.py` и `cd pos-api && npm run gen:permissions`
(`pos-api/src/common/rbac/permissions.generated.ts`), сверка `python -I -X utf8 scripts/check_api_permissions.py`.
Применённые seed-миграции не перегенерируются (07 §12.1 forward-only): новые роли и коды вносит дельта-миграция.

## [2] — 2026-11-04 — режим «Планшет магазина» (P-002, ADR-115)

Основание — P-002 «Планшет магазина» редакции 5, утверждено владельцем 2026-11-04 («P-002 утверждаю, делай»;
группа А — «Да, все рекомендации (Рекоменд.)», в пояснении — «Р-01 а»); решение — ADR-115 п. 13, п. 14 (15). Проекция —
11 v1.4 §4.1 п. 7, §4.2, §4.3 (№77–81), §4.3.1, §4.4 (колонка `kiosk`); имя роли — 07 §5.4, значение enum `role_code` —
07 §14.2 и миграция `pos-api/migrations/0021_kiosk_enum_values.sql`. Seed — новая дельта-миграция
`pos-api/migrations/0023_kiosk_rbac_seed.sql` (генерируется из элементов с `since: "0023"`); применённая
`0002_rbac_seed.sql` не изменилась байт-в-байт (7 ролей, 77 кодов, 231 пара). Итог: 8 ролей, 82 кода, 243 пары.
Удалённых и переименованных ролей и кодов нет, прежние `grants` не менялись — только добавления.

### Добавлено

- `roles`: `kiosk` — «Планшет магазина», `is_system: true`, `is_assignable: false`, `sort_order: 8` (технический
  пользователь планшета `users.kind='kiosk'`; создаётся только `POST /admin/store-tablets`, SEC-136, SEC-142; роль вне
  закрытого перечня ядра §3.1 — отступление по решению владельца, Р-01 (а), ADR-115).
- `permissions` (модуль `kiosk`, номера 11 §4.3): №77 `kiosk.read`; №78 `kiosk.manage` (`step_up: true`,
  `step_up_scope: admin_users`, `step_up_note` — без step-up только изменение имени и склада); №79 `kiosk.order.submit`;
  №80 `kiosk.self.read`; №81 `kiosk.self.exit`. Кодов с `step_up` — 24 (было 23).
- `grants`:
  - `admin` + `kiosk.read`, `kiosk.manage`; `owner` + `kiosk.read` (только просмотр);
  - `kiosk` (новая роль, 9 кодов): `catalog.read`, `catalog.prices.read`, `inventory.read`, `search.read`,
    `cart.manage.own`, `settings.public.read`, `kiosk.order.submit`, `kiosk.self.read`, `kiosk.self.exit` — без
    `order.create`, `profile.manage.own`, `session.manage.own` (SEC-138); `kiosk.order.submit` и `kiosk.self.*`
    засчитываются только при `kind=kiosk` — это проверяет код (`RbacGuard`, SEC-138), а не seed.
  - Видимость заявок с планшета — по Р-12 (а) через существующий `order.read.all`; новых прав `seller` и прочим ролям
    не выдано.
- `constraints`: `kiosk: {}`.
- Ключ `since: "NNNN"` у ролей и кодов — номер seed-миграции, которая вносит элемент (без `since` — `0002`); пара
  `grants` относится к миграции позднейшего из двух концов (`NOTES.md` §2 п. 19).

### Изменено

- `version` 1 → 2; шапка файла — ссылки на дельта-миграцию и генератор.
- `scripts/gen_rbac_seed.py` генерирует `0002_rbac_seed.sql` (без изменений, файл заморожен) и дельты из таблицы
  `DELTAS` (`0023_kiosk_rbac_seed.sql`); `--check` сверяет все файлы; запись — атомарно (временный файл без суффикса
  `.sql`, затем rename).
- `scripts/check_api_permissions.py`: 82 кода; `is_assignable=false` — `customer`, `integration`, `kiosk`; инварианты
  роли `kiosk` (блок D); блок E сверяет каждый seed-файл RBAC и их объединение с yaml.

## [1] — 2026-10-21 — первая версия (RM-B-008, B-AR-10 (а))

*Запись восстановлена при создании файла (2026-11-04) по `NOTES.md`, `docs/stages/B_architecture_report.md` и
`pos-api/migrations/0002_rbac_seed.sql`; содержимое версии 1 совпадает с этим seed.*

### Добавлено

- 7 ролей ядра D-15 (`seller`, `cashier`, `senior_seller`, `admin`, `owner`, `customer`, `integration`;
  `is_assignable: false` — `customer`, `integration`), словарь 11 §4.3 — 77 кодов (№1–76 и 42a, 23 с `step_up`),
  матрица 11 §4.4 — 231 пара, `constraints` (`own`, `maxPercentFrom`), псевдо-набор `pending_activation`.
- Seed `pos-api/migrations/0002_rbac_seed.sql` генерируется из файла скриптом `scripts/gen_rbac_seed.py`. На этапе C
  (RM-C-005) из той же версии 1 добавлена генерация `pos-api/src/common/rbac/permissions.generated.ts`
  (`pos-api/scripts/gen-permissions.mjs`); роли, коды и пары версии 1 с тех пор не менялись — `0002_rbac_seed.sql`
  (42 832 байта) совпадает с генерацией из элементов без `since` байт-в-байт.

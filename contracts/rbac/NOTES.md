# Матрица прав RBAC: заметки и решения (RM-B-008)

Каталог `contracts/rbac/` содержит матрицу прав R1 и заметки к ней. Задача RM-B-008 из `docs/specification/13_IMPLEMENTATION_ROADMAP.md` §3.2.

| Файл | Что это |
|---|---|
| `contracts/rbac/permissions.yaml` | роли (`roles`), словарь кодов (`permissions`), матрица роль × право (`grants`), атрибутные ограничители (`constraints`), псевдо-набор `pending_activation` (`pseudo_sets`) |
| `pos-api/migrations/0002_rbac_seed.sql` | seed таблиц `roles`, `permissions`, `role_permissions` (07 §5.4–§5.6) по `permissions.yaml` |
| `scripts/check_api_permissions.py` | сверка: OpenAPI ↔ yaml, yaml ↔ 11 §4.3/§4.4 и 07, yaml ↔ seed |
| `contracts/rbac/NOTES.md` | этот файл |

## 1. Источники и приоритет

- Ядро R0 v1.9 — высший приоритет: §3.1 (роли), §3.3 и §17.2 (step-up, D-15), §21 п.3 (`owner` в админ-разделах), §22.9–§22.13, §23 п.3 и п.8, §24.2 (`customer` входит в R1, `CUSTOMER_SELF_SERVICE=true`).
- Словарь кодов и матрица роль × право — **11_SECURITY_PRIVACY §4.3–§4.4**. Владелец закреплён ядром §18.1. Области step-up — 11 §4.1 п.7. Покрытие эндпоинтов — 11 §4.3.1.
- Таблицы и колонки — 07 §5.4 `roles`, §5.5 `permissions`, §5.6 `role_permissions`. Enum `role_code` — 07 §14.2.
- 08 §3.15 и §9, 12 T-SEC-016 и T-SEC-019 — проекции. Они использовались только для сверки. При расхождении действует 11.

## 2. Решения

1. **Клиенту выдаются «self»-коды вместо staff-кодов финансовых данных и карточки.** В матрице 11 §4.4 в колонке `customer` у пяти строк стоит `own` или `own conf`: `customer.read.basic`, `customer.history.read`, `customer.receivables.read.summary`, `customer.receivables.read.detail`, `customer.link.read`. Эти коды клиенту **не выдаются**. Вместо них клиент получает `customer.self.read` (№61) и `customer.self.receivables.read` (№62). Основания:
   - 11 §4.3.1 прямо переадресует: `GET /customers/{id}` и `GET /customers/{id}/orders` — «`customer` — `customer.self.read`»; `GET /customers/{id}/receivables` — «`customer` — `customer.self.receivables.read`»;
   - строки самой матрицы «Долг: детализация» и «Привязки клиентов: просмотр» называют для клиента self-код;
   - SEC-032 говорит то же самое: «`customer` — `customer.self.receivables.read`/`customer.self.read`».

   Почему не литерально по ячейкам: `customer.receivables.read.summary` открывает и `GET /receivables/overdue` (список всех просрочек), и `overdue[]` дашборда. Ограничение `own` у такого кода держалось бы только на коде фильтра, что противоречит deny by default (11 §4.1 п.1).

   **Владельцу 11** рекомендуется уточнить эти ячейки так: «own conf (через `customer.self.*`)». Так уже записана строка `customer.link.read`. Это же касается проекции 12 T-SEC-016.29/.33/.34/.35. Скрипт сверки знает это решение (`CUSTOMER_REDIRECT`). Если ячейку изменят на «—», он выдаст предупреждение.
2. **Клиенту выдан `order.read.own`.** Ячейка «Чтение заказов» = `own`. 11 §4.3.1 не переадресует `GET /orders` на self-код. Кроме того, отмена (`order.cancel.own`), QR по своему заказу и счёт требуют, чтобы заказ был виден «по `order.read.*`» (11 §4.1 п.8). Расширенный фильтр клиента (созданные аккаунтом + заказы своей карточки при `confirmed`) задаёт SEC-030 (в).
3. **Коды без строки в матрице.** У `customer.self.read` и `customer.self.receivables.read` нет строки в 11 §4.4. По описаниям 11 §4.3 («Клиент-покупатель: …») они выдаются только `customer`.
4. **Особые строки матрицы.** Скрипт переводит их в коды так:
   - «Чтение заказов»: `own` → `order.read.own`, `✓ all` → `order.read.all`;
   - «Транзакции (`transactions.read.*`)»: `own`/`all` → `transactions.read.own`/`.all`;
   - «Чужие отложенные»: → `cart.parked.read.all` + `cart.parked.resume.any`; у `owner` «только чтение» → только `read.all` (так же в 11 §4.3.1);
   - «Настройки приложения (`settings.app.*`)»: `read + update S!` → оба кода, `read` → `settings.app.read`;
   - «Отчёты (`reports.*.read`)»: → три кода отчётов;
   - «Квитанция об оплате долга без заказа» — составная строка без своего кода. Проверяется только условие: при ✓ у роли есть `order.documents.print` и `payment.read.*`. У `seller` и `customer` эти коды есть, а ячейка — «—». Им квитанция недоступна по object-level: платёж долга без заказа создаёт только держатель `payment.debt.receive`, поэтому своих таких платежей у них нет, и ответ — `404` (SEC-030).
5. **`seller` получает `credit.sale.create`.** Ячейка — «✓ (если разрешено Q-017)». Seed следует матрице. Если ответ на Q-017 — «нет», код снимается новой миграцией (11 SEC-027).
6. **`requires_step_up` = колонка «Step-up» 11 §4.3 начинается с `S!`.** Это 23 кода. Если в колонке после `S!` есть уточнение, оно перенесено в `step_up_note`. Так у `payment.void`, `customer.receivables.read.detail`, `customer.link.resolve`, `profile.manage.own`, `session.manage.own`, `users.manage`, `invitations.manage`, `customer.self.receivables.read`. У части из них step-up нужен не на всех операциях кода: `profile.manage.own`, `session.manage.own`, `payment.void` (только ручное аннулирование), `customer.receivables.read.detail` и `customer.self.receivables.read` (первый просмотр / > 15 мин; у №62 — только детализация). Нужен ли step-up конкретной операции, решают `x-step-up` / `x-step-up-operation` OpenAPI (08 §2.12), а не флаг кода. `step_up_scope` взят из таблицы областей 11 §4.1 п.7. Его нет только у `reports.export`: код R2, никому не выдан, а по 11 §4.1 п.7 такой код образует область из одного кода.
7. **`constraint_json` (07 §5.6) — только ключи из примеров 07.**
   - `{"own": true}` — у ячеек `own` (в том числе «✓ own», «S! own») и у self-кодов клиента;
   - `{"maxPercentFrom": "role_discount_limits"}` — у `discount.apply.within_limit` (ячейки `lim`) и `discount.approve.over_limit` («до 10 %/15 %» — «в пределах своего лимита», 11 §4.3 №24).

   Прочие условия матрицы **не кодируются в seed**. Их проверяет `authorize()`, потому что новые ключи JSON в 07 не определены:
   - `conf` — SEC-030 (в);
   - цели админских действий: SEC-040, SEC-043, SEC-131; `owner` для `users.roles.assign`/`session.revoke.any` — только цели `admin`/`owner`, ядро §21 п.3;
   - флаги: `CUSTOMER_SELF_SERVICE`, `QR_PROVIDER=onec` для QR клиента, `returns_enabled`;
   - «при оформлении» для QR у `seller`;
   - порог возврата — 11 §4.1 п.8;
   - DTO по полям — SEC-031.
8. **Роли.**
   - `sort_order` = порядок enum `role_code` (07 §14.2). Значений в ТЗ нет, выбран детерминированный порядок.
   - `is_system=true` у всех ролей.
   - `is_assignable=false` у `customer` и `integration` (07 §5.4).
   - `name_ru` — из 07 §5.4. Для `customer` это «Клиент», в 11 §4.2 — «Клиент-покупатель». Колонка 07 — владелец имени.
   - Строка `integration` в `roles` есть, но пользователям роль не назначается: субъект аутентифицируется токеном `integration_tokens` (07 §5.4, SEC-038).
9. **`pending_activation` — статус, не роль** (11 §4.2). В seed не входит. Фиксированный псевдо-набор guard'а записан в yaml (`pseudo_sets`) для кода и тестов. Скрипт сверяет его с 11 §4.2.
10. **Описания.** `description_ru` = колонка «Описание» 11 §4.3. Из неё убраны markdown-разметка (обратные кавычки, `**`, `\|`) и пометки `[РЕШЕНИЕ: …]`. Остальной текст сохранён.
11. **Идемпотентность seed.**
    - Каждый `INSERT` — `ON CONFLICT DO NOTHING` без указания цели. Он срабатывает на любое уникальное ограничение: `roles_code_uq`, `permissions_code_uq`, PK `role_permissions`.
    - Существующие строки не обновляются. Изменение состава прав — только новой миграцией (SEC-027).
    - Контрольный DO-блок проверяет «ожидаемое ⊆ фактическое»: 7 ролей, 77 кодов, 231 пара. Опечатка в коде иначе молча выпала бы из `JOIN`. Лишние строки ошибкой не считаются, поэтому повтор всех миграций (RM-C-006, `--repeat-strict`) после будущих seed-миграций не сломается.
    - Явного `BEGIN/COMMIT` нет: транзакцию задаёт средство применения (drizzle — одна транзакция на миграцию, 07 §12.1).
12. **Имя файла.** `0002_rbac_seed.sql` — по постановке и 13 RM-B-008. Схема имён 07 §12.1 (`0007_seed_roles_permissions`) — пример. При переходе на drizzle (RM-C-006) файл может быть перенумерован без изменения содержания.
13. **Не входит в seed:** `role_discount_limits` и `app_settings`. 07 §12.1 включает их в порядок первичного seed, но постановка RM-B-008 ограничена тремя таблицами RBAC. Значения лимитов не подтверждены (5/5/10/15 % и `owner` 0 — Q-015). Строка `role_discount_limits` нужна каждой роли с `maxPercentFrom` (`seller`, `cashier`, `senior_seller`, `admin`) до первого `POST /cart/discount`. Это задача seed настроек (RM-C-006 или отдельная миграция).
14. **OpenAPI: имя расширения.** Каноническое — `x-permissions` (массив; решение RM-B-003, `contracts/openapi/NOTES.md` §5 п.1). В постановке RM-B-008 написано `x-permission`. Скрипт читает оба варианта. На `x-permission` он выдаёт предупреждение и считает код так же.
15. **Публичные пути (пустой `x-permissions`):** `/auth/otp/request`, `/auth/otp/verify`, `/auth/otp/challenges/{…}`, `/auth/refresh`, `/auth/unlock`, `/registration/complete`, `/images/{…}/{…}`, `/payments/qr/webhook`, `/integrations/smspro/dlr`, `/health`, `/health/ready`, `/openapi.json`. Источник — 11 §4.3.1 «без access JWT», SEC-013, SEC-019. У них `security: []` или не-Bearer схема (`webhookSignature`). `/openapi.json` может иметь `security: []` вместе с кодом `system.openapi.read`: в `prod` код проверяется.
16. **`x-roles`.** Ошибка — если роль из `x-roles` не держит ни одного кода операции. Если роль держит код, но в `x-roles` её нет, выдаётся предупреждение: это законно для условий из «Примечания» 11 §4.3.1. Например, `GET /catalog/price-lists` — `catalog.prices.read`, «кроме `customer`».
17. **Ключ `number`, а не `no`.** В YAML 1.1 (PyYAML) ключ `no` читается как `false`.
18. **Как поддерживается синхронность.** Источник — только `permissions.yaml`. Seed `pos-api/migrations/0002_rbac_seed.sql` **генерируется** скриптом `scripts/gen_rbac_seed.py` (добавлен по B-AR-10 (а) архитектурной проверки этапа B) и вручную не правится; `gen_rbac_seed.py --check` (код 1 при дрейфе) входит в CI `contracts-lint` (RM-C-011). Генератор проверяет инварианты yaml: порядок ролей = `sort_order` = порядок enum `role_code`, коды grants есть в словаре и идут в порядке 11 §4.3, `reserved` (R2) никому не выдан, ограничители `constraints` — только для выданных кодов. Сверка yaml ↔ 11 §4.3–§4.4 ↔ OpenAPI — по-прежнему `scripts/check_api_permissions.py` (блоки B–E). При изменении матрицы: правка yaml → `gen_rbac_seed.py` → `check_api_permissions.py --require-operations`. Повторная генерация из текущего yaml совпала с прежним seed байт-в-байт, кроме строки шапки о генераторе.

## 3. Замечания к документам (для владельцев; правок в `docs/` не вносилось)

1. **11 §4.4, колонка `customer`.** Ячейки `customer.read.basic`, `customer.history.read`, `customer.receivables.read.summary` и `customer.receivables.read.detail` расходятся по форме с 11 §4.3.1 и SEC-032 (см. §2 п.1). То же в 12 T-SEC-016.29/.33–.35.
2. **08 §9 (`POST /orders`, `POST /orders/{id}/payments`, колонка `customer`):** «QR при `QR_PROVIDER≠none`». У 11 §4.3 №17 и §4.4 — «только при `QR_PROVIDER=onec`» (ядро §24.4). По ядру §18.1 действует 11.
3. **11 §4.4, строка «Квитанция об оплате долга без заказа».** У `seller`/`customer` стоит «—» при наличии обоих кодов. Это правило object-level, а не матрицы (§2 п.4). Его стоит явно записать в 11 §4.3.1.

## 4. Проверки

```sh
python -I -X utf8 scripts/check_api_permissions.py                 # A–E; 0 — без расхождений
python -I -X utf8 scripts/check_api_permissions.py --require-operations   # A падает, если в OpenAPI 0 операций
node tools/pg/run-sql.mjs pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql   # RM-B-008 п.2
node tools/pg/run-sql.mjs --repeat-strict pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql
```

Источник OpenAPI для блока A: `contracts/openapi/pos-api.v1.yaml`, если файл собран. Иначе — объединение `paths` всех `contracts/openapi/parts/*.yaml`.

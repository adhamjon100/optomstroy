# pos-api/migrations — заметки о решениях (RM-B-005, `0001_init.sql`)

Дата: 2026-10-21. Этап B («контракты»), задача RM-B-005 (13_IMPLEMENTATION_ROADMAP §3.2).
Источник истины — `docs/specification/07_DATA_MODEL.md` v1.6: карточки §5, enum-ы §6.1, CHECK-перечни §6.1.1,
автоматы §6.3–§6.5, деньги §7.5, row_version §8.3, аудит §9, поиск §10, DDL §14. Также учтено ядро R0 v1.9 (§6, §17.3,
§22, §24). Если пример DDL §14 расходится с карточкой §5, действует карточка (DATA-285). Здесь записано, как
`0001_init.sql` разрешает неоднозначности ТЗ. ERD — `docs/erd/README.md`, проверка — `scripts/check_tables.sql`.

## 1. Состав и форма файла

1. **64 таблицы и 45 enum-типов.** Это ровно список карточек 07 §5 и таблица 07 §6.1. Имена и порядок значений
   enum-ов совпадают с 07 §6.1. Других таблиц в схеме `public` нет.
2. **Атомарность и идемпотентность.** Файл обёрнут в `BEGIN … COMMIT`, поэтому при ошибке ничего не применяется.
   Все объекты создаются через `IF NOT EXISTS`, `CREATE OR REPLACE` или охранные `DO`-блоки (для enum-ов, FK,
   добавляемых через `ALTER`, конфигурации FTS и constraint-триггера). Повторное применение даёт 0 изменений, что
   нужно для RM-C-006 п. 4: `run-sql.mjs --repeat-strict` → `ИТОГ: 0 изменений`.
3. **Порядок создания.** Расширения → роли → enum-ы → функции → таблицы в порядке FK → циклические FK через
   `ALTER TABLE … ADD CONSTRAINT` → триггеры → аудит → права → seed. Циклы и прямые ссылки закрываются так:
   `users.invitation_id ↔ user_invitations`, `otp_challenges.sms_outbox_id ↔ sms_outbox.otp_challenge_id`,
   `categories.image_id`/`products.primary_image_id`/`product_variants.primary_image_id → product_images`,
   `carts.converted_order_id`/`restored_from_order_id → orders`.
4. **Seed в этой миграции — только `sync_node_state ('pos')`** (07 §14.6, ядро §22.10). Остальные seed-данные
   приходят из других задач:
   - `roles`, `permissions`, `role_permissions` — `0002_rbac_seed.sql` (RM-B-008); совместимость проверена прогоном
     `0001 + 0002`;
   - `sync_state` (`schedule_cron` и `max_age_warning_sec` — `NOT NULL`, значения из env), `app_settings`
     (ключи ядра §17.7, `customer_stock_display = "status"`, `return_approval_threshold = 10000`) и
     `role_discount_limits` — RM-C-006 (13 §3.3).

## 2. `dev_outbox` — только dev/test (отказ закрыт, B-AR-09)

**Обновление 2026-10-22 (RM-C-006 п. 6–7; ревью C-MJ-05).** Перенос выполнен: DDL `dev_outbox` (таблица, индексы,
trigger `updated_at`, права ролей) — в `pos-api/db/migrations-dev/0001_dev_outbox.sql`; в `0001_init.sql` его больше нет
(`grep 'CREATE TABLE.*dev_outbox' pos-api/migrations/*.sql` — 0 совпадений, AC-DATA-169). Мигратор (`src/migrate.ts`)
применяет `db/migrations-dev/` вторым проходом только при `APP_ENV=dev` (журнал `pos_dev.schema_migrations`, схема
`public`/`pos_meta` и `docs/erd/schema_v1.sql` не меняются); в prod-образ каталог не копируется. Раннер `tools/pg` и CI
(psql) применяют файл третьим после 0001/0002 с `app.env=test`. Поведенческие проверки перенесены в
`pos-api/test/sql/check_ddl_behavior.sql`. Текст ниже — история решения этапа B.

Здесь два документа расходятся:
- 13 RM-B-005 п. 2 требует, чтобы `check_tables.sql` нашёл **64** таблицы, включая `dev_outbox` («только dev/test»);
- 07 §5.63 и DATA-169 (владелец схемы) требуют, чтобы таблица жила в отдельной миграции `db/migrations-dev/`,
  а на prod-схеме выполнялось `to_regclass('dev_outbox') IS NULL`.

Решение (с 2026-10-21, по замечанию B-AR-09 архитектурной проверки этапа B): DDL `dev_outbox` остаётся в
`0001_init.sql` внутри `DO`-блока, но условие **инвертировано** — таблица создаётся, **только если** сеанс миграции
явно помечен как dev/test: `current_setting('app.env', true) IN ('dev', 'test')` [НОВОЕ ИМЯ GUC, по аналогии с env
`APP_ENV`, 16 §4.3; пространство `app.*` уже используется в 07 — `app.system`, `app.actor_id`]. Без пометки
(prod, staging, забытый `PGOPTIONS`) таблицы нет — ошибка конфигурации ведёт к безопасному результату.

- dev/CI: мигратор запускается с `PGOPTIONS='-c app.env=test'` (или `dev`); раннер `tools/pg` — `--set app.env=test`.
- `scripts/check_tables.sql` читает тот же параметр: dev/test — 64 таблицы, иначе — 63 и `dev_outbox` обязан
  отсутствовать (иначе ошибка, AC-DATA-169 на уровне схемы).

Проверено фактически (журнал `docs/stages/B_checks.log`, раздел «после исправлений B-AR»): с `--set app.env=test` —
`64 из 64 таблиц (dev/test-схема, dev_outbox есть)`; без параметра — `63 из 63 таблиц (prod-схема, dev_outbox нет)`.

Остаётся на этапе C (RM-C-006): буквальный grep-критерий AC-DATA-169 («миграции prod-образа не содержат
`CREATE TABLE dev_outbox`») этот вариант по-прежнему не выполняет — текст DDL в файле есть, хотя на prod не
исполняется. Полное закрытие — перенос блока в `db/migrations-dev/` по 07 §5.63 (тогда список `check_tables.sql`
для prod — 63 таблицы, согласовать с владельцем 13). Страховка на старте приложения — 11 T-SEC-007.

## 3. Роли и права БД (07 §2.1, §9.4, §14.1)

1. **Роли.** `pos_migrate`, `pos_app`, `pos_readonly`, `pos_backup` создаются (`LOGIN`, без пароля), только если их
   ещё нет. Это кластерные объекты, пароли задаёт эксплуатация (16; `DB_MIGRATOR_PASSWORD_FILE` — RM-C-006). Если
   миграцию выполняет роль без `CREATEROLE`, роли должны быть созданы заранее.
2. **Права выдаются явно на все таблицы и последовательности** (`GRANT … ON ALL TABLES/SEQUENCES`). Одного
   `ALTER DEFAULT PRIVILEGES FOR ROLE pos_migrate` недостаточно: в раннере и в CI объекты создаёт суперпользователь,
   а не `pos_migrate`. Default privileges для `pos_migrate` тоже заданы — они нужны для следующих миграций.
3. **Только INSERT и SELECT:**
   - `audit_logs` — `REVOKE ALL` + `GRANT INSERT, SELECT` + `USAGE` на `audit_logs_chain_seq`;
   - `transactions`, `order_status_history` — `REVOKE UPDATE, DELETE`;
   - `receivable_documents` — `REVOKE DELETE` (06 EVO-007).

   У `pos_app` нет `TRUNCATE` и `CREATE` в `public` (DATA-012).

   Проверено под `SET ROLE pos_app`: `UPDATE audit_logs`, `DELETE transactions` и `DELETE receivable_documents`
   отклоняются, `CREATE TABLE` → `insufficient_privilege`.

## 4. Таблицы и столбцы

1. **Набор полей реплики 1С** (`onec_ref, onec_code, onec_data_version, deletion_mark, synced_at, source_hash`)
   - **Полный набор** у справочников и документов 1С: `units`, `warehouses`, `categories`, `products`,
     `product_variants`, `product_attributes`, `packagings`, `barcodes`, `price_lists`, `customers`, `discount_rules`,
     `shipments`. У `barcodes` поле `onec_ref` всегда NULL — карточка: «поле NULL». У `shipments` `onec_ref NOT NULL`.
   - **`synced_at`/`source_hash` допускают NULL** у `customers` и `discount_rules`: в них есть строки, созданные в POS
     (`source='pos'`). То же у `customer_contacts`: контакты нового клиента вводятся в POS.
   - **Таблицы-срезы и строки регистров получают только поля из своих карточек:**
     - `stock_balances`, `prices` — `synced_at`, `source_hash` (так же в DDL 07 §14.4);
     - `receivables`, `receivable_documents`, `shipment_items` — `synced_at`, `source_hash`;
     - `variant_attribute_values` — `synced_at`, `onec_value_ref`;
     - `customer_contacts` — `onec_line_key`.
   - **`product_images`** использует `source_ref`/`source_version` — так сказано в карточке.
   - **Документы POS** (`orders`, `payments`, `return_requests`, `transactions`) получают только `onec_ref` и свои
     поля `onec_*` из карточек. Так же сделано в DDL §14.5.
   - **Расхождение с DATA-008** («6 полей у всех таблиц с владельцем 1С»): для срезов выбраны карточка и DDL §14.
2. **`created_at`/`updated_at` есть у всех таблиц** (DATA-002), включая таблицы с составным PK. Исключение —
   `audit_logs`: у неё только `created_at`, как в явном DDL 07 §14.7. Триггер `trg_<table>_set_updated_at` создаётся
   циклом по `information_schema` на каждую таблицу, где есть `updated_at`.
3. **Внешние ключи.**
   - Каждый FK — именованное ограничение `<table>_<col>_fk` (07 §2.1) с явным
     `ON DELETE RESTRICT ON UPDATE RESTRICT`.
   - `ON DELETE CASCADE` — ровно у двух FK: `cart_items.cart_id` и `return_request_items.return_request_id`
     (DATA-004). Всего FK 139: 137 RESTRICT и 2 CASCADE.
   - Исключение из правила имени: `carts_restored_from_order_fk` назван как в 07 §14.5.
   - **Столбцы `*_by_user_id` получают FK на `users`**, даже если карточка пишет просто `uuid`: таковы правило 07 §2.1
     и прецедент DDL §14.5. Это `devices.revoked_by_user_id`, `sync_errors.resolved_by_user_id`,
     `integration_tokens.revoked_by_user_id`, `return_requests.approved_by_user_id` и другие. Пользователи физически
     не удаляются, поэтому FK безопасны.
   - **Без FK оставлены столбцы, где это следует из 07:**
     - `orders.cart_id` — 07 §5.37: «без FK»;
     - `order_status_history.sync_run_id` — `sync_runs` удаляются ретенцией через 90 дней;
     - `audit_logs.on_behalf_of_user_id`, `session_id`, `device_id`, `entity_id` — DDL §14.7;
     - `onec_outbox.aggregate_id` — полиморфная ссылка;
     - `*.local_id`, `idempotency_keys.resource_id`, `customer_links.conflict_candidates[]`.
4. **Проценты.** Ко всем столбцам `numeric(5,2)` применено общее правило 07 §2.1 `CHECK (0..100)`, даже если
   карточка его не повторяет: `orders.customer_discount_percent`, `order_items.discount_percent`, поля
   `role_discount_limits`.
5. **Валюта.** `CHECK (currency = 'KGS')` стоит только там, где его требуют 07 §7.5 и §14: `price_lists`, `orders`,
   `payments`, `transactions`. У `receivables` и `shipments` валюта хранится без CHECK, как в карточках.
6. **`product_variants.name_norm`** и GIN-индекс по нему взяты из 07 §10.2: в карточке §5.17 этого столбца нет,
   но в DDL §14.4 он есть.
7. **Значения по умолчанию.** `otp_challenges.status` и `print_jobs.status` объявлены без `DEFAULT`, как в
   карточках: статус задаёт приложение.
8. **Имя столбца `sync_runs."trigger"`** записано в кавычках для надёжности (имя по карточке).
9. **Нумерация документов.** Последовательность из 07 есть только для заказов (`orders_number_seq`, 07 §5.37).
   Источник номеров `PAY-…` и `RET-…` в 07 не задан, поэтому для них последовательностей нет — решается на этапе C
   модулями `payments` и `returns`.

## 5. Индексы

1. **Все индексы и частичные UNIQUE взяты из карточек**, имена — из 07. Частичные `UNIQUE (onec_ref) WHERE onec_ref
   IS NOT NULL` есть у 16 таблиц, у `shipments` UNIQUE полный. Для безымянных UNIQUE имя построено по правилу
   `<table>_<cols>_uq`.
2. **Добавлены индексы `<table>_updated_at_idx`** у реплик каталога, где их не было: `units`, `warehouses`,
   `categories`, `product_variants`, `product_images`, `product_attributes`, `packagings`, `barcodes`, `price_lists`;
   у `variant_attribute_values` — `synced_at`. Основание — DATA-164 («все реплики каталога имеют индекс по
   `synced_at`/`updated_at`»).
3. **Добавлены индексы под FK, которых нет в карточках.** Они нужны для проверки `RESTRICT` при удалении родителя и
   для JOIN: `products(base_unit_id)`, `sessions(device_id)`, `token_denylist(session_id)`,
   `sms_outbox(otp_challenge_id)`, `consents(device_id)`, `product_images(category_id)`, `packagings(unit_id)`,
   `barcodes(packaging_id)`, `stock_balances(warehouse_id)`, `prices(packaging_id)`,
   `customers(default_price_list_id)`, `order_items(packaging_id)`, `shipments(warehouse_id)`,
   `shipment_items(packaging_id)`, `return_requests(order_id)`, `return_request_items(variant_id)`,
   `favorites_customers(customer_id)`, `recent_products(product_id)`, `sync_errors(outbox_id)`,
   `sync_entity_versions(seen_in_run_id)`, `idempotency_keys(user_id)` (частичный `WHERE user_id IS NOT NULL` — после
   B-AR-01 столбец допускает NULL), `dev_outbox(sms_outbox_id)`.
4. **Не созданы индексы из карточек, которые полностью покрывает ведущий столбец PK или UNIQUE.** Так же поступает
   DDL §14: `stock_balances(variant_id)`, `cart_items(cart_id)`, `order_items(order_id)`,
   `shipment_items(shipment_id)`, `return_request_items(return_request_id)`, `print_jobs(order_id)`, отдельный
   `integration_tokens(token_hash)` и `audit_anchors(anchor_date)` — их покрывают UNIQUE.
5. **`users_deleted_phone_hmac_idx` — частичный** (`WHERE deleted_phone_hmac IS NOT NULL`): столбец заполняется
   только после анонимизации.
6. **Поиск (07 §10).**
   - Функции `immutable_unaccent`, `norm_search`, `norm_sku` и конфигурация `public.ru_unaccent`
     (`COPY = russian` + `unaccent, russian_stem`). Generated-столбцы `STORED`, GIN `gin_trgm_ops` и tsvector с
     `fastupdate = off` (07 §10.5), `text_pattern_ops` для префиксов.
   - Проверено на PG 17.10 с локалью `en-US`:
     - `norm_sku('СМ-12 a') = 'СМ12A'` (AC-DATA-115);
     - `show_trgm` для кириллицы не пуст;
     - FTS `смесители` находит «Смеситель для кухни»;
     - триграммы находят запрос с опечаткой.

## 6. Триггеры целостности (07 §5, §7.5, §8.3, §9.2, §14)

1. **`trg_orders_freeze_financials`, `trg_orders_paid_at_once`, `trg_sync_node_state_monotonic`** — дословно по DDL
   07 §14.5–§14.6.
2. **`trg_order_items_freeze`.** После `orders.submitted_at` можно менять только `shipped_quantity`,
   `returned_quantity`, `onec_line_no`, `onec_line_total`; `DELETE` запрещён. Обход — `app.system = 'migration'`,
   по аналогии с `trg_orders_freeze_financials`: в 07 §9.2 обход не оговорён.
3. **`trg_order_items_totals`** — отложенный (`DEFERRABLE INITIALLY DEFERRED`) constraint-триггер. Проверяет
   Σ `line_total` = `orders.total` при `status <> 'draft'` в конце транзакции создания заказа (07 §7.5).
4. **`order_items.line_subtotal`.** Правило 07 «`= round_half_up(unit_price × quantity, 2)` (CHECK через триггер)»
   реализовано обычным CHECK `order_items_line_subtotal_calc_chk` поверх `IMMUTABLE`-функции `round_half_up`.
   Результат тот же, а реализация проще.
5. **`trg_payments_freeze`.** `DELETE` запрещён всегда. После `received` неизменяемы
   `amount/method/order_id/customer_id/received_amount/change_amount` (07 §7.5).
6. **`trg_return_request_items_guard`** [НОВОЕ ИМЯ; 07 называет его «триггер остатка к возврату»]. Один триггер
   выполняет три проверки:
   - строки меняются только у заявки в статусе `draft` (DATA-145);
   - `quantity ≤ shipment_items.quantity − returned_quantity − Σ других открытых заявок`, где открытые —
     `draft/submitted/accepted`, без текущей заявки;
   - `line_total = round_half_up(si.line_total × quantity / si.quantity, 2)`. Триггер проверяет значение и не
     вычисляет его сам: сумму считает сервис.

   Вектор «100,00 / 3 шт → полный возврат 100,00, а не 99,99» проверен.
7. **`trg_<table>_row_version`** (07 §8.3) стоит на 8 таблицах из перечня §8.3: `carts`, `orders`,
   `user_profiles`, `return_requests`, `customers`, `discount_rules`, `role_discount_limits`, `app_settings`.
   - Проверка «ровно +1» — только при `current_user = 'pos_app'` и пустом `app.system` («для `pos_app`, кроме
     системных обновлений воркера»).
   - **B-AR-20:** любой другой писатель (воркер с `app.system`, миграция, иная роль БД), не увеличивший `row_version`
     сам, получает +1 от триггера — иначе клиент с оптимистической блокировкой не увидит изменение из 1С
     (`customers`, `discount_rules`). Следствие для синхронизации: upsert реплик обязан пропускать неизменённые строки
     (сравнение `source_hash`), иначе каждая выгрузка поднимет версию и вызовет ложный `VERSION_CONFLICT`.
   - В `payments` столбец `row_version` есть, но в перечне §8.3 таблицы нет: проверки «+1» нет, а триггер
     `trg_payments_row_version` (`bump_row_version()`) только увеличивает версию при любом UPDATE, не сделавшем это
     явно (B-AR-20).
   - Следствие для этапа C: любое `UPDATE` этих таблиц из API (в том числе `orders.paid_amount` при приёме
     платежа) обязано инкрементировать `row_version`. Воркер выставляет `SET LOCAL app.system`.
8. **`trg_roles_protect_system`** [НОВОЕ ИМЯ]. Системную роль нельзя удалить или переименовать (07 §5.4
   «Удаление запрещено», AC-DATA-103). Обход — `app.system = 'migration'`.
9. **`trg_integration_tokens_max_active`** — не больше двух активных токенов. Сериализация через
   `pg_advisory_xact_lock`.
10. **Не реализован триггер кэшей корзины** (`carts.items_count_cache/subtotal_cache`, «пересчёт триггером по
    `cart_items»` — 07 §5.35). Причины:
    - формула `subtotal` не задана (цена за базовую единицу или за упаковку при `packaging_id`);
    - триггер обновлял бы `carts` без инкремента `row_version`, что противоречит §8.3.

    Остаётся на этапе C (модуль `cart`) или требует уточнения 07 — см. п. 8.

## 7. Аудит (07 §9)

1. **Таблица, канонизация, хэш-цепочка и проверка.** `audit_logs`, `audit_canon`, `trg_audit_logs_chain`
   (`pg_advisory_xact_lock` → `chain_seq` → `prev_hash` → `row_hash`) и `audit_verify_chain` — по DDL 07 §14.7.
   Проверено:
   - цепочка из 12 событий → `ok = true`;
   - после изменения строки суперпользователем при отключённом триггере → `ok = false`, `broken_at_chain_seq = 2`
     (AC-DATA-157).
2. **Append-only.** Общая функция `append_only_immutable()` используется триггерами `trg_audit_logs_immutable`,
   `trg_transactions_immutable`, `trg_order_status_history_immutable` (07 §9.2). Они действуют для всех ролей,
   включая суперпользователя.
3. **Триггеры уровня БД** (`level = 'db'`, 07 §9.1–§9.2) — общая функция `audit_db_changes()`.
   - Как устроена запись: в `before/after` попадают только изменившиеся столбцы и идентифицирующие поля. Актор и
     контекст берутся из `SET LOCAL app.actor_id/actor_role/session_id/device_id/request_id/ip`. Телефоны
     маскируются в формате 07 §9.5 `+996 *** ** 67`.
   - Подключено по 07 §9.2:

     | Таблица | Код события |
     |---|---|
     | `discount_rules` (только `source='pos'`, 07 §5.33) | `discount.rule_changed` |
     | `role_discount_limits` | `discount.limits_changed` |
     | `user_roles` | `user.role_changed` |
     | `role_permissions` | `rbac.matrix_changed` |
     | `app_settings` | `settings.changed` |
     | `customers` (только `source='pos'`) | `customer.created` / `customer.updated` |
     | `return_requests` | `return.status_changed` |
     | `warehouses`, `price_lists`, `product_attributes` (столбцы с «Происх. = POS») | `settings.changed` |
     | `users` | `user.blocked` / `user.unblocked` / `user.deleted` / `user.phone_changed` |
     | `orders` | `order.status_changed` / `order.cancel_requested` |

   - **Новые коды для diff без бизнес-события.** Для изменений `orders` вне статуса и отмены и для любых изменений
     `payments` в словаре 11 §7.2 нет кода. Использованы `db.orders.update`, `db.orders.delete`,
     `db.payments.update`, `db.payments.delete` [НОВОЕ ИМЯ; формат `^[a-z_]+(\.[a-z_]+)+$`]. Их нужно передать
     владельцу словаря 11 §7.2.1 — так же 07 поступил с `rbac.matrix_changed`. Этим закрыт AC-SEC-074: прямой
     `UPDATE payments` под `pos_app` с `app.actor_id` даёт запись с diff, актором и `request_id`. Проверено.
   - **`prices`/`stock_balances` построчно не аудируются** — так решили 07 §9.2 и ядро §17.2 (агрегированные
     `sync.prices.applied`/`sync.stock.applied`). Список SEC-074 в 11 включает `prices`, но здесь действует
     более новое решение ядра.
   - **Запись без актора.** Нет ни `app.actor_id`, ни `app.system` → `severity = 'warning'`. Вариант 07 §9.1
     «в тестовом окружении — исключение» не реализован: он ломал бы seed-миграции (0002 пишет
     `rbac.matrix_changed` без актора). Полноту актора проверяют интеграционные тесты T-SEC-038.

## 8. Замечания к ТЗ (схема сделана буквально по 07, нужно решение владельца 07)

Статус после исправлений B-AR (2026-10-21): п. 1 — исправлено в DDL (B-AR-19); п. 2 — правило ретенции, DDL не
меняется (B-AR-19, см. §10); п. 3 — исправлено в DDL (B-AR-03); п. 4–5 — без изменений. Предложения владельцу 07 — §10.

1. **Категорийные фото.** `product_images_primary_uq (product_id, variant_id) NULLS NOT DISTINCT WHERE is_primary …`
   не даёт двум категориям иметь главные фото: у категорийных фото `product_id` и `variant_id` равны NULL.
   Предложение: добавить в индекс `category_id`.
2. **Ретенция `sync_runs`.** FK `sync_entity_versions.seen_in_run_id` и `sync_state.last_run_id/last_success_run_id`
   на `sync_runs` (RESTRICT) мешают удалять `sync_runs` через 90 дней (07 §13.3), если на старый прогон ещё есть
   ссылка. Нужно правило ретенции: обновлять ссылки или использовать `ON DELETE SET NULL`, но тогда меняется DATA-004.
3. **Повторная выдача роли.** PK `user_roles (user_id, role_id)` вместе с «история назначений не удаляется»
   (`revoked_at`) не позволяет повторно выдать ту же роль после отзыва.
4. **Удаление draft-заказа.** В 07 §5.39 сказано «`draft` — каскадно», а триггер `trg_order_status_history_immutable`
   запрещает `DELETE` всегда. На практике у `draft` строк истории нет: история пишется с перехода
   `draft → submitting`, §6.3.
5. **Кэши корзины** — см. §6 п. 10.

## 9. Проверки (2026-10-21, PostgreSQL 17.10, раннер `tools/pg`)

| Команда | Результат |
|---|---|
| `node tools/pg/run-sql.mjs pos-api/migrations/0001_init.sql --check scripts/check_tables.sql` | 370 команд — OK; 64 из 64 таблиц, 45 из 45 enum-ов; код 0 |
| `node tools/pg/run-sql.mjs pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_tables.sql` | OK, код 0 (совместимость с RM-B-008) |
| `node tools/pg/run-sql.mjs --repeat-strict pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql` | `ИТОГ: 0 изменений`, код 0 |
| то же, но перед миграцией `SET app.env = 'prod'` | `dev_outbox` нет, таблиц 63; `check_tables.sql` → ERROR `нет: [dev_outbox]`, код 1 (ожидаемо) |

Поведенческие проверки — 46 негативных сценариев по AC-DATA-1xx (ожидаемое отклонение CHECK, UNIQUE или
триггером), 5 проверок под `SET ROLE pos_app` (row_version, UPDATE и DELETE журналов, DDL), проверка аудита и
хэш-цепочки. Сначала их выполнял scratch-скрипт; по B-AR-10 (б) они перенесены в репозиторий:
**`scripts/check_ddl_behavior.sql`** (адаптированы к seed 0002 и дополнены проверками исправлений B-AR-01, -03, -05,
-09, -19, -20; итог прогона — 60 негативных сценариев и 6 позитивных инвариантов). Запуск:
`node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql
--check scripts/check_ddl_behavior.sql`. На этапе C (RM-C-006/RM-C-012) файл переносится в `pos-api/test/sql/` и
входит в CI.

Seed `0002_rbac_seed.sql` с 2026-10-21 генерируется `scripts/gen_rbac_seed.py` из `contracts/rbac/permissions.yaml`
(B-AR-10 (а)); проверка дрейфа — `gen_rbac_seed.py --check`.

## 10. Исправления по архитектурной проверке этапа B и предложения владельцу 07 (2026-10-21)

Источник замечаний — `docs/reviews/B_architecture_review.md`. Документ 07 в этой задаче не правится (путь вне
назначенных); ниже — что сделано в DDL и какую правку карточки предлагается внести владельцу 07, чтобы DDL и
карточка снова совпали (DATA-285: при расхождении действует карточка — до правки 07 это осознанное отступление).

| Замечание | Что сделано в `0001_init.sql` | Предложение владельцу 07 |
|---|---|---|
| B-AR-01 (критично) | `idempotency_keys`: новый столбец `subject_key text NOT NULL` (`user:<uuid>` либо `reg:<sha256(jti registration_token), 64 hex>`), PK `(key, subject_key, route)`, `user_id` — NULL допустим; CHECK `idempotency_keys_subject_user_chk`: `user:` ⇔ `user_id = uuid из subject_key`, `reg:` ⇔ `user_id IS NULL` (созданный пользователь — `resource_id`); индекс `(user_id)` частичный | §5.56: строка `subject_key`, PK `(key, subject_key, route)`, `user_id` NULL «да»; 08 §2.7 «Скоуп» — то же правило для `POST /registration/complete` (contracts/openapi/NOTES.md §8) |
| B-AR-03 | `user_roles`: суррогатный PK `id uuid DEFAULT uuid_generate_v7()`; `user_roles_user_role_active_uq UNIQUE (user_id, role_id) WHERE revoked_at IS NULL`; `user_roles_one_active_uq` (R1) сохранён; индекс `(user_id, granted_at)` для истории; аудит `trg_user_roles_audit` дополнительно пишет `id` | §5.7: PK `id`, уникальность активной пары; «история назначений не удаляется» — новая строка на каждое назначение |
| B-AR-05 | `sync_entity_versions`: ключ `onec_key text NOT NULL` (1…150 символов) — Ref_Key в тексте или ключ набора записей регистра (значение штрихкода); `onec_ref uuid` — NULL допустим, CHECK `onec_ref IS NULL OR onec_key = onec_ref::text`; PK `(entity, onec_key)` | §5.54: строка `onec_key`, PK `(entity, onec_key)`; согласовать с 05 §10.1 и 08 §4.21.1 (`ref` — строка ≤ 150) |
| B-AR-09 | условие `dev_outbox` инвертировано: только `app.env IN ('dev','test')` (§2) | §5.63: зафиксировать параметр `app.env` мигратора или перенос в `db/migrations-dev/` (RM-C-006) |
| B-AR-19, п. 1 | `product_images_primary_uq (product_id, variant_id, category_id) NULLS NOT DISTINCT WHERE is_primary AND deleted_at IS NULL` | §5.23: `category_id` в индексе главного фото |
| B-AR-19, п. 2 | FK на `sync_runs` оставлены `RESTRICT` (DATA-004 не меняется). Правило ретенции: job очистки удаляет прогоны старше 90 дней, на которые нет ссылок — `DELETE FROM sync_runs r WHERE r.started_at < now() - interval '90 days' AND NOT EXISTS (SELECT 1 FROM sync_state s WHERE r.id IN (s.last_run_id, s.last_success_run_id)) AND NOT EXISTS (SELECT 1 FROM sync_entity_versions v WHERE v.seen_in_run_id = r.id)`; `sync_state` всегда ссылается на последние прогоны, а `seen_in_run_id` обновляется при каждом полном прогоне, поэтому «застревают» только прогоны объектов, не виденных > 90 дней (они удаляются вместе со строкой версии через 1 год, §5.54) | §13.3: записать это правило ретенции (вариант «не удалять прогоны, на которые есть ссылки» вместо `ON DELETE SET NULL`) |
| B-AR-20 | `check_row_version()`: инкремент для всех писателей, проверка «+1» только для `pos_app`; `payments` — `trg_payments_row_version` (`bump_row_version()`) | §8.3: «версия увеличивается при любом UPDATE; запрет UPDATE без инкремента — для `pos_app` без `app.system`»; §5.40: `payments.row_version` — признак изменения без проверки; 06 §7.6: переходы платежей — условный `UPDATE … WHERE status IN (…) RETURNING` |
| B-AR-08 (без правки DDL) | триггер `trg_audit_logs_chain` оставлен дословно по 07 §14.7 (глобальная `pg_advisory_xact_lock` + требование `READ COMMITTED`) | 07 §9.3 / 06 §7.2: бизнес-транзакции только `READ COMMITTED` (уже так в 07 §8.5 для всех строк таблицы), `AuditWriter.append` — последняя запись перед COMMIT, чтобы блокировка цепочки держалась минимально; нагрузочный тест NFR-PERF-004 с параллельными заказами и синхронизацией (этап F); при нехватке пропускной способности — вычисление цепочки одним фоновым писателем |
| B-AR-21 (без правки DDL) | — | §5.28 + 06 §7.4 (а): таблица «столбец → писатель» для `customers`: реплицируемые столбцы (`onec_*`, `name`, `phones_norm`, `inn`, `price_list`, кредитные поля и др. с «Происх. = 1С») пишет только `sync/replica` через `INSERT … ON CONFLICT (onec_ref) DO UPDATE SET <только реплицируемые столбцы>`; строки `source='pos'` и столбцы «Происх. = POS» — модуль `customers` |

Проверки этих исправлений — раздел 5 `scripts/check_ddl_behavior.sql`; ERD (`docs/erd/README.md`) в этой задаче
не обновлялся (путь вне назначенных) — обновить при RM-C-006 по столбцам `user_roles.id`,
`idempotency_keys.subject_key`, `sync_entity_versions.onec_key`.

## 11. Номер 0004 зарезервирован и не используется (ревью этапа E, E-trace-8; 2026-10-22)

Файлы миграций: `0001`, `0002`, `0003`, `0005`, `0006`, `0007`. Номер `0004` пропущен (EQ-INT-01) и **не
занимается**: новая миграция всегда получает номер больше всех уже применённых (07 §12.1). Мигратор
(`src/db/migrator.ts`) отказывает с `MIGRATION_OUT_OF_ORDER`, если в каталоге появился неприменённый файл с версией
меньше максимальной применённой: на развёрнутой БД такой файл применился бы после `0007`, а на новой — до `0005`, и
порядок схемы на средах разошёлся бы. Проверка — `test/db/migrate-seed.db-spec.ts`, сценарий 7.

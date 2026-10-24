# Независимая архитектурная проверка этапа B (RM-B-010)

| Атрибут | Значение |
|---|---|
| Задача | RM-B-010 (13_IMPLEMENTATION_ROADMAP §3.2) |
| Дата | 2026-10-21 |
| Роль | независимый архитектурный проверяющий (QA); внешний рецензент не привлекался (Q-197) |
| Объём | контракты RM-B-003…RM-B-009: `contracts/openapi/pos-api.v1.yaml` (+ `parts/`), `contracts/onec/*`, `pos-api/migrations/0001_init.sql`, `0002_rbac_seed.sql`, `contracts/rbac/permissions.yaml`, `contracts/enums.json`, `contracts/design-tokens/tokens.json`, `contracts/l10n/*.arb`, скрипты `scripts/*` |
| Эталон | ядро R0 v1.9 (§24 имеет приоритет), 06 v-текущая, 07 v1.6, 08 v1.9, 11 §4.3–§4.4, 03 §5.3/§16.5, 02 §7, 05 §6 |
| Правки | при проверке контракты и документы ТЗ **не менялись**; исправления замечаний (2026-10-21) — §7, колонка «Статус исправления»; повторный прогон проверок — `docs/stages/B_checks.log`, раздел «ПОВТОРНЫЙ ПРОГОН ПОСЛЕ ИСПРАВЛЕНИЙ» |

## 0. Вердикт

Контракты этапа B полны и в основном точны: все проверки этапа воспроизведены и проходят (код 0), выборочная сверка 34 операций OpenAPI и 18 таблиц DDL расхождений с карточками по составу полей, кодам ответов, `x-permissions`, `x-step-up` и `x-idempotent` не выявила, граф импортов модулей 06 ацикличен.
Найдены **2 критичных** замечания (несогласованность контракта API и схемы БД — реализовать операции по контракту без нарушения ограничений БД невозможно), **10 major** и **11 minor**. Блокеров нет.
По правилу RM-B-010 п. 2 критичные замечания B-AR-01 и B-AR-02 должны быть закрыты до ворот G-B2; major — до начала соответствующих задач этапа C (указано в колонке «Срок»).

| Уровень | Кол-во | Статус (после исправлений 2026-10-21, §7) |
|---|---|---|
| блокер | 0 | — |
| критично | 2 | исправлено 2 (DDL и контракт; правка текста 07/08 — предложение владельцам) |
| major | 10 | исправлено 5 (B-AR-03, -05, -06, -09, -10), частично 3 (B-AR-04, -07, -11), передано владельцам документов 2 (B-AR-08, -12) |
| minor | 11 | исправлено 6 (B-AR-13, -14, -16, -19, -20, -23), вынесено на G-B2 1 (B-AR-15), передано владельцам документов 4 (B-AR-17, -18, -21, -22) |

## 1. Выполненные проверки (фактический результат, 2026-10-21)

Рабочий каталог `D:/optomstroy`; Python запускается как `python -I -X utf8`.

| # | Команда | Результат |
|---|---|---|
| 1 | `scripts/build_openapi.py --check` | `OK … актуален; sha256=9c88916a…`; путей 119, операций 141; код 0 |
| 2 | `npx --yes @redocly/cli@2 lint contracts/openapi/pos-api.v1.yaml` | valid, 10 предупреждений (`info-license`, 9× `no-unused-components`); код 0 |
| 3 | `scripts/check_api_paths.py` | `OK: все обязательные пути и методы есть; запрещённых и лишних операций нет`; код 0 |
| 4 | `scripts/check_api_permissions.py --require-operations` | `ошибок 0, предупреждений 9` (условия object-level, см. B-AR-18); код 0 |
| 5 | `npx --yes @redocly/cli@2 lint contracts/onec/onec-http-service.v1.yaml` | valid, 1 предупреждение (`info-license-strict`); код 0 |
| 6 | `scripts/check_onec_paths.py` | `ИТОГ: OK — ошибок: 0, информационных замечаний: 7`; набор 18 §4.0 = 05 §6.3 (21 операция); код 0 |
| 7 | `node tools/pg/run-sql.mjs --repeat-strict pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_tables.sql` | `64 из 64 таблиц, лишних нет`, `45 из 45 enum-типов 07 §6.1`, повтор — 0 изменений; код 0 |
| 8 | `scripts/check_enums.py` | `проверок пройдено 248, расхождений 0`; код 0 |
| 9 | `scripts/check_arb_keys.py` | `итог: ошибок 0`; покрытие (инфо): `error_*` 27/49, `role_*` 1/7, 22 `status_*` нет (см. B-AR-11); код 0 |
| 10 | `scripts/build_arb.py --check` | `файлы на диске совпадают со сборкой`; 2 конфликта текста 02↔03 решены в пользу 03; код 0 |
| 11 | `scripts/check_contrast.py` | `violations among allowed pairs: 0 … RESULT: OK`; код 0 |
| 12 | `scripts/gen_tokens_dart.py <tmp1>` и `<tmp2>`, `diff -r` | 8 файлов `ds_*.dart`, различий нет (детерминизм) |
| 13 | `scripts/gen_enums.py <tmp1>` и `<tmp2>`, `diff -r` | `enums.ts`, `enums.dart`, различий нет (детерминизм) |
| 14 | Собственные скрипты проверяющего (scratchpad, в репозиторий не добавлялись): дамп 34 операций OpenAPI рядом с карточками 08 §4; сравнение столбцов 18 таблиц DDL с карточками 07 §5; сверка «перечень 08 §2.7 ↔ параметр `Idempotency-Key` ↔ `x-idempotent`»; треугольник `enums.json` ↔ `CREATE TYPE` DDL ↔ enum-схемы OpenAPI; поиск циклов (алгоритм Тарьяна) в графах 06 §7.4 и §6.1 | см. §2–§4 |

## 2. Выборочная сверка контрактов с ТЗ

### 2.1. OpenAPI против карточек 08 §4 (34 операции)

Сверялись: параметры пути/query/заголовки, тело (поля, `required`, `additionalProperties:false`, запрещённые поля 08 §2.14), коды ответов и тела `2xx`, заголовки ответов (`Idempotent-Replayed`, `X-Data-As-Of`, `ETag`), `x-permissions` (11 §4.3), `x-roles` (11 §4.4), `x-step-up`/`x-step-up-operation` (08 §2.12), `x-idempotent` (08 §2.7), `x-feature-flag`, `x-status`.

| Модуль | Операции | Итог |
|---|---|---|
| auth | `POST /auth/otp/request`, `/auth/otp/verify`, `/auth/refresh`, `/auth/step-up`, `/auth/unlock`, `DELETE /auth/sessions/{sessionId}` | совпадает (ответ `202` step-up OTP, `oneOf` веток verify, `security: []` у публичных, step-up только для чужой сессии) |
| registration | `POST /registration/complete` | совпадает; конфликт со схемой БД — B-AR-01 |
| me | `PATCH /me/profile`, `POST /me/pin`, `POST /me/consents` | совпадает; minor B-AR-16 (границы `birthYear`) |
| catalog | `GET /catalog/sync/{entity}` | совпадает (12 сущностей ядра §22.7, `limit ≤ 200`, `304`, `409 cursor_expired`); minor B-AR-14 |
| cart | `PUT /cart/items/{variantId}`, `POST /cart/discount`, `PATCH /cart` | совпадает (`priceSnapshot` — только для предупреждения, как в 08 §4.7.2) |
| orders | `POST /orders`, `GET /orders`, `POST /orders/{id}/cancel`, `POST /orders/{id}/payments`, `POST /orders/{id}/onec-link` | совпадает (`201`/`202`, нет `503`, `items ≤ 200`, `idempotencyKey`, `include=statusCounts`, `sort`); B-AR-04, minor B-AR-13 |
| payments | `POST /payments` (`x-status: proposed`, `DEBT_PAYMENTS_FROM_POS`), `GET /payments/{id}` (`wait 1…25`, без `admin`), `POST /payments/{id}/confirm-manual`, `POST /payments/{id}/void` | совпадает |
| customers | `POST /customers`, `GET /customers/{id}`, `GET /customers/{id}/receivables`, `POST /customers/{id}/receivables/refresh` | совпадает, кроме B-AR-06 |
| returns | `POST /returns/{id}/submit` | совпадает (`return.submit`/`return.approve`, `returns_enabled`) |
| sync | `POST /sync/outbox/{id}/retry` | совпадает (`202`, без step-up, `admin`+`senior_seller`) |
| admin | `PUT /admin/users/{id}/roles`, `POST /admin/users/{id}/emergency-login-code`, `PUT /admin/settings` (только `x-*` против 11) | совпадает с 08; конфликт с БД — B-AR-02 |
| integrations | `POST /integrations/onec/changes`, `POST /integrations/onec/outbox/{outboxId}/ack` | совпадает с 08 §4.21; конфликт с контрактом 1С — B-AR-05 |

Сплошные проверки по всему контракту: перечень «Где обязателен» 08 §2.7 (19 операций) совпадает с операциями, где `Idempotency-Key` обязателен (0 недостающих, 0 лишних); значение `x-idempotent` согласовано с параметром у всех 141 операций; `x-step-up: true` — 32 операции, все из ядра §3.3/§17.2 и SEC-033.

### 2.2. DDL против карточек 07 §5 (18 таблиц)

`users`, `user_roles`, `sessions`, `otp_challenges`, `customers`, `customer_links`, `carts`, `orders`, `order_items`, `payments`, `payment_webhook_events`, `return_requests`, `onec_outbox`, `sync_errors`, `idempotency_keys`, `audit_logs`, `app_settings`, `transactions`.

- Состав столбцов: у всех 18 таблиц «есть в карточке, нет в DDL» — 0; «есть в DDL, нет в карточке» — только `id`/`created_at`/`updated_at` (DATA-002) и `onec_ref` документов POS (07 §14.5). NULL/NOT NULL совпадают (3 срабатывания сравнения — generated/identity-столбцы, фактически NOT NULL).
- Подробно сверены ограничения `orders` (11 CHECK, включая `orders_customer_channel_chk`, `orders_onec_sync_status_chk`; 3 частичных UNIQUE), `payments` (`payments_one_open_per_order_uq`, `payments_idem_uq`, `payments_cash_received_chk`), `onec_outbox` (`external_id = aggregate_id::text`, `UNIQUE (external_id, operation)`, аренда `lease_until`, 6 индексов карточки), `idempotency_keys`, `user_roles`, `audit_logs` (хэш-цепочка `trg_audit_logs_chain`, append-only `trg_*_immutable` для всех ролей, `REVOKE ALL` + `GRANT INSERT, SELECT` для `pos_app`, `TRUNCATE` у `pos_app` нет) — совпадают с 07 §5, §9, §14.7.
- Найденные несогласованности — B-AR-01, B-AR-02, B-AR-03, B-AR-08, B-AR-09, B-AR-19, B-AR-20.

### 2.3. Матрица прав против 11 §4.4

Проверено по ячейкам для всех кодов `payment.*`, `credit.*`, `return.*` и для полных наборов ролей `owner`, `admin`, `customer`: совпадает с 11 §4.4 и ядром §17.2, §21 п.3, §24.2 (у `owner` и `admin` нет кассовых кодов; `credit.sale.approve` — только `senior_seller`; `payment.qr.show` у `customer` — с ограничителем `QR_PROVIDER=onec`). Решение «клиенту — `customer.self.*` вместо staff-кодов с `own`» (rbac NOTES §2 п.1) обосновано deny-by-default и SEC-032; рекомендация владельцу 11 уточнить ячейки поддерживается.

### 2.4. Токены (вариант B, HEX)

`meta.palette = "B"`; все 39 цветовых токенов `color.*` совпадают с таблицей 03 §5.3 (в т. ч. `primary #FF8700`, `onPrimary #1B1F2A`, `primaryText #B04E00`, `focus`/`info #1F5FA8`, `inverseSurface #1B1F2A`, `onInverseSurface #FFFFFF`); формат `#RRGGBB` в верхнем регистре; `overlay` и тени — `{rgb, opacity}`. Радиусы `xs…full`, `space.1…10`, `elevation.0…3`, четыре кривые `motion.curve.*`, `breakpoint.large ≥ 1600`, плотность `standard|compact` — по R0 §17.5, §18.2 п.15. Отклонение — B-AR-15.

### 2.5. Enum-ы против 07 §6

Треугольник проверен независимо: 45 типов `enums.json.dbEnums` = 45 `CREATE TYPE` в DDL (имена, порядок значений — 0 расхождений) = enum-схемы OpenAPI в PascalCase (у 38 типов есть схема API, значения совпадают; 7 внутренних типов — `otp_status`, `attribute_value_type`, `image_status`, `idempotency_status`, `audit_level`, `print_job_status`, `sms_status` — в API не выставляются, это допустимо). CHECK-перечни 07 §6.1.1 совпадают с DDL. Автоматической проверки этого треугольника в репозитории нет — B-AR-10.

### 2.6. ARB против 02 §7

Выборка 12 случайных ключей (seed 7) и 5 ключей по тексту 02 §7 (`cart_warehouse_changed`, `parked_owner_readonly`, `receivables_credit_blocked_stale`, `customer_new_create_failed`, `admin_users_source_invitation`): текст, экран и плейсхолдеры совпадают; `@key.description` есть у всех; `ky`/`en` — каркас (копия `ru` с пометкой «TODO перевод», l10n NOTES §3.6). Неполнота общих ключей 03 — B-AR-11.

### 2.7. Контракт 1С против 05 §6

21 операция `/pos/v1/*` = таблица 05 §6.3; у каждой есть `x-idempotency`, `x-retry`, `x-priority`, коды `POS_E_*` 05 §6.5; QR-методы 05 §6.7 присутствуют; фикстуры валидируются строго. 9 расхождений 05↔18 записаны в `contracts/onec/NOTES.md` §4 с предложениями владельцу 05 — поддерживаются. Схемы элементов `/changes`, выведенные из 05 §5.3 (`x-status: proposed`), утверждаются в RM-B-014. Межконтрактное расхождение — B-AR-05.

## 3. Замечания

Формат: ID — уровень — где — проблема — исправление — владелец — срок. Статус на момент проверки — **открыто**;
текущий статус каждого замечания — §7, колонка «Статус исправления».

### Критично

**B-AR-01 — критично.** `pos-api/migrations/0001_init.sql` (`idempotency_keys.user_id uuid NOT NULL FK users`, PK `(key, user_id, route)`; 07 §5.56) ↔ `pos-api.v1.yaml` `POST /registration/complete` (`Idempotency-Key` обязателен, `security: []`; 08 §2.7 — скоуп `(key, userId, route)`).
Проблема: у публичной операции регистрации пользователя ещё нет — строку `in_progress` вставить нельзя (NOT NULL + FK). Обязательная по 08 идемпотентность («повтор → тот же 201») нереализуема без нарушения схемы; повтор после сетевого сбоя даст `409 PHONE_ALREADY_REGISTERED` вместо сохранённого `201` с токенами.
Исправление: 07 §5.56 — заменить скоуп на `subject_key text NOT NULL` (`user:<uuid>` | `reg:<sha256(jti registration_token)>`), PK `(key, subject_key, route)`, `user_id` — NULL допустим; 08 §2.7 — строка «Скоуп» с тем же правилом для `/registration/complete`. Владелец: 07 (схема), 08 (скоуп). Срок: до G-B2.

**B-AR-02 — критично.** `pos-api.v1.yaml` `AdminUsersRolesSetRequest.roles` (`minItems 1, maxItems 7`) и `AdminUsersCreateRequest.roles` (`1…5`) ↔ DDL `user_roles_one_active_uq UNIQUE (user_id) WHERE revoked_at IS NULL` и одиночное `user_invitations.role` (07 §5.3, §5.7: «в R1 — ровно одна активная роль»).
Проблема: контракт принимает набор ролей, который БД отвергнет нарушением уникальности (`500` вместо бизнес-ошибки); приглашение с двумя ролями не сохраняется.
Исправление: 08 §4.18.1–§4.18.2 — в R1 `maxItems: 1` (расширение до нескольких ролей — expand-изменение после решения Q-005) либо явное правило `422 VALIDATION_FAILED` (rule `single_role_r1`); `Me.roles` остаётся массивом. Владелец: 08 + 07 (Q-005). Срок: до G-B2.

### Major

**B-AR-03 — major.** DDL `user_roles` PK `(user_id, role_id)` + «история назначений не удаляется» (07 §5.7; уже отмечено в `pos-api/migrations/NOTES.md` §8 п.3).
Проблема: возврат ранее отозванной роли (`cashier → seller → cashier`) упирается в PK; реализация вынуждена «оживлять» старую строку и теряет интервал истории в самой таблице.
Исправление: 07 §5.7 — суррогатный `id` PK, `UNIQUE (user_id, role_id) WHERE revoked_at IS NULL`. Владелец: 07. Срок: до RM-C-006.

**B-AR-04 — major (риск потери согласованности при повторе).** 08 §4.8.1 «Состав одной транзакции» (`idempotency_keys` → `completed` с телом `201/202` внутри транзакции) ↔ «после COMMIT — формирование QR» (`qr_pending → qr_shown`, `warnings[QR_UNAVAILABLE]`); то же для `POST /payments` с QR.
Проблема: сохранённое тело не содержит QR и предупреждений, сформированных после COMMIT; повтор с тем же ключом (обрыв сети — основной сценарий идемпотентности) вернёт устаревшее состояние платежа, кассир увидит «QR недоступен» при выданном QR.
Исправление: 08 §2.7 — для операций с пост-COMMIT шагом повтор возвращает **текущее** представление ресурса по `idempotency_keys.resource_id` с `Idempotent-Replayed: true` (или тело перезаписывается после пост-COMMIT шага); тест в 12 (повтор `POST /orders` после выдачи QR). Владелец: 08. Срок: до RM-F-001/RM-F-016.

**B-AR-05 — major.** `pos-api.v1.yaml` `IntegrationsOnecChangeObject.ref: format uuid` (08 §4.21.1, вариант C-2) ↔ `contracts/onec/onec-http-service.v1.yaml` `BarcodeChange.ref` / `ObjectDeletion.ref` = значение штрихкода (05 §6.2 п.1, ONEC-017); 07 §5.54 `sync_entity_versions` ключ `(entity, onec_ref uuid)`.
Проблема: при C-2 пакет с изменением или удалением штрихкода отвергается `400` целиком, 1С не снимает регистрацию — обмен по плану «POS» останавливается; версии наборов записей регистров негде хранить.
Исправление: 08 §4.21.1 — `ref: string, maxLength 150`, проверка формата по `objectType` (GUID для справочников/документов); 07 §5.54 — ключ `onec_key text` для наборов записей регистров. Владелец: 08, 05 §10.1, 07. Срок: до RM-E (адаптер обмена).

**B-AR-06 — major.** `GET /customers/{id}/receivables` (08 §4.11.5: `200` с `balance: null, reason: not_in_onec` для клиента `source=pos`) ↔ схема `Receivable` (`balance` обязателен и не nullable, поля `reason` нет). Записано в `contracts/openapi/NOTES.md` §7.4 п.2, не закрыто; там же п.3 — состав `include=discounts` не задан.
Проблема: контрактные тесты ответа упадут, сгенерированный Dart-клиент упадёт на `null`.
Исправление: 08 §3.7 — `balance` nullable + `reason` (`not_in_onec`); состав блока `discounts`. Владелец: 08. Срок: до RM-G-002.

**B-AR-07 — major (дублирование бизнес-логики).** 08 §4.8 «сервер повторно выполняет все проверки `checkout-preview` при создании» ↔ 06 §7.4: предпросмотр — модуль `cart`, создание — `orders`; единый владелец процедуры проверок (цены, остатки, лимит скидки, порядок продажи в долг ядра §22.4, режим клиента ядра §24.2, `/check` 1С) не назван; на диаграмме нет ребра `cart → sync` (`OnecCheckService.verifyOrder` нужен предпросмотру); хранение результата `/check` для повторного использования ≤ 60 с (05 SYNC-071) не определено — `previewToken` подписывает только `cartRowVersion + итоги + validUntil` (08 §3.8).
Проблема: две реализации одной процедуры в `cart` и `orders` разойдутся (классический источник «предпросмотр разрешил — создание отказало»).
Исправление: 06 §7.4 — `CheckoutPolicy` (domain-сервис модуля `cart`, экспорт `CartService.validateForCheckout(tx?, input)`), его вызывают и `/cart/checkout-preview`, и `orders.create` (ребро `orders → cart` уже есть); добавить ребро `cart → sync`; 08 §3.8 — включить `onecCheck.at`/хэш результата в подпись `previewToken`. Владелец: 06, 08. Срок: до RM-F-001.

**B-AR-08 — major (производительность/изоляция).** DDL `trg_audit_logs_chain` (дословно 07 §14.7): `pg_advisory_xact_lock(hashtext('audit_chain'))` + `RAISE`, если уровень изоляции не `READ COMMITTED`; аудит пишут и бизнес-транзакции (`AuditWriter.append(tx, …)`), и триггеры `audit_db_changes` на `orders`, `customers`, `user_roles` и др.
Проблема: глобальная блокировка держится до COMMIT — все транзакции с аудитом сериализуются (`POST /orders`, приём платежей, применение пакетов синхронизации); любая транзакция `REPEATABLE READ`/`SERIALIZABLE` с аудитом падает.
Исправление: 06 §7.2 п.2 — правило «бизнес-транзакции только `READ COMMITTED`; `AuditWriter.append` — последняя запись перед COMMIT»; нагрузочный тест NFR-PERF-004 с параллельными заказами и синхронизацией; при недостаточной пропускной способности — вычисление цепочки одним фоновым писателем (07 §9.3). Владелец: 07 §9.3, 06. Срок: RM-C-006 (правило), этап F (тест).

**B-AR-09 — major (безопасность конфигурации).** `0001_init.sql`: `dev_outbox` создаётся, если `app.env <> 'prod'` (отказ открыт); AC-DATA-169 (миграции prod не содержат `CREATE TABLE dev_outbox`) не выполняется (migrations NOTES §2).
Проблема: забытый `PGOPTIONS` на prod создаёт таблицу симулятора SMS в боевой схеме; защита остаётся только на старте приложения (T-SEC-007).
Исправление: RM-C-006 — перенести блок в `db/migrations-dev/` (07 §5.63) или инвертировать условие на «создавать только при `app.env IN ('dev','test')`». Владелец: 07 / RM-C-006. Срок: до RM-C-006.

**B-AR-10 — major (сопровождение).** Источники истины дублируются без генераторов/проверок в репозитории:
(а) `permissions.yaml` ↔ `0002_rbac_seed.sql` — генератор «вне назначенных путей» (rbac NOTES §2 п.18); расхождение ловит скрипт, но правка — вручную в двух местах;
(б) 46 поведенческих негативных проверок DDL выполнены scratch-скриптом и в репозитории отсутствуют (migrations NOTES §9);
(в) скрипт сверки `00_root.yaml` со словарями (openapi NOTES §6 п.2) не перенесён в `scripts/`;
(г) нет автоматической проверки `enums.json` ↔ `CREATE TYPE` ↔ enum-схем OpenAPI (сверено вручную в §2.5).
Исправление: в RM-C-011 (`contracts-lint`) добавить `scripts/gen_rbac_seed.py --check`, `pos-api/test/sql/*.sql` (46 сценариев), `scripts/check_openapi_dictionaries.py`, `scripts/check_enum_triangle.py`. Владелец: ARCH. Срок: RM-C-011.

**B-AR-11 — major.** `contracts/l10n/app_ru.arb` ↔ 03 §16.5, §9.39: нет текстов для 22 ключей `error_*` (`error_session_revoked`, `error_pin_locked`, `error_pin_invalid`, `error_otp_invalid`, `error_otp_expired`, `error_unlock_required`, `error_device_mismatch`, `error_app_update_required` и др.), 22 `status_*` (outbox, sync, возвраты, привязки, корзина) и 6 `role_*`; тексты не заданы у владельца 03. Кроме того, `error_qr_unavailable` = «Банк недоступен» (03 §16.5) неверен для основного варианта R1 `QR_PROVIDER=onec` (ядро §24.4: QR недоступен из-за 1С).
Проблема: `ErrorMapper` Flutter вынужден показывать общий текст или зашивать строки в код (нарушение L-6/D-38).
Исправление: владелец 03 §16.5 даёт тексты до RM-C-002; в CI — `check_arb_keys.py --strict-coverage`; текст `error_qr_unavailable` — нейтральный («QR временно недоступен»), согласно 02. Владелец: 03. Срок: до RM-C-002.

**B-AR-12 — major (риск цикла во время выполнения).** 06 §7.4: граф импортов ацикличен (проверено), но с рёбрами очереди pg-boss (`sync → orders/payments/customers/returns/cart/catalog`) образуется компонента сильной связности из 7 модулей. Если типы payload заданий или имена очередей будут импортироваться из модулей-владельцев, цикл станет импортным.
Исправление: 06 §7.3 — имена очередей и типы payload `*.onec-confirmed`, `catalog.*-changed` объявить в `common/jobs/contracts` (без импорта модулей); правило BE-06 §5.2. Владелец: 06. Срок: RM-C-005.

### Minor

**B-AR-13.** `POST /orders/{id}/payments` не перечисляет `503` (`QR_UNAVAILABLE` при `QR_PROVIDER=bakai`, R2), `POST /payments` — перечисляет. Покрыто `default`; выровнять. Владелец: RM-B-003.

**B-AR-14.** `CatalogSyncResponse.items` — `anyOf` из 12 схем без дискриминатора: генератор `dart-dio` даст нетипизированную обёртку. Рекомендация: описать соответствие `entity → схема` расширением (`x-entity-schema`) и декодировать по `entity` в data-слое (одна точка), либо отдельные схемы ответов на сущность. Владелец: RM-B-003 / RM-C-004.

**B-AR-15.** `tokens.json` содержит `alternatives.A` (A+), тогда как 13 RM-B-006 требует «в `tokens.json` не вносится». Решение записано (design-tokens NOTES п.1), генератор по умолчанию A не выводит. Принять отклонение на G-B2 или убрать A из `tokens.json` (оставив в 03). Владелец: DS.

**B-AR-16.** `Profile.birthYear` (ответ) — `minimum 1900`, в телах запросов — `1920`; у `X-Step-Up-Token` `required: false` там, где карточка 08 пишет «обязателен» (семантика — `403 STEP_UP_REQUIRED`, это допустимо) — записать это в `description` параметра, чтобы потребители кодогенерации не считали заголовок необязательным. Владелец: RM-B-003.

**B-AR-17.** `CustomerViewSeller|Cashier|Admin|Self` не используются операциями (`no-unused-components`); фильтрация полей `Customer` по `x-roles` нужна в `GET /customers/{id}`, `Cart.customer`, `Order.customer`. Риск — фильтр, повторённый в каждом сериализаторе. Рекомендация 06: один `CustomerProjector.forRole()` в модуле `customers`; контрактные тесты — по `CustomerView*`. Владелец: 06 / RM-G.

**B-AR-18.** Имя расширения `x-permissions` (массив) вместо `x-permission` из AC RM-B-008 — решение обосновано (08 §8, альтернативы кодов), скрипт читает оба; выровнять формулировку AC в 13. 9 предупреждений `[A]` скрипта прав — условия object-level 11 §4.3.1, не ошибки. Владелец: 13.

**B-AR-19.** FK `RESTRICT` на `sync_runs` (`sync_entity_versions.seen_in_run_id`, `sync_state.last_run_id`) мешает ретенции 90 дней (07 §13.3); `product_images_primary_uq` не допускает главных фото у двух категорий (migrations NOTES §8 п.1–2). Владелец: 07.

**B-AR-20.** `check_row_version()` инкрементирует `row_version` только при `current_user = 'pos_app'` и пустом `app.system`: изменения `customers`/`discount_rules` воркером синхронизации не меняют версию — клиент с оптимистической блокировкой не увидит обновление 1С; у `payments` `row_version` есть, триггера нет. Рекомендация 07 §8.3: инкремент — для всех писателей, проверка — только для `pos_app`; 06 §7.6 — переходы платежей только `UPDATE … WHERE status IN (…) RETURNING`. Владелец: 07, 06.

**B-AR-21.** Два писателя таблицы `customers` (`sync/replica` — реплицируемые поля, `customers` — строки `source='pos'`, 06 §7.4 (а)). Нужна явная таблица «столбец → писатель» и правило: `ON CONFLICT (onec_ref) DO UPDATE SET` только реплицируемых столбцов. Владелец: 06, 07 §5.28.

**B-AR-22.** DAG фич Flutter: `customers` не имеет зависимостей, а SCR-31/SCR-33 (история покупок клиента) показывает заказы — велик соблазн импортировать `orders` (`orders → customers` уже есть, получится цикл). Рекомендация 06 §6.1: собственный read-model `customers/domain/CustomerOrderSummary`, переход к заказу — по маршруту. Владелец: 06.

**B-AR-23.** Контракт 1С: 9 расхождений 05↔18 и схемы элементов `/changes` со статусом `proposed` (onec NOTES §3 п.10–11, §4) — закрываются в RM-B-014 по ONEC-074 (сначала 05 §6, затем 18). Риск: специалист 1С реализует по 18 до правки 05. Рекомендация: зафиксировать в журнале версий RM-B-014, что `proposed`-схемы — предмет согласования, а не готовый канон. Владелец: ONEC.

## 4. Архитектурные риски (чек-лист RM-B-010 п.1)

| Риск | Оценка | Основание |
|---|---|---|
| Циклические зависимости модулей 06 | **нет циклов** в графе импортов: backend — 17 узлов, 38 рёбер, 0 циклов; фичи Flutter — 15 узлов, 24 ребра, 0 циклов. С рёбрами pg-boss — 1 компонента из 7 модулей (ожидаемо, только через очередь) | Тарьян по 06 §7.4 и §6.1 (DAG фич); B-AR-12, B-AR-22 |
| Смешивание слоёв | правила 06 §6.1 (L-1…L-10) и §7.2 (ARCH-030…033) достаточны; не хватает машинных правил — см. §5 | — |
| Дублирование бизнес-логики | проверки оформления (B-AR-07); фильтрация полей по ролям (B-AR-17); денежная арифметика на клиенте ограничена «цена × количество» офлайн (06 §4.6) — допустимо; проекция статусов заказа — единый `OrderStateMachine` (06 §7.4 (в)) | B-AR-07, B-AR-17 |
| Потеря данных: транзакции | заказ, начальный платёж, outbox, история, журнал, аудит, конвертация корзины, ключ идемпотентности — одна транзакция (08 §4.8.1); внешние вызовы вне транзакции; append-only журналов на уровне БД для всех ролей | DDL §2.2; B-AR-08 |
| Потеря данных: outbox | `UNIQUE (external_id, operation)`, `external_id = aggregate_id`, аренда `lease_until` + `outbox.unlock`, `depends_on_outbox_id`, dead-letter индекс — корректно; ручной повтор только `failed/dead` | 07 §5.55, DDL |
| Потеря данных: идемпотентность | перечень 08 §2.7 полностью покрыт; дыры — регистрация (B-AR-01) и повтор после пост-COMMIT шага (B-AR-04); исходящая идемпотентность к 1С по UUID агрегата — корректна | B-AR-01, B-AR-04 |
| Потеря данных: обмен 1С | C-2 и регистры (B-AR-05) | B-AR-05 |
| Сложность сопровождения | ручная синхронизация пар файлов и проверки вне репозитория (B-AR-10); сборка OpenAPI из 7 частей детерминирована, решения авторов частей теряются при сборке (комментарии YAML) — хранить их в `NOTES.md`, как сделано | B-AR-10 |
| Избыточные абстракции | не выявлено: порты только там, где нужна инверсия (`InitialPaymentPort`, `OrderPaymentsReadPort`, журналы, `OutboxActionHandler`) | 06 §7.4 (г)–(е), §6.2 |

## 5. Правила слоёв для lint (спецификация; запуск — RM-C-002 и RM-C-005)

### 5.1. Flutter — `custom_lint` (пакет правил проекта, например `tools/optomstroy_lints`, подключается в `pos-app/analysis_options.yaml`)

Пути — относительно `pos-app/lib/`. Нарушение любого правила — `error` (CI падает). Тесты (`test/**`) из правил FL-01…FL-07 исключены.

| ID | Правило (06 §6.1) | Область | Запрещено | Разрешено |
|---|---|---|---|---|
| FL-01 `domain_pure` (L-1) | domain не знает фреймворков | `features/*/domain/**`, `core/error/**` | `package:flutter/*`, `package:flutter_riverpod`, `package:riverpod*`, `package:dio`, `package:drift`, `package:go_router`, `package:flutter_secure_storage`, `package:json_annotation`; любые `features/*/data/**`, `features/*/presentation/**`, `core/{network,database,storage,sync,hardware,connectivity,di,session}/**`, `design_system/**` | `dart:*`, `package:freezed_annotation`, `package:meta`, `core/error/**`, свой `domain`, `domain` фич из DAG (FL-03) |
| FL-02 `presentation_no_data` (L-2, L-6, L-9) | экраны и Notifier не ходят в данные | `features/*/presentation/**` | `features/*/data/**`, `package:dio`, `package:drift`, `package:flutter_secure_storage`, `core/{network,database,storage,hardware}/**` | `domain`, `<f>_providers.dart`, `design_system/**`, `core/{di,error,l10n,utils}/**` |
| FL-03 `feature_public_api` (L-3, L-10) | межфичевые импорты — только публичный контракт и только по DAG | `features/<a>/**` | импорт `features/<b>/**`, кроме `features/<b>/domain/**` и `features/<b>/<b>_providers.dart`; любой `<b>` вне строки `<a>` таблицы «DAG фич» 06 §6.1 | строки DAG: `cart→customers`; `catalog→cart`; `product_details→catalog,cart`; `favorites→catalog,customers`; `orders→customers`; `cashier→orders,customers`; `checkout→cart,customers,orders,cashier`; `transactions`,`returns→orders,cashier,customers`; `reports→transactions`; `registration`,`profile→auth`; `settings→auth,profile` |
| FL-04 `core_no_features` (L-4) | core не знает о фичах | `core/**` | `features/**`, `design_system/**` | — |
| FL-05 `design_system_isolated` (L-5) | DS без бизнес-логики | `design_system/**` | `features/**`, `core/{network,database,storage,sync}/**`, `package:dio`, `package:drift` | `core/l10n/**`, `design_system/tokens/**` |
| FL-06 `composition_root` (L-8) | связывание реализаций — только в корне | весь `lib/` | импорт `features/*/data/**` откуда-либо, кроме своей фичи `features/<f>/data/**` и `app/di/overrides.dart` (только файлы `*_bindings.dart`) | — |
| FL-07 `providers_contract` (L-3 п.2) | публичный файл провайдеров не связывает реализации | `features/<b>/<b>_providers.dart` | `features/<b>/data/**`, `features/<b>/presentation/**` | `features/<b>/domain/**`, `package:riverpod*`, `core/di/**` |
| FL-08 `no_raw_tokens_strings` (D-38, 03) | цвета и строки — только из DS и ARB | `features/*/presentation/**`, `design_system/components/**` | литералы `Color(0x…)`, `Colors.*` (кроме `transparent`), строковые литералы в `Text(…)`, `tooltip:`, `labelText:` | `DsColors.*`, `AppLocalizations.of(context).*` |
| FL-09 `generated_readonly` | сгенерированные контракты не правятся | `design_system/tokens/*.dart`, `core/enums.dart`, `l10n/*.arb` | ручные изменения (CI: `gen_tokens_dart.py --check`, `gen_enums.py` + `diff`, `build_arb.py --check`) | — |
| FL-10 `no_double_money` (ARCH-048) | деньги/количества не `double` | `features/**`, `core/**` | поля и параметры типа `double`/`num` с именами `*price*`, `*amount*`, `*total*`, `*qty*`, `*quantity*` | `Money`, `Qty` из `core/utils` |
| FL-11 `no_cycles` (L-10) | граф импортов фич ацикличен | `lib/**` | любой цикл между `features/*` | — (инструмент — `lakos --no-cycles` или скрипт по графу, 06 §6.1) |

### 5.2. Backend — `madge` + правила границ (`eslint-plugin-boundaries` или `dependency-cruiser`)

Пути — относительно `pos-api/src/`. `madge` ловит только циклы; разрешённые рёбра проверяются правилами границ.

| ID | Правило (06 §7.2–§7.4) | Проверка |
|---|---|---|
| BE-01 `no_cycles` (MOD-022) | 0 циклов в графе импортов | `npx madge --circular --extensions ts --ts-config tsconfig.json src/` → код ≠ 0 при любом цикле (гейт PR) |
| BE-02 `module_allowlist` | межмодульные импорты — только рёбра 06 §7.4: `profile→auth`; `registration→auth,customers`; `cart→catalog,customers,notifications,sync`*; `orders→cart,catalog,customers,sync,notifications`; `payments→orders,customers,sync,notifications`; `returns→orders,sync`; `transactions→orders,payments,returns` (только `*QueryService`); `customers→sync`; `catalog→sync`; `admin→auth,sync,transactions`; `sync→notifications`; `health→sync`; все — `→ common/**`. Явно запрещены: `sync→{orders,payments,customers,returns,cart,catalog}`, `catalog→cart`, `orders→payments`, `auth→{profile,admin}`, `common/**→modules/**`, `infra/**→modules/**` | правила границ; *ребро `cart→sync` — после принятия B-AR-07 |
| BE-03 `public_api_only` | импорт чужого модуля — только через его `index.ts` (экспортируемые сервисы 06 §7.4) | запрет глубоких путей `modules/<b>/**` кроме `modules/<b>/index.ts` |
| BE-04 `layers` (ARCH-030…033) | `*.controller.ts` → только application service своего модуля и DTO; `domain/**` не импортирует `@nestjs/*`, `drizzle-orm`, `pg`, `pg-boss`, `infra/**`, `db/**`; `repositories/**` не импортирует controllers/services; `infra/**` реализует порты и не импортирует модули | правила границ по типам файлов |
| BE-05 `journal_writers` (MOD-028, 06 §7.4 (г)) | `transactions`, `audit_logs` — запись только `common/journal/**`; `onec_outbox` — только `modules/sync/outbox/**`; таблицы-реплики 1С — только `modules/sync/replica/**` | импорт `db/schema/journal.ts` и схем реплик для `insert/update` разрешён только этим путям (`no-restricted-imports` по путям + ревью) |
| BE-06 `job_contracts` (B-AR-12) | имена очередей и payload заданий — только `common/jobs/contracts/**`; модули не импортируют обработчики других модулей | правила границ |
| BE-07 `no_external_calls_in_tx` (08 §4.8, 06 §7.2 п.2) | внутри колбэка `db.transaction(…)` нет вызовов `*Gateway`/`*Provider`/`fetch` | собственное ESLint-правило (AST: вызов в теле колбэка `transaction`) |
| BE-08 `generated_readonly` | `common/enums.ts` и DTO из OpenAPI не правятся вручную; значения enum не дублируются строковыми литералами | CI `gen_enums.py` + `diff`; `no-restricted-syntax` для литералов статусов |
| BE-09 `single_money` (MOD-023) | одна реализация `Money`/`Qty`/округления — `common/money/**` | запрет импорта `decimal.js`/`big.js` вне `common/money/**` |

## 6. Что не проверено и почему

- Не все 141 операции сверены с карточками 08 вручную: выборка 34 операции + сплошные машинные проверки идемпотентности, step-up, путей и прав (§2.1).
- DDL: столбцы сверены у 18 таблиц, ограничения подробно — у 7; остальные 46 таблиц покрыты только `check_tables.sql` (наличие) и заметками авторов.
- ARB: сверено 17 ключей из 1933; переводы `ky`/`en` не проверялись (каркас по D-38).
- Поведенческие проверки триггеров (46 сценариев авторов) не воспроизводились: скрипт отсутствует в репозитории (B-AR-10 (б)).
- Правила §5 — спецификация; их запуск на коде — RM-C-002 (`dart run custom_lint`) и RM-C-005 (`madge --circular`), кода `pos-app/` и `pos-api/src/` ещё нет.
- Контракт 1С не проверялся против реальной конфигурации 1С (`$metadata` не получен, RM-A-002/RM-B-014).

## 7. Статус исправления замечаний (2026-10-21)

Исправления вносились только в разрешённые пути: `contracts/**`, `scripts/**`, `pos-api/migrations/**`, `tools/**`.
Документы ТЗ (`docs/specification/**`: 05, 06, 07, 08, 12, 13) **не правились**; где исправление по сути — правка текста
ТЗ, оно записано как предложение владельцу в заметках каталога (`contracts/openapi/NOTES.md` §8.2,
`pos-api/migrations/NOTES.md` §10), а статус — «передано владельцу». Повторный прогон всех проверок этапа B и новых
проверок — `docs/stages/B_checks.log`, раздел «ПОВТОРНЫЙ ПРОГОН ПОСЛЕ ИСПРАВЛЕНИЙ»: все команды с ожидаемым кодом.

| ID | Уровень | Статус исправления | Что сделано / что осталось |
|---|---|---|---|
| B-AR-01 | критично | **исправлено** (DDL, контракт); текст 07 §5.56 и 08 §2.7 — предложение владельцам | `idempotency_keys`: `subject_key text NOT NULL` (`user:<uuid>` / `reg:<sha256(jti)>`), PK `(key, subject_key, route)`, `user_id` NULL допустим, CHECK согласованности; описание `Idempotency-Key` и `POST /registration/complete` — скоуп регистрации, повтор выдаёт токены заново (токены в хранилище не сохраняются, 07 §5.56). Проверено: 6 сценариев в `scripts/check_ddl_behavior.sql` |
| B-AR-02 | критично | **исправлено** (контракт); текст 08 §4.18.1–§4.18.2 — предложение | `AdminUsersCreateRequest.roles`, `AdminUsersRolesSetRequest.roles` — `maxItems: 1` (две роли → `400 VALIDATION_FAILED` по схеме); расширение после Q-005 — expand. Проверено: негативные кейсы в `scripts/check_openapi_dictionaries.py` |
| B-AR-03 | major | **исправлено** (DDL) | `user_roles`: PK `id`, `UNIQUE (user_id, role_id) WHERE revoked_at IS NULL`, R1-индекс одной активной роли сохранён. Проверено: `cashier → seller → cashier` даёт 3 строки истории |
| B-AR-04 | major | **частично**: контракт исправлен; 08 §2.7 и тест 12 — предложение; реализация — RM-F-001/RM-F-016 | В описаниях `Idempotency-Key`, `Idempotent-Replayed`, `POST /orders`, `POST /orders/{id}/payments`, `POST /payments`: повтор операции с шагом после COMMIT возвращает текущее представление ресурса с тем же статусом и `Idempotent-Replayed: true` |
| B-AR-05 | major | **исправлено** (контракт, DDL); 08 §4.21.1, 05 §10.1, 07 §5.54 — предложение | `IntegrationsOnecChangeObject.ref` — строка 1…150, формат по `objectType` проверяет сервер (ошибка объекта → `sync_errors`); `sync_entity_versions`: ключ `onec_key text`, `onec_ref` nullable, PK `(entity, onec_key)`. Проверено: удаление штрихкода валидно по схеме; 3 сценария DDL |
| B-AR-06 | major | **исправлено** (контракт); 08 §3.7 — предложение | `Receivable.balance`/`asOf` nullable, `reason: not_in_onec`; `Customer.discounts` (и `CustomerView*`) = `CustomersDiscountsResponse` (состав ответа 08 §4.11.6); пробелы `contracts/openapi/NOTES.md` §7.4 п.2–3 закрыты |
| B-AR-07 | major | **частично**: описание `previewToken` в контракте; `CheckoutPolicy`, ребро `cart → sync`, подпись токена — передано владельцам 06 §7.4 и 08 §3.8 | Правка архитектуры модулей и формата токена — текст 06/08 (вне назначенных путей); предложение — `contracts/openapi/NOTES.md` §8.2. Срок по отчёту — до RM-F-001 |
| B-AR-08 | major | **передано владельцам** 06 §7.2 / 07 §9.3; DDL не менялся | Триггер цепочки оставлен дословно по 07 §14.7. Правило «только `READ COMMITTED`, `AuditWriter.append` — последней записью перед COMMIT», нагрузочный тест NFR-PERF-004 и вариант фонового писателя — предложение (`pos-api/migrations/NOTES.md` §10); тест — этап F |
| B-AR-09 | major | **исправлено** (отказ закрыт); перенос в `db/migrations-dev/` — RM-C-006 | `dev_outbox` создаётся только при `app.env IN ('dev','test')`; `scripts/check_tables.sql` зависит от того же параметра (dev/test — 64 таблицы, иначе 63 и `dev_outbox` запрещён); раннер `tools/pg` получил `--set`. Проверено обоими прогонами. Буквальный grep-критерий AC-DATA-169 закроет перенос в RM-C-006 |
| B-AR-10 | major | **исправлено**: скрипты и SQL-проверки в репозитории; подключение к CI `contracts-lint` — RM-C-011 (CI ещё нет) | (а) `scripts/gen_rbac_seed.py [--check]` — seed 0002 генерируется из `permissions.yaml`; (б) `scripts/check_ddl_behavior.sql` — 60 негативных сценариев + 6 инвариантов (перенос в `pos-api/test/sql/` — RM-C-006, путь вне назначенных); (в) `scripts/check_openapi_dictionaries.py`; (г) `scripts/check_enum_triangle.py`. Негативные самотесты (а) и (г) — код 1 |
| B-AR-11 | major | **частично**: `error_qr_unavailable` исправлен, `role_*` 7/7; 22 `error_*` и 22 `status_*` ждут текстов владельца 03 (до RM-C-002); `--strict-coverage` в CI — после этого | `build_arb.py`: `error_qr_unavailable` — нейтральный текст 02 «QR временно недоступен» (`KERNEL_OVERRIDES`, ядро §24.4); `role_*` — названия ролей из 07 §5.4 `roles.name_ru`. Тексты ошибок и статусов не придуманы (`contracts/l10n/NOTES.md` §4) |
| B-AR-12 | major | **передано владельцу** 06 §7.3 (вне назначенных путей) | Предложение: имена очередей и payload — `common/jobs/contracts/**`, правило BE-06 (`contracts/openapi/NOTES.md` §8.2); кода `pos-api/src/` ещё нет — срок RM-C-005 |
| B-AR-13 | minor | **исправлено** (контракт) | `POST /orders/{id}/payments`: ответ `503` → `ServiceUnavailable` (`QR_UNAVAILABLE` только `QR_PROVIDER=bakai`) |
| B-AR-14 | minor | **исправлено** (контракт) | `CatalogSyncResponse.x-entity-schema` — соответствие `entity → схема`; сверяется с `anyOf` скриптом словарей |
| B-AR-15 | minor | **вынесено на G-B2** (без правок) | Постановка этапа B требовала хранить A для справки, 03 §17.2/§5.9 п.8 описывают `DsColors.lightA`; удаление противоречило бы 03. Варианты решения — `contracts/design-tokens/NOTES.md` п.1 |
| B-AR-16 | minor | **исправлено** (контракт) | `Profile.birthYear` — `minimum: 1920` (как запросы и CHECK 07); `X-Step-Up-Token` — описание: `required: false` по технической причине, без токена там, где он обязателен, — `403 STEP_UP_REQUIRED` |
| B-AR-17 | minor | **передано владельцу** 06 (вне назначенных путей) | `CustomerView*` оставлены эталонами контрактных тестов; предложение `CustomerProjector.forRole()` — `contracts/openapi/NOTES.md` §8.2 |
| B-AR-18 | minor | **передано владельцу** 13 (вне назначенных путей) | Предложение заменить `x-permission` на `x-permissions` в AC RM-B-008 |
| B-AR-19 | minor | **исправлено** п.1 (DDL); п.2 — правило ретенции записано, DDL без изменений (DATA-004 сохранён) | `product_images_primary_uq` включает `category_id`; ретенция `sync_runs` — удалять прогоны старше 90 дней без ссылок (SQL — `pos-api/migrations/NOTES.md` §10), предложение 07 §13.3 |
| B-AR-20 | minor | **исправлено** (DDL); 06 §7.6 — предложение | `check_row_version()`: +1 для всех писателей, проверка «+1» только для `pos_app`; `payments` — `trg_payments_row_version` (`bump_row_version()`). Проверено: системный писатель и суперпользователь поднимают версию, `pos_app` без инкремента отклоняется |
| B-AR-21 | minor | **передано владельцам** 06 §7.4 (а), 07 §5.28 | Предложение «столбец → писатель» и upsert только реплицируемых столбцов — `pos-api/migrations/NOTES.md` §10 |
| B-AR-22 | minor | **передано владельцу** 06 §6.1 | Предложение read-model `customers/domain/CustomerOrderSummary` — `contracts/openapi/NOTES.md` §8.2 |
| B-AR-23 | minor | **исправлено** (контракт 1С, заметки) | `contracts/onec/NOTES.md` §6 «Журнал версий контракта» (v1.0.0 — черновик для согласования, 28 мест `proposed`, порядок правок ONEC-074); абзац «Статус `x-status: proposed`» в `info.description` контракта |

Не обновлялось (вне назначенных путей): `docs/erd/README.md` (новые столбцы `user_roles.id`, `idempotency_keys.subject_key`,
`sync_entity_versions.onec_key`), `docs/stages/B_changes.md`, документы ТЗ 03, 05, 06, 07, 08, 12, 13.

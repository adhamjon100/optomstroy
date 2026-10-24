# Контракт OpenAPI `pos-api` v1: заметки и правила для авторов модулей

RM-B-003. Это часть 1: корень и общие компоненты. Файл — `parts/00_root.yaml`.

Источник истины — `docs/specification/08_API_SPECIFICATION.md` v1.9: §2 (конвенции), §3 (общие схемы), §8 (скелет OpenAPI и правила генерации).

Для словарей действуют документы-владельцы:

| Словарь | Владелец |
|---|---|
| enum-ы и CHECK-перечни | 07 §6.1 и §6.1.1 |
| `permissions` | 11 §4.3 |
| матрица «роль × право» | 11 §4.4 |
| коды ошибок | 08 §2.4 |
| значения `operation` для step-up | 08 §2.12 |
| переменные окружения | 16 §4.3 |

Ядро R0 v1.9 (§24) имеет приоритет над всеми документами.

## 1. Структура

```
contracts/openapi/
  parts/00_root.yaml          — openapi, info, servers, security, tags, components, paths: {}
  parts/NN_<module>.yaml      — фрагменты модулей: только paths (+ свои components)
  pos-api.v1.yaml             — собранный файл (результат сборки RM-B-003)
  NOTES.md                    — этот файл
```

- Части модулей — это **фрагменты**, а не самостоятельные документы. В них нет ключей `openapi`, `info`, `servers`, `security` и `tags`. Есть только `paths:` и при необходимости `components:` (`schemas`, `parameters`, `responses`) со **своими** именами.
- Сборщик объединяет `paths` и `components` всех частей с `00_root.yaml` в один документ. Поэтому во фрагментах ссылки пишутся так, как будут выглядеть в собранном документе: `$ref: "#/components/schemas/Money"`. Префикс файла (`00_root.yaml#/...`) не пишется. Lint отдельного фрагмента не имеет смысла: проверяется только собранный файл.
- Переопределять имена из `00_root.yaml` во фрагментах **запрещено**: одинаковое имя в двух частях — ошибка сборки. Если общей схеме нужно новое поле, его добавляют в `00_root.yaml` и записывают решение в этот файл. Вариант «своя копия схемы в модуле» не допускается.
- Нумерация `NN` — по порядку модулей 08 §4, если постановка задачи не задаёт иное: `01_auth`, `02_registration`, `03_me`, `04_catalog`, `05_search`, `06_inventory`, `07_cart`, `08_orders`, `09_payments`, `10_pos`, `11_customers`, `12_receivables_discounts`, `13_favorites`, `14_transactions`, `15_returns`, `16_notifications`, `17_sync`, `18_admin`, `19_health`, `20_integrations`, `21_settings`.

## 2. Ссылки на общие компоненты

| Что | Ссылка |
|---|---|
| Деньги, количество | `#/components/schemas/Money`, `Quantity`; строковые примитивы: `MoneyAmount` (query `priceMin` и т. п.), `QuantityValue`, `Percent`, `PhoneE164`, `PhoneMasked` |
| Ошибка | `#/components/responses/<Класс>` (ниже); схема — `#/components/schemas/Problem`, код — `ProblemCode` |
| Предупреждения | `warnings: { type: array, items: { $ref: "#/components/schemas/Warning" } }` |
| Пагинация | `allOf: [ { $ref: "#/components/schemas/Page" }, { type: object, properties: { items: { type: array, items: { $ref: "#/components/schemas/<T>" } } } } ]` — именованные схемы `XxxPage` **не** создаются |
| Параметры | `#/components/parameters/{DeviceId, AppVersion, Platform, RequestId, AcceptLanguage, IdempotencyKey, IdempotencyKeyOptional, StepUpToken, IfNoneMatch, Limit, Cursor, Sort, Q, From, To, IdPath}` |
| Заголовки ответов | `#/components/headers/{XRequestId, RetryAfter, IdempotentReplayed, XDataAsOf, XMinAppVersion, XRecommendedAppVersion, ETag, CacheControl, ContentLanguage, Location, XRateLimit*}` |
| Enum-ы | `OrderStatus`, `PaymentStatus`, `PaymentMethod`, `RoleCode`, `PermissionCode`, `SyncEntity` и др. — имена 07 §6.1 в PascalCase. Значения enum **не копируются** во фрагменты: только `$ref` |

### Стандартные ответы ошибок

| HTTP | `$ref` | Коды 08 §2.4 |
|---|---|---|
| 304 | `NotModified` | ETag совпал |
| 400 | `BadRequest` | `VALIDATION_FAILED` (схема, лишние поля, `forbidden_field`, `idempotency_key_required`) |
| 401 | `Unauthorized` | `UNAUTHENTICATED`, `TOKEN_STALE`, `SESSION_REVOKED`, `REGISTRATION_TOKEN_INVALID`, `PIN_INVALID`, `UNLOCK_REQUIRED`, `WEBHOOK_SIGNATURE_INVALID` |
| 403 | `Forbidden` | `FORBIDDEN`, `STEP_UP_REQUIRED` |
| 404 | `NotFound` | `NOT_FOUND` |
| 405 | `MethodNotAllowed` | `METHOD_NOT_ALLOWED` |
| 409 | `Conflict` | `VERSION_CONFLICT`, `IDEMPOTENCY_IN_PROGRESS`, `ORDER_STATE_INVALID`, `PAYMENT_STATE_INVALID`, `PHONE_ALREADY_REGISTERED`, `DEVICE_MISMATCH`, `CUSTOMER_LINK_CONFLICT`, `CUSTOMER_DUPLICATE_SUSPECTED`, `SYNC_ALREADY_RUNNING` |
| 413 / 415 | `PayloadTooLarge` / `UnsupportedMediaType` | — |
| 422 | `UnprocessableEntity` | бизнес-валидация |
| 423 | `Locked` | `OTP_LOCKED`, `PIN_LOCKED` |
| 426 | `UpgradeRequired` | `APP_UPDATE_REQUIRED` |
| 429 | `TooManyRequests` | `RATE_LIMITED`, `OTP_RATE_LIMITED` |
| 500 | `InternalError` | `INTERNAL` |
| 503 | `ServiceUnavailable` | `SMS_PROVIDER_ERROR`, `ONEC_UNAVAILABLE`, `QR_UNAVAILABLE`, `APP_READ_ONLY` |

В каждой операции явно перечисляются статусы из строки «Ошибки» карточки 08 §4. Защищённые операции дополнительно перечисляют `401` и `403`. Остальные статусы закрывает `default: { $ref: "#/components/responses/Problem" }`. Хотя бы один `4xx` должен быть указан явно: одного `default` недостаточно, иначе Redocly выдаёт предупреждение `operation-4xx-response`. Коды, которые возможны в ответе операции, перечисляются в `description` ответа.

## 3. Правила для операций (по 08 §2 и §8)

1. Тег — ровно один, из списка `tags` корня (22 тега 08 §8). Модуль D-06 указан в расширении `x-module` тега.
2. `operationId` имеет вид `<module>_<action>` в snake_case по тегу: `orders_create`, `auth_otp_request` (08 §8).
3. Безопасность:
   - по умолчанию действует глобальная `bearerAuth`;
   - публичные эндпоинты (08 §2.2, §3.15 «без access JWT») указывают `security: []`;
   - операции со step-up указывают `security: [ { bearerAuth: [], stepUpToken: [] } ]` и параметр `#/components/parameters/StepUpToken` (так в 08 §8);
   - `/integrations/onec/*` указывают `security: [ { integrationToken: [] } ]`;
   - вебхук банка указывает `security: [ { webhookSignature: [] } ]`.
4. Заголовки запроса:
   - `DeviceId` — во всех операциях, кроме `/health*`, `POST /payments/qr/webhook`, `/integrations/onec/*` и `POST /integrations/smspro/dlr`;
   - `AppVersion` и `Platform` — во всех операциях, кроме вебхука и `/integrations/*` (в R1 `required: false`, Q-153);
   - `RequestId` и `AcceptLanguage` — по желанию автора, но единообразно внутри модуля.
5. Идемпотентность:
   - для операций из перечня 08 §2.7 «Где обязателен» используется `#/components/parameters/IdempotencyKey` (обязательный);
   - для прочих `POST`, `PUT` и `PATCH` — `IdempotencyKeyOptional`;
   - для `GET` и `DELETE` параметр не указывается;
   - ответ `2xx` таких операций несёт заголовок `Idempotent-Replayed` (`$ref: "#/components/headers/IdempotentReplayed"`).
6. Тела запросов: всегда `additionalProperties: false` (08 §2.11, защита от mass assignment). Поля `price`, `unitPrice`, `total`, `subtotal`, `discountAmount`, `lineTotal`, `amount` в телах корзины и заказа, а также `roles`, `permissions`, `status` в `PATCH /me/profile` в схемы **не включаются** (08 §2.14). Списки `items` — `maxItems: 200`, прочие массивы — `maxItems: 500`. Строки — с `maxLength`.
7. Ответы `2xx`: заголовки `X-Request-Id`, `X-Min-App-Version` и `X-Recommended-App-Version`, а также `ETag` или `X-Data-As-Of` там, где их требует 08 §2.8 или §2.3.
8. Схемы, специфичные для модуля, получают **префикс модуля** — PascalCase-имя тега: `OrdersCreateRequest`, `CartPutItemRequest`, `AdminSettingsResponse`, `SyncRunCreateRequest`. Исключения — имена, явно заданные в 08 §4 и §8; они сохраняются как есть: `OtpVerifyRequest`, `AuthAuthenticated`, `AuthPendingActivation`, `AuthRegistrationRequired`, `AdminUser`. Поля — camelCase, enum-значения — snake_case ровно как в 07.
9. Nullable (OAS 3.0.3, правило Redocly `nullable-type-sibling`):
   - рядом с `nullable: true` обязателен `type`;
   - ссылка на схему пишется так: `type: object` (или `string`), `nullable: true`, `allOf: [ { $ref: ... } ]`;
   - во встроенных enum с `nullable: true` в список значений добавляется `null`.
10. Поля, видимые не всем ролям, помечаются `x-roles` на уровне свойства схемы ответа (field-level allowlist, 08 §3, ASVS 8.2.3). Поле, не разрешённое роли, **отсутствует** в ответе, а не равно `null`.

## 4. Расширения `x-*` (уровень операции)

| Расширение | Значение | Правило |
|---|---|---|
| `x-permissions` | массив кодов `PermissionCode` (11 §4.3) | Коды, которые сервер проверяет на операции (08 §3.15). Альтернативы перечисляются все: `[order.read.own, order.read.all]`. Для публичных операций — `[]`. Код `integration` — `[sync.exchange]` |
| `x-roles` | массив `RoleCode` | Роли, допущенные к операции по 11 §4.4 и 08 §9. На свойствах схем — field-level видимость |
| `x-step-up` | `true` / `false` | `true`, если операция требует или может требовать `X-Step-Up-Token` (08 §2.12, «S!» в 08 §3.15). Условие («только для чужой сессии», «только при `include=documents`», «только с `discountOverride`») описывается в `description` |
| `x-step-up-operation` | массив `StepUpOperation` | Значения `operation` из 08 §2.12, которые сервер вернёт в `403 STEP_UP_REQUIRED`. Обязательно при `x-step-up: true` |
| `x-idempotent` | `required` / `true` / `false` | `required` — ключ обязателен (перечень 08 §2.7); `true` — ключ допускается; `false` — не применяется. Машинно проверяемая истина — параметр `IdempotencyKey` или `IdempotencyKeyOptional` (п. 3.5); значения обязаны совпадать |
| `x-feature-flag` | строка `NAME` или `NAME=value` | Флаг развёртывания, без которого маршрут выключен (`404`) или работает иначе. Имена — переменные окружения 16 §4.3 и ядра §17.7 или ключи `app_settings` 07: `DEBT_PAYMENTS_FROM_POS`, `QR_PROVIDER=bakai`, `ONEC_INBOUND_ENABLED`, `SMSPRO_DLR_MODE=push`, `CUSTOMER_SELF_SERVICE`, `RETURNS_FROM_POS_ENABLED=false`, `returns_enabled` |
| `x-status` | `proposed` | Только для условных путей до решения заказчика «да» (13 RM-B-003, §5.4 п. 5; например `POST /payments` — Q-152). Если расширения нет, путь принят. R2-пути в контракт R1 не входят совсем |
| `x-rate-limit-group` | `RL-*` (08 §2.9) | Группа лимита (08 §8). Для `/integrations/onec/*` — `RL-INTEGRATION` (08 §4.21) |

## 5. Решения и отклонения, принятые в `00_root.yaml`

1. **Имя расширения прав.** В постановке задачи — `x-permission` (код), в 08 §8 (владелец правил генерации) — `x-permissions: [...]` (массив). Принят вариант владельца: `x-permissions`, массив. Массив нужен потому, что на многих операциях проверяется одна из нескольких альтернатив (`order.read.own` / `order.read.all`). Написание `x-permission` в частях модулей не используется. Если оно встретится, при сборке его нужно привести к `x-permissions: [<код>]`.
2. **Значения `x-idempotent`.** В постановке — `true`/`false`, в 08 §8 — `true|required`. Принято объединение: `required | true | false`. Значение `true` означает «допускается», а **не** «обязательно» (п. 4).
3. **Теги.** Взяты 22 тега скелета 08 §8. Тег `me` соответствует модулю D-06 `profile`. Теги `search` и `inventory` относятся к `catalog`, `receivables`, `discounts` и `favorites` — к `customers`, `pos` — к `payments` (11 §4.3 №39), `settings` — к `admin`. Соответствие записано в `x-module` каждого тега.
4. **`Customer` по ролям.** `Customer` — надмножество полей 08 §3.7 с `x-roles` на полях. Строгие представления сделаны как `additionalProperties: false`: они нужны для контрактных тестов allowlist.

   | Схема | Роли |
   |---|---|
   | `CustomerViewSeller` | `seller` |
   | `CustomerViewCashier` | `cashier`, `senior_seller` |
   | `CustomerViewAdmin` | `admin`, `owner` |
   | `CustomerViewSelf` | `customer`, только `confirmed` |

   Имена `CustomerView*`, `ReceivableBadge` (имя из 08 §3.7), `ReceivableSummary`, `PriceListRef`, `CustomerPhone` и `CustomerContact` — структурные. Их состав полей — ровно как в таблице и примерах 08 §3.7. `Cart.customer` и `Order.customer` ссылаются на `Customer`: в списках и встраиваниях сумм долга нет, только флаги.
5. **Вынесенные вложенные объекты.** Из псевдосхем 08 §3 вынесены именованные схемы, поля которых взяты из 08 без изменений, а имена новые:
   - `MoneyRange`, `OrderOnecInfo`, `OrderDocuments`, `OrderDocumentAvailability`, `OrderStatusHistoryEntry`;
   - `PaymentAllocation`, `PaymentOnecInfo`, `TransactionRelated`, `ReturnRequestItem`;
   - `SyncCounts`, `MeCustomerLink`, `ReceivableDocument`;
   - `CartItemWarning`, `CartConflictKind`, `ProblemFieldError`, `ProblemResource`;
   - `DeliverySlot`, `SupportContact`.
6. **Enum-ы.** Значения взяты из 07 §6.1 и §6.1.1 (владелец).
   - `Me.status` ссылается на `UserStatus`, где есть и `deleted` (07). В 08 §3.14 перечислены 4 значения; надмножество допустимо, клиент обрабатывает неизвестное значение как `unknown` (08 §2.11).
   - `StepUpMethod` — `pin | biometric | otp` (07). В `Problem.stepUp.allowedMethods` для R1 — только `pin`, `otp` (ядро §19.3).
   - `QrProvider` — свойство QR: `onec | bakai | elqr_static | none`. `QrProviderMode` — значение env `QR_PROVIDER`: `none | onec | bakai` (ядро §24.4).
7. **`Problem`.** К полям 08 §3.3 добавлены поля, которые 08 §2.4 прямо называет в ответах: `creditReason`, `overdueAmount`, `asOf`, `openPaymentId`. `stepUp.operation` типизирован как `StepUpOperation` (08 §2.12). `ProblemCode` — полный перечень 08 §2.4 (50 кодов); он совпадает с enum скелета 08 §8. Коды предупреждений (`WarningCode`) в него не входят. Коды журнала синхронизации — отдельный enum `SyncErrorCode` (14 значений, 07 §6.1.1).
8. **`CartConflict.oldPrice` / `newPrice` — тип `Money`** по псевдосхеме 08 §3.8 (владелец DTO). Пример problem+json в 08 §2.4 показывает голые строки `"2350.00"`. Это расхождение 08 надо выровнять у владельца: пример 08 §2.4. `CartConflict.stockLevel` добавлен по тексту 08 §3.6: при `customer_stock_display=status` конфликт возвращается без чисел, но с `stockLevel`.
9. **`Delivery.geo` не включён:** это R2 (Q-178). В R1 поле в теле запроса даёт `VALIDATION_FAILED` с `rule: forbidden_field` (ядро §19.4). `Delivery`, `Receiver`, `PrintOptions`, `Money` и `Quantity` используются в телах запросов, поэтому у них `additionalProperties: false`.
10. **`warnings[]`** добавлен в `Order`: ответ `202` `POST /orders` — это `Order` + `warnings` (08 §4.8.1). Он же добавлен в `CheckoutPreview` и уже был в `Payment` (08 §3.10) — по общему правилу 08 §2.4: успешный ответ может нести `warnings[]`.
11. **Nullable и `allOf`.** По требованию Redocly (`nullable-type-sibling`) рядом с `allOf` указан `type`. Строгие валидаторы OAS 3.0.3 не считают `null` допустимым для nullable-ссылки на enum без `null`, хотя генераторы (`dart-dio`, `@nestjs/swagger`) трактуют такую ссылку как nullable. Риск принят, это обычная практика 3.0.x.
12. **Добавленные схемы безопасности.**
    - `integrationToken` (`http bearer`, непрозрачный токен роли `integration`) добавлен по 08 §4.21 — в скелете 08 §8 его нет.
    - `stepUpToken` и `webhookSignature` взяты из 08 §8.
13. **`Invitation` и `PublicSettings`** вынесены в корень, как указано в постановке. Состав полей — 08 §4.18.4 и §4.23.1. Схемы `AdminUser`, `AuditRow`, дашборд кассира, тела запросов и ответы отдельных операций — зона фрагментов модулей (`admin`, `pos` и др.). Схемы `OtpVerifyRequest` и `Auth*` из 08 §8 определяет фрагмент `auth` с теми же именами.
14. **`info.license` не задан:** в ТЗ лицензии нет. Redocly выдаёт предупреждение `info-license`, это ожидаемо.
15. **Плейсхолдер домена.** В `servers` — `https://api.{domain}/api/v1` и `https://api-test.{domain}/api/v1` с `default: "<домен>"` (08 §8, Q-032). Пример `Problem.type` не задан, потому что `<домен>` не является корректным URI. Вместо примера — описание.
16. **Типы и форматы.**
    - `Order.paymentDueDate` — `format: date` (пример 08 «2026-11-01»).
    - `Payment.onec.docType` — enum с кириллическими значениями 1С `[ТИПОВО: Q-012]`.
    - `StockBalance.available`, `CartItem.available` и `Product.availableTotal` допускают отрицательное значение: `out` означает `available ≤ 0`, 08 §3.6.

## 6. Проверки части 1

1. Синтаксис и структура: `npx --yes @redocly/cli@2 lint contracts/openapi/parts/00_root.yaml`. Ожидается 0 ошибок. Предупреждения: `no-unused-components` (компоненты пока не используются путями — пути добавят фрагменты) и `info-license`.
2. Сверка со словарями ТЗ (детерминированно, без сети):
   - `ProblemCode` = 08 §2.4;
   - `PermissionCode` = 11 §4.3;
   - enum-ы = 07 §6.1 и §6.1.1;
   - `StepUpOperation` = 08 §2.12;
   - теги = 08 §8;
   - все `$ref` разрешаются;
   - примеры `Customer` из 08 §3.7 валидны по ролевым представлениям;
   - негативные случаи отвергаются.

   Скрипт сверки перенесён в репозиторий по B-AR-10 (в): `python -I -X utf8 scripts/check_openapi_dictionaries.py`
   (запуск после сборки; `$ref` корня разрешаются по собранному `pos-api.v1.yaml`, потому что корень может ссылаться
   на схему модуля — `Customer.discounts` → `CustomersDiscountsResponse`). Треугольник `enums.json` ↔ `CREATE TYPE` ↔
   enum-схемы OpenAPI — `scripts/check_enum_triangle.py` (B-AR-10 (г)).

## 7. Сборка `pos-api.v1.yaml` и проверки (RM-B-003, часть сборки)

### 7.1. Команды

```
python -I -X utf8 scripts/build_openapi.py            # собрать contracts/openapi/pos-api.v1.yaml
python -I -X utf8 scripts/build_openapi.py --check    # код 1, если файл на диске отличается от сборки (дрейф)
npx --yes @redocly/cli@2 lint contracts/openapi/pos-api.v1.yaml   # 0 ошибок
python -I -X utf8 scripts/check_api_paths.py -v       # пути и методы ядра §7, §17.4, §19.2, §22–§24 и карточек 08 §4
python -I -X utf8 scripts/check_api_permissions.py --require-operations   # x-permissions ↔ 11 §4.3–§4.4 (RM-B-008)
python -I -X utf8 scripts/check_openapi_dictionaries.py   # корень ↔ словари 07/08/11, примеры 08 §3.7 (B-AR-10 (в))
python -I -X utf8 scripts/check_enum_triangle.py          # enums.json ↔ DDL ↔ OpenAPI (B-AR-10 (г))
```

Журнал прогона этапа B — `docs/stages/B_checks.log`.

### 7.2. Правила сборщика (решения, принятые при сборке)

1. **Ключи `openapi` и `info` во фрагментах.** §1 говорит, что их во фрагментах нет, но все шесть фрагментов
   их содержат (авторы оставили их, чтобы фрагмент был самостоятельным YAML-документом). Сборщик их
   **игнорирует**: `openapi` обязан совпадать с корнем, `info` фрагмента в сборку не попадает. Прочие ключи
   верхнего уровня (`servers`, `security`, `tags`, `x-*`) во фрагменте — ошибка сборки.
2. **Конфликты.** Одинаковое имя в `components.<секция>` двух частей с разным содержимым — ошибка; с
   одинаковым — дубликат, сливается с сообщением. Для `paths`: один путь в нескольких частях допустим только
   с разными методами; одинаковый метод с разным содержимым — ошибка.
3. **Сортировка.** Пути — по алфавиту; методы внутри пути — в порядке OAS (`get, put, post, delete, options,
   head, patch, trace`); секции `components` — в порядке OAS 3.0, имена внутри секции — по алфавиту. Порядок
   ключей внутри операций и схем сохраняется авторский. Повторная сборка даёт тот же файл байт-в-байт.
4. **Инварианты сборки:** `operationId` обязателен и уникален; тег операции — из `tags` корня; все `$ref`
   локальные (`#/...`) и разрешаются в собранном документе; повторяющиеся ключи YAML в части — ошибка.
5. **Комментарии частей в сборку не переносятся** (YAML-комментарии теряются). Решения авторов фрагментов
   остаются в шапках частей и являются частью этих заметок:
   `10_auth.yaml` — A1–A9; `20_catalog.yaml` — 10 решений; `30_cart_orders.yaml` — F1–F12;
   `40_payments_pos_returns.yaml` — п. 1–10; `50_customers.yaml` — комментарии и `description`;
   `60_sync_admin_ops.yaml` — шапка файла.
6. **Версия при уточнении описаний** (ревью закрытия F, второй круг, RS-7). Правка только текста описаний
   (`description`, без схемы, путей, прав и `x-*`) в версии, ещё не выпущенной (не принятой воротами этапа),
   вносится в раздел этой версии CHANGELOG «Уточнено» без повышения `info.version`; после выпуска — патч
   (`x.y.z+1`) с отдельной записью и одновременной правкой `OPENAPI_INFO_VERSION` в `pos-api`.

### 7.3. Решения `scripts/check_api_paths.py`

1. Обязательные операции извлекаются из документов (не из списка в скрипте): ядро §7 (пути без методов —
   путь обязан существовать с любым методом), §17.4, §19.2, §22–§24 (кроме методов расширения 1С `/pos/v1/*`)
   и заголовки карточек 08 §4.x.y. Альтернативы раскрываются (`{invoice|waybill|receipt}.pdf`,
   `request|confirm`, `{products|customers}`); параметры пути сравниваются нормализованно, для карточек 08
   (владелец имён) — также по именам параметров (`{sessionId}`, `{challengeId}`, `{outboxId}`).
2. Query-часть в ядре (`GET /payments/{id}?wait=`, `GET /orders?include=`, `?idempotencyKey=`,
   `GET /customers?linkStatus=`, `GET /catalog/sync/{entity}?since=&limit=`) проверяется как наличие
   query-параметра у операции. Дополнительно: `Limit.maximum = 200`, сортировки `available:desc`, `sku:asc`
   у `/catalog/products` и `/search/products` (ядро §19.2).
3. Запрещены: список 13 RM-B-003 (`DELETE /admin/users/{id}/sessions`, `/integrations/onec/heartbeat` — любой
   метод, `POST /registration/customer-match`, `PATCH /customers/{id}/contacts`, `POST /registration/face-scan/verify`)
   и операции абзацев 08 §4.20 «Не в R1 (R2)» и «Эндпоинты R5 §5.2, не вошедшие в ядро §7».
4. **Лишняя операция** (нет ни в ядре, ни в карточках 08) — ошибка: контракт R1 не расширяется без записи в 08.

### 7.4. Пробелы ТЗ, найденные при сборке (решение владельца, в контракте не выдуманы)

1. `WarningCode` (08 §2.4) не содержит `ambiguous_barcode`, который требует 08 §4.5.2 для
   `GET /search/barcode/{value}`. Владелец — 08 §2.4; до решения предупреждение в контракте не выражается.
2. ~~08 §4.11.5: ответ `200` с `balance: null, reason: not_in_onec` не выражается схемой `Receivable`.~~ **Закрыто
   (B-AR-06):** `balance` и `asOf` — nullable, добавлено `reason` (`not_in_onec`); см. §8. Правка 08 §3.7 — у владельца.
3. ~~`GET /customers/{id}?include=discounts`: состав блока не задан.~~ **Закрыто (B-AR-06):** `Customer.discounts` =
   `CustomersDiscountsResponse` (тот же состав, что ответ `GET /customers/{id}/discounts`, 08 §4.11.6, SCR-35); см. §8.
4. `OrderSummary.paymentsSummary` — открытый объект (08 §4.8.2 состав не раскрывает);
   `GET /orders/{id}/payments` — `{ items: Payment[] }` без пагинации (08 §4.8.6 формат не задаёт).
5. `info.license` не задан (в ТЗ нет) — предупреждение Redocly `info-license` ожидаемо.
6. Неиспользуемые компоненты (предупреждения `no-unused-components`) оставлены намеренно:
   `CustomerViewSeller|Cashier|Admin|Self` и `ReceivableBadge` — эталонные ролевые представления для контрактных
   тестов allowlist (§5 п. 4; по B-AR-17 сериализация — единый `CustomerProjector.forRole()`, предложение 06, §8); `OtpPurpose`, `PrintDocumentKind` — enum-ы 07 §6.1; `Sort` — общий параметр
   08 §2.6 (модули объявляют `sort` со своим enum); `MethodNotAllowed` — ответ 405 08 §2.4.
7. Предупреждения `check_api_permissions.py` [A] «роль держит код операции, но не в `x-roles`» (9 операций) —
   условия карточек 08 (например, `DELETE /me/pin` — только `customer`, D-48); ошибок нет.

## 8. Исправления по архитектурной проверке этапа B (2026-10-21)

Источник — `docs/reviews/B_architecture_review.md`. Документы ТЗ (08, 06, 12, 13) в этой задаче не правятся — путь вне
назначенных. В контракте сделано то, что выражается схемой или описанием операции; правки текста ТЗ — предложения
владельцам ниже. Версия `info.version` не повышается: контракт ещё не опубликован (до ворот G-B2), см. CHANGELOG.

### 8.1. Изменения контракта

| Замечание | Где | Что сделано |
|---|---|---|
| B-AR-01 (критично) | `parameters.IdempotencyKey`, `POST /registration/complete` | Скоуп ключа: `(key, субъект, маршрут)`; у публичной регистрации субъект — SHA-256 от `jti` `registrationToken` (БД — `idempotency_keys.subject_key`, migrations NOTES §10). Повтор регистрации выдаёт новую пару токенов для сессии, созданной первым вызовом (токены в `idempotency_keys` не хранятся, 07 §5.56) |
| B-AR-02 (критично) | `AdminUsersCreateRequest.roles`, `AdminUsersRolesSetRequest.roles` | `maxItems: 1` в R1 — больше одной роли → `400 VALIDATION_FAILED` по схеме вместо `500` из БД; расширение после Q-005 — expand-изменение. `Me.roles`, `AdminUser.roles` — массивы без изменений |
| B-AR-04 | `parameters.IdempotencyKey`, `headers.IdempotentReplayed`, `POST /orders`, `POST /orders/{id}/payments`, `POST /payments` | Для операций с шагом после COMMIT (формирование QR) повтор возвращает **текущее** представление ресурса (по сохранённому идентификатору) с тем же статусом и `Idempotent-Replayed: true` |
| B-AR-05 | `IntegrationsOnecChangeObject.ref` | `string`, 1…150 символов; формат по `objectType` (GUID для `Catalog_*`/`Document_*`, ключ набора для `InformationRegister_*`) проверяет сервер, ошибка объекта → `sync_errors`, пакет целиком не отвергается |
| B-AR-06 | `Receivable`, `Customer` + 4 `CustomerView*` | `balance`, `asOf` — nullable; `reason` (`not_in_onec`); блок `discounts` = `CustomersDiscountsResponse` при `include=discounts` |
| B-AR-07 (частично) | `CheckoutPreview.previewToken` | Описание: токен непрозрачен; предложено включить `onecCheck.at` и хэш результата в подпись. Сам процесс — 06/08 (ниже) |
| B-AR-13 | `POST /orders/{id}/payments` | Ответ `503` (`ServiceUnavailable`, `QR_UNAVAILABLE` только при `QR_PROVIDER=bakai`, R2) |
| B-AR-14 | `CatalogSyncResponse` | Расширение `x-entity-schema` (entity → схема элемента `items`); клиент декодирует в одной точке data-слоя по `entity` пути |
| B-AR-16 | `Profile.birthYear`, `parameters.StepUpToken` | `minimum: 1920` (как в телах запросов и CHECK 07 `user_profiles.birth_year`); в описании `X-Step-Up-Token` — почему `required: false` и что без него сервер вернёт `403 STEP_UP_REQUIRED` |

Машинная проверка этих правок — раздел 7 `scripts/check_openapi_dictionaries.py`.

### 8.2. Предложения владельцам документов ТЗ (не внесены — путь вне назначенных)

| Замечание | Владелец | Предлагаемая правка |
|---|---|---|
| B-AR-01 | 08 §2.7 «Скоуп», 07 §5.56 | «Скоуп — `(key, subject, route)`: `subject` = `user:<userId>`; для `POST /registration/complete` — `reg:<sha256(jti registration_token)>`»; строка «Повтор `/registration/complete`: тот же статус и тело, токены выдаются заново для сессии первого вызова» |
| B-AR-02 | 08 §4.18.1–§4.18.2 | «`roles` — ровно один элемент в R1 (`maxItems: 1`); расширение — после Q-005» |
| B-AR-04 | 08 §2.7, 12 | Строка «Повтор операции с шагом после COMMIT (`POST /orders`, `POST /orders/{id}/payments`, `POST /payments` с QR) — текущее представление ресурса по `idempotency_keys.resource_id`, `Idempotent-Replayed: true`»; тест 12: повтор `POST /orders` с тем же ключом после выдачи QR возвращает платёж `qr_shown` с `qr` |
| B-AR-05 | 08 §4.21.1, 05 §10.1 | `ref` — строка ≤ 150, формат по `objectType` |
| B-AR-06 | 08 §3.7 | `Receivable.balance`/`asOf` — `Money|null`/`date-time|null`, `reason: not_in_onec|null`; состав блока `include=discounts` = ответ §4.11.6 |
| B-AR-07 | 06 §7.4, 08 §3.8 | `CheckoutPolicy` — domain-сервис модуля `cart`, экспорт `CartService.validateForCheckout(tx?, input)`; его вызывают `POST /cart/checkout-preview` и `orders.create` (ребро `orders → cart` уже есть); добавить ребро `cart → sync` (`OnecCheckService.verifyOrder`); `previewToken` = HMAC(`cartRowVersion`, итоги, `validUntil`, `onecCheck.at`, sha256(результат `/check`)) — `POST /orders` в пределах 60 с (05 SYNC-071) повторно `/check` не вызывает |
| B-AR-08 | 06 §7.2 п.2, 07 §9.3 | «Бизнес-транзакции — только `READ COMMITTED`; `AuditWriter.append` — последняя запись перед COMMIT»; нагрузочный тест NFR-PERF-004 с параллельными заказами и синхронизацией (этап F); при нехватке пропускной способности — фоновый писатель цепочки |
| B-AR-12 | 06 §7.3, §5.2 | Имена очередей pg-boss и типы payload (`*.onec-confirmed`, `*.onec-failed`, `catalog.*-changed`) объявляются в `common/jobs/contracts/**` без импорта модулей; правило lint BE-06 (отчёт §5.2) |
| B-AR-17 | 06 §7.4 | Один `CustomerProjector.forRole(role, customer, include)` в модуле `customers`; `GET /customers/{id}`, `Cart.customer`, `Order.customer` используют его; контрактные тесты — по `CustomerView*` |
| B-AR-18 | 13 RM-B-008 (AC) | Заменить `x-permission` на `x-permissions` (массив кодов), как в 08 §8 и в контракте (§5 п.1) |
| B-AR-21 | 06 §7.4 (а), 07 §5.28 | Таблица «столбец → писатель» `customers` (migrations NOTES §10) |
| B-AR-22 | 06 §6.1 | Фича `customers` — собственный read-model `customers/domain/CustomerOrderSummary` для истории покупок (SCR-31/SCR-33); переход к заказу — по маршруту `go_router`, без импорта `orders` |

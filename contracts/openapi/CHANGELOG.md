# CHANGELOG — контракт `pos-api` (`contracts/openapi/pos-api.v1.yaml`)

Формат — по [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/); версия — `info.version` контракта
(SemVer: мажор — несовместимое изменение путей/полей, минор — добавление, патч — уточнение описаний).
**Исключение для не выпущенной версии** (ревью закрытия F, второй круг, RS-7): пока версия не выпущена — не принята
воротами этапа, в котором внесена (для 1.2.0 — ворота G-F не закрыты), — уточнения только текста описаний этой версии
вносятся в её же раздел «Уточнено» без повышения `info.version`; после выпуска уточнение описаний — патч. Так уточнён
смысл `Notification.payload.status` в [1.2.0] (PaymentStatus платежа → OrderStatus заказа, RS-1 ревью закрытия F).
Собранный файл не редактируется вручную: правки вносятся в `parts/*.yaml`, затем
`python -I -X utf8 scripts/build_openapi.py` (правила — `NOTES.md` §1, §7).

## [1.2.0] — 2026-10-23 — выравнивание контракта по итогам этапа F (закрытие остатков этапа F)

Аддитивное изменение (MINOR): `info.version` 1.1.0 → 1.2.0. Вносится то, что описано в 08 v1.15 (или 07/05) и что `pos-api`
отдаёт либо должен отдавать по ТЗ (ссылка на § — у каждого пункта); поля, которые сервер пока не отдаёт, — необязательные.
Источник — предложения MINOR 08 §16.11, `docs/stages/F_spec_sync.md` §3; решение — ADR-103 (15, приложение Е); журнал 08 §16.12.
Пути, методы, права и обязательность существующих полей не менялись.

### Добавлено

- `Problem.previewTotal`, `Problem.total` (Money) — `422 PRICE_CHANGED` при несовпадении с `previewToken`; значения `reason`
  `preview_token_invalid` | `preview_cart_changed` | `preview_payment_method_changed` | `preview_total_changed` — в описании
  (08 §2.4 «Уточнения кодов ошибок … этапа F» п. 1, §4.8.1 п. 2; FIX-F-03). Сервер отдаёт (`previewTotal`/`total` — только при
  `reason: preview_total_changed`, см. «Уточнено»).
- `Notification.payload`: `paymentId`, `status`, `cartId`, `entity` (`SyncEntity`), `runId`, `task` (`refund_or_advance`),
  `outboxId`; значение `target = cart_parked` (08 §3.13 «Ключи `Notification.payload`»; FQ-FND-09, FQ-NOTIF-06, FQ-NOTIF-07,
  FIX-F-09). Сервер отдаёт частично: ключи — по видам уведомлений 08 §3.13; `status` у `payment_status` — только с
  `task: refund_or_advance` (статус заказа), статус платежа не передаётся (см. «Уточнено»).
- `GET /cart` → `503` (`ONEC_UNAVAILABLE`, `reason: catalog_not_loaded`, `Retry-After: 60`); `catalog_not_loaded` — в описании
  `Problem.reason` (08 §4.7.1 «Уточнения» п. 2; FIX-F-07). Сервер отдаёт.
- `SyncErrorCode` + `QR_PAID_AFTER_VOID` (15 значений; 08 §2.4 «Коды журнала синхронизации», 07 §5.53, §6.1.1; 05 §6.7.3,
  SYNC-078; FIX-F-06) — одним изменением с `contracts/enums.json` 1.2.0 и expand CHECK `pos-api/migrations/0013`. Сервер пишет
  `QR_PAID_AFTER_VOID`; строки прежних версий `OTHER` + `payload.code` допустимы.
- `Cart.restoredFromOrder` `{number, reason}` — необязательно, nullable (08 §3.8 «Уточнения» п. 4; FQ-CART-05 (fe)). Сервер
  отдаёт.
- `Payment.transactionId` (uuid) — необязательно, nullable (08 §3.10 «Уточнения `Payment`»; 02 UI-24-008; FQ-FEORD-12). Сервер
  пока не отдаёт.
- `Problem.possibleDuplicatePublicNumber`, `Problem.possibleDuplicateCreatedAt` — `409 ORDER_STATE_INVALID`
  `reason: possible_duplicate`, необязательно (08 §4.8.1 «Уточнения» п. 4; FQ-CHK-04). Сервер отдаёт.
- `POST /notifications/read-all` — необязательный query `before` (date-time) (08 §4.16.2 «Уточнения»; FQ-NOTIF-04). Сервер
  отмечает только уведомления с `createdAt` ≤ `before`.

### Не внесено

- `createdAt`/`createdBy` шапки заказа (FQ-FEORD-02) — уже есть в `Order.audit`/`OrderSummary.audit` (`AuditMeta`); бэклог `pos-app`.
- Ключи `payload` `customerId`, `returnId`, `productId`, `variantId` и значения `target` `sync`, `sync_outbox`, `sync_errors` — в 08
  не описаны как ключи/значения сервера (08 §16.12). Решение по `target` (08 §16.13): enum остаётся закрытым, `pos-api` эти
  значения не передаёт (переход уведомлений `sync_error` — по `kind`).

### Уточнено (только текст описаний; схема, пути, права и `x-*` не менялись, `info.version` остаётся 1.2.0 — правка в той же закрывающей итерации, версия не выпущена, см. «Исключение для не выпущенной версии» в шапке; ревью закрытия F, 08 §16.13)

- `Notification.payload.status`: у `payment_status` — только вместе с `task: refund_or_advance`, значение — `OrderStatus` заказа
  (`cancelled`); статус платежа сервер не передаёт (клиент читает `GET /payments/{id}`); у уведомлений синхронизации ключа нет.
  Прежний текст («`payment_status` — `PaymentStatus` платежа; синхронизация — статус прогона») не соответствовал реализации (RS-1).
- `Notification.payload.target`: других значений, кроме перечисленных, сервер не передаёт (RS-2).
- `Problem.previewTotal`, `Problem.total`: передаются только при `reason: preview_total_changed` (прежний текст — «вместе с любым
  `preview_*`»; при `preview_token_invalid` итога токена нет) (RS-3).
- `SyncErrorCode`, `Cart.restoredFromOrder`, `Problem.possibleDuplicatePublicNumber`, `query before` у `read-all`: сняты пометки
  «до правки реализации сервер не передаёт / игнорирует»; правило `before` — `createdAt` ≤ `before`, неверный формат —
  `400 VALIDATION_FAILED` (RS-4, RC-5).

### Уточнено (spec-sync этапа G, 2026-10-24; только текст описаний — схема, пути, права, обязательность и `x-*` не менялись, `info.version` остаётся 1.2.0: версия не выпущена — ворота G-F не закрыты, см. «Исключение для не выпущенной версии» в шапке; 08 §16.15, `docs/stages/G_spec_sync.md`)

Реализация `pos-api` этапа G уже следует уточнённым текстам; прежние тексты расходились с владельцами правил (11, 07) или с
фактическим поведением.

- `customers_discounts_get`: «403 FORBIDDEN (customer — чужой клиент)» → `404 NOT_FOUND` — для покупателя чужая, `proposed`
  и несуществующая карточка неотличимы (11 SEC-030 (в); 08 §4.11.6; FIX-G-DISC-404).
- `returns_delete`: удаление черновика физическое (строки заявки — каскадом, владелец модели 07 §5.45); прежний текст
  «мягкое удаление, `return_requests.deleted_at`» — столбца нет; повтор `DELETE` → `204` по следу в аудите (08 §4.15.4; GQ-TXR-03).
- `returns_create` (общее правило `/returns*`): при `app_settings.returns_enabled=false` — `403 FORBIDDEN`,
  `reason: returns_disabled` (после RBAC, до проверки `Idempotency-Key`; 08 §2.4 «Уточнения … этапа G» п. 1; 10 RET-012; GQ-TXR-01).
- `transactions_get`: «Аудит не пишется» → `audit.viewed` при непустом `audit[]` (11 SEC-073, §7.2; 08 §4.14.2; FIX-G-TXN-AUDIT).
- `Receivable` (описание схемы, `balance`, `asOf`): `null` также у клиента 1С, по которому снимка долга ещё нет (без `reason`,
  `isStale: true`; 10 DEBT-009; 08 §3.7 «Уточнения»; GQ-CRD-05). Значение `reason: no_snapshot` — предложение MINOR (08 §16.15).

## [1.1.0] — 2026-10-22 — выравнивание контракта с ТЗ и реализацией (закрытие остатков этапа E)

Аддитивное изменение (MINOR): `info.version` 1.0.0 → 1.1.0. Вносится только то, что `pos-api` уже отдаёт и что описано
в 08 v1.12 (ссылка на § — у каждого пункта). Источник — `docs/stages/E_spec_sync.md` §1 «Не менялись», §3 «Бэклог»;
решение — ADR-097 (15, приложение Д); журнал 08 §16.9.

### Добавлено

- `Problem.until` (date-time) — `423 PIN_LOCKED`, момент снятия блокировки PIN (08 §2.4 «Расширения `Problem` по реализации»; D AU-15).
- `Problem.reason` для `401 UNLOCK_REQUIRED`: значения `idle_lock`, `refresh_replay`, `emergency_code` — в описании поля и в
  расширении `x-unlock-required-reasons` (поле остаётся строкой: `reason` общий для разных кодов) (08 §2.4; D A-21).
- Поля элементов `GET /catalog/sync/{entity}`, которые сервер уже отдаёт (08 §4.24.1 «Уточнения выгрузки» п. 2; EQ-CSYNC-02,
  FIX-EF-01, EQ-FEF-02, EQ-FEF-03, EQ-FEF-12):
  `CatalogSyncBarcode.id`, `.productId`; `CatalogSyncPrice.id`; `CatalogSyncImage.id`, `.sortOrder`;
  `CatalogSyncPackaging.productId`, `.sortOrder`; `CatalogSyncWarehouse.shortName`, `.isDefaultForPos`, `.sortOrder`;
  `CatalogSyncProduct.multiplicity`, `.isSellable`; `CatalogSyncAttribute.valueType` (enum `attribute_value_type` 07 §6.1),
  `.unitLabel`, `.isFilterable`, `.isVariantAxis`, `.sortOrder`.
- Схема `CatalogSyncCategory` = `Category` + `path`, `depth`, `isVisible`, `updatedAt`; `x-entity-schema.categories` и
  `anyOf` элементов `CatalogSyncResponse` ссылаются на неё (экранная `Category` не меняется).
- `POST /admin/users` → `201`: тело `oneOf [AdminUser, Invitation]` и заголовок `Location` (08 §4.18.4 «Уточнения» п. 4;
  D admin A-03): `AdminUser` — активация `pending_activation`, `Invitation` — номер без учётной записи.

### Уточнено (только текст описания; схема не меняется, `info.version` остаётся 1.1.0 — правка в той же закрывающей итерации)

- Описание `Problem.reason`: `refresh_replay` у `401 UNLOCK_REQUIRED` — поздний повтор refresh у пользователя **с** PIN
  (standard-сессия, сессия не отзывается); пользователю без PIN приходит `401 SESSION_REVOKED` с `reason: refresh_replay`,
  сессия отзывается (09 §8.3, SESS-034; 08 §2.4). Прежний текст «у пользователя без PIN» описывал поведение наоборот
  (ревью закрытия E, RS-1). Реализация (`refresh.service.ts`) и e2e T-SESS-023 уже соответствуют исправленному тексту.
- Описания `admin_users_create` и `admin_invitations_create`: перечислены реализованные отказы — `403 FORBIDDEN`
  `reason: role_not_invitable`, `409 PHONE_ALREADY_REGISTERED` `reason: customer_account` (номер действующего `customer`
  приглашением в сотрудники не переводится; прежний текст `admin_invitations_create` «pending_activation или customer —
  применяется сразу» противоречил 08 §4.18.4 «Уточнения» п. 2 и 11 SEC-136 п. 4; Q-312), `422 VALIDATION_FAILED` rule `max_items`
  и `required` (08 §4.18.4 п. 1–3; ревью закрытия E, RS-4).

### Не внесено (нет в 08 или реализация не отдаёт) — `docs/stages/E_spec_sync.md`, ADR-097

- `devCode` (`AuthOtpRequestResponse`): 08 поля не описывает, 09 §4.6 — «в R1 не возвращается», сервер его не отдаёт.
- `matchedVariantId` (`ProductSummary`): в 08 нет (только предложение 07 §10.3 п. 7), сервер не отдаёт.
- `Variant.prices` / `Variant.availableTotal`: 08 §3.6 — «изменение контракта MINOR по решению владельца 08», сервер не отдаёт.
- `admin_code` в enum `amr` (`AuthUnlockResponse.amr`, `Me.session.amr`): 08 §4.1.8 — в телах ответов значение
  отфильтровывается до `sms|bio|pin`, сервер его не отдаёт.
- Поля таймаутов (`sessionIdleLockMinutes`, `backgroundLockMinutes`) в `GET /settings/public`: в 08 §4.23.1 нет, сервер не отдаёт (D SS-06).

### Требует правки реализации

- `pos-api`: `src/health/openapi.document.ts` — `setVersion('1.0.0')` → `'1.1.0'`.
- `pos-app`: наборы ключей DTO (`catalog_dtos.dart` — `syncJsonKeys`/`extraSyncKeys`, схема `CatalogSyncCategory` для `categories`;
  `core/network/models/problem.dart` — `until`), иначе тесты `catalog_dto_contract_test.dart` и `dto_schema_test.dart`
  (сверка «ключи DTO == properties») расходятся с контрактом 1.1.0.

## [1.0.0] — 2026-10-22 — синхронизация ТЗ с реализацией этапа E (spec-sync E)

Контракт ещё не опубликован, поэтому `info.version` не повышается. Источник — `docs/stages/E_spec_sync.md`, ADR-090.

### Изменено

- `Image.thumbUrl`, `cardUrl`, `fullUrl`: пример пути — `/images/{sha}/{size}` (путь pos-proxy, 08 §4.4.7, 16 §4.5);
  прежний пример `/api/v1/images/…` вёл в api, где маршрута фото нет (EQ-IMG-06, EQ-INT-02). Реализация уже отдаёт новый путь.

## [1.0.0] — 2026-10-21 — правки по архитектурной проверке этапа B (до ворот G-B2)

Контракт ещё не опубликован, поэтому `info.version` не повышается. Источник — `docs/reviews/B_architecture_review.md`;
подробности — `NOTES.md` §8.

### Изменено

- `POST /admin/users`, `PUT /admin/users/{id}/roles`: `roles` — `maxItems: 1` в R1 (B-AR-02).
- `Receivable`: `balance` и `asOf` допускают `null`, новое поле `reason` (`not_in_onec`) — 08 §4.11.5 (B-AR-06).
- `IntegrationsOnecChangeObject.ref`: строка 1…150 вместо `format: uuid` — ключи наборов записей регистров (B-AR-05).
- `Profile.birthYear`: `minimum: 1920` (B-AR-16).

### Добавлено

- `Customer.discounts` (и в четырёх `CustomerView*`) — блок `include=discounts` = `CustomersDiscountsResponse` (B-AR-06).
- `POST /orders/{id}/payments`: ответ `503` (`QR_UNAVAILABLE`, только `QR_PROVIDER=bakai`) (B-AR-13).
- `CatalogSyncResponse.x-entity-schema` — соответствие `entity → схема элемента` (B-AR-14).
- Описания: скоуп `Idempotency-Key` для публичной регистрации (B-AR-01), повтор операций с шагом после COMMIT —
  текущее представление ресурса (B-AR-04), обязательность `X-Step-Up-Token` через `403 STEP_UP_REQUIRED` (B-AR-16),
  `previewToken` (B-AR-07).

### Известные пробелы — закрыто

- `Receivable` без `reason` / `include=discounts` без состава — закрыты (см. выше); предложения владельцу 08 §3.7 —
  `NOTES.md` §8.2.

## [1.0.0] — 2026-10-21 — первая версия контракта R1 (RM-B-003, этап B)

Источник: `docs/specification/08_API_SPECIFICATION.md` v1.9 (§2–§4, §8, §9); ядро R0 v1.9 §7, §17.4,
§19.2, §22–§24 (приоритет); словари — 07 §6 (enum), 11 §4.3–§4.4 (права), 08 §2.4 (коды ошибок),
08 §2.12 (`operation` step-up), 16 §4.3 (флаги).

### Добавлено

- Корень и общие компоненты (`parts/00_root.yaml`): `info`, `servers` (плейсхолдер `<домен>`, Q-032),
  22 тега 08 §8 с `x-module`, схемы безопасности `bearerAuth`, `stepUpToken`, `integrationToken`,
  `webhookSignature`; общие схемы 08 §3 (`Money`, `Quantity`, `Page`, `Problem` + `ProblemCode` — 50 кодов
  08 §2.4, `Warning`, enum-ы 07 §6.1/§6.1.1, `PermissionCode` — 77 кодов 11 §4.3, `StepUpOperation`),
  стандартные ответы ошибок (`BadRequest` … `ServiceUnavailable`, `default: Problem`), параметры
  заголовков ядра §17.4 (`X-Device-Id`, `X-App-Version`, `X-Platform`, `X-Request-Id`, `Idempotency-Key`,
  `X-Step-Up-Token`, `If-None-Match`), заголовки ответов (`X-Request-Id`, `Idempotent-Replayed`,
  `X-Data-As-Of`, `X-Min-App-Version`, `X-Recommended-App-Version`, `ETag`, `Retry-After`, `X-RateLimit-*`),
  пагинация `limit` 1…200 (ядро §19.2) + `cursor`.
- Пути модулей — 119 путей, 141 операция:

  | Часть | Теги (операций) |
  |---|---|
  | `10_auth.yaml` | auth (11), registration (4), me (10) |
  | `20_catalog.yaml` | catalog (11, вкл. `GET /catalog/sync/{entity}` 08 §4.24), search (4), inventory (2), settings (1) |
  | `30_cart_orders.yaml` | cart (13), orders (10) |
  | `40_payments_pos_returns.yaml` | payments (6), pos (1), returns (8) |
  | `50_customers.yaml` | customers (10), receivables (1), discounts (1), favorites (6), transactions (2) |
  | `60_sync_admin_ops.yaml` | notifications (3), sync (7), admin (20), health (3), integrations (7: `/integrations/onec/*` C-2 и `POST /integrations/smspro/dlr`) |

- Расширения операций (NOTES §4): `x-permissions`, `x-roles`, `x-step-up`, `x-step-up-operation`,
  `x-idempotent`, `x-feature-flag`, `x-status`, `x-rate-limit-group`.
- Условные операции с `x-status: proposed` (до решения заказчика, 13 §5.4 п. 5): `POST /payments` и
  `GET /payments/{id}/documents/receipt.pdf` (`DEBT_PAYMENTS_FROM_POS`, Q-152), `POST /payments/qr/webhook`
  (`QR_PROVIDER=bakai`, R2-провайдер, ядро §24.4), шесть операций `/integrations/onec/*`
  (`ONEC_INBOUND_ENABLED`, сценарий C-2, Q-031/Q-011).

### Не входит в R1 (проверяется `scripts/check_api_paths.py`)

- `POST /registration/face-scan/verify` (только R2, ядро §17.4); `PATCH /customers/{id}/contacts`,
  экспорт CSV, пометка ошибки синхронизации решённой, пауза сущности, объединение корзин (ядро §19.2);
  неканонические варианты `DELETE /admin/users/{id}/sessions`, `/integrations/onec/heartbeat`,
  `POST /registration/customer-match`; эндпоинты R5 §5.2, не вошедшие в ядро §7 (08 §4.20).

### Известные пробелы (решение владельца ТЗ, см. NOTES.md §7.4)

- `WarningCode` не содержит `ambiguous_barcode` (требуется 08 §4.5.2) — нет в словаре 08 §2.4.
- `Receivable` без поля `reason` и с обязательным `balance` — ответ `balance: null, reason: not_in_onec`
  08 §4.11.5 не выражается.
- `GET /customers/{id}?include=discounts` — состав блока не задан в 08 §3.7.
- `OrderSummary.paymentsSummary` — открытый объект (08 §4.8.2 не раскрывает состав);
  `GET /orders/{id}/payments` — `{ items: Payment[] }` без пагинации (08 §4.8.6 формат не задаёт).

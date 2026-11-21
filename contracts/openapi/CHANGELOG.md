# CHANGELOG — контракт `pos-api` (`contracts/openapi/pos-api.v1.yaml`)

Формат — по [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/); версия — `info.version` контракта
(SemVer: мажор — несовместимое изменение путей/полей, минор — добавление, патч — уточнение описаний).
**Исключение для не выпущенной версии** (ревью закрытия F, второй круг, RS-7): пока версия не выпущена — не принята
воротами этапа, в котором внесена (для 1.2.0 — ворота G-F не закрыты), — уточнения только текста описаний этой версии
вносятся в её же раздел «Уточнено» без повышения `info.version`; после выпуска уточнение описаний — патч. Так уточнён
смысл `Notification.payload.status` в [1.2.0] (PaymentStatus платежа → OrderStatus заказа, RS-1 ревью закрытия F).
Собранный файл не редактируется вручную: правки вносятся в `parts/*.yaml`, затем
`python -I -X utf8 scripts/build_openapi.py` (правила — `NOTES.md` §1, §7).

## [1.4.0] — 2026-11-08 — вход по лицу на всех платформах (ADR-116)

Аддитивное изменение (MINOR): `info.version` 1.3.0 → 1.4.0. Основание — ответы владельца 2026-11-07 (выбраны все три
варианта вопроса «Где должен работать вход по лицу?») и 2026-11-08 (Q-353 — «Всем (Рекоменд.)», Q-355 — «Лицо без PIN
(Рекоменд.)»); решение — ADR-116 (15, приложение Р). Источник — 08 v1.21 (§2.2, §2.4, §2.9, §3.14, §4.1.2, §4.1.5,
§4.1.8, §4.1.10, §4.3.3, §4.3.5–§4.3.7, §4.18.3, §4.18.11, §4.18.15, §9), 07 v1.18 (§5.9, §5.66, §6.1.1); решения
контракта — `NOTES.md` §10 и шапка `parts/10_auth.yaml` (A10–A14). Путь `v1`, существующие пути, поля и их
обязательность не менялись; `oneOf` не вводился; нового кода ошибки нет. Сервер изменение пока не отдаёт — его вносит
пакет сервера; на рабочем контуре `AUTH_BIO_ALLOW_WEAK=off` и `AUTH_WINDOWS_HELLO_KEY=off` (16 §4.3).

### Добавлено

- `POST /auth/unlock/challenge` (`auth_unlock_challenge`; 08 §4.1.10): публичный, `RL-PIN`; тело
  `AuthUnlockChallengeRequest {method: hello_key, refreshToken}`, ответ `AuthUnlockChallengeResponse {challenge,
  expiresAt}` (challenge — `optomstroy-hello-unlock/v1:` + base64url 32 байт, 120 с); отказ — `401 UNLOCK_REQUIRED`
  `hello_key_unavailable`.
- `AuthUnlockRequest`: `method` + `hello_key`; свойства `signature` (RSASSA-PKCS1-v1_5 / SHA-256 над challenge, base64url)
  и `helloKeyInvalidated` (с `method: pin` — отзыв ключа устройства) — 08 §4.1.8.
- `Problem.reason` для `401 UNLOCK_REQUIRED`: `x-unlock-required-reasons` + `bio_weak_pin_due`, `bio_weak_disabled`,
  `hello_key_unavailable`, `hello_key_invalid` (08 §2.4 «Причины `UNLOCK_REQUIRED` входа по лицу»); описание ответа
  `Unauthorized`.
- `MeBiometricsRequest.biometricClass` + `class2` (уровень W Android); свойство `helloKey` — схема `MeBiometricsHelloKey
  {publicKey, algorithm, source}` (ключ Windows Hello, 08 §4.3.6); `MeBiometricsResponse.reason` +
  `weak_biometrics_disabled`, `hello_key_disabled`, `hello_key_shared_device`.
- Схемы CHECK-перечней `HelloKeyAlgorithm` (`RS256`), `HelloKeySource` (`windows_hello`, `webauthn_prf`) — 07 §6.1.1,
  `contracts/enums.json` 1.4.0.
- `Me.security`: `biometricsPlatform` + `android_class2`, `windows_hello_key` (в конце перечня); `biometricWeakAllowed`,
  `windowsHelloKeyAllowed` (08 §3.14).

### Изменено

- Описания (без изменения схем): `POST /auth/unlock` (методы, порядок проверок, продление срока уровня W, аудит);
  `POST /auth/otp/verify` (продление срока W, правило `personal`); `POST /auth/logout-all`,
  `POST /admin/users/{id}/logout-all`, `POST /me/phone/change/confirm`, `POST /me/consents`, `POST /admin/store-tablets`,
  `POST /admin/store-tablets/{id}/reconnect` — отзыв ключей Windows Hello (`hello_keys.revoke_reason`); `POST /me/biometrics`
  (правила `class2` и `helloKey`).
- `DELETE /me/pin`: правила `weak_biometrics_active`, `hello_key_active` (`400 VALIDATION_FAILED`) и
  `login_protection_required` (`422`) — в описании; в `responses` добавлены `400` и `422` (`422` сервер отдавал и раньше,
  08 §4.3.5 «Уточнения»).

### Уточнено (2026-11-18; только текст описаний — схема, пути, права, обязательность и `x-*` не менялись, `info.version` остаётся 1.4.0: версия не выпущена, см. «Исключение для не выпущенной версии» в шапке; 08 §4.1.10, 09 §9.2 W2 п. 2, BIO-040)

- `POST /auth/unlock/challenge` (и решение A10 в шапке `parts/10_auth.yaml`, описание `Problem.reason`): refresh
  проверяется так же, как в `POST /auth/unlock` — отказ по самой сессии теперь `401 SESSION_REVOKED` (неизвестный или
  отозванный refresh; `reason` `expired` и `device_mismatch` — с отзывом сессии, `blocked`, `reuse_detected` — с отзывом
  семьи) или `401 KIOSK_REVOKED`, а не `UNLOCK_REQUIRED hello_key_unavailable`; прежний refresh в окне грации и при
  позднем повторе получает challenge той же сессии. `hello_key_unavailable` — только отказ по ключу, субъекту и переменной
  (на него приложение снимает признак ключа). Оба кода уже были в ответе `401` (`Unauthorized`). Основание — ревью пакета
  сервера W2: на истёкшую после выходных сессию приложение удаляло ключ Windows Hello, который сервер ещё принимал
  (`[ВЫВОД исполнителя]` по 09 BIO-040).

### Производные артефакты и окна

- `pos-api/src/health/openapi.document.ts`: `OPENAPI_INFO_VERSION` 1.3.0 → 1.4.0 (`src/health/openapi.document.spec.ts`
  зелёный).
- `scripts/check_api_permissions.py`: `/auth/unlock/challenge` — в `PUBLIC_PATHS` (11 §4.3.1, SEC-013).
- Ожидаемо красные до реализации (пакеты сервера и приложения дорожки входа по лицу): `pos-api`
  `test/e2e/smoke.e2e-spec.ts` «контракт ⊆ экспорт»; `pos-app` `test/features/auth/data/auth_dto_contract_test.dart`
  (`AuthUnlockRequest`) и `test/core/network/models/dto_schema_test.dart` (`Me.security`).
- Проверка `oasdiff breaking` — в CI (локально не запускалась): новые значения перечней в ответах — предупреждения; новый
  путь, необязательные свойства и значения перечней запросов — информационные.

## [1.3.0] — 2026-11-04 — режим «Планшет магазина» (P-002, ADR-115)

Аддитивное изменение (MINOR): `info.version` 1.2.0 → 1.3.0. Основание — P-002 «Планшет магазина» редакции 5, утверждённый
владельцем 2026-11-04: «P-002 утверждаю, делай»; группа А — «Да, все рекомендации (Рекоменд.)», в пояснении варианта —
«Р-01 а»; решение — ADR-115 (15). Источник — 08 v1.20 (§2.2–§2.4, §2.7, §2.9, §2.12, §3.9, §3.13, §3.14, §3.17, §4.18.6,
§4.18.11–§4.18.15, §4.23.1, §4.25, §9), 07 v1.17 (§5.65, §6.1, §6.1.1), 11 v1.4 (§4.3 №77–81, §4.4); решения контракта —
`NOTES.md` §9 и шапка `parts/70_kiosk.yaml` (K1–K10). Путь `v1`, существующие пути, поля и их обязательность не менялись;
`oneOf` не вводился. Операции планшета сервер пока не отдаёт — они появляются в пакетах сборки P-002 (пакет WP-S1A-KIOSK
и следующие).

### Добавлено

- Тег `kiosk` — последним в `tags` (08 §8; `x-module: kiosk`, 06 MOD-030) — и часть `parts/70_kiosk.yaml` с десятью
  операциями: `POST /admin/store-tablets` (`kiosk_tablets_enroll`), `GET /admin/store-tablets` (`kiosk_tablets_list`),
  `PATCH /admin/store-tablets/{id}` (`kiosk_tablets_update`), `POST /admin/store-tablets/{id}/revoke`
  (`kiosk_tablets_revoke`), `POST /admin/store-tablets/{id}/reconnect` (`kiosk_tablets_reconnect`) — 08 §4.18.11–§4.18.15;
  `POST /kiosk/order-otp` (`kiosk_order_otp_request`), `POST /kiosk/orders` (`kiosk_orders_create`),
  `GET /kiosk/orders?idempotencyKey=` (`kiosk_orders_find`), `POST /kiosk/reset` (`kiosk_reset`), `POST /kiosk/exit`
  (`kiosk_exit`) — 08 §4.25.1–§4.25.5. У каждой — `x-permissions` по 11 §4.3 №77–81, `x-roles`, `x-step-up` и
  `x-step-up-operation: [kiosk.manage]` (подключение, отключение, подключение заново), `x-idempotent`,
  `x-feature-flag: KIOSK_MODE` (подключение, подключение заново, все `/kiosk/*`), `x-rate-limit-group` по 08 §2.9 «Лимиты
  планшета магазина» (RL-ADMIN, RL-OTP-SEND, RL-FIN, RL-READ, RL-CART, RL-PIN).
- Схемы `StoreTablet` (`lockTaskEnabled: boolean|null`, `expiresAt`), `KioskTokens`, `KioskOrderAccepted` (имена 08 §3.17)
  и тела и ответы операций `Kiosk*`.
- Параметр `KioskLock` — заголовок `X-Kiosk-Lock: on|off`, необязательный (08 §2.3, ADR-115 п. 26): у `/kiosk/*` и у
  операций закрытого списка 08 §4.25 (каталог, поиск, остатки, корзина, предпросмотр, `GET /settings/public`, `GET /me`).
- Перечни: `UserKind` + `kiosk`, `RoleCode` + `kiosk` (в том числе `UserRef.role` в `audit.createdBy` заявки с планшета),
  `OtpPurpose` + `kiosk_order`, `NotificationKind` + `kiosk_order` (07 §6.1); схемы CHECK-перечней `OrderCreatedVia`,
  `KioskCustomerMatch`, `StoreTabletStatus` (07 §6.1.1; имена — как в `contracts/CHANGELOG.md` [1.3.0]); `ProblemCode` +
  `KIOSK_REVOKED`, `KIOSK_DISABLED`, `KIOSK_NETWORK_DENIED`, `KIOSK_RATE_LIMITED`, `KIOSK_EXIT_CODE_INVALID`,
  `KIOSK_EXIT_LOCKED` после `APP_READ_ONLY` (56 кодов, порядок 08 §2.4); `PermissionCode` + `kiosk.read`, `kiosk.manage`,
  `kiosk.order.submit`, `kiosk.self.read`, `kiosk.self.exit` (82 кода, порядок 11 §4.3); `StepUpOperation` +
  `kiosk.manage` (08 §2.12).
- `Order.createdVia` и `OrderSummary.createdVia` (`OrderCreatedVia`) — сервер отдаёт поле с этапа G, в 1.2.0 оно не было
  объявлено (08 §3.9); `Order.kioskCustomerMatch` и `OrderSummary.kioskCustomerMatch` — nullable, `x-roles` сотрудников;
  `Receiver.phoneMasked` (`readOnly`; после маскирования номера покупателя заявки с планшета `Receiver.phone = null`);
  query `createdVia` у `GET /orders` (08 §4.8.2); элемент `awaitingPayment[]` `GET /pos/dashboard` — тот же `OrderSummary`
  с `createdVia` (08 §4.10.1).
- `Me.tablet` (`MeKioskTablet`: `id`, `name`, `warehouseId`) и значение `kind=kiosk` (08 §3.14); строгая форма ответа
  планшета — схема `MeKiosk` (эталон для контрактных тестов, путями не используется — предупреждение Redocly
  `no-unused-components`, как у `CustomerView*`).
- `PublicSettings.kiosk {idleSeconds, idleWarningSeconds, doneSeconds}` и `PublicSettings.features.storeTablet` (env
  `KIOSK_MODE`) — 08 §4.23.1; `AdminSettingsValues` + `kioskIdleSeconds`, `kioskIdleWarningSeconds`, `kioskDoneSeconds`,
  `kioskOtpPerHour`, `kioskOtpPerDay`, `kioskWorkingHours`; `AdminSettingsEnv.kioskMode` — 08 §4.18.6.
- `POST /auth/otp/verify` — ответ `404` (код `kiosk_order` сессию не выдаёт; 08 §4.1.2, 12 T-KIOSK-015).

### Изменено

- `GET /me`: `x-permissions` — `[profile.manage.own, kiosk.self.read]` (одно из, 08 §4.3.1); `x-roles` + `kiosk`.
- `POST /cart/checkout-preview`: `x-permissions` — `[cart.manage.own, order.create, kiosk.order.submit]` («`cart.manage.own`
  и одно из `order.create` | `kiosk.order.submit`», 08 §4.7.7; форма требования — в описании операции и `NOTES.md` §4);
  `x-roles` + `kiosk`; описание — «Предпросмотр на планшете».
- `x-roles` + `kiosk` у операций закрытого списка 08 §4.25: `GET /catalog/categories`, `/catalog/products`,
  `/catalog/products/{id}`, `/catalog/products/{id}/variants`, `/catalog/units`, `/catalog/warehouses`,
  `/catalog/sync/{entity}`, `GET /search/products`, `GET /search/suggest`, `GET /inventory/balances`,
  `POST /inventory/check`, `GET /cart`, `PUT/DELETE /cart/items/{variantId}`, `GET /settings/public`.
- Описания (без изменения схем): `POST /auth/refresh` — `401 KIOSK_REVOKED` и правила сессии планшета (08 §4.1.3);
  `POST /auth/otp/request` — `kiosk_order` не принимается; `POST /auth/logout` и маршруты вне закрытого списка — `403` для
  планшета (`reason: kiosk_closed_list`); `/admin/users*` — цель `kind=kiosk` → `403` (`reason: kiosk_target`), в списке
  технического пользователя нет; `PUT /admin/settings` — границы ключей `kiosk*`; `GET /notifications` — вид
  `kiosk_order`; `GET /pos/dashboard` — пометка «С планшета»; ответы ошибок корня (`Unauthorized`, `Forbidden`,
  `UnprocessableEntity`, `Locked`, `TooManyRequests`), `Problem.reason`, `Problem.attemptsLeft`, `bearerAuth`.

### Не внесено

- `oneOf` у ответа `GET /me` и ослабление `required` схемы `Me`: форма планшета — необязательное свойство (08 §3.14;
  `NOTES.md` §9 п. 4).
- `x-roles: kiosk` у операций, где роль держит код, но маршрут вне закрытого списка или отвечает `403`, как у `customer`
  (`PATCH`/`DELETE /cart`, `POST`/`DELETE /cart/customer`, `/cart/park*`, `/cart/parked*`, `GET`/`DELETE
  /catalog/products/recent`, `GET /catalog/price-lists`, `GET /search/barcode/{value}`): предупреждения [A]
  `check_api_permissions.py` для них законны (`NOTES.md` §7.4 п. 7).

### Производные артефакты и окна

- `pos-api/src/health/openapi.document.ts`: `OPENAPI_INFO_VERSION` 1.2.0 → 1.3.0, тег `kiosk` в `OPENAPI_TAGS`
  (`src/health/openapi.document.spec.ts` зелёный).
- `pos-api/test/e2e/rbac-matrix.e2e-spec.ts` (T-SEC-019): для `POST /kiosk/reset` роль считается допущенной, только если
  держит все коды операции (`NOTES.md` §9 п. 5).
- Ожидаемо красные до реализации на сервере (план сборки P-002, `parallelSafety`): `test/e2e/smoke.e2e-spec.ts`
  «контракт ⊆ экспорт» — до пакета с последней операцией планшета (WP-S4C); сверка групп лимитов
  (`test/catalog/catalog-rate-limit.e2e.spec.ts` — `/kiosk/orders`, `/kiosk/reset`) и состава настроек (`test:admin`,
  `test:settings`) — до WP-S1A-KIOSK; DTO-тесты `pos-app`, которые читают схемы контракта, — до WP-A01.
- Проверка `oasdiff breaking` — в CI (локально не запускалась): новые значения перечней в ответах — предупреждения, не
  ошибки; новые пути, необязательные параметры и свойства — информационные.

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

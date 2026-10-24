# Независимая проверка этапа F «Cart and POS» (раунды 1–2; закрытие остатков — в конце файла)

Дата: 2026-10-23. Проверяющий: независимый агент (13 §3.6, ворота G-F). Машина: Windows 11 Pro 10.0.26200, Node 24,
Flutter 3.38.7 / Dart 3.10.7. Android-устройств, реальной 1С и тестовой копии 1С нет. Все прогоны — на
FakeOnecGateway / ScriptedOnecGateway, управляемом фейке HTTP-сервиса 1С и фикстурах `contracts/onec/fixtures`:
**на фикстурах, не реальная интеграция**.

Код при перепроверке не менялся. Записаны только этот отчёт и раздел «Перепроверка после ревью, раунд 1» в
`docs/stages/F_test_run.log`.

Основание проверки: 10_POS_BUSINESS_RULES (CART-, ORD-, PAY-, DISC-, CRED-, PRINT-, CUST-, INV-), 08 +
`contracts/openapi/pos-api.v1.yaml` 1.1.0, 07 (§6.4, §6.5, §11), 05 (§6, §6.7), 11 + `contracts/rbac/permissions.yaml`,
02 (SCR-20…26, SCR-44), 03, 04, 06, 12, 13 §3.6 (RM-F-001…016, ворота G-F), ядро R0 v1.9 (приоритет §24 > §23 > … > §16).

## 1. Методика

1. **Направления ревью**, по каждому — отдельный проверяющий: `fresh-run` (повторный прогон журнала), `money-rules`
   (деньги, скидки, previewToken, правила 10), `orders-1c` (outbox, ответы 1С, QR через 1С), `security` (RBAC, лимиты,
   валидация, аудит), `flutter-ui` (SCR-20…26, 44, a11y, golden), `flutter-data` (drift, `cart.sync`,
   `checkout_draft`, сессия), `trace` (T-ID → тест, выходы RM-F-*, покрытие).
2. **Два скептика** на каждое серьёзное (blocker/critical/major) замечание: каждый независимо пытался опровергнуть его
   по коду и ТЗ и, где можно, воспроизводил зондом. Замечание подтверждено, если ни один не опроверг. Если оценка
   скептиков ниже исходной, это указано в таблице.
3. **Исправления** выполнили два исправителя (backend и Flutter). Их решения — `docs/stages/F_spec_questions.md`,
   разделы «FIX» (FIX-F-01…17, FIX-FE-01…11), журнал — `F_test_run.log` §7.
4. **Перепроверка (этот раунд)**: полный свежий прогон и сверка каждого подтверждённого замечания с текущим кодом и
   тестом (поиск по коду, чтение изменённых участков, наличие и прохождение тестов, которые закрывают замечание).
   Статусы исправителей не принимались на веру. Интеграционные тесты Flutter не запускались — на C: 69–77 МБ
   (< 300 МБ, условие задачи).

## 2. Повторный прогон после исправлений (раунд 1)

| Проверка | Результат | Итог |
|---|---|---|
| pos-api `lint`, `build`, `madge`, `check:permissions` | код 0; 503 файла, 0 циклов; 77 кодов / 7 ролей | зелёный |
| pos-api `test:all` (27 наборов) | 1179 passed, 7 skipped, 0 failed | зелёный |
| pos-api `test:cov:f` | 638 passed; строки 91.76 %, ветви 76.69 %; пороги строк и «храповик» ветвей выполнены | зелёный (100 % ветвей RM-F-009 — нет, см. F-trace-2) |
| pos-api `test:cov:e` | 1-й прогон: 1 failed (`otp.e2e-spec.ts`, этап D, 500 вместо 202); повтор файла ×3 и повтор `test:cov:e` — 495 passed | **нестабильный** (R1-N-01) |
| pos-api `test:cov:d` | 377 passed; строки 97.92 % | зелёный |
| pos-api `test:e2e:pos` | 1 passed (процессный e2e) | зелёный |
| local-stack `smoke` / `auth-smoke` / `catalog-smoke` / `pos-smoke` | 10/10, 15/15, 22/22, 30/30 PASS (фикстуры) | зелёный |
| миграции `run-sql --repeat-strict` (prod; dev/test) | 0 изменений; 63/63 и 64/64 таблиц, 45/45 enum; check_ddl_behavior OK | зелёный |
| `flutter analyze` | No issues found | зелёный |
| `flutter test --concurrency=2` | 1650 passed | зелёный |
| golden (`--tags golden`) | 220 passed | зелёный |
| `check_layers`, `sync_contracts --check` | код 0 | зелёный |
| `flutter build windows --release` | собрано | зелёный |
| integration `pos_flow_test`, `catalog_flow_test`, `auth_flow_test`, `admin_invite_flow_test`, `boot_test` | **не выполнялись: нет места на C:** | not_done |
| `check_no_double_money.sh`, `check_secrets.py` | 0 совпадений; 0 находок | зелёный |
| `build_openapi.py --check`, `check_api_paths.py`, `check_enums.py`, `check_arb_keys.py` | код 0 | зелёный |
| `check_repo_layout.py`, `check_env_example.py`, `check_api_permissions.py`, `check_enum_triangle.py`, `check_onec_paths.py` | код 0 (0 ошибок) | зелёный |
| `check_money_vectors.py`, `gen_errors_matrix.py --check` (новые) | код 0 | зелёный |
| `trace_test_ids.py --stage D` / `--stage E` | без теста и причины 0 | зелёный |
| **`trace_test_ids.py --stage F`** | охват 242; с тестом 73; not_done 17; **без теста и причины 152; код 1** | **красный** |

## 3. Подтверждённые замечания и их статус после исправлений

Severity — исходная оценка; в скобках — оценка скептиков, если она ниже. Статус — по текущему коду и тестам.

| ID | Направление | Severity | Файл | Суть | Доказательство после исправления (кратко) | Статус |
|---|---|---|---|---|---|---|
| F-fresh-run-1 | scripts | major | docs/repo_layout.md | `pos-api/assets/` не описан, `check_repo_layout` красный | строка `assets/` в дереве pos-api (§2, стр. 85); `check_repo_layout` код 0 | fixed |
| F-fresh-run-2 | docs | minor | docs/stages/F_test_run.log | в журнале нет части скриптов корня | §7.4 журнала перечисляет все скрипты с кодами; подтверждено свежим прогоном (этот раунд) | fixed |
| F-money-rules-1 | backend | critical | pos-api/src/orders/order-create.service.ts | `previewToken` не проверялся | `CheckoutService.assertPreviewToken` (подпись, срок, корзина, rowVersion, способ, итог → 422 PRICE_CHANGED); e2e `orders-money-rules` (скидка изменена, подделка → 422). Токен остаётся необязательным (FIX-F-02, вопрос 08) | fixed |
| F-money-rules-2 | backend | critical | pos-api/src/cart/checkout.service.ts | одобрение скидки распространялось на больший % | `approverLimit` берёт одобрение корзины только при `requested_discount_percent == requested`; e2e: 15 % одобрено → 20 % и 12 % → 422, 15 % → 201 | fixed |
| F-money-rules-3 | backend | major | pos-api/src/orders/order-create.service.ts | причина, `discount_override` и аудит не переносились из корзины | `snap.discountOverrideReason`; запись `discount_reason`, transactions `discount_override`, аудит `discount.over_limit_approved` (стр. 433–637); e2e | fixed |
| F-money-rules-4 | backend | major (minor) | pos-api/src/cart/checkout.service.ts | preview и заказ давали разную сумму при `to_som` | `cashRounding = 'none'` до решения Q-016, журнал `cart.cash_rounding.ignored` (FIX-F-04); e2e preview = order = payment | fixed |
| F-money-rules-5 | backend | major (minor; один скептик опроверг) | pos-api/src/orders/order-create.service.ts | заявка клиента без привязки — на «Розничного», а не на карточку из профиля (CUST-023) | код не менялся (стр. 345); расхождение 10 CUST-023 ↔ 08 §4.8.1 / ядро §22.3 вынесено FIX-F-01 | not_fixed (нужно решение по ТЗ) |
| F-money-rules-6 | backend | major (minor) | pos-api/src/orders/orders.request.ts | `lineTotal`, `discountAmount` не распознавались | общий `CLIENT_FORBIDDEN_MONEY_FIELDS` (7 полей) для cart и orders; unit + e2e 400 `forbidden_field` и аудит `price.override_attempt` | fixed |
| F-money-rules-7 | backend | minor | pos-api/src/orders/order-create.service.ts | `sameItems` сравнивал количество через Money | `Quantity.of(q)` (стр. 841); e2e 1.234 vs 1.231 → 409 | fixed |
| F-money-rules-8 | backend | minor | pos-api/src/cart/checkout.service.ts | `canCreateOrder=true` при отказе в долге | `creditRefused` в условии (стр. 131–137); проверка в cart-flow | fixed |
| F-money-rules-9 | backend | minor | pos-api/test/sales-domain/pricing.spec.ts | property-тесты почти тавтологичны | добавлен независимый оракул 07 §7.3 в тыйынах; свойства «preview ≡ order» и политика одобрения — только e2e, не property | partially_fixed |
| F-orders-1c-1 | backend | critical | pos-api/src/sync/api/sync-outbox.service.ts | повтор отклонённого заказа (ORD-027) не реализован | `retry` вызывает `OrderStatusPort.onOutboxRetry` в той же транзакции: `releaseRestoredCart` (cleared + уведомление или 409 `restored_cart_in_use`), `submit_failed → submitting`, сброс submit_error; то же в onec-link; e2e orders-outbox стр. 269 | fixed |
| F-orders-1c-2 | backend | critical | pos-api/src/orders/worker/order-onec-results.handler.ts | ветка «деньги получены — отклонён 1С» неполная | `withdrawOutbox` (failed → cancelled), `restoreCart(…, parked)`, `payment_status` автору и `received_by_user_id`; повтор → 409; e2e стр. 305 | fixed |
| F-orders-1c-3 | backend | major | pos-api/src/orders/order-cancel.service.ts | повторная отмена после отказа 1С терялась | `OnecOutboxWriter.requeue` (failed/dead → pending, новый payload); e2e orders-ops | fixed |
| F-orders-1c-4 | backend | major | pos-api/src/payments/qr/qr-status.service.ts | оплата после void: нет `sync_errors`, уведомлён один пользователь, повторы раз в 60 с | одна запись `sync_errors` (`error_code = OTHER`, `payload.code = QR_PAID_AFTER_VOID`), `notifyRole` cashier и admin + аннулировавший и автор; повторы 1/2/5 мин до expiresAt; e2e payments-qr-onec. Кода `QR_PAID_AFTER_VOID` в CHECK 07 нет (FIX-F-06) | partially_fixed (остаток — решение по ТЗ) |
| F-orders-1c-5 | backend | major | pos-api/src/payments/qr/qr-issuer.service.ts | при перевыпуске прежний QR не отменялся, нет истории референсов | `provider.cancel(…, 'reissue')` перед новым запросом (синхронно, одна попытка — FIX-F-13); `payments.qr_ref_history` (миграция 0012, expand); старый референс → `late_payment`; тесты исправлены | fixed |
| F-orders-1c-6 | backend | minor | pos-api/src/payments/qr/qr-status.service.ts | опрос продолжался в `qr_expired` | `pollOnce` и `next`: только `qr_shown`; `pollCandidates` без `qr_expired` | fixed |
| F-orders-1c-7 | backend | minor | pos-api/src/sales-domain/payment/payment-status.ts | `cancelled` от 1С игнорировался | `qr_shown` + `cancelled` → `qr_expired` (`provider_cancelled`, актор timer — FIX-F-08); доменный и e2e тест | fixed |
| F-orders-1c-8 | backend | minor | pos-api/src/payments/app/payments.service.ts | фоновая отмена без `.catch` | `cancelInBackground` с `.catch` во всех трёх местах; unit-тест без unhandled rejection | fixed |
| F-security-1 | backend | major (minor) | pos-api/src/payments/app/payment-presenter.ts | клиенту отдавался статический QR | `qr` клиенту только для QR провайдера (`customerMode`), то же в order-presenter; reissue клиенту в ручном режиме исключён; e2e | fixed |
| F-security-2 | backend | major | pos-api/src/common/rate-limit/http-rate-limit.ts | RL-FIN не реализован | группа `RL-FIN` 60/мин, маршруты — по контракту (сверка с контрактом в test:catalog); e2e 429 + Retry-After | fixed |
| F-security-3 | backend | minor | pos-api/src/orders/order-query.service.ts | `sort` через `in` пропускал ключи прототипа | `Object.hasOwn` (также rate-limit.service); e2e `__proto__`/`toString` → 400 | fixed |
| F-security-4 | backend | minor | pos-api/src/payments/long-poll/payment-status-waiter.ts | нет пределов long-polling | ≤ 3 на пользователя, ≤ 200 на процесс (числа — FIX-F-12, вопрос 08); unit-тест | fixed |
| F-security-5 | backend | minor | pos-api/src/orders/order-create.service.ts | нет аудита `credit.sale_blocked` | аудит при каждом отказе по долгу (стр. 743–760); e2e | fixed |
| F-flutter-ui-1 | flutter | critical (major) | pos-app/…/checkout_controller.dart | при неизвестном исходе POST /orders форма редактируема, тело пересобирается | `OrderSubmissionRecovery`: сохранённый объект запроса, тот же ключ, 2/4/8/16/30 с, оверлей UI-20-020 блокирует корзину; widget-тесты (тело и ключ идентичны). Интеграционно не проверено | fixed |
| F-flutter-ui-2 | flutter | major | pos-app/…/checkout_controller.dart | CTA активна во время повторной предпроверки | `isChecking()` в `canSubmit` (стр. 993–1000); widget-тест | fixed |
| F-flutter-ui-3 | flutter | major | pos-app/…/drift_checkout_draft_repository.dart | после перезапуска заказ по ключу не ищется | `OrderSubmissionHost` в AppShell вызывает `pendingSubmissions()` → GET /orders?idempotencyKey= → SCR-22 или SCR-21; тест на реальном drift (новый контейнер над той же БД). Интеграционно не проверено | fixed |
| F-flutter-ui-4 | flutter | major | pos-app/lib/app/di/overrides.dart | роль SCR-26 не подключена | `newCustomerViewerRoleProvider.overrideWith(...)` (стр. 212); stage_f_wiring_test | fixed |
| F-flutter-ui-6 | flutter | major (minor) | pos-app/…/order_created_screen.dart | нет «Открыть восстановленную корзину» | действие на SCR-22 и SCR-24 (порт `orderRestoredCartLocatorProvider`); widget-тесты | fixed |
| F-flutter-ui-7 | flutter | major (minor) | pos-app/…/cart_panel_view.dart | UI-20-004 и UI-20-033 не реализованы | выбор клиента в корзине через `CartSync.direct`, «Подтвердить скидку {p} %» со step-up; cart_screen_test | fixed |
| F-flutter-ui-8 | flutter | major (minor) | pos-app/test/design_system | нет golden AppBottomSheet.side 400/480 | `test/golden/app_bottom_sheet_side_golden_test.dart`, эталоны ci/windows (medium, expanded) | fixed |
| F-flutter-ui-9 | flutter | minor | pos-app/…/cart_panel_view.dart | нет F4 | F4 в CartPanelView и CartFabView; тесты | fixed |
| F-flutter-ui-10 | flutter | minor | pos-app/…/cart_fab_view.dart | подпись диктора без единиц и не словами | `PriceText.spoken`, единицы в `{total}` (FIX-FE-06); semantics-тест | fixed |
| F-flutter-ui-11 | flutter | minor | pos-app/…/order_created_screen.dart | нет OfflineBanner на SCR-22 | `OfflineBanner` (стр. 255), ожидание приостанавливается; widget-тест | fixed |
| F-flutter-ui-12 | flutter | minor | pos-app/…/order_view_rules.dart | накладная всегда недоступна | код не менялся: 02 UI-22-008 ↔ 08 §4.8.5 / 10 PRINT-004 (Q-019), FIX-FE-03 | not_fixed (нужно решение по ТЗ) |
| F-flutter-ui-13 | flutter | minor | pos-app/…/notifications_screen.dart | снекбар UI-44-011 только на SCR-44 | `NotificationAnnouncements` в AppShell, тихо на /checkout и /payments/new; тесты | fixed |
| F-flutter-ui-14 | flutter | minor | pos-app/…/checkout_screen.dart | литеральные отступы | 52 места заменены токенами; lint-тест `spacing_tokens_lint_test.dart`; исключения 5/6 lp и литералы `SizedBox` остались (FIX-FE-05) | partially_fixed |
| F-flutter-ui-15 | flutter | minor | pos-app/…/checkout_screen.dart | SCR-21/22 — непрозрачный маршрут | SCR-21 — `CustomTransitionPage(opaque: false)` на medium/expanded; SCR-22 не менялся (навигация, FIX-FE-04) | partially_fixed |
| F-flutter-ui-16 | flutter | minor | pos-app/…/cart_panel_view.dart | цель нажатия строки склада 32 lp | `BoxConstraints(minHeight: 48)`; golden обновлён | fixed |
| F-flutter-ui-17 | flutter | minor | pos-app/lib/design_system/components/cart_line.dart | сумма строки без нулевых тыйынов | `fixed2: true` (стр. 145); golden обновлён | fixed |
| F-flutter-ui-18 | flutter | minor | pos-app/…/checkout_sections.dart | мета карточки клиента обрезается | перенос строк; golden scr21 показывает «Скидка: 5 %» | fixed |
| F-flutter-ui-19 | docs | minor | pos-app/lib/l10n/app_ru.arb | ICU plural не используется («1 позиций») | ключи не менялись: владелец `contracts/l10n` (FIX-F-16) | not_fixed (нужно решение владельца контракта) |
| F-flutter-data-1 | flutter | critical (major/critical) | pos-app/lib/core/database/daos/cart_draft_dao.dart | строки `dead` стирались сверкой, конфликт терялся | `applyServer` сохраняет `pending` и `dead`; конфликт в `app_meta.cart_version_conflict`, восстанавливается после перезапуска; drift_cart_sync_test (сверка до ответа, перезапуск) | fixed |
| F-flutter-data-2 | flutter | critical (major/critical) | pos-app/…/checkout_controller.dart | ключ `checkout_draft` — серверный Cart.id | ключ — `cart_draft.local_id` (`CartSync.loadLocal`), плюс восстановление через `pendingSubmissions`; тест со сменой Cart.id. Интеграционно не проверено | fixed |
| F-flutter-data-3 | flutter | major | pos-app/…/checkout_controller.dart | SCR-21 менял корзину в обход CartSync | `_cartOp` → `CartSync.direct` для set/clear customer (стр. 683, 699); тест на новую базу rowVersion | fixed |
| F-flutter-data-4 | flutter | minor | pos-app/lib/core/session/session_local_data.dart | предупреждение «Выйти» не видит `dead` и `dirty` | учитывает `pending`+`dead` и `cart_draft.dirty`; session_local_data_test | fixed |
| F-trace-1 | scripts | major | scripts/trace_test_ids.py | нет матрицы T-ID этапа F | `--stage F` добавлен, но **код 1: 152 из 242 ID без теста и причины** (в т. ч. T-PAY-037…041 — тесты есть, T-ID нет) | partially_fixed |
| F-trace-2 | backend | major | pos-api/vitest.config.cov-f.ts | нет порога 100 % ветвей критичных сценариев | пороги ветвей: 100 % для идемпотентности и автомата платежа; «храповик» 67/81/77/53/73 для остальных; order-create 67.41 %, обработчик 1С 53.76 % (FIX-F-14) | partially_fixed |
| F-trace-3 | backend | major | pos-api/src/common/jobs/contracts/queues.ts | нет публикатора `catalog.*-changed` | `PgBossCatalogChangePublisher` в транзакции применения срезов (под SAVEPOINT, pg-boss в pos-worker); e2e `cart-catalog-sync` | fixed |
| F-trace-4 | flutter | major (major/minor) | pos-app/…/order_created_controller.dart | RM-F-013 п. 4 (перезапуск при ожидании оплаты) не подтверждён | «Проверить» на SCR-22 (`refreshStatus=true`), widget-тест без повторного POST; integration-теста перезапуска во время QR нет; SCR-38 — этап G (FIX-FE-09) | partially_fixed |
| F-trace-5 | flutter | major | pos-app/integration_test/pos_flow_test.dart | нет integration для RM-F-005 п. 2 и RM-F-007 п. 2 | сценарий добавлен, **единственный прогон исправителя красный** (зависание на /splash после повторного bootstrap); правки не перепроверены — нет места на C: | partially_fixed |
| F-trace-6 | flutter | major (minor) | pos-app/lib/design_system/components/app_bottom_sheet.dart | нет golden side 400/480 | то же, что F-flutter-ui-8 | fixed |
| F-trace-7 | flutter | major (minor) | pos-app/test/features | приёмочные наборы T-UI неполны, SCR-44 без AC | теги AC-UI-44-001…004/007…009/011 и новые AC-UI-20/21/22; 100 % наборов нет (скептики: по 12 §2.15 полнота — этап H) | partially_fixed |
| F-trace-8 | backend | major (minor) | pos-api/test/orders/orders-create.e2e.spec.ts | нет тестов «без ключа» и «параллельно» | e2e orders-money-rules стр. 242: 400 без ключа; параллельно — один заказ, один платёж, одна строка outbox | fixed |
| F-trace-9 | backend | major (major/minor) | pos-api/src/jobs/outbox/outbox-dispatcher.ts | нет теста T-SYNC-032 | `orders-outbox-concurrency.e2e.spec.ts`: 2 диспетчера × 50, ≤ 20 за цикл, depends_on | fixed |
| F-trace-11 | backend | minor | pos-api/src/cart/cart.service.ts | GET /cart без каталога → 500 | 503 `ONEC_UNAVAILABLE` `reason: catalog_not_loaded`, Retry-After 60; e2e. В 08 §4.7.1 / OpenAPI код не внесён (FIX-F-07) | partially_fixed (остаток — решение по ТЗ) |
| F-trace-12 | docs | minor | docs/errors_matrix.md | нет выхода RM-F-007 | `scripts/gen_errors_matrix.py` + `docs/errors_matrix.md`; `--check` код 0 | fixed |
| F-trace-13 | backend | minor | contracts/test-vectors/money.v1.json | нет сверки MV-01…30 | `scripts/check_money_vectors.py` (MV-06/23/25 — только клиент, с причиной), код 0; общий файл не менялся (контракт) | fixed |
| F-trace-14 | flutter | minor | pos-app/integration_test/pos_flow_test.dart | путь «с клиентом» не в not_done | T-ORD-003 в матрице F — «нет теста и причины»; сида клиентов в local-stack нет (FIX-FE-10) | not_fixed |
| F-trace-15 | docs | minor | 13 §3.6 RM-F-009 | имя выхода `checkout_flow_test.dart` | 13 не менялся (процедура изменения ТЗ, FIX-F-15) | not_fixed (нужно решение по ТЗ) |

Итого: 60 подтверждённых замечаний. fixed — 45, partially_fixed — 10, not_fixed — 5 (из них без решения ТЗ или
владельца контракта — только F-trace-14, minor).

## 4. Опровергнутые замечания

| ID | Severity | Суть | Почему опровергнуто |
|---|---|---|---|
| F-flutter-ui-5 | major | long-polling SCR-22 не приостанавливается при idle-блокировке | `pauseWatch`/`resumeWatch` действительно не вызываются, но приостановку и повтор выполняет `AuthInterceptor` для всех запросов на время оверлея SCR-08; экран SCR-22 остаётся в дереве, ожидание продолжается после разблокировки |
| F-trace-10 | major | ворота G-F закрыть нельзя (RM-F-010 без копии 1С, нет RM-F-011) | это статус ворот, а не дефект результатов этапа: `F_onec_e2e_report.md` — ровно отчёт «не выполнено, блокер для I», который допускает критерий 4 RM-F-010. Вывод о воротах — в §7 |

## 5. Новые наблюдения раунда 1

| ID | Severity | Суть | Доказательство |
|---|---|---|---|
| R1-N-01 | minor | Нестабильный тест этапа D `test/e2e/auth/otp.e2e-spec.ts` «6-й запрос за минуту … circuit-breaker 5 мин»: в 1-м `test:cov:e` последний запрос после `t.tick(4 мин)` дал 500 вместо 202 | 1 failed из 502; в `test:all` этого прогона, в трёх отдельных повторах файла и в повторном `test:cov:e` — зелёный. Причина не установлена; 500 на OTP-запросе стоит разобрать владельцу auth |
| R1-N-02 | info | `POST /sync/outbox/{id}/retry`: если порт `ORDER_STATUS_PORT` не привязан, шаги заказа пропускаются с предупреждением (прежнее поведение) | `sync-outbox.service.ts:154-163`; в сборке pos-api порт привязан (e2e ORD-027 зелёный). Риск — только для процесса без модуля orders |
| R1-N-03 | info | Проверка `previewToken` выполняется, только если токен передан и конфликтов нет; без токена заказ создаётся по серверному пересчёту | `checkout.service.ts:530-537`; обязательность токена — вопрос FIX-F-02 владельцу 08 |

## 6. Итог ревью (раунд 1)

- Все семь critical исправлены по коду; на каждое есть тест исправленного поведения (то, что тест падал бы без исправления, — слова исправителей, не перепроверялось): previewToken
  (F-money-rules-1), одобрение скидки (F-money-rules-2), повтор отклонённого заказа (F-orders-1c-1), ветка
  «деньги получены — отклонён 1С» (F-orders-1c-2), потеря `dead`-строк и конфликта (F-flutter-data-1), ключ
  `checkout_draft` (F-flutter-data-2), неизвестный исход POST /orders (F-flutter-ui-1). Flutter-исправления
  неизвестного исхода и восстановления после перезапуска проверены unit- и widget-тестами, но не интеграционно.
- Полный прогон зелёный, кроме: матрицы T-ID этапа F (`--stage F`, код 1) и одного нестабильного теста этапа D
  (R1-N-01). Интеграционные тесты Flutter не запускались (нет места на C:).
- Остаются незакрытыми по коду и тестам (major): F-trace-1 (152 T-ID без теста и причины), F-trace-2 (100 % ветвей
  для создания заказа и платежей не достигнуто), F-trace-5 (новый integration-сценарий ни разу не прошёл), F-trace-4
  (нет integration-теста перезапуска по RM-F-013 п. 4). F-trace-7 скептики оценили как minor.
- Ждут решения по ТЗ: F-money-rules-5 (CUST-023 ↔ 08 §4.8.1), остаток F-orders-1c-4 (код в CHECK 07),
  F-flutter-ui-12 (накладная, Q-019), F-flutter-ui-19 (ICU plural в контракте l10n), F-trace-11 (код в 08/OpenAPI),
  F-trace-15 (имя выхода в 13), F-flutter-ui-15 (SCR-22 в навигации), а также FIX-F-02…13 и FIX-FE-01…09.

## 7. Вывод по воротам G-F

**Ворота G-F не закрываются.**

1. **RM-F-010** не выполнен на копии 1С: копии базы и HTTP-сервиса расширения нет. Отчёт `F_onec_e2e_report.md`
   («не выполнено, блокер для I») соответствует критерию 4, но закрыть ворота без копии 1С можно только при
   **письменном решении заказчика** об отложении RM-F-010 до этапа I с принятием риска. Такого решения в
   репозитории нет.
2. **RM-F-009** выполнен частично: матрица T-ID этапа F красная (152 ID без теста и причины), 100 % ветвей для
   критичных сценариев (создание заказа, платёж) не достигнуто.
3. **RM-F-013 п. 4, RM-F-005 п. 2, RM-F-007 п. 2** (integration): сценарии перезапуска и «1С недоступна» не
   подтверждены интеграционным прогоном. Новый сценарий pos_flow_test был красным, а повтор невозможен, пока на C:
   меньше 300 МБ.
4. Вопросы FIX-F-* / FIX-FE-* и F-money-rules-5 ждут владельцев ТЗ. Результат по ним может изменить код.

Чтобы закрыть ворота, нужно: письменное решение заказчика по RM-F-010; разметка T-ID и доведение `--stage F` до
«без теста и причины 0» (или not_done с причиной); 100 % ветвей либо утверждённые владельцем 13 исключения;
освободить место на C: и получить зелёные `pos_flow_test`, `catalog_flow_test`, `auth_flow_test`,
`admin_invite_flow_test`, `boot_test`; решения владельцев ТЗ по перечисленным вопросам.

---

# Раунд 2 (перепроверка после исправлений раунда 2)

Дата: 2026-10-23, 09:23…10:31. Проверяющий: независимый агент. Окружение то же, что в раунде 1; на C: свободно
31–39 МБ (< 300 МБ). Все прогоны 1С — **на фикстурах, не реальная интеграция**. Код не менялся; записаны только этот
раздел и раздел «Перепроверка после ревью, раунд 2» в `docs/stages/F_test_run.log`.

## R2.1. Методика

1. Что менялось после раунда 1 — по `find -newer docs/reviews/F_review.md` (08:03): `pos-api/src/common/db/database.module.ts`,
   `pos-api/src/worker.ts` (слушатель `error` у пула pg), 36 файлов `pos-api/test`, `scripts/trace_test_ids.py`,
   `scripts/check_money_vectors.py`. В `pos-app/**`, `docs/specification/**`, `contracts/**`, `resursi/`, ядре изменений
   нет. Поэтому статусы замечаний, которые в раунде 2 не исправлялись, перенесены из раунда 1 и подтверждены только
   тем, что их тесты зелёные в свежем прогоне.
2. Полный свежий прогон всех проверок из задания (кроме integration_test Flutter — нет места на C:).
3. Замечания, которые исправлялись в раунде 2 (F-trace-1, F-trace-2; F-trace-4/5 исправитель отметил как not_fixed),
   сверены с выводом инструментов: полная матрица `trace_test_ids.py --stage F` (без `--summary`), разбор всех 42
   not_done по причине, `coverage/stage-f/coverage-summary.json` для критичных файлов, выборочная проверка тегов T-ID
   в тестах (T-SYNC-035, T-FAIL-012, T-PAY-008, T-CART-008, T-SEC-023 — теги стоят над тестами, которые проверяют
   названное), чтение `createPool`.
4. Для not_done, где исправитель сослался на «нет правила» или «не реализовано», проверено ТЗ (07 DATA-228, 10 CART-005,
   02 SCR-15 UI-15-007).

## R2.2. Повторный прогон

| Проверка | Результат | Итог |
|---|---|---|
| pos-api `lint`, `build`, `madge`, `check:permissions` | код 0; 503 файла, 0 циклов; 77 кодов / 7 ролей | зелёный |
| pos-api `test:all` (27 наборов) | 1209 passed, 7 skipped, 0 failed (было 1179) | зелёный |
| pos-api `test:cov:f` | 667 passed; строки 92.8 %, ветви 79.98 %; пороги строк и «храповик» ветвей выполнены | зелёный (100 % ветвей RM-F-009 — нет) |
| pos-api `test:cov:e`, `test:cov:d` | 496 passed; 378 passed | зелёный (R1-N-01 не повторился) |
| pos-api `test:e2e:pos` | 1 passed | зелёный |
| local-stack `smoke` / `auth-smoke` / `catalog-smoke` / `pos-smoke` | 10/10, 15/15, 22/22, 30/30 PASS (фикстуры) | зелёный |
| миграции `run-sql --repeat-strict` (prod; dev/test) | 0 изменений; 63/63 и 64/64 таблиц, 45/45 enum; check_ddl_behavior — 62 негативных сценария OK | зелёный |
| `flutter analyze` | No issues found | зелёный |
| `flutter test --concurrency=2` | 1650 passed | зелёный |
| golden (`--tags golden`) | 220 passed | зелёный |
| `check_layers`, `sync_contracts --check` | код 0 | зелёный |
| `flutter build windows --release` | собрано | зелёный |
| integration `pos_flow_test`, `catalog_flow_test`, `auth_flow_test`, `admin_invite_flow_test`, `boot_test` | **не выполнялись: нет места на C:** | not_done |
| `check_no_double_money.sh`, `check_secrets.py`, `build_openapi.py --check`, `check_api_paths.py`, `check_enums.py`, `check_arb_keys.py` | код 0 | зелёный |
| `check_repo_layout`, `check_env_example`, `check_api_permissions`, `check_enum_triangle`, `check_onec_paths`, `check_money_vectors`, `gen_errors_matrix --check` | код 0 | зелёный |
| `trace_test_ids.py --stage D` / `--stage E` | без теста и причины 0 | зелёный |
| `trace_test_ids.py --stage F` | охват 242; с тестом 200 (частично 62); not_done 42; **без теста и причины 0; код 0** (в раунде 1 — 152, код 1) | зелёный по критерию скрипта; по существу — см. R2.4 |

## R2.3. Все подтверждённые замечания: статус после раунда 2

«Р1» — статус раунда 1. Severity — исходная; в скобках — оценка скептиков, если ниже. «Без изменений» значит: код по
замечанию после раунда 1 не менялся, закрывающие тесты зелёные в этом прогоне.

| ID | Направление | Severity | Файл | Суть | Доказательство (раунд 2) | Р1 | Статус |
|---|---|---|---|---|---|---|---|
| F-fresh-run-1 | scripts | major | docs/repo_layout.md | `pos-api/assets/` не описан | `check_repo_layout` код 0 | fixed | fixed |
| F-fresh-run-2 | docs | minor | docs/stages/F_test_run.log | в журнале нет части скриптов корня | все скрипты с кодами — в разделе раунда 2 журнала | fixed | fixed |
| F-money-rules-1 | backend | critical | pos-api/src/orders/order-create.service.ts | previewToken не проверялся | без изменений; e2e orders-money-rules зелёный | fixed | fixed |
| F-money-rules-2 | backend | critical | pos-api/src/cart/checkout.service.ts | одобрение скидки распространялось на больший % | без изменений; e2e зелёный | fixed | fixed |
| F-money-rules-3 | backend | major | pos-api/src/orders/order-create.service.ts | причина / `discount_override` / аудит не переносились | без изменений; e2e зелёный (+ новый кейс в orders-create) | fixed | fixed |
| F-money-rules-4 | backend | major (minor) | pos-api/src/cart/checkout.service.ts | preview ≠ order при `to_som` | без изменений; e2e зелёный | fixed | fixed |
| F-money-rules-5 | backend | major (minor; один скептик опроверг) | pos-api/src/orders/order-create.service.ts | заказ клиента без привязки — на «Розничного» | код не менялся; ждёт решения FIX-F-01 (10 CUST-023 ↔ 08 §4.8.1) | not_fixed | not_fixed (решение по ТЗ) |
| F-money-rules-6 | backend | major (minor) | pos-api/src/orders/orders.request.ts | `lineTotal`/`discountAmount` не распознавались | без изменений; unit + e2e зелёные | fixed | fixed |
| F-money-rules-7 | backend | minor | pos-api/src/orders/order-create.service.ts | `sameItems` через Money | без изменений; e2e зелёный | fixed | fixed |
| F-money-rules-8 | backend | minor | pos-api/src/cart/checkout.service.ts | `canCreateOrder=true` при отказе в долге | без изменений; cart-flow зелёный | fixed | fixed |
| F-money-rules-9 | backend | minor | pos-api/test/sales-domain/pricing.spec.ts | property-тесты тавтологичны | без изменений: оракул 07 §7.3 есть; «preview ≡ order» и политика одобрения — только e2e | partially_fixed | partially_fixed |
| F-orders-1c-1 | backend | critical | pos-api/src/sync/api/sync-outbox.service.ts | повтор отклонённого заказа (ORD-027) | без изменений; e2e orders-outbox зелёный | fixed | fixed |
| F-orders-1c-2 | backend | critical | pos-api/src/orders/worker/order-onec-results.handler.ts | «деньги получены — отклонён 1С» неполно | без изменений; e2e зелёный; добавлен order-onec-results.int (ветви обработчика 91.4 %) | fixed | fixed |
| F-orders-1c-3 | backend | major | pos-api/src/orders/order-cancel.service.ts | повторная отмена после отказа 1С терялась | без изменений; e2e orders-ops зелёный | fixed | fixed |
| F-orders-1c-4 | backend | major | pos-api/src/payments/qr/qr-status.service.ts | оплата после void без `sync_errors` и уведомлений | без изменений; код `OTHER` + `payload.code` до решения FIX-F-06 | partially_fixed | partially_fixed (остаток — решение по ТЗ) |
| F-orders-1c-5 | backend | major | pos-api/src/payments/qr/qr-issuer.service.ts | перевыпуск QR без отмены, без истории | без изменений; миграция 0012 повторно применяется без изменений | fixed | fixed |
| F-orders-1c-6 | backend | minor | pos-api/src/payments/qr/qr-status.service.ts | опрос в `qr_expired` | без изменений | fixed | fixed |
| F-orders-1c-7 | backend | minor | pos-api/src/sales-domain/payment/payment-status.ts | `cancelled` от 1С игнорировался | без изменений; ветви payment-status 100 % | fixed | fixed |
| F-orders-1c-8 | backend | minor | pos-api/src/payments/app/payments.service.ts | фоновая отмена без `.catch` | без изменений | fixed | fixed |
| F-security-1 | backend | major (minor) | pos-api/src/payments/app/payment-presenter.ts | клиенту отдавался статический QR | без изменений; e2e зелёный | fixed | fixed |
| F-security-2 | backend | major | pos-api/src/common/rate-limit/http-rate-limit.ts | RL-FIN не реализован | без изменений; e2e 429 зелёный | fixed | fixed |
| F-security-3 | backend | minor | pos-api/src/orders/order-query.service.ts | `sort` через `in` | без изменений | fixed | fixed |
| F-security-4 | backend | minor | pos-api/src/payments/long-poll/payment-status-waiter.ts | нет пределов long-polling | без изменений | fixed | fixed |
| F-security-5 | backend | minor | pos-api/src/orders/order-create.service.ts | нет аудита `credit.sale_blocked` | без изменений; + кейс отказа по долгу с creditReason | fixed | fixed |
| F-flutter-ui-1 | flutter | critical (major) | pos-app/…/checkout_controller.dart | неизвестный исход POST /orders | без изменений; widget-тесты зелёные; интеграционно не проверено | fixed | fixed |
| F-flutter-ui-2 | flutter | major | pos-app/…/checkout_controller.dart | CTA активна во время предпроверки | без изменений | fixed | fixed |
| F-flutter-ui-3 | flutter | major | pos-app/…/drift_checkout_draft_repository.dart | после перезапуска заказ по ключу не ищется | без изменений; тест на реальном drift зелёный; интеграционно не проверено | fixed | fixed |
| F-flutter-ui-4 | flutter | major | pos-app/lib/app/di/overrides.dart | роль SCR-26 не подключена | без изменений | fixed | fixed |
| F-flutter-ui-6 | flutter | major (minor) | pos-app/…/order_created_screen.dart | нет «Открыть восстановленную корзину» | без изменений | fixed | fixed |
| F-flutter-ui-7 | flutter | major (minor) | pos-app/…/cart_panel_view.dart | UI-20-004, UI-20-033 | без изменений | fixed | fixed |
| F-flutter-ui-8 | flutter | major (minor) | pos-app/test/design_system | нет golden side 400/480 | без изменений; golden 220 passed | fixed | fixed |
| F-flutter-ui-9 | flutter | minor | pos-app/…/cart_panel_view.dart | нет F4 | без изменений | fixed | fixed |
| F-flutter-ui-10 | flutter | minor | pos-app/…/cart_fab_view.dart | подпись диктора | без изменений | fixed | fixed |
| F-flutter-ui-11 | flutter | minor | pos-app/…/order_created_screen.dart | нет OfflineBanner | без изменений | fixed | fixed |
| F-flutter-ui-12 | flutter | minor | pos-app/…/order_view_rules.dart | накладная всегда недоступна | код не менялся; FIX-FE-03 (Q-019) | not_fixed | not_fixed (решение по ТЗ) |
| F-flutter-ui-13 | flutter | minor | pos-app/…/notifications_screen.dart | снекбар UI-44-011 только на SCR-44 | без изменений | fixed | fixed |
| F-flutter-ui-14 | flutter | minor | pos-app/…/checkout_screen.dart | литеральные отступы | без изменений; исключения 5/6 lp и `SizedBox` (FIX-FE-05) | partially_fixed | partially_fixed |
| F-flutter-ui-15 | flutter | minor | pos-app/…/checkout_screen.dart | SCR-21/22 непрозрачные | без изменений; SCR-22 — FIX-FE-04 | partially_fixed | partially_fixed |
| F-flutter-ui-16 | flutter | minor | pos-app/…/cart_panel_view.dart | цель 32 lp | без изменений | fixed | fixed |
| F-flutter-ui-17 | flutter | minor | pos-app/lib/design_system/components/cart_line.dart | сумма строки без тыйынов | без изменений | fixed | fixed |
| F-flutter-ui-18 | flutter | minor | pos-app/…/checkout_sections.dart | мета клиента обрезается | без изменений | fixed | fixed |
| F-flutter-ui-19 | docs | minor | pos-app/lib/l10n/app_ru.arb | нет ICU plural | ключи не менялись; владелец contracts/l10n (FIX-F-16) | not_fixed | not_fixed (решение владельца контракта) |
| F-flutter-data-1 | flutter | critical (major/critical) | pos-app/lib/core/database/daos/cart_draft_dao.dart | `dead`-строки и конфликт терялись | без изменений; drift_cart_sync_test зелёный | fixed | fixed |
| F-flutter-data-2 | flutter | critical (major/critical) | pos-app/…/checkout_controller.dart | ключ `checkout_draft` — Cart.id | без изменений; интеграционно не проверено | fixed | fixed |
| F-flutter-data-3 | flutter | major | pos-app/…/checkout_controller.dart | SCR-21 в обход CartSync | без изменений | fixed | fixed |
| F-flutter-data-4 | flutter | minor | pos-app/lib/core/session/session_local_data.dart | предупреждение «Выйти» без `dead`/`dirty` | без изменений | fixed | fixed |
| F-trace-1 | scripts | major | scripts/trace_test_ids.py | нет матрицы T-ID этапа F | `--stage F` код 0, «без теста и причины 0»; 145 ID с T-ID в тестах, 55 трасс, 62 «частично». Но 15 из 42 not_done — невыполненная работа этапа, а не перенос: **T-CART-004 (P1) — CART-005 в pos-app не реализован**, T-ORD-008, T-SYNC-037, T-TXN-008, T-SYNC-F03/F09/F13, T-UI-020…026/044 (см. R2.4). Критерий RM-F-009 «T-CART/T-ORD/… запущены» выполнен не полностью | partially_fixed | partially_fixed |
| F-trace-2 | backend | major | pos-api/vitest.config.cov-f.ts | нет 100 % ветвей критичных сценариев | ветви: order-create 67.4 → 88.7 %, обработчик 1С 53.8 → 91.4 %, payments-port 77.4 → 91.9 %, payments.service 81.0 → 84.1 %, checkout 73.1 → 78.1 %; идемпотентность и автомат платежа 100 %; пороги подняты. Исключения по категориям — вопрос FIX-F-23 владельцу 13 (построчно не перепроверялись) | partially_fixed | partially_fixed |
| F-trace-3 | backend | major | pos-api/src/common/jobs/contracts/queues.ts | нет публикатора `catalog.*-changed` | без изменений; cart-catalog-sync зелёный | fixed | fixed |
| F-trace-4 | flutter | major (major/minor) | pos-app/…/order_created_controller.dart | RM-F-013 п. 4 (перезапуск при ожидании оплаты) | без изменений: только widget-тесты; integration-теста перезапуска во время QR нет (pos-app вне области раунда 2) | partially_fixed | partially_fixed |
| F-trace-5 | flutter | major | pos-app/integration_test/pos_flow_test.dart | нет integration для RM-F-005 п. 2 и RM-F-007 п. 2 | без изменений: сценарий есть, единственный прогон (раунд 1 исправителя) красный, повтор невозможен — нет места на C: | partially_fixed | partially_fixed |
| F-trace-6 | flutter | major (minor) | pos-app/lib/design_system/components/app_bottom_sheet.dart | нет golden side 400/480 | то же, что F-flutter-ui-8 | fixed | fixed |
| F-trace-7 | flutter | major (minor) | pos-app/test/features | приёмочные наборы T-UI неполны | матрица F теперь показывает долю AC-UI: SCR-20 17/30, SCR-21 13/27, SCR-22 8/14, SCR-23 6/13, SCR-24 15/17, SCR-25 9/12, SCR-26 7/12, SCR-44 8/13 (not_done); скептики: полнота наборов — этап H | partially_fixed | partially_fixed |
| F-trace-8 | backend | major (minor) | pos-api/test/orders/orders-create.e2e.spec.ts | нет тестов «без ключа» и «параллельно» | без изменений; e2e зелёный | fixed | fixed |
| F-trace-9 | backend | major (major/minor) | pos-api/src/jobs/outbox/outbox-dispatcher.ts | нет теста T-SYNC-032 | без изменений; e2e зелёный | fixed | fixed |
| F-trace-11 | backend | minor | pos-api/src/cart/cart.service.ts | GET /cart без каталога → 500 | без изменений: 503 `catalog_not_loaded`; код в 08/OpenAPI — FIX-F-07 | partially_fixed | partially_fixed (остаток — решение по ТЗ) |
| F-trace-12 | docs | minor | docs/errors_matrix.md | нет выхода RM-F-007 | `gen_errors_matrix --check` код 0 | fixed | fixed |
| F-trace-13 | backend | minor | contracts/test-vectors/money.v1.json | нет сверки MV-01…30 | `check_money_vectors` код 0 (backend 27/27 + 3 только клиента) | fixed | fixed |
| F-trace-14 | flutter | minor | pos-app/integration_test/pos_flow_test.dart | путь «с клиентом» не в not_done | T-ORD-001/T-ORD-003 — «частично» с причиной RM-G-001; T-UI-026 — not_done с причиной «исправитель Flutter», а не RM-G-001; сида клиентов в local-stack нет | not_fixed | partially_fixed |
| F-trace-15 | docs | minor | 13 §3.6 RM-F-009 | имя выхода `checkout_flow_test.dart` | 13 не менялся (FIX-F-15) | not_fixed | not_fixed (решение по ТЗ) |

Итого 60 подтверждённых замечаний: **fixed — 45, partially_fixed — 11, not_fixed — 4** (в раунде 1: 45 / 10 / 5;
изменился статус только у F-trace-14). Все 4 not_fixed ждут решения по ТЗ или владельца контракта.

Опровергнутые (F-flutter-ui-5, F-trace-10) — без изменений, см. §4 раунда 1.

## R2.4. Новые наблюдения раунда 2

Эти наблюдения скептики не проверяли; оценка — проверяющего.

| ID | Severity | Суть | Доказательство |
|---|---|---|---|
| R2-N-01 | major | **10 CART-005 (must) не реализован в pos-app**: смены варианта в строке корзины («Вариант» → SCR-15 в режиме смены, «Заменить вариант», `ConfirmDialog` «Объединить количества?») нет. T-CART-004 (P1, этап F по 12 §2.15) записан в матрице как not_done «НЕ РЕАЛИЗОВАНО — исправителю Flutter». В раунде 1 этот пробел был скрыт среди 152 ID без трассы | поиск `variant_replace_cta` и `variant_merge_confirm` в `pos-app/lib/features` — 0 совпадений (ключи есть только в ARB); 02 SCR-15 UI-15-007, 10 CART-005, AC-CART-005 |
| R2-N-02 | minor | 07 DATA-228 (should): `payload_hash` не сверяется перед отправкой. В FIX-F-20 сказано, что нужен код ошибки, но 07 DATA-228 уже задаёт исход (`dead` + `sync_errors (HASH_MISMATCH)`), а `HASH_MISMATCH` есть в CHECK (`0001_init.sql:1595`, 07 §6.1.1). Вопрос владельцу не нужен, требование реализуемо | поиск `payload_hash` в `pos-api/src` — только запись в `onec-outbox.writer.ts`; при доставке хеш не проверяется |
| R2-N-03 | minor | Матрица `--stage F` «зелёная» (код 0) отчасти за счёт причин not_done вида «исправителю Flutter» и «НЕ РЕАЛИЗОВАНО». Это не перенос, а невыполненная работа (15 из 42: T-CART-004, T-ORD-008, T-SYNC-037, T-TXN-008, T-SYNC-F03/F09/F13, T-UI-020…026/044). Код выхода 0 не означает, что RM-F-009 выполнен | полный вывод `trace_test_ids.py --stage F` (`.tmp/rev2/trace_f_full.txt`) |
| R2-N-04 | info | Исправитель раунда 2 нашёл и исправил дефект backend: у `pg.Pool` не было слушателя `error`, и разрыв соединений БД ронял процесс API/worker. Исправление прочитано (`createPool`, `worker.ts:116`), тест T-FAIL-012 зелёный. При недоступной БД API отвечает 500, а 12 ждёт 503 — вопрос FIX-F-19 | `pos-api/src/common/db/database.module.ts:32-40`; health.e2e |
| R1-N-01 | minor | Нестабильный `otp.e2e-spec.ts` в этом раунде не повторился (`test:all` и `test:cov:e` зелёные). Один прогон не доказывает, что причина устранена | `.tmp/rev2/testall.txt`, `cove.txt` |

## R2.5. Итог (раунд 2)

- Полный прогон зелёный: pos-api (1209 тестов, покрытие F/E/D, процессный e2e, четыре smoke), миграции, pos-app (analyze,
  1650 тестов, 220 golden, сборка Windows), все скрипты корня, включая матрицу `--stage F` (код 0).
- Интеграционные тесты Flutter **не выполнялись: нет места на C:** (31–39 МБ). Сценарии перезапуска и «1С недоступна»
  по-прежнему не подтверждены ни одним зелёным интеграционным прогоном.
- Раунд 2 закрыл формальную часть F-trace-1 (матрица есть и честно показывает статус каждого ID) и заметно поднял
  ветвевое покрытие (F-trace-2). По существу RM-F-009 не выполнен: T-CART-004 (P1) не выполнен, потому что CART-005 не
  реализован (R2-N-01); 100 % ветвей нет, исключения не утверждены.
- Остаются незакрытыми по коду и тестам (major): F-trace-1 (остаток: CART-005 / T-CART-004 и другие невыполненные
  not_done), F-trace-2 (ветви < 100 % без утверждённых исключений), F-trace-4 (нет integration-теста перезапуска во
  время ожидания оплаты). F-trace-5 упирается в окружение: тест есть, но не прошёл, а повторить его нельзя без места на C:.
  F-trace-7 скептики оценили как minor (полнота наборов T-UI — этап H).
- Ждут решения по ТЗ: F-money-rules-5 (FIX-F-01), F-orders-1c-4 (FIX-F-06), F-flutter-ui-12 (FIX-FE-03),
  F-flutter-ui-19 (FIX-F-16), F-trace-11 (FIX-F-07), F-trace-15 (FIX-F-15), F-flutter-ui-15 (FIX-FE-04), F-trace-2
  (FIX-F-23), а также новые FIX-F-18, FIX-F-19, FIX-F-21, FIX-F-22. FIX-F-20 решения не требует (R2-N-02).

## R2.6. Вывод по воротам G-F (раунд 2)

**Ворота G-F не закрываются.** Причины те же, что в раунде 1 (§7), с уточнениями:

1. **RM-F-010** не выполнен на копии 1С. Письменного решения заказчика отложить RM-F-010 до этапа I с принятием
   риска в репозитории по-прежнему нет. Без него G-F не закрываются, даже если всё остальное будет выполнено.
2. **RM-F-009** выполнен частично. Матрица T-ID есть (код 0), но T-CART-004 (P1) не выполнен, потому что CART-005 не
   реализован (R2-N-01). 100 % ветвей для создания заказа и платежей не достигнуто, исключения (FIX-F-23) не утверждены.
3. **RM-F-013 п. 4, RM-F-005 п. 2, RM-F-007 п. 2** (integration) не подтверждены: интеграционные тесты не запускались
   (на C: < 300 МБ), а integration-теста перезапуска во время ожидания оплаты нет.
4. Решения владельцев ТЗ по FIX-F-* / FIX-FE-* и F-money-rules-5 не получены.

Чтобы закрыть ворота, нужно:
- письменное решение заказчика по RM-F-010;
- реализовать CART-005 в pos-app (SCR-15, режим смены) и тест T-CART-004; закрыть или обоснованно перенести остальные
  «НЕ РЕАЛИЗОВАНО» / «исправителю Flutter» в матрице F;
- получить 100 % ветвей либо утверждённые владельцем 13 исключения;
- освободить место на C: (≥ 300 МБ) и получить зелёные `pos_flow_test` (с новыми сценариями), `catalog_flow_test`,
  `auth_flow_test`, `admin_invite_flow_test`, `boot_test`;
- написать integration-тест RM-F-013 п. 4 (перезапуск во время ожидания оплаты);
- получить решения владельцев ТЗ по перечисленным вопросам.


# Закрытие остатков этапа F (итог после ревью закрытия, 2026-10-23)

Раздел дописан автором итоговых документов этапа F, а не независимым проверяющим. Источники: журнал
`docs/stages/F_test_run.log` (разделы «Прогон после закрытия остатков F», «… повтор при свободном месте на C:»,
«Второй круг ревью закрытия F …» и **«Финальный прогон этапа F»**, строки 1357–1424), `docs/stages/F_spec_sync.md` §5, итоги исправителей
и проверочные выводы `D:/optomstroy/.tmp/rs_fix/check_{before,after}.txt`. Каждый статус ниже подтверждён либо
финальным прогоном (код 0), либо поиском по файлам в этом прогоне; что подтвердить не удалось — сказано явно.

## ЗО.1. Ход закрытия

1. **Закрытие остатков** (исправители контрактов, backend и Flutter): OpenAPI и `enums.json` 1.2.0 (ADR-103),
   `QR_PAID_AFTER_VOID` в CHECK (миграция 0013) и в реализации, 26 ключей ARB этапа F и ICU plural, CART-005 /
   T-CART-004, сверка `payload_hash` (DATA-228, T-SYNC-037), состав RL-ADMIN (RC-10), property-тест «preview ≡ order»,
   100 % ветвей критичных файлов, T-UI-026.
2. **Ревью закрытия, круг 1** (замечания к контрактам и ТЗ RS-1…RS-10, RC-5, RC-10, RR-3): исправлено, разовая сверка
   исправлений — 47 проверок, провалено 0 (`F_spec_sync.md` §5.4–§5.5).
3. **Независимый прогон при свободном месте на C:** (журнал «… повтор при свободном месте на C:») — все команды код 0,
   впервые после ревью пройдены все пять `integration_test` на Windows. Одно замечание — отчёт устарел (стало RR-1).
4. **Ревью закрытия, круг 2** — 20 подтверждённых замечаний (§ЗО.2), исправления Fix2 (ТЗ, backend, Flutter).
5. **Финальный прогон этапа F** (этот проход, журнал 1357–1424) — после Fix2: все команды код 0 — pos-api `lint`, `test:all` (1316 passed, 0 failed), `test:cov:f` (774 passed, ветви критичных файлов 100 %), целевые тесты RC-5/RC-6/RC-7; pos-app `flutter analyze`, `flutter test` (+1759), `pos_flow_test` 4 из 4 и `catalog_flow_test` 2 из 2 на Windows; скрипты корня, `trace_test_ids --stage F` 242 / 211 / 31 / 0.

## ЗО.2. Замечания ревью закрытия, круг 2

Все 20 замечаний переданы исправителям как подтверждённые ревью: 1 major (RS-1; при проверке исправления severity
признана завышенной — minor), 19 minor. Опровергнутых замечаний в материалах круга 2, переданных этому проходу, нет.
Колонка «Проверено здесь» — чем статус подтверждён в финальном прогоне.

| ID | Severity | Суть | Подтверждено / опровергнуто | Статус | Проверено здесь |
|---|---|---|---|---|---|
| RS-1 | major (→ minor) | Пометка Q-329 у 10 CUST-023 приостанавливала правило документа-владельца, а AC-CUST-023, 13 RM-F-015, 12 T-CUST-015 и замечание №23 в 12 оставались без пометки и противоречили реализации | подтверждено | fixed: пометки Q-329 расставлены, рекомендация «08 выравнивает по 10» снята; Q-329 за заказчика не решён | `check_after.txt` RS-1 ×5 OK |
| RS-2 | minor | Q-329 и пометка CUST-023 ссылались на ядро §22.3, которое карточку заявки не определяет | подтверждено | fixed: ссылка заменена на 08 §4.8.1 + ядро §24.2 | `check_after.txt` RS-2 OK |
| RS-3 | minor | 07 §5.53 записывал переход на `QR_PAID_AFTER_VOID` как бэклог, хотя реализация уже пишет код | подтверждено | fixed: 07 v1.13, §21.13 | `payments-qr-onec.e2e` в `test:all` |
| RS-4 | minor | 10 AC-CART-035: чужая отложенная без права — 403, реализация и 08 — 404 | подтверждено | fixed: 404 `NOT_FOUND` (FQ-CART-03 (be)); правило CART-035 не менялось | поиск в 10 |
| RS-5 | minor | 10 AC-TXN-008 без пометки Q-330 | подтверждено | fixed: `[ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА: Q-330]` | поиск в 10 |
| RS-6 | minor | 03 §16.8 и 02 SCR-25 п. (3) описывали временные ключи как действующие | подтверждено | fixed: 03 v1.4, 02 SCR-25 | `check_arb_keys` код 0 |
| RS-7 | minor | Правки описаний в OpenAPI 1.2.0 без подъёма версии не были оговорены правилом CHANGELOG | подтверждено | fixed: «Исключение для не выпущенной версии» в шапке CHANGELOG | поиск в CHANGELOG; `build_openapi --check` код 0 |
| RS-8 | minor | 04 FLOW-021.E7 — метка «новое имя» у `QR_PAID_AFTER_VOID` | подтверждено | fixed: 04 v1.7 | поиск в 04 |
| RS-9 | minor | README и 00: числа строк документов и ADR (103) устарели | подтверждено | fixed | `check_after.txt` RS-9 OK |
| RS-10 | minor | Комментарии pos-app утверждали, что сервер не отдаёт `Cart.restoredFromOrder` | подтверждено | fixed: комментарии и имя теста отката | `flutter test` |
| RC-1 | minor | Смена варианта (`replaceVariant`) оставляла в копии и очереди `cart.sync` старую или целевую строку: «Повторить» могло вернуть удалённую строку или откатить объединённое количество | подтверждено | fixed: `CartSync.direct(settle)`; тесты на drift в памяти (мутационная проверка — слова исправителя) | `flutter test` |
| RC-2 | minor | Сбой между PUT нового варианта и удалением старого оставлял после перезапуска обе строки | подтверждено | fixed: журнал замены `cart_variant_replace` в `app_meta`, досведение в `refresh` | `flutter test` |
| RC-3 | minor | 08 §2.9 называл RL-ADMIN для чтения `/sync/*`, `/openapi.json`, `confirm`/`reject` бэклогом, хотя это реализовано | подтверждено | fixed | поиск в 08 §2.9; `orders-rate-limit.e2e` в `test:all` |
| RC-4 | minor | 02 SCR-44.3: цвет `payment_status` «по статусу», которого сервер не передаёт | подтверждено | fixed: цвет по `severity` (так и реализовано) | поиск в 02 |
| RC-5 | minor | Фейк БД в `order-create-branches.spec.ts` не проверял параметры запросов — тесты не ловили мутации | подтверждено | fixed: запись запросов, проверка параметров INSERT | `test:all`, `test:cov:f` |
| RC-6 | minor | Property-тест «preview ≡ order» — 8 прогонов | подтверждено | fixed: 60 прогонов, фиксированный seed, `ORDERS_PROPERTY_RUNS/SEED`; ночной job CI не добавлен (CI не запускался) | `test:all` |
| RC-7 | minor | `since` / `before` уведомлений не проверялись на RFC 3339 со смещением | подтверждено | fixed: 400 `VALIDATION_FAILED`, 18 unit-кейсов | `test:all` |
| RC-8 | minor | Отказ сервера `max_items` (201-я строка): строка оставалась в копии, каталог показывал «Добавлено» | подтверждено | **partially_fixed**: строка удаляется, каталог показывает отказ; для «В корзину» SCR-14, скана и повтора заказа снекбар виден только при открытой корзине | `flutter test` |
| RC-9 | minor | 06 §6.9 и 16 §4.3 не описывали `APP_DATA_DIR` | подтверждено | fixed | поиск в 06, 16 |
| RR-1 | minor | `F_cart_pos_report.md` устарел относительно прогона при свободном месте на C: (F-KI-04, F-KI-14, трасса) | подтверждено | fixed; отчёт ещё раз обновлён этим проходом по финальному прогону | — |

Итого круга 2: fixed — 19, partially_fixed — 1 (RC-8), not_fixed — 0.

## ЗО.3. Статусы прежних незакрытых замечаний (после раунда 2: partially_fixed 11, not_fixed 4)

| ID | После раунда 2 | Сейчас | Основание |
|---|---|---|---|
| F-money-rules-5 | not_fixed | **not_fixed** (ждёт заказчика) | Q-329 (CUST-023 ↔ 08 §4.8.1): реализовано допущение 08; за заказчика не решено; расхождение с владельцем 10 записано (RS-1) |
| F-money-rules-9 | partially_fixed | fixed (с оговоркой) | «preview ≡ order» — property-тест на реальной корзине и `POST /orders` (`orders-preview-order.property.e2e.spec.ts`, 60 прогонов, RC-6); лимит роли — property в `pricing.spec.ts`; одобрение сверх лимита — примерами и e2e, не property |
| F-orders-1c-4 | partially_fixed | fixed | `QR_PAID_AFTER_VOID` в CHECK (0013), пишется `qr-status.service.ts`; `payments-qr-onec.e2e` |
| F-flutter-ui-12 | not_fixed | **not_fixed** (решение по ТЗ) | накладная до отгрузки — Q-019, FIX-FE-03 |
| F-flutter-ui-14 | partially_fixed | partially_fixed | исключения 5/6 lp и литералы `SizedBox` записаны в 03 DS-025 (FIX-FE-05); код не менялся |
| F-flutter-ui-15 | partially_fixed | partially_fixed | SCR-22 — непрозрачный маршрут; вынос `/orders/{id}/created` — бэклог навигации (FIX-FE-04) |
| F-flutter-ui-19 | not_fixed | fixed | ICU plural у четырёх ключей корзины в `contracts/l10n` (ADR-103), `build_arb --check`, `check_arb_keys` код 0 |
| F-trace-1 | partially_fixed | fixed | матрица F: 242 / 211 / 31 / 0; невыполненной работы среди not_done нет, кроме T-TXN-008 (ждёт Q-330) |
| F-trace-2 | partially_fixed | partially_fixed | ветви всех критичных файлов 100 % (`test:cov:f`); перечень защитных ветвей `F_branch_exceptions.md` (E-1…E-3) владельцем 13 не утверждён; 13 §3.6 ещё приводит старые проценты |
| F-trace-4 | partially_fixed | fixed | `pos_flow_test`: «перезапуск во время ожидания QR» — зелёный |
| F-trace-5 | partially_fixed | fixed | `pos_flow_test`: перезапуск над той же БД, «1С недоступна → `submitting` → уведомление» — зелёные |
| F-trace-7 | partially_fixed | fixed | T-UI-020…026, T-UI-044 с тестами (T-UI-026 — AC-UI-26-008); полнота наборов — этап H |
| F-trace-11 | partially_fixed | fixed | `503 catalog_not_loaded` в 08 §4.7.1 и OpenAPI 1.2.0 |
| F-trace-14 | partially_fixed | partially_fixed | путь «с клиентом» на стенде — этап G (RM-G-001), сида клиентов нет |
| F-trace-15 | not_fixed | **not_fixed** (решение по ТЗ) | строка критерия RM-F-009 в 13 по-прежнему называет `checkout_flow_test.dart`; уточнение записано ниже таблицы 13 §3.6 (FIX-F-15) |

Новые наблюдения раундов 1–2: R2-N-01 (CART-005) и R2-N-02 (`payload_hash`) — закрыты; R2-N-03 — снят (среди not_done
нет невыполненной работы этапа, кроме T-TXN-008 по Q-330); R1-N-01 (нестабильный `otp.e2e-spec.ts`) — в прогонах
закрытия не повторился, причина не установлена.

**Итог по 60 подтверждённым замечаниям раундов 1–2:** fixed — **53** (было 45; +7 из partially_fixed, +1 из
not_fixed — F-flutter-ui-19), partially_fixed — **4** (F-flutter-ui-14, F-flutter-ui-15, F-trace-2, F-trace-14),
not_fixed — **3** (F-money-rules-5 — Q-329; F-flutter-ui-12 — Q-019; F-trace-15 — FIX-F-15). Все 3 not_fixed ждут
решения заказчика или владельца ТЗ. Вместе с кругом 2 ревью закрытия (20 замечаний: 19 fixed, 1 partially_fixed —
RC-8) открытыми по коду остаются только partially_fixed RC-8, F-flutter-ui-14/15, F-trace-14 (minor) и F-trace-2
(ждёт утверждения исключений владельцем 13).

## ЗО.4. Новые наблюдения этого прохода (автор итоговых документов, скептиками не проверялись)

| ID | Severity | Суть | Статус |
|---|---|---|---|
| ZO-N-01 | minor | 13 §3.6 (уточнение к RM-F-009) приводит проценты ветвей на 2026-10-23 до закрытия остатков (`order-create` 88,7 % и т. д.), тогда как `test:cov:f` даёт 100 % | не исправлено: `docs/specification` вне области этого прохода; владелец 13 |

## ЗО.5. Вывод по воротам G-F

**Ворота G-F не закрываются.**
1. RM-F-010 не выполнен на копии 1С, письменного решения заказчика отложить его до этапа I в репозитории нет.
2. Перечень защитных ветвей `F_branch_exceptions.md` (FIX-F-23) владельцем 13 не утверждён.
3. Q-325…Q-330 (в т. ч. Q-329 — CUST-023) без ответа; реализованы текущие допущения.

Всё остальное, что ревью раундов 1–2 и кругов 1–2 закрытия требовало по коду и тестам, выполнено и подтверждено
финальным прогоном (журнал 1357–1424: все команды код 0, `pos_flow_test` 4 из 4 и `catalog_flow_test` 2 из 2 на Windows).
Открытыми по коду остаются только незначительные: RC-8 (частично), F-flutter-ui-14/15, F-trace-14 (этап G).
Для закрытия G-F нужны: письменное решение заказчика по RM-F-010 (или копия 1С и выполненная проверка) и решение
владельца 13 по `F_branch_exceptions.md`. Ответы на Q-325…Q-330 нужны до этапа G (Q-325 — до I, отчёт §4.2); от них
может измениться код.

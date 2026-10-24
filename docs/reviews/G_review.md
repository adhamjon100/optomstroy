# Независимая проверка этапа G «Cashier» (раунды 1 и 2)

Разделы 1–7 — раунд 1 (без изменений). Раунд 2 — разделы 8–13 в конце документа.

Дата: 2026-10-24. Проверяющий: независимый агент (13 §3.7, ворота G-G). Машина: Windows 11 Pro 10.0.26200, Node 24,
embedded PostgreSQL 17, Flutter 3.38.7 / Dart 3.10.7. Android-устройств, реальной 1С и тестовой копии 1С нет. Все
прогоны — на FakeOnecGateway / ScriptedOnecGateway, управляемом фейке HTTP-сервиса 1С в режиме кассира и фикстурах
`contracts/onec/fixtures`: **на фикстурах, не реальная интеграция**.

Код при перепроверке не менялся. Записаны только этот отчёт и разделы «Перепроверка после ревью, раунд 1» и «…,
раунд 2» в `docs/stages/G_test_run.log`.

Основание проверки: 10_POS_BUSINESS_RULES (CUST-, DEBT-, PAY-031, DISC-, TXN-, CASH-, RET-, FAV-, AUD-), 08 +
`contracts/openapi/pos-api.v1.yaml` 1.2.0, 07, 05, 11 + `contracts/rbac/permissions.yaml`, 02 (SCR-30…39, SCR-41…48,
режим клиента), 03, 04, 06, 12, 13 §3.7 (RM-G-001…RM-G-014, ворота G-G), 14 (допущения Q-015, Q-017, Q-018, Q-152,
Q-329), ядро R0 v1.9 (приоритет §24 > §23 > … > §16).

## 1. Методика

1. **Направления ревью**, по каждому — отдельный проверяющий: `fresh-run` (повторный прогон журнала), `credit` (долг,
   PAY-031, скидки сверх лимита), `customers-1c` (клиенты, дедупликация, outbox клиента и заказа), `returns-txn` (журнал
   транзакций, возвраты), `security` (RBAC, режим клиента, step-up, аудит, лимиты), `flutter-ui` (SCR-30…48), `flutter-data`
   (состояние, память сессии, отмена запросов), `trace` (T-ID → тест, выходы RM-G-*, покрытие).
2. **Два скептика** на каждое серьёзное замечание: каждый независимо пытался опровергнуть его по коду и ТЗ и, где можно,
   воспроизводил зондом. Замечание подтверждено, если его не опроверг ни один. Если скептики оценили ниже, это указано.
3. **Исправления** выполнили два исправителя (backend и Flutter). Их решения и вопросы владельцам ТЗ —
   `docs/stages/G_spec_questions.md`, разделы «FIX» (FIX-G-TXN-07, FIX-G-RL-RECV, FIX-G-DISC-404, FIX-G-TXN-AUDIT,
   FIX-G-TXN-SIGN, FIX-G-SNAP-FUTURE, FIX-G-HIST-90, FIX-G-DEBT-013, FIX-G-CRED-TX, FIX-G-ORD-DEP, FIX-G-CUS-STUB,
   FIX-G-RETENTION, FIX-G-AUDIT-JOBS; FIX-G-FE-SETTINGS-LABELS, FIX-G-FE-OVERDUE-TOTAL, FIX-G-FE-LIMIT-NOT-SET,
   FIX-G-FE-OUTBOX-LABELS, FIX-G-FE-PRINT, FIX-G-FE-TRACE, FIX-G-FE-ENV).
4. **Перепроверка (этот раунд)**: полный свежий прогон (раздел 2) и сверка каждого подтверждённого замечания с текущим
   кодом и тестом: чтение изменённых участков, поиск по коду, наличие тестов с ID замечания и их прохождение в свежем
   прогоне. Статусы исправителей на веру не принимались.

## 2. Повторный прогон после исправлений (раунд 1)

Подробности и выдержки — `docs/stages/G_test_run.log`, раздел «Перепроверка после ревью, раунд 1»; сырые логи —
`D:/optomstroy/.tmp/verify_g1/`.

| Проверка | Результат | Итог |
|---|---|---|
| pos-api `lint`, `build`, `madge`, `check:permissions` | код 0; 601 файл, 0 циклов; 77 кодов / 7 ролей | зелёный |
| миграции `run-sql --repeat-strict` (prod; dev/test + `check_ddl_behavior`) | 0 изменений; 63/63 и 64/64 таблиц, 45/45 enum; 62 негативных сценария OK | зелёный |
| pos-api `test:all` (34 набора) | 1687 passed, 8 skipped, 0 failed (с первого раза) | зелёный |
| pos-api `test:cov:g` | 723 passed; строки 95.09 %, ветви 82.8 %; каждый каталог G ≥ 80 % строк (returns/onec 87.62 %); критичные файлы — пороги 100 % выполнены (с первого раза) | зелёный |
| pos-api `test:cov:f` | 799 passed; строки 94.13 %; критичные файлы F (в т. ч. `order-create.service.ts`, `discount-policy.ts`) — 100 % ветвей | зелёный |
| pos-api `test:cov:e` | 1-й прогон: 1 failed из 555 (`otp.e2e-spec.ts`, этап D, 500 вместо 202); повтор файла ×3 и повтор `test:cov:e` — зелёные | **нестабильный** (R1-N-01) |
| pos-api `test:cov:d` | 449 passed; строки 97.92 % | зелёный |
| pos-api `test:e2e:pos`, `test:e2e:cashier` | 1/1, 1/1 | зелёный |
| local-stack `smoke` / `auth-smoke` / `catalog-smoke` / `pos-smoke` / `cashier-smoke` | 10/10, 15/15, 22/22, 30/30, 22/22 PASS | зелёный |
| `flutter analyze` | No issues found | зелёный |
| `flutter test --concurrency=2 --coverage` | 2240 passed | зелёный |
| golden (`--tags golden`) | 362 passed | зелёный |
| `check_layers`, `sync_contracts --check` | 0 нарушений; l10n идентичны | зелёный |
| integration `cashier_flow_test` | 5 passed (добавлены FLOW-042, FLOW-023, офлайн SCR-34/31, проверка хранилищ) | зелёный |
| integration `pos_flow_test`, `catalog_flow_test`, `boot_test` | 4, 2, 1 passed | зелёный |
| integration `auth_flow_test`, `admin_invite_flow_test` | 1-й запуск упал из-за ошибки проверяющего (стек без `LOCAL_STACK_MIN_APP_VERSION` → 426); повтор по инструкции тестов — 3 и 1 passed | зелёный |
| `flutter build windows --release` | собрано | зелёный |
| `check_no_double_money.sh`, `check_secrets.py` | 0 совпадений; 0 находок (2671 файл) | зелёный |
| `check_repo_layout.py`, `build_openapi.py --check`, `check_api_paths.py`, `check_enums.py`, `check_arb_keys.py` | код 0 (0 ошибок) | зелёный |
| `trace_test_ids.py --stage G --summary` | охват 125; с тестом 104 (частично 12); not_done с причиной 21; без теста и причины 0; UI 18/1/17 | зелёный по гейту; T-UI — см. G-trace-7 |
| Flutter-покрытие domain/data фич G (lcov) | итог 87.4 %; cashier, transactions, returns — 100 %; customers 96.6/89.7; admin 91.5/82.8; reports 91.9/100; **profile 61.4/55.0, settings/domain 50.4** | см. G-trace-12, R1-N-02 |

Android/iOS не запускались (эмулятор запрещён условиями этапа). На C: перед integration_test было 3,5 ГБ свободно.

## 3. Подтверждённые замечания и их статус после исправлений

Severity — исходная оценка; в скобках — оценка скептиков, если ниже. Статус — по текущему коду и тестам этого прогона.
`fixed` — дефект устранён и закрыт тестом, который прошёл; `partially_fixed` — устранена часть; `not_fixed` — не
менялось; `not_a_defect` — подтверждено как сбой окружения.

| ID | Направление | Severity | Файл | Суть | Доказательство после исправления (кратко) | Статус |
|---|---|---|---|---|---|---|
| G-fresh-run-1 | backend | minor | pos-api/package.json (`test:all`) | `test:cart` упал из-за нехватки памяти (PG 1455) | Свежий `test:all` с первого раза — код 0, 0 failed; в README pos-api добавлен раздел о памяти | not_a_defect |
| G-fresh-run-2 | backend | minor | vitest.config.cov-g.ts | `test:cov:g` — heap OOM, покрытие verifier занижено | Свежий `test:cov:g` с первого раза — код 0, пороги критичных файлов выполнены | not_a_defect |
| G-fresh-run-3 | backend | minor | src/returns/onec/returns-jobs.bridge.ts | Мост pg-boss возвратов 35 % строк, returns/onec 76.5 % | `test/returns/returns-jobs.bridge.spec.ts`; отдельный каталог `returnsOnec` в cov-g; факт: мост 100 % строк, returns/onec 87.62 % | fixed |
| G-fresh-run-4 | docs | minor | docs/stages/G_test_run.log §1 | Итоговая таблица устарела (trace, check_secrets) | §1: trace 125/104/21/0, check_secrets код 0 — совпадает со свежим прогоном | fixed |
| G-credit-1 | backend | critical (major) | snapshot-credit-decision.service.ts | После refresh условия соглашения не перечитывались | Стр. 169-172: после `refreshed` карточка перечитывается `customers.load`, шаги 1–2 повторяются; unit `credit-decision.unit.spec.ts` и e2e «G-credit-1» в `receivables-credit.e2e.spec.ts` — прошли | fixed |
| G-credit-2 | backend | major (major/minor) | onec-receivables.parser.ts; receivables-snapshot.writer.ts; credit-decision.ts | Метка снимка «из будущего» принималась и блокировала новые снимки | `RECEIVABLES_CLOCK_SKEW_MS` = 5 мин: парсер отклоняет (оба вызова передают `receivedAt`), `isFresh`/`isStale` считают будущую метку непригодной, writer перезаписывает; unit парсера и e2e «G-credit-2» прошли. Допуск 5 мин — предложение исправителя (FIX-G-SNAP-FUTURE) | fixed |
| G-credit-3 | backend | major | order-create.service.ts | Лимит в долг не перепроверялся в транзакции заказа | `recheckCreditInTx`: `pg_advisory_xact_lock(hashtext('credit:'||id))` + `check(tx, allowRefresh=false)` до INSERT; e2e «G-credit-3» (два параллельных POST: один 201/202, второй 422) прошёл | fixed |
| G-credit-4 | backend | major (major/minor) | test/receivables/receivables-credit.e2e.spec.ts | Нет обязательных кейсов T-PAY-033 (9, 10, 13, 16), AC-PAY-032, strict preview = POST /orders | Добавлены тесты стр. 804 (13–16, strict preview), 872 (токен чужой сессии → 403), 887 (C-2 свежий → без 1С, нет снимка → STALE), 684 (1С меняет условия); прошли | fixed |
| G-credit-5 | backend | minor | order-create.service.ts | Отметки разблокировки и discount_override писались без фактического применения | `creditApproval = creditOverrideUsed ? …`; скидка — только по `snap.discountApprovedByUserId`; e2e «G-credit-5» прошёл | fixed |
| G-credit-6 | backend | minor | vitest.config.cov-f.ts / cov-g | 100 % ветвей «скидки сверх лимита» стояло на файле, который не решает | `src/sales-domain/pricing/discount-policy.ts` в CRITICAL_BRANCHES cov-f; `test:cov:f` код 0 | fixed |
| G-credit-7 | backend | minor | order-create.service.ts | Нет in-app уведомления `credit_blocked` (DEBT-013) | `notifyCreditBlocked` на всех путях отказа; e2e T-DEBT-011 прошёл; trace T-DEBT-011 — тест | fixed |
| G-customers-1c-1 | backend | critical | order-create.service.ts; onec-order-payload.ts | Заказ нового клиента уходил в 1С без зависимости и с `customer.ref=null` | `dependsOnOutboxId: customerCreateDependency(...)`; диспетчер выдаёт ссылки клиента-зависимости, `withDependencyCustomer` дополняет тело при доставке; e2e AC-SYNC-049 в cashier-flow и unit прошли. Остаток (minor): при `failed`/`dead` клиента заказ остаётся `pending` без причины в `last_error` (05 SYNC-042 требует `next_attempt_at=NULL` и причину) | fixed |
| G-customers-1c-2 | backend | critical (major) | pg-customer-matching.ts; customer-onec-results.handler.ts; customers-change.handler.ts | Заглушка реплики в окне «доставлено, результат не обработан» → дубль, POS-клиент `duplicate` | Ref из ответа на `customer/create` распознаётся как свой клиент (стр. 104-115), при отправке в процессе заглушка не создаётся; заглушка удаляется в onConfirmed и applyPartner; `customers-review-g.e2e.spec.ts` прошёл. Побочный эффект (minor): пока POS-клиент с тем же телефоном «в полёте», другие кандидаты 1С с этим телефоном не возвращаются | fixed |
| G-customers-1c-3 | backend | major (minor) | customer-create.service.ts | Гонка двух POST /customers с одним телефоном | Advisory-блокировки по телефонам и ИНН в отсортированном порядке, повторная проверка реплики под блокировкой; e2e параллельных запросов [201, 409] прошёл | fixed |
| G-customers-1c-6 | backend | major (minor) | customers-list.service.ts | `GET /customers?q=<номер>` без сигнала `customer.phone_lookup` | Стр. 107: `phoneLookups.record` при `!wideSearch && byPhone`; e2e на 51 запрос прошёл. Маршрут остался в RL-READ (необязательная часть исправления) | fixed |
| G-customers-1c-7 | backend | minor | customer-history.service.ts | Нет периода по умолчанию 90 дней; 366 дней не проверялось при одной границе | `HISTORY_DEFAULT_DAYS = 90`, проверка при одной границе (стр. 83-87); e2e прошли | fixed |
| G-returns-txn-1 | backend | critical (major) | return-docs.handler.ts | Повторная доставка документа возврата закрывала другую заявку | При существующей строке refund (dedupe_key) документ пропускается; `matchRequest` исключает заявки с refund; e2e в `returns-review-g.e2e.spec.ts` прошёл | fixed |
| G-returns-txn-2 | backend | major | order-cancel.service.ts; order-projection.ts | `order_cancelled` писался с «+» | `orderJournalAmount`: `order_cancelled` → −total на всех путях (оба писателя идут через `insertOrderTransaction`); тесты cashier-world и transactions (знак, summary) прошли | fixed |
| G-returns-txn-3 | backend | major (major/minor) | order-create.service.ts | `discount_override` (и `credit_sale_approved`) с суммой в sumIn | Обе строки пишутся с 0.00, суммы в `details`; инвариант-тест журнала прошёл. Для `credit_sale_approved` = 0 — толкование исправителя, ждёт подтверждения владельца 07 (FIX-G-TXN-SIGN) | fixed |
| G-returns-txn-4 | backend | major | return-docs.handler.ts | TXN-007: реализации и ПКО 1С не попадают в журнал | Код не менялся; нужен вид `transaction_kind` и лента ПКО в контракте 1С — решение владельцев 07/05 (FIX-G-TXN-07) | not_fixed (решение ТЗ) |
| G-returns-txn-5 | backend | minor | returns.repository.ts; 0001_init.sql (триггер) | Параллельные заявки на одну реализацию проходили обе | `shipmentLines … FOR UPDATE OF si` (стр. 185); e2e 4 параллельных POST → один 201 прошёл. Триггер не менялся: прямые SQL-вставки в обход сервиса не сериализуются | fixed |
| G-security-1 | backend | major | audit-anchor.service.ts | Задачи `audit.anchor` / `audit.verify` не запускались | `AuditJobsBridge` (AdminAuditModule, pos-worker при `WORKERS_ENABLED`): cron 03:30 и вс 03:45 Asia/Bishkek, файл якоря; очереди в QUEUES; `test/admin/audit-jobs.admin-spec.ts` прошёл | fixed |
| G-security-2 | backend | major (minor/major) | receivables.service.ts; discounts.service.ts | При `CUSTOMER_SELF_SERVICE=false` клиенту отдавались долг и условия | 403 для customer в `view`, `customerDiscounts`, `rules`; e2e в `customers-self-service-off` прошёл | fixed |
| G-security-3 | backend | major | step-up.service.ts / step-up.operations.ts | Клиент не мог получить step-up на детализацию своего долга | `stepUpPermitted`: `customer.receivables.read.detail` при `customer.self.receivables.read`; e2e через настоящий `POST /auth/step-up` (sessions.e2e-spec) прошёл | fixed |
| G-security-4 | backend | major (minor) | receivables.service.ts | RL-RECV-REFRESH в памяти процесса вместо Postgres | Код не менялся; нужен scope в CHECK `rate_limit_counters` (07) или решение «memory» в 08 §2.9 (FIX-G-RL-RECV) | not_fixed (решение ТЗ) |
| G-security-5 | backend | minor | discounts.service.ts | Чужая карточка → 403, несуществующая → 404 (раскрытие) | Для customer привязка проверяется до поиска; чужая/proposed/нет → 404; `discounts.e2e` обновлён и прошёл. 08 §4.11.6 и OpenAPI ещё говорят 403 (FIX-G-DISC-404) | fixed |
| G-security-6 | backend | minor | customers-list.service.ts | Дубль G-customers-1c-6 | То же исправление и тест | fixed |
| G-security-7 | backend | minor | transactions.service.ts | `audit[]` в `GET /transactions/{id}` без `audit.viewed` | `audit.viewed {source: transaction, …}` при непустом audit[]; проверка в transactions.e2e прошла. 08 §4.14.2 ждёт выравнивания (FIX-G-TXN-AUDIT) | fixed |
| G-security-8 | backend | minor | customer-card.service.ts | `customer.debt_viewed` без `snapshotAt`, ключ `view` | Единый формат `{scope, snapshotAt, via}` во всех путях; customers-directory e2e прошёл | fixed |
| G-flutter-ui-2 | flutter | major | unfinished_operations.dart; payment_controller.dart | Незавершённые confirm/void не восстанавливались на SCR-38 | `forOrder` по любому виду; «Результат неизвестен» и тот же ключ для confirm/void; `payment_unfinished_flow_test.dart` прошёл | fixed |
| G-flutter-ui-3 | flutter | major | app_shell.dart | HID-скан кода заказа на SCR-30 не реализован; нет `payment_scan_disabled` | `cashierHidOverride` в `HidScanScope.onEvent`: /cashier → `GET /orders?q=` → SCR-38 или лист; /payments → снекбар; `test/app/cashier_hid_scan_test.dart` прошёл | fixed |
| G-flutter-ui-4 | flutter | major (minor) | dashboard_sections.dart | Нет «Обновить» при устаревшем снимке, подпись без «1С», порог 60 мин зашит | Подпись «Данные 1С на HH:MM», чип и «Обновить», порог из `GET /sync/status`; 4 widget-теста прошли; в golden SCR-30 подпись видна | fixed |
| G-flutter-ui-5 | flutter | major (minor) | dashboard_sections.dart | Итог просрочек считается по обрезанному списку из 10 | При 10 строках итог не показывается, вместо него «Все просрочки» (тест). Настоящий итог требует `PosDashboard.overdueTotal` в 08 (FIX-G-FE-OVERDUE-TOTAL) | partially_fixed (остаток — решение ТЗ) |
| G-flutter-ui-6 | flutter | major (major/none) | admin_settings_sections.dart | Подписи полей SCR-46 — сырые ключи API | Код не менялся (стр. 237 `label = field.key`); нет строк ARB, контракт l10n меняет владелец 02 §7 (FIX-G-FE-SETTINGS-LABELS) | not_fixed (решение ТЗ) |
| G-flutter-ui-7 | flutter | major (major/minor) | test/features/customers/golden | Нет golden SCR-33, SCR-35, SCR-40 | Добавлены compact/medium/expanded в ci и windows; golden-прогон 362 passed | fixed |
| G-flutter-ui-8 | flutter | major | pos-app/test | Нет теста «permissions.yaml ↔ видимость в UI» | `test/app/router/rbac_matrix_test.dart` разбирает permissions.yaml и сверяет CashierRoles, CustomersViewer, ReturnsViewer, SyncRunPolicy, маршруты; прошёл | fixed |
| G-flutter-ui-9 | flutter | major (minor) | admin_settings_screen_test.dart | Нет widget-теста «Показ остатков клиенту» (RM-G-014 п. 4) | Тесты admin (diff → StepUpDialog → PUT одного ключа) и owner (поле недоступно) прошли | fixed |
| G-flutter-ui-10 | flutter | minor | payment_screen.dart | Роль null → кассовые действия разрешены | fail-closed, тест для роли null | fixed |
| G-flutter-ui-11 | flutter | minor | cashier_dashboard_screen.dart | Таймер 30 с для QR TTL и часов | 1 с при наличии QR, иначе граница минуты; 2 теста прошли | fixed |
| G-flutter-ui-12 | flutter | minor | transaction_row.dart | `order_created` зелёным «+», номер обрезан | Тон по виду операции, заказ — textPrimary без знака, заголовок в 2 строки; `transaction_row_test` и golden SCR-30/36 обновлены и прошли | fixed |
| G-flutter-ui-13 | flutter | minor | cashier_dashboard_screen.dart | В шапке SCR-30 нет логотипа, пользователя, меню аватара | TopAppBarUser, меню (Профиль, Настройки, Заблокировать, Выйти), ConnectedSyncIndicator, логотип через порт корня; тесты прошли. В golden SCR-30 логотипа нет (порт корня не подставлен в harness) | fixed |
| G-flutter-data-1 | flutter | major (minor) | debt_snapshot.dart | Порядок статуса долга не по PAY-031 | Порядок: нет данных → credit_allowed → overdue_amount → лимит не задан/исчерпан → неполон/устарел; `overdueDays` не блокирует; `debt_snapshot_test` прошёл. Строки «Лимит в 1С не задан» в ARB нет (FIX-G-FE-LIMIT-NOT-SET) | fixed |
| G-flutter-data-2 | flutter | major (major/minor) | unfinished_operations.dart | Незавершённые операции переживали выход → вход того же пользователя | `cashierSessionScopeProvider` даёт новый объект при каждой смене userId; `unfinished_operations_test` (падал на старом коде) прошёл | fixed |
| G-flutter-data-3 | flutter | minor | customers_search_controller.dart; audit_screen.dart | Устаревшие запросы не отменялись | CancelSignal → dio CancelToken в портах search/list/history/audit; `customers_cancel_test`, `cancel_signal_dio_test`, audit_screen_test прошли | fixed |
| G-trace-1 | flutter | critical (major) | sync_status_screen.dart | На SCR-43 нет вкладок «Ошибки» и «Outbox», повтор outbox из приложения невозможен | SyncJournalPort (`/sync/runs/{id}/errors`, `/sync/outbox`, `retry` с Idempotency-Key), вкладки и «Повторить» для admin и senior_seller; `sync_journal_tabs_test`, `sync_journal_api_test` прошли. Не сделано: фильтр по агрегату UI-43-014, локализованные статусы outbox и коды ошибок (нет ARB — FIX-G-FE-OUTBOX-LABELS), шаг integration_test | partially_fixed |
| G-trace-3 | flutter | major | app_shell.dart | Дубль G-flutter-ui-3 | То же исправление и тест | fixed |
| G-trace-4 | flutter | major (minor) | settings_screen.dart | Секция «Принтер» SCR-42 скрыта | `AppPrinterSettingsPort` в корне: формат, автопечать, адрес/порт, тестовая печать 80 мм (ESC/POS по TCP) и A4 (PDF); `printer_settings_port_test` прошёл. USB ESC/POS не поддержан; причины ошибок технические — нет строк ARB (FIX-G-FE-PRINT) | fixed |
| G-trace-5 | flutter | major | pos-app/test | Дубль G-flutter-ui-7 | То же | fixed |
| G-trace-6 | flutter | major (major/minor) | role_guard_test.dart | Дубль G-flutter-ui-8 | То же | fixed |
| G-trace-7 | flutter | major (minor) | scripts/trace_test_ids.py | T-UI-030…048: 17 из 18 not_done | Ссылки AC-UI добавлены в часть тестов (SCR-30 — 15/22); `trace --stage G`: UI 18/1/17/0 без изменений. Часть AC зависит от полей контракта (FIX-G-FE-TRACE). Один скептик считает T-UI не обязательным для G (12 §2.15) | partially_fixed |
| G-trace-8 | flutter | major (major/minor) | integration_test/cashier_flow_test.dart | Сценарии кассира из 04 покрыты не все | Добавлены FLOW-042, FLOW-023, офлайн SCR-34/31; прогон 5/5. Нет: FLOW-016, 022 (ручное подтверждение QR на SCR-38), 025 (устаревший снимок), 029 (дубль клиента), 031 «Отклонить», 033, 037. Android не запускался (окружение) | partially_fixed |
| G-trace-9 | flutter | major | integration_test/cashier_flow_test.dart | T-DEBT-013, T-CUST-013 (P1) не выполнены | Шаги «офлайн SCR-34/SCR-31» и «финансов клиента нет ни в drift, ни в secure storage» прошли; trace DEBT 14/14, CUST 17/17. Перезапуск проверен сканированием хранилищ, не рестартом процесса; тексты причин «частично … у Flutter-интегратора» в trace устарели | fixed |
| G-trace-10 | backend | major (minor) | src/returns | Нет очистки черновиков возврата старше 7 дней | `ReturnsRetentionService.purgeExpiredDrafts` + очередь `retention.daily` 03:30; e2e (остаток освобождается) и unit регистрации прошли | fixed |
| G-trace-11 | backend | major | return-docs.handler.ts | Дубль G-returns-txn-4 (TXN-007) | Код не менялся (FIX-G-TXN-07) | not_fixed (решение ТЗ) |
| G-trace-12 | flutter | major (major/minor) | dio_returns_repository.dart и др. | Покрытие Flutter для G не измерялось; returns/data 62 % | Свежий lcov: returns 100/100, transactions 100/100, cashier 100/100, customers 96.6/89.7, admin 91.5/82.8, reports 91.9/100, итог 87.4 %; результат записан в G_test_run.log этим раундом. Profile и settings/domain ниже 80 % — см. R1-N-02 | fixed |
| G-trace-13 | backend | minor | order-create.service.ts | Дубль G-credit-7 | То же | fixed |
| G-trace-14 | scripts | minor | scripts/trace_test_ids.py | Устаревшие причины и несвязанные тесты в трассировке | Трассы для T-DEBT-006/008, T-CASH-001…004, 013, 016, T-CUST-002, T-RET-010 добавлены. Не сделано: fakeAsync-тест опроса дашборда 60 с (T-CASH-009 not_done), ID в тестах pos-app; T-TXN-006, T-TXN-009 с устаревшей причиной «у Flutter-интегратора» | partially_fixed |
| G-trace-15 | backend | minor | receivables-credit.e2e.spec.ts; admin-audit.admin-spec.ts | Receivable и AuditRow не валидировались по OpenAPI | `validateAgainst('Receivable')` (сводка и include=documents), `Page<AuditRow>` и каждая строка; тесты прошли | fixed |

Итог по 58 подтверждённым (дубли считаются отдельно): fixed — 47 (из них дубли G-security-6, G-trace-3, G-trace-5,
G-trace-6, G-trace-13 закрыты тем же исправлением, что и основное замечание), partially_fixed — 5 (G-flutter-ui-5,
G-trace-1, G-trace-7, G-trace-8, G-trace-14), not_fixed — 4 (G-returns-txn-4, G-trace-11, G-security-4,
G-flutter-ui-6 — все ждут решения ТЗ), not_a_defect — 2 (G-fresh-run-1, G-fresh-run-2).
Тесты «выключено» для ворот: `returns_enabled=false` (admin-settings-g, returns.e2e), `RETURNS_FROM_POS_ENABLED=false`
(returns.e2e, cashier-flow), `DEBT_PAYMENTS_FROM_POS` (rbac-matrix, public-settings), `QR_PROVIDER` (cart) — есть и
прошли в `test:all`.

## 4. Опровергнутые замечания

| ID | Severity (заявлено) | Суть | Почему опровергнуто |
|---|---|---|---|
| G-customers-1c-4 | major | `PartnerChange` без `phones` очищает телефоны клиента | Элемент плана обмена — объект в текущем состоянии; отсутствие поля по ТЗ означает «телефонов нет». Код делает то, что требует ТЗ |
| G-customers-1c-5 | major | При `POS_E_DUPLICATE` нет автопривязки к карточке 1С и перепривязки заказов | Расхождение документов ТЗ: по приоритету владельцев (05 SYNC-049, 10) кассир выбирает существующего клиента вручную; автопривязка 10 CUST-015 / 12 T-CUST-006 — вопрос владельцу, не дефект реализации |
| G-flutter-ui-1 | major | SCR-34 офлайн показывает суммы долга из памяти сеанса | Ядро §19.4, 10 CASH-015, 02 P-OFFLINE допускают показ данных, уже загруженных в текущем сеансе, только из памяти процесса; так и сделано |
| G-trace-2 | major | Нет `docs/known_issues.md`, `G_cashier_report.md`, `G_review.md` | Это выходы завершающего шага RM-G-010 и условия ворот G-G, который выполняется после независимой проверки; на момент ревью их отсутствие — не дефект |

## 5. Новые наблюдения раунда 1 (скептиками не проверялись)

| ID | Severity | Суть | Доказательство |
|---|---|---|---|
| R1-N-01 | minor | Нестабильный тест этапа D `test/e2e/auth/otp.e2e-spec.ts:61` («ответ request одинаков…»): `POST /auth/otp/request` дал 500 вместо 202 в 1-м `test:cov:e` | 1 failed из 555; в `test:all` этого прогона, в трёх повторах файла (26/26) и в повторе `test:cov:e` — зелёный. Похожая нестабильность того же файла отмечена в ревью F (R1-N-01 F). Причина 500 не установлена — владельцу auth |
| R1-N-02 | minor | Покрытие domain/data Flutter ниже 80 % у фич RM-G-008: profile (data 61.4 %, domain 55.0 %; `dio_profile_repository.dart` 4 %), settings/domain 50.4 % (`settings_entities.dart` 46 %, `settings_bindings.dart` 40 %) | lcov свежего прогона (`D:/optomstroy/.tmp/verify_g1/fe_cov_g.txt`). Итог по фичам G — 87.4 %, порог ворот «покрытие ≥ 80 %» в целом выполнен; RM-G-009 п. 2 говорит о модулях G |
| R1-N-03 | minor | Заказ на POS-клиента, чей `customer/create` ушёл в `failed`/`dead`, остаётся `pending` без причины в `last_error` | `outbox-dispatcher.ts:176-177` просто не выбирает такой элемент; 05 SYNC-042 требует `next_attempt_at=NULL` и причину в `last_error` |
| R1-N-04 | info | Для integration_test `auth_flow_test` и `admin_invite_flow_test` стек нужно поднимать с `LOCAL_STACK_MIN_APP_VERSION=android=0.1.0,windows=0.1.0`, иначе API отвечает 426 (версия клиента 0.1.0+1) | Указано только в комментарии тестов; в журнале G команда записана без переменной. Стоит записать полную команду в журнал/README |

## 6. Итог ревью (раунд 1)

- Свежий прогон зелёный по всем проверкам задачи, включая integration_test на Windows и сборку release. Единственная
  нестабильность — тест этапа D (R1-N-01), не связан с G.
- Все critical-замечания устранены по коду и закрыты тестами: G-credit-1, G-customers-1c-1, G-customers-1c-2,
  G-returns-txn-1. Критичный путь G-trace-1 (повтор outbox из приложения) теперь доступен; остаток — фильтр, подписи и
  шаг integration_test.
- Остаются незакрытыми по коду и тестам (major): **G-trace-8** (FLOW-016, 022, 025, 029, 031, 033, 037 нет в
  integration_test) и **G-trace-7** (наборы T-UI 17/18 not_done; скептики разошлись в оценке — major/minor).
- Ждут решения владельцев ТЗ (не дефект кода до решения): G-returns-txn-4 / G-trace-11 (TXN-007), G-security-4
  (RL-RECV-REFRESH), G-flutter-ui-6 (подписи SCR-46), G-flutter-ui-5 (итог просрочек), а также толкования
  FIX-G-TXN-SIGN, FIX-G-SNAP-FUTURE (допуск 5 мин), FIX-G-DISC-404, FIX-G-TXN-AUDIT.
- Окружение: Android не прогонялся (эмулятор запрещён); в G-trace-8 это ограничение окружения, а не недоработка.

## 7. Вывод по воротам G-G (раунд 1)

Ворота G-G (13 §3.7: RM-G-001…009, 011, 012, 014 закрыты; покрытие ≥ 80 %; отчёт RM-G-010; флаги и тесты
«выключено»; `docs/known_issues.md` актуален) **пока не проходятся**:

1. RM-G-010 не завершена: нет `docs/stages/G_cashier_report.md` и `docs/known_issues.md` (по G-trace-2 это следующий шаг
   после ревью — его надо выполнить).
2. RM-G-010 п. 1 «все сценарии кассира из 04 проходят» — не выполнено (G-trace-8: FLOW-022, 025, 029, 031 и др.).
3. Решения владельцев ТЗ по TXN-007, RL-RECV-REFRESH, подписям SCR-46 и итогу просрочек должны быть приняты или
   явно перенесены в `known_issues.md` / 14 до ворот.

Выполнено: покрытие backend G 95.09 % строк, каждый каталог ≥ 80 %, критичные файлы — 100 % ветвей; Flutter-итог по
фичам G 87.4 % (кроме profile/settings, R1-N-02); тесты `CUSTOMER_SELF_SERVICE=false`, `returns_enabled=false`,
`RETURNS_FROM_POS_ENABLED=false`, «оплата долга выключено» (RM-G-013, Q-152) в наборе зелёные; трассировка без
«без теста и причины».

Если пункты 1–3 закрыть (п. 2 — тестами или решением владельца 13 о составе RM-G-010 п. 1), замечаний, блокирующих
G-G по коду, не остаётся.

---

# Раунд 2 (перепроверка после исправлений раунда 2)

Дата: 2026-10-24, 12:24–13:51. Код при перепроверке не менялся. Записаны только разделы 8–13 этого отчёта (и
пометка в заголовке) и раздел «Перепроверка после ревью, раунд 2» в `docs/stages/G_test_run.log`.

## 8. Методика раунда 2

1. **Что изменилось с раунда 1.** Проверено по времени изменения файлов: после записи отчёта раунда 1 (11:37) изменён
   только pos-app. В `lib` — 9 файлов: сгенерированные `app_localizations*.dart` (ARB не менялись), `payment_screen.dart`,
   `payment_sections.dart`, `customer_card_controller.dart`, `customer_receivables_controller.dart`,
   `customer_card_view.dart`. В `test` — 5 файлов, плюс `integration_test/cashier_flow_test.dart`. В pos-api, scripts,
   contracts и миграциях изменений нет. Поэтому статусы backend-замечаний раунда 1 перенесены и подтверждены свежим
   прогоном (те же тесты прошли). Замечания G-trace-7 и G-trace-8, которые правил исправитель раунда 2, сверены заново
   по коду и тестам.
2. **Полный свежий прогон** всех проверок задачи (раздел 9), последовательно и без параллельных тяжёлых процессов (урок
   G-fresh-run-1/2). На C: перед integration_test было 3 514–3 540 МБ (≥ 300 МБ), `APP_DATA_DIR` — на D:.
3. **Сверка утверждений исправителя** раунда 2 с кодом: поиск шагов FLOW в `integration_test/*.dart`, наличие тестов
   на три найденных им дефекта pos-app, пересчёт AC-UI по выводу `trace_test_ids.py`. Ничего не принималось на веру.

## 9. Свежий прогон (раунд 2)

Сырые логи — `D:/optomstroy/.tmp/verify_g2/`.

| Проверка | Результат | Итог |
|---|---|---|
| pos-api `lint`, `build`, `madge`, `check:permissions` | код 0; 601 файл, 0 циклов; 77 кодов / 7 ролей | зелёный |
| миграции `run-sql --repeat-strict` (prod; dev/test + `check_ddl_behavior`) | 0 изменений; 63/63 и 64/64 таблиц, 45/45 enum; 62 негативных сценария, 6 инвариантов OK | зелёный |
| pos-api `test:all` (34 набора) | 1687 passed, 8 skipped, 0 failed (с первого раза) | зелёный |
| pos-api `test:cov:g` | 723 passed; строки 95.09 %, ветви 82.8 %; returns/onec 87.62 %; пороги критичных файлов выполнены | зелёный |
| pos-api `test:cov:f` | 799 passed; строки 94.13 %, ветви 83.45 % | зелёный |
| pos-api `test:cov:e` | 547 passed, 8 skipped, с первого раза (R1-N-01 не воспроизвёлся) | зелёный |
| pos-api `test:cov:d` | 449 passed; строки 97.92 % | зелёный |
| pos-api `test:e2e:pos`, `test:e2e:cashier` | 1/1, 1/1 | зелёный |
| local-stack `smoke` / `auth-smoke` / `catalog-smoke` / `pos-smoke` / `cashier-smoke` | 10/10, 15/15, 22/22, 30/30, 22/22 PASS | зелёный |
| `flutter analyze` | No issues found | зелёный |
| `flutter test --concurrency=2 --coverage` | 2256 passed (в раунде 1 — 2240; +16 тестов раунда 2) | зелёный |
| golden (`--tags golden`) | 362 passed | зелёный |
| `check_layers`, `sync_contracts --check` | 0 нарушений; l10n идентичны | зелёный |
| integration `cashier_flow_test` | 5 passed; новые шаги FLOW-025, FLOW-029 (S1–S4, A2), FLOW-022 на SCR-38, FLOW-031.A4 выполнились (их метки есть в логе) | зелёный |
| integration `pos_flow_test`, `catalog_flow_test`, `boot_test` | 4, 2, 1 passed | зелёный |
| integration `auth_flow_test`, `admin_invite_flow_test` | 3 и 1 passed (стек с `LOCAL_STACK_MIN_APP_VERSION`, см. R1-N-04) | зелёный |
| `flutter build windows --release` | собрано | зелёный |
| `check_no_double_money.sh`, `check_secrets.py` | 0 совпадений; 0 находок (2672 файла) | зелёный |
| `check_repo_layout.py`, `build_openapi.py --check`, `check_api_paths.py`, `check_enums.py`, `check_arb_keys.py` | код 0 (0 ошибок) | зелёный |
| `trace_test_ids.py --stage G --summary` | охват 125; с тестом 104; not_done с причиной 21; без теста и причины 0; UI 18/1/17 — как в раунде 1 | по гейту зелёный; T-UI — см. G-trace-7, R2-N-02 |
| Flutter-покрытие domain/data фич G (lcov) | итог 87.4 % (1668/1909), как в раунде 1; profile 61.4/55.0, settings/domain 50.4 | см. R1-N-02 |

Android/iOS не запускались (эмулятор запрещён условиями этапа).

## 10. Статус всех подтверждённых замечаний после раунда 2

Колонка «Доказательство (раунд 2)» показывает, что изменилось или чем замечание подтверждено сейчас. «Без изменений»
значит: код не менялся с раунда 1, а тест, закрывающий замечание, прошёл в свежем прогоне раздела 9. Severity —
исходная; в скобках — оценки скептиков, если они ниже.

| ID | Направление | Severity | Файл | Суть | Доказательство (раунд 2) | Статус |
|---|---|---|---|---|---|---|
| G-fresh-run-1 | backend | minor | pos-api/package.json | `test:cart` упал из-за нехватки памяти | `test:all` с первого раза — код 0 | not_a_defect |
| G-fresh-run-2 | backend | minor | vitest.config.cov-g.ts | heap OOM в `test:cov:g` | `test:cov:g` с первого раза — код 0 | not_a_defect |
| G-fresh-run-3 | backend | minor | returns-jobs.bridge.ts | Мост возвратов без тестов | Без изменений; мост 100 % строк, returns/onec 87.62 % | fixed |
| G-fresh-run-4 | docs | minor | G_test_run.log §1 | Устаревшая таблица §1 | Без изменений; §1 совпадает с прогоном (trace 125/104/21/0, check_secrets 0) | fixed |
| G-credit-1 | backend | critical (major) | snapshot-credit-decision.service.ts | После refresh условия соглашения не перечитывались | Без изменений; unit и e2e «G-credit-1» прошли | fixed |
| G-credit-2 | backend | major (major/minor) | onec-receivables.parser.ts и др. | Метка снимка «из будущего» | Без изменений; e2e «G-credit-2» прошёл; допуск 5 мин ждёт владельца (FIX-G-SNAP-FUTURE) | fixed |
| G-credit-3 | backend | major | order-create.service.ts | Лимит в долг не перепроверялся в транзакции заказа | Без изменений; e2e «G-credit-3» (два параллельных POST) прошёл | fixed |
| G-credit-4 | backend | major (major/minor) | receivables-credit.e2e.spec.ts | Нет кейсов T-PAY-033 (9, 10, 13, 16), AC-PAY-032 | Без изменений; добавленные кейсы прошли | fixed |
| G-credit-5 | backend | minor | order-create.service.ts | Отметки разблокировки и скидки без применения | Без изменений; e2e «G-credit-5» прошёл | fixed |
| G-credit-6 | backend | minor | vitest.config.cov-f.ts | 100 % ветвей не на том файле | Без изменений; `test:cov:f` код 0 | fixed |
| G-credit-7 | backend | minor | order-create.service.ts | Нет уведомления `credit_blocked` | Без изменений; e2e T-DEBT-011 прошёл | fixed |
| G-customers-1c-1 | backend | critical | order-create.service.ts; onec-order-payload.ts | Заказ нового клиента уходил в 1С без зависимости и без `customer.ref` | Без изменений; e2e AC-SYNC-049 прошёл. Остаток R1-N-03 (minor) не менялся | fixed |
| G-customers-1c-2 | backend | critical (major) | pg-customer-matching.ts и др. | Заглушка реплики → дубль | Без изменений; `customers-review-g.e2e.spec.ts` прошёл | fixed |
| G-customers-1c-3 | backend | major (minor) | customer-create.service.ts | Гонка двух POST /customers | Без изменений; e2e [201, 409] прошёл | fixed |
| G-customers-1c-6 | backend | major (minor) | customers-list.service.ts | Нет сигнала `customer.phone_lookup` | Без изменений; e2e на 51 запрос прошёл | fixed |
| G-customers-1c-7 | backend | minor | customer-history.service.ts | Нет 90 дней по умолчанию; 366 дней не проверялось при одной границе | Без изменений; e2e прошли | fixed |
| G-returns-txn-1 | backend | critical (major) | return-docs.handler.ts | Повторная доставка закрывала другую заявку | Без изменений; `returns-review-g.e2e.spec.ts` прошёл | fixed |
| G-returns-txn-2 | backend | major | order-cancel.service.ts | `order_cancelled` со знаком «+» | Без изменений; тесты знака и summary прошли | fixed |
| G-returns-txn-3 | backend | major (major/minor) | order-create.service.ts | `discount_override` и `credit_sale_approved` в sumIn | Без изменений; инвариант-тест прошёл; `credit_sale_approved` = 0 ждёт владельца 07 (FIX-G-TXN-SIGN) | fixed |
| G-returns-txn-4 | backend | major | return-docs.handler.ts | TXN-007: реализации и ПКО 1С не попадают в журнал | Без изменений (FIX-G-TXN-07) | not_fixed (решение ТЗ) |
| G-returns-txn-5 | backend | minor | returns.repository.ts | Параллельные заявки на одну реализацию | Без изменений; e2e 4 параллельных POST прошёл | fixed |
| G-security-1 | backend | major | audit-anchor.service.ts | `audit.anchor`/`audit.verify` не запускались | Без изменений; `audit-jobs.admin-spec.ts` прошёл | fixed |
| G-security-2 | backend | major (minor/major) | receivables.service.ts; discounts.service.ts | Долг клиенту при `CUSTOMER_SELF_SERVICE=false` | Без изменений; e2e self-service-off прошёл | fixed |
| G-security-3 | backend | major | step-up.service.ts | Клиент не мог получить step-up на детализацию долга | Без изменений; e2e через `POST /auth/step-up` прошёл | fixed |
| G-security-4 | backend | major (minor) | receivables.service.ts | RL-RECV-REFRESH в памяти процесса | Без изменений (FIX-G-RL-RECV) | not_fixed (решение ТЗ) |
| G-security-5 | backend | minor | discounts.service.ts | Ответ 403/404 раскрывает существование карточки | Без изменений; `discounts.e2e` прошёл; 08 и OpenAPI ждут выравнивания | fixed |
| G-security-6 | backend | minor | customers-list.service.ts | Дубль G-customers-1c-6 | То же | fixed |
| G-security-7 | backend | minor | transactions.service.ts | `audit[]` без `audit.viewed` | Без изменений; transactions.e2e прошёл | fixed |
| G-security-8 | backend | minor | customer-card.service.ts | Разный формат `customer.debt_viewed` | Без изменений; customers-directory e2e прошёл | fixed |
| G-flutter-ui-2 | flutter | major | unfinished_operations.dart | Незавершённые confirm/void не восстанавливались | Без изменений; `payment_unfinished_flow_test` прошёл | fixed |
| G-flutter-ui-3 | flutter | major | app_shell.dart | Нет HID-скана кода заказа на SCR-30 | Без изменений; `cashier_hid_scan_test` прошёл | fixed |
| G-flutter-ui-4 | flutter | major (minor) | dashboard_sections.dart | Нет «Обновить», подпись без «1С» | Без изменений; widget-тесты прошли | fixed |
| G-flutter-ui-5 | flutter | major (minor) | dashboard_sections.dart | Итог просрочек по обрезанному списку | Без изменений; для настоящего итога нужен `overdueTotal` в 08 (FIX-G-FE-OVERDUE-TOTAL) | partially_fixed (остаток — решение ТЗ) |
| G-flutter-ui-6 | flutter | major (major/none) | admin_settings_sections.dart | Подписи SCR-46 — ключи API | Без изменений (FIX-G-FE-SETTINGS-LABELS) | not_fixed (решение ТЗ) |
| G-flutter-ui-7 | flutter | major (major/minor) | customers golden | Нет golden SCR-33, 35, 40 | Без изменений; golden 362 passed | fixed |
| G-flutter-ui-8 | flutter | major | pos-app/test | Нет теста «permissions.yaml ↔ UI» | Без изменений; `rbac_matrix_test` прошёл | fixed |
| G-flutter-ui-9 | flutter | major (minor) | admin_settings_screen_test.dart | Нет теста «Показ остатков клиенту» | Без изменений; тесты прошли | fixed |
| G-flutter-ui-10 | flutter | minor | payment_screen.dart | Роль null — fail-open | В раунде 2 файл менялся только в части QR TTL; тест роли null прошёл | fixed |
| G-flutter-ui-11 | flutter | minor | cashier_dashboard_screen.dart | Таймер 30 с | Без изменений; тесты прошли | fixed |
| G-flutter-ui-12 | flutter | minor | transaction_row.dart | Тон и знак суммы `order_created` | Без изменений; тест и golden прошли | fixed |
| G-flutter-ui-13 | flutter | minor | cashier_dashboard_screen.dart | Шапка SCR-30 без пользователя и меню | Без изменений; тесты прошли | fixed |
| G-flutter-data-1 | flutter | major (minor) | debt_snapshot.dart | Порядок статуса долга не по PAY-031 | Без изменений; `debt_snapshot_test` прошёл | fixed |
| G-flutter-data-2 | flutter | major (major/minor) | unfinished_operations.dart | Память операций переживала выход | Без изменений; `unfinished_operations_test` прошёл | fixed |
| G-flutter-data-3 | flutter | minor | customers_search_controller.dart | Нет отмены устаревших запросов | Без изменений; тесты отмены прошли | fixed |
| G-trace-1 | flutter | critical (major) | sync_status_screen.dart | Нет вкладок «Ошибки» и «Outbox» на SCR-43 | Без изменений. Вкладки и «Повторить» есть и проверены тестами. Не сделаны: фильтр по агрегату UI-43-014 (minor), подписи статусов (нужны ARB, FIX-G-FE-OUTBOX-LABELS), шаг integration_test | partially_fixed |
| G-trace-3 | flutter | major | app_shell.dart | Дубль G-flutter-ui-3 | То же | fixed |
| G-trace-4 | flutter | major (minor) | settings_screen.dart | Секция «Принтер» скрыта | Без изменений; `printer_settings_port_test` прошёл | fixed |
| G-trace-5 | flutter | major | pos-app/test | Дубль G-flutter-ui-7 | То же | fixed |
| G-trace-6 | flutter | major (major/minor) | role_guard_test.dart | Дубль G-flutter-ui-8 | То же | fixed |
| G-trace-7 | flutter | major (minor) | scripts/trace_test_ids.py | T-UI-030…048: 17 из 18 not_done | **Раунд 2:** сокращённые метки AC развёрнуты, добавлено 18 кейсов. Найдены и исправлены 2 дефекта: «Обновить QR» на SCR-38 после TTL (тест AC-UI-38-007) и переполнение чипа Z7 на SCR-32. AC-UI: SCR-30 22/22, 31 9/12, 32 12/16, 34 14/17, 36 14/16, 38 24/29. Скрипт по-прежнему даёт UI 18/1/17. T-UI-030 полон по AC, но выводится not_done из-за устаревшей причины (R2-N-02). Остаток зависит от решений владельцев: 12/13 — входят ли T-UI в G-G (их не называют ни 12 §2.15, ни RM-G-009 п. 1); 02 — AC, которые неисполнимы или противоречат друг другу (FIX-G-FE-TRACE-2) | partially_fixed (остаток — решение ТЗ) |
| G-trace-8 | flutter | major (major/minor) | integration_test/cashier_flow_test.dart | Сценарии кассира из 04 покрыты не все | **Раунд 2:** добавлены и прошли FLOW-025, FLOW-029 S1–S4 и A2, FLOW-022 на SCR-38, FLOW-031.A4 «Отклонить». Найден и исправлен дефект: 503 на refresh долга показывался общей ошибкой (тест AC-UI-34-007 / AC-FLOW-025-05). Из перечня 01 GEN-005 (FLOW-020…031, 036) в integration_test теперь есть всё, **кроме FLOW-026 «Отмена заказа»**. Утверждение FIX-G-FE-FLOWS-2, что его прогоняет `pos_flow_test`, не подтвердилось (R2-N-01). FLOW-016, 033 и 037 вне GEN-005 — нужно решение владельца 13. Android — ограничение окружения | partially_fixed |
| G-trace-9 | flutter | major | cashier_flow_test.dart | T-DEBT-013, T-CUST-013 | Без изменений; шаг «офлайн» прошёл; причины в trace устарели (R2-N-02) | fixed |
| G-trace-10 | backend | major (minor) | src/returns | Нет очистки черновиков старше 7 дней | Без изменений; e2e прошёл | fixed |
| G-trace-11 | backend | major | return-docs.handler.ts | Дубль G-returns-txn-4 | Без изменений (FIX-G-TXN-07) | not_fixed (решение ТЗ) |
| G-trace-12 | flutter | major (major/minor) | dio_returns_repository.dart и др. | Покрытие Flutter для G не измерялось | Свежий lcov: итог 87.4 %; returns, transactions, cashier — 100 %; ниже 80 % только profile и settings/domain (R1-N-02) | fixed |
| G-trace-13 | backend | minor | order-create.service.ts | Дубль G-credit-7 | То же | fixed |
| G-trace-14 | scripts | minor | scripts/trace_test_ids.py | Устаревшие причины и несвязанные тесты | Без изменений: T-CASH-009 (опрос 60 с) not_done; устаревшие причины у T-TXN-006/009, T-DEBT-013, T-CUST-013, T-UI-030/042/043 (R2-N-02) | partially_fixed |
| G-trace-15 | backend | minor | receivables-credit.e2e.spec.ts | Receivable и AuditRow не валидировались по OpenAPI | Без изменений; тесты прошли | fixed |

Итог по 58 подтверждённым замечаниям: fixed — 47; partially_fixed — 5 (G-flutter-ui-5, G-trace-1, G-trace-7, G-trace-8,
G-trace-14); not_fixed — 4 (G-returns-txn-4, G-trace-11, G-security-4, G-flutter-ui-6, все ждут решения ТЗ);
not_a_defect — 2. Счёт статусов тот же, что в раунде 1, но остаток у G-trace-7 и G-trace-8 заметно меньше.

## 11. Опровергнутые замечания

Без изменений с раунда 1 (раздел 4): G-customers-1c-4, G-customers-1c-5, G-flutter-ui-1, G-trace-2. Код, к которому они
относятся, в раунде 2 не менялся. G-trace-2 по-прежнему относится к завершающему шагу RM-G-010, который идёт после ревью.

## 12. Наблюдения раунда 2 (скептиками не проверялись)

| ID | Severity | Суть | Доказательство |
|---|---|---|---|
| R2-N-01 | minor | FLOW-026 «Отмена заказа» (01 GEN-005) не прогоняется ни одним integration_test. FIX-G-FE-FLOWS-2 утверждает обратное: «FLOW-021, FLOW-026, FLOW-027 прогоняет `pos_flow_test`». FLOW-021 (QR из 1С) и FLOW-027 (товарный чек) там действительно есть, отмены нет | `grep -i "cancel\|отмен" integration_test/*.dart` находит только служебные комментарии и `cancelFuture` HTTP-адаптера; ключей `order-cancel*` нет. Отмену покрывают widget-тест `order_details_screen_test.dart` и e2e backend этапа F, но не UI против стенда |
| R2-N-02 | minor | `trace_test_ids.py` выводит устаревшие причины. T-UI-030 полон по AC (22/22), но остаётся not_done с причиной «HID-скан … не сделаны», хотя HID-скан сделан (G-flutter-ui-3). T-UI-042: «секция «Принтер» не подключена», хотя подключена (G-trace-4). T-UI-043: «вкладки «Ошибки» и «Outbox»», хотя они есть (G-trace-1). У T-DEBT-013, T-CUST-013, T-TXN-006, T-TXN-009, T-CASH-007, T-CASH-010 — «у Flutter-интегратора этапа G» | Вывод `trace_test_ids.py --stage G`; словарь причин — `scripts/trace_test_ids.py:738-752`. Для T-UI-030 скрипт берёт причину из `not_done`, потому что ни один тест не называет сам ID T-UI-030 |
| R2-N-03 | info | Исправитель раунда 2 отметил: токен step-up `return.submit` повторно используется для второй заявки в течение 15 минут, без диалога | Не проверялось. Срок step-up 15 мин задан в RM-G-009 и 09. Допустимо ли повторное использование токена для той же операции — вопрос владельцу 09/11; без проверки дефектом не считаю |
| R1-N-01…R1-N-04 | — | Наблюдения раунда 1 | R1-N-01 (нестабильный otp.e2e) в раунде 2 не воспроизвёлся. R1-N-02 (profile, settings/domain < 80 %) и R1-N-03 (заказ при `failed` клиента без причины) — без изменений. R1-N-04 учтён в команде прогона |

## 13. Итог и вывод по воротам G-G (раунд 2)

- Свежий прогон раунда 2 зелёный с первого раза по всем проверкам задачи, нестабильностей нет. Число тестов Flutter
  выросло с 2240 до 2256; backend без изменений (1687 passed).
- Исправитель раунда 2 закрыл большую часть остатка G-trace-8 (FLOW-022, 025, 029, 031.A4) и G-trace-7 (P1-экраны;
  у SCR-30 названы все AC). Попутно он нашёл и исправил три дефекта pos-app и закрыл их тестами: 503 на refresh долга,
  «Обновить QR» после TTL, переполнение чипа Z7.
- Не закрыто по коду (major, решения ТЗ не требует) только одно: **FLOW-026 в integration_test** — остаток G-trace-8
  (R2-N-01). Это пробел тестов, а не поведения: отмену покрывают widget-тест и e2e backend.
- Ждут решения владельцев ТЗ (до решения это не дефект кода): TXN-007 (G-returns-txn-4 / G-trace-11), RL-RECV-REFRESH
  (G-security-4), подписи SCR-46 (G-flutter-ui-6), итог просрочек (G-flutter-ui-5), состав T-UI в воротах G-G
  (G-trace-7, FIX-G-FE-TRACE-2), FLOW-016/033/037 в RM-G-010 п. 1 (FIX-G-FE-FLOWS-2), а также толкования
  FIX-G-TXN-SIGN, FIX-G-SNAP-FUTURE, FIX-G-DISC-404, FIX-G-TXN-AUDIT.
- Окружение: Android не прогонялся (эмулятор запрещён), а RM-G-010 п. 1 требует Windows и Android. Это перенос на
  этап H или решение владельца 13.

**Вывод по воротам G-G (раунд 2): пока не проходятся.** Блокирующего по коду почти не осталось; не выполнено следующее:

1. RM-G-010 не завершена: нет `docs/stages/G_cashier_report.md` и `docs/known_issues.md`, не обновлён список внешних
   зависимостей. Это следующий шаг после ревью.
2. RM-G-010 п. 1: из сценариев кассира 01 GEN-005 в UI против стенда не прогоняется FLOW-026; Android не прогонялся;
   нужно ли включать FLOW-016/033/037, решает владелец 13.
3. Решения владельцев ТЗ из списка выше нужно принять до ворот или явно перенести в `known_issues.md` / 14.

Выполнено: RM-G-001…009, 011, 012, 014 по коду и тестам (кроме пунктов, ждущих решения ТЗ). Покрытие backend G —
95.09 % строк, каждый каталог ≥ 80 %, критичные файлы — 100 % ветвей; Flutter-итог по фичам G — 87.4 %. Тесты
«выключено» (`CUSTOMER_SELF_SERVICE=false`, `returns_enabled=false`, `RETURNS_FROM_POS_ENABLED=false`,
`DEBT_PAYMENTS_FROM_POS`, `QR_PROVIDER=onec/none`) зелёные. В трассировке нет ID «без теста и причины».

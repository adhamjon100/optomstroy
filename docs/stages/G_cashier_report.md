# Отчёт по этапу G — Cashier (клиенты, избранное, долги, скидки, история, транзакции, заявки на возврат) «Оптомстрой POS»

**Этап:** G — Cashier · **Задача фиксации этапа:** RM-G-010 · **Ворота:** G-G
**Дата отчёта:** 2026-10-24 · **Автор (владелец отчёта):** QA + ARCH (13 §2.2) · **Независимый проверяющий:** отдельный
агент, не автор кода — `docs/reviews/G_review.md` (раунд 1 — 10:00–11:40, раунд 2 — 12:24–13:51). Этот отчёт, свежий
прогон для него (§2.1) и `docs/known_issues.md` подготовил автор итоговых документов. Независимой проверки этой редакции
отчёта не было.
**Основание:** 13_IMPLEMENTATION_ROADMAP v2.4 §3.7 (RM-G-001…RM-G-014, «Уточнения путей и критериев задач этапа G»,
ворота G-G), §6.1–§6.3; 12 §2.15 (строка «G — Cashier»); ядро R0 v1.9 (приоритет §24 > §23 > … > §16; D-15,
D-23…D-25, D-36; §17.2–§17.4, §18.2 п. 11, §19.1–§19.4, §21 п. 1, п. 3, §22.4, §22.5, §22.11–§22.13, §23 п. 5, 7, 8;
§24.2).

> **На фикстурах, не реальная интеграция** (SRC-D-176). API специалиста 1С не получен, тестовой копии 1С нет
> (ядро §24.3, RM-A-006, RM-E-016). Все прогоны этапа G шли на `FakeOnecGateway` / `ScriptedOnecGateway` (синтетика
> кассира `SyntheticCashier`), управляемом фейке HTTP-сервиса расширения (`pos-api/scripts/pos_fake_onec.ts --cashier`)
> и фикстурах `contracts/onec/fixtures`. Данных заказчика нет. Коммитов этапов B–G нет (рабочее дерево поверх
> `343db65`); CI не запускался; Docker не установлен. Android/iOS не проверялись. Печать на физический принтер не
> проверялась.

**Ссылки на доказательства.** «Журнал NNN» — номер строки `docs/stages/G_test_run.log`. Основные разделы журнала:
- §0 «Что сделано интеграцией» — строки 11–35; §1 «Итог» — 37–52;
- интеграция backend (миграции, `cashier-smoke`, `test:all`, RBAC-матрица, `test:cov:g/f/d/e`, гейты) — 54–681;
- «Интеграция Flutter этапа G» (`flutter test`, golden, гейты, `trace_test_ids`, `integration_test`, сборка) — 684–809;
- «Исправления ревью этапа G (backend), повторные прогоны» — 811–828;
- «Перепроверка после ревью, раунд 1» (независимый проверяющий) — 830–908;
- «Исправитель Flutter, раунд 2» — 910–928;
- **«Перепроверка после ревью, раунд 2»** (независимый проверяющий, **последний полный прогон**) — 930–1009;
- **«Свежий прогон для отчёта этапа G»** (автор отчёта, короткий: 3 ключевые команды и 2 гейта) — строки 1011–1045 (§2.1).

## Итог

- **Ворота G-G не проходятся** (§4.1). Код этапа почти не держит ворота; держат три вещи:
  1. **RM-G-010 п. 1 выполнен не полностью.** Из сценариев кассира 01 GEN-005 (FLOW-020…031, FLOW-036) на Windows против
     стенда `serve --cashier-fixtures` не прогоняется FLOW-026 «Отмена заказа» (G-trace-8, R2-N-01). Запись 13 v2.4
     §3.7, что FLOW-026 прогоняет `pos_flow_test.dart`, проверкой не подтвердилась. Android не прогонялся: эмулятор в
     окружении запрещён, устройства нет. Перенос Android на этап H записан в 13 v2.4 §3.7 при синхронизации ТЗ
     (FIX-G-FE-FLOWS-2); отдельного подтверждения владельца 13 или заказчика нет;
  2. **предыдущие ворота не закрыты**: G-F красные (нет письменного решения заказчика по RM-F-010), G-D и G-C — красные
     по своим отчётам (Android/биометрия, CI, Docker; `docs/known_issues.md` §2);
  3. **ждут решения владельцев ТЗ** 4 not_fixed и остатки 3 partially_fixed замечаний ревью (TXN-007, RL-RECV-REFRESH,
     подписи SCR-46, итог просрочек, состав T-UI), а также толкования FIX-G-TXN-SIGN, FIX-G-SNAP-FUTURE,
     FIX-G-DISC-404, FIX-G-TXN-AUDIT. Новые вопросы заказчику Q-331, Q-332 без ответа.
- **Последний полный прогон** — независимый проверяющий, раунд 2 (журнал 930–1009; 12:24–13:51; на C: 3,5 ГБ). Все
  команды — код 0 с первого раза, нестабильностей нет:
  - pos-api: `lint`, `build`, `madge`, `check:permissions`; миграции 0001…0018 повторно — 0 изменений; `test:all`
    (34 набора) — **1687 passed**, 8 skipped, 0 failed; `test:cov:g` — 723 passed, строки **95,09 %**, ветви 82,8 %,
    каждый каталог G ≥ 80 % строк, критичные файлы — 100 % ветвей и строк; `test:cov:f/e/d` — пороги выполнены;
    `test:e2e:pos`, `test:e2e:cashier` — 1/1; local-stack `smoke` / `auth-smoke` / `catalog-smoke` / `pos-smoke` /
    `cashier-smoke` — 10/10, 15/15, 22/22, 30/30, **22/22**;
  - pos-app: `flutter analyze` — без замечаний; `flutter test --concurrency=2 --coverage` — **2256 passed**; golden — 362;
    покрытие domain/data фич G — **87,4 %**; `integration_test` на Windows: `cashier_flow_test` **5 из 5**,
    `pos_flow_test` 4, `catalog_flow_test` 2, `auth_flow_test` 3, `admin_invite_flow_test` 1, `boot_test` 1;
    `flutter build windows --release` — собрано;
  - корень: `check_no_double_money`, `check_secrets` (0 находок), `check_repo_layout`, `build_openapi --check`,
    `check_api_paths`, `check_enums`, `check_arb_keys`, `check_layers`, `sync_contracts --check` — код 0;
    `trace_test_ids --stage G` — 125 / **104** / **21** / 0.
- **Свежий прогон для отчёта** (§2.1; автор отчёта, после синхронизации ТЗ): журнал 1011–1045 (14:40–15:01). Все
  команды — код 0: `test:cov:g` — 723 passed, строки 95,09 %, ветви 82,8 %, критичные файлы — 100 % ветвей и строк;
  `trace_test_ids --stage G` — 125 / 104 / 21 / 0; `check_secrets` — 0 находок (2687 файлов); `flutter test
  --concurrency=2` — **+2256**; `cashier_flow_test` на Windows — **5 из 5**. Результаты совпадают с раундом 2: код
  после него не менялся.
- **Ревью** (`G_review.md`): 58 подтверждённых замечаний (дубли считаются отдельно; 5 исходно critical). После двух
  раундов исправлений — **fixed 47, partially_fixed 5, not_fixed 4, not_a_defect 2**. Все critical исправлены и закрыты
  тестами (G-credit-1, G-customers-1c-1, G-customers-1c-2, G-returns-txn-1; G-trace-1 — частично: вкладки и «Повторить»
  на SCR-43 есть, нет фильтра по агрегату, подписей статусов и шага integration_test). Все 4 not_fixed ждут решения ТЗ.
  Единственный остаток, который не требует решения ТЗ, — FLOW-026 в integration_test (§3.1, G-KI-01).
- **Синхронизация ТЗ** (`G_spec_sync.md`): разобрано 169 пунктов `G_spec_questions.md`; изменены 02, 03, 05, 06, 07,
  08, 10 (пометки), 11, 12, 13, 14, 15, `visual/navigation.md`, README, 00; ADR-104…ADR-107; новые вопросы **Q-331,
  Q-332**; в OpenAPI 1.2.0 уточнены только 5 текстов описаний. Ядро, `resursi/`, `enums.json`, `permissions.yaml`,
  `contracts/l10n`, `contracts/onec` не менялись (§5.2).
- **Переносы из F закрыты на Windows**: поиск клиента в SCR-21 (`CustomerPicker`, реальный `GET /customers`) и
  создание клиента SCR-26 из оформления проходят против стенда (`cashier_flow_test`); `Payment.transactionId` сервер
  отдаёт в `GET /payments/{id}` и `/orders/{id}/payments`, в `Order.payments[]` — нет (бэклог GQ-TXR-15, §1.3).
- **Не сделано** по окружению и объёму (§2.4, §4.3): реальная 1С; Android и iOS; печать на принтер; Docker/compose и
  CI; RM-G-013 — по Q-152 = «нет» реализованы только guard и тесты «выключено»; FLOW-026 в integration_test;
  RM-G-012 п. 5 подтверждён unit/widget-тестами, а не integration_test (§1.2, наблюдение автора отчёта G-KI-02).

---

## 1. Готовые файлы

Коммитов этапов B–G нет, поэтому все пути ниже — неотслеживаемые или изменённые (`git status`). Владельцы — по
CONTRIBUTING.md §5 (13 §5.2). Перечень — по модулям, а не по файлам.

### 1.1. Пути

| Путь | Новый / изменён | Задачи `RM-*` | Владелец | Версия контракта (было → стало) | Примечание |
|---|---|---|---|---|---|
| `pos-api/src/customers/{search,directory,history,common,reader,jobs,links,matching,favorites}/**` | новый / изм. | RM-G-001, 004, 011, 014 | BE + ONEC | — | поиск и история перенесены из `cart`/`orders` (мёртвый код F удалён, GQ-INT-07; журнал 19–20) |
| `pos-api/src/customers/receivables/**`, `src/sales-domain/credit/**`, `src/sales-domain/adapters/snapshot-credit-decision.service.ts`, `src/sync/receivables/**` | новый | RM-G-002, 011 | BE + ONEC | — | путь `src/payments/credit/**` из 13 реализован этими путями (13 v2.4 §3.7 «Уточнения») |
| `pos-api/src/customers/discounts/**`, `src/admin/discount-limits/**`, `src/sync/discounts/**` | новый | RM-G-003 | BE + POS | — | |
| `pos-api/src/transactions/**`, `src/common/journal/**`, `src/payments/dashboard/**` | новый | RM-G-004 | BE | — | `TransactionJournal` — писатель по умолчанию порта `TRANSACTIONS_WRITER` |
| `pos-api/src/returns/**` (в т. ч. `onec/`, `returns-retention.service.ts`) | новый | RM-G-005, 011 | BE + ONEC | — | очистка черновиков старше 7 дней (G-trace-10) |
| `pos-api/src/admin/{audit,reports,settings}/**`, `pos-api/scripts/verify_audit_chain.ts` | новый / изм. | RM-G-006 | BE + SEC | — | `AuditJobsBridge`: `audit.anchor` / `audit.verify` (G-security-1) |
| `pos-api/src/payments/**` (guard `POST /payments`, `Payment.transactionId`) | изм. | RM-G-011, 013 | BE | — | RM-G-013 — только guard (Q-152 = «нет») |
| `pos-api/src/orders/**` (зависимость заказа от `customer/create`, перепроверка лимита в транзакции) | изм. | RM-G-002, 014 | BE + ONEC | — | G-credit-3, G-customers-1c-1 |
| `pos-api/src/common/ports/**`, `src/app.module.ts`, `src/worker.ts` | изм. | RM-G-001…006 | BE | — | все порты G привязаны реальными реализациями (журнал 13–18) |
| `pos-api/migrations/0017_returns_transactions.sql`, `0018_audit_system_events.sql`; `docs/erd/schema_v1.sql` (перегенерирован) | новый / изм. | RM-G-005, 006 | BE | — | 0014–0016 не создавались (13 v2.4 §3.7) |
| `pos-api/test/{customers,receivables,discounts,transactions,returns,reports,customer-mode,cashier-foundation,admin}/**`, `test/e2e/cashier/**`, `test/e2e/rbac-matrix.e2e-spec.ts`, `vitest.config.cov-g.ts`, `package.json` | новый / изм. | RM-G-009 | QA | — | `test:cov:g`, `test:e2e:cashier`, `stack:cashier-smoke` |
| `pos-api/scripts/{pos_fake_onec.ts,local-stack.mjs}` (`--cashier`, `cashier-smoke`, `serve --cashier-fixtures`) | изм. | RM-G-009, 010 | ONEC + QA | — | фейк 1С — **тестовые данные** |
| `pos-app/lib/features/{cashier,customers,transactions,returns,favorites}/**` | новый / изм. | RM-G-007, 012 | FE + DS | — | SCR-30…SCR-40 |
| `pos-app/lib/features/{admin,reports,profile,settings,sync_status,notifications}/**` | новый / изм. | RM-G-008, 012, 014 | FE + DS | — | SCR-41…SCR-48 |
| `pos-app/lib/features/{orders,customers,profile,notifications}/**` (режим клиента) | изм. | RM-G-014 | FE | — | фичи `customer_orders` нет (13 v2.4 §3.7) |
| `pos-app/lib/app/di/{stage_g_overrides,customer_orders_tab,printer_settings_port}.dart`, `app/router/**` (в т. ч. `shells/app_shell.dart`) | новый / изм. | RM-G-007, 008, 010 | FE | — | HID-скан SCR-30 (G-flutter-ui-3), guard G-8 |
| `pos-app/test/**` (фичи G, `test/app/router/rbac_matrix_test.dart`, golden SCR-30…48), `pos-app/integration_test/cashier_flow_test.dart` | новый | RM-G-009, 010 | QA | — | |
| `scripts/trace_test_ids.py` (`--stage G`) | изм. | RM-G-009 | QA | — | причины not_done частично устарели (R2-N-02) |
| 02, 03, 05, 06, 07, 08, 10 (пометки), 11, 12, 13, 14, 15, `visual/navigation.md`, README, 00 | изм. (синхронизация ТЗ) | — | владельцы документов | см. `G_spec_sync.md` §1 | ядро и бизнес-правила не менялись |
| `contracts/openapi/parts/{00_root,40_payments_pos_returns,50_customers}.yaml`, `pos-api.v1.yaml`, `CHANGELOG.md` | изм. (тексты описаний) | — | владелец 08 | 1.2.0 → 1.2.0 (версия не повышалась: 1.2.0 не выпущена) | 5 описаний; схема, пути, права не менялись |
| `docs/stages/G_test_run.log`, `G_spec_questions.md`, `G_spec_sync.md`, `docs/reviews/G_review.md`, этот отчёт, `docs/known_issues.md` | новый | RM-G-009, 010 | QA + ARCH | — | |

### 1.2. Статус задач этапа

- «Закрыта (локально)» — все пункты критерия 13 §3.7 выполнены запуском на машине разработчика, на фейке 1С.
- «Частично» — часть пунктов не выполнена; причина указана.
- Подтверждение: backend — `test:all` раунда 2 (журнал 949–950), `test:cov:g` (журнал 951–954), `cashier-smoke`
  22/22 (журнал 137–174; повтор — 960–961); Flutter — `flutter test` раунда 2 (журнал 967), `cashier_flow_test`
  (журнал 976–979). Каждый тест с текстом 12 и 13 построчно не сверялся; опора — журнал, ревью и трассировка.

| Задача | Статус | Что подтверждено запуском (пункты критерия) | Подтверждение | Что не выполнено (причина) |
|---|---|---|---|---|
| RM-G-001 Backend клиенты | закрыта (локально), на фейке 1С | п. 1: `seller` не получает поле долга — схема ответа по роли (`customers-directory` e2e; `cashier-smoke`: `receivables` под `seller` → 403); п. 2: телефон существующего клиента → `CUSTOMER_DUPLICATE_SUSPECTED`; п. 3: новый клиент → outbox → фейк 1С → `onec_ref`, `confirmed`; п. 4: история из реализаций (`shipments`), `historyFrom` | журнал 154–155, 160 (`cashier-smoke`); 497 (`cashier-flow` e2e); 949 | Дубль по правилам 1С (`POS_E_DUPLICATE`) обрабатывается по 05 SYNC-049 без перепривязки заказов — Q-332. Остаток R1-N-03: заказ клиента в `failed`/`dead` остаётся `pending` без причины |
| RM-G-002 Backend долги | закрыта (локально), на фейке 1С | п. 1: матрица fail-closed {снимок} × {лимит} × {просрочка} × {1С} по PAY-031, `ONEC_UNAVAILABLE` не возвращается; `CUSTOMER_NOT_IDENTIFIED`, `credit_not_allowed` без обращения к 1С (`receivables-credit.e2e`, `test:receivables` 142); п. 2: разблокировка без step-up → `STEP_UP_REQUIRED`; п. 3: разблокировка → `audit_logs` и `transactions (credit_sale_approved)` | журнал 157–158; 455–457; 494; 951–954 | Разблокировка — только `senior_seller` в своей сессии (13 v2.4 §3.7 по 10 PAY-032, D-15). Допуск часов 1С 5 мин (FIX-G-SNAP-FUTURE) ждёт владельца |
| RM-G-003 Backend скидки | закрыта (локально) | п. 1: лимиты seed `5/5/10/15` (Q-015); п. 2: override → `transactions (discount_override)` + аудит (сумма 0.00, FIX-G-TXN-SIGN); п. 3: изменение лимита — step-up и аудит (`test:discounts`, `test:admin`) | журнал 156; 458–459; 391–393 | Скидка клиента и параметры правил 1С в контракте 1С не передаются (Q-015, 14 §3.13): `discount_percent = NULL`, итог — 1С |
| RM-G-004 Избранные клиенты, транзакции, дашборд | закрыта (локально) | п. 1: каждое финансовое событие F/G — ровно одна транзакция (инвариант-тест); п. 2: `seller` — только свои, `cashier+` — все; п. 3: дашборд сходится с транзакциями; п. 4: «Ожидают оплаты» содержит `submitting` с открытым платежом | журнал 163–164, 169; 461–463 | TXN-007 (реализации и ПКО 1С вне приложения) выполнен только для возвратов 1С — не в критерии RM-G-004, но must в 10 (G-returns-txn-4, not_fixed) |
| RM-G-005 Заявки на возврат | закрыта (локально) | пп. 1–2: без причины / количество > проданного → `VALIDATION_FAILED`; п. 3: submit без step-up → `STEP_UP_REQUIRED`, сверх порога у `cashier` — отказ, у `senior_seller` со step-up — `submitted`; п. 4: при `RETURNS_FROM_POS_ENABLED=false` outbox нет; при `true` — outbox `return_request`; п. 5: недопустимые переходы и права `accept`/`reject`; п. 6: `returns_enabled=false` по RET-012 | журнал 161–162; 464–466; 495–496 | — |
| RM-G-006 Аудит и отчёты | закрыта (локально) | п. 1: `verify_audit_chain.ts` → код 0; п. 2: подмена строки → разрыв относительно якоря (`audit-chain.verifier.spec.ts`, `audit-jobs.admin-spec.ts`); п. 3: `qr-reconciliation` по `QR_TTL_MINUTES`; п. 4: экспорта CSV нет | журнал 165–168; 589 | Правила отчётов SCR-48 — допущение, Q-331 |
| RM-G-007 Flutter кассир SCR-30…40 | закрыта (локально, Windows) | п. 1: golden на 3 брейкпоинтах (недостававшие SCR-33, 35, 40 добавлены — G-flutter-ui-7; golden 362); п. 2: `seller` не видит сумму долга; п. 3: fail-closed-блок SCR-38 с текстом CASH-007 (плитки `credit` на SCR-38 нет — 13 v2.4 §3.7); п. 4: `StepUpDialog` при первом открытии SCR-34 и не повторно 15 мин (`FakeAsync`); п. 5: кнопки SCR-39 по ролям и `RETURNS_FROM_POS_ENABLED` | журнал 967, 972; 976–979 | Вкладка «Товары» SCR-40 в полном объёме не назначена ни одной задаче G (бэклог, 13 v2.4 §3.7). Итог просрочек SCR-30 при 10 строках не показывается (G-flutter-ui-5) |
| RM-G-008 Flutter админ/руководитель/профиль/настройки | закрыта (локально, Windows) | п. 1: изменение лимита скидки — step-up; п. 2: `owner`/`admin` без кассовых действий, `rbac_matrix_test` сверяет `permissions.yaml` с видимостью (G-flutter-ui-8); п. 3: «Кыргызча»/«English» — «Скоро», ARB-каркас компилируется; п. 4: SCR-43 у `senior_seller` нет `full`/`reconcile`, `full` у `admin` — step-up | журнал 966–967 | Подписи полей SCR-46 — сырые ключи API (G-flutter-ui-6, not_fixed, нужны ключи ARB). Покрытие profile (data 61,4 %, domain 55,0 %) и settings/domain (50,4 %) ниже 80 % (R1-N-02) |
| RM-G-009 Тесты этапа G | закрыта (локально) | п. 1: T-CUST/T-DEBT/T-DISC/T-TXN/T-RET/T-CASH/T-SEC запущены — `trace_test_ids --stage G` 125 / 104 / 21 / 0 (§2.5); п. 2: покрытие модулей G ≥ 80 % (backend 95,09 %, каждый каталог ≥ 80 %; Flutter 87,4 %); п. 3: критичные файлы — 100 % ветвей; integration «клиент с долгом → блок → разрешение старшего → оплата → транзакция → аудит» — `cashier-flow` e2e и `cashier_flow_test` | журнал 951–954; 968–971; 1000–1004; 494 | 21 not_done с причиной (§2.5), из них T-UI 17 — вне ворот G-G по 12 v1.8 §2.15. Flutter-покрытие ниже 80 % у profile и settings/domain |
| RM-G-010 Сборка, проверка, отчёт | **частично** | Независимая проверка — 2 раунда (`G_review.md`); этот отчёт (4 раздела + приложения); `docs/known_issues.md` классифицирован по серьёзности; сценарии кассира GEN-005 на Windows против стенда — все, кроме FLOW-026 | журнал 976–979; `G_review.md` §13 | **п. 1:** FLOW-026 «Отмена заказа» не прогоняется в integration_test (R2-N-01); **Android не выполнен** (эмулятор запрещён, устройства нет); перенос на H записан в 13 v2.4 §3.7, отдельного решения владельца нет |
| RM-G-011 Backend по ядру v1.4 | закрыта (локально) | п. 1: `receivables/refresh` под `cashier` → новый снимок, под `seller` → 403, 11-й запрос → 429 `RATE_LIMITED`; п. 2: `DELETE /returns/{id}` — только черновик; п. 3: `POST /payments` → 403, `receipt.pdf` → 404; п. 4: `jest-openapi` для полей §19.2 (в т. ч. `Receivable`, `AuditRow` — G-trace-15), `forceReason` без права → 403; п. 5: поиск `seller` по 4 цифрам → 400, `cashier` → 200; 13-й избранный клиент — отказ; 367 дней → `VALIDATION_FAILED` | журнал 153; 949; `receivables-credit.e2e.spec.ts:323` | Счётчики RL-RECV-REFRESH — в памяти процесса, а 08 §2.9 называл Postgres (G-security-4, not_fixed; spec-sync выбрал «память процесса в R1», 08 v1.18 §2.9). Значения лимита в 14 Q-251 (60 с) и в реализации/08 (30 с) различаются |
| RM-G-012 Flutter по ядру v1.4 | **частично** | п. 1: «Обновить» на SCR-34 → `receivables/refresh`; офлайн SCR-32/34 без сумм; финансов клиента нет ни в drift, ни в secure storage (шаг `cashier_flow_test`; «перезапуск» проверен сканированием хранилищ, а не рестартом процесса — G-trace-9); п. 2: fail-closed SCR-38 без `StepUpDialog.supervisor`; п. 3: SCR-46 у `owner` — просмотр; экспорта CSV нет; п. 4: SCR-43 без «Пометить решённой»/«Пауза», `chainOk` на SCR-47, период ≤ 366 дней | журнал 967; 976–979 | **п. 5 («integration: прочтение уведомления офлайн → outbox `notification.read` → один запрос; переход по `payload.target`»)** подтверждён только unit/widget-тестами (`notification_read_outbox_test.dart` на drift в памяти, `notifications_screen_test.dart`); в `integration_test/*.dart` такого шага нет (наблюдение автора отчёта, G-KI-02; ревью не проверяло) |
| RM-G-013 Оплата долга без заказа (условно) | **не выполняется** (Q-152 = «нет») | Только guard: `POST /payments` → 403 (`debt_payments_disabled` / `debt_payments_not_implemented`), `receipt.pdf` → 404, режима «по долгу» на SCR-38 нет; `features.debtPaymentsFromPos=false` | журнал 949 (`rbac-matrix`, `public-settings`); `G_review.md` §3 | По 13 §3.12 выполняется только при «да» по Q-152 |
| RM-G-014 Режим клиента | закрыта (локально) | п. 1: `customer` — только свои заказы; `receivables` при `proposed` → 404, при `confirmed` → 200; п. 2: без подтверждённой привязки нет блоков долга и истории; `manual_confirm` — «Оплата проверяется магазином»; п. 3: заявка клиента видна сотруднику в `GET /orders`; п. 4: «Показ остатков клиенту» — только `admin`, step-up (G-flutter-ui-9); `CUSTOMER_SELF_SERVICE=false` закрывает клиенту долг и условия (G-security-2) | журнал 170–171; 499; 976–979 | Выделение заявок клиентов в списке заказов — после выравнивания 08 и 02 (13 §13 п. 22); `OrderSummary.createdVia` — предложение MINOR (08 §16.15) |

### 1.3. Переносы из этапа F

| Пункт (этап F) | Что сделано на этапе G | Подтверждение | Статус |
|---|---|---|---|
| F-KI-15, RM-F-006 / RM-F-011 «с клиентом»: поиск и создание клиента в SCR-21 / SCR-26 на стенде (`GET/POST /customers`) | Сид клиентов в стенде — синхронизацией фейка 1С (`serve --cashier-fixtures`: 30 клиентов, 27 снимков долга, 43 реализации); `CustomerPicker` SCR-21 ищет реальным `GET /customers`; SCR-26 из оформления создаёт клиента и выбирает его в заказе; дубль → выбор существующего (FLOW-029) | `cashier_flow_test`: «SCR-21 CustomerPicker (поиск) → …», «SCR-26 из оформления — клиент создан и выбран в заказе», «FLOW-029 — дубликат найден» (журнал 976–979) | **закрыт на Windows** (на фейке 1С). Android — не проверялся |
| F-KI-21 (FQ-FEORD-12): `Payment.transactionId` | Сервер отдаёт `transactionId` (последняя строка журнала платежа) в `GET /payments/{id}` и `/orders/{id}/payments` ролям с `transactions.read.*` (`payment-presenter.ts`) | `G_spec_questions.md` GQ-TXR-15; `test:payments` в `test:all` (журнал 949) | **закрыт частично**: в `Order.payments[]` (`GET /orders/{id}`, SCR-24) поле не отдаётся — бэклог `orders` (GQ-TXR-15, `G_spec_sync.md` §3) |
| T-TXN-008 (FIX-F-21, ждёт Q-330) | Не менялось | `trace_test_ids --stage F` | открыт (решение заказчика Q-330) |

Другие открытые пункты отчёта F (F-KI-01, F-KI-03, F-KI-06, F-KI-09, F-KI-11, F-KI-12, F-KI-19, F-KI-20) на этапе G
не перепроверялись; они перенесены в `docs/known_issues.md` со статусом по отчёту F.

## 2. Выполненные проверки

### 2.1. Свежий прогон для отчёта этапа G

Прогон выполнил автор отчёта после синхронизации ТЗ; код не менялся. Команды — последовательно одним скриптом
(`D:/optomstroy/.tmp/report_g/run.sh`), `TEMP=TMP=D:/optomstroy/.tmp`, `APP_DATA_DIR=D:/optomstroy/.tmp/appdata`. На C:
перед прогоном 3 598 МБ, в конце — 2 576 МБ (≥ 300 МБ — `integration_test` запускался). **На фикстурах, не реальная
интеграция.** Сырые логи — `D:/optomstroy/.tmp/report_g/*.log`; сводка — журнал 1011–1045.

| № | Задача / критерий | Команда | Результат | Лог |
|---|---|---|---|---|
| 1 | RM-G-009 пп. 2–3; RM-G-001…006, 011 | `cd pos-api && npm run test:cov:g` | код 0; 63 файла passed, 3 skipped; **723 passed**, 7 skipped; строки 95,09 %, ветви 82,8 %, функции 96,05 %; критичные 4 файла — 100 % ветвей и строк; `src/returns/onec` 87,6 % строк | журнал 1011–1045; `.tmp/report_g/cov_g.log` |
| 2 | RM-G-009 п. 1 | `python -I -X utf8 scripts/trace_test_ids.py --stage G --summary` | код 0; 125 / 104 (частично 12) / 21 / 0 | там же; `trace_g.log` |
| 3 | гейт секретов | `python -I -X utf8 scripts/check_secrets.py` | код 0; 2687 файлов, 0 находок | там же; `secrets.log` |
| 4 | RM-G-007, 008, 012, 014 (unit, widget, golden) | `cd pos-app && flutter test --concurrency=2` | код 0; **+2256: All tests passed** | там же; `fe_test.log` |
| 5 | RM-G-009 (integration), RM-G-010 п. 1 (Windows) | `flutter test integration_test/cashier_flow_test.dart -d windows --dart-define-from-file=env/dev_proxy.json --dart-define-from-file=env/local.json` | код 0; **5 из 5** (04:35); шаги — журнал 1011–1045 | там же; `it_cashier.log` |

Не повторялись (последний зелёный результат — раунд 2, §2.2): `test:all`, `test:cov:f/e/d`, `test:e2e:*`, local-stack
smoke, миграции, `flutter test --coverage` и golden отдельно, прочие `integration_test`, сборка Windows, прочие гейты.

### 2.2. Последняя независимая перепроверка — раунд 2 (2026-10-24 12:24–13:51)

Код при перепроверке не менялся; с раунда 1 изменён только pos-app (исправитель Flutter, раунд 2). После перепроверки
менялись только документы ТЗ и 5 текстов описаний OpenAPI (синхронизация ТЗ, `G_spec_sync.md`), код — нет.

| № | Задача / критерий | Команда | Результат | Лог |
|---|---|---|---|---|
| 1 | статическая проверка | pos-api `lint`, `build`, `madge`, `check:permissions` | код 0; 601 файл, 0 циклов; 77 кодов, 7 ролей | журнал 942–945 |
| 2 | миграции | `run-sql --repeat-strict` (prod; dev/test + `check_ddl_behavior`) | код 0; 0 изменений; 63/63 и 64/64 таблиц, 45/45 enum; 62 негативных сценария, 6 инвариантов | журнал 946–948 |
| 3 | RM-G-001…006, 011, 013, 014; регрессия C–F | `npm run test:all` (34 набора) | код 0 с первого раза; **1687 passed, 8 skipped, 0 failed** | журнал 949–950 |
| 4 | RM-G-009 пп. 2–3 | `npm run test:cov:g` | код 0; 723 passed; строки 95,09 %, ветви 82,8 %; критичные — 100 % | журнал 951–954 |
| 5 | регрессия F, E, D | `test:cov:f`, `test:cov:e`, `test:cov:d` | код 0; 799 / 547 / 449 passed | журнал 955–958 |
| 6 | процессные пути | `test:e2e:pos`, `test:e2e:cashier`; local-stack `smoke` / `auth-smoke` / `catalog-smoke` / `pos-smoke` / `cashier-smoke` | код 0; 1/1, 1/1; 10/10, 15/15, 22/22, 30/30, 22/22 | журнал 959–961 |
| 7 | RM-G-007, 008, 012, 014 | `flutter analyze`; `flutter test --concurrency=2 --coverage`; `--tags golden` | код 0; No issues; **+2256**; +362; покрытие фич G 87,4 % | журнал 966–972 |
| 8 | RM-G-009, RM-G-010 п. 1 (Windows) | `integration_test`: `cashier_flow_test`, `pos_flow_test`, `catalog_flow_test`, `auth_flow_test`, `admin_invite_flow_test`, `boot_test` | код 0; 5, 4, 2, 3, 1, 1 | журнал 975–985 |
| 9 | сборка | `flutter build windows --release` | код 0 | журнал 986 |
| 10 | гейты корня | `check_no_double_money`, `check_secrets`, `check_repo_layout`, `build_openapi --check`, `check_api_paths`, `check_enums`, `check_arb_keys`, `check_layers`, `sync_contracts --check` | код 0; `check_secrets` — 2672 файла, 0 находок | журнал 973–974, 993–999 |
| 11 | RM-G-009 п. 1 | `trace_test_ids.py --stage G --summary` | код 0; 125 / 104 (частично 12) / 21 / 0 | журнал 1000–1006 |

### 2.3. Более ранние прогоны (исторические)

| № | Что | Результат | Лог |
|---|---|---|---|
| 1 | Интеграция backend (02:31–03:49) | `test:all` код 0; `test:cov:g` 94,22 % (первый прогон 02:43 — код 1: `customers/jobs` 55 %, verifier 73,77 % ветвей — исправлено); `test:cov:e` первый прогон — код 1 (обработчики G в `src/sync`, исключены из E); `check_secrets` — 2 находки (литерал в тестах, исправлено к 06:03) | журнал 54–681 |
| 2 | Интеграция Flutter (03:55–06:05) | `flutter test` +2144, golden +344; `cashier_flow_test` +5 (такой же прогон 05:14 — +5); регрессия integration — зелёная (первая попытка `pos_flow_test` зависла на системном диалоге печати — печать SCR-22 подменена в тесте) | журнал 684–809 |
| 3 | Исправления ревью backend | `test:cov:g` 95,09 %; `test:cov:f` 94,13 %, `discount-policy.ts` — в критичных; trace 125 / 104 / 21 / 0 | журнал 811–828 |
| 4 | Раунд 1 проверяющего (10:00–11:40) | всё код 0; `test:cov:e` 1-й прогон — 1 failed (`otp.e2e-spec.ts`, этап D, R1-N-01), повторы зелёные; `auth_flow_test`/`admin_invite_flow_test` 1-й запуск — ошибка запуска проверяющего (стек без `LOCAL_STACK_MIN_APP_VERSION`), повтор зелёный | журнал 830–908 |
| 5 | Исправитель Flutter, раунд 2 | `cashier_flow_test` +5 с FLOW-025, FLOW-029, FLOW-022 на SCR-38, FLOW-031.A4; 1-й прогон упал на FLOW-025 (дефект pos-app: 503 refresh — общая ошибка; исправлен) | журнал 910–928 |

### 2.4. Не выполненные проверки

Такие проверки не считаются пройденными.

| Задача / критерий | Команда / проверка | Причина | Когда и кем будет выполнена |
|---|---|---|---|
| RM-G-010 п. 1 — FLOW-026 «Отмена заказа» | шаг `integration_test` (SCR-24 «Отменить заказ» → `ConfirmDialog` с причиной → `POST /orders/{id}/cancel`; ветка S4 со step-up) | шага нет ни в одном `integration_test`; отмену покрывают widget-тест `order_details_screen_test.dart` и e2e backend этапа F | FE + QA, до G-G (G-KI-01) |
| RM-G-010 п. 1, RM-F-011 — Android; iOS | `cashier_flow_test` и остальные `integration_test` на Android; сборка iOS | эмулятор в окружении запускать запрещено, устройства нет (RM-A-008, O-13); macOS нет (Q-008) | QA с устройством, этап H (по 13 v2.4 §3.7 — после подтверждения владельцем) |
| RM-G-012 п. 5 | integration «уведомление офлайн → outbox `notification.read` → один запрос; переход по `payload.target`» | шаг не написан; есть unit/widget-тесты | FE + QA (G-KI-02) |
| Реальная 1С: клиенты, долги, скидки, история, документы возврата | обмен с тестовой копией УТ 11.5 | копии 1С и API расширения нет (RM-A-006, RM-E-016, O-04, O-05) | ONEC + специалист 1С; до I |
| Печать SCR-37/38 на принтер; USB ESC/POS | печать на термопринтер 80 мм и A4 | принтеров нет (RM-A-009); USB ESC/POS не поддержан | QA при получении принтеров |
| T-CASH-009 | fakeAsync-тест опроса дашборда 60 с | не написан (G-trace-14) | FE |
| Docker / CI | образы, `compose.test.yml`, job CI | Docker не установлен; коммитов и push нет | OPS |
| Отдельная повторная проверка этого отчёта и `known_issues.md` | — | не проводилась | QA по 13 §6.1 п. 11, при решении по G-G |

### 2.5. Матрица T-ID этапа G (RM-G-009 п. 1)

`python -I -X utf8 scripts/trace_test_ids.py --stage G --summary` (свежий прогон §2.1; совпадает с раундом 2,
журнал 1000–1006):

| Группа | Охват / с тестом / not_done / без теста и причины |
|---|---|
| DEBT | 14 / 14 / 0 / 0 |
| DISC | 12 / 12 / 0 / 0 |
| CASH | 16 / 15 / 1 / 0 |
| CUST | 17 / 17 / 0 / 0 |
| TXN | 11 / 8 / 3 / 0 |
| RET | 15 / 15 / 0 / 0 |
| ADMIN | 10 / 10 / 0 / 0 |
| SEC | 12 / 12 / 0 / 0 |
| UI | 18 / 1 / 17 / 0 |
| **Итог** | **125 / 104 (частично 12) / 21 / 0** |

not_done (21) — по выводу скрипта:
- T-CASH-009 (P2) — fakeAsync-тест опроса `GET /pos/dashboard` каждые 60 с не написан (G-trace-14);
- T-TXN-006, T-TXN-009 (P3) — причина «у Flutter-интегратора этапа G» (устарела, R2-N-02; UI-тесты есть, ID не названы);
- T-TXN-008 (P3) — ждёт решения заказчика Q-330 (FIX-F-21);
- T-UI-030…039, T-UI-041…043, T-UI-045…048 (17 наборов) — AC-UI экрана названы в тестах частично (например, SCR-31 9/12,
  SCR-33 2/9, SCR-46 2/12, SCR-47 1/14, SCR-48 1/18); по 12 v1.8 §2.15 — вне ворот G-G, полные наборы — этап H.

Оговорки: причины not_done у T-UI-030, T-UI-042, T-UI-043, T-DEBT-013, T-CUST-013, T-TXN-006, T-TXN-009, T-CASH-007,
T-CASH-010 частично устарели — функции, на которые они ссылаются, сделаны (R2-N-02). T-UI-030 полон по AC (22/22), но
выводится not_done, потому что ни один тест не называет сам ID. Наборы T-UI-030…048 по 12 v1.8 §2.15 в ворота G-G не
входят (полные наборы — этап H). T-AUD-* в 12 нет: аудит — T-SEC-030/038/067, T-ADMIN.

### 2.6. Покрытие (RM-G-009 пп. 2–3)

- **Backend** (`test:cov:g`, раунд 2 и свежий прогон): всего строки 95,09 %, ветви 82,8 %; каждый каталог G ≥ 80 %
  строк (минимум — `src/returns/onec` 87,62 %); критичные по 13 v2.4 §3.7 — `credit-decision.ts`,
  `snapshot-credit-decision.service.ts`, `discount-policy.service.ts`, `audit-chain.verifier.ts` — 100 % ветвей и
  строк (порог `vitest.config.cov-g.ts`). «Скидка сверх лимита» в заказе — `src/sales-domain/pricing/discount-policy.ts`
  в критичных `cov-f` (G-credit-6).
- **Flutter** (lcov раунда 2, `D:/optomstroy/.tmp/verify_g2/lcov.info`): domain/data фич G — 87,4 % (1668/1909);
  cashier, transactions, returns — 100 %; customers 96,6 / 89,7; admin 91,5 / 82,8; reports 91,9 / 100;
  **ниже 80 %**: profile (data 61,4 %, domain 55,0 %), settings/domain 50,4 % (R1-N-02). В свежем прогоне §2.1 покрытие
  Flutter не перемерялось.

## 3. Известные проблемы

### 3.1. Дефекты и пробелы этапа G

Серьёзность — по 13 §6.2 (для замечаний ревью — исходная оценка, в скобках — оценка скептиков, если ниже). Полный
список с этапами C–F и внешними зависимостями — `docs/known_issues.md`.

| ID | Описание | Серьёзность | Статус / обход | План (задача, срок) |
|---|---|---|---|---|
| G-KI-01 (G-trace-8, R2-N-01) | FLOW-026 «Отмена заказа» (01 GEN-005) не прогоняется ни одним `integration_test`; запись 13 v2.4 §3.7 / FIX-G-FE-FLOWS-2 «FLOW-026 — `pos_flow_test.dart`» неверна | существенная (major / minor) | открыт; поведение покрыто widget-тестом и e2e backend F | FE + QA: шаг FLOW-026 (и ветка S4 со step-up) в `cashier_flow_test`; исправить запись в 13 §3.7 — владелец 13; до G-G |
| G-KI-02 (наблюдение автора отчёта) | RM-G-012 п. 5 требует integration-проверки «уведомление офлайн → outbox → один запрос; переход по `payload.target`»; есть только unit/widget | незначительная (ревью не проверяло) | открыт | FE + QA: шаг в `integration_test` или решение владельца 13; до G-G |
| G-KI-03 (Android) | `integration_test` этапа G на Android не запускался | блокер RM-G-010 п. 1 до решения | открыт (окружение: эмулятор запрещён, устройства нет) | 13 v2.4 §3.7 переносит на H (O-13); нужно подтверждение владельца 13 / заказчика и Android-устройство |
| G-KI-04 (G-returns-txn-4 = G-trace-11) | 10 TXN-007 (must): реализации и ПКО, введённые в 1С вне приложения, не попадают в журнал `transactions`; выполнено только для возвратов 1С | существенная (major) | not_fixed — решение ТЗ: в enum ядра `transaction_kind` нет вида, в контракте 1С нет ленты ПКО (07 §19 п. 30) | владелец enum (ядро) + 07 + специалист 1С (18) + BE (FIX-G-TXN-07, Q-012) |
| G-KI-05 (G-security-4) | RL-RECV-REFRESH хранится в памяти процесса API | незначительная для R1 (major / minor) | not_fixed; в 08 v1.18 §2.9 записан вариант «память процесса в R1» (R1 — один экземпляр API) | BE + 07 при горизонтальном масштабировании (R2, FIX-G-RL-RECV) |
| G-KI-06 (G-flutter-ui-6) | Подписи полей SCR-46 — сырые ключи API, варианты — коды | существенная (major / none) | not_fixed; ключи ARB предложены в 03 §16.9, не внесены | владелец 02 §7 (тексты) → `build_arb.py` → FE (FIX-G-FE-SETTINGS-LABELS) |
| G-KI-07 (G-flutter-ui-5) | Итог просрочек SCR-30 при 10 строках не показывается (вместо него — «Все просрочки») | незначительная (major / minor) | partially_fixed | владелец 08: `PosDashboard.overdueTotal` (предложение MINOR 08 §16.15) |
| G-KI-08 (G-trace-1) | SCR-43: нет фильтра по агрегату (UI-43-014), локализованных статусов outbox и кодов ошибок, шага integration_test | незначительная (остаток critical-замечания) | partially_fixed: вкладки «Ошибки»/«Outbox» и «Повторить» есть и проверены | FE после ключей ARB (FIX-G-FE-OUTBOX-LABELS) |
| G-KI-09 (G-trace-7) | Приёмочные наборы T-UI-030…048: скрипт показывает UI 18 / 1 / 17; AC-UI частично (SCR-31 9/12, 32 12/16, 34 14/17, 36 14/16, 38 24/29); в 02 есть противоречивые и неисполнимые AC | незначительная для G-G (по 12 v1.8 §2.15 вне ворот) | partially_fixed | этап H (RM-H), владелец 02 (FIX-G-FE-TRACE-2) |
| G-KI-10 (G-trace-14, R2-N-02) | `trace_test_ids.py`: устаревшие причины not_done; T-CASH-009 (опрос 60 с) без теста | незначительная | partially_fixed | владелец скрипта; FE |
| G-KI-11 (R1-N-02) | Покрытие Flutter domain/data ниже 80 %: profile, settings/domain | незначительная | открыт; итог по фичам G 87,4 % | FE (RM-G-008, RM-D-009) |
| G-KI-12 (R1-N-03) | Заказ на POS-клиента с `customer/create` в `failed`/`dead` остаётся `pending` без причины в `last_error` (05 SYNC-042) | незначительная | открыт | BE |
| G-KI-13 (G-customers-1c-2, побочный эффект) | Пока POS-клиент с тем же телефоном «в полёте», другие кандидаты 1С с этим телефоном не возвращаются | незначительная | открыт | BE, вместе с Q-332 |
| G-KI-14 (G-returns-txn-5, остаток) | Триггер возвратов не сериализует прямые SQL-вставки в обход сервиса (сервис — `FOR UPDATE`) | незначительная | открыт | BE / владелец 07 |
| G-KI-15 (R2-N-03) | Токен step-up `return.submit` повторно используется для второй заявки в течение 15 мин без диалога | инфо (не проверялось) | — | владелец 09/11: допустимо ли |
| G-KI-16 (R1-N-01, F-KI-16) | Нестабильный `test/e2e/auth/otp.e2e-spec.ts:61` (этап D): 500 вместо 202, один раз в раунде 1 G (и в F) | незначительная | в раунде 2 и свежем прогоне не воспроизвёлся; причина не установлена | владелец auth |
| G-KI-17 | Толкования исправителей, ждущие владельцев ТЗ: FIX-G-TXN-SIGN (`credit_sale_approved` = 0.00), FIX-G-SNAP-FUTURE (допуск часов 1С 5 мин), FIX-G-DISC-404, FIX-G-TXN-AUDIT | незначительная | внесены в ТЗ как уточнения (класс A, `G_spec_sync.md` §4) | владельцы 07, 05, 08 — подтвердить |
| G-KI-18 | Бэклог ТЗ и реализации (`G_spec_sync.md` §3): предложения MINOR OpenAPI (08 §16.15), ключи ARB этапа G (03 §16.9), вкладка «Товары» SCR-40, `Order.payments[].transactionId`, интервал `return_docs` 5 мин и др. | незначительная | не внесено — вносится одним изменением контракта, сервера и DTO | владельцы 08, 02 §7, 13; BE + FE |

Исправлено на этапе G по ревью и закрыто тестами (§5.1): все critical — G-credit-1 (условия соглашения после refresh),
G-customers-1c-1 (заказ нового клиента без зависимости и `customer.ref`), G-customers-1c-2 (заглушка реплики → дубль),
G-returns-txn-1 (повторная доставка документа возврата закрывала чужую заявку); major — гонка лимита в долг
(G-credit-3), гонка `POST /customers` (G-customers-1c-3), знак `order_cancelled` (G-returns-txn-2), расписание якорей
аудита (G-security-1), долг клиенту при `CUSTOMER_SELF_SERVICE=false` (G-security-2), HID-скан SCR-30
(G-flutter-ui-3), незавершённые операции SCR-38 (G-flutter-ui-2, G-flutter-data-2) и др. Исправитель Flutter раунда 2
нашёл и исправил ещё три дефекта pos-app с тестами: 503 на refresh долга, «Обновить QR» после TTL, переполнение чипа Z7.

### 3.2. Действующие допущения

До ответа заказчика действует значение «Допущение» 14 (реализованные уточнения этапа G — 14 §3.13).

| Q-NNN | Принятое допущение | Какие задачи от него зависят | Последствие при другом ответе |
|---|---|---|---|
| Q-015 | Лимиты ручной скидки `seller 5 / cashier 5 / senior 10 / admin 15 / owner 0`; скидка клиента и параметры правил 1С не передаются — итог 1С | RM-G-003 | меняются значения `role_discount_limits`; передача параметров — контракт 1С (18) |
| Q-017 | Продажа в долг — по соглашению 1С, fail-closed по PAY-031; продавец видит только «есть долг / просрочка»; разблокировка — только `senior_seller` в своей сессии со step-up | RM-G-002, 007, 011 | правка матрицы прав и `CreditDecisionService` |
| Q-018 | Заявка на возврат — в приложении, включена (`returns_enabled=true`); передача в 1С выключена (`RETURNS_FROM_POS_ENABLED=false`) | RM-G-005, 007 | `returns_enabled=false` без изменения кода; включение передачи — после Q-012 |
| Q-152 | «Нет»: оплата долга без заказа не принимается (`POST /payments` → 403) | RM-G-013 | реализация RM-G-013 (3 у.е.) и Q-177 |
| Q-012 | ПКО и реализации 1С вне приложения в журнал не попадают; документы долга — по типу документа 1С | RM-G-004 (TXN-007), RM-G-002 | лента ПКО и вид `transaction_kind` (G-KI-04) |
| Q-020 | Опрос статусов заявок на возврат в 1С — раз в 30 мин (05 §7.3: 5 мин — бэклог) | RM-G-005 | интервал планировщика |
| Q-025, Q-332 | «Всё равно создать» — с причиной, без проверки 1С; дубль по правилам 1С — по 05 SYNC-049 без перепривязки заказов | RM-G-001 | автопривязка к карточке 1С и перепривязка заказов (10 CUST-015) |
| Q-028 | Срок хранения аудита не задан; хэш-цепочка в R1 | RM-G-006 | регламент очистки `retention.daily` |
| Q-176, Q-215 | История — 90 дней по умолчанию; транзакции — текущие сутки; отчёты — 30 суток; максимум 366 дней | RM-G-001, 004, 006, 011 | значения по умолчанию |
| Q-251 | Refresh долга: 1 обращение к 1С на клиента за 30 с, 10 запросов/мин на пользователя (08 §2.9; в строке Q-251 14 — 60 с) | RM-G-011 | константы `RECEIVABLES_REFRESH_LIMITS` |
| Q-315 | Подтверждённый телефон привязки — основной телефон карточки из полной синхронизации 1С | RM-G-014 | правило самоподтверждения |
| Q-329 | Заявка клиента без привязки — на «Розничного покупателя» (08 §4.8.1), а не на карточку POS (10 CUST-023) | RM-F-015, RM-G-014 | смена карточки заявки |
| Q-331 | Отчёты SCR-48: заказы POS периода вне `draft`/`cancelled`/`submit_failed`; долг — только положительное сальдо снимков, без клиентов с пометкой удаления | RM-G-006, 008 | правка запросов отчётов |

### 3.3. Новые вопросы заказчику (14 v1.9: Q-331, Q-332)

Полный текст — `14_OPEN_QUESTIONS.md` §3.1. Реестр 232 → 234; Q-297 не использован. Дополнения к существующим
вопросам — 14 §3.13 (Q-012, Q-015, Q-017, Q-020, Q-025, Q-152, Q-176, Q-215, Q-251, Q-315).

| Q | Тема | Вопрос (кратко) | Действует до ответа | Кто отвечает |
|---|---|---|---|---|
| Q-331 | бизнес | Как считать отчёты руководителя SCR-48: продажи по дате заказа POS или реализации 1С; что считать продажей; учитывать ли авансы в общем долге | см. §3.2 | владелец магазина + бухгалтер |
| Q-332 | бизнес | Дубль клиента в 1С при создании из приложения: привязать к найденной карточке (10 CUST-015) или отказать с выбором существующего (05 SYNC-049) | отказ, выбор существующего, без перепривязки заказов | владелец + специалист 1С |

## 4. Условия перехода дальше

### 4.1. Статус ворот G-G — **красный, ворота не проходятся**

| Условие G-G (13 v2.4 §3.7) | Выполнено? | Доказательство |
|---|---|---|
| RM-G-001…RM-G-009, RM-G-011 закрыты | да (локально, на фейке 1С) | §1.2; §2.2 № 3–8 |
| RM-G-012 закрыта | **частично**: п. 5 — unit/widget вместо integration (G-KI-02) | §1.2 |
| RM-G-014 закрыта | да (локально) | §1.2; журнал 170–171, 499 |
| RM-G-013 — только при её запуске | не запускалась (Q-152 = «нет»); guard и тесты «выключено» есть | §1.2 |
| Покрытие ≥ 80 % | да: backend 95,09 %, каждый каталог G ≥ 80 %; Flutter по фичам G 87,4 % (profile и settings/domain ниже 80 % — G-KI-11) | §2.6 |
| RM-G-010 — отчёт | этот документ и `docs/known_issues.md` сданы; **п. 1 не выполнен полностью** (FLOW-026, Android) | §1.2; §2.4 |
| Возвраты: тесты `returns_enabled=false` и `RETURNS_FROM_POS_ENABLED=false` | да | `admin-settings-g`, `returns.e2e`, `cashier-flow` (`G_review.md` §3); журнал 162, 495–496 |
| Условные модули (по «да»): флаги и тесты «выключено» | оплата долга не реализована, тесты «выключено» (`DEBT_PAYMENTS_FROM_POS`) есть | `rbac-matrix`, `public-settings` |
| Режим клиента: тест `CUSTOMER_SELF_SERVICE=false` | да | `customers-self-service-off` e2e (G-security-2); guard G-8 |
| QR: тесты `QR_PROVIDER=onec` и `none` | да (регрессия F) | `pos-smoke` 30/30 (журнал 662–678, 960–961) |
| Нереализованные: тесты отсутствия маршрутов и экранов | да: `POST /payments/qr/webhook` → 404; R2-действий (CSV, «решено»/пауза) нет | `rbac-matrix` (журнал 486); RM-G-012 пп. 3–4 |
| `docs/known_issues.md` актуален | да (создан этой задачей, 2026-10-24) | `docs/known_issues.md` |
| Предшествующие ворота (G-F → G-G по 13 §4) | **нет**: G-F красные (RM-F-010), G-D и G-C — красные по своим отчётам | `F_cart_pos_report.md` §4.1; `known_issues.md` §2 |

Обоснование по 13 §6.2:
- открыт блокер RM-G-010 п. 1 — Android (G-KI-03) до подтверждения переноса на H владельцем 13 / заказчиком; открыта
  существенная G-KI-01 (FLOW-026), которую можно закрыть кодом теста;
- не закрыты предыдущие ворота: блокер G-F (RM-F-010) и блокеры окружения C/D (CI, Docker, Android, биометрия);
- по коду открытых critical нет; not_fixed ревью (G-KI-04…06) ждут решения ТЗ, от которого может измениться код.

Чтобы пройти G-G, нужно:
1. добавить шаг FLOW-026 в `cashier_flow_test` (G-KI-01) и integration-шаг RM-G-012 п. 5 (G-KI-02) или получить решение
   владельца 13, что п. 5 подтверждается unit/widget;
2. прогнать `integration_test` на Android-устройстве **или** получить подтверждение переноса Android на H (запись 13
   v2.4 §3.7) от владельца 13 / заказчика;
3. закрыть G-F (письменное решение заказчика по RM-F-010 или проверка на копии 1С);
4. решения владельцев ТЗ по G-KI-04, G-KI-06, G-KI-07, G-KI-17 — принять или явно оставить в `known_issues.md` с
   переносом (сейчас перенесены в `known_issues.md`).

### 4.2. Что требуется от заказчика

| Действие / вопрос | Для какой задачи | Срок (ворота) |
|---|---|---|
| Письменное решение по RM-F-010 (отложить до I с принятием риска) или копия 1С | G-F, а через него G-G | до G-G |
| Android-устройство (RM-A-008, O-13) или письменное согласие на перенос Android-прогона этапов F и G на этап H | RM-G-010 п. 1, RM-F-011 | до G-G / до H |
| Ответы на Q-331, Q-332 | RM-G-006, RM-G-001 | до H |
| Ответы на существующие вопросы с дополнениями 14 §3.13: Q-012 (ПКО и документы 1С; TXN-007), Q-015 (лимиты скидок), Q-017 (долг), Q-018 (возвраты), Q-152 (оплата долга без заказа — подтвердить «нет»), Q-020, Q-025, Q-176, Q-215, Q-251, Q-315; а также Q-325…Q-330 этапа F (Q-329 — расхождение 10 CUST-023 и 08) | RM-G-001…006, 011, 013, 014 | до H |
| Передать специалисту 1С предложения полей контракта 1С этапа G (05 §5.3 «Уточнения … этапа G»: `kind` контрагента, `discountPercent` соглашения, параметры `DiscountChange`, признак проведения документа долга, лента ПКО, `returnRequestExternalId`) вместе с `18_ONEC_API_REQUEST.md` (O-04); тестовая копия УТ 11.5 (O-05) | реальная интеграция RM-G-001…005 | до I |
| Принтеры 80 мм и A4 (RM-A-009) | печать SCR-37/38, SCR-42 | до H |
| Решение о CI и хранилище кода (O-23, Q-131); разрешение на Docker | CI, тестовый контур | до H |
| Держать на C: машины разработки ≥ 300 МБ свободными (данные на C: принадлежат пользователю и командой не удаляются) | `integration_test` | постоянно |

Действия команды (не заказчика): FE + QA — G-KI-01, G-KI-02, G-KI-08, G-KI-11, T-CASH-009; BE — G-KI-12, G-KI-13,
`Order.payments[].transactionId`; владелец 13 — исправить запись о FLOW-026 в §3.7, решение по Android, п. 5 RM-G-012;
владелец 02 §7 — тексты ключей 03 §16.9; владелец 08 — предложения MINOR 08 §16.15; владельцы 07/05 — FIX-G-TXN-07,
FIX-G-TXN-SIGN, FIX-G-SNAP-FUTURE; владелец `trace_test_ids.py` — причины not_done (R2-N-02).

### 4.3. Что не сделано и почему (итог этапа)

| Что | Почему | Кто и когда |
|---|---|---|
| Реальная 1С (клиенты, долги, скидки, история, документы возврата, ПКО) | API специалиста 1С и копии УТ 11.5 нет | специалист 1С (18), ONEC; до I |
| Android, iOS | эмулятор запускать запрещено, устройства и macOS нет | QA, этап H (после подтверждения) |
| FLOW-026 в integration_test | шаг не написан; запись в 13 §3.7 ошибочна | FE + QA, до G-G |
| RM-G-012 п. 5 integration | шаг не написан | FE + QA |
| RM-G-013 (оплата долга без заказа) | по Q-152 = «нет» — только guard и тесты «выключено» (13 §3.12) | при «да» по Q-152 |
| TXN-007 для реализаций и ПКО 1С | нет вида `transaction_kind` в ядре и ленты ПКО в контракте 1С | владелец ядра + 07 + 1С |
| Подписи SCR-46, статусы outbox SCR-43, «Лимит в 1С не задан» | нет ключей ARB (03 §16.9 — предложены, не внесены) | владелец 02 §7 → FE |
| Полные наборы T-UI-030…048 | по 12 v1.8 §2.15 — этап H | QA, этап H |
| Печать на принтер, USB ESC/POS | принтеров нет; USB не поддержан | QA / FE |
| Docker, CI | Docker не установлен; коммитов нет | OPS |

### 4.4. Решения, принятые на этапе

ADR, добавленные в `docs/specification/15_DECISION_LOG.md` (приложение Ж) при синхронизации ТЗ:
- ADR-104 — клиенты, долги и скидки (снимок долга, порядок PAY-031, зависимость заказа от `customer/create`);
- ADR-105 — журнал операций, дашборд, заявки на возврат, лимиты RL-RECV-REFRESH (память процесса в R1);
- ADR-106 — аудит (якоря и расписание), настройки, отчёты, режим клиента на сервере;
- ADR-107 — Flutter этапа G (составные компоненты, порты корня, режим клиента без фичи `customer_orders`).

## 5. Приложения

### 5.1. Независимая проверка — `docs/reviews/G_review.md`

| Показатель | Раунд 1 (10:00–11:40) | Раунд 2 (12:24–13:51) |
|---|---|---|
| Найдено и подтверждено (два скептика) | 58 замечаний (дубли считаются отдельно), из них исходно critical — 5 (G-credit-1, G-customers-1c-1, G-customers-1c-2, G-returns-txn-1, G-trace-1; все, кроме G-customers-1c-1, скептики оценили как major) | — (новых подтверждённых нет) |
| Опровергнуто | 4 (G-customers-1c-4, G-customers-1c-5, G-flutter-ui-1, G-trace-2) | без изменений |
| fixed / partially_fixed / not_fixed / not_a_defect | 47 / 5 / 4 / 2 | 47 / 5 / 4 / 2 (остатки G-trace-7 и G-trace-8 заметно меньше) |
| Осталось | G-trace-8 (FLOW-016, 022, 025, 029, 031, 033, 037), G-trace-7 (T-UI 17/18), not_fixed — решения ТЗ | G-trace-8: только FLOW-026 (+ Android); G-trace-7: решения владельцев 12/13/02; G-trace-1, G-trace-14, G-flutter-ui-5 — остатки; not_fixed G-returns-txn-4, G-trace-11, G-security-4, G-flutter-ui-6 — решения ТЗ |
| Новые наблюдения (без скептиков) | R1-N-01 (нестабильный otp.e2e), R1-N-02 (покрытие profile/settings), R1-N-03 (заказ при `failed` клиента), R1-N-04 (команда запуска auth-тестов) | R2-N-01 (ложная запись о FLOW-026), R2-N-02 (устаревшие причины trace), R2-N-03 (повтор токена step-up, info) |
| Вывод по G-G | не проходятся | не проходятся: нет `G_cashier_report.md` и `known_issues.md` (закрыто этой задачей), FLOW-026, Android, решения владельцев |

Статус «not_fixed» у G-returns-txn-4 / G-trace-11 / G-security-4 / G-flutter-ui-6 — «ждёт решения ТЗ», дефектом кода до
решения ревью их не считает. После ревью синхронизация ТЗ записала решения для части пунктов (08 §2.9 — память процесса
для RL-RECV-REFRESH; 12 §2.15 — T-UI вне ворот G-G; 13 §3.7 — состав RM-G-010 п. 1 и перенос Android на H); эти записи
— технические уточнения исполнителя, не ответы заказчика.

### 5.2. Синхронизация ТЗ — `docs/stages/G_spec_sync.md`

- 169 пунктов: A 68, A+C 55, C 25, A+B\* 15, A+B 4, B\* 2; техническая часть внесена в ТЗ у 142, вопрос заказчику — у 21,
  решено / бэклог — 80.
- Версии: 02 1.14, 03 1.5, 05 1.4, 06 1.5, 07 1.14 (+ замечание к ядру §19 п. 30), 08 1.18, 10 (пометки, журнал §28),
  11 1.3, 12 1.8, 13 2.4, 14 1.9, 15 1.13 (ADR-104…107), `visual/navigation.md` 1.10, README 1.7, 00 1.9. Не менялись:
  01, 04, 09, 16, 17, 18, ядро, `resursi/`.
- Контракты: 5 текстов описаний OpenAPI 1.2.0 (`customers_discounts_get` 403 → 404, `returns_delete` — физическое
  удаление, `returns_create` 403 `returns_disabled`, `transactions_get` — `audit.viewed`, `Receivable` — `null` без
  снимка); CHANGELOG [1.2.0] «Уточнено (spec-sync этапа G)»; версия не повышалась (1.2.0 не выпущена).
- Не внесено (бэклог, `G_spec_sync.md` §3): предложения MINOR OpenAPI (08 §16.15) — одним изменением с сервером и DTO;
  ключи ARB этапа G (03 §16.9); TXN-007 для документов 1С (решение по enum ядра).
- Проверки после синхронизации — все код 0 (`G_spec_sync.md` §2), Flutter-тесты не запускались (код не менялся).
- Замечание к синхронизации: строка бэклога «HID-скан номера заказа на SCR-30» (`G_spec_sync.md` §3, GQ-FECASH-02) уже
  выполнена исправлением G-flutter-ui-3; запись 13 v2.4 §3.7 о FLOW-026 в `pos_flow_test` не подтверждается (G-KI-01).

### 5.3. Состояние окружения

- Windows 11 Pro 10.0.26200; Node 24, embedded PostgreSQL 17.10 (без Docker); Flutter 3.38.7 / Dart 3.10.7;
  `TEMP=TMP=D:/optomstroy/.tmp`, `PUB_CACHE=D:/optomstroy/.tmp/pub-cache`; данные `integration_test` —
  `APP_DATA_DIR=D:/optomstroy/.tmp/appdata` (`pos-app/env/local.json`).
- Место на C: (диск пользователя, не трогался): раунд 2 — 3 514–3 540 МБ; свежий прогон — 3 598 МБ до, 2 506 МБ после `test:cov:g`, 2 576 МБ в конце (причина уменьшения не установлена; ≥ 300 МБ на всём протяжении).
- Процессы: после свежего прогона своих `node`, `postgres`, `flutter_tester` не осталось (стек `cashier_flow_test` остановлен тестом, код 0); `flutter_tester` PID 30728 (запущен 01:24) — не мой, не трогался.
- `pos-app/.dart_tool/flutter_build` удалён после `integration_test`.

### 5.4. Прочие документы этапа

- `docs/stages/G_test_run.log` — журнал прогонов (CRLF), включая раздел «Свежий прогон для отчёта этапа G».
- `docs/stages/G_spec_questions.md` — вопросы к ТЗ агентов, исправителей (разделы FIX) и таблица статусов после
  синхронизации.
- `docs/stages/G_spec_sync.md` — синхронизация ТЗ.
- `docs/reviews/G_review.md` — независимая проверка, раунды 1–2.
- `docs/known_issues.md` — известные проблемы этапов C–G и внешние зависимости (RM-G-010).
- Сырые логи: `D:/optomstroy/.tmp/verify_g1/`, `D:/optomstroy/.tmp/verify_g2/` (проверяющий), `D:/optomstroy/.tmp/report_g/`
  (свежий прогон этого отчёта).

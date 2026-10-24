# Отчёт по этапу F — Cart and POS (корзина, проверки, заказ, платежи, ошибки) «Оптомстрой POS»

**Этап:** F — Cart and POS · **Задача фиксации этапа:** RM-F-011 · **Ворота:** G-F
**Дата отчёта:** 2026-10-24 (**финальная редакция** — по журналу «Финальный прогон этапа F» (строки 1357–1424) и `F_review.md` «Закрытие остатков этапа F»: §Итог, §1.1, §1.2, §3.1, §4, §5 обновлены; редакция после закрытия остатков этапа F — §Итог, §2.4, §2.5, §2.6, §3.1, §4.1 обновлены по журналу «Прогон после закрытия остатков F»; ревью закрытия F, RR-3; редакция по повтору при свободном месте на C: — §Итог, §1.2, §2.1, §2.4–§2.6, §3.1, §4 обновлены по журналу «Прогон после закрытия остатков F — повтор при свободном месте на C:» и «Второй круг ревью закрытия F», RR-1) · **Автор (владелец отчёта):** QA + ARCH (13 §2.2) · **Независимый проверяющий:** отдельный
агент, не автор кода — `docs/reviews/F_review.md` (раунд 1 — 06:56–08:00, раунд 2 — 09:23–10:31). Этот отчёт и свежий
прогон для него (§2.1) выполнил автор итоговых документов. Повторной независимой проверки этой редакции отчёта не было.
**Основание:** 13_IMPLEMENTATION_ROADMAP §3.6 (RM-F-001…RM-F-016, ворота G-F), §6.1–§6.3; 12 §2.15 (строка «F — Cart
and POS»); ядро R0 v1.9 (приоритет §24 > §23 > … > §16; D-19…D-23, D-26, D-27, D-32, D-41, §17.2, §17.4, §19.2, §19.4,
§22.1–§22.6, §23, §24.2, §24.4).

> **На фикстурах, не реальная интеграция** (SRC-D-176). API специалиста 1С не получен, тестовой копии 1С нет
> (ядро §24.3, RM-A-006, RM-E-016 — «API 1С не получен»). Все прогоны этапа F шли на `FakeOnecGateway` /
> `ScriptedOnecGateway`, управляемом фейке HTTP-сервиса расширения (`pos-api/scripts/pos_fake_onec.ts`) и фикстурах
> `contracts/onec/fixtures`. Данных заказчика нет. Коммитов этапов B–F нет; CI на GitHub Actions не запускался.
> Android/iOS не проверялись. Печать на физический принтер не проверялась.

**Ссылки на доказательства.** «Журнал NNNN» — номер строки `docs/stages/F_test_run.log`. Основные разделы журнала:
- §3 «Итоговые прогоны» интеграции backend — строки 338–588;
- §6 «Интеграция Flutter этапа F» (единственные прогоны `integration_test` этапа) — строки 652–726;
- §7 «Исправление замечаний ревью — backend» — строки 728–834;
- «Перепроверка после ревью, раунд 1» (независимый проверяющий) — строки 836–915;
- §8 «Исправление замечаний ревью — раунд 2» — строки 917–976;
- **«Перепроверка после ревью, раунд 2»** (независимый проверяющий, последняя полная перепроверка) — строки 978–1065;
- **«Свежий прогон для отчёта этапа F»** (автор отчёта) — строки 1067–1100;
- «Прогон после закрытия остатков F» (независимый проверяющий, последовательный полный прогон) — строки 1102–1203;
- **«Прогон после закрытия остатков F — повтор при свободном месте на C:»** (независимый проверяющий; **последний полный
  прогон**, впервые после ревью — с `integration_test` на Windows) — строки 1205–1328;
- «Второй круг ревью закрытия F» (повтор `pos_flow_test` и выборочных тестов после правок ТЗ) — строки 1330–1355;
- **«Финальный прогон этапа F»** (автор итоговых документов, после исправлений второго круга ревью закрытия — Fix2;
  **последний прогон**, короткий: затронутое Fix2 и ключевые проверки) — строки 1357–1424.

## Итог

- **Ворота G-F не закрываются** (§4.1). Главная причина — нет письменного решения заказчика отложить RM-F-010
  (сквозная проверка заказа на копии 1С) до этапа I. Кроме того:
  - перечень защитных ветвей `F_branch_exceptions.md` §2 (E-1…E-3, FIX-F-23) владельцем 13 не утверждён; сами ветви
    покрыты тестами с подменой — `test:cov:f` даёт 100 % ветвей во всех критичных файлах (журнал 1225–1230; финальный
    прогон — журнал 1357–1424);
  - ответов заказчика на Q-325…Q-330 нет; реализованы допущения 14. По Q-329 (10 CUST-023) реализовано допущение
    08 §4.8.1, расхождение с документом-владельцем 10 записано пометками, за заказчика не решено;
  - прежние причины частичного выполнения RM-F-005/007/009/013 сняты повтором при свободном месте на C: (журнал 1205–1328):
    `integration_test` на Windows пройдены, включая RM-F-013 п. 4 (перезапуск во время ожидания QR), RM-F-005 п. 2 и
    RM-F-007 п. 2; T-UI-026 с тестом (AC-UI-26-008, `flutter test` +1749); матрица F — 242 / 211 / 31 / 0. Повтор
    `pos_flow_test` после правок ТЗ — 4 из 4 (журнал 1330–1355).
- **Финальный прогон этапа F** (журнал 1357–1424; 23.10 23:18 — 24.10 00:01, после Fix2; на C: 22–23 ГБ). Все команды —
  код 0: pos-api `lint`, `test:all` — 27 наборов, **1316 passed**, 7 skipped, 0 failed; `test:cov:f` — 774 passed,
  ветви всех критичных файлов **100 %**; целевые тесты Fix2 (RC-5, RC-6, RC-7); `flutter analyze`, `flutter test`
  **+1759**; `integration_test` на Windows: **`pos_flow_test` 4 из 4**, `catalog_flow_test` 2 из 2; `sync_contracts
  --check`, `check_no_double_money`, `check_secrets`, `check_repo_layout`, `build_openapi --check`, `check_arb_keys`;
  `trace_test_ids --stage F`: 242 / **211** / **31** / 0. В коротком прогоне не повторялись (Fix2 их не затрагивал;
  последний зелёный результат — журнал 1205–1328): `test:cov:e`, `test:cov:d`, `test:e2e:pos`, smoke, миграции,
  `flutter build windows --release`, `auth_flow_test`, `admin_invite_flow_test`, `boot_test`.
- **Последний полный прогон — повтор при свободном месте на C:** (журнал 1205–1328; независимый проверяющий, 21:48–22:53, на C:
  23 ГБ). Все команды — код 0: pos-api `test:all` — 27 наборов, **1298 passed**, 7 skipped, 0 failed; `test:cov:f` —
  756 passed, ветви критичных файлов 100 %; `test:cov:e`, `test:cov:d`, `test:e2e:pos`, четыре smoke (`pos-smoke` 30/30),
  миграции 0001…0013; `flutter analyze`, `flutter test` **1749**, golden 230, `flutter build windows --release`;
  **`integration_test` на Windows**: `pos_flow_test` 4 из 4, `catalog_flow_test` 2, `auth_flow_test` 3,
  `admin_invite_flow_test` 1, `boot_test` 1; скрипты корня; `trace_test_ids --stage F`: 242 / **211** / **31** / 0.
- **Предыдущий полный прогон — после закрытия остатков F** (журнал 1102–1203; независимый проверяющий, строго
  последовательно, 14:51–15:43). Все команды зелёные:
  - pos-api `test:all` — 27 наборов, **1286 passed**, 7 skipped, 0 failed; `test:cov:f` — 744 passed, строки 94,18 %,
    ветви 83,36 %; `test:cov:e`, `test:cov:d`, `test:e2e:pos`, четыре smoke local-stack (`pos-smoke` 30/30), миграции
    0001…0013;
  - `flutter analyze`, `flutter test` **1721**, golden 224, `flutter build windows --release`;
  - все скрипты корня (код 0), `trace_test_ids --stage F`: 242 / 210 с тестом / 32 not_done / 0 (в повторе — 211 / 31);
  - `integration_test` в этом прогоне не запускались (на C: было 100–157 МБ) — выполнены в повторе (журнал 1205–1328).
- **Перепроверка раунда 2** (до закрытия остатков) — независимый проверяющий (журнал 978–1065). Все команды зелёные:
  - pos-api `test:all` — 1209 passed, 7 skipped, 0 failed (журнал 993);
  - `test:cov:f` — строки 92,8 %, ветви 79,98 % (журнал 994–999);
  - `test:cov:e`, `test:cov:d`, `test:e2e:pos`, четыре smoke local-stack (`pos-smoke` 30/30), миграции;
  - `flutter analyze`, `flutter test` 1650, golden 220, `flutter build windows --release` (журнал 1022–1028);
  - все скрипты корня, включая `trace_test_ids.py --stage F` (код 0; журнал 1034–1055).
- **Свежий прогон для отчёта** (§2.1; журнал 1067–1100), результаты совпадают с раундом 2:
  - `test:cov:f` — 667 passed, 0 failed; строки 92,8 %, ветви 79,98 %;
  - `flutter test --concurrency=2` — 1650 passed; `test:e2e:pos` — 1 passed;
  - `trace_test_ids --stage F` и гейты — код 0;
  - `pos_flow_test` не запускался: на C: 7–28 МБ.
- **Интеграционные тесты Flutter после исправлений ревью пройдены** в повторе при свободном месте на C: (журнал 1205–1328):
  `pos_flow_test` 4 из 4 — с новыми сценариями «перезапуск над той же БД», «1С недоступна → `submitting` → уведомление»
  (F-trace-5) и «перезапуск во время ожидания QR» (F-trace-4); регрессия `catalog_flow_test`, `auth_flow_test`,
  `admin_invite_flow_test`, `boot_test` — зелёная; повтор `pos_flow_test` после правок ТЗ — 4 из 4 (журнал 1330–1355).
  Раньше (на C: 7–39 МБ) единственный зелёный прогон `pos_flow_test` (3 из 3) был до ревью (журнал 694–706), а
  единственный прогон новых сценариев — красным (`F_review.md`, F-trace-5).
- Матрица T-ID этапа F (повтор, журнал 1205–1328; журнал 1330–1355): 242 ID, из них 211 с тестом (61 — частично), 31 not_done с
  причиной, 0 без теста и причины. Невыполненной работы этапа среди not_done нет: T-UI-026 получил тест
  (`new_customer_screen_test.dart`, AC-UI-26-008), подтверждён `flutter test`; единственный not_done с открытым FIX —
  T-TXN-008 (FIX-F-21, ждёт Q-330), остальные 30 — перенос на G/H/L3/R2 или ручная проверка (§2.5; до закрытия
  остатков — 200 / 42, из них 15 невыполненных; после закрытия остатков — 210 / 32).
- Ветви критичных файлов (повтор, журнал 1205–1328, `coverage/stage-f/coverage-summary.json`): создание заказа,
  `checkout.service`, `payments-port`, `payments.service` (191/191), обработчик результатов 1С (89/89), идемпотентность
  и автоматы — 100 %. Критерий RM-F-009 «100 % веток» выполнен; перечень защитных ветвей `F_branch_exceptions.md` §2
  (покрыты тестами с подменой) ждёт утверждения владельцем 13 (§2.6). После закрытия остатков (журнал 1102–1203) было
  99,47 % и 97,75 %.
- Ревью: 60 подтверждённых замечаний раундов 1–2 (из них 7 critical). После закрытия остатков (`F_review.md`
  «Закрытие остатков этапа F», ЗО.3) — **fixed 53, partially_fixed 4, not_fixed 3** (после раунда 2 было 45 / 11 / 4).
  Все 3 not_fixed ждут решения заказчика или владельца ТЗ: F-money-rules-5 (Q-329), F-flutter-ui-12 (Q-019),
  F-trace-15 (FIX-F-15). Ревью закрытия, круг 2 — 20 подтверждённых замечаний (1 major RS-1, 19 minor): fixed 19,
  partially_fixed 1 (RC-8). Все critical исправлены; интеграционно сценарии critical Flutter проверены `pos_flow_test`
  (§5.1).
- Синхронизация ТЗ: разобран 201 пункт `F_spec_questions.md`, новые вопросы Q-325…Q-330, ADR-098…ADR-102; при
  закрытии остатков — OpenAPI и `enums.json` 1.2.0, ключи ARB этапа F, ADR-103 (§5.2).
- Не сделано по окружению и объёму этапа (§2.4, §4.3): реальная 1С (RM-F-010); Android и iOS; печать на принтер;
  Docker/compose и CI; поиск и создание клиента в SCR-21 на стенде — этап G (RM-G-001).

---

## 1. Готовые файлы

Коммитов этапов B–F нет, поэтому все пути ниже — неотслеживаемые или изменённые (`git status`). Владельцы — по
CONTRIBUTING.md §5 (13 §5.2).

### 1.1. Пути

| Путь | Новый / изменён | Задачи `RM-*` | Владелец | Версия контракта (было → стало) | Примечание |
|---|---|---|---|---|---|
| `pos-api/src/sales-domain/**` (деньги, скидки, идемпотентность, автоматы заказа и платежа), `src/common/ports/**` | новый | RM-F-001…003, 009 | BE + POS | — | D-19 (NUMERIC(14,2), HALF_UP, коррекция последней строки) |
| `pos-api/src/cart/**`, `migrations/0009_cart.sql` | новый | RM-F-001, 012, 015 | BE + POS | — | `/check` 1С в модуле `cart` (FQ-INT-04), `503 catalog_not_loaded` (FIX-F-07) |
| `pos-api/src/orders/**` (кроме `documents/`), `src/sync/outbox/**`, `src/jobs/**` (заказы, outbox) | новый / изм. | RM-F-002, 012, 015 | BE + ONEC | — | outbox по 07 §6.5, `onec-link`, `statusCounts` |
| `pos-api/src/payments/**` (без `qr-webhook/`), `migrations/0011_payments.sql`, `0012_payments_qr_ref_history.sql` | новый | RM-F-003, 012, 016 | BE + POS | — | QR через 1С и `QR_PROVIDER=none`; `qr_ref_history` (FIX-F-05, expand) |
| `pos-api/src/orders/documents/**`, `assets/templates/pdf/*.json`, шрифт в `assets/` | новый | RM-F-004, 012 п. 5 | BE + POS | — | pdfkit и JSON-шаблоны вместо `.hbs` (ADR-098, уточнение 13 §3.6) |
| `pos-api/src/notifications/**` (кроме `sms/`) | новый | RM-F-008 | BE | — | D-41 |
| `pos-api/src/common/rate-limit/**` (RL-FIN, RL-PDF) | изм. | RM-F-003 (ревью F-security-2) | SEC | — | |
| `pos-api/src/worker.ts`, `src/common/db/database.module.ts` | изм. | RM-F-002, 016 | BE | — | `pos-worker` — контекст Nest (ADR-101); слушатель `error` у `pg.Pool` (раунд 2, T-FAIL-012) |
| `pos-api/scripts/{pos_fake_onec.ts,local-stack.mjs}` (`pos-smoke`, `--pos-fixtures`), `test/support/pos-fixture.ts` | новый / изм. | RM-F-009, 010 | ONEC + QA | — | фейк HTTP-сервиса расширения — **тестовые данные** |
| `pos-api/test/{sales-domain,cart,orders,payments,documents,notifications}/**`, `test/e2e/pos/**`, `vitest.config.cov-f.ts` | новый | RM-F-009 | QA | — | T-ID в комментариях над 106 тестами (раунд 2) |
| `pos-api/Dockerfile`, `infra/docker/api/Dockerfile` (`COPY assets`) | изм. | RM-F-004 | OPS | — | сборка образа не проверялась (Docker нет) |
| `docs/erd/schema_v1.sql` | изм. (перегенерирован штатной командой) | RM-F-001…003 | BE | — | миграции 0009, 0011, 0012 |
| `pos-app/lib/features/cart/**`, `design_system/components/{cart_panel,cart_line,cart_summary,cart_fab,discount_input}*` | новый / изм. | RM-F-005, 013, 015 | FE + DS | — | CART-005 (смена варианта строки) реализован при закрытии остатков; RC-1, RC-2, RC-8 — Fix2 |
| `pos-app/lib/features/checkout/**`, `features/customers/presentation/new/**`, DS `CheckoutStepper`, `CustomerPicker`, `CustomerCard`, `PaymentMethodCard`, `QrPanel` | новый | RM-F-006, 013, 015 | FE + DS | — | SCR-21, SCR-22, SCR-26 |
| `pos-app/lib/features/orders/**`, DS `OrderStatusChip`, `StatusCountChips`, `DocumentActions` | новый | RM-F-004 (клиент), 006, 013 п. 5 | FE + DS | — | SCR-24, SCR-25 |
| `pos-app/lib/features/notifications/**`, DS `NotificationBell` | новый | RM-F-008 | FE | — | SCR-44 |
| `pos-app/lib/core/error/error_mapper.dart`, `docs/errors_matrix.md`, `scripts/gen_errors_matrix.py` | новый | RM-F-007 | FE + BE | — | матрица генерируется скриптом (`--check`) |
| `pos-app/lib/core/database/**` (drift v5), `core/sync/**`, `core/session/**` (`pending_logout`), `app/di/overrides.dart` (`stageFOverrides`), `app/router/**` | новый / изм. | RM-F-005, 013; переносы E (§1.3) | FE | — | единый реестр outbox в корне (ADR-102) |
| `pos-app/lib/design_system/components/app_bottom_sheet.dart`, `test/golden/app_bottom_sheet_side_golden_test.dart` | изм. / новый | RM-F-013 п. 5 | DS | — | side 400 / 480 |
| `pos-app/pubspec.yaml` (`printing`, `qr_flutter`, `file_selector`, `dependency_overrides: image: 4.8.0`) | изм. | RM-F-004, 006 | FE | — | PDFium скачивается при сборке Windows (FQ-INT-F-07) |
| `pos-app/integration_test/pos_flow_test.dart` | новый | RM-F-009, 011 | QA | — | имя выхода в 13 — `checkout_flow_test.dart` (FIX-F-15) |
| `scripts/trace_test_ids.py` (`--stage F`), `scripts/check_money_vectors.py` (новый), `docs/repo_layout.md` | изм. / новый | RM-F-009 | QA | — | ревью F-trace-1, F-trace-13, F-fresh-run-1 |
| `docs/stages/F_test_run.log`, `F_spec_questions.md`, `F_spec_sync.md`, `F_onec_e2e_report.md`, `docs/reviews/F_review.md`, этот отчёт | новый | RM-F-009…011 | QA + ARCH | — | |
| 00, 02, 03, 05, 06, 07, 08, 10 (только пометки), 11, 12, 13, 14, 15, 16, `README.md`, `visual/navigation.md` | изм. (синхронизация ТЗ) | — | владельцы документов | см. `F_spec_sync.md` §1 | ядро и бизнес-правила не менялись |
| `contracts/openapi/**`, `contracts/enums.json`, `contracts/l10n/app_{ru,ky,en}.arb` | изм. при закрытии остатков | RM-F-001…003, 007, 008 | владельцы 08, 07, 02 §7 | OpenAPI и `enums.json` **1.1.0 → 1.2.0** (MINOR, ADR-103); ARB 1998 → 2024 ключей | `QR_PAID_AFTER_VOID`, `Problem.previewTotal`/`total`/`possibleDuplicate*`, `Cart.restoredFromOrder`, `Payment.transactionId` (сервер пока не отдаёт — этап G), `before`, `503 catalog_not_loaded`; ICU plural; `permissions.yaml` и фикстуры 1С не менялись |
| `pos-api/migrations/0013_sync_error_code_qr_paid_after_void.sql` | новый (expand) | RM-F-016 | BE | — | CHECK `sync_errors`, `onec_outbox`, `sync_node_state` |

### 1.2. Статус задач этапа

- «Закрыта (локально)» — все пункты критерия 13 §3.6 выполнены запуском на машине разработчика (на фейке 1С).
- «Частично» — часть пунктов не выполнена; причина указана.
- Колонка «Подтверждение» ссылается на журнал. Наборы pos-api — `test:all` раунда 2 (журнал 993, 1209 тестов);
  pos-app — `flutter test` раунда 2 (журнал 1025, 1650 тестов) и свежий прогон §2.1. **Последнее подтверждение всех
  строк — финальный прогон** (журнал 1357–1424: `test:all` 1316 passed, `test:cov:f` 774 passed, `flutter test` +1759,
  `pos_flow_test` 4 из 4, `catalog_flow_test` 2 из 2 — всё код 0).
- Каждый тест с текстом 12 и 13 построчно не сверялся. Опора — журнал, ревью (`F_review.md`) и матрица T-ID (§2.5).

| Задача | Статус | Что подтверждено запуском (пункты критерия) | Подтверждение | Что не выполнено (причина) |
|---|---|---|---|---|
| RM-F-001 Backend корзина | закрыта (локально) | п. 1: корзина макета → скидка 842,50, итого 16 007,50 (`cart-unit.spec.ts`, `cart-items.e2e`); п. 2: распределение скидки сходится в итог (`pricing.spec.ts` с независимым оракулом 07 §7.3, векторы MV — `check_money_vectors` backend 27/27); п. 3: 7 % под `seller` → `DISCOUNT_LIMIT_EXCEEDED` (`cart-items.e2e`, `cart-flow.e2e`); п. 4: `checkout-preview` после смены цены в фикстуре → предупреждение с `oldPrice` и `newPrice` (`cart-flow.e2e`) | журнал 993; 1047; журнал 1357–1424 | «preview ≡ order» — property-тест на реальной корзине и `POST /orders` (60 прогонов, фиксированный seed; закрытие остатков и RC-6); лимит роли — property; одобрение сверх лимита — примерами и e2e, не property (F-money-rules-9, оговорка) |
| RM-F-002 Backend заказы | закрыта (локально), на фейке 1С | п. 1: тот же ключ → один заказ, другое тело → `IDEMPOTENCY_KEY_REUSED`; без ключа и параллельно (`orders-create.e2e`, `orders-money-rules.e2e`); п. 2: 1С недоступна → `202 submitting`, outbox `pending` → `sent` с проекцией по 10 §2.2, затем `confirmed` без повторной записи истории (`orders-outbox.e2e`, `orders-cart-integration.e2e`); п. 3: отказ 1С → `submit_failed` + уведомление (`order-onec-results.int`, `orders-ops.e2e`); п. 4: `dead` по числу попыток и возрасту (`orders-outbox.e2e`, `worker.int`) | журнал 993; 1007 (`pos-smoke` 30/30) | Реальной 1С нет (RM-F-010). Ветви `order-create.service.ts` — 100 % (310/310) в финальном прогоне (в раунде 2 — 88,7 %) |
| RM-F-003 Backend платежи | закрыта (локально) | п. 1: `QR_PROVIDER=none` → `qr_shown` → ручное подтверждение требует step-up → `received`, аудит и `transactions` (`payments-none.e2e`); п. 2: `/payments/qr/webhook` → 404 (`payments-none`, `payments-qr-onec`, `stage-f-static.spec.ts`); п. 3: `credit` → `CREDIT_BLOCKED` (`credit-gate.spec.ts`, `orders-create.e2e`); п. 4: `?wait=25` с подменой `Clock`, второй ожидающий запрос отклоняется; п. 5: `ORDER_STATE_INVALID`; п. 6: смена способа → `voided` / `method_changed` без step-up; ручной `void` без step-up → `STEP_UP_REQUIRED`, без права → 403; `review_reason=no_webhook` | журнал 993 | Ветви `payments.service.ts` и `payments-port.service.ts` — 100 % в финальном прогоне (в раунде 2 — 84,1 % и 91,9 %). Пределы long-polling (≤ 3 на пользователя, ≤ 200 на процесс) — допущение, вопрос владельцу 08 (FIX-F-12) |
| RM-F-004 Печатные документы | закрыта (локально), с уточнением 13 | п. 1: текст PDF извлекается (номер, клиент, строки, суммы) — собственный разборщик `test/documents/support/pdf-text.ts` вместо `pdf-parse` (уточнение 13 §3.6); п. 2: «Нефискальный документ» (`pdf-parse.spec.ts`, `pdf-renderer.spec.ts`); п. 3: генерация ≤ 2 с (те же тесты, `documents.e2e`) | журнал 958 (раунд 2: documents 27 passed, `documents.e2e` ×3 — 11/11); 993 | Печать на физический принтер не проверялась (принтеров RM-A-009 нет). Реквизиты организации — Q-019. QR на чеке не печатается (Q-325). Время ≤ 2 с — на машине разработчика |
| RM-F-005 Flutter корзина | закрыта (локально) | п. 1: итоги только из ответа сервера (`cart_screen_test`: «итоги — только с сервера»); п. 2: перезапуск восстанавливает черновик — **widget-тест на реальном drift** (новый объект над той же БД, `cart_wiring_test.dart`, `drift_cart_sync_test`), по уточнению 13 §3.6; п. 3: офлайн `cart.sync` по 07 §11.2 применяется один раз (`drift_cart_sync_test`, «серия “+” < 500 мс → один PUT») | журнал 1025; §2.1 | *Раунд 2 (исторически):* п. 2 integration не выполнен: сценарий «перезапуск над той же БД» в `pos_flow_test` ни разу не прошёл, повтор невозможен — нет места на C: (F-trace-5). **10 CART-005 (must) не реализован**: смены варианта в строке (SCR-15 в режиме смены, «Заменить вариант», «Объединить количества?») нет (R2-N-01, §3.1). **Обновление (журнал 1205–1328; журнал 1330–1355):** п. 2 integration пройден (`pos_flow_test`, «перезапуск — черновик корзины восстановлен и сверен с сервером»); CART-005 реализован (F-KI-02 закрыт). **Финальный прогон (журнал 1357–1424):** `pos_flow_test` 4 из 4; дефекты смены варианта RC-1 (очередь `cart.sync`) и RC-2 (сбой между PUT и удалением) исправлены; RC-8 (отказ `max_items`) — частично (F-KI-19) |
| RM-F-006 Flutter оформление | **частично** | п. 1: golden SCR-21 (`checkout_golden_test.dart`); п. 2: CTA недоступна без способа оплаты (`checkout_screen_test`); без клиента 1С при обязательности — `422 CUSTOMER_NOT_IDENTIFIED` (AC-UI-21-026; «Розничный покупатель» по умолчанию — 08 §4.8.1); п. 3: двойное нажатие → один `POST /orders`, ключ из `checkout_draft`; п. 4: кнопки «Выбрать на карте» нет; п. 5: доставка требует адрес и телефон. SCR-22, SCR-24, SCR-25, SCR-26 — widget и golden | журнал 1025–1026; 696–704 (INT-FE: сценарии продавца и клиента на Windows) | Поиск и создание клиента в SCR-21 на стенде не проверены: `GET /customers`, `POST /customers` — этап G (RM-G-001, FQ-INT-F-02). Дедупликация SCR-26 с 1С — этап G. Приёмочные наборы T-UI-020…026 неполны (§2.5) |
| RM-F-007 Ошибки и состояния | закрыта (локально) | п. 1: каждый код `contracts/enums.json` имеет строку и действие (`error_mapper_test.dart`), `docs/errors_matrix.md` — `gen_errors_matrix.py --check` код 0; п. 3: «создать заказ офлайн» → ошибка, SCR-21 остаётся, `checkout_draft` с ключом — integration на Windows (INT-FE, сценарий 3) | журнал 703–704; 1048; §2.1 | *Раунд 2 (исторически):* п. 2 integration «1С-фейк выключен → `submitting` + уведомление» в pos-app **не подтверждён**: сценарий добавлен исправителем, единственный прогон красный, повтор невозможен (F-trace-5). На backend тот же путь подтверждён `pos-smoke` (503 → `submitting` → восстановление). **Обновление (журнал 1205–1328; журнал 1330–1355):** п. 2 integration пройден (`pos_flow_test`: «1С недоступна — заказ submitting, после восстановления — уведомление автору») |
| RM-F-008 Центр уведомлений | закрыта (локально) | п. 1: «КВыполнению» из 1С-фейка → уведомление `order_status` владельцу (`notifications.e2e`); п. 2: бейдж = число непрочитанных (widget); п. 3: «прочитать все» идемпотентно (e2e, в т. ч. с тем же `Idempotency-Key`) | журнал 993; 1025 | Приёмочный набор SCR-44 — 8 из 13 AC-UI (T-UI-044, §2.5) |
| RM-F-009 Тесты этапа F | **частично** | Матрица T-ID: 242 / 200 / 42 / 0, код 0 (§2.5); покрытие строк `cart/orders/payments/…` ≥ 80 % (92,8 % всего); идемпотентность и автомат платежа — 100 % ветвей; деньги — property-тесты и оракул; автоматы D-20/D-21, outbox retry/dead-letter, отказ 1С, QR через 1С и `none`, режим клиента — e2e | журнал 994–999; 1053–1055; §2.1 | **15 not_done — невыполненная работа**: T-CART-004 (P1, CART-005), T-ORD-008, T-SYNC-037 (`payload_hash`), T-TXN-008 (Q-330), T-SYNC-F03/F09/F13 (долг этапа E), T-UI-020…026, T-UI-044. **100 % ветвей** для создания заказа и платежей **нет**, исключения (FIX-F-23) не утверждены. Integration «корзина → заказ → QR → подтверждение» зелёный только до ревью (журнал 696–704). **Обновление (журнал 1205–1328; журнал 1330–1355):** матрица 242 / 211 / 31 / 0, невыполненной работы этапа нет (T-TXN-008 ждёт Q-330; T-SYNC-F03/F09/F13 — долг этапа E, §1.3); ветви критичных файлов 100 % (§2.6), перечень защитных ветвей ждёт владельца 13; integration зелёный после ревью. **Финальный прогон (журнал 1357–1424):** те же 242 / 211 / 31 / 0 и 100 % ветвей; статус «частично» — только из-за неутверждённого перечня `F_branch_exceptions.md` |
| RM-F-010 Сквозная проверка в копии 1С | **не выполнена** | Только на фейке HTTP-сервиса расширения через боевой `OnecExtensionGateway`: шаги 1–3 и 5 — PASS на фейке, шаг 4 — отчёт «не выполнено, блокер для I» (`F_onec_e2e_report.md`) | журнал 1007 (`pos-smoke` 30/30); `F_onec_e2e_report.md` | Копии 1С и API расширения нет. **Для ворот G-F нужно письменное решение заказчика** отложить RM-F-010 до I с принятием риска (§4.1). Решения в репозитории нет |
| RM-F-011 Сборка, проверка, отчёт | **частично** | Путь «каталог → корзина → оформление → заказ в 1С-фейке → QR → подтверждение (из 1С-фейка и вручную со step-up) → PDF» прошёл на Windows (`pos_flow_test` 3 из 3, INT-FE); независимая проверка — 2 раунда; этот отчёт (4 раздела) | журнал 694–706; `F_review.md` | **Android не выполнен** (эмулятор в окружении запрещён, устройства нет). Путь «с клиентом» — после RM-G-001. После исправлений ревью integration пройден на Windows (`pos_flow_test` 4 из 4 и регрессия, журнал 1205–1328; повтор — журнал 1330–1355; финальный прогон после Fix2 — `pos_flow_test` 4 из 4, `catalog_flow_test` 2 из 2, журнал 1357–1424). Ворота G-F не закрыты (§4.1) |
| RM-F-012 Дополнения ядра v1.4 (backend) | закрыта (локально) | п. 1: `PATCH /cart {warehouseId}` пересчитывает `remainingAvailable`; чужая отложенная без права → 404, с правом — успех; `DELETE … ?packagingId=` (`cart-items.e2e`, `cart-flow.e2e`); п. 2: `/check` не ответил → `202 submitting` (таймаут в тестах сокращён до 700–800 мс; по умолчанию `ONEC_SYNC_CHECK_TIMEOUT_MS=6000` в `.env.example`), конфликт → `422 conflicts[]`, в контракте `clientTotalSnapshot` только как удалённое поле; п. 3: QR-платёж в ответе `POST /orders`, «Обновить QR» — тот же `payment_id`, QR в `awaiting_payment`; п. 4: `onec-link` (step-up, 403 под `seller`, аудит `order.onec_linked`, outbox → `sent`), `statusCounts` и `totalEstimate` (`orders-ops.e2e`); п. 5: `void` полученного наличного → `PAYMENT_STATE_INVALID`, `receipt.pdf` до оплаты недоступен, накладная `available:false` (`documents.e2e`) | журнал 993; журнал 1357–1424 | RL-ADMIN для `onec-link` подключён при закрытии остатков (FQ-ORD-13); состав RL-ADMIN совпадает с контрактом (RC-10, `orders-rate-limit.e2e` требует точного совпадения) |
| RM-F-013 Дополнения ядра v1.4 (Flutter) | закрыта (локально) | п. 1: F9 / F8 (`cart_screen_test`); п. 2: «−» на минимуме → `ConfirmDialog`, серия < 500 мс → один `PUT`; п. 3: адрес ≤ 300, кнопки карты нет, `checkout_draft` без ПДн получателя (AC-UI-21-017); п. 5: golden `AppBottomSheet.side` 400 / 480, чипы `statusCounts` SCR-25 | журнал 1025–1026; §2.1 | *Раунд 2 (исторически):* **п. 4 integration не выполнен**: «перезапуск во время ожидания оплаты» и «перезапуск после `POST /orders`» проверены только widget-тестами (F-trace-4); integration-теста перезапуска во время ожидания QR нет. До SCR-38 (этап G) экран проверки статуса — SCR-22 с «Проверить» (уточнение 13 §3.6). **Обновление (журнал 1205–1328; журнал 1330–1355):** п. 4 integration пройден: сценарий «перезапуск во время ожидания QR — ожидание возобновлено, оплата отражена, POST нет» и «ответ POST /orders потерян — один заказ» (`pos_flow_test`) |
| RM-F-014 Вебхук Бакай Банка | **не выполняется — R2** (ядро §24.4) | В R1 маршрута нет: `POST /payments/qr/webhook` → 404 (тест отсутствия, RM-F-003 п. 2) | журнал 993 | Задача R2, ждёт спецификации банка (O-11) и Q-014 |
| RM-F-015 Режим клиента | закрыта (локально), с вопросом Q-329 | п. 1: AC-API-179 (`credit` → 403 `forbidden_role`, ручная скидка → 403, QR при `none` → 422 `payment_method_unavailable`, при `onec` → 201, `allowedPaymentMethods`); п. 2: `created_via=customer` ставит сервер, тело игнорируется; п. 3: widget — нет «Отложить», клиента, скидки, `credit`; п. 4: чужая корзина / заказ → 403/404. Сценарий клиента (`+996777000905`) на Windows | журнал 993; 1025; 700–701 | Заявка клиента без привязки уходит на «Розничного покупателя» по 08 §4.8.1, а 10 CUST-023 требует карточку POS из профиля — расхождение ТЗ, Q-329 (F-money-rules-5, not_fixed). Пометки Q-329 расставлены у AC-CUST-023, 13 RM-F-015, 12 T-CUST-015 (ревью закрытия, RS-1); за заказчика не решено |
| RM-F-016 QR через 1С | закрыта на фейке 1С | п. 1: AC-API-183 (`qr.provider=onec`, `autoConfirm`, перевыпуск — тот же платёж, новый референс, прежний отменяется); п. 2: AC-API-184 (сумма совпала → `received` ≤ 2 опросов; не совпала → `manual_confirm` / `amount_mismatch`; вебхук → 404); п. 3: AC-API-185 (`QR_UNAVAILABLE`, `qr_pending`, ручное подтверждение со step-up); п. 4: `late_payment` после `qr_expired`, отмена QR при смене способа; п. 5: опрос только в `qr_shown`, при `none` обращений к 1С нет (`payments-qr-onec.e2e`) | журнал 993; 1007 | п. 6 (копия 1С) не выполнен. Код `QR_PAID_AFTER_VOID` внесён в CHECK (миграция 0013, ADR-103) и пишется реализацией (F-orders-1c-4 закрыт; `payments-qr-onec.e2e` в `test:all` финального прогона); строки `OTHER` + `payload.code` прежних версий допустимы |

### 1.3. Переносы из этапа E

Источники: `E_catalog_report.md` (§3.1 RC-1, дополнение «RC-1 перенесён в этап F»), `F_spec_questions.md` (агент «TRN»,
FQ-TRN-01…09; INT-FE FQ-INT-F-06, FQ-INT-F-09), `F_spec_sync.md` (раздел TRN).

| Пункт (этап E) | Что сделано на этапе F | Подтверждение | Статус |
|---|---|---|---|
| RC-1 / SS-07 — офлайн-выход без отзыва серверной сессии (`auth.logout`) | Две ступени: `PendingLogoutService` доставляет выход без сессии по записи `pending_logout` в защищённом хранилище (refresh → logout, повтор 30 с…15 мин, до 5 записей, срок 8 дней); запись outbox `auth.logout` (без токенов) обрабатывается при следующем входе владельца (refresh → logout или `DELETE /auth/sessions/{sid}`). Обработчик `auth.logout` терялся при переопределении реестра корзиной — исправлено, реестр корня единый (FQ-INT-F-06). Снекбар UI-41-014 в `SessionGate` | `test/core/session/pending_logout_test.dart`, `session_flow_test.dart`, `test/app/di/outbox_registry_wiring_test.dart` в составе `flutter test` (журнал 1025; §2.1) | **закрыт по коду частично**: интеграционно не проверен. Остаются вопросы: фоновый отзыв своей сессии упирается в step-up (Q-327 — реализовано: step-up из кэша, при `403` — повтор, затем отказ); «Сменить аккаунт» на экране блокировки — только локальный выход (Q-328) |
| EQ-CAT-05 — настройки вида каталога | Вид, сортировка, свёрнутый сайдбар — drift `settings`, ключи `catalog_view_mode.<wc>`, `catalog_sort.*`, `sidebar_collapsed`, `scope=user`; ТЗ уточнено (02 SCR-10, 07 §11.2; FQ-TRN-07) | `test/features/catalog/data/catalog_user_settings_store_test.dart` (журнал 1025; §2.1) | закрыт (локально). Комментарий domain и `SettingsDao.catalogViewKey` не выровнены владельцами (FQ-TRN-07); серверное `Settings.catalogView` не используется |
| FQ-TRN-08 — `q` в фильтрах каталога | `CatalogFiltersScreen(f, q)`, маршрут передаёт `q` (FQ-INT-F-09) | `catalog_filters_query_test.dart`, `catalog_filters_screen_test.dart`, `test/app/router/f_routes_test.dart` | закрыт (локально) |
| EQ-DREST-07 — офлайн-изменение настроек профиля | Онлайн — прямой `PUT /me/settings`, офлайн — outbox `profile.settings`; обработчик в реестре корня | `test/features/settings/data/profile_settings_outbox_test.dart`, `outbox_registry_wiring_test.dart` | закрыт (локально) |
| Долг этапа E в матрице F: T-SYNC-F03 (продолжение полной загрузки с `cursor_to`), T-SYNC-F09 (`BARCODE_CONFLICT`), T-SYNC-F13 (несовместимая `apiVersion` → `paused`) | Не делалось | `trace_test_ids.py --stage F` — not_done «НЕ РЕАЛИЗОВАНО / НЕ ПОКРЫТО (этап E)» | **открыт** |

Другие открытые пункты отчёта E (E-KI-04, E-KI-09, E-KI-12/RC-5, E-KI-14) на этапе F не перепроверялись.

## 2. Выполненные проверки

### 2.0. Финальный прогон этапа F (2026-10-23 23:18 — 2026-10-24 00:01)

Прогон выполнил автор итоговых документов после исправлений второго круга ревью закрытия (Fix2: RC-1, RC-2, RC-5…RC-8,
RS-10 в коде; RS-1…RS-9, RC-3, RC-4, RC-9, RR-1 в ТЗ). Код, ТЗ и контракты этим проходом не менялись.
`TEMP=TMP=D:/optomstroy/.tmp`; на C: 22–23 ГБ свободно (≥ 300 МБ — integration запущены). **На фикстурах, не реальная
интеграция.** Полные выводы — `D:/optomstroy/.tmp/final_f3/*.txt`; сводка — журнал 1357–1424.

| № | Задача / критерий | Команда | Результат | Лог |
|---|---|---|---|---|
| 1 | статическая проверка pos-api | `npm run lint` | код 0 | журнал 1357–1424 |
| 2 | RM-F-001…003, 008, 012, 015, 016; регрессия C–E; RC-5, RC-6, RC-7 | `npm run test:all` (27 наборов) | код 0; **1316 passed, 7 skipped, 0 failed** | там же; `.tmp/final_f3/api_test_all.txt` |
| 3 | RM-F-009 (покрытие, ветви) | `npm run test:cov:f` | код 0; 774 passed, 6 skipped; строки 94,19 %, ветви 83,44 %; **ветви всех 8 критичных файлов — 100 %** | там же; `api_cov_f.txt` |
| 4 | Fix2 backend адресно | `vitest` `notifications.controller.spec.ts` (RC-7); `order-create-branches`, `orders-preview-order` (RC-5, RC-6) | код 0; 18 passed; 18 passed | там же |
| 5 | RM-F-005…008, 013, 015; Fix2 Flutter (RC-1, RC-2, RC-8, RS-10) | `flutter analyze`; `flutter test --concurrency=2`; `cart_variant_change_drift_test.dart` | код 0; No issues; **+1759** (вкл. golden); +2 | там же; `app_test.txt` |
| 6 | RM-F-005 п. 2, 007 п. 2, 011, 013 п. 4, 015, 016 | `flutter test integration_test/pos_flow_test.dart -d windows …` | код 0; **4 из 4** (06:13) | там же; `it_pos_flow.txt` |
| 7 | регрессия каталога после RC-8 | `flutter test integration_test/catalog_flow_test.dart -d windows …` | код 0; 2 из 2 | там же; `it_catalog_flow.txt` |
| 8 | гейты | `check_no_double_money.sh`, `check_secrets`, `check_repo_layout`, `build_openapi --check`, `check_arb_keys`, `sync_contracts --check` | все код 0; `check_secrets` — 2190 файлов, 0 находок; `check_repo_layout` — 0 ошибок, 6 предупреждений | там же |
| 9 | RM-F-009 (T-ID) | `trace_test_ids.py --stage F --summary` | код 0; 242 / 211 (частично 61) / 31 / 0 | там же |

Не повторялись (Fix2 их код не затрагивал; последний зелёный результат — журнал 1205–1328, до Fix2): `test:cov:e`,
`test:cov:d`, `test:e2e:pos`, четыре smoke local-stack, миграции 0001…0013, golden отдельным запуском (входят в
`flutter test`), `flutter build windows --release`, `auth_flow_test`, `admin_invite_flow_test`, `boot_test`.

### 2.1. Свежий прогон для отчёта этапа F (2026-10-23 11:06–11:29)

Прогон выполнил автор отчёта. Код, ТЗ и контракты не менялись. `TEMP=TMP=D:/optomstroy/.tmp`. Свободно на C:
7–28 МБ. Интеграционные тесты Flutter **не запускались: нет места на C:** (< 300 МБ). Полные выводы —
`D:/optomstroy/.tmp/report_f/*.txt`; сводка — журнал 1067–1100.

| № | Задача / критерий | Команда | Результат | Лог |
|---|---|---|---|---|
| 1 | RM-F-009 (покрытие и ветви критичных файлов); RM-F-001…003, 012, 015, 016 | `cd pos-api && npm run test:cov:f` | код 0; **64 файла passed, 2 skipped; 667 passed, 6 skipped, 0 failed**; Statements 88,81 %, Branches 79,98 %, Lines 92,8 %; ветви критичных файлов — те же, что в раунде 2 (§2.6) | журнал 1083–1089; `.tmp/report_f/cov_f.txt` |
| 2 | RM-F-005…008, 013, 015 (widget, unit, golden) | `cd pos-app && flutter test --concurrency=2` | код 0; **+1650: All tests passed** (вкл. golden) | журнал 1090–1091; `.tmp/report_f/flutter_test.txt` |
| 3 | RM-F-010 (фейк), RM-F-011 (процессный путь на фейке 1С) | `cd pos-api && npm run test:e2e:pos` (сборка + pos-api, pos-worker и фейк HTTP-сервиса 1С отдельными процессами) | код 0; 1 файл, 1 тест passed | журнал 1092–1093; `.tmp/report_f/e2e_pos.txt` |
| 4 | RM-F-009 (T-ID) | `python -I -X utf8 scripts/trace_test_ids.py --stage F --summary` | код 0; 242 / 200 (частично 62) / 42 / 0 | журнал 1075–1077 |
| 5 | гейты | `check_secrets.py`, `build_openapi.py --check`, `check_money_vectors.py`, `gen_errors_matrix.py --check`, `check_no_double_money.sh` | все код 0; `check_secrets` — 2181 файл, 0 находок | журнал 1078–1082 |
| — | RM-F-005 п. 2, RM-F-007 п. 2, RM-F-011, RM-F-013 п. 4 | `flutter test integration_test/pos_flow_test.dart -d windows …` | в этом прогоне не запускался (на C: 7–28 МБ); в повторе при свободном месте на C: — **4 из 4, код 0** | журнал 1095; журнал 1205–1328; журнал 1330–1355 |

Результаты совпадают с раундом 2 проверяющего: код после него не менялся.

### 2.2. Последняя независимая перепроверка — раунд 2 (2026-10-23 09:23–10:31)

Код после неё не менялся (изменения раунда 2 исправителей предшествовали перепроверке; журнал 982–984).

| № | Задача / критерий | Команда | Результат | Лог |
|---|---|---|---|---|
| 1 | статическая проверка | pos-api `lint`, `build`, `madge`, `check:permissions` | код 0; 503 файла, циклов нет; 77 кодов прав, 7 ролей | журнал 989–992 |
| 2 | RM-F-001…003, 012, 015, 016; регрессия C–E | `npm run test:all` (27 наборов) | код 0; **1209 passed, 7 skipped, 0 failed** | журнал 993 |
| 3 | RM-F-009 (покрытие) | `npm run test:cov:f` | код 0; 667 passed; строки 92,8 %, ветви 79,98 %; критичные файлы — §2.6 | журнал 994–999 |
| 4 | регрессия порогов D/E | `test:cov:e`, `test:cov:d` | код 0; 496 и 378 passed | журнал 1000–1002 |
| 5 | RM-F-010 (фейк), RM-F-011 | `test:e2e:pos`; `local-stack.mjs smoke / auth-smoke / catalog-smoke / pos-smoke` | код 0; 1 passed; 10/10, 15/15, 22/22, **30/30** (на фикстурах) | журнал 1003–1007 |
| 6 | миграции | `run-sql --repeat-strict` 0001…0012 (prod; dev/test + `check_ddl_behavior`) | код 0; 0 изменений; 63/63 и 64/64 таблиц, 45/45 enum; 62 негативных сценария OK | журнал 1012–1020 |
| 7 | RM-F-005…008, 013, 015 | `flutter analyze`; `flutter test --concurrency=2`; `--tags golden` | код 0; No issues; **+1650**; +220 | журнал 1024–1026 |
| 8 | сборка | `flutter build windows --release` | код 0; собрано | журнал 1027 |
| 9 | гейты репозитория | `check_no_double_money.sh`, `check_secrets`, `build_openapi --check`, `check_api_paths`, `check_enums`, `check_arb_keys`, `check_repo_layout`, `check_env_example`, `check_api_permissions`, `check_enum_triangle`, `check_onec_paths`, `check_money_vectors`, `gen_errors_matrix --check`, `check_layers`, `sync_contracts --check` | все код 0 | журнал 1036–1050 |
| 10 | RM-F-009 (T-ID) | `trace_test_ids.py --stage D / E / F --summary` | код 0; F: 242 / 200 / 42 / 0 | журнал 1051–1055 |

### 2.3. Более ранние прогоны (исторические)

| № | Что | Результат | Лог |
|---|---|---|---|
| 1 | **Интеграция Flutter (INT-FE, 01:29–04:40, до ревью)**: `pos_flow_test` на Windows | код 0, **+3**: продавец (каталог → корзина, скидка 3 % считает сервер → SCR-21 → QR из 1С-фейка → оплата → «Оплачено» → чек PDF 14 581 байт); клиент `+996777000905` (заявка, «Мои заказы»); `QR_PROVIDER=none` (ручное подтверждение со step-up, чек PDF) и офлайн при оформлении | журнал 694–704 |
| 2 | Там же: `catalog_flow_test` +2, `auth_flow_test` +3, `admin_invite_flow_test` +1, `boot_test` +1; release-сборка | код 0 | журнал 705–715 |
| 3 | Раунд 1 проверяющего | `test:all` 1179 passed; `test:cov:e` 1-й прогон — 1 failed (`otp.e2e-spec.ts`, R1-N-01), повтор зелёный; `trace --stage F` — код 1 (152 без теста и причины) | журнал 836–915 |
| 4 | Покрытие до раунда 2 | ветви: order-create 67,41 %, обработчик 1С 53,76 %, payments-port 77,41 %, payments.service 81,02 %, checkout 73,14 % | журнал 781–789 |
| 5 | Промежуточные красные прогоны | `test:e2e:pos` (фильтр строк), `check_no_double_money` и `check_secrets` (код Flutter checkout), `test:payments`, `test:db` (выгрузка схемы), `test:cov:f` (нестабильный тест D; разбор PDF) — все исправлены, причины в журнале | журнал 467–479, 626–650, 745–758, 778–780, 974 |

Покрытие Flutter (`flutter test --coverage`) на этапе F не измерялось.

### 2.4. Не выполненные проверки

Такие проверки не считаются пройденными.

| Задача / критерий | Команда / проверка | Причина | Когда и кем будет выполнена |
|---|---|---|---|
| RM-F-010 пп. 1–3, 5; RM-F-016 п. 6 | сквозной заказ и QR на тестовой копии УТ 11.5 (`F_onec_e2e_report.md` §3) | **копии 1С и API расширения нет** (RM-A-006, RM-E-016) | ONEC + 1С-специалист после передачи API и копии; до I. Для G-F — письменное решение заказчика |
| ~~RM-F-005 п. 2, RM-F-007 п. 2, RM-F-013 п. 4; F-trace-4/5~~ | `flutter test integration_test/pos_flow_test.dart -d windows` с новыми сценариями | **выполнено** в повторе при свободном месте на C: — 4 из 4, код 0 (журнал 1205–1328; журнал 1330–1355) | — |
| ~~Регрессия integration~~ | `catalog_flow_test`, `auth_flow_test`, `admin_invite_flow_test`, `boot_test` после исправлений ревью | **выполнено** в повторе: 2 + 3 + 1 + 1 passed, код 0 (журнал 1205–1328) | — |
| RM-F-011 (Android), iOS | integration на Android; сборка iOS | эмулятор в окружении запускать запрещено, устройства нет; macOS/Xcode нет (Q-008) | QA с устройством (RM-A-008), этап H |
| Печать (RM-F-004, PRINT-*) | печать на термопринтер 80 мм и A4 | принтеров нет (RM-A-009); проверен только PDF и предпросмотр | QA при получении принтеров |
| RM-F-006, RM-F-011 «с клиентом»; T-ORD-001/003, T-UI-026 | выбор и создание клиента в SCR-21/SCR-26 на стенде | `GET/POST /customers` — этап G (RM-G-001); сида клиентов в `local-stack` нет | этап G |
| CART-005, T-CART-004 (P1) | widget + integration смены варианта строки | **закрыто при закрытии остатков**: widget-тест `cart_variant_change_test.dart` и тесты на drift (RC-1, RC-2) в `flutter test` (журнал 1159; 1357–1424). Отдельного integration-сценария смены варианта в `pos_flow_test` нет | FE (по желанию — сценарий в `pos_flow_test`) |
| RM-F-009 (100 % ветвей) | `npm run test:cov:f` с порогом 100 % для критичных файлов | **100 % достигнуто** (журнал 1205–1328 и 1357–1424); не выполнено только утверждение перечня защитных ветвей `F_branch_exceptions.md` (E-1…E-3, FIX-F-23) | владелец 13 |
| Docker / CI | сборка образов с `assets/`, `compose.test.yml` с `ONEC_MODE=fixtures`, job CI | Docker не установлен; коммитов и push нет | OPS после разрешения на Docker; после первого коммита |
| Покрытие Flutter | `flutter test --coverage` | не измерялось на этапе F | QA |

### 2.5. Матрица T-ID этапа F (RM-F-009)

Команда: `python -I -X utf8 scripts/trace_test_ids.py --stage F --summary` — код 0. Последний прогон — после закрытия
остатков F (журнал 1186–1188). Статическая трасса при ревью закрытия F (2026-10-23, после этого прогона, код 0):
242 / **211** / **31** / 0 — T-UI-026 получил тест `pos-app/test/features/customers/presentation/new_customer_screen_test.dart`
(«AC-UI-26-008, T-UI-026 …»); подтверждено повтором при свободном месте на C: (журнал 1205–1328: `flutter test` +1749,
`trace_test_ids --stage F` — 211 / 31, код 0) и журнал 1330–1355.

| Показатель | Раунд 2 (журнал 1053–1055) | После закрытия остатков (журнал 1186–1188) |
|---|---|---|
| ID в охвате | 242 | 242 |
| С тестом | 200 (T-ID в тесте 145, трасса «файл::тест» 55; из них частично 62) | **210** (T-ID в тесте 155, трасса 55; из них частично 61) |
| not_done с причиной | 42 | **32** |
| Без теста и причины | 0 | 0 |

После закрытия остатков (журнал 1193–1195): среди 32 not_done невыполненная работа этапа — **одна**, T-UI-026 (P1,
AC-UI 11/12; в тестах нет AC-UI-26-008); T-CART-004, T-ORD-008, T-SYNC-037, T-UI-020…025 и T-UI-044 теперь с тестами.
Остальные not_done — перенос с обоснованием (этапы G/H, R2, L3 на копии 1С, ручные проверки без принтеров, Q-019,
Q-330 — T-TXN-008).

Разбор 42 not_done раунда 2 (исторический; журнал 1057–1061):
- **27 — перенос с обоснованием**: этапы G/H с задачей 13, R2, L3 на копии 1С, ручные проверки без принтеров,
  решение заказчика Q-019, скан вместо теста, класс B T-SEC-068;
- **15 — невыполненная работа этапа F**:
  - T-CART-004 (P1) — CART-005 в pos-app не реализован;
  - T-ORD-008 — нет widget-теста чекбоксов печати;
  - T-SYNC-037 — `payload_hash` не сверяется при отправке (07 DATA-228 задаёт исход, код `HASH_MISMATCH` есть в CHECK;
    по R2-N-02 решения не требуется);
  - T-TXN-008 — ждёт Q-330;
  - T-SYNC-F03, F09, F13 — долг этапа E;
  - T-UI-020…026, T-UI-044 — приёмочные наборы AC-UI неполны: SCR-20 17/30, SCR-21 13/27, SCR-22 8/14, SCR-23 6/13,
    SCR-24 15/17, SCR-25 9/12, SCR-26 7/12, SCR-44 8/13. Причина в скрипте — «исправитель Flutter», а не перенос.

Код 0 матрицы **не означает**, что RM-F-009 выполнен (R2-N-03).

### 2.6. Покрытие ветвей критичных сценариев (RM-F-009)

| Файл | Ветви, раунд 1 | Ветви, раунд 2 | После закрытия остатков (журнал 1129–1135) | Требование 13 |
|---|---|---|---|---|
| `sales-domain/idempotency` | 100 % (12/12) | 100 % | 100 % | 100 % — выполнено |
| `sales-domain/payment/payment-status.ts` | 100 % (67/67) | 100 % | 100 % | 100 % — выполнено |
| `orders/order-create.service.ts` | 67,41 % | 88,70 % (275/310) | **100 %** (310/310) | 100 % — выполнено |
| `orders/worker/order-onec-results.handler.ts` | 53,76 % | 91,39 % (85/93) | **97,75 %** (87/89); в повторе (журнал 1205–1328) — **100 %** (89/89) | 100 % — выполнено (защитные ветви E-2, E-3 покрыты тестами с подменой) |
| `payments/…/payments-port.service.ts` | 77,41 % | 91,93 % (57/62) | **100 %** (62/62) | 100 % — выполнено |
| `payments/app/payments.service.ts` | 81,02 % | 84,10 % (164/195) | **99,47 %** (190/191); в повторе (журнал 1205–1328) — **100 %** (191/191) | 100 % — выполнено (защитная ветвь E-1 покрыта тестом с подменой) |
| `cart/checkout.service.ts` | 73,14 % | 78,09 % (189/242) | **100 %** (237/237) | 100 % — выполнено |

Финальный прогон (журнал 1357–1424) подтвердил 100 % во всех файлах таблицы, а также `idempotency.interceptor` (48/48).
Защитные ветви — построчный перечень `docs/stages/F_branch_exceptions.md` (E-1 — недостижимая защитная, E-2 —
инвариант проекции, E-3 — гонка); перечень владельцем 13 **не утверждён** (FIX-F-23). Пороги `vitest.config.cov-f.ts`
подняты до измеренных значений («храповик»).

### 2.7. RM-F-010 — «не выполнено, блокер для I»

Источник — `docs/stages/F_onec_e2e_report.md`. На фейке HTTP-сервиса расширения через боевой `OnecExtensionGateway` и
`pos-worker`: документ хранится под `externalId = orders.id`; повтор не создаёт дубль; «КВыполнению» → `awaiting_shipment`;
QR через 1С → `received` на 2-м опросе. **Это модель требований 05, а не проверка 1С**: реквизиты УТ 11.5,
проведение, автоскидки, настоящие статусы и банк QR не проверены. Скриншотов и идентификаторов документов 1С нет и быть
не может.

## 3. Известные проблемы

### 3.1. Дефекты и пробелы

Серьёзность — по 13 §6.2 (ревью: исходная оценка; в скобках — оценка скептиков, если ниже).

| ID | Описание | Серьёзность | Статус / обход | План (задача, срок) |
|---|---|---|---|---|
| F-KI-01 (RM-F-010) | Сквозная проверка заказа на копии 1С не выполнена; письменного решения заказчика отложить её до I нет | **блокер G-F** (по 13 §3.6) | открыт | заказчик: копия и API 1С или письменное решение (§4.2) |
| F-KI-02 (R2-N-01, F-trace-1) | 10 CART-005 (must): смена варианта в строке корзины (SCR-15 в режиме смены, «Заменить вариант», «Объединить количества?») | существенная (major, скептиками не проверялось) | **закрыт** при закрытии остатков: реализовано, T-CART-004 — `pos-app/test/features/cart/presentation/cart_variant_change_test.dart` (`flutter test` +1721, журнал 1159; трасса `--stage F`) | integration-сценарий — вместе с F-KI-04 |
| F-KI-03 (F-trace-2) | 100 % ветвей: в повторе (журнал 1205–1328) все критичные файлы — 100 %, включая `payments.service` (191/191) и обработчик результатов 1С (89/89); после закрытия остатков было `payments.service` 99,47 %, обработчик результатов 1С 97,75 % (§2.6) | существенная | частично: покрытие ветвей 100 % (журнал 1205–1328); перечень защитных ветвей `F_branch_exceptions.md` (E-1…E-3) владельцем 13 не утверждён; пороги подняты | владелец 13 — утвердить или отклонить исключения FIX-F-23 |
| F-KI-04 (F-trace-4, F-trace-5) | Integration по RM-F-013 п. 4, RM-F-005 п. 2, RM-F-007 п. 2 (новые сценарии `pos_flow_test`, включая перезапуск во время ожидания QR) | существенная | **закрыт**: `pos_flow_test` 4 из 4 на Windows (журнал 1205–1328; повтор — журнал 1330–1355); регрессия `catalog_flow_test`, `auth_flow_test`, `admin_invite_flow_test`, `boot_test` зелёная | — |
| F-KI-05 (R2-N-02) | `payload_hash` при отправке outbox сверяется (07 DATA-228): несовпадение → `dead` + `sync_errors (HASH_MISMATCH)`, в 1С не отправляется | незначительная (minor) | **закрыт** при закрытии остатков: `pos-api/src/jobs/outbox/outbox-dispatcher.ts`; T-SYNC-037 — `pos-api/test/worker/worker.int.spec.ts` (повтор 2026-10-23 16:00 — 1 passed) | — |
| F-KI-06 (F-money-rules-5) | Заявка клиента без привязки — на «Розничного покупателя» (по 08 §4.8.1), а 10 CUST-023 требует карточку POS из профиля | существенная (скептики: minor; один опроверг) | not_fixed; реализовано по 08 | решение заказчика Q-329 |
| F-KI-07 (F-orders-1c-4) | `QR_PAID_AFTER_VOID` в CHECK 07 (миграция 0013) и пишется реализацией; строки `OTHER` + `payload.code` прежних версий допустимы | незначительная | **закрыт** при закрытии остатков (ADR-103; 08 §16.12) | — |
| F-KI-08 (F-trace-11) | `503 catalog_not_loaded` у `GET /cart` | незначительная | **закрыт**: 08 §4.7.1 и OpenAPI 1.2.0 (ADR-103) | — |
| F-KI-09 (F-flutter-ui-12) | Накладная на SCR-22/24 всегда «Печатается из 1С при отгрузке»; 02 UI-22-008 и 08/10 расходятся | незначительная | not_fixed | Q-019, FIX-FE-03 |
| F-KI-10 (F-flutter-ui-19) | ICU plural не использовался («1 позиций») | незначительная | **закрыт** при закрытии остатков: четыре ключа корзины переведены на `{count, plural, …}` в 02 §7 и `contracts/l10n` (ADR-103); `check_arb_keys`, `sync_contracts --check`, `flutter test` — код 0 | — |
| F-KI-11 (F-trace-15) | Имя выхода RM-F-009 в 13 — `checkout_flow_test.dart`, файл — `pos_flow_test.dart` | незначительная | not_fixed (уточнение записано в 13 §3.6, строка критерия не менялась) | владелец 13 (FIX-F-15) |
| F-KI-12 (F-flutter-ui-14, -15) | Отступы 5/6 lp и литералы `SizedBox`; SCR-22 — непрозрачный маршрут | незначительная | частично | владельцы 03 (FIX-FE-05) и `navigation.md` (FIX-FE-04) |
| F-KI-13 (F-money-rules-9) | «preview ≡ order» и политика одобрения скидки — только e2e, не property-тесты | незначительная | **закрыт с оговоркой**: «preview ≡ order» — property-тест на реальной корзине и `POST /orders` (60 прогонов, seed фиксирован, RC-6); одобрение сверх лимита — примерами и e2e. Ночной job CI со случайным seed не добавлен (CI не запускался) | QA — ночной job после первого запуска CI |
| F-KI-14 (F-trace-7) | Приёмочные наборы T-UI: T-UI-020…026 и T-UI-044 с тестами; T-UI-026 — `new_customer_screen_test.dart` (AC-UI-26-008), подтверждён `flutter test` (журнал 1205–1328; журнал 1330–1355) | существенная (скептики: minor; полнота — этап H) | **закрыт** (T-UI-026 с тестом) | — |
| F-KI-15 (F-trace-14) | Путь «с клиентом» на стенде: сида клиентов нет (T-UI-026 теперь с widget-тестом, журнал 1205–1328) | незначительная | частично | этап G (RM-G-001) |
| F-KI-16 (R1-N-01) | Нестабильный `test/e2e/auth/otp.e2e-spec.ts` (этап D): один раз 500 вместо 202 | незначительная | в раунде 2 и §2.1 не повторился; причина не установлена | владелец auth |
| F-KI-17 | Отложенный выход (RC-1) проверен только unit/widget; восстановление неизвестного исхода `POST /orders` — integration пройден (`pos_flow_test`: «ответ POST /orders потерян — один заказ», журнал 1205–1328) | незначительная | частично | integration-сценарий отложенного выхода — QA |
| F-KI-18 | Окружение: на C: 7–39 МБ свободно; прогон `catalog_flow_test` уже падал с `database or disk is full` (журнал 679–682) | существенная (для проверок) | **снят**: в прогонах 23.10 21:48 — 24.10 00:01 на C: 22–23 ГБ, `integration_test` пройдены (журнал 1205–1328, 1357–1424); при новом заполнении C: (< 300 МБ) — снова блокирует integration | владелец машины (§4.2) |
| F-KI-19 (RC-8) | Отказ сервера `max_items` (201-я строка): строка из копии удаляется, каталог показывает отказ, но для «В корзину» SCR-14, скана и повтора заказа снекбар виден только при открытой корзине | незначительная | частично (Fix2): глобальный слушатель `CartNotice.maxItems` не сделан — он создавал бы контроллер корзины до входа | FE, отдельное решение |
| F-KI-20 | 13 §3.6 (уточнение к RM-F-009) приводит проценты ветвей до закрытия остатков (88,7 % и т. д.), а критерий RM-F-009 называет выход `checkout_flow_test.dart` (F-trace-15) | незначительная | открыт (`F_review.md` ZO-N-01) | владелец 13 |
| F-KI-21 (FQ-FEORD-12) | `Payment.transactionId` (необязательное поле OpenAPI 1.2.0) сервер не отдаёт; переход из строки платежа SCR-24 в SCR-37 (UI-24-008) — вместе с SCR-37 (`createdAt`/`createdBy` шапки заказа pos-app уже читает из `audit`, FQ-FEORD-02) | незначительная | открыт, перенесён по плану | BE + FE, этап G вместе с SCR-37 |

Исправлено на этапе F по ревью (подтверждено тестами, §5.1): все 7 critical — `previewToken`
(F-money-rules-1), одобрение скидки (F-money-rules-2), повтор отклонённого заказа (F-orders-1c-1), «деньги получены —
отклонён 1С» (F-orders-1c-2), потеря `dead`-строк (F-flutter-data-1), ключ `checkout_draft` (F-flutter-data-2),
неизвестный исход `POST /orders` (F-flutter-ui-1). Найден и исправлен дефект backend вне ревью: у `pg.Pool` не было
слушателя `error`, разрыв соединения БД ронял API/worker (R2-N-04, T-FAIL-012).

### 3.2. Действующие допущения

До ответа заказчика действует значение из столбца «Допущение» 14 — оно же реализовано.

| Q-NNN | Принятое допущение | Какие задачи от него зависят | Последствие при другом ответе |
|---|---|---|---|
| Q-010, Q-012 | Имена объектов и статусы УТ `[ТИПОВО]`; «Заказ клиента» в статусе «Не согласован» | RM-F-002, 010, 015 | правка маппинга outbox и проекции статусов |
| Q-014 | QR через 1С (`QR_PROVIDER=onec`), запасной `none`; срок и отмена QR — по 05 §6.7.3 | RM-F-016 | при отказе 1С — только `none` (без изменения кода) |
| Q-015 | Предел подтверждающего — `approve_max_percent ?? max_percent` | RM-F-001 | правка настроек `role_discount_limits` |
| Q-016 | `cash_rounding=to_som` не применяется | RM-F-001, 003 | expand-миграция дельты округления |
| Q-019 | Накладная только из 1С; реквизиты организации — ключ `print.organization` без seed | RM-F-004 | шаблоны JSON |
| Q-026 | `customer.ref = null` для «Розничного покупателя» | RM-F-002 | ввод `Ref_Key` |
| Q-325…Q-330 | см. §3.3 | — | — |

### 3.3. Новые вопросы заказчику (14 v1.7: Q-325…Q-330)

Полный текст — `14_OPEN_QUESTIONS.md` (§3.1, §3.6, §7 «7б», §8). Реестр 226 → 232; Q-297 не использован.

| Q | Тема | Вопрос (кратко) | Действует до ответа | Кто отвечает |
|---|---|---|---|---|
| Q-325 | бизнес | QR со ссылкой на заказ на товарном чеке | не печатается; номер — текстом | владелец магазина |
| Q-326 | бизнес | Как показывать в журнале аннулирование неполученного платежа | строка `payment_voided` с `−amount` | бухгалтер + владелец |
| Q-327 | безопасность | Step-up при фоновом отзыве своей сессии на том же устройстве | step-up требуется (из кэша, без диалога) | владелец + SEC |
| Q-328 | безопасность | «Сменить аккаунт» на экране блокировки без отзыва серверной сессии | только локальный выход | владелец + SEC |
| Q-329 | бизнес | Карточка заявки клиента без привязки: «Розничный» (08) или карточка POS (10 CUST-023) | «Розничный покупатель» с получателем-клиентом | владелец + 1С-специалист |
| Q-330 | бизнес | Отражение уточнённого 1С итога в журнале | оба итога в заказе, журнал не меняется | бухгалтер + владелец |

Дополнения к существующим вопросам — 14 §3.12 (Q-005, Q-012, Q-014, Q-015, Q-016, Q-019, Q-021, Q-026, Q-028, Q-176,
Q-263, Q-264).

## 4. Условия перехода дальше

### 4.1. Статус ворот G-F — **красный, ворота не закрываются**

| Условие G-F (13 §3.6) | Выполнено? | Доказательство |
|---|---|---|
| RM-F-001…003, 008, 012, 015, 016 закрыты | да (локально, на фейке 1С) | §1.2; §2.2 № 2, 5 |
| RM-F-004 закрыт | да, с уточнением 13 (свой разборщик PDF) | §1.2 |
| RM-F-005, 006, 007, 013 закрыты | RM-F-005, 007, 013 — да (локально, на фейке 1С); RM-F-006 — **частично** | integration п. 2 / п. 2 / п. 4 пройдены (F-KI-04 закрыт, журнал 1205–1328); CART-005 реализован (F-KI-02 закрыт); выбор клиента в RM-F-006 — этап G |
| RM-F-009 закрыт | **частично** | финальный прогон (журнал 1357–1424): 242 / 211 / 31 / 0, ветви всех критичных файлов 100 %; не утверждён владельцем 13 только перечень защитных ветвей `F_branch_exceptions.md`. В повторе: невыполненной работы среди not_done нет (T-UI-026 с тестом), ветви критичных файлов 100 % (§2.5, §2.6). Прежде: 1 not_done — невыполненная работа (T-UI-026, §2.5); 3 ветви двух файлов < 100 %, исключения не утверждены (§2.6) |
| RM-F-014 — R2, в R1 не выполняется | да | ядро §24.4 |
| RM-F-010 выполнен на копии 1С **или** письменно отложен заказчиком до I | **нет** | §2.7; решения заказчика в репозитории нет |
| RM-F-011 — отчёт | да (этот документ); Android не выполнен | §1.2; финальный прогон §2.0 |
| 0 блокеров | **нет** | F-KI-01 (RM-F-010) — блокер G-F до решения заказчика |

Обоснование по 13 §6.2:
- открыт блокер ворот F-KI-01 — без письменного решения заказчика G-F не закрываются, даже если всё остальное будет
  выполнено;
- открыты существенные F-KI-03 (перечень защитных ветвей ждёт решения владельца 13; покрытие 100 %) (F-KI-18 снят на момент повтора:
  на C: 23 ГБ); F-KI-02 (CART-005) и F-KI-05 закрыты при закрытии остатков, F-KI-04 (integration) и
  F-KI-14 (T-UI-026) — повтором при свободном месте на C: (журнал 1205–1328);
- решения владельцев ТЗ по FIX-F-* / FIX-FE-* и ответы заказчика на Q-325…Q-330 (в т. ч. Q-329 — CUST-023) не
  получены; от них может измениться код;
- по коду открыты только незначительные: F-KI-12 (FIX-FE-04/05), F-KI-15 (этап G), F-KI-19 (RC-8), F-KI-21 (этап G).

Все проверки финального прогона (§2.0) зелёные, но **это не закрывает ворота**: G-F остаются красными до письменного
решения заказчика по RM-F-010 и решения владельца 13 по `F_branch_exceptions.md`.

Чтобы закрыть G-F, нужно:
1. письменное решение заказчика по RM-F-010 (или копия 1С и выполненная проверка);
2. ~~закрыть T-UI-026 (AC-UI-26-008)~~ — выполнено (журнал 1205–1328); CART-005/T-CART-004, T-ORD-008, T-SYNC-037,
   T-UI-020…025/044 закрыты при закрытии остатков (§2.5);
3. решение владельца 13 по исключениям `F_branch_exceptions.md` (E-1…E-3, FIX-F-23) — остальные критичные файлы 100 %;
4. ~~освободить на C: ≥ 300 МБ, дописать integration-тест перезапуска во время ожидания QR и получить зелёные
   `pos_flow_test` (с новыми сценариями), `catalog_flow_test`, `auth_flow_test`, `admin_invite_flow_test`, `boot_test`~~ —
   выполнено (журнал 1205–1328; повтор `pos_flow_test` — журнал 1330–1355).

### 4.2. Что требуется от заказчика

| Действие / вопрос | Для какой задачи | Срок (ворота) |
|---|---|---|
| **Письменное решение**: отложить RM-F-010 до этапа I с принятием риска (расхождения с настоящей 1С — реквизиты документа, статусы, автоскидки, QR — обнаружатся только на копии перед пилотом) **или** предоставить копию 1С | RM-F-010, ворота G-F | **до G-F** |
| Специалист 1С передаёт API — расширение по `18_ONEC_API_REQUEST.md` (включая методы QR 05 §6.7) — и тестовую копию УТ 11.5 (O-05, RM-A-006); учётные данные — через секрет-хранилище | RM-E-016, RM-F-010, RM-F-016 п. 6 | до I (без них пилот невозможен) |
| Ответы на Q-325…Q-330; в первую очередь Q-329 (реализация расходится с 10 CUST-023) | §3.3 | Q-326, Q-327…Q-330 — до G; Q-325 — до I |
| Ответы на существующие вопросы с дополнениями 14 §3.12, особенно Q-016 (округление), Q-019 (печатные формы и реквизиты), Q-015 (лимиты скидок), Q-014 (QR через 1С) | RM-F-001, 003, 004, 016 | до G-F / до I |
| Место на диске C: машины разработки — **сейчас достаточно**: в прогонах 23.10 21:48 — 24.10 00:01 на C: 22–23 ГБ, `integration_test` пройдены (журнал 1205–1328, 1330–1355, 1357–1424). Прежде было 7–39 МБ при нужных ≥ 300 МБ. Действие: держать на C: не меньше 300 МБ свободными (БД приложения и сборка Flutter пишут на C:); если место снова закончится — освободить его (данные на C: принадлежат пользователю, команда их не удаляет) | integration_test Flutter (RM-F-005, 007, 011, 013) | постоянно, до G-F и далее |
| Принтеры (термо 80 мм и A4) для ручной проверки печати (RM-A-009); Android-устройство (RM-A-008) | RM-F-004, RM-F-011 | до этапа H |
| Разрешение на Docker на машине разработки | сборка образов с `assets/`, тестовый контур | до этапа H |

Действия команды (не заказчика). Сделано при закрытии остатков: CART-005 / T-CART-004, T-ORD-008, integration-тест
перезапуска во время ожидания QR, приёмочные наборы T-UI (T-UI-026), 100 % ветвей, `payload_hash` (DATA-228), RL-ADMIN
для `onec-link` и полный состав RL-ADMIN, OpenAPI 1.2.0 и ключи ARB 03 §16.8. Остаётся:
- FE: глобальный показ отказа `max_items` для SCR-14, скана и повтора заказа (RC-8, F-KI-19);
- BE + FE: `Payment.transactionId` вместе с SCR-37 (этап G, F-KI-21); сид клиентов для `local-stack` — с RM-G-001;
- QA + OPS: ночной job CI со случайным seed property-теста (`ORDERS_PROPERTY_SEED=random`) — после первого запуска CI;
  сборка образов с `assets/` — после разрешения на Docker (FQ-INT-09);
- владелец 13: утвердить или отклонить `F_branch_exceptions.md` (FIX-F-23); обновить уточнение 13 §3.6 (проценты
  ветвей) и имя выхода RM-F-009 (FIX-F-15, F-KI-20);
- владельцы ТЗ: FIX-F-21 (T-TXN-008, после Q-330); FIX-FE-03 (после Q-019), FIX-FE-04, FIX-FE-05; FIX-F-02, 12, 18,
  19, 22 этим проходом не перепроверялись. FIX-F-03, 06, 07, 16, 20 закрыты при закрытии остатков (ADR-103, DATA-228);
- владелец 02 §7: тексты ключей `error_validation_failed`, `error_client`, `error_outcome_unknown`,
  `warning_stale_data` и смысл `{units}` в `cart_fab_a11y` (03 §16.8 текста не задаёт); владелец 08 — ключи
  `Notification.payload` `customerId`, `returnId`, `productId`, `variantId` (в 08 не описаны как отдаваемые сервером).

### 4.3. Что не сделано и почему (итог этапа)

| Что | Почему | Кто и когда |
|---|---|---|
| RM-F-010 — сквозной заказ и QR на копии 1С | копии УТ 11.5 и API расширения нет; письменного решения заказчика отложить до I нет | заказчик (решение) и 1С-специалист (API, копия); до G-F — решение |
| Утверждение исключений ветвей (FIX-F-23) | решение владельца 13; сами ветви покрыты тестами | владелец 13 |
| Ответы Q-325…Q-330 | вопросы заказчику; реализованы допущения 14, за заказчика не решались | заказчик |
| T-TXN-008 / FIX-F-21 | ждёт Q-330 | владелец 10 после ответа |
| Android, iOS | эмулятор запускать запрещено, устройства и macOS нет | QA, этап H |
| Печать на принтер | принтеров нет (RM-A-009) | QA |
| Путь «с клиентом» на стенде (SCR-21, SCR-26) | `GET/POST /customers` — этап G | этап G (RM-G-001) |
| RC-8 полностью | нужен отдельный дизайн глобального слушателя | FE |
| `Payment.transactionId` | перенесён вместе с SCR-37 | этап G |
| Docker, CI | Docker не установлен; коммитов нет, CI не запускался | OPS |
| Долг этапа E: T-SYNC-F03, F09, F13 | вне объёма F (backend этапа E) | владелец этапа E |
| В финальном прогоне не повторены `test:cov:e/d`, `test:e2e:pos`, smoke, миграции, сборка Windows, `auth_flow_test`, `admin_invite_flow_test`, `boot_test` | короткий прогон: Fix2 их код не затрагивал; последний зелёный результат — журнал 1205–1328 | — |

### 4.4. Решения, принятые на этапе

ADR, добавленные в `docs/specification/15_DECISION_LOG.md` (приложение Е) при синхронизации ТЗ, статус «Принято
(реализовано на этапе F)»:
- ADR-098 — печатные формы: pdfkit и JSON-шаблоны, детерминированный PDF без хранения, версия — `orders.row_version`, RL-PDF;
- ADR-099 — платежи: номер платежа, ключ начального платежа, `qr_issued_at`, `qr_ref_history`, срок и отмена QR через
  1С, long-polling с пределами;
- ADR-100 — корзина и создание заказа: `/check` 1С в модуле `cart`, необязательный `previewToken`, `PRICE_CHANGED` с
  причиной, `503 catalog_not_loaded`;
- ADR-101 — `pos-worker` как контекст Nest без HTTP, очереди этапа F, ручная привязка через `external-ids`;
- ADR-102 — Flutter: порты presentation, единый реестр outbox в корне, drift v5, `cart.sync` только `mode=set`,
  отложенный выход в две ступени.

## 5. Приложения

### 5.1. Независимая проверка — `docs/reviews/F_review.md`

Проверяющий — отдельный агент, не автор кода. Дата: 2026-10-23. Направления: fresh-run, money-rules, orders-1c,
security, flutter-ui, flutter-data, trace; на каждое серьёзное замечание — два скептика.

| Показатель | Число |
|---|---|
| Подтверждено замечаний | 60 (7 critical по исходной оценке) |
| Опровергнуто | 2 (F-flutter-ui-5 — приостановку ожидания выполняет `AuthInterceptor`; F-trace-10 — статус ворот, а не дефект) |
| Раунд 1: fixed / partially_fixed / not_fixed | 45 / 10 / 5 |
| Раунд 2: fixed / partially_fixed / not_fixed | 45 / 11 / 4 (изменился только F-trace-14: not_fixed → partially_fixed) |
| **После закрытия остатков** (`F_review.md` ЗО.3): fixed / partially_fixed / not_fixed | **53 / 4 / 3** |
| Осталось partially_fixed | F-flutter-ui-14 (FIX-FE-05), F-flutter-ui-15 (FIX-FE-04), F-trace-2 (исключения не утверждены), F-trace-14 (этап G) |
| Осталось not_fixed (все ждут решения заказчика или владельца ТЗ) | F-money-rules-5 (Q-329), F-flutter-ui-12 (Q-019, FIX-FE-03), F-trace-15 (FIX-F-15) |
| Ревью закрытия, круг 1 (контракты и ТЗ: RS-1…RS-10, RC-5, RC-10, RR-3) | исправлено; сверка — 47 проверок, 0 провалов (`F_spec_sync.md` §5.4–§5.5) |
| Ревью закрытия, круг 2 (`F_review.md` ЗО.2) | 20 подтверждённых: 1 major (RS-1; при исправлении признано minor), 19 minor; fixed 19, partially_fixed 1 (RC-8) |
| Новые наблюдения (скептиками не проверялись) | R1-N-01…03; R2-N-01 (major, CART-005), R2-N-02 (minor, `payload_hash`), R2-N-03 (minor, код 0 матрицы на причинах «исправитель Flutter»), R2-N-04 (info, исправленный дефект `pg.Pool`) |

Остались серьёзными после раунда 2 (major): F-trace-1 (CART-005 / T-CART-004 и другие невыполненные not_done),
F-trace-2 (ветви < 100 %), F-trace-4 (нет integration перезапуска во время ожидания оплаты). F-trace-5 упирается в
окружение. Вывод проверяющего (`F_review.md` R2.6): **ворота G-F не закрываются**.
После закрытия остатков F-trace-1, F-trace-4, F-trace-5 закрыты; у F-trace-2 ветви 100 %, остался только
неутверждённый перечень исключений. Вывод `F_review.md` ЗО.5 тот же: **ворота G-F не закрываются** (RM-F-010).
Раздел «Закрытие остатков» в `F_review.md` написал автор итоговых документов, а не независимый проверяющий.

Оговорка: для замечаний, код которых после раунда 1 не менялся, статус раунда 2 подтверждён только тем, что их тесты
зелёные в свежем прогоне. То, что новые тесты падали бы без исправлений, — слова исправителей; проверяющий это не
перепроверял.

### 5.2. Синхронизация ТЗ — `docs/stages/F_spec_sync.md`

| Показатель | Значение |
|---|---|
| Разобрано пунктов `F_spec_questions.md` | 201 (номера FQ-CART-01…15 агентов F-be-cart и F-fe-cart различены пометками «(be)» / «(fe)») |
| Классы | A — 112, A+B — 2, A+B\* — 15, A+C — 12, B — 5, B\* — 2, C — 53 |
| Внесено в ТЗ | 141 |
| С вопросом заказчику (новым или существующим) | 24 |
| Решено / бэклог | 65 (бэклог реализации — 21 строка, `F_spec_sync.md` §3) |
| Новые Q-ID | Q-325…Q-330 (реестр 226 → 232) |
| ADR | ADR-098…ADR-102 |

- Изменены: 02 (1.11), 03 (1.2), 05 (1.2), 06 (1.3), 07 (1.10), 08 (1.14), 10 (§27, только пометки
  `[ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА]` у CUST-023, PRINT-005, TXN-008), 11 (1.2), 12 (1.5), 13 (2.2), 14 (1.7), 15 (1.10),
  16 (1.11), `navigation.md` (1.9), README (1.5), 00 (1.7).
- Не менялись: ядро, бизнес-правила, 01, 04, 09, 17, 18, `resursi/`, **машинные контракты** (`contracts/**`).
- 13 RM-F-009 «100 % веток» **не снижен**: записаны измеренные уровни и «храповик».
- Не внесены при синхронизации: ключи ARB этапа F (03 §16.8 → 02 §7 / `contracts/l10n`), предложения MINOR к OpenAPI
  (08 §16.11). **Внесены при закрытии остатков** (`F_spec_sync.md` §5): OpenAPI и `enums.json` 1.2.0, ADR-103, 26
  ключей ARB (2024 всего), ICU plural; затем — правки ТЗ по двум кругам ревью закрытия (08 v1.17, 07 v1.13, 04 v1.7,
  03 v1.4, 13 v2.3, 14 v1.8 и др.). Ядро и бизнес-правила не менялись (в 10 — только пометки и уточнения критериев).
- Гейты после синхронизации — все `check_*`, `build_*`/`sync_contracts`/`gen_rbac_seed --check`, `trace_test_ids` —
  код 0 (`F_spec_sync.md` §2; первый прогон `check_onec_paths` был красным и исправлен формулировкой 05/08).
  e2e pos-api и тесты Flutter после синхронизации не запускались (код не менялся, нет места на C:); после закрытия
  остатков — запускались (журнал 1205–1328, 1357–1424). Повторной независимой проверки синхронизации нет.

### 5.3. Состояние окружения

- Windows 11 Pro 10.0.26200; Node 24.11.1; Flutter 3.38.7 / Dart 3.10.7; embedded PostgreSQL 17.
- **Финальный прогон (журнал 1357–1424):** на C: 22–23 ГБ свободно; на D: ≈ 5,4 ГБ. После прогона
  `pos-app/.dart_tool/flutter_build` удалён, синтетических `pos_*.db` на C: нет, процессов node/postgres/optomstroy этого
  прохода нет, Android-эмулятор не запускался, коммитов нет, на C: ничего не удалялось.
- Прежде (до 23.10 21:48) **диск C: был почти заполнен**: во время ревью и отчёта свободно 7–77 МБ (раунд 1 — 69–77 МБ, раунд 2 — 31–39 МБ, §2.1 — 7–28 МБ). Остальное место — данные
  пользователя, их не трогали. Все временные файлы прогонов — на D: (`TEMP=TMP=D:/optomstroy/.tmp`). БД пользователя
  приложения пишется в `%APPDATA%\com.example\optomstroy` на C:, поэтому integration_test Flutter при < 300 МБ не
  запускаются.
- Диск D: свободно ≈ 6,8 ГБ.
- После прогона §2.1: процессов node/postgres/flutter автора отчёта нет. Integration не запускались, поэтому
  синтетических баз `pos_*.db` нет. Каталог `pos-app/.dart_tool/flutter_build` существует с 07:19 — его создал не этот
  прогон, поэтому он не удалялся. Чужие процессы (nodejs PID 41432, postgres PID 11816, dart-процессы IDE с 18.10 и
  21.10) не трогались. Android-эмулятор не запускался. Коммитов нет.

### 5.4. Прочие документы этапа

- Журнал прогонов — `docs/stages/F_test_run.log` (разделы перечислены в начале отчёта).
- Вопросы к ТЗ — `docs/stages/F_spec_questions.md`; синхронизация — `docs/stages/F_spec_sync.md`.
- RM-F-010 — `docs/stages/F_onec_e2e_report.md`.
- Матрица ошибок RM-F-007 — `docs/errors_matrix.md`.
- Видео и скриншотов сценариев нет. Golden-эталоны — `pos-app/test/**/goldens/`.

# Отчёт по этапу E — Catalog (синхронизация, категории, варианты, фото, поиск, остатки) «Оптомстрой POS»

**Этап:** E — Catalog · **Задача фиксации этапа:** RM-E-012 · **Ворота:** G-E
**Дата отчёта:** 2026-10-22 (итоговая редакция после закрытия остатков: ревью закрытия, раунд Fix2, финальный прогон
20:43–21:13) · **Автор (владелец отчёта):** QA + ARCH (13 §2.2) · **Независимый проверяющий:** отдельный агент, не
автор кода — `docs/reviews/E_review.md`. Раунд 1 — 14:40–15:25, раунд 2 — 15:56–16:40, прогон после закрытия
остатков — 19:20–20:13. Раздел «Закрытие остатков» (§14–§17) составил автор итоговых документов. Повторной
независимой проверки исправлений Fix2 и этой редакции отчёта не было.
**Основание:** 13_IMPLEMENTATION_ROADMAP §3.5 (RM-E-001…RM-E-017, ворота G-E), §6.1–§6.3; 12 §2.15 (строка
«E — Catalog»); ядро R0 v1.9 (приоритет §24 > … > §16 > базовый текст).

> **На фикстурах, не реальная интеграция** (SRC-D-176). API специалиста 1С не получен, тестовой копии 1С нет
> (ядро §24.3, RM-A-006). Все прогоны этапа шли на `FakeOnecGateway`, фикстурах `contracts/onec/fixtures`,
> синтетическом каталоге (`SyntheticCatalog`, до 50 000 SKU) и локальном моке HTTP-сервиса расширения. Данных
> заказчика нет. Коммитов этапов B–E нет; CI на GitHub Actions не запускался.

**Ссылки на доказательства.** «Журнал NNNN» — номер строки `docs/stages/E_test_run.log`. Основные разделы журнала:
- «Перепроверка после ревью, раунд 2» (независимый проверяющий) — строки 1293–1378;
- «Свежий прогон для отчёта этапа E» (автор отчёта) — строки 1382–1444;
- «Прогон после закрытия остатков» (независимый проверяющий) — строки 1448–1557;
- **«Финальный прогон этапа E»** (автор итоговых документов, после Fix2) — строки 1561–1654.

## Итог

- **Финальный прогон** (20:43–21:13, после раунда Fix2; журнал 1561–1654). Зелёные:
  - pos-api `test:all` — 849 passed, 6 skipped, 0 failed (журнал 1603–1608);
  - `test:cov:e` — 495 passed; строки 90,23 %, ветви 76,06 % (порог 80 % строк; журнал 1609–1612);
  - `lint`, `build`;
  - `flutter analyze` — 0 замечаний; `flutter test` — 1298 passed; golden — 164 (журнал 1619–1622);
  - `catalog_flow_test` на Windows — 2 из 2 (журнал 1626–1631). В прогоне 19:20 он был красным 2 из 2 (RR-1, исправлен);
  - регрессия D: `auth_flow_test`, `admin_invite_flow_test`, `boot_test` (журнал 1633–1641);
  - `check_secrets.py` (0 находок), `build_openapi.py --check`, `check_arb_keys.py`, `trace_test_ids.py --stage E` и
    остальные скрипты корня.
- ~~Красный — `check_no_double_money.sh`~~ — **закрыто оркестратором после отчёта** (F-N-01): три строки
  `Animation<double>` в `pos-app/lib/app/router/panel_page.dart` (геометрия анимации, не деньги) получили пометки
  `money-double: allow — <причина>`; `check_no_double_money.sh` — EXIT=0; после правки `flutter analyze` и
  `flutter build windows --release` — EXIT=0 (раздел «Финальная правка оркестратора» в конце журнала). Информационно:
  `dart format` — 9 сгенерированных `*.g.dart` (E-KI-06).
- Не перезапускались в финальном прогоне; результат взят из прогона проверяющего 19:20 (журнал 1448–1557):
  - madge, `test:cov:d` 97,92 %, smoke 10/10, auth-smoke 15/15, catalog-smoke 22/22, миграции (0 изменений) — код,
    который они проверяют, после 19:20 не менялся;
  - release-сборка Windows в прогоне 19:20 предшествовала правкам Fix2; повторная release-сборка после всех правок —
    EXIT=0 (раздел «Финальная правка оркестратора» в конце журнала).
- **Бенчмарк поиска повторён после исправлений ревью** (`docs/perf/E_search_benchmark.md` §8; журнал 1544–1552):
  p95 135,2 мс на 50 000 синтетических SKU при цели ≤ 300 мс (p50 62,3, p99 191,4), 0 ошибок, `matchType` 20 из 20.
  Это синтетика на машине разработчика, не реальная интеграция.
- Матрица T-ID этапа E: 128 ID, из них 87 с тестом (48 — частично), 41 not_done с причиной, 0 без теста и причины
  (журнал 1593–1595).
- Ревью раундов 1–2: подтверждено 50 замечаний, опровергнуто 1. После закрытия остатков исправлено 47, частично 2
  (E-flutter-ui-5, E-flutter-ui-9), не исправлено 1 (E-trace-6) (§5.1).
- Ревью закрытия: 21 замечание (1 critical, 4 major, 16 minor). Исправлено 17, частично 2, не исправлено 2
  (RC-1 — офлайн-выход без отзыва сессии на сервере, RC-5 — ключ ARB для G-11). Открытых blocker и critical нет.
- Не сделано по окружению (§2.3):
  - реальная 1С (RM-E-016 — «API 1С не получен»);
  - Android и iOS, камера, ручной тест HID-сканера, 50 000 SKU на устройстве;
  - Docker/compose и Caddy (`curl -I`), CI на GitHub Actions.
- **Статус ворот G-E — «жёлтый»** (§4.1). По 13 §3.5 при отчёте «API 1С не получен» выше «жёлтого» поставить нельзя.
  Оговорки E-KI-01, E-KI-03 и F-N-01 сняты. Остаются:
  - RC-1 (SS-07) — перенесено в этап F;
  - проверки на устройствах.

---

## 1. Готовые файлы

Коммитов этапов B–E нет, поэтому все пути ниже — неотслеживаемые или изменённые (`git status`). Владельцы — по
CONTRIBUTING.md §5 (13 §5.2).

### 1.1. Пути

| Путь | Новый / изменён | Задачи `RM-*` | Владелец | Версия контракта (было → стало) | Примечание |
|---|---|---|---|---|---|
| `pos-api/src/integrations/onec/**` (`OnecGateway`, `OnecExtensionGateway`, `OnecODataGateway`, `FakeOnecGateway`, allow-list OData, `SyntheticCatalog`) | новый | RM-E-001, RM-E-016 | ONEC | — | основной путь — расширение (`/pos/v1/changes`, `ack`); OData — только чтение |
| `pos-api/src/sync/apply/**`, `sync/reconcile/**` | новый | RM-E-001, RM-E-011 | ONEC | — | применение 1С → реплики, сверка `$count` |
| `pos-api/src/sync/{scheduler,api,alerts}/**`, `src/jobs/**` | новый / изм. | RM-E-002, RM-E-014 | ONEC + BE | — | pg-boss, `POST /sync/runs`, повтор outbox, `GET /sync/status` |
| `pos-api/src/sync/images/**`, `infra/caddy/Caddyfile` (`/images`) | новый / изм. | RM-E-003 | ONEC + OPS | — | sha256, WebP thumb/card/full, SEC-101 |
| `pos-api/src/catalog/{api,inventory,common}/**` | новый | RM-E-004, RM-E-014, RM-E-017 | BE | — | курсоры AES-256-GCM, остатки по полям |
| `pos-api/src/catalog/search/**`, `migrations/0005_search.sql`, `0006_catalog_sort_indexes.sql`, `docs/perf/E_search_benchmark.md` | новый | RM-E-005 | BE | — | D-31: штрихкод → артикул → FTS → триграммы |
| `pos-api/src/catalog/recent/**`, `src/customers/favorites/**` | новый | RM-E-006 | BE | — | |
| `pos-api/src/catalog/sync/**`, `migrations/0007_catalog_sync.sql` | новый | RM-E-015 | BE | — | `GET /catalog/sync/{entity}` |
| `pos-api/src/common/rate-limit/**` (RL-READ, RL-SEARCH, RL-CART) | новый / изм. | RM-E-004 (ревью E-security-2) | SEC | — | |
| `pos-api/migrations/0003_auth_refinements.sql`, `src/admin/bootstrap/**`, `src/jobs/otp/**`, `src/app.module.ts` | новый / изм. | остатки D: RM-D-001, RM-D-002, RM-D-016 | BE + SEC | — | DQ-01…03, INT-01, INT-02 (§1.3) |
| `pos-api/scripts/{seed_synthetic_catalog,load_catalog_fixtures,onec_acceptance,bootstrap-admin}.ts`, `local-stack.mjs` | новый / изм. | RM-E-005, RM-E-011, RM-E-016 | ONEC + QA | — | |
| `pos-api/test/{catalog,catalog-sync,favorites,images,onec,search,sync,sync-apply}/**`, `test/e2e/catalog/**`, `vitest.config.cov-e.ts` | новый | RM-E-012 | QA | — | 88 комментариев с T-ID (раунд 2) |
| `pos-app/lib/features/catalog/**`, `design_system/components/*` (ProductCard*, CategorySidebarItem, SortMenu, FilterPanel, StockBadge, …) | новый | RM-E-007 | FE + DS | — | |
| `pos-app/lib/features/product_details/**`, `features/cart/**/draft/**` | новый | RM-E-008 | FE + DS | — | «Добавить» кладёт товар в локальный черновик корзины |
| `pos-app/lib/core/sync/**`, `core/database/**` (drift v4), `features/sync_status/**` | новый / изм. | RM-E-009 | FE | — | SCR-43, outbox клиента |
| `pos-app/lib/core/hardware/**`, `features/scan/**` | новый | RM-E-010 | FE | — | HID-wedge, камера SCR-17 |
| `pos-app/lib/features/home/**`, `app/router/**`, `app/di/**` | новый / изм. | RM-E-017, RM-E-014 | FE | — | SCR-50, навигация `customer`, `CartDraftScanCartPort` |
| `pos-app/lib/core/config/public_settings_provider.dart`, `features/settings/**`, `core/session/**` (`SecureContent`), `test/features/admin/golden/**` | новый / изм. | остатки D: RM-D-007, 009, 010, 015 | FE | — | §1.3 |
| `pos-app/integration_test/catalog_flow_test.dart`, `admin_invite_flow_test.dart` | новый | RM-E-012 п. 2, RM-D-010 п. 3 | QA | — | Windows |
| `contracts/enums.json`; сгенерированные `pos-api/src/common/enums.ts`, `pos-app/lib/core/enums.dart` | изм. (синхронизация ТЗ) | остатки D (DQ-01, DQ-03) | владелец контракта | **1.0.0 → 1.1.0** | `rate_limit_scope` +7, `session_revoke_reason` + `refresh_replay` |
| `contracts/openapi/parts/{00_root,20_catalog,60_sync_admin_ops}.yaml`, `pos-api.v1.yaml`, `contracts/openapi/CHANGELOG.md` | изм. (синхронизация ТЗ, закрытие остатков) | RM-E-003, RM-E-015, остатки D | владелец 08 | **1.0.0 → 1.1.0** (MINOR, аддитивно; ADR-097) | пример `Image.*Url`; `Problem.until`, причины `UNLOCK_REQUIRED` (уточнено по RS-1); поля элементов выгрузки `CatalogSync*` и схема `CatalogSyncCategory` (FIX-EF-01); `POST /admin/users` → `oneOf [AdminUser, Invitation]` |
| `pos-api/src/health/openapi.document.ts` (+ `.spec.ts`), `test/e2e/smoke.e2e-spec.ts` | изм. (Fix2) | RM-E-012 | BE | экспорт `/openapi.json` 1.0.0 → 1.1.0 | RC-3, RS-11 |
| `contracts/l10n/app_{ru,ky,en}.arb` (сборка `build_arb.py` из 02 §7), копии `pos-app/lib/l10n/**`, `pos-app/lib/core/l10n/**` | изм. (закрытие остатков) | RM-E-007, RM-E-017, остатки D | владелец словаря (02 §7, 03 §16) | +59 ключей (ADR-097); ICU plural `cart_fab_a11y*` (RS-7) | `ky`/`en` — копии `ru` с пометкой «TODO перевод» (Q-007) |
| `contracts/rbac/permissions.yaml`, `contracts/onec/fixtures`, `contracts/enums.json` (после 1.1.0) | **не менялись** при закрытии остатков | — | — | — | — |
| `pos-api/src/sync/apply/catalog-applier.ts`, `test/sync-apply/barcode-conflict.spec.ts` | изм. / новый (закрытие остатков) | RM-E-001 | ONEC | — | правило 05 ONEC-017 п. 2 (E-KI-03) |
| `pos-api/src/sync/images/images-gc.service.ts`, `test/images/images-gc.spec.ts` | новый (закрытие остатков) | RM-E-003 | ONEC | — | задание `images.gc` (EQ-IMG-10) |
| `infra/compose.test.yml`, `infra/docker/scripts/{check_compose_test.py,gen-test-secrets.sh}`, `infra/env/README.md` | изм. (закрытие остатков) | RM-C-012 (остаток EQ-AUTH-08) | OPS | — | `worker` получает `otp_pepper` |
| `pos-app/lib/app/router/{panel_page,routes,app_router}.dart`, `design_system/layout/content_region.dart`, `features/product_details/**`, `features/catalog/presentation/**`, `features/sync_status/**` | изм. / новый (закрытие остатков, Fix2) | RM-E-007, 008, 009, 017 | FE + DS | — | панель SCR-14 на expanded (RR-1, RC-6), side sheet SCR-43, снекбары G-7/G-11, ключи `stock_badge_*` |
| `scripts/trace_test_ids.py` (`--stage E`), `check_secrets.py`, `check_enum_triangle.py`, `check_no_double_money.sh` | изм. | RM-E-012 | QA | — | ревью: E-trace-1, E-fresh-run-1, E-trace-7; закрытие: EQ-FINT-05, RC-2, RC-7, RR-2 |
| `docs/integration/smspro_connect.md`, `docs/ops/first_admin.md` | новый | остатки D (RM-D-002, INT-02) | BE + OPS | — | |
| `docs/stages/E_test_run.log`, `E_initial_import_report.md`, `E_onec_extension_acceptance.md`, `E_spec_questions.md`, `E_spec_sync.md`, `docs/reviews/E_review.md`, этот отчёт | новый | RM-E-011, 012, 016 | QA + ARCH | — | |
| 02, 03, 05, 06, 07, 08, 09, 11, 12, 13, 14, 15, 16, `visual/navigation.md` | изм. (синхронизация ТЗ) | — | владельцы документов | см. `E_spec_sync.md` §1 | §5.2 |
| 00, 02, 03, 07, 08 (v1.12–1.13), 09, 12, 13, 14, 15 (ADR-097), 16, `README.md`, `visual/navigation.md` | изм. (закрытие остатков, ревью закрытия RS-*/RC-4) | — | владельцы документов | — | журналы «Ревью закрытия этапа E» в каждом документе; ядро и бизнес-правила не менялись |

### 1.2. Статус задач этапа

- «Закрыта (локально)» — все пункты критерия 13 §3.5 выполнены запуском на машине разработчика.
- «Частично» — часть пунктов не выполнена; причина указана.
- Колонка «Подтверждение» ссылается на строки журнала. Наборы pos-api — по `test:all` финального прогона (журнал
  1603–1608): onec 36, sync-apply 34, sync 27, worker 20, catalog 33, catalog-sync 16, favorites 10, search 53,
  images 25, e2e 93. Покрытие `test:cov:e` — журнал 1609–1612.
- Каждый тест с текстом 12 построчно не сверялся. Опора — журнал, ревью и матрица T-ID (§2.4).

| Задача | Статус | Что подтверждено запуском (пункты критерия) | Подтверждение | Что не выполнено (причина) |
|---|---|---|---|---|
| RM-E-001 Адаптер 1С (чтение) | закрыта (локально), на фикстурах | п. 1: маппинг всех сущностей (`onec-values.spec.ts`, `catalog-apply.spec.ts`); п. 2: изменена 1 запись → изменилась 1 строка (`catalog-apply`, T-SYNC-002); п. 3: `deletion_mark` → товар скрыт; п. 4: ровно один `is_default`. Шлюзы проверены против мока (`onec-extension.gateway.spec.ts`, `onec-odata.spec.ts`). Правило привязки штрихкода по 05 ONEC-017 п. 2 исправлено, тест `barcode-conflict.spec.ts` (E-KI-03 снят) | журнал 1603–1608 (onec 36, sync-apply 34); 1609–1612 (`integrations/onec` 89,63 %, `sync/apply` 87,84 % строк) | Реальной 1С нет (RM-E-016). Исправление E-KI-03 скептиками не перепроверялось. T-SYNC-019 (перечитка упаковок, `BARCODE_CONFLICT` отдельным тестом) — not_done |
| RM-E-002 Планировщик | закрыта (локально) | п. 1–6: `sync.int.spec.ts` (singleton, ошибка адаптера → failed + `sync_errors` + уведомление, `$count` → partial, матрица ролей и step-up); `worker.int.spec.ts` (SYNC_ALREADY_RUNNING, dead-letter) | журнал 1603–1608 (sync 27, worker 20) | Паузы повторов 60 + 60 с — одно из двух прочтений 05 SYNC-029; ТЗ уточнено (FIX-E-01 → 06 §7.5) |
| RM-E-003 Фотографии | **частично** | п. 1: один файл для двух товаров хранится один раз; п. 2: битый файл → заглушка и `sync_errors` (`images.spec.ts`); SEC-101 — `image-security.spec.ts` (T-SEC-046); задание `images.gc` (очистка в два цикла: пометка, затем удаление) — `images-gc.spec.ts` | журнал 1603–1608 (images 25); 1401–1404 (фото 300/300, дедупликация 1) | п. 3: `curl -I /images/<sha>/card.webp` **не выполнен** — Docker и Caddy нет. Заголовок проверен по конфигурации (`caddyfile.spec.ts`) и через локальный media-proxy стека. Очередь `images.gc` не внесена в 06 §7.5 и `common/jobs/contracts/queues.ts` (задача владельца) |
| RM-E-004 Catalog API | закрыта (локально) | п. 1: ответы валидны по OpenAPI (staff и customer); п. 2: `If-None-Match` → 304; п. 3: `/inventory/check` для 3 вариантов; п. 4: цены строкой + `KGS` (`catalog-api.e2e.spec.ts`); на реальных сессиях — `catalog-flow.e2e-spec.ts` | журнал 1603–1608 (catalog 33, e2e 93); 1500 (catalog-smoke 22/22, прогон 19:20) | — |
| RM-E-005 Поиск | закрыта (локально) | эталонные запросы D-31 и `matchType` (`search.e2e.spec.ts`). Бенчмарк повторён после исправлений ревью: p95 135,2 мс на 50 000 SKU, 0 ошибок, `matchType` 20/20 | журнал 1603–1608 (search 53); 1544–1552; `docs/perf/E_search_benchmark.md` §8 | Только синтетика на машине разработчика. k6 50 VU 10 мин (T-PERF-001) не запускался — RM-H-004 |
| RM-E-006 Избранное и недавние | закрыта (локально) | двойной `PUT` идемпотентен; недавние ≤ N и упорядочены по времени; `DELETE /catalog/products/recent` идемпотентен (`favorites-recent.e2e.spec.ts`; T-FAV-001/003/004/007) | журнал 1603–1608 (favorites 10) | — |
| RM-E-007 Flutter: каталог | закрыта (локально), с оговоркой | п. 1: golden SCR-10 на 3 брейкпоинтах; п. 2: debounce 300 мс и запрет при < 2 символах (`catalog_search_screen_test`); п. 3: скелетон, пусто, ошибка, нет сети (`catalog_screen_test`); п. 4: `CUSTOMER_SELF_SERVICE=false` (`customer_navigation_test`). Чип области UI-11-009 и side sheet SCR-43 на expanded сделаны | журнал 1622 (golden 164); 1620–1621 (1298 тестов) | Обрезка текста в части эталонов (E-flutter-ui-9, FIX-EF-13) — не перепроверялась |
| RM-E-008 Flutter: карточка товара | **частично** | п. 1: при одном варианте селектора нет; п. 2: `QTY_NOT_MULTIPLE`/`QTY_BELOW_MIN` (`product_details_screen_test`, `qty_rules_test`); панель SCR-14 на expanded — integration Windows (RR-1 исправлен) | журнал 1620–1621; 1626–1631 | п. 3: «открытие из кэша ≤ 200 мс» **на устройстве не замерено**: есть только хостовый тест `product_cache_open_test` (NFR-PERF-003). Android-устройства нет (E-trace-6, FIX-EF-12) |
| RM-E-009 Flutter: кэш и офлайн | **частично** | п. 1: integration на Windows — офлайн, каталог и карточка из кэша с баннером и возрастом данных; п. 2: «в избранное» офлайн → один `PUT` с ключом (`outbox_queue_test`, T-FAV-008) | журнал 1626–1631 (2 из 2: кэш 496 товаров, 8 карточек офлайн); 1620–1621 | п. 3: 50 000 SKU ≤ 3 мин по Wi-Fi **на целевом устройстве не замерено**: есть только хостовый `bulk_load_perf_test` с фейковым API |
| RM-E-010 Сканер | **частично** | п. 1: серия клавиш быстрее 50 мс с суффиксом — скан, ручной ввод — нет (`hid_wedge_detector_test`, `scanner_wedge_service_test`); widget SCR-17 (`scan_screen_test`); G-11 (`/scan` без камеры) — блок и снекбар | журнал 1620–1621 | п. 2: integration на Android **не выполнен** — эмулятор в этом окружении не запускается, устройства нет. п. 3: ручной тест HID на Windows **не выполнен** — сканера RM-A-008 нет; шаблон протокола — §5.3. Текст снекбара G-11 — временный ключ (RC-5) |
| RM-E-011 Загрузка каталога | закрыта, **на фикстурах** | п. 1: `$count` 1С = БД по всем сущностям; п. 2: 0 ошибок маппинга; п. 3: отчёт озаглавлен «на фикстурах, не реальная интеграция» | журнал 570–600 (исходный прогон); 1401–1404 (повтор после исправлений ревью, тот же результат) | Тестовой копии 1С нет (§2.6). После исправления E-KI-03 загрузка не перезапускалась (покрыта `catalog-smoke` 19:20 и `sync-apply`) |
| RM-E-012 Тесты, сборка, проверка, отчёт | **частично** | п. 1: T-CAT/T-SYNC/T-INV запущены, матрица T-ID — §2.4; п. 2: Windows — `catalog_flow_test` 2 из 2; п. 3: покрытие backend 90,23 % строк, Flutter catalog domain+data 83,9 %; ревью `E_review.md` (в т. ч. закрытие остатков); этот отчёт | журнал 1593–1595; 1626–1631; 1609–1612; 1186–1191 (покрытие Flutter, раунд 1 — не перезапускалось) | **Гейт `check_no_double_money.sh` красный** (F-N-01, журнал 1576–1579). п. 1: 48 ID покрыты частично, 41 — not_done (этапы F–H, устройство, копия 1С). п. 2: **Android не выполнен**. CI на GitHub не запускался. Покрытие Flutter после изменений pos-app не перемерялось |
| RM-E-013 Входящий обмен C-2 | не выполнялась (условная) | `POST /sync/runs` → 422 `inbound_mode` при `ONEC_INBOUND_ENABLED=true` (`sync.int`) | журнал 1603–1608 | Вариант C-2 не выбран (Q-031). В G-E задача не входит |
| RM-E-014 Дополнения ядра v1.4 | **частично** | п. 1–3: `catalog-api.e2e`, `search.e2e`, `sync.int`; п. 5: скан под `cashier`/`seller`, `scan_adds_to_cart` (`scan_cart_wiring_test`), при неизвестном остатке «Добавить» недоступна | журнал 1603–1608; 1620–1621 | п. 4: «Очистить недавние» офлайн → ровно один `DELETE` проверено только unit-тестом очереди (`outbox_queue_test`), **integration-шага нет** (E-trace-6, FIX-EF-12) |
| RM-E-015 Офлайн-API каталога | закрыта (локально) | п. 1–4: `catalog-sync.e2e.spec.ts` (12 сущностей, ровно 5 полей, `limit=201`, изменения во время выгрузки, виды цен по роли, повтор `since`); курсор привязан к области видимости (E-api-3). Поля элементов выгрузки внесены в OpenAPI 1.1.0 (FIX-EF-01); ключи DTO pos-app совпадают с контрактом | журнал 1603–1608 (catalog-sync 16 + 1 skipped); 1583 (`build_openapi --check`); 1620–1621 (`catalog_dto_contract_test`, `dto_schema_test`) | — |
| RM-E-016 Приёмка API 1С | **отчёт «API 1С не получен»** | `E_onec_extension_acceptance.md` описывает готовность к приёмке. Раннер `onec_acceptance.ts --mock`: КП-1, 2, 5, 18, 19 PASS на моке. `check_onec_paths.py` — 0 ошибок | журнал 559–566, 1398–1400 (PASS 5/5, вручную 15); 1592 | Пп. 1–4 на тестовой копии не выполнялись: API и копии нет. П. 5 — последствия и решение по §3.12, §4.2 |
| RM-E-017 Режим клиента | закрыта (локально) | п. 1: AC-API-180 (`catalog-api.e2e`); п. 2: вид цены клиента; п. 3: golden SCR-50, навигация `customer` (`customer_navigation_test`), `StockBadge` без числа с текстом «В наличии» / «Мало» и `Semantics.label` (ключи `stock_badge_*`, E-KI-01 снят; T-CAT-032); п. 4: `CUSTOMER_SELF_SERVICE=false` | журнал 1603–1608; 1620–1622; 1626–1631 (сценарий клиента PASS) | — |

### 1.3. Остатки этапа D, закрытые на этапе E

Источники: `D_spec_questions.md` («Статусы DQ-01…DQ-03 и INT-01/INT-02 после миграции 0003»), `E_spec_questions.md`
(агенты «AUTH: остатки этапа D — backend» и «DREST: остатки этапа D во Flutter»), `E_spec_sync.md` §5.
Наборы pos-api финального прогона (auth 56, foundation 57, admin 52, settings 17, sms 65, e2e 93) — журнал 1603–1608;
`test:cov:d` 97,92 % строк — журнал 1496–1497 (прогон 19:20; код этапа D после него не менялся).

| Пункт (отчёт D) | Что сделано на этапе E | Подтверждение | Статус |
|---|---|---|---|
| DQ-01 — лимиты OTP, RL-OTP-VERIFY, RL-PIN, RL-ADMIN в PostgreSQL | Миграция 0003: области `otp_ip_10m`, `otp_ip_24h`, `otp_device_10m`, `otp_global_1m`, `otp_verify_ip_10m`, `pin_user_device_10m`, `admin_user_1m`; одно атомарное `consume`. `contracts/enums.json` 1.1.0 | `rate-limit.foundation-spec.ts`, `auth-refinements.e2e-spec.ts` (лимиты переживают перезапуск), `admin-rate-limit.admin-spec.ts`; журнал 1603–1608, 1587–1588 (`check_enums`, `check_enum_triangle` — 0 ошибок) | закрыт (локально). Оставлено осознанно: adm A-10 (24 ч по аудиту), PR-11 (группы `memory`) |
| DQ-02 — `amr = admin_code` | CHECK `sessions_amr_chk` + `admin_code`, сессия аварийного входа хранит `["admin_code"]` | `emergency-login.e2e-spec.ts`; журнал 1603–1608 | закрыт (локально). В ответах API `admin_code` фильтруется: enum OpenAPI не менялся (EQ-AUTH-02) |
| DQ-03 — столбцы `locked_at`, `issued_by_user_id`, `issued_jti`, `sms_outbox.request_id`, `refresh_replay` | Миграция 0003; 8 подпунктов «оставлено» с обоснованием (D_spec_questions, строки 251–257) | e2e «locked_at», «issued_jti», «request_id», `sessions.e2e-spec.ts`; журнал 1603–1608, 1505–1511 (миграции, 0 изменений при повторе; прогон 19:20) | закрыт (локально) в решённой части |
| INT-01 — доставка OTP через pos-worker | `AuthModule.withQueuedSms()`: `sms_outbox` и `sms.send` пишутся в транзакции выпуска; итог `failed` → возврат квоты; очередь недоступна → 503 без расхода квот | e2e «доставка OTP через очередь pos-worker» (`auth-refinements.e2e-spec.ts`); журнал 1603–1608 | закрыт (локально). Остаток EQ-AUTH-08 закрыт при закрытии остатков E: `worker` получает `otp_pepper` в `infra/compose.test.yml` (`check_compose_test.py` OK, журнал 1596–1598; Docker не запускался). `docs/ci.md` (таблица сервисов) не обновлён (F-N-02) |
| INT-02 — первый `admin` на пустой БД | CLI `scripts/bootstrap-admin.ts`, инструкция `docs/ops/first_admin.md` | `test/admin/bootstrap-admin.admin-spec.ts`, e2e «INT-02»; журнал 1603–1608 | закрыт (локально). На staging/prod не выполнялся |
| `docs/integration/smspro_connect.md` (RM-D-002) | Инструкция создана | файл есть | закрыт документально. Реальный аккаунт SMSPro не подключался (Q-029, RM-A-004): RM-D-002 п. 2 по-прежнему не выполнен |
| SCR-42 «Устройства/сессии», «Защита входа» (RM-D-009) | Разделы SCR-42 реализованы: сессии, PIN со step-up, биометрия, сканер, отображение | `settings_screen_test.dart` (31 тест) в составе 1298; журнал 1620–1621 | закрыт (локально) с бэклогом: EQ-DREST-07 (outbox `profile.settings`), EQ-DREST-17 (`returnTo` после выхода), секция принтера скрыта (D-27), названия языков — ключи `settings_language_*` внесены (ADR-097) |
| Public settings во Flutter (RM-D-015) | `core/config/public_settings_provider.dart`, кэш в `app_meta`; SCR-45 и guard G-8 читают `GET /settings/public` | `public_settings_provider_test.dart` (14), `admin_public_settings_test.dart` (3); журнал 1620–1621 | **частично**: `customerSelfServiceProvider` фичи registration читает флаг сборки; маршрута `PUT /admin/settings` нет (RM-D-015 п. 2, часть) |
| Golden SCR-45 (RM-D-010 п. 2) | `test/features/admin/golden/admin_users_golden_test.dart` — 3 брейкпоинта | журнал 1622 (golden 164) | закрыт (локально, Windows) |
| `admin_invite_flow_test` (RM-D-010 п. 3) | «приглашение в UI → вход по OTP → PIN» на Windows | журнал 1367–1369 (3/3, раунд 2); 1533–1540 (19:20); 1633–1641 (финальный); 1202–1213 (раунд 1: 1 из 2 запусков красный) | закрыт (локально). E-KI-02: в `ScannerConfigController._load` добавлены перехват ошибки и проверка `ref.mounted`; нестабильность больше не воспроизводилась |
| AU-03 — подсказка `devCode` | Клиент читает необязательное `devCode` и показывает его только при `!kReleaseMode` и `ENV≠prod`. ТЗ уточнено (09 §4.6, 02 SCR-02) | `auth_d_remainders_test.dart` (13); журнал 1620–1621 | **частично**: pos-api поле не возвращает. В OpenAPI 1.1.0 его сознательно не внесли: 09 §4.6 — «в R1 не возвращается» (08 §16.9, ADR-097). Поэтому подсказка на стенде не появится |
| AU-04 — сигнал `PhoneField` | `PhoneField.onInputSignal(tooLong / unsupportedFormat)`, SCR-01 показывает `auth_phone_error_long` / `auth_phone_error_format` | `auth_d_remainders_test.dart`; журнал 1620–1621 | закрыт (локально) |
| AU-16 — защита экрана при вводе PIN/OTP | `SecureContent` перенесён в `core/session` и включён на всех полях PIN/OTP (FIX-EF-09). На Android — `FLAG_SECURE` через канал | `auth_d_remainders_test.dart`, `session_gate_test.dart`; журнал 1620–1621 | **частично**: на Android не проверено (нет устройства); SMS User Consent API не реализован; запрет снимков — решение заказчика (Q-181) |

**Отчёт этапа D дополнен** (ревью E-trace-9 закрыто документально): в конец `D_authentication_report.md` добавлен
раздел «Дополнение 2026-10-22: остатки D, закрытые на этапе E». Исторические разделы не менялись. G-D там
по-прежнему «красный»: RM-D-008 (Android) и RM-D-002 п. 2 (SMSPro) не выполнены.

## 2. Выполненные проверки

### 2.1. Финальный прогон этапа E (2026-10-22 20:43–21:13, после раунда Fix2)

Прогон выполнил автор итоговых документов, код при этом не менялся. Перезапущено то, что затронул Fix2, и ключевые
команды. Перечень изменённых после 19:20 файлов — журнал 1565–1571 (`find -newer`). Код поиска и синхронизации
(`pos-api/src/catalog/**`, `src/sync/**`) после 19:20 не менялся.

| № | Задача / критерий | Команда | Результат | Лог |
|---|---|---|---|---|
| 1 | AC-RM-E-012 п. 1 | `npm run test:all` (pos-api, 21 набор) | EXIT=0; **849 passed, 6 skipped, 0 failed** (+1 тест: `openapi.document.spec.ts`, RC-3) | журнал 1603–1608 |
| 2 | AC-RM-E-012 п. 3 | `npm run test:cov:e` | EXIT=0; 495 passed; Stmts 87,73 %, Branch 76,06 %, Funcs 87,34 %, **Lines 90,23 %** | журнал 1609–1612 |
| 3 | статическая проверка | `npm run lint`, `npm run build` | EXIT=0 | журнал 1613–1614 |
| 4 | статическая проверка | `flutter analyze` | EXIT=0; No issues found | журнал 1619 |
| 5 | AC-RM-E-012 п. 1, RM-E-007…010, 017 | `flutter test --concurrency=2` | EXIT=0; **+1298: All tests passed** (в т. ч. `catalog_dto_contract_test`, `dto_schema_test`, `guard_notice_test`) | журнал 1620–1621 |
| 6 | RM-E-007 п. 1, RM-E-017 п. 3 | `flutter test --concurrency=2 --tags golden` | EXIT=0; +164 | журнал 1622 |
| 7 | AC-RM-E-012 п. 2 (Windows), AC-RM-E-009 п. 1 | `flutter test integration_test/catalog_flow_test.dart -d windows --dart-define-from-file=env/dev_proxy.json` | EXIT=0 **2 из 2**; кэш 496 товаров за 1046–3261 мс; черновик — 1 строка, вариант выбран, «2шт»; офлайн — баннер с возрастом данных, 8 карточек | журнал 1626–1631 |
| 8 | регрессия D | `auth_flow_test`, `admin_invite_flow_test`, `boot_test` на свежем стеке | EXIT=0: +3, +1, +1 | журнал 1633–1641 |
| 9 | гейты репозитория | `check_secrets.py` (+ `--self-test`), `build_openapi.py --check`, `check_arb_keys.py`, `check_api_paths.py`, `check_enums.py`, `check_enum_triangle.py`, `sync_contracts.py --check`, `check_layers.py`, `check_repo_layout.py`, `check_onec_paths.py`, `trace_test_ids.py --summary` / `--stage E --summary`, `check_compose_test.py` | все EXIT=0; `check_secrets` — 1756 файлов, 0 находок; OpenAPI 119 путей / 141 операция; матрица E — 128 / 87 / 41 / 0 | журнал 1581–1598 |
| 10 | гейт MNY-002 | `bash scripts/check_no_double_money.sh` (+ `--self-test`) | **EXIT=1**: 3 строки `Animation<double>` в `pos-app/lib/app/router/panel_page.dart:65, 71, 72` (новый файл Fix2, RC-6), без пометки с причиной (F-N-01). В pos-api нарушений нет. Self-test — OK | журнал 1576–1580 |
| 11 | инфо (шага в CI нет) | `dart format --output=none --set-exit-if-changed lib test integration_test` | EXIT=1: 9 сгенерированных `*.g.dart` (E-KI-06); рукописные файлы отформатированы | журнал 1623–1625 |

### 2.2. Прогон независимого проверяющего после закрытия остатков (19:20–20:13) и более ранние

Команды, не повторённые в §2.1, взяты из прогона проверяющего 19:20 (журнал 1448–1557). Код, который проверяют
№ 1–4 и 6, после 19:20 не менялся. Release-сборка Windows (№ 5) сделана до правок Fix2 в pos-app: после них
компиляцию подтверждают только `flutter analyze` и debug-сборка в `catalog_flow_test`.

| № | Команда | Результат | Лог |
|---|---|---|---|
| 1 | pos-api `npm run madge`, `check:permissions` | EXIT=0; циклов нет; 77 кодов прав, 7 ролей | журнал 1487–1488 |
| 2 | pos-api `test:cov:d` | 376 passed; строки 97,92 % | журнал 1496–1497 |
| 3 | local-stack `smoke` / `auth-smoke` / `catalog-smoke` | 10/10, 15/15, 22/22 PASS (на фикстурах) | журнал 1498–1500 |
| 4 | Миграции `run-sql --repeat-strict` (prod; dev/test) | 0 изменений; 63/63 и 64/64 таблиц; 45/45 enum; `check_ddl_behavior` OK | журнал 1505–1511 |
| 5 | `flutter build windows --release` | собрано | журнал 1541 |
| 6 | `npm run bench:search -- --sku 50000 --duration 60 --warmup 10 --connections 50` | EXIT=0; p95 135,2 мс (§2.5) | журнал 1544–1552 |
| 7 | `catalog_flow_test`, `trace_test_ids.py --stage E` | **красные** в 19:20 (RR-1, RR-2), исправлены в Fix2 и зелёные в §2.1 | журнал 1475–1480, 1521–1532 |

Более ранние прогоны — исторические:
- раунд 2 проверяющего — журнал 1293–1378;
- свежий прогон автора отчёта 17:30 — журнал 1382–1444. В нём повтор бенчмарка не удался: ECONNRESET, на D: был
  ~1 ГБ свободного места.

Покрытие Flutter (`--coverage`) измерялось только в раунде 1 (журнал 1186–1191): catalog domain+data 83,9 %,
features/*/data 83,1 %, features/*/domain 80,3 %. После правок pos-app его **не перемеряли**.

### 2.3. Не выполненные проверки

Такие проверки не считаются пройденными.

| Задача / критерий | Команда / проверка | Причина | Когда и кем будет выполнена |
|---|---|---|---|
| RM-E-016 пп. 1–4, RM-E-011 на копии, T-ONEC-003/004/012/015/016, T-SYNC-030 | `check_onec_paths.py` против HS копии, КП-1…КП-20, `ONEC_MODE=extension` | **API 1С не получен**, тестовой копии нет (RM-B-014, RM-A-006) | ONEC + специалист 1С после передачи API (`E_onec_extension_acceptance.md` §2) |
| RM-E-012 п. 2, RM-E-010 п. 2, T-CAT-013 | integration на Android, скан EAN-13 камерой | эмулятор в этом окружении не запускается (запрет окружения; на C: свободно ~3 ГБ), устройства нет | QA после освобождения места или с устройством (RM-A-008) |
| iOS | сборка и прогон | нет macOS/Xcode (Q-008) | вне R1 до решения Q-008 |
| RM-E-010 п. 3, T-CAT-012 | ручной тест HID-сканера на Windows | сканера RM-A-008 нет | QA по шаблону §5.3 |
| RM-E-008 п. 3 (NFR-PERF-003) | открытие карточки из кэша ≤ 200 мс на устройстве | нет устройства; есть только хостовый тест | QA, FIX-EF-12 |
| RM-E-009 п. 3 (NFR-PERF-006), T-CAT-025 | 50 000 SKU ≤ 3 мин по Wi-Fi | нет устройства; есть только хостовый `bulk_load_perf_test` | QA, FIX-EF-12 |
| RM-E-014 п. 4 | integration «Очистить недавние» офлайн → один `DELETE` | шаг не написан (E-trace-6) | FE/QA, FIX-EF-12 |
| RM-E-003 п. 3 | `curl -I /images/<sha>/card.webp` через Caddy | Docker, compose и Caddy не установлены (нужно разрешение заказчика, G-C) | OPS после установки Docker |
| RM-E-012 (CI) | job `api-integration`, `coverage-gate` на GitHub Actions | коммитов и push нет: конфигурация CI проверена только локальным запуском тех же команд | после первого коммита и push |
| RM-E-005 на целевом сервере | `bench:search` / k6 на сервере заказчика | повтор после исправлений ревью выполнен на машине разработчика (§2.5, p95 135,2 мс); на целевом сервере и на данных заказчика — нет | RM-H-004 |
| Гейт MNY-002 (`check_no_double_money.sh`) | повтор после исправления F-N-01 | красный в финальном прогоне (`panel_page.dart`) | FE: пометка с причиной или перенос геометрии в `design_system`; до G-F |
| Покрытие Flutter после правок pos-app | `flutter test --coverage` | не перемерялось после раунда 1 | QA при следующем прогоне |
| T-PERF-001, T-SEC-027 класс B | k6 50 VU 10 мин, sqlmap | не запускались | RM-H-004, этап H |
| RM-D-002 п. 2 (остаток D) | контрактный тест SMSPro `test=1` | нет аккаунта SMSPro (Q-029) | QA + SEC после выдачи аккаунта |

### 2.4. Матрица T-ID этапа E (RM-E-012 п. 1)

Команда: `python -I -X utf8 scripts/trace_test_ids.py --stage E` (полная матрица) и `--summary` (финальный прогон,
журнал 1594–1595).

Охват:
- 12 §2.15, строка «E — Catalog»;
- приёмочные наборы T-UI для экранов этапа;
- T-SEC класса A для каталога и фото: T-SEC-017, 027, 046.

Статус «тест (трасса)» означает тест pos-app без T-ID в тексте. Связь «файл::название теста» задана в скрипте, и
скрипт её проверяет. В раунде 2 проверяющий выборочно сверил ссылки с текстом 12 — соответствуют
(`E_review.md` §8 п. 4).

| Группа | В охвате | С тестом | not_done с причиной | Без теста и причины |
|---|---|---|---|---|
| T-CAT | 36 | 34 | 2 | 0 |
| T-INV | 14 | 10 | 4 | 0 |
| T-FAV | 8 | 6 | 2 | 0 |
| T-SYNC-001…030, 043…046 | 34 | 24 | 10 | 0 |
| T-ONEC-001…019 | 19 | 9 | 10 | 0 |
| T-SEC-017, 027, 046 | 3 | 3 | 0 | 0 |
| T-UI-010…017, 042, 043, 045, 050 | 12 | 0 | 12 | 0 |
| T-PERF-001, 002 | 2 | 1 | 1 | 0 |
| **Итого** | **128** | **87** (T-ID в тесте 70, трасса 17; из них частично 48) | **41** | **0** |

Причины not_done:
- этапы F/G (корзина, заказы, долги, история, клиенты 1С): T-CAT-033, T-INV-006/007/011, T-FAV-005/006,
  T-SYNC-011, 015–018, 029, 046, T-ONEC-005…011, 013;
- нет тестовой копии 1С: T-SYNC-030, T-ONEC-015;
- условный элемент C-2: T-ONEC-018;
- нагрузка k6: T-PERF-001;
- приёмочные наборы T-UI (по одному кейсу на каждый AC-UI экрана) не собраны. Доля AC-UI в тестах pos-app — от
  0/12 (SCR-15) до 12/21 (SCR-45);
- **не покрыто или не реализовано на этапе E** (§3.1): T-SYNC-019, T-SYNC-009 (E-KI-04), T-INV-013, T-CAT-028.
  T-SYNC-005 после исправления E-KI-03 получил тест `barcode-conflict.spec.ts`, пока частично. В причине not_done
  у T-SYNC-019 осталась устаревшая ссылка «правило выбора — E-KI-03»: правило уже исправлено, а отдельного теста
  перечитки упаковок по-прежнему нет.

### 2.5. Бенчмарк поиска (RM-E-005, T-PERF-002)

Источник — `docs/perf/E_search_benchmark.md`, §8 «Повтор после ревью». Прогон: 2026-10-22, 20:08–20:12,
независимый проверяющий; журнал 1544–1552. Нагрузка — `autocannon -c 50`, прогрев 10 с, замер 60 с, 20 запросов на
50 000 синтетических SKU. Замер выполнен **после** исправлений ревью в коде поиска (E-api-2 — курсор стадии trgm,
E-api-4 — `greatest(available,0)`, RL-SEARCH). Код поиска после замера не менялся (журнал 1565–1571).

| Показатель | Цель | Факт: повтор после ревью | Первый замер (06:00 UTC, до исправлений) | Статус |
|---|---|---|---|---|
| p95 `GET /search/products` | ≤ 300 мс | **135,2 мс** (p50 62,3; p99 191,4; max 356,4) | 169,8 мс (p50 78,9; p99 227,8; max 351,0) | достигнуто на стенде разработчика |
| Ошибки / не-2xx | < 0,1 % | 0 из 41 785 | 0 из 33 192 | достигнуто |
| `matchType` по эталонному набору | 100 % | 20 из 20 | 20 из 20 | достигнуто |
| Пропускная способность | справочно | 696,4 запроса/с | 553,2 запроса/с | — |

По группам запросов (p95):
- штрихкод — 84,6 мс;
- артикул — 91,8 мс;
- название (FTS и триграммы) — 158,1 мс.

Худший отдельный запрос — по-прежнему `радиатор` + `inStock` + `sort=price:asc`: p95 252,0 мс, p99 320,6 мс. Это
ближе всего к цели. Разница с первым замером частично объясняется условиями: машина была свободна. Это не
доказательство ускорения кода.

Ограничения замера:
- стенд — машина разработчика (Windows, embedded PostgreSQL, `fsync=off`), один процесс Node без AuthGuard;
- данные синтетические, не каталог заказчика (Q-040);
- замер на целевом сервере и k6 — RM-H-004.

### 2.6. Загрузка каталога (RM-E-011) — на фикстурах

Источник — `docs/stages/E_initial_import_report.md`, озаглавлен «на фикстурах, не реальная интеграция». Состав:
`FakeOnecGateway`, фикстуры `contracts/onec/fixtures` и 5 000 синтетических SKU (seed 1).

Результат:
- 9 прогонов полной синхронизации — `success`, ошибок 0;
- сверка `$count` — 12 строк «1С = БД», расхождений 0;
- `sync_errors` пуст, ошибок маппинга 0;
- фото — 300 файлов, 300 готовы, дедупликация 1, ошибок 0.

Исходный прогон — журнал 570–600. Повтор автора отчёта после исправлений ревью (E-onec-sync-3 менял полную
загрузку) — журнал 1401–1404, результат тот же; полная загрузка 9,2 с.

Сверки срезов цен и остатков с 1С по `$count` нет: в 1С он для них не определён. Их полнота подтверждена сравнением с
источником.

### 2.7. Приёмка API 1С (RM-E-016) — «API 1С не получен»

Источник — `docs/stages/E_onec_extension_acceptance.md`.

Дата и причина (RM-B-014 п. 4): на 2026-10-22 специалист 1С заказчика не передал API (расширение «OptomstroyPOS» по
`18_ONEC_API_REQUEST.md`), тестовой копии базы нет (ядро §24.3, RM-A-006). Журнала версий расширения
`docs/integration/onec_extension_versions.md` нет — версий не поступало.

Что готово к приёмке:
- клиент `OnecExtensionGateway` проверен против мока на фикстурах;
- раннер `onec_acceptance.ts`: на моке PASS 5 из 5 автоматических КП, 15 шагов — вручную (журнал 1398–1400);
- описаны порядок приёмки и переключение на `ONEC_MODE=extension`.

Последствия и решение по §3.12 — §4.2.

## 3. Известные проблемы

### 3.1. Дефекты и пробелы

Серьёзность — по 13 §6.2. Статус «закрыт» ставится только по результату запуска или чтения кода в этой редакции.
Доказательства — `E_review.md` §15–§16.

| ID | Описание | Серьёзность | Статус / обход | План (задача, срок) |
|---|---|---|---|---|
| F-N-01 | Гейт `check_no_double_money.sh` (MNY-002) красный. Три строки `Animation<double>` в новом `pos-app/lib/app/router/panel_page.dart:65, 71, 72` (Fix2, RC-6) нарушают правило «double вне `design_system`» без пометки `money-double: allow — <причина>`. Это геометрия анимации, не деньги | существенная (обязательный гейт CI красный) | **открыт** (журнал 1576–1579) | FE: пометить строки с причиной или вынести `PanelPage` в `design_system`; **до G-F** |
| RC-1 | Офлайн-выход не ставит в outbox `auth.logout` / `pending_logout`: серверная сессия остаётся живой до истечения срока, до 7 дней. Ревью закрытия: major, исправитель ссылается на вердикт проверки — minor | существенная (безопасность) | **открыт**. Обход — только ручной отзыв сессии через управление сессиями после следующего входа (в этом прогоне не проверялся) | FE + SEC, бэклог SS-07 (класс C): обработчик без сессии (refresh → logout) и запасной путь при `UNLOCK_REQUIRED` — `DELETE /auth/sessions/{sid}`; до этапа H |
| E-KI-01 | Статус наличия для клиента — только иконка (E-flutter-ui-2) | — | **закрыт**: ключи `stock_badge_*` внесены (ADR-097) и используются; `StockBadge` отдаёт текст в `Semantics.label` | — |
| E-KI-02 | `admin_invite_flow_test` был нестабилен (R1-N-01) | — | **закрыт по коду**: перехват ошибки и проверка `ref.mounted` в `ScannerConfigController._load`; с раунда 2 зелёный во всех 5 запусках (журнал 1633–1641) | — |
| E-KI-03 | Правило привязки штрихкода в пакете расходилось с 05 ONEC-017 п. 2 (R2-N-02) | — | **закрыт**: правило исправлено, тест `barcode-conflict.spec.ts`. Скептиками не перепроверялось | — |
| E-KI-04 | Отчёт о дублях `onec_code` при первичной загрузке (T-SYNC-009) не реализован: код `DUPLICATE_SUSPECTED` есть в перечне, обработки нет | незначительная (P2) | открыт | этап F или H |
| E-KI-05 | Длина шифртекста курсора выдаёт порядок величины ключа сортировки (R1-N-02). Двоичный поиск остатка через `POST /inventory/check` только замедлен лимитом; вывод остатка клиентом вынесен в Q-316 | незначительная | открыт | решение по Q-316 |
| E-KI-06 | 9 сгенерированных `*.g.dart` не проходят `dart format --set-exit-if-changed` (RR-3). source_gen 4.2.4 не поддерживает ширину 120. В CI этого шага нет | незначительная | частично: рукописные файлы отформатированы | DevOps: исключить `*.g.dart` из шага формата в `ci.yml`, если шаг будет введён |
| E-KI-07 | Ослабление правила `check_secrets.py` (R2-N-01) | — | **закрыт** (RC-7): исключение снято, 3 строки в тестах помечены `check-secrets: allow` | — |
| E-KI-08 | Частичные остатки ревью раунда 1 | незначительная | **частично**. Закрыто: side sheet SCR-43 на expanded, снекбары G-7, предупреждение SCR-01, чип области UI-11-009. Открыто: проверка G-7 по permission из токена — бэклог FE; обрезка текста в эталонах (E-flutter-ui-9, FIX-EF-13) — не перепроверялась | FE |
| E-KI-09 | Шаг integration «Очистить недавние» и замеры 200 мс / 50 000 SKU не выполнены (E-trace-6) | незначительная | открыт; обход — unit-тест очереди и хостовые тесты | FE/QA, FIX-EF-12 |
| E-KI-10 | Отчёт этапа D не обновлён (E-trace-9) | — | **закрыт документально**: в `D_authentication_report.md` добавлен раздел «Дополнение 2026-10-22» | — |
| E-KI-11 | 48 ID матрицы покрыты частично: сценарии F–H, L3 на копии 1С, устройство | инфо | — | перепроверка на этапах F–H |
| E-KI-12 | Ключи ARB без источника текста не внесены. Это `role_<code>_summary` (5 ролей), подпись «бургера» SCR-10, заголовок сетки SCR-50, «нет сети» SCR-50.7 и текст снекбара G-11 «Используйте аппаратный сканер» (RC-5). Тексты 7 ключей (`status_sync_*`, `status_link_*` и др.) предложены владельцем словаря и ждут вычитки. `ky`/`en` — копии `ru` (Q-007) | незначительная | открыт; в коде — ближайшие существующие ключи | владелец 02 §7 / 03 §16 (по 11 §4.4 для ролей) → `build_arb.py` → FE (одна строка в `app_router.dart:149` для G-11) |
| E-KI-13 | Документы отстают от кода: `docs/ci.md` (таблица сервисов compose: у `worker` нет `otp_pepper`, F-N-02); очередь `images.gc` не внесена в 06 §7.5 и `common/jobs/contracts/queues.ts`; причина not_done у T-SYNC-019 ссылается на уже закрытый E-KI-03 | инфо | открыт | владельцы `docs/ci.md`, 06, `trace_test_ids.py` |
| E-KI-14 | Покрытие Flutter (`--coverage`) после правок pos-app на этапе закрытия не перемерялось. Последнее значение — раунд 1, 83,9 % catalog domain+data | инфо | открыт | QA при следующем прогоне |

Открытых блокеров и критичных дефектов нет. Единственный critical ревью закрытия (RR-1) исправлен: `catalog_flow_test`
прошёл 2 раза из 2 (журнал 1626–1631).

### 3.2. Действующие допущения

Вопросы без ответа заказчика; работа идёт на допущениях 14. После правки RS-3 «Допущение» в 14 — это значение,
действующее в ТЗ и реализации до ответа.

| Q-NNN | Принятое допущение | Какие задачи от него зависят | Последствие при другом ответе |
|---|---|---|---|
| Q-010 | Имена объектов 1С `[ТИПОВО]`, allow-list OData по 05 §5 | RM-E-001, RM-E-011, RM-E-016 | правка маппинга и allow-list после приёмки API |
| Q-031 | Входящий обмен C-2 не выбран, `ONEC_INBOUND_ENABLED=false` | RM-E-013 | реализация RM-E-013 (8 у.е.) |
| Q-040 | Каталог синтетический (образцов заказчика нет) | RM-E-005, RM-E-011 | повтор бенчмарка и загрузки на данных заказчика |
| Q-181 | Защита экрана на всех полях PIN/OTP | AU-16, FIX-EF-09 | одна точка изменения (`core/session`) |
| Q-298…Q-324 | см. §3.3 | — | — |

### 3.3. Новые вопросы заказчику (14 v1.5–1.6: Q-298, Q-299, Q-310…Q-324)

17 вопросов появились при реализации этапов D–E. Полный текст, варианты и сроки — `14_OPEN_QUESTIONS.md` (§3.2,
§3.3, §3.5, §3.6; трассировка §9). До ответа действует значение из столбца «Допущение» 14 — оно же реализовано.
Q-297 не использован.

| Q | Тема | Вопрос (кратко) | Действует до ответа (14, «Допущение») | Кто отвечает |
|---|---|---|---|---|
| Q-298 | безопасность | Учитывать ли аварийный код входа в лимитах OTP номера | не учитывать; собственные лимиты аварийного кода и step-up | владелец магазина |
| Q-299 | безопасность | Когда аннулировать прежний OTP при запросе нового | сразу при выпуске нового. 09 §4.4 и §5.3 нормативно говорят иначе, поэтому там стоят пометки RS-2 | владелец + SEC |
| Q-310 | безопасность | 5 неверных PIN — на пользователя или на устройство | на пользователя. 09 §9.6 и 08 §4.1.8 нормативно — на устройство, поэтому стоят пометки RS-2 | владелец + SEC |
| Q-311 | безопасность | Длина PIN клиента: 4 или 4–6 | экран — 4 цифры у `customer`, 6 у `staff`; сервер принимает 4–6 | владелец |
| Q-312 | безопасность | Приглашение на номер действующего клиента | отказ `409 PHONE_ALREADY_REGISTERED (customer_account)`, перевод — назначением роли | владелец |
| Q-313 | безопасность | Может ли `admin` назначить роль `admin` без `owner` | разрешено с причиной и аудитом; себе — нельзя | владелец |
| Q-314 | безопасность | Статус после разблокировки `pending_activation` | `active` (буквально 08 §4.18.3) | владелец |
| Q-315 | безопасность | Какой телефон карточки 1С подтверждён для самопривязки | только основной телефон из полной синхронизации | владелец + SEC |
| Q-316 | безопасность | Допустим ли вывод точного остатка клиентом через `/inventory/check` | допустимо в R1, ответ без чисел, лимит RL-CART | владелец |
| Q-317 | 1С | Нет строки в срезе остатков — 0 или «неизвестно» | нет строки → `unknown`, добавление в корзину запрещено (10 INV-052). Строка, исчезнувшая из успешного среза, → 0 | 1С-специалист + владелец |
| Q-318 | 1С | Бывают ли отрицательные остатки в 1С | нет; значения отдаются как есть, в фильтре и сортировке — `greatest(available,0)` | 1С-специалист |
| Q-319 | 1С | Срезы цен и остатков — методы HS или OData | OData учётной записью `pos_integration` | 1С-специалист |
| Q-320 | инфраструктура | Ручной `full`/`reconcile` — сразу или в ночном окне | сразу, с предупреждением на SCR-43 | владелец + 1С-специалист |
| Q-321 | дизайн | «В корзину» без слова «сом» на узких экранах | допустимо; экранный диктор получает полный текст | владелец |
| Q-322 | дизайн | Кнопки «Обновить» в строках SCR-43 | только кнопки нижней зоны | владелец |
| Q-323 | дизайн | Один экран первой установки PIN сотрудника | один экран SCR-04 | владелец |
| Q-324 | инфраструктура | Идентификаторы публикации и ключи подписи | `com.example.optomstroy` только для разработки, к релизу не допускается (RM-H-007) | владелец |

## 4. Условия перехода дальше

### 4.1. Статус ворот G-E — «жёлтый»

| Условие G-E (13 §3.5) | Выполнено? | Доказательство |
|---|---|---|
| RM-E-001…010, 014, 015, 017 закрыты | **нет, частично** | По коду задачи реализованы, тесты зелёные (§2.1 № 1, 5–8). Оговорки E-KI-01 (RM-E-017) и E-KI-03 (RM-E-001) сняты. Не закрыты по окружению: RM-E-003 п. 3 (Caddy); RM-E-008 п. 3, RM-E-009 п. 3, RM-E-010 п. 2–3 (устройство, сканер). RM-E-014 п. 4 — нет integration-шага (E-KI-09) |
| RM-E-011 — отчёт сверки (реальный или явно «на фикстурах») | да, на фикстурах | §2.6; журнал 570–600, 1401–1404 |
| RM-E-016 — протокол приёмки или отчёт «API 1С не получен» с последствиями и решением по §3.12 | да, отчёт «API 1С не получен» → **G-E не выше «жёлтого»** | §2.7, §4.2; `E_onec_extension_acceptance.md` §5–§6 |
| RM-E-012 — тесты зелёные, покрытие ≥ 80 % | **частично** | Тесты зелёные: `test:all` 849/0, `flutter test` 1298, golden 164, `catalog_flow_test` 2 из 2. Покрытие backend 90,23 %, Flutter catalog 83,9 % (раунд 1). Но **гейт `check_no_double_money.sh` красный** (F-N-01). Android не выполнен, CI на GitHub не запускался |
| Бенчмарк поиска приложен | да | §2.5: повтор после исправлений, p95 135,2 мс (синтетика, машина разработчика) |

Обоснование «жёлтого» по 13 §6.2:
- блокеров и критичных дефектов в открытом состоянии нет. RR-1 закрыт, все blocker и critical раундов 1–2 закрыты
  (`E_review.md` §15–§17);
- открыты существенные F-N-01 (красный гейт MNY-002) и RC-1 (офлайн-выход без отзыва серверной сессии). Остальные
  открытые пункты незначительные. У каждого есть план (§3.1);
- RM-E-016 — путь «API 1С не получен»: по 13 §3.5 выше «жёлтого» нельзя, даже если всё остальное будет закрыто.

«Жёлтый» допускает старт Backend/ONEC-задач этапа F (13 §4.3 п. 2, §6.2). Flutter-дорожка F по 13 §4.3 п. 2
начинается «после закрытия ворот»: ей нужны работающие эндпоинты на тест-контуре.

До начала F рекомендуется:
- устранить F-N-01, чтобы обязательный гейт MNY-002 стал зелёным;
- запланировать RC-1 (SS-07).

До «зелёного» нужны:
- шаг «Очистить недавние» (E-KI-09);
- проверки на Android и HID;
- `curl -I` через Caddy;
- прогон CI на GitHub;
- ключи ARB без источника текста (E-KI-12);
- **приёмка API 1С** (без неё «зелёный» недостижим).

G-D пересматривается по дополнению к отчёту D (E-KI-10). Там G-D остаётся «красным»: Android и SMSPro.

### 4.2. Последствия RM-E-016 п. 5 («API 1С не получен») и решение по §3.12

Подробно — `E_onec_extension_acceptance.md` §5, §6.

- **Чтение (этап E).** Не проверены на данных заказчика:
  - реальный инкремент по плану обмена;
  - фото через HS;
  - сверка количеств.

  Имена объектов 1С остаются `[ТИПОВО]` (Q-010), риск «маппинг не работает» не снят. Каталог, поиск и офлайн-API
  проверены только на синтетике и фикстурах.
- **Запись (этапы F/G).** Заказы, оплаты, QR, клиенты и возвраты будут проверяться на `FakeOnecGateway`. До приёмки
  не будут проверены:
  - идемпотентность по `externalId` на стороне 1С;
  - поведение при блокировках;
  - автоскидки.

  Без принятого API или решения о фазе 0 пилот (этап I) невозможен.
- **Нагрузка.** Замер 18 §7.4 не выполнен; интервалы D-29 — значения по умолчанию.
- **Решение по §3.12.**
  - Запасная фаза 0 («ручное оформление без канала записи») сейчас не включается.
  - `ONEC_ODATA_WRITE_ENABLED=false`, `QR_PROVIDER=none` на тест-контуре до приёмки методов QR.
  - Если к интеграционным тестам F API не получен или не принят, владелец магазина выбирает: ждать API (пилот
    сдвигается) или принять фазу 0 (ADR в RM-B-002).

### 4.3. Что требуется от заказчика

| Действие / вопрос | Для какой задачи | Срок (ворота) |
|---|---|---|
| Специалист 1С передаёт API — расширение по `18_ONEC_API_REQUEST.md` — и адрес с учётными данными через секрет-хранилище (O-05, RM-B-014) | RM-E-016, RM-E-011, F | до интеграционных тестов F; к G-F — принятое расширение |
| Тестовая копия базы 1С (RM-A-006, O-05) и пользователь `pos_integration` только для чтения (O-06) | RM-E-016, RM-E-011 | до G-F |
| HID-сканер для ручного теста (RM-A-008) и Android-устройство для замеров NFR-PERF-003/006 | RM-E-008, 009, 010, 012 | для «зелёного» G-E; до этапа H |
| Разрешение на установку Docker на машине разработки (тест-контур compose + Caddy) | RM-E-003 п. 3, RM-C-012 | для «зелёного» G-E |
| Освободить место на дисках машины разработки: сейчас свободно C: ~2,9 ГБ, D: ~7,3 ГБ | Android-эмулятор (в текущем окружении запускать запрещено), будущие прогоны и бенчмарки | при первой возможности |
| Аккаунт SMSPro (Q-029, RM-A-004) | остаток RM-D-002 п. 2 | до этапа H |
| Ответы на новые вопросы 14: Q-298, Q-299, Q-310…Q-324 (§3.3), а также Q-010, Q-040, Q-181. В первую очередь — Q-299 и Q-310: реализация расходится там с нормативным текстом 09/08 (пометки RS-2); Q-316…Q-319 — каталог и 1С | §3.2, §3.3 | без ответа действуют допущения 14; до G-F — Q-299, Q-310, Q-316…Q-319; Q-324 — до RM-H-007 |
| Образцы каталога (Q-040) для повтора бенчмарка на реальных данных | RM-E-005, RM-H-004 | до этапа H |

| Тексты строк без источника и вычитка 7 предложенных текстов: `role_<code>_summary`, «бургер» SCR-10, заголовок сетки SCR-50, «нет сети» SCR-50.7, снекбар G-11; перевод `ky`/`en` (Q-007) | E-KI-12, RM-E-007, RM-E-010 | до этапа H (перевод — R2 по Q-007) |

Действия команды (не заказчика):
- F-N-01 — гейт MNY-002 (FE);
- RC-1 / SS-07 — отложенный отзыв сессии при офлайн-выходе (FE + SEC);
- внести ключи ARB после получения текстов (владелец 02 §7) и заменить временный ключ G-11 (FE);
- `docs/ci.md`, 06 §7.5 и `queues.ts` (`images.gc`), причина T-SYNC-019 (E-KI-13);
- шаг integration «Очистить недавние» (E-KI-09);
- перемерить покрытие Flutter (E-KI-14).

Сделаны при закрытии остатков: ключи `stock_badge_*` и ещё 55 ключей 03 §16.7 (ADR-097); поля выгрузки в OpenAPI
1.1.0 (FIX-EF-01); дополнение к отчёту D. `devCode` в контракт сознательно не внесён: 09 §4.6.

### 4.4. Решения, принятые на этапе

ADR, добавленные в `docs/specification/15_DECISION_LOG.md` (приложение Д) при синхронизации ТЗ, статус «Принято»:
- ADR-088 — схема и доставка авторизации (миграция 0003);
- ADR-089 — конвейер применения 1С;
- ADR-090 — фото;
- ADR-091 — планировщик и ручной запуск синхронизации;
- ADR-092 — Catalog API;
- ADR-093 — офлайн-выгрузка каталога и локальная схема;
- ADR-094 — поиск;
- ADR-095 — Flutter: порты и размещение;
- ADR-096 — API авторизации, регистрации, профиля и администрирования этапа D;
- ADR-097 — выравнивание машинных контрактов с ТЗ и реализацией: OpenAPI 1.0.0 → 1.1.0 (аддитивно), ключи ARB
  03 §16.7 в 02 §7 и `contracts/l10n` (добавлен при закрытии остатков; 15 v1.9).

## 5. Приложения

### 5.1. Независимая проверка — `docs/reviews/E_review.md`

Проверяющий — отдельный агент, не автор кода. Дата: 2026-10-22. Раунд 1 — 14:40–15:25, раунд 2 — 15:56–16:40.

Методика:
- шесть направлений: onec-sync, api, security, flutter-ui, flutter-data, trace — плюс повторный прогон (fresh-run);
- на каждое серьёзное замечание — два скептика.

| Показатель | Число |
|---|---|
| Найдено замечаний (подтверждено + опровергнуто) | 51 |
| Подтверждено | 50: 1 blocker, 3 critical, 25 major, 21 minor (по исходной оценке) |
| Опровергнуто | 1 (E-flutter-ui-6 — режим `owner`, плановое промежуточное состояние) |
| Исправлено (после раунда 2 → после закрытия остатков) | 43 → **47**: добавились E-flutter-ui-1, E-flutter-ui-2, E-flutter-data-6, E-trace-9 |
| Исправлено частично | 4 → **2**: E-flutter-ui-5 (права из токена — бэклог FE), E-flutter-ui-9 (не перепроверялось) |
| Не исправлено (осталось) | 3 → **1**: E-trace-6 (minor → E-KI-09) |
| Новые наблюдения проверяющего (скептиками не проверялись) | 6: R1-N-01…04, R2-N-01, R2-N-02. После закрытия: R2-N-02 (E-KI-03), R2-N-01 (E-KI-07) и R1-N-01 (E-KI-02, по коду) закрыты; R1-N-03 закрыт в ТЗ; R1-N-02 (E-KI-05) и R1-N-04 (E-KI-06, частично) открыты |

Вывод раунда 2 (`E_review.md` §13): G-E можно выставлять «на жёлтый», не «на зелёный». Все blocker и critical закрыты.
По E-onec-sync-1 тест AC-SYNC-011 зелёный, но проверяющий не проверял, что тест падает на старом коде.

**Закрытие остатков** (`E_review.md` §14–§17). Прогон проверяющего 19:20 нашёл две красные команды:
`catalog_flow_test` и трассу T-CAT-032. Затем было ревью закрытия по направлениям RR (прогон), RC (код) и RS (ТЗ и
контракты).

| Показатель | Число |
|---|---|
| Замечаний ревью закрытия | 21: 1 critical (RR-1), 4 major (RC-1, RS-1, RS-2, RS-3), 16 minor |
| Подтверждено верификацией (serious) | 5 из 5; у RS-3 опровергнута часть про 08 §3.6 / INV-052 |
| Исправлено | 17: RR-1, RR-2, RC-2, RC-3, RC-6, RC-7, RS-1…RS-11 |
| Частично | 2: RR-3 (9 `*.g.dart`), RC-4 (`docs/ci.md`) |
| Не исправлено | 2: RC-1 (офлайн-выход, SS-07), RC-5 (ключ ARB G-11) |
| Новые наблюдения финального прогона | F-N-01 (гейт MNY-002 красный из-за `panel_page.dart`), F-N-02 (`docs/ci.md`) |

Оговорка: раздел «Закрытие остатков» составил автор итоговых документов, а не независимый проверяющий. Исправления
Fix2 независимо не перепроверялись, их подтверждает только финальный прогон.

### 5.2. Синхронизация ТЗ — `docs/stages/E_spec_sync.md`

Разобраны 381 пункт: 212 из `E_spec_questions.md` и 169 из `D_spec_questions.md`.

| Показатель | Этап E | Этап D | Всего |
|---|---|---|---|
| Техническая часть внесена в ТЗ (A, A+B, A+B\*, A+C) | 154 | 99 | 253 |
| С вопросом заказчику — новым или существующим | 16 | 21 | 37 |
| Решено, неактуально или бэклог | 53 | 59 | 112 |

- **Новые Q-ID в 14** (v1.5, реестр 209 → 226): Q-298, Q-299, Q-310…Q-324 — 17 вопросов. Q-297 не использован.
- **Изменены документы ТЗ:** 02, 03, 05, 06, 07, 08, 09, 11, 12, 13, 14, 15, 16 и `visual/navigation.md`. Ядро R0 и
  бизнес-правила не менялись; 17 не менялся.
- **Изменены контракты:**
  - `contracts/enums.json` 1.0.0 → 1.1.0;
  - пример `Image` в OpenAPI.
- **Не менялись:** `contracts/l10n`, `permissions.yaml`, фикстуры 1С.
- Бэклог реализации — `E_spec_sync.md` §3.

**После синхронизации, при закрытии остатков:**
- OpenAPI 1.0.0 → 1.1.0 (ADR-097, 08 v1.12, CHANGELOG);
- `contracts/l10n` пересобран: +59 ключей, ICU plural `cart_fab_a11y*`;
- документы ТЗ уточнены по ревью закрытия (RS-1…RS-10, RC-4): 00, 02, 03, 07, 08 (v1.13), 09, 12, 13, 14, 15, 16,
  README, `visual/navigation.md`;
- ядро, бизнес-правила, `permissions.yaml`, `enums.json` и фикстуры 1С не менялись.

Гейты после синхронизации зелёные (журнал 1415–1428). Повторной независимой проверки синхронизации нет.

### 5.3. Протокол ручного теста HID-сканера на Windows (RM-E-010 п. 3) — **не выполнен**

Сканера из RM-A-008 нет. Шаблон для выполнения, когда сканер появится:

| № | Шаг | Ожидаемый результат (02 SCR-42, 13 RM-E-010) | Факт |
|---|---|---|---|
| 1 | SCR-42 → «Сканер»: окончание Enter, порог 50 мс; «Тест сканера» → сканировать EAN-13 | «Найден: … · арт. …» | не выполнено |
| 2 | SCR-10, фокус вне полей, роль `seller`: сканировать известный код | открывается SCR-14 найденного варианта | не выполнено |
| 3 | Роль `cashier` (по умолчанию «сразу в корзину»): сканировать известный код | +1 шаг в черновике, снекбар «Отсканировано … · Отменить» | не выполнено |
| 4 | Сканировать неизвестный код | снекбар «Штрихкод … не найден», SCR-11 с кодом | не выполнено |
| 5 | Ручной ввод цифр с клавиатуры + Enter | скан не распознаётся, запроса нет | не выполнено |
| 6 | Сканер с окончанием Tab при настройке Enter | подсказка «Сканер не отправил окончание» | не выполнено |
| 7 | Скан при открытом нампаде SCR-16 или диалоге | скан игнорируется | не выполнено |

В протоколе `docs/stages/E_hid_manual_test.md` (создаётся при выполнении) записываются:
- модель сканера и версия Windows;
- результат и время каждого шага.

### 5.4. Прочие документы этапа

- Журнал прогонов — `docs/stages/E_test_run.log`, разделы:
  - «Итог интеграции backend этапа E»;
  - «Интеграция Flutter этапа E»;
  - «Исправление замечаний ревью этапа E — backend»;
  - «Перепроверка после ревью, раунд 1»;
  - «Исправление замечаний ревью этапа E, раунд 2»;
  - «Перепроверка после ревью, раунд 2»;
  - «Свежий прогон для отчёта этапа E»;
  - «Прогон после закрытия остатков» (независимый проверяющий, 19:20);
  - «Финальный прогон этапа E» (после Fix2, 20:43).
- RM-E-011 — `docs/stages/E_initial_import_report.md`; RM-E-016 — `docs/stages/E_onec_extension_acceptance.md`.
- Вопросы к ТЗ — `docs/stages/E_spec_questions.md`, `docs/stages/D_spec_questions.md`; синхронизация —
  `docs/stages/E_spec_sync.md`.
- Бенчмарк — `docs/perf/E_search_benchmark.md` (§8 — повтор после ревью).
- Видео и скриншотов сценариев нет. Golden-эталоны — `pos-app/test/**/goldens/`.

---

## Дополнение (2026-10-22, оркестратор, после отчёта)

- **F-N-01 закрыт.** `pos-app/lib/app/router/panel_page.dart`: у `Animation<double>` (геометрия анимации перехода, не деньги) стоят пометки `money-double: allow — анимация перехода, не деньги`. Проверка `bash scripts/check_no_double_money.sh` — EXIT=0 (0 совпадений в pos-app/lib и pos-api/src). После правки `flutter analyze` и `flutter build windows --release` — EXIT=0. Подробности — раздел «Финальная правка оркестратора» в конце `E_test_run.log`. Записи о красном гейте MNY-002 выше (§2, §3.1, §4) относятся к состоянию до этой правки.
- **RC-1 (SS-07)**, офлайн-выход без отзыва серверной сессии, перенесён в этап F. Решение укладывается в текущий контракт: тип outbox `auth.logout` (ядро §19.4) хранит refresh в защищённом хранилище до восстановления сети, затем выполняются `POST /auth/refresh` и `POST /auth/logout`, после чего секреты удаляются.
- Ворота G-E — **«жёлтый»**: RM-E-016 «API 1С не получен»; проверки на устройствах Android/iOS, Caddy и CI не выполнялись.

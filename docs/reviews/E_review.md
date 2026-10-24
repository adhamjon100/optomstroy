# Независимая проверка этапа E «Catalog» (раунды 1 и 2, закрытие остатков)

Дата: 2026-10-22. Проверяющий: независимый агент (13 RM-E-012, выход `docs/reviews/E_review.md`).
Машина: Windows 11 Pro 10.0.26200, Node 24, Flutter 3.38.7 / Dart 3.10.7. Android-устройств, macOS, реальной 1С и
тестовой копии 1С нет. Все прогоны — на FakeOnecGateway, фикстурах `contracts/onec/fixtures` и синтетическом каталоге:
**на фикстурах, не реальная интеграция**.

Код при перепроверках не менялся. Записаны только этот отчёт и разделы «Перепроверка после ревью, раунд 1 / раунд 2» в
`docs/stages/E_test_run.log`.

> **Актуальное состояние — раздел «Закрытие остатков» в конце документа (§14–§17).** §8–§13 — запись раунда 2,
> разделы 1–7 — запись раунда 1; обе без изменений. Раздел «Закрытие остатков» составлен автором итоговых документов
> этапа по данным ревью закрытия, исправителей и финального прогона (не независимым проверяющим).

Основание проверки: 05_ONEC_INTEGRATION, 07_DATA_MODEL, 08_API_SPECIFICATION + `contracts/openapi/pos-api.v1.yaml`,
09, 10_POS_BUSINESS_RULES, 11_SECURITY_PRIVACY + `contracts/rbac/permissions.yaml`, 02 (SCR-10…17, 42, 43, 45, 50),
03, 06, 12, 13 §3.5 (RM-E-001…017, ворота G-E), 16, ядро R0 v1.9 (приоритет §24 > … > §16 > базовый текст).

## 1. Методика

1. **Шесть направлений ревью** — по каждому отдельный проверяющий:
   - `onec-sync` — цикл `onec.changes`, фаза 0, outbox, повторы и таймауты (05, ядро §22.8);
   - `api` — каталог, поиск, офлайн-синхронизация `/catalog/sync/{entity}` (08, 07, 10);
   - `security` — лимиты частоты, field-level остатков, локальные данные, защита экрана (11, 08 §2.9);
   - `flutter-ui` — экраны SCR-10…17, 42, 43, 45, 50, навигация, a11y, golden (02, 03, navigation.md);
   - `flutter-data` — drift-кэш, outbox клиента, планировщик синхронизации, сессия (07 §11, 06 §6.7);
   - `trace` — прослеживаемость T-ID → тест, выходы RM-E-012, CI, миграции, отчёты (12, 13).
2. **Повторный прогон** (`fresh-run`) всех проверок журнала этапа E на чистом окружении.
3. **Два скептика** на каждое серьёзное (blocker/critical/major) замечание: каждый независимо пытается его
   опровергнуть по коду и ТЗ и, где можно, воспроизводит. Замечание считается подтверждённым, если ни один не
   опроверг. Оценки скептиков приведены в таблице, когда они отличаются от исходной.
4. **Исправления** выполнили два исправителя (backend и Flutter). Отчёты — `docs/stages/E_test_run.log` (раздел
   «Исправление замечаний ревью этапа E — backend»), `docs/stages/E_spec_questions.md` (FIX-E-01…07, FIX-EF-01…13).
5. **Перепроверка (этот раунд)**: полный свежий прогон и сверка каждого подтверждённого замечания с текущим кодом и
   тестом. Результаты прогона — `docs/stages/E_test_run.log`, раздел «Перепроверка после ревью, раунд 1».

## 2. Повторный прогон после исправлений (раунд 1)

| Проверка | Результат | Итог |
|---|---|---|
| pos-api `lint`, `build`, `madge`, `check:permissions` | EXIT=0; 0 циклов; 77 кодов / 7 ролей | зелёный |
| pos-api `test:all` (21 набор) | 821 passed, 6 skipped, 0 failed | зелёный |
| pos-api `test:cov:e` | 481 passed; строки 90.18 %, ветви 75.57 %; пороги 80/75 выполнены | зелёный |
| pos-api `test:cov:d` | 361 passed; строки 97.92 % | зелёный |
| local-stack `smoke` / `auth-smoke` / `catalog-smoke` | 10/10, 15/15, 22/22 PASS | зелёный |
| миграции `run-sql --repeat-strict` (prod и dev/test) | 0 изменений; 63/63 и 64/64 таблиц, 45/45 enum; check_ddl_behavior OK | зелёный |
| `check_no_double_money.sh` | 0 совпадений | зелёный |
| **`check_secrets.py`** | **3 находки в pos-app/test, EXIT=1** | **красный** |
| `build_openapi.py --check`, `check_api_paths.py`, `check_enums.py`, `check_arb_keys.py` | EXIT=0 | зелёный |
| `check_repo_layout.py`, `check_layers.py`, `sync_contracts.py --check`, `check_onec_paths.py` | EXIT=0 (0 ошибок) | зелёный |
| `flutter analyze` | No issues found | зелёный |
| `flutter test --concurrency=2` | 1237 passed | зелёный |
| golden (`--tags golden`) | 162 passed | зелёный |
| `flutter test --coverage` | catalog domain+data 83.9 %; все features/*/data 83.1 %; core/sync 88.2 % | зелёный |
| `flutter build windows --release` | собрано | зелёный |
| integration `catalog_flow_test` (Windows, свой стек) | +2 passed | зелёный |
| integration `auth_flow_test`, `boot_test` | +3, +1 passed | зелёный |
| **integration `admin_invite_flow_test`** | **1 из 2 корректных запусков красный** (необработанная асинхронная ошибка в tearDownAll, R1-N-01) | **нестабильный** |
| `dart format --set-exit-if-changed` (вне CI) | 7 сгенерированных `*.g.dart` не отформатированы | инфо |

Не выполнялось (окружение): Android/iOS, камера, ручной тест HID, 50 000 SKU на устройстве, Caddy / `curl -I`, прогон
CI на GitHub Actions.

## 3. Подтверждённые замечания и их статус после исправлений

Обозначения: `sev` — исходная важность; в скобках — оценки скептиков, если они ниже. Статус — по фактическому
состоянию кода и тестов на момент перепроверки.

### 3.1. Повторный прогон (fresh-run)

| id | sev | файл | суть | доказательство | статус |
|---|---|---|---|---|---|
| E-fresh-run-1 | major | `scripts/check_secrets.py` (находки в тестах D–E) | Гейт секретов красный: 7 срабатываний `generic-secret-assignment` на тестовых значениях | было 7 находок, EXIT=1 | **частично**: 4 строки pos-api помечены `check-secrets: allow`; 3 строки `pos-app/test` (settings_repositories_test.dart:322, :349; sync_status_screen_test.dart:221) не помечены — мой прогон: находок 3, EXIT=1 |
| E-fresh-run-2 | major | `scripts/check_no_double_money.sh` | MNY-002 красный: 22 строки pos-api/src | EXIT=1 | **исправлено**: пометки `money-double: allow` с причиной; мой прогон 0 совпадений, EXIT=0; шаг добавлен в CI job api-integration |
| E-fresh-run-3 | minor | `docs/repo_layout.md` §2 | Каталог `docs/ops/` не описан → check_repo_layout EXIT=1 | ошибка уровня 2 | **исправлено**: мой прогон — 0 ошибок |
| E-fresh-run-4 | minor | `docs/stages/E_test_run.log` | Запись test:cov:e сделана до последних правок | 452 vs 454 теста | **исправлено**: новая запись исправителя и моя (481 passed, строки 90.18 %); старая запись помечена как устаревшая в разделе перепроверки |

### 3.2. Синхронизация с 1С (onec-sync)

| id | sev | файл | суть | доказательство | статус |
|---|---|---|---|---|---|
| E-onec-sync-1 | blocker (скептики: major, critical) | `pos-api/src/sync/apply/onec-changes.service.ts` | Singleton цикла `onec.changes` — xact-lock, снимается на COMMIT, ack после него; параллельный цикл теряет изменения 1С | воспроизведено: 3 из 4 изменений потеряны | **исправлено**: сессионный `pg_try_advisory_lock` на выделенном соединении на весь цикл (since → страницы → COMMIT → ack → `sync_node_state`), снятие в `finally`, при сбое unlock соединение уничтожается; `since` читается под lock. Тест AC-SYNC-011 `test/sync-apply/onec-changes-review.spec.ts` (плановый и ручной цикл → `skipped_locked` без обращения к 1С, изменения не теряются) — зелёный в моём `test:all`. Что новый тест падает на старом коде, проверено только рассуждением (исправитель это тоже не проверял) |
| E-onec-sync-2 | major (скептик: minor) | `onec-changes.service.ts`, `sync-alerts.service.ts` | В режиме расширения недоступность 1С не оставляет следов и не даёт уведомления | воспроизведено: runs/errs без изменений | **исправлено**: `recordFailure` вне откатанной транзакции (failed + `sync_errors` ONEC_UNAVAILABLE/ONEC_REJECTED, при сбое до первой строки — по сущностям плана); алерт SYNC-038 п. 1 по `unreachable_since` ≥ `SYNC_ALERT_UNREACHABLE_MIN` в `sweep()`; тесты первой и второй страницы (FIX-E-07) |
| E-onec-sync-3 | major (скептик: minor) | `pos-api/src/sync/apply/catalog-full-load.service.ts` | Инкремент фазы 0 помечает удалёнными пропущенные в листинге ключи без сверки `$count`; пометка не снимается | воспроизведено | **исправлено**: пометка только при совпадении числа живых ключей с `$count` (иначе `COUNT_MISMATCH`, partial); у помеченного ключа сбрасывается `data_version` → при появлении дочитывается; 2 теста. `$orderby` не добавлен — нужно решение по ТЗ (FIX-E-03) |
| E-onec-sync-4 | major (скептик: minor) | `pos-api/src/jobs/outbox/outbox-dispatcher.ts` | Возраст outbox считается от `created_at`, ручной повтор окно не сдвигает | код | **исправлено**: возраст от `max(created_at, последний аудит outbox.retried)`; тест worker.int (dead 30 ч → retry → временная ошибка → pending). Явная колонка — предложение владельцу 07 (FIX-E-04) |
| E-onec-sync-5 | major | `pos-api/src/sync/scheduler/scheduler.config.ts` | retryLimit=5 с экспонентой; `consecutive_errors` растёт на каждую попытку | код + тест «3 попытки» | **исправлено**: `retryLimit=2`, `retryDelay=60`, без backoff; промежуточные попытки не трогают `sync_state` (`updateState=last`), `retryLimit` передаётся из pg-boss (`includeMetadata`). Паузы реализованы как 60 + 60 с («повторы на 1-й и 2-й минуте») — одно из возможных прочтений «паузы 1 и 2 мин»; расхождение 06 §7.5 ↔ 05 SYNC-029 вынесено в FIX-E-01 |
| E-onec-sync-6 | minor | `onec-changes.service.ts:157` | `hasMore=true` + `cursor=null` считалось последней страницей → ack непрочитанного | код | **исправлено**: INVALID_RESPONSE → ROLLBACK без ack; валидатор шлюза отклоняет сочетание; тест |
| E-onec-sync-7 | minor | `pos-api/src/integrations/onec/onec-odata.client.ts` | Страницы OData читались с таймаутом 30 с вместо 60 с | код | **исправлено**: `ODATA_PAGE_TIMEOUT_MS = 60_000` для `list`/`pages`; `$count` — `ONEC_TIMEOUT_MS`; тест |

### 3.3. API каталога и поиска (api)

| id | sev | файл | суть | доказательство | статус |
|---|---|---|---|---|---|
| E-api-1 | critical (скептики: major, major) | `catalog-products.service.ts`, `search.repository.ts`, `search-cursor.ts` | При `customer_stock_display=status` точный `available` читается из `nextCursor` (base64url JSON) | воспроизведено: обход каталога с limit=1 | **исправлено**: курсоры каталога и поиска шифруются AES-256-GCM (`src/catalog/common/cursor-seal.ts`, ключ из кольца секретов, детерминированный IV), e2e для customer в режиме status. Остаточно: длина шифртекста равна длине открытого текста — по ней видно число цифр значения (R1-N-02, minor); двоичный поиск через `POST /inventory/check` — решение по ТЗ (FIX-E-06) |
| E-api-2 | major | `pos-api/src/catalog/search/search.service.ts` | На стадии trgm продолжение по курсору пересчитывает исправление слов и теряет строки | воспроизведено: 3 из 77 | **исправлено**: курсор хранит вариант trgm (`cw`: исправленные слова или raw), продолжение без пересчёта; e2e: постранично = одна страница limit=200 |
| E-api-3 | major (скептик: minor) | `pos-api/src/catalog/sync/catalog-sync.*` | Курсор офлайн-синхронизации не привязан к области видимости (виды цен, режим остатков) | воспроизведено | **исправлено**: отпечаток области в курсоре, несовпадение → 409 `VERSION_CONFLICT reason=cursor_expired`; e2e. Отдельная причина `scope_changed` — решение по ТЗ (FIX-E-02) |
| E-api-4 | major (скептики: minor, none) | `catalog-products.service.ts`, `search.repository.ts` | Сумма `available` по вариантам с отрицательными значениями скрывает товар из `inStock` | воспроизведено | **исправлено**: `PRODUCT_AVAILABLE_SUM` = сумма `greatest(available, 0)` во всех местах каталога и поиска; e2e |

### 3.4. Безопасность (security)

| id | sev | файл | суть | доказательство | статус |
|---|---|---|---|---|---|
| E-security-1 | major (скептик: minor) | `pos-api/src/admin/shared/admin-rate-limit.ts` | RL-ADMIN обходится сменой регистра пути | воспроизведено: 10 × 200 | **исправлено**: путь приводится к нижнему регистру без query/fragment; admin-spec: /ADMIN, /Admin/Users, /admin/USERS → 200,200,200,429 |
| E-security-2 | major | `pos-api/src/common/rate-limit/` | Нет RL-READ / RL-SEARCH | grep пусто | **исправлено**: `HttpRateLimitModule` (APP_INTERCEPTOR после guard'ов, окно 1 мин в памяти, ключ userId; RL-READ 600, RL-SEARCH 120, RL-CART 300; маршруты сверяются тестом с `x-rate-limit-group`; 429 с `Retry-After`). Остаток: двоичный поиск через `/inventory/check` только замедлен — FIX-E-06 |
| E-security-3 | major | `pos-app/lib/features/catalog/presentation/state/catalog_prefs.dart` | История поиска не очищается при выходе / смене пользователя | трассировка кода | **исправлено**: `build()` следит за `catalogSessionUserProvider` (← `sessionUserIdProvider`); тест app_wiring_test |
| E-security-4 | minor | `step_up_dialog.dart`, `session_lock_overlay.dart` | `SecureContent` только на SCR-02/08 | grep | **исправлено**: порт и виджет перенесены в `core/session`, защищены все поля PIN/OTP (12 мест); Q-181 за заказчиком (FIX-EF-09) |

### 3.5. Flutter: экраны и навигация (flutter-ui)

| id | sev | файл | суть | доказательство | статус |
|---|---|---|---|---|---|
| E-flutter-ui-1 | critical (скептики: major, major) | `sync_connected_widgets.dart:120` | `context.go('/sync')` из шапки — тупик без «Назад» | widget-тест: canPop=false | **частично**: `context.push('/sync')`, тупика нет, widget-тест; side sheet 480 на expanded не сделан (FIX-EF-08) — остаток minor |
| E-flutter-ui-2 | major | `catalog_card_mapper.dart:92` | Клиент в режиме status видит статус наличия только иконкой, Semantics пустой; «Мало» не отличить | golden, код | **не исправлено**: в `contracts/l10n` нет ключей `stock_badge_in_stock` / `stock_badge_low` (проверено: есть только «Нет в наличии» и «Только в наличии»); литералы запрещены, контракты исправитель не меняет — нужно действие владельца ARB/03 (FIX-EF-04) |
| E-flutter-ui-3 | major | `catalog_workspace.dart:995` | Чип «Недавние» не показывается на SCR-12 | код + тест | **исправлено**: условие `!_isCategory` снято, подборка ограничена категорией; тест category_screen_test |
| E-flutter-ui-4 | major | `catalog_workspace.dart:342` | Поиск с SCR-12 → «Назад» ведёт в корень, лишний `q` | воспроизведено | **исправлено**: `push(/catalog/search?q&categoryId)`, уточнение — replace; тест. Чип области UI-11-009 не сделан (FIX-EF-07) |
| E-flutter-ui-5 | major (скептики: minor, minor) | `pos-app/lib/app/router/guards/role_guard.dart` | G-7 реализован только для customer | код | **частично**: матрица `isPathAllowedForRole` для всех ролей по navigation.md, тесты по ролям; снекбара G-7 нет (нет ARB-ключей), permissions токена клиент не использует (FIX-EF-05) |
| E-flutter-ui-7 | major (скептики: minor, minor) | `seller_shell.dart:14` и др. | Глифы вкладок противоречат карте 03 §7.7 | код | **исправлено**: star, group, swap_horiz, receipt, account_circle, category; тест shell_icons_test. Противоречие 03 §7.7 ↔ navigation.md §2.2 — владельцам (FIX-EF-06) |
| E-flutter-ui-8 | minor | `app/di/overrides.dart:80-82` | SyncIndicator всегда компактный; golden без индикатора | golden | **исправлено**: вид по классу окна, индикатор в golden SCR-10/11 (состояние syncing) |
| E-flutter-ui-9 | minor | golden SCR-10/50 | Обрезка значимого текста | PNG | **частично**: бейдж и цена переносятся/масштабируются; «Выбрать вариант» 160 lp, лента «Недавние» SCR-50 compact, сайдбар SCR-50 — остались (FIX-EF-13) |
| E-flutter-ui-10 | minor | `catalog_workspace.dart:547-552` | Нет «Выйти» в меню профиля | код | **исправлено**: ConfirmDialog с фокусом на «Отмена» → logout; тест catalog_logout_test |
| E-flutter-ui-11 | minor | `product_details_screen.dart:144-185` | Шапка SCR-14 без категории/поиска, крошки из одного уровня | golden | **исправлено**: категория и поиск на compact/medium, полные крошки на expanded; 2 теста |
| E-flutter-ui-12 | minor | `customer_home_view.dart:607-618` | Нет двойного «Назад» на SCR-50 | grep | **исправлено**: `BackToExitScope` на SCR-10 и SCR-50 (Android); тест |
| E-flutter-ui-13 | minor | `customer_home_view.dart:702-708` | Бейдж корзины сливается с FAB | golden | **исправлено**: `AppBadgeTone.onPrimary`; эталон обновлён |

### 3.6. Flutter: данные и синхронизация (flutter-data)

| id | sev | файл | суть | доказательство | статус |
|---|---|---|---|---|---|
| E-flutter-data-1 | critical (скептики: major, major) | `pos-app/lib/core/database/daos/catalog_dao.dart` | `deleted[]` prices/barcodes/images не применялся (сервер шлёт uuid строки, клиент удалял по другим ключам) | воспроизведено | **исправлено**: схема drift v4, `server_id` + индексы в prices/barcodes/product_images_meta, удаление по `server_id`, миграция v3→v4 со сбросом курсоров, тесты миграций и движка. `id` в OpenAPI-схемах — владельцу 08 (FIX-EF-01) |
| E-flutter-data-2 | major (скептики: minor, minor) | `catalog_offline_bindings.dart`, `catalog_sync_engine.dart` | Фоновая загрузка не привязана к экземпляру БД при смене пользователя | тест с подменой (в реальной проводке вред меньше) | **исправлено**: прогон привязан к экземпляру БД, прерывание при смене, сброс на onSignedOut; 2 теста |
| E-flutter-data-3 | major (скептики: minor, minor) | `pos-app/lib/core/sync/outbox_queue.dart` | Владелец outbox проверялся один раз на проход | тест с подменой | **исправлено**: проверка владельца и `identical(db)` перед каждой записью и перед отправкой; обработчики пишут в захваченную БД; тест |
| E-flutter-data-4 | major (скептик: minor) | `pos-app/lib/core/sync/sync_scheduler.dart` | Холодный старт онлайн не делает инкремент | тест | **исправлено**: `onSignedIn` → `engine.start()` (продолжение загрузки или `/sync/status` + `since=`); тест |
| E-flutter-data-5 | minor | `outbox_queue.dart` | Правило dead расходится с 07 §11.2 | код | **исправлено**: 10 попыток, счёт только при ответе сервера; немедленный dead на постоянный 4xx оставлен как вопрос толкования (FIX-EF-03) |
| E-flutter-data-6 | minor | `pos-app/lib/core/session/session_controller.dart` | Нет предупреждения FLOW-009.E1; не очищаются данные прежнего пользователя | grep | **частично**: предупреждение перед «Выйти» и очистка при `establish` с другим `sub` сделаны; предупреждение на SCR-01 — нет ARB-ключа (FIX-EF-10) |
| E-flutter-data-7 | minor | `catalog_dao.dart:373-385` | Ретенция и VACUUM не выполнялись | grep | **исправлено**: `runMaintenance` раз в 7 дней из планировщика; тест (ключ app_meta — FIX-EF-02) |
| E-flutter-data-8 | minor | `catalog_remote_data_source.dart` | Нет CancelToken в поиске | grep | **исправлено**: отмена предыдущего запроса первой страницы; тест |
| E-flutter-data-9 | minor | `catalog_sync_engine.dart:243-276` | Смена `customer_stock_display` не перезагружает stock | grep | **исправлено**: `catalogStockScopeProvider` + перезагрузка без `since`; тест |

### 3.7. Прослеживаемость, CI, документы (trace)

| id | sev | файл | суть | доказательство | статус |
|---|---|---|---|---|---|
| E-trace-1 | major | `scripts/trace_test_ids.py` | Нет матрицы «T-ID этапа E → тест / not_done»; 93 из 113 ID без ссылок | собственный скрипт | **не исправлено**: `GROUPS = ('AUTH','REG','SESS','SMS','BIO')`, параметра этапа нет; `--summary` — только 178 ID этапа D. Обновлён лишь NOT_DONE для T-SEC-046 |
| E-trace-2 | major (скептики: minor, minor) | `docs/stages/E_catalog_report.md` | Нет выходов RM-E-012: отчёта этапа и отчёта ревью | `ls` | **частично**: `docs/reviews/E_review.md` создан этим раундом; `E_catalog_report.md` (таблица RM-E-*, статус G-E, последствия RM-E-016 п. 5, протокол HID) по-прежнему нет. Один скептик указал, что по 13 §6.3 отчёт этапа составляется после ревью, — это так, но для G-E он обязателен |
| E-trace-3 | major | `pos-app/lib/app/di/overrides.dart` | `scan_adds_to_cart` не влиял, порт корзины не подключён | код | **исправлено**: значение из `Settings.scanAddsToCart` (без значения — умолчание роли), `CartDraftScanCartPort` над `cart_items_draft`; тесты на собранных overrides (FIX-EF-11) |
| E-trace-4 | major | `pos-api/src/sync/images/image-processor.ts` | Валидация фото шире SEC-101 (TIFF/HEIF, 64 МБ, без лимита стороны) | воспроизведено | **исправлено**: jpeg/png/webp/gif, ≤ 10 МБ, сторона ≤ 8000, 64 Мп; тест T-SEC-046 `test/images/image-security.spec.ts` (FIX-E-05) |
| E-trace-5 | major (скептик: minor) | `.github/workflows/ci.yml` | CI не запускает наборы этапа E; coverage-gate по unit; миграции 0003+ не применяются | код CI | **исправлено в конфигурации**: psql применяет все `migrations/*.sql` по порядку; job `api-integration` (`test:cov:all`, `test:cov:e`, MNY-002, загрузка lcov); coverage-gate зависит от него. На GitHub Actions не запускалось — подтверждено только локальными прогонами тех же команд |
| E-trace-6 | minor | `pos-app/integration_test/catalog_flow_test.dart` | RM-E-014 п. 4 и замеры RM-E-008/009 п. 3 только unit-уровнем | grep | **не исправлено** (FIX-EF-12) |
| E-trace-7 | minor | `scripts/check_no_double_money.sh` | 22 ложных/безвредных срабатывания | разбор | **исправлено** (как E-fresh-run-2) |
| E-trace-8 | minor | `pos-api/src/db/migrator.ts` | Пропуск 0004 может дать разный порядок схемы | код | **исправлено**: `MIGRATION_OUT_OF_ORDER` до применения; test/db сценарий 7; NOTES.md §11 |
| E-trace-9 | minor | `docs/stages/D_authentication_report.md` | Отчёт D не обновлён после закрытия остатков D | `ls` | **не исправлено** |
| E-trace-10 | minor | `docs/stages/E_test_run.log` | Нет прогона покрытия Flutter для модулей E | grep | **исправлено документально**: проверяющий выполнил `flutter test --coverage` и записал разбор по группам в журнал (catalog domain+data 83.9 %, features/*/data 83.1 %, features/*/domain 80.3 %) |

## 4. Опровергнутые замечания

| id | sev | суть | почему опровергнуто |
|---|---|---|---|
| E-flutter-ui-6 | major | Роль owner получает режим seller (вкладка корзины, нет вкладки «Админ») | Факт верен, но это плановое промежуточное состояние: собственный набор веток owner (главный экран SCR-48, navigation.md §2.1/§14.7, ядро §9) по дорожной карте не входит в этапы D и E. Часть утверждения о недостижимости SCR-45 для owner не подтвердилась как требование этих этапов |

## 5. Новые наблюдения раунда 1

Скептиками не проверялись; приведены как наблюдения проверяющего.

| id | важность | суть | доказательство |
|---|---|---|---|
| R1-N-01 | minor (нестабильность гейта) | `integration_test/admin_invite_flow_test.dart` нестабилен: в 1 из 2 корректных запусков сценарий проходит, но в tearDownAll — необработанная асинхронная ошибка из `ScannerConfigController._load` (`core/hardware/hardware_providers.dart:43`, `unawaited(_load(store))`). Вероятно, `store.load()` читает настройки из БД прежнего пользователя после её закрытия при смене пользователя. В журнале 12:32 тест был зелёным | `.tmp/rv1/it_admin_invite_flow_test.out` (стек), повтор на свежем стеке — зелёный. Исходный текст ошибки скрыт assertion `stack_frame.dart:197` |
| R1-N-02 | minor | Зашифрованный курсор каталога и поиска сохраняет длину открытого текста: по длине видно число цифр ключа сортировки (`available`) — порядок величины, не значение | `src/catalog/common/cursor-seal.ts` (GCM без выравнивания длины) |
| R1-N-03 | инфо | Паузы повторов pull-прогонов — 60 + 60 с (повторы на 1-й и 2-й минуте); формулировка 05 SYNC-029 «паузы 1 и 2 мин» допускает и прочтение 60 + 120 с | `scheduler.config.ts:101`; вынесено исправителем в FIX-E-01 |
| R1-N-04 | инфо | 7 сгенерированных `*.g.dart` не проходят `dart format --set-exit-if-changed` (в CI шага нет; ранее журнал фиксировал «0 changed») | раздел перепроверки E_test_run.log |

## 6. Итог ревью

- Из 50 подтверждённых замечаний (1 blocker, 3 critical, 25 major, 21 minor по исходной оценке): исправлено 40,
  частично — 6, не исправлено — 4 (E-trace-10 закрыт документально этим раундом, E-trace-2 — частично им же).
- Все blocker и critical закрыты по существу. E-onec-sync-1 (потеря изменений 1С), E-api-1 (утечка остатков через
  курсор), E-flutter-data-1 (`deleted[]` не применялся) исправлены и покрыты тестами, которые зелёные в моём прогоне.
  У E-flutter-ui-1 тупик навигации устранён; side sheet на expanded — остаток уровня minor.
- Backend: `test:all` 821/821, покрытие этапа E 90.18 % строк, все скрипты кроме `check_secrets.py` зелёные.
- Flutter: analyze 0, unit/widget 1237, golden 162, сборка Windows, integration catalog/auth/boot зелёные;
  admin_invite_flow нестабилен (R1-N-01).
- Остались серьёзные пункты без решения по коду и документам:
  1. **E-fresh-run-1** — `check_secrets.py` красный (3 строки в `pos-app/test`): шаг CI упадёт. Исправление
     тривиальное (пометка `check-secrets: allow`).
  2. **E-trace-1** — нет матрицы T-ID этапа E: RM-E-012 п. 1 подтвердить нечем.
  3. **E-trace-2** — нет `docs/stages/E_catalog_report.md` (обязательный выход RM-E-012, в нём же — последствия
     RM-E-016 п. 5 и статус G-E).
- Требуют решения по ТЗ или контрактам (не дефекты исполнителя): E-flutter-ui-2 и часть E-flutter-ui-5,
  E-flutter-data-6 (ключи ARB в `contracts/l10n`), FIX-E-01…04, FIX-E-06, FIX-EF-01…07, FIX-EF-10.
- Ограничения окружения: устройства Android/iOS, камера, HID вручную, 50 000 SKU по Wi-Fi, реальная 1С (RM-E-016 —
  «API 1С не получен»), прогон CI на GitHub.

## 7. Вывод по воротам G-E

| Условие G-E (13 §3.5) | Состояние |
|---|---|
| RM-E-001…010, 014, 015, 017 закрыты | по коду — да, с оговорками: RM-E-010 п. 2–3 и RM-E-008/009 п. 3 не проверены на устройстве (окружение); RM-E-014 п. 4 — только unit (E-trace-6); RM-E-017 — статус наличия без текста для customer (E-flutter-ui-2, ждёт ключей ARB) |
| RM-E-011 — отчёт сверки (явно «на фикстурах») | есть (`E_initial_import_report.md`) |
| RM-E-016 — протокол приёмки или отчёт «API 1С не получен» | есть репетиция на моке (`E_onec_extension_acceptance.md`); реального API нет → G-E не выше «жёлтого» |
| RM-E-012 — тесты зелёные, покрытие ≥ 80 % | покрытие выполнено (backend 90.18 %, Flutter data/domain ≥ 80 %); тесты зелёные, кроме нестабильного admin_invite_flow (R1-N-01); `check_secrets.py` красный (E-fresh-run-1); матрицы T-ID нет (E-trace-1); отчёта этапа нет (E-trace-2) |
| Бенчмарк поиска приложен | есть (`docs/perf/E_search_benchmark.md`) |

**Вывод:** на момент раунда 1 ворота G-E **не пройдены**. По коду этап близок к «жёлтому»: blocker и critical
закрыты, backend и Flutter проходят тесты. Не хватает трёх пунктов: зелёного `check_secrets.py`, матрицы T-ID этапа E
и отчёта `E_catalog_report.md`. Нестабильность `admin_invite_flow_test` (R1-N-01) нужно разобрать до раунда 2. Когда
эти пункты будут сделаны, G-E можно выставлять «на жёлтый»: реального API 1С нет (RM-E-016), устройства не проверены.

---

# Раунд 2 (перепроверка после второго исправления, 2026-10-22 15:56–16:40)

## 8. Методика раунда 2

1. Замечания — те же, что подтверждены в раунде 1: шесть направлений (`onec-sync`, `api`, `security`, `flutter-ui`,
   `flutter-data`, `trace`) плюс повторный прогон (`fresh-run`); на каждое серьёзное (blocker/critical/major)
   замечание — два скептика, замечание подтверждено, если ни один его не опроверг (§1). Новых скептиков в раунде 2
   не было: новые наблюдения проверяющего (§11) скептиками не проверялись.
2. Второе исправление (исправитель backend/scripts) затронуло только `scripts/check_secrets.py`,
   `scripts/trace_test_ids.py`, тесты pos-api (88 комментариев T-ID, 3 новых теста) и документы
   (`docs/stages/E_catalog_report.md`). По времени изменения файлов проверено: `pos-api/src`, `pos-app/lib`,
   `pos-app/test` после раунда 1 не менялись. Поэтому статусы замечаний, не затронутых раундом 2, перенесены из §3 —
   после повторной сверки с тем же кодом и повторного прогона тестов.
3. **Полный свежий прогон** всех проверок (pos-api, миграции, скрипты корня, pos-app, integration на Windows) —
   `docs/stages/E_test_run.log`, раздел «Перепроверка после ревью, раунд 2»; вывод — `.tmp/rv2/*.out`.
4. Точечная сверка изменений раунда 2: правило `check_secrets.py` (код и самопроверка); полная матрица
   `trace_test_ids.py --stage E` (выборочно сверены ссылки T-SYNC-007/021/043, T-CAT-010 с текстом 12 и тестов);
   содержание `E_catalog_report.md` по шаблону 13 §6.3; новая проблема E-KI-03 — по коду `catalog-applier.ts`.

## 9. Повторный прогон (раунд 2)

| Проверка | Результат | Итог |
|---|---|---|
| pos-api `lint`, `build`, `madge`, `check:permissions` | EXIT=0; 0 циклов; 77 кодов / 7 ролей | зелёный |
| pos-api `test:all` (21 набор) | 824 passed, 6 skipped, 0 failed | зелёный |
| pos-api `test:cov:e` | 484 passed; строки 90.18 %, ветви 75.57 %; пороги 80/75 выполнены | зелёный |
| pos-api `test:cov:d` | 361 passed; строки 97.92 % | зелёный |
| local-stack `smoke` / `auth-smoke` / `catalog-smoke` | 10/10, 15/15, 22/22 PASS (на фикстурах) | зелёный |
| миграции `run-sql --repeat-strict` (prod и dev/test) | 0 изменений; 63/63 и 64/64 таблиц, 45/45 enum; check_ddl_behavior OK | зелёный |
| `check_no_double_money.sh` | 0 совпадений | зелёный |
| `check_secrets.py --self-test` и `check_secrets.py` | self-test OK; 1720 файлов, 0 находок | зелёный (см. R2-N-01) |
| `build_openapi.py --check`, `check_api_paths.py`, `check_enums.py`, `check_arb_keys.py` | EXIT=0 | зелёный |
| `check_repo_layout.py`, `check_layers.py`, `sync_contracts.py --check`, `check_onec_paths.py` | EXIT=0 (0 ошибок) | зелёный |
| `trace_test_ids.py --summary` / `--stage E --summary` | D: 178 ID, 0 без причины; E: 128 ID — 86 с тестом (47 частично), 42 not_done с причиной, 0 без причины | зелёный |
| `flutter analyze` | No issues found | зелёный |
| `flutter test --concurrency=2` | 1237 passed | зелёный |
| golden (`--tags golden`) | 162 passed | зелёный |
| `flutter build windows --release` | собрано | зелёный |
| integration `catalog_flow_test` (Windows, свой стек) | +2 passed | зелёный |
| integration `auth_flow_test`, `admin_invite_flow_test`, `boot_test` (три серии, каждая на свежем стеке) | auth 3/3 серии, admin_invite 3/3 серии, boot 1/1 | зелёный; R1-N-01 не воспроизвёлся, причина не устранена |
| `dart format --set-exit-if-changed` (вне CI) | 7 сгенерированных `*.g.dart` | инфо (R1-N-04) |

Flutter-покрытие (`--coverage`) в раунде 2 не перезапускалось: pos-app не менялся, значения раунда 1 (catalog
domain+data 83.9 %, features/*/data 83.1 %, features/*/domain 80.3 %) актуальны.
Не выполнялось (окружение): Android/iOS, камера, ручной тест HID, 50 000 SKU на устройстве, Caddy / `curl -I`, прогон
CI на GitHub Actions.

## 10. Все подтверждённые замечания: статус после исправлений (раунд 2)

`sev` — исходная важность (в скобках — оценки скептиков, если ниже). «Δ» — статус изменился в раунде 2.
Подробные доказательства исходных замечаний — §3; здесь кратко.

| id | направление | sev | файл | суть | доказательство (кратко) | статус после исправлений |
|---|---|---|---|---|---|---|
| E-fresh-run-1 | fresh-run | major | `scripts/check_secrets.py` | Гейт секретов красный (7 находок, после раунда 1 — 3 в pos-app/test) | прогон, EXIT=1 | **исправлено** Δ: правило сканера — значения из строчных латинских слов через «-» считаются меткой (как через «_»), самопроверка дополнена; мой прогон — 0 находок, EXIT=0. Пометки `check-secrets: allow` в pos-app/test не ставились — см. R2-N-01 |
| E-fresh-run-2 | fresh-run | major | `scripts/check_no_double_money.sh` | MNY-002 красный, 22 строки | прогон, EXIT=1 | исправлено (0 совпадений) |
| E-fresh-run-3 | fresh-run | minor | `docs/repo_layout.md` §2 | Нет `docs/ops/` | check_repo_layout EXIT=1 | исправлено (0 ошибок) |
| E-fresh-run-4 | fresh-run | minor | `docs/stages/E_test_run.log` | Устаревшая запись test:cov:e | 452 vs 454 | исправлено (свежие записи раундов 1 и 2) |
| E-onec-sync-1 | onec-sync | blocker (major, critical) | `pos-api/src/sync/apply/onec-changes.service.ts` | Xact-lock снимался до ack — потеря изменений 1С | воспроизведено, 3 из 4 потеряны | исправлено (сессионный lock на весь цикл; тест AC-SYNC-011 зелёный). Что тест падает на старом коде — не проверялось (менять код нельзя) |
| E-onec-sync-2 | onec-sync | major (minor) | `onec-changes.service.ts`, `sync-alerts.service.ts` | Недоступность 1С в режиме extension без следов и алерта | воспроизведено | исправлено (`recordFailure` вне транзакции, алерт SYNC-038 п. 1) |
| E-onec-sync-3 | onec-sync | major (minor) | `catalog-full-load.service.ts` | Фаза 0: пропуск ключа в листинге → вечная пометка удаления | воспроизведено | исправлено (сверка `$count`, сброс `data_version`); `$orderby` — FIX-E-03 (ТЗ) |
| E-onec-sync-4 | onec-sync | major (minor) | `outbox-dispatcher.ts` | Возраст outbox не сдвигается ручным повтором | код | исправлено (от последнего `outbox.retried`); колонка — FIX-E-04 (ТЗ) |
| E-onec-sync-5 | onec-sync | major | `scheduler.config.ts` | retryLimit=5 с экспонентой, `consecutive_errors` растёт на каждую попытку | код + тест | исправлено (retryLimit=2, 60 с, без backoff; счёт на прогон); 06 ↔ 05 — FIX-E-01 |
| E-onec-sync-6 | onec-sync | minor | `onec-changes.service.ts:157` | `hasMore=true` + `cursor=null` → ack непрочитанного | код | исправлено |
| E-onec-sync-7 | onec-sync | minor | `onec-odata.client.ts` | Таймаут страницы OData 30 с вместо 60 с | код | исправлено |
| E-api-1 | api | critical (major, major) | `catalog-products.service.ts`, `search.repository.ts` | Точный `available` в открытом курсоре для customer (status) | воспроизведено | исправлено (AES-256-GCM); остаток — длина шифртекста (R1-N-02), `/inventory/check` — FIX-E-06 (ТЗ) |
| E-api-2 | api | major | `search.service.ts` | Потеря строк при пагинации стадии trgm | воспроизведено, 3 из 77 | исправлено |
| E-api-3 | api | major (minor) | `catalog-sync.*` | Курсор офлайн-синхронизации не привязан к области видимости | воспроизведено | исправлено (отпечаток области → 409 `cursor_expired`); `scope_changed` — FIX-E-02 (ТЗ) |
| E-api-4 | api | major (minor, none) | `catalog-products.service.ts`, `search.repository.ts` | Отрицательный остаток варианта скрывает товар | воспроизведено | исправлено (`greatest(available,0)`) |
| E-security-1 | security | major (minor) | `admin-rate-limit.ts` | RL-ADMIN обходится регистром пути | воспроизведено | исправлено |
| E-security-2 | security | major | `common/rate-limit/` | Нет RL-READ / RL-SEARCH | grep пусто | исправлено (`HttpRateLimitModule`); `/inventory/check` — FIX-E-06 (ТЗ) |
| E-security-3 | security | major | `catalog_prefs.dart` | История поиска не очищается при выходе | трассировка | исправлено |
| E-security-4 | security | minor | `step_up_dialog.dart` и др. | Нет защиты экрана при вводе PIN вне SCR-02/08 | grep | исправлено; Q-181 — за заказчиком |
| E-flutter-ui-1 | flutter-ui | critical (major, major) | `sync_connected_widgets.dart:120` | `go('/sync')` — тупик без «Назад» | widget-тест | **частично**: тупик устранён (`push`); side sheet 480 на expanded (02 SCR-43.6) не сделан — остаток minor (FIX-EF-08) |
| E-flutter-ui-2 | flutter-ui | major | `catalog_card_mapper.dart:92` | Статус наличия для customer — только иконка, Semantics пустой | golden, код | **не исправлено**: ключей `stock_badge_in_stock` / `stock_badge_low` в `contracts/l10n` нет (проверено повторно) — нужно действие владельца ARB/03 (FIX-EF-04, E-KI-01) |
| E-flutter-ui-3 | flutter-ui | major | `catalog_workspace.dart:995` | Нет чипа «Недавние» на SCR-12 | код + тест | исправлено |
| E-flutter-ui-4 | flutter-ui | major | `catalog_workspace.dart:342` | Поиск с SCR-12 → «Назад» в корень | воспроизведено | исправлено; чип области UI-11-009 — FIX-EF-07 |
| E-flutter-ui-5 | flutter-ui | major (minor, minor) | `role_guard.dart` | G-7 только для customer | код | **частично**: матрица для всех ролей; снекбара G-7 нет (нет ARB-ключа), permissions токена не используются (FIX-EF-05) |
| E-flutter-ui-7 | flutter-ui | major (minor, minor) | `seller_shell.dart:14` и др. | Глифы вкладок против 03 §7.7 | код | исправлено; противоречие 03 ↔ navigation.md — FIX-EF-06 |
| E-flutter-ui-8 | flutter-ui | minor | `app/di/overrides.dart:80-82` | SyncIndicator всегда компактный | golden | исправлено |
| E-flutter-ui-9 | flutter-ui | minor | golden SCR-10/50 | Обрезка текста | PNG | **частично** (FIX-EF-13) |
| E-flutter-ui-10 | flutter-ui | minor | `catalog_workspace.dart` | Нет «Выйти» в меню профиля | код | исправлено |
| E-flutter-ui-11 | flutter-ui | minor | `product_details_screen.dart` | Упрощённая шапка SCR-14 | golden | исправлено |
| E-flutter-ui-12 | flutter-ui | minor | `customer_home_view.dart` | Нет двойного «Назад» на SCR-50 | grep | исправлено |
| E-flutter-ui-13 | flutter-ui | minor | `customer_home_view.dart` | Бейдж корзины сливается с FAB | golden | исправлено |
| E-flutter-data-1 | flutter-data | critical (major, major) | `catalog_dao.dart` | `deleted[]` prices/barcodes/images не применялся | воспроизведено | исправлено (drift v4, `server_id`); `id` в OpenAPI — FIX-EF-01 (владелец 08) |
| E-flutter-data-2 | flutter-data | major (minor, minor) | `catalog_offline_bindings.dart`, `catalog_sync_engine.dart` | Загрузка не привязана к экземпляру БД | тест с подменой | исправлено |
| E-flutter-data-3 | flutter-data | major (minor, minor) | `outbox_queue.dart` | Владелец outbox проверялся раз на проход | тест с подменой | исправлено |
| E-flutter-data-4 | flutter-data | major (minor) | `sync_scheduler.dart` | Холодный старт онлайн без инкремента | тест | исправлено |
| E-flutter-data-5 | flutter-data | minor | `outbox_queue.dart` | Правило dead против 07 §11.2 | код | исправлено; dead на постоянный 4xx — FIX-EF-03 |
| E-flutter-data-6 | flutter-data | minor | `session_controller.dart` | Нет FLOW-009.E1; данные прежнего пользователя не чистятся | grep | **частично**: предупреждение на SCR-01 — нет ARB-ключа (FIX-EF-10) |
| E-flutter-data-7 | flutter-data | minor | `catalog_dao.dart` | Нет ретенции и VACUUM | grep | исправлено |
| E-flutter-data-8 | flutter-data | minor | `catalog_remote_data_source.dart` | Нет CancelToken | grep | исправлено |
| E-flutter-data-9 | flutter-data | minor | `catalog_sync_engine.dart` | Смена `customer_stock_display` не перезагружает stock | grep | исправлено |
| E-trace-1 | trace | major | `scripts/trace_test_ids.py` | Нет матрицы T-ID этапа E | собственный скрипт: 93 из 113 без ссылок | **исправлено** Δ: `--stage E` — 128 ID: 86 с тестом (из них 47 частично), 42 not_done с причиной, 0 без причины; выборочная сверка ссылок с 12 — соответствуют. Оговорка: все 12 T-UI — not_done (доля AC-UI в тестах мала, напр. SCR-10 3/32) |
| E-trace-2 | trace | major (minor, minor) | `docs/stages/E_catalog_report.md` | Нет выходов RM-E-012 | `ls` | **исправлено** Δ: отчёт этапа по 13 §6.3 (таблица RM-E-*, матрица T-ID, E-KI-01…07, не выполнено по окружению, G-E «жёлтый», последствия RM-E-016 п. 5, шаблон протокола HID с пометкой «не выполнен»); `E_review.md` — этот документ |
| E-trace-3 | trace | major | `app/di/overrides.dart` | `scan_adds_to_cart` не влиял, порт корзины не подключён | код | исправлено |
| E-trace-4 | trace | major | `image-processor.ts` | Валидация фото шире SEC-101 | воспроизведено | исправлено (тест T-SEC-046) |
| E-trace-5 | trace | major (minor) | `.github/workflows/ci.yml` | CI не гоняет наборы E; coverage-gate по unit | код CI | исправлено в конфигурации; на GitHub Actions не запускалось |
| E-trace-6 | trace | minor | `integration_test/catalog_flow_test.dart` | RM-E-014 п. 4, RM-E-008/009 п. 3 — только unit | grep | **не исправлено** (FIX-EF-12) |
| E-trace-7 | trace | minor | `scripts/check_no_double_money.sh` | 22 ложных срабатывания | разбор | исправлено |
| E-trace-8 | trace | minor | `pos-api/src/db/migrator.ts` | Пропуск 0004 | код | исправлено (`MIGRATION_OUT_OF_ORDER`) |
| E-trace-9 | trace | minor | `docs/stages/D_authentication_report.md` | Отчёт D не обновлён после закрытия остатков D | файл от 07:22, стр. 14–21 без изменений | **не исправлено** |
| E-trace-10 | trace | minor | `docs/stages/E_test_run.log` | Нет прогона покрытия Flutter | grep | исправлено документально (раунд 1) |

Итого по 50 подтверждённым замечаниям: **исправлено 43**, **частично 4** (E-flutter-ui-1, E-flutter-ui-5,
E-flutter-ui-9, E-flutter-data-6), **не исправлено 3** (E-flutter-ui-2, E-trace-6, E-trace-9). В раунде 2 закрыты
E-fresh-run-1, E-trace-1, E-trace-2.

## 11. Опровергнутые замечания и новые наблюдения

Опровергнутые (без изменений с раунда 1):

| id | sev | суть | почему опровергнуто |
|---|---|---|---|
| E-flutter-ui-6 | major | owner получает режим seller (вкладка корзины, нет «Админ») | Плановое промежуточное состояние: набор веток owner (SCR-48, navigation.md §2.1/§14.7, ядро §9) по дорожной карте не входит в этапы D и E; утверждение о недостижимости SCR-45 как требовании этих этапов не подтвердилось |

Новые наблюдения раунда 2 (проверяющий; скептиками не проверялись):

| id | важность | суть | доказательство |
|---|---|---|---|
| R2-N-01 | minor | E-fresh-run-1 закрыт не пометками строк, а ослаблением правила: значение вида `[a-z_]+(-[a-z_]+)*` (строчные латинские слова через «-») больше не находка. Не ловится, например, парольная фраза из строчных слов через дефис. Для «_» так было и раньше; самопроверка требует находку только при цифрах или заглавных. Практический риск невелик, но гейт стал мягче, чем предлагалось в замечании | `scripts/check_secrets.py:148-152` |
| R2-N-02 | major по моей оценке (must, AC-ONEC-017) | Найдено исправителем при трассировке (E-KI-03), подтверждаю по коду: при нескольких привязках одного штрихкода в пакете побеждает **последняя** запись, `BARCODE_CONFLICT` пишется только при разных товарах. 05 ONEC-017 п. 2 требует оставить текущую привязку, если она среди пришедших, иначе — наименьший ключ; конфликт — при любых двух привязках (товар/вариант/упаковка). Результат зависит от порядка записей в пакете 1С; теста нет | `pos-api/src/sync/apply/catalog-applier.ts:801-815` («побеждает последний»); 05 ONEC-017, AC-ONEC-017; T-SYNC-005/019 — not_done |
| R1-N-01 (повтор) | minor | `admin_invite_flow_test` в раунде 2 зелёный 3 из 3; код pos-app не менялся, вероятная причина (`ScannerConfigController._load` после закрытия БД) не устранена — нестабильность не исключена (E-KI-02) | `.tmp/rv2/it_s{1,2,3}_admin_invite_flow_test.dart.out` |

Наблюдения раунда 1 R1-N-02 (длина шифртекста курсора) и R1-N-04 (формат `*.g.dart`) — без изменений, учтены в
`E_catalog_report.md` как E-KI-05 и E-KI-06.

## 12. Итог ревью (раунд 2)

- Свежий прогон полностью зелёный: backend `test:all` 824/824, покрытие этапа E 90.18 % строк / 75.57 % ветвей,
  этапа D 97.92 %; все скрипты корня, включая `check_secrets.py`, — EXIT=0; Flutter analyze 0, unit/widget 1237,
  golden 162, сборка Windows, integration catalog/auth/admin_invite/boot — зелёные.
- Три серьёзных пункта, оставшихся после раунда 1, закрыты: `check_secrets.py` зелёный (способ мягче предложенного,
  R2-N-01), матрица T-ID этапа E есть и полна по охвату 12 §2.15 (47 из 86 покрыты частично, 42 — not_done с
  причиной), отчёт этапа `E_catalog_report.md` составлен.
- Все blocker и critical закрыты по коду; у E-flutter-ui-1 остался minor-остаток (side sheet на expanded).
- Из подтверждённых не исправлены по коду: E-flutter-ui-2 (major) — упирается в отсутствие ключей ARB в контрактах,
  то есть в решение владельца ARB/03; E-trace-6 и E-trace-9 (minor).
- Новое: R2-N-02 (= E-KI-03) — правило привязки штрихкода расходится с must-требованием 05 ONEC-017 п. 2, теста нет.
  Скептиками не проверялось; в отчёте этапа отмечено как известная проблема с планом «до начала F».
- Требуют решения по ТЗ/контрактам: FIX-E-01…04, FIX-E-06, FIX-EF-01…08, FIX-EF-10 (в т. ч. ключи ARB для
  E-flutter-ui-2, E-flutter-ui-5, E-flutter-data-6).
- Ограничения окружения: Android/iOS, камера, HID, 50 000 SKU по Wi-Fi, Caddy, реальная 1С (RM-E-016 «API 1С не
  получен»), прогон CI на GitHub (новый job `api-integration` и объединённый coverage-gate проверены только локально).

## 13. Вывод по воротам G-E (раунд 2)

| Условие G-E (13 §3.5) | Состояние |
|---|---|
| RM-E-001…010, 014, 015, 017 закрыты | по коду — да, с оговорками: RM-E-017 — статус наличия без текста для customer (E-flutter-ui-2, ждёт ключей ARB); RM-E-001 — правило конфликта штрихкодов (R2-N-02 / E-KI-03); RM-E-014 п. 4 — только unit (E-trace-6); RM-E-008/009 п. 3, RM-E-010 п. 2–3, RM-E-003 п. 3 — не проверены (окружение) |
| RM-E-011 — отчёт сверки (явно «на фикстурах») | есть (`E_initial_import_report.md`) |
| RM-E-016 — протокол приёмки или отчёт «API 1С не получен» с последствиями и решением по §3.12 | отчёт «API 1С не получен» (`E_onec_extension_acceptance.md`, `E_catalog_report.md` §4.2) → G-E не выше «жёлтого» |
| RM-E-012 — тесты зелёные, покрытие ≥ 80 % | выполнено в раунде 2: все тесты и скрипты зелёные, покрытие backend 90.18 %, Flutter data/domain ≥ 80 %; матрица T-ID и отчёт этапа есть; CI на GitHub не запускался |
| Бенчмарк поиска приложен | есть (`docs/perf/E_search_benchmark.md`) |

**Вывод:** ворота G-E можно выставлять **«на жёлтый»** (путь RM-E-016 «API 1С не получен»), но не «на зелёный».
Открытых blocker/critical нет. До «зелёного» нужны: ключи ARB и правка статуса наличия для customer
(E-flutter-ui-2); исправление правила штрихкодов с тестом (R2-N-02 / E-KI-03); разбор причины R1-N-01; шаг
integration «Очистить недавние» и замеры на Windows/устройстве (E-trace-6); проверки на устройствах; прогон CI на
GitHub Actions; приёмка API 1С. Обновление отчёта этапа D (E-trace-9) на G-E не влияет, но нужно для корректного
статуса G-D.

---

# Закрытие остатков (ревью закрытия этапа E, исправления Fix2, финальный прогон; 2026-10-22 19:20–21:13)

## 14. Методика закрытия остатков

1. **Прогон проверяющего после закрытия остатков** (19:20–20:13; журнал 1448–1557). Это независимый проверяющий, код он
   не менял. Результат: красные `catalog_flow_test` (2 из 2) и `trace_test_ids.py --stage E`, информационно —
   `dart format` (10 файлов). Остальное зелёное: `test:all` 848 passed, покрытие E 90,23 % строк, бенчмарк p95 135,2 мс.
2. **Ревью закрытия.** Направления: прогон (`RR-*`), код (`RC-*`), ТЗ и контракты (`RS-*`). Найдено 21 замечание:
   1 critical, 4 major, 16 minor. Серьёзные замечания (critical и major) прошли верификацию. Все 5 подтверждены; у RS-3
   верификатор опроверг одну часть — про 08 §3.6 и INV-052. Minor-замечания скептиками не проверялись, исправители
   приняли их к работе.
3. **Раунд Fix2.** Три исправителя: scripts/backend, Flutter, ТЗ/контракты. Их правки — в `find -newer` журнала
   1561–1572. Перед Fix2 закрывали остатки раунда 1 и 2 ещё два исправителя: владелец контрактов (OpenAPI 1.1.0,
   ADR-097, 59 ключей ARB) и исправитель backend/scripts (E-KI-03, `images.gc`, EQ-AUTH-08, EQ-FINT-05, R2-N-01).
4. **Финальный прогон** (20:43–21:13; журнал 1561–1654). Выполнял автор итоговых документов. Перезапущено всё, что
   затронул Fix2, и ключевые команды.

Ограничения записи:
- Этот раздел составил **автор итоговых документов, а не независимый проверяющий**.
- Повторной независимой перепроверки исправлений Fix2 не было. Статусы ниже подтверждены финальным прогоном и
  чтением кода и документов.
- У minor-замечаний RS-4…RS-10 суть восстановлена по журналам изменений документов: 08 §16.10, 02 и 03 «Ревью
  закрытия этапа E», 14 §15, `visual/navigation.md`. Протокола ревью закрытия в репозитории нет.

## 15. Замечания ревью закрытия: проверка и статус

| id | sev | суть | проверка | статус после Fix2 | доказательство |
|---|---|---|---|---|---|
| RR-1 | critical | `catalog_flow_test` красный в 2 запусках из 2. На expanded SCR-14 открывается прозрачной страницей, а у ветки «панель поверх колонки» (`product-panel-overlay`) нет ключа `scr-14`. Сценарий сотрудника «карточка → вариант → черновик → офлайн» не проверялся | подтверждено | **исправлено**. Корень панели получил `ValueKey('scr-14')`. Попутно найден и исправлен второй дефект: `DsContentRegion.rectIn` обращался к деактивированному элементу при `go('/catalog')` с открытой панелью. Android не запускался | журнал 1626–1631: 2 из 2, EXIT=0; черновик 1 строка, «2шт»; офлайн — 8 карточек |
| RC-1 | major (исправитель ссылается на вердикт проверки: minor) | Офлайн-выход не ставит в outbox `auth.logout`. Серверная сессия живёт до истечения срока, до 7 дней | подтверждено | **не исправлено**. Это бэклог SS-07 (класс C, `E_spec_sync.md`). Нужен обработчик `pending_logout`, который работает без сессии: refresh → logout. Плюс запасной путь при `UNLOCK_REQUIRED`: `DELETE /auth/sessions/{sid}` после следующего входа. Изменение затрагивает хранение токенов, поэтому в закрывающем проходе его не делали. Контракт 1.1.0 достаточен | — |
| RS-1 | major | `refresh_replay` у `401 UNLOCK_REQUIRED` описан наоборот: «пользователь без PIN» | подтверждено | **исправлено**. `Problem.reason` в `00_root.yaml`, 08 §2.4, §16.9–16.10, CHANGELOG [1.1.0] «Уточнено». Схема и версия 1.1.0 не менялись. Поведение подтверждает e2e T-SESS-023 | журнал 1583 (`build_openapi --check` OK), 1603–1608 (e2e 93) |
| RS-2 | major | По Q-299 и Q-310 реализация и «Допущение» в 14 расходятся с нормативным текстом 09/08, а ссылки на вопрос в тексте нет | подтверждено | **исправлено**. Добавлены пометки «реализовано в R1 иначе» со ссылками на Q-299/Q-310: 09 §4.4, §5.3, BIO-020; 08 §2.4, §2.9, событие `auth.pin.locked`, §4.1.8. Нормативное правило до ответа заказчика не менялось | 09 §22, 08 §16.10 |
| RS-3 | major | В Q-317 и Q-314 «Допущение» не совпадает ни с ТЗ, ни с реализацией. Вторая часть: 08 §3.6 расширяет INV-052 | подтверждено частично: часть про 08 §3.6 / INV-052 **опровергнута** верификатором | **исправлено** в подтверждённой части. В Q-317, Q-314 и Q-324 (тот же шаблон) «Допущение» теперь равно действующему значению: `unknown`, `active`, `com.example.optomstroy` только для разработки. Предложения исполнителя перенесены в «Иной ответ». 08 §3.6 не менялся | 14 §15 |
| RR-2 | minor | Трасса T-CAT-032 устарела: тест переименован, и `trace_test_ids.py --stage E` даёт EXIT=1 | — | **исправлено** | журнал 1593–1595: EXIT=0, 128 / 87 / 41 / 0 |
| RR-3 | minor | `dart format` нашёл 10 файлов: 9 `*.g.dart` и `customer_mode_catalog_test.dart` | — | **частично**. Рукописный файл отформатирован. 9 `*.g.dart` остались: source_gen 4.2.4 не поддерживает ширину 120. Нужно исключить их из шага формата в CI (`ci.yml`) — это E-KI-06 | журнал 1623–1625 (9 файлов, все `*.g.dart`) |
| RC-2 | minor | `check_no_double_money.sh`, правило 3, пропускал унарный `+` у голого идентификатора и в стрелочной функции | — | **исправлено**. Самопроверка дополнена | журнал 1580 (self-test OK) |
| RC-3 | minor | `openapi.document.ts` отдаёт `setVersion('1.0.0')`, а контракт — 1.1.0 | — | **исправлено**. Введена константа `OPENAPI_INFO_VERSION = '1.1.0'` и `openapi.document.spec.ts` для сверки с контрактом | журнал 1603–1604 (unit 130) |
| RC-4 | minor | Документы не синхронизированы с кодом: `images.gc` (07 §5.23, 13 RM-E-003), G-7/G-11 (`navigation.md`), side sheet SCR-43 (02), `otp_pepper` у `worker` (16 §4.4, примечание 6) | — | **частично**. Всё перечисленное выровнено. `docs/ci.md` не обновлён: в таблице сервисов compose у `worker` по-прежнему «database_url, jwt_public.json», без `otp_pepper` (проверено, `docs/ci.md:97`) | 07, 13, 02, 16 — журналы изменений; `check_compose_test.py` OK (журнал 1596–1598) |
| RC-5 | minor | Для снекбара G-11 (`/scan` без камеры) нет ключа ARB с текстом «Используйте аппаратный сканер». Используется ближайший ключ `catalog_scanner_hid_hint` | — | **не исправлено**. Ключ должен внести владелец словаря в 02 §7 и пересобрать ARB через `build_arb.py`. После этого правка guard — одна строка (`app_router.dart:149`) | — |
| RC-6 | minor | Клики вне панели SCR-14 на expanded/large (CP, SearchBar, пустая шапка) обрабатывались не по 02: модальный барьер страницы перехватывал их | — | **исправлено**. Добавлены `PanelPage` (прозрачный маршрут без перехватывающего барьера), `DsPanelDismissLayer` и `DsPanelPassThrough`, новые widget-тесты. **Побочный эффект:** новый `panel_page.dart` нарушает гейт MNY-002 — см. F-N-01 | журнал 1620–1622 (1298 / 164 зелёные) |
| RC-7 | minor | Ослабление `check_secrets.py` (R2-N-01) отменено лишь частично: исключение для тестовых путей осталось | — | **исправлено**. Исключение удалено. 3 строки в `pos-app/test` помечены `check-secrets: allow — тестовая метка, не секрет`. Фраза из строчных слов через дефис теперь находка везде | журнал 1581–1582: 1756 файлов, 0 находок; self-test OK |
| RS-4 | minor | Тело и ошибки в карточке 08 §4.18.4 не выровнены с «Уточнениями» п. (1)–(3) и 11 SEC-136 п. 4 | — | **исправлено**: 08 §4.18.4 и описания `admin_users_create` / `admin_invitations_create` | 08 §16.10 |
| RS-5 | minor | В `navigation.md` устаревшие фразы «снекбары G-7 не показываются» и «G-11 не реализован» | — | **исправлено**. G-7 помечен как временное отступление: права из токена — бэклог FE | `navigation.md` §4.1, §14.2 |
| RS-6 | minor | Общие ключи `ds_*` / `status_*` (ADR-097) внесены в 02 §7, а не во владельца — 03 §16.5 | — | **исправлено**: 03 §16.5 — владелец, 02 §7 — свод | 02, 03 «Ревью закрытия этапа E» |
| RS-7 | minor | `cart_fab_a11y` и `cart_fab_a11y_nototal` без ICU plural (03 §16.3) | — | **исправлено**, `contracts/l10n` пересобран | журнал 1589 (`sync_contracts --check` OK) |
| RS-8 | minor | В скелете 08 §8 `info.version` не 1.1.0 | — | **исправлено** | 08 §16.10 |
| RS-9 | minor | Статистика реестра 14 (226 ID, 205 открытых тем) не согласована в 14 §1, §9, 00 и README | — | **исправлено** | 14 §15, 00, README |
| RS-10 | minor | Заголовок п. 2 «Уточнений выгрузки» 08 §4.24.1 не отражает, что поля внесены в OpenAPI 1.1.0 | — | **исправлено** | 08 §16.10 |
| RS-11 | minor | Smoke «экспорт OpenAPI ⊆ контракт» не сверяет `info.version` | — | **исправлено** (при 1.0.0 smoke падает) | журнал 1603–1608 (e2e 93) |

Итог по 21 замечанию:
- исправлено 17: RR-1, RR-2, RC-2, RC-3, RC-6, RC-7, RS-1…RS-11;
- частично 2: RR-3, RC-4;
- не исправлено 2: RC-1 (major, бэклог SS-07) и RC-5 (minor, нужен ключ ARB).

Опровергнута одна часть RS-3.

Новые наблюдения финального прогона (автор итоговых документов; скептиками не проверялись):

| id | важность | суть | доказательство |
|---|---|---|---|
| F-N-01 | minor (красный гейт MNY-002) | `check_no_double_money.sh` снова красный. Причина — `Animation<double>` в новом `pos-app/lib/app/router/panel_page.dart:65, 71, 72` (Fix2, RC-6): правило «double вне `design_system`», пометки `money-double: allow — <причина>` нет. Это геометрия анимации, не деньги, но гейт обязательный. В pos-api нарушений нет | журнал 1576–1579 (EXIT=1, повтор в 21:11 — то же) |
| F-N-02 | инфо | Часть RC-4: `docs/ci.md` (таблица сервисов compose, строка `worker`) не показывает `otp_pepper`, хотя `infra/compose.test.yml:126–127` и 16 §4.4 его передают | `docs/ci.md:97` |

## 16. Прежние незакрытые пункты: статус после закрытия остатков

| Пункт | Было (§10–§12) | Стало | Доказательство |
|---|---|---|---|
| E-flutter-ui-2 / E-KI-01 — статус наличия для `customer` без текста | не исправлено (нет ключей ARB) | **исправлено**. Ключи `stock_badge_in_stock{,_qty}` и `stock_badge_low{,_qty}` внесены (02 §7 → `build_arb.py`, ADR-097). Используются в `catalog_card_mapper.dart:96–100` и `product_sections.dart:431–440`. `StockBadge` отдаёт текст в `Semantics.label` | журнал 1620–1622; трасса T-CAT-032 («В наличии» без чисел) зелёная |
| E-flutter-ui-1 — side sheet SCR-43 на expanded | частично | **исправлено**: `sync_side_sheet.dart`, 02 SCR-43 «Уточнения» (4) | RC-4; журнал 1620 |
| E-flutter-ui-5 — G-7 | частично | **частично**. Снекбары G-7 показываются: `global_role_forbidden`, `global_payment_cashier_only`, тест `guard_notice_test`. Проверка по permission из токена — бэклог FE (`navigation.md` §4.1) | журнал 1620–1621 |
| E-flutter-data-6 — предупреждение SCR-01 о данных прежнего пользователя | частично | **исправлено по коду**: ключ `auth_pending_changes_other_user` используется в `phone_screen.dart` | grep; журнал 1620 |
| E-flutter-ui-9 — обрезка текста в эталонах | частично | **без изменений, не перепроверялось** (FIX-EF-13, бэклог) | — |
| E-trace-6 / E-KI-09 — integration-шаг «Очистить недавние» офлайн, замеры 200 мс / 50 000 SKU | не исправлено | **не исправлено**: в `integration_test/` шага нет, устройства нет (FIX-EF-12) | grep `integration_test` |
| E-trace-9 / E-KI-10 — отчёт этапа D | не исправлено | **исправлено документально**: в `D_authentication_report.md` добавлен раздел «Дополнение 2026-10-22: остатки D, закрытые на этапе E». G-D по-прежнему красный | файл, стр. 334+ |
| R2-N-02 / E-KI-03 — правило привязки штрихкода (05 ONEC-017 п. 2) | не исправлено, major | **исправлено**. В `catalog-applier.ts` кандидаты собираются за весь прогон. Если текущая привязка среди кандидатов, она сохраняется, иначе выбирается наименьший ключ. `BARCODE_CONFLICT` пишется при любых двух привязках. Тест `test/sync-apply/barcode-conflict.spec.ts` проверяет оба порядка записей и межпакетный случай. Скептиками исправление не перепроверялось | журнал 1603–1608 (sync-apply 34) |
| R2-N-01 / E-KI-07 — ослабление `check_secrets.py` | minor | **исправлено** (RC-7) | журнал 1581–1582 |
| R1-N-01 / E-KI-02 — нестабильность `admin_invite_flow_test` | не исправлено, не воспроизводится | **исправлено по коду, не воспроизводится**. В `ScannerConfigController._load` есть перехват ошибки и проверка `ref.mounted && identical(_store, store)` (`hardware_providers.dart:48–61`). Тест зелёный: раунд 2 — 3/3, прогон 19:20 — 1/1, финальный — 1/1 | журнал 1633–1641 |
| R1-N-02 / E-KI-05 — длина шифртекста курсора | minor | без изменений, решение по Q-316 | — |
| R1-N-03 — паузы повторов 60 + 60 с | инфо | закрыто в ТЗ (FIX-E-01, 06 §7.5) | — |
| R1-N-04 / E-KI-06 — формат `*.g.dart` | инфо | **частично**: см. RR-3, осталось 9 сгенерированных файлов | журнал 1623–1625 |
| E-KI-04 — отчёт о дублях `onec_code` (T-SYNC-009) | не реализован | **не исправлено**: код `DUPLICATE_SUSPECTED` объявлен, обработки нет; план — этап F или H | grep `pos-api/src` |
| EQ-IMG-10 — задание `images.gc` (RM-E-003) | бэклог | **исправлено**. `ImagesGcService`, очистка в два цикла (пометка, затем удаление), ежедневно в 05:15. Добавить очередь в 06 §7.5 и `queues.ts` — задача владельца | `test/images/images-gc.spec.ts`; журнал 1603–1608 (images 25) |
| EQ-AUTH-08 — `otp_pepper` у `worker` в `infra/compose.test.yml` | бэклог infra | **исправлено** в конфигурации. Docker не запускался | журнал 1596–1598 |
| EQ-FINT-05 — точность `check_no_double_money.sh` | бэклог | **исправлено**: исключение только с указанием причины, правило 4 для миграций, `--self-test`. Гейт сейчас красный из-за F-N-01 | журнал 1576–1580 |
| FIX-EF-01 и др. — поля выгрузки и `Problem.until` в OpenAPI | ТЗ | **исправлено**: OpenAPI 1.1.0, ADR-097. Ключи DTO pos-app совпадают с контрактом (`catalog_dto_contract_test`, `dto_schema_test` зелёные) | журнал 1583, 1620–1621 |
| Ключи ARB 03 §16.7 | не внесены | **частично**. Внесено 59 ключей, временные ключи в коде заменены. Не внесены из-за отсутствия текста в 02/03: `role_<code>_summary`; подпись кнопки «бургера» SCR-10; заголовок сетки SCR-50; «нет сети» SCR-50.7; текст G-11 (RC-5). У 7 текстов пометка «согласовать при вычитке». `ky`/`en` — копии `ru` (Q-007) | журнал 1585, 1589 |
| AU-03 — `devCode` | частично | без изменений. В контракт не внесён: 09 §4.6 — «в R1 не возвращается». Подсказка на стенде не появится | 08 §16.9 |

## 17. Итог и вывод по воротам G-E после закрытия остатков

Финальный прогон (журнал 1561–1654):
- зелёные:
  - `test:all` — 849 passed, 0 failed;
  - `test:cov:e` — строки 90,23 %, ветви 76,06 %;
  - `lint` и `build`;
  - `flutter analyze` — 0 замечаний;
  - `flutter test` — 1298 тестов, golden — 164;
  - `catalog_flow_test` на Windows — 2 из 2;
  - регрессия D (auth, admin_invite, boot);
  - `check_secrets.py`, `build_openapi.py --check`, `check_arb_keys.py`, `trace_test_ids.py --stage E` и остальные
    скрипты корня;
- **красный** — `check_no_double_money.sh` (F-N-01: три строки геометрии анимации в `panel_page.dart`);
- информационно: `dart format` — 9 сгенерированных `*.g.dart`.

Не повторялись команды прогона 19:20, чей проверяемый код после 19:20 не менялся: madge, `test:cov:d` 97,92 %,
smoke 10/10, 15/15, 22/22, миграции, бенчмарк p95 135,2 мс.

Release-сборка Windows из того же прогона сделана **до** правок Fix2 в pos-app и не повторялась. После Fix2
компиляцию подтверждают только `flutter analyze` и debug-сборка в `catalog_flow_test`.

| Условие G-E (13 §3.5) | Состояние |
|---|---|
| RM-E-001…010, 014, 015, 017 закрыты | По коду — да. Сняты оговорки E-KI-01 (RM-E-017) и E-KI-03 (RM-E-001). Не проверены по окружению: RM-E-003 п. 3 (Caddy), RM-E-008 п. 3 и RM-E-009 п. 3 (устройство), RM-E-010 п. 2–3 (Android, HID). RM-E-014 п. 4 — только unit (E-trace-6) |
| RM-E-011 — отчёт сверки (явно «на фикстурах») | есть |
| RM-E-016 — протокол приёмки или отчёт «API 1С не получен» | отчёт «API 1С не получен» → **G-E не выше «жёлтого»** |
| RM-E-012 — тесты зелёные, покрытие ≥ 80 % | тесты зелёные, покрытие backend 90,23 %. Обязательный гейт MNY-002 красный (F-N-01). Android и CI на GitHub не запускались |
| Бенчмарк поиска приложен | есть: повтор после ревью, p95 135,2 мс на 50 000 синтетических SKU (`docs/perf/E_search_benchmark.md` §8) |

**Вывод:** ворота G-E — **«жёлтый»**, не выше: путь RM-E-016 «API 1С не получен».

Открытых blocker и critical нет: RR-1 закрыт, `catalog_flow_test` 2 из 2.

До снятия оговорок «жёлтого» нужно:
- устранить F-N-01 — пометить строки с причиной или вынести геометрию в `design_system`; без этого гейт MNY-002 в CI
  красный;
- RC-1 (SS-07) — отложенный отзыв сессии при офлайн-выходе;
- внести ключи ARB без источника текста, включая RC-5.

До «зелёного», кроме этого, нужны:
- E-trace-6;
- Android и HID;
- `curl -I` через Caddy;
- прогон CI на GitHub;
- приёмка API 1С.

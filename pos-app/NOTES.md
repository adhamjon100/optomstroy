# pos-app — заметки исполнителя RM-C-002 (Flutter-каркас)

Задача: 13_IMPLEMENTATION_ROADMAP §3.3, RM-C-002. Владелец `pubspec.yaml` — FE.
Окружение проверки: Windows 11, Flutter 3.38.7 / Dart 3.10.7, Python 3.13.6.

## 1. Зависимости: что изменено относительно R3 §15 и почему

R3 §15 составлен по версиям pub.dev на 2026-10-18 и прямо оговаривает, что совместимость
с Flutter 3.38.7 / Dart 3.10.7 не проверялась `pub get`. Проверка `flutter pub get` показала
три жёстких ограничения SDK, из-за которых набор R3 §15 на этой машине не разрешается:

1. **Свежие версии требуют Dart ≥ 3.11–3.13.** `riverpod_lint` 3.1.6+ и `flutter_riverpod` 3.4.x —
   Dart ≥ 3.12; `freezed` 4.x — ≥ 3.13; `go_router` 18.x — ≥ 3.12; `build_runner` 2.15.2+ — ≥ 3.11;
   `shared_preferences` 2.5.6 — ≥ 3.11; `cached_network_image` 4.x — новее 3.10.
2. **Flutter 3.38.7 пинует `meta 1.17.0` и `test_api 0.7.7`** (через `flutter_test`).
   `meta 1.17` исключает `analyzer` ≥ 10.0.2 (нужен `meta ^1.18`), а `test_api 0.7.7` даёт `test 1.26.3`,
   который требует `analyzer < 9`. `riverpod` 3.x зависит от `test` в основных зависимостях,
   поэтому ограничение действует на весь граф.
3. **Итог: единственное окно — `analyzer 8.x`** (разрешилось `analyzer 8.4.0`). Все генераторы
   (riverpod_generator, freezed, json_serializable, drift_dev, go_router_builder, build_runner)
   и riverpod_lint взяты в последних версиях, совместимых с analyzer 8.

Версии зафиксированы узкими диапазонами (разрешение с широкими `^` уходило в долгий перебор > 10 мин).

| Пакет | R3 §15 | Принято (pubspec.lock) | Причина |
|---|---|---|---|
| flutter_riverpod | ^3.4.3 | 3.1.0 | 3.4.x — Dart ≥ 3.12; 3.3.x тянет riverpod 3.2.1/3.3.2, их riverpod_lint требует analyzer ≥ 9 |
| riverpod_annotation | ^4.0.7 | 4.0.0 | пара к riverpod 3.1.0 |
| riverpod_generator | ^4.0.9 | 4.0.0+1 | analyzer < 9 |
| riverpod_lint | ^3.1.9 | 3.1.0 | последняя с analyzer < 9; уже на `analysis_server_plugin` (0.3.3), подключение через `plugins:` работает — проверено (сработало правило `only_use_keep_alive_inside_keep_alive`) |
| go_router | ^18.1.0 | 17.5.0 | 18.x — Dart ≥ 3.12 |
| go_router_builder | ^4.5.0 | 4.5.0 | как в R3; `@TypedStatefulShellRoute` и `@TypedQueryParameter` генерируются (ТИПОВО 06 §6.4 снято) |
| drift / drift_dev | ^2.35.2 / ^2.35.1 | 2.30.1 / 2.30.1 | drift_dev ≥ 2.32 требует analyzer ≥ 10 |
| drift_flutter | ^0.3.1 | 0.2.8 | 0.3.x требует sqlite3 3.x (drift ≥ 2.32) |
| sqlite3 | ^3.7.1 | 2.9.4 (+ `sqlite3_flutter_libs` 0.5.42 транзитивно) | drift 2.30 требует sqlite3 2.x. **Отклонение от R3 §1.3**: R3 отклоняет `sqlite3_flutter_libs` (EOL для ветки 3.x); для ветки 2.x он и есть штатный способ бандлинга нативного SQLite. FTS5 в бандле — проверить в RM-C-004 |
| freezed | ^4.0.3 | 3.2.3 | 4.x — Dart ≥ 3.13; 3.2.4+ — analyzer ≥ 9. `freezed_annotation` 3.1.0 — как в R3 |
| json_serializable / json_annotation | ^6.14.1 / ^4.12.0 | 6.11.2 / 4.9.0 | 6.11.3+ — analyzer ≥ 9 |
| build_runner | ^2.17.1 | 2.10.5 | 2.15.2+ — Dart ≥ 3.11; analyzer 8 |
| shared_preferences | ^2.5.6 | 2.5.5 | 2.5.6 — Dart ≥ 3.11 |
| cached_network_image | ^4.0.4 | 3.4.1 | 4.x — новее Dart 3.10 |
| flutter_native_splash | ^2.4.8 | 2.4.7 | 2.4.8 требует meta ^1.18 |
| intl | ^0.20.3 | 0.20.2 | точная версия задаётся `flutter_localizations` из SDK |
| custom_lint | (в задаче) | **не добавлен** | `custom_lint` 0.8.1 требует analyzer ^8.0 + `analyzer_plugin` ^0.13 и пакет правил; R3 §1.1 и 06 §6.3: riverpod_lint 3.x на custom_lint не основан. Правила слоёв — `scripts/check_layers.py` (§4) |
| lottie, msix | опц. / dev | не добавлены | lottie — «опционально» (R3); MSIX — R2 (06 §6.16, ядро §20.2 п.13) |
| biometric_storage | — | не добавлен | выбор пути криптопривязки — прототип RM-C-013 (D-13); пакет добавит FE в RM-C-013 |

Без изменений относительно R3: flutter_secure_storage 11.2.0, local_auth 3.0.2, dio 5.11.1,
connectivity_plus 7.3.2, flutter_cache_manager 3.4.5, flutter_svg 2.3.0, rive 0.14.11,
mobile_scanner 7.4.2, phone_numbers_parser 9.0.28, path_provider 2.1.6, mocktail 1.0.5,
alchemist 0.14.1, flutter_launcher_icons 0.14.4, flutter_lints 6.0.0.

Добавлено заранее для core (RM-C-004) и design_system (RM-C-003), которые pubspec не меняют:
`package_info_plus` 10.2.2 (X-App-Version, версия на Splash — RM-C-015), `device_info_plus` 13.3.0
(X-Platform, имя устройства сессии), `uuid` 4.6.0 (requestId, Idempotency-Key), `collection`,
`meta`, `async`, `logging` (логгер без ПДн, R3 §8), `crypto`, `path`.
Если core/DS понадобится ещё пакет — запрос владельцу pubspec (FE).

**Рекомендация (решение заказчика/ARCH):** обновить Flutter до версии с Dart ≥ 3.13 — тогда
весь набор R3 §15 ставится как есть (riverpod 3.4, freezed 4, drift 2.35 + sqlite3 3.x,
go_router 18). До обновления новые пакеты подбирать под analyzer 8 / meta 1.17.

## 2. Структура `lib/` (06 §6.2, R3 §14.1)

```
lib/
  main.dart                    bootstrap()
  app/app.dart                 MaterialApp.router, AppTheme.light(), gen-l10n, locale ru
  app/bootstrap.dart           ensureInitialized → ProviderScope(overrides: appOverrides)
  app/di/overrides.dart        композиционный корень (L-8), пока пустой
  app/router/app_router.dart   @Riverpod(keepAlive) GoRouter: $appRoutes + redirect
  app/router/routes.dart       типизированные маршруты R0 §9 (+ routes.g.dart)
  app/router/guards/auth_guard.dart   Splash + authGuard (returnTo)
  app/router/shells/           app_shell.dart, app_mode.dart, shell_tab.dart,
                               seller_/cashier_/admin_/customer_shell.dart
  app/router/route_stub_screen.dart   заглушка экрана с ID SCR-xx
  core/                        каталоги-заготовки (.gitkeep) — RM-C-004;
                               core/session/session_status.dart — ЗАГЛУШКА;
                               core/l10n/ — вывод gen-l10n
  design_system/               tokens/, components/, animations/ (.gitkeep) — RM-C-003;
                               theme/app_theme.dart — ЗАГЛУШКА (AppTheme.light())
  features/<19 фич>/           domain/ data/ presentation/ (.gitkeep) + README.md
  features/splash/presentation/screens/splash_screen.dart   SCR-00
  features/auth/presentation/screens/no_session_screen.dart заглушка «нет сессии» на /auth/phone
  l10n/app_{ru,ky,en}.arb      копия contracts/l10n (побайтно)
  l10n/gen_input/              вход gen-l10n (§3)
```

Заглушки в чужих каталогах (`core/session/session_status.dart`, `design_system/theme/app_theme.dart`)
созданы, чтобы проект собирался; владельцы заменяют тело, сохраняя имена `sessionStatusProvider`,
`SessionStatus`, `AppTheme.light()` (или правят вызовы в `app/` вместе с FE).

Маршрутизация:
- Все маршруты карты R0 §9, кроме SCR-05 `/register/face-scan` (R2, только при `FEATURE_FACE_SCAN=true`),
  листов SCR-15/16 и overlay SCR-90. Состав сверяет `test/widget/router_test.dart`.
- **Один `StatefulShellRoute`**, ветки = объединение вкладок всех режимов (10 веток: catalog, home,
  favorites, cart, customers, cashier, transactions, orders, admin, profile). Режим
  (seller/cashier/admin/customer — `appModeProvider`, пока всегда `seller`) выбирает 5 вкладок.
  Отдельные shell-маршруты на режим невозможны: go_router требует уникальных путей, а `/catalog`,
  `/profile` и др. общие для нескольких режимов (06 §6.4: «один граф маршрутов»).
- Query-параметры с именами из R0 §9 (`orderId`, `customerId`, `returnTo`) — через `@TypedQueryParameter`;
  без него go_router_builder делает kebab-case (`order-id`).
- Guards: реализованы Splash-redirect и authGuard. unlock/pendingActivation/registration/role — этап D
  (нужны состояния сессии). Ошибка восстановления сессии сейчас оставляет Splash (экран
  `splash_init_error_*` — RM-D-007).
- `AppShell` — `NavigationBar` для всех размеров; адаптивная раскладка D-18 — после RM-C-003.

## 3. Локализация

- `scripts/sync_contracts.py` копирует `contracts/l10n/app_*.arb` → `pos-app/lib/l10n/` побайтно;
  `--check` сверяет SHA-256 и ищет лишние файлы (код 1 при расхождении; проверено подменой файла).
- **Дефект контракта (передать владельцу RM-B-007, DS):** 4 ключа используют плейсхолдер `new` —
  зарезервированное слово Dart: `admin_users_role_diff`, `cart_line_price_changed`,
  `checkout_conflict_price`, `order_banner_total_adjusted`. `flutter gen-l10n` на исходных ARB падает:
  «'new' can't be used as an identifier because it's a keyword».
  Обход без правки контракта: скрипт пишет `lib/l10n/gen_input/app_*.arb` — те же ARB, где такие
  плейсхолдеры переименованы в `newValue` (детерминированно; `--check` сверяет и это преобразование).
  `l10n.yaml` указывает `arb-dir: lib/l10n/gen_input`. После исправления `build_arb.py`
  (например, `new` → `newValue` в 02 §7) преобразование станет тождественным; тогда `arb-dir` можно
  вернуть на `lib/l10n`, а `gen_input/` удалить.
- Вывод gen-l10n — `lib/core/l10n/` (06 §6.2), `nullable-getter: false`, шаблон `app_ru.arb`.
  Параметры методов с этими ключами — `newValue:`.
- `ky`/`en` — каркас (копия ru, D-38).

## 4. Правила слоёв: `scripts/check_layers.py`

- `custom_lint` в проект не добавлен (§1): с analyzer 8 совместим только `custom_lint` 0.8.x, а
  собственный плагин правил потребовал бы отдельного пакета (`tools/optomstroy_lints`) — это
  **следующая итерация** (после обновления Flutter или при выборе пакета import-правил, 06 §6.1).
- Сейчас правила B_architecture_review.md §5.1, выражаемые через импорты, проверяет скрипт:
  FL-01…FL-07, FL-11 (циклы между фичами) и дополнительное AP-01 (features/core/design_system
  не импортируют `app/`). DAG фич — таблица 06 §6.1.
- `python -I -X utf8 scripts/check_layers.py --self-test` — 35 синтетических проверок самих правил.
- Не по импортам и пока не автоматизированы: FL-08 (литералы цветов/строк в presentation),
  FL-09 (ручная правка сгенерированного — частично закрыта `sync_contracts.py --check`),
  FL-10 (double для денег) — следующая итерация (AST-правила).
- Все импорты внутри `lib/` — `package:optomstroy/...` (`always_use_package_imports`).

## 5. Анализ и форматирование

`analysis_options.yaml`: `flutter_lints` + strict-casts/strict-inference/strict-raw-types,
дополнительные правила надёжности, `plugins: riverpod_lint`, ширина форматирования 120.
Сгенерированные `*.g.dart`, `*.freezed.dart`, `core/l10n/app_localizations*.dart` исключены из анализа.

## 6. Команды (из `pos-app/`, кроме python)

```
python -I -X utf8 ../scripts/sync_contracts.py           # копия ARB + gen_input
python -I -X utf8 ../scripts/sync_contracts.py --check   # идентичность
flutter pub get
flutter gen-l10n
dart run build_runner build -d
flutter analyze                                         # 0 issues
flutter test                                            # smoke: запуск до Splash
python -I -X utf8 ../scripts/check_layers.py            # 0 нарушений
```

## 7. Не сделано / за пределами RM-C-002

- `dart run custom_lint` (AC-RM-C-002 п. 3) — не выполняется: заменён `check_layers.py` (§4).
- Сборки `flutter build windows` / `apk` не запускались — RM-C-013; лицензии Android SDK не приняты
  (действие заказчика: `flutter doctor --android-licenses`). Для Android при RM-C-013 нужны
  `minSdk 24`, `FlutterFragmentActivity` (local_auth), `allowBackup=false` (06 §6.16).
- Платформенные каталоги `linux/`, `macos/`, `web/` оставлены как есть (вне R1, ADR-039): они
  создаются заново `flutter create` и не мешают сборке; удалить можно отдельным решением FE.
- Имя пакета `optomstroy` и `applicationId com.example.optomstroy` не менялись (RM-C-013 / релиз).
- `integration_test/` — QA (RM-C-014).

## 8. Интеграция этапа C (RM-C-013, RM-C-014) — изменения 2026-10-21

- `pubspec.yaml`: `flutter.fonts` — семейство Inter (400/500/600/700 из `assets/fonts/Inter`), `flutter.assets` —
  `assets/fonts/Inter/OFL.txt` (SCR-42). В Windows-сборке `FontManifest.json` содержит Inter; сетевых шрифтов нет.
- `dart_test.yaml`: объявлен тег `golden` (alchemist) — `flutter test --tags golden` без предупреждений.
- `app/bootstrap.dart`: `ClientMeta.load(FlutterSecureStorageAdapter())` → `clientMetaProvider` до `runApp`
  (ошибка платформы не роняет запуск).
- `core/network/backend_health.dart` + `core/di`: `backendHealthProbeProvider`, `backendHealthReportProvider`,
  `backendHealthProvider` (read-only для presentation, L-9) — `GET /health` от origin `API_BASE_URL`.
  Заглушка «нет сессии» (`features/auth/.../no_session_screen.dart`) показывает «Сервер недоступен», если
  `/health` не ответил 200; widget-тесты подменяют проверку `FakeBackendHealthProbe` (`test/support/`).
- `integration_test/boot_test.dart` (RM-C-014): `bootstrap()` → Splash → «нет сессии» → `GET /health`.
  Запуск: `pos-api: node scripts/local-stack.mjs serve` + `flutter test integration_test/boot_test.dart -d windows
  --dart-define-from-file=env/dev.json`.
- `env/dev.json`, `env/test.json` (RM-C-009 п. 6), `tool/run_dev.ps1|sh`. `env/prod.json` не создан (Q-032).
- Проверка секретов: ложные срабатывания `scripts/check_secrets.py` помечены `check-secrets: allow (…)`.
- Ручной код отформатирован `dart format` (ширина 120); сгенерированные файлы (`*.g.dart`, `*.freezed.dart`,
  `lib/core/enums.dart`, `lib/design_system/tokens/*`, `lib/core/l10n/*`) из проверки формата нужно исключать.
- Сборки: `docs/stages/C_builds.md`; биометрия: `docs/stages/C_biometric_prototype.md` — `biometric_storage`
  на Flutter 3.38.7 несовместим с `flutter_secure_storage` 11 (конфликт win32), 6.x требует Flutter ≥ 3.44.
- `app/router/app_router.dart`: служебный маршрут `/dev/gallery` (витрина DS, RM-C-003) — `devRoutes()` подключается
  только под `if (kDebugMode)` и без guard-ов; в release-AOT кода витрины нет (`docs/stages/C_builds.md` §2.1).

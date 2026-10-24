# Отчёт по этапу C — Foundation (каркасы, окружения, CI, тестовый контур) «Оптомстрой POS»

**Этап:** C — Foundation · **Задача фиксации этапа:** RM-C-014 · **Ворота:** G-C
**Дата отчёта:** 2026-10-22 · **Автор (владелец отчёта):** ARCH (13 §2.2; отчёт собран агентом-исполнителем RM-C-014, роль QA + ARCH) · **Независимый проверяющий:** QA-агент, `docs/reviews/C_foundation_review.md` (проверка выполнена **до** исправлений; исправления после неё повторно независимо не проверялись — см. C-KI-09)
**Основание:** 13_IMPLEMENTATION_ROADMAP §3.3 (RM-C-001…RM-C-015), §6.1–§6.3, §9; ядро R0 v1.9 (приоритет §24 … §16)

**Итог.** Каркас Flutter и NestJS собирается и тестируется на машине разработки. Повторный прогон 2026-10-22 01:13–01:17 (UTC+4) дал код 0 у всех ключевых команд: `flutter analyze` — 0 замечаний, `flutter test` — 332 теста, golden — 58, `npm test` — 126, `madge` — 0 циклов, `test:db` — 13, `test:worker` — 19, `test:integrations` — 38, `test:e2e` — 18 (+4 пропущены: блок через Caddy), `boot_test` против локального стека — PASS (§2). Не выполнены: ни одного запуска CI (нет хранилища кода и раннеров, Q-131); тестовый контур `docker compose` (нет Docker); `flutter build apk` (лицензии Android SDK не приняты заказчиком); протокол прототипа биометрии (нет Android-устройства); `gitleaks`, `oasdiff`, `make gen-client` (инструментов нет на машине, загрузка — с разрешения заказчика). **Статус ворот G-C — красный** (§4): открыты три блокера, все внешние, не дефекты кода.

---

## 1. Готовые файлы

Владельцы — по `CONTRIBUTING.md` §5 (= 13 §5.2). Все пути этапа в git не отслеживаются (`??`), коммитов этапа C нет. Версии контрактов этапом C не менялись (контракты B — 1.0.0); новый общий файл — `contracts/test-vectors/money.v1.json` (— → v1).

### 1.1. Статус задач этапа

«Закрыта» — все пункты критерия завершения выполнены и подтверждены запуском. «Частично» — часть пунктов не выполнена, причина указана. Ни одна задача, требующая CI, Docker или Android, не закрыта.

| Задача | Статус | Что подтверждено запуском | Что не выполнено (причина) |
|---|---|---|---|
| RM-C-001 Структура | частично | `check_repo_layout.py` — 0 ошибок (14 предупреждений); `check_secrets.py` — 0 находок в 837 файлах (§2, стр. 13–14) | `gitleaks detect` — нет на машине (замена — `check_secrets.py`; в CI — job `gitleaks`) |
| RM-C-002 Flutter-каркас | частично | п. 1: `flutter analyze` — 0 (стр. 1), `build_runner` — 0 (журнал, стр. 21); п. 2: `flutter test` — 332 passed, smoke до Splash (стр. 2); п. 4: `gen-l10n` — 0, `sync_contracts.py --check` — OK (стр. 15) | п. 3: `dart run custom_lint` не применим — `custom_lint` не ставится на Dart 3.10.7; замена — `scripts/check_layers.py` (0 нарушений, self-test 35/35, стр. 11–12), ADR-086 «Предложено». Версии пакетов ниже R3 §15 (`pos-app/NOTES.md` §1) |
| RM-C-003 Дизайн-система | закрыта | п. 1 `tokens_test` и `gen_tokens_dart.py --check` — 0 differ (стр. 16); п. 2 golden — 58 passed на compact/medium/expanded (стр. 3); п. 3 `touch_targets_test` — в составе 332; п. 4 Inter локально (журнал ЧАСТЬ 1, FontManifest) | — (golden-эталоны сняты только на Windows; Linux-эталоны CI не проверялись) |
| RM-C-004 Flutter core | частично | п. 1 `enums_contract_test`, п. 3 `schema_migration_test` и сверка таблиц 07 §11.2 — в составе 332; п. 2 деньги — общие векторы MV (`money_vectors_test.dart`) | п. 4 `make gen-client` — openapi-generator не загружен (ADR-085 принято как временное, ADR-086 п. 5 — «Предложено»); п. 2 «100 % веток» не измерено: в ЧАСТИ 1 журнала покрытие `core/utils` — 100 % строк, данные о ветвях `lcov` не выдал |
| RM-C-005 NestJS-каркас | частично | п. 1 `lint`/`build`/`test` — 0, 126 passed (стр. 4–7); п. 2 `enums.spec` — в unit; п. 3 `madge` — 0 циклов (стр. 5); п. 4 read-only guard — unit и e2e; п. 6 `GET /health` → 200 (стр. 10) | п. 5 `openapi-diff`/`oasdiff` — нет инструмента; замена — e2e «экспорт `/openapi.json` ⊆ контракт» (зелёный). `npm ci` в этом прогоне не повторялся. `Dockerfile` не собирался (нет Docker) |
| RM-C-006 Миграции и seed | частично | `test:db` — 13 passed (стр. 8): migrate под ролью мигратора, 64 таблицы, ключи `app_settings` = R0 §17.7, повтор — 0 изменений, Drizzle = БД (замена `drizzle-kit check`), выгрузка `docs/erd/schema_v1.sql` (замена `pg_dump`), п. 6 AC-DATA-169 — 0 совпадений (стр. 18), п. 7 `check_ddl_behavior.sql` из `pos-api/test/sql/` — OK (журнал) | п. 2 «контейнер `migrate`» — нет Docker (миграции применялись процессом `node dist/migrate.js` на embedded PostgreSQL 17); `drizzle-kit check` и `pg_dump` заменены тестами (нет `pg_dump` на машине) |
| RM-C-007 Worker | закрыта (локально) | `test:worker` — 19 passed: `SYNC_ALREADY_RUNNING`, dead-letter после N ретраев (стр. 9) | — |
| RM-C-008 Тестовый режим | частично | `test:integrations` — 38 passed: FakeSms → `dev_outbox`, FakeOnec из фикстур, prod отвергает fake/fixtures/test-OTP, `issue_test_jwt` проходит RBAC и падает при `APP_ENV=prod` (стр. 9); `EnvBanner` вне prod — widget-тесты; `issue_test_jwt.ts` вне `dist/` (`tsconfig.build.json` include `src/**`) | п. 1 «каталог из фикстур через API» — Catalog API этапа E; п. 4 «проверка содержимого образа» — образ не собирался (нет Docker) |
| RM-C-009 Окружения | частично | п. 2 `check_env_example.py` — 97/97, 0 лишних/недостающих (стр. 15); п. 4 `X_FILE` приоритетнее `X` и отказ прямых секретов вне dev — unit; п. 5 отказ старта без обязательной переменной — unit; п. 6 Windows-сборка с `env/dev.json` — 0 (журнал) | п. 1 `gitleaks detect` — нет на машине. `env/prod.json` нет (значения prod — Q-032) |
| RM-C-010 Логирование | частично | `logging_redaction.spec.ts` — в unit 126; эхо `X-Request-Id` клиента — e2e в процессе и запрос к реальному процессу (журнал ЧАСТЬ 2) | сквозной requestId «клиент → Caddy → API» не проверен: нет Docker/caddy |
| RM-C-011 CI | **не выполнена** | `.github/workflows/ci.yml` — YAML валиден, 12 jobs (стр. 20) | пп. 1–5: ни одного run — нет хранилища кода и раннеров (Q-131, O-23); branch protection не настроена |
| RM-C-012 Тестовый контур | **частично (основное не выполнено)** | п. 3 `check_compose_test.py` — порты только у `caddy` 80/443 (стр. 19); п. 4 «без Docker» — `pos-api/scripts/local-stack.mjs` (PostgreSQL 17 + migrate + seed + API) поднят в этом прогоне (стр. 10) | пп. 1–2 `docker compose … run --rm migrate`, `up -d && npm run test:e2e` — нет Docker |
| RM-C-013 Пробные сборки | **частично (основное не выполнено)** | `flutter build windows --release --dart-define-from-file=env/dev.json` — 0 (журнал ЧАСТЬ 2, 97 с); exe запущен, снимок `C_assets/windows_release_boot.png`; п. 3 — список для iOS в `C_builds.md` §4 | `flutter build apk --debug` — не запускалась (лицензии SDK не приняты, `ANDROID_HOME` указывает на JDK); CI-сборок нет; Splash «с версией» — версии на Splash пока нет (RM-D-007); п. 4 протокол (а)–(г) — нет Android-устройства, к тому же `biometric_storage` не разрешается рядом с `flutter_secure_storage` 11 на Flutter 3.38.7 (`C_biometric_prototype.md` §2); п. 5 ADR по D-13 — не принят |
| RM-C-014 Интеграционная сборка и отчёт | частично | `boot_test.dart -d windows` против local-stack — PASS: Splash → «нет сессии» → `GET /health` 200 с `X-Request-Id` (стр. 10); этот отчёт | `boot_test` против тестового контура (compose + Caddy) — нет Docker; критерий «логи всех команд RM-C-002…013, 015» — есть для выполненных команд, для невыполненных логов нет по определению |
| RM-C-015 Контроль версии | закрыта (локально) | e2e: 426 `APP_UPDATE_REQUIRED` + `X-Min-App-Version`, другая платформа — 200, заголовки в 2xx, `app_settings` приоритетнее env без перезапуска, `/health*` без проверки, N/N−1 → 200, N−2 → 426 (стр. 7); widget-тест SCR-90 и мягкого баннера (стр. 2) | чек-лист релиза `docs/release/<version>.md` — задача RM-H-007; имя ключа `app_store_url` и мягкий режим без заголовков — Q-153 |

### 1.2. Пути

| Путь | Новый / изменён | Задача `RM-*` | Владелец | Версия контракта (было → стало) | Примечание |
|---|---|---|---|---|---|
| `.editorconfig`, `.gitattributes`, `.gitignore`, `README.md`, `CONTRIBUTING.md`, `docs/repo_layout.md` | новые (`.gitignore`, `README.md` — изменены) | RM-C-001 | ARCH | — | старый Flutter-проект в корне удалён из рабочей копии и перенесён в `pos-app/` (`D` в git status) |
| `pos-app/pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `l10n.yaml`, `dart_test.yaml`, `NOTES.md`, `lib/main.dart`, `lib/app/**` | новые | RM-C-002 | FE | — | версии пакетов — под analyzer 8 (ADR-086) |
| `pos-app/lib/l10n/**` | новые | RM-C-002 | DS + FE | копия `contracts/l10n` 1.0.0 | сверка `sync_contracts.py --check` |
| `pos-app/lib/design_system/**`, `pos-app/assets/fonts/**`, `pos-app/test/design_system/**`, `pos-app/test/golden/**` | новые | RM-C-003 | DS | токены из `contracts/design-tokens` 1.0.0 | `tokens/*.dart` генерирует `scripts/gen_tokens_dart.py`; `components/env_banner.dart` — RM-C-008 |
| `pos-app/lib/core/**` (в т. ч. `enums.dart`, `database/**`, `network/**`, `config/environment.dart`), `pos-app/test/core/**` | новые | RM-C-004, RM-C-008, RM-C-015 | FE (SEC — `network/interceptors/auth`, `storage`, `hardware/biometric`) | — | `packages/pos_api_client` не создан (ADR-085) |
| `pos-app/lib/features/*/` (каркас, `.gitkeep`), `pos-app/test/widget/**` | новые | RM-C-002 | FE | — | фичи пустые, межфичевых импортов 0 |
| `pos-app/env/dev.json`, `env/staging.json`, `env/README.md`, `pos-app/tool/run_dev.sh`, `run_dev.ps1` | новые | RM-C-009 | FE / OPS | — | `prod.json` нет (Q-032) |
| `pos-app/integration_test/boot_test.dart` | новый | RM-C-014 | QA | — | |
| `pos-app/android/**`, `ios/**`, `windows/**`, `linux/**`, `macos/**`, `web/**` | новые (перенос шаблона) | RM-C-001, RM-C-013 | FE + SEC | — | `applicationId` `com.example.optomstroy`, `FlutterActivity` — правки до RM-D-008 (`C_builds.md` §3) |
| `pos-api/package.json`, `package-lock.json`, `tsconfig*.json`, `eslint.config.mjs`, `.prettierrc`, `.madgerc`, `vitest.config*.ts`, `README.md`, `Dockerfile`, `.dockerignore` | новые | RM-C-005 | BE | — | Dockerfile не собирался |
| `pos-api/src/**` (модули D-06, `common/**`, `main.ts`, `worker.ts`, `migrate.ts`, `integrations/**`) | новые | RM-C-005, RM-C-007, RM-C-008, RM-C-010, RM-C-015 | BE; SEC — `auth`, `registration`, `profile`, `common/rbac`, `notifications/sms` | `common/enums.ts` из `contracts/enums.json` 1.0.0 | адаптеры SMS/1С/QR в `src/integrations/*`, а не в путях 13 RM-C-008 — ADR-086 п. 4 |
| `pos-api/src/db/**`, `pos-api/seeds/0001_defaults.sql`, `pos-api/db/migrations-dev/0001_dev_outbox.sql` | новые | RM-C-006 | BE (data) | — | `migrations/0001_init.sql` изменён: DDL `dev_outbox` вынесен (AC-DATA-169) |
| `pos-api/test/**` (`db`, `e2e`, `integrations`, `worker`, `support`, `sql/check_ddl_behavior.sql`) | новые | RM-C-005…008, RM-C-012, RM-C-015 | QA (e2e), BE | — | `check_ddl_behavior.sql` перенесён из `scripts/` |
| `pos-api/scripts/issue_test_jwt.ts`, `local-stack.mjs`, `gen-permissions.mjs`, `clean-dist.mjs`, `drop-dart-enums.mjs` | новые | RM-C-008, RM-C-012 | SEC / BE | — | `issue_test_jwt.ts` не входит в `dist/` |
| `.env.example`, `infra/env/README.md` | новые | RM-C-009 | OPS | — | 97 переменных = 16 §4.3 |
| `infra/compose.test.yml`, `infra/caddy/Caddyfile`, `infra/docker/**`, `infra/README.md`, `infra/NOTES.md`, `Makefile` | новые | RM-C-010, RM-C-012 | OPS | — | не запускались (нет Docker, make, caddy) |
| `.github/workflows/ci.yml`, `docs/ci.md` | новые | RM-C-011 | OPS | — | ни одного run |
| `scripts/check_layers.py`, `check_repo_layout.py`, `check_secrets.py`, `check_env_example.py`, `check_no_double_money.sh`, `sync_contracts.py` | новые | RM-C-001, RM-C-002, RM-C-009, 13 §6.1 п. 7 | ARCH | — | |
| `contracts/test-vectors/money.v1.json` | новый | RM-C-004, RM-C-005 (ревью C-CR-01) | BE + FE (координация ARCH) | — → v1 | общие векторы денег MV для Dart и TS |
| `docs/erd/schema_v1.sql`, `docs/erd/README.md` | новые | RM-C-006 | BE (data) | — | `schema_v1.sql` выгружен тестом `test:db` (п. 9); ERD — из каталога PostgreSQL |
| `docs/stages/C_checks.log`, `C_builds.md`, `C_biometric_prototype.md`, `C_assets/windows_release_boot.png`, `docs/stages/C_foundation_report.md` | новые | RM-C-013, RM-C-014 | ARCH / QA | — | |
| `docs/reviews/C_foundation_review.md` | новый | 13 §6.1 п. 11 | QA | — | §5 дописан исполнителем исправлений, не проверяющим |
| `docs/specification/15_DECISION_LOG.md` | изменён | RM-C-002, RM-C-004 | ARCH | — | ADR-085, ADR-086 |

---

## 2. Выполненные проверки

Строки 1–20 — **свежий прогон этого отчёта**, 2026-10-22 01:13–01:17 (UTC+4), Windows 11 Pro 10.0.26200, Flutter 3.38.7 / Dart 3.10.7, Node 24.11.1, Python 3.13; выдержки вывода — §5.2. Полный вывод свежего прогона лежит во временном каталоге сессии и в репозиторий не записывался (запись разрешена только в этот файл). Строки 21–27 взяты из журнала `docs/stages/C_checks.log` (ЧАСТЬ 2, 2026-10-22 01:00–01:10) и в этом прогоне не повторялись: команды пишут файлы (`build_runner`) или заняли бы окно приложения (`flutter build windows`).

| № | Задача / критерий | Команда | Результат (код выхода, тесты, покрытие) | Где выполнено | Лог |
|---|---|---|---|---|---|
| 1 | AC-RM-C-002 п. 1 | `cd pos-app && flutter analyze` | код 0; «No issues found! (ran in 80.3s)» | локально, свежий прогон | §5.2 |
| 2 | AC-RM-C-002 п. 2; AC-RM-C-003 п. 1, 3; AC-RM-C-004 пп. 1–3; AC-RM-C-008 (EnvBanner); AC-RM-C-015 п. 3 | `cd pos-app && flutter test` | код 0; 332 passed, 0 failed («All tests passed!»), 30 с | локально, свежий прогон | §5.2 |
| 3 | AC-RM-C-003 п. 2 | `cd pos-app && flutter test --tags golden` | код 0; 58 passed (compact/medium/expanded, варианты Windows и CI) | локально, свежий прогон | §5.2 |
| 4 | AC-RM-C-005 п. 1 | `cd pos-api && npm run lint` (tsc + eslint + prettier) | код 0 | локально, свежий прогон | §5.2 |
| 5 | AC-RM-C-005 п. 3 | `cd pos-api && npm run madge` (`madge --circular src`) | код 0; 126 файлов, «No circular dependency found!» | локально, свежий прогон | §5.2 |
| 6 | AC-RM-C-005 п. 1 | `cd pos-api && npm run build` | код 0 | локально, свежий прогон | §5.2 |
| 7 | AC-RM-C-005 пп. 1, 2, 4; AC-RM-C-009 пп. 4–5; AC-RM-C-010; AC-RM-C-015 | `cd pos-api && npm test` (vitest, unit) | код 0; 12 файлов, 126 passed | локально, свежий прогон | §5.2 |
| 8 | AC-RM-C-006 пп. 1–7 (с заменами, §1.1) | `cd pos-api && npm run test:db` (embedded PostgreSQL 17) | код 0; 2 файла, 13 passed | локально, свежий прогон | §5.2 |
| 9 | AC-RM-C-007; AC-RM-C-008 пп. 2–4 | `npm run test:worker`; `npm run test:integrations` | код 0 / код 0; 19 passed / 38 passed | локально, свежий прогон | §5.2 |
| 10 | AC-RM-C-005 пп. 4, 6; AC-RM-C-015 пп. 1, 2, 4, 5; AC-RM-C-014 | `npm run test:e2e`; `node scripts/local-stack.mjs serve --ttl 360` + `curl -i /health`; `cd pos-app && flutter test integration_test/boot_test.dart -d windows --dart-define-from-file=env/dev.json` | e2e: код 0, 18 passed, 4 skipped (блок через Caddy, `runIf(VIA_PROXY)`); `/health` → `HTTP/1.1 200`, `X-Request-Id`, `X-Min-App-Version`; boot_test: код 0, 1 passed, `BackendHealthReport(ok: true, httpStatus: 200 …)` | локально (local-stack, не тестовый контур), свежий прогон | §5.2 |
| 11 | AC-RM-C-002 п. 3 (замена `custom_lint`, ADR-086) | `python -I -X utf8 scripts/check_layers.py` | код 0; файлов 111, импортов 450, нарушений 0 | локально, свежий прогон | §5.2 |
| 12 | то же | `python -I -X utf8 scripts/check_layers.py --self-test` | код 0; 35/35 | локально, свежий прогон | §5.2 |
| 13 | AC-RM-C-001 (`tree` = `repo_layout.md`) | `python -I -X utf8 scripts/check_repo_layout.py` | код 0; файлов 837, ошибок 0, предупреждений 14 | локально, свежий прогон | §5.2 |
| 14 | AC-RM-C-001 (секреты; замена `gitleaks`) | `python -I -X utf8 scripts/check_secrets.py` | код 0; 837 файлов, находок 0 | локально, свежий прогон | §5.2 |
| 15 | AC-RM-C-002 п. 4; AC-RM-C-009 п. 2 | `scripts/sync_contracts.py --check`; `scripts/check_env_example.py` | код 0 / код 0; l10n идентичны; ожидается 97, в `.env.example` 97, 0/0 | локально, свежий прогон | §5.2 |
| 16 | AC-RM-C-003 п. 1; контраст палитры B | `scripts/gen_tokens_dart.py pos-app/lib/design_system/tokens --check`; `scripts/check_contrast.py` | код 0 / код 0; «checked 8 files, 0 differ»; нарушений 0 | локально, свежий прогон | §5.2 |
| 17 | 13 §6.1 п. 7 | `bash scripts/check_no_double_money.sh` | код 0; 0 совпадений (`pos-app/lib` 111 файлов, `pos-api/src` 110) | локально, свежий прогон | §5.2 |
| 18 | AC-RM-C-006 п. 6 (AC-DATA-169) | `grep -cE 'CREATE TABLE.*dev_outbox' pos-api/migrations/*.sql` | 0 совпадений в обоих файлах (код grep 1 = «не найдено», ожидаемо) | локально, свежий прогон | §5.2 |
| 19 | AC-RM-C-012 п. 3 (статически, без Docker) | `python -I -X utf8 infra/docker/scripts/check_compose_test.py infra/compose.test.yml` | код 0; сервисы api, backup, caddy, migrate, postgres, worker; порты только `caddy: [80, 443]` | локально, свежий прогон | §5.2 |
| 20 | AC-RM-C-011 (только синтаксис); RBAC-каталог | разбор `ci.yml` через `yaml.safe_load`; `cd pos-api && npm run check:permissions` | код 0 / код 0; 12 jobs; «актуально (77 кодов, 7 ролей)» | локально, свежий прогон | §5.2 |
| 21 | AC-RM-C-002 п. 1 | `cd pos-app && dart run build_runner build -d` | код 0 | локально, 2026-10-22 | `C_checks.log` ЧАСТЬ 2, блок 1 |
| 22 | AC-RM-C-002 п. 4 | `cd pos-app && flutter gen-l10n` | код 0 | локально, 2026-10-21 | `C_checks.log` ЧАСТЬ 1 |
| 23 | AC-RM-C-013 п. 1 (Windows, локально); AC-RM-C-009 п. 6 | `cd pos-app && flutter build windows --release --dart-define-from-file=env/dev.json` | код 0; 97 с; Release ≈ 33,3 МБ (25 файлов), zip ≈ 14,4 МБ | локально, 2026-10-22 01:07 | `C_checks.log` ЧАСТЬ 2; `C_builds.md` §2 |
| 24 | AC-RM-C-013 п. 2 (только Windows) | запуск `optomstroy.exe` (Release) + снимок окна | процесс запущен, экран «нет сессии» SCR-01; Splash виден один кадр, версии на Splash нет | машина разработки, не POS заказчика | `C_assets/windows_release_boot.png`; `C_builds.md` §2.2 |
| 25 | AC-RM-C-006 пп. 2, 4, 7 (DDL без Docker) | `node tools/pg/run-sql.mjs --set app.env=test --repeat-strict … 0001_init.sql 0002_rbac_seed.sql db/migrations-dev/0001_dev_outbox.sql --check scripts/check_tables.sql`; то же с `--check pos-api/test/sql/check_ddl_behavior.sql`; prod без `app.env` | код 0; 64 таблицы (dev/test), 63 (prod), повтор — 0 изменений, поведенческие проверки — OK | локально, embedded PostgreSQL 17.10 | `C_checks.log` ЧАСТЬ 2 |
| 26 | AC-RM-C-010 (эхо requestId), AC-RM-C-015 п. 1 | `curl -i -H 'X-Request-Id: …' -H 'X-App-Version: 0.9.0' -H 'X-Platform: windows' http://127.0.0.1:3000/api/v1/__probe__` | `426 Upgrade Required`, тот же `X-Request-Id`, `code: APP_UPDATE_REQUIRED`, `X-Min-App-Version: windows=1.0.0` | local-stack, 2026-10-22 01:10 | `C_checks.log` ЧАСТЬ 2, блок 2 |
| 27 | AC-RM-C-013 п. 4 (совместимость пакета) | `flutter pub add biometric_storage:^5.0.1 --dry-run` и ещё 3 варианта | код 65 у всех (несовместимость с `flutter_secure_storage` 11 / Flutter ≥ 3.44 для 6.x) — ожидаемый результат проверки | локально, 2026-10-21 | `C_checks.log` ЧАСТЬ 1; `C_biometric_prototype.md` §2 |

**Не выполненные проверки** (не запускались — такая проверка не считается пройденной):

| Задача / критерий | Команда | Причина | Когда и кем будет выполнена |
|---|---|---|---|
| AC-RM-C-011 пп. 1–5 | все 12 jobs `ci.yml`; branch protection; тестовый PR с падающим тестом класса A | нет хранилища кода и раннеров (Q-131, O-23) | OPS — первый run после ответа заказчика по Q-131; до G-C |
| AC-RM-C-012 пп. 1–2 | `docker compose -f infra/compose.test.yml run --rm migrate`; `… up -d && npm run test:e2e`; `make test-up / test-smoke / test-check` | на машине нет Docker и make; CI не подключён | OPS + QA — job `test-contour` на Linux-раннере с Docker |
| AC-RM-C-013 п. 1 (Android) | `flutter build apk --debug --dart-define-from-file=env/dev.json` | лицензии Android SDK не приняты (действие заказчика), `ANDROID_HOME` указывает на JDK | FE — сразу после принятия лицензий; затем job `build-android-debug` |
| AC-RM-C-013 пп. 1–2 в CI | `build-windows`, `build-android-debug` с артефактами run | нет CI (Q-131) | OPS |
| AC-RM-C-013 п. 2 (Android) | запуск на Android-устройстве до Splash, скриншот | нет устройства (O-13) | FE — после получения устройства |
| AC-RM-C-013 пп. 4–5 | протокол чек-листа (а)–(г) на устройстве; ADR по D-13 | нет Android-устройства с биометрией класса 3; `biometric_storage` не ставится на Flutter 3.38.7 рядом с `flutter_secure_storage` 11 | FE + SEC — до старта RM-D-008; ARCH — ADR |
| AC-RM-C-001; AC-RM-C-009 п. 1 | `gitleaks detect` | gitleaks нет на машине; загрузка файла — с разрешения заказчика | OPS — job `gitleaks` в CI |
| AC-RM-C-005 п. 5 | `oasdiff` / `openapi-diff contracts/openapi/pos-api.v1.yaml http://localhost:3000/openapi.json` | инструмента нет (openapi-diff 0.24 не разбирает циклический `$ref`, ЧАСТЬ 1) | BE — job `openapi-diff` в CI |
| AC-RM-C-004 п. 4 | `make gen-client` (openapi-generator `dart-dio`) | jar генератора не загружен (JDK 17 есть), `make` нет; ADR-085/086 | FE — job `contracts-lint` шаг 4 в CI |
| AC-RM-C-005 (образ); AC-RM-C-008 п. 4 | `docker build` `pos-api` / `infra/docker/api`; проверка отсутствия `issue_test_jwt` в образе | нет Docker (статически: `dist/` его не содержит) | OPS — CI |
| AC-RM-C-010 (через proxy); AC-RM-C-014 | e2e через Caddy (`SMOKE_BASE_URL`), `caddy validate`, `boot_test` против тестового контура | нет Docker/caddy | QA — после RM-C-012 |
| AC-RM-C-008 п. 1 | e2e «каталог из фикстур через API» | Catalog API — этап E | BE — RM-E-* |
| 13 §6.1 п. 3 | `coverage-gate` (domain/data ≥ 80 %) | job не запускался; локально измерено только покрытие строк `core/utils`, `core/error` (100 %, ЧАСТЬ 1) | QA — CI |
| AC-RM-C-005 п. 1 | `npm ci` | в свежем прогоне не повторялся (последний — ЧАСТЬ 1, код 0) | CI |

---

## 3. Известные проблемы

Серьёзность — по 13 §6.2. Идентификаторы ревью — `docs/reviews/C_foundation_review.md` §3, §5.

| ID | Описание | Серьёзность | Обход | План (задача, срок) |
|---|---|---|---|---|
| C-KI-01 (C-BL-01) | CI не запускался ни разу: нет хранилища кода и раннеров Linux+Docker и Windows | **блокер** G-C | все команды CI выполнены локально, где это возможно (§2) | заказчик — Q-131/O-23; OPS — первый зелёный run, branch protection; до G-C |
| C-KI-02 (C-BL-02) | Тестовый контур `docker compose` не поднимался: migrate в контейнере, api-e2e и `boot_test` через Caddy не проверены | **блокер** G-C | `local-stack.mjs` (embedded PostgreSQL 17 + migrate + seed + API) — §2 стр. 10 | OPS + QA — job `test-contour` после C-KI-01 |
| C-KI-03 (C-BL-03) | apk не собран (лицензии SDK); протокол биометрии (а)–(г) и ADR по D-13 нет; `biometric_storage` 5.x несовместим с `flutter_secure_storage` 11, 6.x требует Flutter ≥ 3.44 | **блокер** G-C (для RM-D-008 — безусловный) | Windows-сборка и запуск — есть; варианты пути — `C_biometric_prototype.md` §2 | заказчик — лицензии, `ANDROID_HOME`, устройство (O-13); ARCH/FE — решение по версии Flutter или platform channel; ADR до RM-D-008 |
| C-KI-04 (C-MJ-06) | Нет `gen-client` и `oasdiff`; DTO клиента — ручные freezed (ADR-085), сверка — тестом | существенно | e2e «экспорт OpenAPI ⊆ контракт» (зелёный) | CI `contracts-lint` шаг 4 и `openapi-diff`; до G-C |
| C-KI-05 (C-MJ-10) | Flutter 3.38.7 / Dart 3.10.7: `custom_lint` не ставится, версии пакетов ниже R3 §15 | существенно | `check_layers.py` (§2 стр. 11–12) | ARCH — принять ADR-086 на G-C; обновление Flutter (ср. C-KI-03) |
| C-KI-06 (C-MJ-04, C-MN-03) | Caddyfile (requestId, `/health/ready` только из частных сетей) не проверен запуском | существенно | e2e эха `X-Request-Id` в процессе — зелёный | после C-KI-02 |
| C-KI-07 (C-MJ-11) | `gitleaks` не запускался | существенно | `check_secrets.py` — 0 находок в 837 файлах | CI job `gitleaks` |
| C-KI-08 | Покрытие ≥ 80 % (`coverage-gate`) не измерено; «100 % веток» денег (AC-RM-C-004 п. 2) не подтверждено — `lcov` дал только строки | существенно | 100 % строк `core/utils` (ЧАСТЬ 1); общие векторы MV на Dart и TS | QA — `coverage-gate` в CI; до G-H (гейт R1) |
| C-KI-09 | Исправления после независимой проверки (C-CR-01, C-CR-02, C-MJ-01…11, C-MN-01…08) повторно независимым проверяющим не проверялись; §5 ревью заполнен исполнителем исправлений | существенно | свежий прогон §2 — зелёный | QA — повторная проверка по 13 §6.1 п. 11 до решения по G-C |
| C-KI-10 | `dev_outbox` создаётся только при `APP_ENV=dev`, а 07 §5.63 упоминает `APP_ENV ∈ {dev, staging}` (FakeSmsGateway на staging) | существенно | контур CI работает с `APP_ENV=dev` | ARCH + владелец 07 — до RM-D-002 |
| C-KI-11 | Splash без версии и логотипа; заголовок окна `optomstroy`; `applicationId`/bundle id `com.example.optomstroy`; `MainActivity` — `FlutterActivity` без `USE_BIOMETRIC` | незначительно | — | RM-D-007 (брендинг), до RM-D-008 (Android) |
| C-KI-12 (C-MN-01) | Общий 503 без кода отображается в `500 INTERNAL`: в 08 §2.4 нет общего 503-кода | незначительно | модули бросают 503 со своим кодом | владелец 08 (BE) |
| C-KI-13 (C-MN-09) | Мягкий режим при отсутствии `X-App-Version`/`X-Platform` (пропуск с предупреждением) | незначительно | — | заказчик — Q-153 до G-H |
| C-KI-14 | Для Windows-поставки на POS нужен VC++ Redistributable, в каталог Release не входит; Windows-POS заказчика нет (запуск — на машине разработки) | незначительно | — | OPS — RM-H (формат дистрибуции); O-13 |

Критичные дефекты кода, найденные проверкой (C-CR-01 — распределение скидки на backend, C-CR-02 — освобождение ключа идемпотентности после COMMIT), исправлены исполнителем. Тесты на них входят в unit 126 и проходят в свежем прогоне (§2, стр. 7). Независимого подтверждения закрытия нет (C-KI-09).

**Действующие допущения:**

| Q-NNN | Принятое допущение | Какие задачи от него зависят | Последствие при другом ответе |
|---|---|---|---|
| Q-131 | GitHub + GitHub Actions, раннеры Linux (Docker) и Windows (`ci.yml`) | RM-C-011, RM-C-012, RM-C-013 (CI-сборки) | перенос `ci.yml` на другую платформу; jobs и команды те же (`docs/ci.md`) |
| Q-008 | Android (minSdk 24) и Windows 10/11 x64; iOS — только список требований (`C_builds.md` §4) | RM-C-013 | при iOS в R1 — Mac-раннер, Apple Developer, правки `ios/` |
| Q-153 | Ключ `app_settings.app_store_url`; мягкий режим без заголовков версии | RM-C-015, RM-H-007 | переименование ключа и включение жёсткого режима — конфигурация и тест |
| Q-032 | `env/prod.json` не создаётся до значений prod | RM-C-009, RM-H | добавить файл профиля |
| Q-030 / ADR-082 | Сценарий A: Linux + Docker Compose (`compose.test.yml` повторяет схему) | RM-C-012, RM-I-001 | новая схема развёртывания, пересмотр `infra/` |
| ADR-083 (Предложено) | Перечень мутаций при `APP_READ_ONLY` по умолчанию пуст (SEC-119: все мутации → 503); перечень ADR-083 подставляется явно в тестах | RM-C-005 п. 4 | после принятия ADR-083 — замена значения по умолчанию одной строкой |
| Q-303 | «Супер-админ» = `admin` | не влияет на C | — |

---

## 4. Условия перехода дальше

- **Статус ворот G-C: красный** (13 §6.2: «есть открытые блокеры — переход запрещён»). Открыты три блокера C-KI-01…03. Все они зависят от окружения или заказчика, дефектами кода не являются. Критичных дефектов кода в открытом статусе нет.

| Условие ворот (13 §3.3) | Выполнено? | Доказательство (раздел 2, № строки) |
|---|---|---|
| RM-C-002 закрыта | частично: пп. 1, 2, 4 — да; п. 3 — замена `check_layers.py` (ADR-086 «Предложено») | 1, 2, 11, 12, 15, 21, 22 |
| RM-C-004 закрыта | частично: пп. 1, 3 — да; п. 2 — строки 100 %, ветви не измерены; п. 4 — нет | 2; «Не выполненные» |
| RM-C-005 закрыта | частично: пп. 1–4, 6 — да; п. 5 — замена e2e, `oasdiff` нет | 4–7, 10 |
| RM-C-006 закрыта | частично: проверено на embedded PostgreSQL 17, без контейнера `migrate`; `drizzle-kit`/`pg_dump` заменены тестами | 8, 18, 25 |
| RM-C-011 закрыта (CI зелёный на Linux с Docker и Windows) | **нет** | 20 (только синтаксис) |
| RM-C-012 закрыта | **нет** (п. 3 статически, п. 4 — да; пп. 1–2 — нет) | 10, 19 |
| RM-C-015 закрыта | да (локально; CI не запускался) | 2, 7, 10, 26 |
| RM-C-013 — обе сборки проходят | **нет**: Windows — да (локально), apk — нет | 23, 24 |
| RM-C-014 — отчёт сдан | да (этот файл); `boot_test` — против local-stack, не против контура | 10 |
| Независимая проверка каркаса QA без блокеров | **нет**: проверка выполнена, в ней 3 блокера (= C-KI-01…03); исправления повторно не проверены (C-KI-09) | `docs/reviews/C_foundation_review.md` |

- **Что можно перевести «на жёлтый».** Решение принимает ARCH (при необходимости — с письменного согласия заказчика). Отчёт его не принимает. Основание для перевода — 13 §6.2 «жёлтый: блокеры и критичные закрыты, остались существенные с планом». Это возможно, только если ARCH переклассифицирует C-KI-01 и C-KI-02 из блокеров ворот в существенные проблемы с планом «первый зелёный run CI и контур — в течение этапа D», потому что код для них готов (`ci.yml`, `compose.test.yml`, `Makefile`) и локальные аналоги зелёные (§2). Жёлтый статус по 13 §6.2 допускает старт **только backend/ONEC-задач** этапа D (RM-D-001…006 и т. п.). Нельзя переводить «на жёлтый» и стартовать без отдельного условия:
  - RM-D-008 (биометрия): нужен протокол (а)–(г) на устройстве и ADR по D-13 (ядро §21 п. 2; 13 RM-C-013 п. 5) — C-KI-03 для него остаётся блокером в любом случае;
  - клиентские задачи D, требующие Android-сборки, — до сборки apk.
  Для жёлтого также нужны: принятие ARCH ADR-086 и повторная независимая проверка исправлений (C-KI-09).
- **Условия зелёного G-C:** первый зелёный run всех 12 jobs `ci.yml` на Linux (Docker) и Windows, branch protection; `docker compose` контура со smoke и `boot_test` через Caddy; `flutter build apk --debug` — код 0 в CI и запуск на устройстве; протокол биометрии и ADR по D-13; `gitleaks`, `oasdiff`, `gen-client`, `coverage-gate` — в CI; повторная независимая проверка без блокеров.

- **Что требуется от заказчика** (13 §9):

| Действие / вопрос | Для какой задачи | Срок (ворота) |
|---|---|---|
| O-23 / Q-131: решение о хранилище кода и CI-платформе; раннеры Linux с Docker и Windows | RM-C-011, RM-C-012, RM-C-013 (CI-сборки); C-KI-01, C-KI-02, C-KI-04, C-KI-07, C-KI-08 | до G-C |
| Принять лицензии Android SDK (`flutter doctor --android-licenses`) и исправить `ANDROID_HOME` (сейчас указывает на `C:\Program Files\Java\jdk-17`) | RM-C-013 п. 1 (apk); C-KI-03 | до G-C |
| O-13: Android-устройство с биометрией класса 3 (`BIOMETRIC_STRONG`), Windows-POS | RM-C-013 пп. 2, 4; ADR по D-13; RM-D-008 | до G-C (минимум) |
| Разрешение на загрузку инструментов разработки: openapi-generator-cli 7.x (jar), oasdiff, gitleaks — или их запуск только в CI | RM-C-004 п. 4, RM-C-005 п. 5, RM-C-001/009 (gitleaks) | до G-C |
| Решение по версии Flutter (≥ 3.44 для `biometric_storage` 6.x и набора R3 §15) — совместно с ARCH; либо согласие на собственный platform channel | RM-C-013 п. 5, ADR-086, RM-D-008 | до старта RM-D-008 |
| Q-153: имя ключа ссылки на магазин приложений и жёсткий режим проверки версии | RM-C-015, RM-H-007 | до G-H |
| Q-032: значения профиля prod | RM-C-009 (`env/prod.json`), RM-H | до G-H |

- **Решения, принятые на этапе** (`docs/specification/15_DECISION_LOG.md`):
  - ADR-085 — Dart-DTO клиента до появления генератора (ручные freezed-DTO, `packages/pos_api_client` не создаётся до Java 11+). Статус: **Принято (временное решение до RM-C-011)**.
  - ADR-086 — каркас на Flutter 3.38.7 / Dart 3.10.7: `check_layers.py` вместо `custom_lint`, версии под analyzer 8, адаптеры в `src/integrations/*`, уточнение ADR-085. Статус: **Предложено**, решение ARCH на G-C.
  - ADR по пути криптопривязки биометрии (уточнение ADR-013) — **не принят** (нет протокола).

---

## 5. Приложения

### 5.1. Документы и логи

- Отчёт независимой проверки: `docs/reviews/C_foundation_review.md`. Проверяющий — QA-агент, 2026-10-22. Вывод: G-C красные, 3 блокера (внешние), 2 критичных, 11 существенных, 9 незначительных. §5 — статус исправлений, его записал исполнитель исправлений.
- Журнал команд этапа: `docs/stages/C_checks.log`. ЧАСТЬ 1 — сборка каркаса, 2026-10-21. ЧАСТЬ 2 — повтор после исправлений, 2026-10-22, полный вывод с кодами выхода.
- Сборки: `docs/stages/C_builds.md` (версии SDK, состав и размер артефакта, SHA-256, требования iOS). Прототип биометрии: `docs/stages/C_biometric_prototype.md` (статус «ожидает устройства»).
- Снимок Release-сборки Windows: `docs/stages/C_assets/windows_release_boot.png` (экран «нет сессии» SCR-01).

### 5.2. Свежий прогон 2026-10-22 01:13–01:17 (UTC+4) — выдержки вывода

```
$ cd pos-app && flutter analyze
Analyzing pos-app...
No issues found! (ran in 80.3s)
exit=0 dur=84s

$ cd pos-app && flutter test
00:17 +331: …/test/golden/design_system_golden_test.dart: масштаб текста 1.3× (A11Y-005) inputs · compact · 1.3× (variant: CI)
00:18 +332: All tests passed!
exit=0 dur=30s

$ cd pos-app && flutter test --tags golden
00:07 +58: All tests passed!
exit=0 dur=41s

$ cd pos-api && npm test
 Test Files  12 passed (12)
      Tests  126 passed (126)
exit=0 dur=9s

$ cd pos-api && npm run madge
> madge --circular src
Processed 126 files (2.2s)
✔ No circular dependency found!
exit=0 dur=4s

$ cd pos-api && npm run lint
> tsc -p tsconfig.json --noEmit && eslint "src/**/*.ts" "test/**/*.ts" "scripts/**/*.ts" "scripts/**/*.mjs" && prettier --check …
All matched files use Prettier code style!
exit=0 dur=19s

$ cd pos-api && npm run build
exit=0 dur=5s

$ cd pos-api && npm run test:db
 Test Files  2 passed (2)
      Tests  13 passed (13)
exit=0 dur=34s

$ cd pos-api && npm run test:worker
 Test Files  3 passed (3)
      Tests  19 passed (19)
exit=0 dur=45s

$ cd pos-api && npm run test:integrations
 Test Files  5 passed (5)
      Tests  38 passed (38)
exit=0 dur=31s

$ cd pos-api && npm run test:e2e
 Test Files  2 passed (2)
      Tests  18 passed | 4 skipped (22)
exit=0 dur=37s

$ cd pos-api && node scripts/local-stack.mjs serve --ttl 360   (фон; пароль БД не выводится)
[local-stack] PostgreSQL 17.10 на 127.0.0.1:61829
[local-stack] migrate: migrate: готово applied=["0001_init.sql","0002_rbac_seed.sql"]
[local-stack] migrate --seed: seed: вставлено строк 39 inserted={"app_settings":30,"customers":1,"price_lists":1,"role_discount_limits":7}
[local-stack] migrate --seed: seed: 0 изменений inserted={"app_settings":0,"customers":0,"price_lists":0,"role_discount_limits":0}
$ curl -sS -i http://127.0.0.1:3000/health
HTTP/1.1 200 OK
X-Request-Id: 01a16052-ffff-76d9-9cc1-5dcbd9ef7f0e
X-Min-App-Version: android=1.0.0,windows=1.0.0

$ cd pos-app && flutter test integration_test/boot_test.dart -d windows --dart-define-from-file=env/dev.json
√ Built build\windows\x64\runner\Debug\optomstroy.exe
00:00 +0: boot: Splash → «нет сессии» → GET /health с тестового контура
boot_test: API_BASE_URL=http://127.0.0.1:3000/api/v1 → BackendHealthReport(ok: true, httpStatus: 200, requestId: 01a16053-a39c-7742-9637-fd7209ad0015, error: null)
00:01 +1: All tests passed!
exit=0 dur=43s

$ python -I -X utf8 scripts/check_layers.py            → файлов 111, импортов 450, нарушений 0            exit=0
$ python -I -X utf8 scripts/check_layers.py --self-test → self-test: 35/35 проверок пройдено              exit=0
$ python -I -X utf8 scripts/check_repo_layout.py        → файлов 837; ошибок 0, предупреждений 14, ожидающих задач 8   exit=0
$ python -I -X utf8 scripts/check_secrets.py            → файлов проверено: 837; находок: 0                exit=0
$ python -I -X utf8 scripts/sync_contracts.py --check   → OK l10n: 3 файл(ов) идентичны                    exit=0
$ python -I -X utf8 scripts/check_env_example.py        → ожидается 97, в .env.example 97; недостающих 0, лишних 0; ошибок 0   exit=0
$ python -I -X utf8 scripts/gen_tokens_dart.py pos-app/lib/design_system/tokens --check → checked 8 files, 0 differ   exit=0
$ python -I -X utf8 scripts/check_contrast.py           → violations 0; mismatches 0; RESULT: OK          exit=0
$ bash scripts/check_no_double_money.sh                 → OK — 0 совпадений (pos-app/lib: 111, pos-api/src: 110)   exit=0
$ grep -cE 'CREATE TABLE.*dev_outbox' pos-api/migrations/*.sql → 0001_init.sql:0, 0002_rbac_seed.sql:0   exit=1 (не найдено — ожидаемо)
$ python -I -X utf8 infra/docker/scripts/check_compose_test.py infra/compose.test.yml
  сервисы: api, backup, caddy, migrate, postgres, worker; опубликованные порты: {'caddy': [80, 443]}; ИТОГ: OK   exit=0
$ python … yaml.safe_load('.github/workflows/ci.yml')   → YAML OK; jobs: 12 (contracts-lint, api-lint-test, api-e2e,
  test-contour, openapi-diff, app-analyze-test, app-golden, build-windows, build-android-debug, gitleaks,
  security-class-a, coverage-gate)                                                                          exit=0
$ cd pos-api && npm run check:permissions               → gen-permissions: актуально (77 кодов, 7 ролей)    exit=0
$ command -v gitleaks oasdiff docker caddy openapi-generator-cli make psql → ничего не найдено (инструментов нет)
```

# Структура монорепозитория «Оптомстрой POS» (целевая)

Основание: задачи **RM-C-001** (структура репозитория) и **RM-B-012** (правила изменения). Владелец файла — `ARCH` (13 §5.2). Критерий RM-C-001: вывод `tree -L 2` совпадает с этим документом (§2).

Этот документ задаёт **целевое** дерево. Каталоги создают задачи, указанные в таблицах: этап B — контракты, этап C — каркасы, этапы D–I — остальное. Каталог, которого ещё нет, — это не ошибка, если его задача не закрыта. Каталог или файл верхнего уровня, которого нет в §2, — ошибка. Новый каталог верхнего уровня появляется только через ADR (CONTRIBUTING.md §8 п. 4).

---

## 1. Текущее состояние и перенос (RM-C-001)

**Статус на 2026-10-21: перенос выполнен (RM-C-001).** Шаблон Flutter перенесён в `pos-app/` обычным `mv`, без `git mv`. Коммита нет: в `git status` перенос виден как удаление старых путей и новый каталог `pos-app/`. Сгенерированные каталоги не переносились:

- `.dart_tool/` убран из корня, `flutter pub get` в `pos-app/` создал его заново;
- `build/` в корне не было.

IDE-кеш `.idea/` (игнорируется git) перенесён в `pos-app/.idea/` вместе с `optomstroy.iml`, на который он ссылается. В корне его больше нет.

Ниже — таблица переноса в исходной редакции (для истории). Решения «удалить или оставить» по `linux/`, `macos/`, `web/` и `optomstroy.iml` остаются за `FE` в RM-C-002.

До переноса в корне лежал стартовый шаблон Flutter, этап 1 его не трогал (13 P-1). Он переносится в `pos-app/` **только** задачей RM-C-001, после ворот G-B2. До этого `lib/`, `pubspec.yaml`, `android/`, `ios/` и остальные файлы шаблона не изменяются.

| Сейчас (корень) | После RM-C-001 | Примечание |
|---|---|---|
| `lib/`, `test/` | `pos-app/lib/`, `pos-app/test/` | содержимое шаблона заменяется каркасом RM-C-002 (R3 §14.1) |
| `android/`, `ios/`, `windows/` | `pos-app/android/`, `pos-app/ios/`, `pos-app/windows/` | платформы R1: Android, Windows; iOS — архитектурно (ADR-039) |
| `linux/`, `macos/`, `web/` | `pos-app/linux/`, `pos-app/macos/`, `pos-app/web/` | переносятся как есть; вне целевых платформ R1 (ADR-039). Удалить их или оставить, решает `FE` в RM-C-002 |
| `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml` | `pos-app/` | `pubspec.yaml` — по R3 §15 (RM-C-002) |
| `optomstroy.iml` | `pos-app/` или удаляется | файл IDE; решение `FE` в RM-C-002 |
| `README.md` | `README.md` (переписывается) | команды запуска — выход RM-C-001 |
| `resursi/` | `resursi/` (без изменений) | материалы заказчика (макеты, логотип); не изменяются |
| `docs/`, `contracts/`, `tools/`, `scripts/`, `pos-api/migrations/` | на месте | появились на этапах 1 и B |

---

## 2. Целевое дерево — уровни 1–2 (нормативно, сверка `tree -L 2`)

```
.
├── .editorconfig                   # RM-C-001
├── .env.example                    # RM-C-009 — перечень переменных 16 §4.3, без значений секретов
├── .gitattributes                  # RM-C-001 — LF, UTF-8
├── .github/                        # RM-C-011 — workflows CI (или infra/ci/, Q-131)
│   └── workflows/
├── .gitignore                      # без секретов: .env, secrets/, *.pfx, ключи
├── CONTRIBUTING.md                 # RM-B-012 — правила изменения контрактов, владельцы, CI
├── Makefile                        # RM-C-011, RM-C-012 — цели test-*, check-contracts, gen (docs/ci.md)
├── README.md                       # RM-C-001 — назначение и команды запуска
├── contracts/                      # этап B — машинно-проверяемые контракты (13 §5.1)
│   ├── NOTES_enums.md              # RM-B-009 — заметки исполнителя (решения по неоднозначностям)
│   ├── design-tokens/              # RM-B-006 — tokens.json, tokens.schema.json (DS)
│   ├── enums.json                  # RM-B-009 — enum-ы и коды ошибок (BE)
│   ├── enums.schema.json           # RM-B-009
│   ├── l10n/                       # RM-B-007 — app_ru.arb, app_ky.arb, app_en.arb (DS + FE)
│   ├── legal/                      # RM-A-007 — consents_ru.md (заказчик / SEC)
│   ├── onec/                       # RM-B-004 — onec-http-service.v1.yaml, odata-allowlist.yaml, fixtures/ (ONEC)
│   ├── openapi/                    # RM-B-003 — pos-api.v1.yaml, CHANGELOG.md (BE)
│   ├── rbac/                       # RM-B-008 — permissions.yaml (SEC)
│   └── test-vectors/               # RM-C-004/005 (MNY-004) — money.v1.json: общие векторы MV-01…MV-30 для pos-api и pos-app (BE + FE)
├── demo/                           # ADR-109 — демо-пакет на тестовых данных: build-demo.ps1, start-demo.ps1/.cmd, demo-common.ps1, README.md (app/, data/, logs/ — вне git)
├── docs/                           # документация (ARCH; владельцы подкаталогов — 13 §5.2)
│   ├── customer/                   # документы для заказчика: Voprosy_zakazchiku.md/.docx — сводные вопросы заказчику (ARCH; 2026-10-28)
│   ├── discovery/                  # этап A — аудит сервера, сведения 1С, SMSPro, устройства
│   ├── erd/                        # RM-B-005, RM-C-006 — ER-диаграммы, schema_v1.sql
│   ├── integration/                # RM-B-014 и др. — журнал версий расширения 1С, подключения
│   ├── ops/                        # этап D (INT-02/DQ-27, EQ-AUTH-07) — эксплуатационные инструкции: first_admin.md (OPS)
│   ├── pilot/                      # этап I — пилот, инструкции, откат (POS)
│   ├── deploy/                     # этап I — установка, runbook, передача (OPS)
│   ├── release/                    # RM-C-015, RM-H-007 — чек-листы релизов
│   ├── research/                   # этап 1 — R0 (ядро решений), R1…R8
│   ├── reviews/                    # отчёты независимой проверки (QA)
│   ├── perf/                       # этапы E, H — бенчмарки
│   ├── specification/              # ТЗ 00…18 + visual/ (в т. ч. visual/prototype/ — утверждённый прототип экрана выбора товаров 2026-10-29, эталон ADR-111/ADR-112), source/ (ARCH; только через ADR)
│   ├── stages/                     # ворота и отчёты этапов: B_approval.md, B_changes.md, <X>_<name>_report.md
│   ├── templates/                  # RM-B-012 — stage_report.md, adr.md
│   ├── PROGRESS_LOG.md
│   └── repo_layout.md              # этот файл
├── infra/                          # OPS — развёртывание и тестовый контур (16)
│   ├── NOTES.md                    # RM-B-011, RM-B-012 — заметки исполнителя
│   ├── README.md                   # RM-B-011 — целевая схема
│   ├── caddy/                      # RM-C-010 — Caddyfile
│   ├── compose.test.yml            # RM-C-012 — тестовый контур
│   ├── docker/                     # RM-C-005, RM-C-012 — Dockerfile api (стадии runtime / test-fixtures — фикстуры 1С контура, FQ-INT-08 / release) и backup, initdb postgres, скрипты контура
│   └── env/                        # RM-C-009 — README.md (конвенция *_FILE, ротация)
├── onec-extension/                 # ONEC — контракт, журнал и копии версий расширения «OptomstroyPOS» от специалиста 1С
├── pos-api/                        # BE — NestJS 12 / Node 24, модульный монолит (api + worker)
│   ├── .dockerignore               # RM-C-005 — контекст сборки pos-api/Dockerfile
│   ├── .gitignore                  # RM-C-005 — dist/, coverage/, node_modules/
│   ├── .madgerc                    # RM-C-005 — настройки `npm run madge` (циклы импортов)
│   ├── .prettierignore             # RM-C-005 — исключения форматирования
│   ├── .prettierrc                 # RM-C-005 — стиль кода (`npm run lint`)
│   ├── Dockerfile                  # RM-C-005 — Node 24-alpine, non-root
│   ├── README.md                   # RM-C-005 — запуск, скрипты npm, наборы тестов
│   ├── eslint.config.mjs           # RM-C-005 — правила eslint (в т. ч. no-restricted-imports слоёв)
│   ├── assets/                     # RM-F-004 — fonts/ (Inter-Regular/Bold.ttf, OFL.txt) и templates/pdf/*.json + README.md печатных форм (Q-019); путь от dist/ (../assets), в образ — стадия runtime (16 §4.4 прим. (1), FQ-INT-09)
│   ├── db/                         # RM-C-006 п. 6 — migrations-dev/ (dev_outbox, только APP_ENV=dev; в образ не входит, 07 §5.63)
│   ├── migrations/                 # RM-B-005, RM-B-008, RM-C-006 — 0001_init.sql, 0002_rbac_seed.sql, …
│   ├── package.json                # RM-C-005
│   ├── scripts/                    # RM-C-008 — issue_test_jwt.ts (только dev/staging)
│   ├── seeds/                      # RM-C-006 — *.sql
│   ├── src/                        # RM-C-005 — модули D-06, common/, db/, integrations/, jobs/, sync/, worker.ts, migrate.ts
│   ├── test/                       # RM-C-012 и далее — e2e/ (QA), db/, integrations/, worker/, sql/ (RM-C-006 п. 7)
│   ├── tsconfig.build.json         # RM-C-005 — сборка dist/ (`npm run build`)
│   ├── tsconfig.json               # RM-C-005 — проверка типов src/, test/, scripts/ (`npm run lint`)
│   ├── vitest.config.cov-all.ts    # покрытие всех наборов (`npm run test:cov:all`)
│   ├── vitest.config.cov-d.ts      # RM-D — покрытие этапа D (`npm run test:cov:d`)
│   ├── vitest.config.cov-e.ts      # RM-E — покрытие этапа E (`npm run test:cov:e`)
│   ├── vitest.config.cov-f.ts      # RM-F-009 — покрытие этапа F и пороги ветвей критичных файлов (`npm run test:cov:f`; исключения — docs/stages/F_branch_exceptions.md)
│   ├── vitest.config.e2e.ts        # RM-C-012 — e2e (smoke, rbac-matrix; `npm run test:e2e`)
│   └── vitest.config.ts            # RM-C-005 — unit (`npm test`)
├── pos-app/                        # FE — Flutter (Android, Windows; iOS — архитектурно)
│   ├── .metadata                   # RM-C-001 — служебный файл Flutter (перенесён из корня, в git)
│   ├── analysis_options.yaml       # RM-C-002
│   ├── android/                    # FE + SEC (нативная биометрия, разрешения)
│   ├── assets/                     # DS — fonts/ (Inter), rive/, логотип
│   ├── env/                        # RM-C-009 — профили --dart-define-from-file: dev.json, staging.json (= APP_ENV)
│   ├── integration_test/           # QA
│   ├── ios/
│   ├── l10n.yaml                   # RM-C-002
│   ├── lib/                        # RM-C-002 — app/, core/, design_system/, features/, l10n/ (R3 §14.1)
│   ├── linux/                      # RM-C-001 — перенесён из шаблона; вне платформ R1 (ADR-039), судьба — FE в RM-C-002
│   ├── macos/                      # RM-C-001 — то же
│   ├── packages/                   # RM-C-004 — pos_api_client (генерируется из OpenAPI)
│   ├── pubspec.yaml                # RM-C-002
│   ├── test/                       # unit/, widget/, golden/, design_system/
│   ├── tool/                       # RM-C-009 — run_*.sh | run_*.ps1
│   ├── web/                        # RM-C-001 — то же
│   └── windows/
├── resursi/                        # материалы заказчика — не изменяются
├── scripts/                        # проверочные и генерирующие скрипты контрактов и CI (ARCH)
└── tools/                          # служебные инструменты разработки (ARCH)
    └── pg/                         # раннер PostgreSQL 17 без Docker (локальные проверки DDL)
```

Для сверки RM-C-001 учитываются каталоги и перечисленные файлы. Файлы, которые создают сами инструменты (`pubspec.lock`, `package-lock.json`, `node_modules/`, `.dart_tool/`, `build/`, `__pycache__/`), игнорируются и не попадают в git, кроме lock-файлов. Дополнительные файлы внутри каталогов уровня 2 (например, `docs/ci.md`, `docs/owner_actions.md`) допускаются, если их вводит задача 13.

Сверка выполняется командой `python -I -X utf8 scripts/check_repo_layout.py --tree` (RM-C-001). Это замена `tree -L 2`: в Git Bash для Windows утилиты `tree` нет. Скрипт берёт файлы, которые могут попасть в git (`git ls-files` и неигнорируемые новые), поэтому IDE-кеш и сгенерированные каталоги не мешают. Коды выхода:

- 0 — нет ошибок;
- 1 — есть элемент уровня 1 или каталог уровня 2, которого нет в §2.

Неперечисленные файлы уровня 2 скрипт выдаёт как предупреждения, ещё не созданные элементы — как информацию.

Нормативный перечень каталогов уровня 1 (для скрипта сверки):

```
.github contracts demo docs infra onec-extension pos-api pos-app resursi scripts tools
```

---

## 3. Глубже уровня 2 (справочно)

### 3.1. `pos-app/lib/` (R3 §14.1; ADR-005)

```
pos-app/lib/
├── main.dart
├── app/            # app.dart, router/ (go_router, guards), bootstrap.dart
├── core/           # config/, error/, network/ (interceptors, app_version_interceptor.dart), database/ (drift, 07 §11.2),
│                   # storage/, sync/, hardware/, connectivity/, utils/ (Money, Qty, PhoneNumber), di/, enums.dart (генерация)
├── design_system/  # tokens/ (генерация из contracts/design-tokens), theme/, components/, animations/
├── features/       # <feature>/{domain,data,presentation} — фичи не импортируют друг друга (только domain владельца)
└── l10n/           # копия contracts/l10n/app_*.arb (scripts/sync_contracts.py --check)
```

### 3.2. `pos-api/src/` (ADR-006, D-06; 13 §5.2)

```
pos-api/src/
├── auth/ registration/ profile/          # SEC
├── catalog/ cart/ orders/ payments/ customers/ transactions/ returns/ admin/ notifications/ health/   # BE
├── integrations/                         # infra-порты 06 §7.3 (п. 5) и их адаптеры — фактическое размещение этапа C:
│   ├── sms/                              #   SEC — SmsGateway, SmsProXmlGateway, FakeSmsGateway (13 RM-C-008: «notifications/sms/fake/**»)
│   ├── onec/                             #   ONEC — OnecGateway, FakeOnecGateway, фабрика по ONEC_MODE (13: «sync/adapters/fake/**»)
│   └── payments/                         #   BE — PaymentProvider: OnecQrProvider, ManualQrProvider (ARCH-063)
├── sync/                                 # ONEC — планировщик (scheduler/), модуль sync; адаптеры 1С — integrations/onec/
├── jobs/                                 # BE — worker-runtime pg-boss, обработчики sync/outbox (RM-C-007)
├── common/                               # BE; common/rbac, common/audit — SEC; enums.ts (генерация); app-version/; logging/
├── db/                                   # BE (data) — Drizzle-схема
├── main.ts  worker.ts  migrate.ts
```

Пути адаптеров (ревью C-MJ-11). 13 RM-C-008 называет пути `src/notifications/sms/fake/**` и `src/sync/adapters/fake/**`, 06 §7.3 — «infra-порты» (`infra/bank` для `PaymentProvider`). Каркас этапа C разместил все infra-адаптеры в одном каталоге `src/integrations/{sms,onec,payments}`: правила импорта ARCH-063 п. 4 (payments → onec только `import type`) проверяются тестом `test/integrations/payment-providers.spec.ts`, а `madge --circular src` даёт 0 циклов. Это размещение — нормативное для этапов D–F (ARCH, ADR-086); боевые адаптеры этапов D–E (`SmsProXmlGateway` RM-D-002, `OnecExtensionGateway`/`OnecODataGateway` RM-E-001, `OnecQrProvider` RM-F-016) добавляются в те же подкаталоги, пути задач 13 читаются с этой заменой.

### 3.3. `scripts/` (по задачам 13)

| Скрипт | Задача |
|---|---|
| `check_repo_layout.py`, `check_secrets.py` | RM-C-001 (`check_secrets.py` заменяет `gitleaks detect` до RM-C-011) |
| `build_openapi.py`, `check_openapi_dictionaries.py` | RM-B-003 (сборка из `contracts/openapi/parts/`, сверка словарей) |
| `check_api_paths.py`, `check_api_permissions.py` | RM-B-003, RM-B-008 |
| `gen_rbac_seed.py` | RM-B-008 (`0002_rbac_seed.sql` из `permissions.yaml`) |
| `check_ddl_behavior.sql` | RM-B-005 (B-AR-10, поведенческие проверки DDL); с RM-C-006 п. 7 — `pos-api/test/sql/check_ddl_behavior.sql` |
| `check_contrast.py` | RM-B-006 |
| `build_arb.py` | RM-B-007 |
| `check_enum_triangle.py` | RM-B-009 |
| `check_onec_paths.py` | RM-B-004 |
| `check_tables.sql` | RM-B-005 |
| `gen_tokens_dart.py` | RM-B-006 |
| `check_arb_keys.py` | RM-B-007 |
| `gen_enums.py`, `check_enums.py` | RM-B-009 |
| `sync_contracts.py` | RM-C-002 |
| `check_env_example.py` | RM-C-009 |
| `validate_samples.py` | RM-A-005 (пишется в C) |
| `new_feature.sh` | 13 §5.4 п. 2 |
| `check_no_double_money.sh` | 13 §6.1 п. 7 (12 C-08, T-MNY-030); CI — job app-analyze-test, Makefile check-contracts |

---

## 4. Владельцы

Владельцы каталогов — CONTRIBUTING.md §5 (копия 13 §5.2). Кратко по уровню 1:

| Каталог | Владелец |
|---|---|
| `contracts/` | ARCH (координация); файлы — BE, ONEC, DS, DS + FE, SEC, заказчик (13 §5.1) |
| `pos-api/` | BE; `auth`, `registration`, `profile`, `common/rbac`, `common/audit`, `notifications/sms` — SEC; `sync` — ONEC; `test/e2e` — QA |
| `pos-app/` | FE; `lib/design_system`, `lib/l10n`, `assets/rive`, `assets/fonts` — DS; `integration_test` — QA; нативный код — FE + SEC |
| `onec-extension/` | ONEC (код расширения пишет специалист 1С заказчика по `18_ONEC_API_REQUEST.md`) |
| `infra/`, `.github/workflows/`, `.env.example` | OPS |
| `docs/` | ARCH; `docs/reviews/` — QA; `docs/pilot/` — POS |
| `scripts/`, `tools/` | ARCH |
| `resursi/` | заказчик (только чтение) |

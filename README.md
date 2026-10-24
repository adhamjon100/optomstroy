# Оптомстрой POS

POS-система для «Оптомстрой» (Кыргызстан). Состав:

- клиентское приложение на Flutter для Android и Windows (iOS — только архитектурно);
- серверная часть на NestJS и PostgreSQL;
- обмен с 1С через расширение «OptomstroyPOS».

ТЗ утверждено 2026-10-21, идёт этап 2 «Разработка». Текущий этап дорожной карты — **C «Foundation»** (13 §3.3).

Это монорепозиторий (RM-C-001). Целевое дерево и владельцы каталогов описаны в [`docs/repo_layout.md`](docs/repo_layout.md). Правила изменения контрактов — в [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Состав

| Каталог | Что внутри | Владелец | Состояние |
|---|---|---|---|
| [`pos-app/`](pos-app/) | Flutter-приложение: Android, Windows; iOS — архитектурно (ADR-039) | FE | шаблон Flutter перенесён (RM-C-001); каркас — RM-C-002…004 |
| [`pos-api/`](pos-api/) | Backend: NestJS, Node 24, модульный монолит (`api` + `worker`) | BE | есть `migrations/` (этап B); каркас — RM-C-005…008 |
| [`contracts/`](contracts/) | Машинно-проверяемые контракты: OpenAPI, контракт 1С, дизайн-токены, ARB, RBAC, enum-ы | ARCH (координация) | этап B завершён |
| [`infra/`](infra/) | Схема развёртывания и тестовый контур (Docker Compose, Caddy) | OPS | `README.md` (RM-B-011); compose — RM-C-012 |
| [`onec-extension/`](onec-extension/) | Материалы по расширению 1С «OptomstroyPOS». Код пишет специалист 1С заказчика по [`18_ONEC_API_REQUEST.md`](docs/specification/18_ONEC_API_REQUEST.md) | ONEC | версий пока нет (RM-B-014) |
| [`scripts/`](scripts/) | Проверочные и генерирующие скрипты контрактов и CI | ARCH | этап B + RM-C-001 |
| [`tools/`](tools/) | Служебные инструменты. [`tools/pg`](tools/pg/README.md) — одноразовый PostgreSQL 17 без Docker | ARCH | работает |
| [`docs/`](docs/) | ТЗ, исследования, отчёты этапов, ревью, ERD | ARCH | — |
| `resursi/` | Материалы заказчика (макеты, логотип) | заказчик | **только чтение** |

## Требования к окружению разработчика

| Инструмент | Версия | Для чего |
|---|---|---|
| Flutter / Dart | 3.38.x / 3.10.x (stable) | `pos-app` |
| Visual Studio 2022 с workload «Desktop development with C++» | — | сборка Windows |
| Android SDK | лицензии приняты (`flutter doctor --android-licenses`) | сборка Android |
| Node.js / npm | 24 LTS / 11 | `pos-api`, `tools/pg`, `npx @redocly/cli` |
| Python | 3.11+, пакеты `jsonschema`, `pyyaml` | `scripts/` |
| Java | 11+ | `openapi-generator-cli` (генерация клиента `dart-dio`, RM-C-004) |
| Docker | — | тестовый контур `infra/` (RM-C-012). Без Docker для проверки DDL есть `tools/pg` |

Ничего не устанавливается глобально сверх этого списка. Секреты не хранятся в репозитории: в git только файлы `*_FILE` вне репозитория и `.env.example` (RM-C-009).

## Команды запуска

Все команды выполняются из корня репозитория, если не указано другое. Python запускается как `python -I -X utf8`, так же как в логах этапа B.

### pos-app (Flutter)

```sh
cd pos-app
flutter pub get
flutter analyze
flutter test
flutter run -d windows               # отладочный запуск на Windows
flutter build windows --release      # RM-C-013
flutter build apk --debug            # RM-C-013; сначала принять лицензии Android SDK
```

### pos-api (NestJS)

Каркас `pos-api` создаёт задача RM-C-005. После неё здесь появятся `npm ci`, `npm run start:dev`, `npm test` и `npm run migrate`. Сейчас из `pos-api` есть только SQL-миграции. Их можно проверить на временном PostgreSQL 17:

```sh
npm --prefix tools/pg ci
node tools/pg/run-sql.mjs pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_tables.sql
node tools/pg/run-sql.mjs --repeat-strict pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql
node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql pos-api/db/migrations-dev/0001_dev_outbox.sql --check pos-api/test/sql/check_ddl_behavior.sql
```

### Проверки контрактов (`contracts-lint`, CONTRIBUTING.md §6)

```sh
python -I -X utf8 scripts/build_openapi.py --check
npx --yes @redocly/cli@2 lint contracts/openapi/pos-api.v1.yaml
python -I -X utf8 scripts/check_api_paths.py
python -I -X utf8 scripts/check_api_permissions.py --require-operations
python -I -X utf8 scripts/check_openapi_dictionaries.py
npx --yes @redocly/cli@2 lint contracts/onec/onec-http-service.v1.yaml
python -I -X utf8 scripts/check_onec_paths.py
python -I -X utf8 scripts/check_contrast.py
python -I -X utf8 scripts/build_arb.py --check
python -I -X utf8 scripts/check_arb_keys.py
python -I -X utf8 scripts/check_enums.py
python -I -X utf8 scripts/check_enum_triangle.py
python -I -X utf8 scripts/gen_rbac_seed.py --check
```

Генераторы `gen_tokens_dart.py` и `gen_enums.py` проверяются на детерминизм: два прогона во временные каталоги, затем `diff`. Полный перечень шагов с источниками — `CONTRIBUTING.md` §6 и `docs/stages/B_checks.log`.

### Проверки репозитория (RM-C-001)

```sh
python -I -X utf8 scripts/check_repo_layout.py --tree   # замена `tree -L 2`: сверка с docs/repo_layout.md §2
python -I -X utf8 scripts/check_secrets.py              # замена `gitleaks detect` до RM-C-011; ожидается 0 находок
python -I -X utf8 scripts/check_secrets.py --self-test  # положительный контроль шаблонов
```

## Документы

- ТЗ: [`docs/specification/README.md`](docs/specification/README.md) — документы 00…18.
- Дорожная карта: [`13_IMPLEMENTATION_ROADMAP.md`](docs/specification/13_IMPLEMENTATION_ROADMAP.md). Этап C — §3.3.
- Архитектура: [`06_ARCHITECTURE.md`](docs/specification/06_ARCHITECTURE.md).
- Журнал решений (ADR): [`15_DECISION_LOG.md`](docs/specification/15_DECISION_LOG.md).
- Ядро решений: [`docs/research/R0_DECISION_KERNEL.md`](docs/research/R0_DECISION_KERNEL.md) v1.9. Исследования — R1…R8 в той же папке.
- Ворота и отчёты этапов: [`docs/stages/`](docs/stages/). Утверждение — `B_approval.md`, отчёт этапа B — `B_architecture_report.md`.
- Ревью: [`docs/reviews/`](docs/reviews/). Журнал работ — [`docs/PROGRESS_LOG.md`](docs/PROGRESS_LOG.md).

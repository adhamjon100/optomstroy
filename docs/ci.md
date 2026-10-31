# CI и тестовый контур «Оптомстрой POS»

Задачи: **RM-C-011** (CI) и **RM-C-012** (тестовый контур), 13_IMPLEMENTATION_ROADMAP §3.3. Владелец — `OPS` (+ `QA` для RM-C-012).
Версия 1.2 · Дата: 2026-10-21, обновлено 2026-10-28 (сверка с `infra/compose.test.yml` и `infra/docker/api/Dockerfile`, E-KI-13) и 2026-10-29 (правило слоёв DM-01, тесты веб-демо вне CI — §6, ADR-113; журнал — §9). Источники: 13 §3.3, §5.1, §5.3, §6.1; 12 §2.10–§2.11; 16 §4.1–§4.6, §8, §11; `CONTRIBUTING.md` §6; ядро R0 §20.2 п. 1–2.

| Файл | Назначение |
|---|---|
| `.github/workflows/ci.yml` | 12 jobs: 11 из перечня RM-C-011 и `test-contour` (RM-C-012 в CI) |
| `infra/compose.test.yml` | тестовый контур: `caddy, api, worker, migrate, postgres, backup` |
| `infra/caddy/Caddyfile` | pos-proxy (тест: внутренний CA; образец для prod — 16 §4.5) |
| `infra/docker/api/Dockerfile` (+ `Dockerfile.dockerignore`) | образ `optomstroy/api` — один для api, worker и migrate; стадии `release` (по умолчанию, прод — без фикстур) и `test-fixtures` (`release`-рантайм + `/contracts/onec/fixtures` для `ONEC_MODE=fixtures`; её собирает тестовый контур, `build.target`) |
| `infra/docker/backup/Dockerfile`, `backup.sh` | образ `optomstroy/backup`: pg_dump 17 + age + rclone, расписание `BACKUP_SCHEDULE` |
| `infra/docker/postgres/initdb/10-roles.sh` | роли БД `pos_migrate`, `pos_app`, `pos_readonly`, `pos_backup` при первой инициализации |
| `infra/docker/scripts/gen-test-secrets.sh` | одноразовые секреты контура в `infra/secrets/` (вне git) |
| `infra/docker/scripts/check_compose_test.py` | проверка структуры контура (ports, сети, секреты, non-root) |
| `pos-api/test/e2e/smoke.e2e-spec.ts` | smoke-набор: через Caddy или в процессе |
| `Makefile` | цели `test-up`, `test-down`, `test-smoke`, `test-check`, `gen`, `check-contracts` |

---

## 1. Статус: CI ни разу не запускался

> **CI не запускался ни разу.** Хранилища кода и раннеров нет: вопрос **Q-131** (ведущий; дубли Q-192, Q-233) и действие **O-23** не закрыты. Поэтому ни один критерий RM-C-011 (пп. 1–5) и пп. 1–3 RM-C-012 **не выполнены**. Они выполняются только первым прогоном на раннерах. На машине разработки нет Docker, поэтому образы, compose-контур, Caddy, oasdiff, openapi-generator, gitleaks и Trivy локально тоже не запускались.

Что проверено локально (Windows 11, 2026-10-21) и чем:

| Что | Команда / способ | Результат |
|---|---|---|
| YAML всех новых файлов | `python -c "yaml.safe_load(...)"` | разбираются |
| Схема workflow | `npx @action-validator/cli@0.6.0 .github/workflows/ci.yml` (JSON Schema SchemaStore) | код 0; на заведомо неверном файле — код 1 |
| Структура workflow | скрипт: события, 11 обязательных jobs, `needs`, шаги uses/run, все actions закреплены по SHA, выражения `${{ }}`, синтаксис встроенного Python, раннеры | OK: 12 jobs; Linux — 11, Windows — 1 |
| Шаг 16 (версия и CHANGELOG) | встроенный скрипт извлечён из `ci.yml` и запущен на временном git-репозитории, 7 сценариев | ожидаемые коды 0/1 во всех сценариях |
| coverage-gate | встроенный скрипт на реальных lcov (`vitest --coverage`, `flutter test --coverage`) и на синтетике | этап C: pos-api domain 91.9 %, pos-app domain 100 %, остальные группы пусты; синтетика 79 % → код 1 |
| Структура compose | `python infra/docker/scripts/check_compose_test.py infra/compose.test.yml` и на эмуляции `docker compose config --format json` | OK; 3 негативных варианта (ports у api, `internal: false`, пароль значением) → код 1 |
| Секреты контура | `sh infra/docker/scripts/gen-test-secrets.sh <tmp>` дважды | 7 файлов; повтор ничего не меняет; `jwt_public.json` — валидный JSON |
| initdb + migrate + api + worker | имитация контура без Docker: embedded PostgreSQL 17, SQL из `10-roles.sh`, `node dist/migrate.js --seed` под `pos_migrate` (`APP_ENV=staging`) дважды, `dist/main.js` и `dist/worker.js` под `pos_app` | 10/10: 63 таблицы (staging), владелец — `pos_migrate`, `check_tables.sql` OK, `/health/ready` 200 (db ok, worker ok), worker жив |
| smoke, режим «в процессе» | `cd pos-api && npx vitest run --config ./vitest.config.e2e.ts smoke` | 10 passed, 4 skipped (проверки Caddy) |
| smoke, код режима «контур» | тот же набор с `SMOKE_BASE_URL=http://127.0.0.1:3000` против api из имитации (Caddy нет) | 8 общих проверок passed; 4 проверки Caddy ожидаемо failed |
| Стиль smoke | `npx eslint`, `npx prettier --check`, `npx tsc -p tsconfig.json --noEmit` | 0 ошибок |
| `make check-contracts` | рецепт выполнен построчно мини-исполнителем Makefile (GNU make на машине нет) | 30 из 31 команды — код 0; `check_repo_layout.py` — код 1 (CI-KI-02) |
| `backup.sh` | `sh -n`; 20 сценариев разбора cron; `once` без `BACKUP_AGE_RECIPIENT` | синтаксис OK; 20/20; отказ с кодом 1 |
| Набор класса A (backend) | `npx vitest run logging_redaction rbac read-only idempotency app-config app-version security` | 6 файлов, 48 тестов passed |
| Экспорт `/openapi.json` без БД | `node dist/main.js` с недоступной `DATABASE_URL` | OpenAPI 3.0.3, 3 пути; `/health` 200 |
| `npm audit` | `npm audit --omit=dev --audit-level=high` и полный | 0 уязвимостей, код 0 |

## 2. Что нужно от заказчика (до первого прогона)

1. **Ответ на Q-131 / O-23.** Где хранится код и где работает CI. По допущению 14 §2 это GitHub + GitHub Actions. При другом выборе (GitLab CI, self-hosted) jobs переносятся в `infra/ci/` 1:1: команды шагов не зависят от платформы.
2. **Хранилище кода и первый push.** Сейчас в git один коммит `Initial Flutter project upload`. Почти все файлы этапов B–C не закоммичены: по правилам задач коммиты делает заказчик или ARCH.
3. **Раннеры (ядро §20.2 п. 1, обязательны с этапа C).**
   - Linux с Docker Engine и Compose v2. Для GitHub-hosted это `ubuntu-latest`: в нём есть Docker, make, psql 16, Java, Android SDK с принятыми лицензиями. Нужны свободные порты 80/443: их публикует caddy контура. Другие порты задаются `TEST_HTTP_PORT` и `TEST_HTTPS_PORT`, тогда `SMOKE_BASE_URL` должен содержать порт.
   - Windows с Visual Studio 2022 (C++ desktop, ATL). Для GitHub-hosted это `windows-latest`.
   - Если раннеры self-hosted: те же компоненты плюс Flutter 3.38.7, Node 24, Python 3.13, доступ к Docker Hub, ghcr.io, npm, pub.dev и Maven Central (openapi-generator в Docker).
4. **Branch protection для `main`** (RM-C-011 п. 2). Настраивает владелец репозитория: *Settings → Branches → Require status checks*. Обязательные проверки: `contracts-lint`, `api-lint-test`, `api-integration`, `api-e2e`, `test-contour`, `openapi-diff`, `app-analyze-test`, `app-golden`, `build-windows`, `build-android-debug`, `gitleaks`, `security-class-a`, `coverage-gate`. Дополнительно: *Require branches to be up to date*, запрет прямого push и force-push в `main`.
5. **Приёмка RM-C-011 на первом прогоне** (13 §3.3):
   - (1) все jobs зелёные на `main`;
   - (2) PR с красным job не сливается;
   - (3) артефакты прикреплены к run: `pos-app-windows-release`, `pos-app-android-debug`, `api-coverage`, `app-coverage`;
   - (4) в журнале job `test-contour` видны `docker version` и `docker compose -f infra/compose.test.yml up -d` с кодом 0, а в журнале `build-windows` — `flutter build windows --release` с кодом 0;
   - (5) два тестовых PR: в первом падает тест класса A (например, ломается `logging_redaction.spec.ts`), во втором покрытие domain ниже 80 %. Оба PR не должны сливаться.
6. **Минуты CI.** Для приватного репозитория на GitHub-hosted раннерах минуты Windows считаются с коэффициентом. Один полный прогон — около 12 jobs по 10–40 минут. Бюджет — решение заказчика.
7. **Локальная машина разработки.** Лицензии Android SDK **не приняты**. Это действие заказчика: `sdkmanager --licenses` от имени владельца машины. До этого `flutter build apk` локально не выполняется. В CI сборка идёт на раннере, где лицензии принял владелец образа.

## 3. Тестовый контур (RM-C-012)

### 3.1. Запуск с Docker

Запуск из корня репозитория. Нужны Docker Engine, Compose v2, GNU make, openssl, Python 3 и Node 24 (для smoke).

```sh
make test-up      # секреты → docker compose build api backup → run --rm migrate → up -d → ожидание healthy api
make test-check   # config: ports только у caddy; check_tables.sql; повторный migrate (0 изменений); backup once
make test-smoke   # SMOKE_BASE_URL=https://localhost NODE_EXTRA_CA_CERTS=infra/secrets/caddy-root.crt npm run test:e2e -- smoke
make test-down    # down -v --remove-orphans: контейнеры, сети и тома контура удаляются
```

Без make — те же шаги вручную:

```sh
sh infra/docker/scripts/gen-test-secrets.sh infra/secrets
docker compose -f infra/compose.test.yml build api backup
docker run --rm --entrypoint age-keygen optomstroy/backup:test > infra/secrets/backup_age.key
export BACKUP_AGE_RECIPIENT="$(sed -n 's/^# public key: //p' infra/secrets/backup_age.key)"
docker compose -f infra/compose.test.yml run --rm migrate          # RM-C-012 п. 1
docker compose -f infra/compose.test.yml up -d                     # RM-C-012 п. 2
docker compose -f infra/compose.test.yml config                    # RM-C-012 п. 3: ports: только у caddy
docker compose -f infra/compose.test.yml cp caddy:/data/caddy/pki/authorities/local/root.crt infra/secrets/caddy-root.crt
cd pos-api && SMOKE_BASE_URL=https://localhost NODE_EXTRA_CA_CERTS=../infra/secrets/caddy-root.crt npm run test:e2e -- smoke
```

### 3.2. Устройство

| Сервис | Образ | Сети | Порты | Секреты | Особенности |
|---|---|---|---|---|---|
| `caddy` | `caddy:2.11.6-alpine` | edge | **80, 443** — единственные | — | `localhost`, внутренний CA (`tls internal`), JSON-логи в stdout, без авторизации (DEPLOY-049) |
| `api` | `optomstroy/api:test` (стадия `test-fixtures`), `node dist/main.js` | edge, backend | нет (`expose 3000`) | database_url, jwt_private.pem, jwt_public.json, otp_pepper, pin_pepper | `WORKERS_ENABLED=false`; healthcheck `wget /health`; `user 10001`, `read_only`, `cap_drop ALL` |
| `worker` | тот же образ, `node dist/worker.js` | edge, backend | нет | database_url, jwt_public.json, otp_pepper | `WORKERS_ENABLED=true`; `OTP_HMAC_SECRET_FILE=/run/secrets/otp_pepper` — тот же HMAC OTP, что у api: текст задания `sms.send` и возврат квоты номера (16 §4.4, EQ-AUTH-08); ключ подписи JWT и `pin_pepper` worker не получает |
| `migrate` | тот же образ, `node dist/migrate.js --seed` | backend | нет | database_url, db_migrator_password | одноразовый; api и worker ждут `service_completed_successfully`; `pos-api/db/migrations-dev` смонтирован только для чтения и применяется лишь при `APP_ENV=dev` |
| `postgres` | `postgres:17.10` | **только backend** | нет | pg_password (+ два секрета для initdb) | healthcheck `pg_isready -h 127.0.0.1` (TCP: временный сервер initdb не считается готовым) |
| `backup` | `optomstroy/backup:test` | edge, backend | нет | pg_password | `daemon` по `BACKUP_SCHEDULE`; дамп сразу шифруется age, без получателя дамп не создаётся |

Сети: `optomstroy_test_edge`; `optomstroy_test_backend` с `internal: true`. Тома: `pgdata`, `media`, `backups`, `caddy_data`, `caddy_config`.

Роли БД (07 DATA-012; `10-roles.sh`):
- `pos_migrate` — владелец БД и схемы; под ним работает migrate (`DB_MIGRATOR_PASSWORD_FILE`, логика — `pos-api/src/db/migrator-config.ts`);
- `pos_app` — api и worker, пароль из `database_url`;
- `pos_readonly`, `pos_backup` — без пароля.

Конфигурация api и worker — профиль `staging` (12 §2.11 E3): `ONEC_MODE=fixtures`, `SMS_PROVIDER=fake`, `QR_PROVIDER=none`, `OPENAPI_PUBLIC=true`. При `staging` таблицы `dev_outbox` нет, поэтому `FakeSmsGateway` отвечает ошибкой конфигурации `CONFIG_ERROR` (код OTP через SMS в контуре не доставляется; 07 §5.63). `APP_ENV=dev` можно задать переменной окружения. Тогда migrate применит и dev-миграцию `pos-api/db/migrations-dev/` (монтируется в контейнер только для чтения; в образ не входит — AC-DATA-169) и создаст `dev_outbox`, а `make test-check` сверит 64 таблицы вместо 63.

Переменные уровня compose: `API_TAG`, `BACKUP_TAG`, `POSTGRES_USER`, `POSTGRES_DB`, `BACKUP_*`. Только для тестового контура и Caddyfile: `TEST_HTTP_PORT`, `TEST_HTTPS_PORT`, `CADDY_SITE_ADDRESS`, `CADDY_TLS`, `API_UPSTREAM`. Процесс api/worker их не читает, в 16 §4.3 они не входят.

### 3.3. Smoke-набор (`pos-api/test/e2e/smoke.e2e-spec.ts`)

Тесты не меняют бизнес-данные.

Общие проверки:
- `/health` → 200;
- `/health/ready` → 200 (db ok, worker ok);
- `X-Request-Id` (UUID) и заголовки безопасности;
- `/api/v1/openapi.json` → 200;
- неизвестный маршрут → 404 `problem+json` `NOT_FOUND`;
- старая версия клиента → 426 `APP_UPDATE_REQUIRED` и `X-Min-App-Version`;
- `/api/v1/integrations/onec/ping` → 404;
- защищённый маршрут без токена → 401/404 `problem+json`.

Режим «контур» (`SMOKE_BASE_URL`) добавляет проверки Caddy:
- редирект HTTP → HTTPS;
- нет `Server`, есть `X-Frame-Options: DENY`;
- всё вне `/api/*`, `/health*` и `/images/*` → 404;
- `X-Request-Id` клиента заменяется идентификатором proxy.

Режим «в процессе» добавляет проверки на свежей БД:
- мигратор применяет `0001_init.sql` и `0002_rbac_seed.sql`, повторный прогон — 0 изменений;
- роли и права из seed на месте.

## 4. Без Docker (RM-C-012 п. 4; ограничение машины разработки, ядро R0 §0)

1. **e2e и smoke локально.** `cd pos-api && npm run test:e2e` — все e2e на одноразовом PostgreSQL 17 (npm-пакет `embedded-postgres`, Docker не нужен). Smoke в этом режиме сам создаёт БД, прогоняет мигратор и поднимает приложение. Чтобы использовать уже работающий PostgreSQL 17, задайте `E2E_DATABASE_URL=postgres://<суперпользователь>@<хост>:<порт>/postgres`: smoke создаст и удалит отдельную БД `pos_smoke_*`.
2. **DDL и состав таблиц.** `node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_tables.sql` (`tools/pg/README.md`). Все проверки контрактов разом — `make check-contracts` (в Git Bash с make) или те же команды из `Makefile` по одной.
3. **Локальный PostgreSQL 17 вручную** (установщик EDB или пакет ОС), чтобы запустить api и worker как в контуре:
   1. создать БД `optomstroy_test`;
   2. выполнить под суперпользователем SQL из `infra/docker/postgres/initdb/10-roles.sh` (блок между `<<'SQL'` и `SQL`), подставив пароли вместо `:'migpw'` и `:'apppw'` и имя БД вместо `:"dbname"`;
   3. `cd pos-api && npm run build`;
   4. `APP_ENV=staging PUBLIC_BASE_URL=https://localhost DATABASE_URL=postgres://pos_app:<пароль>@127.0.0.1:5432/optomstroy_test DB_MIGRATOR_PASSWORD=<пароль pos_migrate> node dist/migrate.js --seed`;
   5. те же переменные (без `DB_MIGRATOR_PASSWORD`) плюс `MIN_APP_VERSION=android=0.1.0,windows=0.1.0 ONEC_MODE=fixtures SMS_PROVIDER=fake QR_PROVIDER=none OPENAPI_PUBLIC=true`: `node dist/main.js` и в другом окне `WORKERS_ENABLED=true node dist/worker.js`;
   6. `SMOKE_BASE_URL=http://127.0.0.1:3000 npm run test:e2e -- smoke`. 4 проверки Caddy без proxy ожидаемо падают.

   Пароли задаются вне git: переменные текущей сессии или `.env` (игнорируется).

## 5. Отличия контура от прод-спецификации 16 §4.4

| Отличие | Причина |
|---|---|
| `APP_ENV=staging`, `ONEC_MODE=fixtures`, `SMS_PROVIDER=fake`, `QR_PROVIDER=none` | тестовый контур не подключается к рабочей 1С и не шлёт SMS (16 §11, OPS-027) |
| Фикстуры 1С — слой образа стадии `test-fixtures` (`/contracts/onec/fixtures`, владелец root, только чтение), не bind-mount (FQ-INT-08; 16 §4.4 прим. (2); ADR-098) | FakeOnecGateway (RM-C-008) читает `<корень>/contracts/onec/fixtures`; контур не зависит от рабочей копии на хосте Docker; в прод-образ (стадия `release`) фикстуры не входят, prod отказывает в старте при `ONEC_MODE=fixtures` (16 OPS-027) |
| Набор секретов урезан: нет SMSPro, 1С, `healthchecks_url`, `rclone.conf`; worker получает только `database_url`, `jwt_public.json`, `otp_pepper` | в контуре они не используются; указатели `*_FILE` на несмонтированные файлы не передаются (минимум прав) |
| Caddy: `localhost` + внутренний CA, журналы в stdout, нет `depends_on`/healthcheck | тест без домена и ACME; на сервере — `CADDY_SITE_ADDRESS=api-test.<домен>`, `CADDY_TLS=<e-mail>` (Q-032) |
| Нет `deploy.resources.limits`, `shared_buffers=256MB` | раннер CI; лимиты — при развёртывании RM-I-002 |
| backup не выгружает дампы (`BACKUP_REMOTE=""`), тестовая пара age лежит в `infra/secrets/` | на сервере приватный ключ age не хранится (OPS-004) |
| **`GRANT CREATE ON DATABASE … TO pos_app`** (CI-KI-03) | pg-boss при старте выполняет `CREATE SCHEMA IF NOT EXISTS pgboss` под `pos_app`. PostgreSQL проверяет право CREATE на базу раньше, чем существование схемы. Без гранта воспроизведено: worker — «permission denied for database», `/health/ready` → 503 |
| Секреты в `infra/secrets/` с правами 644 | Compose без Swarm монтирует файлы секретов с правами хоста, а контейнеры работают под uid 10001/10002/999. Допустимо только для одноразовых тестовых секретов |

## 6. Соглашения CI

- **Класс A** (`security-class-a`, 11 SEC-126) — блокирует слияние. В набор входят:
  - backend unit — файлы `logging_redaction`, `rbac`, `read-only`, `idempotency`, `app-config`, `app-version` и любой файл с `security` в имени (`*.security.spec.ts`);
  - backend e2e — `test/e2e/**/*.security.e2e-spec.ts`;
  - Flutter — тесты с тегом `security-a`;
  - `npm audit --omit=dev --audit-level=high`;
  - Trivy образа `optomstroy/api` (HIGH/CRITICAL с исправлением);
  - Caddyfile без директив аутентификации;
  - `check_compose_test.py`.

  Новые тесты T-SEC этапов D–G включаются в набор именем файла или тегом, правка workflow не нужна.
- **Golden** — тег `golden` (`@Tags(['golden'])`). Если golden-тестов нет, `app-golden` красный: пустой набор не засчитывается (CI-KI-04).
- **coverage-gate** — 80 % строк unit-тестами в каждой группе:
  - pos-app domain — `lib/features/*/domain/**`, `lib/core/utils/{money,qty}.dart`;
  - pos-app data — `lib/features/*/data/**`, `lib/core/{database,storage,sync}/**`;
  - pos-api domain — `**/domain/**`, `*-state-machine.ts`, `src/common/money/**`;
  - pos-api application — `*.service.ts` модулей D-06.

  Это группы 12 C-04 и C-10. Сгенерированные файлы исключаются. Пустая группа не блокирует и выводится notice. Порог — `COVERAGE_MIN`. 100 % ветвей для перечня `coverage_critical.txt` (T-NFR-004) — после появления перечня.
- **openapi-diff**:
  - блокирует — `oasdiff breaking` (base → PR) с `--fail-on ERR`. Если в базе контракта нет, шаг пропускается с notice;
  - отчёт — сверка экспорта Nest `/openapi.json` (собирается без БД) с контрактом. На этапе C экспорт содержит 3 пути, поэтому шаг не блокирует (`continue-on-error`). Сделать его блокирующим решает BE после этапа D.
- **Шаг 16 `contracts-lint`** (имя в CONTRIBUTING §6 — `[НОВОЕ ИМЯ]`) — встроенный скрипт в `ci.yml`. Для изменённого контракта версия должна вырасти, а в CHANGELOG.md каталога должна быть запись с новой версией (для `enums.json` — `contracts/CHANGELOG.md`). ARB версии не имеют и не проверяются. Отдельный файл в `scripts/` не создавался: каталог вне путей задачи.
- **Правило слоёв DM-01 и веб-демо** (15 ADR-113, 06 §6.10). Шаг «Правила слоёв (`scripts/check_layers.py`)» job `app-analyze-test` проверяет и DM-01 `demo_isolated`: файлы `pos-app/lib/app/demo/**` импортируются (а также экспортируются и включаются директивой `part`) только из `lib/app/demo/**` — `lib/main.dart` демо-код не достаёт, в сборки Windows и Android он не попадает; сам демо-код опирается только на `app/demo/**`, `app/bootstrap.dart`, `core/**` и пакеты (без `features/**`, `design_system/**` и прочего `app/**` — например, `app/di/overrides.dart` и `app/router/**` тоже запрещены; 06 §6.10). Кейсы DM-01, в том числе `part`, входят в `--self-test`. Правка workflow не нужна.
  - В CI из тестов веб-демо (12 §3.22) попадают только DM-01 (T-DEMO-001) и VM-тесты Dart `pos-app/test/app/demo/**` (T-DEMO-001, T-DEMO-012) — они входят в общий `flutter test` блокирующего job `app-analyze-test`, поэтому их провал блокирует PR; в релизные ворота и подсчёт 12 §5.3 они не входят.
  - **Не в CI:** веб-сборка (`flutter build web`, AC-ADR-039 не меняется), тесты бэкенда демо (`node --test` в `demo/web/backend/test/`), headless-проверка сайта (`demo/web/tools/smoke.mjs`, создаёт пакет WP-T2), `check-site` (`demo/web/tools/check-site.mjs`, создаёт WP-N1) и сверка с local-stack на настоящем PostgreSQL. Их запускают вручную перед выкладкой демо (`demo/web/README.md` — создаёт WP-N1; до него — `demo/web/backend/README.md`); они вне релизных ворот.
  - Новый код демо проходит те же гейты, что и остальной: `flutter analyze`, `check_no_double_money.sh` (не денежные `double`/`num` моста — с пометкой `// money-double: allow — <причина>`), `check_secrets.py` и gitleaks (тестовые векторы — с `check-secrets: allow — <причина>` и `gitleaks:allow`), цепочка ARB (новых строк UI нет: демо-панель — HTML вне Flutter).
- **Генераторы.** `make gen` перегенерирует OpenAPI, ARB, seed RBAC, токены Dart, копии ARB, `enums.ts` и `permissions.generated.ts`. `contracts-lint` требует, чтобы результат совпадал с закоммиченным. Dart-enum-ы pos-app (`lib/core/enums.dart`, RM-C-004) нужно добавить в цель `gen`, когда файл появится.
- **Версии инструментов закреплены.** Actions — по SHA коммита тега. Образы — тегом точной версии: `postgres:17.10`, `caddy:2.11.6-alpine`, `node:24.18.1-alpine3.23`, `alpine:3.23`, `openapitools/openapi-generator-cli:v7.26.0`, `tufin/oasdiff:v1.33.0`, `zricethezav/gitleaks:v8.30.1`, `aquasec/trivy:0.75.0`. Также redocly 2.59.0 и Flutter 3.38.7. Обновление — PR с прогоном CI; рекомендуется Dependabot для `github-actions`.

## 7. Платформенные замечания

- **ATL для Windows-сборки** (`flutter_secure_storage`): в `windows-latest` компонент VS 2022 «C++ ATL» установлен. На self-hosted Windows его нужно поставить: Visual Studio Installer → «Разработка классических приложений на C++» → «C++ ATL для последних средств сборки v143».
- **Java для openapi-generator.** В CI генератор запускается в Docker (`openapitools/openapi-generator-cli:v7.26.0`, внутри Java 17). На машине разработки по умолчанию в PATH стоит Java 8, но найден установленный **JDK 17**: `C:\Program Files\Java\jdk-17\bin\java.exe`, версия 17.0.12. С ним генерация `dart-dio` возможна и локально. Это касается B-KI-01 и RM-C-004 (FE).
- **Android:** `build-android-debug` использует Java 17 (temurin) и SDK раннера.

## 8. Известные проблемы

| ID | Описание | Серьёзность | Что сделать / кто |
|---|---|---|---|
| CI-KI-01 | CI не запускался: нет хранилища и раннеров (Q-131, O-23). Образы, compose-контур, Caddyfile (`caddy validate`), oasdiff, openapi-generator, gitleaks и Trivy не исполнялись ни разу. Первый прогон почти наверняка потребует правок | существенно | заказчик — §2; OPS — разбор первого прогона |
| CI-KI-02 | `scripts/check_repo_layout.py` → код 1: в `docs/repo_layout.md` §2 нет `Makefile` (уровень 1) и `infra/docker/` (уровень 2). Оба пути введены этой задачей по её постановке. Пока §2 не дополнен, шаг `contracts-lint` «RM-C-001: структура» красный | незначительно | ARCH (владелец repo_layout): добавить `Makefile` и `infra/docker/` |
| CI-KI-03 | pg-boss требует право CREATE на базу для `pos_app`. В контуре временно выдан `GRANT CREATE ON DATABASE` (§5). В prod-модели DATA-012 у `pos_app` нет DDL | существенно | BE (RM-C-006/RM-C-007): ставить схему pg-boss мигратором под `pos_migrate`, api/worker запускать с `migrate: false`, затем убрать грант из `10-roles.sh` |
| CI-KI-04 | Golden-тестов в `pos-app/test` пока нет, поэтому `app-golden` красный | существенно (G-C) | FE/DS — RM-C-003 |
| CI-KI-05 | `scripts/check_secrets.py` (job `gitleaks`) → код 1: 4 находки generic-secret-assignment в чужих файлах — `pos-api/src/db/migrator.spec.ts:49`, `pos-app/lib/core/network/api_headers.dart:17, :66`, `pos-app/test/core/utils/small_utils_test.dart:84`. Две ложные находки в файлах этой задачи устранены (переименование, пометка `check-secrets: allow`) | незначительно | владельцы файлов: проверить и пометить `check-secrets: allow` или переименовать |
| CI-KI-06 | Два Dockerfile для одного образа. `pos-api/Dockerfile` (RM-C-005, указан в `docs/repo_layout.md`) отличается от `infra/docker/api/Dockerfile`: uid 1000 вместо 10001 из 16 §4.4; нет `seeds/`, поэтому `migrate --seed` в нём упадёт; HEALTHCHECK `/health` в образе помечает worker и migrate unhealthy; install-скрипты зависимостей не отключены. Compose и CI используют `infra/docker/api/Dockerfile` | незначительно | ARCH/BE: оставить один файл (рекомендация — `infra/docker/api/Dockerfile`), второй удалить или выровнять |
| CI-KI-07 | Слой данных pos-api (`src/db/migrator.ts`, `idempotency.repository.ts`) покрыт unit-тестами на 37 % (47/126 строк), остальное покрывают e2e. В гейт не входит: по 12 C-10 для backend считаются domain и application | для сведения | BE — при желании добавить unit-тесты |
| CI-KI-08 | `CONTRIBUTING.md` §6 не перечисляет 6 проверок после ревью (B-KI-05) и шаг «генераторы — пустой diff». В `ci.yml` они есть | незначительно | ARCH: дополнить §6 по `ci.yml` |
| CI-KI-09 | `--strict-coverage` ARB не включён: есть открытое замечание B-KI-06 | незначительно | после текстов владельца 03 добавить флаг в шаг 13 |
| CI-KI-10 | Сверка экспорта `/openapi.json` с контрактом не блокирует (этап C) | для сведения | BE — сделать блокирующей после этапа D |

## 9. Журнал

| Версия | Дата | Что изменено |
|---|---|---|
| 1.0 | 2026-10-21 | Создан задачами RM-C-011, RM-C-012 |
| 1.1 | 2026-10-28 | Сверка с кодом (E-KI-13, `docs/known_issues.md` v1.1): §3.2 — секреты worker (`otp_pepper`, `OTP_HMAC_SECRET_FILE`) и api, `WORKERS_ENABLED`, dev-миграции у migrate; таблица файлов — стадии `release`/`test-fixtures` Dockerfile; §5 — фикстуры 1С в слое образа `test-fixtures` вместо bind-mount, урезанный набор секретов worker; §3.2 — `FakeSmsGateway` при `staging` без `dev_outbox`. Результаты локальных проверок §1 — исторические (2026-10-21), не перезапускались |
| 1.2 | 2026-10-29 | Веб-демо на Netlify (15 ADR-113): §6 — правило слоёв DM-01 в шаге `check_layers.py`; из тестов веб-демо в CI только DM-01 и VM-тесты `pos-app/test/app/demo/**`, остальные (сборка web, `node --test` бэкенда демо, headless-проверка, `check-site`, сверка с local-stack) — вручную перед выкладкой, вне релизных ворот; гейты для нового кода демо. `ci.yml` не менялся Уточнено по ревью веб-демо: DM-01 — белый список для `app/demo/**` (`app/demo/**`, `app/bootstrap.dart`, `core/**`, пакеты), директивы `part` проверяются; T-DEMO-001 и T-DEMO-012 блокируют PR в job `app-analyze-test`; файлы `demo/web/tools/*` и `demo/web/README.md` создают WP-N1 и WP-T2 |

# Независимая проверка каркаса — этап C «Foundation» (QA, чек-лист 13 §6.1)

Дата: 2026-10-22. Проверяющий: QA-агент (независимая проверка, 13 §6.1 п. 11). Машина: Windows 11 Pro 10.0.26200,
Flutter 3.38.7 / Dart 3.10.7, Node 24.11, Python 3.13. Docker нет, CI не подключён.
Файлы репозитория при проверке не изменялись. Единственный записанный файл — этот отчёт. Для проб использовались
одноразовые скрипты во временном каталоге сессии.

**Вердикт: ворота G-C — КРАСНЫЕ.** Три блокера ворот зависят от окружения и заказчика: CI, Docker, лицензии Android SDK.
В коде найдены два критичных дефекта: распределение скидки на backend и освобождение ключа идемпотентности после
COMMIT. Найдены также 11 существенных и 9 незначительных замечаний. Этапу D-backend можно начинать работу только
после исправления C-CR-01 и C-CR-02 (13 §6.2: «жёлтый» требует закрытых критичных).

## 1. Повторный запуск ключевых команд и сверка с `docs/stages/C_checks.log`

| Команда | Мой результат | C_checks.log (финальный прогон) | Совпадает |
|---|---|---|---|
| `cd pos-app && flutter analyze` | No issues found, exit 0 | 0 issues | да |
| `cd pos-app && flutter test` | +288 All tests passed, exit 0 | 288 passed | да |
| `cd pos-app && flutter test --tags golden` | +58 All tests passed, exit 0 | 58 passed | да |
| `cd pos-api && npm run lint` | exit 0 | exit 0 | да |
| `cd pos-api && npm test` | 11 файлов, 82 passed | unit 82 | да |
| `npm run test:integrations` | 5 файлов, 38 passed | 38 | да |
| `npm run test:worker` | 3 файла, 19 passed | 19 | да |
| `npm run test:db` | 2 файла, 12 passed | 12 | да |
| `npm run test:e2e` | 15 passed, 4 skipped (блок Caddy `runIf(VIA_PROXY)`) | 15 + 4 skipped | да |
| `npx madge --circular src` | No circular dependency found | 0 циклов | да |
| `scripts/check_layers.py` / `--self-test` | 108 файлов, 435 импортов, 0 нарушений / 35/35 | то же | да |
| `sync_contracts.py --check`, `check_env_example.py` (97/97), `gen_tokens_dart.py --check` (0 differ), `check_contrast.py` (0 нарушений), `build_arb.py --check`, `check_arb_keys.py`, `check_enums.py` (248), `gen_rbac_seed.py --check`, `check_enum_triangle.py`, `check_openapi_dictionaries.py`, `check_api_permissions.py --require-operations`, `check_api_paths.py`, `build_openapi.py --check`, `check_secrets.py` (823 файла, 0 находок), `check_compose_test.py` (порты только у caddy 80/443) | все exit 0 | exit 0 | да |
| `scripts/check_repo_layout.py` | **exit 1**: 3 ошибки (`Makefile`, `infra/docker/`, `pos-app/env/` нет в `docs/repo_layout.md` §2) | exit 1, то же | да (красный) |

Расхождений между журналом разработчиков и моими запусками нет. Не перепроверял: `dart run build_runner build`
(команда пишет файлы), Windows-сборку, `boot_test` и `local-stack smoke`. Для них остаются в силе записи журнала.

## 2. Проверка соответствия ТЗ и ядру

| Пункт | Результат |
|---|---|
| Слои Clean Architecture (domain без flutter/dio/drift/riverpod; фичи не импортируют друг друга) | OK. Каталоги `features/*/domain` пока пустые (`.gitkeep`), межфичевых импортов нет. В `core/utils` и `core/error` нет пакетных импортов. Правила FL-01…FL-11 проверяет `check_layers.py`, `custom_lint` заменён им (см. C-MJ-10) |
| Deny-by-default RBAC | OK. Глобальный `RbacGuard`: маршрут без политики → 403, без субъекта → 401, зарезервированные коды не выдаются. Каталог прав генерируется из `permissions.yaml` и сверяется (`check:permissions`). Замечание C-MN-02 |
| problem+json, коды 08 §2.4 | В целом OK: `ProblemCode` типизирован из `enums.json`, `type/title/instance/code/requestId` присутствуют. Замечания C-MN-01 и C-MJ-08 (`storeUrl`) |
| Отсутствие секретов | OK. `check_secrets.py` дал 0 находок, `.gitignore` закрывает `.env*`, `secrets/`, ключи. Флаг: `gitleaks` не запускался |
| Логи без ПДн/OTP/токенов | OK. pino `formatters.log` + `hooks.logMethod`: маска телефона, денай-лист ключей, коды в тексте, CR/LF. `FakeSmsGateway` пишет в лог только маску и transactionId. Flutter `LoggingInterceptor` не пишет тела, заголовки и значения query |
| Деньги без double | Flutter: `Money` хранит int тыйыны, `Qty` хранит milli, drift без `RealColumn`; grep `double` по `lib` ничего не нашёл. Backend: decimal.js, строки. **Но** распределение скидки на backend не соответствует ТЗ — C-CR-01. Скрипта `check_no_double_money.sh` нет — C-MN-05 |
| drift-таблицы = 07 §11.2, без ПДн в черновиках | OK. Набор и столбцы совпадают с 07 §11.2, тест сверки зелёный. В `registration_draft` только `key/value_json`, в `checkout_draft` нет сумм, QR и получателя. Замечание C-MN-07 |
| Токены — вариант B, контраст | OK. `meta.palette=B`, `primary #FF8700`, `onPrimary #1B1F2A` (тёмный текст CTA), ColorScheme `onPrimary←onPrimary`, `check_contrast.py` дал 0 нарушений, тема только light |
| app-version 426 | OK по механизму (middleware до guard'ов, исключения `/health*` и `/openapi.json`, заголовки в каждом ответе, `app_settings` приоритетнее env без перезапуска). Замечание C-MJ-08 |
| Read-only guard | Механизм OK. Перечень по умолчанию нарушает RM-C-005 — C-MJ-03 |
| Конвенция `*_FILE` | Загрузчик OK (`X_FILE` приоритетнее `X`). Нет запрета прямых секретов вне dev — C-MJ-01 |
| Тестовые режимы запрещены в prod | `ONEC_MODE=fixtures`, `SMS_PROVIDER=fake`, `AUTH_OTP_TEST_*`, `SMSPRO_TEST_FLAG`, debug-логи — отказ в старте, проверено тестами и моим запуском. Пробел по `ONEC_ODATA_WRITE_ENABLED` — C-MJ-02 |
| Idempotency без автоповтора денежных операций | Клиент OK: `RetryInterceptor` не повторяет `POST /orders/{id}/payments`, `/payments`, `confirm-manual`, `void`. Сервер: C-CR-02 |

## 3. Замечания

### Блокеры ворот G-C (внешние зависимости, не дефекты кода)

- **C-BL-01 (RM-C-011).** CI ни разу не запускался: нет хранилища и раннеров (Q-131). Ворота требуют зелёный CI на Linux с
  Docker и на Windows. Существует только `ci.yml`, его YAML валиден. Что сделать: ответ заказчика по Q-131, затем
  первый зелёный run с обоими раннерами и проверка branch protection.
- **C-BL-02 (RM-C-012).** `docker compose -f infra/compose.test.yml` не выполнялся: Docker отсутствует. `migrate` в
  контейнере, `api-e2e` через Caddy и `boot_test` против контура не проверены. Что сделать: прогнать в CI
  (C-BL-01) или на машине с Docker.
- **C-BL-03 (RM-C-013).** `flutter build apk --debug` не выполнялся: лицензии SDK не приняты, это действие заказчика.
  Протокол чек-листа (а)–(г) для биометрии не получен. `biometric_storage` не разрешается рядом с
  `flutter_secure_storage 11` на Flutter 3.38.7. ADR с выбранным путём криптопривязки отсутствует, а без него
  RM-D-008 стартовать не может. Что сделать: заказчик принимает лицензии, затем apk, протокол на устройстве и ADR
  (вероятно, собственный platform channel).

### Критичные

- **C-CR-01 (деньги).** `pos-api/src/common/money/money.ts` `Money.allocate()` распределяет остаток методом наибольшего
  остатка. ТЗ требует коррекцию в последней строке: 07 §1 п. 4, DATA-137, DATA-213, 10 MV-11. Проверено запуском:
  `Money.of('10.00').allocate([33.33×3])` возвращает `['3.34','3.33','3.33']`, эталон MV-11 — `[3,33; 3,33; 3,34]`.
  Flutter (`core/utils/money.dart allocateDiscount`) следует ТЗ, поэтому клиент и сервер разойдутся построчно.
  Последствия: ложные `PRICE_CHANGED` и несовпадение строк `order_items` с превью. Что сделать: реализовать
  алгоритм 10 §7.3 (`allocateDiscount`/`twoStageDiscount`) один в один с Dart. Добавить общий тест-вектор MV-11 и
  MV-30 для обоих языков.
- **C-CR-02 (идемпотентность).** `IdempotencyInterceptor` (`common/idempotency/idempotency.interceptor.ts`) на любой 5xx
  вызывает `release()`, то есть удаляет ключ. Это происходит и тогда, когда обработчик уже выполнил COMMIT, а упал
  `service.complete()` (сбой БД или пула): ошибка уходит в `catchError` → INTERNAL 500 → ключ удалён → повтор с тем же
  ключом выполняет операцию второй раз. Так получается второй заказ или платёж, что противоречит 08 §2.7 («никаких
  побочных эффектов»). Каркас подключён глобально ко всем мутациям, поэтому дефект унаследуют модули этапа F.
  Что сделать: при ошибке после успешного обработчика не делать `release`, оставлять запись `in_progress`
  (fail-safe) или повторять `complete`. Освобождать ключ только если обработчик бросил ошибку до фиксации. Запись
  итога для денежных маршрутов делать в транзакции бизнес-операции (B-AR-04). Нужен unit-тест «`complete` падает →
  ключ не освобождён».

### Существенные

- **C-MJ-01 (`*_FILE`).** `env-file.loader.ts`/`env.schema.ts` принимают секреты прямым значением (`DATABASE_URL`,
  `JWT_PRIVATE_KEY` …) при `APP_ENV=prod`. Проверено: `loadAppConfig` в prod с прямым `DATABASE_URL` → ACCEPTED.
  16 §4.3 п. (3): не-`_FILE` варианты допустимы только как fallback при `APP_ENV=dev`. Список `SECRET_ENV_KEYS`
  объявлен, но используется только в тесте. Что сделать: при `APP_ENV≠dev` для ключей `SECRET_ENV_KEYS` прямое
  значение → отказ в старте. Добавить тест.
- **C-MJ-02 (тестовые/временные режимы).** `ONEC_ODATA_WRITE_ENABLED=true` при `ONEC_MODE=extension` и без
  `ONEC_ODATA_WRITE_USER_FILE`/`_PASSWORD_FILE` проходит валидацию старта (проверено: ACCEPTED). 16 §4.3 требует
  отказ в старте (ONEC-028). Второй рубеж в `createOnecGateway` не срабатывает: `OnecGatewayModule` не подключён к
  `AppModule` и worker. Что сделать: добавить правила в `superRefine` в `env.schema.ts`.
- **C-MJ-03 (read-only).** `GLOBAL_PROVIDERS` связывает `READ_ONLY_ALLOWLIST` с непустым `ADR_083_ALLOWED_MUTATIONS`,
  хотя у ADR-083 статус «Предложено» (15, B-KI-09). RM-C-005: «до принятия ADR он пуст и действует 11 SEC-119 „все
  мутации → 503“». Что сделать: по умолчанию передавать пустой перечень и включать перечень ADR-083 только после
  принятия ADR (или флагом конфигурации из 16 §4.3 по процедуре §5.3). Тест п. 4 оставить с явной подстановкой.
- **C-MJ-04 (requestId).** `infra/caddy/Caddyfile`: `header_up X-Request-Id {http.request.uuid}` перезаписывает
  `X-Request-Id`, который присылает клиент (Flutter `RequestIdInterceptor`). 08 §2.3 требует эхо значения клиента,
  RM-C-010 — сквозной requestId «клиент → Caddy → API → worker». Что сделать: подставлять UUID только при
  отсутствии заголовка (например, `@noRid not header X-Request-Id`). Добавить e2e через контур.
- **C-MJ-05 (RM-C-006 п. 6, 7).** DDL `dev_outbox` остаётся в `pos-api/migrations/0001_init.sql` под условием
  `app.env`. Dockerfile копирует `migrations/` в prod-образ, AC-DATA-169 не выполнен. `check_ddl_behavior.sql` не
  перенесён в `pos-api/test/sql/`. Что сделать: перенести DDL в `db/migrations-dev/`, а проверки — в
  `pos-api/test/sql/`.
- **C-MJ-06 (RM-C-004 п. 4, RM-C-005 п. 5).** `openapi-diff` не выполнен. `make gen-client` не выполнен со ссылкой на
  ADR-085 («до Java 11+»), хотя на машине есть `C:\Program Files\Java\jdk-17` (проверено, и это признаёт
  C_checks.log). Посылка ADR-085 неверна, B-KI-01 не закрыт. Что сделать: запустить openapi-generator 7 на JDK 17
  локально, решить судьбу ADR-085 и выполнить `oasdiff` или `openapi-diff` без циклического `$ref`.
- **C-MJ-07 (RM-C-008).** В UI нет баннера `EnvBanner`, который маркирует тестовые данные вне prod: в `pos-app/lib`
  0 совпадений. e2e «каталог из фикстур через API» тоже не выполнен. Что сделать: добавить компонент в
  `design_system` и показывать его при `ENV≠prod`, плюс widget-тест.
- **C-MJ-08 (RM-C-015).** Нет экрана SCR-90 и widget-теста п. 3 («426 → блокирующий экран, рекомендованная версия →
  баннер»). В теле 426 нет `storeUrl`, хотя 08 §2.4 его требует: поле объявлено в `problem.exception.ts`, но не
  заполняется. Нет e2e п. 5 (N/N−1/N−2). Что сделать: реализовать SCR-90 (состояние) и тесты, `storeUrl` брать
  из настройки.
- **C-MJ-09 (RM-C-014).** `docs/stages/C_foundation_report.md` отсутствует. `boot_test` запускался против local-stack,
  а не против тестового контура. Что сделать: сдать отчёт с логами критериев RM-C-002…013, 015.
- **C-MJ-10 (RM-C-002 п. 3; R3 §15).** `custom_lint` заменён на `scripts/check_layers.py`, версии пакетов понижены
  относительно R3 §15 (riverpod 3.1, drift 2.30, freezed 3.2, go_router 17 и др.). Обоснование есть только в
  `pos-app/NOTES.md`, ADR нет. Это изменение контракта по 13 §5.3. Что сделать: оформить ADR (замена инструмента
  гейта слоёв и закрепление версий под analyzer 8) или обновить Flutter.
- **C-MJ-11 (RM-C-001).** `check_repo_layout.py` даёт exit 1: 3 ошибки. Фактические пути также расходятся с
  13/`repo_layout.md`: `src/integrations/sms` и `src/integrations/onec` против `src/notifications/sms/fake/**` и
  `src/sync/adapters/fake/**`. `gitleaks` не запускался. Что сделать: ARCH обновляет `docs/repo_layout.md` или
  код переносится, затем повторить проверку и gitleaks.

### Незначительные

- **C-MN-01.** `problem-details.ts codeForHttpStatus`: Nest-исключения 409, 423, 503 и другие неперечисленные статусы
  превращаются в `500 INTERNAL`. Что сделать: сопоставлять их по классу (4xx → ближайший код, 503 → не INTERNAL) и
  добавить тест.
- **C-MN-02.** Если у маршрута нет политики, `RbacGuard` отвечает 403 до проверки субъекта, поэтому анонимный запрос
  получает 403 вместо 401 (ARCH-006, приоритет 08 §2.4). Ответ безопасен, но не по контракту.
- **C-MN-03.** `OPENAPI_PUBLIC=true` допускается при `APP_ENV=prod` (проверено: ACCEPTED). `handle /health*` в Caddy
  публикует наружу и `/health/ready`, хотя ARCH-006 разрешает readiness только из внутренней сети или с basic-auth
  либо allow-list.
- **C-MN-04.** Flutter `AppConfig`: `ENV` = `dev|test|prod`, а RM-C-009 требует профили, равные `APP_ENV`
  (`dev|staging|prod`). При `ENV=prod` не отвергаются `LOG_LEVEL=debug` и `FEATURE_FACE_SCAN=true` (R2).
- **C-MN-05.** Скрипта `scripts/check_no_double_money.sh` (13 §6.1 п. 7) нет, в `ci.yml` такой проверки нет. Мой
  ручной grep `double` по `pos-app/lib` ничего не нашёл.
- **C-MN-06.** `pos-api/scripts/issue_test_jwt.ts` не входит в `tsconfig.json` `include`, поэтому `npm run lint` его не
  проверяет типами.
- **C-MN-07.** `registration_draft.value_json` — произвольный JSON. Отсутствие ПДн обеспечено только соглашением.
  Что сделать: добавить белый список ключей в DAO и тест.
- **C-MN-08.** `PgIdempotencyStore.acquire` рекурсивно вызывает себя без ограничения глубины, когда строка исчезает
  между INSERT и SELECT. Нужен счётчик попыток.
- **C-MN-09.** Отсутствие `X-App-Version`/`X-Platform` пропускается с предупреждением (мягкий режим Q-153). Решение
  нужно зафиксировать до G-H.

## 4. Что не проверено

Не проверены: Windows-сборка и запуск exe (принято по журналу и снимку), `build_runner` воспроизводимость, Dockerfile
(нет Docker), покрытие ≥ 80 % (`coverage-gate` не запускался), gitleaks.

Подпись: QA-агент, независимая проверка этапа C, 2026-10-22.

## 5. Статус замечаний после исправлений (2026-10-22, исполнитель исправлений каркаса)

Исправления выполнены после проверки; повторный прогон проверок — `docs/stages/C_checks.log`, ЧАСТЬ 2 (полный вывод
каждой команды), сводка — `docs/stages/C_foundation_report.md`. Обозначения статуса: **ИСПРАВЛЕНО** — дефект устранён
и подтверждён запуском; **ЧАСТИЧНО** — устранено то, что выполнимо без внешней зависимости, остаток указан;
**НЕ ИСПРАВЛЕНО** — требует действия вне репозитория (заказчик, окружение).

| ID | Статус | Что сделано (подтверждение запуском) | Что осталось |
|---|---|---|---|
| C-BL-01 | НЕ ИСПРАВЛЕНО | `ci.yml` дополнен шагами, которых требуют исправления: dev-миграция и `pos-api/test/sql/check_ddl_behavior.sql` в contracts-lint, проверка AC-DATA-169 (grep), `check_no_double_money.sh` в app-analyze-test; YAML валиден (ЧАСТЬ 2) | Q-131 (хранилище, раннеры Linux+Docker и Windows), первый зелёный run, branch protection — действие заказчика |
| C-BL-02 | НЕ ИСПРАВЛЕНО | Подготовлено к прогону: Caddyfile (requestId, readiness), `compose.test.yml` (монтирование dev-миграций для APP_ENV=dev), e2e через контур (эхо X-Request-Id, readiness с хоста); `check_compose_test.py` — OK | `docker compose -f infra/compose.test.yml`, migrate в контейнере, api-e2e через Caddy, boot_test против контура — нужен Docker (CI по Q-131 или машина с Docker) |
| C-BL-03 | НЕ ИСПРАВЛЕНО | — | Заказчик принимает лицензии Android SDK (и исправляет `ANDROID_HOME`), затем apk, протокол (а)–(г) на устройстве, ADR по D-13 (RM-D-008 до него не стартует) |
| C-CR-01 | ИСПРАВЛЕНО | `pos-api/src/common/money/money-math.ts` — `MoneyMath.allocateDiscount`/`twoStageDiscount` (+ `lineTotal`, `documentDiscount`, `cashRounding`, `change`, `returnLineAmount`, `creditRemaining`) один в один с Dart: целые тыйыны, HALF_UP, коррекция в последней ненулевой строке; метод наибольшего остатка (`Money.allocate`) удалён. Общие векторы `contracts/test-vectors/money.v1.json` (MV-01…MV-04, MV-08, MV-10…MV-22, MV-27, MV-29, MV-30 и граничные) исполняют оба теста: `money-vectors.spec.ts` и `money_vectors_test.dart`; MV-11 → `[3.33, 3.33, 3.34]` на обеих сторонах | — |
| C-CR-02 | ИСПРАВЛЕНО | `IdempotencyInterceptor`: ошибки обработчика и сбой записи итога разведены; после успешного обработчика итог пишется до 3 раз, при неудаче ключ **не освобождается** (остаётся `in_progress`, повтор → 409), клиент получает ответ обработчика; `markIdempotencyCommitted(req)` — после COMMIT 5xx ключ не освобождает; `IdempotencyService.recordInTransaction(tx, req, …)` — запись итога в транзакции бизнес-операции (B-AR-04). Unit-тесты: «complete падает → ключ не освобождён, повтор 409, операция 1 раз», «5xx после COMMIT → 409», «итог в транзакции не перезаписывается и повторяется» | Денежные маршруты этапа F обязаны вызывать `recordInTransaction` (описано в `idempotency.context.ts`) |
| C-MJ-01 | ИСПРАВЛЕНО | `directSecretProblems()` (`env-file.loader.ts`): при `APP_ENV≠dev` ключи `SECRET_ENV_KEYS` прямым значением → отказ в старте с именем `<X>_FILE` (без значения); то же в миграторе (`DATABASE_URL`, `DB_MIGRATOR_PASSWORD`). Тесты staging/prod/dev в `app-config.spec.ts`, `migrator.spec.ts`; prod-guard и db-тесты переведены на `*_FILE` | — |
| C-MJ-02 | ИСПРАВЛЕНО | `superRefine`: `ONEC_ODATA_WRITE_ENABLED=true` только при `ONEC_MODE=odata_only` и только с `ONEC_ODATA_WRITE_USER(_FILE)` и `_PASSWORD(_FILE)` (05 ONEC-028, 16 §4.3); тест C-MJ-02 | `OnecGatewayModule` подключают владельцы `sync`/`payments` на этапе E (второй рубеж в фабрике сохранён) |
| C-MJ-03 | ИСПРАВЛЕНО | `DEFAULT_READ_ONLY_ALLOWLIST = []`; AppModule по умолчанию — пустой перечень (SEC-119: все мутации → 503), `AppModuleOptions.readOnlyAllowlist`/`TestAppOptions.readOnlyAllowlist` — явная подстановка ADR-083 в тестах п. 4 (unit и e2e на полном AppModule) | После принятия ADR-083 — заменить значение по умолчанию одной строкой |
| C-MJ-04 | ЧАСТИЧНО | Caddyfile: `request_header @noRequestId X-Request-Id {http.request.uuid}` — UUID только при отсутствии заголовка, `header_up` удалён; e2e «X-Request-Id клиента сохраняется сквозь proxy и api» (в процессе — зелёный) | Прогон того же e2e через Caddy (`SMOKE_BASE_URL`) и `caddy validate` — нужен Docker/caddy (C-BL-02) |
| C-MJ-05 | ИСПРАВЛЕНО | DDL `dev_outbox` → `pos-api/db/migrations-dev/0001_dev_outbox.sql` (с trigger и правами, отказ вне dev/test); мигратор применяет каталог вторым проходом только при `APP_ENV=dev` (журнал `pos_dev`), в образ не копируется; `grep 'CREATE TABLE.*dev_outbox' pos-api/migrations/*.sql` — 0; `scripts/check_ddl_behavior.sql` → `pos-api/test/sql/` (CI, Makefile, test:db); db-тест 11: staging-схема без `dev_outbox`; `schema_v1.sql` не изменился | — |
| C-MJ-06 | ЧАСТИЧНО | ADR-086 п. (5) уточняет ADR-085 (JDK 17 есть; блокер — jar генератора и правка pubspec). Вместо `openapi-diff` локально — e2e «экспорт `/api/v1/openapi.json` ⊆ контракт» на полном AppModule (зелёный); `java -version` JDK 17 — в журнале | `make gen-client` (openapi-generator-cli 7.x) и `oasdiff` не запускались: на машине их нет, загрузка файлов требует разрешения заказчика; в CI — job contracts-lint шаг 4 и openapi-diff |
| C-MJ-07 | ЧАСТИЧНО | `design_system/components/env_banner.dart` (`EnvBanner`, «DEV · TEST DATA» / «STAGING · TEST DATA») в `App.builder` при ENV≠prod; widget-тесты (dev, staging, prod), проверка в `boot_test` | e2e «каталог из фикстур через API» — Catalog API реализует этап E (RM-E-*); ключа ARB для текста маркера в 02 §7 нет (маркер — технический, латиницей) |
| C-MJ-08 | ИСПРАВЛЕНО | Backend: `storeUrl` в теле 426 из `app_settings.app_store_url` (только https, по платформе; ключ — предложение Q-153, в seed не создаётся), unit-тест; e2e N/N−1/N−2 на полном AppModule + PostgreSQL (1.3.0 и 1.2.0 → 200, 1.1.0 → 426). Flutter: SCR-90 `UpdateRequiredScreen` (блокирующий, без «Назад», кнопка «Обновить» при https-`storeUrl`) и мягкий `UpdateAvailableBanner` («Позже») в `app/global_states/app_version_gate.dart`; widget-тесты п. 3 | Имя ключа `app_store_url` утверждает ARCH/заказчик (Q-153); открытие ссылки (url_launcher/MDM) — RM-H |
| C-MJ-09 | ЧАСТИЧНО | `docs/stages/C_foundation_report.md` создан (статус критериев RM-C-001…015 со ссылками на журнал); `boot_test` повторён против local-stack после изменений UI | `boot_test` против тестового контура (compose, Caddy) — нужен Docker (C-BL-02) |
| C-MJ-10 | ИСПРАВЛЕНО | ADR-086 (15_DECISION_LOG): гейт слоёв `check_layers.py` вместо `custom_lint`, версии под analyzer 8, условие возврата к R3 §15 (Flutter с Dart ≥ 3.13); статус «Предложено» | Принятие ADR-086 ARCH на G-C |
| C-MJ-11 | ЧАСТИЧНО | `docs/repo_layout.md` §2 дополнен (`Makefile`, `infra/docker/`, `pos-app/env/`, `pos-api/db/`, `contracts/test-vectors/`), §3.2 — фактическое размещение `src/integrations/*` и соответствие путям 13 (ADR-086 п. 4); `check_repo_layout.py` — 0 ошибок; `check_secrets.py` — 0 находок | `gitleaks detect` не запускался: на машине нет, загрузка требует разрешения; в CI — job gitleaks |
| C-MN-01 | ИСПРАВЛЕНО | 409 → `VERSION_CONFLICT` 409, 423 → `FORBIDDEN` 403, прочие 4xx → `VALIDATION_FAILED` 400; статус берётся из перечня кода; тест | Общий 503 без кода остаётся `INTERNAL` 500: в 08 §2.4 нет общего 503-кода (коды 503 бросают модули с причиной) |
| C-MN-02 | ИСПРАВЛЕНО | `RbacGuard`: сначала субъект (401), затем политика (403); тест «маршрут без политики и без субъекта → 401» | — |
| C-MN-03 | ИСПРАВЛЕНО | `OPENAPI_PUBLIC=true` и `http://` у `SMSPRO_BASE_URL` при `APP_ENV=prod` → отказ в старте (тест); Caddy: `/health/ready` только с `private_ranges`, снаружи 404 | Поведение Caddy не проверено запуском (нет caddy/Docker) |
| C-MN-04 | ИСПРАВЛЕНО | `AppEnvironment` = dev/staging/prod (как `APP_ENV`); `env/test.json` → `env/staging.json`; prod отвергает `LOG_LEVEL=debug` и `face_scan` (`FEATURE_FACE_SCAN`/`FEATURE_FLAGS`); тесты | — |
| C-MN-05 | ИСПРАВЛЕНО | `scripts/check_no_double_money.sh` (3 правила, исключение `money-double: allow`, самопроверка через `CHECK_ROOT`), шаг в CI app-analyze-test и в `make check-contracts`; на репозитории — 0 совпадений, самопроверка — код 1 | — |
| C-MN-06 | ИСПРАВЛЕНО | `scripts/**/*.ts` в `tsconfig.json` include, eslint и prettier `npm run lint` | — |
| C-MN-07 | ИСПРАВЛЕНО | `core/database/daos/registration_draft_dao.dart`: белый список ключей (`step`, `consents`, `sphere`) и форм значений (коды `[a-z_]`, согласия `{код: bool}`); тест: ключи и значения ПДн отклоняются до записи, текст исключения без значения | Фичи регистрации (этап D) пишут черновик только через DAO |
| C-MN-08 | ИСПРАВЛЕНО | `PgIdempotencyStore.acquire` — цикл не более `IDEMPOTENCY_ACQUIRE_MAX_ATTEMPTS` (5) попыток; тест с фейковым пулом | — |
| C-MN-09 | НЕ ИСПРАВЛЕНО | Поведение не менялось (мягкий режим R1, предупреждение в логе) | Решение заказчика по Q-153 до G-H |

# Как вносить изменения в «Оптомстрой POS»

Задача: **RM-B-012** (13_IMPLEMENTATION_ROADMAP §3.2). Владелец файла — главный архитектор (`ARCH`).

Документ описывает правила этапа 2 (разработка):

- версионирование и изменение контрактов;
- владельцев каталогов;
- состав CI-job `contracts-lint`;
- шаблоны отчёта этапа и ADR.

Источник правил — 13 §2.1, §5, §6, ядро R0 §10–§11, §18.1, §19.1, §20.1 и 15 §2. Если этот файл расходится с ними, правы они. Этот файл тогда исправляется по процедуре §4.

---

## 1. Правила, которые не нарушаются

1. **Сначала контракты, потом код** (13 P-2, §5.4 п. 1). Код фичи не пишется, пока не зафиксированы контракты RM-B-003…RM-B-009. Код, который расходится с контрактом, считается дефектом. «Подправить контракт под код» нельзя.
2. **У каждого файла один владелец** (13 P-3, §3 ниже). Остальные меняют его только через PR с ревью владельца.
3. **Следовать утверждённому ТЗ** (13 P-5; 15 §2.3). Отклонение от архитектуры или бизнес-правил, которое заметно влияет на ТЗ, допускается только так:
   - сначала новая запись ADR в `docs/specification/15_DECISION_LOG.md` с причиной;
   - затем согласование заказчиком;
   - затем правка документа ТЗ его владельцем.

   После утверждения ТЗ (2026-10-21, `docs/stages/B_approval.md`) документы `docs/specification/**` не меняются без ADR и уведомления заказчика.
4. **Источник истины для словарей — документ-владелец** (ядро §18.1, §19.1, §20.1). Изменение всегда начинается у владельца, затем переходит в контракт, затем в код:

   | Словарь | Документ-владелец | Контракт |
   |---|---|---|
   | коды `permissions` и матрица «роль × право» | 11 §4.3–§4.4 | `contracts/rbac/permissions.yaml` |
   | события аудита `audit_logs.action` | 11 §7.2 | — (константы `pos-api`) |
   | enum-ы, CHECK-перечни, локальная схема drift | 07 §6, §11 | `contracts/enums.json`, DDL `pos-api/migrations/` |
   | коды ошибок HTTP и коды журнала синхронизации | 08 §2.4 | `contracts/enums.json`, `contracts/openapi/pos-api.v1.yaml` |
   | DTO, пути и коды ответов клиентского API | 08 | `contracts/openapi/pos-api.v1.yaml` |
   | методы HTTP-сервиса 1С `/pos/v1/*` | 05 §6 (изложение для специалиста 1С — 18, только после 05) | `contracts/onec/onec-http-service.v1.yaml` |
   | входящий обмен с 1С (C-2) | 05 §10.1 | `contracts/openapi/pos-api.v1.yaml` (`/integrations/onec/*`) |
   | переменные окружения | 16 §4.3 | `.env.example` |
   | токены, компоненты, анимации, правила и общие ключи ARB | 03 (общие ключи — 03 §16) | `contracts/design-tokens/tokens.json`, `contracts/l10n/app_*.arb` |
   | экранные строки ARB | 02 §7 (при конфликте имени ключа прав 03) | `contracts/l10n/app_*.arb` |
   | ID тестов `T-*` | 12 | — |

5. **Тесты запускаются, а не только пишутся** (13 P-6). У любой задачи критерий завершения — команда и её фактический результат. Лог запуска прикладывается к отчёту этапа (§7). Писать «реализовано» или «работает» без доказательства запрещено (ядро §0).
6. **Изолированный тестовый режим вместо подмены интеграций** (13 P-7):
   - `ONEC_MODE=fixtures`, `SMS_PROVIDER=fake`, `AUTH_OTP_TEST_MODE` запрещены при `APP_ENV=prod`;
   - фиктивные данные никогда не выдаются за реальные.
7. **Секреты не попадают в репозиторий.** Только файлы `*_FILE` вне git (16 §4.3). Проверка — `gitleaks detect` (RM-C-001, RM-C-009).
8. **Не переписывать целые файлы без необходимости** (SRC-A-012). **Не редактировать один файл параллельно** несколькими агентами без согласованного разделения (SRC-A-021).
9. Каталог `resursi/` — материалы заказчика (макеты, логотип). Он не изменяется.

---

## 2. Контракты

Перечень контрактов, владельцы и проверки — по 13 §5.1:

| Контракт | Файл | Владелец | Потребители | Проверка в CI |
|---|---|---|---|---|
| API клиент ↔ сервер | `contracts/openapi/pos-api.v1.yaml` | BE (автор), FE + SEC (ревью) | `pos-api` (реализация, экспорт `/openapi.json` сравнивается), `pos-app` (сгенерированный клиент) | `redocly lint`, `openapi-diff` (breaking → красный), `check_api_paths.py`, `check_api_permissions.py` |
| Backend ↔ 1С | `contracts/onec/onec-http-service.v1.yaml` (методы `/pos/v1/*` — строго канон 05 §6.3, R0 §17.4), `contracts/onec/odata-allowlist.yaml`, `contracts/onec/fixtures/` | ONEC | `pos-api/src/sync`, `onec-extension` (реализует специалист 1С заказчика по `18_ONEC_API_REQUEST.md`, ядро §24.3), `FakeOnecGateway` | `redocly lint`, `check_onec_paths.py` (набор путей = 05 §6.3), валидация фикстур схемой, тест «фикстуры ↔ маппер» |
| Схема БД | `pos-api/migrations/*.sql` + `pos-api/src/db/schema/*.ts` | BE (data) | все модули backend | этап B: `psql -f` на пустом PostgreSQL 17 + `check_tables.sql` (RM-B-005); с этапа C: `drizzle-kit check`, контейнер `migrate` на пустой БД, идемпотентность повторного запуска (RM-C-006, RM-C-012) |
| Дизайн-токены | `contracts/design-tokens/tokens.json` | DS | `pos-app/lib/design_system/tokens` (генерация), `visual/*.html` (CSS-переменные `--ds-color-*`) | этап B: JSON Schema, детерминизм генератора, `contrast.py` по разрешённым сочетаниям 03 §5.4 (RM-B-006); с этапа C: `tokens_test.dart` (JSON ↔ Dart, RM-C-003) |
| Строки UI | `contracts/l10n/app_*.arb` (источник) → `pos-app/lib/l10n/app_*.arb` (копия с этапа C) | DS + FE | все экраны | этап B: `check_arb_keys.py` (RM-B-007); с этапа C: `flutter gen-l10n`, `sync_contracts.py --check` (RM-C-002) |
| Права | `contracts/rbac/permissions.yaml` | SEC | guard backend, видимость в UI, e2e-матрица | генерация e2e-матрицы, `check_api_permissions.py` |
| Enum-ы и коды ошибок | `contracts/enums.json` | BE | TS и Dart (генерация с этапа C) | детерминированная генерация (пустой diff), сверка с 07 §6; с этапа C — импорт в unit-тестах (RM-C-004/RM-C-005), тест `error_mapper` (0 unknown) |
| Тексты согласий | `contracts/legal/consents_ru.md` | заказчик (юрист) / SEC | регистрация (версия согласия) | версия в `consents.version` совпадает с заголовком файла |

Где хранится версия каждого контракта:

| Контракт | Поле версии | Журнал изменений |
|---|---|---|
| `contracts/openapi/pos-api.v1.yaml` | `info.version` (SemVer) | `contracts/openapi/CHANGELOG.md` (выход RM-B-003) |
| `contracts/onec/onec-http-service.v1.yaml` | `info.version` (SemVer) | `contracts/onec/CHANGELOG.md` |
| `contracts/onec/odata-allowlist.yaml`, `contracts/onec/fixtures/` | версия набора `contracts/onec` — общая с HTTP-сервисом | `contracts/onec/CHANGELOG.md` |
| `contracts/enums.json` | поле `version` (SemVer, проверяется `contracts/enums.schema.json`) | `contracts/CHANGELOG.md` |
| `contracts/design-tokens/tokens.json` | `meta.version` (SemVer) | `contracts/design-tokens/CHANGELOG.md` |
| `contracts/rbac/permissions.yaml` | поле `version` | `contracts/rbac/CHANGELOG.md` |
| `contracts/l10n/app_*.arb` | версия набора ARB — в журнале | `contracts/l10n/CHANGELOG.md` |
| `contracts/legal/consents_ru.md` | версия в заголовке файла = `consents.version` (13 §5.1) | история версий в самом файле; меняет только заказчик (юрист) |
| `pos-api/migrations/*.sql` (схема БД) | номер файла миграции (`0001_…`, `0002_…`), не SemVer | заголовок-комментарий миграции + `docs/erd/` |

Журнал `CHANGELOG.md` создаётся при первом изменении контракта после версии `1.0.0`. Для OpenAPI его создаёт RM-B-003. Формат записи:

```
## <версия> · <дата ГГГГ-ММ-ДД>
- <added|changed|deprecated> <что именно: путь / поле / значение / токен / ключ>
  Основание: <ID требования ТЗ или ADR-NNN>; запрос: <ссылка на PR или задачу>; статус: proposed|active
```

---

## 3. Версионирование контрактов (SemVer)

Каждый контракт версионируется отдельно в формате `MAJOR.MINOR.PATCH`. Первая зафиксированная версия этапа B — `1.0.0`.

| Часть | Когда поднимается | В R1 |
|---|---|---|
| `MAJOR` | breaking-изменение: удаление или переименование пути, поля, значения enum, кода ошибки, токена, ключа ARB или кода права; смена типа, формата или семантики; новое обязательное поле запроса; сужение допустимых значений | **запрещено** (§4 п. 5) |
| `MINOR` | expand-изменение: новый путь, необязательное поле запроса, новое поле ответа, новое значение enum или кода ошибки, новый токен, ключ ARB, код права, метод 1С | основной вид изменений (13 §5.3 п. 2) |
| `PATCH` | изменение без влияния на потребителей: описания, примеры, опечатки в `description`, `x-*`-метаданные, которые не меняют поведение | допускается |

Правила R1:

1. **Expand-only.** Существующие пути, поля, значения, коды и ключи не удаляются и не меняют смысл (13 §5.3 п. 2). Устаревший элемент можно пометить `deprecated: true` (OpenAPI) или записью `deprecated` в журнале. Удалить его можно только в следующем мажорном релизе.
2. **Новая часть контракта до реализации** помечается `x-status: proposed` и не используется потребителями (13 §5.3 п. 4). Когда реализация готова у всех потребителей, метка снимается (`PATCH`).
3. **Условные элементы R1** (13 §3.12, §5.4 п. 5) присутствуют в контракте с `x-feature-flag` и `x-status: proposed`, пока не принято решение «да». Флаги — только канонические имена R0 §16 п. 3 и §17.7 (13 §5.4 п. 5). Новые имена флагов не вводятся.
4. **Схема БД — forward-only.** Миграции идут по схеме expand → migrate → contract. Применённая миграция не изменяется. Шаги `contract`, то есть удаление или переименование колонок и таблиц, в R1 запрещены (13 §5.2, строка `pos-api/migrations/**`).
5. **Версия контракта ≠ версия приложения.** Поддержка версий клиента N и N−1, `MIN_APP_VERSION` и HTTP 426 `APP_UPDATE_REQUIRED` описаны отдельно (ADR-059, ADR-062; 13 §5.4 п. 7). API остаётся совместимым с клиентом N−1 именно потому, что R1 — expand-only.
6. **Сгенерированный код не правят руками.** TS- и Dart-enum-ы, Dart-токены и клиент `pos_api_client` генерируются из контрактов. Повторная генерация должна давать пустой diff (RM-B-006, RM-B-009, RM-C-004).

---

## 4. Процедура изменения контракта (13 §5.3)

1. Инициатор открывает запрос на изменение с обоснованием и ссылкой на требование ТЗ (или ADR, если ТЗ меняется).
2. Владелец контракта вносит изменение **expand-only** (новые поля/эндпоинты/значения; существующие не удаляются и не меняют семантику в R1), поднимает minor-версию, пишет запись в `CHANGELOG.md`.
3. CI проверяет: lint, `openapi-diff` без breaking, генерация клиентов/enum-ов даёт обновлённый код.
4. Потребители обновляют реализацию в том же или следующем PR; до этого новая часть контракта помечена `x-status: proposed` и не используется.
5. Breaking-изменение в R1 запрещено; если неизбежно — ADR, согласование заказчика (если влияет на ТЗ — P-5), мажорная версия контракта и одновременное обновление всех потребителей в одном релизе.

Порядок на практике:

| Шаг | Кто | Что сделать | Чем подтверждается |
|---|---|---|---|
| 0 | инициатор | Проверить, есть ли значение у документа-владельца словаря (§1 п. 4). Если нет — сначала ADR и правка документа-владельца (`ARCH` + автор документа), потом контракт. Пример: новая переменная окружения сначала вносится в 16 §4.3, потом в `.env.example` (RM-C-009 п. 3). Метод 1С сначала появляется в 05 §6, потом в 18 и `contracts/onec` (ONEC-074) | ссылка на ID требования или ADR в запросе |
| 1 | инициатор | Запрос на изменение: что, зачем, ссылка на ID ТЗ или ADR, список потребителей | PR или задача |
| 2 | владелец контракта (13 §5.1) | Внести изменение expand-only, поднять `MINOR` (или `PATCH`), добавить запись в `CHANGELOG.md`, пометить новое `x-status: proposed` | diff контракта |
| 3 | CI | `contracts-lint` (§6) и `openapi-diff` — зелёные; генераторы дают обновлённый код | статусы PR |
| 4 | ревью | Владелец контракта + `ARCH`. Для `openapi` дополнительно FE и SEC (13 §5.1) | одобрения PR |
| 5 | потребители | Реализовать в том же или следующем PR, затем снять `x-status: proposed` | e2e, контрактные тесты |
| 6 | `ARCH` | Записать изменение в отчёт этапа (§7), раздел «Готовые файлы» | `docs/stages/<X>_<name>_report.md` |

---

## 5. Владельцы модулей и файлов (13 §5.2)

Таблица совпадает с 13 §5.2. При расхождении прав 13: таблица исправляется здесь по процедуре §4.

| Каталог / модуль | Владелец | Кто может менять по запросу | Запрещено |
|---|---|---|---|
| `contracts/**` | ARCH (координация), конкретные файлы — по §5.1 | только через PR с ревью владельца и ARCH | прямые правки без изменения версии |
| `pos-api/src/auth`, `registration`, `profile`, `common/rbac`, `common/audit` | SEC | BE | хранение паролей, логирование OTP/токенов |
| `pos-api/src/notifications/sms/**` (SMS-шлюзы `SmsGateway`, `SmsProXmlGateway`, `FakeSmsGateway`) | SEC | BE | хранение/логирование OTP и паролей SMSPro |
| `pos-api/src/catalog`, `cart`, `orders`, `payments`, `customers`, `transactions`, `returns`, `admin`, `notifications` (кроме `sms/`), `health`, `common/*` (кроме rbac/audit) | BE | POS (бизнес-правила через тесты), SEC (ревью) | вычисление цен/скидок/долгов где-либо кроме этих модулей |
| `pos-api/src/sync/**`, `onec-extension/**` (контракт, журнал и копии версий расширения от специалиста 1С; код расширения пишет специалист 1С заказчика по `18_ONEC_API_REQUEST.md` — ядро §24.3) | ONEC | BE, специалист 1С (код расширения) | прямые запросы к 1С из других модулей (только через `OnecGateway`, 05 ONEC-023) |
| `pos-api/migrations/**`, `pos-api/src/db/**` | BE (data) | ONEC (реплики 1С), SEC (auth-таблицы) | изменение применённых миграций; `contract`-шаги в R1 |
| `pos-app/lib/design_system/**`, `pos-app/lib/l10n/**`, `assets/rive`, `assets/fonts` | DS | FE | бизнес-логика, импорт `features/` |
| `pos-app/lib/core/**`, `pos-app/lib/app/**`, `pos-app/packages/pos_api_client` | FE | SEC (`network/interceptors/auth`, `storage`, `hardware/biometric`) | знание о конкретных фичах |
| `pos-app/lib/features/<feature>/**` | FE (по фичам: auth/registration — совместно с SEC) | DS (presentation-виджеты), POS (тексты правил) | импорт другой фичи напрямую (только `domain` владельца сущности) |
| `pos-app/android/**`, `ios/**`, `windows/**` (нативный код биометрии, разрешения) | FE + SEC | OPS (подпись) | — |
| `infra/**`, `.github/workflows/**`, `.env.example` | OPS | BE (переменные) | секреты в репозитории |
| `pos-api/test/e2e/**`, `pos-app/integration_test/**`, `docs/reviews/**`, `docs/stages/*_test_run.log` | QA | владельцы модулей (unit/widget-тесты в своих каталогах) | правка тестов автором проверяемого кода без ревью QA |
| `docs/pilot/**`, `docs/owner_actions.md`, руководства пользователей | POS | ARCH, OPS | — |
| `docs/specification/**` (ТЗ), `docs/adr/**`/15_DECISION_LOG, `docs/stages/*_report.md` | ARCH | авторы документов этапа 1 | изменение ТЗ без ADR и уведомления заказчика после утверждения |

Роли (13 §2.2): `ARCH` — главный архитектор (оркестратор); `BE` — backend; `FE` — Flutter; `ONEC` — интеграция с 1С; `SEC` — аутентификация и безопасность; `DS` — дизайн-система; `OPS` — DevOps; `QA` — тестирование и независимый аудит; `POS` — POS-аналитик.

Каталоги `contracts/**`:

- `contracts/openapi/**` — `BE`;
- `contracts/onec/**` — `ONEC`;
- `contracts/design-tokens/**` — `DS`;
- `contracts/l10n/**` — `DS` + `FE`;
- `contracts/rbac/**` — `SEC`;
- `contracts/enums.json` — `BE`;
- `contracts/legal/**` — заказчик (юрист) / `SEC`.

Координирует их `ARCH` (13 §5.1). Каталог `tools/` (служебные инструменты разработки, например раннер PostgreSQL `tools/pg`) и `scripts/` (проверочные скрипты контрактов) ведёт `ARCH`. Изменять их можно через PR с ревью `ARCH`.

---

## 6. CI-job `contracts-lint`

Реализуется в RM-C-011 (13 §3.3). До этапа C те же команды выполняются локально или во временном CI-workflow контрактов, и их логи прикладываются к RM-B-013 (13 §3.2, ворота G-B2).

**Когда запускается:** на каждый PR и push в `main`, если изменены `contracts/**`, `pos-api/migrations/**`, `scripts/check_*`, `scripts/gen_*` или `.env.example`; плюс ежедневно по расписанию.

**Где запускается:** Linux-раннер (обязателен с этапа C, ядро §20.2 п. 1). Нужны Python 3 (`jsonschema`, `pyyaml`), Node LTS (`npx`), Java 11+ (для `openapi-generator-cli`) и сервис `postgres:17`.

**Результат:** любой шаг с кодом выхода ≠ 0 делает job красным. Статус job обязателен для merge в `main` (RM-C-011 п. 2). Ни один шаг не обращается к сети, кроме установки пакетов.

| № | Шаг | Команда | Что проверяет | Источник |
|---|---|---|---|---|
| 1 | Lint OpenAPI клиентского API | `npx @redocly/cli lint contracts/openapi/pos-api.v1.yaml` | 0 ошибок | RM-B-003 п. 1 |
| 2 | Пути API | `python scripts/check_api_paths.py` | есть все пути и методы R0 §7, §17.4, §19.2; нет неканонических и R2-путей | RM-B-003 п. 2 |
| 3 | Права на эндпоинтах | `python scripts/check_api_permissions.py --require-operations` | у каждого эндпоинта есть `x-permissions` (массив кодов, 08 §8; прежнее написание `x-permission` скрипт тоже читает), каждый код — из словаря 11 §4.3 | RM-B-008 п. 1 (B-AR-18) |
| 4 | Генерация клиента | `openapi-generator-cli generate -g dart-dio` во временный каталог | генерация без ошибок | RM-B-003 п. 3 |
| 5 | Lint контракта 1С | `npx @redocly/cli lint contracts/onec/onec-http-service.v1.yaml` | 0 ошибок | RM-B-004 п. 1 |
| 6 | Пути 1С | `python scripts/check_onec_paths.py` | набор `/pos/v1/*` = 05 §6.3 (0 лишних, 0 недостающих) | RM-B-004 п. 2 |
| 7 | Фикстуры 1С | валидация `contracts/onec/fixtures/` схемой | фикстуры соответствуют схеме | RM-B-004 п. 4 |
| 8 | DDL | `PGOPTIONS='-c app.env=test' psql -v ON_ERROR_STOP=1 -f pos-api/migrations/0001_init.sql`, затем `-f pos-api/migrations/0002_rbac_seed.sql` на пустом `postgres:17` (без Docker — `node tools/pg/run-sql.mjs --set app.env=test --repeat-strict pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql`) | миграции применяются без ошибок; повтор — 0 изменений | RM-B-005 п. 1, RM-B-008 п. 2, RM-C-006 п. 4 |
| 9 | Состав таблиц | `psql -v ON_ERROR_STOP=1 -f scripts/check_tables.sql` — дважды: на dev/test-схеме (`app.env=test`) и на prod-схеме (без `app.env`) | dev/test — 64 таблицы; prod — 63, `dev_outbox` отсутствует (B-AR-09, 07 §5.63) | RM-B-005 п. 2 |
| 10 | Токены | `python -m jsonschema` (или `ajv`) `contracts/design-tokens/tokens.json` по `tokens.schema.json` | структура токенов | RM-B-006 п. 1 |
| 11 | Генератор токенов | `python scripts/gen_tokens_dart.py` дважды во временный каталог, затем `diff` | детерминизм (пустой diff) | RM-B-006 п. 2 |
| 12 | Контраст | `contrast.py` (R4 Прил. A) по разрешённым парам 03 §5.4 и п. 5.4.5 | 0 пар ниже AA; 0 сочетаний «белый текст на `primary`» | RM-B-006 п. 3 |
| 13 | ARB | `python scripts/check_arb_keys.py` | валидный JSON, описания ключей, префиксы, 0 дублей 02 §7 / 03 §16, совпадение ключей и плейсхолдеров `ky`/`en` с `ru`, ICU | RM-B-007 |
| 14 | Enum-ы и коды | `python -m jsonschema` `contracts/enums.json` по `enums.schema.json`; `python scripts/check_enums.py` (сверка с 07 §6 и 08 §2.4) | структура и совпадение значений | RM-B-009 пп. 1, 3 |
| 15 | Генератор enum-ов | `python scripts/gen_enums.py` дважды во временный каталог, затем `diff` | детерминизм TS и Dart | RM-B-009 п. 2 |
| 16 | Версия и журнал | для каждого изменённого контракта: поле версии изменено по §3, в `CHANGELOG.md` есть запись с этой версией | процедура §4 п. 2 | 13 §5.3 п. 2 |
| 17 | Копии контрактов (с этапа C) | `python scripts/sync_contracts.py --check` | копии ARB в `pos-app/lib/l10n/` идентичны `contracts/l10n/` | RM-C-002 п. 4 |
| 18 | Переменные окружения (с этапа C) | `python scripts/check_env_example.py` | `.env.example` = 16 §4.3 (0 лишних, 0 недостающих) | RM-C-009 п. 2 |
| 19 | Сборка OpenAPI из частей | `python scripts/build_openapi.py --check` | `pos-api.v1.yaml` совпадает со сборкой `contracts/openapi/parts/*` (дрейф → код 1) | `contracts/openapi/NOTES.md` §7.1 |
| 20 | Словари корня OpenAPI | `python scripts/check_openapi_dictionaries.py` | `ProblemCode` = 08 §2.4, `PermissionCode` = 11 §4.3, enum-ы = 07 §6.1, `StepUpOperation` = 08 §2.12, теги = 08 §8, все `$ref` разрешаются, примеры 08 §3.7 валидны по `CustomerView*`, негативные случаи (две роли в `roles`, B-AR-02) отвергаются | B-AR-10 (в) |
| 21 | Треугольник enum-ов | `python scripts/check_enum_triangle.py` | `contracts/enums.json` ↔ `CREATE TYPE` в DDL ↔ enum-схемы OpenAPI: имена и порядок значений совпадают | B-AR-10 (г) |
| 22 | Seed прав из матрицы | `python scripts/gen_rbac_seed.py --check` | `pos-api/migrations/0002_rbac_seed.sql` совпадает с генерацией из `contracts/rbac/permissions.yaml` (правка — только в YAML) | B-AR-10 (а) |
| 23 | Поведение DDL | `node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql pos-api/db/migrations-dev/0001_dev_outbox.sql --check pos-api/test/sql/check_ddl_behavior.sql` (перенесён из `scripts/` по RM-C-006 п. 7; в CI — `psql` на `postgres:17`) | негативные сценарии CHECK/UNIQUE/триггеров отклоняются, позитивные инварианты (`row_version`, хэш-цепочка аудита, `subject_key`, `onec_key`, повторная выдача роли) выполняются; код 0 | B-AR-10 (б) |
| 24 | Сборка ARB | `python scripts/build_arb.py --check` | `contracts/l10n/app_*.arb` совпадают со сборкой из 02 §7 и 03 §16 (дрейф → код 1); `--strict-coverage` у шага 13 включается после текстов владельца 03 (B-AR-11) | RM-B-007, B-AR-11 |
| 25 | Дрейф Dart-токенов (с этапа C) | `python scripts/gen_tokens_dart.py pos-app/lib/design_system/tokens --check` | сгенерированные `ds_*.dart` совпадают с `tokens.json`; генератор сам пишет их в форме `dart format --page-width 120`, поэтому форматирование `pos-app` проверку не ломает (`contracts/design-tokens/NOTES.md` §4) | RM-C-003 |

Что в `contracts-lint` не входит. Это отдельные обязательные job-ы RM-C-011:

- `openapi-diff` — сравнение `contracts/openapi/pos-api.v1.yaml` с версией в `main` и с экспортом `/openapi.json`; breaking-изменение делает job красным (13 §5.1, §5.3 п. 3);
- `gitleaks`;
- `api-lint-test`;
- `api-e2e`;
- `app-analyze-test` (там `tokens_test.dart`, импорт сгенерированных enum-ов, `flutter gen-l10n`);
- `security-class-a`;
- `coverage-gate`.

Скрипты шагов 2, 3, 6, 7, 9, 11, 12, 15–18 появляются в задачах RM-B-003…RM-B-009 и RM-C-002, RM-C-009. Шаги 19–25 добавлены по итогам архитектурной проверки этапа B (`docs/reviews/B_architecture_review.md`, B-AR-09, -10, -11, -18; `docs/stages/B_architecture_report.md`, B-KI-05); их скрипты уже есть в `scripts/`, журнал прогона — `docs/stages/B_checks.log`. Пока скрипта нет, шаг отмечается в логе как «не выполнен: скрипт отсутствует, задача RM-…». Такой шаг не засчитывается как пройденный. Скрипт шага 16 — `[НОВОЕ ИМЯ]`: имя и реализация определяются в RM-C-011.

---

## 7. Отчёт этапа и ADR

- **Отчёт этапа** — `docs/stages/<X>_<name>_report.md`, по шаблону `docs/templates/stage_report.md`. Структура — 13 §6.3: готовые файлы, выполненные проверки, известные проблемы, условия перехода, приложения. Отчёт сдаётся задачей «Фиксация этапа» (RM-A-010, RM-B-013, RM-C-014, …).
- **ADR** — запись в `docs/specification/15_DECISION_LOG.md` по шаблону `docs/templates/adr.md`. Поля — 15 §2.1, статусы — 15 §2.1, правила замены — 15 §2.3. Номер — следующий свободный `ADR-NNN`. Решение не удаляется и не правится задним числом: при замене создаётся новая запись, а у старой меняется статус. Новая запись добавляется в индекс 15 §7.
- **Definition of Done** задачи и модуля — 13 §6.1 (12 пунктов). Уровни готовности ворот: зелёный, жёлтый, красный — 13 §6.2.

## 8. Ветки, PR и коммиты

1. Работа ведётся в ветках от `main`. Merge в `main` — только через PR с зелёными обязательными job-ами CI (RM-C-011 п. 2).
2. В описании PR указываются ID требований ТЗ и задачи `RM-*` (13 §6.1 п. 1). Если PR меняет контракт, указываются версия до и после.
3. Тесты в чужом каталоге автор кода не правит без ревью `QA` (13 §5.2).
4. Структура репозитория — `docs/repo_layout.md`. Новый каталог верхнего уровня появляется только через ADR.

# Отчёт по этапу B — Architecture (утверждение ТЗ и контракты) «Оптомстрой POS»

**Этап:** B — Architecture (утверждение ТЗ и контракты) · **Задача фиксации этапа:** RM-B-013 · **Ворота:** G-B1 (закрыты), G-B2 (предлагается «жёлтый», §4)
**Дата отчёта:** 2026-10-21 · **Автор (владелец отчёта):** главный архитектор `ARCH` (13 §2.2) · **Независимый проверяющий:** архитектурная проверка RM-B-010 выполнена ролью QA (`docs/reviews/B_architecture_review.md`); независимая проверка этого отчёта не назначена (см. §3, B-KI-12)
**Основание:** 13_IMPLEMENTATION_ROADMAP v2.0 §3.2 (RM-B-001…RM-B-014), §6.2–§6.3, §9; ядро R0 v1.9 (§24 — ответы заказчика 2026-10-21, высший приоритет)

**Итог в одной строке.** Контракты этапа B созданы, и все их проверочные команды, которые можно выполнить на этой машине, повторно прогнаны 2026-10-21 в 21:04 с ожидаемым кодом выхода: 26 из 26 (§2). Не выполнены три вещи. Генерация клиента `dart-dio` (RM-B-003 п. 3) не запускалась: локально только Java 8. Заказчик не подписал лист изменений и не ответил на 20 блокирующих вопросов (RM-B-002, RM-A-003). ADR-083 не внесён в 08 и 11. Блокеров и открытых критичных замечаний нет. Предлагаемый статус G-B2 — **жёлтый** (§4).

---

## 1. Готовые файлы

Владельцы взяты из `CONTRIBUTING.md` §5. Эта таблица совпадает с 13 §5.2: 16 строк из 16 одинаковы, проверка — §2, строка 27. Новые пути в git не отслеживаются (`??`), изменённые документы ТЗ и ядра — не закоммичены; коммитов этапа B нет. Версия контракта у всех новых файлов — «— → 1.0.0» (`info.version` / `version`). Контракты ещё не опубликованы, поэтому правки по архитектурной проверке версию не повышали (`contracts/openapi/CHANGELOG.md`, раздел [1.0.0]).

### 1.1. Статус задач этапа

| Задача | Статус | Основание |
|---|---|---|
| RM-B-001 Ворота утверждения | **закрыта** | `docs/stages/B_approval.md`: фраза «ТЗ УТВЕРЖДЕНО. НАЧИНАЙ РАЗРАБОТКУ», 2026-10-21; G-B1 закрыты |
| RM-B-002 Ответы заказчика в ядро и ТЗ, ADR `APP_READ_ONLY` | **частично** | Выполнено: ядро v1.9 §24, ТЗ и лист `docs/stages/B_changes.md`. П. 2 не выполнен: подписи заказчика нет («подпись не получена»). П. 3 не выполнен: ADR-083 в статусе «Предложено», в 08 и 11 ссылок на ADR-083 нет (§2, строка 28). Механизм ограничения мутаций на шаге 1 (13 §8.4) остаётся открытым (`infra/NOTES.md` п. 13). П. 1 (`git diff` ТЗ) этим отчётом отдельно не проверялся |
| RM-B-003 Контракт API | **частично** | П. 1 и п. 2 выполнены (строки 2–3). П. 3 (`openapi-generator-cli generate -g dart-dio`) **не выполнялся**: на машине Java 8, а openapi-generator 7 требует Java 11+ (§3, B-KI-01) |
| RM-B-004 Контракт 1С | **критерии 1–4 выполнены**; контракт — черновик v1.0.0 для согласования | Строки 7–8. 33 коллекции OData: все `[ТИПОВО]`/`[НЕ ПОДТВЕРЖДЕНО]` с fallback, подтверждённых `$metadata` — 0. HTTP-сервис существует только как контракт: в нём 28 мест `x-status: proposed` (по журналу версий `contracts/onec/NOTES.md` §6), реализацию делает специалист 1С (RM-B-014). Это допустимый для G-B2 статус «OData-часть готова, HS-часть `[ТИПОВО]`» |
| RM-B-005 Схема БД | **критерии 1–2 выполнены** (замена `psql` — §3, B-KI-02); п. 3 сверен выборочно | Строки 10–12. Поля сверены с 07 у 18 таблиц из 64 (отчёт RM-B-010 §6). `docs/erd/README.md` устарел относительно DDL (B-KI-04) |
| RM-B-006 DS-токены (палитра B) | **закрыта** | Строки 13–17. Замечание B-AR-15 (`alternatives.A` в `tokens.json`) вынесено на решение G-B2 |
| RM-B-007 Словарь строк UI (ARB) | **закрыта по критерию**; полнота общих ключей 03 — нет | Строки 18–21. `--strict-coverage` → код 1 (ожидаемо): 22 `status_*` и 22 `error_*` не имеют текста у владельца 03 (B-AR-11). `ky`/`en` — каркас-копия `ru` |
| RM-B-008 Матрица прав | **п. 1–2 выполнены**; п. 3 — этап D | Строки 4, 9, 10 |
| RM-B-009 Enum-ы и коды ошибок | **закрыта** | Строки 22–26, 6 |
| RM-B-010 Архитектурная проверка | **закрыта, блокеров нет** | `docs/reviews/B_architecture_review.md`: 0 блокеров; 2 критичных исправлены; из 10 major исправлено 5, частично 3, передано владельцам документов 2; из 11 minor исправлено 6, вынесено на G-B2 1, передано владельцам 4 |
| RM-B-011 Сценарий развёртывания | **закрыта по критерию** (аудита нет) | ADR-082 «Принято условно» в 15 (варианты A–D с отвергнутыми, «сценарий A по умолчанию, пересмотр до I»), `infra/README.md`. Документ 16 этим решением не менялся (ADR-082 п. 6) |
| RM-B-012 CONTRIBUTING, шаблоны | **закрыта по критерию** | Таблица владельцев совпадает с 13 §5.2 (строка 27); состав `contracts-lint` описан в `CONTRIBUTING.md` §6. В нём не хватает 6 проверок, добавленных после ревью (B-KI-05) |
| RM-B-013 Отчёт этапа | этот файл | — |
| RM-B-014 API 1С от специалиста | не начата (у заказчика) | Условием G-B2 не является (13 §3.2) |

### 1.2. Пути

| Путь | Новый / изменён | Задача `RM-*` | Владелец | Версия контракта (было → стало) | Примечание |
|---|---|---|---|---|---|
| `docs/stages/B_approval.md` | новый | RM-B-001 | ARCH | — | дата и текст фразы; ответы Q-001, Q-006, Q-010/011, Q-014 |
| `docs/stages/B_changes.md` | новый | RM-B-002 | ARCH | — | лист изменений ТЗ для подписи; **не подписан** |
| `docs/research/R0_DECISION_KERNEL.md`, `docs/specification/00…17`, `README.md`, `visual/*` | изменены | RM-B-002 | ARCH | ядро → v1.9; версии документов — `B_changes.md` §2 | перечень и журналы сверки — `B_changes.md` §2 |
| `docs/specification/18_ONEC_API_REQUEST.md` | новый | RM-A-011 / RM-B-002 (ядро §24.3) | ONEC | v1.0 | ТЗ на API 1С для специалиста 1С |
| `docs/specification/15_DECISION_LOG.md` | изменён (дописаны ADR-082, ADR-083) | RM-B-011, RM-B-002 | ARCH | — | Сводные счётчики §7, §9.2 и приложение Б не обновлены (`infra/NOTES.md` п. 14) |
| `contracts/openapi/pos-api.v1.yaml` | новый (собирается) | RM-B-003 | BE | — → 1.0.0 | 119 путей, 141 операция, 314 схем; sha256 `3ac07559…` (строка 1) |
| `contracts/openapi/parts/{00_root,10_auth,20_catalog,30_cart_orders,40_payments_pos_returns,50_customers,60_sync_admin_ops}.yaml` | новые | RM-B-003 | BE | — | источник сборки; вручную правится только `parts/` |
| `contracts/openapi/CHANGELOG.md`, `contracts/openapi/NOTES.md` | новые | RM-B-003 | BE | — | решения при неоднозначностях; предложения владельцам 06/08 — `NOTES.md` §8.2 |
| `contracts/onec/onec-http-service.v1.yaml` | новый | RM-B-004 | ONEC | — → 1.0.0 (черновик для согласования) | 21 операция `/pos/v1/*` = 05 §6.3 |
| `contracts/onec/odata-allowlist.yaml` | новый | RM-B-004 | ONEC | — → 1 | 33 коллекции, все `[ТИПОВО]` с fallback |
| `contracts/onec/fixtures/*.json` (58 файлов) | новые | RM-B-004 | ONEC | — | синтетические тестовые данные; строгая валидация схемой |
| `contracts/onec/NOTES.md` | новый | RM-B-004 | ONEC | — | 9 расхождений 05↔18 (§4), журнал версий контракта (§6) |
| `pos-api/migrations/0001_init.sql` | новый | RM-B-005 | BE (data) | — | 374 команды; 64 таблицы (dev/test) / 63 (prod), 45 enum-типов |
| `pos-api/migrations/0002_rbac_seed.sql` | новый (генерируется) | RM-B-008 | SEC (данные) / BE (data) | — | генерируется из `permissions.yaml` скриптом `gen_rbac_seed.py` |
| `pos-api/migrations/NOTES.md` | новый | RM-B-005 | BE (data) | — | замечания к 07 (§8), предложения после ревью (§10) |
| `docs/erd/README.md` | новый | RM-B-005 | BE (data) | — | **устарел** относительно DDL после исправлений B-AR (B-KI-04) |
| `contracts/design-tokens/tokens.json`, `tokens.schema.json`, `NOTES.md` | новые | RM-B-006 | DS | — → 1.0.0 | `meta.palette = "B"`; `alternatives.A` — B-AR-15 |
| `contracts/l10n/app_ru.arb`, `app_ky.arb`, `app_en.arb`, `NOTES.md` | новые | RM-B-007 | DS + FE | — | 1939 ключей, 366 с плейсхолдерами; `ky`/`en` — каркас |
| `contracts/rbac/permissions.yaml`, `contracts/rbac/NOTES.md` | новые | RM-B-008 | SEC | — → 1 | 7 ролей, 77 кодов, 231 пара роль→право (по контролю seed) |
| `contracts/enums.json`, `contracts/enums.schema.json`, `contracts/NOTES_enums.md` | новые | RM-B-009 | BE | — → 1.0.0 | 45 `dbEnums`, `checkLists`, 50 `problemCodes`; генерация — 78 перечней |
| `scripts/build_openapi.py`, `check_api_paths.py`, `check_openapi_dictionaries.py` | новые | RM-B-003, B-AR-10 (в) | ARCH (`scripts/`) | — | |
| `scripts/check_api_permissions.py`, `gen_rbac_seed.py` | новые | RM-B-008, B-AR-10 (а) | ARCH | — | |
| `scripts/check_onec_paths.py` | новый | RM-B-004 | ARCH | — | |
| `scripts/check_tables.sql`, `check_ddl_behavior.sql` | новые | RM-B-005, B-AR-10 (б) | ARCH | — | 60 негативных сценариев и 6 инвариантов DDL |
| `scripts/gen_tokens_dart.py`, `check_contrast.py` | новые | RM-B-006 | ARCH | — | `check_contrast.py` реализует проверку `contrast.py` (R4 прил. A) |
| `scripts/build_arb.py`, `check_arb_keys.py` | новые | RM-B-007 | ARCH | — | |
| `scripts/check_enums.py`, `gen_enums.py`, `check_enum_triangle.py` | новые | RM-B-009, B-AR-10 (г) | ARCH | — | |
| `tools/pg/run-sql.mjs`, `package.json`, `package-lock.json`, `README.md`, `NOTES.md`, `test/*.sql` | новые | RM-B-005, RM-B-008 (средство проверки) | ARCH (`tools/`) | — | одноразовый PostgreSQL 17.10 из npm `embedded-postgres@17.10.0-beta.17`, без Docker |
| `docs/reviews/B_architecture_review.md` | новый | RM-B-010 | QA | — | B-AR-01…23, правила слоёв для lint (§5) |
| `infra/README.md`, `infra/NOTES.md` | новые | RM-B-011 (и заметки RM-B-012, ADR-083) | OPS | — | целевая схема сценария A |
| `CONTRIBUTING.md` | новый | RM-B-012 | ARCH | — | SemVer, процедура изменения, владельцы, `contracts-lint` |
| `docs/templates/stage_report.md`, `docs/templates/adr.md` | новые | RM-B-012 | ARCH | — | |
| `docs/repo_layout.md` | новый | RM-B-012 / RM-C-001 | ARCH | — | целевое дерево монорепозитория |
| `docs/stages/B_checks.log` | новый | RM-B-013 (лог) | QA / ARCH | — | первый прогон 20:26, повторный после исправлений B-AR 21:01 |
| `docs/stages/B_architecture_report.md` | новый | RM-B-013 | ARCH | — | этот отчёт; свежий прогон 21:04 — §5.2 |

---

## 2. Выполненные проверки

Где выполнено: локально, Windows 11 Pro, `D:/optomstroy`, Python 3.13.6 (`python -I -X utf8`), Node v24.11.1, PostgreSQL 17.10 из `tools/pg`. CI нет (B-KI-03).
Свежий прогон: 2026-10-21 21:04. Его запустил автор отчёта через временный скрипт-обвязку в scratchpad, вне репозитория. Сводка и выдержки вывода — §5.2.
Предыдущие прогоны — `docs/stages/B_checks.log`: сводка первого прогона — строки 6–26, сводка повторного прогона после исправлений — строки 873–901, предупреждения — строки 903–926. В столбце «Лог» указана строка команды повторного прогона.
Генераторы писали во временный каталог scratchpad. Файлы репозитория прогон не изменил: `build_openapi.py` и `build_arb.py` запускались только с `--check`.

| № | Задача / критерий | Команда | Результат (свежий прогон 21:04) | Где выполнено | Лог |
|---|---|---|---|---|---|
| 1 | RM-B-003 (детерминизм сборки) | `python scripts/build_openapi.py --check` | код 0; `OK … актуален; sha256=3ac07559…`; 7 частей, путей 119, операций 141 | локально | `B_checks.log` стр. 936; §5.2 |
| 2 | AC-RM-B-003 п. 1 | `npx --yes @redocly/cli@2 lint contracts/openapi/pos-api.v1.yaml` | код 0; «valid», **0 ошибок, 10 предупреждений** (`info-license` ×1, `no-unused-components` ×9) | локально | стр. 944 |
| 3 | AC-RM-B-003 п. 2 | `python scripts/check_api_paths.py -v` | код 0; обязательных операций/путей 236, исключено как R2/неканоническое 4, запрещённых шаблонов 18; `OK: все обязательные пути и методы есть; запрещённых и лишних операций нет` | локально | стр. 1107 |
| 4 | AC-RM-B-008 п. 1 | `python scripts/check_api_permissions.py --require-operations` | код 0; операций 141; `ИТОГ: ошибок 0, предупреждений 9` (условия на уровне объекта 11 §4.3.1, B-AR-18) | локально | стр. 1123 |
| 5 | B-AR-10 (в) — словари OpenAPI | `python scripts/check_openapi_dictionaries.py` | код 0; `ИТОГ: ошибок нет`. ProblemCode = 08 §2.4 (50), PermissionCode = 11 §4.3 (77), 50 сверок enum-схем с 07 §6.1/§6.1.1 — `OK`, негативные примеры B-AR-02/05/06 отвергаются | локально | стр. 1144 |
| 6 | B-AR-10 (г) — треугольник enum | `python scripts/check_enum_triangle.py -v` | код 0; `ИТОГ: OK — ошибок 0, информационных 11` (45 типов DDL = `enums.json`; 38 выставлено в API, 7 внутренних) | локально | стр. 1242 |
| 7 | AC-RM-B-004 п. 1 | `npx --yes @redocly/cli@2 lint contracts/onec/onec-http-service.v1.yaml` | код 0; «valid», **0 ошибок, 1 предупреждение** (`info-license-strict`) | локально | стр. 1378 |
| 8 | AC-RM-B-004 пп. 2–4 | `python scripts/check_onec_paths.py` | код 0; `ИТОГ: OK — ошибок: 0, информационных замечаний: 7`. 21 операция = 05 §6.3 (0 лишних, 0 недостающих); 58 фикстур валидны в строгом режиме (покрыто 19 из 19 JSON-ответов 2xx); 33 коллекции allow-list: подтверждено `$metadata` — **0**, `[ТИПОВО]`/`[НЕ ПОДТВЕРЖДЕНО]` с fallback — 33; 18 §4.0 = 05 §6.3 | локально | стр. 1406 |
| 9 | B-AR-10 (а) — seed из матрицы | `python scripts/gen_rbac_seed.py --check` | код 0; `0002_rbac_seed.sql совпадает с генерацией из permissions.yaml (42832 байт)` | локально | стр. 1438 |
| 10 | AC-RM-B-005 пп. 1–2, AC-RM-B-008 п. 2 (dev/test) | `node tools/pg/run-sql.mjs --set app.env=test --repeat-strict pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_tables.sql` | код 0; PostgreSQL 17.10; `0001_init.sql: 374 команд — OK`, `0002_rbac_seed.sql: 4 команд — OK`; повтор — `0 изменений`, строк DML 0; `64 из 64 таблиц, лишних нет`; `45 из 45 enum-типов 07 §6.1` | локально (`tools/pg`) | стр. 1445 |
| 11 | AC-RM-B-005 пп. 1–2 (prod, B-AR-09) | `node tools/pg/run-sql.mjs pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_tables.sql` | код 0; `63 из 63 таблиц, лишних нет (prod-схема, dev_outbox нет)`; 45 из 45 enum-типов | локально (`tools/pg`) | стр. 2188 |
| 12 | B-AR-10 (б) — поведение DDL | `node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_ddl_behavior.sql` | код 0; `check_ddl_behavior: OK — негативных сценариев 60, позитивных инвариантов 6` | локально (`tools/pg`) | стр. 2263 |
| 13 | AC-RM-B-006 п. 1 | `python -I -X utf8 -c "<Draft202012Validator: tokens.json по tokens.schema.json>"` (команда — `contracts/design-tokens/NOTES.md` стр. 44) | код 0; ошибок валидации 0 | локально | стр. 3231 |
| 14 | AC-RM-B-006 п. 2 (прогон A) | `python scripts/gen_tokens_dart.py <tmp>/tokens_a` | код 0; `generated 8 files (palette B, sha256 7ecbb28dd87e)` | локально | стр. 3238 |
| 15 | AC-RM-B-006 п. 2 (прогон B) | `python scripts/gen_tokens_dart.py <tmp>/tokens_b` | код 0; тот же sha256 `7ecbb28dd87e` | локально | стр. 3253 |
| 16 | AC-RM-B-006 п. 2 (сравнение) | побайтовое сравнение `tokens_a` и `tokens_b` | код 0; файлов 8, различий 0 | локально | стр. 3268 |
| 17 | AC-RM-B-006 п. 3 | `python scripts/check_contrast.py` | код 0; пар 83 (PASS 61, FORBIDDEN 12, DECOR 5, REFERENCE 3, EXCEPTION 2); `violations among allowed pairs: 0`; `mismatches with documented ratios: 0`; `RESULT: OK`. «Белый на `primary #FF8700`» (2.41:1) — в классе FORBIDDEN, то есть запрещён правилом, а не разрешён | локально | стр. 3289 |
| 18 | RM-B-007 (валидный JSON) | `python -I -X utf8 -c "json.load(app_{ru,ky,en}.arb)"` | код 0; `3 ARB: valid JSON` | локально | — (только свежий прогон) |
| 19 | RM-B-007 (сборка из 02 §7 / 03) | `python scripts/build_arb.py --check` | код 0; ключей 1939 (02 §7: 1905, 03: 28, 07 §5.4: 6); `файлы на диске совпадают со сборкой` | локально | стр. 3388 |
| 20 | AC-RM-B-007 | `python scripts/check_arb_keys.py` | код 0; `итог: ошибок 0`; `ru`/`ky`/`en` — по 1939 ключей, 366 с плейсхолдерами; покрытие (инфо): `error_*` 27 из 49, 22 `status_*` нет | локально | стр. 3409 |
| 21 | B-AR-11 (ожидаемый отказ) | `python scripts/check_arb_keys.py --strict-coverage` | **код 1, ожидался 1**; `итог: ошибок 2`: нет 22 `status_*` (03 §9.39), `error_*` 27 из 49 (03 §16.5). Замечание открыто | локально | стр. 3427 |
| 22 | AC-RM-B-009 п. 1 | `python -I -X utf8 -c "<jsonschema: enums.json по enums.schema.json>"` | код 0; `errors 0` | локально | — (только свежий прогон; в логе — в составе `check_enums.py`) |
| 23 | AC-RM-B-009 п. 3 | `python scripts/check_enums.py -v` | код 0; `проверок пройдено 248, расхождений 0` | локально | стр. 3447 |
| 24 | AC-RM-B-009 п. 2 (прогон A) | `python scripts/gen_enums.py <tmp>/enums_a` | код 0; 78 перечней → `enums.ts`, `enums.dart` | локально | стр. 3702 |
| 25 | AC-RM-B-009 п. 2 (прогон B) | `python scripts/gen_enums.py <tmp>/enums_b` | код 0 | локально | стр. 3709 |
| 26 | AC-RM-B-009 п. 2 (сравнение) | побайтовое сравнение `enums_a` и `enums_b` | код 0; файлов 2, различий 0 | локально | стр. 3716 |
| 27 | AC-RM-B-012 (таблица владельцев = 13 §5.2) | `python -I -X utf8 -c "<строки таблицы 13 §5.2 == строки таблицы CONTRIBUTING.md §5>"` | код 0; `16 16 True` | локально | — (только этот отчёт) |
| 28 | AC-RM-B-002 п. 3 (перечень read-only в 08 и 11) | `grep -c "ADR-083" docs/specification/08_API_SPECIFICATION.md docs/specification/11_SECURITY_PRIVACY.md` | `0` и `0`: **критерий не выполнен** | локально | — (только этот отчёт) |

Негативные самотесты новых скриптов в этом прогоне не повторялись. Результат взят из `B_checks.log`, повторный прогон 21:01:

| № | Проверка | Результат | Лог |
|---|---|---|---|
| 29 | `gen_rbac_seed.py --check` на копии `permissions.yaml` без одного кода | код 1, ожидался 1 (`DRIFT … 15 строк diff`) | стр. 3724 |
| 30 | `check_enum_triangle.py` на копии DDL без значения `cart_status.cleared` | код 1, ожидался 1 (`FAIL [1] cart_status …`) | стр. 3747 |

**Не выполненные проверки.** Команда не запускалась или для неё нет условий. Такая проверка не считается пройденной:

| Задача / критерий | Команда | Причина | Когда и кем будет выполнена |
|---|---|---|---|
| AC-RM-B-003 п. 3 | `openapi-generator-cli generate -g dart-dio` на пустом проекте | На машине Java 1.8.0_251; openapi-generator 7 требует Java 11+. Docker тоже нет | Шаг 4 `contracts-lint` на Linux-раннере с Java 11+ (`CONTRIBUTING.md` §6) — RM-C-011 (OPS); генерация клиента `packages/pos_api_client` — RM-C-004 (FE). До этого риск B-AR-14 (`anyOf` без дискриминатора) не проверен генератором |
| AC-RM-B-005 п. 1 буквально | `psql -v ON_ERROR_STOP=1 -f pos-api/migrations/0001_init.sql` на `postgres:17` | Нет PostgreSQL, `psql` и Docker. Использован раннер `tools/pg` (embedded-postgres 17.10 под Windows), который применяет файлы с поведением `ON_ERROR_STOP` (строки 10–12) | Контейнер `migrate` и сервис `postgres:17` в CI — RM-C-006, RM-C-011, RM-C-012 |
| AC-RM-B-008 п. 3 | e2e-тест матрицы прав из `permissions.yaml` | Нужен код backend | Этап D (13 RM-B-008) |
| RM-B-006, RM-B-007, RM-B-009 — проверки на стороне приложения | `tokens_test.dart`, `flutter gen-l10n`, импорт `enums.ts`/`enums.dart` в unit-тестах | Нужны `pos-app/` и `pos-api/src/` (этап C) | RM-C-002, RM-C-003, RM-C-004, RM-C-005 |
| RM-B-010 п. 3 — правила слоёв на коде | `dart run custom_lint`, `madge --circular` | Кода ещё нет; правила описаны в ревью §5 | RM-C-002, RM-C-005 |
| AC-RM-B-002 п. 1 | `git diff` ТЗ «только согласованные изменения» | Этим отчётом не проверялось; основание изменений — `B_changes.md` §2 | ARCH при получении подписи заказчика |
| Проверки в CI | весь `contracts-lint` | CI нет: платформа не выбрана (Q-131, O-23) | RM-C-011 |

---

## 3. Известные проблемы

Серьёзность указана по 13 §6.2. Блокеров и открытых критичных проблем нет.

| ID | Описание | Серьёзность | Обход | План (задача, срок) |
|---|---|---|---|---|
| B-KI-01 | Генерация клиента `dart-dio` не выполнялась: Java 8, openapi-generator 7 не запускается (AC-RM-B-003 п. 3). Совместимость контракта с генератором, в том числе обёртка `anyOf` в `CatalogSyncResponse` (B-AR-14, `x-entity-schema`), не подтверждена | существенно | Контракт проходит Redocly lint (0 ошибок) и проверку словарей. Других локальных средств генерации нет | RM-C-011 (шаг 4 `contracts-lint`, Java 11+) и RM-C-004; до G-C |
| B-KI-02 | Нет Docker и PostgreSQL: DDL проверен раннером `tools/pg` (embedded-postgres 17.10, Windows), а не `psql` на `postgres:17` (Linux) | существенно | Строки 10–12: миграции, повтор без изменений, состав таблиц, 60+6 поведенческих сценариев | RM-C-006, RM-C-012 (контейнер `migrate`, `postgres:17`) |
| B-KI-03 | Нет CI: все проверки выполнены на одной машине, независимого воспроизведения в CI нет | существенно | Команды детерминированы и задокументированы (§2, `CONTRIBUTING.md` §6) | RM-C-011 после ответа Q-131 (O-23) |
| B-KI-04 | `docs/erd/README.md` (сгенерирован 20:17) устарел относительно `0001_init.sql` (изменён 20:57 по B-AR-01/03/05). В ERD PK `user_roles` = `user_id, role_id` и PK `idempotency_keys` = `key, user_id, route`; в DDL — `user_roles.id` и `PRIMARY KEY (key, subject_key, route)`. `subject_key` и `onec_key` в ERD не упоминаются | незначительно | Источник истины — DDL (строки 10–12) | Перегенерировать ERD из каталога PostgreSQL — BE (data), до RM-C-006 |
| B-KI-05 | В `CONTRIBUTING.md` §6 (`contracts-lint`) нет шести проверок, добавленных после ревью: `build_openapi.py --check`, `build_arb.py --check`, `gen_rbac_seed.py --check`, `check_openapi_dictionaries.py`, `check_enum_triangle.py`, `check_ddl_behavior.sql`. Шаг 9 требует «64 таблицы», хотя prod-схема без `app.env` даёт 63 (B-AR-09). Проверено: `grep` по шести именам в `CONTRIBUTING.md` даёт 0 совпадений | незначительно | Команды есть в `B_checks.log` и в §2 | ARCH: дополнить §6 до RM-C-011 |
| B-KI-06 | B-AR-11: у 22 ключей `error_*` и 22 ключей `status_*` нет текстов у владельца 03 (§16.5, §9.39), поэтому `--strict-coverage` даёт код 1. Тексты не придумывались | существенно | Обычная проверка ARB проходит (строка 20) | Владелец 03 (DS) — до RM-C-002. После этого `--strict-coverage` включается в CI |
| B-KI-07 | Замечания архитектурной проверки, не закрытые правкой ТЗ. **Частично:** B-AR-04 (повтор после шага, выполняемого после COMMIT: текст 08 §2.7, тест 12), B-AR-07 (единый владелец проверок оформления, ребро `cart → sync`, подпись `previewToken`). **Передано владельцам документов:** B-AR-08 (триггер цепочки аудита и изоляция, 06/07), B-AR-12 (очереди pg-boss, 06), B-AR-17, -21, -22 (06/07), B-AR-18 (13). Тексты 06, 07, 08, 13 не правились: путь вне назначенных | существенно (major) | Предложения записаны в `contracts/openapi/NOTES.md` §8.2 и `pos-api/migrations/NOTES.md` §10 | Сроки — колонка «Срок» ревью: B-AR-07 до RM-F-001, B-AR-08 — нагрузочный тест этапа F, B-AR-12 до RM-C-005 |
| B-KI-08 | Контракт 1С — черновик v1.0.0: 28 мест `x-status: proposed`, 9 расхождений 05↔18 (`contracts/onec/NOTES.md` §4); 0 из 33 коллекций OData подтверждены `$metadata`. Риск: специалист 1С реализует по 18 раньше, чем будет исправлен 05 (B-AR-23) | существенно | Маппинг вынесен в конфигурацию `odata-allowlist.yaml`; синтетические фикстуры валидируются (строка 8) | RM-B-014 (журнал версий, ONEC-074: сначала 05 §6, затем 18); O-04 |
| B-KI-09 | RM-B-002 не закрыта. Лист `B_changes.md` не подписан. ADR-083 в статусе «Предложено», перечень не внесён в 08 §2.4 и 11 SEC-119 (строка 28). Механизм ограничения мутаций на шаге 1 включения продаж (13 §8.4) не определён | существенно | Не является условием G-B2 по 13 §3.2 | Подпись — заказчик; правка 08 и 11 — владельцы (BE, SEC) после подтверждения ADR-083; до пилота (этап I) |
| B-KI-10 | B-AR-15: в `tokens.json` есть `alternatives.A` (A+), хотя RM-B-006 требует «в `tokens.json` не вносится». Генератор по умолчанию A не выводит | незначительно | `meta.palette = "B"`; генерация — только палитра B (строка 14) | Решение на G-B2: принять отклонение или удалить A (варианты — `contracts/design-tokens/NOTES.md` п. 1); владелец DS |
| B-KI-11 | Предупреждения проверок, не ошибки. Redocly: 10 в `pos-api` (`info-license`; 9 `no-unused-components`, в том числе эталонные `CustomerView*` — B-AR-17) и 1 в контракте 1С (`info-license-strict`). Скрипт прав: 9 предупреждений `[A]` об условиях на уровне объекта. Имя расширения `x-permissions` расходится с текстом AC «`x-permission`» (B-AR-18) | незначительно | Скрипт читает оба имени | B-AR-17 — RM-G; формулировка AC — владелец 13 |
| B-KI-12 | Независимая проверка ограничена. Ревью RM-B-010 выполнил QA-агент, внешний рецензент не привлекался (Q-197). Ревью сверило вручную 34 операции из 141, поля 18 таблиц из 64 и 17 ключей ARB из 1939. Независимого проверяющего у этого отчёта нет | существенно | Сплошные машинные проверки (§2) | Q-197 — заказчик; независимая проверка отчёта — по 13 §6.1 п. 11 |
| B-KI-13 | `ky`/`en` ARB — каркас (копия `ru` с пометкой «TODO перевод», D-38, `contracts/l10n/NOTES.md` §3.6) | незначительно | Набор ключей и плейсхолдеров совпадает с `ru` (строка 20) | Переводы — по D-38, не этап B |
| B-KI-14 | В `15_DECISION_LOG.md` после добавления ADR-082/083 не обновлены сводные счётчики §7, раздел 9.2 и приложение Б (`infra/NOTES.md` п. 14) | незначительно | Записи ADR есть в индексе §7 | ARCH, следующая версия 15 |

**Действующие допущения.** Заказчик ответил только на Q-001 и Q-006 (полностью) и на Q-011 и Q-014 (частично), ядро §24. Форма 14 §7 и письменное принятие допущений не поступали (`B_approval.md`). Поэтому по 20 блокирующим вопросам (14 §2, 13 §9 O-02) работа идёт на рекомендуемых допущениях 14:

| Q-NNN | Принятое допущение (14 §2) | Какие задачи от него зависят | Последствие при другом ответе |
|---|---|---|---|
| Q-010 | Все имена объектов 1С — `[ТИПОВО]` (гипотеза УТ 11.5); OData только для чтения — запасной путь; fallback DataVersion + хэш + ночная сверка | RM-B-004 (`odata-allowlist.yaml`, фикстуры), RM-E-001, RM-E-* | Меняются конфигурация allow-list и фикстуры. Может измениться состав документов заказов, оплат и возвратов, а также проекция статусов D-20 |
| Q-011 (частично) | API 1С делает специалист 1С по документу 18; срок, тестовая копия и сопровождение неизвестны | RM-B-014, RM-E-016, RM-E-011, RM-F-010, RM-I-002 | Без API — фаза 0 и ручное оформление заказов в 1С (13 §3.12), `QR_PROVIDER=none` |
| Q-014 (частично) | QR через 1С (`QR_PROVIDER=onec`); запасной вариант — статический QR и ручное подтверждение; прямой API банка — R2 | RM-F-016, методы `/pos/v1/payments/qr*` контракта 1С | Если 1С не умеет QR — `QR_PROVIDER=none`; автоматическое подтверждение оплаты недоступно |
| Q-012 | Проекция статусов D-20/D-21; оплата допустима в статусах `submitting`…`awaiting_payment`; платёжные документы записываются непроведёнными | Методы `/orders`, `/payments`, `/returns` контракта 1С; RM-F-002…004 | Правка 05 §6, затем 18 и контракта 1С по §5.3; переделка outbox и автоматов |
| Q-031 | Связь по LAN; `/integrations/onec/*` выключен (`404`) | ADR-082, `infra/README.md`, RM-D-013 и RM-E-013 не выполняются | WireGuard (схема compose та же) или C-2: +10 у.е. (13 §3.12), включение входящих маршрутов |
| Q-030 | Сценарий A (Linux + Docker Compose); ничего не устанавливается без разрешения | ADR-082, RM-C-012, RM-I-001 | Новая ADR по дереву 16 §3.5 до RM-I-001; при непригодном сервере — B-3 или C |
| Q-101 | B-3 при физическом сервере, иначе B-2 для теста и C для прода | RM-I-001 | Меняется размещение (этап I), но не контракты |
| Q-102 | Rootless Docker на выделенном хосте | RM-I-* | Меняются процедуры развёртывания |
| Q-002 | Только телефон + OTP + биометрия/PIN (D-09) | RM-D-*, SCR-01, модель данных (таблиц паролей и карт нет) | Новые таблицы, экраны и угрозы; расширение контракта (expand) |
| Q-005 | Роли D-15; одна активная роль (`roles` `maxItems: 1`, B-AR-02); `owner`/`admin` без кассы | `permissions.yaml`, `0002_rbac_seed.sql`, RM-D-010, RM-G-* | Правка `permissions.yaml` и перегенерация seed (`gen_rbac_seed.py`); при нескольких ролях — снятие `maxItems` (expand) и уникального индекса активной роли |
| Q-008 | Android (minSdk 24) и Windows 10/11 x64; iOS — без проверки сборки | RM-C-013, RM-H-007, тест-матрица | Нужен Mac-раннер (Q-131); меняется матрица устройств |
| Q-015 | Лимиты скидок: `seller` 5 %, `cashier` 5 %, `senior_seller` 10 %, `admin` 15 %, `owner` 0 % | RM-G-003 | Меняются значения настроек, а не контракты |
| Q-017 | Долг — по соглашению 1С, fail-closed; продавец видит только признак долга | RM-G-002 | Меняются правила этапа G |
| Q-018 | Заявки на возврат в R1 включены (`returns_enabled=true`), передача в 1С выключена | RM-G-005 | При «только в 1С» — `returns_enabled=false` без кода |
| Q-029 | Отправитель `Optomstroy`; до получения аккаунта — только `FakeSmsGateway` | RM-D-002, RM-H-001 | Без аккаунта реальная доставка OTP невозможна (блок G-H) |
| Q-035 | Плоский нейтральный персонаж, Rive `MascotAuth` | RM-D-007 | Меняется ассет, а не компонент |
| Q-040 | Синтетика: 50 000 SKU до получения образцов | Фикстуры `contracts/onec/fixtures`, RM-E-* | Заменяются фикстуры, возможны правки маппинга |
| Q-131 | GitHub + GitHub Actions; раннеры Linux (Docker) и Windows с этапа C | RM-C-011 (вместе с B-KI-01…03) | Меняется конфигурация CI |
| Q-190 | Принят предложенный календарь (00 §21.1, 18 относительных спринтов) | Сроки ворот | Меняются сроки, но не содержание |
| Q-191 | Принят предложенный состав: 8 ролей + ARCH | Параллельность дорожек | При меньшем составе дорожки идут последовательно, срок растёт |

Не блокируют G-B2, но открыты: Q-303 («супер-админ» = `admin`, допущение; до G-D, O-27); Q-006 — векторный логотип (O-22); Q-302 — ручные чертежи экранов (O-26, желательно); Q-197 — внешний рецензент.

---

## 4. Условия перехода дальше

- **Статус ворот G-B1:** закрыты (`B_approval.md`; ядро §22.13 п. 5 — фраза является единственным условием).
- **Статус ворот G-B2: жёлтый (предложение автора; окончательно — ARCH при приёмке отчёта).** Обоснование по 13 §6.2. Открытых блокеров и критичных проблем нет. Остаются существенные проблемы с планом (§3). RM-A-003 не закрыта: 20 блокирующих вопросов без ответа и без письменного принятия допущений. Это прямо предусмотрено 13 §3.2 как основание для статуса «жёлтый». Отдельно: AC-RM-B-003 п. 3 (`dart-dio`) не выполнен. По тексту 13 §3.2 G-B2 требует, чтобы проверочные команды RM-B-003 были выполнены. Перенос этой проверки на RM-C-011/RM-C-004 — допущение этого отчёта, его должен принять ARCH. Без этого решения условие ворот по RM-B-003 формально не выполнено. Жёлтый статус допускает старт задач Backend/ONEC следующего этапа (13 §6.2, §4.3 п. 2).

| Условие ворот (13 §3.2, G-B2) | Выполнено? | Доказательство (раздел 2, № строки) |
|---|---|---|
| RM-A-003 закрыта: по каждому из 22 блокирующих вопросов есть ответ или письменно принятое допущение | **нет**: закрыты Q-001, Q-006; частично Q-011, Q-014; 20 без ответа | §3 «Действующие допущения»; `B_approval.md`, `B_changes.md` §3 |
| RM-B-003 закрыта, проверки выполнены | **частично**: п. 1, п. 2 — да; п. 3 — нет (Java 8) | строки 1–3; §2 «Не выполненные» |
| RM-B-005 закрыта, проверки выполнены | да (средство — `tools/pg` вместо `psql`/`postgres:17`) | строки 10–12 |
| RM-B-006 закрыта, проверки выполнены | да; решение по B-AR-15 — на G-B2 | строки 13–17 |
| RM-B-008 закрыта, проверки этапа B выполнены | да (п. 1–2; п. 3 — этап D по 13) | строки 4, 9, 10 |
| RM-B-009 закрыта, проверки выполнены | да | строки 6, 22–26 |
| RM-B-012 закрыта | да (состав `contracts-lint` нужно дополнить — B-KI-05) | строка 27 |
| Логи проверочных команд приложены к RM-B-013 | да | `docs/stages/B_checks.log`; §5.2 |
| RM-B-010 без открытых блокеров | да: 0 блокеров, оба критичных исправлены | строки 5, 12; ревью §0, §7 |
| RM-B-013 сдан | да (этот файл); независимой проверки отчёта нет (B-KI-12) | — |
| RM-B-004 допускается в статусе «OData-часть готова, HS-часть `[ТИПОВО]`» | да: контракт и allow-list готовы, все имена `[ТИПОВО]` | строки 7–8 |
| Проверки G-B2 не требуют артефактов этапа C | да: использованы только `contracts/`, `scripts/`, `pos-api/migrations/`, `tools/pg` | строки 1–28 |
| RM-B-014 — не условие G-B2 | — | 13 §3.2 |

**Последствия перехода «на жёлтый»:**

- Интеграция с 1С (этапы E–F) строится на `[ТИПОВО]`-именах и синтетических фикстурах. Ответ специалиста 1С может изменить allow-list, фикстуры и, через процедуру §5.3, контракт 1С (Q-010, Q-012, Q-040).
- QR-оплата: пока специалист 1С не ответит на QR-1…QR-9, действует `QR_PROVIDER=none` (Q-014).
- Матрица прав и seed построены на ролях D-15 и одной активной роли (Q-005). Другой ответ потребует перегенерировать seed и расширить контракт (expand).
- Развёртывание: сценарий A и LAN (ADR-082 принят условно). Его пересмотр обязателен до RM-I-001 (Q-030, Q-031, Q-101, Q-102).
- CI (RM-C-011) нельзя настроить без решения Q-131. До этого B-KI-01…03 остаются открытыми: генерация `dart-dio`, `postgres:17`, независимое воспроизведение.

- **Что требуется от заказчика** (13 §9):

| Действие / вопрос | Для какой задачи | Срок (ворота) |
|---|---|---|
| O-02: ответить на 20 блокирующих вопросов (14 §2) или поставить общую отметку формы 14 §7 «Принимаю рекомендуемые допущения» | RM-A-003; перевод G-B2 из «жёлтого» в «зелёный» | до G-B2 (без ответа — «жёлтый») |
| Подписать лист изменений `docs/stages/B_changes.md` (разделы 1–4) | RM-B-002 п. 2 | как можно раньше; до пилота |
| Ознакомиться с ADR-083 (охват `APP_READ_ONLY`, `B_changes.md` §5); возражения — до пилота | RM-B-002 п. 3 | до этапа I |
| O-04: передать специалисту 1С документ `18_ONEC_API_REQUEST.md`; получить сведения 18 §2, ответы QR-1…QR-9, образцы данных, срок выдачи API (Q-010, Q-011, Q-014, Q-040) | RM-B-004, RM-B-014, RM-E-001, RM-F-016 | ответы — до G-B2; передачу документа не откладывать |
| O-03: аудит сервера по 16 §2 (Q-030, Q-101, Q-102) и схема сети (Q-031, Q-107) | ADR-082 (пересмотр), RM-I-001 | до G-B2 (допустимо до I-0 с риском) |
| O-23: решение о CI-платформе и хранилище кода (Q-131) | RM-C-011; закрытие B-KI-01…03 | до G-B2 |
| O-24: утвердить календарь и состав исполнителей (Q-190, Q-191) | планирование этапов C–I | до G-B2 |
| O-22: векторный логотип (открытая часть Q-006) и стиль персонажа (Q-035) | RM-D-007 | до G-B2 (не блокирует RM-B-006) |
| Q-303 (O-27): кто такой «супер-админ» | RM-D-010, RM-D-017 | до G-D (не блокирует) |
| Q-197: привлекать ли внешнего рецензента | RM-B-010 и независимые проверки этапов | по решению заказчика |
| O-26 / Q-302: ручные чертежи экранов, если они есть | сверка ТЗ с чертежами | желательно до G-B2 |

- **Решения, принятые на этапе** (ADR в `docs/specification/15_DECISION_LOG.md`):
  - ADR-078…ADR-081: палитра B, режим клиента в R1 и приглашение сотрудников, API 1С от специалиста по документу 18, QR через 1С. Приняты по ответам заказчика (ядро §24), перечень — `B_changes.md` §1.
  - ADR-082: сценарий развёртывания A по умолчанию, связь с 1С по LAN, пересмотр до этапа I. **Принято условно**, ждёт Q-030, Q-031, Q-101, Q-107.
  - ADR-083: охват `APP_READ_ONLY`. **Предложено.** В 08 и 11 не внесено.

---

## 5. Приложения

### 5.1. Документы и логи

- Отчёт независимой архитектурной проверки: `docs/reviews/B_architecture_review.md` (RM-B-010). Проверяющий — роль QA, 2026-10-21. Вывод: «Блокеров нет», 2 критичных замечания исправлены. Статусы исправлений — §7 ревью.
- Лог проверок этапа B: `docs/stages/B_checks.log`. Первый прогон — 2026-10-21 20:26, повторный после исправлений B-AR — 21:01. Все команды завершились с ожидаемым кодом.
- Свежий прогон для этого отчёта — 2026-10-21 21:04, выдержки в §5.2. Полный вывод (2824 строки) сохранён только во временном каталоге автора, в репозиторий не добавлялся. Выводы его команд по существу совпадают с повторным прогоном в `B_checks.log`.
- Решения исполнителей по неоднозначностям ТЗ: `contracts/openapi/NOTES.md`, `contracts/onec/NOTES.md`, `contracts/rbac/NOTES.md`, `contracts/design-tokens/NOTES.md`, `contracts/l10n/NOTES.md`, `contracts/NOTES_enums.md`, `pos-api/migrations/NOTES.md`, `infra/NOTES.md`, `tools/pg/NOTES.md`.
- Скриншоты, видео и бенчмарки не применимы: на этапе B нет UI и кода.

### 5.2. Свежий прогон 2026-10-21 21:04 — сводка и выдержки вывода

Временный каталог генераторов заменён на `<scratchpad>`. Секретов, OTP, токенов и ПДн в выводе нет.

```text
# fresh run 2026-10-21 21:04; cwd D:\optomstroy; python 3.13.6
[OK ] exit=0 (expected 0)   2.1s  python -I -X utf8 scripts/build_openapi.py --check
[OK ] exit=0 (expected 0)   5.9s  npx --yes @redocly/cli@2 lint contracts/openapi/pos-api.v1.yaml
[OK ] exit=0 (expected 0)   0.9s  python -I -X utf8 scripts/check_api_paths.py -v
[OK ] exit=0 (expected 0)   0.9s  python -I -X utf8 scripts/check_api_permissions.py --require-operations
[OK ] exit=0 (expected 0)   1.3s  python -I -X utf8 scripts/check_openapi_dictionaries.py
[OK ] exit=0 (expected 0)   0.9s  python -I -X utf8 scripts/check_enum_triangle.py -v
[OK ] exit=0 (expected 0)   4.0s  npx --yes @redocly/cli@2 lint contracts/onec/onec-http-service.v1.yaml
[OK ] exit=0 (expected 0)   8.0s  python -I -X utf8 scripts/check_onec_paths.py
[OK ] exit=0 (expected 0)   0.2s  python -I -X utf8 scripts/gen_rbac_seed.py --check
[OK ] exit=0 (expected 0)  10.0s  node tools/pg/run-sql.mjs --set app.env=test --repeat-strict pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_tables.sql
[OK ] exit=0 (expected 0)   8.9s  node tools/pg/run-sql.mjs pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_tables.sql
[OK ] exit=0 (expected 0)   9.4s  node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql --check scripts/check_ddl_behavior.sql
[OK ] exit=0 (expected 0)   0.5s  python -I -X utf8 -c "<Draft202012Validator: tokens.json по tokens.schema.json>"
[OK ] exit=0 (expected 0)   0.3s  python -I -X utf8 scripts/gen_tokens_dart.py <scratchpad>\gen\tokens_a
[OK ] exit=0 (expected 0)   0.3s  python -I -X utf8 scripts/gen_tokens_dart.py <scratchpad>\gen\tokens_b
[OK ] exit=0 (expected 0)   0.1s  <byte compare tokens_a vs tokens_b>
[OK ] exit=0 (expected 0)   0.1s  python -I -X utf8 scripts/check_contrast.py
[OK ] exit=0 (expected 0)   0.1s  python -I -X utf8 -c "<json.load app_ru/ky/en.arb>"
[OK ] exit=0 (expected 0)   0.2s  python -I -X utf8 scripts/build_arb.py --check
[OK ] exit=0 (expected 0)   0.2s  python -I -X utf8 scripts/check_arb_keys.py
[OK ] exit=1 (expected 1)   0.2s  python -I -X utf8 scripts/check_arb_keys.py --strict-coverage
[OK ] exit=0 (expected 0)   0.3s  python -I -X utf8 -c "<jsonschema: enums.json по enums.schema.json>"
[OK ] exit=0 (expected 0)   0.7s  python -I -X utf8 scripts/check_enums.py -v
[OK ] exit=0 (expected 0)   0.1s  python -I -X utf8 scripts/gen_enums.py <scratchpad>\gen\enums_a
[OK ] exit=0 (expected 0)   0.1s  python -I -X utf8 scripts/gen_enums.py <scratchpad>\gen\enums_b
[OK ] exit=0 (expected 0)   0.1s  <byte compare enums_a vs enums_b>
RUNNER EXIT=0
```

Ключевые строки вывода (по порядку команд):

```text
$ build_openapi.py --check
INFO: части: 7 (...); путей: 119; операций: 141; компонентов: schemas=314, responses=17, parameters=36, headers=14, securitySchemes=4
OK: D:\optomstroy\contracts\openapi\pos-api.v1.yaml актуален; sha256=3ac07559ce2cb0c19caa596540e6a7a379e2c0d1c7a1381759a2bddfa0c8e3bb
$ redocly lint pos-api.v1.yaml
Woohoo! Your API description is valid. 🎉
You have 10 warnings.
$ check_api_paths.py -v
INFO: обязательных операций/путей: 236; исключено как R2/неканоническое: 4; запрещённых шаблонов: 18
OK: все обязательные пути и методы есть; запрещённых и лишних операций нет
$ check_api_permissions.py --require-operations
ИТОГ: ошибок 0, предупреждений 9
$ check_openapi_dictionaries.py
OK   ProblemCode = 08 §2.4 (50 кодов в таблице, 50 в enum)
OK   PermissionCode = 11 §4.3 (77 кодов)
OK   негатив: PUT /admin/users/{id}/roles — две роли отвергаются схемой (B-AR-02)
ИТОГ: ошибок нет
$ check_enum_triangle.py -v
ИТОГ: OK — ошибок 0, информационных 11
$ redocly lint onec-http-service.v1.yaml
Woohoo! Your API description is valid. 🎉
You have 1 warning.
$ check_onec_paths.py
  ok   0 лишних, 0 недостающих (21 операций, 20 путей)
  ok   58 файлов проверено; операций с JSON-ответом 2xx: 19, покрыто: 19
  ok   33 коллекций: подтверждено $metadata — 0, [ТИПОВО]/[НЕ ПОДТВЕРЖДЕНО] с fallback — 33; упомянутые в 05 §5: 27, все покрыты
  ok   набор операций 18 §4.0 совпадает с 05 §6.3 (21)
ИТОГ: OK — ошибок: 0, информационных замечаний: 7
$ gen_rbac_seed.py --check
OK: pos-api/migrations/0002_rbac_seed.sql совпадает с генерацией из contracts/rbac/permissions.yaml (42832 байт)
$ run-sql.mjs --set app.env=test --repeat-strict ... --check check_tables.sql
[pg] PostgreSQL 17.10 on x86_64-windows, compiled by msvc-19.44.35226, 64-bit
[apply] pos-api\migrations\0001_init.sql: 374 команд — OK (679 мс)
[apply] pos-api\migrations\0002_rbac_seed.sql: 4 команд — OK (118 мс)
[repeat] ИТОГ: 0 изменений (схема и данные совпадают); команд выполнено: 378, строк DML: 0
NOTICE:  check_tables: OK — 64 из 64 таблиц, лишних нет (dev/test-схема, dev_outbox есть)
NOTICE:  check_tables: OK — 45 из 45 enum-типов 07 §6.1
$ run-sql.mjs ... --check check_tables.sql   (prod, app.env не задан)
NOTICE:  check_tables: OK — 63 из 63 таблиц, лишних нет (prod-схема, dev_outbox нет)
NOTICE:  check_tables: OK — 45 из 45 enum-типов 07 §6.1
$ run-sql.mjs --set app.env=test ... --check check_ddl_behavior.sql
NOTICE:  check_ddl_behavior: OK — негативных сценариев 60, позитивных инвариантов 6
$ jsonschema tokens.json
0
$ gen_tokens_dart.py (A и B)
generated 8 files (palette B, sha256 7ecbb28dd87e)
files 8, differences 0
$ check_contrast.py
CP-029  PASS         6.83   4.5   6.83  text       onPrimary #1B1F2A on primary #FF8700
CP-032  FORBIDDEN    2.41   4.5   2.41  text       #FFFFFF on primary #FF8700
pairs: 83 (DECOR 5, EXCEPTION 2, FORBIDDEN 12, PASS 61, REFERENCE 3)
violations among allowed pairs: 0
mismatches with documented ratios: 0
RESULT: OK
$ build_arb.py --check
итог: ключей 1939 (текст 02 §7: 1905, текст 03: 28, названия ролей 07 §5.4: 6)
--check: файлы на диске совпадают со сборкой
$ check_arb_keys.py
app_ru.arb: ключей 1939, с плейсхолдерами 366   (ky, en — то же)
ПОКРЫТИЕ (инфо): error_*: 27 из 49 по 03 §16.5
итог: ошибок 0
$ check_arb_keys.py --strict-coverage
ОШИБКА: покрытие: нет строк status_* по 03 §9.39: status_outbox_pending, … status_cart_cleared   (22 ключа)
ОШИБКА: покрытие: error_*: 27 из 49 по 03 §16.5
итог: ошибок 2   → exit 1 (ожидаемо, B-AR-11)
$ jsonschema enums.json
errors 0
$ check_enums.py -v
check_enums: проверок пройдено 248, расхождений 0
$ gen_enums.py (A и B)
gen_enums: 78 перечней → enums.ts, enums.dart
files 2, differences 0
```

Дополнительные проверки этого отчёта:

```text
$ python -I -X utf8 -c "<строки таблицы 13 §5.2 == строки таблицы CONTRIBUTING.md §5>"
16 16 True          → exit 0
$ grep -c "ADR-083" docs/specification/08_API_SPECIFICATION.md docs/specification/11_SECURITY_PRIVACY.md
08_API_SPECIFICATION.md:0
11_SECURITY_PRIVACY.md:0
$ java -version
java version "1.8.0_251"   → openapi-generator 7 (Java 11+) не запускается; AC-RM-B-003 п. 3 не выполнен
```

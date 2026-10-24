# tools/pg — одноразовый PostgreSQL 17 без Docker

Раннер поднимает временный кластер PostgreSQL 17 из npm-пакета
[`embedded-postgres`](https://www.npmjs.com/package/embedded-postgres) (бинарники PostgreSQL ставятся
как dev-зависимость), применяет SQL-файлы с поведением `psql -v ON_ERROR_STOP=1 -f`, выполняет
файл проверок и удаляет кластер. Нужен для проверок этапа B и C на машине без Docker и без
установленного PostgreSQL (ядро R0 §0):

| Задача | Проверка в 13_IMPLEMENTATION_ROADMAP | Чем закрывается здесь |
|---|---|---|
| RM-B-005 | п. 1 — `0001_init.sql` применяется на пустом PostgreSQL 17 без ошибок; п. 2 — `scripts/check_tables.sql` | `node tools/pg/run-sql.mjs pos-api/migrations/0001_init.sql --check scripts/check_tables.sql` |
| RM-B-008 | п. 2 — `0002_rbac_seed.sql` после `0001_init.sql` без ошибок | `node tools/pg/run-sql.mjs pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql` |
| RM-C-006 | п. 4 — повторное применение миграций идемпотентно (0 изменений) | `node tools/pg/run-sql.mjs --repeat-strict pos-api/migrations/*.sql` |
| B-AR-10 (б) | поведенческие проверки DDL (негативные сценарии CHECK/UNIQUE/триггеров) | `node tools/pg/run-sql.mjs --set app.env=test pos-api/migrations/0001_init.sql pos-api/migrations/0002_rbac_seed.sql pos-api/db/migrations-dev/0001_dev_outbox.sql --check pos-api/test/sql/check_ddl_behavior.sql` (с RM-C-006: dev-таблица `dev_outbox` — из `pos-api/db/migrations-dev/`) |

Пути `pos-api/…` и `scripts/…` — выходы соответствующих задач; раннер их не создаёт.

## Установка

```sh
npm --prefix tools/pg ci        # или npm --prefix tools/pg install, если нет package-lock.json
```

Ставится `embedded-postgres@17.10.0-beta.17` (PostgreSQL 17.10) и бинарный пакет для текущей платформы
(`@embedded-postgres/windows-x64`, `linux-x64`, `darwin-arm64` …). В пакете есть `initdb`, `pg_ctl`,
`postgres` и расширения contrib, включая `pg_trgm`, `unaccent`, `pgcrypto`. Клиентов `psql` и
`pg_dump` в пакете нет — SQL выполняется через `node-postgres`, см. «Отличия от psql».

## Запуск

```sh
node tools/pg/run-sql.mjs [опции] file1.sql [file2.sql ...] [--check check.sql]
```

| Опция | Что делает |
|---|---|
| `--check <file>` | после применения (и повтора) выполнить файл проверок; результаты `SELECT` печатаются таблицей в стиле psql; ошибка — код 1. Можно указать несколько раз |
| `--repeat` | повторно применить те же файлы в том же порядке и напечатать итог: ошибка / 0 изменений / список изменений схемы и данных. Код выхода от итога не зависит |
| `--repeat-strict` | как `--repeat`, но ошибка или изменения при повторе дают код 1 (для RM-C-006 п. 4) |
| `--ext <list>` | до применения файлов создать расширения в `pos_test` (`CREATE EXTENSION IF NOT EXISTS`), через запятую; `all` = `pg_trgm,unaccent,pgcrypto`. По умолчанию расширения **не** создаются — их создают сами миграции |
| `--keep` | не удалять каталог кластера; сервер останавливается, печатается команда `pg_ctl … start`, строка подключения с одноразовым паролем пишется в `<каталог>/run-sql.conn` |
| `--locale <name>` | локаль кластера (по умолчанию `en-US` на Windows, `en_US.utf8`/`C.UTF-8` на Linux и macOS) |
| `--set <prefix.name=value>` | до применения файлов задать пользовательский параметр сеанса (`set_config(…, false)`; аналог `PGOPTIONS='-c prefix.name=value'`), можно несколько раз. Нужен миграциям, которые читают `app.*`: например, `--set app.env=test` — схема dev/test с таблицей `dev_outbox` (07 §5.63; без параметра — prod-схема без неё, B-AR-09). Разрешены только имена с точкой |
| `--verbose` | печатать тег каждой команды (`file:строка: CREATE TABLE`) и журнал сервера |
| `--clean` | удалить все каталоги `tools/pg/.tmp/*` (остатки `--keep` или аварийного завершения) и выйти |
| `-h`, `--help` | справка |

Через npm: `npm --prefix tools/pg run selftest` — самопроверка на `test/selftest.sql`.

### Что происходит

1. Каталог кластера — `tools/pg/.tmp/<uuid>`. `initdb` запускается с параметрами `--encoding=UTF8 --locale=<locale> --data-checksums --auth=scram-sha-256`, а пароль суперпользователя `postgres` генерируется случайно для каждого запуска.
2. `postgres` слушает только `127.0.0.1` на свободном порту (до трёх попыток при гонке за порт), с параметрами `timezone=UTC`, `fsync=off`, `synchronous_commit=off`, `full_page_writes=off`. Это одноразовый кластер, данные на диске не сохраняются.
3. Создаётся `CREATE DATABASE pos_test TEMPLATE template0 ENCODING 'UTF8'`. Раннер печатает `version()`, кодировку, `collate`/`ctype` и доступные версии `pg_trgm`, `unaccent`, `pgcrypto`. Если сервер не 17.x, это ошибка инфраструктуры.
4. Файлы применяются по порядку, по одной команде (autocommit, как у `psql` без `--single-transaction`). Первая ошибка останавливает раннер: печатается текст в формате psql, `файл:строка:колонка: ERROR: … (SQLSTATE …)`, затем `DETAIL`, `HINT`, `LINE N:` с кареткой, `QUERY` и `CONTEXT`, и раннер выходит с кодом 1.
5. При `--repeat` файлы применяются ещё раз, и раннер сравнивает отпечаток базы до и после повтора (см. ниже).
6. Выполняются `--check`-файлы. Каждый результат печатается с заголовком `-- файл:строка`.
7. Сервер останавливается (`pg_ctl stop -m fast`; если за 15 с не остановился — принудительно), и каталог удаляется. Без `--keep` каталог удаляется и при ошибке, Ctrl+C или закрытом канале вывода.

`NOTICE` и `WARNING` сервера выводятся в stderr с привязкой `файл:строка`, как у psql.

### Коды выхода

| Код | Значение |
|---|---|
| 0 | все файлы и проверки выполнены без ошибок (при `--repeat` — независимо от итога повтора) |
| 1 | ошибка SQL в применяемом или check-файле; при `--repeat-strict` также ошибка или изменения при повторе |
| 2 | ошибка использования или инфраструктуры: неизвестная опция, файл не найден, не установлен `embedded-postgres`, кластер не стартовал, сервер не 17.x |

### Как писать check-файл

Это обычный SQL. Таблицы результатов — для лога. Чтобы проверка **падала**, используйте
`DO $$ BEGIN IF <условие нарушено> THEN RAISE EXCEPTION '…'; END IF; END $$;`. Ошибка в check-файле
даёт код 1.

### Отпечаток для `--repeat`

Отпечаток пользовательских схем (кроме `pg_catalog`, `information_schema` и `pg_toast`) включает:
схемы, отношения и их вид, столбцы (тип, `NOT NULL`, `DEFAULT`, identity, generated), ограничения
(`pg_get_constraintdef`), индексы (`pg_get_indexdef`), функции и процедуры (сигнатура и md5 тела, без
функций расширений), триггеры, пользовательские типы (enum с метками, domain, composite, range),
политики RLS, расширения с версиями, роли, ACL таблиц. Для данных в каждой обычной таблице
считаются число строк и md5 содержимого. Значения последовательностей не сравниваются.
Итог повтора выводится строкой `[repeat] ИТОГ: …`.

## Отличия от `psql -v ON_ERROR_STOP=1 -f`

- Деление на команды повторяет лексер psql (`psqlscan.l`): учитываются `'…'`, `E'…'` с `\'`, `"…"`, `$tag$…$tag$`, комментарии `--` и вложенные `/* */`, скобки и `BEGIN ATOMIC … END` в `CREATE [OR REPLACE] FUNCTION|PROCEDURE`.
- Метакоманды psql (`\i`, `\set`, `\copy`, `:var` …) не поддерживаются. `\…` вне строки — ошибка с номером строки. `COPY … FROM STDIN` — тоже ошибка.
- `BEGIN; … COMMIT;` внутри файла работают, потому что все команды идут через одно соединение.
- `CREATE INDEX CONCURRENTLY` работает: каждая команда выполняется отдельно, вне неявной транзакции.

## Ограничения

- Нет `pg_dump`, поэтому `pg_dump --schema-only` из RM-C-006 п. 5 раннер не покрывает.
- Если процесс `node` убит принудительно (без Ctrl+C), каталог в `.tmp` может остаться. Удаляется через `--clean`.
- Первый запуск `initdb` на Windows занимает около 8–10 с.

Решения и их обоснование — в [NOTES.md](NOTES.md).

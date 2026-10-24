#!/bin/sh
# Инициализация БД тестового контура (RM-C-012). Выполняется официальным образом postgres ОДИН раз — при пустом
# томе pgdata (каталог /docker-entrypoint-initdb.d). Создаёт роли 07 §2.1 (DATA-012) с паролями из секретов:
#   pos_migrate — владелец БД и схемы public (DDL выполняет только контейнер migrate, R0 §17.7);
#   pos_app     — роль api/worker (без DDL; пароль — из database_url, второго файла с паролем нет);
#   pos_readonly, pos_backup — без пароля (LOGIN по паролю невозможен), права выдаёт миграция 0001 (раздел 12).
# Миграция 0001 создаёт роли только если их нет (IF NOT EXISTS) — здесь они уже есть, поэтому мигратору не нужен
# CREATEROLE.
# ОТКЛОНЕНИЕ ТЕСТОВОГО КОНТУРА (docs/ci.md §5, CI-KI-03): pg-boss (D-44) при старте api/worker выполняет
# `CREATE SCHEMA IF NOT EXISTS pgboss` под ролью из DATABASE_URL (pos_app). PostgreSQL проверяет право CREATE на базу
# ДО проверки существования схемы, поэтому без этого права api отвечает /health/ready → 503, а worker не стартует
# (воспроизведено локально: «permission denied for database»). Пока BE не перенесёт установку схемы pg-boss в
# migrate (pos_migrate) с `migrate: false` в api/worker (RM-C-006/RM-C-007), pos_app получает CREATE на базу.
# Права pos_app в схеме public не меняются (CREATE в public у неё по-прежнему нет — DATA-012).
# Значения секретов не выводятся: psql получает пароли через окружение (\getenv, psql 15+), а не аргументами
# командной строки (не видны в списке процессов), и не печатает их (--quiet, без эха команд).
# Файл может быть и исполнен, и подключён через `.` (entrypoint образа postgres подключает *.sh без бита +x;
# на Windows git бит не хранит). Поэтому вся логика — в подоболочке: `set -eu` не меняет опции entrypoint,
# а код выхода подоболочки (ненулевой при любой ошибке, `set -e` внутри) завершает инициализацию: entrypoint
# работает с `set -e`, исполняемый файл возвращает код последней команды.
(
set -eu

read_secret() {
  # $1 — путь файла секрета; завершающий перевод строки отбрасывается.
  tr -d '\r\n' < "$1"
}

MIGRATOR_PW="$(read_secret /run/secrets/db_migrator_password)"
# postgres://pos_app:<пароль>@postgres:5432/<бд> → <пароль>
APP_PW="$(read_secret /run/secrets/database_url | sed -E 's#^[^:]+://[^:@/]+:([^@]*)@.*$#\1#')"
APP_USER="$(read_secret /run/secrets/database_url | sed -E 's#^[^:]+://([^:@/]+):.*$#\1#')"

if [ "$APP_USER" != "pos_app" ]; then
  echo "10-roles.sh: database_url должен использовать пользователя pos_app (сейчас: другой пользователь)" >&2
  exit 1
fi
if [ -z "$MIGRATOR_PW" ] || [ -z "$APP_PW" ]; then
  echo "10-roles.sh: пустой пароль в секретах db_migrator_password или database_url" >&2
  exit 1
fi

export MIGRATOR_PW APP_PW
psql -v ON_ERROR_STOP=1 --no-psqlrc --quiet \
  --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
\getenv migpw MIGRATOR_PW
\getenv apppw APP_PW
\getenv dbname POSTGRES_DB
CREATE ROLE pos_migrate LOGIN PASSWORD :'migpw';
CREATE ROLE pos_app LOGIN PASSWORD :'apppw';
CREATE ROLE pos_readonly LOGIN;
CREATE ROLE pos_backup LOGIN;

-- Владелец БД — pos_migrate: CREATE в базе (схемы pos_meta и т. п.), доверенные расширения 0001 (pgcrypto, pg_trgm,
-- unaccent), а в PostgreSQL 15+ схема public принадлежит pg_database_owner, то есть тоже pos_migrate.
ALTER DATABASE :"dbname" OWNER TO pos_migrate;
REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"dbname" TO pos_app;
GRANT CONNECT ON DATABASE :"dbname" TO pos_readonly, pos_backup;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Временное отклонение (см. шапку): pg-boss создаёт схему pgboss под pos_app. Убрать после RM-C-006/RM-C-007.
GRANT CREATE ON DATABASE :"dbname" TO pos_app;
SQL

unset MIGRATOR_PW APP_PW
echo "10-roles.sh: роли pos_migrate, pos_app, pos_readonly, pos_backup созданы"
)

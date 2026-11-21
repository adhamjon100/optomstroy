#!/bin/sh
# Инициализация БД CI-контура (RM-C-012) и серверных контуров (compose.prod.yml). Выполняется официальным образом postgres ОДИН раз — при пустом
# томе pgdata (каталог /docker-entrypoint-initdb.d). Создаёт роли 07 §2.1 (DATA-012) с паролями из секретов:
#   pos_migrate — владелец БД и схемы public (DDL выполняет только контейнер migrate, R0 §17.7);
#   pos_app     — роль api/worker (без DDL; пароль — из database_url, второго файла с паролем нет);
#   pos_backup  — роль резервного копирования (сервис backup): пароль из db_backup_password и pg_read_all_data —
#                 чтение всех данных, в том числе схем pgboss и pos_meta, которые GRANT миграций не покрывают
#                 (одна нечитаемая таблица — и pg_dump падает); REPLICATION — базовая копия PITR (pg_basebackup,
#                 RUNBOOK §4.8; читает тот же объём данных) и строка `host replication pos_backup` в pg_hba.conf
#                 (образ заканчивает файл строкой `host all all all`, а «all» репликацию не покрывает; тот же текст
#                 для созданных раньше кластеров пишет lib.sh pg_ensure_replication_hba); суперпользователь не нужен;
#   pos_readonly — без пароля (LOGIN по паролю невозможен), права выдаёт миграция 0001 (раздел 12).
# Миграция 0001 создаёт роли только если их нет (IF NOT EXISTS) — здесь они уже есть, поэтому мигратору не нужен
# CREATEROLE.
# Права pos_app на базу — только CONNECT и TEMPORARY, CREATE нет (07 DATA-012). Схему очередей pgboss (D-44) ставит
# и обновляет контейнер migrate под pos_migrate и выдаёт pos_app только USAGE и DML на её объекты
# (pos-api/src/db/pgboss-install.ts); api и worker запускают pg-boss с `migrate: false, createSchema: false`.
# Прежнее отклонение тестового контура (GRANT CREATE ON DATABASE … TO pos_app, docs/ci.md CI-KI-03) снято 2026-11-19;
# в базах, созданных раньше, migrate снимает этот грант сам, владельца схемы pgboss переносит DevOps (RUNBOOK §3.6).
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
BACKUP_PW="$(read_secret /run/secrets/db_backup_password)"
# postgres://pos_app:<пароль>@postgres:5432/<бд> → <пароль>
APP_PW="$(read_secret /run/secrets/database_url | sed -E 's#^[^:]+://[^:@/]+:([^@]*)@.*$#\1#')"
APP_USER="$(read_secret /run/secrets/database_url | sed -E 's#^[^:]+://([^:@/]+):.*$#\1#')"

if [ "$APP_USER" != "pos_app" ]; then
  echo "10-roles.sh: database_url должен использовать пользователя pos_app (сейчас: другой пользователь)" >&2
  exit 1
fi
if [ -z "$MIGRATOR_PW" ] || [ -z "$APP_PW" ] || [ -z "$BACKUP_PW" ]; then
  echo "10-roles.sh: пустой пароль в секретах db_migrator_password, db_backup_password или database_url" >&2
  exit 1
fi

export MIGRATOR_PW APP_PW BACKUP_PW
psql -v ON_ERROR_STOP=1 --no-psqlrc --quiet \
  --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
\getenv migpw MIGRATOR_PW
\getenv apppw APP_PW
\getenv bkpw BACKUP_PW
\getenv dbname POSTGRES_DB
CREATE ROLE pos_migrate LOGIN PASSWORD :'migpw';
CREATE ROLE pos_app LOGIN PASSWORD :'apppw';
CREATE ROLE pos_readonly LOGIN;
CREATE ROLE pos_backup LOGIN REPLICATION PASSWORD :'bkpw';
-- Чтение всех данных для pg_dump (PostgreSQL 14+): схемы pgboss (права мигратор выдаёт только pos_app) и pos_meta
-- не покрыты GRANT 0001.
GRANT pg_read_all_data TO pos_backup;

-- Владелец БД — pos_migrate: CREATE в базе (схемы pos_meta и т. п.), доверенные расширения 0001 (pgcrypto, pg_trgm,
-- unaccent), а в PostgreSQL 15+ схема public принадлежит pg_database_owner, то есть тоже pos_migrate.
ALTER DATABASE :"dbname" OWNER TO pos_migrate;
REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"dbname" TO pos_app;
GRANT CONNECT ON DATABASE :"dbname" TO pos_readonly, pos_backup;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL

unset MIGRATOR_PW APP_PW BACKUP_PW
# Подключение репликации для pg_basebackup сервиса backup (entrypoint уже записал pg_hba.conf; файл перечитывается
# при окончательном запуске сервера после initdb-скриптов).
if ! grep -Eq "^[[:space:]]*host[[:space:]]+replication[[:space:]]+pos_backup[[:space:]]" "$PGDATA/pg_hba.conf"; then
  printf "%s\n" "# optomstroy: базовая копия PITR — pg_basebackup роли pos_backup (RUNBOOK §4.8)" \
    "host replication pos_backup all scram-sha-256" >> "$PGDATA/pg_hba.conf"
fi
echo "10-roles.sh: роли pos_migrate, pos_app, pos_readonly, pos_backup созданы"
)

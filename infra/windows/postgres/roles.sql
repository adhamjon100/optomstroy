-- Роли и права базы Optomstroy на Windows Server — перенос infra/docker/postgres/initdb/10-roles.sh (07 §2.1, DATA-012).
-- Выполняет pg-tool.mjs setup (вызывается из apply-roles.ps1) под суперпользователем, подключённым к базе программы.
-- Пароли сюда не попадают: pg-tool вычисляет верификаторы SCRAM-SHA-256 из файлов секретов и передаёт их параметрами
-- в настройки сеанса optomstroy.verifier_*. Вручную через psql скрипт не выполняется (настроек сеанса не будет —
-- первый же блок остановится с ошибкой).
--   pos_migrate  — владелец базы и схемы public (DDL — только migrate, R0 §17.7);
--   pos_app      — роль api/worker (без DDL; пароль — из database_url);
--   pos_backup   — резервное копирование: pg_read_all_data (pg_dump читает и схемы pgboss, pos_meta) и REPLICATION
--                  (pg_basebackup для PITR; строка `host replication pos_backup` пишется в pg_hba.conf init-postgres.ps1);
--   pos_readonly — без пароля (вход по паролю невозможен), права выдаёт миграция 0001.
-- Отличие от Linux: скрипт повторяемый. Существующие роли не пересоздаются, а приводятся к тем же атрибутам и паролю
-- из секретов (смена пароля = новый файл секрета + повторный apply-roles.ps1). Всё выполняется одной транзакцией.
BEGIN;

DO $roles$
DECLARE
  v_mig text := current_setting('optomstroy.verifier_pos_migrate', true);
  v_app text := current_setting('optomstroy.verifier_pos_app', true);
  v_bk  text := current_setting('optomstroy.verifier_pos_backup', true);
BEGIN
  IF current_database() IN ('postgres', 'template0', 'template1') THEN
    RAISE EXCEPTION 'roles.sql: выполняется в базе программы, а не в %', current_database();
  END IF;
  IF coalesce(v_mig, '') !~ '^SCRAM-SHA-256\$' OR coalesce(v_app, '') !~ '^SCRAM-SHA-256\$'
     OR coalesce(v_bk, '') !~ '^SCRAM-SHA-256\$' THEN
    RAISE EXCEPTION 'roles.sql: нет верификаторов паролей (запускайте через apply-roles.ps1)';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_migrate') THEN
    EXECUTE format('CREATE ROLE pos_migrate LOGIN PASSWORD %L', v_mig);
  END IF;
  EXECUTE format('ALTER ROLE pos_migrate LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', v_mig);

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_app') THEN
    EXECUTE format('CREATE ROLE pos_app LOGIN PASSWORD %L', v_app);
  END IF;
  EXECUTE format('ALTER ROLE pos_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', v_app);

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_readonly') THEN
    CREATE ROLE pos_readonly LOGIN;
  END IF;
  ALTER ROLE pos_readonly LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD NULL;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_backup') THEN
    EXECUTE format('CREATE ROLE pos_backup LOGIN REPLICATION PASSWORD %L', v_bk);
  END IF;
  EXECUTE format('ALTER ROLE pos_backup LOGIN REPLICATION NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L', v_bk);
END
$roles$;

-- Чтение всех данных для pg_dump (PostgreSQL 14+): схемы pgboss и pos_meta не покрыты GRANT 0001.
GRANT pg_read_all_data TO pos_backup;

-- Владелец базы — pos_migrate: CREATE в базе (схемы pos_meta и т. п.), доверенные расширения 0001 (pgcrypto, pg_trgm,
-- unaccent); в PostgreSQL 15+ схема public принадлежит pg_database_owner, то есть тоже pos_migrate.
DO $db$
BEGIN
  EXECUTE format('ALTER DATABASE %I OWNER TO pos_migrate', current_database());
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
  -- Как в 10-roles.sh: у pos_app только CONNECT и TEMPORARY (снимаем CREATE, если его когда-то выдали вручную).
  EXECUTE format('REVOKE CREATE ON DATABASE %I FROM pos_app', current_database());
  EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO pos_app', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO pos_readonly, pos_backup', current_database());
END
$db$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

COMMIT;

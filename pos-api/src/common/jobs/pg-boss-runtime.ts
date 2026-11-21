/** Схема pg-boss в БД (D-44: очереди только в PostgreSQL). */
export const PG_BOSS_SCHEMA = 'pgboss';

/**
 * Опции pg-boss процессов api и worker (07 DATA-012, AC-DATA-012; docs/ci.md CI-KI-03 — закрыт 2026-11-19).
 * Схему `pgboss` ставит и обновляет только мигратор под `pos_migrate` (`src/db/pgboss-install.ts`, шаг
 * `src/migrate.ts` после SQL-миграций); api и worker работают под `pos_app` без DDL: схему не создают
 * (`createSchema: false`) и не мигрируют (`migrate: false`). Если схема не установлена или её версия не совпадает
 * с пакетом, `start()` отказывает («pg-boss is not installed» / «requires migrations»): api отвечает
 * `/health/ready` 503 и повторяет попытку, worker не стартует — до прогона `migrate`.
 *
 * Очереди — без `partition: true`: тогда `create_queue()` только вставляет строку в `pgboss.queue` (DML);
 * секционированная очередь создавала бы таблицу (DDL), которой у `pos_app` нет.
 */
export const PG_BOSS_RUNTIME_OPTIONS = {
  schema: PG_BOSS_SCHEMA,
  migrate: false,
  createSchema: false,
} as const;

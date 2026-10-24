import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { pino } from 'pino';
import { loadMigratorEnv, type MigratorEnv, MigratorConfigError, migratorConnection } from './db/migrator-config.js';
import { DEV_MIGRATIONS_SCHEMA, migrate, MigrationError, type MigrationLogger, seed } from './db/migrator.js';

/**
 * Точка входа контейнера `migrate` (`node dist/migrate.js`, 16 §4.4; RM-C-006):
 * - без аргументов — применяет недостающие `migrations/NNNN_*.sql` (forward-only, журнал
 *   `pos_meta.schema_migrations`), повторный запуск — 0 изменений;
 * - `--seed` (`npm run seed`) — то же и затем идемпотентный seed `seeds/NNNN_*.sql` (значения по умолчанию
 *   `app_settings`, «Розничный покупатель», вид цены по умолчанию, лимиты скидок).
 * Код выхода: 0 — успех; 1 — ошибка конфигурации, подключения или миграции (сообщение без секретов).
 */
const MIGRATIONS_DIR = fileURLToPath(new URL('../migrations/', import.meta.url));
const SEEDS_DIR = fileURLToPath(new URL('../seeds/', import.meta.url));
/**
 * dev-миграции (07 §5.63 `dev_outbox`; RM-C-006 п. 6): каталог `pos-api/db/migrations-dev/` применяется только при
 * `APP_ENV=dev`; в prod-образ не копируется (Dockerfile), поэтому DDL dev-таблиц в prod-образе нет (AC-DATA-169).
 */
const DEV_MIGRATIONS_DIR = fileURLToPath(new URL('../db/migrations-dev/', import.meta.url));

export interface RunOptions {
  readonly seed: boolean;
  readonly migrationsDir?: string;
  readonly seedsDir?: string;
  /** Каталог dev-миграций (по умолчанию `db/migrations-dev/`); применяется только при APP_ENV=dev. */
  readonly devMigrationsDir?: string;
}

export interface RunSummary {
  readonly user: string;
  readonly applied: readonly string[];
  readonly alreadyApplied: readonly string[];
  /** Применённые dev-миграции (`db/migrations-dev/`, только APP_ENV=dev). */
  readonly devApplied: readonly string[];
  readonly seeded?: Readonly<Record<string, number>>;
}

export async function run(
  env: MigratorEnv,
  options: RunOptions,
  logger: MigrationLogger = createLogger(env),
): Promise<RunSummary> {
  const conn = migratorConnection(env);
  if (conn.fallbackToDatabaseUrlUser) {
    logger.warn(
      { user: conn.user, appEnv: env.APP_ENV },
      'DB_MIGRATOR_PASSWORD_FILE не задан: миграции выполняются под пользователем DATABASE_URL (допустимо только APP_ENV=dev; локально — суперпользователь embedded PostgreSQL)',
    );
  }
  const client = new pg.Client({ connectionString: conn.connectionString, application_name: 'pos-migrate' });
  await client.connect();
  try {
    const result = await migrate(client, {
      dir: options.migrationsDir ?? MIGRATIONS_DIR,
      appEnv: env.APP_ENV,
      logger,
    });
    logger.info(
      { user: conn.user, applied: result.applied, alreadyApplied: result.alreadyApplied.length },
      result.applied.length === 0 ? 'migrate: 0 изменений (все миграции уже применены)' : 'migrate: готово',
    );
    const devDir = options.devMigrationsDir ?? DEV_MIGRATIONS_DIR;
    let devApplied: readonly string[] = [];
    if (env.APP_ENV === 'dev' && existsSync(devDir)) {
      const dev = await migrate(client, {
        dir: devDir,
        appEnv: env.APP_ENV,
        logger,
        journalSchema: DEV_MIGRATIONS_SCHEMA,
      });
      devApplied = dev.applied;
      if (dev.applied.length > 0) logger.info({ devApplied }, 'migrate: dev-миграции применены (APP_ENV=dev)');
    }
    // Поиск (07 §10.1): norm_search() = lower(…) — при локали БД без Unicode-регистра (libc «C») кириллица не
    // приводится к нижнему регистру, generated-столбцы name_norm и поиск без учёта регистра не работают.
    const ctype = await client.query<{ ok: boolean; collate: string; ctype: string }>(
      `SELECT lower('ЁЯ') = 'ёя' AS ok, datcollate AS collate, datctype AS ctype
         FROM pg_database WHERE datname = current_database()`,
    );
    if (ctype.rows[0]?.ok === false) {
      logger.warn(
        { datcollate: ctype.rows[0].collate, datctype: ctype.rows[0].ctype },
        'локаль БД не приводит кириллицу к нижнему регистру: norm_search/name_norm (07 §10.1) работают неверно — создайте БД с UTF-8-локалью (en_US.UTF-8, ru_RU.UTF-8 или builtin C.UTF-8)',
      );
    }
    if (!options.seed) return { user: conn.user, ...result, devApplied };
    const seeded = await seed(client, {
      dir: options.seedsDir ?? SEEDS_DIR,
      logger,
      params: { receivables_max_age_min: String(env.RECEIVABLES_MAX_AGE_MIN) },
    });
    const total = Object.values(seeded.inserted).reduce((a, b) => a + b, 0);
    logger.info({ inserted: seeded.inserted }, total === 0 ? 'seed: 0 изменений' : `seed: вставлено строк ${total}`);
    return { user: conn.user, ...result, devApplied, seeded: seeded.inserted };
  } finally {
    await client.end();
  }
}

function createLogger(env: Pick<MigratorEnv, 'LOG_LEVEL'>) {
  return pino({ name: 'pos-migrate', level: env.LOG_LEVEL, base: undefined });
}

async function main(): Promise<void> {
  let env: MigratorEnv;
  try {
    env = loadMigratorEnv();
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    process.exit(1);
  }
  try {
    await run(env, { seed: process.argv.includes('--seed') });
  } catch (e) {
    if (e instanceof MigrationError || e instanceof MigratorConfigError) console.error(`${e.name}: ${e.message}`);
    else console.error(`pos-migrate: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  }
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}

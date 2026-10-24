import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import type pg from 'pg';

/**
 * Мигратор SQL-файлов (RM-C-006; 06 §11, 07 §15, D-03, R5 §7.2). Источник истины схемы — SQL-файлы
 * `migrations/NNNN_*.sql` (DDL RM-B-005, seed RBAC RM-B-008 и следующие); Drizzle-схема `src/db/schema/*`
 * — типизированная проекция для запросов, `drizzle-kit generate` не используется.
 *
 * Правила:
 * - **forward-only**: применённый файл не меняется и не откатывается; изменение схемы — только новым файлом
 *   по схеме expand → migrate → contract (07 §15.2). Изменённый после применения файл (другая контрольная
 *   сумма) — ошибка `MIGRATION_CHECKSUM_MISMATCH`, мигратор ничего не применяет;
 * - **журнал** — таблица `pos_meta.schema_migrations` (отдельная схема, чтобы в `public` оставались ровно
 *   таблицы 07 §5 — `scripts/check_tables.sql`); 07 §15 и 06 называют журнал `__drizzle_migrations` с пометкой
 *   [ТИПОВО: имя по умолчанию] — здесь имя задано задачей RM-C-006;
 * - каждый файл применяется в **своей транзакции** вместе с записью в журнал: ошибка — откат файла и журнала;
 *   внешняя обёртка файла `BEGIN; … COMMIT;` (так оформлены 0001/0002 для запуска через psql) снимается, чтобы
 *   транзакцией управлял мигратор. Файл с директивой `-- pos-migrate: no-transaction` (например,
 *   `CREATE INDEX CONCURRENTLY`) выполняется без обёртки, журнал пишется после него;
 * - параллельный запуск двух мигратов исключён `pg_advisory_lock`;
 * - сеансу задаётся `app.env` = `APP_ENV` (dev/staging/prod);
 * - dev-миграции `db/migrations-dev/NNNN_*.sql` (07 §5.63: `dev_outbox`) — отдельный проход с журналом
 *   `pos_dev.schema_migrations` только при `APP_ENV=dev` (migrate.ts); в prod-образ каталог не копируется
 *   (AC-DATA-169, RM-C-006 п. 6; ревью C-MJ-05).
 */

export const MIGRATIONS_SCHEMA = 'pos_meta';
export const MIGRATIONS_TABLE = 'schema_migrations';
/** Журнал dev-миграций (`db/migrations-dev/`): отдельная схема — prod-схема (public + pos_meta) не меняется. */
export const DEV_MIGRATIONS_SCHEMA = 'pos_dev';
/** Ключ advisory-lock мигратора (произвольная константа проекта). */
export const MIGRATION_LOCK_KEY = 74_2006;

const FILE_RE = /^(\d{4})_[a-z0-9_]+\.sql$/;
const NO_TX_DIRECTIVE = /^--\s*pos-migrate:\s*no-transaction\s*$/m;

export interface MigrationFile {
  readonly version: string;
  readonly name: string;
  readonly path: string;
  readonly sql: string;
  readonly checksum: string;
  readonly transactional: boolean;
}

export interface MigrationLogger {
  info(obj: object, msg: string): void;
  warn(obj: object, msg: string): void;
}

export interface MigrateResult {
  readonly applied: readonly string[];
  readonly alreadyApplied: readonly string[];
}

export class MigrationError extends Error {
  constructor(
    readonly code:
      | 'MIGRATION_CHECKSUM_MISMATCH'
      | 'MIGRATION_MISSING_FILE'
      | 'MIGRATION_OUT_OF_ORDER'
      | 'MIGRATION_BAD_NAME'
      | 'MIGRATION_FAILED',
    message: string,
    options?: { cause?: unknown },
  ) {
    super(message, options);
    this.name = 'MigrationError';
  }
}

/** Контрольная сумма: sha256 текста с нормализованными переводами строк (checkout CRLF/LF не меняет сумму). */
export function checksumOf(sql: string): string {
  return createHash('sha256').update(sql.replace(/\r\n/g, '\n'), 'utf8').digest('hex');
}

/**
 * Снимает внешнюю обёртку `BEGIN; … COMMIT;` (первая и последняя команды файла вне комментариев). Внутренние
 * `BEGIN … END` PL/pgSQL не затрагиваются: снимается только `BEGIN;`/`COMMIT;` верхнего уровня.
 */
export function stripTransactionWrapper(sql: string): string {
  const head = /^((?:\s|--[^\n]*\n)*)BEGIN\s*;/i;
  const tail = /COMMIT\s*;((?:\s|--[^\n]*(?:\n|$))*)$/i;
  if (!head.test(sql) || !tail.test(sql)) return sql;
  return sql.replace(head, '$1').replace(tail, '$1');
}

export function readSqlDir(dir: string, pattern: RegExp = FILE_RE): MigrationFile[] {
  const names = readdirSync(dir)
    .filter((n) => n.endsWith('.sql'))
    .sort();
  return names.map((name) => {
    const m = pattern.exec(name);
    if (!m) throw new MigrationError('MIGRATION_BAD_NAME', `${name}: ожидается имя NNNN_snake_case.sql`);
    const sql = readFileSync(join(dir, name), 'utf8');
    return {
      version: m[1] ?? name,
      name,
      path: join(dir, name),
      sql,
      checksum: checksumOf(sql),
      transactional: !NO_TX_DIRECTIVE.test(sql),
    };
  });
}

interface JournalRow {
  version: string;
  name: string;
  checksum: string;
}

async function ensureJournal(client: pg.ClientBase, schema: string): Promise<void> {
  await client.query(`CREATE SCHEMA IF NOT EXISTS ${schema}`);
  await client.query(`
    CREATE TABLE IF NOT EXISTS ${schema}.${MIGRATIONS_TABLE} (
      version     text PRIMARY KEY CHECK (version ~ '^[0-9]{4}$'),
      name        text NOT NULL UNIQUE,
      checksum    text NOT NULL CHECK (checksum ~ '^[0-9a-f]{64}$'),
      applied_at  timestamptz NOT NULL DEFAULT now(),
      applied_by  text NOT NULL DEFAULT current_user,
      duration_ms integer NOT NULL CHECK (duration_ms >= 0)
    )`);
}

async function journalRows(client: pg.ClientBase, schema: string): Promise<Map<string, JournalRow>> {
  const res = await client.query<JournalRow>(
    `SELECT version, name, checksum FROM ${schema}.${MIGRATIONS_TABLE} ORDER BY version`,
  );
  return new Map(res.rows.map((r) => [r.version, r]));
}

export interface MigrateOptions {
  readonly dir: string;
  readonly appEnv: string;
  readonly logger: MigrationLogger;
  /** Схема журнала: `pos_meta` (по умолчанию) или `pos_dev` для `db/migrations-dev/`. */
  readonly journalSchema?: string;
}

/** Применяет недостающие миграции по порядку версий. Повторный запуск без новых файлов — 0 изменений. */
export async function migrate(client: pg.ClientBase, options: MigrateOptions): Promise<MigrateResult> {
  const files = readSqlDir(options.dir);
  await client.query(`SELECT set_config('app.env', $1, false)`, [options.appEnv]);
  const journalSchema = options.journalSchema ?? MIGRATIONS_SCHEMA;
  if (!/^[a-z_][a-z0-9_]*$/.test(journalSchema)) throw new Error(`journalSchema: недопустимое имя ${journalSchema}`);
  await client.query('SELECT pg_advisory_lock($1)', [MIGRATION_LOCK_KEY]);
  try {
    await ensureJournal(client, journalSchema);
    const journal = await journalRows(client, journalSchema);
    const byVersion = new Map(files.map((f) => [f.version, f]));
    for (const row of journal.values()) {
      const f = byVersion.get(row.version);
      if (!f) {
        throw new MigrationError(
          'MIGRATION_MISSING_FILE',
          `${row.name}: применён в БД, но файла нет в каталоге миграций (forward-only: файлы не удаляются)`,
        );
      }
      if (f.checksum !== row.checksum || f.name !== row.name) {
        throw new MigrationError(
          'MIGRATION_CHECKSUM_MISMATCH',
          `${f.name}: файл изменён после применения (forward-only: изменения — только новой миграцией)`,
        );
      }
    }
    // Новый файл с версией меньше максимальной применённой (заполнение пропуска, перенумерация ветки) на развёрнутой
    // БД применился бы после более поздних, а на новой — до них: порядок схемы на средах разошёлся бы (07 §12.1;
    // ревью E-trace-8). Отказ до применения чего-либо; такой файл перенумеровывается в конец.
    const maxApplied = [...journal.keys()].sort().at(-1);
    const late = maxApplied ? files.filter((f) => !journal.has(f.version) && f.version < maxApplied) : [];
    if (late.length > 0) {
      throw new MigrationError(
        'MIGRATION_OUT_OF_ORDER',
        `${late.map((f) => f.name).join(', ')}: версия меньше последней применённой ${maxApplied} — ` +
          'новая миграция получает номер больше всех применённых (forward-only, 07 §12.1)',
      );
    }
    const applied: string[] = [];
    const alreadyApplied: string[] = [];
    for (const f of files) {
      if (journal.has(f.version)) {
        alreadyApplied.push(f.name);
        continue;
      }
      const started = Date.now();
      try {
        if (f.transactional) {
          await client.query('BEGIN');
          await client.query(stripTransactionWrapper(f.sql));
          await insertJournal(client, journalSchema, f, Date.now() - started);
          await client.query('COMMIT');
        } else {
          await client.query(f.sql);
          await insertJournal(client, journalSchema, f, Date.now() - started);
        }
      } catch (e) {
        if (f.transactional) await client.query('ROLLBACK').catch(() => undefined);
        throw new MigrationError('MIGRATION_FAILED', `${f.name}: ${e instanceof Error ? e.message : String(e)}`, {
          cause: e,
        });
      }
      applied.push(f.name);
      options.logger.info({ migration: f.name, durationMs: Date.now() - started }, 'migration applied');
    }
    return { applied, alreadyApplied };
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [MIGRATION_LOCK_KEY]).catch(() => undefined);
  }
}

async function insertJournal(
  client: pg.ClientBase,
  schema: string,
  f: MigrationFile,
  durationMs: number,
): Promise<void> {
  await client.query(
    `INSERT INTO ${schema}.${MIGRATIONS_TABLE} (version, name, checksum, duration_ms) VALUES ($1, $2, $3, $4)`,
    [f.version, f.name, f.checksum, durationMs],
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Seed
// ---------------------------------------------------------------------------------------------------------------

const SEED_FILE_RE = /^(\d{4})_[a-z0-9_]+\.sql$/;

export interface SeedOptions {
  readonly dir: string;
  readonly logger: MigrationLogger;
  /**
   * Параметры seed, передаются файлам как GUC сеанса `app.seed_<имя>` (`SET LOCAL`, читаются через
   * `current_setting('app.seed_<имя>', true)`): так значения по умолчанию берутся из env без шаблонизации SQL.
   */
  readonly params: Readonly<Record<string, string>>;
}

export interface SeedResult {
  /** Число вставленных строк по таблицам (по всем файлам); повторный запуск — все нули. */
  readonly inserted: Readonly<Record<string, number>>;
}

/**
 * Применяет `seeds/NNNN_*.sql` при каждом запуске (идемпотентно: `ON CONFLICT DO NOTHING`, существующие
 * значения не перезаписываются — их меняет администратор). Все файлы — одна транзакция с
 * `app.system = 'migration'` (аудит пишется с severity info, 07 §9.1). Подсчёт вставок — по `n_tup_ins`
 * не надёжен в транзакции, поэтому файлы сами не считают: сравниваются `count(*)` затронутых таблиц.
 */
export async function seed(client: pg.ClientBase, options: SeedOptions): Promise<SeedResult> {
  const files = readSqlDir(options.dir, SEED_FILE_RE);
  const tables = seedTables(files);
  await client.query('BEGIN');
  try {
    await client.query(`SELECT set_config('app.system', 'migration', true)`);
    for (const [name, value] of Object.entries(options.params)) {
      if (!/^[a-z0-9_]+$/.test(name)) throw new Error(`seed param ${name}: допустимы [a-z0-9_]`);
      await client.query(`SELECT set_config($1, $2, true)`, [`app.seed_${name}`, value]);
    }
    const before = await countRows(client, tables);
    for (const f of files) {
      await client.query(stripTransactionWrapper(f.sql));
      options.logger.info({ seed: f.name }, 'seed applied');
    }
    const after = await countRows(client, tables);
    await client.query('COMMIT');
    const inserted: Record<string, number> = {};
    for (const t of tables) inserted[t] = (after.get(t) ?? 0) - (before.get(t) ?? 0);
    return { inserted };
  } catch (e) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw e;
  }
}

/** Таблицы, в которые пишут seed-файлы (`INSERT INTO <table>`), — для отчёта о числе вставок. */
function seedTables(files: readonly MigrationFile[]): string[] {
  const set = new Set<string>();
  for (const f of files) for (const m of f.sql.matchAll(/INSERT\s+INTO\s+([a-z_][a-z0-9_]*)/gi)) set.add(m[1]);
  return [...set].sort();
}

async function countRows(client: pg.ClientBase, tables: readonly string[]): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  for (const t of tables) {
    const r = await client.query<{ n: number }>(`SELECT count(*)::int AS n FROM ${t}`);
    out.set(t, r.rows[0]?.n ?? 0);
  }
  return out;
}

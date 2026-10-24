import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { loadMigratorEnv } from '../../src/db/migrator-config.js';
import { run } from '../../src/migrate.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { CHECK_TABLES_SQL } from './support/paths.js';

/**
 * RM-C-006 п. 7 (B-AR-10 (б)): поведенческие SQL-проверки DDL `test/sql/check_ddl_behavior.sql` (60 негативных
 * сценариев CHECK/UNIQUE/FK/триггеров и позитивные инварианты) и `scripts/check_tables.sql` выполняются в тестах
 * pos-api (`npm run test:db`) на БД, созданной настоящим мигратором `src/migrate.ts` (APP_ENV=dev → схема dev/test
 * с dev_outbox из db/migrations-dev/), а не только раннером tools/pg. Файл перенесён из scripts/ в pos-api/test/sql/
 * (RM-C-006 п. 7; ревью C-MJ-05); тот же файл исполняют Makefile `check-contracts` и job contracts-lint (psql).
 */
const DDL_BEHAVIOR_SQL = fileURLToPath(new URL('../sql/check_ddl_behavior.sql', import.meta.url));
/** Лексер команд psql из раннера tools/pg (тот же разбор, что у `run-sql.mjs --check`). */
const RUN_SQL_MODULE = new URL('../../../tools/pg/run-sql.mjs', import.meta.url).href;
type SplitSql = (text: string) => { sql: string }[];

/**
 * Выполняет файл так же, как `psql -f` / `run-sql.mjs`: по одной команде в autocommit. Одним multi-statement
 * запросом нельзя: весь текст стал бы одной неявной транзакцией и `SET LOCAL ROLE` из DO-блоков действовал бы до конца.
 */
async function execFile(c: pg.Client, file: string): Promise<void> {
  const { splitSql } = (await import(RUN_SQL_MODULE)) as { splitSql: SplitSql };
  for (const stmt of splitSql(readFileSync(file, 'utf8'))) await c.query(stmt.sql);
}

describe('RM-C-006 п. 7: check_ddl_behavior.sql и check_tables.sql на схеме мигратора (PostgreSQL 17)', () => {
  const db = new EmbeddedPg();
  const name = 'pos_ddl_behavior';

  beforeAll(async () => {
    await db.start();
    await db.createDatabase(name);
    await run(
      loadMigratorEnv({ APP_ENV: 'dev', LOG_LEVEL: 'silent', DATABASE_URL: db.url(name) }),
      // без seed: сценарии check_ddl_behavior.sql создают собственные данные (в т. ч. прайс-лист по умолчанию).
      { seed: false },
      {
        info: () => undefined,
        warn: () => undefined,
      },
    );
  });

  afterAll(async () => {
    await db.stop();
  });

  const withSession = async <T>(fn: (c: pg.Client) => Promise<T>): Promise<T> => {
    const c = new pg.Client({ connectionString: db.url(name) });
    await c.connect();
    try {
      // Те же условия, что у мигратора dev/test: app.env помечает dev/test-схему (dev_outbox, B-AR-09).
      await c.query(`SELECT set_config('app.env', 'dev', false)`);
      return await fn(c);
    } finally {
      await c.end();
    }
  };

  it('check_tables.sql: 64 таблицы и 45 enum-типов 07 §5/§6.1 (dev/test-схема)', async () => {
    const notices: string[] = [];
    await withSession(async (c) => {
      c.on('notice', (n) => notices.push(n.message ?? ''));
      await execFile(c, CHECK_TABLES_SQL);
    });
    expect(notices.join('\n')).toMatch(/OK — 64 из 64 таблиц/);
    expect(notices.join('\n')).toMatch(/OK — 45 из 45 enum-типов/);
  });

  it('check_ddl_behavior.sql: все негативные сценарии отклоняются, инварианты выполняются (код 0)', async () => {
    const notices: string[] = [];
    const logged = await withSession(async (c) => {
      c.on('notice', (n) => notices.push(n.message ?? ''));
      await execFile(c, DDL_BEHAVIOR_SQL);
      const r = await c.query<{ rejected: number }>(
        `SELECT count(*) FILTER (WHERE outcome LIKE 'rejected%')::int AS rejected FROM ddl_check_log`,
      );
      return r.rows[0]?.rejected ?? 0;
    });
    const summary = notices.find((n) => n.startsWith('check_ddl_behavior: OK')) ?? '';
    expect(summary).toMatch(/негативных сценариев \d+/);
    const declared = Number(/негативных сценариев (\d+)/.exec(summary)?.[1] ?? '0');
    expect(declared).toBeGreaterThanOrEqual(60);
    expect(logged).toBe(declared);
  });

  // 12 T-SYNC-040 (unit + integration): поставить в outbox товар или цену невозможно — `aggregate_type` ограничен
  // enum `outbox_aggregate` (order, payment, customer, return_request); те же сценарии — в check_ddl_behavior.sql.
  it('T-SYNC-040: мастер-данные из POS в 1С не уходят — outbox не принимает product/price', async () => {
    const values = await withSession(async (c) => {
      const r = await c.query<{ v: string }>(`SELECT unnest(enum_range(NULL::outbox_aggregate))::text AS v`);
      const errors: string[] = [];
      for (const kind of ['product', 'price', 'variant', 'stock']) {
        try {
          await c.query(
            `INSERT INTO onec_outbox (aggregate_type, aggregate_id, external_id, operation, payload, payload_hash)
             VALUES ($1::outbox_aggregate, gen_random_uuid(), gen_random_uuid(), 'create', '{}', '\\x00')`,
            [kind],
          );
        } catch (e) {
          errors.push(`${kind}:${(e as { code?: string }).code}`);
        }
      }
      return { enumValues: r.rows.map((x) => x.v), errors };
    });
    expect(values.enumValues.sort()).toEqual(['customer', 'order', 'payment', 'return_request']);
    // 22P02 — invalid_text_representation (значение вне enum).
    expect(values.errors).toEqual(['product:22P02', 'price:22P02', 'variant:22P02', 'stock:22P02']);
  });
});

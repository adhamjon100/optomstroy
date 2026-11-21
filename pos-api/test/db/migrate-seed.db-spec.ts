import { randomBytes } from 'node:crypto';
import { cpSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { INestApplication } from '@nestjs/common';
import { eq } from 'drizzle-orm';
import pg from 'pg';
import { PgBoss } from 'pg-boss';
import request from 'supertest';
import { createApp } from '../../src/bootstrap/create-app.js';
import { PG_BOSS_RUNTIME_OPTIONS } from '../../src/common/jobs/pg-boss-runtime.js';
import { PgBossService } from '../../src/common/jobs/pg-boss.service.js';
import { createDatabase } from '../../src/db/database.js';
import { loadMigratorEnv, MigratorConfigError, migratorConnection } from '../../src/db/migrator-config.js';
import { MIGRATIONS_SCHEMA, MIGRATIONS_TABLE, MigrationError } from '../../src/db/migrator.js';
import { installPgBoss } from '../../src/db/pgboss-install.js';
import * as schema from '../../src/db/schema/index.js';
import { run } from '../../src/migrate.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { LogCapture, testConfig } from '../support/test-app.js';
import { readEnums, readTables, schemaFingerprint } from './support/catalog.js';
import { compareDrizzleWithDb } from './support/drizzle-compare.js';
import { CHECK_TABLES_SQL, expectedTables, MIGRATIONS_DIR, POS_API_DIR, SCHEMA_DUMP_SQL } from './support/paths.js';
import { dumpSchema } from './support/schema-dump.js';

/**
 * RM-C-006 на PostgreSQL 17 (embedded): migrate на пустой БД под ролью pos_migrate → 66 таблиц → seed →
 * ключи app_settings = R0 §17.7 (+ customer_stock_display) → повторный migrate/seed = 0 изменений →
 * Drizzle-схема = БД → forward-only → /health/ready → выгрузка DDL docs/erd/schema_v1.sql (и её проверка
 * повторным применением) → схема pg-boss у мигратора, pos_app без DDL (AC-DATA-012, CI-KI-03) → перенос владельца
 * схемы pg-boss в базе до 2026-11-19 (docs/ops/RUNBOOK.md §3.6 = infra/scripts/restore-db.sh).
 * Запуск: `npx vitest run --config test/db/vitest.config.ts`
 * (перезапись schema_v1.sql: `UPDATE_SCHEMA_DUMP=1`).
 */
/** Схемы приложения: `public`, журнал мигратора и журнал удалений офлайн-API `catalog_sync` (0006, EQ-CSYNC-01). */
const SCHEMAS = ['public', MIGRATIONS_SCHEMA, 'catalog_sync'];
/** Все forward-only миграции `migrations/NNNN_*.sql` по порядку (этапы B–E: 0001…; список не зашит — RM-E-012). */
const ALL_MIGRATIONS = readdirSync(MIGRATIONS_DIR)
  .filter((n) => /^\d{4}_[a-z0-9_]+\.sql$/.test(n))
  .sort();
/** Имя синтетической «сломанной» миграции — следующий номер после последней (forward-only, шаг 7). */
const BROKEN_MIGRATION = `${String(Number(ALL_MIGRATIONS.at(-1)?.slice(0, 4) ?? '0') + 1).padStart(4, '0')}_c006_broken.sql`;
/**
 * Локаль БД с Unicode-регистром: встроенный провайдер PG17 `C.UTF-8` (одинаков на Windows/Linux). С libc-локалью
 * `C` (как в test/support/embedded-pg.ts) lower() не переводит кириллицу в нижний регистр и norm_search (07 §10.1)
 * не нормализует русские названия — в prod (postgres:17, en_US.utf8) этого нет.
 */
const DB_LOCALE = `TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LC_COLLATE 'C' LC_CTYPE 'C'`;

interface LogLine {
  level: 'info' | 'warn';
  obj: object;
  msg: string;
}
class CaptureLogger {
  readonly lines: LogLine[] = [];
  info(obj: object, msg: string): void {
    this.lines.push({ level: 'info', obj, msg });
  }
  warn(obj: object, msg: string): void {
    this.lines.push({ level: 'warn', obj, msg });
  }
}

/** Ключи app_settings ядра R0 §17.7 — из самого документа ядра (абзац «Бизнес-настройки POS — ключи …»). */
function kernelSettingKeys(): string[] {
  const kernel = readFileSync(join(POS_API_DIR, '../docs/research/R0_DECISION_KERNEL.md'), 'utf8');
  const section = kernel.slice(kernel.indexOf('### 17.7.'), kernel.indexOf('## 18.'));
  const start = section.indexOf('Бизнес-настройки POS — ключи');
  expect(start).toBeGreaterThan(0);
  const para = section.slice(start, section.indexOf('\n', start));
  return [...para.matchAll(/`([a-z0-9_.<>]+)`/g)].map((m) => m[1]).filter((k) => k !== 'app_settings');
}

describe('RM-C-006: migrate → seed → проверки на PostgreSQL 17', () => {
  const db = new EmbeddedPg();
  const tmp = mkdtempSync(join(tmpdir(), 'pos-c006-'));
  // спецсимволы URL в пароле: мигратор кодирует пароль в строке подключения
  const migratorPassword = `${randomBytes(18).toString('base64url')}@:/%#?`;
  const passwordFile = join(tmp, 'db_migrator_password');
  let su: pg.Client;
  let env: ReturnType<typeof loadMigratorEnv>;
  let fingerprintAfterFirst: string[];

  const connect = async (database: string): Promise<pg.Client> => {
    const c = new pg.Client({ connectionString: db.url(database) });
    await c.connect();
    return c;
  };
  const withDb = async <T>(database: string, fn: (c: pg.Client) => Promise<T>): Promise<T> => {
    const c = await connect(database);
    try {
      return await fn(c);
    } finally {
      await c.end();
    }
  };

  beforeAll(async () => {
    await db.start();
    su = await connect('postgres');
    // Эксплуатация (16 §4.3): роли создаются заранее, мигратор — не суперпользователь, владелец БД/схемы public
    await su.query(`CREATE ROLE pos_migrate LOGIN PASSWORD '${migratorPassword}'`);
    await su.query('CREATE ROLE pos_app LOGIN; CREATE ROLE pos_readonly LOGIN; CREATE ROLE pos_backup LOGIN');
    await su.query(`CREATE DATABASE pos_c006 OWNER pos_migrate ${DB_LOCALE}`);
    writeFileSync(passwordFile, `${migratorPassword}\n`);
    env = loadMigratorEnv({
      APP_ENV: 'dev',
      LOG_LEVEL: 'silent',
      DATABASE_URL: db.url('pos_c006'),
      DB_MIGRATOR_PASSWORD_FILE: passwordFile,
    });
  });

  afterAll(async () => {
    await su?.end();
    await db.stop();
    rmSync(tmp, { recursive: true, force: true });
  });

  it('1. migrate на пустой БД под ролью pos_migrate (пароль из DB_MIGRATOR_PASSWORD_FILE) применяет все миграции по порядку', async () => {
    const log = new CaptureLogger();
    const summary = await run(env, { seed: false }, log);
    expect(summary.user).toBe('pos_migrate');
    expect(summary.applied).toEqual(ALL_MIGRATIONS);
    expect(summary.devApplied).toEqual(['0001_dev_outbox.sql']); // APP_ENV=dev → db/migrations-dev/ (C-MJ-05)
    // схема pg-boss — шаг мигратора под pos_migrate (07 DATA-012), не api/worker
    expect(summary.pgBoss).toMatchObject({
      schema: 'pgboss',
      before: null,
      owner: 'pos_migrate',
      grantedTo: 'pos_app',
      revokedDatabaseCreate: false,
    });
    expect(log.lines.filter((l) => l.level === 'warn')).toEqual([]);
    await withDb('pos_c006', async (c) => {
      const j = await c.query(
        `SELECT version, name, applied_by FROM ${MIGRATIONS_SCHEMA}.${MIGRATIONS_TABLE} ORDER BY version`,
      );
      expect(ALL_MIGRATIONS.slice(0, 2)).toEqual(['0001_init.sql', '0002_rbac_seed.sql']);
      expect(j.rows).toEqual(
        ALL_MIGRATIONS.map((name) => ({ version: name.slice(0, 4), name, applied_by: 'pos_migrate' })),
      );
      const owners = await c.query(
        `SELECT DISTINCT pg_get_userbyid(c.relowner) AS owner FROM pg_class c
          WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'`,
      );
      expect(owners.rows).toEqual([{ owner: 'pos_migrate' }]);
      const su = await c.query(`SELECT rolsuper FROM pg_roles WHERE rolname = 'pos_migrate'`);
      expect(su.rows[0].rolsuper).toBe(false);
    });
  });

  // 66 = 64 таблицы 07 §5 до v1.17 + store_tablets (07 §5.65, 0022_kiosk_schema.sql, ADR-115) + hello_keys (07 §5.66,
  // 0024_face_login.sql, ADR-116); dev-миграций по-прежнему одна.
  it('2. в public ровно 66 таблиц по scripts/check_tables.sql (app.env=dev → dev_outbox есть)', async () => {
    const expected = expectedTables();
    expect(expected).toHaveLength(66);
    await withDb('pos_c006', async (c) => {
      await c.query(`SET app.env = 'dev'`);
      await c.query(readFileSync(CHECK_TABLES_SQL, 'utf8')); // RAISE EXCEPTION при расхождении
      const actual = await c.query<{ relname: string }>(
        `SELECT relname FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r','p') ORDER BY 1`,
      );
      expect(actual.rows.map((r) => r.relname)).toEqual(expected.map((e) => e.name).sort());
      const enums = await c.query(
        `SELECT count(*)::int AS n FROM pg_type WHERE typnamespace = 'public'::regnamespace AND typtype = 'e'`,
      );
      expect(enums.rows[0].n).toBe(45);
    });
    fingerprintAfterFirst = await withDb('pos_c006', (c) => schemaFingerprint(c, SCHEMAS));
  });

  it('3. seed: app_settings = ключи R0 §17.7 + customer_stock_display; «Розничный покупатель»; вид цены; лимиты', async () => {
    const summary = await run(env, { seed: true }, new CaptureLogger());
    expect(summary.applied).toEqual([]);
    expect(summary.seeded).toEqual({ app_settings: 30, customers: 1, price_lists: 1, role_discount_limits: 7 });

    await withDb('pos_c006', async (c) => {
      const entities = (
        await c.query<{ e: string }>(`SELECT unnest(enum_range(NULL::sync_entity))::text AS e`)
      ).rows.map((r) => r.e);
      expect(entities).toHaveLength(17);
      const kernel = kernelSettingKeys();
      expect(kernel).toHaveLength(13);
      const expectedKeys = [
        ...kernel.filter((k) => k !== 'sync_interval.<entity>'),
        ...entities.map((e) => `sync_interval.${e}`),
        'customer_stock_display',
      ].sort();
      const keys = (await c.query<{ key: string }>('SELECT key FROM app_settings ORDER BY key')).rows.map((r) => r.key);
      expect(keys).toEqual(expectedKeys);
      expect(keys).not.toContain('recommended_app_version');

      const v = Object.fromEntries(
        (
          await c.query<{ key: string; value: unknown; value_type: string }>(
            'SELECT key, value, value_type FROM app_settings',
          )
        ).rows.map((r) => [r.key, { value: r.value, type: r.value_type }]),
      );
      expect(v['customer_stock_display']).toEqual({ value: 'status', type: 'string' });
      expect(v['receivables.max_age_minutes']).toEqual({ value: 60, type: 'integer' });
      expect(v['return_approval_threshold']).toEqual({ value: { amount: '10000.00', currency: 'KGS' }, type: 'money' });
      expect(v['returns_enabled']).toEqual({ value: true, type: 'boolean' });
      expect(v['cash_rounding']).toEqual({ value: 'none', type: 'string' });
      expect(v['min_app_version']).toEqual({ value: null, type: 'string' });
      expect(v['sync_interval.stock']).toEqual({ value: null, type: 'integer' });
      const secret = await c.query(`SELECT count(*)::int AS n FROM app_settings WHERE is_secret`);
      expect(secret.rows[0].n).toBe(0);

      const retail = await c.query(
        `SELECT c.name, c.source, c.credit_allowed, c.name_norm, p.name AS price_list, p.is_default
           FROM customers c LEFT JOIN price_lists p ON p.id = c.default_price_list_id WHERE c.is_retail_default`,
      );
      expect(retail.rows).toEqual([
        {
          name: 'Розничный покупатель',
          source: 'pos',
          credit_allowed: false,
          name_norm: 'розничный покупатель',
          price_list: 'Розничная',
          is_default: true,
        },
      ]);
      const limits = await c.query(
        `SELECT role::text, max_percent, can_approve_over_limit FROM role_discount_limits ORDER BY array_position(enum_range(NULL::role_code), role_discount_limits.role)`,
      );
      expect(limits.rows).toEqual([
        { role: 'seller', max_percent: '5.00', can_approve_over_limit: false },
        { role: 'cashier', max_percent: '5.00', can_approve_over_limit: false },
        { role: 'senior_seller', max_percent: '10.00', can_approve_over_limit: true },
        { role: 'admin', max_percent: '15.00', can_approve_over_limit: true },
        { role: 'owner', max_percent: '0.00', can_approve_over_limit: false },
        { role: 'customer', max_percent: '0.00', can_approve_over_limit: false },
        { role: 'integration', max_percent: '0.00', can_approve_over_limit: false },
      ]);
      // seed пишет аудит с app.system → severity info; цепочка аудита цела
      const audit = await c.query(
        `SELECT action, severity, count(*)::int AS n FROM audit_logs
          WHERE action IN ('customer.created', 'discount.limits_changed') GROUP BY 1, 2 ORDER BY 1`,
      );
      expect(audit.rows).toEqual([
        { action: 'customer.created', severity: 'info', n: 1 },
        { action: 'discount.limits_changed', severity: 'info', n: 7 },
      ]);
      const chain = await c.query(`SELECT ok FROM audit_verify_chain(0, 9223372036854775807)`);
      expect(chain.rows[0].ok).toBe(true);
    });
  });

  it('4. повторный migrate и seed — 0 изменений (схема, журнал, данные)', async () => {
    const counts = async (): Promise<Record<string, unknown>> =>
      withDb(
        'pos_c006',
        async (c) =>
          (
            await c.query<Record<string, unknown>>(
              `SELECT (SELECT count(*) FROM app_settings)::int AS s, (SELECT count(*) FROM customers)::int AS c,
                    (SELECT count(*) FROM price_lists)::int AS p, (SELECT count(*) FROM role_discount_limits)::int AS r,
                    (SELECT count(*) FROM audit_logs)::int AS a, (SELECT count(*) FROM role_permissions)::int AS rp,
                    (SELECT string_agg(version || applied_at::text, ',') FROM ${MIGRATIONS_SCHEMA}.${MIGRATIONS_TABLE}) AS j`,
            )
          ).rows[0],
      );
    const before = await counts();
    const log = new CaptureLogger();
    const summary = await run(env, { seed: true }, log);
    expect(summary.applied).toEqual([]);
    expect(summary.alreadyApplied).toEqual(ALL_MIGRATIONS);
    expect(summary.seeded).toEqual({ app_settings: 0, customers: 0, price_lists: 0, role_discount_limits: 0 });
    expect(summary.pgBoss.before).toBe(summary.pgBoss.version);
    expect(log.lines.map((l) => l.msg)).toEqual(
      expect.arrayContaining([
        'migrate: 0 изменений (все миграции уже применены)',
        'pg-boss: 0 изменений (схема актуальна)',
        'seed: 0 изменений',
      ]),
    );
    expect(await counts()).toEqual(before);
    expect(await withDb('pos_c006', (c) => schemaFingerprint(c, SCHEMAS))).toEqual(fingerprintAfterFirst);
    console.error(
      `[RM-C-006] повторный запуск: applied=[], seed=0, отпечаток схемы: ${fingerprintAfterFirst.length} объектов без изменений`,
    );
  });

  it('5. Drizzle-схема src/db/schema совпадает с БД (все таблицы, столбцы, типы, NOT NULL, DEFAULT, PK, enum-ы)', async () => {
    const diff = await withDb('pos_c006', async (c) =>
      compareDrizzleWithDb(schema as Record<string, unknown>, await readTables(c), await readEnums(c)),
    );
    expect(diff.problems).toEqual([]);
    expect(diff.tablesCompared).toBe(66);
    expect(diff.enumsCompared).toBe(45);
    console.error(
      `[RM-C-006] сверка Drizzle ↔ БД: таблиц ${diff.tablesCompared}, столбцов ${diff.columnsCompared}, enum-ов ${diff.enumsCompared}, расхождений 0`,
    );
  });

  it('6. Drizzle-клиент читает seed (jsonb, generated, text[], enum[])', async () => {
    const pool = new pg.Pool({ connectionString: db.url('pos_c006'), max: 1 });
    try {
      const orm = createDatabase(pool);
      const [setting] = await orm
        .select({ value: schema.appSettings.value })
        .from(schema.appSettings)
        .where(eq(schema.appSettings.key, 'customer_stock_display'));
      expect(setting?.value).toBe('status');
      const [retail] = await orm.select().from(schema.customers).where(eq(schema.customers.isRetailDefault, true));
      expect(retail).toMatchObject({
        name: 'Розничный покупатель',
        phonesNorm: [],
        creditAllowed: false,
        rowVersion: 1,
      });
      const [pl] = await orm.select().from(schema.priceLists).where(eq(schema.priceLists.isDefault, true));
      expect(pl?.visibleToRoles).toEqual(['seller', 'cashier', 'senior_seller', 'admin', 'owner', 'customer']);
      expect(pl?.syncedAt).toBeInstanceOf(Date);
    } finally {
      await pool.end();
    }
  });

  it('7. forward-only: изменённая применённая миграция — ошибка; CRLF — не изменение; сбой файла — откат', async () => {
    const dir = join(tmp, 'migrations-copy');
    cpSync(MIGRATIONS_DIR, dir, { recursive: true });
    // CRLF-копия (checkout на Windows) — та же контрольная сумма
    for (const f of ALL_MIGRATIONS) {
      writeFileSync(join(dir, f), readFileSync(join(MIGRATIONS_DIR, f), 'utf8').replace(/\r?\n/g, '\r\n'));
    }
    expect((await run(env, { seed: false, migrationsDir: dir }, new CaptureLogger())).applied).toEqual([]);

    writeFileSync(join(dir, BROKEN_MIGRATION), 'CREATE TABLE c006_tmp (x int);\nSELECT 1 / 0;\n');
    await expect(run(env, { seed: false, migrationsDir: dir }, new CaptureLogger())).rejects.toMatchObject({
      code: 'MIGRATION_FAILED',
    });
    await withDb('pos_c006', async (c) => {
      expect((await c.query(`SELECT to_regclass('public.c006_tmp') AS t`)).rows[0].t).toBeNull();
      const j = await c.query(`SELECT count(*)::int AS n FROM ${MIGRATIONS_SCHEMA}.${MIGRATIONS_TABLE}`);
      expect(j.rows[0].n).toBe(ALL_MIGRATIONS.length);
    });
    rmSync(join(dir, BROKEN_MIGRATION));

    // Ревью E-trace-8: новый файл с версией меньше последней применённой (заполнение пропуска 0004) — отказ
    // MIGRATION_OUT_OF_ORDER до применения чего-либо (иначе порядок схемы на средах разошёлся бы).
    const gap = ALL_MIGRATIONS.map((f) => Number(f.slice(0, 4))).find((n, i, a) => i > 0 && n - a[i - 1] > 1);
    const gapFile = `${String(gap !== undefined ? gap - 1 : 1).padStart(4, '0')}_c006_gap_fill.sql`;
    expect(ALL_MIGRATIONS).not.toContain(gapFile);
    writeFileSync(join(dir, gapFile), 'CREATE TABLE c006_gap (x int);\n');
    const order = await run(env, { seed: false, migrationsDir: dir }, new CaptureLogger()).catch((e: unknown) => e);
    expect(order).toBeInstanceOf(MigrationError);
    expect(order).toMatchObject({ code: 'MIGRATION_OUT_OF_ORDER' });
    await withDb('pos_c006', async (c) => {
      expect((await c.query(`SELECT to_regclass('public.c006_gap') AS t`)).rows[0].t).toBeNull();
    });
    rmSync(join(dir, gapFile));

    writeFileSync(
      join(dir, '0002_rbac_seed.sql'),
      `${readFileSync(join(dir, '0002_rbac_seed.sql'), 'utf8')}\n-- edit\n`,
    );
    const err = await run(env, { seed: false, migrationsDir: dir }, new CaptureLogger()).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(MigrationError);
    expect(err).toMatchObject({ code: 'MIGRATION_CHECKSUM_MISMATCH' });
  });

  it('8. конфигурация: без DB_MIGRATOR_PASSWORD_FILE — только APP_ENV=dev (пользователь DATABASE_URL, предупреждение)', async () => {
    expect(() => migratorConnection(loadMigratorEnv({ APP_ENV: 'prod', DATABASE_URL: db.url('pos_c006') }))).toThrow(
      MigratorConfigError,
    );
    expect(() => loadMigratorEnv({ APP_ENV: 'dev', DB_MIGRATOR_PASSWORD_FILE: join(tmp, 'нет-файла') })).toThrow(
      MigratorConfigError,
    );
    expect(new URL(migratorConnection(env).connectionString).username).toBe('pos_migrate');

    await su.query(`CREATE DATABASE pos_c006_su ${DB_LOCALE}`);
    const log = new CaptureLogger();
    const devEnv = loadMigratorEnv({
      APP_ENV: 'dev',
      DATABASE_URL: db.url('pos_c006_su'),
      RECEIVABLES_MAX_AGE_MIN: '45',
    });
    const summary = await run(devEnv, { seed: true }, log);
    expect(summary.user).toBe('postgres');
    expect(summary.applied).toEqual(ALL_MIGRATIONS);
    expect(log.lines.filter((l) => l.level === 'warn').map((l) => l.msg)[0]).toContain(
      'DB_MIGRATOR_PASSWORD_FILE не задан',
    );
    await withDb('pos_c006_su', async (c) => {
      const r = await c.query(`SELECT value FROM app_settings WHERE key = 'receivables.max_age_minutes'`);
      expect(r.rows[0].value).toBe(45); // значение по умолчанию — из env RECEIVABLES_MAX_AGE_MIN
    });
  });

  it('9. выгрузка DDL (pg_dump --schema-only недоступен) → docs/erd/schema_v1.sql; DDL воспроизводит схему', async () => {
    const version = (await su.query<{ v: string }>(`SELECT current_setting('server_version') AS v`)).rows[0].v;
    const header = [
      `docs/erd/schema_v1.sql — DDL схемы БД «Оптомстрой POS» после migrations/${ALL_MIGRATIONS.map((m) => m.slice(0, 4)).join('+')}`,
      '(RM-C-006 п. 5). Аналог `pg_dump --schema-only`: в embedded-postgres нет клиента pg_dump, Docker на машине',
      'нет — DDL выгружен из каталога (pg_get_functiondef/pg_get_constraintdef/pg_get_indexdef/pg_get_triggerdef)',
      'скриптом pos-api/test/db/support/schema-dump.ts; проверка — повторное применение к пустой БД даёт тот же',
      'отпечаток схемы (test/db/migrate-seed.db-spec.ts, шаг 9). Без данных (seed — migrations/0002, seeds/*.sql).',
      `PostgreSQL ${version.split(' ')[0]}; app.env=dev (dev_outbox есть; в prod-схеме её нет — B-AR-09); владелец`,
      'объектов — pos_migrate; схема pos_meta — журнал мигратора. Источник истины — migrations/*.sql, не этот файл.',
      'Перегенерация: cd pos-api && UPDATE_SCHEMA_DUMP=1 npx vitest run --config test/db/vitest.config.ts',
    ];
    const ddl = await withDb('pos_c006', (c) => dumpSchema(c, { schemas: SCHEMAS, header }));
    if (process.env['UPDATE_SCHEMA_DUMP'] === '1' || !existsSync(SCHEMA_DUMP_SQL)) {
      writeFileSync(SCHEMA_DUMP_SQL, ddl, 'utf8');
    }
    expect(readFileSync(SCHEMA_DUMP_SQL, 'utf8').replace(/\r\n/g, '\n')).toBe(ddl);

    // DDL применяется к пустой БД под pos_migrate и даёт тот же отпечаток схемы, что миграции
    await su.query(`CREATE DATABASE pos_c006_dump OWNER pos_migrate ${DB_LOCALE}`);
    const conn = migratorConnection({ ...env, DATABASE_URL: db.url('pos_c006_dump') });
    const c = new pg.Client({ connectionString: conn.connectionString });
    await c.connect();
    try {
      await c.query(ddl);
      const replayed = await schemaFingerprint(c, SCHEMAS);
      expect(replayed).toEqual(fingerprintAfterFirst);
    } finally {
      await c.end();
    }
    console.error(`[RM-C-006] schema_v1.sql: ${ddl.split('\n').length} строк; повторное применение → отпечаток совпал`);
  });

  it('11. RM-C-006 п. 6 (AC-DATA-169): вне dev dev-миграции не применяются, DDL dev_outbox нет в migrations/', async () => {
    for (const f of readdirSync(MIGRATIONS_DIR).filter((n) => n.endsWith('.sql'))) {
      expect(readFileSync(join(MIGRATIONS_DIR, f), 'utf8'), f).not.toMatch(/CREATE TABLE.*dev_outbox/);
    }
    await su.query(`CREATE DATABASE pos_c006_stg OWNER pos_migrate ${DB_LOCALE}`);
    const urlFile = join(tmp, 'database_url_stg');
    writeFileSync(urlFile, `${db.url('pos_c006_stg')}\n`);
    const stg = loadMigratorEnv({
      APP_ENV: 'staging',
      LOG_LEVEL: 'silent',
      DATABASE_URL_FILE: urlFile,
      DB_MIGRATOR_PASSWORD_FILE: passwordFile,
    });
    const summary = await run(stg, { seed: false }, new CaptureLogger());
    expect(summary.applied).toEqual(ALL_MIGRATIONS);
    expect(summary.devApplied).toEqual([]);
    await withDb('pos_c006_stg', async (c) => {
      const r = await c.query(
        `SELECT to_regclass('public.dev_outbox') AS t, to_regnamespace('pos_dev') AS dev_journal`,
      );
      expect(r.rows[0]).toEqual({ t: null, dev_journal: null });
      await c.query(readFileSync(CHECK_TABLES_SQL, 'utf8')); // без app.env: 65 таблиц, dev_outbox обязан отсутствовать
    });
  });

  it('10. после migrate → seed API отвечает /health/ready = ok (БД + pg-boss)', async () => {
    let app: INestApplication | undefined;
    try {
      app = await createApp(testConfig({ DATABASE_URL: db.url('pos_c006') }), { logStream: new LogCapture() });
      await app.get(PgBossService).start();
      const ready = await request(app.getHttpServer()).get('/health/ready');
      expect(ready.status).toBe(200);
      expect(ready.body).toMatchObject({ status: 'ok', checks: { db: 'ok', worker: 'ok' } });
    } finally {
      await app?.close();
    }
  });

  it('12. AC-DATA-012 (CI-KI-03): схему pg-boss ставит migrate под pos_migrate; pos_app без DDL, pg-boss под pos_app работает', async () => {
    // 1. Владелец схемы pgboss и всех её объектов — pos_migrate; у pos_app — USAGE и DML, без CREATE и TRUNCATE.
    await withDb('pos_c006', async (c) => {
      const owners = await c.query(
        `SELECT DISTINCT pg_get_userbyid(o) AS owner FROM (
            SELECT nspowner AS o FROM pg_namespace WHERE nspname = 'pgboss'
            UNION ALL SELECT relowner FROM pg_class WHERE relnamespace = 'pgboss'::regnamespace
            UNION ALL SELECT proowner FROM pg_proc WHERE pronamespace = 'pgboss'::regnamespace) x`,
      );
      expect(owners.rows).toEqual([{ owner: 'pos_migrate' }]);
      const priv = await c.query(
        `SELECT has_database_privilege('pos_app', current_database(), 'CREATE') AS db_create,
                has_schema_privilege('pos_app', 'public', 'CREATE') AS public_create,
                has_schema_privilege('pos_app', 'pgboss', 'CREATE') AS boss_create,
                has_schema_privilege('pos_app', 'pgboss', 'USAGE') AS boss_usage,
                has_table_privilege('pos_app', 'pgboss.job', 'INSERT, UPDATE, DELETE') AS job_dml,
                has_table_privilege('pos_app', 'pgboss.job', 'TRUNCATE') AS job_truncate`,
      );
      expect(priv.rows[0]).toEqual({
        db_create: false,
        public_create: false,
        boss_create: false,
        boss_usage: true,
        job_dml: true,
        job_truncate: false,
      });
    });

    // 2. Грант прежнего initdb тестового контура (GRANT CREATE ON DATABASE … TO pos_app) migrate снимает сам.
    await su.query('GRANT CREATE ON DATABASE pos_c006 TO pos_app');
    const again = await run(env, { seed: false }, new CaptureLogger());
    expect(again.pgBoss).toMatchObject({ owner: 'pos_migrate', grantedTo: 'pos_app', revokedDatabaseCreate: true });
    const left = await su.query(`SELECT has_database_privilege('pos_app', 'pos_c006', 'CREATE') AS v`);
    expect(left.rows[0].v).toBe(false);

    // 3. Под pos_app любой DDL — permission denied (42501): новая схема, таблица в pgboss и в public.
    const appPassword = randomBytes(18).toString('base64url');
    await su.query(`ALTER ROLE pos_app PASSWORD '${appPassword}'`);
    const appUrl = new URL(db.url('pos_c006'));
    appUrl.username = 'pos_app';
    appUrl.password = encodeURIComponent(appPassword);
    const app = new pg.Client({ connectionString: appUrl.toString() });
    await app.connect();
    try {
      for (const ddl of [
        'CREATE SCHEMA ac_data_012',
        'CREATE TABLE pgboss.ac_data_012 (x int)',
        'CREATE TABLE public.ac_data_012 (x int)',
      ]) {
        await expect(app.query(ddl), ddl).rejects.toMatchObject({ code: '42501' });
      }
    } finally {
      await app.end();
    }

    // 4. api (PgBossService) и worker (те же опции, что у WorkerRuntime: supervise, schedule) под pos_app: старт
    // без DDL, очередь, задача, расписание, проход обслуживания — без ошибок.
    const api = new PgBossService(appUrl.toString(), { autoStart: false, retryDelayMs: 500 });
    const worker = new PgBoss({
      connectionString: appUrl.toString(),
      application_name: 'ac-data-012:worker',
      supervise: true,
      schedule: true,
      max: 2,
      ...PG_BOSS_RUNTIME_OPTIONS,
    });
    const errors: unknown[] = [];
    worker.on('error', (e: unknown) => errors.push(e));
    try {
      let timer: NodeJS.Timeout | undefined;
      await Promise.race([
        api.start(),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error('PgBossService не стартовал под pos_app за 30 с')), 30_000);
        }),
      ]).finally(() => clearTimeout(timer));
      expect(await api.isReady()).toBe(true);
      const boss = api.instance!;
      await boss.createQueue('ac_data_012');
      const id = await boss.send('ac_data_012', { n: 1 });
      const [job] = await boss.fetch('ac_data_012');
      expect(job?.id).toBe(id);
      await boss.complete('ac_data_012', id!);

      await worker.start();
      await worker.schedule('ac_data_012', '0 3 * * *');
      await worker.supervise();
      expect(errors).toEqual([]);
    } finally {
      await worker.stop({ graceful: false }).catch(() => undefined);
      await api.onApplicationShutdown();
    }

    // 5. Без migrate схемы нет — pg-boss с опциями api/worker её не создаёт даже под суперпользователем.
    await su.query(`CREATE DATABASE pos_c006_noboss OWNER pos_migrate ${DB_LOCALE}`);
    const bare = new PgBoss({ connectionString: db.url('pos_c006_noboss'), ...PG_BOSS_RUNTIME_OPTIONS });
    bare.on('error', () => undefined);
    await expect(bare.start()).rejects.toThrow(/not installed/);
    await bare.stop({ graceful: false }).catch(() => undefined);
    await withDb('pos_c006_noboss', async (c) => {
      expect((await c.query(`SELECT to_regnamespace('pgboss') AS n`)).rows[0].n).toBeNull();
    });
  });

  it('13. база до 2026-11-19 (pgboss у pos_app): migrate отказывает, блок RUNBOOK §3.6 = restore-db.sh переносит владельца, дальше migrate и pg-boss под pos_app работают', async () => {
    // Блок переноса — один и тот же текст в RUNBOOK §3.6 и в restore-db.sh (комментарии и отступы не сравниваются).
    const transfer = heredocAfter(readFileSync(join(POS_API_DIR, '../docs/ops/RUNBOOK.md'), 'utf8'), '### 3.6.');
    const inRestore = heredocAfter(
      readFileSync(join(POS_API_DIR, '../infra/scripts/restore-db.sh'), 'utf8'),
      '# Схема очередей pgboss',
    );
    expect(normalizeSql(transfer)).toBe(normalizeSql(inRestore));
    expect(transfer).toContain('ALTER SCHEMA pgboss OWNER TO pos_migrate');

    // 1. Прежний контур: initdb выдавал pos_app CREATE на базу, схему pgboss создал pg-boss api под pos_app.
    const legacy = 'pos_c006_legacy';
    await su.query(`CREATE DATABASE ${legacy} OWNER pos_migrate ${DB_LOCALE}`);
    await su.query(`GRANT CREATE ON DATABASE ${legacy} TO pos_app`);
    const appPassword = randomBytes(18).toString('base64url');
    await su.query(`ALTER ROLE pos_app PASSWORD '${appPassword}'`);
    const urlAs = (user: string, password: string): string => {
      const u = new URL(db.url(legacy));
      u.username = user;
      u.password = encodeURIComponent(password);
      return u.toString();
    };
    const appUrl = urlAs('pos_app', appPassword);
    const migUrl = urlAs('pos_migrate', migratorPassword);
    // Опции pg-boss api до 2026-11-19: migrate и createSchema по умолчанию (true).
    const oldBoss = (): PgBoss => {
      const b = new PgBoss({ connectionString: appUrl, schema: 'pgboss', supervise: false, schedule: false, max: 2 });
      b.on('error', () => undefined);
      return b;
    };
    /** Объекты схемы pgboss (сама схема, отношения, функции, типы) с владельцем не `owner`: «вид имя (владелец)». */
    const ownedByOthers = (owner: string): Promise<string[]> =>
      withDb(legacy, async (c) =>
        (
          await c.query<{ obj: string }>(
            `SELECT kind || ' ' || name || ' (' || pg_get_userbyid(o) || ')' AS obj FROM (
                SELECT 'schema' AS kind, nspname::text AS name, nspowner AS o FROM pg_namespace WHERE nspname = 'pgboss'
                UNION ALL SELECT 'rel:' || relkind::text, oid::regclass::text, relowner FROM pg_class
                 WHERE relnamespace = 'pgboss'::regnamespace
                UNION ALL SELECT 'routine', oid::regprocedure::text, proowner FROM pg_proc
                 WHERE pronamespace = 'pgboss'::regnamespace
                UNION ALL SELECT 'type:' || typtype::text, oid::regtype::text, typowner FROM pg_type
                 WHERE typnamespace = 'pgboss'::regnamespace) x
              WHERE pg_get_userbyid(o) <> $1 ORDER BY 1`,
            [owner],
          )
        ).rows.map((r) => r.obj),
      );
    const before = oldBoss();
    await before.start();
    await before.createQueue('legacy_q');
    const legacyJob = await before.send('legacy_q', { n: 1 });
    await before.stop({ graceful: false });
    expect(await ownedByOthers('pos_app')).toEqual([]);

    // 2. migrate нового релиза останавливается до каких-либо изменений (PGBOSS_FOREIGN_OWNER).
    const installAsMigrator = async () => {
      const mig = new pg.Client({ connectionString: migUrl });
      await mig.connect();
      try {
        return await installPgBoss(mig, migUrl, { logger: new CaptureLogger() });
      } finally {
        await mig.end();
      }
    };
    await expect(installAsMigrator()).rejects.toMatchObject({ code: 'PGBOSS_FOREIGN_OWNER' });
    expect(await ownedByOthers('pos_app')).toEqual([]);

    // 3. Блок §3.6 под суперпользователем, дважды (идемпотентен). Прежний pg-boss под pos_app работает и после
    // переноса: схему он не меняет, права на объекты выданы в той же транзакции; задача из шага 1 цела.
    await withDb(legacy, async (c) => {
      await c.query(transfer);
      await c.query(transfer);
    });
    expect(await ownedByOthers('pos_migrate')).toEqual([]);
    const after = oldBoss();
    try {
      await after.start();
      const [job] = await after.fetch('legacy_q');
      expect(job?.id).toBe(legacyJob);
      await after.complete('legacy_q', job.id);
    } finally {
      await after.stop({ graceful: false });
    }

    // 4. migrate: схема актуальна, права pos_app выданы, право CREATE на базу снято (07 DATA-012).
    const installed = await installAsMigrator();
    expect(installed).toMatchObject({ owner: 'pos_migrate', grantedTo: 'pos_app', revokedDatabaseCreate: true });
    expect(installed.before).toBe(installed.version);
    const priv = await su.query(`SELECT has_database_privilege('pos_app', '${legacy}', 'CREATE') AS db_create`);
    expect(priv.rows[0]).toEqual({ db_create: false });

    // 5. pg-boss api (без DDL, PG_BOSS_RUNTIME_OPTIONS) под pos_app: старт и очередь прежнего контура.
    const api = new PgBossService(appUrl, { autoStart: false, retryDelayMs: 500 });
    try {
      let timer: NodeJS.Timeout | undefined;
      await Promise.race([
        api.start(),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error('PgBossService не стартовал под pos_app за 30 с')), 30_000);
        }),
      ]).finally(() => clearTimeout(timer));
      expect(await api.isReady()).toBe(true);
      const boss = api.instance!;
      const id = await boss.send('legacy_q', { n: 2 });
      const [job] = await boss.fetch('legacy_q');
      expect(job?.id).toBe(id);
    } finally {
      await api.onApplicationShutdown();
    }
  });
});

/** Текст here-doc `<<'SQL' … SQL` после метки (блок переноса владельца pgboss: RUNBOOK §3.6, restore-db.sh). */
function heredocAfter(text: string, marker: string): string {
  const t = text.replace(/\r\n/g, '\n');
  const at = t.indexOf(marker);
  expect(at, marker).toBeGreaterThanOrEqual(0);
  const open = t.indexOf("<<'SQL'\n", at);
  expect(open, `${marker}: нет <<'SQL'`).toBeGreaterThan(at);
  const start = open + "<<'SQL'\n".length;
  const end = t.indexOf('\nSQL\n', start);
  expect(end, `${marker}: нет строки SQL`).toBeGreaterThan(start);
  return t.slice(start, end + 1);
}

/** SQL без комментариев `--` и с одним пробелом вместо любой последовательности пробельных символов. */
function normalizeSql(sql: string): string {
  return sql
    .replace(/--[^\n]*/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

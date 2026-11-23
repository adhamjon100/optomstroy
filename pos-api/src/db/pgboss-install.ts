import { setTimeout as delay } from 'node:timers/promises';
import { PgBoss } from 'pg-boss';
import type pg from 'pg';
import { PG_BOSS_SCHEMA } from '../common/jobs/pg-boss-runtime.js';
import { MigrationError, type MigrationLogger } from './migrator.js';

/**
 * Установка и обновление схемы pg-boss мигратором (07 DATA-012, AC-DATA-012; docs/ci.md CI-KI-03 — закрыт
 * 2026-11-19). Раньше схему `pgboss` создавали api и worker при старте под `pos_app`, поэтому контуру приходилось
 * выдавать `pos_app` право CREATE на базу. Теперь:
 * - `migrate` после SQL-миграций ставит или обновляет схему под своей ролью (в рабочем контуре — `pos_migrate`,
 *   она же владелец схемы и её объектов), дожидается асинхронных шагов миграции pg-boss (BAM) и выдаёт `pos_app`
 *   только USAGE на схему и DML/EXECUTE на её объекты, плюс те же права по умолчанию на будущие объекты;
 * - api и worker запускают pg-boss с `migrate: false, createSchema: false` (`PG_BOSS_RUNTIME_OPTIONS`) — только
 *   проверка, что схема установлена и её версия совпадает с пакетом;
 * - право CREATE на базу у `pos_app`, оставшееся от прежнего initdb тестового контура, мигратор снимает, если он
 *   владелец базы; иначе — предупреждение.
 *
 * Схема, которой владеет другая роль (контуры, поднятые до 2026-11-19: владелец `pos_app`), — ошибка
 * `PGBOSS_FOREIGN_OWNER` до каких-либо изменений: владельца один раз переносит суперпользователь
 * (docs/ops/RUNBOOK.md §3.6; `restore-db.sh` делает это сам для копий таких контуров).
 *
 * Повторный запуск — 0 изменений: схема актуальна, GRANT тех же прав ничего не меняет.
 */

/** Роль приложения (07 §2.1): DML на объекты pg-boss. */
export const PG_BOSS_APP_ROLE = 'pos_app';
/** Предел ожидания асинхронных шагов миграции pg-boss (построение индексов BAM). */
const DEFAULT_BAM_TIMEOUT_MS = 15 * 60_000;
const BAM_POLL_MS = 250;
const IDENT_RE = /^[a-z_][a-z0-9_]*$/;

export interface PgBossInstallOptions {
  readonly logger: MigrationLogger;
  /** Схема pg-boss (по умолчанию `pgboss`, как у api и worker). */
  readonly schema?: string;
  /** Роль приложения, которой выдаются права (по умолчанию `pos_app`). */
  readonly appRole?: string;
  readonly bamTimeoutMs?: number;
}

export interface PgBossInstallResult {
  readonly schema: string;
  /** Версия схемы pg-boss до шага; `null` — схемы не было. */
  readonly before: number | null;
  readonly version: number;
  /** Владелец схемы после шага (рабочий контур — `pos_migrate`). */
  readonly owner: string;
  /** Кому выданы права DML; `null` — роли приложения нет (возможно только в dev). */
  readonly grantedTo: string | null;
  /** Снято ли этим запуском право CREATE на базу у роли приложения (след прежнего initdb). */
  readonly revokedDatabaseCreate: boolean;
}

/**
 * Ставит или обновляет схему pg-boss и выдаёт права роли приложения. `client` — соединение мигратора (права,
 * проверки владельца); `connectionString` — та же роль для одноразового экземпляра pg-boss.
 */
export async function installPgBoss(
  client: pg.ClientBase,
  connectionString: string,
  options: PgBossInstallOptions,
): Promise<PgBossInstallResult> {
  const schema = ident(options.schema ?? PG_BOSS_SCHEMA);
  const appRole = ident(options.appRole ?? PG_BOSS_APP_ROLE);
  const { logger } = options;

  await assertMigratorOwnsSchema(client, schema);
  const before = await installedVersion(client, schema);
  const version = await startOnce(connectionString, schema, options.bamTimeoutMs ?? DEFAULT_BAM_TIMEOUT_MS, logger);
  const owner = (
    await client.query<{ owner: string }>(
      'SELECT pg_get_userbyid(nspowner) AS owner FROM pg_namespace WHERE nspname = $1',
      [schema],
    )
  ).rows[0]?.owner;
  if (owner === undefined) {
    throw new MigrationError('PGBOSS_INSTALL_FAILED', `pg-boss: после установки нет схемы ${schema}`);
  }
  const grantedTo = await grantAppRole(client, schema, appRole, logger);
  const revokedDatabaseCreate = await revokeDatabaseCreate(client, appRole, logger);
  logger.info(
    { schema, before, version, owner, grantedTo },
    before === null
      ? 'pg-boss: схема установлена'
      : before === version
        ? 'pg-boss: 0 изменений (схема актуальна)'
        : 'pg-boss: схема обновлена',
  );
  return { schema, before, version, owner, grantedTo, revokedDatabaseCreate };
}

function ident(name: string): string {
  if (!IDENT_RE.test(name)) throw new MigrationError('PGBOSS_INSTALL_FAILED', `pg-boss: недопустимое имя «${name}»`);
  return name;
}

/** Схема и её объекты должны принадлежать роли мигратора (или роли, правами которой он обладает). */
async function assertMigratorOwnsSchema(client: pg.ClientBase, schema: string): Promise<void> {
  const r = await client.query<{ me: string; owner: string; own: boolean; foreign: number }>(
    `SELECT current_user AS me, pg_get_userbyid(n.nspowner) AS owner,
            pg_has_role(current_user, n.nspowner, 'USAGE') AS own,
            (SELECT count(*) FROM pg_class c
              WHERE c.relnamespace = n.oid AND NOT pg_has_role(current_user, c.relowner, 'USAGE'))::int
          + (SELECT count(*) FROM pg_proc p
              WHERE p.pronamespace = n.oid AND NOT pg_has_role(current_user, p.proowner, 'USAGE'))::int AS foreign
       FROM pg_namespace n WHERE n.nspname = $1`,
    [schema],
  );
  const row = r.rows[0];
  if (row === undefined || (row.own && row.foreign === 0)) return;
  throw new MigrationError(
    'PGBOSS_FOREIGN_OWNER',
    `схема ${schema} или её объекты (${row.foreign}) принадлежат роли ${row.owner}, а не ${row.me}: pg-boss ставит ` +
      `и обновляет только мигратор (07 DATA-012). Один раз перенесите владельца под суперпользователем ` +
      `(docs/ops/RUNBOOK.md §3.6) и повторите migrate`,
  );
}

async function installedVersion(client: pg.ClientBase, schema: string): Promise<number | null> {
  const exists = await client.query<{ t: string | null }>(`SELECT to_regclass($1)::text AS t`, [`${schema}.version`]);
  const table = exists.rows[0]?.t;
  if (table === undefined || table === null) return null;
  const v = await client.query<{ version: number | string }>(`SELECT version FROM ${schema}.version`);
  const raw = v.rows[0]?.version;
  return raw === undefined ? null : Number(raw);
}

/**
 * Одноразовый экземпляр pg-boss под ролью мигратора: создаёт схему или выполняет миграции пакета (как раньше
 * делали api и worker), ждёт асинхронные шаги (BAM — у api и worker с `migrate: false` они не выполняются) и
 * останавливается. Без обслуживания, расписаний и записи в реестр экземпляров.
 */
async function startOnce(
  connectionString: string,
  schema: string,
  bamTimeoutMs: number,
  logger: MigrationLogger,
): Promise<number> {
  const boss = new PgBoss({
    connectionString,
    schema,
    application_name: 'pos-migrate:pg-boss',
    migrate: true,
    createSchema: true,
    supervise: false,
    schedule: false,
    registerInstance: false,
    max: 2,
  });
  let background: unknown;
  boss.on('error', (err: unknown) => {
    background ??= err;
  });
  try {
    await boss.start();
  } catch (e) {
    await boss.stop({ graceful: false }).catch(() => undefined);
    throw new MigrationError('PGBOSS_INSTALL_FAILED', `pg-boss: установка схемы ${schema} не удалась: ${message(e)}`, {
      cause: e,
    });
  }
  try {
    await waitForBam(boss, bamTimeoutMs, logger);
    if (background !== undefined) {
      throw new MigrationError('PGBOSS_INSTALL_FAILED', `pg-boss: ошибка при установке схемы: ${message(background)}`, {
        cause: background,
      });
    }
    const version = await boss.schemaVersion();
    if (version === null) throw new MigrationError('PGBOSS_INSTALL_FAILED', `pg-boss: нет версии схемы ${schema}`);
    return version;
  } finally {
    await boss.stop({ graceful: true, timeout: 10_000 }).catch(() => undefined);
  }
}

async function waitForBam(boss: PgBoss, timeoutMs: number, logger: MigrationLogger): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const rows = await boss.getBamStatus();
    const count = (s: string): number => rows.filter((r) => r.status === s).reduce((n, r) => n + Number(r.count), 0);
    const open = count('pending') + count('in_progress');
    if (open === 0 && !boss.isBamWorking()) {
      const failed = count('failed');
      if (failed > 0) {
        logger.warn(
          { failed },
          'pg-boss: есть неудавшиеся асинхронные шаги миграции схемы (getBamEntries) — разобрать вручную',
        );
      }
      return;
    }
    if (Date.now() > deadline) {
      throw new MigrationError(
        'PGBOSS_INSTALL_FAILED',
        `pg-boss: асинхронные шаги миграции схемы не завершились за ${Math.round(timeoutMs / 1000)} с ` +
          `(осталось ${open}); повторите migrate — они продолжатся`,
      );
    }
    await delay(BAM_POLL_MS);
  }
}

/**
 * Права роли приложения: USAGE на схему, DML на таблицы, последовательности, EXECUTE на функции; те же права по
 * умолчанию на объекты, которые роль мигратора создаст при следующем обновлении pg-boss. TRUNCATE, CREATE и
 * владения у `pos_app` нет (DATA-012). Все команды — одной неявной транзакцией.
 */
async function grantAppRole(
  client: pg.ClientBase,
  schema: string,
  role: string,
  logger: MigrationLogger,
): Promise<string | null> {
  const exists = await client.query('SELECT 1 FROM pg_roles WHERE rolname = $1', [role]);
  if (exists.rowCount === 0) {
    logger.warn({ role, schema }, `pg-boss: роли ${role} нет — права на схему ${schema} не выданы`);
    return null;
  }
  await client.query(
    [
      `GRANT USAGE ON SCHEMA ${schema} TO ${role}`,
      `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ${schema} TO ${role}`,
      `GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ${schema} TO ${role}`,
      `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ${schema} TO ${role}`,
      `ALTER DEFAULT PRIVILEGES IN SCHEMA ${schema} GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${role}`,
      `ALTER DEFAULT PRIVILEGES IN SCHEMA ${schema} GRANT USAGE, SELECT ON SEQUENCES TO ${role}`,
      `ALTER DEFAULT PRIVILEGES IN SCHEMA ${schema} GRANT EXECUTE ON FUNCTIONS TO ${role}`,
    ].join(';\n'),
  );
  return role;
}

/** Снимает CREATE на базу у роли приложения (отклонение прежнего initdb, CI-KI-03), если мигратор — владелец базы. */
async function revokeDatabaseCreate(client: pg.ClientBase, role: string, logger: MigrationLogger): Promise<boolean> {
  const check = async (): Promise<{ has: boolean; owner: boolean; db: string } | undefined> =>
    (
      await client.query<{ has: boolean; owner: boolean; db: string }>(
        `SELECT has_database_privilege(r.oid, d.oid, 'CREATE') AS has,
                pg_has_role(current_user, d.datdba, 'USAGE') AS owner, d.datname AS db
           FROM pg_database d, pg_roles r
          WHERE d.datname = current_database() AND r.rolname = $1`,
        [role],
      )
    ).rows[0];
  const before = await check();
  if (before === undefined || !before.has) return false;
  if (before.owner) {
    await client.query(`REVOKE CREATE ON DATABASE "${before.db.replace(/"/g, '""')}" FROM ${role}`);
    if ((await check())?.has === false) {
      logger.info({ role, database: before.db }, `pg-boss: у ${role} снято право CREATE на базу (07 DATA-012)`);
      return true;
    }
  }
  logger.warn(
    { role, database: before.db },
    `у ${role} есть право CREATE на базу (отклонение 07 DATA-012): снимите его под суперпользователем — ` +
      'docs/ops/RUNBOOK.md §3.6',
  );
  return false;
}

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

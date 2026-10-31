// Построитель БД снимка веб-демо (WP-B4; plan §3.5 «Снимок, собираемый при сборке»). Собирается esbuild для Node
// (snapshot/build-snapshot.mjs → .build/snapshot/builder.mjs) теми же подменами модулей, что backend.js
// (lib/alias-plugin.mjs: pg → alias/pg-shim.mjs поверх одного PGlite, pino → alias/pino.mjs, замена ПДн синтетики
// кассира), но встроенные модули Node и sharp — настоящие (фото обрабатывает pos-api ImageDirectoryImporter с sharp
// только здесь, при сборке; в backend.js sharp — заглушка). PGlite 0.3.16 — тот же, что в браузере, без портов.
//
// Шаги (как холодный старт воркера, demo-init.mjs):
//  1. настоящие migrate (pos-api/migrations, db/migrations-dev) и seed (pos-api/seeds);
//  2. сотрудники стенда 901/906/907/909 и служебные учётки сида 981/986/987 «Демо-история …» (demo-config.mjs);
//  3. каталог настоящим конвейером: CatalogFullLoadService + SyntheticCatalogSource(FakeOnecGateway({catalog:
//     {skuCount, seed}, includeFixtureCatalog: false})) — без подмеса фикстур;
//  4. фото: синтетические JPEG (их готовит build-snapshot.mjs) → ImageDirectoryImporter (раскладка by-name) →
//     product_images и файлы MEDIA_DIR/images/{sha}/{thumb|card|full}.webp — в ОДНОМ прогоне с данными.
// Приглашение 902, OTP, сессии, секреты и состояние имитатора 1С в снимок не попадают: их создаёт воркер на каждом
// старте (critic [2]).
import * as pgShim from '../alias/pg-shim.mjs';
import { pino } from '../alias/pino.mjs';
import { SEED_ACCOUNTS, STAFF } from '../demo-config.mjs';
import { ensureUsers } from './data-steps.mjs';
import { resetDeterministicIds } from './det-ids.mjs';

import { migrate, seed, DEV_MIGRATIONS_SCHEMA } from '@pos-api-dist/db/migrator.js';
import { FakeOnecGateway } from '@pos-api-dist/integrations/onec/fake-onec.gateway.js';
import { CatalogApplier } from '@pos-api-dist/sync/apply/catalog-applier.js';
import { CatalogFullLoadService } from '@pos-api-dist/sync/apply/catalog-full-load.service.js';
import { SyntheticCatalogSource } from '@pos-api-dist/sync/apply/catalog-source.js';
import { createRunTracker } from '@pos-api-dist/sync/apply/run-tracker.js';
import { ImageDirectoryImporter } from '@pos-api-dist/sync/images/image-directory-import.js';
import { ImageStore } from '@pos-api-dist/sync/images/image-store.js';

const pg = pgShim.default;

/** Схемы детерминированной сборки (только в БД построителя, в снимок не выгружаются). */
export const BUILD_ONLY_SCHEMAS = ['demo_det', 'demo_ext'];

/**
 * Детерминированная сборка: два прогона дают одинаковые строки (manifest.json и ключ эпохи не меняются от
 * пересборки). Часы БД (now/clock_timestamp/…) и gen_random_uuid() — из схемы demo_det: now() = T0,
 * clock_timestamp() = T0 + n мкс, gen_random_uuid() = v4 из md5(номер). pgcrypto ставится заранее в demo_ext (иначе его
 * public.gen_random_uuid() стоял бы в search_path раньше demo_det); миграция `CREATE EXTENSION IF NOT EXISTS pgcrypto`
 * его уже не трогает. Таблицы миграций создаются в public (первая схема пути). JS-идентификаторы (dist newId) —
 * snapshot/det-ids.mjs. Схема БД снимка от этого не меняется: в браузере данные ложатся в схему настоящих миграций.
 */
async function deterministicSession(db, t0Iso) {
  const t0 = `'${t0Iso}'::timestamptz`;
  await db.exec(`
    CREATE SCHEMA demo_det;
    CREATE SCHEMA demo_ext;
    CREATE EXTENSION pgcrypto SCHEMA demo_ext;
    CREATE SEQUENCE demo_det.clk;
    CREATE SEQUENCE demo_det.rnd;
    CREATE FUNCTION demo_det.now() RETURNS timestamptz LANGUAGE sql STABLE AS $$ SELECT ${t0} $$;
    CREATE FUNCTION demo_det.transaction_timestamp() RETURNS timestamptz LANGUAGE sql STABLE AS $$ SELECT ${t0} $$;
    CREATE FUNCTION demo_det.statement_timestamp() RETURNS timestamptz LANGUAGE sql STABLE AS $$ SELECT ${t0} $$;
    CREATE FUNCTION demo_det.clock_timestamp() RETURNS timestamptz LANGUAGE sql VOLATILE AS $$ SELECT ${t0} + nextval('demo_det.clk') * interval '1 microsecond' $$;
    -- настоящий формат v4 (версия 4, вариант 10xx): uuid_generate_v7() ставит поверх версию 7, и id проходят проверку
    -- формата UUID (zod/class-validator: версия 1–8, вариант 8–b), как в обычной сборке
    CREATE FUNCTION demo_det.gen_random_uuid() RETURNS uuid LANGUAGE sql VOLATILE AS $$
      SELECT (substr(h, 1, 12) || '4' || substr(h, 14, 3) || substr('89ab', (('x' || substr(h, 17, 1))::bit(4)::int % 4) + 1, 1) || substr(h, 18, 15))::uuid
        FROM (SELECT md5('pos-demo-snapshot/db/' || nextval('demo_det.rnd')) AS h) s
    $$;
    SET search_path = public, demo_det, demo_ext, pg_catalog;
  `);
}

/**
 * Миграции, seeds, сотрудники, каталог. db — PGlite (memory://) с расширениями pgcrypto, pg_trgm, unaccent.
 * o: { dirs: {migrations, devMigrations, seeds, fixtures}, sku, catalogSeed, includeFixtureCatalog, t0 (ISO),
 *      deterministic (по умолчанию true; false — обычная сборка для S1), seedParams, log(level, msg) }
 */
export async function buildDb(db, o) {
  globalThis.__posDemoLog = o.log;
  const det = o.deterministic !== false;
  if (det) await deterministicSession(db, o.t0);
  // Обычная сборка (S1 для сравнения): JS-идентификаторы от реального времени, часы БД настоящие.
  resetDeterministicIds(det ? Date.parse(o.t0) : Date.now());
  pgShim.attachPglite(db);
  const quiet = { info() {}, warn: (x, m) => o.log('warn', `migrate: ${m ?? ''} ${JSON.stringify(x)}`) };
  const T = {};
  let t = performance.now();
  const mc = new pg.Client({ application_name: 'snapshot-build' });
  const r1 = await migrate(mc, { dir: o.dirs.migrations, appEnv: 'dev', logger: quiet });
  const r2 = await migrate(mc, { dir: o.dirs.devMigrations, appEnv: 'dev', logger: quiet, journalSchema: DEV_MIGRATIONS_SCHEMA });
  T.migrations = [...(r1?.applied ?? []), ...(r2?.applied ?? [])].length;
  T.migrateMs = Math.round(performance.now() - t);
  // Таблицы, которые заполнили сами миграции (роли, права, аудит, узел обмена…): в браузере их строки перед COPY
  // удаляются (DELETE), остальные таблицы после настоящих миграций пусты — без TRUNCATE и новых файлов отношений.
  const rel = await db.query(`SELECT n.nspname AS s, c.relname AS t FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p') AND n.nspname = ANY($1::text[]) ORDER BY 1, 2`, [o.schemas ?? ['public', 'catalog_sync']]);
  T.migrationRows = [];
  for (const r of rel.rows) {
    const n = Number((await db.query(`SELECT count(*)::bigint AS n FROM "${r.s}"."${r.t}"`)).rows[0].n);
    if (n > 0) T.migrationRows.push({ table: `${r.s}.${r.t}`, rows: n });
  }

  t = performance.now();
  const s = await seed(mc, { dir: o.dirs.seeds, logger: quiet, params: o.seedParams });
  T.seedInserted = s?.inserted ?? null;
  await mc.query('BEGIN');
  T.staffCreated = await ensureUsers(mc, STAFF);
  T.seedAccountsCreated = await ensureUsers(mc, SEED_ACCOUNTS);
  await mc.query('COMMIT');
  T.seedMs = Math.round(performance.now() - t);

  t = performance.now();
  const gw = new FakeOnecGateway({
    fixturesDir: o.dirs.fixtures,
    catalog: { skuCount: o.sku, seed: o.catalogSeed },
    includeFixtureCatalog: o.includeFixtureCatalog,
    registerAll: false,
  });
  const pool = new pg.Pool({ application_name: 'snapshot-catalog' });
  const runs = createRunTracker(pool);
  const results = await new CatalogFullLoadService(pool, new CatalogApplier(), runs, pino({ level: 'silent' }), det ? () => new Date(o.t0) : () => new Date()).loadAll(new SyntheticCatalogSource(gw), 'full', 'manual');
  T.catalog = results.map((r) => ({ entity: r.entity, status: r.status }));
  T.catalogMs = Math.round(performance.now() - t);
  return { timings: T, pool, runs };
}

/** Фото: каталог dir с файлами `<onec_ref>.jpg` → ImageDirectoryImporter → product_images + mediaDir/images/**. */
export async function importPhotos(ctx, { dir, mediaDir }) {
  const t = performance.now();
  const r = await new ImageDirectoryImporter(ctx.pool, new ImageStore(mediaDir), ctx.runs, pino({ level: 'silent' })).run({ dir, layout: 'by-name', trigger: 'manual' });
  return { ms: Math.round(performance.now() - t), status: r.status, counts: r.counts };
}

export { pgShim };

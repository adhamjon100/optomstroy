/**
 * Синтетический каталог N SKU в БД через конвейер применения 1С (RM-E-001 → бенчмарк поиска RM-E-005 / NFR-PERF-001,
 * 13 §3.5). **Тестовые данные**: реальных товаров, цен и клиентов нет; одинаковый `--seed` даёт одинаковый каталог.
 *
 *   # в существующую БД (миграции уже применены; APP_ENV=dev|staging):
 *   APP_ENV=dev DATABASE_URL=postgres://… npx tsx scripts/seed_synthetic_catalog.ts --sku 50000 --seed 1
 *   # в одноразовый embedded PostgreSQL 17 (миграции применяются; кластер удаляется по завершении):
 *   npx tsx scripts/seed_synthetic_catalog.ts --embedded --sku 50000 [--report .tmp/seed.json]
 *
 * Параметры: `--sku` (по умолчанию 50000), `--seed` (1), `--warehouses` (3), `--price-lists` (3),
 * `--variant-share` (0.2), `--packaging-share` (0.3), `--page-size` (1000), `--report <файл JSON>`,
 * `--force` — разрешить запись в БД, где уже есть не синтетические товары (иначе отказ, код 2).
 *
 * Отказ (код 2): `APP_ENV=prod` или не задан при работе с внешней БД; БД без таблиц каталога.
 * Итог — таблица времени по сущностям и счётчики в stdout; код 0 — без ошибок позиций, 1 — есть ошибки.
 * В prod-образ не входит (каталог `scripts/` в образ не копируется).
 */
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import pg from 'pg';
import pino from 'pino';
import { SyntheticCatalog } from '../src/integrations/onec/synthetic-catalog.js';
import { loadSyntheticCatalog } from '../src/sync/apply/synthetic-load.js';
import { allMigrations } from '../test/support/catalog-fixture.js';
import { EmbeddedPg } from '../test/support/embedded-pg.js';

export interface SeedReport {
  readonly sku: number;
  readonly seed: number;
  readonly generateMs: number;
  readonly loadMs: number;
  readonly totalMs: number;
  readonly stats: Record<string, number>;
  readonly entities: readonly {
    entity: string;
    status: string;
    ms?: number;
    inserted: number;
    updated: number;
    skipped: number;
    errors: number;
  }[];
  readonly db: Record<string, number>;
  readonly errors: number;
}

const out = (line: string): boolean =>
  process.stdout.write(`${line}
`);

function num(v: string | undefined, def: number, name: string): number {
  if (v === undefined) return def;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw new Error(`--${name}: ожидается число ≥ 0`);
  return n;
}

export async function main(argv = process.argv.slice(2)): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      sku: { type: 'string' },
      seed: { type: 'string' },
      warehouses: { type: 'string' },
      'price-lists': { type: 'string' },
      'variant-share': { type: 'string' },
      'packaging-share': { type: 'string' },
      'page-size': { type: 'string' },
      report: { type: 'string' },
      embedded: { type: 'boolean', default: false },
      force: { type: 'boolean', default: false },
    },
    strict: true,
  });
  const sku = Math.floor(num(values.sku, 50_000, 'sku'));
  const seed = Math.floor(num(values.seed, 1, 'seed'));
  let embedded: EmbeddedPg | undefined;
  let url = process.env.DATABASE_URL;
  if (values.embedded) {
    embedded = new EmbeddedPg();
    await embedded.start();
    await embedded.createDatabase('pos_seed');
    await embedded.migrate('pos_seed', allMigrations());
    url = embedded.url('pos_seed');
  } else {
    const env = process.env.APP_ENV;
    if (env !== 'dev' && env !== 'staging') {
      console.error('seed_synthetic_catalog: APP_ENV должен быть dev или staging (синтетика в prod запрещена)');
      return 2;
    }
    if (!url) {
      console.error('seed_synthetic_catalog: не задан DATABASE_URL (или используйте --embedded)');
      return 2;
    }
  }
  const pool = new pg.Pool({ connectionString: url, max: 4 });
  try {
    const exists = await pool.query<{ ok: boolean }>(`SELECT to_regclass('public.products') IS NOT NULL AS ok`);
    if (!exists.rows[0]?.ok) {
      console.error('seed_synthetic_catalog: в БД нет таблиц каталога — сначала миграции (npm run migrate)');
      return 2;
    }
    const g0 = performance.now();
    const catalog = new SyntheticCatalog({
      skuCount: sku,
      seed,
      warehouses: Math.floor(num(values.warehouses, 3, 'warehouses')),
      priceLists: Math.floor(num(values['price-lists'], 3, 'price-lists')),
      variantShare: num(values['variant-share'], 0.2, 'variant-share'),
      packagingShare: num(values['packaging-share'], 0.3, 'packaging-share'),
    });
    const generateMs = performance.now() - g0;
    if (!values.force) {
      // Синтетические ссылки начинаются с hex(seed); чужие товары в БД → отказ (не смешивать с реальной репликой).
      const prefix = catalog.ref('product', 0).slice(0, 8);
      const foreign = await pool.query<{ n: string }>(
        `SELECT count(*)::text AS n FROM products WHERE onec_ref IS NOT NULL AND left(onec_ref::text, 8) <> $1
            AND onec_ref::text NOT LIKE 'a1b2c3d4-%'`,
        [prefix],
      );
      if (Number(foreign.rows[0]?.n ?? 0) > 0) {
        console.error(
          'seed_synthetic_catalog: в БД есть не синтетические товары — запись отменена (--force, чтобы разрешить)',
        );
        return 2;
      }
    }
    const t0 = performance.now();
    const timings = new Map<string, number>();
    let last = performance.now();
    const log = pino(
      { level: 'info' },
      {
        write: (line: string) => {
          const e = JSON.parse(line) as { msg?: string; entity?: string };
          if (e.msg === 'sync.catalog.loaded' && e.entity) {
            const now = performance.now();
            timings.set(e.entity, now - last);
            last = now;
          }
        },
      },
    );
    console.error(`seed_synthetic_catalog: генерация ${sku} SKU (seed ${seed}) и загрузка через конвейер 1С…`);
    const r = await loadSyntheticCatalog(pool, {
      catalog,
      log,
      pageSize: Math.floor(num(values['page-size'], 1000, 'page-size')),
    });
    const totalMs = performance.now() - t0 + generateMs;
    const db = await pool.query<Record<string, string>>(
      `SELECT (SELECT count(*) FROM products)::text AS products, (SELECT count(*) FROM product_variants)::text AS variants,
              (SELECT count(*) FROM barcodes)::text AS barcodes, (SELECT count(*) FROM prices)::text AS prices,
              (SELECT count(*) FROM stock_balances)::text AS stock_balances, (SELECT count(*) FROM categories)::text AS categories,
              (SELECT count(*) FROM packagings)::text AS packagings, (SELECT count(*) FROM variant_attribute_values)::text AS attribute_values,
              (SELECT count(*) FROM sync_errors)::text AS sync_errors`,
    );
    const report: SeedReport = {
      sku,
      seed,
      generateMs: Math.round(generateMs),
      loadMs: Math.round(r.loadMs),
      totalMs: Math.round(totalMs),
      stats: { ...r.stats },
      entities: r.results.map((x) => ({
        entity: x.entity,
        status: x.status,
        ...(timings.has(x.entity) ? { ms: Math.round(timings.get(x.entity)!) } : {}),
        inserted: x.counts?.inserted ?? 0,
        updated: x.counts?.updated ?? 0,
        skipped: x.counts?.skipped ?? 0,
        errors: x.counts?.errors ?? 0,
      })),
      db: Object.fromEntries(Object.entries(db.rows[0] ?? {}).map(([k, v]) => [k, Number(v)])),
      errors: r.results.reduce((n, x) => n + (x.counts?.errors ?? 0), 0),
    };
    for (const e of report.entities) {
      out(
        `${e.entity.padEnd(11)} ${e.status.padEnd(8)} ${String(e.ms ?? '').padStart(7)} мс  +${e.inserted} ~${e.updated} =${e.skipped} !${e.errors}`,
      );
    }
    out(
      `ИТОГ: ${sku} SKU, генерация ${report.generateMs} мс, загрузка ${report.loadMs} мс, всего ${report.totalMs} мс`,
    );
    out(`БД: ${JSON.stringify(report.db)}`);
    if (values.report) writeFileSync(values.report, JSON.stringify(report, null, 2));
    return report.errors > 0 ? 1 : 0;
  } finally {
    await pool.end();
    await embedded?.stop();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().then(
    (code) => process.exit(code),
    (e: unknown) => {
      console.error('seed_synthetic_catalog: ошибка', e instanceof Error ? e.message : e);
      process.exit(2);
    },
  );
}

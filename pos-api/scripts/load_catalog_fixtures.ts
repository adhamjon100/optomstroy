/**
 * Загрузка каталога «на фикстурах» (RM-E-011; интеграция этапа E): **полная синхронизация через `FakeOnecGateway`**
 * (фикстуры `contracts/onec/fixtures` + N синтетических SKU) тем же конвейером, что в pos-worker
 * (`CatalogFullLoadService` → `CatalogApplier`, прогоны `sync_runs`, сверка `$count` SYNC-003), затем сверка
 * `$count` по сущностям (`CountCheckService`) и прямые подсчёты срезов, затем загрузка **синтетических** фото
 * разовым импортом (`ImageDirectoryImporter`, раскладка `by-name`, 05 SYNC-036) в `MEDIA_DIR/images/{sha}/{size}.webp`.
 * **Тестовые данные** — не реальная интеграция с 1С: API специалиста 1С не получено, тестовой копии нет (ядро §24.3).
 *
 *   # в БД локального стека / тест-контура (миграции уже применены; APP_ENV ≠ prod):
 *   APP_ENV=dev DATABASE_URL_FILE=… MEDIA_DIR=… npx tsx scripts/load_catalog_fixtures.ts --sku 500
 *   # в одноразовый embedded PostgreSQL 17 (миграции применяются, кластер удаляется) — отчёт RM-E-011:
 *   npx tsx scripts/load_catalog_fixtures.ts --embedded --sku 2000 --report ../.tmp/e011.json
 *
 * Параметры: `--sku` (500), `--seed` (1), `--images` (фото у первых K товаров; по умолчанию min(товаров, 300)),
 * `--media-dir` (иначе `MEDIA_DIR`; при `--embedded` — временный каталог), `--report <файл JSON>`, `--embedded`,
 * `--no-fixtures` (только синтетика).
 * Код выхода: 0 — 0 ошибок маппинга и $count сошёлся по всем сущностям; 1 — есть ошибки/расхождения; 2 — параметры.
 * Предупреждения `DUPLICATE_SUSPECTED` уровня warning (отчёт о дублях `onec_code`, SYNC-004) выводятся отдельной
 * строкой и на код выхода не влияют.
 */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import pg from 'pg';
import pino from 'pino';
import sharp from 'sharp';
import { FakeOnecGateway } from '../src/integrations/onec/fake-onec.gateway.js';
import { CatalogApplier } from '../src/sync/apply/catalog-applier.js';
import { type CatalogLoadResult, CatalogFullLoadService } from '../src/sync/apply/catalog-full-load.service.js';
import { type CatalogReadKind, SyntheticCatalogSource } from '../src/sync/apply/catalog-source.js';
import { createRunTracker, DEFAULT_STATE_DEFAULTS } from '../src/sync/apply/run-tracker.js';
import { ImageDirectoryImporter } from '../src/sync/images/image-directory-import.js';
import { ImageStore } from '../src/sync/images/image-store.js';
import { type CountCheckReport, CountCheckService } from '../src/sync/reconcile/count-check.service.js';
import { SyncRunRegistry } from '../src/sync/scheduler/sync-run.registry.js';
import { allMigrations } from '../test/support/catalog-fixture.js';
import { EmbeddedPg } from '../test/support/embedded-pg.js';

/** Сверка «1С ↔ БД» по одной сущности/таблице (живые объекты). */
export interface ImportCountRow {
  readonly entity: string;
  readonly table: string;
  /** Объектов в источнике (1С/фейк): без пометки удаления. */
  readonly source: number;
  /** Строк в БД (живые: `deletion_mark=false`, с `onec_ref`, где применимо). */
  readonly db: number;
  readonly diff: number;
  /** Объяснение разницы или `null`, если совпало. */
  readonly note: string | null;
}

export interface CatalogImportReport {
  readonly marker: 'на фикстурах, не реальная интеграция';
  readonly startedAt: string;
  readonly finishedAt: string;
  readonly sku: number;
  readonly seed: number;
  readonly includeFixtures: boolean;
  readonly gateway: { readonly mode: 'fixtures'; readonly calls: number };
  readonly stats: Record<string, number>;
  readonly runs: readonly {
    entity: string;
    status: string;
    pages: number;
    inserted: number;
    updated: number;
    skipped: number;
    markedDeleted: number;
    errors: number;
    sourceTotal: number | null;
    localTotal: number | null;
  }[];
  readonly loadMs: number;
  readonly counts: readonly ImportCountRow[];
  readonly countCheck: CountCheckReport;
  /**
   * `sync_errors` по коду (все уровни). Ошибки маппинга — все, кроме фото (`IMAGE_*`, `HASH_MISMATCH`) и отчётных
   * предупреждений `syncWarnings` (`DUPLICATE_SUSPECTED` уровня warning — отчёт о дублях `onec_code`, 05 SYNC-004,
   * E-KI-04: строки не правятся, прогон success, на итог не влияет).
   */
  readonly syncErrors: Record<string, number>;
  readonly syncWarnings: Record<string, number>;
  readonly mappingErrors: number;
  readonly images: {
    readonly requested: number;
    readonly files: number;
    readonly imported: number;
    readonly deduplicated: number;
    readonly unchanged: number;
    readonly errors: number;
    readonly productsWithPhoto: number;
    readonly distinctFiles: number;
    readonly storedFiles: number;
    readonly status: string;
    readonly ms: number;
  };
  readonly ok: boolean;
}

const out = (line: string): boolean => process.stdout.write(`${line}\n`);

/**
 * Отчётное предупреждение, а не ошибка маппинга: `DUPLICATE_SUSPECTED` уровня `warning` — отчёт о дублях `onec_code`
 * при полной загрузке (05 SYNC-004; 12 T-SYNC-009; E-KI-04). Фикстуры 1С и синтетика заведомо дают такие дубли.
 * `DUPLICATE_SUSPECTED` уровня `error` (например, занятый код партнёра) остаётся ошибкой.
 */
export function isReportOnlyWarning(code: string, severity: string): boolean {
  return code === 'DUPLICATE_SUSPECTED' && severity === 'warning';
}

/** Разбор `sync_errors` (код × уровень → число) на все коды, отчётные предупреждения и число ошибок маппинга. */
export function classifySyncErrors(rows: readonly { code: string; severity: string; n: number }[]): {
  syncErrors: Record<string, number>;
  syncWarnings: Record<string, number>;
  mappingErrors: number;
} {
  const syncErrors: Record<string, number> = {};
  const syncWarnings: Record<string, number> = {};
  let mappingErrors = 0;
  for (const r of rows) {
    syncErrors[r.code] = (syncErrors[r.code] ?? 0) + r.n;
    if (isReportOnlyWarning(r.code, r.severity)) syncWarnings[r.code] = (syncWarnings[r.code] ?? 0) + r.n;
    else if (!/^(IMAGE_|HASH_MISMATCH)/.test(r.code)) mappingErrors += r.n;
  }
  return { syncErrors, syncWarnings, mappingErrors };
}

function int(v: string | undefined, def: number, name: string): number {
  if (v === undefined) return def;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 0) throw new Error(`--${name}: ожидается целое ≥ 0`);
  return n;
}

/** JPEG 640×480 сплошного цвета с полосой и подписью (разные `seed` → разные байты). Синтетика, не фото товара. */
async function syntheticPhoto(seed: number, label: string): Promise<Buffer> {
  const r = (seed * 67) % 256;
  const g = (seed * 131) % 256;
  const b = (seed * 29) % 256;
  const text = label.replace(/[<>&"']/g, '');
  const svg = Buffer.from(
    `<svg width="640" height="480"><rect x="0" y="180" width="640" height="120" fill="rgb(${255 - r},${255 - g},${255 - b})"/>` +
      `<text x="320" y="255" font-size="48" text-anchor="middle" fill="rgb(${r},${g},${b})">${text}</text></svg>`,
  );
  return sharp({ create: { width: 640, height: 480, channels: 3, background: { r, g, b } } })
    .composite([{ input: svg }])
    .jpeg({ quality: 80 })
    .toBuffer();
}

async function scalar(pool: pg.Pool, sql: string): Promise<number> {
  const r = await pool.query<{ n: string }>(`SELECT (${sql})::text AS n`);
  return Number(r.rows[0]?.n ?? 0);
}

const LIVE = 'NOT deletion_mark AND onec_ref IS NOT NULL';

export interface LoadCatalogFixturesOptions {
  readonly sku: number;
  readonly seed?: number;
  readonly images?: number;
  readonly includeFixtures?: boolean;
  readonly mediaDir: string;
}

/** Загрузка каталога и фото в БД `pool` (миграции применены) и отчёт сверки. */
export async function loadCatalogFixtures(pool: pg.Pool, o: LoadCatalogFixturesOptions): Promise<CatalogImportReport> {
  const startedAt = new Date().toISOString();
  const log = pino({ level: process.env['LOAD_CATALOG_LOG'] ?? 'silent' });
  const seed = o.seed ?? 1;
  const includeFixtures = o.includeFixtures !== false;
  const gateway = new FakeOnecGateway({
    catalog: { skuCount: o.sku, seed },
    includeFixtureCatalog: includeFixtures,
    registerAll: false,
  });
  const catalog = gateway.catalog!;
  const source = new SyntheticCatalogSource(gateway);
  const runs = createRunTracker(pool);

  // 1. Полная синхронизация каталога через FakeOnecGateway (порядок 05 SYNC-001, страницы — транзакции).
  const t0 = performance.now();
  const results: CatalogLoadResult[] = await new CatalogFullLoadService(pool, new CatalogApplier(), runs, log).loadAll(
    source,
    'full',
    'manual',
  );
  const loadMs = Math.round(performance.now() - t0);

  // 2. Сверка $count (05 SYNC-003, SYNC-068) — тот же сервис, что ежесуточное задание `sync.count_check`.
  const registry = new SyncRunRegistry(pool, 3600, DEFAULT_STATE_DEFAULTS);
  const countCheck = await new CountCheckService(pool, registry, source, log).run({ trigger: 'manual' });

  // 3. Прямые подсчёты «источник ↔ БД» по всем таблицам реплик.
  const src = async (kind: CatalogReadKind) => source.count(kind);
  const stats = catalog.stats();
  const priceRefs = catalog.priceLists.filter((l) => !l.deletionMark).map((l) => l.ref);
  const productsTotal = await scalar(pool, `SELECT count(*) FROM products WHERE ${LIVE}`);
  const rows: ImportCountRow[] = [];
  const add = (entity: string, table: string, s: number, d: number, explain?: string) =>
    rows.push({ entity, table, source: s, db: d, diff: d - s, note: d === s ? null : (explain ?? 'не объяснено') });
  add('units', 'units', await src('units'), await scalar(pool, `SELECT count(*) FROM units WHERE ${LIVE}`));
  add(
    'categories',
    'categories',
    await src('categories'),
    await scalar(pool, `SELECT count(*) FROM categories WHERE ${LIVE}`),
  );
  add('products', 'products', await src('products'), productsTotal);
  add(
    'products',
    'packagings',
    await src('packagings'),
    await scalar(pool, `SELECT count(*) FROM packagings WHERE ${LIVE}`),
  );
  const variantsDb = await scalar(pool, `SELECT count(*) FROM product_variants WHERE ${LIVE}`);
  add('variants', 'product_variants (характеристики 1С)', await src('variants'), variantsDb);
  const serviceVariants = await scalar(
    pool,
    `SELECT count(*) FROM product_variants WHERE is_default AND onec_ref IS NULL AND NOT deletion_mark`,
  );
  add(
    'variants',
    'product_variants (служебные is_default)',
    productsTotal,
    serviceVariants,
    'служебный вариант is_default у каждого товара (RM-E-001 п. 4, EQ-ONEC); источник — число живых товаров',
  );
  add(
    'barcodes',
    'barcodes',
    await src('barcodes'),
    await scalar(pool, `SELECT count(*) FROM barcodes WHERE NOT deletion_mark`),
  );
  add(
    'warehouses',
    'warehouses',
    await src('warehouses'),
    await scalar(pool, `SELECT count(*) FROM warehouses WHERE ${LIVE}`),
  );
  add(
    'prices',
    'price_lists',
    await src('price_lists'),
    await scalar(pool, `SELECT count(*) FROM price_lists WHERE ${LIVE}`),
  );
  const priceRows = catalog.priceSlice(priceRefs).length;
  add('prices', 'prices', priceRows, await scalar(pool, `SELECT count(*) FROM prices`));
  const stockRows = catalog.stockSlice().length;
  add('stock', 'stock_balances', stockRows, await scalar(pool, `SELECT count(*) FROM stock_balances`));
  // Свойства приходят в составе товаров и характеристик (ТЧ ДополнительныеРеквизиты): источник — различные
  // `propertyRef` во всех элементах (отдельного чтения/`$count` у 1С нет, 07 §6.2).
  const props = new Set<string>();
  for (const it of [...catalog.productItems(), ...catalog.variants()]) {
    for (const a of (it as { attributes?: readonly { propertyRef: string }[] }).attributes ?? [])
      props.add(a.propertyRef);
  }
  add(
    'attributes',
    'product_attributes',
    props.size,
    await scalar(pool, `SELECT count(*) FROM product_attributes WHERE NOT deletion_mark`),
  );

  // 4. Синтетические фото: раскладка by-name `<onec_ref>.jpg` (05 SYNC-036), один файл — у двух товаров (sha256 → 1 раз).
  const photoProducts = catalog
    .productItems()
    .filter((p) => !p.deletionMark)
    .slice(0, o.images ?? Math.min(300, stats.products));
  const dir = mkdtempSync(path.join(process.env['TEMP'] ?? tmpdir(), 'pos-e011-photos-'));
  const t1 = performance.now();
  let imageResult;
  try {
    let prev: Buffer | undefined;
    for (const [i, p] of photoProducts.entries()) {
      // последний товар получает тот же файл, что предпоследний (дедупликация по sha256, RM-E-003 п. 1)
      const dup = i === photoProducts.length - 1 && i > 0 && prev !== undefined;
      const bytes = dup && prev ? prev : await syntheticPhoto(i + 1, p.sku ?? `#${i + 1}`);
      writeFileSync(path.join(dir, `${p.ref}.jpg`), bytes);
      prev = bytes;
    }
    imageResult = await new ImageDirectoryImporter(
      pool,
      new ImageStore(o.mediaDir),
      runs,
      log.child({ component: 'sync.images.import' }),
    ).run({ dir, layout: 'by-name', trigger: 'manual' });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  const imagesMs = Math.round(performance.now() - t1);
  const errorsByCode = await pool.query<{ code: string; severity: string; n: string }>(
    `SELECT error_code::text AS code, severity::text AS severity, count(*)::text AS n
       FROM sync_errors GROUP BY 1, 2 ORDER BY 1, 2`,
  );
  const { syncErrors, syncWarnings, mappingErrors } = classifySyncErrors(
    errorsByCode.rows.map((r) => ({ code: r.code, severity: r.severity, n: Number(r.n) })),
  );
  const images = {
    requested: photoProducts.length,
    files: imageResult.counts.files,
    imported: imageResult.counts.ready,
    deduplicated: imageResult.counts.deduplicated,
    unchanged: imageResult.counts.unchanged,
    errors: imageResult.counts.errors,
    productsWithPhoto: await scalar(
      pool,
      `SELECT count(DISTINCT product_id) FROM product_images WHERE status = 'ready' AND deleted_at IS NULL`,
    ),
    distinctFiles: await scalar(
      pool,
      `SELECT count(DISTINCT checksum_sha256) FROM product_images WHERE status = 'ready' AND deleted_at IS NULL`,
    ),
    storedFiles: 0,
    status: imageResult.status,
    ms: imagesMs,
  };
  try {
    const { readdirSync } = await import('node:fs');
    images.storedFiles = readdirSync(path.join(o.mediaDir, 'images')).length;
  } catch {
    images.storedFiles = 0;
  }

  const runsOut = results.map((r) => {
    const c = r.counts as Record<string, number | undefined> | undefined;
    return {
      entity: r.entity,
      status: r.status,
      pages: r.pages,
      inserted: c?.['inserted'] ?? 0,
      updated: c?.['updated'] ?? 0,
      skipped: c?.['skipped'] ?? 0,
      markedDeleted: c?.['markedDeleted'] ?? 0,
      errors: c?.['errors'] ?? 0,
      sourceTotal: c?.['sourceTotal'] ?? null,
      localTotal: c?.['localTotal'] ?? null,
    };
  });
  const unexplained = rows.filter((r) => r.note === 'не объяснено').length;
  const ok =
    mappingErrors === 0 &&
    unexplained === 0 &&
    countCheck.mismatches === 0 &&
    runsOut.every((r) => r.status === 'success') &&
    images.errors === 0;
  return {
    marker: 'на фикстурах, не реальная интеграция',
    startedAt,
    finishedAt: new Date().toISOString(),
    sku: o.sku,
    seed,
    includeFixtures,
    gateway: { mode: 'fixtures', calls: gateway.calls.length },
    stats: { ...stats },
    runs: runsOut,
    loadMs,
    counts: rows,
    countCheck,
    syncErrors,
    syncWarnings,
    mappingErrors,
    images,
    ok,
  };
}

function print(r: CatalogImportReport): void {
  out(`[load-catalog] ${r.marker}: ${r.sku} синтетических SKU${r.includeFixtures ? ' + фикстуры 1С' : ''}`);
  out(`[load-catalog] полная загрузка: ${r.loadMs} мс`);
  for (const x of r.runs) {
    out(
      `  run ${x.entity.padEnd(10)} ${x.status.padEnd(8)} стр.=${x.pages} +${x.inserted} ~${x.updated} =${x.skipped} ` +
        `удал.=${x.markedDeleted} ошибок=${x.errors}${x.sourceTotal !== null ? ` $count 1С=${x.sourceTotal} БД=${x.localTotal}` : ''}`,
    );
  }
  for (const c of r.counts) {
    out(
      `  count ${c.entity.padEnd(10)} ${c.table.padEnd(40)} 1С=${String(c.source).padStart(6)} БД=${String(c.db).padStart(6)} ` +
        `${c.diff === 0 ? 'OK' : `разница ${c.diff}: ${c.note}`}`,
    );
  }
  out(
    `[load-catalog] count_check: расхождений ${r.countCheck.mismatches} (${r.countCheck.entities
      .map((e) => `${e.entity}=${e.status}`)
      .join(', ')})`,
  );
  out(`[load-catalog] sync_errors: ${JSON.stringify(r.syncErrors)}; ошибок маппинга: ${r.mappingErrors}`);
  if (Object.keys(r.syncWarnings).length > 0) {
    out(
      `[load-catalog] предупреждения-отчёт (на итог не влияют; дубли onec_code — SYNC-004): ${JSON.stringify(r.syncWarnings)}`,
    );
  }
  out(
    `[load-catalog] фото: файлов ${r.images.files}, готово ${r.images.imported}, дедупликация ${r.images.deduplicated}, ошибок ${r.images.errors}, ` +
      `товаров с фото ${r.images.productsWithPhoto}, уникальных sha256 ${r.images.distinctFiles}, каталогов в хранилище ` +
      `${r.images.storedFiles}, ${r.images.ms} мс`,
  );
  out(`[load-catalog] ИТОГ: ${r.ok ? 'OK' : 'ЕСТЬ РАСХОЖДЕНИЯ'}`);
}

export async function main(argv = process.argv.slice(2)): Promise<number> {
  let values;
  try {
    ({ values } = parseArgs({
      args: argv,
      options: {
        sku: { type: 'string' },
        seed: { type: 'string' },
        images: { type: 'string' },
        'media-dir': { type: 'string' },
        report: { type: 'string' },
        embedded: { type: 'boolean', default: false },
        'no-fixtures': { type: 'boolean', default: false },
      },
      strict: true,
    }));
  } catch (e) {
    process.stderr.write(`${e instanceof Error ? e.message : String(e)}\n`);
    return 2;
  }
  const sku = int(values.sku, 500, 'sku');
  const seed = int(values.seed, 1, 'seed');
  const images = values.images === undefined ? undefined : int(values.images, 0, 'images');
  let embedded: EmbeddedPg | undefined;
  let ownMedia: string | undefined;
  let url = process.env['DATABASE_URL'];
  if (!url && process.env['DATABASE_URL_FILE']) url = readFileSync(process.env['DATABASE_URL_FILE'], 'utf8').trim();
  if (values.embedded) {
    embedded = new EmbeddedPg();
    await embedded.start();
    await embedded.createDatabase('pos_e011');
    await embedded.migrate('pos_e011', allMigrations());
    url = embedded.url('pos_e011');
    out(`[load-catalog] embedded PostgreSQL 17: миграции ${allMigrations().join(', ')}`);
  } else {
    const env = process.env['APP_ENV'];
    if (!env || env === 'prod') {
      process.stderr.write('Отказ: APP_ENV не задан или prod — фикстуры 1С только на dev/test-контуре (OPS-027)\n');
      return 2;
    }
    if (!url) {
      process.stderr.write('Отказ: нужен DATABASE_URL или DATABASE_URL_FILE (или --embedded)\n');
      return 2;
    }
  }
  let mediaDir = values['media-dir'] ?? (values.embedded ? undefined : process.env['MEDIA_DIR']);
  if (!mediaDir) {
    ownMedia = mkdtempSync(path.join(process.env['TEMP'] ?? tmpdir(), 'pos-e011-media-'));
    mediaDir = ownMedia;
  }
  const pool = new pg.Pool({ connectionString: url, max: 4 });
  try {
    const report = await loadCatalogFixtures(pool, {
      sku,
      seed,
      ...(images !== undefined ? { images } : {}),
      includeFixtures: !values['no-fixtures'],
      mediaDir,
    });
    print(report);
    if (values.report) writeFileSync(values.report, `${JSON.stringify(report, null, 2)}\n`);
    return report.ok ? 0 : 1;
  } finally {
    await pool.end();
    await embedded?.stop();
    if (ownMedia) rmSync(ownMedia, { recursive: true, force: true });
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().then(
    (code) => process.exit(code),
    (e: unknown) => {
      process.stderr.write(`[load-catalog] ОШИБКА: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}\n`);
      process.exit(2);
    },
  );
}

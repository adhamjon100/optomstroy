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
 *
 * Каталог по макету (демо Windows, 15 ADR-114; local-stack `--catalog-spec`): `--spec <design-catalog.json>` вместо
 * синтетики и фикстур 1С (несовместим с `--sku`, `--seed`, `--images`, `--no-fixtures`). Каталог строит
 * `scripts/design_catalog.ts` (`buildDesignCatalog`, тот же модуль, что у веб-демо) и загружает тот же конвейер;
 * затем: порядок категорий макета, порог «мало» и избранное (`applyDesignCatalogSettings`), фото товаров макета —
 * `ImageDirectoryImporter` (`<onec_ref>.png`, by-name), картинки категорий — `processImage` → `ImageStore` →
 * `registerCategoryImage` (`categories.image_id`). sha256 каждого фото сверяется со спецификацией.
 * `--photos-dir` — каталог, от которого отсчитываются `photos[].file` (по умолчанию — каталог спецификации);
 * `--staff-phones +996…,+996…` — сотрудники, которым ставится избранное `favorites` (пользователи уже созданы).
 *
 *   APP_ENV=dev DATABASE_URL_FILE=… MEDIA_DIR=… npx tsx scripts/load_catalog_fixtures.ts \
 *     --spec ../demo/catalog/design-catalog.json --staff-phones +996777000901,+996777000906
 *
 * Код выхода: 0 — 0 ошибок маппинга и $count сошёлся по всем сущностям; 1 — есть ошибки/расхождения; 2 — параметры.
 * Предупреждения `DUPLICATE_SUSPECTED` уровня warning (отчёт о дублях `onec_code`, SYNC-004) выводятся отдельной
 * строкой и на код выхода не влияют.
 */
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import pg from 'pg';
import pino from 'pino';
import sharp from 'sharp';
import { FakeOnecGateway } from '../src/integrations/onec/fake-onec.gateway.js';
import { ean13, SyntheticCatalog } from '../src/integrations/onec/synthetic-catalog.js';
import { CatalogApplier } from '../src/sync/apply/catalog-applier.js';
import { type CatalogLoadResult, CatalogFullLoadService } from '../src/sync/apply/catalog-full-load.service.js';
import { type CatalogReadKind, SyntheticCatalogSource } from '../src/sync/apply/catalog-source.js';
import { createRunTracker, DEFAULT_STATE_DEFAULTS } from '../src/sync/apply/run-tracker.js';
import { ImageDirectoryImporter } from '../src/sync/images/image-directory-import.js';
import { processImage } from '../src/sync/images/image-processor.js';
import { ImageStore } from '../src/sync/images/image-store.js';
import { type CountCheckReport, CountCheckService } from '../src/sync/reconcile/count-check.service.js';
import { SyncRunRegistry } from '../src/sync/scheduler/sync-run.registry.js';
import { allMigrations } from '../test/support/catalog-fixture.js';
import { EmbeddedPg } from '../test/support/embedded-pg.js';
import {
  applyDesignCatalogSettings,
  buildDesignCatalog,
  categoryOrder,
  checkGeneratorMirror,
  type DesignCatalogSpec,
  type DesignPhotoPlanItem,
  photoPlan,
  registerCategoryImage,
  validateDesignSpec,
} from './design_catalog.js';

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
  /** Каталог по макету (`--spec`, ADR-114); нет — синтетика `sku`/`seed` и фикстуры 1С. */
  readonly design?: DesignLoadReport;
  readonly ok: boolean;
}

/** Каталог по макету: что загружено и что проверено после загрузки (тестовые данные демо). */
export interface DesignLoadReport {
  readonly profile: string;
  readonly refSeed: number;
  /** sha256 файла спецификации. */
  readonly specSha256: string;
  readonly products: number;
  readonly categories: number;
  readonly productPhotos: number;
  readonly categoryImages: { readonly requested: number; readonly registered: number; readonly ms: number };
  /** Изменено строк `applyDesignCatalogSettings` (повтор — нули). */
  readonly settings: { readonly sortOrder: number; readonly lowStockThreshold: number; readonly favorites: number };
  /** Состояние БД после загрузки. */
  readonly checks: {
    /** Категорий с `sort_order` макета / всего папок спецификации. */
    readonly sortOrder: string;
    readonly lowStockThreshold: number | null;
    /** Категорий с готовой картинкой (`categories.image_id` → `ready`) / по плану. */
    readonly categoryImages: string;
    /** Строк избранного `favorites` у `staffPhones`. */
    readonly favorites: number;
  };
  readonly problems: readonly string[];
  /** Замечания, не влияющие на итог (например, нет строки настроек без seed). */
  readonly notes: readonly string[];
  readonly ok: boolean;
}

/** Каталог по макету для `loadCatalogFixtures` (`--spec`). */
export interface DesignCatalogLoad {
  /** Разобранная спецификация `demo/catalog/design-catalog.json`. */
  readonly spec: DesignCatalogSpec;
  /** sha256 файла спецификации (в отчёт). */
  readonly specSha256: string;
  /** Каталог, от которого отсчитываются `photos[].file` (обычно каталог спецификации). */
  readonly photosDir: string;
  /** Сотрудники стенда для избранного `spec.favorites` (пользователи уже созданы; нет — избранное не ставится). */
  readonly staffPhones?: readonly string[];
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

const sha256Hex = (b: Uint8Array): string => createHash('sha256').update(b).digest('hex');

/** Разбор и проверка файла спецификации каталога по макету → спецификация и sha256 файла (ошибки — исключением). */
export function readDesignSpec(file: string): { spec: DesignCatalogSpec; specSha256: string } {
  const buf = readFileSync(file);
  const spec = JSON.parse(buf.toString('utf8')) as DesignCatalogSpec;
  const errs = validateDesignSpec(spec);
  if (errs.length) throw new Error(`спецификация ${file}: ${errs.slice(0, 8).join('; ')}`);
  return { spec, specSha256: sha256Hex(buf) };
}

/**
 * Каталог по макету: зеркальные константы `design_catalog.ts` сверяются с генератором (расхождение — исключение,
 * как у сборки снимка веб-демо), затем `buildDesignCatalog`. Товары кассира строит так же `designCatalogFromFile`
 * (`pos_fake_onec.ts`; загрузчик с pg/sharp фейк не импортирует).
 */
export function designCatalogOf(spec: DesignCatalogSpec): SyntheticCatalog {
  const deps = { SyntheticCatalog, ean13 };
  const problems = checkGeneratorMirror(deps, spec);
  if (problems.length) throw new Error(`design_catalog ≠ генератор: ${problems.slice(0, 8).join('; ')}`);
  return buildDesignCatalog(spec, deps);
}

/** Байты фото спецификации; sha256 файла ≠ спецификации — исключение (фото не подменяются молча). */
function designPhotoBytes(photosDir: string, p: DesignPhotoPlanItem): Buffer {
  const file = path.join(photosDir, p.file);
  const bytes = readFileSync(file);
  const sha = sha256Hex(bytes);
  if (sha !== p.sha256) {
    throw new Error(`фото ${p.photo} (${file}): sha256 ${sha.slice(0, 12)}… ≠ спецификации ${p.sha256.slice(0, 12)}…`);
  }
  return bytes;
}

/**
 * Каталог по макету после полной загрузки и фото товаров: порядок категорий, порог «мало», избранное
 * (`applyDesignCatalogSettings` — одно соединение: в нём BEGIN / SET LOCAL), картинки категорий и проверка состояния БД.
 */
async function applyDesignCatalog(
  pool: pg.Pool,
  d: DesignCatalogLoad,
  catalog: SyntheticCatalog,
  plan: ReturnType<typeof photoPlan>,
  mediaDir: string,
): Promise<DesignLoadReport> {
  const problems: string[] = [];
  const notes: string[] = [];
  const staffPhones = d.staffPhones ?? [];
  const client = await pool.connect();
  let settings;
  try {
    settings = await applyDesignCatalogSettings(client, d.spec, catalog, { staffPhones });
  } finally {
    client.release();
  }
  // Картинки категорий: PNG макета → WebP thumb/card/full (без увеличения) → MEDIA_DIR/images/{sha}/ → строка
  // product_images с category_id и categories.image_id (как category-images.mjs построителя снимка веб-демо).
  const t = performance.now();
  const store = new ImageStore(mediaDir);
  let registered = 0;
  for (const c of plan.categories) {
    const img = await processImage(designPhotoBytes(d.photosDir, c));
    if (!(await store.has(img.sha256))) await store.write(img.sha256, img.renders);
    const r = await registerCategoryImage(pool, {
      categoryRef: c.onecRef,
      fileName: path.basename(c.file),
      image: {
        sha256: img.sha256,
        originalMime: img.originalMime,
        originalBytes: img.originalBytes,
        width: img.width,
        height: img.height,
        sizes: img.sizes,
      },
    });
    if (r) registered += 1;
    else problems.push(`картинка категории ${c.owner}: категории ${c.onecRef} нет в БД`);
  }
  const imagesMs = Math.round(performance.now() - t);

  const order = categoryOrder(d.spec, catalog);
  const so = await pool.query<{ n: number }>(
    `SELECT count(*)::int AS n FROM categories c JOIN unnest($1::uuid[], $2::int[]) AS v(ref, sort_order)
         ON c.onec_ref = v.ref
      WHERE c.sort_order = v.sort_order AND NOT c.deletion_mark`,
    [order.map((x) => x.onecRef), order.map((x) => x.sortOrder)],
  );
  const sortOk = so.rows[0]?.n ?? 0;
  if (sortOk !== order.length) problems.push(`порядок макета у ${sortOk} из ${order.length} категорий`);
  const th = await pool.query<{ value: unknown }>(`SELECT value FROM app_settings WHERE key = 'low_stock_threshold'`);
  const threshold = th.rows[0] === undefined ? null : Number(th.rows[0].value);
  // Строку настроек создаёт seed (`migrate --seed`, local-stack); без seed (`--embedded`) её нет — это не расхождение.
  if (threshold === null) notes.push('порог «мало»: строки app_settings нет (seed не применён)');
  else if (threshold !== d.spec.lowStockThreshold) {
    problems.push(`порог «мало» ${threshold} ≠ ${d.spec.lowStockThreshold}`);
  }
  const ci = await pool.query<{ n: number }>(
    `SELECT count(*)::int AS n FROM categories c JOIN product_images i ON i.id = c.image_id
      WHERE c.onec_ref = ANY($1::uuid[]) AND i.category_id = c.id AND i.status = 'ready' AND i.deleted_at IS NULL`,
    [plan.categories.map((c) => c.onecRef)],
  );
  const catImages = ci.rows[0]?.n ?? 0;
  if (catImages !== plan.categories.length) {
    problems.push(`картинки у ${catImages} из ${plan.categories.length} категорий`);
  }
  const fav = await pool.query<{ n: number }>(
    `SELECT count(*)::int AS n FROM favorites_products f JOIN users u ON u.id = f.user_id JOIN products p ON p.id = f.product_id
      WHERE u.phone_e164 = ANY($1::text[]) AND p.sku = ANY($2::text[])`,
    [[...staffPhones], [...d.spec.favorites]],
  );
  const favorites = fav.rows[0]?.n ?? 0;
  return {
    profile: d.spec.profile,
    refSeed: d.spec.refSeed,
    specSha256: d.specSha256,
    products: d.spec.products.length,
    categories: order.length,
    productPhotos: plan.products.length,
    categoryImages: { requested: plan.categories.length, registered, ms: imagesMs },
    settings,
    checks: {
      sortOrder: `${sortOk}/${order.length}`,
      lowStockThreshold: threshold,
      categoryImages: `${catImages}/${plan.categories.length}`,
      favorites,
    },
    problems,
    notes,
    ok: problems.length === 0,
  };
}

export interface LoadCatalogFixturesOptions {
  readonly sku: number;
  readonly seed?: number;
  readonly images?: number;
  readonly includeFixtures?: boolean;
  readonly mediaDir: string;
  /** Каталог по макету (ADR-114) вместо синтетики `sku`/`seed` и фикстур 1С (`sku`, `seed`, `images` не читаются). */
  readonly design?: DesignCatalogLoad;
}

/** Загрузка каталога и фото в БД `pool` (миграции применены) и отчёт сверки. */
export async function loadCatalogFixtures(pool: pg.Pool, o: LoadCatalogFixturesOptions): Promise<CatalogImportReport> {
  const startedAt = new Date().toISOString();
  const log = pino({ level: process.env['LOAD_CATALOG_LOG'] ?? 'silent' });
  const design = o.design;
  const seed = design ? design.spec.refSeed : (o.seed ?? 1);
  const includeFixtures = design ? false : o.includeFixtures !== false;
  const gateway = new FakeOnecGateway({
    catalog: design ? designCatalogOf(design.spec) : { skuCount: o.sku, seed },
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
  //    Каталог по макету: фото товаров макета как есть, `<onec_ref>.png` по плану спецификации.
  const plan = design ? photoPlan(design.spec, catalog) : undefined;
  const photoProducts = plan
    ? []
    : catalog
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
    if (design && plan) {
      for (const p of plan.products) {
        writeFileSync(path.join(dir, `${p.onecRef}.png`), designPhotoBytes(design.photosDir, p));
      }
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
  // 5. Каталог по макету: порядок категорий, порог «мало», избранное, картинки категорий и проверка БД.
  const designReport = design && plan ? await applyDesignCatalog(pool, design, catalog, plan, o.mediaDir) : undefined;
  const errorsByCode = await pool.query<{ code: string; severity: string; n: string }>(
    `SELECT error_code::text AS code, severity::text AS severity, count(*)::text AS n
       FROM sync_errors GROUP BY 1, 2 ORDER BY 1, 2`,
  );
  const { syncErrors, syncWarnings, mappingErrors } = classifySyncErrors(
    errorsByCode.rows.map((r) => ({ code: r.code, severity: r.severity, n: Number(r.n) })),
  );
  const images = {
    requested: plan ? plan.products.length : photoProducts.length,
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
    images.errors === 0 &&
    (designReport === undefined || (designReport.ok && images.productsWithPhoto === designReport.productPhotos));
  return {
    marker: 'на фикстурах, не реальная интеграция',
    startedAt,
    finishedAt: new Date().toISOString(),
    sku: design ? 0 : o.sku,
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
    ...(designReport ? { design: designReport } : {}),
    ok,
  };
}

function print(r: CatalogImportReport): void {
  const d = r.design;
  out(
    d
      ? `[load-catalog] ${r.marker}: каталог по макету ${d.profile} (${d.products} товаров, ${d.categories} категорий; ` +
          `спецификация sha256 ${d.specSha256.slice(0, 12)}…) — тестовые данные демо`
      : `[load-catalog] ${r.marker}: ${r.sku} синтетических SKU${r.includeFixtures ? ' + фикстуры 1С' : ''}`,
  );
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
  if (d) {
    out(
      `[load-catalog] по макету: порядок категорий ${d.checks.sortOrder}, порог «мало» ${String(d.checks.lowStockThreshold)}, ` +
        `картинки категорий ${d.checks.categoryImages} (${d.categoryImages.ms} мс), фото товаров ${r.images.productsWithPhoto}/` +
        `${d.productPhotos}, избранное сотрудников ${d.checks.favorites}` +
        `${d.notes.length ? `; замечания: ${d.notes.join('; ')}` : ''}` +
        `${d.problems.length ? `; ПРОБЛЕМЫ: ${d.problems.join('; ')}` : ''}`,
    );
  }
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
        spec: { type: 'string' },
        'photos-dir': { type: 'string' },
        'staff-phones': { type: 'string' },
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
  let design: DesignCatalogLoad | undefined;
  if (values.spec !== undefined) {
    const clash = (['sku', 'seed', 'images', 'no-fixtures'] as const).filter((k) =>
      k === 'no-fixtures' ? values[k] : values[k] !== undefined,
    );
    if (clash.length) {
      process.stderr.write(
        `--spec несовместим с ${clash.map((k) => `--${k}`).join(', ')} (каталог — из спецификации)\n`,
      );
      return 2;
    }
    const file = path.resolve(values.spec);
    try {
      design = {
        ...readDesignSpec(file),
        photosDir: path.resolve(values['photos-dir'] ?? path.dirname(file)),
        staffPhones: (values['staff-phones'] ?? '')
          .split(',')
          .map((s) => s.trim())
          .filter((s) => s !== ''),
      };
    } catch (e) {
      process.stderr.write(`--spec: ${e instanceof Error ? e.message : String(e)}\n`);
      return 2;
    }
  } else if (values['photos-dir'] !== undefined || values['staff-phones'] !== undefined) {
    process.stderr.write('--photos-dir и --staff-phones — только вместе с --spec\n');
    return 2;
  }
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
      ...(design ? { design } : {}),
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

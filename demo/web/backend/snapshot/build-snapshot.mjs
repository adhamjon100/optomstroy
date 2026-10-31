// Снимок БД и фото веб-демо, собираемые при сборке (WP-B4; plan §3.5, §4 WP-B4; critic [2], [10], [20]).
//
//   node demo/web/backend/snapshot/build-snapshot.mjs [--sku 500] [--photos 300] [--no-site] [--s1] [--out <каталог>]
//
// Node, тот же PGlite 0.3.16, без портов. Шаги:
//  1. построитель (builder-entry.mjs) собирается esbuild для Node теми же подменами, что backend.js (bundle-builder);
//  2. детерминированная БД: настоящие migrate и seed, сотрудники 901/906/907/909 и служебные учётки сида 981/986/987
//     «Демо-история …», каталог настоящим конвейером (SyntheticCatalog seed 1, 500 SKU, без фикстур);
//  3. фото: синтетические JPEG (photos.mjs, sharp) → pos-api ImageDirectoryImporter → product_images и
//     .build/images/{sha}/{thumb|card|full}.webp — в одном прогоне с данными;
//  4. выгрузка S2 (export-copy.mjs): .build/snapshot/{manifest.json, data.copy}, .build/snapshot/images.json;
//  5. проверки: таблицы со сроком действия пусты и не выгружены, часы сборки не «протекли», sha фото = файлы,
//     запрещённые строки ПДн (forbidden.mjs, полный список из pii-map.json) — в снимке, манифесте и подписях фото;
//     телефоны тестовых клиентов проходят ту же проверку номера, что pos-api (libphonenumber-js/max, мобильный КР);
//  6. копия в site/demo/snapshot/{manifest.json, data.copy.gz} и site/images/ (если не --no-site).
// --s1: дополнительно обычная (не детерминированная) сборка той же БД и её dumpDataDir — запасной формат S1 для
// сравнения (test/harness/b4-acceptance.mjs); файл .build/snapshot/s1-datadir.tar.gz.
// Отчёт: .build/snapshot/report.json. Код выхода: 0 — всё в порядке; 1 — ошибка сборки или проверки.
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, statfsSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { brotliCompressSync, constants as zc, gzipSync } from 'node:zlib';
import { API, BACKEND, BUILD, DIST, NM, PGLITE_DIR, ROOT, SITE } from '../lib/paths.mjs';
import { DEMO_DATA, INVITATION, LOGIN_HINTS, SEED_ACCOUNTS, STAFF } from '../demo-config.mjs';
import { loadPiiMap } from '../pii/pii-transform.mjs';
import { bundleBuilder } from './bundle-builder.mjs';
import { exportSnapshot, SNAPSHOT_FORMAT } from './export-copy.mjs';
import { deriveFromFixtures, forbiddenStrings, scanText } from './forbidden.mjs';
import { sharpVersion, syntheticPhoto } from './photos.mjs';

/** T0 снимка: всё, что при сборке идёт от часов, равно T0 (+ мкс); воркер сдвигает это на момент восстановления. */
export const SNAPSHOT_T0 = '2000-01-01T00:00:00.000Z';
export const SNAPSHOT_DIR = `${BUILD}/snapshot`;
export const IMAGE_SIZES = ['thumb', 'card', 'full'];

const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const freeMB = (p) => {
  try {
    const s = statfsSync(p);
    return Math.round((s.bavail * s.bsize) / 1048576);
  } catch {
    return null;
  }
};

async function loadPglite() {
  const lock = JSON.parse(readFileSync(`${BACKEND}/pglite.lock.json`, 'utf8'));
  const pkg = JSON.parse(readFileSync(`${PGLITE_DIR}/package.json`, 'utf8'));
  if (pkg.version !== lock.version) throw new Error(`PGlite: версия ${pkg.version} в ${PGLITE_DIR}, в lock — ${lock.version}`);
  for (const f of ['dist/pglite.wasm', 'dist/pglite.data', 'dist/index.js']) {
    const a = lock.files[f];
    if (a && sha256(readFileSync(`${PGLITE_DIR}/${f}`)) !== a.sha256) throw new Error(`PGlite: ${f} не совпадает с pglite.lock.json`);
  }
  const u = (f) => pathToFileURL(`${PGLITE_DIR}/dist/${f}`).href;
  const [{ PGlite }, { pgcrypto }, { pg_trgm }, { unaccent }] = await Promise.all([import(u('index.js')), import(u('contrib/pgcrypto.js')), import(u('contrib/pg_trgm.js')), import(u('contrib/unaccent.js'))]);
  return { PGlite, extensions: { pgcrypto, pg_trgm, unaccent }, version: pkg.version };
}

function dirFiles(dir, re) {
  return existsSync(dir) ? readdirSync(dir).filter((f) => re.test(f)).sort().map((f) => [f, sha256(readFileSync(`${dir}/${f}`))]) : [];
}

/** Телефоны тестовых клиентов и стенда — через ту же проверку, что pos-api normalizeKgPhone (мобильный номер КР). */
function checkPhones(piiMap, extraCustomers) {
  const req = createRequire(`${NM}/`);
  const { parsePhoneNumberFromString } = req('libphonenumber-js/max');
  const kinds = {};
  const add = (group, phone) => {
    const p = parsePhoneNumberFromString(phone);
    const ok = !!p && p.country === 'KG' && p.isValid() && ['MOBILE', 'FIXED_LINE_OR_MOBILE'].includes(p.getType());
    (kinds[group] ??= []).push({ phone, ok, type: p?.getType() ?? null });
  };
  for (const e of Object.values(piiMap.tables.CASHIER_SCENARIO_PHONES.entries)) add('scenario', e.to);
  for (let i = 1; i <= extraCustomers; i++) add('regular', `+9967000${String(1000 + i).padStart(5, '0')}`);
  for (const s of [...STAFF, ...SEED_ACCOUNTS, INVITATION]) add('staff', s.phone);
  for (const h of LOGIN_HINTS) add('hints', h.phone);
  // Есть ли у КР «невыделенный» мобильный диапазон, который проходит проверку? (вывод — в known_issues)
  const probes = ['+996000000101', '+996100000101', '+996300000101', '+996400000101', '+996900000101', '+996800000101'].map((phone) => {
    const p = parsePhoneNumberFromString(phone);
    return { phone, valid: !!p?.isValid(), type: p?.getType() ?? null };
  });
  const all = Object.values(kinds).flat();
  return { groups: kinds, allValid: all.every((x) => x.ok), invalid: all.filter((x) => !x.ok), nonMobileProbes: probes };
}

/** Проверка фото: строки product_images ↔ файлы images/{sha}/{size}.webp ↔ sha256 исходных JPEG. */
async function checkImages(db, imagesRoot, sourceShaByRef) {
  const r = await db.query(
    `SELECT pi.id::text AS id, encode(pi.checksum_sha256, 'hex') AS sha, pi.status::text AS status, pi.storage_key, pi.sizes, pi.is_primary,
            p.onec_ref::text AS ref, (p.primary_image_id = pi.id) AS is_product_primary
       FROM product_images pi JOIN products p ON p.id = pi.product_id WHERE pi.deleted_at IS NULL ORDER BY sha`,
  );
  const problems = [];
  const files = [];
  const shas = new Set();
  for (const row of r.rows) {
    if (row.status !== 'ready') problems.push(`${row.ref}: статус ${row.status}`);
    if (row.storage_key !== `images/${row.sha}`) problems.push(`${row.ref}: storage_key ${row.storage_key}`);
    if (sourceShaByRef.get(row.ref) !== row.sha) problems.push(`${row.ref}: sha в БД ${row.sha.slice(0, 12)} ≠ sha исходника ${String(sourceShaByRef.get(row.ref)).slice(0, 12)}`);
    if (!row.is_product_primary) problems.push(`${row.ref}: фото не основное у товара`);
    if (shas.has(row.sha)) continue;
    shas.add(row.sha);
    const sizes = typeof row.sizes === 'string' ? JSON.parse(row.sizes) : row.sizes;
    const entry = { sha: row.sha, sizes: {} };
    for (const s of IMAGE_SIZES) {
      const f = `${imagesRoot}/${row.sha}/${s}.webp`;
      if (!existsSync(f)) {
        problems.push(`нет файла images/${row.sha}/${s}.webp`);
        continue;
      }
      const buf = readFileSync(f);
      if (buf.length !== sizes?.[s]?.bytes) problems.push(`images/${row.sha}/${s}.webp: ${buf.length} Б, в product_images.sizes ${sizes?.[s]?.bytes}`);
      if (buf.subarray(0, 4).toString('latin1') !== 'RIFF' || buf.subarray(8, 12).toString('latin1') !== 'WEBP') problems.push(`images/${row.sha}/${s}.webp: не WebP`);
      entry.sizes[s] = { w: sizes?.[s]?.w, h: sizes?.[s]?.h, bytes: buf.length, sha256: sha256(buf) };
    }
    files.push(entry);
  }
  const onDisk = existsSync(imagesRoot) ? readdirSync(imagesRoot).filter((d) => statSync(`${imagesRoot}/${d}`).isDirectory()) : [];
  const orphans = onDisk.filter((d) => !shas.has(d));
  if (orphans.length) problems.push(`каталоги без строк product_images: ${orphans.slice(0, 5).join(', ')}`);
  for (const d of onDisk) {
    const extra = readdirSync(`${imagesRoot}/${d}`).filter((f) => !IMAGE_SIZES.some((s) => f === `${s}.webp`));
    if (extra.length) problems.push(`images/${d}: лишние файлы ${extra.join(', ')}`);
  }
  const bytes = files.reduce((a, f) => a + Object.values(f.sizes).reduce((x, s) => x + s.bytes, 0), 0);
  const list = files.map((f) => `${f.sha} ${IMAGE_SIZES.map((s) => `${s}:${f.sizes[s]?.bytes}:${f.sizes[s]?.sha256}`).join(' ')}`).join('\n');
  const owners = [...r.rows.map((x) => `${x.ref} ${x.sha}`)].sort().join('\n');
  return { rows: r.rows.length, products: new Set(r.rows.map((x) => x.ref)).size, distinct: files.length, files: files.length * IMAGE_SIZES.length, bytes, listSha256: sha256(list), ownersSha256: sha256(owners), problems, list: files };
}

/**
 * Собрать снимок. o: { sku, photos, outDir (.build/snapshot), mediaDir (.build: фото в mediaDir/images), site (копия
 * в site/), s1, quiet }. → report.
 */
export async function buildSnapshot(o = {}) {
  const t00 = performance.now();
  const say = (...a) => o.quiet || console.log(`[build-snapshot ${((performance.now() - t00) / 1000).toFixed(1)}s]`, ...a);
  process.env.TEMP ||= `${ROOT}/.tmp`;
  process.env.TMP ||= `${ROOT}/.tmp`;
  const outDir = o.outDir ?? SNAPSHOT_DIR;
  const mediaDir = o.mediaDir ?? BUILD;
  const imagesRoot = `${mediaDir}/images`;
  const sku = o.sku ?? DEMO_DATA.catalog.skuCount;
  const photoCount = o.photos ?? 300;
  const free = freeMB(ROOT);
  if (free !== null && free < 300) throw new Error(`мало места на диске сборки: ${free} МБ (нужно ≥ 300 МБ)`);
  if (!existsSync(`${DIST}/db/migrator.js`)) throw new Error(`нет ${DIST} — сначала node demo/web/backend/build-backend.mjs (tsc)`);
  const report = { startedAt: new Date().toISOString(), format: SNAPSHOT_FORMAT, sku, photos: photoCount, diskFreeMB: free, problems: [] };
  const piiMap = loadPiiMap();

  // ---------------------------------------------------------------- 1. построитель и PGlite
  const { file, report: bundleReport } = await bundleBuilder({ outDir });
  report.builder = { file: file.replace(ROOT + '/', ''), sharpImports: bundleReport.sharp ?? 0, deterministicIds: bundleReport.deterministicIds ?? 0, piiSyntheticCashier: !!bundleReport.pii?.syntheticCashier };
  if (!bundleReport.deterministicIds) throw new Error('построитель: подмена dist/common/ids/uuid.js не применилась');
  const builder = await import(`${pathToFileURL(file).href}?t=${Date.now()}`);
  const pgl = await loadPglite();
  report.pglite = pgl.version;
  report.sharp = sharpVersion();

  const dirs = { migrations: `${API}/migrations`, devMigrations: `${API}/db/migrations-dev`, seeds: `${API}/seeds`, fixtures: `${ROOT}/contracts/onec/fixtures` };
  const logLines = [];
  const log = (level, msg) => {
    if (level === 'error' || level === 'warn') logLines.push(`${level} ${String(msg).slice(0, 400)}`);
  };

  /** Одна сборка БД (+ фото). deterministic=false — для S1 (обычная сборка, как холодный старт воркера). */
  async function makeDb({ deterministic, photosTo }) {
    const db = await pgl.PGlite.create('memory://', { extensions: pgl.extensions });
    const ctx = await builder.buildDb(db, { dirs, sku, catalogSeed: DEMO_DATA.catalog.seed, includeFixtureCatalog: DEMO_DATA.catalog.includeFixtureCatalog, t0: SNAPSHOT_T0, deterministic, seedParams: { receivables_max_age_min: '60' }, log });
    // Фото: первые photoCount продаваемых товаров по коду 1С.
    const prods = await db.query(
      `SELECT p.onec_ref::text AS ref, p.sku, c.name AS category FROM products p LEFT JOIN categories c ON c.id = p.category_id
        WHERE NOT p.deletion_mark AND p.is_sellable ORDER BY p.onec_code, p.onec_ref LIMIT $1`,
      [photoCount],
    );
    const src = `${outDir}/photos-src`;
    rmSync(src, { recursive: true, force: true });
    mkdirSync(src, { recursive: true });
    const shaByRef = new Map();
    const labels = [];
    let t = performance.now();
    for (const [i, p] of prods.rows.entries()) {
      const jpg = await syntheticPhoto({ sku: p.sku, category: p.category, index: i });
      writeFileSync(`${src}/${p.ref}.jpg`, jpg);
      shaByRef.set(p.ref, sha256(jpg));
      labels.push(`${p.sku} ${p.category}`);
    }
    const genMs = Math.round(performance.now() - t);
    rmSync(`${photosTo}/images`, { recursive: true, force: true });
    const imp = await builder.importPhotos(ctx, { dir: src, mediaDir: photosTo });
    rmSync(src, { recursive: true, force: true });
    return { db, ctx, prods: prods.rows, shaByRef, labels, photos: { generated: prods.rows.length, genMs, importMs: imp.ms, status: imp.status, counts: imp.counts } };
  }

  // ---------------------------------------------------------------- 2–3. детерминированная БД и фото
  say(`БД снимка: ${sku} SKU, ${photoCount} фото…`);
  const main = await makeDb({ deterministic: true, photosTo: mediaDir });
  report.build = main.ctx.timings;
  report.photosRun = main.photos;
  if (main.photos.status !== 'success' || main.photos.counts.errors) report.problems.push(`импорт фото: ${main.photos.status}, ошибок ${main.photos.counts.errors}`);
  const images = await checkImages(main.db, imagesRoot, main.shaByRef);
  report.images = { ...images, list: undefined };
  report.problems.push(...images.problems);
  say(`фото: ${images.products} товаров, ${images.files} файлов, ${(images.bytes / 1e6).toFixed(2)} МБ`);
  const audit = (await main.db.query(`SELECT ok, broken_at_chain_seq, gaps FROM audit_verify_chain(0, 9223372036854775807)`)).rows[0];
  report.auditChainAtBuild = audit;
  if (!audit?.ok) report.problems.push('цепочка аудита в БД сборки не сходится');

  // ---------------------------------------------------------------- 4. выгрузка S2
  const t4 = performance.now();
  const ex = await exportSnapshot(main.db, { t0: SNAPSHOT_T0, now: new Date(), migrationRows: main.ctx.timings.migrationRows });
  report.exportMs = Math.round(performance.now() - t4);
  report.problems.push(...ex.report.problems);
  report.tables = { total: ex.report.tables, inSnapshot: ex.report.included, empty: ex.report.emptyTables, excluded: ex.report.excluded };
  const pkgSha = (dir, re) => dirFiles(dir, re);
  const manifest = {
    ...ex.manifest,
    source: {
      what: 'Синтетические тестовые данные веб-демо «Оптомстрой POS»: каталог SyntheticCatalog, сотрудники стенда, фото-заглушки. Не реальные данные.',
      catalog: { skuCount: sku, seed: DEMO_DATA.catalog.seed, includeFixtureCatalog: DEMO_DATA.catalog.includeFixtureCatalog },
      staff: STAFF.map((s) => s.phone),
      seedAccounts: SEED_ACCOUNTS.map((s) => ({ phone: s.phone, name: s.name })),
      migrations: pkgSha(`${API}/migrations`, /^\d{4}_.*\.sql$/),
      devMigrations: pkgSha(`${API}/db/migrations-dev`, /\.sql$/),
      seeds: pkgSha(`${API}/seeds`, /\.sql$/),
      pglite: pgl.version,
    },
    images: { products: images.products, distinct: images.distinct, files: images.files, bytes: images.bytes, sizes: IMAGE_SIZES, url: '/images/{sha}/{size}.webp', listSha256: images.listSha256, ownersSha256: images.ownersSha256 },
  };
  // Ключ эпохи (lib/epoch.mjs) берёт из манифеста ТОЛЬКО то, от чего зависят уже сохранённые данные зрителя (тёплый
  // старт снимок не читает): привязка фото «товар → sha» (файлы /images/{sha}/… на сайте должны совпасть со строками
  // product_images в его браузере), параметры каталога, сотрудники и служебные учётки, формат и T0. Схема и строки
  // снимка сюда не входят: более поздняя миграция меняет снимок, но к данным зрителя её применяет настоящий мигратор,
  // и ключ эпохи от неё не меняется (как в WP-B3).
  manifest.epoch = {
    format: manifest.format,
    t0: manifest.t0,
    catalog: manifest.source.catalog,
    staff: manifest.source.staff,
    seedAccounts: manifest.source.seedAccounts,
    imagesOwnersSha256: images.ownersSha256,
  };
  manifest.data.gzipFile = 'data.copy.gz';
  const data = ex.data;
  const dataText = Buffer.from(data).toString('utf8');

  // ---------------------------------------------------------------- 5. ПДн и телефоны
  const fb = forbiddenStrings(piiMap, { cashierSeed: DEMO_DATA.cashier.seed, extraCustomers: DEMO_DATA.cashier.extraCustomers });
  const missingInPii = fb.sources.derived;
  if (missingInPii.length) report.problems.push(`pii-map.json forbidden неполный: нет ${missingInPii.slice(0, 8).join(', ')}${missingInPii.length > 8 ? '…' : ''}`);
  const hits = {
    snapshot: scanText(dataText, fb.strings),
    manifest: scanText(JSON.stringify(manifest), fb.strings),
    photoLabels: scanText(main.labels.join('\n'), fb.strings),
  };
  for (const [k, v] of Object.entries(hits)) if (v.length) report.problems.push(`запрещённые строки ПДн в ${k}: ${v.map((x) => `${x.string}×${x.count}`).join(', ')}`);
  report.pii = { forbiddenCount: fb.strings.length, derivedMissingInPiiMap: missingInPii, hits, fixtures: deriveFromFixtures(dirs.fixtures) };
  report.phones = checkPhones(piiMap, DEMO_DATA.cashier.extraCustomers);
  if (!report.phones.allValid) report.problems.push(`телефоны не проходят проверку pos-api: ${report.phones.invalid.map((x) => x.phone).join(', ')}`);
  report.expiry = {
    excludedTables: ex.manifest.excluded.map((x) => x.table),
    timeColumnsRebased: ex.manifest.timeColumns.length,
    invitationsInSnapshot: ex.manifest.tables.some((t) => t.name === 'user_invitations'),
  };
  report.serviceAccounts = (await main.db.query(`SELECT u.phone_e164 AS phone, p.full_name AS name, u.status FROM users u JOIN user_profiles p ON p.user_id = u.id WHERE u.phone_e164 = ANY($1) ORDER BY 1`, [SEED_ACCOUNTS.map((s) => s.phone)])).rows;
  if (!report.serviceAccounts.every((a) => a.name.startsWith('Демо-история'))) report.problems.push('служебные учётки сида не «Демо-история …»');

  // ---------------------------------------------------------------- запись
  mkdirSync(outDir, { recursive: true });
  manifest.builtAt = new Date().toISOString();
  const manifestText = JSON.stringify(manifest, null, 1) + '\n';
  writeFileSync(`${outDir}/data.copy`, data);
  // На сайт идёт сжатая копия (gzip -9, без времени в заголовке — детерминирована): воркер распаковывает её сам
  // (DecompressionStream), поэтому размер передачи не зависит от того, сожмёт ли хостинг файл .copy.
  const gz = gzipSync(data, { level: 9 });
  writeFileSync(`${outDir}/${manifest.data.gzipFile}`, gz);
  writeFileSync(`${outDir}/manifest.json`, manifestText);
  writeFileSync(`${outDir}/images.json`, JSON.stringify({ url: manifest.images.url, listSha256: images.listSha256, files: images.list }, null, 1) + '\n');
  report.size = {
    dataBytes: data.length,
    dataGzip: gz.length,
    dataGzipSha256: sha256(gz),
    dataBrotli: brotliCompressSync(data, { params: { [zc.BROTLI_PARAM_QUALITY]: 11, [zc.BROTLI_PARAM_SIZE_HINT]: data.length } }).length,
    manifestBytes: Buffer.byteLength(manifestText),
    imagesBytes: images.bytes,
  };
  report.dataSha256 = manifest.data.sha256;
  report.manifestKey = sha256(JSON.stringify({ ...manifest, builtAt: undefined }));
  say(`снимок S2: ${manifest.tables.length} таблиц, ${manifest.tables.reduce((a, t) => a + t.rows, 0)} строк, data.copy ${(data.length / 1e6).toFixed(2)} МБ (gzip ${(report.size.dataGzip / 1e6).toFixed(2)}, brotli ${(report.size.dataBrotli / 1e6).toFixed(2)})`);

  // ---------------------------------------------------------------- S1 для сравнения (необязательно)
  if (o.s1) {
    const t = performance.now();
    const s1Media = `${outDir}/s1-media`;
    const s1 = await makeDb({ deterministic: false, photosTo: s1Media });
    rmSync(s1Media, { recursive: true, force: true });
    const blob = await s1.db.dumpDataDir('gzip');
    const buf = Buffer.from(await blob.arrayBuffer());
    writeFileSync(`${outDir}/s1-datadir.tar.gz`, buf);
    await s1.db.close();
    report.s1 = { file: 's1-datadir.tar.gz', bytes: buf.length, ms: Math.round(performance.now() - t) };
    say(`S1 dumpDataDir (обычная сборка): ${(buf.length / 1e6).toFixed(2)} МБ gzip`);
  }
  await main.db.close();

  // ---------------------------------------------------------------- 6. копия в site/
  if (o.site !== false && !report.problems.length) {
    const snapDir = `${SITE}/demo/snapshot`;
    rmSync(snapDir, { recursive: true, force: true });
    mkdirSync(snapDir, { recursive: true });
    cpSync(`${outDir}/${manifest.data.gzipFile}`, `${snapDir}/${manifest.data.gzipFile}`);
    cpSync(`${outDir}/manifest.json`, `${snapDir}/manifest.json`);
    rmSync(`${SITE}/images`, { recursive: true, force: true });
    cpSync(imagesRoot, `${SITE}/images`, { recursive: true });
    report.site = { snapshot: `site/demo/snapshot/{manifest.json,${manifest.data.gzipFile}}`, images: 'site/images/{sha}/{size}.webp' };
  }
  report.warnings = logLines.slice(0, 50);
  report.totalMs = Math.round(performance.now() - t00);
  writeFileSync(`${outDir}/report.json`, JSON.stringify(report, null, 1) + '\n');
  return { report, manifest };
}

// ---------------------------------------------------------------- CLI
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const arg = (k, d) => {
    const i = argv.indexOf(k);
    return i >= 0 ? argv[i + 1] : d;
  };
  const out = arg('--out', null);
  try {
    const { report } = await buildSnapshot({
      sku: Number(arg('--sku', DEMO_DATA.catalog.skuCount)),
      photos: Number(arg('--photos', 300)),
      site: !argv.includes('--no-site') && !out,
      s1: argv.includes('--s1'),
      ...(out ? { outDir: resolve(out).replace(/\\/g, '/'), mediaDir: resolve(out).replace(/\\/g, '/') } : {}),
    });
    console.log(`[build-snapshot] проверки: ${report.problems.length ? 'ОШИБКИ' : 'ok'}; ${report.totalMs} мс; отчёт ${(out ?? SNAPSHOT_DIR)}/report.json`);
    for (const p of report.problems) console.error('  FAIL', p);
    process.exitCode = report.problems.length ? 1 : 0;
  } catch (e) {
    console.error('[build-snapshot] ОШИБКА', e?.stack ?? e);
    process.exitCode = 1;
  }
}

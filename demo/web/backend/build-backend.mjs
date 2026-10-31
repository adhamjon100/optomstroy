// Сборка браузерного бэкенда веб-демо (WP-B1): настоящий pos-api (tsc текущего рабочего дерева) + шимы Node +
// подмены модулей → один ESM-бандл site/backend/backend.js для module Web Worker; рядом — PGlite 0.3.16 как есть
// (site/backend/pglite/), внешние файлы виртуальной fs (site/backend/vfs/), build.json и
// site/THIRD_PARTY_NOTICES.txt. Исходники pos-api не меняются: вся адаптация — подмена модулей на этапе сборки.
//
//   node demo/web/backend/build-backend.mjs [--skip-tsc] [--skip-snapshot] [--no-minify] [--update-lock] [--allow-over-budget]
//
// WP-B4: после tsc собирается снимок БД и фото (snapshot/build-snapshot.mjs → .build/snapshot, .build/images,
// site/demo/snapshot, site/images); его манифест входит в ключ эпохи, sha данных — в бандл.
//
// Отчёт: demo/web/.build/backend-report.json, metafile: demo/web/.build/backend-metafile.json.
// Код выхода: 0 — всё в порядке; 1 — ошибка сборки или проверки; 2 — бандл больше бюджета (6,5 МБ min / 1,5 МБ br).
//
// Review fixes:
//  - backend.js, build.json и THIRD_PARTY_NOTICES.txt пишутся в demo/web/.build/staging и копируются в site/ ТОЛЬКО
//    если все проверки пройдены (и бюджет соблюдён или --allow-over-budget): сборка с ошибками больше не оставляет в
//    site/ публикуемый на вид бандл (с запрещёнными строками ПДн, неразрешёнными импортами и т. п.); site/ сохраняет
//    прошлую удачную сборку целиком;
//  - posApiDiffSha256 — хэш `git diff HEAD -- pos-api` (изменения в индексе И в рабочем дереве; раньше `git diff`
//    без HEAD не видел подготовленных к коммиту изменений, хотя tsc их компилировал).
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, statfsSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { brotliCompressSync, constants as zc, gzipSync } from 'node:zlib';
import { createAliasPlugin, ownerOf } from './lib/alias-plugin.mjs';
import { SUPPORT_MODULES } from './alias-map.mjs';
import { checkDistAliases, checkMetafile, checkOutput, checkPiggybackAllow, checkProxyStubs } from './lib/checks.mjs';
import { API, BACKEND, BUILD, DIST, NM, OUT, ROOT, SHIMS, SITE } from './lib/paths.mjs';
import { copyPglite } from './lib/pglite.mjs';
import { buildNotices } from './notices/build-notices.mjs';
import { loadPiiMap } from './pii/pii-transform.mjs';
import { buildVfs } from './vfs/build-vfs.mjs';
import { computeEpoch, readAppVersion } from './lib/epoch.mjs';
import { DEMO_DATA, EPOCH_MIGRATION_BASE } from './demo-config.mjs';
import { buildSnapshot, SNAPSHOT_DIR } from './snapshot/build-snapshot.mjs';

const argv = new Set(process.argv.slice(2));
const minify = !argv.has('--no-minify');
const BUDGET = { minBytes: 6_500_000, brotliBytes: 1_500_000 };
const t00 = Date.now();
const log = (...a) => console.log(`[build-backend ${((Date.now() - t00) / 1000).toFixed(1)}s]`, ...a);

process.env.TEMP ||= `${ROOT}/.tmp`;
process.env.TMP ||= `${ROOT}/.tmp`;

function freeMB(p) {
  try {
    const s = statfsSync(p);
    return Math.round((s.bavail * s.bsize) / 1048576);
  } catch {
    return null;
  }
}
const free = freeMB(ROOT);
if (free !== null && free < 400) throw new Error(`мало места на диске сборки: ${free} МБ (нужно ≥ 400 МБ)`);

const report = { startedAt: new Date().toISOString(), minify, diskFreeMB: free };

// ---------------------------------------------------------------- 1. tsc → .build/pos-api-dist
if (!argv.has('--skip-tsc') || !existsSync(`${DIST}/bootstrap/create-app.js`)) {
  log('tsc -p pos-api/tsconfig.build.json →', DIST);
  if (existsSync(DIST)) rmSync(DIST, { recursive: true, force: true });
  const t = Date.now();
  execFileSync(process.execPath, [`${NM}/typescript/bin/tsc`, '-p', `${API}/tsconfig.build.json`, '--outDir', DIST, '--sourceMap', 'false'], {
    cwd: API,
    stdio: 'inherit',
  });
  report.tscMs = Date.now() - t;
} else report.tscMs = 'skipped';

// ---------------------------------------------------------------- 1б. снимок БД и фото (WP-B4)
// До ключа эпохи: манифест снимка входит в ключ (lib/epoch.mjs), а sha данных снимка — в бандл (DEMO_BUILD.snapshot:
// воркер берёт со страницы только тот снимок, с которым собран). --skip-snapshot — взять уже собранный.
let snapshotManifest = null;
if (!argv.has('--skip-snapshot')) {
  log('снимок БД и фото (snapshot/build-snapshot.mjs)…');
  const r = await buildSnapshot({ quiet: true });
  report.snapshot = { problems: r.report.problems, totalMs: r.report.totalMs, size: r.report.size, images: { products: r.report.images.products, files: r.report.images.files, bytes: r.report.images.bytes }, tables: r.report.tables.inSnapshot, dataSha256: r.report.dataSha256 };
  if (r.report.problems.length) {
    writeFileSync(`${BUILD}/backend-report.json`, JSON.stringify(report, null, 2));
    for (const p of r.report.problems) console.error('  FAIL снимок:', p);
    throw new Error(`снимок: ${r.report.problems.length} ошибок (см. .build/snapshot/report.json)`);
  }
  snapshotManifest = r.manifest;
  log(`снимок: ${r.manifest.tables.length} таблиц, data.copy ${(r.report.size.dataBytes / 1e6).toFixed(2)} МБ (gzip ${(r.report.size.dataGzip / 1e6).toFixed(2)}), фото ${r.report.images.products} товаров`);
} else if (existsSync(`${SNAPSHOT_DIR}/manifest.json`)) {
  snapshotManifest = JSON.parse(readFileSync(`${SNAPSHOT_DIR}/manifest.json`, 'utf8'));
  report.snapshot = 'skipped (взят собранный)';
} else report.snapshot = 'skipped (снимка нет: воркер загрузит каталог конвейером)';

// ---------------------------------------------------------------- 2. ревизия
const git = (...a) => execFileSync('git', ['-C', ROOT, ...a], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const untracked = git('ls-files', '--others', '--exclude-standard', '--', 'pos-api').split('\n').filter(Boolean).sort();
const untrackedHash = createHash('sha256');
for (const f of untracked) untrackedHash.update(f + '\0').update(readFileSync(`${ROOT}/${f}`)).update('\0');
const diffHead = git('diff', 'HEAD', '--', 'pos-api');
const build = {
  builtAt: new Date().toISOString(),
  gitHead: git('rev-parse', 'HEAD').trim(),
  /** sha256(`git diff HEAD -- pos-api`): подготовленные к коммиту и неподготовленные изменения вместе. */
  posApiDiffSha256: sha256(diffHead),
  posApiDiffBase: 'HEAD',
  posApiDiffBytes: Buffer.byteLength(diffHead),
  posApiStagedFiles: git('diff', '--cached', '--name-only', '--', 'pos-api').split('\n').filter(Boolean).length,
  posApiUntracked: untracked.length,
  posApiUntrackedSha256: untracked.length ? untrackedHash.digest('hex') : null,
  minify,
};
// WP-B3: ключ эпохи (хэш миграций до базы, генераторов данных и снимка — не id сборки, critic [15]) и версия
// приложения для MIN_APP_VERSION (pos-app/pubspec.yaml, critic [3]).
const epoch = computeEpoch();
build.epochKey = epoch.key;
build.epoch = epoch.inputs;
build.appVersion = readAppVersion(`${ROOT}/pos-app/pubspec.yaml`);
const demoBuildInfo = { appVersion: build.appVersion, epochKey: epoch.key, migrationBase: EPOCH_MIGRATION_BASE, stateFormat: DEMO_DATA.stateFormat };
if (snapshotManifest) {
  demoBuildInfo.snapshot = { format: snapshotManifest.format, dataSha256: snapshotManifest.data.sha256, skuCount: snapshotManifest.source?.catalog?.skuCount ?? null };
  build.snapshot = { ...demoBuildInfo.snapshot, bytes: snapshotManifest.data.bytes, tables: snapshotManifest.tables.length, rows: snapshotManifest.tables.reduce((a, t) => a + t.rows, 0), images: snapshotManifest.images ?? null, files: ['demo/snapshot/manifest.json', `demo/snapshot/${snapshotManifest.data.gzipFile}`] };
}
report.epoch = { key: epoch.key, appVersion: build.appVersion, laterMigrations: epoch.inputs.laterMigrations, snapshot: epoch.inputs.snapshot };
log(`эпоха ${epoch.key}; приложение ${build.appVersion}`);

// ---------------------------------------------------------------- 3. esbuild и проверки подмен
const esbuild = await import(pathToFileURL(`${NM}/esbuild/lib/main.js`).href);
report.esbuildVersion = esbuild.version;
report.distAliases = await checkDistAliases(esbuild);
// WP-B2: белый список подсадок pg-shim и модули единицы работы.
report.piggybackAllow = checkPiggybackAllow(SUPPORT_MODULES);
if (report.piggybackAllow.problems.length) throw new Error(`alias/piggyback-allow.json: ${report.piggybackAllow.problems.join('; ')}`);

// ---------------------------------------------------------------- 4. виртуальная fs
mkdirSync(OUT, { recursive: true });
const vfs = await buildVfs();
report.vfs = { ...vfs, external: Object.fromEntries(Object.entries(vfs.external).map(([k, v]) => [k, { bytes: v.bytes, sha256: v.sha256 }])) };
log(`vfs: встроено ${vfs.embeddedFiles} файлов (${vfs.embeddedBytes} Б), внешние ${vfs.externalFiles} (${vfs.externalBytes} Б)`);

// ---------------------------------------------------------------- 5. бандл
const piiMap = loadPiiMap();
const plugin = createAliasPlugin({ piiMap, report });
// Review fixes: вывод esbuild, уведомления и build.json — сначала в staging; в site/ — только после проверок (шаг 8).
const STAGING = `${BUILD}/staging`;
rmSync(STAGING, { recursive: true, force: true });
mkdirSync(STAGING, { recursive: true });
const t1 = Date.now();
const result = await esbuild.build({
  absWorkingDir: ROOT,
  entryPoints: [`${BACKEND}/backend-entry.mjs`],
  bundle: true,
  format: 'esm',
  platform: 'browser',
  target: 'es2023',
  outfile: `${STAGING}/backend.js`,
  metafile: true,
  minify,
  charset: 'utf8',
  keepNames: false,
  sourcemap: false,
  legalComments: 'external',
  banner: { js: '/*! Оптомстрой POS — веб-демо, браузерный бэкенд (тестовые данные). Лицензии сторонних компонентов: ../THIRD_PARTY_NOTICES.txt */' },
  logLevel: 'silent',
  mainFields: ['browser', 'module', 'main'],
  conditions: ['browser', 'module'],
  nodePaths: [NM],
  inject: [`${SHIMS}/inject.mjs`],
  define: {
    'process.env.NODE_ENV': '"production"',
    __dirname: '"/vfs"',
    __filename: '"/vfs/index.js"',
    // строкой: объект в define esbuild внедряет как модуль <define:…> (metafile считает его external)
    __POS_DEMO_BUILD_JSON__: JSON.stringify(JSON.stringify(demoBuildInfo)),
  },
  plugins: [plugin],
  supported: { 'top-level-await': true },
}).catch((e) => {
  report.errors = (e.errors ?? []).map((x) => `${x.text} @ ${x.location?.file}:${x.location?.line}`);
  writeFileSync(`${BUILD}/backend-report.json`, JSON.stringify(report, null, 2));
  for (const x of report.errors ?? []) console.error('ERROR', x);
  throw new Error(`esbuild: ${report.errors?.length ?? '?'} ошибок (см. .build/backend-report.json)`);
});
report.buildMs = Date.now() - t1;
report.warnings = result.warnings.map((e) => `${e.text} @ ${e.location?.file}:${e.location?.line}`);
writeFileSync(`${BUILD}/backend-metafile.json`, JSON.stringify(result.metafile));

const outBuf = readFileSync(`${STAGING}/backend.js`);
const outText = outBuf.toString('utf8');
report.size = {
  minBytes: outBuf.length,
  gzipBytes: gzipSync(outBuf, { level: 9 }).length,
  brotliBytes: brotliCompressSync(outBuf, { params: { [zc.BROTLI_PARAM_QUALITY]: 11, [zc.BROTLI_PARAM_SIZE_HINT]: outBuf.length } }).length,
  budget: BUDGET,
};
report.size.withinBudget = report.size.minBytes <= BUDGET.minBytes && report.size.brotliBytes <= BUDGET.brotliBytes;
log(`backend.js: ${(report.size.minBytes / 1e6).toFixed(2)} МБ min / ${(report.size.gzipBytes / 1e6).toFixed(2)} МБ gzip / ${(report.size.brotliBytes / 1e6).toFixed(2)} МБ brotli`);

const byPkg = {};
for (const [file, info] of Object.entries(result.metafile.inputs)) {
  const k = ownerOf(`${ROOT}/${file}`);
  byPkg[k] = (byPkg[k] ?? 0) + info.bytes;
}
report.inputFiles = Object.keys(result.metafile.inputs).length;
report.inputBytesByOwner = Object.fromEntries(Object.entries(byPkg).sort((a, b) => b[1] - a[1]));
const outMeta = Object.values(result.metafile.outputs).find((o) => o.entryPoint);
const outByOwner = {};
for (const [file, info] of Object.entries(outMeta?.inputs ?? {})) {
  const k = ownerOf(`${ROOT}/${file}`);
  outByOwner[k] = (outByOwner[k] ?? 0) + info.bytesInOutput;
}
report.outputBytesByOwner = Object.fromEntries(Object.entries(outByOwner).sort((a, b) => b[1] - a[1]).slice(0, 40));

// ---------------------------------------------------------------- 6. проверки бандла
const meta = checkMetafile(result.metafile);
const proxy = checkProxyStubs(result.metafile);
const outCheck = checkOutput(outText, piiMap.forbidden);
report.checks = {
  unresolvedImports: meta.unresolved,
  nodeImportsInMetafile: meta.nodeImports,
  nodeImportsInOutput: outCheck.nodeInOutput,
  unknownBuiltins: report.unknownBuiltins,
  missingPackagesEager: meta.missingEager,
  missingPackagesLazy: meta.missingLazy,
  proxyStubs: proxy.stubs,
  proxyUsesInBackendModules: proxy.proxyUses,
  piiForbiddenFound: outCheck.pii,
  piiSyntheticCashierReplaced: !!report.pii?.syntheticCashier,
  urlHostsInBundle: outCheck.urlHosts,
  dynamicImportsInBundle: outCheck.dynamicImports,
  esbuildDynamicRequireCalls: outCheck.dynamicRequire,
};
const failures = [];
if (meta.unresolved.length) failures.push(`неразрешённые (external) импорты: ${meta.unresolved.length}`);
if (meta.nodeImports.length || outCheck.nodeInOutput.length) failures.push('остались импорты node:*');
if (Object.keys(report.unknownBuiltins).length) failures.push('встроенные модули без шима');
if (meta.missingEager.length) failures.push(`пакет-«отсутствующий» подключён статическим импортом (на пути исполнения): ${JSON.stringify(meta.missingEager)}`);
if (proxy.stubs.length) failures.push(`Proxy-заглушки модулей: ${proxy.stubs.join(', ')}`);
if (outCheck.pii.length) failures.push(`в бандле запрещённые строки ПДн: ${outCheck.pii.map((x) => `${x.string}×${x.count}`).join(', ')}`);
if (!report.pii?.syntheticCashier) failures.push('synthetic-cashier.js не прошёл замену ПДн (не попал в бандл?)');
// sharp — только при сборке снимка (Node); в бандл не должен попасть ни один файл пакета (WP-B4).
const sharpInputs = Object.keys(result.metafile.inputs).filter((f) => /node_modules[\/](sharp|@img)[\/]/.test(f));
report.checks.sharpInBundle = sharpInputs;
if (sharpInputs.length) failures.push(`в бандле файлы sharp: ${sharpInputs.slice(0, 3).join(', ')}`);

// ---------------------------------------------------------------- 7. PGlite, лицензии, build.json
report.pglite = copyPglite({ updateLock: argv.has('--update-lock') });
log(`pglite ${report.pglite.version}: ${report.pglite.files} файлов, ${(report.pglite.bytes / 1e6).toFixed(1)} МБ`);
const legalFile = `${STAGING}/backend.js.LEGAL.txt`;
const legalText = existsSync(legalFile) ? readFileSync(legalFile, 'utf8') : '';
const notices = buildNotices({ metafile: result.metafile, legalText, pglite: report.pglite, build });
writeFileSync(`${STAGING}/THIRD_PARTY_NOTICES.txt`, notices.text);
if (existsSync(legalFile)) rmSync(legalFile); // текст перенесён в THIRD_PARTY_NOTICES.txt (раздел 5)
report.notices = { file: 'site/THIRD_PARTY_NOTICES.txt', bytes: Buffer.byteLength(notices.text), packages: notices.packages.length, packagesWithoutLicenseFile: notices.packages.filter((p) => p.note).map((p) => `${p.name}@${p.version} (${p.spdx})`), problems: notices.problems, warnings: notices.warnings, legalCommentsBytes: Buffer.byteLength(legalText) };
if (notices.problems.length) failures.push(`лицензии: ${notices.problems.join('; ')}`);

build.backend = {
  file: 'backend/backend.js',
  minBytes: report.size.minBytes,
  gzipBytes: report.size.gzipBytes,
  brotliBytes: report.size.brotliBytes,
  sha256: createHash('sha256').update(outBuf).digest('hex'),
  pglite: report.pglite.version,
  vfsExternal: Object.fromEntries(Object.entries(vfs.external).map(([k, v]) => [k, v.url])),
};
writeFileSync(`${STAGING}/build.json`, JSON.stringify(build, null, 2) + '\n');
report.build = build;
report.failures = failures;

// ---------------------------------------------------------------- 8. staging → site (только чистая сборка)
const overBudget = !report.size.withinBudget && !argv.has('--allow-over-budget');
if (!failures.length && !overBudget) {
  mkdirSync(OUT, { recursive: true });
  // build.json — последним: по нему тесты и страница узнают, что backend.js на месте и совпадает по sha.
  copyFileSync(`${STAGING}/backend.js`, `${OUT}/backend.js`);
  copyFileSync(`${STAGING}/THIRD_PARTY_NOTICES.txt`, `${SITE}/THIRD_PARTY_NOTICES.txt`);
  copyFileSync(`${STAGING}/build.json`, `${OUT}/build.json`);
  rmSync(STAGING, { recursive: true, force: true });
  report.published = { to: 'site/backend', at: new Date().toISOString() };
} else {
  report.published = null;
  report.staging = STAGING;
}
report.totalMs = Date.now() - t00;
writeFileSync(`${BUILD}/backend-report.json`, JSON.stringify(report, null, 2));

log(`проверки: ${failures.length ? 'ОШИБКИ' : 'ok'}; отчёт ${BUILD}/backend-report.json`);
for (const f of failures) console.error('  FAIL', f);
if (!report.size.withinBudget) console.error(`  BUDGET бандл больше бюджета: ${report.size.minBytes} Б min (≤ ${BUDGET.minBytes}), ${report.size.brotliBytes} Б brotli (≤ ${BUDGET.brotliBytes})`);
if (!report.published) console.error(`  НЕ ОПУБЛИКОВАНО в site/: сборка осталась в ${STAGING}; site/backend — прежняя удачная сборка`);
process.exitCode = failures.length ? 1 : overBudget ? 2 : 0;

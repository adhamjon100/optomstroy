// Сборка публикуемого сайта веб-демо demo/web/site (WP-N1; review fixes, critic [21]).
//
//   node demo/web/tools/assemble-site.mjs [--flutter <каталог сборки Flutter>] [--json <отчёт>]
//
// На входе (ничего не скачивается, flutter/dart здесь НЕ запускаются):
//   - site/backend/**, site/demo/snapshot/**, site/images/**, site/THIRD_PARTY_NOTICES.txt — node demo/web/backend/build-backend.mjs;
//   - demo/web/.build/flutter — `flutter build web … -t lib/app/demo/main_web_demo.dart -o …\.build\flutter`
//     (build-web-demo.ps1, шаг Flutter; plan WP-N1 п. 4);
//   - demo/web/.build/drift_worker.js (dart compile js), demo/web/.build/sqlite3.wasm (копия из drift, sha256 сверяется);
//   - Roboto из Flutter SDK (material_fonts/roboto-regular.ttf) → fonts/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2
//     (адрес fontFallbackBaseUrl движка: запасной шрифт берётся с сайта, а не с fonts.gstatic.com);
//   - demo/web/site-src — страница (index.html вместо index.html Flutter, demo-*.js/css, robots.txt …) через
//     site-src/build-site.mjs --out (там же проверка ПДн и путей машины);
//   - pdf.js для предпросмотра PDF (fix:pdfcsp): pdfjs-dist 5.4.296 из pos-api/node_modules (версия и sha256 —
//     tools/pdfjs-files.mjs) и загрузчик site-src/pdfjs/pdf.min.js → site/pdfjs/ (вместо unpkg.com).
// Что делает:
//   1. чистит site/, кроме вывода build-backend (backend/, demo/snapshot/, images/, THIRD_PARTY_NOTICES.txt);
//   2. копирует сборку Flutter без index.html (наш), flutter_service_worker.js (пустой, не регистрируется),
//      .last_build_id, *.symbols и canvaskit/skwasm* (dart2js их не грузит); из .js убирает строки
//      `//# sourceMappingURL=…` (карт на сайте нет);
//   3. drift_worker.js, sqlite3.wasm, Roboto, pdf.js (pdfjs/; раздел 7 в THIRD_PARTY_NOTICES.txt), страницу;
//   4. demo/build.json — ИЗ site/backend/build.json (один источник ключа эпохи: epochKey страницы = ключ бэкенда) +
//      отпечатки Flutter и страницы; buildId — sha256 всех трёх частей (новая выкладка видна, данные — по эпохе);
//   5. _headers и _redirects из tools/site-headers.mjs (noindex, CSP, типы .wasm/.data/.gz, /api/* → 404, фото);
//   6. отчёт: файлы, размеры, сжатие (gzip/brotli — оценка трафика Netlify) → demo/web/.build/site-report.json.
// Код выхода 0 — сайт собран; 1 — нет входных данных или ошибка (что именно — в выводе). Проверки публикации —
// tools/check-site.mjs (отдельно, после сборки).
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { brotliCompressSync, constants as zc, gzipSync } from 'node:zlib';
import { headerRules, renderHeaders, renderRedirects } from './site-headers.mjs';
import { PDFJS, PDFJS_SITE_FILES } from './pdfjs-files.mjs';
import { ROBOTO_SITE_PATH, robotoSource, withPdfjsNotice } from '../backend/notices/build-notices.mjs';
import { PUBLISHED } from '../site-src/build-site.mjs';

const HERE = dirname(fileURLToPath(import.meta.url)).replace(/\\/g, '/');
const WEB = resolve(HERE, '..').replace(/\\/g, '/');
const ROOT = resolve(WEB, '../..').replace(/\\/g, '/');
const SITE = `${WEB}/site`;
const BUILD = `${WEB}/.build`;
const argv = process.argv.slice(2);
const arg = (k, d) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : d);
const FLUTTER = resolve(arg('--flutter', `${BUILD}/flutter`)).replace(/\\/g, '/');
const REPORT = arg('--json', `${BUILD}/site-report.json`);
/** sqlite3.wasm из drift 2.30.1 (extension/devtools/build) — проверен в Chrome (handoff «APP: compile and boot»). */
export const SQLITE3_WASM = { bytes: 706316, sha256: '3981a48433ab7b554e5b602b960a18bbbae6ab8d2bf5d906646ca5beeea197d6' };
/** Вывод build-backend.mjs — сборка сайта его не трогает. */
const KEEP = ['backend', 'demo/snapshot', 'images', 'THIRD_PARTY_NOTICES.txt'];
const SOURCE_MAP_LINE = /^[ \t]*\/\/[#@] sourceMappingURL=.*$\n?/gm;
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const norm = (p) => p.replace(/\\/g, '/');
const t0 = Date.now();
const log = (...a) => console.log(`[assemble-site ${((Date.now() - t0) / 1000).toFixed(1)}s]`, ...a);
process.env.TEMP ||= `${ROOT}/.tmp`;
process.env.TMP ||= `${ROOT}/.tmp`;

const walk = (dir) => (existsSync(dir) ? readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [norm(join(dir, e.name))])) : []);

function fail(msg) {
  console.error(`ОШИБКА: ${msg}`);
  process.exit(1);
}

// ---------------------------------------------------------------- 0. входные данные
const backendBuild = existsSync(`${SITE}/backend/build.json`) ? JSON.parse(readFileSync(`${SITE}/backend/build.json`, 'utf8')) : null;
if (!backendBuild || !existsSync(`${SITE}/backend/backend.js`)) fail('нет site/backend/backend.js и build.json — сначала node demo/web/backend/build-backend.mjs');
if (sha256(readFileSync(`${SITE}/backend/backend.js`)) !== backendBuild.backend?.sha256) fail('site/backend/backend.js ≠ build.json (sha256) — пересоберите бэкенд');
if (!/^[0-9a-f]{16}$/.test(String(backendBuild.epochKey))) fail(`в site/backend/build.json нет ключа эпохи: ${backendBuild.epochKey}`);
for (const f of ['demo/snapshot/manifest.json', 'THIRD_PARTY_NOTICES.txt']) if (!existsSync(`${SITE}/${f}`)) fail(`нет site/${f} — сначала build-backend.mjs`);
if (!existsSync(`${FLUTTER}/main.dart.js`) || !existsSync(`${FLUTTER}/flutter_bootstrap.js`)) fail(`нет сборки Flutter в ${FLUTTER} (main.dart.js, flutter_bootstrap.js) — шаг Flutter build-web-demo.ps1`);
if (!existsSync(`${BUILD}/drift_worker.js`)) fail('нет demo/web/.build/drift_worker.js (dart compile js, plan WP-N1 п. 5)');
const sqlite = existsSync(`${BUILD}/sqlite3.wasm`) ? readFileSync(`${BUILD}/sqlite3.wasm`) : null;
if (!sqlite || sqlite.length !== SQLITE3_WASM.bytes || sha256(sqlite) !== SQLITE3_WASM.sha256) fail(`demo/web/.build/sqlite3.wasm отсутствует или не тот (ожидается ${SQLITE3_WASM.bytes} Б, sha256 ${SQLITE3_WASM.sha256.slice(0, 12)}…)`);
const rob = robotoSource();
if (!rob || !existsSync(rob.font)) fail(`нет Roboto из Flutter SDK (${rob?.font ?? 'FLUTTER_ROOT не найден'}) — задайте FLUTTER_ROOT или FLUTTER_MATERIAL_FONTS`);
// pdf.js (fix:pdfcsp): ровно закреплённая версия и файлы — иначе ошибка (не скачивается; другая версия — правка pdfjs-files.mjs)
{
  const pj = existsSync(`${PDFJS.source}/package.json`) ? JSON.parse(readFileSync(`${PDFJS.source}/package.json`, 'utf8')) : null;
  if (!pj || pj.name !== PDFJS.package || pj.version !== PDFJS.version) fail(`нет ${PDFJS.package} ${PDFJS.version} в ${PDFJS.source} (найдено: ${pj ? `${pj.name} ${pj.version}` : 'ничего'}) — нужен pos-api/node_modules (npm ci в pos-api) или PDFJS_DIST`);
  for (const f of PDFJS.files) {
    const b = existsSync(`${PDFJS.source}/${f.from}`) ? readFileSync(`${PDFJS.source}/${f.from}`) : null;
    if (!b || b.length !== f.bytes || sha256(b) !== f.sha256) fail(`${PDFJS.package}/${f.from}: нет файла или не тот (ожидается ${f.bytes} Б, sha256 ${f.sha256.slice(0, 12)}…)`);
  }
  if (!existsSync(`${WEB}/${PDFJS.loader.from}`)) fail(`нет загрузчика pdf.js demo/web/${PDFJS.loader.from}`);
}

// ---------------------------------------------------------------- 1. очистка site/ (кроме вывода build-backend)
const keepAbs = KEEP.map((k) => `${SITE}/${k}`);
let removed = 0;
for (const f of walk(SITE)) {
  if (keepAbs.some((k) => f === k || f.startsWith(`${k}/`))) continue;
  rmSync(f, { force: true });
  removed++;
}
// пустые каталоги
const prune = (d) => {
  for (const e of readdirSync(d, { withFileTypes: true })) if (e.isDirectory()) prune(join(d, e.name));
  if (d !== SITE && readdirSync(d).length === 0 && !keepAbs.includes(norm(d))) rmSync(d, { recursive: true, force: true });
};
prune(SITE);
log(`site/: удалено ${removed} файлов прошлой сборки (оставлены ${KEEP.join(', ')})`);

// ---------------------------------------------------------------- 2. Flutter
const SKIP = [/^index\.html$/, /^flutter_service_worker\.js$/, /^\.last_build_id$/, /\.symbols$/i, /\.map$/i, /^canvaskit\/skwasm[^/]*$/, /\.deps$/i];
const flutterFiles = [];
const stripped = [];
for (const abs of walk(FLUTTER)) {
  const rel = norm(relative(FLUTTER, abs));
  if (SKIP.some((re) => re.test(rel))) continue;
  const to = `${SITE}/${rel}`;
  mkdirSync(dirname(to), { recursive: true });
  if (/\.js$/i.test(rel)) {
    const src = readFileSync(abs, 'utf8');
    const out = src.replace(SOURCE_MAP_LINE, '');
    if (out !== src) stripped.push(rel);
    writeFileSync(to, out);
  } else copyFileSync(abs, to);
  flutterFiles.push(rel);
}
log(`Flutter: ${flutterFiles.length} файлов из ${FLUTTER}; убрано sourceMappingURL: ${stripped.join(', ') || '—'}`);

// ---------------------------------------------------------------- 3. drift, sqlite3, Roboto, страница
{
  const src = readFileSync(`${BUILD}/drift_worker.js`, 'utf8');
  const out = src.replace(SOURCE_MAP_LINE, '');
  if (out !== src) stripped.push('drift_worker.js');
  writeFileSync(`${SITE}/drift_worker.js`, out);
  copyFileSync(`${BUILD}/sqlite3.wasm`, `${SITE}/sqlite3.wasm`);
  mkdirSync(dirname(`${SITE}/${ROBOTO_SITE_PATH}`), { recursive: true });
  copyFileSync(rob.font, `${SITE}/${ROBOTO_SITE_PATH}`);
}
{
  // pdf.js: файлы пакета без изменений + загрузчик; раздел 7 уведомлений (заменяется, а не дублируется)
  mkdirSync(`${SITE}/pdfjs`, { recursive: true });
  for (const f of PDFJS.files) copyFileSync(`${PDFJS.source}/${f.from}`, `${SITE}/${f.to}`);
  copyFileSync(`${WEB}/${PDFJS.loader.from}`, `${SITE}/${PDFJS.loader.to}`);
  const notices = `${SITE}/THIRD_PARTY_NOTICES.txt`;
  const licenseText = readFileSync(`${PDFJS.source}/LICENSE`, 'utf8');
  writeFileSync(notices, withPdfjsNotice(readFileSync(notices, 'utf8'), { ...PDFJS, licenseText }));
  log(`pdf.js: ${PDFJS.package} ${PDFJS.version} → ${PDFJS_SITE_FILES.join(', ')}; THIRD_PARTY_NOTICES.txt — раздел 7`);
}
log('страница: site-src/build-site.mjs --out site …');
try {
  execFileSync(process.execPath, [`${WEB}/site-src/build-site.mjs`, '--out', SITE], { stdio: ['ignore', 'pipe', 'inherit'], cwd: ROOT });
} catch (e) {
  fail(`site-src/build-site.mjs: ${e?.stdout?.toString?.().slice(-1500) ?? e.message}`);
}

// ---------------------------------------------------------------- 4. demo/build.json (один источник ключа эпохи)
const pageFiles = [...PUBLISHED, ...PDFJS_SITE_FILES];
const pageHash = createHash('sha256');
for (const f of pageFiles) pageHash.update(f).update('\0').update(readFileSync(`${SITE}/${f}`)).update('\0');
const flutterHash = createHash('sha256');
for (const f of [...flutterFiles].sort()) flutterHash.update(f).update('\0').update(readFileSync(`${SITE}/${f}`)).update('\0');
const parts = { backend: backendBuild.backend.sha256, snapshot: backendBuild.snapshot?.dataSha256 ?? null, flutter: flutterHash.digest('hex'), page: pageHash.digest('hex') };
const buildId = createHash('sha256').update(JSON.stringify(parts)).digest('hex').slice(0, 16);
const mainDart = readFileSync(`${SITE}/main.dart.js`);
const demoBuild = {
  $comment: 'СГЕНЕРИРОВАНО demo/web/tools/assemble-site.mjs: epochKey — из backend/build.json (ключ данных демо; сменился — страница предупреждает «Демо обновлено» и начинает заново), buildId — отпечаток выкладки.',
  buildId,
  epochKey: backendBuild.epochKey,
  builtAt: new Date().toISOString(),
  gitHead: backendBuild.gitHead,
  posApiDiffSha256: backendBuild.posApiDiffSha256,
  posApiDiffBase: backendBuild.posApiDiffBase ?? null,
  appVersion: backendBuild.appVersion,
  backend: { sha256: backendBuild.backend.sha256, builtAt: backendBuild.builtAt },
  snapshot: backendBuild.snapshot ? { dataSha256: backendBuild.snapshot.dataSha256 } : null,
  flutter: { filesSha256: parts.flutter, mainDartJsSha256: sha256(mainDart), mainDartJsBytes: mainDart.length, builtAt: statSync(`${FLUTTER}/main.dart.js`).mtime.toISOString() },
  page: { filesSha256: parts.page },
};
mkdirSync(`${SITE}/demo`, { recursive: true });
writeFileSync(`${SITE}/demo/build.json`, `${JSON.stringify(demoBuild, null, 2)}\n`);
log(`demo/build.json: buildId ${buildId}, epochKey ${demoBuild.epochKey} (= backend/build.json)`);

// ---------------------------------------------------------------- 5. _headers, _redirects
const all = walk(SITE).map((f) => norm(relative(SITE, f)));
writeFileSync(`${SITE}/_headers`, renderHeaders(headerRules(all)));
writeFileSync(`${SITE}/_redirects`, renderRedirects());
// ещё раз: ни одного *.map / *.symbols
for (const f of walk(SITE)) if (/\.(map|symbols)$/i.test(f)) rmSync(f, { force: true });

// ---------------------------------------------------------------- 6. отчёт
const files = walk(SITE)
  .map((abs) => {
    const rel = norm(relative(SITE, abs));
    const st = statSync(abs);
    return { file: rel, bytes: st.size };
  })
  .sort((a, b) => b.bytes - a.bytes);
const total = files.reduce((s, f) => s + f.bytes, 0);
const est = { gzip: 0, brotli: 0 };
for (const f of files.slice(0, 25)) {
  if (/\.(png|webp|gz)$/i.test(f.file)) continue;
  const b = readFileSync(`${SITE}/${f.file}`);
  f.gzip = gzipSync(b, { level: 9 }).length;
  if (b.length < 12_000_000) f.brotli = brotliCompressSync(b, { params: { [zc.BROTLI_PARAM_QUALITY]: 9, [zc.BROTLI_PARAM_SIZE_HINT]: b.length } }).length;
  est.gzip += f.gzip;
  est.brotli += f.brotli ?? f.gzip;
}
const report = {
  at: new Date().toISOString(),
  flutter: FLUTTER,
  buildId,
  epochKey: demoBuild.epochKey,
  files: files.length,
  bytes: total,
  over10MB: files.filter((f) => f.bytes > 10 * 1024 * 1024).map((f) => f.file),
  sourceMapLinesRemoved: stripped,
  largest: files.slice(0, 25),
  compressedTop25: est,
};
mkdirSync(dirname(REPORT), { recursive: true });
writeFileSync(REPORT, `${JSON.stringify(report, null, 1)}\n`);
log(`site/: ${files.length} файлов, ${(total / 1e6).toFixed(1)} МБ; больше 10 МБ: ${report.over10MB.join(', ') || 'нет'}; отчёт ${REPORT}`);

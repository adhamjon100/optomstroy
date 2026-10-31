// Проверка публикуемого сайта веб-демо перед выкладкой (WP-N1 «check-site»; review fixes, critic [10]–[12], [21]).
//
//   node demo/web/tools/check-site.mjs [--site <каталог>] [--json <отчёт>] [--no-secrets-script]
//
// Проверяет собранный site/ (tools/assemble-site.mjs):
//   1. состав: страница, Flutter, drift, sqlite3, Roboto, бэкенд, PGlite, снимок, фото, _headers, _redirects, лицензии;
//   2. demo/build.json: epochKey = backend/build.json (один источник), buildId, ревизия;
//   3. нет *.map, *.symbols, canvaskit/skwasm*, flutter_service_worker.js, *.deps; нигде нет ссылки sourceMappingURL;
//   4. нет приватных ключей, JWT, путей машины разработки (D:/optomstroy, C:/Users, C:/dev), токена 1С константой;
//      file:/// — только Uri-код Dart SDK в main.dart.js и drift_worker.js; localhost/127.0.0.1 — перечень по файлам;
//   5. нет прежних ФИО и телефонов клиентов (backend/pii-map.json forbidden) ни в одном текстовом файле, включая
//      main.dart.js и NOTICES (check_secrets пропускает файлы больше 5 МБ — поэтому свой поиск);
//   6. scripts/check_secrets.py --root demo/web/site --all — 0 находок (только чтение репозитория);
//   7. _headers: X-Robots-Tag noindex и Content-Security-Policy на «/*» (без чужих хостов; хэш скрипта печати пакета
//      printing = тексту в main.dart.js), типы .wasm/.data/.gz/.mjs/LICENSE; _redirects: /api/* 404!, фото; robots.txt
//      без «Disallow: /» (иначе поисковик не прочтёт noindex); meta robots в index.html;
//   8. THIRD_PARTY_NOTICES.txt: разделы 1–7 (7 — pdf.js), перечень компонентов Flutter соответствует assets/NOTICES
//      сайта; ссылки «Лицензии» в панели и на demo-closed.html;
//   9. размеры: всего, файлы больше 10 МБ (предупреждение: лимит Netlify Drop), оценка сжатого трафика;
//  10. pdf.js (fix:pdfcsp): pdfjs/ — файлы pdfjs-dist с закреплёнными sha256 (tools/pdfjs-files.mjs), загрузчик = исходнику,
//      demo-boot.js задаёт dartPdfJsBaseUrl, main.dart.js его читает (пакет printing не пойдёт на unpkg.com).
// Код выхода: 0 — можно выкладывать; 1 — есть ошибки (перечислены).
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { headersFor, matchPath, parseHeaders, parseRedirects, PRINTING_PRINT_SCRIPT, PRINTING_PRINT_SCRIPT_HASH } from './site-headers.mjs';
import { PDFJS, PDFJS_SITE_FILES } from './pdfjs-files.mjs';

const HERE = dirname(fileURLToPath(import.meta.url)).replace(/\\/g, '/');
const WEB = resolve(HERE, '..').replace(/\\/g, '/');
const ROOT = resolve(WEB, '../..').replace(/\\/g, '/');
const argv = process.argv.slice(2);
const arg = (k, d) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : d);
const SITE = resolve(arg('--site', `${WEB}/site`)).replace(/\\/g, '/');
const REPORT = arg('--json', `${WEB}/.build/check-site.json`);
const norm = (p) => p.replace(/\\/g, '/');
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const walk = (dir) => (existsSync(dir) ? readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [norm(join(dir, e.name))])) : []);

const checks = [];
const warnings = [];
const add = (name, ok, evidence) => {
  checks.push({ name, ok: !!ok, evidence: evidence === undefined ? null : evidence });
  console.log(`${ok ? 'OK  ' : 'FAIL'} ${name}${evidence !== undefined ? ` — ${typeof evidence === 'string' ? evidence : JSON.stringify(evidence)}`.slice(0, 600) : ''}`);
};

const files = walk(SITE).map((f) => norm(relative(SITE, f)));
const has = (f) => files.includes(f);
const read = (f) => readFileSync(`${SITE}/${f}`, 'utf8');

// ---------------------------------------------------------------- 1. состав
const REQUIRED = [
  'index.html', 'demo-closed.html', 'demo-boot.js', 'demo-bridge.js', 'demo-panel.js', 'demo-lock.js', 'demo-reset.js', 'demo-env.js', 'demo-data.js',
  'demo-tokens.css', 'demo-screen.css', 'demo-panel.css', 'api-unavailable.json', 'robots.txt', '_headers', '_redirects',
  'flutter_bootstrap.js', 'main.dart.js', 'manifest.json', 'favicon.png', 'canvaskit/canvaskit.js', 'canvaskit/canvaskit.wasm', 'canvaskit/chromium/canvaskit.js', 'canvaskit/chromium/canvaskit.wasm',
  'assets/NOTICES', 'assets/FontManifest.json', 'assets/AssetManifest.bin', 'assets/fonts/MaterialIcons-Regular.otf',
  'drift_worker.js', 'sqlite3.wasm', 'fonts/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2',
  'backend/backend.js', 'backend/build.json', 'backend/pglite/index.js', 'backend/pglite/pglite.wasm', 'backend/pglite/pglite.data', 'backend/pglite/LICENSE',
  'demo/build.json', 'demo/snapshot/manifest.json', 'THIRD_PARTY_NOTICES.txt',
  ...PDFJS_SITE_FILES,
];
const missing = REQUIRED.filter((f) => !has(f));
add('состав сайта: все обязательные файлы на месте', missing.length === 0, missing.length ? missing : `${REQUIRED.length} файлов`);
const images = files.filter((f) => /^images\/[0-9a-f]{64}\/(thumb|card|full)\.webp$/.test(f));
add('фото товаров: images/<sha>/{thumb,card,full}.webp', images.length >= 600, `${images.length} файлов`);

// ---------------------------------------------------------------- 2. demo/build.json
let demoBuild = null;
let backendBuild = null;
try {
  demoBuild = JSON.parse(read('demo/build.json'));
  backendBuild = JSON.parse(read('backend/build.json'));
} catch (e) {
  add('demo/build.json и backend/build.json читаются', false, String(e?.message ?? e));
}
if (demoBuild && backendBuild) {
  add('demo/build.json: epochKey = backend/build.json epochKey (один источник ключа эпохи)', demoBuild.epochKey === backendBuild.epochKey && /^[0-9a-f]{16}$/.test(demoBuild.epochKey), { page: demoBuild.epochKey, backend: backendBuild.epochKey });
  add('demo/build.json: buildId, ревизия pos-api (git diff HEAD), sha бандла = файлу', /^[0-9a-f]{16}$/.test(demoBuild.buildId) && /^[0-9a-f]{40}$/.test(demoBuild.gitHead) && demoBuild.backend?.sha256 === sha256(readFileSync(`${SITE}/backend/backend.js`)) && demoBuild.posApiDiffBase === 'HEAD', { buildId: demoBuild.buildId, gitHead: demoBuild.gitHead?.slice(0, 8), diff: demoBuild.posApiDiffSha256?.slice(0, 12), base: demoBuild.posApiDiffBase });
  const snap = JSON.parse(read('demo/snapshot/manifest.json'));
  add('снимок: файл данных на месте, sha = backend/build.json', has(`demo/snapshot/${snap.data?.gzipFile}`) && snap.data?.sha256 === backendBuild.snapshot?.dataSha256, { file: snap.data?.gzipFile, sha: snap.data?.sha256?.slice(0, 12) });
}

// ---------------------------------------------------------------- 3. мусор сборки и sourceMappingURL
const junk = files.filter((f) => /\.(map|symbols|deps)$/i.test(f) || /^canvaskit\/skwasm/.test(f) || /(^|\/)flutter_service_worker\.js$/.test(f) || /(^|\/)\.last_build_id$/.test(f));
add('нет *.map, *.symbols, *.deps, canvaskit/skwasm*, flutter_service_worker.js', junk.length === 0, junk.slice(0, 10));
const codeFiles = files.filter((f) => /\.(js|mjs|cjs|css|html)$/i.test(f));
const smap = codeFiles.filter((f) => /[#@]\s*sourceMappingURL=/.test(read(f)));
add('нигде нет ссылки sourceMappingURL', smap.length === 0, smap.slice(0, 10));

// ---------------------------------------------------------------- 4–5. запрещённые строки
const TEXT = files.filter((f) => /\.(js|mjs|cjs|json|html|css|txt|svg|webmanifest)$/i.test(f) || /(^|\/)(NOTICES|_headers|_redirects)$/.test(f)).filter((f) => !/^images\//.test(f) && statSync(`${SITE}/${f}`).size < 40_000_000);
const pii = JSON.parse(readFileSync(`${WEB}/backend/pii-map.json`, 'utf8')).forbidden ?? [];
const RULES = [
  { name: 'приватный ключ', re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/g },
  { name: 'JWT', re: /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g },
  { name: 'путь машины разработки', re: /[A-Za-z]:[\\/](?:optomstroy|Users|dev)[\\/]|\\Users\\Farruh/gi },
  { name: 'токен 1С константой', re: /ONEC_HS_TOKEN\s*[:=]\s*["'][^"']{6,}["']/g },
  { name: 'ключ SMSPro константой', re: /SMSPRO_(?:API_)?(?:KEY|TOKEN|PASSWORD)\s*[:=]\s*["'][^"']{6,}["']/g },
  { name: 'AWS/Stripe/Slack-ключ', re: /AKIA[0-9A-Z]{16}|sk_live_[0-9a-zA-Z]{20,}|xox[baprs]-[0-9a-zA-Z-]{10,}/g },
];
// Допустимые совпадения (обоснование): file:/// — код Uri среды Dart в main.dart.js и drift_worker.js (handoff «APP:
// compile and boot»); в backend/backend.js — import.meta.url модулей dist, подменённый на виртуальную fs
// (file:///vfs/pos-api/dist/…, lib/alias-plugin.mjs), не путь машины.
const FILE_URI_ALLOW = { 'main.dart.js': 2, 'drift_worker.js': 2, 'backend/backend.js': 4 };
const hits = [];
const piiHits = [];
let piiSeesCyr = false; // проверка самой проверки: кириллица main.dart.js после раскодирования видна
const fileUri = {};
const local = {};
for (const f of TEXT) {
  const s = read(f);
  for (const r of RULES) for (const m of s.matchAll(r.re)) hits.push(`${f}: ${r.name}: ${m[0].slice(0, 60)}`);
  // dart2js пишет кириллицу как \uXXXX (в main.dart.js ~135 тыс. таких escape): без раскодирования кириллические ФИО
  // из pii-map там не видны (ревью сайта SITE-01, WEB-KI-33).
  const sd = s.includes('\\u') ? s.replace(/\\u([0-9a-fA-F]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16))) : s;
  for (const x of pii) if (s.includes(x) || sd.includes(x)) piiHits.push(`${f}: «${x}»`);
  if (f === 'main.dart.js') piiSeesCyr = sd.includes('Касса');
  const fu = (s.match(/file:\/\/\//g) ?? []).length;
  if (fu) fileUri[f] = fu;
  const lh = (s.match(/\blocalhost\b|127\.0\.0\.1/g) ?? []).length;
  if (lh) local[f] = lh;
}
add('нет приватных ключей, JWT, путей машины, токенов-констант', hits.length === 0, hits.slice(0, 10));
add(`нет прежних ФИО и телефонов клиентов (pii-map.json, ${pii.length} строк) ни в одном текстовом файле`, piiHits.length === 0 && pii.length >= 90 && piiSeesCyr, piiHits.length ? piiHits.slice(0, 10) : { cyrillicInMainDartJsVisible: piiSeesCyr });
const badFileUri = Object.entries(fileUri).filter(([f, n]) => !(f in FILE_URI_ALLOW) || n > FILE_URI_ALLOW[f]);
add('file:/// — только Uri-код Dart SDK (main.dart.js, drift_worker.js) и виртуальная fs бандла (file:///vfs/…)', badFileUri.length === 0 && !/file:\/\/\/(?!vfs\/)/.test(read('backend/backend.js')), fileUri);
// localhost/127.0.0.1: в demo-boot.js — только проверка «запущено на машине разработчика» (isLocalDev: ?initExtra=,
// ?storage= переживают перезагрузку лишь там); в бандлах — код библиотек и FakeSocket моста. В HTML и build.json — нельзя.
const pageLocal = Object.keys(local).filter((f) => /^(index\.html|demo-closed\.html|demo\/build\.json|_headers|_redirects)$/.test(f));
const bootLocal = has('demo-boot.js') ? (read('demo-boot.js').match(/\blocalhost\b|127\.0\.0\.1/g) ?? []).length : 0;
add('HTML, заголовки и demo/build.json без localhost/127.0.0.1; в demo-boot.js — только isLocalDev (перечень по файлам)', pageLocal.length === 0 && bootLocal <= 6 && /function isLocalDev\(\)/.test(read('demo-boot.js')), local);

// ---------------------------------------------------------------- 6. check_secrets.py
// Находки generic-secret-assignment в PGlite — привязки экспорта Emscripten к символам PostgreSQL
// (символы вроде _outToken и _check_password_hook, привязанные к Module._…), а не секреты. Принимаются,
// только если файл — проверенная копия пакета (sha256 = backend/pglite.lock.json) и значение — `Module.…`.
function pgliteFindingAccepted(line) {
  const m = /^(backend\/pglite\/[^:]+\.js):\d+: \[generic-secret-assignment\] (Modu…)/.exec(line);
  if (!m) return false;
  const lock = JSON.parse(readFileSync(`${WEB}/backend/pglite.lock.json`, 'utf8'));
  const rel = `dist/${m[1].replace(/^backend\/pglite\//, '')}`;
  const want = lock.shipped?.[rel] ?? lock.files?.[rel];
  return !!want && sha256(readFileSync(`${SITE}/${m[1]}`)) === want.sha256;
}
// Находки в pdf.js (fix:pdfcsp) — копирование свойств форм XFA и редактора (accessKey, passwordChar, hasAltText) в
// минифицированном коде, а не секреты. Принимаются, только если файл — закреплённая копия pdfjs-dist (sha256 =
// tools/pdfjs-files.mjs) и значение — выражение JS (`e.…`, `!!this.…`).
function pdfjsFindingAccepted(line) {
  const m = /^(pdfjs\/[^:]+\.mjs):\d+: \[generic-secret-assignment\] (e\.[a-z]{2}…|!!th…)/.exec(line);
  if (!m) return false;
  const want = PDFJS.files.find((f) => f.to === m[1]);
  return !!want && sha256(readFileSync(`${SITE}/${m[1]}`)) === want.sha256;
}
if (!argv.includes('--no-secrets-script')) {
  let out = '';
  let code = 0;
  try {
    out = execFileSync('python', ['-I', '-X', 'utf8', `${ROOT}/scripts/check_secrets.py`, '--root', SITE, '--all'], { encoding: 'utf8', env: { ...process.env, PYTHONIOENCODING: 'utf-8' }, stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    code = e.status ?? 1;
    out = `${(e.stdout ?? '').toString()}\n${(e.stderr ?? '').toString()}`;
  }
  const findings = out.split(/\r?\n/).filter((l) => /^[^\s].*:\d+: \[/.test(l));
  const accepted = findings.filter(pgliteFindingAccepted);
  const acceptedPdfjs = findings.filter(pdfjsFindingAccepted);
  const rest = findings.filter((l) => !accepted.includes(l) && !acceptedPdfjs.includes(l));
  const summaryLine = out.trim().split(/\r?\n/).filter((l) => /check_secrets:/.test(l)).pop() ?? '';
  add('scripts/check_secrets.py --root site --all: 0 находок (кроме привязок Emscripten в проверенной копии PGlite и имён свойств в проверенной копии pdf.js)', rest.length === 0 && (code === 0 || accepted.length + acceptedPdfjs.length === findings.length) && /файлов проверено/.test(summaryLine), { summary: summaryLine, acceptedPglite: accepted.length, acceptedPdfjs: acceptedPdfjs.length, other: rest.slice(0, 10) });
}

// ---------------------------------------------------------------- 7. заголовки, перенаправления, индексация
if (has('_headers') && has('_redirects')) {
  const rules = parseHeaders(read('_headers'));
  const root = headersFor(rules, '/index.html');
  add('_headers: «/*» — X-Robots-Tag noindex, nofollow, noarchive', /noindex/.test(root['X-Robots-Tag'] ?? '') && /nofollow/.test(root['X-Robots-Tag'] ?? ''), root['X-Robots-Tag']);
  const csp = root['Content-Security-Policy'] ?? '';
  // Источники CSP — только ключевые слова, хэши, blob:/data:; ни одного хоста или «*» (pdf.js — с сайта, fix:pdfcsp).
  const directives = Object.fromEntries(csp.split(';').map((d) => d.trim().split(/\s+/)).filter((d) => d[0]).map(([k, ...v]) => [k, v]));
  const foreignSrc = Object.entries(directives).flatMap(([k, v]) => v.filter((s) => !/^'(self|none|unsafe-eval|wasm-unsafe-eval|unsafe-inline|sha256-[A-Za-z0-9+/=]+)'$|^(blob|data):$/.test(s)).map((s) => `${k} ${s}`));
  const inlineOk = Object.entries(directives).filter(([, v]) => v.includes("'unsafe-inline'")).map(([k]) => k);
  add("_headers: Content-Security-Policy — default-src 'self', ни одного чужого хоста (pdf.js с сайта), 'unsafe-inline' только в style-src", /default-src 'self'/.test(csp) && foreignSrc.length === 0 && inlineOk.join() === 'style-src', foreignSrc.length ? foreignSrc : csp.slice(0, 240));
  // Встроенный скрипт печати пакета printing: текст в main.dart.js = PRINTING_PRINT_SCRIPT, его sha256 — в script-src.
  const printTexts = [...read('main.dart.js').matchAll(/\.innerHTML="(function __net_nfet_printing___print\(\)\{[^"]*\})"/g)].map((x) => x[1]);
  const printHash = `sha256-${createHash('sha256').update(PRINTING_PRINT_SCRIPT, 'utf8').digest('base64')}`;
  add('CSP: хэш встроенного скрипта печати пакета printing = тексту в main.dart.js (Printing.layoutPdf без запасной вкладки)', printTexts.length === 1 && printTexts[0] === PRINTING_PRINT_SCRIPT && printHash === PRINTING_PRINT_SCRIPT_HASH && (directives['script-src'] ?? []).includes(`'${PRINTING_PRINT_SCRIPT_HASH}'`), { found: printTexts.length, same: printTexts[0] === PRINTING_PRINT_SCRIPT, hash: printHash, hint: printTexts[0] && printTexts[0] !== PRINTING_PRINT_SCRIPT ? 'пакет printing обновлён: обновите PRINTING_PRINT_SCRIPT и хэш в tools/site-headers.mjs' : undefined });
  const t = (p) => headersFor(rules, p)['Content-Type'];
  const wasm = files.filter((f) => f.endsWith('.wasm'));
  const gz = files.filter((f) => f.endsWith('.gz'));
  const mjs = files.filter((f) => f.endsWith('.mjs'));
  const licenses = files.filter((f) => /(^|\/)LICENSE$/.test(f));
  const badTypes = [...wasm.filter((f) => t(`/${f}`) !== 'application/wasm'), ...gz.filter((f) => t(`/${f}`) !== 'application/gzip'), ...mjs.filter((f) => !/^text\/javascript/.test(t(`/${f}`) ?? '')), ...licenses.filter((f) => !/^text\/plain/.test(t(`/${f}`) ?? '')), ...(t('/backend/pglite/pglite.data') === 'application/octet-stream' ? [] : ['backend/pglite/pglite.data'])];
  add('_headers: типы .wasm (application/wasm), .gz (application/gzip), .mjs (text/javascript), LICENSE (text/plain), pglite.data (octet-stream) — явными путями', badTypes.length === 0, badTypes.length ? badTypes : `${wasm.length} wasm, ${gz.length} gz, ${mjs.length} mjs, ${licenses.length} LICENSE`);
  const red = parseRedirects(read('_redirects'));
  const api = red.find((r) => matchPath(r.from, '/api/v1/orders'));
  const img = red.find((r) => matchPath(r.from, '/images/abc/card'));
  const problemJson = ['/api/v1/orders', '/api-unavailable.json'].every((p) => /^application\/problem\+json/.test(t(p) ?? ''));
  add('_redirects: /api/* → 404 problem+json (force; тип в _headers и для /api/*, и для цели), /images/:sha/:size → .webp; без SPA-правила /*', api?.status === 404 && api.force && api.to === '/api-unavailable.json' && problemJson && img?.status === 200 && /\.webp$/.test(img.to) && !red.some((r) => r.from === '/*'), red);
}
const robots = has('robots.txt') ? read('robots.txt') : '';
add('robots.txt не запрещает обход (поисковик должен увидеть noindex)', !/^\s*Disallow:\s*\/\s*$/im.test(robots), robots.split(/\r?\n/).filter((l) => l && !l.startsWith('#')).join(' | '));
add('index.html и demo-closed.html: meta robots noindex', /<meta name="robots" content="noindex, nofollow, noarchive">/.test(read('index.html')) && /noindex/.test(read('demo-closed.html')));

// ---------------------------------------------------------------- 8. лицензии
if (has('THIRD_PARTY_NOTICES.txt') && has('assets/NOTICES')) {
  const n = read('THIRD_PARTY_NOTICES.txt');
  const sections = [1, 2, 3, 4, 5, 6, 7].filter((i) => new RegExp(`^${i}\\. `, 'm').test(n));
  const m = /Компоненты \((\d+), по assets\/NOTICES сборки, (\d+) байт\)/.exec(n);
  const noticesBytes = statSync(`${SITE}/assets/NOTICES`).size;
  add('THIRD_PARTY_NOTICES.txt: разделы 1–7; перечень Flutter — по assets/NOTICES ЭТОГО сайта (размер совпадает)', sections.length === 7 && m && Number(m[1]) >= 50 && Number(m[2]) === noticesBytes, { sections, components: m?.[1], bytesInNotices: m?.[2], siteNotices: noticesBytes, hint: m && Number(m[2]) !== noticesBytes ? 'сборка Flutter новее уведомлений: пересоберите бэкенд (build-backend.mjs --skip-tsc --skip-snapshot)' : undefined });
  const lic = has('pdfjs/LICENSE') ? read('pdfjs/LICENSE').replace(/\r\n/g, '\n').trim() : '';
  const sec7 = n.slice(n.search(/^7\. pdfjs\/ — pdf\.js /m));
  add(`pdf.js в уведомлениях: раздел 7 (${PDFJS.package} ${PDFJS.version}, Apache-2.0) с полным текстом LICENSE пакета, одна строка оглавления`, /^7\. pdfjs\/ — pdf\.js /m.test(n) && sec7.includes(`${PDFJS.package} ${PDFJS.version}`) && lic.length > 1000 && sec7.includes(lic) && (n.match(/^ {2}7\. pdfjs\//gm) ?? []).length === 1 && (n.match(/^7\. pdfjs\//gm) ?? []).length === 1);
  add('Roboto в уведомлениях — файл, который публикуется (fonts/roboto/v32/…woff2), с лицензией Apache-2.0', /fonts\/roboto\/v32\/KFOmCnqEu92Fr1Me4GZLCzYlKw\.woff2/.test(n) && /Apache License/.test(n));
  add('ссылки «Лицензии»: панель (Сервис) и demo-closed.html', /THIRD_PARTY_NOTICES\.txt/.test(read('demo-panel.js')) && /THIRD_PARTY_NOTICES\.txt/.test(read('demo-closed.html')));
}

// ---------------------------------------------------------------- 10. pdf.js (fix:pdfcsp)
{
  const bad = PDFJS.files.filter((f) => !has(f.to) || statSync(`${SITE}/${f.to}`).size !== f.bytes || sha256(readFileSync(`${SITE}/${f.to}`)) !== f.sha256).map((f) => f.to);
  const loaderSrc = `${WEB}/${PDFJS.loader.from}`;
  const loaderOk = has(PDFJS.loader.to) && existsSync(loaderSrc) && sha256(readFileSync(`${SITE}/${PDFJS.loader.to}`)) === sha256(readFileSync(loaderSrc));
  add(`pdfjs/: ${PDFJS.package} ${PDFJS.version} без изменений (sha256 = tools/pdfjs-files.mjs), загрузчик pdf.min.js = ${PDFJS.loader.from}`, bad.length === 0 && loaderOk, bad.length ? bad : { files: PDFJS_SITE_FILES, loaderOk });
  const boot = has('demo-boot.js') ? read('demo-boot.js') : '';
  const main = read('main.dart.js');
  const baseSet = new RegExp(`dartPdfJsBaseUrl = '${PDFJS.baseUrl.replace(/[/.]/g, '\\$&')}'`).test(boot);
  const honoured = /"dartPdfJsBaseUrl" in [\w$.]+\)[\w$.]+=[\w$.]+\.dartPdfJsBaseUrl/.test(main);
  add(`pdf.js с сайта: demo-boot.js задаёт dartPdfJsBaseUrl = '${PDFJS.baseUrl}', пакет printing в main.dart.js его читает (не unpkg.com)`, baseSet && honoured, { baseSet, honoured, cdnDefault: /https:\/\/unpkg\.com\/pdfjs-dist@/.test(main) ? 'в main.dart.js — адрес по умолчанию пакета (не используется: задан dartPdfJsBaseUrl; CSP его не пропустит)' : null });
}

// ---------------------------------------------------------------- 9. размеры
const sized = files.map((f) => ({ f, b: statSync(`${SITE}/${f}`).size })).sort((a, b) => b.b - a.b);
const total = sized.reduce((s, x) => s + x.b, 0);
const big = sized.filter((x) => x.b > 10 * 1024 * 1024).map((x) => `${x.f} ${(x.b / 1048576).toFixed(1)} МБ`);
if (big.length) warnings.push(`файлы больше 10 МБ (лимит Netlify Drop): ${big.join(', ')}`);
add('размер сайта 30–60 МБ', total >= 30e6 && total <= 60e6, `${(total / 1e6).toFixed(1)} МБ, ${files.length} файлов; крупнейшие: ${sized.slice(0, 6).map((x) => `${x.f} ${(x.b / 1e6).toFixed(1)}`).join(', ')}`);

const failed = checks.filter((c) => !c.ok);
const report = { at: new Date().toISOString(), site: SITE, files: files.length, bytes: total, checks, warnings, failed: failed.length, localhostByFile: local, fileUriByFile: fileUri };
try {
  const { mkdirSync, writeFileSync } = await import('node:fs');
  mkdirSync(dirname(REPORT), { recursive: true });
  writeFileSync(REPORT, `${JSON.stringify(report, null, 1)}\n`);
} catch {
  /* отчёт необязателен */
}
for (const w of warnings) console.log(`WARN ${w}`);
console.log(`\ncheck-site: ${checks.length - failed.length}/${checks.length}${failed.length ? ` — ОШИБКИ: ${failed.map((c) => c.name).join('; ')}` : ' — можно выкладывать'}; отчёт ${REPORT}`);
process.exit(failed.length ? 1 : 0);

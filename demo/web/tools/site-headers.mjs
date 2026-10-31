// Заголовки и перенаправления сайта веб-демо — ОДИН источник (review fixes, critic [21]; plan WP-N1, §3.7):
//   - site/_headers и site/_redirects для Netlify (их читают и Netlify Drop, и `netlify deploy --dir site`);
//   - tools/serve-site.mjs применяет те же правила локально (127.0.0.1:8095–8099), tools/smoke.mjs проверяет их.
// netlify.toml (demo/web) задаёт только каталог публикации: правила здесь, чтобы не было двух копий.
//
// Что и зачем:
//   - X-Robots-Tag noindex, nofollow, noarchive на всё (robots.txt обход разрешает — иначе поисковик не увидит noindex);
//   - Content-Security-Policy: страница, Flutter и воркеры ходят только на свой origin, чужих хостов нет совсем: pdf.js
//     предпросмотра PDF сайт отдаёт сам (pdfjs/, tools/pdfjs-files.mjs; до fix:pdfcsp — с unpkg.com, plan §10 п. 8);
//     'wasm-unsafe-eval' — CanvasKit и PGlite; 'unsafe-eval' — пакет printing (проверка «pdf.js загружен» через
//     window.eval); хэш PRINTING_PRINT_SCRIPT_HASH — встроенный скрипт печати пакета printing (Printing.layoutPdf;
//     без него печать уходит в запасной путь «PDF в новой вкладке»); worker-src blob: — проверка module Worker в
//     demo-env.js и асинхронный fflate в backend.js; frame-src blob: — скрытый iframe печати с PDF; без COOP/COEP
//     (ломают pdf.js и шрифты, plan WP-N1);
//   - .mjs (pdf.js) — явный тип text/javascript: модульный скрипт и воркер с другим типом не запустятся (nosniff);
//   - типы: .wasm — application/wasm, pglite.data — octet-stream, *.tar.gz и снимок data.copy.gz — application/gzip
//     (воркер сам распаковывает и не ждёт Content-Encoding; если хостинг всё же сожмёт — demo-init проверит сигнатуру);
//   - /api/* → 404 problem+json (запросов туда нет — страховка), /images/:sha/:size → :size.webp (пути pos-api без
//     расширения), без SPA-правила /* → index.html (маршрутизация хэшевая; такое правило отдавало бы index.html
//     вместо отсутствующих шрифтов и фото);
//   - кэш: имена файлов без хэша — только ревалидация; фото (sha-адреса) и шрифт Inter — надолго; demo/build.json —
//     no-store (по нему страница узнаёт новую выкладку).

/**
 * Встроенный скрипт печати пакета printing 5.14.3 (lib/printing_web.dart, layoutPdf): ровно этот текст пакет кладёт
 * в <script> перед печатью; CSP разрешает только его (sha256). Другая версия пакета — другой текст: check-site.mjs
 * сверяет текст и хэш с main.dart.js сайта.
 */
export const PRINTING_PRINT_SCRIPT = "function __net_nfet_printing___print(){var f=document.getElementById('__net_nfet_printing__');f.focus();f.contentWindow.print();}";
export const PRINTING_PRINT_SCRIPT_HASH = 'sha256-+M0fGRkOqgYlCQCff9oNQn6k6a7Si4Et8iofLMceadE=';

export const CSP = [
  "default-src 'self'",
  `script-src 'self' 'wasm-unsafe-eval' 'unsafe-eval' '${PRINTING_PRINT_SCRIPT_HASH}'`,
  "worker-src 'self' blob:",
  "connect-src 'self' blob: data:",
  "img-src 'self' data: blob:",
  "font-src 'self' data:",
  "style-src 'self' 'unsafe-inline'",
  "frame-src 'self' blob:",
  "manifest-src 'self'",
  "media-src 'self' blob: data:",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join('; ');

export const GLOBAL_HEADERS = {
  'X-Robots-Tag': 'noindex, nofollow, noarchive',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()',
  'Content-Security-Policy': CSP,
};
// Cache-Control в «/*» не ставится: несколько совпавших правил Netlify объединяет, и значения сложились бы. Умолчание
// Netlify — «public, max-age=0, must-revalidate» (ETag), его же отдаёт serve-site.mjs; явные правила — ниже.
export const DEFAULT_CACHE_CONTROL = 'public, max-age=0, must-revalidate';

/** Типы по расширению (serve-site.mjs и явные правила _headers для файлов, где тип важен). */
export const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff2': 'font/woff2',
  '.wasm': 'application/wasm',
  '.data': 'application/octet-stream',
  '.gz': 'application/gzip',
  '.frag': 'application/octet-stream',
  '.bin': 'application/octet-stream',
};
export const typeOf = (path) => {
  if (/\/(NOTICES|LICENSE)$/.test(path)) return 'text/plain; charset=utf-8';
  // Ответ на /api/* (404, RFC 9457): по расширению .json Netlify отдал бы application/json (ревью сайта SITE-05).
  if (/\/api-unavailable\.json$/.test(path)) return 'application/problem+json; charset=utf-8';
  if (/manifest\.json$/.test(path) && !/\/snapshot\//.test(path)) return 'application/manifest+json; charset=utf-8';
  const m = /(\.[a-z0-9]+)$/i.exec(path);
  return (m && TYPES[m[1].toLowerCase()]) || 'application/octet-stream';
};

/**
 * Правила _headers: [{ path, headers }] по порядку. Типы файлов, для которых он важен (.wasm, .data, .gz, .mjs,
 * NOTICES, LICENSE, manifest), — явными путями (files — список опубликованных путей сайта): шаблоны вида /*.wasm
 * Netlify не гарантирует.
 */
export function headerRules(files = []) {
  const rules = [{ path: '/*', headers: { ...GLOBAL_HEADERS } }];
  const typed = files.filter((f) => /\.(wasm|data|gz|mjs)$/i.test(f) || /(^|\/)(NOTICES|LICENSE)$/.test(f) || f === 'manifest.json' || f === 'THIRD_PARTY_NOTICES.txt' || f === 'api-unavailable.json').sort();
  for (const f of typed) rules.push({ path: `/${f}`, headers: { 'Content-Type': typeOf(`/${f}`) } });
  // Netlify сопоставляет заголовки с запрошенным путём: правило и для /api/*, и для цели перезаписи.
  rules.push({ path: '/api/*', headers: { 'Content-Type': typeOf('/api-unavailable.json') } });
  rules.push({ path: '/demo/build.json', headers: { 'Cache-Control': 'no-store' } });
  rules.push({ path: '/images/*', headers: { 'Cache-Control': 'public, max-age=31536000, immutable' } });
  rules.push({ path: '/assets/assets/fonts/Inter/*', headers: { 'Cache-Control': 'public, max-age=2592000' } });
  rules.push({ path: '/fonts/*', headers: { 'Cache-Control': 'public, max-age=2592000' } });
  return rules;
}

/** Правила _redirects (первое совпадение). force — «!» Netlify: применять, даже если файл существует. */
export const REDIRECTS = [
  { from: '/api/*', to: '/api-unavailable.json', status: 404, force: true },
  { from: '/images/:sha/:size', to: '/images/:sha/:size.webp', status: 200, force: false },
];

export function renderHeaders(rules) {
  const out = ['# СГЕНЕРИРОВАНО demo/web/tools/assemble-site.mjs из tools/site-headers.mjs — не править вручную.'];
  for (const r of rules) {
    out.push(r.path);
    for (const [k, v] of Object.entries(r.headers)) out.push(`  ${k}: ${v}`);
  }
  return `${out.join('\n')}\n`;
}

export function renderRedirects(list = REDIRECTS) {
  const out = ['# СГЕНЕРИРОВАНО demo/web/tools/assemble-site.mjs из tools/site-headers.mjs — не править вручную.'];
  for (const r of list) out.push(`${r.from.padEnd(22)} ${r.to.padEnd(28)} ${r.status}${r.force ? '!' : ''}`);
  return `${out.join('\n')}\n`;
}

/** Разбор site/_headers (формат renderHeaders / Netlify): [{ path, headers }]. */
export function parseHeaders(text) {
  const rules = [];
  let cur = null;
  for (const line of String(text).split(/\r?\n/)) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    if (!/^\s/.test(line)) {
      cur = { path: line.trim(), headers: {} };
      rules.push(cur);
      continue;
    }
    const m = /^\s+([^:]+):\s*(.*)$/.exec(line);
    if (m && cur) cur.headers[m[1].trim()] = m[2].trim();
  }
  return rules;
}

/** Разбор site/_redirects: [{ from, to, status, force }]. */
export function parseRedirects(text) {
  const out = [];
  for (const line of String(text).split(/\r?\n/)) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const [from, to, st] = line.trim().split(/\s+/);
    out.push({ from, to, status: Number(String(st).replace('!', '')), force: /!$/.test(st) });
  }
  return out;
}

/** Совпадение пути с шаблоном Netlify (* — остаток пути, :name — сегмент). → параметры или null. */
export function matchPath(pattern, path) {
  const ps = pattern.split('/');
  const xs = path.split('/');
  const params = {};
  for (let i = 0; i < ps.length; i++) {
    const p = ps[i];
    if (p === '*') {
      params.splat = xs.slice(i).join('/');
      return params;
    }
    if (i >= xs.length) return null;
    if (p.startsWith(':')) {
      if (!xs[i]) return null;
      params[p.slice(1)] = xs[i];
      continue;
    }
    if (p !== xs[i]) return null;
  }
  return xs.length === ps.length ? params : null;
}

/** Заголовки ответа для пути: все совпавшие правила по порядку (позднее перекрывает раньше, как у Netlify). */
export function headersFor(rules, path) {
  const h = {};
  for (const r of rules) if (matchPath(r.path, path)) Object.assign(h, r.headers);
  return h;
}

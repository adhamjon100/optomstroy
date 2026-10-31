// Локальный статический сервер собранного сайта веб-демо С ТЕМИ ЖЕ заголовками и перенаправлениями, что на Netlify
// (site/_headers, site/_redirects из tools/site-headers.mjs) — для smoke в headless Chrome (WP-T2) и ручной проверки.
//
//   node demo/web/tools/serve-site.mjs [--port 8095] [--site <каталог>] [--quiet]
//
// Только 127.0.0.1; порты 8095–8099 (3000, 8080, 8091, 8092 занимает другой workflow). Без сжатия на лету (Netlify
// сжимает сам — проверяется на превью), с ETag/If-None-Match как у Netlify. Ведёт журнал запросов: GET /__site/log.
import http from 'node:http';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEFAULT_CACHE_CONTROL, headersFor, matchPath, parseHeaders, parseRedirects, typeOf } from './site-headers.mjs';

const HERE = dirname(fileURLToPath(import.meta.url)).replace(/\\/g, '/');
const argv = process.argv.slice(2);
const arg = (k, d) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : d);
const SITE = resolve(arg('--site', `${HERE}/../site`)).replace(/\\/g, '/');
const PORT = Number(arg('--port', 8095));
const QUIET = argv.includes('--quiet');
if (!(PORT >= 8095 && PORT <= 8099)) throw new Error(`порт ${PORT}: для статики — только 8095–8099`);
if (!existsSync(`${SITE}/_headers`)) throw new Error(`нет ${SITE}/_headers — сначала tools/assemble-site.mjs`);

const rules = parseHeaders(readFileSync(`${SITE}/_headers`, 'utf8'));
const redirects = parseRedirects(readFileSync(`${SITE}/_redirects`, 'utf8'));
const journal = [];
const etags = new Map();

function fileOf(p) {
  const f = `${SITE}${p}`;
  if (!resolve(f).replace(/\\/g, '/').startsWith(SITE)) return null;
  try {
    const st = statSync(f);
    return st.isFile() ? { f, st } : st.isDirectory() && existsSync(`${f}/index.html`) ? { f: `${f}/index.html`, st: statSync(`${f}/index.html`) } : null;
  } catch {
    return null;
  }
}
function etagOf(f, st) {
  const k = `${f}:${st.mtimeMs}:${st.size}`;
  if (!etags.has(k)) etags.set(k, `"${createHash('sha1').update(readFileSync(f)).digest('hex').slice(0, 20)}"`);
  return etags.get(k);
}
function substitute(to, params) {
  return to.replace(/:([a-z]+)/gi, (_, k) => params[k] ?? `:${k}`).replace('*', params.splat ?? '');
}

const server = http.createServer((req, res) => {
  let path;
  try {
    path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  } catch {
    res.writeHead(400).end();
    return;
  }
  if (path === '/__site/log') {
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end(JSON.stringify(journal.slice(-5000)));
    return;
  }
  let status = 200;
  let target = path === '/' ? '/index.html' : path;
  // перенаправления: первое совпадение; без force — только если файла нет (как Netlify «shadowing»)
  for (const r of redirects) {
    const m = matchPath(r.from, path);
    if (!m) continue;
    if (!r.force && fileOf(target)) break;
    target = substitute(r.to, m);
    status = r.status;
    break;
  }
  const hit = fileOf(target);
  const entry = { t: Date.now(), m: req.method, p: path, s: 0 };
  journal.push(entry);
  if (journal.length > 20000) journal.splice(0, 10000);
  if (!hit) {
    entry.s = 404;
    const nf = fileOf('/404.html');
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8', ...headersFor(rules, path) });
    res.end(nf ? readFileSync(nf.f) : 'Not Found');
    if (!QUIET) console.log(`404 ${path}`);
    return;
  }
  const h = { 'content-type': typeOf(target), 'cache-control': DEFAULT_CACHE_CONTROL, ...Object.fromEntries(Object.entries(headersFor(rules, target)).map(([k, v]) => [k.toLowerCase(), v])) };
  // правила «/*» (noindex, CSP) — и для ответа по перенаправлению
  Object.assign(h, Object.fromEntries(Object.entries(headersFor(rules, path)).filter(([k]) => !/^content-type$/i.test(k)).map(([k, v]) => [k.toLowerCase(), v])));
  const tag = etagOf(hit.f, hit.st);
  h.etag = tag;
  if (status === 200 && req.headers['if-none-match'] === tag) {
    entry.s = 304;
    res.writeHead(304, h).end();
    return;
  }
  entry.s = status;
  h['content-length'] = String(hit.st.size);
  res.writeHead(status, h);
  if (req.method === 'HEAD') res.end();
  else res.end(readFileSync(hit.f));
});
server.listen(PORT, '127.0.0.1', () => {
  console.log(`serve-site: http://127.0.0.1:${PORT}/ (${SITE}); правил заголовков ${rules.length}, перенаправлений ${redirects.length}; pid ${process.pid}`);
});

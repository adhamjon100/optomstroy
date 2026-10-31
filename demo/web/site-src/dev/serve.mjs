// Оптомстрой POS · веб-демо · dev-сервер страницы WP-S1 без Flutter и без настоящего сервера демо.
//
//   node demo/web/site-src/dev/serve.mjs [--port 8096] [--backend-dir <каталог site/backend>]
//
// Отдаёт demo/web/site-src как корень сайта и подменяет то, чего ещё нет:
//   /backend/backend.js  → dev/mock-backend.js (или настоящий backend.js из --backend-dir вместе с pglite/);
//   /flutter_bootstrap.js → настоящий pos-app/web/flutter_bootstrap.js, где {{flutter_js}} — dev/fake-flutter-loader.js
//                           (имитация движка: окно приложения, слушатели клавиш и сети как у Flutter);
//   /demo/build.json      → значения в памяти (меняются через /__dev/set-build);
//   /icons/*, /favicon.png, /manifest.json → pos-app/web; /assets/assets/fonts/Inter/* → pos-app/assets/fonts/Inter;
//   /api/*                → 404 api-unavailable.json (как правило Netlify), счётчик обращений;
//   с --site-dir <demo/web/site> (WP-B4): /demo/snapshot/* и /images/{sha}/{size} → {size}.webp (как правило Netlify).
// Управление: /__dev/state, /__dev/set-build?epochKey=&buildId=, /__dev/set-mock?fatal=1&initDelayMs=…&fenceCheck=0,
// /__dev/mock-config. Только 127.0.0.1; порты 8095–8099 (3000, 8080, 8091, 8092 заняты другим workflow).
import http from 'node:http';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PUBLISHED } from '../build-site.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = resolve(HERE, '..');
const REPO = resolve(SRC, '..', '..', '..');
const arg = (name, def) => {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
};
const PORT = Number(arg('port', 8096));
if (!(PORT >= 8095 && PORT <= 8099)) throw new Error(`порт ${PORT}: для статики WP-S1 — только 8095–8099`);
const BACKEND_DIR = arg('backend-dir', null);
const SITE_DIR = arg('site-dir', null);

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.png': 'image/png',
  '.ttf': 'font/ttf',
  '.woff2': 'font/woff2',
  '.wasm': 'application/wasm',
  '.data': 'application/octet-stream',
  '.gz': 'application/gzip',
  '.webp': 'image/webp',
};

const state = {
  build: { buildId: 'dev-1', epochKey: 'dev-epoch-1', gitHead: 'devhead0000', posApiDiffSha256: 'dev', builtAt: new Date().toISOString() },
  mock: { fatal: false, initDelayMs: 1200, flutterDelayMs: 600, fenceCheck: true },
  counters: { requests: 0, apiHits: 0, notFound: [] },
};

function flutterBootstrap() {
  const tpl = readFileSync(join(REPO, 'pos-app', 'web', 'flutter_bootstrap.js'), 'utf8');
  const loader = readFileSync(join(HERE, 'fake-flutter-loader.js'), 'utf8');
  return tpl.split('{{flutter_js}}').join(loader).split('{{flutter_build_config}}').join("_flutter.buildConfig = {engineRevision: 'dev-stub', builds: []};");
}

function send(res, status, body, type, extra) {
  res.writeHead(status, {
    'content-type': type,
    'cache-control': 'no-store',
    'x-robots-tag': 'noindex, nofollow',
    'x-content-type-options': 'nosniff',
    ...(extra || {}),
  });
  res.end(body);
}
const json = (res, obj, status = 200) => send(res, status, JSON.stringify(obj), 'application/json; charset=utf-8');

function sendFile(res, file) {
  let st;
  try {
    st = statSync(file);
  } catch {
    return false;
  }
  if (!st.isFile()) return false;
  send(res, 200, readFileSync(file), TYPES[extname(file).toLowerCase()] || 'application/octet-stream');
  return true;
}

function under(base, rel) {
  const f = normalize(join(base, rel));
  return f.startsWith(normalize(base)) ? f : null;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = decodeURIComponent(url.pathname);
  state.counters.requests++;
  if (p === '/__dev/state') return json(res, state);
  if (p === '/__dev/mock-config') return json(res, state.mock);
  if (p === '/__dev/set-build') {
    for (const k of ['buildId', 'epochKey']) if (url.searchParams.has(k)) state.build[k] = url.searchParams.get(k);
    if (url.searchParams.has('fail')) state.buildFail = url.searchParams.get('fail') === '1';
    if (url.searchParams.has('missing')) state.buildMissing = url.searchParams.get('missing') === '1';
    return json(res, state.build);
  }
  if (p === '/__dev/set-mock') {
    for (const [k, v] of url.searchParams) {
      state.mock[k] = v === '1' || v === 'true' ? true : v === '0' || v === 'false' ? false : /^\d+$/.test(v) ? Number(v) : v;
    }
    return json(res, state.mock);
  }
  if (p === '/__dev/reset-counters') {
    state.counters = { requests: 0, apiHits: 0, notFound: [] };
    return json(res, state.counters);
  }
  if (p.startsWith('/api/')) {
    state.counters.apiHits++;
    return send(res, 404, readFileSync(join(SRC, 'api-unavailable.json')), 'application/problem+json; charset=utf-8');
  }
  if (p === '/demo/build.json') {
    if (state.buildMissing) return send(res, 404, 'not found', 'text/plain; charset=utf-8'); // review fixes: сайт без demo/build.json
    return state.buildFail ? send(res, 503, 'unavailable', 'text/plain; charset=utf-8') : json(res, state.build);
  }
  if (p === '/flutter_bootstrap.js') return send(res, 200, flutterBootstrap(), TYPES['.js']);
  if (p === '/backend/backend.js' && !BACKEND_DIR) {
    if (sendFile(res, join(HERE, 'mock-backend.js'))) return;
  }
  if (SITE_DIR && p.startsWith('/demo/snapshot/')) {
    const f = under(resolve(SITE_DIR), p.slice(1));
    if (f && sendFile(res, f)) return;
  }
  if (SITE_DIR && /^\/images\/[0-9a-f]{64}\/(thumb|card|full)(\.webp)?$/.test(p)) {
    const f = under(resolve(SITE_DIR), p.endsWith('.webp') ? p.slice(1) : `${p.slice(1)}.webp`);
    if (f && sendFile(res, f)) return;
  }
  if (p.startsWith('/backend/') && BACKEND_DIR) {
    const f = under(resolve(BACKEND_DIR), p.slice('/backend/'.length));
    if (f && sendFile(res, f)) return;
  }
  if (p === '/favicon.png' || p === '/manifest.json' || p.startsWith('/icons/')) {
    const f = under(join(REPO, 'pos-app', 'web'), p.slice(1));
    if (f && sendFile(res, f)) return;
  }
  if (p.startsWith('/assets/assets/fonts/Inter/')) {
    const f = under(join(REPO, 'pos-app', 'assets', 'fonts', 'Inter'), p.slice('/assets/assets/fonts/Inter/'.length));
    if (f && sendFile(res, f)) return;
  }
  if (p.startsWith('/dev/')) {
    const f = under(HERE, p.slice('/dev/'.length));
    if (f && /\.(html|js)$/.test(f) && sendFile(res, f)) return;
  }
  const rel = p === '/' ? 'index.html' : p.slice(1);
  if (PUBLISHED.includes(rel) && sendFile(res, join(SRC, rel))) return;
  state.counters.notFound.push(p);
  if (state.counters.notFound.length > 200) state.counters.notFound.splice(0, 100);
  send(res, 404, 'not found', 'text/plain; charset=utf-8');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`WP-S1 dev: http://127.0.0.1:${PORT}/ (backend: ${BACKEND_DIR || 'mock'}; repo ${existsSync(REPO) ? 'ok' : '?'})`);
});

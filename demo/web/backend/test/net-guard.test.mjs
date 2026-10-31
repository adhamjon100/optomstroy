// WP-B1, критик [12]: из браузерного бэкенда нет исходящей сети. fetch, XMLHttpRequest, WebSocket, EventSource и
// importScripts пропускают только свой origin (и data:/blob:), клиент node:http/https и net/tls/dns всегда бросают
// ERR_DEMO_NO_NETWORK; собранный backend.js ставит запрет при загрузке. Настоящих сетевых запросов тест не делает:
// «родные» fetch/WebSocket/XMLHttpRequest подменены шпионами до загрузки бандла.
//   node --test "demo/web/backend/test/*.test.mjs"
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { before, describe, test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { OUT } from '../lib/paths.mjs';
import { bundleForTest } from './support/bundle-for-test.mjs';

const ORIGIN = 'https://optomstroy-demo-4fhvb.netlify.app';
const calls = { fetch: [], ws: [], xhr: [], importScripts: [] };
let mod;

before(async () => {
  // Среда module Web Worker: location — адрес backend.js на сайте; «родные» сетевые API — шпионы.
  globalThis.location = new URL(`${ORIGIN}/backend/backend.js`);
  globalThis.fetch = async (input) => {
    calls.fetch.push(String(input?.url ?? input));
    return new Response('ok');
  };
  globalThis.WebSocket = class {
    constructor(url) {
      calls.ws.push(String(url));
    }
  };
  globalThis.EventSource = class {
    constructor(url) {
      calls.ws.push(`es:${url}`);
    }
  };
  globalThis.XMLHttpRequest = class {
    open(method, url) {
      calls.xhr.push(`${method} ${url}`);
    }
  };
  globalThis.importScripts = (...u) => calls.importScripts.push(...u);
  mod = await bundleForTest(
    'net-guard',
    `import { assertSameOrigin, isAllowedUrl, netGuard } from './shims/net-guard.mjs';
     import http from 'node:http';
     import https from 'node:https';
     import net from 'node:net';
     import tls from 'node:tls';
     import dns from 'node:dns';
     export { assertSameOrigin, isAllowedUrl, netGuard, http, https, net, tls, dns };`,
  );
});

const noNet = (e) => e && e.code === 'ERR_DEMO_NO_NETWORK';

describe('запрет сети в воркере', () => {
  test('fetch: свой origin и относительные адреса — да; SMSPro, фото по URL, 1С, другие хосты — нет', async () => {
    await fetch(`${ORIGIN}/backend/pglite/pglite.wasm`);
    await fetch('pglite/pglite.data');
    await fetch(new URL('vfs/pos-api/assets/fonts/Inter-Regular.ttf', `${ORIGIN}/backend/`));
    await fetch(new Request(`${ORIGIN}/backend/pglite/pgcrypto.tar.gz`));
    await fetch('data:text/plain,ok');
    for (const u of [
      'https://smspro.nikita.kg/api/otp',
      'https://images.example.com/p/1.jpg',
      'https://fake-1c.invalid/ut11/hs/pos/v1/health',
      'http://127.0.0.1:8091/pos/v1/health',
      `${ORIGIN.replace('https:', 'http:')}/backend/x`,
      'https://optomstroy-demo-4fhvb.netlify.app.evil.example/x',
      'https://unpkg.com/pdfjs-dist@3.2.146/build/pdf.min.js',
    ]) {
      await assert.rejects(fetch(u), noNet, u);
    }
    assert.deepEqual(calls.fetch, [
      `${ORIGIN}/backend/pglite/pglite.wasm`,
      'pglite/pglite.data',
      `${ORIGIN}/backend/vfs/pos-api/assets/fonts/Inter-Regular.ttf`,
      `${ORIGIN}/backend/pglite/pgcrypto.tar.gz`,
      'data:text/plain,ok',
    ]);
    assert.ok(mod.netGuard.blocked >= 7);
    assert.ok(mod.netGuard.blockedLog.every((x) => !x.url.includes('?')), 'в журнал не попадает query');
  });
  test('WebSocket, EventSource, XMLHttpRequest, importScripts', () => {
    assert.throws(() => new WebSocket('wss://example.com/socket'), noNet);
    new WebSocket(`wss://optomstroy-demo-4fhvb.netlify.app/ws`);
    assert.throws(() => new EventSource('https://example.com/events'), noNet);
    assert.throws(() => new XMLHttpRequest().open('GET', 'https://example.com/'), noNet);
    new XMLHttpRequest().open('GET', '/backend/build.json');
    assert.throws(() => importScripts('https://cdn.example.com/x.js'), noNet);
    importScripts(`${ORIGIN}/backend/x.js`);
    assert.deepEqual(calls.ws, ['wss://optomstroy-demo-4fhvb.netlify.app/ws']);
    assert.deepEqual(calls.xhr, ['GET /backend/build.json']);
    assert.deepEqual(calls.importScripts, [`${ORIGIN}/backend/x.js`]);
  });
  test('подменённые API нельзя вернуть присваиванием', () => {
    const before = globalThis.fetch;
    try {
      globalThis.fetch = async () => new Response('bypass');
    } catch {
      /* strict mode: TypeError — тоже правильно */
    }
    assert.equal(globalThis.fetch, before);
  });
  test('assertSameOrigin (для import() PGlite)', () => {
    assert.equal(mod.assertSameOrigin(`${ORIGIN}/backend/pglite/`), `${ORIGIN}/backend/pglite/`);
    assert.throws(() => mod.assertSameOrigin('https://cdn.jsdelivr.net/npm/@electric-sql/pglite/dist/'), noNet);
    assert.equal(mod.isAllowedUrl('file:///D:/x'), false, 'file: в браузере запрещён');
  });
  test('клиент node:http/https, net, tls, dns — всегда ошибка', () => {
    assert.throws(() => mod.https.request('https://smspro.nikita.kg/api', () => {}), noNet);
    assert.throws(() => mod.http.get('http://127.0.0.1:8091/'), noNet);
    assert.throws(() => mod.net.connect(5432, '127.0.0.1'), noNet);
    assert.throws(() => mod.tls.connect(443, 'example.com'), noNet);
    assert.throws(() => mod.dns.lookup('example.com', () => {}), noNet);
    assert.throws(() => mod.http.createServer(() => {}).listen(3000), noNet);
  });
});

describe('собранный backend.js', () => {
  test('при загрузке ставит запрет сети раньше кода pos-api (отдельный процесс Node)', () => {
    const script = `
      globalThis.location = new URL('${ORIGIN}/backend/backend.js');
      const seen = [];
      globalThis.fetch = async (u) => { seen.push(String(u)); return new Response('x'); };
      globalThis.self = globalThis;
      globalThis.addEventListener = () => {};
      globalThis.postMessage = () => {};
      await import(${JSON.stringify(pathToFileURL(`${OUT}/backend.js`).href)});
      const g = globalThis.__posNetGuard;
      let blocked = null;
      try { await fetch('https://smspro.nikita.kg/api/send'); } catch (e) { blocked = e.code; }
      await fetch('${ORIGIN}/backend/pglite/pglite.wasm');
      console.log(JSON.stringify({ installed: g && g.installed, origin: g && g.origin, blocked, seen }));
    `;
    const out = execFileSync(process.execPath, ['--input-type=module', '-e', script], { encoding: 'utf8', timeout: 60000 });
    const r = JSON.parse(out.trim().split('\n').pop());
    assert.equal(r.installed, true);
    assert.equal(r.origin, ORIGIN);
    assert.equal(r.blocked, 'ERR_DEMO_NO_NETWORK');
    assert.deepEqual(r.seen, [`${ORIGIN}/backend/pglite/pglite.wasm`]);
  });
  test('демо-конфиг переопределяет SMSPRO_BASE_URL несуществующим адресом', () => {
    assert.ok(readFileSync(`${OUT}/backend.js`, 'utf8').includes('https://smspro.invalid/api'));
  });
});

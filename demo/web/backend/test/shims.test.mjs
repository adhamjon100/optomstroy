// WP-T1: шимы Node браузерного бэкенда против настоящих модулей Node (plan §4 WP-T1 «shims.test.mjs»). Векторы crypto —
// в crypto-shim.test.mjs (WP-B1), запрет сети — в net-guard.test.mjs. Здесь:
//   http  — IncomingMessage/ServerResponse без сокета: заголовки (регистр, set-cookie, массивы), writeHead, chunked
//           (несколько write) → одно тело, HEAD, 204/304, события finish/close, отмена (close у ответа, aborted у
//           запроса), STATUS_CODES; express через шим = express через настоящий node:http (тот же ответ);
//   fs    — виртуальная fs: каждый файл = файл репозитория (после преобразований сборки), список каталога, stat,
//           ENOENT, внешние файлы (шрифты) — после provide;
//   timers — unref/ref/hasRef/refresh, clearTimeout, setImmediate раньше setTimeout(0), timers/promises с AbortSignal;
//   прочее — util.format/inspect/types, path.posix, url.fileURLToPath для /vfs, querystring, events, stream,
//           string_decoder (разрезанный многобайтовый символ), zlib — понятная ошибка ERR_DEMO_UNSUPPORTED.
//   node --test demo/web/backend/test/shims.test.mjs
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import nodeHttp from 'node:http';
import { createRequire } from 'node:module';
import nodePath from 'node:path';
import nodeQs from 'node:querystring';
import { StringDecoder as NodeDecoder } from 'node:string_decoder';
import nodeUtil from 'node:util';
import { after, before, describe, test } from 'node:test';
import { join, relative } from 'node:path';
import { NM, OUT, norm } from '../lib/paths.mjs';
import { VFS_SOURCES } from '../vfs/build-vfs.mjs';
import { transforms } from '../vfs/transforms.mjs';
import { bundleForTest } from './support/bundle-for-test.mjs';

const require = createRequire(import.meta.url);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let m;
// setImmediate шима — на MessageChannel (без зажима 4 мс в браузере); в Node открытый порт держит процесс теста.
after(() => setTimeout(() => process.exit(), 300).unref());
before(async () => {
  globalThis.__posDemoLog ??= () => {};
  m = await bundleForTest(
    'shims',
    `import http from 'node:http';
     import fs from 'node:fs';
     import timers from 'node:timers';
     import * as timersP from 'node:timers/promises';
     import util from 'node:util';
     import path from 'node:path';
     import url from 'node:url';
     import qs from 'node:querystring';
     import events from 'node:events';
     import stream from 'node:stream';
     import { StringDecoder } from 'node:string_decoder';
     import zlib from 'node:zlib';
     import { Buffer } from 'node:buffer';
     import express from 'express';
     export { http, fs, timers, timersP, util, path, url, qs, events, stream, StringDecoder, zlib, Buffer, express };`,
  );
});

/** Запрос через шим так же, как bridge-server.mjs: FakeSocket, IncomingMessage, ServerResponse, res._onEnd. */
function shimRequest(handler, { method = 'GET', url = '/', headers = {}, body = null } = {}) {
  const { http, Buffer } = m;
  return new Promise((resolve) => {
    const socket = new http.FakeSocket('127.0.0.1');
    const req = new http.IncomingMessage(socket);
    req.method = method;
    req.url = url;
    const h = { host: 'demo.local', ...headers };
    const b = body ? Buffer.from(body) : null;
    if (b) h['content-length'] = String(b.length);
    req.headers = h;
    const res = new http.ServerResponse(req);
    const events = [];
    res.on('finish', () => events.push('finish'));
    res.on('close', () => events.push('close'));
    res._onEnd = (buf) => resolve({ status: res.statusCode, headers: res.getHeaders(), body: Buffer.from(buf).toString('utf8'), events, res, req, socket });
    if (b) req.push(b);
    req.push(null);
    handler(req, res);
  });
}
/** Тот же обработчик через настоящий node:http (сервер на 127.0.0.1:0, без внешней сети). */
async function nativeRequest(handler, { method = 'GET', url = '/', headers = {}, body = null } = {}) {
  const server = nodeHttp.createServer(handler);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  try {
    // node:http.request, а не fetch: fetch этого процесса закрыт запретом сети бандла (net-guard.mjs из бандла теста)
    return await new Promise((resolve, reject) => {
      const rq = nodeHttp.request({ host: '127.0.0.1', port, path: url, method, headers }, (res) => {
        const parts = [];
        res.on('data', (c) => parts.push(c));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(parts).toString('utf8') }));
      });
      rq.on('error', reject);
      if (body) rq.write(body);
      rq.end();
    });
  } finally {
    await new Promise((r) => server.close(r));
  }
}

describe('http: IncomingMessage / ServerResponse без сокета', () => {
  test('STATUS_CODES и METHODS совпадают с node:http', () => {
    for (const [k, v] of Object.entries(nodeHttp.STATUS_CODES)) assert.equal(m.http.STATUS_CODES[k], v, `STATUS_CODES[${k}]`);
    for (const x of ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']) assert.ok(m.http.METHODS.includes(x));
  });
  test('заголовки: регистр, массивы, set-cookie, remove/has; writeHead с объектом и массивом', async () => {
    const r = await shimRequest((req, res) => {
      res.setHeader('X-One', '1');
      res.setHeader('Set-Cookie', ['a=1', 'b=2']);
      res.appendHeader?.('X-Multi', 'a');
      res.setHeader('X-Gone', 'x');
      assert.equal(res.hasHeader('x-one'), true);
      assert.equal(res.getHeader('X-ONE'), '1');
      res.removeHeader('x-gone');
      res.writeHead(201, 'Created', { 'Content-Type': 'text/plain; charset=utf-8', 'X-Two': ['p', 'q'] });
      res.end('ok');
    });
    assert.equal(r.status, 201);
    assert.equal(r.headers['x-one'], '1');
    assert.deepEqual(r.headers['set-cookie'], ['a=1', 'b=2']);
    assert.equal(r.headers['x-gone'], undefined);
    assert.deepEqual([].concat(r.headers['x-two']), ['p', 'q']);
    assert.match(String(r.headers['content-type']), /text\/plain/);
    assert.equal(r.body, 'ok');
    assert.equal(r.res.statusMessage, 'Created');
  });
  test('несколько write (chunked) → одно тело; Buffer и строки с кодировкой; finish раньше close', async () => {
    const r = await shimRequest((req, res) => {
      res.write('при');
      res.write(m.Buffer.from('вет, ', 'utf8'));
      res.write('6d6972', 'hex');
      res.end();
    });
    assert.equal(r.body, 'привет, mir');
    await sleep(5);
    assert.equal(r.events[0], 'finish');
  });
  test('тело запроса читается потоком (data/end), как у настоящего сервера', async () => {
    const r = await shimRequest(
      (req, res) => {
        const parts = [];
        req.on('data', (c) => parts.push(m.Buffer.from(c)));
        req.on('end', () => res.end(`got:${m.Buffer.concat(parts).toString('utf8')}`));
      },
      { method: 'POST', body: JSON.stringify({ a: 'б' }), headers: { 'content-type': 'application/json' } },
    );
    assert.equal(r.body, 'got:{"a":"б"}');
  });
  test('отмена начатого запроса: socket.destroy → close у ответа, aborted у запроса (long-poll слушает close)', async () => {
    const { http } = m;
    const socket = new http.FakeSocket('127.0.0.1');
    const req = new http.IncomingMessage(socket);
    req.method = 'GET';
    req.url = '/wait';
    req.headers = { host: 'demo.local' };
    const res = new http.ServerResponse(req);
    const seen = [];
    res.on('close', () => seen.push('res.close'));
    req.on('aborted', () => seen.push('req.aborted'));
    req.push(null);
    // как bridge-server.mjs при http:cancel
    req.aborted = true;
    req.emit('aborted');
    socket.destroy();
    req.destroy();
    res.destroy();
    await sleep(10);
    assert.ok(seen.includes('res.close'), `события: ${seen}`);
    assert.ok(seen.includes('req.aborted'));
  });
  test('express через шим = express через настоящий node:http (JSON, 201, 204, 304, 404, заголовки)', async () => {
    const realExpress = require(`${NM}/express`);
    const build = (express) => {
      const app = express();
      app.disable('x-powered-by');
      app.use(express.json());
      app.post('/echo', (req, res) => res.status(201).set('X-Req', req.get('x-req') ?? '').json({ got: req.body, q: req.query }));
      app.get('/empty', (req, res) => res.status(204).end());
      app.get('/etag', (req, res) => res.set('ETag', '"v1"').json({ a: 1 }));
      app.head('/etag', (req, res) => res.set('ETag', '"v1"').end());
      return app;
    };
    const shimApp = build(m.express);
    const nativeApp = build(realExpress);
    const cases = [
      { method: 'POST', url: '/echo?x=1&y=%D0%B0', headers: { 'content-type': 'application/json', 'x-req': 'r1' }, body: JSON.stringify({ n: 'Клиент', v: [1, 2] }) },
      { method: 'GET', url: '/empty' },
      { method: 'GET', url: '/etag' },
      { method: 'GET', url: '/etag', headers: { 'if-none-match': '"v1"' } },
      { method: 'GET', url: '/nope' },
    ];
    for (const c of cases) {
      const a = await shimRequest(shimApp, c);
      const b = await nativeRequest(nativeApp, c);
      assert.equal(a.status, b.status, `${c.method} ${c.url} статус`);
      assert.equal(a.body, b.body, `${c.method} ${c.url} тело`);
      for (const h of ['content-type', 'etag', 'x-req', 'content-length']) assert.equal(a.headers[h] === undefined ? undefined : String(a.headers[h]), b.headers[h], `${c.method} ${c.url} заголовок ${h}`);
    }
  });
});

describe('виртуальная fs = файлы репозитория', () => {
  const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]));
  test('каждый файл источников vfs читается и совпадает байт в байт (после преобразований сборки); каталоги и stat', () => {
    const fs = m.fs;
    const build = JSON.parse(readFileSync(`${OUT}/build.json`, 'utf8'));
    for (const [key, url] of Object.entries(build.backend?.vfsExternal ?? {})) fs.__vfs.provide(key, new Uint8Array(readFileSync(`${OUT}/${url}`)));
    let files = 0;
    let transformed = 0;
    for (const src of VFS_SOURCES) {
      const all = walk(src.from).map((f) => norm(relative(src.from, f))).filter((rel) => src.include.test(rel));
      for (const rel of all) {
        const key = `${src.to}/${rel}`;
        let want = readFileSync(join(src.from, rel));
        for (const t of transforms) {
          const r = t(key, want);
          if (r !== undefined && r !== want) {
            want = Buffer.from(r);
            transformed++;
          }
        }
        const got = Buffer.from(fs.readFileSync(key));
        assert.equal(createHash('sha256').update(got).digest('hex'), createHash('sha256').update(want).digest('hex'), key);
        assert.equal(fs.statSync(key).size, want.length, `stat ${key}`);
        assert.equal(fs.existsSync(key), true);
        files++;
      }
      const top = readdirSync(src.from, { withFileTypes: true }).filter((e) => e.isDirectory() || src.include.test(e.name)).map((e) => e.name).sort();
      assert.deepEqual([...fs.readdirSync(src.to)].sort(), top, `readdir ${src.to}`);
      assert.equal(fs.statSync(src.to).isDirectory(), true);
    }
    assert.ok(files > 50, `файлов vfs ${files}`);
    assert.ok(transformed >= 1, 'шаблоны PDF с водяным знаком');
  });
  test('нет файла → ENOENT, как у node:fs; fs.promises.readFile', async () => {
    assert.throws(() => m.fs.readFileSync('/vfs/pos-api/migrations/9999_nope.sql'), (e) => e.code === 'ENOENT');
    const migs = m.fs.readdirSync('/vfs/pos-api/migrations');
    const txt = await m.fs.promises.readFile(`/vfs/pos-api/migrations/${migs[0]}`, 'utf8');
    assert.equal(txt, readFileSync(`${VFS_SOURCES[0].from}/${migs[0]}`, 'utf8'));
  });
  test('запись — только в память (MEDIA_DIR /vfs/media), чтение обратно', () => {
    m.fs.mkdirSync('/vfs/media/t1', { recursive: true });
    m.fs.writeFileSync('/vfs/media/t1/a.txt', 'x1');
    assert.equal(m.fs.readFileSync('/vfs/media/t1/a.txt', 'utf8'), 'x1');
    assert.ok(m.fs.readdirSync('/vfs/media/t1').includes('a.txt'));
  });
});

describe('timers', () => {
  test('setTimeout → объект Timeout: unref/ref/hasRef/refresh; clearTimeout после unref', async () => {
    const { timers } = m;
    let fired = 0;
    const t = timers.setTimeout(() => fired++, 20);
    assert.equal(typeof t.unref, 'function');
    assert.equal(t.unref(), t);
    assert.equal(t.hasRef(), false);
    t.ref();
    assert.equal(t.hasRef(), true);
    t.refresh();
    const t2 = timers.setTimeout(() => fired++, 5).unref();
    timers.clearTimeout(t2);
    await sleep(60);
    assert.equal(fired, 1);
    const iv = timers.setInterval(() => fired++, 5);
    await sleep(30);
    timers.clearInterval(iv);
    const n = fired;
    await sleep(20);
    assert.equal(fired, n, 'clearInterval');
  });
  test('setImmediate раньше setTimeout(0); clearImmediate', async () => {
    const { timers } = m;
    const order = [];
    timers.setTimeout(() => order.push('timeout'), 0);
    timers.setImmediate(() => order.push('immediate'));
    const c = timers.setImmediate(() => order.push('cleared'));
    timers.clearImmediate(c);
    await sleep(30);
    assert.deepEqual(order, ['immediate', 'timeout']);
  });
  test('timers/promises: setTimeout со значением, отмена AbortSignal (AbortError)', async () => {
    assert.equal(await m.timersP.setTimeout(5, 'v'), 'v');
    const ac = new AbortController();
    const p = m.timersP.setTimeout(1000, 'x', { signal: ac.signal });
    ac.abort();
    await assert.rejects(p, (e) => e.name === 'AbortError' || e.code === 'ABORT_ERR');
  });
});

describe('util, path, url, querystring, events, stream, string_decoder, zlib', () => {
  test('util.format / inspect / types / promisify совпадают с Node на типичных значениях', async () => {
    for (const args of [['%s=%d %j', 'a', 42, { b: 1 }], ['%s', { a: [1, 'x'] }], ['plain', 1, 'two'], ['%i%%', 3.9], ['%s:%s', 'ОС00', 4601]]) assert.equal(m.util.format(...args), nodeUtil.format(...args), JSON.stringify(args));
    // Известное расхождение: %o шима не показывает скрытые свойства ([length] у массива). В pos-api %o/%O не
    // используется (grep по pos-api/src), журнал демо — JSON; отражено в отчёте WP-T1.
    assert.equal(m.util.format('%o', [1, 'x']).startsWith("[ 1, 'x'"), true);
    assert.equal(m.util.inspect({ a: 1, b: 'x', c: [1, 2] }), nodeUtil.inspect({ a: 1, b: 'x', c: [1, 2] }));
    assert.equal(m.util.types.isDate(new Date()), true);
    assert.equal(m.util.types.isUint8Array(new Uint8Array(1)), true);
    const p = m.util.promisify((x, cb) => cb(null, x * 2));
    assert.equal(await p(21), 42);
  });
  test('path (posix) = node:path.posix', () => {
    const P = nodePath.posix;
    for (const a of [['/vfs/pos-api/dist/db', '../../migrations'], ['/a/b', './c/../d'], ['/x', '/y']]) assert.equal(m.path.resolve(...a), P.resolve(...a));
    assert.equal(m.path.join('/vfs', 'pos-api', '..', 'contracts'), P.join('/vfs', 'pos-api', '..', 'contracts'));
    assert.equal(m.path.relative('/vfs/a/b', '/vfs/c'), P.relative('/vfs/a/b', '/vfs/c'));
    assert.deepEqual(m.path.parse('/vfs/a/file.tar.gz'), P.parse('/vfs/a/file.tar.gz'));
  });
  test('url: fileURLToPath/pathToFileURL для /vfs и URLSearchParams', () => {
    assert.equal(m.url.fileURLToPath('file:///vfs/pos-api/dist/x.js'), '/vfs/pos-api/dist/x.js');
    assert.equal(m.url.pathToFileURL('/vfs/a b.js').href, 'file:///vfs/a%20b.js');
    assert.equal(new m.url.URLSearchParams('a=1&b=%D0%B0').get('b'), 'а');
  });
  test('querystring = node:querystring', () => {
    for (const s of ['a=1&b=2&a=3', 'x=%D0%BA%D0%B8&y=', 'z']) assert.deepEqual({ ...m.qs.parse(s) }, { ...nodeQs.parse(s) }, s);
    assert.equal(m.qs.stringify({ a: [1, 2], b: 'кв' }), nodeQs.stringify({ a: [1, 2], b: 'кв' }));
  });
  test('events: once, off, listenerCount, error без слушателя бросает', async () => {
    const e = new m.events.EventEmitter();
    let n = 0;
    const f = () => n++;
    e.on('x', f);
    e.once('x', f);
    e.emit('x');
    e.emit('x');
    assert.equal(n, 3);
    e.off('x', f);
    assert.equal(e.listenerCount('x'), 0);
    assert.throws(() => e.emit('error', new Error('boom')), /boom/);
    const p = m.events.once(e, 'y');
    e.emit('y', 7);
    assert.deepEqual(await p, [7]);
  });
  test('stream: Readable.from → Transform → pipeline', async () => {
    const out = [];
    await m.stream.promises.pipeline(
      m.stream.Readable.from(['a', 'b', 'c']),
      new m.stream.Transform({ transform: (c, _e, cb) => cb(null, String(c).toUpperCase()) }),
      new m.stream.Writable({ write: (c, _e, cb) => (out.push(String(c)), cb()) }),
    );
    assert.equal(out.join(''), 'ABC');
  });
  test('string_decoder: многобайтовый символ, разрезанный между кусками', () => {
    const bytes = Buffer.from('ДЕМО·ОС00', 'utf8');
    const a = new m.StringDecoder('utf8');
    const b = new NodeDecoder('utf8');
    let sa = '';
    let sb = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const part = bytes.subarray(i, i + 3);
      sa += a.write(m.Buffer.from(part));
      sb += b.write(part);
    }
    assert.equal(sa + a.end(), sb + b.end());
  });
  test('zlib: понятная ошибка ERR_DEMO_UNSUPPORTED (сжатие в демо не используется), константы есть', () => {
    assert.throws(() => m.zlib.gzipSync(m.Buffer.from('x')), (e) => e.code === 'ERR_DEMO_UNSUPPORTED');
    assert.equal(typeof m.zlib.constants.Z_OK, 'number');
  });
});

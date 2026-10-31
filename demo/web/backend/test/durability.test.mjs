// Review fixes: сохранность ответа и сбои записи (critic [4], [1]; находки ревью «durability», «broken screen after a
// backend crash», «history seed idempotency», «demo panel produces an inconsistent order»).
//
// 1. Мост + единица работы (без PGlite, те же модули, что в backend.js — bridge-server.mjs, alias/work-gate.mjs):
//    - изменяющий запрос, чей сброс тома вернул {error}: с Idempotency-Key — 503 без поля code (RetryInterceptor
//      приложения повторит тем же ключом), без ключа (POST) — ответ с x-demo-durability: failed; {fenced} — 503
//      SERVICE_UNAVAILABLE; исключение хука конца единицы — тоже не «успех»;
//    - GET-ответ ждёт идущий изменяющий сброс (durability.mustWait/idle), обычный GET — сразу;
//    - сервер мёртв (isDead) — 503 без выполнения.
// 2. Собранный site/backend/backend.js (worker-harness, память):
//    - testStorage: сбой записи → 503 на PUT с ключом, сообщение `storage {ok:false}`; повтор тем же ключом → 200 и
//      `storage {ok:true}`; POST без ключа → 202 с x-demo-durability: failed;
//    - задача pg-boss, записавшая номер «1С» заказа (outbox), — durable (counters.endHook.jobFlushes);
//    - «Отгрузить» неоплаченный заказ → STATE с подсказкой, «ship» нет в действиях;
//    - PGlite «погиб» после ready (testKillPglite) → fatal pglite_aborted, запросы → 503 «Сервер демо остановился»;
//    - сид истории: «F5» (dump → новый старт на том же каталоге данных), пока шаг «shipped» уже создал заказ, —
//      шаг продолжает тот же заказ: ровно 5 заказов истории, resumed ≥ 1.
//   node --test demo/web/backend/test/durability.test.mjs
import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';
import { bundleForTest } from './support/bundle-for-test.mjs';
import { startWorkerBackend } from './harness/worker-harness.mjs';
import { cashAmount, createCtx, placeOrder, sellable, sleep } from './scenarios/dsl.mjs';

let m;
const posts = [];
const enc = new TextEncoder();
const dec = new TextDecoder();

before(async () => {
  m = await bundleForTest(
    'durability',
    `export { BridgeServer, durableFailure } from './bridge-server.mjs';
     export * as gate from './alias/work-gate.mjs';`,
  );
  globalThis.__posDemoLog = () => {};
  m.gate.configureGate({ quietMs: 2, quietMaxMs: 20 });
});
after(() => {
  setTimeout(() => process.exit(), 300).unref();
});

/** express-заглушка: тело отражается; GET — 200, прочее — 201. */
function handler(req, res) {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    res.statusCode = req.method === 'GET' ? 200 : 201;
    res.setHeader('content-type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ m: req.method, u: req.url }));
  });
}

function makeBridge(extra = {}) {
  posts.length = 0;
  return new m.BridgeServer({ handler, post: (msg) => posts.push(msg), log: () => {}, ...extra });
}
let seq = 0;
async function call(bridge, method, url, headers = [], body = null) {
  const id = `t${++seq}`;
  const t0 = Date.now();
  bridge.handleHttp({ id, method, url, headers, body: body ? enc.encode(JSON.stringify(body)).buffer : null });
  for (let i = 0; i < 400; i++) {
    const r = posts.find((p) => p.type === 'http:res' && p.id === id);
    if (r) {
      const h = Object.fromEntries((r.headers ?? []).map(([k, v]) => [k.toLowerCase(), v]));
      const text = r.body ? dec.decode(new Uint8Array(r.body)) : '';
      return { status: r.status, headers: h, json: text ? JSON.parse(text) : null, ms: Date.now() - t0 };
    }
    await sleep(5);
  }
  throw new Error(`нет ответа на ${method} ${url}`);
}

describe('мост и единица работы: ответ только после записи на диск', () => {
  test('сброс тома {error}: PUT и POST с ключом → 503 без code; POST без ключа → 201 с x-demo-durability: failed', async () => {
    const b = makeBridge();
    m.gate.setUnitEndHook(async (u) => (u.durable ? { afterRelease: async () => ({ error: 'QuotaExceededError' }) } : undefined));
    const put = await call(b, 'PUT', '/api/v1/cart/items/x', [['content-type', 'application/json']], { a: 1 });
    assert.equal(put.status, 503);
    assert.equal(put.json.code, undefined, 'без code — RetryInterceptor повторяет 503 без problem-кода');
    const post = await call(b, 'POST', '/api/v1/orders', [['Idempotency-Key', 'k-1']], { a: 1 });
    assert.equal(post.status, 503);
    const otp = await call(b, 'POST', '/api/v1/auth/otp/request', [], { phone: '+996777000905' });
    assert.equal(otp.status, 201);
    assert.equal(otp.headers['x-demo-durability'], 'failed');
    assert.equal(b.stats.durableFailed503, 2);
    assert.equal(b.stats.durableFailedMarked, 1);
  });
  test('том перехвачен ({fenced}) → 503 SERVICE_UNAVAILABLE; исключение хука конца единицы → 503, не «успех»', async () => {
    const b = makeBridge();
    m.gate.setUnitEndHook(async (u) => (u.durable ? { afterRelease: async () => ({ fenced: true }) } : undefined));
    const f = await call(b, 'POST', '/api/v1/orders', [['Idempotency-Key', 'k-2']], {});
    assert.equal(f.status, 503);
    assert.equal(f.json.code, 'SERVICE_UNAVAILABLE');
    m.gate.setUnitEndHook(async () => {
      throw new Error('writeMeta упал');
    });
    const h = await call(b, 'DELETE', '/api/v1/cart?rowVersion=1');
    assert.equal(h.status, 503);
    assert.match(h.json.detail, /не дал сохранить/);
  });
  test('сброс удался → изменяющий запрос 201 (без пометок); GET без изменений — сразу', async () => {
    const b = makeBridge();
    m.gate.setUnitEndHook(async (u) => (u.durable ? { afterRelease: async () => ({ ms: 3 }) } : undefined));
    const ok = await call(b, 'POST', '/api/v1/orders', [['Idempotency-Key', 'k-3']], {});
    assert.equal(ok.status, 201);
    assert.equal(ok.headers['x-demo-durability'], undefined);
    const g = await call(b, 'GET', '/api/v1/me');
    assert.equal(g.status, 200);
    assert.equal(b.stats.getDeferred, 0);
  });
  test('GET при идущем изменяющем сбросе ждёт его конца (durability.idle)', async () => {
    let release;
    const idle = new Promise((r) => (release = r));
    let pending = true;
    const b = makeBridge({ durability: { mustWait: () => pending, idle: () => idle } });
    m.gate.setUnitEndHook(async () => undefined);
    const p = call(b, 'GET', '/api/v1/payments/1?wait=25');
    await sleep(120);
    assert.equal(posts.filter((x) => x.type === 'http:res').length, 0, 'ответ GET ещё не ушёл');
    pending = false;
    release();
    const r = await p;
    assert.equal(r.status, 200);
    assert.equal(b.stats.getDeferred, 1);
    assert.ok(r.ms >= 100, `ответ через ${r.ms} мс`);
  });
  test('сервер мёртв (PGlite погиб) → 503 без выполнения', async () => {
    let calls = 0;
    const b = new m.BridgeServer({ handler: (q, s) => (calls++, handler(q, s)), post: (msg) => posts.push(msg), log: () => {}, isDead: () => true });
    posts.length = 0;
    const r = await call(b, 'GET', '/api/v1/me');
    assert.equal(r.status, 503);
    assert.match(r.json.title, /остановился/);
    assert.equal(calls, 0);
    m.gate.setUnitEndHook(null);
  });
});

describe('собранный backend.js: сбой записи, задачи, «Отгрузить», гибель PGlite', () => {
  let be;
  let ctx;
  let C;
  before(async () => {
    be = await startWorkerBackend({ sku: 500, initOpts: { seed: false, testHooks: true } });
    ctx = createCtx(be, { label: 'durability' });
    C = ctx.dev('windows', { name: 'кассир 906' });
    await C.login('+996777000906');
  });
  after(async () => {
    await be?.close();
  });

  test('сбой записи тома: PUT с ключом → 503 и `storage {ok:false}`; повтор тем же ключом → 200 и `storage {ok:true}`; POST без ключа → 202 с пометкой', async () => {
    const p = (await sellable(C, { limit: 30 }))[0];
    const cart = (await C.call('GET /cart', 'GET', '/cart')).json;
    await be.rpc({ type: 'testStorage', failNext: 1 });
    const key = crypto.randomUUID();
    const body = { quantity: { value: '2', unitId: p.baseUnit.id, packagingId: null }, rowVersion: cart.rowVersion, mode: 'set' };
    const r1 = await C.call('PUT (сбой записи)', 'PUT', `/cart/items/${p.defaultVariantId}`, { idem: key, body, expect: 503 });
    assert.equal(r1.status, 503, JSON.stringify(r1.json));
    assert.equal(r1.json?.code, undefined);
    for (let i = 0; i < 40 && !be.storageEvents.some((e) => e.ok === false); i++) await sleep(25);
    assert.ok(be.storageEvents.some((e) => e.ok === false && /testFlushFailures/.test(e.error)), JSON.stringify(be.storageEvents));
    const r2 = await C.call('PUT (повтор тем же ключом)', 'PUT', `/cart/items/${p.defaultVariantId}`, { idem: key, body });
    assert.equal(r2.status, 200, JSON.stringify(r2.json));
    for (let i = 0; i < 40 && !be.storageEvents.some((e) => e.ok === true); i++) await sleep(25);
    assert.ok(be.storageEvents.some((e) => e.ok === true), 'восстановление записи сообщено странице');
    await be.rpc({ type: 'testStorage', failNext: 1 });
    const otp = await C.call('POST otp/request без ключа (сбой записи)', 'POST', '/auth/otp/request', { body: { phone: '+996777000905', purpose: 'login_or_register', locale: 'ru' }, expect: 202 });
    assert.equal(otp.status, 202);
    assert.equal(otp.headers['x-demo-durability'], 'failed');
  });

  test('задача pg-boss, записавшая номер «1С», сбрасывается сразу; «Отгрузить» неоплаченный заказ → STATE', async () => {
    const pl = await sellable(C, { limit: 60 });
    const before = (await be.control('GET state')).counters.endHook;
    const { order } = await placeOrder(C, pl[1], 'cash', { label: 'неоплаченный' });
    const o = order.json;
    const linked = await C.poll('номер «1С»', 'GET', `/orders/${o.id}`, (r) => !!r.json?.onec?.number, { timeoutMs: 30000 });
    assert.ok(linked.json?.onec?.number, 'номер «1С»');
    const st = await be.control('GET state');
    assert.ok(st.counters.endHook.jobFlushes > before.jobFlushes, JSON.stringify({ before, after: st.counters.endHook }));
    const row = st.orders.find((x) => x.id === o.id);
    assert.equal(row?.status, 'awaiting_payment');
    assert.ok(!row.actions.includes('ship'), JSON.stringify(row.actions));
    await assert.rejects(be.control(`POST orders/${o.id}/ship`, {}), (e) => e.code === 'STATE' && /сначала примите оплату/.test(e.message));
    // оплачен и согласован → «Отгрузить» доступно
    await C.call('оплата', 'POST', `/orders/${o.id}/payments`, { idem: true, body: { method: 'cash', receivedAmount: cashAmount(o) }, expect: [200, 201] });
    await be.control(`POST orders/${o.id}/onec-status`, { status: 'КВыполнению', approved: true });
    await C.poll('согласован', 'GET', `/orders/${o.id}`, (r) => ['approved', 'awaiting_shipment'].includes(r.json?.status), { timeoutMs: 30000 });
    const sh = await be.control(`POST orders/${o.id}/ship`, {});
    assert.equal(sh.status, 'shipped');
  });

  test('PGlite погиб после ready → fatal pglite_aborted, запросы → 503 «Сервер демо остановился»', async () => {
    await be.rpc({ type: 'testKillPglite' });
    let r;
    for (let i = 0; i < 60 && !be.fatalEvents.length; i++) {
      r = await C.call('GET /me (после гибели PGlite)', 'GET', '/me', { expect: (s) => s >= 200 });
      if (!be.fatalEvents.length) await sleep(100);
    }
    assert.ok(be.fatalEvents.some((f) => f.code === 'pglite_aborted' && /Обновите страницу/.test(f.message)), JSON.stringify(be.fatalEvents));
    r = await C.call('GET /me (сервер мёртв)', 'GET', '/me', { expect: 503 });
    assert.equal(r.status, 503);
    assert.match(r.json?.title ?? '', /остановился/);
  });
});

describe('сид истории: «F5» посреди шага не создаёт второй заказ', () => {
  test('dump, пока шаг «shipped» уже создал заказ → новый старт продолжает его: 5 заказов истории, resumed ≥ 1', async () => {
    let be = await startWorkerBackend({ sku: 500, initOpts: { seedDelayMs: 100 } });
    let dump = null;
    let at = null;
    try {
      for (let i = 0; i < 900 && !dump; i++) {
        const s = (await be.control('GET state')).seed;
        if (s?.state === 'failed') throw new Error(`сид упал: ${s.message}`);
        if (s?.state === 'done') throw new Error('сид закончился раньше, чем поймали шаг shipped с заказом');
        if (s?.step === 'shipped' && s.pending?.some((x) => x.step === 'shipped' && x.order)) {
          at = s;
          const r = await be.rpc({ type: 'dump' }, 60000);
          dump = r.data;
          break;
        }
        await sleep(60);
      }
      assert.ok(dump, 'шаг shipped с заказом пойман');
    } finally {
      await be.terminate();
    }
    be = await startWorkerBackend({ sku: 500, initOpts: { seedDelayMs: 100, loadDataDir: dump } });
    try {
      let s;
      for (let i = 0; i < 600; i++) {
        s = (await be.control('GET state')).seed;
        if (s?.state === 'done' || s?.state === 'failed') break;
        await sleep(200);
      }
      assert.equal(s?.state, 'done', JSON.stringify(s));
      assert.ok(s.resumed >= 1, `resumed ${s.resumed} (поймано: ${JSON.stringify(at)})`);
      const st = await be.control('GET state');
      assert.equal(st.orders.length, 5, JSON.stringify(st.orders.map((o) => `${o.number} ${o.status}`)));
      assert.ok(st.orders.some((o) => o.status === 'shipped'), 'отгруженный');
      assert.ok(st.orders.some((o) => o.status === 'cancelled' || o.status === 'pending_approval'), 'отменённый (или отмена запрошена)');
    } finally {
      await be.close();
    }
  });
});

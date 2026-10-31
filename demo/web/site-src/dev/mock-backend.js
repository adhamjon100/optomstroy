// Оптомстрой POS · веб-демо · ИМИТАЦИЯ backend.js для проверки страницы WP-S1 (не публикуется на сайт).
// Тот же протокол postMessage, что ждёт demo-bridge.js (plan §3.3 + handoff WP-S1): loaded → init → progress… → ready;
// http / http:cancel / control / flush / shutdown. «Том» — IndexedDB optomstroy-mock-<dbName> (имитация PGlite):
// изменяющий запрос пишет состояние в том сразу (как syncToFs до ответа), но только если поколение fence совпадает с
// поколением init (fencing WP-B3). Настройки имитации — GET /__dev/mock-config (fatal, initDelayMs, fenceCheck).
const S = {
  opts: null,
  cfg: {},
  ready: false,
  db: null,
  state: null,
  generation: 0,
  fenced: false,
  slow: new Map(),
  log: [],
  ticker: null,
  persists: 0,
  refusedPersists: 0,
};
const post = (m, t) => self.postMessage(m, t || []);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const note = (type, data) => {
  S.log.push({ t: Date.now(), type, ...(data || {}) });
  if (S.log.length > 300) S.log.splice(0, 100);
};
const uuid = () => crypto.randomUUID();

function freshState() {
  return {
    seq: 4600,
    orderNo: 100,
    orders: [],
    returns: [],
    qr: { paidAfterPolls: 5, pollSeconds: 2, pending: [] },
    onec: { down: false, orderMode: 'accept', failNext: 0 },
    seed: { state: 'done', pct: 100 },
  };
}

function idbOpen(name, store) {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open(name, 1);
    r.onupgradeneeded = () => {
      if (!r.result.objectStoreNames.contains(store)) r.result.createObjectStore(store);
    };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
function idbGet(db, store, key) {
  return new Promise((resolve, reject) => {
    const r = db.transaction(store, 'readonly').objectStore(store).get(key);
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
function idbPut(db, store, key, value) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, 'readwrite');
    tx.objectStore(store).put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

// Fence: как воркер (demo-storage.mjs, review fixes) — наибольшее поколение из имён баз
// optomstroy-demo-fence-g<поколение>-t<вкладка> (indexedDB.databases(), без транзакций); их нет — прежнее хранилище
// optomstroy-demo-fence / fence / 'generation' → {generation, tabId, at}. Только чтение.
async function readFence() {
  if (typeof indexedDB.databases === 'function') {
    try {
      let best = null;
      for (const d of await indexedDB.databases()) {
        const m = d && d.name ? /^optomstroy-demo-fence-g(\d+)-t([0-9a-z]+)$/.exec(d.name) : null;
        if (m && (!best || Number(m[1]) > best.generation)) best = { generation: Number(m[1]), tabId: m[2] };
      }
      if (best) return best;
    } catch (e) {
      /* хранилище fence */
    }
  }
  return readFenceStore();
}
function readFenceStore() {
  return new Promise((resolve) => {
    const r = indexedDB.open('optomstroy-demo-fence');
    r.onsuccess = () => {
      const db = r.result;
      if (!db.objectStoreNames.contains('fence')) {
        db.close();
        resolve(null);
        return;
      }
      const g = db.transaction('fence', 'readonly').objectStore('fence').get('generation');
      g.onsuccess = () => {
        db.close();
        resolve(g.result || null);
      };
      g.onerror = () => {
        db.close();
        resolve(null);
      };
    };
    r.onerror = () => resolve(null);
  });
}

async function generationOk() {
  if (S.cfg.fenceCheck === false) return true;
  const f = await readFence();
  if (!f || f.generation === S.generation) return true;
  if (!S.fenced) {
    S.fenced = true;
    post({ type: 'fenced', generation: S.generation, volumeGeneration: f.generation });
  }
  return false;
}

async function persist(reason) {
  if (!S.db || !S.state) return false;
  if (!(await generationOk())) {
    S.refusedPersists++;
    note('persist-refused', { reason });
    return false;
  }
  await idbPut(S.db, 'kv', 'state', S.state);
  S.persists++;
  note('persist', { reason, orders: S.state.orders.length });
  return true;
}

function respond(id, status, body, headers) {
  const bytes = body === undefined || body === null ? new Uint8Array(0) : body instanceof Uint8Array ? body : new TextEncoder().encode(JSON.stringify(body));
  const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const h = [['content-type', body instanceof Uint8Array ? 'application/octet-stream' : status >= 400 ? 'application/problem+json; charset=utf-8' : 'application/json; charset=utf-8'], ['x-request-id', uuid()]].concat(headers || []);
  post({ type: 'http:res', id, status, headers: h, body: ab, workerMs: 1 }, [ab]);
}

const problem = (status, code, title) => ({ type: `https://demo.invalid/problems/${code.toLowerCase().replace(/_/g, '-')}`, title, status, code, requestId: uuid() });

function createOrder(body) {
  const st = S.state;
  st.orderNo++;
  const o = {
    id: uuid(),
    number: `000${st.orderNo}`,
    onecNumber: null,
    status: body.payment === 'qr' ? 'awaiting_payment' : 'paid',
    onecStatus: null,
    approved: false,
    shipped: false,
    total: String(body.total || '1250.00'),
    payment: body.payment || 'cash',
    createdAt: new Date().toISOString(),
  };
  if (!st.onec.down) {
    if (st.onec.orderMode === 'reject' && st.onec.failNext > 0) {
      st.onec.failNext--;
      if (st.onec.failNext === 0) st.onec.orderMode = 'accept';
      o.onecSync = 'rejected';
    } else {
      st.seq++;
      o.onecNumber = `ОС00-00${st.seq}`;
      o.onecStatus = 'НеСогласован';
    }
  }
  st.orders.unshift(o);
  if (o.payment === 'qr') st.qr.pending.push({ paymentId: uuid(), externalId: uuid(), orderId: o.id, orderNumber: o.number, amount: o.total, polls: 0, createdAt: o.createdAt });
  return o;
}

async function handleHttp(m) {
  post({ type: 'http:start', id: m.id });
  const u = new URL(m.url, 'http://mock');
  const p = u.pathname;
  const bodyText = m.body ? new TextDecoder().decode(new Uint8Array(m.body)) : '';
  note('http', { id: m.id, method: m.method, url: m.url });
  if (!S.ready) return respond(m.id, 503, problem(503, 'SERVICE_UNAVAILABLE', 'not ready'));
  if (p === '/health' || p === '/api/v1/health') return respond(m.id, 200, { status: 'ok', mock: true });
  if (p === '/api/v1/demo-mock/orders' && m.method === 'GET') return respond(m.id, 200, { items: S.state.orders, generation: S.generation });
  if (p === '/api/v1/demo-mock/orders' && m.method === 'POST') {
    const o = createOrder(bodyText ? JSON.parse(bodyText) : {});
    await persist('POST orders');
    return respond(m.id, 201, o);
  }
  if (p === '/api/v1/demo-mock/echo') return respond(m.id, 200, m.body ? new Uint8Array(m.body) : new Uint8Array(0));
  if (p === '/api/v1/demo-mock/headers') return respond(m.id, 200, { headers: m.headers, method: m.method });
  if (p === '/api/v1/demo-mock/slow') {
    const ms = Number(u.searchParams.get('ms') || 3000);
    const t = setTimeout(() => {
      S.slow.delete(m.id);
      respond(m.id, 200, { slow: ms });
    }, ms);
    S.slow.set(m.id, t);
    return undefined;
  }
  return respond(m.id, 404, problem(404, 'NOT_FOUND', 'Не найдено (имитация)'));
}

function stateView() {
  const st = S.state;
  return {
    epoch: `mock-${S.opts.epochKey}`,
    buildId: S.opts.buildId,
    storage: S.opts.storage,
    generation: S.generation,
    qr: st.qr,
    onec: st.onec,
    orders: st.orders.slice(0, 10).map((o) => ({ ...o, returns: st.returns.filter((r) => r.orderId === o.id) })),
    returns: st.returns,
    seed: st.seed,
    counters: { persists: S.persists, refusedPersists: S.refusedPersists, piggybacks: 0, lockWaitsOver3s: 0 },
  };
}

async function handleControl(m) {
  const [method, path] = String(m.action || '').split(' ');
  const a = m.args || {};
  const st = S.state;
  const ok = (data) => post({ type: 'control:res', id: m.id, ok: true, data });
  const fail = (code, message) => post({ type: 'control:res', id: m.id, ok: false, error: { code, message } });
  note('control', { action: m.action });
  let r;
  if (method === 'GET' && path === 'state') return ok(stateView());
  if (method === 'GET' && path === 'debug') return ok({ log: S.log.slice(-80), generation: S.generation, fenced: S.fenced, persists: S.persists, refusedPersists: S.refusedPersists, opts: S.opts });
  if (method === 'POST' && path === '__mock/fatal') {
    ok({});
    const code = a.code || 'mock';
    setTimeout(() => post({ type: 'fatal', message: code === 'mock' ? 'Имитация: сервер демо упал во время работы (mock runtime fatal)' : `Имитация: fatal ${code}`, code }), 30);
    return undefined;
  }
  // review fixes: сообщение воркера `storage` — запись тома не удаётся / восстановилась.
  if (method === 'POST' && path === '__mock/storage') {
    ok({});
    setTimeout(() => post(a.ok === false ? { type: 'storage', ok: false, error: a.error || 'QuotaExceededError (имитация)', failures: 1, kind: S.opts.storage } : { type: 'storage', ok: true, kind: S.opts.storage }), 20);
    return undefined;
  }
  if (method === 'POST' && path === 'qr/config') {
    st.qr.paidAfterPolls = Number(a.paidAfterPolls) || 0;
    await persist('qr/config');
    return ok(st.qr);
  }
  if (method === 'POST' && (r = /^qr\/([^/]+)\/(pay|expire)$/.exec(path))) {
    const i = st.qr.pending.findIndex((q) => q.paymentId === r[1] || q.externalId === r[1]);
    if (i < 0) return fail('not_found', 'QR не найден');
    const q = st.qr.pending.splice(i, 1)[0];
    const o = st.orders.find((x) => x.id === q.orderId);
    if (o) o.status = r[2] === 'pay' ? 'paid' : 'payment_expired';
    if (o && r[2] === 'pay' && a.amount) o.paidAmount = String(a.amount);
    await persist(`qr/${r[2]}`);
    return ok({ paymentId: q.paymentId, status: r[2] === 'pay' ? 'received' : 'expired' });
  }
  if (method === 'POST' && path === 'onec/down') {
    st.onec.down = !!a.down;
    await persist('onec/down');
    return ok(st.onec);
  }
  if (method === 'POST' && path === 'onec/orders/mode') {
    st.onec.orderMode = a.mode || 'accept';
    st.onec.failNext = Number(a.failNext) || 0;
    await persist('onec/mode');
    return ok(st.onec);
  }
  if (method === 'POST' && (r = /^orders\/([^/]+)\/(onec-status|ship)$/.exec(path))) {
    const o = st.orders.find((x) => x.id === r[1]);
    if (!o) return fail('not_found', 'Заказ не найден');
    if (r[2] === 'ship') {
      o.shipped = true;
      st.returns.push({ externalId: uuid(), orderId: o.id, orderNumber: o.number, status: 'submitted' });
    } else {
      o.onecStatus = a.status || o.onecStatus;
      if (a.approved !== undefined) o.approved = !!a.approved;
    }
    await persist(r[2]);
    return ok(o);
  }
  if (method === 'POST' && (r = /^returns\/([^/]+)\/status$/.exec(path))) {
    const ret = st.returns.find((x) => x.externalId === r[1]);
    if (!ret) return fail('not_found', 'Заявка на возврат не найдена');
    ret.status = a.status;
    await persist('returns');
    return ok(ret);
  }
  return fail('not_found', `unknown action ${m.action}`);
}

async function tick() {
  if (!S.ready || !S.state) return;
  const st = S.state;
  if (!st.qr.pending.length) return;
  let changed = false;
  for (const q of st.qr.pending.slice()) {
    q.polls++;
    changed = true;
    if (st.qr.paidAfterPolls > 0 && q.polls >= st.qr.paidAfterPolls) {
      st.qr.pending.splice(st.qr.pending.indexOf(q), 1);
      const o = st.orders.find((x) => x.id === q.orderId);
      if (o) o.status = 'paid';
    }
  }
  if (changed) await persist('qr tick');
}

async function init(m) {
  S.opts = m;
  S.generation = m.generation;
  try {
    S.cfg = await (await fetch('/__dev/mock-config', { cache: 'no-store' })).json();
  } catch {
    S.cfg = {};
  }
  const delay = Number(S.cfg.initDelayMs ?? 1200);
  const t0 = performance.now();
  for (const [stage, pct] of [['pglite', 10], ['migrate', 35], ['snapshot', 60], ['nest', 80], ['worker', 92]]) {
    post({ type: 'progress', stage, pct });
    await sleep(delay / 5);
    if (S.cfg.fatal && stage === 'migrate') {
      post({ type: 'fatal', message: 'Имитация: не удалось открыть базу данных PGlite (mock fatal)\n    at init (mock-backend.js)', code: 'mock' });
      return;
    }
  }
  S.db = await idbOpen(`optomstroy-mock-${m.dbName}`, 'kv');
  const saved = await idbGet(S.db, 'kv', 'state');
  S.state = saved || freshState();
  S.ready = true;
  S.ticker = setInterval(() => void tick(), 2000);
  post({
    type: 'ready',
    id: m.id,
    epoch: `mock-${m.epochKey}`,
    buildId: m.buildId,
    storage: m.storage,
    generation: m.generation,
    warm: !!saved,
    features: ['http:start'],
    timings: { totalMs: Math.round(performance.now() - t0), warm: !!saved, mock: true },
  });
}

self.addEventListener('message', async (ev) => {
  const m = ev.data || {};
  note(`msg:${m.type}`, { generation: m.generation, reason: m.reason });
  try {
    switch (m.type) {
      case 'init':
        await init(m);
        return;
      case 'http':
        await handleHttp(m);
        return;
      case 'http:cancel': {
        const t = S.slow.get(m.id);
        if (t) {
          clearTimeout(t);
          S.slow.delete(m.id);
        }
        note('cancelled', { id: m.id });
        return;
      }
      case 'control':
        await handleControl(m);
        return;
      case 'flush': {
        const okGen = m.generation === S.generation;
        const done = okGen ? await persist(`flush:${m.reason}`) : false;
        post({ type: 'flush:ok', id: m.id, ok: done, data: { persisted: done } });
        return;
      }
      case 'shutdown':
        if (S.ticker) clearInterval(S.ticker);
        S.ready = false;
        if (S.db) S.db.close();
        S.db = null;
        post({ type: 'shutdown:ok', id: m.id });
        return;
      default:
        post({ type: 'res', id: m.id, ok: false, error: `unknown message ${m.type}` });
    }
  } catch (e) {
    post({ type: 'log', level: 'error', msg: `mock: ${e && e.stack ? e.stack : e}` });
    if (m.type === 'http') respond(m.id, 500, problem(500, 'INTERNAL', String(e)));
    if (m.type === 'control') post({ type: 'control:res', id: m.id, ok: false, error: { code: 'mock_error', message: String(e) } });
  }
});

post({ type: 'loaded' });

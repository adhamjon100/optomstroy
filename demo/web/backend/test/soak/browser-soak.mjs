// Сокращённый soak WP-T1 в браузере (critic [4]: «вкладка открыта 8 часов»; рост IndexedDB, запись на диск, память).
// Страница WP-S1 (demo-bridge.js, demo-boot.js, панель; Flutter — фейковый загрузчик S1) + НАСТОЯЩИЙ backend.js в
// headless Chrome (или Edge) через CDP на глобальном WebSocket Node 24, без puppeteer. Хранилище — IndexedDB (idb).
// Нагрузка — как в scenarios/soak.mjs: опросы экранов каждые 30 с, продажа и QR раз в ~3 мин, остальное — простой.
// Раз в минуту: navigator.storage.estimate() (usage — IndexedDB origin), счётчики записи воркера (io.idbBytes,
// io.idbPuts, сбросы тома), heap воркера (performance.memory), куча WASM, pg_database_size. По наклону — 8 часов.
//
//   node demo/web/backend/test/soak/browser-soak.mjs [--minutes 20] [--browser chrome|edge] [--storage idb|opfs]
//        [--port 8095..8099] [--cdp 9481] [--commit-delay-ms N] [--json <файл>]
// Свой сервер и браузер убиваются по PID, профиль .tmp/web_demo/chrome-t1-soak-* удаляется.
//
// Fix round 2: --commit-delay-ms N — «медленный диск»: воркер ждёт N мс после каждого commit IndexedDB
// (init.testFlushCommitDelayMs через ?initExtra=, только 127.0.0.1). Проверка: ответы изменяющих запросов ждут
// commit (bridge.maxDurableWaitMs ≥ N), а сторож молчит — commit не держит ни замок сессии, ни слот единицы работы
// (до fix round 2 такой commit под замком давал ожидания > 3 с у опросов pg-boss и запросов приложения).
import { spawn } from 'node:child_process';
import { mkdirSync, rmSync } from 'node:fs';
import net from 'node:net';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ROOT, SITE } from '../../lib/paths.mjs';
import { slopePerHour } from '../scenarios/soak.mjs';
import { writeJson } from '../lib/report.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const portFree = (port) =>
  new Promise((res) => {
    const s = net.createServer();
    s.once('error', () => res(false));
    s.listen(port, '127.0.0.1', () => s.close(() => res(true)));
  });

export async function runBrowserSoak({ minutes = 20, browser = 'chrome', storage = 'idb', port, cdpPort = 9481, commitDelayMs = 0, log = console.log } = {}) {
  if (!port) for (const p of [8095, 8096, 8097, 8098, 8099]) if (await portFree(p)) {
    port = p;
    break;
  }
  if (!port) throw new Error('нет свободного порта 8095–8099');
  const EXE = browser === 'edge' ? 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' : 'C:/Program Files/Google/Chrome/Application/chrome.exe';
  const PROFILE = `${ROOT}/.tmp/web_demo/chrome-t1-soak-${browser}${commitDelayMs ? `-slow${commitDelayMs}` : ''}-${Date.now()}`;
  const ORIGIN = `http://127.0.0.1:${port}`;
  const res = { browser, storage, port, commitDelayMs, samples: [], exceptions: [], consoleErrors: [], requests: { own: 0, foreign: [] }, checks: [] };
  const server = spawn(process.execPath, [`${ROOT}/demo/web/site-src/dev/serve.mjs`, '--port', String(port), '--backend-dir', `${SITE}/backend`, '--site-dir', SITE], { stdio: 'ignore' });
  let proc = null;
  let ws = null;
  const pend = new Map();
  let mid = 0;
  const send = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      const id = ++mid;
      pend.set(id, { resolve, reject, method });
      ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  let page = null;
  let worker = null;
  const ev = async (s, expression, ms = 120000) => {
    const r = await Promise.race([send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, s), sleep(ms).then(() => ({ timeout: true }))]);
    if (r.timeout) throw new Error(`timeout: ${expression.slice(0, 80)}`);
    if (r.exceptionDetails) throw new Error(`${r.exceptionDetails.text} ${r.exceptionDetails.exception?.description ?? ''}`);
    return r.result.value;
  };
  try {
    await sleep(900);
    const build = await (await fetch(`${ORIGIN}/backend/build.json`)).json();
    await fetch(`${ORIGIN}/__dev/set-build?epochKey=${encodeURIComponent(build.epochKey)}&buildId=t1-soak-${Date.now()}`);
    await fetch(`${ORIGIN}/__dev/set-mock?flutterDelayMs=300`);
    mkdirSync(PROFILE, { recursive: true });
    proc = spawn(EXE, ['--headless=new', `--remote-debugging-port=${cdpPort}`, `--user-data-dir=${PROFILE}`, '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--disable-component-update', '--disable-sync', 'about:blank'], { stdio: 'ignore' });
    res.pids = { server: server.pid, browser: proc.pid };
    let ver;
    for (let i = 0; i < 150 && !ver; i++) {
      try {
        ver = await (await fetch(`http://127.0.0.1:${cdpPort}/json/version`)).json();
      } catch {
        await sleep(200);
      }
    }
    res.browserVersion = ver.Browser;
    ws = new WebSocket(ver.webSocketDebuggerUrl);
    await new Promise((r) => (ws.onopen = r));
    ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      if (m.id && pend.has(m.id)) {
        const p = pend.get(m.id);
        pend.delete(m.id);
        if (m.error) p.reject(new Error(`${p.method}: ${m.error.message}`));
        else p.resolve(m.result);
        return;
      }
      if (m.method === 'Target.attachedToTarget' && m.params.targetInfo.type === 'worker' && /backend/.test(m.params.targetInfo.url)) {
        worker = m.params.sessionId;
        void send('Runtime.enable', {}, worker).catch(() => undefined);
        void send('HeapProfiler.enable', {}, worker).catch(() => undefined);
        void send('Network.enable', {}, worker).catch(() => undefined);
      }
      if (m.method === 'Network.requestWillBeSent') {
        const u = m.params.request.url;
        if (u.startsWith(ORIGIN) || u.startsWith('data:') || u.startsWith('blob:')) res.requests.own++;
        else if (!u.startsWith('chrome') && !u.startsWith('about:')) res.requests.foreign.push(u.slice(0, 120));
      }
      if (m.method === 'Runtime.exceptionThrown') res.exceptions.push(`${m.params.exceptionDetails.text} ${m.params.exceptionDetails.exception?.description ?? ''}`.slice(0, 600));
      if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') res.consoleErrors.push(m.params.args.map((a) => a.value ?? a.description ?? '').join(' ').slice(0, 400));
    };
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
    page = (await send('Target.attachToTarget', { targetId, flatten: true })).sessionId;
    for (const d of ['Runtime.enable', 'Page.enable', 'Network.enable', 'Performance.enable']) await send(d, {}, page);
    await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, page);
    const t0 = Date.now();
    const extra = commitDelayMs ? `&initExtra=${encodeURIComponent(JSON.stringify({ testFlushCommitDelayMs: commitDelayMs }))}` : '';
    await send('Page.navigate', { url: `${ORIGIN}/?storage=${storage}${extra}` }, page);
    for (let i = 0; i < 600; i++) {
      if (await ev(page, `!!(window.__posDemo && __posDemo.isReady && window.PosDemoPage && PosDemoPage.boot.hidden)`, 10000).catch(() => false)) break;
      await sleep(200);
    }
    res.readyMs = Date.now() - t0;
    res.ready = await ev(page, `({storage: __posDemo.info.storage, warm: __posDemo.info.warm, readyMs: __posDemo.info.timings.readyMs})`);
    log(`[browser-soak] ${res.browserVersion}, ${res.ready.storage}, ready ${res.ready.readyMs} мс`);
    await ev(page, `
      window.__dev = {};
      window.__fails = [];
      window.__api = async function (who, method, url, body, headers) {
        const d = window.__dev[who] || (window.__dev[who] = {id: crypto.randomUUID()});
        const h = Object.assign({'X-Device-Id': d.id, 'X-App-Version': ${JSON.stringify(build.appVersion)}, 'X-Platform': 'windows', 'Accept-Language': 'ru'}, d.token ? {Authorization: 'Bearer ' + d.token} : {}, headers || {});
        if (body !== undefined) h['content-type'] = 'application/json';
        let r = await __posDemo.request({method, url: '/api/v1' + url, headers: h, body: body === undefined ? null : JSON.stringify(body)});
        let json = null; try { json = JSON.parse(new TextDecoder().decode(r.body)); } catch (e) {}
        // как AuthInterceptor приложения: 401 → POST /auth/refresh → один повтор (access-токен живёт 15 мин)
        if (r.status === 401 && d.refresh && json && (json.code === 'UNAUTHENTICATED' || json.code === 'TOKEN_STALE')) {
          const sent = h.Authorization;
          // single-flight, как TokenRefresher приложения: параллельные 401 ждут один POST /auth/refresh (ротация refresh)
          if (!d.refreshing && ('Bearer ' + d.token) === sent) {
            d.refreshing = (async () => {
              const hr = {'X-Device-Id': d.id, 'X-App-Version': h['X-App-Version'], 'X-Platform': 'windows', 'content-type': 'application/json'};
              const rf = await __posDemo.request({method: 'POST', url: '/api/v1/auth/refresh', headers: hr, body: JSON.stringify({refreshToken: d.refresh})});
              let rj = null; try { rj = JSON.parse(new TextDecoder().decode(rf.body)); } catch (e) {}
              window.__refreshes = (window.__refreshes || 0) + 1;
              if (rf.status === 200 && rj && rj.accessToken) { d.token = rj.accessToken; d.refresh = rj.refreshToken || d.refresh; }
              else window.__refreshFailures = (window.__refreshFailures || 0) + 1;
            })().finally(() => { d.refreshing = null; });
          }
          if (d.refreshing) await d.refreshing;
          if (('Bearer ' + d.token) !== sent) {
            h.Authorization = 'Bearer ' + d.token;
            r = await __posDemo.request({method, url: '/api/v1' + url, headers: h, body: body === undefined ? null : JSON.stringify(body)});
            json = null; try { json = JSON.parse(new TextDecoder().decode(r.body)); } catch (e) {}
          }
        }
        if (r.status >= 400 && window.__fails && window.__fails.length < 20) window.__fails.push({url, status: r.status, code: json && json.code});
        return {status: r.status, json};
      };
      window.__login = async function (who, phone) {
        const rq = await __api(who, 'POST', '/auth/otp/request', {phone, purpose: 'login_or_register', locale: 'ru'});
        const vr = await __api(who, 'POST', '/auth/otp/verify', {challengeId: rq.json && rq.json.challengeId, code: '246810', device: {name: 'Chrome (soak)', platform: 'windows', appVersion: ${JSON.stringify(build.appVersion)}}});
        window.__dev[who].token = vr.json && vr.json.accessToken;
        window.__dev[who].refresh = vr.json && vr.json.refreshToken;
        if (vr.json && vr.json.user && vr.json.user.kind === 'staff') await __api(who, 'POST', '/me/pin', {newPin: '715382'}, {'Idempotency-Key': crypto.randomUUID()});
        return vr.status;
      };
      window.__sell = async function (who, idx, method) {
        const pr = await __api(who, 'GET', '/catalog/products?limit=100&inStock=true&sort=price:asc');
        if (!pr.json || !pr.json.items) return 'catalog:' + pr.status;
        const pl = pr.json.items.filter(p => !p.hasVariants && p.price && Number(p.price.price.amount) <= 6000);
        const p = pl[idx % pl.length];
        let c = (await __api(who, 'GET', '/cart')).json;
        if (c.items.length) c = (await __api(who, 'DELETE', '/cart?rowVersion=' + c.rowVersion)).json;
        c = (await __api(who, 'PUT', '/cart/items/' + p.defaultVariantId, {quantity: {value: '1', unitId: p.baseUnit.id, packagingId: null}, rowVersion: c.rowVersion, mode: 'set'}, {'Idempotency-Key': crypto.randomUUID()})).json;
        const pv = (await __api(who, 'POST', '/cart/checkout-preview', {cartId: c.id, cartRowVersion: c.rowVersion, paymentMethod: method, delivery: {method: 'pickup'}, receiver: {kind: 'customer'}}, {'Idempotency-Key': crypto.randomUUID()})).json;
        const o = await __api(who, 'POST', '/orders', {cartId: c.id, cartRowVersion: c.rowVersion, previewToken: pv && pv.previewToken, receiver: {kind: 'customer'}, delivery: {method: 'pickup'}, paymentMethod: method, items: [{variantId: p.defaultVariantId, quantity: {value: '1', unitId: p.baseUnit.id, packagingId: null}}]}, {'Idempotency-Key': crypto.randomUUID()});
        if (method === 'cash' && o.json && o.json.id) await __api(who, 'POST', '/orders/' + o.json.id + '/payments', {method: 'cash', receivedAmount: {amount: Math.ceil(Number(o.json.total.amount)) + '.00', currency: 'KGS'}}, {'Idempotency-Key': crypto.randomUUID()});
        if (method === 'qr_bakai' && o.json && o.json.payments) { const pid = o.json.payments[0].id; for (let i = 0; i < 3; i++) { const r = await __api(who, 'GET', '/payments/' + pid + '?wait=25'); if (r.json && r.json.status === 'received') return 'paid'; } return 'unpaid'; }
        return o.status;
      };
      true`);
    for (const [who, phone] of [['C', '+996777000906'], ['S', '+996777000902'], ['A', '+996777000901']]) await ev(page, `__login(${JSON.stringify(who)}, ${JSON.stringify(phone)})`);
    await ev(page, `__posDemo.control('POST qr/config', {paidAfterPolls: 3})`);
    // самопроверка харнесса: «истёкшие» access-токены у всех → параллельные опросы → один refresh на устройство
    res.refreshSelfTest = await ev(page, `(async () => { for (const d of Object.values(__dev)) d.token = 'x.y.z'; const st = await Promise.all([['C','/me'],['C','/notifications?limit=5'],['C','/pos/dashboard'],['S','/cart'],['A','/sync/status']].map(([w, u]) => __api(w, 'GET', u).then(r => r.status))); return {statuses: st, refreshes: window.__refreshes || 0, failures: window.__refreshFailures || 0}; })()`);
    log(`[browser-soak] самопроверка refresh: ${JSON.stringify(res.refreshSelfTest)}`);
    const sample = async (phase) => {
      const s = await ev(page, `(async () => { const e = await navigator.storage.estimate(); return {usage: e.usage, quota: e.quota, usageDetails: e.usageDetails || null}; })()`);
      const w = worker ? await ev(worker, `__posDemoDiag.stats().then(s => ({io: s.io, storage: s.storage, dbSize: s.dbSize, heap: s.heap, wasm: s.wasmHeapBytes, gate: {holds3s: s.gate.stats.holdsOver3s, queue3s: s.gate.stats.queueWaitsOver3s, maxHoldMs: s.gate.stats.maxHoldMs, afterRelease: s.gate.stats.afterRelease || 0, maxAfterReleaseMs: s.gate.stats.maxAfterReleaseMs || 0, watchdog: s.gate.stats.watchdog.slice(0, 5)}, pg: {waits3s: s.pg.waitsOver3s, outside: s.pg.outsideWhitelist, maxWaitMs: s.pg.maxWaitMs, longWaits: s.pg.longWaits.slice(0, 5)}, bridge: s.bridge && {durable: s.bridge.durable, maxDurableWaitMs: s.bridge.maxDurableWaitMs}, seed: s.seed && s.seed.state}))`).catch(() => null) : null;
      const pm = Object.fromEntries((await send('Performance.getMetrics', {}, page)).metrics.map((x) => [x.name, x.value]));
      // куча JS воркера: performance.memory в выделенном воркере Chrome нет — Runtime.getHeapUsage его сессии CDP
      if (worker) await send('HeapProfiler.collectGarbage', {}, worker).catch(() => null); // «пол» кучи, без пилы GC
      const wh = worker ? await send('Runtime.getHeapUsage', {}, worker).catch(() => null) : null;
      if (w && wh) w.heap = { used: wh.usedSize, total: wh.totalSize };
      res.samples.push({ t: Date.now() - tStart, phase, usage: s.usage, idbUsage: s.usageDetails?.indexedDB ?? null, idbBytes: w?.io?.idbBytes ?? null, idbPuts: w?.io?.idbPuts ?? null, opfsBytes: w?.io?.opfsBytes ?? null, flushes: w?.storage?.flushes ?? null, dbSize: w?.dbSize ?? null, workerHeap: w?.heap?.used ?? null, wasmHeap: w?.wasm ?? null, pageHeap: pm.JSHeapUsedSize ?? null, gate: w?.gate, pg: w?.pg, seed: w?.seed, bridge: w?.bridge ?? null, flush: w?.storage ? { flushes: w.storage.flushes, coalesced: w.storage.coalesced, errors: w.storage.errors, maxMs: w.storage.maxMs, maxLockMs: w.storage.maxLockMs, idb: w.storage.idb && { captures: w.storage.idb.captures, maxCaptureMs: w.storage.idb.maxCaptureMs, maxCommitMs: w.storage.idb.maxCommitMs, aborts: w.storage.idb.aborts, uncertain: w.storage.idb.uncertain, truncates: w.storage.idb.truncates, indexLoads: w.storage.idb.indexLoads } } : null });
    };
    const tStart = Date.now();
    await sample('start');
    let orders = 0;
    let qrPaid = 0;
    let failed = 0;
    let tick = 0;
    let lastSample = Date.now();
    while (Date.now() < tStart + minutes * 60e3) {
      const c0 = Date.now();
      tick++;
      const st = await ev(page, `Promise.all([['C','/me'],['C','/notifications?limit=20'],['C','/pos/dashboard'],['C','/orders?limit=20&include=statusCounts'],['A','/sync/status'],['S','/catalog/products?limit=20&inStock=true'],['S','/cart']].map(([w, u]) => __api(w, 'GET', u).then(r => r.status)))`);
      failed += st.filter((x) => x >= 400 || x === 0).length;
      if (tick % 6 === 1) {
        const cs = await ev(page, `__sell('C', ${orders}, 'cash')`);
        if (![201, 202].includes(cs)) failed++;
        if ((await ev(page, `__sell('S', ${orders + 7}, 'qr_bakai')`)) === 'paid') qrPaid++;
        orders++;
      }
      if (Date.now() - lastSample >= 60e3) {
        await sample(Date.now() - tStart < 3 * 60e3 ? 'warmup' : 'run');
        lastSample = Date.now();
        const x = res.samples.at(-1);
        log(`[browser-soak ${((Date.now() - tStart) / 60e3).toFixed(1)} мин] IndexedDB ${(x.usage / 1e6).toFixed(1)} МБ, записано ${((x.idbBytes ?? 0) / 1e6).toFixed(0)} МБ, heap воркера ${((x.workerHeap ?? 0) / 1e6).toFixed(0)} МБ, wasm ${((x.wasmHeap ?? 0) / 1e6).toFixed(0)} МБ, БД ${((x.dbSize ?? 0) / 1e6).toFixed(1)} МБ`);
      }
      await sleep(Math.max(0, 30e3 - (Date.now() - c0)));
    }
    await sample('end');
    res.orders = orders;
    res.qrPaid = qrPaid;
    res.failedCalls = failed;
    res.tokenRefreshes = await ev(page, `window.__refreshes || 0`).catch(() => null);
    res.refreshFailures = await ev(page, `window.__refreshFailures || 0`).catch(() => null);
    res.failedSamples = await ev(page, `window.__fails || []`).catch(() => null);
  } finally {
    try {
      if (ws) await Promise.race([send('Browser.close').catch(() => undefined), sleep(3000)]);
    } catch {
      /* ignore */
    }
    await sleep(800);
    for (const p of [proc, server]) {
      try {
        if (p && p.exitCode === null) process.kill(p.pid);
      } catch {
        /* ignore */
      }
    }
    await sleep(800);
    for (let i = 0; i < 8; i++) {
      try {
        rmSync(PROFILE, { recursive: true, force: true });
        break;
      } catch {
        await sleep(800);
      }
    }
  }
  const run = res.samples.filter((s) => s.phase === 'run' || s.phase === 'end');
  const S = run.length >= 3 ? run : res.samples;
  const durMin = (res.samples.at(-1).t - res.samples[0].t) / 60e3;
  const mb = (x) => (x === null ? null : +(x / 1e6).toFixed(2));
  const slope = (k) => slopePerHour(S, k);
  const first = res.samples[0];
  const last = res.samples.at(-1);
  res.extrapolation8h = {
    indexedDbUsage: { startMB: mb(first.usage), endMB: mb(last.usage), perHourMB: mb(slope('usage')), in8hMB: mb(last.usage + Math.max(0, slope('usage') ?? 0) * Math.max(0, 8 - durMin / 60)) },
    // запись на диск: IndexedDB (put тома) или OPFS (write sync access handle) — review fixes: soak и на OPFS
    diskWrites: (() => {
      const w = (x) => (x.idbBytes ?? 0) + (x.opfsBytes ?? 0);
      const d = w(last) - w(first);
      return { kind: res.ready?.storage ?? storage, totalMB: mb(d), perMinMB: +(d / 1e6 / Math.max(durMin, 1e-6)).toFixed(2), in8hMB: +((d / 1e6 / Math.max(durMin, 1e-6)) * 480).toFixed(0) };
    })(),
    workerHeap: { endMB: mb(last.workerHeap), perHourMB: mb(slope('workerHeap')), in8hMB: mb((last.workerHeap ?? 0) + Math.max(0, slope('workerHeap') ?? 0) * 8) },
    wasmHeap: { endMB: mb(last.wasmHeap), perHourMB: mb(slope('wasmHeap')) },
    dbSize: { endMB: mb(last.dbSize), perHourMB: mb(slope('dbSize')) },
    pageHeap: { endMB: mb(last.pageHeap), perHourMB: mb(slope('pageHeap')) },
  };
  res.minutes = +durMin.toFixed(1);
  const add = (name, ok, evidence) => res.checks.push({ name, ok: !!ok, evidence: JSON.stringify(evidence) });
  const minOrders = minutes >= 15 ? 3 : 1;
  add(`браузерный soak ${res.minutes} мин (${res.browserVersion ?? browser}, ${res.ready?.storage}${commitDelayMs ? `, commit +${commitDelayMs} мс` : ''}): 0 ответов 5xx, заказы и QR проходят, 0 исключений`, res.failedCalls === 0 && res.orders >= minOrders && res.qrPaid === res.orders && res.exceptions.length === 0, { failedCalls: res.failedCalls, failedSamples: res.failedSamples, orders: res.orders, qrPaid: res.qrPaid, tokenRefreshes: res.tokenRefreshes, refreshFailures: res.refreshFailures, refreshSelfTest: res.refreshSelfTest, exceptions: res.exceptions.slice(0, 3) });
  // Экстраполяция на 8 ч — только для настоящего soak: за 2–3 мин «медленного диска» наклон — это прогрев (сид).
  // Review fixes (OPFS soak): на OPFS Chrome с первой минуты учитывает за origin ~1,4 ГБ квоты — резерв ~2000 открытых
  // sync access handle пула PGlite opfs-ahp (на диске профиль ~0,14 ГБ). Для OPFS проверяется РОСТ за 8 ч (≤ 300 МБ) и
  // что учёт с начала не больше 2 ГБ; для IndexedDB — как раньше, весь объём ≤ 300 МБ.
  const u8 = res.extrapolation8h.indexedDbUsage;
  const opfsKind = (res.ready?.storage ?? storage) === 'opfs';
  const storageOk = opfsKind ? (u8.in8hMB ?? 0) - (u8.startMB ?? 0) <= 300 && (u8.startMB ?? 0) <= 2000 : (u8.in8hMB ?? 0) <= 300;
  if (minutes >= 15) add(opfsKind ? 'браузерный soak → 8 ч: рост хранилища origin (opfs) ≤ 300 МБ, учёт квоты с начала ≤ 2 ГБ, heap воркера ≤ 600 МБ' : `браузерный soak → 8 ч: хранилище origin (${res.ready?.storage ?? storage}) ≤ 300 МБ, heap воркера ≤ 600 МБ`, storageOk && (res.extrapolation8h.workerHeap.in8hMB ?? 0) <= 600, res.extrapolation8h);
  add('браузерный soak: сеть — только свой origin', res.requests.foreign.length === 0, { own: res.requests.own, foreign: res.requests.foreign.slice(0, 5) });
  add('браузерный soak: сторож молчит (0 удержаний/ожиданий > 3 с)', !last.gate || (last.gate.holds3s === 0 && last.gate.queue3s === 0 && last.pg.waits3s === 0), { gate: last.gate, pg: last.pg, flush: last.flush });
  if (commitDelayMs) {
    // Медленный commit: ответ изменяющего запроса ждёт его (critic [4]), замок сессии — только на снимок.
    const f = last.flush;
    add(`медленный commit IndexedDB (+${commitDelayMs} мс): ответы изменяющих запросов ждут commit, замок сессии — только на снимок (< 500 мс), сбросы без ошибок`, !!f && !!last.bridge && last.bridge.maxDurableWaitMs >= commitDelayMs && f.maxLockMs < 500 && f.errors === 0 && (f.idb?.aborts ?? 0) === 0, { bridge: last.bridge, flush: f });
  }
  return res;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const arg = (k, d) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : d);
  const res = await runBrowserSoak({ minutes: Number(arg('--minutes', 20)), browser: arg('--browser', 'chrome'), storage: arg('--storage', 'idb'), port: arg('--port') ? Number(arg('--port')) : undefined, cdpPort: Number(arg('--cdp', 9481)), commitDelayMs: Number(arg('--commit-delay-ms', 0)) });
  const out = arg('--json', null);
  if (out) writeJson(out, res);
  for (const c of res.checks) console.log(`${c.ok ? 'OK  ' : 'FAIL'} ${c.name}\n      ${c.evidence.slice(0, 700)}`);
  process.exit(res.checks.every((c) => c.ok) ? 0 : 1);
}

// Headless-проверка СОБРАННОГО сайта веб-демо (review fixes: часть WP-T2; critic [5], [16], [19], [21]).
// Настоящая страница, настоящее приложение Flutter (main.dart.js), настоящий backend.js на PGlite — через
// tools/serve-site.mjs с заголовками и перенаправлениями Netlify; Chrome --headless=new, CDP на глобальном WebSocket
// Node 24 (без puppeteer). Порт статики 8095–8099 (первый свободный), CDP — первый свободный от 9491.
//
//   node demo/web/tools/smoke.mjs [--storage opfs|idb] [--only boot,ui,f5,frozen] [--out <каталог>] [--keep-profile] [--port 8095–8099] [--cdp <порт>]
//
// Шаги:
//   boot   — загрузка: ready, первый кадр Flutter, кнопка «ДЕМО»; заголовки ответа (CSP, X-Robots-Tag, типы .wasm/.gz),
//            0 нарушений CSP, 0 исключений, 0 запросов на чужие хосты и на /api/ сайта, 0 ошибок загрузки;
//   ui     — вход кассира 906 в НАСТОЯЩЕМ интерфейсе: номер → «Получить код» → код 246810 → PIN 715382 дважды →
//            рабочий экран (координаты — по семантике Flutter, ввод — с выключенной семантикой: handoff «OtpField»);
//   f5     — F5 посреди работы (через мост страницы, как приложение): (а) QR оплачен «Оплатить сейчас» → long-poll
//            received → СРАЗУ F5 → после перезагрузки платёж received, заказ с номером «1С»; если шаг ui вошёл в
//            интерфейс — после F5 интерфейс на SCR-08 `/auth/unlock?mode=cold&from=<прежний адрес>` (G-5; ui:A uiA-01 —
//            раньше вечный скелетон, а проверка смотрела только мост); (б) POST /orders и F5, не
//            дожидаясь ответа → повтор тем же Idempotency-Key после перезагрузки → ровно один новый заказ;
//   frozen — замороженная вкладка: A заморожена (Page.setWebLifecycleState frozen), B «Продолжить здесь» → steal;
//            B работает (IndexedDB) или честно сообщает «данные заняты» (OPFS: дескрипторы замороженной вкладки);
//            A после разморозки уходит на demo-closed.html и НЕ пишет (заказ B на месте после перезагрузки B).
// Итог — <out>/smoke.json и снимки <out>/NN-*.png. Свои сервер и браузер — по PID, профиль удаляется.
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url)).replace(/\\/g, '/');
const WEB = resolve(HERE, '..').replace(/\\/g, '/');
const ROOT = resolve(WEB, '../..').replace(/\\/g, '/');
const argv = process.argv.slice(2);
const arg = (k, d) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : d);
const STORAGE = arg('--storage', 'opfs');
const ONLY = new Set(String(arg('--only', 'boot,ui,f5,frozen')).split(','));
const OUT = resolve(arg('--out', `${ROOT}/.tmp/web_demo/smoke/${STORAGE}-${new Date().toISOString().replace(/[:.]/g, '-')}`)).replace(/\\/g, '/');
const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PROFILE = `${ROOT}/.tmp/web_demo/chrome-smoke-${STORAGE}-${Date.now()}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const log = (...a) => console.log(`${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s`, ...a);
mkdirSync(OUT, { recursive: true });
process.env.TEMP ||= `${ROOT}/.tmp`;

const R = { storage: STORAGE, startedAt: new Date().toISOString(), checks: [], exceptions: [], consoleErrors: [], csp: [], foreign: [], failedLoads: [], pids: {}, shots: [], steps: [] };
const check = (name, ok, evidence) => {
  R.checks.push({ name, ok: !!ok, evidence: evidence === undefined ? null : evidence });
  log(`${ok ? 'OK  ' : 'FAIL'} ${name}${evidence !== undefined ? ` — ${JSON.stringify(evidence).slice(0, 400)}` : ''}`);
  return !!ok;
};
const portFree = (p) => new Promise((res) => {
  const s = net.createServer();
  s.once('error', () => res(false));
  s.listen(p, '127.0.0.1', () => s.close(() => res(true)));
});
const killTree = (pid) => {
  try {
    execFileSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
  } catch {
    /* уже завершён */
  }
};

// ---------------------------------------------------------------- сервер и браузер
// --port / --cdp — заданные порты (параллельные прогоны других задач); без них — первый свободный.
let port = null;
for (const p of argv.includes('--port') ? [Number(arg('--port'))] : [8095, 8096, 8097, 8098, 8099]) if (await portFree(p)) {
  port = p;
  break;
}
if (!port) throw new Error(`нет свободного порта ${argv.includes('--port') ? arg('--port') : '8095–8099'}`);
let cdpPort = null;
for (let p = Number(arg('--cdp', 9491)); p < (argv.includes('--cdp') ? Number(arg('--cdp')) + 1 : 9520); p++) if (await portFree(p)) {
  cdpPort = p;
  break;
}
if (!cdpPort) throw new Error(`нет свободного порта CDP ${arg('--cdp', '9491–9519')}`);
const ORIGIN = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, [`${HERE}/serve-site.mjs`, '--port', String(port), '--quiet'], { stdio: ['ignore', 'pipe', 'pipe'] });
R.pids.server = server.pid;
mkdirSync(PROFILE, { recursive: true });
const chrome = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${cdpPort}`, `--user-data-dir=${PROFILE}`, '--window-size=1280,800', '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-default-apps', '--lang=ru', 'about:blank'], { stdio: 'ignore' });
R.pids.browser = chrome.pid;

let ws;
const pending = new Map();
const sessions = new Map(); // sessionId → { type, url, tab }
const handlers = [];
let seq = 0;
const send = (method, params = {}, sessionId) =>
  new Promise((res, rej) => {
    const id = ++seq;
    pending.set(id, { res, rej, method });
    ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
  });

async function connect() {
  let ver = null;
  for (let i = 0; i < 120 && !ver; i++) {
    try {
      ver = await (await fetch(`http://127.0.0.1:${cdpPort}/json/version`)).json();
    } catch {
      await sleep(250);
    }
  }
  if (!ver) throw new Error('CDP не поднялся');
  R.browserVersion = ver.Browser;
  ws = new WebSocket(ver.webSocketDebuggerUrl);
  await new Promise((r, j) => ((ws.onopen = r), (ws.onerror = j)));
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id);
      pending.delete(m.id);
      if (m.error) p.rej(new Error(`${p.method}: ${JSON.stringify(m.error)}`));
      else p.res(m.result);
      return;
    }
    const sid = m.sessionId;
    const s = sid ? sessions.get(sid) : null;
    if (m.method === 'Target.attachedToTarget') {
      const info = m.params.targetInfo;
      const parent = s;
      sessions.set(m.params.sessionId, { type: info.type, url: info.url, tab: parent?.tab ?? info.targetId });
      void initSession(m.params.sessionId, info.type);
    } else if (m.method === 'Network.requestWillBeSent') {
      const u = m.params.request.url;
      if (!u.startsWith(ORIGIN) && !/^(data|blob|chrome|about|devtools|chrome-extension):/.test(u)) R.foreign.push({ tab: s?.tab, type: s?.type, url: u.slice(0, 160) });
    } else if (m.method === 'Network.loadingFailed') {
      if (!m.params.canceled) R.failedLoads.push({ type: s?.type, error: m.params.errorText });
    } else if (m.method === 'Runtime.exceptionThrown') {
      R.exceptions.push({ type: s?.type, text: `${m.params.exceptionDetails.text} ${m.params.exceptionDetails.exception?.description ?? ''}`.slice(0, 600) });
    } else if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') {
      R.consoleErrors.push({ t: Date.now(), tab: s?.tab, type: s?.type, text: m.params.args.map((a) => a.value ?? a.description ?? '').join(' ').slice(0, 2000) });
    } else if (m.method === 'Log.entryAdded' && /Content Security Policy|Refused to/i.test(m.params.entry.text)) {
      R.csp.push({ type: s?.type, text: m.params.entry.text.slice(0, 300) });
    }
    for (const h of handlers) h(m);
  };
}
async function initSession(sid, type) {
  const tasks = [send('Runtime.enable', {}, sid), send('Network.enable', {}, sid)];
  if (type === 'page') tasks.push(send('Page.enable', {}, sid), send('Log.enable', {}, sid));
  if (['page', 'worker', 'shared_worker'].includes(type)) tasks.push(send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sid));
  await Promise.allSettled(tasks);
}
async function openTab(name) {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  sessions.set(sessionId, { type: 'page', url: 'about:blank', tab: targetId, name });
  await initSession(sessionId, 'page');
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false }, sessionId);
  // нарушения CSP страницы — в журнал (securitypolicyviolation), до любого скрипта страницы
  await send('Page.addScriptToEvaluateOnNewDocument', { source: `window.__cspViolations=[];document.addEventListener('securitypolicyviolation',function(e){window.__cspViolations.push({d:e.violatedDirective,u:String(e.blockedURI).slice(0,160)});});` }, sessionId);
  return { name, targetId, sid: sessionId };
}
const ev = async (tab, expression, timeoutMs = 60000) => {
  const r = await Promise.race([send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, tab.sid), sleep(timeoutMs).then(() => ({ timeout: true }))]);
  if (r.timeout) throw new Error(`timeout ${timeoutMs} мс: ${expression.slice(0, 100)}`);
  if (r.exceptionDetails) throw new Error(`${r.exceptionDetails.text} ${r.exceptionDetails.exception?.description ?? ''}`.slice(0, 600));
  return r.result.value;
};
const waitFor = async (tab, expr, timeoutMs, label) => {
  const end = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < end) {
    try {
      const v = await ev(tab, expr, 10000);
      if (v) return v;
    } catch (e) {
      last = e;
    }
    await sleep(200);
  }
  throw new Error(`не дождались: ${label}${last ? ` (${String(last.message).slice(0, 200)})` : ''}`);
};
let shotN = 0;
const shot = async (tab, name) => {
  const r = await send('Page.captureScreenshot', { format: 'png' }, tab.sid);
  const f = `${OUT}/${String(++shotN).padStart(2, '0')}-${name}.png`;
  writeFileSync(f, Buffer.from(r.data, 'base64'));
  R.shots.push(f);
};
const click = async (tab, x, y) => {
  for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 }, tab.sid);
};
const typeText = (tab, text) => send('Input.insertText', { text }, tab.sid);
const navigate = (tab, url) => send('Page.navigate', { url }, tab.sid);
const appReady = (tab, ms = 90000) => waitFor(tab, `!!(window.__posDemo && __posDemo.isReady && window.PosDemoPage && PosDemoPage.boot.hidden && document.getElementById('pos-demo-fab'))`, ms, 'демо готово (ready + первый кадр + «ДЕМО»)');
const url = (q = '') => `${ORIGIN}/?storage=${STORAGE}${q}`;

// API через мост страницы (как DemoBridgeAdapter приложения): JSON → {status, json, headers}.
// Сессия = { token, device }: X-Device-Id — из сессии (токен привязан к устройству; после F5 тот же).
let lastDevice = crypto.randomUUID();
const api = (tab, method, path, { headers = {}, body, token, device } = {}) =>
  ev(
    tab,
    `(async () => {
      const h = Object.assign({ 'X-Device-Id': ${JSON.stringify(String(device ?? lastDevice))}, 'X-App-Version': ${JSON.stringify('0.1.0+1')}, 'X-Platform': 'windows', 'Accept-Language': 'ru', 'content-type': 'application/json' }, ${JSON.stringify(headers)});
      ${token ? `h.Authorization = 'Bearer ' + ${JSON.stringify(token)};` : ''}
      const r = await __posDemo.request({ method: ${JSON.stringify(method)}, url: ${JSON.stringify(`/api/v1${path}`)}, headers: h, body: ${body === undefined ? 'null' : JSON.stringify(JSON.stringify(body))} });
      const text = new TextDecoder().decode(r.body);
      let json = null; try { json = text ? JSON.parse(text) : null; } catch (e) {}
      return { status: r.status, json, headers: Object.fromEntries(r.headers) };
    })()`,
    90000,
  );

async function apiLogin(tab, phone, { pin = '715382', device = crypto.randomUUID() } = {}) {
  lastDevice = device;
  let rq = await api(tab, 'POST', '/auth/otp/request', { body: { phone, purpose: 'login_or_register', locale: 'ru' } });
  for (let i = 0; i < 3 && rq.status === 429; i++) {
    await sleep(11000);
    rq = await api(tab, 'POST', '/auth/otp/request', { body: { phone, purpose: 'login_or_register', locale: 'ru' } });
  }
  const vr = await api(tab, 'POST', '/auth/otp/verify', { body: { challengeId: rq.json?.challengeId, code: '246810', device: { name: 'smoke', platform: 'windows', appVersion: '0.1.0+1' } } });
  const token = vr.json?.accessToken; // check-secrets: allow — токен из ответа API тестового прогона, не секрет
  if (token && (vr.json?.nextStep === 'set_pin' || vr.json?.security?.pinSet === false)) await api(tab, 'POST', '/me/pin', { token, headers: { 'Idempotency-Key': crypto.randomUUID() }, body: { newPin: pin } });
  return { token, verify: vr };
}
async function sellOne(tab, token, method, { key = crypto.randomUUID(), wait = true } = {}) {
  const pl = (await api(tab, 'GET', '/catalog/products?limit=40&inStock=true&sort=price:asc', { token })).json?.items?.filter((p) => !p.hasVariants && p.defaultVariantId && p.baseUnit?.id && p.price) ?? [];
  const p = pl[Math.floor(Math.random() * Math.min(pl.length, 20))];
  let cart = (await api(tab, 'GET', '/cart', { token })).json;
  if ((cart?.items ?? []).length) cart = (await api(tab, 'DELETE', `/cart?rowVersion=${cart.rowVersion}`, { token })).json;
  cart = (await api(tab, 'PUT', `/cart/items/${p.defaultVariantId}`, { token, headers: { 'Idempotency-Key': crypto.randomUUID() }, body: { quantity: { value: '1', unitId: p.baseUnit.id, packagingId: null }, rowVersion: cart.rowVersion, mode: 'set' } })).json;
  const prev = await api(tab, 'POST', '/cart/checkout-preview', { token, headers: { 'Idempotency-Key': crypto.randomUUID() }, body: { cartId: cart.id, cartRowVersion: cart.rowVersion, paymentMethod: method, delivery: { method: 'pickup' }, receiver: { kind: 'customer' } } });
  const body = { cartId: cart.id, cartRowVersion: cart.rowVersion, ...(prev.json?.previewToken ? { previewToken: prev.json.previewToken } : {}), receiver: { kind: 'customer' }, delivery: { method: 'pickup' }, paymentMethod: method, items: [{ variantId: p.defaultVariantId, quantity: { value: '1', unitId: p.baseUnit.id, packagingId: null } }] };
  if (!wait) return { key, body };
  const o = await api(tab, 'POST', '/orders', { token, headers: { 'Idempotency-Key': key }, body });
  return { key, body, order: o };
}

// Координаты элемента семантики Flutter по тексту/aria-label (центр наименьшего видимого совпадения).
const findExpr = (text) => `(() => { const want = ${JSON.stringify(text)}; let best = null;
  for (const n of document.querySelectorAll('flt-semantics, flt-semantics *, [role], input, textarea')) {
    const label = (n.getAttribute('aria-label') || '') + ' ' + (n.textContent || '');
    if (!label.includes(want)) continue; const r = n.getBoundingClientRect(); if (r.width < 2 || r.height < 2) continue;
    const area = r.width * r.height; if (!best || area < best.area) best = { area, x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
  return best; })()`;
// Точная подпись (кнопки экранной клавиатуры «1»…«0»): aria-label или текст равен want; предпочтение — role=button.
const findExact = (text) => `(() => { const want = ${JSON.stringify(text)}; let best = null;
  for (const n of document.querySelectorAll('flt-semantics, flt-semantics *, [role]')) {
    const label = (n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').trim();
    if (label !== want) continue; const r = n.getBoundingClientRect(); if (r.width < 2 || r.height < 2) continue;
    const score = (n.getAttribute('role') === 'button' ? 0 : 1e9) + r.width * r.height;
    if (!best || score < best.score) best = { score, x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
  return best; })()`;
const semanticsOn = async (tab) => {
  await waitFor(tab, `!!document.querySelector('flt-semantics-placeholder') || document.querySelectorAll('flt-semantics').length > 3`, 20000, 'семантика Flutter');
  await ev(tab, `(document.querySelector('flt-semantics-placeholder') && document.querySelector('flt-semantics-placeholder').click(), true)`);
  await waitFor(tab, `document.querySelectorAll('flt-semantics').length > 3`, 15000, 'семантика включена');
};
const texts = (tab) => ev(tab, `[...document.querySelectorAll('flt-semantics')].map((n) => n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').map((s) => s.trim()).filter(Boolean).slice(0, 60)`);

// ================================================================ шаги
try {
  await connect();
  await sleep(600);
  // заголовки ответа сервера (как на Netlify)
  const hIndex = await fetch(`${ORIGIN}/`);
  const hWasm = await fetch(`${ORIGIN}/backend/pglite/pglite.wasm`, { method: 'HEAD' });
  const hGz = await fetch(`${ORIGIN}/demo/snapshot/data.copy.gz`, { method: 'HEAD' });
  const hApi = await fetch(`${ORIGIN}/api/v1/__smoke_probe`); // проверка правила /api/* (из Node, не из браузера)
  const hImg = await fetch(`${ORIGIN}/images/${JSON.parse(readFileSync(`${WEB}/.build/snapshot/images.json`, 'utf8'))?.files?.[0]?.sha ?? 'x'}/card`, { method: 'HEAD' }).catch(() => null);
  R.headers = { index: Object.fromEntries(hIndex.headers), wasm: hWasm.headers.get('content-type'), gz: [hGz.headers.get('content-type'), hGz.headers.get('content-encoding')], api: hApi.status, image: hImg ? [hImg.status, hImg.headers.get('content-type')] : null };
  check('заголовки как на Netlify: CSP и X-Robots-Tag на странице, .wasm — application/wasm, снимок .gz — application/gzip без Content-Encoding, /api/* → 404', /default-src 'self'/.test(R.headers.index['content-security-policy'] ?? '') && /noindex/.test(R.headers.index['x-robots-tag'] ?? '') && R.headers.wasm === 'application/wasm' && R.headers.gz[0] === 'application/gzip' && !R.headers.gz[1] && R.headers.api === 404, R.headers);

  const A = await openTab('A');
  // ------------------------------------------------------------ boot
  if (ONLY.has('boot') || ONLY.has('ui') || ONLY.has('f5') || ONLY.has('frozen')) {
    const tNav = Date.now();
    await navigate(A, url('&envcheck=0'));
    await appReady(A, 120000);
    R.boot = await ev(A, `({ ms: ${'Date.now()'} - ${tNav}, storage: __posDemo.info.storage, warm: __posDemo.info.warm, readyMs: __posDemo.info.timings && __posDemo.info.timings.readyMs, epochKey: __posDemo.info.epochKey, buildId: PosDemoPage.boot.build.buildId, title: document.title, csp: window.__cspViolations })`);
    await sleep(1500);
    await shot(A, 'boot-1280x800');
    check(`загрузка: ready + первый кадр + «ДЕМО» (хранилище ${STORAGE})`, R.boot.storage === STORAGE, R.boot);
    const sk = await ev(A, `JSON.parse(localStorage.getItem('optomstroy.demo.storageKind') || 'null')`);
    check('хранилище эпохи запомнено', sk?.storage === STORAGE && sk.epochKey === R.boot.epochKey, sk);
  }

  // ------------------------------------------------------------ ui: вход кассира 906 в интерфейсе Flutter
  let uiSignedIn = false;
  if (ONLY.has('ui')) {
    try {
      await semanticsOn(A);
      await waitFor(A, `document.body.innerHTML.includes('Получить код')`, 30000, 'SCR-01');
      const scr01 = await texts(A);
      const field = await ev(A, findExpr('Номер телефона'));
      const submit = await ev(A, findExpr('Получить код'));
      R.ui = { scr01: scr01.slice(0, 20), field, submit };
      await shot(A, 'scr01');
      // с семантикой ввод кода не работает (handoff «OtpField») — перезагрузка: семантика выключена, ввод по координатам
      await send('Page.reload', {}, A.sid);
      await appReady(A, 90000);
      await sleep(1500);
      await click(A, field.x, field.y);
      await sleep(500);
      await typeText(A, '777000906');
      await sleep(600);
      await click(A, submit.x, submit.y);
      await waitFor(A, `PosDemoPage.bridge._stats.statuses['202'] >= 1`, 15000, 'otp/request 202');
      await sleep(1500);
      await shot(A, 'scr02-otp');
      await typeText(A, '246810');
      await waitFor(A, `(PosDemoPage.bridge._stats.statuses['200'] || 0) >= 2`, 15000, 'otp/verify 200');
      await sleep(2500);
      await shot(A, 'after-verify');
      // PIN: первый вход сотрудника — «Задайте PIN-код для работы»: экранная клавиатура (кнопки «0»…«9»), дважды,
      // затем «Начать работу». Кнопки — по семантике Flutter (точная подпись).
      await semanticsOn(A);
      await waitFor(A, `document.body.innerHTML.includes('PIN')`, 15000, 'экран PIN');
      const pinDigits = async (pin) => {
        for (const d of pin) {
          const b = await ev(A, findExact(d));
          if (!b) throw new Error(`нет кнопки «${d}» на экране PIN`);
          await click(A, b.x, b.y);
          await sleep(180);
        }
      };
      await pinDigits('715382');
      await sleep(1200);
      await shot(A, 'pin-first');
      if (await ev(A, `document.body.innerHTML.includes('Повторите') || document.body.innerHTML.includes('ещё раз')`)) {
        await pinDigits('715382');
        await sleep(1200);
      }
      // согласие на обработку персональных данных (чекбокс под PIN, обязателен для «Начать работу»)
      const consent = await ev(A, findExpr('Я ознакомлен'));
      if (consent) {
        await click(A, consent.x, consent.y);
        await sleep(600);
      }
      await shot(A, 'pin-consent');
      const start = await ev(A, findExpr('Начать работу'));
      if (start) await click(A, start.x, start.y);
      await waitFor(A, `(PosDemoPage.bridge._stats.statuses['204'] || 0) >= 1`, 15000, 'POST /me/pin 204');
      await sleep(3000);
      await shot(A, 'after-pin');
      await semanticsOn(A).catch(() => undefined);
      const after = await texts(A).catch(() => []);
      R.ui.after = after.slice(0, 40);
      const pinSet = await ev(A, `(PosDemoPage.bridge._stats.statuses['204'] || 0) >= 1`);
      uiSignedIn = check('интерфейс: вход кассира 906 — номер, код 246810, PIN 715382 дважды → рабочий экран', pinSet && !after.some((t) => /Получить код|Введите код/.test(t)), { pinSet, after: after.slice(0, 12), statuses: await ev(A, `PosDemoPage.bridge._stats.statuses`) });
    } catch (e) {
      check('интерфейс: вход кассира 906 — номер, код 246810, PIN 715382 дважды → рабочий экран', false, String(e?.message ?? e));
      await shot(A, 'ui-error').catch(() => undefined);
    }
  }

  // ------------------------------------------------------------ f5: F5 посреди QR и оформления
  if (ONLY.has('f5')) {
    const { token } = await apiLogin(A, '+996777000907', { device: crypto.randomUUID() });
    await ev(A, `__posDemo.control('POST qr/config', { paidAfterPolls: 0 })`);
    // (а) QR: «Оплатить сейчас» → long-poll received → СРАЗУ F5
    const q = await sellOne(A, token, 'qr_bakai');
    const pay = q.order.json?.payments?.[0];
    await ev(A, `__posDemo.control(${JSON.stringify(`POST qr/${pay?.id}/pay`)}, {})`);
    let st = null;
    for (let i = 0; i < 20 && st !== 'received'; i++) st = (await api(A, 'GET', `/payments/${pay.id}?wait=10`, { token })).json?.status;
    const order0 = (await api(A, 'GET', `/orders/${q.order.json.id}`, { token })).json;
    const hashBefore = await ev(A, 'location.hash');
    await send('Page.reload', {}, A.sid); // F5 сразу после «Оплачено»
    await appReady(A, 90000);
    if (uiSignedIn) {
      // Интерфейс после F5 (G-5): SCR-08 `cold` с возвратом на прежний экран, а не рабочий экран под невидимой блокировкой.
      const unlock = await waitFor(A, `location.hash.indexOf('#/auth/unlock') === 0 ? location.hash : null`, 20000, 'SCR-08 после F5').catch(() => null);
      const from = unlock ? new URLSearchParams(unlock.slice(unlock.indexOf('?') + 1)).get('from') : null;
      check('F5 на рабочем экране (вход в интерфейсе): SCR-08 `cold` «Введите PIN-код» с возвратом на прежний адрес', !!unlock && /mode=cold/.test(unlock) && !!from && hashBefore.slice(1).startsWith(from.split('?')[0]), { hashBefore, unlock });
      await shot(A, 'f5-unlock');
    }
    const st2 = (await api(A, 'GET', `/payments/${pay.id}`, { token })).json?.status;
    let o2 = (await api(A, 'GET', `/orders/${q.order.json.id}`, { token })).json;
    for (let i = 0; i < 30 && !o2?.onec?.number; i++) {
      await sleep(500);
      o2 = (await api(A, 'GET', `/orders/${q.order.json.id}`, { token })).json;
    }
    check('F5 сразу после «Оплачено» (QR): после перезагрузки платёж received, заказ на месте с номером «1С»', st === 'received' && st2 === 'received' && !!o2?.onec?.number, { before: st, after: st2, onecBefore: order0?.onec?.number ?? null, onecAfter: o2?.onec?.number ?? null });
    // (б) POST /orders и F5, не дожидаясь ответа → повтор тем же ключом
    const countOrders = async () => (await ev(A, `__posDemo.control('GET state')`)).orders.length;
    const s = await sellOne(A, token, 'cash', { wait: false });
    await ev(A, `(window.__inflight = __posDemo.request({ method: 'POST', url: '/api/v1/orders', headers: { 'X-Device-Id': ${JSON.stringify(lastDevice)}, 'X-App-Version': '0.1.0+1', 'X-Platform': 'windows', 'content-type': 'application/json', 'Idempotency-Key': ${JSON.stringify(s.key)}, Authorization: 'Bearer ${token}' }, body: ${JSON.stringify(JSON.stringify(s.body))} }).catch(function () {}), true)`);
    await sleep(Math.floor(Math.random() * 120));
    await send('Page.reload', {}, A.sid); // F5 посреди оформления
    await appReady(A, 90000);
    const again = await api(A, 'POST', '/orders', { token, headers: { 'Idempotency-Key': s.key }, body: s.body });
    const byKey = (await api(A, 'GET', `/orders?idempotencyKey=${encodeURIComponent(s.key)}&limit=10`, { token })).json;
    const n1 = (byKey?.items ?? byKey?.data ?? []).length;
    check('F5 посреди POST /orders: повтор тем же Idempotency-Key после перезагрузки → ровно один заказ с этим ключом', [200, 201].includes(again.status) && n1 === 1, { status: again.status, replayed: again.headers['idempotent-replayed'] ?? null, ordersWithKey: n1, state: await countOrders().catch(() => null) });
    await shot(A, 'after-f5');
  }

  // ------------------------------------------------------------ frozen: замороженная вкладка
  if (ONLY.has('frozen')) {
    const { token } = await apiLogin(A, '+996777000901', { device: crypto.randomUUID() });
    const genA = await ev(A, `PosDemoPage.lock.generation`);
    await send('Page.setWebLifecycleState', { state: 'frozen' }, A.sid);
    const B = await openTab('B');
    await navigate(B, url('&envcheck=0'));
    await waitFor(B, `(document.getElementById('loading')||{dataset:{}}).dataset.view === 'lock' && !!document.getElementById('pd-lock-takeover')`, 30000, 'плашка «Демо уже открыто»');
    await shot(B, 'frozen-B-lock');
    await ev(B, `document.getElementById('pd-lock-takeover').click(), true`);
    // IndexedDB: B забирает том и работает; OPFS: дескрипторы файлов держит замороженная вкладка → «данные заняты»
    const outcome = await waitFor(B, `(window.__posDemo && __posDemo.isReady && PosDemoPage.boot.hidden) ? 'ready' : (__posDemo && __posDemo.fatal && __posDemo.fatal.code) || null`, 60000, 'B: ready или fatal').catch(async (e) => {
      R.frozenDebug = await ev(B, `({ phase: __posDemo.phase, steps: PosDemoPage.boot.steps.slice(-12), lock: PosDemoPage.lock.log.slice(-10), view: (document.getElementById('loading')||{dataset:{}}).dataset.view, stage: (document.getElementById('pd-stage')||{}).textContent })`).catch((x) => String(x));
      await shot(B, 'frozen-B-stuck').catch(() => undefined);
      throw new Error(`${e.message}; B: ${JSON.stringify(R.frozenDebug).slice(0, 1500)}`);
    });
    await shot(B, `frozen-B-${outcome}`);
    const lockB = await ev(B, `({ result: PosDemoPage.boot.lockResult, gen: PosDemoPage.lock.generation })`);
    check('замороженная вкладка: «Продолжить здесь» во второй — steal через 3 с, новое поколение', lockB.result?.stolen === true && lockB.gen > genA, lockB);
    let orderB = null;
    if (outcome === 'ready') {
      const { token: tb } = await apiLogin(B, '+996777000906', { device: crypto.randomUUID() });
      orderB = (await sellOne(B, tb, 'cash')).order.json;
      check('B (IndexedDB): работает поверх замороженной A — заказ оформлен', !!orderB?.id, { number: orderB?.publicNumber });
    } else {
      const text = await ev(B, `(document.getElementById('loading')||document.body).innerText`);
      check('B (OPFS): дескрипторы держит замороженная A — понятное сообщение «Данные демо заняты другой вкладкой», без «Сбросить демо» первым', outcome === 'storage_busy' && /заняты другой вкладкой/.test(text), { outcome, text: text.slice(0, 200) });
    }
    // разморозка A → она уходит на demo-closed и не пишет
    R.unfrozenAt = Date.now();
    R.frozenTab = A.targetId;
    await send('Page.setWebLifecycleState', { state: 'active' }, A.sid);
    const aGone = await waitFor(A, `/demo-closed\\.html/.test(location.href) ? location.href : null`, 30000, 'A ушла на demo-closed').catch(() => null);
    await shot(A, 'frozen-A-after-unfreeze');
    // reason: stolen/generation; «moved» — если localStorage замороженной вкладки ещё не получил новое поколение
    // (storage-событие приходит после 'release'); запись тома в любом случае отклоняет fence воркера (проверка ниже).
    check('A после разморозки ушла на demo-closed.html', !!aGone && /reason=(stolen|generation|moved)/.test(aGone), aGone);
    void token;
    if (outcome !== 'ready') {
      // A отпустила дескрипторы — «Обновить страницу» в B
      await navigate(B, url('&envcheck=0'));
      await appReady(B, 90000);
      const { token: tb } = await apiLogin(B, '+996777000906', { device: crypto.randomUUID() });
      orderB = (await sellOne(B, tb, 'cash')).order.json;
    }
    await navigate(B, url('&envcheck=0'));
    await appReady(B, 90000);
    const st = await ev(B, `__posDemo.control('GET state')`);
    check('после перезагрузки B заказ B на месте, том цел (A не перезаписала его)', !!orderB && st.orders.some((o) => o.id === orderB.id), { orderB: orderB?.publicNumber, orders: st.orders.length, storage: st.storage });
    await shot(B, 'frozen-B-final');
  }

  // ------------------------------------------------------------ общие проверки
  const csp = [];
  for (const [sid, s] of sessions) if (s.type === 'page') csp.push(...((await ev({ sid }, `window.__cspViolations || []`, 5000).catch(() => [])) ?? []));
  R.cspPage = csp;
  const log0 = await (await fetch(`${ORIGIN}/__site/log`)).json();
  const fromBrowser = log0.filter((r) => r.p !== '/api/v1/__smoke_probe');
  R.server = { requests: fromBrowser.length, api: fromBrowser.filter((r) => /^\/api\//.test(r.p)).length, notFound: [...new Set(fromBrowser.filter((r) => r.s === 404).map((r) => r.p))].slice(0, 20) };
  check('0 нарушений Content-Security-Policy (страница, воркеры)', csp.length === 0 && R.csp.length === 0, { page: csp.slice(0, 5), log: R.csp.slice(0, 5) });
  check('0 запросов на чужие хосты; 0 запросов к /api/ сайта; 0 ответов 404', R.foreign.length === 0 && R.server.api === 0 && R.server.notFound.length === 0, { foreign: R.foreign.slice(0, 5), server: R.server });
  const exc = R.exceptions.filter((e) => !/frozen|Демо перенесено|fenced/i.test(e.text));
  check('0 необработанных исключений', exc.length === 0, exc.slice(0, 5));
  // Сторож единиц работы в воркере замороженной вкладки A после разморозки: таймеры отработали с опозданием на время
  // заморозки (ожидание «15 с» — это время заморозки, а не работы); вкладка в этот момент уходит на demo-closed.
  const errs = R.consoleErrors.filter((e) => !/dio_web_adapter|storage_busy|Данные демо заняты|PosDemoBridgeError/.test(e.text) && !(R.unfrozenAt && e.t >= R.unfrozenAt && e.tab === R.frozenTab && /сторож|watchdog/.test(e.text)));
  check('0 ошибок в консоли (кроме известных)', errs.length === 0, errs.slice(0, 8));
} catch (e) {
  R.error = String(e?.stack ?? e);
  console.error(R.error);
  check('прогон без исключения', false, R.error.slice(0, 800));
} finally {
  try {
    ws?.close();
  } catch {
    /* ignore */
  }
  killTree(chrome.pid);
  killTree(server.pid);
  await sleep(1500);
  if (!argv.includes('--keep-profile')) rmSync(PROFILE, { recursive: true, force: true, maxRetries: 5, retryDelay: 400 });
  R.finishedAt = new Date().toISOString();
  R.summary = { checks: R.checks.length, failed: R.checks.filter((c) => !c.ok).length };
  writeFileSync(`${OUT}/smoke.json`, JSON.stringify(R, null, 1));
  log(`итог: ${R.summary.checks - R.summary.failed}/${R.summary.checks}; ${OUT}/smoke.json; профиль ${existsSync(PROFILE) ? 'НЕ удалён' : 'удалён'}`);
  process.exit(R.summary.failed ? 1 : 0);
}

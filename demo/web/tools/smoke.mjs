// Headless-проверка СОБРАННОГО сайта веб-демо (review fixes: часть WP-T2; critic [5], [16], [19], [21]; шаги kiosk и
// kioskswitch — «Планшет магазина», P-002 TAB-3-01 и TAB-3-02).
// Настоящая страница, настоящее приложение Flutter (main.dart.js), настоящий backend.js на PGlite — через
// tools/serve-site.mjs с заголовками и перенаправлениями Netlify; Chrome --headless=new, CDP на глобальном WebSocket
// Node 24 (без puppeteer). Порт статики 8095–8099 (первый свободный), CDP — первый свободный от 9491.
//
//   node demo/web/tools/smoke.mjs [--storage opfs|idb] [--only boot,ui,f5,frozen,kiosk,kioskswitch] [--out <каталог>] [--keep-profile] [--port 8095–8099] [--cdp <порт>]
//                                 [--url <https-адрес>] [--browser chrome|edge]
//
// --url — удалённый режим (превью или основной адрес Netlify, например https://<id>--optomstroy-demo-4fhvb.netlify.app):
//   свой сервер не запускается (--port не нужен), браузер открывает этот адрес. Заголовки — запросами Node к адресу;
//   журнал запросов (к /api/, 404, чужие хосты) — из событий CDP Network страниц и воркеров (requestWillBeSent /
//   responseReceived / loadingFailed) вместо журнала serve-site. Браузер резолвит только хост адреса
//   (--host-resolver-rules): попытка запроса на чужой хост видна в журнале, но наружу не уходит. Шаги те же.
// --browser — chrome (по умолчанию, C:/Program Files/Google/Chrome) или edge (C:/Program Files (x86)/Microsoft/Edge);
//   у edge имена резолвятся только для адреса --url (локально — никакие: 127.0.0.1 — адрес, не имя).
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
//            A после разморозки уходит на demo-closed.html и НЕ пишет (заказ B на месте после перезагрузки B);
//   kiosk  — планшет магазина (P-002 TAB-3-01, ADR-115; по умолчанию не входит, вне релизных ворот — 12 §3.23):
//            «ДЕМО» → «Планшет магазина» (шаги) → вход администратора 901 в НАСТОЯЩЕМ интерфейсе → SCR-54 «Сделать это
//            устройство планшетом магазина» (имя, склад, PIN) → аварийный код → SCR-51 → товар → корзина → «Оформить
//            заявку» → номер и код 246810 экранной клавиатурой → SCR-53; кассир 906 видит заявку createdVia=kiosk,
//            документ «1С» демо создан, в панели «С планшета» (T-KIOSK-034, T-KIOSK-043); адресная строка #/auth/phone,
//            #/orders, «назад» и загрузка страницы с #/auth/phone → планшет на /kiosk (T-KIOSK-045). Идёт после прежних
//            шагов: после него браузер — планшет. Своя вкладка K: прежние вкладки шага закрываются (замок и дескрипторы OPFS);
//   kioskswitch — «планшет магазина ↔ обычный вход» (P-002 TAB-3-02; T-KIOSK-051; по умолчанию не входит, нужен шаг kiosk,
//            идёт последним): «Вернуться к обычному входу» → кассир 906 видит заявку → «Планшет магазина» — тот же
//            store_tablets.id без подключения заново, корзина пуста → снова обычный вход — кассир без кода; негодные
//            отложенные данные → «Подключить этот браузер заново» → SCR-54 «Подключить заново этот планшет» — тот же id;
//            «Сбросить демо» → только первое подключение (новый id). device.id и ключ AES не переносятся и не меняются.
// Итог — <out>/smoke.json и снимки <out>/NN-*.png. Свои сервер и браузер — по PID, профиль удаляется.
// В удалённом режиме по умолчанию <out> = .tmp/web_demo/smoke/remote-[edge-]<storage>-<время>.
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
// удалённый режим: origin без пути и без «/» в конце
const REMOTE = argv.includes('--url') ? String(arg('--url', '')).replace(/\/+$/, '') : null;
if (REMOTE !== null && !/^https?:\/\/[^/?#\s]+$/.test(REMOTE)) throw new Error(`--url: нужен адрес вида https://<хост> без пути, получено «${REMOTE}»`);
const BROWSERS = { chrome: 'C:/Program Files/Google/Chrome/Application/chrome.exe', edge: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' };
const BROWSER = arg('--browser', 'chrome');
if (!BROWSERS[BROWSER]) throw new Error(`--browser: chrome или edge, получено «${BROWSER}»`);
const OUT = resolve(arg('--out', `${ROOT}/.tmp/web_demo/smoke/${REMOTE ? 'remote-' : ''}${BROWSER === 'chrome' ? '' : `${BROWSER}-`}${STORAGE}-${new Date().toISOString().replace(/[:.]/g, '-')}`)).replace(/\\/g, '/');
const CHROME = BROWSERS[BROWSER];
const PROFILE = `${ROOT}/.tmp/web_demo/${BROWSER}-smoke-${STORAGE}-${Date.now()}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const log = (...a) => console.log(`${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s`, ...a);
mkdirSync(OUT, { recursive: true });
process.env.TEMP ||= `${ROOT}/.tmp`;

const R = { storage: STORAGE, mode: REMOTE ? 'remote' : 'local', browser: BROWSER, startedAt: new Date().toISOString(), checks: [], exceptions: [], consoleErrors: [], csp: [], foreign: [], failedLoads: [], pids: {}, shots: [], steps: [] };
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
// Удалённый режим (--url): свой сервер не нужен, порт статики не занимается.
let port = null;
if (!REMOTE) {
  for (const p of argv.includes('--port') ? [Number(arg('--port'))] : [8095, 8096, 8097, 8098, 8099]) if (await portFree(p)) {
    port = p;
    break;
  }
  if (!port) throw new Error(`нет свободного порта ${argv.includes('--port') ? arg('--port') : '8095–8099'}`);
}
let cdpPort = null;
for (let p = Number(arg('--cdp', 9491)); p < (argv.includes('--cdp') ? Number(arg('--cdp')) + 1 : 9520); p++) if (await portFree(p)) {
  cdpPort = p;
  break;
}
if (!cdpPort) throw new Error(`нет свободного порта CDP ${arg('--cdp', '9491–9519')}`);
const ORIGIN = REMOTE ?? `http://127.0.0.1:${port}`;
R.origin = ORIGIN;
// запрос того же origin (а не «https://хост.чужой» с тем же началом)
const onOrigin = (u) => u.startsWith(ORIGIN) && (u.length === ORIGIN.length || /^[/?#]/.test(u[ORIGIN.length]));
const server = REMOTE ? null : spawn(process.execPath, [`${HERE}/serve-site.mjs`, '--port', String(port), '--quiet'], { stdio: ['ignore', 'pipe', 'pipe'] });
R.pids.server = server ? server.pid : null;
mkdirSync(PROFILE, { recursive: true });
// Удалённый режим и edge: имена резолвятся только для хоста --url — служебные запросы браузера (обновления, телеметрия,
// SmartScreen) и чужие хосты страницы наружу не уходят; запросы страницы всё равно видны в журнале CDP (foreign).
const resolverRules = REMOTE ? `MAP * ~NOTFOUND, EXCLUDE ${new URL(REMOTE).hostname}` : BROWSER === 'edge' ? 'MAP * ~NOTFOUND' : null;
const chrome = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${cdpPort}`, `--user-data-dir=${PROFILE}`, '--window-size=1280,800', '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-default-apps', '--lang=ru', ...(resolverRules ? [`--host-resolver-rules=${resolverRules}`] : []), 'about:blank'], { stdio: 'ignore' });
R.pids.browser = chrome.pid;
// Удалённый режим: журнал запросов страниц и воркеров к ORIGIN из CDP Network (вместо журнала serve-site /__site/log):
// { p: путь, m: метод, s: статус (последний; у перенаправления — его статус, затем новый адрес), err: ошибка загрузки }.
const netLog = [];
const netById = new Map();
const netRequest = (p, s) => {
  const prev = netById.get(p.requestId);
  if (prev && p.redirectResponse) prev.s = p.redirectResponse.status;
  else if (prev) return; // тот же запрос в другой сессии CDP
  netById.delete(p.requestId);
  if (!onOrigin(p.request.url)) return;
  const r = { p: new URL(p.request.url).pathname, m: p.request.method, s: null, type: s?.type };
  netLog.push(r);
  netById.set(p.requestId, r);
};
const netResponse = (p) => {
  const r = netById.get(p.requestId);
  if (r) r.s = p.response.status;
};
const netFailed = (p) => {
  const r = netById.get(p.requestId);
  if (r && !p.canceled) r.err = p.errorText;
};

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
      if (!onOrigin(u) && !/^(data|blob|chrome|about|devtools|chrome-extension):/.test(u)) R.foreign.push({ tab: s?.tab, type: s?.type, url: u.slice(0, 160) });
      if (REMOTE) netRequest(m.params, s);
    } else if (m.method === 'Network.responseReceived') {
      if (REMOTE) netResponse(m.params);
    } else if (m.method === 'Network.loadingFailed') {
      if (!m.params.canceled) R.failedLoads.push({ type: s?.type, error: m.params.errorText });
      if (REMOTE) netFailed(m.params);
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

// Помощники UI-шагов на вкладке tab (шаги kiosk и kioskswitch). Текст — только по дереву семантики Flutter: подписи
// панели «ДЕМО» (раздел «Планшет магазина» называет те же кнопки) в document.body есть всегда, поэтому
// document.body.innerHTML здесь не годится. rec.stage — этап шага для отчёта.
function uiKit(tab, rec, name) {
  const stage = (s) => {
    rec.stage = s;
    log(`${name}: ${s}`);
  };
  const statuses = () => ev(tab, `Object.assign({}, PosDemoPage.bridge._stats.statuses)`);
  const count = async (code) => Number((await statuses())[String(code)] || 0);
  const allTexts = () => ev(tab, `[...document.querySelectorAll('flt-semantics')].map((n) => n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').map((s) => s.trim()).filter(Boolean)`);
  const semExpr = (text) => `[...document.querySelectorAll('flt-semantics, flt-semantics input, flt-semantics textarea')].some((n) => ((n.getAttribute('aria-label') || '') + ' ' + (n.getAttribute('placeholder') || '') + ' ' + n.textContent).includes(${JSON.stringify(text)}))`;
  const has = (text) => ev(tab, semExpr(text));
  const waitText = (text, ms, label) => waitFor(tab, semExpr(text), ms, label ?? `«${text}»`);
  // Первая (сверху слева) карточка витрины в пределах окна, товар в наличии: узел семантики карточки содержит
  // «В наличии» и «+ Добавить»; нажатие — в верхнюю четверть (фото), не на кнопку.
  const firstCardInView = () => `(() => { const out = [];
    for (const n of document.querySelectorAll('flt-semantics')) {
      const l = (n.getAttribute('aria-label') || '') + ' ' + n.textContent;
      if (!l.includes('+ Добавить') || !l.includes('В наличии') || l.includes('Нет в наличии')) continue;
      const r = n.getBoundingClientRect();
      if (r.width < 120 || r.height < 150 || r.width > 400 || r.top < 0 || r.left < 0 || r.bottom > innerHeight || r.right > innerWidth) continue;
      out.push({ x: r.left + r.width / 2, y: r.top + r.height / 4 }); }
    out.sort((a, b) => a.y - b.y || a.x - b.x); return out[0] || null; })()`;
  const clickFound = async (expr, label) => {
    const b = await ev(tab, expr);
    if (!b) throw new Error(`нет элемента ${label} на экране; видно: ${JSON.stringify((await allTexts()).slice(0, 40))}`);
    await click(tab, b.x, b.y);
    return b;
  };
  const clickText = (text) => clickFound(findExpr(text), `«${text}»`);
  const clickExact = (text) => clickFound(findExact(text), `«${text}» (точно)`);
  const digits = async (seq) => {
    for (const d of seq) {
      await clickExact(d);
      await sleep(160);
    }
  };
  const hash = () => ev(tab, 'location.hash');
  const waitHash = (prefix, ms, label) => waitFor(tab, `location.hash.indexOf(${JSON.stringify(`#${prefix}`)}) === 0 ? location.hash : null`, ms, label ?? `адрес #${prefix}`);
  const panelOpen = async (id) => {
    if (!(await ev(tab, 'PosDemoPage.panel.isOpen'))) await ev(tab, `document.getElementById('pos-demo-fab').click(), true`);
    await waitFor(tab, 'PosDemoPage.panel.isOpen', 5000, 'панель «ДЕМО» открыта');
    await ev(tab, `(function () { var d = document.getElementById('pd-sec-${id}'); if (!d.open) d.querySelector('summary').click(); d.scrollIntoView({ block: 'start' }); return true; })()`);
    await waitFor(tab, `document.getElementById('pd-sec-${id}').open`, 3000, `раздел ${id} открыт`);
  };
  const panelClose = () => ev(tab, `PosDemoPage.panel.isOpen && document.getElementById('pd-close').click(), true`);
  return { tab, stage, statuses, count, allTexts, semExpr, has, waitText, firstCardInView, clickFound, clickText, clickExact, digits, hash, waitHash, panelOpen, panelClose };
}

// Вход сотрудника в НАСТОЯЩЕМ интерфейсе (как шаг ui): SCR-08 «Сменить аккаунт» → SCR-01 (координаты — по семантике),
// перезагрузка (ввод кода с включённой семантикой не работает — handoff «OtpField»), номер phone9 → «Получить код» →
// 246810 → первый PIN 715382 дважды с согласием (если PIN ещё не задан) → рабочий экран («Меню разделов»).
async function staffLogin(x, phone9) {
  const tab = x.tab;
  await semanticsOn(tab);
  await waitFor(tab, `${x.semExpr('Получить код')} || ${x.semExpr('Сменить аккаунт')}`, 30000, 'SCR-01 или SCR-08');
  const switchedAccount = await x.has('Сменить аккаунт');
  if (switchedAccount) {
    // в браузере есть сессия прежнего сотрудника: SCR-08 «Сменить аккаунт» → «Сменить» → SCR-01
    await x.clickText('Сменить аккаунт');
    await waitFor(tab, `!!(${findExact('Сменить')})`, 10000, 'подтверждение «Сменить»');
    await sleep(400);
    await x.clickExact('Сменить');
    await x.waitText('Получить код', 30000, 'SCR-01 после «Сменить аккаунт»');
  }
  await sleep(800);
  const field = await ev(tab, findExpr('Номер телефона'));
  const submit = await ev(tab, findExpr('Получить код'));
  if (!field || !submit) throw new Error(`SCR-01: нет поля номера или «Получить код»: ${JSON.stringify(await x.allTexts())}`);
  await send('Page.reload', {}, tab.sid);
  await appReady(tab, 90000);
  await sleep(1500);
  await click(tab, field.x, field.y);
  await sleep(500);
  await typeText(tab, phone9);
  await sleep(600);
  await click(tab, submit.x, submit.y);
  await waitFor(tab, `(PosDemoPage.bridge._stats.statuses['202'] || 0) >= 1`, 15000, 'otp/request 202');
  await sleep(1500);
  await typeText(tab, '246810');
  await waitFor(tab, `(PosDemoPage.bridge._stats.statuses['200'] || 0) >= 2`, 15000, 'otp/verify 200');
  await sleep(2500);
  await semanticsOn(tab);
  // первый вход — «Задайте PIN-код для работы» (дважды, согласие, «Начать работу»); PIN уже задан — сразу рабочий экран
  const firstPin = await waitFor(tab, `${x.semExpr('Задайте PIN-код для работы')} ? 'pin' : (${x.semExpr('Меню разделов')} ? 'home' : null)`, 30000, 'SCR-04 или рабочий экран');
  if (firstPin === 'pin') {
    x.stage(`первый PIN ${phone9.slice(-3)}`);
    await x.digits('715382');
    await sleep(1200);
    if (await ev(tab, `${x.semExpr('Повторите')} || ${x.semExpr('ещё раз')}`)) {
      await x.digits('715382');
      await sleep(1200);
    }
    const consent = await ev(tab, findExpr('Я ознакомлен'));
    if (consent) {
      await click(tab, consent.x, consent.y);
      await sleep(600);
    }
    await x.clickText('Начать работу');
    await waitFor(tab, `(PosDemoPage.bridge._stats.statuses['204'] || 0) >= 1`, 15000, 'POST /me/pin 204');
    await sleep(2500);
  }
  await x.waitText('Меню разделов', 30000, 'рабочий экран сотрудника');
  return { switchedAccount, firstPin: firstPin === 'pin', home: await x.hash() };
}

// Меню разделов → «Администратор» (SCR-45 «Пользователи») → меню разделов админа «Ещё» → «Планшеты магазина» (SCR-54).
async function openTablets(x) {
  await x.clickText('Меню разделов');
  await waitFor(x.tab, `!!(${findExact('Администратор')})`, 10000, 'меню разделов: «Администратор»');
  await sleep(500);
  await x.clickExact('Администратор');
  await x.waitHash('/admin/users', 20000, 'SCR-45 «Пользователи»');
  await sleep(1200);
  await x.clickExact('Ещё');
  await x.waitText('Планшеты магазина', 10000, 'меню разделов админа: «Планшеты магазина»');
  await sleep(400);
  await x.clickExact('Планшеты магазина');
  await x.waitHash('/admin/tablets', 20000, 'SCR-54 «Планшеты магазина»');
}

// Аварийный код выхода показан (8 цифр группами по 4 — в журнал смоука не пишется, только факт показа).
async function exitCodeShown(x) {
  await x.waitText('Аварийный код выхода', 20000, 'аварийный код выхода');
  await sleep(800);
  return ev(x.tab, `[...document.querySelectorAll('flt-semantics')].some((n) => /Аварийный код выхода: \\d{4} \\d{4}/.test(((n.getAttribute('aria-label') || '') + ' ' + n.textContent).replace(/\\s+/g, ' ')))`);
}

// SCR-54 «Сделать это устройство планшетом магазина» → имя «Планшет у входа», склад по умолчанию → кнопка формы (та же
// подпись; модальный барьер прячет экран из семантики) → 403 STEP_UP_REQUIRED → PIN администратора → 201 → аварийный
// код показан. Снимки — <prefix>-enroll-form, -stepup, -exit-code.
async function enrollThisDevice(x, prefix) {
  const tab = x.tab;
  await x.clickText('Сделать это устройство планшетом магазина');
  await x.waitText('Имя планшета', 15000, 'форма подключения: «Имя планшета»');
  await sleep(800);
  await x.clickText('Имя планшета');
  await sleep(500);
  await typeText(tab, 'Планшет у входа');
  await sleep(800);
  await shot(tab, `${prefix}-enroll-form`);
  const before403 = await x.count(403);
  await x.clickText('Сделать это устройство планшетом магазина');
  await waitFor(tab, `(PosDemoPage.bridge._stats.statuses['403'] || 0) > ${before403}`, 20000, 'POST /admin/store-tablets → 403 STEP_UP_REQUIRED');
  await x.waitText('PIN', 15000, 'step-up: PIN');
  await sleep(800);
  await shot(tab, `${prefix}-stepup`);
  const before201 = await x.count(201);
  await x.digits('715382');
  await waitFor(tab, `(PosDemoPage.bridge._stats.statuses['201'] || 0) > ${before201}`, 30000, 'POST /admin/store-tablets → 201');
  const shown = await exitCodeShown(x);
  await shot(tab, `${prefix}-exit-code`);
  return shown;
}

// SCR-54 «Подключить заново этот планшет» (UI-54-003) → выбор записи «Выберите планшет для подключения заново» (признака
// планшета в браузере нет — записи по умолчанию нет) → кнопка диалога (та же подпись) → 403 STEP_UP_REQUIRED → PIN →
// POST /admin/store-tablets/{id}/reconnect → аварийный код показан. Снимки — <prefix>-reconnect-pick, -exit-code.
async function reconnectThisDevice(x, tabletName, prefix) {
  const tab = x.tab;
  await x.clickText('Подключить заново этот планшет');
  await x.waitText('Выберите планшет для подключения заново', 15000, 'выбор планшета для подключения заново');
  await sleep(800);
  await x.clickText(tabletName);
  await sleep(600);
  await shot(tab, `${prefix}-reconnect-pick`);
  const before403 = await x.count(403);
  await x.clickText('Подключить заново этот планшет');
  await waitFor(tab, `(PosDemoPage.bridge._stats.statuses['403'] || 0) > ${before403}`, 20000, 'POST …/reconnect → 403 STEP_UP_REQUIRED');
  await x.waitText('PIN', 15000, 'step-up: PIN');
  await sleep(800);
  await x.digits('715382');
  const shown = await exitCodeShown(x);
  await shot(tab, `${prefix}-exit-code`);
  return shown;
}

// ================================================================ шаги
try {
  await connect();
  await sleep(600);
  // заголовки ответа сервера (как на Netlify); в удалённом режиме — те же запросы Node к адресу --url
  const hIndex = await fetch(`${ORIGIN}/`);
  const hWasm = await fetch(`${ORIGIN}/backend/pglite/pglite.wasm`, { method: 'HEAD' });
  const hGz = await fetch(`${ORIGIN}/demo/snapshot/data.copy.gz`, { method: 'HEAD' });
  const hApi = await fetch(`${ORIGIN}/api/v1/__smoke_probe`); // проверка правила /api/* (из Node, не из браузера)
  const hImg = await fetch(`${ORIGIN}/images/${JSON.parse(readFileSync(`${WEB}/.build/snapshot/images.json`, 'utf8'))?.files?.[0]?.sha ?? 'x'}/card`, { method: 'HEAD' }).catch(() => null);
  R.headers = { index: Object.fromEntries(hIndex.headers), wasm: hWasm.headers.get('content-type'), gz: [hGz.headers.get('content-type'), hGz.headers.get('content-encoding')], api: hApi.status, image: hImg ? [hImg.status, hImg.headers.get('content-type')] : null };
  if (REMOTE) {
    // для сведения (README «Как проверить превью»): сжатие больших файлов на CDN — в итог не входит
    R.headers.encoding = {};
    for (const p of ['/main.dart.js', '/backend/backend.js', '/backend/pglite/pglite.wasm', '/backend/pglite/pglite.data', '/canvaskit/canvaskit.wasm']) {
      const h = await fetch(`${ORIGIN}${p}`, { method: 'HEAD', headers: { 'accept-encoding': 'br, gzip' } }).catch((e) => ({ status: String(e?.message ?? e), headers: new Headers() }));
      R.headers.encoding[p] = [h.status, h.headers.get('content-type'), h.headers.get('content-encoding')];
    }
  }
  check('заголовки как на Netlify: CSP и X-Robots-Tag на странице, .wasm — application/wasm, снимок .gz — application/gzip без Content-Encoding, /api/* → 404', /default-src 'self'/.test(R.headers.index['content-security-policy'] ?? '') && /noindex/.test(R.headers.index['x-robots-tag'] ?? '') && R.headers.wasm === 'application/wasm' && R.headers.gz[0] === 'application/gzip' && !R.headers.gz[1] && R.headers.api === 404, R.headers);

  const A = await openTab('A');
  // Вкладка, в которой работает демо к началу шага kiosk: A, а после шага frozen — B (A ушла на demo-closed.html).
  let cur = A;
  // Вкладка шагов kiosk и kioskswitch (после шага kiosk браузер — планшет магазина).
  let K = null;
  // ------------------------------------------------------------ boot
  if (ONLY.has('boot') || ONLY.has('ui') || ONLY.has('f5') || ONLY.has('frozen') || ONLY.has('kiosk') || ONLY.has('kioskswitch')) {
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
    cur = B;
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

  // ------------------------------------------------------------ kiosk: планшет магазина через настоящий интерфейс
  // P-002 TAB-3-01, ADR-115; 12 §3.23 (вне релизных ворот). T-KIOSK-034: «ДЕМО» → «Планшет магазина» (шаги) → вход
  // администратором 901 в интерфейсе (номер, код 246810, PIN) → меню разделов → «Администратор» → меню разделов админа →
  // SCR-54 «Планшеты магазина» → «Сделать это устройство планшетом магазина» (имя, склад по умолчанию, PIN) → аварийный
  // код → «Готово» → SCR-51 → «+ Добавить» → корзина → «Оформить заявку» → номер на экранной клавиатуре → «Получить код»
  // → 246810 → «Отправить заявку» → SCR-53 с номером заявки; кассир 906 (через мост, как приложение) видит её в
  // GET /orders?createdVia=kiosk. T-KIOSK-043: документ «1С» демо создан (номер «1С»), в панели — «С планшета».
  // T-KIOSK-045: адресная строка `#/auth/phone` без перезагрузки, с перезагрузкой и «назад» браузера → планшет на `/kiosk`.
  if (ONLY.has('kiosk')) {
    // Своя вкладка: прежние (A, после frozen — и B) закрываются — замок вкладки и дескрипторы OPFS отпускаются, а
    // вкладка B после «Продолжить здесь» на OPFS бывает неустойчива (WEB-KI-24, WEB-KI-25). Хранилище браузера общее:
    // приложение в новой вкладке видит прежнюю сессию (после шага ui — SCR-08 кассира).
    K = await openTab('K');
    for (const t of new Set([A, cur])) await send('Target.closeTarget', { targetId: t.targetId }).catch(() => undefined);
    await sleep(1500);
    R.kiosk = { tab: K.name, closed: [...new Set([A, cur])].map((t) => t.name) };
    const kx = uiKit(K, R.kiosk, 'kiosk');
    const { stage, count, allTexts, has, waitText, firstCardInView, clickFound, clickText, clickExact, digits, hash, waitHash, panelOpen, panelClose } = kx;
    try {
      stage('загрузка');
      await navigate(K, url('&envcheck=0'));
      await appReady(K, 120000);
      await sleep(1500);

      // ---- (1) панель: раздел «Планшет магазина» с шагами — между «Как войти» и «Оплата QR»
      stage('панель «Планшет магазина»');
      await panelOpen('kiosk');
      const panel = await ev(K, `({ steps: document.querySelectorAll('#pd-kiosk-steps > li').length, text: document.getElementById('pd-sec-kiosk').innerText, order: [...document.querySelectorAll('#pos-demo-panel .pd-section')].map((d) => d.id), mode: document.getElementById('pd-kiosk-mode').textContent })`);
      await shot(K, 'kiosk-panel');
      check(
        'T-KIOSK-034 «ДЕМО» → «Планшет магазина»: шаги подключения (вход администратором +996 777 000 901, код 246810, PIN, «Планшеты магазина», «Сделать это устройство планшетом магазина»); раздел между «Как войти» и «Оплата QR»',
        panel.steps === 6 && /\+996 777 000 901/.test(panel.text) && /246810/.test(panel.text) && /Планшеты магазина/.test(panel.text) && /Сделать это устройство планшетом магазина/.test(panel.text) && panel.order.indexOf('pd-sec-kiosk') === panel.order.indexOf('pd-sec-login') + 1 && panel.order.indexOf('pd-sec-qr') === panel.order.indexOf('pd-sec-kiosk') + 1 && /обычный вход/.test(panel.mode),
        { steps: panel.steps, order: panel.order, mode: panel.mode },
      );
      await panelClose();

      // ---- (2) вход администратором 901 в интерфейсе (как шаг ui: координаты — по семантике, ввод — без неё); после
      // прежних шагов в браузере сессия кассира — SCR-08 «Сменить аккаунт»; первый вход — PIN 715382 дважды (шаг frozen
      // задаёт его через API — тогда сразу рабочий экран)
      stage('SCR-01');
      const login = await staffLogin(kx, '777000901');
      R.kiosk.switchedAccount = login.switchedAccount;
      R.kiosk.adminFirstPin = login.firstPin;
      R.kiosk.adminHome = login.home;
      await shot(K, 'kiosk-admin-home');

      // ---- (3) меню разделов → «Администратор» (SCR-45 «Пользователи») → меню разделов админа «Ещё» → «Планшеты магазина» (SCR-54)
      stage('SCR-54');
      await openTablets(kx);
      await waitText('Сделать это устройство планшетом магазина', 30000, 'SCR-54: «Сделать это устройство планшетом магазина»');
      await sleep(1000);
      await shot(K, 'kiosk-scr54');

      // ---- (4) «Сделать это устройство планшетом магазина» → имя, склад (по умолчанию), → PIN → аварийный код
      stage('подключение');
      R.kiosk.exitCodeShown = await enrollThisDevice(kx, 'kiosk');
      await clickExact('Готово');
      const showcase = await waitHash('/kiosk', 60000, 'SCR-51 после «Готово»');
      await waitText('Начать заново', 60000, 'SCR-51: витрина планшета («Начать заново» в шапке)').catch(() => undefined);
      await sleep(2500);
      await shot(K, 'kiosk-scr51');
      R.kiosk.scr51 = (await allTexts()).slice(0, 12).map((t) => t.split('\n')[0]);
      const kioskFlag = await ev(K, `localStorage.getItem('FlutterSecureStorage.kiosk.tablet_id') !== null`);
      const stTablets = (await ev(K, `__posDemo.control('GET state')`)).kiosk;
      const tablet = (stTablets?.tablets ?? []).find((t) => t.name === 'Планшет у входа' && t.status === 'active');
      R.kiosk.tablet = tablet ? { id: tablet.id, status: tablet.status } : null;
      check(
        'T-KIOSK-034 SCR-54 → «Сделать это устройство планшетом магазина» (имя «Планшет у входа», склад, PIN администратора) → аварийный код один раз → «Готово» → SCR-51; планшет в GET state панели, признак планшета в хранилище',
        R.kiosk.exitCodeShown && showcase.startsWith('#/kiosk') && kioskFlag && !!tablet && stTablets?.enabled === true,
        { exitCodeShown: R.kiosk.exitCodeShown, hash: showcase, kioskFlag, tablet: R.kiosk.tablet, enabled: stTablets?.enabled },
      );

      // ---- (5) T-KIOSK-045: адресная строка и «назад» браузера не уводят планшет с /kiosk (G-15, G-0a)
      stage('адресная строка');
      await ev(K, `(location.hash = '#/auth/phone', true)`);
      await sleep(2500);
      const afterHash = await waitHash('/kiosk', 20000, 'G-15: #/auth/phone → /kiosk').catch(() => null);
      await ev(K, `(location.hash = '#/orders', true)`);
      await sleep(2500);
      const afterOrders = await waitHash('/kiosk', 20000, 'G-15: #/orders → /kiosk').catch(() => null);
      await ev(K, `(history.back(), true)`);
      await sleep(2500);
      const afterBack = await waitHash('/kiosk', 20000, 'G-15: «назад» браузера → /kiosk').catch(() => null);
      // адрес с переходом и Enter — полная загрузка страницы на #/auth/phone: холодный старт планшета → /kiosk
      await navigate(K, `${url('&envcheck=0')}#/auth/phone`);
      await appReady(K, 90000);
      const afterReload = await waitHash('/kiosk', 60000, 'G-0a/G-15 после загрузки #/auth/phone').catch(() => null);
      await semanticsOn(K);
      const showcaseAgain = await waitText('Начать заново', 60000, 'SCR-51 после загрузки').then(() => true, () => false);
      await sleep(2000);
      const loginShown = await has('Получить код');
      await shot(K, 'kiosk-after-address-bar');
      check(
        'T-KIOSK-045 веб-демо: адресная строка #/auth/phone и #/orders, «назад» браузера и загрузка страницы с #/auth/phone → планшет остаётся на /kiosk, экрана входа нет',
        !!afterHash && !!afterOrders && !!afterBack && !!afterReload && showcaseAgain && !loginShown,
        { afterHash, afterOrders, afterBack, afterReload, showcaseAgain, loginShown },
      );

      // ---- (6) заявка: «+ Добавить» → корзина → «Оформить заявку» → номер → «Получить код» → 246810 → SCR-53
      stage('товар в корзину');
      // карточка витрины — один узел семантики («…, В наличии, … + Добавить»): нажатие открывает слой карточки
      // товара (UI-51-011), в нём — «В корзину · …»
      await clickFound(firstCardInView(), 'карточка товара в наличии на витрине');
      await waitText('В корзину ·', 15000, 'слой карточки товара: «В корзину · …»');
      await sleep(800);
      await shot(K, 'kiosk-product-sheet');
      await clickText('В корзину ·');
      // строка подтверждена сервером (корзина планшета — только на сервере): «В корзине: 1 шт», кнопка «Добавить ещё»
      await waitText('Добавить ещё', 20000, 'слой карточки: товар в корзине («Добавить ещё»)');
      await sleep(600);
      await clickText('Закрыть');
      await sleep(1200);
      await waitFor(K, `[...document.querySelectorAll('flt-semantics')].some((n) => /Открыть корзину, [1-9]/.test((n.getAttribute('aria-label') || '') + ' ' + n.textContent))`, 20000, 'шапка: «Открыть корзину, 1 позиция, …»');
      R.kiosk.afterAdd = (await allTexts()).filter((t) => /Открыть корзину/.test(t)).slice(0, 3);
      await shot(K, 'kiosk-added');
      stage('корзина');
      await clickText('Открыть корзину');
      await waitText('Оформить заявку', 15000, 'drawer корзины: «Оформить заявку»');
      await sleep(1200);
      await shot(K, 'kiosk-cart');
      await clickExact('Оформить заявку');
      stage('SCR-52 телефон');
      // SCR-52 открывается поверх витрины (push): адрес страницы остаётся #/kiosk?…, шаг виден по заголовку
      await waitText('Введите номер телефона', 30000, 'SCR-52 «Введите номер телефона»');
      await sleep(1500);
      await digits('700000101');
      await sleep(800);
      await shot(K, 'kiosk-scr52-phone');
      const otpBefore = await count(202);
      await clickExact('Получить код');
      await waitFor(K, `(PosDemoPage.bridge._stats.statuses['202'] || 0) > ${otpBefore}`, 30000, 'POST /kiosk/order-otp → 202');
      stage('SCR-52 код');
      await waitText('Введите код из SMS', 20000, 'SCR-52 «Введите код из SMS»');
      await sleep(1200);
      await digits('246810');
      await sleep(800);
      await shot(K, 'kiosk-scr52-code');
      await clickExact('Отправить заявку');
      stage('SCR-53');
      const done = await waitHash('/kiosk/done', 90000, 'SCR-53');
      await waitText('Заявка № POS-', 30000, 'SCR-53 «Заявка № … отправлена»');
      await sleep(1200);
      const number = await ev(K, `(/Заявка № (POS-\\d{4}-\\d+)/.exec([...document.querySelectorAll('flt-semantics')].map((n) => (n.getAttribute('aria-label') || '') + ' ' + n.textContent).join(' ')) || [])[1] || null`);
      R.kiosk.number = number;
      await shot(K, 'kiosk-scr53');

      // ---- (7) кассир 906 (через мост страницы, как приложение) видит заявку createdVia=kiosk; документ «1С» создан
      stage('кассир и «1С»');
      const { token: ct } = await apiLogin(K, '+996777000906', { device: crypto.randomUUID() });
      let mine = null;
      for (let i = 0; i < 30 && !mine?.onec?.number; i++) {
        const list = (await api(K, 'GET', '/orders?createdVia=kiosk&limit=20', { token: ct })).json;
        mine = (list?.items ?? []).find((o) => o.publicNumber === number) ?? null;
        if (mine?.id && !mine?.onec?.number) mine = (await api(K, 'GET', `/orders/${mine.id}`, { token: ct })).json ?? mine;
        if (!mine?.onec?.number) await sleep(1000);
      }
      check(
        'T-KIOSK-034 SCR-53 «Заявка № … отправлена»; заявку с кодом 246810 видит кассир 906: GET /orders?createdVia=kiosk',
        done.startsWith('#/kiosk/done') && !!number && mine?.createdVia === 'kiosk',
        { hash: done, number, createdVia: mine?.createdVia ?? null, status: mine?.status ?? null, match: mine?.kioskCustomerMatch ?? null },
      );
      await panelOpen('onec');
      await sleep(2500);
      const onecRow = await ev(K, `(function () { var li = [...document.querySelectorAll('#pd-onec-orders li[data-order]')].find(function (x) { return x.textContent.indexOf(${JSON.stringify(String(number))}) >= 0; }); return li ? { via: li.dataset.createdVia, badge: !!li.querySelector('.pd-badge-kiosk'), text: li.innerText.slice(0, 200) } : null; })()`);
      const st = await ev(K, `__posDemo.control('GET state')`);
      const so = (st.orders ?? []).find((o) => o.number === number);
      await shot(K, 'kiosk-panel-onec');
      check(
        'T-KIOSK-043 веб-демо: документ «1С» демо создан (номер «1С» у заявки), в разделе «1С» панели — пометка «С планшета»',
        !!mine?.onec?.number && !!so?.onecNumber && so?.createdVia === 'kiosk' && onecRow?.via === 'kiosk' && onecRow?.badge === true,
        { onec: mine?.onec?.number ?? null, panel: so && { onecNumber: so.onecNumber, createdVia: so.createdVia }, row: onecRow },
      );
      await panelOpen('kiosk');
      await sleep(800);
      const kRow = await ev(K, `({ mode: document.getElementById('pd-kiosk-mode').textContent, rows: [...document.querySelectorAll('#pd-kiosk-tablets li[data-tablet]')].map(function (x) { return { id: x.dataset.tablet, status: x.dataset.status, text: x.innerText }; }) })`);
      await shot(K, 'kiosk-panel-tablets');
      check(
        'T-KIOSK-034 панель «Планшет магазина»: этот браузер — планшет, планшет «Планшет у входа» в списке (подключён)',
        /планшет магазина/.test(kRow.mode) && kRow.rows.some((r) => r.id === tablet?.id && r.status === 'active' && /Планшет у входа/.test(r.text)),
        kRow,
      );
      await panelClose();
      // «Готово» на SCR-53 — сброс (POST /kiosk/reset) и снова витрина
      stage('«Готово»');
      await clickExact('Готово');
      await waitFor(K, `location.hash === '#/kiosk' || location.hash.indexOf('#/kiosk?') === 0`, 60000, 'SCR-51 после «Готово»');
      await sleep(1500);
      await shot(K, 'kiosk-scr51-after-done');
    } catch (e) {
      R.kiosk.error = String(e?.message ?? e);
      R.kiosk.texts = await allTexts().catch(() => null);
      R.kiosk.hash = await hash().catch(() => null);
      check(`T-KIOSK-034 шаг kiosk без исключения (этап «${R.kiosk.stage}»)`, false, R.kiosk.error.slice(0, 900));
      await shot(K, 'kiosk-error').catch(() => undefined);
    }
  }

  // ------------------------------------------------------------ kioskswitch: «планшет магазина ↔ обычный вход»
  // P-002 TAB-3-02, ADR-115; 10 AC-KIOSK-027; 12 T-KIOSK-051 (вне релизных ворот, §3.23). После шага kiosk (браузер —
  // планшет «Планшет у входа», вкладка K): товар в корзину планшета → «ДЕМО» → «Планшет магазина» → «Вернуться к
  // обычному входу» → SCR-01 → вход кассиром 906 в интерфейсе, заявка планшета в «Ожидают оплаты» → «Планшет магазина» →
  // тот же store_tablets.id без подключения заново, корзина пуста → снова обычный вход — кассир без кода из SMS (SCR-08,
  // PIN); отложенные данные планшета негодны → панель предлагает «Подключить этот браузер заново» → вход администратором
  // → SCR-54 «Подключить заново этот планшет» → тот же store_tablets.id; «Сбросить демо» → планшета нет ни в браузере, ни
  // на сервере → первое подключение — новый store_tablets.id. На каждом шаге device.id и ключ AES приложения не
  // переносятся и не меняются (сравниваются отпечатки; значения ключей в отчёт не попадают).
  if (ONLY.has('kioskswitch')) {
    R.kioskswitch = {};
    const x = uiKit(K ?? cur, R.kioskswitch, 'kioskswitch');
    const T = x.tab;
    const tabletId = R.kiosk?.tablet?.id ?? null;
    const number = R.kiosk?.number ?? null;
    // Состояние хранилища браузера без значений: имена ключей приложения, места хранения (имена ключей внутри),
    // отпечатки device.id и ключа AES (SHA-256, 8 байт).
    const storageState = () => ev(T, `(async () => {
      const fp = async (v) => v === null ? 'none' : [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(v)))].slice(0, 8).map((b) => b.toString(16).padStart(2, '0')).join('');
      const short = (k) => k.replace(/^FlutterSecureStorage\\./, '');
      const slot = (n) => { const raw = localStorage.getItem('optomstroy.demo.kioskSlot.' + n); if (!raw) return null;
        try { const items = JSON.parse(raw).items || {}; const keys = Object.keys(items);
          return { keys: keys.map(short).sort(), device: keys.includes('FlutterSecureStorage.device.id'), aes: keys.includes('FlutterSecureStorage') }; } catch (e) { return { broken: true }; } };
      const app = Object.keys(localStorage).filter((k) => k.startsWith('FlutterSecureStorage.')).map(short).sort();
      return { tablet: app.includes('kiosk.tablet_id'), session: app.includes('auth.refresh_token'), app,
        dev: await fp(localStorage.getItem('FlutterSecureStorage.device.id')), aes: await fp(localStorage.getItem('FlutterSecureStorage')),
        slots: { kiosk: slot('kiosk'), normal: slot('normal') }, pending: localStorage.getItem('optomstroy.demo.kioskSwitch') !== null };
    })()`);
    // Новая загрузка страницы после кнопки панели: метка старой страницы пропала, демо готово («Всё равно продолжить» на
    // проверке среды — как пользователь: адрес после перезагрузки без envcheck=0).
    const reboot = async (label, ms = 150000) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        const s = await ev(T, `window.__ksOld ? 'old' : document.getElementById('pd-env-continue') ? 'env' : (window.__posDemo && __posDemo.isReady && window.PosDemoPage && PosDemoPage.boot.hidden && document.getElementById('pos-demo-fab')) ? 'ready' : 'wait'`, 10000).catch(() => 'nav');
        if (s === 'ready') return;
        if (s === 'env') await ev(T, `document.getElementById('pd-env-continue').click(), true`).catch(() => undefined);
        await sleep(300);
      }
      throw new Error(`не дождались новой загрузки страницы: ${label}`);
    };
    const panelButton = async (id) => {
      await x.panelOpen('kiosk');
      await waitFor(T, `!!document.getElementById(${JSON.stringify(id)})`, 15000, `панель: кнопка #${id}`);
      await ev(T, `(window.__ksOld = true, document.getElementById(${JSON.stringify(id)}).click(), true)`);
    };
    const panelKiosk = () => ev(T, `(() => { const g = (id) => document.getElementById(id); const n = g('pd-kiosk-notice');
      return { mode: g('pd-kiosk-mode').textContent, toNormal: !!g('pd-kiosk-to-normal'), toKiosk: !!g('pd-kiosk-to-kiosk'), reconnect: !!g('pd-kiosk-reconnect'), first: !!g('pd-kiosk-first'), notice: n ? n.textContent : null, reason: n ? n.dataset.reason : null }; })()`);
    const switchResult = () => ev(T, `PosDemoPage.boot.kiosk`);
    const tablets = async () => ((await ev(T, `__posDemo.control('GET state')`)).kiosk?.tablets ?? []).map((t) => ({ id: t.id, name: t.name, status: t.status }));
    // число позиций на кнопке корзины в шапке витрины («Открыть корзину, N …»); 0 — пусто
    const cartExpr = `(() => { for (const n of document.querySelectorAll('flt-semantics')) { const m = /Открыть корзину, (\\d+)/.exec((n.getAttribute('aria-label') || '') + ' ' + n.textContent); if (m) return Number(m[1]); } return 0; })()`;
    const showcase = async (label) => {
      const h = await x.waitHash('/kiosk', 60000, label);
      await semanticsOn(T);
      await x.waitText('Начать заново', 60000, `${label}: витрина («Начать заново»)`);
      await sleep(2500);
      return h;
    };
    const same = (a, b) => a.dev === b.dev && a.aes === b.aes && a.dev !== 'none' && a.aes !== 'none';
    try {
      if (!K || !tabletId) throw new Error('нужен шаг kiosk (--only …,kiosk,kioskswitch): браузер должен быть планшетом магазина');
      x.stage('исходное состояние');
      await semanticsOn(T);
      await x.waitText('Начать заново', 30000, 'SCR-51 после шага kiosk');
      const s0 = await storageState();
      const t0 = await tablets();
      R.kioskswitch.start = { s0: { app: s0.app, slots: s0.slots }, tablets: t0 };

      // ---- (1) товар в корзину планшета → «Вернуться к обычному входу» → SCR-01; данные планшета — в месте «планшет»
      x.stage('товар в корзину планшета');
      await x.clickFound(x.firstCardInView(), 'карточка товара в наличии на витрине');
      await x.waitText('В корзину ·', 15000, 'слой карточки товара: «В корзину · …»');
      await sleep(800);
      await x.clickText('В корзину ·');
      await x.waitText('Добавить ещё', 20000, 'слой карточки: товар в корзине');
      await sleep(600);
      await x.clickText('Закрыть');
      const cartBefore = await waitFor(T, cartExpr, 20000, 'шапка: «Открыть корзину, 1 …»');
      await shot(T, 'ks-cart-before');
      x.stage('«Вернуться к обычному входу»');
      await x.panelOpen('kiosk');
      const p0 = await panelKiosk();
      await shot(T, 'ks-panel-tablet');
      await panelButton('pd-kiosk-to-normal');
      await reboot('«Вернуться к обычному входу»');
      const r1 = await switchResult();
      const s1 = await storageState();
      await semanticsOn(T);
      await x.waitText('Получить код', 30000, 'SCR-01 после «Вернуться к обычному входу»');
      const h1 = await x.hash();
      await shot(T, 'ks-normal-scr01');
      check(
        'T-KIOSK-051 (1) «ДЕМО» → «Планшет магазина» → «Вернуться к обычному входу»: перезагрузка → экран входа SCR-01; данные планшета (признак kiosk.tablet_id, refresh-токен) отложены в хранилище страницы, device.id и ключ AES не перенесены и не изменились',
        p0.toNormal && p0.reconnect && !p0.toKiosk && r1?.to === 'normal' && r1.ok && !s1.tablet && !s1.session && !!s1.slots.kiosk?.keys?.includes('kiosk.tablet_id') && s1.slots.kiosk.keys.includes('auth.refresh_token') && !s1.slots.kiosk.device && !s1.slots.kiosk.aes && same(s0, s1) && !h1.startsWith('#/kiosk'),
        { panel: p0, result: r1, hash: h1, app: s1.app, slotKiosk: s1.slots.kiosk, deviceSame: s0.dev === s1.dev, aesSame: s0.aes === s1.aes },
      );

      // ---- (2) вход кассиром 906 в интерфейсе; заявка планшета — в «Ожидают оплаты» с пометкой «С планшета»
      x.stage('вход кассиром');
      const cashier = await staffLogin(x, '777000906');
      const seen = number ? await waitFor(T, `${x.semExpr(number)} && ${x.semExpr('С планшета')}`, 30000, `«Ожидают оплаты»: ${number} «С планшета»`).then(() => true, () => false) : false;
      await shot(T, 'ks-cashier');
      check(
        'T-KIOSK-051 (2) обычный вход: кассир 906 входит в той же вкладке (номер, код 246810, PIN); заявка с планшета видна кассиру — «Ожидают оплаты» с пометкой «С планшета»',
        !!cashier.home && seen,
        { cashier, number, seen, texts: seen ? undefined : (await x.allTexts()).slice(0, 30) },
      );

      // ---- (3) «Планшет магазина» → тот же планшет без подключения заново; корзина пуста; вход кассира отложен
      x.stage('«Планшет магазина»');
      await panelButton('pd-kiosk-to-kiosk');
      await reboot('«Планшет магазина»');
      const r2 = await switchResult();
      const s2 = await storageState();
      const h2 = await showcase('SCR-51 после «Планшет магазина»');
      const cartAfter = await ev(T, cartExpr);
      const enrollShown = await x.has('Сделать это устройство планшетом магазина');
      const t2 = await tablets();
      await shot(T, 'ks-kiosk-again');
      check(
        'T-KIOSK-051 (3) снова «Планшет магазина»: тот же демо-планшет — тот же store_tablets.id, новых планшетов нет, подключать заново не нужно (сразу SCR-51); корзина планшета пуста; вход кассира отложен; device.id и ключ AES не изменились',
        r2?.to === 'kiosk' && r2.ok && s2.tablet && !s2.slots.kiosk && !!s2.slots.normal?.keys?.includes('auth.refresh_token') && !s2.slots.normal.device && same(s0, s2) && h2.startsWith('#/kiosk') && !enrollShown && t2.length === t0.length && t2.some((t) => t.id === tabletId && t.status === 'active') && cartBefore >= 1 && cartAfter === 0,
        { result: r2, hash: h2, tablets: t2, tabletId, cartBefore, cartAfter, slotNormal: s2.slots.normal, deviceSame: s0.dev === s2.dev, aesSame: s0.aes === s2.aes },
      );

      // ---- (4) снова «Вернуться к обычному входу» → кассир без кода из SMS: SCR-08 «Введите PIN-код» → рабочий экран
      x.stage('снова обычный вход');
      await panelButton('pd-kiosk-to-normal');
      await reboot('снова «Вернуться к обычному входу»');
      const r3 = await switchResult();
      const s3 = await storageState();
      const unlock = await waitFor(T, `location.hash.indexOf('#/auth/unlock') === 0 ? location.hash : null`, 30000, 'SCR-08 «Введите PIN-код»').catch(() => null);
      await semanticsOn(T);
      await waitFor(T, `!!(${findExact('7')})`, 20000, 'SCR-08: клавиатура PIN');
      const otpShown = await x.has('Получить код');
      await shot(T, 'ks-cashier-unlock');
      await x.digits('715382');
      const home3 = await x.waitText('Меню разделов', 30000, 'рабочий экран кассира после PIN').then(() => true, () => false);
      await shot(T, 'ks-cashier-back');
      check(
        'T-KIOSK-051 (4) снова «Вернуться к обычному входу»: вернулся вход кассира без кода из SMS (SCR-08 «Введите PIN-код» → рабочий экран); планшет снова отложен',
        r3?.to === 'normal' && r3.ok && r3.restored > 0 && !s3.tablet && s3.session && !!s3.slots.kiosk?.keys?.includes('kiosk.tablet_id') && same(s0, s3) && !!unlock && !otpShown && home3,
        { result: r3, unlock, otpShown, home3 },
      );

      // ---- (5) отложенные данные планшета не восстановились (запись другой эпохи данных демо) → «вернуть не удалось»
      x.stage('отложенные данные негодны');
      await ev(T, `(() => { const k = 'optomstroy.demo.kioskSlot.kiosk'; const j = JSON.parse(localStorage.getItem(k)); j.epochKey = 'e000000000000000'; localStorage.setItem(k, JSON.stringify(j)); return true; })()`);
      await panelButton('pd-kiosk-to-kiosk');
      await reboot('«Планшет магазина» с негодными данными');
      const r4 = await switchResult();
      const s4 = await storageState();
      await x.panelOpen('kiosk');
      await waitFor(T, `!!document.getElementById('pd-kiosk-reconnect')`, 15000, 'панель: «Подключить этот браузер заново»');
      const p4 = await panelKiosk();
      await shot(T, 'ks-restore-failed');
      check(
        'T-KIOSK-051 (5) отложенные данные планшета не восстановились: браузер остаётся на обычном входе (вход кассира не тронут), запись удалена, панель сообщает «вернуть не удалось» и предлагает «Подключить этот браузер заново»',
        r4?.to === 'kiosk' && r4.ok === false && r4.reason === 'epoch' && !s4.tablet && s4.session && !s4.slots.kiosk && same(s0, s4) && p4.reconnect && !p4.toKiosk && !p4.toNormal && /вернуть не удалось/.test(p4.notice ?? '') && p4.reason === 'epoch',
        { result: r4, panel: p4 },
      );

      // ---- (6) «Подключить этот браузер заново» → вход администратором 901 → SCR-54 «Подключить заново этот планшет» →
      // выбор записи → PIN → аварийный код → SCR-51: тот же store_tablets.id
      x.stage('подключение заново');
      await ev(T, `(window.__ksOld = true, document.getElementById('pd-kiosk-reconnect').click(), true)`);
      await reboot('«Подключить этот браузер заново»');
      const r5 = await switchResult();
      const s5 = await storageState();
      const admin = await staffLogin(x, '777000901');
      await openTablets(x);
      await x.waitText('Подключить заново этот планшет', 30000, 'SCR-54: «Подключить заново этот планшет»');
      await sleep(1000);
      await shot(T, 'ks-scr54');
      const codeShown = await reconnectThisDevice(x, 'Планшет у входа', 'ks');
      await x.clickExact('Готово');
      const h6 = await showcase('SCR-51 после подключения заново');
      const s6 = await storageState();
      const t6 = await tablets();
      await shot(T, 'ks-reconnected');
      check(
        'T-KIOSK-051 (6) «Подключить этот браузер заново» (данные планшета удалены, device.id сохранён, вход кассира отложен) → вход администратором → SCR-54 «Подключить заново этот планшет» → PIN → аварийный код → SCR-51: тот же store_tablets.id, новых планшетов нет',
        r5?.to === 'reconnect' && r5.ok && !s5.tablet && !s5.session && !!s5.slots.normal?.keys?.includes('auth.refresh_token') && same(s0, s5) && !!admin.home && codeShown && h6.startsWith('#/kiosk') && s6.tablet && same(s0, s6) && t6.length === t0.length && t6.some((t) => t.id === tabletId && t.status === 'active'),
        { result: r5, admin, codeShown, hash: h6, tablets: t6, tabletId, deviceSame: s0.dev === s6.dev },
      );

      // ---- (7) «Сбросить демо» удаляет и планшет: только первое подключение, новый store_tablets.id
      x.stage('«Сбросить демо»');
      await x.panelOpen('service');
      await ev(T, `document.getElementById('pd-reset').click(), true`);
      await waitFor(T, `!document.getElementById('pd-reset-confirm').hidden`, 5000, 'подтверждение «Сбросить»');
      await ev(T, `(window.__ksOld = true, document.getElementById('pd-reset-yes').click(), true)`);
      await reboot('«Сбросить демо»', 240000);
      const s7 = await storageState();
      const t7 = await tablets();
      await x.panelOpen('kiosk');
      await waitFor(T, `!!document.getElementById('pd-kiosk-first')`, 15000, 'панель: «ещё не подключён»').catch(() => null);
      const p7 = await panelKiosk();
      await shot(T, 'ks-after-reset');
      await x.panelClose();
      x.stage('первое подключение после сброса');
      await staffLogin(x, '777000901');
      await openTablets(x);
      await x.waitText('Сделать это устройство планшетом магазина', 30000, 'SCR-54 после сброса');
      const reconnectOffered = await x.has('Подключить заново этот планшет');
      await sleep(800);
      const codeShown2 = await enrollThisDevice(x, 'ks-new');
      await x.clickExact('Готово');
      await showcase('SCR-51 после первого подключения');
      const t8 = await tablets();
      await shot(T, 'ks-new-tablet');
      check(
        'T-KIOSK-051 (7) «Сбросить демо», затем «Планшет магазина»: прежнего планшета нет ни в браузере (признак и отложенные данные удалены), ни на сервере демо; панель и SCR-54 предлагают только первое подключение; после него — новый store_tablets.id',
        !s7.tablet && !s7.slots.kiosk && !s7.slots.normal && t7.length === 0 && p7.first && !p7.toKiosk && !p7.reconnect && !reconnectOffered && codeShown2 && t8.length === 1 && t8[0].id !== tabletId && t8[0].status === 'active',
        { tabletsAfterReset: t7, panel: p7, reconnectOffered, tablets: t8, oldId: tabletId },
      );
    } catch (e) {
      R.kioskswitch.error = String(e?.message ?? e);
      R.kioskswitch.texts = await x.allTexts().catch(() => null);
      R.kioskswitch.hash = await x.hash().catch(() => null);
      R.kioskswitch.bootSteps = await ev(T, `PosDemoPage.boot.steps.slice(-12)`).catch(() => null);
      check(`T-KIOSK-051 шаг kioskswitch без исключения (этап «${R.kioskswitch.stage}»)`, false, R.kioskswitch.error.slice(0, 900));
      await shot(T, 'kioskswitch-error').catch(() => undefined);
    }
  }

  // ------------------------------------------------------------ общие проверки
  const csp = [];
  for (const [sid, s] of sessions) if (s.type === 'page') csp.push(...((await ev({ sid }, `window.__cspViolations || []`, 5000).catch(() => [])) ?? []));
  R.cspPage = csp;
  if (REMOTE) {
    // журнал из CDP Network (запросы Node к адресу сюда не попадают — фильтр пробы /api/ не нужен)
    R.server = { source: 'cdp', requests: netLog.length, api: netLog.filter((r) => /^\/api\//.test(r.p)).length, notFound: [...new Set(netLog.filter((r) => r.s === 404).map((r) => r.p))].slice(0, 20) };
    // для сведения: прочие 4xx/5xx, ошибки загрузки и перенаправления того же origin, запросы без ответа
    R.server.otherErrors = netLog.filter((r) => (r.s >= 400 && r.s !== 404) || r.err).map((r) => `${r.m} ${r.p} ${r.s ?? ''} ${r.err ?? ''}`.trim()).slice(0, 20);
    R.server.redirects = netLog.filter((r) => r.s >= 300 && r.s < 400).map((r) => `${r.m} ${r.p} ${r.s}`).slice(0, 20);
    R.server.noResponse = netLog.filter((r) => r.s === null && !r.err).length;
    R.server.byType = netLog.reduce((a, r) => ((a[r.type ?? '?'] = (a[r.type ?? '?'] || 0) + 1), a), {});
  } else {
    const log0 = await (await fetch(`${ORIGIN}/__site/log`)).json();
    const fromBrowser = log0.filter((r) => r.p !== '/api/v1/__smoke_probe');
    R.server = { requests: fromBrowser.length, api: fromBrowser.filter((r) => /^\/api\//.test(r.p)).length, notFound: [...new Set(fromBrowser.filter((r) => r.s === 404).map((r) => r.p))].slice(0, 20) };
  }
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
  if (server) killTree(server.pid);
  await sleep(1500);
  if (!argv.includes('--keep-profile')) rmSync(PROFILE, { recursive: true, force: true, maxRetries: 5, retryDelay: 400 });
  R.finishedAt = new Date().toISOString();
  R.summary = { checks: R.checks.length, failed: R.checks.filter((c) => !c.ok).length };
  writeFileSync(`${OUT}/smoke.json`, JSON.stringify(R, null, 1));
  log(`итог: ${R.summary.checks - R.summary.failed}/${R.summary.checks}; ${OUT}/smoke.json; профиль ${existsSync(PROFILE) ? 'НЕ удалён' : 'удалён'}`);
  process.exit(R.summary.failed ? 1 : 0);
}

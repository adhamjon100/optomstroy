// Headless-проверка предпросмотра и печати PDF на СОБРАННОМ сайте веб-демо под действующей CSP (fix:pdfcsp).
// Настоящая страница, настоящее приложение Flutter, настоящий backend.js — через tools/serve-site.mjs с заголовками
// Netlify (site/_headers). Помощники CDP и вход в интерфейсе — как в tools/smoke.mjs (тот же сценарий входа).
//
//   node demo/web/tools/pdf-smoke.mjs [--port 8097] [--cdp 9417] [--storage idb|opfs] [--out <каталог>] [--keep-profile]
//
// Шаги:
//   1. вход кассира 906 в интерфейсе (номер → «Получить код» → 246810 при ВЫКЛЮЧЕННОЙ семантике (WEB-KI-21) → PIN
//      715382 дважды → согласие → «Начать работу»);
//   2. заказ продавца 907 через мост страницы (как приложение): QR, «Оплатить сейчас» → платёж received, номер «1С»;
//   3. в интерфейсе 906: #/orders/<id> → «Товарный чек» → «Просмотр» (PdfPreview пакета printing → pdf.js), снимок;
//      Esc → «Печать» (Printing.layoutPdf: скрытый iframe blob: + встроенный скрипт печати пакета), снимок.
// Пишет: нарушения CSP (Log, Audits, securitypolicyviolation в каждом кадре), запросы на чужие хосты, ошибки консоли,
// исключения, новые вкладки (запасной путь печати пакета — открыть PDF в новой вкладке), вызовы печати.
// Скачиваний нет: Chrome запущен с --host-resolver-rules «все имена → NOTFOUND, кроме 127.0.0.1» (запрос на CDN
// виден в журнале как попытка, но байты не приходят) и Browser.setDownloadBehavior deny.
// Итог — <out>/pdf-smoke.json и снимки <out>/NN-*.png; код 0 — все проверки зелёные. Сервер и браузер — по PID,
// профиль удаляется.
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url)).replace(/\\/g, '/');
const WEB = resolve(HERE, '..').replace(/\\/g, '/');
const ROOT = resolve(WEB, '../..').replace(/\\/g, '/');
const argv = process.argv.slice(2);
const arg = (k, d) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : d);
const PORT = Number(arg('--port', 8097));
const CDP = Number(arg('--cdp', 9417));
const STORAGE = arg('--storage', 'idb');
const OUT = resolve(arg('--out', `${ROOT}/.tmp/web_demo/pdfcsp/run-${new Date().toISOString().replace(/[:.]/g, '-')}`)).replace(/\\/g, '/');
const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PROFILE = `${ROOT}/.tmp/web_demo/pdfcsp/chrome-profile-${Date.now()}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const log = (...a) => console.log(`${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s`, ...a);
mkdirSync(OUT, { recursive: true });
process.env.TEMP ||= `${ROOT}/.tmp`;
process.env.TMP ||= `${ROOT}/.tmp`;

const R = { port: PORT, cdp: CDP, storage: STORAGE, startedAt: new Date().toISOString(), checks: [], exceptions: [], consoleErrors: [], consoleWarnings: [], csp: [], cspIssues: [], foreign: [], failedLoads: [], targets: [], pids: {}, shots: [], steps: {} };
const check = (name, ok, evidence) => {
  R.checks.push({ name, ok: !!ok, evidence: evidence === undefined ? null : evidence });
  log(`${ok ? 'OK  ' : 'FAIL'} ${name}${evidence !== undefined ? ` — ${JSON.stringify(evidence).slice(0, 500)}` : ''}`);
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

if (!(await portFree(PORT))) throw new Error(`порт ${PORT} занят`);
if (!(await portFree(CDP))) throw new Error(`порт CDP ${CDP} занят`);
const ORIGIN = `http://127.0.0.1:${PORT}`;
const server = spawn(process.execPath, [`${HERE}/serve-site.mjs`, '--port', String(PORT), '--quiet'], { stdio: ['ignore', 'pipe', 'pipe'] });
R.pids.server = server.pid;
mkdirSync(PROFILE, { recursive: true });
const chrome = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${CDP}`, `--user-data-dir=${PROFILE}`, '--window-size=1280,800', '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-default-apps', '--lang=ru', '--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1', 'about:blank'], { stdio: 'ignore' });
R.pids.browser = chrome.pid;

// ---------------------------------------------------------------- CDP (как tools/smoke.mjs)
let ws;
const pending = new Map();
const sessions = new Map(); // sessionId → { type, url, tab }
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
      ver = await (await fetch(`http://127.0.0.1:${CDP}/json/version`)).json();
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
      sessions.set(m.params.sessionId, { type: info.type, url: info.url, tab: s?.tab ?? info.targetId });
      R.targets.push({ attached: info.type, url: String(info.url).slice(0, 160) });
      void initSession(m.params.sessionId, info.type);
    } else if (m.method === 'Target.targetCreated') {
      const info = m.params.targetInfo;
      R.targets.push({ created: info.type, url: String(info.url).slice(0, 160), opener: info.openerId ?? null, at: Date.now() - t0 });
    } else if (m.method === 'Network.requestWillBeSent') {
      const u = m.params.request.url;
      if (!u.startsWith(ORIGIN) && !/^(data|blob|chrome|about|devtools|chrome-extension):/.test(u)) R.foreign.push({ type: s?.type, url: u.slice(0, 200) });
      if (/\/pdfjs\/|pdfjs-dist|pdf\.worker/.test(u)) (R.pdfjsRequests ||= []).push({ type: s?.type, url: u.replace(ORIGIN, '').slice(0, 200) });
    } else if (m.method === 'Network.loadingFailed') {
      if (!m.params.canceled) R.failedLoads.push({ type: s?.type, error: m.params.errorText, blocked: m.params.blockedReason ?? null });
    } else if (m.method === 'Runtime.exceptionThrown') {
      R.exceptions.push({ type: s?.type, text: `${m.params.exceptionDetails.text} ${m.params.exceptionDetails.exception?.description ?? ''}`.slice(0, 600) });
    } else if (m.method === 'Runtime.consoleAPICalled' && (m.params.type === 'error' || m.params.type === 'warning')) {
      const text = m.params.args.map((a) => a.value ?? a.description ?? '').join(' ').slice(0, 1500);
      (m.params.type === 'error' ? R.consoleErrors : R.consoleWarnings).push({ t: Date.now() - t0, type: s?.type, text });
    } else if (m.method === 'Log.entryAdded') {
      const e = m.params.entry;
      if (/Content Security Policy|Refused to/i.test(e.text)) R.csp.push({ type: s?.type, text: e.text.slice(0, 400) });
      else if (e.level === 'error') R.consoleErrors.push({ t: Date.now() - t0, type: s?.type, source: e.source, text: `${e.text} ${e.url ?? ''}`.slice(0, 600) });
    } else if (m.method === 'Audits.issueAdded') {
      const i = m.params.issue;
      if (i.code === 'ContentSecurityPolicyIssue') R.cspIssues.push({ type: s?.type, ...i.details?.contentSecurityPolicyIssueDetails, sourceCodeLocation: undefined });
    }
  };
}
async function initSession(sid, type) {
  const tasks = [send('Runtime.enable', {}, sid), send('Network.enable', {}, sid)];
  if (type === 'page' || type === 'iframe') tasks.push(send('Page.enable', {}, sid), send('Log.enable', {}, sid), send('Audits.enable', {}, sid));
  if (['page', 'iframe', 'worker', 'shared_worker'].includes(type)) tasks.push(send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sid));
  await Promise.allSettled(tasks);
}
// Наблюдение страницы (до любого скрипта, в каждом кадре): нарушения CSP; вызов встроенной функции печати пакета
// printing (она первым делом делает focus() скрытого iframe #__net_nfet_printing__); вызовы canvas.toBlob (пакет
// переводит каждую отрисованную pdf.js страницу в PNG); клики по ссылкам (запасной путь печати — PDF в новой вкладке).
const OBSERVER = `(() => {
  window.__cspViolations = [];
  document.addEventListener('securitypolicyviolation', function (e) { window.__cspViolations.push({ d: e.violatedDirective, e: e.effectiveDirective, u: String(e.blockedURI).slice(0, 160), s: String(e.sample || '').slice(0, 120), f: String(e.sourceFile || '').slice(-60) }); });
  const focus = HTMLElement.prototype.focus;
  HTMLElement.prototype.focus = function () { if (this.id === '__net_nfet_printing__') window.__printFocus = (window.__printFocus || 0) + 1; return focus.apply(this, arguments); };
  const toBlob = HTMLCanvasElement.prototype.toBlob;
  HTMLCanvasElement.prototype.toBlob = function () { window.__toBlob = (window.__toBlob || 0) + 1; return toBlob.apply(this, arguments); };
  const aclick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () { (window.__anchorClicks = window.__anchorClicks || []).push({ href: String(this.href).slice(0, 80), target: this.target, download: this.download }); return aclick.apply(this, arguments); };
})();`;
async function openTab(name) {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  sessions.set(sessionId, { type: 'page', url: 'about:blank', tab: targetId, name });
  await initSession(sessionId, 'page');
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false }, sessionId);
  await send('Page.addScriptToEvaluateOnNewDocument', { source: OBSERVER }, sessionId);
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
    await sleep(250);
  }
  throw new Error(`не дождались: ${label}${last ? ` (${String(last.message).slice(0, 200)})` : ''}`);
};
let shotN = 0;
const shot = async (tab, name) => {
  const r = await send('Page.captureScreenshot', { format: 'png' }, tab.sid);
  const f = `${OUT}/${String(++shotN).padStart(2, '0')}-${name}.png`;
  writeFileSync(f, Buffer.from(r.data, 'base64'));
  R.shots.push(f);
  return f;
};
const click = async (tab, x, y) => {
  for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 }, tab.sid);
};
const key = async (tab, k, code, keyCode) => {
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code, windowsVirtualKeyCode: keyCode }, tab.sid);
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, windowsVirtualKeyCode: keyCode }, tab.sid);
};
const typeText = (tab, text) => send('Input.insertText', { text }, tab.sid);
const appReady = (tab, ms = 90000) => waitFor(tab, `!!(window.__posDemo && __posDemo.isReady && window.PosDemoPage && PosDemoPage.boot.hidden && document.getElementById('pos-demo-fab'))`, ms, 'демо готово (ready + первый кадр + «ДЕМО»)');

let lastDevice = crypto.randomUUID();
const api = (tab, method, path, { headers = {}, body, token, device, bytes = false } = {}) =>
  ev(
    tab,
    `(async () => {
      const h = Object.assign({ 'X-Device-Id': ${JSON.stringify(String(device ?? lastDevice))}, 'X-App-Version': '0.1.0+1', 'X-Platform': 'windows', 'Accept-Language': 'ru', 'content-type': 'application/json' }, ${JSON.stringify(headers)});
      ${token ? `h.Authorization = 'Bearer ' + ${JSON.stringify(token)};` : ''}
      const r = await __posDemo.request({ method: ${JSON.stringify(method)}, url: ${JSON.stringify(`/api/v1${path}`)}, headers: h, body: ${body === undefined ? 'null' : JSON.stringify(JSON.stringify(body))} });
      if (${bytes}) { const b = new Uint8Array(r.body); return { status: r.status, bytes: b.length, head: new TextDecoder().decode(b.slice(0, 8)), headers: Object.fromEntries(r.headers) }; }
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
  const vr = await api(tab, 'POST', '/auth/otp/verify', { body: { challengeId: rq.json?.challengeId, code: '246810', device: { name: 'pdf-smoke', platform: 'windows', appVersion: '0.1.0+1' } } });
  const token = vr.json?.accessToken; // check-secrets: allow — токен из ответа API тестового прогона, не секрет
  if (token && (vr.json?.nextStep === 'set_pin' || vr.json?.security?.pinSet === false)) await api(tab, 'POST', '/me/pin', { token, headers: { 'Idempotency-Key': crypto.randomUUID() }, body: { newPin: pin } });
  return { token, verify: vr };
}
async function sellOne(tab, token, method) {
  const pl = (await api(tab, 'GET', '/catalog/products?limit=40&inStock=true&sort=price:asc', { token })).json?.items?.filter((p) => !p.hasVariants && p.defaultVariantId && p.baseUnit?.id && p.price) ?? [];
  const p = pl[Math.floor(Math.random() * Math.min(pl.length, 20))];
  let cart = (await api(tab, 'GET', '/cart', { token })).json;
  if ((cart?.items ?? []).length) cart = (await api(tab, 'DELETE', `/cart?rowVersion=${cart.rowVersion}`, { token })).json;
  cart = (await api(tab, 'PUT', `/cart/items/${p.defaultVariantId}`, { token, headers: { 'Idempotency-Key': crypto.randomUUID() }, body: { quantity: { value: '1', unitId: p.baseUnit.id, packagingId: null }, rowVersion: cart.rowVersion, mode: 'set' } })).json;
  const prev = await api(tab, 'POST', '/cart/checkout-preview', { token, headers: { 'Idempotency-Key': crypto.randomUUID() }, body: { cartId: cart.id, cartRowVersion: cart.rowVersion, paymentMethod: method, delivery: { method: 'pickup' }, receiver: { kind: 'customer' } } });
  const body = { cartId: cart.id, cartRowVersion: cart.rowVersion, ...(prev.json?.previewToken ? { previewToken: prev.json.previewToken } : {}), receiver: { kind: 'customer' }, delivery: { method: 'pickup' }, paymentMethod: method, items: [{ variantId: p.defaultVariantId, quantity: { value: '1', unitId: p.baseUnit.id, packagingId: null } }] };
  return api(tab, 'POST', '/orders', { token, headers: { 'Idempotency-Key': crypto.randomUUID() }, body });
}

// Семантика Flutter (как tools/smoke.mjs)
const findExpr = (text) => `(() => { const want = ${JSON.stringify(text)}; let best = null;
  for (const n of document.querySelectorAll('flt-semantics, flt-semantics *, [role], input, textarea')) {
    const label = (n.getAttribute('aria-label') || '') + ' ' + (n.textContent || '');
    if (!label.includes(want)) continue; const r = n.getBoundingClientRect(); if (r.width < 2 || r.height < 2) continue;
    const area = r.width * r.height; if (!best || area < best.area) best = { area, x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
  return best; })()`;
const findExact = (text) => `(() => { const want = ${JSON.stringify(text)}; let best = null;
  for (const n of document.querySelectorAll('flt-semantics, flt-semantics *, [role]')) {
    const label = (n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').trim();
    if (label !== want) continue; const r = n.getBoundingClientRect(); if (r.width < 2 || r.height < 2) continue;
    const score = (n.getAttribute('role') === 'button' ? 0 : 1e9) + r.width * r.height;
    if (!best || score < best.score) best = { score, x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
  return best; })()`;
// Кнопка [button] в строке документа [row] (DocumentActions: заголовок и подпись сверху, кнопки — под ними, ~64 px ниже
// заголовка; ближайшая кнопка НИЖЕ заголовка своей строки, а не строки выше).
const findRowButton = (row, button) => `(() => {
  const vis = (n) => { const r = n.getBoundingClientRect(); return r.width >= 2 && r.height >= 2 ? r : null; };
  let title = null;
  for (const n of document.querySelectorAll('flt-semantics, flt-semantics *')) {
    const label = (n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').trim();
    if (!label.startsWith(${JSON.stringify(row)})) continue; const r = vis(n); if (!r) continue;
    if (!title || r.width * r.height < title.w * title.h) title = { x: r.left, y: r.top + r.height / 2, w: r.width, h: r.height };
  }
  if (!title) return null;
  let best = null;
  for (const n of document.querySelectorAll('flt-semantics, flt-semantics *, [role=button]')) {
    const label = (n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').trim();
    if (label !== ${JSON.stringify(button)}) continue; const r = vis(n); if (!r) continue;
    const cy = r.top + r.height / 2; const d = cy - title.y;
    if (d > -8 && d < 110 && (!best || d < best.d)) best = { d, x: r.left + r.width / 2, y: cy };
  }
  return best ? { x: best.x, y: best.y, title } : { title };
})()`;
const semanticsOn = async (tab) => {
  await waitFor(tab, `!!document.querySelector('flt-semantics-placeholder') || document.querySelectorAll('flt-semantics').length > 3`, 20000, 'семантика Flutter');
  await ev(tab, `(document.querySelector('flt-semantics-placeholder') && document.querySelector('flt-semantics-placeholder').click(), true)`);
  await waitFor(tab, `document.querySelectorAll('flt-semantics').length > 3`, 15000, 'семантика включена');
};
const texts = (tab) => ev(tab, `[...document.querySelectorAll('flt-semantics')].map((n) => n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').map((s) => s.trim()).filter(Boolean).slice(0, 80)`);
const pageState = (tab) => ev(tab, `({
  pdfjsLib: typeof window.pdfjsLib === 'undefined' ? null : { workerSrc: String(pdfjsLib.GlobalWorkerOptions && pdfjsLib.GlobalWorkerOptions.workerSrc), demo: pdfjsLib.__demo ? JSON.parse(JSON.stringify(pdfjsLib.__demo)) : null },
  dartPdfJsBaseUrl: window.dartPdfJsBaseUrl === undefined ? null : String(window.dartPdfJsBaseUrl),
  pdfjsScripts: [...document.querySelectorAll('script[src]')].map((s) => s.src).filter((s) => /pdf/.test(s)).map((s) => s.replace(location.origin, '')),
  printScript: !!document.getElementById('__net_nfet_printing_s__'), printFnDefined: typeof window.__net_nfet_printing___print === 'function',
  printFrame: (() => { const f = document.getElementById('__net_nfet_printing__'); if (!f) return null; let ct = null; try { ct = f.contentDocument && f.contentDocument.contentType; } catch (e) { ct = 'no access: ' + e.name; } return { src: String(f.getAttribute('src')).slice(0, 40), contentType: ct }; })(),
  printFocus: window.__printFocus || 0, toBlob: window.__toBlob || 0, anchorClicks: window.__anchorClicks || [],
  csp: window.__cspViolations || [], pdfViewerEnabled: navigator.pdfViewerEnabled, href: location.href.replace(location.origin, '')
})`);

// ================================================================ сценарий
try {
  await connect();
  await send('Target.setDiscoverTargets', { discover: true });
  await send('Browser.setDownloadBehavior', { behavior: 'deny' }).catch(() => undefined);
  await sleep(600);
  const hIndex = await fetch(`${ORIGIN}/`);
  R.headers = { csp: hIndex.headers.get('content-security-policy') };
  const hShim = await fetch(`${ORIGIN}/pdfjs/pdf.min.js`, { method: 'HEAD' });
  R.headers.pdfjsShim = [hShim.status, hShim.headers.get('content-type')];
  log('CSP:', R.headers.csp);

  const A = await openTab('A');
  await send('Page.navigate', { url: `${ORIGIN}/?storage=${STORAGE}&envcheck=0` }, A.sid);
  await appReady(A, 120000);
  await sleep(1500);
  R.steps.boot = await ev(A, `({ storage: __posDemo.info.storage, epochKey: __posDemo.info.epochKey, buildId: PosDemoPage.boot.build.buildId })`);

  // ------------------------------------------------------------ 1. вход кассира 906 в интерфейсе
  await semanticsOn(A);
  await waitFor(A, `document.body.innerHTML.includes('Получить код')`, 30000, 'SCR-01');
  const field = await ev(A, findExpr('Номер телефона'));
  const submit = await ev(A, findExpr('Получить код'));
  await send('Page.reload', {}, A.sid); // ввод кода — с выключенной семантикой (WEB-KI-21)
  await appReady(A, 90000);
  await sleep(1500);
  await click(A, field.x, field.y);
  await sleep(500);
  await typeText(A, '777000906');
  await sleep(600);
  await click(A, submit.x, submit.y);
  await waitFor(A, `PosDemoPage.bridge._stats.statuses['202'] >= 1`, 15000, 'otp/request 202');
  await sleep(1500);
  await typeText(A, '246810');
  await waitFor(A, `(PosDemoPage.bridge._stats.statuses['200'] || 0) >= 2`, 15000, 'otp/verify 200');
  await sleep(2500);
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
  if (await ev(A, `document.body.innerHTML.includes('Повторите') || document.body.innerHTML.includes('ещё раз')`)) {
    await pinDigits('715382');
    await sleep(1200);
  }
  const consent = await ev(A, findExpr('Я ознакомлен'));
  if (consent) {
    await click(A, consent.x, consent.y);
    await sleep(600);
  }
  const start = await ev(A, findExpr('Начать работу'));
  if (start) await click(A, start.x, start.y);
  await waitFor(A, `(PosDemoPage.bridge._stats.statuses['204'] || 0) >= 1`, 15000, 'POST /me/pin 204');
  await sleep(3000);
  await semanticsOn(A).catch(() => undefined);
  const after = await texts(A).catch(() => []);
  check('вход кассира 906 в интерфейсе (номер, 246810, PIN дважды) → рабочий экран', !after.some((t) => /Получить код|Введите код/.test(t)), { after: after.slice(0, 10), href: await ev(A, 'location.href.replace(location.origin, "")') });
  await shot(A, 'after-login');

  // ------------------------------------------------------------ 2. заказ (продавец 907, QR оплачен, номер «1С»)
  const seller = await apiLogin(A, '+996777000907');
  await ev(A, `__posDemo.control('POST qr/config', { paidAfterPolls: 0 })`);
  const created = await sellOne(A, seller.token, 'qr_bakai');
  const order = created.json;
  const pay = order?.payments?.[0];
  await ev(A, `__posDemo.control(${JSON.stringify(`POST qr/${pay?.id}/pay`)}, {})`);
  let st = null;
  for (let i = 0; i < 20 && st !== 'received'; i++) st = (await api(A, 'GET', `/payments/${pay.id}?wait=10`, { token: seller.token })).json?.status;
  let o2 = null;
  for (let i = 0; i < 60 && !o2?.onec?.number; i++) {
    o2 = (await api(A, 'GET', `/orders/${order.id}`, { token: seller.token })).json;
    if (!o2?.onec?.number) await sleep(500);
  }
  const pdf = await api(A, 'GET', `/orders/${order.id}/documents/receipt.pdf?format=thermal80`, { token: seller.token, headers: { Accept: 'application/pdf' }, bytes: true });
  R.steps.order = { status: created.status, id: order?.id, number: order?.publicNumber, payment: st, onec: o2?.onec?.number ?? null, orderStatus: o2?.status, receiptPdf: { status: pdf.status, bytes: pdf.bytes, head: pdf.head, type: pdf.headers?.['content-type'] } };
  check('заказ 907 оплачен QR, номер «1С»; товарный чек — PDF (через мост)', [200, 201].includes(created.status) && st === 'received' && !!o2?.onec?.number && pdf.status === 200 && pdf.head.startsWith('%PDF'), R.steps.order);

  // ------------------------------------------------------------ 3. предпросмотр товарного чека в интерфейсе
  await ev(A, `(location.hash = ${JSON.stringify(`#/orders/${order.id}`)}, true)`);
  await sleep(2500);
  await semanticsOn(A).catch(() => undefined);
  await waitFor(A, `document.body.innerHTML.includes('Товарный чек')`, 30000, 'SCR-24: раздел «Документы» с «Товарный чек»');
  let btn = null;
  for (let i = 0; i < 40 && !btn?.x; i++) {
    btn = await ev(A, findRowButton('Товарный чек', 'Просмотр'));
    if (!btn?.x) {
      await ev(A, `window.scrollBy(0, 0)`);
      await sleep(500);
    }
  }
  await shot(A, 'order-details');
  if (!btn?.x) throw new Error(`нет кнопки «Просмотр» в строке «Товарный чек»: ${JSON.stringify(btn)}; ${JSON.stringify((await texts(A)).slice(0, 60))}`);
  R.steps.previewButton = btn;
  const before = await pageState(A);
  await click(A, btn.x, btn.y);
  // ждём: pdf.js загружен и пакет отрисовал хотя бы одну страницу (canvas.toBlob) — или 30 с
  let s1 = null;
  const tPrev = Date.now();
  for (let i = 0; i < 120; i++) {
    s1 = await pageState(A);
    if (s1.toBlob > before.toBlob) break;
    await sleep(250);
  }
  R.steps.previewMs = Date.now() - tPrev;
  await sleep(2500);
  s1 = await pageState(A);
  R.steps.preview = s1;
  R.steps.previewTexts = (await texts(A).catch(() => [])).slice(0, 40);
  R.steps.previewShot = await shot(A, 'receipt-preview');
  const demoStats = s1.pdfjsLib?.demo;
  check('«Просмотр» товарного чека: pdf.js загружен, страница отрисована (canvas.toBlob), без чужих хостов', s1.toBlob > before.toBlob && !!s1.pdfjsLib && (!demoStats || (demoStats.loaded >= 1 && demoStats.errors.length === 0)) && !R.foreign.length, { ms: R.steps.previewMs, toBlob: s1.toBlob, pdfjsLib: s1.pdfjsLib, scripts: s1.pdfjsScripts, foreign: R.foreign.slice(0, 3) });

  // ------------------------------------------------------------ 4. «Печать» товарного чека
  await key(A, 'Escape', 'Escape', 27);
  await sleep(1200);
  await semanticsOn(A).catch(() => undefined);
  let pbtn = null;
  for (let i = 0; i < 20 && !pbtn?.x; i++) {
    pbtn = await ev(A, findRowButton('Товарный чек', 'Печать'));
    if (!pbtn?.x) await sleep(500);
  }
  if (!pbtn?.x) throw new Error(`нет кнопки «Печать» в строке «Товарный чек»: ${JSON.stringify(pbtn)}`);
  const targetsBefore = R.targets.length;
  await click(A, pbtn.x, pbtn.y);
  let s2 = null;
  for (let i = 0; i < 60; i++) {
    s2 = await pageState(A);
    if (s2.printFocus > 0 || s2.anchorClicks.length > before.anchorClicks.length) break;
    await sleep(250);
  }
  await sleep(3000);
  s2 = await pageState(A);
  R.steps.print = s2;
  R.steps.printTexts = (await texts(A).catch(() => [])).filter((t) => /Напечатан|Не удалось|печат/i.test(t)).slice(0, 10);
  R.steps.printTargets = R.targets.slice(targetsBefore);
  await shot(A, 'receipt-print');
  check('«Печать» товарного чека: встроенный скрипт печати пакета выполнен (focus iframe → print), без запасной новой вкладки', s2.printFnDefined && s2.printFocus >= 1 && s2.anchorClicks.length === before.anchorClicks.length && !R.steps.printTargets.some((t) => t.created === 'page'), { printFnDefined: s2.printFnDefined, printFocus: s2.printFocus, frame: s2.printFrame, anchorClicks: s2.anchorClicks, newTargets: R.steps.printTargets, snackbar: R.steps.printTexts });

  // ------------------------------------------------------------ 5. второй предпросмотр (счёт на оплату, A4)
  await semanticsOn(A).catch(() => undefined);
  let ibtn = null;
  for (let i = 0; i < 20 && !ibtn?.x; i++) {
    ibtn = await ev(A, findRowButton('Счёт на оплату', 'Просмотр'));
    if (!ibtn?.x) await sleep(500);
  }
  if (!ibtn?.x) throw new Error(`нет кнопки «Просмотр» в строке «Счёт на оплату»: ${JSON.stringify(ibtn)}`);
  const before3 = await pageState(A);
  await click(A, ibtn.x, ibtn.y);
  let s3 = null;
  for (let i = 0; i < 120; i++) {
    s3 = await pageState(A);
    if (s3.toBlob > before3.toBlob) break;
    await sleep(250);
  }
  await sleep(2500);
  s3 = await pageState(A);
  R.steps.preview2 = s3;
  await shot(A, 'invoice-preview');
  const d3 = s3.pdfjsLib?.demo;
  check('второй «Просмотр» (счёт на оплату): снова отрисован, pdf.js не загружается повторно', s3.toBlob > before3.toBlob && (!d3 || (d3.imports === 1 && d3.documents >= 2 && d3.loaded >= 2 && d3.errors.length === 0)), { toBlob: s3.toBlob, demo: d3 });
  await key(A, 'Escape', 'Escape', 27);
  await sleep(800);

  // ------------------------------------------------------------ общие проверки
  const csp = [];
  for (const [sid, s] of sessions) if (s.type === 'page' || s.type === 'iframe') csp.push(...((await ev({ sid }, `window.__cspViolations || []`, 5000).catch(() => [])) ?? []));
  R.cspPage = csp;
  const log0 = (await (await fetch(`${ORIGIN}/__site/log`)).json()).filter((r) => !(r.m === 'HEAD' && r.p === '/pdfjs/pdf.min.js')); // HEAD — проверка из Node
  R.server = { requests: log0.length, api: log0.filter((r) => /^\/api\//.test(r.p)).length, notFound: [...new Set(log0.filter((r) => r.s === 404).map((r) => r.p))].slice(0, 20), pdfjs: log0.filter((r) => /^\/pdfjs\//.test(r.p)).map((r) => `${r.s} ${r.p}`) };
  check('0 нарушений Content-Security-Policy (securitypolicyviolation в кадрах, Log, Audits)', csp.length === 0 && R.csp.length === 0 && R.cspIssues.length === 0, { page: csp.slice(0, 6), log: R.csp.slice(0, 6), issues: R.cspIssues.slice(0, 6) });
  check('0 запросов на чужие хосты; 0 к /api/ сайта; 0 ответов 404', R.foreign.length === 0 && R.server.api === 0 && R.server.notFound.length === 0, { foreign: R.foreign.slice(0, 6), server: R.server });
  check('0 необработанных исключений', R.exceptions.length === 0, R.exceptions.slice(0, 6));
  const errs = R.consoleErrors.filter((e) => !/dio_web_adapter|PosDemoBridgeError/.test(e.text));
  check('0 ошибок в консоли (кроме известных)', errs.length === 0, errs.slice(0, 8));
} catch (e) {
  R.error = String(e?.stack ?? e);
  console.error(R.error);
  check('прогон без исключения', false, R.error.slice(0, 800));
  try {
    const tab = [...sessions.entries()].find(([, s]) => s.type === 'page');
    if (tab) {
      R.errorState = await pageState({ sid: tab[0] }).catch((x) => String(x));
      await shot({ sid: tab[0] }, 'error').catch(() => undefined);
    }
  } catch {
    /* ignore */
  }
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
  writeFileSync(`${OUT}/pdf-smoke.json`, JSON.stringify(R, null, 1));
  log(`итог: ${R.summary.checks - R.summary.failed}/${R.summary.checks}; ${OUT}/pdf-smoke.json; профиль ${existsSync(PROFILE) ? 'НЕ удалён' : 'удалён'}`);
  process.exit(R.summary.failed ? 1 : 0);
}

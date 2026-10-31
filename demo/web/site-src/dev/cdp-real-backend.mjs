// Оптомстрой POS · веб-демо · страница WP-S1 с НАСТОЯЩИМ backend.js (pos-api на PGlite) вместо имитации.
//
//   node demo/web/site-src/dev/cdp-real-backend.mjs --backend-dir <каталог с backend.js и pglite/> [--port 8097]
//        [--storage opfs|idb|memory] [--init-extra '{"sku":120}'] [--browser chrome|edge]
//
// Проверяет мост страницы на настоящем сервере: холодный старт, /health, OTP 246810 и PIN кассира 906,
// «Продолжить здесь» во второй вкладке (flush + shutdown первой → вторая открывает тот же том PGlite: PIN сохранился —
// повторный POST /me/pin → 403 STEP_UP_REQUIRED), «Сбросить демо» (том стёрт — PIN снова можно задать).
// Flutter — имитация dev/fake-flutter-loader.js. Снимки — D:/optomstroy/.tmp/web_demo/s1_shots/real-*.png.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (name, def) => {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
};
const BACKEND = arg('backend-dir', null);
if (!BACKEND || !existsSync(join(BACKEND, 'backend.js'))) throw new Error('нужен --backend-dir с backend.js');
const PORT = Number(arg('port', 8097));
const STORAGE = arg('storage', 'opfs');
const EXTRA = arg('init-extra', '{"sku":120}');
const BROWSER = arg('browser', 'chrome');
const EXE = BROWSER === 'edge' ? 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' : 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const SHOTS = 'D:/optomstroy/.tmp/web_demo/s1_shots';
const RESULT = `D:/optomstroy/.tmp/web_demo/s1_results-real-${BROWSER}-${STORAGE}.json`;
const PROFILE = `D:/optomstroy/.tmp/web_demo/chrome-s1-real-${Date.now()}`;
const ORIGIN = `http://127.0.0.1:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const log = (...a) => console.log(`${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s`, ...a);
const results = { backend: BACKEND, storage: STORAGE, checks: [], exceptions: [], console: [], timings: {} };
const check = (name, ok, details) => {
  results.checks.push({ name, ok: !!ok, details: details ?? null });
  log(`${ok ? 'OK  ' : 'FAIL'} ${name}${details !== undefined ? ' — ' + JSON.stringify(details).slice(0, 400) : ''}`);
};

let ws;
let mid = 0;
const pend = new Map();
const names = new Map();
function send(method, params = {}, sessionId) {
  return new Promise((resolve, reject) => {
    const id = ++mid;
    pend.set(id, { resolve, reject, method });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
}
async function tab(name) {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId: s } = await send('Target.attachToTarget', { targetId, flatten: true });
  names.set(s, name);
  for (const d of ['Runtime.enable', 'Page.enable']) await send(d, {}, s);
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false }, s);
  await send('Emulation.setFocusEmulationEnabled', { enabled: true }, s);
  await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, s);
  await send('Page.bringToFront', {}, s);
  return { name, targetId, s };
}
async function ev(t, expression, timeoutMs = 60000) {
  const r = await Promise.race([send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true }, t.s), sleep(timeoutMs).then(() => ({ timeout: true }))]);
  if (r.timeout) throw new Error(`timeout: ${expression.slice(0, 80)}`);
  if (r.exceptionDetails) throw new Error(`${r.exceptionDetails.text} ${r.exceptionDetails.exception?.description ?? ''}`);
  return r.result.value;
}
async function waitFor(t, expr, ms, label) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await ev(t, `(function(){try{return !!(${expr});}catch(e){return false;}})()`, 10000).catch(() => false)) return;
    await sleep(150);
  }
  const dump = await ev(t, `JSON.stringify({href: location.href, view: (document.getElementById('loading')||{dataset:{}}).dataset.view, phase: window.__posDemo && __posDemo.phase, fatal: window.__posDemo && __posDemo.fatal, steps: window.PosDemoPage && PosDemoPage.boot ? PosDemoPage.boot.steps.slice(-10) : null, wipe: window.PosDemoPage && PosDemoPage.boot && PosDemoPage.boot.lastWipe, logs: window.__posDemo ? __posDemo._logs.slice(-5) : null, stage: (document.getElementById('pd-stage')||{}).textContent})`, 5000).catch((e) => String(e));
  throw new Error(`waitFor ${label}: ${String(dump).slice(0, 3000)}`);
}
async function click(t, sel) {
  const r = await ev(t, `(function(){var e=document.querySelector(${JSON.stringify(sel)}); if(!e) return null; e.scrollIntoView({block:'center'}); var b=e.getBoundingClientRect(); return {x:b.left+b.width/2, y:b.top+b.height/2};})()`);
  if (!r) throw new Error(`нет ${sel}`);
  for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, x: r.x, y: r.y, button: 'left', clickCount: 1 }, t.s);
}
async function shot(t, name) {
  mkdirSync(SHOTS, { recursive: true });
  await send('Page.bringToFront', {}, t.s);
  await sleep(150);
  const { data } = await send('Page.captureScreenshot', { format: 'png' }, t.s);
  writeFileSync(join(SHOTS, `${name}.png`), Buffer.from(data, 'base64'));
}
const ready = (t, ms = 90000) => waitFor(t, `window.__posDemo && __posDemo.isReady && PosDemoPage.boot.hidden`, ms, 'готово');
// API через мост страницы: те же заголовки, что у веб-сборки (X-App-Version 0.1.0+1, X-Platform windows).
const API = `
  window.__api = async function (method, url, body, headers) {
    const h = Object.assign({'X-Device-Id': window.__dev || (window.__dev = crypto.randomUUID()), 'X-App-Version': '0.1.0+1', 'X-Platform': 'windows', 'Accept-Language': 'ru'}, headers || {});
    if (body !== undefined) h['content-type'] = 'application/json';
    const r = await __posDemo.request({method, url, headers: h, body: body === undefined ? null : JSON.stringify(body)});
    const text = new TextDecoder().decode(r.body);
    let json = null; try { json = JSON.parse(text); } catch (e) {}
    return {status: r.status, json, workerMs: r.workerMs, totalMs: r.totalMs};
  };
  window.__login = async function (phone) {
    const rq = await __api('POST', '/api/v1/auth/otp/request', {phone, purpose: 'login_or_register', locale: 'ru'});
    const vr = await __api('POST', '/api/v1/auth/otp/verify', {challengeId: rq.json && rq.json.challengeId, code: '246810', device: {name: 'Chrome (демо)', platform: 'windows', appVersion: '0.1.0+1'}});
    return {device: window.__dev, rq: rq.status, vr: vr.status, token: vr.json && vr.json.accessToken, rqBody: rq.status >= 300 ? rq.json : null, vrBody: vr.status >= 300 ? vr.json : null};
  };
  window.__setPin = async function (token, pin) {
    return __api('POST', '/api/v1/me/pin', {newPin: pin}, {Authorization: 'Bearer ' + token, 'Idempotency-Key': crypto.randomUUID()});
  };
  true`;

async function main() {
  const server = spawn(process.execPath, [join(HERE, 'serve.mjs'), '--port', String(PORT), '--backend-dir', BACKEND], { stdio: 'ignore' });
  await sleep(800);
  await fetch(`${ORIGIN}/__dev/set-mock?flutterDelayMs=300`);
  mkdirSync(PROFILE, { recursive: true });
  const proc = spawn(EXE, ['--headless=new', '--remote-debugging-port=9445', `--user-data-dir=${PROFILE}`, '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--disable-component-update', '--disable-sync', 'about:blank'], { stdio: 'ignore' });
  let ver;
  for (let i = 0; i < 100 && !ver; i++) {
    try {
      ver = await (await fetch('http://127.0.0.1:9445/json/version')).json();
    } catch {
      await sleep(200);
    }
  }
  results.browserVersion = ver.Browser;
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
    const who = names.get(m.sessionId) || 'browser';
    if (m.method === 'Target.attachedToTarget' && m.params.targetInfo.type === 'worker') {
      names.set(m.params.sessionId, `${who}:worker`);
      void send('Runtime.enable', {}, m.params.sessionId).catch(() => undefined);
    }
    if (m.method === 'Runtime.exceptionThrown') results.exceptions.push({ who, text: `${m.params.exceptionDetails.text} ${m.params.exceptionDetails.exception?.description ?? ''}`.slice(0, 800) });
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') results.console.push({ who, text: m.params.args.map((a) => a.value ?? a.description ?? '').join(' ').slice(0, 500) });
  };
  try {
    const q = `?storage=${STORAGE}&initExtra=${encodeURIComponent(EXTRA)}`;
    const A = await tab('A');
    let t = Date.now();
    await send('Page.navigate', { url: `${ORIGIN}/${q}` }, A.s);
    await ready(A);
    results.timings.coldReadyMs = Date.now() - t;
    const infoA = await ev(A, `({storage: __posDemo.info.storage, startMs: __posDemo.info.startMs, warm: __posDemo.info.warm, gen: __posDemo.info.generation})`);
    check('холодный старт настоящего сервера через страницу', infoA.storage === STORAGE, { ...infoA, pageMs: results.timings.coldReadyMs });
    await shot(A, `real-01-ready-${STORAGE}`);
    await ev(A, API);
    const h = await ev(A, `__api('GET', '/health')`);
    check('GET /health → 200', h.status === 200, h);
    const lg = await ev(A, `__login('+996777000906')`);
    check('OTP 246810 для 906 → accessToken', lg.rq < 300 && lg.vr === 200 && !!lg.token, { rq: lg.rq, vr: lg.vr });
    const pin = await ev(A, `__setPin(${JSON.stringify(lg.token)}, '715382')`);
    check('POST /me/pin (первый PIN) → 2xx', pin.status >= 200 && pin.status < 300, { status: pin.status, ms: pin.totalMs });
    const me = await ev(A, `__api('GET', '/api/v1/me', undefined, {Authorization: 'Bearer ' + ${JSON.stringify(lg.token)}})`);
    check('GET /me → 200', me.status === 200, { status: me.status });

    const B = await tab('B');
    await send('Page.navigate', { url: `${ORIGIN}/${q}` }, B.s);
    await waitFor(B, `(document.getElementById('loading')||{dataset:{}}).dataset.view === 'lock'`, 20000, 'плашка блокировки');
    t = Date.now();
    await click(B, '#pd-lock-takeover');
    await waitFor(A, `location.pathname.endsWith('/demo-closed.html')`, 20000, 'A ушла');
    results.timings.handoverMs = Date.now() - t;
    await ready(B);
    results.timings.takeoverReadyMs = Date.now() - t;
    const infoB = await ev(B, `({warm: __posDemo.info.warm, startMs: __posDemo.info.startMs, lock: PosDemoPage.boot.lockResult})`);
    check('«Продолжить здесь»: вторая вкладка открыла тот же том (тёплый старт), передача штатная', infoB.warm === true && infoB.lock.released === true, { ...infoB, handoverMs: results.timings.handoverMs, readyMs: results.timings.takeoverReadyMs });
    await ev(B, API);
    // Приложение хранит X-Device-Id в хранилище origin — во второй вкладке тот же id (иначе 401 SESSION_REVOKED device_mismatch).
    const devA = lg.device;
    await ev(B, `window.__dev = ${JSON.stringify('__DEV__')}; true`.replace('__DEV__', devA));
    // Токен первой вкладки: сессия, ключ JWT (demo_meta) и PIN должны пережить перенос; повторный OTP — 429 (кулдаун).
    const meB = await ev(B, `__api('GET', '/api/v1/me', undefined, {Authorization: 'Bearer ' + ${JSON.stringify(lg.token)}})`);
    check('сессия первой вкладки жива во второй (GET /me тем же токеном → 200)', meB.status === 200, { status: meB.status, code: meB.json && meB.json.code });
    const pin2 = await ev(B, `__setPin(${JSON.stringify(lg.token)}, '715382')`);
    check('данные первой вкладки на месте: PIN уже задан → 403 STEP_UP_REQUIRED', pin2.status === 403 && pin2.json && pin2.json.code === 'STEP_UP_REQUIRED', { status: pin2.status, code: pin2.json && pin2.json.code });
    await shot(B, `real-02-after-takeover-${STORAGE}`);

    t = Date.now();
    await ev(B, `PosDemoPage.boot.resetDemo('test'); true`);
    await waitFor(B, `window.PosDemoPage && PosDemoPage.boot && PosDemoPage.boot.lastWipe`, 60000, 'очистка');
    await ready(B);
    results.timings.resetReadyMs = Date.now() - t;
    const wipe = await ev(B, `({ok: PosDemoPage.boot.lastWipe.ok, ms: PosDemoPage.boot.lastWipe.ms, idb: PosDemoPage.boot.lastWipe.idb.length, opfs: PosDemoPage.boot.lastWipe.opfs.map(x=>x.name+':'+x.attempts), warm: __posDemo.info.warm})`);
    check('«Сбросить демо» с настоящим PGlite: том стёрт, холодный старт', wipe.ok && wipe.warm === false, { ...wipe, resetReadyMs: results.timings.resetReadyMs });
    await ev(B, API);
    const lgC = await ev(B, `__login('+996777000906')`);
    const pin3 = await ev(B, `__setPin(${JSON.stringify(lgC.token)}, '715382')`);
    check('после сброса PIN задаётся заново (данные чистые)', pin3.status >= 200 && pin3.status < 300, { status: pin3.status });
    check('нет необработанных исключений', results.exceptions.length === 0, results.exceptions.slice(0, 3));
  } catch (e) {
    check('сценарий без исключения', false, String(e.stack || e).slice(0, 1200));
  } finally {
    await Promise.race([send('Browser.close').catch(() => undefined), sleep(3000)]);
    await sleep(800);
    for (const p of [proc, server]) {
      try {
        if (p.exitCode === null) process.kill(p.pid);
      } catch {
        /* ignore */
      }
    }
    await sleep(800);
    for (let i = 0; i < 6; i++) {
      try {
        rmSync(PROFILE, { recursive: true, force: true });
        break;
      } catch {
        await sleep(800);
      }
    }
    writeFileSync(RESULT, JSON.stringify(results, null, 1));
    const failed = results.checks.filter((c) => !c.ok).length;
    log(`итог: ${results.checks.length - failed}/${results.checks.length}; ${RESULT}`);
    process.exitCode = failed ? 1 : 0;
  }
}

main();

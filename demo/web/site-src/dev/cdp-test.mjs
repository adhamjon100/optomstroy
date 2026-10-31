// Оптомстрой POS · веб-демо · headless-проверка страницы WP-S1 с имитацией воркера (без Flutter, без загрузок).
//
//   node demo/web/site-src/dev/cdp-test.mjs [--port 8096] [--cdp 9420] [--browser chrome|edge] [--shots <dir>] [--keep-profile]
//
// --cdp — с какого порта искать свободный порт CDP (по умолчанию 9420; regress:final — чтобы оставаться в своих портах).
//
// Поднимает dev/serve.mjs на 127.0.0.1:<port>, запускает Chrome (или Edge) --headless=new со своим --user-data-dir в
// D:/optomstroy/.tmp/web_demo/chrome-s1-*, управляет им по CDP через глобальный WebSocket Node 24. Снимки — в
// D:/optomstroy/.tmp/web_demo/s1_shots/, итог — D:/optomstroy/.tmp/web_demo/s1_results.json. Завершает только свои
// процессы (по PID) и удаляет профиль.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (name, def) => {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
};
const PORT = Number(arg('port', 8096));
const BROWSER = arg('browser', 'chrome');
const EXE = BROWSER === 'edge' ? 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' : 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const SHOTS = arg('shots', 'D:/optomstroy/.tmp/web_demo/s1_shots');
const RESULT = arg('result', `D:/optomstroy/.tmp/web_demo/s1_results${BROWSER === 'edge' ? '-edge' : ''}.json`);
const PROFILE = `D:/optomstroy/.tmp/web_demo/chrome-s1-${BROWSER}-${Date.now()}`;
const KEEP = arg('keep-profile', false) === true;
const ORIGIN = `http://127.0.0.1:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const log = (...a) => console.log(`${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s`, ...a);

const results = { browser: BROWSER, startedAt: new Date().toISOString(), checks: [], console: [], exceptions: [], requests: [], shots: [] };
function check(name, ok, details) {
  results.checks.push({ name, ok: !!ok, details: details === undefined ? null : details });
  log(`${ok ? 'OK  ' : 'FAIL'} ${name}${details !== undefined ? ' — ' + JSON.stringify(details).slice(0, 300) : ''}`);
  return !!ok;
}

function freePort(start) {
  return new Promise((resolve) => {
    const tryPort = (p) => {
      const s = net.createServer();
      s.once('error', () => tryPort(p + 1));
      s.listen(p, '127.0.0.1', () => s.close(() => resolve(p)));
    };
    tryPort(start);
  });
}

class CDP {
  constructor(url) {
    this.url = url;
    this.id = 0;
    this.pending = new Map();
    this.handlers = [];
  }
  open() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => resolve();
      this.ws.onerror = (e) => reject(e);
      this.ws.onmessage = (ev) => {
        const m = JSON.parse(ev.data);
        if (m.id) {
          const p = this.pending.get(m.id);
          if (!p) return;
          this.pending.delete(m.id);
          if (m.error) p.reject(new Error(`${p.method}: ${m.error.message} ${m.error.data ?? ''}`));
          else p.resolve(m.result);
        } else for (const h of this.handlers) h(m);
      };
    });
  }
  send(method, params = {}, sessionId) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject, method }));
  }
  on(fn) {
    this.handlers.push(fn);
  }
}

let cdp;
const tabs = new Map(); // sessionId → name
let frontTab = null;
async function front(tab) {
  if (frontTab === tab.s) return;
  await cdp.send('Page.bringToFront', {}, tab.s).catch(() => undefined);
  frontTab = tab.s;
  await sleep(150);
}
async function openTab(name, { w = 1280, h = 800, mobile = false, ua = null, uaMeta = null } = {}) {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank', newWindow: false });
  const { sessionId: s } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  tabs.set(s, name);
  for (const d of ['Runtime.enable', 'Page.enable', 'Network.enable']) await cdp.send(d, {}, s);
  await cdp.send('Network.setCacheDisabled', { cacheDisabled: true }, s);
  await cdp.send('Emulation.setFocusEmulationEnabled', { enabled: true }, s);
  await cdp.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, s);
  await setViewport({ s }, w, h, mobile);
  await front({ s });
  if (ua) await cdp.send('Emulation.setUserAgentOverride', { userAgent: ua, ...(uaMeta ? { userAgentMetadata: uaMeta } : {}) }, s);
  return { name, targetId, s };
}
async function setViewport(tab, w, h, mobile = false) {
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile }, tab.s);
  if (mobile) await cdp.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 }, tab.s);
}
async function navigate(tab, url) {
  await cdp.send('Page.navigate', { url }, tab.s);
}
async function ev(tab, expression, timeoutMs = 20000) {
  const r = await Promise.race([
    cdp.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true }, tab.s),
    sleep(timeoutMs).then(() => {
      throw new Error(`timeout: ${expression.slice(0, 100)}`);
    }),
  ]);
  if (r.exceptionDetails) throw new Error(`evaluate: ${r.exceptionDetails.text} ${r.exceptionDetails.exception?.description ?? ''} :: ${expression.slice(0, 120)}`);
  return r.result.value;
}
async function waitFor(tab, expression, timeoutMs = 20000, label = expression) {
  const end = Date.now() + timeoutMs;
  let last;
  while (Date.now() < end) {
    try {
      last = await ev(tab, `(function(){try{return !!(${expression});}catch(e){return false;}})()`, 5000);
      if (last) return true;
    } catch (e) {
      last = String(e.message);
    }
    await sleep(100);
  }
  const dump = await ev(tab, `JSON.stringify({href: location.href, view: (document.getElementById('loading')||{dataset:{}}).dataset.view, steps: window.PosDemoPage && PosDemoPage.boot ? PosDemoPage.boot.steps.slice(-8) : null, lock: window.PosDemoPage && PosDemoPage.lock ? PosDemoPage.lock.log.slice(-6) : null, vis: document.visibilityState})`, 3000).catch((e) => String(e));
  throw new Error(`waitFor timeout (${timeoutMs} ms): ${label} (last=${last}) ${String(dump).slice(0, 1500)}`);
}
async function shot(tab, name) {
  mkdirSync(SHOTS, { recursive: true });
  // Фоновая вкладка headless не рисует кадры — снимок ждал бы минуты.
  await front(tab);
  const { data } = await Promise.race([
    cdp.send('Page.captureScreenshot', { format: 'png' }, tab.s),
    sleep(20000).then(() => {
      throw new Error(`снимок ${name}: нет кадра за 20 с`);
    }),
  ]);
  const file = join(SHOTS, `${name}.png`);
  writeFileSync(file, Buffer.from(data, 'base64'));
  results.shots.push(file);
  log(`снимок ${file}`);
}
async function rect(tab, selector) {
  return ev(tab, `(function(){var e=document.querySelector(${JSON.stringify(selector)}); if(!e) return null; var r=e.getBoundingClientRect(); return {x:r.left,y:r.top,w:r.width,h:r.height};})()`);
}
async function click(tab, selector) {
  await ev(tab, `(function(){var e=document.querySelector(${JSON.stringify(selector)}); if(e) e.scrollIntoView({block:'center'}); return !!e;})()`);
  const r = await rect(tab, selector);
  if (!r) throw new Error(`нет элемента ${selector}`);
  const x = r.x + r.w / 2;
  const y = r.y + r.h / 2;
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, tab.s);
  await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 }, tab.s);
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 }, tab.s);
}
const KEYS = { Escape: { code: 'Escape', vk: 27 }, Backspace: { code: 'Backspace', vk: 8 }, Enter: { code: 'Enter', vk: 13, text: '\r' }, Tab: { code: 'Tab', vk: 9 } };
async function key(tab, k) {
  const d = KEYS[k];
  if (d) {
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code: d.code, windowsVirtualKeyCode: d.vk, nativeVirtualKeyCode: d.vk, ...(d.text ? { text: d.text } : {}) }, tab.s);
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code: d.code, windowsVirtualKeyCode: d.vk, nativeVirtualKeyCode: d.vk }, tab.s);
    return;
  }
  for (const ch of k) {
    const vk = ch.toUpperCase().charCodeAt(0);
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: ch, text: ch, unmodifiedText: ch, windowsVirtualKeyCode: vk }, tab.s);
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: ch, windowsVirtualKeyCode: vk }, tab.s);
  }
}
const devGet = async (path) => (await fetch(`${ORIGIN}${path}`)).json();
const view = (tab) => ev(tab, `(document.getElementById('loading')||{dataset:{}}).dataset.view || (document.getElementById('loading') ? '' : 'gone')`);
const appReady = (tab, ms = 30000) => waitFor(tab, `window.__posDemo && __posDemo.isReady && PosDemoPage.boot.hidden && document.getElementById('pos-demo-fab')`, ms, 'приложение готово, экран загрузки скрыт');
const req = (tab, js) => ev(tab, `(async()=>{try{const r=await __posDemo.request(${js});return {status:r.status,headers:r.headers,len:r.body.length,text:new TextDecoder().decode(r.body),queuedMs:r.queuedMs};}catch(e){return {error:e.code||String(e),message:e.message};}})()`);
const ordersCount = async (tab) => {
  const r = await req(tab, `{method:'GET',url:'/api/v1/demo-mock/orders'}`);
  return r.status === 200 ? JSON.parse(r.text).items.length : r;
};
const postOrder = (tab, payment = 'cash') => req(tab, `{method:'POST',url:'/api/v1/demo-mock/orders',headers:[['content-type','application/json']],body:JSON.stringify({total:'1250.00',payment:${JSON.stringify(payment)}})}`);

// Навигация приложения не перекрыта: центр каждого [data-nav] и FAB экрана — сам элемент (а не панель или «ДЕМО»).
async function navFree(tab, withFab = true) {
  return ev(tab, `(function(){
    var out = [];
    document.querySelectorAll(${JSON.stringify(withFab ? '#stub-app [data-nav], #stub-fab' : '#stub-app [data-nav]')}).forEach(function(n){
      var r = n.getBoundingClientRect(); if (!r.width || !r.height) return;
      if (n.dataset.nav === 'header' || n.dataset.nav === 'bottom') return;
      var pts = [[r.left + r.width*0.5, r.top + r.height*0.5], [r.left + r.width*0.3, r.top + r.height*0.3], [r.left + r.width*0.7, r.top + r.height*0.7]];
      var ok = pts.every(function(p){ var e = document.elementFromPoint(p[0], p[1]); return e && (e === n || n.contains(e)); });
      out.push({nav: n.dataset.nav || n.id, ok: ok});
    });
    var fab = document.getElementById('pos-demo-fab'); var fr = fab && fab.getBoundingClientRect();
    var bars = Array.prototype.map.call(document.querySelectorAll('#stub-app [data-nav="header"], #stub-app [data-nav="bottom"], #stub-fab'), function(n){ var r=n.getBoundingClientRect(); return {id:n.dataset.nav||n.id, l:r.left,t:r.top,r:r.right,b:r.bottom, w:r.width}; }).filter(function(b){return b.w>0;});
    var inter = function(a, b){ return a.l < b.right && b.left < a.r && a.t < b.bottom && b.top < a.b; };
    var panel = document.getElementById('pos-demo-panel'); var pr = panel && !panel.hidden ? panel.getBoundingClientRect() : null;
    return {
      items: out,
      allFree: out.every(function(x){return x.ok;}),
      fabOverlaps: fr && fr.width ? bars.filter(function(b){ return inter(b, fr); }).map(function(b){return b.id;}) : [],
      panelOverlaps: pr ? bars.filter(function(b){ return b.id !== 'stub-fab' && inter(b, pr); }).map(function(b){return b.id;}) : [],
      fab: fr ? {l:fr.left,t:fr.top,w:fr.width,h:fr.height} : null,
      panel: pr ? {l:pr.left,t:pr.top,w:pr.width,h:pr.height} : null,
    };
  })()`);
}

async function main() {
  if (!existsSync(EXE)) throw new Error(`нет браузера ${EXE}`);
  mkdirSync(SHOTS, { recursive: true });
  const server = spawn(process.execPath, [join(HERE, 'serve.mjs'), '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
  results.serverPid = server.pid;
  server.stderr.on('data', (d) => log('serve stderr:', String(d).trim()));
  for (let i = 0; i < 50; i++) {
    try {
      await devGet('/__dev/state');
      break;
    } catch {
      await sleep(100);
    }
  }
  const cdpPort = await freePort(Number(arg('cdp', 9420)));
  mkdirSync(PROFILE, { recursive: true });
  const proc = spawn(EXE, [
    '--headless=new', `--remote-debugging-port=${cdpPort}`, `--user-data-dir=${PROFILE}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-background-networking',
    '--disable-component-update', '--disable-sync', '--disable-default-apps', '--disable-features=Translate,MediaRouter,OptimizationHints',
    '--window-size=1280,800', 'about:blank',
  ], { stdio: 'ignore' });
  results.browserPid = proc.pid;
  log(`${BROWSER} pid ${proc.pid}, CDP ${cdpPort}, сервер pid ${server.pid} ${ORIGIN}`);
  let ver;
  for (let i = 0; i < 100; i++) {
    try {
      ver = await (await fetch(`http://127.0.0.1:${cdpPort}/json/version`)).json();
      break;
    } catch {
      await sleep(200);
    }
  }
  if (!ver) throw new Error('CDP не поднялся');
  results.browserVersion = ver.Browser;
  cdp = new CDP(ver.webSocketDebuggerUrl);
  await cdp.open();
  cdp.on((m) => {
    const who = tabs.get(m.sessionId) || m.sessionId || 'browser';
    if (m.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(m.params.type)) {
      const text = m.params.args.map((a) => a.value ?? a.description ?? '').join(' ');
      results.console.push({ tab: who, type: m.params.type, text: text.slice(0, 600) });
    }
    if (m.method === 'Runtime.exceptionThrown') {
      const d = m.params.exceptionDetails;
      results.exceptions.push({ tab: who, text: `${d.text} ${d.exception?.description ?? ''}`.slice(0, 1000) });
    }
    if (m.method === 'Network.requestWillBeSent') results.requests.push({ tab: who, url: m.params.request.url });
    if (m.method === 'Target.attachedToTarget' && m.params.targetInfo.type === 'worker') {
      tabs.set(m.params.sessionId, `${who}:worker`);
      void cdp.send('Runtime.enable', {}, m.params.sessionId).catch(() => undefined);
      void cdp.send('Network.enable', {}, m.params.sessionId).catch(() => undefined);
    }
  });
  await cdp.send('Browser.grantPermissions', { permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'], origin: ORIGIN }).catch((e) => log('clipboard permission:', e.message));
  try {
    await scenario();
  } catch (e) {
    check('сценарий завершился без исключения', false, String(e.stack || e).slice(0, 1500));
  } finally {
    results.server = await devGet('/__dev/state').catch(() => null);
    results.finishedAt = new Date().toISOString();
    await Promise.race([cdp.send('Browser.close').catch(() => undefined), sleep(3000)]);
    await sleep(800);
    for (const p of [proc, server]) {
      try {
        if (p.exitCode === null) process.kill(p.pid);
      } catch {
        /* ignore */
      }
    }
    await sleep(800);
    if (!KEEP) {
      for (let i = 0; i < 6; i++) {
        try {
          rmSync(PROFILE, { recursive: true, force: true });
          break;
        } catch {
          await sleep(800);
        }
      }
    }
    const failed = results.checks.filter((c) => !c.ok);
    results.summary = { checks: results.checks.length, failed: failed.length, exceptions: results.exceptions.length, consoleErrors: results.console.filter((c) => c.type === 'error').length };
    writeFileSync(RESULT, JSON.stringify(results, null, 1));
    log(`итог: ${results.checks.length - failed.length}/${results.checks.length} проверок, исключений ${results.exceptions.length}; ${RESULT}`);
    process.exitCode = failed.length ? 1 : 0;
  }
}

async function scenario() {
  // ------------------------------------------------------------ 1. загрузка 1280×800, очередь до ready
  await fetch(`${ORIGIN}/__dev/set-mock?initDelayMs=2500&flutterDelayMs=500&fatal=0&fenceCheck=1`);
  const A = await openTab('A');
  await navigate(A, `${ORIGIN}/`);
  await waitFor(A, `window.__posDemo && __posDemo.phase === 'starting'`, 15000, 'воркер запускается');
  await ev(A, `window.__early = __posDemo.request({id:'early-1', method:'GET', url:'/health', onStart: function(){ window.__earlyStarted = true; }}).then(function(r){return {status:r.status, queuedMs:r.queuedMs};}, function(e){return {error:e.code};}); true`);
  await sleep(500);
  await shot(A, '01-loading-1280x800');
  check('экран загрузки: вид loading и этапы', (await view(A)) === 'loading', await ev(A, `document.getElementById('pd-stage').textContent`));
  await appReady(A);
  const early = await ev(A, `window.__early`);
  check('запрос до готовности воркера ждёт в очереди и выполняется после ready', early.status === 200 && early.queuedMs > 200, early);
  check('onStart вызван (http:start)', await ev(A, `!!window.__earlyStarted`));
  check('init содержит generation, storage, dbName, epochKey', await ev(A, `(async()=>{const d=await __posDemo.control('GET debug'); const o=d.opts; return !!(o && o.generation>=1 && o.storage && o.dbName && o.epochKey==='dev-epoch-1' && o.opts && o.opts.pgliteBase);})()`));
  await shot(A, '02-app-1280x800');
  let nf = await navFree(A);
  check('1280×800: «ДЕМО» не перекрывает навигацию и FAB экрана', nf.allFree && nf.fabOverlaps.length === 0, nf);

  // ------------------------------------------------------------ 2. мост: адреса, тело, отмена
  const h = await req(A, `{method:'GET', url: location.origin + '/api/v1/health', headers:{accept:'application/json'}}`);
  check('request: абсолютный адрес того же origin → 200 JSON', h.status === 200 && /"ok"/.test(h.text) && h.headers.some((p) => p[0] === 'content-type'), h);
  const foreign = await req(A, `{method:'GET', url:'https://example.com/api/v1/health'}`);
  check('request: чужой origin → bad_request без отправки', foreign.error === 'bad_request', foreign);
  const ctl = await req(A, `{method:'GET', url:'/__demo/state'}`);
  check('request: /__demo/* через request запрещён', ctl.error === 'bad_request', ctl);
  const copy = await ev(A, `(async()=>{const big=new Uint8Array(64); for(let i=0;i<64;i++) big[i]=i; const view=big.subarray(8,24); const r=await __posDemo.request({method:'POST', url:'/api/v1/demo-mock/echo', body: view}); return {len:r.body.length, first:r.body[0], last:r.body[15], bufLen: big.buffer.byteLength, viewLen: view.length};})()`);
  check('тело копируется: буфер вызывающего не отсоединён, байты дошли', copy.len === 16 && copy.first === 8 && copy.last === 23 && copy.bufLen === 64 && copy.viewLen === 16, copy);
  const canc = await ev(A, `(async()=>{const p=__posDemo.request({id:'slow-1', method:'GET', url:'/api/v1/demo-mock/slow?ms=4000'}); await new Promise(r=>setTimeout(r,200)); const t=performance.now(); __posDemo.cancel('slow-1'); try{await p; return {error:'resolved'};}catch(e){return {code:e.code, ms: performance.now()-t};}})()`);
  const dbg = await ev(A, `__posDemo.control('GET debug').then(d=>d.log.filter(x=>x.type==='cancelled').map(x=>x.id))`);
  check('cancel: промис → cancelled сразу, воркер получил http:cancel', canc.code === 'cancelled' && canc.ms < 100 && dbg.includes('slow-1'), { canc, dbg });

  // ------------------------------------------------------------ 3. панель 1280×800: «Как войти», копирование
  await click(A, '#pos-demo-fab');
  await waitFor(A, `PosDemoPage.panel.isOpen`, 3000);
  await sleep(300);
  await shot(A, '03-panel-login-1280x800');
  const login = await ev(A, `document.getElementById('pd-sec-login').innerText`);
  const phones = ['+996 777 000 902', '+996 777 000 907', '+996 777 000 906', '+996 777 000 901', '+996 777 000 909', '+996 777 000 905', '+996 777 000 903', '+996 700 000 101', '+996 777 000 904'];
  const roleOrder = await ev(A, `Array.prototype.map.call(document.querySelectorAll('#pd-login-roles .pd-phone'), e=>e.textContent)`);
  check('«Как войти»: роли и телефоны в порядке plan §3.6', JSON.stringify(roleOrder) === JSON.stringify(phones), roleOrder);
  check('«Как войти»: код 246810, PIN 715382, 111111 и 123456', /246810/.test(login) && /715382/.test(login) && /111111/.test(login) && /123456/.test(login));
  check('«Как войти»: подписи ролей', ['Продавец (по приглашению)', 'Старший продавец', 'Кассир', 'Администратор', 'Руководитель', 'Новый покупатель', 'Покупатель с карточкой «1С»', 'Свободный номер для приглашения'].every((s) => login.includes(s)));
  const cust = await ev(A, `Array.prototype.map.call(document.querySelectorAll('#pd-login-customers li'), e=>e.innerText.replace(/\\s+/g,' '))`);
  // Метка — слово для поиска по имени, рядом полный номер (поиск по 4 цифрам у продавца не работает — ui:A uiA-09).
  check('тестовые клиенты: «Просрочка», «Долг в лимите», «Лимит превышен», «Без долга» с полным номером — имена из pii-map', cust.length === 4 && /^Просрочка Покупатель Просрочка \(тест\) \+996 700 000 102/.test(cust[0]) && /^Долг в лимите Покупатель Долг в лимите \(тест\) \+996 700 000 101/.test(cust[1]) && /^Лимит превышен ОсОО Лимит превышен \(тест\) \+996 700 000 104/.test(cust[2]) && /^Без долга ОсОО Без долга \(тест\) \+996 700 000 103/.test(cust[3]), cust);
  nf = await navFree(A, false);
  check('1280×800: открытая панель не перекрывает навигацию (шапка: меню, корзина, профиль)', nf.allFree && nf.panelOverlaps.length === 0, nf);
  await click(A, '.pd-code .pd-copy');
  await sleep(300);
  let clip = await ev(A, `navigator.clipboard.readText().catch(e=>'ERR '+e.message)`);
  check('«Скопировать» код → буфер обмена 246810', clip === '246810', clip);
  await click(A, '#pd-login-roles li:nth-child(3) .pd-copy');
  await sleep(300);
  clip = await ev(A, `navigator.clipboard.readText().catch(e=>'ERR '+e.message)`);
  check('«Скопировать номер» кассира → +996777000906', clip === '+996777000906', clip);

  // ------------------------------------------------------------ 4. клавиатура: ввод в панели не доходит до «Flutter»
  await click(A, '#pd-sec-qr > summary');
  await waitFor(A, `document.getElementById('pd-sec-qr').open`, 2000);
  await click(A, '#pd-qr-polls');
  await ev(A, `(function(){var e=document.getElementById('pd-qr-polls'); e.focus(); e.select(); return true;})()`);
  const k0 = await ev(A, `__stub.keys.length`);
  await key(A, 'Backspace');
  await key(A, '7');
  await sleep(150);
  const k1 = await ev(A, `({n: __stub.keys.length, v: document.getElementById('pd-qr-polls').value, focus: document.activeElement && document.activeElement.id})`);
  check('ввод в поле панели работает, а слушатель «Flutter» на window (захват) клавиш не получил', k1.n === k0 && k1.v === '7' && k1.focus === 'pd-qr-polls', { k0, k1 });
  await key(A, 'Escape');
  await sleep(150);
  const k2 = await ev(A, `({open: PosDemoPage.panel.isOpen, n: __stub.keys.length, focus: document.activeElement && document.activeElement.id, esc: __stub.keys.filter(k=>k.key==='Escape').length})`);
  check('Esc в панели закрывает её, «Flutter» Esc не видит, фокус — на «ДЕМО»', !k2.open && k2.n === k0 && k2.esc === 0 && k2.focus === 'pos-demo-fab', k2);
  await click(A, '#stub-input');
  await key(A, 'a');
  await sleep(100);
  const k3 = await ev(A, `__stub.keys.filter(k=>k.target==='stub-input').length`);
  check('вне панели клавиши доходят до «Flutter»', k3 >= 2, k3);
  await click(A, '#pos-demo-fab');
  await waitFor(A, `PosDemoPage.panel.isOpen`, 2000);
  await click(A, '#stub-input');
  await key(A, 'Escape');
  await sleep(150);
  const k4 = await ev(A, `({open: PosDemoPage.panel.isOpen, esc: __stub.keys.filter(k=>k.key==='Escape').length})`);
  check('Esc при открытой панели и фокусе в приложении закрывает панель, приложению не доходит', !k4.open && k4.esc === 0, k4);

  // ------------------------------------------------------------ 5. QR и «1С» в панели
  await postOrder(A, 'qr');
  await postOrder(A, 'cash');
  await ev(A, `__posDemo.control('POST qr/config', {paidAfterPolls: 0})`);
  await click(A, '#pos-demo-fab');
  await waitFor(A, `document.querySelector('#pd-qr-list [data-act="qr-pay"]')`, 6000, 'QR в списке «Ожидают оплаты»');
  await shot(A, '04-panel-qr-1280x800');
  await click(A, '#pd-qr-list [data-act="qr-pay"]');
  await waitFor(A, `/Нет QR, ожидающих оплаты/.test(document.getElementById('pd-qr-list').textContent)`, 6000, 'QR оплачен');
  const qrSt = await ev(A, `__posDemo.control('GET state').then(s=>({pending:s.qr.pending.length, statuses:s.orders.map(o=>o.status)}))`);
  check('«Оплатить сейчас» → QR оплачен, заказ paid', qrSt.pending === 0 && qrSt.statuses.includes('paid') && !qrSt.statuses.includes('awaiting_payment'), qrSt);
  await click(A, '#pd-sec-onec > summary');
  await waitFor(A, `document.querySelector('#pd-onec-orders [data-act="approve"]')`, 6000);
  await click(A, '#pd-onec-down');
  await waitFor(A, `__posDemo.control('GET state').then(s=>s.onec.down)`, 4000, '1С недоступна');
  await click(A, '#pd-onec-down');
  await click(A, '#pd-onec-reject');
  await waitFor(A, `document.getElementById('pd-onec-reject-cancel')`, 6000, 'режим «отклонить следующий»');
  await click(A, '#pd-onec-orders li:first-child [data-act="approve"]');
  await sleep(500);
  await click(A, '#pd-onec-orders li:first-child [data-act="ship"]');
  await waitFor(A, `document.querySelector('#pd-onec-orders li:first-child [data-act="return"]:not([disabled])')`, 6000, 'возврат доступен после отгрузки');
  await shot(A, '05-panel-onec-1280x800');
  await click(A, '#pd-onec-orders li:first-child [data-act="return"]');
  await sleep(600);
  const onecSt = await ev(A, `__posDemo.control('GET state').then(s=>({down:s.onec.down, mode:s.onec.orderMode, failNext:s.onec.failNext, first:{onec:s.orders[0].onecStatus, approved:s.orders[0].approved, shipped:s.orders[0].shipped}, returns:s.returns.map(r=>r.status)}))`);
  check('«1С»: недоступна вкл/выкл, «Отклонить следующий», «Согласовать», «Отгрузить», «Выполнить возврат»', !onecSt.down && onecSt.mode === 'reject' && onecSt.failNext === 1 && onecSt.first.onec === 'КВыполнению' && onecSt.first.approved && onecSt.first.shipped && onecSt.returns.includes('completed'), onecSt);
  await ev(A, `__posDemo.control('POST onec/orders/mode', {mode:'accept', failNext:0})`);

  // ------------------------------------------------------------ 6. «Нет сети»
  await click(A, '#pd-sec-net > summary');
  await waitFor(A, `document.getElementById('pd-sec-net').open`, 2000);
  await click(A, '#pd-offline');
  await sleep(200);
  const off = await ev(A, `(async()=>{const r=await __posDemo.request({method:'GET',url:'/health'}).then(()=>'ok',e=>e.code); return {onLine: navigator.onLine, net: __stub.net.slice(), req: r, bridge: __posDemo.offline, dot: document.getElementById('pos-demo-fab').dataset.offline};})()`);
  check('«Нет сети»: navigator.onLine=false, событие offline на window, запрос → offline', off.onLine === false && off.net.join() === 'offline' && off.req === 'offline' && off.bridge === true && off.dot === '1', off);
  await shot(A, '06-panel-offline-1280x800');
  await click(A, '#pd-offline');
  await sleep(200);
  const on = await ev(A, `({onLine: navigator.onLine, net: __stub.net.slice(), bridge: __posDemo.offline})`);
  check('сеть обратно: navigator.onLine=true, событие online', on.onLine === true && on.net.join() === 'offline,online' && on.bridge === false, on);
  await key(A, 'Escape');

  // ------------------------------------------------------------ 7. 390×844
  await setViewport(A, 390, 844, false);
  await sleep(400);
  await shot(A, '07-app-390x844');
  nf = await navFree(A);
  check('390×844: «ДЕМО» не перекрывает нижнюю навигацию, шапку и FAB', nf.allFree && nf.fabOverlaps.length === 0, nf);
  await click(A, '#pos-demo-fab');
  await waitFor(A, `PosDemoPage.panel.isOpen`, 2000);
  await sleep(300);
  await shot(A, '08-panel-390x844');
  nf = await navFree(A, false);
  check('390×844: открытая панель не перекрывает нижнюю навигацию и шапку', nf.allFree && nf.panelOverlaps.length === 0, nf);
  await key(A, 'Escape');
  await sleep(150);
  check('390×844: Esc закрывает панель', !(await ev(A, `PosDemoPage.panel.isOpen`)));
  await setViewport(A, 1280, 800, false);

  // ------------------------------------------------------------ 8. вторая вкладка, «Продолжить здесь»
  const before = await ordersCount(A);
  const B = await openTab('B');
  await navigate(B, `${ORIGIN}/`);
  await waitFor(B, `(document.getElementById('loading')||{dataset:{}}).dataset.view === 'lock'`, 15000, 'плашка блокировки во второй вкладке');
  await shot(B, '09-second-tab-lock');
  check('вторая вкладка: «Демо уже открыто в другой вкладке» и «Продолжить здесь»', /Демо уже открыто в другой вкладке/.test(await ev(B, `document.getElementById('loading').innerText`)) && !!(await rect(B, '#pd-lock-takeover')));
  check('вторая вкладка не запускает воркер и Flutter, пока ждёт', (await ev(B, `__posDemo.phase`)) === 'idle' && !(await ev(B, `!!document.getElementById('stub-app')`)));
  await click(B, '#pd-lock-takeover');
  await waitFor(A, `location.pathname.endsWith('/demo-closed.html')`, 10000, 'первая вкладка ушла на demo-closed.html');
  await appReady(B, 30000);
  const aUrl = await ev(A, `location.search`);
  const aHasFlutter = await ev(A, `!!document.getElementById('stub-app') || typeof window.__posDemo !== 'undefined'`);
  await shot(A, '10-first-tab-closed');
  check('первая вкладка: location.replace на статическую страницу без Flutter и моста', aUrl === '?reason=moved' && !aHasFlutter, { aUrl, aHasFlutter });
  const bCount = await ordersCount(B);
  check('«Продолжить здесь»: данные перенесены без потерь', bCount === before, { before, bCount });
  const bLock = await ev(B, `PosDemoPage.boot.lockResult`);
  check('передача — штатная (released), без steal', bLock.released === true && !bLock.stolen, bLock);
  const bGen = await ev(B, `({gen: PosDemoPage.lock.generation, ls: localStorage.getItem('optomstroy.demo.generation')})`);
  check('новое поколение тома у второй вкладки (localStorage и fence)', bGen.gen >= 2 && String(bGen.gen) === bGen.ls && (await ev(B, `PosDemoPage.lock.readFence().then(f=>f&&f.generation)`)) === bGen.gen, bGen);
  await postOrder(B, 'cash');
  const bCount2 = await ordersCount(B);
  await cdp.send('Target.closeTarget', { targetId: A.targetId });

  // ------------------------------------------------------------ 9. «Продолжить здесь» при замороженной вкладке
  await fetch(`${ORIGIN}/__dev/set-mock?fenceCheck=0`); // проверяем fencing страницы, без страховки воркера
  // «Заморозка»: Debugger.pause останавливает главный поток страницы на первом же обработчике (сообщение release),
  // как Chrome Memory Saver / заморозка фоновой вкладки; воркер страницы при этом не останавливается.
  const frozenBy = 'debugger';
  await cdp.send('Debugger.enable', {}, B.s);
  await cdp.send('Debugger.pause', {}, B.s);
  log(`вкладка B заморожена (${frozenBy})`);
  const C = await openTab('C');
  await navigate(C, `${ORIGIN}/`);
  await waitFor(C, `(document.getElementById('loading')||{dataset:{}}).dataset.view === 'lock'`, 15000, 'плашка блокировки в третьей вкладке');
  const tTake = Date.now();
  await click(C, '#pd-lock-takeover');
  await appReady(C, 30000);
  const cLock = await ev(C, `PosDemoPage.boot.lockResult`);
  check('замороженная вкладка: через ~3 с steal, новая вкладка работает', cLock.stolen === true && Date.now() - tTake >= 2900, { cLock, ms: Date.now() - tTake, frozenBy });
  const cCount = await ordersCount(C);
  check('замороженная вкладка: данные на месте', cCount === bCount2, { cCount, bCount2 });
  await postOrder(C, 'cash');
  const cCount2 = await ordersCount(C);
  await cdp.send('Debugger.resume', {}, B.s);
  await cdp.send('Debugger.disable', {}, B.s).catch(() => undefined);
  await waitFor(B, `location.pathname.endsWith('/demo-closed.html')`, 10000, 'размороженная вкладка ушла на demo-closed.html');
  const bReason = await ev(B, `location.search`);
  await sleep(1500);
  const persisted = await ev(C, `(async()=>{const name='optomstroy-mock-'+PosDemoPage.boot.storage.dbName; const db=await new Promise((res,rej)=>{const r=indexedDB.open(name,1); r.onsuccess=()=>res(r.result); r.onerror=()=>rej(r.error);}); const st=await new Promise(res=>{const g=db.transaction('kv').objectStore('kv').get('state'); g.onsuccess=()=>res(g.result);}); db.close(); return st.orders.length;})()`);
  check('размороженная вкладка не записала устаревшее состояние (fencing страницы)', /reason=(stolen|generation)/.test(bReason) && persisted === cCount2, { bReason, persisted, cCount2 });
  await shot(B, '11-frozen-tab-closed');
  await cdp.send('Target.closeTarget', { targetId: B.targetId });
  await fetch(`${ORIGIN}/__dev/set-mock?fenceCheck=1`);

  // ------------------------------------------------------------ 10. «Сбросить демо» с занятыми соединениями
  const H = await openTab('H');
  await navigate(H, `${ORIGIN}/dev/holder.html`);
  await waitFor(H, `window.__holder`, 10000);
  check('держатель открыл IndexedDB drift-like-db', await ev(H, `__holder.openDb()`));
  check('держатель взял OPFS sync access handle', await ev(H, `__holder.lockOpfs()`));
  await ev(C, `(async()=>{localStorage.setItem('flutter.test','1'); sessionStorage.setItem('s','1'); const c=await caches.open('demo-test'); await c.put('/x', new Response('1')); const d=await navigator.storage.getDirectory(); const f=await d.getFileHandle('drift-test.sqlite',{create:true}); const w=await f.createWritable(); await w.write('abc'); await w.close(); return true;})()`);
  await click(C, '#pos-demo-fab');
  await waitFor(C, `PosDemoPage.panel.isOpen`, 2000);
  await click(C, '#pd-sec-service > summary');
  await click(C, '#pd-reset');
  await waitFor(C, `!document.getElementById('pd-reset-confirm').hidden`, 2000);
  await shot(C, '12-reset-confirm');
  await ev(H, `__holder.releaseOpfsAfter(4000); true`);
  await click(C, '#pd-reset-yes');
  await waitFor(C, `window.PosDemoPage && PosDemoPage.boot && PosDemoPage.boot.lastWipe`, 30000, 'после перезагрузки выполнена очистка');
  await appReady(C, 40000);
  const wipe = await ev(C, `PosDemoPage.boot.lastWipe`);
  const drift = wipe.idb.find((x) => x.name === 'drift-like-db');
  const lockedFile = wipe.opfs.find((x) => x.name === 'holder-locked.bin');
  check('сброс: drift-like-db удалена после blocked (повтор)', drift && drift.ok && drift.blocked, drift);
  check('сброс: файл OPFS с открытым handle удалён повтором', lockedFile && lockedFile.ok && lockedFile.attempts > 1, lockedFile);
  const after = await ev(C, `(async()=>{const d=await navigator.storage.getDirectory(); const names=[]; for await (const k of d.keys()) names.push(k); return {ls: localStorage.getItem('flutter.test'), ss: sessionStorage.getItem('s'), caches: await caches.keys(), opfs: names, dbs: (await indexedDB.databases()).map(x=>x.name), leftovers: PosDemoPage.boot.lastWipe.leftovers, url: location.href};})()`);
  check('сброс: localStorage, sessionStorage, Cache Storage, OPFS очищены; адрес без ?reset', after.ls === null && after.ss === null && after.caches.length === 0 && after.opfs.length === 0 && after.leftovers.length === 0 && !/reset=/.test(after.url), after);
  const cAfter = await ordersCount(C);
  check('сброс: демо начинается с чистыми данными', cAfter === 0, cAfter);
  check('сброс выполнен до запуска воркера и Flutter', await ev(C, `(function(){var s=PosDemoPage.boot.steps.map(x=>x.step); return s.indexOf('wipe-done') >= 0 && s.indexOf('wipe-done') < s.indexOf('start') && s.indexOf('start') < s.indexOf('flutter-load');})()`));
  await shot(C, '13-after-reset');
  await cdp.send('Target.closeTarget', { targetId: H.targetId });

  // ------------------------------------------------------------ 11. смена эпохи
  await postOrder(C, 'cash');
  await fetch(`${ORIGIN}/__dev/set-build?epochKey=dev-epoch-2&buildId=dev-2`);
  await navigate(C, `${ORIGIN}/`);
  await waitFor(C, `(document.getElementById('loading')||{dataset:{}}).dataset.view === 'epoch'`, 15000, 'предупреждение о новой эпохе');
  await shot(C, '14-epoch-warning');
  check('смена эпохи: предупреждение до стирания, воркер не запущен', /Демо обновлено/.test(await ev(C, `document.getElementById('loading').innerText`)) && (await ev(C, `__posDemo.phase`)) === 'idle');
  await click(C, '#pd-epoch-continue');
  await appReady(C, 30000);
  const ep = await ev(C, `({key: localStorage.getItem('optomstroy.demo.epochKey'), build: localStorage.getItem('optomstroy.demo.buildId'), db: PosDemoPage.boot.storage.dbName})`);
  check('новая эпоха: ключ сохранён, новый том, данных нет', ep.key === 'dev-epoch-2' && ep.build === 'dev-2' && /dev-epoch-2/.test(ep.db) && (await ordersCount(C)) === 0, ep);
  await fetch(`${ORIGIN}/__dev/set-build?buildId=dev-3`);
  await navigate(C, `${ORIGIN}/`);
  await appReady(C, 30000);
  check('новая выкладка без смены эпохи: данные сохраняются, без предупреждения', (await ev(C, `PosDemoPage.boot.steps.some(s=>s.step==='epoch' && s.data.state==='same')`)) && !(await ev(C, `PosDemoPage.boot.steps.some(s=>s.step==='wipe-start')`)));

  // ------------------------------------------------------------ 12. fatal воркера
  await fetch(`${ORIGIN}/__dev/set-mock?fatal=1&initDelayMs=600`);
  await navigate(C, `${ORIGIN}/`);
  await waitFor(C, `(document.getElementById('loading')||{dataset:{}}).dataset.view === 'fatal'`, 15000, 'экран ошибки воркера');
  await sleep(300);
  await shot(C, '15-worker-fatal');
  const fatalText = await ev(C, `document.getElementById('loading').innerText`);
  check('fatal: текст ошибки и «Сбросить демо» на экране загрузки', /mock fatal/.test(fatalText) && /Сервер демо не запустился/.test(fatalText) && !!(await rect(C, '#pd-fatal-reset')), fatalText.slice(0, 300));
  const r503 = await req(C, `{method:'GET', url:'/health'}`);
  check('fatal: запросы моста → code fatal', r503.error === 'fatal', r503);
  await fetch(`${ORIGIN}/__dev/set-mock?fatal=0`);
  await click(C, '#pd-fatal-reset');
  await appReady(C, 40000);
  check('«Сбросить демо» с экрана ошибки → чистый старт', (await ev(C, `!!PosDemoPage.boot.lastWipe && PosDemoPage.boot.lastWipe.ok`)) && (await ordersCount(C)) === 0);
  await ev(C, `__posDemo.control('POST __mock/fatal')`);
  await waitFor(C, `document.getElementById('pd-overlay') && document.getElementById('pd-fatal-reset')`, 5000, 'слой ошибки после запуска');
  await shot(C, '16-worker-fatal-runtime');
  check('fatal во время работы: слой с текстом и «Сбросить демо»', /сервер демо упал во время работы/.test(await ev(C, `document.getElementById('pd-overlay').innerText`)));
  await click(C, '#pd-fatal-reload');
  await appReady(C, 30000);
  // Ошибка запуска движка Flutter: flutter_bootstrap.js пишет текст в #loading .error — страница добавляет кнопки.
  await fetch(`${ORIGIN}/__dev/set-mock?flutterFail=1`);
  await navigate(C, `${ORIGIN}/`);
  await waitFor(C, `document.getElementById('pd-app-reload') && document.querySelector('#loading .error').textContent.length > 0`, 15000, 'ошибка запуска приложения');
  await shot(C, '16b-flutter-start-error');
  check('ошибка запуска Flutter: текст из flutter_bootstrap.js и кнопки «Обновить страницу», «Сбросить демо»', /Не удалось запустить приложение/.test(await ev(C, `document.getElementById('loading').innerText`)) && !!(await rect(C, '#pd-app-reset')));
  await fetch(`${ORIGIN}/__dev/set-mock?flutterFail=0`);
  // demo/build.json недоступен (сбой сети) — эпоха не проверяется, данные не стираются.
  await postOrder(C, 'cash');
  const keepCount = await ordersCount(C);
  await fetch(`${ORIGIN}/__dev/set-build?fail=1`);
  await navigate(C, `${ORIGIN}/`);
  await appReady(C, 30000);
  check('build.json недоступен: без предупреждения и без стирания, тот же том', (await ev(C, `PosDemoPage.boot.steps.some(s=>s.step==='epoch' && s.data.state==='unknown') && !PosDemoPage.boot.steps.some(s=>s.step==='wipe-start')`)) && (await ordersCount(C)) === keepCount, { keepCount });
  await fetch(`${ORIGIN}/__dev/set-build?fail=0`);

  // ------------------------------------------------------------ 12б. review fixes
  // запомненное хранилище эпохи
  const sk = await ev(C, `JSON.parse(localStorage.getItem('optomstroy.demo.storageKind')||'null')`);
  check('review: хранилище эпохи запомнено после ready (storageKind)', !!sk && sk.epochKey === (await ev(C, `PosDemoPage.boot.build.epochKey`)) && /^(opfs|idb)$/.test(sk.storage) && sk.readyCount >= 1, sk);
  check('review: повторный визит открыл запомненное хранилище, запасной — только memory', await ev(C, `PosDemoPage.boot.storage.source === 'remembered' && PosDemoPage.boot.storage.fallback.join(',') === 'memory'`), await ev(C, `PosDemoPage.boot.storage`));
  // плашка «Данные демо не сохраняются»
  await ev(C, `__posDemo.control('POST __mock/storage', {ok:false, error:'QuotaExceededError (имитация)'})`);
  await waitFor(C, `!!document.getElementById('pd-storage-banner') && !document.getElementById('pd-storage-banner').hidden`, 5000, 'плашка сбоя записи');
  await shot(C, '16c-storage-banner');
  const banner = await ev(C, `document.getElementById('pd-storage-banner').innerText`);
  check('review: storage {ok:false} → плашка «Данные демо не сохраняются» с кнопкой «Сервис»', /Данные демо не сохраняются/.test(banner) && !!(await rect(C, '#pd-storage-open')), banner.slice(0, 200));
  await click(C, '#pd-storage-open');
  await sleep(300);
  check('review: «Открыть «Сервис»» открывает панель на разделе «Сервис» (лицензии, «Запись на диск: НЕ УДАЁТСЯ»)', await ev(C, `PosDemoPage.panel.isOpen && document.getElementById('pd-sec-service').open && /НЕ УДАЁТСЯ/.test(document.getElementById('pd-service-info').innerText) && !!document.getElementById('pd-licenses-link')`));
  await ev(C, `__posDemo.control('POST __mock/storage', {ok:true})`);
  await waitFor(C, `!document.getElementById('pd-storage-banner')`, 5000, 'плашка снята');
  check('review: storage {ok:true} → плашка снята', true);
  await ev(C, `PosDemoPage.panel.close(false)`);
  // demo/build.json отсутствует (404) — ошибка сборки сайта, демо не запускается, данные не трогаются
  const keep2 = await ordersCount(C);
  await fetch(`${ORIGIN}/__dev/set-build?missing=1`);
  await navigate(C, `${ORIGIN}/`);
  await waitFor(C, `(document.getElementById('loading')||{dataset:{}}).dataset.view === 'fatal'`, 15000, 'ошибка конфигурации');
  await shot(C, '16d-build-json-missing');
  const cfgText = await ev(C, `document.getElementById('loading').innerText`);
  check('review: demo/build.json 404 → «Сайт демо собран неполностью», воркер не запущен, без «Сбросить демо»', /собран неполностью/.test(cfgText) && (await ev(C, `__posDemo.phase`)) === 'idle' && !(await rect(C, '#pd-fatal-reset')), cfgText.slice(0, 300));
  await fetch(`${ORIGIN}/__dev/set-build?missing=0`);
  await navigate(C, `${ORIGIN}/`);
  await appReady(C, 30000);
  check('review: после 404 данные не стёрты, эпоха та же', (await ordersCount(C)) === keep2 && !(await ev(C, `PosDemoPage.boot.steps.some(s=>s.step==='wipe-start')`)), { keep2 });
  // fatal fenced → уход на demo-closed.html, а не «Сбросить демо»
  await ev(C, `__posDemo.control('POST __mock/fatal', {code:'fenced'})`);
  await waitFor(C, `/demo-closed\\.html/.test(location.href)`, 8000, 'уход на demo-closed после fatal fenced');
  check('review: fatal fenced → demo-closed.html?reason=generation (без «Сбросить демо»)', /reason=generation/.test(await ev(C, `location.href`)) && !!(await rect(C, '#pd-closed-licenses')), await ev(C, `location.href`));
  await navigate(C, `${ORIGIN}/?takeover=1`);
  await appReady(C, 30000);

  // ------------------------------------------------------------ 13. проверка среды: телефон, мессенджер, Safari
  const cls = await ev(C, `(function(){var c=PosDemoPage.env.classify; var codes=function(i){return c(i).issues.map(function(x){return x.code;}).join(',');};
    return {
      chromeWin: codes({ua:'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36', brands:[{brand:'Chromium'}], uaMobile:false, deviceMemory:8}),
      edgeWin: codes({ua:'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36 Edg/156.0.0.0', brands:[{brand:'Microsoft Edge'}], uaMobile:false}),
      yandex: codes({ua:'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 YaBrowser/25.0 Safari/537.36'}),
      safariMac: codes({ua:'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15', maxTouchPoints:0}),
      iPad: codes({ua:'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15', maxTouchPoints:5}),
      iphoneTelegram: codes({ua:'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148', telegram:true}),
      androidWhatsApp: codes({ua:'Mozilla/5.0 (Linux; Android 14; SM-A546B; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0 Mobile Safari/537.36 WhatsApp/2.24', uaMobile:true}),
      firefox: codes({ua:'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0'}),
      lowMem: codes({ua:'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36', brands:[{brand:'Chromium'}], deviceMemory:2}),
      noFeatures: codes({ua:'Mozilla/5.0 (Windows NT 10.0) Chrome/156.0.0.0', brands:[{brand:'Chromium'}], caps:{moduleWorker:false, locks:false, idb:false, broadcast:false, wasm:true}}),
    };})()`);
  check('classify: Chrome/Edge/Яндекс на ПК без замечаний', cls.chromeWin === '' && cls.edgeWin === '' && cls.yandex === '', cls);
  check('classify: Safari, iPad, iPhone+Telegram, Android WebView WhatsApp, Firefox, мало памяти, без возможностей', cls.safariMac === 'safari' && cls.iPad === 'tablet,safari' && cls.iphoneTelegram === 'in_app,phone,safari' && cls.androidWhatsApp === 'in_app,phone' && cls.firefox === 'other_browser' && cls.lowMem === 'low_memory' && cls.noFeatures === 'no_module_worker,no_locks,no_broadcast,no_idb', cls);
  const D = await openTab('D', {
    w: 390, h: 844, mobile: true,
    ua: 'Mozilla/5.0 (Linux; Android 14; SM-A546B; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.0.0 Mobile Safari/537.36 Telegram-Android/11.2.0',
    uaMeta: { brands: [{ brand: 'Chromium', version: '126' }], fullVersionList: [], platform: 'Android', platformVersion: '14', architecture: '', model: 'SM-A546B', mobile: true },
  });
  await navigate(D, `${ORIGIN}/`);
  await waitFor(D, `(document.getElementById('loading')||{dataset:{}}).dataset.view === 'env'`, 15000, 'страница «Откройте на компьютере»');
  await shot(D, '17-env-phone-telegram');
  const envText = await ev(D, `document.getElementById('loading').innerText`);
  check('телефон в Telegram: «Откройте на компьютере в Chrome или Edge» и «Всё равно продолжить»', /Откройте на компьютере в Chrome или Edge/.test(envText) && /встроенном браузере мессенджера/.test(envText) && /телефон/.test(envText) && !!(await rect(D, '#pd-env-continue')), envText.slice(0, 400));
  check('проверка среды — до замка и до воркера', (await ev(D, `__posDemo.phase`)) === 'idle' && !(await ev(D, `PosDemoPage.boot.lockResult`)));
  await click(D, '#pd-env-continue');
  await waitFor(D, `(document.getElementById('loading')||{dataset:{}}).dataset.view === 'lock'`, 10000, 'после «Всё равно продолжить» — замок (демо открыто в C)');
  check('«Всё равно продолжить» → дальше обычная загрузка (здесь — плашка замка)', true);
  await cdp.send('Target.closeTarget', { targetId: D.targetId });

  // ------------------------------------------------------------ 14. закрытая страница и сеть
  const E = await openTab('E');
  await navigate(E, `${ORIGIN}/demo-closed.html?reason=moved`);
  await waitFor(E, `document.getElementById('pd-closed-back')`, 5000);
  await click(E, '#pd-closed-back');
  await waitFor(C, `location.pathname.endsWith('/demo-closed.html')`, 10000, '«Вернуть демо в эту вкладку» забирает демо у C');
  await appReady(E, 30000);
  check('demo-closed.html → «Вернуть демо в эту вкладку» (?takeover=1) переносит демо', (await ev(E, `location.search`)) === '' && (await ev(E, `PosDemoPage.boot.lockResult.released`)) === true);
  // Без постоянного хранилища (memory://): предупреждение «данные не сохранятся».
  await navigate(E, `${ORIGIN}/?storage=memory`);
  await appReady(E, 30000);
  await sleep(300);
  await shot(E, '18-memory-storage-toast');
  check('memory://: предупреждение «Данные демо не сохранятся после перезагрузки»', /не сохранятся после перезагрузки/.test(await ev(E, `(document.querySelector('.pd-toast')||{}).textContent || ''`)) && (await ev(E, `__posDemo.info.storage`)) === 'memory');
  const st = await devGet('/__dev/state');
  const external = results.requests.filter((r) => !r.url.startsWith(ORIGIN) && !/^(data|blob|about|chrome):/.test(r.url));
  check('нет запросов к /api/ сайта и к внешним хостам', st.counters.apiHits === 0 && external.length === 0, { apiHits: st.counters.apiHits, external: external.slice(0, 5), notFound: st.counters.notFound });
  check('нет необработанных исключений на страницах и в воркерах', results.exceptions.length === 0, results.exceptions.slice(0, 5));
  // Ожидаемые ошибки — только от намеренно вызванных сбоев имитации (текст «Имитация: …»).
  const unexpected = results.console.filter((c) => c.type === 'error' && !/Имитация:/.test(c.text));
  check('нет ошибок в консоли, кроме намеренных сбоев имитации', unexpected.length === 0, unexpected.slice(0, 5));
}

main();

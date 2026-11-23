// Headless-проверка СОБРАННОГО сайта веб-демо (review fixes: часть WP-T2; critic [5], [16], [19], [21]; шаги kiosk и
// kioskswitch — «Планшет магазина», P-002 TAB-3-01 и TAB-3-02; шаг paste — вставка на экране входа, 12 T-DEMO-014).
// Настоящая страница, настоящее приложение Flutter (main.dart.js), настоящий backend.js на PGlite — через
// tools/serve-site.mjs с заголовками и перенаправлениями Netlify; Chrome --headless=new, CDP на глобальном WebSocket
// Node 24 (без puppeteer). Порт статики 8095–8099 (первый свободный), CDP — первый свободный от 9491.
//
//   node demo/web/tools/smoke.mjs [--storage opfs|idb] [--only boot,paste,ui,f5,frozen,kiosk,kioskswitch,passkey] [--out <каталог>] [--keep-profile] [--port 8095–8099] [--cdp <порт>]
//                                 [--url <https-адрес>] [--browser chrome|edge] [--passkey gate,bound,neg,kiosk]
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
//   paste  — вставка в поле номера SCR-01 (12 T-DEMO-014; 15 ADR-113 п. 1, уточнение 2026-11-08; по умолчанию не
//            входит, вне релизных ворот — как kiosk; идёт до ui, пока вкладка A на SCR-01): буфер «+996 555 000 906»
//            (разрешения — Browser.grantPermissions / setPermission, фокус страницы — Emulation.setFocusEmulationEnabled);
//            (а) clipboard-read разрешено: правая кнопка над «+996» — меню приложения (contextmenu отменён движком),
//            «Вставить» → «555 000 906»; (б) clipboard-read запрещено: поле «77», Ctrl+A, Ctrl+V → «555 000 906»
//            (событие paste не отменено); (в) clipboard-read запрещено, поле пустое: правая кнопка над полем в фокусе —
//            contextmenu на элементе ввода движка НЕ отменён (меню браузера с его «Вставить»; headless его не рисует —
//            проверка вручную, README «Как проверить превью»), над «+996» — меню приложения, «Вставить» → подсказка
//            ds_paste_blocked_hint (по дереву семантики), поле пустое. «Вставить» меню приложения — первый пункт у
//            точки нажатия (поле пустое или без выделения);
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
//            WEB-KI-25 (headless Chrome, OPFS): вкладка B при перезагрузке изредка падает (процесс отрисовки,
//            Inspector.targetCrashed) — тогда, как пользователь, демо открывается в новой вкладке (один раз; данные —
//            до последней записи) и проверки идут в ней; падение — в smoke.json crashes и в строке итога;
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
//   passkey — вход по лицу или отпечатку через passkey (15 ADR-116 п. 1, п. 4, п. 5; 09 BIO-035, BIO-037, BIO-041; 12
//            T-DEMO-017, T-DEMO-018, T-DEMO-019, T-DEMO-022, T-DEMO-023, T-DEMO-024; по умолчанию не входит, вне релизных
//            ворот — как kiosk; идёт последним; --passkey gate,winkey,bound,neg,kiosk — части, по умолчанию все). Виртуальный аутентификатор CDP
//            (WebAuthn.addVirtualAuthenticator: internal, ctap2, проверка пользователя) добавляется до первой навигации
//            вкладки; «один внутренний на вкладку» — замена = remove + add; setUserVerified(false) не используется (после
//            него окружение отказывает и при true — проба 2026-11-07). С шагом passkey адрес сайта — http://localhost:<порт>
//            (на 127.0.0.1 WebAuthn: SecurityError «invalid domain»), во всех вкладках прогона включён WebAuthn.enable —
//            настоящий Windows Hello не вызывается ни в одной вкладке. Части gate, winkey, bound и kiosk начинаются в новой
//            вкладке с чистого хранилища сайта (прежние вкладки закрываются, Storage.clearDataForOrigin; не вышло —
//            «Сбросить демо»):
//            gate  — T-DEMO-017, браузер на Windows (UA headless-браузера), аутентификатор без PRF: кассир 906 → SCR-42
//                    «Вход через Windows Hello» (режим ключа, LF-3-06; в сборке без него — «Windows Hello перед вводом
//                    PIN») → согласие → credentialAdded → снекбар settings_hello_key_no_prf, ключа входа нет, секция в
//                    режиме гейта (включён) → F5 → SCR-08 без автовызова → «Windows Hello» →
//                    credentialAsserted, «Подтверждено Windows Hello · введите PIN», без PIN рабочего экрана нет → PIN →
//                    рабочий экран; «Выйти» → вход по SMS → блокировка (F5) → «Windows Hello» тем же ключом (нет ни
//                    credentialAdded, ни credentialDeleted); T-DEMO-019 (4) для гейта — ключ удалён → «Windows Hello не
//                    подтвердил вход. Введите PIN»; «Сбросить демо» сообщает ОС о passkey сайта (lastWipe.passkeys);
//            winkey — T-DEMO-024 (LF-3-06), браузер на Windows, аутентификатор с PRF, AUTH_WINDOWS_HELLO_KEY=all
//                    (backend/demo-config.mjs): кассир 906 → SCR-42 «Вход через Windows Hello» → согласие → ключ входа
//                    (POST /me/biometrics с helloKey.source=webauthn_prf — по журналу запросов к мосту window.__pkTrace,
//                    только признаки тела; на странице — только зашифрованный passkeyHelloKey) → F5 → SCR-08
//                    «Войти через Windows Hello» без автовызова → ровно один credentialAsserted → POST
//                    /auth/unlock/challenge и POST /auth/unlock {method: hello_key} → рабочий экран без PIN; «Выйти» →
//                    вход по SMS → блокировка (F5) → тот же ключ без PIN (нет credentialAdded/credentialDeleted);
//            bound — T-DEMO-018, UA Android, аутентификатор с PRF: SCR-42 «Вход по отпечатку или лицу» (согласие) →
//                    блоб без JWT-подобных строк → F5 → автовызов SCR-08, ровно один credentialAsserted → рабочий экран
//                    без PIN; GET /auth/sessions через мост — сессия kind=biometric (android) использована при входе;
//            neg   — T-DEMO-019, внутри частей gate и bound: (4) ключ удалён (clearCredentials / removeCredential) →
//                    cancelled, поле PIN, блоб цел; дальше в bound (UA Android): (1) замена на аутентификатор без
//                    проверки пользователя (тот же ключ addCredential) → поле PIN; (2) замена на аутентификатор с ключом
//                    addCredential без PRF → invalidated, блоб удалён, SCR-01 bio_invalidated (02 SCR-08.4 п. 7) →
//                    вход по SMS; (3) аутентификатора нет → тумблер SCR-42
//                    неактивен, на SCR-08 кнопки нет;
//            kiosk — T-DEMO-023 и T-DEMO-022 (UA Android, аутентификатор с PRF): администратор 901 с включённым
//                    passkey подключает браузер планшетом (SCR-54) →
//                    блоба нет; сессия планшета SCR-51 → SCR-52 → SCR-53 и холодный старт — ни одного события WebAuthn,
//                    кнопок биометрии нет; «Вернуться к обычному входу» → кассир 906 включает passkey → «Планшет
//                    магазина» — блоб уехал в место «обычный вход» (записи гейта и пользователя остались) → «Подключить
//                    этот браузер заново» → администратор 901: SCR-08 без чужого ключа → SCR-54 «Подключить заново» →
//                    «Вернуться к обычному входу» — кассир входит своим passkey без PIN; «Выйти» → вход 907 → оставленный
//                    блоб 906 (имитация остатка) SCR-08 907 не предлагает.
// Итог — <out>/smoke.json и снимки <out>/NN-*.png. Свои сервер и браузер — по PID, профиль удаляется.
// В удалённом режиме по умолчанию <out> = .tmp/web_demo/smoke/remote-[edge-]<storage>-<время>.
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
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
// Шаг passkey: части (по умолчанию все) и адрес localhost (WebAuthn на 127.0.0.1 недоступен: rpId — не домен).
const PASSKEY = ONLY.has('passkey');
const PK_PARTS = new Set(String(arg('--passkey', 'gate,winkey,bound,neg,kiosk')).split(','));
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

const R = { storage: STORAGE, mode: REMOTE ? 'remote' : 'local', browser: BROWSER, startedAt: new Date().toISOString(), checks: [], exceptions: [], consoleErrors: [], csp: [], foreign: [], failedLoads: [], pids: {}, shots: [], steps: [], crashes: [] };
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
// Адрес страницы в браузере. С шагом passkey — localhost (secure context с допустимым rpId; сервер слушает 127.0.0.1,
// браузер сам резолвит localhost в петлю). Запросы Node к своему серверу — всегда на 127.0.0.1 (HTTP).
const HOST = PASSKEY && !REMOTE ? 'localhost' : '127.0.0.1';
const ORIGIN = REMOTE ?? `http://${HOST}:${port}`;
const HTTP = REMOTE ?? `http://127.0.0.1:${port}`;
R.origin = ORIGIN;
// запрос того же origin (а не «https://хост.чужой» с тем же началом)
const onOrigin = (u) => u.startsWith(ORIGIN) && (u.length === ORIGIN.length || /^[/?#]/.test(u[ORIGIN.length]));
const server = REMOTE ? null : spawn(process.execPath, [`${HERE}/serve-site.mjs`, '--port', String(port), '--quiet'], { stdio: ['ignore', 'pipe', 'pipe'] });
R.pids.server = server ? server.pid : null;
mkdirSync(PROFILE, { recursive: true });
// Удалённый режим и edge: имена резолвятся только для хоста --url — служебные запросы браузера (обновления, телеметрия,
// SmartScreen) и чужие хосты страницы наружу не уходят; запросы страницы всё равно видны в журнале CDP (foreign).
const resolverRules = REMOTE ? `MAP * ~NOTFOUND, EXCLUDE ${new URL(REMOTE).hostname}` : BROWSER === 'edge' ? `MAP * ~NOTFOUND${HOST === 'localhost' ? ', EXCLUDE localhost' : ''}` : null;
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
// События WebAuthn всех вкладок: { t, tab: targetId вкладки, name } (шаг passkey).
const waLog = [];
// Исходы операций demo-passkey.js из консоли (console.info «[demo-passkey] read: cancelled (NotAllowedError)»).
const pkNotes = [];
// Упавшие вкладки (WEB-KI-25): targetId вкладки → { t, via, status, errorCode }. Runtime.evaluate в упавшей вкладке не
// отвечает — waitFor заканчивается сразу с понятной ошибкой, а не через 90 с ожидания.
const crashed = new Map();
const crashWaiters = new Set();
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
    } else if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'info' && /^\[demo-passkey\] /.test(String(m.params.args?.[0]?.value ?? ''))) {
      // исход операции шлюза passkey страницы: «[demo-passkey] <операция>: <код> (<причина>)» — без значений
      pkNotes.push({ t: Date.now(), tab: s?.tab ?? null, text: String(m.params.args[0].value).slice(15, 160) });
    } else if (m.method === 'Inspector.targetCrashed' || m.method === 'Target.targetCrashed') {
      // процесс отрисовки вкладки упал: Inspector — в сессии страницы, Target — от браузера (setDiscoverTargets)
      const tab = m.method === 'Target.targetCrashed' ? m.params.targetId : s?.type === 'page' ? s.tab : null;
      if (tab) {
        const c = { t: Date.now(), tab, via: m.method, status: m.params?.status ?? null, errorCode: m.params?.errorCode ?? null };
        R.crashes.push(c);
        if (!crashed.has(tab)) crashed.set(tab, c);
        for (const w of crashWaiters) w(tab);
      }
    } else if (typeof m.method === 'string' && m.method.startsWith('WebAuthn.')) {
      // события виртуального аутентификатора (credentialAdded / Asserted / Deleted / Updated) — по вкладке
      waLog.push({ t: Date.now(), tab: s?.tab ?? null, name: m.method.slice(9) });
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
async function openTab(name, { ua = null } = {}) {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  sessions.set(sessionId, { type: 'page', url: 'about:blank', tab: targetId, name });
  await initSession(sessionId, 'page');
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false }, sessionId);
  // С шагом passkey — виртуальное окружение WebAuthn в каждой вкладке до первой навигации: без виртуального
  // аутентификатора isUserVerifyingPlatformAuthenticatorAvailable() = false, а настоящий Windows Hello не вызывается.
  if (PASSKEY) await send('WebAuthn.enable', { enableUI: false }, sessionId);
  if (ua) await send('Emulation.setUserAgentOverride', ua, sessionId);
  // нарушения CSP страницы — в журнал (securitypolicyviolation), до любого скрипта страницы
  await send('Page.addScriptToEvaluateOnNewDocument', { source: `window.__cspViolations=[];document.addEventListener('securitypolicyviolation',function(e){window.__cspViolations.push({d:e.violatedDirective,u:String(e.blockedURI).slice(0,160)});});` }, sessionId);
  return { name, targetId, sid: sessionId };
}
class TabCrashedError extends Error {}
// Ожидание падения вкладки: Runtime.evaluate в упавшей вкладке не отвечает — ev заканчивается сразу, а не по таймауту.
const onCrash = (tab) => {
  let off = () => undefined;
  const p = new Promise((res) => {
    if (!tab.targetId) return;
    if (crashed.has(tab.targetId)) return res({ crashed: true });
    const w = (t) => t === tab.targetId && res({ crashed: true });
    crashWaiters.add(w);
    off = () => crashWaiters.delete(w);
  });
  return { p, off: () => off() };
};
const ev = async (tab, expression, timeoutMs = 60000) => {
  const crash = onCrash(tab);
  const r = await Promise.race([send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, tab.sid), sleep(timeoutMs).then(() => ({ timeout: true })), crash.p]).finally(crash.off);
  if (r.crashed) throw new TabCrashedError(`вкладка ${tab.name ?? tab.targetId} упала (${crashed.get(tab.targetId).via}, WEB-KI-25): ${expression.slice(0, 100)}`);
  if (r.timeout) throw new Error(`timeout ${timeoutMs} мс: ${expression.slice(0, 100)}`);
  if (r.exceptionDetails) throw new Error(`${r.exceptionDetails.text} ${r.exceptionDetails.exception?.description ?? ''}`.slice(0, 600));
  return r.result.value;
};
const waitFor = async (tab, expr, timeoutMs, label) => {
  const end = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < end) {
    if (tab.targetId && crashed.has(tab.targetId)) throw new TabCrashedError(`вкладка ${tab.name} упала (${crashed.get(tab.targetId).via}, WEB-KI-25): ${label}`);
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
// Правая кнопка мыши (шаг paste): buttons = 2 при нажатии — PointerDownEvent Flutter с kSecondaryMouseButton.
const rightClick = async (tab, x, y) => {
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, tab.sid);
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'right', buttons: 2, clickCount: 1 }, tab.sid);
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'right', buttons: 0, clickCount: 1 }, tab.sid);
};
// Клавиша без модификаторов (Backspace, Escape) и Ctrl+<буква> (шаг paste; Windows: Blink сам выполняет команду правки
// Paste / SelectAll для элемента ввода — тот же путь, что у настоящего Ctrl+V).
const KEYS = { Backspace: 8, Escape: 27 };
const pressKey = async (tab, key) => {
  await send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key, code: key, windowsVirtualKeyCode: KEYS[key] }, tab.sid);
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key, code: key, windowsVirtualKeyCode: KEYS[key] }, tab.sid);
};
const ctrlKey = async (tab, ch) => {
  const vk = ch.toUpperCase().charCodeAt(0);
  await send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Control', code: 'ControlLeft', windowsVirtualKeyCode: 17, modifiers: 2 }, tab.sid);
  await send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: ch, code: `Key${ch.toUpperCase()}`, windowsVirtualKeyCode: vk, modifiers: 2 }, tab.sid);
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: ch, code: `Key${ch.toUpperCase()}`, windowsVirtualKeyCode: vk, modifiers: 2 }, tab.sid);
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Control', code: 'ControlLeft', windowsVirtualKeyCode: 17, modifiers: 0 }, tab.sid);
};
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
    const area = r.width * r.height; if (!best || area < best.area) best = { area, x: r.left + r.width / 2, y: r.top + r.height / 2, l: r.left }; }
  return best; })()`;
// Точная подпись (кнопки экранной клавиатуры «1»…«0»): aria-label или текст равен want; предпочтение — role=button.
const findExact = (text) => `(() => { const want = ${JSON.stringify(text)}; let best = null;
  for (const n of document.querySelectorAll('flt-semantics, flt-semantics *, [role]')) {
    const label = (n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').trim();
    if (label !== want) continue; const r = n.getBoundingClientRect(); if (r.width < 2 || r.height < 2) continue;
    const score = (n.getAttribute('role') === 'button' ? 0 : 1e9) + r.width * r.height;
    if (!best || score < best.score) best = { score, x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
  return best; })()`;
// Включение семантики Flutter: «click» по заглушке. На настольной ОС движку достаточно цели события; на мобильной (UA
// Android, шаг passkey) — точка нажатия в центре заглушки (MobileSemanticsEnabler), поэтому событие — с координатами
// центра, а не element.click() (clientX/Y = 0).
const semanticsOn = async (tab) => {
  await waitFor(tab, `!!document.querySelector('flt-semantics-placeholder') || document.querySelectorAll('flt-semantics').length > 3`, 20000, 'семантика Flutter');
  await ev(tab, `(() => { const p = document.querySelector('flt-semantics-placeholder'); if (!p) return true; const r = p.getBoundingClientRect();
    p.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 })); return true; })()`);
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
// Перед нажатием «Меню разделов» — ждём, пока кнопка встанет на место: при UA Android (шаг passkey, часть kiosk) после
// входа PIN на SCR-08 экран въезжает переходом Zoom (TargetPlatform.android), и «Меню разделов» в дереве семантики уже
// есть, но ещё движется (x центра 71 → 52 → 48 за ≈ 200 мс; прогон 2026-11-19, wave2:DEMO-E2E). Нажатие в эти мс
// приходится мимо кнопки — меню не открывается, «Администратор» не дожидались (Chrome и Edge, 3 из 3 на сборке
// 67c20b520903831e). Два одинаковых замера подряд (через 150 мс), не дольше 5 с; потом — нажатие как раньше.
async function openTablets(x) {
  let prev = null;
  for (const until = Date.now() + 5000; Date.now() < until; ) {
    const r = await ev(x.tab, findExpr('Меню разделов'));
    const at = r ? `${Math.round(r.x)},${Math.round(r.y)}` : null;
    if (at && at === prev) break;
    prev = at;
    await sleep(150);
  }
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

// Заявка на планшете (SCR-51 → SCR-52 → SCR-53; шаги kiosk и passkey): карточка товара в наличии → «В корзину · …» →
// «Открыть корзину» → «Оформить заявку» → номер 700000101 и «Получить код» → 246810 → «Отправить заявку» → SCR-53.
// Снимки — <prefix>-product-sheet, -added, -cart, -scr52-phone, -scr52-code, -scr53. Возвращает адрес SCR-53 и номер заявки.
async function kioskOrder(x, prefix) {
  const tab = x.tab;
  x.stage('товар в корзину');
  // карточка витрины — один узел семантики («…, В наличии, … + Добавить»): нажатие открывает слой карточки
  // товара (UI-51-011), в нём — «В корзину · …»
  await x.clickFound(x.firstCardInView(), 'карточка товара в наличии на витрине');
  await x.waitText('В корзину ·', 15000, 'слой карточки товара: «В корзину · …»');
  await sleep(800);
  await shot(tab, `${prefix}-product-sheet`);
  await x.clickText('В корзину ·');
  // строка подтверждена сервером (корзина планшета — только на сервере): «В корзине: 1 шт», кнопка «Добавить ещё»
  await x.waitText('Добавить ещё', 20000, 'слой карточки: товар в корзине («Добавить ещё»)');
  await sleep(600);
  await x.clickText('Закрыть');
  await sleep(1200);
  await waitFor(tab, `[...document.querySelectorAll('flt-semantics')].some((n) => /Открыть корзину, [1-9]/.test((n.getAttribute('aria-label') || '') + ' ' + n.textContent))`, 20000, 'шапка: «Открыть корзину, 1 позиция, …»');
  const afterAdd = (await x.allTexts()).filter((t) => /Открыть корзину/.test(t)).slice(0, 3);
  await shot(tab, `${prefix}-added`);
  x.stage('корзина');
  await x.clickText('Открыть корзину');
  await x.waitText('Оформить заявку', 15000, 'drawer корзины: «Оформить заявку»');
  await sleep(1200);
  await shot(tab, `${prefix}-cart`);
  await x.clickExact('Оформить заявку');
  x.stage('SCR-52 телефон');
  // SCR-52 открывается поверх витрины (push): адрес страницы остаётся #/kiosk?…, шаг виден по заголовку
  await x.waitText('Введите номер телефона', 30000, 'SCR-52 «Введите номер телефона»');
  await sleep(1500);
  await x.digits('700000101');
  await sleep(800);
  await shot(tab, `${prefix}-scr52-phone`);
  const otpBefore = await x.count(202);
  await x.clickExact('Получить код');
  await waitFor(tab, `(PosDemoPage.bridge._stats.statuses['202'] || 0) > ${otpBefore}`, 30000, 'POST /kiosk/order-otp → 202');
  x.stage('SCR-52 код');
  await x.waitText('Введите код из SMS', 20000, 'SCR-52 «Введите код из SMS»');
  await sleep(1200);
  await x.digits('246810');
  await sleep(800);
  await shot(tab, `${prefix}-scr52-code`);
  await x.clickExact('Отправить заявку');
  x.stage('SCR-53');
  const done = await x.waitHash('/kiosk/done', 90000, 'SCR-53');
  await x.waitText('Заявка № POS-', 30000, 'SCR-53 «Заявка № … отправлена»');
  await sleep(1200);
  const number = await ev(tab, `(/Заявка № (POS-\\d{4}-\\d+)/.exec([...document.querySelectorAll('flt-semantics')].map((n) => (n.getAttribute('aria-label') || '') + ' ' + n.textContent).join(' ')) || [])[1] || null`);
  await shot(tab, `${prefix}-scr53`);
  return { done, number, afterAdd };
}

// ================================================================ шаги
try {
  await connect();
  // Target.targetCrashed (падение процесса отрисовки вкладки) приходит только при обнаружении целей
  await send('Target.setDiscoverTargets', { discover: true }).catch(() => undefined);
  await sleep(600);
  // заголовки ответа сервера (как на Netlify); в удалённом режиме — те же запросы Node к адресу --url
  const hIndex = await fetch(`${HTTP}/`);
  const hWasm = await fetch(`${HTTP}/backend/pglite/pglite.wasm`, { method: 'HEAD' });
  const hGz = await fetch(`${HTTP}/demo/snapshot/data.copy.gz`, { method: 'HEAD' });
  const hApi = await fetch(`${HTTP}/api/v1/__smoke_probe`); // проверка правила /api/* (из Node, не из браузера)
  const hImg = await fetch(`${HTTP}/images/${JSON.parse(readFileSync(`${WEB}/.build/snapshot/images.json`, 'utf8'))?.files?.[0]?.sha ?? 'x'}/card`, { method: 'HEAD' }).catch(() => null);
  R.headers = { index: Object.fromEntries(hIndex.headers), wasm: hWasm.headers.get('content-type'), gz: [hGz.headers.get('content-type'), hGz.headers.get('content-encoding')], api: hApi.status, image: hImg ? [hImg.status, hImg.headers.get('content-type')] : null };
  if (REMOTE) {
    // для сведения (README «Как проверить превью»): сжатие больших файлов на CDN — в итог не входит
    R.headers.encoding = {};
    for (const p of ['/main.dart.js', '/backend/backend.js', '/backend/pglite/pglite.wasm', '/backend/pglite/pglite.data', '/canvaskit/canvaskit.wasm']) {
      const h = await fetch(`${HTTP}${p}`, { method: 'HEAD', headers: { 'accept-encoding': 'br, gzip' } }).catch((e) => ({ status: String(e?.message ?? e), headers: new Headers() }));
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
  if (ONLY.has('boot') || ONLY.has('paste') || ONLY.has('ui') || ONLY.has('f5') || ONLY.has('frozen') || ONLY.has('kiosk') || ONLY.has('kioskswitch')) {
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

  // ------------------------------------------------------------ paste: вставка в поле номера SCR-01 (12 T-DEMO-014)
  if (ONLY.has('paste')) {
    const CLIP = '+996 555 000 906';
    const WANT = '555 000 906';
    R.paste = {};
    // Значение элемента ввода движка Flutter web в фокусе (синхронизировано с полем) — без семантики.
    const field = () => ev(A, `(() => { const all = [...document.querySelectorAll('flt-text-editing-host input, flt-text-editing-host textarea')]; const e = all.includes(document.activeElement) ? document.activeElement : null; return e ? { value: e.value, focused: true } : { value: null, focused: false, active: document.activeElement && document.activeElement.tagName }; })()`);
    // Журнал contextmenu / paste: цель и defaultPrevented после всех обработчиков (читается в следующей задаче).
    const events = async () => {
      await sleep(80);
      return ev(A, `(() => { const a = window.__pasteLog || []; window.__pasteLog = []; return a; })()`);
    };
    const setRead = (setting) => send('Browser.setPermission', { origin: ORIGIN, permission: { name: 'clipboard-read' }, setting });
    const readState = () => ev(A, `navigator.permissions.query({ name: 'clipboard-read' }).then((s) => s.state, (e) => 'query-error ' + e.name)`);
    try {
      await semanticsOn(A);
      await waitFor(A, `document.body.innerHTML.includes('Получить код')`, 30000, 'SCR-01');
      const box = await ev(A, findExpr('Номер телефона'));
      if (!box) throw new Error(`SCR-01: нет поля номера: ${JSON.stringify(await texts(A))}`);
      // меню и ввод — с выключенной семантикой (как шаг ui): перезагрузка, поле номера в автофокусе и пустое
      await send('Page.reload', {}, A.sid);
      await appReady(A, 90000);
      await sleep(1500);
      await send('Emulation.setFocusEmulationEnabled', { enabled: true }, A.sid);
      await ev(A, `(() => { window.__pasteLog = []; for (const t of ['contextmenu', 'paste']) window.addEventListener(t, (e) => { const r = { t, target: e.target && e.target.tagName, data: t === 'paste' && e.clipboardData ? e.clipboardData.getData('text/plain') : null }; window.__pasteLog.push(r); setTimeout(() => { r.prevented = e.defaultPrevented; }, 0); }, true); return true; })()`);
      await send('Browser.grantPermissions', { origin: ORIGIN, permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'] });
      const wr = await send('Runtime.evaluate', { expression: `navigator.clipboard.writeText(${JSON.stringify(CLIP)}).then(() => navigator.clipboard.readText(), (e) => 'write-error ' + e.name)`, awaitPromise: true, returnByValue: true, userGesture: true }, A.sid);
      R.paste.clipboard = wr.result?.value ?? null;
      // «+996» — префикс поля слева (вне элемента ввода движка); «Вставить» — первый пункт меню приложения у точки нажатия
      const prefix = { x: box.l + 30, y: box.y };
      const pasteItem = { x: prefix.x + 40, y: prefix.y + 22 };
      await click(A, box.x, box.y);
      await sleep(400);

      // (а) clipboard-read разрешено: меню приложения над «+996» → «Вставить»
      const a0 = await field();
      await events();
      await rightClick(A, prefix.x, prefix.y);
      await sleep(800);
      const evA = await events();
      await shot(A, 'paste-a-menu');
      await click(A, pasteItem.x, pasteItem.y);
      await sleep(1200);
      R.paste.a = { read: await readState(), before: a0, events: evA, after: await field() };
      await shot(A, 'paste-a-after');
      check(`вставка (а): clipboard-read разрешено — правая кнопка над «+996» → меню приложения → «Вставить» «${CLIP}» → «${WANT}»`, R.paste.clipboard === CLIP && R.paste.a.read === 'granted' && a0.value === '' && evA.some((e) => e.t === 'contextmenu' && e.target === 'FLUTTER-VIEW' && e.prevented === true) && R.paste.a.after.value === WANT, { clipboard: R.paste.clipboard, ...R.paste.a });

      // (б) clipboard-read запрещено: Ctrl+V поверх выделенного «77» (вставка браузера, разрешение не нужно)
      await setRead('denied');
      await ctrlKey(A, 'a');
      await typeText(A, '77');
      await sleep(400);
      const b0 = await field();
      await ctrlKey(A, 'a');
      await sleep(200);
      await events();
      await ctrlKey(A, 'v');
      await sleep(900);
      const evB = await events();
      R.paste.b = { read: await readState(), before: b0, events: evB, after: await field() };
      await shot(A, 'paste-b-ctrl-v');
      check(`вставка (б): clipboard-read запрещено — поле «77», Ctrl+A, Ctrl+V «${CLIP}» → «${WANT}»`, R.paste.b.read === 'denied' && b0.value === '77' && evB.some((e) => e.t === 'paste' && e.data === CLIP && e.prevented === false) && R.paste.b.after.value === WANT, R.paste.b);

      // (в) clipboard-read запрещено, поле пустое: над полем в фокусе — меню браузера; над «+996» — меню приложения,
      // «Вставить» → подсказка ds_paste_blocked_hint, поле пустое
      await ctrlKey(A, 'a');
      await pressKey(A, 'Backspace');
      await sleep(400);
      const c0 = await field();
      await events();
      await rightClick(A, box.x, box.y);
      await sleep(800);
      const evField = await events();
      await rightClick(A, prefix.x, prefix.y);
      await sleep(800);
      const evPrefix = await events();
      await shot(A, 'paste-c-menu');
      const ex0 = R.exceptions.length;
      await click(A, pasteItem.x, pasteItem.y);
      await sleep(600);
      const c1 = await field();
      // подсказка — по дереву семантики (снекбар 4 с); после этого шаг ui перезагружает страницу
      await semanticsOn(A);
      const hint = await waitFor(A, `[...document.querySelectorAll('flt-semantics')].map((n) => ((n.getAttribute('aria-label') || '') + ' ' + n.textContent).trim()).filter((s) => s.includes('Браузер не разрешил вставку')).sort((a, b) => a.length - b.length)[0] || null`, 3500, 'подсказка ds_paste_blocked_hint').catch(() => null);
      await shot(A, 'paste-c-hint');
      R.paste.c = { read: await readState(), before: c0, fieldEvents: evField, prefixEvents: evPrefix, after: c1, hint: hint ? hint.slice(0, 200) : null, newExceptions: R.exceptions.length - ex0 };
      check('вставка (в): clipboard-read запрещено — правая кнопка над полем в фокусе: contextmenu на элементе ввода не отменён (меню браузера); над «+996» меню приложения, «Вставить» → подсказка, поле пустое, 0 исключений', R.paste.c.read === 'denied' && c0.value === '' && evField.some((e) => e.t === 'contextmenu' && e.target === 'INPUT' && e.prevented === false) && !evField.some((e) => e.t === 'contextmenu' && e.prevented) && evPrefix.some((e) => e.t === 'contextmenu' && e.target === 'FLUTTER-VIEW' && e.prevented === true) && c1.value === '' && !!hint && R.paste.c.newExceptions === 0, R.paste.c);
    } catch (e) {
      check('вставка на SCR-01 (шаг paste) без исключения', false, String(e?.message ?? e));
      await shot(A, 'paste-error').catch(() => undefined);
    }
    await send('Browser.resetPermissions', {}).catch(() => undefined);
    await send('Emulation.setFocusEmulationEnabled', { enabled: false }, A.sid).catch(() => undefined);
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
    let B = await openTab('B');
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
    // Перезагрузка B. WEB-KI-25: на OPFS процесс отрисовки вкладки B после «Продолжить здесь» изредка падает через
    // доли секунды после перехода (ошибка доступа к памяти внутри Chrome; прогоны 2026-10-30 — 5 из 12, 2026-11-18 —
    // 1 из 2; код демо не причастен). Тогда — как пользователь: упавшая вкладка закрывается, демо открывается в новой
    // (один раз; второе падение подряд — провал шага), проверки шага идут в ней.
    R.frozenReloads = [];
    const reloadB = async (why) => {
      try {
        await navigate(B, url('&envcheck=0'));
        await appReady(B, 90000);
        R.frozenReloads.push({ why, tab: B.name, crashed: false });
        return;
      } catch (e) {
        if (!(e instanceof TabCrashedError) || R.frozenReloads.some((r) => r.crashed)) throw e;
        R.frozenReloads.push({ why, tab: B.name, crashed: true, crash: crashed.get(B.targetId) });
        log(`ВНИМАНИЕ ${e.message} — демо открывается в новой вкладке (WEB-KI-25)`);
      }
      await send('Target.closeTarget', { targetId: B.targetId }).catch(() => undefined);
      await sleep(1500);
      B = await openTab(`${B.name}2`);
      cur = B;
      await navigate(B, url('&envcheck=0'));
      await appReady(B, 120000);
      await shot(B, 'frozen-B-after-crash');
    };
    if (outcome !== 'ready') {
      // A отпустила дескрипторы — «Обновить страницу» в B
      await reloadB('B после разморозки A: «Обновить страницу»');
      const { token: tb } = await apiLogin(B, '+996777000906', { device: crypto.randomUUID() });
      orderB = (await sellOne(B, tb, 'cash')).order.json;
    }
    await reloadB('перезагрузка B: заказ B на месте');
    const st = await ev(B, `__posDemo.control('GET state')`);
    const crashB = R.frozenReloads.find((r) => r.crashed) ?? null;
    check(`после перезагрузки B заказ B на месте, том цел (A не перезаписала его)${crashB ? '; вкладка B упала (WEB-KI-25) — проверено в новой вкладке' : ''}`, !!orderB && st.orders.some((o) => o.id === orderB.id), { orderB: orderB?.publicNumber, orders: st.orders.length, storage: st.storage, tab: B.name, crash: crashB });
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
      const order = await kioskOrder(kx, 'kiosk');
      R.kiosk.afterAdd = order.afterAdd;
      const { done, number } = order;
      R.kiosk.number = number;

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

  // ------------------------------------------------------------ passkey: вход по лицу или отпечатку (ADR-116 п. 1, п. 5)
  // 12 T-DEMO-017 (gate), T-DEMO-018 (bound), T-DEMO-019 (neg), T-DEMO-023 и T-DEMO-022 (kiosk); вне релизных ворот.
  // Части начинаются с чистого хранилища сайта (кроме neg — продолжает bound). Значения секретов, блобов и токенов в
  // отчёт не пишутся — только признаки, числа событий WebAuthn и коды исходов шлюза страницы.
  if (PASSKEY) {
    R.passkey = { parts: ['gate', 'winkey', 'bound', 'neg', 'kiosk'].filter((p) => PK_PARTS.has(p)), host: HOST, notes: pkNotes };
    const PK = R.passkey;
    const SNACK = { ok: 'Вход по биометрии включён', noPrf: 'Браузер не поддерживает вход без PIN', cancelled: 'Биометрия не подтверждена', error: 'Не удалось сохранить настройку' };
    // Подписи кнопок биометрии SCR-08 (02 SCR-08.4 п. 9; 09 BIO-036).
    const BIO_BUTTONS = ['Войти по биометрии', 'Войти по лицу или отпечатку', 'Войти через Windows Hello', 'Windows Hello'];
    const JWT_RE = /eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}/;
    // Журнал запросов приложения к мосту (часть winkey, T-DEMO-024): ловушка на присваивание window.__posDemo
    // (demo-bridge.js) оборачивает request — в window.__pkTrace только метод, путь и признаки тела (источник ключа,
    // метод входа, есть ли подпись или PIN), без значений ключа, подписи, PIN и токенов.
    const REQ_TRACE = `(function () {
      var trace = [];
      Object.defineProperty(window, '__pkTrace', { value: trace });
      var bridge;
      Object.defineProperty(window, '__posDemo', {
        configurable: true,
        enumerable: true,
        get: function () { return bridge; },
        set: function (v) {
          bridge = v;
          if (!v || typeof v.request !== 'function' || v.__pkWrapped) return;
          var orig = v.request;
          v.request = function (req) {
            try {
              var path = String((req && req.url) || '').replace(/^.*\\/api\\/v1/, '').split('?')[0];
              var e = { t: Date.now(), method: String((req && req.method) || ''), path: path };
              if (/^\\/(me\\/biometrics|auth\\/unlock)/.test(path) && req.body && typeof req.body !== 'string') {
                var b = JSON.parse(new TextDecoder().decode(req.body));
                var k = b.helloKey || {};
                e.body = { enabled: b.enabled, biometricClass: b.biometricClass, method: b.method, helloKeySource: k.source, helloKeyAlgorithm: k.algorithm, publicKey: !!k.publicKey, signature: !!b.signature, pin: !!b.pin };
              }
              trace.push(e);
            } catch (err) { trace.push({ t: Date.now(), error: String(err && err.name) }); }
            return orig.apply(this, arguments);
          };
          v.__pkWrapped = true;
        },
      });
    })();`;
    // ---- виртуальный аутентификатор вкладки (internal, ctap2.1, резидентные ключи, проверка пользователя)
    const authOpts = (o) => ({ options: { protocol: 'ctap2', ctap2Version: 'ctap2_1', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true, hasPrf: true, ...o } });
    const addAuth = async (tab, o = {}) => {
      tab.auth = (await send('WebAuthn.addVirtualAuthenticator', authOpts(o), tab.sid)).authenticatorId;
      return tab.auth;
    };
    const removeAuth = async (tab) => {
      if (tab.auth) await send('WebAuthn.removeVirtualAuthenticator', { authenticatorId: tab.auth }, tab.sid);
      tab.auth = null;
    };
    const credList = async (tab) => (tab.auth ? (await send('WebAuthn.getCredentials', { authenticatorId: tab.auth }, tab.sid)).credentials : []);
    // ---- события WebAuthn и исходы шлюза страницы на вкладке после метки
    const waMark = () => waLog.length;
    const waCount = (tab, from, name) => waLog.slice(from).filter((e) => e.tab === tab.targetId && (!name || e.name === name)).length;
    const waNames = (tab, from) => waLog.slice(from).filter((e) => e.tab === tab.targetId).map((e) => e.name);
    const noteMark = () => pkNotes.length;
    const notesSince = (tab, from) => pkNotes.slice(from).filter((n) => n.tab === tab.targetId).map((n) => n.text);
    const waitNote = (tab, from, re, ms, label) =>
      (async () => {
        const end = Date.now() + ms;
        while (Date.now() < end) {
          const hit = notesSince(tab, from).find((t) => re.test(t));
          if (hit) return hit;
          await sleep(250);
        }
        throw new Error(`не дождались исхода шлюза passkey: ${label}; было: ${JSON.stringify(notesSince(tab, from))}`);
      })();
    // ---- UA Android той же версии браузера: Flutter web → defaultTargetPlatform android → режим привязки
    const androidUa = () => {
      const full = (/\/(\d+(?:\.\d+){3})/.exec(R.browserVersion || '') || [])[1] || '157.0.0.0';
      const major = full.split('.')[0];
      const edge = BROWSER === 'edge';
      return {
        userAgent: `Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${full} Mobile Safari/537.36${edge ? ` EdgA/${full}` : ''}`,
        acceptLanguage: 'ru',
        platform: 'Linux armv8l',
        userAgentMetadata: { brands: [{ brand: 'Chromium', version: major }, { brand: edge ? 'Microsoft Edge' : 'Google Chrome', version: major }, { brand: 'Not_A Brand', version: '24' }], fullVersion: full, platform: 'Android', platformVersion: '14.0.0', architecture: '', model: 'Pixel 8', mobile: true },
      };
    };
    // ---- состояние записей passkey страницы (только признаки и числа) и сырые ключи страницы (для сравнения, не в отчёт)
    const pkState = (tab) => ev(tab, `PosDemoPage.passkey.state()`);
    const pkKeys = (tab) => ev(tab, `Object.keys(localStorage).filter((k) => k.indexOf('optomstroy.demo.passkey') === 0).map((k) => k.slice(16)).sort()`);
    const boundRaw = (tab) => ev(tab, `localStorage.getItem('optomstroy.demo.passkeyBound')`);
    const fp = (s) => (s === null || s === undefined ? 'none' : createHash('sha256').update(String(s)).digest('hex').slice(0, 12));
    // ---- пауза повторной отправки кода (OTP_RESEND_COOLDOWN_SECONDS = 10 в демо) между входами одного номера
    const otpAt = new Map();
    const otpGap = async (phone) => {
      const last = otpAt.get(phone);
      if (last) {
        const wait = 11500 - (Date.now() - last);
        if (wait > 0) await sleep(wait);
      }
      otpAt.set(phone, Date.now());
    };
    // Вход по SMS в интерфейсе; x.homeHash — рабочий экран роли (на нём «Меню разделов»).
    const login = async (x, phone9) => {
      await otpGap(phone9);
      const r = await staffLogin(x, phone9);
      x.homeHash = r.home;
      return r;
    };
    // ---- вкладка части: прежние вкладки сайта закрываются (замок вкладки, дескрипторы OPFS), хранилище сайта
    // очищается (Storage.clearDataForOrigin из сеанса новой вкладки; не вышло — start() сбросит демо кнопкой панели)
    const partTab = async (name, { ua = null } = {}) => {
      const { targetInfos } = await send('Target.getTargets');
      for (const t of targetInfos) if (t.type === 'page' && onOrigin(t.url)) await send('Target.closeTarget', { targetId: t.targetId }).catch(() => undefined);
      await sleep(1500);
      const tab = await openTab(name, { ua });
      const cleared = await send('Storage.clearDataForOrigin', { origin: ORIGIN, storageTypes: 'all' }, tab.sid).then(() => true, (e) => String(e?.message ?? e).slice(0, 200));
      return { tab, cleared };
    };
    // Первая загрузка части — без envcheck=0, как у пользователя: с UA Android страница предупреждает «Похоже, это
    // телефон» — «Всё равно продолжить» (признак envAck в хранилище страницы; boot убирает envcheck из адреса, и без
    // признака предупреждение вернулось бы после каждой перезагрузки шага).
    const startInfo = (tab) => ev(tab, `({ warm: __posDemo.info.warm, epochKey: __posDemo.info.epochKey, ua: navigator.userAgent.indexOf('Android') >= 0 ? 'android' : 'desktop', platform: navigator.platform, pk: PosDemoPage.passkey.state(), app: Object.keys(localStorage).filter((k) => k.indexOf('FlutterSecureStorage.') === 0).map((k) => k.slice(21)).sort() })`);
    const start = async (tab, label) => {
      await navigate(tab, url());
      const end = Date.now() + 180000;
      let env = false;
      for (;;) {
        const st = await ev(tab, `document.getElementById('pd-env-continue') ? 'env' : (window.__posDemo && __posDemo.isReady && window.PosDemoPage && PosDemoPage.boot.hidden && document.getElementById('pos-demo-fab')) ? 'ready' : 'wait'`, 10000).catch(() => 'nav');
        if (st === 'ready') break;
        if (st === 'env') {
          env = true;
          await shot(tab, `pk-${label}-envcheck`);
          await ev(tab, `document.getElementById('pd-env-continue').click(), true`).catch(() => undefined);
        }
        if (Date.now() > end) throw new Error(`${label}: демо не готово за 180 с`);
        await sleep(300);
      }
      await sleep(1200);
      let info = await startInfo(tab);
      // в браузере остались данные прежних шагов (вход, планшет, passkey) — «Сбросить демо» кнопкой панели
      const dirty = info.app.some((k) => k !== 'device.id') || info.pk.user || info.pk.gate || info.pk.bound;
      if (dirty) {
        await resetDemo(uiKit(tab, {}, `passkey/${label}`));
        await sleep(1200);
        info = { ...(await startInfo(tab)), resetBefore: info.app };
      }
      return { envNotice: env, label, ...info };
    };
    const f5 = async (tab) => {
      await send('Page.reload', {}, tab.sid);
      await appReady(tab, 120000);
    };
    // Новая загрузка страницы после кнопки панели (метка старой страницы пропала, демо готово).
    const reboot = async (tab, label, ms = 240000) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        const s = await ev(tab, `window.__pkOld ? 'old' : document.getElementById('pd-env-continue') ? 'env' : (window.__posDemo && __posDemo.isReady && window.PosDemoPage && PosDemoPage.boot.hidden && document.getElementById('pos-demo-fab')) ? 'ready' : 'wait'`, 10000).catch(() => 'nav');
        if (s === 'ready') return;
        if (s === 'env') await ev(tab, `document.getElementById('pd-env-continue').click(), true`).catch(() => undefined);
        await sleep(300);
      }
      throw new Error(`не дождались новой загрузки страницы: ${label}`);
    };
    const panelButton = async (x, id) => {
      await x.panelOpen('kiosk');
      await waitFor(x.tab, `!!document.getElementById(${JSON.stringify(id)})`, 15000, `панель: кнопка #${id}`);
      await ev(x.tab, `(window.__pkOld = true, document.getElementById(${JSON.stringify(id)}).click(), true)`);
    };
    const resetDemo = async (x) => {
      await x.panelOpen('service');
      await ev(x.tab, `document.getElementById('pd-reset').click(), true`);
      await waitFor(x.tab, `!document.getElementById('pd-reset-confirm').hidden`, 5000, 'подтверждение «Сбросить»');
      await ev(x.tab, `(window.__pkOld = true, document.getElementById('pd-reset-yes').click(), true)`);
      await reboot(x.tab, '«Сбросить демо»');
    };
    // ---- экраны приложения
    // Кнопки биометрии SCR-08 на экране (по точной подписи).
    const bioButtons = (tab) => ev(tab, `(() => { const want = ${JSON.stringify(BIO_BUTTONS)}; const out = [];
      for (const n of document.querySelectorAll('flt-semantics, flt-semantics *')) { const l = (n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').trim();
        const r = n.getBoundingClientRect(); if (want.includes(l) && r.width > 1 && r.height > 1 && !out.includes(l)) out.push(l); } return out; })()`);
    // SCR-08: клавиатура PIN на экране (кнопка «7»).
    const atUnlock = async (tab, label, ms = 40000) => {
      await semanticsOn(tab).catch(() => undefined);
      await waitFor(tab, `!!(${findExact('7')})`, ms, `${label}: SCR-08, клавиатура PIN`);
    };
    const home = (x, ms = 40000) => x.waitText('Меню разделов', ms, 'рабочий экран сотрудника («Меню разделов»)').then(() => true, () => false);
    // Элемент по выражению: вне окна — прокрутка колесом мыши над серединой окна (до 10 раз).
    const clickVisible = async (x, expr, label) => {
      for (let i = 0; i < 10; i++) {
        const b = await ev(x.tab, expr);
        if (b && b.y > 8 && b.y < 792) {
          await click(x.tab, b.x, b.y);
          return b;
        }
        await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: 640, y: 420, deltaX: 0, deltaY: b && b.y < 8 ? -300 : 300 }, x.tab.sid);
        await sleep(600);
      }
      throw new Error(`нет элемента в окне: ${label}; видно: ${JSON.stringify((await x.allTexts()).slice(0, 40))}`);
    };
    // Тумблер по точной подписи: узел семантики переключателя (role switch / aria-checked) и его состояние.
    const switchExpr = (label) => `(() => { const want = ${JSON.stringify(label)}; let best = null;
      for (const n of document.querySelectorAll('flt-semantics, flt-semantics *')) {
        const l = (n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').trim();
        if (l !== want) continue; const sw = n.closest('[aria-checked], [role="switch"]') || n; const r = sw.getBoundingClientRect(); if (r.width < 2 || r.height < 2) continue;
        const area = r.width * r.height;
        if (!best || area < best.area) best = { area, x: r.left + r.width / 2, y: r.top + r.height / 2, checked: sw.getAttribute('aria-checked'), disabled: sw.getAttribute('aria-disabled'), role: sw.getAttribute('role') }; }
      return best; })()`;
    // SCR-42 «Защита входа»: тумблер биометрии с одной из подписей (по режиму).
    const toSettings = async (x, labels) => {
      await ev(x.tab, `(location.hash = '#/settings', true)`);
      await x.waitHash('/settings', 20000, 'SCR-42');
      await semanticsOn(x.tab).catch(() => undefined);
      const any = `(${labels.map((l) => `!!${switchExpr(l)}`).join(' || ')})`;
      const seen = await waitFor(x.tab, any, 12000, 'SCR-42: тумблер биометрии').then(() => true, () => false);
      if (!seen) {
        await x.clickText('Защита входа');
        await waitFor(x.tab, any, 15000, `SCR-42: тумблер ${labels.join(' / ')}`);
      }
      for (const l of labels) if (await ev(x.tab, switchExpr(l))) return l;
      throw new Error('SCR-42: тумблер биометрии пропал');
    };
    const snackExpr = `(() => { const s = ${JSON.stringify(SNACK)}; const all = [...document.querySelectorAll('flt-semantics, flt-semantics *')].map((n) => (n.getAttribute('aria-label') || '') + ' ' + (n.childElementCount === 0 ? n.textContent : ''));
      for (const k of Object.keys(s)) if (all.some((t) => t.indexOf(s[k]) >= 0)) return k; return null; })()`;
    // Включение тумблера биометрии SCR-42: согласие biometrics_device (если спрошено) → итог по снекбару.
    const enableBio = async (x, labels, prefix) => {
      const tab = x.tab;
      const label = await toSettings(x, labels);
      const before = await ev(tab, switchExpr(label));
      await shot(tab, `${prefix}-scr42`);
      const m = waMark();
      await clickVisible(x, switchExpr(label), `тумблер «${label}»`);
      const first = await waitFor(tab, `${x.semExpr('Согласие на вход по биометрии')} ? 'consent' : ${snackExpr}`, 60000, 'SCR-42: согласие или итог включения');
      let consent = false;
      if (first === 'consent') {
        consent = true;
        await sleep(900);
        await shot(tab, `${prefix}-consent`);
        await clickVisible(x, findExact('Согласен'), '«Согласен»');
        await sleep(500);
        await clickVisible(x, findExact('Включить'), '«Включить»');
      }
      const snack = first === 'consent' ? await waitFor(tab, snackExpr, 60000, 'SCR-42: итог включения (снекбар)') : first;
      await sleep(900);
      await shot(tab, `${prefix}-enabled`);
      return { label, consent, snack, before: before && { checked: before.checked, disabled: before.disabled, role: before.role }, added: waCount(tab, m, 'credentialAdded'), asserted: waCount(tab, m, 'credentialAsserted'), events: waNames(tab, m) };
    };
    // Профиль: «Выйти» (подтверждение → SCR-01).
    const toProfile = async (x) => {
      await ev(x.tab, `(location.hash = '#/profile', true)`);
      await x.waitHash('/profile', 20000, 'профиль');
      await semanticsOn(x.tab).catch(() => undefined);
      await sleep(800);
    };
    // Блокировка = холодный старт SCR-08 (F5 на рабочем экране роли). Слой блокировки в сессии («Заблокировать»,
    // простой) — PIN-вариант SessionLockOverlay без биометрии (SessionGate.lockScreenBuilder не задан, как до ADR-116),
    // кнопки биометрии — только на SCR-08 `cold`.
    const toHome = async (x) => {
      if (x.homeHash && !(await x.hash()).startsWith(x.homeHash)) await ev(x.tab, `(location.hash = ${JSON.stringify(x.homeHash)}, true)`);
      await x.waitText('Меню разделов', 30000, 'рабочий экран роли перед F5');
    };
    const coldLock = async (x, label) => {
      await toHome(x);
      await f5(x.tab);
      const h = await x.waitHash('/auth/unlock', 30000, `${label}: SCR-08 после F5`);
      await atUnlock(x.tab, label);
      return h;
    };
    const logout = async (x) => {
      await toProfile(x);
      await clickVisible(x, findExact('Выйти'), 'профиль: «Выйти»');
      await x.waitText('Выйти из аккаунта?', 10000, 'подтверждение выхода');
      await sleep(700);
      await x.clickExact('Выйти');
      await x.waitText('Получить код', 30000, 'SCR-01 после «Выйти»');
    };
    // Кнопка биометрии SCR-08 по подписи (нампад тоже может нести клавишу биометрии — берётся кнопка с этой подписью).
    const pressBio = (x, label) => clickVisible(x, findExact(label), `SCR-08: «${label}»`);
    // GET /auth/sessions пользователя через мост (вход по SMS с отдельного устройства smoke): сессии kind=biometric.
    const bioSessions = async (tab, phone) => {
      await otpGap(phone.slice(-9));
      const { token } = await apiLogin(tab, phone, { device: crypto.randomUUID() });
      const list = (await api(tab, 'GET', '/auth/sessions', { token })).json?.items ?? [];
      return list.filter((s) => s.kind === 'biometric').map((s) => ({ id: s.id, platform: s.platform, lastUsedAt: s.lastUsedAt ?? null }));
    };
    const fail = async (part, rec, tab, e) => {
      rec.error = String(e?.message ?? e).slice(0, 1500);
      rec.texts = await ev(tab, `[...document.querySelectorAll('flt-semantics')].map((n) => n.getAttribute('aria-label') || (n.childElementCount === 0 ? n.textContent : '') || '').map((s) => s.trim()).filter(Boolean).slice(0, 40)`).catch(() => null);
      rec.hash = await ev(tab, 'location.hash').catch(() => null);
      rec.notes = notesSince(tab, 0).slice(-12);
      check(`passkey (${part}) без исключения (этап «${rec.stage}»)`, false, rec.error.slice(0, 900));
      await shot(tab, `pk-${part}-error`).catch(() => undefined);
    };

    // ======== gate — T-DEMO-017: браузер на Windows, аутентификатор без PRF (гейт перед PIN)
    if (PK_PARTS.has('gate')) {
      const g = (PK.gate = {});
      const { tab: G, cleared } = await partTab('PG');
      g.cleared = cleared;
      const x = uiKit(G, g, 'passkey/gate');
      try {
        x.stage('загрузка');
        await addAuth(G, { hasPrf: false });
        g.start = await start(G, 'gate');
        g.capability = await ev(G, `__posPasskey.capability({ mode: 'gate' })`);
        x.stage('вход 906');
        await login(x, '777000906');
        // ---- (1) SCR-42: включение. Режим ключа браузера на Windows (LF-3-06, «Вход через Windows Hello»: клиент
        // сообщает PRF, сервер разрешает ключ — AUTH_WINDOWS_HELLO_KEY=all) — согласие, passkey создаётся без PRF →
        // снекбар settings_hello_key_no_prf, ключ входа не создан, включён гейт; без режима ключа (сборка до LF-3-06) —
        // «Windows Hello перед вводом PIN» без согласия и «включён».
        x.stage('SCR-42 включение');
        const en = await enableBio(x, ['Вход через Windows Hello', 'Windows Hello перед вводом PIN'], 'pk-gate');
        const st1 = await pkState(G);
        const creds1 = await credList(G);
        // секция после включения (в режиме ключа — перечитана после снекбара): тумблер гейта включён
        await waitFor(G, `!!${switchExpr('Windows Hello перед вводом PIN')}`, 15000, 'SCR-42: «Windows Hello перед вводом PIN» после включения').catch(() => undefined);
        const label1 = await toSettings(x, ['Windows Hello перед вводом PIN', 'Вход через Windows Hello']);
        const sw1 = await ev(G, switchExpr(label1));
        g.enable = { ...en, state: st1, credentials: creds1.length, after: { label: label1, checked: sw1?.checked ?? null } };
        const keyMode = en.label === 'Вход через Windows Hello';
        check(
          `T-DEMO-017 (1) браузер на Windows, аутентификатор без PRF: SCR-42 «${en.label}» → ${keyMode ? 'согласие → ' : ''}passkey создан (credentialAdded), ${keyMode ? 'снекбар settings_hello_key_no_prf — ключ входа не создан, секция перечитана: «Windows Hello перед вводом PIN» включён' : 'снекбар «Вход по биометрии включён» (режим гейта W1; режима ключа LF-3-06 в сборке нет)'}; запись гейта, признак «PRF нет», блоба привязки и ключей входа нет`,
          en.added === 1 && en.asserted === 0 && en.snack === (keyMode ? 'noPrf' : 'ok') && en.consent === keyMode && st1.gate && st1.noPrf && !st1.bound && st1.keys === 0 && creds1.length === 1 && g.start.ua === 'desktop' &&
            label1 === 'Windows Hello перед вводом PIN' && sw1?.checked === 'true',
          { label: en.label, keyMode, snack: en.snack, consent: en.consent, added: en.added, asserted: en.asserted, state: st1, credentials: creds1.length, after: g.enable.after, start: g.start, capability: g.capability },
        );

        // ---- (2) F5 → SCR-08: «Windows Hello» без автовызова → PIN обязателен
        x.stage('F5 → SCR-08');
        await toHome(x);
        const m2 = waMark();
        await f5(G);
        const unlock2 = await x.waitHash('/auth/unlock', 30000, 'SCR-08 после F5');
        await atUnlock(G, 'F5');
        await x.waitText('Windows Hello', 20000, 'SCR-08: кнопка «Windows Hello»');
        await sleep(2500);
        const auto2 = waCount(G, m2);
        const buttons2 = await bioButtons(G);
        await shot(G, 'pk-gate-scr08');
        await pressBio(x, 'Windows Hello');
        const verified2 = await x.waitText('Подтверждено Windows Hello', 20000, '«Подтверждено Windows Hello · введите PIN»').then(() => true, () => false);
        await sleep(800);
        const locked2 = (await x.hash()).startsWith('#/auth/unlock') && !(await x.has('Меню разделов'));
        await shot(G, 'pk-gate-verified');
        await x.digits('715382');
        const home2 = await home(x);
        g.f5 = { unlock: unlock2, auto: auto2, buttons: buttons2, verified: verified2, lockedUntilPin: locked2, home: home2, events: waNames(G, m2) };
        check(
          'T-DEMO-017 (2) F5 → SCR-08 `cold`: кнопка «Windows Hello» без автовызова → credentialAsserted → «Подтверждено Windows Hello · введите PIN», без PIN рабочего экрана нет → PIN 715382 → рабочий экран',
          /mode=cold/.test(unlock2) && auto2 === 0 && buttons2.includes('Windows Hello') && verified2 && locked2 && home2 && waCount(G, m2, 'credentialAsserted') === 1 && waCount(G, m2, 'credentialAdded') === 0,
          g.f5,
        );

        // ---- (3) «Выйти» → вход по SMS → блокировка (F5) → «Windows Hello» тем же ключом
        x.stage('«Выйти» → вход по SMS');
        const m3 = waMark();
        await logout(x);
        const st3a = await pkState(G);
        await login(x, '777000906');
        x.stage('блокировка (F5) → «Windows Hello»');
        await coldLock(x, 'блокировка после входа по SMS');
        await x.waitText('Windows Hello', 20000, 'SCR-08 после входа по SMS: «Windows Hello»');
        const buttons3 = await bioButtons(G);
        await pressBio(x, 'Windows Hello');
        const verified3 = await x.waitText('Подтверждено Windows Hello', 20000, '«Подтверждено Windows Hello · введите PIN»').then(() => true, () => false);
        await x.digits('715382');
        const home3 = await home(x);
        const creds3 = await credList(G);
        await shot(G, 'pk-gate-after-logout');
        g.relogin = { stateAfterLogout: st3a, buttons: buttons3, verified: verified3, home: home3, credentials: creds3.length, events: waNames(G, m3) };
        check(
          'T-DEMO-017 (3) «Выйти» (запись гейта осталась) → вход по SMS → блокировка (F5, SCR-08 `cold`) → «Windows Hello» → PIN → рабочий экран тем же ключом: нет ни credentialAdded, ни credentialDeleted',
          st3a.gate && buttons3.includes('Windows Hello') && verified3 && home3 && waCount(G, m3, 'credentialAdded') === 0 && waCount(G, m3, 'credentialDeleted') === 0 && waCount(G, m3, 'credentialAsserted') === 1 && creds3.length === 1,
          g.relogin,
        );

        // ---- (4) T-DEMO-019 (4) для гейта: ключ удалён из аутентификатора → «Windows Hello не подтвердил вход» → PIN
        if (PK_PARTS.has('neg')) {
          x.stage('ключ гейта удалён');
          await send('WebAuthn.clearCredentials', { authenticatorId: G.auth }, G.sid);
          const m4 = waMark();
          const n4 = noteMark();
          await coldLock(x, 'ключ гейта удалён');
          await pressBio(x, 'Windows Hello');
          const outcome4 = await waitNote(G, n4, /^confirmPresence: /, 75000, 'confirmPresence после удаления ключа');
          const failed4 = await x.waitText('Windows Hello не подтвердил вход', 20000, '«Windows Hello не подтвердил вход. Введите PIN»').then(() => true, () => false);
          await shot(G, 'pk-gate-deleted');
          await x.digits('715382');
          const home4 = await home(x);
          g.deleted = { outcome: outcome4, failed: failed4, home: home4, events: waNames(G, m4) };
          check(
            'T-DEMO-019 (4) гейт: ключ удалён из аутентификатора → исход cancelled («Windows Hello не подтвердил вход. Введите PIN»), PIN → рабочий экран',
            /^confirmPresence: cancelled/.test(outcome4) && failed4 && home4 && waCount(G, m4, 'credentialAsserted') === 0,
            g.deleted,
          );
        }

        // ---- (5) «Сбросить демо»: ОС сообщается о passkey сайта (signalUnknownCredential), записи passkey удалены
        x.stage('«Сбросить демо»');
        const m5 = waMark();
        await resetDemo(x);
        const wipe = await ev(G, `PosDemoPage.boot.lastWipe && { ok: PosDemoPage.boot.lastWipe.ok, passkeys: PosDemoPage.boot.lastWipe.passkeys }`);
        const st5 = await pkState(G);
        const keys5 = await pkKeys(G);
        g.reset = { wipe, state: st5, keys: keys5, events: waNames(G, m5) };
        check(
          '«Сбросить демо» (ADR-116 п. 1): passkey сайта сообщены ОС (signalUnknownCredential), записи passkey страницы удалены',
          wipe?.ok === true && (wipe.passkeys?.signalled ?? 0) >= 1 && !st5.gate && !st5.user && !st5.bound && !st5.noPrf && keys5.length === 0,
          g.reset,
        );
      } catch (e) {
        await fail('gate', g, G, e);
      }
    }

    // ======== winkey — T-DEMO-024: браузер на Windows с PRF — вход без PIN приложения (ключ входа, путь hello_key)
    if (PK_PARTS.has('winkey')) {
      const w = (PK.winkey = {});
      const { tab: W, cleared } = await partTab('PW');
      w.cleared = cleared;
      const x = uiKit(W, w, 'passkey/winkey');
      // Запросы приложения к мосту (__posDemo.request): метод, путь и признаки тела /me/biometrics и /auth/unlock* —
      // без значений ключа, подписи, PIN и токенов. Ставится до скриптов страницы и переживает F5 (новый журнал).
      await send('Page.addScriptToEvaluateOnNewDocument', { source: REQ_TRACE }, W.sid);
      const trace = () => ev(W, `(window.__pkTrace || []).slice()`);
      const unlockCalls = (list) => list.filter((e) => /^\/auth\/unlock/.test(e.path));
      try {
        x.stage('загрузка');
        await addAuth(W, { hasPrf: true });
        w.start = await start(W, 'winkey');
        w.capability = await ev(W, `__posPasskey.capability({ mode: 'gate' })`);
        x.stage('вход 906');
        await login(x, '777000906');

        // ---- (1) SCR-42 «Вход через Windows Hello» → согласие → ключ входа под PRF → POST helloKey.source=webauthn_prf
        x.stage('SCR-42 включение');
        const t1 = (await trace()).length;
        const en = await enableBio(x, ['Вход через Windows Hello', 'Windows Hello перед вводом PIN'], 'pk-winkey');
        const st1 = await pkState(W);
        const keys1 = await pkKeys(W);
        const raw1 = await ev(W, `localStorage.getItem('optomstroy.demo.passkeyHelloKey')`);
        let items1 = null;
        try {
          const parsed = JSON.parse(raw1 || 'null');
          items1 = parsed && parsed.items ? Object.values(parsed.items).map((it) => Object.keys(it).sort().join(',')) : null;
        } catch {
          items1 = null;
        }
        const posts1 = (await trace()).slice(t1).filter((e) => e.method === 'POST' && e.path === '/me/biometrics');
        const creds1 = await credList(W);
        w.enable = { ...en, state: st1, keys: keys1, items: items1, blobFp: fp(raw1), posts: posts1, credentials: creds1.length };
        check(
          'T-DEMO-024 (1) браузер на Windows, аутентификатор с PRF: SCR-42 «Вход через Windows Hello» → согласие → passkey создан → снекбар «Вход по биометрии включён»; POST /me/biometrics {biometricClass: windows_hello, helloKey: {source: webauthn_prf, RS256}}; в хранилище страницы — только зашифрованный ключ входа (passkeyHelloKey: credId, iv, ct), без JWT-подобных строк; блоба привязки нет',
          en.label === 'Вход через Windows Hello' && en.consent && en.snack === 'ok' && en.added === 1 && creds1.length === 1 &&
            posts1.length === 1 && posts1[0].body?.enabled === true && posts1[0].body.biometricClass === 'windows_hello' && posts1[0].body.helloKeySource === 'webauthn_prf' && posts1[0].body.helloKeyAlgorithm === 'RS256' && posts1[0].body.publicKey === true &&
            st1.keys === 1 && st1.gate && !st1.bound && !st1.noPrf && keys1.includes('passkeyHelloKey') && !keys1.includes('passkeyBound') &&
            Array.isArray(items1) && items1.length === 1 && items1[0] === 'credId,ct,iv' && !JWT_RE.test(String(raw1)) && w.capability?.keysSupported === true,
          { label: en.label, consent: en.consent, snack: en.snack, added: en.added, asserted: en.asserted, posts: posts1, state: st1, keys: keys1, items: items1, capability: w.capability, start: w.start },
        );

        // ---- (2) F5 → SCR-08 `cold`: «Войти через Windows Hello» без автовызова → один get() → challenge → hello_key
        x.stage('F5 → «Войти через Windows Hello»');
        const unlock = async (label, prefix) => {
          const m = waMark();
          const h = await coldLock(x, label);
          await x.waitText('Войти через Windows Hello', 20000, `${label}: SCR-08 «Войти через Windows Hello»`);
          await sleep(2500);
          const auto = waCount(W, m);
          const buttons = await bioButtons(W);
          await shot(W, `${prefix}-scr08`);
          await pressBio(x, 'Войти через Windows Hello');
          const ok = await home(x);
          await shot(W, `${prefix}-home`);
          const calls = unlockCalls(await trace());
          return {
            unlock: h,
            auto,
            buttons,
            home: ok,
            asserted: waCount(W, m, 'credentialAsserted'),
            added: waCount(W, m, 'credentialAdded'),
            deleted: waCount(W, m, 'credentialDeleted'),
            calls,
            events: waNames(W, m),
          };
        };
        const helloKeyPath = (r) =>
          r.calls.length === 2 && r.calls[0].path === '/auth/unlock/challenge' && r.calls[0].method === 'POST' &&
          r.calls[1].path === '/auth/unlock' && r.calls[1].body?.method === 'hello_key' && r.calls[1].body.signature === true && r.calls[1].body.pin === false;
        const r2 = await unlock('F5', 'pk-winkey');
        w.f5 = r2;
        check(
          'T-DEMO-024 (2) F5 → SCR-08 `cold`: кнопка «Войти через Windows Hello» без автовызова → ровно один credentialAsserted → POST /auth/unlock/challenge и POST /auth/unlock {method: hello_key} → рабочий экран без PIN приложения',
          /mode=cold/.test(r2.unlock) && r2.auto === 0 && r2.buttons.includes('Войти через Windows Hello') && r2.home && r2.asserted === 1 && r2.added === 0 && helloKeyPath(r2),
          r2,
        );

        // ---- (3) «Выйти» (ключ входа остаётся) → вход по SMS → блокировка (F5) → тот же ключ без PIN
        x.stage('«Выйти» → вход по SMS → блокировка');
        await logout(x);
        const st3a = await pkState(W);
        await login(x, '777000906');
        const r3 = await unlock('после входа по SMS', 'pk-winkey-relogin');
        const creds3 = await credList(W);
        w.relogin = { stateAfterLogout: st3a, ...r3, credentials: creds3.length };
        check(
          'T-DEMO-024 (3) «Выйти» (ключ входа остался на странице) → вход по SMS → блокировка (F5) → «Войти через Windows Hello» → рабочий экран без PIN тем же ключом: нет ни credentialAdded, ни credentialDeleted',
          st3a.keys === 1 && st3a.gate && r3.home && r3.asserted === 1 && r3.added === 0 && r3.deleted === 0 && helloKeyPath(r3) && creds3.length === 1,
          w.relogin,
        );
      } catch (e) {
        await fail('winkey', w, W, e);
      }
    }

    // ======== bound — T-DEMO-018: UA Android, аутентификатор с PRF (вход без PIN); neg — T-DEMO-019
    if (PK_PARTS.has('bound')) {
      const b = (PK.bound = {});
      const { tab: D, cleared } = await partTab('PD', { ua: androidUa() });
      b.cleared = cleared;
      const x = uiKit(D, b, 'passkey/bound');
      try {
        x.stage('загрузка (UA Android)');
        await addAuth(D, { hasPrf: true });
        b.start = await start(D, 'bound');
        b.capability = await ev(D, `__posPasskey.capability({ mode: 'bound' })`);
        x.stage('вход 906');
        await login(x, '777000906');
        // ---- (1) SCR-42 «Вход по отпечатку или лицу» → согласие → блоб без JWT-подобных строк
        x.stage('SCR-42 включение');
        const en = await enableBio(x, ['Вход по отпечатку или лицу'], 'pk-bound');
        const st1 = await pkState(D);
        const raw1 = await boundRaw(D);
        const page1 = await ev(D, `JSON.stringify(Object.keys(localStorage).filter((k) => k.indexOf('optomstroy.demo.') === 0).map((k) => localStorage.getItem(k)))`);
        b.enable = { ...en, state: st1, blob: fp(raw1), jwtInPage: JWT_RE.test(page1) };
        check(
          'T-DEMO-018 (1) UA Android: SCR-42 «Вход по отпечатку или лицу» → согласие → passkey создан (credentialAdded) → «Вход по биометрии включён»; в хранилище страницы — блоб привязки, без JWT-подобных строк',
          b.start.ua === 'android' && en.added === 1 && en.snack === 'ok' && en.consent && st1.bound && !st1.gate && !!raw1 && !JWT_RE.test(page1) && b.capability?.kind === 'android_class3',
          { ...b.enable, start: b.start, capability: b.capability },
        );
        // сессия kind=biometric до входа (для сравнения времени использования)
        x.stage('сессии до F5');
        const s0 = await bioSessions(D, '+996777000906');
        // ---- (2) F5 → автовызов SCR-08 → ровно один credentialAsserted → рабочий экран без PIN
        x.stage('F5 → вход passkey');
        await toHome(x);
        const m2 = waMark();
        const n2 = noteMark();
        await f5(D);
        await semanticsOn(D).catch(() => undefined);
        const home2 = await home(x, 60000);
        await sleep(2500);
        const raw2 = await boundRaw(D);
        const asserted2 = waCount(D, m2, 'credentialAsserted');
        await shot(D, 'pk-bound-home');
        x.stage('сессии после F5');
        const s1 = await bioSessions(D, '+996777000906');
        const used = s1.find((s) => s.platform === 'android' && s0.some((o) => o.id === s.id && (o.lastUsedAt ?? '') < (s.lastUsedAt ?? '')));
        b.f5 = { home: home2, asserted: asserted2, events: waNames(D, m2), notes: notesSince(D, n2), blobBefore: fp(raw1), blobAfter: fp(raw2), sessionsBefore: s0, sessionsAfter: s1, used: used ?? null };
        check(
          'T-DEMO-018 (2) F5 → автовызов SCR-08 → ровно один credentialAsserted → рабочий экран без PIN; новый токен перешифрован без второго диалога (блоб обновлён); через мост — сессия kind=biometric (android) использована при входе',
          home2 && asserted2 === 1 && waCount(D, m2, 'credentialAdded') === 0 && !!raw2 && raw2 !== raw1 && !JWT_RE.test(raw2) && !!used,
          b.f5,
        );

        // ======== neg — T-DEMO-019 (UA Android)
        if (PK_PARTS.has('neg')) {
          const n = (PK.neg = {});
          const [cred] = await credList(D);
          const copy = cred && { credentialId: cred.credentialId, isResidentCredential: cred.isResidentCredential, rpId: cred.rpId, privateKey: cred.privateKey, userHandle: cred.userHandle, signCount: cred.signCount };
          // F5 → SCR-08: исход чтения блоба шлюзом страницы, клавиатура PIN, без рабочего экрана; затем PIN → рабочий экран.
          const unlockAfterF5 = async (label, re) => {
            await toHome(x);
            const m = waMark();
            const k = noteMark();
            await f5(D);
            const outcome = await waitNote(D, k, re, 75000, label);
            await atUnlock(D, label);
            await sleep(1500);
            const homeBeforePin = await x.has('Меню разделов');
            const st = await pkState(D);
            await shot(D, `pk-neg-${label}`);
            await x.digits('715382');
            const homeAfter = await home(x);
            return { outcome, homeBeforePin, homeAfter, state: st, asserted: waCount(D, m, 'credentialAsserted'), events: waNames(D, m) };
          };
          // (4) ключ удалён из аутентификатора (как passkey, удалённый в ОС) → cancelled, поле PIN, блоб цел
          x.stage('(4) ключ удалён');
          await send('WebAuthn.removeCredential', { authenticatorId: D.auth, credentialId: cred.credentialId }, D.sid);
          n.deleted = await unlockAfterF5('deleted', /^read: /);
          check(
            'T-DEMO-019 (4) привязка: ключ удалён из аутентификатора → F5 → исход cancelled, поле PIN (рабочего экрана без PIN нет), блоб не удалён → PIN → рабочий экран',
            /^read: cancelled/.test(n.deleted.outcome) && !n.deleted.homeBeforePin && n.deleted.state.bound && n.deleted.asserted === 0 && n.deleted.homeAfter,
            n.deleted,
          );
          // (1) замена аутентификатора: тот же ключ, проверка пользователя не проходит → поле PIN
          x.stage('(1) без проверки пользователя');
          await removeAuth(D);
          await addAuth(D, { hasPrf: true, isUserVerified: false });
          await send('WebAuthn.addCredential', { authenticatorId: D.auth, credential: copy }, D.sid);
          n.noUv = await unlockAfterF5('no-uv', /^read: /);
          check(
            'T-DEMO-019 (1) привязка: аутентификатор заменён на не прошедший проверку пользователя (тот же ключ) → вход лицом не проходит (cancelled/failed), поле PIN, блоб цел → PIN → рабочий экран',
            /^read: (cancelled|failed)/.test(n.noUv.outcome) && !n.noUv.homeBeforePin && n.noUv.state.bound && n.noUv.homeAfter,
            n.noUv,
          );
          // (2) замена аутентификатора: ключ addCredential без PRF → invalidated, блоб удалён; как у ключа Android,
          // инвалидированного ОС (02 SCR-08.4 п. 7; 09 BIO-014): SCR-01 с причиной bio_invalidated → вход по SMS
          x.stage('(2) addCredential без PRF');
          await removeAuth(D);
          await addAuth(D, { hasPrf: true, isUserVerified: true });
          await send('WebAuthn.addCredential', { authenticatorId: D.auth, credential: copy }, D.sid);
          await toHome(x);
          const m2n = waMark();
          const k2n = noteMark();
          await f5(D);
          const outcome2 = await waitNote(D, k2n, /^read: /, 75000, 'no-prf');
          await semanticsOn(D).catch(() => undefined);
          const banner2 = await x.waitText('Биометрия на устройстве изменилась', 30000, 'SCR-01: «Биометрия на устройстве изменилась…»').then(() => true, () => false);
          const hash2 = await x.hash();
          const st2n = await pkState(D);
          await shot(D, 'pk-neg-no-prf');
          // баннер причины сдвигает форму SCR-01, а staffLogin берёт координаты до своей перезагрузки (после неё баннера
          // нет) — сначала адрес SCR-01 без причины и F5
          await ev(D, `(location.hash = '#/auth/phone', true)`);
          await sleep(800);
          await f5(D);
          await login(x, '777000906');
          n.noPrf = { outcome: outcome2, banner: banner2, hash: hash2, state: st2n, asserted: waCount(D, m2n, 'credentialAsserted'), events: waNames(D, m2n), relogin: x.homeHash };
          check(
            'T-DEMO-019 (2) привязка: ключ перенесён addCredential без PRF → F5 → credentialAsserted, исход invalidated → блоб удалён → SCR-01 «Биометрия на устройстве изменилась. Войдите по номеру телефона и включите вход заново» (bio_invalidated, 02 SCR-08.4 п. 7) → вход по SMS',
            /^read: invalidated/.test(outcome2) && n.noPrf.asserted === 1 && banner2 && /reason=bio_invalidated/.test(hash2) && !st2n.bound && !!x.homeHash,
            n.noPrf,
          );
          // (3) аутентификатора нет → вариант скрыт: тумблер SCR-42 неактивен; SCR-08 без кнопки биометрии
          x.stage('(3) аутентификатора нет');
          await removeAuth(D);
          const cap3 = await ev(D, `__posPasskey.capability({ mode: 'bound' })`);
          const label3 = await toSettings(x, ['Вход по отпечатку или лицу']);
          const sw3 = await ev(D, switchExpr(label3));
          await shot(D, 'pk-neg-no-authenticator');
          await toHome(x);
          const m3 = waMark();
          await f5(D);
          await atUnlock(D, 'без аутентификатора');
          await sleep(2500);
          const buttons3 = await bioButtons(D);
          await x.digits('715382');
          const home3 = await home(x);
          n.none = { capability: cap3, switch: sw3 && { checked: sw3.checked, disabled: sw3.disabled, role: sw3.role }, buttons: buttons3, home: home3, events: waNames(D, m3) };
          check(
            'T-DEMO-019 (3) аутентификатора нет → вариант скрыт: capability no_platform_authenticator, тумблер «Вход по отпечатку или лицу» SCR-42 неактивен, на SCR-08 нет кнопки биометрии',
            cap3?.reason === 'no_platform_authenticator' && sw3?.disabled === 'true' && buttons3.length === 0 && home3 && waCount(D, m3) === 0,
            n.none,
          );
        }
      } catch (e) {
        await fail('bound', b, D, e);
      }
    }

    // ======== kiosk — T-DEMO-023 и T-DEMO-022: планшет магазина (UA Android, аутентификатор с PRF)
    if (PK_PARTS.has('kiosk')) {
      const k = (PK.kiosk = {});
      const { tab: T, cleared } = await partTab('PK', { ua: androidUa() });
      k.cleared = cleared;
      const x = uiKit(T, k, 'passkey/kiosk');
      const slotRaw = (name) => ev(T, `localStorage.getItem('optomstroy.demo.kioskSlot.' + ${JSON.stringify(name)})`);
      const slotPageKeys = async (name) => {
        const raw = await slotRaw(name);
        try {
          return raw ? Object.keys(JSON.parse(raw).page || {}).map((s) => s.replace(/^optomstroy\.demo\./, '')).sort() : null;
        } catch {
          return ['broken'];
        }
      };
      try {
        x.stage('загрузка (UA Android)');
        await addAuth(T, { hasPrf: true });
        k.start = await start(T, 'kiosk');
        // ---- T-DEMO-023 (1): администратор 901 с включённым passkey подключает браузер планшетом → блоба нет
        x.stage('вход 901');
        await login(x, '777000901');
        x.stage('SCR-42 включение 901');
        const en1 = await enableBio(x, ['Вход по отпечатку или лицу'], 'pk-kiosk-admin');
        const st1 = await pkState(T);
        x.stage('SCR-54 подключение');
        await toHome(x);
        await openTablets(x);
        await x.waitText('Сделать это устройство планшетом магазина', 30000, 'SCR-54');
        await sleep(1000);
        const codeShown = await enrollThisDevice(x, 'pk-kiosk');
        await x.clickExact('Готово');
        const h1 = await x.waitHash('/kiosk', 60000, 'SCR-51 после «Готово»');
        await semanticsOn(T);
        await x.waitText('Начать заново', 60000, 'SCR-51: витрина');
        await sleep(2000);
        const st2 = await pkState(T);
        const keys2 = await pkKeys(T);
        k.connect = { enable: en1, stateBefore: st1, codeShown, hash: h1, stateAfter: st2, keys: keys2, slotNormal: await ev(T, `PosDemoPage.kiosk.slotInfo('normal')`) };
        check(
          'T-DEMO-023 (1) администратор 901 с включённым passkey (блоб привязки) → SCR-54 «Сделать это устройство планшетом магазина» → SCR-51: блоба администратора нет (ни в хранилище страницы, ни в месте «обычный вход»)',
          en1.snack === 'ok' && en1.added === 1 && st1.bound && codeShown && h1.startsWith('#/kiosk') && !st2.bound && !keys2.includes('passkeyBound') && !k.connect.slotNormal?.bound,
          k.connect,
        );
        // ---- T-DEMO-023 (2): сессия планшета SCR-51 → SCR-52 → SCR-53 и холодный старт — ни одного события WebAuthn
        x.stage('сессия планшета');
        const mK = waMark();
        const nK = noteMark();
        const buttons51 = await bioButtons(T);
        const order = await kioskOrder(x, 'pk-kiosk');
        await x.clickExact('Готово');
        await waitFor(T, `location.hash === '#/kiosk' || location.hash.indexOf('#/kiosk?') === 0`, 60000, 'SCR-51 после «Готово»');
        x.stage('холодный старт планшета');
        await f5(T);
        const h2 = await x.waitHash('/kiosk', 60000, 'SCR-51 после F5');
        await semanticsOn(T);
        await x.waitText('Начать заново', 60000, 'SCR-51 после F5: витрина');
        await sleep(2500);
        const buttons51b = await bioButtons(T);
        await shot(T, 'pk-kiosk-cold');
        k.session = { buttons: buttons51, buttonsCold: buttons51b, order: { done: order.done, number: order.number }, hash: h2, events: waNames(T, mK), notes: notesSince(T, nK) };
        check(
          'T-DEMO-023 (2) сессия планшета: SCR-51 → заявка SCR-52 → SCR-53 → «Готово», холодный старт (F5) → SCR-51 — ни одного события WebAuthn и вызова шлюза passkey, на SCR-51 нет кнопок биометрии',
          order.done.startsWith('#/kiosk/done') && !!order.number && h2.startsWith('#/kiosk') && buttons51.length === 0 && buttons51b.length === 0 && waCount(T, mK) === 0 && notesSince(T, nK).length === 0,
          k.session,
        );

        // ---- T-DEMO-022 (1): «Вернуться к обычному входу» → кассир 906 включает passkey → «Планшет магазина»: блоб уехал
        // в место «обычный вход», записи гейта и пользователя passkey остались на странице
        x.stage('«Вернуться к обычному входу»');
        await panelButton(x, 'pd-kiosk-to-normal');
        await reboot(T, '«Вернуться к обычному входу»');
        await login(x, '777000906');
        x.stage('SCR-42 включение 906');
        const en2 = await enableBio(x, ['Вход по отпечатку или лицу'], 'pk-kiosk-906');
        const raw906 = await boundRaw(T);
        x.stage('«Планшет магазина»');
        await panelButton(x, 'pd-kiosk-to-kiosk');
        await reboot(T, '«Планшет магазина»');
        await x.waitHash('/kiosk', 60000, 'SCR-51 после «Планшет магазина»');
        const st3 = await pkState(T);
        const keys3 = await pkKeys(T);
        const slot3 = await ev(T, `PosDemoPage.kiosk.slotInfo('normal')`);
        const page3 = await slotPageKeys('normal');
        const r3 = await ev(T, `PosDemoPage.boot.kiosk`);
        k.toKiosk = { enable: { snack: en2.snack, consent: en2.consent, added: en2.added }, state: st3, keys: keys3, slotNormal: slot3, slotPage: page3, result: r3 };
        check(
          'T-DEMO-022 (1) passkey кассира 906 → «Планшет магазина»: блоб привязки уехал в место «обычный вход» (page), на странице его нет; запись пользователя passkey осталась на странице и в место не попала',
          en2.snack === 'ok' && !!raw906 && r3?.to === 'kiosk' && r3.ok && !st3.bound && !keys3.includes('passkeyBound') && keys3.includes('passkeyUser') && slot3?.bound === true && JSON.stringify(page3) === JSON.stringify(['passkeyBound']),
          k.toKiosk,
        );

        // ---- T-DEMO-022 (2): «Подключить этот браузер заново» → вход администратора 901: SCR-08 без чужого ключа →
        // SCR-54 «Подключить заново этот планшет» → SCR-51
        x.stage('«Подключить этот браузер заново»');
        await panelButton(x, 'pd-kiosk-reconnect');
        await reboot(T, '«Подключить этот браузер заново»');
        const r4 = await ev(T, `PosDemoPage.boot.kiosk`);
        await login(x, '777000901');
        const m4 = waMark();
        await f5(T);
        await atUnlock(T, 'SCR-08 администратора');
        await sleep(2500);
        const buttons4 = await bioButtons(T);
        const slot4 = await ev(T, `PosDemoPage.kiosk.slotInfo('normal')`);
        const st4 = await pkState(T);
        await shot(T, 'pk-kiosk-admin-scr08');
        await x.digits('715382');
        await home(x);
        await openTablets(x);
        await x.waitText('Подключить заново этот планшет', 30000, 'SCR-54: «Подключить заново этот планшет»');
        await sleep(1000);
        const codeShown2 = await reconnectThisDevice(x, 'Планшет у входа', 'pk-kiosk');
        await x.clickExact('Готово');
        const h4 = await x.waitHash('/kiosk', 60000, 'SCR-51 после подключения заново');
        k.reconnect = { result: r4, buttons: buttons4, state: st4, slotNormal: slot4, codeShown: codeShown2, hash: h4, events: waNames(T, m4) };
        check(
          'T-DEMO-022 (2) «Подключить этот браузер заново» → вход администратора 901 → SCR-08 (F5): ключ кассира не предлагается (нет кнопки биометрии, нет событий WebAuthn), блоб кассира отложен в месте «обычный вход» → SCR-54 «Подключить заново этот планшет» → SCR-51',
          r4?.to === 'reconnect' && r4.ok && buttons4.length === 0 && waCount(T, m4) === 0 && !st4.bound && slot4?.bound === true && codeShown2 && h4.startsWith('#/kiosk'),
          k.reconnect,
        );

        // ---- T-DEMO-022 (3): «Вернуться к обычному входу» → кассир 906 входит своим passkey без PIN
        x.stage('снова обычный вход');
        const m5 = waMark();
        await panelButton(x, 'pd-kiosk-to-normal');
        await reboot(T, 'снова «Вернуться к обычному входу»');
        await semanticsOn(T).catch(() => undefined);
        const home5 = await home(x, 60000);
        await sleep(2000);
        const st5 = await pkState(T);
        const raw5 = await boundRaw(T);
        const r5 = await ev(T, `PosDemoPage.boot.kiosk`);
        await shot(T, 'pk-kiosk-906-back');
        k.back = { result: r5, home: home5, state: st5, asserted: waCount(T, m5, 'credentialAsserted'), events: waNames(T, m5) };
        check(
          'T-DEMO-022 (3) «Вернуться к обычному входу»: блоб вернулся с местом «обычный вход» — кассир 906 входит своим passkey без PIN (ровно один credentialAsserted)',
          r5?.to === 'normal' && r5.ok && home5 && st5.bound && !!raw5 && waCount(T, m5, 'credentialAsserted') === 1,
          k.back,
        );

        // ---- T-DEMO-022 (4): «Выйти» (блоб удалён) → вход другим пользователем 907; оставленный блоб 906 (имитация
        // остатка) SCR-08 пользователя 907 не предлагает
        x.stage('другой пользователь');
        await logout(x);
        const st6 = await pkState(T);
        await login(x, '777000907');
        await ev(T, `(localStorage.setItem('optomstroy.demo.passkeyBound', ${JSON.stringify(raw5)}), true)`);
        const m6 = waMark();
        const n6 = noteMark();
        await f5(T);
        await atUnlock(T, 'SCR-08 пользователя 907');
        await sleep(3000);
        const buttons6 = await bioButtons(T);
        const st6b = await pkState(T);
        await shot(T, 'pk-kiosk-907-scr08');
        await x.digits('715382');
        const home6 = await home(x);
        await ev(T, `(localStorage.removeItem('optomstroy.demo.passkeyBound'), true)`);
        k.other = { stateAfterLogout: st6, buttons: buttons6, stateWithLeftover: st6b, home: home6, events: waNames(T, m6), notes: notesSince(T, n6) };
        check(
          'T-DEMO-022 (4) «Выйти» удаляет блоб кассира; вход по SMS другим пользователем 907, блоб 906 оставлен на странице (имитация остатка) → SCR-08 907 не предлагает чужой ключ: нет кнопки биометрии, нет событий WebAuthn → PIN → рабочий экран',
          !st6.bound && st6b.bound && buttons6.length === 0 && waCount(T, m6) === 0 && home6,
          k.other,
        );
      } catch (e) {
        await fail('kiosk', k, T, e);
      }
    }
    PK.webauthnEvents = waLog.length;
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
    const log0 = await (await fetch(`${HTTP}/__site/log`)).json();
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
  // Edge перезапускает себя другим процессом (PID из spawn уже не браузер): сначала закрыть браузер по CDP.
  if (ws && ws.readyState === 1) await Promise.race([send('Browser.close').catch(() => undefined), sleep(3000)]);
  try {
    ws?.close();
  } catch {
    /* ignore */
  }
  killTree(chrome.pid);
  if (server) killTree(server.pid);
  await sleep(1500);
  // профиль не удалён (файлы держит процесс браузера) — отчёт всё равно пишется, итог строки ниже это сообщает
  if (!argv.includes('--keep-profile')) {
    try {
      rmSync(PROFILE, { recursive: true, force: true, maxRetries: 5, retryDelay: 400 });
    } catch (e) {
      R.profileError = String(e?.code ?? e);
    }
  }
  R.finishedAt = new Date().toISOString();
  R.summary = { checks: R.checks.length, failed: R.checks.filter((c) => !c.ok).length, tabCrashes: new Set(R.crashes.map((c) => c.tab)).size };
  writeFileSync(`${OUT}/smoke.json`, JSON.stringify(R, null, 1));
  log(`итог: ${R.summary.checks - R.summary.failed}/${R.summary.checks}; падений вкладок ${R.summary.tabCrashes}${R.summary.tabCrashes ? ' (WEB-KI-25, smoke.json crashes)' : ''}; ${OUT}/smoke.json; профиль ${existsSync(PROFILE) ? 'НЕ удалён' : 'удалён'}`);
  process.exit(R.summary.failed ? 1 : 0);
}

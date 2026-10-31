// Запрет исходящей сети из браузерного бэкенда (WP-B1, критик [12]). Выполняется первым модулем бандла (первый
// импорт inject.mjs и точки входа) и подменяет в глобальной области воркера fetch, XMLHttpRequest, WebSocket,
// EventSource, WebTransport, importScripts и navigator.sendBeacon: разрешены только адреса своего origin (тот же
// сайт: pglite.wasm, pglite.data, расширения, файлы vfs) и схемы data:/blob:. Любой другой адрес (SMSPro по
// умолчанию https://smspro.nikita.kg, загрузка фото по URL из sync/images, 1С по HTTP) отклоняется ошибкой
// ERR_DEMO_NO_NETWORK и попадает в журнал и счётчики `globalThis.__posNetGuard`.
//
// Клиент node:http/https в шиме бросает ошибку всегда (shims/node-http.cjs), node:net/tls/dns — тоже
// (shims/node-net.cjs, shims/node-netstub.cjs). Динамический import() перехватить нельзя: точка входа сама
// проверяет базовый адрес PGlite функцией assertSameOrigin().
const g = globalThis;

function selfOrigin() {
  try {
    const o = g.location && g.location.origin;
    return o && o !== 'null' ? o : null;
  } catch {
    return null;
  }
}
function baseHref() {
  try {
    return g.location ? String(g.location.href) : undefined;
  } catch {
    return undefined;
  }
}

const state = (g.__posNetGuard ??= {
  installed: false,
  origin: selfOrigin(),
  allowed: 0,
  blocked: 0,
  blockedLog: [],
});

function describe(u) {
  // В журнал — только origin и путь, без query (там могли бы оказаться параметры).
  try {
    const x = new URL(u, baseHref());
    return `${x.protocol}//${x.host}${x.pathname}`.slice(0, 200);
  } catch {
    return String(u).slice(0, 80);
  }
}

/** true — адрес разрешён (свой origin, data:, blob: своего origin). */
export function isAllowedUrl(input, { websocket = false } = {}) {
  let raw = input;
  if (raw && typeof raw === 'object') raw = typeof raw.url === 'string' ? raw.url : typeof raw.href === 'string' ? raw.href : String(raw);
  let u;
  try {
    u = new URL(String(raw), baseHref());
  } catch {
    return false;
  }
  if (u.protocol === 'data:') return !websocket;
  const origin = state.origin;
  // Без origin (Node: тестовый прогон бандла в worker_threads) разрешены только локальные файлы file:.
  if (!origin) return !websocket && u.protocol === 'file:';
  if (u.protocol === 'blob:') return u.origin === origin;
  if (websocket) {
    const own = new URL(origin);
    return (u.protocol === 'wss:' || u.protocol === 'ws:') && u.host === own.host;
  }
  return (u.protocol === 'https:' || u.protocol === 'http:') && u.origin === origin;
}

function blockedError(api, input) {
  const where = describe(input && typeof input === 'object' && 'url' in input ? input.url : input);
  state.blocked++;
  state.blockedLog.push({ api, url: where, at: new Date().toISOString() });
  if (state.blockedLog.length > 50) state.blockedLog.splice(0, 25);
  const msg = `Исходящий сетевой запрос из демо-бэкенда заблокирован (${api} ${where}): веб-демо работает без сети`;
  if (typeof g.__posDemoLog === 'function') g.__posDemoLog('warn', msg);
  const e = new TypeError(msg);
  e.code = 'ERR_DEMO_NO_NETWORK';
  return e;
}

/** Бросает ERR_DEMO_NO_NETWORK, если адрес не своего origin (для import() и прочего, что нельзя подменить). */
export function assertSameOrigin(url, api = 'import') {
  if (!isAllowedUrl(url)) throw blockedError(api, url);
  state.allowed++;
  return url;
}

function lock(name, value) {
  try {
    Object.defineProperty(g, name, { value, writable: false, configurable: false, enumerable: false });
  } catch {
    try {
      g[name] = value;
    } catch {
      /* свойство уже закреплено */
    }
  }
}

function install() {
  if (state.installed) return;
  state.installed = true;

  if (typeof g.fetch === 'function') {
    const nativeFetch = g.fetch.bind(g);
    lock('fetch', function fetch(input, init) {
      if (!isAllowedUrl(input)) return Promise.reject(blockedError('fetch', input));
      state.allowed++;
      return nativeFetch(input, init);
    });
  }

  if (typeof g.XMLHttpRequest === 'function') {
    const proto = g.XMLHttpRequest.prototype;
    const open = proto.open;
    proto.open = function (method, url, ...rest) {
      if (!isAllowedUrl(url)) throw blockedError('XMLHttpRequest', url);
      state.allowed++;
      return open.call(this, method, url, ...rest);
    };
  }

  for (const name of ['WebSocket', 'EventSource', 'WebTransport']) {
    const Native = g[name];
    if (typeof Native !== 'function') continue;
    const ws = name === 'WebSocket';
    const Guarded = class extends Native {
      constructor(url, ...rest) {
        if (!isAllowedUrl(url, { websocket: ws })) throw blockedError(name, url);
        state.allowed++;
        super(url, ...rest);
      }
    };
    Object.defineProperty(Guarded, 'name', { value: name });
    lock(name, Guarded);
  }

  if (typeof g.importScripts === 'function') {
    const nativeImport = g.importScripts.bind(g);
    lock('importScripts', function importScripts(...urls) {
      for (const u of urls) if (!isAllowedUrl(u)) throw blockedError('importScripts', u);
      state.allowed += urls.length;
      return nativeImport(...urls);
    });
  }

  const nav = g.navigator;
  if (nav && typeof nav.sendBeacon === 'function') {
    const beacon = nav.sendBeacon.bind(nav);
    try {
      Object.defineProperty(nav, 'sendBeacon', {
        value: (url, data) => {
          if (!isAllowedUrl(url)) {
            blockedError('sendBeacon', url);
            return false;
          }
          state.allowed++;
          return beacon(url, data);
        },
        configurable: false,
      });
    } catch {
      /* ignore */
    }
  }
}

install();
export const netGuard = state;

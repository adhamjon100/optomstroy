/*
 * Оптомстрой POS · веб-демо · проверка среды до загрузки (WP-S1; ADR-113 п. 9; critic «проверка среды»).
 *
 * Классический скрипт ES2017 без модулей и без `?.`/`??`: он должен выполниться и в старом или встроенном браузере,
 * чтобы показать понятную страницу «Откройте на компьютере в Chrome или Edge» вместо пустого экрана.
 *
 * PosDemoPage.env:
 *   classify(info) → {issues, kind}  — чистая функция по строке UA и признакам (проверяется тестом страницы);
 *   check()        → Promise<{issues, kind, caps}> — возможности текущего браузера (module Worker, Web Locks,
 *                    IndexedDB, BroadcastChannel, WebAssembly, память navigator.deviceMemory, телефон, WebView, Safari);
 *   pickStorage(override) → Promise<{storage, fallback, caps}> — OPFS (основное) → IndexedDB → memory://.
 */
(function (global) {
  'use strict';

  var PosDemoPage = global.PosDemoPage = global.PosDemoPage || {};

  // Строки — только русские (ADR-113 п. 9). Ключи — коды проблем для тестов и журнала.
  var TEXT = {
    in_app: 'Ссылка открыта во встроенном браузере мессенджера (Telegram, WhatsApp и подобных). В нём демо работает ненадёжно.',
    phone: 'Похоже, это телефон. Демо рассчитано на компьютер: ему нужно около 0,6–0,8 ГБ памяти и широкий экран.',
    tablet: 'Похоже, это планшет. Работа демо на планшете не проверена.',
    safari: 'Safari и браузеры на движке Safari поддерживаются «по возможности»: часть функций демо в них не проверена.',
    other_browser: 'Этот браузер поддерживается «по возможности»: демо проверено в Chrome и Edge.',
    no_module_worker: 'Браузер не поддерживает фоновые модули (module Worker): без них сервер демо не запустится.',
    no_locks: 'Браузер не поддерживает Web Locks: демо не сможет проследить, чтобы оно было открыто только в одной вкладке.',
    no_idb: 'Браузер не даёт сохранять данные (IndexedDB недоступна): демо будет работать без сохранения после перезагрузки.',
    no_broadcast: 'Браузер не поддерживает BroadcastChannel: перенос демо между вкладками работать не будет.',
    no_wasm: 'Браузер не поддерживает WebAssembly: сервер демо не запустится.',
    low_memory: 'На устройстве мало памяти ({gb} ГБ). Демо занимает около 0,6–0,8 ГБ, браузер может закрыть вкладку.',
  };

  function text(code, vars) {
    var s = TEXT[code] || code;
    if (vars) {
      Object.keys(vars).forEach(function (k) {
        s = s.split('{' + k + '}').join(String(vars[k]));
      });
    }
    return s;
  }

  // Классификация по строке UA и признакам. info: {ua, uaMobile, brands[], maxTouchPoints, telegram, deviceMemory,
  // caps: {moduleWorker, locks, idb, broadcast, wasm}}. Возвращает {kind, issues: [{code, text, hard}]}.
  function classify(info) {
    var ua = String(info.ua || '');
    var brands = (info.brands || []).map(function (b) { return String(b.brand || b).toLowerCase(); });
    var issues = [];
    var add = function (code, hard, vars) {
      issues.push({ code: code, hard: !!hard, text: text(code, vars) });
    };

    var inApp = !!info.telegram ||
      /Telegram|WhatsApp|Instagram|FBAN|FBAV|FB_IAB|FBIOS|Line\/|VKClient|MicroMessenger|OKApp|; wv\)|GSA\//i.test(ua);
    var iPadOs = /iPad/.test(ua) || (/Macintosh/.test(ua) && Number(info.maxTouchPoints || 0) > 1);
    var phone = info.uaMobile === true || /iPhone|iPod|Android.+Mobile|Windows Phone|Opera Mini|Mobile Safari/i.test(ua);
    var androidTablet = /Android/i.test(ua) && !/Mobile/i.test(ua);
    var webkitIos = /iPhone|iPad|iPod/.test(ua) || iPadOs; // на iOS все браузеры — WebKit
    var chromium = brands.indexOf('chromium') >= 0 || brands.indexOf('google chrome') >= 0 ||
      brands.indexOf('microsoft edge') >= 0 || (/Chrome\/\d+|Chromium\/\d+/.test(ua) && !/Edge\/\d+/.test(ua));
    var firefox = /Firefox\/|FxiOS\//.test(ua);
    var safari = webkitIos || (/Safari\//.test(ua) && !chromium && !firefox && !/Chrome|Chromium|CriOS|Edg|OPR/.test(ua));

    var kind = 'desktop';
    if (inApp) {
      kind = 'in_app';
      add('in_app', false);
    }
    if (phone) {
      if (kind === 'desktop') kind = 'phone';
      add('phone', false);
    } else if (iPadOs || androidTablet) {
      if (kind === 'desktop') kind = 'tablet';
      add('tablet', false);
    }
    if (safari) add('safari', false);
    else if (!chromium) add('other_browser', false);

    var caps = info.caps || {};
    if (caps.moduleWorker === false) add('no_module_worker', true);
    if (caps.wasm === false) add('no_wasm', true);
    if (caps.locks === false) add('no_locks', false);
    if (caps.broadcast === false) add('no_broadcast', false);
    if (caps.idb === false) add('no_idb', false);
    var mem = Number(info.deviceMemory);
    if (mem && mem < 4) add('low_memory', false, { gb: String(mem).replace('.', ',') });
    return { kind: kind, issues: issues };
  }

  // Поддержка module Worker: браузер читает опцию `type` только если умеет модульные воркеры.
  function detectModuleWorker() {
    if (typeof global.Worker !== 'function') return false;
    var supported = false;
    var url = null;
    try {
      url = URL.createObjectURL(new Blob([''], { type: 'text/javascript' }));
      var opts = {};
      Object.defineProperty(opts, 'type', {
        get: function () {
          supported = true;
          return 'module';
        },
      });
      var w = new global.Worker(url, opts);
      w.terminate();
    } catch (e) {
      /* нет Worker/Blob — значит, не поддерживается */
    }
    if (url) {
      try {
        URL.revokeObjectURL(url);
      } catch (e) { /* ignore */ }
    }
    return supported;
  }

  function withTimeout(promise, ms, fallback) {
    return new Promise(function (resolve) {
      var done = false;
      var timer = setTimeout(function () {
        if (!done) {
          done = true;
          resolve(fallback);
        }
      }, ms);
      promise.then(function (v) {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(v);
        }
      }, function () {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(fallback);
        }
      });
    });
  }

  // IndexedDB доступна и открывается (в части приватных режимов open() падает).
  function probeIdb() {
    if (!global.indexedDB) return Promise.resolve(false);
    return withTimeout(new Promise(function (resolve, reject) {
      var name = 'optomstroy-demo-probe';
      var req;
      try {
        req = global.indexedDB.open(name);
      } catch (e) {
        reject(e);
        return;
      }
      req.onsuccess = function () {
        try {
          req.result.close();
          global.indexedDB.deleteDatabase(name);
        } catch (e) { /* ignore */ }
        resolve(true);
      };
      req.onerror = function () { resolve(false); };
      req.onblocked = function () { resolve(true); };
    }), 3000, false);
  }

  // OPFS (navigator.storage.getDirectory). Синхронные handle (opfs-ahp) есть только в воркере — их проверяет сам
  // backend.js и при неудаче переходит на `storageFallback` из init.
  function probeOpfs() {
    if (!global.navigator.storage || typeof global.navigator.storage.getDirectory !== 'function') return Promise.resolve(false);
    return withTimeout(global.navigator.storage.getDirectory().then(function (d) { return !!d; }), 3000, false);
  }

  function gatherInfo() {
    var nav = global.navigator;
    var uad = nav.userAgentData || null;
    return {
      ua: nav.userAgent,
      uaMobile: uad ? uad.mobile === true : undefined,
      brands: uad && uad.brands ? uad.brands : [],
      maxTouchPoints: nav.maxTouchPoints || 0,
      telegram: typeof global.TelegramWebviewProxy !== 'undefined' || typeof global.TelegramWebview !== 'undefined',
      deviceMemory: nav.deviceMemory,
    };
  }

  // Квота origin (navigator.storage.estimate) — для выбора хранилища: см. pickStorage.
  function probeQuota() {
    var st = global.navigator.storage;
    if (!st || typeof st.estimate !== 'function') return Promise.resolve(null);
    return withTimeout(st.estimate().then(function (e) { return e && typeof e.quota === 'number' ? e.quota : null; }), 2000, null);
  }

  var capsPromise = null;
  function capabilities() {
    if (!capsPromise) {
      capsPromise = Promise.all([probeIdb(), probeOpfs(), probeQuota()]).then(function (r) {
        return {
          moduleWorker: detectModuleWorker(),
          locks: !!(global.navigator.locks && typeof global.navigator.locks.request === 'function'),
          broadcast: typeof global.BroadcastChannel === 'function',
          wasm: typeof global.WebAssembly === 'object' && typeof global.WebAssembly.instantiate === 'function',
          idb: r[0],
          opfs: r[1],
          quota: r[2],
        };
      });
    }
    return capsPromise;
  }

  // Review fixes (OPFS soak, Chrome 156): пока демо открыто, Chrome учитывает за origin ~1,4 ГБ квоты — резерв
  // ~2000 открытых sync access handle пула PGlite opfs-ahp (на диске при этом ~0,1–0,15 ГБ). Если квота origin меньше
  // OPFS_MIN_QUOTA, запись в OPFS упрётся в QuotaExceededError — тогда основным берётся IndexedDB.
  var OPFS_MIN_QUOTA = 3 * 1024 * 1024 * 1024;

  function check() {
    return capabilities().then(function (caps) {
      var info = gatherInfo();
      info.caps = caps;
      var r = classify(info);
      r.caps = caps;
      r.info = info;
      return r;
    });
  }

  // Выбор хранилища PGlite: OPFS (opfs-ahp, основное по замеру WP-B0) → IndexedDB → memory://.
  // override — значение `?storage=` (opfs | idb | memory) для разработчика и тестов.
  // remembered (review fixes) — хранилище, на котором в этой эпохе уже был успешный запуск ({epochKey, storage}):
  // данные лежат ТАМ, поэтому выбор не повторяется заново (медленная проверка OPFS или сбой его открытия раньше молча
  // открывали пустой том IndexedDB — «заказы пропали»). Запасной вариант тогда только memory (без сохранения).
  function pickStorage(override, remembered) {
    return capabilities().then(function (caps) {
      var order = [];
      var lowQuota = typeof caps.quota === 'number' && caps.quota < OPFS_MIN_QUOTA;
      if (caps.opfs && !lowQuota) order.push('opfs');
      if (caps.idb) order.push('idb');
      if (caps.opfs && lowQuota) order.push('opfs');
      order.push('memory');
      if (override && /^(opfs|idb|memory)$/.test(override)) {
        order = [override].concat(order.filter(function (s) { return s !== override; }));
        return { storage: order[0], fallback: order.slice(1), caps: caps, source: 'override' };
      }
      if (remembered && /^(opfs|idb)$/.test(remembered)) {
        return { storage: remembered, fallback: ['memory'], caps: caps, source: 'remembered' };
      }
      return { storage: order[0], fallback: order.slice(1), caps: caps, source: 'probe' };
    });
  }

  // localStorage/sessionStorage с перехватом исключений (приватный режим, запрет cookies). Ключи страницы —
  // с префиксом `optomstroy.demo.`; Flutter и его плагины используют свои ключи (`flutter.*` и др.).
  function makeStore(kind) {
    var area = null;
    try {
      area = global[kind];
      var probe = 'optomstroy.demo.__probe';
      area.setItem(probe, '1');
      area.removeItem(probe);
    } catch (e) {
      area = null;
    }
    return {
      available: !!area,
      get: function (key) {
        try {
          return area ? area.getItem(key) : null;
        } catch (e) {
          return null;
        }
      },
      set: function (key, value) {
        try {
          if (area) area.setItem(key, String(value));
          return !!area;
        } catch (e) {
          return false;
        }
      },
      remove: function (key) {
        try {
          if (area) area.removeItem(key);
        } catch (e) { /* ignore */ }
      },
      clear: function () {
        try {
          if (area) area.clear();
        } catch (e) { /* ignore */ }
      },
    };
  }

  PosDemoPage.store = makeStore('localStorage');
  PosDemoPage.session = makeStore('sessionStorage');
  PosDemoPage.KEYS = {
    buildId: 'optomstroy.demo.buildId',
    epochKey: 'optomstroy.demo.epochKey',
    generation: 'optomstroy.demo.generation',
    resetPending: 'optomstroy.demo.resetPending',
    envAck: 'optomstroy.demo.envAck',
    persist: 'optomstroy.demo.persist',
    hintShown: 'optomstroy.demo.hintShown',
    knownDbs: 'optomstroy.demo.knownDbs',
    // review fixes: {epochKey, storage, readyCount, lastReadyAt} — где лежат данные этой эпохи (pickStorage, demo-boot).
    storageKind: 'optomstroy.demo.storageKind',
  };

  PosDemoPage.env = {
    TEXT: TEXT,
    classify: classify,
    check: check,
    capabilities: capabilities,
    pickStorage: pickStorage,
    gatherInfo: gatherInfo,
  };
})(window);

/*
 * Оптомстрой POS · веб-демо · одна вкладка и fencing (WP-S1; ADR-113 п. 9; critic «Продолжить здесь» без fencing).
 *
 * Замок Web Locks `optomstroy-demo` держит вкладка, в которой работает демо (воркер backend.js и Flutter).
 *   acquire({takeover, onBusy, onStatus})
 *     1. `ifAvailable` — замок свободен → работаем.
 *     2. Занят → onBusy() показывает плашку «Демо уже открыто в другой вкладке» с кнопкой «Продолжить здесь».
 *        Параллельно стоит обычный запрос замка: если та вкладка закрылась, эта продолжает сама.
 *     3. «Продолжить здесь» (или `?takeover=1`): по BroadcastChannel `optomstroy-demo` уходит `release`; держатель
 *        выходит из демо (flush своего поколения → shutdown воркера → освобождает замок → `released` →
 *        location.replace на demo-closed.html) — обычный запрос замка удовлетворяется. Если за 3 с ответа нет
 *        (вкладка заморожена или зависла) — `steal`.
 *   После получения замка — bumpGeneration(): новое поколение тома PGlite. Оно пишется в localStorage
 *   (`optomstroy.demo.generation`) и в IndexedDB — как имя пустой базы `optomstroy-demo-fence-g<поколение>-t<вкладка>`
 *   (review fixes; читается через indexedDB.databases() без транзакций — замороженная вкладка её не блокирует) и, для
 *   совместимости, в `optomstroy-demo-fence` (хранилище `fence`, ключ `generation`, {generation, tabId, at});
 *   передаётся воркеру в `init` и в каждом `flush`. Вкладка с устаревшим поколением не шлёт flush
 *   (isGenerationCurrent), а воркер сверяет поколение И вкладку с fence перед записью тома (и ещё раз под замком).
 * Потеря замка (`release` от другой вкладки, steal, смена поколения в localStorage) → onLost({reason}). Обработчик
 * страницы (demo-boot.js) останавливает мост и уходит на статическую demo-closed.html — Flutter дальше не работает.
 */
(function (global) {
  'use strict';

  var P = global.PosDemoPage = global.PosDemoPage || {};
  var NAME = 'optomstroy-demo';
  var FENCE_DB = 'optomstroy-demo-fence';
  var FENCE_STORE = 'fence';
  var RELEASE_TIMEOUT_MS = 3000;

  function randomId() {
    try {
      var a = new Uint8Array(8);
      global.crypto.getRandomValues(a);
      return Array.prototype.map.call(a, function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
    } catch (e) {
      return String(Date.now()) + String(Math.random()).slice(2, 8);
    }
  }

  var tabId = randomId();
  var hasLocks = !!(global.navigator.locks && typeof global.navigator.locks.request === 'function');
  var channel = null;
  try {
    channel = typeof global.BroadcastChannel === 'function' ? new global.BroadcastChannel(NAME) : null;
  } catch (e) {
    channel = null;
  }

  var state = {
    holder: false,
    held: null, // {release: fn} — снимает замок (резолвит промис колбэка locks.request)
    releasing: false, // мы сами отпускаем замок — отказ промиса не считать потерей
    generation: 0,
    lostFired: false,
    lostHandler: null,
    mode: null, // acquired | nolocks
  };
  var log = [];
  function note(event, data) {
    log.push({ t: Math.round(global.performance ? global.performance.now() : Date.now()), event: event, data: data || null });
    if (log.length > 200) log.splice(0, 100);
  }

  function sleep(ms) {
    return new Promise(function (r) { setTimeout(r, ms); });
  }

  function post(msg) {
    if (!channel) return;
    try {
      msg.from = tabId;
      msg.at = Date.now();
      channel.postMessage(msg);
    } catch (e) { /* ignore */ }
  }

  // Запрос замка. Резолвится true, когда замок получен (держится до state.held.release()), false — если
  // `ifAvailable` и замок занят. Отказ промиса locks.request ПОСЛЕ получения — замок отобрали (steal).
  function requestLock(options) {
    return new Promise(function (resolve, reject) {
      var granted = false;
      var p;
      try {
        p = global.navigator.locks.request(NAME, options, function (lock) {
          if (!lock) {
            resolve(false);
            return undefined;
          }
          granted = true;
          return new Promise(function (release) {
            state.held = { release: release };
            state.holder = true;
            note('granted', { steal: !!options.steal });
            resolve(true);
          });
        });
      } catch (e) {
        reject(e);
        return;
      }
      p.then(function () {
        if (granted) note('released');
      }, function (err) {
        if (!granted) {
          reject(err);
          return;
        }
        if (!state.releasing && state.holder) {
          state.holder = false;
          state.held = null;
          note('stolen', { name: err && err.name });
          lost('stolen', null);
        }
      });
    });
  }

  function lost(reason, from) {
    if (state.lostFired) return;
    state.lostFired = true;
    note('lost', { reason: reason, from: from });
    var handler = state.lostHandler;
    if (handler) {
      try {
        handler({ reason: reason, from: from });
        return;
      } catch (e) {
        if (global.console) global.console.error('Оптомстрой демо: обработчик потери замка упал', e);
      }
    }
    global.location.replace('demo-closed.html?reason=' + encodeURIComponent(reason));
  }

  if (channel) {
    channel.onmessage = function (ev) {
      var m = ev.data || {};
      if (m.from === tabId) return;
      if (m.type === 'release' && state.holder) {
        note('release-request', { from: m.from });
        lost('released', m.from);
      } else if (m.type === 'released' && m.to === tabId) {
        note('released-ack', { from: m.from });
        var w = releasedWaiters.splice(0);
        w.forEach(function (fn) { fn(m); });
      }
    };
  }
  var releasedWaiters = [];

  // Другая вкладка сменила поколение (steal после заморозки этой) — эта вкладка больше не владелец тома.
  global.addEventListener('storage', function (ev) {
    if (ev.key !== P.KEYS.generation || !state.holder || !state.generation) return;
    if (String(ev.newValue) !== String(state.generation)) {
      note('generation-changed', { newValue: ev.newValue, own: state.generation });
      lost('generation', null);
    }
  });

  // Плашка «занято»: onBusy() → Promise, который резолвится 'takeover' по кнопке «Продолжить здесь».
  function acquire(opts) {
    opts = opts || {};
    var onStatus = opts.onStatus || function () {};
    if (!hasLocks) {
      state.mode = 'nolocks';
      state.holder = true;
      note('nolocks');
      return Promise.resolve({ mode: 'nolocks' });
    }
    var started = Date.now();
    var first = opts.takeover ? Promise.resolve(false) : requestLock({ ifAvailable: true });
    return first.then(function (ok) {
      if (ok) {
        state.mode = 'acquired';
        return { mode: 'acquired' };
      }
      var ac = typeof global.AbortController === 'function' ? new global.AbortController() : null;
      var queued = requestLock(ac ? { signal: ac.signal } : {}).then(function () { return 'granted'; }, function () { return 'aborted'; });
      // Плашку «занято» показываем не сразу: при перезагрузке прежний документ отпускает замок с задержкой.
      var busyDelay = typeof opts.busyDelayMs === 'number' ? opts.busyDelayMs : 600;
      var settledQueued = false;
      queued.then(function () { settledQueued = true; });
      var busy = sleep(busyDelay).then(function () {
        if (settledQueued) return new Promise(function () {});
        note('busy');
        return opts.onBusy ? opts.onBusy() : 'takeover';
      });
      var choice = opts.takeover ? Promise.resolve('takeover') : Promise.race([queued, busy]);
      return choice.then(function (c) {
        if (c === 'granted') {
          state.mode = 'acquired';
          return { mode: 'acquired', waited: true, waitedMs: Date.now() - started };
        }
        onStatus('Переносим демо в эту вкладку…');
        note('takeover-start');
        var ack = new Promise(function (r) { releasedWaiters.push(r); });
        post({ type: 'release' });
        return Promise.race([queued, sleep(opts.releaseTimeoutMs || RELEASE_TIMEOUT_MS).then(function () { return 'timeout'; })])
          .then(function (r) {
            if (r === 'granted') return 'granted';
            if (ac) ac.abort();
            return queued; // 'granted' (успели получить до abort) или 'aborted'
          })
          .then(function (r) {
            if (r === 'granted') {
              state.mode = 'acquired';
              return Promise.race([ack, sleep(300)]).then(function () {
                return { mode: 'acquired', released: true, waitedMs: Date.now() - started };
              });
            }
            onStatus('Другая вкладка не отвечает — забираем демо…');
            note('steal');
            return requestLock({ steal: true }).then(function () {
              state.mode = 'acquired';
              return { mode: 'acquired', stolen: true, waitedMs: Date.now() - started };
            });
          });
      });
    });
  }

  // Освободить замок после выхода из демо (вызывает обработчик потери) и сообщить вкладке, которая его просила.
  function finishRelease(toTabId) {
    state.releasing = true;
    state.holder = false;
    var h = state.held;
    state.held = null;
    if (h) h.release();
    if (toTabId) post({ type: 'released', to: toTabId });
    note('finish-release', { to: toTabId });
  }

  // ---------------------------------------------------------------- поколение тома (fencing)
  function openFence(version) {
    return new Promise(function (resolve) {
      var req;
      try {
        req = version ? global.indexedDB.open(FENCE_DB, version) : global.indexedDB.open(FENCE_DB);
      } catch (e) {
        resolve(null);
        return;
      }
      req.onupgradeneeded = function () {
        var db = req.result;
        if (!db.objectStoreNames.contains(FENCE_STORE)) db.createObjectStore(FENCE_STORE);
      };
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { resolve(null); };
      req.onblocked = function () { /* ждём; таймаут ниже */ };
      setTimeout(function () { resolve(null); }, 3000);
    });
  }

  // Review fixes (smoke «замороженная вкладка», Chrome 156): запись нового поколения в хранилище fence ждала ~58 с,
  // если у замороженной вкладки воркер начал чтение fence — замороженная транзакция readonly держала хранилище, а
  // запись readwrite ждёт её. Поэтому поколение теперь — ИМЯ отдельной пустой базы
  // `optomstroy-demo-fence-g<поколение>-t<вкладка>`: создание новой базы никто не блокирует, а читатель берёт
  // наибольшее поколение из indexedDB.databases() — без транзакций. Прежние такие базы удаляются в фоне; хранилище
  // fence пишется тоже (совместимость; без ожидания).
  var FENCE_NAME_RE = /^optomstroy-demo-fence-g(\d+)-t([0-9a-z]+)$/;
  function fenceDbName(gen, tab) {
    return FENCE_DB + '-g' + gen + '-t' + tab;
  }
  function listFences() {
    var idb = global.indexedDB;
    if (!idb || typeof idb.databases !== 'function') return Promise.resolve(null);
    return idb.databases().then(function (list) {
      var out = [];
      (list || []).forEach(function (d) {
        var m = d && d.name ? FENCE_NAME_RE.exec(d.name) : null;
        if (m) out.push({ name: d.name, generation: Number(m[1]), tabId: m[2] });
      });
      out.sort(function (a, b) { return b.generation - a.generation; });
      return out;
    }, function () { return null; });
  }
  function writeFence(gen) {
    if (!global.indexedDB) return Promise.resolve(false);
    var created = new Promise(function (resolve) {
      var req;
      try {
        req = global.indexedDB.open(fenceDbName(gen, tabId), 1);
      } catch (e) {
        resolve(false);
        return;
      }
      req.onupgradeneeded = function () { /* пустая база: запись — её имя */ };
      req.onsuccess = function () {
        try {
          req.result.close();
        } catch (e) { /* ignore */ }
        resolve(true);
      };
      req.onerror = function () { resolve(false); };
      req.onblocked = function () { /* новой базы ни у кого нет */ };
      setTimeout(function () { resolve(false); }, 3000);
    });
    return created.then(function (ok) {
      // прежние поколения — в фоне (удаление может ждать соединения замороженной вкладки — не ждём)
      listFences().then(function (list) {
        (list || []).forEach(function (f) {
          if (f.generation < gen) {
            try {
              global.indexedDB.deleteDatabase(f.name);
            } catch (e) { /* ignore */ }
          }
        });
      });
      writeFenceStore(gen); // совместимость, без ожидания
      return ok;
    });
  }

  // Прежний формат: {generation, tabId, at} в IndexedDB optomstroy-demo-fence/fence['generation'] (читается, только
  // если баз-поколений нет — indexedDB.databases() недоступен).
  function writeFenceStore(gen) {
    if (!global.indexedDB) return Promise.resolve(false);
    return openFence(0).then(function (db) {
      if (!db) return null;
      if (db.objectStoreNames.contains(FENCE_STORE)) return db;
      var v = db.version + 1;
      db.close();
      return openFence(v);
    }).then(function (db) {
      if (!db) return false;
      return new Promise(function (resolve) {
        try {
          var tx = db.transaction(FENCE_STORE, 'readwrite');
          tx.objectStore(FENCE_STORE).put({ generation: gen, tabId: tabId, at: Date.now() }, 'generation');
          tx.oncomplete = function () {
            db.close();
            resolve(true);
          };
          tx.onerror = tx.onabort = function () {
            db.close();
            resolve(false);
          };
        } catch (e) {
          db.close();
          resolve(false);
        }
      });
    });
  }

  // Текущее поколение тома: наибольшее из баз-поколений; если их нет (нет indexedDB.databases()) — хранилище fence.
  function readFence() {
    if (!global.indexedDB) return Promise.resolve(null);
    return listFences().then(function (list) {
      if (list && list.length) return { generation: list[0].generation, tabId: list[0].tabId, source: 'name' };
      return readFenceStore();
    });
  }
  function readFenceStore() {
    if (!global.indexedDB) return Promise.resolve(null);
    return openFence(0).then(function (db) {
      if (!db) return null;
      if (!db.objectStoreNames.contains(FENCE_STORE)) {
        db.close();
        return null;
      }
      return new Promise(function (resolve) {
        try {
          var r = db.transaction(FENCE_STORE, 'readonly').objectStore(FENCE_STORE).get('generation');
          r.onsuccess = function () {
            db.close();
            resolve(r.result || null);
          };
          r.onerror = function () {
            db.close();
            resolve(null);
          };
        } catch (e) {
          db.close();
          resolve(null);
        }
      });
    });
  }

  // Поколение растёт всегда, в том числе через «Сбросить демо» (review fixes: раньше wipeAll очищал localStorage, и
  // первая вкладка после сброса снова получала поколение 1 — то же, что у замороженной старой вкладки; fence этого не
  // видел). Теперь max(предыдущее + 1, Date.now()), а wipeAll сохраняет ключ поколения; воркер сверяет и tabId.
  function bumpGeneration() {
    var store = P.store;
    var prev = Number(store.get(P.KEYS.generation)) || 0;
    var gen = Math.max(prev + 1, Date.now());
    store.set(P.KEYS.generation, gen);
    state.generation = gen;
    note('generation', { generation: gen });
    return writeFence(gen).then(function (ok) {
      note('fence', { ok: ok });
      return gen;
    });
  }

  // true — эта вкладка всё ещё владелец тома: можно слать flush.
  function isGenerationCurrent() {
    if (!state.generation) return false;
    if (!state.holder && state.mode !== 'nolocks') return false;
    if (!P.store.available) return true; // проверка остаётся за воркером (fence в IndexedDB)
    return String(P.store.get(P.KEYS.generation)) === String(state.generation);
  }

  P.lock = {
    NAME: NAME,
    FENCE_DB: FENCE_DB,
    FENCE_STORE: FENCE_STORE,
    tabId: tabId,
    hasLocks: hasLocks,
    acquire: acquire,
    finishRelease: finishRelease,
    bumpGeneration: bumpGeneration,
    isGenerationCurrent: isGenerationCurrent,
    readFence: readFence,
    onLost: function (fn) { state.lostHandler = fn; },
    get generation() { return state.generation; },
    get holder() { return state.holder; },
    get mode() { return state.mode; },
    log: log,
  };
})(window);

/*
 * Оптомстрой POS · веб-демо · мост страницы к серверу в module Web Worker (WP-S1; plan §3.3; ADR-113 п. 2).
 *
 * window.__posDemo — API для Flutter (DemoBridgeAdapter через dart:js_interop, WP-F1) и демо-панели:
 *   protocol            1
 *   ready               Promise<ReadyInfo> — резолвится по `ready` воркера, отклоняется по `fatal`
 *   isReady / phase     bool / 'idle'|'starting'|'ready'|'fatal'|'fenced'|'stopped'
 *   info                ReadyInfo {epoch, epochKey, buildId, storage, generation, warm, features[], timings} | null
 *   offline             bool — включено «Нет сети (имитация)»
 *   request(req)        Promise<Res>
 *       req {id?: string, method, url: '/api/v1/…?…' | '/health' (или абсолютный URL того же origin),
 *            headers?: [[k, v], …] | {k: v}, body?: Uint8Array | ArrayBuffer | string | null,
 *            onStart?: () => void — запрос начал выполняться в воркере (для таймаутов Dio, critic «таймауты»)}
 *       Res {id, status, headers: [[k, v], …] (ключи в нижнем регистре), body: Uint8Array, workerMs, queuedMs, totalMs}
 *       Ошибка — Error с полем code: 'offline' | 'cancelled' | 'fatal' | 'fenced' | 'bad_request'.
 *       Тело КОПИРУЕТСЯ перед передачей (transfer копии), буфер Dart не отсоединяется.
 *       Запросы до готовности воркера ждут в очереди (отсчёт таймаутов — от onStart).
 *   cancel(id)          отмена: снимает из очереди или шлёт `http:cancel`; промис запроса → code 'cancelled'
 *   control(action, args) Promise<data> — команды демо-панели `/__demo/*` мимо Dio (action — 'GET state',
 *                       'POST qr/<paymentId>/pay' и т. д., см. handoff WP-S1)
 *   setOffline(bool)    «Нет сети»: кроме флага моста подменяет navigator.onLine и рассылает события
 *                       offline/online на window (их слушает connectivity_plus на web); настоящие события сети
 *                       на время имитации глушатся
 *   on(type, fn)        события: ready | fatal | progress | offline | fenced | slow | log | storage; возвращает отписку
 *   storageHealth       {ok, error, failures, kind, at} | null — последнее сообщение воркера `storage` (review fixes)
 *
 * Протокол postMessage (structured clone; тело — передаваемый ArrayBuffer):
 *   страница → воркер: init {id:'init', protocol, epochKey, epoch, dbName, storage, storageFallback[], generation,
 *                       pgliteBase, snapshotUrl, origin, buildId, tabId, persisted, opts:{…то же…}}
 *                      http {id, method, url, headers: [[k, v]], body} · http:cancel {id}
 *                      control {id, action, args} · flush {id, generation, reason} · shutdown {id, generation}
 *   воркер → страница: loaded · progress {stage, pct, label?} · ready {epoch, buildId, storage, generation, warm,
 *                       features?: ['http:start'], timings?} · fatal {message, code?} · http:start {id} (необяз.) ·
 *                      http:res {id, status, headers, body, workerMs} · control:res {id, ok, data | error} ·
 *                      flush:ok {id} · shutdown:ok {id} · fenced {generation, volumeGeneration} · log {level, msg} ·
 *                      storage {ok, error?, failures?, kind} · fatal {code: 'pglite_aborted'} и после ready
 *   Для совместимости со спайком WP-B0 ответ `res {id, ok, data}` принимается как control:res.
 */
(function (global) {
  'use strict';

  var P = global.PosDemoPage = global.PosDemoPage || {};
  var PROTOCOL = 1;
  var doc = global.document;

  function now() {
    return global.performance && global.performance.now ? global.performance.now() : Date.now();
  }

  function bridgeError(code, message) {
    var e = new Error(message || code);
    e.code = code;
    e.name = 'PosDemoBridgeError';
    return e;
  }

  // ---------------------------------------------------------------- события
  var listeners = {};
  function on(type, fn) {
    (listeners[type] = listeners[type] || []).push(fn);
    return function () {
      var l = listeners[type] || [];
      var i = l.indexOf(fn);
      if (i >= 0) l.splice(i, 1);
    };
  }
  function emit(type, detail) {
    (listeners[type] || []).slice().forEach(function (fn) {
      try {
        fn(detail);
      } catch (e) {
        if (global.console) global.console.error('Оптомстрой демо: обработчик события ' + type + ' упал', e);
      }
    });
  }

  // ---------------------------------------------------------------- «Нет сети» (имитация)
  var simOffline = false;
  var dispatchingNetEvent = false;
  var onLineDesc = null;
  (function findOnLine() {
    var o = Object.getPrototypeOf(global.navigator);
    while (o && !onLineDesc) {
      onLineDesc = Object.getOwnPropertyDescriptor(o, 'onLine') || null;
      o = Object.getPrototypeOf(o);
    }
  })();
  function realOnLine() {
    try {
      return onLineDesc && onLineDesc.get ? !!onLineDesc.get.call(global.navigator) : true;
    } catch (e) {
      return true;
    }
  }
  var onLineOverridden = false;
  try {
    Object.defineProperty(global.navigator, 'onLine', {
      configurable: true,
      enumerable: true,
      get: function () { return !simOffline && realOnLine(); },
    });
    onLineOverridden = true;
  } catch (e) {
    onLineOverridden = false;
  }
  // Слушатели в фазе захвата на window регистрируются раньше Flutter — пока включена имитация, настоящие online/offline
  // браузера до приложения не доходят.
  ['online', 'offline'].forEach(function (type) {
    global.addEventListener(type, function (ev) {
      if (dispatchingNetEvent) return;
      if (simOffline) ev.stopImmediatePropagation();
    }, true);
  });
  function fireNetEvent(type) {
    dispatchingNetEvent = true;
    try {
      global.dispatchEvent(new Event(type));
    } finally {
      dispatchingNetEvent = false;
    }
  }

  // ---------------------------------------------------------------- состояние
  var S = {
    worker: null,
    phase: 'idle',
    info: null,
    fatal: null,
    startOpts: null,
    features: {},
    pending: {}, // id → запись HTTP
    pendingCount: 0,
    queue: [], // записи до готовности воркера
    rpc: {}, // id → {resolve, reject, type}
    seq: 0,
    marks: {},
    logs: [],
    stats: { requests: 0, responses: 0, cancelled: 0, offlineRejected: 0, fencedRejected: 0, maxQueuedMs: 0, statuses: {} },
    slowTimer: null,
  };

  var readyResolve;
  var readyReject;
  var ready = new Promise(function (res, rej) {
    readyResolve = res;
    readyReject = rej;
  });
  ready.catch(function () { /* отказ обрабатывают подписчики; без этого — unhandledrejection */ });

  // ---------------------------------------------------------------- HTTP
  function toPairs(h) {
    var out = [];
    if (!h) return out;
    if (Array.isArray(h)) {
      h.forEach(function (p) {
        if (p && p.length >= 2 && p[1] !== undefined && p[1] !== null) out.push([String(p[0]), String(p[1])]);
      });
    } else if ((typeof global.Headers === 'function' && h instanceof global.Headers) || h instanceof Map) {
      h.forEach(function (v, k) { out.push([String(k), String(v)]); });
    } else {
      Object.keys(h).forEach(function (k) {
        var v = h[k];
        if (v === undefined || v === null) return;
        if (Array.isArray(v)) v.forEach(function (x) { out.push([k, String(x)]); });
        else out.push([k, String(v)]);
      });
    }
    return out;
  }

  // Копия тела в собственный ArrayBuffer (critic: transfer представления Uint8List отсоединил бы буфер Dart).
  function copyBody(body) {
    if (body === undefined || body === null) return null;
    if (typeof body === 'string') return new TextEncoder().encode(body).buffer;
    if (body instanceof ArrayBuffer) return body.slice(0);
    if (ArrayBuffer.isView(body)) return new Uint8Array(body.buffer, body.byteOffset, body.byteLength).slice().buffer;
    throw bridgeError('bad_request', 'Неподдерживаемое тело запроса');
  }

  function normalize(req) {
    if (!req || typeof req !== 'object') throw bridgeError('bad_request', 'Нет запроса');
    var u;
    try {
      u = new URL(String(req.url || ''), doc.baseURI || global.location.href);
    } catch (e) {
      throw bridgeError('bad_request', 'Неверный адрес запроса');
    }
    if (u.origin !== global.location.origin) throw bridgeError('bad_request', 'Запрос на чужой адрес не отправлен: ' + u.origin);
    var path = u.pathname;
    if (!(path === '/health' || path === '/api/v1' || path.indexOf('/api/v1/') === 0)) {
      throw bridgeError('bad_request', 'Путь вне API демо: ' + path);
    }
    var body = copyBody(req.body);
    var id = req.id !== undefined && req.id !== null && req.id !== '' ? String(req.id) : 'r' + (++S.seq);
    return {
      id: id,
      msg: { type: 'http', id: id, method: String(req.method || 'GET').toUpperCase(), url: path + u.search, headers: toPairs(req.headers), body: body },
      transfer: body ? [body] : [],
    };
  }

  function headerPairs(h) {
    return toPairs(h).map(function (p) { return [p[0].toLowerCase(), p[1]]; });
  }

  function fireStart(entry) {
    if (!entry || entry.started) return;
    entry.started = true;
    entry.tStarted = now();
    if (typeof entry.onStart === 'function') {
      try {
        entry.onStart();
      } catch (e) { /* ignore */ }
    }
  }

  function postHttp(entry) {
    entry.tPosted = now();
    var q = entry.tPosted - entry.tQueued;
    if (q > S.stats.maxQueuedMs) S.stats.maxQueuedMs = Math.round(q);
    try {
      S.worker.postMessage(entry.msg, entry.transfer);
    } catch (e) {
      settle(entry.id, null, bridgeError('fatal', 'Не удалось передать запрос серверу демо: ' + e.message));
      return;
    }
    entry.posted = true;
    if (!S.features.httpStart) fireStart(entry);
  }

  function settle(id, value, error) {
    var entry = S.pending[id];
    if (!entry) return null;
    delete S.pending[id];
    S.pendingCount--;
    var qi = S.queue.indexOf(entry);
    if (qi >= 0) S.queue.splice(qi, 1);
    if (error) entry.reject(error);
    else entry.resolve(value);
    return entry;
  }

  function rejectAllHttp(code, message, notifyWorker) {
    Object.keys(S.pending).forEach(function (id) {
      var entry = S.pending[id];
      if (notifyWorker && entry.posted && S.worker) {
        try {
          S.worker.postMessage({ type: 'http:cancel', id: id });
        } catch (e) { /* ignore */ }
      }
      settle(id, null, bridgeError(code, message));
    });
  }

  function request(req) {
    return new Promise(function (resolve, reject) {
      var r;
      try {
        r = normalize(req);
      } catch (e) {
        reject(e);
        return;
      }
      S.stats.requests++;
      if (simOffline) {
        S.stats.offlineRejected++;
        reject(bridgeError('offline', 'Нет сети (имитация в демо-панели)'));
        return;
      }
      if (S.phase === 'fatal') {
        reject(bridgeError('fatal', S.fatal ? S.fatal.message : 'Сервер демо остановлен'));
        return;
      }
      if (S.phase === 'fenced' || S.phase === 'stopped') {
        S.stats.fencedRejected++;
        reject(bridgeError('fenced', 'Демо перенесено в другую вкладку'));
        return;
      }
      if (S.pending[r.id]) {
        reject(bridgeError('bad_request', 'Повтор id запроса: ' + r.id));
        return;
      }
      var entry = { id: r.id, msg: r.msg, transfer: r.transfer, resolve: resolve, reject: reject, onStart: req.onStart, tQueued: now(), started: false, posted: false };
      S.pending[r.id] = entry;
      S.pendingCount++;
      if (S.phase === 'ready') postHttp(entry);
      else S.queue.push(entry);
    });
  }

  function cancel(id) {
    id = String(id);
    var entry = S.pending[id];
    if (!entry) return false;
    if (entry.posted && S.worker) {
      try {
        S.worker.postMessage({ type: 'http:cancel', id: id });
      } catch (e) { /* ignore */ }
    }
    S.stats.cancelled++;
    settle(id, null, bridgeError('cancelled', 'Запрос отменён'));
    return true;
  }

  function onHttpRes(m) {
    var entry = S.pending[m.id];
    if (!entry) return; // отменён
    var t = now();
    S.stats.responses++;
    S.stats.statuses[m.status] = (S.stats.statuses[m.status] || 0) + 1;
    var body = m.body instanceof ArrayBuffer ? new Uint8Array(m.body) : ArrayBuffer.isView(m.body) ? new Uint8Array(m.body.buffer, m.body.byteOffset, m.body.byteLength) : new Uint8Array(0);
    settle(m.id, {
      id: m.id,
      status: Number(m.status) || 0,
      headers: headerPairs(m.headers),
      body: body,
      workerMs: typeof m.workerMs === 'number' ? m.workerMs : null,
      queuedMs: Math.round((entry.tPosted || t) - entry.tQueued),
      totalMs: Math.round(t - entry.tQueued),
    });
  }

  // ---------------------------------------------------------------- RPC (control, flush, shutdown)
  function rpc(msg, timeoutMs, transfer) {
    return new Promise(function (resolve, reject) {
      if (!S.worker) {
        reject(bridgeError('not_started', 'Сервер демо не запущен'));
        return;
      }
      var id = 'c' + (++S.seq);
      msg.id = id;
      var timer = setTimeout(function () {
        if (!S.rpc[id]) return;
        delete S.rpc[id];
        reject(bridgeError('timeout', 'Сервер демо не ответил'));
      }, timeoutMs || 15000);
      S.rpc[id] = {
        type: msg.type,
        resolve: function (v) {
          clearTimeout(timer);
          resolve(v);
        },
        reject: function (e) {
          clearTimeout(timer);
          reject(e);
        },
      };
      try {
        S.worker.postMessage(msg, transfer || []);
      } catch (e) {
        delete S.rpc[id];
        clearTimeout(timer);
        reject(bridgeError('fatal', e.message));
      }
    });
  }

  function onRpcRes(m) {
    var id = m.id;
    var entry = id !== undefined ? S.rpc[id] : null;
    if (!entry && m.type === 'shutdown:ok') {
      // shutdown:ok без id (plan §3.3) — отвечаем всем ожидающим shutdown
      Object.keys(S.rpc).forEach(function (k) {
        if (S.rpc[k].type === 'shutdown') onRpcRes({ type: 'shutdown:ok', id: k, ok: true });
      });
      return;
    }
    if (!entry) return;
    delete S.rpc[id];
    if (m.ok === false) {
      var err = m.error;
      var code = err && typeof err === 'object' && err.code ? err.code : 'control_failed';
      var message = err && typeof err === 'object' ? err.message || JSON.stringify(err) : String(err || 'ошибка');
      entry.reject(bridgeError(code, message));
    } else {
      entry.resolve(m.data !== undefined ? m.data : null);
    }
  }

  function rejectAllRpc(code, message) {
    Object.keys(S.rpc).forEach(function (id) {
      var e = S.rpc[id];
      delete S.rpc[id];
      e.reject(bridgeError(code, message));
    });
  }

  function whenReady() {
    return ready;
  }

  function control(action, args, opts) {
    return whenReady().then(function () {
      return rpc({ type: 'control', action: String(action), args: args === undefined ? null : args }, (opts && opts.timeoutMs) || 15000);
    });
  }

  // ---------------------------------------------------------------- жизненный цикл воркера
  function failFatal(f) {
    if (S.phase === 'fatal') return;
    var wasReady = S.phase === 'ready';
    S.phase = 'fatal';
    S.fatal = { message: String(f.message || 'Сервер демо остановился'), code: f.code || 'fatal', afterReady: wasReady };
    if (S.slowTimer) clearTimeout(S.slowTimer);
    readyReject(bridgeError('fatal', S.fatal.message));
    rejectAllHttp('fatal', S.fatal.message, false);
    rejectAllRpc('fatal', S.fatal.message);
    emit('fatal', S.fatal);
  }

  function pushLog(level, msg) {
    S.logs.push({ t: Date.now(), level: level, msg: String(msg).slice(0, 2000) });
    if (S.logs.length > 200) S.logs.splice(0, 100);
    emit('log', { level: level, msg: msg });
  }

  function onMessage(ev) {
    var m = ev.data || {};
    switch (m.type) {
      case 'loaded':
        S.marks.loaded = now();
        emit('progress', { stage: 'loaded', pct: 3 });
        return;
      case 'progress':
        emit('progress', { stage: m.stage, pct: m.pct, label: m.label });
        return;
      case 'ready': {
        if (S.phase !== 'starting') return;
        S.phase = 'ready';
        S.marks.ready = now();
        if (S.slowTimer) clearTimeout(S.slowTimer);
        var features = Array.isArray(m.features) ? m.features : [];
        S.features.httpStart = features.indexOf('http:start') >= 0;
        S.info = {
          epoch: m.epoch || null,
          epochKey: S.startOpts.epochKey,
          buildId: m.buildId || S.startOpts.buildId,
          storage: m.storage || S.startOpts.storage,
          generation: m.generation !== undefined ? m.generation : S.startOpts.generation,
          warm: m.warm !== undefined ? !!m.warm : m.timings ? !!m.timings.warm : null,
          features: features,
          timings: m.timings || null,
          roles: m.roles || null,
          phones: m.phones || null,
          startMs: Math.round(S.marks.ready - S.marks.created),
        };
        readyResolve(S.info);
        var q = S.queue.splice(0);
        q.forEach(function (entry) {
          if (S.pending[entry.id]) postHttp(entry);
        });
        emit('ready', S.info);
        return;
      }
      case 'fatal':
        failFatal({ message: m.message, code: m.code });
        return;
      case 'http:start':
        fireStart(S.pending[m.id]);
        return;
      case 'http:res':
        onHttpRes(m);
        return;
      case 'control:res':
      case 'res':
      case 'flush:ok':
      case 'shutdown:ok':
        onRpcRes(m);
        return;
      case 'fenced':
        pushLog('warn', 'воркер: поколение тома устарело (' + m.generation + ' ≠ ' + m.volumeGeneration + ')');
        emit('fenced', m);
        return;
      case 'log':
        pushLog(m.level || 'error', m.msg || '');
        return;
      case 'storage':
        // review fixes: запись данных демо на диск не удаётся (квота, отказ IndexedDB) / снова удаётся.
        S.storageHealth = { ok: m.ok !== false, error: m.error || null, failures: m.failures || 0, kind: m.kind || null, at: Date.now() };
        pushLog(m.ok === false ? 'error' : 'info', m.ok === false ? 'воркер: данные демо не записываются на диск: ' + (m.error || '') : 'воркер: запись на диск восстановилась');
        emit('storage', S.storageHealth);
        return;
      default:
    }
  }

  function onWorkerError(ev) {
    var msg = (ev && ev.message) || 'ошибка загрузки backend/backend.js';
    if (S.phase === 'starting') {
      if (ev && ev.preventDefault) ev.preventDefault();
      failFatal({ message: 'Сервер демо не загрузился: ' + msg, code: 'worker_error' });
    } else {
      pushLog('error', 'воркер: ' + msg);
    }
  }

  function absUrl(rel) {
    return new URL(rel, doc.baseURI || global.location.href).href;
  }

  // opts: {epochKey, buildId, dbName, storage, storageFallback, generation, tabId, persisted, workerUrl?, extra?}
  function start(opts) {
    if (S.worker || S.phase !== 'idle') return ready;
    S.startOpts = opts;
    S.phase = 'starting';
    S.marks.created = now();
    try {
      S.worker = new global.Worker(opts.workerUrl || 'backend/backend.js', { type: 'module', name: 'optomstroy-demo-backend' });
    } catch (e) {
      failFatal({ message: 'Не удалось запустить сервер демо: ' + e.message, code: 'worker_create' });
      return ready;
    }
    S.worker.onmessage = onMessage;
    S.worker.onerror = onWorkerError;
    S.worker.onmessageerror = function () { pushLog('error', 'воркер: сообщение не разобрано'); };
    var init = {
      protocol: PROTOCOL,
      epochKey: opts.epochKey,
      epoch: opts.epochKey,
      dbName: opts.dbName,
      storage: opts.storage,
      storageFallback: opts.storageFallback || [],
      generation: opts.generation,
      pgliteBase: absUrl('backend/pglite/'),
      snapshotUrl: absUrl('demo/snapshot/'),
      origin: global.location.origin,
      buildId: opts.buildId,
      tabId: opts.tabId,
      persisted: !!opts.persisted,
    };
    if (opts.extra) Object.keys(opts.extra).forEach(function (k) { init[k] = opts.extra[k]; });
    var msg = { type: 'init', id: 'init', opts: {} };
    Object.keys(init).forEach(function (k) {
      msg[k] = init[k];
      msg.opts[k] = init[k];
    });
    S.worker.postMessage(msg);
    S.slowTimer = setTimeout(function () {
      if (S.phase === 'starting') emit('slow', { ms: 90000 });
    }, 90000);
    return ready;
  }

  // flush тома PGlite (pagehide, скрытие вкладки, выход при переносе). Только если поколение этой вкладки текущее.
  function flush(reason) {
    if (!S.worker || S.phase !== 'ready') return Promise.resolve({ skipped: 'not_ready' });
    if (P.lock && !P.lock.isGenerationCurrent()) return Promise.resolve({ skipped: 'generation' });
    return rpc({ type: 'flush', generation: S.startOpts.generation, reason: reason || 'page' }, 2500).then(function (d) {
      return d || { ok: true };
    }, function (e) {
      return { error: e.code };
    });
  }

  function terminate(phase) {
    if (S.slowTimer) clearTimeout(S.slowTimer);
    if (S.worker) {
      try {
        S.worker.terminate();
      } catch (e) { /* ignore */ }
    }
    S.worker = null;
    if (S.phase !== 'fatal') S.phase = phase || 'stopped';
    rejectAllHttp('fenced', 'Сервер демо остановлен', false);
    rejectAllRpc('fenced', 'Сервер демо остановлен');
  }

  // Обычная остановка (сброс демо): shutdown закрывает PGlite и отпускает файлы OPFS, затем terminate.
  function shutdown(opts) {
    opts = opts || {};
    if (!S.worker) return Promise.resolve({ skipped: true });
    var p = rpc({ type: 'shutdown', generation: S.startOpts ? S.startOpts.generation : null }, opts.timeoutMs || 2500)
      .then(function () { return { ok: true }; }, function (e) { return { error: e.code }; });
    return p.then(function (r) {
      terminate(opts.phase || 'stopped');
      return r;
    });
  }

  // Выход вкладки, потерявшей замок: новые запросы — 'fenced'; flush только при текущем поколении (обычная передача);
  // при steal/смене поколения — terminate без shutdown (закрытие PGlite могло бы записать устаревшую память в том).
  function fenceExit(opts) {
    opts = opts || {};
    var wasReady = S.phase === 'ready';
    if (S.phase !== 'fatal') S.phase = 'fenced';
    rejectAllHttp('fenced', 'Демо перенесено в другую вкладку', true);
    if (!S.worker) return Promise.resolve({ worker: false });
    var current = !!(P.lock && P.lock.isGenerationCurrent());
    if (opts.flush && current && wasReady) {
      return rpc({ type: 'flush', generation: S.startOpts.generation, reason: 'handover' }, 2000)
        .then(function () { return true; }, function () { return false; })
        .then(function (flushed) {
          return shutdown({ timeoutMs: 2000, phase: 'fenced' }).then(function (r) {
            return { worker: true, flushed: flushed, shutdown: r };
          });
        });
    }
    terminate('fenced');
    return Promise.resolve({ worker: true, flushed: false, terminated: true, generationCurrent: current });
  }

  function setOffline(value) {
    value = !!value;
    if (value === simOffline) return simOffline;
    simOffline = value;
    if (simOffline) {
      rejectAllHttp('offline', 'Нет сети (имитация в демо-панели)', true);
      fireNetEvent('offline');
    } else if (realOnLine()) {
      fireNetEvent('online');
    }
    emit('offline', { offline: simOffline });
    return simOffline;
  }

  var api = {
    protocol: PROTOCOL,
    ready: ready,
    request: request,
    cancel: cancel,
    control: control,
    setOffline: setOffline,
    on: on,
    get isReady() { return S.phase === 'ready'; },
    get phase() { return S.phase; },
    get info() { return S.info; },
    get offline() { return simOffline; },
    get fatal() { return S.fatal; },
    get storageHealth() { return S.storageHealth || null; },
    get onLineOverridden() { return onLineOverridden; },
    // Для страницы (demo-boot.js, demo-panel.js) и тестов, не для Flutter:
    _start: start,
    _flush: flush,
    _shutdown: shutdown,
    _fenceExit: fenceExit,
    _terminate: terminate,
    _stats: S.stats,
    _logs: S.logs,
    _marks: S.marks,
    _pendingCount: function () { return S.pendingCount; },
  };

  global.__posDemo = api;
  P.bridge = api;
})(window);

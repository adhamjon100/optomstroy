/*
 * Оптомстрой POS · веб-демо · сброс и эпоха (WP-S1; ADR-113 п. 8; critic «Сбросить демо» при открытых соединениях).
 *
 * Сброс выполняется только через перезагрузку: request() ставит флаг `optomstroy.demo.resetPending` → вкладка
 * перезагружается → при следующей загрузке (под замком, ДО запуска Flutter и воркера) wipeAll() очищает хранилище
 * origin: IndexedDB (все базы, в том числе drift приложения и fence), OPFS, Cache Storage, service worker,
 * localStorage и sessionStorage. `?reset=1` в адресе — то же самое без подтверждения (для разработчика и smoke).
 * indexedDB.deleteDatabase в состоянии `blocked` (соединение держит другая вкладка или отмирающий SharedWorker drift)
 * повторяется; файлы OPFS с открытыми sync access handle — тоже.
 *
 * Эпоха: demo/build.json `epochKey` — отпечаток снимка данных и набора миграций (critic: не buildId). Если он сменился,
 * страница предупреждает и только потом стирает данные (checkEpoch).
 *
 * Passkey сайта (15 ADR-116 п. 1; demo-passkey.js): ключ гейта и ключи входа принадлежат браузеру и переживают выход,
 * удаляет их только полная очистка. Перед очисткой localStorage (там credId) страница сообщает ОС и менеджеру паролей,
 * что passkey этого сайта больше не нужны (PublicKeyCredential.signalUnknownCredential, best effort; не дольше
 * PASSKEY_FORGET_MS), и удаляет записи passkey. Только при успешной очистке: при остатках (другая вкладка держит базу)
 * passkey и данные приложения остаются вместе — «Повторить» доделает. Так же при смене эпохи и чужих данных
 * (demo-boot.js wipe): после P.store.clear() записи passkey пропали бы, а сами ключи остались бы в ОС без хозяина.
 * В отчёт — только число сообщённых ключей (report.passkeys), без credId.
 */
(function (global) {
  'use strict';

  var P = global.PosDemoPage = global.PosDemoPage || {};
  var K = P.KEYS;
  // signalUnknownCredential не открывает диалогов и обычно отвечает сразу; дольше сброс его не ждёт.
  var PASSKEY_FORGET_MS = 2000;

  function sleep(ms) {
    return new Promise(function (r) { setTimeout(r, ms); });
  }

  // ---------------------------------------------------------------- passkey сайта (ADR-116 п. 1)
  // PosDemoPage.passkey.forgetAll() (demo-passkey.js) сразу удаляет записи passkey и сообщает ОС о каждом credId.
  // Результат: null — шлюза нет; {signalled} — сколько ключей сообщено (браузер без Signal API — 0); timeout/error —
  // ОС не ответила вовремя или вызов упал (записи всё равно удалены очисткой localStorage).
  function forgetPasskeys() {
    var pk = P.passkey;
    if (!pk || typeof pk.forgetAll !== 'function') return Promise.resolve(null);
    var run;
    try {
      run = Promise.resolve(pk.forgetAll());
    } catch (e) {
      return Promise.resolve({ signalled: 0, error: true });
    }
    return Promise.race([
      run.then(function (r) {
        return { signalled: r && typeof r.signalled === 'number' ? r.signalled : 0 };
      }, function () {
        return { signalled: 0, error: true };
      }),
      sleep(PASSKEY_FORGET_MS).then(function () { return { signalled: 0, timeout: true }; }),
    ]);
  }

  function request(reason) {
    var ok = P.store.set(K.resetPending, JSON.stringify({ at: Date.now(), reason: reason || 'panel' }));
    if (!ok) P.session.set(K.resetPending, '1');
    return ok;
  }

  function urlParams() {
    try {
      return new URL(global.location.href).searchParams;
    } catch (e) {
      return { get: function () { return null; } };
    }
  }

  function isPending() {
    return !!(P.store.get(K.resetPending) || P.session.get(K.resetPending) || urlParams().get('reset') === '1');
  }

  // ---------------------------------------------------------------- IndexedDB
  function listDatabases() {
    var idb = global.indexedDB;
    if (!idb) return Promise.resolve([]);
    var known = [];
    try {
      known = JSON.parse(P.store.get(K.knownDbs) || '[]');
    } catch (e) {
      known = [];
    }
    known.push(P.lock ? P.lock.FENCE_DB : 'optomstroy-demo-fence');
    var p = typeof idb.databases === 'function' ? idb.databases().then(function (list) {
      return list.map(function (d) { return d.name; }).filter(Boolean);
    }, function () { return []; }) : Promise.resolve([]);
    return p.then(function (names) {
      var all = names.concat(known);
      return all.filter(function (n, i) { return all.indexOf(n) === i; });
    });
  }

  // Одна попытка удаления. blocked — ждём (запрос остаётся в очереди браузера) до timeoutMs.
  function deleteOnce(name, timeoutMs) {
    return new Promise(function (resolve) {
      var settled = false;
      var blocked = false;
      var finish = function (r) {
        if (settled) return;
        settled = true;
        r.blocked = blocked;
        resolve(r);
      };
      var req;
      try {
        req = global.indexedDB.deleteDatabase(name);
      } catch (e) {
        finish({ ok: false, error: e && e.name });
        return;
      }
      req.onsuccess = function () { finish({ ok: true }); };
      req.onerror = function () { finish({ ok: false, error: req.error && req.error.name }); };
      req.onblocked = function () { blocked = true; };
      setTimeout(function () { finish({ ok: false, timeout: true }); }, timeoutMs);
    });
  }

  function deleteDatabase(name, onStatus) {
    var timeouts = [1500, 2500, 4000, 6000];
    var everBlocked = false;
    var attempt = function (i) {
      return deleteOnce(name, timeouts[i]).then(function (r) {
        if (r.blocked) everBlocked = true;
        if (r.ok) return { name: name, ok: true, attempts: i + 1, blocked: everBlocked };
        if (i + 1 >= timeouts.length) return { name: name, ok: false, attempts: i + 1, blocked: everBlocked, error: r.error || (r.timeout ? 'timeout' : 'unknown') };
        if (everBlocked) onStatus('Ждём, пока другие вкладки и процессы закроют базу данных…');
        return sleep(300).then(function () { return attempt(i + 1); });
      });
    };
    return attempt(0);
  }

  // ---------------------------------------------------------------- OPFS
  function opfsRoot() {
    var st = global.navigator.storage;
    if (!st || typeof st.getDirectory !== 'function') return Promise.resolve(null);
    return st.getDirectory().then(function (d) { return d; }, function () { return null; });
  }

  function opfsNames(dir) {
    if (!dir || typeof dir.keys !== 'function') return Promise.resolve([]);
    var it = dir.keys();
    var names = [];
    var step = function () {
      return it.next().then(function (r) {
        if (r.done) return names;
        names.push(r.value);
        return step();
      });
    };
    return step().catch(function () { return names; });
  }

  // Удаление записи OPFS с повтором: файл с открытым sync access handle (PGlite opfs-ahp, drift) удалить нельзя,
  // пока handle не закроется (NoModificationAllowedError / InvalidModificationError).
  function removeOpfsEntry(dir, name, onStatus) {
    var delays = [0, 300, 700, 1200, 2000, 3000, 4000];
    var attempt = function (i) {
      return dir.removeEntry(name, { recursive: true }).then(function () {
        return { name: name, ok: true, attempts: i + 1 };
      }, function (e) {
        var code = e && e.name;
        if (code === 'NotFoundError') return { name: name, ok: true, attempts: i + 1 };
        if (i + 1 >= delays.length) return { name: name, ok: false, attempts: i + 1, error: code || String(e) };
        onStatus('Ждём, пока закроются файлы базы данных…');
        return sleep(delays[i + 1]).then(function () { return attempt(i + 1); });
      });
    };
    return attempt(0);
  }

  // ---------------------------------------------------------------- всё хранилище origin
  // onStatus(text) — строка для экрана загрузки. Результат: {ok, idb: [...], opfs: [...], caches, serviceWorkers,
  // passkeys, ms}; passkeys — итог forgetPasskeys() (null — не вызывался: очистка неполная или шлюза нет).
  function wipeAll(opts) {
    opts = opts || {};
    var onStatus = opts.onStatus || function () {};
    var t0 = Date.now();
    var report = { ok: true, idb: [], opfs: [], caches: 0, serviceWorkers: 0, leftovers: [], passkeys: null };
    var keepEnvAck = P.store.get(K.envAck);
    // Поколение тома переживает сброс (review fixes): иначе следующая вкладка снова начала бы с 1 и совпала бы
    // с поколением замороженной старой вкладки (fencing).
    var keepGeneration = P.store.get(K.generation);

    onStatus('Удаляем данные демо…');
    var sw = global.navigator.serviceWorker && typeof global.navigator.serviceWorker.getRegistrations === 'function'
      ? global.navigator.serviceWorker.getRegistrations().then(function (regs) {
        return Promise.all(regs.map(function (r) { return r.unregister(); })).then(function () { report.serviceWorkers = regs.length; });
      }, function () {})
      : Promise.resolve();

    var cachesP = global.caches && typeof global.caches.keys === 'function'
      ? global.caches.keys().then(function (keys) {
        return Promise.all(keys.map(function (k) { return global.caches.delete(k); })).then(function () { report.caches = keys.length; });
      }, function () {})
      : Promise.resolve();

    return Promise.all([sw, cachesP]).then(function () {
      return listDatabases();
    }).then(function (names) {
      // Последовательно: параллельные deleteDatabase к одной базе drift путают очередь versionchange.
      var chain = Promise.resolve();
      names.forEach(function (name) {
        chain = chain.then(function () {
          return deleteDatabase(name, onStatus).then(function (r) { report.idb.push(r); });
        });
      });
      return chain;
    }).then(function () {
      return opfsRoot();
    }).then(function (root) {
      if (!root) return null;
      return opfsNames(root).then(function (names) {
        var chain = Promise.resolve();
        names.forEach(function (name) {
          chain = chain.then(function () {
            return removeOpfsEntry(root, name, onStatus).then(function (r) { report.opfs.push(r); });
          });
        });
        return chain.then(function () { return opfsNames(root); }).then(function (left) {
          left.forEach(function (n) { report.leftovers.push('opfs:' + n); });
        });
      });
    }).then(function () {
      return existingDatabases();
    }).then(function (left) {
      // Проверка по факту: что осталось в indexedDB.databases(); без этого API — по результатам удаления.
      if (left) {
        left.forEach(function (n) { report.leftovers.push('idb:' + n); });
      } else {
        report.idb.forEach(function (r) {
          if (!r.ok) report.leftovers.push('idb:' + r.name);
        });
      }
      report.ok = report.leftovers.length === 0 && report.opfs.every(function (r) { return r.ok; });
      if (!report.ok) return null;
      // До P.store.clear(): credId passkey лежат в localStorage (ADR-116 п. 1, «Сбросить демо» с signalUnknownCredential).
      return forgetPasskeys().then(function (r) { report.passkeys = r; });
    }).then(function () {
      if (report.ok) {
        P.store.clear();
        P.session.clear();
        if (keepEnvAck) P.store.set(K.envAck, keepEnvAck);
        if (keepGeneration) P.store.set(K.generation, keepGeneration);
      }
      report.ms = Date.now() - t0;
      return report;
    });
  }

  // Имена существующих баз по indexedDB.databases(); null — API нет (старый Firefox).
  function existingDatabases() {
    var idb = global.indexedDB;
    if (!idb || typeof idb.databases !== 'function') return Promise.resolve(null);
    return idb.databases().then(function (list) {
      return list.map(function (d) { return d.name; }).filter(function (n) { return n && n !== 'optomstroy-demo-probe'; });
    }, function () { return null; });
  }

  // Базы-поколения fence (demo-lock.js) — служебные, данных демо в них нет.
  function isServiceDb(n) {
    return /^optomstroy-demo-fence(-g\d+-t[0-9a-z]+)?$/.test(n);
  }

  // Есть ли в origin хоть какие-то данные (для первого визита с «чужими» данными без ключа эпохи).
  function hasData() {
    return existingDatabases().then(function (names) {
      if (names && names.filter(function (n) { return !isServiceDb(n); }).length) return true;
      return opfsRoot().then(function (root) {
        return root ? opfsNames(root).then(function (n) { return n.length > 0; }) : false;
      });
    });
  }

  // 'first' — ключа эпохи ещё нет; 'same'; 'changed' — сменился (нужно предупреждение и стирание).
  function checkEpoch(build) {
    var stored = P.store.get(K.epochKey);
    if (!stored) return 'first';
    return stored === build.epochKey ? 'same' : 'changed';
  }

  function rememberEpoch(build) {
    P.store.set(K.epochKey, build.epochKey);
    P.store.set(K.buildId, build.buildId);
  }

  function rememberDb(name) {
    var list = [];
    try {
      list = JSON.parse(P.store.get(K.knownDbs) || '[]');
    } catch (e) {
      list = [];
    }
    if (list.indexOf(name) < 0) {
      list.push(name);
      P.store.set(K.knownDbs, JSON.stringify(list.slice(-20)));
    }
  }

  function clearFlag() {
    P.store.remove(K.resetPending);
    P.session.remove(K.resetPending);
  }

  P.reset = {
    request: request,
    isPending: isPending,
    clearFlag: clearFlag,
    wipeAll: wipeAll,
    hasData: hasData,
    checkEpoch: checkEpoch,
    rememberEpoch: rememberEpoch,
    rememberDb: rememberDb,
    listDatabases: listDatabases,
    existingDatabases: existingDatabases,
  };
})(window);

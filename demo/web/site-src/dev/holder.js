// WP-S1 тест сброса: держит соединение IndexedDB и OPFS sync access handle (в воркере), отпускает с задержкой.
(function () {
  'use strict';
  var H = (window.__holder = { events: [], closeDelayMs: 1500, db: null, worker: null });
  var log = function (e) {
    H.events.push({ t: Date.now(), e: e });
    var el = document.getElementById('log');
    if (el) el.textContent += e + '\n';
  };
  H.openDb = function () {
    return new Promise(function (resolve) {
      var r = indexedDB.open('drift-like-db', 1);
      r.onupgradeneeded = function () { r.result.createObjectStore('files'); };
      r.onsuccess = function () {
        var db = r.result;
        H.db = db;
        db.onversionchange = function () {
          log('versionchange → закрою через ' + H.closeDelayMs + ' мс');
          setTimeout(function () {
            db.close();
            log('db closed');
          }, H.closeDelayMs);
        };
        var tx = db.transaction('files', 'readwrite');
        tx.objectStore('files').put('x', 'k');
        tx.oncomplete = function () {
          log('db open');
          resolve(true);
        };
      };
      r.onerror = function () { resolve(false); };
    });
  };
  H.lockOpfs = function () {
    return new Promise(function (resolve) {
      var src = [
        'let h = null;',
        'onmessage = async (ev) => {',
        '  if (ev.data.op === "lock") {',
        '    const root = await navigator.storage.getDirectory();',
        '    const f = await root.getFileHandle("holder-locked.bin", { create: true });',
        '    h = await f.createSyncAccessHandle();',
        '    h.write(new Uint8Array([1, 2, 3]), { at: 0 }); h.flush();',
        '    postMessage("locked");',
        '  } else if (ev.data.op === "release") {',
        '    setTimeout(() => { if (h) { h.close(); h = null; } postMessage("released"); }, ev.data.after || 0);',
        '  }',
        '};',
      ].join('\n');
      var w = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
      H.worker = w;
      w.onmessage = function (ev) {
        log('opfs ' + ev.data);
        if (ev.data === 'locked') resolve(true);
      };
      w.onerror = function (e) {
        log('opfs error ' + e.message);
        resolve(false);
      };
      w.postMessage({ op: 'lock' });
    });
  };
  H.releaseOpfsAfter = function (ms) {
    if (H.worker) H.worker.postMessage({ op: 'release', after: ms });
  };
})();

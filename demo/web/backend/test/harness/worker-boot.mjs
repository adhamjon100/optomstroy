// Сторона воркера для worker-harness.mjs (WP-B2/WP-T1): среда module Web Worker поверх node:worker_threads —
// self, postMessage(m, transfer), addEventListener/removeEventListener('message' | 'error' | 'unhandledrejection'),
// затем import собранного site/backend/backend.js (или эталона WP-T1). Протокол моста тот же, что у страницы
// (plan §3.3).
//
// Необязательные средства тестов WP-T1 (workerData; без них поведение прежнее):
//   clockOffsetMs — «прошло N дней»: Date.now()/new Date() воркера сдвинуты на N мс. PGlite (Emscripten
//                   clock_gettime → Date.now) видит тот же сдвиг, так что now() SQL и время JS совпадают.
//   netRecorder   — учёт сетевых вызовов, ДОШЕДШИХ до платформы (под запретом сети net-guard.mjs бандла): fetch,
//                   WebSocket, EventSource, а также node:net/tls/dns/http/https/http2/dgram (эталон в Node).
//                   Каждый вызов → сообщение {type:'__net', api, url} родителю.
//   сообщение {type:'__mem', id, gc} → {type:'__mem:res', id, data} (process.memoryUsage + v8 heap) — замеры soak;
//   exposeGc — gc() воркера (v8.setFlagsFromString), и __mem {gc: true} меряет кучу после полной сборки мусора.
import { parentPort, workerData } from 'node:worker_threads';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import v8 from 'node:v8';
import vm from 'node:vm';

const require = createRequire(import.meta.url);

let fullGc = null;
if (workerData.exposeGc) {
  v8.setFlagsFromString('--expose-gc');
  fullGc = vm.runInNewContext('gc');
}

if (workerData.clockOffsetMs) {
  const OFF = Number(workerData.clockOffsetMs);
  const RealDate = Date;
  class ShiftedDate extends RealDate {
    constructor(...a) {
      if (a.length === 0) super(RealDate.now() + OFF);
      else super(...a);
    }
    static now() {
      return RealDate.now() + OFF;
    }
    static [Symbol.hasInstance](x) {
      return x instanceof RealDate;
    }
  }
  globalThis.Date = ShiftedDate;
}

if (workerData.netRecorder) {
  const report = (api, url) => {
    try {
      parentPort.postMessage({ type: '__net', api, url: String(url).slice(0, 300) });
    } catch {
      /* ignore */
    }
  };
  const urlOf = (x) => (typeof x === 'string' ? x : x?.url ?? x?.href ?? String(x));
  if (typeof globalThis.fetch === 'function') {
    const realFetch = globalThis.fetch;
    globalThis.fetch = function (input, init) {
      report('fetch', urlOf(input));
      return realFetch.call(this, input, init);
    };
  }
  for (const name of ['WebSocket', 'EventSource']) {
    const Real = globalThis[name];
    if (typeof Real !== 'function') continue;
    globalThis[name] = class extends Real {
      constructor(url, ...rest) {
        report(name, urlOf(url));
        super(url, ...rest);
      }
    };
  }
  const wrap = (mod, names, api) => {
    for (const n of names) {
      const fn = mod[n];
      if (typeof fn !== 'function') continue;
      mod[n] = function (...args) {
        const a = args[0];
        report(`${api}.${n}`, typeof a === 'object' && a ? a.href ?? `${a.protocol ?? ''}//${a.host ?? a.hostname ?? ''}${a.path ?? ''}` : a);
        return fn.apply(this, args);
      };
    }
  };
  const net = require('node:net');
  const realConnect = net.Socket.prototype.connect;
  net.Socket.prototype.connect = function (...args) {
    const a = args[0];
    report('net.Socket.connect', typeof a === 'object' && a ? `${a.host ?? ''}:${a.port ?? a.path ?? ''}` : String(a));
    return realConnect.apply(this, args);
  };
  wrap(net, ['connect', 'createConnection'], 'net');
  wrap(require('node:tls'), ['connect'], 'tls');
  wrap(require('node:dns'), ['lookup', 'resolve', 'resolve4', 'resolve6'], 'dns');
  wrap(require('node:dns').promises, ['lookup', 'resolve'], 'dns.promises');
  wrap(require('node:http'), ['request', 'get'], 'http');
  wrap(require('node:https'), ['request', 'get'], 'https');
  wrap(require('node:http2'), ['connect'], 'http2');
  wrap(require('node:dgram'), ['createSocket'], 'dgram');
  syncBuiltinESMExports();
}

const listeners = new Map();
const on = (type) => listeners.get(type) ?? [];
globalThis.self = globalThis;
globalThis.postMessage = (m, transfer) => {
  // В браузере передаются ArrayBuffer; здесь — те же объекты (без повторов: transferList не терпит дублей).
  const list = Array.isArray(transfer) ? [...new Set(transfer.filter((x) => x instanceof ArrayBuffer && x.byteLength > 0))] : undefined;
  parentPort.postMessage(m, list);
};
globalThis.addEventListener = (type, fn) => {
  if (!listeners.has(type)) listeners.set(type, []);
  listeners.get(type).push(fn);
};
globalThis.removeEventListener = (type, fn) => {
  const l = listeners.get(type);
  if (l) listeners.set(type, l.filter((f) => f !== fn));
};
parentPort.on('message', (data) => {
  if (data?.type === '__mem') {
    if (data.gc && fullGc) fullGc();
    const h = v8.getHeapStatistics();
    parentPort.postMessage({ type: '__mem:res', id: data.id, data: { ...process.memoryUsage(), heapUsedV8: h.used_heap_size, heapTotalV8: h.total_heap_size, external: h.external_memory ?? null, now: Date.now() } });
    return;
  }
  for (const fn of on('message')) fn({ data });
});
process.on('unhandledRejection', (reason) => {
  const l = on('unhandledrejection');
  if (l.length) for (const fn of l) fn({ reason, preventDefault() {} });
  else parentPort.postMessage({ type: 'log', level: 'error', msg: `unhandledRejection: ${reason?.stack ?? reason}` });
});
process.on('uncaughtException', (error) => {
  const l = on('error');
  if (l.length) for (const fn of l) fn({ message: error?.message, error });
  else parentPort.postMessage({ type: 'log', level: 'error', msg: `uncaughtException: ${error?.stack ?? error}` });
});

await import(workerData.backendUrl);

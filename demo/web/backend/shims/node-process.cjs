'use strict';
// Шим `process` для module Web Worker (внедряется esbuild `inject`; глобальный `process` НЕ создаётся, иначе PGlite
// решит, что работает в Node). versions.node намеренно нет.
const EventEmitter = require('./node-events.cjs');

const proc = new EventEmitter();
proc.setMaxListeners(0);
const t0 = typeof performance !== 'undefined' ? performance.now() : Date.now();
const env = Object.create(null);
env.NODE_ENV = 'production';
proc.env = env;
proc.argv = ['browser', '/vfs/backend.js'];
proc.execArgv = [];
proc.argv0 = 'browser';
proc.execPath = '/vfs/browser';
proc.title = 'pos-api (browser)';
proc.platform = 'linux';
proc.arch = 'wasm32';
proc.version = 'v24.11.1';
proc.versions = {};
proc.release = { name: 'browser' };
proc.pid = 1;
proc.ppid = 0;
proc.exitCode = undefined;
proc.features = {};
proc.config = { variables: {} };
proc.browser = true;
proc.noDeprecation = true;
proc.throwDeprecation = false;
proc.traceDeprecation = false;
proc.cwd = () => '/vfs';
proc.chdir = () => {};
proc.umask = () => 0o22;
proc.getuid = () => 0;
proc.getgid = () => 0;
proc.geteuid = () => 0;
proc.getegid = () => 0;
proc.kill = () => true;
proc.binding = () => {
  throw new Error('process.binding is not supported');
};
proc.nextTick = (fn, ...args) => {
  queueMicrotask(() => fn(...args));
};
proc.emitWarning = (w, type, code) => {
  const msg = typeof w === 'string' ? w : w?.message;
  if (globalThis.__posDemoLog) globalThis.__posDemoLog('warn', `process.emitWarning ${type ?? ''} ${code ?? ''}: ${msg}`);
};
proc.exit = (code) => {
  const err = new Error(`process.exit(${code ?? 0}) вызван в браузерном бэкенде`);
  if (globalThis.__posDemoLog) globalThis.__posDemoLog('error', err.message + '\n' + err.stack);
  throw err;
};
proc.abort = () => proc.exit(134);
proc.uptime = () => ((typeof performance !== 'undefined' ? performance.now() : Date.now()) - t0) / 1000;
function hrtime(prev) {
  const now = typeof performance !== 'undefined' ? performance.now() : Date.now();
  let s = Math.floor(now / 1000);
  let ns = Math.floor((now % 1000) * 1e6);
  if (prev) {
    s -= prev[0];
    ns -= prev[1];
    if (ns < 0) {
      s -= 1;
      ns += 1e9;
    }
  }
  return [s, ns];
}
hrtime.bigint = () => {
  const now = typeof performance !== 'undefined' ? performance.now() : Date.now();
  return BigInt(Math.floor(now * 1e6));
};
proc.hrtime = hrtime;
function heap() {
  const m = typeof performance !== 'undefined' && performance.memory ? performance.memory : null;
  return m ? { used: m.usedJSHeapSize, total: m.totalJSHeapSize } : { used: 0, total: 0 };
}
function memoryUsage() {
  const h = heap();
  return { rss: h.total, heapTotal: h.total, heapUsed: h.used, external: 0, arrayBuffers: 0 };
}
memoryUsage.rss = () => heap().total;
proc.memoryUsage = memoryUsage;
proc.cpuUsage = () => ({ user: 0, system: 0 });
proc.resourceUsage = () => ({});
proc.report = { getReport: () => ({}) };
const write = (level) => (chunk, enc, cb) => {
  const s = typeof chunk === 'string' ? chunk : new TextDecoder().decode(chunk);
  if (globalThis.__posDemoLog) globalThis.__posDemoLog(level, s.replace(/\n$/, ''));
  if (typeof enc === 'function') enc();
  else if (typeof cb === 'function') cb();
  return true;
};
proc.stdout = { write: write('info'), isTTY: false, fd: 1, on() {}, once() {}, columns: 120 };
proc.stderr = { write: write('warn'), isTTY: false, fd: 2, on() {}, once() {}, columns: 120 };
proc.stdin = { isTTY: false, fd: 0, on() {}, once() {}, resume() {}, pause() {} };
proc.allowedNodeEnvironmentFlags = new Set();
proc.setUncaughtExceptionCaptureCallback = () => {};
proc.hasUncaughtExceptionCaptureCallback = () => false;
proc.getActiveResourcesInfo = () => [];
proc.constrainedMemory = () => 0;
proc.availableMemory = () => 0;

module.exports = proc;

// Подмена pino для браузерного бэкенда: тот же интерфейс логгера (уровни, child, bindings, isLevelEnabled),
// запись — в журнал демо (globalThis.__posDemoLog: консоль воркера + кольцевой буфер). Без потоков и транспорта.
const LEVELS = { trace: 10, debug: 20, info: 30, warn: 40, error: 50, fatal: 60, silent: Infinity };
const LABELS = Object.fromEntries(Object.entries(LEVELS).map(([k, v]) => [v, k]));

function sink(level, obj, msg) {
  const log = globalThis.__posDemoLog;
  let line = msg ?? '';
  if (obj && typeof obj === 'object') {
    const extra = {};
    for (const [k, v] of Object.entries(obj)) {
      if (v instanceof Error) extra[k] = { type: v.name, message: v.message, stack: v.stack };
      else extra[k] = v;
    }
    try {
      const s = JSON.stringify(extra);
      if (s !== '{}') line = `${line} ${s}`;
    } catch {
      /* ignore */
    }
  }
  if (log) log(level, line);
  else if (level === 'error' || level === 'fatal') console.error(line);
  else if (level === 'warn') console.warn(line);
}

class MiniLogger {
  constructor(levelName, bindings, onWrite) {
    this._level = LEVELS[levelName] ?? 30;
    this._bindings = bindings || {};
    this._onWrite = onWrite;
    this.levels = { values: { ...LEVELS }, labels: { ...LABELS } };
    for (const name of ['trace', 'debug', 'info', 'warn', 'error', 'fatal']) {
      this[name] = (a, b, ...rest) => this._write(name, a, b, rest);
    }
    this.silent = () => {};
  }
  get level() {
    return LABELS[this._level] ?? 'silent';
  }
  set level(v) {
    this._level = LEVELS[v] ?? this._level;
  }
  get levelVal() {
    return this._level;
  }
  isLevelEnabled(name) {
    return (LEVELS[name] ?? 0) >= this._level;
  }
  _write(name, a, b, rest) {
    if (LEVELS[name] < this._level) return;
    let obj = null;
    let msg;
    if (a instanceof Error) {
      obj = { err: a };
      msg = typeof b === 'string' ? b : a.message;
    } else if (a && typeof a === 'object') {
      obj = a;
      msg = typeof b === 'string' ? b : a.msg ?? a.message;
    } else {
      msg = a === undefined ? '' : String(a);
      if (b !== undefined) rest = [b, ...rest];
    }
    if (rest && rest.length && typeof msg === 'string') {
      let i = 0;
      msg = msg.replace(/%[sdjoO]/g, () => (i < rest.length ? String(typeof rest[i] === 'object' ? JSON.stringify(rest[i++]) : rest[i++]) : ''));
    }
    const full = Object.keys(this._bindings).length ? { ...this._bindings, ...(obj || {}) } : obj;
    (this._onWrite || sink)(name, full, msg);
  }
  child(bindings, opts) {
    const c = new MiniLogger(opts?.level ?? this.level, { ...this._bindings, ...(bindings || {}) }, this._onWrite);
    return c;
  }
  bindings() {
    return { ...this._bindings };
  }
  setBindings(b) {
    Object.assign(this._bindings, b);
  }
  flush(cb) {
    if (cb) cb();
  }
  on() {
    return this;
  }
  once() {
    return this;
  }
  emit() {
    return false;
  }
  removeListener() {
    return this;
  }
  get [Symbol.toStringTag]() {
    return 'Pino';
  }
}

export function pino(opts, _stream) {
  const o = typeof opts === 'object' && opts ? opts : {};
  return new MiniLogger(o.level ?? 'info', o.base ? { ...o.base } : {});
}
export const stdTimeFunctions = {
  isoTime: () => `,"time":"${new Date().toISOString()}"`,
  epochTime: () => `,"time":${Date.now()}`,
  unixTime: () => `,"time":${Math.round(Date.now() / 1000)}`,
  nullTime: () => '',
  isoTimeNano: () => `,"time":"${new Date().toISOString()}"`,
};
const errSerializer = (e) => (e instanceof Error ? { type: e.name, message: e.message, stack: e.stack } : e);
export const stdSerializers = {
  err: errSerializer,
  errWithCause: errSerializer,
  req: (r) => ({ method: r?.method, url: r?.url }),
  res: (r) => ({ statusCode: r?.statusCode }),
  wrapRequestSerializer: (f) => f,
  wrapResponseSerializer: (f) => f,
  wrapErrorSerializer: (f) => f,
};
export const levels = { values: { ...LEVELS }, labels: { ...LABELS } };
export const symbols = {};
export const version = '10.4.0-browser-demo';
export function destination() {
  return { write() {}, flushSync() {}, end() {}, on() {} };
}
export function transport() {
  return destination();
}
export function multistream() {
  return destination();
}
Object.assign(pino, { pino, stdTimeFunctions, stdSerializers, levels, symbols, version, destination, transport, multistream, default: pino });
export { MiniLogger };
export default pino;

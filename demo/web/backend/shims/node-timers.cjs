'use strict';
// Шим `timers`: объекты Timeout с unref()/ref()/hasRef()/refresh() поверх таймеров браузера (в браузере setTimeout
// возвращает число, а код Node вызывает .unref()). setImmediate — через MessageChannel (без зажима 4 мс).
const g = globalThis;
const nativeSetTimeout = g.setTimeout.bind(g);
const nativeClearTimeout = g.clearTimeout.bind(g);
const nativeSetInterval = g.setInterval.bind(g);
const nativeClearInterval = g.clearInterval.bind(g);

class Timeout {
  constructor(kind, fn, ms, args) {
    this._kind = kind;
    this._fn = fn;
    this._ms = ms;
    this._args = args;
    this._ref = true;
    this._destroyed = false;
    this._start();
  }
  _start() {
    const run = () => {
      if (this._kind === 'timeout') this._destroyed = true;
      this._fn(...this._args);
    };
    this._id = this._kind === 'interval' ? nativeSetInterval(run, this._ms) : nativeSetTimeout(run, this._ms);
  }
  unref() {
    this._ref = false;
    return this;
  }
  ref() {
    this._ref = true;
    return this;
  }
  hasRef() {
    return this._ref;
  }
  refresh() {
    if (this._destroyed) return this;
    if (this._kind === 'interval') nativeClearInterval(this._id);
    else nativeClearTimeout(this._id);
    this._start();
    return this;
  }
  close() {
    clear(this);
    return this;
  }
  [Symbol.toPrimitive]() {
    return this._id;
  }
  [Symbol.dispose || Symbol.for('dispose')]() {
    clear(this);
  }
}
function clear(t) {
  if (t == null) return;
  if (t instanceof Timeout) {
    t._destroyed = true;
    if (t._kind === 'interval') nativeClearInterval(t._id);
    else nativeClearTimeout(t._id);
    return;
  }
  if (t instanceof Immediate) {
    t._cleared = true;
    return;
  }
  nativeClearTimeout(t);
  nativeClearInterval(t);
}
function setTimeout(fn, ms, ...args) {
  if (typeof fn !== 'function') throw new TypeError('The "callback" argument must be of type function');
  return new Timeout('timeout', fn, Math.max(0, Number(ms) || 0), args);
}
function setInterval(fn, ms, ...args) {
  if (typeof fn !== 'function') throw new TypeError('The "callback" argument must be of type function');
  return new Timeout('interval', fn, Math.max(1, Number(ms) || 1), args);
}

class Immediate {
  constructor(fn, args) {
    this._fn = fn;
    this._args = args;
    this._cleared = false;
  }
  ref() {
    return this;
  }
  unref() {
    return this;
  }
  hasRef() {
    return true;
  }
}
const queue = [];
let channel = null;
let scheduled = false;
function flush() {
  scheduled = false;
  const batch = queue.splice(0);
  for (const im of batch) {
    if (im._cleared) continue;
    im._cleared = true;
    try {
      im._fn(...im._args);
    } catch (e) {
      nativeSetTimeout(() => {
        throw e;
      }, 0);
    }
  }
}
function setImmediate(fn, ...args) {
  const im = new Immediate(fn, args);
  queue.push(im);
  if (!scheduled) {
    scheduled = true;
    if (typeof MessageChannel !== 'undefined') {
      if (!channel) {
        channel = new MessageChannel();
        channel.port1.onmessage = flush;
      }
      channel.port2.postMessage(0);
    } else nativeSetTimeout(flush, 0);
  }
  return im;
}
function clearImmediate(im) {
  if (im) im._cleared = true;
}

function abortError(signal) {
  const e = new Error('The operation was aborted');
  e.name = 'AbortError';
  e.code = 'ABORT_ERR';
  e.cause = signal?.reason;
  return e;
}
const promises = {
  setTimeout(ms, value, options = {}) {
    return new Promise((resolve, reject) => {
      const signal = options.signal;
      if (signal?.aborted) return reject(abortError(signal));
      const t = setTimeout(() => {
        if (signal) signal.removeEventListener('abort', onAbort);
        resolve(value);
      }, ms);
      const onAbort = () => {
        clear(t);
        reject(abortError(signal));
      };
      if (signal) signal.addEventListener('abort', onAbort, { once: true });
    });
  },
  setImmediate(value, options = {}) {
    return new Promise((resolve, reject) => {
      const signal = options.signal;
      if (signal?.aborted) return reject(abortError(signal));
      setImmediate(() => resolve(value));
    });
  },
  async *setInterval(ms, value, options = {}) {
    const signal = options.signal;
    for (;;) {
      await promises.setTimeout(ms, undefined, { signal });
      yield value;
    }
  },
  scheduler: {
    wait: (ms, options) => promises.setTimeout(ms, undefined, options),
    yield: () => promises.setImmediate(),
  },
};

module.exports = {
  setTimeout,
  clearTimeout: clear,
  setInterval,
  clearInterval: clear,
  setImmediate,
  clearImmediate,
  Timeout,
  Immediate,
  promises,
  active() {},
  unenroll() {},
  enroll() {},
};

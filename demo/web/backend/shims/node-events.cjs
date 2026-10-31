'use strict';
// Шим `events`: npm events 3.3.0 + недостающие статические функции Node (on, errorMonitor, setMaxListeners,
// getEventListeners, addAbortListener). Не использует process (циклическая зависимость с шимом process).
const EventEmitter = require('nm:events/events.js');

if (!EventEmitter.errorMonitor) EventEmitter.errorMonitor = Symbol('events.errorMonitor');
if (!EventEmitter.captureRejectionSymbol) EventEmitter.captureRejectionSymbol = Symbol.for('nodejs.rejection');
EventEmitter.captureRejections = false;
EventEmitter.EventEmitterAsyncResource = EventEmitter;
EventEmitter.setMaxListeners = function setMaxListeners(n, ...targets) {
  for (const t of targets) {
    if (t && typeof t.setMaxListeners === 'function') t.setMaxListeners(n);
  }
};
EventEmitter.getEventListeners = function getEventListeners(emitter, name) {
  if (emitter && typeof emitter.listeners === 'function') return emitter.listeners(name);
  return [];
};
EventEmitter.getMaxListeners = function getMaxListeners(emitter) {
  return emitter && typeof emitter.getMaxListeners === 'function' ? emitter.getMaxListeners() : 10;
};
EventEmitter.addAbortListener = function addAbortListener(signal, listener) {
  if (signal.aborted) {
    queueMicrotask(() => listener());
    return { [Symbol.dispose || Symbol.for('dispose')]() {} };
  }
  signal.addEventListener('abort', listener, { once: true });
  return {
    [Symbol.dispose || Symbol.for('dispose')]() {
      signal.removeEventListener('abort', listener);
    },
  };
};
EventEmitter.on = function on(emitter, event, options = {}) {
  const queue = [];
  const waiters = [];
  let error = null;
  let done = false;
  const onEvent = (...args) => {
    const w = waiters.shift();
    if (w) w.resolve({ value: args, done: false });
    else queue.push(args);
  };
  const onError = (err) => {
    done = true;
    const w = waiters.shift();
    if (w) w.reject(err);
    else error = err;
  };
  emitter.on(event, onEvent);
  if (event !== 'error') emitter.on('error', onError);
  const cleanup = () => {
    emitter.removeListener(event, onEvent);
    emitter.removeListener('error', onError);
  };
  if (options.signal) options.signal.addEventListener('abort', () => onError(new Error('The operation was aborted')), { once: true });
  return {
    next() {
      if (queue.length) return Promise.resolve({ value: queue.shift(), done: false });
      if (error) {
        const e = error;
        error = null;
        return Promise.reject(e);
      }
      if (done) return Promise.resolve({ value: undefined, done: true });
      return new Promise((resolve, reject) => waiters.push({ resolve, reject }));
    },
    return() {
      done = true;
      cleanup();
      for (const w of waiters.splice(0)) w.resolve({ value: undefined, done: true });
      return Promise.resolve({ value: undefined, done: true });
    },
    throw(err) {
      onError(err);
      cleanup();
      return Promise.reject(err);
    },
    [Symbol.asyncIterator]() {
      return this;
    },
  };
};
// errorMonitor: эмиттер events 3.x о нём не знает — достаточно, что символ существует.
module.exports = EventEmitter;

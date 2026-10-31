'use strict';
// Шим `async_hooks`: AsyncLocalStorage без распространения контекста через await (хранилище видно только в
// синхронной части run()); AsyncResource — прямой вызов.
class AsyncLocalStorage {
  constructor() {
    this._store = undefined;
  }
  getStore() {
    return this._store;
  }
  run(store, fn, ...args) {
    const prev = this._store;
    this._store = store;
    try {
      return fn(...args);
    } finally {
      this._store = prev;
    }
  }
  exit(fn, ...args) {
    const prev = this._store;
    this._store = undefined;
    try {
      return fn(...args);
    } finally {
      this._store = prev;
    }
  }
  enterWith(store) {
    this._store = store;
  }
  disable() {
    this._store = undefined;
  }
  static bind(fn) {
    return fn;
  }
  static snapshot() {
    return (fn, ...args) => fn(...args);
  }
}
class AsyncResource {
  constructor(type) {
    this.type = type;
  }
  runInAsyncScope(fn, thisArg, ...args) {
    return fn.apply(thisArg, args);
  }
  bind(fn, thisArg) {
    const bound = thisArg === undefined ? (...a) => fn(...a) : fn.bind(thisArg);
    Object.defineProperty(bound, 'asyncResource', { value: this, configurable: true });
    return bound;
  }
  emitDestroy() {
    return this;
  }
  asyncId() {
    return 1;
  }
  triggerAsyncId() {
    return 0;
  }
  static bind(fn, _type, thisArg) {
    return new AsyncResource('bound').bind(fn, thisArg);
  }
}
module.exports = {
  AsyncLocalStorage,
  AsyncResource,
  createHook: () => ({
    enable() {
      return this;
    },
    disable() {
      return this;
    },
  }),
  executionAsyncId: () => 1,
  triggerAsyncId: () => 0,
  executionAsyncResource: () => ({}),
  asyncWrapProviders: {},
};

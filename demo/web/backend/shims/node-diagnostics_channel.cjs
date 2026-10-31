'use strict';
// Шим `diagnostics_channel`: каналы без подписчиков.
class Channel {
  constructor(name) {
    this.name = name;
    this._subs = new Set();
  }
  get hasSubscribers() {
    return this._subs.size > 0;
  }
  publish(msg) {
    for (const s of this._subs) s(msg, this.name);
  }
  subscribe(fn) {
    this._subs.add(fn);
  }
  unsubscribe(fn) {
    return this._subs.delete(fn);
  }
  bindStore() {}
  unbindStore() {}
  runStores(_d, fn, thisArg, ...args) {
    return fn.apply(thisArg, args);
  }
}
const channels = new Map();
const channel = (name) => {
  if (!channels.has(name)) channels.set(name, new Channel(name));
  return channels.get(name);
};
function tracingChannel(name) {
  const mk = (p) => channel(`tracing:${name}:${p}`);
  return {
    start: mk('start'),
    end: mk('end'),
    asyncStart: mk('asyncStart'),
    asyncEnd: mk('asyncEnd'),
    error: mk('error'),
    get hasSubscribers() {
      return false;
    },
    subscribe() {},
    unsubscribe() {},
    traceSync: (fn, _ctx, thisArg, ...args) => fn.apply(thisArg, args),
    tracePromise: (fn, _ctx, thisArg, ...args) => fn.apply(thisArg, args),
    traceCallback: (fn, _pos, _ctx, thisArg, ...args) => fn.apply(thisArg, args),
  };
}
module.exports = {
  channel,
  hasSubscribers: (n) => channel(n).hasSubscribers,
  subscribe: (n, fn) => channel(n).subscribe(fn),
  unsubscribe: (n, fn) => channel(n).unsubscribe(fn),
  tracingChannel,
  Channel,
};

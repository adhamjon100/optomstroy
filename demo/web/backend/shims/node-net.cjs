'use strict';
// Шим `net`: isIP/isIPv4/isIPv6 и упрощённый BlockList; соединения запрещены.
const EventEmitter = require('./node-events.cjs');

const V4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
function isIPv4(s) {
  return V4.test(String(s));
}
function isIPv6(s) {
  s = String(s);
  if (!s.includes(':')) return false;
  try {
    new URL(`http://[${s.replace(/%.*$/, '')}]/`);
    return true;
  } catch {
    return false;
  }
}
function isIP(s) {
  return isIPv4(s) ? 4 : isIPv6(s) ? 6 : 0;
}
class BlockList {
  constructor() {
    this.rules = [];
  }
  addAddress(a) {
    this.rules.push({ kind: 'addr', a });
  }
  addSubnet(net, prefix) {
    this.rules.push({ kind: 'subnet', net, prefix });
  }
  addRange(a, b) {
    this.rules.push({ kind: 'range', a, b });
  }
  check(addr) {
    const n = (ip) => ip.split('.').reduce((x, o) => x * 256 + Number(o), 0);
    for (const r of this.rules) {
      if (r.kind === 'addr' && r.a === addr) return true;
      if (r.kind === 'subnet' && isIPv4(addr) && isIPv4(r.net)) {
        const mask = r.prefix === 0 ? 0 : 2 ** 32 - 2 ** (32 - r.prefix);
        if ((n(addr) & mask) >>> 0 === (n(r.net) & mask) >>> 0) return true;
      }
      if (r.kind === 'range' && isIPv4(addr) && n(addr) >= n(r.a) && n(addr) <= n(r.b)) return true;
    }
    return false;
  }
}
function forbidden() {
  const e = new Error('Сетевые соединения из браузерного бэкенда запрещены');
  e.code = 'ERR_DEMO_NO_NETWORK';
  throw e;
}
class Socket extends EventEmitter {
  constructor() {
    super();
    this.remoteAddress = '127.0.0.1';
    this.readable = true;
    this.writable = true;
  }
  connect() {
    forbidden();
  }
  setTimeout() {
    return this;
  }
  setNoDelay() {
    return this;
  }
  setKeepAlive() {
    return this;
  }
  destroy() {
    return this;
  }
  end() {
    return this;
  }
  ref() {
    return this;
  }
  unref() {
    return this;
  }
}
module.exports = {
  isIP,
  isIPv4,
  isIPv6,
  BlockList,
  Socket,
  Stream: Socket,
  Server: function Server() {
    forbidden();
  },
  createServer: forbidden,
  connect: forbidden,
  createConnection: forbidden,
  SocketAddress: class SocketAddress {},
  getDefaultAutoSelectFamily: () => false,
  setDefaultAutoSelectFamily() {},
};

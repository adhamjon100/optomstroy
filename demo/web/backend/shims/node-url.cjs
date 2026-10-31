'use strict';
// Шим `url`: WHATWG URL браузера + fileURLToPath/pathToFileURL (для http(s)-URL возвращается pathname) +
// упрощённый legacy url.parse/format/resolve и конструктор Url (parseurl в express).
const path = require('./node-path.cjs');
const qs = require('./node-querystring.cjs');

function Url() {
  this.protocol = null;
  this.slashes = null;
  this.auth = null;
  this.host = null;
  this.port = null;
  this.hostname = null;
  this.hash = null;
  this.search = null;
  this.query = null;
  this.pathname = null;
  this.path = null;
  this.href = null;
}
function parse(str, parseQuery) {
  if (str instanceof Url) return str;
  const u = new Url();
  const s = String(str).trim();
  const m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?(\/\/)?/.exec(s);
  if (m && m[1] && m[2]) {
    let w;
    try {
      w = new URL(s);
    } catch {
      w = null;
    }
    if (w) {
      u.protocol = w.protocol;
      u.slashes = true;
      u.auth = w.username ? decodeURIComponent(w.username) + (w.password ? ':' + decodeURIComponent(w.password) : '') : null;
      u.host = w.host;
      u.port = w.port || null;
      u.hostname = w.hostname;
      u.hash = w.hash || null;
      u.search = w.search || null;
      u.query = w.search ? w.search.slice(1) : null;
      u.pathname = w.pathname;
      u.path = w.pathname + (w.search || '');
      u.href = w.href;
      if (parseQuery) u.query = qs.parse(u.query || '');
      return u;
    }
  }
  let rest = s;
  const hashAt = rest.indexOf('#');
  if (hashAt >= 0) {
    u.hash = rest.slice(hashAt);
    rest = rest.slice(0, hashAt);
  }
  const qAt = rest.indexOf('?');
  if (qAt >= 0) {
    u.search = rest.slice(qAt);
    u.query = rest.slice(qAt + 1);
    rest = rest.slice(0, qAt);
  }
  u.pathname = rest || (u.search ? '/' : rest);
  u.path = (u.pathname || '') + (u.search || '');
  u.href = s;
  if (parseQuery) u.query = qs.parse(u.query || '');
  return u;
}
function format(obj) {
  if (typeof obj === 'string') return obj;
  if (obj instanceof URL) return obj.href;
  let out = '';
  if (obj.protocol) out += obj.protocol.endsWith(':') ? obj.protocol : obj.protocol + ':';
  if (obj.slashes || obj.host || obj.hostname) out += '//';
  if (obj.auth) out += obj.auth + '@';
  if (obj.host) out += obj.host;
  else if (obj.hostname) out += obj.hostname + (obj.port ? ':' + obj.port : '');
  out += obj.pathname || '';
  if (obj.search) out += obj.search.startsWith('?') ? obj.search : '?' + obj.search;
  else if (obj.query && typeof obj.query === 'object') {
    const q = qs.stringify(obj.query);
    if (q) out += '?' + q;
  }
  if (obj.hash) out += obj.hash;
  return out;
}
function resolve(from, to) {
  try {
    return new URL(to, new URL(from, 'resolve://x/')).href.replace(/^resolve:\/\/x/, '');
  } catch {
    return to;
  }
}
function fileURLToPath(u) {
  const url = typeof u === 'string' ? new URL(u) : u;
  return decodeURIComponent(url.pathname);
}
function pathToFileURL(p) {
  const abs = path.resolve(String(p));
  const enc = abs
    .split('/')
    .map((s) => encodeURIComponent(s))
    .join('/');
  return new URL(`file://${enc}${String(p).endsWith('/') && !enc.endsWith('/') ? '/' : ''}`);
}
function urlToHttpOptions(url) {
  return {
    protocol: url.protocol,
    hostname: url.hostname,
    hash: url.hash,
    search: url.search,
    pathname: url.pathname,
    path: `${url.pathname || ''}${url.search || ''}`,
    href: url.href,
    port: url.port !== '' ? Number(url.port) : undefined,
  };
}
module.exports = {
  URL: globalThis.URL,
  URLSearchParams: globalThis.URLSearchParams,
  Url,
  parse,
  format,
  resolve,
  resolveObject: (a, b) => parse(resolve(a, b)),
  fileURLToPath,
  pathToFileURL,
  urlToHttpOptions,
  domainToASCII: (d) => {
    try {
      return new URL(`http://${d}`).hostname;
    } catch {
      return '';
    }
  },
  domainToUnicode: (d) => d,
};

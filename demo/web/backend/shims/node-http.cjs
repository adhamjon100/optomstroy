'use strict';
// Шим `http`/`https` для бэкенда в Web Worker: IncomingMessage (Readable) и ServerResponse без сокета — express
// строит на их прототипах req/res. Исходящие http(s)-запросы запрещены: request/get бросают ошибку.
const EventEmitter = require('./node-events.cjs');
const Stream = require('./node-stream.cjs');
const { Buffer } = require('./node-buffer.cjs');

const STATUS_CODES = {
  100: 'Continue', 101: 'Switching Protocols', 102: 'Processing', 103: 'Early Hints',
  200: 'OK', 201: 'Created', 202: 'Accepted', 203: 'Non-Authoritative Information', 204: 'No Content',
  205: 'Reset Content', 206: 'Partial Content', 207: 'Multi-Status', 208: 'Already Reported', 226: 'IM Used',
  300: 'Multiple Choices', 301: 'Moved Permanently', 302: 'Found', 303: 'See Other', 304: 'Not Modified',
  305: 'Use Proxy', 307: 'Temporary Redirect', 308: 'Permanent Redirect',
  400: 'Bad Request', 401: 'Unauthorized', 402: 'Payment Required', 403: 'Forbidden', 404: 'Not Found',
  405: 'Method Not Allowed', 406: 'Not Acceptable', 407: 'Proxy Authentication Required', 408: 'Request Timeout',
  409: 'Conflict', 410: 'Gone', 411: 'Length Required', 412: 'Precondition Failed', 413: 'Payload Too Large',
  414: 'URI Too Long', 415: 'Unsupported Media Type', 416: 'Range Not Satisfiable', 417: 'Expectation Failed',
  418: "I'm a Teapot", 421: 'Misdirected Request', 422: 'Unprocessable Entity', 423: 'Locked', 424: 'Failed Dependency',
  425: 'Too Early', 426: 'Upgrade Required', 428: 'Precondition Required', 429: 'Too Many Requests',
  431: 'Request Header Fields Too Large', 451: 'Unavailable For Legal Reasons',
  500: 'Internal Server Error', 501: 'Not Implemented', 502: 'Bad Gateway', 503: 'Service Unavailable',
  504: 'Gateway Timeout', 505: 'HTTP Version Not Supported', 506: 'Variant Also Negotiates', 507: 'Insufficient Storage',
  508: 'Loop Detected', 509: 'Bandwidth Limit Exceeded', 510: 'Not Extended', 511: 'Network Authentication Required',
};
const METHODS = ['ACL', 'BIND', 'CHECKOUT', 'CONNECT', 'COPY', 'DELETE', 'GET', 'HEAD', 'LINK', 'LOCK', 'M-SEARCH', 'MERGE', 'MKACTIVITY', 'MKCALENDAR', 'MKCOL', 'MOVE', 'NOTIFY', 'OPTIONS', 'PATCH', 'POST', 'PROPFIND', 'PROPPATCH', 'PURGE', 'PUT', 'QUERY', 'REBIND', 'REPORT', 'SEARCH', 'SOURCE', 'SUBSCRIBE', 'TRACE', 'UNBIND', 'UNLINK', 'UNLOCK', 'UNSUBSCRIBE'];

class FakeSocket extends EventEmitter {
  constructor(remoteAddress = '127.0.0.1') {
    super();
    this.remoteAddress = remoteAddress;
    this.remoteFamily = 'IPv4';
    this.remotePort = 0;
    this.localAddress = '127.0.0.1';
    this.localPort = 0;
    this.encrypted = false;
    this.readable = true;
    this.writable = true;
    this.destroyed = false;
    this.bytesRead = 0;
    this.bytesWritten = 0;
    this.timeout = 0;
  }
  setTimeout(ms, cb) {
    this.timeout = ms;
    if (cb) this.once('timeout', cb);
    return this;
  }
  setNoDelay() {
    return this;
  }
  setKeepAlive() {
    return this;
  }
  address() {
    return { address: '127.0.0.1', family: 'IPv4', port: 0 };
  }
  ref() {
    return this;
  }
  unref() {
    return this;
  }
  cork() {}
  uncork() {}
  pause() {
    return this;
  }
  resume() {
    return this;
  }
  write() {
    return true;
  }
  end() {
    this.destroy();
    return this;
  }
  destroySoon() {
    this.destroy();
  }
  destroy(err) {
    if (this.destroyed) return this;
    this.destroyed = true;
    this.readable = false;
    this.writable = false;
    queueMicrotask(() => {
      if (err) this.emit('error', err);
      this.emit('close', !!err);
    });
    return this;
  }
}

class IncomingMessage extends Stream.Readable {
  constructor(socket) {
    super();
    this.socket = socket;
    this.httpVersionMajor = 1;
    this.httpVersionMinor = 1;
    this.httpVersion = '1.1';
    this.complete = false;
    this.rawHeaders = [];
    this.headers = {};
    this.trailers = {};
    this.rawTrailers = [];
    this.joinDuplicateHeaders = false;
    this.aborted = false;
    this.upgrade = false;
    this.url = '';
    this.method = null;
    this.statusCode = null;
    this.statusMessage = null;
    this.once('end', () => {
      this.complete = true;
    });
  }
  get connection() {
    return this.socket;
  }
  set connection(v) {
    this.socket = v;
  }
  get headersDistinct() {
    const o = Object.create(null);
    for (const [k, v] of Object.entries(this.headers)) o[k] = Array.isArray(v) ? v : [v];
    return o;
  }
  get trailersDistinct() {
    return Object.create(null);
  }
  _read() {}
  setTimeout(_ms, cb) {
    if (cb) this.once('timeout', cb);
    return this;
  }
}

function headersSentError() {
  const e = new Error('Cannot set headers after they are sent to the client');
  e.code = 'ERR_HTTP_HEADERS_SENT';
  return e;
}
class OutgoingMessage extends Stream {
  constructor() {
    super();
    this._hdrs = new Map();
    this.headersSent = false;
    this.finished = false;
    this.writableEnded = false;
    this.writableFinished = false;
    this.writable = true;
    this.destroyed = false;
    this.chunkedEncoding = false;
    this.useChunkedEncodingByDefault = true;
    this.sendDate = false;
    this.shouldKeepAlive = false;
    this._chunks = [];
    this.socket = null;
    this.outputSize = 0;
  }
  get connection() {
    return this.socket;
  }
  setHeader(name, value) {
    if (this.headersSent) throw headersSentError();
    this._hdrs.set(String(name).toLowerCase(), [String(name), value]);
    return this;
  }
  setHeaders(headers) {
    const entries = headers instanceof Map || (typeof Headers !== 'undefined' && headers instanceof Headers) ? headers.entries() : Object.entries(headers);
    for (const [k, v] of entries) this.setHeader(k, v);
    return this;
  }
  appendHeader(name, value) {
    const k = String(name).toLowerCase();
    const cur = this._hdrs.get(k);
    if (!cur) return this.setHeader(name, value);
    const prev = Array.isArray(cur[1]) ? cur[1] : [cur[1]];
    this._hdrs.set(k, [cur[0], prev.concat(value)]);
    return this;
  }
  getHeader(name) {
    return this._hdrs.get(String(name).toLowerCase())?.[1];
  }
  getHeaders() {
    const o = Object.create(null);
    for (const [k, [, v]] of this._hdrs) o[k] = v;
    return o;
  }
  getHeaderNames() {
    return [...this._hdrs.keys()];
  }
  getRawHeaderNames() {
    return [...this._hdrs.values()].map(([n]) => n);
  }
  hasHeader(name) {
    return this._hdrs.has(String(name).toLowerCase());
  }
  removeHeader(name) {
    if (this.headersSent) throw headersSentError();
    this._hdrs.delete(String(name).toLowerCase());
  }
  flushHeaders() {
    if (!this.headersSent) this._implicitHeader();
  }
  _implicitHeader() {
    this.headersSent = true;
  }
  write(chunk, encoding, cb) {
    if (typeof encoding === 'function') {
      cb = encoding;
      encoding = undefined;
    }
    if (this.writableEnded) {
      const e = new Error('write after end');
      e.code = 'ERR_STREAM_WRITE_AFTER_END';
      queueMicrotask(() => (cb ? cb(e) : this.emit('error', e)));
      return false;
    }
    if (!this.headersSent) this._implicitHeader();
    if (chunk !== undefined && chunk !== null && chunk.length !== 0) {
      const buf = typeof chunk === 'string' ? Buffer.from(chunk, encoding || 'utf8') : Buffer.from(chunk.buffer ? new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength) : chunk);
      this._chunks.push(buf);
      this.outputSize += buf.length;
    }
    if (cb) queueMicrotask(() => cb());
    return true;
  }
  end(chunk, encoding, cb) {
    if (typeof chunk === 'function') {
      cb = chunk;
      chunk = undefined;
    } else if (typeof encoding === 'function') {
      cb = encoding;
      encoding = undefined;
    }
    if (this.writableEnded) {
      if (cb) queueMicrotask(cb);
      return this;
    }
    if (chunk !== undefined && chunk !== null) this.write(chunk, encoding);
    if (!this.headersSent) this._implicitHeader();
    this.writableEnded = true;
    this.finished = true;
    this.writable = false;
    queueMicrotask(() => {
      this.writableFinished = true;
      if (typeof this._onEnd === 'function') {
        try {
          this._onEnd(Buffer.concat(this._chunks));
        } catch (e) {
          if (globalThis.__posDemoLog) globalThis.__posDemoLog('error', `http shim _onEnd: ${e?.stack ?? e}`);
        }
      }
      this.emit('prefinish');
      this.emit('finish');
      if (cb) cb();
      this._emitClose();
    });
    return this;
  }
  _emitClose() {
    if (this._closed) return;
    this._closed = true;
    this.emit('close');
  }
  destroy(err) {
    if (this.destroyed) return this;
    this.destroyed = true;
    this.writable = false;
    queueMicrotask(() => {
      if (err && this.listenerCount('error') > 0) this.emit('error', err);
      this._emitClose();
    });
    return this;
  }
  cork() {}
  uncork() {}
  setTimeout(_ms, cb) {
    if (cb) this.once('timeout', cb);
    return this;
  }
  addTrailers() {}
  get writableLength() {
    return 0;
  }
  get writableHighWaterMark() {
    return 16384;
  }
  get writableCorked() {
    return 0;
  }
  get writableObjectMode() {
    return false;
  }
  get writableNeedDrain() {
    return false;
  }
}

class ServerResponse extends OutgoingMessage {
  constructor(req) {
    super();
    this.req = req;
    this.statusCode = 200;
    this.statusMessage = undefined;
    this.socket = req ? req.socket : null;
    this.strictContentLength = false;
    this._sent100 = false;
  }
  _implicitHeader() {
    this.writeHead(this.statusCode);
  }
  writeHead(statusCode, reason, obj) {
    if (this.headersSent) throw headersSentError();
    if (typeof reason !== 'string') {
      obj = reason;
      reason = undefined;
    }
    this.statusCode = statusCode | 0;
    this.statusMessage = reason || this.statusMessage || STATUS_CODES[this.statusCode] || 'unknown';
    if (obj) {
      if (Array.isArray(obj)) {
        if (obj.length && Array.isArray(obj[0])) for (const [k, v] of obj) this.appendHeader(k, v);
        else for (let i = 0; i + 1 < obj.length; i += 2) this.appendHeader(obj[i], obj[i + 1]);
      } else for (const k of Object.keys(obj)) this.setHeader(k, obj[k]);
    }
    this.headersSent = true;
    return this;
  }
  writeContinue(cb) {
    if (cb) queueMicrotask(cb);
  }
  writeProcessing(cb) {
    if (cb) queueMicrotask(cb);
  }
  writeEarlyHints(_h, cb) {
    if (cb) queueMicrotask(cb);
  }
  assignSocket(socket) {
    this.socket = socket;
    this.emit('socket', socket);
  }
  detachSocket() {
    this.socket = null;
  }
}

function forbidden() {
  const e = new Error('Исходящие HTTP-запросы из браузерного бэкенда запрещены (демо без сети)');
  e.code = 'ERR_DEMO_NO_NETWORK';
  throw e;
}
class Agent extends EventEmitter {
  constructor(opts) {
    super();
    this.options = opts || {};
    this.maxSockets = Infinity;
    this.sockets = {};
    this.requests = {};
    this.freeSockets = {};
  }
  destroy() {}
}
// Сервер без сокета: Nest (ExpressAdapter.initHttpServer) создаёт его всегда; запросы приходят через мост воркера.
class Server extends EventEmitter {
  constructor(opts, handler) {
    super();
    if (typeof opts === 'function') handler = opts;
    this._handler = handler;
    this.listening = false;
    this.timeout = 0;
    this.keepAliveTimeout = 5000;
    this.headersTimeout = 60000;
    this.requestTimeout = 300000;
    this.maxHeadersCount = null;
  }
  listen() {
    forbidden();
  }
  address() {
    return null;
  }
  close(cb) {
    this.listening = false;
    if (typeof cb === 'function') queueMicrotask(() => cb());
    queueMicrotask(() => this.emit('close'));
    return this;
  }
  closeAllConnections() {}
  closeIdleConnections() {}
  setTimeout() {
    return this;
  }
  ref() {
    return this;
  }
  unref() {
    return this;
  }
}
const validateHeaderName = (name) => {
  if (typeof name !== 'string' || !/^[\^_`a-zA-Z\-0-9!#$%&'*+.|~]+$/.test(name)) {
    const e = new TypeError(`Header name must be a valid HTTP token ["${name}"]`);
    e.code = 'ERR_INVALID_HTTP_TOKEN';
    throw e;
  }
};
const validateHeaderValue = (name, value) => {
  if (value === undefined) {
    const e = new TypeError(`Invalid value "${value}" for header "${name}"`);
    e.code = 'ERR_HTTP_INVALID_HEADER_VALUE';
    throw e;
  }
};
module.exports = {
  STATUS_CODES,
  METHODS,
  IncomingMessage,
  OutgoingMessage,
  ServerResponse,
  ClientRequest: function ClientRequest() {
    forbidden();
  },
  Agent,
  globalAgent: new Agent(),
  Server,
  createServer: (opts, handler) => new Server(opts, handler),
  request: forbidden,
  get: forbidden,
  validateHeaderName,
  validateHeaderValue,
  maxHeaderSize: 16384,
  setMaxIdleHTTPParsers() {},
  FakeSocket,
};

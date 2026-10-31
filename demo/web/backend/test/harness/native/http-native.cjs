'use strict';
// Эталон WP-T1 (native-runner.mjs): НАСТОЯЩИЙ node:http вместо шима shims/node-http.cjs. Мост (bridge-server.mjs)
// пользуется расширениями шима — FakeSocket и res._onEnd(body) — поэтому здесь они реализованы поверх настоящих
// классов Node: сокет — Duplex, в который пишет настоящий ServerResponse (сериализация HTTP/1.1, chunked), а тело
// ответа разбирается из записанных байтов. Клиент http/https (исходящие запросы), как и в шиме, всегда бросает
// ERR_DEMO_NO_NETWORK: эталон тоже не ходит в сеть.
const http = require('node:http');
const { Duplex } = require('node:stream');

class FakeSocket extends Duplex {
  constructor(remoteAddress = '127.0.0.1') {
    super({ allowHalfOpen: true });
    this.remoteAddress = remoteAddress;
    this.remotePort = 0;
    this.remoteFamily = 'IPv4';
    this.localAddress = '127.0.0.1';
    this.localPort = 0;
    this.encrypted = false;
    this.connecting = false;
    this._chunks = [];
  }
  _read() {}
  _write(chunk, enc, cb) {
    this._chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, enc));
    cb();
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
  ref() {
    return this;
  }
  unref() {
    return this;
  }
  address() {
    return { address: this.localAddress, family: 'IPv4', port: 0 };
  }
}

class IncomingMessage extends http.IncomingMessage {
  constructor(socket) {
    super(socket);
    // как у настоящего сервера Node: HTTP/1.1 (keep-alive и chunked по умолчанию)
    this.httpVersionMajor = 1;
    this.httpVersionMinor = 1;
    this.httpVersion = '1.1';
    this.complete = false;
  }
  push(chunk, encoding) {
    // Как парсер HTTP Node: сообщение «полное» перед концом тела. Иначе autoDestroy после 'end' посчитает запрос
    // оборванным (aborted) и уничтожит сокет до того, как ответ будет записан.
    if (chunk === null) this.complete = true;
    return super.push(chunk, encoding);
  }
}

/** Разбор chunked-тела: <hex>\r\n<данные>\r\n … 0\r\n\r\n. */
function dechunk(buf) {
  const out = [];
  let i = 0;
  for (;;) {
    const nl = buf.indexOf('\r\n', i, 'latin1');
    if (nl < 0) break;
    const size = parseInt(buf.toString('latin1', i, nl).split(';')[0], 16);
    if (!Number.isFinite(size) || size === 0) break;
    out.push(buf.subarray(nl + 2, nl + 2 + size));
    i = nl + 2 + size + 2;
  }
  return Buffer.concat(out);
}

class ServerResponse extends http.ServerResponse {
  constructor(req) {
    super(req);
    const socket = req.socket;
    this.assignSocket(socket);
    this.on('finish', () => {
      if (typeof this._onEnd !== 'function') return;
      const all = Buffer.concat(socket._chunks || []);
      const sep = all.indexOf('\r\n\r\n', 0, 'latin1');
      let body = sep >= 0 ? all.subarray(sep + 4) : Buffer.alloc(0);
      const head = sep >= 0 ? all.toString('latin1', 0, sep) : '';
      if (/\r\ntransfer-encoding:\s*chunked/i.test(head)) body = dechunk(body);
      try {
        this._onEnd(Buffer.from(body));
      } catch (e) {
        if (globalThis.__posDemoLog) globalThis.__posDemoLog('error', `http-native _onEnd: ${e?.stack ?? e}`);
      }
    });
  }
}

function noNetwork() {
  const e = new Error('Исходящая сеть запрещена (эталон WP-T1, как ERR_DEMO_NO_NETWORK шима)');
  e.code = 'ERR_DEMO_NO_NETWORK';
  throw e;
}

module.exports = {
  ...http,
  IncomingMessage,
  ServerResponse,
  FakeSocket,
  request: noNetwork,
  get: noNetwork,
};

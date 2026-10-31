// Встроенные модули Node → шимы браузерного бэкенда (WP-B1). Каждый встроенный модуль, который встречается в
// графе импорта, должен быть перечислен здесь явно: неизвестный встроенный модуль — ошибка сборки (а не тихая
// пустая заглушка). Шимы — CommonJS: потребители CJS делают require('events') / require('stream') и ждут сам
// конструктор, а ESM-шим отдал бы им объект пространства имён.
//
// Значение — файл в backend/shims/ или { virtual: '<код CJS>' } (тонкий модуль поверх другого шима).

/** @type {Record<string, string | { virtual: string }>} */
export const SHIM_MAP = {
  process: 'node-process.cjs',
  buffer: 'node-buffer.cjs',
  events: 'node-events.cjs',
  stream: 'node-stream.cjs',
  'stream/promises': { virtual: `module.exports = require('./node-stream.cjs').promises;` },
  'stream/web': {
    virtual: `module.exports = { ReadableStream: globalThis.ReadableStream, WritableStream: globalThis.WritableStream, TransformStream: globalThis.TransformStream, TextEncoderStream: globalThis.TextEncoderStream, TextDecoderStream: globalThis.TextDecoderStream, CompressionStream: globalThis.CompressionStream, DecompressionStream: globalThis.DecompressionStream, ByteLengthQueuingStrategy: globalThis.ByteLengthQueuingStrategy, CountQueuingStrategy: globalThis.CountQueuingStrategy };`,
  },
  string_decoder: { virtual: `module.exports = require('nm:string_decoder/lib/string_decoder.js');` },
  punycode: { virtual: `module.exports = require('nm:punycode/punycode.js');` },
  util: 'node-util.cjs',
  sys: 'node-util.cjs',
  'util/types': { virtual: `module.exports = require('./node-util.cjs').types;` },
  path: 'node-path.cjs',
  'path/posix': 'node-path.cjs',
  'path/win32': 'node-path.cjs',
  url: 'node-url.cjs',
  querystring: 'node-querystring.cjs',
  crypto: 'node-crypto.cjs',
  // http и https: серверная часть (IncomingMessage/ServerResponse для express) и клиент, который всегда бросает
  // ERR_DEMO_NO_NETWORK (SMSPro, 1С по HTTP и любые другие исходящие запросы — критик [12]).
  http: 'node-http.cjs',
  https: 'node-http.cjs',
  http2: 'node-netstub.cjs',
  net: 'node-net.cjs',
  tls: 'node-netstub.cjs',
  dns: 'node-netstub.cjs',
  'dns/promises': { virtual: `module.exports = require('./node-netstub.cjs').promises;` },
  dgram: 'node-netstub.cjs',
  fs: 'node-fs.cjs',
  'fs/promises': { virtual: `module.exports = require('./node-fs.cjs').promises;` },
  os: 'node-os.cjs',
  async_hooks: 'node-async_hooks.cjs',
  perf_hooks: 'node-perf_hooks.cjs',
  v8: 'node-perf_hooks.cjs',
  assert: 'node-assert.cjs',
  'assert/strict': 'node-assert.cjs',
  zlib: 'node-zlib.cjs',
  module: 'node-module.cjs',
  timers: 'node-timers.cjs',
  'timers/promises': { virtual: `module.exports = require('./node-timers.cjs').promises;` },
  diagnostics_channel: 'node-diagnostics_channel.cjs',
  // Модули без функций, нужных демо: свойства-функции бросают ERR_DEMO_UNSUPPORTED (не Proxy).
  repl: 'node-empty.cjs',
  worker_threads: 'node-empty.cjs',
  child_process: 'node-empty.cjs',
  tty: 'node-empty.cjs',
  readline: 'node-empty.cjs',
  cluster: 'node-empty.cjs',
  vm: 'node-empty.cjs',
  inspector: 'node-empty.cjs',
};

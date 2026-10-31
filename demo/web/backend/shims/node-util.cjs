'use strict';
// Шим `util` (и `util/types`): format, inspect, promisify, callbackify, inherits, deprecate, debuglog, types,
// isDeepStrictEqual, TextEncoder/TextDecoder, parseArgs (только для CLI — бросает).
const customInspect = Symbol.for('nodejs.util.inspect.custom');
const customPromisify = Symbol.for('nodejs.util.promisify.custom');

function inspect(value, opts) {
  const depth = typeof opts === 'object' && opts && opts.depth !== undefined ? opts.depth : 2;
  const seen = new WeakSet();
  const walk = (v, d) => {
    if (v === null) return 'null';
    if (v === undefined) return 'undefined';
    const t = typeof v;
    if (t === 'string') return d === 0 ? v : `'${v}'`;
    if (t === 'number' || t === 'boolean' || t === 'bigint') return String(v) + (t === 'bigint' ? 'n' : '');
    if (t === 'symbol') return v.toString();
    if (t === 'function') return `[Function: ${v.name || 'anonymous'}]`;
    if (typeof v[customInspect] === 'function') {
      try {
        return String(v[customInspect](depth - d, { depth }, inspect));
      } catch {
        /* ignore */
      }
    }
    if (v instanceof Error) return v.stack || `${v.name}: ${v.message}`;
    if (v instanceof Date) return isNaN(v) ? 'Invalid Date' : v.toISOString();
    if (v instanceof RegExp) return String(v);
    if (seen.has(v)) return '[Circular]';
    if (d > depth) return Array.isArray(v) ? '[Array]' : '[Object]';
    seen.add(v);
    if (Array.isArray(v)) return `[ ${v.slice(0, 100).map((x) => walk(x, d + 1)).join(', ')}${v.length > 100 ? ', ...' : ''} ]`;
    if (v instanceof Map) return `Map(${v.size}) { ${[...v].slice(0, 50).map(([k, x]) => `${walk(k, d + 1)} => ${walk(x, d + 1)}`).join(', ')} }`;
    if (v instanceof Set) return `Set(${v.size}) { ${[...v].slice(0, 50).map((x) => walk(x, d + 1)).join(', ')} }`;
    if (ArrayBuffer.isView(v)) return `${v.constructor?.name ?? 'TypedArray'}(${v.length ?? v.byteLength})`;
    const keys = Object.keys(v);
    const name = v.constructor && v.constructor !== Object ? `${v.constructor.name} ` : '';
    return `${name}{ ${keys.slice(0, 50).map((k) => `${k}: ${walk(v[k], d + 1)}`).join(', ')} }`;
  };
  return walk(value, 0);
}
inspect.custom = customInspect;
inspect.defaultOptions = { depth: 2, colors: false };
inspect.colors = {};
inspect.styles = {};

function format(f, ...args) {
  if (typeof f !== 'string') return [f, ...args].map((a) => (typeof a === 'string' ? a : inspect(a))).join(' ');
  let i = 0;
  let str = f.replace(/%[sdifjoOc%]/g, (m) => {
    if (m === '%%') return '%';
    if (i >= args.length) return m;
    const a = args[i++];
    switch (m) {
      case '%s':
        return typeof a === 'string' ? a : typeof a === 'bigint' ? `${a}n` : typeof a === 'object' && a !== null ? inspect(a, { depth: 0 }) : String(a);
      case '%d':
        return typeof a === 'bigint' ? `${a}n` : String(Number(a));
      case '%i':
        return String(parseInt(a, 10));
      case '%f':
        return String(parseFloat(a));
      case '%j':
        try {
          return JSON.stringify(a);
        } catch {
          return '[Circular]';
        }
      case '%o':
      case '%O':
        return inspect(a);
      case '%c':
        return '';
      default:
        return m;
    }
  });
  for (; i < args.length; i++) str += ' ' + (typeof args[i] === 'string' ? args[i] : inspect(args[i]));
  return str;
}
function formatWithOptions(_o, ...args) {
  return format(...args);
}
function promisify(fn) {
  if (typeof fn !== 'function') throw new TypeError('The "original" argument must be of type Function');
  if (fn[customPromisify]) return fn[customPromisify];
  function promisified(...args) {
    return new Promise((resolve, reject) => {
      fn.call(this, ...args, (err, ...values) => (err ? reject(err) : resolve(values.length > 1 ? values : values[0])));
    });
  }
  Object.setPrototypeOf(promisified, Object.getPrototypeOf(fn));
  return Object.defineProperties(promisified, Object.getOwnPropertyDescriptors(fn));
}
promisify.custom = customPromisify;
function callbackify(fn) {
  return function (...args) {
    const cb = args.pop();
    fn.apply(this, args).then((v) => cb(null, v), (e) => cb(e || new Error('Promise was rejected with falsy value')));
  };
}
function inherits(ctor, superCtor) {
  if (superCtor) {
    Object.defineProperty(ctor, 'super_', { value: superCtor, writable: true, configurable: true });
    Object.setPrototypeOf(ctor.prototype, superCtor.prototype);
  }
}
function deprecate(fn) {
  return fn;
}
function debuglog() {
  const f = () => {};
  f.enabled = false;
  return f;
}
const toStr = (v) => Object.prototype.toString.call(v);
const types = {
  isDate: (v) => v instanceof Date,
  isRegExp: (v) => v instanceof RegExp,
  isPromise: (v) => v instanceof Promise,
  isMap: (v) => v instanceof Map,
  isSet: (v) => v instanceof Set,
  isWeakMap: (v) => v instanceof WeakMap,
  isWeakSet: (v) => v instanceof WeakSet,
  isNativeError: (v) => v instanceof Error,
  isAnyArrayBuffer: (v) => v instanceof ArrayBuffer || (typeof SharedArrayBuffer !== 'undefined' && v instanceof SharedArrayBuffer),
  isArrayBuffer: (v) => v instanceof ArrayBuffer,
  isSharedArrayBuffer: (v) => typeof SharedArrayBuffer !== 'undefined' && v instanceof SharedArrayBuffer,
  isArrayBufferView: (v) => ArrayBuffer.isView(v),
  isTypedArray: (v) => ArrayBuffer.isView(v) && !(v instanceof DataView),
  isUint8Array: (v) => v instanceof Uint8Array,
  isUint8ClampedArray: (v) => v instanceof Uint8ClampedArray,
  isUint16Array: (v) => v instanceof Uint16Array,
  isUint32Array: (v) => v instanceof Uint32Array,
  isInt8Array: (v) => v instanceof Int8Array,
  isInt16Array: (v) => v instanceof Int16Array,
  isInt32Array: (v) => v instanceof Int32Array,
  isFloat32Array: (v) => v instanceof Float32Array,
  isFloat64Array: (v) => v instanceof Float64Array,
  isBigInt64Array: (v) => v instanceof BigInt64Array,
  isBigUint64Array: (v) => v instanceof BigUint64Array,
  isDataView: (v) => v instanceof DataView,
  isAsyncFunction: (v) => typeof v === 'function' && toStr(v) === '[object AsyncFunction]',
  isGeneratorFunction: (v) => typeof v === 'function' && /GeneratorFunction/.test(toStr(v)),
  isGeneratorObject: (v) => toStr(v) === '[object Generator]',
  isBoxedPrimitive: (v) => v instanceof Number || v instanceof String || v instanceof Boolean,
  isNumberObject: (v) => v instanceof Number,
  isStringObject: (v) => v instanceof String,
  isBooleanObject: (v) => v instanceof Boolean,
  isSymbolObject: () => false,
  isBigIntObject: () => false,
  isProxy: () => false,
  isExternal: () => false,
  isModuleNamespaceObject: (v) => toStr(v) === '[object Module]',
  isArgumentsObject: (v) => toStr(v) === '[object Arguments]',
  isKeyObject: () => false,
  isCryptoKey: (v) => typeof CryptoKey !== 'undefined' && v instanceof CryptoKey,
};
function isDeepStrictEqual(a, b) {
  if (Object.is(a, b)) return true;
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false;
  if (Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false;
  if (a instanceof Date) return a.getTime() === b.getTime();
  if (ArrayBuffer.isView(a)) {
    if (a.byteLength !== b.byteLength) return false;
    const x = new Uint8Array(a.buffer, a.byteOffset, a.byteLength);
    const y = new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
    for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false;
    return true;
  }
  if (a instanceof Map) {
    if (a.size !== b.size) return false;
    for (const [k, v] of a) if (!b.has(k) || !isDeepStrictEqual(v, b.get(k))) return false;
    return true;
  }
  if (a instanceof Set) {
    if (a.size !== b.size) return false;
    for (const v of a) if (!b.has(v)) return false;
    return true;
  }
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (const k of ka) if (!Object.prototype.hasOwnProperty.call(b, k) || !isDeepStrictEqual(a[k], b[k])) return false;
  return true;
}
function parseArgs() {
  throw new TypeError('util.parseArgs недоступен в браузерном бэкенде');
}
function stripVTControlCharacters(s) {
  // eslint-disable-next-line no-control-regex
  return String(s).replace(/\u001b\[[0-9;]*[A-Za-z]/g, '');
}
function aborted(signal) {
  return new Promise((resolve) => {
    if (signal.aborted) resolve();
    else signal.addEventListener('abort', () => resolve(), { once: true });
  });
}
module.exports = {
  format,
  formatWithOptions,
  inspect,
  promisify,
  callbackify,
  inherits,
  deprecate,
  debuglog,
  debug: debuglog,
  types,
  isDeepStrictEqual,
  parseArgs,
  stripVTControlCharacters,
  styleText: (_f, s) => s,
  toUSVString: (s) => String(s).toWellFormed?.() ?? String(s),
  getSystemErrorName: (n) => `E${n}`,
  getSystemErrorMap: () => new Map(),
  aborted,
  TextEncoder: globalThis.TextEncoder,
  TextDecoder: globalThis.TextDecoder,
  isArray: Array.isArray,
  isBoolean: (v) => typeof v === 'boolean',
  isNull: (v) => v === null,
  isNullOrUndefined: (v) => v == null,
  isNumber: (v) => typeof v === 'number',
  isString: (v) => typeof v === 'string',
  isSymbol: (v) => typeof v === 'symbol',
  isUndefined: (v) => v === undefined,
  isRegExp: types.isRegExp,
  isObject: (v) => v !== null && typeof v === 'object',
  isDate: types.isDate,
  isError: (v) => v instanceof Error,
  isFunction: (v) => typeof v === 'function',
  isPrimitive: (v) => v === null || (typeof v !== 'object' && typeof v !== 'function'),
  isBuffer: (v) => v != null && v.constructor != null && typeof v.constructor.isBuffer === 'function' && v.constructor.isBuffer(v),
  _extend: (o, a) => Object.assign(o, a),
  MIMEType: undefined,
};

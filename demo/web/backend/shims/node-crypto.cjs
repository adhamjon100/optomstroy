'use strict';
// Шим `crypto`: синхронные хэши/HMAC/HKDF/AES-256-GCM на @noble/hashes и @noble/ciphers (уже в pos-api/node_modules),
// случайные числа — WebCrypto getRandomValues. Асимметричные ключи (generateKeyPairSync и т. п.) не поддержаны:
// jwt-keys.js подменяется отдельно (ключ из WebCrypto). Исключение — только проверка подписи RSA: createPublicKey
// (SPKI DER ключа rsaEncryption) и verify (RSASSA-PKCS1-v1_5) синхронно на BigInt — ими pos-api проверяет ключ входа
// без PIN браузера на Windows (common/auth/hello-key.ts: parseHelloPublicKey, verifyHelloSignature; 09 BIO-041,
// 15 ADR-116 п. 4). WebCrypto здесь не годится: он асинхронный, а код pos-api — синхронный. Подпись, закрытые ключи,
// RSA-PSS, EC и прочие форматы — по-прежнему ERR_DEMO_UNSUPPORTED.
const { Buffer } = require('./node-buffer.cjs');
const { sha256, sha512, sha384, sha224 } = require('@noble/hashes/sha2');
const { sha1, md5 } = require('@noble/hashes/legacy');
const { hmac } = require('@noble/hashes/hmac');
const { hkdf } = require('@noble/hashes/hkdf');
const { gcm } = require('@noble/ciphers/aes');

const webcrypto = globalThis.crypto;
const HASHES = { sha256, sha512, sha384, sha224, sha1, md5, 'sha-256': sha256, 'sha-512': sha512, 'sha-1': sha1 };
function hashFn(alg) {
  const h = HASHES[String(alg).toLowerCase()];
  if (!h) {
    const e = new Error(`Digest method not supported: ${alg}`);
    e.code = 'ERR_CRYPTO_INVALID_DIGEST';
    throw e;
  }
  return h;
}
function toBytes(data, enc) {
  if (typeof data === 'string') return Buffer.from(data, enc || 'utf8');
  if (data instanceof Uint8Array) return data;
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (data && data.__posKeyObject) return data.__bytes;
  throw new TypeError('The "data" argument must be of type string or an instance of Buffer, TypedArray, or DataView.');
}
function out(bytes, enc) {
  const b = Buffer.from(bytes.buffer ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) : bytes);
  return enc ? b.toString(enc) : b;
}
class Hash {
  constructor(alg, ctx) {
    this._alg = alg;
    this._h = ctx || hashFn(alg).create();
    this._done = false;
  }
  update(data, enc) {
    if (this._done) throw Object.assign(new Error('Digest already called'), { code: 'ERR_CRYPTO_HASH_FINALIZED' });
    this._h.update(toBytes(data, enc));
    return this;
  }
  digest(enc) {
    if (this._done) throw Object.assign(new Error('Digest already called'), { code: 'ERR_CRYPTO_HASH_FINALIZED' });
    this._done = true;
    return out(this._h.digest(), enc);
  }
  copy() {
    return new Hash(this._alg, this._h.clone());
  }
}
class Hmac {
  constructor(alg, key) {
    this._h = hmac.create(hashFn(alg), toBytes(key));
    this._done = false;
  }
  update(data, enc) {
    this._h.update(toBytes(data, enc));
    return this;
  }
  digest(enc) {
    if (this._done) throw Object.assign(new Error('Digest already called'), { code: 'ERR_CRYPTO_HASH_FINALIZED' });
    this._done = true;
    return out(this._h.digest(), enc);
  }
}
function createHash(alg) {
  return new Hash(alg);
}
function createHmac(alg, key) {
  return new Hmac(alg, key);
}
function hash(alg, data, enc = 'hex') {
  return out(hashFn(alg)(toBytes(data)), enc === 'buffer' ? undefined : enc);
}
function randomFill(u8) {
  for (let i = 0; i < u8.length; i += 65536) webcrypto.getRandomValues(u8.subarray(i, Math.min(u8.length, i + 65536)));
  return u8;
}
function randomBytes(n, cb) {
  const b = Buffer.alloc(n);
  randomFill(b);
  if (typeof cb === 'function') {
    queueMicrotask(() => cb(null, b));
    return undefined;
  }
  return b;
}
function randomFillSync(buf, offset = 0, size) {
  const u = toBytes(buf);
  const end = size === undefined ? u.length : offset + size;
  randomFill(u.subarray(offset, end));
  return buf;
}
function randomUUID() {
  if (typeof webcrypto.randomUUID === 'function') return webcrypto.randomUUID();
  const b = randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
function randomInt(min, max, cb) {
  if (max === undefined || typeof max === 'function') {
    cb = max;
    max = min;
    min = 0;
  }
  const range = max - min;
  if (!Number.isSafeInteger(range) || range <= 0) throw new RangeError('The value of "max" is out of range.');
  const limit = Math.floor(0x1000000000000 / range) * range; // 48 бит
  let x;
  do {
    const b = randomBytes(6);
    x = b.readUIntBE(0, 6);
  } while (x >= limit);
  const r = min + (x % range);
  if (typeof cb === 'function') {
    queueMicrotask(() => cb(null, r));
    return undefined;
  }
  return r;
}
function timingSafeEqual(a, b) {
  const x = toBytes(a);
  const y = toBytes(b);
  if (x.length !== y.length) {
    const e = new RangeError('Input buffers must have the same byte length');
    e.code = 'ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH';
    throw e;
  }
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}
function hkdfSync(digest, ikm, salt, info, keylen) {
  const r = hkdf(hashFn(digest), toBytes(ikm), toBytes(salt), toBytes(info), keylen);
  return r.buffer.slice(r.byteOffset, r.byteOffset + r.byteLength);
}
function hkdfAsync(digest, ikm, salt, info, keylen, cb) {
  try {
    const r = hkdfSync(digest, ikm, salt, info, keylen);
    queueMicrotask(() => cb(null, r));
  } catch (e) {
    queueMicrotask(() => cb(e));
  }
}

function checkGcm(alg) {
  if (String(alg).toLowerCase() !== 'aes-256-gcm') {
    const e = new Error(`Unsupported cipher: ${alg} (в браузерном бэкенде — только aes-256-gcm)`);
    e.code = 'ERR_CRYPTO_UNKNOWN_CIPHER';
    throw e;
  }
}
class GcmCipher {
  constructor(alg, key, iv, opts, decrypt) {
    checkGcm(alg);
    this._key = toBytes(key);
    this._iv = toBytes(iv);
    this._tagLen = (opts && opts.authTagLength) || 16;
    this._aad = undefined;
    this._chunks = [];
    this._decrypt = decrypt;
    this._tag = undefined;
  }
  setAAD(aad) {
    this._aad = toBytes(aad);
    return this;
  }
  setAutoPadding() {
    return this;
  }
  setAuthTag(tag) {
    this._tag = toBytes(tag);
    return this;
  }
  getAuthTag() {
    if (!this._outTag) throw new Error('Attempting to get auth tag in unsupported state');
    return Buffer.from(this._outTag);
  }
  update(data, inEnc, outEnc) {
    this._chunks.push(Buffer.from(toBytes(data, inEnc)));
    return outEnc ? '' : Buffer.alloc(0);
  }
  final(outEnc) {
    const input = Buffer.concat(this._chunks);
    const c = gcm(this._key, this._iv, this._aad);
    let res;
    if (this._decrypt) {
      if (!this._tag) throw new Error('Unsupported state or unable to authenticate data');
      try {
        res = c.decrypt(Buffer.concat([input, Buffer.from(this._tag)]));
      } catch {
        throw new Error('Unsupported state or unable to authenticate data');
      }
    } else {
      const enc = c.encrypt(input);
      res = enc.subarray(0, enc.length - 16);
      this._outTag = enc.subarray(enc.length - 16, enc.length - 16 + this._tagLen);
    }
    return out(res, outEnc);
  }
}
function createCipheriv(alg, key, iv, opts) {
  return new GcmCipher(alg, key, iv, opts, false);
}
function createDecipheriv(alg, key, iv, opts) {
  return new GcmCipher(alg, key, iv, opts, true);
}
function unsupported(name) {
  return () => {
    const e = new Error(`crypto.${name} не поддерживается в браузерном бэкенде`);
    e.code = 'ERR_DEMO_UNSUPPORTED';
    throw e;
  };
}
class KeyObject {
  constructor(type, bytes) {
    this.__posKeyObject = true;
    this.type = type;
    this.__bytes = bytes;
    this.symmetricKeySize = bytes.length;
  }
  export() {
    return Buffer.from(this.__bytes);
  }
  equals(o) {
    return o instanceof KeyObject && timingSafeEqual(this.__bytes, o.__bytes);
  }
}
function createSecretKey(key, enc) {
  return new KeyObject('secret', toBytes(key, enc));
}

// ---- открытый ключ RSA и проверка RSASSA-PKCS1-v1_5 (только то, что нужно common/auth/hello-key.ts pos-api)
const RSA_ENCRYPTION_OID = '2a864886f70d010101'; // 1.2.840.113549.1.1.1
const RSA_PKCS1_PADDING = 1;
// DigestInfo (RFC 8017 §9.2, прим. 1) перед хэшем.
const DIGEST_INFO = {
  sha1: '3021300906052b0e03021a05000414',
  sha256: '3031300d060960864801650304020105000420',
  sha384: '3041300d060960864801650304020205000430',
  sha512: '3051300d060960864801650304020305000440',
};
function decoderError() {
  const e = new Error('error:1E08010C:DECODER routines::unsupported');
  e.code = 'ERR_OSSL_UNSUPPORTED';
  return e;
}
// Элемент DER с тегом want от позиции pos: { start, end } содержимого (длина — короткая или 1…4 байта).
function der(bytes, pos, want) {
  if (pos + 2 > bytes.length || bytes[pos] !== want) throw decoderError();
  let len = bytes[pos + 1];
  let p = pos + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n < 1 || n > 4 || p + n > bytes.length) throw decoderError();
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + bytes[p++];
  }
  if (p + len > bytes.length) throw decoderError();
  return { start: p, end: p + len };
}
function bigOf(bytes) {
  let x = 0n;
  for (const b of bytes) x = (x << 8n) | BigInt(b);
  return x;
}
function bitLength(x) {
  return x === 0n ? 0 : x.toString(2).length;
}
function modPow(base, exp, mod) {
  let result = 1n;
  let b = base % mod;
  let e = exp;
  while (e > 0n) {
    if (e & 1n) result = (result * b) % mod;
    b = (b * b) % mod;
    e >>= 1n;
  }
  return result;
}
// SPKI: SEQUENCE { SEQUENCE { OID rsaEncryption, NULL? }, BIT STRING { SEQUENCE { INTEGER n, INTEGER e } } }. Байты
// после внешнего SEQUENCE, как и OpenSSL в Node, не мешают (ключ — без них).
function parseRsaSpki(bytes) {
  const outer = der(bytes, 0, 0x30);
  const alg = der(bytes, outer.start, 0x30);
  const oid = der(bytes, alg.start, 0x06);
  if (Buffer.from(bytes.subarray(oid.start, oid.end)).toString('hex') !== RSA_ENCRYPTION_OID) {
    const e = new Error('crypto.createPublicKey: в браузерном бэкенде — только ключи RSA (rsaEncryption)');
    e.code = 'ERR_DEMO_UNSUPPORTED';
    throw e;
  }
  const bits = der(bytes, alg.end, 0x03);
  if (bits.end !== outer.end || bytes[bits.start] !== 0) throw decoderError();
  const seq = der(bytes, bits.start + 1, 0x30);
  const nEl = der(bytes, seq.start, 0x02);
  const eEl = der(bytes, nEl.end, 0x02);
  if (eEl.end !== seq.end || bytes[nEl.start] & 0x80 || bytes[eEl.start] & 0x80) throw decoderError();
  const n = bigOf(bytes.subarray(nEl.start, nEl.end));
  const e = bigOf(bytes.subarray(eEl.start, eEl.end));
  if (n === 0n || e === 0n) throw decoderError();
  return { n, e, end: outer.end };
}
class RsaPublicKeyObject {
  constructor(spki, n, e) {
    this.type = 'public';
    this.asymmetricKeyType = 'rsa';
    this.asymmetricKeyDetails = { modulusLength: bitLength(n), publicExponent: e };
    this.__spki = spki;
    this.__n = n;
    this.__e = e;
  }
  export(options) {
    const o = options || {};
    if (o.format === 'der' && o.type === 'spki') return Buffer.from(this.__spki);
    return unsupported('KeyObject.export (кроме der/spki)')();
  }
}
function createPublicKey(input) {
  if (input instanceof RsaPublicKeyObject) return input;
  const o = input && typeof input === 'object' && !ArrayBuffer.isView(input) ? input : { key: input };
  if (o.key instanceof RsaPublicKeyObject) return o.key;
  if (o.format !== 'der' || o.type !== 'spki') return unsupported('createPublicKey (кроме der/spki)')();
  const bytes = Buffer.from(toBytes(o.key));
  const { n, e, end } = parseRsaSpki(bytes);
  return new RsaPublicKeyObject(bytes.subarray(0, end), n, e);
}
// crypto.verify(algorithm, data, key, signature[, callback]) — RSASSA-PKCS1-v1_5; неверная подпись — false.
function verify(algorithm, data, key, signature, callback) {
  const o = key instanceof RsaPublicKeyObject ? { key } : key || {};
  const k = o.key instanceof RsaPublicKeyObject ? o.key : createPublicKey(o);
  if (o.padding !== undefined && o.padding !== RSA_PKCS1_PADDING) return unsupported('verify (кроме RSA_PKCS1_PADDING)')();
  const name = String(algorithm).toLowerCase().replace('-', '');
  const prefix = DIGEST_INFO[name];
  if (!prefix) return unsupported(`verify (${algorithm})`)();
  const len = Math.ceil(k.asymmetricKeyDetails.modulusLength / 8);
  const sig = toBytes(signature);
  let ok = false;
  if (sig.length === len) {
    const s = bigOf(sig);
    if (s < k.__n) {
      const em = modPow(s, k.__e, k.__n).toString(16).padStart(len * 2, '0');
      const t = prefix + Buffer.from(hashFn(name)(toBytes(data))).toString('hex');
      const want = '0001' + 'ff'.repeat(len - 3 - t.length / 2) + '00' + t;
      ok = len - 3 - t.length / 2 >= 8 && em === want;
    }
  }
  if (typeof callback === 'function') {
    queueMicrotask(() => callback(null, ok));
    return undefined;
  }
  return ok;
}
module.exports = {
  createHash,
  createHmac,
  hash,
  randomBytes,
  randomFillSync,
  randomFill: (buf, ...rest) => {
    const cb = rest.pop();
    randomFillSync(buf);
    queueMicrotask(() => cb(null, buf));
  },
  randomUUID,
  randomInt,
  pseudoRandomBytes: randomBytes,
  getRandomValues: (a) => webcrypto.getRandomValues(a),
  timingSafeEqual,
  hkdfSync,
  hkdf: hkdfAsync,
  createCipheriv,
  createDecipheriv,
  createSecretKey,
  KeyObject,
  createPublicKey,
  createPrivateKey: unsupported('createPrivateKey'),
  generateKeyPairSync: unsupported('generateKeyPairSync'),
  generateKeyPair: unsupported('generateKeyPair'),
  createSign: unsupported('createSign'),
  createVerify: unsupported('createVerify'),
  sign: unsupported('sign'),
  verify,
  pbkdf2Sync: unsupported('pbkdf2Sync'),
  pbkdf2: unsupported('pbkdf2'),
  scryptSync: unsupported('scryptSync'),
  publicEncrypt: unsupported('publicEncrypt'),
  privateDecrypt: unsupported('privateDecrypt'),
  getHashes: () => ['md5', 'sha1', 'sha224', 'sha256', 'sha384', 'sha512'],
  getCiphers: () => ['aes-256-gcm'],
  getCurves: () => [],
  constants: { RSA_PKCS1_PADDING },
  webcrypto,
  subtle: webcrypto.subtle,
};

'use strict';
// Шим `buffer`: npm buffer 5.7.1 + кодировка base64url (Node ≥ 15), BigInt-методы чтения/записи, isUtf8.
const mod = require('nm:buffer/index.js');
const { Buffer } = mod;

const toUrl = (b64) => b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const fromUrl = (s) => String(s).replace(/-/g, '+').replace(/_/g, '/');
const isUrl = (enc) => typeof enc === 'string' && enc.toLowerCase() === 'base64url';

if (!Buffer.__posPatched) {
  Object.defineProperty(Buffer, '__posPatched', { value: true });
  const origFrom = Buffer.from;
  Buffer.from = function from(value, encOrOffset, length) {
    if (typeof value === 'string' && isUrl(encOrOffset)) return origFrom.call(Buffer, fromUrl(value), 'base64');
    return origFrom.call(Buffer, value, encOrOffset, length);
  };
  const origByteLength = Buffer.byteLength;
  Buffer.byteLength = function byteLength(str, enc) {
    if (typeof str === 'string' && isUrl(enc)) return origByteLength.call(Buffer, fromUrl(str), 'base64');
    return origByteLength.call(Buffer, str, enc);
  };
  const origIsEncoding = Buffer.isEncoding;
  Buffer.isEncoding = function isEncoding(enc) {
    return isUrl(enc) || origIsEncoding.call(Buffer, enc);
  };
  const origAlloc = Buffer.alloc;
  Buffer.alloc = function alloc(size, fill, enc) {
    if (typeof fill === 'string' && isUrl(enc)) return origAlloc.call(Buffer, size, fromUrl(fill), 'base64');
    return origAlloc.call(Buffer, size, fill, enc);
  };
  const proto = Buffer.prototype;
  const origToString = proto.toString;
  proto.toString = function toString(enc, start, end) {
    if (isUrl(enc)) return toUrl(origToString.call(this, 'base64', start, end));
    return origToString.call(this, enc, start, end);
  };
  proto.toLocaleString = proto.toString;
  const origWrite = proto.write;
  proto.write = function write(string, offset, length, enc) {
    if (isUrl(enc)) return origWrite.call(this, fromUrl(string), offset, length, 'base64');
    if (isUrl(length)) return origWrite.call(this, fromUrl(string), offset, 'base64');
    if (isUrl(offset)) return origWrite.call(this, fromUrl(string), 'base64');
    return origWrite.call(this, string, offset, length, enc);
  };
  const dv = (b) => new DataView(b.buffer, b.byteOffset, b.byteLength);
  if (!proto.readBigUInt64LE) {
    proto.readBigUInt64LE = function (o = 0) {
      return dv(this).getBigUint64(o, true);
    };
    proto.readBigUInt64BE = function (o = 0) {
      return dv(this).getBigUint64(o, false);
    };
    proto.readBigInt64LE = function (o = 0) {
      return dv(this).getBigInt64(o, true);
    };
    proto.readBigInt64BE = function (o = 0) {
      return dv(this).getBigInt64(o, false);
    };
    proto.writeBigUInt64LE = function (v, o = 0) {
      dv(this).setBigUint64(o, BigInt(v), true);
      return o + 8;
    };
    proto.writeBigUInt64BE = function (v, o = 0) {
      dv(this).setBigUint64(o, BigInt(v), false);
      return o + 8;
    };
    proto.writeBigInt64LE = function (v, o = 0) {
      dv(this).setBigInt64(o, BigInt(v), true);
      return o + 8;
    };
    proto.writeBigInt64BE = function (v, o = 0) {
      dv(this).setBigInt64(o, BigInt(v), false);
      return o + 8;
    };
    proto.readBigUint64LE = proto.readBigUInt64LE;
    proto.readBigUint64BE = proto.readBigUInt64BE;
    proto.writeBigUint64LE = proto.writeBigUInt64LE;
    proto.writeBigUint64BE = proto.writeBigUInt64BE;
  }
  // subarray у buffer 5.x возвращает Buffer через species; страхуемся.
  const origSub = Uint8Array.prototype.subarray;
  proto.subarray = function subarray(start, end) {
    const u = origSub.call(this, start, end);
    return Object.setPrototypeOf(u, Buffer.prototype);
  };
}

const atob = globalThis.atob;
const btoa = globalThis.btoa;
function isUtf8(input) {
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(input);
    return true;
  } catch {
    return false;
  }
}
function isAscii(input) {
  for (const b of input) if (b > 127) return false;
  return true;
}
module.exports = {
  ...mod,
  Buffer,
  SlowBuffer: mod.SlowBuffer,
  INSPECT_MAX_BYTES: mod.INSPECT_MAX_BYTES,
  kMaxLength: mod.kMaxLength,
  kStringMaxLength: 0x1fffffe8,
  constants: { MAX_LENGTH: mod.kMaxLength, MAX_STRING_LENGTH: 0x1fffffe8 },
  Blob: globalThis.Blob,
  File: globalThis.File,
  atob,
  btoa,
  isUtf8,
  isAscii,
  transcode() {
    throw new Error('buffer.transcode is not supported');
  },
};

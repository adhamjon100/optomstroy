'use strict';
// Шим `zlib`: сжатие тел запросов в демо не используется (body-parser inflate) — понятная ошибка.
function unsupported(name) {
  return () => {
    const e = new Error(`zlib.${name} не поддерживается в браузерном бэкенде`);
    e.code = 'ERR_DEMO_UNSUPPORTED';
    throw e;
  };
}
const names = ['createGzip', 'createGunzip', 'createDeflate', 'createInflate', 'createDeflateRaw', 'createInflateRaw', 'createUnzip', 'createBrotliCompress', 'createBrotliDecompress', 'gzipSync', 'gunzipSync', 'deflateSync', 'inflateSync', 'deflateRawSync', 'inflateRawSync', 'unzipSync', 'brotliCompressSync', 'brotliDecompressSync', 'gzip', 'gunzip', 'deflate', 'inflate', 'brotliCompress', 'brotliDecompress', 'crc32'];
const constants = { Z_NO_FLUSH: 0, Z_SYNC_FLUSH: 2, Z_FULL_FLUSH: 3, Z_FINISH: 4, Z_OK: 0, Z_DEFAULT_COMPRESSION: -1, BROTLI_OPERATION_FLUSH: 1, BROTLI_OPERATION_FINISH: 2, BROTLI_PARAM_QUALITY: 1 };
const m = { constants, ...constants };
for (const n of names) m[n] = unsupported(n);
module.exports = m;

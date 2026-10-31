'use strict';
// Шим `tls`, `dns`, `dns/promises`, `http2`, `dgram`: только заглушки, сетевые соединения запрещены.
function forbidden() {
  const e = new Error('Сетевые соединения из браузерного бэкенда запрещены');
  e.code = 'ERR_DEMO_NO_NETWORK';
  throw e;
}
module.exports = {
  connect: forbidden,
  createServer: forbidden,
  createSecureServer: forbidden,
  createSocket: forbidden,
  createSecureContext: () => ({}),
  lookup: forbidden,
  resolve: forbidden,
  resolve4: forbidden,
  resolve6: forbidden,
  promises: { lookup: forbidden, resolve: forbidden },
  rootCertificates: [],
  DEFAULT_MIN_VERSION: 'TLSv1.2',
  DEFAULT_MAX_VERSION: 'TLSv1.3',
  TLSSocket: function TLSSocket() {
    forbidden();
  },
  checkServerIdentity: () => undefined,
  getCiphers: () => [],
  setDefaultResultOrder() {},
  getDefaultResultOrder: () => 'verbatim',
  constants: {},
};

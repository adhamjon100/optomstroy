'use strict';
// Шим `module`: createRequire даёт require, который всегда бросает MODULE_NOT_FOUND (необязательные пакеты Nest).
function notFound(id) {
  const e = new Error(`Cannot find module '${id}' (браузерный бэкенд: динамический require недоступен)`);
  e.code = 'MODULE_NOT_FOUND';
  return e;
}
function createRequire() {
  const req = (id) => {
    throw notFound(id);
  };
  req.resolve = (id) => {
    throw notFound(id);
  };
  req.cache = {};
  return req;
}
module.exports = {
  createRequire,
  builtinModules: [],
  isBuiltin: () => false,
  register() {},
  registerHooks() {},
  Module: function Module() {},
  findPackageJSON: () => undefined,
  enableCompileCache() {},
  constants: {},
};

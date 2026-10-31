'use strict';
// Эталон WP-T1: настоящий node:url. Единственное дополнение — пути виртуальной раскладки /vfs/… (import.meta.url
// файлов dist указывает в /vfs/pos-api/dist/…, как в бандле) остаются POSIX-путями и на Windows: настоящий
// fileURLToPath('file:///vfs/…') на Windows бросает ERR_INVALID_FILE_URL_PATH (сервер pos-api работает на Linux, где
// такого нет). Сами файлы по этим путям находит native/fs-native.cjs.
const url = require('node:url');

const isVfsUrl = (u) => {
  try {
    const x = u instanceof URL ? u : new URL(String(u));
    return x.protocol === 'file:' && (x.pathname === '/vfs' || x.pathname.startsWith('/vfs/'));
  } catch {
    return false;
  }
};
function fileURLToPath(u, opts) {
  if (isVfsUrl(u)) return decodeURIComponent((u instanceof URL ? u : new URL(String(u))).pathname);
  return url.fileURLToPath(u, opts);
}
function pathToFileURL(p, opts) {
  const s = String(p).split('\\').join('/');
  if (s === '/vfs' || s.startsWith('/vfs/')) return new URL(`file://${encodeURI(s)}`);
  return url.pathToFileURL(p, opts);
}
module.exports = { ...url, fileURLToPath, pathToFileURL };

'use strict';
// Шим `fs`/`fs/promises`: виртуальная fs только для чтения. Набор файлов собирает vfs/build-vfs.mjs:
//  - текст и мелкие файлы встроены в бандл (модуль pos-vfs-data: миграции, seeds, dev-миграции, фикстуры 1С,
//    шаблоны PDF);
//  - крупные двоичные файлы (шрифты Inter) лежат рядом со статикой (site/backend/vfs/...) и подгружаются
//    один раз при старте: `await fs.__vfs.preloadExternal(baseUrl)` (fetch своего origin, проверка размера и sha256).
// Ключи — пути /vfs/<как в репозитории>; import.meta.url файлов pos-api указывает в /vfs/pos-api/dist/…, поэтому
// относительные пути pos-api (../migrations/, ../../../assets/, ../../../../contracts/onec/fixtures/) совпадают.
// Запись — только в память воркера (не сохраняется между запусками).
const { Buffer } = require('./node-buffer.cjs');
const path = require('./node-path.cjs');
const { files: EMBEDDED, external: EXTERNAL = {} } = require('pos-vfs-data');

const mem = new Map(); // путь → Buffer (записанные во время работы)
const memDirs = new Set(['/', '/vfs', '/tmp']);
const decoded = new Map();
const mtime = new Date();

function toPath(p) {
  if (p instanceof URL) p = decodeURIComponent(p.pathname);
  else if (p && typeof p === 'object' && typeof p.href === 'string') p = decodeURIComponent(new URL(p.href).pathname);
  else if (p instanceof Uint8Array) p = new TextDecoder().decode(p);
  let s = String(p);
  if (s.startsWith('file://')) s = decodeURIComponent(new URL(s).pathname);
  return path.resolve(s.replace(/\\/g, '/'));
}
function enoent(syscall, p) {
  const e = new Error(`ENOENT: no such file or directory, ${syscall} '${p}'`);
  e.code = 'ENOENT';
  e.errno = -2;
  e.syscall = syscall;
  e.path = p;
  return e;
}
function notLoaded(p) {
  const e = new Error(`Файл виртуальной fs ${p} ещё не загружен (нужен fs.__vfs.preloadExternal до первого чтения)`);
  e.code = 'ERR_DEMO_VFS_NOT_LOADED';
  e.path = p;
  return e;
}
function getFile(p) {
  if (mem.has(p)) return mem.get(p);
  if (decoded.has(p)) return decoded.get(p);
  const f = EMBEDDED[p];
  if (f === undefined) {
    if (EXTERNAL[p]) throw notLoaded(p);
    return undefined;
  }
  const b = typeof f === 'string' ? Buffer.from(f, 'utf8') : Buffer.from(f.b64, 'base64');
  decoded.set(p, b);
  return b;
}
function listDir(p) {
  const prefix = p.endsWith('/') ? p : p + '/';
  const names = new Map();
  const add = (full, isDir) => {
    if (!full.startsWith(prefix)) return;
    const rest = full.slice(prefix.length);
    if (!rest) return;
    const i = rest.indexOf('/');
    if (i < 0) names.set(rest, isDir ? 'dir' : names.get(rest) ?? 'file');
    else names.set(rest.slice(0, i), 'dir');
  };
  for (const k of Object.keys(EMBEDDED)) add(k, false);
  for (const k of Object.keys(EXTERNAL)) add(k, false);
  for (const k of mem.keys()) add(k, false);
  for (const d of memDirs) add(d, true);
  return names;
}
function isDir(p) {
  if (memDirs.has(p)) return true;
  const prefix = p.endsWith('/') ? p : p + '/';
  for (const k of Object.keys(EMBEDDED)) if (k.startsWith(prefix)) return true;
  for (const k of Object.keys(EXTERNAL)) if (k.startsWith(prefix)) return true;
  for (const k of mem.keys()) if (k.startsWith(prefix)) return true;
  return false;
}
class Stats {
  constructor(kind, size) {
    this._kind = kind;
    this.size = size;
    this.mode = kind === 'dir' ? 0o40755 : 0o100644;
    this.mtime = mtime;
    this.ctime = mtime;
    this.atime = mtime;
    this.birthtime = mtime;
    this.mtimeMs = mtime.getTime();
    this.ctimeMs = this.mtimeMs;
    this.atimeMs = this.mtimeMs;
    this.birthtimeMs = this.mtimeMs;
    this.uid = 0;
    this.gid = 0;
    this.dev = 1;
    this.ino = 0;
    this.nlink = 1;
    this.blksize = 4096;
    this.blocks = Math.ceil(size / 4096);
  }
  isFile() {
    return this._kind === 'file';
  }
  isDirectory() {
    return this._kind === 'dir';
  }
  isSymbolicLink() {
    return false;
  }
  isFIFO() {
    return false;
  }
  isSocket() {
    return false;
  }
  isBlockDevice() {
    return false;
  }
  isCharacterDevice() {
    return false;
  }
}
class Dirent {
  constructor(name, kind, parent) {
    this.name = name;
    this._kind = kind;
    this.parentPath = parent;
    this.path = parent;
  }
  isFile() {
    return this._kind === 'file';
  }
  isDirectory() {
    return this._kind === 'dir';
  }
  isSymbolicLink() {
    return false;
  }
}
const encOf = (opts) => (typeof opts === 'string' ? opts : opts && opts.encoding) || null;

function readFileSync(p, opts) {
  if (typeof p === 'number') throw new Error('fs.readFileSync(fd) не поддерживается');
  const fp = toPath(p);
  const b = getFile(fp);
  if (!b) throw enoent('open', fp);
  const enc = encOf(opts);
  return enc ? b.toString(enc) : Buffer.from(b);
}
function existsSync(p) {
  try {
    const fp = toPath(p);
    return EXTERNAL[fp] !== undefined || getFile(fp) !== undefined || isDir(fp);
  } catch {
    return false;
  }
}
function statSync(p, opts) {
  const fp = toPath(p);
  if (EXTERNAL[fp] && !decoded.has(fp) && !mem.has(fp)) return new Stats('file', EXTERNAL[fp].bytes);
  const b = getFile(fp);
  if (b) return new Stats('file', b.length);
  if (isDir(fp)) return new Stats('dir', 0);
  if (opts && opts.throwIfNoEntry === false) return undefined;
  throw enoent('stat', fp);
}
function readdirSync(p, opts) {
  const fp = toPath(p);
  if (!isDir(fp)) throw enoent('scandir', fp);
  const entries = [...listDir(fp)].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  if (opts && typeof opts === 'object' && opts.withFileTypes) return entries.map(([n, k]) => new Dirent(n, k, fp));
  return entries.map(([n]) => n);
}
function realpathSync(p) {
  return toPath(p);
}
realpathSync.native = realpathSync;
function accessSync(p) {
  if (!existsSync(p)) throw enoent('access', toPath(p));
}
function mkdirSync(p, opts) {
  const fp = toPath(p);
  if (opts && opts.recursive) {
    let cur = '';
    for (const part of fp.split('/').filter(Boolean)) {
      cur += '/' + part;
      memDirs.add(cur);
    }
  } else memDirs.add(fp);
  return undefined;
}
function writeFileSync(p, data, opts) {
  const fp = toPath(p);
  const enc = encOf(opts) || 'utf8';
  mem.set(fp, typeof data === 'string' ? Buffer.from(data, enc) : Buffer.from(data));
  memDirs.add(path.dirname(fp));
}
function appendFileSync(p, data, opts) {
  const fp = toPath(p);
  const prev = getFile(fp) || Buffer.alloc(0);
  const enc = encOf(opts) || 'utf8';
  mem.set(fp, Buffer.concat([prev, typeof data === 'string' ? Buffer.from(data, enc) : Buffer.from(data)]));
}
function rmSync(p) {
  const fp = toPath(p);
  mem.delete(fp);
  decoded.delete(fp);
  for (const k of [...mem.keys()]) if (k.startsWith(fp + '/')) mem.delete(k);
  memDirs.delete(fp);
}
function renameSync(a, b) {
  const fa = toPath(a);
  const fb = toPath(b);
  const d = getFile(fa);
  if (!d) throw enoent('rename', fa);
  mem.set(fb, d);
  mem.delete(fa);
}
function copyFileSync(a, b) {
  const d = getFile(toPath(a));
  if (!d) throw enoent('copyfile', toPath(a));
  mem.set(toPath(b), Buffer.from(d));
}
const notSupported = (name) => () => {
  const e = new Error(`fs.${name} не поддерживается в браузерном бэкенде`);
  e.code = 'ERR_DEMO_UNSUPPORTED';
  throw e;
};
const wrapCb = (fn) =>
  function (...args) {
    const cb = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    let res;
    let err = null;
    try {
      res = fn(...args);
    } catch (e) {
      err = e;
    }
    if (cb) queueMicrotask(() => cb(err, res));
  };
const wrapP = (fn) => async (...args) => fn(...args);
const promises = {
  readFile: wrapP(readFileSync),
  writeFile: wrapP(writeFileSync),
  appendFile: wrapP(appendFileSync),
  readdir: wrapP(readdirSync),
  stat: wrapP(statSync),
  lstat: wrapP(statSync),
  mkdir: wrapP(mkdirSync),
  rm: wrapP(rmSync),
  rmdir: wrapP(rmSync),
  unlink: wrapP(rmSync),
  rename: wrapP(renameSync),
  copyFile: wrapP(copyFileSync),
  access: wrapP(accessSync),
  realpath: wrapP(realpathSync),
  open: async () => notSupported('promises.open')(),
  mkdtemp: async (prefix) => {
    const d = `${prefix}${Math.random().toString(36).slice(2, 8)}`;
    mkdirSync(d, { recursive: true });
    return d;
  },
};
const constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1, O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2, O_CREAT: 64, O_EXCL: 128, O_TRUNC: 512, O_APPEND: 1024, S_IFMT: 61440, S_IFREG: 32768, S_IFDIR: 16384 };
promises.constants = constants;
module.exports = {
  readFileSync,
  existsSync,
  statSync,
  lstatSync: statSync,
  readdirSync,
  realpathSync,
  accessSync,
  mkdirSync,
  writeFileSync,
  appendFileSync,
  rmSync,
  rmdirSync: rmSync,
  unlinkSync: rmSync,
  renameSync,
  copyFileSync,
  readFile: wrapCb(readFileSync),
  writeFile: wrapCb(writeFileSync),
  appendFile: wrapCb(appendFileSync),
  readdir: wrapCb(readdirSync),
  stat: wrapCb(statSync),
  lstat: wrapCb(statSync),
  access: wrapCb(accessSync),
  mkdir: wrapCb(mkdirSync),
  unlink: wrapCb(rmSync),
  rename: wrapCb(renameSync),
  realpath: Object.assign(wrapCb(realpathSync), { native: wrapCb(realpathSync) }),
  exists: (p, cb) => queueMicrotask(() => cb(existsSync(p))),
  openSync: notSupported('openSync'),
  closeSync: () => {},
  readSync: notSupported('readSync'),
  writeSync: notSupported('writeSync'),
  fstatSync: notSupported('fstatSync'),
  open: notSupported('open'),
  close: (_fd, cb) => cb && queueMicrotask(() => cb(null)),
  createReadStream: notSupported('createReadStream'),
  createWriteStream: notSupported('createWriteStream'),
  watch: notSupported('watch'),
  watchFile: () => {},
  unwatchFile: () => {},
  Stats,
  Dirent,
  constants,
  promises,
  __vfs: {
    mem,
    EMBEDDED,
    EXTERNAL,
    list: () => [...Object.keys(EMBEDDED), ...Object.keys(EXTERNAL)],
    /** Загрузить внешние файлы vfs (fetch своего origin); baseUrl — адрес каталога backend/ сайта. */
    async preloadExternal(baseUrl) {
      const hex = (ab) => [...new Uint8Array(ab)].map((x) => x.toString(16).padStart(2, '0')).join('');
      const loaded = [];
      await Promise.all(
        Object.entries(EXTERNAL).map(async ([key, meta]) => {
          if (decoded.has(key)) return;
          const res = await fetch(new URL(meta.url, baseUrl));
          if (!res.ok) throw new Error(`vfs: ${meta.url} → HTTP ${res.status}`);
          const ab = await res.arrayBuffer();
          if (ab.byteLength !== meta.bytes) throw new Error(`vfs: ${meta.url}: ${ab.byteLength} байт вместо ${meta.bytes}`);
          if (meta.sha256 && globalThis.crypto && globalThis.crypto.subtle) {
            const got = hex(await globalThis.crypto.subtle.digest('SHA-256', ab));
            if (got !== meta.sha256) throw new Error(`vfs: ${meta.url}: sha256 не совпадает`);
          }
          decoded.set(key, Buffer.from(new Uint8Array(ab)));
          loaded.push(key);
        }),
      );
      return loaded;
    },
    /** Положить содержимое внешнего файла напрямую (Node-прогон бандла читает его с диска). */
    provide(key, bytes) {
      if (!EXTERNAL[key]) throw new Error(`vfs: ${key} не внешний файл`);
      decoded.set(key, Buffer.from(bytes));
    },
  },
};

'use strict';
// Эталон WP-T1 (native-runner.mjs): НАСТОЯЩИЙ node:fs вместо виртуальной fs shims/node-fs.cjs. Код pos-api и точка
// входа демо обращаются к файлам по путям /vfs/<как в репозитории> (import.meta.url файлов dist → /vfs/pos-api/dist/…,
// миграции → /vfs/pos-api/migrations, фикстуры 1С → /vfs/contracts/onec/fixtures, шаблоны PDF и шрифты). Здесь
// такие пути переводятся в настоящие каталоги репозитория по той же таблице, что vfs/build-vfs.mjs (VFS_SOURCES,
// записывается native-runner.mjs в vfs-map.json), список каталога фильтруется тем же include, а к прочитанному
// содержимому применяются те же преобразования сборки (vfs/transforms.mjs: водяной знак PDF). Запись (MEDIA_DIR
// /vfs/media) — в рабочий каталог эталона. Остальные пути — как есть.
const nfs = require('node:fs');
const npath = require('node:path');
const MAP = require('./vfs-map.json');
const { transforms } = require('../../../vfs/transforms.mjs');

const sources = MAP.sources.map((s) => ({ ...s, include: new RegExp(s.include, s.flags) }));
const norm = (p) => p.replace(/\\/g, '/');

function vfsKey(p) {
  if (p instanceof URL) p = decodeURIComponent(p.pathname);
  else if (Buffer.isBuffer(p)) p = p.toString('utf8');
  else if (typeof p !== 'string') return null;
  let s = norm(p);
  if (s.startsWith('file://')) s = decodeURIComponent(new URL(s).pathname);
  // на Windows путь /vfs/x мог стать D:/vfs/x после path.resolve
  s = s.replace(/^[A-Za-z]:(?=\/vfs\/|\/vfs$)/, '');
  if (s === '/vfs' || s.startsWith('/vfs/')) return npath.posix.normalize(s);
  return null;
}
function toReal(key) {
  for (const src of sources) if (key === src.to || key.startsWith(src.to + '/')) return { real: src.from + key.slice(src.to.length), src };
  if (key === '/vfs/media' || key.startsWith('/vfs/media/')) return { real: MAP.media + key.slice('/vfs/media'.length), src: null };
  if (key.startsWith('/vfs/pos-api/dist/') || key === '/vfs/pos-api/dist') return { real: MAP.dist + key.slice('/vfs/pos-api/dist'.length), src: null };
  // ключ вне vfs → несуществующий путь (ENOENT, как в виртуальной fs)
  return { real: `${MAP.missing}${key}`, src: null };
}
const tr = (p) => {
  const k = vfsKey(p);
  return k ? toReal(k).real : p;
};
function transformed(p, buf, enc) {
  const k = vfsKey(p);
  if (!k) return null;
  let out = Buffer.isBuffer(buf) ? buf : Buffer.from(buf);
  let changed = false;
  for (const t of transforms) {
    const r = t(k, out);
    if (r !== undefined && r !== out) {
      out = Buffer.from(r);
      changed = true;
    }
  }
  if (!changed) return null;
  return enc ? out.toString(enc) : out;
}
const encOf = (o) => (typeof o === 'string' ? o : o?.encoding ?? null);
/** Список каталога источника vfs: только файлы, которые попали бы в виртуальную fs (include), и подкаталоги. */
function filterList(p, list) {
  const k = vfsKey(p);
  if (!k) return list;
  const hit = sources.find((s) => k === s.to || k.startsWith(s.to + '/'));
  if (!hit) return list;
  const rel = k === hit.to ? '' : k.slice(hit.to.length + 1) + '/';
  const real = toReal(k).real;
  return list.filter((e) => {
    const name = typeof e === 'string' ? e : Buffer.isBuffer(e) ? e.toString() : e.name;
    let dir = false;
    try {
      dir = typeof e === 'object' && !Buffer.isBuffer(e) ? e.isDirectory() : nfs.statSync(`${real}/${name}`).isDirectory();
    } catch {
      dir = false;
    }
    return dir || hit.include.test(rel + name);
  });
}

const TWO_PATHS = new Set(['rename', 'renameSync', 'copyFile', 'copyFileSync', 'link', 'linkSync', 'symlink', 'symlinkSync', 'cp', 'cpSync']);
function wrapFns(target, kind) {
  const cache = new Map();
  return new Proxy(target, {
    get(t, key) {
      const v = t[key];
      if (typeof v !== 'function' || typeof key !== 'string' || !/^[a-z]/.test(key)) return v;
      if (cache.has(key)) return cache.get(key);
      let w;
      if (key === 'readFileSync') {
        w = function (p, o) {
          const r = v.call(t, tr(p), o);
          return transformed(p, Buffer.isBuffer(r) ? r : Buffer.from(r, encOf(o) ?? 'utf8'), encOf(o)) ?? r;
        };
      } else if (key === 'readFile' && kind === 'promises') {
        w = async function (p, o) {
          const r = await v.call(t, tr(p), o);
          return transformed(p, Buffer.isBuffer(r) ? r : Buffer.from(r, encOf(o) ?? 'utf8'), encOf(o)) ?? r;
        };
      } else if (key === 'readFile') {
        w = function (p, o, cb) {
          if (typeof o === 'function') (cb = o), (o = undefined);
          v.call(t, tr(p), o, (err, r) => (err ? cb(err) : cb(null, transformed(p, Buffer.isBuffer(r) ? r : Buffer.from(r, encOf(o) ?? 'utf8'), encOf(o)) ?? r)));
        };
      } else if (key === 'readdirSync') {
        w = function (p, o) {
          return filterList(p, v.call(t, tr(p), o));
        };
      } else if (key === 'readdir' && kind === 'promises') {
        w = async function (p, o) {
          return filterList(p, await v.call(t, tr(p), o));
        };
      } else if (key === 'readdir') {
        w = function (p, o, cb) {
          if (typeof o === 'function') (cb = o), (o = undefined);
          v.call(t, tr(p), o, (err, r) => (err ? cb(err) : cb(null, filterList(p, r))));
        };
      } else {
        w = function (...args) {
          if (args.length) args[0] = tr(args[0]);
          if (TWO_PATHS.has(key) && args.length > 1) args[1] = tr(args[1]);
          return v.apply(t, args);
        };
      }
      Object.assign(w, v);
      cache.set(key, w);
      return w;
    },
  });
}

const promises = wrapFns(nfs.promises, 'promises');
const fs = wrapFns(nfs, 'fs');
module.exports = new Proxy(fs, {
  get(t, key) {
    if (key === 'promises') return promises;
    return t[key];
  },
});

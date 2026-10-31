'use strict';
// Шим `path`: posix-реализация (по алгоритмам Node lib/path.js), win32 = posix; cwd = /vfs.
function normalizeString(path, allowAboveRoot) {
  let res = '';
  let lastSegmentLength = 0;
  let lastSlash = -1;
  let dots = 0;
  let code;
  for (let i = 0; i <= path.length; ++i) {
    if (i < path.length) code = path.charCodeAt(i);
    else if (code === 47) break;
    else code = 47;
    if (code === 47) {
      if (lastSlash === i - 1 || dots === 1) {
        // noop
      } else if (dots === 2) {
        if (res.length < 2 || lastSegmentLength !== 2 || res.charCodeAt(res.length - 1) !== 46 || res.charCodeAt(res.length - 2) !== 46) {
          if (res.length > 2) {
            const lastSlashIndex = res.lastIndexOf('/');
            if (lastSlashIndex === -1) {
              res = '';
              lastSegmentLength = 0;
            } else {
              res = res.slice(0, lastSlashIndex);
              lastSegmentLength = res.length - 1 - res.lastIndexOf('/');
            }
            lastSlash = i;
            dots = 0;
            continue;
          } else if (res.length !== 0) {
            res = '';
            lastSegmentLength = 0;
            lastSlash = i;
            dots = 0;
            continue;
          }
        }
        if (allowAboveRoot) {
          res += res.length > 0 ? '/..' : '..';
          lastSegmentLength = 2;
        }
      } else {
        if (res.length > 0) res += '/' + path.slice(lastSlash + 1, i);
        else res = path.slice(lastSlash + 1, i);
        lastSegmentLength = i - lastSlash - 1;
      }
      lastSlash = i;
      dots = 0;
    } else if (code === 46 && dots !== -1) {
      ++dots;
    } else {
      dots = -1;
    }
  }
  return res;
}
const toPosix = (p) => String(p).replace(/\\/g, '/');
const posix = {
  sep: '/',
  delimiter: ':',
  resolve(...args) {
    let resolvedPath = '';
    let resolvedAbsolute = false;
    for (let i = args.length - 1; i >= -1 && !resolvedAbsolute; i--) {
      const path = i >= 0 ? toPosix(args[i]) : '/vfs';
      if (path.length === 0) continue;
      resolvedPath = `${path}/${resolvedPath}`;
      resolvedAbsolute = path.charCodeAt(0) === 47;
    }
    resolvedPath = normalizeString(resolvedPath, !resolvedAbsolute);
    if (resolvedAbsolute) return `/${resolvedPath}`;
    return resolvedPath.length > 0 ? resolvedPath : '.';
  },
  normalize(path) {
    path = toPosix(path);
    if (path.length === 0) return '.';
    const isAbsolute = path.charCodeAt(0) === 47;
    const trailingSeparator = path.charCodeAt(path.length - 1) === 47;
    path = normalizeString(path, !isAbsolute);
    if (path.length === 0) {
      if (isAbsolute) return '/';
      return trailingSeparator ? './' : '.';
    }
    if (trailingSeparator) path += '/';
    return isAbsolute ? `/${path}` : path;
  },
  isAbsolute(path) {
    path = toPosix(path);
    return path.length > 0 && path.charCodeAt(0) === 47;
  },
  join(...args) {
    if (args.length === 0) return '.';
    const parts = args.map(toPosix).filter((a) => a.length > 0);
    if (parts.length === 0) return '.';
    return posix.normalize(parts.join('/'));
  },
  relative(from, to) {
    if (from === to) return '';
    from = posix.resolve(from);
    to = posix.resolve(to);
    if (from === to) return '';
    const f = from.split('/').filter(Boolean);
    const t = to.split('/').filter(Boolean);
    let i = 0;
    while (i < f.length && i < t.length && f[i] === t[i]) i++;
    return [...f.slice(i).map(() => '..'), ...t.slice(i)].join('/');
  },
  toNamespacedPath(p) {
    return p;
  },
  dirname(path) {
    path = toPosix(path);
    if (path.length === 0) return '.';
    const hasRoot = path.charCodeAt(0) === 47;
    let end = -1;
    let matchedSlash = true;
    for (let i = path.length - 1; i >= 1; --i) {
      if (path.charCodeAt(i) === 47) {
        if (!matchedSlash) {
          end = i;
          break;
        }
      } else {
        matchedSlash = false;
      }
    }
    if (end === -1) return hasRoot ? '/' : '.';
    if (hasRoot && end === 1) return '//';
    return path.slice(0, end);
  },
  basename(path, suffix) {
    path = toPosix(path);
    let end = path.length;
    while (end > 0 && path.charCodeAt(end - 1) === 47) end--;
    const trimmed = path.slice(0, end);
    let base = trimmed.slice(trimmed.lastIndexOf('/') + 1);
    if (suffix !== undefined && base.endsWith(suffix) && base !== suffix) base = base.slice(0, base.length - suffix.length);
    return base;
  },
  extname(path) {
    const base = posix.basename(path);
    const i = base.lastIndexOf('.');
    if (i <= 0) return '';
    return base.slice(i);
  },
  parse(path) {
    path = toPosix(path);
    const root = path.startsWith('/') ? '/' : '';
    const base = posix.basename(path);
    const ext = posix.extname(path);
    let dir = posix.dirname(path);
    if (dir === '.' && !path.includes('/')) dir = '';
    return { root, dir, base, ext, name: ext ? base.slice(0, base.length - ext.length) : base };
  },
  format(obj) {
    const dir = obj.dir || obj.root;
    const base = obj.base || `${obj.name || ''}${obj.ext || ''}`;
    if (!dir) return base;
    return dir === obj.root ? `${dir}${base}` : `${dir}/${base}`;
  },
  matchesGlob() {
    return false;
  },
};
posix.posix = posix;
posix.win32 = posix;
module.exports = posix;

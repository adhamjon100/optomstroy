// Копия PGlite 0.3.16 в site/backend/pglite/ (WP-B1). PGlite НЕ бандлится: файлы копируются как есть, и его
// собственный import.meta.url находит pglite.wasm, pglite.data и *.tar.gz расширений рядом с index.js.
// Состав — замыкание статических импортов от точек входа (index.js, contrib/{pgcrypto,pg_trgm,unaccent}.js,
// fs/opfs-ahp.js) плюс файлы, на которые они ссылаются через new URL(…), и LICENSE. fs/nodefs.js (только Node,
// динамический import) не копируется. Каждый файл сверяется с backend/pglite.lock.json (размер и sha256);
// `--update-lock` переписывает lock-файл по текущему источнику.
//
// Review fixes: из .js убирается завершающая строка `//# sourceMappingURL=…` (карт *.map на сайте нет: DevTools
// получал 404 и ссылку на несуществующий файл). Исходник по-прежнему сверяется с lock (files — sha оригинала), а
// опубликованная копия — с lock.shipped (sha после удаления строки); остальные файлы копируются байт в байт.
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, posix } from 'node:path';
import { BACKEND, OUT, PGLITE_DIR } from './paths.mjs';

const SOURCE_MAP_TRAILER = /\n?\/\/# sourceMappingURL=[^\n]*\s*$/;
/** Содержимое опубликованной копии: .js без завершающей строки sourceMappingURL, прочее — как есть. */
export function shippedContent(file, buf) {
  if (!file.endsWith('.js')) return buf;
  const s = buf.toString('utf8');
  if (!SOURCE_MAP_TRAILER.test(s)) return buf;
  return Buffer.from(`${s.replace(SOURCE_MAP_TRAILER, '')}\n`, 'utf8');
}

const LOCK = `${BACKEND}/pglite.lock.json`;
const ENTRIES = ['dist/index.js', 'dist/contrib/pgcrypto.js', 'dist/contrib/pg_trgm.js', 'dist/contrib/unaccent.js', 'dist/fs/opfs-ahp.js'];
// pglite.data загружается по имени через locateFile/fetch рядом с index.js — регулярным выражением не находится.
const EXTRA = ['dist/pglite.data', 'LICENSE'];

function closure() {
  const files = new Set();
  const dynamic = new Set();
  const queue = [...ENTRIES];
  while (queue.length) {
    const f = queue.shift();
    if (files.has(f)) continue;
    files.add(f);
    const src = readFileSync(`${PGLITE_DIR}/${f}`, 'utf8');
    const dir = posix.dirname(f);
    for (const m of src.matchAll(/from\s*"(\.{1,2}\/[^"]+)"/g)) queue.push(posix.normalize(posix.join(dir, m[1])));
    for (const m of src.matchAll(/new URL\("(\.{0,2}\/?[^"]+\.(?:wasm|data|tar\.gz))"/g)) files.add(posix.normalize(posix.join(dir, m[1])));
    for (const m of src.matchAll(/import\("(\.{1,2}\/[^"]+)"\)/g)) dynamic.add(posix.normalize(posix.join(dir, m[1])));
  }
  for (const e of EXTRA) files.add(e);
  return { files: [...files].sort(), dynamic: [...dynamic].filter((d) => !files.has(d)).sort() };
}

const sha = (buf) => createHash('sha256').update(buf).digest('hex');

export function copyPglite({ updateLock = false } = {}) {
  const pkg = JSON.parse(readFileSync(`${PGLITE_DIR}/package.json`, 'utf8'));
  const { files, dynamic } = closure();
  const current = {};
  const shipped = {};
  const content = {};
  for (const f of files) {
    const buf = readFileSync(`${PGLITE_DIR}/${f}`);
    current[f] = { bytes: buf.length, sha256: sha(buf) };
    const out = shippedContent(f, buf);
    content[f] = out;
    if (out !== buf) shipped[f] = { bytes: out.length, sha256: sha(out) };
  }
  let lock = existsSync(LOCK) ? JSON.parse(readFileSync(LOCK, 'utf8')) : null;
  if (updateLock || !lock) {
    lock = {
      $comment: 'PGlite для браузерного бэкенда веб-демо: версия и sha256 копируемых файлов (demo/web/backend/lib/pglite.mjs). Источник по умолчанию — копия в глобальном netlify-cli (PGLITE_DIR). Обновлять: node demo/web/backend/build-backend.mjs --update-lock.',
      package: pkg.name,
      version: pkg.version,
      license: pkg.license,
      licenseNote: 'Apache-2.0 или PostgreSQL License на выбор (README PGlite); изменения исходников Postgres — PostgreSQL License',
      files: current,
      notCopied: Object.fromEntries(dynamic.map((d) => [d, 'динамический import только для Node (не нужен в браузере)'])),
    };
  }
  // Опубликованные копии без строки sourceMappingURL: их sha — в lock.shipped (дописывается, если раздела ещё нет).
  if (updateLock || !lock.shipped) {
    lock.shippedComment = 'shipped — sha256 опубликованных копий .js без завершающей строки //# sourceMappingURL (review fixes); files — sha256 оригиналов пакета';
    lock.shipped = shipped;
    writeFileSync(LOCK, JSON.stringify(lock, null, 2) + '\n');
  }
  if (pkg.version !== lock.version) throw new Error(`PGlite: версия ${pkg.version} в ${PGLITE_DIR}, в lock — ${lock.version}`);
  const mismatch = [];
  for (const f of new Set([...Object.keys(lock.files), ...files])) {
    const a = lock.files[f];
    const b = current[f];
    if (!a || !b || a.sha256 !== b.sha256 || a.bytes !== b.bytes) mismatch.push(f);
  }
  if (mismatch.length) throw new Error(`PGlite: файлы не совпадают с pglite.lock.json: ${mismatch.join(', ')}`);
  const shippedMismatch = [];
  for (const f of new Set([...Object.keys(lock.shipped ?? {}), ...Object.keys(shipped)])) {
    const a = lock.shipped?.[f];
    const b = shipped[f];
    if (!a || !b || a.sha256 !== b.sha256 || a.bytes !== b.bytes) shippedMismatch.push(f);
  }
  if (shippedMismatch.length) throw new Error(`PGlite: опубликованные копии не совпадают с pglite.lock.json shipped: ${shippedMismatch.join(', ')}`);
  const dst = `${OUT}/pglite`;
  if (existsSync(dst)) rmSync(dst, { recursive: true, force: true });
  let bytes = 0;
  for (const f of files) {
    const to = `${dst}/${f.replace(/^dist\//, '')}`;
    mkdirSync(dirname(to), { recursive: true });
    writeFileSync(to, content[f]);
    bytes += content[f].length;
  }
  // Проверка копии: каждый относительный импорт внутри pglite/ указывает на скопированный файл.
  const broken = [];
  for (const f of files.filter((x) => x.endsWith('.js'))) {
    const src = readFileSync(`${PGLITE_DIR}/${f}`, 'utf8');
    const dir = posix.dirname(f.replace(/^dist\//, ''));
    for (const m of src.matchAll(/from\s*"(\.{1,2}\/[^"]+)"/g)) {
      const t = posix.normalize(posix.join(dir, m[1]));
      if (!existsSync(`${dst}/${t}`)) broken.push(`${f} → ${t}`);
    }
  }
  if (broken.length) throw new Error(`PGlite: в копии нет файлов: ${broken.join(', ')}`);
  return { version: pkg.version, files: files.length, bytes, notCopied: dynamic, lockUpdated: updateLock, sourceMapTrailersRemoved: Object.keys(shipped).length };
}

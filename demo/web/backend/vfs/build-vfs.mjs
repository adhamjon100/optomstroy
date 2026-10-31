// Генератор виртуальной fs браузерного бэкенда (WP-B1). Собирает файлы, которые pos-api читает с диска во время
// работы, под ключами /vfs/<путь как в репозитории>:
//   pos-api/migrations, pos-api/db/migrations-dev, pos-api/seeds   — мигратор и сид (db/migrator.js, migrate.js)
//   contracts/onec/fixtures                                        — FakeOnecGateway / PosFakeOnec (фикстуры 1С)
//   pos-api/assets/templates/pdf, pos-api/assets/fonts             — печатные формы (orders/documents)
// Текст и мелкие файлы встраиваются в модуль .build/gen/vfs-data.cjs (подключается как `pos-vfs-data`), крупные
// двоичные (шрифты Inter, ~0,65 МБ) копируются в site/backend/vfs/… и подгружаются при старте воркера
// (shims/node-fs.cjs `__vfs.preloadExternal`) — так backend.js меньше и шрифты кэшируются отдельно.
//
// Точка расширения для WP-B3/WP-B4: backend/vfs/transforms.mjs (если есть) экспортирует
// `transforms: [(key, buf) => buf | undefined]` — например, водяной знак в шаблонах PDF (§3.7 плана).
//
//   node demo/web/backend/vfs/build-vfs.mjs            — только vfs (для отладки)
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { pathToFileURL } from 'node:url';
import { API, BACKEND, GEN, OUT, ROOT, norm } from '../lib/paths.mjs';

export const VFS_SOURCES = [
  { from: `${API}/migrations`, to: '/vfs/pos-api/migrations', include: /\.sql$/i },
  { from: `${API}/db/migrations-dev`, to: '/vfs/pos-api/db/migrations-dev', include: /\.sql$/i },
  { from: `${API}/seeds`, to: '/vfs/pos-api/seeds', include: /\.(sql|json)$/i },
  { from: `${ROOT}/contracts/onec/fixtures`, to: '/vfs/contracts/onec/fixtures', include: /\.json$/i },
  { from: `${API}/assets/templates/pdf`, to: '/vfs/pos-api/assets/templates/pdf', include: /\.json$/i },
  { from: `${API}/assets/fonts`, to: '/vfs/pos-api/assets/fonts', include: /\.(ttf|otf)$/i },
];
const TEXT = /\.(sql|json|md|txt|ya?ml|csv|xml)$/i;
/** Двоичные файлы больше этого размера — внешние (site/backend/vfs/…). */
export const EXTERNAL_MIN_BYTES = 32 * 1024;

function walk(dir) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else out.push(p);
  }
  return out.sort();
}

export async function buildVfs({ transforms } = {}) {
  if (!transforms) {
    const tf = `${BACKEND}/vfs/transforms.mjs`;
    transforms = existsSync(tf) ? ((await import(pathToFileURL(tf).href)).transforms ?? []) : [];
  }
  const files = {};
  const external = {};
  const report = { embeddedFiles: 0, embeddedBytes: 0, externalFiles: 0, externalBytes: 0, transformed: [], bySource: {} };
  const extDir = `${OUT}/vfs`;
  if (existsSync(extDir)) rmSync(extDir, { recursive: true, force: true });
  for (const src of VFS_SOURCES) {
    if (!existsSync(src.from)) throw new Error(`vfs: нет каталога ${src.from}`);
    let n = 0;
    for (const f of walk(src.from)) {
      const rel = norm(relative(src.from, f));
      if (!src.include.test(rel)) continue;
      const key = `${src.to}/${rel}`;
      let buf = readFileSync(f);
      for (const t of transforms) {
        const r = await t(key, buf);
        if (r !== undefined && r !== buf) {
          buf = Buffer.from(r);
          report.transformed.push(key);
        }
      }
      n++;
      if (!TEXT.test(f) && buf.length >= EXTERNAL_MIN_BYTES) {
        const url = `vfs/${key.slice('/vfs/'.length)}`;
        const dst = `${OUT}/${url}`;
        mkdirSync(dirname(dst), { recursive: true });
        writeFileSync(dst, buf);
        external[key] = { url, bytes: buf.length, sha256: createHash('sha256').update(buf).digest('hex') };
        report.externalFiles++;
        report.externalBytes += buf.length;
      } else {
        files[key] = TEXT.test(f) ? buf.toString('utf8') : { b64: buf.toString('base64') };
        report.embeddedFiles++;
        report.embeddedBytes += buf.length;
      }
    }
    report.bySource[src.to] = n;
  }
  mkdirSync(GEN, { recursive: true });
  const body =
    `'use strict';\n// Сгенерировано demo/web/backend/vfs/build-vfs.mjs — не править вручную.\n` +
    `// Встроено: ${report.embeddedFiles} файлов; внешние (site/backend/vfs): ${report.externalFiles}.\n` +
    `module.exports = { files: ${JSON.stringify(files)}, external: ${JSON.stringify(external)} };\n`;
  writeFileSync(`${GEN}/vfs-data.cjs`, body);
  report.moduleBytes = Buffer.byteLength(body);
  report.external = external;
  return report;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const r = await buildVfs();
  console.log(JSON.stringify({ ...r, external: Object.keys(r.external) }, null, 1));
}

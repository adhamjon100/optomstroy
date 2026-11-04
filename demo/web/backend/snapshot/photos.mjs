// Фото демо-каталога для снимка веб-демо (WP-B4; WP-DATA-WEB 2026-10-31, ADR-114). Только Node и только при сборке.
// Каталог по макету — demo/catalog/design-catalog.json (pos-api/scripts/design_catalog.ts), фото — PNG макета
// demo/catalog/photos/*.png как есть (без перекодирования и увеличения; WebP thumb/card/full делает processImage
// pos-api). Байты исходников фиксированы, поэтому sha256, адреса /images/{sha}/… и снимок не меняются от пересборки.
// Прежние синтетические JPEG-заглушки (каталог SyntheticCatalog seed 1, 500 SKU) больше не строятся.
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';
import { NM, ROOT } from '../lib/paths.mjs';

/** Каталог спецификации и фото (в git). */
export const CATALOG_DIR = `${ROOT}/demo/catalog`;
export const CATALOG_SPEC = `${CATALOG_DIR}/design-catalog.json`;

const sha256 = (b) => createHash('sha256').update(b).digest('hex');

/** Спецификация каталога: { spec, sha256 (байты файла), bytes }. */
export function readCatalogSpec(file = CATALOG_SPEC) {
  const buf = readFileSync(file);
  return { spec: JSON.parse(buf.toString('utf8')), sha256: sha256(buf), bytes: buf.length };
}

/**
 * Файлы фото спецификации: существуют, sha256 = spec.photos[].sha256. → { files: Map(name → {path, sha256, bytes}),
 * problems }.
 */
export function checkCatalogPhotos(spec, dir = CATALOG_DIR) {
  const files = new Map();
  const problems = [];
  for (const p of spec.photos ?? []) {
    const path = `${dir}/${p.file}`;
    if (!existsSync(path)) {
      problems.push(`фото ${p.name}: нет файла demo/catalog/${p.file}`);
      continue;
    }
    const buf = readFileSync(path);
    const s = sha256(buf);
    if (s !== p.sha256) problems.push(`фото ${p.name}: sha256 файла ${s.slice(0, 12)}… ≠ спецификации ${String(p.sha256).slice(0, 12)}…`);
    files.set(p.name, { path, sha256: s, bytes: buf.length });
  }
  return { files, problems };
}

/** Отсортированный список «имя sha256» фото по файлам (ключ эпохи, lib/epoch.mjs). */
export function catalogPhotoShas(spec, dir = CATALOG_DIR) {
  return (spec.photos ?? []).map((p) => `${p.name} ${existsSync(`${dir}/${p.file}`) ? sha256(readFileSync(`${dir}/${p.file}`)) : 'missing'}`).sort();
}

/** Версия sharp построителя (sharp грузится только здесь — модуль читает и lib/epoch.mjs). */
export function sharpVersion() {
  const require = createRequire(`${NM}/`);
  return require('sharp').versions?.sharp ?? null;
}

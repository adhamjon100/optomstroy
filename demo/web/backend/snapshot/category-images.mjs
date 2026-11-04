// Картинки категорий демо-каталога (WP-DATA-WEB 2026-10-31, ADR-114; входит в построитель снимка builder-entry.mjs,
// Node: sharp настоящий). В pos-api нет шага, который пишет categories.image_id (ImageDirectoryImporter привязывает
// фото только к товарам и вариантам), а API уже отдаёт её как Category.imageUrl — поэтому здесь: PNG макета →
// processImage pos-api (WebP thumb 160 / card 400 / full 1200, без увеличения) → ImageStore (MEDIA_DIR/images/{sha}/…)
// → registerCategoryImage (pos-api/scripts/design_catalog.ts: product_images с category_id, source_ref
// import:category:<ref>/<файл>, ready, основная; categories.image_id). Порядок — спецификации, внутри
// детерминированной сессии построителя: id и время строк от пересборки не меняются.
import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';
import { processImage } from '@pos-api-dist/sync/images/image-processor.js';
import { ImageStore } from '@pos-api-dist/sync/images/image-store.js';
import { registerCategoryImage } from '@pos-api-scripts/design_catalog.ts';

/**
 * items: [{ onecRef, path (PNG), owner (путь категории) }], mediaDir — корень MEDIA_DIR (файлы в mediaDir/images).
 * → { ms, registered, missing: [owner] }.
 */
export async function importCategoryImages(ctx, { items, mediaDir }) {
  const t = performance.now();
  const store = new ImageStore(mediaDir);
  const missing = [];
  let registered = 0;
  for (const it of items) {
    const bytes = await readFile(it.path);
    const img = await processImage(bytes);
    if (!(await store.has(img.sha256))) await store.write(img.sha256, img.renders);
    const r = await registerCategoryImage(ctx.pool, {
      categoryRef: it.onecRef,
      fileName: basename(it.path),
      image: { sha256: img.sha256, originalMime: img.originalMime, originalBytes: img.originalBytes, width: img.width, height: img.height, sizes: img.sizes },
    });
    if (r) registered++;
    else missing.push(it.owner);
  }
  return { ms: Math.round(performance.now() - t), registered, missing };
}

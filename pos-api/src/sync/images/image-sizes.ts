/**
 * Размеры хранения фото (ядро D-30, §17.2; 05 SYNC-035; 07 §5.23): контент-адресуемые файлы
 * `images/{sha256}/{size}.webp`, длинная сторона ≤ `px` (без увеличения), формат WebP.
 * URL канона — `/images/{sha}/{size}` без расширения (08 §4.4.7); Caddy подставляет `.webp` (16 §4.5).
 */
export const IMAGE_SIZES = [
  { name: 'thumb', px: 160, quality: 78 },
  { name: 'card', px: 400, quality: 80 },
  { name: 'full', px: 1200, quality: 82 },
] as const;

export type ImageSizeName = (typeof IMAGE_SIZES)[number]['name'];
export const IMAGE_SIZE_NAMES: readonly ImageSizeName[] = IMAGE_SIZES.map((s) => s.name);

/** Метаданные одного размера (`product_images.sizes`, 07 §5.23: `{"thumb": {"w":160,"h":…,"bytes":…}, …}`). */
export interface ImageSizeMeta {
  readonly w: number;
  readonly h: number;
  readonly bytes: number;
}
export type ImageSizesMeta = Readonly<Record<ImageSizeName, ImageSizeMeta>>;

/** SHA-256 в hex (ключ хранилища и `Image.sha256` API: `^[0-9a-f]{64}$`). */
export const SHA256_HEX = /^[0-9a-f]{64}$/;

export function isSha256Hex(v: string): boolean {
  return SHA256_HEX.test(v);
}

import { createHash } from 'node:crypto';
import sharp from 'sharp';
import { IMAGE_SIZES, type ImageSizeName, type ImageSizesMeta } from './image-sizes.js';

/**
 * Форматы исходников — allowlist 11 SEC-101: JPEG/PNG/WebP/GIF (формат определяется по содержимому, не по
 * расширению; TIFF/HEIF и прочее — отказ, ревью E-trace-4).
 */
export const ACCEPTED_SOURCE_FORMATS: ReadonlySet<string> = new Set(['jpeg', 'png', 'webp', 'gif']);

/** Размер исходника ≤ 10 МБ (11 SEC-101; AC-SEC-101: PNG 50 МБ отклонён). */
export const MAX_SOURCE_BYTES = 10 * 1024 * 1024;

/** Размеры исходника по каждой стороне ≤ 8000 px (11 SEC-101). */
export const MAX_SOURCE_SIDE_PX = 8000;

/** Предел пикселей исходника (защита от «декомпрессионной бомбы», SEC-101): 8000 × 8000 = 64 Мп. */
export const DEFAULT_LIMIT_INPUT_PIXELS = MAX_SOURCE_SIDE_PX * MAX_SOURCE_SIDE_PX;

/** Файл не декодируется как изображение (битый, усечённый, не картинка, неподдерживаемый формат, слишком большой). */
export class ImageDecodeError extends Error {
  override readonly name = 'ImageDecodeError';
  constructor(
    readonly reason: 'unsupported_format' | 'corrupt' | 'too_large' | 'empty',
    message: string,
  ) {
    super(message);
  }
}

export interface RenderedSize {
  readonly name: ImageSizeName;
  readonly data: Buffer;
  readonly w: number;
  readonly h: number;
}

export interface ProcessedImage {
  /** SHA-256 исходных байтов (hex) — ключ хранилища (D-30). */
  readonly sha256: string;
  readonly originalMime: string;
  readonly originalBytes: number;
  /** Размеры исходника с учётом EXIF-ориентации. */
  readonly width: number;
  readonly height: number;
  readonly renders: readonly RenderedSize[];
  readonly sizes: ImageSizesMeta;
}

export function sha256Hex(data: Uint8Array): string {
  return createHash('sha256').update(data).digest('hex');
}

const MIME: Readonly<Record<string, string>> = {
  jpeg: 'image/jpeg',
  png: 'image/png',
  webp: 'image/webp',
  gif: 'image/gif',
};

export interface ProcessOptions {
  readonly limitInputPixels?: number;
  /** Предел размера исходника, байт (по умолчанию `MAX_SOURCE_BYTES`, 10 МБ). */
  readonly maxSourceBytes?: number;
}

/**
 * Исходник → три WebP-размера `thumb 160` / `card 400` / `full 1200` (D-30): ориентация по EXIF, вписывание
 * без увеличения, метаданные (EXIF/GPS) не переносятся. Ошибка декодирования → `ImageDecodeError`
 * (`failOn: 'error'` — усечённый/повреждённый файл не превращается в «полкартинки»).
 */
export async function processImage(data: Uint8Array, opts: ProcessOptions = {}): Promise<ProcessedImage> {
  if (data.byteLength === 0) throw new ImageDecodeError('empty', 'пустой файл');
  const maxBytes = opts.maxSourceBytes ?? MAX_SOURCE_BYTES;
  if (data.byteLength > maxBytes) {
    throw new ImageDecodeError('too_large', `файл фото больше ${maxBytes} байт (SEC-101)`);
  }
  const buf = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  const sha = sha256Hex(buf);
  const limitInputPixels = opts.limitInputPixels ?? DEFAULT_LIMIT_INPUT_PIXELS;
  let meta: sharp.Metadata;
  try {
    meta = await sharp(buf, { failOn: 'error', limitInputPixels }).metadata();
  } catch (e) {
    throw decodeError(e);
  }
  const format = meta.format ?? '';
  if (!ACCEPTED_SOURCE_FORMATS.has(format)) {
    throw new ImageDecodeError('unsupported_format', `формат не поддерживается: ${format || 'неизвестен'}`);
  }
  if (!meta.width || !meta.height) throw new ImageDecodeError('corrupt', 'нет размеров изображения');
  if (meta.width > MAX_SOURCE_SIDE_PX || meta.height > MAX_SOURCE_SIDE_PX) {
    throw new ImageDecodeError(
      'too_large',
      `размеры ${meta.width}×${meta.height} больше ${MAX_SOURCE_SIDE_PX}×${MAX_SOURCE_SIDE_PX} px (SEC-101)`,
    );
  }
  const rotated = (meta.orientation ?? 1) >= 5;
  const width = rotated ? meta.height : meta.width;
  const height = rotated ? meta.width : meta.height;

  const renders: RenderedSize[] = [];
  try {
    // Один декодер на исходник: размеры — клоны конвейера (sharp читает вход один раз).
    const base = sharp(buf, { failOn: 'error', limitInputPixels, animated: false }).rotate();
    for (const s of IMAGE_SIZES) {
      const { data: out, info } = await base
        .clone()
        .resize({ width: s.px, height: s.px, fit: 'inside', withoutEnlargement: true })
        .webp({ quality: s.quality, effort: 4 })
        .toBuffer({ resolveWithObject: true });
      renders.push({ name: s.name, data: out, w: info.width, h: info.height });
    }
  } catch (e) {
    throw decodeError(e);
  }
  const sizes = Object.fromEntries(
    renders.map((r) => [r.name, { w: r.w, h: r.h, bytes: r.data.byteLength }]),
  ) as Record<ImageSizeName, { w: number; h: number; bytes: number }>;
  return {
    sha256: sha,
    originalMime: MIME[format] ?? 'application/octet-stream',
    originalBytes: buf.byteLength,
    width,
    height,
    renders,
    sizes,
  };
}

function decodeError(e: unknown): ImageDecodeError {
  if (e instanceof ImageDecodeError) return e;
  const msg = e instanceof Error ? e.message : String(e);
  if (/pixel limit/i.test(msg))
    return new ImageDecodeError('too_large', 'изображение больше допустимого предела пикселей');
  if (/unsupported image format/i.test(msg)) return new ImageDecodeError('unsupported_format', 'формат не распознан');
  // Текст libvips может содержать путь к временным файлам — в журнал идёт только первая строка, до 200 символов.
  return new ImageDecodeError('corrupt', `файл повреждён: ${msg.split('\n')[0].slice(0, 200)}`);
}

import { createHash, randomUUID } from 'node:crypto';
import { mkdirSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { OnecError } from '../../../src/integrations/onec/onec-error.js';
import type { OnecCallOptions, OnecImage, OnecMode, OnecResult } from '../../../src/integrations/onec/onec-gateway.js';

/**
 * Синтетические изображения и тестовый шлюз `getImage` (RM-E-003). **Тестовые данные**: картинки генерирует sharp,
 * реальных фото товаров нет; это не интеграция с 1С (HS расширения не получено).
 */

const TMP_ROOT = fileURLToPath(new URL('../../../../.tmp/', import.meta.url));

/** Одноразовый каталог `MEDIA_DIR` для теста (в `D:/optomstroy/.tmp`, удаляется `cleanup`). */
export function tempMediaDir(prefix = 'images'): { dir: string; cleanup: () => void } {
  const dir = path.join(TMP_ROOT, `${prefix}-${randomUUID()}`);
  mkdirSync(dir, { recursive: true });
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

/** JPEG `w×h` сплошного цвета с диагональной полосой (разные `seed` → разные байты). */
export async function syntheticJpeg(w: number, h: number, seed: number): Promise<Buffer> {
  const r = (seed * 67) % 256;
  const g = (seed * 131) % 256;
  const b = (seed * 29) % 256;
  const stripe = Buffer.from(
    `<svg width="${w}" height="${h}"><rect x="0" y="${Math.floor(h / 3)}" width="${w}" height="${Math.max(
      1,
      Math.floor(h / 6),
    )}" fill="rgb(${255 - r},${255 - g},${255 - b})"/></svg>`,
  );
  return sharp({ create: { width: w, height: h, channels: 3, background: { r, g, b } } })
    .composite([{ input: stripe }])
    .jpeg({ quality: 85 })
    .toBuffer();
}

export async function syntheticPng(w: number, h: number, seed: number): Promise<Buffer> {
  return sharp({ create: { width: w, height: h, channels: 4, background: { r: seed % 256, g: 40, b: 90, alpha: 1 } } })
    .png()
    .toBuffer();
}

export function sha256(b: Uint8Array): string {
  return createHash('sha256').update(b).digest('hex');
}

/** Байты, которые не являются изображением. */
export function garbageBytes(n = 4096, seed = 7): Buffer {
  const out = Buffer.alloc(n);
  let x = seed;
  for (let i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = x & 0xff;
  }
  return out;
}

interface ServedFile {
  data: Buffer;
  /** `undefined` — `"<sha256>"`; `null` — без ETag; строка — как есть. */
  etag?: string | null;
  /** Ошибка HTTP вместо файла (например 503). */
  failStatus?: number;
}

/**
 * Шлюз 1С для `getImage` по контракту HS (05 §6.3): `ETag = "<sha256>"`, `If-None-Match` → 304 без тела,
 * нет файла → 404 `POS_E_NOT_FOUND`. Журнал вызовов — для проверки «повтор без перекачки».
 */
export class TestImageGateway {
  readonly mode: OnecMode = 'extension';
  readonly files = new Map<string, ServedFile>();
  readonly calls: { ref: string; ifNoneMatch?: string }[] = [];

  serve(ref: string, data: Buffer, extra: Omit<ServedFile, 'data'> = {}): void {
    this.files.set(ref, { data, ...extra });
  }

  etagOf(ref: string): string | null {
    const f = this.files.get(ref);
    if (!f) return null;
    return f.etag === undefined ? `"${sha256(f.data)}"` : f.etag;
  }

  getImage(ref: string, ifNoneMatch?: string, _opts?: OnecCallOptions): Promise<OnecResult<OnecImage | null>> {
    this.calls.push({ ref, ...(ifNoneMatch ? { ifNoneMatch } : {}) });
    const f = this.files.get(ref);
    if (!f) return Promise.reject(new OnecError('getImage', 404, 'POS_E_NOT_FOUND', 'Файл не найден'));
    if (f.failStatus) return Promise.reject(new OnecError('getImage', f.failStatus, 'POS_E_INTERNAL', 'сбой'));
    const etag = this.etagOf(ref);
    if (ifNoneMatch && etag && ifNoneMatch === etag) return Promise.resolve({ status: 304, body: null });
    return Promise.resolve({
      status: 200,
      body: { contentType: 'image/jpeg', etag, data: new Uint8Array(f.data) },
    });
  }
}

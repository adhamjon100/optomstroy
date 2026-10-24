import { randomUUID } from 'node:crypto';
import { mkdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { RenderedSize } from './image-processor.js';
import { IMAGE_SIZE_NAMES, type ImageSizeName, isSha256Hex } from './image-sizes.js';

/**
 * Контент-адресуемое хранилище фото (D-30; 07 §5.23; 16 §4.2 том `media`): `${MEDIA_DIR}/images/{sha256}/{size}.webp`.
 * Файл по ключу никогда не перезаписывается другим содержимым (ключ = хэш исходника), поэтому Caddy отдаёт его с
 * `Cache-Control: immutable`. Запись атомарна: временный файл в том же каталоге → `rename` (читатель видит либо
 * старый полный файл, либо новый полный, но не частичный).
 */
export class ImageStore {
  readonly root: string;
  private readonly locks = new Map<string, Promise<void>>();

  constructor(mediaDir: string) {
    this.root = path.resolve(mediaDir, 'images');
  }

  /** `images/{sha}` — значение `product_images.storage_key` (07 §5.23). */
  static storageKey(sha: string): string {
    return `images/${sha}`;
  }

  dirOf(sha: string): string {
    if (!isSha256Hex(sha)) throw new Error('ImageStore: ключ — только sha256 hex');
    return path.join(this.root, sha);
  }

  fileOf(sha: string, size: ImageSizeName): string {
    return path.join(this.dirOf(sha), `${size}.webp`);
  }

  /** Запись одного ключа в процессе — последовательно (дедупликация параллельных строк с одинаковым файлом). */
  async withKey<T>(sha: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.locks.get(sha) ?? Promise.resolve();
    let release!: () => void;
    const mine = new Promise<void>((r) => (release = r));
    const chain = prev.then(() => mine);
    this.locks.set(sha, chain);
    await prev;
    try {
      return await fn();
    } finally {
      release();
      if (this.locks.get(sha) === chain) this.locks.delete(sha);
    }
  }

  /** Пометка «кандидат на удаление» регламентной очистки `images.gc` (EQ-IMG-10; `ImagesGcService`). */
  static readonly GC_MARKER = '.gc-mark';

  markerOf(sha: string): string {
    return path.join(this.dirOf(sha), ImageStore.GC_MARKER);
  }

  /**
   * Все три размера уже на диске (дедупликация по sha256: файл с существующим хэшем не пишется повторно).
   * Каталог, помеченный `images.gc`, считается отсутствующим: загрузка не ссылается на файлы, которые очистка
   * может удалить, а перезаписывает их (`write` снимает пометку) — безопасность к гонке «очистка ↔ загрузка».
   */
  async has(sha: string): Promise<boolean> {
    if (await exists(this.markerOf(sha))) return false;
    for (const s of IMAGE_SIZE_NAMES) {
      try {
        const st = await stat(this.fileOf(sha, s));
        if (!st.isFile() || st.size === 0) return false;
      } catch {
        return false;
      }
    }
    return true;
  }

  async write(sha: string, renders: readonly RenderedSize[]): Promise<void> {
    const dir = this.dirOf(sha);
    await mkdir(dir, { recursive: true });
    // Снять пометку `images.gc` до записи: очистка не удаляет каталог без пометки и с файлами новее пометки.
    await rm(this.markerOf(sha), { force: true });
    for (const r of renders) {
      const target = this.fileOf(sha, r.name);
      const tmp = path.join(dir, `.${r.name}.${randomUUID()}.tmp`);
      try {
        await writeFile(tmp, r.data, { flag: 'wx' });
        await rename(tmp, target);
      } catch (e) {
        await rm(tmp, { force: true }).catch(() => undefined);
        // Параллельная запись того же ключа (другой процесс/реплика worker): содержимое по ключу sha256 одинаково,
        // на Windows `rename` поверх открытого файла даёт EPERM/EBUSY — готовый файл считается результатом.
        const code = (e as NodeJS.ErrnoException).code;
        if ((code === 'EPERM' || code === 'EBUSY' || code === 'EACCES') && (await nonEmptyFile(target))) continue;
        throw e;
      }
    }
  }
}

async function nonEmptyFile(p: string): Promise<boolean> {
  try {
    const st = await stat(p);
    return st.isFile() && st.size > 0;
  } catch {
    return false;
  }
}

async function exists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

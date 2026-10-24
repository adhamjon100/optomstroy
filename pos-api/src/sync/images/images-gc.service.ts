import { randomUUID } from 'node:crypto';
import { mkdir, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type pg from 'pg';
import type { Logger } from 'pino';
import { isSha256Hex } from './image-sizes.js';
import { ImageStore } from './image-store.js';

const DAY_MS = 86_400_000;
const HOUR_MS = 3_600_000;

export interface ImagesGcOptions {
  /** Файлы снятых фото хранятся после `deleted_at` последней строки (07 §5.23, 05 ONEC-006: 30 дней). */
  readonly retentionDays?: number;
  /**
   * Каталог sha256 без единой строки `product_images` (сбой между записью файла и `markReady`, удалённые строки)
   * — кандидат, если самый новый файл старше этого порога (по умолчанию 24 ч; загрузка пишет файлы до строки).
   */
  readonly orphanGraceMs?: number;
  /** Пометка живёт не меньше этого срока до удаления (следующий цикл; по умолчанию 1 ч). */
  readonly markMinAgeMs?: number;
  readonly now?: () => Date;
}

export interface ImagesGcResult {
  /** Каталогов `images/{sha256}` просмотрено. */
  scanned: number;
  /** Помечено кандидатами в этом цикле (удаление — в следующем). */
  marked: number;
  /** Пометка снята: фото снова используется или файлы перезаписаны после пометки. */
  unmarked: number;
  /** Каталогов удалено. */
  deleted: number;
  /** Оставлено (используется, срок не вышел, пометка свежая). */
  kept: number;
  errors: number;
}

interface ShaUsage {
  live: boolean;
  rows: number;
  lastDeleted: Date | null;
}

/**
 * Регламентная очистка осиротевших файлов фото — job `images.gc` (EQ-IMG-10; 07 §5.23, 13 RM-E-003; 05 ONEC-006).
 * Удаляется каталог `${MEDIA_DIR}/images/{sha256}`, если на sha256 нет живых строк `product_images`
 * (`deleted_at IS NULL` — по `checksum_sha256` или `storage_key`) и (а) все строки сняты раньше `retentionDays`,
 * либо (б) строк нет вовсе, а файлы старше `orphanGraceMs`.
 *
 * Безопасность к гонке с загрузкой (`ImageSyncService`, `ImageDirectoryImporter` пишут файлы до строки и
 * дедуплицируют по `ImageStore.has`): двухфазно. Цикл N кладёт в каталог пометку `.gc-mark`; помеченный каталог
 * `ImageStore.has` считает отсутствующим (загрузка перезапишет файлы и снимет пометку). Цикл N+1 (не раньше
 * `markMinAgeMs`) повторно проверяет условия, пометку и отсутствие файлов новее неё; каталог атомарно
 * переносится в `images/.gc-trash/`, условия проверяются ещё раз — и только затем удаляется (иначе возвращается).
 */
export class ImagesGcService {
  private readonly retentionMs: number;
  private readonly orphanGraceMs: number;
  private readonly markMinAgeMs: number;
  private readonly now: () => Date;

  constructor(
    private readonly pool: Pick<pg.Pool, 'query'>,
    private readonly store: ImageStore,
    private readonly log: Logger,
    options: ImagesGcOptions = {},
  ) {
    this.retentionMs = (options.retentionDays ?? 30) * DAY_MS;
    this.orphanGraceMs = options.orphanGraceMs ?? 24 * HOUR_MS;
    this.markMinAgeMs = options.markMinAgeMs ?? HOUR_MS;
    this.now = options.now ?? (() => new Date());
  }

  get trashDir(): string {
    return path.join(this.store.root, '.gc-trash');
  }

  async run(): Promise<ImagesGcResult> {
    const res: ImagesGcResult = { scanned: 0, marked: 0, unmarked: 0, deleted: 0, kept: 0, errors: 0 };
    // Остатки прерванного цикла (процесс упал между переносом и удалением) — уже проверенный мусор.
    await rm(this.trashDir, { recursive: true, force: true }).catch(() => undefined);
    let names: string[];
    try {
      names = (await readdir(this.store.root, { withFileTypes: true }))
        .filter((d) => d.isDirectory() && isSha256Hex(d.name))
        .map((d) => d.name);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === 'ENOENT') return res;
      throw e;
    }
    for (let i = 0; i < names.length; i += 1000) {
      const chunk = names.slice(i, i + 1000);
      const usage = await this.usage(chunk);
      for (const sha of chunk) {
        res.scanned += 1;
        try {
          await this.one(sha, usage.get(sha) ?? { live: false, rows: 0, lastDeleted: null }, res);
        } catch (e) {
          res.errors += 1;
          this.log.warn({ err: e, sha }, 'images.gc.item_failed');
        }
      }
    }
    this.log.info(res, 'images.gc.done');
    return res;
  }

  private async one(sha: string, u: ShaUsage, res: ImagesGcResult): Promise<void> {
    const dir = this.store.dirOf(sha);
    const now = this.now().getTime();
    const files = await this.newestFile(dir);
    const marker = await mtime(this.store.markerOf(sha));
    if (!this.eligible(u, files, now)) {
      if (marker !== null) {
        await rm(this.store.markerOf(sha), { force: true });
        res.unmarked += 1;
      }
      res.kept += 1;
      return;
    }
    if (marker === null) {
      await writeFile(this.store.markerOf(sha), new Date(now).toISOString());
      res.marked += 1;
      return;
    }
    if (files !== null && files > marker) {
      // Файлы перезаписаны после пометки — каталог снова в работе.
      await rm(this.store.markerOf(sha), { force: true });
      res.unmarked += 1;
      res.kept += 1;
      return;
    }
    if (now - marker < this.markMinAgeMs) {
      res.kept += 1;
      return;
    }
    await mkdir(this.trashDir, { recursive: true });
    const trashed = path.join(this.trashDir, `${sha}.${randomUUID()}`);
    await rename(dir, trashed);
    // Повторная проверка после атомарного переноса: строка/запись могли появиться между проверкой и переносом.
    const again = (await this.usage([sha])).get(sha) ?? { live: false, rows: 0, lastDeleted: null };
    const stillMarked = (await mtime(path.join(trashed, ImageStore.GC_MARKER))) !== null;
    const newest = await this.newestFile(trashed);
    if (again.live || !stillMarked || (newest !== null && newest > marker)) {
      await rename(trashed, dir).catch(async (e: unknown) => {
        // Каталог уже создан заново загрузкой — её файлы актуальны, перенесённую копию можно удалить.
        this.log.warn({ err: e, sha }, 'images.gc.restore_skipped');
        await rm(trashed, { recursive: true, force: true });
      });
      await rm(this.store.markerOf(sha), { force: true }).catch(() => undefined);
      res.unmarked += 1;
      res.kept += 1;
      return;
    }
    await rm(trashed, { recursive: true, force: true });
    res.deleted += 1;
    this.log.info({ sha, rows: u.rows }, 'images.gc.deleted');
  }

  private eligible(u: ShaUsage, newest: number | null, now: number): boolean {
    if (u.live) return false;
    if (u.rows > 0) return u.lastDeleted !== null && now - u.lastDeleted.getTime() >= this.retentionMs;
    return newest === null || now - newest >= this.orphanGraceMs;
  }

  /** Использование sha256 строками `product_images` (по `checksum_sha256` и по `storage_key`). */
  private async usage(shas: readonly string[]): Promise<Map<string, ShaUsage>> {
    const out = new Map<string, ShaUsage>();
    const r = await this.pool.query<{ sha: string; live: boolean; n: string; last: Date | null }>(
      `SELECT x.sha, bool_or(x.deleted_at IS NULL) AS live, count(*)::text AS n, max(x.deleted_at) AS last
         FROM (SELECT encode(checksum_sha256, 'hex') AS sha, deleted_at FROM product_images
                WHERE checksum_sha256 = ANY (SELECT decode(s, 'hex') FROM unnest($1::text[]) AS s)
               UNION ALL
               SELECT substr(storage_key, 8) AS sha, deleted_at FROM product_images
                WHERE storage_key = ANY (SELECT 'images/' || s FROM unnest($1::text[]) AS s)) x
        GROUP BY x.sha`,
      [shas],
    );
    for (const row of r.rows) out.set(row.sha, { live: row.live, rows: Number(row.n), lastDeleted: row.last });
    return out;
  }

  /** Время самого нового файла каталога (без пометки и временных файлов записи), мс; `null` — файлов нет. */
  private async newestFile(dir: string): Promise<number | null> {
    let newest: number | null = null;
    let entries: string[];
    try {
      entries = await readdir(dir);
    } catch {
      return null;
    }
    for (const name of entries) {
      if (name === ImageStore.GC_MARKER) continue;
      const t = await mtime(path.join(dir, name));
      if (t !== null && (newest === null || t > newest)) newest = t;
    }
    return newest;
  }
}

async function mtime(p: string): Promise<number | null> {
  try {
    return (await stat(p)).mtimeMs;
  } catch {
    return null;
  }
}

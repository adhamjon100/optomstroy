import type pg from 'pg';
import type { Logger } from 'pino';
import type { SyncMode, SyncTrigger } from '../../common/enums.js';
import type { ApplyRunTracker } from '../apply/apply.types.js';
import { ImageDecodeError, MAX_SOURCE_BYTES, processImage, sha256Hex } from './image-processor.js';
import {
  expectedBytesOf,
  etagSha256,
  type ImageBytesSource,
  type ImageListSource,
  ImageSourceError,
} from './image-sources.js';
import { ImageStore } from './image-store.js';
import { emptyImageCounts, type ImageItemError, type ImageRunCounts } from './image.types.js';
import { type ClaimedImage, ProductImageRepository } from './product-image.repository.js';

export interface ImageSyncOptions {
  /** Параллельных скачиваний/обработок (sharp загружает CPU; 1С — `ONEC_MAX_CONCURRENCY`). */
  readonly concurrency?: number;
  readonly batchSize?: number;
  /** Попыток при временных ошибках (сеть, 5xx) до остановки повторов. */
  readonly maxAttempts?: number;
  /** База экспоненциальной паузы повтора, секунды. */
  readonly backoffBaseSec?: number;
  readonly limitInputPixels?: number;
  /** Предел размера тела исходника (байт). */
  readonly maxSourceBytes?: number;
  readonly now?: () => Date;
}

export interface ImageSyncRunRequest {
  readonly trigger?: SyncTrigger;
  readonly mode?: SyncMode;
  /** Прогон уже создан вызывающим (`SyncJobProcessor`) — сервис его не завершает. */
  readonly runId?: string;
  /** Полный список файлов (ночная сверка); без него обрабатывается только очередь `product_images`. */
  readonly listSource?: ImageListSource | null;
  /** requestId запуска (журнал); `X-Request-Id` каждого запроса к 1С создаёт шлюз. */
  readonly requestId?: string;
  readonly signal?: AbortSignal;
  /** Предел обработанных строк за прогон (по умолчанию — вся очередь). */
  readonly maxItems?: number;
}

export interface ImageSyncResult {
  readonly runId: string;
  readonly status: 'success' | 'partial';
  readonly counts: ImageRunCounts;
  /** Источник байтов отсутствует в этом режиме (`odata_only`) — очередь не обрабатывалась. */
  readonly sourceAvailable: boolean;
}

/**
 * Ежесуточный прогон фото (05 SYNC-035, ONEC-006; D-30; RM-E-003): [полный список файлов → `product_images`] →
 * очередь `pending`/`failed` → HS `GET /pos/v1/images/{ref}` с `If-None-Match: "<sha256>"` → проверка размера и
 * sha256 (ETag) → дедупликация по sha256 → sharp: `thumb 160` / `card 400` / `full 1200` WebP →
 * `images/{sha256}/{size}.webp` → `ready` → главное фото товара. Битый файл → `failed` (заглушка на клиенте) +
 * `sync_errors`; 404 → `missing_source`. Привязка — только по `onec_ref` владельца (регистрация).
 *
 * Порт для планировщика — `run()` (через `ImageSyncHandler` очереди `sync.images`, cron `SYNC_IMAGES_CRON`).
 */
export class ImageSyncService {
  private readonly repo = new ProductImageRepository();
  private readonly concurrency: number;
  private readonly batchSize: number;
  private readonly maxAttempts: number;
  private readonly backoffBaseSec: number;
  private readonly maxSourceBytes: number;
  private readonly now: () => Date;

  constructor(
    private readonly pool: pg.Pool,
    private readonly source: ImageBytesSource | null,
    private readonly store: ImageStore,
    private readonly runs: ApplyRunTracker,
    private readonly log: Logger,
    private readonly options: ImageSyncOptions = {},
  ) {
    this.concurrency = Math.max(1, options.concurrency ?? 2);
    this.batchSize = Math.max(1, options.batchSize ?? 50);
    this.maxAttempts = Math.max(1, options.maxAttempts ?? 5);
    this.backoffBaseSec = Math.max(1, options.backoffBaseSec ?? 600);
    this.maxSourceBytes = options.maxSourceBytes ?? MAX_SOURCE_BYTES;
    this.now = options.now ?? (() => new Date());
  }

  get sourceAvailable(): boolean {
    return this.source !== null;
  }

  async run(req: ImageSyncRunRequest = {}): Promise<ImageSyncResult> {
    const ownRun = !req.runId;
    const runId =
      req.runId ??
      (await this.runs.start({
        entity: 'images',
        mode: req.mode ?? 'incremental',
        trigger: req.trigger ?? 'schedule',
        ...(this.source ? { endpoint: 'GET /pos/v1/images/{ref}' } : {}),
      }));
    const counts = emptyImageCounts();
    const log = this.log.child({ runId, entity: 'images', ...(req.requestId ? { requestId: req.requestId } : {}) });
    try {
      await this.repo.resetStuck(this.pool);
      const affected = new Set<string>();
      if (req.listSource) await this.reconcileList(req.listSource, runId, counts, affected, req.signal);
      if (this.source) await this.drainQueue(this.source, runId, counts, affected, req);
      else {
        const pending = await this.pool.query<{ n: string }>(
          `SELECT count(*)::text AS n FROM product_images WHERE deleted_at IS NULL AND status IN ('pending','failed')`,
        );
        counts.skipped = Number(pending.rows[0]?.n ?? 0);
        log.info({ pending: counts.skipped }, 'images.source_unavailable: байты фото в этом режиме 1С недоступны');
      }
      await this.repo.refreshPrimary(this.pool, affected);
      const status = counts.errors > 0 || counts.failed > 0 ? 'partial' : 'success';
      if (ownRun) await this.runs.finish({ runId, entity: 'images', status, counts: { ...counts } });
      log.info({ status, counts }, 'images.run.finished');
      return { runId, status, counts, sourceAvailable: this.source !== null };
    } catch (e) {
      if (ownRun) {
        await this.runs
          .finish({
            runId,
            entity: 'images',
            status: 'failed',
            counts: { ...counts },
            errorSummary: e instanceof Error ? e.message : String(e),
          })
          .catch((err: unknown) => log.error({ err }, 'images.run.finish_failed'));
      }
      throw e;
    }
  }

  /** Полный список файлов → регистрация; отсутствующие в полном списке → `deleted_at`. */
  private async reconcileList(
    src: ImageListSource,
    runId: string,
    counts: ImageRunCounts,
    affected: Set<string>,
    signal?: AbortSignal,
  ): Promise<void> {
    const seen: string[] = [];
    let complete = true;
    for await (const page of src.list(signal)) {
      if (signal?.aborted) {
        complete = false;
        break;
      }
      counts.listed += page.length;
      for (const e of page) if (!e.deletionMark) seen.push(e.sourceRef);
      const res = await this.repo.register(this.pool, page);
      counts.registered += res.inserted + res.updated;
      counts.markedDeleted += res.markedDeleted;
      counts.ownerNotFound += res.ownerNotFound;
      counts.errors += await this.repo.writeErrors(this.pool, res.errors, runId);
      for (const p of res.affectedProducts) affected.add(p);
    }
    if (complete && !signal?.aborted) {
      const gone = await this.repo.markAbsent(this.pool, seen);
      counts.markedDeleted += gone.count;
      for (const p of gone.products) affected.add(p);
    }
  }

  private async drainQueue(
    source: ImageBytesSource,
    runId: string,
    counts: ImageRunCounts,
    affected: Set<string>,
    req: ImageSyncRunRequest,
  ): Promise<void> {
    const done: string[] = [];
    const limit = req.maxItems ?? Number.POSITIVE_INFINITY;
    while (!req.signal?.aborted && done.length < limit) {
      const take = Math.min(this.batchSize, limit - done.length);
      const batch = await this.repo.claim(this.pool, take, this.now(), done);
      if (batch.length === 0) break;
      let next = 0;
      const worker = async (): Promise<void> => {
        for (;;) {
          const i = next++;
          if (i >= batch.length) return;
          const row = batch[i];
          await this.processOne(source, row, runId, counts, req).catch(async (e: unknown) => {
            // Непредвиденная ошибка (БД/диск) — строка не должна остаться в `downloading`.
            await this.failRow(row, runId, counts, {
              code: 'OTHER',
              message: `ошибка обработки фото: ${e instanceof Error ? e.message.split('\n')[0].slice(0, 200) : 'ошибка'}`,
              retryable: true,
            });
            return false;
          });
          // Готово или сброшено в заглушку — главное фото товара пересчитывается в обоих случаях.
          if (row.productId) affected.add(row.productId);
        }
      };
      await Promise.all(Array.from({ length: Math.min(this.concurrency, batch.length) }, () => worker()));
      for (const r of batch) done.push(r.id);
    }
    // Строки, захваченные, но не обработанные из-за отмены, вернутся в очередь при следующем прогоне (resetStuck).
    if (req.signal?.aborted) await this.repo.resetStuck(this.pool);
  }

  /** Обработать одну строку очереди. `true` — строка `ready`. */
  private async processOne(
    source: ImageBytesSource,
    row: ClaimedImage,
    runId: string,
    counts: ImageRunCounts,
    req: ImageSyncRunRequest,
  ): Promise<boolean> {
    const haveFiles = row.checksum !== null && row.storageKey !== null && (await this.store.has(row.checksum));
    const ifNoneMatch = haveFiles && row.checksum ? `"${row.checksum}"` : undefined;
    let res;
    try {
      res = await source.fetch(row.sourceRef, {
        ...(ifNoneMatch ? { ifNoneMatch } : {}),
        ...(req.signal ? { signal: req.signal } : {}),
      });
    } catch (e) {
      const retryable = e instanceof ImageSourceError ? e.retryable : true;
      await this.failRow(row, runId, counts, {
        code: 'IMAGE_DOWNLOAD',
        message: `скачивание фото не удалось: ${e instanceof Error ? e.message.slice(0, 200) : 'ошибка'}`,
        retryable,
      });
      return false;
    }

    if (res.kind === 'not_modified') {
      if (haveFiles) {
        await this.repo.markNotModified(this.pool, row.id);
        counts.notModified += 1;
        counts.ready += 1;
        return true;
      }
      // 304 без локальных файлов (If-None-Match не отправлялся) — ответ источника не по контракту.
      await this.failRow(row, runId, counts, {
        code: 'IMAGE_DOWNLOAD',
        message: '304 без запрошенной версии — файл не получен',
        retryable: true,
      });
      return false;
    }
    if (res.kind === 'not_found') {
      await this.repo.markMissing(this.pool, row.id);
      counts.missing += 1;
      counts.errors += await this.repo.writeErrors(
        this.pool,
        [
          {
            errorCode: 'IMAGE_DOWNLOAD',
            severity: 'warning',
            message: 'файл фото не найден в 1С (404) — показывается заглушка',
            onecRef: row.sourceRef,
            localId: row.id,
            payload: { reason: 'not_found' },
          },
        ],
        runId,
      );
      return false;
    }

    counts.downloaded += 1;
    const data = res.data;
    if (data.byteLength > this.maxSourceBytes) {
      await this.failRow(row, runId, counts, {
        code: 'IMAGE_DOWNLOAD',
        message: `файл фото больше ${this.maxSourceBytes} байт`,
        retryable: false,
      });
      return false;
    }
    // Частично скачанный файл отбрасывается: размер из версии 1С и sha256 из ETag (05 ONEC-006, SYNC-035).
    const expected = expectedBytesOf(row.sourceVersion);
    if (expected !== null && expected !== data.byteLength) {
      await this.failRow(row, runId, counts, {
        code: 'HASH_MISMATCH',
        message: `размер файла ${data.byteLength} ≠ ${expected} (Размер 1С)`,
        retryable: true,
      });
      return false;
    }
    const sha = sha256Hex(data);
    const etagSha = etagSha256(res.etag);
    if (etagSha !== null && etagSha !== sha) {
      await this.failRow(row, runId, counts, {
        code: 'HASH_MISMATCH',
        message: 'sha256 содержимого не совпадает с ETag 1С',
        retryable: true,
      });
      return false;
    }

    // Строки с одинаковым содержимым обрабатываются по очереди (параллельные воркеры прогона).
    return this.store.withKey(sha, () => this.storeAndMark(row, runId, counts, data, sha));
  }

  private async storeAndMark(
    row: ClaimedImage,
    runId: string,
    counts: ImageRunCounts,
    data: Uint8Array,
    sha: string,
  ): Promise<boolean> {
    // Дедупликация: тот же файл уже обработан (другой товар/строка) — только ссылка.
    if (await this.store.has(sha)) {
      const meta = await this.repo.readyMetaBySha(this.pool, sha);
      if (meta) {
        await this.repo.markReady(this.pool, row.id, meta);
        counts.deduplicated += 1;
        counts.ready += 1;
        return true;
      }
    }
    try {
      const img = await processImage(data, {
        maxSourceBytes: this.maxSourceBytes,
        ...(this.options.limitInputPixels ? { limitInputPixels: this.options.limitInputPixels } : {}),
      });
      if (!(await this.store.has(sha))) await this.store.write(sha, img.renders);
      else counts.deduplicated += 1;
      await this.repo.markReady(this.pool, row.id, {
        sha256: sha,
        storageKey: ImageStore.storageKey(sha),
        originalMime: img.originalMime,
        originalBytes: img.originalBytes,
        width: img.width,
        height: img.height,
        sizes: img.sizes,
      });
      counts.processed += 1;
      counts.ready += 1;
      return true;
    } catch (e) {
      if (e instanceof ImageDecodeError) {
        // Битый файл: повтор бессмыслен до смены версии в 1С (новая версия → pending при регистрации).
        await this.failRow(row, runId, counts, {
          code: 'IMAGE_DOWNLOAD',
          message: `файл фото не читается как изображение (${e.reason}) — показывается заглушка`,
          retryable: false,
          checksum: sha,
          reason: e.reason,
        });
        return false;
      }
      throw e;
    }
  }

  private async failRow(
    row: ClaimedImage,
    runId: string,
    counts: ImageRunCounts,
    f: {
      code: ImageItemError['errorCode'];
      message: string;
      retryable: boolean;
      checksum?: string;
      reason?: string;
    },
  ): Promise<void> {
    const attempts = row.attempts + 1;
    const final = !f.retryable || attempts >= this.maxAttempts;
    const retryAt = final
      ? null
      : new Date(this.now().getTime() + this.backoffBaseSec * 1000 * 2 ** Math.min(attempts - 1, 8));
    await this.repo.markFailed(this.pool, row.id, {
      error: f.message,
      attempts,
      retryAt,
      ...(f.checksum ? { checksum: f.checksum } : {}),
    });
    counts.failed += 1;
    // В журнал — окончательные ошибки (битый файл, исчерпаны попытки); промежуточные — только в лог.
    if (final) {
      counts.errors += await this.repo.writeErrors(
        this.pool,
        [
          {
            errorCode: f.code,
            severity: 'error',
            message: f.message,
            onecRef: row.sourceRef,
            localId: row.id,
            payload: { attempts, ...(f.reason ? { reason: f.reason } : {}) },
          },
        ],
        runId,
      );
    } else {
      this.log.warn({ imageId: row.id, attempts, code: f.code }, 'images.item.retry: будет повтор');
    }
  }
}

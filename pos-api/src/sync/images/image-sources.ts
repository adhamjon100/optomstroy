import type { OnecImageFileItem } from '../../integrations/onec/onec-catalog.types.js';
import { ONEC_TYPE } from '../../integrations/onec/onec-catalog.types.js';
import { isOnecError } from '../../integrations/onec/onec-error.js';
import type { OnecGateway } from '../../integrations/onec/onec-gateway.js';
import type { OnecODataClient, ODataRow } from '../../integrations/onec/onec-odata.client.js';
import { type ImageFileEntry, normRef } from './image.types.js';

// ------------------------------------------------------------------ байты файла

export type ImageFetchResult =
  | { readonly kind: 'ok'; readonly data: Uint8Array; readonly contentType: string; readonly etag: string | null }
  | { readonly kind: 'not_modified' }
  | { readonly kind: 'not_found' };

/** Источник байтов присоединённого файла (05 §6.3: HS `GET /pos/v1/images/{ref}`, ETag/If-None-Match). */
export interface ImageBytesSource {
  readonly name: string;
  fetch(
    sourceRef: string,
    opts?: { readonly ifNoneMatch?: string; readonly requestId?: string; readonly signal?: AbortSignal },
  ): Promise<ImageFetchResult>;
}

/** Ошибка источника, после которой повтор имеет смысл (сеть, 5xx, 423, таймаут). */
export class ImageSourceError extends Error {
  override readonly name = 'ImageSourceError';
  constructor(
    message: string,
    readonly retryable: boolean,
    readonly status?: number,
  ) {
    super(message);
  }
}

/**
 * `OnecGateway.getImage` как источник байтов: 304 → `not_modified`, 404 → `not_found`, прочие ошибки 1С →
 * `ImageSourceError` (повтор — по `retryable` 1С, ONEC-055). Режим `odata_only` байтов не отдаёт (501) — сервис
 * в этом режиме источник не создаёт (фото — разовой выгрузкой, SYNC-036).
 */
export class GatewayImageSource implements ImageBytesSource {
  readonly name: string;

  constructor(private readonly gateway: Pick<OnecGateway, 'getImage' | 'mode'>) {
    this.name = `onec:${gateway.mode}`;
  }

  async fetch(
    sourceRef: string,
    opts: { readonly ifNoneMatch?: string; readonly requestId?: string; readonly signal?: AbortSignal } = {},
  ): Promise<ImageFetchResult> {
    try {
      const r = await this.gateway.getImage(sourceRef, opts.ifNoneMatch, {
        ...(opts.requestId ? { requestId: opts.requestId } : {}),
        ...(opts.signal ? { signal: opts.signal } : {}),
      });
      if (r.status === 304 || r.body === null) return { kind: 'not_modified' };
      return { kind: 'ok', data: r.body.data, contentType: r.body.contentType, etag: r.body.etag };
    } catch (e) {
      if (isOnecError(e)) {
        if (e.status === 404) return { kind: 'not_found' };
        throw new ImageSourceError(`${e.status} ${e.code}`, e.retryable || e.status >= 500, e.status);
      }
      throw new ImageSourceError(e instanceof Error ? e.message.split('\n')[0].slice(0, 200) : 'ошибка', true);
    }
  }
}

/** sha256 из ETag `"<hex>"` (05 §6.3); fallback-ETag `"<дата>-<размер>"` → `null` (хэш считает backend). */
export function etagSha256(etag: string | null | undefined): string | null {
  if (!etag) return null;
  const m = /^(?:W\/)?"?([0-9a-fA-F]{64})"?$/.exec(etag.trim());
  return m ? m[1].toLowerCase() : null;
}

// ------------------------------------------------------------------ список файлов

/** Расширения файлов-картинок; прочие присоединённые файлы номенклатуры (PDF, DOC…) в фото не попадают. */
export const IMAGE_EXTENSIONS: ReadonlySet<string> = new Set([
  'jpg',
  'jpeg',
  'jpe',
  'jfif',
  'png',
  'webp',
  'gif',
  'tif',
  'tiff',
  'heic',
  'heif',
]);

export function isImageExtension(ext: string | null | undefined): boolean {
  const e = (ext ?? '').trim().toLowerCase().replace(/^\./, '');
  return e === '' || IMAGE_EXTENSIONS.has(e);
}

/** Версия файла 1С (05 ONEC-006): `ДатаМодификацииУниверсальная|Размер`. */
export function onecFileVersion(modifiedAt: unknown, size: unknown): string | null {
  const m = typeof modifiedAt === 'string' ? modifiedAt.trim() : '';
  const s = typeof size === 'number' || typeof size === 'string' ? String(size).trim() : '';
  if (!m && !s) return null;
  return `${m}|${s}`;
}

/** Ожидаемый размер из версии `…|<байт>` (проверка «частично скачанного» файла, 05 ONEC-006). */
export function expectedBytesOf(version: string | null): number | null {
  const m = version ? /\|(\d{1,12})$/.exec(version) : null;
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isSafeInteger(n) && n > 0 ? n : null;
}

/**
 * Элемент `/changes` `Catalog_НоменклатураПрисоединенныеФайлы` (контракт `ChangeItem`) → запись списка.
 * `null` — не картинка (расширение) или нет ссылки.
 */
export function entryFromChangeItem(item: Readonly<Record<string, unknown>>): ImageFileEntry | null {
  if (item.type === 'ObjectDeletion') {
    const ref = normRef(item.ref);
    return ref ? { sourceRef: ref, ownerRef: null, sourceVersion: null, deletionMark: true } : null;
  }
  const it = item as unknown as OnecImageFileItem;
  const ref = normRef(it.ref);
  if (!ref) return null;
  if (!isImageExtension(it.extension))
    return { sourceRef: ref, ownerRef: null, sourceVersion: null, deletionMark: true };
  return {
    sourceRef: ref,
    ownerRef: normRef(it.ownerRef ?? null),
    sourceVersion: onecFileVersion(it.modifiedAt, it.size),
    sortOrder: 0,
    deletionMark: it.deletionMark === true,
    ...(typeof it.isMain === 'boolean' ? { isMain: it.isMain } : {}),
  };
}

/** Полный список файлов источника (ночная сверка, SYNC-035): страницы записей. */
export interface ImageListSource {
  readonly name: string;
  list(signal?: AbortSignal): AsyncIterable<readonly ImageFileEntry[]>;
}

const ODATA_FILE_FIELDS = [
  'Ref_Key',
  'DataVersion',
  'DeletionMark',
  'ВладелецФайла_Key',
  'Размер',
  'Расширение',
  'ДатаМодификацииУниверсальная',
] as const;

/**
 * Список присоединённых файлов номенклатуры через OData (05 ONEC-006, allow-list `Catalog_НоменклатураПрисоединенныеФайлы`;
 * поля `[НЕ ПОДТВЕРЖДЕНО: $metadata]`). Байты этим путём не читаются (тома — только HS, ONEC-006).
 */
export class ODataImageListSource implements ImageListSource {
  readonly name = 'odata:Catalog_НоменклатураПрисоединенныеФайлы';

  constructor(private readonly client: Pick<OnecODataClient, 'pages'>) {}

  async *list(signal?: AbortSignal): AsyncIterable<readonly ImageFileEntry[]> {
    for await (const page of this.client.pages(ONEC_TYPE.imageFile, { select: [...ODATA_FILE_FIELDS] })) {
      if (signal?.aborted) return;
      const out: ImageFileEntry[] = [];
      for (const row of page.rows) {
        const e = entryFromODataRow(row);
        if (e) out.push(e);
      }
      yield out;
    }
  }
}

export function entryFromODataRow(row: ODataRow): ImageFileEntry | null {
  const ref = normRef(row.Ref_Key);
  if (!ref) return null;
  const isImage = isImageExtension(typeof row['Расширение'] === 'string' ? row['Расширение'] : '');
  return {
    sourceRef: ref,
    ownerRef: normRef(row['ВладелецФайла_Key']),
    sourceVersion: onecFileVersion(row['ДатаМодификацииУниверсальная'], row['Размер']),
    sortOrder: 0,
    deletionMark: row.DeletionMark === true || !isImage,
  };
}

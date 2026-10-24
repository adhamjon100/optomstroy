import { createHash } from 'node:crypto';
import type { Response } from 'express';

/**
 * Кэширование ответов каталога (08 §2.8): `ETag` + `Cache-Control: private, max-age=…`, `If-None-Match` → 304 без
 * тела; `X-Data-As-Of` — момент снимка данных 1С. ETag — слабый валидатор по SHA-256 канонического тела ответа:
 * он меняется при любом изменении представления (цены, остатки, снимок, поля роли), что строже формулы 08 §2.8
 * (`max(updated_at)`, `count`, `priceListId`, `warehouseId`) и не даёт ложного 304 после обновления остатков.
 */
export const CACHE_REFERENCE = 'private, max-age=300';
export const CACHE_PRODUCTS = 'private, max-age=60';
export const CACHE_NO_STORE = 'no-store';

export function etagOfBody(body: unknown): string {
  return `W/"${createHash('sha256').update(JSON.stringify(body)).digest('base64url').slice(0, 32)}"`;
}

/** Совпадение `If-None-Match` (список, `*`, слабое сравнение — RFC 9110 §13.1.2). */
export function etagMatches(ifNoneMatch: string | undefined, etag: string): boolean {
  if (!ifNoneMatch) return false;
  const strip = (t: string) => t.trim().replace(/^W\//, '');
  const target = strip(etag);
  return ifNoneMatch.split(',').some((t) => t.trim() === '*' || strip(t) === target);
}

export interface CachedSend {
  readonly body: unknown;
  readonly cacheControl: string;
  readonly dataAsOf?: Date;
  readonly ifNoneMatch?: string;
  /** false — без ETag (no-store ответы `/inventory/*`). */
  readonly etag?: boolean;
}

/** Отправить ответ 200 (или 304 при совпадении ETag) с заголовками кэширования. */
export function sendCached(res: Response, opts: CachedSend): void {
  res.setHeader('Cache-Control', opts.cacheControl);
  if (opts.dataAsOf) res.setHeader('X-Data-As-Of', opts.dataAsOf.toISOString());
  if (opts.etag !== false) {
    const etag = etagOfBody(opts.body);
    res.setHeader('ETag', etag);
    if (etagMatches(opts.ifNoneMatch, etag)) {
      res.status(304).end();
      return;
    }
  }
  res.status(200).json(opts.body);
}

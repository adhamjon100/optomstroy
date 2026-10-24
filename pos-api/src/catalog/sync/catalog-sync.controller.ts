import { Controller, Get, Headers, Param, Query, Req, Res } from '@nestjs/common';
import type { Response } from 'express';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { etagMatches } from '../common/catalog-http.js';
import { MAX_CURSOR_LENGTH } from './catalog-sync.cursor.js';
import { CatalogSyncService } from './catalog-sync.service.js';
import {
  CATALOG_SYNC_DEFAULT_LIMIT,
  CATALOG_SYNC_ENTITIES,
  CATALOG_SYNC_MAX_LIMIT,
  isCatalogSyncEntity,
} from './catalog-sync.types.js';

/** `Cache-Control` выгрузки (08 §4.24 «Кэширование»). */
export const CATALOG_SYNC_CACHE_CONTROL = 'private, no-cache';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function invalid(field: string, rule: string, message: string, params?: Record<string, unknown>): never {
  throw new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field, rule, message, ...(params ? { params } : {}) }],
  });
}

function single(q: Record<string, unknown>, name: string): string | undefined {
  const v = q[name];
  if (v === undefined) return undefined;
  if (typeof v !== 'string') invalid(name, 'type', `Параметр ${name} задан более одного раза или неверно.`);
  return v;
}

/** `limit` 1…200 (08 §4.24; T-CAT-034: `limit=201` → rule `limit`). */
export function parseSyncLimit(raw: string | undefined): number {
  if (raw === undefined || raw === '') return CATALOG_SYNC_DEFAULT_LIMIT;
  if (!/^\d{1,6}$/.test(raw)) invalid('limit', 'limit', 'limit — целое число 1…200.');
  const n = Number(raw);
  if (n < 1 || n > CATALOG_SYNC_MAX_LIMIT) {
    invalid('limit', 'limit', `limit — от 1 до ${CATALOG_SYNC_MAX_LIMIT}.`, {
      minimum: 1,
      maximum: CATALOG_SYNC_MAX_LIMIT,
    });
  }
  return n;
}

/**
 * `GET /catalog/sync/{entity}` (RM-E-015; 08 §4.24, ядро §22.7) — первичная загрузка (без `since`) и инкремент
 * офлайн-кэша клиента. `catalog.read` — обязательный код операции (все интерактивные роли R1, 11 §4.4); права по
 * сущностям и виды цен — `CatalogSyncService`. Токен `integration` → 403 (нет `catalog.read`; проверяется и в
 * сервисе). `ETag` + `Cache-Control: private, no-cache`; `If-None-Match` → 304; `X-Data-As-Of`. Аудит не пишется.
 */
@Controller('catalog/sync')
export class CatalogSyncController {
  constructor(private readonly service: CatalogSyncService) {}

  @Get(':entity')
  @RequirePermission('catalog.read')
  async page(
    @Req() req: RequestWithContext,
    @Param('entity') entity: string,
    @Query() q: Record<string, unknown>,
    @Headers('if-none-match') ifNoneMatch: string | undefined,
    @Res() res: Response,
  ): Promise<void> {
    if (!isCatalogSyncEntity(entity)) {
      invalid('entity', 'enum', 'Неизвестная сущность выгрузки.', { allowed: CATALOG_SYNC_ENTITIES });
    }
    const limit = parseSyncLimit(single(q, 'limit'));
    const since = single(q, 'since');
    if (since !== undefined && since.length > MAX_CURSOR_LENGTH) invalid('since', 'cursor', 'Курсор недействителен.');
    const warehouseRaw = single(q, 'warehouseId');
    if (warehouseRaw !== undefined && warehouseRaw !== '' && !UUID_RE.test(warehouseRaw)) {
      invalid('warehouseId', 'uuid', 'warehouseId — UUID.');
    }
    const warehouseId = warehouseRaw ? warehouseRaw.toLowerCase() : undefined;
    const result = await this.service.page(req.principal, {
      entity,
      limit,
      ...(since !== undefined && since !== '' ? { since } : {}),
      ...(warehouseId !== undefined ? { warehouseId } : {}),
    });
    res.setHeader('Cache-Control', CATALOG_SYNC_CACHE_CONTROL);
    res.setHeader('ETag', result.etag);
    res.setHeader('X-Data-As-Of', (result.dataAsOf ?? new Date(result.body.serverTime)).toISOString());
    if (etagMatches(ifNoneMatch, result.etag)) {
      res.status(304).end();
      return;
    }
    res.status(200).json(result.body);
  }
}

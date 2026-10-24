import { Controller, Delete, Get, HttpCode, Query, Req, Res } from '@nestjs/common';
import type { Response } from 'express';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { CACHE_NO_STORE } from '../common/catalog-http.js';
import { CatalogSnapshotService } from '../common/catalog-snapshot.js';
import { RECENT_LIMIT_DEFAULT, RECENT_LIMIT_MAX, RecentProductsService } from './recent-products.service.js';

export function parseRecentLimit(raw: unknown): number {
  if (raw === undefined || raw === '') return RECENT_LIMIT_DEFAULT;
  const fail = (): never => {
    throw new ProblemException('VALIDATION_FAILED', {
      status: 400,
      detail: 'Запрос не прошёл проверку.',
      errors: [
        {
          field: 'limit',
          rule: 'limit',
          message: `limit — от 1 до ${RECENT_LIMIT_MAX}.`,
          params: { minimum: 1, maximum: RECENT_LIMIT_MAX },
        },
      ],
    });
  };
  if (typeof raw !== 'string' || !/^\d{1,6}$/.test(raw)) fail();
  const n = Number(raw);
  if (n < 1 || n > RECENT_LIMIT_MAX) fail();
  return n;
}

/**
 * «Недавние товары» (RM-E-006; 08 §4.4.5, ядро §17.4): `GET /catalog/products/recent` — собственный список,
 * `DELETE /catalog/products/recent` — «Очистить» (повтор → 204; офлайн-очередь клиента `recent.clear`).
 * Право `catalog.read` (все роли R1; `customer` — при `CUSTOMER_SELF_SERVICE=true`), цены — по `catalog.prices.read`
 * в `ProductSummary`. `Cache-Control: no-store`. Аудит не пишется.
 *
 * Маршрут статический (`products/recent`) и должен регистрироваться **раньше** `GET /catalog/products/:id`
 * (`CatalogApiModule`): модуль `CatalogRecentModule` подключается в `CatalogModule` перед `CatalogApiModule`.
 */
@Controller('catalog/products')
export class RecentProductsController {
  constructor(
    private readonly recent: RecentProductsService,
    private readonly snapshots: CatalogSnapshotService,
  ) {}

  @Get('recent')
  @RequirePermission('catalog.read')
  async list(@Req() req: RequestWithContext, @Query('limit') limit: unknown, @Res() res: Response): Promise<void> {
    const n = parseRecentLimit(limit);
    const [body, snap] = await Promise.all([this.recent.list(req.principal, n), this.snapshots.read()]);
    res.setHeader('Cache-Control', CACHE_NO_STORE);
    if (snap.dataAsOf) res.setHeader('X-Data-As-Of', snap.dataAsOf.toISOString());
    res.status(200).json(body);
  }

  @Delete('recent')
  @HttpCode(204)
  @RequirePermission('catalog.read')
  async clear(@Req() req: RequestWithContext, @Res({ passthrough: true }) res: Response): Promise<void> {
    await this.recent.clear(req.principal);
    res.setHeader('Cache-Control', CACHE_NO_STORE);
  }
}

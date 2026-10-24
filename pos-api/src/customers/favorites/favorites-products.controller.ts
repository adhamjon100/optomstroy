import { Controller, Delete, Get, HttpCode, Param, Put, Query, Req, Res } from '@nestjs/common';
import type { Response } from 'express';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import {
  FAVORITES_LIMIT_DEFAULT,
  FAVORITES_LIMIT_MAX,
  type FavoritesPage,
  FavoritesProductsService,
} from './favorites-products.service.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NO_STORE = 'no-store';

function invalid(field: string, rule: string, message: string): never {
  throw new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field, rule, message }],
  });
}

function one(q: Record<string, unknown>, name: string): string | undefined {
  const v = q[name];
  if (v === undefined || v === '') return undefined;
  if (typeof v !== 'string') invalid(name, 'type', `Параметр ${name} задан более одного раза или неверно.`);
  return v;
}

function uuid(value: string | undefined, field: string): string | undefined {
  if (value === undefined) return undefined;
  if (!UUID_RE.test(value)) invalid(field, 'uuid', `${field} — UUID.`);
  return value.toLowerCase();
}

/**
 * Избранные товары (RM-E-006; 08 §4.13.1–§4.13.2): `GET /favorites/products` — `Page<ProductSummary>` + `count`;
 * `PUT|DELETE /favorites/products/{id}` → 204, повтор → 204 (идемпотентны для outbox клиента, D-32;
 * `Idempotency-Key` допускается). Право `favorites.products.manage` — все роли R1 (`customer` — при
 * `CUSTOMER_SELF_SERVICE=true`). `Cache-Control: no-store`. Аудит не пишется.
 */
@Controller('favorites/products')
export class FavoritesProductsController {
  constructor(private readonly service: FavoritesProductsService) {}

  @Get()
  @RequirePermission('favorites.products.manage')
  async list(
    @Req() req: RequestWithContext,
    @Query() q: Record<string, unknown>,
    @Res({ passthrough: true }) res: Response,
  ): Promise<FavoritesPage> {
    const rawLimit = one(q, 'limit');
    let limit = FAVORITES_LIMIT_DEFAULT;
    if (rawLimit !== undefined) {
      if (!/^\d{1,6}$/.test(rawLimit) || Number(rawLimit) < 1 || Number(rawLimit) > FAVORITES_LIMIT_MAX) {
        invalid('limit', 'limit', `limit — от 1 до ${FAVORITES_LIMIT_MAX}.`);
      }
      limit = Number(rawLimit);
    }
    const cursor = one(q, 'cursor');
    const warehouseId = uuid(one(q, 'warehouseId'), 'warehouseId');
    res.setHeader('Cache-Control', NO_STORE);
    return this.service.list(req.principal, {
      limit,
      ...(cursor !== undefined ? { cursor } : {}),
      ...(warehouseId !== undefined ? { warehouseId } : {}),
    });
  }

  @Put(':id')
  @HttpCode(204)
  @RequirePermission('favorites.products.manage')
  @Idempotent({ required: false })
  async add(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<void> {
    res.setHeader('Cache-Control', NO_STORE);
    await this.service.add(req.principal, uuid(id, 'id') as string);
  }

  @Delete(':id')
  @HttpCode(204)
  @RequirePermission('favorites.products.manage')
  async remove(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<void> {
    res.setHeader('Cache-Control', NO_STORE);
    await this.service.remove(req.principal, uuid(id, 'id') as string);
  }
}

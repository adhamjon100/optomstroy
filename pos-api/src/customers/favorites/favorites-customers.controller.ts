import { Controller, Delete, Get, HttpCode, Param, Put, Query, Req, Res } from '@nestjs/common';
import type { Response } from 'express';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { CustomerAccessService } from '../common/customer-access.js';
import { customerIdParam, limitQuery, NO_STORE, oneQuery } from '../common/customer-http.js';
import {
  FAVORITE_CUSTOMERS_LIMIT_DEFAULT,
  FAVORITE_CUSTOMERS_LIMIT_MAX,
  type FavoriteCustomersPage,
  FavoritesCustomersService,
} from './favorites-customers.service.js';

/**
 * Избранные клиенты (08 §4.13.1–§4.13.2; OpenAPI `favorites_customers_list|put|delete`; SCR-40, дашборд кассира).
 * Право `favorites.customers.manage` — `cashier`, `senior_seller`, `admin` (`owner`, `seller`, `customer` → 403,
 * 11 §4.4). `Cache-Control: no-store`. `PUT` принимает необязательный `Idempotency-Key` (08 §2.7).
 */
@Controller('favorites/customers')
export class FavoritesCustomersController {
  constructor(
    private readonly service: FavoritesCustomersService,
    private readonly access: CustomerAccessService,
  ) {}

  @Get()
  @RequirePermission('favorites.customers.manage')
  async list(
    @Req() req: RequestWithContext,
    @Query() q: Record<string, unknown>,
    @Res({ passthrough: true }) res: Response,
  ): Promise<FavoriteCustomersPage> {
    res.setHeader('Cache-Control', NO_STORE);
    const v = this.access.viewer(req.principal);
    const cursor = oneQuery(q, 'cursor');
    return this.service.list(v, {
      limit: limitQuery(q, FAVORITE_CUSTOMERS_LIMIT_DEFAULT, FAVORITE_CUSTOMERS_LIMIT_MAX),
      ...(cursor !== undefined ? { cursor } : {}),
    });
  }

  @Put(':id')
  @HttpCode(204)
  @RequirePermission('favorites.customers.manage')
  @Idempotent({ required: false })
  async add(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<void> {
    res.setHeader('Cache-Control', NO_STORE);
    await this.service.add(this.access.viewer(req.principal), customerIdParam(id));
  }

  @Delete(':id')
  @HttpCode(204)
  @RequirePermission('favorites.customers.manage')
  async remove(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<void> {
    res.setHeader('Cache-Control', NO_STORE);
    await this.service.remove(this.access.viewer(req.principal), customerIdParam(id));
  }
}

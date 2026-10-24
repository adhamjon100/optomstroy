import { Controller, Get, Header, Param, Query, Req } from '@nestjs/common';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { DiscountsService } from './discounts.service.js';

/** Скидки и условия клиента (08 §4.11.6; `customers_discounts_get`; SCR-35; RM-G-003). */
@Controller('customers/:id/discounts')
export class CustomerDiscountsController {
  constructor(private readonly service: DiscountsService) {}

  @Get()
  @RequirePermission('discount.rules.read')
  @Header('Cache-Control', 'no-store')
  get(@Req() req: RequestWithContext, @Param('id') id: string): Promise<Record<string, unknown>> {
    return this.service.customerDiscounts(req, id);
  }
}

/** Применимые правила и потолок роли (08 §4.12.2; `discounts_rules_get`; RM-G-003). */
@Controller('discounts')
export class DiscountRulesController {
  constructor(private readonly service: DiscountsService) {}

  @Get('rules')
  @RequirePermission('discount.rules.read')
  @Header('Cache-Control', 'private, max-age=60')
  rules(@Req() req: RequestWithContext, @Query() query: Record<string, unknown>): Promise<Record<string, unknown>> {
    return this.service.rules(req, query);
  }
}

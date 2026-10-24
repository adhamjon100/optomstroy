import { Controller, Get, Header, Param, Query, Req } from '@nestjs/common';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { RequireAnyPermission } from '../../common/rbac/rbac.decorators.js';
import { CustomerAccessService } from '../common/customer-access.js';
import { customerIdParam, dateQuery, invalid, limitQuery, NO_STORE, oneQuery } from '../common/customer-http.js';
import {
  CustomerHistoryService,
  HISTORY_LIMIT_DEFAULT,
  HISTORY_LIMIT_MAX,
  type HistorySource,
} from './customer-history.service.js';

/**
 * `GET /customers/{id}/orders` — история покупок клиента (08 §4.11.4; OpenAPI `customers_orders_list`; SCR-33).
 * `Cache-Control: no-store`. Владелец маршрута — `customers` (RM-G-001; перенос из `orders` этапа F, GQ-FND-08).
 */
@Controller('customers')
export class CustomerHistoryController {
  constructor(
    private readonly service: CustomerHistoryService,
    private readonly access: CustomerAccessService,
  ) {}

  @Get(':id/orders')
  @Header('Cache-Control', NO_STORE)
  @RequireAnyPermission('customer.history.read', 'customer.self.read')
  async history(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Query() q: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    const v = this.access.viewer(req.principal);
    const customerId = customerIdParam(id);
    const source = (oneQuery(q, 'source') ?? 'all') as HistorySource;
    if (!['pos', 'onec', 'all'].includes(source)) invalid('source', 'enum', 'Допустимо: pos, onec, all.');
    const from = dateQuery(q, 'from');
    const to = dateQuery(q, 'to');
    const limit = limitQuery(q, HISTORY_LIMIT_DEFAULT, HISTORY_LIMIT_MAX);
    const cursor = oneQuery(q, 'cursor');
    return this.service.history(v, auditContextFromRequest(req), customerId, {
      source,
      limit,
      ...(from ? { from } : {}),
      ...(to ? { to } : {}),
      ...(cursor !== undefined ? { cursor } : {}),
    });
  }
}

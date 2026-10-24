import { Controller, Get, Header, Query, Req } from '@nestjs/common';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { CustomerAccessService } from '../common/customer-access.js';
import { boolQuery, forbidden, invalid, limitQuery, NO_STORE, oneQuery } from '../common/customer-http.js';
import {
  CustomerSearchService,
  SEARCH_CUSTOMERS_LIMIT_DEFAULT,
  SEARCH_CUSTOMERS_LIMIT_MAX,
} from './customer-search.service.js';

/**
 * `GET /search/customers` (08 §4.5.4; OpenAPI `search_customers_list`) — поле «Введите имя, телефон или часть
 * имени…» (SCR-21/31), `CustomerPicker`. Право `search.customers` (`customer` → 403); `Cache-Control: no-store`
 * (ПДн). Владелец маршрута — `customers` (RM-G-001; перенос из `cart` этапа F, GQ-FND-08).
 */
@Controller('search')
export class CustomerSearchController {
  constructor(
    private readonly service: CustomerSearchService,
    private readonly access: CustomerAccessService,
  ) {}

  @Get('customers')
  @Header('Cache-Control', NO_STORE)
  @RequirePermission('search.customers')
  async search(@Req() req: RequestWithContext, @Query() q: Record<string, unknown>): Promise<Record<string, unknown>> {
    const v = this.access.viewer(req.principal);
    if (v.isCustomer) forbidden();
    const text = oneQuery(q, 'q');
    if (text === undefined || text.trim() === '') invalid('q', 'required', 'Параметр q обязателен.');
    const favorite = boolQuery(q, 'favorite') ?? false;
    const include = oneQuery(q, 'include');
    if (include !== undefined && include !== 'receivable') invalid('include', 'enum', 'include — receivable.');
    const limit = limitQuery(q, SEARCH_CUSTOMERS_LIMIT_DEFAULT, SEARCH_CUSTOMERS_LIMIT_MAX);
    const cursor = oneQuery(q, 'cursor');
    const page = await this.service.search(v, auditContextFromRequest(req), {
      q: text,
      favorite,
      includeReceivable: include === 'receivable',
      limit,
      ...(cursor !== undefined ? { cursor } : {}),
    });
    return { ...page };
  }
}

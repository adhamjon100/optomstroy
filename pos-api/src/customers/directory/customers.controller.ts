import { Body, Controller, Get, Header, HttpCode, Param, Post, Query, Req, Res } from '@nestjs/common';
import type { Response } from 'express';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { CUSTOMER_TYPE_VALUES, type CustomerType } from '../../common/enums.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { RequireAnyPermission, RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { CustomerLinksService, QUEUE_DEFAULT_LIMIT, QUEUE_MAX_LIMIT } from '../links/customer-links.service.js';
import { CustomerAccessService } from '../common/customer-access.js';
import {
  boolQuery,
  csvQuery,
  customerIdParam,
  forbidden,
  invalid,
  limitQuery,
  NO_STORE,
  oneQuery,
} from '../common/customer-http.js';
import { CARD_INCLUDES, CustomerCardService } from './customer-card.service.js';
import { CustomerCreateService, parseCreateBody } from './customer-create.service.js';
import {
  CUSTOMERS_LIMIT_DEFAULT,
  CUSTOMERS_LIMIT_MAX,
  CustomersListService,
  type CustomersSort,
} from './customers-list.service.js';

/**
 * Клиенты (08 §4.11.1–§4.11.3; OpenAPI `customers_list`, `customers_create`, `customers_get`; RM-G-001, RM-G-011,
 * RM-G-014). `GET /customers?linkStatus=` — очередь привязок SCR-45 (`CustomerLinksService.listQueue`, этап D;
 * только `customer.link.conflicts.read`, иначе 403); без `linkStatus` — список клиентов. Все ответы —
 * `Cache-Control: no-store` (ПДн).
 */
@Controller('customers')
export class CustomersController {
  constructor(
    private readonly access: CustomerAccessService,
    private readonly list: CustomersListService,
    private readonly cards: CustomerCardService,
    private readonly creator: CustomerCreateService,
    private readonly links: CustomerLinksService,
  ) {}

  @Get()
  @Header('Cache-Control', NO_STORE)
  @RequireAnyPermission('customer.read.basic', 'customer.link.conflicts.read')
  async listCustomers(
    @Req() req: RequestWithContext,
    @Query() q: Record<string, unknown>,
  ): Promise<{ items: Record<string, unknown>[]; nextCursor: string | null; hasMore: boolean }> {
    const v = this.access.viewer(req.principal);
    if (v.isCustomer) forbidden();
    if (q.linkStatus !== undefined) {
      if (!v.permissions.has('customer.link.conflicts.read')) forbidden();
      const statuses = csvQuery(q, 'linkStatus', ['proposed', 'conflict'] as const, 2);
      if (statuses.length === 0) invalid('linkStatus', 'enum', 'Допустимо: proposed, conflict.');
      const limit = limitQuery(q, QUEUE_DEFAULT_LIMIT, QUEUE_MAX_LIMIT);
      return this.links.listQueue(statuses, limit, oneQuery(q, 'cursor') ?? null);
    }
    if (!v.permissions.has('customer.read.basic')) forbidden();
    const sort = (oneQuery(q, 'sort') ?? 'name:asc') as CustomersSort;
    if (sort !== 'name:asc' && sort !== 'lastOrderAt:desc')
      invalid('sort', 'sort_field', 'sort: name:asc или lastOrderAt:desc.');
    const customerType = oneQuery(q, 'customerType');
    if (customerType !== undefined && !(CUSTOMER_TYPE_VALUES as readonly string[]).includes(customerType)) {
      invalid('customerType', 'enum', 'customerType: individual, entrepreneur или legal.');
    }
    const include = oneQuery(q, 'include');
    if (include !== undefined && include !== 'receivable') invalid('include', 'enum', 'include — receivable.');
    const text = oneQuery(q, 'q');
    const favorite = boolQuery(q, 'favorite');
    const hasDebt = boolQuery(q, 'hasDebt');
    const isOverdue = boolQuery(q, 'isOverdue');
    const cursor = oneQuery(q, 'cursor');
    return this.list.list(v, auditContextFromRequest(req), {
      sort,
      limit: limitQuery(q, CUSTOMERS_LIMIT_DEFAULT, CUSTOMERS_LIMIT_MAX),
      includeReceivable: include === 'receivable',
      ...(text !== undefined ? { q: text } : {}),
      ...(favorite !== undefined ? { favorite } : {}),
      ...(hasDebt !== undefined ? { hasDebt } : {}),
      ...(isOverdue !== undefined ? { isOverdue } : {}),
      ...(customerType !== undefined ? { customerType: customerType as CustomerType } : {}),
      ...(cursor !== undefined ? { cursor } : {}),
    });
  }

  @Get(':id')
  @Header('Cache-Control', NO_STORE)
  @RequireAnyPermission('customer.read.basic', 'customer.self.read')
  async getCustomer(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Query() q: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    const v = this.access.viewer(req.principal);
    const customerId = customerIdParam(id);
    const include = csvQuery(q, 'include', CARD_INCLUDES, 4);
    return this.cards.card(
      v,
      auditContextFromRequest(req),
      customerId,
      include,
      typeof req.id === 'string' ? req.id : null,
    );
  }

  @Post()
  @HttpCode(201)
  @RequirePermission('customer.create')
  @Idempotent({ required: true })
  async createCustomer(
    @Req() req: RequestWithContext,
    @Body() body: unknown,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Record<string, unknown>> {
    res.setHeader('Cache-Control', NO_STORE);
    const v = this.access.viewer(req.principal);
    if (v.isCustomer) forbidden();
    const input = parseCreateBody(body);
    const requestId = typeof req.id === 'string' ? req.id : null;
    const ctx = auditContextFromRequest(req);
    const { id } = await this.creator.create(v, ctx, input, requestId);
    return this.cards.render(v, ctx, id, [], requestId);
  }
}

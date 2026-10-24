import {
  Body,
  Controller,
  Get,
  Header,
  Headers,
  HttpCode,
  Param,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import { CurrentUser } from '../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { Idempotent } from '../common/idempotency/idempotent.decorator.js';
import { RequireAnyPermission, RequirePermission } from '../common/rbac/rbac.decorators.js';
import { CustomerModeGuard } from './customer-mode.guard.js';
import { OrderCancelService } from './order-cancel.service.js';
import { OrderCreateService } from './order-create.service.js';
import { OrderOnecLinkService } from './order-onec-link.service.js';
import { OrderQueryService } from './order-query.service.js';
import { OrderViewService } from './order-view.service.js';

const STEP_UP_HEADER = 'x-step-up-token';

type Req = RequestWithContext & { ip?: string };

interface StatusResponse {
  status(code: number): unknown;
  setHeader(name: string, value: string): unknown;
}

/**
 * API модуля `orders` (08 §4.8; OpenAPI `orders_create`, `orders_list`, `orders_get`, `orders_cancel`,
 * `orders_onec_link`; RM-F-002, RM-F-012, RM-F-015). Права — 11 §4.3–§4.4 (guard + проверки «own» в сервисах).
 * Режим клиента (RM-G-014): при `CUSTOMER_SELF_SERVICE=false` запросы `customer` → 403 (`CustomerModeGuard`).
 */
@Controller('orders')
@UseGuards(CustomerModeGuard)
export class OrdersController {
  constructor(
    private readonly creator: OrderCreateService,
    private readonly query: OrderQueryService,
    private readonly views: OrderViewService,
    private readonly canceller: OrderCancelService,
    private readonly linker: OrderOnecLinkService,
  ) {}

  /** `POST /orders` → `201` (проверка 1С выполнена) или `202` + `Location` + `warnings[STALE_DATA]`. */
  @Post()
  @RequirePermission('order.create')
  @Idempotent({ required: true })
  @Header('Cache-Control', 'no-store')
  async create(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: Req,
    @Res({ passthrough: true }) res: StatusResponse,
    @Headers(STEP_UP_HEADER) stepUpToken: string | undefined,
    @Body() body: unknown,
  ): Promise<Record<string, unknown>> {
    const r = await this.creator.createHttp(principal, req, body, stepUpToken);
    res.status(r.httpStatus);
    if (r.httpStatus === 202) res.setHeader('Location', `/api/v1/orders/${r.orderId}`);
    return r.body;
  }

  @Get()
  @RequireAnyPermission('order.read.own', 'order.read.all')
  @Header('Cache-Control', 'no-store')
  async list(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: Req,
    @Query() q: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    const viewer = await this.views.viewer(principal, typeof req.id === 'string' ? req.id : null);
    return this.query.list(viewer, this.query.parseListQuery(q, viewer));
  }

  @Get(':id')
  @RequireAnyPermission('order.read.own', 'order.read.all')
  @Header('Cache-Control', 'no-store')
  async get(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: Req,
    @Param('id') id: string,
    @Query() q: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    const viewer = await this.views.viewer(principal, typeof req.id === 'string' ? req.id : null);
    return this.query.get(viewer, id, q);
  }

  @Post(':id/cancel')
  @HttpCode(200)
  @RequireAnyPermission('order.cancel.own', 'order.cancel.request.any')
  @Idempotent({ required: true })
  @Header('Cache-Control', 'no-store')
  cancel(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: Req,
    @Param('id') id: string,
    @Headers(STEP_UP_HEADER) stepUpToken: string | undefined,
    @Body() body: unknown,
  ): Promise<Record<string, unknown>> {
    return this.canceller.cancel(principal, req, id, body, stepUpToken);
  }

  @Post(':id/onec-link')
  @HttpCode(200)
  @RequirePermission('order.onec_link')
  @Idempotent({ required: true })
  @Header('Cache-Control', 'no-store')
  onecLink(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: Req,
    @Param('id') id: string,
    @Headers(STEP_UP_HEADER) stepUpToken: string | undefined,
    @Body() body: unknown,
  ): Promise<Record<string, unknown>> {
    return this.linker.link(principal, req, id, body, stepUpToken);
  }
}

import { Controller, Get, Header, HttpCode, Param, Post, Query, Req, Res } from '@nestjs/common';
import type { Response } from 'express';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { RequireAnyPermission, RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { ReceivablesService } from './receivables.service.js';

function dataAsOf(res: Response, body: Record<string, unknown>): Record<string, unknown> {
  if (typeof body.asOf === 'string') res.setHeader('X-Data-As-Of', body.asOf);
  return body;
}

/**
 * Долг клиента (08 §4.11.5, §4.11.8; contracts/openapi `customers_receivables_get`,
 * `customers_receivables_refresh`; RM-G-002, RM-G-011). Финансовые данные — `Cache-Control: no-store`, заголовок
 * `X-Data-As-Of` — метка снимка 1С. Порядок проверок: Auth (401) → RBAC (403) → параметры (400) → step-up детализации
 * (403 STEP_UP_REQUIRED) → лимит RL-RECV-REFRESH (429) → клиент (404) → идентификация в 1С (422) → 1С (503).
 */
@Controller('customers/:id/receivables')
export class ReceivablesController {
  constructor(private readonly service: ReceivablesService) {}

  @Get()
  @RequireAnyPermission('customer.receivables.read.summary', 'customer.self.receivables.read')
  @Header('Cache-Control', 'no-store')
  async get(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Query() query: Record<string, unknown>,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Record<string, unknown>> {
    return dataAsOf(res, (await this.service.view(req, id, query)).body);
  }

  @Post('refresh')
  @HttpCode(200)
  @RequirePermission('customer.receivables.read.summary')
  // 08 §4.11.8: Idempotency-Key не требуется, но допускается по общему правилу (повтор → тот же ответ).
  @Idempotent({ required: false })
  @Header('Cache-Control', 'no-store')
  async refresh(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Query() query: Record<string, unknown>,
    @Res({ passthrough: true }) res: Response,
  ): Promise<Record<string, unknown>> {
    return dataAsOf(res, (await this.service.refresh(req, id, query)).body);
  }
}

/** Просроченные долги (08 §4.12.1; `receivables_overdue_list`; DEBT-007). */
@Controller('receivables')
export class ReceivablesOverdueController {
  constructor(private readonly service: ReceivablesService) {}

  @Get('overdue')
  @RequirePermission('customer.receivables.read.summary')
  @Header('Cache-Control', 'no-store')
  overdue(@Req() req: RequestWithContext, @Query() query: Record<string, unknown>): Promise<Record<string, unknown>> {
    return this.service.overdue(req, query);
  }
}

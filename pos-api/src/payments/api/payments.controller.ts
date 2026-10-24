import { Body, Controller, Get, Headers, HttpCode, Param, Post, Query, Req, Res, UseGuards } from '@nestjs/common';
import type { Response } from 'express';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { CurrentUser } from '../../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { isUuid } from '../../common/ids/uuid.js';
import { IDEMPOTENCY_KEY_HEADER, Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { RequireAnyPermission, RequirePermission } from '../../common/rbac/rbac.decorators.js';
import type { PaymentsCaller } from '../app/payments-caller.js';
import { type OrderPaymentResultDto, PaymentsService } from '../app/payments.service.js';
import type { AllowedAction, PaymentDto } from '../app/payment-presenter.js';
import { MAX_WAIT_SECONDS } from '../long-poll/payment-status-waiter.js';
import { OrdersPaymentCreateRequest, PaymentsConfirmManualRequest, PaymentsVoidRequest } from './payments.dto.js';
import { CustomerModeGuard } from './customer-mode.guard.js';
import { PaymentsStepUpGuard, paymentsStepUpOf, RequirePaymentsStepUp } from './payments-step-up.guard.js';

function uuidParam(value: string, field: string): string {
  if (!isUuid(value)) {
    throw new ProblemException('VALIDATION_FAILED', {
      status: 400,
      detail: 'Неверный идентификатор.',
      errors: [{ field, rule: 'uuid', message: 'Ожидается UUID.' }],
    });
  }
  return value.toLowerCase();
}

function parseWait(raw: string | undefined): number | undefined {
  if (raw === undefined || raw === '') return undefined;
  if (!/^\d{1,2}$/.test(raw) || Number(raw) < 1 || Number(raw) > MAX_WAIT_SECONDS) {
    throw new ProblemException('VALIDATION_FAILED', {
      status: 400,
      detail: `wait — целое число секунд 1…${MAX_WAIT_SECONDS}.`,
      errors: [{ field: 'wait', rule: 'range', message: `Допустимо 1…${MAX_WAIT_SECONDS}.` }],
    });
  }
  return Number(raw); // money-double: allow — секунды ожидания, не сумма
}

function parseBool(raw: string | undefined, field: string): boolean {
  if (raw === undefined || raw === '' || raw === 'false') return false;
  if (raw === 'true') return true;
  throw new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: `${field} — true или false.`,
    errors: [{ field, rule: 'boolean', message: 'Ожидается true или false.' }],
  });
}

/**
 * Платежи (08 §4.8.6, §4.9.2–§4.9.4; RM-F-003, RM-F-012, RM-F-016). Маршрут вебхука банка
 * `POST /payments/qr/webhook` в R1 **не регистрируется** (RM-F-014 — R2; ядро §24.4): запрос → 404.
 * `POST /payments` (оплата долга без заказа) — RM-G-013 (условно, Q-152), здесь не реализуется. Режим клиента
 * (RM-G-014): при `CUSTOMER_SELF_SERVICE=false` запросы `customer` → 403 (`CustomerModeGuard`).
 */
@Controller()
@UseGuards(CustomerModeGuard, PaymentsStepUpGuard)
export class PaymentsController {
  constructor(
    private readonly service: PaymentsService,
    private readonly catalog: PermissionCatalog,
  ) {}

  private caller(p: AuthenticatedPrincipal, req: RequestWithContext): PaymentsCaller {
    return {
      userId: p.userId,
      roles: p.roles,
      isCustomer: p.kind === 'customer',
      perms: this.catalog.effectivePermissions(p),
      audit: auditContextFromRequest(req),
      requestId: typeof req.id === 'string' ? req.id : null,
      sessionId: p.sessionId,
      deviceId: p.deviceId,
    };
  }

  @Get('orders/:id/payments')
  @RequireAnyPermission('order.read.own', 'order.read.all')
  async listForOrder(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ items: PaymentDto[] }> {
    res.setHeader('Cache-Control', 'no-store');
    return this.service.listForOrder(this.caller(principal, req), uuidParam(id, 'id'));
  }

  @Post('orders/:id/payments')
  @RequireAnyPermission('payment.cash.receive', 'payment.qr.show')
  @Idempotent({ required: true })
  async acceptForOrder(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Headers(IDEMPOTENCY_KEY_HEADER.toLowerCase()) idempotencyKey: string,
    @Body() body: OrdersPaymentCreateRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<OrderPaymentResultDto> {
    const r = await this.service.acceptForOrder(
      this.caller(principal, req),
      uuidParam(id, 'id'),
      body,
      idempotencyKey,
      req,
    );
    res.status(r.status);
    res.setHeader('Cache-Control', 'no-store');
    return r.body;
  }

  @Get('payments/:id')
  @RequireAnyPermission('payment.read.all', 'payment.read.own')
  async get(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Query('wait') waitRaw: string | undefined,
    @Query('refreshStatus') refreshRaw: string | undefined,
    @Res({ passthrough: true }) res: Response,
  ): Promise<PaymentDto & { allowedActions: AllowedAction[] }> {
    const paymentId = uuidParam(id, 'id');
    const waitSeconds = parseWait(waitRaw);
    const refreshStatus = parseBool(refreshRaw, 'refreshStatus');
    const ac = new AbortController();
    const onClose = () => {
      if (!res.writableFinished) ac.abort();
    };
    res.on('close', onClose);
    try {
      res.setHeader('Cache-Control', 'no-store');
      return await this.service.get(this.caller(principal, req), paymentId, {
        ...(waitSeconds !== undefined ? { waitSeconds } : {}),
        refreshStatus,
        signal: ac.signal,
      });
    } finally {
      res.off('close', onClose);
    }
  }

  @Post('payments/:id/confirm-manual')
  @HttpCode(200)
  @RequirePermission('payment.qr.confirm_manual')
  @RequirePaymentsStepUp('payment.qr.confirm_manual')
  @Idempotent({ required: true })
  async confirmManual(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Body() body: PaymentsConfirmManualRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<PaymentDto> {
    const stepUp = paymentsStepUpOf(req);
    if (!stepUp) throw new ProblemException('INTERNAL');
    res.setHeader('Cache-Control', 'no-store');
    return this.service.confirmManual(this.caller(principal, req), uuidParam(id, 'id'), body, stepUp, req);
  }

  @Post('payments/:id/void')
  @HttpCode(200)
  @RequirePermission('payment.void')
  @RequirePaymentsStepUp('payment.void')
  @Idempotent({ required: true })
  async voidPayment(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Body() body: PaymentsVoidRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<PaymentDto> {
    const stepUp = paymentsStepUpOf(req);
    if (!stepUp) throw new ProblemException('INTERNAL');
    res.setHeader('Cache-Control', 'no-store');
    return this.service.voidByUser(this.caller(principal, req), uuidParam(id, 'id'), body, stepUp, req);
  }
}

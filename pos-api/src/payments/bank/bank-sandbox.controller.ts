import { Body, Controller, Get, HttpCode, Inject, Param, Post, Query, Res } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { IsBoolean, IsOptional, IsString, Matches } from 'class-validator';
import type { Response } from 'express';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { MONEY_AMOUNT_RE } from '../../common/money/money.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequireAnyPermission, RequirePermission } from '../../common/rbac/rbac.decorators.js';
import {
  BANK_QR_API,
  BankApiError,
  type BankOperation,
  type BankQrApi,
} from '../../integrations/payments/bank/bank-qr-api.js';
import { type SandboxPayResult, SandboxBankQrApi } from '../../integrations/payments/bank/sandbox-bank-qr.api.js';
import {
  WEBHOOK_SIGNATURE_HEADER,
  WEBHOOK_TIMESTAMP_HEADER,
} from '../../integrations/payments/bank/webhook-signature.js';
import { BankWebhookService } from './bank-webhook.service.js';

/** IP «банка-песочницы» для allowlist вебхука: песочница доставляет вебхук внутри процесса pos-api. */
export const SANDBOX_WEBHOOK_SOURCE_IP = '127.0.0.1';

/** `SandboxBankPayRequest` (08 §4.9.6): сумма по умолчанию — сумма QR; `allowExpired` — оплатить истёкший QR. */
export class SandboxBankPayRequest {
  @IsOptional()
  @IsString()
  @Matches(MONEY_AMOUNT_RE, { message: 'amount — строка с двумя знаками после точки' })
  amount?: string;

  @IsOptional()
  @IsBoolean()
  allowExpired?: boolean;
}

export interface SandboxOperationDto {
  readonly operationId: string;
  readonly reference: string;
  readonly merchantOrderId: string | null;
  readonly amount: { readonly amount: string; readonly currency: 'KGS' };
  readonly paidAt: string;
}

export interface SandboxBankPayResponse {
  readonly operation: SandboxOperationDto;
  readonly webhook: {
    readonly delivered: boolean;
    readonly httpStatus: number | null;
    readonly result: string | null;
  };
}

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Служебные маршруты песочницы банка (08 §4.9.6, §4.9.7; ADR-123) — **только тестовый контур**: контроллер подключает
 * `BankQrHttpModule` при `QR_PROVIDER=bank`, `BANK_QR_ADAPTER=sandbox` и `APP_ENV≠prod` (при `prod` песочница —
 * отказ в старте). Защита: Bearer сотрудника и право `payment.qr.confirm_manual` (кассир, старший продавец) для
 * «оплаты»; список операций — также `reports.qr_reconciliation.read` (владелец, администратор).
 *
 * «Оплата» записывает операцию банка-песочницы и, если вебхук включён (`QR_WEBHOOK_ENABLED=true`), доставляет
 * **подписанный** вебхук в обработчик `BankWebhookService` внутри процесса — с проверкой IP (`127.0.0.1` должен быть в
 * `QR_WEBHOOK_ALLOWED_IPS`) и подписи по сырому телу, как от банка. Без вебхука оплату найдут опрос статуса,
 * `GET /payments/{id}?refreshStatus=true` и ежедневная сверка.
 */
@ApiTags('payments')
@Controller('sandbox/bank')
export class BankSandboxController {
  constructor(
    @Inject(BANK_QR_API) private readonly bank: BankQrApi | null,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly webhook: BankWebhookService,
  ) {}

  private sandbox(): SandboxBankQrApi {
    if (!(this.bank instanceof SandboxBankQrApi) || this.config.APP_ENV === 'prod') {
      throw new ProblemException('NOT_FOUND', { detail: 'Ресурс не найден.' });
    }
    return this.bank;
  }

  @ApiOperation({ operationId: 'sandbox_bank_qr_pay', summary: 'Песочница банка: оплатить QR (тестовый контур)' })
  @Post('qr/:reference/pay')
  @HttpCode(200)
  @RequirePermission('payment.qr.confirm_manual')
  async pay(
    @Param('reference') reference: string,
    @Body() body: SandboxBankPayRequest,
    @Res({ passthrough: true }) res: Response,
  ): Promise<SandboxBankPayResponse> {
    const sandbox = this.sandbox();
    res.setHeader('Cache-Control', 'no-store');
    let paid: SandboxPayResult;
    try {
      paid = sandbox.pay({
        reference: reference.trim(),
        amount: body.amount ?? null,
        allowExpired: body.allowExpired === true,
      });
    } catch (e) {
      if (e instanceof BankApiError) {
        if (e.httpStatus === 404) throw new ProblemException('NOT_FOUND', { detail: e.message });
        throw new ProblemException('VALIDATION_FAILED', {
          status: 422,
          detail: e.message,
          errors: [{ field: 'reference', rule: e.code.toLowerCase(), message: e.message }],
        });
      }
      throw e;
    }
    const operation = toDto(paid.operation);
    if (!paid.webhook || !this.webhook.enabled) {
      return { operation, webhook: { delivered: false, httpStatus: null, result: null } };
    }
    try {
      const r = await this.webhook.receive({
        rawBody: paid.webhook.rawBody,
        signature: paid.webhook.headers[WEBHOOK_SIGNATURE_HEADER],
        timestamp: paid.webhook.headers[WEBHOOK_TIMESTAMP_HEADER],
        ip: SANDBOX_WEBHOOK_SOURCE_IP,
      });
      return { operation, webhook: { delivered: true, httpStatus: 200, result: r.result } };
    } catch (e) {
      if (e instanceof ProblemException) {
        return { operation, webhook: { delivered: true, httpStatus: e.getStatus(), result: e.code } };
      }
      throw e;
    }
  }

  @ApiOperation({ operationId: 'sandbox_bank_operations', summary: 'Песочница банка: операции за день' })
  @Get('operations')
  @RequireAnyPermission('reports.qr_reconciliation.read', 'payment.qr.confirm_manual')
  async operations(
    @Query('day') dayRaw: string | undefined,
    @Res({ passthrough: true }) res: Response,
  ): Promise<{ day: string; items: SandboxOperationDto[] }> {
    const sandbox = this.sandbox();
    const day = dayRaw ?? new Date(this.clock.now().getTime() + 6 * 3600_000).toISOString().slice(0, 10);
    if (!DAY_RE.test(day) || Number.isNaN(Date.parse(`${day}T00:00:00+06:00`))) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'day — дата YYYY-MM-DD.',
        errors: [{ field: 'day', rule: 'date', message: 'Ожидается YYYY-MM-DD.' }],
      });
    }
    res.setHeader('Cache-Control', 'no-store');
    return { day, items: (await sandbox.listOperations(day)).map(toDto) };
  }
}

function toDto(op: BankOperation): SandboxOperationDto {
  return {
    operationId: op.operationId,
    reference: op.reference,
    merchantOrderId: op.merchantOrderId,
    amount: { amount: op.amount, currency: 'KGS' },
    paidAt: op.paidAt,
  };
}

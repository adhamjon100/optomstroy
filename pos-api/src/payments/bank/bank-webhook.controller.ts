import { Controller, Header, HttpCode, Post, Req } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import type { Request } from 'express';
import { Public } from '../../common/auth/auth.decorators.js';
import { readRawBody } from '../../common/http/raw-body.js';
import {
  WEBHOOK_SIGNATURE_HEADER,
  WEBHOOK_TIMESTAMP_HEADER,
} from '../../integrations/payments/bank/webhook-signature.js';
import { type BankWebhookAck, BankWebhookService } from './bank-webhook.service.js';

/** Предел тела вебхука (08 §2.1: ≤ 1 MB → 413). */
export const WEBHOOK_BODY_LIMIT_BYTES = 1024 * 1024;

function header(req: Request, name: string): string | undefined {
  const v = req.headers[name];
  const s = Array.isArray(v) ? v[0] : v;
  return typeof s === 'string' ? s : undefined;
}

/**
 * `POST /api/v1/payments/qr/webhook` — вебхук банка о зачислении (08 §4.9.5; ADR-123; 11 SEC-135). Контроллер
 * подключается модулем `BankQrHttpModule` **только** при `QR_PROVIDER=bank` и `QR_WEBHOOK_ENABLED=true`; иначе
 * маршрута нет (404). Без Bearer (вызывает банк): IP-allowlist и подпись по сырому телу — `BankWebhookService`.
 */
@ApiTags('payments')
@Controller('payments/qr')
export class BankWebhookController {
  constructor(private readonly webhook: BankWebhookService) {}

  @Public()
  @ApiOperation({ operationId: 'payments_qr_webhook', summary: 'Вебхук банка о зачислении (QR_PROVIDER=bank)' })
  @Post('webhook')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  async receive(@Req() req: Request & { id?: unknown }): Promise<BankWebhookAck> {
    const rawBody = await readRawBody(req, WEBHOOK_BODY_LIMIT_BYTES);
    const r = await this.webhook.receive({
      rawBody,
      signature: header(req, WEBHOOK_SIGNATURE_HEADER),
      timestamp: header(req, WEBHOOK_TIMESTAMP_HEADER),
      ip: req.ip ?? null,
      requestId: typeof req.id === 'string' ? req.id : null,
    });
    return r.ack;
  }
}

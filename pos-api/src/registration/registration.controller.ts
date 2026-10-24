import { Body, Controller, HttpCode, Post, Req } from '@nestjs/common';
import type { Request } from 'express';
import { auditContextFromRequest } from '../common/audit/audit-context.js';
import { Public } from '../common/auth/auth.decorators.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { IDEMPOTENCY_KEY_HEADER } from '../common/idempotency/idempotent.decorator.js';
import { isUuidV4Lower } from '../common/ids/uuid.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { RegistrationCompleteRequest } from './registration.dto.js';
import { type RegistrationResponse, RegistrationService } from './registration.service.js';

type Req = Request & RequestWithContext;

function header(req: Req, name: string): string | undefined {
  const v = req.headers[name.toLowerCase()];
  const s = Array.isArray(v) ? (v.length === 1 ? v[0] : undefined) : v;
  return typeof s === 'string' && s.trim() !== '' ? s.trim() : undefined;
}

function badHeader(field: string, rule: string, message: string): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: message,
    errors: [{ field, message, rule }],
  });
}

/**
 * Модуль D-06 `registration` (08 §4.2.1): `POST /registration/complete` — публичный (аутентификация —
 * `registrationToken` в теле); `Idempotency-Key` обязателен, скоуп `reg:<sha256(jti)>` обрабатывает
 * RegistrationService (перехватчик common/idempotency публичный маршрут без субъекта пропускает).
 * `GET /registration/customer-match` и `POST /registration/customer-match/confirm|reject` — у владельца привязок
 * (`customers/links`, CustomerMatchController, RM-D-005).
 */
@Controller('registration')
export class RegistrationController {
  constructor(private readonly registration: RegistrationService) {}

  @Public()
  @Post('complete')
  @HttpCode(201)
  complete(@Body() body: RegistrationCompleteRequest, @Req() req: Req): Promise<RegistrationResponse> {
    const deviceKey = header(req, 'X-Device-Id')?.toLowerCase();
    if (deviceKey === undefined || !isUuidV4Lower(deviceKey)) {
      throw badHeader('X-Device-Id', 'uuid', 'Заголовок X-Device-Id обязателен (UUID v4 устройства).');
    }
    const key = header(req, IDEMPOTENCY_KEY_HEADER);
    if (key === undefined) {
      throw badHeader(IDEMPOTENCY_KEY_HEADER, 'idempotency_key_required', 'Заголовок Idempotency-Key обязателен.');
    }
    if (!isUuidV4Lower(key)) {
      throw badHeader(IDEMPOTENCY_KEY_HEADER, 'idempotency_key_format', 'Idempotency-Key — UUID v4 в нижнем регистре.');
    }
    return this.registration.complete(body, {
      deviceKey,
      idempotencyKey: key,
      ctx: auditContextFromRequest(req),
      userAgent: header(req, 'User-Agent')?.slice(0, 256) ?? null,
    });
  }
}

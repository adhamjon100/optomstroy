import { Body, Controller, Post, Req, Res } from '@nestjs/common';
import type { Response } from 'express';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { CurrentUser } from '../../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { type AuthHttpRequest, clientIp, requestIdOf } from '../common/request.js';
import { StepUpDto } from './step-up.dto.js';
import { type StepUpOtpIssued, StepUpService, type StepUpTokenBody } from './step-up.service.js';

/** `POST /auth/step-up` (RM-D-003; 08 §4.1.7): 200 — `stepUpToken`; 202 — OTP шаг 1 (челлендж `purpose=step_up`). */
@Controller('auth')
export class StepUpController {
  constructor(private readonly stepUp: StepUpService) {}

  @RequirePermission('session.manage.own')
  @Post('step-up')
  async request(
    @Req() req: AuthHttpRequest,
    @Res({ passthrough: true }) res: Response,
    @CurrentUser() p: AuthenticatedPrincipal,
    @Body() body: StepUpDto,
  ): Promise<StepUpTokenBody | StepUpOtpIssued> {
    if (body.method === 'pin' && (body.challengeId !== undefined || body.code !== undefined)) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Запрос не прошёл проверку.',
        errors: [{ field: 'challengeId', message: 'Только для method=otp', rule: 'forbidden_field' }],
      });
    }
    if (body.method === 'otp' && body.pin !== undefined) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Запрос не прошёл проверку.',
        errors: [{ field: 'pin', message: 'Только для method=pin', rule: 'forbidden_field' }],
      });
    }
    const result = await this.stepUp.request({
      principal: p,
      method: body.method,
      operation: body.operation,
      ...(body.pin !== undefined ? { pin: body.pin } : {}),
      ...(body.challengeId !== undefined ? { challengeId: body.challengeId.toLowerCase() } : {}),
      ...(body.code !== undefined ? { code: body.code } : {}),
      ip: clientIp(req),
      requestId: requestIdOf(req),
      audit: auditContextFromRequest(req),
    });
    res.status(result.kind === 'otp' ? 202 : 200);
    return result.body;
  }
}

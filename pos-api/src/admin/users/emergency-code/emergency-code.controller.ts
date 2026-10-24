import { Body, Controller, Header, HttpCode, Param, Post, Req, UseGuards } from '@nestjs/common';
import type { RequestWithContext } from '../../../common/http/request-context.js';
import { RequirePermission } from '../../../common/rbac/rbac.decorators.js';
import { uuidParam } from '../shared/params.js';
import { AdminStepUpGuard, RequireStepUp } from '../shared/step-up.guard.js';
import { type EmergencyLoginCodeDto, EmergencyLoginCodeRequestDto } from './emergency-code.dto.js';
import { EmergencyLoginCodeService } from './emergency-code.service.js';
import { IgnoreIdempotencyKeyGuard } from './ignore-idempotency-key.guard.js';

/**
 * `POST /admin/users/{id}/emergency-login-code` (08 §4.18.10; contracts/openapi
 * `admin_users_emergency_login_code_issue`): `users.emergency_code.issue` (только `admin`), step-up — только метод
 * `pin`; `Idempotency-Key` игнорируется; `Cache-Control: no-store`.
 */
@Controller('admin/users')
@UseGuards(AdminStepUpGuard, IgnoreIdempotencyKeyGuard)
export class EmergencyLoginCodeController {
  constructor(private readonly service: EmergencyLoginCodeService) {}

  @Post(':id/emergency-login-code')
  @HttpCode(201)
  @Header('Cache-Control', 'no-store')
  @RequirePermission('users.emergency_code.issue')
  @RequireStepUp('users.emergency_code.issue', ['pin'])
  issue(
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Body() body: EmergencyLoginCodeRequestDto,
  ): Promise<EmergencyLoginCodeDto> {
    return this.service.issue(req, uuidParam(id), body);
  }
}

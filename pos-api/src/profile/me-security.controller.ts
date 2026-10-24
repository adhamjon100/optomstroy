import { Body, Controller, Delete, HttpCode, Post, Req, UseGuards } from '@nestjs/common';
import type { Request } from 'express';
import { auditContextFromRequest } from '../common/audit/audit-context.js';
import { CurrentUser } from '../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { getIdempotencyState } from '../common/idempotency/idempotency.context.js';
import { IdempotencyService } from '../common/idempotency/idempotency.service.js';
import { RequirePermission } from '../common/rbac/rbac.decorators.js';
import { type MePhoneChangeResult, type OtpChallengeIssuedDto, PhoneChangeService } from './phone-change.service.js';
import { PROFILE_STEP_UP } from './profile.constants.js';
import {
  MeBiometricsRequest,
  MePhoneChangeConfirmRequest,
  MePhoneChangeRequest,
  MePinSetRequest,
} from './profile.dto.js';
import { type MeBiometricsResponse, SecurityService } from './security.service.js';
import { ProfileStepUpGuard, RequireStepUp, StepUpResult, type StepUpOutcome } from './step-up/step-up.guard.js';

type Req = Request & RequestWithContext;

/**
 * Защита входа и номер телефона (08 §4.3.3, §4.3.5, §4.3.6): `POST|DELETE /me/pin`, `POST /me/biometrics`,
 * `POST /me/phone/change/request|confirm`. Step-up — ProfileStepUpGuard (до валидации тела).
 */
@Controller('me')
@UseGuards(ProfileStepUpGuard)
export class MeSecurityController {
  constructor(
    private readonly security: SecurityService,
    private readonly phone: PhoneChangeService,
    private readonly idempotency: IdempotencyService,
  ) {}

  @Post('pin')
  @HttpCode(204)
  @RequirePermission('profile.manage.own')
  @RequireStepUp({ operation: PROFILE_STEP_UP.pinSet, exemption: 'first_pin_otp_window' })
  async setPin(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Body() body: MePinSetRequest,
    @StepUpResult() stepUp: StepUpOutcome,
    @Req() req: Req,
  ): Promise<void> {
    await this.security.setPin(p, body.newPin, stepUp, auditContextFromRequest(req));
  }

  @Delete('pin')
  @HttpCode(204)
  @RequirePermission('profile.manage.own')
  // Только customer (D-48; contracts x-roles): staff получает 403 pin_required_for_staff сразу, без step-up.
  @RequireStepUp({ operation: PROFILE_STEP_UP.pinSet, when: (req) => req.principal?.kind === 'customer' })
  async deletePin(
    @CurrentUser() p: AuthenticatedPrincipal,
    @StepUpResult() stepUp: StepUpOutcome,
    @Req() req: Req,
  ): Promise<void> {
    await this.security.deletePin(p, stepUp, auditContextFromRequest(req));
  }

  /**
   * Не идемпотентна (решение A4 контракта): повтор `enabled=true` выдаёт новый токен. Если клиент всё же прислал
   * `Idempotency-Key`, захват ключа снимается — токен не попадает в `idempotency_keys` (07 §5.56).
   */
  @Post('biometrics')
  @HttpCode(200)
  @RequirePermission('profile.manage.own')
  @RequireStepUp({ operation: PROFILE_STEP_UP.biometricsToggle, exemption: 'otp_session_window' })
  async biometrics(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Body() body: MeBiometricsRequest,
    @StepUpResult() stepUp: StepUpOutcome,
    @Req() req: Req,
  ): Promise<MeBiometricsResponse> {
    const state = getIdempotencyState(req);
    if (state) {
      await this.idempotency.release(state.scope);
      state.recordedInTx = true;
    }
    return this.security.toggleBiometrics(p, body, stepUp, auditContextFromRequest(req));
  }

  @Post('phone/change/request')
  @HttpCode(202)
  @RequirePermission('profile.manage.own')
  @RequireStepUp({ operation: PROFILE_STEP_UP.phoneChange })
  requestPhoneChange(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Body() body: MePhoneChangeRequest,
    @StepUpResult() stepUp: StepUpOutcome,
    @Req() req: Req,
  ): Promise<OtpChallengeIssuedDto> {
    return this.phone.request(p, body.newPhone, stepUp, auditContextFromRequest(req));
  }

  @Post('phone/change/confirm')
  @HttpCode(200)
  @RequirePermission('profile.manage.own')
  confirmPhoneChange(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Body() body: MePhoneChangeConfirmRequest,
    @Req() req: Req,
  ): Promise<MePhoneChangeResult> {
    return this.phone.confirm(p, body.challengeId, body.code, auditContextFromRequest(req));
  }
}

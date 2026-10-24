import { Body, Controller, Get, HttpCode, Patch, Post, Put, Req, Res, UseGuards } from '@nestjs/common';
import type { Request, Response } from 'express';
import { auditContextFromRequest } from '../common/audit/audit-context.js';
import { CurrentUser } from '../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import {
  MIN_APP_VERSION_HEADER,
  RECOMMENDED_APP_VERSION_HEADER,
} from '../common/app-version/app-version.middleware.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { RequirePermission } from '../common/rbac/rbac.decorators.js';
import { type ConsentDto } from './consents/consents.service.js';
import { type MeConsentList, MeConsentsService } from './consents/me-consents.service.js';
import { type MeDto, MeService, type ProfileDto } from './me/me.service.js';
import type { SettingsDto } from './me/settings.projection.js';
import { PROFILE_STEP_UP } from './profile.constants.js';
import { MeConsentUpdateRequest, MeProfilePatchRequest, MeSettingsPutRequest } from './profile.dto.js';
import { ProfileService } from './profile.service.js';
import { ProfileStepUpGuard, RequireStepUp, StepUpResult, type StepUpOutcome } from './step-up/step-up.guard.js';

type Req = Request & RequestWithContext;

/** Версия из заголовка ответа (одна платформа `X-Platform` → одно значение; список платформ — не дублируется). */
function versionHeader(res: Response, name: string): string | undefined {
  const v = res.getHeader(name);
  return typeof v === 'string' && v !== '' && !v.includes('=') ? v : undefined;
}

/** Отзыв `personal_data` — со step-up `profile.consent.revoke` (08 §2.12, §4.3.7). */
function isPersonalDataRevocation(req: RequestWithContext): boolean {
  const b = req.body as { kind?: unknown; granted?: unknown } | undefined;
  return b?.kind === 'personal_data' && b.granted === false;
}

/**
 * Модуль `profile` (08 §4.3): `GET /me`, `PATCH /me/profile`, `PUT /me/settings`, `GET/POST /me/consents`. Право —
 * `profile.manage.own` (все роли и псевдо-набор `pending_activation`, 11 §4.2–§4.3); объект — только свой.
 */
@Controller('me')
@UseGuards(ProfileStepUpGuard)
export class MeController {
  constructor(
    private readonly me: MeService,
    private readonly profile: ProfileService,
    private readonly consents: MeConsentsService,
  ) {}

  @Get()
  @RequirePermission('profile.manage.own')
  async get(@CurrentUser() p: AuthenticatedPrincipal, @Res({ passthrough: true }) res: Response): Promise<MeDto> {
    const min = versionHeader(res, MIN_APP_VERSION_HEADER);
    const recommended = versionHeader(res, RECOMMENDED_APP_VERSION_HEADER);
    return this.me.build(p.userId, {
      sessionId: p.sessionId,
      deviceKey: p.deviceId,
      ...(min ? { appVersion: { min, recommended: recommended ?? null } } : {}),
    });
  }

  @Patch('profile')
  @RequirePermission('profile.manage.own')
  patchProfile(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Body() body: MeProfilePatchRequest,
    @Req() req: Req,
  ): Promise<ProfileDto> {
    return this.profile.patchProfile(p, body, auditContextFromRequest(req));
  }

  @Put('settings')
  @RequirePermission('profile.manage.own')
  putSettings(@CurrentUser() p: AuthenticatedPrincipal, @Body() body: MeSettingsPutRequest): Promise<SettingsDto> {
    return this.profile.putSettings(p, body);
  }

  @Get('consents')
  @RequirePermission('profile.manage.own')
  listConsents(@CurrentUser() p: AuthenticatedPrincipal): Promise<MeConsentList> {
    return this.consents.list(p);
  }

  @Post('consents')
  @HttpCode(200)
  @RequirePermission('profile.manage.own')
  @RequireStepUp({ operation: PROFILE_STEP_UP.consentRevoke, when: isPersonalDataRevocation })
  updateConsent(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Body() body: MeConsentUpdateRequest,
    @StepUpResult() stepUp: StepUpOutcome,
    @Req() req: Req,
  ): Promise<ConsentDto> {
    return this.consents.update(p, body, stepUp, auditContextFromRequest(req));
  }
}

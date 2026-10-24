import { Body, Controller, Delete, Get, HttpCode, Param, Patch, Post, Req } from '@nestjs/common';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { CurrentUser, Public } from '../../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { AuthHttpRateLimiter } from '../common/http-rate-limits.js';
import { type AuthHttpRequest, clientIp, headerValue, requireDeviceKey } from '../common/request.js';
import { RequireStepUp, type RequestWithStepUp } from '../step-up/step-up.guard.js';
import { StepUpService } from '../step-up/step-up.service.js';
import { RefreshService, type TokenPairBody } from './refresh.service.js';
import { LogoutDto, RefreshDto, SessionPatchDto, UnlockDto } from './sessions.dto.js';
import { type SessionDto, SessionsService } from './sessions.service.js';

/**
 * Сессии (RM-D-003; 08 §4.1.3–§4.1.6, §4.1.8; 09 §8): `refresh` и `unlock` — публичные (субъект — refresh +
 * `X-Device-Id`); остальное — Bearer, право `session.manage.own`.
 */
@Controller('auth')
export class SessionsController {
  constructor(
    private readonly refreshService: RefreshService,
    private readonly sessions: SessionsService,
    private readonly stepUp: StepUpService,
    private readonly limiter: AuthHttpRateLimiter,
  ) {}

  @Public()
  @Post('refresh')
  @HttpCode(200)
  async refresh(@Req() req: AuthHttpRequest, @Body() body: RefreshDto): Promise<TokenPairBody> {
    const deviceKey = requireDeviceKey(req);
    this.limiter.publicIp(clientIp(req));
    this.limiter.authDevice(deviceKey);
    return this.refreshService.rotate({
      refreshToken: body.refreshToken,
      deviceKey,
      mode: 'refresh',
      ip: clientIp(req),
      audit: auditContextFromRequest(req),
    });
  }

  @Public()
  @Post('unlock')
  @HttpCode(200)
  async unlock(@Req() req: AuthHttpRequest, @Body() body: UnlockDto): Promise<TokenPairBody> {
    const deviceKey = requireDeviceKey(req);
    this.limiter.publicIp(clientIp(req));
    this.limiter.authDevice(deviceKey);
    const method = body.method ?? 'pin';
    if (method === 'biometric' && (body.pin !== undefined || body.biometricInvalidated !== undefined)) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Запрос не прошёл проверку.',
        errors: [{ field: 'pin', message: 'Для method=biometric PIN не передаётся', rule: 'forbidden_field' }],
      });
    }
    return this.refreshService.rotate({
      refreshToken: body.refreshToken,
      deviceKey,
      mode: method === 'pin' ? 'unlock_pin' : 'unlock_biometric',
      ...(body.pin !== undefined ? { pin: body.pin } : {}),
      ...(body.biometricInvalidated !== undefined ? { biometricInvalidated: body.biometricInvalidated } : {}),
      ip: clientIp(req),
      audit: auditContextFromRequest(req),
    });
  }

  @RequirePermission('session.manage.own')
  @Post('logout')
  @HttpCode(204)
  async logout(
    @Req() req: AuthHttpRequest,
    @CurrentUser() p: AuthenticatedPrincipal,
    @Body() body: LogoutDto,
  ): Promise<void> {
    this.limiter.authDevice(p.deviceId);
    await this.sessions.logout(p, auditContextFromRequest(req), body?.reason);
  }

  @RequirePermission('session.manage.own')
  @RequireStepUp('session.logout_all')
  @Post('logout-all')
  @HttpCode(204)
  async logoutAll(@Req() req: RequestWithStepUp, @CurrentUser() p: AuthenticatedPrincipal): Promise<void> {
    this.limiter.authDevice(p.deviceId);
    if (!req.stepUp) throw StepUpService.required('session.logout_all');
    await this.sessions.logoutAll(p, req.stepUp, auditContextFromRequest(req));
  }

  @RequirePermission('session.manage.own')
  @Get('sessions')
  async list(@CurrentUser() p: AuthenticatedPrincipal): Promise<{ items: SessionDto[] }> {
    this.limiter.authDevice(p.deviceId);
    return this.sessions.list(p);
  }

  /** Текущая сессия = logout (без step-up); другая — step-up `session.revoke.other` (08 §4.1.6; ядро §17.2). */
  @RequirePermission('session.manage.own')
  @Delete('sessions/:sessionId')
  @HttpCode(204)
  async revoke(
    @Req() req: AuthHttpRequest,
    @CurrentUser() p: AuthenticatedPrincipal,
    @Param('sessionId') sessionId: string,
  ): Promise<void> {
    this.limiter.authDevice(p.deviceId);
    const { session } = await this.sessions.findOwn(p, sessionId);
    if (session.id === p.sessionId) {
      await this.sessions.logout(p, auditContextFromRequest(req));
      return;
    }
    const verified = await this.stepUp.verify(headerValue(req, 'x-step-up-token'), p, 'session.revoke.other');
    if (session.revokedAt !== null) return;
    await this.sessions.revokeOther(p, session, verified, auditContextFromRequest(req));
  }

  @RequirePermission('session.manage.own')
  @Patch('sessions/:sessionId')
  @HttpCode(200)
  async rename(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Param('sessionId') sessionId: string,
    @Body() body: SessionPatchDto,
  ): Promise<SessionDto> {
    this.limiter.authDevice(p.deviceId);
    return this.sessions.rename(p, sessionId, body.deviceName);
  }
}

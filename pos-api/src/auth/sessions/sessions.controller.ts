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
import { type HelloChallengeBody, HelloKeyChallengeService } from './hello-key-challenge.service.js';
import { RefreshService, type RotationMode, type TokenPairBody } from './refresh.service.js';
import { LogoutDto, RefreshDto, SessionPatchDto, UnlockChallengeDto, UnlockDto } from './sessions.dto.js';
import { type SessionDto, SessionsService } from './sessions.service.js';

/**
 * Сессии (RM-D-003; 08 §4.1.3–§4.1.6, §4.1.8, §4.1.10; 09 §8): `refresh`, `unlock` и `unlock/challenge` — публичные
 * (субъект — refresh + `X-Device-Id`); остальное — Bearer, право `session.manage.own`.
 */
@Controller('auth')
export class SessionsController {
  constructor(
    private readonly refreshService: RefreshService,
    private readonly sessions: SessionsService,
    private readonly stepUp: StepUpService,
    private readonly limiter: AuthHttpRateLimiter,
    private readonly helloChallenge: HelloKeyChallengeService,
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
    if (method !== 'pin' && (body.pin !== undefined || body.biometricInvalidated !== undefined)) {
      throw invalid('pin', `Для method=${method} PIN не передаётся`, 'forbidden_field');
    }
    // Сочетания полей входа по лицу (08 §4.1.8; решение A11 контракта): `signature` — только с `hello_key` и обязательна
    // для него, `helloKeyInvalidated` — только с `pin`.
    if (body.signature !== undefined && method !== 'hello_key') {
      throw invalid('signature', 'signature передаётся только с method=hello_key', 'method');
    }
    if (body.helloKeyInvalidated !== undefined && method !== 'pin') {
      throw invalid('helloKeyInvalidated', 'helloKeyInvalidated передаётся только с method=pin', 'method');
    }
    if (method === 'hello_key' && body.signature === undefined) {
      throw invalid('signature', 'Для method=hello_key нужна подпись challenge', 'required');
    }
    const modes: Record<typeof method, RotationMode> = {
      pin: 'unlock_pin',
      biometric: 'unlock_biometric',
      hello_key: 'unlock_hello_key',
    };
    return this.refreshService.rotate({
      refreshToken: body.refreshToken,
      deviceKey,
      mode: modes[method],
      ...(body.pin !== undefined ? { pin: body.pin } : {}),
      ...(body.biometricInvalidated !== undefined ? { biometricInvalidated: body.biometricInvalidated } : {}),
      ...(body.signature !== undefined ? { signature: body.signature } : {}),
      ...(body.helloKeyInvalidated !== undefined ? { helloKeyInvalidated: body.helloKeyInvalidated } : {}),
      ip: clientIp(req),
      audit: auditContextFromRequest(req),
    });
  }

  /**
   * `POST /auth/unlock/challenge` (08 §4.1.10; ADR-116): одноразовый challenge для подписи ключом Windows Hello. Лимиты —
   * RL-PUBLIC-IP и RL-PIN (`userId + deviceKey` сессии, общий с `/auth/unlock` — в сервисе).
   */
  @Public()
  @Post('unlock/challenge')
  @HttpCode(200)
  async unlockChallenge(@Req() req: AuthHttpRequest, @Body() body: UnlockChallengeDto): Promise<HelloChallengeBody> {
    const deviceKey = requireDeviceKey(req);
    this.limiter.publicIp(clientIp(req));
    return this.helloChallenge.issue({
      refreshToken: body.refreshToken,
      deviceKey,
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

function invalid(field: string, message: string, rule: string): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field, message, rule }],
  });
}

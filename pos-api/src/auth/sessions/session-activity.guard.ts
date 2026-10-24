import { type CanActivate, type ExecutionContext, Inject, Injectable, Logger, type Provider } from '@nestjs/common';
import { APP_GUARD, Reflector } from '@nestjs/core';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PUBLIC_ROUTE } from '../../common/rbac/rbac.decorators.js';
import { AuthPolicyService } from '../common/auth-policy.js';
import { type AuthHttpRequest, clientIp, routePath } from '../common/request.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { AppPinsRepository } from '../pin/app-pins.repository.js';
import { SessionStore } from './session-store.js';

const PIN_CACHE_TTL_MS = 60_000;
const MAX_ENTRIES = 20_000;

/**
 * Глобальный guard **после** AuthGuard (порядок: ReadOnlyGuard → AuthGuard → SessionActivityGuard → RbacGuard):
 *
 * 1. Ограниченная сессия сотрудника без PIN (08 §4.1.2, API-181; 09 REG-037; D-48): `staff` без строки `app_pins`
 *    — разрешены только `/me*`, `/auth/*`, `GET /settings/public`; прочее → 403 FORBIDDEN `reason: pin_not_set`.
 * 2. Активность access-токена: первый запрос с каждым `jti` отмечает `sessions.last_used_at` (признак «токен,
 *    выданный при ротации/входе, использовался» для reuse-detection 09 §8.3 и повтора verify §5.6) и продлевает
 *    `unlocked_until` (09 §8.8).
 * 3. Сессия входа по аварийному коду администратора (09 §6.13 п. 3: `amr=["admin_code"]` без `pin`): при
 *    установленном PIN и `unlocked_until <= now` (выдаётся `now()` при входе) любой запрос, кроме `/auth/*`, →
 *    401 UNLOCK_REQUIRED (второй фактор — `POST /auth/unlock {method: "pin"}`, после него `amr` содержит `pin`).
 */
@Injectable()
export class SessionActivityGuard implements CanActivate {
  private readonly logger = new Logger('auth');
  private readonly pinKnown = new Map<string, number>();
  private readonly touched = new Map<string, number>();

  constructor(
    private readonly reflector: Reflector,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly pins: AppPinsRepository,
    private readonly store: SessionStore,
    private readonly policy: AuthPolicyService,
    private readonly sessions: SessionsRepository,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    if (context.getType() !== 'http') return true;
    if (this.reflector.getAllAndOverride<boolean>(PUBLIC_ROUTE, [context.getHandler(), context.getClass()]) === true) {
      return true;
    }
    const req = context.switchToHttp().getRequest<AuthHttpRequest>();
    const p = req.principal;
    if (!isAuthenticatedPrincipal(p)) return true;
    const now = this.clock.now().getTime();

    if (p.kind === 'staff' && !isAllowedWithoutPin(req) && !(await this.hasPin(p.userId, now))) {
      this.logger.warn({ event: 'auth.pin_not_set', requestId: req.id }, 'auth.pin_not_set');
      throw new ProblemException('FORBIDDEN', {
        detail: 'Установите PIN, чтобы продолжить работу.',
        reason: 'pin_not_set',
      });
    }

    if (
      p.amr.includes('admin_code') &&
      !p.amr.includes('pin') &&
      !routePath(req).startsWith('/auth/') &&
      (await this.hasPin(p.userId, now))
    ) {
      const s = await this.sessions.findById(p.sessionId);
      if (!s || s.unlockedUntil === null || s.unlockedUntil.getTime() <= now) {
        this.logger.warn({ event: 'auth.unlock_required', reason: 'emergency_code', requestId: req.id }, 'unlock');
        throw new ProblemException('UNLOCK_REQUIRED', {
          detail: 'Разблокируйте приложение PIN-кодом.',
          reason: 'emergency_code',
        });
      }
    }

    if (!this.touched.has(p.jti)) {
      if (this.touched.size >= MAX_ENTRIES) this.prune(this.touched, now);
      this.touched.set(p.jti, p.tokenExpiresAt.getTime());
      await this.store.touchActivity(
        p.sessionId,
        new Date(now),
        this.policy.base().session.idleLockMinutes,
        clientIp(req),
      );
    }
    return true;
  }

  /** Сброс кэша «PIN установлен» (например, после `DELETE /admin/users/{id}/pin` — модуль admin). */
  forgetPin(userId: string): void {
    this.pinKnown.delete(userId);
  }

  private async hasPin(userId: string, now: number): Promise<boolean> {
    const until = this.pinKnown.get(userId);
    if (until !== undefined && until > now) return true;
    const exists = await this.pins.exists(userId);
    if (exists) {
      if (this.pinKnown.size >= MAX_ENTRIES) this.prune(this.pinKnown, now);
      this.pinKnown.set(userId, now + PIN_CACHE_TTL_MS);
    }
    return exists;
  }

  private prune(map: Map<string, number>, now: number): void {
    for (const [k, until] of map) if (until <= now) map.delete(k);
  }
}

function isAllowedWithoutPin(req: AuthHttpRequest): boolean {
  const path = routePath(req);
  if (path === '/me' || path.startsWith('/me/')) return true;
  if (path.startsWith('/auth/')) return true;
  return (req.method ?? 'GET').toUpperCase() === 'GET' && path === '/settings/public';
}

/**
 * Провайдер для `GLOBAL_PROVIDERS` app.module.ts — ставится сразу после `AUTH_APP_GUARD` (common/auth).
 * Файл app.module.ts — у владельца каркаса (RM-C-005).
 */
export const AUTH_SESSION_ACTIVITY_GUARD: Provider = { provide: APP_GUARD, useClass: SessionActivityGuard };

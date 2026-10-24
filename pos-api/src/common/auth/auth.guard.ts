import { type CanActivate, type ExecutionContext, Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { type RequestWithContext } from '../http/request-context.js';
import { isUuid } from '../ids/uuid.js';
import { ProblemException } from '../problem-details/problem.exception.js';
import { PUBLIC_ROUTE } from '../rbac/rbac.decorators.js';
import { AuthStateCache } from './auth-state.js';
import { CLOCK, type Clock } from './clock.js';
import { type AccessTokenClaims, JwtService, JwtVerificationError } from './jwt.service.js';
import type { AuthenticatedPrincipal } from './principal.js';

export interface AuthGuardOptions {
  /**
   * `X-Device-Id` обязателен на защищённых маршрутах (08 §2.2, API-052): нет/не UUID → 400 VALIDATION_FAILED
   * (`rule=uuid`); не совпадает с claim `deviceId` → 401 SESSION_REVOKED (08 §2.4). По умолчанию — true.
   */
  readonly requireDeviceHeader: boolean;
}

export const AUTH_GUARD_OPTIONS = Symbol('AUTH_GUARD_OPTIONS');
export const DEFAULT_AUTH_GUARD_OPTIONS: AuthGuardOptions = Object.freeze({ requireDeviceHeader: true });

type RejectCode = 'UNAUTHENTICATED' | 'SESSION_REVOKED' | 'TOKEN_STALE';

const DETAILS: Readonly<Record<RejectCode, string>> = {
  UNAUTHENTICATED: 'Требуется вход.',
  SESSION_REVOKED: 'Сессия завершена. Войдите снова.',
  TOKEN_STALE: 'Права доступа изменились. Обновите токен.',
};

/**
 * Аутентификация Bearer access-JWT (common/auth; 08 §2.2; 09 §8.1; 11 §3.3). Порядок глобальных guard'ов:
 * ReadOnlyGuard → **AuthGuard** → RbacGuard: AuthGuard заполняет `req.principal`, RbacGuard проверяет права по
 * `principal.roles`/`status` (permissions.yaml) — 401 всегда раньше 403 (08 §2.4).
 *
 * Проверки: `@Public()` → пропуск (токен не читается); Bearer → подпись/`kid`/`alg`/`iss`/`aud`/`exp` (JwtService)
 * → 401 UNAUTHENTICATED; `X-Device-Id` (см. AuthGuardOptions); снимок БД (кэш 60 с): пользователь существует и
 * `kind` совпадает (иначе UNAUTHENTICATED), статус `active|pending_activation`, сессия `sid` принадлежит `sub`, не
 * отозвана, не истекла, устройство сессии = `deviceId`, `jti` не в denylist (иначе 401 SESSION_REVOKED);
 * `permissionsVersion` токена = `users.permissions_version` (иначе 401 TOKEN_STALE).
 * Логи — только причина и requestId (без токена и claims ПДн, 11 SEC-062).
 */
@Injectable()
export class AuthGuard implements CanActivate {
  private readonly logger = new Logger('auth');
  private readonly options: AuthGuardOptions;

  constructor(
    private readonly reflector: Reflector,
    private readonly jwt: JwtService,
    private readonly state: AuthStateCache,
    @Inject(CLOCK) private readonly clock: Clock,
    @Optional() @Inject(AUTH_GUARD_OPTIONS) options?: AuthGuardOptions,
  ) {
    this.options = options ?? DEFAULT_AUTH_GUARD_OPTIONS;
  }

  async canActivate(context: ExecutionContext): Promise<boolean> {
    if (context.getType() !== 'http') return true;
    if (this.reflector.getAllAndOverride<boolean>(PUBLIC_ROUTE, [context.getHandler(), context.getClass()]) === true) {
      return true;
    }
    const req = context.switchToHttp().getRequest<RequestWithContext>();
    req.principal = undefined;

    const token = bearerToken(req.headers.authorization);
    if (token === undefined) this.reject(req, 'UNAUTHENTICATED', 'no_bearer');

    let claims: AccessTokenClaims;
    try {
      claims = await this.jwt.verifyAccess(token);
    } catch (e) {
      if (e instanceof JwtVerificationError) this.reject(req, 'UNAUTHENTICATED', `jwt_${e.reason}`);
      throw e;
    }

    const deviceHeader = singleHeader(req.headers['x-device-id']);
    if (deviceHeader === undefined || !isUuid(deviceHeader)) {
      if (this.options.requireDeviceHeader || deviceHeader !== undefined) {
        throw new ProblemException('VALIDATION_FAILED', {
          status: 400,
          detail: 'Заголовок X-Device-Id обязателен (UUID устройства).',
          errors: [{ field: 'X-Device-Id', message: 'Ожидается UUID устройства', rule: 'uuid' }],
        });
      }
    } else if (deviceHeader.toLowerCase() !== claims.deviceId.toLowerCase()) {
      this.reject(req, 'SESSION_REVOKED', 'device_mismatch');
    }

    const snap = await this.state.snapshot({ userId: claims.sub, sessionId: claims.sid, jti: claims.jti });
    // `jti` в denylist проверяется первым: снимок после `denyJti` может не содержать пользователя, а отказ обязан
    // быть SESSION_REVOKED (09 §8.6; D_spec_questions A-13).
    if (snap.jtiDenied) this.reject(req, 'SESSION_REVOKED', 'jti_denied');
    const user = snap.user;
    if (!user || user.kind !== claims.kind) this.reject(req, 'UNAUTHENTICATED', 'user_unknown');
    if (user.status !== 'active' && user.status !== 'pending_activation') {
      this.reject(req, 'SESSION_REVOKED', `user_${user.status}`);
    }
    const s = snap.session;
    const now = this.clock.now().getTime();
    if (!s || s.userId !== claims.sub) this.reject(req, 'SESSION_REVOKED', 'session_unknown');
    if (s.revokedAt !== null) this.reject(req, 'SESSION_REVOKED', 'session_revoked');
    if (s.expiresAt.getTime() <= now) this.reject(req, 'SESSION_REVOKED', 'session_expired');
    if (s.deviceKey !== null && s.deviceKey.toLowerCase() !== claims.deviceId.toLowerCase()) {
      this.reject(req, 'SESSION_REVOKED', 'session_device_mismatch');
    }
    if (claims.permissionsVersion !== user.permissionsVersion) this.reject(req, 'TOKEN_STALE', 'permissions_version');

    const principal: AuthenticatedPrincipal = {
      userId: claims.sub,
      kind: claims.kind,
      roles: claims.roles,
      status: user.status,
      sessionId: claims.sid,
      deviceId: claims.deviceId,
      jti: claims.jti,
      permissionsVersion: claims.permissionsVersion,
      amr: claims.amr,
      tokenExpiresAt: new Date(claims.exp * 1000),
      ...(claims.stepUpUntil !== undefined ? { stepUpUntil: new Date(claims.stepUpUntil * 1000) } : {}),
    };
    req.principal = principal;
    return true;
  }

  private reject(req: RequestWithContext, code: RejectCode, reason: string): never {
    this.logger.warn({ event: 'auth.rejected', requestId: req.id, code, reason }, 'auth.rejected');
    throw new ProblemException(code, { detail: DETAILS[code] });
  }
}

function singleHeader(v: string | string[] | undefined): string | undefined {
  if (Array.isArray(v)) return v.length === 1 ? v[0] : undefined;
  return v;
}

/** `Authorization: Bearer <token>` (схема без учёта регистра, RFC 6750 §2.1); иначе — undefined. */
export function bearerToken(header: string | string[] | undefined): string | undefined {
  const v = singleHeader(header);
  if (v === undefined) return undefined;
  const m = /^Bearer[ ]+([A-Za-z0-9._~+/-]+=*)$/i.exec(v.trim());
  return m?.[1];
}

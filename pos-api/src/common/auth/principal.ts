import type { Principal } from '../http/request-context.js';
import type { AmrValue, TokenKind } from './jwt.service.js';

/**
 * Субъект, установленный AuthGuard по проверенному access-JWT (`req.principal`). Расширяет `Principal`
 * (common/http) полями токена — их читают step-up, logout, аудит.
 */
export interface AuthenticatedPrincipal extends Principal {
  /**
   * Вид субъекта из claim `kind` (= `users.kind`, `SubjectKind` — 06 ARCH-065): `staff | customer | kiosk`, без
   * `integration`. Ветки по виду — исчерпывающим разбором subject-kind.ts, не двоичной проверкой.
   */
  readonly kind: TokenKind;
  readonly status: 'active' | 'pending_activation';
  readonly sessionId: string;
  /** `X-Device-Id` = claim `deviceId` = `devices.device_key`. */
  readonly deviceId: string;
  readonly jti: string;
  readonly permissionsVersion: number;
  readonly amr: readonly AmrValue[];
  readonly tokenExpiresAt: Date;
  readonly stepUpUntil?: Date;
}

export function isAuthenticatedPrincipal(p: Principal | undefined): p is AuthenticatedPrincipal {
  return p !== undefined && typeof (p as Partial<AuthenticatedPrincipal>).jti === 'string';
}

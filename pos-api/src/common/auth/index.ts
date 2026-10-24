export { AUTH_APP_GUARD, AuthCoreModule, JWT_KEY_RING, jwtKeyRingFromConfig } from './auth-core.module.js';
export { CurrentUser, Public, PUBLIC_ROUTE } from './auth.decorators.js';
export {
  AUTH_GUARD_OPTIONS,
  AuthGuard,
  type AuthGuardOptions,
  bearerToken,
  DEFAULT_AUTH_GUARD_OPTIONS,
} from './auth.guard.js';
export {
  AUTH_STATE_CACHE_TTL_MS,
  AUTH_STATE_READER,
  type AuthSessionState,
  type AuthSnapshot,
  type AuthSnapshotQuery,
  AuthStateCache,
  type AuthStateReader,
  type AuthUserState,
  type UserStatus,
} from './auth-state.js';
export { CLOCK, type Clock, FixedClock, systemClock } from './clock.js';
export {
  EPHEMERAL_KID,
  JWT_ALLOWED_ALGS,
  type JwtAlg,
  JwtKeyConfigError,
  type JwtKeyRing,
  type JwtKeySource,
  parseJwtKeyRing,
} from './jwt-keys.js';
export {
  type AccessTokenClaims,
  type AccessTokenInput,
  type AmrValue,
  type IssuedToken,
  JWT_AUDIENCE,
  JWT_ISSUER,
  type JwtFailureReason,
  JwtService,
  type JwtServiceOptions,
  JwtVerificationError,
  type PurposeTokenInput,
  type TokenKind,
  type TokenPurpose,
  type VerifiedPurposeToken,
} from './jwt.service.js';
export { type AuthenticatedPrincipal, isAuthenticatedPrincipal } from './principal.js';

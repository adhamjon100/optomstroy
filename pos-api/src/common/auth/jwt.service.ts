import { decodeProtectedHeader, errors as joseErrors, type JWTPayload, jwtVerify, SignJWT } from 'jose';
import { z } from 'zod';
import { newId } from '../ids/uuid.js';
import { RBAC_ROLES } from '../rbac/permissions.generated.js';
import { type Clock, systemClock } from './clock.js';
import { JWT_ALLOWED_ALGS, type JwtAlg, type JwtKeyRing } from './jwt-keys.js';

/** `iss`/`aud` access-JWT (09 §8.1; совпадают с scripts/issue_test_jwt.ts RM-C-008). */
export const JWT_ISSUER = 'optomstroy-pos';
export const JWT_AUDIENCE = 'optomstroy-api';
/** Предел длины компактного JWS (защита разбора; реальные токены < 1 КБ). */
export const JWT_MAX_LENGTH = 8192;
/** Допуск расхождения часов для `nbf`/`iat`/`exp`, секунд. */
export const JWT_CLOCK_TOLERANCE_SECONDS = 5;

export type TokenKind = 'staff' | 'customer';
export type AmrValue = 'sms' | 'pin' | 'bio' | 'admin_code';

const UUID = z.uuid();

/** Claims access-токена (09 §8.1; 08 §2.2, API-041). Без ПДн. */
export interface AccessTokenClaims {
  readonly sub: string;
  readonly kind: TokenKind;
  readonly roles: readonly string[];
  readonly permissionsVersion: number;
  /** `X-Device-Id` клиента (UUID v4) = `devices.device_key` (ядро §18.2 п. 3). */
  readonly deviceId: string;
  /** `sessions.id`. */
  readonly sid: string;
  readonly jti: string;
  readonly iat: number;
  readonly exp: number;
  readonly amr: readonly AmrValue[];
  /** Окончание step-up (unix, 09 §8.1 «опционально»). */
  readonly stepUpUntil?: number;
}

type AccessTokenGenerated = 'jti' | 'iat' | 'exp' | 'amr';

export interface AccessTokenInput extends Omit<AccessTokenClaims, AccessTokenGenerated> {
  readonly amr?: readonly AmrValue[];
}

export interface IssuedToken {
  readonly token: string;
  readonly jti: string;
  readonly issuedAt: Date;
  readonly expiresAt: Date;
  readonly kid: string;
}

/**
 * Назначения «токенов назначения» (не access): `step_up` — `stepUpToken` 15 мин, многоразовый в своей `scope`
 * (09 §8.8, ядро §18.2 п. 6); `registration` — `registration_token` 15 мин, одноразовый через token_denylist
 * (09 §7.3). Access-токен claim `purpose` не содержит; проверка access отвергает токен с `purpose`, проверка
 * назначения — токен без него или с другим (защита от подмены типа токена).
 */
export type TokenPurpose = 'step_up' | 'registration';

const RESERVED_CLAIMS = new Set(['iss', 'aud', 'sub', 'exp', 'iat', 'nbf', 'jti', 'purpose']);

export interface PurposeTokenInput {
  readonly sub?: string;
  readonly ttlSeconds: number;
  /** Дополнительные claims назначения (`sid`, `scope`, `method`, `deviceId`, `challengeId`…); без ПДн и секретов. */
  readonly claims?: Readonly<Record<string, unknown>>;
}

export interface VerifiedPurposeToken {
  readonly purpose: TokenPurpose;
  readonly sub: string | undefined;
  readonly jti: string;
  readonly iat: number;
  readonly exp: number;
  readonly claims: Readonly<JWTPayload>;
}

export type JwtFailureReason =
  | 'malformed'
  | 'alg_not_allowed'
  | 'unknown_kid'
  | 'signature'
  | 'expired'
  | 'not_yet_valid'
  | 'claims'
  | 'wrong_token_type';

/** Отказ проверки токена. Сообщение не содержит токен/claims (логи — 11 SEC-062). */
export class JwtVerificationError extends Error {
  override readonly name = 'JwtVerificationError';
  constructor(readonly reason: JwtFailureReason) {
    super(`jwt rejected: ${reason}`);
  }
}

const accessSchema = z
  .object({
    sub: UUID,
    kind: z.enum(['staff', 'customer']),
    roles: z
      .array(z.enum(RBAC_ROLES))
      .max(RBAC_ROLES.length)
      .refine((r) => new Set(r).size === r.length, 'roles: повторы'),
    permissionsVersion: z.number().int().min(1),
    deviceId: UUID,
    sid: UUID,
    jti: UUID,
    iat: z.number().int(),
    exp: z.number().int(),
    amr: z
      .array(z.enum(['sms', 'pin', 'bio', 'admin_code']))
      .min(1)
      .optional(),
    stepUpUntil: z.number().int().optional(),
  })
  .loose();

export interface JwtServiceOptions {
  /** `AUTH_ACCESS_TTL_SECONDS` (900 — D-12). */
  readonly accessTtlSeconds: number;
}

/**
 * Подпись и проверка JWT (common/auth; RM-D-003 п. 4; 09 §8.1; 11 §3.3). Только `jose`; проверка: allowlist
 * алгоритмов, `kid` из набора, `alg` = алгоритм ключа `kid`, подпись, `iss`, `aud`, `exp`, `nbf`, схема claims.
 * Отзыв (`jti` denylist, `sid`, `permissionsVersion`) — AuthGuard по данным БД.
 */
export class JwtService {
  constructor(
    private readonly ring: JwtKeyRing,
    private readonly options: JwtServiceOptions,
    private readonly clock: Clock = systemClock,
  ) {}

  get currentKid(): string | undefined {
    return this.ring.signing?.kid;
  }

  get accessTtlSeconds(): number {
    return this.options.accessTtlSeconds;
  }

  async signAccess(input: AccessTokenInput, ttlSeconds: number = this.options.accessTtlSeconds): Promise<IssuedToken> {
    const claims = accessSchema.parse({ ...input, jti: newId(), iat: 0, exp: 0, amr: input.amr ?? ['sms'] });
    const { sub, jti: _jti, iat: _iat, exp: _exp, ...rest } = claims;
    return this.sign(sub, rest, ttlSeconds);
  }

  async verifyAccess(token: string): Promise<AccessTokenClaims> {
    const payload = await this.verifyRaw(token);
    if (payload.purpose !== undefined) throw new JwtVerificationError('wrong_token_type');
    const parsed = accessSchema.safeParse(payload);
    if (!parsed.success) throw new JwtVerificationError('claims');
    const c = parsed.data;
    return {
      sub: c.sub,
      kind: c.kind,
      roles: c.roles,
      permissionsVersion: c.permissionsVersion,
      deviceId: c.deviceId,
      sid: c.sid,
      jti: c.jti,
      iat: c.iat,
      exp: c.exp,
      amr: c.amr ?? ['sms'],
      ...(c.stepUpUntil !== undefined ? { stepUpUntil: c.stepUpUntil } : {}),
    };
  }

  async signPurpose(purpose: TokenPurpose, input: PurposeTokenInput): Promise<IssuedToken> {
    const extra: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(input.claims ?? {})) {
      if (RESERVED_CLAIMS.has(k)) throw new Error(`signPurpose: claim «${k}» зарезервирован`);
      extra[k] = v;
    }
    if (input.sub !== undefined && !UUID.safeParse(input.sub).success) throw new Error('signPurpose: sub — UUID');
    return this.sign(input.sub, { ...extra, purpose }, input.ttlSeconds);
  }

  async verifyPurpose(token: string, purpose: TokenPurpose): Promise<VerifiedPurposeToken> {
    const payload = await this.verifyRaw(token);
    if (payload.purpose !== purpose) throw new JwtVerificationError('wrong_token_type');
    if (!UUID.safeParse(payload.jti).success || typeof payload.iat !== 'number' || typeof payload.exp !== 'number') {
      throw new JwtVerificationError('claims');
    }
    if (payload.sub !== undefined && !UUID.safeParse(payload.sub).success) throw new JwtVerificationError('claims');
    return {
      purpose,
      sub: payload.sub,
      jti: String(payload.jti),
      iat: payload.iat,
      exp: payload.exp,
      claims: payload,
    };
  }

  private async sign(
    sub: string | undefined,
    claims: Record<string, unknown>,
    ttlSeconds: number,
  ): Promise<IssuedToken> {
    const signing = this.ring.signing;
    if (!signing) throw new Error('JwtService: ключ подписи не настроен (JWT_PRIVATE_KEY_FILE)');
    if (!Number.isInteger(ttlSeconds) || ttlSeconds < 1 || ttlSeconds > 86_400) {
      throw new RangeError('JwtService: ttlSeconds — целое 1…86400');
    }
    const iat = Math.floor(this.clock.now().getTime() / 1000);
    const exp = iat + ttlSeconds;
    const jti = newId();
    const builder = new SignJWT(claims)
      .setProtectedHeader({ alg: signing.alg, typ: 'JWT', kid: signing.kid })
      .setIssuer(JWT_ISSUER)
      .setAudience(JWT_AUDIENCE)
      .setJti(jti)
      .setIssuedAt(iat)
      .setExpirationTime(exp);
    if (sub !== undefined) builder.setSubject(sub);
    const token = await builder.sign(signing.key);
    return { token, jti, issuedAt: new Date(iat * 1000), expiresAt: new Date(exp * 1000), kid: signing.kid };
  }

  private async verifyRaw(token: string): Promise<JWTPayload> {
    if (typeof token !== 'string' || token.length === 0 || token.length > JWT_MAX_LENGTH) {
      throw new JwtVerificationError('malformed');
    }
    if (!/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) {
      // В т. ч. `alg=none` с пустой подписью («header.payload.»).
      throw new JwtVerificationError(token.endsWith('.') ? 'alg_not_allowed' : 'malformed');
    }
    let header: ReturnType<typeof decodeProtectedHeader>;
    try {
      header = decodeProtectedHeader(token);
    } catch {
      throw new JwtVerificationError('malformed');
    }
    if (typeof header.alg !== 'string' || !(JWT_ALLOWED_ALGS as readonly string[]).includes(header.alg)) {
      throw new JwtVerificationError('alg_not_allowed');
    }
    if (header.typ !== undefined && header.typ !== 'JWT') throw new JwtVerificationError('wrong_token_type');
    const key = typeof header.kid === 'string' ? this.ring.verify.get(header.kid) : undefined;
    if (!key) throw new JwtVerificationError('unknown_kid');
    if (header.alg !== key.alg) throw new JwtVerificationError('alg_not_allowed');
    try {
      const { payload } = await jwtVerify(token, key.key, {
        algorithms: [key.alg satisfies JwtAlg],
        issuer: JWT_ISSUER,
        audience: JWT_AUDIENCE,
        currentDate: this.clock.now(),
        clockTolerance: JWT_CLOCK_TOLERANCE_SECONDS,
        requiredClaims: ['jti', 'iat', 'exp'],
      });
      return payload;
    } catch (e) {
      throw new JwtVerificationError(mapJoseError(e));
    }
  }
}

function mapJoseError(e: unknown): JwtFailureReason {
  if (e instanceof joseErrors.JWTExpired) return 'expired';
  if (e instanceof joseErrors.JWTClaimValidationFailed) return e.claim === 'nbf' ? 'not_yet_valid' : 'claims';
  if (e instanceof joseErrors.JWSSignatureVerificationFailed) return 'signature';
  if (e instanceof joseErrors.JOSEAlgNotAllowed) return 'alg_not_allowed';
  return 'malformed';
}

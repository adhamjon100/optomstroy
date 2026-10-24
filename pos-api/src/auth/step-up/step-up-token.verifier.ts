import { Inject, Injectable, Logger } from '@nestjs/common';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { JwtService, JwtVerificationError } from '../../common/auth/jwt.service.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { TokenDenylistRepository } from '../../users/token-denylist.repository.js';

/** Методы step-up R1 (08 §2.12; ядро §19.3): `pin`, `otp`; биометрия вторым фактором в R1 не принимается. */
export type StepUpTokenMethod = 'pin' | 'otp';

export interface VerifiedStepUpToken {
  readonly method: StepUpTokenMethod;
  readonly jti: string;
  readonly expiresAt: Date;
}

export interface StepUpTokenCheck {
  /** Значение `operation` (08 §2.12): должно входить в claim `scope` (массив). */
  readonly operation: string;
  /** Допустимые методы (по умолчанию `pin`, `otp`); аварийный код — только `pin` (08 §4.18.10). */
  readonly allowedMethods?: readonly StepUpTokenMethod[];
  /** Текст `detail` ответа 403 (по умолчанию — общий). */
  readonly detail?: string;
}

const DEFAULT_METHODS: readonly StepUpTokenMethod[] = ['pin', 'otp'];

/**
 * Единственная проверка `X-Step-Up-Token` (RM-D-003 п. 3; 08 §2.12; 09 §8.8; ядро §18.2 п. 6) для всех модулей:
 * auth (StepUpService/StepUpGuard), admin (AdminStepUpGuard), customers (StepUpVerifier), profile (через
 * StepUpService). Токен — JWT назначения `step_up` (JwtService.verifyPurpose), выданный `POST /auth/step-up`.
 * Принимается, только если одновременно: `sub` = субъект; claim `sid` = текущая сессия; claim `deviceId` (обязателен)
 * = `X-Device-Id`; claim `pv` = `permissionsVersion` субъекта (смена прав гасит прежний step-up без отзыва
 * сессий); `scope` — **массив**, содержащий `operation`; `method` ∈ разрешённых; `jti` не в `token_denylist`.
 * Иначе → `403 STEP_UP_REQUIRED {stepUp: {operation, allowedMethods}}`; причина — только в логе (без токена).
 * Ревью D-MN-01: прежние копии в admin/customers не проверяли `pv`, `deviceId`/`method` и принимали строковый `scope`.
 */
@Injectable()
export class StepUpTokenVerifier {
  private readonly logger = new Logger('auth.step_up');

  constructor(
    private readonly jwt: JwtService,
    private readonly denylist: TokenDenylistRepository,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  static required(
    operation: string,
    allowedMethods: readonly StepUpTokenMethod[] = DEFAULT_METHODS,
    detail = 'Требуется подтверждение операции.',
  ): ProblemException {
    return new ProblemException('STEP_UP_REQUIRED', {
      detail,
      stepUp: { operation, allowedMethods: [...allowedMethods] },
    });
  }

  async verify(
    token: string | readonly string[] | undefined,
    principal: AuthenticatedPrincipal,
    check: StepUpTokenCheck,
  ): Promise<VerifiedStepUpToken> {
    const methods = check.allowedMethods ?? DEFAULT_METHODS;
    const reject = (reason: string): never => {
      this.logger.warn({ event: 'auth.step_up.rejected', reason, operation: check.operation }, 'step_up rejected');
      throw StepUpTokenVerifier.required(check.operation, methods, check.detail);
    };
    const raw = typeof token === 'string' ? token : token?.[0];
    if (typeof raw !== 'string' || raw.trim() === '') return reject('missing');
    let v: Awaited<ReturnType<JwtService['verifyPurpose']>>;
    try {
      v = await this.jwt.verifyPurpose(raw.trim(), 'step_up');
    } catch (e) {
      if (e instanceof JwtVerificationError) return reject(e.reason);
      throw e;
    }
    const c = v.claims as Record<string, unknown>;
    if (v.sub !== principal.userId) return reject('sub');
    if (c.sid !== principal.sessionId) return reject('sid');
    if (typeof c.deviceId !== 'string' || c.deviceId.toLowerCase() !== principal.deviceId.toLowerCase()) {
      return reject('device');
    }
    if (typeof c.pv !== 'number' || c.pv !== principal.permissionsVersion) return reject('permissions_version');
    if (!Array.isArray(c.scope) || !c.scope.includes(check.operation)) return reject('scope');
    const method = c.method === 'pin' || c.method === 'otp' ? c.method : undefined;
    if (method === undefined || !methods.includes(method)) return reject('method');
    if (await this.denylist.isDenied(v.jti, this.clock.now())) return reject('denied');
    return { method, jti: v.jti, expiresAt: new Date(v.exp * 1000) };
  }
}

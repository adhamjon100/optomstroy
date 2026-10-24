import { type CanActivate, type ExecutionContext, Injectable, SetMetadata } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { StepUpTokenVerifier } from '../../../auth/step-up/step-up-token.verifier.js';
import { isAuthenticatedPrincipal } from '../../../common/auth/principal.js';
import type { RequestWithContext } from '../../../common/http/request-context.js';
import { ProblemException } from '../../../common/problem-details/problem.exception.js';
import type { PermissionCode } from '../../../common/rbac/permissions.generated.js';

/** Методы step-up R1 (08 §2.12; ядро §19.3): биометрия в R1 вторым фактором не принимается. */
export type StepUpMethodR1 = 'pin' | 'otp';

export interface StepUpRequirement {
  /** Значение `operation` (= код 11 §4.3 для админ-операций, 08 §2.12 таблица). */
  readonly operation: PermissionCode;
  /** Допустимые методы; по умолчанию `pin`, `otp`. Аварийный код — только `pin` (08 §4.18.10). */
  readonly allowedMethods?: readonly StepUpMethodR1[];
}

export const STEP_UP_REQUIREMENT = 'optomstroy:admin-step-up';
export const STEP_UP_HEADER = 'x-step-up-token';

/** Проверенный step-up текущего запроса (для `audit_logs.step_up_method`). */
export interface VerifiedStepUp {
  readonly operation: PermissionCode;
  readonly method: StepUpMethodR1;
  readonly jti: string;
  readonly expiresAt: Date;
}

const STEP_UP_STATE = Symbol.for('optomstroy.admin.step-up');

/** Операция требует `X-Step-Up-Token` с `scope`, включающей `operation` (08 §2.12; 11 SEC-033). */
export const RequireStepUp = (
  operation: PermissionCode,
  allowedMethods: readonly StepUpMethodR1[] = ['pin', 'otp'],
): MethodDecorator => SetMetadata(STEP_UP_REQUIREMENT, { operation, allowedMethods } satisfies StepUpRequirement);

export function verifiedStepUp(req: object): VerifiedStepUp | undefined {
  return (req as { [STEP_UP_STATE]?: VerifiedStepUp })[STEP_UP_STATE];
}

/**
 * Проверка `stepUpToken` для админ-операций (08 §2.12, 09 §8.8; ядро §18.2 п. 6). Подключается на уровне
 * контроллера (`@UseGuards`) и выполняется после глобальных Auth → RBAC: 401 и 403 FORBIDDEN всегда раньше
 * STEP_UP_REQUIRED, а ответ без step-up не раскрывает существование цели. Сама проверка токена — единая
 * `StepUpTokenVerifier` модуля auth (RM-D-003 п. 3; ревью D-MN-01): `sub`, `sid`, `deviceId`, `pv`, `scope`
 * (массив), `method` ∈ разрешённых, `token_denylist`.
 */
@Injectable()
export class AdminStepUpGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly tokens: StepUpTokenVerifier,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    if (context.getType() !== 'http') return true;
    const requirement = this.reflector.get<StepUpRequirement | undefined>(STEP_UP_REQUIREMENT, context.getHandler());
    if (!requirement) return true;
    const req = context.switchToHttp().getRequest<RequestWithContext>();
    const methods = requirement.allowedMethods ?? ['pin', 'otp'];
    const principal = req.principal;
    if (!isAuthenticatedPrincipal(principal)) {
      throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    }
    const verified = await this.tokens.verify(req.headers[STEP_UP_HEADER], principal, {
      operation: requirement.operation,
      allowedMethods: methods,
      detail: methods.includes('otp')
        ? 'Подтвердите операцию PIN-кодом или кодом из SMS.'
        : 'Подтвердите операцию PIN-кодом.',
    });
    (req as unknown as { [STEP_UP_STATE]?: VerifiedStepUp })[STEP_UP_STATE] = {
      operation: requirement.operation,
      method: verified.method,
      jti: verified.jti,
      expiresAt: verified.expiresAt,
    };
    return true;
  }
}

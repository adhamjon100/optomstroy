import { Injectable } from '@nestjs/common';
import { StepUpTokenVerifier } from '../../auth/step-up/step-up-token.verifier.js';
import type { AuditStepUpMethod } from '../../common/audit/audit.service.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';

export const STEP_UP_TOKEN_HEADER = 'x-step-up-token'; // check-secrets: allow — имя поля/заголовка, не секрет

export interface VerifiedStepUp {
  readonly jti: string;
  /** Фактор для `audit_logs.step_up_method` (09 §8.8): `pin` или `otp`. */
  readonly method: AuditStepUpMethod;
}

/**
 * Проверка `X-Step-Up-Token` для операции привязки клиента (08 §2.12; ядро §18.2 п. 6) — обёртка над единой
 * `StepUpTokenVerifier` модуля auth (RM-D-003 п. 3; ревью D-MN-01): `sub`, `sid`, `deviceId`, `pv`, `scope`
 * (массив), `method` (`pin`/`otp`), `token_denylist`. Нет токена или он не подходит → `403 STEP_UP_REQUIRED` c
 * `stepUp {operation, allowedMethods}`.
 */
@Injectable()
export class StepUpVerifier {
  constructor(private readonly tokens: StepUpTokenVerifier) {}

  async verify(
    principal: AuthenticatedPrincipal,
    token: string | string[] | undefined,
    operation: string,
  ): Promise<VerifiedStepUp> {
    const v = await this.tokens.verify(token, principal, { operation });
    return { jti: v.jti, method: v.method };
  }
}

import { type CanActivate, type ExecutionContext, Injectable, SetMetadata } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { StepUpTokenVerifier } from '../../auth/step-up/step-up-token.verifier.js';
import type { AuditStepUpMethod } from '../../common/audit/audit.service.js';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';

export type PaymentsStepUpOperation = 'payment.qr.confirm_manual' | 'payment.void';

const META = 'optomstroy:payments-step-up';
const STATE = Symbol.for('optomstroy.payments.step-up');
export const STEP_UP_HEADER = 'x-step-up-token'; // check-secrets: allow — имя заголовка, не секрет

/** Маршрут требует `X-Step-Up-Token` операции (08 §2.12; 11 §4.3 №18, №19 — S!). */
export const RequirePaymentsStepUp = (operation: PaymentsStepUpOperation): MethodDecorator =>
  SetMetadata(META, operation);

export interface PaymentsStepUp {
  readonly operation: PaymentsStepUpOperation;
  readonly method: AuditStepUpMethod;
  readonly jti: string;
}

export function paymentsStepUpOf(req: object): PaymentsStepUp | undefined {
  return (req as { [STATE]?: PaymentsStepUp })[STATE];
}

/**
 * Step-up кассовых операций (ручное подтверждение QR, ручной void). Выполняется после глобальных Auth → RBAC
 * (403 FORBIDDEN раньше STEP_UP_REQUIRED) и до pipes (403 раньше 400 VALIDATION_FAILED, 08 §2.4) и интерсептора
 * идемпотентности (ключ не захватывается — повтор с тем же ключом после step-up). Проверка токена — единая
 * `StepUpTokenVerifier` модуля auth (`sub`, `sid`, `deviceId`, `pv`, `scope`, `method`, denylist).
 */
@Injectable()
export class PaymentsStepUpGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly tokens: StepUpTokenVerifier,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    if (context.getType() !== 'http') return true;
    const operation = this.reflector.get<PaymentsStepUpOperation | undefined>(META, context.getHandler());
    if (!operation) return true;
    const req = context.switchToHttp().getRequest<RequestWithContext>();
    const principal = req.principal;
    if (!isAuthenticatedPrincipal(principal)) {
      throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    }
    const v = await this.tokens.verify(req.headers[STEP_UP_HEADER], principal, {
      operation,
      allowedMethods: ['pin', 'otp'],
      detail: 'Подтвердите кассовую операцию PIN-кодом или кодом из SMS.',
    });
    (req as unknown as { [STATE]?: PaymentsStepUp })[STATE] = { operation, method: v.method, jti: v.jti };
    return true;
  }
}

import { type CanActivate, type ExecutionContext, Injectable, SetMetadata } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import type { AuditStepUpMethod } from '../common/audit/audit.service.js';
import { isAuthenticatedPrincipal } from '../common/auth/principal.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { ReturnsSettings } from './returns.settings.js';

export type ReturnsStepUpOperation = 'return.submit' | 'return.approve';

const META = 'optomstroy:returns-step-up';
const STATE = Symbol.for('optomstroy.returns.step-up');
export const STEP_UP_HEADER = 'x-step-up-token'; // check-secrets: allow — имя заголовка, не секрет

/** Маршрут требует `X-Step-Up-Token` операции (08 §2.12; 11 §4.3 №68, №74 — S!). */
export const RequireReturnsStepUp = (operation: ReturnsStepUpOperation): MethodDecorator =>
  SetMetadata(META, operation);

export interface ReturnsStepUp {
  readonly operation: ReturnsStepUpOperation;
  readonly method: AuditStepUpMethod;
  readonly jti: string;
}

export function returnsStepUpOf(req: object): ReturnsStepUp | undefined {
  return (req as { [STATE]?: ReturnsStepUp })[STATE];
}

/** Отключённый модуль (10 RET-012): `/returns*` недоступны — `403 FORBIDDEN`, `reason: returns_disabled` (GQ-TXR-01). */
export function returnsDisabled(): ProblemException {
  return new ProblemException('FORBIDDEN', {
    detail: 'Заявки на возврат из приложения отключены: возврат оформляется в 1С.',
    reason: 'returns_disabled',
  });
}

/**
 * Guard модуля `returns`: выполняется после глобальных Auth → RBAC (403 по праву раньше) и до интерсептора
 * идемпотентности (ключ не захватывается):
 * 1) `app_settings.returns_enabled=false` → 403 `returns_disabled` для всех `/returns*` (10 RET-012);
 * 2) маршруты с `@RequireReturnsStepUp` (accept/reject — `return.approve`) — проверка `X-Step-Up-Token` единым
 *    `StepUpTokenVerifier` (scope, sid, deviceId, pv, denylist). Step-up отправки (`return.submit`) проверяет сервис —
 *    после объектной проверки и порога (08 §2.4: 403 FORBIDDEN раньше STEP_UP_REQUIRED).
 */
@Injectable()
export class ReturnsGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly tokens: StepUpTokenVerifier,
    private readonly settings: ReturnsSettings,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    if (context.getType() !== 'http') return true;
    const req = context.switchToHttp().getRequest<RequestWithContext>();
    const principal = req.principal;
    if (!isAuthenticatedPrincipal(principal))
      throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    if (!(await this.settings.enabled())) throw returnsDisabled();
    const operation = this.reflector.get<ReturnsStepUpOperation | undefined>(META, context.getHandler());
    if (!operation) return true;
    const v = await this.tokens.verify(req.headers[STEP_UP_HEADER], principal, {
      operation,
      allowedMethods: ['pin', 'otp'],
      detail: 'Подтвердите действие с заявкой на возврат PIN-кодом или кодом из SMS.',
    });
    (req as unknown as { [STATE]?: ReturnsStepUp })[STATE] = { operation, method: v.method, jti: v.jti };
    return true;
  }
}

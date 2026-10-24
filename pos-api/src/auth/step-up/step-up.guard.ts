import {
  type CanActivate,
  type ExecutionContext,
  Injectable,
  SetMetadata,
  UseGuards,
  applyDecorators,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { type AuthHttpRequest, headerValue } from '../common/request.js';
import type { StepUpOperation } from './step-up.operations.js';
import { StepUpService, type VerifiedStepUp } from './step-up.service.js';

export const STEP_UP_OPERATION = 'optomstroy:step-up-operation';

/** Запрос после StepUpGuard: проверенный step-up (метод — в аудит операции, 08 §2.12). */
export type RequestWithStepUp = AuthHttpRequest & { stepUp?: VerifiedStepUp };

/**
 * Проверяет `X-Step-Up-Token` для операции маршрута (после глобальных AuthGuard/RbacGuard). Нет/неверный/истёкший
 * токен, другая область, другая сессия → 403 STEP_UP_REQUIRED `{stepUp: {operation, allowedMethods}}`.
 */
@Injectable()
export class StepUpGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly stepUp: StepUpService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const operation = this.reflector.getAllAndOverride<StepUpOperation | undefined>(STEP_UP_OPERATION, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (!operation) return true;
    const req = context.switchToHttp().getRequest<RequestWithStepUp>();
    const p = req.principal;
    if (!isAuthenticatedPrincipal(p)) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    req.stepUp = await this.stepUp.verify(headerValue(req, 'x-step-up-token'), p, operation);
    return true;
  }
}

/** Маршрут требует step-up операции `operation` (08 §2.12): `@RequireStepUp('session.logout_all')`. */
export function RequireStepUp(operation: StepUpOperation): MethodDecorator & ClassDecorator {
  return applyDecorators(SetMetadata(STEP_UP_OPERATION, operation), UseGuards(StepUpGuard));
}

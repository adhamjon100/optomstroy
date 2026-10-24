import { createParamDecorator, type ExecutionContext } from '@nestjs/common';
import type { RequestWithContext } from '../http/request-context.js';
import { ProblemException } from '../problem-details/problem.exception.js';
import { isAuthenticatedPrincipal, type AuthenticatedPrincipal } from './principal.js';

/**
 * `@Public()` — маршрут без Bearer (08 §2.2 «Публичные эндпоинты», 11 SEC-013). Тот же ключ метаданных, что
 * у RbacGuard (common/rbac): AuthGuard и RbacGuard пропускают маршрут одинаково.
 */
export { Public, PUBLIC_ROUTE } from '../rbac/rbac.decorators.js';

/**
 * `@CurrentUser()` — субъект запроса (`AuthenticatedPrincipal`); `@CurrentUser('userId')` — одно поле.
 * На маршруте без субъекта (ошибка конфигурации: `@Public()` + `@CurrentUser()`) → 401 UNAUTHENTICATED.
 */
export const CurrentUser = createParamDecorator(
  (field: keyof AuthenticatedPrincipal | undefined, ctx: ExecutionContext): unknown => {
    const req = ctx.switchToHttp().getRequest<RequestWithContext>();
    const p = req.principal;
    if (!isAuthenticatedPrincipal(p)) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    return field === undefined ? p : p[field];
  },
);

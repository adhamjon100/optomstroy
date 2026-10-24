import { type AuthenticatedPrincipal, isAuthenticatedPrincipal } from '../../../common/auth/principal.js';
import type { RequestWithContext } from '../../../common/http/request-context.js';
import { ProblemException } from '../../../common/problem-details/problem.exception.js';

/** Субъект запроса (AuthGuard). Отсутствие на защищённом маршруте — ошибка конфигурации → 401. */
export function principalOf(req: RequestWithContext): AuthenticatedPrincipal {
  const p = req.principal;
  if (!isAuthenticatedPrincipal(p)) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
  return p;
}

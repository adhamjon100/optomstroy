import { type CanActivate, type ExecutionContext, Inject, Injectable } from '@nestjs/common';
import { isAuthenticatedPrincipal } from '../../common/auth/principal.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';

/**
 * Режим клиента выключен (`CUSTOMER_SELF_SERVICE=false`, только env — ядро §19.2, §24.2): строки матрицы 10 §3 для
 * `customer` не действуют — платежи и QR своего заказа → `403 FORBIDDEN` (10 CASH-006, AC-CASH-006; RM-G-014).
 * Копия guard модуля orders (модули не импортируют друг друга, 06 §7.4). Guard контроллера выполняется после глобальных (Auth 401 → RBAC 403), сотрудников не затрагивает.
 */
@Injectable()
export class CustomerModeGuard implements CanActivate {
  constructor(@Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'CUSTOMER_SELF_SERVICE'>) {}

  canActivate(context: ExecutionContext): boolean {
    if (context.getType() !== 'http') return true;
    const p = context.switchToHttp().getRequest<RequestWithContext>().principal;
    if (isAuthenticatedPrincipal(p) && p.kind === 'customer' && !this.config.CUSTOMER_SELF_SERVICE) {
      throw new ProblemException('FORBIDDEN', { detail: 'Режим покупателя отключён.' });
    }
    return true;
  }
}

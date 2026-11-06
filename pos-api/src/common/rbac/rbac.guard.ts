import { type CanActivate, type ExecutionContext, Injectable, Logger } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { RequestWithContext } from '../http/request-context.js';
import { ProblemException } from '../problem-details/problem.exception.js';
import { PermissionCatalog } from './permission-catalog.js';
import type { PermissionCode } from './permissions.generated.js';
import { type PermissionRequirement, PUBLIC_ROUTE, REQUIRED_PERMISSIONS, requirementCodes } from './rbac.decorators.js';

/**
 * RBAC guard (RM-C-005; 11 §4.1–§4.4; deny by default, ADR-015):
 * 1) `@Public()` — пропуск без субъекта;
 * 2) нет субъекта (`req.principal`, заполняет common/auth-context этапа D) → 401 UNAUTHENTICATED — до проверки политики
 *    (ARCH-006, приоритет 08 §2.4: 401 раньше 403; ревью C-MN-02);
 * 3) маршрут без `@Public()` и без `@RequirePermission`/`@RequireAnyPermission`/`@RequirePermissionGroups` → 403
 *    FORBIDDEN (политика не задана);
 * 4) требование не выполнено (`requirementSatisfied`: все | любое | «И из ИЛИ») → 403 FORBIDDEN. Эффективные права —
 *    по ролям, статусу и виду субъекта: коды `kiosk.order.submit`, `kiosk.self.*` засчитываются только при
 *    `kind=kiosk` (11 SEC-138, PermissionCatalog). Object-level (own) и step-up проверяют сервисы/StepUpGuard.
 */
@Injectable()
export class RbacGuard implements CanActivate {
  private readonly logger = new Logger('authz');

  constructor(
    private readonly reflector: Reflector,
    private readonly catalog: PermissionCatalog,
  ) {}

  canActivate(context: ExecutionContext): boolean {
    if (context.getType() !== 'http') return true;
    const targets = [context.getHandler(), context.getClass()];
    if (this.reflector.getAllAndOverride<boolean>(PUBLIC_ROUTE, targets) === true) return true;

    const req = context.switchToHttp().getRequest<RequestWithContext>();
    const requirement = this.reflector.getAllAndOverride<PermissionRequirement | undefined>(
      REQUIRED_PERMISSIONS,
      targets,
    );
    const principal = req.principal;
    if (!principal) {
      throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    }
    if (!requirement || requirementCodes(requirement).length === 0) {
      this.deny(req, 'no_policy');
    }
    const granted = this.catalog.effectivePermissions(principal);
    if (!requirementSatisfied(requirement, granted)) {
      this.deny(req, 'missing_permission', requirementCodes(requirement));
    }
    return true;
  }

  private deny(req: RequestWithContext, reason: string, codes: readonly string[] = []): never {
    this.logger.warn({ event: 'authz.denied', requestId: req.id, reason, permissions: codes }, 'authz.denied');
    throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
  }
}

/**
 * Выполнено ли требование маршрута при эффективных правах `granted` (deny by default): `all` — все коды (пустой
 * список — нет); `any` — хотя бы один; `cnf` — каждая группа хотя бы одним своим правом (нет групп или пустая
 * группа — нет). Неизвестная форма метаданных — отказ.
 */
export function requirementSatisfied(
  requirement: PermissionRequirement,
  granted: ReadonlySet<PermissionCode>,
): boolean {
  switch (requirement.mode) {
    case 'all':
      return requirement.codes.length > 0 && requirement.codes.every((c) => granted.has(c));
    case 'any':
      return requirement.codes.some((c) => granted.has(c));
    case 'cnf':
      return requirement.groups.length > 0 && requirement.groups.every((g) => g.some((c) => granted.has(c)));
    default:
      return false;
  }
}

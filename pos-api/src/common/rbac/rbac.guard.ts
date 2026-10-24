import { type CanActivate, type ExecutionContext, Injectable, Logger } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { RequestWithContext } from '../http/request-context.js';
import { ProblemException } from '../problem-details/problem.exception.js';
import { PermissionCatalog } from './permission-catalog.js';
import { type PermissionRequirement, PUBLIC_ROUTE, REQUIRED_PERMISSIONS } from './rbac.decorators.js';

/**
 * RBAC guard (RM-C-005; 11 §4.1–§4.4; deny by default, ADR-015):
 * 1) `@Public()` — пропуск без субъекта;
 * 2) нет субъекта (`req.principal`, заполняет common/auth-context этапа D) → 401 UNAUTHENTICATED — до проверки политики
 *    (ARCH-006, приоритет 08 §2.4: 401 раньше 403; ревью C-MN-02);
 * 3) маршрут без `@Public()` и без `@RequirePermission`/`@RequireAnyPermission` → 403 FORBIDDEN (политика не задана);
 * 4) нет требуемого права → 403 FORBIDDEN. Object-level (own) и step-up проверяют сервисы/StepUpGuard.
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
    if (!requirement || requirement.codes.length === 0) {
      this.deny(req, 'no_policy');
    }
    const granted = this.catalog.effectivePermissions(principal);
    const ok =
      requirement.mode === 'all'
        ? requirement.codes.every((c) => granted.has(c))
        : requirement.codes.some((c) => granted.has(c));
    if (!ok) this.deny(req, 'missing_permission', requirement.codes);
    return true;
  }

  private deny(req: RequestWithContext, reason: string, codes: readonly string[] = []): never {
    this.logger.warn({ event: 'authz.denied', requestId: req.id, reason, permissions: codes }, 'authz.denied');
    throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
  }
}

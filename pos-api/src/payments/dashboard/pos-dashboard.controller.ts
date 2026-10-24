import { Controller, Get, Header, Query, Req } from '@nestjs/common';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { CurrentUser } from '../../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { PosDashboardService } from './pos-dashboard.service.js';

/**
 * `GET /pos/dashboard` (08 §4.10.1; OpenAPI `pos_dashboard_get`; 13 RM-G-004): право `dashboard.cashier.read`
 * (cashier, senior_seller, admin, owner); `seller`, `customer` — 403. Контроллер модуля `payments` (06 §7.4).
 */
@Controller('pos')
export class PosDashboardController {
  constructor(
    private readonly service: PosDashboardService,
    private readonly catalog: PermissionCatalog,
  ) {}

  @Get('dashboard')
  @RequirePermission('dashboard.cashier.read')
  @Header('Cache-Control', 'no-store')
  get(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Req() req: RequestWithContext & { ip?: string },
    @Query() q: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    return this.service.get(
      {
        userId: p.userId,
        roles: p.roles,
        perms: this.catalog.effectivePermissions(p),
        audit: auditContextFromRequest(req),
      },
      q,
    );
  }
}

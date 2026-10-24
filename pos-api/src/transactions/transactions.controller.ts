import { Controller, Get, Header, Param, Query, Req } from '@nestjs/common';
import { auditContextFromRequest } from '../common/audit/audit-context.js';
import { CurrentUser } from '../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { PermissionCatalog } from '../common/rbac/permission-catalog.js';
import { RequireAnyPermission } from '../common/rbac/rbac.decorators.js';
import { TransactionQueryService, type TransactionsViewer } from './transactions.service.js';

type Req = RequestWithContext & { ip?: string };

/**
 * API модуля `transactions` (08 §4.14; OpenAPI `transactions_list`, `transactions_get`; 13 RM-G-004, RM-G-011):
 * только чтение журнала. Права — `transactions.read.all` (cashier, senior_seller, admin, owner) или
 * `transactions.read.own` (seller); `customer` — 403 (нет права, RBAC).
 */
@Controller('transactions')
export class TransactionsController {
  constructor(
    private readonly query: TransactionQueryService,
    private readonly catalog: PermissionCatalog,
  ) {}

  private viewer(p: AuthenticatedPrincipal, req: Req): TransactionsViewer {
    return {
      actor: {
        userId: p.userId,
        roles: p.roles,
        isCustomer: p.kind === 'customer',
        sessionId: p.sessionId,
        deviceId: p.deviceId,
        requestId: typeof req.id === 'string' ? req.id : null,
      },
      userId: p.userId,
      sessionId: p.sessionId,
      perms: this.catalog.effectivePermissions(p),
      audit: auditContextFromRequest(req),
    };
  }

  @Get()
  @RequireAnyPermission('transactions.read.all', 'transactions.read.own')
  @Header('Cache-Control', 'no-store')
  list(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Req() req: Req,
    @Query() q: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    const viewer = this.viewer(p, req);
    return this.query.list(viewer, this.query.parse(q, viewer));
  }

  @Get(':id')
  @RequireAnyPermission('transactions.read.all', 'transactions.read.own')
  @Header('Cache-Control', 'no-store')
  get(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Req() req: Req,
    @Param('id') id: string,
  ): Promise<Record<string, unknown>> {
    return this.query.get(this.viewer(p, req), id);
  }
}

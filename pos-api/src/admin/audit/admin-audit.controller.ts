import { Controller, Get, Header, Inject, Query, Req } from '@nestjs/common';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { AUDIT_QUERY_PORT, type AuditQueryPort, type SalesActor } from '../../common/ports/index.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { principalOf } from '../users/shared/principal.js';
import { type AdminAuditQuery, parseAdminAuditQuery } from './admin-audit.request.js';
import { presentAuditRow } from './audit-row.presenter.js';

/**
 * `GET /admin/audit-logs` (08 §4.18.7; OpenAPI `admin_audit_logs_list`; RM-G-006, RM-G-011 `chainOk`): права
 * `audit.read` (`admin`, `owner`); `admin` — финансовые `before/after` замаскированы (11 SEC-083), `owner` —
 * полностью. Каждое чтение пишет `audit.viewed` (фильтры, число строк; 07 DATA-237, 11 §7.2). `Cache-Control: no-store`.
 * Порядок проверок: Auth (401) → RBAC (403) → параметры (400 / 422 `date_range`).
 */
@Controller('admin/audit-logs')
export class AdminAuditController {
  constructor(
    @Inject(AUDIT_QUERY_PORT) private readonly audits: AuditQueryPort,
    private readonly audit: AuditService,
  ) {}

  @Get()
  @RequirePermission('audit.read')
  @Header('Cache-Control', 'no-store')
  async list(@Req() req: RequestWithContext, @Query() raw: Record<string, unknown>): Promise<Record<string, unknown>> {
    const p = principalOf(req);
    const query: AdminAuditQuery = parseAdminAuditQuery(raw);
    const viewer: SalesActor = {
      userId: p.userId,
      roles: p.roles,
      isCustomer: p.kind === 'customer',
      sessionId: p.sessionId,
      deviceId: p.deviceId,
      requestId: typeof req.id === 'string' ? req.id : null,
    };
    if (viewer.isCustomer) throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
    const page = await this.audits.list(null, viewer, query);
    await this.audit.write(auditContextFromRequest(req), {
      action: 'audit.viewed',
      entityType: 'audit_logs',
      after: {
        filters: {
          from: query.from.toISOString(),
          to: query.to.toISOString(),
          ...(query.actorUserId ? { actorId: query.actorUserId } : {}),
          ...(query.action ? { action: query.action } : {}),
          ...(query.entityType ? { entityType: query.entityType } : {}),
          ...(query.entityId ? { entityId: query.entityId } : {}),
          ...(query.result ? { result: query.result } : {}),
          ...(query.cursor ? { page: 'next' } : {}),
        },
        rowsReturned: page.items.length,
      },
    });
    return {
      items: page.items.map(presentAuditRow),
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
    };
  }
}

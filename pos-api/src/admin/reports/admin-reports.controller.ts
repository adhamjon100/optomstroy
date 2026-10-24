import { Controller, Get, Header, Query, Req } from '@nestjs/common';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { principalOf } from '../users/shared/principal.js';
import {
  assertJsonFormat,
  parseAsOfOnly,
  parseGroupBy,
  parseQrStatus,
  parseReportPeriod,
  type ReportPeriod,
} from './admin-reports.request.js';
import { AdminReportsService } from './admin-reports.service.js';

type Req = RequestWithContext & { ip?: string };

/**
 * Отчёты руководителя R1 `GET /admin/reports/sales-summary|receivables|qr-reconciliation` (08 §4.18.8; OpenAPI
 * `admin_reports_*`; ядро §22.13 п. 3; RM-G-006): права по отчёту (`reports.sales.read`, `reports.receivables.read`,
 * `reports.qr_reconciliation.read` — `admin`, `owner`); `format=csv` → 403 (R2); период ≤ 366 дней (422
 * `date_range`); аудит `report.viewed` (имя, период) — финансовые данные (D-36). `Cache-Control: no-store`.
 */
@Controller('admin/reports')
export class AdminReportsController {
  constructor(
    private readonly reports: AdminReportsService,
    private readonly audit: AuditService,
  ) {}

  @Get('sales-summary')
  @RequirePermission('reports.sales.read')
  @Header('Cache-Control', 'no-store')
  async salesSummary(@Req() req: Req, @Query() q: Record<string, unknown>): Promise<Record<string, unknown>> {
    this.assertStaff(req);
    assertJsonFormat(q);
    const period = parseReportPeriod(q, this.reports.now());
    const groupBy = parseGroupBy(q);
    const body = await this.reports.salesSummary(period, groupBy);
    await this.viewed(req, 'sales-summary', period, { groupBy });
    return body;
  }

  @Get('receivables')
  @RequirePermission('reports.receivables.read')
  @Header('Cache-Control', 'no-store')
  async receivables(@Req() req: Req, @Query() q: Record<string, unknown>): Promise<Record<string, unknown>> {
    this.assertStaff(req);
    assertJsonFormat(q);
    const asOfOnly = parseAsOfOnly(q);
    const body = await this.reports.receivables(asOfOnly);
    await this.viewed(req, 'receivables', null, { asOfOnly, asOf: body.asOf ?? null });
    return body;
  }

  @Get('qr-reconciliation')
  @RequirePermission('reports.qr_reconciliation.read')
  @Header('Cache-Control', 'no-store')
  async qrReconciliation(@Req() req: Req, @Query() q: Record<string, unknown>): Promise<Record<string, unknown>> {
    this.assertStaff(req);
    assertJsonFormat(q);
    const period = parseReportPeriod(q, this.reports.now());
    const status = parseQrStatus(q);
    const body = await this.reports.qrReconciliation(period, status);
    await this.viewed(req, 'qr-reconciliation', period, { status });
    return body;
  }

  private assertStaff(req: Req): void {
    if (principalOf(req).kind === 'customer') {
      throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
    }
  }

  /** `report.viewed` (11 §7.2: тип отчёта, период; 08 §4.18.8: name, period). */
  private async viewed(
    req: Req,
    name: string,
    period: ReportPeriod | null,
    params: Record<string, unknown>,
  ): Promise<void> {
    await this.audit.write(auditContextFromRequest(req), {
      action: 'report.viewed',
      entityType: 'report',
      after: {
        name,
        period: period ? { from: period.from.toISOString(), to: period.to.toISOString() } : null,
        ...params,
      },
    });
  }
}

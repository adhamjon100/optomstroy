import { Body, Controller, Get, Header, Headers, HttpCode, Param, Post, Query, Req, Res } from '@nestjs/common';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { CurrentUser } from '../../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { RequireAnyPermission, RequirePermission } from '../../common/rbac/rbac.decorators.js';
import type { Page } from './sync-api.common.js';
import type { SyncRunDto } from './sync-api.presenters.js';
import { SyncOutboxService } from './sync-outbox.service.js';
import { SyncRunsService } from './sync-runs.service.js';
import { type SyncStatusDto, SyncStatusService } from './sync-status.service.js';

const STEP_UP_HEADER = 'x-step-up-token';

interface LocationResponse {
  setHeader(name: string, value: string): unknown;
}

/**
 * API модуля `sync` (08 §4.17; OpenAPI `/sync/*`; RM-E-002, RM-E-014): статус, прогоны (ручной запуск — R0 §17.2),
 * ошибки прогонов, очередь «в 1С» и ручной повтор элемента outbox (ядро §22.1, §22.10, §19.4).
 */
@Controller('sync')
export class SyncController {
  constructor(
    private readonly status: SyncStatusService,
    private readonly runs: SyncRunsService,
    private readonly outbox: SyncOutboxService,
  ) {}

  @Get('status')
  @RequireAnyPermission('sync.status.read', 'sync.runs.read')
  @Header('Cache-Control', 'private, max-age=15')
  getStatus(@CurrentUser() principal: AuthenticatedPrincipal): Promise<SyncStatusDto> {
    return this.status.status(principal);
  }

  @Post('runs')
  @HttpCode(202)
  @RequireAnyPermission('sync.run.incremental.limited', 'sync.run.full')
  @Idempotent({ required: true })
  @Header('Cache-Control', 'no-store')
  async createRun(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Res({ passthrough: true }) res: LocationResponse,
    @Headers(STEP_UP_HEADER) stepUpToken: string | undefined,
    @Body() body: unknown,
  ): Promise<SyncRunDto> {
    const run = await this.runs.create(
      principal,
      body,
      stepUpToken,
      auditContextFromRequest(req),
      typeof req.id === 'string' ? req.id : undefined,
    );
    res.setHeader('Location', `/api/v1/sync/runs/${run.id}`);
    return run;
  }

  @Get('runs')
  @RequirePermission('sync.runs.read')
  @Header('Cache-Control', 'no-store')
  listRuns(@Query() q: Record<string, unknown>): Promise<Page<SyncRunDto>> {
    return this.runs.list(q);
  }

  @Get('runs/:id')
  @RequirePermission('sync.runs.read')
  @Header('Cache-Control', 'no-store')
  getRun(@Param('id') id: string): Promise<SyncRunDto> {
    return this.runs.get(id);
  }

  @Get('runs/:id/errors')
  @RequirePermission('sync.runs.read')
  @Header('Cache-Control', 'no-store')
  runErrors(@Param('id') id: string, @Query() q: Record<string, unknown>): Promise<Page<Record<string, unknown>>> {
    return this.runs.errors(id, q);
  }

  @Get('outbox')
  @RequirePermission('sync.outbox.manage')
  @Header('Cache-Control', 'no-store')
  listOutbox(@Query() q: Record<string, unknown>): Promise<Page<Record<string, unknown>>> {
    return this.outbox.list(q);
  }

  @Post('outbox/:id/retry')
  @HttpCode(202)
  @RequirePermission('sync.outbox.manage')
  @Idempotent({ required: true })
  @Header('Cache-Control', 'no-store')
  retryOutbox(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Param('id') id: string,
  ): Promise<Record<string, unknown>> {
    return this.outbox.retry(principal, id, auditContextFromRequest(req));
  }
}

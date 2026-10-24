import {
  Body,
  Controller,
  Delete,
  Get,
  Header,
  Headers,
  HttpCode,
  Param,
  Patch,
  Post,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { auditContextFromRequest } from '../common/audit/audit-context.js';
import { CurrentUser } from '../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../common/auth/principal.js';
import type { RequestWithContext } from '../common/http/request-context.js';
import { IDEMPOTENCY_KEY_HEADER, Idempotent } from '../common/idempotency/idempotent.decorator.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../common/rbac/permission-catalog.js';
import { RequireAnyPermission, RequirePermission } from '../common/rbac/rbac.decorators.js';
import { RequireReturnsStepUp, ReturnsGuard, returnsStepUpOf, STEP_UP_HEADER } from './returns.guard.js';
import {
  parseAcceptBody,
  parseCreateReturnBody,
  parseRejectBody,
  parseRowVersionQuery,
  parseUpdateReturnBody,
  parseUuidPath,
} from './returns.request.js';
import { type ReturnDto, type ReturnsCaller, ReturnsService } from './returns.service.js';

type Req = RequestWithContext & { ip?: string };

/**
 * API модуля `returns` (08 §4.15; OpenAPI `returns_list`, `returns_create`, `returns_get`, `returns_update`,
 * `returns_delete`, `returns_submit`, `returns_accept`, `returns_reject`; 13 RM-G-005, RM-G-011). Права — 11 §4.3–§4.4
 * (`return.read`, `return.create`, `return.submit`, `return.approve`); объектные правила SEC-030 (г) — в сервисе.
 * Модуль отключается только `app_settings.returns_enabled=false` (10 RET-012, `ReturnsGuard`).
 */
@Controller('returns')
@UseGuards(ReturnsGuard)
export class ReturnsController {
  constructor(
    private readonly service: ReturnsService,
    private readonly catalog: PermissionCatalog,
  ) {}

  private caller(p: AuthenticatedPrincipal, req: Req): ReturnsCaller {
    return {
      principal: p,
      userId: p.userId,
      perms: this.catalog.effectivePermissions(p),
      audit: auditContextFromRequest(req),
      actor: {
        userId: p.userId,
        roles: p.roles,
        isCustomer: p.kind === 'customer',
        sessionId: p.sessionId,
        deviceId: p.deviceId,
        requestId: typeof req.id === 'string' ? req.id : null,
      },
    };
  }

  @Get()
  @RequirePermission('return.read')
  @Header('Cache-Control', 'no-store')
  list(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Req() req: Req,
    @Query() q: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    return this.service.list(this.caller(p, req), q);
  }

  @Post()
  @RequirePermission('return.create')
  @Idempotent({ required: true })
  @Header('Cache-Control', 'no-store')
  create(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Req() req: Req,
    @Headers(IDEMPOTENCY_KEY_HEADER.toLowerCase()) idempotencyKey: string | undefined,
    @Body() body: unknown,
  ): Promise<ReturnDto> {
    return this.service.create(this.caller(p, req), parseCreateReturnBody(body), idempotencyKey ?? null);
  }

  @Get(':id')
  @RequirePermission('return.read')
  @Header('Cache-Control', 'no-store')
  get(@CurrentUser() p: AuthenticatedPrincipal, @Req() req: Req, @Param('id') id: string): Promise<ReturnDto> {
    return this.service.get(this.caller(p, req), parseUuidPath(id));
  }

  @Patch(':id')
  @RequirePermission('return.create')
  @Idempotent({ required: false })
  @Header('Cache-Control', 'no-store')
  update(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Req() req: Req,
    @Param('id') id: string,
    @Body() body: unknown,
  ): Promise<ReturnDto> {
    return this.service.update(this.caller(p, req), parseUuidPath(id), parseUpdateReturnBody(body));
  }

  @Delete(':id')
  @HttpCode(204)
  @RequirePermission('return.create')
  @Header('Cache-Control', 'no-store')
  async remove(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Req() req: Req,
    @Param('id') id: string,
    @Query('rowVersion') rowVersion: unknown,
  ): Promise<void> {
    const rid = parseUuidPath(id);
    await this.service.remove(this.caller(p, req), rid, parseRowVersionQuery(rowVersion));
  }

  /** Step-up `return.submit` проверяет сервис — после объектной проверки и порога (08 §2.4). */
  @Post(':id/submit')
  @HttpCode(200)
  @RequireAnyPermission('return.submit', 'return.approve')
  @Idempotent({ required: true })
  @Header('Cache-Control', 'no-store')
  submit(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Req() req: Req,
    @Param('id') id: string,
    @Headers(STEP_UP_HEADER) stepUpToken: string | undefined,
    @Body() body: unknown,
  ): Promise<ReturnDto> {
    return this.service.submit(this.caller(p, req), parseUuidPath(id), body, stepUpToken);
  }

  @Post(':id/accept')
  @HttpCode(200)
  @RequirePermission('return.approve')
  @RequireReturnsStepUp('return.approve')
  @Idempotent({ required: true })
  @Header('Cache-Control', 'no-store')
  accept(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Req() req: Req,
    @Param('id') id: string,
    @Body() body: unknown,
  ): Promise<ReturnDto> {
    const stepUp = returnsStepUpOf(req);
    if (!stepUp) throw new ProblemException('INTERNAL');
    return this.service.accept(this.caller(p, req), parseUuidPath(id), parseAcceptBody(body), stepUp);
  }

  @Post(':id/reject')
  @HttpCode(200)
  @RequirePermission('return.approve')
  @RequireReturnsStepUp('return.approve')
  @Idempotent({ required: true })
  @Header('Cache-Control', 'no-store')
  reject(
    @CurrentUser() p: AuthenticatedPrincipal,
    @Req() req: Req,
    @Param('id') id: string,
    @Body() body: unknown,
  ): Promise<ReturnDto> {
    const stepUp = returnsStepUpOf(req);
    if (!stepUp) throw new ProblemException('INTERNAL');
    return this.service.reject(this.caller(p, req), parseUuidPath(id), parseRejectBody(body), stepUp);
  }
}

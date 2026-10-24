import { Body, Controller, Get, Headers, HttpCode, Param, Post, Query, Req } from '@nestjs/common';
import { auditContextFromRequest } from '../../common/audit/audit-context.js';
import { CurrentUser } from '../../common/auth/auth.decorators.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { RequireAnyPermission, RequirePermission } from '../../common/rbac/rbac.decorators.js';
import type { CustomerLinkDto } from './customer-link.presenter.js';
import { CustomersLinkConfirmRequest, CustomersLinkRejectRequest } from './customer-links.dto.js';
import {
  type CustomerLinkWithUserDto,
  CustomerLinksService,
  LINK_RESOLVE_OPERATION,
  QUEUE_DEFAULT_LIMIT,
  QUEUE_MAX_LIMIT,
} from './customer-links.service.js';
import { STEP_UP_TOKEN_HEADER, StepUpVerifier } from './step-up.verifier.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function uuidParam(value: string, field: string): string {
  if (!UUID_RE.test(value)) {
    throw new ProblemException('VALIDATION_FAILED', {
      status: 400,
      detail: 'Неверный идентификатор.',
      errors: [{ field, rule: 'uuid', message: 'Ожидается UUID.' }],
    });
  }
  return value.toLowerCase();
}

/**
 * Привязки карточки клиента (08 §4.11.7; 11 коды 32, 61, 67): просмотр — `cashier`, `senior_seller`, `admin`,
 * `owner` (`customer.link.read`), `customer` — только своя подтверждённая (`customer.self.read`); подтверждение и
 * отклонение (`proposed` и `conflict`) — **только `admin`** со step-up (`X-Step-Up-Token`, операция
 * `customer.link.resolve`); прочие роли, в том числе `customer`, → 403 FORBIDDEN (RbacGuard).
 */
@Controller('customers')
export class CustomerLinksController {
  constructor(
    private readonly service: CustomerLinksService,
    private readonly stepUp: StepUpVerifier,
  ) {}

  @Get(':id/links')
  @RequireAnyPermission('customer.link.read', 'customer.self.read')
  list(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Param('id') id: string,
  ): Promise<{ items: CustomerLinkWithUserDto[] }> {
    return this.service.listLinks(principal, uuidParam(id, 'id'));
  }

  @Post(':id/links/:linkId/confirm')
  @HttpCode(200)
  @RequirePermission('customer.link.resolve')
  @Idempotent({ required: false })
  async confirm(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Param('linkId') linkId: string,
    @Headers(STEP_UP_TOKEN_HEADER) stepUpToken: string | undefined,
    @Body() body: CustomersLinkConfirmRequest,
  ): Promise<CustomerLinkDto> {
    const customerId = uuidParam(id, 'id');
    const link = uuidParam(linkId, 'linkId');
    const verified = await this.stepUp.verify(principal, stepUpToken, LINK_RESOLVE_OPERATION);
    return this.service.adminResolve(
      principal,
      auditContextFromRequest(req),
      customerId,
      link,
      'confirm',
      body,
      verified,
    );
  }

  @Post(':id/links/:linkId/reject')
  @HttpCode(200)
  @RequirePermission('customer.link.resolve')
  @Idempotent({ required: false })
  async reject(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Req() req: RequestWithContext,
    @Param('id') id: string,
    @Param('linkId') linkId: string,
    @Headers(STEP_UP_TOKEN_HEADER) stepUpToken: string | undefined,
    @Body() body: CustomersLinkRejectRequest,
  ): Promise<CustomerLinkDto> {
    const customerId = uuidParam(id, 'id');
    const link = uuidParam(linkId, 'linkId');
    const verified = await this.stepUp.verify(principal, stepUpToken, LINK_RESOLVE_OPERATION);
    return this.service.adminResolve(
      principal,
      auditContextFromRequest(req),
      customerId,
      link,
      'reject',
      { ...(body.comment !== undefined ? { comment: body.comment } : {}) },
      verified,
    );
  }
}

const LINK_STATUS_FILTER = ['proposed', 'conflict'] as const;
type LinkStatusFilter = (typeof LINK_STATUS_FILTER)[number];

/**
 * Очередь администратора `GET /customers?linkStatus=proposed,conflict` (08 §4.11.1; 11 код 73
 * `customer.link.conflicts.read`, только `admin`; иные роли с `linkStatus` → 403). Общий список клиентов
 * (`GET /customers` без `linkStatus`) — RM-G-001: до его реализации маршрут без `linkStatus` отвечает 404 NOT_FOUND;
 * владелец RM-G-001 переносит эту ветку в свой обработчик (вызов `CustomerLinksService.listQueue`).
 */
@Controller('customers')
export class CustomerLinkQueueController {
  constructor(
    private readonly service: CustomerLinksService,
    private readonly catalog: PermissionCatalog,
  ) {}

  @Get()
  @RequireAnyPermission('customer.read.basic', 'customer.link.conflicts.read')
  async list(
    @CurrentUser() principal: AuthenticatedPrincipal,
    @Query('linkStatus') linkStatus: string | string[] | undefined,
    @Query('limit') limitRaw: string | undefined,
    @Query('cursor') cursor: string | undefined,
  ): Promise<{ items: Record<string, unknown>[]; nextCursor: string | null; hasMore: boolean }> {
    if (linkStatus === undefined) {
      throw new ProblemException('NOT_FOUND', { detail: 'Список клиентов без linkStatus — RM-G-001.' });
    }
    if (!this.catalog.effectivePermissions(principal).has('customer.link.conflicts.read')) {
      throw new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
    }
    const statuses = parseLinkStatus(linkStatus);
    const limit = parseLimit(limitRaw);
    return this.service.listQueue(statuses, limit, cursor && cursor !== '' ? cursor : null);
  }
}

function validation(field: string, rule: string, message: string): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field, rule, message }],
  });
}

function parseLinkStatus(raw: string | string[]): LinkStatusFilter[] {
  const parts = (Array.isArray(raw) ? raw : [raw]).flatMap((v) => v.split(',')).map((v) => v.trim());
  if (parts.length === 0 || parts.length > 2 || parts.some((p) => p === '')) {
    throw validation('linkStatus', 'enum', 'Допустимо: proposed, conflict.');
  }
  const out: LinkStatusFilter[] = [];
  for (const p of parts) {
    if (!(LINK_STATUS_FILTER as readonly string[]).includes(p)) {
      throw validation('linkStatus', 'enum', 'Допустимо: proposed, conflict.');
    }
    if (out.includes(p as LinkStatusFilter)) throw validation('linkStatus', 'unique_items', 'Значения не повторяются.');
    out.push(p as LinkStatusFilter);
  }
  return out;
}

function parseLimit(raw: string | undefined): number {
  if (raw === undefined || raw === '') return QUEUE_DEFAULT_LIMIT;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > QUEUE_MAX_LIMIT) {
    throw validation('limit', 'range', `Целое 1…${QUEUE_MAX_LIMIT}.`);
  }
  return n;
}

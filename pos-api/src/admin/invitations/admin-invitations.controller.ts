import { Body, Controller, Delete, Get, HttpCode, Param, Post, Query, Req, UseGuards } from '@nestjs/common';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { uuidParam } from '../users/shared/params.js';
import { AdminStepUpGuard, RequireStepUp } from '../users/shared/step-up.guard.js';
import { AdminInvitationsCreateDto, AdminInvitationsListQuery, type InvitationDto } from './admin-invitations.dto.js';
import { AdminInvitationsService } from './admin-invitations.service.js';

/**
 * `/admin/invitations` (08 §4.18.4; contracts/openapi `admin_invitations_*`): GET — `users.read` (`admin`, `owner`);
 * POST/DELETE — `invitations.manage` (`admin`) со step-up (ядро §17.2). Порядок проверок: Auth (401) → RBAC (403
 * FORBIDDEN) → step-up (403 STEP_UP_REQUIRED) → схема тела (400) → бизнес-правила.
 */
@Controller('admin/invitations')
@UseGuards(AdminStepUpGuard)
export class AdminInvitationsController {
  constructor(private readonly service: AdminInvitationsService) {}

  @Get()
  @RequirePermission('users.read')
  list(@Query() q: AdminInvitationsListQuery) {
    return this.service.list(q.limit ?? 50, q.cursor);
  }

  @Post()
  @HttpCode(201)
  @RequirePermission('invitations.manage')
  @RequireStepUp('invitations.manage')
  @Idempotent({ required: true })
  async create(@Req() req: RequestWithContext, @Body() body: AdminInvitationsCreateDto): Promise<InvitationDto> {
    const outcome = await this.service.invite(req, body, 'invitations');
    return this.service.get(outcome.invitationId);
  }

  @Delete(':id')
  @HttpCode(204)
  @RequirePermission('invitations.manage')
  @RequireStepUp('invitations.manage')
  async revoke(@Req() req: RequestWithContext, @Param('id') id: string): Promise<void> {
    await this.service.revoke(req, uuidParam(id));
  }
}

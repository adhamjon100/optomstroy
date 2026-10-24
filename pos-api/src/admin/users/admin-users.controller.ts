import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  Patch,
  Post,
  Put,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Response } from 'express';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { AdminInvitationsService } from '../invitations/admin-invitations.service.js';
import type { InvitationDto } from '../invitations/admin-invitations.dto.js';
import type { AdminUserDto } from './admin-user.mapper.js';
import {
  AdminUsersBlockDto,
  AdminUsersCreateDto,
  AdminUsersListQuery,
  AdminUsersPinResetDto,
  AdminUsersRolesSetDto,
  AdminUsersUpdateDto,
} from './admin-users.dto.js';
import { AdminUsersService } from './admin-users.service.js';
import { uuidParam } from './shared/params.js';
import { AdminStepUpGuard, RequireStepUp } from './shared/step-up.guard.js';

/**
 * `/admin/users` (08 §4.18.1–§4.18.3, §4.18.9; contracts/openapi `admin_users_*`; права — 11 §4.3–§4.4, матрица
 * `x-permissions`/`x-roles`). Порядок проверок: Auth (401) → RBAC (403 FORBIDDEN, deny by default) → step-up
 * (403 STEP_UP_REQUIRED, до раскрытия существования цели) → схема тела (400) → цель (404) → политика целей (403/422).
 */
@Controller('admin/users')
@UseGuards(AdminStepUpGuard)
export class AdminUsersController {
  constructor(
    private readonly service: AdminUsersService,
    private readonly invitations: AdminInvitationsService,
  ) {}

  @Get()
  @RequirePermission('users.read')
  list(@Req() req: RequestWithContext, @Query() q: AdminUsersListQuery) {
    return this.service.list(req, q);
  }

  /**
   * `POST /admin/users`: создаёт приглашение; для номера `pending_activation` — сразу активирует (ответ — `AdminUser`).
   * Если учётной записи ещё нет, строки `users` не создаётся (DATA-102: пользователь появляется при первом OTP-входе),
   * поэтому ответ `201` — `Invitation` с `Location` приглашения. Контракт 1.1.0 (D admin A-03): `201` —
   * `oneOf [AdminUser, Invitation]` + заголовок `Location`; клиент различает тела по полю `kind` (есть только у
   * `AdminUser`).
   */
  @Post()
  @HttpCode(201)
  @RequirePermission('users.manage')
  @RequireStepUp('users.manage')
  @Idempotent({ required: true })
  async create(
    @Req() req: RequestWithContext,
    @Body() body: AdminUsersCreateDto,
    @Res({ passthrough: true }) res: Response,
  ): Promise<AdminUserDto | InvitationDto> {
    const outcome = await this.invitations.invite(
      req,
      { phone: body.phone, roles: body.roles, fullName: body.fullName },
      'users',
    );
    if (outcome.kind === 'applied') {
      res.setHeader('Location', `/api/v1/admin/users/${outcome.userId}`);
      return this.service.get(req, outcome.userId);
    }
    res.setHeader('Location', `/api/v1/admin/invitations/${outcome.invitationId}`);
    return this.invitations.get(outcome.invitationId);
  }

  @Get(':id')
  @RequirePermission('users.read')
  get(@Req() req: RequestWithContext, @Param('id') id: string) {
    return this.service.get(req, uuidParam(id));
  }

  @Patch(':id')
  @RequirePermission('users.manage')
  @RequireStepUp('users.manage')
  @Idempotent({ required: false })
  update(@Req() req: RequestWithContext, @Param('id') id: string, @Body() body: AdminUsersUpdateDto) {
    return this.service.update(req, uuidParam(id), body);
  }

  @Put(':id/roles')
  @RequirePermission('users.roles.assign')
  @RequireStepUp('users.roles.assign')
  @Idempotent({ required: false })
  setRoles(@Req() req: RequestWithContext, @Param('id') id: string, @Body() body: AdminUsersRolesSetDto) {
    return this.service.setRoles(req, uuidParam(id), body);
  }

  @Post(':id/block')
  @HttpCode(200)
  @RequirePermission('users.manage')
  @RequireStepUp('users.manage')
  @Idempotent({ required: false })
  block(@Req() req: RequestWithContext, @Param('id') id: string, @Body() body: AdminUsersBlockDto) {
    return this.service.block(req, uuidParam(id), body);
  }

  @Post(':id/logout-all')
  @HttpCode(204)
  @RequirePermission('session.revoke.any')
  @RequireStepUp('session.revoke.any')
  @Idempotent({ required: false })
  async logoutAll(@Req() req: RequestWithContext, @Param('id') id: string): Promise<void> {
    await this.service.logoutAll(req, uuidParam(id));
  }

  @Delete(':id/pin')
  @HttpCode(204)
  @RequirePermission('users.pin.reset')
  @RequireStepUp('users.pin.reset')
  async resetPin(@Req() req: RequestWithContext, @Param('id') id: string, @Body() body: AdminUsersPinResetDto) {
    await this.service.resetPin(req, uuidParam(id), body);
  }
}

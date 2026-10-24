import { Body, Controller, Get, Header, HttpCode, Put, Req, UseGuards } from '@nestjs/common';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { AdminStepUpGuard, RequireStepUp } from '../users/shared/step-up.guard.js';
import { AdminSettingsUpdateDto } from './admin-settings.dto.js';
import { type AdminSettingsResponse, AdminSettingsService } from './admin-settings.service.js';

/**
 * `/admin/settings` (08 §4.18.6; contracts/openapi `admin_settings_get`, `admin_settings_update`; RM-D-015 п. 2).
 * GET — `settings.app.read` (admin, owner: SCR-46 владельцу только просмотр, ядро §21 п. 3); PUT —
 * `settings.app.update` (только admin) со step-up `settings.app.update`. Порядок: Auth (401) → RBAC (403) →
 * step-up (403 STEP_UP_REQUIRED) → схема тела (400) → значения (422) → версия (409). `Cache-Control: no-store`.
 */
@Controller('admin/settings')
@UseGuards(AdminStepUpGuard)
export class AdminSettingsController {
  constructor(private readonly service: AdminSettingsService) {}

  @Get()
  @RequirePermission('settings.app.read')
  @Header('Cache-Control', 'no-store')
  get(): Promise<AdminSettingsResponse> {
    return this.service.get();
  }

  @Put()
  @HttpCode(200)
  @RequirePermission('settings.app.update')
  @RequireStepUp('settings.app.update')
  @Idempotent({ required: false })
  @Header('Cache-Control', 'no-store')
  update(@Req() req: RequestWithContext, @Body() body: AdminSettingsUpdateDto): Promise<AdminSettingsResponse> {
    return this.service.update(req, body);
  }
}

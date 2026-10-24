import { Body, Controller, Get, Header, HttpCode, Put, Req, UseGuards } from '@nestjs/common';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { Idempotent } from '../../common/idempotency/idempotent.decorator.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { AdminStepUpGuard, RequireStepUp } from '../users/shared/step-up.guard.js';
import { type AdminDiscountLimitsBody, AdminDiscountLimitsService } from './admin-discount-limits.service.js';

/**
 * `/admin/discount-limits` (08 §4.18.5; contracts/openapi `admin_discount_limits_get`, `admin_discount_limits_update`;
 * RM-G-003; T-DISC-012). GET — `settings.app.read` (admin, owner); PUT — `settings.discount_limits.update` (только
 * admin) со step-up `settings.discount_limits.update`. Порядок: Auth (401) → RBAC (403) → step-up
 * (403 STEP_UP_REQUIRED) → тело (400) → значения (422) → версия (409). RL-ADMIN — `AdminRateLimitModule`.
 */
@Controller('admin/discount-limits')
@UseGuards(AdminStepUpGuard)
export class AdminDiscountLimitsController {
  constructor(private readonly service: AdminDiscountLimitsService) {}

  @Get()
  @RequirePermission('settings.app.read')
  @Header('Cache-Control', 'no-store')
  get(): Promise<AdminDiscountLimitsBody> {
    return this.service.get();
  }

  @Put()
  @HttpCode(200)
  @RequirePermission('settings.discount_limits.update')
  @RequireStepUp('settings.discount_limits.update')
  @Idempotent({ required: false })
  @Header('Cache-Control', 'no-store')
  update(@Req() req: RequestWithContext, @Body() body: unknown): Promise<AdminDiscountLimitsBody> {
    return this.service.update(req, body);
  }
}

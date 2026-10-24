import { Module } from '@nestjs/common';
import { AdminSharedModule } from '../users/shared/admin-shared.module.js';
import { AdminDiscountLimitsController } from './admin-discount-limits.controller.js';
import { AdminDiscountLimitsService } from './admin-discount-limits.service.js';

/** Лимиты ручной скидки по ролям `/admin/discount-limits` (08 §4.18.5; RM-G-003). Step-up — `AdminSharedModule`. */
@Module({
  imports: [AdminSharedModule],
  controllers: [AdminDiscountLimitsController],
  providers: [AdminDiscountLimitsService],
  exports: [AdminDiscountLimitsService],
})
export class AdminDiscountLimitsModule {}

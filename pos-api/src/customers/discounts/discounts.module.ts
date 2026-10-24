import { Module } from '@nestjs/common';
import { DISCOUNT_POLICY_PORT } from '../../common/ports/index.js';
import { bindSalesPort } from '../../sales-domain/sales-ports.module.js';
import { CustomerDiscountsController, DiscountRulesController } from './discounts.controller.js';
import { DiscountsService } from './discounts.service.js';
import { DiscountPolicyService } from './discount-policy.service.js';

/**
 * Скидки (модуль `customers`, подмодуль `discounts`; 06 §7.4 `DiscountService`; RM-G-003): `GET /customers/{id}/
 * discounts`, `GET /discounts/rules`; привязка порта `DISCOUNT_POLICY_PORT` (лимиты ролей, правила 1С, условия
 * клиента). Изменение лимитов — `AdminDiscountLimitsModule` (`/admin/discount-limits`).
 */
@Module({
  controllers: [CustomerDiscountsController, DiscountRulesController],
  providers: [DiscountsService, ...bindSalesPort(DISCOUNT_POLICY_PORT, DiscountPolicyService)],
  exports: [DiscountPolicyService, DiscountsService],
})
export class CustomerDiscountsModule {}

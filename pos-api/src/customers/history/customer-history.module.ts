import { Module } from '@nestjs/common';
import { CustomerCoreModule } from '../common/customer-core.module.js';
import { CustomerHistoryController } from './customer-history.controller.js';
import { CustomerHistoryService } from './customer-history.service.js';

/**
 * История покупок клиента `GET /customers/{id}/orders` (RM-G-001; 08 §4.11.4). Отдельный модуль — `OrdersModule`
 * этапа F подключает его импортом (ребро `orders → customers`, 06 §7.4) вместо собственного контроллера
 * (GQ-FND-08); заказы POS читаются read-only SQL без импорта `orders` (цикла нет).
 */
@Module({
  imports: [CustomerCoreModule],
  controllers: [CustomerHistoryController],
  providers: [CustomerHistoryService],
  exports: [CustomerHistoryService],
})
export class CustomerHistoryModule {}

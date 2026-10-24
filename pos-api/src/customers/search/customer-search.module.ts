import { Module } from '@nestjs/common';
import { CustomerCoreModule } from '../common/customer-core.module.js';
import { CustomerSearchController } from './customer-search.controller.js';
import { CustomerSearchService } from './customer-search.service.js';
import { PhoneLookupSignal } from './phone-lookup.signal.js';

/**
 * Поиск клиентов `GET /search/customers` (RM-G-001, RM-G-011; 08 §4.5.4). Отдельный модуль — чтобы маршрут жил в
 * `customers`, а `CartModule` этапа F (SCR-21) подключал его импортом (ребро `cart → customers`, 06 §7.4) вместо
 * собственного контроллера (GQ-FND-08). Nest регистрирует контроллер один раз при любом числе импортов.
 */
@Module({
  imports: [CustomerCoreModule],
  controllers: [CustomerSearchController],
  providers: [CustomerSearchService, PhoneLookupSignal],
  // `PhoneLookupSignal` — общий счётчик с `GET /customers?q=` (CustomersListService; ревью G-customers-1c-6).
  exports: [CustomerSearchService, PhoneLookupSignal],
})
export class CustomerSearchModule {}

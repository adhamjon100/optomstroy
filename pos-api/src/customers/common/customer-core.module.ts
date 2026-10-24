import { Module } from '@nestjs/common';
import { CustomerAccessService } from './customer-access.js';
import { CustomerFinanceService } from './customer-finance.js';
import { CustomerCursorCodec } from './customer-http.js';

/**
 * Общие сервисы модуля `customers` этапа G (RM-G-001): права и политика полей (`CustomerAccessService`), курсор
 * списков, финансовые части карточки через порты G. Зависимости — только глобальные модули фундамента (БД, RBAC,
 * Crypto, Audit, Config) и `SalesPortsModule` (DI-токены портов), поэтому модуль подключают и `cart`/`orders`
 * (рёбра `cart → customers`, `orders → customers` графа 06 §7.4) без цикла.
 */
@Module({
  providers: [CustomerAccessService, CustomerCursorCodec, CustomerFinanceService],
  exports: [CustomerAccessService, CustomerCursorCodec, CustomerFinanceService],
})
export class CustomerCoreModule {}

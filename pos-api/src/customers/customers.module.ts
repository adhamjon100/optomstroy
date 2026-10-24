import { Global, Module } from '@nestjs/common';
import { CUSTOMER_READER } from '../common/ports/index.js';
import { CUSTOMER_MATCHING_PORT } from '../registration/ports/customer-matching.port.js';
import { bindSalesPort } from '../sales-domain/sales-ports.module.js';
import { OnecOutboxWriterService } from '../sync/outbox/onec-outbox.writer.js';
import { CustomerCoreModule } from './common/customer-core.module.js';
import { CustomerCardService } from './directory/customer-card.service.js';
import { CustomerCreateService } from './directory/customer-create.service.js';
import { CustomersController } from './directory/customers.controller.js';
import { CustomersListService } from './directory/customers-list.service.js';
import { FavoritesModule } from './favorites/favorites.module.js';
import { CustomerHistoryModule } from './history/customer-history.module.js';
import { CustomersJobsBridge } from './jobs/customers-jobs.bridge.js';
import { CustomerLinksModule } from './links/customer-links.module.js';
import { CustomerLinksService } from './links/customer-links.service.js';
import { PgCustomerReader } from './reader/pg-customer-reader.js';
import { CustomerSearchModule } from './search/customer-search.module.js';
// RM-G-002, RM-G-003, RM-G-011 (агент G-be-credit): долги, решение о продаже в долг, скидки и условия.
import { CustomerDiscountsModule } from './discounts/discounts.module.js';
import { ReceivablesModule } from './receivables/receivables.module.js';

// Очередь привязок `GET /customers?linkStatus=` обслуживает `CustomersController` (RM-G-001) — контроллер этапа D
// с той же ветвью не регистрируется (`queueController: false`).
const customerLinks = CustomerLinksModule.forRoot({ matching: { onec: 'auto' }, queueController: false });

/**
 * Порт `CUSTOMER_MATCHING_PORT` для `POST /registration/complete` (RM-D-004; D_spec_questions RG-08): реализация —
 * `CustomerLinksService.proposeForUser`. Глобальный — registration не импортирует `customers` (граф 06 §7.4).
 */
@Global()
@Module({
  imports: [customerLinks],
  providers: [{ provide: CUSTOMER_MATCHING_PORT, useExisting: CustomerLinksService }],
  exports: [CUSTOMER_MATCHING_PORT],
})
export class CustomerMatchingPortModule {}

/**
 * Модуль D-06 `customers` (06 §7.4). Этап D: привязки клиентов к карточкам 1С (RM-D-005 — `customer_links`,
 * `/registration/customer-match*`, `/customers/{id}/links*`) и порт привязки для регистрации. Порт 1С —
 * `onec: 'auto'`. Этап E: избранные товары (RM-E-006). Этап G (RM-G-001, части RM-G-004 и RM-G-011):
 * - `GET /customers` (список и очередь привязок SCR-45), `GET /customers/{id}` (поля по роли), `POST /customers`
 *   (дедупликация по телефону/ИНН → `onec_outbox` → подтверждение 1С);
 * - `GET /search/customers` (`CustomerSearchModule`) и `GET /customers/{id}/orders` (`CustomerHistoryModule`) —
 *   отдельные модули, которые также импортируют `cart`/`orders` этапа F (GQ-FND-08);
 * - `/favorites/customers` (до 12 карточек) — в `FavoritesModule`;
 * - порт `CUSTOMER_READER` (`PgCustomerReader`); события `customers.onec-confirmed|failed` (`CustomersJobsBridge`).
 * Синхронизация клиентов и истории продаж из 1С — обработчик `sync/customers` (модуль `sync`, без импорта
 * `customers`: связь только через таблицы-реплики, 06 §7.4 B-AR-12).
 */
@Module({
  imports: [
    customerLinks,
    CustomerMatchingPortModule,
    FavoritesModule,
    CustomerCoreModule,
    CustomerSearchModule,
    CustomerHistoryModule,
    ReceivablesModule,
    CustomerDiscountsModule,
  ],
  controllers: [CustomersController],
  providers: [
    CustomersListService,
    CustomerCardService,
    CustomerCreateService,
    OnecOutboxWriterService,
    CustomersJobsBridge,
    ...bindSalesPort(CUSTOMER_READER, PgCustomerReader),
  ],
  exports: [customerLinks, FavoritesModule, CustomerCoreModule, CustomersJobsBridge],
})
export class CustomersModule {}

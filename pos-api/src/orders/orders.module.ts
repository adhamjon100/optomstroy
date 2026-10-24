import { Module } from '@nestjs/common';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import { ONEC_OUTBOX_WRITER, ORDER_CREATOR, ORDER_STATUS_PORT } from '../common/ports/index.js';
import { OnecGatewayModule } from '../integrations/onec/onec.module.js';
import { bindSalesPort } from '../sales-domain/sales-ports.module.js';
import { OnecOutboxWriterService } from '../sync/outbox/onec-outbox.writer.js';
import { OrderCancelService } from './order-cancel.service.js';
import { OrderCreateService } from './order-create.service.js';
import { OrderOnecLinkService } from './order-onec-link.service.js';
import { OrderQueryService } from './order-query.service.js';
import { OrderStatusPortService } from './order-status-port.service.js';
import { OrderViewService } from './order-view.service.js';
import { CustomerHistoryModule } from '../customers/history/customer-history.module.js';
import { OrdersController } from './orders.controller.js';

/**
 * Модуль D-06 `orders` (06 §7.4; этап F — RM-F-002, RM-F-012, RM-F-015): `POST/GET /orders`, `GET /orders/{id}`,
 * `POST /orders/{id}/cancel`, `POST /orders/{id}/onec-link`, `GET /customers/{id}/orders` (заказы POS).
 * Привязывает порты `ORDER_CREATOR`, `ORDER_STATUS_PORT` и `ONEC_OUTBOX_WRITER` (реализация — `sync/outbox`);
 * корзину, платежи, документы и уведомления вызывает через порты `common/ports` (импорта модулей нет, MOD-022).
 * Обработчики результата outbox и синхронизации статусов — `orders/worker` (процесс `pos-worker`).
 */
@Module({
  // `GET /customers/{id}/orders` (заказы POS + реализации 1С) — модуль `customers` (RM-G-001, GQ-FND-08; ребро
  // `orders → customers` 06 §7.4).
  imports: [OnecGatewayModule, CustomerHistoryModule],
  controllers: [OrdersController],
  providers: [
    StepUpTokenVerifier,
    OrderViewService,
    OrderQueryService,
    OrderCancelService,
    OrderOnecLinkService,
    ...bindSalesPort(ORDER_CREATOR, OrderCreateService),
    ...bindSalesPort(ORDER_STATUS_PORT, OrderStatusPortService),
    ...bindSalesPort(ONEC_OUTBOX_WRITER, OnecOutboxWriterService),
  ],
  exports: [OrderViewService],
})
export class OrdersModule {}

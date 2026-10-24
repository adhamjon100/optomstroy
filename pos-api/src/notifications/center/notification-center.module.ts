import { Module } from '@nestjs/common';
import { CatalogCommonModule } from '../../catalog/common/catalog-common.module.js';
import { NOTIFICATIONS_PORT } from '../../common/ports/notifications.port.js';
import { bindSalesPort } from '../../sales-domain/sales-ports.module.js';
import { NotificationsPortService } from './notifications-port.service.js';
import { NotificationsController } from './notifications.controller.js';
import { NotificationsRepository } from './notifications.repository.js';
import { NotificationsService } from './notifications.service.js';

/**
 * Центр уведомлений in-app (RM-F-008; D-41; 08 §4.16): `GET /notifications`, `POST /notifications/{id}/read`,
 * `POST /notifications/read-all` и реализация `NotificationsPort` (`bindSalesPort(NOTIFICATIONS_PORT, …)`) для
 * orders/payments/cart. Курсор списка — `CatalogCursorCodec` (зашифрованный keyset-курсор 08 §2.5; ребро
 * `notifications → catalog/common` ацикличное, MOD-022). Push (FCM) — R2 (Q-036).
 */
@Module({
  imports: [CatalogCommonModule],
  controllers: [NotificationsController],
  providers: [
    NotificationsRepository,
    NotificationsService,
    ...bindSalesPort(NOTIFICATIONS_PORT, NotificationsPortService),
  ],
  exports: [NotificationsService],
})
export class NotificationCenterModule {}

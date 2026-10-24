import { Module } from '@nestjs/common';
import { NotificationCenterModule } from './center/notification-center.module.js';
import { SmsNotificationsModule } from './sms/sms-notifications.module.js';

/**
 * Модуль D-06 `notifications` (06 §7.4). Этап D: SMS-контур процесса API (RM-D-002) — `sms_outbox`/`sms.send`
 * (`SmsOutboxService`), признак доступности канала и push-DLR `POST /integrations/smspro/dlr` (за флагом
 * `SMSPRO_DLR_MODE=push`). Обработчики заданий `sms.*` — в pos-worker (`SmsRuntime`, src/worker.ts).
 * Этап F (RM-F-008, D-41): центр уведомлений in-app (`NotificationCenterModule` — `/notifications*` и реализация
 * `NotificationsPort` для orders/payments/cart).
 */
@Module({
  imports: [SmsNotificationsModule, NotificationCenterModule],
  exports: [SmsNotificationsModule, NotificationCenterModule],
})
export class NotificationsModule {}

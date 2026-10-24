import { Injectable, Logger } from '@nestjs/common';
import { isNotificationKind } from '../../common/enums.js';
import { assertNotificationPayload } from '../../common/notifications/notification-target.js';
import type { NotificationInput, NotificationsPort } from '../../common/ports/notifications.port.js';
import type { SalesTx } from '../../common/ports/sales-context.js';
import { NotificationsRepository } from './notifications.repository.js';

/**
 * Реализация `NotificationsPort` (06 §7.4 `NotificationService.create`; D-41; 07 §5.50) для модулей orders
 * (смена статуса из 1С — `order_status`, отказ 1С и `dead` outbox — `sync_error`), payments (`payment_status`),
 * cart (`cart_price_changed`/`cart_stock_changed`), долга (`credit_blocked`). Запись — в транзакции вызывающего
 * (`tx`) или отдельной командой (`null`); повтор с тем же `dedupeKey` не создаёт вторую строку (T-NOTIF-003).
 */
const TITLE_MAX = 200;
const BODY_MAX = 2000;

function clip(s: string, max: number): string {
  const t = s.trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

function check(input: Omit<NotificationInput, 'userId'>): void {
  if (!isNotificationKind(input.kind)) throw new Error(`NotificationsPort: неизвестный kind ${String(input.kind)}`);
  if (!['info', 'warning', 'error'].includes(input.severity)) {
    throw new Error(`NotificationsPort: неизвестный severity ${String(input.severity)}`);
  }
  if (input.title.trim() === '') throw new Error('NotificationsPort: пустой title');
  if (input.dedupeKey.trim() === '' || input.dedupeKey.length > 300) {
    throw new Error('NotificationsPort: dedupeKey — 1…300 символов');
  }
  // Notification.payload.target — только значения enum контракта (OpenAPI 1.2.0; ревью F, RC-3).
  assertNotificationPayload(input.payload);
}

@Injectable()
export class NotificationsPortService implements NotificationsPort {
  private readonly logger = new Logger('notifications');

  constructor(private readonly repo: NotificationsRepository) {}

  async notify(
    tx: SalesTx | null,
    input: NotificationInput,
  ): Promise<{ readonly id: string; readonly created: boolean }> {
    check(input);
    const r = await this.repo.insert(tx, {
      ...input,
      title: clip(input.title, TITLE_MAX),
      body: clip(input.body, BODY_MAX),
    });
    if (r.created) this.logger.log({ event: 'notification.created', kind: input.kind, notificationId: r.id });
    return r;
  }

  async notifyRole(
    tx: SalesTx | null,
    role: string,
    input: Omit<NotificationInput, 'userId'>,
  ): Promise<readonly string[]> {
    check(input);
    return this.repo.insertForRole(tx, role, {
      ...input,
      title: clip(input.title, TITLE_MAX),
      body: clip(input.body, BODY_MAX),
    });
  }
}

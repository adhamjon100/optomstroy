import { Injectable, Logger } from '@nestjs/common';
import { NOTIFICATIONS_PORT, SalesPortRegistry } from '../../common/ports/index.js';

export interface PaymentNotice {
  readonly userId: string;
  readonly paymentId: string;
  readonly orderId: string | null;
  readonly severity: 'info' | 'warning' | 'error';
  readonly title: string;
  readonly body: string;
  /** Часть ключа дедупликации (`payment_status:<paymentId>:<event>`). */
  readonly event: string;
}

/**
 * In-app уведомления о платеже (D-41; `notification_kind = payment_status`) через `NotificationsPort` модуля
 * notifications. Отправляется **после COMMIT** и без влияния на исход операции: сбой или непривязанный порт только
 * журналируется (уведомление — вторичный канал; источник истины — статус платежа, его читает клиент).
 */
@Injectable()
export class PaymentNotifier {
  private readonly logger = new Logger('payments');

  constructor(private readonly registry: SalesPortRegistry) {}

  /**
   * Уведомление роли (кассирам, администраторам) — например, оплата по аннулированному QR (05 §6.7.3, SYNC-078:
   * «уведомление кассиру и администратору»). Получатели — активные пользователи роли (NotificationsPort.notifyRole).
   */
  async notifyRole(role: string, n: Omit<PaymentNotice, 'userId'>): Promise<void> {
    if (!this.registry.isBound(NOTIFICATIONS_PORT)) return;
    try {
      await this.registry.get(NOTIFICATIONS_PORT).notifyRole(null, role, {
        kind: 'payment_status',
        severity: n.severity,
        title: n.title,
        body: n.body,
        payload: { paymentId: n.paymentId, ...(n.orderId ? { orderId: n.orderId } : {}) },
        dedupeKey: `payment_status:${n.paymentId}:${n.event}:${role}`,
      });
    } catch (err) {
      this.logger.warn({ err, paymentId: n.paymentId, event: n.event, role }, 'payments.notify_role_failed');
    }
  }

  async notify(n: PaymentNotice): Promise<void> {
    if (!this.registry.isBound(NOTIFICATIONS_PORT)) return;
    try {
      await this.registry.get(NOTIFICATIONS_PORT).notify(null, {
        userId: n.userId,
        kind: 'payment_status',
        severity: n.severity,
        title: n.title,
        body: n.body,
        payload: { paymentId: n.paymentId, ...(n.orderId ? { orderId: n.orderId } : {}) },
        dedupeKey: `payment_status:${n.paymentId}:${n.event}`,
      });
    } catch (err) {
      this.logger.warn({ err, paymentId: n.paymentId, event: n.event }, 'payments.notify_failed');
    }
  }
}

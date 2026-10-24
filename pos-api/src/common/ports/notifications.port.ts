import type { NotificationKind } from '../enums.js';
import type { SalesTx } from './sales-context.js';

/**
 * `NotificationsPort` — создание in-app уведомления (D-41; 06 §7.4 `NotificationService.create`; 07 §5.50).
 * Идемпотентность — `UNIQUE (user_id, dedupe_key)`: повтор с тем же ключом не создаёт вторую строку. Реализация —
 * агент F-be-docs-notif (`src/notifications/**`, кроме `sms/`); потребители — orders (смена статуса из 1С, отказ 1С,
 * dead outbox), payments (`payment_status`), cart (`cart_price_changed`/`cart_stock_changed`).
 */
export const NOTIFICATIONS_PORT = 'sales.NotificationsPort' as const;

export interface NotificationInput {
  readonly userId: string;
  readonly kind: NotificationKind;
  readonly severity: 'info' | 'warning' | 'error';
  readonly title: string;
  readonly body: string;
  /** `Notification.payload` (например, `{orderId}`; для `system` — `target`). */
  readonly payload?: Readonly<Record<string, unknown>>;
  readonly dedupeKey: string;
  readonly expiresAt?: Date | null;
}

export interface NotificationsPort {
  /** В транзакции вызывающего (`tx`) или отдельной командой (`null`). Возвращает id (существующий при дубле). */
  notify(tx: SalesTx | null, input: NotificationInput): Promise<{ readonly id: string; readonly created: boolean }>;
  /** Всем активным пользователям роли (например, `admin` при `dead` outbox, 10 ORD-031). */
  notifyRole(tx: SalesTx | null, role: string, input: Omit<NotificationInput, 'userId'>): Promise<readonly string[]>;
}

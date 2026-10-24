/**
 * Допустимые значения `Notification.payload.target` — закрытый enum контракта (OpenAPI 1.2.0, 08 §3.13 «Ключи
 * `Notification.payload`»; ядро §19.2): цель перехода для `kind=system`; `null` — без перехода. Значения, которых нет в
 * enum (прежние `sync`, `sync_outbox`, `sync_errors` уведомлений синхронизации и заказа — ревью F, RC-3), сервер не
 * передаёт: переход по `sync_error` клиент строит по `kind` (02 SCR-44 → SCR-43), а не по `target`.
 * Совпадение списка с контрактом проверяет test/notifications/notification-target.spec.ts.
 */
export const NOTIFICATION_TARGET_VALUES = ['sessions', 'profile', 'customer_link', 'update', 'cart_parked'] as const;
export type NotificationTarget = (typeof NOTIFICATION_TARGET_VALUES)[number];

export function isNotificationTarget(value: unknown): value is NotificationTarget {
  return typeof value === 'string' && (NOTIFICATION_TARGET_VALUES as readonly string[]).includes(value);
}

/**
 * Проверка `payload` уведомления по схеме контракта перед записью: `target`, если задан, — значение enum или `null`.
 * Нарушение — ошибка программиста (бросается), а не данные пользователя.
 */
export function assertNotificationPayload(payload: Readonly<Record<string, unknown>> | null | undefined): void {
  if (!payload || !Object.hasOwn(payload, 'target')) return;
  const target = payload.target;
  if (target === null || isNotificationTarget(target)) return;
  throw new Error(
    `Notification.payload.target: значение ${JSON.stringify(target)} вне enum контракта (${NOTIFICATION_TARGET_VALUES.join(', ')}, null)`,
  );
}

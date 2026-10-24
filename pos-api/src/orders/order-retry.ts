import { sql } from 'drizzle-orm';
import type { OrderStatus } from '../common/enums.js';
import { type CartReader, type NotificationsPort, PortNotBoundError, type SalesTx } from '../common/ports/index.js';
import { ProblemException } from '../common/problem-details/problem.exception.js';
import type { OrderRow } from './order.repository.js';

/**
 * Восстановленная корзина отклонённого заказа при техническом повторе (`POST /sync/outbox/{id}/retry`) или ручной
 * привязке (`POST /orders/{id}/onec-link`) — 10 ORD-027, ORD-034: корзина не изменялась и не использована → `cleared`
 * с уведомлением автору (`order_status`); изменена или оформлена → `409 ORDER_STATE_INVALID` «Заказ уже исправляется
 * пользователем» (транзакция вызывающего откатывается). Порт корзины не привязан (процесс без модуля cart) — шаг
 * пропускается: корзина остаётся, повтор допускается (как при отсутствии восстановленной корзины).
 */
export async function releaseRestoredCart(
  tx: SalesTx,
  deps: { readonly cart: CartReader | null; readonly notifications: NotificationsPort | null },
  o: Pick<OrderRow, 'id' | 'public_number' | 'created_by_user_id' | 'status'>,
  via: 'retry' | 'onec_link',
): Promise<void> {
  if (!deps.cart) return;
  let rel: Awaited<ReturnType<CartReader['releaseRestored']>>;
  try {
    rel = await deps.cart.releaseRestored(tx, { orderId: o.id, ownerUserId: o.created_by_user_id });
  } catch (e) {
    if (e instanceof PortNotBoundError) return;
    throw e;
  }
  if (rel.outcome === 'modified') {
    throw new ProblemException('ORDER_STATE_INVALID', {
      detail: 'Заказ уже исправляется пользователем: восстановленная корзина изменена или оформлена.',
      resource: 'order',
      reason: 'restored_cart_in_use',
      currentStatus: o.status,
    });
  }
  if (rel.outcome === 'cleared' && deps.notifications) {
    try {
      await deps.notifications.notify(tx, {
        userId: o.created_by_user_id,
        kind: 'order_status',
        severity: 'info',
        title: `Заказ ${o.public_number}: повторная отправка в 1С`,
        body:
          via === 'retry'
            ? `Заказ ${o.public_number} повторно отправлен в 1С. Корзина, восстановленная из заказа, закрыта.`
            : `Заказ ${o.public_number} привязан к документу 1С. Корзина, восстановленная из заказа, закрыта.`,
        payload: { orderId: o.id, cartIds: [...rel.cartIds] },
        dedupeKey: `order_restored_cart_released:${o.id}:${rel.cartIds.join(',')}`,
      });
    } catch (e) {
      if (!(e instanceof PortNotBoundError)) throw e;
    }
  }
}

/** Сброс причины отказа 1С при возврате заказа в отправку (ORD-027: `submit_failed → submitting`). */
export async function clearSubmitError(tx: SalesTx, orderId: string): Promise<void> {
  await tx.execute(sql`
    UPDATE orders SET submit_error_code = NULL, submit_error_message = NULL, updated_at = now()
     WHERE id = ${orderId}::uuid`);
}

export function orderStateInvalid(currentStatus: OrderStatus, reason: string, detail: string): ProblemException {
  return new ProblemException('ORDER_STATE_INVALID', { detail, resource: 'order', reason, currentStatus });
}

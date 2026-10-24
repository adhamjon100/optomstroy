import type { CartStatus } from '../../common/enums.js';
import { SalesDomainError } from '../domain-error.js';

/**
 * Автомат `cart_status` (07 §6.5; 10 CART-, §7.3): корзина — сущность `carts`, не статус `draft` заказа (ядро §17.2).
 * Восстановление состава заказа (ORD-027) создаёт **новую** корзину (`active` или `parked`) — это не переход.
 */
export type CartTrigger =
  | 'park'
  | 'resume'
  | 'convert'
  | 'clear'
  /** Истёк `expires_at` (job `cart.parked_expire`) или `DELETE /cart/parked/{id}`. */
  | 'expire_or_delete'
  /** Технический повтор ORD-027 / привязка ORD-034: восстановленная корзина → `cleared`. */
  | 'restored_superseded';

export interface CartTransition {
  readonly from: CartStatus;
  readonly to: CartStatus;
  readonly triggers: readonly CartTrigger[];
}

export const CART_TRANSITIONS: readonly CartTransition[] = [
  { from: 'active', to: 'parked', triggers: ['park'] },
  { from: 'parked', to: 'active', triggers: ['resume'] },
  { from: 'active', to: 'converted', triggers: ['convert'] },
  { from: 'active', to: 'cleared', triggers: ['clear', 'restored_superseded'] },
  { from: 'parked', to: 'cleared', triggers: ['expire_or_delete', 'restored_superseded'] },
];

export const CART_TERMINAL_STATUSES: ReadonlySet<CartStatus> = new Set(['converted', 'cleared']);

export function isCartTransitionAllowed(from: CartStatus, to: CartStatus, trigger?: CartTrigger): boolean {
  const t = CART_TRANSITIONS.find((x) => x.from === from && x.to === to);
  return t !== undefined && (trigger === undefined || t.triggers.includes(trigger));
}

/** Недопустимый переход — `409 ORDER_STATE_INVALID` (`resource: cart`; 08 §2.4, DATA-205). */
export function assertCartTransition(from: CartStatus, to: CartStatus, trigger: CartTrigger): void {
  if (!isCartTransitionAllowed(from, to, trigger)) {
    throw new SalesDomainError('ORDER_STATE_INVALID', `Переход корзины ${from} → ${to} (${trigger}) недопустим.`, {
      resource: 'cart',
      reason: from === 'parked' || from === 'active' ? 'transition_not_allowed' : `cart_${from}`,
      currentStatus: from,
      targetStatus: to,
    });
  }
}

/** Изменение содержимого допустимо только у `active` (converted не редактируется — DATA-205). */
export function assertCartEditable(status: CartStatus): void {
  if (status !== 'active') {
    throw new SalesDomainError('ORDER_STATE_INVALID', 'Корзина недоступна для изменения.', {
      resource: 'cart',
      reason: `cart_${status}`,
      currentStatus: status,
    });
  }
}

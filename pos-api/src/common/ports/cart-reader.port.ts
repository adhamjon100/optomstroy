import type { PaymentMethod } from '../enums.js';
import type { MoneyString, QuantityString, SalesActor, SalesTx } from './sales-context.js';

/**
 * `CartReader` — порт модуля `cart` для `orders` (06 §7.4: `CartService.getForCheckout`, `markConverted`,
 * `validateForCheckout` — единственная процедура проверок оформления `CheckoutPolicy`, B-AR-07). Реализация —
 * агент F-be-cart; потребитель — F-be-orders (`POST /orders`, восстановление состава ORD-027).
 */
export const CART_READER = 'sales.CartReader' as const;

export interface CheckoutLineSnapshot {
  readonly lineNo: number;
  readonly variantId: string;
  readonly productId: string;
  readonly packagingId: string | null;
  /** Количество в единицах цены (упаковки, если цена за упаковку). */
  readonly quantity: QuantityString;
  readonly baseQuantity: QuantityString;
  readonly unitPrice: MoneyString;
  readonly lineSubtotal: MoneyString;
  readonly customerDiscountAmount: MoneyString;
  readonly manualDiscountAmount: MoneyString;
  readonly discountAmount: MoneyString;
  readonly lineTotal: MoneyString;
  readonly unitCode: string;
  readonly packagingName: string | null;
  readonly packagingFactor: QuantityString | null;
  readonly productName: string;
  readonly variantName: string | null;
  readonly sku: string | null;
  readonly barcode: string | null;
}

/** Корзина, пересчитанная сервером в транзакции (снимок для `order_items`, 07 §5.38). */
export interface CheckoutCartSnapshot {
  readonly cartId: string;
  readonly rowVersion: number;
  readonly ownerUserId: string;
  readonly customerId: string | null;
  readonly warehouseId: string;
  readonly priceListId: string;
  readonly customerDiscountPercent: string;
  readonly manualDiscountPercent: string;
  readonly discountApprovedByUserId: string | null;
  /**
   * Причина подтверждения скидки сверх лимита, данного в корзине (`carts.discount_override_reason`, 10 DISC-010):
   * заказ переносит её в `orders.discount_reason`, `transactions.kind=discount_override` и аудит. `null` — нет.
   */
  readonly discountOverrideReason: string | null;
  readonly subtotal: MoneyString;
  readonly customerDiscountTotal: MoneyString;
  readonly manualDiscountTotal: MoneyString;
  readonly discountTotal: MoneyString;
  readonly total: MoneyString;
  readonly lines: readonly CheckoutLineSnapshot[];
}

export interface CheckoutValidationInput {
  readonly cartId?: string;
  /** `cartRowVersion` из тела запроса (несовпадение → `409 VERSION_CONFLICT`). */
  readonly expectedRowVersion?: number;
  readonly paymentMethod?: PaymentMethod;
  readonly manualDiscountPercent?: string;
  readonly discountOverride?: { readonly reason: string } | null;
  readonly creditOverride?: { readonly reason: string } | null;
  /** `X-Step-Up-Token` уже проверен вызывающим (true — действителен для нужной операции). */
  readonly stepUpVerified?: boolean;
  /**
   * `previewToken` последнего `POST /cart/checkout-preview` (08 §3.8, §4.8.1; 10 ORD-020). Если передан — подпись,
   * срок, корзина, `cartRowVersion`, способ оплаты и итог сверяются с серверным пересчётом: расхождение или
   * просроченный/подделанный токен → `422 PRICE_CHANGED` (`conflicts[]`, `reason`).
   */
  readonly previewToken?: string | null;
}

export type CheckoutConflict = {
  readonly variantId: string;
  readonly kind: 'price_changed' | 'stock_insufficient' | 'variant_unavailable' | 'qty_not_multiple' | 'qty_below_min';
  readonly [extra: string]: unknown;
};

export interface CheckoutValidation {
  /** `false` — есть конфликты (`checkout-preview` отвечает 200 `ok=false`, `POST /orders` — 422 `conflicts[]`). */
  readonly ok: boolean;
  readonly conflicts: readonly CheckoutConflict[];
  readonly cart: CheckoutCartSnapshot;
  readonly allowedPaymentMethods: readonly PaymentMethod[];
  /** Результат синхронной проверки `/check` 1С (таймаут `ONEC_SYNC_CHECK_TIMEOUT_MS` = 6000). */
  readonly onecCheck: {
    readonly performed: boolean;
    readonly at: Date | null;
    readonly result: 'ok' | 'unavailable' | 'rejected';
  };
  /** Решение по долгу для `paymentMethod=credit` (порядок PAY-031); `null` для прочих способов. */
  readonly credit: { readonly allowed: boolean; readonly overrideUsed: boolean } | null;
  readonly warnings: readonly { readonly code: 'STALE_DATA' | 'QR_UNAVAILABLE'; readonly message: string }[];
}

export interface CartReader {
  /** Проверки оформления (CheckoutPolicy): цены, остатки, лимит скидки, долг, режим клиента, `/check` 1С. */
  validateForCheckout(
    tx: SalesTx | null,
    actor: SalesActor,
    input: CheckoutValidationInput,
  ): Promise<CheckoutValidation>;
  /** Активная корзина → `converted` (`converted_order_id`), только при совпадении `row_version`. */
  markConverted(
    tx: SalesTx,
    input: { readonly cartId: string; readonly expectedRowVersion: number; readonly orderId: string },
  ): Promise<void>;
  /**
   * Восстановление состава заказа в новую корзину автора (ORD-027): пустая `active` — восстановленная `active`, иначе
   * `parked` «Восстановлена из заказа № …»; `restored_from_order_id`, `row_version = 1`.
   */
  restoreFromOrder(
    tx: SalesTx,
    input: { readonly orderId: string; readonly ownerUserId: string; readonly forceParked?: boolean },
  ): Promise<{ readonly cartId: string; readonly status: 'active' | 'parked' }>;
  /**
   * Технический повтор или ручная привязка отклонённого заказа (10 ORD-027, ORD-034): восстановленная из заказа
   * корзина автора, если она не изменялась (`row_version = 1`) и не использована для нового заказа, переводится в
   * `cleared` (`restored_superseded`) — `cleared`; корзины нет — `none`; изменена или оформлена — `modified` (ничего
   * не меняется, вызывающий отвечает `409 ORDER_STATE_INVALID` «Заказ уже исправляется пользователем»).
   */
  releaseRestored(
    tx: SalesTx,
    input: { readonly orderId: string; readonly ownerUserId: string },
  ): Promise<{ readonly outcome: 'none' | 'cleared' | 'modified'; readonly cartIds: readonly string[] }>;
}

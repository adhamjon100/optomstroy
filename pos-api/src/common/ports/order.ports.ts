import type { OrderStatus, PaymentMethod, StatusChangeSource } from '../enums.js';
import type { MoneyString, SalesActor, SalesTx } from './sales-context.js';

/**
 * Порты модуля `orders` (реализация — агент F-be-orders).
 * - `OrderCreator` — создание заказа из корзины (`POST /orders`, ядро §22.3) для внутренних вызовов и тестов других
 *   агентов (e2e платежей/документов могут создать заказ через порт, когда он привязан; до этого — `pos-fixture`).
 * - `OrderStatusPort` (= 06 §7.4 `OrderPaymentLedger`) — для `payments`: блокировка заказа под платёж, учёт
 *   полученных денег (`paid_amount`, монотонный `paid_at`) и пересчёт проекции статуса D-20.
 */
export const ORDER_CREATOR = 'sales.OrderCreator' as const;
export const ORDER_STATUS_PORT = 'sales.OrderStatusPort' as const;

export interface CreateOrderCommand {
  readonly actor: SalesActor;
  readonly idempotencyKey: string;
  readonly cartRowVersion: number;
  readonly paymentMethod: PaymentMethod;
  readonly customerId?: string | null;
  readonly deliveryMethod: 'pickup' | 'delivery';
  readonly receiver?: {
    readonly kind: 'customer' | 'other_person';
    readonly name?: string;
    readonly phoneE164?: string;
  };
  readonly delivery?: {
    readonly address?: string;
    readonly phoneE164?: string;
    readonly comment?: string;
    readonly date?: string;
    readonly timeFrom?: string;
    readonly timeTo?: string;
  };
  readonly comment?: string;
  readonly manualDiscountPercent?: string;
  readonly discountOverride?: { readonly reason: string } | null;
  readonly creditOverride?: { readonly reason: string } | null;
  readonly confirmDuplicate?: boolean;
}

export interface CreateOrderResult {
  /** `201` — проверка 1С выполнена; `202` — 1С недоступна, проверка по снимку (`warnings[STALE_DATA]`). */
  readonly httpStatus: 201 | 202;
  readonly orderId: string;
  readonly publicNumber: string;
  readonly status: OrderStatus;
  readonly paymentId: string | null;
  readonly warnings: readonly { readonly code: string; readonly message: string }[];
}

export interface OrderCreator {
  createFromCart(cmd: CreateOrderCommand): Promise<CreateOrderResult>;
}

/** Состояние заказа под платёж (строка заблокирована `FOR UPDATE` в транзакции платежа). */
export interface OrderPaymentView {
  readonly orderId: string;
  readonly publicNumber: string;
  readonly status: OrderStatus;
  readonly paymentMethod: PaymentMethod;
  readonly customerId: string;
  readonly createdByUserId: string;
  readonly createdVia: 'staff' | 'customer';
  readonly onecRef: string | null;
  readonly total: MoneyString;
  readonly paidAmount: MoneyString;
  readonly isPaid: boolean;
  readonly cancelRequested: boolean;
}

export interface OrderStatusChangeResult {
  readonly from: OrderStatus;
  readonly to: OrderStatus;
  /** Записи `order_status_history`, добавленные в этой транзакции. */
  readonly historySteps: number;
}

export interface OrderStatusPort {
  /** `SELECT … FOR UPDATE` строки заказа; нет заказа или нет доступа — `null` (вызывающий отвечает 404). */
  lockForPayment(tx: SalesTx, orderId: string): Promise<OrderPaymentView | null>;
  /**
   * Платёж перешёл в `received`: `paid_amount += amount`, при первом `paid_amount ≥ total` — `paid_at = now()` и
   * пересчёт проекции (P8 → P9/P10), `order_status_history` (`source=pos_system`), уведомление `order_status`.
   */
  applyReceived(
    tx: SalesTx,
    input: {
      readonly orderId: string;
      readonly amount: MoneyString;
      readonly paymentId: string;
      readonly actor: SalesActor;
    },
  ): Promise<{ readonly paidAt: Date | null; readonly statusChange: OrderStatusChangeResult | null }>;
  /**
   * Ручной повтор задачи outbox заказа (`POST /sync/outbox/{id}/retry`, 10 ORD-027; ядро §22.1) — в транзакции
   * повтора **после** перевода строки `failed | dead → pending`. Для `create` заказа `submit_failed`: восстановленная
   * корзина не изменялась → `cleared` с уведомлением автору, заказ `submit_failed → submitting` (`pos_user`, история);
   * иначе — `409 ORDER_STATE_INVALID`. Заказ `cancelled` (ORD-035: деньги получены, заказ отклонён) — `409`.
   * Исключение откатывает транзакцию повтора.
   */
  onOutboxRetry(
    tx: SalesTx,
    input: {
      readonly orderId: string;
      readonly operation: 'create' | 'cancel';
      readonly actor: SalesActor;
      readonly requestId?: string | null;
    },
  ): Promise<void>;
  /** Пересчёт проекции по текущим фактам (после изменения фактов вне `orders`). */
  recompute(
    tx: SalesTx,
    input: { readonly orderId: string; readonly source: StatusChangeSource; readonly actor: SalesActor | null },
  ): Promise<OrderStatusChangeResult | null>;
}

/** 06 §7.4 имя того же порта. */
export type OrderPaymentLedger = OrderStatusPort;

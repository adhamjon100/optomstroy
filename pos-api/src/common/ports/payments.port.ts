import type { PaymentMethod, PaymentStatus, ReviewReason } from '../enums.js';
import type { MoneyString, SalesActor, SalesTx } from './sales-context.js';

/**
 * `PaymentsPort` — порт модуля `payments` для `orders` (06 §7.4: `InitialPaymentPort` + `OrderPaymentsReadPort`,
 * реализация связывается в `SalesPortRegistry`, поэтому `orders` не импортирует `payments`). Реализация — агент
 * F-be-payments; потребитель — F-be-orders (создание заказа, отмена, `GET /orders/{id}`) и документы (чек).
 */
export const PAYMENTS_PORT = 'sales.PaymentsPort' as const;

export interface InitialPaymentInput {
  readonly orderId: string;
  readonly customerId: string;
  readonly method: PaymentMethod;
  /** Сумма — `orders.total` (вычисляет сервер; клиент сумму не передаёт). */
  readonly amount: MoneyString;
  readonly actor: SalesActor;
  /** Производный ключ `initialPaymentIdempotencyKey(orderKey)` (sales-domain/idempotency). */
  readonly idempotencyKey: string;
}

export interface PaymentSummary {
  readonly paymentId: string;
  readonly publicNumber: string;
  readonly method: PaymentMethod;
  readonly status: PaymentStatus;
  readonly amount: MoneyString;
  readonly receivedAt: Date | null;
  readonly reviewReason: ReviewReason | null;
  readonly qrProvider: 'onec' | 'none' | 'bakai' | null;
}

export interface QrAfterCommitResult {
  readonly payment: PaymentSummary;
  /** `QR_UNAVAILABLE` — провайдер (1С) не выдал QR: платёж остаётся `qr_pending` (08 API-185). */
  readonly warnings: readonly { readonly code: 'QR_UNAVAILABLE'; readonly message: string }[];
}

export interface PaymentsPort {
  /** Начальный платёж в транзакции `POST /orders`: `initiated → cash_pending | qr_pending | credit` (ядро §22.3). */
  createInitial(tx: SalesTx, input: InitialPaymentInput): Promise<PaymentSummary>;
  /** Запрос QR у провайдера после COMMIT, вне транзакции (08 API-183); для не-QR — текущее состояние. */
  afterCommit(paymentId: string, actor: SalesActor): Promise<QrAfterCommitResult>;
  /** Платежи заказа (`GET /orders/{id}`, `payments[]`). */
  listForOrder(orderId: string, tx?: SalesTx | null): Promise<readonly PaymentSummary[]>;
  /** Сумма полученных (`received`) платежей заказа. */
  receivedTotal(tx: SalesTx | null, orderId: string): Promise<MoneyString>;
  /**
   * Отмена заказа: неполученные платежи (`cash_pending`, `qr_pending`, `qr_shown`, `qr_expired`, `manual_confirm`)
   * → `voided` системой (PAY-050), `credit` остаётся `credit`; отмена QR в 1С — после COMMIT.
   */
  voidOpenForOrderCancel(
    tx: SalesTx,
    input: { readonly orderId: string; readonly actor: SalesActor },
  ): Promise<readonly string[]>;
}

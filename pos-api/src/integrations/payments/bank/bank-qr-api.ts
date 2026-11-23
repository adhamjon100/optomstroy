/**
 * Клиент API банка для QR-оплаты (ADR-123, P-004; 08 §4.9.5, §6) — внутренний интерфейс адаптера `BankQrProvider`
 * (порт `PaymentProvider`). Реализации выбирает `BANK_QR_ADAPTER`:
 * - `sandbox` — песочница банка (`SandboxBankQrApi`): встроена в pos-api, хранит выданные QR в памяти процесса, по
 *   служебному запросу «оплатить» формирует подписанный вебхук (08 §6), отдаёт операции за день для сверки;
 * - адаптер настоящего банка — **не сделан**: банк заказчика «другой», не Бакай, название и документация API неизвестны
 *   `[НЕ ПОДТВЕРЖДЕНО: Q-381, Q-382, Q-014]`. API банка не выдумываем: этот интерфейс — наш порт, а не протокол банка.
 *
 * Ключ сопоставления у банка — `merchantPaymentId` = `payments.id` (как `externalId` у 1С): перевыпуск QR на том же
 * платеже даёт новый `reference`, статус и отмена — по платежу (последний выпуск). Деньги — строки `"16007.50"` (D-19).
 */

/** DI-токен клиента банка (`null`, если `QR_PROVIDER≠bank`). */
export const BANK_QR_API = 'BankQrApi' as const;

/** Значения env `BANK_QR_ADAPTER` (16 §4.3). */
export type BankQrAdapter = 'sandbox';

export interface BankQrCreateRequest {
  /** `payments.id`. */
  readonly merchantPaymentId: string;
  /** Публичный номер заказа (`POS-2026-000123`) — второй ключ сопоставления вебхука (08 §6). */
  readonly merchantOrderId: string | null;
  readonly amount: string;
  readonly currency: 'KGS';
  readonly purpose: string;
  readonly ttlSeconds: number;
}

export interface BankQrCreated {
  /** Референс QR у банка (`payments.qr_provider_ref`, `QrInfo.bankReference`). */
  readonly reference: string;
  /** Строка QR (EMVCo/ELQR у настоящего банка; у песочницы — заведомо тестовая строка). */
  readonly payload: string;
  readonly amount: string;
  readonly issuedAt: string;
  readonly expiresAt: string;
}

export type BankQrStatus = 'pending' | 'paid' | 'expired' | 'cancelled';

/** Состояние последнего выпуска QR платежа у банка. */
export interface BankQrState {
  readonly status: BankQrStatus;
  readonly reference: string;
  readonly amount: string;
  readonly expiresAt: string;
  /** Оплата (если `paid`): по какому референсу пришли деньги, сумма, время, идентификатор операции банка. */
  readonly paidReference: string | null;
  readonly paidAmount: string | null;
  readonly paidAt: string | null;
  readonly operationId: string | null;
}

/** Операция зачисления у банка (выписка за день — ежедневная сверка QR, 10 PAY-029). */
export interface BankOperation {
  readonly operationId: string;
  readonly reference: string;
  readonly merchantPaymentId: string | null;
  readonly merchantOrderId: string | null;
  readonly amount: string;
  readonly currency: 'KGS';
  readonly paidAt: string;
}

export interface BankCallOptions {
  readonly signal?: AbortSignal;
}

export interface BankQrApi {
  readonly adapter: BankQrAdapter;
  createQr(req: BankQrCreateRequest, opts?: BankCallOptions): Promise<BankQrCreated>;
  /** `null` — банк не знает платёж (QR не выпускался или забыт песочницей после перезапуска). */
  getStatus(merchantPaymentId: string, opts?: BankCallOptions): Promise<BankQrState | null>;
  /** Отмена действующего QR платежа; если деньги уже пришли — состояние `paid`. `null` — отменять нечего. */
  cancel(merchantPaymentId: string, opts?: BankCallOptions): Promise<BankQrState | null>;
  /** Операции зачисления за календарный день Бишкека (`YYYY-MM-DD`, UTC+6). */
  listOperations(day: string, opts?: BankCallOptions): Promise<readonly BankOperation[]>;
}

/** Ошибка вызова банка: `retryable` — сеть/таймаут/5xx; иначе отказ по существу (код банка). */
export class BankApiError extends Error {
  override readonly name = 'BankApiError';

  constructor(
    readonly code: string,
    readonly retryable: boolean,
    message: string,
    readonly httpStatus = retryable ? 503 : 409,
  ) {
    super(message);
  }
}

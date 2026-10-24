/**
 * Порт `PaymentProvider` (06 §7.3 `infra/bank`, ARCH-063 `[НОВОЕ ИМЯ]`; ядро v1.9 §24.4): выдача QR, статус оплаты
 * и отмена QR. Реализации выбираются `QR_PROVIDER` при старте:
 * - `onec` → `OnecQrProvider` — основной вариант R1: динамический QR и статус от 1С (05 §6.7) только через порт
 *   `OnecGateway` (протокол 1С здесь не дублируется — ARCH-007);
 * - `none` → `ManualQrProvider` — запасной: статический QR торговой точки (или без QR) и ручное подтверждение
 *   кассиром со step-up (D-21), без внешних вызовов;
 * - `bakai` → `BakaiQrProvider` — **R2**, в R1 не создаётся (фабрика отвечает ошибкой конфигурации).
 *
 * Модули `orders`/`payments` и клиент от выбранной реализации не зависят: результат `issue()` проецируется в
 * `QrInfo` (contracts/openapi `QrInfo`: provider, payload, bankReference, amount, expiresAt, issuedAt, autoConfirm).
 */

/** DI-токен порта. */
export const PAYMENT_PROVIDER = 'PaymentProvider' as const;

/** Значения env `QR_PROVIDER` (16 §4.3). */
export type QrProviderMode = 'onec' | 'none' | 'bakai';
/** `QrInfo.provider` — свойство показанного QR (08 §3.10). */
export type QrInfoProvider = 'onec' | 'bakai' | 'elqr_static' | 'none';

export interface QrIssueRequest {
  /** `payments.id` = `externalId` платежа в 1С. */
  readonly paymentId: string;
  readonly orderExternalId: string;
  readonly orderRef: string | null;
  readonly customerRef: string | null;
  /** Деньги строкой `"16007.50"` (08 §2.1); сумму формирует сервер из заказа. */
  readonly amount: string;
  readonly currency: 'KGS';
  readonly purpose: string;
  /** `QR_TTL_MINUTES` × 60. */
  readonly ttlSeconds: number;
  readonly cashierUserCode: string;
}

/** Выданный QR — проекция в `QrInfo` и поля `payments.qr_*`. */
export interface QrIssued {
  readonly provider: QrInfoProvider;
  readonly payload: string | null;
  /** PNG base64, если банк отдаёт картинку вместо строки (05 §6.7, QR-3). */
  readonly imagePngBase64: string | null;
  /** `payments.qr_provider_ref` — идентификатор QR у банка/1С. */
  readonly providerRef: string | null;
  readonly amount: string | null;
  readonly issuedAt: string;
  readonly expiresAt: string | null;
  /** `true` — оплату подтверждает провайдер; `false` — только `confirm-manual` со step-up. */
  readonly autoConfirm: boolean;
  /** Сырой статус провайдера (`payments.qr_provider_status_raw`, ≤ 100 символов). */
  readonly providerStatusRaw: string | null;
}

/** `unknown` — провайдер не сообщает статус (ручной режим): решение принимает кассир. */
export type QrPaymentState = 'pending' | 'paid' | 'expired' | 'cancelled' | 'unknown';

export interface QrStatusResult {
  readonly state: QrPaymentState;
  readonly providerRef: string | null;
  readonly amount: string | null;
  readonly paidAmount: string | null;
  readonly paidAt: string | null;
  readonly bankReference: string | null;
  readonly expiresAt: string | null;
  /** Документ поступления, созданный интеграцией 1С (05 ONEC-077: не дублировать). */
  readonly documentRef: string | null;
  readonly providerStatusRaw: string | null;
}

export type QrCancelReason = 'method_changed' | 'voided' | 'order_cancelled' | 'reissue';

export interface QrCancelResult {
  /** `paid` — деньги уже зачислены, отмена невозможна (05 §6.7.2); `not_applicable` — у провайдера нечего отменять. */
  readonly state: 'cancelled' | 'paid' | 'not_applicable';
  readonly paidAmount: string | null;
  readonly paidAt: string | null;
  readonly bankReference: string | null;
}

/**
 * Параметры вызова провайдера (RM-F-016): `signal` прерывает запрос к 1С по таймауту вызывающего
 * (`ONEC_SYNC_CHECK_TIMEOUT_MS` — выдача QR при оформлении, 08 API-183; `ONEC_TIMEOUT_MS` — опрос статуса воркером).
 */
export interface QrCallOptions {
  readonly signal?: AbortSignal;
}

export interface PaymentProvider {
  readonly mode: QrProviderMode;
  /** Автоматическое подтверждение оплаты провайдером (`QrInfo.autoConfirm`). */
  readonly autoConfirm: boolean;
  issue(req: QrIssueRequest, opts?: QrCallOptions): Promise<QrIssued>;
  status(paymentId: string, opts?: QrCallOptions): Promise<QrStatusResult>;
  cancel(paymentId: string, reason: QrCancelReason, opts?: QrCallOptions): Promise<QrCancelResult>;
}

/**
 * Провайдер QR недоступен (таймаут, сеть, 5xx/`POS_E_QR_UNAVAILABLE`, отказ метода): `orders`/`payments` оставляют
 * платёж в `qr_pending` без QR и добавляют `warnings[QR_UNAVAILABLE]` (08 §4.8.1) — это не HTTP-ошибка при `onec`.
 */
export class QrProviderUnavailableError extends Error {
  override readonly name = 'QrProviderUnavailableError';

  constructor(
    readonly operation: 'issue' | 'status' | 'cancel',
    readonly retryable: boolean,
    readonly providerCode: string | null,
    message: string,
  ) {
    super(message);
  }
}

/** Отказ провайдера по существу (4xx, кроме недоступности): дубль, состояние, валидация. */
export class QrProviderRejectedError extends Error {
  override readonly name = 'QrProviderRejectedError';

  constructor(
    readonly operation: 'issue' | 'status' | 'cancel',
    readonly httpStatus: number,
    readonly providerCode: string,
    message: string,
  ) {
    super(message);
  }
}

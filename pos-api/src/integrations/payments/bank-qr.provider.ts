import { Money } from '../../common/money/money.js';
import { BankApiError, type BankQrApi, type BankQrState } from './bank/bank-qr-api.js';
import {
  type PaymentProvider,
  type QrCallOptions,
  type QrCancelResult,
  type QrIssued,
  type QrIssueRequest,
  QrProviderRejectedError,
  QrProviderUnavailableError,
  type QrStatusResult,
} from './payment-provider.js';

export interface BankQrProviderOptions {
  readonly now?: () => Date;
}

/**
 * `BankQrProvider` (`QR_PROVIDER=bank`, синоним `bakai`; ADR-123, P-004) — QR напрямую от банка через наш сервер за
 * портом `PaymentProvider`. Сумма — только из запроса сервера (`QrIssueRequest.amount` формирует модуль `payments` из
 * заказа); срок QR и перевыпуск на том же `payment_id` (новый референс); отмена и опрос статуса — по платежу.
 * Протокол банка — в реализации `BankQrApi` (`BANK_QR_ADAPTER`); здесь только отображение на порт.
 *
 * `QrInfo.provider = 'bakai'` — исторический код «прямой API банка» независимо от банка (ADR-123 п. 3).
 * Автомат платежа, сопоставление суммы/референса и `manual_confirm` — модуль `payments` (как для `onec`).
 */
export class BankQrProvider implements PaymentProvider {
  readonly mode = 'bank' as const;
  readonly autoConfirm = true;
  private readonly now: () => Date;

  constructor(
    private readonly bank: BankQrApi,
    options: BankQrProviderOptions = {},
  ) {
    this.now = options.now ?? (() => new Date());
  }

  async issue(req: QrIssueRequest, opts: QrCallOptions = {}): Promise<QrIssued> {
    try {
      const r = await this.bank.createQr(
        {
          merchantPaymentId: req.paymentId,
          merchantOrderId: req.orderPublicNumber ?? null,
          amount: Money.of(req.amount).toString(),
          currency: req.currency,
          purpose: req.purpose,
          ttlSeconds: req.ttlSeconds,
        },
        opts.signal ? { signal: opts.signal } : undefined,
      );
      return {
        provider: 'bakai',
        payload: r.payload,
        imagePngBase64: null,
        providerRef: r.reference,
        amount: r.amount,
        issuedAt: r.issuedAt || this.now().toISOString(),
        expiresAt: r.expiresAt,
        autoConfirm: true,
        providerStatusRaw: 'pending',
      };
    } catch (e) {
      throw mapError('issue', e);
    }
  }

  async status(paymentId: string, opts: QrCallOptions = {}): Promise<QrStatusResult> {
    let st: BankQrState | null;
    try {
      st = await this.bank.getStatus(paymentId, opts.signal ? { signal: opts.signal } : undefined);
    } catch (e) {
      throw mapError('status', e);
    }
    if (!st) {
      // Банк не знает платёж (песочница после перезапуска): решение — за кассиром, статус не меняется.
      return {
        state: 'unknown',
        providerRef: null,
        amount: null,
        paidAmount: null,
        paidAt: null,
        bankReference: null,
        expiresAt: null,
        documentRef: null,
        providerStatusRaw: 'unknown',
      };
    }
    return {
      state: st.status,
      providerRef: st.status === 'paid' ? (st.paidReference ?? st.reference) : st.reference,
      amount: st.amount,
      paidAmount: st.paidAmount,
      paidAt: st.paidAt,
      bankReference: st.operationId,
      expiresAt: st.expiresAt,
      documentRef: null,
      providerStatusRaw: st.status,
    };
  }

  async cancel(paymentId: string, _reason: unknown, opts: QrCallOptions = {}): Promise<QrCancelResult> {
    let st: BankQrState | null;
    try {
      st = await this.bank.cancel(paymentId, opts.signal ? { signal: opts.signal } : undefined);
    } catch (e) {
      throw mapError('cancel', e);
    }
    if (!st) return { state: 'not_applicable', paidAmount: null, paidAt: null, bankReference: null };
    if (st.status === 'paid') {
      return { state: 'paid', paidAmount: st.paidAmount, paidAt: st.paidAt, bankReference: st.operationId };
    }
    return { state: 'cancelled', paidAmount: null, paidAt: null, bankReference: null };
  }
}

/** Сеть/таймаут/5xx банка → недоступность (`qr_pending` + `QR_UNAVAILABLE`); прочее — отказ по существу. */
function mapError(operation: 'issue' | 'status' | 'cancel', e: unknown): Error {
  if (e instanceof BankApiError) {
    if (e.retryable) return new QrProviderUnavailableError(operation, true, e.code, `Банк: QR недоступен (${e.code})`);
    return new QrProviderRejectedError(operation, e.httpStatus, e.code, `Банк отклонил операцию QR (${e.code})`);
  }
  return new QrProviderUnavailableError(operation, true, null, 'Банк: сбой вызова QR');
}

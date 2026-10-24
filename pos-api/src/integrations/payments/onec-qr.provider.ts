// ARCH-063 п. 4: из integrations/onec/** импортируются только типы порта OnecGateway (import type).
import type { OnecGateway, OnecQrPaymentStatus } from '../onec/onec-gateway.js';
import {
  type PaymentProvider,
  type QrCallOptions,
  type QrCancelReason,
  type QrCancelResult,
  type QrIssued,
  type QrIssueRequest,
  QrProviderRejectedError,
  QrProviderUnavailableError,
  type QrStatusResult,
} from './payment-provider.js';

export interface OnecQrProviderOptions {
  readonly now?: () => Date;
}

/**
 * `OnecQrProvider` (`QR_PROVIDER=onec`, ARCH-063; ядро v1.9 §24.4; 05 §6.7) — **каркас этапа C**: отображение
 * методов QR порта `OnecGateway` на `PaymentProvider` без собственной логики протокола. Автомат платежа, опрос
 * `payments.qr_onec_poll`, сопоставление суммы/референса и `manual_confirm` — модуль `payments` (RM-F-016).
 *
 * Ошибки порта не импортируются как классы (ARCH-063 п. 4): ответ 1С распознаётся по полям `status`/`code`/`retryable`.
 */
export class OnecQrProvider implements PaymentProvider {
  readonly mode = 'onec' as const;
  readonly autoConfirm = true;
  private readonly now: () => Date;

  constructor(
    private readonly onec: OnecGateway,
    options: OnecQrProviderOptions = {},
  ) {
    this.now = options.now ?? (() => new Date());
  }

  async issue(req: QrIssueRequest, opts: QrCallOptions = {}): Promise<QrIssued> {
    try {
      const { body } = await this.onec.createQrPayment(
        {
          externalId: req.paymentId,
          orderExternalId: req.orderExternalId,
          orderRef: req.orderRef,
          customerRef: req.customerRef,
          amount: req.amount,
          currency: req.currency,
          purpose: req.purpose,
          requestedTtlSeconds: req.ttlSeconds,
          cashierUserCode: req.cashierUserCode,
        },
        callOpts(opts),
      );
      return {
        provider: 'onec',
        payload: body.qrPayload ?? null,
        imagePngBase64: body.qrImagePng ?? null,
        providerRef: body.reference,
        amount: body.amount,
        issuedAt: this.now().toISOString(),
        expiresAt: body.expiresAt,
        autoConfirm: true,
        providerStatusRaw: body.status,
      };
    } catch (e) {
      throw mapError('issue', e);
    }
  }

  async status(paymentId: string, opts: QrCallOptions = {}): Promise<QrStatusResult> {
    let body: OnecQrPaymentStatus;
    try {
      ({ body } = await this.onec.getQrPaymentStatus(paymentId, callOpts(opts)));
    } catch (e) {
      throw mapError('status', e);
    }
    return {
      state: body.status,
      providerRef: body.reference,
      amount: body.amount,
      paidAmount: body.paidAmount,
      paidAt: body.paidAt,
      bankReference: body.bankReference,
      expiresAt: body.expiresAt,
      documentRef: body.documentRef,
      providerStatusRaw: body.status,
    };
  }

  async cancel(paymentId: string, reason: QrCancelReason, opts: QrCallOptions = {}): Promise<QrCancelResult> {
    try {
      const { body } = await this.onec.cancelQrPayment(paymentId, reason, callOpts(opts));
      return {
        state: body.status,
        paidAmount: body.paidAmount ?? null,
        paidAt: body.paidAt ?? null,
        bankReference: body.bankReference ?? null,
      };
    } catch (e) {
      throw mapError('cancel', e);
    }
  }
}

/** `signal` вызывающего → опции вызова порта 1С (без сигнала — таймаут адаптера, `ONEC_TIMEOUT_MS`). */
function callOpts(opts: QrCallOptions): { signal: AbortSignal } | undefined {
  return opts.signal ? { signal: opts.signal } : undefined;
}

interface OnecErrorShape {
  readonly name: string;
  readonly status: number;
  readonly code: string;
  readonly retryable: boolean;
  readonly message: string;
}

function isOnecErrorShape(e: unknown): e is OnecErrorShape {
  return (
    e instanceof Error &&
    e.name === 'OnecError' &&
    typeof (e as Partial<OnecErrorShape>).status === 'number' &&
    typeof (e as Partial<OnecErrorShape>).code === 'string'
  );
}

/** 5xx/423/транспорт/`POS_E_QR_UNAVAILABLE` → недоступность (qr_pending + warning); прочие 4xx → отказ по существу. */
function mapError(operation: 'issue' | 'status' | 'cancel', e: unknown): Error {
  if (isOnecErrorShape(e)) {
    if (e.retryable || e.code === 'POS_E_QR_UNAVAILABLE' || e.status >= 500) {
      return new QrProviderUnavailableError(operation, true, e.code, `1С: QR недоступен (${e.code})`);
    }
    return new QrProviderRejectedError(operation, e.status, e.code, `1С отклонила операцию QR (${e.code})`);
  }
  return new QrProviderUnavailableError(operation, true, null, '1С: сбой вызова QR');
}

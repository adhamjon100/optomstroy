import type { PaymentProvider, QrCancelResult, QrIssued, QrIssueRequest, QrStatusResult } from './payment-provider.js';

export interface ManualQrProviderOptions {
  /** Статический QR торговой точки (ELQR/EMVCo-строка); `null` — QR не показывается, только ручное подтверждение. */
  readonly staticPayload?: string | null;
  /**
   * Источник статического QR на момент выдачи (модуль `payments`: ключ `app_settings` `qr.static_payload`, 08 §3.10 —
   * меняется администратором без перезапуска). Если задан, имеет приоритет над `staticPayload`.
   */
  readonly staticPayloadSource?: () => Promise<string | null>;
  readonly now?: () => Date;
}

/**
 * `ManualQrProvider` (`QR_PROVIDER=none`, ARCH-063; ядро v1.9 §24.4 — запасной вариант): без внешних вызовов.
 * Показывает статический QR магазина (`QrInfo.provider = elqr_static`, без суммы и срока) или ничего (`none`);
 * оплату подтверждает кассир (`POST /payments/{id}/confirm-manual`, step-up, аудит D-36) — `autoConfirm = false`.
 */
export class ManualQrProvider implements PaymentProvider {
  readonly mode = 'none' as const;
  readonly autoConfirm = false;
  private readonly staticPayload: string | null;
  private readonly staticPayloadSource: (() => Promise<string | null>) | undefined;
  private readonly now: () => Date;

  constructor(options: ManualQrProviderOptions = {}) {
    this.staticPayload = options.staticPayload ?? null;
    this.staticPayloadSource = options.staticPayloadSource;
    this.now = options.now ?? (() => new Date());
  }

  async issue(_req: QrIssueRequest): Promise<QrIssued> {
    const payload = this.staticPayloadSource ? await this.staticPayloadSource() : this.staticPayload;
    return {
      provider: payload ? 'elqr_static' : 'none',
      payload,
      imagePngBase64: null,
      providerRef: null,
      amount: null,
      issuedAt: this.now().toISOString(),
      expiresAt: null,
      autoConfirm: false,
      providerStatusRaw: null,
    };
  }

  /** Статус зачисления провайдер не знает: решение — за кассиром (`manual_confirm`). */
  status(_paymentId: string): Promise<QrStatusResult> {
    return Promise.resolve({
      state: 'unknown',
      providerRef: null,
      amount: null,
      paidAmount: null,
      paidAt: null,
      bankReference: null,
      expiresAt: null,
      documentRef: null,
      providerStatusRaw: null,
    });
  }

  cancel(): Promise<QrCancelResult> {
    return Promise.resolve({ state: 'not_applicable', paidAmount: null, paidAt: null, bankReference: null });
  }
}

import { Inject, Injectable } from '@nestjs/common';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { type QrProviderCode, qrProviderCode } from '../../common/config/qr-provider.js';
import { SettingsReader } from '../../common/settings/settings-reader.js';
import { ManualQrProvider } from '../../integrations/payments/manual-qr.provider.js';
import { PAYMENT_PROVIDER, type PaymentProvider } from '../../integrations/payments/payment-provider.js';

/** Интервал опроса статуса QR у банка, с (08 §6; ADR-123). */
export const BANK_QR_POLL_SECONDS = 30;

/** Ключ `app_settings` со статическим QR торговой точки (08 §3.10 — предложение для 07; Q-014). */
export const QR_STATIC_PAYLOAD_SETTING = 'qr.static_payload';

/**
 * Провайдеры QR модуля `payments` (ARCH-063; ядро §24.4):
 * - `dynamic` — по `QR_PROVIDER`: `onec` → `OnecQrProvider` (порт `OnecGateway`, 05 §6.7); `bank` → `BankQrProvider`
 *   (ADR-123: банк через наш сервер, `BANK_QR_ADAPTER`); при `none` динамического провайдера нет;
 * - `manual` — статический QR магазина (`app_settings.qr.static_payload`) или без payload, подтверждение только
 *   `confirm-manual`: всегда при `QR_PROVIDER=none` и по `manualOnly: true` при `onec` (08 API-185, 10 PAY-053).
 */
@Injectable()
export class QrProviders {
  readonly manual: ManualQrProvider;

  constructor(
    @Inject(PAYMENT_PROVIDER) private readonly configured: PaymentProvider,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    private readonly settings: SettingsReader,
    @Inject(CLOCK) clock: Clock,
  ) {
    this.manual = new ManualQrProvider({
      staticPayloadSource: () => this.staticPayload(),
      now: () => clock.now(),
    });
  }

  /**
   * Код `QR_PROVIDER` развёртывания для хранения (фиксируется в `payments.qr_provider` при создании QR-платежа):
   * `onec | none | bakai` — при `QR_PROVIDER=bank` хранится исторический код `bakai` (ADR-123 п. 3).
   */
  get mode(): QrProviderCode {
    return qrProviderCode(this.config.QR_PROVIDER);
  }

  /** Динамический провайдер (`onec` — 1С, `bank` — банк через наш сервер); `null` при `QR_PROVIDER=none`. */
  get dynamic(): PaymentProvider | null {
    return this.config.QR_PROVIDER === 'none' ? null : this.configured;
  }

  /** Источник провайдера для журнала и аудита (`onec` | `bank`). */
  get source(): 'onec' | 'bank' | 'manual' {
    return this.config.QR_PROVIDER === 'none' ? 'manual' : this.config.QR_PROVIDER;
  }

  /**
   * Интервал опроса статуса QR, с: у 1С — `QR_ONEC_POLL_SECONDS` (05 SYNC-077); у банка — 30 с (08 §6 «если банк
   * не повторяет — опрос статуса каждые 30 с до expiresAt»): основной путь банка — вебхук, опрос — запасной.
   */
  get pollSeconds(): number {
    return this.config.QR_PROVIDER === 'bank' ? BANK_QR_POLL_SECONDS : this.config.QR_ONEC_POLL_SECONDS; // money-double: allow — секунды
  }

  /** Строка статического QR (ELQR/EMVCo) или `null` — только ручное подтверждение без QR. */
  async staticPayload(): Promise<string | null> {
    const v = await this.settings.get(QR_STATIC_PAYLOAD_SETTING);
    if (typeof v === 'string' && v.trim() !== '') return v.trim();
    if (v && typeof v === 'object' && typeof (v as { payload?: unknown }).payload === 'string') {
      const p = (v as { payload: string }).payload.trim();
      return p === '' ? null : p;
    }
    return null;
  }
}

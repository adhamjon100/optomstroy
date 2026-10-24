import { Inject, Injectable } from '@nestjs/common';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { SettingsReader } from '../../common/settings/settings-reader.js';
import { ManualQrProvider } from '../../integrations/payments/manual-qr.provider.js';
import { PAYMENT_PROVIDER, type PaymentProvider } from '../../integrations/payments/payment-provider.js';

/** Ключ `app_settings` со статическим QR торговой точки (08 §3.10 — предложение для 07; Q-014). */
export const QR_STATIC_PAYLOAD_SETTING = 'qr.static_payload';

/**
 * Провайдеры QR модуля `payments` (ARCH-063; ядро §24.4):
 * - `dynamic` — по `QR_PROVIDER`: `onec` → `OnecQrProvider` (порт `OnecGateway`, 05 §6.7); при `none` динамического
 *   провайдера нет;
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

  /** `QR_PROVIDER` развёртывания (фиксируется в `payments.qr_provider` при создании QR-платежа). */
  get mode(): 'onec' | 'none' | 'bakai' {
    return this.config.QR_PROVIDER;
  }

  /** Динамический провайдер (`onec`); `null` при `QR_PROVIDER=none`. */
  get dynamic(): PaymentProvider | null {
    return this.config.QR_PROVIDER === 'onec' ? this.configured : null;
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

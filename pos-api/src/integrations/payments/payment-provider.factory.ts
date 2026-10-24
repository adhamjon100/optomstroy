import { type AppConfig, ConfigError } from '../../common/config/app-config.js';
import type { OnecGateway } from '../onec/onec-gateway.js';
import { ManualQrProvider, type ManualQrProviderOptions } from './manual-qr.provider.js';
import { OnecQrProvider } from './onec-qr.provider.js';
import type { PaymentProvider } from './payment-provider.js';

export type PaymentProviderConfig = Pick<AppConfig, 'QR_PROVIDER' | 'ONEC_MODE' | 'ONEC_INBOUND_ENABLED'>;

export interface PaymentProviderDeps {
  /** Порт 1С — обязателен при `QR_PROVIDER=onec`. */
  readonly onecGateway?: OnecGateway;
  readonly manual?: ManualQrProviderOptions;
}

/**
 * Выбор `PaymentProvider` по `QR_PROVIDER` (ARCH-063, 16 §4.3, DEPLOY-051). Отказ в старте (`ConfigError`):
 * `onec` при `ONEC_MODE=odata_only` или `ONEC_INBOUND_ENABLED=true` (AC-ARCH-063 п. 3; тот же запрет — env.schema.ts);
 * `bakai` — R2, `BakaiQrProvider` в R1 не создаётся (ядро v1.9 §24.4).
 */
export function createPaymentProvider(config: PaymentProviderConfig, deps: PaymentProviderDeps = {}): PaymentProvider {
  switch (config.QR_PROVIDER) {
    case 'none':
      return new ManualQrProvider(deps.manual);
    case 'onec': {
      const problems: string[] = [];
      if (config.ONEC_MODE === 'odata_only') {
        problems.push('QR_PROVIDER: onec требует ONEC_MODE=extension (или fixtures на тестовом контуре)');
      }
      if (config.ONEC_INBOUND_ENABLED) {
        problems.push('QR_PROVIDER: onec несовместим с ONEC_INBOUND_ENABLED=true (05 ONEC-065)');
      }
      if (problems.length > 0) throw new ConfigError(problems);
      if (!deps.onecGateway) throw new Error('OnecQrProvider: не передан порт OnecGateway');
      return new OnecQrProvider(deps.onecGateway);
    }
    case 'bakai':
      throw new ConfigError(['QR_PROVIDER: bakai — релиз R2 (ядро v1.9 §24.4), в R1 не поддерживается']);
  }
}

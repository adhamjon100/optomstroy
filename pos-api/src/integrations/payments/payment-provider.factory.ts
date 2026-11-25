import { type AppConfig, ConfigError } from '../../common/config/app-config.js';
import type { OnecGateway } from '../onec/onec-gateway.js';
import type { BankQrApi } from './bank/bank-qr-api.js';
import { SandboxBankQrApi } from './bank/sandbox-bank-qr.api.js';
import { BankQrProvider } from './bank-qr.provider.js';
import { ManualQrProvider, type ManualQrProviderOptions } from './manual-qr.provider.js';
import { OnecQrProvider } from './onec-qr.provider.js';
import type { PaymentProvider } from './payment-provider.js';

export type PaymentProviderConfig = Pick<AppConfig, 'QR_PROVIDER' | 'ONEC_MODE' | 'ONEC_INBOUND_ENABLED'> &
  Partial<Pick<AppConfig, 'APP_ENV' | 'BANK_QR_ADAPTER'>>;

export interface PaymentProviderDeps {
  /** Порт 1С — обязателен при `QR_PROVIDER=onec`. */
  readonly onecGateway?: OnecGateway;
  /** Клиент банка — обязателен при `QR_PROVIDER=bank` (`createBankQrApi`). */
  readonly bankApi?: BankQrApi | null;
  readonly manual?: ManualQrProviderOptions;
}

export type BankQrApiConfig = Pick<AppConfig, 'QR_PROVIDER'> &
  Partial<Pick<AppConfig, 'APP_ENV' | 'BANK_QR_ADAPTER' | 'QR_WEBHOOK_SECRET'>>;

/**
 * Клиент банка по `BANK_QR_ADAPTER` (ADR-123): `null` при `QR_PROVIDER≠bank`; `sandbox` — песочница банка (не при
 * `APP_ENV=prod` — отказ в старте, как в env.schema.ts). Адаптера настоящего банка нет — `[НЕ ПОДТВЕРЖДЕНО: Q-381]`.
 */
export function createBankQrApi(config: BankQrApiConfig, now?: () => Date): BankQrApi | null {
  if (config.QR_PROVIDER !== 'bank') return null;
  const adapter = config.BANK_QR_ADAPTER ?? 'sandbox';
  if (adapter === 'sandbox') {
    if (config.APP_ENV === 'prod') {
      throw new ConfigError(['BANK_QR_ADAPTER: sandbox (песочница банка) запрещён при APP_ENV=prod (ADR-123)']);
    }
    return new SandboxBankQrApi({ webhookSecret: config.QR_WEBHOOK_SECRET ?? null, ...(now ? { now } : {}) });
  }
  throw new ConfigError([`BANK_QR_ADAPTER: адаптер «${String(adapter)}» не реализован (Q-381)`]);
}

/**
 * Выбор `PaymentProvider` по `QR_PROVIDER` (ARCH-063, 16 §4.3, DEPLOY-051). Отказ в старте (`ConfigError`):
 * `onec` при `ONEC_MODE=odata_only|os_api` или `ONEC_INBOUND_ENABLED=true` (AC-ARCH-063 п. 3; тот же запрет — env.schema.ts);
 * `bank` без клиента банка (`BANK_QR_ADAPTER`) или с песочницей при `APP_ENV=prod` (ADR-123).
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
      if (config.ONEC_MODE === 'os_api') {
        problems.push('QR_PROVIDER: onec недопустим при ONEC_MODE=os_api — QR-оплаты через 1С в ОС_API нет (ADR-126)');
      }
      if (config.ONEC_INBOUND_ENABLED) {
        problems.push('QR_PROVIDER: onec несовместим с ONEC_INBOUND_ENABLED=true (05 ONEC-065)');
      }
      if (problems.length > 0) throw new ConfigError(problems);
      if (!deps.onecGateway) throw new Error('OnecQrProvider: не передан порт OnecGateway');
      return new OnecQrProvider(deps.onecGateway);
    }
    case 'bank': {
      if (config.APP_ENV === 'prod' && (config.BANK_QR_ADAPTER ?? 'sandbox') === 'sandbox') {
        throw new ConfigError(['BANK_QR_ADAPTER: sandbox (песочница банка) запрещён при APP_ENV=prod (ADR-123)']);
      }
      if (!deps.bankApi) throw new ConfigError(['QR_PROVIDER: bank — не создан клиент банка (BANK_QR_ADAPTER)']);
      return new BankQrProvider(deps.bankApi);
    }
  }
}

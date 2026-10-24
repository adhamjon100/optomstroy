import type { Provider } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';

/**
 * Флаг режима клиента `CUSTOMER_SELF_SERVICE` (ядро §24.2: R1, по умолчанию `true`; ядро §19.2: **только env**, не
 * ключ `app_settings`). Обёртка-токен — чтобы тесты переключали флаг без пересборки конфигурации.
 */
export const CUSTOMER_SELF_SERVICE_FLAG = Symbol('CUSTOMER_SELF_SERVICE_FLAG');

export interface SelfServiceFlag {
  enabled(): boolean;
}

export const selfServiceFlagProvider: Provider = {
  provide: CUSTOMER_SELF_SERVICE_FLAG,
  inject: [APP_CONFIG],
  useFactory: (config: Pick<AppConfig, 'CUSTOMER_SELF_SERVICE'>): SelfServiceFlag => {
    const value = config.CUSTOMER_SELF_SERVICE;
    return { enabled: () => value };
  },
};

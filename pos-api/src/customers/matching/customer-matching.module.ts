import { type DynamicModule, Logger, Module, type Provider } from '@nestjs/common';
import { APP_CONFIG, type AppConfig, ConfigError } from '../../common/config/app-config.js';
import { createOnecGateway } from '../../integrations/onec/onec-gateway.factory.js';
import { ONEC_GATEWAY, type OnecGateway } from '../../integrations/onec/onec-gateway.js';
import { OnecGatewayModule } from '../../integrations/onec/onec.module.js';
import { CUSTOMER_MATCHING } from './customer-matching.port.js';
import { PgCustomerMatching } from './pg-customer-matching.js';

export interface CustomerMatchingModuleOptions {
  /**
   * Подключить порт 1С (`OnecGatewayModule`, `ONEC_MODE`). `false` — поиск только по реплике (например, пока боевой
   * адаптер `OnecExtensionGateway` не подключён — RM-E-001; иначе `ONEC_MODE=extension` остановит старт).
   * `'auto'` — порт 1С, если адаптер текущего `ONEC_MODE` доступен; иначе поиск только по реплике с предупреждением
   * в логе (AppModule: на тестовом контуре `fixtures` — поиск 1С, до RM-E-001 в `extension` — только реплика).
   */
  readonly onec: boolean | 'auto';
}

/** `ONEC_GATEWAY` или `null`, если адаптер режима ещё не подключён (до RM-E-001). */
const optionalOnecGateway: Provider = {
  provide: ONEC_GATEWAY,
  inject: [APP_CONFIG],
  useFactory: (c: AppConfig): OnecGateway | null => {
    try {
      return createOnecGateway(c);
    } catch (e) {
      if (!(e instanceof ConfigError) || c.ONEC_MODE === 'fixtures') throw e;
      new Logger('customers').warn(
        { event: 'customers.matching.onec_unavailable', onecMode: c.ONEC_MODE },
        'Адаптер 1С не подключён: поиск карточки клиента — только по реплике',
      );
      return null;
    }
  },
};

/**
 * Порт `CUSTOMER_MATCHING` (RM-D-005). Подключение: `CustomerMatchingModule.forRoot({ onec: true })` в модуле
 * `customers` (интеграция — владелец app.module/customers.module).
 */
@Module({})
export class CustomerMatchingModule {
  static forRoot(options: CustomerMatchingModuleOptions = { onec: true }): DynamicModule {
    return {
      module: CustomerMatchingModule,
      imports: options.onec === true ? [OnecGatewayModule] : [],
      providers: [
        ...(options.onec === 'auto' ? [optionalOnecGateway] : []),
        PgCustomerMatching,
        { provide: CUSTOMER_MATCHING, useExisting: PgCustomerMatching },
      ],
      exports: [CUSTOMER_MATCHING],
    };
  }
}

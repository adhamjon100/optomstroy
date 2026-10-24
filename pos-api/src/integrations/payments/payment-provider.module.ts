import { type DynamicModule, Module } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import type { OnecGateway, OnecGatewayDiKey } from '../onec/onec-gateway.js';
import { createPaymentProvider } from './payment-provider.factory.js';
import { PAYMENT_PROVIDER } from './payment-provider.js';

/** Токен порта 1С без импорта значения из integrations/onec (ARCH-063 п. 4); литерал проверяется типом. */
const ONEC_GATEWAY: OnecGatewayDiKey = 'OnecGateway';

/**
 * Провайдер порта `PaymentProvider` (токен `PAYMENT_PROVIDER`). `onecModule` — модуль, экспортирующий `OnecGateway`
 * (integrations/onec/onec.module.ts); передаётся владельцем сборки (модуль `payments`, RM-F-016).
 */
@Module({})
export class PaymentProviderModule {
  static forRoot(onecModule: DynamicModule | (new () => unknown)): DynamicModule {
    return {
      module: PaymentProviderModule,
      imports: [onecModule],
      providers: [
        {
          provide: PAYMENT_PROVIDER,
          inject: [APP_CONFIG, ONEC_GATEWAY],
          useFactory: (c: AppConfig, onec: OnecGateway) => createPaymentProvider(c, { onecGateway: onec }),
        },
      ],
      exports: [PAYMENT_PROVIDER],
    };
  }
}

import { type DynamicModule, Module } from '@nestjs/common';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import type { OnecGateway, OnecGatewayDiKey } from '../onec/onec-gateway.js';
import { BANK_QR_API, type BankQrApi } from './bank/bank-qr-api.js';
import { createBankQrApi, createPaymentProvider } from './payment-provider.factory.js';
import { PAYMENT_PROVIDER } from './payment-provider.js';

/** Токен порта 1С без импорта значения из integrations/onec (ARCH-063 п. 4); литерал проверяется типом. */
const ONEC_GATEWAY: OnecGatewayDiKey = 'OnecGateway';

/**
 * Провайдер порта `PaymentProvider` (токен `PAYMENT_PROVIDER`) и клиент банка `BANK_QR_API` (ADR-123: `null`, если
 * `QR_PROVIDER≠bank`; песочница — один экземпляр на процесс, его же видит служебный маршрут оплаты песочницы).
 * `onecModule` — модуль, экспортирующий `OnecGateway` (integrations/onec/onec.module.ts); передаётся владельцем сборки
 * (модуль `payments`, RM-F-016).
 */
@Module({})
export class PaymentProviderModule {
  static forRoot(onecModule: DynamicModule | (new () => unknown)): DynamicModule {
    return {
      module: PaymentProviderModule,
      imports: [onecModule],
      providers: [
        {
          provide: BANK_QR_API,
          inject: [APP_CONFIG, { token: CLOCK, optional: true }],
          useFactory: (c: AppConfig, clock?: Clock) => createBankQrApi(c, clock ? () => clock.now() : undefined),
        },
        {
          provide: PAYMENT_PROVIDER,
          inject: [APP_CONFIG, ONEC_GATEWAY, BANK_QR_API],
          useFactory: (c: AppConfig, onec: OnecGateway, bank: BankQrApi | null) =>
            createPaymentProvider(c, { onecGateway: onec, bankApi: bank }),
        },
      ],
      exports: [PAYMENT_PROVIDER, BANK_QR_API],
    };
  }
}

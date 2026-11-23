import { type DynamicModule, Module, type Type } from '@nestjs/common';
import type { AppConfig } from '../../common/config/app-config.js';
import { PaymentsModule } from '../payments.module.js';
import { BankSandboxController } from './bank-sandbox.controller.js';
import { BankWebhookController } from './bank-webhook.controller.js';

/** Какие маршруты банка регистрируются при данной конфигурации (ADR-123; 11 SEC-135). */
export function bankQrControllers(
  config: Pick<AppConfig, 'QR_PROVIDER' | 'QR_WEBHOOK_ENABLED' | 'BANK_QR_ADAPTER' | 'APP_ENV'>,
): Type[] {
  if (config.QR_PROVIDER !== 'bank') return [];
  const out: Type[] = [];
  // Вебхук банка — только при QR_PROVIDER=bank и QR_WEBHOOK_ENABLED=true (иначе маршрута нет → 404).
  if (config.QR_WEBHOOK_ENABLED) out.push(BankWebhookController);
  // Служебные маршруты песочницы — только BANK_QR_ADAPTER=sandbox и не рабочий контур.
  if (config.BANK_QR_ADAPTER === 'sandbox' && config.APP_ENV !== 'prod') out.push(BankSandboxController);
  return out;
}

/**
 * HTTP-маршруты QR банка через наш сервер (ADR-123, P-004): `POST /payments/qr/webhook` и служебные маршруты песочницы
 * `/sandbox/bank/*`. Подключаются по конфигурации при сборке приложения (`AppModule.forRoot`), поэтому при выключенных
 * флагах маршрутов нет вовсе (и в экспорте OpenAPI тоже). Сервисы — модуль `payments`.
 */
@Module({})
export class BankQrHttpModule {
  static forRoot(
    config: Pick<AppConfig, 'QR_PROVIDER' | 'QR_WEBHOOK_ENABLED' | 'BANK_QR_ADAPTER' | 'APP_ENV'>,
  ): DynamicModule {
    return { module: BankQrHttpModule, imports: [PaymentsModule], controllers: bankQrControllers(config) };
  }
}

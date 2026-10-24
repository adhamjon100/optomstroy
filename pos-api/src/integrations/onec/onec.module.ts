import { Module } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { onecAdapters } from './onec-adapters.js';
import { createOnecGateway } from './onec-gateway.factory.js';
import { ONEC_GATEWAY } from './onec-gateway.js';

/**
 * Провайдер порта `OnecGateway` (токен `ONEC_GATEWAY`): реализация — по `ONEC_MODE` (05 ONEC-023):
 * `extension` → `OnecExtensionGateway`, `odata_only` → `OnecODataGateway`, `fixtures` → `FakeOnecGateway`
 * (RM-E-001). Подключение к AppModule/worker — владельцы модулей `sync` и `payments` (этапы E–F).
 */
@Module({
  providers: [
    {
      provide: ONEC_GATEWAY,
      inject: [APP_CONFIG],
      useFactory: (c: AppConfig) => createOnecGateway(c, onecAdapters(c)),
    },
  ],
  exports: [ONEC_GATEWAY],
})
export class OnecGatewayModule {}

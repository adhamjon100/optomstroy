import { Logger, Module } from '@nestjs/common';
import type pg from 'pg';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { PG_POOL } from '../../common/db/database.module.js';
import { createSmsGateway } from './sms-gateway.factory.js';
import { SMS_GATEWAY } from './sms-gateway.js';
import { createSmsTelemetry, SMS_TELEMETRY, type SmsTelemetry } from './sms-telemetry.js';

/**
 * Провайдер порта `SmsGateway` (токен `SMS_GATEWAY`) и телеметрии SMS процесса (`SMS_TELEMETRY`: метрики §6.9,
 * алерты). Использует глобальные `APP_CONFIG` и `PG_POOL`. Подключение — владельцы `auth`/`notifications` и
 * pos-worker (RM-D-002, RM-C-007).
 */
@Module({
  providers: [
    { provide: SMS_TELEMETRY, useFactory: (): SmsTelemetry => createSmsTelemetry(new Logger('sms')) },
    {
      provide: SMS_GATEWAY,
      inject: [APP_CONFIG, PG_POOL, SMS_TELEMETRY],
      useFactory: (c: AppConfig, pool: pg.Pool, telemetry: SmsTelemetry) =>
        createSmsGateway(c, { db: pool, telemetry }),
    },
  ],
  exports: [SMS_GATEWAY, SMS_TELEMETRY],
})
export class SmsGatewayModule {}

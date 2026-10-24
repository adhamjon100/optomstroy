import { Module } from '@nestjs/common';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { OTP_HMAC_SECRET_RING, type SecretRing } from '../../common/crypto/index.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { PgBossService } from '../../common/jobs/pg-boss.service.js';
import type { PosDatabase } from '../../db/database.js';
import { SmsGatewayModule } from '../../integrations/sms/sms.module.js';
import { SMS_GATEWAY, type SmsGateway } from '../../integrations/sms/sms-gateway.js';
import { SMS_TELEMETRY, type SmsTelemetry } from '../../integrations/sms/sms-telemetry.js';
import { SMS_DELIVERY_LISTENER, type SmsDeliveryListener } from './sms-delivery.listener.js';
import { SmsDlrController } from './sms-dlr.controller.js';
import { SmsDlrService } from './sms-dlr.service.js';
import { PgBossSmsJobPublisher, SMS_JOB_PUBLISHER, type SmsJobPublisher } from './sms-job-publisher.js';
import { SmsOutboxRepository } from './sms-outbox.repository.js';
import { SmsOutboxService } from './sms-outbox.service.js';
import { SmsTextSealer } from './sms-text-sealer.js';

/**
 * SMS-контур процесса API (RM-D-002): постановка `sms_outbox` + `sms.send` (`SmsOutboxService.enqueue` — для
 * `SmsOtpProvider`, RM-D-001), признак недоступности канала (`availability()` → синхронный 503), push-DLR
 * `POST /integrations/smspro/dlr`. Обработчики заданий — в pos-worker (`SmsRuntime.register`).
 *
 * Требует глобальных `ConfigModule`, `DatabaseModule` (DRIZZLE, PG_POOL), `JobsModule` (PgBossService) и
 * `CryptoModule` (OTP_HMAC_SECRET_RING). Подключается в `NotificationsModule` (владелец модуля notifications).
 * `SMS_DELIVERY_LISTENER` (реализация — auth/otp) и `CLOCK` — необязательны.
 */
@Module({
  imports: [SmsGatewayModule],
  controllers: [SmsDlrController],
  providers: [
    SmsOutboxRepository,
    {
      provide: SmsTextSealer,
      inject: [OTP_HMAC_SECRET_RING],
      useFactory: (ring: SecretRing) => new SmsTextSealer(ring),
    },
    {
      provide: SMS_JOB_PUBLISHER,
      inject: [PgBossService],
      useFactory: (boss: PgBossService): SmsJobPublisher => new PgBossSmsJobPublisher(() => boss.instance),
    },
    {
      provide: SmsOutboxService,
      inject: [DRIZZLE, SmsOutboxRepository, SMS_GATEWAY, SmsTextSealer, SMS_JOB_PUBLISHER, APP_CONFIG],
      useFactory: (
        db: PosDatabase,
        repo: SmsOutboxRepository,
        gateway: SmsGateway,
        sealer: SmsTextSealer,
        publisher: SmsJobPublisher,
        c: AppConfig,
      ) => new SmsOutboxService({ db, repo, gateway, sealer, publisher, cbOpenMinutes: c.SMSPRO_CB_OPEN_MINUTES }),
    },
    {
      provide: SmsDlrService,
      inject: [
        DRIZZLE,
        SmsOutboxRepository,
        SMS_GATEWAY,
        SMS_TELEMETRY,
        { token: SMS_DELIVERY_LISTENER, optional: true },
        { token: CLOCK, optional: true },
      ],
      useFactory: (
        db: PosDatabase,
        repo: SmsOutboxRepository,
        gateway: SmsGateway,
        telemetry: SmsTelemetry,
        listener?: SmsDeliveryListener,
        clock?: Clock,
      ) =>
        new SmsDlrService({
          db,
          repo,
          gateway,
          telemetry,
          ...(listener ? { listener } : {}),
          ...(clock ? { clock } : {}),
        }),
    },
  ],
  exports: [SmsGatewayModule, SmsOutboxService, SmsDlrService, SmsOutboxRepository, SMS_JOB_PUBLISHER],
})
export class SmsNotificationsModule {}

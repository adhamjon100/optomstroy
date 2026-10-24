import { Module } from '@nestjs/common';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import { OnecGatewayModule } from '../integrations/onec/onec.module.js';
import { ReturnsJobsBridge, ReturnsStatusSyncHandler } from './onec/returns-jobs.bridge.js';
import { ReturnsOnecService } from './onec/returns-onec.service.js';
import { ReturnsController } from './returns.controller.js';
import { ReturnsGuard } from './returns.guard.js';
import { ReturnsRepository } from './returns.repository.js';
import { ReturnsRetentionService } from './returns-retention.service.js';
import { ReturnsService } from './returns.service.js';
import { ReturnsSettings } from './returns.settings.js';

/**
 * Модуль D-06 `returns` (06 §7.4; 08 §4.15; 13 RM-G-005, RM-G-011): заявки на возврат — R1 must (D-25, ядро §21 п. 1),
 * автомат ядра §22.11 (владелец 10 RET). Зависимости — только порты `common/ports` (outbox — `ONEC_OUTBOX_WRITER`,
 * журнал — `TRANSACTIONS_WRITER`, уведомления — `NOTIFICATIONS_PORT`) и общий шлюз 1С (`ONEC_GATEWAY`, для опроса
 * статусов); модули orders/payments/customers не импортируются (MOD-022).
 *
 * Экспорт: `ReturnsOnecService` (события `returns.onec-*`, опрос статусов) и `ReturnsStatusSyncHandler` (прогон
 * `return_docs` в pos-worker). Проекция документов возврата 1С из `/changes` — `ReturnDocsChangeHandler`
 * (src/returns/onec/return-docs.handler.ts, подключается в конвейере синхронизации).
 */
@Module({
  imports: [OnecGatewayModule],
  controllers: [ReturnsController],
  providers: [
    StepUpTokenVerifier,
    ReturnsSettings,
    ReturnsRepository,
    ReturnsGuard,
    ReturnsService,
    ReturnsOnecService,
    ReturnsJobsBridge,
    ReturnsStatusSyncHandler,
    ReturnsRetentionService,
  ],
  exports: [ReturnsOnecService, ReturnsStatusSyncHandler],
})
export class ReturnsModule {}

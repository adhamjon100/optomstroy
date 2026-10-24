import { Module } from '@nestjs/common';
import { StepUpTokenVerifier } from '../../auth/step-up/step-up-token.verifier.js';
import { CREDIT_DECISION_SERVICE, RECEIVABLES_SNAPSHOT_PORT } from '../../common/ports/index.js';
import { OnecGatewayModule } from '../../integrations/onec/onec.module.js';
import {
  CreditCustomerLookup,
  SnapshotCreditDecisionService,
} from '../../sales-domain/adapters/snapshot-credit-decision.service.js';
import { bindSalesPort } from '../../sales-domain/sales-ports.module.js';
import { ReceivablesController, ReceivablesOverdueController } from './receivables.controller.js';
import { ReceivablesRepository } from './receivables.repository.js';
import { ReceivablesService } from './receivables.service.js';
import { ReceivablesSnapshotService } from './receivables-snapshot.service.js';

/**
 * Долги клиентов (модуль `customers`, подмодуль `receivables`; 06 §7.4 `ReceivablesService`; RM-G-002, RM-G-011):
 * `GET /customers/{id}/receivables`, `POST /customers/{id}/receivables/refresh`, `GET /receivables/overdue`.
 * Привязывает порты `RECEIVABLES_SNAPSHOT_PORT` (снимок долга из 1С) и `CREDIT_DECISION_SERVICE` — реальное решение
 * о продаже в долг (10 PAY-031) вместо fail-closed-заглушки этапа F (`SnapshotCreditDecisionService` из
 * sales-domain/adapters). Требует глобальных `SalesPortsModule`, БД, аудита, настроек, `CLOCK`, крипто (курсор).
 */
@Module({
  imports: [OnecGatewayModule],
  controllers: [ReceivablesController, ReceivablesOverdueController],
  providers: [
    ReceivablesRepository,
    ReceivablesService,
    CreditCustomerLookup,
    StepUpTokenVerifier,
    ...bindSalesPort(RECEIVABLES_SNAPSHOT_PORT, ReceivablesSnapshotService),
    ...bindSalesPort(CREDIT_DECISION_SERVICE, SnapshotCreditDecisionService),
  ],
  exports: [ReceivablesSnapshotService],
})
export class ReceivablesModule {}

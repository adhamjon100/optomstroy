import { Module } from '@nestjs/common';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import { PAYMENTS_PORT } from '../common/ports/index.js';
import { OnecGatewayModule } from '../integrations/onec/onec.module.js';
import { PaymentProviderModule } from '../integrations/payments/payment-provider.module.js';
import { bindSalesPort } from '../sales-domain/sales-ports.module.js';
import { PaymentsController } from './api/payments.controller.js';
import { PaymentsStepUpGuard } from './api/payments-step-up.guard.js';
import { PaymentStateWriter } from './app/payment-state.writer.js';
import { PaymentsPortService } from './app/payments-port.service.js';
import { PaymentsService } from './app/payments.service.js';
import { CreditGate } from './credit/credit-gate.js';
// Этап G (RM-G-004, RM-G-013; агент G-be-txn-returns): дашборд кассира и guard оплаты долга без заказа.
import { PosDashboardController } from './dashboard/pos-dashboard.controller.js';
import { PosDashboardService } from './dashboard/pos-dashboard.service.js';
import { DebtPaymentsController } from './debt/debt-payments.controller.js';
import { PaymentJournal } from './infra/payment-journal.js';
import { PaymentNotifier } from './infra/payment-notifier.js';
import { PaymentsLookups } from './infra/payments-lookups.js';
import { PaymentsRepository } from './infra/payments.repository.js';
import { PaymentsJobsBridge } from './jobs/payments-jobs.bridge.js';
import { PaymentStatusWaiter } from './long-poll/payment-status-waiter.js';
import { QrIssuer } from './qr/qr-issuer.service.js';
import { QrProviders } from './qr/qr-providers.js';
import { QrStatusService } from './qr/qr-status.service.js';

/**
 * Модуль D-06 `payments` (06 §7.4; этап F — RM-F-003, RM-F-012, RM-F-016, часть RM-F-015): платежи по заказу
 * (наличные, QR через 1С `QR_PROVIDER=onec` и запасной `none`), ручное подтверждение QR и ручной void (step-up),
 * системное аннулирование при смене способа, long-polling статуса, опрос статуса QR у 1С (pg-boss).
 *
 * - Порт `PAYMENTS_PORT` привязывается здесь (`bindSalesPort`); заказ — только через `ORDER_STATUS_PORT`
 *   (модуль `orders` не импортируется — MOD-022), уведомления — `NOTIFICATIONS_PORT` (если привязан).
 * - Провайдер QR — `PaymentProviderModule` (`QR_PROVIDER`), порт 1С — `OnecGatewayModule` (ARCH-063).
 * - Маршрут `/payments/qr/webhook` в R1 не регистрируется (RM-F-014 — R2).
 * - `CreditGate` — решение о долге через `CREDIT_DECISION_SERVICE` (экспорт для модуля `orders`).
 */
@Module({
  imports: [PaymentProviderModule.forRoot(OnecGatewayModule)],
  controllers: [PaymentsController, PosDashboardController, DebtPaymentsController],
  providers: [
    StepUpTokenVerifier,
    PaymentsStepUpGuard,
    PaymentsRepository,
    PaymentsLookups,
    PaymentJournal,
    PaymentNotifier,
    PaymentStateWriter,
    QrProviders,
    QrStatusService,
    QrIssuer,
    PaymentsJobsBridge,
    PaymentStatusWaiter,
    PaymentsService,
    CreditGate,
    PosDashboardService,
    ...bindSalesPort(PAYMENTS_PORT, PaymentsPortService),
  ],
  exports: [CreditGate, QrStatusService],
})
export class PaymentsModule {}

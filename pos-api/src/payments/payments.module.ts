import { Module } from '@nestjs/common';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import { PAYMENTS_PORT } from '../common/ports/index.js';
import { OnecGatewayModule } from '../integrations/onec/onec.module.js';
import { PaymentProviderModule } from '../integrations/payments/payment-provider.module.js';
import { bindSalesPort } from '../sales-domain/sales-ports.module.js';
import { PaymentsController } from './api/payments.controller.js';
import { BankWebhookService } from './bank/bank-webhook.service.js';
import { QrReconciliationService } from './bank/qr-reconciliation.service.js';
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
import { PaymentOnecDocument } from './onec/payment-onec-document.js';
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
 * - QR банка через наш сервер (`QR_PROVIDER=bank`, ADR-123): `BankWebhookService` (вебхук), `QrReconciliationService`
 *   (ежедневная сверка), `PaymentOnecDocument` (документ оплаты в `onec_outbox`); маршруты вебхука и песочницы
 *   подключает `BankQrHttpModule.forRoot(config)` только при включённых флагах.
 * - `CreditGate` — решение о долге через `CREDIT_DECISION_SERVICE` (экспорт для модуля `orders`).
 */
/** Провайдер QR и клиент банка (`BANK_QR_API`) — один экземпляр на процесс; реэкспорт для `BankQrHttpModule`. */
const PAYMENT_PROVIDER_MODULE = PaymentProviderModule.forRoot(OnecGatewayModule);

@Module({
  imports: [PAYMENT_PROVIDER_MODULE],
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
    PaymentOnecDocument,
    BankWebhookService,
    QrReconciliationService,
    PaymentsJobsBridge,
    PaymentStatusWaiter,
    PaymentsService,
    CreditGate,
    PosDashboardService,
    ...bindSalesPort(PAYMENTS_PORT, PaymentsPortService),
  ],
  exports: [CreditGate, QrStatusService, BankWebhookService, QrReconciliationService, PAYMENT_PROVIDER_MODULE],
})
export class PaymentsModule {}

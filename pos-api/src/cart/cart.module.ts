import { Module } from '@nestjs/common';
import { StepUpTokenVerifier } from '../auth/step-up/step-up-token.verifier.js';
import { CART_READER, CATALOG_PRICING_PORT } from '../common/ports/index.js';
import { OnecGatewayModule } from '../integrations/onec/onec.module.js';
import { bindSalesPort } from '../sales-domain/sales-ports.module.js';
import { CartActorResolver } from './cart-actor.js';
import { CartJobsHandler } from './cart-jobs.js';
import { CartController } from './cart.controller.js';
import { CartRepository } from './cart.repository.js';
import { CartService } from './cart.service.js';
import { CatalogPricingService } from './catalog-pricing.service.js';
import { CheckoutService } from './checkout.service.js';
import { OnecCheckService } from './onec-check.service.js';
import { CustomerSearchModule } from '../customers/search/customer-search.module.js';

/**
 * Модуль D-06 `cart` (06 §7.4; агент F-be-cart: RM-F-001, RM-F-012, RM-F-015): маршруты корзины 08 §4.7, минимальный
 * `GET /search/customers` для SCR-21 (владелец — RM-G-001), `CheckoutPolicy` (`CheckoutService`). Привязывает порты
 * `CART_READER` (заказы: `validateForCheckout`, `markConverted`, `restoreFromOrder`) и `CATALOG_PRICING_PORT`.
 * Не импортирует `catalog`/`orders`/`payments` (MOD-022): каталог — read-only запросы к репликам, остатки этапа E —
 * через `INVENTORY_CHECK_PORT`, долг — `CREDIT_DECISION_SERVICE`, уведомления — `NOTIFICATIONS_PORT`; 1С — порт
 * `ONEC_GATEWAY` (необязательный, глобальный провайдер композиционного корня). Фоновые задачи — `CartJobsHandler`
 * (`registerCartJobs` — регистрирует worker).
 */
@Module({
  // Порт 1С (`ONEC_GATEWAY`, по `ONEC_MODE`) для `/check` (OnecCheckService) — тот же модуль, что у orders/payments
  // (интеграция этапа F: без него синхронная проверка 1С в checkout-preview/POST /orders не выполнялась).
  // `GET /search/customers` — модуль `customers` (RM-G-001, GQ-FND-08; ребро `cart → customers` 06 §7.4).
  imports: [OnecGatewayModule, CustomerSearchModule],
  controllers: [CartController],
  providers: [
    CartActorResolver,
    CartRepository,
    CartService,
    OnecCheckService,
    CartJobsHandler,
    StepUpTokenVerifier,
    ...bindSalesPort(CATALOG_PRICING_PORT, CatalogPricingService),
    ...bindSalesPort(CART_READER, CheckoutService),
  ],
  exports: [CartJobsHandler],
})
export class CartModule {}

import { Global, Module, type Provider, type Type } from '@nestjs/common';
import { CatalogCommonModule } from '../catalog/common/catalog-common.module.js';
import { InventoryModule } from '../catalog/inventory/inventory.module.js';
import {
  CREDIT_DECISION_SERVICE,
  INVENTORY_CHECK_PORT,
  SALES_PORT_TOKENS,
  type SalesPortMap,
  SalesPortRegistry,
  type SalesPortToken,
  TRANSACTIONS_WRITER,
} from '../common/ports/index.js';
import { transactionJournal } from '../common/journal/index.js';
import { CatalogInventoryCheckAdapter } from './adapters/catalog-inventory-check.adapter.js';
import { FailClosedCreditDecisionService } from './adapters/fail-closed-credit.js';

/**
 * Реестр с реализациями по умолчанию: fail-closed долг (до привязки `CreditDecisionService` этапа G, RM-G-002) и
 * общий журнал `transactions` (`TransactionJournal`, common/journal — RM-G-004).
 */
export function createSalesPortRegistry(): SalesPortRegistry {
  return new SalesPortRegistry()
    .setDefault(CREDIT_DECISION_SERVICE, new FailClosedCreditDecisionService())
    .setDefault(TRANSACTIONS_WRITER, transactionJournal);
}

/**
 * Привязка реализации порта модулем-владельцем: добавить в `providers` модуля
 * `...bindSalesPort(PAYMENTS_PORT, PaymentsPortService)` — класс становится провайдером модуля и регистрируется в
 * `SalesPortRegistry` при создании (до обработки запросов). Потребитель: `@Inject(PAYMENTS_PORT) p: PaymentsPort`.
 */
export function bindSalesPort<K extends SalesPortToken>(token: K, impl: Type<SalesPortMap[K]>): Provider[] {
  return [
    impl,
    {
      provide: `sales.bind:${token}`,
      inject: [SalesPortRegistry, impl],
      useFactory: (registry: SalesPortRegistry, instance: SalesPortMap[K]) => {
        registry.bind(token, instance);
        return token;
      },
    },
  ];
}

const proxyProviders: Provider[] = SALES_PORT_TOKENS.map((token) => ({
  provide: token,
  inject: [SalesPortRegistry],
  useFactory: (registry: SalesPortRegistry) => registry.proxy(token),
}));

/**
 * Глобальный модуль портов этапа F: реестр `SalesPortRegistry`, DI-токены всех портов (прокси позднего связывания)
 * и привязка `InventoryCheckPort` к сервису этапа E. Модули cart/orders/payments/notifications/документы друг друга
 * не импортируют (06 §7.4, MOD-022).
 */
@Global()
@Module({
  imports: [CatalogCommonModule, InventoryModule],
  providers: [
    { provide: SalesPortRegistry, useFactory: createSalesPortRegistry },
    ...proxyProviders,
    ...bindSalesPort(INVENTORY_CHECK_PORT, CatalogInventoryCheckAdapter),
  ],
  exports: [SalesPortRegistry, ...SALES_PORT_TOKENS],
})
export class SalesPortsModule {}

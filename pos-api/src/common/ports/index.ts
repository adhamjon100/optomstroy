/**
 * Порты межмодульных вызовов этапов F и G (06 §7.4 `common/ports`): интерфейсы, DI-токены и реестр позднего
 * связывания. Реализации — в модулях-владельцах (привязка `bindSalesPort`, sales-domain/sales-ports.module.ts);
 * заглушки для тестов — `test/support/sales-ports.fakes.ts` (F) и `test/support/cashier-ports.fakes.ts` (G).
 */
export * from './audit-query.port.js';
export * from './cart-reader.port.js';
export * from './catalog-pricing.port.js';
export * from './credit-decision.port.js';
export * from './customer-reader.port.js';
export * from './discount-policy.port.js';
export * from './documents.port.js';
export * from './inventory-check.port.js';
export * from './notifications.port.js';
export * from './onec-outbox-writer.port.js';
export * from './order.ports.js';
export * from './payments.port.js';
export * from './port-registry.js';
export * from './receivables-snapshot.port.js';
export * from './sales-context.js';
export * from './transactions-writer.port.js';

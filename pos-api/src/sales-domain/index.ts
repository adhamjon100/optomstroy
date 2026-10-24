/**
 * Домен продаж этапа F (RM-F-001…RM-F-016): чистые автоматы и правила, общие для cart / orders / payments /
 * documents / notifications. Модули-владельцы только вызывают эти функции и пишут результат в БД.
 *
 * - order/order-status — проекция D-20 (10 §2.2 P1…P10), таблица переходов 07 §6.3, приём оплаты (ядро §22.5),
 *   решение по отмене (ORD-050…ORD-053);
 * - payment/payment-status — автомат 07 §6.4 (ядро §22.2, §23 пп. 3–4, §24.4);
 * - outbox/outbox-status — автомат 07 §6.5 (ядро §22.1, §23 п. 1), backoff — `sync/scheduler/outbox-backoff.ts`;
 * - cart/cart-status — `cart_status` 07 §6.5;
 * - pricing/* — цены, скидки (два этапа, `MoneyMath`), лимит роли, вид цены, способы оплаты, конфликты строк;
 * - credit/credit-decision — порядок PAY-031 (ядро §22.4, §23 п. 5);
 * - idempotency/sales-idempotency — правила ключей (08 §2.7, ядро §22.6) поверх механизма этапа C.
 *
 * Порты межмодульных вызовов — `src/common/ports` (DI-токены, `SalesPortRegistry`); Nest-модуль портов —
 * `SalesPortsModule` (sales-ports.module.ts).
 */
export * from './cart/cart-status.js';
export * from './credit/credit-decision.js';
export * from './domain-error.js';
export * from './idempotency/sales-idempotency.js';
export * from './order/order-status.js';
export * from './outbox/outbox-status.js';
export * from './payment/payment-status.js';
export * from './pricing/cart-conflicts.js';
export * from './pricing/cart-pricing.js';
export * from './pricing/client-money-fields.js';
export * from './pricing/discount-policy.js';
export * from './pricing/payment-methods.js';
export * from './pricing/percent.js';
export * from './pricing/price-list.js';
export { toProblemException, withProblem } from './problem.js';

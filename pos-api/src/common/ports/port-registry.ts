import type { CartReader } from './cart-reader.port.js';
import { CART_READER } from './cart-reader.port.js';
import type { CatalogPricingPort } from './catalog-pricing.port.js';
import { CATALOG_PRICING_PORT } from './catalog-pricing.port.js';
import type { CreditDecisionService } from './credit-decision.port.js';
import { CREDIT_DECISION_SERVICE } from './credit-decision.port.js';
import type { DocumentsPort } from './documents.port.js';
import { DOCUMENTS_PORT } from './documents.port.js';
import type { InventoryCheckPort } from './inventory-check.port.js';
import { INVENTORY_CHECK_PORT } from './inventory-check.port.js';
import type { NotificationsPort } from './notifications.port.js';
import { NOTIFICATIONS_PORT } from './notifications.port.js';
import type { OnecOutboxWriter } from './onec-outbox-writer.port.js';
import { ONEC_OUTBOX_WRITER } from './onec-outbox-writer.port.js';
import type { OrderCreator, OrderStatusPort } from './order.ports.js';
import { ORDER_CREATOR, ORDER_STATUS_PORT } from './order.ports.js';
import type { PaymentsPort } from './payments.port.js';
import { PAYMENTS_PORT } from './payments.port.js';
import type { AuditQueryPort } from './audit-query.port.js';
import { AUDIT_QUERY_PORT } from './audit-query.port.js';
import type { CustomerReader } from './customer-reader.port.js';
import { CUSTOMER_READER } from './customer-reader.port.js';
import type { DiscountPolicyPort } from './discount-policy.port.js';
import { DISCOUNT_POLICY_PORT } from './discount-policy.port.js';
import type { ReceivablesSnapshotPort } from './receivables-snapshot.port.js';
import { RECEIVABLES_SNAPSHOT_PORT } from './receivables-snapshot.port.js';
import type { TransactionsWriter } from './transactions-writer.port.js';
import { TRANSACTIONS_WRITER } from './transactions-writer.port.js';

/** Токен порта → его интерфейс (единый перечень портов этапов F и G; порты G — основа этапа G, RM-G-001…006). */
export interface SalesPortMap {
  [CART_READER]: CartReader;
  [CATALOG_PRICING_PORT]: CatalogPricingPort;
  [INVENTORY_CHECK_PORT]: InventoryCheckPort;
  [ORDER_CREATOR]: OrderCreator;
  [ORDER_STATUS_PORT]: OrderStatusPort;
  [PAYMENTS_PORT]: PaymentsPort;
  [ONEC_OUTBOX_WRITER]: OnecOutboxWriter;
  [DOCUMENTS_PORT]: DocumentsPort;
  [NOTIFICATIONS_PORT]: NotificationsPort;
  [CREDIT_DECISION_SERVICE]: CreditDecisionService;
  // Этап G (кассир): реализации привязывают модули-владельцы G (`bindSalesPort`); `TRANSACTIONS_WRITER` — по
  // умолчанию `TransactionJournal` (common/journal).
  [CUSTOMER_READER]: CustomerReader;
  [RECEIVABLES_SNAPSHOT_PORT]: ReceivablesSnapshotPort;
  [DISCOUNT_POLICY_PORT]: DiscountPolicyPort;
  [TRANSACTIONS_WRITER]: TransactionsWriter;
  [AUDIT_QUERY_PORT]: AuditQueryPort;
}

export type SalesPortToken = keyof SalesPortMap;

export const SALES_PORT_TOKENS: readonly SalesPortToken[] = [
  CART_READER,
  CATALOG_PRICING_PORT,
  INVENTORY_CHECK_PORT,
  ORDER_CREATOR,
  ORDER_STATUS_PORT,
  PAYMENTS_PORT,
  ONEC_OUTBOX_WRITER,
  DOCUMENTS_PORT,
  NOTIFICATIONS_PORT,
  CREDIT_DECISION_SERVICE,
  CUSTOMER_READER,
  RECEIVABLES_SNAPSHOT_PORT,
  DISCOUNT_POLICY_PORT,
  TRANSACTIONS_WRITER,
  AUDIT_QUERY_PORT,
];

/** Порт вызван, но реализация ещё не привязана (модуль-владелец не подключён / не реализован). */
export class PortNotBoundError extends Error {
  override readonly name = 'PortNotBoundError';

  constructor(readonly token: string) {
    super(`Порт ${token} не привязан: модуль-владелец не зарегистрировал реализацию (SalesPortRegistry.bind)`);
  }
}

/** Свойства, которые Nest/Promise/инспекторы читают у значения провайдера: прокси не должен на них реагировать. */
const PASSTHROUGH = new Set([
  'then',
  'catch',
  'finally',
  'constructor',
  'toJSON',
  'inspect',
  'onModuleInit',
  'onApplicationBootstrap',
  'onModuleDestroy',
  'beforeApplicationShutdown',
  'onApplicationShutdown',
]);

/**
 * Позднее связывание портов этапа F (06 §7.4: `orders` не импортирует `payments` и т. д.; «реализации связываются в
 * port-bindings»). Модуль-владелец при создании своего провайдера вызывает `bind(token, impl)` (helper
 * `bindSalesPort` в sales-domain/sales-ports.module.ts); потребитель получает по DI-токену **прокси**, который
 * обращается к привязанной реализации в момент вызова. Так модули разрабатываются и подключаются независимо, а
 * граф импортов остаётся ацикличным (MOD-022).
 *
 * Повторная привязка того же токена другой реализацией — ошибка (кроме `replace`, для тестов). Вызов метода
 * непривязанного порта — `PortNotBoundError` (reject для async-методов).
 */
export class SalesPortRegistry {
  private readonly impls = new Map<SalesPortToken, unknown>();
  private readonly defaults = new Map<SalesPortToken, unknown>();

  /** Реализация по умолчанию (используется, пока владелец не привязал свою; например, fail-closed долг). */
  setDefault<K extends SalesPortToken>(token: K, impl: SalesPortMap[K]): this {
    this.defaults.set(token, impl);
    return this;
  }

  bind<K extends SalesPortToken>(token: K, impl: SalesPortMap[K]): this {
    const cur = this.impls.get(token);
    if (cur !== undefined && cur !== impl) {
      throw new Error(`Порт ${token} уже привязан другой реализацией`);
    }
    this.impls.set(token, impl);
    return this;
  }

  /** Замена реализации (тесты). */
  replace<K extends SalesPortToken>(token: K, impl: SalesPortMap[K]): this {
    this.impls.set(token, impl);
    return this;
  }

  unbind(token: SalesPortToken): void {
    this.impls.delete(token);
  }

  isBound(token: SalesPortToken): boolean {
    return this.impls.has(token);
  }

  /** Привязанная реализация, иначе по умолчанию, иначе `PortNotBoundError`. */
  get<K extends SalesPortToken>(token: K): SalesPortMap[K] {
    const impl = this.impls.get(token) ?? this.defaults.get(token);
    if (impl === undefined) throw new PortNotBoundError(token);
    return impl as SalesPortMap[K];
  }

  /** Прокси порта для DI: методы разрешаются в момент вызова. */
  proxy<K extends SalesPortToken>(token: K): SalesPortMap[K] {
    const target = Object.create(null) as Record<string | symbol, unknown>;
    return new Proxy(target, {
      get: (_t, prop) => {
        if (typeof prop === 'symbol' || PASSTHROUGH.has(prop)) return undefined;
        const impl = (this.impls.get(token) ?? this.defaults.get(token)) as Record<string, unknown> | undefined;
        if (impl === undefined) {
          return () => {
            throw new PortNotBoundError(token);
          };
        }
        const v = impl[prop];
        return typeof v === 'function' ? (v as (...a: unknown[]) => unknown).bind(impl) : v;
      },
      has: (_t, prop) => {
        const impl = (this.impls.get(token) ?? this.defaults.get(token)) as object | undefined;
        return impl !== undefined && prop in impl;
      },
    }) as unknown as SalesPortMap[K];
  }
}

import type { CustomerLinkStatus, CustomerOnecStatus, CustomerSource, CustomerType } from '../enums.js';
import type { MoneyString, SalesActor, SalesTx } from './sales-context.js';

/**
 * `CustomerReader` (этап G, RM-G-001; 06 §7.4 `CustomerService` / `CustomerProjector.forRole` [НОВОЕ ИМЯ]) — чтение
 * карточки клиента (реплика 1С `customers` + `customer_contacts`, поля POS) и полномочий роли на её поля для
 * межмодульных вызовов: `cart`/`orders` (клиент заказа), `payments` (долг), `returns` (клиент заявки),
 * `transactions` (имя клиента строки), `admin.reports`, режим клиента-покупателя (RM-G-014).
 *
 * Реализация — агент G-be-customers (`pos-api/src/customers/**`, привязка `bindSalesPort(CUSTOMER_READER, …)`);
 * до привязки вызов → `PortNotBoundError`. Заглушка для тестов — `test/support/cashier-ports.fakes.ts`
 * (`InMemoryCustomerReader`).
 *
 * Правила видимости (10 CUST-, DEBT-004; 11 §4.3–§4.4; 08 §3.7 `CustomerView*`): DTO строится allow-list полей по
 * роли на сервере; «нет права» = поля нет (не `null`). Суммы долга — только `customer.receivables.read.summary`
 * (`cashier`, `senior_seller`, `admin`, `owner`; `customer` — свой при `customer_links.status=confirmed` по
 * `customer.self.receivables.read`); `seller` — только `hasDebt`/`isOverdue` (Q-017).
 */
export const CUSTOMER_READER = 'sales.CustomerReader' as const;

/** Телефон карточки (08 `CustomerPhone`): `verified` — номер подтверждён OTP привязанного пользователя (CUST-). */
export interface CustomerPhoneView {
  readonly value: string;
  readonly verified: boolean;
}

/**
 * Снимок карточки клиента без фильтрации по роли (доменный вид; фильтрует `CustomerFieldPolicy`/презентер
 * владельца). Деньги — строки `NUMERIC(14,2)`.
 */
export interface CustomerCard {
  readonly id: string;
  readonly name: string;
  readonly customerType: CustomerType;
  readonly source: CustomerSource;
  readonly onecStatus: CustomerOnecStatus;
  readonly onecRef: string | null;
  readonly onecCode: string | null;
  /** Системный «Розничный покупатель» (`customers.is_retail_default`). */
  readonly isRetailDefault: boolean;
  readonly deletionMark: boolean;
  readonly inn: string | null;
  readonly primaryPhoneE164: string | null;
  readonly phones: readonly CustomerPhoneView[];
  readonly priceListId: string | null;
  /** Скидка клиента 1С (`customers.discount_percent`, `"5.00"`); `null` — 1С не отдала. */
  readonly discountPercent: string | null;
  readonly creditAllowed: boolean;
  /** `null` — лимит в 1С не задан (DEBT-012: до Q-017 — блокировка). */
  readonly creditLimit: MoneyString | null;
  readonly creditDays: number | null;
  readonly syncedAt: Date | null;
}

/**
 * Полномочия субъекта на поля карточки (вычисляет реализация по эффективным правам `PermissionCatalog`; одна
 * функция на все ответы — `GET /customers*`, `Cart.customer`, `Order.customer`, `/search/customers`).
 */
export interface CustomerFieldPolicy {
  /** Вид DTO контракта: `CustomerViewSeller` / `CustomerViewCashier` / `CustomerViewAdmin` / `CustomerViewSelf`. */
  readonly view: 'seller' | 'cashier' | 'admin' | 'self';
  /** Полные телефоны, ИНН, адреса, контакты (иначе — `phoneMasked`). */
  readonly fullContacts: boolean;
  /** Суммы долга (`receivable`, `creditLimit`) — `customer.receivables.read.summary` или свой долг клиента. */
  readonly receivableAmounts: boolean;
  /** Детализация долга (`documents[]`) — `customer.receivables.read.detail` + step-up (DEBT-005). */
  readonly receivableDetail: boolean;
  /** История покупок (`customer.history.read` или своя при confirmed). */
  readonly history: boolean;
  /** `isFavorite` (`favorites.customers.manage`). */
  readonly favorites: boolean;
  /** Служебные поля 1С (`source`, `onecStatus`, `onecRef`, `syncedAt`) — сотрудники. */
  readonly serviceFields: boolean;
}

/** Доступ субъекта к конкретной карточке. */
export type CustomerAccess =
  | { readonly kind: 'staff'; readonly policy: CustomerFieldPolicy }
  /** Клиент-покупатель — только своя карточка при `customer_links.status=confirmed` (CUST-025, SEC-030). */
  | { readonly kind: 'self'; readonly policy: CustomerFieldPolicy; readonly linkId: string };

export interface CustomerReader {
  /** Карточка по `id` (включая помеченные на удаление); `null` — нет такой. Без проверки прав. */
  get(tx: SalesTx | null, customerId: string): Promise<CustomerCard | null>;

  /** Карточка по `onec_ref` (реплика 1С); `null` — нет. Без проверки прав. */
  getByOnecRef(tx: SalesTx | null, onecRef: string): Promise<CustomerCard | null>;

  /**
   * Карточка, если субъект вправе её видеть: сотрудник с `customer.read.basic` — любая; `customer` — только
   * привязанная со статусом `confirmed` (иначе `null` → вызывающий отвечает `404`, а не `403` — 08 AC-API-179).
   */
  getForActor(
    tx: SalesTx | null,
    actor: SalesActor,
    customerId: string,
  ): Promise<{ readonly card: CustomerCard; readonly access: CustomerAccess } | null>;

  /** Полномочия роли на поля карточки (без обращения к БД). */
  fieldPolicy(actor: SalesActor): CustomerFieldPolicy;

  /**
   * Клиент, к которому привязан пользователь-покупатель: `{customerId, status}` последней привязки или `null`.
   * Режим клиента (RM-G-014): свои долг и история — только при `status = 'confirmed'`.
   */
  linkOf(
    tx: SalesTx | null,
    userId: string,
  ): Promise<{ readonly customerId: string; readonly status: CustomerLinkStatus; readonly linkId: string } | null>;
}

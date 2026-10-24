import { maskPhone } from '../../common/logging/redaction.js';
import type { CustomerFieldPolicy } from '../../common/ports/index.js';
import { customerDisplayName } from '../../common/presenters/customer-name.js';
import { type CustomerRow, phonesOf, phoneVerified } from './customer-rows.js';

/** Деньги API (08 §2.14, `Money`). */
export function moneyDto(amount: string): { amount: string; currency: 'KGS' } {
  return { amount, currency: 'KGS' };
}

/** Необязательные части карточки (только `GET /customers/{id}` с `include=`, право проверяет вызывающий). */
export interface CustomerExtras {
  readonly receivable?: Readonly<Record<string, unknown>> | null;
  readonly discounts?: Readonly<Record<string, unknown>> | null;
  readonly links?: readonly Readonly<Record<string, unknown>>[] | null;
  readonly contacts?:
    readonly { readonly kind: string; readonly value: string; readonly label: string | null }[] | null;
  /** Адреса доставки (контакты `kind = address`); отдаются ролям с полными контактами. */
  readonly addresses?: readonly string[] | null;
}

/**
 * `CustomerProjector.forRole` (06 §7.4, B-AR-17; 08 §3.7; OpenAPI `CustomerViewSeller|Cashier|Admin|Self`):
 * сериализация по allowlist вида DTO — поля, не разрешённые роли, **отсутствуют** (а не `null`). В списках сумм долга
 * нет (`receivable` передаётся только из `GET /customers/{id}?include=receivable` и поиска с `include=receivable`
 * при праве) — только флаги `hasDebt`/`isOverdue` (ядро §22.13 п. 1). `seller` — `phoneMasked` вместо телефонов,
 * без ИНН, адресов, контактов, избранного (Q-017 — допущение ТЗ).
 */
export function projectCustomer(
  row: CustomerRow,
  policy: CustomerFieldPolicy,
  extras: CustomerExtras = {},
): Record<string, unknown> {
  const out: Record<string, unknown> = {
    id: row.id,
    name: row.name,
    displayName: customerDisplayName(row.name),
    customerType: row.customerType,
  };
  if (row.onecCode) out.onecCode = row.onecCode;
  out.isRetailDefault = row.isRetailDefault;
  const phones = phonesOf(row);
  if (policy.view === 'seller') {
    if (phones[0]) out.phoneMasked = maskPhone(phones[0]);
  } else {
    out.phones = phones.map((value) => ({ value, verified: phoneVerified(row, value) }));
    if (row.inn) out.inn = row.inn;
  }
  if (row.priceListId && row.priceListName) out.priceList = { id: row.priceListId, name: row.priceListName };
  if (row.discountPercent !== null) out.discountPercent = row.discountPercent;
  out.creditAllowed = row.creditAllowed;
  out.hasDebt = row.hasDebt;
  out.isOverdue = row.isOverdue;
  if (extras.receivable && policy.receivableAmounts) out.receivable = extras.receivable;
  out.ordersCount = row.ordersCount;
  out.lastOrderAt = row.lastOrderAt ? row.lastOrderAt.toISOString() : null;
  if (extras.discounts) out.discounts = extras.discounts;
  if (policy.fullContacts) {
    if (extras.addresses) out.addresses = [...extras.addresses];
    if (extras.contacts) {
      out.contacts = extras.contacts.map((c) => ({
        kind: c.kind,
        value: c.value,
        ...(c.label ? { name: c.label } : {}),
      }));
    }
  }
  if ((policy.view === 'admin' || policy.view === 'self') && extras.links) out.links = [...extras.links];
  if (policy.view !== 'self' && policy.view !== 'seller' && policy.favorites) out.isFavorite = row.isFavorite;
  if (policy.serviceFields) {
    out.source = row.source;
    out.onecStatus = row.onecStatus;
    out.onecRef = row.onecRef;
    out.syncedAt = row.syncedAt ? row.syncedAt.toISOString() : null;
  }
  return out;
}

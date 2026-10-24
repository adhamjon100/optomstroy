import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { maskPhone } from '../common/logging/redaction.js';
import { customerDisplayName } from '../common/presenters/customer-name.js';
import { iso, rows } from './cart-common.js';

/** Строка клиента для ролевого представления (07 §5.21 `customers` + флаги долга `receivables`). */
export interface CustomerViewRow {
  readonly id: string;
  readonly name: string;
  readonly customer_type: string;
  readonly onec_code: string | null;
  readonly onec_ref: string | null;
  readonly source: string;
  readonly onec_status: string;
  readonly is_retail_default: boolean;
  readonly inn: string | null;
  readonly primary_phone_e164: string | null;
  readonly phones_norm: string[] | null;
  readonly price_list_id: string | null;
  readonly price_list_name: string | null;
  readonly discount_percent: string | null;
  readonly credit_allowed: boolean;
  readonly synced_at: Date | null;
  readonly has_debt: boolean;
  readonly is_overdue: boolean;
  readonly deletion_mark: boolean;
  readonly deleted_at: Date | null;
}

export async function loadCustomers(ex: DbExecutor, ids: readonly string[]): Promise<Map<string, CustomerViewRow>> {
  const uniq = [...new Set(ids)];
  if (uniq.length === 0) return new Map();
  const r = await rows<CustomerViewRow>(
    ex,
    sql`SELECT c.id, c.name, c.customer_type::text AS customer_type, c.onec_code, c.onec_ref::text AS onec_ref,
               c.source::text AS source, c.onec_status::text AS onec_status, c.is_retail_default, c.inn,
               c.primary_phone_e164, c.phones_norm, c.default_price_list_id AS price_list_id, pl.name AS price_list_name,
               c.discount_percent::text AS discount_percent, c.credit_allowed, c.synced_at,
               coalesce(r.balance > 0, false) AS has_debt, coalesce(r.overdue_amount > 0, false) AS is_overdue,
               c.deletion_mark, c.deleted_at
          FROM customers c
          LEFT JOIN price_lists pl ON pl.id = c.default_price_list_id
          LEFT JOIN receivables r ON r.customer_id = c.id
         WHERE c.id = ANY(${sql.param(uniq)}::uuid[])`,
  );
  return new Map(r.map((x) => [x.id, x]));
}

/**
 * `Customer` по allowlist роли (08 §3.7; OpenAPI `CustomerViewSeller|Cashier|Admin|Self`; 11 SEC-031, SEC-042):
 * поля, не разрешённые роли, отсутствуют (а не `null`). В корзине (`Cart.customer`) и в поиске суммы долга не
 * отдаются — только флаги `hasDebt`/`isOverdue` (ядро §22.13 п. 1). `seller` — маскированный телефон.
 */
export function customerDto(c: CustomerViewRow, role: string, isCustomer: boolean): Record<string, unknown> {
  const base: Record<string, unknown> = {
    id: c.id,
    name: c.name,
    displayName: customerDisplayName(c.name),
    customerType: c.customer_type,
    ...(c.onec_code ? { onecCode: c.onec_code } : {}),
    isRetailDefault: c.is_retail_default,
    ...(c.price_list_id && c.price_list_name ? { priceList: { id: c.price_list_id, name: c.price_list_name } } : {}),
    ...(c.discount_percent !== null ? { discountPercent: c.discount_percent } : {}),
    creditAllowed: c.credit_allowed,
    hasDebt: c.has_debt,
    isOverdue: c.is_overdue,
  };
  const phones = (): { value: string; verified: boolean }[] => {
    const all = new Set<string>();
    if (c.primary_phone_e164) all.add(c.primary_phone_e164);
    for (const p of c.phones_norm ?? []) if (/^\+996\d{9}$/.test(p)) all.add(p);
    return [...all].map((value) => ({ value, verified: false }));
  };
  const onecMeta = {
    source: c.source,
    onecStatus: c.onec_status,
    onecRef: c.onec_ref,
    syncedAt: iso(c.synced_at),
  };
  if (isCustomer || role === 'customer') {
    return { ...base, phones: phones(), ...(c.inn ? { inn: c.inn } : {}) };
  }
  if (role === 'seller') {
    const phone = c.primary_phone_e164 ?? (c.phones_norm ?? []).find((p) => /^\+996\d{9}$/.test(p));
    return { ...base, ...(phone ? { phoneMasked: maskPhone(phone) } : {}), ...onecMeta };
  }
  return { ...base, phones: phones(), ...(c.inn ? { inn: c.inn } : {}), ...onecMeta };
}

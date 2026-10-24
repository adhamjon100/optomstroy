import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { CustomerOnecStatus, CustomerSource, CustomerType } from '../../common/enums.js';

/**
 * Строка карточки клиента для представлений (07 §5.28 `customers` + флаги долга `receivables` + сводка истории
 * `orders`/`shipments` + избранное субъекта). Деньги — строки `NUMERIC(14,2)`.
 */
export interface CustomerRow {
  readonly id: string;
  readonly name: string;
  readonly customerType: CustomerType;
  readonly onecCode: string | null;
  readonly onecRef: string | null;
  readonly source: CustomerSource;
  readonly onecStatus: CustomerOnecStatus;
  readonly isRetailDefault: boolean;
  readonly inn: string | null;
  readonly primaryPhoneE164: string | null;
  readonly phonesNorm: readonly string[];
  readonly priceListId: string | null;
  readonly priceListName: string | null;
  readonly discountPercent: string | null;
  readonly creditAllowed: boolean;
  readonly creditLimit: string | null;
  readonly creditDays: number | null;
  readonly syncedAt: Date | null;
  readonly deletionMark: boolean;
  readonly hasDebt: boolean;
  readonly isOverdue: boolean;
  readonly ordersCount: number; // money-double: allow — число документов, не деньги
  readonly lastOrderAt: Date | null;
  readonly isFavorite: boolean;
  /** Номера, подтверждённые OTP при привязке аккаунта (`customer_links.status = confirmed`, CUST-003). */
  readonly verifiedPhones: readonly string[];
}

interface RawRow extends Record<string, unknown> {
  id: string;
  name: string;
  customer_type: CustomerType;
  onec_code: string | null;
  onec_ref: string | null;
  source: CustomerSource;
  onec_status: CustomerOnecStatus;
  is_retail_default: boolean;
  inn: string | null;
  primary_phone_e164: string | null;
  phones_norm: string[] | null;
  price_list_id: string | null;
  price_list_name: string | null;
  discount_percent: string | null;
  credit_allowed: boolean;
  credit_limit: string | null;
  credit_days: number | null;
  synced_at: Date | string | null;
  deletion_mark: boolean;
  has_debt: boolean;
  is_overdue: boolean;
  orders_count: number;
  last_order_at: Date | string | null;
  is_favorite: boolean;
  verified_phones: string[] | null;
}

function toDate(v: Date | string | null): Date | null {
  if (v === null) return null;
  return v instanceof Date ? v : new Date(v);
}

/**
 * «История: N заказов» и дата последней покупки (08 §3.7 `ordersCount`, `lastOrderAt`): заказы POS (кроме
 * черновиков и отменённых) + проведённые реализации 1С без заказа POS (реализация по заказу POS — тот же заказ).
 * «Розничный покупатель» — без истории (10 CUST-018).
 */
export const ORDERS_COUNT_SQL = sql`
  CASE WHEN c.is_retail_default THEN 0 ELSE
    (SELECT count(*)::int FROM orders o WHERE o.customer_id = c.id AND o.status NOT IN ('draft','cancelled'))
    + (SELECT count(*)::int FROM shipments s
        WHERE s.customer_id = c.id AND s.posted AND NOT s.deletion_mark AND s.order_id IS NULL) END`;

export const LAST_ORDER_AT_SQL = sql`
  CASE WHEN c.is_retail_default THEN NULL ELSE GREATEST(
    (SELECT max(o.created_at) FROM orders o WHERE o.customer_id = c.id AND o.status NOT IN ('draft','cancelled')),
    (SELECT max(s.onec_date) FROM shipments s
      WHERE s.customer_id = c.id AND s.posted AND NOT s.deletion_mark AND s.order_id IS NULL)) END`;

/** Номера карточки, подтверждённые OTP при привязке (`customer_links.matched_phone_e164`, `confirmed`). */
export const VERIFIED_PHONES_SQL = sql`
  (SELECT coalesce(array_agg(DISTINCT l.matched_phone_e164) FILTER (WHERE l.matched_phone_e164 IS NOT NULL), '{}')
     FROM customer_links l WHERE l.customer_id = c.id AND l.status = 'confirmed')`;

/** Карточки по id (включая помеченные на удаление; `deleted_at IS NOT NULL` — нет). Порядок — как в `ids`. */
export async function loadCustomerRows(
  ex: DbExecutor,
  ids: readonly string[],
  viewerUserId: string | null,
): Promise<CustomerRow[]> {
  const uniq = [...new Set(ids)];
  if (uniq.length === 0) return [];
  const fav = viewerUserId
    ? sql`EXISTS (SELECT 1 FROM favorites_customers f WHERE f.customer_id = c.id AND f.user_id = ${viewerUserId}::uuid)`
    : sql`false`;
  const r = await ex.execute<RawRow>(sql`
    SELECT c.id, c.name, c.customer_type::text AS customer_type, c.onec_code, c.onec_ref::text AS onec_ref,
           c.source::text AS source, c.onec_status::text AS onec_status, c.is_retail_default, c.inn,
           c.primary_phone_e164, c.phones_norm, c.default_price_list_id::text AS price_list_id,
           pl.name AS price_list_name, c.discount_percent::text AS discount_percent, c.credit_allowed,
           c.credit_limit::text AS credit_limit, c.credit_days::int AS credit_days, c.synced_at, c.deletion_mark,
           coalesce(r.balance > 0, false) AS has_debt, coalesce(r.overdue_amount > 0, false) AS is_overdue,
           ${ORDERS_COUNT_SQL} AS orders_count, ${LAST_ORDER_AT_SQL} AS last_order_at, ${fav} AS is_favorite,
           ${VERIFIED_PHONES_SQL} AS verified_phones
      FROM customers c
      LEFT JOIN price_lists pl ON pl.id = c.default_price_list_id
      LEFT JOIN receivables r ON r.customer_id = c.id
     WHERE c.id = ANY(${sql.param(uniq)}::uuid[]) AND c.deleted_at IS NULL`);
  const byId = new Map(r.rows.map((x) => [x.id, x]));
  const out: CustomerRow[] = [];
  for (const id of ids) {
    const x = byId.get(id);
    if (!x) continue;
    out.push({
      id: x.id,
      name: x.name,
      customerType: x.customer_type,
      onecCode: x.onec_code,
      onecRef: x.onec_ref,
      source: x.source,
      onecStatus: x.onec_status,
      isRetailDefault: x.is_retail_default,
      inn: x.inn,
      primaryPhoneE164: x.primary_phone_e164,
      phonesNorm: x.phones_norm ?? [],
      priceListId: x.price_list_id,
      priceListName: x.price_list_name,
      discountPercent: x.discount_percent,
      creditAllowed: x.credit_allowed,
      creditLimit: x.credit_limit,
      creditDays: x.credit_days === null ? null : Number(x.credit_days), // money-double: allow — дни отсрочки
      syncedAt: toDate(x.synced_at),
      deletionMark: x.deletion_mark,
      hasDebt: x.has_debt,
      isOverdue: x.is_overdue,
      ordersCount: Number(x.orders_count), // money-double: allow — число документов
      lastOrderAt: toDate(x.last_order_at),
      isFavorite: x.is_favorite,
      verifiedPhones: x.verified_phones ?? [],
    });
  }
  return out;
}

/** Живые контакты карточки (`customer_contacts`, `deleted_at IS NULL`): основной — первым. */
export async function loadContacts(
  ex: DbExecutor,
  customerId: string,
): Promise<{ kind: string; value: string; label: string | null }[]> {
  const r = await ex.execute<{ kind: string; value: string; label: string | null }>(sql`
    SELECT kind::text AS kind, value, label FROM customer_contacts
     WHERE customer_id = ${customerId}::uuid AND deleted_at IS NULL
     ORDER BY is_primary DESC, kind, onec_line_key NULLS LAST, created_at, id`);
  return r.rows;
}

/** Телефоны карточки (E.164 КР): основной первым, без повторов. */
export function phonesOf(row: Pick<CustomerRow, 'primaryPhoneE164' | 'phonesNorm'>): string[] {
  const all = new Set<string>();
  if (row.primaryPhoneE164) all.add(row.primaryPhoneE164);
  for (const p of row.phonesNorm) if (/^\+996\d{9}$/.test(p)) all.add(p);
  return [...all];
}

/**
 * `phones[].verified` (10 CUST-003, ядро §19.2): номер карточки помечается «подтверждён», если он совпадает с
 * номером, подтверждённым OTP при привязке аккаунта (`customer_links.status = confirmed`); иначе — «не подтверждён»
 * (подтверждение при создании в POS — R2, CUST-013). Правило самоподтверждения привязки D (LNK-01, Q-315) — отдельно.
 */
export function phoneVerified(row: Pick<CustomerRow, 'verifiedPhones'>, phone: string): boolean {
  return row.verifiedPhones.includes(phone);
}

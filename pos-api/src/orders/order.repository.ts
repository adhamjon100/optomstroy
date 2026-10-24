import { sql } from 'drizzle-orm';
import type { OnecSyncState, OrderStatus, OutboxStatus, PaymentMethod, StatusChangeSource } from '../common/enums.js';
import type { SalesTx } from '../common/ports/index.js';

/**
 * Доступ к таблицам модуля `orders` (07 §5.37–§5.39): `orders`, `order_items`, `order_status_history` и чтение строк
 * `onec_outbox` агрегата `order`. Чистый SQL через Drizzle `sql` (как в модулях этапов D–E); деньги и количества —
 * NUMERIC-строки (D-19), без приведения к числам JS.
 */

export interface OrderRow extends Record<string, unknown> {
  id: string;
  public_number: string;
  status: OrderStatus;
  cart_id: string | null;
  customer_id: string;
  created_by_user_id: string;
  created_via: 'staff' | 'customer';
  device_id: string | null;
  warehouse_id: string;
  price_list_id: string;
  subtotal: string;
  discount_percent: string;
  customer_discount_percent: string | null;
  customer_discount_total: string;
  manual_discount_total: string;
  discount_total: string;
  total: string;
  onec_total: string | null;
  totals_differ: boolean;
  payment_method: PaymentMethod;
  credit_due_date: string | null;
  paid_amount: string;
  paid_at: Date | null;
  is_paid: boolean;
  delivery_method: 'pickup' | 'delivery';
  receiver_kind: 'customer' | 'other_person';
  receiver_name: string | null;
  receiver_phone_e164: string | null;
  delivery_recipient_phone_e164: string | null;
  delivery_address: string | null;
  delivery_comment: string | null;
  delivery_date: string | null;
  delivery_time_from: string | null;
  delivery_time_to: string | null;
  print_options: Record<string, boolean>;
  comment: string | null;
  onec_ref: string | null;
  onec_number: string | null;
  onec_date: Date | null;
  onec_status_raw: string | null;
  onec_last_sync_at: Date | null;
  onec_sync_state: OnecSyncState;
  submitted_at: Date | null;
  approved_at: Date | null;
  shipped_at: Date | null;
  closed_at: Date | null;
  cancelled_at: Date | null;
  cancel_reason: string | null;
  cancel_reason_code: 'customer_refused' | 'duplicate' | 'error' | 'other' | null;
  refund_intent: 'none' | 'refund' | 'advance' | null;
  cancel_requested_at: Date | null;
  cancel_requested_by_user_id: string | null;
  submit_error_code: string | null;
  submit_error_message: string | null;
  idempotency_key: string | null;
  row_version: number;
  created_at: Date;
  updated_at: Date;
  has_return: boolean;
}

const ORDER_COLUMNS = sql.raw(`
  o.id, o.public_number, o.status::text AS status, o.cart_id, o.customer_id, o.created_by_user_id, o.created_via,
  o.device_id, o.warehouse_id, o.price_list_id, o.subtotal::text AS subtotal, o.discount_percent::text AS discount_percent,
  o.customer_discount_percent::text AS customer_discount_percent,
  o.customer_discount_total::text AS customer_discount_total, o.manual_discount_total::text AS manual_discount_total,
  o.discount_total::text AS discount_total, o.total::text AS total, o.onec_total::text AS onec_total, o.totals_differ,
  o.payment_method::text AS payment_method, o.credit_due_date::text AS credit_due_date,
  o.paid_amount::text AS paid_amount, o.paid_at, o.is_paid, o.delivery_method::text AS delivery_method,
  o.receiver_kind::text AS receiver_kind, o.receiver_name, o.receiver_phone_e164, o.delivery_recipient_phone_e164,
  o.delivery_address, o.delivery_comment, o.delivery_date::text AS delivery_date,
  to_char(o.delivery_time_from, 'HH24:MI') AS delivery_time_from, to_char(o.delivery_time_to, 'HH24:MI') AS delivery_time_to,
  o.print_options, o.comment, o.onec_ref::text AS onec_ref, o.onec_number, o.onec_date, o.onec_status_raw,
  o.onec_last_sync_at, o.onec_sync_state::text AS onec_sync_state, o.submitted_at, o.approved_at, o.shipped_at,
  o.closed_at, o.cancelled_at, o.cancel_reason, o.cancel_reason_code, o.refund_intent, o.cancel_requested_at,
  o.cancel_requested_by_user_id, o.submit_error_code, o.submit_error_message, o.idempotency_key, o.row_version,
  o.created_at, o.updated_at,
  EXISTS (SELECT 1 FROM order_items ri WHERE ri.order_id = o.id AND ri.returned_quantity > 0) AS has_return`);

export const orderColumnsSql = ORDER_COLUMNS;

/** Литерал массива PostgreSQL (`{a,b}`) для `ANY($1::uuid[])`: Drizzle разворачивает массив JS в кортеж. */
export function pgArray(values: readonly string[]): string {
  return `{${values.map((v) => `"${v.replace(/["\\]/g, '')}"`).join(',')}}`;
}

export async function findOrder(tx: SalesTx, id: string, forUpdate = false): Promise<OrderRow | null> {
  const r = await tx.execute<OrderRow>(
    forUpdate
      ? sql`SELECT ${ORDER_COLUMNS} FROM orders o WHERE o.id = ${id}::uuid FOR UPDATE OF o`
      : sql`SELECT ${ORDER_COLUMNS} FROM orders o WHERE o.id = ${id}::uuid`,
  );
  return r.rows[0] ?? null;
}

export interface OrderItemRow extends Record<string, unknown> {
  line_no: number;
  variant_id: string;
  product_id: string;
  packaging_id: string | null;
  quantity: string;
  base_quantity: string;
  unit_code_snapshot: string;
  packaging_name_snapshot: string | null;
  packaging_factor_snapshot: string | null;
  unit_price: string;
  line_subtotal: string;
  discount_percent: string;
  customer_discount_amount: string;
  manual_discount_amount: string;
  discount_amount: string;
  line_total: string;
  product_name_snapshot: string;
  variant_name_snapshot: string | null;
  sku_snapshot: string | null;
  barcode_snapshot: string | null;
  shipped_quantity: string;
  returned_quantity: string;
  unit_id: string | null;
}

export async function findOrderItems(tx: SalesTx, orderId: string): Promise<OrderItemRow[]> {
  const r = await tx.execute<OrderItemRow>(sql`
    SELECT i.line_no, i.variant_id, i.product_id, i.packaging_id, i.quantity::text AS quantity,
           i.base_quantity::text AS base_quantity, i.unit_code_snapshot, i.packaging_name_snapshot,
           i.packaging_factor_snapshot::text AS packaging_factor_snapshot, i.unit_price::text AS unit_price,
           i.line_subtotal::text AS line_subtotal, i.discount_percent::text AS discount_percent,
           i.customer_discount_amount::text AS customer_discount_amount,
           i.manual_discount_amount::text AS manual_discount_amount, i.discount_amount::text AS discount_amount,
           i.line_total::text AS line_total, i.product_name_snapshot, i.variant_name_snapshot, i.sku_snapshot,
           i.barcode_snapshot, i.shipped_quantity::text AS shipped_quantity,
           i.returned_quantity::text AS returned_quantity, p.base_unit_id AS unit_id
      FROM order_items i LEFT JOIN products p ON p.id = i.product_id
     WHERE i.order_id = ${orderId}::uuid ORDER BY i.line_no`);
  return r.rows;
}

export interface HistoryRow extends Record<string, unknown> {
  from_status: OrderStatus | null;
  to_status: OrderStatus;
  source: StatusChangeSource;
  actor_user_id: string | null;
  occurred_at: Date;
  reason: string | null;
}

export async function findHistory(tx: SalesTx, orderId: string): Promise<HistoryRow[]> {
  const r = await tx.execute<HistoryRow>(sql`
    SELECT from_status::text AS from_status, to_status::text AS to_status, source::text AS source, actor_user_id,
           occurred_at, reason
      FROM order_status_history WHERE order_id = ${orderId}::uuid ORDER BY occurred_at, id`);
  return r.rows;
}

export async function insertHistory(
  tx: SalesTx,
  h: {
    readonly orderId: string;
    readonly from: OrderStatus | null;
    readonly to: OrderStatus;
    readonly source: StatusChangeSource;
    readonly actorUserId: string | null;
    readonly onecStatusRaw?: string | null;
    readonly reason?: string | null;
    readonly errorCode?: string | null;
    readonly requestId?: string | null;
    readonly syncRunId?: string | null;
  },
): Promise<void> {
  await tx.execute(sql`
    INSERT INTO order_status_history (order_id, from_status, to_status, source, actor_user_id, onec_status_raw, reason,
                                      error_code, request_id, sync_run_id, occurred_at)
    VALUES (${h.orderId}::uuid, ${h.from}::order_status, ${h.to}::order_status, ${h.source}::status_change_source,
            ${h.actorUserId}::uuid, ${h.onecStatusRaw ?? null}, ${h.reason ?? null}, ${h.errorCode ?? null},
            ${h.requestId ?? null}, ${h.syncRunId ?? null}::uuid, clock_timestamp())`);
}

export interface OrderOutboxRow extends Record<string, unknown> {
  id: string;
  operation: 'create' | 'cancel';
  status: OutboxStatus;
  attempts: number;
  onec_ref: string | null;
  last_error_code: string | null;
  last_error: string | null;
  onec_response: Record<string, unknown> | null;
  sent_at: Date | null;
}

export async function findOrderOutbox(
  tx: SalesTx,
  orderId: string,
  operation: 'create' | 'cancel',
): Promise<OrderOutboxRow | null> {
  const r = await tx.execute<OrderOutboxRow>(sql`
    SELECT id, operation, status::text AS status, attempts, onec_ref::text AS onec_ref, last_error_code, last_error,
           onec_response, sent_at
      FROM onec_outbox
     WHERE aggregate_type = 'order' AND aggregate_id = ${orderId}::uuid AND operation = ${operation}`);
  return r.rows[0] ?? null;
}

export async function findOutboxById(
  tx: SalesTx,
  outboxId: string,
): Promise<(OrderOutboxRow & { aggregate_id: string; aggregate_type: string }) | null> {
  const r = await tx.execute<OrderOutboxRow & { aggregate_id: string; aggregate_type: string }>(sql`
    SELECT id, aggregate_type::text AS aggregate_type, aggregate_id, operation, status::text AS status, attempts,
           onec_ref::text AS onec_ref, last_error_code, last_error, onec_response, sent_at
      FROM onec_outbox WHERE id = ${outboxId}::uuid`);
  return r.rows[0] ?? null;
}

/** Активные пользователи с ролью (уведомления администраторам). */
export async function userIdsWithRole(tx: SalesTx, role: string): Promise<string[]> {
  const r = await tx.execute<{ user_id: string }>(sql`
    SELECT ur.user_id FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id JOIN users u ON u.id = ur.user_id
     WHERE ro.code = ${role}::role_code AND ur.revoked_at IS NULL AND u.status = 'active'`);
  return r.rows.map((x) => x.user_id);
}

/** Подтверждённая привязка клиента-покупателя к карточке 1С (`customer_links.status='confirmed'`, 11 SEC-030 (в)). */
export async function confirmedCustomerId(tx: SalesTx, userId: string): Promise<string | null> {
  const r = await tx.execute<{ customer_id: string }>(sql`
    SELECT customer_id FROM customer_links WHERE user_id = ${userId}::uuid AND status = 'confirmed' LIMIT 1`);
  return r.rows[0]?.customer_id ?? null;
}

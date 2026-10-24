import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { Money, Quantity } from '../common/money/money.js';
import type { ReturnItemRow, ReturnRow } from './returns.repository.js';
import { pgUuidArray } from './returns.repository.js';

export interface UserRefDto {
  readonly id: string;
  readonly displayName: string;
  readonly role?: string;
}

/** `UserRef` (08 §3.5): без телефона. */
export async function loadUserRefs(tx: DbExecutor, ids: readonly (string | null)[]): Promise<Map<string, UserRefDto>> {
  const uniq = [...new Set(ids.filter((x): x is string => typeof x === 'string'))];
  const out = new Map<string, UserRefDto>();
  if (uniq.length === 0) return out;
  const r = await tx.execute<{
    id: string;
    display_name: string | null;
    full_name: string | null;
    role: string | null;
  }>(
    sql`SELECT u.id, p.display_name, p.full_name,
               (SELECT ro.code::text FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
                 WHERE ur.user_id = u.id AND ur.revoked_at IS NULL ORDER BY ro.code LIMIT 1) AS role
          FROM users u LEFT JOIN user_profiles p ON p.user_id = u.id
         WHERE u.id = ANY(${pgUuidArray(uniq)}::uuid[])`,
  );
  for (const row of r.rows) {
    out.set(row.id, {
      id: row.id,
      displayName: row.display_name ?? row.full_name ?? 'Пользователь',
      ...(row.role ? { role: row.role } : {}),
    });
  }
  return out;
}

function money(v: string): { amount: string; currency: 'KGS' } {
  return Money.of(v).toJSON();
}

/** Количество строкой `QuantityValue` (≤ 3 знаков, 08 §2.14): `"2.000"`. */
export function qty3(v: string): string {
  const q = Quantity.of(v).toString();
  const [i, f = ''] = q.split('.');
  return `${i}.${f.padEnd(3, '0')}`;
}

/** `max(0, a − b − c)` для количеств (строки NUMERIC(14,3)). */
export function remainingQty(shipped: string, returned: string, otherOpen: string): string {
  const m = (s: string) => Quantity.of(s).toMilli();
  const left = m(shipped) - m(returned) - m(otherOpen);
  const v = left > 0n ? left : 0n;
  const s = v.toString().padStart(4, '0');
  return `${s.slice(0, -3)}.${s.slice(-3)}`;
}

function iso(d: Date | null): string | undefined {
  return d ? new Date(d).toISOString() : undefined;
}

/** `ReturnRequestItem` (08 §3.12): `orderLineNo` — номер строки заказа POS (`order_items.line_no`, GQ-TXR-02). */
export function presentReturnItem(i: ReturnItemRow): Record<string, unknown> {
  return {
    orderLineNo: Number(i.order_line_no), // money-double: allow — номер строки документа, не сумма
    variantId: i.variant_id,
    quantity: {
      value: qty3(i.quantity),
      unitId: i.unit_id,
      packagingId: i.packaging_id,
    },
    maxReturnable: remainingQty(i.shipped_quantity, i.returned_quantity, i.other_open),
    amount: money(i.line_total),
  };
}

/** `ReturnRequest` (08 §3.12; OpenAPI `ReturnRequest`): поля без значения опускаются (`reasonComment`). */
export function presentReturn(
  r: ReturnRow,
  items: readonly ReturnItemRow[],
  users: ReadonlyMap<string, UserRefDto>,
): Record<string, unknown> {
  const createdBy = users.get(r.created_by_user_id);
  return {
    id: r.id,
    publicNumber: r.public_number,
    status: r.status,
    orderId: r.order_id,
    shipmentRef: r.shipment_ref,
    ...(r.shipment_number ? { shipmentNumber: r.shipment_number } : {}),
    customerId: r.customer_id,
    reasonCode: r.reason,
    ...(r.reason_comment ? { reasonComment: r.reason_comment } : {}),
    items: items.filter((i) => i.return_request_id === r.id).map(presentReturnItem),
    totalAmount: money(r.total),
    refundKind: r.refund_method_expected,
    approvalReason: r.approval_reason,
    onec: { ref: r.onec_ref, status: r.onec_status_raw },
    rowVersion: Number(r.row_version), // money-double: allow — версия строки, не сумма
    audit: {
      createdAt: iso(r.created_at),
      ...(createdBy ? { createdBy } : {}),
      updatedAt: iso(r.updated_at),
      rowVersion: Number(r.row_version), // money-double: allow — версия строки, не сумма
    },
  };
}

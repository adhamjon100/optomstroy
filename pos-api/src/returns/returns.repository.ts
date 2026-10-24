import { Injectable } from '@nestjs/common';
import { type SQL, sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import type { OrderStatus, OutboxStatus, PaymentMethod, ReturnReason, ReturnRequestStatus } from '../common/enums.js';

/** Массив-литерал PostgreSQL для `= ANY($1::uuid[])` (значения — UUID, проверенные вызывающим). */
export function pgUuidArray(values: readonly string[]): string {
  return `{${values.map((v) => `"${v.replace(/["\\]/g, '')}"`).join(',')}}`;
}

/** Строка `return_requests` (07 §5.45) + реквизиты исходной реализации; деньги — строки NUMERIC (D-19). */
export interface ReturnRow extends Record<string, unknown> {
  id: string;
  public_number: string;
  status: ReturnRequestStatus;
  order_id: string | null;
  shipment_id: string;
  shipment_ref: string;
  shipment_number: string | null;
  customer_id: string;
  customer_ref: string | null;
  reason: ReturnReason;
  reason_comment: string | null;
  total: string;
  refund_method_expected: PaymentMethod | null;
  created_by_user_id: string;
  approved_by_user_id: string | null;
  approved_at: Date | null;
  accepted_at: Date | null;
  accepted_by_user_id: string | null;
  approval_reason: 'return_threshold_exceeded' | null;
  submitted_at: Date | null;
  completed_at: Date | null;
  rejected_at: Date | null;
  rejected_by_user_id: string | null;
  reject_reason: string | null;
  onec_ref: string | null;
  onec_number: string | null;
  onec_status_raw: string | null;
  onec_result: string | null;
  row_version: number;
  created_at: Date;
  updated_at: Date;
  /** `created_at` с микросекундами (ключ keyset-курсора). */
  created_key: string;
}

/** Строка заявки + строка реализации (номер строки 1С, единица, остаток к возврату). */
export interface ReturnItemRow extends Record<string, unknown> {
  id: string;
  return_request_id: string;
  shipment_item_id: string;
  variant_id: string;
  quantity: string;
  unit_price: string;
  line_total: string;
  product_name_snapshot: string;
  onec_line_no: number;
  /** Номер строки заказа POS (`order_items.line_no`) того же варианта/упаковки; нет — номер строки реализации. */
  order_line_no: number;
  shipped_quantity: string;
  returned_quantity: string;
  /** Σ количества этой строки реализации в других заявках `draft | submitted | accepted`. */
  other_open: string;
  unit_id: string | null;
  packaging_id: string | null;
}

/** Строка исходной реализации, доступная к возврату (RET-003). */
export interface ShipmentLineRow extends Record<string, unknown> {
  id: string;
  onec_line_no: number;
  variant_id: string | null;
  product_name_snapshot: string;
  quantity: string;
  returned_quantity: string;
  line_total: string;
  unit_price: string;
  other_open: string;
  unit_id: string | null;
  packaging_id: string | null;
  product_ref: string | null;
  variant_ref: string | null;
  /** Вариант не по умолчанию без ссылки 1С на характеристику (`variant_ref = null` тогда — не «без характеристики»). */
  variant_ref_missing: boolean;
}

export interface OrderForReturn extends Record<string, unknown> {
  id: string;
  public_number: string;
  status: OrderStatus;
  customer_id: string;
  warehouse_id: string;
}

export interface SourceShipment extends Record<string, unknown> {
  id: string;
  onec_ref: string;
  number: string | null;
  customer_id: string;
}

export interface ReturnsListFilter {
  readonly statuses: readonly ReturnRequestStatus[] | null;
  readonly orderId?: string;
  readonly customerId?: string;
  readonly from?: Date;
  readonly to?: Date;
  readonly after?: { readonly createdAt: string; readonly id: string };
  readonly limit: number;
}

const RETURN_COLUMNS = sql.raw(`r.id, r.public_number, r.status::text AS status, r.order_id, r.shipment_id,
  s.onec_ref::text AS shipment_ref, s.onec_code AS shipment_number, r.customer_id, c.onec_ref::text AS customer_ref,
  r.reason::text AS reason, r.reason_comment, r.total::text AS total,
  r.refund_method_expected::text AS refund_method_expected, r.created_by_user_id, r.approved_by_user_id,
  r.approved_at, r.accepted_at, r.accepted_by_user_id, r.approval_reason, r.submitted_at, r.completed_at,
  r.rejected_at, r.rejected_by_user_id, r.reject_reason, r.onec_ref::text AS onec_ref, r.onec_number,
  r.onec_status_raw, r.onec_result, r.row_version, r.created_at, r.updated_at,
  to_char(r.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_key`);

const RETURN_FROM = sql.raw(`return_requests r JOIN shipments s ON s.id = r.shipment_id
  JOIN customers c ON c.id = r.customer_id`);

/** Σ количества строки реализации в других открытых заявках (как триггер `return_request_items_guard`, 0001). */
function otherOpen(shipmentItemCol: string, excludeRequest: SQL): SQL {
  return sql`(SELECT coalesce(sum(oi.quantity), 0) FROM return_request_items oi
               JOIN return_requests orr ON orr.id = oi.return_request_id
              WHERE oi.shipment_item_id = ${sql.raw(shipmentItemCol)}
                AND orr.status IN ('draft','submitted','accepted')
                AND ${excludeRequest})`;
}

/**
 * SQL модуля `returns` (07 §5.45–§5.46; реплика реализаций 1С `shipments`/`shipment_items` — только чтение).
 * Контроль остатка к возврату дублирует триггер БД `return_request_items_guard` (0001): сервис отвечает 422
 * `RETURN_QTY_EXCEEDED` до INSERT, триггер — последняя защита от гонки (RET-008).
 */
@Injectable()
export class ReturnsRepository {
  async findOrder(tx: DbExecutor, orderId: string, lock = false): Promise<OrderForReturn | null> {
    const r = await tx.execute<OrderForReturn>(sql`
      SELECT id, public_number, status::text AS status, customer_id, warehouse_id FROM orders
       WHERE id = ${orderId}::uuid ${lock ? sql.raw('FOR SHARE') : sql.raw('')}`);
    return r.rows[0] ?? null;
  }

  /**
   * Исходная продажа заказа — последняя проведённая, не помеченная на удаление реализация 1С по заказу
   * (`shipments.order_id`; «нет возврата в никуда», R7 §6, RET-002). Несколько реализаций одного заказа — GQ-TXR-02.
   */
  async sourceShipment(tx: DbExecutor, orderId: string): Promise<SourceShipment | null> {
    const r = await tx.execute<SourceShipment>(sql`
      SELECT id, onec_ref::text AS onec_ref, onec_code AS number, customer_id FROM shipments
       WHERE order_id = ${orderId}::uuid AND posted AND NOT deletion_mark
       ORDER BY onec_date DESC, id DESC LIMIT 1`);
    return r.rows[0] ?? null;
  }

  async shipmentById(tx: DbExecutor, shipmentId: string): Promise<SourceShipment | null> {
    const r = await tx.execute<SourceShipment>(sql`
      SELECT id, onec_ref::text AS onec_ref, onec_code AS number, customer_id FROM shipments
       WHERE id = ${shipmentId}::uuid`);
    return r.rows[0] ?? null;
  }

  /**
   * Строки реализации с остатком к возврату; `excludeRequestId` — заявка, чьи строки не считаются «чужими».
   * `FOR UPDATE OF si` — сериализация заявок на одну реализацию (10 RET-003, RET-008; ревью G-returns-txn-5): вторая
   * параллельная заявка ждёт COMMIT первой, и триггер `return_request_items_guard` видит её строки (`FOR SHARE`
   * совместим сам с собой и гонку не исключал).
   */
  async shipmentLines(tx: DbExecutor, shipmentId: string, excludeRequestId: string | null): Promise<ShipmentLineRow[]> {
    const exclude = excludeRequestId ? sql`orr.id <> ${excludeRequestId}::uuid` : sql`true`;
    const r = await tx.execute<ShipmentLineRow>(sql`
      SELECT si.id, si.onec_line_no, si.variant_id, si.product_name_snapshot, si.quantity::text AS quantity,
             si.returned_quantity::text AS returned_quantity, si.line_total::text AS line_total,
             si.unit_price::text AS unit_price, ${otherOpen('si.id', exclude)}::text AS other_open,
             coalesce(pk.unit_id, p.base_unit_id) AS unit_id, si.packaging_id,
             p.onec_ref::text AS product_ref,
             CASE WHEN v.is_default THEN NULL ELSE v.onec_ref::text END AS variant_ref,
             (v.id IS NOT NULL AND NOT v.is_default AND v.onec_ref IS NULL) AS variant_ref_missing
        FROM shipment_items si
        LEFT JOIN product_variants v ON v.id = si.variant_id
        LEFT JOIN products p ON p.id = v.product_id
        LEFT JOIN packagings pk ON pk.id = si.packaging_id
       WHERE si.shipment_id = ${shipmentId}::uuid
       ORDER BY si.onec_line_no FOR UPDATE OF si`);
    return r.rows;
  }

  async insertRequest(
    tx: DbExecutor,
    r: {
      readonly shipmentId: string;
      readonly orderId: string;
      readonly customerId: string;
      readonly reason: ReturnReason;
      readonly reasonComment: string | null;
      readonly total: string;
      readonly refundKind: PaymentMethod | null;
      readonly createdBy: string;
      readonly approvalReason: 'return_threshold_exceeded' | null;
      readonly idempotencyKey: string | null;
    },
  ): Promise<string> {
    const ins = await tx.execute<{ id: string }>(sql`
      INSERT INTO return_requests (public_number, shipment_id, order_id, customer_id, status, reason, reason_comment,
                                   total, refund_method_expected, created_by_user_id, approval_reason, idempotency_key)
      VALUES (next_return_public_number(), ${r.shipmentId}::uuid, ${r.orderId}::uuid, ${r.customerId}::uuid, 'draft',
              ${r.reason}::return_reason, ${r.reasonComment}, ${r.total}::numeric,
              ${r.refundKind}::payment_method, ${r.createdBy}::uuid, ${r.approvalReason}, ${r.idempotencyKey})
      RETURNING id`);
    return ins.rows[0].id;
  }

  async insertItems(
    tx: DbExecutor,
    requestId: string,
    items: readonly {
      readonly shipmentItemId: string;
      readonly variantId: string;
      readonly quantity: string;
      readonly unitPrice: string;
      readonly lineTotal: string;
      readonly productName: string;
    }[],
  ): Promise<void> {
    for (const it of items) {
      await tx.execute(sql`
        INSERT INTO return_request_items (return_request_id, shipment_item_id, variant_id, quantity, unit_price,
                                          line_total, product_name_snapshot)
        VALUES (${requestId}::uuid, ${it.shipmentItemId}::uuid, ${it.variantId}::uuid, ${it.quantity}::numeric,
                ${it.unitPrice}::numeric, ${it.lineTotal}::numeric, ${it.productName})`);
    }
  }

  async deleteItems(tx: DbExecutor, requestId: string): Promise<void> {
    await tx.execute(sql`DELETE FROM return_request_items WHERE return_request_id = ${requestId}::uuid`);
  }

  async findById(tx: DbExecutor, id: string, lock = false): Promise<ReturnRow | null> {
    const r = await tx.execute<ReturnRow>(sql`
      SELECT ${RETURN_COLUMNS} FROM ${RETURN_FROM} WHERE r.id = ${id}::uuid
      ${lock ? sql.raw('FOR UPDATE OF r') : sql.raw('')}`);
    return r.rows[0] ?? null;
  }

  async findByOnecRef(tx: DbExecutor, onecRef: string): Promise<ReturnRow | null> {
    const r = await tx.execute<ReturnRow>(sql`
      SELECT ${RETURN_COLUMNS} FROM ${RETURN_FROM} WHERE r.onec_ref = ${onecRef}::uuid FOR UPDATE OF r`);
    return r.rows[0] ?? null;
  }

  async items(tx: DbExecutor, requestIds: readonly string[]): Promise<ReturnItemRow[]> {
    if (requestIds.length === 0) return [];
    const r = await tx.execute<ReturnItemRow>(sql`
      SELECT i.id, i.return_request_id, i.shipment_item_id, i.variant_id, i.quantity::text AS quantity,
             i.unit_price::text AS unit_price, i.line_total::text AS line_total, i.product_name_snapshot,
             si.onec_line_no, si.quantity::text AS shipped_quantity, si.returned_quantity::text AS returned_quantity,
             coalesce((SELECT ol.line_no FROM order_items ol
                        WHERE ol.order_id = rq.order_id AND ol.variant_id = i.variant_id
                          AND ol.packaging_id IS NOT DISTINCT FROM si.packaging_id
                        ORDER BY ol.line_no LIMIT 1), si.onec_line_no) AS order_line_no,
             (SELECT coalesce(sum(oi.quantity), 0) FROM return_request_items oi
                JOIN return_requests orr ON orr.id = oi.return_request_id
               WHERE oi.shipment_item_id = si.id AND orr.status IN ('draft','submitted','accepted')
                 AND orr.id <> i.return_request_id)::text AS other_open,
             coalesce(pk.unit_id, p.base_unit_id) AS unit_id, si.packaging_id
        FROM return_request_items i
        JOIN return_requests rq ON rq.id = i.return_request_id
        JOIN shipment_items si ON si.id = i.shipment_item_id
        LEFT JOIN product_variants v ON v.id = i.variant_id
        LEFT JOIN products p ON p.id = v.product_id
        LEFT JOIN packagings pk ON pk.id = si.packaging_id
       WHERE i.return_request_id = ANY(${pgUuidArray(requestIds)}::uuid[])
       ORDER BY i.return_request_id, order_line_no, si.onec_line_no`);
    return r.rows;
  }

  /** Строки заказа POS (номер, вариант, упаковка) — сопоставление с исходной реализацией (GQ-TXR-02). */
  async orderLines(
    tx: DbExecutor,
    orderId: string,
  ): Promise<{ line_no: number; variant_id: string; packaging_id: string | null }[]> {
    const r = await tx.execute<{ line_no: number; variant_id: string; packaging_id: string | null }>(sql`
      SELECT line_no, variant_id, packaging_id FROM order_items WHERE order_id = ${orderId}::uuid ORDER BY line_no`);
    return r.rows;
  }

  /** Список `GET /returns` (08 §4.15.2): keyset `(created_at DESC, id DESC)`. */
  async list(tx: DbExecutor, f: ReturnsListFilter): Promise<ReturnRow[]> {
    const where: SQL[] = [sql`true`];
    if (f.statuses && f.statuses.length > 0) {
      where.push(
        sql`r.status::text IN (${sql.join(
          f.statuses.map((s) => sql`${s}`),
          sql.raw(', '),
        )})`,
      );
    }
    if (f.orderId) where.push(sql`r.order_id = ${f.orderId}::uuid`);
    if (f.customerId) where.push(sql`r.customer_id = ${f.customerId}::uuid`);
    if (f.from) where.push(sql`r.created_at >= ${f.from.toISOString()}::timestamptz`);
    if (f.to) where.push(sql`r.created_at <= ${f.to.toISOString()}::timestamptz`);
    if (f.after) {
      where.push(sql`(r.created_at, r.id) < (${f.after.createdAt}::timestamptz, ${f.after.id}::uuid)`);
    }
    const r = await tx.execute<ReturnRow>(sql`
      SELECT ${RETURN_COLUMNS} FROM ${RETURN_FROM}
       WHERE ${sql.join(where, sql.raw(' AND '))}
       ORDER BY r.created_at DESC, r.id DESC LIMIT ${f.limit + 1}`);
    return r.rows;
  }

  /** Условный UPDATE по `rowVersion` (07 §4 «Оптимистичная блокировка»): `false` — версия устарела. */
  async updateDraft(
    tx: DbExecutor,
    id: string,
    rowVersion: number,
    p: {
      readonly reason: ReturnReason;
      readonly reasonComment: string | null;
      readonly total: string;
      readonly refundKind: PaymentMethod | null;
      readonly approvalReason: 'return_threshold_exceeded' | null;
    },
  ): Promise<boolean> {
    const r = await tx.execute(sql`
      UPDATE return_requests
         SET reason = ${p.reason}::return_reason, reason_comment = ${p.reasonComment}, total = ${p.total}::numeric,
             refund_method_expected = ${p.refundKind}::payment_method, approval_reason = ${p.approvalReason},
             row_version = row_version + 1, updated_at = now()
       WHERE id = ${id}::uuid AND row_version = ${rowVersion} AND status = 'draft'`);
    return (r.rowCount ?? 0) === 1;
  }

  async deleteDraft(tx: DbExecutor, id: string, rowVersion: number): Promise<boolean> {
    const r = await tx.execute(sql`
      DELETE FROM return_requests WHERE id = ${id}::uuid AND row_version = ${rowVersion} AND status = 'draft'`);
    return (r.rowCount ?? 0) === 1;
  }

  /** Переход статуса с проверкой исходного статуса и (если задана) версии строки. */
  async transition(
    tx: DbExecutor,
    id: string,
    from: ReturnRequestStatus,
    to: ReturnRequestStatus,
    rowVersion: number | null,
    set: SQL = sql.raw(''),
  ): Promise<boolean> {
    const stamp =
      to === 'submitted'
        ? sql.raw(', submitted_at = now()')
        : to === 'accepted'
          ? sql.raw(', accepted_at = coalesce(accepted_at, now())')
          : to === 'rejected'
            ? sql.raw(', rejected_at = now()')
            : to === 'completed'
              ? sql.raw(', completed_at = now()')
              : sql.raw('');
    const r = await tx.execute(sql`
      UPDATE return_requests SET status = ${to}::return_request_status, row_version = row_version + 1,
             updated_at = now() ${stamp} ${set}
       WHERE id = ${id}::uuid AND status = ${from}::return_request_status
         ${rowVersion === null ? sql.raw('') : sql`AND row_version = ${rowVersion}`}`);
    return (r.rowCount ?? 0) === 1;
  }

  /** Строка outbox `return_request/create` заявки (под блокировкой) или `null`. */
  async outboxOf(tx: DbExecutor, id: string): Promise<{ id: string; status: OutboxStatus } | null> {
    const r = await tx.execute<{ id: string; status: OutboxStatus }>(sql`
      SELECT id, status::text AS status FROM onec_outbox
       WHERE aggregate_type = 'return_request' AND aggregate_id = ${id}::uuid AND operation = 'create'
       FOR UPDATE`);
    return r.rows[0] ?? null;
  }

  /** Повторное удаление уже удалённого черновика (08 §4.15.4 — DELETE идемпотентен): след в аудите. */
  async wasDeleted(tx: DbExecutor, id: string): Promise<boolean> {
    const r = await tx.execute<{ n: number }>(sql`
      SELECT count(*)::int AS n FROM audit_logs
       WHERE action = 'return.updated' AND entity_type = 'return_request' AND entity_id = ${id}::uuid
         AND after ->> 'deleted' = 'true'`);
    return (r.rows[0]?.n ?? 0) > 0;
  }
}

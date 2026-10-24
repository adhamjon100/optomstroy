import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { OrderDocRow, OrderItemDocRow, ReceivedPaymentRow } from './document-model.js';

/**
 * Чтение данных печатных форм. Object-level доступ (11 SEC-030) — фильтром владельца в SQL, не пост-фильтрацией:
 * `order.read.all` — любой заказ; иначе `created_by_user_id = :subject`, а для `customer` дополнительно заказы
 * карточки с подтверждённой привязкой (`customer_links.status = 'confirmed'`, SEC-030 (в)). Чужой заказ → нет строки
 * → `404 NOT_FOUND` (08 §4.8.3, единообразно с несуществующим).
 */
export interface DocumentViewer {
  /** `null` — система (без ограничения). */
  readonly userId: string | null;
  readonly readAll: boolean;
  readonly isCustomer: boolean;
}

function toDate(v: unknown): Date | null {
  if (v === null || v === undefined) return null;
  if (v instanceof Date) return v;
  if (typeof v !== 'string') return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

function text(v: unknown): string | null {
  if (typeof v === 'string') return v;
  return typeof v === 'number' || typeof v === 'bigint' ? String(v) : null;
}

type Row = Record<string, unknown>;

@Injectable()
export class DocumentsRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async findOrder(orderId: string, viewer: DocumentViewer): Promise<OrderDocRow | null> {
    const all = viewer.userId === null || viewer.readAll;
    const r = await this.db.execute<Row>(sql`
      SELECT o.id, o.public_number, o.status::text AS status, o.onec_number,
             to_json(o.onec_date) #>> '{}' AS onec_date, to_json(o.created_at) #>> '{}' AS created_at,
             to_json(o.updated_at) #>> '{}' AS updated_at, o.row_version, o.payment_method::text AS payment_method,
             o.credit_due_date::text AS credit_due_date, o.subtotal::text AS subtotal,
             o.discount_total::text AS discount_total, o.customer_discount_total::text AS customer_discount_total,
             o.manual_discount_total::text AS manual_discount_total, o.discount_percent::text AS discount_percent,
             o.customer_discount_percent::text AS customer_discount_percent, o.total::text AS total,
             COALESCE(NULLIF(o.customer_name_snapshot, ''), c.name, '') AS customer_name, c.inn AS customer_inn,
             o.created_by_user_id
        FROM orders o
        LEFT JOIN customers c ON c.id = o.customer_id
       WHERE o.id = ${orderId}::uuid
         AND (${all}::boolean
              OR o.created_by_user_id = ${viewer.userId}::uuid
              OR (${viewer.isCustomer}::boolean AND EXISTS (
                    SELECT 1 FROM customer_links cl
                     WHERE cl.user_id = ${viewer.userId}::uuid AND cl.customer_id = o.customer_id
                       AND cl.status = 'confirmed')))`);
    const o = r.rows[0];
    if (!o) return null;
    return {
      id: String(o.id),
      publicNumber: String(o.public_number),
      status: String(o.status),
      onecNumber: text(o.onec_number),
      onecDate: toDate(o.onec_date),
      createdAt: toDate(o.created_at) ?? new Date(0),
      updatedAt: toDate(o.updated_at) ?? new Date(0),
      rowVersion: Number(o.row_version), // money-double: allow — версия строки (счётчик), не деньги
      paymentMethod: String(o.payment_method),
      creditDueDate: text(o.credit_due_date),
      subtotal: String(o.subtotal),
      discountTotal: String(o.discount_total),
      customerDiscountTotal: String(o.customer_discount_total),
      manualDiscountTotal: String(o.manual_discount_total),
      discountPercent: String(o.discount_percent),
      customerDiscountPercent: text(o.customer_discount_percent),
      total: String(o.total),
      customerName: String(o.customer_name),
      customerInn: text(o.customer_inn),
      createdById: String(o.created_by_user_id),
    };
  }

  async items(orderId: string): Promise<OrderItemDocRow[]> {
    const r = await this.db.execute<Row>(sql`
      SELECT i.line_no, i.product_name_snapshot, i.variant_name_snapshot, i.packaging_name_snapshot, i.sku_snapshot,
             i.quantity::text AS quantity, i.unit_code_snapshot, i.unit_price::text AS unit_price,
             i.line_subtotal::text AS line_subtotal, i.discount_amount::text AS discount_amount,
             i.line_total::text AS line_total
        FROM order_items i
       WHERE i.order_id = ${orderId}::uuid
       ORDER BY i.line_no`);
    return r.rows.map((i) => ({
      lineNo: Number(i.line_no), // money-double: allow — номер строки, не деньги
      productName: String(i.product_name_snapshot),
      variantName: text(i.variant_name_snapshot),
      packagingName: text(i.packaging_name_snapshot),
      sku: text(i.sku_snapshot),
      quantity: String(i.quantity),
      unit: String(i.unit_code_snapshot),
      unitPrice: String(i.unit_price),
      lineSubtotal: String(i.line_subtotal),
      discountAmount: String(i.discount_amount),
      lineTotal: String(i.line_total),
    }));
  }

  /** Полученные платежи заказа (`payments.status = 'received'`, PRINT-005) в порядке получения. */
  async receivedPayments(orderId: string): Promise<ReceivedPaymentRow[]> {
    const r = await this.db.execute<Row>(sql`
      SELECT p.id, p.method::text AS method, p.amount::text AS amount, p.received_amount::text AS received_amount,
             p.change_amount::text AS change_amount, to_json(p.received_at) #>> '{}' AS received_at,
             COALESCE(NULLIF(up.display_name, ''), up.full_name) AS received_by_name
        FROM payments p
        LEFT JOIN user_profiles up ON up.user_id = p.received_by_user_id
       WHERE p.order_id = ${orderId}::uuid AND p.status = 'received'
       ORDER BY p.received_at NULLS LAST, p.id`);
    return r.rows.map((p) => ({
      id: String(p.id),
      method: String(p.method),
      amount: String(p.amount),
      receivedAmount: text(p.received_amount),
      changeAmount: text(p.change_amount),
      receivedAt: toDate(p.received_at),
      receivedByName: text(p.received_by_name),
    }));
  }

  async hasReceivedPayment(orderId: string): Promise<boolean> {
    const r = await this.db.execute<Row>(sql`
      SELECT 1 FROM payments WHERE order_id = ${orderId}::uuid AND status = 'received' LIMIT 1`);
    return r.rows.length > 0;
  }

  /** Состояние заказа для `availability` (без проверки владельца — её выполняет вызывающий модуль orders). */
  async orderState(orderId: string): Promise<{ status: string; onecNumber: string | null } | null> {
    const r = await this.db.execute<Row>(sql`
      SELECT status::text AS status, onec_number FROM orders WHERE id = ${orderId}::uuid`);
    const o = r.rows[0];
    return o ? { status: String(o.status), onecNumber: text(o.onec_number) } : null;
  }

  /**
   * Факт рендера — `print_jobs` (08 §4.8.5 «Аудит не пишется; факт рендера — print_jobs»; 07 §5.60): одна строка на
   * (заказ, вид, бумага, версия заказа); повторный рендер той же версии обновляет хэш и автора.
   */
  async recordPrintJob(input: {
    readonly orderId: string;
    readonly kind: 'invoice' | 'receipt';
    readonly paper: 'a4' | 'thermal80';
    readonly version: number; // money-double: allow — версия заказа (row_version), не деньги
    readonly userId: string;
    readonly sha256Hex: string | null;
    readonly error: string | null;
  }): Promise<void> {
    const status = input.error === null ? 'ready' : 'failed';
    await this.db.execute(sql`
      INSERT INTO print_jobs (order_id, document_kind, paper, status, sha256, version, requested_by_user_id, error)
      VALUES (${input.orderId}::uuid, ${input.kind}::print_document_kind, ${input.paper},
              ${status}::print_job_status, decode(${input.sha256Hex}, 'hex'), ${input.version}::smallint,
              ${input.userId}::uuid, ${input.error})
      ON CONFLICT ON CONSTRAINT print_jobs_document_version_uq DO UPDATE
         SET status = EXCLUDED.status, sha256 = EXCLUDED.sha256, error = EXCLUDED.error,
             requested_by_user_id = EXCLUDED.requested_by_user_id, updated_at = now()`);
  }
}

import { Inject, Injectable } from '@nestjs/common';
import { sql, type SQL } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { ReceivableDocumentKind, ReceivableDocumentStatus } from '../../common/enums.js';
import type { SalesTx } from '../../common/ports/index.js';

export interface ReceivablesRow {
  readonly balance: string;
  readonly overdueAmount: string | null;
  readonly overdueDays: number | null;
  readonly oldestDueDate: string | null;
  readonly snapshotAt: Date;
  readonly syncedAt: Date;
}

export interface ReceivableDocumentRow {
  readonly onecRef: string;
  readonly docType: string;
  readonly kind: ReceivableDocumentKind;
  readonly status: ReceivableDocumentStatus;
  readonly number: string;
  readonly date: string;
  readonly amount: string;
  readonly paid: string;
  readonly remaining: string;
  readonly dueDate: string | null;
  readonly overdueDays: number | null;
  readonly orderId: string | null;
}

/** Карточка клиента для экранов долга (условия соглашения, идентификация в 1С). */
export interface ReceivablesCustomerRow {
  readonly id: string;
  readonly name: string;
  readonly customerType: string;
  readonly onecRef: string | null;
  readonly onecCode: string | null;
  readonly source: string;
  readonly onecStatus: string;
  readonly isRetailDefault: boolean;
  readonly creditAllowed: boolean;
  readonly creditLimit: string | null;
  readonly creditDays: number | null;
  readonly deletionMark: boolean;
}

export interface OverdueRow {
  readonly customer: ReceivablesCustomerRow;
  readonly balance: string;
  readonly overdueAmount: string;
  readonly overdueDays: number;
  readonly oldestDueDate: string | null;
  readonly snapshotAt: Date;
}

export type OverdueSort = 'overdueAmount:desc' | 'overdueDays:desc' | 'customerName:asc';

export interface OverdueQuery {
  readonly minOverdueDays: number | null;
  readonly minAmount: string | null;
  readonly sort: OverdueSort;
  readonly offset: number;
  readonly limit: number;
}

/**
 * Статусы заказов в долг, ещё не отражённых в снимке 1С (DEBT-011: `pending_approval`/`approved`/
 * `awaiting_shipment`; дополнительно `submitting` — заказ уже оформлен в долг, но ещё не доставлен в 1С: fail-closed,
 * GQ-CRD-03).
 */
export const OPEN_CREDIT_ORDER_STATUSES = ['submitting', 'pending_approval', 'approved', 'awaiting_shipment'] as const;

const CUSTOMER_COLUMNS = sql`c.id, c.name, c.customer_type::text AS customer_type, c.onec_ref, c.onec_code,
  c.source::text AS source, c.onec_status::text AS onec_status, c.is_retail_default, c.credit_allowed,
  c.credit_limit::text AS credit_limit, c.credit_days, c.deletion_mark`;

interface CustomerSqlRow extends Record<string, unknown> {
  id: string;
  name: string;
  customer_type: string;
  onec_ref: string | null;
  onec_code: string | null;
  source: string;
  onec_status: string;
  is_retail_default: boolean;
  credit_allowed: boolean;
  credit_limit: string | null;
  credit_days: number | null;
  deletion_mark: boolean;
}

function customerOf(r: CustomerSqlRow): ReceivablesCustomerRow {
  return {
    id: r.id,
    name: r.name,
    customerType: r.customer_type,
    onecRef: r.onec_ref,
    onecCode: r.onec_code,
    source: r.source,
    onecStatus: r.onec_status,
    isRetailDefault: r.is_retail_default,
    creditAllowed: r.credit_allowed,
    creditLimit: r.credit_limit,
    creditDays: r.credit_days,
    deletionMark: r.deletion_mark,
  };
}

const ORDER_BY: Readonly<Record<OverdueSort, SQL>> = {
  'overdueAmount:desc': sql`r.overdue_amount DESC, c.name ASC, c.id ASC`,
  'overdueDays:desc': sql`r.overdue_days DESC NULLS LAST, r.overdue_amount DESC, c.id ASC`,
  'customerName:asc': sql`c.name ASC, c.id ASC`,
};

/** Чтение снимков долга (07 §5.31–§5.32) — read-only SQL через Drizzle (в транзакции вызывающего, если передана). */
@Injectable()
export class ReceivablesRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  private ex(tx: SalesTx | null | undefined): DbExecutor {
    return tx ?? this.db;
  }

  async snapshot(tx: SalesTx | null, customerId: string): Promise<ReceivablesRow | null> {
    const r = await this.ex(tx).execute<{
      balance: string;
      overdue_amount: string | null;
      overdue_days: number | null;
      oldest_due_date: string | null;
      onec_snapshot_at: Date | string;
      synced_at: Date | string;
    }>(sql`
      SELECT balance::text AS balance, overdue_amount::text AS overdue_amount, overdue_days,
             to_char(oldest_due_date, 'YYYY-MM-DD') AS oldest_due_date, onec_snapshot_at, synced_at
        FROM receivables WHERE customer_id = ${customerId}::uuid`);
    const row = r.rows[0];
    if (!row) return null;
    return {
      balance: row.balance,
      overdueAmount: row.overdue_amount,
      overdueDays: row.overdue_days,
      oldestDueDate: row.oldest_due_date,
      snapshotAt: new Date(row.onec_snapshot_at),
      syncedAt: new Date(row.synced_at),
    };
  }

  async documents(tx: SalesTx | null, customerId: string): Promise<ReceivableDocumentRow[]> {
    const r = await this.ex(tx).execute<{
      onec_ref: string;
      doc_type: string;
      kind: ReceivableDocumentKind;
      status: ReceivableDocumentStatus;
      doc_number: string;
      doc_date: string;
      amount: string;
      paid: string;
      remaining: string;
      due_date: string | null;
      overdue_days: number | null;
      order_id: string | null;
    }>(sql`
      SELECT onec_ref, doc_type, kind, status, doc_number, to_char(doc_date, 'YYYY-MM-DD') AS doc_date,
             amount::text AS amount, paid::text AS paid, remaining::text AS remaining,
             to_char(due_date, 'YYYY-MM-DD') AS due_date, overdue_days, order_id
        FROM receivable_documents
       WHERE customer_id = ${customerId}::uuid AND superseded_at IS NULL
       ORDER BY due_date ASC NULLS LAST, doc_date ASC, doc_number ASC, onec_ref ASC`);
    return r.rows.map((d) => ({
      onecRef: d.onec_ref,
      docType: d.doc_type,
      kind: d.kind,
      status: d.status,
      number: d.doc_number,
      date: d.doc_date,
      amount: d.amount,
      paid: d.paid,
      remaining: d.remaining,
      dueDate: d.due_date,
      overdueDays: d.overdue_days,
      orderId: d.order_id,
    }));
  }

  /**
   * Прогноз открытых заказов в долг (DEBT-011): Σ `total` заказов `credit` клиента в статусах
   * `OPEN_CREDIT_ORDER_STATUSES` без полной оплаты, которых ещё нет в текущей детализации снимка 1С.
   */
  async openOrdersAmount(tx: SalesTx | null, customerId: string): Promise<string> {
    const r = await this.ex(tx).execute<{ s: string }>(sql`
      SELECT coalesce(sum(o.total), 0)::numeric(14,2)::text AS s
        FROM orders o
       WHERE o.customer_id = ${customerId}::uuid
         AND o.payment_method = 'credit'
         AND o.status::text IN (${sql.join(
           OPEN_CREDIT_ORDER_STATUSES.map((s) => sql`${s}`),
           sql`, `,
         )})
         AND o.paid_amount < o.total
         AND NOT EXISTS (SELECT 1 FROM receivable_documents d
                          WHERE d.customer_id = o.customer_id AND d.order_id = o.id AND d.superseded_at IS NULL)`);
    return r.rows[0]?.s ?? '0.00';
  }

  async customer(tx: SalesTx | null, customerId: string): Promise<ReceivablesCustomerRow | null> {
    const r = await this.ex(tx).execute<CustomerSqlRow>(
      sql`SELECT ${CUSTOMER_COLUMNS} FROM customers c WHERE c.id = ${customerId}::uuid AND c.deleted_at IS NULL`,
    );
    const row = r.rows[0];
    return row ? customerOf(row) : null;
  }

  /** Подтверждённая привязка пользователя-клиента к карточке (`customer_links.status = confirmed`, CUST-023). */
  async isConfirmedLink(userId: string, customerId: string): Promise<boolean> {
    const r = await this.db.execute<{ ok: number }>(sql`
      SELECT 1 AS ok FROM customer_links
       WHERE user_id = ${userId}::uuid AND customer_id = ${customerId}::uuid AND status = 'confirmed' LIMIT 1`);
    return r.rows.length > 0;
  }

  async overdue(q: OverdueQuery): Promise<OverdueRow[]> {
    const conds: SQL[] = [sql`r.overdue_amount > 0`, sql`c.deleted_at IS NULL`];
    if (q.minOverdueDays !== null) conds.push(sql`coalesce(r.overdue_days, 0) >= ${q.minOverdueDays}`);
    if (q.minAmount !== null) conds.push(sql`r.overdue_amount >= ${q.minAmount}::numeric`);
    const r = await this.db.execute<
      CustomerSqlRow & {
        balance: string;
        overdue_amount: string;
        overdue_days: number | null;
        oldest_due_date: string | null;
        onec_snapshot_at: Date | string;
      }
    >(sql`
      SELECT ${CUSTOMER_COLUMNS}, r.balance::text AS balance, r.overdue_amount::text AS overdue_amount,
             r.overdue_days, to_char(r.oldest_due_date, 'YYYY-MM-DD') AS oldest_due_date, r.onec_snapshot_at
        FROM receivables r JOIN customers c ON c.id = r.customer_id
       WHERE ${sql.join(conds, sql` AND `)}
       ORDER BY ${ORDER_BY[q.sort]}
       LIMIT ${q.limit + 1} OFFSET ${q.offset}`);
    return r.rows.map((row) => ({
      customer: customerOf(row),
      balance: row.balance,
      overdueAmount: row.overdue_amount,
      overdueDays: row.overdue_days ?? 0,
      oldestDueDate: row.oldest_due_date,
      snapshotAt: new Date(row.onec_snapshot_at),
    }));
  }
}

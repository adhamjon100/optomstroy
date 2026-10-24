import { type SQL, sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import type { PaymentMethod, TransactionKind, TransactionSource } from '../common/enums.js';
import { Money } from '../common/money/money.js';
import { customerDisplayName } from '../common/presenters/customer-name.js';

/**
 * Чтение журнала `transactions` (07 §5.44; read-model — модуль `transactions` в таблицу не пишет, 06 §7.4): общий SQL
 * списка/деталей `GET /transactions*` (08 §4.14) и блока «Недавние операции» дашборда кассира (08 §4.10.1, TXN-009).
 * Чистые функции без Nest — их импортирует и дашборд модуля `payments` (без импорта Nest-модуля).
 */

/** Группа статуса для фильтра `?status=` и поля `statusGroup` (08 §3.11; ядро §19.2 — значения определяет 08). */
export const TRANSACTION_STATUS_GROUPS = ['received', 'pending', 'voided', 'returned', 'onec_error'] as const;
export type TransactionStatusGroup = (typeof TRANSACTION_STATUS_GROUPS)[number];

/** Виды, суммы которых — деньги платежа (08 §4.10.1: «платёжные поля… только при `payment.read.all`»). */
export const PAYMENT_KINDS: readonly TransactionKind[] = ['payment_received', 'payment_voided', 'manual_qr_confirm'];

export interface TransactionRowDb extends Record<string, unknown> {
  id: string;
  kind: TransactionKind;
  source: TransactionSource;
  order_id: string | null;
  payment_id: string | null;
  return_request_id: string | null;
  shipment_id: string | null;
  customer_id: string | null;
  customer_name: string | null;
  actor_user_id: string | null;
  amount: string;
  payment_method: PaymentMethod | null;
  status_snapshot: string;
  current_status: string;
  status_group: TransactionStatusGroup;
  title_ru: string;
  occurred_at: Date;
  occurred_key: string;
  number: string;
  onec_ref: string | null;
  onec_number: string | null;
  onec_doc_type: string | null;
  order_number: string | null;
  order_onec_ref: string | null;
  order_onec_number: string | null;
  payment_number: string | null;
  return_number: string | null;
  shipment_ref: string | null;
  shipment_number: string | null;
  order_author: string | null;
}

export interface TransactionsFilter {
  readonly from: Date;
  readonly to: Date;
  readonly customerId?: string;
  readonly statusGroups?: readonly TransactionStatusGroup[];
  readonly kinds?: readonly TransactionKind[];
  readonly source?: TransactionSource;
  /** Только операции субъекта: `actor_user_id = me` или заказ создан им (TXN-004, SEC-030). */
  readonly ownerUserId?: string;
  readonly actorId?: string;
  readonly paymentMethod?: PaymentMethod;
  /** По модулю суммы (`|amount|`), строки NUMERIC. */
  readonly amountMin?: string;
  readonly amountMax?: string;
  readonly q?: string;
  readonly ids?: readonly string[];
  readonly excludeKinds?: readonly TransactionKind[];
}

export type TransactionsSort = 'occurredAt:desc' | 'amount:desc';

export interface TransactionsKeyset {
  readonly value: string;
  readonly id: string;
}

/** Выборка с вычисленными колонками: номер, текущий статус документа, группа статуса, автор заказа. */
const INNER = sql.raw(`
  SELECT t.id, t.kind::text AS kind, t.source::text AS source, t.order_id, t.payment_id, t.return_request_id,
         t.shipment_id, t.customer_id, c.name AS customer_name, t.actor_user_id, t.amount::text AS amount,
         t.amount AS amount_num, t.payment_method::text AS payment_method, t.status_snapshot, t.title_ru,
         t.occurred_at, to_char(t.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS occurred_key,
         t.onec_ref::text AS onec_ref, t.onec_number, t.onec_doc_type,
         o.public_number AS order_number, o.onec_ref::text AS order_onec_ref, o.onec_number AS order_onec_number,
         o.created_by_user_id AS order_author,
         p.public_number AS payment_number, rr.public_number AS return_number,
         sh.onec_ref::text AS shipment_ref, sh.onec_code AS shipment_number,
         COALESCE(p.status::text, CASE WHEN t.kind = 'return_requested' THEN rr.status::text END, o.status::text,
                  t.status_snapshot) AS current_status,
         COALESCE(NULLIF(concat_ws(' / ',
                    CASE WHEN t.payment_id IS NOT NULL THEN p.public_number
                         WHEN t.kind = 'return_requested' THEN rr.public_number
                         WHEN t.source = 'pos' THEN o.public_number END,
                    CASE WHEN t.source = 'onec' THEN t.onec_number
                         WHEN t.payment_id IS NOT NULL THEN p.onec_number
                         WHEN t.kind = 'return_requested' THEN rr.onec_number
                         ELSE o.onec_number END), ''),
                  t.onec_number, sh.onec_code, '—') AS number,
         CASE
           WHEN t.kind = 'refund' THEN 'returned'
           WHEN t.kind = 'return_requested' THEN CASE WHEN rr.status = 'rejected' THEN 'voided' ELSE 'returned' END
           WHEN t.kind IN ('payment_voided', 'order_cancelled') THEN 'voided'
           WHEN t.payment_id IS NOT NULL THEN
             CASE p.status WHEN 'received' THEN 'received' WHEN 'credit' THEN 'received'
                           WHEN 'voided' THEN 'voided' WHEN 'refunded' THEN 'returned' ELSE 'pending' END
           WHEN t.order_id IS NOT NULL THEN
             CASE
               WHEN o.status = 'cancelled' THEN 'voided'
               WHEN o.status = 'submit_failed' OR EXISTS (
                      SELECT 1 FROM onec_outbox ob WHERE ob.aggregate_type = 'order' AND ob.aggregate_id = o.id
                         AND ob.status IN ('failed', 'dead')) THEN 'onec_error'
               WHEN o.status = 'partially_returned' THEN 'returned'
               WHEN o.status IN ('submitting', 'pending_approval', 'awaiting_payment') THEN 'pending'
               WHEN o.is_paid OR o.payment_method = 'credit' THEN 'received'
               ELSE 'pending'
             END
           ELSE 'received'
         END AS status_group
    FROM transactions t
    LEFT JOIN customers c ON c.id = t.customer_id
    LEFT JOIN orders o ON o.id = t.order_id
    LEFT JOIN payments p ON p.id = t.payment_id
    LEFT JOIN return_requests rr ON rr.id = t.return_request_id
    LEFT JOIN shipments sh ON sh.id = t.shipment_id`);

function list(values: readonly string[]): SQL {
  return sql.join(
    values.map((v) => sql`${v}`),
    sql.raw(', '),
  );
}

function where(f: TransactionsFilter): SQL {
  const w: SQL[] = [
    sql`x.occurred_at >= ${f.from.toISOString()}::timestamptz`,
    sql`x.occurred_at <= ${f.to.toISOString()}::timestamptz`,
  ];
  if (f.customerId) w.push(sql`x.customer_id = ${f.customerId}::uuid`);
  if (f.statusGroups && f.statusGroups.length > 0) w.push(sql`x.status_group IN (${list(f.statusGroups)})`);
  if (f.kinds && f.kinds.length > 0) w.push(sql`x.kind IN (${list(f.kinds)})`);
  if (f.excludeKinds && f.excludeKinds.length > 0) w.push(sql`x.kind NOT IN (${list(f.excludeKinds)})`);
  if (f.source) w.push(sql`x.source = ${f.source}`);
  if (f.ownerUserId) {
    w.push(sql`(x.actor_user_id = ${f.ownerUserId}::uuid OR x.order_author = ${f.ownerUserId}::uuid)`);
  }
  if (f.actorId) w.push(sql`x.actor_user_id = ${f.actorId}::uuid`);
  if (f.paymentMethod) w.push(sql`x.payment_method = ${f.paymentMethod}`);
  if (f.amountMin) w.push(sql`abs(x.amount_num) >= ${f.amountMin}::numeric`);
  if (f.amountMax) w.push(sql`abs(x.amount_num) <= ${f.amountMax}::numeric`);
  if (f.q) {
    const like = `%${f.q.replace(/[\\%_]/g, (m) => `\\${m}`)}%`;
    w.push(sql`(x.number ILIKE ${like} OR x.order_number ILIKE ${like} OR x.payment_number ILIKE ${like}
                OR x.return_number ILIKE ${like} OR x.shipment_number ILIKE ${like})`);
  }
  if (f.ids) w.push(sql`x.id = ANY(${`{${f.ids.join(',')}}`}::uuid[])`);
  return sql.join(w, sql.raw(' AND '));
}

/** Страница журнала по фильтру; `limit + 1` строк (признак `hasMore`). */
export async function selectTransactions(
  tx: DbExecutor,
  f: TransactionsFilter,
  sort: TransactionsSort,
  limit: number,
  after?: TransactionsKeyset,
): Promise<TransactionRowDb[]> {
  const keyset = after
    ? sort === 'amount:desc'
      ? sql` AND (x.amount_num, x.id) < (${after.value}::numeric, ${after.id}::uuid)`
      : sql` AND (x.occurred_at, x.id) < (${after.value}::timestamptz, ${after.id}::uuid)`
    : sql.raw('');
  const order =
    sort === 'amount:desc' ? sql.raw('x.amount_num DESC, x.id DESC') : sql.raw('x.occurred_at DESC, x.id DESC');
  const r = await tx.execute<TransactionRowDb>(sql`
    SELECT x.* FROM (${INNER}) x
     WHERE ${where(f)} ${keyset}
     ORDER BY ${order} LIMIT ${limit + 1}`);
  return r.rows;
}

/** Одна строка журнала (без фильтра периода). */
export async function selectTransactionById(tx: DbExecutor, id: string): Promise<TransactionRowDb | null> {
  const r = await tx.execute<TransactionRowDb>(sql`SELECT x.* FROM (${INNER}) x WHERE x.id = ${id}::uuid`);
  return r.rows[0] ?? null;
}

/** `summary` по фильтру (08 §4.14.1): число строк, приход (Σ `+`), расход (Σ |`−`|). */
export async function summarizeTransactions(
  tx: DbExecutor,
  f: TransactionsFilter,
): Promise<{ count: number; sumIn: string; sumOut: string }> {
  const r = await tx.execute<{ count: number; sum_in: string; sum_out: string }>(sql`
    SELECT count(*)::int AS count,
           coalesce(sum(x.amount_num) FILTER (WHERE x.amount_num > 0), 0)::numeric(16,2)::text AS sum_in,
           coalesce(-sum(x.amount_num) FILTER (WHERE x.amount_num < 0), 0)::numeric(16,2)::text AS sum_out
      FROM (${INNER}) x WHERE ${where(f)}`);
  const row = r.rows[0];
  return { count: Number(row?.count ?? 0), sumIn: row?.sum_in ?? '0.00', sumOut: row?.sum_out ?? '0.00' }; // money-double: allow — число строк
}

export interface UserRefDto {
  readonly id: string;
  readonly displayName: string;
  readonly role?: string;
}

/** `UserRef` (08 §3.5): без телефона. */
export async function loadTxUserRefs(
  tx: DbExecutor,
  ids: readonly (string | null)[],
): Promise<Map<string, UserRefDto>> {
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
         WHERE u.id = ANY(${`{${uniq.join(',')}}`}::uuid[])`,
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

function related(t: TransactionRowDb): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  if (t.order_id) {
    out.push({ type: 'order', id: t.order_id, number: t.order_number ?? '', url: `/api/v1/orders/${t.order_id}` });
  }
  if (t.payment_id) {
    out.push({
      type: 'payment',
      id: t.payment_id,
      number: t.payment_number ?? '',
      url: `/api/v1/payments/${t.payment_id}`,
    });
  }
  if (t.return_request_id) {
    out.push({
      type: 'return_request',
      id: t.return_request_id,
      number: t.return_number ?? '',
      url: `/api/v1/returns/${t.return_request_id}`,
    });
  }
  if (t.source === 'onec' && (t.onec_ref || t.onec_number)) {
    out.push({ type: 'onec_document', id: t.onec_ref, number: t.onec_number ?? '' });
  }
  if (t.shipment_id && (t.shipment_ref || t.shipment_number)) {
    out.push({ type: 'onec_document', id: t.shipment_ref, number: t.shipment_number ?? '' });
  }
  if (t.source === 'pos' && t.order_onec_number) {
    out.push({ type: 'onec_document', id: t.order_onec_ref, number: t.order_onec_number });
  }
  return out;
}

/**
 * `Transaction` (08 §3.11): `amount` — модуль суммы (Money), знак — в `sign` (`+` приход, `−` возврат/аннулирование;
 * GQ-TXR-07); `status` — текущий статус связанного документа, `statusGroup` — группа для фильтра; `actor` — только
 * у операций POS (строки 1С без автора, TXN-007).
 */
export function presentTransaction(
  t: TransactionRowDb,
  users: ReadonlyMap<string, UserRefDto>,
): Record<string, unknown> {
  const amount = Money.of(t.amount);
  const actor = t.actor_user_id
    ? (users.get(t.actor_user_id) ?? { id: t.actor_user_id, displayName: 'Сотрудник' })
    : null;
  return {
    id: t.id,
    kind: t.kind,
    number: t.number,
    occurredAt: new Date(t.occurred_at).toISOString(),
    amount: (amount.isNegative() ? Money.ZERO.minus(amount) : amount).toJSON(),
    sign: amount.isNegative() ? '-' : '+',
    status: t.current_status,
    statusGroup: t.status_group,
    customer: t.customer_id
      ? { id: t.customer_id, displayName: t.customer_name ? customerDisplayName(t.customer_name) : 'Клиент' }
      : null,
    ...(actor ? { actor } : {}),
    source: t.source,
    related: related(t),
  };
}

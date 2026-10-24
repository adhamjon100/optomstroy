import { Injectable } from '@nestjs/common';
import { type SQL, sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { PaymentMethod, PaymentStatus, ReviewReason } from '../../common/enums.js';
import { PAYMENT_OPEN_STATUSES } from '../../sales-domain/payment/payment-status.js';
import { rows } from './sql-executor.js';

/** Строка `payments` (07 §5.40 + `qr_issued_at` 0011) — деньги строками NUMERIC (D-19). */
export interface PaymentRow {
  readonly id: string;
  readonly publicNumber: string;
  readonly orderId: string | null;
  readonly customerId: string | null;
  readonly method: PaymentMethod;
  readonly qrProvider: 'onec' | 'none' | 'bakai' | null;
  readonly status: PaymentStatus;
  readonly amount: string;
  readonly createdByUserId: string;
  readonly receivedByUserId: string | null;
  readonly receivedAt: Date | null;
  readonly receivedAmount: string | null;
  readonly changeAmount: string | null;
  readonly bankAmount: string | null;
  readonly qrPayload: string | null;
  readonly qrExpiresAt: Date | null;
  readonly qrIssuedAt: Date | null;
  readonly qrProviderRef: string | null;
  /** Референсы QR, заменённые перевыпуском (0012, 10 PAY-025): оплата по ним — `late_payment`. */
  readonly qrRefHistory: readonly string[];
  readonly bankReference: string | null;
  readonly qrStatusCheckedAt: Date | null;
  readonly qrProviderStatusRaw: string | null;
  readonly manualConfirmedByUserId: string | null;
  readonly manualConfirmedAt: Date | null;
  readonly manualReason: string | null;
  readonly reviewReason: ReviewReason | null;
  readonly voidedByUserId: string | null;
  readonly voidedAt: Date | null;
  readonly voidReason: string | null;
  readonly onecRef: string | null;
  readonly onecDocType: string | null;
  readonly idempotencyKey: string;
  readonly rowVersion: number; // money-double: allow — версия строки, не сумма
  readonly createdAt: Date;
}

const COLUMNS = sql.raw(`p.id, p.public_number, p.order_id, p.customer_id, p.method::text AS method, p.qr_provider,
  p.status::text AS status, p.amount::text AS amount, p.created_by_user_id, p.received_by_user_id, p.received_at,
  p.received_amount::text AS received_amount, p.change_amount::text AS change_amount,
  p.bank_amount::text AS bank_amount, p.qr_payload, p.qr_expires_at, p.qr_issued_at, p.qr_provider_ref,
  p.bank_reference, p.qr_status_checked_at, p.qr_provider_status_raw, p.manual_confirmed_by_user_id,
  p.manual_confirmed_at, p.manual_reason, p.review_reason, p.voided_by_user_id, p.voided_at, p.void_reason,
  p.onec_ref, p.onec_doc_type, p.idempotency_key, p.row_version, p.created_at, p.qr_ref_history`);

type Raw = Record<string, unknown>;

function d(v: unknown): Date | null {
  if (v === null || v === undefined) return null;
  if (v instanceof Date) return v;
  return typeof v === 'string' || typeof v === 'number' ? new Date(v) : null;
}

function s(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  return typeof v === 'string' ? v : typeof v === 'number' || typeof v === 'bigint' ? v.toString() : null;
}

export function toPaymentRow(r: Raw): PaymentRow {
  return {
    id: String(r.id),
    publicNumber: String(r.public_number),
    orderId: s(r.order_id),
    customerId: s(r.customer_id),
    method: r.method as PaymentMethod,
    qrProvider: s(r.qr_provider) as PaymentRow['qrProvider'],
    status: r.status as PaymentStatus,
    amount: String(r.amount),
    createdByUserId: String(r.created_by_user_id),
    receivedByUserId: s(r.received_by_user_id),
    receivedAt: d(r.received_at),
    receivedAmount: s(r.received_amount),
    changeAmount: s(r.change_amount),
    bankAmount: s(r.bank_amount),
    qrPayload: s(r.qr_payload),
    qrExpiresAt: d(r.qr_expires_at),
    qrIssuedAt: d(r.qr_issued_at),
    qrProviderRef: s(r.qr_provider_ref),
    qrRefHistory: Array.isArray(r.qr_ref_history) ? r.qr_ref_history.map(String) : [],
    bankReference: s(r.bank_reference),
    qrStatusCheckedAt: d(r.qr_status_checked_at),
    qrProviderStatusRaw: s(r.qr_provider_status_raw),
    manualConfirmedByUserId: s(r.manual_confirmed_by_user_id),
    manualConfirmedAt: d(r.manual_confirmed_at),
    manualReason: s(r.manual_reason),
    reviewReason: s(r.review_reason) as ReviewReason | null,
    voidedByUserId: s(r.voided_by_user_id),
    voidedAt: d(r.voided_at),
    voidReason: s(r.void_reason),
    onecRef: s(r.onec_ref),
    onecDocType: s(r.onec_doc_type),
    idempotencyKey: String(r.idempotency_key),
    rowVersion: Number(r.row_version), // money-double: allow — версия строки
    createdAt: d(r.created_at) ?? new Date(0),
  };
}

const OPEN = [...PAYMENT_OPEN_STATUSES];

/** Поля, которые меняет переход (кроме `status`): только перечисленные столбцы, значения — параметрами. */
export interface PaymentPatch {
  readonly receivedByUserId?: string | null;
  readonly receivedAt?: Date | null;
  readonly receivedAmount?: string | null;
  readonly changeAmount?: string | null;
  readonly bankAmount?: string | null;
  readonly bankReference?: string | null;
  readonly qrPayload?: string | null;
  readonly qrExpiresAt?: Date | null;
  readonly qrIssuedAt?: Date | null;
  readonly qrProviderRef?: string | null;
  readonly qrStatusCheckedAt?: Date | null;
  readonly qrProviderStatusRaw?: string | null;
  readonly manualConfirmedByUserId?: string | null;
  readonly manualConfirmedAt?: Date | null;
  readonly manualReason?: string | null;
  readonly reviewReason?: ReviewReason | null;
  readonly voidedByUserId?: string | null;
  readonly voidedAt?: Date | null;
  readonly voidReason?: string | null;
  readonly onecRef?: string | null;
  readonly onecDocType?: string | null;
}

const PATCH_COLUMNS: Readonly<Record<keyof PaymentPatch, { readonly col: string; readonly cast?: string }>> = {
  receivedByUserId: { col: 'received_by_user_id', cast: 'uuid' },
  receivedAt: { col: 'received_at', cast: 'timestamptz' },
  receivedAmount: { col: 'received_amount', cast: 'numeric' },
  changeAmount: { col: 'change_amount', cast: 'numeric' },
  bankAmount: { col: 'bank_amount', cast: 'numeric' },
  bankReference: { col: 'bank_reference' },
  qrPayload: { col: 'qr_payload' },
  qrExpiresAt: { col: 'qr_expires_at', cast: 'timestamptz' },
  qrIssuedAt: { col: 'qr_issued_at', cast: 'timestamptz' },
  qrProviderRef: { col: 'qr_provider_ref' },
  qrStatusCheckedAt: { col: 'qr_status_checked_at', cast: 'timestamptz' },
  qrProviderStatusRaw: { col: 'qr_provider_status_raw' },
  manualConfirmedByUserId: { col: 'manual_confirmed_by_user_id', cast: 'uuid' },
  manualConfirmedAt: { col: 'manual_confirmed_at', cast: 'timestamptz' },
  manualReason: { col: 'manual_reason' },
  reviewReason: { col: 'review_reason' },
  voidedByUserId: { col: 'voided_by_user_id', cast: 'uuid' },
  voidedAt: { col: 'voided_at', cast: 'timestamptz' },
  voidReason: { col: 'void_reason' },
  onecRef: { col: 'onec_ref', cast: 'uuid' },
  onecDocType: { col: 'onec_doc_type' },
};

function setClause(status: PaymentStatus | null, patch: PaymentPatch): SQL {
  const parts: SQL[] = [sql`updated_at = now()`];
  if (status !== null) parts.push(sql`status = ${status}::payment_status`);
  for (const [key, value] of Object.entries(patch) as [keyof PaymentPatch, unknown][]) {
    if (value === undefined) continue;
    const meta = PATCH_COLUMNS[key];
    const v = value instanceof Date ? value.toISOString() : value;
    parts.push(
      meta.cast
        ? sql`${sql.raw(meta.col)} = ${v}::${sql.raw(meta.cast)}`
        : sql`${sql.raw(meta.col)} = ${v as string | null}`,
    );
  }
  return sql.join(parts, sql.raw(', '));
}

export interface NewPaymentRecord {
  readonly id?: string;
  readonly orderId: string | null;
  readonly customerId: string | null;
  readonly method: PaymentMethod;
  readonly qrProvider: 'onec' | 'none' | 'bakai' | null;
  readonly status: PaymentStatus;
  readonly amount: string;
  readonly createdByUserId: string;
  readonly idempotencyKey: string;
  readonly requestId: string | null;
}

/**
 * Доступ к `payments` (07 §5.40) — только модуль `payments` (06 §7.4). Переходы статусов — условным
 * `UPDATE … WHERE status = <ожидаемый> RETURNING` (0001 NOTES §10): конкурентный переход не теряется — вызывающий
 * получает `null` и отвечает `PAYMENT_STATE_INVALID`.
 */
@Injectable()
export class PaymentsRepository {
  /** Прежний референс QR → история платежа (перевыпуск, 10 PAY-025); повтор того же референса не дублируется. */
  async rememberQrRef(tx: DbExecutor, id: string, ref: string | null): Promise<void> {
    if (!ref) return;
    await tx.execute(sql`
      UPDATE payments SET qr_ref_history = array_append(qr_ref_history, ${ref}::text)
       WHERE id = ${id}::uuid AND NOT (${ref}::text = ANY (qr_ref_history))`);
  }

  async findById(tx: DbExecutor, id: string, lock = false): Promise<PaymentRow | null> {
    const r = await rows<Raw>(
      tx,
      sql`SELECT ${COLUMNS} FROM payments p WHERE p.id = ${id}::uuid ${lock ? sql.raw('FOR UPDATE') : sql.raw('')}`,
    );
    return r[0] ? toPaymentRow(r[0]) : null;
  }

  async listForOrder(tx: DbExecutor, orderId: string): Promise<PaymentRow[]> {
    const r = await rows<Raw>(
      tx,
      sql`SELECT ${COLUMNS} FROM payments p WHERE p.order_id = ${orderId}::uuid ORDER BY p.created_at, p.id`,
    );
    return r.map(toPaymentRow);
  }

  /** Незавершённый платёж заказа (не более одного — `payments_one_open_per_order_uq`), под блокировкой. */
  async findOpenForOrder(tx: DbExecutor, orderId: string): Promise<PaymentRow | null> {
    const r = await rows<Raw>(
      tx,
      sql`SELECT ${COLUMNS} FROM payments p
           WHERE p.order_id = ${orderId}::uuid AND p.status::text IN (${sql.join(
             OPEN.map((st) => sql`${st}`),
             sql.raw(', '),
           )})
           ORDER BY p.created_at DESC LIMIT 1 FOR UPDATE`,
    );
    return r[0] ? toPaymentRow(r[0]) : null;
  }

  async receivedTotal(tx: DbExecutor, orderId: string): Promise<string> {
    const r = await rows<{ total: string }>(
      tx,
      sql`SELECT coalesce(sum(amount), 0)::numeric(14,2)::text AS total FROM payments
           WHERE order_id = ${orderId}::uuid AND status = 'received'`,
    );
    return r[0]?.total ?? '0.00';
  }

  async insert(tx: DbExecutor, p: NewPaymentRecord): Promise<PaymentRow> {
    const r = await rows<Raw>(
      tx,
      sql`INSERT INTO payments (id, public_number, order_id, customer_id, method, qr_provider, status, amount,
                                created_by_user_id, idempotency_key, request_id)
          VALUES (coalesce(${p.id ?? null}::uuid, uuid_generate_v7()), next_payment_public_number(),
                  ${p.orderId}::uuid, ${p.customerId}::uuid, ${p.method}::payment_method, ${p.qrProvider},
                  ${p.status}::payment_status, ${p.amount}::numeric, ${p.createdByUserId}::uuid, ${p.idempotencyKey},
                  ${p.requestId})
          RETURNING id`,
    );
    const created = await this.findById(tx, String(r[0].id));
    if (!created) throw new Error('payments: строка не найдена после INSERT');
    return created;
  }

  /** Существующий платёж по ключу идемпотентности автора (`payments_idem_uq`). */
  async findByIdempotencyKey(tx: DbExecutor, key: string, userId: string): Promise<PaymentRow | null> {
    const r = await rows<Raw>(
      tx,
      sql`SELECT ${COLUMNS} FROM payments p WHERE p.idempotency_key = ${key} AND p.created_by_user_id = ${userId}::uuid`,
    );
    return r[0] ? toPaymentRow(r[0]) : null;
  }

  /**
   * Переход `from → to` с изменением полей; `null` — статус уже другой (гонка). `to = null` — обновить только поля
   * при неизменном статусе `from` (перевыпуск QR в `qr_shown`, метка опроса).
   */
  async transition(
    tx: DbExecutor,
    id: string,
    from: PaymentStatus,
    to: PaymentStatus | null,
    patch: PaymentPatch = {},
  ): Promise<PaymentRow | null> {
    const r = await rows<{ id: string }>(
      tx,
      sql`UPDATE payments SET ${setClause(to, patch)}
           WHERE id = ${id}::uuid AND status = ${from}::payment_status RETURNING id`,
    );
    if (!r[0]) return null;
    return this.findById(tx, id);
  }

  /** Платежи `qr_shown` с истёкшим QR и без `review_reason` (job `payments.qr_expire`, 06 §7.5). */
  async dueForExpiry(tx: DbExecutor, now: Date, limit: number): Promise<string[]> {
    const r = await rows<{ id: string }>(
      tx,
      sql`SELECT id FROM payments
           WHERE status = 'qr_shown' AND review_reason IS NULL AND qr_expires_at IS NOT NULL
             AND qr_expires_at <= ${now.toISOString()}::timestamptz
           ORDER BY qr_expires_at LIMIT ${limit}`,
    );
    return r.map((x) => x.id);
  }

  /** Платежи с QR 1С, которые нужно опрашивать или отменить в 1С (восстановление цепочки опроса после рестарта). */
  async pollCandidates(tx: DbExecutor, limit: number): Promise<string[]> {
    const r = await rows<{ id: string }>(
      tx,
      sql`SELECT id FROM payments
           WHERE qr_provider = 'onec' AND qr_provider_ref IS NOT NULL
             AND (status = 'qr_shown'
                  OR (status = 'voided' AND coalesce(qr_provider_status_raw, '') NOT IN ('cancelled', 'paid', 'cancel_failed')))
           ORDER BY updated_at LIMIT ${limit}`,
    );
    return r.map((x) => x.id);
  }
}

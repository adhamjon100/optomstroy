import { sql } from 'drizzle-orm';
import { TRANSACTION_KIND_VALUES, type TransactionKind } from '../enums.js';
import { MONEY_AMOUNT_RE } from '../money/money.js';
import type { SalesTx, TransactionRecordInput, TransactionRecordResult, TransactionsWriter } from '../ports/index.js';

/** Ошибка программиста: строка журнала не прошла проверку формы до SQL (не бизнес-отказ). */
export class TransactionJournalError extends Error {
  override readonly name = 'TransactionJournalError';
}

const KINDS = new Set<string>(TRANSACTION_KIND_VALUES);

/**
 * Ключи `transactions.dedupe_key` (TXN-005: «каждая финансовая операция существует в журнале ровно один раз»).
 * Форматы совпадают с записанными этапом F (orders: `<kind>:<orderId>`; payments: `<kind>:<paymentId>:<ISO>` —
 * одна строка на переход платежа), поэтому повтор события F/G после перехода на журнал дубля не создаёт.
 */
export const transactionDedupeKey = {
  /** `order_created`, `order_cancelled`, `credit_sale_approved`, `discount_override` — одна строка на заказ. */
  order(
    kind: Extract<TransactionKind, 'order_created' | 'order_cancelled' | 'credit_sale_approved' | 'discount_override'>,
    orderId: string,
  ): string {
    return `${kind}:${orderId}`;
  },
  /** `payment_received`, `payment_voided`, `manual_qr_confirm` — одна строка на переход платежа. */
  payment(
    kind: Extract<TransactionKind, 'payment_received' | 'payment_voided' | 'manual_qr_confirm'>,
    paymentId: string,
    occurredAt: Date,
  ): string {
    return `${kind}:${paymentId}:${occurredAt.toISOString()}`;
  },
  /** `return_requested` (could, TXN-001) — одна строка на заявку (отправка `submit`). */
  returnRequested(returnRequestId: string): string {
    return `return_requested:${returnRequestId}`;
  },
  /** Документ 1С (`refund` из «Возврата товаров от клиента», реализации — TXN-007): идемпотентно по `onec_ref`. */
  onecDocument(kind: TransactionKind, onecRef: string): string {
    return `${kind}:onec:${onecRef}`;
  },
} as const;

function check(i: TransactionRecordInput): void {
  if (!KINDS.has(i.kind)) throw new TransactionJournalError(`transactions.kind: неизвестный вид ${String(i.kind)}`);
  if (!MONEY_AMOUNT_RE.test(i.amount)) {
    throw new TransactionJournalError('transactions.amount: строка NUMERIC(14,2) со знаком ("-1500.00")');
  }
  if (!i.orderId && !i.paymentId && !i.returnRequestId && !i.shipmentId) {
    throw new TransactionJournalError('transactions: нужна ссылка order/payment/return_request/shipment (07 §5.44)');
  }
  if (!i.dedupeKey || i.dedupeKey.length > 300) throw new TransactionJournalError('transactions.dedupe_key: 1…300');
  if (!i.title.trim()) throw new TransactionJournalError('transactions.title_ru: не пустой');
  if (!i.statusSnapshot.trim()) throw new TransactionJournalError('transactions.status_snapshot: не пустой');
  if ((i.source ?? 'pos') === 'onec' && i.actorUserId) {
    throw new TransactionJournalError('transactions: строка source=onec без actor_user_id (TXN-007)');
  }
}

/**
 * `TransactionJournal` (06 §7.4 п. (г), `common/journal` [НОВОЕ ИМЯ]) — реализация порта `TransactionsWriter` по
 * умолчанию: `INSERT … ON CONFLICT (dedupe_key) DO NOTHING` в транзакции вызывающего. Бизнес-правил нет (какое
 * событие и с какой суммой пишется — решает модуль-владелец агрегата: orders, payments, returns, обработчики 1С).
 */
export class TransactionJournal implements TransactionsWriter {
  async record(tx: SalesTx, i: TransactionRecordInput): Promise<TransactionRecordResult> {
    check(i);
    const occurred = i.occurredAt ? sql`${i.occurredAt.toISOString()}::timestamptz` : sql`now()`;
    const ins = await tx.execute<{ id: string }>(sql`
      INSERT INTO transactions (kind, source, order_id, payment_id, return_request_id, shipment_id, customer_id,
                                actor_user_id, amount, payment_method, status_snapshot, title_ru, details, occurred_at,
                                onec_ref, onec_number, onec_doc_type, dedupe_key)
      VALUES (${i.kind}::transaction_kind, ${i.source ?? 'pos'}::transaction_source, ${i.orderId ?? null}::uuid,
              ${i.paymentId ?? null}::uuid, ${i.returnRequestId ?? null}::uuid, ${i.shipmentId ?? null}::uuid,
              ${i.customerId ?? null}::uuid, ${i.actorUserId ?? null}::uuid, ${i.amount}::numeric,
              ${i.paymentMethod ?? null}::payment_method, ${i.statusSnapshot}, ${i.title},
              ${JSON.stringify(i.details ?? {})}::jsonb, ${occurred}, ${i.onecRef ?? null}::uuid,
              ${i.onecNumber ?? null}, ${i.onecDocType ?? null}, ${i.dedupeKey})
      ON CONFLICT (dedupe_key) DO NOTHING
      RETURNING id`);
    const created = ins.rows[0]?.id;
    if (created) return { created: true, id: created };
    const ex = await tx.execute<{ id: string }>(sql`SELECT id FROM transactions WHERE dedupe_key = ${i.dedupeKey}`);
    return { created: false, id: ex.rows[0]?.id ?? null };
  }
}

/** Экземпляр журнала для модулей F/G, пишущих строку в своей транзакции (stateless). */
export const transactionJournal: TransactionsWriter = new TransactionJournal();

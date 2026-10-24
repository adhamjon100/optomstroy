import type { PaymentMethod, TransactionKind, TransactionSource } from '../enums.js';
import type { MoneyString, SalesTx } from './sales-context.js';

/**
 * `TransactionsWriter` (этап G, RM-G-004; 06 §7.4 п. (г) `TransactionJournal.record` [НОВОЕ ИМЯ] в `common/journal`)
 * — **единственный** путь записи строки производного журнала `transactions` (07 §5.44; 10 TXN-001, TXN-005): только
 * `INSERT … ON CONFLICT (dedupe_key) DO NOTHING`, без бизнес-правил, в транзакции вызывающего (атомарно с
 * агрегатом, ARCH-032). Модуль `transactions` в таблицу не пишет — только читает.
 *
 * Реализация по умолчанию — `TransactionJournal` (`common/journal/transaction-journal.ts`), привязана в
 * `createSalesPortRegistry()`; события этапа F (`order_created`, `order_cancelled`, `credit_sale_approved`,
 * `discount_override` — orders; `payment_received`, `payment_voided`, `manual_qr_confirm` — payments) пишутся через
 * неё. Ключи `dedupe_key` — `transactionDedupeKey` (common/journal). Заглушка — `InMemoryTransactionsWriter`
 * (`test/support/cashier-ports.fakes.ts`).
 *
 * Знак суммы (TXN-001): `+` приход, `−` возврат/аннулирование (`payment_voided`, `refund`); `return_requested` —
 * `0.00`. Ссылка обязательна: хотя бы одно из `orderId`, `paymentId`, `returnRequestId`, `shipmentId`
 * (`transactions_link_chk`).
 */
export const TRANSACTIONS_WRITER = 'sales.TransactionsWriter' as const;

export interface TransactionRecordInput {
  readonly kind: TransactionKind;
  /** По умолчанию `pos`; `onec` — документы 1С (`refund`, реализации — TXN-007) без `actorUserId`. */
  readonly source?: TransactionSource;
  readonly orderId?: string | null;
  readonly paymentId?: string | null;
  readonly returnRequestId?: string | null;
  readonly shipmentId?: string | null;
  readonly customerId?: string | null;
  readonly actorUserId?: string | null;
  /** Строка `NUMERIC(14,2)` со знаком (`"-1500.00"`). */
  readonly amount: MoneyString;
  readonly paymentMethod?: PaymentMethod | null;
  /** Статус связанного документа на момент записи (`orders.status`, `payments.status`, …). */
  readonly statusSnapshot: string;
  /** `title_ru` строки журнала. */
  readonly title: string;
  readonly details?: Readonly<Record<string, unknown>>;
  /** Момент операции; не задан — `now()` транзакции. */
  readonly occurredAt?: Date | null;
  readonly onecRef?: string | null;
  readonly onecNumber?: string | null;
  readonly onecDocType?: string | null;
  /** Ключ идемпотентности строки (`transactions_dedupe_key_uq`) — `transactionDedupeKey(...)`. */
  readonly dedupeKey: string;
}

export interface TransactionRecordResult {
  /** `false` — строка с этим `dedupeKey` уже была (повтор, TXN-005). */
  readonly created: boolean;
  /** `id` новой строки; при повторе — `id` существующей (или `null`, если её не видно в транзакции). */
  readonly id: string | null;
}

export interface TransactionsWriter {
  record(tx: SalesTx, input: TransactionRecordInput): Promise<TransactionRecordResult>;
}

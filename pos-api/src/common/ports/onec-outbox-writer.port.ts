import type { OutboxAggregate, OutboxStatus } from '../enums.js';
import type { SalesTx } from './sales-context.js';

/**
 * `OnecOutboxWriter` — постановка документа 1С в `onec_outbox` **в транзакции агрегата** и пробуждение диспетчера
 * `outbox.dispatch` **после COMMIT** (06 §7.4 `OutboxService.enqueue`, 07 §8.2; ядро §22.1, §22.3). `external_id` =
 * UUID агрегата (CHECK `onec_outbox_external_is_aggregate_chk`). Переходы — только по автомату 07 §6.5
 * (`sales-domain/outbox/outbox-status.ts`). Реализация — агент F-be-orders (`src/sync/outbox/**`); потребители —
 * orders (create/cancel заказа, onec-link), payments (документ оплаты, Q-012).
 */
export const ONEC_OUTBOX_WRITER = 'sales.OnecOutboxWriter' as const;

export interface OutboxEnqueueInput {
  readonly aggregateType: OutboxAggregate;
  readonly aggregateId: string;
  readonly operation: 'create' | 'cancel';
  /** Тело запроса к методу `/pos/v1/*` (05 §6); `payload_hash` считает реализация. */
  readonly payload: Readonly<Record<string, unknown>>;
  readonly dependsOnOutboxId?: string | null;
  readonly priority?: number;
  readonly requestedByUserId?: string | null;
  readonly warehouseId?: string | null;
}

export interface OutboxItemView {
  readonly outboxId: string;
  readonly status: OutboxStatus;
  readonly attempts: number;
  readonly onecRef: string | null;
}

export interface OnecOutboxWriter {
  /** INSERT `pending` (`next_attempt_at = now()`); повтор той же пары (агрегат, операция) — существующая строка. */
  enqueue(tx: SalesTx, input: OutboxEnqueueInput): Promise<OutboxItemView>;
  /** Текущая строка `(aggregate, operation)` под `FOR UPDATE`; `null` — нет. */
  lock(
    tx: SalesTx,
    key: {
      readonly aggregateType: OutboxAggregate;
      readonly aggregateId: string;
      readonly operation: 'create' | 'cancel';
    },
  ): Promise<OutboxItemView | null>;
  /** Отзыв задачи (`pending | failed | dead → cancelled`) транзакцией бизнес-операции над агрегатом. */
  cancel(tx: SalesTx, outboxId: string): Promise<void>;
  /**
   * Повторная постановка задачи `failed | dead → pending` (`attempts = 0`, `next_attempt_at = now()`; 07 §6.5
   * `manual_retry`) в транзакции бизнес-операции — например, новый запрос отмены после отказа 1С (ORD-050, 08 §4.8.4).
   * `payload` — новое тело запроса (по умолчанию прежнее). Другой статус — `409 ORDER_STATE_INVALID` (автомат).
   */
  requeue(
    tx: SalesTx,
    input: {
      readonly outboxId: string;
      readonly payload?: Readonly<Record<string, unknown>>;
      readonly requestedByUserId?: string | null;
    },
  ): Promise<OutboxItemView>;
  /** Ручная привязка документа 1С (`pending | failed | dead → sent`, ORD-034, ядро §23 п. 1). */
  markSentManually(
    tx: SalesTx,
    input: { readonly outboxId: string; readonly onecRef: string; readonly onecNumber?: string | null },
  ): Promise<void>;
  /** После COMMIT: опубликовать `outbox.dispatch` (не ждать тикера). Ошибка публикации не критична — тикер подберёт. */
  kickAfterCommit(): Promise<void>;
}

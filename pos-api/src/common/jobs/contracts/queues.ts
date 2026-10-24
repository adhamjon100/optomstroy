/**
 * Контракты очередей pg-boss (B-AR-12; 06 §7.5, §7.4 п. (б)): имена очередей и типы payload объявлены здесь,
 * в common/jobs/contracts, чтобы публикатор (`sync`) и обработчик (модуль-владелец агрегата) не импортировали
 * друг друга (MOD-022). Значения имён — ровно как в 06 §7.5; новое имя добавляется сначала в 06.
 * Параметры очередей (singleton, retryLimit, backoff, dead-letter) — RM-C-007 (src/sync/scheduler/**).
 */
export const QUEUES = {
  // Синхронизация с 1С (worker, модуль sync)
  onecChanges: 'onec.changes',
  syncStock: 'sync.stock',
  syncPrices: 'sync.prices',
  syncOrderStatus: 'sync.order_status',
  syncMaster: 'sync.master',
  syncCustomers: 'sync.customers',
  syncReceivables: 'sync.receivables',
  syncDiscounts: 'sync.discounts',
  syncSalesHistory: 'sync.sales_history',
  syncImages: 'sync.images',
  syncReconcile: 'sync.reconcile',
  syncManual: 'sync.manual',
  syncPaymentDocs: 'sync.payment_docs',
  syncReturnDocs: 'sync.return_docs',
  syncCountCheck: 'sync.count_check',
  syncPostVacuum: 'sync.post_vacuum',
  // Outbox (07 §8.2)
  outboxDispatch: 'outbox.dispatch',
  outboxUnlock: 'outbox.unlock',
  outboxReconcileAggregates: 'outbox.reconcile-aggregates',
  // События результата доставки outbox → модули-владельцы агрегатов (06 §7.4 п. (б))
  ordersOnecConfirmed: 'orders.onec-confirmed',
  ordersOnecFailed: 'orders.onec-failed',
  ordersOnecStatusChanged: 'orders.onec-status-changed',
  paymentsOnecConfirmed: 'payments.onec-confirmed',
  paymentsOnecFailed: 'payments.onec-failed',
  paymentsOnecQrStatus: 'payments.onec-qr-status',
  customersOnecConfirmed: 'customers.onec-confirmed',
  customersOnecFailed: 'customers.onec-failed',
  returnsOnecConfirmed: 'returns.onec-confirmed',
  returnsOnecFailed: 'returns.onec-failed',
  // Изменения реплик каталога → корзины (05 SYNC-070)
  catalogPricesChanged: 'catalog.prices-changed',
  catalogStockChanged: 'catalog.stock-changed',
  // Прочие периодические задачи
  ordersManualSlaCheck: 'orders.manual_sla_check',
  paymentsQrExpire: 'payments.qr_expire',
  paymentsQrOnecPoll: 'payments.qr_onec_poll',
  cartParkedExpire: 'cart.parked_expire',
  smsSend: 'sms.send',
  smsBalancePoll: 'sms.balance_poll',
  // Аудит и сроки хранения (06 §7.5; 07 §9.3, §13.3; 11 SEC-080, SEC-081) — 03:30 Asia/Bishkek.
  auditAnchor: 'audit.anchor',
  auditVerify: 'audit.verify',
  retentionDaily: 'retention.daily',
} as const;

export type QueueName = (typeof QUEUES)[keyof typeof QUEUES];

/** Payload `<aggregate>.onec-confirmed` (06 §7.4 п. (б)). Идемпотентность обработчика — по `outboxId`. */
export interface OnecConfirmedPayload {
  readonly outboxId: string;
  readonly aggregateId: string;
  readonly onecRef: string;
  readonly onecNumber: string | null;
  readonly onecStatus: string | null;
  readonly attempt: number;
}

/** Payload `<aggregate>.onec-failed`: бизнес-отказ/ошибка данных 1С (`failed`, ONEC_REJECTED). */
export interface OnecFailedPayload {
  readonly outboxId: string;
  readonly aggregateId: string;
  readonly errorCode: string;
  readonly attempt: number;
}

/**
 * Payload `orders.onec-status-changed`: элемент `Document_ЗаказКлиента` плана обмена (`/changes`, контракт
 * `OrderChange`; 05 §6.2) по заказу POS (`externalId` = `orders.id`). Публикует `sync` в транзакции сообщения,
 * применяет модуль `orders` той же процедурой, что и опрос `POST /orders/status` (проекция статуса D-20,
 * идемпотентно). `document` — поля элемента «как есть» (сырые значения 1С).
 */
export interface OrderOnecStatusChangedPayload {
  readonly orderId: string;
  readonly document: {
    readonly ref: string;
    readonly number: string | null;
    readonly date: string | null;
    readonly status: string | null;
    readonly approved: boolean | null;
    readonly deletionMark: boolean;
    readonly total: string | null;
    readonly fulfillmentState: string | null;
    readonly shipments: readonly unknown[];
  };
}

/** Payload `catalog.prices-changed` / `catalog.stock-changed`. */
export interface CatalogChangedPayload {
  readonly variantIds: readonly string[];
}

/** Все сообщения несут requestId/runId для сквозной корреляции логов API ↔ worker (RM-C-010). */
export interface JobEnvelopeMeta {
  readonly requestId?: string;
  readonly runId?: string;
}

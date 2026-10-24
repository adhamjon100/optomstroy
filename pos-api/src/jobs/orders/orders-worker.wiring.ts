import type pg from 'pg';
import type { PgBoss } from 'pg-boss';
import type { Logger } from 'pino';
import type { AppConfig } from '../../common/config/app-config.js';
import {
  type OnecConfirmedPayload,
  type OnecFailedPayload,
  type OrderOnecStatusChangedPayload,
  QUEUES,
} from '../../common/jobs/contracts/queues.js';
import type { CartReader, NotificationsPort, PaymentsPort } from '../../common/ports/index.js';
import { createDatabase } from '../../db/database.js';
import type { OnecGateway } from '../../integrations/onec/onec-gateway.js';
import { NotificationsRepository } from '../../notifications/center/notifications.repository.js';
import { NotificationsPortService } from '../../notifications/center/notifications-port.service.js';
import { OrderOnecResultsHandler } from '../../orders/worker/order-onec-results.handler.js';
import { parseOnecOrderDocument } from '../../orders/order-projection.js';
import { OrderStatusSyncHandler } from '../../orders/worker/order-status-sync.handler.js';
import { OnecOutboxDelivery } from '../../sync/outbox/onec-outbox.delivery.js';
import type { OutboxDeliveryPort } from '../outbox/outbox-delivery.port.js';
import type { OutboxDispatcherHooks } from '../outbox/outbox-dispatcher.js';
import type { SyncEntityHandler } from '../sync/sync-handler.js';

export interface OrdersWorkerWiringOptions {
  readonly config: Pick<
    AppConfig,
    'ONEC_MODE' | 'ONEC_ODATA_WRITE_ENABLED' | 'ONEC_TIMEOUT_MS' | 'ONEC_SYNC_CHECK_TIMEOUT_MS'
  >;
  readonly pool: pg.Pool;
  readonly log: Logger;
  /** Шлюз 1С (тот же, что у синхронизации); `undefined` — канал записи не подключён. */
  readonly gateway?: OnecGateway;
  /** `NotificationsPort` процесса воркера; по умолчанию — реализация модуля notifications над тем же пулом. */
  readonly notifications?: NotificationsPort | null;
  /** Порт корзины для ORD-027 (восстановление состава при `submit_failed`); нет — шаг пропускается (FQ-ORD-05). */
  readonly cart?: CartReader | null;
  /** Порт платежей (аннулирование неполученных при отмене/отказе 1С). */
  readonly payments?: PaymentsPort | null;
}

export interface OrdersWorkerWiring {
  /** `WorkerRuntimeOptions.outboxDelivery`: канал записи заказов/платежей в 1С. */
  readonly outboxDelivery: OutboxDeliveryPort | undefined;
  /** `WorkerRuntimeOptions.outboxHooks`: `dead` → уведомления. */
  readonly outboxHooks: OutboxDispatcherHooks;
  /** `WorkerRuntimeOptions.extraWorkers`: `orders.onec-confirmed`, `orders.onec-failed`. */
  readonly register: (boss: PgBoss) => Promise<void>;
  /** `WorkerRuntimeOptions.jobs`: `outbox.reconcile-aggregates`. */
  readonly jobs: Record<string, (job: { readonly id: string; readonly data: unknown }) => Promise<unknown>>;
  /** `SyncWorkerWiringOptions.handlers`: `order_status`. */
  readonly handlers: { readonly order_status?: SyncEntityHandler };
  readonly results: OrderOnecResultsHandler;
}

/**
 * Обработчик `orders.onec-status-changed`: документ «Заказ клиента» из `/changes` применяется той же процедурой,
 * что и ответ опроса `POST /orders/status` (`applyDocument`: проекция D-20, история, уведомление, `linked`, outbox
 * `sent → confirmed`; идемпотентно). Нет обработчика статусов (шлюз 1С не создан) — исключение: задача остаётся в
 * очереди с повтором (`retryLimit` событий результата ≥ 1000), элемент не теряется.
 */
export function orderStatusChangedJob(
  statusSync: Pick<OrderStatusSyncHandler, 'applyDocument'> | undefined,
): (data: OrderOnecStatusChangedPayload) => Promise<unknown> {
  return async (data) => {
    if (!data?.orderId || !data.document) return { outcome: 'ignored_bad_payload' };
    if (!statusSync) throw new Error('orders.onec-status-changed: обработчик статусов заказов не подключён');
    return statusSync.applyDocument(data.orderId, parseOnecOrderDocument(data.document), null);
  };
}

/**
 * Сборка обработчиков заказов для `pos-worker` (RM-F-002; 06 §7.5; 07 §8.2; ядро §22.1, §23 п. 2) без Nest:
 * канал записи outbox → 1С (`OnecOutboxDelivery`), события результата `orders.onec-confirmed|failed` (проекция
 * статуса в момент `sent`), сверщик `outbox.reconcile-aggregates`, уведомление о `dead` и синхронизация статусов
 * `order_status` (расписание этапа E). Фаза 0 без канала записи (`odata_only` без `ONEC_ODATA_WRITE_ENABLED`) —
 * канал не подключается (строки остаются `pending`, 05 SYNC-066).
 */
export function createOrdersWorkerWiring(o: OrdersWorkerWiringOptions): OrdersWorkerWiring {
  const log = o.log.child({ component: 'orders' });
  const db = createDatabase(o.pool);
  const notifications =
    o.notifications !== undefined ? o.notifications : new NotificationsPortService(new NotificationsRepository(db));
  const results = new OrderOnecResultsHandler({
    db,
    notifications,
    cart: o.cart ?? null,
    payments: o.payments ?? null,
    log,
  });
  const writeChannel = o.config.ONEC_MODE !== 'odata_only' || o.config.ONEC_ODATA_WRITE_ENABLED;
  const outboxDelivery =
    o.gateway && writeChannel ? new OnecOutboxDelivery(o.gateway, { timeoutMs: o.config.ONEC_TIMEOUT_MS }) : undefined;
  const statusSync = o.gateway
    ? new OrderStatusSyncHandler({
        db,
        gateway: o.gateway,
        notifications,
        payments: o.payments ?? null,
        log,
        timeoutMs: o.config.ONEC_TIMEOUT_MS,
      })
    : undefined;

  const register = async (boss: PgBoss): Promise<void> => {
    const poll = { pollingIntervalSeconds: 2, batchSize: 1 };
    await boss.work<OnecConfirmedPayload>(QUEUES.ordersOnecConfirmed, poll, async ([job]) => {
      if (!job) return undefined;
      return { outcome: await results.onConfirmed(job.data) };
    });
    await boss.work<OnecFailedPayload>(QUEUES.ordersOnecFailed, poll, async ([job]) => {
      if (!job) return undefined;
      return { outcome: await results.onFailed(job.data) };
    });
    // Элемент `Document_ЗаказКлиента` плана обмена (публикует sync в транзакции сообщения; разбор расхождений п. 8).
    const statusChanged = orderStatusChangedJob(statusSync);
    await boss.work<OrderOnecStatusChangedPayload>(QUEUES.ordersOnecStatusChanged, poll, async ([job]) =>
      job ? statusChanged(job.data) : undefined,
    );
  };

  return {
    outboxDelivery,
    outboxHooks: { onDead: (row, info) => results.onDead(row, `${info.code}: ${info.reason}`) },
    register,
    jobs: { [QUEUES.outboxReconcileAggregates]: () => results.reconcile() },
    handlers: statusSync ? { order_status: statusSync } : {},
    results,
  };
}

import type { Queue } from 'pg-boss';
import { QUEUES, type QueueName } from '../../common/jobs/contracts/queues.js';
import type { SchedulerConfig } from './scheduler.config.js';
import { IMAGES_GC_QUEUE, SYNC_DEAD_LETTER_QUEUE, SYNC_ENTITY_QUEUES, SYNC_QUEUE_POLICY } from './sync-queues.js';

export interface QueueSpec {
  readonly name: string;
  readonly options: Omit<Queue, 'name'>;
}

const DAY = 86_400;

/**
 * Параметры очередей pg-boss (06 §7.5; 07 §8.2; ядро §22.1). Порядок важен: очередь «мёртвых писем»
 * создаётся раньше очередей, которые на неё ссылаются (FK в схеме pg-boss).
 */
export function queueSpecs(cfg: Pick<SchedulerConfig, 'sync'>): QueueSpec[] {
  const syncRetry = {
    retryLimit: cfg.sync.retryLimit,
    retryDelay: cfg.sync.retryDelay,
    retryBackoff: cfg.sync.retryBackoff,
    ...(cfg.sync.retryBackoff ? { retryDelayMax: cfg.sync.retryDelayMax } : {}),
    expireInSeconds: cfg.sync.expireInSeconds,
  };
  const syncQueue = (name: string): QueueSpec => ({
    name,
    options: { policy: SYNC_QUEUE_POLICY, deadLetter: SYNC_DEAD_LETTER_QUEUE, ...syncRetry },
  });
  /** Периодический «тикер» без собственных повторов: следующий тик и есть повтор (07 §8.2: `retryLimit=0`). */
  const ticker = (name: QueueName, expireInSeconds = 600): QueueSpec => ({
    name,
    options: { policy: 'exclusive', retryLimit: 0, expireInSeconds },
  });
  /**
   * События результата outbox → модули-владельцы агрегатов: без низкого лимита попыток и без `dead`
   * (06 §7.5; 07 §8.2: `retryLimit` ≥ 1000, backoff до 60 мин).
   */
  const resultEvent = (name: QueueName): QueueSpec => ({
    name,
    options: {
      policy: 'standard',
      retryLimit: 1000,
      retryBackoff: true,
      retryDelay: 30,
      retryDelayMax: 3600,
      retentionSeconds: 30 * DAY,
    },
  });

  return [
    { name: SYNC_DEAD_LETTER_QUEUE, options: { policy: 'standard', retentionSeconds: 30 * DAY, retryLimit: 0 } },
    ...SYNC_ENTITY_QUEUES.map(syncQueue),
    { ...syncQueue(QUEUES.syncReconcile), options: { ...syncQueue(QUEUES.syncReconcile).options, retryLimit: 1 } },
    { ...syncQueue(QUEUES.syncCountCheck), options: { ...syncQueue(QUEUES.syncCountCheck).options, retryLimit: 1 } },
    { ...syncQueue(QUEUES.syncPostVacuum), options: { ...syncQueue(QUEUES.syncPostVacuum).options, retryLimit: 1 } },
    // 05 SYNC-011: одна job на узел плана обмена; ошибка → ack не отправлен, следующий цикл повторит сообщение.
    ticker(QUEUES.onecChanges, cfg.sync.expireInSeconds),
    ticker(QUEUES.outboxDispatch),
    ticker(QUEUES.outboxUnlock),
    ticker(QUEUES.outboxReconcileAggregates),
    // EQ-IMG-10: ежесуточная очистка файлов фото; повтор — следующий запуск (двухфазная пометка → удаление).
    { name: IMAGES_GC_QUEUE, options: { policy: 'exclusive', retryLimit: 0, expireInSeconds: 3600 } },
    ...[
      QUEUES.ordersOnecConfirmed,
      QUEUES.ordersOnecFailed,
      // Элемент `Document_ЗаказКлиента` плана обмена → модуль orders (разбор расхождений п. 8; ядро §22.8).
      QUEUES.ordersOnecStatusChanged,
      QUEUES.paymentsOnecConfirmed,
      QUEUES.paymentsOnecFailed,
      QUEUES.customersOnecConfirmed,
      QUEUES.customersOnecFailed,
      QUEUES.returnsOnecConfirmed,
      QUEUES.returnsOnecFailed,
    ].map(resultEvent),
  ];
}

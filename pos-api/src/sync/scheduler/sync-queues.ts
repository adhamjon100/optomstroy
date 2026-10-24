import { QUEUES, type QueueName } from '../../common/jobs/contracts/queues.js';
import type { SyncEntity, SyncMode, SyncTrigger } from '../../common/enums.js';
import type { SchedulerConfig } from './scheduler.config.js';

/**
 * Очереди синхронизации и outbox (06 §7.5; 05 §7.3, SYNC-011, SYNC-021, SYNC-023). Имена — только из
 * common/jobs/contracts/queues.ts. Здесь — параметры очередей и соответствие сущность → очередь → cron.
 */

/**
 * Очередь «мёртвых писем» для job синхронизации: job, исчерпавшая `retryLimit`, копируется сюда (pg-boss
 * `deadLetter`). `[НОВОЕ ИМЯ: RM-C-007]` — в 06 §7.5 имени нет; предложение для 06 §7.5 (имена через точку, K-16).
 * Очередь не обрабатывается: это стоянка для разбора администратором (повтор — `redrive`/ручной запуск).
 */
export const SYNC_DEAD_LETTER_QUEUE = 'sync.dead_letter';

/**
 * Регламентная очистка осиротевших файлов фото (EQ-IMG-10; имя `images.gc` — 07 §5.23, 13 RM-E-003). В 06 §7.5 и
 * `common/jobs/contracts/queues.ts` имени пока нет (`[НОВОЕ ИМЯ]`, как у `sync.dead_letter`): публикует и
 * обрабатывает очередь только `pos-worker` (планировщик), других публикаторов нет. Предложение для 06 §7.5.
 */
export const IMAGES_GC_QUEUE = 'images.gc';

/** Узел плана обмена POS (05 SYNC-011: `onec.changes` — singleton на узел, не на сущность). */
export const ONEC_EXCHANGE_NODE = 'POS';

/** Payload job синхронизации сущности. `runId` — только у ручного запуска (строка `sync_runs` уже создана). */
export interface SyncJobPayload {
  readonly entity: SyncEntity;
  readonly mode: SyncMode;
  readonly trigger: SyncTrigger;
  readonly runId?: string;
  readonly userId?: string;
  readonly requestId?: string;
}

/** Ключ расписания в pg-boss — сущность (несколько расписаний одной очереди, напр. `sync.master`). */
export type CronSource = keyof SchedulerConfig['cron'];

interface EntityQueueDef {
  readonly queue: QueueName;
  /** cron по умолчанию (env `SYNC_*_CRON`); для сущностей без своей переменной — `master` (30 мин, 05 §7.3). */
  readonly cron: CronSource;
}

/** Сущность → очередь и cron по умолчанию (06 §7.5; 05 §7.3; для `payment_docs`/`return_docs` — 30 мин, Q-020). */
export const ENTITY_QUEUES: Readonly<Record<SyncEntity, EntityQueueDef>> = {
  stock: { queue: QUEUES.syncStock, cron: 'stock' },
  prices: { queue: QUEUES.syncPrices, cron: 'prices' },
  order_status: { queue: QUEUES.syncOrderStatus, cron: 'orderStatus' },
  categories: { queue: QUEUES.syncMaster, cron: 'master' },
  products: { queue: QUEUES.syncMaster, cron: 'master' },
  variants: { queue: QUEUES.syncMaster, cron: 'master' },
  attributes: { queue: QUEUES.syncMaster, cron: 'master' },
  units: { queue: QUEUES.syncMaster, cron: 'master' },
  barcodes: { queue: QUEUES.syncMaster, cron: 'master' },
  warehouses: { queue: QUEUES.syncMaster, cron: 'master' },
  customers: { queue: QUEUES.syncCustomers, cron: 'master' },
  receivables: { queue: QUEUES.syncReceivables, cron: 'master' },
  discounts: { queue: QUEUES.syncDiscounts, cron: 'master' },
  sales_history: { queue: QUEUES.syncSalesHistory, cron: 'master' },
  images: { queue: QUEUES.syncImages, cron: 'images' },
  payment_docs: { queue: QUEUES.syncPaymentDocs, cron: 'master' },
  return_docs: { queue: QUEUES.syncReturnDocs, cron: 'master' },
};

/**
 * Сущности, которые в режиме расширения (`ONEC_MODE=extension`, фаза 1) по-прежнему опрашиваются своими
 * cron-заданиями: срезы (`stock`, `prices`, `receivables`), статусы (`order_status`) и фото (05 SYNC-011).
 * Остальные сущности в фазе 1 приходят через `onec.changes`; их `sync.<entity>` — только `full`/`reconcile`/ручной.
 */
export const EXTENSION_POLLED_ENTITIES: readonly SyncEntity[] = [
  'stock',
  'prices',
  'receivables',
  'order_status',
  'images',
];

/** Сущности, которые планируются по расписанию инкрементом в данном режиме 1С. */
export function scheduledEntities(mode: SchedulerConfig['onecMode'], all: readonly SyncEntity[]): SyncEntity[] {
  return mode === 'extension' ? all.filter((e) => EXTENSION_POLLED_ENTITIES.includes(e)) : [...all];
}

/** Очереди job синхронизации сущностей (обрабатываются `SyncJobProcessor`). */
export const SYNC_ENTITY_QUEUES: readonly QueueName[] = [
  ...new Set([...Object.values(ENTITY_QUEUES).map((d) => d.queue), QUEUES.syncManual]),
];

/** Политика pg-boss `stately`: по одной job в состояниях queued и active на ключ (`singletonKey` = сущность). */
export const SYNC_QUEUE_POLICY = 'stately';

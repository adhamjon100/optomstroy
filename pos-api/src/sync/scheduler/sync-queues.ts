import { QUEUES, type QueueName } from '../../common/jobs/contracts/queues.js';
import { SYNC_ENTITY_VALUES, type SyncEntity, type SyncMode, type SyncTrigger } from '../../common/enums.js';
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

/**
 * Сущности плана обмена в режиме расширения: все, кроме `EXTENSION_POLLED_ENTITIES` (их инкремент — только цикл
 * `onec.changes`, по которому планировщик ставит одно задание узла, 05 SYNC-011). Успешный цикл подтверждает их
 * свежесть (`OnecChangesService` `freshnessEntities`, POSAPI-T1-01).
 */
export const EXTENSION_PLAN_ENTITIES: readonly SyncEntity[] = SYNC_ENTITY_VALUES.filter(
  (e) => !EXTENSION_POLLED_ENTITIES.includes(e),
);

/**
 * Сущности режима `os_api` (ADR-126, ОС_API — только чтение): каталог, цены, остатки (полная перечитка по
 * расписанию `ONEC_OSAPI_POLL_SECONDS`) и фото. Клиентов, долгов, скидок и документов ОС_API в этом режиме не
 * читает — их задания не ставятся (иначе каждые 5–30 минут прогон с отказом 501 и тревогой). Статусы заказов
 * (`order_status`, `GET /orders/{id}`) — только при записи заказов (`ONEC_OSAPI_WRITE_ORDERS=true`), см.
 * `scheduledEntities`.
 */
export const OSAPI_POLLED_ENTITIES: readonly SyncEntity[] = [
  'units',
  'categories',
  'products',
  'variants',
  'attributes',
  'barcodes',
  'warehouses',
  'prices',
  'stock',
  'images',
];

/**
 * Сущности, которые планируются по расписанию инкрементом в данном режиме 1С. `os_api` с записью заказов
 * (`osApiWriteOrders`, решение владельца 25.11.2026) — плюс `order_status`: черновики, записанные POS, читаются
 * `GET /orders/{id}` (проведение в 1С, отгрузки, чеки ККМ).
 */
export function scheduledEntities(
  mode: SchedulerConfig['onecMode'],
  all: readonly SyncEntity[],
  opts: { readonly osApiWriteOrders?: boolean } = {},
): SyncEntity[] {
  if (mode === 'extension') return all.filter((e) => EXTENSION_POLLED_ENTITIES.includes(e));
  if (mode === 'os_api') {
    return all.filter(
      (e) => OSAPI_POLLED_ENTITIES.includes(e) || (e === 'order_status' && opts.osApiWriteOrders === true),
    );
  }
  return [...all];
}

/**
 * cron периода перечитки ОС_API (`ONEC_OSAPI_POLL_SECONDS`, кратно 60, 60…3600): `*\/N * * * *` по минутам,
 * 3600 — раз в час (`0 * * * *`).
 */
export function osApiPollCron(seconds: number): string {
  const minutes = Math.max(1, Math.round(seconds / 60));
  return minutes >= 60 ? '0 * * * *' : `*/${minutes} * * * *`;
}

/** Очереди job синхронизации сущностей (обрабатываются `SyncJobProcessor`). */
export const SYNC_ENTITY_QUEUES: readonly QueueName[] = [
  ...new Set([...Object.values(ENTITY_QUEUES).map((d) => d.queue), QUEUES.syncManual]),
];

/** Политика pg-boss `stately`: по одной job в состояниях queued и active на ключ (`singletonKey` = сущность). */
export const SYNC_QUEUE_POLICY = 'stately';

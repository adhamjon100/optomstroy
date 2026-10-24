import type pg from 'pg';
import type { Logger } from 'pino';
import type { AppConfig } from '../../common/config/app-config.js';
import type { SyncEntity } from '../../common/enums.js';
import { QUEUES } from '../../common/jobs/contracts/queues.js';
import { createOnecGateway } from '../../integrations/onec/onec-gateway.factory.js';
import { onecAdapters } from '../../integrations/onec/onec-adapters.js';
import type { OnecGateway } from '../../integrations/onec/onec-gateway.js';
import type { ApplyRunTracker, ChangeItemHandler } from '../../sync/apply/apply.types.js';
import { CatalogApplier } from '../../sync/apply/catalog-applier.js';
import { CATALOG_LOAD_ENTITIES, CatalogFullLoadService } from '../../sync/apply/catalog-full-load.service.js';
import type { CatalogFullSource } from '../../sync/apply/catalog-source.js';
import { OnecChangesService } from '../../sync/apply/onec-changes.service.js';
import { RegistryRunTracker } from '../../sync/apply/run-tracker.js';
import { createCatalogFullSource } from '../../sync/apply/sync-apply.module.js';
import { type SyncAlertOptions, SyncAlertService } from '../../sync/alerts/sync-alerts.service.js';
import { ProductImageFilesHandler } from '../../sync/images/image-files.handler.js';
// RM-G-002, RM-G-003 (агент G-be-credit): снимки долга `sync.receivables` и правила скидок `Catalog_СкидкиНаценки`.
import { DiscountRulesChangeHandler } from '../../sync/discounts/discount-rules.change-handler.js';
import { ReceivablesSyncHandler } from '../../sync/receivables/receivables-sync.handler.js';
// RM-G-005 (агент G-be-txn-returns): документы «Возврат товаров от клиента» (`return_docs`) → `refund`, `completed`.
import { ReturnDocsChangeHandler } from '../../returns/onec/return-docs.handler.js';
// RM-G-001 (агент G-be-customers): клиенты (`Catalog_Партнеры`/`Контрагенты`/`СоглашенияСКлиентами`) и история продаж
// (`Document_РеализацияТоваровУслуг` → `shipments`, глубина SALES_HISTORY_MONTHS).
import { CustomersChangeHandler } from '../../sync/customers/customers-change.handler.js';
import { ImageStore } from '../../sync/images/image-store.js';
import { ImageSyncHandler } from '../../sync/images/image-sync.handler.js';
import { ImageSyncService } from '../../sync/images/image-sync.service.js';
import { ImagesGcService } from '../../sync/images/images-gc.service.js';
import { createImageBytesSource, createImageListSource } from '../../sync/images/images.module.js';
import { CountCheckService } from '../../sync/reconcile/count-check.service.js';
import type { SchedulerConfig } from '../../sync/scheduler/scheduler.config.js';
import { ENTITY_QUEUES, IMAGES_GC_QUEUE } from '../../sync/scheduler/sync-queues.js';
import {
  type RunFinishedEvent,
  SyncRunRegistry,
  type SyncStateDefaults,
} from '../../sync/scheduler/sync-run.registry.js';
import { PgBossCatalogChangePublisher } from '../../sync/apply/catalog-change-publisher.js';
// Разбор расхождений пп. 8, 68, 69, 89: заказы, QR и отложенные платёжные документы `/changes`; пауза после 401/403.
import { type ChangeJobPublisher, PgBossChangeJobPublisher } from '../../sync/apply/change-job-publisher.js';
import { CustomerOrderChangeHandler } from '../../sync/apply/customer-order.change-handler.js';
import { DeferredDocumentsHandler } from '../../sync/apply/deferred-documents.handler.js';
import { QrPaymentStatusChangeHandler } from '../../sync/apply/qr-payment-status.handler.js';
import { OnecAuthPause } from '../../sync/alerts/onec-auth-pause.js';
import { ensurePaymentsQueues } from '../payments/payments-jobs.js';
import { CatalogSyncHandler } from './catalog-sync.handler.js';
import { ChangesSyncHandler } from './changes-sync.handler.js';
import type { SyncEntityHandler } from './sync-handler.js';
import { countCheckJob, imagesGcJob, onecChangesJob, type SyncQueueJob } from './sync-jobs.js';

export interface SyncWorkerWiringOptions {
  readonly config: AppConfig;
  readonly pool: pg.Pool;
  readonly log: Logger;
  /** Параметры планировщика (cron по умолчанию для строки `sync_state`, порог потерянного прогона). */
  readonly scheduler?: Pick<SchedulerConfig, 'cron' | 'staleRunSeconds'>;
  /** Шлюз 1С; по умолчанию — `createOnecGateway(config, onecAdapters(config))` по `ONEC_MODE`. */
  readonly gateway?: OnecGateway;
  /** Источник полной загрузки/срезов; `undefined` — `createCatalogFullSource`, `null` — нет источника. */
  readonly source?: CatalogFullSource | null;
  /**
   * Обработчик фото (RM-E-003). `undefined` — `ImageSyncHandler` над `ImageSyncService` (байты — HS расширения или
   * фейк по `ONEC_MODE`, хранилище `MEDIA_DIR`, список файлов — OData, если настроен); `null` — заглушка worker'а.
   */
  readonly images?: SyncEntityHandler | null;
  /**
   * Обработчики не-каталожных элементов `/changes` (клиенты G, документы F). По умолчанию — файлы картинок
   * `Catalog_НоменклатураПрисоединенныеФайлы` (`ProductImageFilesHandler`, RM-E-003; EQ-ONEC-12) и правила скидок
   * `Catalog_СкидкиНаценки` (`DiscountRulesChangeHandler`, RM-G-003).
   */
  readonly changeHandlers?: readonly ChangeItemHandler[];
  /** Прочие обработчики сущностей (`order_status` — этап F, `customers`… — этап G); иначе — заглушка. */
  readonly handlers?: Partial<Record<SyncEntity, SyncEntityHandler>>;
  readonly alerts?: SyncAlertOptions;
}

export interface SyncWorkerWiring {
  /** Для `WorkerRuntimeOptions.handlers`. */
  readonly handlers: Partial<Record<SyncEntity, SyncEntityHandler>>;
  /** Для `WorkerRuntimeOptions.jobs`: `onec.changes`, `sync.count_check`, `images.gc`. */
  readonly jobs: Partial<Record<string, SyncQueueJob>>;
  /** Для `WorkerRuntimeOptions.onRunFinished` (алерты `consecutive_errors`). */
  readonly onRunFinished: (e: RunFinishedEvent) => Promise<void>;
  readonly alerts: SyncAlertService;
  readonly registry: SyncRunRegistry;
  readonly countCheck: CountCheckService;
  readonly changes: OnecChangesService | undefined;
  /** Публикатор `catalog.prices-changed|stock-changed`: `attach(boss)` после старта pg-boss. */
  readonly catalogChanges: PgBossCatalogChangePublisher;
  /**
   * Публикатор задач модулям-владельцам из транзакции сообщения (`payments.onec-qr-status`,
   * `orders.onec-status-changed`): `attach(boss)` после старта pg-boss; до него сообщения с такими элементами не
   * подтверждаются (повтор следующим циклом).
   */
  readonly changeJobs: PgBossChangeJobPublisher;
  /** Пауза чтения после 401/403 (05 §6.5). */
  readonly authPause: OnecAuthPause;
  readonly source: CatalogFullSource | null;
  readonly gateway: OnecGateway | undefined;
}

/**
 * Сборка обработчиков синхронизации для `pos-worker` (RM-E-002) без Nest: шлюз 1С по `ONEC_MODE`, конвейер apply
 * (RM-E-001), обработчики сущностей каталога, цикл `onec.changes` (режим расширения), сверка `$count` и алерты
 * `sync_error`. Ошибка конфигурации шлюза (нет `ONEC_BASE_URL` и т. п.) не роняет worker: обработчики каталога
 * работают как заглушки, а `onec.changes` падает с текстом ошибки конфигурации (видно в `sync_runs`/журнале).
 */
export function createSyncWorkerWiring(o: SyncWorkerWiringOptions): SyncWorkerWiring {
  const log = o.log.child({ component: 'sync' });
  let gateway: OnecGateway | undefined = o.gateway;
  let gatewayError: Error | undefined;
  if (!gateway) {
    try {
      gateway = createOnecGateway(o.config, onecAdapters(o.config));
    } catch (e) {
      gatewayError = e instanceof Error ? e : new Error(String(e));
      log.error(
        { err: gatewayError, onecMode: o.config.ONEC_MODE },
        'sync.wiring.gateway_unavailable: шлюз 1С не создан',
      );
    }
  }
  const source = o.source !== undefined ? o.source : gateway ? createCatalogFullSource(o.config, gateway) : null;
  const alerts = new SyncAlertService(o.pool, log.child({ component: 'sync.alerts' }), {
    unreachableMinutes: o.config.SYNC_ALERT_UNREACHABLE_MIN,
    ...o.alerts,
  });
  const onRunFinished = (e: RunFinishedEvent) =>
    alerts.onRunFinished(e).catch((err: unknown) => log.error({ err, entity: e.entity }, 'sync.alert.failed'));
  const cron = o.scheduler?.cron;
  const stateDefaults: SyncStateDefaults = (entity) => ({
    scheduleCron: cron ? cron[ENTITY_QUEUES[entity].cron] : o.config.SYNC_MASTER_CRON,
    maxAgeWarningSec: 3600,
  });
  const registry = new SyncRunRegistry(o.pool, o.scheduler?.staleRunSeconds ?? 3600, stateDefaults, {
    onFinished: onRunFinished,
  });
  const tracker = new RegistryRunTracker(registry, o.pool);
  const applier = new CatalogApplier();
  const applyLog = log.child({ component: 'sync.apply' });
  const gw = gateway;
  // Очередь `payments.onec-qr-status` создаёт модуль payments; здесь — идемпотентно до первой публикации.
  const changeJobs = new PgBossChangeJobPublisher((boss) => ensurePaymentsQueues(boss));
  const authPause = new OnecAuthPause(o.pool, { alerts, log: applyLog });
  const changeHandlers =
    o.changeHandlers ??
    defaultChangeHandlers({ salesHistoryMonths: o.config.SALES_HISTORY_MONTHS, publisher: changeJobs, log: applyLog });
  // 05 SYNC-070: изменения цен/остатков → задачи `catalog.*-changed` корзинам (pg-boss подключается при старте
  // WorkerRuntime: `catalogChanges.attach(boss)`; ревью F-trace-3).
  const catalogChanges = new PgBossCatalogChangePublisher(applyLog);
  const changesFor = gw
    ? (t: ApplyRunTracker) =>
        new OnecChangesService(o.pool, gw, applier, t, applyLog, {
          pageSize: o.config.ONEC_SYNC_PAGE_SIZE,
          handlers: changeHandlers,
          ...(source ? { slices: source } : {}),
          catalogChanges,
          authPause,
        })
    : undefined;
  const changes = changesFor?.(tracker);
  const fullLoad = new CatalogFullLoadService(o.pool, applier, tracker, applyLog, () => new Date(), catalogChanges);
  const plan = changesFor ? new ChangesSyncHandler(o.pool, tracker, changesFor, () => alerts.sweep()) : undefined;
  const catalog = new CatalogSyncHandler(o.config.ONEC_MODE, fullLoad, source, plan);

  const handlers: Partial<Record<SyncEntity, SyncEntityHandler>> = { ...o.handlers };
  for (const e of CATALOG_LOAD_ENTITIES) handlers[e] ??= catalog;
  const images = o.images !== undefined ? o.images : gw ? createImagesHandler(o, gw, tracker, log) : null;
  if (images) handlers.images = images;
  // RM-G-001: `sync.customers` / `sync.sales_history` по расписанию — цикл плана обмена (как справочники каталога в
  // режиме расширения; ядро §22.8). В `odata_only` загрузчика клиентов нет — заглушка worker'а.
  if (plan && o.config.ONEC_MODE !== 'odata_only') {
    handlers.customers ??= plan;
    handlers.sales_history ??= plan;
  }
  // 05 SYNC-016: снимок долга активных клиентов (опрос среза и в режиме расширения — EXTENSION_POLLED_ENTITIES).
  if (gw) {
    handlers.receivables ??= new ReceivablesSyncHandler(o.pool, gw, {
      concurrency: Math.min(2, o.config.ONEC_MAX_CONCURRENCY),
      inboundMode: o.config.ONEC_INBOUND_ENABLED,
    });
  }

  const countCheck = new CountCheckService(o.pool, registry, source, log, alerts);
  const jobs: Partial<Record<string, SyncQueueJob>> = {
    [QUEUES.syncCountCheck]: countCheckJob(o.config.ONEC_MODE, countCheck, log),
    [QUEUES.onecChanges]: changes
      ? onecChangesJob(changes, alerts, log)
      : () => Promise.reject(gatewayError ?? new Error('onec.changes: шлюз 1С не настроен')),
    // EQ-IMG-10: очистка осиротевших файлов фото (`MEDIA_DIR`), не зависит от шлюза 1С.
    [IMAGES_GC_QUEUE]: imagesGcJob(
      new ImagesGcService(o.pool, new ImageStore(o.config.MEDIA_DIR), log.child({ component: 'images.gc' })),
    ),
  };
  return {
    handlers,
    jobs,
    onRunFinished,
    alerts,
    registry,
    countCheck,
    changes,
    catalogChanges,
    changeJobs,
    authPause,
    source,
    gateway,
  };
}

/**
 * Обработчики всех не-каталожных типов состава плана обмена (05 §6.2 уточнение п. 3: до `ONEC_MODE=extension` на
 * проде подключены обработчики всех типов состава; ядро §22.8): файлы картинок, скидки, возвраты, клиенты и
 * реализации, заказы клиентов, события QR; ПКО и поступления — осознанно отложены до Q-012 (`deferred`).
 */
export function defaultChangeHandlers(o: {
  readonly salesHistoryMonths: number;
  readonly publisher: ChangeJobPublisher;
  readonly log?: Logger;
}): ChangeItemHandler[] {
  return [
    new ProductImageFilesHandler(),
    new DiscountRulesChangeHandler(),
    new ReturnDocsChangeHandler(),
    new CustomersChangeHandler({ salesHistoryMonths: o.salesHistoryMonths }),
    new CustomerOrderChangeHandler(o.publisher, o.log),
    new QrPaymentStatusChangeHandler(o.publisher),
    new DeferredDocumentsHandler(o.log),
  ];
}

/**
 * Ежесуточный прогон фото `images` (RM-E-003; D-30; 05 SYNC-035/036): байты — `GET /pos/v1/images/{ref}` расширения
 * или фейк (`fixtures`), в `odata_only` источника байтов нет (фото — разовой выгрузкой, `import-images.cli`); список
 * файлов — OData, если заданы `ONEC_BASE_URL`/`ONEC_USER_FILE`. Прогон `sync_runs` создаёт `SyncJobProcessor`.
 */
function createImagesHandler(
  o: SyncWorkerWiringOptions,
  gateway: OnecGateway,
  tracker: ApplyRunTracker,
  log: Logger,
): SyncEntityHandler {
  const service = new ImageSyncService(
    o.pool,
    createImageBytesSource(gateway),
    new ImageStore(o.config.MEDIA_DIR),
    tracker,
    log.child({ component: 'sync.images' }),
    { concurrency: Math.min(2, o.config.ONEC_MAX_CONCURRENCY) },
  );
  return new ImageSyncHandler(service, createImageListSource(o.config));
}

import { hostname } from 'node:os';
import { type ConstructorOptions, PgBoss } from 'pg-boss';
import type pg from 'pg';
import type { Logger } from 'pino';
import { SYNC_ENTITY_VALUES, type SyncEntity } from '../common/enums.js';
import { QUEUES } from '../common/jobs/contracts/queues.js';
import { PG_BOSS_SCHEMA } from '../common/jobs/pg-boss.service.js';
import type { SchedulerConfig } from '../sync/scheduler/scheduler.config.js';
import { ScheduleResolver, type SettingsSource } from '../sync/scheduler/schedule-resolver.js';
import { IMAGES_GC_QUEUE, SYNC_ENTITY_QUEUES, type SyncJobPayload } from '../sync/scheduler/sync-queues.js';
import { type RunFinishedEvent, SyncRunRegistry } from '../sync/scheduler/sync-run.registry.js';
import { SyncRunRequester } from '../sync/scheduler/sync-run.requester.js';
import { SyncScheduler } from '../sync/scheduler/sync-scheduler.js';
import { NotConfiguredOutboxDelivery, type OutboxDeliveryPort } from './outbox/outbox-delivery.port.js';
import { OutboxDispatcher, type OutboxDispatcherHooks } from './outbox/outbox-dispatcher.js';
import { stubJob } from './stub-handlers.js';
import { StubSyncHandler, type SyncEntityHandler } from './sync/sync-handler.js';
import { SyncJobProcessor } from './sync/sync-job.processor.js';

export interface WorkerRuntimeOptions {
  /** `WORKERS_ENABLED` (R0 §17.7, 16 §4.3): `false` — процесс не исполняет обработчики и расписания. */
  readonly enabled: boolean;
  readonly connectionString: string;
  readonly pool: pg.Pool;
  readonly settings: SettingsSource;
  readonly scheduler: SchedulerConfig;
  readonly log: Logger;
  /** Обработчики сущностей (этап E/F); по умолчанию — заглушки. */
  readonly handlers?: Partial<Record<SyncEntity, SyncEntityHandler>>;
  /** Канал записи в 1С для outbox (этап E/F); по умолчанию — не подключён. */
  readonly outboxDelivery?: OutboxDeliveryPort;
  /** Хуки владельцев агрегатов после перехода строки outbox (этап F: `dead` → уведомления). */
  readonly outboxHooks?: OutboxDispatcherHooks;
  readonly workerId?: string;
  /** Дополнительные опции pg-boss (тесты: интервалы обслуживания). */
  readonly bossOptions?: Partial<ConstructorOptions>;
  /**
   * Регистрация обработчиков других модулей после `boss.start()` (этап D: SMS-контур `SmsRuntime.register` —
   * `sms.send`, `sms.dlr_poll`, `sms.balance_poll`, RM-D-002).
   */
  readonly extraWorkers?: readonly ((boss: PgBoss) => Promise<void>)[];
  /**
   * Обработчики очередей вместо заглушек этапа C (RM-E-002: `onec.changes`, `sync.count_check` —
   * `createSyncWorkerWiring().jobs`). Результат возвращается в pg-boss как output job.
   */
  readonly jobs?: Partial<Record<string, (job: { readonly id: string; readonly data: unknown }) => Promise<unknown>>>;
  /** Итог прогона сущности (алерты `consecutive_errors ≥ 3`, SYNC-038 — `createSyncWorkerWiring().onRunFinished`). */
  readonly onRunFinished?: (e: RunFinishedEvent) => Promise<void>;
}

/**
 * Процесс `pos-worker` (06 §7.5, D-44, D-45): pg-boss в PostgreSQL без Redis — очереди `sync.*`, `onec.changes`,
 * `outbox.*`, расписания (`schedule: true`) и обслуживание (`supervise: true`) включены только здесь.
 */
export class WorkerRuntime {
  private bossInstance: PgBoss | undefined;
  private ticker: NodeJS.Timeout | undefined;
  private schedulerInstance: SyncScheduler | undefined;
  readonly registry: SyncRunRegistry;
  readonly dispatcher: OutboxDispatcher;
  readonly workerId: string;
  private readonly resolver: ScheduleResolver;
  private readonly delivery: OutboxDeliveryPort;
  private requesterInstance: SyncRunRequester | undefined;
  private started = false;

  constructor(private readonly o: WorkerRuntimeOptions) {
    this.workerId = o.workerId ?? `${hostname()}:${process.pid}`;
    this.resolver = new ScheduleResolver(o.scheduler, o.settings, (r) =>
      o.log.warn(
        { key: r.key, reason: r.reason },
        'scheduler.setting_invalid: значение app_settings проигнорировано, действует env',
      ),
    );
    this.registry = new SyncRunRegistry(
      o.pool,
      o.scheduler.staleRunSeconds,
      (entity) => ({ scheduleCron: this.resolver.envCron(entity), maxAgeWarningSec: 3600 }),
      o.onRunFinished ? { onFinished: o.onRunFinished } : {},
    );
    this.delivery = o.outboxDelivery ?? new NotConfiguredOutboxDelivery();
    // Публикация `<aggregate>.onec-*` идёт через экземпляр pg-boss, созданный в start().
    this.dispatcher = new OutboxDispatcher(
      o.pool,
      this.delivery,
      { send: (name, data, options) => this.boss.send(name, data, options) },
      o.scheduler.outbox,
      this.workerId,
      o.log.child({ component: 'outbox' }),
      o.outboxHooks ?? {},
    );
  }

  get boss(): PgBoss {
    if (!this.bossInstance) throw new Error('WorkerRuntime не запущен');
    return this.bossInstance;
  }

  get scheduler(): SyncScheduler {
    if (!this.schedulerInstance) throw new Error('WorkerRuntime не запущен');
    return this.schedulerInstance;
  }

  /** Ручной запуск прогона (основа `POST /sync/runs`, RM-E-002). */
  get requester(): SyncRunRequester {
    this.requesterInstance ??= new SyncRunRequester(this.registry, this.boss);
    return this.requesterInstance;
  }

  /** Возвращает `false`, если обработчики выключены флагом `WORKERS_ENABLED=false`. */
  async start(): Promise<boolean> {
    const { log } = this.o;
    if (!this.o.enabled) {
      log.warn('worker.disabled: WORKERS_ENABLED=false — обработчики и расписания pg-boss не запускаются');
      return false;
    }
    if (this.started) return true;
    const boss = new PgBoss({
      connectionString: this.o.connectionString,
      schema: PG_BOSS_SCHEMA,
      application_name: 'pos-worker:pg-boss',
      supervise: true,
      schedule: true,
      max: 5,
      ...this.o.bossOptions,
    });
    boss.on('error', (err: unknown) => log.error({ err }, 'pg-boss.error'));
    boss.on('warning', (w: unknown) => log.warn({ warning: w }, 'pg-boss.warning'));
    await boss.start();
    this.bossInstance = boss;
    const scheduler = new SyncScheduler(
      boss,
      this.o.pool,
      this.o.scheduler,
      this.resolver,
      log.child({ component: 'scheduler' }),
    );
    this.schedulerInstance = scheduler;
    await scheduler.ensureQueues();
    await this.registerWorkers(boss);
    for (const register of this.o.extraWorkers ?? []) await register(boss);
    await scheduler.apply();
    scheduler.startRefresh();
    if (this.delivery.configured) {
      this.ticker = setInterval(() => {
        boss.send(QUEUES.outboxDispatch, {}).catch((err: unknown) => log.error({ err }, 'outbox.tick.send_failed'));
      }, this.o.scheduler.outbox.tickMs);
      this.ticker.unref();
    } else {
      log.info('outbox.dispatch: канал записи в 1С не подключён — тикер outbox не запускается (этап E/F)');
    }
    this.started = true;
    log.info(
      { workerId: this.workerId, onecMode: this.o.scheduler.onecMode, tz: this.o.scheduler.timezone },
      'worker.started',
    );
    return true;
  }

  async stop(): Promise<void> {
    this.schedulerInstance?.stop();
    if (this.ticker) clearInterval(this.ticker);
    this.ticker = undefined;
    if (this.bossInstance) await this.bossInstance.stop({ graceful: true, timeout: 10_000 }).catch(() => undefined);
    this.bossInstance = undefined;
    this.started = false;
    this.o.log.info('worker.stopped');
  }

  private async registerWorkers(boss: PgBoss): Promise<void> {
    const { log, scheduler: cfg } = this.o;
    const stub = new StubSyncHandler();
    const processor = new SyncJobProcessor(
      this.registry,
      (entity) => this.o.handlers?.[entity] ?? stub,
      this.o.pool,
      log.child({ component: 'sync' }),
    );
    const poll = { pollingIntervalSeconds: cfg.pollingIntervalSeconds, batchSize: 1 };

    for (const queue of SYNC_ENTITY_QUEUES) {
      await boss.work(queue, { ...poll, includeMetadata: true }, async ([job]) => {
        if (!job) return undefined;
        return processor.process({ id: job.id, retryCount: job.retryCount, retryLimit: job.retryLimit }, job.data);
      });
    }
    // Еженедельная сверка (05 §7.3: `reconcile` по всем сущностям): прогон `mode=reconcile` по каждой сущности.
    await boss.work(QUEUES.syncReconcile, { ...poll, includeMetadata: true }, async ([job]) => {
      if (!job) return undefined;
      const outcomes: Record<string, string> = {};
      for (const entity of SYNC_ENTITY_VALUES) {
        const r = await processor.process({ id: job.id, retryCount: job.retryCount, retryLimit: job.retryLimit }, {
          entity,
          mode: 'reconcile',
          trigger: 'schedule',
        } satisfies SyncJobPayload);
        outcomes[entity] = r.status;
      }
      return outcomes;
    });
    const stubs: [string, string][] = [
      [QUEUES.syncCountCheck, 'RM-E-002'],
      [QUEUES.syncPostVacuum, 'RM-E-005'],
      [QUEUES.onecChanges, 'RM-E-001/RM-E-002'],
      [QUEUES.outboxReconcileAggregates, 'этап F'],
      [IMAGES_GC_QUEUE, 'EQ-IMG-10 (обработчик — createSyncWorkerWiring().jobs)'],
    ];
    for (const [queue, stage] of stubs) {
      const custom = this.o.jobs?.[queue];
      if (custom) {
        await boss.work(queue, poll, async ([job]) => (job ? custom({ id: job.id, data: job.data }) : undefined));
        continue;
      }
      const h = stubJob(log.child({ component: 'jobs' }), queue, stage);
      await boss.work(queue, poll, async ([job]) => {
        if (job) await h(job.data, job.id);
      });
    }
    await boss.work(QUEUES.outboxDispatch, poll, async () => this.dispatcher.tick());
    await boss.work(QUEUES.outboxUnlock, poll, async () => ({ unlocked: await this.dispatcher.unlockExpired() }));
  }
}

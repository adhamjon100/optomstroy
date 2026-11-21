import { Inject, Injectable, Logger, type OnApplicationBootstrap, Optional } from '@nestjs/common';
import type { PgBoss } from 'pg-boss';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { type OnecConfirmedPayload, type OnecFailedPayload, QUEUES } from '../../common/jobs/contracts/queues.js';
import { PgBossService } from '../../common/jobs/pg-boss.service.js';
import type { SyncEntityHandler, SyncHandlerResult, SyncRunContext } from '../../jobs/sync/sync-handler.js';
import { OrdersRetentionService } from '../../orders/orders-retention.service.js';
import { HelloKeysRepository } from '../../users/hello-keys.repository.js';
import { ReturnsRetentionService } from '../returns-retention.service.js';
import { ReturnsOnecService } from './returns-onec.service.js';

const DAY = 86_400;

/** Параметры очередей результата outbox — как у `queueSpecs` планировщика (src/sync/scheduler/queue-specs.ts). */
const RESULT_QUEUE_OPTIONS = {
  policy: 'standard',
  retryLimit: 1000,
  retryBackoff: true,
  retryDelay: 30,
  retryDelayMax: 3600,
  retentionSeconds: 30 * DAY,
} as const;

/** `retention.daily` — singleton, без длинных повторов (повтор — следующие сутки). */
const RETENTION_QUEUE_OPTIONS = { policy: 'singleton', retryLimit: 3, retryDelay: 300, expireInSeconds: 3600 } as const;

async function ensureQueue(
  boss: PgBoss,
  name: string,
  options: Parameters<PgBoss['createQueue']>[1] = RESULT_QUEUE_OPTIONS,
): Promise<void> {
  if (await boss.getQueue(name)) return;
  try {
    await boss.createQueue(name, options);
  } catch (e) {
    // Гонка двух процессов (планировщик pos-worker создаёт те же очереди) — не ошибка.
    if (!(await boss.getQueue(name))) throw e;
  }
}

/**
 * Связь модуля `returns` с pg-boss (06 §7.5, §7.4 п. (б)): обработчики `returns.onec-confirmed` /
 * `returns.onec-failed` (событие результата доставки outbox `return_request`) регистрируются только при
 * `WORKERS_ENABLED=true` (pos-worker; pos-api в минимальной конфигурации без воркера) — как `PaymentsJobsBridge`.
 * Без pg-boss (тесты `jobs: false`) ничего не делает: результаты применяются вызовом `ReturnsOnecService`.
 *
 * Очередь `retention.daily` (03:30 Asia/Bishkek, singleton) регистрирует только этот мост — **один** `boss.work`
 * (второй обработчик той же очереди делил бы задания pg-boss между собой): `runDaily` — общий реестр задач сроков
 * хранения (07 §13.3 «общим реестром задач в одном job»; 06 MOD-024 — очистку выполняет обработчик модуля-владельца):
 * черновики заявок на возврат (`returns`) и маскирование номера покупателя в заявках с планшета (`orders`,
 * `OrdersRetentionService`, задача TAB-1-10; ADR-115) — экспорт `OrdersModule`, внедряется конструктором (06 MOD-024:
 * взаимодействие только через экспортируемые сервисы). Импорт `returns → orders` — только этот обработчик ретенции
 * (`orders` модуль `returns` не импортирует, цикла нет — `npm run madge`). Ключи Windows Hello (`hello_keys`, 07 §13.3;
 * ADR-116): истёкший challenge и отозванные старше 90 дней — `HelloKeysRepository` глобального `UsersModule`.
 */
@Injectable()
export class ReturnsJobsBridge implements OnApplicationBootstrap {
  private readonly logger = new Logger('returns.jobs');

  /**
   * `ordersRetention` — задача модуля `orders` (экспорт `OrdersModule`); нет — только задача возвратов (модульные
   * тесты моста без контекста Nest).
   */
  constructor(
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'WORKERS_ENABLED'>,
    private readonly onec: ReturnsOnecService,
    private readonly retention: ReturnsRetentionService,
    @Optional() private readonly boss?: PgBossService,
    @Optional() private readonly ordersRetention?: OrdersRetentionService,
    @Optional() private readonly helloKeys?: HelloKeysRepository,
  ) {}

  /**
   * Один запуск `retention.daily`: задачи выполняются по очереди, сбой одной не отменяет другие (каждая идемпотентна);
   * после всех — первая ошибка пробрасывается, и pg-boss повторяет задание (`retryLimit` 3). Итог — счётчики задач
   * (`deleted` — черновики возвратов, `masked` — номера в заявках с планшета, `helloChallenges` и `helloKeys` — очищенные
   * challenge и удалённые отозванные ключи Windows Hello), без ПДн.
   */
  async runDaily(): Promise<Record<string, number>> {
    const orders = this.ordersRetention;
    const keys = this.helloKeys;
    const tasks: { readonly name: string; readonly run: () => Promise<Record<string, number>> }[] = [
      { name: 'returns.drafts', run: () => this.retention.purgeExpiredDrafts() },
      ...(orders ? [{ name: 'orders.kiosk_receiver_phone', run: () => orders.maskKioskReceiverPhones() }] : []),
      ...(keys
        ? [
            {
              name: 'auth.hello_keys',
              run: async () => {
                const r = await keys.purge();
                return { helloChallenges: r.challenges, helloKeys: r.keys };
              },
            },
          ]
        : []),
    ];
    const out: Record<string, number> = {};
    let failure: Error | null = null;
    for (const t of tasks) {
      try {
        Object.assign(out, await t.run());
      } catch (err) {
        failure ??= err instanceof Error ? err : new Error(`retention.daily: задача ${t.name} не выполнена`);
        this.logger.error({ err, task: t.name }, 'retention.daily.task_failed');
      }
    }
    if (failure !== null) throw failure;
    this.logger.log({ event: 'retention.daily', ...out });
    return out;
  }

  onApplicationBootstrap(): void {
    if (!this.boss || !this.config.WORKERS_ENABLED) return;
    void this.boss
      .start()
      .then(async () => {
        const boss = this.boss?.instance;
        if (!boss) return;
        await ensureQueue(boss, QUEUES.returnsOnecConfirmed);
        await ensureQueue(boss, QUEUES.returnsOnecFailed);
        const poll = { pollingIntervalSeconds: 2, batchSize: 1 }; // money-double: allow — секунды
        await boss.work<OnecConfirmedPayload>(QUEUES.returnsOnecConfirmed, poll, async ([job]) => {
          if (!job) return undefined;
          return { outcome: await this.onec.onConfirmed(job.data) };
        });
        await boss.work<OnecFailedPayload>(QUEUES.returnsOnecFailed, poll, async ([job]) => {
          if (!job) return undefined;
          return { outcome: await this.onec.onFailed(job.data) };
        });
        // Сроки хранения (06 §7.5 `retention.daily`, 03:30 Asia/Bishkek; 07 §13.3): черновики заявок старше 7 дней
        // и номер покупателя в заявках с планшета старше 90 дней — один обработчик очереди (runDaily).
        await ensureQueue(boss, QUEUES.retentionDaily, RETENTION_QUEUE_OPTIONS);
        await boss.work(QUEUES.retentionDaily, { pollingIntervalSeconds: 30, batchSize: 1 }, async () =>
          this.runDaily(),
        );
        await boss.schedule(
          QUEUES.retentionDaily,
          '30 3 * * *',
          {},
          { tz: 'Asia/Bishkek', singletonKey: QUEUES.retentionDaily },
        );
      })
      .catch((err: unknown) => this.logger.error({ err }, 'returns.jobs.register_failed'));
  }
}

/**
 * Прогон сущности `return_docs` (05 §7.3: вместе с `order_status` — каждые 5 мин; ядро §17.3): опрос статусов открытых
 * заявок, переданных в 1С (`GET /pos/v1/returns/{uuid}/status`, ONEC-067). Документы «Возврат товаров от клиента»
 * приходят планом обмена `/changes` (`ReturnDocsChangeHandler`). Регистрация — `WorkerRuntimeOptions.handlers`.
 */
@Injectable()
export class ReturnsStatusSyncHandler implements SyncEntityHandler {
  constructor(private readonly onec: ReturnsOnecService) {}

  async run(ctx: SyncRunContext): Promise<SyncHandlerResult> {
    const r = await this.onec.pollOpen();
    ctx.log.info({ entity: ctx.entity, ...r }, 'returns.status_poll');
    return { implemented: true, status: r.failed > 0 ? 'partial' : 'success', counts: r };
  }
}

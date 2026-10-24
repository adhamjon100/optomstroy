import {
  Inject,
  Injectable,
  Logger,
  type OnApplicationBootstrap,
  type OnApplicationShutdown,
  Optional,
} from '@nestjs/common';
import type { PgBoss } from 'pg-boss';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { type OnecConfirmedPayload, type OnecFailedPayload, QUEUES } from '../../common/jobs/contracts/queues.js';
import { PgBossService } from '../../common/jobs/pg-boss.service.js';
import type { PosDatabase } from '../../db/database.js';
import { CustomerOnecResultsHandler } from './customer-onec-results.handler.js';

/** Параметры очередей результата outbox (как `queueSpecs`: без низкого лимита попыток, 07 §8.2). */
const RESULT_QUEUE_OPTIONS = {
  policy: 'standard',
  retryLimit: 1000,
  retryBackoff: true,
  retryDelay: 30,
  retryDelayMax: 3600,
  retentionSeconds: 30 * 86_400,
} as const;

const RECONCILE_EVERY_MS = 5 * 60_000;

/**
 * Связь модуля `customers` с pg-boss (06 §7.4 п. (б), §7.5): при `WORKERS_ENABLED=true` (pos-worker — контекст Nest
 * `AppModule`; pos-api в минимальной конфигурации) регистрирует обработчики `customers.onec-confirmed` и
 * `customers.onec-failed` (`CustomerOnecResultsHandler`) и раз в 5 минут — сверщик потерянных результатов клиента
 * (07 §8.2 `outbox.reconcile-aggregates`). Без pg-boss (тесты `jobs: false`) — ничего не делает.
 */
@Injectable()
export class CustomersJobsBridge implements OnApplicationBootstrap, OnApplicationShutdown {
  private readonly logger = new Logger('customers.jobs');
  readonly results: CustomerOnecResultsHandler;
  private timer: NodeJS.Timeout | undefined;

  constructor(
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'WORKERS_ENABLED'>,
    @Inject(DRIZZLE) db: PosDatabase,
    @Optional() private readonly boss?: PgBossService,
  ) {
    this.results = new CustomerOnecResultsHandler(db, {
      info: (o, m) => this.logger.log(o, m),
      warn: (o, m) => this.logger.warn(o, m),
    });
  }

  onApplicationBootstrap(): void {
    if (!this.boss || !this.config.WORKERS_ENABLED) return;
    void this.boss
      .start()
      .then(async () => {
        const instance = this.boss?.instance;
        if (!instance) return;
        await this.register(instance);
        this.timer = setInterval(() => {
          this.results.reconcile().catch((err: unknown) => this.logger.warn({ err }, 'customers.reconcile.failed'));
        }, RECONCILE_EVERY_MS);
        this.timer.unref();
      })
      .catch((err: unknown) => this.logger.error({ err }, 'customers.jobs.register_failed'));
  }

  onApplicationShutdown(): void {
    if (this.timer) clearInterval(this.timer);
  }

  private async register(boss: PgBoss): Promise<void> {
    for (const name of [QUEUES.customersOnecConfirmed, QUEUES.customersOnecFailed]) {
      if (!(await boss.getQueue(name))) {
        try {
          await boss.createQueue(name, RESULT_QUEUE_OPTIONS);
        } catch (e) {
          if (!(await boss.getQueue(name))) throw e;
        }
      }
    }
    const work = { pollingIntervalSeconds: 2, batchSize: 1 }; // money-double: allow — секунды опроса
    await boss.work<OnecConfirmedPayload>(QUEUES.customersOnecConfirmed, work, async ([job]) =>
      job ? { outcome: await this.results.onConfirmed(job.data) } : undefined,
    );
    await boss.work<OnecFailedPayload>(QUEUES.customersOnecFailed, work, async ([job]) =>
      job ? { outcome: await this.results.onFailed(job.data) } : undefined,
    );
    this.logger.log(
      { queues: [QUEUES.customersOnecConfirmed, QUEUES.customersOnecFailed] },
      'customers.jobs.registered',
    );
  }
}

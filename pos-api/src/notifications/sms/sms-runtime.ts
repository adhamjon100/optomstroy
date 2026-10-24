import type pg from 'pg';
import type { PgBoss } from 'pg-boss';
import { type Clock, systemClock } from '../../common/auth/clock.js';
import type { AppConfig } from '../../common/config/app-config.js';
import { parseSecretRing, type SecretRing } from '../../common/crypto/index.js';
import { createDatabase, type PosDatabase } from '../../db/database.js';
import { createSmsGateway } from '../../integrations/sms/sms-gateway.factory.js';
import type { SmsGateway } from '../../integrations/sms/sms-gateway.js';
import type { SmsHttpTransport } from '../../integrations/sms/sms-http-transport.js';
import { createSmsTelemetry, type SmsLogger, type SmsTelemetry } from '../../integrations/sms/sms-telemetry.js';
import { SmsBalanceMonitor, type SmsBalanceSnapshot } from './sms-balance.monitor.js';
import type { SmsDeliveryListener } from './sms-delivery.listener.js';
import { SmsDlrService } from './sms-dlr.service.js';
import { PgBossSmsJobPublisher } from './sms-job-publisher.js';
import { SmsOutboxRepository } from './sms-outbox.repository.js';
import { SmsOutboxService } from './sms-outbox.service.js';
import { SMS_QUEUE_OPTIONS, SMS_QUEUES, type SmsDlrPollJob, type SmsSendJob } from './sms-queues.js';
import { SmsSendProcessor } from './sms-send.processor.js';
import { SmsTextSealer } from './sms-text-sealer.js';

export type SmsRuntimeConfig = Pick<
  AppConfig,
  | 'APP_ENV'
  | 'SMS_PROVIDER'
  | 'SMSPRO_BASE_URL'
  | 'SMSPRO_LOGIN'
  | 'SMSPRO_PASSWORD'
  | 'SMSPRO_SENDER'
  | 'SMSPRO_TEST_FLAG'
  | 'SMSPRO_TIMEOUT_MS'
  | 'SMSPRO_RETRY_MAX'
  | 'SMSPRO_CB_OPEN_MINUTES'
  | 'SMSPRO_DLR_MODE'
  | 'SMSPRO_BALANCE_POLL_MINUTES'
  | 'SMSPRO_BALANCE_ALERT_SOM'
  | 'OTP_HMAC_SECRET'
  | 'OTP_HMAC_SECRET_VERSION'
>;

export interface SmsRuntimeOptions {
  readonly config: SmsRuntimeConfig;
  readonly pool: pg.Pool;
  readonly logger: SmsLogger;
  readonly db?: PosDatabase;
  /** Набор секрета OTP (тот же, что у CryptoModule) — ключ шифрования текста в payload. */
  readonly otpSecretRing?: SecretRing;
  readonly telemetry?: SmsTelemetry;
  readonly gateway?: SmsGateway;
  readonly transport?: SmsHttpTransport;
  readonly listener?: SmsDeliveryListener;
  readonly clock?: Clock;
  readonly sleep?: (ms: number) => Promise<void>;
  /** Интервал опроса заданий pg-boss (тесты — 0.5 с). */
  readonly pollingIntervalSeconds?: number;
}

/** Cron из `SMSPRO_BALANCE_POLL_MINUTES` (5 полей). */
export function balancePollCron(minutes: number): string {
  if (minutes >= 1 && minutes < 60 && 60 % minutes === 0) return `*/${minutes} * * * *`;
  if (minutes >= 60 && minutes % 60 === 0 && 24 % (minutes / 60) === 0) return `0 */${minutes / 60} * * *`;
  return `*/${Math.min(Math.max(Math.round(minutes), 1), 59)} * * * *`;
}

/**
 * Сборка SMS-контура процесса вне Nest (pos-worker, RM-C-007) и регистрация обработчиков pg-boss:
 * `sms.send` → `SmsSendProcessor`, `sms.dlr_poll` → `SmsDlrService.poll`, `sms.balance_poll` →
 * `SmsBalanceMonitor.poll` (расписание `SMSPRO_BALANCE_POLL_MINUTES`). Подключение к `WorkerRuntime` —
 * `new SmsRuntime({...}).register(boss)` после `boss.start()` (владелец src/jobs, RM-C-007).
 */
export class SmsRuntime {
  readonly db: PosDatabase;
  readonly telemetry: SmsTelemetry;
  readonly gateway: SmsGateway;
  readonly repo: SmsOutboxRepository;
  readonly sealer: SmsTextSealer;
  readonly publisher: PgBossSmsJobPublisher;
  readonly outbox: SmsOutboxService;
  readonly processor: SmsSendProcessor;
  readonly dlr: SmsDlrService;
  readonly balance: SmsBalanceMonitor;
  private bossRef: PgBoss | undefined;

  constructor(private readonly o: SmsRuntimeOptions) {
    const c = o.config;
    const clock = o.clock ?? systemClock;
    this.db = o.db ?? createDatabase(o.pool);
    this.telemetry = o.telemetry ?? createSmsTelemetry(o.logger, () => clock.now().getTime());
    this.gateway =
      o.gateway ??
      createSmsGateway(c, {
        db: o.pool,
        telemetry: this.telemetry,
        ...(o.transport ? { transport: o.transport } : {}),
        now: () => clock.now().getTime(),
      });
    this.repo = new SmsOutboxRepository(this.db);
    this.sealer = new SmsTextSealer(
      o.otpSecretRing ?? parseSecretRing('OTP_HMAC_SECRET', c.OTP_HMAC_SECRET, c.OTP_HMAC_SECRET_VERSION, c.APP_ENV),
    );
    this.publisher = new PgBossSmsJobPublisher(() => this.bossRef);
    this.outbox = new SmsOutboxService({
      db: this.db,
      repo: this.repo,
      gateway: this.gateway,
      sealer: this.sealer,
      publisher: this.publisher,
      cbOpenMinutes: c.SMSPRO_CB_OPEN_MINUTES,
    });
    this.processor = new SmsSendProcessor({
      db: this.db,
      repo: this.repo,
      gateway: this.gateway,
      sealer: this.sealer,
      publisher: this.publisher,
      telemetry: this.telemetry,
      config: {
        sender: c.SMSPRO_SENDER ?? '',
        testFlag: c.SMSPRO_TEST_FLAG,
        retryMax: c.SMSPRO_RETRY_MAX,
        dlrMode: c.SMSPRO_DLR_MODE,
      },
      clock,
      ...(o.listener ? { listener: o.listener } : {}),
      ...(o.sleep ? { sleep: o.sleep } : {}),
    });
    this.dlr = new SmsDlrService({
      db: this.db,
      repo: this.repo,
      gateway: this.gateway,
      telemetry: this.telemetry,
      clock,
      ...(o.listener ? { listener: o.listener } : {}),
    });
    this.balance = new SmsBalanceMonitor({
      gateway: this.gateway,
      telemetry: this.telemetry,
      thresholdSom: c.SMSPRO_BALANCE_ALERT_SOM,
      db: this.db,
      clock,
    });
  }

  /** Подключает экземпляр pg-boss (публикация) без регистрации обработчиков (процесс API). */
  attach(boss: PgBoss): void {
    this.bossRef = boss;
  }

  /** Очереди, обработчики и расписание баланса (процесс pos-worker). */
  async register(boss: PgBoss): Promise<void> {
    this.bossRef = boss;
    for (const name of Object.values(SMS_QUEUES)) {
      if (!(await boss.getQueue(name))) await boss.createQueue(name, SMS_QUEUE_OPTIONS[name] ?? {});
    }
    const poll = { pollingIntervalSeconds: this.o.pollingIntervalSeconds ?? 2, batchSize: 1 };
    await boss.work<SmsSendJob>(SMS_QUEUES.send, poll, async ([job]) =>
      job ? this.processor.process(job.data) : undefined,
    );
    await boss.work<SmsDlrPollJob>(SMS_QUEUES.dlrPoll, poll, async ([job]) =>
      job ? this.dlr.poll(job.data) : undefined,
    );
    await boss.work<object, SmsBalanceSnapshot>(SMS_QUEUES.balancePoll, poll, async () => this.balance.poll());
    const cron = balancePollCron(this.o.config.SMSPRO_BALANCE_POLL_MINUTES);
    await boss.schedule(SMS_QUEUES.balancePoll, cron, {}, { key: 'default', singletonKey: 'sms.balance_poll' });
    this.o.logger.log({ event: 'sms.worker.registered', provider: this.gateway.provider, balanceCron: cron });
  }
}

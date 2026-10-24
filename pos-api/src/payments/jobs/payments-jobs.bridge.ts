import { Inject, Injectable, Logger, type OnApplicationBootstrap, Optional } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { PgBossService } from '../../common/jobs/pg-boss.service.js';
import { ensurePaymentsQueues, registerPaymentsJobs, schedulePaymentPoll } from '../../jobs/payments/payments-jobs.js';
import { bossExecutor } from '../infra/sql-executor.js';
import { QrStatusService } from '../qr/qr-status.service.js';

/**
 * Связь модуля `payments` с pg-boss (06 §7.5):
 * - публикация опроса QR у 1С (`payments.qr_onec_poll`) после выдачи QR и аннулирования QR-платежа — из любого
 *   процесса (pos-api публикует, исполняет процесс с `WORKERS_ENABLED=true`);
 * - регистрация обработчиков (`registerPaymentsJobs`, src/jobs/payments) — только при `WORKERS_ENABLED=true`
 *   (pos-worker, либо pos-api в минимальной конфигурации без отдельного воркера — 16 §4.3, Q-135).
 * Без pg-boss (тесты `jobs: false`) публикация пропускается: QR остаётся `qr_shown`, статус можно получить
 * `GET /payments/{id}?refreshStatus=true` или ручным подтверждением.
 */
@Injectable()
export class PaymentsJobsBridge implements OnApplicationBootstrap {
  private readonly logger = new Logger('payments.jobs');
  private queuesReady: Promise<void> | undefined;

  constructor(
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    private readonly qrStatus: QrStatusService,
    @Optional() private readonly boss?: PgBossService,
  ) {}

  onApplicationBootstrap(): void {
    if (!this.boss) return;
    void this.boss
      .start()
      .then(async () => {
        const instance = this.boss?.instance;
        if (!instance) return;
        await this.ensureQueues();
        if (!this.config.WORKERS_ENABLED) return;
        await registerPaymentsJobs(
          instance,
          {
            pollQr: (id) => this.qrStatus.pollOnce(id),
            expireDue: () => this.qrStatus.expireDue(),
            applyOnecQrStatus: (p) => this.qrStatus.applyOnecQrStatus(p),
            pollCandidates: () => this.qrStatus.pollCandidates(),
          },
          {
            pollingIntervalSeconds: Math.min(2, this.config.QR_ONEC_POLL_SECONDS), // money-double: allow — секунды
            log: {
              warn: (o, m) => this.logger.warn(o, m),
              info: (o, m) => this.logger.log(o, m),
            },
          },
        );
      })
      .catch((err: unknown) => this.logger.error({ err }, 'payments.jobs.register_failed'));
  }

  private ensureQueues(): Promise<void> {
    const instance = this.boss?.instance;
    if (!instance) return Promise.resolve();
    this.queuesReady ??= ensurePaymentsQueues(instance).catch((err: unknown) => {
      this.queuesReady = undefined;
      throw err;
    });
    return this.queuesReady;
  }

  /** Опрос QR через `delaySeconds` (по умолчанию — `QR_ONEC_POLL_SECONDS`); сбой публикации только журналируется. */
  async kickPoll(paymentId: string, delaySeconds = this.config.QR_ONEC_POLL_SECONDS): Promise<void> {
    const instance = this.boss?.instance;
    if (!instance) return;
    try {
      await this.ensureQueues();
      await schedulePaymentPoll(instance, paymentId, delaySeconds);
    } catch (err) {
      this.logger.warn({ err, paymentId }, 'payments.poll.kick_failed');
    }
  }

  /**
   * Задача опроса/отмены QR в транзакции вызывающего (отмена заказа — `voidOpenForOrderCancel`): публикуется
   * атомарно с аннулированием; без pg-boss — no-op.
   */
  async enqueuePollInTx(tx: DbExecutor, paymentId: string): Promise<void> {
    const instance = this.boss?.instance;
    if (!instance) return;
    await this.ensureQueues();
    await schedulePaymentPoll(instance, paymentId, 0, bossExecutor(tx));
  }
}

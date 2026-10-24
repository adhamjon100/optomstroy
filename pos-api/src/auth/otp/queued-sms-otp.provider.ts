import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock, systemClock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { SmsEnqueueError, SmsOutboxService } from '../../notifications/sms/sms-outbox.service.js';
import type { SmsDeliveryListener, SmsSendSettledEvent } from '../../notifications/sms/sms-delivery.listener.js';
import { OtpChallengesRepository } from './otp-challenges.repository.js';
import { releaseOtpPhoneQuota } from './otp-quota.js';
import type { OtpDeliveryTarget, OtpProvider, PreparedDelivery } from './otp.provider.js';

/**
 * Вариант `OtpProvider` через очередь pos-worker (RM-D-002, notifications/sms; 09 §6.8 «отправку выполняет
 * pos-worker», 06 §7.5; INT-01 — вариант по умолчанию в AppModule): `prepare` в транзакции выпуска кода вызывает
 * `SmsOutboxService.enqueue` — `sms_outbox(queued)` + задание `sms.send` с зашифрованным текстом (SMS-Q-02);
 * `dispatch` — ничего (отправляет воркер); `blocked()` — межпроцессный circuit-breaker по журналу
 * (`SmsOutboxService.availability`). Очередь недоступна (pg-boss процесса API не запущен) → нейтральный
 * 503 SMS_PROVIDER_ERROR: транзакция выпуска откатывается целиком, квоты лимитов не расходуются.
 */
@Injectable()
export class QueuedSmsOtpProvider implements OtpProvider {
  private readonly logger = new Logger('auth');

  constructor(
    private readonly outbox: SmsOutboxService,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
  ) {}

  async prepare(target: OtpDeliveryTarget, code: string, _at: Date, tx: DbExecutor): Promise<PreparedDelivery> {
    try {
      const q = await this.outbox.enqueue(
        {
          phone: target.phoneE164,
          templateKey: target.templateKey,
          text: this.config.SMS_OTP_TEMPLATE.replace('{code}', code),
          otpChallengeId: target.challengeId,
          ...(target.requestId ? { requestId: target.requestId } : {}),
        },
        tx,
      );
      return { smsOutboxId: q.id, transactionId: q.providerMessageId };
    } catch (err) {
      if (err instanceof SmsEnqueueError) throw err;
      this.logger.error(
        {
          event: 'otp.enqueue_failed',
          challengeId: target.challengeId,
          err: err instanceof Error ? err.name : 'unknown',
        },
        'otp.enqueue_failed',
      );
      throw new ProblemException('SMS_PROVIDER_ERROR', { detail: 'Не удалось отправить SMS. Попробуйте позже.' });
    }
  }

  dispatch(): void {
    // Отправку выполняет pos-worker (задание `sms.send` поставлено в prepare).
  }

  async drain(): Promise<void> {
    return Promise.resolve();
  }

  async blocked(): Promise<boolean> {
    return (await this.outbox.availability()).blocked;
  }
}

/**
 * Реализация порта `SMS_DELIVERY_LISTENER` (notifications/sms) владельцем OTP (09 §6.8): итог `failed` →
 * челлендж `failed_delivery` (если он ещё `sent`) и возврат квоты номера; `sent` — без изменений (предыдущий код
 * аннулирован при выпуске нового — D_spec_questions A-05). Вызывается в транзакции, обновляющей `sms_outbox`.
 * Без состояния и без OtpService: тот же класс собирается вне Nest в pos-worker (`createOtpDeliveryListener`,
 * src/jobs/otp), где выполняется задание `sms.send`.
 */
@Injectable()
export class OtpSmsDeliveryListener implements SmsDeliveryListener {
  private readonly logger = new Logger('auth');
  private readonly clock: Clock;

  constructor(
    private readonly challenges: OtpChallengesRepository,
    private readonly hmac: OtpHmacService,
    @Optional() @Inject(CLOCK) clock?: Clock,
  ) {
    this.clock = clock ?? systemClock;
  }

  async onSendSettled(event: SmsSendSettledEvent, tx: DbExecutor): Promise<void> {
    if (event.status !== 'failed' || !event.otpChallengeId) return;
    const ch = await this.challenges.findById(event.otpChallengeId, tx, true);
    if (!ch || ch.status !== 'sent' || ch.smsOutboxId !== event.smsOutboxId) return;
    await this.challenges.update(ch.id, { status: 'failed_delivery' }, this.clock.now(), tx);
    await releaseOtpPhoneQuota(tx, this.hmac, ch.phoneE164, ch.createdAt);
    this.logger.warn(
      { event: 'otp.failed_delivery', challengeId: ch.id, outcome: event.outcome ?? undefined },
      'otp.failed_delivery',
    );
  }
}

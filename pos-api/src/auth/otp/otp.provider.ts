import { Inject, Injectable, Logger, type OnApplicationShutdown, Optional } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { generateProviderMessageId } from '../../common/crypto/random.js';
import { maskPhone } from '../../common/logging/redaction.js';
import {
  SMS_GATEWAY,
  type SendOutcome,
  type SendResult,
  type SmsGateway,
  type SmsTemplateKey,
} from '../../integrations/sms/sms-gateway.js';
import { OtpChallengesRepository } from './otp-challenges.repository.js';
import { OtpCircuitBreaker } from './otp-circuit-breaker.js';
import { SmsOutboxRepository } from './sms-outbox.repository.js';

/**
 * Порт доставки OTP (D-47; 09 §6.8): `OtpService` генерирует код и хранит HMAC, доставку поручает `OtpProvider`.
 * R1 — `SmsOtpProvider` поверх `SmsGateway` (`SMS_PROVIDER=smspro|fake`); OTP API SMSPro — альтернатива (Q-242).
 *
 * Двухфазный контракт: `prepare` — в транзакции `/auth/otp/request` (запись `sms_outbox(queued)` вместе с
 * `otp_challenges`); `dispatch` — после COMMIT, в фоне (ответ 202 не ждёт вендора, 09 §4.2). Код передаётся
 * только в памяти: в `sms_outbox` нет полей `text`/`code` (09 §6.9), поэтому отправка выполняется процессом
 * pos-api, а не задачей pg-boss с кодом в payload (D_spec_questions A-04).
 */
export const OTP_PROVIDER = Symbol('OTP_PROVIDER');

export interface OtpDeliveryTarget {
  readonly challengeId: string;
  readonly phoneE164: string;
  readonly templateKey: SmsTemplateKey;
  readonly requestId?: string | null;
}

export interface PreparedDelivery {
  readonly smsOutboxId: string;
  readonly transactionId: string;
}

export interface DeliveryHooks {
  /** Итог `failed_delivery` (после ретраев): вызывающий освобождает квоту номера (09 §6.8). */
  readonly onFailed?: () => Promise<void>;
}

export interface OtpProvider {
  /**
   * В транзакции выпуска кода: журнал доставки (`sms_outbox(queued)`). Код передаётся для реализаций, которые
   * ставят отправку в очередь в этой же транзакции (QueuedSmsOtpProvider — текст шифруется в задании pg-boss).
   */
  prepare(target: OtpDeliveryTarget, code: string, at: Date, tx: DbExecutor): Promise<PreparedDelivery>;
  dispatch(prepared: PreparedDelivery, target: OtpDeliveryTarget, code: string, hooks?: DeliveryHooks): void;
  /** Канал заведомо недоступен (синхронный 503 SMS_PROVIDER_ERROR, 09 §6.8); по умолчанию — доступен. */
  blocked?(): Promise<boolean>;
  /** Ожидание завершения фоновых отправок (тесты, остановка процесса). */
  drain(): Promise<void>;
}

export interface OtpDeliveryOptions {
  /** Пауза перед повтором `RETRYABLE`, мс (растёт линейно с номером попытки). */
  readonly retryDelayMs: number;
}

export const OTP_DELIVERY_OPTIONS = Symbol('OTP_DELIVERY_OPTIONS');

const ACCEPTED: ReadonlySet<SendOutcome> = new Set<SendOutcome>(['ACCEPTED', 'ACCEPTED_TEST', 'DUPLICATE_ID']);

@Injectable()
export class SmsOtpProvider implements OtpProvider, OnApplicationShutdown {
  private readonly logger = new Logger('auth');
  private readonly inflight = new Set<Promise<void>>();
  private readonly retryDelayMs: number;

  constructor(
    @Inject(SMS_GATEWAY) private readonly gateway: SmsGateway,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly outbox: SmsOutboxRepository,
    private readonly challenges: OtpChallengesRepository,
    private readonly breaker: OtpCircuitBreaker,
    @Optional() @Inject(OTP_DELIVERY_OPTIONS) options?: OtpDeliveryOptions,
  ) {
    this.retryDelayMs = options?.retryDelayMs ?? 2_000;
  }

  async prepare(target: OtpDeliveryTarget, _code: string, at: Date, tx: DbExecutor): Promise<PreparedDelivery> {
    const transactionId = generateProviderMessageId();
    const row = await this.outbox.insertQueued(
      {
        phoneE164: target.phoneE164,
        templateKey: target.templateKey,
        provider: this.gateway.provider,
        providerMessageId: transactionId,
        otpChallengeId: target.challengeId,
        requestId: target.requestId ?? null,
        at,
      },
      tx,
    );
    return { smsOutboxId: row.id, transactionId };
  }

  dispatch(prepared: PreparedDelivery, target: OtpDeliveryTarget, code: string, hooks: DeliveryHooks = {}): void {
    const p = this.deliver(prepared, target, code, hooks).catch((err: unknown) => {
      this.logger.error(
        { event: 'otp.delivery_error', challengeId: target.challengeId, err: errorName(err) },
        'otp.delivery_error',
      );
    });
    this.inflight.add(p);
    void p.finally(() => this.inflight.delete(p));
  }

  async drain(): Promise<void> {
    while (this.inflight.size > 0) await Promise.allSettled([...this.inflight]);
  }

  async onApplicationShutdown(): Promise<void> {
    await this.drain();
  }

  private async deliver(
    prepared: PreparedDelivery,
    target: OtpDeliveryTarget,
    code: string,
    hooks: DeliveryHooks,
  ): Promise<void> {
    const text = this.config.SMS_OTP_TEMPLATE.replace('{code}', code);
    const maxAttempts = 1 + this.config.SMSPRO_RETRY_MAX;
    let result: SendResult | undefined;
    let attempt = 0;
    while (attempt < maxAttempts) {
      attempt += 1;
      try {
        result = await this.gateway.send({
          transactionId: prepared.transactionId,
          sender: this.config.SMSPRO_SENDER ?? 'Optomstroy',
          text,
          phone: target.phoneE164,
          test: this.testFlag(target.phoneE164),
          purpose: target.templateKey,
          smsOutboxId: prepared.smsOutboxId,
          attempt,
        });
      } catch (err) {
        this.logger.warn(
          { event: 'otp.send_exception', challengeId: target.challengeId, attempt, err: errorName(err) },
          'otp.send_exception',
        );
        result = undefined;
      }
      if (result && result.outcome !== 'RETRYABLE') break;
      if (attempt < maxAttempts && this.retryDelayMs > 0) await sleep(this.retryDelayMs * attempt);
    }
    const outcome: SendOutcome = result?.outcome ?? 'RETRYABLE';
    const ok = ACCEPTED.has(outcome);
    const at = this.clock.now();
    await this.outbox.recordResult(prepared.smsOutboxId, {
      status: ok ? 'sent' : 'failed',
      outcome,
      providerStatus: result?.providerStatus ?? null,
      attempts: attempt,
      smsParts: result?.smsParts ?? 0,
      phonesRecognized: result?.phonesRecognized ?? 0,
      latencyMs: result?.latencyMs ?? 0,
      at,
    });
    this.logger.log(
      {
        event: ok ? 'otp.sent' : 'otp.failed_delivery',
        challengeId: target.challengeId,
        transactionId: prepared.transactionId,
        phoneMasked: maskPhone(target.phoneE164),
        purpose: target.templateKey,
        providerStatus: result?.providerStatus ?? null,
        outcome,
        attempt,
        requestId: target.requestId ?? undefined,
      },
      ok ? 'otp.sent' : 'otp.failed_delivery',
    );
    if (ok) return;
    const ch = await this.challenges.findById(target.challengeId);
    if (ch && ch.status === 'sent') {
      await this.challenges.update(target.challengeId, { status: 'failed_delivery' }, at);
    }
    if (outcome === 'CONFIG_ERROR' || outcome === 'INSUFFICIENT_FUNDS') {
      this.breaker.open(
        outcome === 'CONFIG_ERROR' ? 'config_error' : 'insufficient_funds',
        this.config.SMSPRO_CB_OPEN_MINUTES,
      );
    }
    await hooks.onFailed?.();
  }

  /**
   * `<test>1</test>` (09 §5.8): `SMSPRO_TEST_FLAG=true` или staging-номер вне `SMS_STAGING_ALLOWED_PHONES`.
   */
  private testFlag(phoneE164: string): boolean {
    if (this.config.SMSPRO_TEST_FLAG) return true;
    if (this.config.APP_ENV !== 'staging' || this.gateway.provider !== 'smspro') return false;
    const allowed = (this.config.SMS_STAGING_ALLOWED_PHONES ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter((s) => s !== '');
    return !allowed.includes(phoneE164);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms).unref());
}

function errorName(e: unknown): string {
  return e instanceof Error ? e.name : 'unknown';
}

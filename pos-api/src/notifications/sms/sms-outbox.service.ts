import type { DbExecutor } from '../../common/audit/db-executor.js';
import { generateProviderMessageId } from '../../common/crypto/index.js';
import type { PosDatabase } from '../../db/database.js';
import {
  SMS_TEMPLATE_KEYS,
  type SmsGateway,
  type SmsTemplateKey,
  toE164Kg,
} from '../../integrations/sms/sms-gateway.js';
import { SMSPRO_MAX_TEXT_LENGTH } from '../../integrations/sms/smspro-xml.gateway.js';
import type { SmsJobPublisher } from './sms-job-publisher.js';
import { type SmsOutboxRepository, type SmsOutboxRow } from './sms-outbox.repository.js';
import { SMS_QUEUES, type SmsSendJob } from './sms-queues.js';
import type { SmsTextSealer } from './sms-text-sealer.js';

export interface EnqueueSmsInput {
  /** E.164 `+996XXXXXXXXX` (или `996XXXXXXXXX`). */
  readonly phone: string;
  readonly templateKey: SmsTemplateKey;
  /** Готовый текст (шаблон `SMS_OTP_TEMPLATE` применяет `SmsOtpProvider`, RM-D-001). В БД не сохраняется. */
  readonly text: string;
  readonly otpChallengeId?: string | null;
  readonly requestId?: string;
}

export interface EnqueuedSms {
  readonly id: string;
  readonly providerMessageId: string;
  readonly status: 'queued';
}

export class SmsEnqueueError extends Error {
  override readonly name = 'SmsEnqueueError';
}

/** Признак «SMS недоступны» для синхронного `503 SMS_PROVIDER_ERROR` (09 §4.2, §6.8; SMS-021). */
export interface SmsAvailability {
  readonly blocked: boolean;
  readonly reason?: 'config_error' | 'insufficient_funds' | 'retryable_ratio';
  readonly since?: Date;
}

/** Состояние доставки для `GET /auth/otp/challenges/{id}` (RM-D-014; 08 §4.1.9): без ПДн. */
export type SmsDeliveryView = 'queued' | 'sent' | 'delivered' | 'failed';

export interface SmsOutboxServiceDeps {
  readonly db: PosDatabase;
  readonly repo: SmsOutboxRepository;
  readonly gateway: Pick<SmsGateway, 'provider'>;
  readonly sealer: SmsTextSealer;
  readonly publisher: SmsJobPublisher;
  /** `SMSPRO_CB_OPEN_MINUTES`. */
  readonly cbOpenMinutes: number;
}

const UNIQUE_VIOLATION = '23505';
const RETRYABLE_RATIO = 0.5;
const RETRYABLE_MIN_SAMPLES = 4;

/**
 * Постановка SMS в очередь (RM-D-002; 09 §4.2, §6.8; 06 §4.5.3): в транзакции вызывающего (`OtpService`
 * создаёт `otp_challenges`) — строка `sms_outbox(queued)` с новым `provider_message_id` (12 `[A-Za-z0-9]`, CSPRNG,
 * UNIQUE — до HTTP-вызова, SMS-006) и задание `sms.send` с зашифрованным текстом. Ответ API не ждёт провайдера.
 */
export class SmsOutboxService {
  constructor(private readonly d: SmsOutboxServiceDeps) {}

  async enqueue(input: EnqueueSmsInput, executor?: DbExecutor): Promise<EnqueuedSms> {
    const phoneE164 = toE164Kg(input.phone);
    if (phoneE164 === null) throw new SmsEnqueueError('номер вне формата КР (+996XXXXXXXXX)');
    if (!(SMS_TEMPLATE_KEYS as readonly string[]).includes(input.templateKey)) {
      throw new SmsEnqueueError('неизвестный template_key');
    }
    if (input.text.length === 0 || input.text.length > SMSPRO_MAX_TEXT_LENGTH) {
      throw new SmsEnqueueError(`текст SMS: 1…${SMSPRO_MAX_TEXT_LENGTH} символов`);
    }
    const run = async (tx: DbExecutor): Promise<EnqueuedSms> => {
      const row = await this.insertWithUniqueId(tx, {
        phoneE164,
        templateKey: input.templateKey,
        otpChallengeId: input.otpChallengeId ?? null,
        requestId: input.requestId ?? null,
      });
      const job: SmsSendJob = {
        smsOutboxId: row.id,
        sealedText: this.d.sealer.seal(row.id, input.text),
        ...(input.requestId ? { requestId: input.requestId } : {}),
      };
      await this.d.publisher.publish(SMS_QUEUES.send, job, { singletonKey: row.id }, tx);
      return { id: row.id, providerMessageId: row.providerMessageId, status: 'queued' };
    };
    return executor ? run(executor) : this.d.db.transaction((tx) => run(tx));
  }

  /**
   * Канал SMS заведомо недоступен (межпроцессный circuit-breaker по журналу): последний `CONFIG_ERROR`/
   * `INSUFFICIENT_FUNDS` моложе `SMSPRO_CB_OPEN_MINUTES` без последующего принятия, либо ≥ 50 % `RETRYABLE`
   * за минуту (не менее 4 попыток).
   */
  async availability(executor?: DbExecutor): Promise<SmsAvailability> {
    const s = await this.d.repo.circuitSignals(this.d.cbOpenMinutes, executor);
    if (s.trip) {
      return {
        blocked: true,
        reason: s.trip.outcome === 'CONFIG_ERROR' ? 'config_error' : 'insufficient_funds',
        since: s.trip.at,
      };
    }
    const { total, retryable } = s.lastMinute;
    if (total >= RETRYABLE_MIN_SAMPLES && retryable / total >= RETRYABLE_RATIO) {
      return { blocked: true, reason: 'retryable_ratio' };
    }
    return { blocked: false };
  }

  async deliveryView(smsOutboxId: string, executor?: DbExecutor): Promise<SmsDeliveryView | undefined> {
    const row = await this.d.repo.findById(smsOutboxId, executor);
    if (!row) return undefined;
    if (row.status === 'expired') return 'failed';
    return row.status;
  }

  private async insertWithUniqueId(
    tx: DbExecutor,
    base: { phoneE164: string; templateKey: SmsTemplateKey; otpChallengeId: string | null; requestId: string | null },
  ): Promise<SmsOutboxRow> {
    // 62^12 ≈ 3·10^21 — коллизия практически невозможна; при нарушении UNIQUE — новый id (до 3 раз). Внутри
    // транзакции повтор после ошибки невозможен без SAVEPOINT — используется вложенная транзакция Drizzle.
    for (let i = 0; ; i++) {
      try {
        return await tx.transaction((sp) =>
          this.d.repo.insert(
            { ...base, provider: this.d.gateway.provider, providerMessageId: generateProviderMessageId() },
            sp,
          ),
        );
      } catch (e) {
        if (i < 2 && isUniqueViolation(e)) continue;
        throw e;
      }
    }
  }
}

function isUniqueViolation(e: unknown): boolean {
  for (let cur: unknown = e, depth = 0; cur && depth < 4; depth++) {
    if (typeof cur === 'object' && (cur as { code?: unknown }).code === UNIQUE_VIOLATION) return true;
    cur = (cur as { cause?: unknown }).cause;
  }
  return false;
}

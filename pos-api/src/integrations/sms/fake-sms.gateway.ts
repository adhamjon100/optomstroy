import { Logger } from '@nestjs/common';
import type pg from 'pg';
import { ConfigError } from '../../common/config/app-config.js';
import { maskPhone } from '../../common/logging/redaction.js';
import {
  type AccountInfo,
  classifySmsProStatus,
  type DeliveryReport,
  type DeliveryReportResponse,
  type SendRequest,
  type SendResult,
  type SmsGateway,
  toE164Kg,
  TRANSACTION_ID_RE,
} from './sms-gateway.js';
import type { SmsLogger } from './sms-telemetry.js';

/** Минимальный интерфейс логгера — sms-telemetry.ts (реэкспорт для совместимости импорта этапа C). */
export type { SmsLogger };

export type FakeSmsDb = Pick<pg.Pool, 'query'>;

/**
 * Имитация кодов `status` SMSPro по специальным номерам (09 §6.8): последние две цифры национального номера
 * `7000000NN` = код. `+996700000001` не входит — это типовой номер `AUTH_OTP_TEST_PHONES` (09 §5.8).
 */
export const DEFAULT_SIMULATED_STATUSES: ReadonlyMap<string, number> = new Map(
  [2, 3, 4, 5, 6, 7, 8, 9, 10, 11].map((code) => [`+9967000000${String(code).padStart(2, '0')}`, code]),
);

export interface FakeSmsGatewayOptions {
  readonly appEnv: 'dev' | 'staging' | 'prod';
  readonly logger?: SmsLogger;
  /** Номер E.164 → имитируемый `status` (по умолчанию DEFAULT_SIMULATED_STATUSES). */
  readonly simulatedStatuses?: ReadonlyMap<string, number>;
  readonly now?: () => number;
}

const UNDEFINED_TABLE = '42P01';

/**
 * `FakeSmsGateway` (09 §6.8, RM-C-008; ядро R0 §17.3): в сеть не ходит; принятое «SMS» записывает **только** в таблицу
 * `dev_outbox` (существует только в dev/test-схеме — миграция при `app.env IN ('dev','test')`, 07 §5.63). E2e-тесты
 * читают код оттуда. В лог (любого уровня) — только `transactionId`, маска телефона, `purpose`, `providerStatus`;
 * текст и код — никогда (SRC-B-116, AC-AUTH-012).
 *
 * Поведение «как у шлюза»: повтор того же `transactionId` после принятия → `status=10` (`DUPLICATE_ID`); номер вне
 * формата КР → `status=7`; `RETRYABLE` (9) не записывается (шлюз запрос не обработал); `test=true` → `status=11`.
 * Разрешён только при `APP_ENV ∈ {dev, staging}` (09 §5.8, OPS-027): конструктор отвергает `prod`.
 */
export class FakeSmsGateway implements SmsGateway {
  readonly provider = 'fake' as const;
  private readonly logger: SmsLogger;
  private readonly simulated: ReadonlyMap<string, number>;
  private readonly now: () => number;

  constructor(
    private readonly db: FakeSmsDb,
    options: FakeSmsGatewayOptions,
  ) {
    if (options.appEnv !== 'dev' && options.appEnv !== 'staging') {
      throw new ConfigError([`SMS_PROVIDER: fake запрещён при APP_ENV=${options.appEnv} (OPS-027, 09 §5.8)`]);
    }
    this.logger = options.logger ?? new Logger('sms');
    this.simulated = options.simulatedStatuses ?? DEFAULT_SIMULATED_STATUSES;
    this.now = options.now ?? Date.now;
  }

  async send(req: SendRequest): Promise<SendResult> {
    const started = this.now();
    const attempt = req.attempt ?? 1;
    const purpose = req.purpose ?? 'otp_login';
    const phone = toE164Kg(req.phone);
    const smsParts = countSmsParts(req.text);
    const finish = (providerStatus: number | null, outcome = classifyOrConfig(providerStatus)): SendResult => {
      const result: SendResult = {
        transactionId: req.transactionId,
        outcome,
        providerStatus,
        phonesRecognized: phone && providerStatus !== null && providerStatus !== 7 ? 1 : 0,
        smsParts,
        latencyMs: Math.max(0, this.now() - started),
        attempt,
      };
      this.logger.log({
        event: 'sms.fake.send',
        transactionId: req.transactionId,
        phoneMasked: maskPhone(req.phone),
        purpose,
        providerStatus,
        outcome,
        smsParts,
        attempt,
      });
      return result;
    };

    if (!TRANSACTION_ID_RE.test(req.transactionId)) return finish(1); // ошибка формата запроса (у нас)
    if (phone === null) return finish(7);
    const simulated = this.simulated.get(phone) ?? (req.test ? 11 : 0);
    if (simulated === 9) return finish(9); // шлюз перегружен: запрос не обработан, повтор с тем же id

    try {
      const res = await this.db.query(
        `INSERT INTO dev_outbox (transaction_id, sms_outbox_id, phone_e164, template_key, text, simulated_status_code)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (transaction_id) DO NOTHING
         RETURNING id`,
        [req.transactionId, req.smsOutboxId ?? null, phone, purpose, req.text, simulated],
      );
      if (res.rowCount === 0) return finish(10);
    } catch (e) {
      if (isPgError(e, UNDEFINED_TABLE)) {
        // prod/staging-схема без dev_outbox: fake здесь неприменим — ошибка конфигурации, не «успех».
        this.logger.warn({ event: 'sms.fake.no_dev_outbox', transactionId: req.transactionId });
        return finish(null, 'CONFIG_ERROR');
      }
      throw e;
    }
    return finish(simulated);
  }

  async getDeliveryReport(transactionId: string, phone: string): Promise<DeliveryReport[]> {
    return [...(await this.queryDeliveryReport(transactionId, phone)).reports];
  }

  /** Имитация `/api/dr`: запись есть → `status=0` с отчётом (0/11 → доставлено, иначе отклонено); нет → `status=4`. */
  async queryDeliveryReport(transactionId: string, phone: string): Promise<DeliveryReportResponse> {
    const res = await this.db.query<{ phone_e164: string; simulated_status_code: number | null; created_at: Date }>(
      `SELECT phone_e164, simulated_status_code, created_at FROM dev_outbox WHERE transaction_id = $1`,
      [transactionId],
    );
    const row = res.rows[0];
    if (!row || row.phone_e164 !== toE164Kg(phone)) return { status: 4, reports: [] };
    const delivered = row.simulated_status_code === 0 || row.simulated_status_code === 11;
    const time = row.created_at.toISOString();
    return {
      status: 0,
      reports: [
        {
          number: row.phone_e164.slice(1),
          report: delivered ? 3 : 2,
          sendTime: time,
          rcvTime: delivered ? time : null,
          state: delivered ? 'DELIVERED' : 'FAILED',
        },
      ],
    };
  }

  getAccountInfo(): Promise<AccountInfo> {
    return Promise.resolve({ status: 0, state: 0, account: '1000.00', smsprice: '0.00' });
  }
}

function classifyOrConfig(status: number | null): ReturnType<typeof classifySmsProStatus> {
  return status === null ? 'CONFIG_ERROR' : classifySmsProStatus(status);
}

/** Число частей SMS: GSM-7 — 160/153 символа, иначе UCS-2 — 70/67 (09 §6.7). */
export function countSmsParts(text: string): number {
  // eslint-disable-next-line no-control-regex
  const gsm = /^[\x0A\x0D\x20-\x7E]*$/.test(text);
  const [single, multi] = gsm ? [160, 153] : [70, 67];
  return text.length <= single ? 1 : Math.ceil(text.length / multi);
}

function isPgError(e: unknown, code: string): boolean {
  return typeof e === 'object' && e !== null && (e as { code?: unknown }).code === code;
}

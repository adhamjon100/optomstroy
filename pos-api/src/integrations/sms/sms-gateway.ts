/**
 * Порт `SmsGateway` (09 §6.8 — сигнатуры как спецификация; D-11; 06 §7.3). Реализации: `SmsProXmlGateway`
 * (боевой HTTP-XML SMSPro, RM-D-002) и `FakeSmsGateway` (dev/test, запись в `dev_outbox`, RM-C-008).
 * Выбор — `SMS_PROVIDER=smspro|fake` при старте (sms-gateway.factory.ts).
 *
 * Правило логов (09 §6.9, SRC-B-116, 11 SEC-062): реализация пишет в лог только `transactionId`, маску телефона,
 * `purpose`, `providerStatus` и служебные числа — никогда текст SMS, код, пароль или полный номер.
 *
 * Граница ответственности (09 §6.8): `send()` — **одна** HTTP-попытка с классификацией результата по таблице §6.4
 * и circuit-breaker; ретраи по классам (5/10/10 с для `status=9`, транспортные повторы с тем же `id`, сверка `/dr`
 * при `status=10`) выполняет `pos-worker` (notifications/sms, `SmsSendProcessor`).
 */

/** DI-токен порта. */
export const SMS_GATEWAY = 'SmsGateway' as const;

/** Значения `sms_outbox.template_key` / `dev_outbox.template_key` (07 §5.61, 09 §6.9). */
export const SMS_TEMPLATE_KEYS = ['otp_login', 'otp_step_up', 'otp_phone_change', 'otp_customer_link'] as const;
export type SmsTemplateKey = (typeof SMS_TEMPLATE_KEYS)[number];

/** Классы исхода отправки (09 §6.4, столбец «Класс»; CHECK `sms_outbox_outcome_chk`, 07 §5.61). */
export const SEND_OUTCOMES = [
  'ACCEPTED',
  'ACCEPTED_TEST',
  'RETRYABLE',
  'PERMANENT',
  'CONFIG_ERROR',
  'INSUFFICIENT_FUNDS',
  'INVALID_PHONE',
  'DUPLICATE_ID',
] as const;
export type SendOutcome = (typeof SEND_OUTCOMES)[number];

/**
 * Причина исхода без кода вендора (`providerStatus = null`) или уточнение `RETRYABLE` (09 §6.4, две последние
 * строки таблицы): по ней воркер выбирает политику повтора. Не секрет, пишется в лог и `sms_outbox.error`.
 */
export type SendFailure =
  /** Сетевой таймаут `SMSPRO_TIMEOUT_MS`: запрос мог быть принят — повтор с тем же `id`. */
  | 'timeout'
  /** Сбой соединения (DNS, TLS, сброс): повтор с тем же `id`. */
  | 'network'
  /** Тело ответа — не XML или без `<status>`: повтор с тем же `id`. */
  | 'bad_response'
  /** HTTP 5xx: повтор 1–2 раза с алертом, затем `PERMANENT` (5xx бывает и при ошибке клиента). */
  | 'http_5xx'
  /** HTTP-код вне 200/5xx: вендор их не использует → `PERMANENT`. */
  | 'http_status'
  /** Circuit-breaker открыт: сетевого вызова не было (09 §6.8). */
  | 'circuit_open'
  /** Запрос отвергнут адаптером до сети (формат `id`, номер вне КР) — ошибка у нас. */
  | 'invalid_request';

export interface SendRequest {
  /** Ровно 12 `[A-Za-z0-9]` из CSPRNG; UNIQUE = `sms_outbox.provider_message_id` (ядро §18.2 п. 9). */
  readonly transactionId: string;
  readonly sender: string;
  /** Текст SMS (содержит код) — в лог не попадает. */
  readonly text: string;
  /** `996XXXXXXXXX` (формат SMSPro) или E.164 `+996XXXXXXXXX`. */
  readonly phone: string;
  /** Тег `<test>1</test>` SMSPro (`SMSPRO_TEST_FLAG`). */
  readonly test: boolean;
  /** Назначение (`template_key`) — для лога и `dev_outbox`; по умолчанию `otp_login`. */
  readonly purpose?: SmsTemplateKey;
  /** Ссылка на строку `sms_outbox`, если она есть (тестовый режим OTP её не создаёт — 09 §5.8). */
  readonly smsOutboxId?: string | null;
  /** Номер попытки (ретраи по классам §6.4 выполняет pos-worker). */
  readonly attempt?: number;
  /** Сквозной `requestId` (11 SEC-064) — только для лога. */
  readonly requestId?: string;
}

export interface SendResult {
  readonly transactionId: string;
  readonly outcome: SendOutcome;
  /** Код `<status>` ответа `/api/message`; `null` — ответа вендора не было или он нечитаем. */
  readonly providerStatus: number | null;
  readonly phonesRecognized: number;
  readonly smsParts: number;
  /** Текст `<message>` вендора (маскирован: телефоны и коды скрыты). */
  readonly providerMessage?: string;
  readonly latencyMs: number;
  readonly attempt: number;
  /** Причина без кода вендора / уточнение `RETRYABLE` (см. `SendFailure`). */
  readonly failure?: SendFailure;
  /** HTTP-статус ответа (диагностика 5xx). */
  readonly httpStatus?: number;
}

/** Состояние доставки по коду `report` (09 §6.5: 3 → DELIVERED; 2/4/5/7 → FAILED; 0/1/6 → PENDING). */
export type DeliveryState = 'PENDING' | 'DELIVERED' | 'FAILED';
export type ReportCode = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7;

export interface DeliveryReport {
  /** Номер в формате SMSPro `996XXXXXXXXX`. */
  readonly number: string;
  readonly report: ReportCode;
  /** ISO 8601 (UTC) из `YYYYMMDDhhmmss` по времени Бишкека (GMT+6); `null` — события не было. */
  readonly sendTime: string | null;
  readonly rcvTime: string | null;
  readonly state: DeliveryState;
}

/**
 * Ответ `/api/dr` целиком (09 §6.5): `status` 0 — запрос корректен; 1 — формат; 2 — авторизация; 3 — IP;
 * 4 — отчёт для номера и ID не найден; 5 — переполнение очереди запросами с одним ID.
 * Нужен воркеру для `status=10` (SMS-013): «отчёт есть» (0 + `phone`) и «не найден» (4) различаются по `status`.
 */
export interface DeliveryReportResponse {
  readonly status: number;
  readonly reports: readonly DeliveryReport[];
}

export interface AccountInfo {
  readonly status: number;
  readonly state: 0 | 1;
  /** Баланс, десятичная строка. */
  readonly account: string;
  readonly smsprice: string;
}

export interface SmsGateway {
  /** `fake` | `smspro` — значение `SMS_PROVIDER` (и `sms_outbox.provider`). */
  readonly provider: 'fake' | 'smspro';
  /** Одна транзакция = один `<message>`, один номер (`/api/message`); одна HTTP-попытка. */
  send(req: SendRequest): Promise<SendResult>;
  /**
   * `/api/dr` (с `phone` всегда): отчёты при `status=0`; `[]` при `status=4` («не найден»). Прочие коды и сбои
   * транспорта → `SmsGatewayError`.
   */
  getDeliveryReport(transactionId: string, phone: string): Promise<DeliveryReport[]>;
  /** `/api/dr` с кодом `status` ответа (без исключения на коды вендора); сбой транспорта → `SmsGatewayError`. */
  queryDeliveryReport(transactionId: string, phone: string): Promise<DeliveryReportResponse>;
  /** `/api/info`: коды `status` вендора возвращаются в `AccountInfo.status`; сбой транспорта → `SmsGatewayError`. */
  getAccountInfo(): Promise<AccountInfo>;
}

/** Ошибка вызова `/api/dr` или `/api/info` (сбой транспорта, нечитаемый ответ, код вендора ≠ 0 в `getDeliveryReport`). */
export class SmsGatewayError extends Error {
  override readonly name = 'SmsGatewayError';

  constructor(
    readonly endpoint: 'message' | 'dr' | 'info',
    readonly kind: SendFailure | 'provider_status',
    readonly providerStatus: number | null = null,
    readonly httpStatus?: number,
  ) {
    super(
      `SMSPro /api/${endpoint}: ${kind}${providerStatus !== null ? ` (status=${providerStatus})` : ''}${
        httpStatus !== undefined ? ` (HTTP ${httpStatus})` : ''
      }`,
    );
  }
}

/**
 * Класс исхода по коду `status` ответа `/api/message` (09 §6.4). `11` — `ACCEPTED_TEST` всегда; если
 * `SMSPRO_TEST_FLAG=false`, вызывающий поднимает алерт «флаг утёк». Неизвестный код — `PERMANENT`.
 */
export function classifySmsProStatus(status: number): SendOutcome {
  switch (status) {
    case 0:
      return 'ACCEPTED';
    case 2:
    case 3:
    case 5:
      return 'CONFIG_ERROR';
    case 4:
      return 'INSUFFICIENT_FUNDS';
    case 7:
      return 'INVALID_PHONE';
    case 9:
      return 'RETRYABLE';
    case 10:
      return 'DUPLICATE_ID';
    case 11:
      return 'ACCEPTED_TEST';
    default:
      return 'PERMANENT'; // 1, 6, 8 и неизвестные
  }
}

/** Коды `status` `/api/message`, описанные вендором (09 §6.4, R2 §3.4). */
export const KNOWN_MESSAGE_STATUSES: readonly number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

/** Исход «принято шлюзом» (`sms_outbox.status = sent`). */
export function isAcceptedOutcome(outcome: SendOutcome): boolean {
  return outcome === 'ACCEPTED' || outcome === 'ACCEPTED_TEST';
}

/** Маппинг кода `report` (09 §6.5). Неизвестный код (не 0–7) — `PENDING` (как «6 — неизвестный статус»). */
export function deliveryStateOfReport(report: number): DeliveryState {
  if (report === 3) return 'DELIVERED';
  if (report === 2 || report === 4 || report === 5 || report === 7) return 'FAILED';
  return 'PENDING';
}

export function isReportCode(v: number): v is ReportCode {
  return Number.isInteger(v) && v >= 0 && v <= 7;
}

/** Номер КР в E.164 (`+996XXXXXXXXX`) из `996XXXXXXXXX` / `+996XXXXXXXXX`; иначе `null`. */
export function toE164Kg(phone: string): string | null {
  const digits = phone.replace(/[\s()-]/g, '');
  const m = /^\+?996(\d{9})$/.exec(digits);
  return m ? `+996${m[1]}` : null;
}

/** Номер в формате тега `<phone>` SMSPro: `996XXXXXXXXX` без «+» (SMS-008); вне КР — `null`. */
export function toSmsProPhone(phone: string): string | null {
  const e164 = toE164Kg(phone);
  return e164 === null ? null : e164.slice(1);
}

export const TRANSACTION_ID_RE = /^[A-Za-z0-9]{12}$/;

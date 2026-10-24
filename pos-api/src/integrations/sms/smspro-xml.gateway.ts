import { Logger } from '@nestjs/common';
import { type AppConfig, ConfigError } from '../../common/config/app-config.js';
import { maskCodesInText, maskPhone, maskPhonesInText } from '../../common/logging/redaction.js';
import { countSmsParts } from './fake-sms.gateway.js';
import { type CircuitOpenReason, type CircuitState, SmsCircuitBreaker } from './sms-circuit-breaker.js';
import {
  type AccountInfo,
  classifySmsProStatus,
  type DeliveryReport,
  type DeliveryReportResponse,
  KNOWN_MESSAGE_STATUSES,
  type SendFailure,
  type SendOutcome,
  type SendRequest,
  type SendResult,
  type SmsGateway,
  SmsGatewayError,
  toSmsProPhone,
  TRANSACTION_ID_RE,
} from './sms-gateway.js';
import { NodeHttpsTransport, type SmsHttpTransport, SmsTransportError } from './sms-http-transport.js';
import { createSmsTelemetry, SMS_METRICS, type SmsAlert, type SmsTelemetry } from './sms-telemetry.js';
import {
  buildDrXml,
  buildInfoXml,
  buildMessageXml,
  type MessageResponse,
  parseDrResponse,
  parseInfoResponse,
  parseMessageResponse,
} from './smspro-xml.js';

export type SmsProConfig = Pick<
  AppConfig,
  | 'SMSPRO_BASE_URL'
  | 'SMSPRO_LOGIN'
  | 'SMSPRO_PASSWORD'
  | 'SMSPRO_SENDER'
  | 'SMSPRO_TEST_FLAG'
  | 'SMSPRO_TIMEOUT_MS'
  | 'SMSPRO_RETRY_MAX'
> &
  Partial<Pick<AppConfig, 'SMSPRO_CB_OPEN_MINUTES' | 'APP_ENV'>>;

export interface SmsProGatewayDeps {
  readonly transport?: SmsHttpTransport;
  readonly telemetry?: SmsTelemetry;
  readonly now?: () => number;
}

/**
 * @deprecated Каркас этапа C (RM-C-008): методы `SmsProXmlGateway` больше не отвечают этой ошибкой — адаптер
 * реализован (RM-D-002). Класс сохранён только для совместимости импорта в test/integrations/prod-guard.spec.ts
 * (владелец теста обновляет проверку «каркаса»).
 */
export class SmsGatewayNotImplementedError extends Error {
  override readonly name = 'SmsGatewayNotImplementedError';

  constructor(method: string) {
    super(`SmsProXmlGateway.${method}: не реализовано`);
  }
}

/**
 * Имя отправителя (09 §6.2, §6.7; R2 §3.2): «либо из 11 латинских букв, цифр и знаков точка и тире, либо из 14 цифр».
 */
export const SENDER_RE = /^(?:[A-Za-z0-9.-]{1,11}|\d{14})$/;

/** Максимальная длина `text` по документации (R2 §3.2: «Максимальная длина 800 символов»). */
export const SMSPRO_MAX_TEXT_LENGTH = 800;

/** Алерты по коду `status` `/api/message` (09 §6.4, столбец «Действие адаптера»). */
const STATUS_ALERTS: Readonly<Record<number, Omit<SmsAlert, 'details'>>> = {
  1: { kind: 'smspro_request_format', severity: 'critical', message: 'SMSPro: ошибка в формате запроса (status=1)' },
  2: { kind: 'smspro_auth_failed', severity: 'critical', message: 'Неверный логин/пароль SMSPro (status=2)' },
  3: {
    kind: 'smspro_ip_not_allowed',
    severity: 'critical',
    message: 'IP сервера не в whitelist SMSPro (status=3)',
  },
  4: {
    kind: 'smspro_insufficient_funds',
    severity: 'critical',
    message: 'Пополните баланс SMSPro: недостаточно средств (status=4)',
  },
  5: {
    kind: 'smspro_sender_rejected',
    severity: 'critical',
    message: 'Имя отправителя SMSPro не согласовано (status=5)',
  },
  6: {
    kind: 'smspro_stop_words',
    severity: 'critical',
    message: 'SMS заблокировано по стоп-словам SMSPro (status=6): проверьте шаблон',
  },
  8: { kind: 'smspro_request_format', severity: 'critical', message: 'SMSPro: неверный формат времени (status=8)' },
};

/**
 * `SmsProXmlGateway` (09 §6.8, D-11, RM-D-002) — боевой адаптер HTTP-XML SMSPro:
 * - `POST {SMSPRO_BASE_URL}/message|dr|info`, только HTTPS (SMS-003), `Content-Type: application/xml`, таймаут
 *   `SMSPRO_TIMEOUT_MS` на вызов;
 * - тело `/message` строго из тегов документации, без `time`, `<test>1</test>` только при `SMSPRO_TEST_FLAG`
 *   (SMS-004…SMS-009); ответ разбирается namespace-agnostic, решение — по `<status>` (SMS-010);
 * - классы исхода — таблица §6.4 (SMS-011); `send()` выполняет **одну** HTTP-попытку — повторы с тем же `id`
 *   (`status=9`, таймаут, 5xx) и сверку `/dr` при `status=10` выполняет воркер (`SmsSendProcessor`);
 * - circuit-breaker (SMS-015): при открытом — `RETRYABLE` без сети, `sms_circuit_open=1` и алерт;
 * - логи (SMS-023): `transactionId`, маска номера, `purpose`, `providerStatus`, `smscnt`, `phonesRecognized`,
 *   `latencyMs`, `attempt`, `requestId`; логин, пароль, текст и код — никогда (секреты — в приватных полях).
 */
export class SmsProXmlGateway implements SmsGateway {
  readonly provider = 'smspro' as const;
  readonly baseUrl: string;
  readonly sender: string;
  readonly testFlag: boolean;
  readonly timeoutMs: number;
  readonly breaker: SmsCircuitBreaker;
  readonly #login: string;
  readonly #password: string;
  private readonly transport: SmsHttpTransport;
  private readonly telemetry: SmsTelemetry;
  private readonly now: () => number;
  private readonly appEnv: string | undefined;

  constructor(config: SmsProConfig, deps: SmsProGatewayDeps = {}) {
    const problems: string[] = [];
    if (!config.SMSPRO_LOGIN) problems.push('SMSPRO_LOGIN_FILE: обязателен при SMS_PROVIDER=smspro');
    if (!config.SMSPRO_PASSWORD) problems.push('SMSPRO_PASSWORD_FILE: обязателен при SMS_PROVIDER=smspro');
    if (!config.SMSPRO_SENDER) problems.push('SMSPRO_SENDER: обязателен при SMS_PROVIDER=smspro');
    else if (!SENDER_RE.test(config.SMSPRO_SENDER)) {
      problems.push('SMSPRO_SENDER: латиница/цифры/точка/тире ≤ 11 символов либо 14 цифр (09 §6.7)');
    }
    if (!config.SMSPRO_BASE_URL.startsWith('https://')) {
      problems.push('SMSPRO_BASE_URL: допускается только https:// (AC-AUTH-034)');
    }
    if (problems.length > 0) throw new ConfigError(problems);
    this.baseUrl = config.SMSPRO_BASE_URL.replace(/\/+$/, '');
    this.sender = config.SMSPRO_SENDER ?? '';
    this.testFlag = config.SMSPRO_TEST_FLAG;
    this.timeoutMs = config.SMSPRO_TIMEOUT_MS;
    this.appEnv = config.APP_ENV;
    this.#login = config.SMSPRO_LOGIN ?? '';
    this.#password = config.SMSPRO_PASSWORD ?? '';
    this.now = deps.now ?? Date.now;
    this.transport = deps.transport ?? new NodeHttpsTransport();
    this.telemetry = deps.telemetry ?? createSmsTelemetry(new Logger('sms'), this.now);
    this.breaker = new SmsCircuitBreaker({
      openMs: (config.SMSPRO_CB_OPEN_MINUTES ?? 5) * 60_000,
      now: this.now,
      onChange: (state, reason) => this.onBreakerChange(state, reason),
    });
    this.telemetry.metrics.set(SMS_METRICS.circuitOpen, 0);
  }

  /** Признак, что учётные данные загружены (без раскрытия значений). */
  get hasCredentials(): boolean {
    return this.#login.length > 0 && this.#password.length > 0;
  }

  async send(req: SendRequest): Promise<SendResult> {
    const started = this.now();
    const attempt = req.attempt ?? 1;
    const smsParts = countSmsParts(req.text);
    const base = { transactionId: req.transactionId, attempt };
    const done = (
      outcome: SendOutcome,
      extra: Partial<Omit<SendResult, 'transactionId' | 'outcome' | 'attempt' | 'latencyMs'>> = {},
    ): SendResult => {
      const result: SendResult = {
        ...base,
        outcome,
        providerStatus: extra.providerStatus ?? null,
        phonesRecognized: extra.phonesRecognized ?? 0,
        smsParts: extra.smsParts ?? smsParts,
        latencyMs: Math.max(0, this.now() - started),
        ...(extra.providerMessage ? { providerMessage: extra.providerMessage } : {}),
        ...(extra.failure ? { failure: extra.failure } : {}),
        ...(extra.httpStatus !== undefined ? { httpStatus: extra.httpStatus } : {}),
      };
      this.logSend(req, result);
      return result;
    };

    const phone = toSmsProPhone(req.phone);
    if (!TRANSACTION_ID_RE.test(req.transactionId)) return done('PERMANENT', { failure: 'invalid_request' });
    if (phone === null) return done('INVALID_PHONE', { failure: 'invalid_request' });
    if (req.text.length === 0 || req.text.length > SMSPRO_MAX_TEXT_LENGTH) {
      return done('PERMANENT', { failure: 'invalid_request' });
    }
    if (!this.breaker.allowRequest()) {
      this.telemetry.metrics.inc(SMS_METRICS.sendTotal, { outcome: 'RETRYABLE', status: 'circuit_open' });
      return done('RETRYABLE', { failure: 'circuit_open' });
    }

    try {
      const body = buildMessageXml({
        login: this.#login,
        pwd: this.#password,
        id: req.transactionId,
        sender: req.sender || this.sender,
        text: req.text,
        phone,
        test: req.test,
      });
      let res;
      try {
        res = await this.transport.post(`${this.baseUrl}/message`, body, this.timeoutMs);
      } catch (e) {
        const failure: SendFailure = e instanceof SmsTransportError && e.kind === 'timeout' ? 'timeout' : 'network';
        return this.finish(done('RETRYABLE', { failure }));
      } finally {
        this.telemetry.metrics.observeLatency(Math.max(0, this.now() - started));
      }
      if (res.status >= 500) {
        this.alert({
          kind: 'smspro_http_5xx',
          severity: 'warning',
          message: `SMSPro ответил HTTP ${res.status}`,
          details: { transactionId: req.transactionId, httpStatus: res.status },
        });
        return this.finish(done('RETRYABLE', { failure: 'http_5xx', httpStatus: res.status }));
      }
      if (res.status !== 200) {
        this.alert({
          kind: 'smspro_http_status',
          severity: 'critical',
          message: `SMSPro ответил неожиданным HTTP ${res.status}`,
          details: { transactionId: req.transactionId, httpStatus: res.status },
        });
        return this.finish(done('PERMANENT', { failure: 'http_status', httpStatus: res.status }));
      }
      let parsed: MessageResponse;
      try {
        parsed = parseMessageResponse(res.body);
      } catch {
        return this.finish(done('RETRYABLE', { failure: 'bad_response', httpStatus: res.status }));
      }
      const outcome = classifySmsProStatus(parsed.status);
      this.alertForStatus(parsed.status, req);
      const providerMessage = parsed.message ? maskCodesInText(maskPhonesInText(parsed.message)) : undefined;
      return this.finish(
        done(outcome, {
          providerStatus: parsed.status,
          phonesRecognized: parsed.phones ?? 0,
          smsParts: parsed.smscnt ?? smsParts,
          ...(providerMessage ? { providerMessage } : {}),
        }),
      );
    } catch (e) {
      // Непредвиденная ошибка до сети (например, недопустимый символ в тексте) — ошибка у нас.
      this.telemetry.logger.warn({
        event: 'sms.send.internal_error',
        transactionId: req.transactionId,
        error: e instanceof Error ? e.name : 'unknown',
      });
      return this.finish(done('PERMANENT', { failure: 'invalid_request' }));
    }
  }

  async getDeliveryReport(transactionId: string, phone: string): Promise<DeliveryReport[]> {
    const res = await this.queryDeliveryReport(transactionId, phone);
    if (res.status === 0) return [...res.reports];
    if (res.status === 4) return [];
    throw new SmsGatewayError('dr', 'provider_status', res.status);
  }

  async queryDeliveryReport(transactionId: string, phone: string): Promise<DeliveryReportResponse> {
    const p = toSmsProPhone(phone);
    if (p === null || !TRANSACTION_ID_RE.test(transactionId)) throw new SmsGatewayError('dr', 'invalid_request');
    const body = buildDrXml({ login: this.#login, pwd: this.#password, id: transactionId, phone: p });
    const xml = await this.call('dr', body);
    let parsed: DeliveryReportResponse;
    try {
      parsed = parseDrResponse(xml);
    } catch {
      throw new SmsGatewayError('dr', 'bad_response');
    }
    if (parsed.status === 2 || parsed.status === 3) this.alertForStatus(parsed.status, { transactionId });
    for (const r of parsed.reports) {
      this.telemetry.metrics.inc(SMS_METRICS.deliveryReportTotal, { report: r.report });
    }
    this.telemetry.logger.log({
      event: 'sms.dr',
      transactionId,
      phoneMasked: maskPhone(p),
      providerStatus: parsed.status,
      reports: parsed.reports.map((r) => r.report),
    });
    return parsed;
  }

  async getAccountInfo(): Promise<AccountInfo> {
    const xml = await this.call('info', buildInfoXml({ login: this.#login, pwd: this.#password }));
    try {
      return parseInfoResponse(xml);
    } catch {
      throw new SmsGatewayError('info', 'bad_response');
    }
  }

  /** Состояние breaker'а (для health «sms: ok|circuit_open» и SCR-46). */
  circuitState(): { state: CircuitState; reason?: CircuitOpenReason; since?: Date } {
    const state = this.breaker.state;
    const reason = this.breaker.reason;
    const since = this.breaker.openedSince;
    return { state, ...(reason ? { reason } : {}), ...(since ? { since } : {}) };
  }

  private async call(endpoint: 'dr' | 'info', body: string): Promise<string> {
    let res;
    try {
      res = await this.transport.post(`${this.baseUrl}/${endpoint}`, body, this.timeoutMs);
    } catch (e) {
      throw new SmsGatewayError(
        endpoint,
        e instanceof SmsTransportError && e.kind === 'timeout' ? 'timeout' : 'network',
      );
    }
    if (res.status >= 500) throw new SmsGatewayError(endpoint, 'http_5xx', null, res.status);
    if (res.status !== 200) throw new SmsGatewayError(endpoint, 'http_status', null, res.status);
    return res.body;
  }

  /** Учёт исхода в breaker'е и метриках (только для выполненных сетевых вызовов). */
  private finish(result: SendResult): SendResult {
    if (result.failure === 'invalid_request') this.breaker.abandonProbe();
    else this.breaker.record(result.outcome);
    this.telemetry.metrics.inc(SMS_METRICS.sendTotal, {
      outcome: result.outcome,
      status: result.providerStatus ?? result.failure ?? 'none',
    });
    return result;
  }

  private alertForStatus(status: number, req: { transactionId: string }): void {
    const a = STATUS_ALERTS[status];
    if (a) {
      this.alert({ ...a, details: { transactionId: req.transactionId, providerStatus: status } });
      return;
    }
    if (status === 11 && !this.testFlag) {
      this.alert({
        kind: 'smspro_test_flag_leaked',
        severity: 'critical',
        message: `SMSPro ответил status=11 (тестовый режим) при SMSPRO_TEST_FLAG=false${
          this.appEnv ? `, APP_ENV=${this.appEnv}` : ''
        }`,
        details: { transactionId: req.transactionId, providerStatus: status },
      });
      return;
    }
    if (!KNOWN_MESSAGE_STATUSES.includes(status)) {
      this.alert({
        kind: 'smspro_unknown_status',
        severity: 'critical',
        message: `SMSPro вернул недокументированный status=${status}`,
        details: { transactionId: req.transactionId, providerStatus: status },
      });
    }
  }

  private alert(a: SmsAlert): void {
    this.telemetry.alerts.raise(a);
  }

  private onBreakerChange(state: CircuitState, reason?: CircuitOpenReason): void {
    this.telemetry.metrics.set(SMS_METRICS.circuitOpen, state === 'closed' ? 0 : 1);
    this.telemetry.logger.warn({ event: 'sms.circuit_state', state, reason: reason ?? null });
    if (state === 'open') {
      this.alert({
        kind: 'sms_circuit_open',
        severity: 'critical',
        message: `Circuit-breaker SMS открыт (${reason ?? 'unknown'}): отправка SMS приостановлена`,
        details: { reason: reason ?? null },
      });
    }
  }

  private logSend(req: SendRequest, r: SendResult): void {
    const entry = {
      event: 'sms.send',
      transactionId: r.transactionId,
      phoneMasked: maskPhone(req.phone),
      purpose: req.purpose ?? 'otp_login',
      providerStatus: r.providerStatus,
      outcome: r.outcome,
      smscnt: r.smsParts,
      phonesRecognized: r.phonesRecognized,
      latencyMs: r.latencyMs,
      attempt: r.attempt,
      ...(r.failure ? { failure: r.failure } : {}),
      ...(r.httpStatus !== undefined ? { httpStatus: r.httpStatus } : {}),
      ...(r.providerMessage ? { providerMessage: r.providerMessage } : {}),
      ...(req.requestId ? { requestId: req.requestId } : {}),
    };
    if (r.outcome === 'ACCEPTED' || r.outcome === 'ACCEPTED_TEST') this.telemetry.logger.log(entry);
    else this.telemetry.logger.warn(entry);
  }
}

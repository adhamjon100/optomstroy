import { Logger } from '@nestjs/common';

/**
 * Метрики и алерты SMS (09 §6.9, SMS-024; 11 §7 — события `sms.send|retry|failed|circuit_open|balance_low`).
 *
 * Метрики — в памяти процесса (счётчики/гейджи с метками) с выводом в текстовом формате Prometheus
 * (`toPrometheusText`); эндпоинт экспорта и канал алертов (Q-032) подключает владелец мониторинга (16).
 * Алерт — структурное событие лога `sms.alert` уровня error/warn (канал по умолчанию) с подавлением повторов
 * одного вида в окне `dedupeMs`. Ни метрики, ни алерты не содержат текста SMS, кода, пароля и полного номера.
 */

export const SMS_METRICS = {
  sendTotal: 'sms_send_total',
  sendLatencyMs: 'sms_send_latency_ms',
  retryTotal: 'sms_retry_total',
  deliveryReportTotal: 'sms_delivery_report_total',
  balanceSom: 'sms_balance_som',
  circuitOpen: 'sms_circuit_open',
  dlrUnknownIdTotal: 'sms_dlr_unknown_id_total',
} as const;
export type SmsMetricName = (typeof SMS_METRICS)[keyof typeof SMS_METRICS];

type Labels = Readonly<Record<string, string | number>>;

const key = (name: string, labels: Labels = {}): string => {
  const parts = Object.keys(labels)
    .sort()
    .map((k) => `${k}="${String(labels[k]).replace(/["\\\n]/g, '_')}"`);
  return parts.length > 0 ? `${name}{${parts.join(',')}}` : name;
};

export interface SmsMetricSample {
  readonly name: string;
  readonly labels: Labels;
  readonly value: number;
}

/** Реестр метрик SMS процесса. */
export class SmsMetrics {
  private readonly counters = new Map<string, SmsMetricSample>();
  private readonly gauges = new Map<string, SmsMetricSample>();
  /** Сводка задержки: count/sum/max (без гистограммы — достаточно для алертов §6.9). */
  private readonly latency = { count: 0, sum: 0, max: 0 };

  inc(name: SmsMetricName, labels: Labels = {}, by = 1): void {
    const k = key(name, labels);
    const prev = this.counters.get(k);
    this.counters.set(k, { name, labels, value: (prev?.value ?? 0) + by });
  }

  set(name: SmsMetricName, value: number, labels: Labels = {}): void {
    this.gauges.set(key(name, labels), { name, labels, value });
  }

  observeLatency(ms: number): void {
    this.latency.count += 1;
    this.latency.sum += ms;
    this.latency.max = Math.max(this.latency.max, ms);
  }

  /** Значение счётчика/гейджа (сумма по всем меткам, если `labels` не заданы). */
  value(name: SmsMetricName, labels?: Labels): number {
    if (name === SMS_METRICS.sendLatencyMs) return this.latency.count;
    const pool = [...this.counters.values(), ...this.gauges.values()].filter((s) => s.name === name);
    if (labels === undefined) return pool.reduce((a, s) => a + s.value, 0);
    const k = key(name, labels);
    return (this.counters.get(k) ?? this.gauges.get(k))?.value ?? 0;
  }

  latencySummary(): { count: number; sum: number; max: number } {
    return { ...this.latency };
  }

  snapshot(): SmsMetricSample[] {
    return [...this.counters.values(), ...this.gauges.values()];
  }

  toPrometheusText(): string {
    const lines: string[] = [];
    for (const s of this.snapshot()) lines.push(`${key(s.name, s.labels)} ${s.value}`);
    lines.push(`${SMS_METRICS.sendLatencyMs}_count ${this.latency.count}`);
    lines.push(`${SMS_METRICS.sendLatencyMs}_sum ${this.latency.sum}`);
    lines.push(`${SMS_METRICS.sendLatencyMs}_max ${this.latency.max}`);
    return `${lines.join('\n')}\n`;
  }
}

/** Виды алертов (09 §6.4, §6.6, §6.9). */
export type SmsAlertKind =
  | 'smspro_auth_failed'
  | 'smspro_ip_not_allowed'
  | 'smspro_insufficient_funds'
  | 'smspro_sender_rejected'
  | 'smspro_stop_words'
  | 'smspro_request_format'
  | 'smspro_test_flag_leaked'
  | 'smspro_unknown_status'
  | 'smspro_http_5xx'
  | 'smspro_http_status'
  | 'smspro_duplicate_id'
  | 'smspro_retry_exhausted'
  | 'sms_circuit_open'
  | 'sms_balance_low'
  | 'sms_account_inactive'
  | 'sms_balance_unreachable'
  | 'sms_dlr_error';

export interface SmsAlert {
  readonly kind: SmsAlertKind;
  readonly severity: 'warning' | 'critical';
  /** Текст для дежурного (рус.), без секретов и ПДн. */
  readonly message: string;
  readonly details?: Readonly<Record<string, string | number | boolean | null>>;
}

export interface SmsAlertSink {
  raise(alert: SmsAlert): void;
}

/** Минимальный интерфейс логгера (Nest `Logger` → nestjs-pino в API; pino-логгер в pos-worker — `pinoSmsLogger`). */
export interface SmsLogger {
  log(message: Record<string, unknown>): void;
  warn(message: Record<string, unknown>): void;
  error?(message: Record<string, unknown>): void;
}

/** Адаптер pino → SmsLogger (pos-worker вне Nest). */
export function pinoSmsLogger(p: {
  info(obj: object, msg?: string): void;
  warn(obj: object, msg?: string): void;
  error(obj: object, msg?: string): void;
}): SmsLogger {
  const msg = (o: Record<string, unknown>): string => (typeof o.event === 'string' ? o.event : 'sms');
  return {
    log: (o) => p.info(o, msg(o)),
    warn: (o) => p.warn(o, msg(o)),
    error: (o) => p.error(o, msg(o)),
  };
}

/** Канал алертов по умолчанию: событие лога `sms.alert` (Q-032 — внешний канал) с подавлением повторов. */
export class LogSmsAlertSink implements SmsAlertSink {
  private readonly last = new Map<SmsAlertKind, number>();
  readonly raised: SmsAlert[] = [];

  constructor(
    private readonly logger: SmsLogger = new Logger('sms'),
    private readonly now: () => number = Date.now,
    private readonly dedupeMs = 5 * 60_000,
  ) {}

  raise(alert: SmsAlert): void {
    const t = this.now();
    const prev = this.last.get(alert.kind);
    if (prev !== undefined && t - prev < this.dedupeMs) return;
    this.last.set(alert.kind, t);
    this.raised.push(alert);
    if (this.raised.length > 100) this.raised.shift();
    const entry = {
      event: 'sms.alert',
      alert: alert.kind,
      severity: alert.severity,
      alertMessage: alert.message,
      ...(alert.details ?? {}),
    };
    if (alert.severity === 'critical') (this.logger.error ?? this.logger.warn).call(this.logger, entry);
    else this.logger.warn(entry);
  }
}

/** Набор телеметрии SMS процесса (один на процесс: gateway, воркер, DLR, баланс). */
export interface SmsTelemetry {
  readonly metrics: SmsMetrics;
  readonly alerts: SmsAlertSink;
  readonly logger: SmsLogger;
}

export const SMS_TELEMETRY = 'SmsTelemetry' as const;

export function createSmsTelemetry(logger: SmsLogger = new Logger('sms'), now: () => number = Date.now): SmsTelemetry {
  return { metrics: new SmsMetrics(), alerts: new LogSmsAlertSink(logger, now), logger };
}

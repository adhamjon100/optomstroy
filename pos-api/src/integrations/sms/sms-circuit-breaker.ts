import type { SendOutcome } from './sms-gateway.js';

/**
 * Circuit-breaker отправки SMS (09 §6.8, SMS-015, AC-AUTH-030):
 * - открывается сразу при `CONFIG_ERROR` / `INSUFFICIENT_FUNDS` (коды 2, 3, 4, 5) и при доле `RETRYABLE` ≥ 50 %
 *   за скользящую минуту (при не менее `minSamples` вызовов — иначе один таймаут открыл бы breaker);
 * - пока открыт — `send()` немедленно возвращает `RETRYABLE` без сетевого вызова;
 * - через `SMSPRO_CB_OPEN_MINUTES` переходит в half-open: пропускается **один** пробный запрос; принят → закрыт,
 *   иначе снова открыт на тот же срок.
 * Состояние — в памяти процесса-отправителя (pos-worker). Межпроцессный признак «SMS недоступны» для синхронного
 * `503 SMS_PROVIDER_ERROR` в `/auth/otp/request` выводится из `sms_outbox` (notifications/sms, `SmsOutboxService`).
 */
export type CircuitState = 'closed' | 'open' | 'half_open';

export type CircuitOpenReason = 'config_error' | 'insufficient_funds' | 'retryable_ratio' | 'probe_failed';

export interface SmsCircuitBreakerOptions {
  readonly openMs: number;
  readonly windowMs?: number;
  readonly retryableRatio?: number;
  readonly minSamples?: number;
  readonly now?: () => number;
  readonly onChange?: (state: CircuitState, reason?: CircuitOpenReason) => void;
}

export class SmsCircuitBreaker {
  private stateValue: CircuitState = 'closed';
  private openedAt = 0;
  private probeInFlight = false;
  private reasonValue: CircuitOpenReason | undefined;
  private readonly samples: { t: number; retryable: boolean }[] = [];
  private readonly windowMs: number;
  private readonly ratio: number;
  private readonly minSamples: number;
  private readonly now: () => number;

  constructor(private readonly o: SmsCircuitBreakerOptions) {
    this.windowMs = o.windowMs ?? 60_000;
    this.ratio = o.retryableRatio ?? 0.5;
    this.minSamples = o.minSamples ?? 4;
    this.now = o.now ?? Date.now;
  }

  get state(): CircuitState {
    if (this.stateValue === 'open' && this.now() - this.openedAt >= this.o.openMs) return 'half_open';
    return this.stateValue;
  }

  get reason(): CircuitOpenReason | undefined {
    return this.stateValue === 'closed' ? undefined : this.reasonValue;
  }

  /** Момент открытия (для «SMS недоступны с HH:MM», 09 §6.13). */
  get openedSince(): Date | undefined {
    return this.stateValue === 'closed' ? undefined : new Date(this.openedAt);
  }

  /** Можно ли выполнить сетевой вызов сейчас. В half-open пропускает один пробный запрос. */
  allowRequest(): boolean {
    const s = this.state;
    if (s === 'closed') return true;
    if (s === 'open') return false;
    if (this.probeInFlight) return false;
    this.probeInFlight = true;
    if (this.stateValue !== 'half_open') {
      this.stateValue = 'half_open';
      this.o.onChange?.('half_open', this.reasonValue);
    }
    return true;
  }

  /** Пробный запрос не состоялся (ошибка до сети) — освободить слот half-open без вердикта. */
  abandonProbe(): void {
    this.probeInFlight = false;
  }

  /** Учёт исхода выполненного сетевого вызова (не вызывается для отказов breaker'а). */
  record(outcome: SendOutcome): void {
    const t = this.now();
    const wasProbe = this.probeInFlight;
    this.probeInFlight = false;
    if (outcome === 'CONFIG_ERROR' || outcome === 'INSUFFICIENT_FUNDS') {
      this.open(outcome === 'CONFIG_ERROR' ? 'config_error' : 'insufficient_funds', t);
      return;
    }
    if (wasProbe || this.stateValue === 'half_open') {
      if (outcome === 'RETRYABLE') this.open('probe_failed', t);
      else this.close();
      return;
    }
    this.samples.push({ t, retryable: outcome === 'RETRYABLE' });
    while (this.samples.length > 0 && t - this.samples[0].t > this.windowMs) this.samples.shift();
    const retryable = this.samples.filter((s) => s.retryable).length;
    if (this.samples.length >= this.minSamples && retryable / this.samples.length >= this.ratio) {
      this.open('retryable_ratio', t);
    }
  }

  private open(reason: CircuitOpenReason, t: number): void {
    this.stateValue = 'open';
    this.openedAt = t;
    this.reasonValue = reason;
    this.samples.length = 0;
    this.o.onChange?.('open', reason);
  }

  private close(): void {
    const was = this.stateValue;
    this.stateValue = 'closed';
    this.reasonValue = undefined;
    this.samples.length = 0;
    if (was !== 'closed') this.o.onChange?.('closed');
  }
}

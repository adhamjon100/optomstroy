import { Inject, Injectable, Logger } from '@nestjs/common';
import { CLOCK, type Clock } from '../../common/auth/clock.js';

export type CircuitReason = 'global_limit' | 'config_error' | 'insufficient_funds';

/**
 * Circuit-breaker отправки OTP (09 §5.4 «Глобальный», §6.8): открыт → `POST /auth/otp/request` отвечает
 * нейтральным `503 SMS_PROVIDER_ERROR` без сетевого вызова. Открывается при превышении `OTP_GLOBAL_PER_MIN`
 * (5 мин) и при итогах доставки `CONFIG_ERROR`/`INSUFFICIENT_FUNDS` (`SMSPRO_CB_OPEN_MINUTES`). Состояние — в
 * процессе (одна реплика pos-api в R1; D-45).
 */
@Injectable()
export class OtpCircuitBreaker {
  private readonly logger = new Logger('auth');
  private openUntil = 0;
  private reason: CircuitReason | undefined;

  constructor(@Inject(CLOCK) private readonly clock: Clock) {}

  isOpen(): boolean {
    return this.clock.now().getTime() < this.openUntil;
  }

  open(reason: CircuitReason, minutes: number): void {
    const until = this.clock.now().getTime() + minutes * 60_000;
    if (until > this.openUntil) {
      this.openUntil = until;
      this.reason = reason;
    }
    // Алерт SEC-068 / 09 §6.9: событие лога уровня error (канал оповещения — Q-032).
    this.logger.error({ event: 'otp.circuit_open', reason, minutes }, 'otp.circuit_open');
  }

  get openReason(): CircuitReason | undefined {
    return this.isOpen() ? this.reason : undefined;
  }

  reset(): void {
    this.openUntil = 0;
    this.reason = undefined;
  }
}

import { Inject, Injectable, Optional } from '@nestjs/common';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { type RateLimitScope, RateLimitService } from '../../common/rate-limit/rate-limit.service.js';

/**
 * Лимиты групп 08 §2.9:
 * - хранилище `memory` (так в 08): RL-PUBLIC-IP, RL-AUTH, RL-OTP-STATUS — фиксированные окна в процессе;
 * - хранилище `Postgres` (08 §2.9; миграция 0003, DQ-01): RL-OTP-VERIFY на IP (`otp_verify_ip_10m`) и RL-PIN
 *   30 / 10 мин на `userId + deviceId` (`pin_user_device_10m`) — `rate_limit_counters`, переживают рестарт и общие
 *   для реплик. Счёт неверных PIN подряд (5 → `PIN_LOCKED`) — в `app_pins`.
 */
export interface AuthHttpLimits {
  /** RL-PUBLIC-IP: публичные эндпоинты auth, на IP в минуту. */
  readonly publicIpPerMinute: number;
  /** RL-AUTH: `/auth/refresh`, `/auth/logout*`, `/auth/sessions` — на устройство в минуту. */
  readonly authPerDevicePerMinute: number;
  /** RL-OTP-STATUS: не более N запросов статуса на челлендж. */
  readonly otpStatusPerChallenge: number;
  /** RL-OTP-VERIFY: на IP за 10 мин. */
  readonly otpVerifyPerIp10m: number;
  /** RL-PIN: попыток PIN (step-up/unlock) на `userId + deviceId` за 10 мин. */
  readonly pinPer10m: number;
}

export const AUTH_HTTP_LIMITS = Symbol('AUTH_HTTP_LIMITS');

export const DEFAULT_AUTH_HTTP_LIMITS: AuthHttpLimits = Object.freeze({
  publicIpPerMinute: 60,
  authPerDevicePerMinute: 30,
  otpStatusPerChallenge: 20,
  otpVerifyPerIp10m: 60,
  pinPer10m: 30,
});

const MAX_KEYS = 50_000;

interface Bucket {
  start: number;
  count: number;
  /** Окно группы этой корзины: очистка при переполнении — по собственному окну (ревью D-MN-03). */
  windowMs: number;
}

@Injectable()
export class AuthHttpRateLimiter {
  private readonly buckets = new Map<string, Bucket>();
  readonly limits: AuthHttpLimits;

  /**
   * `rateLimit` — счётчики PostgreSQL (в AuthModule всегда есть: RateLimitModule глобальный). Без него (unit-тесты
   * без БД) группы «Postgres» считаются в памяти процесса тем же фиксированным окном.
   */
  constructor(
    @Inject(CLOCK) private readonly clock: Clock,
    @Optional() private readonly rateLimit?: RateLimitService,
    @Optional() @Inject(AUTH_HTTP_LIMITS) limits?: AuthHttpLimits,
  ) {
    this.limits = limits ?? DEFAULT_AUTH_HTTP_LIMITS;
  }

  /** Учитывает событие; превышение → 429 RATE_LIMITED с `retryAfter`. */
  hit(group: string, key: string, limit: number, windowMs: number): void {
    const now = this.clock.now().getTime();
    const k = `${group}:${key}`;
    let b = this.buckets.get(k);
    if (!b || now - b.start >= windowMs) {
      if (this.buckets.size >= MAX_KEYS) this.prune(now);
      b = { start: now, count: 0, windowMs };
      this.buckets.set(k, b);
    }
    if (b.count >= limit) {
      const retryAfter = Math.max(1, Math.ceil((b.start + windowMs - now) / 1000));
      throw new ProblemException('RATE_LIMITED', {
        detail: 'Слишком много запросов. Повторите позже.',
        retryAfter,
      });
    }
    b.count += 1;
  }

  publicIp(ip: string | null): void {
    this.hit('RL-PUBLIC-IP', ip ?? 'unknown', this.limits.publicIpPerMinute, 60_000);
  }

  authDevice(deviceKey: string): void {
    this.hit('RL-AUTH', deviceKey, this.limits.authPerDevicePerMinute, 60_000);
  }

  otpStatus(challengeId: string, deviceKey: string): void {
    this.hit('RL-OTP-STATUS', `${challengeId}:${deviceKey}`, this.limits.otpStatusPerChallenge, 10 * 60_000);
  }

  /** RL-OTP-VERIFY: 60 / 10 мин на IP (`otp_verify_ip_10m`). Попытки на код (5) — `otp_challenges.attempts`. */
  otpVerifyIp(ip: string | null): Promise<void> {
    return this.durable('otp_verify_ip_10m', 'RL-OTP-VERIFY', ip ?? 'unknown', this.limits.otpVerifyPerIp10m);
  }

  /** RL-PIN: единый ключ `userId:deviceKey` для step-up по PIN и `/auth/unlock` (ревью D-MN-03). */
  pin(userId: string, deviceKey: string): Promise<void> {
    return this.durable('pin_user_device_10m', 'RL-PIN', `${userId}:${deviceKey}`, this.limits.pinPer10m);
  }

  /**
   * Группа с хранилищем Postgres: `consume` в собственной транзакции (попытка учитывается, даже если запрос затем
   * откатится — иначе отказ PIN «бесплатен»); превышение → 429 RATE_LIMITED с `retryAfter` до конца окна.
   */
  private async durable(scope: RateLimitScope, group: string, subject: string, limit: number): Promise<void> {
    if (!this.rateLimit) {
      this.hit(group, subject, limit, 10 * 60_000);
      return;
    }
    const r = await this.rateLimit.consume([{ scope, subject, limit }]);
    if (!r.allowed) {
      throw new ProblemException('RATE_LIMITED', {
        detail: 'Слишком много запросов. Повторите позже.',
        retryAfter: Math.max(1, r.retryAfterSec),
      });
    }
  }

  clear(): void {
    this.buckets.clear();
  }

  /**
   * Удаляет только истёкшие корзины — каждую по её собственному окну: переполнение ключами 1-минутных групп
   * (`X-Device-Id` выбирает клиент) не сбрасывает 10-минутные RL-PIN / RL-OTP-VERIFY / RL-OTP-STATUS.
   */
  private prune(now: number): void {
    for (const [k, b] of this.buckets) if (now - b.start >= b.windowMs) this.buckets.delete(k);
  }

  /** Число корзин (наблюдаемость и тесты). */
  get size(): number {
    return this.buckets.size;
  }
}

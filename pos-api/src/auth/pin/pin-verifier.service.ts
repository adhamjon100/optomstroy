import { Inject, Injectable } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { PinHasher } from '../../common/crypto/pin-hasher.service.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { AuthPolicyService } from '../common/auth-policy.js';
import { AppPinsRepository } from './app-pins.repository.js';

/**
 * Блокировка PIN после 5 неверных подряд действует «до успешного OTP-входа» (09 §9.6, BIO-020): срок условный —
 * снимается `resetAfterOtpLogin` при входе по OTP.
 */
export const PIN_LOCK_DAYS = 365;

export type PinCheck =
  | { readonly kind: 'ok' }
  | { readonly kind: 'not_set' }
  | { readonly kind: 'locked'; readonly until: Date }
  | { readonly kind: 'invalid'; readonly attemptsLeft: number }
  /** Эта попытка — 5-я неверная подряд: PIN заблокирован (аудит `auth.pin.locked`). */
  | { readonly kind: 'locked_now'; readonly until: Date };

/**
 * Серверная проверка PIN (D-48; 09 §9.6; RM-D-003): Argon2id + `PIN_PEPPER` (common/crypto PinHasher),
 * `PIN_MAX_ATTEMPTS=5` неверных подряд → блокировка. Счёт — на `user_id` (`app_pins.failed_attempts`;
 * разделение по устройству — D_spec_questions A-09). Выполняется в транзакции вызывающего: строка `app_pins`
 * блокируется FOR UPDATE (параллельные попытки не обходят счётчик).
 */
@Injectable()
export class PinVerifier {
  constructor(
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly pins: AppPinsRepository,
    private readonly hasher: PinHasher,
    private readonly policy: AuthPolicyService,
  ) {}

  async verify(userId: string, pin: string, tx: DbExecutor): Promise<PinCheck> {
    const now = this.clock.now();
    const row = await this.pins.find(userId, tx, true);
    if (!row) return { kind: 'not_set' };
    if (row.lockedUntil !== null && row.lockedUntil.getTime() > now.getTime()) {
      return { kind: 'locked', until: row.lockedUntil };
    }
    const max = this.policy.base().session.pinMaxAttempts;
    const res = await this.hasher.verify(pin, userId, row.pinHash, row.pepperVersion);
    if (!res.ok) {
      const attempts = row.failedAttempts + 1;
      if (attempts >= max) {
        const until = new Date(now.getTime() + PIN_LOCK_DAYS * 24 * 3600_000);
        await this.pins.setAttempts(userId, attempts, until, now, tx);
        return { kind: 'locked_now', until };
      }
      await this.pins.setAttempts(userId, attempts, null, now, tx);
      return { kind: 'invalid', attemptsLeft: max - attempts };
    }
    if (row.failedAttempts !== 0 || row.lockedUntil !== null) await this.pins.setAttempts(userId, 0, null, now, tx);
    if (res.needsRehash) {
      const h = await this.hasher.hash(pin, userId);
      await this.pins.rehash(userId, h, now, tx);
    }
    return { kind: 'ok' };
  }

  /** Успешный вход по OTP снимает блокировку PIN и обнуляет счётчик (09 §9.6, §9.7). */
  async resetAfterOtpLogin(userId: string, tx: DbExecutor): Promise<void> {
    const row = await this.pins.find(userId, tx);
    if (row && (row.failedAttempts !== 0 || row.lockedUntil !== null)) {
      await this.pins.setAttempts(userId, 0, null, this.clock.now(), tx);
    }
  }

  static toProblem(check: Exclude<PinCheck, { kind: 'ok' }>): ProblemException {
    switch (check.kind) {
      case 'not_set':
        return new ProblemException('FORBIDDEN', { detail: 'PIN не установлен.', reason: 'pin_not_set' });
      case 'locked':
      case 'locked_now':
        return new ProblemException('PIN_LOCKED', {
          detail: 'PIN заблокирован. Войдите по номеру телефона.',
          until: check.until.toISOString(),
        });
      case 'invalid':
        return new ProblemException('PIN_INVALID', {
          detail: `Неверный PIN. Осталось попыток: ${check.attemptsLeft}.`,
          attemptsLeft: check.attemptsLeft,
        });
    }
  }
}

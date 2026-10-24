import { Inject, Injectable, Logger } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { type EmergencyChallenge, EmergencyChallengesRepository } from '../otp/emergency-challenges.repository.js';
import { OtpChallengesRepository } from '../otp/otp-challenges.repository.js';

export type EmergencyClaim =
  | { readonly kind: 'none' }
  | { readonly kind: 'bound'; readonly challenge: EmergencyChallenge }
  | { readonly kind: 'other_device' };

/**
 * Вход сотрудника по аварийному коду администратора (RM-D-016; 09 §6.13 п. 3, SMS-035; 11 SEC-131; AC-AUTH-086):
 *
 * - `/auth/otp/request`: при живом челлендже, выданном администратором, — 202 с его `challengeId` **без** SMS, без
 *   `retireActive` и без cooldown; челлендж привязывается к `X-Device-Id` этого запроса (`claim`). Запрос с другого
 *   устройства после привязки → 409 DEVICE_MISMATCH (раскрывает лишь факт выдачи кода — допустимо по 09 §6.13).
 * - `/auth/otp/verify` — обычные правила (попытки, TTL 10 мин, одноразовость); ветвление — LoginService: только
 *   активный `staff`-владелец кода; `amr=["admin_code"]`; при установленном и не заблокированном PIN
 *   `unlocked_until = now()`; снятие `PIN_LOCKED`; аудит `auth.emergency_code.used`.
 */
@Injectable()
export class EmergencyLoginService {
  private readonly logger = new Logger('auth');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly repo: EmergencyChallengesRepository,
    private readonly challenges: OtpChallengesRepository,
  ) {}

  /** Шаг `/auth/otp/request`: найти живой аварийный челлендж номера и привязать к устройству. */
  async claim(phoneE164: string, deviceKey: string, requestId: string | null): Promise<EmergencyClaim> {
    const result = await this.db.transaction(async (tx): Promise<EmergencyClaim> => {
      // Та же сериализация, что у выпуска OTP номера (OtpService.issue) — без гонки с обычным запросом кода.
      await this.challenges.lockPhone(phoneE164, 'login_or_register', tx);
      const live = await this.repo.findLiveForPhone(phoneE164, this.clock.now(), tx);
      if (!live) return { kind: 'none' };
      if (live.deviceKey !== null && live.deviceKey !== deviceKey) return { kind: 'other_device' };
      if (!(await this.repo.bindDevice(live.challengeId, deviceKey, tx))) return { kind: 'other_device' };
      return { kind: 'bound', challenge: { ...live, deviceKey } };
    });
    if (result.kind !== 'none') {
      this.logger.log(
        {
          event: result.kind === 'bound' ? 'otp.emergency_bound' : 'otp.emergency_device_mismatch',
          ...(result.kind === 'bound' ? { challengeId: result.challenge.challengeId } : {}),
          deviceId: deviceKey,
          requestId: requestId ?? undefined,
        },
        result.kind === 'bound' ? 'otp.emergency_bound' : 'otp.emergency_device_mismatch',
      );
    }
    return result;
  }

  /** Челлендж выдан администратором (только для челленджей без `sms_outbox`). */
  forChallenge(
    challengeId: string,
    smsOutboxId: string | null,
    ex?: DbExecutor,
  ): Promise<EmergencyChallenge | undefined> {
    if (smsOutboxId !== null) return Promise.resolve(undefined);
    return this.repo.findIssued(challengeId, ex);
  }
}

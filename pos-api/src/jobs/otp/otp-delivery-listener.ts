import type pg from 'pg';
import { OtpChallengesRepository } from '../../auth/otp/otp-challenges.repository.js';
import { OtpSmsDeliveryListener } from '../../auth/otp/queued-sms-otp.provider.js';
import { type Clock, systemClock } from '../../common/auth/clock.js';
import type { AppConfig } from '../../common/config/app-config.js';
import { OtpHmacService, parseSecretRing, type SecretRing } from '../../common/crypto/index.js';
import { createDatabase, type PosDatabase } from '../../db/database.js';
import type { SmsDeliveryListener } from '../../notifications/sms/sms-delivery.listener.js';

export interface OtpDeliveryListenerOptions {
  readonly config: Pick<AppConfig, 'APP_ENV' | 'OTP_HMAC_SECRET' | 'OTP_HMAC_SECRET_VERSION'>;
  readonly pool: pg.Pool;
  readonly db?: PosDatabase;
  /** Набор секрета OTP (тот же, что у pos-api): псевдоним номера в `rate_limit_counters.subject`. */
  readonly otpSecretRing?: SecretRing;
  readonly clock?: Clock;
}

/**
 * Очередь OTP-SMS в pos-worker (INT-01; 09 §6.8, 06 §7.5): владелец OTP узнаёт итог задания `sms.send` через порт
 * `SMS_DELIVERY_LISTENER` — итог `failed` → челлендж `failed_delivery` и возврат квоты номера (как в процессе API).
 * Вне Nest: `new SmsRuntime({ ..., listener: createOtpDeliveryListener({ config, pool }) })` (src/worker.ts).
 *
 * Секрет `OTP_HMAC_SECRET` (`*_FILE`) у pos-api и pos-worker обязан совпадать: им же шифруется текст SMS в задании
 * (`SmsTextSealer`) и строится псевдоним номера; эфемерный секрет dev у каждого процесса свой.
 */
export function createOtpDeliveryListener(o: OtpDeliveryListenerOptions): SmsDeliveryListener {
  const c = o.config;
  const ring =
    o.otpSecretRing ?? parseSecretRing('OTP_HMAC_SECRET', c.OTP_HMAC_SECRET, c.OTP_HMAC_SECRET_VERSION, c.APP_ENV);
  return new OtpSmsDeliveryListener(
    new OtpChallengesRepository(o.db ?? createDatabase(o.pool)),
    new OtpHmacService(ring),
    o.clock ?? systemClock,
  );
}

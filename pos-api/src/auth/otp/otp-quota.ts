import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { RATE_LIMIT_WINDOWS } from '../../common/rate-limit/rate-limit.service.js';

/** Домен HMAC-псевдонима номера в `rate_limit_counters.subject` (07 §5.12: сырой номер запрещён). */
export const OTP_PHONE_PSEUDONYM_DOMAIN = 'phone';

/** Субъект лимитов номера RL-OTP-SEND (`otp_phone_15m`, `otp_phone_24h`). */
export function otpPhoneSubject(hmac: Pick<OtpHmacService, 'pseudonym'>, phoneE164: string): string {
  return hmac.pseudonym(OTP_PHONE_PSEUDONYM_DOMAIN, phoneE164);
}

/**
 * `failed_delivery` не учитывается в лимите номера (09 §6.8): возврат единицы в окна номера, в которые попал
 * выпуск кода (`at` — `otp_challenges.created_at`). Общая функция для процесса API (`OtpService`) и pos-worker
 * (итог задания `sms.send` → `OtpSmsDeliveryListener`, вариант доставки через очередь — INT-01).
 */
export async function releaseOtpPhoneQuota(
  ex: DbExecutor,
  hmac: Pick<OtpHmacService, 'pseudonym'>,
  phoneE164: string,
  at: Date,
): Promise<void> {
  const subject = otpPhoneSubject(hmac, phoneE164);
  for (const scope of ['otp_phone_15m', 'otp_phone_24h'] as const) {
    const len = RATE_LIMIT_WINDOWS[scope] * 1000;
    const start = new Date(Math.floor(at.getTime() / len) * len);
    await ex.execute(sql`
      UPDATE rate_limit_counters SET count = greatest(count - 1, 0), updated_at = now()
       WHERE scope = ${scope} AND subject = ${subject} AND window_start = ${start.toISOString()}::timestamptz`);
  }
}

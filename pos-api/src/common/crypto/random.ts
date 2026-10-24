import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';

/**
 * CSPRNG-утилиты (09 §5.1, §6.8, §8.2; 07 §5.61; ASVS 5.0 6.5.3). Только `node:crypto`; `Math.random` не используется.
 */

/** Длина OTP — 6 десятичных цифр, ведущие нули сохраняются (09 §5.1; NIST SP 800-63B-4). */
export const OTP_CODE_LENGTH = 6;
/** `sms_outbox.provider_message_id` — 12 символов `[A-Za-z0-9]` (R0 §18.2 п. 9; CHECK 07 §5.61). */
export const PROVIDER_MESSAGE_ID_LENGTH = 12;
/** Непрозрачный токен — 32 байта (256 бит) → base64url 43 символа (refresh, registration; 09 §8.2, 08 §2.2). */
export const OPAQUE_TOKEN_BYTES = 32;

const ALPHANUMERIC = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/** 6-значный код `000000…999999` (`crypto.randomInt` — без смещения по модулю). */
export function generateOtpCode(): string {
  return randomInt(0, 10 ** OTP_CODE_LENGTH)
    .toString()
    .padStart(OTP_CODE_LENGTH, '0');
}

/** Случайная строка `[A-Za-z0-9]{length}` с равномерным распределением символов (randomInt на символ). */
export function generateAlphanumericId(length: number = PROVIDER_MESSAGE_ID_LENGTH): string {
  if (!Number.isInteger(length) || length < 1 || length > 256) throw new RangeError('length: 1…256');
  let out = '';
  for (let i = 0; i < length; i++) out += ALPHANUMERIC[randomInt(0, ALPHANUMERIC.length)];
  return out;
}

/** Идентификатор SMS для SMSPro (`<id>` запроса /api/message = `sms_outbox.provider_message_id`). */
export function generateProviderMessageId(): string {
  return generateAlphanumericId(PROVIDER_MESSAGE_ID_LENGTH);
}

/** 256-битный непрозрачный токен в base64url без `=` (43 символа). */
export function generateOpaqueToken(bytes: number = OPAQUE_TOKEN_BYTES): string {
  if (!Number.isInteger(bytes) || bytes < 32) throw new RangeError('bytes: не менее 32 (256 бит)');
  return randomBytes(bytes).toString('base64url');
}

/** SHA-256 (refresh_hash, registration_token_hash: при 256 бит энтропии pepper не нужен — 09 §8.2). */
export function sha256(data: string | Buffer): Buffer {
  return createHash('sha256').update(data).digest();
}

/**
 * Сравнение за постоянное время. Длины выравниваются хэшированием (SHA-256 обеих сторон), поэтому время не
 * зависит ни от позиции первого расхождения, ни от разницы длин (`timingSafeEqual` бросает на разных длинах).
 */
export function constantTimeEqual(a: string | Buffer, b: string | Buffer): boolean {
  const ab = typeof a === 'string' ? Buffer.from(a, 'utf8') : a;
  const bb = typeof b === 'string' ? Buffer.from(b, 'utf8') : b;
  const eq = timingSafeEqual(sha256(ab), sha256(bb));
  return eq && ab.length === bb.length;
}

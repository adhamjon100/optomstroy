import { createHmac, timingSafeEqual } from 'node:crypto';
import type { SecretRing } from './secret-ring.js';

/**
 * HMAC для OTP (09 §5.2; D-10; ядро §17 п. 6): `code_hmac = HMAC-SHA-256(key = OTP_HMAC_SECRET[v],
 * msg = challenge_id ‖ ":" ‖ code)`; `pepper_version` хранится в `otp_challenges.pepper_version`, при ротации
 * старые челленджи доживают TTL со своей версией. Сравнение — `timingSafeEqual` (длина HMAC фиксирована).
 *
 * Тот же ключ (с разделением доменов) даёт псевдонимы ПДн для служебных ключей, где сырой номер хранить нельзя:
 * `rate_limit_counters.subject` (07 §5.12 «Телефон в subject хранится как HMAC»).
 */
export class OtpHmacService {
  constructor(private readonly ring: SecretRing) {}

  get currentVersion(): number {
    return this.ring.currentVersion;
  }

  /** HMAC кода для челленджа; `version` по умолчанию — текущая (`OTP_HMAC_SECRET_VERSION`). */
  codeHmac(challengeId: string, code: string, version: number = this.ring.currentVersion): Buffer {
    return createHmac('sha256', this.key(version)).update(`${challengeId}:${code}`, 'utf8').digest();
  }

  /** Проверка введённого кода за постоянное время. Неизвестная версия ключа → false (челлендж не принимается). */
  verifyCode(challengeId: string, code: string, storedHmac: Buffer, version: number): boolean {
    if (this.ring.get(version) === undefined || storedHmac.length !== 32) return false;
    return timingSafeEqual(this.codeHmac(challengeId, code, version), storedHmac);
  }

  /**
   * Псевдоним значения (hex, 64 символа) для служебных ключей: `HMAC(key, domain ‖ 0x00 ‖ value)`.
   * Всегда текущей версией: после ротации ключа псевдонимы меняются (счётчики лимитов начинаются заново).
   */
  pseudonym(domain: string, value: string): string {
    return createHmac('sha256', this.key(this.ring.currentVersion))
      .update(`pseudonym:${domain}\u0000${value}`, 'utf8')
      .digest('hex');
  }

  private key(version: number): Buffer {
    const k = this.ring.get(version);
    if (!k) throw new RangeError(`OTP_HMAC_SECRET: версия ${version} не настроена`);
    return k;
  }
}

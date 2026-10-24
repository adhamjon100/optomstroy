import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from 'node:crypto';
import type { SecretRing } from '../../common/crypto/index.js';

/**
 * Шифрование текста SMS в payload задания `sms.send` (09 §5.2, §5.7; SMS-022: в БД нет текста и кода).
 *
 * `sms_outbox` по 07 §5.61 не содержит `text`, а отправка асинхронна (запись `queued` + задание pg-boss в одной
 * транзакции, 06 §4.5.3) — текст должен дожить до воркера. Он кладётся в payload задания только в виде
 * AES-256-GCM, ключ — HKDF-SHA-256 от `OTP_HMAC_SECRET[v]` (секрет вне БД, ядро §17.7) с отдельным доменом,
 * AAD = `sms_outbox.id` (шифртекст нельзя переставить на другую строку). Ротация: версия ключа в токене,
 * прежние версии берутся из набора секрета до истечения TTL OTP.
 */
export class SmsTextSealError extends Error {
  override readonly name = 'SmsTextSealError';
}

const PREFIX = 'v1';
const INFO = Buffer.from('optomstroy:sms-outbox-text:v1', 'utf8');
const SALT = Buffer.from('optomstroy.sms', 'utf8');

export class SmsTextSealer {
  private readonly keys = new Map<number, Buffer>();

  constructor(private readonly ring: SecretRing) {}

  seal(smsOutboxId: string, text: string): string {
    const version = this.ring.currentVersion;
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key(version), iv);
    cipher.setAAD(Buffer.from(smsOutboxId, 'utf8'));
    const ct = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    return [
      PREFIX,
      String(version),
      iv.toString('base64url'),
      ct.toString('base64url'),
      tag.toString('base64url'),
    ].join('.');
  }

  open(smsOutboxId: string, sealed: string): string {
    const parts = sealed.split('.');
    if (parts.length !== 5 || parts[0] !== PREFIX) throw new SmsTextSealError('неверный формат шифртекста');
    const version = Number(parts[1]);
    if (!Number.isInteger(version) || this.ring.get(version) === undefined) {
      throw new SmsTextSealError('версия ключа недоступна');
    }
    try {
      const decipher = createDecipheriv('aes-256-gcm', this.key(version), Buffer.from(parts[2], 'base64url'));
      decipher.setAAD(Buffer.from(smsOutboxId, 'utf8'));
      decipher.setAuthTag(Buffer.from(parts[4], 'base64url'));
      return Buffer.concat([decipher.update(Buffer.from(parts[3], 'base64url')), decipher.final()]).toString('utf8');
    } catch {
      throw new SmsTextSealError('шифртекст не прошёл проверку подлинности');
    }
  }

  private key(version: number): Buffer {
    let k = this.keys.get(version);
    if (!k) {
      const secret = this.ring.get(version);
      if (!secret) throw new SmsTextSealError('версия ключа недоступна');
      k = Buffer.from(hkdfSync('sha256', secret, SALT, INFO, 32));
      this.keys.set(version, k);
    }
    return k;
  }
}

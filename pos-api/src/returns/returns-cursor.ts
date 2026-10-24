import { timingSafeEqual } from 'node:crypto';
import type { OtpHmacService } from '../common/crypto/otp-hmac.service.js';
import { validationFailed } from './returns.request.js';

const MAC_HEX = 32;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export interface ReturnsCursor {
  readonly createdAt: string;
  readonly id: string;
}

/**
 * Непрозрачный курсор `GET /returns` (08 §2.5): `base64url(JSON [createdAt, id]) "." mac`, mac — HMAC-псевдоним
 * (`OtpHmacService.pseudonym`, домен `cursor:returns`). Подделка → 400 `VALIDATION_FAILED` (rule `cursor`).
 */
export class ReturnsCursorCodec {
  constructor(private readonly hmac: OtpHmacService) {}

  encode(c: ReturnsCursor): string {
    const body = Buffer.from(JSON.stringify([c.createdAt, c.id]), 'utf8').toString('base64url');
    return `${body}.${this.mac(body)}`;
  }

  decode(raw: string | undefined): ReturnsCursor | undefined {
    if (raw === undefined || raw === '') return undefined;
    const bad = () => validationFailed([{ field: 'cursor', rule: 'cursor', message: 'Курсор недействителен.' }]);
    const [body, mac, ...rest] = raw.split('.');
    if (!body || !mac || rest.length > 0 || mac.length !== MAC_HEX) throw bad();
    if (!timingSafeEqual(Buffer.from(this.mac(body), 'utf8'), Buffer.from(mac, 'utf8'))) throw bad();
    try {
      const v: unknown = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
      if (
        Array.isArray(v) &&
        v.length === 2 &&
        typeof v[0] === 'string' &&
        typeof v[1] === 'string' &&
        !Number.isNaN(Date.parse(v[0])) &&
        UUID_RE.test(v[1])
      ) {
        return { createdAt: v[0], id: v[1] };
      }
    } catch {
      // ниже — общий ответ
    }
    throw bad();
  }

  private mac(body: string): string {
    return this.hmac.pseudonym('cursor:returns', body).slice(0, MAC_HEX);
  }
}

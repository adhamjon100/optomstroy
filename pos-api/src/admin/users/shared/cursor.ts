import { timingSafeEqual } from 'node:crypto';
import { OtpHmacService } from '../../../common/crypto/otp-hmac.service.js';
import { ProblemException } from '../../../common/problem-details/problem.exception.js';

/** Позиция keyset-пагинации списков админ-раздела: `(created_at DESC, id DESC)`. */
export interface KeysetPosition {
  readonly createdAt: string;
  readonly id: string;
}

const MAC_HEX_LENGTH = 32;

/**
 * Непрозрачный курсор (08 §2.5, параметр `Cursor`): `base64url(JSON) "." mac`, где mac — HMAC-псевдоним
 * (`OtpHmacService.pseudonym`, домен `cursor:<list>`). Подделанный курсор → `400 VALIDATION_FAILED rule cursor`.
 * После ротации `OTP_HMAC_SECRET` старые курсоры недействительны — клиент начинает список заново.
 */
export class AdminCursorCodec {
  constructor(
    private readonly hmac: OtpHmacService,
    private readonly list: string,
  ) {}

  encode(pos: KeysetPosition): string {
    const body = Buffer.from(JSON.stringify([pos.createdAt, pos.id]), 'utf8').toString('base64url');
    return `${body}.${this.mac(body)}`;
  }

  decode(cursor: string | undefined): KeysetPosition | undefined {
    if (cursor === undefined || cursor === '') return undefined;
    const [body, mac, ...rest] = cursor.split('.');
    if (!body || !mac || rest.length > 0 || mac.length !== MAC_HEX_LENGTH) throw invalidCursor();
    const expected = Buffer.from(this.mac(body), 'utf8');
    if (!timingSafeEqual(expected, Buffer.from(mac, 'utf8'))) throw invalidCursor();
    try {
      const parsed: unknown = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
      if (
        Array.isArray(parsed) &&
        parsed.length === 2 &&
        typeof parsed[0] === 'string' &&
        typeof parsed[1] === 'string' &&
        !Number.isNaN(Date.parse(parsed[0]))
      ) {
        return { createdAt: parsed[0], id: parsed[1] };
      }
    } catch {
      // ниже — общий ответ
    }
    throw invalidCursor();
  }

  private mac(body: string): string {
    return this.hmac.pseudonym(`cursor:${this.list}`, body).slice(0, MAC_HEX_LENGTH);
  }
}

function invalidCursor(): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Курсор недействителен.',
    errors: [{ field: 'cursor', rule: 'cursor', message: 'Курсор недействителен — запросите список заново.' }],
  });
}

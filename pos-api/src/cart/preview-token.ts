import { createHash, timingSafeEqual } from 'node:crypto';
import type { OtpHmacService } from '../common/crypto/otp-hmac.service.js';

/**
 * `CheckoutPreview.previewToken` (08 §3.8 — [НЕ ПОДТВЕРЖДЕНО — предложение]): непрозрачный токен, доказывающий, что
 * продавец видел именно эти итоги. Подпись — HMAC-SHA-256 ключом, выведенным из текущей версии `OTP_HMAC_SECRET` с
 * меткой назначения (как подпись курсоров, 08 §2.5; отдельного секрета нет — 16 §4.3). Состав подписи: корзина,
 * `cartRowVersion`, итог, способ оплаты, `validUntil`, `onecCheck.at` и SHA-256 результата `/check` (B-AR-07).
 */
export const PREVIEW_TOKEN_DOMAIN = 'pos-api:checkout-preview:v1'; // check-secrets: allow — метка назначения HMAC, не секрет

export interface PreviewTokenPayload {
  readonly cartId: string;
  readonly cartRowVersion: number;
  readonly total: string;
  readonly paymentMethod: string;
  readonly validUntil: string;
  readonly onecCheckAt: string | null;
  readonly onecResult: string;
}

function b64url(s: string): string {
  return Buffer.from(s, 'utf8').toString('base64url');
}

export function signPreviewToken(hmac: OtpHmacService, p: PreviewTokenPayload): string {
  const body = b64url(
    JSON.stringify({
      c: p.cartId,
      v: p.cartRowVersion,
      t: p.total,
      m: p.paymentMethod,
      u: p.validUntil,
      o: p.onecCheckAt,
      h: createHash('sha256').update(p.onecResult).digest('hex').slice(0, 32),
    }),
  );
  return `${body}.${hmac.pseudonym(PREVIEW_TOKEN_DOMAIN, body)}`;
}

/** Проверка подписи и срока; `null` — токен подделан, повреждён или истёк. */
export function verifyPreviewToken(
  hmac: OtpHmacService,
  token: string,
  now: Date,
): { cartId: string; cartRowVersion: number; total: string; paymentMethod: string; validUntil: string } | null {
  const [body, mac] = token.split('.');
  if (!body || !mac) return null;
  const expected = Buffer.from(hmac.pseudonym(PREVIEW_TOKEN_DOMAIN, body), 'utf8');
  const given = Buffer.from(mac, 'utf8');
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return null;
  try {
    const p = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as Record<string, unknown>;
    if (typeof p.u !== 'string' || new Date(p.u).getTime() < now.getTime()) return null;
    return {
      cartId: String(p.c),
      cartRowVersion: Number(p.v),
      total: String(p.t),
      paymentMethod: String(p.m),
      validUntil: p.u,
    };
  } catch {
    return null;
  }
}

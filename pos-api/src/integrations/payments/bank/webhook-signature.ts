import { createHmac, timingSafeEqual } from 'node:crypto';

/**
 * Подпись вебхука банка — вариант (а) 08 §6: `X-Signature = HMAC-SHA256(secret, timestamp + "." + rawBody)` в hex,
 * `X-Timestamp` — Unix-время в секундах (или ISO 8601), допуск ±5 мин (защита от повтора). Подпись считается по
 * **сырому** телу запроса (байты как пришли), а не по разобранному JSON.
 * Формат настоящего банка — `[НЕ ПОДТВЕРЖДЕНО: Q-382]` (имена заголовков, кодировка подписи, алгоритм); заменяется
 * при подключении банка, инварианты (сырое тело, окно времени, сравнение за постоянное время) остаются.
 */
export const WEBHOOK_SIGNATURE_HEADER = 'x-signature';
export const WEBHOOK_TIMESTAMP_HEADER = 'x-timestamp';
/** Допуск по времени подписи (08 §6). */
export const WEBHOOK_TOLERANCE_MS = 5 * 60_000;

export function signWebhook(secret: string, timestamp: string, rawBody: Buffer | string): string {
  return createHmac('sha256', secret)
    .update(`${timestamp}.`, 'utf8')
    .update(typeof rawBody === 'string' ? Buffer.from(rawBody, 'utf8') : rawBody)
    .digest('hex');
}

/** Метка времени → мс; `null` — формат не распознан. */
export function parseWebhookTimestamp(v: string): number | null {
  const t = v.trim();
  if (/^\d{9,11}$/.test(t)) return Number(t) * 1000; // money-double: allow — секунды Unix, не сумма
  if (/^\d{4}-\d{2}-\d{2}T/.test(t)) {
    const ms = Date.parse(t);
    return Number.isNaN(ms) ? null : ms;
  }
  return null;
}

export type SignatureCheck =
  | { readonly ok: true }
  | { readonly ok: false; readonly reason: 'missing' | 'timestamp_format' | 'timestamp_skew' | 'mismatch' };

export function verifyWebhookSignature(input: {
  readonly secret: string;
  readonly rawBody: Buffer;
  readonly signature: string | undefined;
  readonly timestamp: string | undefined;
  readonly nowMs: number;
}): SignatureCheck {
  const sig = input.signature
    ?.trim()
    .toLowerCase()
    .replace(/^sha256=/, '');
  const ts = input.timestamp?.trim();
  if (!sig || !ts) return { ok: false, reason: 'missing' };
  const at = parseWebhookTimestamp(ts);
  if (at === null) return { ok: false, reason: 'timestamp_format' };
  if (Math.abs(input.nowMs - at) > WEBHOOK_TOLERANCE_MS) return { ok: false, reason: 'timestamp_skew' };
  if (!/^[0-9a-f]{64}$/.test(sig)) return { ok: false, reason: 'mismatch' };
  const expected = Buffer.from(signWebhook(input.secret, ts, input.rawBody), 'hex');
  const got = Buffer.from(sig, 'hex');
  return expected.length === got.length && timingSafeEqual(expected, got)
    ? { ok: true }
    : { ok: false, reason: 'mismatch' };
}

/**
 * Redaction и маскирование ПДн в логах (RM-C-010; 11 SEC-062, SEC-063; NFR-LOG-001).
 * Применяется ко всем объектам записи до сериализации (pino `formatters.log`) — «маскирование до записи».
 *
 * - Ключи-секреты (денай-лист SEC-062: otp, code, password, pin, token, refresh*, authorization, cookie, pwd,
 *   apiKey, secret, fullName, birthYear, debt, receivable*) → `[REDACTED]`.
 * - Ключи-телефоны (`phone*`, `msisdn`) → маска `+996 7** *** *00` (SEC-063, ядро §19.2).
 * - Строковые значения любых ключей: последовательности, похожие на телефон, маскируются (URL с `?q=0555…`,
 *   тексты ошибок провайдеров); переводы строк и управляющие символы экранируются (log injection, SEC-066).
 */
import { IncomingMessage, ServerResponse } from 'node:http';

export const REDACTED = '[REDACTED]';

const EXACT_SECRET_KEYS = new Set([
  'otp',
  'code',
  'pin',
  'pwd',
  'otpcode',
  'smscode',
  'newpin',
  'oldpin',
  'text',
  'body',
]);
const SECRET_KEY_PARTS = [
  'password',
  'passwd',
  'token',
  'refresh',
  'authorization',
  'cookie',
  'apikey',
  'api_key',
  'secret',
  'fullname',
  'full_name',
  'birthyear',
  'birth_year',
  'debt',
  'receivable',
  'pepper',
  'hmac',
  'privatekey',
  'private_key',
];
const PHONE_KEY_RE = /^(phone|msisdn|phonee164|phone_e164|newphone|oldphone|phonenumber|phone_number|to)$/i;

/** Машинные коды ошибок (`code: "PRICE_CHANGED"`, `code: "ECONNREFUSED"`) — не секрет, их оставляем. */
const MACHINE_CODE_RE = /^[A-Z][A-Z0-9_]{2,}$/;

export function isSecretKey(key: string): boolean {
  const k = key.toLowerCase();
  if (EXACT_SECRET_KEYS.has(k)) return true;
  if (k.endsWith('pin') && k.length <= 8) return true;
  return SECRET_KEY_PARTS.some((p) => k.includes(p));
}

export function isPhoneKey(key: string): boolean {
  return PHONE_KEY_RE.test(key);
}

/**
 * Маска телефона SEC-063: первая и последние 2 цифры национального номера, `+996 7** *** *00`.
 * Для номеров не КР (или неразборчивых) остаются только последние 2 цифры.
 */
export function maskPhone(value: string): string {
  if (value.includes('*')) return value; // уже маскирован (идемпотентность при двойном проходе)
  const digits = value.replace(/\D/g, '');
  let national: string;
  if (digits.length === 12 && digits.startsWith('996')) national = digits.slice(3);
  else if (digits.length === 10 && digits.startsWith('0')) national = digits.slice(1);
  else if (digits.length === 9) national = digits;
  else {
    const tail = digits.slice(-2);
    return digits.length >= 4 ? `***${tail}` : '***';
  }
  // national: 9 цифр → «7** *** *00»
  return `+996 ${national.slice(0, 1)}** *** *${national.slice(-2)}`;
}

/** Телефоноподобные последовательности в произвольной строке: +996XXXXXXXXX, 996XXXXXXXXX, 0XXXXXXXXX, 9 цифр подряд. */
const PHONE_IN_TEXT_RE = /(?<![\dA-Za-z])(?:\+?996[\s-]?|0)?\d{3}[\s-]?\d{3}[\s-]?\d{3}(?![\dA-Za-z])/g;
/** UUID не трогаем — сначала «прячем» их, затем маскируем телефоны. */
const UUID_RE = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g;

export function maskPhonesInText(text: string): string {
  const uuids: string[] = [];
  const hidden = text.replace(UUID_RE, (m) => {
    uuids.push(m);
    return `\u0000${uuids.length - 1}\u0000`;
  });
  const masked = hidden.replace(PHONE_IN_TEXT_RE, (m) => maskPhone(m));
  // eslint-disable-next-line no-control-regex
  return masked.replace(/\u0000(\d+)\u0000/g, (_m, i: string) => uuids[Number(i)] ?? '');
}

/** Экранирование CR/LF и управляющих символов (SEC-066). */
export function escapeControlChars(text: string): string {
  return (
    text
      // eslint-disable-next-line no-control-regex
      .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '')
      .replace(/\r/g, '\\r')
      .replace(/\n/g, '\\n')
  );
}

/** Коды в тексте: «OTP 583921», «Kod: 583921», «code=1234», «PIN 1234» → значение заменяется (SEC-062, второй слой). */
const CODE_IN_TEXT_RE = /(?<![\p{L}\d])(otp|code|kod|pin|код|пин)(\s*[:=]?\s*)\d{4,8}(?!\d)/giu;

export function maskCodesInText(text: string): string {
  return text.replace(CODE_IN_TEXT_RE, (_m, word: string, sep: string) => `${word}${sep}${REDACTED}`);
}

export function sanitizeString(text: string): string {
  return escapeControlChars(maskCodesInText(maskPhonesInText(text)));
}

const MAX_DEPTH = 8;

/**
 * Ключи верхнего уровня записи, которые pino-http передаёт сырыми `IncomingMessage`/`ServerResponse` и которые
 * обрабатывают сериализаторы `req`/`res` (logger.config.ts: метод, URL с маской, ipPrefix, версия клиента, код
 * ответа — без заголовков и тел). Такие объекты не копируются: глубокая копия `ServerResponse` на 8 уровней — это
 * 8–10 % CPU процесса API на каждый запрос (E_spec_questions EQ-SRCH-16) и вдобавок тянет в запись заголовки.
 */
const HTTP_SERIALIZED_KEYS: ReadonlySet<string> = new Set(['req', 'res']);

function isHttpMessage(value: object): value is IncomingMessage | ServerResponse {
  return value instanceof IncomingMessage || value instanceof ServerResponse;
}

/**
 * Глубокая копия объекта лога с redaction; исходный объект не изменяется. Сырые объекты HTTP (`IncomingMessage`,
 * `ServerResponse`) не обходятся (EQ-SRCH-16): под ключами `req`/`res` верхнего уровня передаются сериализаторам
 * pino как есть, в любом другом месте заменяются меткой `[IncomingMessage]`/`[ServerResponse]` — без заголовков
 * (`Authorization`, `Cookie`, `X-Step-Up-Token`), тел и адресов клиента.
 */
export function sanitizeLogValue(value: unknown, key?: string, depth = 0, seen = new WeakSet<object>()): unknown {
  if (key !== undefined) {
    if (isPhoneKey(key) && (typeof value === 'string' || typeof value === 'number')) return maskPhone(String(value));
    if (isSecretKey(key)) {
      if (key.toLowerCase() === 'code' && typeof value === 'string' && MACHINE_CODE_RE.test(value)) return value;
      if (value === undefined || value === null) return value;
      return REDACTED;
    }
  }
  if (typeof value === 'string') return sanitizeString(value);
  if (value === null || typeof value !== 'object') return value;
  if (isHttpMessage(value)) {
    if (depth === 1 && key !== undefined && HTTP_SERIALIZED_KEYS.has(key)) return value;
    return value instanceof IncomingMessage ? '[IncomingMessage]' : '[ServerResponse]';
  }
  if (depth >= MAX_DEPTH) return '[Object]';
  if (seen.has(value)) return '[Circular]';
  seen.add(value);
  if (value instanceof Error) {
    // Копия с тем же прототипом: сериализатор pino `err` сохраняет тип (constructor.name), а текст и стек маскируются.
    const copy = Object.create(Object.getPrototypeOf(value) as object) as Error & Record<string, unknown>;
    for (const [k, v] of Object.entries(value)) copy[k] = sanitizeLogValue(v, k, depth + 1, seen);
    Object.defineProperty(copy, 'message', { value: sanitizeString(value.message), enumerable: true });
    if (value.stack) Object.defineProperty(copy, 'stack', { value: sanitizeString(value.stack), enumerable: true });
    return copy;
  }
  if (Array.isArray(value)) return value.map((v) => sanitizeLogValue(v, undefined, depth + 1, seen));
  if (value instanceof Date) return value.toISOString();
  if (Buffer.isBuffer(value)) return `[Buffer ${value.length}]`;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>))
    out[k] = sanitizeLogValue(v, k, depth + 1, seen);
  return out;
}

/** Усечение IP до /24 (IPv4) или /48 (IPv6) для поля `ipPrefix` (SEC-063). */
export function ipPrefix(ip: string | undefined): string | undefined {
  if (!ip) return undefined;
  const v4 = ip.replace(/^::ffff:/, '');
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}$/.exec(v4);
  if (m) return `${m[1]}.${m[2]}.${m[3]}.0/24`;
  if (ip.includes(':')) {
    const parts = ip.split(':').filter((p) => p !== '');
    return `${parts.slice(0, 3).join(':')}::/48`;
  }
  return undefined;
}

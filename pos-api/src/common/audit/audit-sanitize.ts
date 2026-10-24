/**
 * Очистка `before/after` записи аудита (11 SEC-078, SEC-063; 07 §9.5; DATA-236): в аудит не пишутся OTP, токены,
 * PIN/пароли и их хэши/HMAC, секреты, тела SMS и фото; телефоны — маска `+996 *** ** 67` (как SQL-функция
 * `audit_mask_phone`), ФИО — инициалы. Суммы и прочие поля — как есть. Ключ-секрет удаляется вместе со значением.
 */
export const PHONE_MASK_PREFIX = '+996 *** ** ';
const MAX_DEPTH = 8;

const SECRET_EXACT = new Set(['otp', 'code', 'pin', 'pwd', 'text', 'body', 'photo', 'image', 'sms', 'smstext']);
const SECRET_PARTS = [
  'password',
  'passwd',
  'token',
  'refresh',
  'authorization',
  'cookie',
  'apikey',
  'api_key',
  'secret',
  'pepper',
  'hmac',
  'pinhash',
  'pin_hash',
  'privatekey',
  'private_key',
  'otpcode',
  'otp_code',
  'smscode',
  'sms_code',
  'biometric_assertion',
  'biometricassertion',
];
/** Идентификаторы, не являющиеся секретом (11 §7.2.1: `integration.auth_failed` — `token_id`). */
const SAFE_KEYS = new Set(['token_id', 'tokenid', 'token_kind', 'tokenkind']);
const NAME_KEYS = new Set(['fullname', 'full_name', 'displayname', 'display_name', 'name_full']);
const JWT_LIKE = /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/g;
const FULL_PHONE = /\+?996\d{9}\b/g;

export function isAuditSecretKey(key: string): boolean {
  const k = key.toLowerCase();
  if (SAFE_KEYS.has(k)) return false;
  if (SECRET_EXACT.has(k)) return true;
  if (k.endsWith('pin') && k.length <= 8) return true; // newPin, oldPin, appPin
  return SECRET_PARTS.some((p) => k.includes(p));
}

export function isAuditPhoneKey(key: string): boolean {
  const k = key.toLowerCase();
  return k.includes('phone') && !k.includes('hmac');
}

/** Маска 07 §9.5: «+996 *** ** 67» (последние 2 цифры); уже маскированное значение не меняется. */
export function maskPhoneForAudit(value: string): string {
  if (value.startsWith(PHONE_MASK_PREFIX)) return value;
  const digits = value.replace(/\D/g, '');
  return `${PHONE_MASK_PREFIX}${digits.slice(-2)}`;
}

/** «Иванов Иван Иванович» → «И. И. И.» (SEC-063, 07 §15.2 п. 5). */
export function initialsOf(value: string): string {
  return value
    .split(/\s+/)
    .filter((w) => w.length > 0)
    .map((w) => `${Array.from(w)[0]?.toUpperCase() ?? ''}.`)
    .join(' ');
}

function sanitizeString(v: string): string {
  return v.replace(JWT_LIKE, '[REDACTED]').replace(FULL_PHONE, (m) => maskPhoneForAudit(m));
}

function walk(value: unknown, depth: number): unknown {
  if (value === null || value === undefined) return value ?? null;
  if (typeof value === 'string') return sanitizeString(value);
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  if (typeof value === 'bigint') return value.toString();
  if (value instanceof Date) return value.toISOString();
  if (Buffer.isBuffer(value)) return '[BINARY]';
  if (depth >= MAX_DEPTH) return '[TRUNCATED]';
  if (Array.isArray(value)) return value.map((v) => walk(v, depth + 1));
  if (typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (v === undefined || isAuditSecretKey(k)) continue;
      if (isAuditPhoneKey(k)) {
        out[k] =
          typeof v === 'string'
            ? maskPhoneForAudit(v)
            : Array.isArray(v)
              ? v.map((e) => (typeof e === 'string' ? maskPhoneForAudit(e) : walk(e, depth + 1)))
              : walk(v, depth + 1);
      } else if (NAME_KEYS.has(k.toLowerCase()) && typeof v === 'string') {
        out[k] = initialsOf(v);
      } else {
        out[k] = walk(v, depth + 1);
      }
    }
    return out;
  }
  return null;
}

/** Очищенный JSON-объект или `null` (нет данных). Верхний уровень — только объект (07 §5.57: JSONB-объект). */
export function sanitizeAuditPayload(
  value: Readonly<Record<string, unknown>> | null | undefined,
): Record<string, unknown> | null {
  if (value === null || value === undefined) return null;
  const cleaned = walk(value, 0) as Record<string, unknown>;
  return Object.keys(cleaned).length === 0 ? null : cleaned;
}

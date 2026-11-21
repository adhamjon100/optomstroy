import { constants, createPublicKey, type KeyObject, verify } from 'node:crypto';
import type { AppConfig } from '../config/app-config.js';
import { bySubjectKind, type SubjectKind } from './subject-kind.js';

/**
 * Вход по ключу Windows Hello без PIN приложения — вариант W2 (15 ADR-116 п. 3, п. 4; ответ владельца 2026-11-08 на
 * Q-355 «Лицо без PIN (Рекоменд.)»; 09 §9.2 «Вход по ключу Windows Hello», BIO-038…BIO-041; 08 §4.1.8, §4.1.10,
 * §4.3.6, API-196…API-199; 07 §5.66 `hello_keys`, DATA-172; 11 SEC-146, RR-10). Закрытый ключ RSA-2048 создаёт Windows
 * Hello (`KeyCredentialManager`) или, в веб-демо, браузер на Windows (WebCrypto под ключом из PRF passkey, источник
 * `webauthn_prf`); сервер хранит только открытый ключ (SPKI) и проверяет подпись одноразового challenge.
 *
 * Правила и криптография, общие для модулей auth (challenge, разблокировка, вход по SMS, подключение планшета), profile
 * (`POST /me/biometrics`, `GET /me`, `DELETE /me/pin`) и admin (`logout-all`): файл без зависимостей от модулей D-06
 * (06 §7.4, MOD-022), как `weak-biometrics.ts`.
 */
export type HelloKeyMode = AppConfig['AUTH_WINDOWS_HELLO_KEY'];

/** Префикс назначения строки challenge (08 §4.1.10): подписываются байты UTF-8 всей строки. */
export const HELLO_CHALLENGE_PREFIX = 'optomstroy-hello-unlock/v1:';
/** 32 байта CSPRNG (07 §5.66 CHECK `hello_keys_challenge_chk`). */
export const HELLO_CHALLENGE_BYTES = 32;
/** Срок challenge — 120 с (08 §4.1.10; 09 BIO-039). */
export const HELLO_CHALLENGE_TTL_MS = 120_000;
/**
 * Окно правила `personal` — 30 дней (09 BIO-040; 07 §5.66 «Правило `personal`»): толкование исполнителя, срок —
 * НЕ ПОДТВЕРЖДЕНО (15 ADR-116 п. 3).
 */
export const HELLO_PERSONAL_WINDOW_MS = 30 * 24 * 3600_000;

/** Длина SPKI DER (07 §5.66 CHECK `hello_keys_public_key_len_chk`) и модуля RSA (08 §4.3.6: 2048…4096 бит). */
const SPKI_MIN_BYTES = 256;
const SPKI_MAX_BYTES = 1024;
const RSA_MIN_BITS = 2048;
const RSA_MAX_BITS = 4096;
const RSA_EXPONENT = 65537n;
const BASE64URL = /^[A-Za-z0-9_-]+$/;

/**
 * Разрешает ли `AUTH_WINDOWS_HELLO_KEY` ключ этому виду субъекта: `off` — никому; `personal` и `all` — сотрудникам и
 * покупателям (правило `personal` проверяется отдельно, по установке). Планшет магазина биометрию и ключ не получает
 * ни в каком виде (09 BIO-037). Исчерпывающий разбор вида (06 ARCH-065).
 */
export function helloKeyAllowedFor(mode: HelloKeyMode, kind: SubjectKind): boolean {
  const on = mode !== 'off';
  return bySubjectKind(kind, { staff: on, customer: on, kiosk: false });
}

/** Строка challenge для подписи: префикс назначения и base64url (без `=`) 32 байт (08 §4.1.10). */
export function helloChallengeString(bytes: Buffer): string {
  return `${HELLO_CHALLENGE_PREFIX}${bytes.toString('base64url')}`;
}

/** base64url без `=` → байты; строка вне алфавита или с «хвостом» (не каноническая) — `null`. */
function decodeBase64Url(value: string): Buffer | null {
  if (!BASE64URL.test(value)) return null;
  const bytes = Buffer.from(value, 'base64url');
  return bytes.toString('base64url') === value ? bytes : null;
}

/**
 * Открытый ключ `POST /me/biometrics {helloKey.publicKey}` (08 §4.3.6; 07 §5.66): `X509SubjectPublicKeyInfo` (DER,
 * base64url без `=`) ключа RSA (не RSA-PSS) 2048…4096 бит с экспонентой 65537. Подходит — DER для `hello_keys`,
 * иначе `null` (`400 VALIDATION_FAILED`, rule `hello_key_format`).
 */
export function parseHelloPublicKey(publicKey: string): Buffer | null {
  const der = decodeBase64Url(publicKey);
  if (!der || der.length < SPKI_MIN_BYTES || der.length > SPKI_MAX_BYTES) return null;
  let key: KeyObject;
  try {
    key = createPublicKey({ key: der, format: 'der', type: 'spki' });
  } catch {
    return null;
  }
  if (key.asymmetricKeyType !== 'rsa') return null;
  const bits = key.asymmetricKeyDetails?.modulusLength ?? 0;
  if (bits < RSA_MIN_BITS || bits > RSA_MAX_BITS) return null;
  if (key.asymmetricKeyDetails?.publicExponent !== RSA_EXPONENT) return null;
  return der;
}

/**
 * Подпись `POST /auth/unlock {method: hello_key, signature}` (08 §4.1.8; 11 SEC-146): RSASSA-PKCS1-v1_5 с SHA-256
 * открытым ключом `hello_keys.public_key` над байтами UTF-8 строки challenge. Неверная, не base64url или не той длины —
 * `false` (исключение не выходит наружу: ответ один — `hello_key_invalid`).
 */
export function verifyHelloSignature(publicKeyDer: Buffer, challenge: string, signature: string): boolean {
  const sig = decodeBase64Url(signature);
  if (!sig) return false;
  try {
    const key = createPublicKey({ key: publicKeyDer, format: 'der', type: 'spki' });
    return verify('sha256', Buffer.from(challenge, 'utf8'), { key, padding: constants.RSA_PKCS1_PADDING }, sig);
  } catch {
    return false;
  }
}

import { parsePhoneNumberFromString } from 'libphonenumber-js/max';
import { maskPhone } from '../../common/logging/redaction.js';

/**
 * Серверная нормализация номера КР (09 §3.4; 08 §2.14 rule `phone_e164`): принимает `+996XXXXXXXXX`, `996…`, `0…`,
 * 9 цифр, с пробелами/скобками/дефисами/точками; результат — только E.164 `+996XXXXXXXXX`. Все лимиты, поиск
 * пользователя и `otp_challenges.phone_e164` работают с нормализованным значением (обход лимита сменой записи
 * невозможен — R6 SEC-AUTH-005).
 *
 * Тип номера проверяется по метаданным libphonenumber (`libphonenumber-js/max`, 09 §3.4): допускаются только
 * действительные номера КР типа `MOBILE` (или `FIXED_LINE_OR_MOBILE`); стационарные и несуществующие — `null`
 * (D_spec_questions A-03 закрыт подключением зависимости).
 */
export function normalizeKgPhone(input: unknown): string | null {
  if (typeof input !== 'string' || input.length === 0 || input.length > 32) return null;
  const compact = input.replace(/[\s().-]/g, '');
  const m = /^(?:\+996|996|0)?(\d{9})$/.exec(compact);
  const national = m?.[1];
  if (national === undefined || !isKgMobileNational(national)) return null;
  return `+996${national}`;
}

function isKgMobileNational(national: string): boolean {
  const parsed = parsePhoneNumberFromString(`+996${national}`);
  if (parsed === undefined || parsed.country !== 'KG' || !parsed.isValid()) return false;
  const type = parsed.getType();
  return type === 'MOBILE' || type === 'FIXED_LINE_OR_MOBILE';
}

/** `phoneMasked` (08 §2.14, ядро §19.2): `+996 7** *** *01`. */
export function phoneMasked(e164: string): string {
  return maskPhone(e164);
}

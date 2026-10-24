/**
 * Маска телефона в ответах API (`PhoneMasked`, 08 §2.14; ядро §19.2): первая цифра абонентского номера и две
 * последние, остальное `*`: `+996700000001` → `+996 7** *** *01`. Аудит маскирует иначе (`+996 *** ** 01`,
 * common/audit) — это разные форматы разных документов (07 §9.5 и 08 §2.14).
 */
export function maskPhone(e164: string | null | undefined): string {
  if (!e164) return '';
  const digits = e164.replace(/\D/g, '');
  const subscriber = digits.startsWith('996') ? digits.slice(3) : digits;
  if (subscriber.length < 3) return '+996 *** *** ***';
  const first = subscriber[0] ?? '*';
  const last2 = subscriber.slice(-2);
  return `+996 ${first}** *** *${last2}`;
}

/** Номер для ответа `AdminUser.phoneMasked`: полный E.164 только для `admin` (08 §4.18.1), иначе — маска. */
export function phoneForViewer(e164: string | null | undefined, viewerIsAdmin: boolean): string | undefined {
  if (!e164) return undefined;
  return viewerIsAdmin ? e164 : maskPhone(e164);
}

/** Нормализация ввода: пробелы, скобки, дефисы удаляются до проверки `^\+996\d{9}$` (08 §2.14). */
export function normalizePhone(raw: unknown): unknown {
  if (typeof raw !== 'string') return raw;
  return raw.replace(/[\s()-]/g, '');
}

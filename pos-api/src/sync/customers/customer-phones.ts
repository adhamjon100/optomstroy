/**
 * Нормализация телефонов клиентов 1С (05 ONEC-012, AC-ONEC-012: `0700123456` и `+996700123456` — один номер;
 * 07 §5.29 `customer_contacts.value_norm`): элемент `ContactPhone` контракта 1С — `phone` (E.164 или `null`) и
 * `presentation` (как в 1С). Номер КР → `+996XXXXXXXXX`; иной корректный E.164 — как есть; нераспознанный — `null`.
 */
export interface OnecContactPhone {
  readonly e164: string | null;
  readonly raw: string;
}

const E164 = /^\+[1-9]\d{7,14}$/;

export function normalizeKgPhone(value: string): string | null {
  const digits = value.replace(/\D/g, '');
  if (digits.length === 12 && digits.startsWith('996')) return `+${digits}`;
  if (digits.length === 10 && digits.startsWith('0')) return `+996${digits.slice(1)}`;
  if (digits.length === 9) return `+996${digits}`;
  return null;
}

export function parseContactPhones(raw: unknown): OnecContactPhone[] {
  if (!Array.isArray(raw)) return [];
  const out: OnecContactPhone[] = [];
  for (const p of raw) {
    if (typeof p !== 'object' || p === null) continue;
    const o = p as Record<string, unknown>;
    const phone = typeof o.phone === 'string' ? o.phone.trim() : null;
    const presentation = typeof o.presentation === 'string' ? o.presentation.trim() : '';
    let e164: string | null = null;
    if (phone && E164.test(phone)) e164 = phone.startsWith('+996') ? normalizeKgPhone(phone) : phone;
    if (!e164 && presentation) e164 = normalizeKgPhone(presentation);
    if (!e164 && phone) e164 = normalizeKgPhone(phone);
    const value = presentation || phone || '';
    if (value === '' && !e164) continue;
    if (e164 && out.some((x) => x.e164 === e164)) continue;
    out.push({ e164, raw: value });
  }
  return out;
}

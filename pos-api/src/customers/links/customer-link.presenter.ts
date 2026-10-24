import { maskPhone } from '../../common/logging/redaction.js';
import type { CustomerCardRow, CustomerLinkRow } from './customer-links.repository.js';

/**
 * Представление привязок и карточек (08 §3.7 `CustomerLink`, §4.2.2 `RegistrationCustomerMatch`, §4.11.1/§4.11.7).
 * Правила раскрытия (09 REG-031/REG-032, 11 SEC-030 (в), SEC-031): до `confirmed` пользователь видит только
 * маскированное наименование карточки — без `customer.id`, полного имени, телефонов и финансов.
 */

/** Формы собственности КР/СНГ в начале наименования (`ОсОО «…»`, `ИП …`). */
const LEGAL_FORMS = [
  'ОсОО',
  'ОсДО',
  'ООО',
  'ОАО',
  'ЗАО',
  'ОДО',
  'АО',
  'ИП',
  'ЧП',
  'ОО',
  'ОФ',
  'ГП',
  'МП',
  'ПК',
  'КХ',
  'ФХ',
];

interface ParsedName {
  readonly form: string | null;
  readonly core: string;
  readonly quoted: boolean;
}

export function parseCustomerName(name: string): ParsedName {
  let rest = name.trim().replace(/\s+/g, ' ');
  let form: string | null = null;
  for (const f of LEGAL_FORMS) {
    if (rest === f) break;
    if (rest.startsWith(`${f} `) || rest.startsWith(`${f}«`) || rest.startsWith(`${f}"`)) {
      form = f;
      rest = rest.slice(f.length).trim();
      break;
    }
  }
  const m = /^[«"“„'](.*?)[»"”“']?$/u.exec(rest);
  if (m && m[1] !== undefined && m[1].trim() !== '') return { form, core: m[1].trim(), quoted: true };
  return { form, core: rest, quoted: false };
}

/** Отображаемое имя карточки (08 §3.7 `displayName`): без формы собственности и кавычек. */
export function customerDisplayName(name: string): string {
  const p = parseCustomerName(name);
  return p.core !== '' ? p.core : name.trim();
}

/**
 * `displayNameMasked` (08 §4.2.2): форма собственности + первые 3 символа значимой части + `***`
 * (`ОсОО «Стр***»`, `Аса***`).
 */
export function maskCustomerName(name: string): string {
  const p = parseCustomerName(name);
  const head = Array.from(p.core).slice(0, 3).join('');
  const masked = p.quoted ? `«${head}***»` : `${head}***`;
  return p.form ? `${p.form} ${masked}` : masked;
}

/**
 * Признак `phones[].verified` (08 §3.7: «номер подтверждён в 1С/при привязке аккаунта»; отдельного столбца нет —
 * 07 §5.29). В R1 подтверждённым считается **основной** телефон карточки, полученной из 1С полной синхронизацией
 * (`source = onec`, `onec_ref` и `synced_at` заданы). Телефон карточки POS (`source = pos`), второй контакт и строка
 * реплики, созданная по ответу поиска 1С без синхронизации, — `verified = false`
 * (docs/stages/D_spec_questions.md, LNK-01).
 */
export function isPhoneVerified(card: CustomerCardRow, phoneE164: string): boolean {
  return (
    card.source === 'onec' &&
    card.onecRef !== null &&
    card.syncedAt !== null &&
    card.primaryPhoneE164 !== null &&
    card.primaryPhoneE164 === phoneE164
  );
}

/** Телефоны карточки для DTO `Customer.phones[{value, verified}]` (роли с правом на полные телефоны). */
export function cardPhones(card: CustomerCardRow): { value: string; verified: boolean }[] {
  const all = new Set<string>();
  if (card.primaryPhoneE164) all.add(card.primaryPhoneE164);
  for (const p of card.phonesNorm) if (/^\+996\d{9}$/.test(p)) all.add(p);
  return [...all].map((value) => ({ value, verified: isPhoneVerified(card, value) }));
}

export interface UserBrief {
  readonly id: string;
  readonly displayName: string;
  readonly phoneMasked?: string;
}

/** Краткий пользователь привязки (08 `CustomersLinkUser`): без полного телефона. */
export function userBrief(
  userId: string,
  profile: { fullName: string; displayName: string | null } | null,
  phoneE164: string | null,
): UserBrief {
  const displayName = profile?.displayName?.trim() || profile?.fullName?.trim() || 'Пользователь';
  return { id: userId, displayName, ...(phoneE164 ? { phoneMasked: maskPhone(phoneE164) } : {}) };
}

export interface CustomerLinkDto {
  readonly id: string;
  readonly userId: string;
  readonly customerId: string;
  readonly status: CustomerLinkRow['status'];
  readonly matchedBy: CustomerLinkRow['matchMethod'];
  readonly createdAt: string;
  readonly resolvedBy: { readonly id: string; readonly displayName: string } | null;
  readonly resolvedAt: string | null;
}

/** `CustomerLink` (08 §3.7). `resolvedBy` — `confirmed_by_user_id` (кто принял решение: подтвердил или отклонил). */
export function toCustomerLinkDto(row: CustomerLinkRow, resolver: UserBrief | null): CustomerLinkDto {
  const resolvedAt = row.status === 'confirmed' ? row.confirmedAt : row.status === 'rejected' ? row.rejectedAt : null;
  return {
    id: row.id,
    userId: row.userId,
    customerId: row.customerId,
    status: row.status,
    matchedBy: row.matchMethod,
    createdAt: row.proposedAt.toISOString(),
    resolvedBy: resolver ? { id: resolver.id, displayName: resolver.displayName } : null,
    resolvedAt: resolvedAt ? resolvedAt.toISOString() : null,
  };
}

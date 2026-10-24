/**
 * Наименование карточки клиента 1С для ответов API — единые правила (D PR-09, бэклог E_spec_sync.md §3):
 * `displayName` — значимая часть без формы собственности и кавычек (08 §3.7 `Customer.displayName`),
 * `displayNameMasked` — «форма собственности + первые 3 символа значимой части + `***`» (08 §4.2.2).
 *
 * Чистые функции без зависимостей от модулей (06 §7.4 п. (е)): ими пользуются `profile` (`Me.customerLink`,
 * запасной `RegistrationCustomerMatch`) и `customers` (привязки, карточки), чтобы одна и та же карточка не
 * показывалась в двух формах. Правила совпадают с customers/links/customer-link.presenter.ts (сверка —
 * test/profile/customer-name.profile-spec.ts).
 */

/** Формы собственности КР/СНГ в начале наименования (`ОсОО «…»`, `ИП …`). */
export const CUSTOMER_LEGAL_FORMS: readonly string[] = [
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

export interface ParsedCustomerName {
  readonly form: string | null;
  readonly core: string;
  readonly quoted: boolean;
}

export function parseCustomerName(name: string): ParsedCustomerName {
  let rest = name.trim().replace(/\s+/g, ' ');
  let form: string | null = null;
  for (const f of CUSTOMER_LEGAL_FORMS) {
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

/** `displayNameMasked` (08 §4.2.2): `ОсОО «Стр***»`, `Аса***`. */
export function maskCustomerName(name: string): string {
  const p = parseCustomerName(name);
  const head = Array.from(p.core).slice(0, 3).join('');
  const masked = p.quoted ? `«${head}***»` : `${head}***`;
  return p.form ? `${p.form} ${masked}` : masked;
}

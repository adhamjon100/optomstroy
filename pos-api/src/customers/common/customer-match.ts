import { type SQL, sql } from 'drizzle-orm';
import { invalid } from './customer-http.js';

export type CustomerMatchType = 'name' | 'phone' | 'code' | 'inn';

/** Разобранная строка поиска клиента по правилам роли (ядро §19.4; 10 CUST-008, CUST-009; 11 SEC-042). */
export interface CustomerMatch {
  /** Выражение приоритета совпадения по строке `c` (`NULL` — не совпало): 0 код, 1 телефон, 2 ИНН, 3 часть номера, 4 имя. */
  readonly prio: SQL;
  /** Поиск по телефону (сигнал `customer.phone_lookup` для `seller`). */
  readonly byPhone: boolean;
  /** Запрос `seller` — не полный номер: отказ, если и код клиента не совпал (`search_scope_role`). */
  readonly sellerNeedsCode: boolean;
}

export const MATCH_TYPE_SQL = (prio: SQL): SQL =>
  sql`CASE ${prio} WHEN 0 THEN 'code' WHEN 1 THEN 'phone' WHEN 2 THEN 'inn' WHEN 3 THEN 'phone' ELSE 'name' END`;

/**
 * Глубина поиска (ядро §19.4): с `customer.receivables.read.summary` (`cashier`, `senior_seller`, `admin`, `owner`)
 * — от 4 цифр номера (подстрока), от 2 букв имени (триграммы `name_norm`, ё→е), код клиента (точно), ИНН (14 цифр);
 * короче → `400 q_too_short`. Без него (`seller`) — только полный номер (9 цифр абонентского номера, `0XXXXXXXXX`,
 * `996XXXXXXXXX`, E.164) или точный код клиента; иначе → `400 search_scope_role` (проверяет сервер, CUST-008).
 */
export function parseCustomerQuery(raw: string, wide: boolean): CustomerMatch {
  // eslint-disable-next-line no-control-regex
  const text = raw.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  if (text === '') invalid('q', 'required', 'Параметр q обязателен.');
  if (text.length > 200) invalid('q', 'max_length', 'q — не более 200 символов.');
  const digits = text.replace(/[\s()+-]/g, '');
  const isDigits = /^\d+$/.test(digits);
  const national = isDigits
    ? digits.length === 12 && digits.startsWith('996')
      ? digits.slice(3)
      : digits.length === 10 && digits.startsWith('0')
        ? digits.slice(1)
        : digits.length === 9
          ? digits
          : null
    : null;
  const phoneExact: string | null = national ? `+996${national}` : null;
  let phonePart: string | null = null;
  let namePart: string | null = null;
  const inn = wide && /^\d{14}$/.test(digits) ? digits : null;
  if (wide) {
    if (isDigits && digits.length >= 4) phonePart = digits;
    if (!isDigits && Array.from(text.replace(/[^\p{L}]/gu, '')).length >= 2) namePart = text;
    if (!phonePart && !namePart && !phoneExact) {
      if (isDigits && digits.length < 4) invalid('q', 'q_too_short', 'Введите не менее 4 цифр телефона.');
      if (!isDigits && text.length < 2) {
        invalid('q', 'q_too_short', 'Введите не менее 2 букв имени или 4 цифр телефона.');
      }
    }
  }
  const prio = sql`(CASE
      WHEN c.onec_code = ${text} THEN 0
      WHEN ${phoneExact}::text IS NOT NULL
           AND (c.primary_phone_e164 = ${phoneExact} OR ${phoneExact} = ANY(c.phones_norm)) THEN 1
      WHEN ${inn}::text IS NOT NULL AND c.inn = ${inn} THEN 2
      WHEN ${phonePart}::text IS NOT NULL
           AND (position(${phonePart} IN coalesce(c.primary_phone_e164, '')) > 0
                OR EXISTS (SELECT 1 FROM unnest(c.phones_norm) x WHERE position(${phonePart} IN x) > 0)) THEN 3
      WHEN ${namePart}::text IS NOT NULL AND c.name_norm LIKE '%' || norm_search(${namePart}) || '%' THEN 4
    END)`;
  return { prio, byPhone: phoneExact !== null || phonePart !== null, sellerNeedsCode: !wide && phoneExact === null };
}

/** Отказ `seller` за пределами глубины поиска (ни полного номера, ни совпадения кода). */
export function sellerScopeError(): never {
  return invalid(
    'q',
    'search_scope_role',
    'Для вашей роли поиск — только по полному номеру телефона или коду клиента.',
  );
}

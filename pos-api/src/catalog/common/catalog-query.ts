import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';

/**
 * Разбор query-параметров каталога вручную (08 §2.6: неизвестные параметры игнорируются, поэтому DTO с
 * `forbidNonWhitelisted` здесь не применяется). Ошибки — `400 VALIDATION_FAILED` с `errors[].rule`.
 */
export type RawQuery = Readonly<Record<string, unknown>>;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MONEY_RE = /^-?\d{1,12}\.\d{2}$/;

export function validationFailed(errors: readonly ProblemFieldError[], detail = 'Запрос не прошёл проверку.'): never {
  throw new ProblemException('VALIDATION_FAILED', { status: 400, detail, errors });
}

export function fieldError(field: string, rule: string, message: string, params?: Record<string, unknown>): never {
  validationFailed([{ field, rule, message, ...(params ? { params } : {}) }]);
}

export function isUuidString(v: unknown): v is string {
  return typeof v === 'string' && UUID_RE.test(v);
}

/** Одиночное строковое значение (повтор параметра → VALIDATION_FAILED). */
export function single(q: RawQuery, name: string): string | undefined {
  const v = q[name];
  if (v === undefined) return undefined;
  if (typeof v !== 'string') fieldError(name, 'type', `Параметр ${name} задан более одного раза или неверно.`);
  return v;
}

export function uuidParam(q: RawQuery, name: string): string | undefined {
  const v = single(q, name);
  if (v === undefined || v === '') return undefined;
  if (!UUID_RE.test(v)) fieldError(name, 'format', `Параметр ${name} должен быть UUID.`);
  return v.toLowerCase();
}

export function uuidPath(value: string, name = 'id'): string {
  if (!UUID_RE.test(value)) fieldError(name, 'format', `Параметр ${name} должен быть UUID.`);
  return value.toLowerCase();
}

export function boolParam(q: RawQuery, name: string): boolean | undefined {
  const v = single(q, name);
  if (v === undefined || v === '') return undefined;
  if (v === 'true') return true;
  if (v === 'false') return false;
  fieldError(name, 'type', `Параметр ${name} должен быть true или false.`);
}

export function intParam(q: RawQuery, name: string, min: number, max: number, dflt?: number): number | undefined {
  const v = single(q, name);
  if (v === undefined || v === '') return dflt;
  if (!/^-?\d{1,6}$/.test(v)) fieldError(name, 'type', `Параметр ${name} должен быть целым числом.`);
  const n = Number(v);
  if (n < min) fieldError(name, 'minimum', `Параметр ${name} не может быть меньше ${min}.`, { minimum: min });
  if (n > max) fieldError(name, 'maximum', `Параметр ${name} не может быть больше ${max}.`, { maximum: max });
  return n;
}

export function moneyParam(q: RawQuery, name: string): string | undefined {
  const v = single(q, name);
  if (v === undefined || v === '') return undefined;
  if (!MONEY_RE.test(v))
    fieldError(name, 'money_format', `Параметр ${name}: сумма строкой с 2 знаками, например 100.00.`);
  return v;
}

/** Список через запятую (08 §2.6: ≤ maxItems значений). */
export function listParam(q: RawQuery, name: string, maxItems: number, maxLength = 200): string[] | undefined {
  const v = single(q, name);
  if (v === undefined || v === '') return undefined;
  const items = v
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s !== '');
  if (items.length > maxItems)
    fieldError(name, 'max_items', `Параметр ${name}: не более ${maxItems} значений.`, { maxItems });
  for (const s of items) {
    if (s.length > maxLength) fieldError(name, 'max_length', `Параметр ${name}: значение длиннее ${maxLength}.`);
  }
  return [...new Set(items)];
}

/**
 * `attr[<ключ>]=<значение>` (style deepObject, ≤ 10 пар; 08 §2.6). Поддерживаются оба вида разбора query в Express:
 * плоские ключи `attr[color]` (парсер `simple`) и вложенный объект `attr` (парсер `extended`).
 */
export function attrParam(q: RawQuery, maxPairs = 10, maxLength = 200): Record<string, string> | undefined {
  const out: Record<string, string> = {};
  const put = (key: string, value: unknown) => {
    if (typeof value !== 'string') fieldError(`attr[${key}]`, 'type', 'Значение фильтра по свойству — строка.');
    if (key === '' || key.length > 100) fieldError('attr', 'format', 'Неверный ключ свойства.');
    if (value.length > maxLength) fieldError(`attr[${key}]`, 'max_length', `Значение длиннее ${maxLength}.`);
    if (value.trim() !== '') out[key] = value.trim();
  };
  for (const [k, v] of Object.entries(q)) {
    const m = /^attr\[([^\]]*)\]$/.exec(k);
    if (m) put(m[1], v);
  }
  const nested = q.attr;
  if (nested !== undefined) {
    if (nested === null || typeof nested !== 'object' || Array.isArray(nested)) {
      fieldError('attr', 'type', 'Фильтр по свойствам: attr[<ключ>]=<значение>.');
    }
    for (const [k, v] of Object.entries(nested as Record<string, unknown>)) put(k, v);
  }
  const keys = Object.keys(out);
  if (keys.length > maxPairs) fieldError('attr', 'max_properties', `Не более ${maxPairs} фильтров по свойствам.`);
  return keys.length > 0 ? out : undefined;
}

export function enumParam<T extends string>(
  q: RawQuery,
  name: string,
  values: readonly T[],
  rule: string,
): T | undefined {
  const v = single(q, name);
  if (v === undefined || v === '') return undefined;
  if (!(values as readonly string[]).includes(v)) {
    fieldError(name, rule, `Недопустимое значение ${name}.`, { allowed: values });
  }
  return v as T;
}

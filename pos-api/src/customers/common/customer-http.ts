import { timingSafeEqual } from 'node:crypto';
import { Injectable } from '@nestjs/common';
import { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';

/**
 * Общие помощники HTTP-слоя модуля `customers` (этап G, RM-G-001): разбор query-параметров по правилам 08 §2.14,
 * ответы `VALIDATION_FAILED`/`NOT_FOUND`/`FORBIDDEN` и непрозрачный курсор keyset с HMAC (08 §2.5).
 */
export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const NO_STORE = 'no-store';

export function invalid(field: string, rule: string, message: string, status: 400 | 422 = 400): never {
  throw new ProblemException('VALIDATION_FAILED', {
    status,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field, rule, message }],
  });
}

export function notFound(detail = 'Клиент не найден.'): never {
  throw new ProblemException('NOT_FOUND', { detail });
}

export function forbidden(detail = 'Недостаточно прав для операции.'): never {
  throw new ProblemException('FORBIDDEN', { detail });
}

/** Одиночный query-параметр; повтор (`?a=1&a=2`) → `400 VALIDATION_FAILED` (rule `type`). Пустая строка — нет. */
export function oneQuery(q: Readonly<Record<string, unknown>>, name: string): string | undefined {
  const v = q[name];
  if (v === undefined || v === '') return undefined;
  if (typeof v !== 'string') invalid(name, 'type', `Параметр ${name} задан более одного раза или неверно.`);
  return v;
}

export function boolQuery(q: Readonly<Record<string, unknown>>, name: string): boolean | undefined {
  const v = oneQuery(q, name);
  if (v === undefined) return undefined;
  if (v !== 'true' && v !== 'false') invalid(name, 'type', `Параметр ${name} — true или false.`);
  return v === 'true';
}

export function limitQuery(q: Readonly<Record<string, unknown>>, def: number, max: number): number {
  const raw = oneQuery(q, 'limit');
  if (raw === undefined) return def;
  if (!/^\d{1,6}$/.test(raw) || Number(raw) < 1 || Number(raw) > max) {
    invalid('limit', 'limit', `limit — от 1 до ${max}.`);
  }
  return Number(raw);
}

/** Идентификатор клиента в пути: не-UUID — `404 NOT_FOUND` (объекта с таким id не бывает; как `/orders/{id}`). */
export function customerIdParam(raw: string): string {
  if (!UUID_RE.test(raw)) notFound();
  return raw.toLowerCase();
}

/** Список через запятую из допустимых значений (без повторов, ≤ max). */
export function csvQuery<T extends string>(
  q: Readonly<Record<string, unknown>>,
  name: string,
  allowed: readonly T[],
  max: number,
): T[] {
  const v = q[name];
  if (v === undefined || v === '') return [];
  const parts = (Array.isArray(v) ? v : [v])
    .flatMap((x) => (typeof x === 'string' ? x.split(',') : [String(x)]))
    .map((x) => x.trim());
  const out: T[] = [];
  for (const p of parts) {
    if (!(allowed as readonly string[]).includes(p)) invalid(name, 'enum', `${name}: допустимо ${allowed.join(', ')}.`);
    if (out.includes(p as T)) invalid(name, 'unique_items', `${name}: значения не повторяются.`);
    out.push(p as T);
  }
  if (out.length > max) invalid(name, 'max_items', `${name}: не более ${max} значений.`);
  return out;
}

/** `YYYY-MM-DD` или ISO date-time → `Date`; иное → `400` (rule `date_format`). */
export function dateQuery(q: Readonly<Record<string, unknown>>, name: string): Date | undefined {
  const v = oneQuery(q, name);
  if (v === undefined) return undefined;
  const ok = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|[+-]\d{2}:\d{2}))?$/.test(v);
  const ms = ok ? Date.parse(v.length === 10 ? `${v}T00:00:00+06:00` : v) : Number.NaN;
  if (!Number.isFinite(ms)) invalid(name, 'date_format', `${name} — дата ISO 8601.`);
  return new Date(ms);
}

/**
 * Курсор keyset модуля `customers` (08 §2.5): `base64url(JSON [scope, ...ключ]).hmac`; подделка, чужой список или
 * другая сортировка → `400 VALIDATION_FAILED` (rule `cursor`).
 */
@Injectable()
export class CustomerCursorCodec {
  constructor(private readonly hmac: OtpHmacService) {}

  encode(scope: string, key: readonly unknown[]): string {
    const body = Buffer.from(JSON.stringify([scope, ...key]), 'utf8').toString('base64url');
    return `${body}.${this.mac(body)}`;
  }

  decode(raw: string | undefined, scope: string): unknown[] | undefined {
    if (raw === undefined) return undefined;
    const fail = (): never => invalid('cursor', 'cursor', 'Курсор недействителен — запросите список заново.');
    const [body, mac, ...rest] = raw.split('.');
    if (!body || !mac || rest.length > 0 || mac.length !== 32) return fail();
    if (!timingSafeEqual(Buffer.from(this.mac(body), 'utf8'), Buffer.from(mac, 'utf8'))) return fail();
    try {
      const v: unknown = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
      if (Array.isArray(v) && v[0] === scope) return (v as unknown[]).slice(1);
    } catch {
      // ниже
    }
    return fail();
  }

  private mac(body: string): string {
    return this.hmac.pseudonym('cursor:customers', body).slice(0, 32);
  }
}

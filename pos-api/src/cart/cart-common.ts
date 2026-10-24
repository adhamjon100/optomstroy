import { Decimal } from 'decimal.js';
import type { SQL } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { CURRENCY } from '../common/money/money.js';
import { ProblemException, type ProblemFieldError } from '../common/problem-details/problem.exception.js';

/**
 * Общие утилиты модуля `cart` (06 §7.4): форматирование денег и количеств по контракту (08 §3.1, §3.2 — строки
 * NUMERIC, decimal.js; число JS для денег и количеств не используется, D-19), ответы `VALIDATION_FAILED`, выполнение
 * SQL через исполнитель Drizzle (транзакция бизнес-операции или клиент). Модуль `cart` не импортирует `catalog`
 * (06 §7.4, строка `cart`): реплики каталога читаются собственными read-only запросами.
 */
const D = Decimal.clone({ precision: 40, rounding: Decimal.ROUND_HALF_UP, toExpNeg: -40, toExpPos: 40 });
export type Dec = InstanceType<typeof D>;

export function dec(numeric: string): Dec {
  return new D(numeric);
}

export interface MoneyDto {
  readonly amount: string;
  readonly currency: typeof CURRENCY;
}

/** NUMERIC(14,2) → `Money` (HALF_UP до 0.01). */
export function moneyDto(numeric: string): MoneyDto {
  const s = new D(numeric).toFixed(2, D.ROUND_HALF_UP);
  return { amount: s === '-0.00' ? '0.00' : s, currency: CURRENCY };
}

/** NUMERIC(14,3) → строка количества с 3 знаками (`"124.000"`, 08 §3.6). */
export function qty3(numeric: string): string {
  const s = new D(numeric).toFixed(3, D.ROUND_HALF_UP);
  return s === '-0.000' ? '0.000' : s;
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const PHONE_E164_RE = /^\+996\d{9}$/;

export function isUuidString(v: unknown): v is string {
  return typeof v === 'string' && UUID_RE.test(v);
}

export function validationFailed(
  errors: readonly ProblemFieldError[],
  status: 400 | 422 = 400,
  detail = 'Запрос не прошёл проверку.',
): never {
  throw new ProblemException('VALIDATION_FAILED', { status, detail, errors });
}

export function fieldError(field: string, rule: string, message: string, status: 400 | 422 = 400): never {
  validationFailed([{ field, rule, message }], status);
}

/** Путь `{id}`/`{variantId}`: не-UUID → `400 VALIDATION_FAILED` (rule `format`, 08 §2.14, EQ-CAT-15). */
export function uuidPath(value: string, name: string): string {
  if (!UUID_RE.test(value)) fieldError(name, 'format', `Параметр ${name} должен быть UUID.`);
  return value.toLowerCase();
}

/** Одиночный query-параметр (повтор → `VALIDATION_FAILED`). */
export function singleQuery(q: Readonly<Record<string, unknown>>, name: string): string | undefined {
  const v = q[name];
  if (v === undefined) return undefined;
  if (typeof v !== 'string') fieldError(name, 'type', `Параметр ${name} задан более одного раза или неверно.`);
  return v;
}

/** Строки результата SQL через исполнитель Drizzle. */
export async function rows<T>(ex: DbExecutor, query: SQL): Promise<T[]> {
  const res = await ex.execute(query);
  return res.rows as T[];
}

export interface ImageDto {
  readonly sha256: string;
  readonly thumbUrl: string;
  readonly cardUrl: string;
  readonly fullUrl: string;
  readonly width?: number;
  readonly height?: number;
}

/** Контент-адресуемые URL фото (08 §4.4.7, D-30) — те же пути, что у каталога (`/images/{sha}/{size}`). */
export function imageDto(
  sha: Buffer | string | null,
  width: number | null,
  height: number | null,
): ImageDto | undefined {
  if (sha === null) return undefined;
  const hex = typeof sha === 'string' ? sha.replace(/^\\x/, '').toLowerCase() : sha.toString('hex');
  if (!/^[0-9a-f]{64}$/.test(hex)) return undefined;
  const base = `/images/${hex}`;
  return {
    sha256: hex,
    thumbUrl: `${base}/thumb`,
    cardUrl: `${base}/card`,
    fullUrl: `${base}/full`,
    ...(typeof width === 'number' ? { width } : {}),
    ...(typeof height === 'number' ? { height } : {}),
  };
}

export function iso(v: Date | string | null | undefined): string | null {
  if (v === null || v === undefined) return null;
  const d = v instanceof Date ? v : new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** Время `HH:MM` по Бишкеку (UTC+6) — подпись отложенной корзины (10 CART-030). */
export function bishkekTime(at: Date): string {
  return new Intl.DateTimeFormat('ru-RU', {
    timeZone: 'Asia/Bishkek',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(at);
}

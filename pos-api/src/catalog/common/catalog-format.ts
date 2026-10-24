import { Decimal } from 'decimal.js';
import { CURRENCY } from '../../common/money/money.js';

/**
 * Форматирование значений каталога по контракту (08 §3.1, §3.2, §3.6; D-19): деньги — строки с 2 знаками +
 * `currency: "KGS"`, количества — строки до 3 знаков. Число JS для денег и количеств не используется: значения
 * приходят из PostgreSQL строками NUMERIC и проходят через decimal.js.
 */
const D = Decimal.clone({ precision: 40, rounding: Decimal.ROUND_HALF_UP, toExpNeg: -40, toExpPos: 40 });
type Dec = InstanceType<typeof D>;

export interface MoneyDto {
  readonly amount: string;
  readonly currency: typeof CURRENCY;
}

/** NUMERIC(14,2) → Money (HALF_UP до 0.01). */
export function moneyOf(numeric: string): MoneyDto {
  const s = new D(numeric).toFixed(2, D.ROUND_HALF_UP);
  return { amount: s === '-0.00' ? '0.00' : s, currency: CURRENCY };
}

/** NUMERIC(14,3) → строка количества с 3 знаками (`"124.000"`, 08 §3.6). */
export function qtyOf(numeric: string): string {
  const s = new D(numeric).toFixed(3, D.ROUND_HALF_UP);
  return s === '-0.000' ? '0.000' : s;
}

export function dec(numeric: string | number): Dec {
  return new D(numeric);
}

export function decCompare(a: string, b: string): -1 | 0 | 1 {
  return new D(a).comparedTo(new D(b)) as -1 | 0 | 1;
}

/** `timestamptz` → ISO-8601 UTC с суффиксом Z (08 §2.1). */
export function isoOf(v: Date | string | null | undefined): string | undefined {
  if (v === null || v === undefined) return undefined;
  const d = v instanceof Date ? v : new Date(v);
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
}

/** Наибольшая из меток времени (null игнорируются). */
export function latest(...values: (Date | string | null | undefined)[]): Date | undefined {
  let best: Date | undefined;
  for (const v of values) {
    if (v === null || v === undefined) continue;
    const d = v instanceof Date ? v : new Date(v);
    if (Number.isNaN(d.getTime())) continue;
    if (!best || d.getTime() > best.getTime()) best = d;
  }
  return best;
}

export interface ImageDto {
  readonly sha256: string;
  readonly thumbUrl: string;
  readonly cardUrl: string;
  readonly fullUrl: string;
  readonly isPrimary?: boolean;
  readonly width?: number;
  readonly height?: number;
}

/**
 * Контент-адресуемые URL фото (08 §4.4.7, 16 §4.5, R0 §7; D-30): `/images/{sha}/{thumb|card|full}` — путь, который
 * отдаёт Caddy `file_server` из `MEDIA_DIR` (infra/caddy/Caddyfile, блок `@image`); `/api/v1/*` уходит в api, где
 * маршрута фото нет. Пример `/api/v1/images/…` в OpenAPI `Image.thumbUrl` — иллюстрация (EQ-IMG-06, EQ-INT-02).
 */
export function imageOf(row: {
  readonly sha: Buffer | string | null;
  readonly is_primary?: boolean | null;
  readonly width?: number | null;
  readonly height?: number | null;
}): ImageDto | undefined {
  if (row.sha === null) return undefined;
  const sha = typeof row.sha === 'string' ? row.sha.toLowerCase() : row.sha.toString('hex');
  if (!/^[0-9a-f]{64}$/.test(sha)) return undefined;
  const base = `/images/${sha}`;
  return {
    sha256: sha,
    thumbUrl: `${base}/thumb`,
    cardUrl: `${base}/card`,
    fullUrl: `${base}/full`,
    ...(row.is_primary !== undefined && row.is_primary !== null ? { isPrimary: row.is_primary } : {}),
    ...(typeof row.width === 'number' ? { width: row.width } : {}),
    ...(typeof row.height === 'number' ? { height: row.height } : {}),
  };
}

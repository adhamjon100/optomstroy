import { createHash } from 'node:crypto';
import { Decimal } from 'decimal.js';

/**
 * Преобразования значений 1С → реплика (RM-E-001). Деньги и количества — только через decimal.js и целые
 * (тыйыны, тысячные), без float (D-19, 07 §7.5): строка 1С `"2350.00"` → 235000n тыйынов → `NUMERIC(14,2)` `"2350.00"`.
 */

/** Ошибка значения позиции: позиция уходит в `sync_errors` (`VALIDATION`), остальные применяются. */
export class OnecValueError extends Error {
  override readonly name = 'OnecValueError';
}

const D: typeof Decimal = Decimal.clone({ precision: 40, rounding: Decimal.ROUND_HALF_UP });
/** Предел `NUMERIC(14,2)`/`NUMERIC(14,3)`: 12/11 знаков целой части. */
const MONEY_MAX_TYIYN = 10n ** 14n - 1n;
const QTY_MAX_MILLI = 10n ** 14n - 1n;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const EMPTY_REF = '00000000-0000-0000-0000-000000000000';

/** Деньги 1С (`^-?\d+\.\d{2}$`, допускается и меньше знаков) → тыйыны; не более 2 знаков дробной части. */
export function moneyToTyiyn(value: unknown, field = 'price'): bigint {
  const d = decimal(value, field);
  if (d.decimalPlaces() > 2) throw new OnecValueError(`${field}: больше 2 знаков после точки`);
  const t = BigInt(d.times(100).toFixed(0));
  if (t > MONEY_MAX_TYIYN || t < -MONEY_MAX_TYIYN) throw new OnecValueError(`${field}: вне NUMERIC(14,2)`);
  return t;
}

/** Тыйыны → строка `NUMERIC(14,2)`. */
export function tyiynToNumeric(t: bigint): string {
  const neg = t < 0n;
  const s = (neg ? -t : t).toString().padStart(3, '0');
  return `${neg ? '-' : ''}${s.slice(0, -2)}.${s.slice(-2)}`;
}

/** Количество 1С (`^-?\d+\.\d{3}$`) → тысячные; не более 3 знаков дробной части. */
export function qtyToMilli(value: unknown, field = 'quantity'): bigint {
  const d = decimal(value, field);
  if (d.decimalPlaces() > 3) throw new OnecValueError(`${field}: больше 3 знаков после точки`);
  const m = BigInt(d.times(1000).toFixed(0));
  if (m > QTY_MAX_MILLI || m < -QTY_MAX_MILLI) throw new OnecValueError(`${field}: вне NUMERIC(14,3)`);
  return m;
}

/** Тысячные → строка `NUMERIC(14,3)`. */
export function milliToNumeric(m: bigint): string {
  const neg = m < 0n;
  const s = (neg ? -m : m).toString().padStart(4, '0');
  return `${neg ? '-' : ''}${s.slice(0, -3)}.${s.slice(-3)}`;
}

function decimal(value: unknown, field: string): Decimal {
  if (typeof value !== 'string' && typeof value !== 'number') throw new OnecValueError(`${field}: нет значения`);
  const s = String(value).trim();
  if (!/^-?\d+(\.\d+)?$/.test(s)) throw new OnecValueError(`${field}: не число «${s.slice(0, 32)}»`);
  return new D(s);
}

/** Ссылка 1С (`Ref_Key`) в нижнем регистре; пустая/нулевая → `null`; иное — ошибка значения. */
export function onecRef(value: unknown, field = 'ref'): string | null {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value !== 'string') throw new OnecValueError(`${field}: ссылка — не строка`);
  const v = value.trim().toLowerCase();
  if (v === EMPTY_REF) return null;
  if (!UUID_RE.test(v)) throw new OnecValueError(`${field}: ссылка — не GUID`);
  return v;
}

/** Обязательная ссылка. */
export function requiredRef(value: unknown, field: string): string {
  const r = onecRef(value, field);
  if (r === null) throw new OnecValueError(`${field}: обязательна`);
  return r;
}

/** Непустая строка (обрезанная) или `null`. */
export function text(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const v = value.trim();
  return v === '' ? null : v;
}

export function requiredText(value: unknown, field: string): string {
  const v = text(value);
  if (v === null) throw new OnecValueError(`${field}: обязателен`);
  return v;
}

export function bool(value: unknown, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback;
}

/** Канонический JSON (ключи по алфавиту, `undefined` опускается) — вход `source_hash` (05 SYNC-013). */
export function canonicalJson(value: unknown): string {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'bigint') return JSON.stringify(value.toString());
  if (Array.isArray(value)) return `[${value.map((v) => canonicalJson(v === undefined ? null : v)).join(',')}]`;
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

/** `source_hash` = SHA-256 (hex) канонического JSON реплицируемых полей (05 SYNC-013, 07 §2.1). */
export function sourceHash(value: unknown): string {
  return createHash('sha256').update(canonicalJson(value), 'utf8').digest('hex');
}

/** Тип штрихкода по длине и контрольной цифре (07 DATA-121: «определяется по длине/формату при sync»). */
export function barcodeType(
  value: string,
  fromOnec?: string | null,
): 'EAN13' | 'EAN8' | 'UPC' | 'CODE128' | 'CODE39' | 'QR' | 'other' {
  const hint = (fromOnec ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (/^\d{13}$/.test(value) && checkDigitOk(value)) return 'EAN13';
  if (/^\d{8}$/.test(value) && checkDigitOk(value)) return 'EAN8';
  if (/^\d{12}$/.test(value) && checkDigitOk(value)) return 'UPC';
  if (hint === 'CODE128') return 'CODE128';
  if (hint === 'CODE39') return 'CODE39';
  if (hint === 'QR' || hint === 'QRCODE') return 'QR';
  return 'other';
}

/** Контрольная цифра GTIN (EAN-8/UPC-A/EAN-13): веса 3/1 справа налево. */
function checkDigitOk(code: string): boolean {
  let sum = 0;
  const body = code.slice(0, -1);
  for (let i = body.length - 1, w = 3; i >= 0; i--, w = w === 3 ? 1 : 3) sum += Number(body[i]) * w;
  return (10 - (sum % 10)) % 10 === Number(code[code.length - 1]);
}

/** Допустимое значение штрихкода (CHECK `barcodes_value_chk`). */
export const BARCODE_VALUE_RE = /^[0-9A-Za-z\-. ]{4,64}$/;

/**
 * Точность количества единицы (07 §5.20: «настройка backend по умолчанию 0/3», Q-021): метры, кг, литры, м², м³,
 * тонны — 3 знака; штучные — 0. Администратор переопределяет (`qty_precision` пишется только при создании).
 */
export function unitPrecision(code: string | null, name: string): number {
  const okei = new Set(['006', '055', '113', '166', '112', '168', '018', '163', '111']);
  if (code && okei.has(code)) return 3;
  const n = name.toLowerCase().replace(/[.\s]/g, '');
  return ['м', 'пм', 'мп', 'кг', 'г', 'л', 'мл', 'м2', 'м²', 'м3', 'м³', 'т', 'пог.м'].includes(n) ? 3 : 0;
}

const TRANSLIT: Readonly<Record<string, string>> = {
  а: 'a',
  б: 'b',
  в: 'v',
  г: 'g',
  д: 'd',
  е: 'e',
  ё: 'e',
  ж: 'zh',
  з: 'z',
  и: 'i',
  й: 'y',
  к: 'k',
  л: 'l',
  м: 'm',
  н: 'n',
  о: 'o',
  п: 'p',
  р: 'r',
  с: 's',
  т: 't',
  у: 'u',
  ф: 'f',
  х: 'h',
  ц: 'ts',
  ч: 'ch',
  ш: 'sh',
  щ: 'sch',
  ъ: '',
  ы: 'y',
  ь: '',
  э: 'e',
  ю: 'yu',
  я: 'ya',
  ү: 'u',
  ө: 'o',
  ң: 'n',
};

/** Код свойства по умолчанию — slug имени (07 §5.18: «по умолчанию slug имени»; маппинг задаёт admin). */
export function attributeCode(name: string): string {
  const slug = [...name.toLowerCase()]
    .map((ch) => TRANSLIT[ch] ?? ch)
    .join('')
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 48);
  return slug || 'attr';
}

/** Тип значения свойства по `Значение_Type` (07 enum `attribute_value_type`). */
export function attributeValueType(valueType: string | null | undefined): 'text' | 'number' | 'boolean' | 'list' {
  const t = (valueType ?? '').trim();
  if (/ЗначенияСвойствОбъектов/.test(t) || /^Catalog_/.test(t)) return 'list';
  if (/^Edm\.(Double|Decimal|Int16|Int32|Int64|Single|Byte)$/.test(t)) return 'number';
  if (t === 'Edm.Boolean') return 'boolean';
  return 'text';
}

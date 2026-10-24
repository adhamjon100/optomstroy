import { SalesDomainError } from '../domain-error.js';

/**
 * Проценты `NUMERIC(5,2)` (0…100, до 2 знаков; API — строка `Percent`, например `"5.00"`) в целых сотых долях:
 * `"5"` → 500, `"12.5"` → 1250. Без чисел с плавающей точкой (D-19).
 */
const PERCENT_RE = /^(\d{1,3})(?:\.(\d{1,2}))?$/;

export function percentToHundredths(percent: string, field = 'discountPercent'): bigint {
  const m = PERCENT_RE.exec(percent.trim());
  const v = m ? BigInt(m[1] ?? '0') * 100n + BigInt((m[2] ?? '').padEnd(2, '0')) : -1n;
  if (v < 0n || v > 10_000n) {
    throw new SalesDomainError(
      'VALIDATION_FAILED',
      'Процент — от 0 до 100, не более 2 знаков.',
      {
        errors: [{ field, rule: 'percent_range', message: 'Процент — от 0 до 100, не более 2 знаков.' }],
      },
      422,
    );
  }
  return v;
}

/** Сотые доли → каноническая строка `Percent` с 2 знаками (`500n` → `"5.00"`). */
export function hundredthsToPercent(v: bigint): string {
  const abs = v < 0n ? -v : v;
  const s = `${abs / 100n}.${(abs % 100n).toString().padStart(2, '0')}`;
  return v < 0n ? `-${s}` : s;
}

export function normalizePercent(percent: string): string {
  return hundredthsToPercent(percentToHundredths(percent));
}

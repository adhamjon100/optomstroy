import { Money, Quantity } from './money.js';

/**
 * Функции денежной арифметики 10 §18.1 (сигнатуры — спецификация), один в один с клиентом
 * `pos-app/lib/core/utils/money.dart` (`MoneyMath`): вычисления в целых тыйынах (bigint), округление HALF_UP
 * (половина — от нуля). Общие тест-векторы MV-01…MV-30 — `contracts/test-vectors/money.v1.json`
 * (`money-vectors.spec.ts`; в pos-app — `test/core/utils/money_vectors_test.dart`), MNY-004.
 *
 * Распределение скидки — 07 §7.3, 10 MNY-003: `alloc_i = roundHalfUp(discount × line_i / Σlines, 2)`, разница
 * `delta = discount − Σalloc` относится к **последней** строке с `line_i > 0` (если не помещается в
 * `0 ≤ alloc_i ≤ line_i` — остаток переносится на предыдущую ненулевую). Метод наибольшего остатка не применяется
 * (ревью C-CR-01: иначе строки сервера расходятся с превью клиента → ложные PRICE_CHANGED).
 */
export type MoneyErrorKind = 'negative' | 'outOfRange' | 'receivedLessThanTotal';

/** Ошибка входа денежной функции (на API — `VALIDATION_FAILED`, как AmountException клиента). */
export class MoneyMathError extends Error {
  constructor(readonly kind: MoneyErrorKind) {
    super(`MoneyMath: ${kind}`);
    this.name = 'MoneyMathError';
  }
}

export type CashRoundingMode = 'none' | 'to_som_half_up' | 'to_som_down';

export interface TwoStageDiscount {
  readonly customer: Money[];
  readonly manual: Money[];
  readonly lineTotals: Money[];
  readonly total: Money;
}

/** Процент `NUMERIC(5,2)` → сотые доли (`"5"` → 500, `"12.50"` → 1250). */
function percentHundredths(percent: string): bigint {
  const m = /^(\d{1,3})(?:\.(\d{1,2}))?$/.exec(percent.trim());
  if (!m) throw new MoneyMathError('outOfRange');
  const v = BigInt(m[1] ?? '0') * 100n + BigInt((m[2] ?? '').padEnd(2, '0'));
  if (v > 10_000n) throw new MoneyMathError('outOfRange');
  return v;
}

/** `roundHalfUp(a × b / divisor)` в целых; половина — от нуля; divisor > 0. */
export function mulDivHalfUp(a: bigint, b: bigint, divisor: bigint): bigint {
  const product = a * b;
  const abs = product < 0n ? -product : product;
  let q = abs / divisor;
  if ((abs % divisor) * 2n >= divisor) q += 1n;
  return product < 0n ? -q : q;
}

const sum = (values: readonly bigint[]): bigint => values.reduce((a, b) => a + b, 0n);
const toMoney = (tyiyn: bigint): Money => Money.fromTyiyn(tyiyn);

/**
 * Переносит `delta` на строки с конца (строки с `cap ≤ 0` пропускаются), не выходя за `0 ≤ alloc_i ≤ cap_i`.
 * Предусловие: `0 ≤ Σalloc + delta ≤ Σcaps`.
 */
function distributeDelta(alloc: bigint[], caps: readonly bigint[], delta: bigint): void {
  let rest = delta;
  for (let i = alloc.length - 1; i >= 0 && rest !== 0n; i--) {
    const cap = caps[i] ?? 0n;
    const cur = alloc[i] ?? 0n;
    if (cap <= 0n) continue;
    if (rest > 0n) {
      const take = rest < cap - cur ? rest : cap - cur;
      alloc[i] = cur + take;
      rest -= take;
    } else {
      const take = -rest < cur ? -rest : cur;
      alloc[i] = cur - take;
      rest += take;
    }
  }
}

export const MoneyMath = {
  /** `lineTotal(unitPrice, baseQty) = roundHalfUp(unitPrice × baseQty, 2)` (MV-01…MV-04). */
  lineTotal(unitPrice: Money, baseQty: Quantity): Money {
    return toMoney(mulDivHalfUp(unitPrice.toTyiyn(), baseQty.toMilli(), 1000n));
  },

  /** `documentDiscount(subtotal, percent) = roundHalfUp(subtotal × percent / 100, 2)` (MV-08, MV-27). */
  documentDiscount(subtotal: Money, percent: string): Money {
    return toMoney(mulDivHalfUp(subtotal.toTyiyn(), percentHundredths(percent), 10_000n));
  },

  /** Распределение скидки документа по строкам с коррекцией в последней ненулевой строке (MV-10…MV-13). */
  allocateDiscount(lines: readonly Money[], discount: Money): Money[] {
    if (discount.isNegative() || lines.some((l) => l.isNegative())) throw new MoneyMathError('negative');
    const caps = lines.map((l) => l.toTyiyn());
    const total = sum(caps);
    const d = discount.toTyiyn();
    if (d > total) throw new MoneyMathError('outOfRange');
    if (total === 0n) return lines.map(() => Money.ZERO);
    const alloc = caps.map((cap) => mulDivHalfUp(d, cap, total));
    distributeDelta(alloc, caps, d - sum(alloc));
    return alloc.map(toMoney);
  },

  /**
   * Двухэтапная скидка (07 §7.3 п. 3–5; MV-29, MV-30): этап 1 — скидка клиента 1С построчно без коррекции;
   * этап 2 — ручная скидка от базы `b_i = line_i − customer_i` с коррекцией в последней строке с `b_i > 0`.
   */
  twoStageDiscount(lineSubtotals: readonly Money[], customerPercent: string, manualPercent: string): TwoStageDiscount {
    if (lineSubtotals.some((l) => l.isNegative())) throw new MoneyMathError('negative');
    const c = percentHundredths(customerPercent);
    const p = percentHundredths(manualPercent);
    const lines = lineSubtotals.map((l) => l.toTyiyn());
    const customer = lines.map((l) => mulDivHalfUp(l, c, 10_000n));
    const bases = lines.map((l, i) => l - (customer[i] ?? 0n));
    const manualTotal = mulDivHalfUp(sum(bases), p, 10_000n);
    const manual = bases.map((b) => mulDivHalfUp(b, p, 10_000n));
    distributeDelta(manual, bases, manualTotal - sum(manual));
    const lineTotals = bases.map((b, i) => b - (manual[i] ?? 0n));
    return {
      customer: customer.map(toMoney),
      manual: manual.map(toMoney),
      lineTotals: lineTotals.map(toMoney),
      total: toMoney(sum(lineTotals)),
    };
  },

  /** Округление наличных (MV-15, MV-16; по умолчанию `none`, Q-016). */
  cashRounding(total: Money, mode: CashRoundingMode): { rounded: Money; delta: Money } {
    const t = total.toTyiyn();
    const rounded =
      mode === 'none' ? t : mode === 'to_som_half_up' ? mulDivHalfUp(t, 1n, 100n) * 100n : (t / 100n) * 100n;
    return { rounded: toMoney(rounded), delta: toMoney(rounded - t) };
  },

  /** Сдача `received − total`; `received < total` → ошибка (MV-17, MV-18). */
  change(total: Money, received: Money): Money {
    if (received.compare(total) < 0) throw new MoneyMathError('receivedLessThanTotal');
    return received.minus(total);
  },

  /** Сумма возврата строки (MNY-006, MV-19, MV-20); полный возврат — ровно сумма строки. */
  returnLineAmount(lineTotalAfterDiscount: Money, shippedQty: Quantity, returnQty: Quantity): Money {
    const shipped = shippedQty.toMilli();
    const ret = returnQty.toMilli();
    if (shipped <= 0n || ret <= 0n || ret > shipped) throw new MoneyMathError('outOfRange');
    if (ret === shipped) return lineTotalAfterDiscount;
    return toMoney(mulDivHalfUp(lineTotalAfterDiscount.toTyiyn(), ret, shipped));
  },

  /** `limit − balance − openOrders`, может быть отрицательным (MV-21, MV-22). */
  creditRemaining(limit: Money, balance: Money, openOrders: Money): Money {
    return limit.minus(balance).minus(openOrders);
  },
} as const;

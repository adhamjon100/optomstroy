import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Money, Quantity } from './money.js';
import { type CashRoundingMode, MoneyMath, MoneyMathError } from './money-math.js';

/**
 * Общие тест-векторы MV-01…MV-30 (10 §18.2, MNY-004) — тот же файл исполняет pos-app
 * (`test/core/utils/money_vectors_test.dart`). Ревью C-CR-01: распределение скидки клиента и сервера совпадает.
 */
interface Vectors {
  lineTotal: { id: string; unitPrice: string; qty: string; expected: string }[];
  documentDiscount: { id: string; subtotal: string; percent: string; expected: string }[];
  allocateDiscount: { id: string; lines: string[]; discount: string; expected: string[] }[];
  allocateDiscountErrors: { id: string; lines: string[]; discount: string; error: string }[];
  twoStageDiscount: {
    id: string;
    lines: string[];
    customerPercent: string;
    manualPercent: string;
    customer: string[];
    manual: string[];
    lineTotals: string[];
    total: string;
  }[];
  cashRounding: { id: string; total: string; mode: CashRoundingMode; rounded: string; delta: string }[];
  change: { id: string; total: string; received: string; expected?: string; error?: string }[];
  returnLineAmount: { id: string; lineTotal: string; shippedQty: string; returnQty: string; expected: string }[];
  creditRemaining: { id: string; limit: string; balance: string; openOrders: string; expected: string }[];
}

const vectors = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../../../contracts/test-vectors/money.v1.json', import.meta.url)), 'utf8'),
) as Vectors;

const m = (s: string): Money => Money.fromApi(s);
const ms = (xs: readonly string[]): Money[] => xs.map(m);
const str = (xs: readonly Money[]): string[] => xs.map(String);

function errorKind(fn: () => unknown): string | undefined {
  try {
    fn();
    return undefined;
  } catch (e) {
    return e instanceof MoneyMathError ? e.kind : `unexpected: ${String(e)}`;
  }
}

describe('MoneyMath — общие тест-векторы contracts/test-vectors/money.v1.json (MV-01…MV-30)', () => {
  it.each(vectors.lineTotal)('lineTotal $id', (v) => {
    expect(MoneyMath.lineTotal(m(v.unitPrice), Quantity.of(v.qty)).toString()).toBe(v.expected);
  });

  it.each(vectors.documentDiscount)('documentDiscount $id', (v) => {
    expect(MoneyMath.documentDiscount(m(v.subtotal), v.percent).toString()).toBe(v.expected);
  });

  it.each(vectors.allocateDiscount)('allocateDiscount $id: коррекция в последней ненулевой строке', (v) => {
    const result = MoneyMath.allocateDiscount(ms(v.lines), m(v.discount));
    expect(str(result)).toEqual(v.expected);
    expect(result.reduce((a, b) => a.plus(b), Money.ZERO).toString()).toBe(m(v.discount).toString());
  });

  it.each(vectors.allocateDiscountErrors)('allocateDiscount ошибка $id', (v) => {
    expect(errorKind(() => MoneyMath.allocateDiscount(ms(v.lines), m(v.discount)))).toBe(v.error);
  });

  it.each(vectors.twoStageDiscount)('twoStageDiscount $id', (v) => {
    const r = MoneyMath.twoStageDiscount(ms(v.lines), v.customerPercent, v.manualPercent);
    expect(str(r.customer)).toEqual(v.customer);
    expect(str(r.manual)).toEqual(v.manual);
    expect(str(r.lineTotals)).toEqual(v.lineTotals);
    expect(r.total.toString()).toBe(v.total);
  });

  it.each(vectors.cashRounding)('cashRounding $id', (v) => {
    const r = MoneyMath.cashRounding(m(v.total), v.mode);
    expect([r.rounded.toString(), r.delta.toString()]).toEqual([v.rounded, v.delta]);
  });

  it.each(vectors.change)('change $id', (v) => {
    if (v.error !== undefined) expect(errorKind(() => MoneyMath.change(m(v.total), m(v.received)))).toBe(v.error);
    else expect(MoneyMath.change(m(v.total), m(v.received)).toString()).toBe(v.expected);
  });

  it.each(vectors.returnLineAmount)('returnLineAmount $id', (v) => {
    expect(
      MoneyMath.returnLineAmount(m(v.lineTotal), Quantity.of(v.shippedQty), Quantity.of(v.returnQty)).toString(),
    ).toBe(v.expected);
  });

  it.each(vectors.creditRemaining)('creditRemaining $id', (v) => {
    expect(MoneyMath.creditRemaining(m(v.limit), m(v.balance), m(v.openOrders)).toString()).toBe(v.expected);
  });

  it('гарантии Σ = скидка и 0 ≤ alloc ≤ line на переборе (как в Dart-тесте)', () => {
    const lines = ms(['0.01', '0.02', '0.03', '17.77', '0.00', '1000.01']);
    const total = lines.reduce((a, b) => a.plus(b), Money.ZERO).toTyiyn();
    for (let d = 0n; d <= total; d += 7n) {
      const result = MoneyMath.allocateDiscount(lines, Money.fromTyiyn(d));
      expect(result.reduce((a, b) => a.plus(b), Money.ZERO).toTyiyn()).toBe(d);
      result.forEach((r, i) => {
        expect(r.toTyiyn() >= 0n && r.toTyiyn() <= lines[i].toTyiyn()).toBe(true);
      });
    }
  });

  it('входные ошибки: процент вне диапазона, возврат больше отгрузки', () => {
    expect(errorKind(() => MoneyMath.documentDiscount(m('1.00'), '100.01'))).toBe('outOfRange');
    expect(errorKind(() => MoneyMath.documentDiscount(m('1.00'), '12.345'))).toBe('outOfRange');
    expect(errorKind(() => MoneyMath.twoStageDiscount(ms(['-1.00']), '0', '0'))).toBe('negative');
    expect(errorKind(() => MoneyMath.returnLineAmount(m('1.00'), Quantity.of('1'), Quantity.of('2')))).toBe(
      'outOfRange',
    );
  });
});

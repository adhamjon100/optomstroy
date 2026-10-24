import { Decimal } from 'decimal.js';

/**
 * Money / Quantity — десятичные значения как NUMERIC-строки (08 §3.1, §3.2; D-19; 06 §7.3 common/money).
 *
 * Выбор библиотеки — decimal.js (а не big.js):
 * - режим округления задаётся на каждую операцию (`toDecimalPlaces(dp, ROUND_HALF_UP)`), а изолированный
 *   конструктор `Decimal.clone()` не меняет глобальное состояние (у big.js режим — статическое поле `Big.RM`,
 *   общее для всего процесса и всех модулей);
 * - есть деление с заданной точностью, сравнения и `toFixed(dp, rm)` — нужно для округления наличных
 *   до сома (Q-016); распределение скидки считается в целых тыйынах (money-math.ts);
 * - полная поддержка TypeScript-типов в пакете; размер не критичен для backend.
 * Число JS (`number`) для денег не используется нигде: вход и выход — только строки.
 */
const D = Decimal.clone({ precision: 40, rounding: Decimal.ROUND_HALF_UP, toExpNeg: -40, toExpPos: 40 });
type Dec = InstanceType<typeof D>;

export const CURRENCY = 'KGS' as const;
export type Currency = typeof CURRENCY;

/** Схема Money.amount: `^-?\d{1,12}\.\d{2}$`. */
export const MONEY_AMOUNT_RE = /^-?\d{1,12}\.\d{2}$/;
/** Схема Quantity.value: `^\d{1,11}(\.\d{1,3})?$`. */
export const QUANTITY_RE = /^\d{1,11}(\.\d{1,3})?$/;
/** Значения NUMERIC, которые приходят из PostgreSQL (`numeric` → string в node-postgres). */
const NUMERIC_INPUT_RE = /^-?\d+(\.\d+)?$/;

export class DecimalFormatError extends Error {}

function parse(value: string | Money | Quantity, what: string): Dec {
  if (value instanceof Money || value instanceof Quantity) return new D(value.toString());
  if (typeof value !== 'string' || !NUMERIC_INPUT_RE.test(value.trim())) {
    throw new DecimalFormatError(`${what}: ожидается десятичная строка, получено ${JSON.stringify(value)}`);
  }
  return new D(value.trim());
}

export class Money {
  private constructor(private readonly value: Dec) {}

  static readonly ZERO = new Money(new D(0));

  /** Из NUMERIC-строки (БД, 1С, расчёт); округление HALF_UP до 0.01 (D-19). */
  static of(amount: string): Money {
    return new Money(parse(amount, 'Money').toDecimalPlaces(2, D.ROUND_HALF_UP));
  }

  /** Строгий разбор значения API (уже ровно 2 знака). */
  static fromApi(amount: string): Money {
    if (!MONEY_AMOUNT_RE.test(amount))
      throw new DecimalFormatError(`Money.amount не соответствует ${MONEY_AMOUNT_RE.source}`);
    return new Money(new D(amount));
  }

  /** Целые тыйыны (клиент хранит int тыйынов, D-19). */
  static fromTyiyn(tyiyn: bigint): Money {
    return new Money(new D(tyiyn.toString()).div(100));
  }

  plus(other: Money): Money {
    return new Money(this.value.plus(other.value));
  }

  minus(other: Money): Money {
    return new Money(this.value.minus(other.value));
  }

  /** Цена × количество (Quantity или NUMERIC-строка) → округление HALF_UP до 0.01. */
  times(factor: Quantity | string): Money {
    const f = factor instanceof Quantity ? new D(factor.toString()) : parse(factor, 'factor');
    return new Money(this.value.times(f).toDecimalPlaces(2, D.ROUND_HALF_UP));
  }

  /** Процент (например, скидка `"5.00"`) от суммы, HALF_UP до 0.01. */
  percent(pct: string): Money {
    return new Money(this.value.times(parse(pct, 'percent')).div(100).toDecimalPlaces(2, D.ROUND_HALF_UP));
  }

  // Распределение скидки по строкам — только MoneyMath.allocateDiscount / twoStageDiscount (money-math.ts,
  // 07 §7.3, 10 MNY-003): коррекция в последней ненулевой строке, как у клиента. Метод наибольшего остатка
  // (прежний Money.allocate) удалён — ревью C-CR-01.

  /** Округление наличных до целого сома (Q-016; `cash_rounding`) — HALF_UP. */
  roundToSom(): Money {
    return new Money(this.value.toDecimalPlaces(0, D.ROUND_HALF_UP));
  }

  compare(other: Money): -1 | 0 | 1 {
    return this.value.comparedTo(other.value) as -1 | 0 | 1;
  }

  equals(other: Money): boolean {
    return this.value.equals(other.value);
  }

  isZero(): boolean {
    return this.value.isZero();
  }

  isNegative(): boolean {
    return this.value.isNegative() && !this.value.isZero();
  }

  /** NUMERIC-строка с 2 знаками: `"16007.50"`, `"-0.10"`. */
  toString(): string {
    const s = this.value.toFixed(2, D.ROUND_HALF_UP);
    return s === '-0.00' ? '0.00' : s;
  }

  toTyiyn(): bigint {
    return BigInt(this.value.times(100).toFixed(0, D.ROUND_HALF_UP));
  }

  /** Схема Money 08 §3.1. */
  toJSON(): { amount: string; currency: Currency } {
    return { amount: this.toString(), currency: CURRENCY };
  }
}

/** Количество: до 3 знаков (единица/упаковка), неотрицательное (08 §3.2). */
export class Quantity {
  private constructor(private readonly value: Dec) {}

  static of(value: string): Quantity {
    const d = parse(value, 'Quantity');
    if (d.isNegative()) throw new DecimalFormatError('Quantity не может быть отрицательным');
    if (d.decimalPlaces() > 3) throw new DecimalFormatError('Quantity: не более 3 знаков после запятой');
    return new Quantity(d);
  }

  static fromApi(value: string): Quantity {
    if (!QUANTITY_RE.test(value)) throw new DecimalFormatError(`Quantity.value не соответствует ${QUANTITY_RE.source}`);
    return new Quantity(new D(value));
  }

  plus(other: Quantity): Quantity {
    return new Quantity(this.value.plus(other.value));
  }

  /** value × packaging.factor → baseValue (POS-004), до 3 знаков HALF_UP. */
  times(factor: string): Quantity {
    return new Quantity(this.value.times(parse(factor, 'factor')).toDecimalPlaces(3, D.ROUND_HALF_UP));
  }

  /** Кратность (QTY_NOT_MULTIPLE): остаток от деления на шаг равен нулю. */
  isMultipleOf(step: string): boolean {
    const s = parse(step, 'step');
    return !s.isZero() && this.value.mod(s).isZero();
  }

  compare(other: Quantity): -1 | 0 | 1 {
    return this.value.comparedTo(other.value) as -1 | 0 | 1;
  }

  isZero(): boolean {
    return this.value.isZero();
  }

  /** Каноническая строка без лишних нулей: `"12"`, `"1.5"`, `"0.125"`. */
  toString(): string {
    return this.value.toFixed();
  }

  /** Тысячные доли (клиент хранит milli-units, D-19). */
  toMilli(): bigint {
    return BigInt(this.value.times(1000).toFixed(0, D.ROUND_HALF_UP));
  }

  toJSON(): string {
    return this.toString();
  }
}

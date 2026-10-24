import { DecimalFormatError, Money, MONEY_AMOUNT_RE, Quantity } from './money.js';

describe('Money (NUMERIC-строки, HALF_UP до 0.01 — D-19, 08 §3.1)', () => {
  it('точная арифметика без плавающей точки', () => {
    expect(Money.of('0.10').plus(Money.of('0.20')).toString()).toBe('0.30');
    expect(Money.of('16007.5').toString()).toBe('16007.50');
    expect(Money.of('100.00').minus(Money.of('100.01')).toString()).toBe('-0.01');
    expect(Money.of('999999999999.99').plus(Money.of('0.01')).toString()).toBe('1000000000000.00');
  });

  it('округление HALF_UP: цена × количество, процент', () => {
    expect(Money.of('2.675').toString()).toBe('2.68');
    expect(Money.of('-2.675').toString()).toBe('-2.68');
    expect(Money.of('2410.00').times(Quantity.of('1.125')).toString()).toBe('2711.25');
    expect(Money.of('19.99').times('3').toString()).toBe('59.97');
    expect(Money.of('333.33').percent('5.00').toString()).toBe('16.67');
    expect(Money.of('10.004').toString()).toBe('10.00');
  });

  it('округление наличных до сома, тыйыны, JSON-схема Money', () => {
    expect(Money.of('1234.50').roundToSom().toString()).toBe('1235.00');
    expect(Money.of('1234.49').roundToSom().toString()).toBe('1234.00');
    expect(Money.of('16007.50').toTyiyn()).toBe(1600750n);
    expect(Money.fromTyiyn(1600750n).toString()).toBe('16007.50');
    expect(JSON.stringify({ total: Money.of('5') })).toBe('{"total":{"amount":"5.00","currency":"KGS"}}');
    expect(MONEY_AMOUNT_RE.test(Money.of('-0.001').toString())).toBe(true);
    expect(Money.of('-0.001').toString()).toBe('0.00');
  });

  it('строгий вход API и отказ от number/экспоненты', () => {
    expect(Money.fromApi('2350.00').toString()).toBe('2350.00');
    expect(() => Money.fromApi('2350.0')).toThrow(DecimalFormatError);
    expect(() => Money.of('1e3')).toThrow(DecimalFormatError);
    expect(() => Money.of(12 as unknown as string)).toThrow(DecimalFormatError);
    expect(Money.of('5.00').compare(Money.of('5'))).toBe(0);
    expect(Money.of('5.00').equals(Money.of('5.001'))).toBe(true);
  });
});

describe('Quantity (до 3 знаков, 08 §3.2)', () => {
  it('разбор, кратность, базовое количество, тысячные', () => {
    expect(Quantity.fromApi('12.500').toString()).toBe('12.5');
    expect(() => Quantity.fromApi('1.2345')).toThrow(DecimalFormatError);
    expect(() => Quantity.of('-1')).toThrow(DecimalFormatError);
    expect(Quantity.of('12').isMultipleOf('6')).toBe(true);
    expect(Quantity.of('13').isMultipleOf('6')).toBe(false);
    expect(Quantity.of('0.3').isMultipleOf('0.1')).toBe(true);
    expect(Quantity.of('2').times('6').toString()).toBe('12');
    expect(Quantity.of('1.125').toMilli()).toBe(1125n);
    expect(Quantity.of('1').plus(Quantity.of('0.001')).toString()).toBe('1.001');
  });
});

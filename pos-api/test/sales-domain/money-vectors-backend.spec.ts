import { describe, expect, it } from 'vitest';
import { Money, Quantity } from '../../src/common/money/money.js';
import { priceCart } from '../../src/sales-domain/pricing/cart-pricing.js';
import { percentToHundredths } from '../../src/sales-domain/pricing/percent.js';
import { moneyToTyiyn } from '../../src/sync/apply/onec-values.js';

/**
 * Векторы 10 §18.1, которых нет в общем файле contracts/test-vectors/money.v1.json, но правило которых исполняет
 * backend (12 T-MNY-034; ревью F-trace-13): MV-05 упаковки → база, MV-09 итог макета, MV-24 лишний знак количества,
 * MV-26 процент с 3 знаками, MV-28 цена 1С с 3 знаками. MV-07 — cart-items.e2e (PUT дробных упаковок); MV-06,
 * MV-23, MV-25 — только клиент (scripts/check_money_vectors.py, CLIENT_ONLY).
 */
describe('денежные векторы backend вне общего файла', () => {
  it('MV-05: 5 кор × 12 = 60 шт', () => {
    expect(Quantity.of('5').times('12').toString()).toBe('60');
  });

  it('MV-09: итог 16 850,00 − 842,50 = 16 007,50 (макет «16 030» неверен)', () => {
    const lines = ['2350.00', '4800.00', '3200.00', '5000.00', '1500.00'].map((p, i) => ({
      lineNo: i + 1,
      variantId: `v${i + 1}`,
      packagingId: null,
      quantity: Quantity.of('1'),
      unitPrice: Money.of(p),
    }));
    const r = priceCart({ lines, customerDiscountPercent: null, manualDiscountPercent: '5' });
    expect(r.subtotal.toString()).toBe('16850.00');
    expect(r.discountTotal.toString()).toBe('842.50');
    expect(r.total.toString()).toBe('16007.50');
  });

  it('MV-24: количество «2.3333» при точности 3 — ошибка (сервер не принимает 4-й знак)', () => {
    expect(() => Quantity.of('2.3333')).toThrow(/не более 3 знаков/);
  });

  it('MV-26: процент скидки 12,345 % — ошибка (NUMERIC(5,2), не более 2 знаков)', () => {
    expect(() => percentToHundredths('12.345')).toThrow();
    expect(percentToHundredths('12.34')).toBe(1234n);
  });

  it('MV-28: цена из 1С с 3 знаками (1 234,565) — ошибка синхронизации цены, цена не публикуется', () => {
    expect(() => moneyToTyiyn('1234.565')).toThrow(/больше 2 знаков/);
    expect(moneyToTyiyn('1234.56')).toBe(123456n);
  });
});

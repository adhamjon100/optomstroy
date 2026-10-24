import fc from 'fast-check';
import { describe, expect, it } from 'vitest';
import { Money, Quantity } from '../../src/common/money/money.js';
import { SalesDomainError } from '../../src/sales-domain/domain-error.js';
import { detectLineConflicts } from '../../src/sales-domain/pricing/cart-conflicts.js';
import {
  type PricingLineInput,
  priceCart,
  pricingInvariantViolations,
} from '../../src/sales-domain/pricing/cart-pricing.js';
import { checkManualDiscount, type RoleDiscountLimit } from '../../src/sales-domain/pricing/discount-policy.js';
import { allowedPaymentMethods, assertPaymentMethodAllowed } from '../../src/sales-domain/pricing/payment-methods.js';
import { hundredthsToPercent, percentToHundredths } from '../../src/sales-domain/pricing/percent.js';
import { resolvePriceListId } from '../../src/sales-domain/pricing/price-list.js';

/** Движок цен корзины (07 §7.3, §7.4; 10 §11, MNY-) + property-based (fast-check) на суммах и скидках. */
const line = (lineNo: number, price: string, qty = '1', variantId = `v${lineNo}`): PricingLineInput => ({
  lineNo,
  variantId,
  packagingId: null,
  quantity: Quantity.of(qty),
  unitPrice: Money.of(price),
});
const s = (m: Money) => m.toString();

describe('примеры 07 §7.4 (ядро §17.2: 16 850 × 5 % = 842,50 → 16 007,50)', () => {
  it('A — корзина макета: скидка 842,50, итого 16 007,50 (не 820 / 16 030)', () => {
    const p = priceCart({
      lines: ['2350.00', '4800.00', '3200.00', '5000.00', '1500.00'].map((x, i) => line(i + 1, x)),
      customerDiscountPercent: null,
      manualDiscountPercent: '5',
    });
    expect(s(p.subtotal)).toBe('16850.00');
    expect(s(p.discountTotal)).toBe('842.50');
    expect(s(p.total)).toBe('16007.50');
    expect(p.lines.map((l) => s(l.discountAmount))).toEqual(['117.50', '240.00', '160.00', '250.00', '75.00']);
    expect(pricingInvariantViolations(p)).toEqual([]);
  });

  // 12: T-DISC-007 (округление и распределение: Σ строк = скидка документа)
  it('B — коррекция копеек в последней строке: 3 × 33,33, 10 % → 10,00; 30,00 / 30,00 / 29,99', () => {
    const p = priceCart({
      lines: [1, 2, 3].map((n) => line(n, '33.33')),
      customerDiscountPercent: null,
      manualDiscountPercent: '10',
    });
    expect(s(p.discountTotal)).toBe('10.00');
    expect(p.lines.map((l) => s(l.lineTotal))).toEqual(['30.00', '30.00', '29.99']);
    expect(s(p.total)).toBe('89.99');
  });

  it('C — дробное количество: 85,00 × 2,333 = 198,31', () => {
    expect(
      s(
        priceCart({ lines: [line(1, '85.00', '2.333')], customerDiscountPercent: null, manualDiscountPercent: '0' })
          .total,
      ),
    ).toBe('198.31');
  });

  it('F — скидка клиента 5 % + ручная 5 %: 1 642,88; итого 15 207,12', () => {
    const p = priceCart({
      lines: ['2350.00', '4800.00', '3200.00', '5000.00', '1500.00'].map((x, i) => line(i + 1, x)),
      customerDiscountPercent: '5.00',
      manualDiscountPercent: '5.00',
    });
    expect(s(p.customerDiscountTotal)).toBe('842.50');
    expect(s(p.manualDiscountTotal)).toBe('800.38');
    expect(s(p.discountTotal)).toBe('1642.88');
    expect(s(p.total)).toBe('15207.12');
    expect(p.lines.map((l) => s(l.lineTotal))).toEqual(['2120.87', '4332.00', '2888.00', '4512.50', '1353.75']);
  });

  it('G — два этапа с коррекцией −0,01: 28,49 / 28,49 / 28,50; итого 85,48', () => {
    const p = priceCart({
      lines: [1, 2, 3].map((n) => line(n, '33.33')),
      customerDiscountPercent: '5',
      manualDiscountPercent: '10',
    });
    expect(s(p.customerDiscountTotal)).toBe('5.01');
    expect(s(p.manualDiscountTotal)).toBe('9.50');
    expect(p.lines.map((l) => s(l.lineTotal))).toEqual(['28.49', '28.49', '28.50']);
    expect(s(p.total)).toBe('85.48');
  });

  it('коррекция — по последней line_no, а не по порядку во входе', () => {
    const a = priceCart({
      lines: [line(3, '33.33'), line(1, '33.33'), line(2, '33.33')],
      customerDiscountPercent: null,
      manualDiscountPercent: '10',
    });
    expect(a.lines.map((l) => l.lineNo)).toEqual([1, 2, 3]);
    expect(s(a.lines[2].manualDiscountAmount)).toBe('3.34');
  });

  it('округление наличных (Q-016): none по умолчанию; to_som — HALF_UP до сома', () => {
    const lines = [line(1, '16007.50')];
    expect(s(priceCart({ lines, customerDiscountPercent: null, manualDiscountPercent: '0' }).totalToPay)).toBe(
      '16007.50',
    );
    const r = priceCart({ lines, customerDiscountPercent: null, manualDiscountPercent: '0', cashRounding: 'to_som' });
    expect([s(r.totalToPay), s(r.cashRoundingDelta)]).toEqual(['16008.00', '0.50']);
  });

  it('некорректный вход: дубль line_no, нулевое количество, процент > 100 → VALIDATION_FAILED', () => {
    expect(() =>
      priceCart({ lines: [line(1, '1'), line(1, '2')], customerDiscountPercent: null, manualDiscountPercent: '0' }),
    ).toThrow(SalesDomainError);
    expect(() =>
      priceCart({ lines: [line(1, '1', '0')], customerDiscountPercent: null, manualDiscountPercent: '0' }),
    ).toThrow(/VALIDATION/);
    expect(() =>
      priceCart({ lines: [line(1, '1')], customerDiscountPercent: null, manualDiscountPercent: '100.01' }),
    ).toThrow(/VALIDATION/);
  });
});

// ---------------------------------------------------------------------------------------------------------------
// property-based (fast-check): суммы, скидки, округление
// ---------------------------------------------------------------------------------------------------------------

/** Деньги в тыйынах → строка (без float). */
const tyiyn = (min: bigint, max: bigint) => fc.bigInt({ min, max }).map((t) => Money.fromTyiyn(t).toString());
const percentArb = fc.integer({ min: 0, max: 10_000 }).map((h) => hundredthsToPercent(BigInt(h)));
/** Количество в тысячных (0,001…99,999) → строка `NUMERIC(14,3)`. */
const qtyArb = fc.integer({ min: 1, max: 99_999 }).map((milli) => {
  const d = String(milli).padStart(4, '0');
  return `${d.slice(0, -3)}.${d.slice(-3)}`;
});
const linesArb = fc
  .array(fc.record({ price: tyiyn(0n, 5_000_000n), qty: qtyArb }), { minLength: 1, maxLength: 25 })
  .map((xs) => xs.map((x, i) => line(i + 1, x.price, x.qty)));

describe('property-based: инварианты денег (D-19, 07 §7.5)', () => {
  it('Σ line_total = total = subtotal − discount_total; split; 0 ≤ скидка строки ≤ сумма строки', () => {
    fc.assert(
      fc.property(linesArb, fc.option(percentArb, { nil: null }), percentArb, (lines, c, p) => {
        const r = priceCart({ lines, customerDiscountPercent: c, manualDiscountPercent: p });
        expect(pricingInvariantViolations(r)).toEqual([]);
      }),
      { numRuns: 400 },
    );
  });

  it('независимый оракул 07 §7.3 (тыйыны, без кода движка): subtotal, скидка клиента, ручная скидка, итог', () => {
    // 12 T-MNY-029 (свойство, backend). Ревью F-money-rules-9: первое свойство выше выполняется по построению (total = Σ lineTotals). Здесь итог
    // пересчитывается в тесте по формулам 07 §7.3 п. 1–5 целыми тыйынами и сравнивается с движком.
    const halfUp = (num: bigint, den: bigint) => num / den + ((num % den) * 2n >= den ? 1n : 0n);
    fc.assert(
      fc.property(linesArb, fc.option(percentArb, { nil: null }), percentArb, (lines, c, p) => {
        const r = priceCart({ lines, customerDiscountPercent: c, manualDiscountPercent: p });
        const ch = c === null ? 0n : percentToHundredths(c);
        const ph = percentToHundredths(p);
        const subs = lines.map((l) => halfUp(l.unitPrice.toTyiyn() * l.quantity.toMilli(), 1000n));
        const cust = subs.map((x) => halfUp(x * ch, 10_000n));
        const base = subs.reduce((a, x, i) => a + x - (cust[i] ?? 0n), 0n);
        const manual = halfUp(base * ph, 10_000n);
        const subtotal = subs.reduce((a, x) => a + x, 0n);
        const custTotal = cust.reduce((a, x) => a + x, 0n);
        expect(r.subtotal.toTyiyn()).toBe(subtotal);
        expect(r.customerDiscountTotal.toTyiyn()).toBe(custTotal);
        expect(r.manualDiscountTotal.toTyiyn()).toBe(manual);
        expect(r.total.toTyiyn()).toBe(subtotal - custTotal - manual);
        expect(r.totalToPay.toTyiyn()).toBe(r.total.toTyiyn());
      }),
      { numRuns: 400 },
    );
  });

  it('распределение ручной скидки без потери тыйына: Σ ручных скидок строк = round_half_up(B × p / 100)', () => {
    fc.assert(
      fc.property(linesArb, percentArb, percentArb, (lines, c, p) => {
        const r = priceCart({ lines, customerDiscountPercent: c, manualDiscountPercent: p });
        const base = r.subtotal.minus(r.customerDiscountTotal).toTyiyn();
        const ph = percentToHundredths(p);
        const product = base * ph;
        const expected = product / 10_000n + ((product % 10_000n) * 2n >= 10_000n ? 1n : 0n);
        const sumManual = r.lines.reduce((a, l) => a + l.manualDiscountAmount.toTyiyn(), 0n);
        expect(sumManual).toBe(expected);
        expect(r.manualDiscountTotal.toTyiyn()).toBe(expected);
      }),
      { numRuns: 400 },
    );
  });

  it('скидка не превышает лимит: discount_total ≤ subtotal × (c + p − c·p/100) / 100 + 0,01 на строку', () => {
    fc.assert(
      fc.property(linesArb, percentArb, percentArb, (lines, c, p) => {
        const r = priceCart({ lines, customerDiscountPercent: c, manualDiscountPercent: p });
        const ch = percentToHundredths(c);
        const ph = percentToHundredths(p);
        // эффективный процент в 1/10^8: c + p − c·p/100 (в сотых долях процента обоих)
        const effective = ch * 10_000n + ph * 10_000n - ch * ph;
        const bound = (r.subtotal.toTyiyn() * effective) / 100_000_000n + BigInt(r.lines.length) * 2n;
        expect(r.discountTotal.toTyiyn() <= bound).toBe(true);
        expect(r.discountTotal.compare(r.subtotal) <= 0).toBe(true);
      }),
      { numRuns: 300 },
    );
  });

  it('неотрицательность и 0 % — без скидки; 100 % — итог 0', () => {
    fc.assert(
      fc.property(linesArb, (lines) => {
        const zero = priceCart({ lines, customerDiscountPercent: null, manualDiscountPercent: '0' });
        expect(zero.discountTotal.isZero()).toBe(true);
        expect(zero.total.equals(zero.subtotal)).toBe(true);
        const full = priceCart({ lines, customerDiscountPercent: null, manualDiscountPercent: '100' });
        expect(full.total.isZero()).toBe(true);
        for (const l of full.lines) expect(l.lineTotal.isNegative()).toBe(false);
      }),
      { numRuns: 200 },
    );
  });

  it('политика скидки: применённый % ≤ лимита роли без подтверждения; сверх — DISCOUNT_LIMIT_EXCEEDED с limitPercent', () => {
    fc.assert(
      fc.property(percentArb, percentArb, (requested, limit) => {
        const lim: RoleDiscountLimit = { maxPercent: limit, canApproveOverLimit: false, approveMaxPercent: null };
        const rq = percentToHundredths(requested);
        const lm = percentToHundredths(limit);
        if (rq <= lm) {
          const d = checkManualDiscount({ requestedPercent: requested, isCustomer: false, initiatorLimit: lim });
          expect(percentToHundredths(d.appliedPercent) <= lm).toBe(true);
          expect(d.overrideApplied).toBe(false);
        } else {
          try {
            checkManualDiscount({ requestedPercent: requested, isCustomer: false, initiatorLimit: lim });
            expect.unreachable();
          } catch (e) {
            expect((e as SalesDomainError).code).toBe('DISCOUNT_LIMIT_EXCEEDED');
            expect((e as SalesDomainError).extensions.limitPercent).toBe(hundredthsToPercent(lm));
          }
        }
      }),
      { numRuns: 300 },
    );
  });

  it('проценты: строка ↔ сотые доли без потерь', () => {
    fc.assert(
      fc.property(fc.integer({ min: 0, max: 10_000 }), (h) => {
        expect(percentToHundredths(hundredthsToPercent(BigInt(h)))).toBe(BigInt(h));
      }),
    );
  });
});

describe('политика ручной скидки (DISC-003, DISC-010, CUST-021)', () => {
  const seller: RoleDiscountLimit = { maxPercent: '5.00', canApproveOverLimit: false, approveMaxPercent: null };
  const senior: RoleDiscountLimit = { maxPercent: '10.00', canApproveOverLimit: true, approveMaxPercent: null };

  it('7 % под seller (лимит 5 %) → 422 DISCOUNT_LIMIT_EXCEEDED, limitPercent "5.00" (RM-F-001 п. 3)', () => {
    try {
      checkManualDiscount({ requestedPercent: '7', isCustomer: false, initiatorLimit: seller });
      expect.unreachable();
    } catch (e) {
      expect((e as SalesDomainError).code).toBe('DISCOUNT_LIMIT_EXCEEDED');
      expect((e as SalesDomainError).extensions.limitPercent).toBe('5.00');
    }
  });

  // 12: T-SEC-022 (подтверждение сверх лимита в пределах лимита подтверждающего)
  it('подтверждение senior_seller в собственной сессии: до своего лимита, с причиной', () => {
    expect(
      checkManualDiscount({
        requestedPercent: '8',
        isCustomer: false,
        initiatorLimit: seller,
        override: { approverLimit: senior, reason: 'опт' },
      }),
    ).toEqual({ appliedPercent: '8.00', limitPercent: '5.00', overrideApplied: true });
    expect(() =>
      checkManualDiscount({
        requestedPercent: '12',
        isCustomer: false,
        initiatorLimit: seller,
        override: { approverLimit: senior, reason: 'опт' },
      }),
    ).toThrow(/DISCOUNT_LIMIT_EXCEEDED/);
    expect(() =>
      checkManualDiscount({
        requestedPercent: '8',
        isCustomer: false,
        initiatorLimit: seller,
        override: { approverLimit: seller, reason: 'x' },
      }),
    ).toThrow(/FORBIDDEN/);
    expect(() =>
      checkManualDiscount({
        requestedPercent: '8',
        isCustomer: false,
        initiatorLimit: seller,
        override: { approverLimit: senior, reason: ' ' },
      }),
    ).toThrow(/VALIDATION_FAILED/);
  });

  it('customer: ручная скидка → 403; нет строки лимита → лимит 0 (fail-closed)', () => {
    expect(() => checkManualDiscount({ requestedPercent: '1', isCustomer: true, initiatorLimit: seller })).toThrow(
      /FORBIDDEN/,
    );
    expect(checkManualDiscount({ requestedPercent: '0', isCustomer: true, initiatorLimit: null }).appliedPercent).toBe(
      '0.00',
    );
    expect(() => checkManualDiscount({ requestedPercent: '0.01', isCustomer: false, initiatorLimit: null })).toThrow(
      /DISCOUNT_LIMIT/,
    );
  });
});

describe('вид цены, способы оплаты, конфликты строк', () => {
  const base = { defaultPriceListId: 'D', retailPriceListId: 'R', customerPriceListVisible: true };
  it('INV-030 / CUST-021', () => {
    expect(
      resolvePriceListId({ ...base, isCustomerMode: false, linkConfirmed: false, customerPriceListId: 'C' }),
    ).toEqual({ id: 'C', source: 'customer' });
    expect(
      resolvePriceListId({ ...base, isCustomerMode: true, linkConfirmed: false, customerPriceListId: 'C' }).id,
    ).toBe('D');
    expect(
      resolvePriceListId({ ...base, isCustomerMode: true, linkConfirmed: true, customerPriceListId: 'C' }).id,
    ).toBe('C');
    expect(
      resolvePriceListId({
        ...base,
        isCustomerMode: false,
        linkConfirmed: false,
        customerPriceListId: 'C',
        customerPriceListVisible: false,
      }).id,
    ).toBe('D');
    expect(
      resolvePriceListId({
        ...base,
        defaultPriceListId: null,
        isCustomerMode: false,
        linkConfirmed: false,
        customerPriceListId: null,
      }).source,
    ).toBe('retail');
  });

  it('API-179: customer — cash и QR только при QR_PROVIDER≠none; credit → 403 forbidden_role', () => {
    expect(allowedPaymentMethods({ isCustomerMode: true, qrProvider: 'none', canSellOnCredit: true })).toEqual([
      'cash',
    ]);
    expect(allowedPaymentMethods({ isCustomerMode: true, qrProvider: 'onec', canSellOnCredit: true })).toEqual([
      'cash',
      'qr_bakai',
    ]);
    expect(allowedPaymentMethods({ isCustomerMode: false, qrProvider: 'none', canSellOnCredit: true })).toEqual([
      'cash',
      'qr_bakai',
      'credit',
    ]);
    const cust = { isCustomerMode: true, qrProvider: 'none' as const, canSellOnCredit: false };
    expect(() => assertPaymentMethodAllowed('credit', cust)).toThrow(
      expect.objectContaining({
        code: 'FORBIDDEN',
        extensions: expect.objectContaining({ creditReason: 'forbidden_role' }),
      }),
    );
    expect(() => assertPaymentMethodAllowed('qr_bakai', cust)).toThrow(
      expect.objectContaining({ code: 'VALIDATION_FAILED', status: 422 }),
    );
    expect(() => assertPaymentMethodAllowed('qr_bakai', { ...cust, qrProvider: 'onec' })).not.toThrow();
  });

  it('конфликты: цена изменилась (обе цены), нехватка, недоступен, кратность, минимальная партия', () => {
    const q = (x: string) => Quantity.of(x);
    const out = detectLineConflicts([
      {
        variantId: 'a',
        priceSnapshot: Money.of('100'),
        currentPrice: Money.of('110'),
        unavailable: false,
        requestedBase: q('2'),
        available: q('5'),
        multiplicity: null,
        minQty: null,
      },
      {
        variantId: 'b',
        priceSnapshot: Money.of('1'),
        currentPrice: Money.of('1'),
        unavailable: false,
        requestedBase: q('6'),
        available: q('5'),
        multiplicity: '4',
        minQty: q('10'),
      },
      {
        variantId: 'c',
        priceSnapshot: Money.of('1'),
        currentPrice: null,
        unavailable: false,
        requestedBase: q('1'),
        available: q('5'),
        multiplicity: null,
        minQty: null,
      },
      {
        variantId: 'd',
        priceSnapshot: Money.of('1'),
        currentPrice: Money.of('1'),
        unavailable: false,
        requestedBase: q('1'),
        available: null,
        multiplicity: null,
        minQty: null,
      },
    ]);
    expect(out.map((c) => `${c.variantId}:${c.kind}`)).toEqual([
      'a:price_changed',
      'b:stock_insufficient',
      'b:qty_not_multiple',
      'b:qty_below_min',
      'c:variant_unavailable',
      'd:stock_insufficient',
    ]);
    expect([out[0].oldPrice?.toString(), out[0].newPrice?.toString()]).toEqual(['100.00', '110.00']);
  });
});

import { describe, expect, it } from 'vitest';
import { discountStateOf, evaluateCart, stockLevelOf } from '../../src/cart/cart-evaluator.js';
import { forbiddenPriceFields, parsePreview, parsePutItem, parseUpdate } from '../../src/cart/cart-requests.js';
import type { CartItemRow, CartRow } from '../../src/cart/cart.repository.js';
import type { LineQuote } from '../../src/cart/catalog-pricing.service.js';
import { signPreviewToken, verifyPreviewToken } from '../../src/cart/preview-token.js';
import { OtpHmacService } from '../../src/common/crypto/otp-hmac.service.js';
import { Money } from '../../src/common/money/money.js';

const CART: CartRow = {
  id: '00000000-0000-7000-8000-00000000c001',
  owner_user_id: '00000000-0000-7000-8000-00000000a001',
  created_by_user_id: '00000000-0000-7000-8000-00000000a001',
  customer_id: null,
  warehouse_id: '00000000-0000-7000-8000-00000000d001',
  price_list_id: '00000000-0000-7000-8000-00000000e001',
  status: 'active',
  name: null,
  requested_discount_percent: '5.00',
  discount_approved_by_user_id: null,
  discount_approved_at: null,
  discount_override_reason: null,
  receiver_kind: 'customer',
  receiver_name: null,
  receiver_phone_e164: null,
  restored_from_order_id: null,
  converted_order_id: null,
  parked_at: null,
  resumed_at: null,
  cleared_at: null,
  expires_at: null,
  last_price_check_at: null,
  row_version: 1,
  created_at: new Date(),
  updated_at: new Date(),
};

function item(
  n: number,
  variant: string,
  qty: string,
  snapshot: string,
  packagingId: string | null = null,
  base = qty,
): CartItemRow {
  return {
    id: `00000000-0000-7000-8000-0000000001${String(n).padStart(2, '0')}`,
    cart_id: CART.id,
    variant_id: variant,
    packaging_id: packagingId,
    quantity: qty,
    base_quantity: base,
    price_snapshot: snapshot,
    stock_snapshot: null,
    price_changed: false,
    stock_insufficient: false,
    line_no: n,
    added_at: new Date(),
  };
}

function quote(
  variant: string,
  price: string | null,
  available: string | null,
  extra: Partial<LineQuote> = {},
): LineQuote {
  return {
    variantId: variant,
    productId: 'p',
    packagingId: null,
    unitPrice: price,
    pricePerPackaging: false,
    packagingFactor: null,
    unitId: 'u',
    unitCode: 'шт',
    qtyPrecision: 0,
    multiplicity: null,
    minQty: null,
    available,
    sellable: price !== null,
    productName: 'Товар',
    variantName: null,
    sku: null,
    barcode: null,
    packagingName: null,
    found: true,
    baseUnitId: 'u',
    packagingValid: true,
    packaging: null,
    imageSha: null,
    imageWidth: null,
    imageHeight: null,
    productOnecRef: null,
    variantOnecRef: null,
    packagingOnecRef: null,
    ...extra,
  };
}

/** Чистые функции корзины (без БД): движок пересчёта, конфликты, разбор тел, подпись previewToken. */
describe('cart (unit)', () => {
  it('макет корзины: 16 850 сом, 5 % → 842,50 / 16 007,50; Σ строк = итог (RM-F-001 п. 1–2, R7 §0)', () => {
    const prices = ['2350.00', '3000.00', '4150.00', '2500.00', '2500.00'];
    const qty = ['2', '1', '1', '1', '1'];
    const items = prices.map((p, i) => item(i + 1, `v${i}`, qty[i], p));
    const e = evaluateCart({
      cart: CART,
      items,
      quotes: prices.map((p, i) => quote(`v${i}`, p, '100')),
      discount: discountStateOf(CART, '5.00', false),
      customerDiscountPercent: null,
    });
    expect(e.priced.subtotal.toString()).toBe('16850.00');
    expect(e.priced.discountTotal.toString()).toBe('842.50');
    expect(e.priced.total.toString()).toBe('16007.50');
    expect(e.priced.lines.reduce((s, l) => s.plus(l.lineTotal), Money.ZERO).toString()).toBe('16007.50');
    expect(e.conflicts).toEqual([]);
    expect(e.unitsCount).toBe('6.000');
  });

  it('нехватка — по Σ базовых количеств варианта во всех упаковках; remaining ≥ 0; неизвестный остаток — конфликт', () => {
    const items = [item(1, 'a', '4', '10.00'), item(2, 'a', '1', '60.00', 'pk', '6'), item(3, 'b', '1', '5.00')];
    const e = evaluateCart({
      cart: CART,
      items,
      quotes: [quote('a', '10.00', '8'), quote('a', '60.00', '8', { packagingId: 'pk' }), quote('b', '5.00', null)],
      discount: discountStateOf({ ...CART, requested_discount_percent: '0' }, '5', false),
      customerDiscountPercent: null,
    });
    expect(e.lines[0].remaining).toBe('0.000');
    expect(e.conflicts.filter((c) => c.kind === 'stock_insufficient').map((c) => c.variantId)).toEqual(['a', 'b']);
  });

  it('цена изменилась / вариант недоступен: недоступная строка не входит в итог', () => {
    const e = evaluateCart({
      cart: CART,
      items: [item(1, 'a', '1', '10.00'), item(2, 'b', '1', '5.00')],
      quotes: [quote('a', '12.00', '10'), quote('b', null, '10')],
      discount: discountStateOf({ ...CART, requested_discount_percent: '0' }, '5', false),
      customerDiscountPercent: null,
    });
    expect(e.conflicts.map((c) => c.kind)).toEqual(['price_changed', 'variant_unavailable']);
    expect(e.priced.total.toString()).toBe('12.00');
  });

  it('скидка сверх лимита без подтверждения применяется в пределах лимита; клиенту — 0', () => {
    expect(discountStateOf({ ...CART, requested_discount_percent: '7' }, '5', false)).toMatchObject({
      applied: '5.00',
    });
    expect(
      discountStateOf(
        { ...CART, requested_discount_percent: '7', discount_approved_by_user_id: CART.owner_user_id },
        '5',
        false,
      ),
    ).toMatchObject({ applied: '7.00', approved: true });
    expect(discountStateOf(CART, '5', true)).toMatchObject({ applied: '0.00', limit: '0.00' });
    expect(stockLevelOf(null, '5')).toBe('unknown');
    expect(stockLevelOf('0', '5')).toBe('out');
    expect(stockLevelOf('3', '5')).toBe('low');
    expect(stockLevelOf('5', '5')).toBe('in_stock');
  });

  it('разбор тел: forbidden_field для цен, priceSnapshot разрешён; PATCH — только warehouseId; delivery требует адрес и телефон', () => {
    expect(forbiddenPriceFields({ quantity: {}, priceSnapshot: { amount: '1.00' } }, ['priceSnapshot'])).toEqual([]);
    expect(forbiddenPriceFields({ total: '1', delivery: { amount: 1 } })).toEqual(['total', 'delivery.amount']);
    expect(
      parsePutItem({
        quantity: { value: '2', unitId: '00000000-0000-4000-8000-000000000001' },
        priceSnapshot: { amount: '10.00', currency: 'KGS' },
        rowVersion: 3,
      }),
    ).toMatchObject({ value: '2', packagingId: null, priceSnapshot: '10.00', mode: 'set' });
    expect(() => parsePutItem({ quantity: { value: '-1', unitId: 'x' }, rowVersion: -1 })).toThrow();
    expect(() =>
      parseUpdate({ warehouseId: '00000000-0000-4000-8000-000000000001', rowVersion: 1, name: 'x' }),
    ).toThrow();
    const base = {
      cartId: '00000000-0000-4000-8000-000000000001',
      cartRowVersion: 1,
      paymentMethod: 'cash',
      receiver: { kind: 'customer' },
    };
    expect(() => parsePreview({ ...base, delivery: { method: 'delivery' } })).toThrow();
    expect(
      parsePreview({
        ...base,
        delivery: { method: 'delivery', address: 'ул. Ленина 1', recipientPhone: '+996 700 123 456' },
      }).delivery,
    ).toMatchObject({ recipientPhone: '+996700123456' });
  });

  it('previewToken: подпись проверяется, подмена и истечение — отказ', () => {
    const ring = {
      name: 'OTP_HMAC_SECRET',
      currentVersion: 1,
      versions: [1],
      ephemeral: false,
      get: () => Buffer.alloc(32, 7),
    };
    const hmac = new OtpHmacService(ring);
    const validUntil = new Date(Date.now() + 60_000).toISOString();
    const token = signPreviewToken(hmac, {
      cartId: CART.id,
      cartRowVersion: 3,
      total: '16007.50',
      paymentMethod: 'cash',
      validUntil,
      onecCheckAt: null,
      onecResult: 'ok',
    });
    expect(verifyPreviewToken(hmac, token, new Date())).toMatchObject({ cartRowVersion: 3, total: '16007.50' });
    expect(verifyPreviewToken(hmac, `${token}x`, new Date())).toBeNull();
    expect(verifyPreviewToken(hmac, token, new Date(Date.now() + 120_000))).toBeNull();
  });
});

import { parseProductFilters, parseProductPage } from '../../src/catalog/api/product-filters.js';
import { CatalogCursorCodec } from '../../src/catalog/common/catalog-cursor.js';
import { etagMatches, etagOfBody } from '../../src/catalog/common/catalog-http.js';
import { CatalogViewerService } from '../../src/catalog/common/catalog-viewer.js';
import { projectStock, stockLevelOf } from '../../src/catalog/common/stock-projection.js';
import { parseInventoryCheck } from '../../src/catalog/inventory/inventory.service.js';
import { parseSecretRing } from '../../src/common/crypto/secret-ring.js';
import type { ProblemException } from '../../src/common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../src/common/rbac/permission-catalog.js';
import type { SettingsReader } from '../../src/common/settings/settings-reader.js';

/** Unit-проверки правил каталога без БД (RM-E-004, RM-E-014, RM-E-017). */
function problemOf(fn: () => unknown): { code: string; rules: string[] } {
  try {
    fn();
  } catch (e) {
    const p = e as ProblemException;
    return { code: p.code, rules: (p.extensions.errors ?? []).map((x) => x.rule) };
  }
  throw new Error('ожидалось исключение');
}

describe('catalog: unit', () => {
  it('stockLevelOf: in_stock ≥ порога, low — между 0 и порогом, out ≤ 0, unknown — нет снимка', () => {
    expect(stockLevelOf('5.000', '5')).toBe('in_stock');
    expect(stockLevelOf('4.999', '5')).toBe('low');
    expect(stockLevelOf('0.000', '5')).toBe('out');
    expect(stockLevelOf('-1.000', '5')).toBe('out');
    expect(stockLevelOf(null, '5')).toBe('unknown');
  });

  it('projectStock: customer status — без количеств; quantity — только available; staff — все поля', () => {
    const key = { variantId: 'v', warehouseId: 'w', warehouseName: 'Основной', unitId: 'u' };
    const fig = { quantity: '10', reserved: '2', available: '8', asOf: new Date('2026-10-22T06:00:00Z') };
    expect(projectStock({ stockDisplay: 'status', lowStockThreshold: '5' }, key, fig)).toEqual({
      variantId: 'v',
      warehouseId: 'w',
      warehouseName: 'Основной',
      asOf: '2026-10-22T06:00:00.000Z',
      stockLevel: 'in_stock',
    });
    expect(projectStock({ stockDisplay: 'quantity', lowStockThreshold: '5' }, key, fig)).toEqual({
      variantId: 'v',
      warehouseId: 'w',
      warehouseName: 'Основной',
      available: '8.000',
      asOf: '2026-10-22T06:00:00.000Z',
      stockLevel: 'in_stock',
    });
    expect(projectStock({ stockDisplay: 'full', lowStockThreshold: '5' }, key, fig)).toMatchObject({
      quantity: '10.000',
      reserved: '2.000',
      available: '8.000',
      unitId: 'u',
    });
    expect(projectStock({ stockDisplay: 'full', lowStockThreshold: '5' }, key, null)).toEqual({
      variantId: 'v',
      warehouseId: 'w',
      warehouseName: 'Основной',
      stockLevel: 'unknown',
    });
  });

  it('курсор: AES-GCM (содержимое не читается, ревью E-api-1), подделка → rule cursor, другая сортировка → cursor_sort_mismatch', () => {
    const ring = parseSecretRing('OTP_HMAC_SECRET', 'x'.repeat(40), 1, 'staging');
    const codec = new CatalogCursorCodec(ring);
    const c = codec.encode({ o: 'price:asc', s: '100.00', id: '019a0000-0000-7000-8000-000000000001' });
    const leaked = Buffer.from(c.split('.')[0] ?? '', 'base64url').toString('latin1');
    expect(leaked).not.toContain('100.00');
    expect(leaked).not.toContain('price');
    expect(codec.encode({ o: 'price:asc', s: '100.00', id: '019a0000-0000-7000-8000-000000000001' })).toBe(c);
    expect(codec.decode(c, 'price:asc')).toEqual({
      o: 'price:asc',
      s: '100.00',
      id: '019a0000-0000-7000-8000-000000000001',
    });
    const [body] = c.split('.');
    const forged = `${Buffer.from(JSON.stringify({ v: 1, o: 'price:asc', s: '0.00', id: 'x' })).toString('base64url')}.${c.split('.')[1]}`;
    expect(problemOf(() => codec.decode(forged, 'price:asc')).rules).toEqual(['cursor']);
    expect(problemOf(() => codec.decode(`${body}.AAAA`, 'price:asc')).rules).toEqual(['cursor']);
    expect(problemOf(() => codec.decode('garbage', 'price:asc')).rules).toEqual(['cursor']);
    expect(problemOf(() => codec.decode(c, 'name:asc')).rules).toEqual(['cursor_sort_mismatch']);
    const other = new CatalogCursorCodec(parseSecretRing('OTP_HMAC_SECRET', 'y'.repeat(40), 1, 'staging'));
    expect(problemOf(() => other.decode(c, 'price:asc')).rules).toEqual(['cursor']);
  });

  it('фильтры и страница: limit 1…200 (по умолчанию 40), sort из перечня, Money-строки, attr ≤ 10, brand ≤ 50', () => {
    expect(parseProductPage({})).toEqual({ sort: 'name:asc', limit: 40 });
    expect(parseProductPage({ limit: '200', sort: 'available:desc' })).toEqual({ sort: 'available:desc', limit: 200 });
    expect(problemOf(() => parseProductPage({ limit: '201' })).rules).toEqual(['maximum']);
    expect(problemOf(() => parseProductPage({ limit: '0' })).rules).toEqual(['minimum']);
    expect(problemOf(() => parseProductPage({ sort: 'weight:asc' })).rules).toEqual(['sort_field']);
    const f = parseProductFilters({
      categoryId: '019A0000-0000-7000-8000-000000000001',
      inStock: 'true',
      priceMin: '100.00',
      priceMax: '5000.00',
      brand: 'Grohe, Frap',
      'attr[color]': 'хром',
      unknownParam: 'ignored',
    });
    expect(f).toMatchObject({
      categoryId: '019a0000-0000-7000-8000-000000000001',
      includeSubcategories: true,
      inStock: true,
      priceMin: '100.00',
      priceMax: '5000.00',
      brand: ['Grohe', 'Frap'],
      attr: { color: 'хром' },
    });
    expect(parseProductFilters({ attr: { size: '20 мм' } }).attr).toEqual({ size: '20 мм' });
    expect(problemOf(() => parseProductFilters({ priceMin: '100' })).rules).toEqual(['money_format']);
    expect(problemOf(() => parseProductFilters({ priceMin: '10.00', priceMax: '5.00' })).rules).toEqual(['range']);
    const many = Object.fromEntries(Array.from({ length: 11 }, (_, i) => [`attr[k${i}]`, 'v']));
    expect(problemOf(() => parseProductFilters(many)).rules).toEqual(['max_properties']);
    const brands = Array.from({ length: 51 }, (_, i) => `b${i}`).join(',');
    expect(problemOf(() => parseProductFilters({ brand: brands })).rules).toEqual(['max_items']);
    expect(problemOf(() => parseProductFilters({ inStock: 'yes' })).rules).toEqual(['type']);
  });

  it('тело /inventory/check: additionalProperties=false, формат количества, ≤ 200 строк', () => {
    const v = '019a0000-0000-7000-8000-000000000001';
    expect(
      parseInventoryCheck({ warehouseId: v, items: [{ variantId: v, quantity: { value: '2.5', unitId: v } }] }),
    ).toEqual({
      warehouseId: v,
      items: [{ variantId: v, value: '2.5', unitId: v, packagingId: null }],
    });
    expect(problemOf(() => parseInventoryCheck({ warehouseId: v, items: [], x: 1 })).rules.sort()).toEqual([
      'additional_properties',
      'min_items',
    ]);
    expect(
      problemOf(() =>
        parseInventoryCheck({ warehouseId: v, items: [{ variantId: v, quantity: { value: '1.2345', unitId: v } }] }),
      ).rules,
    ).toEqual(['quantity_format']);
    expect(problemOf(() => parseInventoryCheck(null)).code).toBe('VALIDATION_FAILED');
  });

  it('ETag: слабый валидатор по телу; If-None-Match — список и *', () => {
    const e = etagOfBody({ a: 1 });
    expect(e).toMatch(/^W\/".+"$/);
    expect(etagOfBody({ a: 1 })).toBe(e);
    expect(etagOfBody({ a: 2 })).not.toBe(e);
    expect(etagMatches(`W/"x", ${e}`, e)).toBe(true);
    expect(etagMatches('*', e)).toBe(true);
    expect(etagMatches(undefined, e)).toBe(false);
  });

  // 12 T-CAT-032 (CUSTOMER_SELF_SERVICE=false)
  it('CUSTOMER_SELF_SERVICE=false → customer получает 403 FORBIDDEN; staff — без изменений (10 CASH-006)', async () => {
    const settings = { get: () => Promise.resolve(undefined) } as unknown as SettingsReader;
    const pool = { query: () => Promise.resolve({ rows: [] }) } as never;
    const off = new CatalogViewerService(pool, new PermissionCatalog(), settings, { CUSTOMER_SELF_SERVICE: false });
    const customer = { userId: 'u', kind: 'customer' as const, roles: ['customer'] };
    await expect(off.resolve(customer)).rejects.toMatchObject({ code: 'FORBIDDEN' });
    const staff = await off.resolve({ userId: 'u', kind: 'staff', roles: ['seller'] });
    expect(staff).toMatchObject({
      isCustomer: false,
      stockDisplay: 'full',
      canReadAllPrices: false,
      lowStockThreshold: '5',
    });
    const on = new CatalogViewerService(pool, new PermissionCatalog(), settings, { CUSTOMER_SELF_SERVICE: true });
    expect(await on.resolve(customer)).toMatchObject({
      isCustomer: true,
      stockDisplay: 'status',
      canReadAllPrices: false,
    });
    await expect(on.resolve(customer, { priceListId: 'x' })).rejects.toMatchObject({ code: 'FORBIDDEN' });
    await expect(
      on.resolve({ userId: 'u', kind: 'staff', roles: ['seller'] }, { priceListId: 'x' }),
    ).rejects.toMatchObject({
      code: 'FORBIDDEN',
    });
  });
});

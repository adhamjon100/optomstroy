import { describe, expect, it } from 'vitest';
import type { PaymentMethod } from '../../src/common/enums.js';
import type { PermissionCode } from '../../src/common/rbac/permissions.generated.js';
import type { CartActor } from '../../src/cart/cart-actor.js';
import { CheckoutService } from '../../src/cart/checkout.service.js';
import type { CartItemRow, CartRow } from '../../src/cart/cart.repository.js';
import { signPreviewToken } from '../../src/cart/preview-token.js';
import { Money, Quantity } from '../../src/common/money/money.js';
import { type PricedLine, priceCart } from '../../src/sales-domain/pricing/cart-pricing.js';

/**
 * Ветви `CheckoutService` / CheckoutPolicy (13 RM-F-009 «создание заказа — 100 % веток»; ревью F-trace-2, FIX-F-23),
 * которые сквозные сценарии с БД не задевают без подмены: роль без лимита скидки, подтверждающий без роли, подтверждение
 * скидки в сессии со step-up, решения по долгу без остатка лимита, override долга без step-up, отсутствие продаваемых
 * строк, исчезновение строк между чтением и обновлением, восстановление корзины из заказа. **Тестовые данные**: фейки
 * зависимостей (без PostgreSQL). Сценарии с БД — cart-flow.e2e, cart-customer-port.e2e, orders-*.e2e.
 */
const ME = '0192f3a1-0000-7000-8000-0000000000a1';
const OTHER = '0192f3a1-0000-7000-8000-0000000000a2';
const CART = '0192f3a1-0000-7000-8000-0000000000a3';
const V1 = '0192f3a1-0000-7000-8000-0000000000a4';
const V2 = '0192f3a1-0000-7000-8000-0000000000a5';
const ORDER = '0192f3a1-0000-7000-8000-0000000000a6';
const hmac = { pseudonym: (d: string, v: string) => `sig(${d}:${v.length})` };

function cartRow(over: Partial<CartRow> = {}): CartRow {
  return {
    id: CART,
    owner_user_id: ME,
    created_by_user_id: ME,
    customer_id: null,
    warehouse_id: 'w',
    price_list_id: 'pl',
    status: 'active',
    name: null,
    requested_discount_percent: '0.00',
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
    row_version: 3,
    created_at: new Date('2026-10-23T00:00:00Z'),
    updated_at: new Date('2026-10-23T00:00:00Z'),
    ...over,
  };
}

function item(variant: string, lineNo: number, packaging: string | null = null): CartItemRow {
  return {
    id: `i${lineNo}`,
    cart_id: CART,
    variant_id: variant,
    packaging_id: packaging,
    quantity: '1',
    base_quantity: '1',
    price_snapshot: '100.00',
    stock_snapshot: null,
    price_changed: false,
    stock_insufficient: false,
    line_no: lineNo,
    added_at: new Date('2026-10-23T00:00:00Z'),
  };
}

function actor(perms: PermissionCode[], over: Partial<CartActor> = {}): CartActor {
  return {
    userId: ME,
    role: 'seller',
    roles: ['seller'],
    isCustomer: false,
    permissions: new Set(perms),
    stockDisplay: 'exact' as never,
    lowStockThreshold: '5',
    sessionId: null,
    deviceId: null,
    requestId: null,
    ...over,
  };
}
const SELLER: PermissionCode[] = ['order.create', 'discount.apply.within_limit', 'credit.sale.create'];

interface Fx {
  cart?: CartRow;
  items?: CartItemRow[];
  sellable?: boolean;
  sku?: string | null;
  limit?: Record<string, { maxPercent: string; canApproveOverLimit: boolean; approveMaxPercent: string | null } | null>;
  approverRole?: string | null;
  other?: CartRow | null;
  byIdLocked?: CartRow | null;
  credit?: Record<string, unknown>;
  inventory?: { unavailable: string[]; shortages: { variantId: string }[] } | Error;
  conflicts?: { variantId: string; kind: string }[];
  // restore / release
  restored?: CartRow | null;
  order?: Record<string, unknown> | null;
  active?: CartRow | null;
  activeItems?: CartItemRow[];
  ttl?: unknown;
  inserted?: CartRow | null;
  updates?: (CartRow | null)[];
  found?: { id: string; status: string; row_version: number }[];
}

function service(f: Fx = {}) {
  const items = f.items ?? [item(V1, 1)];
  const updates = [...(f.updates ?? [])];
  const repo = {
    items: (_ex: unknown, id: string) => Promise.resolve(id === CART ? items : (f.activeItems ?? [])),
    findById: (_ex: unknown, _id: string, lock?: boolean) =>
      Promise.resolve(lock ? (f.byIdLocked === undefined ? (f.cart ?? cartRow()) : f.byIdLocked) : (f.other ?? null)),
    findRestored: () => Promise.resolve(f.restored ?? null),
    findActive: () => Promise.resolve(f.active ?? null),
    update: (_tx: unknown, id: string) => Promise.resolve(updates.length > 0 ? updates.shift() : cartRow({ id })),
    insert: () => Promise.resolve(f.inserted === undefined ? cartRow({ id: 'restored' }) : f.inserted),
    insertItems: () => Promise.resolve(),
  };
  const evaluate = (
    _ex: unknown,
    _a: CartActor,
    cart: CartRow,
    opts?: { items: CartItemRow[]; manualPercentOverride: string },
  ) => {
    const o = opts ?? { items: [], manualPercentOverride: '0.00' };
    const lines = o.items.map((it) => ({
      item: it,
      quote: {
        productId: 'p',
        productName: 'Товар',
        variantName: null,
        sku: f.sku === undefined ? 'SKU' : f.sku,
        unitId: 'u',
        baseUnitId: 'u',
        sellable: f.sellable !== false,
        unitCode: 'шт',
        packagingName: null,
        packagingFactor: null,
        barcode: null,
        available: '10',
      },
      priceable: true,
      priced: null as PricedLine | null | undefined,
      conflicts: [],
      variantBase: '1',
      remaining: '9',
    }));
    const priced = priceCart({
      lines: o.items.map((it) => ({
        lineNo: it.line_no,
        variantId: it.variant_id,
        packagingId: it.packaging_id,
        quantity: Quantity.of(it.quantity),
        unitPrice: Money.of('100.00'),
      })),
      customerDiscountPercent: null,
      manualDiscountPercent: o.manualPercentOverride,
    });
    lines.forEach((l, i) => (l.priced = priced.lines[i]));
    return Promise.resolve({
      e: {
        cart,
        lines,
        priced,
        conflicts: f.conflicts ?? [],
        discount: {},
        customerDiscountPercent: '0.00',
        unitsCount: '1',
      },
      customer: null,
    });
  };
  const ex = {
    execute: () =>
      Promise.resolve({
        rows:
          f.found ??
          (f.order !== undefined ? (f.order ? [f.order] : []) : [{ role: f.approverRole ?? null, ok: true }]),
      }),
  };
  const carts = {
    run: (fn: (e: unknown) => unknown) => fn(ex),
    assertVersion: () => Promise.resolve(),
    ensureActive: () => Promise.resolve(f.cart ?? cartRow()),
    evaluate,
  };
  const actors = {
    discountLimit: (role: string) =>
      Promise.resolve(
        f.limit && role in f.limit
          ? f.limit[role]
          : { maxPercent: '5.00', canApproveOverLimit: role !== 'seller', approveMaxPercent: '20.00' },
      ),
    toSalesActor: (a: CartActor) => ({ userId: a.userId, roles: a.roles, isCustomer: a.isCustomer }),
    fromSalesActor: (s: { userId: string; roles: string[]; isCustomer: boolean }) =>
      Promise.resolve(actor(SELLER, { userId: s.userId, isCustomer: s.isCustomer })),
  };
  const svc = new CheckoutService(
    carts as never,
    repo as never,
    actors as never,
    { check: () => Promise.resolve({ performed: true, at: new Date('2026-10-23T08:00:00Z'), result: 'ok' }) } as never,
    hmac as never,
    { get: (k: string) => Promise.resolve(k === 'parked_cart_ttl_days' ? (f.ttl ?? 7) : 'none') } as never,
    {
      check: () =>
        f.inventory instanceof Error
          ? Promise.reject(f.inventory)
          : Promise.resolve(f.inventory ?? { unavailable: [], shortages: [] }),
    } as never,
    {
      check: () =>
        Promise.resolve(
          f.credit ?? { allowed: true, overrideUsed: false, limitRemaining: null, receivablesAsOf: null },
        ),
    } as never,
    { QR_PROVIDER: 'onec' } as never,
    { now: () => new Date('2026-10-23T08:00:00Z') },
  );
  return { svc, ex };
}

const preview = (over: Record<string, unknown> = {}) =>
  ({
    cartId: CART,
    cartRowVersion: 3,
    paymentMethod: 'cash' as PaymentMethod,
    manualDiscountPercent: null,
    creditOverride: null,
    strict: false,
    syncCheckWithOnec: false,
    ...over,
  }) as never;

describe('CheckoutService.preview: ветви (RM-F-009)', () => {
  it('две строки одного варианта (упаковки) — один источник строки; без SKU — поле опущено', async () => {
    const { svc } = service({ items: [item(V1, 1), item(V1, 2, 'pack')], sku: null });
    const r = (await svc.preview(actor(SELLER), preview())) as { items: Record<string, unknown>[] };
    expect(r.items).toHaveLength(2);
    expect(r.items[0]).not.toHaveProperty('sku');
  });

  it('скидка сверх лимита (нестрого): needsOverride; роль без лимита — limitPercent 0.00', async () => {
    const r1 = (await service().svc.preview(actor(SELLER), preview({ manualDiscountPercent: '7.00' }))) as {
      permissions: { needsOverride: string[]; discountLimitPercent: string; canCreateOrder: boolean };
    };
    expect(r1.permissions).toMatchObject({
      needsOverride: ['discount'],
      discountLimitPercent: '5.00',
      canCreateOrder: false,
    });
    const r2 = (await service({ limit: { seller: null } }).svc.preview(
      actor(SELLER),
      preview({ manualDiscountPercent: '1.00' }),
    )) as {
      permissions: { needsOverride: string[]; discountLimitPercent: string };
    };
    expect(r2.permissions).toMatchObject({ needsOverride: ['discount'], discountLimitPercent: '0.00' });
  });

  it('скидка, подтверждённая в корзине: подтверждающий без роли — без подтверждения; без лимита роли — без подтверждения; без причины — «подтверждено»', async () => {
    const approved = cartRow({ requested_discount_percent: '7.00', discount_approved_by_user_id: OTHER });
    const r1 = (await service({ cart: approved, approverRole: null }).svc.preview(actor(SELLER), preview())) as {
      permissions: { needsOverride: string[] };
    };
    expect(r1.permissions.needsOverride).toEqual(['discount']);
    const r2 = (await service({ cart: approved, approverRole: 'admin', limit: { admin: null } }).svc.preview(
      actor(SELLER),
      preview(),
    )) as {
      permissions: { needsOverride: string[] };
    };
    expect(r2.permissions.needsOverride).toEqual(['discount']);
    const { svc } = service({ cart: approved, approverRole: 'admin' });
    const v = await svc.validateForCheckout(null, { userId: ME, roles: ['seller'], isCustomer: false }, {});
    expect(v.cart).toMatchObject({ discountApprovedByUserId: OTHER, discountOverrideReason: 'подтверждено' });
  });

  it('долг разрешён без остатка лимита — limitRemaining не выводится', async () => {
    const r = (await service({ cart: cartRow({ customer_id: 'c1' }) }).svc.preview(
      actor(SELLER),
      preview({ paymentMethod: 'credit' }),
    )) as {
      paymentChecks: Record<string, unknown>;
    };
    expect(r.paymentChecks).toEqual({
      creditAllowed: true,
      creditReason: null,
      receivablesAsOf: null,
      receivablesStale: false,
    });
  });

  it('override долга: без credit.sale.approve → 403; в предпросмотре step-up не требуется', async () => {
    const c = cartRow({ customer_id: 'c1' });
    await expect(
      service({ cart: c }).svc.preview(
        actor(SELLER),
        preview({ paymentMethod: 'credit', creditOverride: { reason: 'клиент надёжный' } }),
      ),
    ).rejects.toMatchObject({ code: 'FORBIDDEN' });
    const r = await service({ cart: c }).svc.preview(
      actor([...SELLER, 'credit.sale.approve']),
      preview({ paymentMethod: 'credit', creditOverride: { reason: 'клиент надёжный' } }),
    );
    expect(r).toMatchObject({ paymentChecks: { creditAllowed: true } });
  });

  it('нет продаваемых строк — без обращения к остаткам; остатки: недоступные и нехватки, уже найденные — без дублей', async () => {
    const r1 = (await service({ sellable: false }).svc.preview(actor(SELLER), preview())) as { ok: boolean };
    expect(r1.ok).toBe(true);
    const r2 = (await service({
      items: [item(V1, 1), item(V2, 2)],
      conflicts: [
        { variantId: V1, kind: 'variant_unavailable' },
        { variantId: V2, kind: 'stock_insufficient' },
      ],
      inventory: { unavailable: [V1, V2], shortages: [{ variantId: V2 }, { variantId: V1 }] },
    }).svc.preview(actor(SELLER), preview())) as { conflicts: { variantId: string; kind: string }[] };
    expect(r2.conflicts.map((c) => `${c.variantId}:${c.kind}`).sort()).toEqual(
      [
        `${V1}:variant_unavailable`,
        `${V2}:stock_insufficient`,
        `${V2}:variant_unavailable`,
        `${V1}:stock_insufficient`,
      ].sort(),
    );
  });

  it('сбой сервиса остатков — только журнал (конфликты пересчёта корзины); cartView — DTO корзины', async () => {
    const { svc, ex } = service({ inventory: new Error('inventory недоступен (тест)') });
    const r = (await svc.preview(actor(SELLER), preview())) as { ok: boolean };
    expect(r.ok).toBe(true);
    const dto = await svc.cartView(ex as never, actor(SELLER), cartRow());
    expect(dto).toMatchObject({ id: CART, status: 'active' });
  });

  it('чужая/оформленная корзина cartId: своя не активная → 409 cart_<status>', async () => {
    await expect(
      service({ other: cartRow({ id: 'x', status: 'parked' }) }).svc.preview(actor(SELLER), preview({ cartId: 'x' })),
    ).rejects.toMatchObject({ code: 'ORDER_STATE_INVALID', extensions: { reason: 'cart_parked' } });
  });
});

describe('CheckoutService.validateForCheckout (порт CartReader): ветви (RM-F-009)', () => {
  const sales = { userId: ME, roles: ['seller'], isCustomer: false };

  it('в транзакции вызывающего: корзина под блокировкой (или прежняя строка); способ по умолчанию cash', async () => {
    const { svc, ex } = service({ byIdLocked: null });
    const v = await svc.validateForCheckout(ex as never, sales, { cartId: CART });
    expect(v.ok).toBe(true);
    const { svc: s2, ex: ex2 } = service();
    expect((await s2.validateForCheckout(ex2 as never, sales, {})).allowedPaymentMethods).toContain('cash');
  });

  it('клиент: ручная скидка > 0 → 403; 0 — допустима', async () => {
    const { svc } = service();
    const customer = { userId: ME, roles: ['customer'], isCustomer: true };
    await expect(svc.validateForCheckout(null, customer, { manualDiscountPercent: '1.00' })).rejects.toMatchObject({
      code: 'FORBIDDEN',
    });
    expect((await svc.validateForCheckout(null, customer, { manualDiscountPercent: '0.00' })).ok).toBe(true);
  });

  it('скидка сверх лимита с discountOverride в сессии: step-up и право — подтверждение; роль без лимита — нет', async () => {
    const a = { userId: ME, roles: ['senior_seller'], isCustomer: false };
    const { svc } = service({
      limit: { seller: { maxPercent: '5.00', canApproveOverLimit: true, approveMaxPercent: '20.00' } },
    });
    // fromSalesActor фейка даёт права SELLER: без discount.approve.over_limit — строгий отказ.
    await expect(
      svc.validateForCheckout(null, a, {
        manualDiscountPercent: '7.00',
        discountOverride: { reason: 'постоянный клиент' },
        stepUpVerified: true,
      }),
    ).rejects.toMatchObject({ code: 'DISCOUNT_LIMIT_EXCEEDED' });
  });

  it('previewToken другой корзины/версии → 422 PRICE_CHANGED preview_cart_changed', async () => {
    const { svc } = service();
    const token = signPreviewToken(hmac as never, {
      cartId: 'other',
      cartRowVersion: 3,
      total: '100.00',
      paymentMethod: 'cash',
      validUntil: '2026-10-23T09:00:00Z',
      onecCheckAt: null,
      onecResult: 'ok',
    });
    await expect(svc.validateForCheckout(null, sales, { previewToken: token })).rejects.toMatchObject({
      code: 'PRICE_CHANGED',
      extensions: { reason: 'preview_cart_changed' },
    });
  });
});

describe('CheckoutService: discountOverride сессии (approverLimit) — ветви (RM-F-009)', () => {
  it('право discount.approve.over_limit + step-up: подтверждение сессии; лимита роли нет — без подтверждения', async () => {
    const perms: PermissionCode[] = [...SELLER, 'discount.approve.over_limit'];
    const run = (limit: Fx['limit']) => {
      const s = service({ limit });
      (s.svc as unknown as { actors: { fromSalesActor: unknown } }).actors.fromSalesActor = () =>
        Promise.resolve(actor(perms, { role: 'senior_seller', roles: ['senior_seller'] }));
      return s.svc.validateForCheckout(
        null,
        { userId: ME, roles: ['senior_seller'], isCustomer: false },
        {
          manualDiscountPercent: '7.00',
          discountOverride: { reason: 'постоянный клиент' },
          stepUpVerified: true,
        },
      );
    };
    const ok = await run({
      senior_seller: { maxPercent: '5.00', canApproveOverLimit: true, approveMaxPercent: '20.00' },
    });
    expect(ok.cart).toMatchObject({ discountApprovedByUserId: ME, discountOverrideReason: 'постоянный клиент' });
    await expect(run({ senior_seller: null })).rejects.toMatchObject({ code: 'DISCOUNT_LIMIT_EXCEEDED' });
  });
});

describe('CheckoutService: override долга при POST /orders — ветви (RM-F-009)', () => {
  it('creditOverride без step-up → 403 STEP_UP_REQUIRED; со step-up — решение с override', async () => {
    const run = (stepUpVerified: boolean) => {
      const s = service({
        cart: cartRow({ customer_id: 'c1' }),
        credit: { allowed: true, overrideUsed: true, limitRemaining: '50.00', receivablesAsOf: null },
      });
      (s.svc as unknown as { actors: { fromSalesActor: unknown } }).actors.fromSalesActor = () =>
        Promise.resolve(actor([...SELLER, 'credit.sale.approve']));
      return s.svc.validateForCheckout(
        null,
        { userId: ME, roles: ['senior_seller'], isCustomer: false },
        {
          paymentMethod: 'credit',
          creditOverride: { reason: 'клиент надёжный' },
          stepUpVerified,
        },
      );
    };
    await expect(run(false)).rejects.toMatchObject({ code: 'STEP_UP_REQUIRED' });
    expect((await run(true)).credit).toEqual({ allowed: true, overrideUsed: true });
  });
});

describe('CheckoutService: конвертация и восстановление корзины — ветви (RM-F-009)', () => {
  it('markConverted: нет корзины → 404; строка изменилась при обновлении → 409', async () => {
    await expect(
      service({ byIdLocked: null }).svc.markConverted('TX' as never, {
        cartId: CART,
        expectedRowVersion: 3,
        orderId: ORDER,
      }),
    ).rejects.toMatchObject({ code: 'NOT_FOUND' });
    await expect(
      service({ updates: [null] }).svc.markConverted('TX' as never, {
        cartId: CART,
        expectedRowVersion: 3,
        orderId: ORDER,
      }),
    ).rejects.toMatchObject({ code: 'VERSION_CONFLICT' });
  });

  it('restoreFromOrder: повтор — та же отложенная; заказа нет → 404; TTL настройки неверен → 7 дней; вставка не удалась → 500', async () => {
    const { svc, ex } = service({ restored: cartRow({ id: 'r1', status: 'parked' }) });
    expect(await svc.restoreFromOrder(ex as never, { orderId: ORDER, ownerUserId: ME })).toEqual({
      cartId: 'r1',
      status: 'parked',
    });
    const s2 = service({ order: null });
    await expect(s2.svc.restoreFromOrder(s2.ex as never, { orderId: ORDER, ownerUserId: ME })).rejects.toMatchObject({
      code: 'NOT_FOUND',
    });
    const orderRow = {
      customer_id: null,
      warehouse_id: 'w',
      price_list_id: 'pl',
      discount_percent: '0.00',
      public_number: 'POS-1',
    };
    const s3 = service({ order: orderRow, ttl: 'x', active: cartRow({ id: 'act' }), activeItems: [item(V1, 1)] });
    expect(await s3.svc.restoreFromOrder(s3.ex as never, { orderId: ORDER, ownerUserId: ME })).toEqual({
      cartId: 'restored',
      status: 'parked',
    });
    const s4 = service({ order: orderRow, inserted: null });
    await expect(s4.svc.restoreFromOrder(s4.ex as never, { orderId: ORDER, ownerUserId: ME })).rejects.toMatchObject({
      code: 'INTERNAL',
    });
  });

  it('releaseRestored: нет корзин → none; изменённая/оформленная → modified; обновление не удалось → modified; иначе cleared', async () => {
    const run = (found: Fx['found'], updates?: (CartRow | null)[]) => {
      const s = service({ found, updates });
      return s.svc.releaseRestored(s.ex as never, { orderId: ORDER, ownerUserId: ME });
    };
    expect(await run([])).toEqual({ outcome: 'none', cartIds: [] });
    expect((await run([{ id: 'c1', status: 'converted', row_version: 1 }])).outcome).toBe('modified');
    expect((await run([{ id: 'c1', status: 'parked', row_version: 2 }])).outcome).toBe('modified');
    expect((await run([{ id: 'c1', status: 'cleared', row_version: 1 }])).outcome).toBe('none');
    expect((await run([{ id: 'c1', status: 'active', row_version: 1 }], [null])).outcome).toBe('modified');
    expect(await run([{ id: 'c1', status: 'parked', row_version: 1 }])).toEqual({
      outcome: 'cleared',
      cartIds: ['c1'],
    });
  });
});

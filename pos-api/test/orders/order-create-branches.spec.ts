import type { SQL } from 'drizzle-orm';
import { PgDialect } from 'drizzle-orm/pg-core';
import { describe, expect, it } from 'vitest';
import type { PaymentMethod } from '../../src/common/enums.js';
import {
  type CheckoutCartSnapshot,
  type CheckoutValidation,
  PortNotBoundError,
  type SalesActor,
} from '../../src/common/ports/index.js';
import { ProblemException } from '../../src/common/problem-details/problem.exception.js';
import { OrderCreateService, sameItems } from '../../src/orders/order-create.service.js';

/**
 * Ветви `OrderCreateService` (13 RM-F-009 «создание заказа — 100 % веток»; ревью F-trace-2, FIX-F-23), которые сквозные
 * сценарии с БД не задевают без подмены портов: порт `OrderCreator` с системным субъектом и режимом клиента, ответы
 * `CheckoutPolicy` с конфликтом без кода, отказом 1С, решением по долгу, повторными предупреждениями, сбой QR после
 * COMMIT, отсутствие системного клиента и строки заказа после INSERT. **Тестовые данные**: фейки портов и БД
 * (запросы различаются по тексту SQL), без PostgreSQL. Сценарии с БД — orders-create.e2e, orders-trace-f.e2e,
 * orders-money-rules.e2e.
 */
const dialect = new PgDialect();

const RETAIL = '0192f3a1-0000-7000-8000-0000000000e0';
const CUST = '0192f3a1-0000-7000-8000-0000000000e1';
const CART = '0192f3a1-0000-7000-8000-0000000000e2';
const V = '0192f3a1-0000-7000-8000-0000000000e3';
const U = '0192f3a1-0000-7000-8000-0000000000e4';
const ME = '0192f3a1-0000-7000-8000-0000000000e5';

function snapshot(over: Partial<CheckoutCartSnapshot> = {}): CheckoutCartSnapshot {
  return {
    cartId: CART,
    rowVersion: 3,
    ownerUserId: ME,
    customerId: null,
    warehouseId: '0192f3a1-0000-7000-8000-0000000000f1',
    priceListId: '0192f3a1-0000-7000-8000-0000000000f2',
    customerDiscountPercent: '0.00',
    manualDiscountPercent: '0.00',
    discountApprovedByUserId: null,
    discountOverrideReason: null,
    subtotal: '100.00',
    customerDiscountTotal: '0.00',
    manualDiscountTotal: '0.00',
    discountTotal: '0.00',
    total: '100.00',
    lines: [
      {
        lineNo: 1,
        variantId: V,
        productId: '0192f3a1-0000-7000-8000-0000000000f3',
        packagingId: null,
        quantity: '1.000',
        baseQuantity: '1.000',
        unitPrice: '100.00',
        lineSubtotal: '100.00',
        customerDiscountAmount: '0.00',
        manualDiscountAmount: '0.00',
        discountAmount: '0.00',
        lineTotal: '100.00',
        unitCode: 'шт',
        packagingName: null,
        packagingFactor: null,
        productName: 'Товар',
        variantName: null,
        sku: null,
        barcode: null,
      },
    ],
    ...over,
  };
}

function validation(
  over: Partial<CheckoutValidation> = {},
  snap: Partial<CheckoutCartSnapshot> = {},
): CheckoutValidation {
  return {
    ok: true,
    conflicts: [],
    cart: snapshot(snap),
    allowedPaymentMethods: ['cash', 'qr_bakai', 'credit'],
    onecCheck: { performed: true, at: new Date('2026-10-23T08:00:00Z'), result: 'ok' },
    credit: null,
    warnings: [],
    ...over,
  };
}

interface H {
  validate?: CheckoutValidation | (() => Promise<CheckoutValidation>);
  retail?: string | null;
  orderRow?: boolean;
  dup?: Record<string, unknown>[];
  contact?: Record<string, unknown>[];
  linked?: string | null;
  afterCommit?: () => Promise<{ warnings: { code: string; message: string }[] }>;
  presentById?: () => Promise<Record<string, unknown>>;
  perms?: string[];
  audits?: { action: string; reason?: string; after?: Record<string, unknown> }[];
  tx?: string[];
  /** Текст и параметры каждого запроса — проверка значений, которые даёт ветвь (ревью RC-5). */
  queries?: { sql: string; params: unknown[] }[];
  kickFails?: boolean;
  auditFails?: string;
  /** Решение CreditDecisionService (в т. ч. повторная проверка в транзакции, `allowRefresh=false`; ревью G-credit-3). */
  credit?: (i: { override: unknown; allowRefresh?: boolean }) => Promise<Record<string, unknown>>;
  notified?: Record<string, unknown>[];
}

function service(h: H = {}) {
  const tx = h.tx ?? [];
  const queries = h.queries ?? [];
  const exec = (q: SQL) => {
    const { sql: s, params } = dialect.sqlToQuery(q);
    tx.push(s);
    queries.push({ sql: s, params });
    if (s.includes('is_retail_default')) return { rows: h.retail === null ? [] : [{ id: h.retail ?? RETAIL }] };
    if (s.includes("nextval('orders_number_seq')")) return { rows: [{ n: '7' }] };
    if (s.includes('credit_days')) return { rows: [{ d: 30 }] };
    if (s.includes('customer_links')) return { rows: h.linked ? [{ customer_id: h.linked }] : [] };
    if (s.includes("interval '60 seconds'")) return { rows: h.dup ?? [] };
    if (s.includes('user_profiles')) return { rows: h.contact ?? [] };
    if (s.includes('FROM orders o WHERE o.id')) return { rows: h.orderRow === false ? [] : [{ id: 'order-row' }] };
    return { rows: [] };
  };
  const txObj = { execute: (q: SQL) => Promise.resolve(exec(q)) };
  const db = { execute: txObj.execute, transaction: (fn: (t: unknown) => unknown) => fn(txObj) };
  const audits = h.audits ?? [];
  const perms = new Set(
    h.perms ?? ['payment.qr.show', 'credit.sale.create', 'discount.approve.over_limit', 'credit.sale.approve'],
  );
  const cart = {
    validateForCheckout: () =>
      typeof h.validate === 'function' ? h.validate() : Promise.resolve(h.validate ?? validation()),
    markConverted: () => Promise.resolve(),
  };
  const views = {
    viewer: (p: { userId: string }) =>
      Promise.resolve({
        actor: { userId: p.userId, roles: ['seller'], isCustomer: false },
        permissions: perms,
        linkedCustomerId: null,
      }),
    present: () => Promise.resolve({ id: 'order-row', publicNumber: 'POS-2026-000007', payments: [{ id: 'pay-1' }] }),
    presentById:
      h.presentById ??
      ((_v: unknown, _id: string, o: { warnings: unknown[] }) =>
        Promise.resolve({ id: 'order-row', publicNumber: 'POS-2026-000007', warnings: o.warnings })),
  };
  return new OrderCreateService(
    db as never,
    { QR_PROVIDER: 'onec' } as never,
    { now: () => new Date('2026-10-23T08:00:00Z') },
    cart as never,
    {
      createInitial: () => Promise.resolve({ paymentId: 'pay-1' }),
      afterCommit: h.afterCommit ?? (() => Promise.resolve({ warnings: [] })),
    } as never,
    {
      enqueue: () => Promise.resolve(),
      kickAfterCommit: () => (h.kickFails ? Promise.reject(new Error('pg-boss недоступен (тест)')) : Promise.resolve()),
    } as never,
    {
      check: (_tx: unknown, i: { override: unknown; allowRefresh?: boolean }) =>
        h.credit ? h.credit(i) : Promise.resolve({ allowed: true, overrideUsed: i.override !== null }),
    } as never,
    {
      write: (_c: unknown, e: { action: string; reason?: string; after?: Record<string, unknown> }) => {
        audits.push(e);
        return h.auditFails === e.action ? Promise.reject(new Error('аудит недоступен (тест)')) : Promise.resolve();
      },
    } as never,
    { recordInTransaction: () => Promise.resolve(), complete: () => Promise.resolve() } as never,
    { verify: () => Promise.resolve({ method: 'pin' }) } as never,
    views as never,
    { effectivePermissions: () => perms } as never,
    h.notified
      ? ({
          notify: (_tx: unknown, n: Record<string, unknown>) => {
            h.notified!.push(n);
            return Promise.resolve({ id: 'n1', created: true });
          },
        } as never)
      : undefined,
  );
}

const staff = (over: Partial<SalesActor> = {}): SalesActor => ({
  userId: ME,
  roles: ['seller'],
  isCustomer: false,
  ...over,
});
const cmd = (over: Record<string, unknown> = {}) =>
  ({
    actor: staff(),
    idempotencyKey: 'key-1',
    cartRowVersion: 3,
    paymentMethod: 'cash' as PaymentMethod,
    deliveryMethod: 'pickup' as const,
    ...over,
  }) as never;

const body = (over: Record<string, unknown> = {}) => ({
  cartId: CART,
  cartRowVersion: 3,
  receiver: { kind: 'customer' },
  delivery: { method: 'pickup' },
  paymentMethod: 'cash',
  items: [{ variantId: V, quantity: { value: '1', unitId: U, packagingId: null } }],
  ...over,
});
const req = (headers: Record<string, unknown>, id?: unknown) => ({ headers, id, ip: '127.0.0.1' }) as never;
const principal = { userId: ME } as never;

describe('OrderCreateService: ветви HTTP-входа (RM-F-009)', () => {
  it('Idempotency-Key: нет / пустой → 400; массив заголовков — первый; X-Request-Id не строка → null', async () => {
    await expect(service().createHttp(principal, req({}), body(), undefined)).rejects.toMatchObject({
      code: 'VALIDATION_FAILED',
    });
    await expect(
      service().createHttp(principal, req({ 'idempotency-key': '' }), body(), undefined),
    ).rejects.toMatchObject({
      code: 'VALIDATION_FAILED',
    });
    const r = await service().createHttp(principal, req({ 'idempotency-key': ['k-arr', 'k2'] }, 42), body(), undefined);
    expect(r.httpStatus).toBe(201);
  });

  it('cartId тела не совпадает с корзиной CheckoutPolicy → 409 VERSION_CONFLICT', async () => {
    const h = service({ validate: validation({}, { cartId: '0192f3a1-0000-7000-8000-0000000000aa' }) });
    await expect(h.createHttp(principal, req({ 'idempotency-key': 'k' }), body(), undefined)).rejects.toMatchObject({
      code: 'VERSION_CONFLICT',
    });
  });

  it('customerId тела не совпадает с клиентом корзины (staff) → 409 VERSION_CONFLICT', async () => {
    const h = service({ validate: validation({}, { customerId: CUST }) });
    await expect(
      h.createHttp(
        principal,
        req({ 'idempotency-key': 'k' }),
        body({ customerId: '0192f3a1-0000-7000-8000-0000000000ab' }),
        undefined,
      ),
    ).rejects.toMatchObject({ code: 'VERSION_CONFLICT' });
  });

  it('discountOverride с короткой причиной — в аудите дополняется до 5 символов (11 SEC-076)', async () => {
    const audits: { action: string; reason?: string }[] = [];
    await service({
      audits,
      // Корзина применила подтверждение сверх лимита из этого запроса (overrideApplied → подтверждающий).
      validate: validation(
        {},
        {
          manualDiscountPercent: '7.00',
          manualDiscountTotal: '7.00',
          discountApprovedByUserId: ME,
          discountOverrideReason: 'да',
        },
      ),
    }).createHttp(
      principal,
      req({ 'idempotency-key': 'k' }),
      body({ manualDiscountPercent: '7.00', discountOverride: { reason: 'да' } }),
      'step',
    );
    expect(audits.find((a) => a.action === 'discount.over_limit_approved')?.reason).toBe('причина: да');
  });
});

describe('OrderCreateService: ветви CheckoutPolicy (RM-F-009)', () => {
  it('пустая корзина → CART_EMPTY; отказ /check 1С → ONEC_REJECTED; способ не разрешён → 422', async () => {
    await expect(service({ validate: validation({}, { lines: [] }) }).createFromCart(cmd())).rejects.toMatchObject({
      code: 'CART_EMPTY',
    });
    await expect(
      service({
        validate: validation({ onecCheck: { performed: true, at: null, result: 'rejected' } }),
      }).createFromCart(cmd()),
    ).rejects.toMatchObject({ code: 'ONEC_REJECTED' });
    await expect(
      service({ validate: validation({ allowedPaymentMethods: ['qr_bakai'] }) }).createFromCart(cmd()),
    ).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
  });

  it('конфликты: без элементов и с неизвестным видом → PRICE_CHANGED', async () => {
    await expect(service({ validate: validation({ ok: false }) }).createFromCart(cmd())).rejects.toMatchObject({
      code: 'PRICE_CHANGED',
    });
    await expect(
      service({
        validate: validation({ ok: false, conflicts: [{ variantId: V, kind: 'something_new' as never }] }),
      }).createFromCart(cmd()),
    ).rejects.toMatchObject({ code: 'PRICE_CHANGED' });
  });

  it('отказ по долгу из CheckoutPolicy (строгий режим): creditReason строкой и без клиента в команде — аудит credit.sale_blocked', async () => {
    const audits: { action: string; after?: Record<string, unknown> }[] = [];
    const refuse = () =>
      Promise.reject(new ProblemException('CREDIT_BLOCKED', { detail: 'x', creditReason: 'overdue' }));
    await expect(
      service({ audits, validate: refuse }).createFromCart(cmd({ paymentMethod: 'credit' })),
    ).rejects.toMatchObject({
      code: 'CREDIT_BLOCKED',
    });
    expect(audits[0]).toMatchObject({
      action: 'credit.sale_blocked',
      after: { customerId: null, creditReason: 'overdue' },
    });
  });

  it('решение корзины по долгу: запрет → CREDIT_BLOCKED; разрешение с override — транзакция и аудит подтверждения', async () => {
    const audits: { action: string }[] = [];
    await expect(
      service({
        audits,
        validate: validation({ credit: { allowed: false, overrideUsed: false } }, { customerId: CUST }),
      }).createFromCart(cmd({ paymentMethod: 'credit' })),
    ).rejects.toMatchObject({ code: 'CREDIT_BLOCKED' });
    const r = await service({
      audits,
      validate: validation({ credit: { allowed: true, overrideUsed: true } }, { customerId: CUST }),
    }).createFromCart(cmd({ paymentMethod: 'credit', creditOverride: { reason: 'клиент надёжный' } }));
    expect(r.httpStatus).toBe(201);
    expect(audits.map((a) => a.action)).toContain('credit.sale_approved');
  });

  it('повторная проверка долга в транзакции заказа отказала (параллельный заказ занял лимит) → 422, аудит, credit_blocked', async () => {
    const audits: { action: string; after?: Record<string, unknown> }[] = [];
    const notified: Record<string, unknown>[] = [];
    const credit = (i: { allowRefresh?: boolean }) =>
      Promise.resolve(
        i.allowRefresh === false
          ? {
              allowed: false,
              code: 'CREDIT_LIMIT_EXCEEDED',
              creditReason: 'limit_exceeded',
              detail: 'Превышен лимит: доступно 0,00 сом.',
              limitRemaining: '-50.00',
              receivablesAsOf: new Date('2026-10-23T07:00:00Z'),
            }
          : { allowed: true, overrideUsed: false },
      );
    await expect(
      service({
        audits,
        notified,
        credit,
        validate: validation({ credit: { allowed: true, overrideUsed: false } }, { customerId: CUST }),
      }).createFromCart(cmd({ paymentMethod: 'credit' })),
    ).rejects.toMatchObject({ code: 'CREDIT_LIMIT_EXCEEDED', extensions: { creditReason: 'limit_exceeded' } });
    expect(audits.map((a) => a.action)).toEqual(['credit.sale_blocked']);
    expect(audits[0].after).toMatchObject({
      customerId: CUST,
      refusalCode: 'CREDIT_LIMIT_EXCEEDED',
      limitRemaining: '-50.00',
      receivablesAsOf: '2026-10-23T07:00:00.000Z',
    });
    expect(notified).toEqual([
      expect.objectContaining({ kind: 'credit_blocked', body: 'Превышен лимит задолженности клиента.' }),
    ]);
    // Повторная проверка разрешила только благодаря creditOverride → подтверждение записывается (overrideUsed).
    const audits2: { action: string }[] = [];
    await service({
      audits: audits2,
      credit: (i) => Promise.resolve({ allowed: true, overrideUsed: i.allowRefresh === false }),
      validate: validation({ credit: { allowed: true, overrideUsed: false } }, { customerId: CUST }),
    }).createFromCart(cmd({ paymentMethod: 'credit', creditOverride: { reason: 'клиент надёжный' } }));
    expect(audits2.map((a) => a.action)).toContain('credit.sale_approved');
  });

  it('202 без проверки 1С: повторное STALE_DATA из CheckoutPolicy не дублируется', async () => {
    const r = await service({
      validate: validation({
        onecCheck: { performed: true, at: null, result: 'unavailable' },
        warnings: [
          { code: 'STALE_DATA', message: 'dup' },
          { code: 'QR_UNAVAILABLE', message: 'новое' },
        ],
      }),
    }).createFromCart(cmd());
    expect(r.httpStatus).toBe(202);
    expect(r.warnings.map((w) => w.code)).toEqual(['STALE_DATA', 'QR_UNAVAILABLE']);
  });

  it('скидка, подтверждённая в корзине, без причины — «подтверждено в корзине»; системный субъект без userId', async () => {
    const audits: { action: string; reason?: string }[] = [];
    const r = await service({
      audits,
      validate: validation(
        {},
        { discountApprovedByUserId: ME, discountOverrideReason: null, manualDiscountTotal: '7.00' },
      ),
    }).createFromCart(cmd({ actor: staff({ userId: null }), discountOverride: { reason: 'системное подтверждение' } }));
    expect(r.httpStatus).toBe(201);
    expect(audits.some((a) => a.action === 'discount.over_limit_approved')).toBe(true);
    const r2 = await service({
      audits,
      validate: validation(
        {},
        { discountApprovedByUserId: ME, discountOverrideReason: null, manualDiscountTotal: '7.00' },
      ),
    }).createFromCart(cmd());
    expect(r2.httpStatus).toBe(201);
    expect(audits.filter((a) => a.action === 'discount.over_limit_approved').at(-1)?.reason).toBe(
      'подтверждено в корзине',
    );
  });
});

describe('OrderCreateService: ветви режима клиента и окружения (RM-F-009)', () => {
  const customer = (over: Partial<SalesActor> = {}) => staff({ isCustomer: true, roles: ['customer'], ...over });

  it('режим клиента: overrides → 403; ручная скидка в снимке корзины → 403; контакт аккаунта без профиля — null', async () => {
    await expect(
      service().createFromCart(cmd({ actor: customer(), discountOverride: { reason: 'хочу скидку' } })),
    ).rejects.toMatchObject({ code: 'FORBIDDEN' });
    await expect(
      service({ validate: validation({}, { manualDiscountTotal: '5.00' }) }).createFromCart(cmd({ actor: customer() })),
    ).rejects.toMatchObject({ code: 'FORBIDDEN' });
    // Контакт аккаунта (receiver kind=customer без имени/телефона в запросе): профиль есть — его имя и телефон в
    // INSERT заказа; профиля нет (запрос user_profiles пуст) — receiver_name и receiver_phone_e164 = NULL.
    const NAME = 'Айбек Профилев';
    const PHONE = '+996555000111';
    const insertOf = (qs: { sql: string; params: unknown[] }[]) => {
      const ins = qs.filter((q) => q.sql.includes('INSERT INTO orders ('));
      expect(ins).toHaveLength(1);
      return ins[0];
    };
    const withProfile: { sql: string; params: unknown[] }[] = [];
    const r0 = await service({
      linked: CUST,
      contact: [{ name: NAME, phone: PHONE }],
      queries: withProfile,
    }).createFromCart(cmd({ actor: customer() }));
    expect(r0.httpStatus).toBe(201);
    const p0 = insertOf(withProfile).params;
    const nameAt = p0.indexOf(NAME);
    expect(nameAt).toBeGreaterThanOrEqual(0);
    expect(p0[nameAt + 1]).toBe(PHONE); // receiver_name, receiver_phone_e164 — соседние параметры INSERT
    const noProfile: { sql: string; params: unknown[] }[] = [];
    const r = await service({ linked: CUST, contact: [], queries: noProfile }).createFromCart(
      cmd({ actor: customer() }),
    );
    expect(r.httpStatus).toBe(201);
    expect(noProfile.some((q) => q.sql.includes('user_profiles'))).toBe(true); // ветвь accountContact выполнена
    const p = insertOf(noProfile).params;
    expect(p).toHaveLength(p0.length);
    expect(p[nameAt]).toBeNull();
    expect(p[nameAt + 1]).toBeNull();
  });

  it('нет системного клиента «Розничный покупатель» → ошибка seed', async () => {
    await expect(service({ retail: null }).createFromCart(cmd())).rejects.toThrow('Розничный покупатель');
  });

  it('заказ не найден после INSERT → ошибка; представление без платежей — paymentId null; сбой представления после COMMIT — тело транзакции', async () => {
    await expect(service({ orderRow: false }).createFromCart(cmd())).rejects.toThrow('не найден после INSERT');
    const r = await service({
      presentById: () => Promise.resolve({ id: 'order-row', publicNumber: 'POS-2026-000007' }),
    }).createFromCart(cmd());
    expect(r.paymentId).toBeNull();
    const r2 = await service({ presentById: () => Promise.reject(new Error('present failed (тест)')) }).createFromCart(
      cmd(),
    );
    expect(r2.paymentId).toBe('pay-1');
  });

  it('мягкий дубль: строки без состава (items NULL) не совпадают — заказ создаётся', async () => {
    const recent = (items: unknown) => ({
      id: 'o-1',
      public_number: 'POS-1',
      customer_id: RETAIL,
      payment_method: 'cash',
      total: '100.00',
      created_at: new Date('2026-10-23T07:59:50Z'),
      items,
    });
    // Контроль: та же строка с совпадающим составом — 409 possible_duplicate (фейк действительно даёт дубль).
    await expect(
      service({ dup: [recent([{ v: V, p: null, q: '1.000' }])] }).createFromCart(cmd()),
    ).rejects.toMatchObject({
      code: 'ORDER_STATE_INVALID',
      extensions: { reason: 'possible_duplicate', possibleDuplicateOrderId: 'o-1' },
    });
    // items NULL — состав пуст, хэш не совпадает: поиск дубля выполнен, 409 нет, заказ вставлен.
    const tx: string[] = [];
    const r = await service({ dup: [recent(null)], tx }).createFromCart(cmd());
    expect(r.httpStatus).toBe(201);
    expect(tx.some((s) => s.includes("interval '60 seconds'"))).toBe(true);
    expect(tx.filter((s) => s.includes('INSERT INTO orders ('))).toHaveLength(1);
  });

  it('QR после COMMIT: предупреждения без дублей; порт не привязан и прочий сбой → QR_UNAVAILABLE', async () => {
    const r1 = await service({
      validate: validation({ onecCheck: { performed: false, at: null, result: 'unavailable' } }),
      afterCommit: () =>
        Promise.resolve({
          warnings: [
            { code: 'STALE_DATA', message: 'повтор' },
            { code: 'QR_UNAVAILABLE', message: 'нет QR' },
          ],
        }),
    }).createFromCart(cmd({ paymentMethod: 'qr_bakai' }));
    expect(r1.warnings.map((w) => w.code)).toEqual(['STALE_DATA', 'QR_UNAVAILABLE']);
    for (const err of [new PortNotBoundError('PAYMENTS'), new Error('1С недоступна (тест)')]) {
      const r = await service({ afterCommit: () => Promise.reject(err) }).createFromCart(
        cmd({ paymentMethod: 'qr_bakai' }),
      );
      expect(r.warnings.map((w) => w.code)).toContain('QR_UNAVAILABLE');
    }
  });

  it('сбой пробуждения outbox после COMMIT и сбой аудита отказа в долге — только журнал', async () => {
    expect((await service({ kickFails: true }).createFromCart(cmd())).httpStatus).toBe(201);
    const refuse = () => Promise.reject(new ProblemException('CREDIT_LIMIT_EXCEEDED', { detail: 'x' }));
    await expect(
      service({ validate: refuse, auditFails: 'credit.sale_blocked' }).createFromCart(cmd({ paymentMethod: 'credit' })),
    ).rejects.toMatchObject({ code: 'CREDIT_LIMIT_EXCEEDED' });
  });

  it('sameItems: разное число строк → false', () => {
    expect(sameItems([], [{ variantId: V, packagingId: null, quantity: '1' }])).toBe(false);
  });
});

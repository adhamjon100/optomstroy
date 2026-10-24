import { CUSTOMER_READER, SYSTEM_ACTOR } from '../../src/common/ports/index.js';
import { CASHIER_SCENARIO_PHONES } from '../../src/integrations/onec/synthetic-cashier.js';
import type { CashierWorld } from '../support/cashier-fixture.js';
import type { PosActor } from '../support/pos-fixture.js';
import { apiErrors, CustomersTestApp, viewSchemaFor } from './support/customers-app.js';

/**
 * RM-G-001, RM-G-011, часть RM-G-004 (агент G-be-customers) на embedded PostgreSQL 17 (**тестовые данные**: мир кассира
 * `cashier-fixture`, фейк 1С): поля карточки по роли (схема ответа `CustomerView*` — allowlist), список и фильтры,
 * поиск по правилам роли, суммы долга только с правом и `include=receivable` (+ аудит), сигнал `customer.phone_lookup`,
 * избранные клиенты (до 12, IDOR), порт `CUSTOMER_READER`.
 */
let t: CustomersTestApp;
let w: CashierWorld;

const ROLES = ['seller', 'cashier', 'senior_seller', 'admin', 'owner'] as const;

beforeAll(async () => {
  t = await new CustomersTestApp().start({ env: { QR_PROVIDER: 'none' } });
  w = await t.seedCashierWorld();
}, 600_000);

afterAll(async () => {
  await t?.stop();
});

function staff(role: (typeof ROLES)[number]): PosActor {
  return w.actors[role];
}

describe('GET /customers/{id} — поля по роли (08 §3.7, CUST-001; T-CUST-001)', () => {
  it('seller не получает поле долга и полных контактов даже с include=receivable (схема CustomerViewSeller)', async () => {
    const res = await t.req(
      'get',
      `/customers/${w.customers.debtWithinLimit.id}?include=receivable,contacts`,
      staff('seller'),
    );
    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(apiErrors('CustomerViewSeller', res.body)).toEqual([]);
    expect(res.body.receivable).toBeUndefined();
    expect(res.body.phones).toBeUndefined();
    expect(res.body.inn).toBeUndefined();
    expect(res.body.contacts).toBeUndefined();
    expect(res.body).toMatchObject({ hasDebt: true, isOverdue: false, phoneMasked: '+996 7** *** *56' });
    expect(await t.auditRows('customer.debt_viewed', w.customers.debtWithinLimit.id)).toHaveLength(0);
  });

  it('каждая роль сотрудника — ровно свой allowlist; суммы — только с правом и include=receivable', async () => {
    for (const role of ROLES) {
      const res = await t.req('get', `/customers/${w.customers.overdue.id}`, staff(role));
      expect(res.status).toBe(200);
      expect(apiErrors(viewSchemaFor(role), res.body)).toEqual([]);
      expect(res.body.receivable).toBeUndefined();
      expect(res.body).toMatchObject({ hasDebt: true, isOverdue: true, source: 'onec', onecStatus: 'n_a' });
    }
    const cashier = await t.req('get', `/customers/${w.customers.overdue.id}?include=receivable`, staff('cashier'));
    expect(apiErrors('CustomerViewCashier', cashier.body)).toEqual([]);
    expect(cashier.body.receivable).toMatchObject({
      balance: { amount: '8000.00', currency: 'KGS' },
      overdueAmount: { amount: '8000.00', currency: 'KGS' },
      creditLimit: { amount: '50000.00', currency: 'KGS' },
      limitRemaining: { amount: '42000.00', currency: 'KGS' },
    });
    // CUST-003: «подтверждён» — только номер, подтверждённый OTP при привязке аккаунта.
    expect(cashier.body.phones).toEqual([{ value: CASHIER_SCENARIO_PHONES.overdue, verified: false }]);
    const audit = await t.auditRows('customer.debt_viewed', w.customers.overdue.id);
    expect(audit).toHaveLength(1);
    // Единый формат с ReceivablesService: объём и метка снимка 1С (11 §7.2, SEC-032; ревью G-security-8).
    expect(audit[0]).toMatchObject({
      actor_user_id: staff('cashier').userId,
      after: { scope: 'summary', via: 'card', snapshotAt: cashier.body.receivable.asOf },
    });
  });

  it('клиент-покупатель: своя карточка при confirmed (CustomerViewSelf, links, суммы); proposed/чужая → 404', async () => {
    const own = await t.req('get', `/customers/${w.customers.buyer.id}?include=receivable,links`, w.buyerConfirmed);
    expect(own.status).toBe(200);
    expect(apiErrors('CustomerViewSelf', own.body)).toEqual([]);
    expect(own.body.source).toBeUndefined();
    expect(own.body.isFavorite).toBeUndefined();
    expect(own.body.receivable).toBeDefined();
    expect(own.body.links).toHaveLength(1);
    expect(own.body.links[0]).toMatchObject({ userId: w.buyerConfirmed.userId, status: 'confirmed' });
    expect((await t.req('get', `/customers/${w.customers.buyer.id}`, w.buyerProposed)).status).toBe(404);
    expect((await t.req('get', `/customers/${w.customers.overdue.id}`, w.buyerConfirmed)).status).toBe(404);
  });

  it('phones[].verified=true — номер совпадает с подтверждённым OTP при привязке (customer_links confirmed, CUST-003)', async () => {
    const user = await t.actor({ role: 'customer' });
    await t.pool.query(
      `INSERT INTO customer_links (user_id, customer_id, status, match_method, matched_phone_e164, confirmed_at)
       VALUES ($1::uuid, $2::uuid, 'confirmed', 'phone', $3, now())`,
      [user.userId, w.customers.noLimit.id, CASHIER_SCENARIO_PHONES.noLimit],
    );
    const res = await t.req('get', `/customers/${w.customers.noLimit.id}`, staff('cashier'));
    expect(res.body.phones).toEqual([{ value: CASHIER_SCENARIO_PHONES.noLimit, verified: true }]);
    const card = await t.registry.get(CUSTOMER_READER).get(null, w.customers.noLimit.id);
    expect(card?.phones).toEqual([{ value: CASHIER_SCENARIO_PHONES.noLimit, verified: true }]);
  });

  it('include=discounts — блок CustomersDiscountsResponse; лимит долга в условиях — только с правом на суммы', async () => {
    const id = w.customers.debtWithinLimit.id;
    const cashier = await t.req('get', `/customers/${id}?include=discounts`, staff('cashier'));
    expect(apiErrors('CustomersDiscountsResponse', cashier.body.discounts)).toEqual([]);
    expect(cashier.body.discounts.creditTerms).toMatchObject({
      creditAllowed: true,
      creditLimit: { amount: '100000.00', currency: 'KGS' },
    });
    const seller = await t.req('get', `/customers/${id}?include=discounts`, staff('seller'));
    expect(apiErrors('CustomerViewSeller', seller.body)).toEqual([]);
    expect(seller.body.discounts.creditTerms.creditLimit).toBeUndefined();
  });

  it('POS-клиент «ожидает 1С»: onecStatus=pending, onecRef=null, суммы долга не отдаются (not_in_onec)', async () => {
    const res = await t.req('get', `/customers/${w.customers.posPending.id}?include=receivable`, staff('cashier'));
    expect(res.body).toMatchObject({ source: 'pos', onecStatus: 'pending', onecRef: null });
    expect(res.body.receivable).toBeUndefined();
    expect(res.body.phones).toEqual([{ value: w.customers.posPending.phone, verified: false }]);
  });

  it('include: admin получает links; неизвестное значение → 400; не-UUID → 404; нет карточки → 404', async () => {
    const admin = await t.req('get', `/customers/${w.customers.buyer.id}?include=links`, staff('admin'));
    expect(apiErrors('CustomerViewAdmin', admin.body)).toEqual([]);
    expect((admin.body.links as unknown[]).length).toBe(2);
    const cashier = await t.req('get', `/customers/${w.customers.buyer.id}?include=links`, staff('cashier'));
    expect(cashier.body.links).toBeUndefined();
    expect((await t.req('get', `/customers/${w.customers.buyer.id}?include=balance`, staff('cashier'))).status).toBe(
      400,
    );
    expect((await t.req('get', '/customers/not-a-uuid', staff('cashier'))).status).toBe(404);
    expect((await t.req('get', '/customers/0192e0b2-0000-7000-8000-00000000dead', staff('cashier'))).status).toBe(404);
  });

  it('ordersCount/lastOrderAt: заказы POS и реализации 1С без заказа; избранное — isFavorite', async () => {
    const res = await t.req('get', `/customers/${w.customers.buyer.id}`, staff('cashier'));
    expect(res.body.ordersCount).toBeGreaterThanOrEqual(3);
    expect(res.body.lastOrderAt).not.toBeNull();
    expect(res.body.isFavorite).toBe(true);
    const other = await t.req('get', `/customers/${w.customers.buyer.id}`, staff('senior_seller'));
    expect(other.body.isFavorite).toBe(false);
  });
});

describe('GET /customers — список (08 §4.11.1, SCR-31)', () => {
  it('cashier+: фильтры hasDebt/isOverdue/favorite/customerType; элементы без сумм; курсор', async () => {
    const debt = await t.req('get', '/customers?hasDebt=true&limit=200', staff('cashier'));
    expect(debt.status).toBe(200);
    const ids = (debt.body.items as { id: string; hasDebt: boolean; receivable?: unknown }[]).map((x) => x.id);
    expect(ids).toContain(w.customers.overdue.id);
    expect(ids).not.toContain(w.customers.noDebt.id);
    expect(ids).not.toContain(w.customers.retail.id);
    for (const it of debt.body.items as Record<string, unknown>[]) {
      expect(it.hasDebt).toBe(true);
      expect(it.receivable).toBeUndefined();
      expect(apiErrors('CustomerViewCashier', it)).toEqual([]);
    }
    const overdue = await t.req('get', '/customers?isOverdue=true&limit=200', staff('cashier'));
    expect((overdue.body.items as { isOverdue: boolean }[]).every((x) => x.isOverdue)).toBe(true);
    const fav = await t.req('get', '/customers?favorite=true', staff('cashier'));
    expect((fav.body.items as { id: string }[]).map((x) => x.id).sort()).toEqual(
      [w.customers.buyer.id, w.customers.debtWithinLimit.id].sort(),
    );
    const legal = await t.req('get', '/customers?customerType=individual&limit=200', staff('admin'));
    expect((legal.body.items as { customerType: string }[]).every((x) => x.customerType === 'individual')).toBe(true);
    const p1 = await t.req('get', '/customers?limit=5', staff('cashier'));
    expect(p1.body.hasMore).toBe(true);
    const p2 = await t.req(
      'get',
      `/customers?limit=5&cursor=${encodeURIComponent(p1.body.nextCursor as string)}`,
      staff('cashier'),
    );
    expect(p2.status).toBe(200);
    const ids1 = new Set((p1.body.items as { id: string }[]).map((x) => x.id));
    expect((p2.body.items as { id: string }[]).some((x) => ids1.has(x.id))).toBe(false);
    const byLast = await t.req('get', '/customers?sort=lastOrderAt:desc&limit=3', staff('cashier'));
    expect(byLast.body.items[0].lastOrderAt).not.toBeNull();
    const byLast2 = await t.req(
      'get',
      `/customers?sort=lastOrderAt:desc&limit=3&cursor=${encodeURIComponent(byLast.body.nextCursor as string)}`,
      staff('cashier'),
    );
    expect(byLast2.status).toBe(200);
    // Курсор другой сортировки → 400 (rule cursor).
    const mixed = await t.req(
      'get',
      `/customers?cursor=${encodeURIComponent(byLast.body.nextCursor as string)}`,
      staff('cashier'),
    );
    expect(mixed.status).toBe(400);
  });

  it('include=receivable — суммы с аудитом; seller: hasDebt → 403, без q → 400 search_scope_role; customer → 403', async () => {
    const withSums = await t.req(
      'get',
      `/customers?q=${encodeURIComponent(CASHIER_SCENARIO_PHONES.overLimit)}&include=receivable`,
      staff('owner'),
    );
    expect(withSums.body.items[0].receivable.balance).toEqual({ amount: '49000.00', currency: 'KGS' });
    expect(await t.auditRows('customer.debt_viewed', w.customers.overLimit.id)).toHaveLength(1);
    expect((await t.req('get', '/customers?hasDebt=true', staff('seller'))).status).toBe(403);
    const browse = await t.req('get', '/customers', staff('seller'));
    expect(browse.status).toBe(400);
    expect(browse.body.errors[0]).toMatchObject({ rule: 'search_scope_role' });
    const exact = await t.req(
      'get',
      `/customers?q=${encodeURIComponent(CASHIER_SCENARIO_PHONES.noDebt)}`,
      staff('seller'),
    );
    expect(exact.body.items).toHaveLength(1);
    expect(apiErrors('CustomerViewSeller', exact.body.items[0])).toEqual([]);
    expect((await t.req('get', '/customers', w.actors.customer)).status).toBe(403);
    expect((await t.req('get', '/customers?sort=balance:desc', staff('cashier'))).status).toBe(400);
  });

  it('linkStatus — только admin (очередь SCR-45); cashier → 403; неверное значение → 400', async () => {
    const q = await t.req('get', '/customers?linkStatus=proposed', staff('admin'));
    expect(q.status).toBe(200);
    expect((q.body.items as { id: string }[]).map((x) => x.id)).toContain(w.customers.buyer.id);
    expect((await t.req('get', '/customers?linkStatus=proposed', staff('cashier'))).status).toBe(403);
    expect((await t.req('get', '/customers?linkStatus=confirmed', staff('admin'))).status).toBe(400);
  });
});

describe('GET /search/customers — правила поиска по роли (ядро §19.4, CUST-008/009; RM-G-011 п. 5)', () => {
  it('seller по 4 цифрам телефона — не возвращает результатов (400 search_scope_role); cashier — возвращает', async () => {
    const digits = CASHIER_SCENARIO_PHONES.buyer.slice(-4);
    const seller = await t.req('get', `/search/customers?q=${digits}`, staff('seller'));
    expect(seller.status).toBe(400);
    expect(seller.body.errors[0]).toMatchObject({ rule: 'search_scope_role' });
    const cashier = await t.req('get', `/search/customers?q=${digits}`, staff('cashier'));
    expect(cashier.status).toBe(200);
    expect((cashier.body.items as { id: string }[]).map((x) => x.id)).toContain(w.customers.buyer.id);
    const full = await t.req('get', `/search/customers?q=${encodeURIComponent('0555000109')}`, staff('seller'));
    expect(full.body.items[0]).toMatchObject({
      id: w.customers.buyer.id,
      matchType: 'phone',
      phoneMasked: '+996 5** *** *09',
    });
    expect(full.body.items[0].phones).toBeUndefined();
  });

  it('ReceivableBadge по умолчанию; суммы — cashier с include=receivable (аудит), seller — параметр игнорируется', async () => {
    const q = encodeURIComponent(CASHIER_SCENARIO_PHONES.stale);
    const plain = await t.req('get', `/search/customers?q=${q}`, staff('cashier'));
    expect(plain.body.items[0].receivable).toBeUndefined();
    const sums = await t.req('get', `/search/customers?q=${q}&include=receivable`, staff('cashier'));
    expect(sums.body.items[0].receivable).toBeDefined();
    expect(await t.auditRows('customer.debt_viewed', w.customers.stale.id)).toHaveLength(1);
    const seller = await t.req('get', `/search/customers?q=${q}&include=receivable`, staff('seller'));
    expect(seller.body.items[0].receivable).toBeUndefined();
    expect((await t.req('get', `/search/customers?q=${q}`, w.actors.customer)).status).toBe(403);
  });

  it('«Розничный покупатель» и помеченные на удаление не находятся; имя — от 2 букв; код — точно', async () => {
    const retail = await t.req('get', `/search/customers?q=${encodeURIComponent('Розничный')}`, staff('cashier'));
    expect((retail.body.items as { id: string }[]).map((x) => x.id)).not.toContain(w.customers.retail.id);
    const name = await t.req('get', `/search/customers?q=${encodeURIComponent('Айбек')}`, staff('cashier'));
    expect(name.body.items[0]).toMatchObject({ id: w.customers.buyer.id, matchType: 'name' });
    const code = (await t.customerRow(w.customers.noLimit.id)).onec_code!;
    const byCode = await t.req('get', `/search/customers?q=${encodeURIComponent(code)}`, staff('seller'));
    expect(byCode.body.items[0]).toMatchObject({ id: w.customers.noLimit.id, matchType: 'code' });
    const deleted = await t.q<{ name: string }>(`SELECT name FROM customers WHERE deletion_mark LIMIT 1`);
    if (deleted[0]) {
      const r = await t.req('get', `/search/customers?q=${encodeURIComponent(deleted[0].name)}`, staff('cashier'));
      expect((r.body.items as { name: string }[]).map((x) => x.name)).not.toContain(deleted[0].name);
    }
    expect((await t.req('get', '/search/customers?q=1', staff('cashier'))).body.errors[0].rule).toBe('q_too_short');
  });

  it('сигнал customer.phone_lookup: seller > 50 поисков по телефону за час — одна запись аудита', async () => {
    const seller = await t.actor({ role: 'seller' });
    for (let i = 0; i < 52; i += 1) {
      await t
        .req('get', `/search/customers?q=${encodeURIComponent(CASHIER_SCENARIO_PHONES.noDebt)}`, seller)
        .expect(200);
    }
    const rows = await t.q<{ entity_id: string; severity: string }>(
      `SELECT entity_id, severity FROM audit_logs WHERE action = 'customer.phone_lookup' AND entity_id = $1::uuid`,
      [seller.userId],
    );
    expect(rows).toEqual([{ entity_id: seller.userId, severity: 'warning' }]);
  });
});

describe('/favorites/customers — избранные клиенты (FAV-006; T-FAV-005; RM-G-011 п. 5)', () => {
  it('cashier: список своих, PUT/DELETE идемпотентны, 13-й → 422; чужие не видны (IDOR)', async () => {
    const cashier = await t.actor({ role: 'cashier' });
    const other = await t.actor({ role: 'cashier' });
    const pool = await t.q<{ id: string }>(
      `SELECT id FROM customers WHERE NOT deletion_mark AND NOT is_retail_default AND deleted_at IS NULL
        ORDER BY name LIMIT 13`,
    );
    for (const c of pool.slice(0, 12)) {
      await t.req('put', `/favorites/customers/${c.id}`, cashier).expect(204);
    }
    await t.req('put', `/favorites/customers/${pool[0].id}`, cashier).expect(204); // повтор
    const thirteenth = await t.req('put', `/favorites/customers/${pool[12].id}`, cashier);
    expect(thirteenth.status).toBe(422);
    expect(thirteenth.body).toMatchObject({ code: 'VALIDATION_FAILED' });
    expect(thirteenth.body.errors[0]).toMatchObject({ rule: 'favorites_limit' });
    const list = await t.req('get', '/favorites/customers', cashier);
    expect(list.status).toBe(200);
    expect(list.body.count).toBe(12);
    for (const it of list.body.items as Record<string, unknown>[]) {
      expect(it.receivable).toBeUndefined();
      expect(it.isFavorite).toBe(true);
      expect(apiErrors('CustomerViewCashier', it)).toEqual([]);
    }
    const theirs = await t.req('get', '/favorites/customers', other);
    expect(theirs.body.count).toBe(0);
    // DELETE другим кассиром не трогает чужой список.
    await t.req('delete', `/favorites/customers/${pool[0].id}`, other).expect(204);
    expect((await t.req('get', '/favorites/customers', cashier)).body.count).toBe(12);
    await t.req('delete', `/favorites/customers/${pool[0].id}`, cashier).expect(204);
    await t.req('delete', `/favorites/customers/${pool[0].id}`, cashier).expect(204);
    await t.req('put', `/favorites/customers/${pool[12].id}`, cashier).expect(204);
    expect((await t.req('get', '/favorites/customers?limit=5', cashier)).body).toMatchObject({
      count: 12,
      hasMore: true,
    });
    const outbox = await t.q(`SELECT 1 FROM onec_outbox WHERE aggregate_type = 'customer'`);
    expect(outbox).toHaveLength(0); // FAV-008: избранное в 1С не уходит
  });

  it('права: seller/owner/customer → 403; нет клиента → 404', async () => {
    for (const a of [staff('seller'), staff('owner'), w.actors.customer]) {
      expect((await t.req('get', '/favorites/customers', a)).status).toBe(403);
      expect((await t.req('put', `/favorites/customers/${w.customers.noDebt.id}`, a)).status).toBe(403);
    }
    expect(
      (await t.req('put', '/favorites/customers/0192e0b2-0000-7000-8000-00000000dead', staff('admin'))).status,
    ).toBe(404);
    expect(
      (await t.req('delete', '/favorites/customers/0192e0b2-0000-7000-8000-00000000dead', staff('admin'))).status,
    ).toBe(404);
  });
});

describe('порт CUSTOMER_READER (PgCustomerReader)', () => {
  it('карточка, политика полей, режим клиента (confirmed — self, proposed — null)', async () => {
    const reader = t.registry.get(CUSTOMER_READER);
    const card = await reader.get(null, w.customers.debtWithinLimit.id);
    expect(card).toMatchObject({
      id: w.customers.debtWithinLimit.id,
      onecRef: w.customers.debtWithinLimit.onecRef,
      creditLimit: '100000.00',
      discountPercent: '5.00',
      phones: [{ value: CASHIER_SCENARIO_PHONES.debtWithinLimit, verified: false }],
    });
    expect((await reader.getByOnecRef(null, w.customers.overdue.onecRef!))?.id).toBe(w.customers.overdue.id);
    const seller = reader.fieldPolicy({ userId: w.actors.seller.userId, roles: ['seller'], isCustomer: false });
    expect(seller).toMatchObject({ view: 'seller', receivableAmounts: false, history: false, fullContacts: false });
    const owner = reader.fieldPolicy({ userId: w.actors.owner.userId, roles: ['owner'], isCustomer: false });
    expect(owner).toMatchObject({ view: 'admin', receivableAmounts: true, favorites: false });
    const self = await reader.getForActor(
      null,
      { userId: w.buyerConfirmed.userId, roles: ['customer'], isCustomer: true },
      w.customers.buyer.id,
    );
    expect(self?.access).toMatchObject({ kind: 'self' });
    expect(
      await reader.getForActor(
        null,
        { userId: w.buyerProposed.userId, roles: ['customer'], isCustomer: true },
        w.customers.buyer.id,
      ),
    ).toBeNull();
    expect((await reader.getForActor(null, SYSTEM_ACTOR, w.customers.buyer.id))?.access.kind).toBe('staff');
    expect(await reader.linkOf(null, w.buyerProposed.userId)).toMatchObject({
      status: 'proposed',
      customerId: w.customers.buyer.id,
    });
  });
});

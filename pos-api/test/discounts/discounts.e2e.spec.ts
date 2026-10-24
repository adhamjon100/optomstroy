import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { AdminDiscountLimitsModule } from '../../src/admin/discount-limits/admin-discount-limits.module.js';
import { DISCOUNT_POLICY_PORT, type SalesActor } from '../../src/common/ports/index.js';
import { CustomerDiscountsModule } from '../../src/customers/discounts/discounts.module.js';
import { ReceivablesModule } from '../../src/customers/receivables/receivables.module.js';
import { SyntheticCashier } from '../../src/integrations/onec/synthetic-cashier.js';
import {
  DiscountRulesChangeHandler,
  discountRuleFields,
} from '../../src/sync/discounts/discount-rules.change-handler.js';
import type { ApplyScope, EntityCounts, ItemError } from '../../src/sync/apply/apply.types.js';
import { CashierTestApp, type CashierWorld } from '../support/cashier-fixture.js';
import { F_MODULES, type PosActor, type SaleableVariant } from '../support/pos-fixture.js';

/**
 * Скидки на embedded PostgreSQL 17 — **тестовые данные** (фейк 1С в режиме кассира, `cashier-fixture`):
 * `CustomerDiscountsModule` (порт `DISCOUNT_POLICY_PORT`, `/customers/{id}/discounts`, `/discounts/rules`),
 * `AdminDiscountLimitsModule` (`/admin/discount-limits`), корзина/заказы этапа F (лимит роли и подтверждение сверх
 * лимита), обработчик `/changes` `Catalog_СкидкиНаценки`.
 *
 * Трассировка 13 RM-G-003 (критерии 1–3), 12: T-DISC-003, T-DISC-004, T-DISC-008, T-DISC-009, T-DISC-012,
 * T-DEBT-014; 10 DISC-003, DISC-007, DISC-010, DISC-012, DISC-013.
 */
let t: CashierTestApp;
let w: CashierWorld;
let variants: SaleableVariant[];

const RULE_PERSONAL = 'd15c0000-0000-4000-8000-000000000001';
const RULE_WHOLESALE = 'd15c0000-0000-4000-8000-000000000002';
const SEED = { seller: '5.00', cashier: '5.00', senior_seller: '10.00', admin: '15.00', owner: '0.00' };

beforeAll(async () => {
  t = await new CashierTestApp().start({
    env: { QR_PROVIDER: 'none', ONEC_SYNC_CHECK_TIMEOUT_MS: '1500' },
    modules: [...F_MODULES, ReceivablesModule, CustomerDiscountsModule, AdminDiscountLimitsModule],
  });
  w = await t.seedCashierWorld();
  t.onec.always('checkCart', { transport: true });
  t.onec.always('createOrder', { transport: true });
  variants = await t.saleableVariants(8);
}, 600_000);

afterAll(async () => {
  await t?.stop();
});

const sales = (role: string, isCustomer = false): SalesActor => ({ userId: null, roles: [role], isCustomer });

async function cartWith(a: PosActor, v: SaleableVariant, qty = '2') {
  const c0 = (await t.req('get', '/cart', a)).body as { rowVersion: number };
  const r = await t.req('put', `/cart/items/${v.variantId}`, a).send({
    quantity: { value: qty, unitId: v.unitId, packagingId: null },
    rowVersion: c0.rowVersion,
  });
  expect(r.status, JSON.stringify(r.body)).toBe(200);
  return r.body as { id: string; rowVersion: number };
}

async function discount(a: PosActor, percent: string, extra: Record<string, unknown> = {}, stepUp?: string) {
  const c = (await t.req('get', '/cart', a)).body as { rowVersion: number };
  return t
    .req('post', '/cart/discount', a, stepUp ? { stepUp } : {})
    .send({ percent, rowVersion: c.rowVersion, ...extra });
}

// ============================================================================== лимиты ролей (seed, порт, корзина)

describe('лимиты ручной скидки по ролям из seed (RM-G-003 п. 1; DISC-003; T-DISC-003) [НЕ ПОДТВЕРЖДЕНО: Q-015]', () => {
  it('DiscountPolicyPort: limits/limitFor по seed — seller 5, cashier 5, senior 10, admin 15, owner 0, customer 0', async () => {
    const port = t.registry.get(DISCOUNT_POLICY_PORT);
    const rows = await port.limits(null);
    expect(Object.fromEntries(rows.map((r) => [r.role, r.maxPercent]))).toMatchObject({
      ...SEED,
      customer: '0.00',
      integration: '0.00',
    });
    expect(
      rows
        .filter((r) => r.canApproveOverLimit)
        .map((r) => r.role)
        .sort(),
    ).toEqual(['admin', 'senior_seller']);
    for (const [role, p] of Object.entries(SEED)) expect(await port.limitFor(null, sales(role))).toBe(p);
    expect(await port.limitFor(null, sales('customer', true))).toBe('0.00');
    expect(await port.limitFor(null, sales('nobody'))).toBe('0.00');
    expect(await port.limitFor(null, { userId: null, roles: ['seller', 'admin'], isCustomer: false })).toBe('15.00');
  });

  it('canApproveOverLimit: право discount.approve.over_limit и потолок роли (approve_max_percent ?? max_percent)', async () => {
    const port = t.registry.get(DISCOUNT_POLICY_PORT);
    expect(await port.canApproveOverLimit(null, sales('senior_seller'), '10.00')).toBe(true);
    expect(await port.canApproveOverLimit(null, sales('senior_seller'), '10.01')).toBe(false);
    expect(await port.canApproveOverLimit(null, sales('admin'), '15')).toBe(true);
    expect(await port.canApproveOverLimit(null, sales('cashier'), '1.00')).toBe(false);
    expect(await port.canApproveOverLimit(null, sales('owner'), '0.00')).toBe(false);
    expect(await port.canApproveOverLimit(null, sales('customer', true), '0.00')).toBe(false);
    expect(await port.canApproveOverLimit(null, sales('admin'), 'abc')).toBe(false);
    expect(await port.canApproveOverLimit(null, sales('admin'), '100.01')).toBe(false);
  });

  it('корзина применяет лимиты seed: seller 5 → 200, 7 → 422 DISCOUNT_LIMIT_EXCEEDED {limitPercent 5.00}; senior 10/10.01; admin 15/15.01', async () => {
    const cases: [PosActor, string, string, string][] = [
      [w.actors.seller, '5', '7', '5.00'],
      [w.actors.cashier, '5.00', '5.01', '5.00'],
      [w.actors.senior_seller, '10', '10.01', '10.00'],
      [w.actors.admin, '15', '15.01', '15.00'],
    ];
    for (const [i, [a, ok, over, limit]] of cases.entries()) {
      await cartWith(a, variants[i]);
      const r1 = await discount(a, ok);
      expect(r1.status, JSON.stringify(r1.body)).toBe(200);
      const r2 = await discount(a, over);
      expect(r2.status, `${a.role} ${over}`).toBe(422);
      expect(r2.body).toMatchObject({ code: 'DISCOUNT_LIMIT_EXCEEDED', limitPercent: limit });
    }
  });
});

// ============================================================================== подтверждение сверх лимита

describe('подтверждение скидки сверх лимита (RM-G-003 п. 2; DISC-010, DISC-012; T-DISC-004, T-DISC-008)', () => {
  it('senior_seller со step-up: 15 % (потолок подтверждения 20) → заказ с transactions(discount_override) и аудитом; одобрение 15 % не переносится на 20 %', async () => {
    await t.q(
      `UPDATE role_discount_limits SET approve_max_percent = 20, row_version = row_version + 1 WHERE role = 'senior_seller'`,
    );
    try {
      const s = await t.actor({ role: 'senior_seller' });
      const v = variants[5];
      await cartWith(s, v, '2');
      const noStep = await discount(s, '15', { override: { reason: 'постоянный клиент' } });
      expect(noStep.status).toBe(403);
      expect(noStep.body).toMatchObject({ code: 'STEP_UP_REQUIRED' });
      const ok = await discount(
        s,
        '15',
        { override: { reason: 'постоянный клиент' } },
        await t.stepUp(s, 'discount.approve.over_limit'),
      );
      expect(ok.status, JSON.stringify(ok.body)).toBe(200);
      const cart = (await t.req('get', '/cart', s)).body as { id: string; rowVersion: number };
      const body = (extra: Record<string, unknown> = {}) => ({
        cartId: cart.id,
        cartRowVersion: cart.rowVersion,
        receiver: { kind: 'customer' },
        delivery: { method: 'pickup' },
        paymentMethod: 'cash',
        items: [{ variantId: v.variantId, quantity: { value: '2', unitId: v.unitId, packagingId: null } }],
        ...extra,
      });
      // F-money-rules-2: одобрение корзины действует только на одобренный процент.
      const more = await t.req('post', '/orders', s, { idem: true }).send(body({ manualDiscountPercent: '20' }));
      expect(more.status).toBe(422);
      expect(more.body).toMatchObject({ code: 'DISCOUNT_LIMIT_EXCEEDED' });
      const order = await t.req('post', '/orders', s, { idem: true }).send(body({ manualDiscountPercent: '15' }));
      expect([201, 202], JSON.stringify(order.body)).toContain(order.status);
      const orderId = order.body.id as string;
      const tx = await t.q<{ kind: string }>(`SELECT kind::text AS kind FROM transactions WHERE order_id = $1`, [
        orderId,
      ]);
      expect(tx.map((x) => x.kind)).toContain('discount_override');
      const audit = await t.auditRows('discount.over_limit_approved', orderId);
      expect(audit).toHaveLength(1);
      expect(audit[0]?.after).toMatchObject({ percent: '15.00', approverUserId: s.userId });
    } finally {
      await t.q(
        `UPDATE role_discount_limits SET approve_max_percent = NULL, row_version = row_version + 1 WHERE role = 'senior_seller'`,
      );
    }
  });

  it('cashier не может подтвердить сверх лимита (нет discount.approve.over_limit) → 403', async () => {
    const c = await t.actor({ role: 'cashier' });
    await cartWith(c, variants[6]);
    const r = await discount(
      c,
      '7',
      { override: { reason: 'попытка кассира' } },
      await t.stepUp(c, 'discount.approve.over_limit'),
    );
    expect(r.status).toBe(403);
  });
});

// ============================================================================== /customers/{id}/discounts

describe('GET /customers/{id}/discounts — SCR-35 (08 §4.11.6; DISC-013; T-DISC-009, T-DEBT-014)', () => {
  it('cashier: вид цены, скидка клиента 1С, действующие правила (персональная + оптовая), условия оплаты с лимитом, лимит роли', async () => {
    const c = w.customers.buyer;
    const r = await t.req('get', `/customers/${c.id}/discounts`, w.actors.cashier);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.headers['cache-control']).toBe('no-store');
    expect(r.body.priceList).toMatchObject({ id: await t.defaultPriceListId() });
    expect(typeof r.body.priceList.name).toBe('string');
    expect(r.body.customerDiscountPercent).toBe('5.00');
    const rules = r.body.rules as {
      id: string;
      name: string;
      kind: string;
      value: string;
      conditions: Record<string, unknown>;
    }[];
    expect(rules.map((x) => x.id).sort()).toEqual(
      [w.discountRuleIds.get(RULE_PERSONAL), w.discountRuleIds.get(RULE_WHOLESALE)].sort(),
    );
    const personal = rules.find((x) => x.id === w.discountRuleIds.get(RULE_PERSONAL))!;
    expect(personal).toMatchObject({ source: 'onec', kind: 'percent', value: '5.00', isActive: true });
    // Условие по клиентам сужено до клиента запроса (другие карточки не раскрываются).
    expect(personal.conditions.customerIds).toEqual([c.id]);
    const wholesale = rules.find((x) => x.id === w.discountRuleIds.get(RULE_WHOLESALE))!;
    expect(wholesale.conditions.minTotal).toEqual({ amount: '50000.00', currency: 'KGS' });
    expect(r.body.creditTerms).toMatchObject({ creditAllowed: true });
    expect(r.body.creditTerms).toHaveProperty('creditLimit');
    expect(r.body.manualDiscountLimitPercent).toBe('5.00');
    expect(typeof r.body.asOf).toBe('string');
  });

  it('seller — без creditLimit (нет права на суммы долга); senior — лимит роли 10.00; клиент без персональных правил — только оптовая', async () => {
    const s = await t.req('get', `/customers/${w.customers.buyer.id}/discounts`, w.actors.seller);
    expect(s.status).toBe(200);
    expect(s.body.creditTerms).not.toHaveProperty('creditLimit');
    expect(s.body.manualDiscountLimitPercent).toBe('5.00');
    const sr = await t.req('get', `/customers/${w.customers.noLimit.id}/discounts`, w.actors.senior_seller);
    expect(sr.body.manualDiscountLimitPercent).toBe('10.00');
    expect((sr.body.rules as { id: string }[]).map((x) => x.id)).toEqual([w.discountRuleIds.get(RULE_WHOLESALE)]);
    expect(sr.body.creditTerms).toMatchObject({ creditAllowed: true, creditLimit: null });
  });

  // 11 SEC-030 (в) (владелец RBAC — ядро §18.1; ревью G-security-5): клиенту чужая и несуществующая карточка
  // неразличимы — 404 (существование карточки не раскрывается).
  it('режим клиента: своя confirmed карточка → 200 (лимит 0.00); чужая, proposed и несуществующая → 404; не UUID → 400', async () => {
    const own = await t.req('get', `/customers/${w.customers.buyer.id}/discounts`, w.buyerConfirmed);
    expect(own.status, JSON.stringify(own.body)).toBe(200);
    expect(own.body.manualDiscountLimitPercent).toBe('0.00');
    expect(own.body.creditTerms).toHaveProperty('creditLimit');
    const foreign = await t.req('get', `/customers/${w.customers.overdue.id}/discounts`, w.buyerConfirmed);
    const missing = await t.req('get', `/customers/${randomUUID()}/discounts`, w.buyerConfirmed);
    expect([foreign.status, foreign.body.code]).toEqual([404, 'NOT_FOUND']);
    expect([missing.status, missing.body.code]).toEqual([404, 'NOT_FOUND']);
    expect(foreign.body.detail).toBe(missing.body.detail);
    expect((await t.req('get', `/customers/${w.customers.buyer.id}/discounts`, w.buyerProposed)).status).toBe(404);
    expect((await t.req('get', `/customers/${randomUUID()}/discounts`, w.actors.cashier)).status).toBe(404);
    expect((await t.req('get', '/customers/xyz/discounts', w.actors.cashier)).status).toBe(400);
  });
});

// ============================================================================== /discounts/rules

describe('GET /discounts/rules — правила и потолок роли (08 §4.12.2; D-23)', () => {
  it('cashier без параметров: действующие правила 1С (без истёкших, отключённых, удалённых), limitsByRole, overrideRoles; private, max-age=60', async () => {
    const r = await t.req('get', '/discounts/rules', w.actors.cashier);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.headers['cache-control']).toBe('private, max-age=60');
    expect((r.body.rules as { id: string }[]).map((x) => x.id).sort()).toEqual(
      [w.discountRuleIds.get(RULE_PERSONAL), w.discountRuleIds.get(RULE_WHOLESALE)].sort(),
    );
    expect(r.body.manualDiscountLimitPercent).toBe('5.00');
    expect([...(r.body.overrideRoles as string[])].sort()).toEqual(['admin', 'senior_seller']);
    expect(r.body.limitsByRole).toEqual(SEED);
  });

  it('customerId / cartId (своя корзина с клиентом) сужают правила; чужая корзина и неизвестный клиент → 404; не UUID → 400', async () => {
    const byCustomer = await t.req('get', `/discounts/rules?customerId=${w.customers.noLimit.id}`, w.actors.cashier);
    expect((byCustomer.body.rules as { id: string }[]).map((x) => x.id)).toEqual([
      w.discountRuleIds.get(RULE_WHOLESALE),
    ]);
    const a = await t.actor({ role: 'cashier' });
    const cart = await cartWith(a, variants[7]);
    const set = await t
      .req('post', '/cart/customer', a)
      .send({ customerId: w.customers.buyer.id, rowVersion: cart.rowVersion });
    expect(set.status, JSON.stringify(set.body)).toBe(200);
    const byCart = await t.req('get', `/discounts/rules?cartId=${cart.id}`, a);
    expect(byCart.body.rules).toHaveLength(2);
    expect((await t.req('get', `/discounts/rules?cartId=${cart.id}`, w.actors.cashier)).status).toBe(404);
    expect((await t.req('get', `/discounts/rules?customerId=${randomUUID()}`, a)).status).toBe(404);
    expect((await t.req('get', '/discounts/rules?customerId=1', a)).status).toBe(400);
  });

  it('customer: правила своей карточки без limitsByRole/overrideRoles, лимит 0.00; чужая карточка или без confirmed → 403', async () => {
    const own = await t.req('get', '/discounts/rules', w.buyerConfirmed);
    expect(own.status, JSON.stringify(own.body)).toBe(200);
    expect(own.body.rules).toHaveLength(2);
    expect(own.body.manualDiscountLimitPercent).toBe('0.00');
    expect(own.body.limitsByRole).toBeUndefined();
    expect(own.body.overrideRoles).toBeUndefined();
    expect((await t.req('get', `/discounts/rules?customerId=${w.customers.overdue.id}`, w.buyerConfirmed)).status).toBe(
      403,
    );
    expect((await t.req('get', '/discounts/rules', w.buyerProposed)).status).toBe(403);
  });
});

// ============================================================================== /admin/discount-limits

describe('/admin/discount-limits — изменение лимитов админом (RM-G-003 п. 3; DISC-012; T-DISC-012)', () => {
  const path = '/admin/discount-limits';

  it('GET: admin и owner → 200 (seed); seller, cashier → 403', async () => {
    const r = await t.req('get', path, w.actors.admin);
    expect(r.status).toBe(200);
    expect(r.body.limits).toEqual(SEED);
    expect([...(r.body.overrideRoles as string[])].sort()).toEqual(['admin', 'senior_seller']);
    expect(Number.isInteger(r.body.rowVersion)).toBe(true);
    expect(r.headers['cache-control']).toBe('no-store');
    expect((await t.req('get', path, w.actors.owner)).status).toBe(200);
    expect((await t.req('get', path, w.actors.seller)).status).toBe(403);
    expect((await t.req('get', path, w.actors.cashier)).status).toBe(403);
  });

  it('PUT: без step-up → 403 STEP_UP_REQUIRED; owner/seller → 403 FORBIDDEN; со step-up → 200, аудит discount.limits_changed (before/after, step_up_method), лимит действует сразу', async () => {
    const cur = (await t.req('get', path, w.actors.admin)).body as { rowVersion: number };
    const body = {
      limits: { ...SEED, seller: '7.00' },
      overrideRoles: ['senior_seller', 'admin'],
      rowVersion: cur.rowVersion,
    };
    const no = await t.req('put', path, w.actors.admin).send(body);
    expect(no.status).toBe(403);
    expect(no.body).toMatchObject({
      code: 'STEP_UP_REQUIRED',
      stepUp: { operation: 'settings.discount_limits.update' },
    });
    expect((await t.req('put', path, w.actors.owner).send(body)).body).toMatchObject({ code: 'FORBIDDEN' });
    expect((await t.req('put', path, w.actors.seller).send(body)).status).toBe(403);
    const step = await t.stepUp(w.actors.admin, 'settings.discount_limits.update');
    const ok = await t.req('put', path, w.actors.admin, { stepUp: step }).send(body);
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body.limits.seller).toBe('7.00');
    expect(ok.body.rowVersion).toBeGreaterThan(cur.rowVersion);
    expect(ok.body.updatedBy).toMatchObject({ id: w.actors.admin.userId });
    expect(typeof ok.body.updatedAt).toBe('string');
    const audit = (await t.auditRows('discount.limits_changed')).filter(
      (x) => x.actor_user_id === w.actors.admin.userId,
    );
    const app = audit.find((x) => x.step_up_method === 'pin');
    expect(app?.after).toMatchObject({ limits: { seller: '7.00' } });
    // Построчный аудит уровня БД (триггер role_discount_limits) — тоже есть.
    expect(audit.length).toBeGreaterThan(1);
    // Новый лимит seller действует сразу (корзина читает role_discount_limits).
    const seller = await t.actor({ role: 'seller' });
    await cartWith(seller, variants[3]);
    expect((await discount(seller, '7')).status).toBe(200);
    expect((await discount(seller, '7.01')).body).toMatchObject({ limitPercent: '7.00' });
    expect(await t.registry.get(DISCOUNT_POLICY_PORT).limitFor(null, sales('seller'))).toBe('7.00');
    // Повтор того же тела (прежний rowVersion) → 200 без изменений.
    const replay = await t.req('put', path, w.actors.admin, { stepUp: step }).send(body);
    expect(replay.status).toBe(200);
    expect(replay.body.rowVersion).toBe(ok.body.rowVersion);
    // Устаревшая версия с другим телом → 409 VERSION_CONFLICT.
    const stale = await t
      .req('put', path, w.actors.admin, { stepUp: step })
      .send({ ...body, limits: { ...SEED, seller: '6.00' } });
    expect(stale.status).toBe(409);
    expect(stale.body).toMatchObject({ code: 'VERSION_CONFLICT', current: { rowVersion: ok.body.rowVersion } });
  });

  it('PUT: проверки тела — percent_range/required/лишние поля → 400; роль без права подтверждения → 422; overrideRoles=[] отключает подтверждение', async () => {
    const step = await t.stepUp(w.actors.admin, 'settings.discount_limits.update');
    const cur = (await t.req('get', path, w.actors.admin)).body as {
      rowVersion: number;
      limits: Record<string, string>;
    };
    const base = { limits: cur.limits, overrideRoles: ['senior_seller', 'admin'], rowVersion: cur.rowVersion };
    const send = (b: unknown) => t.req('put', path, w.actors.admin, { stepUp: step }).send(b as object);
    for (const [b, field, rule] of [
      [{ ...base, limits: { ...cur.limits, cashier: '101' } }, 'limits.cashier', 'percent_range'],
      [{ ...base, limits: { ...cur.limits, cashier: '5.555' } }, 'limits.cashier', 'percent_range'],
      [{ ...base, limits: { ...cur.limits, cashier: 5 } }, 'limits.cashier', 'percent_range'],
      [{ ...base, limits: { seller: '1.00' } }, 'limits.owner', 'required'],
      [{ ...base, limits: { ...cur.limits, customer: '1.00' } }, 'limits.customer', 'additional_properties'],
      [{ ...base, extra: 1 }, 'extra', 'additional_properties'],
      [{ ...base, overrideRoles: ['admin', 'admin'] }, 'overrideRoles[1]', 'unique_items'],
      [{ ...base, overrideRoles: ['boss'] }, 'overrideRoles[0]', 'enum'],
      [{ ...base, rowVersion: -1 }, 'rowVersion', 'minimum'],
    ] as const) {
      const r = await send(b);
      expect(r.status, JSON.stringify(b)).toBe(400);
      expect(r.body.errors).toEqual(expect.arrayContaining([expect.objectContaining({ field, rule })]));
    }
    const r422 = await send({ ...base, overrideRoles: ['cashier'] });
    expect(r422.status).toBe(422);
    expect(r422.body.errors[0]).toMatchObject({ field: 'overrideRoles', rule: 'role_cannot_approve' });
    const off = await send({ ...base, overrideRoles: [] });
    expect(off.status, JSON.stringify(off.body)).toBe(200);
    expect(off.body.overrideRoles).toEqual([]);
    expect(await t.registry.get(DISCOUNT_POLICY_PORT).canApproveOverLimit(null, sales('admin'), '1.00')).toBe(false);
    const back = await send({
      limits: SEED,
      overrideRoles: ['senior_seller', 'admin'],
      rowVersion: off.body.rowVersion,
    });
    expect(back.status).toBe(200);
    expect(back.body.limits).toEqual(SEED);
  });
});

// ============================================================================== sync Catalog_СкидкиНаценки

describe('синхронизация Catalog_СкидкиНаценки → discount_rules (05 §5.3; GQ-FND-05)', () => {
  async function apply(items: Record<string, unknown>[]) {
    const c = await t.pool.connect();
    const counts = new Map<string, EntityCounts>();
    const errors: ItemError[] = [];
    try {
      await c.query('BEGIN');
      await c.query(`SELECT set_config('app.system', 'sync', true)`);
      const runId = (
        await c.query<{ id: string }>(
          `INSERT INTO sync_runs (entity, mode, "trigger", status) VALUES ('discounts', 'incremental', 'manual', 'success') RETURNING id`,
        )
      ).rows[0].id;
      const scope = {
        client: c,
        runIdFor: () => Promise.resolve(runId),
        syncedAt: new Date(),
        counts,
        errors,
      } as unknown as ApplyScope;
      await new DiscountRulesChangeHandler().apply(scope, items);
      await c.query('COMMIT');
    } catch (e) {
      await c.query('ROLLBACK');
      throw e;
    } finally {
      c.release();
    }
    return { counts: counts.get('discounts')!, errors };
  }
  const discountItems = (sc: SyntheticCashier) =>
    sc.allItems().filter((i) => i.type === 'Catalog_СкидкиНаценки') as Record<string, unknown>[];

  it('элементы плана обмена (поля-предложения): upsert по onec_ref, partnerRefs → customerIds; повтор без изменений — skipped', async () => {
    const items = discountItems(t.cashier);
    expect(items).toHaveLength(5);
    const first = await apply(items);
    expect(first.errors).toEqual([]);
    expect(first.counts).toMatchObject({ fetched: 5, updated: 5, inserted: 0 });
    const personal = await t.q<{
      conditions: Record<string, unknown>;
      kind: string;
      value: string;
      is_active: boolean;
    }>(
      `SELECT conditions, kind::text AS kind, value::text AS value, is_active FROM discount_rules WHERE onec_ref = $1`,
      [RULE_PERSONAL],
    );
    expect(personal[0]).toMatchObject({ kind: 'percent', value: '5.00', is_active: true });
    expect([...(personal[0].conditions.customerIds as string[])].sort()).toEqual(
      [w.customers.buyer.id, w.customers.debtWithinLimit.id].sort(),
    );
    const deleted = await t.q<{ deletion_mark: boolean; is_active: boolean }>(
      `SELECT deletion_mark, is_active FROM discount_rules WHERE onec_ref = 'd15c0000-0000-4000-8000-000000000005'`,
    );
    expect(deleted[0]).toEqual({ deletion_mark: true, is_active: false });
    const again = await apply(items);
    expect(again.counts).toMatchObject({ fetched: 5, skipped: 5, updated: 0 });
    // Применимость не изменилась: buyer — 2 правила.
    const r = await t.req('get', `/customers/${w.customers.buyer.id}/discounts`, w.actors.cashier);
    expect(r.body.rules).toHaveLength(2);
  });

  it('строгий контракт (без полей-предложений): kind=percent, value=0, is_active=NOT deletionMark; новое правило вставляется', async () => {
    const strict = new SyntheticCashier({ discountDetails: false });
    const items = discountItems(strict).map((i) => ({
      ...i,
      ref: randomUUID(),
      description: `Строгое: ${String(i.description)}`,
    }));
    const r = await apply(items);
    expect(r.counts).toMatchObject({ inserted: 5 });
    const rows = await t.q<{ kind: string; value: string; is_active: boolean; deletion_mark: boolean }>(
      `SELECT kind::text AS kind, value::text AS value, is_active, deletion_mark FROM discount_rules WHERE name LIKE 'Строгое:%'`,
    );
    expect(rows).toHaveLength(5);
    expect(rows.every((x) => x.kind === 'percent' && x.value === '0.00' && x.is_active === !x.deletion_mark)).toBe(
      true,
    );
  });

  it('ObjectDeletion → пометка удаления и is_active=false; ошибки позиций (kind, value > 100, ref, description) → sync_errors (VALIDATION)', async () => {
    const del = await apply([{ type: 'ObjectDeletion', objectType: 'Catalog_СкидкиНаценки', ref: RULE_WHOLESALE }]);
    expect(del.counts.markedDeleted).toBe(1);
    const row = await t.q<{ deletion_mark: boolean; is_active: boolean }>(
      `SELECT deletion_mark, is_active FROM discount_rules WHERE onec_ref = $1`,
      [RULE_WHOLESALE],
    );
    expect(row[0]).toEqual({ deletion_mark: true, is_active: false });
    const ids = ((await t.req('get', '/discounts/rules', w.actors.cashier)).body.rules as { id: string }[]).map(
      (x) => x.id,
    );
    expect(ids).not.toContain(w.discountRuleIds.get(RULE_WHOLESALE));
    expect(ids).toContain(w.discountRuleIds.get(RULE_PERSONAL));
    const bad = await apply([
      {
        type: 'Catalog_СкидкиНаценки',
        ref: randomUUID(),
        dataVersion: 'x',
        deletionMark: false,
        description: 'A',
        kind: 'bonus',
      },
      {
        type: 'Catalog_СкидкиНаценки',
        ref: randomUUID(),
        dataVersion: 'x',
        deletionMark: false,
        description: 'B',
        value: '100.01',
      },
      { type: 'Catalog_СкидкиНаценки', ref: 'not-uuid', dataVersion: 'x', deletionMark: false, description: 'C' },
      { type: 'Catalog_СкидкиНаценки', ref: randomUUID(), dataVersion: 'x', deletionMark: false, description: ' ' },
      {
        type: 'Catalog_СкидкиНаценки',
        ref: randomUUID(),
        dataVersion: 'x',
        deletionMark: false,
        description: 'D',
        value: 7,
      },
    ]);
    expect(bad.counts.errors).toBe(5);
    expect(bad.errors.every((e) => e.errorCode === 'VALIDATION' && e.entity === 'discounts')).toBe(true);
  });

  it('discountRuleFields: даты как date-time, fixed_amount сверх 100, условия minTotal/partnerRefs', () => {
    const f = discountRuleFields({
      kind: 'fixed_amount',
      value: '500.00',
      validFrom: '2026-01-01T00:00:00+06:00',
      validTo: 'bad',
      isActive: false,
      appliesAutomatically: true,
      conditions: { minTotal: '1000.00', partnerRefs: ['C3D4E5F6-0000-4000-8000-000000000001', 'x'] },
    });
    expect(f).toEqual({
      kind: 'fixed_amount',
      value: '500.00',
      isActive: false,
      appliesAutomatically: true,
      validFrom: '2026-01-01',
      validTo: null,
      minTotal: '1000.00',
      partnerRefs: ['c3d4e5f6-0000-4000-8000-000000000001'],
    });
  });
});

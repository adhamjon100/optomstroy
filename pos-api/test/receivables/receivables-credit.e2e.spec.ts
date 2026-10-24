import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { Money } from '../../src/common/money/money.js';
import { CustomerDiscountsModule } from '../../src/customers/discounts/discounts.module.js';
import { ReceivablesModule } from '../../src/customers/receivables/receivables.module.js';
import { ReceivablesSnapshotService } from '../../src/customers/receivables/receivables-snapshot.service.js';
import { CREDIT_DECISION_SERVICE } from '../../src/common/ports/index.js';
import { SnapshotCreditDecisionService } from '../../src/sales-domain/adapters/snapshot-credit-decision.service.js';
import { bishkekIso, CASHIER_SCENARIOS } from '../../src/integrations/onec/synthetic-cashier.js';
import { SyncRunError } from '../../src/jobs/sync/sync-handler.js';
import { ReceivablesSyncHandler } from '../../src/sync/receivables/receivables-sync.handler.js';
import { validateAgainst } from '../settings/support/openapi-check.js';
import { CashierTestApp, type CashierWorld } from '../support/cashier-fixture.js';
import { F_MODULES, type PosActor, RETAIL_CUSTOMER_ID, type SaleableVariant } from '../support/pos-fixture.js';

/**
 * Долги клиентов и продажа в долг на embedded PostgreSQL 17 — **тестовые данные** (фейк 1С в режиме кассира,
 * `cashier-fixture`): приложение с модулями этапа F (корзина, заказы, платежи, документы, уведомления) и модулями
 * G-be-credit (`ReceivablesModule` — снимок долга, `CreditDecisionService` по снимку; `CustomerDiscountsModule`).
 *
 * Трассировка 13 RM-G-002 (критерии 1–3), RM-G-011 (критерий 1), 12: T-PAY-033 (матрица порядка проверок долга),
 * T-DEBT-002…007, T-DEBT-009, T-DEBT-012, T-SEC (field-level, 403/404), 05 AC-SYNC-016, AC-SYNC-055, AC-SYNC-073.
 */
let t: CashierTestApp;
let w: CashierWorld;
let v: SaleableVariant;

const DETAIL = 'customer.receivables.read.detail';

beforeAll(async () => {
  t = await new CashierTestApp().start({
    env: { QR_PROVIDER: 'none', ONEC_SYNC_CHECK_TIMEOUT_MS: '1500' },
    modules: [...F_MODULES, ReceivablesModule, CustomerDiscountsModule],
  });
  w = await t.seedCashierWorld();
  // Снимки записаны только что: «старим» отметку записи, чтобы правило «не чаще 1 раза в 30 с» не мешало тестам.
  await t.q(`UPDATE receivables SET synced_at = now() - interval '1 hour'`);
  // /check 1С недоступен во всех тестах заказа: измерение «1С доступна/нет» матрицы — это запрос долга клиента.
  t.onec.always('checkCart', { transport: true });
  t.onec.always('createOrder', { transport: true });
  [v] = await t.saleableVariants(1);
}, 600_000);

afterAll(async () => {
  await t?.stop();
});

const receivableCalls = () => t.onec.callsOf('getCustomerReceivables').length;
const snapshotAt = async (customerId: string) => (await t.receivablesRow(customerId))?.onec_snapshot_at.getTime();

// ================================================================================================ GET receivables

describe('GET /customers/{id}/receivables — снимок долга из 1С (08 §4.11.5; DEBT-002, DEBT-004, DEBT-009)', () => {
  it('cashier: сальдо, просрочка, лимит, остаток лимита, срок, asOf; no-store, X-Data-As-Of; аудит customer.debt_viewed (summary)', async () => {
    const c = w.customers.debtWithinLimit;
    const r = await t.req('get', `/customers/${c.id}/receivables`, w.actors.cashier);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body).toMatchObject({
      customerId: c.id,
      balance: { amount: '12300.00', currency: 'KGS' },
      overdueAmount: { amount: '0.00', currency: 'KGS' },
      creditLimit: { amount: '100000.00', currency: 'KGS' },
      openOrdersAmount: { amount: '0.00', currency: 'KGS' },
      limitRemaining: { amount: '87700.00', currency: 'KGS' },
      creditAllowed: true,
      isStale: false,
      staleAfterMinutes: 60,
    });
    expect(r.body.documents).toBeUndefined();
    expect(r.body.refreshed).toBeUndefined();
    expect(validateAgainst('Receivable', r.body)).toEqual([]);
    expect(r.headers['cache-control']).toBe('no-store');
    expect(r.headers['x-data-as-of']).toBe(r.body.asOf);
    const audit = await t.auditRows('customer.debt_viewed', c.id);
    expect(audit.at(-1)).toMatchObject({ actor_user_id: w.actors.cashier.userId, result: 'ok' });
    expect(audit.at(-1)?.after).toMatchObject({ scope: 'summary', snapshotAt: r.body.asOf });
  });

  it('роли: seller → 403 (только флаги, Q-017); senior_seller, admin, owner → 200', async () => {
    const id = w.customers.overdue.id;
    expect((await t.req('get', `/customers/${id}/receivables`, w.actors.seller)).status).toBe(403);
    for (const a of [w.actors.senior_seller, w.actors.admin, w.actors.owner]) {
      const r = await t.req('get', `/customers/${id}/receivables`, a);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(r.body.overdueAmount).toEqual({ amount: '8000.00', currency: 'KGS' });
      expect(r.body.overdueDays).toBe(12);
    }
  });

  it('детализация: без step-up → 403 STEP_UP_REQUIRED (customer.receivables.read.detail); со step-up — documents[] kind/status + аудит customer.finance.view', async () => {
    const c = w.customers.buyer;
    const no = await t.req('get', `/customers/${c.id}/receivables?include=documents`, w.actors.cashier);
    expect(no.status).toBe(403);
    expect(no.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: DETAIL } });
    const foreign = await t.stepUp(w.actors.senior_seller, DETAIL);
    expect(
      (await t.req('get', `/customers/${c.id}/receivables?include=documents`, w.actors.cashier, { stepUp: foreign }))
        .status,
    ).toBe(403);
    const step = await t.stepUp(w.actors.cashier, DETAIL);
    const r = await t.req('get', `/customers/${c.id}/receivables?include=documents`, w.actors.cashier, {
      stepUp: step,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    // Контракт OpenAPI `Receivable` (documents[].kind/status — ядро §19.2; 13 RM-G-011 п. 4; ревью G-trace-15).
    expect(validateAgainst('Receivable', r.body)).toEqual([]);
    const docs = r.body.documents as { kind: string; status: string; amount: { amount: string } }[];
    expect([...new Set(docs.map((d) => d.kind))].sort()).toEqual(['adjustment', 'invoice', 'payment', 'return']);
    expect(docs.every((d) => ['posted', 'not_posted', 'due'].includes(d.status))).toBe(true);
    const remaining = docs.reduce(
      (s, d) => s.plus(Money.of((d as unknown as { remaining: { amount: string } }).remaining.amount)),
      Money.ZERO,
    );
    expect(remaining.toString()).toBe((r.body.balance as { amount: string }).amount);
    const fin = await t.auditRows('customer.finance.view', c.id);
    expect(fin.at(-1)).toMatchObject({ step_up_method: 'pin', actor_user_id: w.actors.cashier.userId });
    expect(fin.at(-1)?.after).toMatchObject({ documents: docs.length, snapshotAt: r.body.asOf });
    const viewed = await t.auditRows('customer.debt_viewed', c.id);
    expect(viewed.at(-1)?.after).toMatchObject({ scope: 'detail' });
    // Повторный просмотр в течение 15 мин тем же токеном — без нового step-up (токен многоразовый, 08 §2.12).
    expect(
      (await t.req('get', `/customers/${c.id}/receivables?include=documents`, w.actors.cashier, { stepUp: step }))
        .status,
    ).toBe(200);
  });

  it('устаревший снимок → isStale=true; неполный → overdueAmount=null; без снимка → «Нет данных из 1С» (balance=null, asOf=null)', async () => {
    const stale = await t.req('get', `/customers/${w.customers.stale.id}/receivables`, w.actors.cashier);
    expect(stale.body).toMatchObject({ isStale: true });
    expect(stale.body.balance).not.toBeNull();
    const inc = await t.req('get', `/customers/${w.customers.incomplete.id}/receivables`, w.actors.cashier);
    expect(inc.body.overdueAmount).toBeNull();
    const none = await t.req('get', `/customers/${w.customers.noSnapshot.id}/receivables`, w.actors.cashier);
    expect(none.status).toBe(200);
    expect(none.body).toMatchObject({ balance: null, overdueAmount: null, asOf: null, isStale: true });
    expect(none.body.reason).toBeUndefined();
    expect(none.headers['x-data-as-of']).toBeUndefined();
  });

  it('клиент source=pos до 1С и «Розничный покупатель» → 200 balance=null, reason=not_in_onec; суммы не передаются', async () => {
    for (const c of [w.customers.posPending, w.customers.retail]) {
      const r = await t.req('get', `/customers/${c.id}/receivables`, w.actors.cashier);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(r.body).toMatchObject({ customerId: c.id, balance: null, reason: 'not_in_onec', asOf: null });
      expect(r.body.creditLimit).toBeUndefined();
      expect(r.body.limitRemaining).toBeUndefined();
    }
  });

  it('режим клиента: свой (confirmed) → 200; proposed → 404; чужой → 404; детализация — тоже со step-up (AC-API-179)', async () => {
    const own = await t.req('get', `/customers/${w.customers.buyer.id}/receivables`, w.buyerConfirmed);
    expect(own.status, JSON.stringify(own.body)).toBe(200);
    expect(own.body.balance).not.toBeNull();
    expect((await t.req('get', `/customers/${w.customers.buyer.id}/receivables`, w.buyerProposed)).status).toBe(404);
    expect((await t.req('get', `/customers/${w.customers.overdue.id}/receivables`, w.buyerConfirmed)).status).toBe(404);
    const noStep = await t.req(
      'get',
      `/customers/${w.customers.buyer.id}/receivables?include=documents`,
      w.buyerConfirmed,
    );
    expect(noStep.body).toMatchObject({ code: 'STEP_UP_REQUIRED' });
    const step = await t.stepUp(w.buyerConfirmed, DETAIL);
    const det = await t.req(
      'get',
      `/customers/${w.customers.buyer.id}/receivables?include=documents`,
      w.buyerConfirmed,
      {
        stepUp: step,
      },
    );
    expect(det.status).toBe(200);
    expect(Array.isArray(det.body.documents)).toBe(true);
  });

  it('ошибки параметров: не UUID → 400; неизвестный клиент → 404; include=foo → 400; refresh=maybe → 400', async () => {
    const a = w.actors.cashier;
    expect((await t.req('get', '/customers/not-a-uuid/receivables', a)).status).toBe(400);
    expect((await t.req('get', `/customers/${randomUUID()}/receivables`, a)).status).toBe(404);
    const inc = await t.req('get', `/customers/${w.customers.overdue.id}/receivables?include=foo`, a);
    expect(inc.status).toBe(400);
    expect(inc.body.errors[0]).toMatchObject({ field: 'include', rule: 'enum' });
    expect((await t.req('get', `/customers/${w.customers.overdue.id}/receivables?refresh=maybe`, a)).status).toBe(400);
  });

  it('refresh=true (совместимость): устаревший снимок обновляется из 1С; при недоступной 1С — прежний снимок с isStale', async () => {
    const c = w.customers.stale;
    t.onec.always('getCustomerReceivables', { transport: true });
    const down = await t.req('get', `/customers/${c.id}/receivables?refresh=true`, w.actors.senior_seller);
    expect(down.status).toBe(200);
    expect(down.body.isStale).toBe(true);
    t.onec.always('getCustomerReceivables', null);
    // Последнее обращение к 1С по клиенту было < 30 с назад — повтор без нового обращения (RL-RECV-REFRESH).
    const before = receivableCalls();
    const again = await t.req('get', `/customers/${c.id}/receivables?refresh=true`, w.actors.admin);
    expect(again.body.isStale).toBe(true);
    expect(receivableCalls()).toBe(before);
  });
});

// ================================================================================================ POST refresh

describe('POST /customers/{id}/receivables/refresh — точечное обновление (08 §4.11.8; SYNC-073; RM-G-011 п. 1)', () => {
  it('cashier → снимок с новой меткой (refreshed=true, ровно один запрос в 1С); повтор < 30 с → refreshed=false без 1С', async () => {
    const c = w.customers.debtWithinLimit;
    const before = await snapshotAt(c.id);
    const calls = receivableCalls();
    const r = await t.req('post', `/customers/${c.id}/receivables/refresh`, w.actors.cashier);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body).toMatchObject({ refreshed: true, isStale: false, balance: { amount: '12300.00' } });
    expect(receivableCalls()).toBe(calls + 1);
    expect(t.onec.callsOf('getCustomerReceivables').at(-1)?.[0]).toBe(c.onecRef);
    expect(await snapshotAt(c.id)).toBeGreaterThan(before);
    expect(new Date(r.body.asOf as string).getTime()).toBe(await snapshotAt(c.id));
    const again = await t.req('post', `/customers/${c.id}/receivables/refresh`, w.actors.cashier);
    expect(again.body).toMatchObject({ refreshed: false });
    expect(receivableCalls()).toBe(calls + 1);
    const audit = await t.auditRows('customer.debt_viewed', c.id);
    expect(audit.at(-1)?.after).toMatchObject({ scope: 'summary', onecSync: true });
  });

  it('seller и customer → 403; POS-клиент до 1С → 422 CUSTOMER_NOT_IDENTIFIED; неизвестный → 404', async () => {
    const id = w.customers.overdue.id;
    expect((await t.req('post', `/customers/${id}/receivables/refresh`, w.actors.seller)).status).toBe(403);
    expect((await t.req('post', `/customers/${id}/receivables/refresh`, w.buyerConfirmed)).status).toBe(403);
    const pos = await t.req('post', `/customers/${w.customers.posPending.id}/receivables/refresh`, w.actors.owner);
    expect(pos.status).toBe(422);
    expect(pos.body).toMatchObject({ code: 'CUSTOMER_NOT_IDENTIFIED', reason: 'not_in_onec' });
    expect((await t.req('post', `/customers/${randomUUID()}/receivables/refresh`, w.actors.owner)).status).toBe(404);
  });

  it('1С недоступна → 503 ONEC_UNAVAILABLE, onec_snapshot_at не изменён; повтор < 30 с — 503 без обращения к 1С', async () => {
    const c = w.customers.overdue;
    const before = await snapshotAt(c.id);
    t.onec.always('getCustomerReceivables', { transport: true });
    const r = await t.req('post', `/customers/${c.id}/receivables/refresh`, w.actors.senior_seller);
    expect(r.status).toBe(503);
    expect(r.body).toMatchObject({ code: 'ONEC_UNAVAILABLE' });
    expect(await snapshotAt(c.id)).toBe(before);
    const calls = receivableCalls();
    const again = await t.req('post', `/customers/${c.id}/receivables/refresh`, w.actors.senior_seller);
    expect(again.status).toBe(503);
    expect(Number(again.headers['retry-after'])).toBeGreaterThan(0);
    expect(receivableCalls()).toBe(calls);
    t.onec.always('getCustomerReceivables', null);
  });

  it('таймаут 1С (ONEC_SYNC_CHECK_TIMEOUT_MS) → 503 за время таймаута; снимок прежний', async () => {
    const c = w.customers.noLimit;
    const before = await snapshotAt(c.id);
    t.onec.script('getCustomerReceivables', { hang: true });
    const started = Date.now();
    const r = await t.req('post', `/customers/${c.id}/receivables/refresh`, w.actors.admin);
    expect(r.status).toBe(503);
    expect(Date.now() - started).toBeLessThan(6000);
    expect(await snapshotAt(c.id)).toBe(before);
  });

  it('single-flight: два параллельных запроса по клиенту — одно обращение к 1С, оба получают обновлённый снимок', async () => {
    const c = w.customers.advance;
    const calls = receivableCalls();
    t.onec.script('getCustomerReceivables', { delayMs: 300 });
    const [a, b] = await Promise.all([
      t.req('post', `/customers/${c.id}/receivables/refresh`, w.actors.cashier),
      t.req('post', `/customers/${c.id}/receivables/refresh`, w.actors.senior_seller),
    ]);
    expect([a.status, b.status]).toEqual([200, 200]);
    expect(a.body).toMatchObject({ refreshed: true, balance: { amount: '-2500.00' } });
    expect(b.body.asOf).toBe(a.body.asOf);
    expect(receivableCalls()).toBe(calls + 1);
  });

  it('include=documents: без step-up → 403; со step-up — детализация заменяется целиком (superseded_at), условия соглашения из 1С', async () => {
    const c = w.customers.overLimit;
    const no = await t.req('post', `/customers/${c.id}/receivables/refresh?include=documents`, w.actors.cashier);
    expect(no.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: DETAIL } });
    const docRef = randomUUID();
    t.cashier.setReceivables(c.onecRef!, {
      balance: '500.00',
      overdueAmount: '0.00',
      overdueDays: 0,
      documents: [
        {
          documentRef: docRef,
          documentType: 'Document_РеализацияТоваровУслуг',
          number: 'РТ00-777777',
          date: '2026-10-20',
          amount: '500.00',
          paid: '0.00',
          remaining: '500.00',
          dueDate: '2099-01-01',
          overdueDays: 0,
        },
      ],
    });
    t.cashier.updatePartner(c.onecRef!, { creditLimit: '60000.00', creditDays: 21 });
    const step = await t.stepUp(w.actors.cashier, DETAIL);
    const r = await t.req('post', `/customers/${c.id}/receivables/refresh?include=documents`, w.actors.cashier, {
      stepUp: step,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body).toMatchObject({
      refreshed: true,
      balance: { amount: '500.00' },
      creditLimit: { amount: '60000.00' },
      paymentTermDays: 21,
      limitRemaining: { amount: '59500.00' },
      documents: [{ onecRef: docRef, kind: 'invoice', status: 'posted', number: 'РТ00-777777' }],
    });
    const rows = await t.q<{ onec_ref: string; superseded: boolean }>(
      `SELECT onec_ref, superseded_at IS NOT NULL AS superseded FROM receivable_documents WHERE customer_id = $1`,
      [c.id],
    );
    expect(rows.filter((x) => !x.superseded).map((x) => x.onec_ref)).toEqual([docRef]);
    expect(rows.some((x) => x.superseded)).toBe(true);
    const cust = await t.q<{ credit_limit: string; credit_days: number }>(
      `SELECT credit_limit::text AS credit_limit, credit_days FROM customers WHERE id = $1`,
      [c.id],
    );
    expect(cust[0]).toEqual({ credit_limit: '60000.00', credit_days: 21 });
    expect((await t.auditRows('customer.finance.view', c.id)).at(-1)?.after).toMatchObject({ documents: 1 });
  });

  it('RL-RECV-REFRESH: 10 запросов в минуту на пользователя, 11-й → 429 RATE_LIMITED c Retry-After', async () => {
    // Окно лимита — календарная минута: не начинать у её границы.
    const msLeft = 60_000 - (Date.now() % 60_000);
    if (msLeft < 15_000) await new Promise((r) => setTimeout(r, msLeft + 200));
    const a = await t.actor({ role: 'cashier' });
    const id = w.customers.creditNotAllowed.id;
    for (let i = 0; i < 10; i++) {
      const r = await t.req('post', `/customers/${id}/receivables/refresh`, a);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
    }
    const over = await t.req('post', `/customers/${id}/receivables/refresh`, a);
    expect(over.status).toBe(429);
    expect(over.body).toMatchObject({ code: 'RATE_LIMITED' });
    expect(Number(over.headers['retry-after'])).toBeGreaterThan(0);
    // Лимит — на пользователя: другой кассир не затронут.
    expect((await t.req('post', `/customers/${id}/receivables/refresh`, w.actors.owner)).status).toBe(200);
  });
});

// ================================================================================================ overdue

describe('GET /receivables/overdue — просроченные долги (08 §4.12.1; DEBT-007)', () => {
  it('cashier: только просрочка > 0, по убыванию суммы; базовые поля клиента без сумм receivable; аудит receivables.overdue_viewed', async () => {
    const r = await t.req('get', '/receivables/overdue', w.actors.cashier);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const items = r.body.items as { customer: Record<string, unknown>; overdueAmount: { amount: string } }[];
    expect(items.length).toBeGreaterThan(0);
    expect(items.every((i) => Money.of(i.overdueAmount.amount).compare(Money.ZERO) > 0)).toBe(true);
    const sorted = [...items].sort((a, b) =>
      Money.of(b.overdueAmount.amount).compare(Money.of(a.overdueAmount.amount)),
    );
    expect(items.map((i) => i.overdueAmount.amount)).toEqual(sorted.map((i) => i.overdueAmount.amount));
    expect(items.map((i) => i.customer.id)).toContain(w.customers.overdue.id);
    expect(items[0]?.customer.receivable).toBeUndefined();
    expect(items[0]?.customer).toMatchObject({ hasDebt: true, isOverdue: true });
    expect(r.body).toMatchObject({ hasMore: false, nextCursor: null });
    expect(typeof r.body.asOf).toBe('string');
    expect(typeof r.body.isStale).toBe('boolean');
    expect(r.headers['cache-control']).toBe('no-store');
    const audit = await t.auditRows('receivables.overdue_viewed');
    expect(audit.at(-1)?.after).toMatchObject({ rows: items.length });
  });

  it('seller и customer → 403', async () => {
    expect((await t.req('get', '/receivables/overdue', w.actors.seller)).status).toBe(403);
    expect((await t.req('get', '/receivables/overdue', w.buyerConfirmed)).status).toBe(403);
  });

  it('фильтры minOverdueDays/minAmount, сортировка customerName:asc, курсор; ошибки параметров → 400', async () => {
    const a = w.actors.owner;
    const big = await t.req('get', '/receivables/overdue?minAmount=7999.99&minOverdueDays=12', a);
    expect(big.status).toBe(200);
    for (const i of big.body.items as { overdueAmount: { amount: string }; overdueDays: number }[]) {
      expect(Money.of(i.overdueAmount.amount).compare(Money.of('7999.99'))).toBeGreaterThanOrEqual(0);
      expect(i.overdueDays).toBeGreaterThanOrEqual(12);
    }
    const all = await t.req('get', '/receivables/overdue?sort=customerName:asc&limit=200', a);
    const names = (all.body.items as { customer: { name: string } }[]).map((i) => i.customer.name);
    const p1 = await t.req('get', '/receivables/overdue?sort=customerName:asc&limit=1', a);
    expect(p1.body.hasMore).toBe(names.length > 1);
    if (names.length > 1) {
      const p2 = await t.req(
        'get',
        `/receivables/overdue?sort=customerName:asc&limit=1&cursor=${p1.body.nextCursor}`,
        a,
      );
      expect((p2.body.items as { customer: { name: string } }[])[0]?.customer.name).toBe(names[1]);
      const mismatch = await t.req('get', `/receivables/overdue?sort=overdueDays:desc&cursor=${p1.body.nextCursor}`, a);
      expect(mismatch.status).toBe(400);
      expect(mismatch.body.errors[0]).toMatchObject({ field: 'cursor', rule: 'cursor_sort_mismatch' });
      const forged = await t.req(
        'get',
        `/receivables/overdue?cursor=${String(p1.body.nextCursor).replace(/.$/, '0')}x`,
        a,
      );
      expect(forged.status).toBe(400);
    }
    for (const bad of [
      'sort=balance:desc',
      'limit=201',
      'limit=0',
      'minAmount=10',
      'minOverdueDays=-1',
      'cursor=abc',
    ]) {
      const r = await t.req('get', `/receivables/overdue?${bad}`, a);
      expect(r.status, bad).toBe(400);
      expect(r.body.code).toBe('VALIDATION_FAILED');
    }
  });
});

// ================================================================================================ credit (POST /orders)

interface Truth {
  readonly balance: string;
  readonly overdue: string;
  readonly limit: string;
}

/** Ответ 1С `CustomerReceivables` (контракт 1С, тестовые данные) для клиента с данной «истиной». */
function onecReceivables(ref: string, s: Truth): Record<string, unknown> {
  const overdue = Money.of(s.overdue);
  return {
    customerRef: ref,
    snapshotAt: bishkekIso(new Date()),
    balance: s.balance,
    overdueAmount: s.overdue,
    overdueDays: overdue.isZero() ? 0 : 7,
    creditAllowed: true,
    creditLimit: s.limit,
    creditDays: 14,
    creditAvailable: Money.of(s.limit).minus(Money.of(s.balance)).toString(),
    documents: [
      {
        documentRef: randomUUID(),
        documentType: 'Document_РеализацияТоваровУслуг',
        number: 'РТ00-000001',
        date: bishkekIso(new Date(Date.now() - 20 * 86_400_000)),
        amount: s.balance,
        paid: '0.00',
        remaining: s.balance,
        dueDate: bishkekIso(new Date(Date.now() - (overdue.isZero() ? -5 : 7) * 86_400_000)),
        overdueDays: overdue.isZero() ? 0 : 7,
      },
    ],
  };
}

type Cart = { id: string; rowVersion: number; total: { amount: string } };

async function cartFor(a: PosActor, customerId: string | null, qty = '1'): Promise<Cart> {
  const c0 = (await t.req('get', '/cart', a)).body as Cart;
  const put = await t.req('put', `/cart/items/${v.variantId}`, a).send({
    quantity: { value: qty, unitId: v.unitId, packagingId: null },
    rowVersion: c0.rowVersion,
  });
  expect(put.status, JSON.stringify(put.body)).toBe(200);
  if (customerId !== null) {
    const cur = (await t.req('get', '/cart', a)).body as Cart;
    const set = await t.req('post', '/cart/customer', a).send({ customerId, rowVersion: cur.rowVersion });
    expect(set.status, JSON.stringify(set.body)).toBe(200);
  }
  return (await t.req('get', '/cart', a)).body as Cart;
}

function order(a: PosActor, cart: Cart, qty = '1', extra: Record<string, unknown> = {}, stepUp?: string) {
  return t.req('post', '/orders', a, { idem: true, ...(stepUp ? { stepUp } : {}) }).send({
    cartId: cart.id,
    cartRowVersion: cart.rowVersion,
    receiver: { kind: 'customer' },
    delivery: { method: 'pickup' },
    paymentMethod: 'credit',
    items: [{ variantId: v.variantId, quantity: { value: qty, unitId: v.unitId, packagingId: null } }],
    ...extra,
  });
}

type SnapState = 'fresh' | 'stale' | 'incomplete' | 'none';

/** Оракул 10 PAY-031 (см. credit-decision.unit.spec): код отказа или `ALLOWED`, нужно ли обращение к 1С. */
function oracle(c: { state: SnapState; over: boolean; overdue: boolean; onecUp: boolean }) {
  const known = c.state !== 'none';
  const overdueKnown = c.state === 'fresh' || c.state === 'stale';
  if (known && overdueKnown && c.overdue) return { code: 'CREDIT_BLOCKED', reason: 'overdue', refresh: false };
  if (known && c.over) return { code: 'CREDIT_LIMIT_EXCEEDED', reason: 'limit_exceeded', refresh: false };
  if (c.state === 'fresh') return { code: 'ALLOWED', reason: null, refresh: false };
  if (!c.onecUp) return { code: 'RECEIVABLES_STALE', reason: 'stale_snapshot', refresh: true };
  if (c.overdue) return { code: 'CREDIT_BLOCKED', reason: 'overdue', refresh: true };
  if (c.over) return { code: 'CREDIT_LIMIT_EXCEEDED', reason: 'limit_exceeded', refresh: true };
  return { code: 'ALLOWED', reason: null, refresh: true };
}

/** Клиент 1С с отсрочкой, лимит которого относительно заказа `total` — в лимите или сверх (на 0,01). */
async function creditCustomer(total: string, s: { over: boolean; overdue: boolean; state: SnapState }) {
  const balance = '1000.00';
  const limit = s.over
    ? Money.of(balance).plus(Money.of(total)).minus(Money.of('0.01')).toString()
    : Money.of(balance).plus(Money.of(total)).plus(Money.of('100.00')).toString();
  const truth: Truth = { balance, overdue: s.overdue ? '500.00' : '0.00', limit };
  const id = await t.createOnecCustomer({ creditAllowed: true, creditLimit: limit, creditDays: 14 });
  const ref = (await t.q<{ onec_ref: string }>(`SELECT onec_ref FROM customers WHERE id = $1`, [id]))[0].onec_ref;
  if (s.state === 'fresh') await t.setReceivables(id, { balance, overdue: truth.overdue, ageMinutes: 5 });
  if (s.state === 'stale') await t.setReceivables(id, { balance, overdue: truth.overdue, ageMinutes: 180 });
  if (s.state === 'incomplete') await t.setReceivables(id, { balance, overdue: null, ageMinutes: 5 });
  return { id, ref, truth };
}

describe('продажа в долг: матрица fail-closed через POST /orders (RM-G-002 п. 1; T-PAY-033; AC-SYNC-055)', () => {
  const states: SnapState[] = ['fresh', 'stale', 'incomplete', 'none'];
  const cases = states.flatMap((state) =>
    [false, true].flatMap((over) =>
      [false, true].flatMap((overdue) => [true, false].map((onecUp) => ({ state, over, overdue, onecUp }))),
    ),
  );

  it.each(cases)('снимок $state, сверх лимита=$over, просрочка=$overdue, 1С доступна=$onecUp', async (c) => {
    const a = await t.actor({ role: 'cashier' });
    // Итог заказа — цена варианта × 1 (клиент без скидки и без своего вида цены).
    const cust = await creditCustomer(v.price, c);
    const cart = await cartFor(a, cust.id);
    expect(cart.total.amount).toBe(v.price);
    t.onec.always(
      'getCustomerReceivables',
      c.onecUp ? { respond: { body: onecReceivables(cust.ref, cust.truth) as never } } : { transport: true },
    );
    const calls = receivableCalls();
    let r: Awaited<ReturnType<typeof order>>;
    try {
      r = await order(a, cart);
    } finally {
      t.onec.always('getCustomerReceivables', null);
    }
    const exp = oracle(c);
    if (exp.code === 'ALLOWED') {
      expect([201, 202], JSON.stringify(r.body)).toContain(r.status);
      expect(r.body.paymentMethod ?? 'credit').toBe('credit');
    } else {
      expect(r.status, JSON.stringify(r.body)).toBe(422);
      expect(r.body).toMatchObject({ code: exp.code, creditReason: exp.reason });
      const blocked = await t.q<{ after: Record<string, unknown> }>(
        `SELECT after FROM audit_logs WHERE action = 'credit.sale_blocked' AND actor_user_id = $1 ORDER BY chain_seq DESC LIMIT 1`,
        [a.userId],
      );
      expect(blocked[0]?.after).toMatchObject({ refusalCode: exp.code, creditReason: exp.reason });
    }
    expect(r.status).not.toBe(503);
    expect(r.body.code).not.toBe('ONEC_UNAVAILABLE');
    expect(receivableCalls() - calls, 'обращений к 1С за долгом').toBe(exp.refresh ? 1 : 0);
    if (exp.refresh && c.onecUp) {
      // Снимок обновлён: onec_snapshot_at — момент ответа 1С (не старше минуты).
      const row = await t.receivablesRow(cust.id);
      expect(Date.now() - row.onec_snapshot_at.getTime()).toBeLessThan(60_000);
      expect(row.overdue_amount).toBe(cust.truth.overdue);
    }
  });
});

describe('продажа в долг: шаг 1, разблокировка, открытые заказы (PAY-031 шаг 1, PAY-032, DEBT-010, DEBT-011)', () => {
  it('без клиента и с «Розничным покупателем» → 422 CUSTOMER_NOT_IDENTIFIED; credit_allowed=false → CREDIT_BLOCKED credit_not_allowed без 1С; admin → 403 forbidden_role', async () => {
    const a = await t.actor({ role: 'cashier' });
    const calls = receivableCalls();
    const none = await order(a, await cartFor(a, null));
    expect(none.status).toBe(422);
    expect(none.body).toMatchObject({ code: 'CUSTOMER_NOT_IDENTIFIED' });
    const b = await t.actor({ role: 'cashier' });
    const retail = await order(b, await cartFor(b, RETAIL_CUSTOMER_ID));
    expect(retail.body).toMatchObject({ code: 'CUSTOMER_NOT_IDENTIFIED' });
    // Соглашение без отсрочки: снимок устаревший и неполный, 1С недоступна — отказ шага 1 без обращения к 1С.
    const c = await t.actor({ role: 'cashier' });
    await t.setReceivables(w.customers.creditNotAllowed.id, { balance: '0.00', overdue: null, ageMinutes: 500 });
    t.onec.always('getCustomerReceivables', { transport: true });
    const na = await order(c, await cartFor(c, w.customers.creditNotAllowed.id));
    t.onec.always('getCustomerReceivables', null);
    expect(na.status).toBe(422);
    expect(na.body).toMatchObject({ code: 'CREDIT_BLOCKED', creditReason: 'credit_not_allowed' });
    expect(receivableCalls()).toBe(calls);
    const adm = w.actors.admin;
    const forb = await order(adm, await cartFor(adm, w.customers.debtWithinLimit.id));
    expect(forb.status).toBe(403);
    expect(forb.body).toMatchObject({ code: 'FORBIDDEN', creditReason: 'forbidden_role' });
  });

  it('разблокировка просрочки senior_seller: без step-up → 403 STEP_UP_REQUIRED; со step-up → заказ, transactions(credit_sale_approved) и аудит credit.sale_approved', async () => {
    const s = await t.actor({ role: 'senior_seller' });
    const cust = await creditCustomer(v.price, { over: false, overdue: true, state: 'fresh' });
    const cart = await cartFor(s, cust.id);
    const noStep = await order(s, cart, '1', { creditOverride: { reason: 'клиент оплатит завтра' } });
    expect(noStep.status).toBe(403);
    expect(noStep.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: 'credit.sale.approve' } });
    const step = await t.stepUp(s, 'credit.sale.approve');
    const ok = await order(s, cart, '1', { creditOverride: { reason: 'клиент оплатит завтра' } }, step);
    expect([201, 202], JSON.stringify(ok.body)).toContain(ok.status);
    const orderId = ok.body.id as string;
    const tx = await t.q<{ kind: string }>(`SELECT kind::text AS kind FROM transactions WHERE order_id = $1`, [
      orderId,
    ]);
    expect(tx.map((x) => x.kind)).toContain('credit_sale_approved');
    const audit = await t.auditRows('credit.sale_approved', orderId);
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({ actor_user_id: s.userId, step_up_method: 'pin' });
  });

  it('admin с creditOverride → 403; разблокировка не снимает RECEIVABLES_STALE (устаревший снимок, 1С недоступна)', async () => {
    const adm = await t.actor({ role: 'admin' });
    const cart = await cartFor(adm, w.customers.overdue.id);
    const r = await order(
      adm,
      cart,
      '1',
      { creditOverride: { reason: 'админ разрешил' } },
      await t.stepUp(adm, 'credit.sale.approve'),
    );
    expect(r.status).toBe(403);
    const s = await t.actor({ role: 'senior_seller' });
    const cust = await creditCustomer(v.price, { over: false, overdue: true, state: 'stale' });
    const cart2 = await cartFor(s, cust.id);
    t.onec.always('getCustomerReceivables', { transport: true });
    const stale = await order(
      s,
      cart2,
      '1',
      { creditOverride: { reason: 'клиент оплатит завтра' } },
      await t.stepUp(s, 'credit.sale.approve'),
    );
    t.onec.always('getCustomerReceivables', null);
    expect(stale.status).toBe(422);
    expect(stale.body).toMatchObject({ code: 'RECEIVABLES_STALE', creditReason: 'stale_snapshot' });
  });

  it('открытые заказы в долг (в т. ч. ещё не доставленные в 1С) уменьшают остаток лимита: второй заказ → CREDIT_LIMIT_EXCEEDED (T-DEBT-009)', async () => {
    const a = await t.actor({ role: 'cashier' });
    const total = Money.of(v.price);
    // Лимит = сальдо 1000 + 1,5 заказа: первый проходит, второй — уже нет (остаток 0,5 заказа).
    const limit = Money.of('1000.00')
      .plus(total)
      .plus(Money.of(total.percent('50').toString()))
      .toString();
    const id = await t.createOnecCustomer({ creditAllowed: true, creditLimit: limit, creditDays: 14 });
    await t.setReceivables(id, { balance: '1000.00', overdue: '0.00', ageMinutes: 1 });
    const first = await order(a, await cartFor(a, id));
    expect([201, 202], JSON.stringify(first.body)).toContain(first.status);
    const b = await t.actor({ role: 'cashier' });
    const second = await order(b, await cartFor(b, id));
    expect(second.status, JSON.stringify(second.body)).toBe(422);
    expect(second.body).toMatchObject({ code: 'CREDIT_LIMIT_EXCEEDED', creditReason: 'limit_exceeded' });
    const view = await t.req('get', `/customers/${id}/receivables`, w.actors.cashier);
    expect(view.body.openOrdersAmount).toEqual(total.toJSON());
  });

  it('checkout-preview (мягкий режим): просрочка → paymentChecks.creditAllowed=false, creditReason=overdue, без 503', async () => {
    const a = await t.actor({ role: 'cashier' });
    const cart = await cartFor(a, w.customers.overdue.id);
    const r = await t.req('post', '/cart/checkout-preview', a).send({
      cartId: cart.id,
      cartRowVersion: cart.rowVersion,
      paymentMethod: 'credit',
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.paymentChecks).toMatchObject({
      creditAllowed: false,
      creditReason: 'overdue',
      receivablesStale: false,
    });
  });
});

// ================================================================================================ ревью G (исправления)

describe('продажа в долг: исправления ревью G (G-credit-1…7)', () => {
  const step = (a: PosActor) => t.stepUp(a, 'credit.sale.approve');
  const lastBlocked = async (userId: string) =>
    (
      await t.q<{ after: Record<string, unknown> }>(
        `SELECT after FROM audit_logs WHERE action = 'credit.sale_blocked' AND actor_user_id = $1 ORDER BY chain_seq DESC LIMIT 1`,
        [userId],
      )
    )[0]?.after;

  it('G-credit-1: 1С при обновлении снимка запретила отсрочку / снизила лимит → отказ по новым условиям (не по старой карточке)', async () => {
    const a = await t.actor({ role: 'cashier' });
    const cust = await creditCustomer(v.price, { over: false, overdue: false, state: 'stale' });
    t.onec.always('getCustomerReceivables', {
      respond: { body: { ...onecReceivables(cust.ref, cust.truth), creditAllowed: false } },
    });
    let r: Awaited<ReturnType<typeof order>>;
    try {
      r = await order(a, await cartFor(a, cust.id));
    } finally {
      t.onec.always('getCustomerReceivables', null);
    }
    expect(r.status, JSON.stringify(r.body)).toBe(422);
    expect(r.body).toMatchObject({ code: 'CREDIT_BLOCKED', creditReason: 'credit_not_allowed' });
    expect((await t.q<{ c: boolean }>(`SELECT credit_allowed AS c FROM customers WHERE id = $1`, [cust.id]))[0].c).toBe(
      false,
    );

    const b = await t.actor({ role: 'cashier' });
    const cust2 = await creditCustomer(v.price, { over: false, overdue: false, state: 'stale' });
    t.onec.always('getCustomerReceivables', {
      respond: { body: { ...onecReceivables(cust2.ref, cust2.truth), creditLimit: '1000.00' } },
    });
    try {
      r = await order(b, await cartFor(b, cust2.id));
    } finally {
      t.onec.always('getCustomerReceivables', null);
    }
    expect(r.status, JSON.stringify(r.body)).toBe(422);
    expect(r.body).toMatchObject({ code: 'CREDIT_LIMIT_EXCEEDED', creditReason: 'limit_exceeded' });
    expect(await lastBlocked(b.userId)).toMatchObject({ refusalCode: 'CREDIT_LIMIT_EXCEEDED' });
  });

  it('G-credit-2: снимок «из будущего» непригоден и перезаписывается; ответ 1С с меткой из будущего → RECEIVABLES_STALE', async () => {
    const a = await t.actor({ role: 'cashier' });
    const cust = await creditCustomer(v.price, { over: false, overdue: false, state: 'fresh' });
    await t.setReceivables(cust.id, { balance: '1000.00', overdue: '0.00', ageMinutes: -24 * 60 });
    const view = await t.req('get', `/customers/${cust.id}/receivables`, w.actors.cashier);
    expect(view.body).toMatchObject({ isStale: true });
    t.onec.always('getCustomerReceivables', { respond: { body: onecReceivables(cust.ref, cust.truth) as never } });
    const calls = receivableCalls();
    let ok: Awaited<ReturnType<typeof order>>;
    try {
      ok = await order(a, await cartFor(a, cust.id));
    } finally {
      t.onec.always('getCustomerReceivables', null);
    }
    expect([201, 202], JSON.stringify(ok.body)).toContain(ok.status);
    expect(receivableCalls() - calls).toBe(1);
    expect(Math.abs(Date.now() - (await snapshotAt(cust.id)))).toBeLessThan(60_000);

    const b = await t.actor({ role: 'cashier' });
    const cust2 = await creditCustomer(v.price, { over: false, overdue: false, state: 'stale' });
    const before = await snapshotAt(cust2.id);
    const future = {
      ...onecReceivables(cust2.ref, cust2.truth),
      snapshotAt: bishkekIso(new Date(Date.now() + 86_400_000)),
    };
    t.onec.always('getCustomerReceivables', { respond: { body: future } });
    let stale: Awaited<ReturnType<typeof order>>;
    try {
      stale = await order(b, await cartFor(b, cust2.id));
    } finally {
      t.onec.always('getCustomerReceivables', null);
    }
    expect(stale.status, JSON.stringify(stale.body)).toBe(422);
    expect(stale.body).toMatchObject({ code: 'RECEIVABLES_STALE', creditReason: 'stale_snapshot' });
    expect(await snapshotAt(cust2.id)).toBe(before);
  });

  it('G-credit-3: два параллельных POST /orders в долг одного клиента — лимит проверяется в транзакции заказа: один 201/202, второй 422', async () => {
    const real = t.app.get(SnapshotCreditDecisionService);
    const total = Money.of(v.price);
    // Лимит = сальдо + 1,5 заказа: каждый заказ по отдельности проходит, оба вместе — нет.
    const limit = Money.of('1000.00')
      .plus(total)
      .plus(Money.of(total.percent('50').toString()))
      .toString();
    const id = await t.createOnecCustomer({ creditAllowed: true, creditLimit: limit, creditDays: 14 });
    await t.setReceivables(id, { balance: '1000.00', overdue: '0.00', ageMinutes: 1 });
    const a = await t.actor({ role: 'cashier' });
    const b = await t.actor({ role: 'cashier' });
    const ca = await cartFor(a, id);
    const cb = await cartFor(b, id);
    // Барьер: проверки корзины обоих запросов выполняются до создания любого из заказов (окно гонки).
    let arrived = 0;
    let release: () => void = () => undefined;
    const gate = new Promise<void>((r) => (release = r));
    const inTx: boolean[] = [];
    t.registry.replace(CREDIT_DECISION_SERVICE, {
      check: async (tx, input) => {
        inTx.push(input.allowRefresh === false);
        if (input.allowRefresh !== false) {
          arrived += 1;
          if (arrived >= 2) release();
          await gate;
        }
        return real.check(tx, input);
      },
    });
    let rs: Awaited<ReturnType<typeof order>>[];
    try {
      rs = await Promise.all([order(a, ca), order(b, cb)]);
    } finally {
      t.registry.replace(CREDIT_DECISION_SERVICE, real);
    }
    const created = rs.filter((r) => r.status === 201 || r.status === 202);
    expect(created, JSON.stringify(rs.map((r) => r.body as unknown))).toHaveLength(1);
    const refused = rs.find((r) => r.status === 422)!;
    expect(refused.body).toMatchObject({ code: 'CREDIT_LIMIT_EXCEEDED', creditReason: 'limit_exceeded' });
    expect(inTx.filter(Boolean)).toHaveLength(2);
    const n = await t.q<{ n: number }>(
      `SELECT count(*)::int AS n FROM orders WHERE customer_id = $1 AND payment_method = 'credit'`,
      [id],
    );
    expect(n[0].n).toBe(1);
    const loser = refused === rs[0] ? a : b;
    expect(await lastBlocked(loser.userId)).toMatchObject({ refusalCode: 'CREDIT_LIMIT_EXCEEDED' });
  });

  it('G-credit-4: (13) новый клиент без onec_ref; (14)/(15)/(16) credit_allowed=false и credit_limit IS NULL с creditOverride; strict preview = POST /orders', async () => {
    const calls = receivableCalls();
    const c = await t.actor({ role: 'cashier' });
    const nw = await order(c, await cartFor(c, w.customers.posPending.id));
    expect([nw.status, nw.body.code, nw.body.creditReason]).toEqual([422, 'CUSTOMER_NOT_IDENTIFIED', undefined]);
    expect(receivableCalls()).toBe(calls);

    // (14) + (16): creditOverride шаг 1 не снимает — по-прежнему credit_not_allowed, 1С не вызывается.
    const s = await t.actor({ role: 'senior_seller' });
    const na = await t.createOnecCustomer({ creditAllowed: false, creditLimit: '100000.00', creditDays: 14 });
    await t.setReceivables(na, { balance: '0.00', overdue: null, ageMinutes: 500 });
    t.onec.always('getCustomerReceivables', { transport: true });
    let r14: Awaited<ReturnType<typeof order>>;
    try {
      r14 = await order(
        s,
        await cartFor(s, na),
        '1',
        { creditOverride: { reason: 'старший разрешил' } },
        await step(s),
      );
    } finally {
      t.onec.always('getCustomerReceivables', null);
    }
    expect([r14.status, r14.body.code, r14.body.creditReason]).toEqual([422, 'CREDIT_BLOCKED', 'credit_not_allowed']);
    expect(receivableCalls()).toBe(calls);
    // (15) лимит не задан → CREDIT_LIMIT_EXCEEDED «Лимит в 1С не задан»; (16) с creditOverride → заказ и аудит.
    const nl = await t.createOnecCustomer({ creditAllowed: true, creditDays: 14 });
    await t.setReceivables(nl, { balance: '0.00', overdue: '0.00', ageMinutes: 1 });
    const c15 = await t.actor({ role: 'cashier' });
    const r15 = await order(c15, await cartFor(c15, nl));
    expect([r15.status, r15.body.code]).toEqual([422, 'CREDIT_LIMIT_EXCEEDED']);
    expect(String(r15.body.detail)).toContain('Лимит в 1С не задан');
    const s2 = await t.actor({ role: 'senior_seller' });
    const r16 = await order(
      s2,
      await cartFor(s2, nl),
      '1',
      { creditOverride: { reason: 'старший разрешил' } },
      await step(s2),
    );
    expect([201, 202], JSON.stringify(r16.body)).toContain(r16.status);
    expect(await t.auditRows('credit.sale_approved', r16.body.id as string)).toHaveLength(1);

    // Код checkout-preview (strict=true) совпадает с кодом POST /orders (T-PAY-033).
    const cases: [string, string][] = [
      [w.customers.overdue.id, 'CREDIT_BLOCKED'],
      [w.customers.creditNotAllowed.id, 'CREDIT_BLOCKED'],
      [w.customers.posPending.id, 'CUSTOMER_NOT_IDENTIFIED'],
      [nl, 'CREDIT_LIMIT_EXCEEDED'],
    ];
    for (const [cid, code] of cases) {
      const a = await t.actor({ role: 'cashier' });
      const cart = await cartFor(a, cid);
      const pv = await t.req('post', '/cart/checkout-preview', a).send({
        cartId: cart.id,
        cartRowVersion: cart.rowVersion,
        paymentMethod: 'credit',
        strict: true,
        receiver: { kind: 'customer' },
        delivery: { method: 'pickup' },
      });
      const o = await order(a, cart);
      expect([pv.status, pv.body.code], cid).toEqual([o.status, o.body.code]);
      expect(o.body.code, cid).toBe(code);
    }
  });

  it('G-credit-4 (AC-PAY-032): X-Step-Up-Token другой сессии с creditOverride → 403 STEP_UP_REQUIRED', async () => {
    const s = await t.actor({ role: 'senior_seller' });
    const cust = await creditCustomer(v.price, { over: false, overdue: true, state: 'fresh' });
    const foreign = await t.stepUp(s, 'credit.sale.approve', 'pin', { sid: randomUUID() });
    const r = await order(
      s,
      await cartFor(s, cust.id),
      '1',
      { creditOverride: { reason: 'клиент оплатит завтра' } },
      foreign,
    );
    expect(r.status).toBe(403);
    expect(r.body).toMatchObject({ code: 'STEP_UP_REQUIRED' });
  });

  it('G-credit-4 (T-PAY-033 (9), (10); T-PAY-024 (б)): вариант C-2 — свежий снимок → долг без 1С; снимка нет → RECEIVABLES_STALE', async () => {
    const svc: { config: Record<string, unknown> } = t.app.get<unknown>(ReceivablesSnapshotService) as {
      config: Record<string, unknown>;
    };
    const cfg = svc.config;
    svc.config = { ...cfg, ONEC_INBOUND_ENABLED: true };
    const calls = receivableCalls();
    try {
      const a = await t.actor({ role: 'cashier' });
      const fresh = await creditCustomer(v.price, { over: false, overdue: false, state: 'fresh' });
      const ok = await order(a, await cartFor(a, fresh.id));
      expect(ok.status, JSON.stringify(ok.body)).toBe(202);
      const b = await t.actor({ role: 'cashier' });
      const none = await creditCustomer(v.price, { over: false, overdue: false, state: 'none' });
      const stale = await order(b, await cartFor(b, none.id));
      expect([stale.status, stale.body.code, stale.body.creditReason]).toEqual([
        422,
        'RECEIVABLES_STALE',
        'stale_snapshot',
      ]);
    } finally {
      svc.config = cfg;
    }
    expect(receivableCalls()).toBe(calls);
  });

  it('G-credit-5: creditOverride без блокировки и discountOverride в пределах лимита — подтверждения не записываются', async () => {
    const s = await t.actor({ role: 'senior_seller' });
    const cust = await creditCustomer(v.price, { over: false, overdue: false, state: 'fresh' });
    const cart = await cartFor(s, cust.id);
    const r = await order(s, cart, '1', { creditOverride: { reason: 'на всякий случай' } }, await step(s));
    expect([201, 202], JSON.stringify(r.body)).toContain(r.status);
    const id = r.body.id as string;
    const o = await t.q<{ by: string | null; at: Date | null; reason: string | null; dby: string | null }>(
      `SELECT credit_approved_by_user_id AS by, credit_approved_at AS at, credit_reason AS reason,
              discount_approved_by_user_id AS dby FROM orders WHERE id = $1`,
      [id],
    );
    expect(o[0]).toEqual({ by: null, at: null, reason: null, dby: null });
    const kinds = await t.q<{ kind: string }>(`SELECT kind::text AS kind FROM transactions WHERE order_id = $1`, [id]);
    expect(kinds.map((k) => k.kind)).toEqual(['order_created']);
    expect(await t.auditRows('credit.sale_approved', id)).toHaveLength(0);

    // discountOverride со step-up при ручной скидке в пределах лимита роли (senior_seller 10 %, Q-015): 5 %.
    const s2 = await t.actor({ role: 'senior_seller' });
    const cust2 = await creditCustomer(v.price, { over: false, overdue: false, state: 'fresh' });
    const cart2 = await cartFor(s2, cust2.id);
    const d = await order(
      s2,
      cart2,
      '1',
      { manualDiscountPercent: '5.00', discountOverride: { reason: 'в пределах лимита' } },
      await t.stepUp(s2, 'discount.approve.over_limit'),
    );
    expect([201, 202], JSON.stringify(d.body)).toContain(d.status);
    const did = d.body.id as string;
    const od = await t.q<{ dby: string | null; reason: string | null; pct: string }>(
      `SELECT discount_approved_by_user_id AS dby, discount_reason AS reason, discount_percent::text AS pct
         FROM orders WHERE id = $1`,
      [did],
    );
    expect(od[0]).toEqual({ dby: null, reason: null, pct: '5.00' });
    const dk = await t.q<{ kind: string }>(`SELECT kind::text AS kind FROM transactions WHERE order_id = $1`, [did]);
    expect(dk.map((k) => k.kind)).toEqual(['order_created']);
    expect(await t.auditRows('discount.over_limit_approved', did)).toHaveLength(0);
  });

  it('G-credit-7 (DEBT-013, T-DEBT-011): блокировка продажи в долг → in-app credit_blocked инициатору с причиной, без сумм', async () => {
    const a = await t.actor({ role: 'cashier' });
    const cust = await creditCustomer(v.price, { over: false, overdue: true, state: 'fresh' });
    const r = await order(a, await cartFor(a, cust.id));
    expect(r.body).toMatchObject({ code: 'CREDIT_BLOCKED', creditReason: 'overdue' });
    const n = await t.q<{ kind: string; title: string; body: string; payload: Record<string, unknown> }>(
      `SELECT kind::text AS kind, title_ru AS title, body_ru AS body, payload FROM notifications
        WHERE user_id = $1 ORDER BY created_at`,
      [a.userId],
    );
    expect(n).toHaveLength(1);
    expect(n[0]).toMatchObject({
      kind: 'credit_blocked',
      body: 'У клиента есть просроченная задолженность.',
      payload: { creditReason: 'overdue', code: 'CREDIT_BLOCKED' },
    });
    expect(n[0].body).not.toMatch(/\d/);
  });
});

// ================================================================================================ sync

describe('sync.receivables — фоновый снимок долга активных клиентов (05 SYNC-016)', () => {
  const ctx = (runId: string) => ({
    runId,
    entity: 'receivables' as const,
    mode: 'incremental' as const,
    trigger: 'manual' as const,
    jobId: randomUUID(),
    attempt: 1,
    log: { info: () => undefined, error: () => undefined, warn: () => undefined } as never,
    touch: () => Promise.resolve(),
  });
  const run = async () =>
    (
      await t.q<{ id: string }>(
        `INSERT INTO sync_runs (entity, mode, "trigger", status) VALUES ('receivables', 'incremental', 'manual', 'success') RETURNING id`,
      )
    )[0].id;

  it('снимки клиентов 1С обновлены (метка — ответ 1С); клиенты, которых 1С не знает, пропущены; повтор без изменений идемпотентен', async () => {
    const staleBefore = await snapshotAt(w.customers.stale.id);
    const h = new ReceivablesSyncHandler(t.pool, t.onec, { concurrency: 3 });
    const r = await h.run(ctx(await run()));
    expect(r.implemented).toBe(true);
    expect(r.counts).toMatchObject({ errors: 0 });
    expect((r.counts as { updated: number }).updated).toBeGreaterThan(20);
    expect(await snapshotAt(w.customers.stale.id)).toBeGreaterThan(staleBefore);
    // noSnapshot: снимка не было — теперь есть (клиент с отсрочкой — активный).
    expect(await t.receivablesRow(w.customers.noSnapshot.id)).toBeDefined();
    const buyerDocs = await t.q<{ n: number }>(
      `SELECT count(*)::int AS n FROM receivable_documents WHERE customer_id = $1 AND superseded_at IS NULL`,
      [w.customers.buyer.id],
    );
    expect(buyerDocs[0].n).toBeGreaterThan(0);
  });

  it('1С недоступна для всех → SyncRunError ONEC_UNAVAILABLE, снимки не изменены, sync_errors записаны; C-2 — не обращается к 1С', async () => {
    const before = await snapshotAt(w.customers.debtWithinLimit.id);
    t.onec.always('getCustomerReceivables', { transport: true });
    const runId = await run();
    const h = new ReceivablesSyncHandler(t.pool, t.onec);
    await expect(h.run(ctx(runId))).rejects.toBeInstanceOf(SyncRunError);
    t.onec.always('getCustomerReceivables', null);
    expect(await snapshotAt(w.customers.debtWithinLimit.id)).toBe(before);
    const errs = await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM sync_errors WHERE sync_run_id = $1`, [runId]);
    expect(errs[0].n).toBeGreaterThan(0);
    const calls = receivableCalls();
    const c2 = await new ReceivablesSyncHandler(t.pool, t.onec, { inboundMode: true }).run(ctx(runId));
    expect(c2.implemented).toBe(false);
    expect(receivableCalls()).toBe(calls);
  });

  it('ответ 1С вне контракта (просрочка больше сальдо) → снимок клиента не применяется (VALIDATION), прогон partial', async () => {
    const ref = CASHIER_SCENARIOS.debtWithinLimit;
    const before = await t.receivablesRow(w.customers.debtWithinLimit.id);
    t.cashier.setReceivables(ref, { balance: '100.00', overdueAmount: '500.00', overdueDays: 3, documents: [] });
    const runId = await run();
    const r = await new ReceivablesSyncHandler(t.pool, t.onec).run(ctx(runId));
    expect(r.status).toBe('partial');
    expect((await t.receivablesRow(w.customers.debtWithinLimit.id)).balance).toBe(before.balance);
    const errs = await t.q<{ error_code: string }>(`SELECT error_code FROM sync_errors WHERE sync_run_id = $1`, [
      runId,
    ]);
    expect(errs.map((e) => e.error_code)).toEqual(['VALIDATION']);
  });
});

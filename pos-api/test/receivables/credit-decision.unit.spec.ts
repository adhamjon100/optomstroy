import { describe, expect, it } from 'vitest';
import { Money } from '../../src/common/money/money.js';
import type { ReceivablesRefreshOutcome, SalesActor } from '../../src/common/ports/index.js';
import { PermissionCatalog } from '../../src/common/rbac/permission-catalog.js';
import type { DbExecutor } from '../../src/common/audit/db-executor.js';
import {
  CreditCustomerLookup,
  type CreditCustomerRow,
  SnapshotCreditDecisionService,
} from '../../src/sales-domain/adapters/snapshot-credit-decision.service.js';
import { creditRefusalError, decideCredit } from '../../src/sales-domain/credit/credit-decision.js';
import { InMemoryReceivablesSnapshots } from '../support/cashier-ports.fakes.js';

/**
 * Решение о продаже в долг — unit (без БД; **тестовые данные**): `SnapshotCreditDecisionService` поверх заглушки
 * снимков долга и чистая функция `decideCredit` (10 PAY-031; ядро §22.4 в редакции §23 п. 5; 12 T-PAY-033, T-DEBT-009).
 * Полная матрица fail-closed {снимок свежий / устаревший / неполный / нет} × {в лимите / сверх} × {просрочка есть /
 * нет} × {1С доступна / нет} сверяется с оракулом, записанным по тексту PAY-031 (не по коду реализации); причины шага 1
 * (право роли, клиент не выбран / «Розничный покупатель» / без карточки 1С / помечен на удаление, `credit_allowed`) —
 * без чтения снимка и без обращения к 1С; разблокировка `creditOverride` (PAY-032, DEBT-010) — только блокировки
 * шага 2 и только с правом `credit.sale.approve`.
 */

const CUSTOMER = '01900000-0000-7000-8000-0000000000c1';
const catalog = new PermissionCatalog();
const actor = (role: string, isCustomer = false): SalesActor => ({ userId: null, roles: [role], isCustomer });

class FakeCustomers {
  readonly rows = new Map<string, CreditCustomerRow>();
  calls = 0;
  load(_tx: unknown, id: string): Promise<CreditCustomerRow | null> {
    this.calls += 1;
    return Promise.resolve(this.rows.get(id) ?? null);
  }
}

/** Снимки с «истиной 1С»: `refresh` при доступной 1С записывает истину (`snapshotAt = now`), иначе — `unavailable`. */
class Snapshots extends InMemoryReceivablesSnapshots {
  truth: { balance: string; overdueAmount: string | null } | null = null;
  onec: 'up' | 'down' | 'not_in_onec' = 'up';
  snapshotCalls = 0;
  /** Побочный эффект обновления из 1С (запись условий соглашения клиента — writeReceivablesSnapshot, ONEC-047). */
  onRefreshed: (() => void) | null = null;

  override snapshot(tx: unknown, id: string, now?: Date) {
    this.snapshotCalls += 1;
    return super.snapshot(tx, id, now);
  }

  override async refresh(customerId: string): Promise<ReceivablesRefreshOutcome> {
    this.refreshCalls.push(customerId);
    if (this.onec === 'not_in_onec') return { kind: 'not_in_onec' };
    if (this.onec === 'down' || !this.truth) {
      return { kind: 'unavailable', snapshot: await super.snapshot(null, customerId), reason: 'TRANSPORT' };
    }
    this.set(customerId, { ...this.truth, ageMinutes: 0 });
    this.onRefreshed?.();
    return { kind: 'refreshed', snapshot: (await super.snapshot(null, customerId))! };
  }
}

function service(rows: Partial<CreditCustomerRow> | null = {}): {
  svc: SnapshotCreditDecisionService;
  customers: FakeCustomers;
  snaps: Snapshots;
} {
  const customers = new FakeCustomers();
  if (rows !== null) {
    customers.rows.set(CUSTOMER, {
      isRetailDefault: false,
      onecRef: 'c3d4e5f6-0000-4000-8000-0000000000aa',
      deletionMark: false,
      deleted: false,
      creditAllowed: true,
      creditLimit: '100000.00',
      ...rows,
    });
  }
  const snaps = new Snapshots();
  const svc = new SnapshotCreditDecisionService(customers as unknown as CreditCustomerLookup, snaps, catalog);
  return { svc, customers, snaps };
}

type SnapState = 'fresh' | 'stale' | 'incomplete' | 'none';

/**
 * Оракул PAY-031 для клиента, прошедшего шаг 1: шаг 2 по имеющемуся снимку (любой возраст; просрочка известна и > 0
 * → `CREDIT_BLOCKED overdue`; сумма сверх `лимит − сальдо − открытые заказы` → `CREDIT_LIMIT_EXCEEDED`); снимок
 * не свежий/неполный/нет → обновление: 1С недоступна → `RECEIVABLES_STALE`; доступна → шаг 2 по истине 1С;
 * иначе → разрешено.
 */
function oracle(c: { state: SnapState; overdue: boolean; over: boolean; onecUp: boolean }): {
  code: string;
  reason: string | null;
  refresh: boolean;
} {
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

describe('SnapshotCreditDecisionService — матрица fail-closed PAY-031 (T-PAY-033)', () => {
  const states: SnapState[] = ['fresh', 'stale', 'incomplete', 'none'];
  const cases = states.flatMap((state) =>
    [false, true].flatMap((over) =>
      [false, true].flatMap((overdue) => [true, false].map((onecUp) => ({ state, over, overdue, onecUp }))),
    ),
  );

  it.each(cases)('снимок $state, сверх лимита=$over, просрочка=$overdue, 1С доступна=$onecUp', async (c) => {
    const { svc, snaps } = service({ creditLimit: '100000.00' });
    // Истина 1С: сальдо 40 000; просрочка 5 000 или 0; заказ 50 000 (в лимите) или 70 000 (сверх).
    const truth = { balance: '40000.00', overdueAmount: c.overdue ? '5000.00' : '0.00' };
    snaps.truth = truth;
    snaps.onec = c.onecUp ? 'up' : 'down';
    if (c.state === 'fresh') snaps.set(CUSTOMER, { ...truth, ageMinutes: 5 });
    if (c.state === 'stale') snaps.set(CUSTOMER, { ...truth, ageMinutes: 180 });
    if (c.state === 'incomplete') snaps.set(CUSTOMER, { balance: truth.balance, overdueAmount: null, ageMinutes: 5 });
    const total = c.over ? '70000.00' : '50000.00';
    const r = await svc.check(null, { actor: actor('cashier'), customerId: CUSTOMER, total, override: null });
    const exp = oracle(c);
    if (exp.code === 'ALLOWED') {
      expect(r).toMatchObject({ allowed: true, overrideUsed: false });
      if (r.allowed) {
        // Остаток лимита до заказа: 100 000 − 40 000 − 0 (MV-21).
        expect(r.limitRemaining).toBe('60000.00');
        expect(r.receivablesAsOf).toBeInstanceOf(Date);
      }
    } else {
      expect(r).toMatchObject({ allowed: false, code: exp.code, creditReason: exp.reason });
    }
    // 503/ONEC_UNAVAILABLE для долга не возвращается ни в одном случае (ядро §22.4).
    expect(JSON.stringify(r)).not.toContain('ONEC_UNAVAILABLE');
    expect(snaps.refreshCalls.length).toBe(exp.refresh ? 1 : 0);
  });
});

describe('SnapshotCreditDecisionService — шаг 1 PAY-031 (ядро §23 п. 5): без снимка и без 1С', () => {
  it.each([
    ['admin (нет credit.sale.create, D-15)', actor('admin'), 'FORBIDDEN', 'forbidden_role'],
    ['owner', actor('owner'), 'FORBIDDEN', 'forbidden_role'],
    ['режим клиента', actor('customer', true), 'FORBIDDEN', 'forbidden_role'],
  ])('%s → %s', async (_n, a, code, reason) => {
    const { svc, customers, snaps } = service();
    const r = await svc.check(null, { actor: a, customerId: CUSTOMER, total: '10.00', override: null });
    expect(r).toMatchObject({ allowed: false, code, creditReason: reason });
    expect(customers.calls).toBe(0);
    expect(snaps.snapshotCalls).toBe(0);
    expect(snaps.refreshCalls).toEqual([]);
  });

  it.each([
    ['клиент не выбран', null, {}],
    ['не UUID', 'nope', {}],
    ['клиента нет', '01900000-0000-7000-8000-0000000000ff', {}],
    ['«Розничный покупатель»', CUSTOMER, { isRetailDefault: true, onecRef: null }],
    ['без карточки 1С (source=pos до подтверждения)', CUSTOMER, { onecRef: null }],
    ['помечен на удаление', CUSTOMER, { deletionMark: true }],
    ['удалён', CUSTOMER, { deleted: true }],
  ] as const)('%s → 422 CUSTOMER_NOT_IDENTIFIED без creditReason', async (_n, id, row) => {
    const { svc, snaps } = service(row);
    snaps.set(CUSTOMER, { balance: '0.00', overdueAmount: '0.00', ageMinutes: 1 });
    const r = await svc.check(null, { actor: actor('seller'), customerId: id, total: '10.00', override: null });
    expect(r).toMatchObject({ allowed: false, code: 'CUSTOMER_NOT_IDENTIFIED', creditReason: null });
    expect(snaps.snapshotCalls).toBe(0);
    expect(snaps.refreshCalls).toEqual([]);
  });

  it('credit_allowed=false → CREDIT_BLOCKED credit_not_allowed до снимка (даже устаревшего, 1С недоступна)', async () => {
    const { svc, snaps } = service({ creditAllowed: false });
    snaps.set(CUSTOMER, { balance: '0.00', overdueAmount: null, ageMinutes: 600 });
    snaps.onec = 'down';
    const r = await svc.check(null, {
      actor: actor('senior_seller'),
      customerId: CUSTOMER,
      total: '10.00',
      override: { reason: 'старший разрешил' },
    });
    expect(r).toMatchObject({ allowed: false, code: 'CREDIT_BLOCKED', creditReason: 'credit_not_allowed' });
    expect(snaps.snapshotCalls).toBe(0);
    expect(snaps.refreshCalls).toEqual([]);
    // Клиент без просрочки никогда не получает `creditReason=overdue` (AC-SYNC-055).
    expect(r).not.toMatchObject({ creditReason: 'overdue' });
  });
});

describe('SnapshotCreditDecisionService — лимит, открытые заказы, разблокировка (PAY-032, DEBT-010…012)', () => {
  it('лимит в 1С не задан → CREDIT_LIMIT_EXCEEDED «Лимит в 1С не задан» (без 1С, снимок свежий)', async () => {
    const { svc, snaps } = service({ creditLimit: null });
    snaps.set(CUSTOMER, { balance: '0.00', overdueAmount: '0.00', ageMinutes: 1 });
    const r = await svc.check(null, { actor: actor('cashier'), customerId: CUSTOMER, total: '1.00', override: null });
    expect(r).toMatchObject({
      allowed: false,
      code: 'CREDIT_LIMIT_EXCEEDED',
      creditReason: 'limit_exceeded',
      limitRemaining: null,
    });
    expect(r.allowed === false && r.detail).toBe('Лимит в 1С не задан.');
  });

  it('открытые заказы в долг уменьшают остаток лимита (DEBT-011, MV-21): 100 000 − 64 500 − 20 000 = 15 500', async () => {
    const { svc, snaps } = service();
    snaps.set(CUSTOMER, { balance: '64500.00', overdueAmount: '0.00', ageMinutes: 1 });
    snaps.openOrders.set(CUSTOMER, '20000.00');
    const ok = await svc.check(null, {
      actor: actor('cashier'),
      customerId: CUSTOMER,
      total: '15500.00',
      override: null,
    });
    expect(ok).toMatchObject({ allowed: true, limitRemaining: '15500.00' });
    const over = await svc.check(null, {
      actor: actor('cashier'),
      customerId: CUSTOMER,
      total: '15500.01',
      override: null,
    });
    expect(over).toMatchObject({ allowed: false, code: 'CREDIT_LIMIT_EXCEEDED', limitRemaining: '15500.00' });
  });

  it('MV-22: сальдо больше лимита → остаток отрицательный, отказ; сообщение показывает 0', async () => {
    const { svc, snaps } = service({ creditLimit: '50000.00' });
    snaps.set(CUSTOMER, { balance: '62000.00', overdueAmount: '0.00', ageMinutes: 1 });
    const r = await svc.check(null, { actor: actor('cashier'), customerId: CUSTOMER, total: '1.00', override: null });
    expect(r).toMatchObject({ allowed: false, code: 'CREDIT_LIMIT_EXCEEDED', limitRemaining: '-12000.00' });
    expect(r.allowed === false && r.detail).toContain('доступно 0,00 сом');
  });

  it('senior_seller с creditOverride снимает просрочку и превышение (overrideUsed); без блокировки override не используется', async () => {
    const { svc, snaps } = service();
    snaps.set(CUSTOMER, { balance: '99000.00', overdueAmount: '500.00', ageMinutes: 3 });
    const r = await svc.check(null, {
      actor: actor('senior_seller'),
      customerId: CUSTOMER,
      total: '5000.00',
      override: { reason: 'постоянный клиент' },
    });
    expect(r).toMatchObject({ allowed: true, overrideUsed: true });
    snaps.set(CUSTOMER, { balance: '0.00', overdueAmount: '0.00', ageMinutes: 3 });
    const plain = await svc.check(null, {
      actor: actor('senior_seller'),
      customerId: CUSTOMER,
      total: '5000.00',
      override: { reason: 'на всякий случай' },
    });
    expect(plain).toMatchObject({ allowed: true, overrideUsed: false });
  });

  it('override без права credit.sale.approve (cashier) не учитывается → CREDIT_BLOCKED overdue', async () => {
    const { svc, snaps } = service();
    snaps.set(CUSTOMER, { balance: '1000.00', overdueAmount: '500.00', ageMinutes: 3 });
    const r = await svc.check(null, {
      actor: actor('cashier'),
      customerId: CUSTOMER,
      total: '10.00',
      override: { reason: 'попытка кассира' },
    });
    expect(r).toMatchObject({ allowed: false, code: 'CREDIT_BLOCKED', creditReason: 'overdue' });
  });

  it('override не снимает RECEIVABLES_STALE: устаревший снимок с просрочкой, 1С недоступна', async () => {
    const { svc, snaps } = service();
    snaps.set(CUSTOMER, { balance: '1000.00', overdueAmount: '500.00', ageMinutes: 300 });
    snaps.onec = 'down';
    const r = await svc.check(null, {
      actor: actor('senior_seller'),
      customerId: CUSTOMER,
      total: '10.00',
      override: { reason: 'старший разрешил' },
    });
    expect(r).toMatchObject({ allowed: false, code: 'RECEIVABLES_STALE', creditReason: 'stale_snapshot' });
    expect(r.allowed === false && r.receivablesAsOf).toBeInstanceOf(Date);
  });

  it('override + устаревший снимок, 1С доступна и подтверждает просрочку → разрешено старшим (overrideUsed)', async () => {
    const { svc, snaps } = service();
    snaps.set(CUSTOMER, { balance: '1000.00', overdueAmount: '0.00', ageMinutes: 300 });
    snaps.truth = { balance: '1000.00', overdueAmount: '700.00' };
    const r = await svc.check(null, {
      actor: actor('senior_seller'),
      customerId: CUSTOMER,
      total: '10.00',
      override: { reason: 'старший разрешил' },
    });
    expect(r).toMatchObject({ allowed: true, overrideUsed: true });
    expect(snaps.refreshCalls).toEqual([CUSTOMER]);
  });

  it('1С не знает клиента (not_in_onec при обновлении) → RECEIVABLES_STALE; снимка нет → receivablesAsOf null', async () => {
    const { svc, snaps } = service();
    snaps.onec = 'not_in_onec';
    const r = await svc.check(null, { actor: actor('cashier'), customerId: CUSTOMER, total: '10.00', override: null });
    expect(r).toMatchObject({ allowed: false, code: 'RECEIVABLES_STALE', receivablesAsOf: null });
  });

  it('порог устаревания — из порта (maxAgeMinutes): 61 мин при пороге 60 → обновление; при 120 — без 1С', async () => {
    const { svc, snaps } = service();
    snaps.set(CUSTOMER, { balance: '0.00', overdueAmount: '0.00', ageMinutes: 61 });
    snaps.onec = 'down';
    expect(
      await svc.check(null, { actor: actor('cashier'), customerId: CUSTOMER, total: '1.00', override: null }),
    ).toMatchObject({ code: 'RECEIVABLES_STALE' });
    snaps.maxAge = 120;
    expect(
      await svc.check(null, { actor: actor('cashier'), customerId: CUSTOMER, total: '1.00', override: null }),
    ).toMatchObject({ allowed: true });
  });

  it('время возраста снимка — `now` сервиса (подмена часов)', async () => {
    const { svc, snaps } = service();
    snaps.set(CUSTOMER, { balance: '0.00', overdueAmount: '0.00', ageMinutes: 0 });
    snaps.onec = 'down';
    svc.now = () => new Date(Date.now() + 2 * 3600_000);
    expect(
      await svc.check(null, { actor: actor('cashier'), customerId: CUSTOMER, total: '1.00', override: null }),
    ).toMatchObject({ code: 'RECEIVABLES_STALE' });
  });
});

describe('SnapshotCreditDecisionService — условия соглашения после обновления из 1С (ревью G-credit-1, GQ-CRD-10)', () => {
  const stale = (snaps: Snapshots) => {
    snaps.set(CUSTOMER, { balance: '40000.00', overdueAmount: '0.00', ageMinutes: 180 });
    snaps.truth = { balance: '40000.00', overdueAmount: '0.00' };
  };

  it('1С при обновлении запретила отсрочку → CREDIT_BLOCKED credit_not_allowed (карточка перечитана)', async () => {
    const { svc, customers, snaps } = service({ creditLimit: '100000.00' });
    stale(snaps);
    snaps.onRefreshed = () => {
      const row = customers.rows.get(CUSTOMER)!;
      customers.rows.set(CUSTOMER, { ...row, creditAllowed: false, creditLimit: '10000.00' });
    };
    const r = await svc.check(null, {
      actor: actor('cashier'),
      customerId: CUSTOMER,
      total: '50000.00',
      override: null,
    });
    expect(r).toMatchObject({ allowed: false, code: 'CREDIT_BLOCKED', creditReason: 'credit_not_allowed' });
    expect(customers.calls).toBe(2);
    expect(snaps.refreshCalls).toEqual([CUSTOMER]);
  });

  it('1С при обновлении снизила лимит → CREDIT_LIMIT_EXCEEDED по новому лимиту (остаток 10 000 − 40 000)', async () => {
    const { svc, customers, snaps } = service({ creditLimit: '100000.00' });
    stale(snaps);
    snaps.onRefreshed = () => {
      const row = customers.rows.get(CUSTOMER)!;
      customers.rows.set(CUSTOMER, { ...row, creditLimit: '10000.00' });
    };
    const r = await svc.check(null, {
      actor: actor('cashier'),
      customerId: CUSTOMER,
      total: '50000.00',
      override: null,
    });
    expect(r).toMatchObject({
      allowed: false,
      code: 'CREDIT_LIMIT_EXCEEDED',
      creditReason: 'limit_exceeded',
      limitRemaining: '-30000.00',
    });
  });

  it('1С при обновлении повысила лимит → разрешено, остаток — по новому лимиту', async () => {
    const { svc, customers, snaps } = service({ creditLimit: '100000.00' });
    stale(snaps);
    snaps.onRefreshed = () => {
      const row = customers.rows.get(CUSTOMER)!;
      customers.rows.set(CUSTOMER, { ...row, creditLimit: '200000.00' });
    };
    const r = await svc.check(null, {
      actor: actor('cashier'),
      customerId: CUSTOMER,
      total: '50000.00',
      override: null,
    });
    expect(r).toMatchObject({ allowed: true, limitRemaining: '160000.00' });
  });
});

describe('SnapshotCreditDecisionService — повторная проверка без обращения к 1С (allowRefresh=false, ревью G-credit-3)', () => {
  it('свежий снимок — решение как обычно; устаревший — RECEIVABLES_STALE без refresh', async () => {
    const { svc, snaps } = service();
    snaps.set(CUSTOMER, { balance: '0.00', overdueAmount: '0.00', ageMinutes: 1 });
    expect(
      await svc.check(null, {
        actor: actor('cashier'),
        customerId: CUSTOMER,
        total: '10.00',
        override: null,
        allowRefresh: false,
      }),
    ).toMatchObject({ allowed: true });
    snaps.set(CUSTOMER, { balance: '0.00', overdueAmount: '0.00', ageMinutes: 600 });
    const stale = await svc.check(null, {
      actor: actor('cashier'),
      customerId: CUSTOMER,
      total: '10.00',
      override: null,
      allowRefresh: false,
    });
    expect(stale).toMatchObject({ allowed: false, code: 'RECEIVABLES_STALE', creditReason: 'stale_snapshot' });
    expect(snaps.refreshCalls).toEqual([]);
  });
});

describe('decideCredit — граничные ветви чистой функции (10 PAY-031)', () => {
  const customer = { isRetailDefault: false, hasOnecRef: true, creditAllowed: true, creditLimit: Money.of('100.00') };
  const now = new Date('2026-10-24T06:00:00Z');
  const base = {
    canSellOnCredit: true,
    customer,
    openOrdersAmount: Money.ZERO,
    total: Money.of('100.00'),
    now,
    maxAgeMinutes: 60,
    override: false,
  };

  it('ровно в лимит и ровно на пороге возраста (60 мин) — разрешено без обновления', () => {
    const d = decideCredit({
      ...base,
      snapshot: { balance: Money.ZERO, overdueAmount: Money.ZERO, snapshotAt: new Date(now.getTime() - 60 * 60_000) },
    });
    expect(d).toMatchObject({ kind: 'allowed', overrideUsed: false });
  });

  it('снимок без лимита и без просрочки, свежий → limit_exceeded; отрицательная просрочка (аванс) не блокирует', () => {
    const d = decideCredit({
      ...base,
      customer: { ...customer, creditLimit: null },
      snapshot: { balance: Money.of('-50.00'), overdueAmount: Money.of('0.00'), snapshotAt: now },
    });
    expect(d).toMatchObject({ kind: 'refused', code: 'CREDIT_LIMIT_EXCEEDED', step: 2 });
    const ok = decideCredit({
      ...base,
      snapshot: { balance: Money.of('-50.00'), overdueAmount: Money.of('-1.00'), snapshotAt: now },
    });
    expect(ok).toMatchObject({ kind: 'allowed' });
  });

  it('метка снимка «из будущего» сверх допуска часов → не свежий (refresh_required; после попытки — STALE); в допуске — свежий', () => {
    const future = {
      balance: Money.ZERO,
      overdueAmount: Money.ZERO,
      snapshotAt: new Date(now.getTime() + 24 * 3600_000),
    };
    expect(decideCredit({ ...base, snapshot: future })).toEqual({ kind: 'refresh_required' });
    expect(decideCredit({ ...base, snapshot: future, refresh: 'unavailable' })).toMatchObject({
      kind: 'refused',
      code: 'RECEIVABLES_STALE',
    });
    const skew = { ...future, snapshotAt: new Date(now.getTime() + 4 * 60_000) };
    expect(decideCredit({ ...base, snapshot: skew })).toMatchObject({ kind: 'allowed' });
  });

  it('нет снимка, обновление не выполнялось → refresh_required; creditRefusalError переносит creditReason/limitRemaining', () => {
    expect(decideCredit({ ...base, snapshot: null })).toEqual({ kind: 'refresh_required' });
    const refused = decideCredit({
      ...base,
      total: Money.of('101.00'),
      snapshot: { balance: Money.ZERO, overdueAmount: Money.ZERO, snapshotAt: now },
    });
    if (refused.kind !== 'refused') throw new Error('ожидался отказ');
    const e = creditRefusalError(refused);
    expect(e.code).toBe('CREDIT_LIMIT_EXCEEDED');
    expect(e.extensions).toMatchObject({ creditReason: 'limit_exceeded', limitRemaining: { amount: '100.00' } });
    const step1 = decideCredit({ ...base, customer: null, snapshot: null });
    if (step1.kind !== 'refused') throw new Error('ожидался отказ');
    expect(creditRefusalError(step1).extensions).toEqual({});
  });
});

describe('CreditCustomerLookup и разблокировка без лимита (ветви адаптера)', () => {
  it('load: транзакция вызывающего или пул; нет строки → null; строка → карточка', async () => {
    const used: string[] = [];
    const exec = (name: string, rows: Record<string, unknown>[]) => ({
      execute: () => {
        used.push(name);
        return Promise.resolve({ rows });
      },
    });
    const row = {
      is_retail_default: false,
      onec_ref: 'r',
      deletion_mark: false,
      deleted: false,
      credit_allowed: true,
      credit_limit: null,
    };
    const lookup = new CreditCustomerLookup(exec('pool', []) as unknown as DbExecutor);
    expect(await lookup.load(null, CUSTOMER)).toBeNull();
    expect(await lookup.load(exec('tx', [row]) as unknown as DbExecutor, CUSTOMER)).toEqual({
      isRetailDefault: false,
      onecRef: 'r',
      deletionMark: false,
      deleted: false,
      creditAllowed: true,
      creditLimit: null,
    });
    expect(used).toEqual(['pool', 'tx']);
  });

  it('лимит не задан + creditOverride senior_seller → разрешено, limitRemaining=null (DEBT-012 → DEBT-010)', async () => {
    const { svc, snaps } = service({ creditLimit: null });
    snaps.set(CUSTOMER, { balance: '0.00', overdueAmount: '0.00', ageMinutes: 1 });
    const r = await svc.check(null, {
      actor: actor('senior_seller'),
      customerId: CUSTOMER,
      total: '10.00',
      override: { reason: 'старший разрешил' },
    });
    expect(r).toMatchObject({ allowed: true, overrideUsed: true, limitRemaining: null });
  });
});

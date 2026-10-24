import { describe, expect, it } from 'vitest';
import type { CreditCheckInput, CreditCheckResult, CreditDecisionService } from '../../src/common/ports/index.js';
import { ProblemException } from '../../src/common/problem-details/problem.exception.js';
import { CreditGate } from '../../src/payments/credit/credit-gate.js';
import { FailClosedCreditDecisionService } from '../../src/sales-domain/adapters/fail-closed-credit.js';
import { decideCredit, type CreditDecisionInput } from '../../src/sales-domain/credit/credit-decision.js';
import { Money } from '../../src/common/money/money.js';

const staff = { userId: '0192f601-0000-7000-8000-000000000001', roles: ['cashier'], isCustomer: false };
const input = (over: Partial<CreditCheckInput> = {}): CreditCheckInput => ({
  actor: staff,
  customerId: '0192f601-0000-7000-8000-0000000000c1',
  total: '16007.50',
  override: null,
  ...over,
});

/** Реализация порта по чистой функции `decideCredit` (как сделает RM-G-002) — для матрицы причин отказа. */
class DecideCreditService implements CreditDecisionService {
  constructor(private readonly base: Omit<CreditDecisionInput, 'override' | 'total' | 'now'>) {}

  check(_tx: unknown, i: CreditCheckInput): Promise<CreditCheckResult> {
    let d = decideCredit({ ...this.base, total: Money.of(i.total), override: i.override !== null, now: new Date() });
    if (d.kind === 'refresh_required') {
      d = decideCredit({
        ...this.base,
        total: Money.of(i.total),
        override: i.override !== null,
        now: new Date(),
        refresh: 'unavailable',
      });
    }
    if (d.kind === 'allowed') {
      return Promise.resolve({
        allowed: true,
        overrideUsed: d.overrideUsed,
        limitRemaining: d.limitRemaining?.toString() ?? null,
        receivablesAsOf: d.receivablesAsOf,
      });
    }
    if (d.kind === 'refresh_required') throw new Error('unreachable');
    return Promise.resolve({
      allowed: false,
      code: d.code,
      creditReason: d.creditReason,
      detail: d.detail,
      ...(d.limitRemaining !== undefined ? { limitRemaining: d.limitRemaining?.toString() ?? null } : {}),
      ...(d.receivablesAsOf !== undefined ? { receivablesAsOf: d.receivablesAsOf } : {}),
    });
  }
}

const fresh = { balance: Money.of('1000.00'), overdueAmount: Money.ZERO, snapshotAt: new Date() };
const customer = { isRetailDefault: false, hasOnecRef: true, creditAllowed: true, creditLimit: Money.of('100000.00') };
const base = { canSellOnCredit: true, customer, snapshot: fresh, openOrdersAmount: Money.ZERO, maxAgeMinutes: 60 };

async function refusal(gate: CreditGate, i = input()): Promise<ProblemException> {
  try {
    await gate.require(null, i);
  } catch (e) {
    if (e instanceof ProblemException) return e;
    throw e;
  }
  throw new Error('ожидался отказ');
}

/**
 * Решение о продаже в долг (RM-F-003; 10 PAY-031; ядро §22.4, §23 п. 5): `CreditGate` поверх порта
 * `CreditDecisionService` — коды и `creditReason` 08 §2.4 для каждой причины; 503 не возвращается.
 */
describe('CreditGate (порядок PAY-031, creditReason)', () => {
  // 12: T-PAY-033 (порядок проверок продажи в долг: шаг 1, fail-closed до этапа G)
  it('по умолчанию до этапа G — fail-closed: 422 CREDIT_BLOCKED; customer — 403 forbidden_role', async () => {
    const gate = new CreditGate(new FailClosedCreditDecisionService());
    let e = await refusal(gate);
    expect(e.code).toBe('CREDIT_BLOCKED');
    expect(e.getStatus()).toBe(422);
    e = await refusal(gate, input({ actor: { ...staff, roles: ['customer'], isCustomer: true } }));
    expect(e.code).toBe('FORBIDDEN');
    expect(e.extensions.creditReason).toBe('forbidden_role');
  });

  it.each([
    ['forbidden_role', { ...base, canSellOnCredit: false }, 'FORBIDDEN', 403],
    [
      'CUSTOMER_NOT_IDENTIFIED (Розничный)',
      { ...base, customer: { ...customer, isRetailDefault: true } },
      'CUSTOMER_NOT_IDENTIFIED',
      422,
    ],
    [
      'CUSTOMER_NOT_IDENTIFIED (нет onec_ref)',
      { ...base, customer: { ...customer, hasOnecRef: false } },
      'CUSTOMER_NOT_IDENTIFIED',
      422,
    ],
    ['credit_not_allowed', { ...base, customer: { ...customer, creditAllowed: false } }, 'CREDIT_BLOCKED', 422],
    ['overdue', { ...base, snapshot: { ...fresh, overdueAmount: Money.of('500.00') } }, 'CREDIT_BLOCKED', 422],
    [
      'limit_exceeded',
      { ...base, customer: { ...customer, creditLimit: Money.of('2000.00') } },
      'CREDIT_LIMIT_EXCEEDED',
      422,
    ],
    [
      'limit_exceeded (лимит не задан)',
      { ...base, customer: { ...customer, creditLimit: null } },
      'CREDIT_LIMIT_EXCEEDED',
      422,
    ],
    [
      'stale_snapshot',
      { ...base, snapshot: { ...fresh, snapshotAt: new Date(Date.now() - 3 * 3600_000) } },
      'RECEIVABLES_STALE',
      422,
    ],
    ['stale_snapshot (неполный)', { ...base, snapshot: { ...fresh, overdueAmount: null } }, 'RECEIVABLES_STALE', 422],
  ] as const)('%s → %s', async (name, cfg, code, status) => {
    const gate = new CreditGate(new DecideCreditService(cfg));
    const e = await refusal(gate);
    expect(e.code).toBe(code);
    expect(e.getStatus()).toBe(status);
    const expectedReason: Record<string, string | undefined> = {
      forbidden_role: 'forbidden_role',
      credit_not_allowed: 'credit_not_allowed',
      overdue: 'overdue',
      limit_exceeded: 'limit_exceeded',
      'limit_exceeded (лимит не задан)': 'limit_exceeded',
      stale_snapshot: 'stale_snapshot',
      'stale_snapshot (неполный)': 'stale_snapshot',
    };
    expect(e.extensions.creditReason).toBe(expectedReason[name]);
    if (code === 'CREDIT_LIMIT_EXCEEDED' && name === 'limit_exceeded') {
      expect(e.extensions.limitRemaining).toEqual({ amount: '1000.00', currency: 'KGS' });
    }
  });

  // 12: T-PAY-033 (override снимает только шаг 2)
  it('override снимает только шаг 2 (просрочка), не шаг 1; свежий снимок без блокировок — разрешено', async () => {
    const overdue = new CreditGate(
      new DecideCreditService({ ...base, snapshot: { ...fresh, overdueAmount: Money.of('1.00') } }),
    );
    const ok = await overdue.require(null, input({ override: { reason: 'клиент оплатит завтра' } }));
    expect(ok.overrideUsed).toBe(true);
    const noCredit = new CreditGate(
      new DecideCreditService({ ...base, customer: { ...customer, creditAllowed: false } }),
    );
    const e = await refusal(noCredit, input({ override: { reason: 'клиент оплатит завтра' } }));
    expect(e.extensions.creditReason).toBe('credit_not_allowed');
    const allowed = await new CreditGate(new DecideCreditService(base)).require(null, input());
    expect(allowed).toMatchObject({ overrideUsed: false, limitRemaining: '99000.00' });
  });

  it('сбой/таймаут реализации порта (1С недоступна) → 422 RECEIVABLES_STALE, не 503', async () => {
    const failing: CreditDecisionService = { check: () => Promise.reject(new Error('timeout 6000 ms')) };
    let e = await refusal(new CreditGate(failing));
    expect(e.code).toBe('RECEIVABLES_STALE');
    expect(e.extensions.creditReason).toBe('stale_snapshot');
    const onecDown: CreditDecisionService = {
      check: () => Promise.reject(new ProblemException('ONEC_UNAVAILABLE', { detail: '1С недоступна' })),
    };
    e = await refusal(new CreditGate(onecDown));
    expect(e.code).toBe('RECEIVABLES_STALE');
  });
});

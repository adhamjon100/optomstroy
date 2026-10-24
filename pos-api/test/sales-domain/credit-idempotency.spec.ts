import fc from 'fast-check';
import { describe, expect, it } from 'vitest';
import { Money } from '../../src/common/money/money.js';
import {
  type CreditCustomer,
  type CreditDecisionInput,
  creditRefusalError,
  decideCredit,
} from '../../src/sales-domain/credit/credit-decision.js';
import {
  initialPaymentIdempotencyKey,
  isSoftDuplicate,
  orderCompositionHash,
  SOFT_DUPLICATE_WINDOW_MS,
} from '../../src/sales-domain/idempotency/sales-idempotency.js';

/** Решение о долге — порядок 10 PAY-031 (ядро §22.4, §23 п. 5); идемпотентность (08 §2.7, ядро §22.6). */
const now = new Date('2026-10-22T10:00:00Z');
const ago = (min: number) => new Date(now.getTime() - min * 60_000);
const customer: CreditCustomer = {
  isRetailDefault: false,
  hasOnecRef: true,
  creditAllowed: true,
  creditLimit: Money.of('100000.00'),
};
const input = (p: Partial<CreditDecisionInput>): CreditDecisionInput => ({
  canSellOnCredit: true,
  customer,
  snapshot: { balance: Money.of('20000.00'), overdueAmount: Money.ZERO, snapshotAt: ago(5) },
  openOrdersAmount: Money.ZERO,
  total: Money.of('16007.50'),
  now,
  maxAgeMinutes: 60,
  override: false,
  ...p,
});

describe('decideCredit — порядок PAY-031', () => {
  it('шаг 4: свежий полный снимок без блокировок — разрешено без 1С', () => {
    expect(decideCredit(input({}))).toMatchObject({ kind: 'allowed', overrideUsed: false });
    expect((decideCredit(input({})) as { limitRemaining: Money }).limitRemaining.toString()).toBe('80000.00');
  });

  // 12: T-PAY-033 (1) (admin без credit.sale.create → 403 forbidden_role)
  it('шаг 1: нет права → 403 forbidden_role (раньше всего остального)', () => {
    expect(decideCredit(input({ canSellOnCredit: false, customer: null, snapshot: null }))).toMatchObject({
      kind: 'refused',
      code: 'FORBIDDEN',
      creditReason: 'forbidden_role',
      step: 1,
    });
  });

  it('шаг 1: клиент не выбран / «Розничный покупатель» / без onec_ref → CUSTOMER_NOT_IDENTIFIED без creditReason', () => {
    for (const c of [null, { ...customer, isRetailDefault: true }, { ...customer, hasOnecRef: false }]) {
      expect(decideCredit(input({ customer: c }))).toMatchObject({
        code: 'CUSTOMER_NOT_IDENTIFIED',
        creditReason: null,
      });
    }
  });

  it('шаг 1: credit_allowed=false → CREDIT_BLOCKED credit_not_allowed (override не снимает)', () => {
    expect(decideCredit(input({ customer: { ...customer, creditAllowed: false }, override: true }))).toMatchObject({
      code: 'CREDIT_BLOCKED',
      creditReason: 'credit_not_allowed',
    });
  });

  it('шаг 2: просрочка в снимке любого возраста — без обращения к 1С', () => {
    const d = decideCredit(
      input({ snapshot: { balance: Money.of('1'), overdueAmount: Money.of('500.00'), snapshotAt: ago(600) } }),
    );
    expect(d).toMatchObject({ kind: 'refused', code: 'CREDIT_BLOCKED', creditReason: 'overdue', step: 2 });
  });

  // 12: T-PAY-033 (3) (CREDIT_LIMIT_EXCEEDED раньше проверки возраста)
  it('шаг 2: лимит превышен / не задан → CREDIT_LIMIT_EXCEEDED', () => {
    expect(decideCredit(input({ total: Money.of('80000.01') }))).toMatchObject({
      code: 'CREDIT_LIMIT_EXCEEDED',
      creditReason: 'limit_exceeded',
    });
    expect(decideCredit(input({ total: Money.of('80000.00') })).kind).toBe('allowed');
    expect(decideCredit(input({ openOrdersAmount: Money.of('70000.00') }))).toMatchObject({
      code: 'CREDIT_LIMIT_EXCEEDED',
    });
    expect(decideCredit(input({ customer: { ...customer, creditLimit: null } }))).toMatchObject({
      code: 'CREDIT_LIMIT_EXCEEDED',
      detail: 'Лимит в 1С не задан.',
    });
  });

  // 12: T-PAY-033 (4)–(5) (refresh_required; 1С недоступна → RECEIVABLES_STALE)
  it('шаг 3: снимка нет / неполон / устарел → refresh_required; 1С недоступна или C-2 → RECEIVABLES_STALE', () => {
    for (const snapshot of [
      null,
      { balance: Money.ZERO, overdueAmount: null, snapshotAt: ago(1) },
      { balance: Money.ZERO, overdueAmount: Money.ZERO, snapshotAt: ago(61) },
    ]) {
      expect(decideCredit(input({ snapshot })).kind).toBe('refresh_required');
      expect(decideCredit(input({ snapshot, refresh: 'unavailable' }))).toMatchObject({
        code: 'RECEIVABLES_STALE',
        creditReason: 'stale_snapshot',
        step: 3,
      });
    }
  });

  it('шаг 3 → обновлённый снимок: шаг 2 повторяется по свежему снимку', () => {
    const fresh = { balance: Money.of('99000.00'), overdueAmount: Money.ZERO, snapshotAt: now };
    expect(decideCredit(input({ snapshot: fresh, refresh: 'refreshed' }))).toMatchObject({
      code: 'CREDIT_LIMIT_EXCEEDED',
    });
  });

  it('creditOverride снимает только шаг 2; RECEIVABLES_STALE и шаг 1 — нет', () => {
    const blocked = { balance: Money.of('1'), overdueAmount: Money.of('5.00'), snapshotAt: ago(1) };
    expect(decideCredit(input({ snapshot: blocked, override: true }))).toMatchObject({
      kind: 'allowed',
      overrideUsed: true,
    });
    const staleBlocked = { ...blocked, snapshotAt: ago(120) };
    expect(decideCredit(input({ snapshot: staleBlocked, override: true, refresh: 'unavailable' }))).toMatchObject({
      code: 'RECEIVABLES_STALE',
    });
  });

  it('503 ONEC_UNAVAILABLE для долга никогда не возвращается (property)', () => {
    fc.assert(
      fc.property(
        fc.boolean(),
        fc.boolean(),
        fc.boolean(),
        fc.option(fc.bigInt({ min: 0n, max: 10_000_000n }), { nil: null }),
        fc.integer({ min: 0, max: 600 }),
        fc.constantFrom(undefined, 'refreshed' as const, 'unavailable' as const),
        fc.boolean(),
        (canSell, allowed, hasRef, overdue, ageMin, refresh, override) => {
          const d = decideCredit(
            input({
              canSellOnCredit: canSell,
              customer: { ...customer, creditAllowed: allowed, hasOnecRef: hasRef },
              snapshot: {
                balance: Money.of('100'),
                overdueAmount: overdue === null ? null : Money.fromTyiyn(overdue),
                snapshotAt: ago(ageMin),
              },
              refresh,
              override,
            }),
          );
          if (d.kind === 'refused') {
            expect([
              'FORBIDDEN',
              'CUSTOMER_NOT_IDENTIFIED',
              'CREDIT_BLOCKED',
              'CREDIT_LIMIT_EXCEEDED',
              'RECEIVABLES_STALE',
            ]).toContain(d.code);
            const err = creditRefusalError(d);
            expect(err.code).toBe(d.code);
          }
          if (!canSell) expect(d).toMatchObject({ code: 'FORBIDDEN' });
        },
      ),
      { numRuns: 300 },
    );
  });
});

describe('идемпотентность этапа F (08 §2.7, ядро §22.6)', () => {
  it('ключ начального платежа производный от ключа заказа и не совпадает с ним', () => {
    const k = '7d2b3f4e-1a2b-4c3d-8e9f-0a1b2c3d4e5f';
    expect(initialPaymentIdempotencyKey(k)).toBe(`order:${k}`);
  });

  it('хэш состава не зависит от порядка строк и меняется при изменении суммы/клиента/количества', () => {
    const items = [
      { variantId: 'a', packagingId: null, quantity: '1' },
      { variantId: 'b', packagingId: 'p', quantity: '2' },
    ];
    const h = orderCompositionHash({ customerId: 'c', paymentMethod: 'cash', total: '10.00', items });
    expect(
      orderCompositionHash({ customerId: 'c', paymentMethod: 'cash', total: '10.00', items: [...items].reverse() }),
    ).toBe(h);
    expect(orderCompositionHash({ customerId: 'c', paymentMethod: 'cash', total: '10.01', items })).not.toBe(h);
    expect(orderCompositionHash({ customerId: 'd', paymentMethod: 'cash', total: '10.00', items })).not.toBe(h);
    expect(
      orderCompositionHash({
        customerId: 'c',
        paymentMethod: 'cash',
        total: '10.00',
        items: [items[0], { ...items[1], quantity: '3' }],
      }),
    ).not.toBe(h);
  });

  it('мягкий дубль — тот же состав в пределах 60 с без confirmDuplicate', () => {
    const t = new Date('2026-10-22T10:00:00Z');
    const prev = { compositionHash: 'x', createdAt: t };
    expect(isSoftDuplicate(prev, 'x', new Date(t.getTime() + SOFT_DUPLICATE_WINDOW_MS), false)).toBe(true);
    expect(isSoftDuplicate(prev, 'x', new Date(t.getTime() + SOFT_DUPLICATE_WINDOW_MS + 1), false)).toBe(false);
    expect(isSoftDuplicate(prev, 'x', t, true)).toBe(false);
    expect(isSoftDuplicate(prev, 'y', t, false)).toBe(false);
    expect(isSoftDuplicate(null, 'x', t, false)).toBe(false);
  });
});

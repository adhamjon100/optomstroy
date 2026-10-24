import { describe, expect, it } from 'vitest';
import { CART_STATUS_VALUES, OUTBOX_STATUS_VALUES } from '../../src/common/enums.js';
import { SalesDomainError } from '../../src/sales-domain/domain-error.js';
import {
  assertCartEditable,
  assertCartTransition,
  CART_TRANSITIONS,
  isCartTransitionAllowed,
} from '../../src/sales-domain/cart/cart-status.js';
import {
  assertManualLinkAllowed,
  assertOutboxTransition,
  classifyOnecResult,
  isOutboxTransitionAllowed,
  OUTBOX_TRANSITIONS,
  outboxOutcome,
  type OutboxTrigger,
} from '../../src/sales-domain/outbox/outbox-status.js';
import { outboxBackoffMs } from '../../src/sync/scheduler/outbox-backoff.js';

/** Автомат `onec_outbox` (07 §6.5; ядро §22.1, §23 п. 1) и `cart_status` — исчерпывающе. */
const TRIGGERS: OutboxTrigger[] = [
  'claim',
  'delivered',
  'transient',
  'rejected',
  'dead',
  'confirmed_by_sync',
  'manual_retry',
  'manual_link',
  'aggregate_cancelled',
];

const EXPECTED: Record<string, OutboxTrigger> = {
  'pending>sending': 'claim',
  'pending>sent': 'manual_link',
  'pending>cancelled': 'aggregate_cancelled',
  'sending>sent': 'delivered',
  'sending>pending': 'transient',
  'sending>failed': 'rejected',
  'sending>dead': 'dead',
  'sent>confirmed': 'confirmed_by_sync',
  'failed>pending': 'manual_retry',
  'failed>sent': 'manual_link',
  'failed>cancelled': 'aggregate_cancelled',
  'dead>pending': 'manual_retry',
  'dead>sent': 'manual_link',
  'dead>cancelled': 'aggregate_cancelled',
};

const MIN = 60_000;
const cfg = {
  backoffMs: [1, 2, 5, 15, 60].map((m) => m * MIN),
  backoffTailMs: 60 * MIN,
  maxAttempts: 20,
  maxAgeMs: 24 * 60 * MIN,
};

describe('onec_outbox — таблица 07 §6.5 (исчерпывающе)', () => {
  it('таблица кода совпадает с ожидаемой', () => {
    expect(Object.fromEntries(OUTBOX_TRANSITIONS.map((t) => [`${t.from}>${t.to}`, t.triggers.join('|')]))).toEqual(
      EXPECTED,
    );
  });

  it(`все ${OUTBOX_STATUS_VALUES.length ** 2 * TRIGGERS.length} комбинаций`, () => {
    for (const from of OUTBOX_STATUS_VALUES)
      for (const to of OUTBOX_STATUS_VALUES)
        for (const t of TRIGGERS) {
          const ok = EXPECTED[`${from}>${to}`] === t;
          expect(isOutboxTransitionAllowed(from, to, t), `${from}→${to} (${t})`).toBe(ok);
          if (!ok) {
            try {
              assertOutboxTransition(from, to, t);
              expect.unreachable();
            } catch (e) {
              expect((e as SalesDomainError).code).toBe('ORDER_STATE_INVALID');
              expect((e as SalesDomainError).extensions.resource).toBe('outbox_item');
            }
          }
        }
  });

  it('запреты DATA-208: sending → cancelled, pending → confirmed, из confirmed/cancelled — никуда', () => {
    expect(isOutboxTransitionAllowed('sending', 'cancelled')).toBe(false);
    expect(isOutboxTransitionAllowed('pending', 'confirmed')).toBe(false);
    for (const to of OUTBOX_STATUS_VALUES) {
      expect(isOutboxTransitionAllowed('confirmed', to)).toBe(false);
      expect(isOutboxTransitionAllowed('cancelled', to)).toBe(false);
    }
  });

  it('ручная привязка onec-link: pending|failed|dead → sent; sending/sent/cancelled/confirmed — отказ (ORD-034)', () => {
    for (const s of ['pending', 'failed', 'dead'] as const) expect(() => assertManualLinkAllowed(s)).not.toThrow();
    for (const s of ['sending', 'sent', 'cancelled', 'confirmed'] as const)
      expect(() => assertManualLinkAllowed(s)).toThrow();
  });
});

describe('исход доставки — та же политика, что диспетчер outbox.dispatch', () => {
  // 12: T-SYNC-034 (задержки 1, 2, 5, 15, 60 мин, далее 60)
  it('backoff 1, 2, 5, 15, 60 мин, далее каждые 60 мин (переиспользует outbox-backoff.ts)', () => {
    const delays = [1, 2, 3, 4, 5, 6, 7, 19].map((a) => outboxOutcome('transient', a, 0, cfg));
    expect(delays.map((d) => (d.to === 'pending' ? d.retryInMs / MIN : d.to))).toEqual([1, 2, 5, 15, 60, 60, 60, 60]);
    for (let a = 1; a < 20; a++) {
      const o = outboxOutcome('transient', a, 0, cfg);
      expect(o).toEqual({ to: 'pending', retryInMs: outboxBackoffMs(a, cfg) });
    }
  });

  // 12: T-SYNC-034 (dead по попыткам / возрасту; 401/403 — сразу)
  it('dead: attempts ≥ OUTBOX_MAX_ATTEMPTS (20) или возраст > 24 ч; 401/403 — сразу', () => {
    expect(outboxOutcome('transient', 20, 0, cfg)).toEqual({ to: 'dead', reason: 'max_attempts' });
    expect(outboxOutcome('transient', 3, 24 * 60 * MIN + 1, cfg)).toEqual({ to: 'dead', reason: 'max_age' });
    expect(outboxOutcome('transient', 3, 24 * 60 * MIN, cfg).to).toBe('pending');
    expect(outboxOutcome('fatal', 1, 0, cfg)).toEqual({ to: 'dead', reason: 'fatal' });
  });

  it('sent / failed (ONEC_REJECTED); таймаут никогда не даёт sent', () => {
    expect(outboxOutcome('sent', 1, 0, cfg)).toEqual({ to: 'sent' });
    expect(outboxOutcome('rejected', 1, 0, cfg)).toEqual({ to: 'failed', errorCode: 'ONEC_REJECTED' });
    for (let a = 1; a <= 25; a++) expect(outboxOutcome('transient', a, 0, cfg).to).not.toBe('sent');
  });

  it('каждый исход — допустимый переход из sending', () => {
    const trig: Record<string, OutboxTrigger> = {
      sent: 'delivered',
      failed: 'rejected',
      pending: 'transient',
      dead: 'dead',
    };
    for (const k of ['sent', 'transient', 'rejected', 'fatal'] as const)
      for (const a of [1, 5, 20]) {
        const o = outboxOutcome(k, a, 0, cfg);
        expect(isOutboxTransitionAllowed('sending', o.to, trig[o.to])).toBe(true);
      }
  });

  it('классификация ответов 1С (05 §6.5, ONEC-055): POS_E_DUPLICATE → sent, 503/423/0 → transient, 401/403 → fatal', () => {
    expect(classifyOnecResult({ ok: true })).toBe('sent');
    expect(classifyOnecResult({ ok: false, status: 409, code: 'POS_E_DUPLICATE' })).toBe('sent');
    expect(classifyOnecResult({ ok: false, status: 503, code: 'POS_E_MAINTENANCE' })).toBe('transient');
    expect(classifyOnecResult({ ok: false, status: 423, code: 'POS_E_LOCKED' })).toBe('transient');
    expect(classifyOnecResult({ ok: false, status: 0, code: 'TRANSPORT' })).toBe('transient');
    expect(classifyOnecResult({ ok: false, status: 500, code: 'POS_E_INTERNAL' })).toBe('transient');
    expect(classifyOnecResult({ ok: false, status: 401, code: 'POS_E_UNAUTHORIZED' })).toBe('fatal');
    expect(classifyOnecResult({ ok: false, status: 403, code: 'POS_E_FORBIDDEN' })).toBe('fatal');
    for (const code of ['POS_E_VALIDATION', 'POS_E_STOCK', 'POS_E_PRICE', 'POS_E_CREDIT', 'POS_E_STATE'])
      expect(classifyOnecResult({ ok: false, status: code === 'POS_E_VALIDATION' ? 422 : 409, code })).toBe('rejected');
  });
});

describe('cart_status (07 §6.5)', () => {
  it('исчерпывающе: 5 допустимых переходов', () => {
    const allowed = new Set(CART_TRANSITIONS.map((t) => `${t.from}>${t.to}`));
    expect([...allowed].sort()).toEqual([
      'active>cleared',
      'active>converted',
      'active>parked',
      'parked>active',
      'parked>cleared',
    ]);
    for (const from of CART_STATUS_VALUES)
      for (const to of CART_STATUS_VALUES) expect(isCartTransitionAllowed(from, to)).toBe(allowed.has(`${from}>${to}`));
  });
  it('converted/cleared — терминальные; правка — только active', () => {
    expect(() => assertCartTransition('converted', 'active', 'resume')).toThrow(/ORDER_STATE_INVALID/);
    expect(() => assertCartTransition('active', 'parked', 'park')).not.toThrow();
    expect(() => assertCartEditable('active')).not.toThrow();
    for (const s of ['parked', 'converted', 'cleared'] as const) {
      try {
        assertCartEditable(s);
        expect.unreachable();
      } catch (e) {
        expect((e as SalesDomainError).extensions).toMatchObject({ resource: 'cart', reason: `cart_${s}` });
      }
    }
  });
});

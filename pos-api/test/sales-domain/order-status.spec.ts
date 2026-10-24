import { describe, expect, it } from 'vitest';
import {
  ORDER_STATUS_VALUES,
  type OrderStatus,
  STATUS_CHANGE_SOURCE_VALUES,
  type StatusChangeSource,
} from '../../src/common/enums.js';
import { SalesDomainError } from '../../src/sales-domain/domain-error.js';
import {
  assertOrderAcceptsPayment,
  assertOrderTransition,
  decideOrderCancel,
  isOrderTransitionAllowed,
  ORDER_PAYABLE_STATUSES,
  ORDER_TRANSITIONS,
  type OrderCancelInput,
  type OrderFacts,
  planOrderStatusChange,
  projectOrderStatus,
} from '../../src/sales-domain/order/order-status.js';

/**
 * Автомат заказа D-20: проекция P1…P10 (10 §2.2), таблица переходов 07 §6.3 — исчерпывающе (все 11 × 11 пар ×
 * 4 источника), событие `approved` (P10), приём оплаты (ядро §22.5), отмена (ORD-050…ORD-053).
 */
const base: OrderFacts = {
  creating: false,
  cancelConfirmed: false,
  rejected: false,
  hasOnecRef: false,
  onecStatus: null,
  hasShipment: false,
  hasReturn: false,
  paymentMethod: 'cash',
  paidAtSet: false,
  hasReceivedMoney: false,
};
const f = (p: Partial<OrderFacts>): OrderFacts => ({ ...base, ...p });

/** Ожидаемая таблица (07 §6.3): ключ `from>to` → допустимые источники. */
const EXPECTED: Record<string, StatusChangeSource[]> = {
  'draft>submitting': ['pos_system'],
  'submitting>awaiting_payment': ['onec_response', 'pos_user'],
  'submitting>pending_approval': ['onec_response', 'pos_user'],
  'submitting>approved': ['onec_response', 'pos_user'],
  'submitting>submit_failed': ['onec_response'],
  'submitting>cancelled': ['pos_user', 'onec_response'],
  'submit_failed>submitting': ['pos_user'],
  'awaiting_payment>pending_approval': ['pos_system'],
  'awaiting_payment>approved': ['pos_system', 'onec_sync', 'onec_response'],
  'awaiting_payment>awaiting_shipment': ['pos_system', 'onec_sync'],
  'awaiting_payment>cancelled': ['onec_response', 'onec_sync'],
  'pending_approval>approved': ['onec_sync', 'onec_response'],
  'pending_approval>cancelled': ['onec_response', 'onec_sync'],
  'approved>awaiting_shipment': ['onec_sync', 'onec_response', 'pos_system', 'pos_user'],
  'awaiting_shipment>pending_approval': ['onec_sync'],
  'awaiting_shipment>shipped': ['onec_sync'],
  'awaiting_shipment>cancelled': ['onec_response', 'onec_sync'],
  'shipped>partially_returned': ['onec_sync'],
  'shipped>closed': ['onec_sync'],
  'partially_returned>closed': ['onec_sync'],
};

describe('order_status — таблица переходов 07 §6.3 (исчерпывающе)', () => {
  it('таблица кода совпадает с ожидаемой (нет лишних и пропущенных переходов)', () => {
    const actual = Object.fromEntries(ORDER_TRANSITIONS.map((t) => [`${t.from}>${t.to}`, [...t.sources].sort()]));
    const expected = Object.fromEntries(Object.entries(EXPECTED).map(([k, v]) => [k, [...v].sort()]));
    expect(actual).toEqual(expected);
  });

  const cases: [OrderStatus, OrderStatus, StatusChangeSource, boolean][] = [];
  for (const from of ORDER_STATUS_VALUES)
    for (const to of ORDER_STATUS_VALUES)
      for (const s of STATUS_CHANGE_SOURCE_VALUES)
        cases.push([from, to, s, EXPECTED[`${from}>${to}`]?.includes(s) ?? false]);

  it(`все ${cases.length} комбинаций (из × в × источник): допустимые проходят, остальные — ORDER_STATE_INVALID`, () => {
    let allowed = 0;
    for (const [from, to, s, ok] of cases) {
      expect(isOrderTransitionAllowed(from, to, s), `${from}→${to} (${s})`).toBe(ok);
      if (ok) {
        allowed += 1;
        expect(assertOrderTransition(from, to, s).to).toBe(to);
      } else {
        let err: unknown;
        try {
          assertOrderTransition(from, to, s);
        } catch (e) {
          err = e;
        }
        expect(err, `${from}→${to} (${s})`).toBeInstanceOf(SalesDomainError);
        const de = err as SalesDomainError;
        expect(de.code).toBe('ORDER_STATE_INVALID');
        expect(de.extensions).toMatchObject({ resource: 'order', currentStatus: from });
      }
    }
    expect(allowed).toBe(Object.values(EXPECTED).reduce((a, v) => a + v.length, 0));
  });

  it.each([
    ['closed', 'cancelled'],
    ['cancelled', 'submitting'],
    ['shipped', 'cancelled'],
    ['submit_failed', 'cancelled'],
    ['awaiting_shipment', 'awaiting_payment'],
    ['pending_approval', 'awaiting_payment'],
    ['awaiting_shipment', 'submitting'],
  ] as [OrderStatus, OrderStatus][])('запрещённый переход %s → %s (DATA-201)', (from, to) => {
    for (const s of STATUS_CHANGE_SOURCE_VALUES) expect(isOrderTransitionAllowed(from, to, s)).toBe(false);
  });

  it('из closed/cancelled переходов нет', () => {
    expect(ORDER_TRANSITIONS.filter((t) => t.from === 'closed' || t.from === 'cancelled')).toEqual([]);
  });
});

describe('projectOrderStatus — P1…P10 (каждое правило даёт ровно один статус)', () => {
  it.each([
    ['P1', f({ creating: true, cancelConfirmed: true }), 'draft'],
    ['P2 cancel_confirmed', f({ cancelConfirmed: true, hasOnecRef: true, onecStatus: 'not_approved' }), 'cancelled'],
    ['P2 rejected + деньги', f({ rejected: true, hasReceivedMoney: true }), 'cancelled'],
    ['P2 «Закрыт» без реализации', f({ hasOnecRef: true, onecStatus: 'closed', paidAtSet: true }), 'cancelled'],
    ['P3', f({ rejected: true }), 'submit_failed'],
    ['P4', f({}), 'submitting'],
    ['P4 credit', f({ paymentMethod: 'credit' }), 'submitting'],
    ['P5', f({ hasOnecRef: true, onecStatus: 'closed', hasShipment: true, hasReturn: true }), 'closed'],
    ['P6', f({ hasOnecRef: true, onecStatus: 'to_execute', hasShipment: true, hasReturn: true }), 'partially_returned'],
    ['P7', f({ hasOnecRef: true, onecStatus: 'to_execute', hasShipment: true }), 'shipped'],
    ['P8 cash', f({ hasOnecRef: true, onecStatus: 'not_approved' }), 'awaiting_payment'],
    [
      'P8 qr, «К выполнению»',
      f({ hasOnecRef: true, onecStatus: 'to_execute', paymentMethod: 'qr_bakai' }),
      'awaiting_payment',
    ],
    ['P9 credit', f({ hasOnecRef: true, onecStatus: 'not_approved', paymentMethod: 'credit' }), 'pending_approval'],
    ['P9 оплачен', f({ hasOnecRef: true, onecStatus: 'not_approved', paidAtSet: true }), 'pending_approval'],
    ['P10', f({ hasOnecRef: true, onecStatus: 'to_execute', paidAtSet: true }), 'awaiting_shipment'],
  ] as [string, OrderFacts, OrderStatus][])('%s → %s', (_name, facts, status) => {
    expect(projectOrderStatus(facts).status).toBe(status);
  });

  it('неизвестный статус 1С у settled-заказа — статус не меняется (10 §2.2 правило 8)', () => {
    expect(projectOrderStatus(f({ hasOnecRef: true, paymentMethod: 'credit' }))).toEqual({
      status: null,
      rule: 'unknown_onec_status',
    });
  });

  it('полнота: для любого набора фактов результат — один статус из enum или «без изменения»', () => {
    const bools = [false, true];
    let n = 0;
    for (const creating of bools)
      for (const cancelConfirmed of bools)
        for (const rejected of bools)
          for (const hasOnecRef of bools)
            for (const onecStatus of [null, 'not_approved', 'to_execute', 'closed'] as const)
              for (const hasShipment of bools)
                for (const hasReturn of bools)
                  for (const paymentMethod of ['cash', 'qr_bakai', 'credit'] as const)
                    for (const paidAtSet of bools)
                      for (const hasReceivedMoney of bools) {
                        const p = projectOrderStatus({
                          creating,
                          cancelConfirmed,
                          rejected,
                          hasOnecRef,
                          onecStatus,
                          hasShipment,
                          hasReturn,
                          paymentMethod,
                          paidAtSet,
                          hasReceivedMoney,
                        });
                        n += 1;
                        if (p.status !== null) expect(ORDER_STATUS_VALUES).toContain(p.status);
                        else expect(hasOnecRef && onecStatus === null).toBe(true);
                      }
    expect(n).toBe(2 * 2 * 2 * 2 * 4 * 2 * 2 * 3 * 2 * 2);
  });
});

describe('planOrderStatusChange — момент проекции (ядро §23 п. 2) и событие approved (P10)', () => {
  it('outbox create → sent: неоплаченный cash → awaiting_payment; credit → pending_approval', () => {
    expect(
      planOrderStatusChange('submitting', f({ hasOnecRef: true, onecStatus: 'not_approved' }), 'onec_response'),
    ).toMatchObject({ to: 'awaiting_payment', rule: 'P8', history: [{ from: 'submitting', to: 'awaiting_payment' }] });
    expect(
      planOrderStatusChange(
        'submitting',
        f({ hasOnecRef: true, onecStatus: 'not_approved', paymentMethod: 'credit' }),
        'onec_response',
      ),
    ).toMatchObject({ to: 'pending_approval', rule: 'P9' });
  });

  it('qr_bakai, оплаченный до ответа 1С: submitting → pending_approval без awaiting_payment', () => {
    const c = planOrderStatusChange(
      'submitting',
      f({ hasOnecRef: true, onecStatus: 'not_approved', paymentMethod: 'qr_bakai', paidAtSet: true }),
      'onec_response',
    );
    expect(c?.history).toEqual([{ from: 'submitting', to: 'pending_approval', source: 'onec_response' }]);
  });

  it('«К выполнению» для settled: две записи истории (approved, awaiting_shipment)', () => {
    const c = planOrderStatusChange(
      'pending_approval',
      f({ hasOnecRef: true, onecStatus: 'to_execute', paymentMethod: 'credit' }),
      'onec_sync',
    );
    expect(c).toEqual({
      to: 'awaiting_shipment',
      rule: 'P10',
      history: [
        { from: 'pending_approval', to: 'approved', source: 'onec_sync' },
        { from: 'approved', to: 'awaiting_shipment', source: 'onec_sync' },
      ],
    });
  });

  it('оплата после согласования: awaiting_payment → approved → awaiting_shipment (pos_system)', () => {
    const c = planOrderStatusChange(
      'awaiting_payment',
      f({ hasOnecRef: true, onecStatus: 'to_execute', paidAtSet: true }),
      'pos_system',
    );
    expect(c?.history.map((h) => h.to)).toEqual(['approved', 'awaiting_shipment']);
  });

  it('оплата до согласования: awaiting_payment → pending_approval (P9)', () => {
    const c = planOrderStatusChange(
      'awaiting_payment',
      f({ hasOnecRef: true, onecStatus: 'not_approved', paidAtSet: true }),
      'pos_system',
    );
    expect(c?.history).toEqual([{ from: 'awaiting_payment', to: 'pending_approval', source: 'pos_system' }]);
  });

  it('тот же статус и confirmed (повторная синхронизация) — записей нет', () => {
    expect(
      planOrderStatusChange('awaiting_payment', f({ hasOnecRef: true, onecStatus: 'not_approved' }), 'onec_sync'),
    ).toBeNull();
  });

  it('откат «назад» awaiting_shipment → pending_approval — только onec_sync', () => {
    const facts = f({ hasOnecRef: true, onecStatus: 'not_approved', paidAtSet: true });
    expect(planOrderStatusChange('awaiting_shipment', facts, 'onec_sync')?.to).toBe('pending_approval');
    expect(() => planOrderStatusChange('awaiting_shipment', facts, 'pos_system')).toThrow(SalesDomainError);
  });

  it('факт settled монотонен: awaiting_shipment не возвращается в awaiting_payment', () => {
    expect(() =>
      planOrderStatusChange('awaiting_shipment', f({ hasOnecRef: true, onecStatus: 'not_approved' }), 'onec_sync'),
    ).toThrow(/ORDER_STATE_INVALID/);
  });

  it('отклонение 1С: без денег → submit_failed; с деньгами → cancelled', () => {
    expect(planOrderStatusChange('submitting', f({ rejected: true }), 'onec_response')?.to).toBe('submit_failed');
    expect(
      planOrderStatusChange('submitting', f({ rejected: true, hasReceivedMoney: true }), 'onec_response')?.to,
    ).toBe('cancelled');
  });
});

describe('приём оплаты по заказу (ядро §22.5)', () => {
  it('допустимые статусы — ровно submitting, pending_approval, approved, awaiting_payment', () => {
    expect([...ORDER_PAYABLE_STATUSES].sort()).toEqual([
      'approved',
      'awaiting_payment',
      'pending_approval',
      'submitting',
    ]);
    for (const s of ORDER_STATUS_VALUES) {
      if (ORDER_PAYABLE_STATUSES.has(s)) expect(() => assertOrderAcceptsPayment(s, false)).not.toThrow();
      else expect(() => assertOrderAcceptsPayment(s, false)).toThrow(/ORDER_STATE_INVALID/);
    }
  });

  it('полностью оплаченный — already_paid', () => {
    try {
      assertOrderAcceptsPayment('awaiting_payment', true);
      expect.unreachable();
    } catch (e) {
      expect((e as SalesDomainError).extensions.reason).toBe('already_paid');
    }
  });
});

describe('decideOrderCancel (ORD-050…ORD-053, 07 §6.3, ядро §22.9)', () => {
  const ci = (p: Partial<OrderCancelInput>): OrderCancelInput => ({
    status: 'submitting',
    hasOnecRef: false,
    createOutbox: { status: 'pending', attempts: 0 },
    hasReceivedPayments: false,
    isOwn: true,
    cancelAlreadyRequested: false,
    canCancelOwn: true,
    canRequestAny: false,
    ...p,
  });

  it('свой submitting, outbox pending, attempts=0 → немедленная отмена без step-up, 1С не вызывается', () => {
    expect(decideOrderCancel(ci({}))).toEqual({
      kind: 'cancel_now',
      outbox: 'cancel_create',
      via: 'own',
      requiresStepUp: false,
    });
  });

  it('attempts>0 → отмена + защитная задача cancel', () => {
    expect(decideOrderCancel(ci({ createOutbox: { status: 'pending', attempts: 2 } })).outbox).toBe(
      'cancel_create_and_enqueue_cancel',
    );
    expect(decideOrderCancel(ci({ createOutbox: { status: 'dead', attempts: 20 } })).kind).toBe('cancel_now');
  });

  it('outbox sending → запрос отмены следом за create', () => {
    expect(decideOrderCancel(ci({ createOutbox: { status: 'sending', attempts: 1 } }))).toMatchObject({
      kind: 'request',
      outbox: 'enqueue_cancel_after_create',
    });
  });

  it('создан в 1С (awaiting_payment) → запрос cancel в outbox', () => {
    expect(
      decideOrderCancel(
        ci({ status: 'awaiting_payment', hasOnecRef: true, createOutbox: { status: 'sent', attempts: 1 } }),
      ),
    ).toMatchObject({ kind: 'request', outbox: 'enqueue_cancel', via: 'own', requiresStepUp: false });
  });

  it('чужой заказ: seller/customer → FORBIDDEN; cashier (request.any) → step-up', () => {
    expect(() => decideOrderCancel(ci({ isOwn: false }))).toThrow(/FORBIDDEN/);
    expect(decideOrderCancel(ci({ isOwn: false, canRequestAny: true }))).toMatchObject({
      via: 'any',
      requiresStepUp: true,
    });
  });

  it('с полученными платежами — только запрос any со step-up и refundIntent', () => {
    expect(() => decideOrderCancel(ci({ hasReceivedPayments: true }))).toThrow(/FORBIDDEN/);
    expect(decideOrderCancel(ci({ hasReceivedPayments: true, canRequestAny: true }))).toMatchObject({
      kind: 'request',
      via: 'any',
      requiresStepUp: true,
      refundIntentRequired: true,
    });
  });

  it('согласованный (awaiting_shipment) — только any', () => {
    expect(() => decideOrderCancel(ci({ status: 'awaiting_shipment', hasOnecRef: true }))).toThrow(/FORBIDDEN/);
    expect(decideOrderCancel(ci({ status: 'awaiting_shipment', hasOnecRef: true, canRequestAny: true })).kind).toBe(
      'request',
    );
  });

  it.each(['submit_failed', 'shipped', 'partially_returned', 'closed', 'cancelled', 'draft'] as OrderStatus[])(
    '%s — ORDER_STATE_INVALID (ORD-052)',
    (status) => {
      expect(() => decideOrderCancel(ci({ status, canRequestAny: true }))).toThrow(/ORDER_STATE_INVALID/);
    },
  );

  it('повторный запрос отмены — cancel_already_requested', () => {
    try {
      decideOrderCancel(ci({ status: 'pending_approval', hasOnecRef: true, cancelAlreadyRequested: true }));
      expect.unreachable();
    } catch (e) {
      expect((e as SalesDomainError).extensions.reason).toBe('cancel_already_requested');
    }
  });
});

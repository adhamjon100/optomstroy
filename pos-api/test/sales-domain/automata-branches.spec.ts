import { describe, expect, it } from 'vitest';
import { assertCartTransition } from '../../src/sales-domain/cart/cart-status.js';
import {
  decideOrderCancel,
  type OrderCancelInput,
  type OrderFacts,
  planOrderStatusChange,
} from '../../src/sales-domain/order/order-status.js';
import { classifyOnecResult } from '../../src/sales-domain/outbox/outbox-status.js';

/**
 * Ветви автоматов D-20/D-21 и корзины/outbox, не задетые таблицами переходов (13 RM-F-009 «автоматы — 100 % веток»;
 * ревью F-trace-2, FIX-F-23) — чистые функции, **тестовые данные**.
 */
describe('автоматы: оставшиеся ветви (RM-F-009)', () => {
  it('корзина: недопустимый триггер из active/parked → reason transition_not_allowed; из terminal → cart_<status>', () => {
    expect(() => assertCartTransition('active', 'converted', 'park')).toThrow(
      expect.objectContaining({ extensions: expect.objectContaining({ reason: 'transition_not_allowed' }) }),
    );
    expect(() => assertCartTransition('parked', 'active', 'clear')).toThrow(
      expect.objectContaining({ extensions: expect.objectContaining({ reason: 'transition_not_allowed' }) }),
    );
    expect(() => assertCartTransition('cleared', 'active', 'resume')).toThrow(
      expect.objectContaining({ extensions: expect.objectContaining({ reason: 'cart_cleared' }) }),
    );
  });

  it('заказ: P10 из approved → только approved → awaiting_shipment (без повторного события approved)', () => {
    const facts: OrderFacts = {
      creating: false,
      cancelConfirmed: false,
      rejected: false,
      hasOnecRef: true,
      onecStatus: 'to_execute',
      hasShipment: false,
      hasReturn: false,
      paymentMethod: 'credit',
      paidAtSet: false,
      hasReceivedMoney: false,
    };
    expect(planOrderStatusChange('approved', facts, 'onec_sync')).toEqual({
      to: 'awaiting_shipment',
      rule: 'P10',
      history: [{ from: 'approved', to: 'awaiting_shipment', source: 'onec_sync' }],
    });
  });

  it('отмена submitting без onec_ref по состоянию задачи create: failed / cancelled → 409; sent / confirmed → запрос в 1С', () => {
    const input = (status: NonNullable<OrderCancelInput['createOutbox']>['status']): OrderCancelInput => ({
      status: 'submitting',
      hasOnecRef: false,
      createOutbox: { status, attempts: 1 },
      hasReceivedPayments: false,
      isOwn: true,
      cancelAlreadyRequested: false,
      canCancelOwn: true,
      canRequestAny: false,
    });
    expect(() => decideOrderCancel(input('failed'))).toThrow(
      expect.objectContaining({
        code: 'ORDER_STATE_INVALID',
        extensions: expect.objectContaining({ reason: 'not_cancellable' }),
      }),
    );
    expect(() => decideOrderCancel(input('cancelled'))).toThrow(
      expect.objectContaining({ code: 'ORDER_STATE_INVALID', detail: 'Задача 1С уже отозвана.' }),
    );
    for (const st of ['sent', 'confirmed'] as const) {
      expect(decideOrderCancel(input(st))).toEqual({
        kind: 'request',
        outbox: 'enqueue_cancel',
        via: 'own',
        requiresStepUp: false,
        refundIntentRequired: false,
      });
    }
  });

  it('outbox: POS_E_LOCKED/… с 4xx → transient; прочие 4xx без кода отказа → rejected; 401/403 → fatal', () => {
    for (const code of ['POS_E_LOCKED', 'POS_E_INTERNAL', 'POS_E_MAINTENANCE', 'POS_E_QR_UNAVAILABLE']) {
      expect(classifyOnecResult({ ok: false, status: 409, code })).toBe('transient');
    }
    expect(classifyOnecResult({ ok: false, status: 404, code: 'POS_E_NOT_FOUND' })).toBe('rejected');
    expect(classifyOnecResult({ ok: false, status: 400, code: 'POS_E_BAD_REQUEST' })).toBe('rejected');
    expect(classifyOnecResult({ ok: false, status: 422, code: 'POS_E_STOCK' })).toBe('rejected');
    expect(classifyOnecResult({ ok: false, status: 403, code: 'POS_E_FORBIDDEN' })).toBe('fatal');
  });
});

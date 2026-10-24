import { describe, expect, it } from 'vitest';
import { RETURN_REQUEST_STATUS_VALUES, type ReturnRequestStatus } from '../../src/common/enums.js';
import {
  canReturnTransition,
  decideAccept,
  decideReject,
  onecProjectionPath,
} from '../../src/returns/domain/return-status.js';
import { parseOnecReturnState } from '../../src/returns/onec/returns-onec.service.js';
import { qty3, remainingQty } from '../../src/returns/returns.presenter.js';
import { bishkekIso } from '../../src/returns/return-onec-payload.js';
import { parseCreateReturnBody } from '../../src/returns/returns.request.js';

/** Автомат заявки на возврат — ядро §22.11, 10 RET §2.4 (чистые функции, без БД). */
describe('return-status: автомат ядра §22.11', () => {
  const allowed: [ReturnRequestStatus, ReturnRequestStatus][] = [
    ['draft', 'submitted'],
    ['submitted', 'accepted'],
    ['submitted', 'rejected'],
    ['accepted', 'rejected'],
    ['accepted', 'completed'],
  ];

  it('разрешены ровно 5 переходов; draft → rejected/accepted, выход из rejected/completed — нет', () => {
    for (const from of RETURN_REQUEST_STATUS_VALUES) {
      for (const to of RETURN_REQUEST_STATUS_VALUES) {
        const expected = allowed.some(([f, t]) => f === from && t === to);
        expect(canReturnTransition(from, to), `${from} → ${to}`).toBe(expected);
      }
    }
  });

  it('reject: передача в 1С определяется outbox/ссылкой; accepted из 1С — только в 1С', () => {
    const base = { onecRef: null, acceptedInPos: false } as const;
    expect(decideReject({ ...base, status: 'submitted', outboxStatus: null })).toEqual({
      kind: 'ok',
      cancelOutbox: false,
    });
    for (const s of ['pending', 'failed', 'dead'] as const) {
      expect(decideReject({ ...base, status: 'submitted', outboxStatus: s })).toEqual({
        kind: 'ok',
        cancelOutbox: true,
      });
    }
    for (const s of ['sending', 'sent', 'confirmed'] as const) {
      expect(decideReject({ ...base, status: 'submitted', outboxStatus: s }).kind).toBe('already_in_onec');
    }
    expect(decideReject({ ...base, status: 'submitted', outboxStatus: 'cancelled' })).toEqual({
      kind: 'ok',
      cancelOutbox: false,
    });
    expect(decideReject({ ...base, status: 'accepted', outboxStatus: null }).kind).toBe('already_in_onec');
    expect(decideReject({ ...base, status: 'accepted', outboxStatus: null, acceptedInPos: true }).kind).toBe('ok');
    expect(decideReject({ ...base, status: 'submitted', outboxStatus: null, onecRef: 'x' }).kind).toBe(
      'already_in_onec',
    );
    for (const s of ['draft', 'rejected', 'completed'] as const) {
      expect(decideReject({ ...base, status: s, outboxStatus: null }).kind).toBe('invalid_transition');
    }
  });

  it('accept: только submitted и только при выключенном outbox', () => {
    expect(decideAccept({ status: 'submitted', outboxEnabled: false }).kind).toBe('ok');
    expect(decideAccept({ status: 'submitted', outboxEnabled: true }).kind).toBe('already_in_onec');
    for (const s of ['draft', 'accepted', 'rejected', 'completed'] as const) {
      expect(decideAccept({ status: s, outboxEnabled: false }).kind).toBe('invalid_transition');
    }
  });

  it('проекция статуса 1С: вперёд по автомату; submitted→completed через accepted; назад — нет', () => {
    expect(onecProjectionPath('submitted', 'accepted')).toEqual(['accepted']);
    expect(onecProjectionPath('submitted', 'completed')).toEqual(['accepted', 'completed']);
    expect(onecProjectionPath('accepted', 'rejected')).toEqual(['rejected']);
    expect(onecProjectionPath('completed', 'accepted')).toEqual([]);
    expect(onecProjectionPath('rejected', 'completed')).toEqual([]);
    expect(onecProjectionPath('submitted', 'submitted')).toEqual([]);
    expect(onecProjectionPath('draft', 'accepted')).toEqual([]);
  });

  it('разбор ответа 1С и форматы: статус вне перечня → null; количество 3 знака; +06:00', () => {
    expect(
      parseOnecReturnState({ ref: 'r', number: 'N', status: 'accepted', onecStatus: 'Согласована' }),
    ).toMatchObject({
      status: 'accepted',
      onecStatus: 'Согласована',
    });
    expect(parseOnecReturnState({ status: 'КВыполнению' })).toBeNull();
    expect(qty3('2')).toBe('2.000');
    expect(qty3('1.5')).toBe('1.500');
    expect(remainingQty('10.000', '3.000', '8.000')).toBe('0.000');
    expect(remainingQty('10.000', '1.500', '2.000')).toBe('6.500');
    expect(bishkekIso(new Date('2026-10-22T04:15:00Z'))).toBe('2026-10-22T10:15:00+06:00');
  });

  it('тело POST /returns: причина обязательна, excess и суммы — 400', () => {
    const ok = {
      orderId: '0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a8b',
      reasonCode: 'defect',
      items: [{ orderLineNo: 1, quantity: { value: '1', unitId: '0192f5a0-7c2e-7d3b-9a1f-3c4d5e6f7a8c' } }],
    };
    expect(parseCreateReturnBody(ok)).toMatchObject({ reasonCode: 'defect', reasonComment: null, refundKind: null });
    expect(() => parseCreateReturnBody({ ...ok, reasonCode: undefined })).toThrow();
    expect(() => parseCreateReturnBody({ ...ok, reasonCode: 'excess' })).toThrow();
    expect(() => parseCreateReturnBody({ ...ok, total: '1.00' })).toThrow();
  });
});

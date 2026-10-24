import { describe, expect, it } from 'vitest';
import { PAYMENT_STATUS_VALUES, type PaymentStatus } from '../../src/common/enums.js';
import { SalesDomainError } from '../../src/sales-domain/domain-error.js';
import {
  assertPaymentTransition,
  assertUserVoidable,
  decideProviderReport,
  initialPaymentStatus,
  isPaymentTransitionAllowed,
  PAYMENT_OPEN_STATUSES,
  PAYMENT_TERMINAL_STATUSES,
  PAYMENT_TRANSITIONS,
  type PaymentActor,
  planConfirmManual,
  planNewPayment,
  planQrReissue,
} from '../../src/sales-domain/payment/payment-status.js';

/** Автомат `payment_status` (07 §6.4; ядро §22.2, §23 пп. 3–4, §24.4) — исчерпывающе. */
const ACTORS: PaymentActor[] = ['system', 'provider', 'timer', 'user', 'user_step_up', 'onec_sync'];

const EXPECTED: Record<string, PaymentActor[]> = {
  'initiated>cash_pending': ['system'],
  'initiated>qr_pending': ['system'],
  'initiated>credit': ['system'],
  'cash_pending>received': ['user'],
  'cash_pending>voided': ['system', 'user_step_up'],
  'qr_pending>qr_shown': ['system', 'user'],
  'qr_pending>voided': ['system', 'user_step_up'],
  'qr_shown>received': ['provider'],
  'qr_shown>qr_expired': ['timer'],
  'qr_shown>manual_confirm': ['provider', 'user_step_up'],
  'qr_shown>voided': ['system', 'user_step_up'],
  'qr_expired>qr_shown': ['system', 'user'],
  'qr_expired>manual_confirm': ['provider'],
  'qr_expired>voided': ['system', 'user_step_up'],
  'manual_confirm>received': ['user_step_up'],
  'manual_confirm>voided': ['user_step_up', 'system'],
  'received>refunded': ['onec_sync'],
};

describe('payment_status — таблица 07 §6.4 (исчерпывающе)', () => {
  it('таблица кода совпадает с ожидаемой', () => {
    const actual = Object.fromEntries(PAYMENT_TRANSITIONS.map((t) => [`${t.from}>${t.to}`, [...t.actors].sort()]));
    expect(actual).toEqual(Object.fromEntries(Object.entries(EXPECTED).map(([k, v]) => [k, [...v].sort()])));
  });

  it(`все ${PAYMENT_STATUS_VALUES.length ** 2 * ACTORS.length} комбинаций: допустимые проходят, остальные — PAYMENT_STATE_INVALID`, () => {
    for (const from of PAYMENT_STATUS_VALUES)
      for (const to of PAYMENT_STATUS_VALUES)
        for (const a of ACTORS) {
          const ok = EXPECTED[`${from}>${to}`]?.includes(a) ?? false;
          expect(isPaymentTransitionAllowed(from, to, a), `${from}→${to} (${a})`).toBe(ok);
          if (ok) continue;
          try {
            assertPaymentTransition(from, to, a);
            expect.unreachable(`${from}→${to} (${a})`);
          } catch (e) {
            expect(e).toBeInstanceOf(SalesDomainError);
            expect((e as SalesDomainError).code).toBe('PAYMENT_STATE_INVALID');
            expect((e as SalesDomainError).extensions.currentStatus).toBe(from);
          }
        }
  });

  it('credit — конечный; received → voided запрещён; qr_expired → received напрямую нет', () => {
    for (const to of PAYMENT_STATUS_VALUES) expect(isPaymentTransitionAllowed('credit', to)).toBe(false);
    expect(isPaymentTransitionAllowed('received', 'voided')).toBe(false);
    expect(isPaymentTransitionAllowed('qr_expired', 'received')).toBe(false);
    expect(() => assertPaymentTransition('received', 'voided', 'user_step_up')).toThrow(
      expect.objectContaining({ extensions: expect.objectContaining({ reason: 'received_void_forbidden' }) }),
    );
    expect(() => assertPaymentTransition('credit', 'voided', 'system')).toThrow(
      expect.objectContaining({ extensions: expect.objectContaining({ reason: 'credit_terminal' }) }),
    );
  });

  it('создание сразу в manual_confirm недопустимо (из initiated — только по способу)', () => {
    expect(isPaymentTransitionAllowed('initiated', 'manual_confirm')).toBe(false);
    expect(isPaymentTransitionAllowed('initiated', 'qr_shown')).toBe(false);
  });

  it('конечные и открытые статусы', () => {
    expect([...PAYMENT_TERMINAL_STATUSES].sort()).toEqual(['credit', 'refunded', 'voided']);
    for (const s of PAYMENT_TERMINAL_STATUSES) expect(PAYMENT_TRANSITIONS.some((t) => t.from === s)).toBe(false);
    expect([...PAYMENT_OPEN_STATUSES].sort()).toEqual(
      ['cash_pending', 'initiated', 'manual_confirm', 'qr_expired', 'qr_pending', 'qr_shown'].sort(),
    );
  });

  it('initialPaymentStatus по способу', () => {
    expect(initialPaymentStatus('cash')).toBe('cash_pending');
    expect(initialPaymentStatus('qr_bakai')).toBe('qr_pending');
    expect(initialPaymentStatus('credit')).toBe('credit');
  });
});

describe('ручные действия кассира', () => {
  it('void: только до получения денег', () => {
    for (const s of PAYMENT_STATUS_VALUES) {
      const ok = ['cash_pending', 'qr_pending', 'qr_shown', 'qr_expired', 'manual_confirm'].includes(s);
      if (ok) expect(() => assertUserVoidable(s)).not.toThrow();
      else expect(() => assertUserVoidable(s)).toThrow(/PAYMENT_STATE_INVALID/);
    }
  });

  it('confirm-manual: из qr_shown — две записи (no_webhook); из manual_confirm — одна; из qr_expired — перевыпуск', () => {
    expect(planConfirmManual('qr_shown')).toEqual({
      steps: [
        { from: 'qr_shown', to: 'manual_confirm' },
        { from: 'manual_confirm', to: 'received' },
      ],
      reviewReason: 'no_webhook',
    });
    expect(planConfirmManual('manual_confirm').steps).toHaveLength(1);
    expect(() => planConfirmManual('qr_expired')).toThrow(
      expect.objectContaining({ extensions: expect.objectContaining({ reason: 'qr_expired_reissue_required' }) }),
    );
    for (const s of [
      'initiated',
      'cash_pending',
      'qr_pending',
      'credit',
      'received',
      'voided',
      'refunded',
    ] as PaymentStatus[])
      expect(() => planConfirmManual(s)).toThrow(/PAYMENT_STATE_INVALID/);
    // каждый шаг плана — допустимый переход для user_step_up
    for (const st of planConfirmManual('qr_shown').steps) {
      expect(isPaymentTransitionAllowed(st.from, st.to, 'user_step_up')).toBe(true);
    }
  });

  it('перевыпуск QR — тот же payment_id: qr_expired|qr_pending → qr_shown', () => {
    expect(planQrReissue('qr_expired')).toEqual({ from: 'qr_expired', to: 'qr_shown' });
    expect(planQrReissue('qr_pending').to).toBe('qr_shown');
    expect(() => planQrReissue('received')).toThrow(/PAYMENT_STATE_INVALID/);
  });
});

describe('подтверждение оплаты провайдером (QR через 1С, 07 §6.4 правило 10)', () => {
  const amount = 1_600_750n;
  it('совпали сумма и референс → received', () => {
    expect(
      decideProviderReport('qr_shown', amount, { state: 'paid', paidTyiyn: amount, referenceKnown: true }),
    ).toEqual({
      kind: 'transition',
      to: 'received',
    });
  });
  it('сумма ≠ amount → manual_confirm (amount_mismatch); неизвестный референс → unknown_reference', () => {
    expect(decideProviderReport('qr_shown', amount, { state: 'paid', paidTyiyn: 100n, referenceKnown: true })).toEqual({
      kind: 'transition',
      to: 'manual_confirm',
      reviewReason: 'amount_mismatch',
    });
    expect(
      decideProviderReport('qr_shown', amount, { state: 'paid', paidTyiyn: amount, referenceKnown: false }),
    ).toMatchObject({
      reviewReason: 'unknown_reference',
    });
  });
  it('оплата после истечения → manual_confirm (late_payment); expired у провайдера → qr_expired', () => {
    expect(
      decideProviderReport('qr_expired', amount, { state: 'paid', paidTyiyn: amount, referenceKnown: true }),
    ).toMatchObject({
      to: 'manual_confirm',
      reviewReason: 'late_payment',
    });
    expect(
      decideProviderReport('qr_shown', amount, { state: 'expired', paidTyiyn: null, referenceKnown: true }),
    ).toEqual({
      kind: 'transition',
      to: 'qr_expired',
      cause: 'provider_expired',
    });
  });
  it('PAY-025 / 05 §6.7.3: оплата по референсу из истории (перевыпуск) → late_payment; cancelled от 1С → qr_expired', () => {
    expect(
      decideProviderReport('qr_shown', amount, {
        state: 'paid',
        paidTyiyn: amount,
        referenceKnown: false,
        referencePrevious: true,
      }),
    ).toEqual({ kind: 'transition', to: 'manual_confirm', reviewReason: 'late_payment' });
    expect(
      decideProviderReport('qr_shown', amount, { state: 'paid', paidTyiyn: amount, referenceKnown: false }),
    ).toMatchObject({ reviewReason: 'unknown_reference' });
    expect(
      decideProviderReport('qr_shown', amount, { state: 'cancelled', paidTyiyn: null, referenceKnown: true }),
    ).toEqual({ kind: 'transition', to: 'qr_expired', cause: 'provider_cancelled' });
    // Отмена прежнего QR при перевыпуске текущий QR не гасит; у аннулированного/истёкшего — без перехода.
    expect(
      decideProviderReport('qr_shown', amount, {
        state: 'cancelled',
        paidTyiyn: null,
        referenceKnown: false,
        referencePrevious: true,
      }).kind,
    ).toBe('none');
    expect(
      decideProviderReport('voided', amount, { state: 'cancelled', paidTyiyn: null, referenceKnown: true }).kind,
    ).toBe('none');
  });
  it('pending/unknown — без перехода; оплата вне ожидания — разбор без перехода', () => {
    expect(
      decideProviderReport('qr_shown', amount, { state: 'pending', paidTyiyn: null, referenceKnown: true }).kind,
    ).toBe('none');
    expect(
      decideProviderReport('voided', amount, { state: 'paid', paidTyiyn: amount, referenceKnown: true }).kind,
    ).toBe('review_only');
  });
  it('каждое решение-переход допустимо автоматом для provider/timer', () => {
    for (const s of ['qr_shown', 'qr_expired'] as PaymentStatus[])
      for (const state of ['paid', 'expired', 'cancelled'] as const) {
        const d = decideProviderReport(s, amount, { state, paidTyiyn: amount, referenceKnown: true });
        if (d.kind === 'transition') {
          expect(isPaymentTransitionAllowed(s, d.to, 'provider') || isPaymentTransitionAllowed(s, d.to, 'timer')).toBe(
            true,
          );
        }
      }
  });
});

describe('смена способа оплаты (ядро §23 п. 3; PAY-052)', () => {
  it('нет открытого — create; тот же способ — reuse; другой — системный void (без step-up) и create', () => {
    expect(planNewPayment(null, 'cash')).toEqual({ kind: 'create' });
    expect(planNewPayment({ id: 'p1', method: 'cash', status: 'cash_pending' }, 'cash')).toEqual({
      kind: 'reuse',
      paymentId: 'p1',
    });
    for (const status of ['cash_pending', 'qr_pending', 'qr_shown'] as PaymentStatus[]) {
      expect(planNewPayment({ id: 'p1', method: 'qr_bakai', status }, 'cash')).toEqual({
        kind: 'void_and_create',
        voidPaymentId: 'p1',
      });
      expect(isPaymentTransitionAllowed(status, 'voided', 'system')).toBe(true);
    }
  });
  it('qr_expired / manual_confirm — сначала решение кассира', () => {
    for (const status of ['qr_expired', 'manual_confirm'] as PaymentStatus[]) {
      expect(() => planNewPayment({ id: 'p1', method: 'qr_bakai', status }, 'cash')).toThrow(
        expect.objectContaining({
          code: 'PAYMENT_STATE_INVALID',
          extensions: expect.objectContaining({
            reason: 'open_payment_exists',
            openPaymentId: 'p1',
            currentStatus: status,
          }),
        }),
      );
    }
  });
});

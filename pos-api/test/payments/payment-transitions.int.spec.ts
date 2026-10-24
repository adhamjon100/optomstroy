import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PAYMENT_STATUS_VALUES, type PaymentStatus } from '../../src/common/enums.js';
import { PaymentStateWriter } from '../../src/payments/app/payment-state.writer.js';
import { PaymentsRepository } from '../../src/payments/infra/payments.repository.js';
import { SalesDomainError } from '../../src/sales-domain/domain-error.js';
import {
  isPaymentTransitionAllowed,
  PAYMENT_TRANSITIONS,
  type PaymentActor,
} from '../../src/sales-domain/payment/payment-status.js';
import { PaymentsTestApp } from './support/payments-app.js';

const ACTORS: readonly PaymentActor[] = ['system', 'provider', 'timer', 'user', 'user_step_up', 'onec_sync'];

class Rollback extends Error {}

/**
 * Автомат `payment_status` на реальной БД (07 §6.4; ядро §22.2, §23 пп. 3–4; 12 T-PAY-034): для каждой тройки
 * «исходный статус × целевой × инициатор» модуль `payments` (`PaymentStateWriter.move`) либо выполняет переход
 * (строка проходит CHECK/триггеры 0001), либо отвечает `PAYMENT_STATE_INVALID` — ровно по таблице переходов.
 * Каждая проверка — в откатываемой транзакции (**тестовые данные**).
 */
describe('payment_status: все переходы и недопустимые (T-PAY-034)', () => {
  const t = new PaymentsTestApp();
  let orderId: string;
  let userId: string;

  beforeAll(async () => {
    await t.startPayments({ env: { QR_PROVIDER: 'none' }, jobs: false });
    const seller = await t.actor({ role: 'cashier' });
    userId = seller.userId;
    const o = await t.seedOrder({ createdBy: seller, method: 'cash', status: 'awaiting_payment' });
    orderId = o.orderId;
    await t.forcePayment(o.paymentId, { status: 'voided' });
  });
  afterAll(async () => {
    await t.stop();
  });

  /** Строка платежа в статусе `status` (вставка `initiated` + прямой UPDATE мимо автомата — подготовка). */
  async function rowIn(tx: Parameters<Parameters<typeof t.db.transaction>[0]>[0], status: PaymentStatus) {
    const repo = t.app.get(PaymentsRepository, { strict: false });
    const p = await repo.insert(tx, {
      orderId,
      customerId: null,
      method: 'qr_bakai',
      qrProvider: 'none',
      status: 'initiated',
      amount: '100.00',
      createdByUserId: userId,
      idempotencyKey: randomUUID(),
      requestId: null,
    });
    if (status === 'initiated') return p;
    const moved = await repo.transition(
      tx,
      p.id,
      'initiated',
      status,
      status === 'manual_confirm' ? { reviewReason: 'amount_mismatch' } : {},
    );
    if (!moved) throw new Error(`подготовка: ${status}`);
    return moved;
  }

  it('таблица кода совпадает с 07 §6.4: 17 переходов; credit/voided/refunded — конечные; received → voided запрещён', () => {
    expect(PAYMENT_TRANSITIONS).toHaveLength(17);
    for (const to of PAYMENT_STATUS_VALUES) {
      expect(isPaymentTransitionAllowed('credit', to)).toBe(false);
      expect(isPaymentTransitionAllowed('voided', to)).toBe(false);
      expect(isPaymentTransitionAllowed('refunded', to)).toBe(false);
    }
    expect(isPaymentTransitionAllowed('received', 'voided')).toBe(false);
    expect(isPaymentTransitionAllowed('qr_expired', 'received')).toBe(false);
  });

  it('каждая тройка статус × статус × инициатор: разрешённые применяются в БД, остальные → PAYMENT_STATE_INVALID', async () => {
    const writer = t.app.get(PaymentStateWriter, { strict: false });
    let allowed = 0;
    let denied = 0;
    for (const from of PAYMENT_STATUS_VALUES) {
      for (const to of PAYMENT_STATUS_VALUES) {
        for (const actor of ACTORS) {
          const expectOk = isPaymentTransitionAllowed(from, to, actor);
          let outcome: 'ok' | 'denied' | Error = 'ok';
          try {
            await t.db.transaction(async (tx) => {
              const p = await rowIn(tx, from);
              const moved = await writer.move(
                tx,
                p,
                to,
                actor,
                to === 'manual_confirm' ? { reviewReason: 'no_webhook' } : {},
              );
              expect(moved.status).toBe(to);
              throw new Rollback();
            });
          } catch (e) {
            if (e instanceof Rollback) outcome = 'ok';
            else if (e instanceof SalesDomainError && e.code === 'PAYMENT_STATE_INVALID') outcome = 'denied';
            else outcome = e as Error;
          }
          const label = `${from} → ${to} (${actor})`;
          if (outcome instanceof Error) throw new Error(`${label}: ${outcome.message}`);
          expect(outcome, label).toBe(expectOk ? 'ok' : 'denied');
          if (expectOk) allowed += 1;
          else denied += 1;
        }
      }
    }
    // 17 переходов, часть — с двумя инициаторами (07 §6.4).
    const expectedAllowed = PAYMENT_TRANSITIONS.reduce((n, tr) => n + tr.actors.length, 0);
    expect(allowed).toBe(expectedAllowed);
    expect(allowed + denied).toBe(PAYMENT_STATUS_VALUES.length ** 2 * ACTORS.length);
  });

  it('PAYMENT_STATE_INVALID несёт причину: received → voided — received_void_forbidden; credit — credit_terminal', async () => {
    const writer = t.app.get(PaymentStateWriter, { strict: false });
    const reasons: Partial<Record<PaymentStatus, string>> = {};
    for (const from of ['received', 'credit'] as const) {
      await t.db
        .transaction(async (tx) => {
          const p = await rowIn(tx, from);
          await writer.move(tx, p, 'voided', 'user_step_up', {});
        })
        .catch((e: unknown) => {
          if (e instanceof SalesDomainError) reasons[from] = String(e.extensions.reason);
        });
    }
    expect(reasons).toEqual({ received: 'received_void_forbidden', credit: 'credit_terminal' });
  });
});

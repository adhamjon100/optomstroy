import { describe, expect, it } from 'vitest';
import { attachIdempotencyState } from '../../src/common/idempotency/idempotency.context.js';
import type { OrderPaymentView } from '../../src/common/ports/index.js';
import type { PermissionCode } from '../../src/common/rbac/permissions.generated.js';
import type { PaymentsCaller } from '../../src/payments/app/payments-caller.js';
import { PaymentsService } from '../../src/payments/app/payments.service.js';
import type { PaymentRow } from '../../src/payments/infra/payments.repository.js';
import { paymentRow } from './support/payment-row.js';

/**
 * Ветви `PaymentsService` (13 RM-F-009 «платёж — 100 % веток»; ревью F-trace-2, FIX-F-23), не достижимые сквозными
 * сценариями с БД без подмены данных: системный субъект без `userId`, платёж без заказа, исчезновение строки между
 * чтением и блокировкой, сумма к оплате ≤ 0 при `isPaid=false` и т. п. — **тестовые данные**, фейки зависимостей.
 * Сценарии с БД — payments-none.e2e, payments-qr-onec.e2e, payments-with-orders.int.
 */
const OID = '0192f3a1-0000-7000-8000-0000000000b1';
const ME = '0192f3a1-0000-7000-8000-0000000000c1';
const OTHER = '0192f3a1-0000-7000-8000-0000000000c2';
const STEP = { operation: 'payment.void', method: 'pin', jti: 'j' } as never;

function caller(perms: PermissionCode[], over: Partial<PaymentsCaller> = {}): PaymentsCaller {
  return {
    userId: ME,
    roles: ['cashier'],
    isCustomer: false,
    perms: new Set(perms),
    audit: { actorUserId: ME, requestId: 'r' },
    requestId: 'r',
    sessionId: null,
    deviceId: null,
    ...over,
  };
}
const CASHIER: PermissionCode[] = ['payment.cash.receive', 'payment.qr.show', 'order.read.all', 'payment.read.all'];

function order(over: Partial<OrderPaymentView> = {}): OrderPaymentView {
  return {
    orderId: OID,
    publicNumber: 'POS-2026-000001',
    status: 'awaiting_payment',
    paymentMethod: 'cash',
    customerId: '0192f3a1-0000-7000-8000-0000000000d1',
    createdByUserId: OTHER,
    createdVia: 'staff',
    onecRef: null,
    total: '100.00',
    paidAmount: '0.00',
    isPaid: false,
    cancelRequested: false,
    ...over,
  };
}

interface F {
  order?: OrderPaymentView | null;
  open?: PaymentRow | null;
  byId?: (id: string, lock?: boolean) => PaymentRow | null;
  readOrder?: { publicNumber: string; createdByUserId: string } | null;
  issue?: { payment: PaymentRow | null; warnings: { code: string; message: string }[] };
  refresh?: boolean;
  acquire?: boolean;
  inserted?: Record<string, unknown>[];
  moves?: unknown[];
  completed?: unknown[];
  mode?: 'onec' | 'none';
  completeFails?: boolean;
  /** Поля результата `systemVoid` (по умолчанию — исходный платёж со статусом `voided`). */
  voided?: Partial<PaymentRow>;
  /** Журнал `cancelInBackground` (отмена QR в 1С после COMMIT). */
  cancelled?: string[];
}

function svc(f: F = {}) {
  const tx = { execute: () => Promise.resolve({ rows: [] }) };
  const db = { transaction: (fn: (t: unknown) => unknown) => fn(tx), execute: tx.execute };
  const inserted = f.inserted ?? [];
  const moves = f.moves ?? [];
  const repo = {
    findOpenForOrder: () => Promise.resolve(f.open ?? null),
    findById: (_ex: unknown, id: string, lock?: boolean) => Promise.resolve(f.byId ? f.byId(id, lock) : null),
    listForOrder: () => Promise.resolve([]),
    insert: (_tx: unknown, v: Record<string, unknown>) => {
      inserted.push(v);
      return Promise.resolve(
        paymentRow({
          id: `new-${inserted.length}`,
          method: v.method as never,
          status: v.status as never,
          amount: String(v.amount),
        }),
      );
    },
  };
  const lookups = {
    order: () =>
      Promise.resolve(
        f.readOrder === undefined ? { publicNumber: 'POS-2026-000001', createdByUserId: OTHER } : f.readOrder,
      ),
    userRefs: () => Promise.resolve(new Map()),
  };
  const writer = {
    systemVoid: (_tx: unknown, p: PaymentRow) => Promise.resolve({ ...p, status: 'voided', ...f.voided }),
    move: (_tx: unknown, p: PaymentRow, to: string | null, kind: string, patch: Record<string, unknown>) => {
      moves.push({ from: p.status, to, kind, patch });
      return Promise.resolve({
        ...p,
        status: to ?? p.status,
        reviewReason: (patch.reviewReason as never) ?? p.reviewReason,
      });
    },
    receive: (_tx: unknown, i: { payment: PaymentRow }) =>
      Promise.resolve({ payment: { ...i.payment, status: 'received' }, paidAmount: '100.00', isPaid: true }),
  };
  const ok = () => Promise.resolve();
  const completed = f.completed ?? [];
  return new PaymentsService(
    db as never,
    { now: () => new Date('2026-10-23T08:00:00Z') },
    { lockForPayment: () => Promise.resolve(f.order === undefined ? order() : f.order) } as never,
    repo as never,
    lookups as never,
    writer as never,
    { write: ok },
    { write: ok } as never,
    {
      recordInTransaction: ok,
      complete: (...a: unknown[]) => {
        completed.push(a);
        return f.completeFails ? Promise.reject(new Error('idempotency_keys недоступна (тест)')) : Promise.resolve();
      },
    } as never,
    { mode: f.mode ?? 'onec', staticPayload: () => Promise.resolve(null) } as never,
    { issue: () => Promise.resolve(f.issue ?? { payment: null, warnings: [] }) } as never,
    {
      refresh: () => Promise.resolve(f.refresh ?? true),
      cancelInBackground: (id: string) => {
        f.cancelled?.push(id);
      },
    } as never,
    {
      acquire: () => (f.acquire === false ? null : () => undefined),
      waitForChange: async (_id: string, _s: string, _d: Date, _sig: AbortSignal, read: () => Promise<unknown>) => {
        await read();
      },
    } as never,
  );
}

describe('PaymentsService: ветви приёма оплаты (RM-F-009)', () => {
  it('QR без права payment.qr.show → 403 payment_method_not_permitted', async () => {
    await expect(
      svc().acceptForOrder(caller(['payment.cash.receive']), OID, { method: 'qr_bakai' } as never, 'k', {}),
    ).rejects.toMatchObject({ code: 'FORBIDDEN', extensions: { reason: 'payment_method_not_permitted' } });
  });

  it('наличные: системный субъект (userId=null) — автор платежа = автор заказа; комментарий — в журнал', async () => {
    const inserted: Record<string, unknown>[] = [];
    const r = await svc({ inserted }).acceptForOrder(
      caller(CASHIER, { userId: null }),
      OID,
      { method: 'cash', comment: 'сдача мелочью' } as never,
      'k',
      {},
    );
    expect(r.status).toBe(201);
    expect(inserted[0]).toMatchObject({ method: 'cash', createdByUserId: OTHER });
  });

  it('сумма к оплате ≤ 0 при isPaid=false → 409 already_paid', async () => {
    await expect(
      svc({ order: order({ paidAmount: '100.00' }) }).acceptForOrder(
        caller(CASHIER),
        OID,
        { method: 'cash' } as never,
        'k',
        {},
      ),
    ).rejects.toMatchObject({ code: 'ORDER_STATE_INVALID', extensions: { reason: 'already_paid' } });
  });

  it('QR: новый платёж без открытого (create), системный субъект; QR не выдан (payment=null) — прежняя строка; без состояния идемпотентности — итог не перезаписывается', async () => {
    const inserted: Record<string, unknown>[] = [];
    const completed: unknown[] = [];
    const r = await svc({
      inserted,
      completed,
      issue: { payment: null, warnings: [{ code: 'QR_UNAVAILABLE', message: 'x' }] },
    }).acceptForOrder(caller(CASHIER, { userId: null }), OID, { method: 'qr_bakai' } as never, 'k', {});
    expect(r).toMatchObject({ status: 201, body: { status: 'qr_pending', warnings: [{ code: 'QR_UNAVAILABLE' }] } });
    expect(inserted[0]).toMatchObject({ method: 'qr_bakai', qrProvider: 'onec', createdByUserId: OTHER });
    expect(completed).toEqual([]);
    // С состоянием идемпотентности — итог с QR перезаписывается (B-AR-04).
    const req = {};
    attachIdempotencyState(req, { key: 'k' } as never);
    await svc({ completed }).acceptForOrder(caller(CASHIER), OID, { method: 'qr_bakai' } as never, 'k', req);
    expect(completed).toHaveLength(1);
    // Сбой перезаписи итога после выдачи QR — только журнал, ответ клиенту не меняется.
    const req2 = {};
    attachIdempotencyState(req2, { key: 'k2' } as never);
    const r2 = await svc({ completeFails: true }).acceptForOrder(
      caller(CASHIER),
      OID,
      { method: 'qr_bakai' } as never,
      'k2',
      req2,
    );
    expect(r2.status).toBe(201);
  });

  it('QR: смена способа с открытого наличного (не QR провайдера) — отмена QR в 1С не ставится', async () => {
    const open = paymentRow({ id: 'cash-open', status: 'cash_pending' });
    const cancelled: string[] = [];
    const r = await svc({ open, cancelled }).acceptForOrder(
      caller(CASHIER),
      OID,
      { method: 'qr_bakai' } as never,
      'k',
      {},
    );
    expect(r.status).toBe(201);
    expect(cancelled).toEqual([]);
  });

  // docs/stages/F_branch_exceptions.md E-1 (RC-7, RR-4): защитная ветвь — если аннулированный при смене способа платёж
  // оказался QR провайдера (новый способ оплаты в будущем), его QR отменяется в 1С после COMMIT (SYNC-078).
  it('E-1: QR — аннулирован открытый QR провайдера → отмена QR в 1С ставится после COMMIT', async () => {
    const open = paymentRow({ id: 'other-open', status: 'cash_pending' });
    const cancelled: string[] = [];
    const r = await svc({
      open,
      cancelled,
      voided: { method: 'qr_bakai', qrProvider: 'onec', qrProviderRef: 'QR-E1' },
    }).acceptForOrder(caller(CASHIER), OID, { method: 'qr_bakai' } as never, 'k', {});
    expect(r.status).toBe(201);
    expect(cancelled).toEqual(['other-open']);
  });

  it('reissueQr без открытого QR-платежа → 409 transition_not_allowed (текущий статус initiated)', async () => {
    await expect(
      svc().acceptForOrder(caller(CASHIER), OID, { method: 'qr_bakai', reissueQr: true } as never, 'k', {}),
    ).rejects.toMatchObject({
      code: 'PAYMENT_STATE_INVALID',
      extensions: { reason: 'transition_not_allowed', currentStatus: 'initiated' },
    });
  });
});

describe('PaymentsService: ветви чтения (RM-F-009)', () => {
  const qrStatic = paymentRow({ method: 'qr_bakai', status: 'qr_shown', qrProvider: 'none', createdByUserId: OTHER });
  const qrOnec = paymentRow({
    method: 'qr_bakai',
    status: 'qr_shown',
    qrProvider: 'onec',
    qrProviderRef: 'ref',
    createdByUserId: OTHER,
  });

  it('refreshStatus для статического QR (не провайдера) — без опроса; строка исчезла после опроса/ожидания — прежняя', async () => {
    let calls = 0;
    const s1 = svc({ byId: () => qrStatic });
    expect(
      (await s1.get(caller(CASHIER), qrStatic.id, { refreshStatus: true, signal: new AbortController().signal }))
        .status,
    ).toBe('qr_shown');
    // refreshStatus у не-QR статуса (наличные) — без опроса.
    const cash = paymentRow({ createdByUserId: OTHER });
    expect(
      (
        await svc({ byId: () => cash }).get(caller(CASHIER), cash.id, {
          refreshStatus: true,
          signal: new AbortController().signal,
        })
      ).status,
    ).toBe('cash_pending');
    const s2 = svc({ byId: () => (calls++ === 0 ? qrOnec : null), refresh: false });
    const r = await s2.get(caller(CASHIER), qrOnec.id, { refreshStatus: true, signal: new AbortController().signal });
    expect(r.warnings).toEqual([expect.objectContaining({ code: 'STALE_DATA' })]);
    calls = 0;
    const s3 = svc({ byId: () => (calls++ === 0 ? qrOnec : null) });
    expect(
      (await s3.get(caller(CASHIER), qrOnec.id, { waitSeconds: 1, signal: new AbortController().signal })).id,
    ).toBe(qrOnec.id);
    // Предел ожиданий исчерпан — ответ сразу; без пользователя ожидания нет.
    expect(
      (
        await svc({ byId: () => qrOnec, acquire: false }).get(caller(CASHIER), qrOnec.id, {
          waitSeconds: 1,
          signal: new AbortController().signal,
        })
      ).id,
    ).toBe(qrOnec.id);
    expect(
      (
        await svc({ byId: () => qrOnec }).get(caller(CASHIER, { userId: null }), qrOnec.id, {
          waitSeconds: 1,
          signal: new AbortController().signal,
        })
      ).id,
    ).toBe(qrOnec.id);
  });

  it('видимость по payment.read.own: платёж своего заказа — виден; платёж без заказа чужой — 404; чужой заказ — 404', async () => {
    const own = caller(['payment.read.own']);
    const p = paymentRow({ createdByUserId: OTHER });
    expect(
      (
        await svc({ byId: () => p, readOrder: { publicNumber: 'x', createdByUserId: ME } }).get(own, p.id, {
          signal: new AbortController().signal,
        })
      ).id,
    ).toBe(p.id);
    await expect(
      svc({ byId: () => p, readOrder: { publicNumber: 'x', createdByUserId: OTHER } }).get(own, p.id, {
        signal: new AbortController().signal,
      }),
    ).rejects.toMatchObject({ code: 'NOT_FOUND' });
    await expect(
      svc({ byId: () => p, readOrder: null }).get(own, p.id, { signal: new AbortController().signal }),
    ).rejects.toMatchObject({ code: 'NOT_FOUND' });
    const noOrder = paymentRow({ orderId: null, createdByUserId: OTHER });
    await expect(
      svc({ byId: () => noOrder }).get(own, noOrder.id, { signal: new AbortController().signal }),
    ).rejects.toMatchObject({
      code: 'NOT_FOUND',
    });
  });
});

describe('PaymentsService: ветви ручного подтверждения и аннулирования (RM-F-009)', () => {
  const qr = paymentRow({ method: 'qr_bakai', status: 'qr_shown', qrProvider: 'none', amount: '100.00' });
  const body = (amount: string, extra: Record<string, unknown> = {}) =>
    ({ receivedAmount: { amount, currency: 'KGS' }, bankReference: 'BK-1', ...extra }) as never;

  it('confirm-manual: сумма ≤ 0 → 400; платёж исчез до/после блокировки → 404', async () => {
    await expect(svc().confirmManual(caller(CASHIER), qr.id, body('0.00'), STEP, {})).rejects.toMatchObject({
      code: 'VALIDATION_FAILED',
    });
    await expect(
      svc({ byId: () => null }).confirmManual(caller(CASHIER), qr.id, body('100.00'), STEP, {}),
    ).rejects.toMatchObject({
      code: 'NOT_FOUND',
    });
    await expect(
      svc({ byId: (_id, lock) => (lock ? null : qr) }).confirmManual(caller(CASHIER), qr.id, body('100.00'), STEP, {}),
    ).rejects.toMatchObject({ code: 'NOT_FOUND' });
  });

  it('confirm-manual: иная сумма по manual_confirm — разбор без смены статуса (с комментарием и без); receivedAt из тела', async () => {
    const moves: { to: string | null; patch: Record<string, unknown> }[] = [];
    const expired = { ...qr, status: 'manual_confirm' as const, reviewReason: 'late_payment' as const };
    const r1 = await svc({ byId: () => expired, moves }).confirmManual(
      caller(CASHIER),
      qr.id,
      body('90.00', { comment: 'частичная оплата по выписке', receivedAt: '2026-10-23T07:00:00Z' }),
      STEP,
      {},
    );
    expect(r1.warnings).toEqual([expect.objectContaining({ code: 'PAYMENT_AMOUNT_MISMATCH' })]);
    await svc({ byId: () => expired, moves }).confirmManual(caller(CASHIER), qr.id, body('90.00'), STEP, {});
    expect(moves.map((m) => [m.to, m.patch.manualReason])).toEqual([
      [null, 'частичная оплата по выписке'],
      [null, null],
    ]);
  });

  it('confirm-manual: сумма совпала, платёж без заказа → 404', async () => {
    const noOrder = { ...qr, orderId: null };
    await expect(
      svc({ byId: () => noOrder }).confirmManual(caller(CASHIER), qr.id, body('100.00'), STEP, {}),
    ).rejects.toMatchObject({ code: 'NOT_FOUND' });
  });

  it('void: нет платежа / исчез под блокировкой → 404; voided → not_voidable; платёж без заказа — без блокировки заказа', async () => {
    const vb = { reason: 'клиент ушёл', reasonCode: 'customer_refused' } as never;
    await expect(svc().voidByUser(caller(CASHIER), 'x', vb, STEP, {})).rejects.toMatchObject({ code: 'NOT_FOUND' });
    await expect(
      svc({ byId: (_id, lock) => (lock ? null : qr) }).voidByUser(caller(CASHIER), qr.id, vb, STEP, {}),
    ).rejects.toMatchObject({ code: 'NOT_FOUND' });
    await expect(
      svc({ byId: () => ({ ...qr, status: 'voided' }) }).voidByUser(caller(CASHIER), qr.id, vb, STEP, {}),
    ).rejects.toMatchObject({ code: 'PAYMENT_STATE_INVALID', extensions: { reason: 'not_voidable' } });
    const noOrder = { ...qr, orderId: null };
    const r = await svc({ byId: () => noOrder }).voidByUser(caller(CASHIER), qr.id, vb, STEP, {});
    expect(r.status).toBe('voided');
  });
});

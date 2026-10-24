import { describe, expect, it } from 'vitest';
import type { PaymentStatus } from '../../src/common/enums.js';
import type { SalesActor } from '../../src/common/ports/index.js';
import { auditContextOf, PaymentsPortService } from '../../src/payments/app/payments-port.service.js';
import type { PaymentRow } from '../../src/payments/infra/payments.repository.js';
import { paymentRow } from './support/payment-row.js';

/**
 * Ветви `PaymentsPortService` (13 RM-F-009 «платёж — 100 % веток»; ревью F-trace-2, FIX-F-23) — без БД, на фейках
 * зависимостей (**тестовые данные**). Сценарии с БД — payments-with-orders.int, payments-qr-onec.e2e.
 */
const PID = '0192f3a1-0000-7000-8000-0000000000a1';
const OID = '0192f3a1-0000-7000-8000-0000000000b1';
const UID = '0192f3a1-0000-7000-8000-0000000000c1';
const row = (over: Partial<PaymentRow> = {}): PaymentRow =>
  paymentRow({ id: PID, orderId: OID, createdByUserId: UID, ...over });

interface Fakes {
  byKey?: PaymentRow | null;
  byId?: (id: string, lock?: boolean) => PaymentRow | null;
  list?: PaymentRow[];
  inserted?: unknown[];
  perms?: string[];
  customer?: { exists: boolean; isRetailDefault: boolean; hasOnecRef: boolean; creditAllowed: boolean };
  order?: { publicNumber: string } | null;
  issue?: { payment: PaymentRow | null; warnings: { code: string; message: string }[] };
  voided?: (p: PaymentRow) => PaymentRow;
  polls?: string[];
  staticPayload?: string | null;
  mode?: 'onec' | 'none';
}

function svc(f: Fakes = {}) {
  const inserted = f.inserted ?? [];
  const repo = {
    findByIdempotencyKey: () => Promise.resolve(f.byKey ?? null),
    findById: (_ex: unknown, id: string, lock?: boolean) => Promise.resolve(f.byId ? f.byId(id, lock) : null),
    listForOrder: () => Promise.resolve(f.list ?? []),
    receivedTotal: (ex: unknown, orderId: string) => Promise.resolve(`${String(ex === 'TX')}:${orderId}`),
    insert: (_tx: unknown, v: Record<string, unknown>) => {
      inserted.push(v);
      return Promise.resolve(row({ method: v.method as PaymentRow['method'], status: v.status as PaymentStatus }));
    },
  };
  const lookups = {
    order: () => Promise.resolve(f.order === undefined ? { publicNumber: 'POS-2026-000001' } : f.order),
    creditCustomer: () =>
      Promise.resolve(f.customer ?? { exists: true, isRetailDefault: false, hasOnecRef: true, creditAllowed: true }),
  };
  const writer = {
    systemVoid: (_tx: unknown, p: PaymentRow) =>
      Promise.resolve(f.voided ? f.voided(p) : row({ ...p, status: 'voided' })),
  };
  const qrIssuer = { issue: () => Promise.resolve(f.issue ?? { payment: null, warnings: [] }) };
  const providers = { mode: f.mode ?? 'onec', staticPayload: () => Promise.resolve(f.staticPayload ?? null) };
  const jobs = {
    enqueuePollInTx: (_tx: unknown, id: string) => {
      (f.polls ??= []).push(id);
      return Promise.resolve();
    },
  };
  const catalog = { effectivePermissions: () => new Set(f.perms ?? ['payment.qr.show', 'credit.sale.create']) };
  return new PaymentsPortService(
    'DB' as never,
    repo as never,
    lookups as never,
    writer as never,
    qrIssuer as never,
    providers as never,
    jobs as never,
    catalog as never,
  );
}

const seller: SalesActor = { userId: UID, roles: ['seller'], isCustomer: false, requestId: 'r-1' };
const base = {
  orderId: OID,
  customerId: '0192f3a1-0000-7000-8000-0000000000d1',
  amount: '100.00',
  idempotencyKey: 'order:k',
  actor: seller,
} as const;

describe('PaymentsPortService: ветви (RM-F-009)', () => {
  it('auditContextOf: пользователь — без system; системный вызов — system=payments, необязательные поля null', () => {
    expect(auditContextOf(seller)).toMatchObject({ actorUserId: UID, requestId: 'r-1', sessionId: null });
    expect(auditContextOf(seller)).not.toHaveProperty('system');
    expect(auditContextOf({ userId: null, roles: [], isCustomer: false })).toMatchObject({
      actorUserId: null,
      system: 'payments',
      deviceId: null,
      requestId: null,
    });
  });

  it('createInitial: повтор по ключу → существующий; без пользователя ключ не ищется; сумма ≤ 0 → 422; без пользователя → ошибка', async () => {
    const existing = row({ method: 'qr_bakai', status: 'qr_pending', qrProvider: 'none' });
    const r = await svc({ byKey: existing, staticPayload: 'STATIC' }).createInitial('TX' as never, {
      ...base,
      method: 'qr_bakai',
    });
    expect(r).toMatchObject({ paymentId: PID, status: 'qr_pending' });
    await expect(svc().createInitial('TX' as never, { ...base, amount: '0.00', method: 'cash' })).rejects.toMatchObject(
      {
        code: 'VALIDATION_FAILED',
      },
    );
    await expect(
      svc({ byKey: existing }).createInitial('TX' as never, {
        ...base,
        method: 'cash',
        actor: { userId: null, roles: [], isCustomer: false },
      }),
    ).rejects.toThrow('нужен пользователь-инициатор');
  });

  it('createInitial: cash / qr_bakai (qr_provider из режима) / credit после шага 1 PAY-031', async () => {
    const inserted: Record<string, unknown>[] = [];
    const s = svc({ inserted, mode: 'none' });
    expect((await s.createInitial('TX' as never, { ...base, method: 'cash' })).status).toBe('cash_pending');
    expect(
      (
        await s.createInitial('TX' as never, {
          ...base,
          method: 'qr_bakai',
          actor: { ...seller, requestId: undefined },
        })
      ).status,
    ).toBe('qr_pending');
    expect((await s.createInitial('TX' as never, { ...base, method: 'credit' })).status).toBe('credit');
    expect(inserted.map((i) => [i.method, i.qrProvider, i.requestId])).toEqual([
      ['cash', null, 'r-1'],
      ['qr_bakai', 'none', null],
      ['credit', null, 'r-1'],
    ]);
  });

  it('createInitial credit: роль без права и клиент-покупатель → FORBIDDEN; клиент не идентифицирован → CUSTOMER_NOT_IDENTIFIED; без отсрочки → CREDIT_BLOCKED', async () => {
    const credit = { ...base, method: 'credit' as const };
    await expect(svc({ perms: [] }).createInitial('TX' as never, credit)).rejects.toMatchObject({
      code: 'FORBIDDEN',
      extensions: { creditReason: 'forbidden_role' },
    });
    await expect(
      svc().createInitial('TX' as never, { ...credit, actor: { ...seller, isCustomer: true } }),
    ).rejects.toMatchObject({ code: 'FORBIDDEN' });
    for (const customer of [
      { exists: false, isRetailDefault: false, hasOnecRef: true, creditAllowed: true },
      { exists: true, isRetailDefault: true, hasOnecRef: true, creditAllowed: true },
      { exists: true, isRetailDefault: false, hasOnecRef: false, creditAllowed: true },
    ]) {
      await expect(svc({ customer }).createInitial('TX' as never, credit)).rejects.toMatchObject({
        code: 'CUSTOMER_NOT_IDENTIFIED',
      });
    }
    await expect(
      svc({ customer: { exists: true, isRetailDefault: false, hasOnecRef: true, creditAllowed: false } }).createInitial(
        'TX' as never,
        credit,
      ),
    ).rejects.toMatchObject({ code: 'CREDIT_BLOCKED', extensions: { creditReason: 'credit_not_allowed' } });
  });

  it('afterCommit: нет платежа → 404; не QR / не qr_pending / нет права — без выдачи; выдача — платёж из ответа или прежний, только QR_UNAVAILABLE', async () => {
    await expect(svc().afterCommit(PID, seller)).rejects.toMatchObject({ code: 'NOT_FOUND' });
    const cash = row();
    expect(await svc({ byId: () => cash }).afterCommit(PID, seller)).toMatchObject({ warnings: [] });
    const shown = row({ method: 'qr_bakai', status: 'qr_shown', qrProvider: 'onec' });
    expect(await svc({ byId: () => shown }).afterCommit(PID, seller)).toMatchObject({
      payment: { status: 'qr_shown' },
    });
    const pending = row({ method: 'qr_bakai', status: 'qr_pending', qrProvider: 'onec' });
    expect(await svc({ byId: () => pending, perms: [] }).afterCommit(PID, seller)).toMatchObject({
      payment: { status: 'qr_pending' },
      warnings: [],
    });
    const r1 = await svc({
      byId: () => pending,
      issue: {
        payment: null,
        warnings: [
          { code: 'QR_UNAVAILABLE', message: '1С недоступна' },
          { code: 'STALE_DATA', message: 'x' },
        ],
      },
    }).afterCommit(PID, { userId: null, roles: ['cashier'], isCustomer: false });
    expect(r1).toEqual({
      payment: expect.objectContaining({ status: 'qr_pending' }),
      warnings: [{ code: 'QR_UNAVAILABLE', message: '1С недоступна' }],
    });
    const r2 = await svc({
      byId: () => pending,
      issue: { payment: row({ ...pending, status: 'qr_shown', qrProviderRef: 'ref' }), warnings: [] },
    }).afterCommit(PID, seller);
    expect(r2.payment.status).toBe('qr_shown');
  });

  it('listForOrder и receivedTotal: транзакция вызывающего или db; статический QR — только при QR-платежах', async () => {
    const list = [row(), row({ id: 'x', method: 'qr_bakai', status: 'qr_shown', qrProvider: 'none' })];
    expect(await svc({ list, staticPayload: 'S' }).listForOrder(OID)).toHaveLength(2);
    expect(await svc({ list: [row()] }).listForOrder(OID, 'TX' as never)).toHaveLength(1);
    expect(await svc({ list: [row()] }).listForOrder(OID, null)).toHaveLength(1);
    expect(await svc().receivedTotal('TX' as never, OID)).toBe(`true:${OID}`);
    expect(await svc().receivedTotal(null, OID)).toBe(`false:${OID}`);
  });

  it('voidOpenForOrderCancel: только открытые статусы; перепроверка под блокировкой; номер заказа или null; опрос — только QR провайдера', async () => {
    const polls: string[] = [];
    const list = [
      row({ id: 'p-received', status: 'received' }),
      row({ id: 'p-gone', status: 'cash_pending' }),
      row({ id: 'p-changed', status: 'qr_shown' }),
      row({ id: 'p-cash', status: 'cash_pending' }),
      row({ id: 'p-qr', method: 'qr_bakai', status: 'qr_shown', qrProvider: 'onec', qrProviderRef: 'ref-1' }),
    ];
    const byId = (id: string) =>
      id === 'p-gone'
        ? null
        : id === 'p-changed'
          ? row({ id, status: 'received' })
          : (list.find((p) => p.id === id) ?? null);
    const ids = await svc({ list, byId, polls }).voidOpenForOrderCancel('TX' as never, {
      orderId: OID,
      actor: seller,
    });
    expect(ids).toEqual(['p-cash', 'p-qr']);
    expect(polls).toEqual(['p-qr']);
    const none = await svc({
      list: [row({ id: 'p-1' })],
      byId: () => row({ id: 'p-1' }),
      order: null,
    }).voidOpenForOrderCancel('TX' as never, { orderId: OID, actor: { userId: null, roles: [], isCustomer: false } });
    expect(none).toEqual(['p-1']);
  });
});

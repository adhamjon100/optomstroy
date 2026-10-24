import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuditRowView } from '../../src/common/ports/index.js';
import type { CashierWorld } from '../support/cashier-fixture.js';
import type { PosActor } from '../support/pos-fixture.js';
import { validateAgainst } from '../settings/support/openapi-check.js';
import { TxnTestApp } from './support/txn-app.js';

/**
 * Журнал операций, дашборд кассира и guard оплаты долга (13 RM-G-004, RM-G-011, RM-G-013; 08 §4.10, §4.14, §4.9.1,
 * §4.9.6; 10 TXN-, CASH-; 12 T-TXN-001…005, T-CASH-006, T-CASH-008, T-SEC-017) — **тестовые данные**: заказы и платежи
 * создаются через API этапа F (корзина → `POST /orders` → приём/void/ручное подтверждение), журнал — реальный.
 */
const PAGE_TXN = {
  allOf: [
    { $ref: '#/components/schemas/Page' },
    {
      type: 'object',
      properties: {
        items: { type: 'array', items: { $ref: '#/components/schemas/Transaction' } },
        summary: { $ref: '#/components/schemas/TransactionsSummary' },
      },
    },
  ],
};

interface TxnItem {
  id: string;
  kind: string;
  number: string;
  amount: { amount: string };
  sign: '+' | '-';
  status: string;
  statusGroup: string;
  customer: { id: string } | null;
  actor?: { id: string };
  related: { type: string; id: string | null }[];
}

let t: TxnTestApp;
let w: CashierWorld;
let sellerA: PosActor;
let sellerB: PosActor;
let cashier: PosActor;
let o1: Awaited<ReturnType<TxnTestApp['orderViaApi']>>; // seller A, наличные, оплачен кассиром, клиент buyer
let o2: Awaited<ReturnType<TxnTestApp['orderViaApi']>>; // кассир, QR, платёж аннулирован
let o3: Awaited<ReturnType<TxnTestApp['orderViaApi']>>; // кассир, QR, подтверждён вручную
let o4: Awaited<ReturnType<TxnTestApp['orderViaApi']>>; // seller B, наличные, ждёт оплаты
const PERIOD = {
  from: new Date(Date.now() - 86_400_000).toISOString(),
  to: new Date(Date.now() + 86_400_000).toISOString(),
};
const day = () => `from=${encodeURIComponent(PERIOD.from)}&to=${encodeURIComponent(PERIOD.to)}`;

async function list(actor: PosActor, query = ''): Promise<{ status: number; body: Record<string, unknown> }> {
  const r = await t.req('get', `/transactions?${day()}&limit=200${query ? `&${query}` : ''}`, actor);
  return { status: r.status, body: r.body as Record<string, unknown> };
}

async function showQr(actor: PosActor, orderId: string, paymentId: string): Promise<void> {
  const p = await t.req('get', `/payments/${paymentId}`, actor);
  if ((p.body as { status: string }).status === 'qr_shown') return;
  const r = await t.req('post', `/orders/${orderId}/payments`, actor, { idem: true }).send({ method: 'qr_bakai' });
  expect([200, 201], JSON.stringify(r.body)).toContain(r.status);
}

beforeAll(async () => {
  t = await new TxnTestApp().startTxn();
  w = await t.seedCashierWorld();
  cashier = w.actors.cashier;
  sellerA = w.actors.seller;
  sellerB = await t.actor({ role: 'seller' });

  o1 = await t.orderViaApi(sellerA, { method: 'cash', quantity: '2', customerId: w.customers.buyer.id });
  const pay1 = await t
    .req('post', `/orders/${o1.id}/payments`, cashier, { idem: true })
    .send({ method: 'cash', receivedAmount: { amount: o1.total, currency: 'KGS' } });
  expect([200, 201], JSON.stringify(pay1.body)).toContain(pay1.status);
  expect((pay1.body as { status: string }).status).toBe('received');

  o2 = await t.orderViaApi(cashier, { method: 'qr_bakai' });
  await showQr(cashier, o2.id, o2.paymentId!);
  const voided = await t
    .req('post', `/payments/${o2.paymentId}/void`, cashier, {
      idem: true,
      stepUp: await t.stepUp(cashier, 'payment.void'),
    })
    .send({ reason: 'покупатель передумал', reasonCode: 'customer_refused' });
  expect(voided.status, JSON.stringify(voided.body)).toBe(200);

  o3 = await t.orderViaApi(cashier, { method: 'qr_bakai', quantity: '3' });
  await showQr(cashier, o3.id, o3.paymentId!);
  const confirmed = await t
    .req('post', `/payments/${o3.paymentId}/confirm-manual`, cashier, {
      idem: true,
      stepUp: await t.stepUp(cashier, 'payment.qr.confirm_manual'),
    })
    .send({ bankReference: 'BK-G-TXN-1', receivedAmount: { amount: o3.total, currency: 'KGS' } });
  expect(confirmed.status, JSON.stringify(confirmed.body)).toBe(200);
  expect((confirmed.body as { status: string }).status).toBe('received');

  o4 = await t.orderViaApi(sellerB, { method: 'cash' });
}, 900_000);

afterAll(async () => {
  await t?.stop();
});

describe('журнал transactions — инварианты (RM-G-004 п. 1; TXN-005; T-TXN-001, T-TXN-005)', () => {
  it('каждое финансовое событие F порождает ровно одну строку журнала', async () => {
    const orders = [o1, o2, o3, o4].map((o) => o.id);
    const created = await t.q<{ order_id: string; n: number }>(
      `SELECT order_id, count(*)::int AS n FROM transactions WHERE kind = 'order_created' AND order_id = ANY($1::uuid[])
        GROUP BY order_id`,
      [orders],
    );
    expect(created).toHaveLength(4);
    expect(created.every((r) => r.n === 1)).toBe(true);
    // Повтор POST /orders с тем же ключом — тот же заказ, второй строки нет (TXN-005).
    const before = await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM transactions`);
    const again = await t.orderViaApiReplay(sellerA, o1);
    expect(again).toBe(o1.id);
    const after = await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM transactions`);
    expect(after[0].n).toBe(before[0].n);
  });

  it('Σ по видам = Σ платежей: получено по способу, аннулировано со знаком «−», ручной QR без payment_received', async () => {
    const byKind = await t.q<{ kind: string; method: string | null; n: number; sum: string }>(
      `SELECT kind::text AS kind, payment_method::text AS method, count(*)::int AS n, sum(amount)::text AS sum
         FROM transactions WHERE kind IN ('payment_received','manual_qr_confirm','payment_voided')
        GROUP BY kind, payment_method ORDER BY kind, method`,
    );
    const pays = await t.q<{ status: string; method: string; n: number; sum: string }>(
      `SELECT status::text AS status, method::text AS method, count(*)::int AS n, sum(amount)::text AS sum
         FROM payments WHERE status IN ('received','voided') GROUP BY status, method ORDER BY status, method`,
    );
    const received = byKind.filter((r) => r.kind === 'payment_received' || r.kind === 'manual_qr_confirm');
    for (const p of pays.filter((x) => x.status === 'received')) {
      const rows = received.filter((r) => r.method === p.method);
      expect(rows.reduce((s, r) => s + r.n, 0)).toBe(p.n);
      expect(rows.map((r) => r.sum)).toContain(p.sum);
    }
    const voided = pays.find((x) => x.status === 'voided' && x.method === 'qr_bakai')!;
    const voidRow = byKind.find((r) => r.kind === 'payment_voided')!;
    expect(voidRow.n).toBe(voided.n);
    expect(voidRow.sum).toBe(`-${voided.sum}`);
    const o3rows = await t.q<{ kind: string }>(`SELECT kind::text AS kind FROM transactions WHERE payment_id = $1`, [
      o3.paymentId,
    ]);
    expect(o3rows.map((r) => r.kind)).toEqual(['manual_qr_confirm']);
  });
});

describe('GET /transactions — права, фильтры, курсор (RM-G-004 п. 2; RM-G-011 п. 5; T-TXN-002…004)', () => {
  it('seller видит только операции по своим заказам; cashier+ — все и summary; customer → 403', async () => {
    const a = await list(sellerA);
    expect(a.status).toBe(200);
    const aItems = a.body.items as TxnItem[];
    expect(aItems.length).toBeGreaterThanOrEqual(2);
    expect(aItems.every((i) => i.related.some((r) => r.type === 'order' && r.id === o1.id))).toBe(true);
    expect(a.body.summary).toBeUndefined();
    const aAll = await list(sellerA, 'mine=false');
    expect((aAll.body.items as TxnItem[]).map((i) => i.id).sort()).toEqual(aItems.map((i) => i.id).sort());
    const b = await list(sellerB);
    expect((b.body.items as TxnItem[]).every((i) => i.related.some((r) => r.id === o4.id))).toBe(true);
    const c = await list(cashier);
    expect(c.status).toBe(200);
    const cItems = c.body.items as TxnItem[];
    for (const o of [o1, o2, o3, o4]) expect(cItems.some((i) => i.related.some((r) => r.id === o.id))).toBe(true);
    expect(c.body.summary).toMatchObject({ count: cItems.length });
    expect(validateAgainst(PAGE_TXN, c.body)).toEqual([]);
    for (const role of ['admin', 'owner', 'senior_seller'] as const) {
      expect((await list(w.actors[role])).status).toBe(200);
    }
    expect((await list(w.buyerConfirmed)).status).toBe(403);
    const forbidden = await list(sellerA, `actorId=${cashier.userId}`);
    expect(forbidden.status).toBe(403);
    expect((forbidden.body as { code: string }).code).toBe('FORBIDDEN');
  });

  it('фильтры: вид, группа статуса, способ, клиент, номер, сумма, источник', async () => {
    const voided = (await list(cashier, 'kind=payment_voided')).body.items as TxnItem[];
    expect(voided).toHaveLength(1);
    expect(voided[0]).toMatchObject({ sign: '-', statusGroup: 'voided', status: 'voided' });
    expect(voided[0].amount.amount).toBe(o2.total);
    const groups = (await list(cashier, 'status=received,voided')).body.items as TxnItem[];
    expect(groups.length).toBeGreaterThan(0);
    expect(groups.every((i) => ['received', 'voided'].includes(i.statusGroup))).toBe(true);
    const qr = (await list(cashier, 'paymentMethod=qr_bakai')).body.items as TxnItem[];
    expect(qr.every((i) => i.related.some((r) => r.id === o2.id || r.id === o3.id))).toBe(true);
    const byCustomer = (await list(cashier, `customerId=${w.customers.buyer.id}`)).body.items as TxnItem[];
    expect(byCustomer.length).toBeGreaterThanOrEqual(2);
    expect(byCustomer.every((i) => i.customer?.id === w.customers.buyer.id)).toBe(true);
    const byNumber = (await list(cashier, `q=${o1.publicNumber}`)).body.items as TxnItem[];
    expect(byNumber.every((i) => i.related.some((r) => r.id === o1.id))).toBe(true);
    expect(byNumber.some((i) => i.kind === 'order_created')).toBe(true);
    const big = (await list(cashier, `amountMin=${o3.total}`)).body.items as TxnItem[];
    expect(big.every((i) => Number(i.amount.amount) >= Number(o3.total))).toBe(true); // money-double: allow — сравнение в тесте
    expect(((await list(cashier, 'source=onec')).body.items as TxnItem[]).every((i) => i.kind === 'refund')).toBe(true);
    const pending = (await list(cashier, 'status=pending&kind=order_created')).body.items as TxnItem[];
    expect(pending.some((i) => i.related.some((r) => r.id === o4.id))).toBe(true);
  });

  it('ошибки параметров: период 367 дней, неизвестные kind/status, sort; actorId чужой роли', async () => {
    const from = new Date('2025-01-01T00:00:00Z');
    const to = new Date(from.getTime() + 367 * 86_400_000);
    const r = await t.req('get', `/transactions?from=${from.toISOString()}&to=${to.toISOString()}`, cashier);
    expect(r.status).toBe(400);
    expect(r.body.code).toBe('VALIDATION_FAILED');
    expect(r.body.errors[0].rule).toBe('date_range');
    const ok366 = new Date(from.getTime() + 366 * 86_400_000);
    expect(
      (await t.req('get', `/transactions?from=${from.toISOString()}&to=${ok366.toISOString()}`, cashier)).status,
    ).toBe(200);
    for (const q of ['kind=excess', 'status=paid', 'sort=amount:asc', 'source=bank', 'amountMin=10', 'mine=yes']) {
      const x = await list(cashier, q);
      expect(x.status, q).toBe(400);
    }
    expect((await t.req('get', `/transactions?${day()}&limit=201`, cashier)).status).toBe(400);
  });

  it('курсор: limit=2 обходит выборку без пропусков и дублей; подделка и смена сортировки → 400', async () => {
    const all = ((await list(cashier)).body.items as TxnItem[]).map((i) => i.id);
    const seen: string[] = [];
    let cursor: string | null = null;
    for (let i = 0; i < 100; i++) {
      const r = await t.req(
        'get',
        `/transactions?${day()}&limit=2${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`,
        cashier,
      );
      expect(r.status).toBe(200);
      seen.push(...(r.body.items as TxnItem[]).map((x) => x.id));
      cursor = r.body.nextCursor as string | null;
      if (!r.body.hasMore) break;
    }
    expect(seen).toEqual(all);
    const first = await t.req('get', `/transactions?${day()}&limit=2`, cashier);
    const c = first.body.nextCursor as string;
    const tampered = `${c.slice(0, -1)}${c.endsWith('0') ? '1' : '0'}`;
    const bad = await t.req('get', `/transactions?${day()}&limit=2&cursor=${encodeURIComponent(tampered)}`, cashier);
    expect(bad.status).toBe(400);
    expect(bad.body.errors[0].rule).toBe('cursor');
    const mismatch = await t.req(
      'get',
      `/transactions?${day()}&limit=2&sort=amount:desc&cursor=${encodeURIComponent(c)}`,
      cashier,
    );
    expect(mismatch.body.errors[0].rule).toBe('cursor_sort_mismatch');
    const byAmount = ((await list(cashier, 'sort=amount:desc')).body.items as TxnItem[]).map(
      (i) => (i.sign === '-' ? -Number(i.amount.amount) : Number(i.amount.amount)), // money-double: allow — сравнение порядка в тесте
    );
    expect([...byAmount].sort((a, b) => b - a)).toEqual(byAmount);
  });

  it('аудит transaction.viewed_all — раз на сессию и набор фильтров; выборка своих (seller) — не пишется', async () => {
    const count = async () =>
      (await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM audit_logs WHERE action = 'transaction.viewed_all'`))[0]
        .n;
    const before = await count();
    await list(w.actors.senior_seller, 'kind=order_created');
    await list(w.actors.senior_seller, 'kind=order_created');
    expect(await count()).toBe(before + 1);
    await list(w.actors.senior_seller, 'kind=order_cancelled');
    expect(await count()).toBe(before + 2);
    await list(sellerA);
    await list(w.actors.senior_seller, 'mine=true');
    expect(await count()).toBe(before + 2);
  });
});

describe('GET /transactions/{id} — связанные документы и аудит (TXN-003; T-TXN-003)', () => {
  it('детали: related (заказ, платёж); чужая для seller — 404; audit[] — только audit.read', async () => {
    const row = (
      await t.q<{ id: string }>(`SELECT id FROM transactions WHERE kind = 'payment_received' AND order_id = $1`, [
        o1.id,
      ])
    )[0];
    const c = await t.req('get', `/transactions/${row.id}`, cashier);
    expect(c.status).toBe(200);
    expect(c.body.audit).toBeUndefined();
    expect((c.body.related as { type: string }[]).map((r) => r.type).sort()).toEqual(['order', 'payment']);
    expect(validateAgainst('TransactionsDetail', c.body)).toEqual([]);
    expect((await t.req('get', `/transactions/${row.id}`, sellerA)).status).toBe(200);
    expect((await t.req('get', `/transactions/${row.id}`, sellerB)).status).toBe(404);
    expect((await t.req('get', `/transactions/${randomUUID()}`, cashier)).status).toBe(404);
    expect((await t.req('get', `/transactions/not-a-uuid`, cashier)).status).toBe(404);
    const view: AuditRowView = {
      id: randomUUID(),
      chainSeq: '1',
      occurredAt: new Date(),
      requestId: null,
      actorUserId: cashier.userId,
      actorName: 'Кассир',
      actorRole: 'cashier',
      sessionId: null,
      deviceId: null,
      ip: null,
      appVersion: null,
      action: 'payment.received',
      entityType: 'payment',
      entityId: o1.paymentId,
      onecRef: null,
      before: null,
      after: { amount: '***' },
      result: 'ok',
      stepUpMethod: null,
      reason: null,
      rowHash: 'ab',
      chainOk: true,
    };
    t.auditQuery.rows.push(view);
    const viewedBefore = await t.q<{ n: number }>(
      `SELECT count(*)::int AS n FROM audit_logs WHERE action = 'audit.viewed' AND actor_user_id = $1`,
      [w.actors.admin.userId],
    );
    const admin = await t.req('get', `/transactions/${row.id}`, w.actors.admin);
    expect(admin.status).toBe(200);
    expect((admin.body.audit as { id: string; chainOk: boolean }[]).map((a) => a.id)).toContain(view.id);
    expect(validateAgainst('TransactionsDetail', admin.body)).toEqual([]);
    // Блок audit[] — просмотр журнала аудита: audit.viewed (11 SEC-083, SEC-073; ревью G-security-7).
    const viewed = await t.q<{ after: Record<string, unknown> }>(
      `SELECT after FROM audit_logs WHERE action = 'audit.viewed' AND actor_user_id = $1 ORDER BY chain_seq`,
      [w.actors.admin.userId],
    );
    expect(viewed).toHaveLength(viewedBefore[0].n + 1);
    expect(viewed.at(-1)?.after).toMatchObject({
      source: 'transaction',
      transactionId: row.id,
      rowsReturned: (admin.body.audit as unknown[]).length,
    });
  });

  it('Payment.transactionId — строка журнала платежа (FQ-FEORD-12) для ролей с чтением журнала', async () => {
    const row = (
      await t.q<{ id: string }>(`SELECT id FROM transactions WHERE payment_id = $1 ORDER BY occurred_at DESC`, [
        o1.paymentId,
      ])
    )[0];
    const p = await t.req('get', `/payments/${o1.paymentId}`, cashier);
    expect(p.status).toBe(200);
    expect(p.body.transactionId).toBe(row.id);
    expect(validateAgainst('Payment', { ...p.body, allowedActions: undefined }, false)).toEqual([]);
  });
});

describe('GET /pos/dashboard (RM-G-004 п. 3–4; CASH-010; T-CASH-008; T-SEC-017)', () => {
  it('«Ожидают оплаты» — 4 статуса с открытым платежом; без открытого платежа и в ином статусе — нет', async () => {
    const pending = await t.seedOrder({ createdBy: cashier, method: 'qr_bakai', status: 'pending_approval' });
    const shipping = await t.seedOrder({ createdBy: cashier, method: 'cash', status: 'awaiting_shipment' });
    const r = await t.req('get', '/pos/dashboard', cashier);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const ids = (r.body.awaitingPayment as { id: string; status: string }[]).map((o) => o.id);
    expect(ids).toContain(o4.id); // submitting + cash_pending (после 201/202)
    expect(ids).toContain(pending.orderId); // pending_approval + qr_pending
    expect(ids).toContain(w.orders.buyerRequest.orderId); // заявка клиента awaiting_payment
    expect(ids).not.toContain(o1.id); // оплачен
    expect(ids).not.toContain(o2.id); // платёж аннулирован — открытого нет
    expect(ids).not.toContain(shipping.orderId); // awaiting_shipment
    expect(ids).not.toContain(w.orders.buyerShipped.orderId);
    for (const o of r.body.awaitingPayment as { status: string }[]) {
      expect(['submitting', 'pending_approval', 'approved', 'awaiting_payment']).toContain(o.status);
    }
    expect(validateAgainst('PosDashboard', r.body)).toEqual([]);
  });

  it('сверка: суммы смены = Σ журнала за день по способам; избранные ≤ 12 без сумм; просрочки — с аудитом', async () => {
    const before = await t.auditRows('receivables.overdue_viewed');
    const r = await t.req('get', '/pos/dashboard', cashier);
    const totals = r.body.totals as Record<string, { amount: string } | number>;
    const sum = async (method: string) => {
      const items = (await list(cashier, `kind=payment_received,manual_qr_confirm&paymentMethod=${method}`)).body
        .items as TxnItem[];
      return items.reduce((s, i) => s + Math.round(Number(i.amount.amount) * 100), 0); // money-double: allow — тыйыны в тесте
    };
    expect(Math.round(Number((totals.cash as { amount: string }).amount) * 100)).toBe(await sum('cash')); // money-double: allow — тест
    expect(Math.round(Number((totals.qr as { amount: string }).amount) * 100)).toBe(await sum('qr_bakai')); // money-double: allow — тест
    expect(totals.paymentsCount).toBe(2);
    const created = (await list(cashier, 'kind=order_created')).body.items as TxnItem[];
    expect(totals.ordersCount).toBe(created.length);
    const fav = r.body.favoriteCustomers as Record<string, unknown>[];
    expect(fav.map((c) => c.id).sort()).toEqual([w.customers.buyer.id, w.customers.debtWithinLimit.id].sort());
    expect(fav.every((c) => c.receivable === undefined && typeof c.hasDebt === 'boolean')).toBe(true);
    const overdue = r.body.overdue as { customer: { id: string }; overdueAmount: { amount: string } }[];
    expect(overdue.length).toBeGreaterThan(0);
    expect(overdue.length).toBeLessThanOrEqual(10);
    expect(overdue.map((o) => o.customer.id)).toContain(w.customers.overdue.id);
    expect((await t.auditRows('receivables.overdue_viewed')).length).toBe(before.length + 1);
    expect((r.body.recentTransactions as unknown[]).length).toBeLessThanOrEqual(10);
    expect((r.body.qrPending as unknown[]).length).toBe(r.body.qrPendingCount);
  });

  it('allowlist по ролям: admin — без платёжных списков и строк платежей; owner — без избранных; seller/customer — 403', async () => {
    const admin = await t.req('get', '/pos/dashboard', w.actors.admin);
    expect(admin.status).toBe(200);
    expect(admin.body).not.toHaveProperty('qrPending');
    expect(admin.body).not.toHaveProperty('manualConfirm');
    expect(admin.body).toHaveProperty('qrPendingCount');
    expect(admin.body).toHaveProperty('favoriteCustomers');
    expect(
      (admin.body.recentTransactions as TxnItem[]).every(
        (i) => !['payment_received', 'payment_voided', 'manual_qr_confirm'].includes(i.kind),
      ),
    ).toBe(true);
    expect(validateAgainst('PosDashboard', admin.body)).toEqual([]);
    const owner = await t.req('get', '/pos/dashboard', w.actors.owner);
    expect(owner.status).toBe(200);
    expect(owner.body).not.toHaveProperty('favoriteCustomers');
    expect(owner.body).toHaveProperty('qrPending');
    expect(validateAgainst('PosDashboard', owner.body)).toEqual([]);
    expect((await t.req('get', '/pos/dashboard', sellerA)).status).toBe(403);
    expect((await t.req('get', '/pos/dashboard', w.buyerConfirmed)).status).toBe(403);
    expect((await t.req('get', '/pos/dashboard?date=2026-13-45', cashier)).status).toBe(400);
    const other = await t.req('get', '/pos/dashboard?date=2020-01-01', cashier);
    expect(other.body).toMatchObject({ date: '2020-01-01', awaitingPayment: [], totals: { ordersCount: 0 } });
  });
});

describe('RM-G-013: оплата долга без заказа выключена (DEBT_PAYMENTS_FROM_POS=false; 08 API-087)', () => {
  it('POST /payments → 403; квитанция receipt.pdf → 404; seller — 403 по праву', async () => {
    const body = {
      customerId: w.customers.overdue.id,
      method: 'cash',
      amountRequested: { amount: '100.00', currency: 'KGS' },
    };
    const c = await t.req('post', '/payments', cashier, { idem: true }).send(body);
    expect(c.status).toBe(403);
    expect(c.body).toMatchObject({ code: 'FORBIDDEN', reason: 'debt_payments_disabled' });
    expect((await t.req('post', '/payments', w.actors.senior_seller, { idem: true }).send(body)).status).toBe(403);
    expect((await t.req('post', '/payments', sellerA, { idem: true }).send(body)).status).toBe(403);
    expect((await t.req('post', '/payments', w.actors.admin, { idem: true }).send(body)).status).toBe(403);
    const rc = await t.req('get', `/payments/${o1.paymentId}/documents/receipt.pdf`, cashier);
    expect(rc.status).toBe(404);
    expect((await t.req('get', `/payments/${o1.paymentId}/documents/receipt.pdf`, sellerA)).status).toBe(403);
    expect(await t.q(`SELECT 1 FROM payments WHERE order_id IS NULL`)).toEqual([]);
  });
});

// Последним: отмена заказа добавляет строки журнала (order_cancelled, payment_voided) — фильтры выше их не видят.
describe('журнал transactions — знак суммы по виду (07 §5.44; TXN-001; ревью G-returns-txn-2, G-returns-txn-3)', () => {
  it('отмена заказа — строка order_cancelled со знаком «−» (sign «−»), не входит в sumIn; подтверждения — 0', async () => {
    const sellerC = await t.actor({ role: 'seller' });
    const o5 = await t.orderViaApi(sellerC, { method: 'cash' });
    const cancel = await t
      .req('post', `/orders/${o5.id}/cancel`, sellerC, { idem: true })
      .send({ reason: 'Клиент передумал', reasonCode: 'customer_refused' });
    expect(cancel.status, JSON.stringify(cancel.body)).toBe(200);
    const rows = await t.q<{ id: string; kind: string; amount: string }>(
      `SELECT id, kind::text AS kind, amount::text AS amount FROM transactions WHERE order_id = $1 ORDER BY occurred_at`,
      [o5.id],
    );
    const created = rows.find((r) => r.kind === 'order_created')!;
    const cancelled = rows.find((r) => r.kind === 'order_cancelled')!;
    expect(cancelled.amount).toBe(`-${created.amount}`);
    const item = await t.req('get', `/transactions/${cancelled.id}`, cashier);
    expect(item.body).toMatchObject({ kind: 'order_cancelled', sign: '-', amount: { amount: created.amount } });
    // summary: отмена — в sumOut, а не в sumIn (08 §4.14.1).
    const q = `q=${encodeURIComponent(o5.publicNumber)}`;
    const r = await list(cashier, q);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.summary).toMatchObject({ sumIn: { amount: created.amount } });
    const out = (r.body.summary as { sumOut: { amount: string } }).sumOut.amount;
    expect(Number(out)).toBeGreaterThanOrEqual(Number(created.amount)); // money-double: allow — сравнение в тесте
    // Инвариант по всему журналу: отмены и аннулирования — только «−», нефинансовые подтверждения — 0.
    const wrong = await t.q<{ kind: string; amount: string }>(
      `SELECT kind::text AS kind, amount::text AS amount FROM transactions
        WHERE (kind IN ('order_cancelled','payment_voided','refund') AND amount > 0)
           OR (kind IN ('discount_override','credit_sale_approved','return_requested') AND amount <> 0)`,
    );
    expect(wrong).toEqual([]);
  });
});

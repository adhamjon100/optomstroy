import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { verifyAuditChain } from '../../../src/admin/audit/audit-chain.verifier.js';
import { SalesPortRegistry } from '../../../src/common/ports/index.js';
import { CustomersJobsBridge } from '../../../src/customers/jobs/customers-jobs.bridge.js';
import { SALES_PORT_TOKENS } from '../../../src/common/ports/port-registry.js';
import { Money } from '../../../src/common/money/money.js';
import type { CashierWorld } from '../../support/cashier-fixture.js';
import type { PosActor, SaleableVariant } from '../../support/pos-fixture.js';
import { CashierE2eApp } from './support/cashier-e2e-app.js';

/**
 * Сквозные сценарии этапа G «Кассир» на полном наборе модулей F+G (интеграция backend этапа G; 13 RM-G-009:
 * integration «клиент с долгом → продажа в долг заблокирована → разрешение старшего → оплата → транзакция → аудит»;
 * 12 T-DEBT-010, T-PAY-033, T-TXN-001/005, T-RET-001…008, T-CUST-001/010, T-ADMIN-005/006, T-AUD-001, T-SEC-016) —
 * **тестовые данные**: embedded PostgreSQL 17, синтетический каталог, синтетика кассира в фейке 1С. Все порты
 * `common/ports` — реальные реализации (без заглушек).
 */
let t: CashierE2eApp;
let w: CashierWorld;
let v: SaleableVariant;

const DAY = 86_400_000;
const PERIOD = { from: new Date(Date.now() - DAY).toISOString(), to: new Date(Date.now() + DAY).toISOString() };
const period = () => `from=${encodeURIComponent(PERIOD.from)}&to=${encodeURIComponent(PERIOD.to)}`;
const sum = (xs: readonly string[]) => xs.reduce((s, x) => s.plus(Money.of(x)), Money.ZERO).toString();
const money = (a: string) => ({ amount: Money.of(a).toString(), currency: 'KGS' });

type SalesTotals = {
  ordersCount: number;
  ordersTotal: { amount: string };
  paidTotal: { amount: string };
};

async function salesTotals(actor: PosActor): Promise<SalesTotals> {
  const r = await t.req('get', `/admin/reports/sales-summary?${period()}&groupBy=day`, actor);
  expect(r.status, JSON.stringify(r.body)).toBe(200);
  return (r.body as { totals: SalesTotals }).totals;
}

beforeAll(async () => {
  t = await new CashierE2eApp().start({ env: { QR_PROVIDER: 'none', ONEC_SYNC_CHECK_TIMEOUT_MS: '1500' } });
  w = await t.seedCashierWorld();
  // Снимки только что записаны: «старим» отметку записи (правило «обновление не чаще 1 раза в 30 с»).
  await t.q(`UPDATE receivables SET synced_at = now() - interval '1 hour'`);
  // /check 1С недоступен (мягкий режим) и «Заказ клиента» не принимается — заказы остаются в outbox (не мешает G).
  t.onec.always('checkCart', { transport: true });
  t.onec.always('createOrder', { transport: true });
  [v] = await t.saleableVariants(1);
}, 900_000);

afterAll(async () => {
  await t?.stop();
});

describe('DI этапа G: все порты привязаны реальными реализациями', () => {
  it('SalesPortRegistry: каждый токен common/ports привязан модулем-владельцем или реализацией по умолчанию (не заглушкой)', () => {
    const registry = t.app.get(SalesPortRegistry);
    const notBound = SALES_PORT_TOKENS.filter((k) => {
      try {
        registry.get(k);
        return false;
      } catch {
        return true;
      }
    });
    expect(notBound).toEqual([]);
    // CreditDecisionService — реальный (снимок долга), не fail-closed заглушка этапа F.
    expect(registry.isBound('sales.CreditDecisionService')).toBe(true);
    expect(registry.get('sales.CreditDecisionService').constructor.name).toBe('SnapshotCreditDecisionService');
    for (const k of [
      'sales.CustomerReader',
      'sales.ReceivablesSnapshotPort',
      'sales.DiscountPolicyPort',
      'sales.AuditQueryPort',
    ] as const) {
      expect(registry.isBound(k), k).toBe(true);
    }
    expect(registry.get('sales.TransactionsWriter').constructor.name).toBe('TransactionJournal');
  });
});

describe('клиент с долгом → продажа в долг заблокирована → разрешение старшего (step-up) → оплата → транзакция → аудит', () => {
  it('полный сценарий FLOW-024 (10 PAY-031, PAY-032, DEBT-010; TXN-001; 11 §7.2) и сверка отчёта с журналом', async () => {
    const cust = w.customers.overdue;
    const { cashier, senior_seller: senior, owner, admin } = w.actors;
    const before = await salesTotals(owner);

    // 1. Кассир видит долг клиента (сводка; аудит customer.debt_viewed).
    const card = await t.req('get', `/customers/${cust.id}/receivables`, cashier);
    expect(card.status, JSON.stringify(card.body)).toBe(200);
    expect(card.body.overdueAmount).toEqual(money('8000.00'));

    // 2. Предпроверка «в долг» — мягкий отказ; POST /orders credit — 422 CREDIT_BLOCKED overdue (без обращения к 1С
    //    за долгом: снимок свежий, блокировка известна) + аудит credit.sale_blocked.
    const callsBefore = t.onec.callsOf('getCustomerReceivables').length;
    const cart = await t.cartFor(cashier, v, cust.id);
    const preview = await t.req('post', '/cart/checkout-preview', cashier).send({
      cartId: cart.id,
      cartRowVersion: cart.rowVersion,
      paymentMethod: 'credit',
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
    });
    expect(preview.status, JSON.stringify(preview.body)).toBe(200);
    expect(preview.body.paymentChecks).toMatchObject({ creditAllowed: false, creditReason: 'overdue' });
    const blocked = await t.order(cashier, cart, v, 'credit');
    expect(blocked.status, JSON.stringify(blocked.body)).toBe(422);
    expect(blocked.body).toMatchObject({ code: 'CREDIT_BLOCKED', creditReason: 'overdue' });
    expect(t.onec.callsOf('getCustomerReceivables').length).toBe(callsBefore);
    const blockedAudit = (await t.auditRows('credit.sale_blocked')).filter((a) => a.actor_user_id === cashier.userId);
    expect(blockedAudit.length).toBeGreaterThan(0);
    // Кассир не может разрешить сам (нет credit.sale.approve) — 403.
    const self = await t.order(
      cashier,
      cart,
      v,
      'credit',
      '1',
      { creditOverride: { reason: 'сам разрешу' } },
      await t.stepUp(cashier, 'credit.sale.approve'),
    );
    expect(self.status).toBe(403);

    // 3. Разрешение старшего в собственной сессии: без step-up → 403 STEP_UP_REQUIRED; со step-up → заказ в долг.
    const sCart = await t.cartFor(senior, v, cust.id);
    const noStep = await t.order(senior, sCart, v, 'credit', '1', {
      creditOverride: { reason: 'согласовано с руководителем, оплата до пятницы' },
    });
    expect(noStep.status).toBe(403);
    expect(noStep.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: 'credit.sale.approve' } });
    const approved = await t.order(
      senior,
      sCart,
      v,
      'credit',
      '1',
      { creditOverride: { reason: 'согласовано с руководителем, оплата до пятницы' } },
      await t.stepUp(senior, 'credit.sale.approve'),
    );
    expect([201, 202], JSON.stringify(approved.body)).toContain(approved.status);
    const creditOrder = approved.body as { id: string; total: { amount: string }; paymentMethod: string };
    expect(creditOrder.paymentMethod).toBe('credit');

    // 4. Оплата: кассир переключает свою корзину на наличные (FLOW-024.S2) и принимает оплату.
    const cur = (await t.req('get', '/cart', cashier)).body as { id: string; rowVersion: number };
    const cashOrder = await t.order(cashier, { ...cart, ...cur }, v, 'cash');
    expect([201, 202], JSON.stringify(cashOrder.body)).toContain(cashOrder.status);
    const cash = cashOrder.body as { id: string; total: { amount: string } };
    const paid = await t
      .req('post', `/orders/${cash.id}/payments`, cashier, { idem: true })
      .send({ method: 'cash', receivedAmount: { amount: cash.total.amount, currency: 'KGS' } });
    expect([200, 201], JSON.stringify(paid.body)).toContain(paid.status);
    expect(paid.body.status).toBe('received');
    // T-DEBT-001: сальдо — только снимок 1С; заказы и оплата в POS его не меняют (до синхронизации).
    const recAfter = await t.req('get', `/customers/${cust.id}/receivables`, cashier);
    expect(recAfter.body.balance).toEqual(card.body.balance);
    expect(recAfter.body.overdueAmount).toEqual(card.body.overdueAmount);
    expect(recAfter.body.asOf).toBe(card.body.asOf);

    // 5. Транзакции: ровно по одной строке на событие; журнал виден через API (summary — только read.all).
    const kinds = await t.q<{ order_id: string; kind: string; amount: string; actor_user_id: string | null }>(
      `SELECT order_id, kind::text AS kind, amount::text AS amount, actor_user_id FROM transactions
        WHERE order_id = ANY($1::uuid[]) ORDER BY occurred_at, id`,
      [[creditOrder.id, cash.id]],
    );
    const of = (id: string) =>
      kinds
        .filter((k) => k.order_id === id)
        .map((k) => k.kind)
        .sort();
    expect(of(creditOrder.id)).toEqual(['credit_sale_approved', 'order_created']);
    expect(of(cash.id)).toEqual(['order_created', 'payment_received']);
    expect(kinds.find((k) => k.kind === 'credit_sale_approved')?.actor_user_id).toBe(senior.userId);
    const list = await t.req('get', `/transactions?${period()}&customerId=${cust.id}&limit=200`, admin);
    expect(list.status, JSON.stringify(list.body)).toBe(200);
    const items = list.body.items as { id: string; kind: string; related: { kind: string; id: string }[] }[];
    expect(items.map((i) => i.kind).sort()).toEqual(
      ['credit_sale_approved', 'order_created', 'order_created', 'payment_received'].sort(),
    );
    expect(list.body.summary).toBeDefined();
    const sellerList = await t.req('get', `/transactions?${period()}&customerId=${cust.id}`, w.actors.seller);
    expect(sellerList.status).toBe(200);
    expect(sellerList.body.summary).toBeUndefined();
    expect(sellerList.body.items).toEqual([]); // seller видит только свои

    // Деталь транзакции разрешения: связи и аудит (audit.read).
    const approval = items.find((i) => i.kind === 'credit_sale_approved')!;
    const detail = await t.req('get', `/transactions/${approval.id}`, owner);
    expect(detail.status, JSON.stringify(detail.body)).toBe(200);
    expect((detail.body.related as { kind: string; id: string }[]).some((r) => r.id === creditOrder.id)).toBe(true);
    expect((detail.body.audit as { action: string }[]).map((a) => a.action)).toContain('credit.sale_approved');

    // 6. Аудит: разрешение — со step-up старшего; журнал аудита — chainOk; цепочка хэшей цела.
    const approvedAudit = await t.auditRows('credit.sale_approved', creditOrder.id);
    expect(approvedAudit).toHaveLength(1);
    expect(approvedAudit[0]).toMatchObject({ actor_user_id: senior.userId, step_up_method: 'pin' });
    expect((await t.auditRows('payment.received')).length).toBeGreaterThan(0);
    const logs = await t.req('get', `/admin/audit-logs?${period()}&entityId=${creditOrder.id}&limit=200`, owner);
    expect(logs.status, JSON.stringify(logs.body)).toBe(200);
    const rows = logs.body.items as { action: string; chainOk: boolean }[];
    expect(rows.map((r) => r.action)).toEqual(expect.arrayContaining(['order.created', 'credit.sale_approved']));
    expect(rows.every((r) => r.chainOk)).toBe(true);
    const chain = await verifyAuditChain(t.pool);
    expect(chain.ok, JSON.stringify(chain)).toBe(true);
    expect(chain.brokenAtChainSeq).toBeNull();

    // 7. Отчёт сходится с журналом: прирост продаж = Σ order_created; прирост оплат = Σ payment_received.
    const after = await salesTotals(owner);
    const created = sum(kinds.filter((k) => k.kind === 'order_created').map((k) => k.amount));
    const received = sum(kinds.filter((k) => k.kind === 'payment_received').map((k) => k.amount));
    expect(after.ordersCount - before.ordersCount).toBe(2);
    expect(Money.of(after.ordersTotal.amount).minus(Money.of(before.ordersTotal.amount)).toString()).toBe(created);
    expect(Money.of(after.paidTotal.amount).minus(Money.of(before.paidTotal.amount)).toString()).toBe(received);
    expect(created).toBe(sum([creditOrder.total.amount, cash.total.amount]));
    expect(received).toBe(Money.of(cash.total.amount).toString());

    // Дашборд кассира открывается (суммы смены — из журнала).
    expect((await t.req('get', '/pos/dashboard', cashier)).status).toBe(200);
  });
});

describe('возврат: черновик → submit → accept / reject (RM-G-005; RET-001…RET-010; RETURNS_FROM_POS_ENABLED=false)', () => {
  interface Shipped {
    readonly orderId: string;
    readonly unitId: string;
  }

  /** Отгруженный заказ клиента с реализацией 1С в реплике (строка 1: 10 × 100.00). */
  async function shippedOrder(): Promise<Shipped> {
    const o = await t.seedOrder({
      createdBy: w.actors.cashier,
      customerId: w.customers.debtWithinLimit.id,
      method: 'cash',
      status: 'awaiting_shipment',
      items: [{ variantId: v.variantId, quantity: '10' }],
    });
    await t.q(`UPDATE orders SET status = 'shipped', shipped_at = now() WHERE id = $1::uuid`, [o.orderId]);
    const s = await t.q<{ id: string }>(
      `INSERT INTO shipments (onec_ref, onec_code, onec_data_version, synced_at, source_hash, onec_doc_type, onec_date,
                              posted, order_id, customer_id, warehouse_id, total, discount_total, returned_total)
       VALUES (gen_random_uuid(), 'РТ-G-' || substr(md5(random()::text), 1, 6), 'AAAAAQ==', now(), 'test',
               'Document_РеализацияТоваровУслуг', now(), true, $1::uuid, $2::uuid, $3::uuid, 1000.00, 0, 0)
       RETURNING id`,
      [o.orderId, w.customers.debtWithinLimit.id, await t.defaultWarehouseId()],
    );
    await t.q(
      `INSERT INTO shipment_items (shipment_id, onec_line_no, variant_id, product_name_snapshot, quantity, base_quantity,
                                   unit_price, line_total, discount_amount, returned_quantity, synced_at, source_hash)
       VALUES ($1::uuid, 1, $2::uuid, $3, 10, 10, 100.00, 1000.00, 0, 0, now(), 'test')`,
      [s[0].id, v.variantId, v.productName],
    );
    return { orderId: o.orderId, unitId: v.unitId };
  }

  async function draftAndSubmit(s: Shipped, qty: string): Promise<{ id: string; rowVersion: number }> {
    const { cashier } = w.actors;
    const d = await t.req('post', '/returns', cashier, { idem: true }).send({
      orderId: s.orderId,
      reasonCode: 'defect',
      items: [{ orderLineNo: 1, quantity: { value: qty, unitId: s.unitId, packagingId: null } }],
    });
    expect(d.status, JSON.stringify(d.body)).toBe(201);
    expect(d.body.status).toBe('draft');
    const sub = await t
      .req('post', `/returns/${d.body.id}/submit`, cashier, {
        idem: true,
        stepUp: await t.stepUp(cashier, 'return.submit'),
      })
      .send({ rowVersion: d.body.rowVersion });
    expect(sub.status, JSON.stringify(sub.body)).toBe(200);
    expect(sub.body.status).toBe('submitted');
    return sub.body as { id: string; rowVersion: number };
  }

  it('T-RET-003, T-RET-008: количество ≤ отгружено − возвращено − в других заявках; две параллельные заявки на остаток — одна принята, вторая 422', async () => {
    const s = await shippedOrder();
    const { cashier } = w.actors;
    // В 1С уже возвращено 4 из 10 (проведённый «Возврат товаров от клиента»).
    await t.q(
      `UPDATE shipment_items SET returned_quantity = 4 WHERE shipment_id = (SELECT id FROM shipments WHERE order_id = $1::uuid)`,
      [s.orderId],
    );
    const body = (qty: string) => ({
      orderId: s.orderId,
      reasonCode: 'defect',
      items: [{ orderLineNo: 1, quantity: { value: qty, unitId: s.unitId, packagingId: null } }],
    });
    const over = await t.req('post', '/returns', cashier, { idem: true }).send(body('7'));
    expect([over.status, over.body.code], JSON.stringify(over.body)).toEqual([422, 'RETURN_QTY_EXCEEDED']);
    const [r1, r2] = await Promise.all([
      t.req('post', '/returns', cashier, { idem: true }).send(body('4')),
      t.req('post', '/returns', cashier, { idem: true }).send(body('4')),
    ]);
    expect([r1.status, r2.status].sort(), JSON.stringify([r1.body, r2.body])).toEqual([201, 422]);
    expect([r1, r2].find((r) => r.status === 422)?.body.code).toBe('RETURN_QTY_EXCEEDED');
    const open = await t.q<{ n: string }>(
      `SELECT coalesce(sum(i.quantity), 0)::text AS n FROM return_request_items i
         JOIN return_requests r ON r.id = i.return_request_id
         JOIN shipment_items si ON si.id = i.shipment_item_id
         JOIN shipments sh ON sh.id = si.shipment_id
        WHERE sh.order_id = $1::uuid AND r.status IN ('draft', 'submitted', 'accepted')`,
      [s.orderId],
    );
    expect(Number(open[0].n)).toBe(4); // money-double: allow — количество (шт.), не деньги
  });

  it('accept и reject старшим со step-up; return_requested в журнале; аудит; outbox в 1С не создаётся', async () => {
    const s = await shippedOrder();
    const { senior_seller: senior, cashier } = w.actors;
    const a = await draftAndSubmit(s, '2');
    // кассир согласовать не может; старший без step-up — STEP_UP_REQUIRED
    expect(
      (await t.req('post', `/returns/${a.id}/accept`, cashier, { idem: true }).send({ rowVersion: a.rowVersion }))
        .status,
    ).toBe(403);
    const noStep = await t
      .req('post', `/returns/${a.id}/accept`, senior, { idem: true })
      .send({ rowVersion: a.rowVersion });
    expect([noStep.status, noStep.body.code]).toEqual([403, 'STEP_UP_REQUIRED']);
    const accepted = await t
      .req('post', `/returns/${a.id}/accept`, senior, {
        idem: true,
        stepUp: await t.stepUp(senior, 'return.approve'),
      })
      .send({ rowVersion: a.rowVersion });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    expect(accepted.body.status).toBe('accepted');

    const r = await draftAndSubmit(s, '1');
    const rejected = await t
      .req('post', `/returns/${r.id}/reject`, senior, {
        idem: true,
        stepUp: await t.stepUp(senior, 'return.approve'),
      })
      .send({ rowVersion: r.rowVersion, reason: 'Товар без дефекта по результатам осмотра' });
    expect(rejected.status, JSON.stringify(rejected.body)).toBe(200);
    expect(rejected.body.status).toBe('rejected');

    const txn = await t.q<{ return_request_id: string; kind: string }>(
      `SELECT return_request_id, kind::text AS kind FROM transactions WHERE return_request_id = ANY($1::uuid[])`,
      [[a.id, r.id]],
    );
    expect(txn.map((x) => x.kind)).toEqual(['return_requested', 'return_requested']);
    for (const id of [a.id, r.id]) {
      expect((await t.auditRows('return.requested', id)).length).toBe(1);
      expect((await t.auditRows('return.submitted', id)).length).toBe(1);
      const changed = await t.auditRows('return.status_changed', id);
      expect(changed.at(-1)).toMatchObject({ actor_user_id: senior.userId, step_up_method: 'pin' });
    }
    expect(
      await t.q(
        `SELECT 1 FROM onec_outbox WHERE aggregate_type = 'return_request' AND aggregate_id = ANY($1::uuid[])`,
        [[a.id, r.id]],
      ),
    ).toEqual([]);
    const listed = await t.req('get', `/returns?limit=50`, w.actors.owner);
    expect(listed.status).toBe(200);
    expect((listed.body.items as { id: string }[]).map((x) => x.id)).toEqual(expect.arrayContaining([a.id, r.id]));
  });
});

describe('создание клиента → outbox → 1С (RM-G-001; CUST-010…CUST-015)', () => {
  it('кассир создаёт клиента: 201 pending → outbox customer → 1С 201 → onec_ref; поиск по телефону; аудит', async () => {
    const phone = `+99655${String(Date.now() % 10_000_000).padStart(7, '0')}`;
    const res = await t
      .req('post', '/customers', w.actors.cashier, { idem: true })
      .send({ name: 'Сквозной Клиент Кассы', customerType: 'individual', phones: [phone] });
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    const id = res.body.id as string;
    expect(res.body).toMatchObject({ onecStatus: 'pending', onecRef: null });
    const ob = await t.q<{ status: string }>(
      `SELECT status::text AS status FROM onec_outbox WHERE aggregate_type = 'customer' AND aggregate_id = $1::uuid`,
      [id],
    );
    expect(ob).toEqual([{ status: 'pending' }]);
    await t.drainOutbox();
    const row = (
      await t.q<{ onec_status: string; onec_ref: string | null }>(
        `SELECT onec_status::text AS onec_status, onec_ref::text AS onec_ref FROM customers WHERE id = $1::uuid`,
        [id],
      )
    )[0];
    expect(row.onec_status).toBe('confirmed');
    expect(row.onec_ref).not.toBeNull();
    expect(t.cashier.allPartners().find((p) => p.externalId === id)?.ref).toBe(row.onec_ref);
    expect(t.onec.callsOf('createCustomer').length).toBeGreaterThan(0);
    const card = await t.req('get', `/customers/${id}`, w.actors.cashier);
    expect(card.body).toMatchObject({ onecStatus: 'confirmed', onecRef: row.onec_ref });
    const found = await t.req('get', `/search/customers?q=${encodeURIComponent(phone.slice(-4))}`, w.actors.cashier);
    expect(found.status, JSON.stringify(found.body)).toBe(200);
    expect((found.body.items as { id: string }[]).map((x) => x.id)).toContain(id);
    // Прикладная запись (актор, forceCreate) — ровно одна; построчная запись уровня БД (триггер `customers`) — отдельно.
    const created = await t.auditRows('customer.created', id);
    expect(created.filter((a) => a.after?.forceCreate === false)).toHaveLength(1);
    expect(created.find((a) => a.after?.forceCreate === false)?.actor_user_id).toBe(w.actors.cashier.userId);
    // Повтор ключа идемпотентности — тот же клиент, второго нет.
    const dup = await t
      .req('post', '/customers', w.actors.cashier, { idem: true })
      .send({ name: 'Дубль По Телефону', customerType: 'individual', phones: [phone] });
    expect(dup.status).toBe(409);
    expect(dup.body.code).toBe('CUSTOMER_DUPLICATE_SUSPECTED');
  });
});

describe('отчёты сходятся с данными (T-ADMIN-006)', () => {
  it('receivables: итог = Σ положительных сальдо снимков 1С (без пометки удаления); роли', async () => {
    const rows = await t.q<{ balance: string; overdue: string | null }>(
      `SELECT r.balance::text AS balance, r.overdue_amount::text AS overdue
         FROM receivables r JOIN customers c ON c.id = r.customer_id WHERE NOT c.deletion_mark`,
    );
    const debt = rows.filter((x) => Money.of(x.balance).compare(Money.ZERO) > 0);
    const overdue = rows.filter((x) => x.overdue !== null && Money.of(x.overdue).compare(Money.ZERO) > 0);
    const r = await t.req('get', '/admin/reports/receivables', w.actors.owner);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body).toMatchObject({
      totalBalance: money(sum(debt.map((x) => x.balance))),
      totalOverdue: money(sum(overdue.map((x) => x.overdue!))),
      customersCount: debt.length,
      overdueCount: overdue.length,
    });
    for (const role of ['seller', 'cashier', 'senior_seller', 'customer'] as const) {
      expect((await t.req('get', '/admin/reports/receivables', w.actors[role])).status, role).toBe(403);
    }
    const qr = await t.req('get', `/admin/reports/qr-reconciliation?${period()}`, w.actors.admin);
    expect(qr.status).toBe(200);
  });
});

describe('режим клиента (RM-G-014; CUST-023, CUST-024; T-SEC-016)', () => {
  it('confirmed — своя карточка, долг и история; proposed/чужая — 404; кассовые и админ-операции — 403', async () => {
    const buyer = w.customers.buyer.id;
    const me = w.buyerConfirmed;
    expect((await t.req('get', `/customers/${buyer}`, me)).status).toBe(200);
    const rec = await t.req('get', `/customers/${buyer}/receivables`, me);
    expect(rec.status, JSON.stringify(rec.body)).toBe(200);
    expect(rec.body.customerId).toBe(buyer);
    const hist = await t.req('get', `/customers/${buyer}/orders`, me);
    expect(hist.status, JSON.stringify(hist.body)).toBe(200);
    expect((hist.body.items as unknown[]).length).toBeGreaterThan(0);
    for (const path of [`/customers/${buyer}`, `/customers/${buyer}/receivables`, `/customers/${buyer}/orders`]) {
      expect((await t.req('get', path, w.buyerProposed)).status, path).toBe(404);
    }
    expect((await t.req('get', `/customers/${w.customers.overdue.id}`, me)).status).toBe(404);
    for (const path of [
      `/transactions?${period()}`,
      '/pos/dashboard',
      '/returns',
      `/admin/audit-logs?${period()}`,
      '/receivables/overdue',
      '/favorites/customers',
    ]) {
      const r = await t.req('get', path, me);
      expect([r.status, r.body.code], path).toEqual([403, 'FORBIDDEN']);
    }
    // Продажа в долг в режиме клиента недоступна (forbidden_role), независимо от долга.
    const cart = await t.cartFor(me, v, null);
    const credit = await t.order(me, cart, v, 'credit');
    expect([credit.status, credit.body.creditReason]).toEqual([403, 'forbidden_role']);
    expect((await t.req('post', '/customers', me, { idem: randomUUID() }).send({})).status).toBe(403);
  });
});

describe('результаты 1С по клиенту: очереди pg-boss pos-worker и сверщик потерянных результатов (customers/jobs)', () => {
  type JobFn = (jobs: { data: unknown }[]) => Promise<unknown>;
  const newPhone = () => `+99655${String(Math.floor(Math.random() * 10_000_000)).padStart(7, '0')}`;

  it('мост регистрирует очереди (гонка createQueue), события применяются идемпотентно; сверщик подбирает потерянные; ссылка занята → duplicate', async () => {
    const { cashier } = w.actors;
    // A — 1С создаст клиента (результат «потерян»); B — 1С найдёт дубль по телефону (результат «потерян»).
    const a = await t
      .req('post', '/customers', cashier, { idem: true })
      .send({ name: 'Потерянный Результат', customerType: 'individual', phones: [newPhone()] });
    expect(a.status, JSON.stringify(a.body)).toBe(201);
    const phoneB = newPhone();
    t.cashier.createCustomer({
      externalId: randomUUID(),
      name: 'Карточка Уже В 1С',
      phone: phoneB,
      kind: 'individual',
      dedupe: { byPhone: true, failOnDuplicate: true },
    });
    t.onec.script('findCustomersByPhone', { transport: true });
    const b = await t
      .req('post', '/customers', cashier, { idem: true })
      .send({ name: 'Дубль Из Кассы', customerType: 'individual', phones: [phoneB] });
    expect(b.status, JSON.stringify(b.body)).toBe(201);
    const c = await t
      .req('post', '/customers', cashier, { idem: true })
      .send({ name: 'Ссылка Уже Занята', customerType: 'individual', phones: [newPhone()] });
    expect(c.status, JSON.stringify(c.body)).toBe(201);
    const before = t.published.length;
    await t.q(`UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE status = 'pending'`);
    await t.dispatcher.tick(); // события опубликованы, но не применены
    const lost = t.published.slice(before).filter((p) => p.name.startsWith('customers.onec-'));
    expect(lost.map((p) => p.data.aggregateId)).toEqual(expect.arrayContaining([a.body.id, b.body.id, c.body.id]));

    // Мост pg-boss с фейком очередей: первая createQueue «проигрывает гонку» — очередь уже создана другим процессом.
    const handlers = new Map<string, JobFn>();
    const queues = new Set<string>();
    let race = true;
    const boss = {
      getQueue: (n: string) => Promise.resolve(queues.has(n) ? { name: n } : null),
      createQueue: (n: string) => {
        queues.add(n);
        if (race) {
          race = false;
          return Promise.reject(new Error('queue already exists'));
        }
        return Promise.resolve();
      },
      work: (n: string, _o: unknown, fn: JobFn) => {
        handlers.set(n, fn);
        return Promise.resolve(randomUUID());
      },
    };
    const bridge = new CustomersJobsBridge({ WORKERS_ENABLED: true }, t.db, {
      start: () => Promise.resolve(),
      instance: boss,
    } as never);
    bridge.onApplicationBootstrap();
    await vi.waitFor(() =>
      expect([...handlers.keys()].sort()).toEqual(['customers.onec-confirmed', 'customers.onec-failed']),
    );
    expect(await handlers.get('customers.onec-confirmed')!([])).toBeUndefined();
    expect(await handlers.get('customers.onec-failed')!([])).toBeUndefined();

    // C: ссылка 1С уже принадлежит другой карточке реплики → POS-клиент помечается duplicate (GQ-CUS-02).
    const lostC = lost.find((p) => p.data.aggregateId === c.body.id)!;
    await t.q(
      `UPDATE onec_outbox SET onec_response = jsonb_set(coalesce(onec_response, '{}'::jsonb), '{ref}', to_jsonb($2::text))
        WHERE id = $1::uuid`,
      [lostC.data.outboxId, w.customers.noDebt.onecRef],
    );
    expect(await handlers.get('customers.onec-confirmed')!([{ data: lostC.data }])).toEqual({ outcome: 'applied' });

    // Сверщик: A — подтверждение (onec_ref из outbox), B — отказ 1С POS_E_DUPLICATE → duplicate.
    const rec = await bridge.results.reconcile();
    expect(rec.confirmed).toBeGreaterThanOrEqual(1);
    expect(rec.failed).toBeGreaterThanOrEqual(1);
    const rows = await t.q<{ id: string; onec_status: string; onec_ref: string | null }>(
      `SELECT id, onec_status::text AS onec_status, onec_ref::text AS onec_ref FROM customers WHERE id = ANY($1::uuid[])`,
      [[a.body.id, b.body.id, c.body.id]],
    );
    const by = new Map(rows.map((r) => [r.id, r]));
    expect(by.get(a.body.id)).toMatchObject({ onec_status: 'confirmed' });
    expect(by.get(a.body.id)?.onec_ref).not.toBeNull();
    expect(by.get(b.body.id)).toMatchObject({ onec_status: 'duplicate', onec_ref: null });
    expect(by.get(c.body.id)).toMatchObject({ onec_status: 'duplicate', onec_ref: null });

    // Повторная доставка событий — без изменений (идемпотентно по outboxId).
    for (const p of lost.filter((x) => x.data.aggregateId !== c.body.id)) {
      expect(await handlers.get(p.name)!([{ data: p.data }]), p.name).toEqual({ outcome: 'skipped' });
    }
    expect(await bridge.results.reconcile()).toEqual({ confirmed: 0, failed: 0 });
    bridge.onApplicationShutdown();

    // Без воркеров / без pg-boss — ничего не регистрируется; сбой старта pg-boss только журналируется.
    new CustomersJobsBridge({ WORKERS_ENABLED: false }, t.db, undefined).onApplicationBootstrap();
    new CustomersJobsBridge({ WORKERS_ENABLED: true }, t.db, {
      start: () => Promise.resolve(),
      instance: undefined,
    } as never).onApplicationBootstrap();
    const failing = new CustomersJobsBridge({ WORKERS_ENABLED: true }, t.db, {
      start: () => Promise.reject(new Error('pg-boss недоступен')),
      instance: undefined,
    } as never);
    failing.onApplicationBootstrap();
    failing.onApplicationShutdown();
    await new Promise((r) => setTimeout(r, 20));
  });
});

describe('AC-SYNC-049: заказ нового POS-клиента уходит в 1С после его карточки (05 SYNC-042, SYNC-049; ревью G-customers-1c-1)', () => {
  it('outbox заказа зависит от customer/create; до подтверждения клиента заказ не отправляется; в 1С — customer.ref клиента', async () => {
    const phone = `+99655${String(Math.floor(Math.random() * 10_000_000)).padStart(7, '0')}`;
    const c = await t
      .req('post', '/customers', w.actors.cashier, { idem: true })
      .send({ name: 'Новый Для Заказа', customerType: 'individual', phones: [phone] });
    expect(c.status, JSON.stringify(c.body)).toBe(201);
    const customerId = c.body.id as string;
    const cart = await t.cartFor(w.actors.cashier, v, customerId);
    const o = await t.order(w.actors.cashier, cart, v, 'cash');
    expect([201, 202], JSON.stringify(o.body)).toContain(o.status);
    const orderId = o.body.id as string;
    const outbox = async () =>
      t.q<{ aggregate_type: string; id: string; status: string; dep: string | null }>(
        `SELECT aggregate_type::text AS aggregate_type, id, status::text AS status, depends_on_outbox_id::text AS dep
           FROM onec_outbox WHERE aggregate_id IN ($1::uuid, $2::uuid) ORDER BY created_at`,
        [customerId, orderId],
      );
    const [cust, ord] = await outbox();
    expect(cust).toMatchObject({ aggregate_type: 'customer', status: 'pending' });
    expect(ord).toMatchObject({ aggregate_type: 'order', status: 'pending', dep: cust.id });

    // 1С недоступна для клиента: заказ не захватывается, хотя его next_attempt_at наступил.
    const createOrders = () => t.onec.callsOf('createOrder').length;
    const before = createOrders();
    t.onec.always('createOrder', null);
    t.onec.always('createCustomer', { transport: true });
    try {
      await t.drainOutbox();
      expect((await outbox())[1].status).toBe('pending');
      expect(t.onec.callsOf('createOrder').some((a) => (a[0] as { externalId?: string }).externalId === orderId)).toBe(
        false,
      );
      t.onec.always('createCustomer', null);
      await t.q(`UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE id = $1`, [cust.id]);
      await t.drainOutbox(); // клиент → sent (Ref 1С), подтверждение применено
      await t.drainOutbox(); // заказ → 1С с ссылкой клиента
    } finally {
      t.onec.always('createOrder', { transport: true });
      t.onec.always('createCustomer', null);
    }
    const ref = (
      await t.q<{ r: string | null }>(`SELECT onec_ref::text AS r FROM customers WHERE id = $1`, [customerId])
    )[0].r;
    expect(ref).not.toBeNull();
    const sent = t.onec
      .callsOf('createOrder')
      .slice(before)
      .map((a) => a[0] as { externalId?: string; customer?: { ref: string | null } })
      .filter((b) => b.externalId === orderId);
    expect(sent.length).toBeGreaterThan(0);
    expect(sent.every((b) => b.customer?.ref === ref)).toBe(true);
  });
});

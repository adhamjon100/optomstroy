import {
  AUDIT_QUERY_PORT,
  CREDIT_DECISION_SERVICE,
  CUSTOMER_READER,
  DISCOUNT_POLICY_PORT,
  RECEIVABLES_SNAPSHOT_PORT,
  SALES_PORT_TOKENS,
  type SalesActor,
  TRANSACTIONS_WRITER,
} from '../../src/common/ports/index.js';
import { TransactionJournal, transactionDedupeKey } from '../../src/common/journal/index.js';
import { FailClosedCreditDecisionService } from '../../src/sales-domain/adapters/fail-closed-credit.js';
import { createSalesPortRegistry } from '../../src/sales-domain/sales-ports.module.js';
import {
  createFakeCashierPorts,
  customerCard,
  customerFieldPolicyFor,
  InMemoryAuditQuery,
  InMemoryCustomerReader,
  InMemoryReceivablesSnapshots,
  InMemoryTransactionsWriter,
  StubDiscountPolicy,
} from '../support/cashier-ports.fakes.js';

/** Порты этапа G (`common/ports`): токены в реестре, реализации по умолчанию, заглушки для тестов агентов G. */
const actor = (roles: string[], isCustomer = false, userId = 'u-1'): SalesActor => ({ userId, roles, isCustomer });

describe('порты G в SalesPortRegistry', () => {
  it('токены G входят в SALES_PORT_TOKENS (DI-прокси создаёт SalesPortsModule)', () => {
    for (const t of [
      CUSTOMER_READER,
      RECEIVABLES_SNAPSHOT_PORT,
      DISCOUNT_POLICY_PORT,
      TRANSACTIONS_WRITER,
      AUDIT_QUERY_PORT,
    ]) {
      expect(SALES_PORT_TOKENS).toContain(t);
    }
    expect(new Set(SALES_PORT_TOKENS).size).toBe(SALES_PORT_TOKENS.length);
  });

  it('по умолчанию: долг — fail-closed этапа F, журнал — TransactionJournal; привязка G заменяет умолчание', () => {
    const r = createSalesPortRegistry();
    expect(r.get(CREDIT_DECISION_SERVICE)).toBeInstanceOf(FailClosedCreditDecisionService);
    expect(r.get(TRANSACTIONS_WRITER)).toBeInstanceOf(TransactionJournal);
    const fake = new InMemoryTransactionsWriter();
    r.bind(TRANSACTIONS_WRITER, fake);
    expect(r.get(TRANSACTIONS_WRITER)).toBe(fake);
  });

  it('createFakeCashierPorts подменяет порты G, кроме keep; долг — только с withCredit', () => {
    const r = createSalesPortRegistry();
    const keepReader = new InMemoryCustomerReader();
    r.bind(CUSTOMER_READER, keepReader);
    const f = createFakeCashierPorts(r, [CUSTOMER_READER]);
    expect(r.get(CUSTOMER_READER)).toBe(keepReader);
    expect(r.get(RECEIVABLES_SNAPSHOT_PORT)).toBe(f.receivables);
    expect(r.get(TRANSACTIONS_WRITER)).toBe(f.transactions);
    expect(r.get(CREDIT_DECISION_SERVICE)).toBeInstanceOf(FailClosedCreditDecisionService);
    createFakeCashierPorts(r, [], { withCredit: true });
    expect(r.get(CREDIT_DECISION_SERVICE).constructor.name).toBe('ScriptedCreditDecision');
  });
});

describe('заглушки портов G', () => {
  it('customerFieldPolicyFor: продавец без сумм (Q-017), кассир/старший/админ/владелец — суммы, клиент — self', () => {
    expect(customerFieldPolicyFor(actor(['seller']))).toMatchObject({
      view: 'seller',
      receivableAmounts: false,
      fullContacts: false,
    });
    for (const r of ['cashier', 'senior_seller']) {
      expect(customerFieldPolicyFor(actor([r]))).toMatchObject({
        view: 'cashier',
        receivableAmounts: true,
        favorites: true,
      });
    }
    for (const r of ['admin', 'owner']) expect(customerFieldPolicyFor(actor([r]))).toMatchObject({ view: 'admin' });
    expect(customerFieldPolicyFor(actor(['customer'], true))).toMatchObject({ view: 'self', serviceFields: false });
  });

  it('InMemoryCustomerReader: покупатель видит только свою карточку при confirmed (иначе null → 404)', async () => {
    const r = new InMemoryCustomerReader().put(customerCard({ id: 'c-1' })).put(customerCard({ id: 'c-2' }));
    r.link('buyer', 'c-1', 'confirmed').link('pending', 'c-1', 'proposed');
    expect(await r.getForActor(null, actor(['customer'], true, 'buyer'), 'c-1')).toMatchObject({
      access: { kind: 'self' },
    });
    expect(await r.getForActor(null, actor(['customer'], true, 'buyer'), 'c-2')).toBeNull();
    expect(await r.getForActor(null, actor(['customer'], true, 'pending'), 'c-1')).toBeNull();
    expect(await r.getForActor(null, actor(['seller']), 'c-2')).toMatchObject({ access: { kind: 'staff' } });
  });

  it('InMemoryReceivablesSnapshots: возраст, пригодность для долга, сценарий refresh', async () => {
    const s = new InMemoryReceivablesSnapshots();
    s.set('c', { balance: '100.00', overdueAmount: '0.00', ageMinutes: 90 });
    expect(await s.snapshot(null, 'c')).toMatchObject({ isStale: true, usableForCredit: false });
    s.refreshScript.push('unavailable');
    expect(await s.refresh('c')).toMatchObject({ kind: 'unavailable' });
    expect(await s.refresh('c')).toMatchObject({
      kind: 'refreshed',
      snapshot: { isStale: false, usableForCredit: true },
    });
    s.set('i', { balance: '100.00', overdueAmount: null });
    expect(await s.snapshot(null, 'i')).toMatchObject({ usableForCredit: false, isStale: false });
    expect(await s.snapshot(null, 'none')).toBeNull();
  });

  it('StubDiscountPolicy: лимит — максимум по ролям seed; подтверждение сверх лимита — senior_seller/admin', async () => {
    const d = new StubDiscountPolicy();
    expect(await d.limitFor(null, actor(['seller']))).toBe('5.00');
    expect(await d.limitFor(null, actor(['seller', 'senior_seller']))).toBe('10.00');
    expect(await d.limitFor(null, actor(['customer'], true))).toBe('0.00');
    expect(await d.canApproveOverLimit(null, actor(['cashier']), '7.00')).toBe(false);
    expect(await d.canApproveOverLimit(null, actor(['admin']), '20.00')).toBe(true);
  });

  it('InMemoryTransactionsWriter: идемпотентность по dedupeKey, ссылка обязательна', async () => {
    const w = new InMemoryTransactionsWriter();
    const input = {
      kind: 'discount_override' as const,
      orderId: 'o-1',
      amount: '50.00',
      statusSnapshot: 'submitting',
      title: 'Скидка',
      dedupeKey: transactionDedupeKey.order('discount_override', 'o-1'),
    };
    const a = await w.record(null, input);
    expect(await w.record(null, input)).toEqual({ created: false, id: a.id });
    await expect(w.record(null, { ...input, orderId: null, dedupeKey: 'x' })).rejects.toThrow();
    expect(w.ofKind('discount_override')).toHaveLength(1);
  });

  it('InMemoryAuditQuery: фильтр по префиксу действия и объекту', async () => {
    const q = new InMemoryAuditQuery();
    const row = (action: string, entityId: string, at: string) => ({
      id: `${action}-${entityId}`,
      chainSeq: '1',
      occurredAt: new Date(at),
      requestId: null,
      actorUserId: null,
      actorName: null,
      actorRole: null,
      sessionId: null,
      deviceId: null,
      ip: null,
      appVersion: null,
      action,
      entityType: 'return_request',
      entityId,
      onecRef: null,
      before: null,
      after: null,
      result: 'ok' as const,
      stepUpMethod: null,
      reason: null,
      rowHash: 'aa',
      chainOk: true,
    });
    q.rows.push(
      row('return.submitted', 'r1', '2026-10-21T10:00:00Z'),
      row('order.created', 'o1', '2026-10-21T11:00:00Z'),
    );
    const page = await q.list(null, actor(['admin']), {
      from: new Date('2026-10-21T00:00:00Z'),
      to: new Date('2026-10-22T00:00:00Z'),
      action: 'return.*',
    });
    expect(page.items.map((i) => i.id)).toEqual(['return.submitted-r1']);
    expect(await q.forEntity(null, actor(['admin']), 'return_request', 'r1')).toHaveLength(1);
    expect((await q.verifyChain()).ok).toBe(true);
  });
});

describe('transactionDedupeKey — форматы этапа F сохранены', () => {
  it('заказ, платёж, заявка, документ 1С', () => {
    const at = new Date('2026-10-21T08:30:00Z');
    expect(transactionDedupeKey.order('order_created', 'o')).toBe('order_created:o');
    expect(transactionDedupeKey.payment('payment_received', 'p', at)).toBe(
      'payment_received:p:2026-10-21T08:30:00.000Z',
    );
    expect(transactionDedupeKey.returnRequested('r')).toBe('return_requested:r');
    expect(transactionDedupeKey.onecDocument('refund', 'x')).toBe('refund:onec:x');
  });
});

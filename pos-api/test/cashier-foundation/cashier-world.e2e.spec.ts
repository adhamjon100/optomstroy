import { Money } from '../../src/common/money/money.js';
import { TransactionJournal, TransactionJournalError, transactionDedupeKey } from '../../src/common/journal/index.js';
import {
  AUDIT_QUERY_PORT,
  CREDIT_DECISION_SERVICE,
  CUSTOMER_READER,
  type CustomerReader,
  DISCOUNT_POLICY_PORT,
  PortNotBoundError,
  RECEIVABLES_SNAPSHOT_PORT,
  SalesPortRegistry,
  TRANSACTIONS_WRITER,
} from '../../src/common/ports/index.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import { CASHIER_SCENARIOS } from '../../src/integrations/onec/synthetic-cashier.js';
import { insertOrderTransaction } from '../../src/orders/order-projection.js';
import { PaymentJournal } from '../../src/payments/infra/payment-journal.js';
import { PaymentsRepository } from '../../src/payments/infra/payments.repository.js';
import { decideCredit, type CreditDecision } from '../../src/sales-domain/credit/credit-decision.js';
import { type CashierCustomerKey, CashierTestApp, type CashierWorld } from '../support/cashier-fixture.js';

/**
 * Основа этапа G на embedded PostgreSQL 17 (**тестовые данные**): хелпер `cashier-fixture` (реплика 1С кассира в БД,
 * пользователи, привязки, избранное, заказы), согласованность БД и фейка 1С, матрица сценариев долга по чистой
 * функции PAY-031, журнал `transactions` (`TransactionJournal`) и события F через него, порты G в реестре.
 */
let t: CashierTestApp;
let w: CashierWorld;

beforeAll(async () => {
  t = await new CashierTestApp().start({ env: { QR_PROVIDER: 'none' } });
  w = await t.seedCashierWorld();
}, 600_000);

afterAll(async () => {
  await t?.stop();
});

describe('cashier-fixture — состав мира кассира', () => {
  it('клиенты 1С синтетики загружены с контактами; сценарные — с ожидаемыми условиями', async () => {
    const partners = t.cashier.allPartners();
    expect(w.customerIdByRef.size).toBe(partners.length);
    const rows = await t.q<{ id: string; credit_allowed: boolean; credit_limit: string | null; phones: number }>(
      `SELECT c.id, c.credit_allowed, c.credit_limit::text AS credit_limit,
              (SELECT count(*)::int FROM customer_contacts cc WHERE cc.customer_id = c.id AND cc.kind = 'phone') AS phones
         FROM customers c WHERE c.source_hash = 'cashier-fixture'`,
    );
    expect(rows).toHaveLength(partners.length);
    expect(rows.every((r) => r.phones >= 1)).toBe(true);
    const byId = new Map(rows.map((r) => [r.id, r]));
    expect(byId.get(w.customers.noLimit.id)).toMatchObject({ credit_allowed: true, credit_limit: null });
    expect(byId.get(w.customers.creditNotAllowed.id)).toMatchObject({ credit_allowed: false });
    expect(byId.get(w.customers.overLimit.id)).toMatchObject({ credit_limit: '50000.00' });
    expect(w.customers.posPending.onecRef).toBeNull();
    expect(w.customers.retail.id).toBe('00000000-0000-7000-8000-000000000201');
  });

  it('снимки долга: свежие, устаревший (stale), неполный (incomplete), без снимка (noSnapshot)', async () => {
    const stale = await t.receivablesRow(w.customers.stale.id);
    expect(Date.now() - new Date(stale.onec_snapshot_at).getTime()).toBeGreaterThan(60 * 60_000);
    const fresh = await t.receivablesRow(w.customers.debtWithinLimit.id);
    expect(fresh).toMatchObject({ balance: '12300.00', overdue_amount: '0.00' });
    expect(Date.now() - new Date(fresh.onec_snapshot_at).getTime()).toBeLessThan(30 * 60_000);
    expect((await t.receivablesRow(w.customers.incomplete.id)).overdue_amount).toBeNull();
    expect(await t.receivablesRow(w.customers.noSnapshot.id)).toBeUndefined();
    expect(await t.receivablesRow(w.customers.posPending.id)).toBeUndefined();
    // Детализация: Σ остатков документов = сальдо по каждому клиенту; виды и статусы — из словаря 07.
    const mismatch = await t.q(
      `SELECT r.customer_id FROM receivables r
         LEFT JOIN receivable_documents d ON d.customer_id = r.customer_id AND d.superseded_at IS NULL
        GROUP BY r.customer_id, r.balance HAVING coalesce(sum(d.remaining), 0) <> r.balance`,
    );
    expect(mismatch).toEqual([]);
    const kinds = await t.q<{ kind: string; status: string }>(
      `SELECT DISTINCT kind, status FROM receivable_documents WHERE customer_id = $1::uuid ORDER BY kind, status`,
      [w.customers.buyer.id],
    );
    expect(kinds.map((k) => k.kind)).toEqual(['adjustment', 'invoice', 'payment', 'return']);
    const due = await t.q<{ status: string }>(`SELECT status FROM receivable_documents WHERE customer_id = $1::uuid`, [
      w.customers.overdue.id,
    ]);
    expect(due).toEqual([{ status: 'due' }]);
  });

  it('реализации — только в глубине SALES_HISTORY_MONTHS; строки ссылаются на варианты каталога БД', async () => {
    const buyer = await t.q<{ n: number; min: string }>(
      `SELECT count(*)::int AS n, to_char(min(onec_date AT TIME ZONE 'Asia/Bishkek'), 'YYYY-MM-DD') AS min
         FROM shipments WHERE customer_id = $1::uuid`,
      [w.customers.buyer.id],
    );
    expect(buyer[0].n).toBe(12);
    expect(buyer[0].min >= w.historyFrom).toBe(true);
    const unresolved = await t.q(`SELECT id FROM shipment_items WHERE variant_id IS NULL`);
    expect(unresolved).toEqual([]);
    // Возврат, уже проведённый в 1С, отражён в реализации.
    const ret = await t.q<{ returned_quantity: string }>(
      `SELECT returned_quantity::text AS returned_quantity FROM shipment_items WHERE returned_quantity > 0`,
    );
    expect(ret).toEqual([{ returned_quantity: '1.000' }]);
    expect(w.shipments.fixture.customerId).toBe(w.customers.debtWithinLimit.id);
    expect(w.shipments.buyerLatest.orderId).toBe(w.orders.buyerShipped.orderId);
    const order = await t.q<{ status: string; order_id: string }>(
      `SELECT o.status::text AS status, s.order_id FROM orders o JOIN shipments s ON s.order_id = o.id WHERE o.id = $1::uuid`,
      [w.orders.buyerShipped.orderId],
    );
    expect(order).toEqual([{ status: 'shipped', order_id: w.orders.buyerShipped.orderId }]);
  });

  it('правила скидок, лимиты ролей seed, привязки покупателей, избранное, заявка клиента', async () => {
    const rules = await t.q<{ onec_ref: string; conditions: Record<string, unknown> }>(
      `SELECT onec_ref, conditions FROM discount_rules WHERE source = 'onec' ORDER BY onec_ref`,
    );
    expect(rules).toHaveLength(5);
    expect(rules[0].conditions).toEqual({ customerIds: [w.customers.buyer.id, w.customers.debtWithinLimit.id] });
    const limits = await t.q<{ role: string; max_percent: string }>(
      `SELECT role::text AS role, max_percent::text AS max_percent FROM role_discount_limits ORDER BY role`,
    );
    expect(Object.fromEntries(limits.map((l) => [l.role, l.max_percent]))).toMatchObject({
      seller: '5.00',
      cashier: '5.00',
      senior_seller: '10.00',
      admin: '15.00',
      owner: '0.00',
    });
    const links = await t.q<{ user_id: string; status: string }>(
      `SELECT user_id, status::text AS status FROM customer_links WHERE customer_id = $1::uuid ORDER BY status`,
      [w.customers.buyer.id],
    );
    expect(links).toEqual([
      { user_id: w.buyerConfirmed.userId, status: 'confirmed' },
      { user_id: w.buyerProposed.userId, status: 'proposed' },
    ]);
    const fav = await t.q(`SELECT customer_id FROM favorites_customers WHERE user_id = $1::uuid`, [
      w.actors.cashier.userId,
    ]);
    expect(fav).toHaveLength(2);
    const req = await t.q<{ created_via: string; status: string }>(
      `SELECT created_via, status::text AS status FROM orders WHERE id = $1::uuid`,
      [w.orders.buyerRequest.orderId],
    );
    expect(req).toEqual([{ created_via: 'customer', status: 'awaiting_payment' }]);
    expect(Object.keys(w.actors).sort()).toEqual(['admin', 'cashier', 'customer', 'owner', 'seller', 'senior_seller']);
  });
});

describe('cashier-fixture — согласованность с фейком 1С', () => {
  it('обновление снимка из 1С: тот же клиент, свежий snapshotAt, суммы совпадают с БД (кроме stale-возраста)', async () => {
    const r = await t.onec.getCustomerReceivables(w.customers.stale.onecRef!);
    expect(r.body).toMatchObject({ customerRef: w.customers.stale.onecRef, balance: '2000.00' });
    expect(Math.abs(Date.parse(r.body.snapshotAt as string) - Date.now())).toBeLessThan(5_000);
    expect((await t.receivablesRow(w.customers.stale.id)).balance).toBe('2000.00');
    // Клиент без снимка в БД: в 1С снимок есть — обновление возможно.
    await expect(t.onec.getCustomerReceivables(w.customers.noSnapshot.onecRef!)).resolves.toMatchObject({
      status: 200,
    });
    // 1С недоступна — сценарий ScriptedOnecGateway.
    t.onec.script('getCustomerReceivables', { transport: true });
    await expect(t.onec.getCustomerReceivables(w.customers.stale.onecRef!)).rejects.toBeInstanceOf(OnecError);
  });

  it('создание клиента с телефоном клиента 1С → 409 с кандидатом, ссылка которого есть в БД (CUSTOMER_DUPLICATE_SUSPECTED)', async () => {
    const e = (await t.onec
      .createCustomer({
        externalId: '0192f5b1-1111-7aaa-8bbb-0000000000b1',
        name: 'Дубль Клиента',
        phone: w.customers.overdue.phone!,
        kind: 'individual',
        dedupe: { byPhone: true, failOnDuplicate: true },
      })
      .catch((x: unknown) => x)) as OnecError;
    expect(e).toMatchObject({ status: 409, code: 'POS_E_DUPLICATE' });
    const ref = (e.details as { candidates: { ref: string }[] }).candidates[0].ref;
    expect(w.customerIdByRef.get(ref)).toBe(w.customers.overdue.id);
  });

  it('возврат по реализации фикстуры: строка 1С и shipment_items совпадают по номеру строки', async () => {
    const s = t.cashier.shipment(w.shipments.fixture.onecRef)!;
    expect(Object.keys(w.shipments.fixture.itemIds).map(Number).sort()).toEqual(s.lines.map((l) => l.lineNumber));
    const res = await t.onec.createReturnRequest({
      externalId: '0192f5d2-3333-7ccc-8ddd-0000000000b1',
      shipmentRef: s.ref,
      orderExternalId: null,
      customerRef: w.customers.debtWithinLimit.onecRef!,
      reasonCode: 'defect',
      reasonText: 'Течёт',
      requestedAt: '2026-10-22T10:15:00+06:00',
      lines: [
        {
          shipmentLineNumber: 1,
          productRef: s.lines[0].productRef,
          variantRef: s.lines[0].variantRef,
          quantity: '1.000',
        },
      ],
    });
    expect(res.status).toBe(201);
  });
});

describe('сценарии долга × PAY-031 (чистая функция decideCredit по данным мира)', () => {
  async function decide(key: CashierCustomerKey, total: string): Promise<CreditDecision> {
    const c = (
      await t.q<{
        is_retail_default: boolean;
        onec_ref: string | null;
        credit_allowed: boolean;
        credit_limit: string | null;
      }>(
        `SELECT is_retail_default, onec_ref, credit_allowed, credit_limit::text AS credit_limit FROM customers WHERE id = $1::uuid`,
        [w.customers[key].id],
      )
    )[0];
    const r = await t.receivablesRow(w.customers[key].id);
    return decideCredit({
      canSellOnCredit: true,
      customer: {
        isRetailDefault: c.is_retail_default,
        hasOnecRef: c.onec_ref !== null,
        creditAllowed: c.credit_allowed,
        creditLimit: c.credit_limit === null ? null : Money.of(c.credit_limit),
      },
      snapshot: r
        ? {
            balance: Money.of(r.balance),
            overdueAmount: r.overdue_amount === null ? null : Money.of(r.overdue_amount),
            snapshotAt: new Date(r.onec_snapshot_at),
          }
        : null,
      openOrdersAmount: Money.ZERO,
      total: Money.of(total),
      now: new Date(),
      maxAgeMinutes: 60,
      override: false,
    });
  }

  it.each<[CashierCustomerKey, string, Partial<{ kind: string; code: string; creditReason: string | null }>]>([
    ['noDebt', '1000.00', { kind: 'allowed' }],
    ['debtWithinLimit', '1000.00', { kind: 'allowed' }],
    ['advance', '1000.00', { kind: 'allowed' }],
    ['overdue', '1000.00', { kind: 'refused', code: 'CREDIT_BLOCKED', creditReason: 'overdue' }],
    ['overLimit', '1500.00', { kind: 'refused', code: 'CREDIT_LIMIT_EXCEEDED', creditReason: 'limit_exceeded' }],
    ['noLimit', '100.00', { kind: 'refused', code: 'CREDIT_LIMIT_EXCEEDED', creditReason: 'limit_exceeded' }],
    ['creditNotAllowed', '100.00', { kind: 'refused', code: 'CREDIT_BLOCKED', creditReason: 'credit_not_allowed' }],
    ['incomplete', '100.00', { kind: 'refresh_required' }],
    ['stale', '100.00', { kind: 'refresh_required' }],
    ['noSnapshot', '100.00', { kind: 'refresh_required' }],
    ['posPending', '100.00', { kind: 'refused', code: 'CUSTOMER_NOT_IDENTIFIED', creditReason: null }],
    ['retail', '100.00', { kind: 'refused', code: 'CUSTOMER_NOT_IDENTIFIED', creditReason: null }],
  ])('%s, итог %s → %o', async (key, total, expected) => {
    expect(await decide(key, total)).toMatchObject(expected);
  });
});

describe('журнал transactions (TransactionJournal) и события F через него', () => {
  it('record: строка создаётся один раз по dedupe_key; повтор возвращает тот же id', async () => {
    const j = new TransactionJournal();
    const input = {
      kind: 'return_requested' as const,
      orderId: w.orders.buyerShipped.orderId,
      customerId: w.customers.buyer.id,
      actorUserId: w.actors.cashier.userId,
      amount: '0.00',
      statusSnapshot: 'submitted',
      title: 'Заявка на возврат отправлена (тест)',
      dedupeKey: transactionDedupeKey.returnRequested('00000000-0000-7000-8000-00000000f001'),
    };
    const a = await j.record(t.db, input);
    const b = await j.record(t.db, input);
    expect(a.created).toBe(true);
    expect(b).toEqual({ created: false, id: a.id });
    const row = await t.q<{ source: string; amount: string; kind: string }>(
      `SELECT source::text AS source, amount::text AS amount, kind::text AS kind FROM transactions WHERE id = $1::uuid`,
      [a.id],
    );
    expect(row).toEqual([{ source: 'pos', amount: '0.00', kind: 'return_requested' }]);
  });

  it('record: проверка формы до SQL (сумма, ссылка, source=onec без автора)', async () => {
    const j = new TransactionJournal();
    const base = {
      kind: 'refund' as const,
      orderId: w.orders.buyerShipped.orderId,
      amount: '-100.00',
      statusSnapshot: 'completed',
      title: 'Возврат',
      dedupeKey: 'refund:test',
    };
    await expect(j.record(t.db, { ...base, amount: '100' })).rejects.toBeInstanceOf(TransactionJournalError);
    await expect(j.record(t.db, { ...base, orderId: null })).rejects.toBeInstanceOf(TransactionJournalError);
    await expect(
      j.record(t.db, { ...base, source: 'onec', actorUserId: w.actors.cashier.userId }),
    ).rejects.toBeInstanceOf(TransactionJournalError);
    const onec = await j.record(t.db, {
      ...base,
      source: 'onec',
      shipmentId: w.shipments.buyerLatest.id,
      onecRef: '0192f5d2-0000-7000-8000-0000000000c1',
      onecNumber: 'ВЗ00-000777',
      onecDocType: 'Document_ВозвратТоваровОтКлиента',
      occurredAt: new Date('2026-10-20T09:00:00Z'),
      dedupeKey: transactionDedupeKey.onecDocument('refund', '0192f5d2-0000-7000-8000-0000000000c1'),
    });
    expect(onec.created).toBe(true);
  });

  it('события заказа F (insertOrderTransaction) пишутся через журнал: формат dedupe_key прежний, дубля нет', async () => {
    const o = w.orders.buyerRequest;
    const input = {
      kind: 'order_cancelled' as const,
      orderId: o.orderId,
      customerId: w.customers.buyer.id,
      actorUserId: w.actors.cashier.userId,
      amount: o.total,
      paymentMethod: 'cash',
      statusSnapshot: 'cancelled',
      title: `Заказ ${o.publicNumber} отменён`,
      dedupeKey: transactionDedupeKey.order('order_cancelled', o.orderId),
    };
    await insertOrderTransaction(t.db, input);
    await insertOrderTransaction(t.db, input);
    const rows = await t.q<{ dedupe_key: string; amount: string; payment_method: string }>(
      `SELECT dedupe_key, amount::text AS amount, payment_method::text AS payment_method FROM transactions
        WHERE order_id = $1::uuid AND kind = 'order_cancelled'`,
      [o.orderId],
    );
    // Аннулирование — со знаком «−» (07 §5.44 amount; 10 TXN-001; ревью G-returns-txn-2).
    expect(rows).toEqual([
      { dedupe_key: `order_cancelled:${o.orderId}`, amount: `-${o.total}`, payment_method: 'cash' },
    ]);
  });

  it('события платежа F (PaymentJournal) пишутся через журнал: payment_received +, payment_voided −', async () => {
    const repo = t.app.get(PaymentsRepository);
    const journal = t.app.get(PaymentJournal);
    const p = (await repo.findById(t.db, w.orders.buyerRequest.paymentId))!;
    const at = new Date('2026-10-21T08:30:00Z');
    for (let i = 0; i < 2; i++) {
      await journal.write(t.db, {
        kind: 'payment_received',
        payment: p,
        orderPublicNumber: 'X',
        actorUserId: w.actors.cashier.userId,
        occurredAt: at,
      });
    }
    await journal.write(t.db, {
      kind: 'payment_voided',
      payment: p,
      orderPublicNumber: 'X',
      actorUserId: w.actors.cashier.userId,
      occurredAt: new Date(at.getTime() + 1000),
    });
    const rows = await t.q<{ kind: string; amount: string; dedupe_key: string }>(
      `SELECT kind::text AS kind, amount::text AS amount, dedupe_key FROM transactions WHERE payment_id = $1::uuid ORDER BY occurred_at`,
      [p.id],
    );
    expect(rows).toEqual([
      { kind: 'payment_received', amount: p.amount, dedupe_key: `payment_received:${p.id}:${at.toISOString()}` },
      {
        kind: 'payment_voided',
        amount: Money.ZERO.minus(Money.of(p.amount)).toString(),
        dedupe_key: `payment_voided:${p.id}:${new Date(at.getTime() + 1000).toISOString()}`,
      },
    ]);
  });
});

describe('порты этапа G в реестре приложения', () => {
  it('TransactionsWriter привязан по умолчанию (TransactionJournal); остальные — PortNotBoundError до модулей G', async () => {
    const registry = t.app.get(SalesPortRegistry);
    expect(registry.get(TRANSACTIONS_WRITER)).toBeInstanceOf(TransactionJournal);
    for (const token of [CUSTOMER_READER, RECEIVABLES_SNAPSHOT_PORT, DISCOUNT_POLICY_PORT, AUDIT_QUERY_PORT] as const) {
      expect(() => registry.get(token)).toThrow(PortNotBoundError);
    }
    // DI-токен — прокси позднего связывания: вызов непривязанного порта → PortNotBoundError.
    const reader = t.app.get<CustomerReader>(CUSTOMER_READER);
    expect(() => reader.fieldPolicy({ userId: null, roles: [], isCustomer: false })).toThrow(PortNotBoundError);
    // Долг до привязки G — fail-closed этапа F (контракт порта не меняется).
    const credit = registry.get(CREDIT_DECISION_SERVICE);
    await expect(
      credit.check(null, {
        actor: { userId: w.actors.cashier.userId, roles: ['cashier'], isCustomer: false },
        customerId: w.customers.noDebt.id,
        total: '100.00',
        override: null,
      }),
    ).resolves.toMatchObject({ allowed: false, code: 'CREDIT_BLOCKED' });
  });

  it('сценарные ссылки мира совпадают с CASHIER_SCENARIOS фейка', () => {
    for (const [k, ref] of Object.entries(CASHIER_SCENARIOS)) {
      expect(w.customers[k as keyof typeof CASHIER_SCENARIOS].onecRef).toBe(ref);
    }
  });
});

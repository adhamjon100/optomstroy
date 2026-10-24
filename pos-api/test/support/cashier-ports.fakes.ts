import { randomUUID } from 'node:crypto';
import type { CustomerLinkStatus, RoleCode } from '../../src/common/enums.js';
import { Money } from '../../src/common/money/money.js';
import {
  AUDIT_QUERY_PORT,
  type AuditPage,
  type AuditQuery,
  type AuditQueryPort,
  type AuditRowView,
  CREDIT_DECISION_SERVICE,
  type CreditCheckInput,
  type CreditCheckResult,
  type CreditDecisionService,
  CUSTOMER_READER,
  type CustomerAccess,
  type CustomerCard,
  type CustomerDiscountTerms,
  type CustomerFieldPolicy,
  type CustomerReader,
  DISCOUNT_POLICY_PORT,
  type DiscountPolicyPort,
  type DiscountRuleView,
  RECEIVABLES_SNAPSHOT_PORT,
  type ReceivableDocumentView,
  type ReceivablesRefreshOutcome,
  type ReceivablesSnapshotPort,
  type ReceivablesSnapshotView,
  type RoleDiscountLimitView,
  type SalesActor,
  type SalesPortToken,
  SalesPortRegistry,
  TRANSACTIONS_WRITER,
  type TransactionRecordInput,
  type TransactionRecordResult,
  type TransactionsWriter,
} from '../../src/common/ports/index.js';

/**
 * Заглушки портов этапа G (кассир) для unit/e2e тестов агентов G (in-memory, без БД; **тестовые данные**). Каждая
 * хранит журнал вызовов. Подключение: `registry.replace(TOKEN, fake)` или `createFakeCashierPorts(registry, keep)`.
 * Порты F — `sales-ports.fakes.ts`.
 */

/** Полномочия на поля карточки по ролям (11 §4.3–§4.4, 08 §3.7 `CustomerView*`; Q-017 — продавец без сумм). */
export function customerFieldPolicyFor(actor: Pick<SalesActor, 'roles' | 'isCustomer'>): CustomerFieldPolicy {
  const has = (r: RoleCode) => actor.roles.includes(r);
  if (actor.isCustomer || has('customer')) {
    return {
      view: 'self',
      fullContacts: true,
      receivableAmounts: true,
      receivableDetail: true,
      history: true,
      favorites: false,
      serviceFields: false,
    };
  }
  if (has('admin') || has('owner')) {
    return {
      view: 'admin',
      fullContacts: true,
      receivableAmounts: true,
      receivableDetail: true,
      history: true,
      favorites: true,
      serviceFields: true,
    };
  }
  if (has('cashier') || has('senior_seller')) {
    return {
      view: 'cashier',
      fullContacts: true,
      receivableAmounts: true,
      receivableDetail: true,
      history: true,
      favorites: true,
      serviceFields: true,
    };
  }
  return {
    view: 'seller',
    fullContacts: false,
    receivableAmounts: false,
    receivableDetail: false,
    history: false,
    favorites: false,
    serviceFields: true,
  };
}

/** Карточка клиента для заглушек (значения по умолчанию — клиент 1С с отсрочкой). */
export function customerCard(p: Partial<CustomerCard> & Pick<CustomerCard, 'id'>): CustomerCard {
  return {
    name: 'ОсОО «Тестовый клиент»',
    customerType: 'legal',
    source: 'onec',
    onecStatus: 'n_a',
    onecRef: randomUUID(),
    onecCode: '00000001',
    isRetailDefault: false,
    deletionMark: false,
    inn: null,
    primaryPhoneE164: null,
    phones: [],
    priceListId: null,
    discountPercent: null,
    creditAllowed: true,
    creditLimit: '50000.00',
    creditDays: 14,
    syncedAt: new Date(),
    ...p,
  };
}

export class InMemoryCustomerReader implements CustomerReader {
  readonly cards = new Map<string, CustomerCard>();
  /** userId → привязка. */
  readonly links = new Map<string, { customerId: string; status: CustomerLinkStatus; linkId: string }>();
  readonly calls: { readonly method: string; readonly args: readonly unknown[] }[] = [];

  put(card: CustomerCard): this {
    this.cards.set(card.id, card);
    return this;
  }

  link(userId: string, customerId: string, status: CustomerLinkStatus = 'confirmed'): this {
    this.links.set(userId, { customerId, status, linkId: randomUUID() });
    return this;
  }

  get(_tx: unknown, customerId: string): Promise<CustomerCard | null> {
    this.calls.push({ method: 'get', args: [customerId] });
    return Promise.resolve(this.cards.get(customerId) ?? null);
  }

  getByOnecRef(_tx: unknown, onecRef: string): Promise<CustomerCard | null> {
    this.calls.push({ method: 'getByOnecRef', args: [onecRef] });
    return Promise.resolve([...this.cards.values()].find((c) => c.onecRef === onecRef) ?? null);
  }

  getForActor(
    _tx: unknown,
    actor: SalesActor,
    customerId: string,
  ): Promise<{ card: CustomerCard; access: CustomerAccess } | null> {
    this.calls.push({ method: 'getForActor', args: [actor.userId, customerId] });
    const card = this.cards.get(customerId);
    if (!card) return Promise.resolve(null);
    const policy = this.fieldPolicy(actor);
    if (actor.isCustomer) {
      const l = actor.userId ? this.links.get(actor.userId) : undefined;
      if (!l || l.customerId !== customerId || l.status !== 'confirmed') return Promise.resolve(null);
      return Promise.resolve({ card, access: { kind: 'self', policy, linkId: l.linkId } });
    }
    return Promise.resolve({ card, access: { kind: 'staff', policy } });
  }

  fieldPolicy(actor: SalesActor): CustomerFieldPolicy {
    return customerFieldPolicyFor(actor);
  }

  linkOf(
    _tx: unknown,
    userId: string,
  ): Promise<{ customerId: string; status: CustomerLinkStatus; linkId: string } | null> {
    return Promise.resolve(this.links.get(userId) ?? null);
  }
}

export class InMemoryReceivablesSnapshots implements ReceivablesSnapshotPort {
  maxAge = 60;
  /** customerId → снимок (`snapshotAt`, суммы). */
  readonly snapshots = new Map<
    string,
    { balance: string; overdueAmount: string | null; overdueDays: number | null; snapshotAt: Date }
  >();
  readonly docs = new Map<string, ReceivableDocumentView[]>();
  readonly openOrders = new Map<string, string>();
  /** Исход следующих `refresh` (по очереди); пусто — `refreshed` с `snapshotAt = now`. */
  readonly refreshScript: ('refreshed' | 'unavailable' | 'not_in_onec')[] = [];
  readonly refreshCalls: string[] = [];

  set(
    customerId: string,
    s: { balance: string; overdueAmount: string | null; overdueDays?: number | null; ageMinutes?: number },
  ): this {
    this.snapshots.set(customerId, {
      balance: s.balance,
      overdueAmount: s.overdueAmount,
      overdueDays: s.overdueDays ?? (s.overdueAmount === null ? null : 0),
      snapshotAt: new Date(Date.now() - (s.ageMinutes ?? 0) * 60_000),
    });
    return this;
  }

  maxAgeMinutes(): Promise<number> {
    return Promise.resolve(this.maxAge);
  }

  snapshot(_tx: unknown, customerId: string, now: Date = new Date()): Promise<ReceivablesSnapshotView | null> {
    const s = this.snapshots.get(customerId);
    if (!s) return Promise.resolve(null);
    const ageMinutes = Math.max(0, Math.floor((now.getTime() - s.snapshotAt.getTime()) / 60_000));
    const isStale = ageMinutes > this.maxAge;
    return Promise.resolve({
      customerId,
      balance: s.balance,
      overdueAmount: s.overdueAmount,
      overdueDays: s.overdueDays,
      oldestDueDate: null,
      snapshotAt: s.snapshotAt,
      ageMinutes,
      isStale,
      usableForCredit: !isStale && s.overdueAmount !== null,
      maxAgeMinutes: this.maxAge,
    });
  }

  documents(_tx: unknown, customerId: string): Promise<readonly ReceivableDocumentView[]> {
    return Promise.resolve(this.docs.get(customerId) ?? []);
  }

  openOrdersAmount(_tx: unknown, customerId: string): Promise<string> {
    return Promise.resolve(this.openOrders.get(customerId) ?? '0.00');
  }

  async refresh(customerId: string): Promise<ReceivablesRefreshOutcome> {
    this.refreshCalls.push(customerId);
    const step = this.refreshScript.shift() ?? 'refreshed';
    if (step === 'not_in_onec') return { kind: 'not_in_onec' };
    if (step === 'unavailable') {
      return { kind: 'unavailable', snapshot: await this.snapshot(null, customerId), reason: 'ONEC_UNAVAILABLE' };
    }
    const cur = this.snapshots.get(customerId);
    this.snapshots.set(customerId, {
      balance: cur?.balance ?? '0.00',
      overdueAmount: cur?.overdueAmount ?? '0.00',
      overdueDays: cur?.overdueDays ?? 0,
      snapshotAt: new Date(),
    });
    const snap = await this.snapshot(null, customerId);
    return { kind: 'refreshed', snapshot: snap! };
  }
}

/** Лимиты seed `seeds/0001_defaults.sql` (Q-015: seller 5, cashier 5, senior 10, admin 15, owner 0). */
export const SEED_ROLE_LIMITS: readonly RoleDiscountLimitView[] = [
  ['seller', '5.00', false],
  ['cashier', '5.00', false],
  ['senior_seller', '10.00', true],
  ['admin', '15.00', true],
  ['owner', '0.00', false],
  ['customer', '0.00', false],
  ['integration', '0.00', false],
].map(([role, maxPercent, can]) => ({
  role: role as RoleCode,
  maxPercent: maxPercent as string,
  canApproveOverLimit: can as boolean,
  approveMaxPercent: null,
  requiresReasonOverPercent: null,
  rowVersion: 1,
}));

/** Сравнение процентов `"5.00"` (точно, через decimal — как деньги, 2 знака). */
function cmpPercent(a: string, b: string): number {
  return Money.of(a).compare(Money.of(b));
}

export class StubDiscountPolicy implements DiscountPolicyPort {
  readonly limitRows: RoleDiscountLimitView[] = SEED_ROLE_LIMITS.map((r) => ({ ...r }));
  readonly rules: DiscountRuleView[] = [];
  readonly terms = new Map<string, CustomerDiscountTerms>();

  limits(): Promise<readonly RoleDiscountLimitView[]> {
    return Promise.resolve(this.limitRows);
  }

  limitFor(_tx: unknown, actor: SalesActor): Promise<string> {
    if (actor.isCustomer) return Promise.resolve('0.00');
    let best = '0.00';
    for (const r of this.limitRows) {
      if (actor.roles.includes(r.role) && cmpPercent(r.maxPercent, best) > 0) best = r.maxPercent;
    }
    return Promise.resolve(best);
  }

  canApproveOverLimit(_tx: unknown, actor: SalesActor, percent: string): Promise<boolean> {
    if (actor.isCustomer) return Promise.resolve(false);
    return Promise.resolve(
      this.limitRows.some(
        (r) =>
          actor.roles.includes(r.role) &&
          r.canApproveOverLimit &&
          (r.approveMaxPercent === null || cmpPercent(percent, r.approveMaxPercent) <= 0),
      ),
    );
  }

  activeRules(): Promise<readonly DiscountRuleView[]> {
    return Promise.resolve(this.rules.filter((r) => r.isActive));
  }

  customerTerms(_tx: unknown, customerId: string): Promise<CustomerDiscountTerms | null> {
    return Promise.resolve(this.terms.get(customerId) ?? null);
  }
}

/** In-memory журнал `transactions` с той же идемпотентностью по `dedupeKey`, что `TransactionJournal`. */
export class InMemoryTransactionsWriter implements TransactionsWriter {
  readonly rows: (TransactionRecordInput & { readonly id: string })[] = [];

  record(_tx: unknown, input: TransactionRecordInput): Promise<TransactionRecordResult> {
    const dup = this.rows.find((r) => r.dedupeKey === input.dedupeKey);
    if (dup) return Promise.resolve({ created: false, id: dup.id });
    if (!input.orderId && !input.paymentId && !input.returnRequestId && !input.shipmentId) {
      return Promise.reject(new Error('transactions: нужна ссылка order/payment/return_request/shipment'));
    }
    const id = randomUUID();
    this.rows.push({ ...input, id });
    return Promise.resolve({ created: true, id });
  }

  ofKind(kind: TransactionRecordInput['kind']): readonly TransactionRecordInput[] {
    return this.rows.filter((r) => r.kind === kind);
  }
}

export class InMemoryAuditQuery implements AuditQueryPort {
  readonly rows: AuditRowView[] = [];
  chainOk = true;

  list(_tx: unknown, _viewer: SalesActor, q: AuditQuery): Promise<AuditPage> {
    const items = this.rows
      .filter((r) => r.occurredAt >= q.from && r.occurredAt < q.to)
      .filter((r) => !q.actorUserId || r.actorUserId === q.actorUserId)
      .filter((r) => !q.entityType || r.entityType === q.entityType)
      .filter((r) => !q.entityId || r.entityId === q.entityId)
      .filter((r) => !q.result || r.result === q.result)
      .filter((r) =>
        !q.action ? true : q.action.endsWith('.*') ? r.action.startsWith(q.action.slice(0, -1)) : r.action === q.action,
      )
      .sort((a, b) => b.occurredAt.getTime() - a.occurredAt.getTime());
    const limit = q.limit ?? 50;
    return Promise.resolve({ items: items.slice(0, limit), nextCursor: null, hasMore: items.length > limit });
  }

  forEntity(_tx: unknown, _viewer: SalesActor, entityType: string, entityId: string): Promise<AuditRowView[]> {
    return Promise.resolve(this.rows.filter((r) => r.entityType === entityType && r.entityId === entityId));
  }

  verifyChain(): Promise<{ ok: boolean; brokenAtChainSeq: string | null; gaps: number }> {
    return Promise.resolve({ ok: this.chainOk, brokenAtChainSeq: this.chainOk ? null : '1', gaps: 0 });
  }
}

/** Решение о долге по сценарию теста (очередь результатов; пусто — fail-closed `CREDIT_BLOCKED`). */
export class ScriptedCreditDecision implements CreditDecisionService {
  readonly results: CreditCheckResult[] = [];
  readonly calls: CreditCheckInput[] = [];

  check(_tx: unknown, input: CreditCheckInput): Promise<CreditCheckResult> {
    this.calls.push(input);
    return Promise.resolve(
      this.results.shift() ?? {
        allowed: false,
        code: 'CREDIT_BLOCKED',
        creditReason: null,
        detail: 'ScriptedCreditDecision: сценарий не задан (fail-closed).',
      },
    );
  }
}

export interface FakeCashierPorts {
  readonly registry: SalesPortRegistry;
  readonly customers: InMemoryCustomerReader;
  readonly receivables: InMemoryReceivablesSnapshots;
  readonly discounts: StubDiscountPolicy;
  readonly transactions: InMemoryTransactionsWriter;
  readonly audit: InMemoryAuditQuery;
  readonly credit: ScriptedCreditDecision;
}

/**
 * Подменить порты G заглушками (`keep` — токены, которые не трогать: свой порт агента). `CREDIT_DECISION_SERVICE`
 * подменяется только при `withCredit` (по умолчанию остаётся привязанный/fail-closed).
 */
export function createFakeCashierPorts(
  registry: SalesPortRegistry,
  keep: readonly SalesPortToken[] = [],
  opts: { readonly withCredit?: boolean } = {},
): FakeCashierPorts {
  const ports = {
    customers: new InMemoryCustomerReader(),
    receivables: new InMemoryReceivablesSnapshots(),
    discounts: new StubDiscountPolicy(),
    transactions: new InMemoryTransactionsWriter(),
    audit: new InMemoryAuditQuery(),
    credit: new ScriptedCreditDecision(),
  };
  if (!keep.includes(CUSTOMER_READER)) registry.replace(CUSTOMER_READER, ports.customers);
  if (!keep.includes(RECEIVABLES_SNAPSHOT_PORT)) registry.replace(RECEIVABLES_SNAPSHOT_PORT, ports.receivables);
  if (!keep.includes(DISCOUNT_POLICY_PORT)) registry.replace(DISCOUNT_POLICY_PORT, ports.discounts);
  if (!keep.includes(TRANSACTIONS_WRITER)) registry.replace(TRANSACTIONS_WRITER, ports.transactions);
  if (!keep.includes(AUDIT_QUERY_PORT)) registry.replace(AUDIT_QUERY_PORT, ports.audit);
  if (opts.withCredit && !keep.includes(CREDIT_DECISION_SERVICE))
    registry.replace(CREDIT_DECISION_SERVICE, ports.credit);
  return { registry, ...ports };
}

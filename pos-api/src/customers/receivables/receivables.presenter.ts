import { MoneyMath } from '../../common/money/money-math.js';
import { Money } from '../../common/money/money.js';
import type { ReceivableDocumentView, ReceivablesSnapshotView } from '../../common/ports/index.js';
import { customerDisplayName } from '../../common/presenters/customer-name.js';
import type { ReceivablesCustomerRow } from './receivables.repository.js';

type MoneyDto = { amount: string; currency: 'KGS' };

function money(v: string): MoneyDto {
  return Money.of(v).toJSON();
}

/** `ReceivableDocument` (08 §3.7; 10 DEBT-003). */
export function presentReceivableDocument(d: ReceivableDocumentView): Record<string, unknown> {
  return {
    kind: d.kind,
    status: d.status,
    number: d.number,
    date: d.date,
    amount: money(d.amount),
    paid: money(d.paid),
    remaining: money(d.remaining),
    dueDate: d.dueDate,
    ...(d.overdueDays !== null ? { overdueDays: d.overdueDays } : {}),
    onecRef: d.onecRef,
  };
}

export interface ReceivableViewInput {
  readonly customer: ReceivablesCustomerRow;
  readonly snapshot: ReceivablesSnapshotView | null;
  readonly maxAgeMinutes: number;
  readonly openOrdersAmount: string;
  /** `include=documents` со step-up; иначе `undefined` (поле не выводится). */
  readonly documents?: readonly ReceivableDocumentView[];
  /** Только в ответе `POST …/receivables/refresh`. */
  readonly refreshed?: boolean;
}

/**
 * `Receivable` (08 §3.7, §4.11.5, §4.11.8; 10 DEBT-002, DEBT-009, DEBT-011, DEBT-012) — суммы только из снимка 1С:
 *
 * - клиент без карточки 1С (`onec_ref IS NULL`: POS-клиент до подтверждения 1С, «Розничный покупатель») — `200` с
 *   `balance: null`, `asOf: null`, `reason: not_in_onec`, прочие суммы не передаются (B-AR-06);
 * - снимка ещё нет («Нет данных из 1С», DEBT-009) — `balance: null`, `asOf: null`, `isStale: true` без `reason`
 *   (GQ-CRD-05); суммы не подставляются нулями;
 * - иначе — сальдо, просрочка (`null` — неизвестна), лимит, прогноз открытых заказов, остаток лимита
 *   `creditLimit − balance − openOrdersAmount` (MV-21, MV-22; лимит не задан — поля нет), срок, `asOf`, `isStale`.
 */
export function presentReceivable(i: ReceivableViewInput): Record<string, unknown> {
  const c = i.customer;
  const tail = {
    ...(i.refreshed !== undefined ? { refreshed: i.refreshed } : {}),
  };
  if (c.onecRef === null) {
    return {
      customerId: c.id,
      balance: null,
      reason: 'not_in_onec',
      overdueAmount: null,
      creditAllowed: c.creditAllowed,
      asOf: null,
      isStale: false,
      staleAfterMinutes: i.maxAgeMinutes,
      ...tail,
      ...(i.documents !== undefined ? { documents: [] } : {}),
    };
  }
  const terms = {
    creditAllowed: c.creditAllowed,
    ...(c.creditLimit !== null ? { creditLimit: money(c.creditLimit) } : {}),
    ...(c.creditDays !== null ? { paymentTermDays: c.creditDays } : {}),
    openOrdersAmount: money(i.openOrdersAmount),
  };
  const s = i.snapshot;
  if (!s) {
    return {
      customerId: c.id,
      balance: null,
      overdueAmount: null,
      ...terms,
      asOf: null,
      isStale: true,
      staleAfterMinutes: i.maxAgeMinutes,
      ...tail,
      ...(i.documents !== undefined ? { documents: [] } : {}),
    };
  }
  const remaining =
    c.creditLimit === null
      ? null
      : MoneyMath.creditRemaining(Money.of(c.creditLimit), Money.of(s.balance), Money.of(i.openOrdersAmount));
  return {
    customerId: c.id,
    balance: money(s.balance),
    overdueAmount: s.overdueAmount === null ? null : money(s.overdueAmount),
    ...(s.overdueDays !== null ? { overdueDays: s.overdueDays } : {}),
    ...terms,
    ...(remaining !== null ? { limitRemaining: remaining.toJSON() } : {}),
    asOf: s.snapshotAt.toISOString(),
    isStale: s.isStale,
    staleAfterMinutes: i.maxAgeMinutes,
    ...tail,
    ...(i.documents !== undefined ? { documents: i.documents.map(presentReceivableDocument) } : {}),
  };
}

/** `Customer` (базовые поля без сумм долга) для строк `GET /receivables/overdue` (08 §4.12.1). */
export function presentOverdueCustomer(c: ReceivablesCustomerRow, overdue: boolean): Record<string, unknown> {
  return {
    id: c.id,
    name: c.name,
    displayName: customerDisplayName(c.name),
    customerType: c.customerType,
    ...(c.onecCode ? { onecCode: c.onecCode } : {}),
    isRetailDefault: c.isRetailDefault,
    creditAllowed: c.creditAllowed,
    hasDebt: true,
    isOverdue: overdue,
    source: c.source,
    onecStatus: c.onecStatus,
    onecRef: c.onecRef,
  };
}

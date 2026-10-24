import { createHash } from 'node:crypto';
import type { ReceivableDocumentKind, ReceivableDocumentStatus } from '../../common/enums.js';
import { Money } from '../../common/money/money.js';
import { RECEIVABLES_CLOCK_SKEW_MS } from '../../common/ports/receivables-snapshot.port.js';

/**
 * Разбор ответа 1С `GET /pos/v1/customers/{ref}/receivables` (контракт `contracts/onec/onec-http-service.v1.yaml`
 * `CustomerReceivables`, ONEC-047) в снимок `receivables` + `receivable_documents` (07 §5.31–§5.32). Долг не
 * вычисляется (D-24, DEBT-001): суммы, просрочка и сроки — как прислала 1С; вычисляются только служебные поля, которых
 * в ответе нет:
 *
 * - `kind`/`status` строки детализации (10 DEBT-003; маппинг — GQ-FND-06, владелец — G-be-credit): по типу документа
 *   1С и сроку оплаты (`receivableDocKind`, `receivableDocStatus`);
 * - `oldest_due_date` (GQ-FND-07): минимальный срок оплаты строк с остатком > 0.
 *
 * Ответ, не соответствующий контракту, или с нарушением инвариантов 07 (`0 ≤ overdue_amount ≤ max(balance, 0)`) —
 * `OnecReceivablesFormatError`: снимок не применяется, прежний остаётся (SYNC-016, fail-closed).
 */
export interface ParsedReceivableDocument {
  readonly onecRef: string;
  readonly docType: string;
  readonly kind: ReceivableDocumentKind;
  readonly status: ReceivableDocumentStatus;
  readonly number: string;
  /** `YYYY-MM-DD` (дата документа по Бишкеку, как в 1С). */
  readonly date: string;
  readonly amount: string;
  readonly paid: string;
  readonly remaining: string;
  readonly dueDate: string | null;
  readonly overdueDays: number | null;
}

export interface ParsedReceivables {
  readonly customerRef: string;
  /** Метка времени снимка 1С (`receivables.onec_snapshot_at`). */
  readonly snapshotAt: Date;
  readonly balance: string;
  readonly overdueAmount: string | null;
  readonly overdueDays: number | null;
  readonly oldestDueDate: string | null;
  readonly creditAllowed: boolean;
  readonly creditLimit: string | null;
  readonly creditDays: number | null;
  readonly documents: readonly ParsedReceivableDocument[];
  /** SHA-256 канонического тела (`receivables.source_hash`). */
  readonly sourceHash: string;
}

export class OnecReceivablesFormatError extends Error {
  override readonly name = 'OnecReceivablesFormatError';
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MONEY_RE = /^-?\d{1,12}\.\d{2}$/;
const DATE_TIME_RE = /^(\d{4}-\d{2}-\d{2})T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
const BISHKEK_OFFSET_MS = 6 * 3600_000;

/** Дата по Бишкеку (UTC+6 без перехода на летнее время) `YYYY-MM-DD`. */
export function bishkekDate(d: Date): string {
  return new Date(d.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 10);
}

const KIND_BY_TYPE: Readonly<Record<string, ReceivableDocumentKind>> = {
  Document_РеализацияТоваровУслуг: 'invoice',
  Document_ЗаказКлиента: 'invoice',
  Document_ПриходныйКассовыйОрдер: 'payment',
  Document_ПоступлениеБезналичныхДенежныхСредств: 'payment',
  Document_ОплатаПлатежнойКартой: 'payment',
  Document_ВозвратТоваровОтКлиента: 'return',
};

/**
 * Вид строки детализации по типу документа 1С (GQ-FND-06): реализация/заказ → `invoice`; ПКО/поступление/оплата
 * картой → `payment`; возврат от клиента → `return`; тип со «Скидк» → `discount`; прочие (корректировки, ввод
 * остатков) → `adjustment`.
 */
export function receivableDocKind(documentType: string): ReceivableDocumentKind {
  return KIND_BY_TYPE[documentType] ?? (documentType.includes('Скидк') ? 'discount' : 'adjustment');
}

/**
 * Статус строки (GQ-FND-06): `due` — срок оплаты наступил (`dueDate ≤ дата снимка`) и остаток > 0; иначе
 * `posted` (документы в ответе 1С — проведённые; признака «не проведён» в контракте нет, `not_posted` не выдаётся).
 */
export function receivableDocStatus(
  dueDate: string | null,
  remaining: string,
  today: string,
): ReceivableDocumentStatus {
  const positive = !Money.of(remaining).isNegative() && !Money.of(remaining).isZero();
  return dueDate !== null && dueDate <= today && positive ? 'due' : 'posted';
}

function fail(field: string, why: string): never {
  throw new OnecReceivablesFormatError(`receivables: ${field} — ${why}`);
}

function obj(v: unknown, field: string): Record<string, unknown> {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) fail(field, 'ожидается объект');
  return v as Record<string, unknown>;
}

function money(v: unknown, field: string): string {
  if (typeof v !== 'string' || !MONEY_RE.test(v)) fail(field, 'ожидается сумма ^-?\\d+\\.\\d{2}$');
  return Money.of(v).toString();
}

function moneyOrNull(v: unknown, field: string): string | null {
  return v === null || v === undefined ? null : money(v, field);
}

function intOrNull(v: unknown, field: string, max = 2_147_483_647): number | null {
  if (v === null || v === undefined) return null;
  if (typeof v !== 'number' || !Number.isInteger(v) || v < 0 || v > max) fail(field, 'ожидается целое ≥ 0');
  return v;
}

function dateTime(v: unknown, field: string): { at: Date; localDate: string } {
  const m = typeof v === 'string' ? DATE_TIME_RE.exec(v) : null;
  const at = m ? new Date(v as string) : null;
  if (!m || !at || Number.isNaN(at.getTime())) fail(field, 'ожидается дата-время ISO 8601');
  // Дата документа/срока — как записана в 1С (`…T00:00:00+06:00` → её календарная дата).
  return { at, localDate: m[1] };
}

function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (v !== null && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`)
      .join(',')}}`;
  }
  return JSON.stringify(v ?? null);
}

/**
 * `receivedAt` — момент получения ответа 1С: `snapshotAt` позже него больше чем на `RECEIVABLES_CLOCK_SKEW_MS`
 * (сбой часов/часового пояса 1С) — нарушение контракта, снимок не применяется (ревью G-credit-2).
 */
export function parseOnecReceivables(
  body: unknown,
  expectedRef: string,
  opts: { readonly receivedAt?: Date } = {},
): ParsedReceivables {
  const b = obj(body, 'body');
  const ref = b.customerRef;
  if (typeof ref !== 'string' || !UUID_RE.test(ref)) fail('customerRef', 'ожидается UUID');
  if (ref.toLowerCase() !== expectedRef.toLowerCase()) fail('customerRef', 'не совпадает с запрошенным клиентом');
  const snapshot = dateTime(b.snapshotAt, 'snapshotAt');
  if (opts.receivedAt && snapshot.at.getTime() - opts.receivedAt.getTime() > RECEIVABLES_CLOCK_SKEW_MS) {
    fail('snapshotAt', 'метка снимка позже момента ответа 1С (часы 1С)');
  }
  const balance = money(b.balance, 'balance');
  const overdueAmount = moneyOrNull(b.overdueAmount, 'overdueAmount');
  if (overdueAmount !== null) {
    const o = Money.of(overdueAmount);
    const cap = Money.of(balance).isNegative() ? Money.ZERO : Money.of(balance);
    if (o.isNegative() || o.compare(cap) > 0) fail('overdueAmount', 'вне 0…max(balance, 0) (07 §5.31)');
  }
  if (typeof b.creditAllowed !== 'boolean') fail('creditAllowed', 'ожидается boolean');
  const creditLimit = moneyOrNull(b.creditLimit, 'creditLimit');
  if (creditLimit !== null && Money.of(creditLimit).isNegative()) fail('creditLimit', 'ожидается ≥ 0');
  if (!Array.isArray(b.documents)) fail('documents', 'ожидается массив');
  const today = bishkekDate(snapshot.at);
  const seen = new Set<string>();
  const documents = b.documents.map((raw, i): ParsedReceivableDocument => {
    const d = obj(raw, `documents[${i}]`);
    const docRef = d.documentRef;
    if (typeof docRef !== 'string' || !UUID_RE.test(docRef)) fail(`documents[${i}].documentRef`, 'ожидается UUID');
    const key = docRef.toLowerCase();
    if (seen.has(key)) fail(`documents[${i}].documentRef`, 'повтор документа');
    seen.add(key);
    if (typeof d.documentType !== 'string' || d.documentType === '') fail(`documents[${i}].documentType`, 'пусто');
    if (typeof d.number !== 'string' || d.number.trim() === '') fail(`documents[${i}].number`, 'пусто');
    const date = dateTime(d.date, `documents[${i}].date`).localDate;
    const remaining = money(d.remaining, `documents[${i}].remaining`);
    const dueDate =
      d.dueDate === null || d.dueDate === undefined ? null : dateTime(d.dueDate, `documents[${i}].dueDate`).localDate;
    return {
      onecRef: key,
      docType: d.documentType,
      kind: receivableDocKind(d.documentType),
      status: receivableDocStatus(dueDate, remaining, today),
      number: d.number,
      date,
      amount: money(d.amount, `documents[${i}].amount`),
      paid: money(d.paid, `documents[${i}].paid`),
      remaining,
      dueDate,
      overdueDays: intOrNull(d.overdueDays, `documents[${i}].overdueDays`),
    };
  });
  const oldestDueDate =
    documents
      .filter((d) => d.dueDate !== null && !Money.of(d.remaining).isNegative() && !Money.of(d.remaining).isZero())
      .map((d) => d.dueDate as string)
      .sort()[0] ?? null;
  return {
    customerRef: ref.toLowerCase(),
    snapshotAt: snapshot.at,
    balance,
    overdueAmount,
    overdueDays: intOrNull(b.overdueDays, 'overdueDays'),
    oldestDueDate,
    creditAllowed: b.creditAllowed,
    creditLimit,
    creditDays: intOrNull(b.creditDays, 'creditDays', 32_767),
    documents,
    sourceHash: createHash('sha256').update(canonical(b)).digest('hex'),
  };
}

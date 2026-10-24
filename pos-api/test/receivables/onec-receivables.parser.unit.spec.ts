import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { SyntheticCashier, CASHIER_SCENARIOS } from '../../src/integrations/onec/synthetic-cashier.js';
import {
  bishkekDate,
  OnecReceivablesFormatError,
  parseOnecReceivables,
  receivableDocKind,
  receivableDocStatus,
} from '../../src/sync/receivables/onec-receivables.parser.js';
import { contractErrors } from '../cashier-foundation/support/onec-contract.js';

/**
 * Разбор ответа 1С `GET /pos/v1/customers/{ref}/receivables` (контракт 1С `CustomerReceivables`, ONEC-047) —
 * **тестовые данные**: фикстура контракта и синтетика кассира; вид/статус строк детализации (GQ-FND-06),
 * `oldest_due_date` (GQ-FND-07); ответ вне контракта или с нарушением инвариантов 07 §5.31 — ошибка формата
 * (снимок не применяется, SYNC-016).
 */
const FIXTURE = JSON.parse(
  readFileSync(new URL('../../../contracts/onec/fixtures/receivables.200.json', import.meta.url), 'utf8'),
) as { body: Record<string, unknown> };
const REF = 'c3d4e5f6-0000-4000-8000-000000000001';

describe('parseOnecReceivables', () => {
  it('фикстура контракта: суммы как в 1С, метка снимка, вид invoice, срок → status по дате снимка, oldestDueDate', () => {
    expect(contractErrors('CustomerReceivables', FIXTURE.body)).toEqual([]);
    const p = parseOnecReceivables(FIXTURE.body, REF.toUpperCase());
    expect(p).toMatchObject({
      customerRef: REF,
      balance: '12300.00',
      overdueAmount: '0.00',
      overdueDays: 0,
      creditAllowed: true,
      creditLimit: '100000.00',
      creditDays: 14,
      oldestDueDate: '2026-10-24',
    });
    expect(p.snapshotAt.toISOString()).toBe('2026-10-21T07:39:05.000Z');
    expect(p.documents).toEqual([
      expect.objectContaining({ kind: 'invoice', status: 'posted', date: '2026-10-10', dueDate: '2026-10-24' }),
    ]);
    expect(p.sourceHash).toMatch(/^[0-9a-f]{64}$/);
    // Хэш не зависит от порядка ключей.
    const reordered = Object.fromEntries(Object.entries(FIXTURE.body).reverse());
    expect(parseOnecReceivables(reordered, REF).sourceHash).toBe(p.sourceHash);
  });

  it('синтетика кассира (покупатель): ответ по контракту; виды строк invoice/payment/return/adjustment', () => {
    const sc = new SyntheticCashier();
    const body = sc.getReceivables(CASHIER_SCENARIOS.buyer);
    expect(contractErrors('CustomerReceivables', body)).toEqual([]);
    const p = parseOnecReceivables(body, CASHIER_SCENARIOS.buyer);
    expect([...new Set(p.documents.map((d) => d.kind))].sort()).toEqual(['adjustment', 'invoice', 'payment', 'return']);
    const overdue = parseOnecReceivables(sc.getReceivables(CASHIER_SCENARIOS.overdue), CASHIER_SCENARIOS.overdue);
    expect(overdue.documents.map((d) => d.status)).toEqual(['due']);
    const incomplete = parseOnecReceivables(
      sc.getReceivables(CASHIER_SCENARIOS.incomplete),
      CASHIER_SCENARIOS.incomplete,
    );
    expect(incomplete.overdueAmount).toBeNull();
  });

  it('вид и статус строк (GQ-FND-06); дата по Бишкеку', () => {
    expect(receivableDocKind('Document_ПоступлениеБезналичныхДенежныхСредств')).toBe('payment');
    expect(receivableDocKind('Document_СкидкаКлиенту')).toBe('discount');
    expect(receivableDocKind('Document_КорректировкаРеализации')).toBe('adjustment');
    expect(receivableDocStatus('2026-10-24', '1.00', '2026-10-24')).toBe('due');
    expect(receivableDocStatus('2026-10-25', '1.00', '2026-10-24')).toBe('posted');
    expect(receivableDocStatus('2026-10-01', '0.00', '2026-10-24')).toBe('posted');
    expect(receivableDocStatus('2026-10-01', '-5.00', '2026-10-24')).toBe('posted');
    expect(receivableDocStatus(null, '5.00', '2026-10-24')).toBe('posted');
    expect(bishkekDate(new Date('2026-10-23T18:00:00Z'))).toBe('2026-10-24');
  });

  const bad: [string, (b: Record<string, unknown>) => unknown][] = [
    ['не объект', () => []],
    ['customerRef не UUID', (b) => ({ ...b, customerRef: 'x' })],
    ['чужой customerRef', (b) => ({ ...b, customerRef: 'c3d4e5f6-0000-4000-8000-000000000002' })],
    ['snapshotAt не дата', (b) => ({ ...b, snapshotAt: '21.10.2026' })],
    ['balance числом', (b) => ({ ...b, balance: 12300 })],
    ['просрочка больше сальдо', (b) => ({ ...b, overdueAmount: '20000.00' })],
    ['отрицательная просрочка', (b) => ({ ...b, overdueAmount: '-1.00' })],
    ['просрочка при авансе', (b) => ({ ...b, balance: '-10.00', overdueAmount: '5.00' })],
    ['creditAllowed не boolean', (b) => ({ ...b, creditAllowed: 'yes' })],
    ['отрицательный лимит', (b) => ({ ...b, creditLimit: '-1.00' })],
    ['overdueDays дробное', (b) => ({ ...b, overdueDays: 1.5 })],
    ['creditDays больше smallint', (b) => ({ ...b, creditDays: 40000 })],
    ['documents не массив', (b) => ({ ...b, documents: {} })],
    ['документ не объект', (b) => ({ ...b, documents: [1] })],
    ['documentRef не UUID', (b) => ({ ...b, documents: [{ ...doc(b), documentRef: 'x' }] })],
    ['повтор документа', (b) => ({ ...b, documents: [doc(b), doc(b)] })],
    ['пустой тип', (b) => ({ ...b, documents: [{ ...doc(b), documentType: '' }] })],
    ['пустой номер', (b) => ({ ...b, documents: [{ ...doc(b), number: ' ' }] })],
    ['dueDate не дата', (b) => ({ ...b, documents: [{ ...doc(b), dueDate: 'завтра' }] })],
  ];
  function doc(b: Record<string, unknown>): Record<string, unknown> {
    return (b.documents as Record<string, unknown>[])[0];
  }

  it.each(bad)('вне контракта: %s → OnecReceivablesFormatError', (_n, mutate) => {
    expect(() => parseOnecReceivables(mutate(FIXTURE.body), REF)).toThrow(OnecReceivablesFormatError);
  });

  it('необязательные поля: overdueAmount/creditLimit/creditDays/dueDate = null допустимы; без documents[].overdueDays', () => {
    const d = { ...doc(FIXTURE.body), dueDate: null, overdueDays: undefined };
    const p = parseOnecReceivables(
      { ...FIXTURE.body, overdueAmount: null, overdueDays: null, creditLimit: null, creditDays: null, documents: [d] },
      REF,
    );
    expect(p).toMatchObject({
      overdueAmount: null,
      overdueDays: null,
      creditLimit: null,
      creditDays: null,
      oldestDueDate: null,
    });
    expect(p.documents[0]).toMatchObject({ dueDate: null, overdueDays: null, status: 'posted' });
  });

  it('метка снимка «из будущего» относительно момента ответа (сверх допуска 5 мин) → ошибка формата (ревью G-credit-2)', () => {
    const at = new Date(String(FIXTURE.body.snapshotAt));
    expect(() =>
      parseOnecReceivables(FIXTURE.body, REF, { receivedAt: new Date(at.getTime() - 24 * 3600_000) }),
    ).toThrow(/snapshotAt/);
    // В пределах допуска часов — принимается; без receivedAt — только формат.
    expect(
      parseOnecReceivables(FIXTURE.body, REF, { receivedAt: new Date(at.getTime() - 4 * 60_000) }).snapshotAt,
    ).toEqual(at);
    expect(parseOnecReceivables(FIXTURE.body, REF).snapshotAt).toEqual(at);
  });
});

import { describe, expect, it } from 'vitest';
import { sameItems } from '../../src/orders/order-create.service.js';
import { normalizeOnecStatus, orderJournalAmount, parseOnecOrderDocument } from '../../src/orders/order-projection.js';
import { forbiddenMoneyFields, parseCancelBody, parseCreateOrderBody } from '../../src/orders/orders.request.js';
import { toOnecDateTime } from '../../src/orders/onec-order-payload.js';
import { OnecOutboxDelivery, withDependencyCustomer } from '../../src/sync/outbox/onec-outbox.delivery.js';
import type { OutboxRow } from '../../src/jobs/outbox/outbox-delivery.port.js';
import { ScriptedOnecGateway } from '../support/scripted-onec.gateway.js';

/** Чистые правила модуля orders без БД (05 §5.1b ONEC-021, ядро §22.1, 08 §4.8.1) — **тестовые данные**. */
describe('orders: чистые правила', () => {
  it('нормализация статуса 1С (M1–M5, M11)', () => {
    expect(normalizeOnecStatus('НеСогласован')).toBe('not_approved');
    expect(normalizeOnecStatus('На согласовании')).toBe('not_approved');
    expect(normalizeOnecStatus('КВыполнению')).toBe('to_execute');
    expect(normalizeOnecStatus('К выполнению')).toBe('to_execute');
    expect(normalizeOnecStatus('Закрыт')).toBe('closed');
    expect(normalizeOnecStatus(null)).toBeNull();
    expect(normalizeOnecStatus('Что-то')).toBe('unrecognized');
  });

  // 12: T-ORD-024 (отгрузка — только из 1С: hasShipment по документу), T-SYNC-F07 (пометка удаления)
  it('разбор документа 1С: реализация проведена → hasShipment; пометка удаления; итог', () => {
    const d = parseOnecOrderDocument({
      ref: 'b2c3d4e5-0000-4000-8000-000000000010',
      number: 'ОС00-1',
      status: 'Закрыт',
      deletionMark: true,
      total: '16007.5',
      shipments: [{ posted: true }],
    });
    expect(d).toMatchObject({
      number: 'ОС00-1',
      status: 'Закрыт',
      deletionMark: true,
      total: '16007.50',
      hasShipment: true,
    });
    expect(parseOnecOrderDocument({ totals: { total: '1.00' } }).total).toBe('1.00');
  });

  it('items[] сверяется с корзиной до тысячных (Quantity, 3 знака — ревью F-money-rules-7)', () => {
    const v = '0192f3a1-0000-7000-8000-0000000000aa';
    const line = { variantId: v, packagingId: null, quantity: '1.234' };
    expect(sameItems([{ ...line, quantity: '1.234' }], [line])).toBe(true);
    expect(sameItems([{ ...line, quantity: '1.2340' }], [line])).toBe(true);
    expect(sameItems([{ ...line, quantity: '1.231' }], [line])).toBe(false);
    expect(sameItems([{ ...line, quantity: '0.004' }], [{ ...line, quantity: '0.000' }])).toBe(false);
  });

  it('дата-время контракта 1С — +06:00', () => {
    expect(toOnecDateTime(new Date('2026-10-21T07:39:12Z'))).toBe('2026-10-21T13:39:12+06:00');
  });

  it('запрещённые денежные поля и delivery.geo; createdVia игнорируется; обязательные поля доставки', () => {
    expect(forbiddenMoneyFields({ total: '1', items: [{ unitPrice: '1' }], delivery: { geo: {} } })).toEqual([
      'total',
      'items[0].unitPrice',
      'delivery.geo',
    ]);
    // Все семь полей 10 ORD-020 / DISC-011 — и на верхнем уровне, и в items[] (ревью F-money-rules-6).
    expect(
      forbiddenMoneyFields({ lineTotal: '1', discountAmount: '1', items: [{ lineTotal: '1', discountAmount: '1' }] }),
    ).toEqual(['lineTotal', 'discountAmount', 'items[0].lineTotal', 'items[0].discountAmount']);
    for (const f of ['price', 'unitPrice', 'lineTotal', 'subtotal', 'total', 'discountAmount', 'amount']) {
      expect(forbiddenMoneyFields({ [f]: '1' }), f).toEqual([f]);
    }
    const base = {
      cartId: '0192f3a1-0000-7000-8000-000000000001',
      cartRowVersion: 1,
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
      paymentMethod: 'cash',
      items: [
        {
          variantId: '0192f3a1-0000-7000-8000-000000000002',
          quantity: { value: '1', unitId: '0192f3a1-0000-7000-8000-000000000003' },
        },
      ],
    };
    expect(parseCreateOrderBody({ ...base, createdVia: 'customer' }).paymentMethod).toBe('cash');
    expect(() => parseCreateOrderBody({ ...base, foo: 1 })).toThrow();
    expect(() => parseCreateOrderBody({ ...base, delivery: { method: 'delivery' } })).toThrow();
    expect(() => parseCreateOrderBody({ ...base, receiver: { kind: 'other_person' } })).toThrow();
    expect(() => parseCancelBody({ reason: '', reasonCode: 'other' })).toThrow();
    expect(parseCancelBody({ reason: 'x', reasonCode: 'other', refundIntent: 'advance' }).refundIntent).toBe('advance');
  });

  describe('канал записи outbox → 1С (классификация исходов, ядро §22.1)', () => {
    const row = (
      op: 'create' | 'cancel' = 'create',
      aggregateType: OutboxRow['aggregateType'] = 'order',
    ): OutboxRow => ({
      id: '0192f3a1-0000-7000-8000-0000000000aa',
      aggregateType,
      aggregateId: '0192f3a1-0000-7000-8000-0000000000bb',
      externalId: '0192f3a1-0000-7000-8000-0000000000bb',
      operation: op,
      payload: { lines: [] },
      attempts: 1,
      createdAt: new Date(),
    });

    // 12: T-SYNC-F02 (423/503 — временная ошибка), T-FAIL-009 (1С в режиме обслуживания)
    it('201 → sent с ref; таймаут/сеть/503/423 → transient; бизнес-отказ → rejected; 401 → fatal', async () => {
      const gw = new ScriptedOnecGateway();
      const d = new OnecOutboxDelivery(gw, { timeoutMs: 200 });
      const ok = await d.deliver(row());
      expect(ok).toMatchObject({
        kind: 'sent',
        onecRef: 'b2c3d4e5-0000-4000-8000-000000000010',
        onecStatus: 'НеСогласован',
      });
      gw.script('createOrder', { hang: true });
      expect((await d.deliver(row())).kind).toBe('transient');
      gw.script(
        'createOrder',
        { transport: true },
        { error: 503 },
        { error: 423 },
        { fixture: 'orders-create.503.locked' },
      );
      for (let i = 0; i < 4; i++) expect((await d.deliver(row())).kind).toBe('transient');
      gw.script('createOrder', { fixture: 'orders-create.409.stock' }, { fixture: 'orders-create.422' });
      expect((await d.deliver(row())).kind).toBe('rejected');
      expect((await d.deliver(row())).kind).toBe('rejected');
      gw.script('createOrder', { error: 401, code: 'POS_E_UNAUTHORIZED' });
      expect((await d.deliver(row())).kind).toBe('fatal');
      gw.script('createOrder', { respond: { status: 200, body: { externalId: 'x' } } });
      expect((await d.deliver(row())).kind).toBe('transient');
      gw.script('createOrder', {
        error: 409,
        code: 'POS_E_DUPLICATE',
        details: { ref: 'b2c3d4e5-0000-4000-8000-000000000011' },
      });
      expect(await d.deliver(row())).toMatchObject({ kind: 'sent', onecRef: 'b2c3d4e5-0000-4000-8000-000000000011' });
      // Отмена заказа и неподдержанный маршрут (заявка на возврат `create` — маршрут этапа G, RM-G-005; отмены у
      // заявки нет — отклонение в POS отзывает задачу, 10 RET-013).
      expect((await d.deliver(row('cancel'))).kind).toBe('sent');
      expect((await d.deliver(row('create', 'return_request'))).kind).toBe('sent');
      expect((await d.deliver(row('cancel', 'return_request'))).kind).toBe('fatal');
    });
  });
});

describe('orderJournalAmount — знак суммы журнала по виду (07 §5.44; ревью G-returns-txn-2, G-returns-txn-3)', () => {
  it('order_cancelled — «−total» (и уже отрицательная сумма не меняет знак); подтверждения — 0; order_created — +total', () => {
    expect(orderJournalAmount('order_cancelled', '100.00')).toBe('-100.00');
    expect(orderJournalAmount('order_cancelled', '-100.00')).toBe('-100.00');
    expect(orderJournalAmount('order_cancelled', '0.00')).toBe('0.00');
    expect(orderJournalAmount('discount_override', '12.50')).toBe('0.00');
    expect(orderJournalAmount('credit_sale_approved', '5000.00')).toBe('0.00');
    expect(orderJournalAmount('order_created', '5000.00')).toBe('5000.00');
  });
});

describe('withDependencyCustomer — ссылки 1С нового клиента в теле заказа при доставке (05 SYNC-049; ревью G-customers-1c-1)', () => {
  const dep = { ref: 'c3d4e5f6-00ff-4000-8000-000000000001', contractorRef: null, agreementRef: 'a1' };
  it('заполняет только пустые поля customer.*; без зависимости или без Ref — тело без изменений', () => {
    const p = { externalId: 'x', customer: { ref: null, contractorRef: null, agreementRef: null } };
    expect(withDependencyCustomer(p, dep)).toEqual({
      externalId: 'x',
      customer: { ref: dep.ref, contractorRef: null, agreementRef: 'a1' },
    });
    const own = { customer: { ref: 'own', contractorRef: 'c', agreementRef: 'g' } };
    expect(withDependencyCustomer(own, dep)).toEqual(own);
    expect(withDependencyCustomer({ externalId: 'y' }, dep)).toEqual({
      externalId: 'y',
      customer: { ref: dep.ref, contractorRef: null, agreementRef: 'a1' },
    });
    expect(withDependencyCustomer(p, undefined)).toBe(p);
    expect(withDependencyCustomer(p, null)).toBe(p);
    expect(withDependencyCustomer(p, { ...dep, ref: null })).toBe(p);
  });
});

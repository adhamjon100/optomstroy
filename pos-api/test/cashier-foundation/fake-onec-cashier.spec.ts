import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import type { OnecJsonObject } from '../../src/integrations/onec/onec-gateway.js';
import {
  bishkekToday,
  CASHIER_SCENARIO_PHONES,
  CASHIER_SCENARIOS,
  FIXTURE_SHIPMENT_REF,
  SyntheticCashier,
} from '../../src/integrations/onec/synthetic-cashier.js';
import { ScriptedOnecGateway } from '../support/scripted-onec.gateway.js';
import { contractErrors } from './support/onec-contract.js';

/**
 * Фейк 1С этапа G (режим кассира, **тестовые данные**): клиенты, долги, реализации, скидки, создание клиента,
 * возвраты — детерминированность, соответствие контракту `contracts/onec/onec-http-service.v1.yaml`, ветки
 * 200/201/404/409/422 и план обмена `/changes`.
 */
const NOW = new Date('2026-10-21T08:00:00Z'); // 14:00 Бишкека

function cashier(extra: ConstructorParameters<typeof SyntheticCashier>[0] = {}) {
  return new SyntheticCashier({ now: () => NOW, asOf: '2026-10-21', ...extra });
}

async function drain(gw: FakeOnecGateway): Promise<{ items: OnecJsonObject[]; messageNumber: number }> {
  const items: OnecJsonObject[] = [];
  let page = await gw.getChanges({ since: 0, limit: 50 });
  items.push(...(page.body.items as unknown as OnecJsonObject[]));
  while (page.body.hasMore) {
    page = await gw.getChanges({ since: 0, limit: 50, cursor: page.body.cursor! });
    items.push(...(page.body.items as unknown as OnecJsonObject[]));
  }
  return { items, messageNumber: page.body.messageNumber };
}

describe('SyntheticCashier — состав и детерминированность', () => {
  it('одинаковые seed/asOf → идентичные элементы /changes, снимки и реализации', () => {
    const a = cashier();
    const b = cashier();
    expect(JSON.stringify(a.allItems())).toBe(JSON.stringify(b.allItems()));
    for (const ref of Object.values(CASHIER_SCENARIOS)) expect(a.getReceivables(ref)).toEqual(b.getReceivables(ref));
    const c = cashier({ seed: 8 });
    expect(JSON.stringify(c.allItems())).not.toBe(JSON.stringify(a.allItems()));
  });

  it('сценарные клиенты: долг, просрочка, лимит, неполный снимок, аванс — по фикстурам и ТЗ', () => {
    const c = cashier();
    const r = (k: keyof typeof CASHIER_SCENARIOS) => c.getReceivables(CASHIER_SCENARIOS[k]);
    expect(r('debtWithinLimit')).toMatchObject({
      balance: '12300.00',
      overdueAmount: '0.00',
      creditLimit: '100000.00',
      creditAvailable: '87700.00',
    });
    expect(r('overdue')).toMatchObject({ balance: '8000.00', overdueAmount: '8000.00', overdueDays: 12 });
    expect(r('overLimit')).toMatchObject({ balance: '49000.00', creditLimit: '50000.00', creditAvailable: '1000.00' });
    expect(r('noLimit')).toMatchObject({ creditLimit: null, creditAvailable: null, creditAllowed: true });
    expect(r('creditNotAllowed')).toMatchObject({ creditAllowed: false });
    expect(r('incomplete')).toMatchObject({ overdueAmount: null, overdueDays: null });
    expect(r('advance')).toMatchObject({ balance: '-2500.00' });
    expect(r('noDebt')).toMatchObject({ balance: '0.00', documents: [] });
    // snapshotAt — момент ответа 1С (часы теста), +06:00.
    expect(r('stale').snapshotAt).toBe('2026-10-21T14:00:00+06:00');
  });

  it('детализация: остатки документов сходятся с сальдо; типы документов разные (kind маппит G-be-credit)', () => {
    const c = cashier();
    for (const p of c.allPartners()) {
      const snap = c.receivablesOf(p.ref);
      if (!snap) continue;
      const sum = snap.documents.reduce((acc, d) => acc + BigInt(d.remaining.replace('.', '')), 0n);
      expect(sum).toBe(BigInt(snap.balance.replace('.', '')));
    }
    const types = new Set(c.receivablesOf(CASHIER_SCENARIOS.buyer)!.documents.map((d) => d.documentType));
    expect([...types].sort()).toEqual([
      'Document_ВозвратТоваровОтКлиента',
      'Document_КорректировкаРеализации',
      'Document_ПриходныйКассовыйОрдер',
      'Document_РеализацияТоваровУслуг',
    ]);
  });

  it('история продаж покупателя: реализации на SALES_HISTORY_MONTHS + 1 мес. назад, две — за границей historyFrom', () => {
    const c = cashier({ salesHistoryMonths: 12 });
    const list = c.shipmentsOf(CASHIER_SCENARIOS.buyer);
    expect(list).toHaveLength(14);
    expect(c.historyFrom()).toBe('2025-10-21');
    expect(list.filter((s) => s.date < c.historyFrom())).toHaveLength(2);
    // Возврат 1 шт. по второй реализации уже проведён в 1С.
    expect(list[1].lines[0].returnedQuantity).toBe('1.000');
    expect(list[1].returnedTotal).toBe(list[1].lines[0].price);
  });

  it('все элементы /changes, снимки и кандидаты соответствуют контракту 1С', () => {
    const c = cashier();
    for (const it of c.allItems()) expect(contractErrors('ChangeItem', it)).toEqual([]);
    for (const p of c.allPartners()) {
      if (c.receivablesOf(p.ref)) expect(contractErrors('CustomerReceivables', c.getReceivables(p.ref))).toEqual([]);
    }
    const found = c.findByPhone(CASHIER_SCENARIO_PHONES.debtWithinLimit);
    expect(found).toHaveLength(1);
    for (const x of found) expect(contractErrors('CustomerCandidate', x)).toEqual([]);
  });

  it('проверка контракта ловит нарушения (контроль проверяющего)', () => {
    const c = cashier();
    const good = c.getReceivables(CASHIER_SCENARIOS.overdue);
    expect(contractErrors('CustomerReceivables', { ...good, balance: '8000' })).not.toEqual([]);
    expect(contractErrors('CustomerReceivables', { ...good, snapshotAt: '2026-10-21T13:41:00Z' })).not.toEqual([]);
    const { documents: _omit, ...noDocs } = good;
    expect(contractErrors('CustomerReceivables', noDocs)).not.toEqual([]);
    expect(contractErrors('ChangeItem', { type: 'Catalog_Неизвестный', ref: 'x' })).not.toEqual([]);
    const partner = c.allItems().find((i) => i.type === 'Catalog_Партнеры')!;
    expect(contractErrors('ChangeItem', { ...partner, ref: 'not-a-uuid' })).not.toEqual([]);
  });

  it('discountDetails=false — правила скидок строго по контракту (только code/description)', () => {
    const strict = cashier({ discountDetails: false });
    const d = strict.allItems().filter((i) => i.type === 'Catalog_СкидкиНаценки');
    expect(d.length).toBeGreaterThan(0);
    for (const x of d)
      expect(Object.keys(x).sort()).toEqual(['code', 'dataVersion', 'deletionMark', 'description', 'ref', 'type']);
    const rich = cashier()
      .allItems()
      .find((i) => i.ref === 'd15c0000-0000-4000-8000-000000000001')!;
    expect(rich).toMatchObject({ kind: 'percent', value: '5.00', conditions: { partnerRefs: expect.any(Array) } });
  });

  it('bindProducts пересобирает реализации детерминированно по товарам каталога', () => {
    const products = [
      { productRef: 'aaaaaaaa-0000-4000-8000-000000000001', variantRef: null, name: 'Товар 1', price: '100.00' },
      { productRef: 'aaaaaaaa-0000-4000-8000-000000000002', variantRef: null, name: 'Товар 2', price: '250.50' },
    ];
    const a = cashier();
    const b = cashier();
    a.bindProducts(products);
    b.bindProducts(products);
    expect(JSON.stringify(a.allItems())).toBe(JSON.stringify(b.allItems()));
    const s = a.shipment(FIXTURE_SHIPMENT_REF)!;
    expect(s.lines.every((l) => products.some((p) => p.productRef === l.productRef))).toBe(true);
    expect(a.receivablesOf(CASHIER_SCENARIOS.buyer)!.documents[0].documentRef).toBe(
      a.shipmentsOf(CASHIER_SCENARIOS.buyer)[0].ref,
    );
  });

  it('bishkekToday — дата по UTC+6', () => {
    expect(bishkekToday(new Date('2026-10-21T19:30:00Z'))).toBe('2026-10-22');
    expect(bishkekToday(new Date('2026-10-21T17:59:59Z'))).toBe('2026-10-21');
  });
});

describe('FakeOnecGateway({ cashier }) — операции HS 1С по состоянию', () => {
  it('createCustomer: 201 новый → 200 повтор externalId → 409 POS_E_DUPLICATE с кандидатами', async () => {
    const gw = new FakeOnecGateway({ cashier: cashier() });
    const req = {
      externalId: '0192f5b1-1111-7aaa-8bbb-0000000000ff',
      name: 'Новый Клиент',
      fullName: null,
      phone: '+996555777001',
      taxId: null,
      kind: 'individual',
      priceListRef: null,
      comment: 'Создан в POS (тест)',
      dedupe: { byPhone: true, failOnDuplicate: true },
    };
    expect(contractErrors('CustomerCreateRequest', req)).toEqual([]);
    const created = await gw.createCustomer(req);
    expect(created.status).toBe(201);
    expect(contractErrors('CustomerCreateResponse', created.body)).toEqual([]);
    expect(created.body).toMatchObject({ externalId: req.externalId, created: true });
    const again = await gw.createCustomer(req);
    expect(again).toMatchObject({ status: 200, body: { ref: created.body.ref, created: false } });
    // Новый клиент виден поиском по телефону и имеет нулевой снимок долга.
    expect((await gw.findCustomersByPhone('+996555777001')).body).toEqual([
      expect.objectContaining({ ref: created.body.ref, name: 'Новый Клиент' }),
    ]);
    expect((await gw.getCustomerReceivables(created.body.ref as string)).body).toMatchObject({ balance: '0.00' });
    // Телефон существующего клиента 1С → 409 с предложением привязки.
    const dup = await gw
      .createCustomer({
        ...req,
        externalId: '0192f5b1-1111-7aaa-8bbb-0000000000fe',
        phone: CASHIER_SCENARIO_PHONES.overdue,
      })
      .catch((e: unknown) => e);
    expect(dup).toBeInstanceOf(OnecError);
    expect(dup).toMatchObject({ status: 409, code: 'POS_E_DUPLICATE' });
    expect((dup as OnecError).details).toEqual({
      candidates: [{ ref: CASHIER_SCENARIOS.overdue, name: 'Асанова Айгуль', phone: CASHIER_SCENARIO_PHONES.overdue }],
    });
    // Без failOnDuplicate — создаётся.
    const forced = await gw.createCustomer({
      ...req,
      externalId: '0192f5b1-1111-7aaa-8bbb-0000000000fd',
      phone: CASHIER_SCENARIO_PHONES.overdue,
      dedupe: { byPhone: true, failOnDuplicate: false },
    });
    expect(forced.status).toBe(201);
    // Неполный запрос → 400, телефон не E.164 → 422.
    await expect(gw.createCustomer({ externalId: 'x' })).rejects.toMatchObject({
      status: 400,
      code: 'POS_E_BAD_REQUEST',
    });
    await expect(
      gw.createCustomer({ ...req, externalId: '0192f5b1-1111-7aaa-8bbb-0000000000fc', phone: '0555' }),
    ).rejects.toMatchObject({ status: 422, code: 'POS_E_VALIDATION' });
    expect(gw.calls.filter((c) => c.operation === 'createCustomer')).toHaveLength(6);
  });

  it('getCustomerReceivables: неизвестный клиент → 404 POS_E_NOT_FOUND; снят снимок → 404', async () => {
    const c = cashier();
    const gw = new FakeOnecGateway({ cashier: c });
    await expect(gw.getCustomerReceivables('c3d4e5f6-0000-4000-8000-0000000000ee')).rejects.toMatchObject({
      status: 404,
      code: 'POS_E_NOT_FOUND',
    });
    c.setReceivables(CASHIER_SCENARIOS.noDebt, null);
    await expect(gw.getCustomerReceivables(CASHIER_SCENARIOS.noDebt)).rejects.toMatchObject({ status: 404 });
    c.setReceivables(CASHIER_SCENARIOS.noDebt, {
      balance: '100.00',
      overdueAmount: '0.00',
      overdueDays: 0,
      documents: [],
    });
    expect((await gw.getCustomerReceivables(CASHIER_SCENARIOS.noDebt)).body).toMatchObject({ balance: '100.00' });
  });

  it('createReturnRequest: 201 → 200 повтор → 409 сверх остатка → 422 нет реализации; статус и проведение возврата', async () => {
    const c = cashier();
    const gw = new FakeOnecGateway({ cashier: c });
    const s = c.shipment(FIXTURE_SHIPMENT_REF)!;
    const line = s.lines[0];
    const req = {
      externalId: '0192f5d2-3333-7ccc-8ddd-0000000000a1',
      shipmentRef: s.ref,
      orderExternalId: null,
      customerRef: s.customerRef,
      reasonCode: 'defect',
      reasonText: 'Течёт картридж',
      requestedAt: '2026-10-22T10:15:00+06:00',
      lines: [{ shipmentLineNumber: 1, productRef: line.productRef, variantRef: line.variantRef, quantity: '1.000' }],
    };
    expect(contractErrors('ReturnCreateRequest', req)).toEqual([]);
    const r1 = await gw.createReturnRequest(req);
    expect(r1.status).toBe(201);
    expect(contractErrors('ReturnRequestState', r1.body)).toEqual([]);
    expect(r1.body).toMatchObject({ status: 'submitted', onecStatus: 'НаРассмотрении' });
    expect((await gw.createReturnRequest(req)).status).toBe(200);
    // Остаток строки: отгружено − 1 (открытая заявка).
    const over = {
      ...req,
      externalId: '0192f5d2-3333-7ccc-8ddd-0000000000a2',
      lines: [{ ...req.lines[0], quantity: line.quantity }],
    };
    await expect(gw.createReturnRequest(over)).rejects.toMatchObject({ status: 409, code: 'POS_E_STATE' });
    await expect(
      gw.createReturnRequest({
        ...req,
        externalId: '0192f5d2-3333-7ccc-8ddd-0000000000a3',
        shipmentRef: 'f1e2d3c4-9999-4000-8000-000000000001',
      }),
    ).rejects.toMatchObject({ status: 422, code: 'POS_E_VALIDATION' });
    await expect(gw.getReturnRequestStatus('0192f5d2-3333-7ccc-8ddd-00000000ffff')).rejects.toMatchObject({
      status: 404,
    });
    c.setReturnStatus(req.externalId, 'accepted');
    expect((await gw.getReturnRequestStatus(req.externalId)).body).toMatchObject({
      status: 'accepted',
      onecStatus: 'КВыполнению',
    });
    c.setReturnStatus(req.externalId, 'completed');
    expect(c.shipment(FIXTURE_SHIPMENT_REF)!.lines[0].returnedQuantity).toBe('1.000');
  });

  it('/changes: план обмена кассира (клиенты → скидки → документы), ack, регистрация изменений', async () => {
    const c = cashier();
    const gw = new FakeOnecGateway({ cashier: c });
    const first = await drain(gw);
    const types = first.items.map((i) => i.type as string);
    expect(types.indexOf('Catalog_Партнеры')).toBeLessThan(types.indexOf('Catalog_СкидкиНаценки'));
    expect(types.lastIndexOf('Catalog_СоглашенияСКлиентами')).toBeLessThan(
      types.indexOf('Document_РеализацияТоваровУслуг'),
    );
    expect(first.items.length).toBe(c.allItems().length);
    await gw.ackChanges(first.messageNumber);
    // После ack — пусто; изменение условий соглашения → в следующем сообщении партнёр, контрагент и соглашение.
    expect((await gw.getChanges({ since: first.messageNumber })).body.items).toHaveLength(0);
    c.updatePartner(CASHIER_SCENARIOS.noDebt, { creditLimit: '70000.00' });
    const next = await gw.getChanges({ since: first.messageNumber });
    const agreement = next.body.items.find((i) => i.type === 'Catalog_СоглашенияСКлиентами');
    expect(next.body.items).toHaveLength(3);
    expect(agreement).toMatchObject({ partnerRef: CASHIER_SCENARIOS.noDebt, creditLimit: '70000.00' });
  });

  it('каталог + кассир: строки реализаций ссылаются на товары синтетического каталога', async () => {
    const gw = new FakeOnecGateway({ catalog: { skuCount: 30, seed: 3 }, cashier: { now: () => NOW } });
    const productRefs = new Set(gw.catalog!.productItems().map((p) => p.ref));
    const ship = gw.cashier!.shipment(FIXTURE_SHIPMENT_REF)!;
    expect(ship.lines.every((l) => productRefs.has(l.productRef))).toBe(true);
    const all = await drain(gw);
    expect(all.items.some((i) => i.type === 'Catalog_Номенклатура')).toBe(true);
    expect(all.items.some((i) => i.type === 'Catalog_Партнеры')).toBe(true);
  });

  it('без режима кассира — ответы фикстур (обратная совместимость этапов D–F)', async () => {
    const gw = new FakeOnecGateway();
    expect((await gw.createCustomer({ externalId: 'any' })).status).toBe(201);
    expect((await gw.getCustomerReceivables('c3d4e5f6-0000-4000-8000-000000000001')).body).toMatchObject({
      balance: '12300.00',
      snapshotAt: '2026-10-21T13:39:05+06:00',
    });
  });

  it('ScriptedOnecGateway: сценарии поверх синтетики (503 → ответ по состоянию; сеть)', async () => {
    const gw = new ScriptedOnecGateway({ cashier: cashier() });
    gw.script('createCustomer', { error: 503 });
    gw.always('findCustomersByPhone', { transport: true });
    const req = {
      externalId: '0192f5b1-1111-7aaa-8bbb-0000000000aa',
      name: 'Клиент Сценария',
      phone: '+996555777009',
      kind: 'individual',
      dedupe: { byPhone: true, failOnDuplicate: true },
    };
    await expect(gw.createCustomer(req)).rejects.toMatchObject({ status: 503, code: 'POS_E_MAINTENANCE' });
    expect((await gw.createCustomer(req)).status).toBe(201);
    await expect(gw.findCustomersByPhone('+996555777009')).rejects.toMatchObject({ status: 0, code: 'TRANSPORT' });
    gw.script('createReturnRequest', { fixture: 'returns-create.409' });
    await expect(gw.createReturnRequest({})).rejects.toMatchObject({ status: 409 });
    gw.script('getReturnRequestStatus', { fixture: 'returns-status.200' });
    expect((await gw.getReturnRequestStatus('x')).body).toMatchObject({ status: 'accepted' });
  });
});

import { randomUUID } from 'node:crypto';
import { Money } from '../../src/common/money/money.js';
import { CASHIER_SCENARIO_PHONES, CASHIER_SCENARIOS } from '../../src/integrations/onec/synthetic-cashier.js';
import { deliverCustomerCreate } from '../../src/sync/outbox/customer-outbox.route.js';
import { contractErrors } from '../cashier-foundation/support/onec-contract.js';
import type { CashierWorld } from '../support/cashier-fixture.js';
import { apiErrors, CustomersTestApp } from './support/customers-app.js';

/**
 * RM-G-001 (агент G-be-customers), **тестовые данные**: история покупок из проекции «Реализаций» 1С (`shipments`) и
 * заказов POS (`CustomerHistory.summary`, `historyFrom`, доступ по ролям), создание клиента с дедупликацией по
 * телефону (реплика и синхронный поиск 1С), `forceReason`/`customer.create.force`, повтор по `Idempotency-Key`,
 * outbox → 1С 201 (`onec_ref` заполняется), 200 (повтор `externalId`), 409 `POS_E_DUPLICATE`.
 */
let t: CustomersTestApp;
let w: CashierWorld;

beforeAll(async () => {
  t = await new CustomersTestApp().start({ env: { QR_PROVIDER: 'none' } });
  w = await t.seedCashierWorld();
}, 600_000);

afterAll(async () => {
  await t?.stop();
});

let phoneSeq = 0;
function newPhone(): string {
  phoneSeq += 1;
  return `+99655577${String(phoneSeq).padStart(4, '0')}`;
}

function body(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return { name: 'Тестов Клиент', customerType: 'individual', phones: [newPhone()], ...extra };
}

// Вся история фикстуры — за последний год (по умолчанию период — 90 дней, 10 CUST-005; ревью G-customers-1c-7).
const YEAR = `from=${encodeURIComponent(new Date(Date.now() - 365 * 86_400_000).toISOString())}`;

describe('GET /customers/{id}/orders — история покупок (CUST-005; RM-G-001 п. 4)', () => {
  it('строится из shipments/shipment_items фикстуры «Реализаций» и заказов POS; summary и historyFrom', async () => {
    const res = await t.req('get', `/customers/${w.customers.buyer.id}/orders?limit=200&${YEAR}`, w.actors.cashier);
    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(apiErrors('CustomerHistory', res.body)).toEqual([]);
    expect(res.body.historyFrom).toBe(w.historyFrom);
    const items = res.body.items as {
      kind: string;
      id: string;
      number: string;
      total: { amount: string };
      source: string;
      status: string;
      date: string;
      url: string | null;
    }[];
    const shipments = await t.q<{ id: string; onec_code: string; total: string; order_id: string | null }>(
      `SELECT id, onec_code, total::text AS total, order_id FROM shipments
        WHERE customer_id = $1::uuid AND posted AND NOT deletion_mark`,
      [w.customers.buyer.id],
    );
    const unlinked = shipments.filter((s) => s.order_id === null);
    expect(unlinked.length).toBe(
      t.cashier.shipmentsOf(CASHIER_SCENARIOS.buyer).filter((s) => s.date >= w.historyFrom).length - 1,
    );
    // Реализация по заказу POS отдельной строкой не показывается (тот же заказ); прочие — kind=shipment, source=onec.
    expect(
      items
        .filter((i) => i.kind === 'shipment')
        .map((i) => i.id)
        .sort(),
    ).toEqual(unlinked.map((s) => s.id).sort());
    expect(items.some((i) => i.id === w.shipments.buyerLatest.id)).toBe(false);
    const orders = items.filter((i) => i.kind === 'order');
    expect(orders.map((o) => o.id).sort()).toEqual(
      [w.orders.buyerShipped.orderId, w.orders.buyerRequest.orderId].sort(),
    );
    expect(orders[0]).toMatchObject({ source: 'pos', url: `/api/v1/orders/${orders[0].id}` });
    const ship = items.find((i) => i.kind === 'shipment')!;
    expect(ship).toMatchObject({ source: 'onec', url: null });
    expect(unlinked.find((s) => s.id === ship.id)?.onec_code).toBe(ship.number);
    expect(items.some((i) => i.status === 'partially_returned')).toBe(true);
    // Порядок — новые сверху; сводка — по всем строкам (отменённых нет).
    const dates = items.map((i) => Date.parse(i.date));
    expect([...dates].sort((a, b) => b - a)).toEqual(dates);
    const sum = items.reduce((acc, i) => acc.plus(Money.of(i.total.amount)), Money.ZERO).toString();
    expect(res.body.summary).toMatchObject({ count: items.length, total: { amount: sum, currency: 'KGS' } });
    expect(res.body.summary.lastOrderAt).toBe(items[0].date);
  });

  it('фильтры source/period, курсор, 367 дней → 400; аудит debt_viewed у сотрудника, не у клиента', async () => {
    const onec = await t.req('get', `/customers/${w.customers.buyer.id}/orders?source=onec&${YEAR}`, w.actors.owner);
    expect((onec.body.items as { kind: string }[]).every((i) => i.kind === 'shipment')).toBe(true);
    const pos = await t.req('get', `/customers/${w.customers.buyer.id}/orders?source=pos&${YEAR}`, w.actors.owner);
    expect(pos.body.summary.count).toBe(2);
    const p1 = await t.req('get', `/customers/${w.customers.buyer.id}/orders?limit=4&${YEAR}`, w.actors.admin);
    expect(p1.body.hasMore).toBe(true);
    const p2 = await t.req(
      'get',
      `/customers/${w.customers.buyer.id}/orders?limit=4&${YEAR}&cursor=${encodeURIComponent(p1.body.nextCursor as string)}`,
      w.actors.admin,
    );
    const first = new Set((p1.body.items as { id: string }[]).map((i) => i.id));
    expect((p2.body.items as { id: string }[]).some((i) => first.has(i.id))).toBe(false);
    expect(p2.body.summary).toEqual(p1.body.summary);
    const to = new Date();
    const from = new Date(to.getTime() - 60 * 86_400_000);
    const period = await t.req(
      'get',
      `/customers/${w.customers.buyer.id}/orders?from=${from.toISOString()}&to=${to.toISOString()}`,
      w.actors.cashier,
    );
    expect((period.body.items as { date: string }[]).every((i) => Date.parse(i.date) >= from.getTime())).toBe(true);
    const tooLong = new Date(to.getTime() - 367 * 86_400_000);
    const bad = await t.req(
      'get',
      `/customers/${w.customers.buyer.id}/orders?from=${tooLong.toISOString()}&to=${to.toISOString()}`,
      w.actors.cashier,
    );
    expect(bad.status).toBe(400);
    expect(bad.body.errors[0]).toMatchObject({ rule: 'date_range' });
    const audit = await t.auditRows('customer.debt_viewed', w.customers.buyer.id);
    expect(
      audit.filter((a) => (a.after as { scope?: string } | null)?.scope === 'history').length,
    ).toBeGreaterThanOrEqual(4);
    const before = audit.length;
    const self = await t.req('get', `/customers/${w.customers.buyer.id}/orders`, w.buyerConfirmed);
    expect(self.status).toBe(200);
    expect(await t.auditRows('customer.debt_viewed', w.customers.buyer.id)).toHaveLength(before);
  });

  it('доступ: seller → 403; customer — своя при confirmed, иначе 404; «Розничный» — пустая история', async () => {
    expect((await t.req('get', `/customers/${w.customers.buyer.id}/orders`, w.actors.seller)).status).toBe(403);
    expect((await t.req('get', `/customers/${w.customers.buyer.id}/orders`, w.buyerProposed)).status).toBe(404);
    expect((await t.req('get', `/customers/${w.customers.overdue.id}/orders`, w.buyerConfirmed)).status).toBe(404);
    expect(
      (await t.req('get', `/customers/0192e0b2-0000-7000-8000-00000000dead/orders`, w.actors.cashier)).status,
    ).toBe(404);
    const retail = await t.req('get', `/customers/${w.customers.retail.id}/orders`, w.actors.cashier);
    expect(retail.body).toMatchObject({ items: [], summary: { count: 0 } });
  });
});

describe('POST /customers — создание с дедупликацией (CUST-010…016; RM-G-001 пп. 2–3)', () => {
  it('новый клиент → 201 (source=pos, onecStatus=pending, onecRef=null) + outbox customer; повтор ключа — replay', async () => {
    const key = randomUUID();
    const b = body({
      inn: '01234567890123',
      address: 'г. Бишкек, ул. Тестовая 1',
      customerType: 'legal',
      name: 'ОсОО «Новый Клиент»',
    });
    const res = await t.req('post', '/customers', w.actors.cashier, { idem: key }).send(b);
    expect(res.status).toBe(201);
    expect(apiErrors('CustomerViewCashier', res.body)).toEqual([]);
    expect(res.body).toMatchObject({
      source: 'pos',
      onecStatus: 'pending',
      onecRef: null,
      customerType: 'legal',
      inn: '01234567890123',
      phones: [{ value: (b.phones as string[])[0], verified: false }],
      addresses: ['г. Бишкек, ул. Тестовая 1'],
      hasDebt: false,
    });
    const replay = await t.req('post', '/customers', w.actors.cashier, { idem: key }).send(b);
    expect(replay.status).toBe(201);
    expect(replay.headers['idempotent-replayed']).toBe('true');
    expect(replay.body.id).toBe(res.body.id);
    expect(await t.q(`SELECT 1 FROM customers WHERE name = 'ОсОО «Новый Клиент»'`)).toHaveLength(1);
    const ob = await t.q<{ status: string; payload: Record<string, unknown>; external_id: string; priority: number }>(
      `SELECT status::text AS status, payload, external_id, priority FROM onec_outbox
        WHERE aggregate_type = 'customer' AND aggregate_id = $1::uuid`,
      [res.body.id],
    );
    expect(ob).toHaveLength(1);
    expect(ob[0]).toMatchObject({ status: 'pending', external_id: res.body.id, priority: 10 });
    expect(contractErrors('CustomerCreateRequest', ob[0].payload)).toEqual([]);
    expect(ob[0].payload).toMatchObject({
      externalId: res.body.id,
      phone: (b.phones as string[])[0],
      kind: 'legal',
      taxId: '01234567890123',
      dedupe: { byPhone: true, failOnDuplicate: true },
    });
    const audit = await t.auditRows('customer.created', res.body.id);
    expect(audit.some((a) => a.after && a.after.forceCreate === false)).toBe(true);
    // Без ключа — 400/422 (Idempotency-Key обязателен, 08 §2.7).
    expect([400, 422, 428]).toContain((await t.req('post', '/customers', w.actors.cashier).send(body())).status);
  });

  it('новый клиент → outbox → 1С 201 → onec_ref заполняется; повтор externalId → 200 с тем же Ref', async () => {
    const res = await t
      .req('post', '/customers', w.actors.seller, { idem: true })
      .send(body({ name: 'Клиент Для 1С' }));
    expect(res.status).toBe(201);
    expect(apiErrors('CustomerViewSeller', res.body)).toEqual([]);
    const id = res.body.id as string;
    expect((await t.customerRow(id)).onec_ref).toBeNull();
    await t.drainOutbox();
    const row = await t.customerRow(id);
    expect(row).toMatchObject({ onec_status: 'confirmed', source: 'pos' });
    expect(row.onec_ref).toMatch(/^c3d4e5f6-00ff-/);
    expect(row.onec_code).not.toBeNull();
    const partner = t.cashier.allPartners().find((p) => p.externalId === id);
    expect(partner?.ref).toBe(row.onec_ref);
    const ob = (
      await t.q<{
        id: string;
        status: string;
        payload: Record<string, unknown>;
        external_id: string;
        attempts: number;
        created_at: Date;
      }>(
        `SELECT id, status::text AS status, payload, external_id, attempts, created_at FROM onec_outbox
          WHERE aggregate_type = 'customer' AND aggregate_id = $1::uuid`,
        [id],
      )
    )[0];
    expect(ob.status).toBe('sent');
    const again = await deliverCustomerCreate(
      t.onec,
      {
        id: ob.id,
        aggregateType: 'customer',
        aggregateId: id,
        externalId: ob.external_id,
        operation: 'create',
        payload: ob.payload,
        attempts: 2,
        createdAt: ob.created_at,
      },
      ob.payload as never,
      {},
    );
    expect(again).toMatchObject({ kind: 'sent', onecRef: row.onec_ref, response: { created: false } });
    // Повторная доставка события результата ничего не меняет (идемпотентно по outboxId).
    expect(
      await t.results.onConfirmed({
        outboxId: ob.id,
        aggregateId: id,
        onecRef: row.onec_ref!,
        onecNumber: null,
        onecStatus: null,
        attempt: 2,
      }),
    ).toBe('skipped');
    const card = await t.req('get', `/customers/${id}`, w.actors.cashier);
    expect(card.body).toMatchObject({ onecStatus: 'confirmed', onecRef: row.onec_ref });
  });

  it('телефон существующего клиента реплики → 409 CUSTOMER_DUPLICATE_SUSPECTED с кандидатом (предложение привязки)', async () => {
    const res = await t
      .req('post', '/customers', w.actors.seller, { idem: true })
      .send(body({ phones: [CASHIER_SCENARIO_PHONES.debtWithinLimit] }));
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CUSTOMER_DUPLICATE_SUSPECTED');
    expect(res.body.candidates).toEqual([
      expect.objectContaining({
        id: w.customers.debtWithinLimit.id,
        displayName: 'Асанов Бакыт',
        phoneMasked: '+996 7** *** *56',
        source: 'onec',
      }),
    ]);
    expect(JSON.stringify(res.body)).not.toContain(CASHIER_SCENARIO_PHONES.debtWithinLimit);
    // ИНН существующего клиента — тоже дубль.
    const inn = (await t.customerRow(w.customers.noDebt.id)).inn!;
    const byInn = await t
      .req('post', '/customers', w.actors.cashier, { idem: true })
      .send(body({ inn, customerType: 'legal' }));
    expect(byInn.status).toBe(409);
    expect((byInn.body.candidates as { id: string }[]).map((c) => c.id)).toContain(w.customers.noDebt.id);
  });

  it('телефон есть только в 1С (не в реплике) → синхронный поиск 1С находит → 409 (T-CUST-004)', async () => {
    const phone = newPhone();
    t.cashier.createCustomer({
      externalId: randomUUID(),
      name: 'Клиент Только В 1С',
      phone,
      kind: 'individual',
      dedupe: { byPhone: true, failOnDuplicate: true },
    });
    expect(await t.q(`SELECT 1 FROM customers WHERE $1 = ANY(phones_norm)`, [phone])).toHaveLength(0);
    const res = await t.req('post', '/customers', w.actors.cashier, { idem: true }).send(body({ phones: [phone] }));
    expect(res.status).toBe(409);
    expect(res.body.candidates[0]).toMatchObject({ source: 'onec', displayName: 'Клиент Только В 1С' });
  });

  it('«Всё равно создать»: seller → 403; без причины → 400 force_reason_required; cashier с причиной → 201 + аудит', async () => {
    const dup = { phones: [CASHIER_SCENARIO_PHONES.overdue] };
    const seller = await t
      .req('post', '/customers', w.actors.seller, { idem: true })
      .send(body({ ...dup, forceCreate: true, forceReason: 'Другой человек' }));
    expect(seller.status).toBe(403);
    const noReason = await t
      .req('post', '/customers', w.actors.cashier, { idem: true })
      .send(body({ ...dup, forceCreate: true }));
    expect(noReason.status).toBe(400);
    expect(noReason.body.errors[0]).toMatchObject({ rule: 'force_reason_required' });
    const reasonWithoutForce = await t
      .req('post', '/customers', w.actors.cashier, { idem: true })
      .send(body({ forceReason: 'Лишняя причина' }));
    expect(reasonWithoutForce.status).toBe(400);
    const ok = await t
      .req('post', '/customers', w.actors.senior_seller, { idem: true })
      .send(body({ ...dup, forceCreate: true, forceReason: 'Однофамилец, другой номер договора' }));
    expect(ok.status).toBe(201);
    expect((await t.customerRow(ok.body.id)).force_reason).toBe('Однофамилец, другой номер договора');
    const audit = await t.auditRows('customer.created', ok.body.id);
    const app = audit.find((a) => a.after && 'forceCreate' in (a.after as object));
    expect(app?.after).toMatchObject({ forceCreate: true, candidatesCount: 1 });
    const payload = (
      await t.q<{ payload: { dedupe: { failOnDuplicate: boolean } } }>(
        `SELECT payload FROM onec_outbox WHERE aggregate_type = 'customer' AND aggregate_id = $1::uuid`,
        [ok.body.id],
      )
    )[0].payload;
    expect(payload.dedupe.failOnDuplicate).toBe(false);
  });

  it('проверка тела: телефон, ИНН, тип, длина имени, лишние поля; customer → 403', async () => {
    const cases: [Record<string, unknown>, string][] = [
      [{ phones: [] }, 'min_items'],
      [{ phones: ['0700123456'] }, 'phone_e164'],
      [{ inn: '123' }, 'pattern'],
      [{ customerType: 'company' }, 'enum'],
      [{ name: 'Я' }, 'min_length'],
      [{ name: 'Я'.repeat(151) }, 'max_length'],
      [{ extra: 1 }, 'additional_properties'],
    ];
    for (const [patch, rule] of cases) {
      const r = await t.req('post', '/customers', w.actors.cashier, { idem: true }).send(body(patch));
      expect(r.status).toBe(400);
      expect(r.body.errors[0]).toMatchObject({ rule });
    }
    expect((await t.req('post', '/customers', w.actors.customer, { idem: true }).send(body())).status).toBe(403);
    expect((await t.req('post', '/customers', w.actors.owner, { idem: true }).send(body())).status).toBe(403);
  });

  it('1С недоступна при проверке → клиент создаётся; 1С при создании нашла дубль → outbox failed, onecStatus=duplicate', async () => {
    const phone = newPhone();
    t.cashier.createCustomer({
      externalId: randomUUID(),
      name: 'Карточка Уже В 1С',
      phone,
      kind: 'individual',
      dedupe: { byPhone: true, failOnDuplicate: true },
    });
    t.onec.script('findCustomersByPhone', { transport: true });
    const res = await t.req('post', '/customers', w.actors.cashier, { idem: true }).send(body({ phones: [phone] }));
    expect(res.status).toBe(201);
    const audit = await t.auditRows('customer.created', res.body.id);
    expect(audit.some((a) => a.after?.onecCheck === 'unavailable')).toBe(true);
    await t.drainOutbox();
    const ob = await t.q<{ status: string; onec_response: { code: string } }>(
      `SELECT status::text AS status, onec_response FROM onec_outbox WHERE aggregate_type = 'customer' AND aggregate_id = $1::uuid`,
      [res.body.id],
    );
    expect(ob[0]).toMatchObject({ status: 'failed', onec_response: { code: 'POS_E_DUPLICATE' } });
    expect(await t.customerRow(res.body.id)).toMatchObject({ onec_status: 'duplicate', onec_ref: null });
    expect(t.published.some((p) => p.name === 'customers.onec-failed' && p.data.aggregateId === res.body.id)).toBe(
      true,
    );
  });
});

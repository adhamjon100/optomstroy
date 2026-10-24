import { randomUUID } from 'node:crypto';
import pino from 'pino';
import type { SyncEntity } from '../../src/common/enums.js';
import { CASHIER_SCENARIO_PHONES, CASHIER_SCENARIOS } from '../../src/integrations/onec/synthetic-cashier.js';
import type { ApplyScope, EntityCounts } from '../../src/sync/apply/apply.types.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import { normalizeKgPhone, parseContactPhones } from '../../src/sync/customers/customer-phones.js';
import { CustomersChangeHandler, salesHistoryFrom } from '../../src/sync/customers/customers-change.handler.js';
import type { PosActor } from '../support/pos-fixture.js';
import { CustomersTestApp } from './support/customers-app.js';

/**
 * RM-G-001 (агент G-be-customers), **тестовые данные**: синхронизация клиентов (`Catalog_Партнеры`/`Контрагенты`/
 * `СоглашенияСКлиентами` → `customers`, `customer_contacts`) и истории продаж (`Document_РеализацияТоваровУслуг` →
 * `shipments`/`shipment_items`, глубина `SALES_HISTORY_MONTHS`) по плану обмена фейка 1С: первичная загрузка,
 * инкремент, пометка удаления, исчезновение телефона привязанного клиента, подтверждение POS-клиента по `externalId`.
 */
let t: CustomersTestApp;
let cashier: PosActor;
const silent = pino({ level: 'silent' });
const handler = new CustomersChangeHandler({ salesHistoryMonths: 12 });

function changes(): OnecChangesService {
  return new OnecChangesService(t.pool, t.onec, new CatalogApplier(), createRunTracker(t.pool), silent, {
    reconcileWithHealth: false,
    handlers: [handler],
    planEntities: [],
  });
}

async function idOf(onecRef: string): Promise<string> {
  return (await t.q<{ id: string }>(`SELECT id FROM customers WHERE onec_ref = $1::uuid`, [onecRef]))[0].id;
}

beforeAll(async () => {
  t = await new CustomersTestApp().start({ env: { QR_PROVIDER: 'none' } });
  cashier = await t.actor({ role: 'cashier' });
}, 600_000);

afterAll(async () => {
  await t?.stop();
});

describe('нормализация телефонов (ONEC-012)', () => {
  it('0700123456, 996700123456 и +996700123456 — один E.164; нераспознанное — только представление', () => {
    expect(normalizeKgPhone('0700123456')).toBe('+996700123456');
    expect(normalizeKgPhone('+996 (700) 123-456')).toBe('+996700123456');
    expect(normalizeKgPhone('12345')).toBeNull();
    expect(
      parseContactPhones([
        { phone: null, presentation: '0700 12 34 56' },
        { phone: '+996700123456', presentation: '+996 (700) 123-456' },
        { phone: null, presentation: 'доб. 12' },
      ]),
    ).toEqual([
      { e164: '+996700123456', raw: '0700 12 34 56' },
      { e164: null, raw: 'доб. 12' },
    ]);
  });
});

describe('синхронизация клиентов и истории продаж из 1С', () => {
  it('первичная загрузка: клиенты с контактами и условиями соглашений, реализации в глубине SALES_HISTORY_MONTHS', async () => {
    const r = await changes().pullOnce({ trigger: 'manual' });
    expect(r.status).toBe('applied');
    const partners = t.cashier.allPartners();
    const counts = r.counts as Partial<Record<SyncEntity, EntityCounts>>;
    expect(counts.customers?.inserted).toBe(partners.length);
    expect(counts.customers?.errors).toBe(0);
    const n = await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM customers WHERE source = 'onec'`);
    expect(n[0].n).toBe(partners.length);
    const dwl = (
      await t.q<{
        id: string;
        customer_type: string;
        credit_limit: string;
        credit_days: number;
        discount_percent: string;
        credit_allowed: boolean;
        primary_phone_e164: string;
        phones_norm: string[];
        onec_code: string;
        onec_agreement_ref: string;
        onec_counterparty_ref: string;
        synced_at: Date | null;
      }>(
        `SELECT id, customer_type::text AS customer_type, credit_limit::text AS credit_limit, credit_days,
                discount_percent::text AS discount_percent, credit_allowed, primary_phone_e164, phones_norm, onec_code,
                onec_agreement_ref::text AS onec_agreement_ref, onec_counterparty_ref::text AS onec_counterparty_ref,
                synced_at
           FROM customers WHERE onec_ref = $1::uuid`,
        [CASHIER_SCENARIOS.debtWithinLimit],
      )
    )[0];
    const p = t.cashier.partner(CASHIER_SCENARIOS.debtWithinLimit)!;
    expect(dwl).toMatchObject({
      customer_type: 'individual',
      credit_limit: '100000.00',
      credit_days: 14,
      discount_percent: '5.00',
      credit_allowed: true,
      primary_phone_e164: CASHIER_SCENARIO_PHONES.debtWithinLimit,
      phones_norm: [CASHIER_SCENARIO_PHONES.debtWithinLimit],
      onec_code: p.code,
      onec_agreement_ref: p.agreementRef,
      onec_counterparty_ref: p.counterpartyRef,
    });
    expect(dwl.synced_at).not.toBeNull();
    // Один телефон партнёра и контрагента — одна строка контактов.
    const contacts = await t.q(
      `SELECT 1 FROM customer_contacts WHERE customer_id = $1::uuid AND kind = 'phone' AND deleted_at IS NULL`,
      [dwl.id],
    );
    expect(contacts).toHaveLength(1);
    const legal = await t.customerRow(await idOf(CASHIER_SCENARIOS.noDebt));
    expect(legal).toMatchObject({ customer_type: 'legal', inn: t.cashier.partner(CASHIER_SCENARIOS.noDebt)!.taxId });
    const noCredit = await t.customerRow(await idOf(CASHIER_SCENARIOS.creditNotAllowed));
    expect(noCredit.credit_limit).toBeNull();
    const deleted = partners.filter((x) => x.deletionMark);
    expect(deleted.length).toBeGreaterThan(0);
    for (const d of deleted) expect((await t.customerRow(await idOf(d.ref))).deletion_mark).toBe(true);
    // История продаж: только в глубине SALES_HISTORY_MONTHS (две реализации покупателя — за границей).
    const from = salesHistoryFrom(12, new Date());
    const expected = partners.flatMap((x) => t.cashier.shipmentsOf(x.ref)).filter((s) => s.date >= from);
    const shipped = await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM shipments`);
    expect(shipped[0].n).toBe(expected.length);
    expect(counts.sales_history?.inserted).toBe(expected.length);
    expect(counts.sales_history?.skipped).toBeGreaterThanOrEqual(2);
    const buyerId = await idOf(CASHIER_SCENARIOS.buyer);
    const buyerShipments = await t.q<{ n: number }>(
      `SELECT count(*)::int AS n FROM shipments WHERE customer_id = $1::uuid`,
      [buyerId],
    );
    expect(buyerShipments[0].n).toBe(
      t.cashier.shipmentsOf(CASHIER_SCENARIOS.buyer).filter((s) => s.date >= from).length,
    );
    const items = await t.q<{ variant_id: string | null; quantity: string; base_quantity: string }>(
      `SELECT variant_id, quantity::text AS quantity, base_quantity::text AS base_quantity FROM shipment_items`,
    );
    expect(items.length).toBeGreaterThan(0);
    expect(items.every((i) => i.variant_id !== null && i.quantity === i.base_quantity)).toBe(true);
    const runs = await t.q<{ entity: string; status: string }>(
      `SELECT entity::text AS entity, status::text AS status FROM sync_runs WHERE entity IN ('customers','sales_history')`,
    );
    expect(runs.map((x) => `${x.entity}:${x.status}`).sort()).toEqual(['customers:success', 'sales_history:success']);
    // История покупок API строится из загруженных реализаций.
    const hist = await t.req(
      'get',
      `/customers/${buyerId}/orders?source=onec&limit=200&from=${encodeURIComponent(new Date(Date.now() - 365 * 86_400_000).toISOString())}`,
      cashier,
    );
    expect(hist.status).toBe(200);
    expect(hist.body.items).toHaveLength(buyerShipments[0].n);
    // Повторный цикл без изменений — пустое сообщение.
    expect((await changes().pullOnce()).status).toBe('empty');
  });

  it('инкремент: новые условия и телефон соглашения; исчезнувший телефон привязанного клиента → привязка conflict', async () => {
    const id = await idOf(CASHIER_SCENARIOS.noDebt);
    const user = await t.actor({ role: 'customer' });
    await t.pool.query(
      `INSERT INTO customer_links (user_id, customer_id, status, match_method, matched_phone_e164, confirmed_at)
       VALUES ($1::uuid, $2::uuid, 'confirmed', 'phone', $3, now())`,
      [user.userId, id, CASHIER_SCENARIO_PHONES.noDebt],
    );
    t.cashier.updatePartner(CASHIER_SCENARIOS.noDebt, { creditLimit: '70000.00', phones: ['+996555000203'] });
    const r = await changes().pullOnce();
    expect(r.status).toBe('applied');
    const row = await t.customerRow(id);
    expect(row).toMatchObject({
      credit_limit: '70000.00',
      primary_phone_e164: '+996555000203',
      phones_norm: ['+996555000203'],
    });
    const old = await t.q<{ deleted_at: Date | null }>(
      `SELECT deleted_at FROM customer_contacts WHERE customer_id = $1::uuid AND value_norm = $2`,
      [id, CASHIER_SCENARIO_PHONES.noDebt],
    );
    expect(old[0].deleted_at).not.toBeNull();
    const link = await t.q<{ status: string; reason: string }>(
      `SELECT status::text AS status, reason FROM customer_links WHERE user_id = $1::uuid`,
      [user.userId],
    );
    expect(link[0]).toMatchObject({ status: 'conflict', reason: 'phone_removed_in_onec' });
    // Пометка удаления партнёра → deletion_mark; карточка пропадает из поиска.
    t.cashier.updatePartner(CASHIER_SCENARIOS.overLimit, { deletionMark: true });
    await changes().pullOnce();
    const ol = await idOf(CASHIER_SCENARIOS.overLimit);
    expect((await t.customerRow(ol)).deletion_mark).toBe(true);
    const search = await t.req(
      'get',
      `/search/customers?q=${encodeURIComponent(CASHIER_SCENARIO_PHONES.overLimit)}`,
      cashier,
    );
    expect(search.body.items).toHaveLength(0);
  });

  it('POS-клиент: 1С подтверждает по externalId — та же строка, outbox sent → confirmed (до и после события результата)', async () => {
    // (а) Событие результата раньше синхронизации.
    const a = await t
      .req('post', '/customers', cashier, { idem: true })
      .send({ name: 'Новый Через POS', customerType: 'entrepreneur', phones: ['+996555880001'] });
    expect(a.status).toBe(201);
    await t.drainOutbox();
    const ref = (await t.customerRow(a.body.id)).onec_ref!;
    await changes().pullOnce();
    const rows = await t.q<{ id: string }>(`SELECT id FROM customers WHERE onec_ref = $1::uuid`, [ref]);
    expect(rows.map((x) => x.id)).toEqual([a.body.id]);
    expect(await t.customerRow(a.body.id)).toMatchObject({
      source: 'pos',
      onec_status: 'confirmed',
      customer_type: 'entrepreneur',
    });
    const ob = await t.q<{ status: string }>(
      `SELECT status::text AS status FROM onec_outbox WHERE aggregate_type = 'customer' AND aggregate_id = $1::uuid`,
      [a.body.id],
    );
    expect(ob[0].status).toBe('confirmed');
    // (б) Синхронизация раньше события результата: элемент партнёра с externalId «усыновляет» карточку POS.
    const b = await t
      .req('post', '/customers', cashier, { idem: true })
      .send({ name: 'Второй Через POS', customerType: 'individual', phones: ['+996555880002'] });
    await t.pool.query(`UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE status = 'pending'`);
    const before = t.published.length;
    await t.dispatcher.tick(); // событие опубликовано, но не обработано
    expect(t.published.length).toBe(before + 1);
    await changes().pullOnce();
    const rowB = await t.customerRow(b.body.id);
    expect(rowB.onec_status).toBe('confirmed');
    expect(rowB.onec_ref).not.toBeNull();
    const data = t.published[before].data as never;
    expect(await t.results.onConfirmed(data)).toBe('skipped');
    await t.drainOutbox();
  });

  it('реализация по заказу POS связывается с заказом; ObjectDeletion — пометка удаления; неизвестный клиент — sync_errors', async () => {
    const buyerId = await idOf(CASHIER_SCENARIOS.buyer);
    const order = await t.seedOrder({
      createdBy: cashier,
      customerId: buyerId,
      method: 'cash',
      status: 'awaiting_shipment',
    });
    const latest = t.cashier.shipmentsOf(CASHIER_SCENARIOS.buyer)[0];
    t.cashier.linkShipmentToOrder(latest.ref, order.orderId);
    await changes().pullOnce();
    const s = await t.q<{ order_id: string | null }>(`SELECT order_id FROM shipments WHERE onec_ref = $1::uuid`, [
      latest.ref,
    ]);
    expect(s[0].order_id).toBe(order.orderId);
    // Прямой вызов обработчика: удаление объектов и реализация неизвестного клиента.
    const c = await t.pool.connect();
    try {
      await c.query('BEGIN');
      const scope: ApplyScope = {
        client: c,
        syncedAt: new Date(),
        counts: new Map(),
        errors: [],
        runIdFor: () => Promise.resolve(randomUUID()),
      };
      await handler.apply(scope, [
        { type: 'ObjectDeletion', objectType: 'Document_РеализацияТоваровУслуг', ref: latest.ref },
        { type: 'ObjectDeletion', objectType: 'Catalog_Партнеры', ref: CASHIER_SCENARIOS.advance },
        {
          type: 'Document_РеализацияТоваровУслуг',
          ref: randomUUID(),
          dataVersion: 'AAAAAQ==',
          deletionMark: false,
          number: 'РТ00-999999',
          date: new Date().toISOString().replace('Z', '+00:00'),
          posted: true,
          customerRef: randomUUID(),
          lines: [],
        },
      ]);
      await c.query('COMMIT');
      expect(scope.errors.map((e) => e.errorCode)).toEqual(['NOT_FOUND_LOCAL']);
      expect(scope.counts.get('sales_history')?.markedDeleted).toBe(1);
      expect(scope.counts.get('customers')?.markedDeleted).toBe(1);
    } finally {
      c.release();
    }
    const del = await t.q<{ deletion_mark: boolean }>(`SELECT deletion_mark FROM shipments WHERE onec_ref = $1::uuid`, [
      latest.ref,
    ]);
    expect(del[0].deletion_mark).toBe(true);
    expect((await t.customerRow(await idOf(CASHIER_SCENARIOS.advance))).deletion_mark).toBe(true);
  });
});

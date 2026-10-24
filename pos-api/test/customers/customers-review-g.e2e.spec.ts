import pino from 'pino';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CASHIER_SCENARIO_PHONES } from '../../src/integrations/onec/synthetic-cashier.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import { CustomersChangeHandler } from '../../src/sync/customers/customers-change.handler.js';
import type { CashierWorld } from '../support/cashier-fixture.js';
import { CustomersTestApp } from './support/customers-app.js';

/**
 * Исправления ревью этапа G по клиентам (**тестовые данные**, фейк 1С в режиме кассира, embedded PostgreSQL 17):
 * - G-customers-1c-2 — окно «customer/create доставлен в 1С, результат не обработан»: повторный поиск дубля по тому же
 *   телефону не создаёт строку-заглушку реплики, POS-клиент получает свой Ref (05 SYNC-005, 10 CUST-014);
 *   заглушка, созданная ранее, удаляется при подтверждении и при синхронизации /changes;
 * - G-customers-1c-3 — два параллельных POST /customers с одним телефоном: одна карточка (10 CUST-011);
 * - G-customers-1c-6 / G-security-6 — сигнал скрейпинга `customer.phone_lookup` и для `GET /customers?q=` (08 §4.5.4);
 * - G-customers-1c-7 — история покупок: по умолчанию 90 дней, период ≤ 366 дней и при одной границе (10 CUST-005).
 */
let t: CustomersTestApp;
let w: CashierWorld;
let seq = 0;
const newPhone = () => `+99655${String(9_000_000 + (Date.now() % 900_000) + (seq += 1)).padStart(7, '0')}`;

beforeAll(async () => {
  t = await new CustomersTestApp().start({ env: { QR_PROVIDER: 'none' } });
  w = await t.seedCashierWorld();
}, 600_000);

afterAll(async () => {
  await t?.stop();
});

type Row = { id: string; source: string; onec_status: string; onec_ref: string | null };
const rowsByPhone = (phone: string) =>
  t.q<Row>(
    `SELECT id, source::text AS source, onec_status::text AS onec_status, onec_ref::text AS onec_ref
       FROM customers WHERE ($1 = ANY(phones_norm) OR primary_phone_e164 = $1) AND deleted_at IS NULL
      ORDER BY created_at`,
    [phone],
  );

async function applyConfirmed(from: number): Promise<void> {
  for (let i = from; i < t.published.length; i += 1) {
    const p = t.published[i];
    if (p.name === 'customers.onec-confirmed') await t.results.onConfirmed(p.data as never);
  }
}

function changes(): OnecChangesService {
  return new OnecChangesService(
    t.pool,
    t.onec,
    new CatalogApplier(),
    createRunTracker(t.pool),
    pino({ level: 'silent' }),
    {
      reconcileWithHealth: false,
      handlers: [new CustomersChangeHandler({ salesHistoryMonths: 12 })],
      planEntities: [],
    },
  );
}

describe('G-customers-1c-2: окно «доставлено в 1С, результат не обработан» (05 SYNC-005)', () => {
  it('повторный поиск по телефону не создаёт заглушку: 409 с одним кандидатом (сам POS-клиент), затем confirmed с Ref', async () => {
    const phone = newPhone();
    const a = await t
      .req('post', '/customers', w.actors.cashier, { idem: true })
      .send({ name: 'Окно Подтверждения', customerType: 'individual', phones: [phone] });
    expect(a.status, JSON.stringify(a.body)).toBe(201);
    const x = a.body.id as string;
    await t.q(`UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE status = 'pending'`);
    const before = t.published.length;
    await t.dispatcher.tick(); // 1С создала партнёра с externalId = X; результат ещё не применён
    const again = await t
      .req('post', '/customers', w.actors.seller, { idem: true })
      .send({ name: 'Окно Подтверждения', customerType: 'individual', phones: [phone] });
    expect(again.status).toBe(409);
    expect((again.body.candidates as { id: string }[]).map((c) => c.id)).toEqual([x]);
    await applyConfirmed(before);
    const rows = await rowsByPhone(phone);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ id: x, source: 'pos', onec_status: 'confirmed' });
    expect(rows[0].onec_ref).not.toBeNull();
  });

  it('заглушка, созданная поиском до применения результата, удаляется при подтверждении; Ref — у POS-клиента', async () => {
    const phone = newPhone();
    const a = await t
      .req('post', '/customers', w.actors.cashier, { idem: true })
      .send({ name: 'Заглушка Подтверждение', customerType: 'individual', phones: [phone] });
    const x = a.body.id as string;
    await t.q(`UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE status = 'pending'`);
    const before = t.published.length;
    await t.dispatcher.tick();
    const ref = (
      await t.q<{ r: string }>(
        `SELECT onec_ref::text AS r FROM onec_outbox WHERE aggregate_type = 'customer' AND aggregate_id = $1`,
        [x],
      )
    )[0].r;
    // Строка-заглушка поиска дубля (как до исправления CustomerMatching): source=onec, synced_at IS NULL.
    await t.q(
      `INSERT INTO customers (onec_ref, source, name, customer_type, primary_phone_e164, phones_norm, onec_status)
       VALUES ($1::uuid, 'onec', 'Заглушка Поиска', 'legal', $2, ARRAY[$2]::text[], 'n_a')`,
      [ref, phone],
    );
    await applyConfirmed(before);
    const rows = await rowsByPhone(phone);
    expect(rows).toEqual([{ id: x, source: 'pos', onec_status: 'confirmed', onec_ref: ref }]);
  });

  it('заглушка с Ref карточки POS-клиента удаляется синхронизацией /changes (externalId), POS-клиент усыновлён', async () => {
    const phone = newPhone();
    const a = await t
      .req('post', '/customers', w.actors.cashier, { idem: true })
      .send({ name: 'Заглушка Синхронизация', customerType: 'individual', phones: [phone] });
    const x = a.body.id as string;
    await t.q(`UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE status = 'pending'`);
    await t.dispatcher.tick(); // результат не применяется — подтверждает только синхронизация
    const ref = (
      await t.q<{ r: string }>(
        `SELECT onec_ref::text AS r FROM onec_outbox WHERE aggregate_type = 'customer' AND aggregate_id = $1`,
        [x],
      )
    )[0].r;
    await t.q(
      `INSERT INTO customers (onec_ref, source, name, customer_type, primary_phone_e164, phones_norm, onec_status)
       VALUES ($1::uuid, 'onec', 'Заглушка Поиска', 'legal', $2, ARRAY[$2]::text[], 'n_a')`,
      [ref, phone],
    );
    await changes().pullOnce();
    const rows = await rowsByPhone(phone);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ id: x, source: 'pos', onec_status: 'confirmed', onec_ref: ref });
    const ob = await t.q<{ status: string }>(
      `SELECT status::text AS status FROM onec_outbox WHERE aggregate_type = 'customer' AND aggregate_id = $1`,
      [x],
    );
    expect(ob.map((o) => o.status)).toEqual(['confirmed']);
  });
});

describe('G-customers-1c-3: параллельные POST /customers с одним телефоном (10 CUST-011)', () => {
  it('ответ 1С задержан на 300 мс: один 201, второй 409 CUSTOMER_DUPLICATE_SUSPECTED; одна карточка и один outbox', async () => {
    const onec = t.onec as unknown as { findCustomersByPhone: (...a: unknown[]) => Promise<unknown> };
    const orig = onec.findCustomersByPhone.bind(onec);
    onec.findCustomersByPhone = async (...a: unknown[]) => {
      await new Promise((r) => setTimeout(r, 300));
      return orig(...a);
    };
    const phone = newPhone();
    const b = { name: 'Гонка Клиент', customerType: 'individual', phones: [phone] };
    let res: Awaited<ReturnType<ReturnType<CustomersTestApp['req']>['send']>>[];
    try {
      res = await Promise.all([
        t.req('post', '/customers', w.actors.cashier, { idem: true }).send(b),
        t.req('post', '/customers', w.actors.senior_seller, { idem: true }).send(b),
      ]);
    } finally {
      onec.findCustomersByPhone = orig;
    }
    expect(res.map((r) => r.status).sort()).toEqual([201, 409]);
    expect(res.find((r) => r.status === 409)?.body.code).toBe('CUSTOMER_DUPLICATE_SUSPECTED');
    expect(await rowsByPhone(phone)).toHaveLength(1);
    const ob = await t.q(
      `SELECT x.id FROM onec_outbox x JOIN customers c ON c.id = x.aggregate_id
        WHERE x.aggregate_type = 'customer' AND $1 = ANY(c.phones_norm)`,
      [phone],
    );
    expect(ob).toHaveLength(1);
  });
});

describe('G-customers-1c-6 / G-security-6: customer.phone_lookup и для GET /customers?q= (08 §4.5.4, 11 SEC-042)', () => {
  it('seller: 51 поиск по полному номеру через список клиентов → одна запись аудита customer.phone_lookup', async () => {
    const seller = await t.actor({ role: 'seller' });
    for (let i = 0; i < 51; i += 1) {
      const r = await t.req('get', `/customers?q=${encodeURIComponent(CASHIER_SCENARIO_PHONES.noDebt)}`, seller);
      expect(r.status).toBe(200);
    }
    const rows = await t.q(`SELECT 1 FROM audit_logs WHERE action = 'customer.phone_lookup' AND entity_id = $1::uuid`, [
      seller.userId,
    ]);
    expect(rows).toHaveLength(1);
  });
});

describe('G-customers-1c-7: период истории покупок (10 CUST-005, OpenAPI From)', () => {
  it('без from/to — последние 90 дней; только from старше 366 дней → 400 date_range; только to — 90 дней до to', async () => {
    const path = `/customers/${w.customers.buyer.id}/orders`;
    const all = await t.req(
      'get',
      `${path}?from=${new Date(Date.now() - 365 * 86_400_000).toISOString()}`,
      w.actors.cashier,
    );
    expect(all.status, JSON.stringify(all.body)).toBe(200);
    const def = await t.req('get', path, w.actors.cashier);
    expect(def.status).toBe(200);
    const border = Date.now() - 90 * 86_400_000 - 60_000;
    const dates = (def.body.items as { date: string }[]).map((i) => Date.parse(i.date));
    expect(dates.every((d) => d >= border)).toBe(true);
    const older = (all.body.items as { date: string }[]).filter((i) => Date.parse(i.date) < border);
    expect(older.length, 'в фикстуре есть покупки старше 90 дней').toBeGreaterThan(0);
    expect(def.body.items.length).toBe((all.body.items as unknown[]).length - older.length);

    const wide = await t.req('get', `${path}?from=2000-01-01T00:00:00Z`, w.actors.cashier);
    expect(wide.status).toBe(400);
    expect(wide.body.errors[0]).toMatchObject({ field: 'from', rule: 'date_range' });
    const to = new Date(Date.now() - 30 * 86_400_000);
    const onlyTo = await t.req('get', `${path}?to=${to.toISOString()}`, w.actors.cashier);
    expect(onlyTo.status).toBe(200);
    const d2 = (onlyTo.body.items as { date: string }[]).map((i) => Date.parse(i.date));
    expect(d2.every((d) => d <= to.getTime() && d >= to.getTime() - 90 * 86_400_000)).toBe(true);
  });
});

import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { AdminAuditModule } from '../../src/admin/audit/admin-audit.module.js';
import { AdminReportsModule } from '../../src/admin/reports/admin-reports.module.js';
import { Money } from '../../src/common/money/money.js';
import { CashierTestApp, type CashierWorld } from '../support/cashier-fixture.js';
import { F_MODULES, type PosActor, type SeededOrder } from '../support/pos-fixture.js';

/**
 * RM-G-006 (08 §4.18.8; ядро §22.13 п. 3; 12 T-ADMIN-006, T-FLOW-041): отчёты руководителя R1 на данных POS —
 * **тестовые данные** (заказы и платежи сидируются в БД стенда, снимки долга — реплика фейка 1С в режиме кассира).
 * Суммы отчёта сверяются с независимым расчётом по строкам БД (decimal), разрез `day` — по суткам Asia/Bishkek.
 */
type Money2 = { amount: string; currency: 'KGS' };
const sum = (xs: readonly string[]): string => xs.reduce((m, x) => m.plus(Money.of(x)), Money.of('0')).toString();
const m = (amount: string): Money2 => ({ amount: Money.of(amount).toString(), currency: 'KGS' });

describe('admin/reports: сводка продаж, долги, сверка QR (RM-G-006)', () => {
  const t = new CashierTestApp();
  let w: CashierWorld;
  let sellerA: PosActor;
  let sellerB: PosActor;
  const o: Record<string, SeededOrder> = {};
  const FROM = '2026-09-10T00:00:00.000Z';
  const TO = '2026-09-13T00:00:00.000Z';
  const get = (a: PosActor | undefined, path: string, q: Record<string, string> = {}) =>
    t.req('get', `/admin/reports/${path}?${new URLSearchParams(q).toString()}`, a);

  /** Перенести заказ (и его платёж) в момент `at` (UTC). */
  async function place(order: SeededOrder, at: string): Promise<void> {
    await t.q(`UPDATE orders SET created_at = $2::timestamptz WHERE id = $1::uuid`, [order.orderId, at]);
    await t.q(`UPDATE payments SET created_at = $2::timestamptz WHERE id = $1::uuid`, [order.paymentId, at]);
  }

  beforeAll(async () => {
    await t.start({
      env: { QR_PROVIDER: 'onec', QR_TTL_MINUTES: '15' },
      modules: [...F_MODULES, AdminReportsModule, AdminAuditModule],
    });
    w = await t.seedCashierWorld();
    sellerA = w.actors.seller;
    sellerB = w.actors.senior_seller;
    const cashier = w.actors.cashier;
    const seed = (by: PosActor, method: 'cash' | 'qr_bakai' | 'credit', extra: Record<string, unknown> = {}) =>
      t.seedOrder({ createdBy: by, method, status: 'awaiting_payment', ...extra });
    o.o1 = await seed(sellerA, 'cash', { discountPercent: '5' });
    o.o2 = await seed(sellerA, 'qr_bakai');
    o.o3 = await seed(sellerB, 'credit', { status: 'awaiting_shipment', customerId: w.customers.debtWithinLimit.id });
    o.o4 = await seed(sellerB, 'cash');
    o.o5 = await seed(sellerA, 'cash', { status: 'submit_failed' });
    o.o6 = await seed(sellerA, 'qr_bakai');
    o.o7 = await seed(sellerB, 'qr_bakai');
    o.o8 = await seed(sellerB, 'qr_bakai');
    o.o9 = await seed(sellerA, 'qr_bakai');
    // Сутки Бишкека (UTC+6): 17:30Z — 23:30 того же дня, 19:00Z — 01:00 следующего.
    await place(o.o1, '2026-09-10T04:00:00Z');
    await place(o.o2, '2026-09-10T05:00:00Z');
    await place(o.o5, '2026-09-10T06:00:00Z');
    await place(o.o9, '2026-09-10T07:00:00Z');
    await place(o.o3, '2026-09-11T17:30:00Z');
    await place(o.o6, '2026-09-11T17:40:00Z');
    await place(o.o7, '2026-09-11T17:50:00Z');
    await place(o.o4, '2026-09-11T19:00:00Z');
    await place(o.o8, '2026-09-11T19:10:00Z');
    await t.q(
      `UPDATE orders SET status = 'cancelled', cancelled_at = now(), cancel_reason_code = 'customer_refused'
                WHERE id = $1::uuid`,
      [o.o4.orderId],
    );
    // Платежи: o1 — наличные получены; o2 — QR подтверждён 1С; o6 — QR подтверждён вручную; o7 — QR показан давно
    // (без подтверждения > QR_TTL_MINUTES); o8 — требует разбора (amount_mismatch); o9 — QR показан только что.
    await t.q(
      `UPDATE payments SET status = 'received', received_at = now(), received_by_user_id = $2::uuid,
              received_amount = amount, change_amount = 0 WHERE id = $1::uuid`,
      [o.o1.paymentId, cashier.userId],
    );
    await t.q(
      `UPDATE payments SET status = 'received', received_at = '2026-09-10T05:03:00Z', qr_provider_ref = 'ONEC-QR-2'
        WHERE id = $1::uuid`,
      [o.o2.paymentId],
    );
    await t.q(
      `UPDATE payments SET status = 'received', received_at = '2026-09-11T18:00:00Z', bank_reference = 'BK-0006',
              manual_confirmed_by_user_id = $2::uuid, manual_confirmed_at = '2026-09-11T18:00:00Z',
              manual_reason = 'Выписка банка'
        WHERE id = $1::uuid`,
      [o.o6.paymentId, cashier.userId],
    );
    await t.q(
      `UPDATE payments SET status = 'qr_shown', qr_provider_ref = 'ONEC-QR-7', qr_issued_at = now() - interval '2 hours',
              qr_expires_at = now() - interval '1 hour 45 minutes' WHERE id = $1::uuid`,
      [o.o7.paymentId],
    );
    await t.q(
      `UPDATE payments SET status = 'manual_confirm', review_reason = 'amount_mismatch', bank_amount = amount - 1,
              qr_provider_ref = 'ONEC-QR-8' WHERE id = $1::uuid`,
      [o.o8.paymentId],
    );
    await t.q(
      `UPDATE payments SET status = 'qr_shown', qr_provider_ref = 'ONEC-QR-9', qr_issued_at = now(),
              qr_expires_at = now() + interval '15 minutes' WHERE id = $1::uuid`,
      [o.o9.paymentId],
    );
  });

  afterAll(async () => {
    await t.stop();
  });

  it('RBAC: owner и admin → 200 (no-store, source=pos); seller, cashier, senior_seller, customer → 403; без Bearer → 401', async () => {
    for (const path of ['sales-summary', 'receivables', 'qr-reconciliation']) {
      for (const role of ['seller', 'cashier', 'senior_seller', 'customer'] as const) {
        const r = await get(w.actors[role], path);
        expect([r.status, r.body.code], `${path} ${role}`).toEqual([403, 'FORBIDDEN']);
      }
      expect((await get(undefined, path)).status).toBe(401);
      for (const a of [w.actors.owner, w.actors.admin]) {
        const r = await get(a, path);
        expect(r.status, path).toBe(200);
        expect(r.headers['cache-control']).toBe('no-store');
      }
    }
    expect((await get(w.actors.owner, 'sales-summary')).body.source).toBe('pos');
  });

  it('format=csv → 403 FORBIDDEN (R2); groupBy=week|month|warehouse → 400 groupBy; 367 дней → 422 date_range; 366 → 200', async () => {
    for (const path of ['sales-summary', 'receivables', 'qr-reconciliation']) {
      const csv = await get(w.actors.owner, path, { format: 'csv' });
      expect([csv.status, csv.body.code], path).toEqual([403, 'FORBIDDEN']);
      expect((await get(w.actors.owner, path, { format: 'xml' })).status).toBe(400);
    }
    for (const g of ['week', 'month', 'warehouse']) {
      const r = await get(w.actors.owner, 'sales-summary', { groupBy: g });
      expect([r.status, r.body.code, r.body.errors[0].rule]).toEqual([400, 'VALIDATION_FAILED', 'groupBy']);
    }
    const base = Date.parse('2026-10-24T00:00:00Z');
    const iso = (ms: number) => new Date(ms).toISOString();
    for (const path of ['sales-summary', 'qr-reconciliation']) {
      const long = await get(w.actors.owner, path, { from: iso(base - 367 * 86_400_000), to: iso(base) });
      expect([long.status, long.body.errors[0].rule], path).toEqual([422, 'date_range']);
      const inv = await get(w.actors.owner, path, { from: iso(base), to: iso(base - 1) });
      expect(inv.status).toBe(422);
      expect((await get(w.actors.owner, path, { from: iso(base - 366 * 86_400_000), to: iso(base) })).status).toBe(200);
      expect((await get(w.actors.owner, path, { from: 'вчера' })).status).toBe(400);
    }
    expect((await get(w.actors.owner, 'receivables', { asOfOnly: 'maybe' })).status).toBe(400);
  });

  it('sales-summary groupBy=day: сутки Бишкека, продажи без отменённых и submit_failed; суммы = расчёт по БД', async () => {
    const r = await get(w.actors.owner, 'sales-summary', { from: FROM, to: TO, groupBy: 'day' });
    expect(r.status).toBe(200);
    expect(r.body.period).toEqual({ from: FROM, to: TO });
    const day10 = [o.o1, o.o2, o.o9];
    const day11 = [o.o3, o.o6, o.o7];
    const day12 = [o.o8];
    expect(r.body.rows).toEqual([
      {
        key: '2026-09-10',
        ordersCount: 3,
        ordersTotal: m(sum(day10.map((x) => x.total))),
        paidTotal: m(sum([o.o1.total, o.o2.total])),
        byMethod: { cash: m(o.o1.total), qr_bakai: m(sum([o.o2.total, o.o9.total])), credit: m('0') },
        discountTotal: m(
          (await t.q<{ d: string }>(`SELECT discount_total::text AS d FROM orders WHERE id = $1`, [o.o1.orderId]))[0].d,
        ),
        cancelledCount: 0,
      },
      {
        key: '2026-09-11',
        ordersCount: 3,
        ordersTotal: m(sum(day11.map((x) => x.total))),
        paidTotal: m(o.o6.total),
        byMethod: { cash: m('0'), qr_bakai: m(sum([o.o6.total, o.o7.total])), credit: m(o.o3.total) },
        discountTotal: m('0'),
        cancelledCount: 0,
      },
      {
        key: '2026-09-12',
        ordersCount: 1,
        ordersTotal: m(o.o8.total),
        paidTotal: m('0'),
        byMethod: { cash: m('0'), qr_bakai: m(o.o8.total), credit: m('0') },
        discountTotal: m('0'),
        cancelledCount: 1,
      },
    ]);
    expect(Money.of(r.body.rows[0].discountTotal.amount).compare(Money.of('0'))).toBeGreaterThan(0);
    const all = [...day10, ...day11, ...day12];
    expect(r.body.totals).toMatchObject({
      ordersCount: 7,
      ordersTotal: m(sum(all.map((x) => x.total))),
      paidTotal: m(sum([o.o1.total, o.o2.total, o.o6.total])),
      cancelledCount: 1,
    });
    // Независимая сверка с БД: сумма строк = итог; итог = SUM(orders.total) продаж периода.
    const [db] = await t.q<{ total: string; paid: string }>(
      `SELECT sum(o.total)::text AS total,
              (SELECT sum(p.amount) FROM payments p JOIN orders oo ON oo.id = p.order_id
                WHERE p.status = 'received' AND oo.created_at >= $1 AND oo.created_at < $2
                  AND oo.status NOT IN ('draft','cancelled','submit_failed'))::text AS paid
         FROM orders o WHERE o.created_at >= $1 AND o.created_at < $2
          AND o.status NOT IN ('draft','cancelled','submit_failed')`,
      [FROM, TO],
    );
    expect(r.body.totals.ordersTotal).toEqual(m(db.total));
    expect(r.body.totals.paidTotal).toEqual(m(db.paid));
    expect(sum((r.body.rows as { ordersTotal: Money2 }[]).map((x) => x.ordersTotal.amount))).toBe(
      r.body.totals.ordersTotal.amount,
    );
  });

  it('sales-summary groupBy=seller и paymentMethod: ключи — автор заказа и способ оплаты', async () => {
    const bySeller = await get(w.actors.admin, 'sales-summary', { from: FROM, to: TO, groupBy: 'seller' });
    const rows = new Map(
      (bySeller.body.rows as { key: string; ordersCount: number; ordersTotal: Money2; cancelledCount: number }[]).map(
        (x) => [x.key, x],
      ),
    );
    expect([...rows.keys()].sort()).toEqual([sellerA.userId, sellerB.userId].sort());
    expect(rows.get(sellerA.userId)).toMatchObject({
      ordersCount: 4,
      ordersTotal: m(sum([o.o1.total, o.o2.total, o.o6.total, o.o9.total])),
      cancelledCount: 0,
    });
    expect(rows.get(sellerB.userId)).toMatchObject({
      ordersCount: 3,
      ordersTotal: m(sum([o.o3.total, o.o7.total, o.o8.total])),
      cancelledCount: 1,
    });
    const byMethod = await get(w.actors.admin, 'sales-summary', { from: FROM, to: TO, groupBy: 'paymentMethod' });
    expect((byMethod.body.rows as { key: string; ordersCount: number }[]).map((x) => [x.key, x.ordersCount])).toEqual([
      ['cash', 1],
      ['credit', 1],
      ['qr_bakai', 5],
    ]);
    // Аудит report.viewed (имя, период, разрез).
    const viewed = await t.auditRows('report.viewed');
    expect(viewed.at(-1)).toMatchObject({
      actor_user_id: w.actors.admin.userId,
      after: { name: 'sales-summary', period: { from: FROM, to: TO }, groupBy: 'paymentMethod' },
    });
  });

  it('qr-reconciliation: подтверждения 1С и ручные, расхождения (manual_confirm и qr_shown старше QR_TTL_MINUTES)', async () => {
    const r = await get(w.actors.owner, 'qr-reconciliation', { from: FROM, to: TO });
    expect(r.status).toBe(200);
    expect(r.body.summary).toEqual({ webhook: 1, manual: 1, unmatched: 2 });
    const byId = new Map((r.body.rows as { paymentId: string }[]).map((x) => [x.paymentId, x]));
    expect([...byId.keys()].sort()).toEqual([o.o2, o.o6, o.o7, o.o8, o.o9].map((x) => x.paymentId).sort());
    expect(byId.get(o.o2.paymentId)).toMatchObject({
      orderNumber: o.o2.publicNumber,
      amount: m(o.o2.total),
      status: 'received',
      confirmationKind: 'webhook',
      confirmedBy: null,
      bankReference: 'ONEC-QR-2',
      confirmedAt: '2026-09-10T05:03:00.000Z',
    });
    expect(byId.get(o.o6.paymentId)).toMatchObject({
      status: 'received',
      confirmationKind: 'manual',
      confirmedBy: { id: w.actors.cashier.userId, role: 'cashier' },
      bankReference: 'BK-0006',
    });
    expect(byId.get(o.o8.paymentId)).toMatchObject({
      status: 'manual_confirm',
      confirmationKind: null,
      reviewReason: 'amount_mismatch',
      bankAmount: m(Money.of(o.o8.total).minus(Money.of('1')).toString()),
    });
    const unmatched = await get(w.actors.owner, 'qr-reconciliation', { from: FROM, to: TO, status: 'unmatched' });
    expect((unmatched.body.rows as { paymentId: string }[]).map((x) => x.paymentId).sort()).toEqual(
      [o.o7.paymentId, o.o8.paymentId].sort(),
    );
    const manual = await get(w.actors.owner, 'qr-reconciliation', { from: FROM, to: TO, status: 'manual' });
    expect((manual.body.rows as { paymentId: string }[]).map((x) => x.paymentId)).toEqual([o.o6.paymentId]);
    expect((await get(w.actors.owner, 'qr-reconciliation', { status: 'pending' })).status).toBe(400);
    expect((await t.auditRows('report.viewed')).at(-1)?.after).toMatchObject({
      name: 'qr-reconciliation',
      status: 'manual',
    });
  });

  it('receivables: снимок 1С без пометки удаления; сумма — положительное сальдо; asOf — старейший снимок; isStale', async () => {
    const rows = await t.q<{ balance: string; overdue: string | null; at: Date; deleted: boolean }>(
      `SELECT r.balance::text AS balance, r.overdue_amount::text AS overdue, r.onec_snapshot_at AS at,
              c.deletion_mark AS deleted
         FROM receivables r JOIN customers c ON c.id = r.customer_id`,
    );
    const live = rows.filter((x) => !x.deleted);
    const debt = live.filter((x) => Money.of(x.balance).compare(Money.of('0')) > 0);
    const overdue = live.filter((x) => x.overdue !== null && Money.of(x.overdue).compare(Money.of('0')) > 0);
    const oldest = live.map((x) => new Date(x.at).getTime()).reduce((a, b) => Math.min(a, b));
    const r = await get(w.actors.owner, 'receivables');
    expect(r.status).toBe(200);
    expect(r.body).toEqual({
      asOf: new Date(oldest).toISOString(),
      isStale: true, // сценарий stale: снимок 180 мин при пороге 60
      totalBalance: m(sum(debt.map((x) => x.balance))),
      totalOverdue: m(sum(overdue.map((x) => x.overdue!))),
      customersCount: debt.length,
      overdueCount: overdue.length,
    });
    expect(debt.length).toBeGreaterThan(5);
    // аванс (сальдо < 0) итог не уменьшает
    expect(live.some((x) => Money.of(x.balance).compare(Money.of('0')) < 0)).toBe(true);
    const asOf = await get(w.actors.admin, 'receivables', { asOfOnly: 'true' });
    expect(Object.keys(asOf.body).sort()).toEqual(['asOf', 'isStale']);
    // все снимки свежие → isStale=false; порог — receivables.max_age_minutes
    await t.q(`UPDATE receivables SET onec_snapshot_at = now() - interval '10 minutes'`);
    expect((await get(w.actors.owner, 'receivables')).body.isStale).toBe(false);
    await t.setSetting('receivables.max_age_minutes', '5');
    expect((await get(w.actors.owner, 'receivables')).body.isStale).toBe(true);
    await t.setSetting('receivables.max_age_minutes', '60');
    expect((await t.auditRows('report.viewed')).at(-1)?.after).toMatchObject({ name: 'receivables', period: null });
  });
});

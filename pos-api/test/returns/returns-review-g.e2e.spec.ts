import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { SyncEntity } from '../../src/common/enums.js';
import { RETURN_DOC_TYPE, ReturnDocsChangeHandler } from '../../src/returns/onec/return-docs.handler.js';
import { ReturnsRetentionService } from '../../src/returns/returns-retention.service.js';
import { emptyCounts, type ApplyScope, type EntityCounts, type ItemError } from '../../src/sync/apply/apply.types.js';
import type { CashierWorld } from '../support/cashier-fixture.js';
import type { PosActor } from '../support/pos-fixture.js';
import { TxnTestApp } from '../transactions/support/txn-app.js';

/**
 * Исправления ревью этапа G по возвратам (**тестовые данные**: реализации записаны тестом в реплику, embedded
 * PostgreSQL 17):
 * - G-returns-txn-1 — повторная доставка того же документа «Возврат товаров от клиента» (тот же `onec_ref`) не
 *   переводит в `completed` другую открытую заявку той же реализации (05 ONEC-015, SYNC-031; 10 RET-007, TXN-005);
 * - G-returns-txn-5 — параллельные POST /returns на весь остаток строки реализации: ровно одна заявка (RET-003, RET-008);
 * - G-trace-10 — `retention.daily`: черновики старше 7 дней удаляются, остаток к возврату освобождается (07 §5.45,
 *   §13.3), аудит `retention.executed`.
 */
let t: TxnTestApp;
let w: CashierWorld;
let cashier: PosActor;
let cashier2: PosActor;

interface Shipped {
  readonly orderId: string;
  readonly shipmentId: string;
  readonly shipmentRef: string;
  readonly unitId: string;
  readonly productRef: string;
  readonly variantRef: string | null;
}

async function shippedOrder(): Promise<Shipped> {
  const [v1] = await t.saleableVariants(1);
  const o = await t.seedOrder({
    createdBy: cashier,
    customerId: w.customers.debtWithinLimit.id,
    method: 'cash',
    status: 'awaiting_shipment',
    items: [{ variantId: v1.variantId, quantity: '50' }],
  });
  await t.q(`UPDATE orders SET status = 'shipped', shipped_at = now() WHERE id = $1::uuid`, [o.orderId]);
  const s = await t.q<{ id: string; onec_ref: string }>(
    `INSERT INTO shipments (onec_ref, onec_code, onec_data_version, synced_at, source_hash, onec_doc_type, onec_date,
                            posted, order_id, customer_id, warehouse_id, total, discount_total, returned_total)
     VALUES (gen_random_uuid(), 'RT-RVG-' || substr(md5(random()::text), 1, 6), 'AAAAAQ==', now(), 'test',
             'Document_РеализацияТоваровУслуг', now(), true, $1::uuid, $2::uuid, $3::uuid, 5000.00, 0, 0)
     RETURNING id, onec_ref::text AS onec_ref`,
    [o.orderId, w.customers.debtWithinLimit.id, await t.defaultWarehouseId()],
  );
  await t.q(
    `INSERT INTO shipment_items (shipment_id, onec_line_no, variant_id, product_name_snapshot, quantity, base_quantity,
                                 unit_price, line_total, discount_amount, returned_quantity, synced_at, source_hash)
     VALUES ($1::uuid, 1, $2::uuid, $3, 50, 50, 100.00, 5000.00, 0, 0, now(), 'test')`,
    [s[0].id, v1.variantId, v1.productName],
  );
  const refs = await t.q<{ product_ref: string; variant_ref: string | null }>(
    `SELECT p.onec_ref::text AS product_ref, CASE WHEN v.is_default THEN NULL ELSE v.onec_ref::text END AS variant_ref
       FROM product_variants v JOIN products p ON p.id = v.product_id WHERE v.id = $1`,
    [v1.variantId],
  );
  return {
    orderId: o.orderId,
    shipmentId: s[0].id,
    shipmentRef: s[0].onec_ref,
    unitId: v1.unitId,
    productRef: refs[0].product_ref,
    variantRef: refs[0].variant_ref,
  };
}

const body = (s: Shipped, qty: string) => ({
  orderId: s.orderId,
  reasonCode: 'defect',
  items: [{ orderLineNo: 1, quantity: { value: qty, unitId: s.unitId, packagingId: null } }],
});

async function applyDocs(items: Record<string, unknown>[]) {
  const client = await t.pool.connect();
  const counts = new Map<SyncEntity, EntityCounts>();
  const errors: ItemError[] = [];
  try {
    await client.query('BEGIN');
    const scope: ApplyScope = {
      client,
      runIdFor: () => Promise.resolve(randomUUID()),
      syncedAt: new Date(),
      counts,
      errors,
    };
    await new ReturnDocsChangeHandler().apply(scope, items);
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
  return { counts: counts.get('return_docs') ?? { ...emptyCounts(), tables: {} }, errors };
}

beforeAll(async () => {
  t = await new TxnTestApp().startTxn();
  w = await t.seedCashierWorld();
  ({ cashier } = w.actors);
  cashier2 = await t.actor({ role: 'cashier' });
}, 900_000);

afterAll(async () => {
  await t?.stop();
});

describe('G-returns-txn-1: повторная доставка документа возврата 1С (идемпотентность по onec_ref)', () => {
  it('две открытые заявки на одну реализацию; тот же документ дважды → completed только первая, одна строка refund', async () => {
    const s = await shippedOrder();
    const ids: string[] = [];
    for (let i = 0; i < 2; i += 1) {
      const r = await t.req('post', '/returns', cashier, { idem: true }).send(body(s, '5'));
      expect(r.status, JSON.stringify(r.body)).toBe(201);
      const sub = await t
        .req('post', `/returns/${r.body.id as string}/submit`, cashier, {
          idem: true,
          stepUp: await t.stepUp(cashier, 'return.submit'),
        })
        .send({ rowVersion: r.body.rowVersion });
      expect(sub.status, JSON.stringify(sub.body)).toBe(200);
      ids.push(r.body.id as string);
    }
    const docRef = randomUUID();
    const doc = {
      type: RETURN_DOC_TYPE,
      ref: docRef,
      number: 'VK-RVG-1',
      date: new Date().toISOString(),
      posted: true,
      deletionMark: false,
      shipmentRef: s.shipmentRef,
      total: '500.00',
      lines: [{ productRef: s.productRef, variantRef: s.variantRef, quantity: '5.000' }],
    };
    const status = async () =>
      new Map(
        (
          await t.q<{ id: string; status: string }>(
            `SELECT id, status::text AS status FROM return_requests WHERE id = ANY($1::uuid[])`,
            [ids],
          )
        ).map((x) => [x.id, x.status]),
      );
    const first = await applyDocs([doc]);
    expect(first.counts.inserted).toBe(1);
    const afterFirst = await status();
    const done = ids.filter((id) => afterFirst.get(id) === 'completed');
    expect(done).toHaveLength(1);
    const second = await applyDocs([doc]);
    expect(second.counts).toMatchObject({ inserted: 0, skipped: 1 });
    expect(await status()).toEqual(afterFirst);
    const refunds = await t.q<{ return_request_id: string; amount: string }>(
      `SELECT return_request_id, amount::text AS amount FROM transactions WHERE kind = 'refund' AND onec_ref = $1`,
      [docRef],
    );
    expect(refunds).toEqual([{ return_request_id: done[0], amount: '-500.00' }]);
    // Второй документ того же объёма закрывает вторую заявку (первая уже связана со своей строкой refund).
    const other = await applyDocs([{ ...doc, ref: randomUUID(), number: 'VK-RVG-2' }]);
    expect(other.counts.inserted).toBe(1);
    expect([...(await status()).values()]).toEqual(['completed', 'completed']);
  });
});

describe('G-returns-txn-5: параллельные заявки на один остаток (RET-003, RET-008)', () => {
  it('4 параллельных POST /returns на весь остаток (50 из 50) → ровно один 201, в открытых заявках не больше отгруженного', async () => {
    const s = await shippedOrder();
    const results = await Promise.all(
      [cashier, cashier2, cashier, cashier2].map((a) =>
        t.req('post', '/returns', a, { idem: true }).send(body(s, '50')),
      ),
    );
    expect(results.filter((r) => r.status === 201)).toHaveLength(1);
    expect(results.filter((r) => r.status === 422).every((r) => r.body.code === 'RETURN_QTY_EXCEEDED')).toBe(true);
    const open = await t.q<{ q: string }>(
      `SELECT coalesce(sum(i.quantity), 0)::numeric(14,3)::text AS q FROM return_requests r
         JOIN return_request_items i ON i.return_request_id = r.id
        WHERE r.shipment_id = $1 AND r.status IN ('draft','submitted','accepted')`,
      [s.shipmentId],
    );
    expect(open[0].q).toBe('50.000');
  });
});

describe('G-trace-10: retention.daily — черновики заявок старше 7 дней (07 §5.45, §13.3)', () => {
  it('черновик 8 дней назад удаляется со строками, остаток освобождается; свежий и отправленный — остаются; аудит retention.executed', async () => {
    const s = await shippedOrder();
    const old = await t.req('post', '/returns', cashier, { idem: true }).send(body(s, '30'));
    const fresh = await t.req('post', '/returns', cashier2, { idem: true }).send(body(s, '10'));
    expect([old.status, fresh.status]).toEqual([201, 201]);
    await t.q(`UPDATE return_requests SET created_at = now() - interval '8 days' WHERE id = $1`, [old.body.id]);
    // Пока старый черновик жив, остатка на 40 нет.
    expect((await t.req('post', '/returns', cashier2, { idem: true }).send(body(s, '40'))).status).toBe(422);
    const svc = t.app.get(ReturnsRetentionService);
    const r = await svc.purgeExpiredDrafts();
    expect(r.deleted).toBeGreaterThanOrEqual(1);
    const left = await t.q<{ id: string }>(`SELECT id FROM return_requests WHERE shipment_id = $1`, [s.shipmentId]);
    expect(left.map((x) => x.id)).toEqual([fresh.body.id]);
    expect((await t.q(`SELECT 1 FROM return_request_items WHERE return_request_id = $1`, [old.body.id])).length).toBe(
      0,
    );
    expect((await t.req('post', '/returns', cashier2, { idem: true }).send(body(s, '40'))).status).toBe(201);
    const audit = await t.q<{ after: Record<string, unknown> }>(
      `SELECT after FROM audit_logs WHERE action = 'retention.executed' ORDER BY chain_seq DESC LIMIT 1`,
    );
    expect(audit[0]?.after).toMatchObject({ table: 'return_requests', status: 'draft', olderThanDays: 7 });
    expect(await svc.purgeExpiredDrafts()).toEqual({ deleted: 0 });
  });
});

import { randomUUID } from 'node:crypto';
import pino from 'pino';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { OutboxDispatcher } from '../../src/jobs/outbox/outbox-dispatcher.js';
import { RETURN_DOC_TYPE, ReturnDocsChangeHandler } from '../../src/returns/onec/return-docs.handler.js';
import { ReturnsOnecService } from '../../src/returns/onec/returns-onec.service.js';
import { ReturnsSettings } from '../../src/returns/returns.settings.js';
import { emptyCounts, type ApplyScope, type EntityCounts, type ItemError } from '../../src/sync/apply/apply.types.js';
import { OnecOutboxDelivery } from '../../src/sync/outbox/onec-outbox.delivery.js';
import { schedulerConfigFromEnv } from '../../src/sync/scheduler/scheduler.config.js';
import type { SyncEntity } from '../../src/common/enums.js';
import type { CashierWorld } from '../support/cashier-fixture.js';
import type { PosActor } from '../support/pos-fixture.js';
import { validateAgainst } from '../settings/support/openapi-check.js';
import { TxnTestApp } from '../transactions/support/txn-app.js';

/**
 * Заявки на возврат (13 RM-G-005, RM-G-011 п. 2; 08 §4.15; 10 RET-001…RET-013; ядро §21 п. 1, §22.11, §23 п. 8;
 * 12 T-RET-001…015, T-SEC-016.A04) — **тестовые данные**: исходные продажи — реализации синтетики кассира и
 * реализации, записанные тестом прямо в реплику; 1С — фейк в режиме кассира (`createReturnRequest`, статусы, документ
 * «Возврат товаров от клиента»).
 */
interface Line {
  readonly lineNo: number;
  readonly unitId: string;
  readonly quantity: string;
  readonly lineTotal: string;
}
interface Shipped {
  readonly orderId: string;
  readonly shipmentId: string;
  readonly lines: readonly Line[];
}
type Ret = Record<string, unknown> & { id: string; status: string; rowVersion: number };

let t: TxnTestApp;
let w: CashierWorld;
let cashier: PosActor;
let cashier2: PosActor;
let senior: PosActor;
let admin: PosActor;
let owner: PosActor;
let seller: PosActor;
let big: Shipped;

/** Отгруженный заказ с реализацией, записанной прямо в реплику (2 строки: 50 × 100.00; 10 × 250.00 − скидка 100.00). */
async function shippedOrder(): Promise<Shipped> {
  const [v1, v2] = await t.saleableVariants(2);
  // Строки заказа POS 1 и 2 — те же варианты, что строки реализации (`orderLineNo` — номер строки заказа).
  const o = await t.seedOrder({
    createdBy: cashier,
    customerId: w.customers.debtWithinLimit.id,
    method: 'cash',
    status: 'awaiting_shipment',
    items: [
      { variantId: v1.variantId, quantity: '50' },
      { variantId: v2.variantId, quantity: '10' },
    ],
  });
  await t.q(`UPDATE orders SET status = 'shipped', shipped_at = now() WHERE id = $1::uuid`, [o.orderId]);
  const s = await t.q<{ id: string }>(
    `INSERT INTO shipments (onec_ref, onec_code, onec_data_version, synced_at, source_hash, onec_doc_type, onec_date,
                            posted, order_id, customer_id, warehouse_id, total, discount_total, returned_total)
     VALUES (gen_random_uuid(), 'РТ-ТЕСТ-' || substr(md5(random()::text), 1, 6), 'AAAAAQ==', now(), 'test',
             'Document_РеализацияТоваровУслуг', now(), true, $1::uuid, $2::uuid, $3::uuid, 7400.00, 100.00, 0)
     RETURNING id`,
    [o.orderId, w.customers.debtWithinLimit.id, await t.defaultWarehouseId()],
  );
  const lines: Line[] = [
    { lineNo: 1, unitId: v1.unitId, quantity: '50.000', lineTotal: '5000.00' },
    { lineNo: 2, unitId: v2.unitId, quantity: '10.000', lineTotal: '2400.00' },
  ];
  for (const [i, l] of lines.entries()) {
    const v = i === 0 ? v1 : v2;
    await t.q(
      `INSERT INTO shipment_items (shipment_id, onec_line_no, variant_id, product_name_snapshot, quantity, base_quantity,
                                   unit_price, line_total, discount_amount, returned_quantity, synced_at, source_hash)
       VALUES ($1::uuid, $2, $3::uuid, $4, $5::numeric, $5::numeric, $6::numeric, $7::numeric, $8::numeric, 0, now(), 'test')`,
      [
        s[0].id,
        l.lineNo,
        v.variantId,
        v.productName,
        l.quantity,
        i === 0 ? '100.00' : '250.00',
        l.lineTotal,
        i === 0 ? '0' : '100.00',
      ],
    );
  }
  return { orderId: o.orderId, shipmentId: s[0].id, lines };
}

function item(l: Line, value: string) {
  return { orderLineNo: l.lineNo, quantity: { value, unitId: l.unitId, packagingId: null } };
}

async function create(actor: PosActor, body: Record<string, unknown>) {
  return t.req('post', '/returns', actor, { idem: true }).send(body);
}

async function draft(actor: PosActor, s: Shipped, qty = '1', reasonCode = 'defect'): Promise<Ret> {
  const r = await create(actor, { orderId: s.orderId, reasonCode, items: [item(s.lines[0], qty)] });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  return r.body as Ret;
}

async function submit(actor: PosActor, r: Ret, stepUpOp: string | null = 'return.submit') {
  return t
    .req('post', `/returns/${r.id}/submit`, actor, {
      idem: true,
      ...(stepUpOp ? { stepUp: await t.stepUp(actor, stepUpOp) } : {}),
    })
    .send({ rowVersion: r.rowVersion });
}

async function act(
  actor: PosActor,
  r: Ret,
  action: 'accept' | 'reject',
  body: Record<string, unknown> = {},
  su = true,
) {
  return t
    .req('post', `/returns/${r.id}/${action}`, actor, {
      idem: true,
      ...(su ? { stepUp: await t.stepUp(actor, 'return.approve') } : {}),
    })
    .send({ rowVersion: r.rowVersion, ...body });
}

beforeAll(async () => {
  t = await new TxnTestApp().startTxn();
  w = await t.seedCashierWorld();
  ({ cashier, senior_seller: senior, admin, owner, seller } = w.actors);
  cashier2 = await t.actor({ role: 'cashier' });
  big = await shippedOrder();
}, 900_000);

afterAll(async () => {
  await t?.stop();
});

describe('POST /returns — черновик по исходной продаже (RET-001…RET-005; T-RET-001…005)', () => {
  it('валидация: причина обязательна, excess недопустим, other — с комментарием, суммы клиент не передаёт', async () => {
    const base = { orderId: big.orderId, items: [item(big.lines[0], '1')] };
    const cases: [Record<string, unknown>, string][] = [
      [{ ...base }, 'reasonCode'],
      [{ ...base, reasonCode: 'excess' }, 'reasonCode'],
      [{ ...base, reasonCode: 'other' }, 'reasonComment'],
      [{ ...base, reasonCode: 'other', reasonComment: 'коротко' }, 'reasonComment'],
      [{ ...base, reasonCode: 'defect', items: [] }, 'items'],
      [{ ...base, reasonCode: 'defect', items: [{ ...item(big.lines[0], '1'), amount: '1.00' }] }, 'items[0].amount'],
      [{ ...base, reasonCode: 'defect', items: [item(big.lines[0], '0')] }, 'items[0].quantity.value'],
      [
        { ...base, reasonCode: 'defect', items: [item(big.lines[0], '1'), item(big.lines[0], '2')] },
        'items[1].orderLineNo',
      ],
      [
        { ...base, reasonCode: 'defect', items: [{ orderLineNo: 1, quantity: { value: '1', unitId: randomUUID() } }] },
        'items[0].quantity.unitId',
      ],
      [{ ...base, reasonCode: 'defect', items: [item(big.lines[0], '51')] }, 'items[0].quantity.value'],
      [
        { ...base, reasonCode: 'defect', items: [{ ...item(big.lines[0], '1'), orderLineNo: 9 }] },
        'items[0].orderLineNo',
      ],
    ];
    for (const [body, field] of cases) {
      const r = await create(cashier, body);
      expect(r.status, JSON.stringify(body)).toBe(400);
      expect(r.body.code).toBe('VALIDATION_FAILED');
      expect((r.body.errors as { field: string }[]).map((e) => e.field)).toContain(field);
    }
  });

  it('заказ не отгружен → 409 order_not_shipped; нет заказа → 404; seller/owner → 403', async () => {
    const r = await create(cashier, {
      orderId: w.orders.buyerRequest.orderId,
      reasonCode: 'defect',
      items: [item(big.lines[0], '1')],
    });
    expect(r.status).toBe(409);
    expect(r.body).toMatchObject({
      code: 'ORDER_STATE_INVALID',
      resource: 'return_request',
      reason: 'order_not_shipped',
    });
    const nf = await create(cashier, { orderId: randomUUID(), reasonCode: 'defect', items: [item(big.lines[0], '1')] });
    expect(nf.status).toBe(404);
    const body = { orderId: big.orderId, reasonCode: 'defect', items: [item(big.lines[0], '1')] };
    expect((await create(seller, body)).status).toBe(403);
    expect((await create(owner, body)).status).toBe(403);
  });

  it('201 draft: сумма строки — доля суммы реализации с учётом скидки (MNY-006); контракт ReturnRequest; аудит', async () => {
    const r = await create(cashier, {
      orderId: big.orderId,
      reasonCode: 'not_suitable',
      refundKind: 'cash',
      items: [item(big.lines[0], '2'), item(big.lines[1], '3')],
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(r.body).toMatchObject({
      status: 'draft',
      orderId: big.orderId,
      reasonCode: 'not_suitable',
      refundKind: 'cash',
      approvalReason: null,
      totalAmount: { amount: '920.00', currency: 'KGS' },
    });
    const items = r.body.items as { orderLineNo: number; amount: { amount: string }; maxReturnable: string }[];
    expect(items.map((i) => i.amount.amount)).toEqual(['200.00', '720.00']);
    expect(items.map((i) => i.orderLineNo)).toEqual([1, 2]);
    expect(items[0].maxReturnable).toBe('50.000');
    expect(r.body.publicNumber).toMatch(/^RET-\d{4}-\d{6}$/);
    expect(validateAgainst('ReturnRequest', r.body)).toEqual([]);
    const audit = await t.auditRows('return.requested', r.body.id);
    expect(audit).toHaveLength(1);
    expect(audit[0].actor_user_id).toBe(cashier.userId);
    // Остаток к возврату учитывает другие открытые заявки (RET-008): 50 − 2 = 48.
    const over = await create(cashier, {
      orderId: big.orderId,
      reasonCode: 'defect',
      items: [item(big.lines[0], '49')],
    });
    expect(over.status).toBe(422);
    expect(over.body.code).toBe('RETURN_QTY_EXCEEDED');
    expect(over.body.errors[0].params).toMatchObject({ maxReturnable: '48.000' });
    // Удаляем, чтобы не занимать остаток.
    const del = await t.req('delete', `/returns/${r.body.id}?rowVersion=${r.body.rowVersion}`, cashier);
    expect(del.status).toBe(204);
  });
});

describe('GET/PATCH/DELETE /returns (08 §4.15.2, §4.15.4; RET-003; T-RET-013)', () => {
  it('список и карточка: return.read (owner — да, seller — 403); фильтры и курсор', async () => {
    const a = await draft(cashier, big);
    const b = await draft(cashier2, big);
    const one = await t.req('get', `/returns/${a.id}`, owner);
    expect(one.status).toBe(200);
    expect(validateAgainst('ReturnRequest', one.body)).toEqual([]);
    expect((await t.req('get', `/returns/${a.id}`, seller)).status).toBe(403);
    expect((await t.req('get', `/returns/${randomUUID()}`, cashier)).status).toBe(404);
    const list = await t.req('get', `/returns?orderId=${big.orderId}&status=draft&limit=1`, cashier);
    expect(list.status).toBe(200);
    expect(list.body.items).toHaveLength(1);
    expect(list.body.hasMore).toBe(true);
    const next = await t.req(
      'get',
      `/returns?orderId=${big.orderId}&status=draft&limit=1&cursor=${encodeURIComponent(list.body.nextCursor as string)}`,
      cashier,
    );
    const ids = [...(list.body.items as Ret[]), ...(next.body.items as Ret[])].map((x) => x.id);
    expect(new Set(ids)).toEqual(new Set([a.id, b.id]));
    expect((await t.req('get', '/returns?status=bogus', cashier)).status).toBe(400);
    expect((await t.req('get', '/returns?cursor=abc.def', cashier)).status).toBe(400);
    for (const r of [a, b]) {
      const who = r === a ? cashier : cashier2;
      expect((await t.req('delete', `/returns/${r.id}?rowVersion=${r.rowVersion}`, who)).status).toBe(204);
    }
  });

  it('PATCH: только автор (кассир) или старший; rowVersion → VERSION_CONFLICT; пересчёт суммы; аудит return.updated', async () => {
    const r = await draft(cashier, big, '1');
    const stale = await t
      .req('patch', `/returns/${r.id}`, cashier)
      .send({ rowVersion: r.rowVersion + 5, reasonCode: 'surplus' });
    expect(stale.status).toBe(409);
    expect(stale.body.code).toBe('VERSION_CONFLICT');
    expect((await t.req('patch', `/returns/${r.id}`, cashier2).send({ rowVersion: r.rowVersion })).status).toBe(404);
    expect((await t.req('patch', `/returns/${r.id}`, owner).send({ rowVersion: r.rowVersion })).status).toBe(403);
    const upd = await t.req('patch', `/returns/${r.id}`, senior).send({
      rowVersion: r.rowVersion,
      reasonCode: 'other',
      reasonComment: 'Клиент вернул лишнюю коробку',
      items: [item(big.lines[1], '10')],
    });
    expect(upd.status, JSON.stringify(upd.body)).toBe(200);
    expect(upd.body).toMatchObject({
      reasonCode: 'other',
      reasonComment: 'Клиент вернул лишнюю коробку',
      totalAmount: { amount: '2400.00' },
      rowVersion: r.rowVersion + 1,
    });
    expect((await t.auditRows('return.updated', r.id)).length).toBe(1);
    const noComment = await t
      .req('patch', `/returns/${r.id}`, cashier)
      .send({ rowVersion: r.rowVersion + 1, reasonComment: '' });
    expect(noComment.status).toBe(400);
    const del = await t.req('delete', `/returns/${r.id}?rowVersion=${r.rowVersion + 1}`, cashier);
    expect(del.status).toBe(204);
  });

  it('DELETE: только draft; повтор → 204; чужой черновик кассира → 404; без rowVersion → 400; owner → 403', async () => {
    const r = await draft(cashier, big);
    expect((await t.req('delete', `/returns/${r.id}`, cashier)).status).toBe(400);
    expect((await t.req('delete', `/returns/${r.id}?rowVersion=${r.rowVersion}`, owner)).status).toBe(403);
    expect((await t.req('delete', `/returns/${r.id}?rowVersion=${r.rowVersion}`, cashier2)).status).toBe(404);
    expect((await t.req('delete', `/returns/${r.id}?rowVersion=${r.rowVersion + 1}`, cashier)).status).toBe(409);
    expect((await t.req('delete', `/returns/${r.id}?rowVersion=${r.rowVersion}`, cashier)).status).toBe(204);
    expect((await t.req('delete', `/returns/${r.id}?rowVersion=${r.rowVersion}`, cashier)).status).toBe(204);
    expect(await t.q(`SELECT 1 FROM return_requests WHERE id = $1`, [r.id])).toEqual([]);
    const deleted = await t.auditRows('return.updated', r.id);
    expect(deleted.at(-1)?.after).toMatchObject({ deleted: true });
    const s = await draft(cashier, big);
    const sub = await submit(cashier, s);
    expect(sub.status).toBe(200);
    const notDraft = await t.req('delete', `/returns/${s.id}?rowVersion=${sub.body.rowVersion}`, cashier);
    expect(notDraft.status).toBe(409);
    expect(notDraft.body).toMatchObject({
      code: 'ORDER_STATE_INVALID',
      reason: 'not_draft',
      currentStatus: 'submitted',
    });
    // освободить остаток
    expect((await act(senior, sub.body as Ret, 'reject', { reason: 'тестовая очистка' })).status).toBe(200);
  });
});

describe('Отправка, порог, согласование, отклонение (RET-006, RET-009, RET-013; T-RET-006, 009, 014, 015)', () => {
  it('submit: без step-up → STEP_UP_REQUIRED; со step-up → submitted, return_requested 0.00, аудит; outbox нет', async () => {
    const r = await draft(cashier, big);
    const no = await submit(cashier, r, null);
    expect(no.status).toBe(403);
    expect(no.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: 'return.submit' } });
    const ok = await submit(cashier, r);
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body).toMatchObject({ status: 'submitted', approvalReason: null });
    const txn = await t.q<{ kind: string; amount: string; actor_user_id: string; source: string }>(
      `SELECT kind::text AS kind, amount::text AS amount, actor_user_id, source::text AS source FROM transactions
        WHERE return_request_id = $1`,
      [r.id],
    );
    expect(txn).toEqual([{ kind: 'return_requested', amount: '0.00', actor_user_id: cashier.userId, source: 'pos' }]);
    expect(await t.q(`SELECT 1 FROM transactions WHERE kind = 'refund' AND return_request_id = $1`, [r.id])).toEqual(
      [],
    );
    const audit = await t.auditRows('return.submitted', r.id);
    expect(audit).toHaveLength(1);
    expect(audit[0].step_up_method).toBe('pin');
    expect(await t.q(`SELECT 1 FROM onec_outbox WHERE aggregate_id = $1`, [r.id])).toEqual([]);
    const again = await submit(cashier, ok.body as Ret);
    expect(again.status).toBe(409);
    expect(again.body).toMatchObject({ reason: 'not_draft' });
    const rej = await act(senior, ok.body as Ret, 'reject', { reason: 'тестовая очистка' });
    expect(rej.status).toBe(200);
  });

  it('порог return_approval_threshold: кассир → 403 return_threshold_exceeded; старший со step-up → submitted', async () => {
    await t.setSetting('return_approval_threshold', '{"amount":"150.00","currency":"KGS"}');
    try {
      const r = await draft(cashier, big, '2'); // 200.00 > 150.00
      expect(r.approvalReason).toBe('return_threshold_exceeded');
      const c = await submit(cashier, r);
      expect(c.status).toBe(403);
      expect(c.body).toMatchObject({ code: 'FORBIDDEN', reason: 'return_threshold_exceeded' });
      expect((await t.req('get', `/returns/${r.id}`, cashier)).body.status).toBe('draft');
      const noSu = await submit(senior, r, null);
      expect(noSu.body.code).toBe('STEP_UP_REQUIRED');
      const ok = await submit(senior, r);
      expect(ok.status, JSON.stringify(ok.body)).toBe(200);
      expect(ok.body).toMatchObject({ status: 'submitted', approvalReason: 'return_threshold_exceeded' });
      const row = await t.q<{ approved_by_user_id: string }>(
        `SELECT approved_by_user_id FROM return_requests WHERE id = $1`,
        [r.id],
      );
      expect(row[0].approved_by_user_id).toBe(senior.userId);
      const audit = await t.auditRows('return.submitted', r.id);
      expect(audit[0]).toMatchObject({ actor_user_id: senior.userId, step_up_method: 'pin' });
      expect(audit[0].after).toMatchObject({ initiatorId: cashier.userId });
      const a = await draft(admin, big, '2');
      const viaApprove = await submit(admin, a, 'return.approve');
      expect(viaApprove.status, JSON.stringify(viaApprove.body)).toBe(200);
      for (const x of [ok.body as Ret, viaApprove.body as Ret]) {
        expect((await act(senior, x, 'reject', { reason: 'тестовая очистка' })).status).toBe(200);
      }
    } finally {
      await t.setSetting('return_approval_threshold', '{"amount":"10000.00","currency":"KGS"}');
    }
  });

  it('accept (RETURNS_FROM_POS_ENABLED=false): права, step-up, переходы; уведомление автору', async () => {
    const r = await draft(cashier, big);
    const draftAccept = await act(senior, r, 'accept');
    expect(draftAccept.status).toBe(409);
    expect(draftAccept.body).toMatchObject({ reason: 'invalid_transition', currentStatus: 'draft' });
    const s = (await submit(cashier, r)).body as Ret;
    expect((await act(cashier, s, 'accept')).status).toBe(403);
    expect((await act(owner, s, 'accept')).status).toBe(403);
    const noSu = await act(senior, s, 'accept', {}, false);
    expect(noSu.body).toMatchObject({ code: 'STEP_UP_REQUIRED', stepUp: { operation: 'return.approve' } });
    const stale = await act(senior, { ...s, rowVersion: s.rowVersion + 3 }, 'accept');
    expect(stale.body.code).toBe('VERSION_CONFLICT');
    const ok = await act(senior, s, 'accept', { comment: 'Товар проверен' });
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body.status).toBe('accepted');
    expect(validateAgainst('ReturnRequest', ok.body)).toEqual([]);
    const audit = (await t.auditRows('return.status_changed', r.id)).filter((x) => x.step_up_method !== null);
    expect(audit[0]).toMatchObject({ actor_user_id: senior.userId, step_up_method: 'pin' });
    const n = await t.q<{ kind: string }>(
      `SELECT kind::text AS kind FROM notifications WHERE user_id = $1 AND payload->>'returnRequestId' = $2`,
      [cashier.userId, r.id],
    );
    expect(n.map((x) => x.kind)).toEqual(['return_status']);
    const twice = await act(senior, ok.body as Ret, 'accept');
    expect(twice.body.reason).toBe('invalid_transition');
    // accepted → rejected (согласована в POS — не передана в 1С).
    const rej = await act(admin, ok.body as Ret, 'reject', { reason: 'Клиент передумал' });
    expect(rej.status, JSON.stringify(rej.body)).toBe(200);
    expect(rej.body.status).toBe('rejected');
    const again = await act(senior, rej.body as Ret, 'reject', { reason: 'повторно' });
    expect(again.body).toMatchObject({ code: 'ORDER_STATE_INVALID', reason: 'invalid_transition' });
  });

  it('reject: draft → 409; без причины → 400; cashier/owner → 403; без step-up → STEP_UP_REQUIRED', async () => {
    const r = await draft(cashier, big);
    expect((await act(senior, r, 'reject', { reason: 'черновик' })).body.reason).toBe('invalid_transition');
    const s = (await submit(cashier, r)).body as Ret;
    expect((await act(cashier, s, 'reject', { reason: 'не надо' })).status).toBe(403);
    expect((await act(owner, s, 'reject', { reason: 'не надо' })).status).toBe(403);
    expect((await act(senior, s, 'reject', { reason: 'не надо' }, false)).body.code).toBe('STEP_UP_REQUIRED');
    const noReason = await act(senior, s, 'reject');
    expect(noReason.status).toBe(400);
    const ok = await act(senior, s, 'reject', { reason: 'Брак не подтверждён' });
    expect(ok.status).toBe(200);
    expect(ok.body.status).toBe('rejected');
  });
});

describe('returns_enabled=false — модуль отключён ключом (RET-012; T-RET-012)', () => {
  it('/returns* → 403 returns_disabled; включение — без перезапуска', async () => {
    await t.setSetting('returns_enabled', 'false');
    try {
      const g = await t.req('get', '/returns', cashier);
      expect(g.status).toBe(403);
      expect(g.body).toMatchObject({ code: 'FORBIDDEN', reason: 'returns_disabled' });
      const p = await t.req('post', '/returns', cashier).send({});
      expect(p.status).toBe(403);
      expect(p.body.reason).toBe('returns_disabled');
    } finally {
      await t.setSetting('returns_enabled', 'true');
    }
    expect((await t.req('get', '/returns', cashier)).status).toBe(200);
  });
});

describe('RETURNS_FROM_POS_ENABLED=true — outbox return_request и проекция 1С (SYNC-050, ONEC-067, RET-007; T-RET-007, T-SYNC-039)', () => {
  let outboxFlag = false;
  const published: { name: string; data: Record<string, unknown> }[] = [];
  let dispatcher: OutboxDispatcher;
  let onec: ReturnsOnecService;
  let latestLine: Line;

  beforeAll(async () => {
    // Цена товара синтетики может превышать порог — порог поднят, чтобы отправлял кассир (порог — отдельный тест).
    await t.setSetting('return_approval_threshold', '{"amount":"999999999.00","currency":"KGS"}');
    Object.defineProperty(t.app.get(ReturnsSettings), 'outboxEnabled', { get: () => outboxFlag, configurable: true });
    onec = t.app.get(ReturnsOnecService);
    const cfg = schedulerConfigFromEnv(t.config).outbox;
    dispatcher = new OutboxDispatcher(
      t.pool,
      new OnecOutboxDelivery(t.onec, { timeoutMs: 5000 }),
      {
        send: (name: string, data: object) => {
          published.push({ name, data: data as Record<string, unknown> });
          return Promise.resolve(randomUUID());
        },
      },
      cfg,
      'test-worker',
      pino({ level: 'silent' }),
    );
    const l = await t.q<{
      onec_line_no: number;
      variant_id: string;
      unit_id: string;
      quantity: string;
      line_total: string;
    }>(
      `SELECT si.onec_line_no, si.variant_id, coalesce(pk.unit_id, p.base_unit_id) AS unit_id,
              si.quantity::text AS quantity, si.line_total::text AS line_total
         FROM shipment_items si JOIN product_variants v ON v.id = si.variant_id JOIN products p ON p.id = v.product_id
         LEFT JOIN packagings pk ON pk.id = si.packaging_id
        WHERE si.shipment_id = $1 ORDER BY si.onec_line_no LIMIT 1`,
      [w.shipments.buyerLatest.id],
    );
    // Заказ POS покупателя той же номенклатуры, к которому привязана последняя реализация 1С: `orderLineNo` —
    // номер строки заказа, со строкой реализации он сопоставляется по варианту (GQ-TXR-02).
    const o = await t.seedOrder({
      createdBy: cashier,
      customerId: w.customers.buyer.id,
      method: 'cash',
      status: 'awaiting_shipment',
      items: [{ variantId: l[0].variant_id, quantity: l[0].quantity }],
    });
    await t.q(`UPDATE orders SET status = 'shipped', shipped_at = now() WHERE id = $1::uuid`, [o.orderId]);
    await t.q(`UPDATE shipments SET order_id = $2::uuid WHERE id = $1::uuid`, [w.shipments.buyerLatest.id, o.orderId]);
    t.cashier.linkShipmentToOrder(w.shipments.buyerLatest.onecRef, o.orderId);
    buyerOrderId = o.orderId;
    shipmentLineNo = l[0].onec_line_no;
    latestLine = { lineNo: 1, unitId: l[0].unit_id, quantity: l[0].quantity, lineTotal: l[0].line_total };
  });

  let buyerOrderId = '';
  let shipmentLineNo = 0;
  const buyer = (): Shipped => ({
    orderId: buyerOrderId,
    shipmentId: w.shipments.buyerLatest.id,
    lines: [latestLine],
  });

  async function drain(): Promise<void> {
    await t.q(`UPDATE onec_outbox SET next_attempt_at = now() - interval '1 second' WHERE status = 'pending'`);
    await dispatcher.tick();
    while (published.length > 0) {
      const p = published.shift()!;
      if (p.name === 'returns.onec-confirmed') await onec.onConfirmed(p.data as never);
      if (p.name === 'returns.onec-failed') await onec.onFailed(p.data as never);
    }
  }

  it('товар строки без ссылки 1С → 422 not_linked_to_onec: в outbox не ставится, черновик, уведомление admin (98 п. 74)', async () => {
    outboxFlag = true;
    const r = await draft(cashier, buyer());
    const prod = await t.q<{ id: string; onec_ref: string }>(
      `SELECT p.id, p.onec_ref::text AS onec_ref FROM shipment_items si
         JOIN product_variants v ON v.id = si.variant_id JOIN products p ON p.id = v.product_id
        WHERE si.shipment_id = $1 AND si.onec_line_no = $2`,
      [w.shipments.buyerLatest.id, shipmentLineNo],
    );
    expect(prod[0].onec_ref).toMatch(/^[0-9a-f-]{36}$/);
    await t.q(`UPDATE products SET onec_ref = NULL WHERE id = $1::uuid`, [prod[0].id]);
    try {
      const s = await submit(cashier, r);
      expect(s.status, JSON.stringify(s.body)).toBe(422);
      expect(s.body).toMatchObject({
        code: 'VALIDATION_FAILED',
        errors: [
          {
            field: 'items[0].orderLineNo',
            rule: 'not_linked_to_onec',
            params: { orderLineNo: 1, shipmentLineNumber: shipmentLineNo, missing: 'productRef' },
          },
        ],
      });
      expect(String(s.body.detail)).toContain('не связан с 1С');
      const ob = await t.q(`SELECT 1 FROM onec_outbox WHERE aggregate_type = 'return_request' AND aggregate_id = $1`, [
        r.id,
      ]);
      expect(ob).toHaveLength(0);
      const cur = (await t.req('get', `/returns/${r.id}`, cashier)).body as Ret;
      expect(cur).toMatchObject({ status: 'draft', rowVersion: r.rowVersion });
      const n = await t.q<{ kind: string; severity: string; title_ru: string }>(
        `SELECT kind::text AS kind, severity, title_ru FROM notifications WHERE user_id = $1 AND dedupe_key = $2`,
        [admin.userId, `return_not_linked:${r.id}`],
      );
      expect(n).toHaveLength(1);
      expect(n[0]).toMatchObject({ kind: 'sync_error', severity: 'error' });
      expect(n[0].title_ru).toContain(String(cur.publicNumber));
      // Кассиру — ответ 422, не уведомление.
      const own = await t.q(`SELECT 1 FROM notifications WHERE user_id = $1 AND dedupe_key = $2`, [
        cashier.userId,
        `return_not_linked:${r.id}`,
      ]);
      expect(own).toHaveLength(0);
    } finally {
      await t.q(`UPDATE products SET onec_ref = $2::uuid WHERE id = $1::uuid`, [prod[0].id, prod[0].onec_ref]);
    }
    const del = await t.req('delete', `/returns/${r.id}?rowVersion=${r.rowVersion}`, cashier);
    expect(del.status, JSON.stringify(del.body)).toBe(204);
  });

  it('accept при включённом outbox → 409 already_in_onec; submit создаёт outbox; 1С принимает → ссылка 1С', async () => {
    outboxFlag = true;
    const r = await draft(cashier, buyer());
    const s = await submit(cashier, r);
    expect(s.status, JSON.stringify(s.body)).toBe(200);
    const ob = await t.q<{ status: string; operation: string; payload: Record<string, unknown> }>(
      `SELECT status::text AS status, operation, payload FROM onec_outbox WHERE aggregate_type = 'return_request'
          AND aggregate_id = $1`,
      [r.id],
    );
    expect(ob).toHaveLength(1);
    expect(ob[0]).toMatchObject({ status: 'pending', operation: 'create' });
    expect(ob[0].payload).toMatchObject({
      externalId: r.id,
      shipmentRef: w.shipments.buyerLatest.onecRef,
      customerRef: w.customers.buyer.onecRef,
      orderExternalId: buyerOrderId,
      reasonCode: 'defect',
      lines: [{ shipmentLineNumber: shipmentLineNo, quantity: '1.000' }],
    });
    const acc = await act(senior, s.body as Ret, 'accept');
    expect(acc.body).toMatchObject({ code: 'ORDER_STATE_INVALID', reason: 'already_in_onec' });
    await drain();
    const row = await t.q<{ onec_ref: string | null; onec_number: string | null; status: string }>(
      `SELECT onec_ref::text AS onec_ref, onec_number, status::text AS status FROM return_requests WHERE id = $1`,
      [r.id],
    );
    expect(row[0].status).toBe('submitted');
    expect(row[0].onec_ref).toBe(t.cashier.returnRequest(r.id)?.ref);
    const cur = (await t.req('get', `/returns/${r.id}`, senior)).body as Ret;
    const rej = await act(senior, cur, 'reject', { reason: 'уже в 1С' });
    expect(rej.body).toMatchObject({ reason: 'already_in_onec' });

    // Согласование в 1С → опрос статуса → accepted + уведомление автору.
    t.cashier.setReturnStatus(r.id, 'accepted');
    const pollCallsFrom = t.onec.calls.length;
    const poll = await onec.pollOpen();
    expect(poll.changed).toBeGreaterThanOrEqual(1);
    // X-Request-Id опроса — UUID на каждый вызов (контракт XRequestId; разбор 98 п. 71), не `returns.poll:<id>`.
    const pollIds = t.onec.calls
      .slice(pollCallsFrom)
      .filter((c) => c.operation === 'getReturnRequestStatus')
      .map((c) => (c.args[1] as { requestId?: string }).requestId);
    expect(pollIds.length).toBeGreaterThanOrEqual(1);
    for (const rid of pollIds)
      expect(rid).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(new Set(pollIds).size).toBe(pollIds.length);
    expect((await t.req('get', `/returns/${r.id}`, cashier)).body.status).toBe('accepted');
    const n = await t.q<{ title_ru: string }>(
      `SELECT title_ru FROM notifications WHERE user_id = $1 AND dedupe_key = $2`,
      [cashier.userId, `return_status:${r.id}:accepted`],
    );
    expect(n).toHaveLength(1);

    // Проведён «Возврат товаров от клиента» → refund (source=onec) и completed (проекция return_docs).
    t.cashier.setReturnStatus(r.id, 'completed');
    const docRef = t.cashier.returnRequest(r.id)!.ref.replace('-7000-', '-2000-');
    const doc = t.cashier.allItems().find((x) => x.type === RETURN_DOC_TYPE && x.ref === docRef)!;
    expect(doc).toBeDefined();
    const applyDocs = async (items: Record<string, unknown>[]) => {
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
    };
    const first = await applyDocs([doc]);
    expect(first.counts.inserted).toBe(1);
    const again = await applyDocs([doc]);
    expect(again.counts.inserted).toBe(0);
    const refund = await t.q<{
      amount: string;
      source: string;
      actor_user_id: string | null;
      return_request_id: string;
    }>(
      `SELECT amount::text AS amount, source::text AS source, actor_user_id, return_request_id FROM transactions
        WHERE kind = 'refund' AND onec_ref = $1`,
      [docRef],
    );
    expect(refund).toHaveLength(1);
    expect(refund[0]).toMatchObject({ source: 'onec', actor_user_id: null, return_request_id: r.id });
    expect(refund[0].amount).toBe(`-${doc.total as string}`);
    const done = (await t.req('get', `/returns/${r.id}`, cashier)).body as Ret;
    expect(done.status).toBe('completed');
    const fin = await act(senior, done, 'reject', { reason: 'поздно' });
    expect(fin.body).toMatchObject({ reason: 'invalid_transition', currentStatus: 'completed' });
    // Документ 1С без заявки POS (введён в 1С) → refund без return_request_id (TXN-007).
    const old = t.cashier
      .allItems()
      .find((x) => x.type === RETURN_DOC_TYPE && x.ref === 'f1e2d3c4-2000-4000-8000-000000000001');
    if (old) {
      const res = await applyDocs([old]);
      const rows = await t.q<{ return_request_id: string | null }>(
        `SELECT return_request_id FROM transactions WHERE onec_ref = $1`,
        [old.ref],
      );
      if (res.errors.length === 0) expect(rows).toEqual([{ return_request_id: null }]);
    }
    outboxFlag = false;
  });

  it('отклонение в POS заявки с outbox pending → rejected, элемент outbox → cancelled; отказ 1С → уведомление', async () => {
    outboxFlag = true;
    try {
      const r = await draft(cashier, buyer());
      const s = (await submit(cashier, r)).body as Ret;
      const rej = await act(senior, s, 'reject', { reason: 'Ошибся строкой' });
      expect(rej.status, JSON.stringify(rej.body)).toBe(200);
      const ob = await t.q<{ status: string }>(
        `SELECT status::text AS status FROM onec_outbox WHERE aggregate_id = $1`,
        [r.id],
      );
      expect(ob[0].status).toBe('cancelled');
      expect((await t.auditRows('return.status_changed', r.id)).some((a) => a.after?.outboxCancelled === true)).toBe(
        true,
      );

      t.onec.script('createReturnRequest', { error: 409, code: 'POS_E_STATE' });
      const r2 = await draft(cashier, buyer());
      const s2 = (await submit(cashier, r2)).body as Ret;
      await drain();
      const ob2 = await t.q<{ status: string }>(
        `SELECT status::text AS status FROM onec_outbox WHERE aggregate_id = $1`,
        [r2.id],
      );
      expect(ob2[0].status).toBe('failed');
      const n = await t.q(`SELECT 1 FROM notifications WHERE user_id = $1 AND dedupe_key = $2`, [
        cashier.userId,
        `return_status:${r2.id}:onec_failed`,
      ]);
      expect(n).toHaveLength(1);
      const cur = (await t.req('get', `/returns/${r2.id}`, senior)).body as Ret;
      expect(cur.status).toBe('submitted');
      const rej2 = await act(senior, cur, 'reject', { reason: '1С отклонила заявку' });
      expect(rej2.status).toBe(200);
      void s2;
    } finally {
      outboxFlag = false;
    }
  });
});

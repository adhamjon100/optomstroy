import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import pino from 'pino';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { CREDIT_DECISION_SERVICE, ORDER_STATUS_PORT } from '../../src/common/ports/index.js';
import type { SyncRunContext } from '../../src/jobs/sync/sync-handler.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { SyncApiModule } from '../../src/sync/api/sync-api.module.js';
import type { PosActor } from '../support/pos-fixture.js';
import {
  onecNumberFor,
  onecRefFor,
  type OrdersHarness,
  orderBody,
  startOrders,
  type OrderDto,
} from './support/orders-fixture.js';

/**
 * Воркер outbox заказа и проекция статусов (ядро §22.1, §23 п. 2; 07 §6.3, §6.5, §8.2; 05 §5.1b; RM-F-002 п. 2–4;
 * 12 T-ORD-009, T-ORD-012, T-ORD-013, T-ORD-017, T-ORD-028, T-ORD-031, T-ORD-032) — **тестовые данные**:
 * FakeOnecGateway со сценариями (успех, 409/422/503, задержка, POS_E_DUPLICATE), диспетчер `outbox.dispatch`.
 */
describe('outbox заказа → 1С и проекция статуса', () => {
  let h: OrdersHarness;
  let a: Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;
  let qty = 10;

  beforeAll(async () => {
    h = await startOrders({
      env: { QR_PROVIDER: 'onec', ONEC_SYNC_CHECK_TIMEOUT_MS: '700' },
      outbox: { maxAttempts: 3 },
      // `POST /sync/outbox/{id}/retry` (технический повтор ORD-027) — HTTP API модуля sync.
      modules: [OrdersModule, SyncApiModule.forRoot()],
    });
    a = await h.t.actors();
    h.t.fakes!.notifications.roleMembers.set('admin', [a.admin.userId]);
    h.t.fakes!.notifications.roleMembers.set('cashier', [a.cashier.userId]);
  });
  afterAll(async () => {
    await h?.t.stop();
  });
  beforeEach(() => {
    h.t.onec.reset();
  });

  async function create(
    actor: PosActor,
    extra: Record<string, unknown> = {},
    cartOpts: { customerId?: string } = {},
  ): Promise<OrderDto> {
    const [v] = await h.t.saleableVariants(1);
    qty += 1;
    const cart = await h.cart.create(actor, [{ variantId: v.variantId, quantity: String(qty) }], cartOpts);
    const res = await h.t
      .req('post', '/orders', actor, { idem: true })
      .send(orderBody(cart, { confirmDuplicate: true, ...extra }));
    expect(res.status, JSON.stringify(res.body)).toBeLessThan(300);
    return res.body as OrderDto;
  }

  const outboxOf = async (orderId: string, op = 'create') =>
    (
      await h.t.q<{
        id: string;
        status: string;
        attempts: number;
        last_error_code: string | null;
        next_attempt_at: Date | null;
        onec_ref: string | null;
      }>(
        `SELECT id, status::text AS status, attempts, last_error_code, next_attempt_at, onec_ref::text AS onec_ref
           FROM onec_outbox WHERE aggregate_id = $1 AND operation = $2`,
        [orderId, op],
      )
    )[0];
  const orderRow = async (orderId: string) =>
    (
      await h.t.q<{
        status: string;
        onec_ref: string | null;
        onec_number: string | null;
        onec_sync_state: string;
        submit_error_code: string | null;
        paid_at: Date | null;
      }>(
        `SELECT status::text AS status, onec_ref::text AS onec_ref, onec_number, onec_sync_state::text AS onec_sync_state,
                submit_error_code, paid_at FROM orders WHERE id = $1`,
        [orderId],
      )
    )[0];
  const historyOf = async (orderId: string) =>
    h.t.q<{ from_status: string | null; to_status: string; source: string }>(
      `SELECT from_status::text AS from_status, to_status::text AS to_status, source::text AS source
         FROM order_status_history WHERE order_id = $1 ORDER BY occurred_at, id`,
      [orderId],
    );

  async function syncCtx(): Promise<SyncRunContext> {
    const run = await h.t.q<{ id: string }>(
      `INSERT INTO sync_runs (entity, mode, "trigger", status, started_at, finished_at)
       VALUES ('order_status', 'incremental', 'manual', 'success', now(), now()) RETURNING id`,
    );
    return {
      runId: run[0].id,
      entity: 'order_status',
      mode: 'incremental',
      trigger: 'manual',
      jobId: randomUUID(),
      attempt: 1,
      log: pino({ level: 'silent' }),
      touch: () => Promise.resolve(),
    };
  }

  function statusItem(orderId: string, status: string, extra: Record<string, unknown> = {}) {
    return {
      externalId: orderId,
      ref: onecRefFor(orderId),
      number: onecNumberFor(orderId),
      date: '2026-10-21T13:40:00+06:00',
      status,
      approved: status === 'КВыполнению',
      fulfillmentState: null,
      deletionMark: false,
      total: '0.00',
      shipments: [],
      ...extra,
    };
  }

  it('успех: outbox pending → sent, заказ получает onec_ref/номер и P8 awaiting_payment; confirmed без новой истории', async () => {
    const o = await create(a.seller);
    const r = await h.drain();
    expect(r.sent).toBeGreaterThanOrEqual(1);
    const ob = await outboxOf(o.id);
    expect(ob.status).toBe('sent');
    expect(ob.onec_ref).toBe(onecRefFor(o.id));
    const row = await orderRow(o.id);
    expect(row).toMatchObject({
      status: 'awaiting_payment',
      onec_ref: onecRefFor(o.id),
      onec_number: onecNumberFor(o.id),
    });
    expect(row.onec_sync_state).toBe('pending');
    const hist = await historyOf(o.id);
    expect(hist.map((x) => [x.from_status, x.to_status, x.source])).toEqual([
      ['draft', 'submitting', 'pos_system'],
      ['submitting', 'awaiting_payment', 'onec_response'],
    ]);
    expect(await h.t.auditRows('order.submitted', o.id)).toHaveLength(1);
    const notes = h.t.fakes!.notifications.of(a.seller.userId).filter((n) => n.payload?.orderId === o.id);
    expect(notes.map((n) => n.kind)).toContain('order_status');
    // Идемпотентность обработчика: повторная доставка события ничего не меняет.
    const ev = h.published.find((p) => p.name === 'orders.onec-confirmed' && p.data.aggregateId === o.id)!;
    expect(await h.results.onConfirmed(ev.data as never)).toBe('skipped');
    expect(await historyOf(o.id)).toHaveLength(2);
    // Синхронизация статусов: документ прочитан → outbox confirmed, onec_sync_state linked, без повторной проекции.
    h.t.onec.script('getOrderStatusBatch', {
      respond: { body: { items: [statusItem(o.id, 'НеСогласован')], notFound: [] } },
    });
    const res = await h.statusSync.run(await syncCtx());
    expect(res.implemented).toBe(true);
    expect((await outboxOf(o.id)).status).toBe('confirmed');
    expect((await orderRow(o.id)).onec_sync_state).toBe('linked');
    expect(await historyOf(o.id)).toHaveLength(2);
    // Статус документа 1С через GET /orders/{id}.
    const got = await h.t.req('get', `/orders/${o.id}`, a.seller);
    expect(got.body.onec).toMatchObject({ number: onecNumberFor(o.id), ref: onecRefFor(o.id), status: 'НеСогласован' });
  });

  it('credit (долг разрешён) → при sent P9 pending_approval; «К выполнению» синхронизацией → approved → awaiting_shipment', async () => {
    h.t.replacePort(CREDIT_DECISION_SERVICE, {
      check: () =>
        Promise.resolve({ allowed: true, overrideUsed: false, limitRemaining: null, receivablesAsOf: new Date() }),
    });
    try {
      const customerId = await h.t.createOnecCustomer({ creditAllowed: true, creditLimit: '900000.00', creditDays: 7 });
      const o = await create(a.cashier, { paymentMethod: 'credit' }, { customerId });
      await h.drain();
      expect((await orderRow(o.id)).status).toBe('pending_approval');
      h.t.onec.script('getOrderStatusBatch', {
        respond: { body: { items: [statusItem(o.id, 'КВыполнению')], notFound: [] } },
      });
      await h.statusSync.run(await syncCtx());
      expect((await orderRow(o.id)).status).toBe('awaiting_shipment');
      const hist = await historyOf(o.id);
      expect(hist.slice(-2).map((x) => [x.from_status, x.to_status, x.source])).toEqual([
        ['pending_approval', 'approved', 'onec_sync'],
        ['approved', 'awaiting_shipment', 'onec_sync'],
      ]);
      // Пометка удаления в 1С → cancelled (ONEC-020), транзакция order_cancelled.
      h.t.onec.script('getOrderStatusBatch', {
        respond: { body: { items: [statusItem(o.id, 'КВыполнению', { deletionMark: true })], notFound: [] } },
      });
      await h.statusSync.run(await syncCtx());
      expect((await orderRow(o.id)).status).toBe('cancelled');
      const tx = await h.t.q<{ kind: string }>(`SELECT kind::text AS kind FROM transactions WHERE order_id = $1`, [
        o.id,
      ]);
      expect(tx.map((x) => x.kind).sort()).toEqual(['order_cancelled', 'order_created']);
    } finally {
      h.t.registry.unbind(CREDIT_DECISION_SERVICE);
    }
  });

  // 12: T-SYNC-033 (повтор тем же externalId — один документ; таймаут — pending, не sent), T-SYNC-F01 (1С недоступна), T-SYNC-F05 (таймаут после записи)
  it('503 и таймаут → pending с backoff (никогда не sent); повтор с тем же externalId — один документ в 1С', async () => {
    const o = await create(a.seller);
    h.t.onec.script('createOrder', { error: 503 }, { delayMs: 5_000 });
    const r1 = await h.drain();
    expect(r1.retried).toBeGreaterThanOrEqual(1);
    let ob = await outboxOf(o.id);
    expect(ob).toMatchObject({ status: 'pending', attempts: 1, last_error_code: 'ONEC_UNAVAILABLE' });
    expect(new Date(ob.next_attempt_at!).getTime()).toBeGreaterThan(Date.now() + 30_000);
    await h.makeDue();
    await h.drain(); // таймаут ответа 1С (задержка 5 с > 700 мс) — снова pending
    ob = await outboxOf(o.id);
    expect(ob).toMatchObject({ status: 'pending', attempts: 2 });
    expect((await orderRow(o.id)).status).toBe('submitting');
    await h.makeDue();
    await h.drain();
    expect((await outboxOf(o.id)).status).toBe('sent');
    const calls = h.t.onec.callsOf('createOrder').map((c) => (c[0] as { externalId: string }).externalId);
    expect(calls.filter((x) => x === o.id).length).toBe(3);
    expect((await orderRow(o.id)).onec_ref).toBe(onecRefFor(o.id));
  });

  // 12: T-SYNC-033 (POS_E_DUPLICATE → sent), T-SYNC-F05
  it('POS_E_DUPLICATE с ref документа → sent (документ уже создан в 1С)', async () => {
    const o = await create(a.seller);
    h.t.onec.script('createOrder', {
      error: 409,
      code: 'POS_E_DUPLICATE',
      details: { ref: onecRefFor(o.id), number: onecNumberFor(o.id), status: 'НеСогласован' },
    });
    await h.drain();
    expect((await outboxOf(o.id)).status).toBe('sent');
    expect((await orderRow(o.id)).status).toBe('awaiting_payment');
  });

  // 12: T-CART-009 (б) (submit_failed, корзина возвращена), T-SYNC-F06 (1С отклонила заказ)
  it('бизнес-отказ 1С (409 POS_E_STOCK / 422) → outbox failed, заказ submit_failed, корзина восстановлена, уведомление', async () => {
    const o = await create(a.seller);
    h.t.onec.script('createOrder', { fixture: 'orders-create.409.stock' });
    const r = await h.drain();
    expect(r.failed).toBeGreaterThanOrEqual(1);
    const ob = await outboxOf(o.id);
    expect(ob).toMatchObject({ status: 'failed', last_error_code: 'ONEC_REJECTED' });
    const row = await orderRow(o.id);
    expect(row).toMatchObject({
      status: 'submit_failed',
      onec_sync_state: 'unknown',
      submit_error_code: 'ONEC_REJECTED',
    });
    expect((await historyOf(o.id)).at(-1)).toMatchObject({ to_status: 'submit_failed', source: 'onec_response' });
    expect(h.cart.restored.some((x) => x.orderId === o.id)).toBe(true);
    const pay = await h.t.q<{ status: string }>(`SELECT status::text AS status FROM payments WHERE order_id = $1`, [
      o.id,
    ]);
    expect(pay[0].status).toBe('voided');
    const notes = h.t.fakes!.notifications.of(a.seller.userId).filter((n) => n.payload?.orderId === o.id);
    expect(notes.some((n) => n.title.includes('Отклонён'))).toBe(true);
    // 422 POS_E_VALIDATION — тот же исход.
    const o2 = await create(a.seller);
    h.t.onec.script('createOrder', { fixture: 'orders-create.422' });
    await h.drain();
    expect((await orderRow(o2.id)).status).toBe('submit_failed');
  });

  // 12 T-ORD-013 (б): 1С отклонила запись документа → submit_failed, технический повтор (10 ORD-027).
  // 12: T-SYNC-F06 (исправление и повторная отправка)
  it('технический повтор отклонённого заказа (ORD-027): retry → submitting, корзина cleared, 1С создаёт документ; корзина изменена → 409', async () => {
    const o = await create(a.seller);
    h.t.onec.script('createOrder', { fixture: 'orders-create.409.stock' });
    await h.drain();
    expect((await orderRow(o.id)).status).toBe('submit_failed');
    const ob = await outboxOf(o.id);
    expect(ob.status).toBe('failed');
    // Восстановленная корзина изменена пользователем → 409, повтор не выполнен (транзакция откатилась).
    h.cart.releaseResult = 'modified';
    try {
      const busy = await h.t.req('post', `/sync/outbox/${ob.id}/retry`, a.admin, { idem: true });
      expect(busy.status, JSON.stringify(busy.body)).toBe(409);
      expect(busy.body).toMatchObject({ code: 'ORDER_STATE_INVALID', reason: 'restored_cart_in_use' });
      expect((await outboxOf(o.id)).status).toBe('failed');
      expect((await orderRow(o.id)).status).toBe('submit_failed');
    } finally {
      h.cart.releaseResult = 'none';
    }
    const retry = await h.t.req('post', `/sync/outbox/${ob.id}/retry`, a.senior_seller, { idem: true });
    expect(retry.status, JSON.stringify(retry.body)).toBe(202);
    expect(h.cart.released).toContain(o.id);
    expect(await orderRow(o.id)).toMatchObject({ status: 'submitting', submit_error_code: null });
    expect((await historyOf(o.id)).at(-1)).toMatchObject({
      from_status: 'submit_failed',
      to_status: 'submitting',
      source: 'pos_user',
    });
    await h.drain();
    expect(await orderRow(o.id)).toMatchObject({ status: 'awaiting_payment', onec_ref: onecRefFor(o.id) });
    expect((await outboxOf(o.id)).status).toBe('sent');
    // Переход submit_failed → awaiting_payment больше не отвергается автоматом (ошибка ревью F-orders-1c-1).
    const errs = await h.t.q(`SELECT 1 FROM sync_errors WHERE outbox_id = $1 AND message LIKE '%недопустим%'`, [ob.id]);
    expect(errs).toHaveLength(0);
  });

  // 12 T-ORD-032 (а): «деньги получены — заказ отклонён 1С» (10 ORD-035 п. 2).
  it('деньги получены — заказ отклонён 1С → cancelled (P2), платёж received, outbox cancelled, корзина parked, уведомления кассиру и автору; повтор → 409', async () => {
    const o = await create(a.seller);
    const port = h.t.registry.get(ORDER_STATUS_PORT);
    await h.t.db.transaction(async (tx) => {
      await tx.execute(
        sql`UPDATE payments SET status = 'received', received_at = now(), received_by_user_id = ${a.cashier.userId}::uuid
             WHERE order_id = ${o.id}::uuid`,
      );
      await port.applyReceived(tx, {
        orderId: o.id,
        amount: o.total.amount,
        paymentId: o.payments[0].id,
        actor: { userId: a.cashier.userId, roles: ['cashier'], isCustomer: false },
      });
    });
    expect((await orderRow(o.id)).paid_at).not.toBeNull();
    expect((await orderRow(o.id)).status).toBe('submitting');
    h.t.onec.script('createOrder', { error: 422, code: 'POS_E_PRICE' });
    await h.drain();
    expect((await orderRow(o.id)).status).toBe('cancelled');
    const pay = await h.t.q<{ status: string }>(`SELECT status::text AS status FROM payments WHERE order_id = $1`, [
      o.id,
    ]);
    expect(pay[0].status).toBe('received');
    // 10 ORD-035 п. 2 (ревью F-orders-1c-2).
    const ob = await outboxOf(o.id);
    expect(ob.status).toBe('cancelled');
    expect(h.cart.restored).toContainEqual({ orderId: o.id, ownerUserId: a.seller.userId, forceParked: true });
    for (const u of [a.cashier.userId, a.seller.userId]) {
      expect(
        h.t.fakes!.notifications.of(u).some((n) => n.kind === 'payment_status' && n.payload?.orderId === o.id),
        u,
      ).toBe(true);
    }
    const retry = await h.t.req('post', `/sync/outbox/${ob.id}/retry`, a.admin, { idem: true });
    expect(retry.status).toBe(409);
    expect(retry.body.reason).toBe('withdrawn');
    expect((await orderRow(o.id)).onec_ref).toBeNull();
  });

  // 12: T-SYNC-034 (1) (attempts = OUTBOX_MAX_ATTEMPTS → dead, sync_errors, уведомления)
  it('dead: после OUTBOX_MAX_ATTEMPTS временных ошибок → dead, sync_errors, уведомления админу и автору; заказ submitting', async () => {
    const o = await create(a.seller);
    h.t.onec.always('createOrder', { error: 503 });
    try {
      for (let i = 0; i < 3; i++) {
        await h.makeDue();
        await h.drain();
      }
    } finally {
      h.t.onec.always('createOrder', null);
    }
    const ob = await outboxOf(o.id);
    expect(ob).toMatchObject({ status: 'dead', attempts: 3 });
    expect(h.dead.some((d) => d.outboxId === ob.id && d.reason === 'max_attempts')).toBe(true);
    const errs = await h.t.q<{ error_code: string }>(`SELECT error_code FROM sync_errors WHERE outbox_id = $1`, [
      ob.id,
    ]);
    expect(errs.map((e) => e.error_code)).toContain('ONEC_UNAVAILABLE');
    expect(
      h.t.fakes!.notifications.of(a.admin.userId).some((n) => n.kind === 'sync_error' && n.payload?.orderId === o.id),
    ).toBe(true);
    expect(
      h.t.fakes!.notifications.of(a.seller.userId).some((n) => n.kind === 'sync_error' && n.payload?.orderId === o.id),
    ).toBe(true);
    expect((await orderRow(o.id)).status).toBe('submitting');
  });

  it('сверщик outbox.reconcile-aggregates применяет потерянный результат (job не обработан)', async () => {
    const o = await create(a.seller);
    await h.dispatcher.tick(); // событие опубликовано, но не обработано
    expect((await orderRow(o.id)).onec_ref).toBeNull();
    const before = h.published.length;
    const r = await h.results.reconcile();
    expect(r.confirmed).toBeGreaterThanOrEqual(1);
    expect((await orderRow(o.id)).status).toBe('awaiting_payment');
    // Дальнейший drain не применяет событие повторно.
    expect(h.published.length).toBe(before);
    await h.drain();
    expect(await historyOf(o.id)).toHaveLength(2);
  });

  // 12: T-SYNC-035 (1) (документ прочитан → confirmed/linked; не найден → missing), T-SYNC-F07
  it('синхронизация статусов: неизвестный статус → sync_errors без смены; документ не найден → missing', async () => {
    const o = await create(a.seller);
    await h.drain();
    h.t.onec.script('getOrderStatusBatch', {
      respond: { body: { items: [statusItem(o.id, 'НаКакомТоСтатусе')], notFound: [] } },
    });
    const ctx = await syncCtx();
    const r = await h.statusSync.run(ctx);
    expect((r.counts as { unknownStatus: number }).unknownStatus).toBe(1);
    expect((await orderRow(o.id)).status).toBe('awaiting_payment');
    const errs = await h.t.q<{ error_code: string }>(`SELECT error_code FROM sync_errors WHERE local_id = $1`, [o.id]);
    expect(errs.length).toBeGreaterThanOrEqual(1);
    h.t.onec.script('getOrderStatusBatch', { respond: { body: { items: [], notFound: [o.id] } } });
    await h.statusSync.run(await syncCtx());
    expect((await orderRow(o.id)).onec_sync_state).toBe('missing');
    expect((await orderRow(o.id)).status).toBe('awaiting_payment');
  });

  // T-MNY-032, T-DISC-006 (часть «хранятся оба»): итог документа 1С отличается от итога POS — сохраняются оба,
  // заказ помечен `totals_differ` («итог уточнён 1С»); итог POS (снимок) не переписывается.
  it('T-MNY-032: итог 1С ≠ итог POS → onec_total сохранён, totals_differ = true, total заказа прежний', async () => {
    const o = await create(a.seller);
    await h.drain();
    const posTotal = (o as unknown as { total: { amount: string } }).total.amount;
    const onecTotal = (Number(posTotal) - 0.5).toFixed(2);
    h.t.onec.script('getOrderStatusBatch', {
      respond: { body: { items: [statusItem(o.id, 'НеСогласован', { total: onecTotal })], notFound: [] } },
    });
    await h.statusSync.run(await syncCtx());
    const row = await h.t.q<{ total: string; onec_total: string; totals_differ: boolean }>(
      `SELECT total::text AS total, onec_total::text AS onec_total, totals_differ FROM orders WHERE id = $1`,
      [o.id],
    );
    expect(row[0]).toEqual({ total: posTotal, onec_total: onecTotal, totals_differ: true });
    const view = await h.t.req('get', `/orders/${o.id}`, a.seller);
    expect(view.status).toBe(200);
    expect(view.body.total.amount).toBe(posTotal);
    expect(JSON.stringify(view.body)).toContain(`"amount":"${onecTotal}"`);
    // 10 DISC-006, 05 ONEC-039 (разбор 98 п. 49): автору — уведомление «итог уточнён 1С».
    expect(totalsNotes(a.seller.userId, o.id)).toHaveLength(1);
  });

  const totalsNotes = (userId: string, orderId: string) =>
    h.t
      .fakes!.notifications.of(userId)
      .filter((n) => n.payload?.orderId === orderId && n.payload?.totalsDiffer === true);

  function createdBody(orderId: string, total: string, recalculated: boolean) {
    return {
      externalId: orderId,
      ref: onecRefFor(orderId),
      number: onecNumberFor(orderId),
      date: '2026-10-21T13:40:00+06:00',
      status: 'НеСогласован',
      approved: false,
      posted: true,
      deletionMark: false,
      recalculated,
      totals: { subtotal: total, discount: '0.00', total, currency: 'KGS' },
      warnings: [],
    };
  }

  // 10 DISC-006; 05 ONEC-039, SYNC-047; 07 DATA-215; ТЗ для 1С §6.6 (разбор 98 п. 49).
  it('recalculated: итог 1С в ответе POST /orders ≠ итог POS → уведомление автору один раз; совпадает — без уведомления', async () => {
    const o = await create(a.seller);
    const posTotal = (o as unknown as { total: { amount: string } }).total.amount;
    h.t.onec.script('createOrder', { respond: { status: 201, body: createdBody(o.id, '1.00', true) } });
    await h.drain();
    expect((await outboxOf(o.id)).status).toBe('sent');
    const notes = totalsNotes(a.seller.userId, o.id);
    expect(notes).toHaveLength(1);
    expect(notes[0]).toMatchObject({
      kind: 'order_status',
      severity: 'warning',
      dedupeKey: `order_totals_differ:${o.id}`,
      payload: { orderId: o.id, totalsDiffer: true, total: posTotal, onecTotal: '1.00' },
    });
    expect(notes[0].title).toContain('итог уточнён 1С');
    // Повторное расхождение (синхронизация статусов с другим итогом 1С) второго уведомления не создаёт.
    const before = h.t.fakes!.notifications.items.length;
    h.t.onec.script('getOrderStatusBatch', {
      respond: { body: { items: [statusItem(o.id, 'НеСогласован', { total: '2.00' })], notFound: [] } },
    });
    await h.statusSync.run(await syncCtx());
    expect(totalsNotes(a.seller.userId, o.id)).toHaveLength(1);
    expect(h.t.fakes!.notifications.items.length).toBe(before);
    // Итог 1С совпал с итогом POS — уведомления нет.
    const o2 = await create(a.seller);
    const pos2 = (o2 as unknown as { total: { amount: string } }).total.amount;
    h.t.onec.script('createOrder', { respond: { status: 201, body: createdBody(o2.id, pos2, false) } });
    await h.drain();
    expect((await outboxOf(o2.id)).status).toBe('sent');
    expect(totalsNotes(a.seller.userId, o2.id)).toHaveLength(0);
  });

  // T-SYNC-035 (2), T-SYNC-F07: документ не прочитан 30 мин после sent → missing + sync_errors OUTBOX_UNCONFIRMED,
  // элемент outbox остаётся sent (не dead), статус заказа не меняется; раньше 30 мин — без изменений.
  it('T-SYNC-035: документ не найден < 30 мин после sent — без изменений; > 30 мин — missing, OUTBOX_UNCONFIRMED, outbox sent', async () => {
    const o = await create(a.seller);
    await h.drain();
    const outbox = async () =>
      (
        await h.t.q<{ status: string }>(
          `SELECT status::text AS status FROM onec_outbox WHERE aggregate_id = $1 AND operation = 'create'`,
          [o.id],
        )
      )[0].status;
    expect(await outbox()).toBe('sent');
    const unconfirmed = async () =>
      (
        await h.t.q<{ n: string }>(
          `SELECT count(*)::text AS n FROM sync_errors WHERE local_id = $1 AND error_code = 'OUTBOX_UNCONFIRMED'`,
          [o.id],
        )
      )[0].n;
    h.t.onec.script('getOrderStatusBatch', { respond: { body: { items: [], notFound: [o.id] } } });
    await h.statusSync.run(await syncCtx());
    expect((await orderRow(o.id)).onec_sync_state).not.toBe('missing');
    expect(await unconfirmed()).toBe('0');
    await h.t.q(
      `UPDATE onec_outbox SET sent_at = now() - interval '31 minutes' WHERE aggregate_id = $1 AND operation = 'create'`,
      [o.id],
    );
    h.t.onec.script('getOrderStatusBatch', { respond: { body: { items: [], notFound: [o.id] } } });
    await h.statusSync.run(await syncCtx());
    expect((await orderRow(o.id)).onec_sync_state).toBe('missing');
    expect((await orderRow(o.id)).status).toBe('awaiting_payment');
    expect(await unconfirmed()).toBe('1');
    expect(await outbox()).toBe('sent');
  });

  it('оплата закрыта (applyReceived) у «Не согласован» → P9 pending_approval, история pos_system; paid_at однократно', async () => {
    const o = await create(a.cashier);
    await h.drain();
    expect((await orderRow(o.id)).status).toBe('awaiting_payment');
    const port = h.t.registry.get(ORDER_STATUS_PORT);
    const r = await h.t.db.transaction(async (tx) => {
      const locked = await port.lockForPayment(tx, o.id);
      expect(locked).toMatchObject({ status: 'awaiting_payment', isPaid: false, paymentMethod: 'cash' });
      return port.applyReceived(tx, {
        orderId: o.id,
        amount: o.total.amount,
        paymentId: o.payments[0].id,
        actor: { userId: a.cashier.userId, roles: ['cashier'], isCustomer: false },
      });
    });
    expect(r.paidAt).not.toBeNull();
    expect(r.statusChange).toMatchObject({ from: 'awaiting_payment', to: 'pending_approval', historySteps: 1 });
    expect((await historyOf(o.id)).at(-1)).toMatchObject({ to_status: 'pending_approval', source: 'pos_system' });
  });
});

import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { PosActor } from '../support/pos-fixture.js';
import {
  onecRefFor,
  type OrdersHarness,
  orderBody,
  startOrders,
  type OrderDto,
  ids,
} from './support/orders-fixture.js';

/**
 * Отмена (08 §4.8.4; 10 ORD-050…053; ядро §22.9), ручная привязка `onec-link` (08 §4.8.7; ядро §23 п. 1),
 * списки и счётчики (08 §4.8.2; ядро §19.2), карточка заказа, история клиента и права по 11 §4.3–§4.4
 * (RM-F-002, RM-F-012 п. 4, RM-F-015 п. 4; 12 T-ORD-018, T-ORD-020…T-ORD-023, T-ORD-025) — **тестовые данные**.
 */
describe('orders: отмена, onec-link, списки, права', () => {
  let h: OrdersHarness;
  let a: Record<'seller' | 'cashier' | 'senior_seller' | 'admin' | 'owner' | 'customer', PosActor>;
  let qty = 100;

  beforeAll(async () => {
    h = await startOrders({ env: { QR_PROVIDER: 'onec', ONEC_SYNC_CHECK_TIMEOUT_MS: '700' } });
    a = await h.t.actors();
  });
  afterAll(async () => {
    await h?.t.stop();
  });

  async function create(actor: PosActor, extra: Record<string, unknown> = {}): Promise<OrderDto> {
    const [v] = await h.t.saleableVariants(1);
    qty += 1;
    const cart = await h.cart.create(actor, [{ variantId: v.variantId, quantity: String(qty) }]);
    const res = await h.t
      .req('post', '/orders', actor, { idem: true })
      .send(orderBody(cart, { confirmDuplicate: true, ...extra }));
    expect(res.status, JSON.stringify(res.body)).toBeLessThan(300);
    return res.body as OrderDto;
  }
  const status = async (id: string) =>
    (await h.t.q<{ s: string }>(`SELECT status::text AS s FROM orders WHERE id = $1`, [id]))[0].s;
  const outbox = async (id: string, op: string) =>
    (
      await h.t.q<{ status: string; depends_on_outbox_id: string | null; attempts: number }>(
        `SELECT status::text AS status, depends_on_outbox_id, attempts FROM onec_outbox
          WHERE aggregate_id = $1 AND operation = $2`,
        [id, op],
      )
    )[0];
  const cancelBody = { reason: 'Клиент передумал', reasonCode: 'customer_refused' };

  describe('отмена', () => {
    // 12: T-CART-010 (отмена заказа до согласования → cancelled, транзакция order_cancelled, аудит), T-TXN-001 (order_cancelled, payment_voided)
    it('свой заказ submitting (outbox pending) → немедленно cancelled: outbox cancelled, платёж voided, корзина, транзакция', async () => {
      const o = await create(a.seller);
      const key = randomUUID();
      const res = await h.t.req('post', `/orders/${o.id}/cancel`, a.seller, { idem: key }).send(cancelBody);
      expect(res.status, JSON.stringify(res.body)).toBe(200);
      expect(res.body.status).toBe('cancelled');
      expect((await outbox(o.id, 'create')).status).toBe('cancelled');
      const pay = await h.t.q<{ status: string }>(`SELECT status::text AS status FROM payments WHERE order_id = $1`, [
        o.id,
      ]);
      expect(pay[0].status).toBe('voided');
      expect(h.cart.restored.some((r) => r.orderId === o.id)).toBe(true);
      const tx = await h.t.q<{ kind: string }>(`SELECT kind::text AS kind FROM transactions WHERE order_id = $1`, [
        o.id,
      ]);
      expect(tx.map((x) => x.kind).sort()).toEqual(['order_cancelled', 'order_created']);
      expect(await h.t.auditRows('order.cancelled', o.id)).toHaveLength(1);
      // Повтор тем же ключом — тот же ответ; другим ключом — 409 (заказ уже отменён), без второй транзакции.
      const again = await h.t.req('post', `/orders/${o.id}/cancel`, a.seller, { idem: key }).send(cancelBody);
      expect(again.status).toBe(200);
      expect(again.headers['idempotent-replayed']).toBe('true');
      const other = await h.t.req('post', `/orders/${o.id}/cancel`, a.seller, { idem: true }).send(cancelBody);
      expect(other.status).toBe(409);
      expect(other.body).toMatchObject({
        code: 'ORDER_STATE_INVALID',
        resource: 'order',
        reason: 'invalid_transition',
      });
      const tx2 = await h.t.q<{ n: string }>(
        `SELECT count(*)::text AS n FROM transactions WHERE order_id = $1 AND kind = 'order_cancelled'`,
        [o.id],
      );
      expect(tx2[0].n).toBe('1');
    });

    it('свой заказ в 1С (awaiting_payment) → запрос отмены; 1С подтвердила → cancelled; отказ 1С → cancelRequested снят', async () => {
      const o = await create(a.seller);
      await h.drain();
      expect(await status(o.id)).toBe('awaiting_payment');
      const res = await h.t.req('post', `/orders/${o.id}/cancel`, a.seller, { idem: true }).send(cancelBody);
      expect(res.status).toBe(200);
      expect(res.body).toMatchObject({ status: 'awaiting_payment', cancelRequested: true });
      expect((await outbox(o.id, 'cancel')).status).toBe('pending');
      expect(await h.t.auditRows('order.cancel_requested', o.id)).not.toHaveLength(0);
      const dup = await h.t.req('post', `/orders/${o.id}/cancel`, a.seller, { idem: true }).send(cancelBody);
      expect(dup.status).toBe(409);
      expect(dup.body.reason).toBe('cancel_already_requested');
      h.t.onec.script('cancelOrder', {
        respond: {
          body: {
            externalId: o.id,
            ref: onecRefFor(o.id),
            status: 'Закрыт',
            approved: false,
            deletionMark: true,
            shipments: [],
          },
        },
      });
      await h.drain();
      expect(await status(o.id)).toBe('cancelled');
      expect((await outbox(o.id, 'cancel')).status).toBe('sent');

      const o2 = await create(a.seller);
      await h.drain();
      await h.t.req('post', `/orders/${o2.id}/cancel`, a.seller, { idem: true }).send(cancelBody);
      h.t.onec.script('cancelOrder', { fixture: 'orders-cancel.409' });
      await h.drain();
      expect(await status(o2.id)).toBe('awaiting_payment');
      const got = await h.t.req('get', `/orders/${o2.id}`, a.seller);
      expect(got.body.cancelRequested).toBe(false);
      expect(
        h.t
          .fakes!.notifications.of(a.seller.userId)
          .some((n) => n.dedupeKey.startsWith(`order_cancel_rejected:${o2.id}`)),
      ).toBe(true);
      // Повторный запрос отмены после отказа 1С (10 ORD-050, 08 §4.8.4): строка cancel (failed) переотправляется, а не теряется
      // (ревью F-orders-1c-3): pending, attempts=0; 1С подтверждает → cancelled.
      const cancelCalls = h.t.onec.callsOf('cancelOrder').length;
      const again = await h.t.req('post', `/orders/${o2.id}/cancel`, a.seller, { idem: true }).send(cancelBody);
      expect(again.status, JSON.stringify(again.body)).toBe(200);
      expect(again.body.cancelRequested).toBe(true);
      expect(await outbox(o2.id, 'cancel')).toMatchObject({ status: 'pending', attempts: 0 });
      h.t.onec.script('cancelOrder', {
        respond: {
          body: {
            externalId: o2.id,
            ref: onecRefFor(o2.id),
            status: 'Закрыт',
            approved: false,
            deletionMark: true,
            shipments: [],
          },
        },
      });
      await h.drain();
      expect(h.t.onec.callsOf('cancelOrder').length).toBe(cancelCalls + 1);
      expect(await status(o2.id)).toBe('cancelled');
    });

    // 12: T-ORD-021 (а) (отмена чужого: seller2 → 404, cashier без step-up → STEP_UP_REQUIRED, со step-up → отмена; owner → 403)
    it('права: seller — чужой → 404; cashier — чужой без step-up → STEP_UP_REQUIRED, со step-up → отменён; owner → 403', async () => {
      const o = await create(a.seller);
      const seller2 = await h.t.actor({ role: 'seller' });
      expect((await h.t.req('post', `/orders/${o.id}/cancel`, seller2, { idem: true }).send(cancelBody)).status).toBe(
        404,
      );
      expect((await h.t.req('post', `/orders/${o.id}/cancel`, a.owner, { idem: true }).send(cancelBody)).status).toBe(
        403,
      );
      const noStep = await h.t.req('post', `/orders/${o.id}/cancel`, a.cashier, { idem: true }).send(cancelBody);
      expect(noStep.status).toBe(403);
      expect(noStep.body).toMatchObject({
        code: 'STEP_UP_REQUIRED',
        stepUp: { operation: 'order.cancel.request.any' },
      });
      const step = await h.t.stepUp(a.cashier, 'order.cancel.request.any');
      const ok = await h.t
        .req('post', `/orders/${o.id}/cancel`, a.cashier, { idem: true, stepUp: step })
        .send(cancelBody);
      expect(ok.status, JSON.stringify(ok.body)).toBe(200);
      expect(ok.body.status).toBe('cancelled');
      const audit = await h.t.auditRows('order.cancelled', o.id);
      expect(audit[0].step_up_method).toBe('pin');
    });

    // 12: T-ORD-022 (отгруженный не отменяется → 409 ORDER_STATE_INVALID)
    it('платёж на разборе (manual_confirm) → 409 PAYMENT_STATE_INVALID open_payment_exists; отгруженный — не отменяется', async () => {
      const o = await create(a.cashier, { paymentMethod: 'qr_bakai' });
      await h.t.q(`UPDATE payments SET status = 'manual_confirm', review_reason = 'no_webhook' WHERE order_id = $1`, [
        o.id,
      ]);
      const res = await h.t.req('post', `/orders/${o.id}/cancel`, a.cashier, { idem: true }).send(cancelBody);
      expect(res.status).toBe(409);
      expect(res.body).toMatchObject({
        code: 'PAYMENT_STATE_INVALID',
        reason: 'open_payment_exists',
        openPaymentId: o.payments[0].id,
      });
      const shipped = await h.t.seedOrder({ createdBy: a.seller, method: 'cash', status: 'awaiting_shipment' });
      await h.t.q(`UPDATE orders SET status = 'shipped', shipped_at = now() WHERE id = $1`, [shipped.orderId]);
      const r2 = await h.t.req('post', `/orders/${shipped.orderId}/cancel`, a.seller, { idem: true }).send(cancelBody);
      expect(r2.status).toBe(409);
      expect(r2.body.code).toBe('ORDER_STATE_INVALID');
    });
  });

  describe('POST /orders/{id}/onec-link', () => {
    function linkScript(orderId: string, number: string, ref = randomUUID()) {
      h.t.onec.externalIds.push({
        items: [
          {
            externalId: orderId,
            objectType: 'Заказ',
            ref,
            number,
            date: '2026-10-21T13:40:00+06:00',
            deletionMark: false,
          },
        ],
        hasMore: false,
        cursor: null,
      });
      h.t.onec.script('getOrderStatus', {
        respond: {
          body: {
            externalId: orderId,
            ref,
            number,
            date: '2026-10-21T13:40:00+06:00',
            status: 'НеСогласован',
            approved: false,
            deletionMark: false,
            total: '1.00',
            shipments: [],
          },
        },
      });
      return ref;
    }
    const body = { onecNumber: 'УТ-0001234', reason: 'документ оформлен вручную в 1С' };

    it('seller/cashier → 403; без step-up → STEP_UP_REQUIRED; привязка: outbox pending → sent, linked, P8, аудит', async () => {
      const o = await create(a.seller);
      expect((await h.t.req('post', `/orders/${o.id}/onec-link`, a.seller, { idem: true }).send(body)).status).toBe(
        403,
      );
      expect((await h.t.req('post', `/orders/${o.id}/onec-link`, a.cashier, { idem: true }).send(body)).status).toBe(
        403,
      );
      const noStep = await h.t.req('post', `/orders/${o.id}/onec-link`, a.senior_seller, { idem: true }).send(body);
      expect(noStep.status).toBe(403);
      expect(noStep.body.code).toBe('STEP_UP_REQUIRED');
      const ref = linkScript(o.id, 'УТ-0001234');
      const step = await h.t.stepUp(a.senior_seller, 'order.onec_link');
      const res = await h.t
        .req('post', `/orders/${o.id}/onec-link`, a.senior_seller, { idem: true, stepUp: step })
        .send(body);
      expect(res.status, JSON.stringify(res.body)).toBe(200);
      expect(res.body).toMatchObject({ status: 'awaiting_payment', onecSyncState: 'linked' });
      expect(res.body.onec).toMatchObject({ number: 'УТ-0001234', ref });
      expect((await outbox(o.id, 'create')).status).toBe('sent');
      const audit = await h.t.auditRows('order.onec_linked', o.id);
      expect(audit).toHaveLength(1);
      expect(audit[0].step_up_method).toBe('pin');
      // Тот же документ с другим ключом — 200 без изменений; другой номер — already_linked.
      const step2 = await h.t.stepUp(a.senior_seller, 'order.onec_link');
      const same = await h.t
        .req('post', `/orders/${o.id}/onec-link`, a.senior_seller, { idem: true, stepUp: step2 })
        .send(body);
      expect(same.status).toBe(200);
      const step3 = await h.t.stepUp(a.senior_seller, 'order.onec_link');
      const diff = await h.t
        .req('post', `/orders/${o.id}/onec-link`, a.senior_seller, { idem: true, stepUp: step3 })
        .send({ ...body, onecNumber: 'УТ-9999999' });
      expect(diff.status).toBe(409);
      expect(diff.body.reason).toBe('already_linked');
    });

    it('из failed (submit_failed) и dead → sent; документ не найден → 404; 1С недоступна → 503', async () => {
      await h.drain(); // прочие строки outbox уже отправлены — сценарий 1С достанется этому заказу
      const o = await create(a.seller);
      h.t.onec.script('createOrder', { fixture: 'orders-create.422' });
      await h.drain();
      expect(await status(o.id)).toBe('submit_failed');
      linkScript(o.id, 'УТ-0005555');
      // 12 T-ORD-018: восстановленная корзина изменена пользователем → 409 «Заказ уже исправляется» (10 ORD-034, ORD-027).
      h.cart.releaseResult = 'modified';
      try {
        const busy = await h.t
          .req('post', `/orders/${o.id}/onec-link`, a.admin, {
            idem: true,
            stepUp: await h.t.stepUp(a.admin, 'order.onec_link'),
          })
          .send({ ...body, onecNumber: 'УТ-0005555' });
        expect(busy.status, JSON.stringify(busy.body)).toBe(409);
        expect(busy.body).toMatchObject({ code: 'ORDER_STATE_INVALID', reason: 'restored_cart_in_use' });
        expect((await outbox(o.id, 'create')).status).toBe('failed');
        expect(await status(o.id)).toBe('submit_failed');
      } finally {
        h.cart.releaseResult = 'none';
      }
      linkScript(o.id, 'УТ-0005555');
      const step = await h.t.stepUp(a.admin, 'order.onec_link');
      const res = await h.t
        .req('post', `/orders/${o.id}/onec-link`, a.admin, { idem: true, stepUp: step })
        .send({ ...body, onecNumber: 'УТ-0005555' });
      expect(res.status, JSON.stringify(res.body)).toBe(200);
      expect(res.body.status).toBe('awaiting_payment');
      expect((await outbox(o.id, 'create')).status).toBe('sent');
      const hist = await h.t.q<{ to_status: string; source: string }>(
        `SELECT to_status::text AS to_status, source::text AS source FROM order_status_history WHERE order_id = $1 ORDER BY occurred_at, id`,
        [o.id],
      );
      expect(hist.map((x) => x.to_status)).toEqual(['submitting', 'submit_failed', 'submitting', 'awaiting_payment']);
      expect(h.cart.released).toContain(o.id);

      const o2 = await create(a.seller);
      await h.t.q(`UPDATE onec_outbox SET status = 'dead', dead_at = now() WHERE aggregate_id = $1`, [o2.id]);
      linkScript(o2.id, 'УТ-0007777');
      const s2 = await h.t.stepUp(a.owner, 'order.onec_link');
      const r2 = await h.t
        .req('post', `/orders/${o2.id}/onec-link`, a.owner, { idem: true, stepUp: s2 })
        .send({ ...body, onecNumber: 'УТ-0007777' });
      expect(r2.status, JSON.stringify(r2.body)).toBe(200);
      expect((await outbox(o2.id, 'create')).status).toBe('sent');

      const o3 = await create(a.seller);
      linkScript(o3.id, 'УТ-1111111');
      const s3 = await h.t.stepUp(a.admin, 'order.onec_link');
      const nf = await h.t
        .req('post', `/orders/${o3.id}/onec-link`, a.admin, { idem: true, stepUp: s3 })
        .send({ ...body, onecNumber: 'УТ-0000000' });
      expect(nf.status).toBe(404);
      h.t.onec.reset();
      h.t.onec.externalIds.push('transport');
      const s4 = await h.t.stepUp(a.admin, 'order.onec_link');
      const down = await h.t.req('post', `/orders/${o3.id}/onec-link`, a.admin, { idem: true, stepUp: s4 }).send(body);
      expect(down.status).toBe(503);
      expect(down.body.code).toBe('ONEC_UNAVAILABLE');
    });
  });

  describe('чтение и права', () => {
    it('GET /orders: seller — свои, cashier — все; statusCounts без фильтра status; totalEstimate; createdBy у seller → 403', async () => {
      const seller = await h.t.actor({ role: 'seller' });
      const o1 = await create(seller);
      const o2 = await create(seller);
      await h.drain();
      const o3 = await create(seller); // остаётся submitting
      const mine = await h.t.req('get', '/orders?include=statusCounts&status=awaiting_payment', seller);
      expect(mine.status).toBe(200);
      expect(ids(mine.body).sort()).toEqual([o1.id, o2.id].sort());
      expect(mine.body.totalEstimate).toBe(2);
      expect(mine.body.statusCounts).toMatchObject({ awaiting_payment: 2, submitting: 1, cancelled: 0 });
      expect(mine.body.items[0]).toMatchObject({ itemsCount: 1 });
      expect(mine.body.items[0].items).toBeUndefined();
      const page = await h.t.req('get', '/orders?limit=1', seller);
      expect(page.body.hasMore).toBe(true);
      const next = await h.t.req('get', `/orders?limit=1&cursor=${encodeURIComponent(page.body.nextCursor)}`, seller);
      expect(next.status).toBe(200);
      expect(next.body.items[0].id).not.toBe(page.body.items[0].id);
      expect((await h.t.req('get', '/orders?cursor=forged.x', seller)).status).toBe(400);
      const all = await h.t.req('get', `/orders?createdBy=${seller.userId}`, a.cashier);
      expect(ids(all.body)).toContain(o3.id);
      expect((await h.t.req('get', `/orders?createdBy=${seller.userId}`, a.seller)).status).toBe(403);
      expect((await h.t.req('get', '/orders?sort=foo', seller)).status).toBe(400);
      // Ключи прототипа Object — тоже вне перечня (ревью F-security-3): 400, не 200/500.
      for (const sort of ['toString', 'constructor', '__proto__', 'hasOwnProperty']) {
        const r = await h.t.req('get', `/orders?sort=${sort}`, seller);
        expect(r.status, sort).toBe(400);
        expect(r.body.errors[0]).toMatchObject({ field: 'sort', rule: 'sort_field' });
      }
    });

    it('GET /orders/{id}: свой — с allowedActions; чужой у seller → 404; include ограничивает состав; owner читает', async () => {
      const o = await create(a.seller);
      const got = await h.t.req('get', `/orders/${o.id}`, a.seller);
      expect(got.status).toBe(200);
      expect(got.body.allowedActions).toContain('cancel');
      expect(got.body.items).toHaveLength(1);
      const seller2 = await h.t.actor({ role: 'seller' });
      expect((await h.t.req('get', `/orders/${o.id}`, seller2)).status).toBe(404);
      expect((await h.t.req('get', `/orders/not-a-uuid`, a.seller)).status).toBe(404);
      const part = await h.t.req('get', `/orders/${o.id}?include=items`, a.owner);
      expect(part.status).toBe(200);
      expect(part.body.history).toBeUndefined();
      expect(part.body.allowedActions).not.toContain('cancel');
    });

    it('GET /customers/{id}/orders: cashier — заказы POS клиента; seller → 403; клиент — только своя подтверждённая карточка', async () => {
      const buyer = await h.t.actor({ role: 'customer' });
      const card = await h.t.createOnecCustomer();
      await h.t.linkCustomer(buyer.userId, card, 'confirmed');
      const o = await create(buyer, { paymentMethod: 'qr_bakai' });
      expect(o.createdVia).toBe('customer');
      const res = await h.t.req('get', `/customers/${card}/orders`, a.cashier);
      expect(res.status).toBe(200);
      expect(ids(res.body)).toEqual([o.id]);
      expect(res.body.summary.count).toBe(1);
      expect((await h.t.req('get', `/customers/${card}/orders`, a.seller)).status).toBe(403);
      expect((await h.t.req('get', `/customers/${card}/orders`, buyer)).status).toBe(200);
      expect((await h.t.req('get', `/customers/${card}/orders`, a.customer)).status).toBe(404);
      // Клиент-покупатель видит заказы своей карточки в списке.
      const list = await h.t.req('get', '/orders', buyer);
      expect(ids(list.body)).toContain(o.id);
    });

    // 12: T-PAY-042 (клиент: QR своего заказа; чужой → 404)
    it('режим клиента при QR_PROVIDER=onec: qr_bakai → 201; свой заказ отменяет без step-up; чужой → 404', async () => {
      const buyer = await h.t.actor({ role: 'customer' });
      const o = await create(buyer, { paymentMethod: 'qr_bakai' });
      expect(o.payments[0].method).toBe('qr_bakai');
      expect(
        (await h.t.req('post', `/orders/${o.id}/cancel`, a.customer, { idem: true }).send(cancelBody)).status,
      ).toBe(404);
      const res = await h.t.req('post', `/orders/${o.id}/cancel`, buyer, { idem: true }).send(cancelBody);
      expect(res.status, JSON.stringify(res.body)).toBe(200);
      expect(res.body.status).toBe('cancelled');
    });
  });
});

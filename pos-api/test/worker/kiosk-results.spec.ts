import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CartJobsHandler } from '../../src/cart/cart-jobs.js';
import { CartModule } from '../../src/cart/cart.module.js';
import { CART_READER, type CartReader, NOTIFICATIONS_PORT, PAYMENTS_PORT } from '../../src/common/ports/index.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import { kioskNoticeSha256 } from '../../src/kiosk/otp/notice-catalog.js';
import { NotificationCenterModule } from '../../src/notifications/center/notification-center.module.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { OrderOnecResultsHandler, type OrdersWorkerLog } from '../../src/orders/worker/order-onec-results.handler.js';
import { PaymentsModule } from '../../src/payments/payments.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import { type KioskTablet, KioskTestApp } from '../kiosk/support/kiosk-fixture.js';
import type { PosActor, SaleableVariant, SeededOrder } from '../support/pos-fixture.js';

/**
 * Результаты 1С по заявке с планшета в `pos-worker` (`OrderOnecResultsHandler`; 10 KIOSK-030, ORD-027, ORD-031,
 * ORD-035; 08 §3.13, §4.8.4; P-002 §8.7 п. 8–9; ADR-115; задача TAB-1-08) — **тестовые данные**: стенд `kiosk-fixture`
 * (embedded PostgreSQL 17 со всеми миграциями, синтетический каталог, `ScriptedOnecGateway`) с настоящими портами
 * корзины, платежей и уведомлений (как их берёт pos-worker из контекста Nest). Заявка с планшета — заказ стенда
 * (`seedOrder`: строки, платёж `cash_pending`, outbox `create`) с признаками канала `kiosk` (как после
 * `POST /kiosk/orders`: `created_via`, `kiosk_customer_match`, получатель — номер кода `+996 555 007 xxx`,
 * `pd_notice_*`); автор — технический пользователь планшета, корзина которого уже сброшена (пустая активная).
 * - T-KIOSK-039: отказ 1С `submit_failed` (ORD-027) и отказ по оплаченной заявке `cancelled` (ORD-035) — корзина
 *   планшета не восстанавливается ни активной, ни отложенной, автору уведомлений нет, кассиру и старшему продавцу —
 *   есть; `dead` задачи (ORD-031) и отказ 1С в отмене — так же; `CartReader.restoreFromOrder` для заявки — `skipped`;
 * - паритет: заказ сотрудника при отказе 1С — восстановленная корзина и уведомление автору, как прежде;
 * - корзина планшета в `catalog.prices-changed`: пометки строк ставятся, уведомления владельцу-планшету нет.
 */
type Method = 'get' | 'post' | 'put' | 'delete';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
}

const NOTICE = '2026-11-04';

let phoneSeq = 0;
/** Вымышленный мобильный номер КР `+996 555 007 xxx` (тестовые данные). */
function buyerPhone(): string {
  phoneSeq += 1;
  return `+996555007${String(100 + phoneSeq).padStart(3, '0')}`;
}

class RecLog implements OrdersWorkerLog {
  readonly lines: { level: string; msg?: string; obj: object }[] = [];
  info(obj: object, msg?: string): void {
    this.lines.push({ level: 'info', obj, msg });
  }
  warn(obj: object, msg?: string): void {
    this.lines.push({ level: 'warn', obj, msg });
  }
  error(obj: object, msg?: string): void {
    this.lines.push({ level: 'error', obj, msg });
  }
}

describe('pos-worker: результаты 1С по заявке с планшета (KIOSK-030)', () => {
  const t = new KioskTestApp();
  const log = new RecLog();
  let handler: OrderOnecResultsHandler;
  let cart: CartReader;
  let v: SaleableVariant[];
  let cashier: PosActor;
  let senior: PosActor;
  let seller: PosActor;
  let admin: PosActor;

  async function call(
    method: Method,
    path: string,
    a: PosActor,
    body?: unknown,
    opts: { readonly idem?: string | true; readonly stepUp?: string } = {},
  ): Promise<Res> {
    const r = t.req(method, path, a, opts);
    const res = await (body !== undefined ? r.send(body as object) : r);
    return { status: res.status, body: (res.body ?? {}) as Res['body'] };
  }

  /** Планшет после автосброса (FLOW-045): активная пустая корзина технического пользователя. */
  async function resetTablet(): Promise<KioskTablet> {
    const tab = await t.tablet();
    const c = await call('get', '/cart', tab);
    expect(c.status, JSON.stringify(c.body)).toBe(200);
    expect(c.body.items).toEqual([]);
    return tab;
  }

  /** Заявка с планшета в БД стенда: заказ `seedOrder` + признаки канала `kiosk` (08 §4.25.2, 07 §5.37). */
  async function kioskOrder(
    tab: KioskTablet,
    status: 'submitting' | 'pending_approval' = 'submitting',
  ): Promise<SeededOrder & { phone: string }> {
    const o = await t.seedOrder({
      createdBy: tab,
      method: 'cash',
      status,
      items: [{ variantId: v[0].variantId, quantity: '1' }],
    });
    const phone = buyerPhone();
    await t.q(
      `UPDATE orders SET created_via = 'kiosk', kiosk_customer_match = 'none', receiver_kind = 'customer',
              receiver_name = NULL, receiver_phone_e164 = $2, pd_notice_version = $3, pd_notice_sha256 = $4
        WHERE id = $1`,
      [o.orderId, phone, NOTICE, kioskNoticeSha256(NOTICE)],
    );
    return { ...o, phone };
  }

  /** Отказ 1С по задаче `create` записан диспетчером (`failed`, ONEC_REJECTED), результат ещё не применён. */
  async function rejectCreate(outboxId: string): Promise<void> {
    await t.q(
      `UPDATE onec_outbox SET status = 'failed', attempts = 1, last_error_code = 'ONEC_REJECTED',
              last_error = 'POS_E_VALIDATION: отказ (тест)', onec_response = $2::jsonb, next_attempt_at = NULL
        WHERE id = $1`,
      [outboxId, JSON.stringify({ message: 'Контрагент заблокирован (тест)' })],
    );
  }

  const failed = (outboxId: string) => ({ outboxId, aggregateId: '', errorCode: 'ONEC_REJECTED', attempt: 1 });

  async function notified(dedupeKey: string): Promise<{ user_id: string; kind: string; body_ru: string }[]> {
    return t.q(
      `SELECT user_id::text AS user_id, kind::text AS kind, body_ru FROM notifications WHERE dedupe_key = $1`,
      [dedupeKey],
    );
  }

  async function tabletNotifications(tab: KioskTablet): Promise<number> {
    return (
      await t.q<{ n: number }>(`SELECT count(*)::int AS n FROM notifications WHERE user_id = $1`, [tab.userId])
    )[0].n;
  }

  /** Корзины планшета: восстановленных из заказа и отложенных нет, активная — пустая (KIOSK-030). */
  async function expectTabletCartsUntouched(tab: KioskTablet): Promise<void> {
    const r = await t.q<{ restored: number; parked: number; active_items: number }>(
      `SELECT (SELECT count(*) FROM carts WHERE owner_user_id = $1 AND restored_from_order_id IS NOT NULL)::int AS restored,
              (SELECT count(*) FROM carts WHERE owner_user_id = $1 AND status = 'parked')::int AS parked,
              (SELECT count(*) FROM cart_items i JOIN carts c ON c.id = i.cart_id
                WHERE c.owner_user_id = $1 AND c.status = 'active')::int AS active_items`,
      [tab.userId],
    );
    expect(r[0]).toEqual({ restored: 0, parked: 0, active_items: 0 });
    const c = await call('get', '/cart', tab);
    expect(c.body.items).toEqual([]);
    expect(c.body.restoredFromOrder ?? null).toBeNull();
  }

  async function orderStatus(orderId: string): Promise<string> {
    return (await t.q<{ s: string }>(`SELECT status::text AS s FROM orders WHERE id = $1`, [orderId]))[0].s;
  }

  beforeAll(async () => {
    await t.start({
      env: { QR_PROVIDER: 'none', KIOSK_MODE: 'true' },
      skuCount: 40,
      modules: [
        CartModule,
        OrdersModule,
        PaymentsModule,
        NotificationCenterModule,
        ProfileModule,
        PublicSettingsModule,
        KioskModule,
      ],
      guards: [KIOSK_ACCESS_GUARD],
      fakePorts: true,
      jobs: false,
    });
    v = await t.saleableVariants(4);
    for (const x of v) await t.setPrice(x.variantId, '100.00');
    cashier = await t.actor({ role: 'cashier' });
    senior = await t.actor({ role: 'senior_seller' });
    seller = await t.actor({ role: 'seller' });
    admin = await t.actor({ role: 'admin' });
    cart = t.registry.get(CART_READER);
    // Порты — как в pos-worker (src/worker.ts): реализации из контекста Nest.
    handler = new OrderOnecResultsHandler({
      db: t.db,
      notifications: t.registry.get(NOTIFICATIONS_PORT),
      cart,
      payments: t.registry.get(PAYMENTS_PORT),
      log,
    });
  });

  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-039 submit_failed/cancelled → no restore, no author notifications, role notifications', async () => {
    // (1) 1С отклонила заявку (ORD-027): submit_failed, платёж cash_pending → voided.
    const tab = await resetTablet();
    const a = await kioskOrder(tab);
    await rejectCreate(a.outboxId);
    expect(await handler.onFailed(failed(a.outboxId))).toBe('applied');
    expect(await orderStatus(a.orderId)).toBe('submit_failed');
    expect((await t.q<{ s: string }>(`SELECT status::text AS s FROM payments WHERE id = $1`, [a.paymentId]))[0].s).toBe(
      'voided',
    );
    await expectTabletCartsUntouched(tab);
    expect(await tabletNotifications(tab)).toBe(0);
    const rejected = await notified(`kiosk_order_status:${a.orderId}:submit_failed`);
    expect(rejected.map((x) => x.user_id)).toEqual(expect.arrayContaining([cashier.userId, senior.userId]));
    expect(rejected.map((x) => x.user_id)).not.toContain(seller.userId);
    expect(rejected.every((x) => x.kind === 'order_status' && !x.body_ru.includes(a.phone.slice(4)))).toBe(true);
    expect(await notified(`order_status:${a.orderId}:submit_failed`)).toEqual([]);
    // Повторная доставка того же события — ничего не меняет (идемпотентно по outboxId и dedupe_key).
    expect(await handler.onFailed(failed(a.outboxId))).toBe('skipped');
    expect(await notified(`kiosk_order_status:${a.orderId}:submit_failed`)).toHaveLength(rejected.length);

    // (2) 1С отклонила оплаченную заявку (ORD-035): cancelled, корзина не парковается, деньги — задача кассе.
    const b = await kioskOrder(tab);
    const total = (
      await t.q<{ total: string }>(`SELECT total::text AS total FROM orders WHERE id = $1`, [b.orderId])
    )[0].total;
    const paid = await call(
      'post',
      `/orders/${b.orderId}/payments`,
      cashier,
      { method: 'cash', receivedAmount: { amount: total, currency: 'KGS' } },
      { idem: true },
    );
    expect(paid.status, JSON.stringify(paid.body)).toBe(200);
    expect(paid.body.status).toBe('received');
    await rejectCreate(b.outboxId);
    expect(await handler.onFailed(failed(b.outboxId))).toBe('applied');
    expect(await orderStatus(b.orderId)).toBe('cancelled');
    await expectTabletCartsUntouched(tab);
    expect(await tabletNotifications(tab)).toBe(0);
    const money = await notified(`order_rejected_paid:${b.orderId}`);
    expect(money.map((x) => x.user_id)).toEqual(expect.arrayContaining([cashier.userId, senior.userId]));
    expect(money.map((x) => x.user_id)).not.toContain(tab.userId);
    expect(money.every((x) => x.kind === 'payment_status')).toBe(true);
    // Кассир, принявший деньги, — одно уведомление о деньгах (UNIQUE user_id + dedupe_key).
    expect(money.filter((x) => x.user_id === cashier.userId)).toHaveLength(1);
    expect((await notified(`kiosk_order_status:${b.orderId}:cancelled`)).map((x) => x.user_id)).toEqual(
      expect.arrayContaining([cashier.userId, senior.userId]),
    );

    // (3) Задача outbox исчерпала повторы (ORD-031): sync_error администраторам, кассиру и старшему продавцу.
    const c = await kioskOrder(tab);
    await handler.onDead({ id: c.outboxId, aggregateType: 'order', aggregateId: c.orderId, operation: 'create' }, 'x');
    const dead = await notified(`outbox_dead:${c.outboxId}`);
    expect(dead.map((x) => x.user_id)).toEqual(expect.arrayContaining([admin.userId, cashier.userId, senior.userId]));
    expect(dead.map((x) => x.user_id)).not.toContain(tab.userId);
    expect(dead.every((x) => x.kind === 'sync_error')).toBe(true);
    expect(await tabletNotifications(tab)).toBe(0);

    // (4) 1С отклонила запрос отмены заявки, уже созданной в 1С: запросившему и ролям кассы, не автору.
    const d = await kioskOrder(tab, 'pending_approval');
    const stepUp = await t.stepUp(cashier, 'order.cancel.request.any');
    const req = await call(
      'post',
      `/orders/${d.orderId}/cancel`,
      cashier,
      { reason: 'Покупатель передумал (тест)', reasonCode: 'customer_refused' },
      { idem: true, stepUp },
    );
    expect(req.status, JSON.stringify(req.body)).toBe(200);
    expect(req.body).toMatchObject({ status: 'pending_approval', cancelRequested: true });
    const [cancelJob] = await t.q<{ id: string }>(
      `SELECT id FROM onec_outbox WHERE aggregate_id = $1 AND operation = 'cancel'`,
      [d.orderId],
    );
    await t.q(
      `UPDATE onec_outbox SET status = 'failed', attempts = 1, last_error_code = 'ONEC_REJECTED',
              last_error = 'POS_E_STATE: документ проведён (тест)', next_attempt_at = NULL WHERE id = $1`,
      [cancelJob.id],
    );
    expect(await handler.onFailed(failed(cancelJob.id))).toBe('applied');
    const refused = await t.q<{ user_id: string }>(
      `SELECT user_id::text AS user_id FROM notifications WHERE dedupe_key LIKE $1`,
      [`order_cancel_rejected:${d.orderId}:%`],
    );
    expect(refused.map((x) => x.user_id)).toEqual(expect.arrayContaining([cashier.userId, senior.userId]));
    expect(refused.map((x) => x.user_id)).not.toContain(tab.userId);
    expect(refused.filter((x) => x.user_id === cashier.userId)).toHaveLength(1);
    expect(await tabletNotifications(tab)).toBe(0);
    await expectTabletCartsUntouched(tab);

    // (5) Защита на стороне корзины: restoreFromOrder для заявки с планшета ничего не создаёт.
    const r = await t.db.transaction((tx) =>
      cart.restoreFromOrder(tx, { orderId: a.orderId, ownerUserId: tab.userId }),
    );
    expect(r).toEqual({ cartId: null, status: 'skipped' });
    const forced = await t.db.transaction((tx) =>
      cart.restoreFromOrder(tx, { orderId: b.orderId, ownerUserId: tab.userId, forceParked: true }),
    );
    expect(forced).toEqual({ cartId: null, status: 'skipped' });
    await expectTabletCartsUntouched(tab);
    // В журнале воркера — ни номеров покупателей, ни кодов.
    const logged = JSON.stringify(log.lines);
    for (const o of [a, b, c, d]) expect(logged).not.toContain(o.phone.slice(4));
  });

  it('KIOSK-030 parity: staff order rejected by 1C — restored cart and author notification as before', async () => {
    const o = await t.seedOrder({
      createdBy: seller,
      method: 'cash',
      items: [{ variantId: v[1].variantId, quantity: '2' }],
    });
    await rejectCreate(o.outboxId);
    expect(await handler.onFailed(failed(o.outboxId))).toBe('applied');
    expect(await orderStatus(o.orderId)).toBe('submit_failed');
    const restored = await t.q<{ status: string }>(
      `SELECT status::text AS status FROM carts WHERE owner_user_id = $1 AND restored_from_order_id = $2`,
      [seller.userId, o.orderId],
    );
    expect(restored).toHaveLength(1);
    expect((await notified(`order_status:${o.orderId}:submit_failed`)).map((x) => x.user_id)).toEqual([seller.userId]);
    expect(await notified(`kiosk_order_status:${o.orderId}:submit_failed`)).toEqual([]);
    // Порт корзины для заказа сотрудника — прежний итог (та же восстановленная корзина при повторе).
    const again = await t.db.transaction((tx) =>
      cart.restoreFromOrder(tx, { orderId: o.orderId, ownerUserId: seller.userId }),
    );
    expect(again.cartId).not.toBeNull();
    expect(['active', 'parked']).toContain(again.status);
  });

  it('KIOSK-030 cart jobs: kiosk-owned cart gets flags but no cart_price_changed notification', async () => {
    const tab = await resetTablet();
    const x = v[2];
    for (const who of [tab, seller]) {
      const c0 = await call('get', '/cart', who);
      const put = await call('put', `/cart/items/${x.variantId}`, who, {
        quantity: { value: '1', unitId: x.unitId, packagingId: null },
        rowVersion: c0.body.rowVersion as number,
      });
      expect(put.status, JSON.stringify(put.body)).toBe(200);
    }
    await t.setPrice(x.variantId, '125.00');
    const jobs = t.app.get(CartJobsHandler, { strict: false });
    const r = await jobs.catalogChanged('prices', { variantIds: [x.variantId] });
    expect(r.carts).toBeGreaterThanOrEqual(2);
    const kinds = async (userId: string) =>
      (
        await t.q<{ kind: string }>(
          `SELECT kind::text AS kind FROM notifications WHERE user_id = $1 AND kind::text = $2`,
          [userId, 'cart_price_changed'],
        )
      ).length;
    expect(await kinds(tab.userId)).toBe(0);
    expect(await kinds(seller.userId)).toBe(1);
    // Пометка строки корзины планшета ставится, как у всех (предупреждение корзины, 10 CART-013).
    const flags = await t.q<{ price_changed: boolean }>(
      `SELECT i.price_changed FROM cart_items i JOIN carts c ON c.id = i.cart_id
        WHERE c.owner_user_id = $1 AND c.status = 'active' AND i.variant_id = $2`,
      [tab.userId, x.variantId],
    );
    expect(flags).toEqual([{ price_changed: true }]);
  });
});

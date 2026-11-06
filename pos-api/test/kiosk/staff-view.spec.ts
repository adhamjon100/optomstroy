import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { OTP_PROVIDER, type OtpProvider } from '../../src/auth/otp/otp.provider.js';
import { CartModule } from '../../src/cart/cart.module.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import { NotificationCenterModule } from '../../src/notifications/center/notification-center.module.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { PaymentsModule } from '../../src/payments/payments.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import { apiErrors } from '../customers/support/customers-app.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { type KioskTablet, KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Заявка с планшета у персонала и на кассе (08 §3.9, §3.13, §4.8.2, §4.8.4, §4.10.1; 10 KIOSK-018, KIOSK-019,
 * KIOSK-030, KIOSK-034; P-002 §8.7; ADR-115; задачи TAB-1-06, TAB-1-08) — **тестовые данные** стенда `kiosk-fixture`
 * (embedded PostgreSQL 17 со всеми миграциями, синтетический каталог, `ScriptedOnecGateway`; номера покупателей —
 * вымышленные `+996 555 006 xxx`, номера сотрудников стенда — `+996 77x xxx xxx`; коды из SMS — из `dev_outbox`
 * поддельного шлюза). Заявка создаётся настоящим `POST /kiosk/orders` (WP-S4C); стенд — модули корзины, заказов,
 * платежей (`QR_PROVIDER=none` — статический QR), центра уведомлений, профиля, публичных настроек и `kiosk`.
 * - T-KIOSK-026: уведомление `kiosk_order` у `cashier` и `senior_seller` (не у планшета и не у продавца); фильтр
 *   `GET /orders?createdVia=kiosk`; продавец (`order.read.own`) заявку не видит; `createdVia`/`kioskCustomerMatch` в
 *   `Order`, `OrderSummary` и `awaitingPayment[]`; покупателю `kioskCustomerMatch` не отдаётся;
 * - T-KIOSK-027: касса — поиск по номеру, приём наличных, смена на QR, отмена со step-up `order.cancel.request.any`;
 * - T-KIOSK-039 (cancel_now): немедленная отмена кассиром — корзина планшета не восстанавливается, автору
 *   уведомлений нет, ролям кассы — есть; заказ сотрудника — как прежде (корзина и уведомление автору);
 * - T-KIOSK-055: неоплаченная заявка — в «Ожидают оплаты» только в свой день, далее — по фильтру; отмена со step-up.
 */
type Method = 'get' | 'post' | 'put' | 'delete';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
}

interface KioskOrder {
  readonly tab: KioskTablet;
  readonly phone: string;
  readonly id: string;
  readonly publicNumber: string;
  readonly cartId: string;
}

const NOTICE = '2026-11-04';
const DEV_OUTBOX_SQL = fileURLToPath(new URL('../../db/migrations-dev/0001_dev_outbox.sql', import.meta.url));
const CANCEL = { reason: 'Покупатель не пришёл на кассу (тест)', reasonCode: 'customer_refused' } as const;

let phoneSeq = 0;
/** Вымышленный мобильный номер КР `+996 555 006 xxx` (тестовые данные). */
function buyerPhone(): string {
  phoneSeq += 1;
  return `+996555006${String(100 + phoneSeq).padStart(3, '0')}`;
}

/** Дата Asia/Bishkek (UTC+6) момента `d` — `YYYY-MM-DD` (как `GET /pos/dashboard?date=`). */
function bishkekDate(d: Date, plusDays = 0): string {
  return new Date(d.getTime() + 6 * 3_600_000 + plusDays * 86_400_000).toISOString().slice(0, 10);
}

describe('kiosk: заявка с планшета у персонала и на кассе (KIOSK_MODE=true)', () => {
  const t = new KioskTestApp();
  let v: SaleableVariant[];
  let w1: string;
  let cashier: PosActor;
  let senior: PosActor;
  let seller: PosActor;
  let admin: PosActor;

  async function call(
    method: Method,
    path: string,
    a?: PosActor,
    body?: unknown,
    opts: { readonly idem?: string | true; readonly stepUp?: string } = {},
  ): Promise<Res> {
    const r = t.req(method, path, a, opts);
    const res = await (body !== undefined ? r.send(body as object) : r);
    return { status: res.status, body: (res.body ?? {}) as Res['body'] };
  }

  async function putItem(tab: PosActor, x: SaleableVariant, value: string): Promise<void> {
    const c0 = await call('get', '/cart', tab);
    const r = await call('put', `/cart/items/${x.variantId}`, tab, {
      quantity: { value, unitId: x.unitId, packagingId: null },
      rowVersion: c0.body.rowVersion as number,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
  }

  /** Код из SMS (`dev_outbox` поддельного шлюза) — после фоновой отправки. */
  async function codeOf(challengeId: string): Promise<string> {
    await t.app.get<OtpProvider>(OTP_PROVIDER, { strict: false }).drain();
    const r = await t.q<{ text: string }>(
      `SELECT d.text FROM dev_outbox d JOIN otp_challenges c ON c.sms_outbox_id = d.sms_outbox_id WHERE c.id = $1`,
      [challengeId],
    );
    const m = /(\d{6})/.exec(r[0]?.text ?? '');
    if (!m?.[1]) throw new Error(`код для ${challengeId} не найден в dev_outbox`);
    return m[1];
  }

  /**
   * `dev_outbox` (07 §5.63) — только в dev/test-схеме: dev-миграция применяется к БД стенда в сеансе с
   * `app.env=test` (как test/kiosk/orders.spec.ts; файл миграции не меняется). Без неё FakeSmsGateway — CONFIG_ERROR.
   */
  async function createDevOutbox(): Promise<void> {
    const c = await t.pool.connect();
    try {
      await c.query(`SELECT set_config('app.env', 'test', false)`);
      await c.query(readFileSync(DEV_OUTBOX_SQL, 'utf8'));
    } finally {
      await c.query('RESET app.env').catch(() => undefined);
      c.release();
    }
  }

  /** Заявка с планшета настоящим потоком SCR-51 → SCR-52 (08 §4.25.1, §4.7.7, §4.25.2): корзина, код, предпросмотр. */
  async function kioskOrder(o: { readonly phone?: string; readonly tab?: KioskTablet } = {}): Promise<KioskOrder> {
    const tab = o.tab ?? (await t.tablet({ warehouseId: w1 }));
    await putItem(tab, v[0], '1');
    const phone = o.phone ?? buyerPhone();
    const c = await call('get', '/cart', tab);
    const otp = await call('post', '/kiosk/order-otp', tab, {
      phone,
      cartId: c.body.id as string,
      noticeVersion: NOTICE,
    });
    expect(otp.status, JSON.stringify(otp.body)).toBe(202);
    const challengeId = otp.body.challengeId as string;
    const code = await codeOf(challengeId);
    const c2 = await call('get', '/cart', tab);
    const p = await call('post', '/cart/checkout-preview', tab, {
      cartId: c2.body.id as string,
      cartRowVersion: c2.body.rowVersion as number,
      paymentMethod: 'cash',
      delivery: { method: 'pickup' },
      receiver: { kind: 'customer' },
      manualDiscountPercent: '0.00',
      syncCheckWithOnec: false,
    });
    expect(p.status, JSON.stringify(p.body)).toBe(200);
    const r = await call(
      'post',
      '/kiosk/orders',
      tab,
      {
        challengeId,
        code,
        cartId: p.body.cartId as string,
        cartRowVersion: p.body.cartRowVersion as number,
        previewToken: p.body.previewToken as string,
      },
      { idem: randomUUID() },
    );
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const publicNumber = r.body.publicNumber as string;
    const row = await t.q<{ id: string }>(`SELECT id FROM orders WHERE public_number = $1`, [publicNumber]);
    return { tab, phone, id: row[0].id, publicNumber, cartId: p.body.cartId as string };
  }

  /** Автосброс планшета после SCR-53 (`POST /kiosk/reset`, FLOW-045): новая пустая активная корзина. */
  async function resetTablet(k: KioskOrder): Promise<void> {
    const r = await call('post', '/kiosk/reset', k.tab, { cartId: k.cartId });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.items).toEqual([]);
  }

  /** Карточка клиента из полной синхронизации 1С (`source=onec`), номер — основной (как test/kiosk/orders.spec.ts). */
  async function card(phone: string, name: string): Promise<string> {
    const r = await t.q<{ id: string }>(
      `INSERT INTO customers (onec_ref, onec_code, source, name, customer_type, primary_phone_e164, phones_norm,
                              synced_at, source_hash, onec_status)
       VALUES ($1::uuid, $2, 'onec', $3, 'individual', $4, ARRAY[$4::text], now(), 'test', 'n_a')
       RETURNING id`,
      [randomUUID(), `T-${randomUUID().slice(0, 8)}`, name, phone],
    );
    return r[0].id;
  }

  async function phoneOf(a: PosActor): Promise<string> {
    return (await t.q<{ p: string }>(`SELECT phone_e164 AS p FROM users WHERE id = $1`, [a.userId]))[0].p;
  }

  /** Уведомления заказа по ключу дедупликации: адресаты (id пользователей) и вид. */
  async function notified(dedupeKey: string): Promise<{ user_id: string; kind: string; body_ru: string }[]> {
    return t.q(
      `SELECT user_id::text AS user_id, kind::text AS kind, body_ru FROM notifications WHERE dedupe_key = $1`,
      [dedupeKey],
    );
  }

  /** Все уведомления пользователя (по любому ключу) о заказе `orderId`. */
  async function notificationsOf(userId: string, orderId: string): Promise<{ kind: string; dedupe_key: string }[]> {
    return t.q(
      `SELECT kind::text AS kind, dedupe_key FROM notifications WHERE user_id = $1 AND payload ->> 'orderId' = $2`,
      [userId, orderId],
    );
  }

  /** Корзины технического пользователя планшета: восстановленных и отложенных нет, активная — пустая. */
  async function expectTabletCartsUntouched(tab: KioskTablet): Promise<void> {
    const restored = await t.q<{ n: number }>(
      `SELECT count(*)::int AS n FROM carts WHERE owner_user_id = $1 AND restored_from_order_id IS NOT NULL`,
      [tab.userId],
    );
    expect(restored[0].n).toBe(0);
    const parked = await t.q<{ n: number }>(
      `SELECT count(*)::int AS n FROM carts WHERE owner_user_id = $1 AND status = 'parked'`,
      [tab.userId],
    );
    expect(parked[0].n).toBe(0);
    const cart = await call('get', '/cart', tab);
    expect(cart.status).toBe(200);
    expect(cart.body.items).toEqual([]);
    expect(cart.body.restoredFromOrder ?? null).toBeNull();
    expect(cart.body.restoredFromOrderId ?? null).toBeNull();
  }

  function ids(list: Res): string[] {
    return (list.body.items as { id: string }[]).map((i) => i.id);
  }

  beforeAll(async () => {
    await t.start({
      env: {
        QR_PROVIDER: 'none',
        KIOSK_MODE: 'true',
        OTP_GLOBAL_PER_MIN: '100000',
        ONEC_SYNC_CHECK_TIMEOUT_MS: '1500',
      },
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
    await createDevOutbox();
    w1 = await t.defaultWarehouseId();
    v = await t.saleableVariants(4, { warehouseId: w1 });
    for (const x of v) await t.setPrice(x.variantId, '100.00');
    cashier = await t.actor({ role: 'cashier' });
    senior = await t.actor({ role: 'senior_seller' });
    seller = await t.actor({ role: 'seller' });
    admin = await t.actor({ role: 'admin' });
  });

  afterAll(async () => {
    await t.stop();
  });

  beforeEach(() => {
    t.onec.reset();
    t.onec.useFixture('findCustomersByPhone', 'customers-search.empty.200');
  });

  it('T-KIOSK-026 notifications cashier+senior_seller, filter, seller does not see', async () => {
    const k = await kioskOrder();
    const staff = await t.seedOrder({ createdBy: seller, method: 'cash' });

    // Уведомление kiosk_order (08 §3.13): кассиру и старшему продавцу; не планшету, не продавцу; без телефона.
    const n = await notified(`kiosk_order:${k.id}`);
    const to = n.map((x) => x.user_id);
    expect(to).toEqual(expect.arrayContaining([cashier.userId, senior.userId]));
    expect(to).not.toContain(k.tab.userId);
    expect(to).not.toContain(seller.userId);
    expect(to).not.toContain(admin.userId);
    expect(n.every((x) => x.kind === 'kiosk_order' && !x.body_ru.includes(k.phone.slice(4)))).toBe(true);
    const feed = await call('get', '/notifications', cashier);
    expect(feed.status, JSON.stringify(feed.body)).toBe(200);
    const mine = (feed.body.items as { kind: string; title: string; payload: { orderId?: string } }[]).find(
      (x) => x.payload?.orderId === k.id,
    );
    expect(mine).toMatchObject({ kind: 'kiosk_order', title: `Новая заявка с планшета № ${k.publicNumber}` });
    expect(await notificationsOf(k.tab.userId, k.id)).toEqual([]);

    // Фильтр «С планшета» (08 §4.8.2): только заявки с планшета; staff — без них; одно значение перечня.
    const kioskList = await call('get', '/orders?createdVia=kiosk&limit=200', cashier);
    expect(kioskList.status, JSON.stringify(kioskList.body)).toBe(200);
    expect(ids(kioskList)).toContain(k.id);
    expect(ids(kioskList)).not.toContain(staff.orderId);
    for (const it of kioskList.body.items as { createdVia: string; kioskCustomerMatch: string | null }[]) {
      expect(it.createdVia).toBe('kiosk');
      expect(['single', 'ambiguous', 'none']).toContain(it.kioskCustomerMatch);
    }
    const summary = (kioskList.body.items as { id: string }[]).find((i) => i.id === k.id) as Record<string, unknown>;
    expect(summary).toMatchObject({ createdVia: 'kiosk', kioskCustomerMatch: 'none' });
    expect(apiErrors('Receiver', summary.receiver)).toEqual([]);
    const staffList = await call('get', '/orders?createdVia=staff&limit=200', cashier);
    expect(ids(staffList)).toContain(staff.orderId);
    expect(ids(staffList)).not.toContain(k.id);
    const all = await call('get', '/orders?limit=200', cashier);
    const staffItem = (all.body.items as { id: string }[]).find((i) => i.id === staff.orderId);
    expect(staffItem).toMatchObject({ createdVia: 'staff', kioskCustomerMatch: null });
    for (const bad of ['createdVia=tablet', 'createdVia=kiosk&createdVia=staff', 'createdVia=KIOSK']) {
      const r = await call('get', `/orders?${bad}`, cashier);
      expect(r.status, bad).toBe(400);
      expect(r.body).toMatchObject({ code: 'VALIDATION_FAILED', errors: [{ field: 'createdVia', rule: 'enum' }] });
    }

    // Р-12 (а): держатели order.read.all видят, продавец (order.read.own) — нет.
    for (const a of [cashier, senior, admin]) {
      const one = await call('get', `/orders/${k.id}`, a);
      expect(one.status, `${a.role}: ${JSON.stringify(one.body)}`).toBe(200);
    }
    expect(ids(await call('get', '/orders?limit=200', seller))).not.toContain(k.id);
    expect(ids(await call('get', '/orders?createdVia=kiosk', seller))).toEqual([]);
    expect((await call('get', `/orders/${k.id}`, seller)).status).toBe(404);

    // DTO заказа для кассира (08 §3.9): канал, подсказка, получатель — номер кода, без маски до срока хранения.
    const dto = await call('get', `/orders/${k.id}`, cashier);
    expect(dto.body).toMatchObject({
      createdVia: 'kiosk',
      kioskCustomerMatch: 'none',
      paymentMethod: 'cash',
      receiver: { kind: 'customer', name: null, phone: k.phone },
    });
    expect(dto.body.receiver).not.toHaveProperty('phoneMasked');
    expect(apiErrors('Receiver', dto.body.receiver)).toEqual([]);
    expect(apiErrors('KioskCustomerMatch', dto.body.kioskCustomerMatch)).toEqual([]);
    expect(apiErrors('OrderCreatedVia', dto.body.createdVia)).toEqual([]);

    // SCR-30 «Ожидают оплаты» (08 §4.10.1): элемент несёт createdVia; заказ сотрудника — staff.
    const dash = await call('get', '/pos/dashboard', cashier);
    expect(dash.status, JSON.stringify(dash.body)).toBe(200);
    const awaiting = dash.body.awaitingPayment as { id: string; createdVia: string }[];
    expect(awaiting.find((x) => x.id === k.id)).toMatchObject({ createdVia: 'kiosk' });
    expect(awaiting.find((x) => x.id === staff.orderId)).toMatchObject({ createdVia: 'staff' });

    // Покупатель (режим клиента): заявка на его подтверждённую карточку видна, но без kioskCustomerMatch.
    const customer1 = await t.actor({ role: 'customer' });
    const custPhone = await phoneOf(customer1);
    const cardId = await card(custPhone, 'Покупатель с привязкой (тест 026)');
    await t.q(
      `INSERT INTO customer_links (user_id, customer_id, status, match_method, matched_phone_e164, confirmed_at)
       VALUES ($1::uuid, $2::uuid, 'confirmed', 'phone', $3, now())`,
      [customer1.userId, cardId, custPhone],
    );
    const onCard = await kioskOrder({ phone: custPhone });
    expect((await call('get', `/orders/${onCard.id}`, cashier)).body).toMatchObject({ kioskCustomerMatch: 'single' });
    const own = await call('get', `/orders/${onCard.id}`, customer1);
    expect(own.status, JSON.stringify(own.body)).toBe(200);
    expect(own.body.createdVia).toBe('kiosk');
    expect(own.body).not.toHaveProperty('kioskCustomerMatch');
    const ownList = await call('get', '/orders', customer1);
    const ownItem = (ownList.body.items as { id: string }[]).find((i) => i.id === onCard.id);
    expect(ownItem).toBeDefined();
    expect(ownItem).not.toHaveProperty('kioskCustomerMatch');
  });

  it('T-KIOSK-027 search by number, cash, QR switch, cancel with step-up order.cancel.request.any', async () => {
    // Поиск по номеру (`q`) и приём наличных (PAY-010) — как для любого заказа: открытый `cash_pending` заявки → 200.
    const a = await kioskOrder();
    const found = await call('get', `/orders?q=${encodeURIComponent(a.publicNumber)}`, cashier);
    expect(found.status).toBe(200);
    expect(ids(found)).toEqual([a.id]);
    const total = (await call('get', `/orders/${a.id}`, cashier)).body.totalToPay as { amount: string };
    const cash = await call(
      'post',
      `/orders/${a.id}/payments`,
      cashier,
      { method: 'cash', receivedAmount: { amount: total.amount, currency: 'KGS' } },
      { idem: true },
    );
    expect(cash.status, JSON.stringify(cash.body)).toBe(200);
    expect(cash.body).toMatchObject({ method: 'cash', status: 'received' });
    expect((await call('get', `/orders/${a.id}`, cashier)).body).toMatchObject({ isPaid: true, createdVia: 'kiosk' });

    // Смена наличных на QR (PAY-052): прежний платёж — voided method_changed, новый — QR.
    const b = await kioskOrder();
    const [cashPending] = await t.q<{ id: string }>(
      `SELECT id FROM payments WHERE order_id = $1 AND status = 'cash_pending'`,
      [b.id],
    );
    const qr = await call('post', `/orders/${b.id}/payments`, cashier, { method: 'qr_bakai' }, { idem: true });
    expect(qr.status, JSON.stringify(qr.body)).toBe(201);
    expect(qr.body).toMatchObject({ method: 'qr_bakai', status: 'qr_shown' });
    expect(
      (
        await t.q<{ status: string; void_reason: string }>(
          `SELECT status::text AS status, void_reason FROM payments WHERE id = $1`,
          [cashPending.id],
        )
      )[0],
    ).toEqual({ status: 'voided', void_reason: 'method_changed' });

    // Отмена кассиром: чужой заказ — order.cancel.request.any со step-up (08 §4.8.4; ORD-050 (б)).
    const noStepUp = await call('post', `/orders/${b.id}/cancel`, cashier, CANCEL, { idem: true });
    expect(noStepUp.status, JSON.stringify(noStepUp.body)).toBe(403);
    expect(noStepUp.body.code).toBe('STEP_UP_REQUIRED');
    const stepUp = await t.stepUp(cashier, 'order.cancel.request.any');
    const cancelled = await call('post', `/orders/${b.id}/cancel`, cashier, CANCEL, { idem: true, stepUp });
    expect(cancelled.status, JSON.stringify(cancelled.body)).toBe(200);
    expect(cancelled.body).toMatchObject({ status: 'cancelled', createdVia: 'kiosk' });
    const audit = await t.auditRows('order.cancelled', b.id);
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({ step_up_method: 'pin' });
    expect(
      (await t.q<{ status: string }>(`SELECT status::text AS status FROM payments WHERE id = $1`, [qr.body.id]))[0]
        .status,
    ).toBe('voided');
  });

  it('T-KIOSK-039 cancel_now', async () => {
    const k = await kioskOrder();
    await resetTablet(k);
    const stepUp = await t.stepUp(cashier, 'order.cancel.request.any');
    const r = await call('post', `/orders/${k.id}/cancel`, cashier, CANCEL, { idem: true, stepUp });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.status).toBe('cancelled');
    // Немедленная отмена (outbox create ещё pending): статус сразу cancelled, право — чужой заказ (`via: any`).
    expect(await t.auditRows('order.cancelled', k.id)).toEqual([
      expect.objectContaining({
        step_up_method: 'pin',
        after: expect.objectContaining({ status: 'cancelled', via: 'any' }),
      }),
    ]);
    expect(
      (
        await t.q<{ status: string }>(
          `SELECT status::text AS status FROM onec_outbox WHERE aggregate_id = $1 AND operation = 'create'`,
          [k.id],
        )
      )[0].status,
    ).toBe('cancelled');

    // Корзина планшета не восстанавливается (KIOSK-030): ни активной, ни отложенной; номера чужой заявки нет.
    await expectTabletCartsUntouched(k.tab);
    // Уведомления: техническому пользователю — нет; кассиру и старшему продавцу — «отменена» (08 §3.13, §4.8.4).
    expect(await notificationsOf(k.tab.userId, k.id)).toEqual([]);
    const n = await notified(`kiosk_order_status:${k.id}:cancelled`);
    expect(n.map((x) => x.user_id)).toEqual(expect.arrayContaining([cashier.userId, senior.userId]));
    expect(n.map((x) => x.user_id)).not.toContain(k.tab.userId);
    expect(n.map((x) => x.user_id)).not.toContain(seller.userId);
    expect(n.every((x) => x.kind === 'order_status' && !x.body_ru.includes(k.phone.slice(4)))).toBe(true);

    // Паритет: заказ сотрудника, отменённый кассиром, — состав в корзину автора и уведомление автору, как прежде.
    const own = await t.seedOrder({ createdBy: seller, method: 'cash' });
    const stepUp2 = await t.stepUp(cashier, 'order.cancel.request.any');
    const r2 = await call('post', `/orders/${own.orderId}/cancel`, cashier, CANCEL, { idem: true, stepUp: stepUp2 });
    expect(r2.status, JSON.stringify(r2.body)).toBe(200);
    expect(r2.body.status).toBe('cancelled');
    const restored = await t.q<{ status: string }>(
      `SELECT status::text AS status FROM carts WHERE owner_user_id = $1 AND restored_from_order_id = $2`,
      [seller.userId, own.orderId],
    );
    expect(restored).toHaveLength(1);
    expect((await notified(`order_status:${own.orderId}:cancelled`)).map((x) => x.user_id)).toEqual([seller.userId]);
    expect(await notified(`kiosk_order_status:${own.orderId}:cancelled`)).toEqual([]);
  });

  it("T-KIOSK-055 Р-18 (а) unpaid order in today's feed, next day only via filter, cancel with step-up", async () => {
    const k = await kioskOrder();
    await resetTablet(k);
    const [row] = await t.q<{ created_at: Date }>(`SELECT created_at FROM orders WHERE id = $1`, [k.id]);
    const today = bishkekDate(new Date(row.created_at));
    const tomorrow = bishkekDate(new Date(row.created_at), 1);

    // Конец дня: заявка — в «Ожидают оплаты» дня (заказы дня с cash_pending склада кассира).
    const day = await call('get', `/pos/dashboard?date=${today}`, cashier);
    expect(day.status, JSON.stringify(day.body)).toBe(200);
    expect((day.body.awaitingPayment as { id: string }[]).map((x) => x.id)).toContain(k.id);
    // Следующий день: в блоке её нет, в SCR-25 — по фильтру «С планшета»; автоотмены нет (Р-18 (б) не вводится).
    const next = await call('get', `/pos/dashboard?date=${tomorrow}`, senior);
    expect(next.status, JSON.stringify(next.body)).toBe(200);
    expect((next.body.awaitingPayment as { id: string }[]).map((x) => x.id)).not.toContain(k.id);
    const filtered = await call('get', '/orders?createdVia=kiosk&limit=200', senior);
    const item = (filtered.body.items as { id: string; status: string; isPaid: boolean }[]).find((x) => x.id === k.id);
    expect(item).toMatchObject({ isPaid: false });
    expect(item?.status).not.toBe('cancelled');
    const settings = await t.q<{ n: number }>(
      `SELECT count(*)::int AS n FROM app_settings WHERE key = 'kiosk_autocancel_time'`,
    );
    expect(settings[0].n).toBe(0);

    // Утром отменяет старший продавец — для него это чужой заказ: step-up order.cancel.request.any.
    const denied = await call('post', `/orders/${k.id}/cancel`, senior, CANCEL, { idem: true });
    expect(denied.status).toBe(403);
    expect(denied.body.code).toBe('STEP_UP_REQUIRED');
    const stepUp = await t.stepUp(senior, 'order.cancel.request.any');
    const r = await call('post', `/orders/${k.id}/cancel`, senior, CANCEL, { idem: true, stepUp });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.status).toBe('cancelled');
    await expectTabletCartsUntouched(k.tab);
    expect(await notificationsOf(k.tab.userId, k.id)).toEqual([]);
    // После отмены заявка вне «Ожидают оплаты» и в своём дне.
    const after = await call('get', `/pos/dashboard?date=${today}`, cashier);
    expect((after.body.awaitingPayment as { id: string }[]).map((x) => x.id)).not.toContain(k.id);
  });
});

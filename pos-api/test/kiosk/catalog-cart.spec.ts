import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { OTP_PROVIDER, type OtpProvider } from '../../src/auth/otp/otp.provider.js';
import { CartActorResolver } from '../../src/cart/cart-actor.js';
import { CartService } from '../../src/cart/cart.service.js';
import { CatalogViewerService } from '../../src/catalog/common/catalog-viewer.js';
import type { AuditContext } from '../../src/common/audit/audit-context.js';
import { DRIZZLE, PG_POOL } from '../../src/common/db/database.module.js';
import { PermissionCatalog } from '../../src/common/rbac/permission-catalog.js';
import { SettingsReader } from '../../src/common/settings/settings-reader.js';
import { NOTICE_CATALOG } from '../../src/kiosk/otp/notice-catalog.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { type KioskTablet, KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Каталог и корзина планшета магазина (P-002 §8.3–§8.4; 06 ARCH-065, ARCH-067; 08 §3.6 «Цены и остатки для планшета»,
 * §4.7, §4.25; 10 KIOSK-005…KIOSK-007, KIOSK-009; 11 SEC-137 (6); ADR-115 п. 2, п. 23) — **тестовые данные** стенда
 * `kiosk-fixture` (embedded PostgreSQL 17, синтетический каталог; номер карточки — тестовый `+996 555 000 xxx`; код
 * из SMS — из `dev_outbox` поддельного шлюза):
 * - T-KIOSK-006 (сервер): `priceListId`, `warehouseId` (в том числе свой склад), ручная скидка предпросмотра, выбор
 *   клиента, отложенные корзины, смена склада, `POST /orders` — `403`; предпросмотр — `200` с `previewToken`; склад
 *   каталога и корзины — склад планшета W1; `stockDisplay ≠ full`; карточка товара не пишет `recent_products`;
 * - T-KIOSK-008: цена — обычная (`is_default`, без него — розничная) и до, и после кода и заявки на номер карточки с
 *   соглашением (`POST /kiosk/order-otp` → `POST /kiosk/orders`; заявка — по виду цены карточки, KIOSK-015);
 *   `priceListId` — `403`;
 * - T-KIOSK-009 (сервер): наличие по `customer_stock_display` (`status` — без количеств) и только по складу W1;
 *   склад не задан или неактивен — `403 kiosk_warehouse_unavailable`;
 * - T-KIOSK-040: `KIOSK_MODE=true` при `CUSTOMER_SELF_SERVICE=false` — каталог, корзина и заявка планшета
 *   (`POST /kiosk/order-otp` → `POST /kiosk/orders`, `created_via=kiosk`) работают, покупатель — «Режим клиента
 *   выключен»; заявку при флаге по умолчанию (`CUSTOMER_SELF_SERVICE=true`) проверяет `test/kiosk/orders.spec.ts`;
 * - T-KIOSK-042 (сервер): `Cart` планшета — `customer = null`, без ручной скидки, склад W1; выбор клиента, смена
 *   склада, отложенные корзины — `403` и guard-ом, и сервисом корзины (отказ по умолчанию ниже guard-а);
 * - паритет: сотрудник и покупатель режима клиента — как прежде (склад параметром, все склады, «Недавние»).
 */
type Method = 'get' | 'post' | 'put' | 'patch' | 'delete';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
}

async function call(
  t: KioskTestApp,
  method: Method,
  path: string,
  a?: Pick<PosActor, 'token' | 'deviceKey'>,
  body?: object,
): Promise<Res> {
  const r = t.req(method, path, a);
  const res = await (body !== undefined ? r.send(body) : method === 'get' || method === 'delete' ? r : r.send({}));
  return { status: res.status, body: (res.body ?? {}) as Res['body'] };
}

const label = (method: string, path: string, r: Res) =>
  `${method.toUpperCase()} ${path} → ${r.status} ${r.body.code ?? ''}${r.body.reason ? `/${r.body.reason}` : ''}`;

const isForbidden = (r: Res) => r.status === 403 && r.body.code === 'FORBIDDEN';

/** Поля количеств `StockBalance` (08 §3.6): при `customer_stock_display=status` их нет совсем. */
const QTY_FIELDS = ['quantity', 'reserved', 'available'] as const;

const AUDIT_CTX: AuditContext = { actorUserId: null, actorRole: null, requestId: null };

async function putItem(t: KioskTestApp, a: PosActor, v: SaleableVariant, value = '1'): Promise<Res> {
  const c0 = await call(t, 'get', '/cart', a);
  return call(t, 'put', `/cart/items/${v.variantId}`, a, {
    quantity: { value, unitId: v.unitId, packagingId: null },
    rowVersion: c0.body.rowVersion as number,
  });
}

async function previewBody(t: KioskTestApp, a: PosActor, extra: object = {}): Promise<object> {
  const c = await call(t, 'get', '/cart', a);
  return {
    cartId: c.body.id as string,
    cartRowVersion: c.body.rowVersion as number,
    paymentMethod: 'cash',
    delivery: { method: 'pickup' },
    receiver: { kind: 'customer' },
    ...extra,
  };
}

async function recentCount(t: KioskTestApp, userId: string): Promise<number> {
  const r = await t.q<{ n: string }>(`SELECT count(*)::text AS n FROM recent_products WHERE user_id = $1`, [userId]);
  return Number(r[0]?.n ?? '0');
}

const DEV_OUTBOX_SQL = fileURLToPath(new URL('../../db/migrations-dev/0001_dev_outbox.sql', import.meta.url));

/**
 * `dev_outbox` (07 §5.63) — только в dev/test-схеме: dev-миграция применяется к БД стенда в сеансе с `app.env=test`
 * (как test/kiosk/order-otp.spec.ts, orders.spec.ts; файл миграции не меняется). Без неё FakeSmsGateway — CONFIG_ERROR.
 */
async function createDevOutbox(t: KioskTestApp): Promise<void> {
  const c = await t.pool.connect();
  try {
    await c.query(`SELECT set_config('app.env', 'test', false)`);
    await c.query(readFileSync(DEV_OUTBOX_SQL, 'utf8'));
  } finally {
    await c.query('RESET app.env').catch(() => undefined);
    c.release();
  }
}

/** Код из SMS (`dev_outbox` поддельного шлюза) — после фоновой отправки. */
async function codeOf(t: KioskTestApp, challengeId: string): Promise<string> {
  await t.app.get<OtpProvider>(OTP_PROVIDER, { strict: false }).drain();
  const r = await t.q<{ text: string }>(
    `SELECT d.text FROM dev_outbox d JOIN otp_challenges c ON c.sms_outbox_id = d.sms_outbox_id WHERE c.id = $1`,
    [challengeId],
  );
  const m = /(\d{6})/.exec(r[0]?.text ?? '');
  if (!m?.[1]) throw new Error(`код для ${challengeId} не найден в dev_outbox`);
  return m[1];
}

/** Отметка «Недавних» пишется в фоне после ответа (RecentViewInterceptor): ждём её не дольше `ms`. */
async function waitRecent(t: KioskTestApp, userId: string, ms = 3000): Promise<number> {
  const until = Date.now() + ms;
  let n = await recentCount(t, userId);
  while (n === 0 && Date.now() < until) {
    await new Promise((r) => setTimeout(r, 50));
    n = await recentCount(t, userId);
  }
  return n;
}

describe('kiosk: каталог и корзина планшета — ветка покупателя без привязки, склад планшета (KIOSK_MODE=true)', () => {
  const t = new KioskTestApp();
  let tab: KioskTablet;
  let seller: PosActor;
  let customer: PosActor;
  let v: SaleableVariant[];
  let w1: string;
  let w2: string;
  let defaultPl: string;

  beforeAll(async () => {
    await t.startKiosk({ kioskMode: true });
    await createDevOutbox(t);
    w1 = await t.defaultWarehouseId();
    defaultPl = await t.defaultPriceListId();
    const ins = await t.q<{ id: string }>(
      `INSERT INTO warehouses (synced_at, source_hash, name, sort_order) VALUES (now(), 'kiosk-test', 'Склад стенда W2', 99)
       RETURNING id`,
    );
    w2 = ins[0].id;
    tab = await t.tablet({ name: 'Планшет у входа', warehouseId: w1 });
    seller = await t.actor({ role: 'seller' });
    customer = await t.actor({ role: 'customer' });
    v = await t.saleableVariants(4, { warehouseId: w1 });
    for (const x of v) await t.setStock(x.variantId, '37', w2);
  });
  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-006 forbidden params and routes, preview 200, warehouse, stockDisplay, no recent_products', async () => {
    const problems: string[] = [];
    const expect403 = async (method: Method, path: string, body?: object) => {
      const r = await call(t, method, path, tab, body);
      if (!isForbidden(r)) problems.push(label(method, path, r));
    };
    const pl = await t.q<{ id: string }>(`SELECT id FROM price_lists WHERE NOT deletion_mark AND id <> $1 LIMIT 1`, [
      defaultPl,
    ]);
    const other = pl[0]?.id ?? defaultPl;
    const q = encodeURIComponent(v[0].productName.slice(0, 4));
    // Параметры вида цены и склада (KIOSK-006, KIOSK-007): 403, в том числе свой склад W1 параметром.
    await expect403('get', `/catalog/products?priceListId=${other}`);
    await expect403('get', `/catalog/products?priceListId=${defaultPl}`);
    await expect403('get', `/catalog/products?warehouseId=${w2}`);
    await expect403('get', `/catalog/products?warehouseId=${w1}`);
    await expect403('get', `/catalog/products/${v[0].productId}?warehouseId=${w2}`);
    await expect403('get', `/catalog/products/${v[0].productId}/variants?priceListId=${other}`);
    await expect403('get', `/search/products?q=${q}&warehouseId=${w2}`);
    await expect403('get', `/search/products?q=${q}&priceListId=${other}`);
    await expect403('get', `/inventory/balances?variantIds=${v[0].variantId}&warehouseId=${w2}`);
    await expect403('get', `/inventory/balances?variantIds=${v[0].variantId}&warehouseId=${w1}`);
    await expect403('get', `/catalog/sync/stock?warehouseId=${w2}`);
    await expect403('post', '/inventory/check', {
      warehouseId: w2,
      items: [{ variantId: v[0].variantId, quantity: { value: '1', unitId: v[0].unitId, packagingId: null } }],
    });
    // Справочник видов цен покупателю не отдаётся (08 AC-API-186) — как у customer.
    await expect403('get', '/catalog/price-lists');
    // Маршруты корзины и заказов вне закрытого списка.
    await expect403('post', '/cart/customer', { customerId: await t.createOnecCustomer(), rowVersion: 0 });
    await expect403('patch', '/cart', { warehouseId: w2, rowVersion: 0 });
    await expect403('get', '/cart/parked');
    await expect403('post', '/cart/park', { rowVersion: 0 });
    await expect403('post', '/orders', {});
    // Цены и итоги считает сервер: поле цены в теле корзины не принимается (как у всех ролей, 08 §4.7.2).
    const priced = await call(t, 'put', `/cart/items/${v[0].variantId}`, tab, {
      quantity: { value: '1', unitId: v[0].unitId, packagingId: null },
      rowVersion: 0,
      priceListId: other,
    });
    if (priced.status < 400 || priced.status >= 500) problems.push(label('put', '/cart/items (priceListId)', priced));
    expect(problems).toEqual([]);

    // Склад планшета: тело POST /inventory/check — W1 принимается.
    const check = await call(t, 'post', '/inventory/check', tab, {
      warehouseId: w1,
      items: [{ variantId: v[0].variantId, quantity: { value: '1', unitId: v[0].unitId, packagingId: null } }],
    });
    expect(check.status, JSON.stringify(check.body)).toBe(200);

    // Корзина: склад W1, предпросмотр — 200 с previewToken; ручная скидка в предпросмотре — 403.
    const put = await putItem(t, tab, v[1]);
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    expect(put.body).toMatchObject({ warehouseId: w1, customer: null });
    const discount = await call(
      t,
      'post',
      '/cart/checkout-preview',
      tab,
      await previewBody(t, tab, { manualDiscountPercent: '5.00' }),
    );
    expect(isForbidden(discount), label('post', '/cart/checkout-preview (discount)', discount)).toBe(true);
    const preview = await call(t, 'post', '/cart/checkout-preview', tab, await previewBody(t, tab));
    expect(preview.status, JSON.stringify(preview.body)).toBe(200);
    expect(typeof preview.body.previewToken).toBe('string');
    expect(preview.body.permissions).toMatchObject({ canCreateOrder: true, allowedPaymentMethods: ['cash'] });

    // stockDisplay ≠ full: в каталоге и корзине нет полей «остаток»/«резерв» (по умолчанию customer_stock_display=status).
    const card = await call(t, 'get', `/catalog/products/${v[0].productId}`, tab);
    expect(card.status).toBe(200);
    expect(card.body.stock).toMatchObject({ warehouseId: w1 });
    for (const f of ['quantity', 'reserved'] as const) expect(card.body.stock, f).not.toHaveProperty(f);
    const line = (put.body.items as Record<string, unknown>[]).find((i) => i.variantId === v[1].variantId);
    expect(line).toBeDefined();
    for (const f of ['available', 'remainingAvailable'] as const) expect(line, f).not.toHaveProperty(f);

    // Карточка товара не пишет «Недавние» технического пользователя; сотруднику — пишет (паритет).
    await call(t, 'get', `/catalog/products/${v[2].productId}`, tab);
    const staffCard = await call(t, 'get', `/catalog/products/${v[2].productId}`, seller);
    expect(staffCard.status).toBe(200);
    expect(await waitRecent(t, seller.userId)).toBeGreaterThan(0);
    expect(await recentCount(t, tab.userId)).toBe(0);
  });

  it('T-KIOSK-009 customer_stock_display status/quantity, tablet warehouse: остатки только склада W1, при status — без количеств', async () => {
    const shape = async (mode: 'status' | 'quantity') => {
      await t.setSetting('customer_stock_display', JSON.stringify(mode));
      const card = await call(t, 'get', `/catalog/products/${v[0].productId}`, tab);
      const variants = await call(t, 'get', `/catalog/products/${v[0].productId}/variants`, tab);
      const balances = await call(t, 'get', `/inventory/balances?variantIds=${v[0].variantId},${v[1].variantId}`, tab);
      const list = await call(t, 'get', '/catalog/products?limit=20', tab);
      const sync = await call(t, 'get', '/catalog/sync/stock?limit=200', tab);
      for (const r of [card, variants, balances, list, sync]) expect(r.status, JSON.stringify(r.body)).toBe(200);
      const stocks: Record<string, unknown>[] = [
        card.body.stock,
        ...(card.body.stockByWarehouse as Record<string, unknown>[]),
        ...(variants.body.items as Record<string, unknown>[]).flatMap((x) => [
          x.stock as Record<string, unknown>,
          ...(x.stockByWarehouse as Record<string, unknown>[]),
        ]),
        ...(balances.body.items as Record<string, unknown>[]),
        ...(list.body.items as Record<string, unknown>[])
          .map((x) => x.stock as Record<string, unknown>)
          .filter(Boolean),
        ...(sync.body.items as Record<string, unknown>[]),
      ];
      return { card, balances, stocks, sync };
    };

    const status = await shape('status');
    expect(status.stocks.length).toBeGreaterThan(5);
    // Только склад планшета W1: остатки W2 не видны нигде (ни карточка, ни варианты, ни balances, ни выгрузка).
    expect([...new Set(status.stocks.map((s) => s.warehouseId))]).toEqual([w1]);
    expect(status.card.body.stockByWarehouse).toHaveLength(1);
    expect((status.balances.body.items as unknown[]).length).toBe(2);
    // status: количеств нет ни в одном ответе (поля отсутствуют, а не null); availableTotal — нет.
    for (const s of status.stocks) for (const f of QTY_FIELDS) expect(s, f).not.toHaveProperty(f);
    expect(status.card.body).not.toHaveProperty('availableTotal');

    const quantity = await shape('quantity');
    expect([...new Set(quantity.stocks.map((s) => s.warehouseId))]).toEqual([w1]);
    // quantity: только «доступно» по W1; «остаток» и «резерв» — нет; availableTotal — только W1 (без 37 шт. склада W2).
    for (const s of quantity.stocks) {
      expect(s, 'quantity').not.toHaveProperty('quantity');
      expect(s, 'reserved').not.toHaveProperty('reserved');
    }
    const w1Available = (quantity.card.body.stock as { available?: string }).available;
    expect(w1Available).toBeDefined();
    expect(quantity.card.body.availableTotal).toBe(w1Available);

    // Паритет: сотрудник видит все склады и количества, покупатель — все склады по своему режиму.
    const staff = await call(t, 'get', `/catalog/products/${v[0].productId}`, seller);
    const staffWh = (staff.body.stockByWarehouse as { warehouseId: string; quantity?: string }[]).map(
      (s) => s.warehouseId,
    );
    expect(staffWh).toEqual(expect.arrayContaining([w1, w2]));
    expect(staff.body.stock).toHaveProperty('quantity');
    const own = await call(t, 'get', `/catalog/products/${v[0].productId}?warehouseId=${w2}`, seller);
    expect([own.status, own.body.stock?.warehouseId]).toEqual([200, w2]);
    const buyer = await call(t, 'get', `/catalog/products/${v[0].productId}`, customer);
    const buyerWh = (buyer.body.stockByWarehouse as { warehouseId: string }[]).map((s) => s.warehouseId);
    expect(buyerWh).toEqual(expect.arrayContaining([w1, w2]));
    const staffBalances = await call(t, 'get', `/inventory/balances?variantIds=${v[0].variantId}`, seller);
    expect((staffBalances.body.items as { warehouseId: string }[]).map((s) => s.warehouseId)).toEqual(
      expect.arrayContaining([w1, w2]),
    );
    await t.setSetting('customer_stock_display', JSON.stringify('status'));
  });

  it('T-KIOSK-009 склад планшета не задан или неактивен → 403 kiosk_warehouse_unavailable (каталог, корзина, наличие); запасного склада нет', async () => {
    const none = await t.tablet({ warehouseId: null });
    const inactive = await t.q<{ id: string }>(
      `INSERT INTO warehouses (synced_at, source_hash, name, is_active, sort_order)
       VALUES (now(), 'kiosk-test', 'Закрытый склад стенда', false, 98) RETURNING id`,
    );
    const closed = await t.tablet({ warehouseId: inactive[0].id });
    // Склад в settings.defaultWarehouseId профиля планшета не учитывается (ADR-115 п. 23).
    await t.q(
      `UPDATE user_profiles SET settings = jsonb_build_object('defaultWarehouseId', $2::text) WHERE user_id = $1`,
      [none.userId, w1],
    );
    const problems: string[] = [];
    for (const a of [none, closed]) {
      for (const [method, path, body] of [
        ['get', '/catalog/products'],
        ['get', `/catalog/products/${v[0].productId}`],
        ['get', `/search/products?q=${encodeURIComponent(v[0].productName.slice(0, 4))}`],
        ['get', `/inventory/balances?variantIds=${v[0].variantId}`],
        ['get', '/catalog/sync/stock'],
        ['get', '/cart'],
        [
          'put',
          `/cart/items/${v[0].variantId}`,
          { quantity: { value: '1', unitId: v[0].unitId, packagingId: null }, rowVersion: 0 },
        ],
      ] as const) {
        const r = await call(t, method, path, a, body);
        if (!(isForbidden(r) && r.body.reason === 'kiosk_warehouse_unavailable')) problems.push(label(method, path, r));
      }
    }
    expect(problems).toEqual([]);
    const carts = await t.q(`SELECT 1 FROM carts WHERE owner_user_id = ANY($1::uuid[])`, [
      [none.userId, closed.userId],
    ]);
    expect(carts).toHaveLength(0);
  });

  it('T-KIOSK-042 Cart customerId null, no manual discount, POST /cart/customer, PATCH /cart, /cart/parked* 403', async () => {
    const cart = await call(t, 'get', '/cart', tab);
    expect(cart.status).toBe(200);
    expect(cart.body).toMatchObject({
      customer: null,
      receiver: { kind: 'customer', name: null, phone: null },
      warehouseId: w1,
      priceListId: defaultPl,
    });
    expect(Number(cart.body.customerDiscountPercent ?? 0)).toBe(0);
    expect(Number(cart.body.requestedDiscountPercent)).toBe(0);
    expect(Number(cart.body.appliedDiscountPercent)).toBe(0);
    const problems: string[] = [];
    const parkedId = randomUUID();
    for (const [method, path, body] of [
      ['post', '/cart/customer', { customerId: await t.createOnecCustomer(), rowVersion: cart.body.rowVersion }],
      ['delete', '/cart/customer'],
      ['patch', '/cart', { warehouseId: w2, rowVersion: cart.body.rowVersion }],
      ['patch', '/cart', { warehouseId: w1, rowVersion: cart.body.rowVersion }],
      ['post', '/cart/discount', { percent: '1.00', rowVersion: cart.body.rowVersion }],
      ['post', '/cart/park', { rowVersion: cart.body.rowVersion }],
      ['get', '/cart/parked'],
      ['get', '/cart/parked?scope=all'],
      ['post', `/cart/parked/${parkedId}/resume`, {}],
      ['delete', `/cart/parked/${parkedId}`],
    ] as const) {
      const r = await call(t, method, path, tab, body);
      if (!isForbidden(r)) problems.push(label(method, path, r));
    }
    expect(problems).toEqual([]);
    const after = await call(t, 'get', '/cart', tab);
    expect(after.body).toMatchObject({ id: cart.body.id, customer: null, warehouseId: w1 });
  });

  it('T-KIOSK-042 сервис корзины ниже guard-а: kiosk — 403 на клиента, склад, скидку, отложенные; клиент из БД снимается', async () => {
    const actors = t.app.get(CartActorResolver);
    const carts = t.app.get(CartService);
    const a = await actors.fromPrincipal({ userId: tab.userId, kind: 'kiosk', roles: ['kiosk'], status: 'active' });
    expect(a).toMatchObject({ isCustomer: true, subjectKind: 'kiosk', stockDisplay: 'status', role: 'kiosk' });
    // Права kiosk.* засчитываются по виду (11 SEC-138): актор корзины планшета видит kiosk.order.submit.
    expect(a.permissions.has('kiosk.order.submit')).toBe(true);
    const c = await call(t, 'get', '/cart', tab);
    const rv = c.body.rowVersion as number;
    const customerId = await t.createOnecCustomer({ name: 'ООО «Карточка стенда»' });
    const stepUp = () => Promise.resolve<'pin'>('pin');
    const denied: [string, () => Promise<unknown>][] = [
      ['setCustomer', () => carts.setCustomer(a, AUDIT_CTX, { customerId, receiver: null, rowVersion: rv })],
      ['unsetCustomer', () => carts.unsetCustomer(a, AUDIT_CTX)],
      ['updateWarehouse', () => carts.updateWarehouse(a, AUDIT_CTX, w2, rv)],
      [
        'applyDiscount',
        () =>
          carts.applyDiscount(a, AUDIT_CTX, { percent: '1.00', ruleId: null, rowVersion: rv, override: null }, stepUp),
      ],
      ['park', () => carts.park(a, AUDIT_CTX, { name: null, rowVersion: rv })],
      ['listParked', () => carts.listParked(a, { scope: 'own', limit: 10, cursor: undefined })],
    ];
    for (const [name, fn] of denied) await expect(fn(), name).rejects.toMatchObject({ code: 'FORBIDDEN' });
    // Привязка клиента в строке корзины (не может появиться через API) снимается при чтении — карточка не отдаётся.
    await t.q(`UPDATE carts SET customer_id = $2 WHERE id = $1`, [c.body.id, customerId]);
    const cleared = await call(t, 'get', '/cart', tab);
    expect(cleared.body).toMatchObject({ customer: null });
    const row = await t.q<{ customer_id: string | null }>(`SELECT customer_id FROM carts WHERE id = $1`, [c.body.id]);
    expect(row[0]?.customer_id).toBeNull();
    // Паритет: сотрудник меняет склад корзины и выбирает клиента, как прежде.
    const sc = await call(t, 'get', '/cart', seller);
    const patched = await call(t, 'patch', '/cart', seller, { warehouseId: w2, rowVersion: sc.body.rowVersion });
    expect([patched.status, patched.body.warehouseId]).toEqual([200, w2]);
    const chosen = await call(t, 'post', '/cart/customer', seller, { customerId, rowVersion: patched.body.rowVersion });
    expect([chosen.status, chosen.body.customer?.id]).toEqual([200, customerId]);
  });

  it('T-KIOSK-058 PUT /cart/items и предпросмотр планшету: conflicts[] только variantId, kind, stockLevel; VERSION_CONFLICT без current; повтор ключа — то же чистое тело', async () => {
    const k = await t.tablet({ name: 'Планшет T-KIOSK-058', warehouseId: w1 });
    // Товары вне `v` (их используют другие тесты), каждый — отдельный товар (min_qty и кратность — свойства товара).
    const pool = (await t.saleableVariants(16, { warehouseId: w1 })).filter(
      (x) => !v.some((y) => y.variantId === x.variantId || y.productId === x.productId),
    );
    const picked: SaleableVariant[] = [];
    for (const x of pool) if (!picked.some((p) => p.productId === x.productId)) picked.push(x);
    const [minV, multV, unknownV, plainV] = picked;
    expect(plainV, 'нужно четыре разных товара стенда').toBeDefined();
    await t.q(`UPDATE products SET min_qty = 5 WHERE id = $1`, [minV.productId]);
    await t.q(`UPDATE products SET multiplicity = 4 WHERE id = $1`, [multV.productId]);
    const stockRow = await t.q<{ available: string }>(
      `SELECT available_onec::text AS available FROM stock_balances WHERE variant_id = $1 AND warehouse_id = $2`,
      [unknownV.variantId, w1],
    );
    await t.q(`DELETE FROM stock_balances WHERE variant_id = $1 AND warehouse_id = $2`, [unknownV.variantId, w1]);
    const allowed = new Set(['variantId', 'kind', 'stockLevel']);
    const cleanConflicts = (r: Res) => {
      const list = r.body.conflicts as Record<string, unknown>[] | undefined;
      expect(Array.isArray(list) && list.length > 0, JSON.stringify(r.body)).toBe(true);
      for (const c of list ?? []) {
        for (const key of Object.keys(c)) expect(allowed.has(key), `${String(r.body.code)}: ${key}`).toBe(true);
      }
    };
    const put = async (a: PosActor, x: SaleableVariant, value: string, o: { mode?: string; idem?: string } = {}) => {
      const c0 = await call(t, 'get', '/cart', a);
      const res = await t.req('put', `/cart/items/${x.variantId}`, a, o.idem ? { idem: o.idem } : {}).send({
        quantity: { value, unitId: x.unitId, packagingId: null },
        rowVersion: c0.body.rowVersion as number,
        ...(o.mode ? { mode: o.mode } : {}),
      });
      return { status: res.status, body: (res.body ?? {}) as Res['body'] };
    };
    try {
      const below = await put(k, minV, '2');
      expect([below.status, below.body.code]).toEqual([422, 'QTY_BELOW_MIN']);
      cleanConflicts(below);
      expect(below.body.conflicts).toEqual([{ variantId: minV.variantId, kind: 'qty_below_min' }]);

      const notMultiple = await put(k, multV, '6');
      expect([notMultiple.status, notMultiple.body.code]).toEqual([422, 'QTY_NOT_MULTIPLE']);
      cleanConflicts(notMultiple);
      expect(notMultiple.body.conflicts).toEqual([{ variantId: multV.variantId, kind: 'qty_not_multiple' }]);

      const unknown = await put(k, unknownV, '1');
      expect([unknown.status, unknown.body.code, unknown.body.reason]).toEqual([
        422,
        'STOCK_INSUFFICIENT',
        'stock_unknown',
      ]);
      cleanConflicts(unknown);
      expect(unknown.body.conflicts).toEqual([
        { variantId: unknownV.variantId, kind: 'stock_insufficient', stockLevel: 'unknown' },
      ]);

      // устаревшая версия корзины: 409 без `current` (полной корзины) — и у PUT, и у предпросмотра
      const c1 = await call(t, 'get', '/cart', k);
      const stale = await call(t, 'put', `/cart/items/${plainV.variantId}`, k, {
        quantity: { value: '1', unitId: plainV.unitId, packagingId: null },
        rowVersion: (c1.body.rowVersion as number) + 7,
      });
      expect([stale.status, stale.body.code]).toEqual([409, 'VERSION_CONFLICT']);
      expect(stale.body).not.toHaveProperty('current');
      expect((await putItem(t, k, plainV)).status).toBe(200);
      const body = (await previewBody(t, k)) as { cartRowVersion: number };
      const stalePreview = await call(t, 'post', '/cart/checkout-preview', k, {
        ...body,
        cartRowVersion: body.cartRowVersion + 7,
      });
      expect([stalePreview.status, stalePreview.body.code]).toEqual([409, 'VERSION_CONFLICT']);
      expect(stalePreview.body).not.toHaveProperty('current');

      // `mode=increment` с ключом: под ключом хранится уже очищенное тело, повтор отдаёт его же
      const key = randomUUID();
      const first = await put(k, minV, '2', { mode: 'increment', idem: key });
      const replay = await put(k, minV, '2', { mode: 'increment', idem: key });
      for (const r of [first, replay]) {
        expect([r.status, r.body.code]).toEqual([422, 'QTY_BELOW_MIN']);
        cleanConflicts(r);
      }
      expect(replay.body.conflicts).toEqual(first.body.conflicts);
      const stored = await t.q<{ body: { conflicts?: Record<string, unknown>[] } }>(
        `SELECT response_body AS body FROM idempotency_keys WHERE key = $1 AND user_id = $2`,
        [key, k.userId],
      );
      expect(stored.map((r) => r.body.conflicts)).toEqual([[{ variantId: minV.variantId, kind: 'qty_below_min' }]]);

      // паритет: сотруднику QTY_BELOW_MIN — с requested/factor, VERSION_CONFLICT — с current (как прежде)
      const staffBelow = await put(seller, minV, '2');
      expect([staffBelow.status, staffBelow.body.code]).toEqual([422, 'QTY_BELOW_MIN']);
      expect(staffBelow.body.conflicts).toEqual([
        expect.objectContaining({ variantId: minV.variantId, kind: 'qty_below_min', requested: expect.any(String) }),
      ]);
      expect(staffBelow.body.conflicts[0]).toHaveProperty('factor');
      const sc = await call(t, 'get', '/cart', seller);
      const staffStale = await call(t, 'put', `/cart/items/${plainV.variantId}`, seller, {
        quantity: { value: '1', unitId: plainV.unitId, packagingId: null },
        rowVersion: (sc.body.rowVersion as number) + 7,
      });
      expect([staffStale.status, staffStale.body.code]).toEqual([409, 'VERSION_CONFLICT']);
      expect(staffStale.body).toHaveProperty('current');
    } finally {
      await t.q(`UPDATE products SET min_qty = NULL, multiplicity = NULL WHERE id = ANY($1::uuid[])`, [
        [minV.productId, multV.productId],
      ]);
      await t.setStock(unknownV.variantId, stockRow[0]?.available ?? '37', w1);
    }
  });

  it('T-KIOSK-008 regular price before and after code: is_default, без него — розничная; цена планшета не меняется', async () => {
    const phone = '+996555000101';
    const target = v[3];
    // Свой планшет теста: в корзине только этот товар (заявка не зависит от строк предыдущих тестов).
    const k = await t.tablet({ name: 'Планшет T-KIOSK-008', warehouseId: w1 });
    // Карточка с соглашением из полной синхронизации 1С: свой вид цены с другой ценой; основной телефон — номер
    // покупателя (физлицо — поиск по номеру находит её однозначно, KIOSK-014).
    const agreement = await t.q<{ id: string }>(
      `INSERT INTO price_lists (onec_ref, synced_at, source_hash, name, sort_order)
       VALUES ($1::uuid, now(), 'kiosk-test', 'Договорная стенда', 50) RETURNING id`,
      [randomUUID()],
    );
    const agreementPl = agreement[0].id;
    await t.setPrice(target.variantId, '11.00', agreementPl);
    const cards = await t.q<{ id: string }>(
      `INSERT INTO customers (onec_ref, onec_code, source, name, customer_type, primary_phone_e164, phones_norm,
                              synced_at, source_hash, onec_status, default_price_list_id)
       VALUES ($1::uuid, $2, 'onec', 'Тестова Айгуль (тест)', 'individual', $3, ARRAY[$3::text], now(), 'test', 'n_a',
               $4::uuid)
       RETURNING id`,
      [randomUUID(), `T-${randomUUID().slice(0, 8)}`, phone, agreementPl],
    );
    const card = cards[0].id;
    const regular = target.price;
    expect(regular).not.toBe('11.00');
    // Цена варианта (товар может быть с характеристиками — у карточки тогда своей цены нет).
    const variantsOf = (a: PosActor) => call(t, 'get', `/catalog/products/${target.productId}/variants`, a);
    const priceOf = async (a: PosActor) => {
      const r = await variantsOf(a);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      const item = (r.body.items as { id: string; price?: unknown }[]).find((x) => x.id === target.variantId);
      return item?.price as { priceListId: string; price: { amount: string } } | undefined;
    };
    const cartLine = async () => {
      const r = await call(t, 'get', '/cart', k);
      const item = (r.body.items as { variantId: string; unitPrice?: { amount: string } }[]).find(
        (i) => i.variantId === target.variantId,
      );
      return {
        priceListId: r.body.priceListId as string,
        unitPrice: item?.unitPrice?.amount,
        customer: r.body.customer,
      };
    };

    // До кода: каталог и корзина — вид цены is_default.
    expect(await priceOf(k)).toMatchObject({ priceListId: defaultPl, price: { amount: regular } });
    expect((await putItem(t, k, target)).status).toBe(200);
    expect(await cartLine()).toEqual({ priceListId: defaultPl, unitPrice: regular, customer: null });

    // Код и заявка на этот номер (08 §4.25.1, §4.25.2): POST /kiosk/order-otp → код из SMS → предпросмотр →
    // POST /kiosk/orders. 1С по номеру никого не вернула — решение по реплике: карточка найдена (single).
    t.onec.reset();
    t.onec.useFixture('findCustomersByPhone', 'customers-search.empty.200');
    let sent: Res;
    try {
      const cart0 = await call(t, 'get', '/cart', k);
      const otp = await call(t, 'post', '/kiosk/order-otp', k, {
        phone,
        cartId: cart0.body.id as string,
        noticeVersion: NOTICE_CATALOG.kiosk_order_notice.current,
      });
      expect(otp.status, JSON.stringify(otp.body)).toBe(202);
      const challengeId = otp.body.challengeId as string;
      const code = await codeOf(t, challengeId);
      const preview = await call(t, 'post', '/cart/checkout-preview', k, await previewBody(t, k));
      expect(preview.status, JSON.stringify(preview.body)).toBe(200);
      expect(JSON.stringify(preview.body)).not.toContain(agreementPl);
      const res = await t.req('post', '/kiosk/orders', k, { idem: true }).send({
        challengeId,
        code,
        cartId: preview.body.cartId as string,
        cartRowVersion: preview.body.cartRowVersion as number,
        previewToken: preview.body.previewToken as string,
      });
      sent = { status: res.status, body: (res.body ?? {}) as Res['body'] };
    } finally {
      t.onec.reset();
    }
    expect([201, 202], JSON.stringify(sent.body)).toContain(sent.status);
    expect(Object.keys(sent.body)).toEqual(['publicNumber']);
    // Заявка — на карточку и по её виду цены (KIOSK-015); планшету эта цена не отдаётся.
    const order = await t.q<{ customer_id: string; price_list_id: string; unit_price: string; match: string }>(
      `SELECT o.customer_id, o.price_list_id, i.unit_price::text AS unit_price, o.kiosk_customer_match AS match
         FROM orders o JOIN order_items i ON i.order_id = o.id
        WHERE o.public_number = $1`,
      [sent.body.publicNumber],
    );
    expect(order).toEqual([{ customer_id: card, price_list_id: agreementPl, unit_price: '11.00', match: 'single' }]);

    // После кода и заявки: каталог и новая корзина планшета — та же обычная цена; договорной цены и карточки в ответах нет.
    expect(await priceOf(k)).toMatchObject({ priceListId: defaultPl, price: { amount: regular } });
    expect((await putItem(t, k, target)).status).toBe(200);
    expect(await cartLine()).toEqual({ priceListId: defaultPl, unitPrice: regular, customer: null });
    for (const r of [await call(t, 'get', '/cart', k), await variantsOf(k)]) {
      expect(JSON.stringify(r.body)).not.toContain(agreementPl);
      expect(JSON.stringify(r.body)).not.toContain(card);
    }
    // Даже строка привязки технического пользователя к карточке (через API её не бывает) цену не меняет.
    await t.linkCustomer(k.userId, card, 'confirmed');
    expect(await priceOf(k)).toMatchObject({ priceListId: defaultPl, price: { amount: regular } });
    expect(await cartLine()).toEqual({ priceListId: defaultPl, unitPrice: regular, customer: null });
    const forbidden = await call(t, 'get', `/catalog/products/${target.productId}?priceListId=${agreementPl}`, k);
    expect(isForbidden(forbidden)).toBe(true);
    // Паритет: покупатель режима клиента с подтверждённой привязкой к этой карточке видит свой вид цены.
    await t.linkCustomer(customer.userId, card, 'confirmed');
    expect(await priceOf(customer)).toMatchObject({ priceListId: agreementPl, price: { amount: '11.00' } });

    // Другой вид цены по умолчанию → он; без is_default → розничный («Розничн…»).
    const other = await t.q<{ id: string }>(
      `INSERT INTO price_lists (synced_at, source_hash, name, sort_order) VALUES (now(), 'kiosk-test', 'Основная стенда', 40)
       RETURNING id`,
    );
    await t.setPrice(target.variantId, '22.00', other[0].id);
    await t.q(`UPDATE price_lists SET is_default = (id = $1)`, [other[0].id]);
    try {
      expect(await priceOf(k)).toMatchObject({ priceListId: other[0].id, price: { amount: '22.00' } });
      expect(await cartLine()).toMatchObject({ priceListId: other[0].id, unitPrice: '22.00', customer: null });
      await t.q(`UPDATE price_lists SET is_default = false`);
      const retail = await t.q<{ id: string }>(
        `SELECT id FROM price_lists WHERE NOT deletion_mark AND lower(name) LIKE 'розничн%' ORDER BY sort_order, name, id LIMIT 1`,
      );
      expect(retail[0]?.id).toBeDefined();
      const p = await priceOf(k);
      expect(p?.priceListId).toBe(retail[0].id);
      expect((await cartLine()).priceListId).toBe(retail[0].id);
    } finally {
      await t.q(`UPDATE price_lists SET is_default = (id = $1)`, [defaultPl]);
    }
  });
});

describe('T-KIOSK-040 KIOSK_MODE=true + CUSTOMER_SELF_SERVICE=false: tablet works, customer blocked', () => {
  const t = new KioskTestApp();
  let tab: KioskTablet;
  let customer: PosActor;
  let v: SaleableVariant[];

  beforeAll(async () => {
    await t.startKiosk({ kioskMode: true, env: { CUSTOMER_SELF_SERVICE: 'false' } });
    await createDevOutbox(t);
    tab = await t.tablet({ name: 'Планшет у кассы' });
    customer = await t.actor({ role: 'customer' });
    v = await t.saleableVariants(2);
  });
  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-040 KIOSK_MODE=true + CUSTOMER_SELF_SERVICE=false: каталог, наличие, корзина и предпросмотр планшета — 200; покупатель — «Режим клиента выключен»', async () => {
    const q = encodeURIComponent(v[0].productName.slice(0, 4));
    const problems: string[] = [];
    for (const [method, path] of [
      ['get', '/catalog/categories'],
      ['get', '/catalog/products'],
      ['get', `/catalog/products/${v[0].productId}`],
      ['get', `/search/products?q=${q}`],
      ['get', `/inventory/balances?variantIds=${v[0].variantId}`],
      ['get', '/catalog/sync/stock'],
      ['get', '/cart'],
    ] as const) {
      const r = await call(t, method, path, tab);
      if (r.status !== 200) problems.push(label(method, path, r));
    }
    expect(problems).toEqual([]);
    expect((await putItem(t, tab, v[0])).status).toBe(200);
    const preview = await call(t, 'post', '/cart/checkout-preview', tab, await previewBody(t, tab));
    expect(preview.status, JSON.stringify(preview.body)).toBe(200);
    expect(preview.body.permissions).toMatchObject({ canCreateOrder: true });
    // Покупатель на телефоне — как сейчас: 403 «Режим клиента выключен» (10 CASH-006).
    for (const path of ['/catalog/products', '/cart', `/catalog/products/${v[0].productId}`]) {
      const r = await call(t, 'get', path, customer);
      expect([r.status, r.body.code, r.body.detail], path).toEqual([403, 'FORBIDDEN', 'Режим клиента выключен.']);
    }
  });

  it('T-KIOSK-040 заявка с планшета при CUSTOMER_SELF_SERVICE=false — 201/202 {publicNumber}, created_via=kiosk', async () => {
    // Свой планшет: в корзине только строка этого теста (10 KIOSK-001: заявка не зависит от режима клиента).
    const k = await t.tablet({ name: 'Планшет T-KIOSK-040' });
    expect((await putItem(t, k, v[1])).status).toBe(200);
    t.onec.reset();
    t.onec.useFixture('findCustomersByPhone', 'customers-search.empty.200');
    let sent: Res;
    try {
      const cart0 = await call(t, 'get', '/cart', k);
      const otp = await call(t, 'post', '/kiosk/order-otp', k, {
        phone: '+996555000140',
        cartId: cart0.body.id as string,
        noticeVersion: NOTICE_CATALOG.kiosk_order_notice.current,
      });
      expect(otp.status, JSON.stringify(otp.body)).toBe(202);
      const challengeId = otp.body.challengeId as string;
      const code = await codeOf(t, challengeId);
      const preview = await call(t, 'post', '/cart/checkout-preview', k, await previewBody(t, k));
      expect(preview.status, JSON.stringify(preview.body)).toBe(200);
      const res = await t.req('post', '/kiosk/orders', k, { idem: randomUUID() }).send({
        challengeId,
        code,
        cartId: preview.body.cartId as string,
        cartRowVersion: preview.body.cartRowVersion as number,
        previewToken: preview.body.previewToken as string,
      });
      sent = { status: res.status, body: (res.body ?? {}) as Res['body'] };
    } finally {
      t.onec.reset();
    }
    expect([201, 202], JSON.stringify(sent.body)).toContain(sent.status);
    expect(Object.keys(sent.body)).toEqual(['publicNumber']);
    expect(
      await t.q(`SELECT created_via::text AS created_via, created_by_user_id FROM orders WHERE public_number = $1`, [
        sent.body.publicNumber,
      ]),
    ).toEqual([{ created_via: 'kiosk', created_by_user_id: k.userId }]);
  });

  it('T-KIOSK-040 флаги ниже guard-а: kiosk проверяет только KIOSK_MODE (KIOSK_DISABLED), customer — только CUSTOMER_SELF_SERVICE', async () => {
    const pool = t.app.get(PG_POOL);
    const db = t.app.get(DRIZZLE);
    const perms = t.app.get(PermissionCatalog);
    const settings = t.app.get(SettingsReader);
    const kiosk = { userId: tab.userId, kind: 'kiosk' as const, roles: ['kiosk'] };
    const buyer = { userId: customer.userId, kind: 'customer' as const, roles: ['customer'] };
    const matrix: [boolean, boolean, string | null, string | null][] = [
      // KIOSK_MODE, CUSTOMER_SELF_SERVICE → отказ планшету, отказ покупателю
      [true, false, null, 'FORBIDDEN'],
      [false, true, 'KIOSK_DISABLED', null],
      [false, false, 'KIOSK_DISABLED', 'FORBIDDEN'],
      [true, true, null, null],
    ];
    for (const [kioskMode, selfService, kioskCode, buyerCode] of matrix) {
      const config = { CUSTOMER_SELF_SERVICE: selfService, KIOSK_MODE: kioskMode };
      const viewers = new CatalogViewerService(pool, perms, settings, config);
      const actors = new CartActorResolver(perms, settings, config, db);
      const outcome = async (fn: () => unknown) => {
        try {
          await fn();
          return null;
        } catch (e) {
          return (e as { code?: string }).code ?? 'ERROR';
        }
      };
      const label2 = `KIOSK_MODE=${kioskMode} CUSTOMER_SELF_SERVICE=${selfService}`;
      expect(await outcome(() => viewers.resolve(kiosk)), `${label2} viewer kiosk`).toBe(kioskCode);
      expect(await outcome(() => actors.fromPrincipal(kiosk)), `${label2} cart kiosk`).toBe(kioskCode);
      expect(await outcome(() => viewers.resolve(buyer)), `${label2} viewer customer`).toBe(buyerCode);
      expect(await outcome(() => actors.fromPrincipal(buyer)), `${label2} cart customer`).toBe(buyerCode);
    }
    // Служебный вид integration и любой вне перечня — 403 (отказ по умолчанию, 06 ARCH-065).
    const viewers = new CatalogViewerService(pool, perms, settings, { CUSTOMER_SELF_SERVICE: true, KIOSK_MODE: true });
    await expect(viewers.resolve({ userId: tab.userId, kind: 'integration', roles: [] })).rejects.toMatchObject({
      code: 'FORBIDDEN',
    });
  });
});

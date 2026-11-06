import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { kioskCardPriceListId } from '../../src/cart/kiosk-card-price-list.js';
import { signPreviewToken } from '../../src/cart/preview-token.js';
import { OtpHmacService } from '../../src/common/crypto/otp-hmac.service.js';
import {
  CART_READER,
  type CartReader,
  type CheckoutValidationInput,
  type SalesActor,
} from '../../src/common/ports/index.js';
import { ProblemException } from '../../src/common/problem-details/problem.exception.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { type KioskTablet, KioskTestApp } from './support/kiosk-fixture.js';

/**
 * Цена заявки с планшета по найденной карточке — в памяти, без утечки на планшет (Р-05 (а); P-002 §8.4 п. 4–5;
 * 10 KIOSK-006, KIOSK-015, ORD-007, ORD-008; 08 §4.7.7 «Предпросмотр на планшете», §4.25.2; 05 §6.8 п. (2),
 * ONEC-110; ADR-115 п. 5; задача TAB-1-14) — **тестовые данные** стенда `kiosk-fixture` (embedded PostgreSQL 17,
 * синтетический каталог, `ScriptedOnecGateway`; номер карточки — тестовый `+996 555 000 xxx`). Порт
 * `CartReader.validateForCheckout` вызывается так, как его вызовет `createForKiosk` (WP-S4C): актор планшета,
 * `channel: 'kiosk'`, `customerOverride` при `kioskCustomerMatch = single`, `previewToken: null`.
 * - T-KIOSK-022: строки — по виду цены карточки (без учёта `visible_to_roles`) со скидкой клиента 1С, без ручной
 *   скидки; `/check` 1С — с `customerRef` и `priceListRef` карточки, без `agreementRef` (Q-345); корзина планшета не
 *   меняется (`GET /cart` — обычная цена, `customer = null`); выбор вида цены карточки; ключ кэша `/check` — с
 *   клиентом и видом цены (результат предпросмотра по обычной цене заявке по карточке не достаётся);
 * - T-KIOSK-058: `price_changed` для канала `kiosk` не поднимается (ни против снимка обычной цены, ни против цены
 *   карточки), остаток — как прежде; `GET /cart` и предпросмотр — обычная цена; после исправления — цена карточки;
 * - T-KIOSK-059: `verifyPreviewToken` — подпись, срок, корзина, версия, способ оплаты, **без итога**; для `POST /orders`
 *   сверка итога прежняя;
 * - T-KIOSK-006 (предпросмотр): `allowedPaymentMethods = ["cash"]` у планшета и при `QR_PROVIDER=onec`;
 * - паритет: сотрудник и покупатель режима клиента — `price_changed` и сверка итога как прежде; `channel`/
 *   `customerOverride` не для планшета — ошибка вызывающего кода.
 * Санитайзер ответа планшету (`conflicts[]` только `variantId`, `kind`, `stockLevel`) и сама заявка — WP-S4C
 * (`src/kiosk/common/kiosk-problem.sanitizer.spec.ts`, `test/kiosk/orders.spec.ts`).
 */
type Method = 'get' | 'post' | 'put' | 'delete';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
}

async function call(
  t: KioskTestApp,
  method: Method,
  path: string,
  a: Pick<PosActor, 'token' | 'deviceKey'>,
  body?: object,
): Promise<Res> {
  const r = t.req(method, path, a);
  const res = await (body !== undefined ? r.send(body) : method === 'get' || method === 'delete' ? r : r.send({}));
  return { status: res.status, body: (res.body ?? {}) as Res['body'] };
}

async function putItem(t: KioskTestApp, a: PosActor, v: SaleableVariant, value: string): Promise<Res> {
  const c0 = await call(t, 'get', '/cart', a);
  const r = await call(t, 'put', `/cart/items/${v.variantId}`, a, {
    quantity: { value, unitId: v.unitId, packagingId: null },
    rowVersion: c0.body.rowVersion as number,
  });
  expect(r.status, JSON.stringify(r.body)).toBe(200);
  return r;
}

/** Тело предпросмотра планшета (08 §4.7.7): наличные, самовывоз, получатель без имени и телефона. */
async function kioskPreview(t: KioskTestApp, a: PosActor, extra: object = {}): Promise<Res> {
  const c = await call(t, 'get', '/cart', a);
  return call(t, 'post', '/cart/checkout-preview', a, {
    cartId: c.body.id as string,
    cartRowVersion: c.body.rowVersion as number,
    paymentMethod: 'cash',
    delivery: { method: 'pickup' },
    receiver: { kind: 'customer' },
    manualDiscountPercent: '0.00',
    syncCheckWithOnec: false,
    ...extra,
  });
}

function kioskActor(tab: KioskTablet): SalesActor {
  return {
    userId: tab.userId,
    roles: ['kiosk'],
    isCustomer: true,
    subjectKind: 'kiosk',
    sessionId: tab.sessionId,
    deviceId: tab.deviceId,
    requestId: null,
  };
}

function salesActorOf(a: PosActor): SalesActor {
  const buyer = a.role === 'customer';
  return {
    userId: a.userId,
    roles: a.role ? [a.role] : [],
    isCustomer: buyer,
    subjectKind: buyer ? 'customer' : 'staff',
    sessionId: a.sessionId,
    deviceId: a.deviceId,
    requestId: null,
  };
}

/** Синхронный отказ (`verifyPreviewToken`) — исключение Problem или `null`. */
function problemOf(fn: () => void): ProblemException | null {
  try {
    fn();
    return null;
  } catch (e) {
    if (e instanceof ProblemException) return e;
    throw e;
  }
}

/** Строка `carts` и строки `cart_items` целиком — для проверки «в корзину ничего не пишется». */
async function cartState(t: KioskTestApp, cartId: string): Promise<string> {
  const c = await t.q<{ j: unknown }>(`SELECT row_to_json(c) AS j FROM carts c WHERE id = $1`, [cartId]);
  const i = await t.q<{ j: unknown }>(
    `SELECT coalesce(json_agg(i ORDER BY i.line_no), '[]'::json) AS j FROM cart_items i WHERE i.cart_id = $1`,
    [cartId],
  );
  return JSON.stringify({ cart: c[0]?.j, items: i[0]?.j });
}

type CheckRequest = Record<string, unknown>;

describe('kiosk: цена заявки по карточке в памяти, токен предпросмотра без итога, ключ кэша /check (KIOSK_MODE=true)', () => {
  const t = new KioskTestApp();
  let reader: CartReader;
  let hmac: OtpHmacService;
  let v: SaleableVariant[];
  let w1: string;
  let defaultPl: string;
  let cardPl: string;
  let card: string;
  let cardRefs: { customer: string; priceList: string; warehouse: string | null };
  const REGULAR = '100.00';
  const CARD_PRICE = '80.00';

  const checkCalls = (): readonly CheckRequest[] => t.onec.callsOf('checkCart').map((args) => args[0] as CheckRequest);

  const validate = (actor: SalesActor, input: CheckoutValidationInput) =>
    reader.validateForCheckout(null, actor, input);

  beforeAll(async () => {
    // QR_PROVIDER=onec: покупателю режима клиента доступен QR, планшету — только «Оплата на кассе» (08 §4.7.7).
    await t.startKiosk({ kioskMode: true, env: { QR_PROVIDER: 'onec' } });
    reader = t.registry.get(CART_READER);
    hmac = t.app.get(OtpHmacService, { strict: false });
    w1 = await t.defaultWarehouseId();
    defaultPl = await t.defaultPriceListId();
    v = await t.saleableVariants(10, { warehouseId: w1 });
    // Вид цены соглашения карточки: ниже обычной цены; `visible_to_roles` — по умолчанию (роли kiosk там нет).
    const pl = await t.q<{ id: string }>(
      `INSERT INTO price_lists (onec_ref, synced_at, source_hash, name, sort_order)
       VALUES ($1::uuid, now(), 'kiosk-test', 'Договорная стенда', 50) RETURNING id`,
      [randomUUID()],
    );
    cardPl = pl[0].id;
    for (const x of v) {
      await t.setPrice(x.variantId, REGULAR);
      await t.setPrice(x.variantId, CARD_PRICE, cardPl);
    }
    card = await t.createOnecCustomer({
      name: 'ИП Тестовый покупатель',
      priceListId: cardPl,
      discountPercent: '5.00',
      phoneE164: '+996555000201',
    });
    const refs = await t.q<{ customer: string; price_list: string; warehouse: string | null }>(
      `SELECT (SELECT onec_ref::text FROM customers WHERE id = $1) AS customer,
              (SELECT onec_ref::text FROM price_lists WHERE id = $2) AS price_list,
              (SELECT onec_ref::text FROM warehouses WHERE id = $3) AS warehouse`,
      [card, cardPl, w1],
    );
    cardRefs = { customer: refs[0].customer, priceList: refs[0].price_list, warehouse: refs[0].warehouse };
  });
  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-022 lines by card price list and customer discount, /check with customerRef+priceListRef, no agreementRef (Q-345)', async () => {
    const tab = await t.tablet({ name: 'Планшет у входа', warehouseId: w1 });
    await putItem(t, tab, v[0], '2');
    await putItem(t, tab, v[1], '1');
    const cart = await call(t, 'get', '/cart', tab);
    expect(cart.body).toMatchObject({ customer: null, priceListId: defaultPl, warehouseId: w1 });
    const before = await cartState(t, cart.body.id as string);
    const visible = await t.q<{ roles: string }>(
      `SELECT visible_to_roles::text AS roles FROM price_lists WHERE id = $1`,
      [cardPl],
    );
    expect(visible[0].roles).not.toContain('kiosk');
    const calls0 = checkCalls().length;

    const r = await validate(kioskActor(tab), {
      cartId: cart.body.id as string,
      expectedRowVersion: cart.body.rowVersion as number,
      paymentMethod: 'cash',
      previewToken: null,
      channel: 'kiosk',
      customerOverride: { customerId: card },
    });
    expect(r.ok, JSON.stringify(r.conflicts)).toBe(true);
    expect(r.allowedPaymentMethods).toEqual(['cash']);
    // Снимок для order_items: клиент, вид цены, цены строк и скидка клиента 1С — по карточке; ручной скидки нет.
    expect(r.cart).toMatchObject({
      cartId: cart.body.id,
      rowVersion: cart.body.rowVersion,
      ownerUserId: tab.userId,
      customerId: card,
      priceListId: cardPl,
      warehouseId: w1,
      customerDiscountPercent: '5.00',
      manualDiscountPercent: '0.00',
      discountApprovedByUserId: null,
      subtotal: '240.00',
      customerDiscountTotal: '12.00',
      manualDiscountTotal: '0.00',
      total: '228.00',
    });
    expect(r.cart.lines.map((l) => [l.variantId, l.unitPrice, l.lineSubtotal])).toEqual([
      [v[0].variantId, CARD_PRICE, '160.00'],
      [v[1].variantId, CARD_PRICE, '80.00'],
    ]);
    // Синхронный /check 1С — с карточкой (05 ONEC-110), полей соглашения у /check нет (Q-345).
    const calls = checkCalls().slice(calls0);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({
      customerRef: cardRefs.customer,
      priceListRef: cardRefs.priceList,
      warehouseRef: cardRefs.warehouse,
      paymentMethod: 'cash',
    });
    expect(calls[0]).not.toHaveProperty('agreementRef');
    expect(r.onecCheck).toMatchObject({ performed: true, result: 'ok' });

    // В корзину планшета ничего не записано; GET /cart — обычная цена, без клиента, обычный вид цены.
    expect(await cartState(t, cart.body.id as string)).toBe(before);
    const after = await call(t, 'get', '/cart', tab);
    expect(after.body).toMatchObject({
      customer: null,
      priceListId: defaultPl,
      rowVersion: cart.body.rowVersion,
      customerDiscountPercent: '0.00',
      total: { amount: '300.00' },
    });
    const text = JSON.stringify(after.body);
    for (const leak of [card, cardPl, CARD_PRICE, '228.00']) expect(text).not.toContain(leak);

    // Без карточки (ambiguous / none) — обычная цена корзины, клиент не задан.
    const retail = await validate(kioskActor(tab), {
      cartId: cart.body.id as string,
      expectedRowVersion: cart.body.rowVersion as number,
      paymentMethod: 'cash',
      previewToken: null,
      channel: 'kiosk',
    });
    expect(retail.cart).toMatchObject({
      customerId: null,
      priceListId: defaultPl,
      customerDiscountPercent: '0.00',
      total: '300.00',
    });
  });

  it('T-KIOSK-022 card price list: card → is_default → retail, without visible_to_roles', async () => {
    expect(await kioskCardPriceListId(t.db, card)).toBe(cardPl);
    const noPl = await t.createOnecCustomer({ name: 'ИП Без соглашения', phoneE164: '+996555000202' });
    expect(await kioskCardPriceListId(t.db, noPl)).toBe(defaultPl);
    const deletedPl = await t.q<{ id: string }>(
      `INSERT INTO price_lists (synced_at, source_hash, name, sort_order, deletion_mark)
       VALUES (now(), 'kiosk-test', 'Удалённая стенда', 60, true) RETURNING id`,
    );
    const withDeleted = await t.createOnecCustomer({ name: 'ИП Удалённый вид цены', priceListId: deletedPl[0].id });
    expect(await kioskCardPriceListId(t.db, withDeleted)).toBe(defaultPl);
    const markedCard = await t.createOnecCustomer({ name: 'ИП Помеченная карточка', priceListId: cardPl });
    await t.q(`UPDATE customers SET deletion_mark = true WHERE id = $1`, [markedCard]);
    expect(await kioskCardPriceListId(t.db, markedCard)).toBe(defaultPl);
    // Без is_default — розничный («Розничн…»), как INV-030 «без клиента».
    await t.q(`UPDATE price_lists SET is_default = false`);
    try {
      const retail = await t.q<{ id: string }>(
        `SELECT id FROM price_lists WHERE NOT deletion_mark AND lower(name) LIKE 'розничн%' ORDER BY sort_order, name, id LIMIT 1`,
      );
      expect(retail[0]?.id).toBeDefined();
      expect(await kioskCardPriceListId(t.db, noPl)).toBe(retail[0].id);
      expect(await kioskCardPriceListId(t.db, card)).toBe(cardPl);
    } finally {
      await t.q(`UPDATE price_lists SET is_default = (id = $1)`, [defaultPl]);
    }
  });

  it('T-KIOSK-022 /check cache key with customer and price list: preview by regular price is not reused for the card', async () => {
    const tab = await t.tablet({ name: 'Планшет у кассы', warehouseId: w1 });
    await putItem(t, tab, v[2], '1');
    const calls0 = checkCalls().length;
    // Предпросмотр с синхронной проверкой (тело может её запросить) — /check по обычной цене, без клиента.
    const p = await kioskPreview(t, tab, { syncCheckWithOnec: true });
    expect(p.status, JSON.stringify(p.body)).toBe(200);
    expect(checkCalls().slice(calls0)).toHaveLength(1);
    expect(checkCalls().at(-1)).toMatchObject({ customerRef: null });
    const base = {
      cartId: p.body.cartId as string,
      expectedRowVersion: p.body.cartRowVersion as number,
      paymentMethod: 'cash' as const,
      previewToken: null,
      channel: 'kiosk' as const,
    };
    // Та же корзина, клиент и вид цены — результат 60 с переиспользуется (05 SYNC-071, как прежде).
    await validate(kioskActor(tab), base);
    expect(checkCalls().slice(calls0)).toHaveLength(1);
    // Карточка — другой ключ: новый /check с карточкой; повтор с карточкой — из кэша.
    const r = await validate(kioskActor(tab), { ...base, customerOverride: { customerId: card } });
    expect(r.cart.priceListId).toBe(cardPl);
    expect(checkCalls().slice(calls0)).toHaveLength(2);
    expect(checkCalls().at(-1)).toMatchObject({ customerRef: cardRefs.customer, priceListRef: cardRefs.priceList });
    await validate(kioskActor(tab), { ...base, customerOverride: { customerId: card } });
    expect(checkCalls().slice(calls0)).toHaveLength(2);
  });

  it('T-KIOSK-058 no price_changed, GET /cart regular price, /check with card', async () => {
    const tab = await t.tablet({ name: 'Планшет в зале', warehouseId: w1 });
    await putItem(t, tab, v[3], '1');
    await putItem(t, tab, v[4], '3');
    // Обычная цена изменилась после добавления (снимок 100.00 ≠ 105.00); остатка v[4] не хватает.
    await t.setPrice(v[3].variantId, '105.00');
    await t.setStock(v[4].variantId, '1', w1);
    const cart = await call(t, 'get', '/cart', tab);
    const before = await cartState(t, cart.body.id as string);
    const input = {
      cartId: cart.body.id as string,
      expectedRowVersion: cart.body.rowVersion as number,
      paymentMethod: 'cash' as const,
      previewToken: null,
      channel: 'kiosk' as const,
      customerOverride: { customerId: card },
    };
    const calls0 = checkCalls().length;
    const refused = await validate(kioskActor(tab), input);
    expect(refused.ok).toBe(false);
    expect(refused.conflicts.map((c) => [c.variantId, c.kind])).toEqual([[v[4].variantId, 'stock_insufficient']]);
    expect(JSON.stringify(refused.conflicts)).not.toContain('Price');
    const calls = checkCalls().slice(calls0);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ customerRef: cardRefs.customer, priceListRef: cardRefs.priceList });
    // Без карточки (обычная цена 105.00 ≠ снимку) — тоже без price_changed.
    const regular = await validate(kioskActor(tab), { ...input, customerOverride: undefined });
    expect(regular.conflicts.map((c) => c.kind)).toEqual(['stock_insufficient']);

    // После отказа: корзина планшета не изменилась; GET /cart и предпросмотр — обычная цена, без клиента.
    expect(await cartState(t, cart.body.id as string)).toBe(before);
    const view = await call(t, 'get', '/cart', tab);
    expect(view.body).toMatchObject({ customer: null, priceListId: defaultPl });
    const prices = (view.body.items as { variantId: string; unitPrice: { amount: string } }[]).map((i) => [
      i.variantId,
      i.unitPrice.amount,
    ]);
    expect(prices).toEqual([
      [v[3].variantId, '105.00'],
      [v[4].variantId, REGULAR],
    ]);
    const preview = await kioskPreview(t, tab);
    expect(preview.status, JSON.stringify(preview.body)).toBe(200);
    expect(preview.body.permissions.allowedPaymentMethods).toEqual(['cash']);
    expect(preview.body.total).toEqual({ amount: '405.00', currency: 'KGS' });
    for (const text of [JSON.stringify(view.body), JSON.stringify(preview.body)]) {
      for (const leak of [card, cardPl, CARD_PRICE]) expect(text).not.toContain(leak);
    }

    // Исправить корзину (количество по остатку) — заявка проходит по цене карточки со скидкой клиента 1С.
    await putItem(t, tab, v[4], '1');
    const fixed = await call(t, 'get', '/cart', tab);
    const ok = await validate(kioskActor(tab), { ...input, expectedRowVersion: fixed.body.rowVersion as number });
    expect(ok.ok, JSON.stringify(ok.conflicts)).toBe(true);
    expect(ok.cart).toMatchObject({ customerId: card, priceListId: cardPl, subtotal: '160.00', total: '152.00' });
    expect(ok.cart.lines.map((l) => l.unitPrice)).toEqual([CARD_PRICE, CARD_PRICE]);
  });

  it('T-KIOSK-058 parity: staff and customer keep price_changed; channel and customerOverride only for the tablet', async () => {
    const seller = await t.actor({ role: 'seller' });
    const buyer = await t.actor({ role: 'customer' });
    await putItem(t, seller, v[5], '1');
    await putItem(t, buyer, v[5], '1');
    await t.setPrice(v[5].variantId, '107.00');
    for (const a of [seller, buyer]) {
      const c = await call(t, 'get', '/cart', a);
      const r = await validate(salesActorOf(a), {
        cartId: c.body.id as string,
        expectedRowVersion: c.body.rowVersion as number,
        paymentMethod: 'cash',
      });
      expect(r.ok).toBe(false);
      expect(r.conflicts).toEqual([
        expect.objectContaining({
          variantId: v[5].variantId,
          kind: 'price_changed',
          oldPrice: { amount: REGULAR, currency: 'KGS' },
          newPrice: { amount: '107.00', currency: 'KGS' },
        }),
      ]);
      // Сервер задаёт канал и карточку только планшету: иначе — ошибка вызывающего кода, а не подмена цены.
      await expect(
        validate(salesActorOf(a), { cartId: c.body.id as string, customerOverride: { customerId: card } }),
      ).rejects.toThrow(/только для актора планшета/);
      await expect(validate(salesActorOf(a), { cartId: c.body.id as string, channel: 'kiosk' })).rejects.toThrow(
        /только для актора планшета/,
      );
    }
    const tab = await t.tablet({ warehouseId: w1 });
    await expect(validate(kioskActor(tab), { customerOverride: { customerId: card } })).rejects.toThrow(
      /только вместе с channel=kiosk/,
    );
  });

  it('T-KIOSK-059 token check without total: signature, expiry, cart, version, payment method', async () => {
    const tab = await t.tablet({ name: 'Планшет у выхода', warehouseId: w1 });
    await putItem(t, tab, v[6], '1');
    const p = await kioskPreview(t, tab);
    expect(p.status, JSON.stringify(p.body)).toBe(200);
    expect(p.body.total).toEqual({ amount: REGULAR, currency: 'KGS' });
    const token = p.body.previewToken as string;
    const cartId = p.body.cartId as string;
    const cartRowVersion = p.body.cartRowVersion as number;
    const expected = { cartId, cartRowVersion, paymentMethod: 'cash' as const };
    expect(problemOf(() => reader.verifyPreviewToken(token, expected))).toBeNull();

    // Итог по карточке (80.00 − 5 %) ≠ итогу предпросмотра (100.00): токен с тем же итогом и без него — годен.
    const priced = await validate(kioskActor(tab), {
      cartId,
      expectedRowVersion: cartRowVersion,
      paymentMethod: 'cash',
      previewToken: token,
      channel: 'kiosk',
      customerOverride: { customerId: card },
    });
    expect(priced.ok).toBe(true);
    expect(priced.cart.total).toBe('76.00');

    const reasonOf = (tok: string, exp: Parameters<CartReader['verifyPreviewToken']>[1]) => {
      const e = problemOf(() => reader.verifyPreviewToken(tok, exp));
      expect(e?.code).toBe('PRICE_CHANGED');
      expect(e?.getStatus()).toBe(422);
      // Без сумм: ни итога предпросмотра, ни итога заявки; conflicts пуст.
      expect(e?.extensions).not.toHaveProperty('total');
      expect(e?.extensions).not.toHaveProperty('previewTotal');
      expect(e?.extensions.conflicts).toEqual([]);
      return e?.extensions.reason;
    };
    expect(reasonOf(token, { ...expected, cartRowVersion: cartRowVersion + 1 })).toBe('preview_cart_changed');
    expect(reasonOf(token, { ...expected, cartId: randomUUID() })).toBe('preview_cart_changed');
    expect(reasonOf(token, { ...expected, paymentMethod: 'qr_bakai' })).toBe('preview_payment_method_changed');
    const tampered = `${token.slice(0, -1)}${token.endsWith('A') ? 'B' : 'A'}`;
    expect(reasonOf(tampered, expected)).toBe('preview_token_invalid');
    expect(reasonOf('not-a-token', expected)).toBe('preview_token_invalid');
    const expired = signPreviewToken(hmac, {
      cartId,
      cartRowVersion,
      total: REGULAR,
      paymentMethod: 'cash',
      validUntil: new Date(Date.now() - 1000).toISOString(),
      onecCheckAt: null,
      onecResult: 'unavailable',
    });
    expect(reasonOf(expired, expected)).toBe('preview_token_invalid');
    // Корзина изменена после предпросмотра — прежний токен к новой версии не подходит.
    await putItem(t, tab, v[6], '2');
    const changed = await call(t, 'get', '/cart', tab);
    expect(reasonOf(token, { ...expected, cartRowVersion: changed.body.rowVersion as number })).toBe(
      'preview_cart_changed',
    );
  });

  it('T-KIOSK-059 parity: POST /orders keeps the total check (preview_total_changed) for staff, not for the tablet', async () => {
    const seller = await t.actor({ role: 'seller' });
    await putItem(t, seller, v[7], '1');
    const c = await call(t, 'get', '/cart', seller);
    const signWithTotal = (cartId: string, cartRowVersion: number, total: string) =>
      signPreviewToken(hmac, {
        cartId,
        cartRowVersion,
        total,
        paymentMethod: 'cash',
        validUntil: new Date(Date.now() + 60_000).toISOString(),
        onecCheckAt: null,
        onecResult: 'unavailable',
      });
    const stale = signWithTotal(c.body.id as string, c.body.rowVersion as number, '1.00');
    await expect(
      validate(salesActorOf(seller), {
        cartId: c.body.id as string,
        expectedRowVersion: c.body.rowVersion as number,
        paymentMethod: 'cash',
        previewToken: stale,
      }),
    ).rejects.toMatchObject({
      code: 'PRICE_CHANGED',
      extensions: {
        reason: 'preview_total_changed',
        previewTotal: { amount: '1.00', currency: 'KGS' },
        total: { amount: REGULAR, currency: 'KGS' },
      },
    });
    const good = signWithTotal(c.body.id as string, c.body.rowVersion as number, REGULAR);
    const ok = await validate(salesActorOf(seller), {
      cartId: c.body.id as string,
      expectedRowVersion: c.body.rowVersion as number,
      paymentMethod: 'cash',
      previewToken: good,
    });
    expect(ok.ok).toBe(true);

    // Планшет: тот же итог-«не тот» токена не мешает (итог не сверяется ни в verifyPreviewToken, ни в шаге 2).
    const tab = await t.tablet({ warehouseId: w1 });
    await putItem(t, tab, v[7], '1');
    const k = await call(t, 'get', '/cart', tab);
    const kioskStale = signWithTotal(k.body.id as string, k.body.rowVersion as number, '1.00');
    const expected = {
      cartId: k.body.id as string,
      cartRowVersion: k.body.rowVersion as number,
      paymentMethod: 'cash' as const,
    };
    expect(problemOf(() => reader.verifyPreviewToken(kioskStale, expected))).toBeNull();
    const r = await validate(kioskActor(tab), {
      cartId: expected.cartId,
      expectedRowVersion: expected.cartRowVersion,
      paymentMethod: 'cash',
      previewToken: kioskStale,
      channel: 'kiosk',
    });
    expect(r.ok).toBe(true);
  });

  it('T-KIOSK-006 preview allowedPaymentMethods = [cash] with QR_PROVIDER=onec; qr_bakai → 422; customer keeps QR', async () => {
    const tab = await t.tablet({ warehouseId: w1 });
    await putItem(t, tab, v[8], '1');
    const p = await kioskPreview(t, tab);
    expect(p.status, JSON.stringify(p.body)).toBe(200);
    expect(p.body.permissions).toMatchObject({ allowedPaymentMethods: ['cash'], canCreateOrder: true });
    const qr = await kioskPreview(t, tab, { paymentMethod: 'qr_bakai' });
    expect(qr.status, JSON.stringify(qr.body)).toBe(422);
    expect(qr.body).toMatchObject({ code: 'VALIDATION_FAILED' });
    expect(JSON.stringify(qr.body.errors)).toContain('payment_method_unavailable');
    const k = await call(t, 'get', '/cart', tab);
    await expect(
      validate(kioskActor(tab), {
        cartId: k.body.id as string,
        paymentMethod: 'qr_bakai',
        channel: 'kiosk',
      }),
    ).rejects.toMatchObject({ code: 'VALIDATION_FAILED' });
    // Паритет: покупатель режима клиента при QR_PROVIDER=onec — наличные и QR (08 §4.7.7), как прежде.
    const buyer = await t.actor({ role: 'customer' });
    await putItem(t, buyer, v[9], '1');
    const b = await call(t, 'get', '/cart', buyer);
    const bp = await call(t, 'post', '/cart/checkout-preview', buyer, {
      cartId: b.body.id as string,
      cartRowVersion: b.body.rowVersion as number,
      paymentMethod: 'qr_bakai',
      delivery: { method: 'pickup' },
      receiver: { kind: 'customer' },
      syncCheckWithOnec: false,
    });
    expect(bp.status, JSON.stringify(bp.body)).toBe(200);
    expect(bp.body.permissions.allowedPaymentMethods).toEqual(['cash', 'qr_bakai']);
  });
});

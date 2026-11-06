import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { OTP_PROVIDER, type OtpProvider } from '../../src/auth/otp/otp.provider.js';
import { type OtpCheck, OtpService } from '../../src/auth/otp/otp.service.js';
import { CartModule } from '../../src/cart/cart.module.js';
import { KIOSK_ACCESS_GUARD } from '../../src/kiosk/common/kiosk-access.guard.js';
import { KioskModule } from '../../src/kiosk/kiosk.module.js';
import { OrdersModule } from '../../src/orders/orders.module.js';
import { ProfileModule } from '../../src/profile/profile.module.js';
import { PublicSettingsModule } from '../../src/settings/public-settings.module.js';
import type { PosActor, SaleableVariant } from '../support/pos-fixture.js';
import { type KioskTablet, KioskTestApp } from './support/kiosk-fixture.js';

/**
 * `POST /kiosk/reset` — сброс планшета магазина (08 §4.25.4; 10 KIOSK-020, AC-KIOSK-020; 04 FLOW-045; 11 §6.1
 * `kiosk.session_reset`; ADR-115) — **тестовые данные** стенда `kiosk-fixture` (embedded PostgreSQL 17, синтетический
 * каталог; номера покупателей — вымышленные `+996 555 002 xxx`; коды из SMS — из `dev_outbox` поддельного шлюза):
 * - T-KIOSK-028: новый `cartId`, прежняя корзина закрыта (и пустая тоже), код погашен, аудит `cart.cleared`
 *   `after.reason = kiosk_reset`, журнал `kiosk.session_reset` без номера;
 * - T-KIOSK-054: сброс гасит и проверенный, но не погашенный код (`replayed_at`), прежний код → `OTP_EXPIRED`; повтор с
 *   тем же `cartId` → `200` с текущей корзиной без новой корзины и без повторного гашения; одновременные сбросы;
 *   порядок блокировок «коды → корзина» — сброс во время транзакции заявки ждёт её, без взаимоблокировки;
 * - отказы: чужая и несуществующая корзина → `404`, тело → `400`, сотрудник и покупатель → `403`, склад планшета не
 *   задан → `403 kiosk_warehouse_unavailable` без изменений.
 * Прикладная часть T-KIOSK-028/-054 (таймеры, метка без сети) — `pos-app/test/features/kiosk/kiosk_reset_test.dart`.
 */
type Method = 'get' | 'post' | 'put' | 'patch' | 'delete';

interface Res {
  readonly status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- тело ответа API в проверках
  readonly body: Record<string, any>;
}

const NOTICE = '2026-11-04';
const DEV_OUTBOX_SQL = fileURLToPath(new URL('../../db/migrations-dev/0001_dev_outbox.sql', import.meta.url));

let phoneSeq = 0;
/** Вымышленный мобильный номер КР `+996 555 002 xxx` (тестовые данные). */
function freshPhone(): string {
  phoneSeq += 1;
  return `+996555002${String(100 + phoneSeq)}`;
}

async function call(t: KioskTestApp, method: Method, path: string, a?: PosActor, body?: unknown): Promise<Res> {
  const r = t.req(method, path, a);
  const res = await (body !== undefined ? r.send(body as object) : r);
  return { status: res.status, body: (res.body ?? {}) as Res['body'] };
}

function reset(t: KioskTestApp, a: PosActor, body: unknown): Promise<Res> {
  return call(t, 'post', '/kiosk/reset', a, body);
}

/** Корзина с одной строкой (SCR-51); возвращает `cartId`. */
async function fillCart(t: KioskTestApp, a: PosActor, v: SaleableVariant): Promise<string> {
  const c0 = await call(t, 'get', '/cart', a);
  expect(c0.status).toBe(200);
  const put = await call(t, 'put', `/cart/items/${v.variantId}`, a, {
    quantity: { value: '1', unitId: v.unitId, packagingId: null },
    rowVersion: c0.body.rowVersion as number,
  });
  expect(put.status, JSON.stringify(put.body)).toBe(200);
  return c0.body.id as string;
}

/** `dev_outbox` (07 §5.63) в БД стенда — как `order-otp.spec.ts` (файл dev-миграции не меняется). */
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

/** Проверка кода так, как её сделает `POST /kiosk/orders` (WP-S4C): назначение `kiosk_order`, устройство планшета. */
async function checkCode(t: KioskTestApp, tab: KioskTablet, challengeId: string, code: string): Promise<OtpCheck> {
  const otp = t.app.get(OtpService, { strict: false });
  return t.db.transaction((tx) =>
    otp.check(tx, { challengeId, code, deviceKey: tab.deviceKey, purpose: 'kiosk_order', allowReplay: true }),
  );
}

async function requestCode(t: KioskTestApp, tab: KioskTablet, cartId: string): Promise<{ id: string; code: string }> {
  const r = await call(t, 'post', '/kiosk/order-otp', tab, { phone: freshPhone(), cartId, noticeVersion: NOTICE });
  expect(r.status, JSON.stringify(r.body)).toBe(202);
  const id = r.body.challengeId as string;
  return { id, code: await codeOf(t, id) };
}

async function cartRows(t: KioskTestApp, ownerUserId: string) {
  return t.q<{ id: string; status: string; cleared_at: Date | null; warehouse_id: string; customer_id: string | null }>(
    `SELECT id, status::text AS status, cleared_at, warehouse_id, customer_id FROM carts
      WHERE owner_user_id = $1 ORDER BY created_at, id`,
    [ownerUserId],
  );
}

/** Ждать, пока `n` других соединений БД стенда не встанут в ожидание блокировки (`pg_stat_activity`), не дольше 10 с. */
async function waitForLockWaiters(t: KioskTestApp, n: number): Promise<void> {
  const until = Date.now() + 10_000;
  for (;;) {
    const r = await t.q<{ n: number }>(
      `SELECT count(*)::int AS n FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()`,
    );
    if ((r[0]?.n ?? 0) >= n) return;
    if (Date.now() > until) throw new Error(`нет ${String(n)} ожидающих блокировку соединений`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

async function codeStatus(t: KioskTestApp, id: string): Promise<{ status: string; replayed: boolean }> {
  const r = await t.q<{ status: string; replayed_at: Date | null }>(
    `SELECT status::text AS status, replayed_at FROM otp_challenges WHERE id = $1`,
    [id],
  );
  return { status: r[0]?.status ?? 'none', replayed: r[0]?.replayed_at !== null && r[0]?.replayed_at !== undefined };
}

describe('kiosk: POST /kiosk/reset — сброс планшета (KIOSK_MODE=true)', () => {
  const t = new KioskTestApp();
  let variant: SaleableVariant;
  let seller: PosActor;
  let customer: PosActor;

  beforeAll(async () => {
    // Как startKiosk стенда; пробные маршруты /kiosk/* не нужны — контроллеры сброса и кода настоящие.
    await t.start({
      env: { QR_PROVIDER: 'none', KIOSK_MODE: 'true', OTP_GLOBAL_PER_MIN: '100000' },
      skuCount: 40,
      modules: [CartModule, OrdersModule, ProfileModule, PublicSettingsModule, KioskModule],
      guards: [KIOSK_ACCESS_GUARD],
      fakePorts: true,
      jobs: false,
    });
    await createDevOutbox(t);
    variant = (await t.saleableVariants(1))[0];
    seller = await t.actor({ role: 'seller' });
    customer = await t.actor({ role: 'customer' });
  });

  afterAll(async () => {
    await t.stop();
  });

  it('T-KIOSK-028 new cartId, old closed, code gashed: новая пустая корзина склада планшета, аудит и журнал без номера', async () => {
    const tab = await t.tablet();
    const cartId = await fillCart(t, tab, variant);
    const code = await requestCode(t, tab, cartId);
    expect(await codeStatus(t, code.id)).toEqual({ status: 'sent', replayed: false });
    const logsBefore = t.logs.lines.length;

    const r = await reset(t, tab, { cartId });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const fresh = r.body.id as string;
    expect(fresh).not.toBe(cartId);
    expect(r.body).toMatchObject({
      status: 'active',
      ownerId: tab.userId,
      customer: null,
      warehouseId: tab.warehouseId,
      items: [],
      itemsCount: 0,
      receiver: { kind: 'customer', name: null, phone: null },
    });

    // прежняя закрыта, новая — единственная активная корзина планшета
    const carts = await cartRows(t, tab.userId);
    expect(carts.map((c) => [c.id, c.status])).toEqual([
      [cartId, 'cleared'],
      [fresh, 'active'],
    ]);
    expect(carts[0]?.cleared_at).not.toBeNull();
    expect(carts[1]).toMatchObject({ warehouse_id: tab.warehouseId, customer_id: null });
    expect((await call(t, 'get', '/cart', tab)).body.id).toBe(fresh);

    // код погашен: `sent → superseded`, проверка — как истёкший (`422 OTP_EXPIRED` в POST /kiosk/orders)
    expect(await codeStatus(t, code.id)).toEqual({ status: 'superseded', replayed: false });
    expect((await checkCode(t, tab, code.id, code.code)).kind).toBe('expired');

    // аудит `cart.cleared` (08 §3.16): `after.reason = kiosk_reset`, `itemsCount`; без телефона и кода
    const audit = await t.auditRows('cart.cleared', cartId);
    expect(audit).toEqual([
      expect.objectContaining({
        result: 'ok',
        actor_user_id: tab.userId,
        after: {
          cartId,
          itemsCount: 1,
          parked: false,
          reason: 'kiosk_reset',
          newCartId: fresh,
          codesGashed: 1,
        },
      }),
    ]);
    expect(JSON.stringify(audit)).not.toContain('+996');

    // журнал `kiosk.session_reset` (11 §6.1): tabletId, cartId, reason — без номера, кода и сумм
    const lines = t.logs.lines.slice(logsBefore);
    const events = lines
      .map((l) => JSON.parse(l) as Record<string, unknown>)
      .filter((e) => e.event === 'kiosk.session_reset');
    expect(events).toEqual([expect.objectContaining({ tabletId: tab.tabletId, cartId, reason: 'kiosk_reset' })]);
    expect(lines.join('\n')).not.toContain('+996555002');
    expect(lines.join('\n')).not.toContain(code.code);
  });

  it('T-KIOSK-028 пустая корзина тоже закрывается — у следующего покупателя всегда новый cartId', async () => {
    const tab = await t.tablet();
    const empty = await call(t, 'get', '/cart', tab);
    expect([empty.status, empty.body.itemsCount]).toEqual([200, 0]);
    const r = await reset(t, tab, { cartId: empty.body.id as string });
    expect(r.status).toBe(200);
    expect(r.body.id).not.toBe(empty.body.id);
    expect((await cartRows(t, tab.userId)).map((c) => c.status)).toEqual(['cleared', 'active']);
    expect(await t.auditRows('cart.cleared', empty.body.id as string)).toEqual([
      expect.objectContaining({ after: expect.objectContaining({ itemsCount: 0, reason: 'kiosk_reset' }) }),
    ]);
  });

  it('T-KIOSK-054 reset gashes code, idempotent repeat: проверенный код — replayed_at, повтор 200 без нового гашения', async () => {
    const tab = await t.tablet();
    const cartId = await fillCart(t, tab, variant);
    const code = await requestCode(t, tab, cartId);
    // верный код уже проверен (как после отказа шага корзины в POST /kiosk/orders) и ещё не погашен
    expect((await checkCode(t, tab, code.id, code.code)).kind).toBe('ok');
    expect(await codeStatus(t, code.id)).toEqual({ status: 'verified', replayed: false });

    const first = await reset(t, tab, { cartId });
    expect(first.status).toBe(200);
    const fresh = first.body.id as string;
    expect(await codeStatus(t, code.id)).toEqual({ status: 'verified', replayed: true });
    expect((await checkCode(t, tab, code.id, code.code)).kind).toBe('expired');

    // следующий покупатель запросил код на новой корзине — повтор сброса прежней корзины его не трогает
    await fillCart(t, tab, variant);
    const next = await requestCode(t, tab, fresh);
    const logsBefore = t.logs.lines.length;
    const repeat = await reset(t, tab, { cartId });
    expect(repeat.status, JSON.stringify(repeat.body)).toBe(200);
    expect(repeat.body).toMatchObject({ id: fresh, status: 'active', itemsCount: 1 });
    expect((await cartRows(t, tab.userId)).map((c) => [c.id, c.status])).toEqual([
      [cartId, 'cleared'],
      [fresh, 'active'],
    ]);
    expect(await codeStatus(t, next.id)).toEqual({ status: 'sent', replayed: false });
    expect(await t.auditRows('cart.cleared', cartId)).toHaveLength(1);
    const events = t.logs.lines
      .slice(logsBefore)
      .map((l) => JSON.parse(l) as Record<string, unknown>)
      .filter((e) => e.event === 'kiosk.session_reset');
    expect(events).toEqual([expect.objectContaining({ tabletId: tab.tabletId, cartId, reason: 'already_closed' })]);
  });

  it('T-KIOSK-054 одновременные сбросы одной корзины (повтор после обрыва связи): одна новая корзина, одна запись аудита', async () => {
    const tab = await t.tablet();
    const cartId = await fillCart(t, tab, variant);
    const rs = await Promise.all([reset(t, tab, { cartId }), reset(t, tab, { cartId }), reset(t, tab, { cartId })]);
    expect(rs.map((r) => r.status)).toEqual([200, 200, 200]);
    const ids = new Set(rs.map((r) => r.body.id as string));
    expect(ids.size).toBe(1);
    const carts = await cartRows(t, tab.userId);
    expect(carts.map((c) => c.status)).toEqual(['cleared', 'active']);
    expect(carts[1]?.id).toBe([...ids][0]);
    expect(await t.auditRows('cart.cleared', cartId)).toHaveLength(1);
  });

  it('T-KIOSK-054 порядок блокировок «коды → корзина», как у POST /kiosk/orders: сброс во время погашения кода без 40P01', async () => {
    const tab = await t.tablet();
    const cartId = await fillCart(t, tab, variant);
    const code = await requestCode(t, tab, cartId);
    expect((await checkCode(t, tab, code.id, code.code)).kind).toBe('ok');

    // Транзакция заявки (order-create.service.ts, P-002 §8.5 п. 9): строка кода `FOR UPDATE` и `replayed_at` первым
    // действием, затем корзина (`orders.cart_id`, `markConverted` — `FOR UPDATE`). Сброс в это время ждёт строку кода,
    // а не держит корзину: иначе обе транзакции ждали бы друг друга.
    const c = await t.pool.connect();
    let pending: Promise<Res> | undefined;
    try {
      await c.query('BEGIN');
      await c.query(`SELECT id FROM otp_challenges WHERE id = $1 FOR UPDATE`, [code.id]);
      await c.query(`UPDATE otp_challenges SET replayed_at = now(), updated_at = now() WHERE id = $1`, [code.id]);
      pending = reset(t, tab, { cartId });
      await waitForLockWaiters(t, 1);
      await c.query(`SET LOCAL lock_timeout = '5s'`);
      expect(await c.query(`SELECT id FROM carts WHERE id = $1 FOR UPDATE`, [cartId])).toMatchObject({ rowCount: 1 });
      await c.query('COMMIT');
    } catch (e) {
      await c.query('ROLLBACK').catch(() => undefined);
      throw e;
    } finally {
      c.release();
    }

    // сброс завершился после COMMIT заявки: корзина закрыта, код уже погашен заявкой — повторного гашения нет
    const r = await pending;
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect((await cartRows(t, tab.userId)).map((x) => [x.id === cartId, x.status])).toEqual([
      [true, 'cleared'],
      [false, 'active'],
    ]);
    expect(await codeStatus(t, code.id)).toEqual({ status: 'verified', replayed: true });
    expect(await t.auditRows('cart.cleared', cartId)).toEqual([
      expect.objectContaining({ after: expect.objectContaining({ reason: 'kiosk_reset', codesGashed: 0 }) }),
    ]);
  });

  it('отказы: чужая и несуществующая корзина → 404, тело → 400, сотрудник и покупатель → 403; ничего не меняется', async () => {
    const tab = await t.tablet();
    const own = await fillCart(t, tab, variant);
    const other = await t.tablet();
    const otherCart = await fillCart(t, other, variant);
    const sellerCart = await fillCart(t, seller, variant);
    for (const cartId of [otherCart, sellerCart, randomUUID()]) {
      const r = await reset(t, tab, { cartId });
      expect([r.status, r.body.code], cartId).toEqual([404, 'NOT_FOUND']);
    }
    expect((await cartRows(t, other.userId)).map((c) => c.status)).toEqual(['active']);
    expect((await cartRows(t, seller.userId)).map((c) => [c.id, c.status])).toEqual([[sellerCart, 'active']]);

    // OpenAPI KioskResetRequest (additionalProperties: false): 400 VALIDATION_FAILED
    const rule = async (body: unknown) => {
      const r = await reset(t, tab, body);
      expect([r.status, r.body.code], JSON.stringify(body)).toEqual([400, 'VALIDATION_FAILED']);
      return (r.body.errors as { field: string; rule: string }[]).map((e) => `${e.field}:${e.rule}`).sort();
    };
    expect(await rule({})).toEqual(['cartId:uuid']);
    expect(await rule({ cartId: 'not-a-uuid' })).toEqual(['cartId:uuid']);
    expect(await rule({ cartId: own, rowVersion: 3 })).toEqual(['rowVersion:forbidden_field']);
    expect(await rule([{ cartId: own }])).toEqual(['body:type']);

    // Требование — cart.manage.own И kiosk.order.submit: второе право есть только у kind=kiosk (11 SEC-138)
    for (const a of [seller, customer]) {
      const r = await reset(t, a, { cartId: sellerCart });
      expect([r.status, r.body.code, r.body.reason], a.kind).toEqual([403, 'FORBIDDEN', undefined]);
    }
    expect((await cartRows(t, tab.userId)).map((c) => [c.id, c.status])).toEqual([[own, 'active']]);
    expect((await cartRows(t, seller.userId)).map((c) => [c.id, c.status])).toEqual([[sellerCart, 'active']]);
  });

  it('склад планшета не задан → 403 kiosk_warehouse_unavailable до изменений: корзина и код остаются', async () => {
    const tab = await t.tablet();
    const cartId = await fillCart(t, tab, variant);
    const code = await requestCode(t, tab, cartId);
    await t.q(`UPDATE user_profiles SET home_warehouse_id = NULL WHERE user_id = $1`, [tab.userId]);
    const r = await reset(t, tab, { cartId });
    expect([r.status, r.body.code, r.body.reason]).toEqual([403, 'FORBIDDEN', 'kiosk_warehouse_unavailable']);
    expect((await cartRows(t, tab.userId)).map((c) => [c.id, c.status])).toEqual([[cartId, 'active']]);
    expect(await codeStatus(t, code.id)).toEqual({ status: 'sent', replayed: false });
    expect(await t.auditRows('cart.cleared', cartId)).toEqual([]);
  });

  it('паритет: DELETE /cart сотрудника — прежняя очистка с rowVersion (новая пустая корзина), сброс планшета её не меняет', async () => {
    const cartId = await fillCart(t, seller, variant);
    const c = await call(t, 'get', '/cart', seller);
    const r = await call(t, 'delete', `/cart?rowVersion=${String(c.body.rowVersion)}`, seller);
    expect(r.status).toBe(200);
    expect(r.body.id).not.toBe(cartId);
    expect(await t.auditRows('cart.cleared', cartId)).toEqual([
      expect.objectContaining({ after: expect.not.objectContaining({ reason: 'kiosk_reset' }) }),
    ]);
  });
});

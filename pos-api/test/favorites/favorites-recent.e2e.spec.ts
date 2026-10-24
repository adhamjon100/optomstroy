import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import request from 'supertest';
import { RecentProductsService } from '../../src/catalog/recent/recent-products.service.js';
import { validateAgainst } from '../settings/support/openapi-check.js';
import { type Actor, CatalogApiTestApp } from '../catalog-sync/support/catalog-api-app.js';

/**
 * RM-E-006 «Избранное товаров и недавние» (08 §4.4.5, §4.13; 10 FAV-001…FAV-005; 07 DATA-146, DATA-148; T-FAV-001,
 * T-FAV-003, T-FAV-004) на embedded PostgreSQL 17 с синтетическим каталогом (тестовые данные, не реальная 1С).
 */
describe('RM-E-006 избранное товаров и недавние (embedded PG17, синтетический каталог)', () => {
  const t = new CatalogApiTestApp();
  let seller: Actor;
  let cashier: Actor;
  let customer: Actor;
  let products: string[] = [];
  let deletedProduct: string;

  const http = () => request(t.app.getHttpServer());
  const as = (a: Actor, r: request.Test) => r.set('Authorization', `Bearer ${a.token}`).set('X-Device-Id', a.deviceKey);
  const get = (a: Actor, path: string) => as(a, http().get(`/api/v1${path}`));
  const put = (a: Actor, path: string) => as(a, http().put(`/api/v1${path}`));
  const del = (a: Actor, path: string) => as(a, http().delete(`/api/v1${path}`));
  const favCount = async (a: Actor, productId?: string) =>
    (
      await t.rows<{ n: number }>(
        `SELECT count(*)::int AS n FROM favorites_products WHERE user_id = $1 ${productId ? 'AND product_id = $2' : ''}`,
        productId ? [a.userId, productId] : [a.userId],
      )
    )[0].n;
  /** Просмотр карточки (побочный эффект `@RecordsRecentView()`, запись асинхронная) и ожидание записи. */
  const view = async (a: Actor, productId: string) => {
    const before = await t.rows<{ c: number }>(
      `SELECT coalesce(max(view_count), 0)::int AS c FROM recent_products WHERE user_id = $1 AND product_id = $2`,
      [a.userId, productId],
    );
    expect((await get(a, `/test/card/${productId}`)).status).toBe(200);
    for (let i = 0; i < 100; i++) {
      const now = await t.rows<{ c: number }>(
        `SELECT coalesce(max(view_count), 0)::int AS c FROM recent_products WHERE user_id = $1 AND product_id = $2`,
        [a.userId, productId],
      );
      if (now[0].c > before[0].c) return;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error('просмотр не записан');
  };

  beforeAll(async () => {
    await t.start('pos_favorites', { skuCount: 120 });
    seller = await t.actor('seller');
    cashier = await t.actor('cashier');
    customer = await t.actor('customer');
    products = (await t.rows<{ id: string }>('SELECT id FROM products WHERE NOT deletion_mark ORDER BY name, id')).map(
      (r) => r.id,
    );
    deletedProduct = (await t.rows<{ id: string }>('SELECT id FROM products WHERE deletion_mark LIMIT 1'))[0]?.id;
    if (!deletedProduct) {
      deletedProduct = products.pop()!;
      await t.f.pool.query('UPDATE products SET deletion_mark = true WHERE id = $1', [deletedProduct]);
    }
    expect(products.length).toBeGreaterThan(60);
  });

  afterAll(async () => {
    await t.stop();
  });

  describe('избранное', () => {
    it('T-FAV-001: двойной PUT → 204, 204 и одна строка; двойной DELETE → 204, 204 и ноль строк', async () => {
      const p = products[0];
      const r1 = await put(seller, `/favorites/products/${p}`);
      const r2 = await put(seller, `/favorites/products/${p}`);
      expect([r1.status, r2.status]).toEqual([204, 204]);
      expect(r1.headers['cache-control']).toBe('no-store');
      expect(await favCount(seller, p)).toBe(1);
      const d1 = await del(seller, `/favorites/products/${p}`);
      const d2 = await del(seller, `/favorites/products/${p}`);
      expect([d1.status, d2.status]).toEqual([204, 204]);
      expect(await favCount(seller, p)).toBe(0);
    });

    // 12 T-FAV-007 (10 FAV-008, 07 DATA-022): избранное — данные POS, в 1С не уходит и из 1С не загружается.
    it('T-FAV-007: PUT/DELETE избранного не создают записей onec_outbox; конвейер 1С не пишет favorites_products', async () => {
      const outboxBefore = (await t.rows<{ n: number }>('SELECT count(*)::int AS n FROM onec_outbox'))[0].n;
      const p = products[2];
      expect((await put(cashier, `/favorites/products/${p}`)).status).toBe(204);
      expect((await del(cashier, `/favorites/products/${p}`)).status).toBe(204);
      expect((await put(cashier, `/favorites/products/${p}`)).status).toBe(204);
      expect((await t.rows<{ n: number }>('SELECT count(*)::int AS n FROM onec_outbox'))[0].n).toBe(outboxBefore);
      const applyDir = fileURLToPath(new URL('../../src/sync/', import.meta.url));
      const syncSources = readdirSync(applyDir, { recursive: true, encoding: 'utf8' })
        .filter((f) => f.endsWith('.ts'))
        .map((f) => readFileSync(join(applyDir, f), 'utf8'));
      expect(syncSources.length).toBeGreaterThan(10);
      expect(syncSources.filter((s) => s.includes('favorites_products'))).toEqual([]);
      await del(cashier, `/favorites/products/${p}`);
    });

    it('повтор PUT с Idempotency-Key и без него — один результат (outbox клиента повторяет без ключа)', async () => {
      const p = products[1];
      const key = '0b8e5f3c-3a3b-4c6d-9e1f-2a3b4c5d6e7f';
      expect((await put(customer, `/favorites/products/${p}`).set('Idempotency-Key', key)).status).toBe(204);
      const replay = await put(customer, `/favorites/products/${p}`).set('Idempotency-Key', key);
      expect(replay.status).toBe(204);
      expect(replay.headers['idempotent-replayed']).toBe('true');
      expect((await put(customer, `/favorites/products/${p}`)).status).toBe(204);
      expect(await favCount(customer, p)).toBe(1);
      expect((await del(customer, `/favorites/products/${p}`)).status).toBe(204);
    });

    it('несуществующий товар → 404 NOT_FOUND; неверный id → 400; снятый с продажи: staff — 204, customer — 404', async () => {
      const missing = '01920000-0000-7000-8000-000000000000';
      for (const r of [
        await put(seller, `/favorites/products/${missing}`),
        await del(seller, `/favorites/products/${missing}`),
      ]) {
        expect(r.status).toBe(404);
        expect(r.body.code).toBe('NOT_FOUND');
      }
      const bad = await put(seller, '/favorites/products/not-a-uuid');
      expect(bad.status).toBe(400);
      expect(bad.body.errors[0]).toMatchObject({ field: 'id', rule: 'uuid' });
      expect((await put(seller, `/favorites/products/${deletedProduct}`)).status).toBe(204);
      expect((await put(customer, `/favorites/products/${deletedProduct}`)).status).toBe(404);
      expect((await del(seller, `/favorites/products/${deletedProduct}`)).status).toBe(204);
    });

    it('GET /favorites/products: новые сверху, страницы по курсору, count без снятых с продажи (T-FAV-003), только свой список', async () => {
      const mine = products.slice(10, 17);
      for (const p of mine) {
        expect((await put(cashier, `/favorites/products/${p}`)).status).toBe(204);
        await new Promise((r) => setTimeout(r, 3));
      }
      expect((await put(cashier, `/favorites/products/${deletedProduct}`)).status).toBe(204);
      expect((await put(seller, `/favorites/products/${products[30]}`)).status).toBe(204);
      const first = await get(cashier, '/favorites/products?limit=4');
      expect(first.status).toBe(200);
      expect(first.headers['cache-control']).toBe('no-store');
      expect(first.body.count).toBe(mine.length);
      expect(first.body.hasMore).toBe(true);
      expect(typeof first.body.nextCursor).toBe('string');
      const second = await get(
        cashier,
        `/favorites/products?limit=4&cursor=${encodeURIComponent(first.body.nextCursor)}`,
      );
      expect(second.status).toBe(200);
      expect(second.body.hasMore).toBe(false);
      expect(second.body.nextCursor).toBeNull();
      const order = [...first.body.items, ...second.body.items].map((i: { id: string }) => i.id);
      expect(order).toEqual([...mine].reverse());
      for (const item of [...first.body.items, ...second.body.items]) {
        expect(item.isFavorite).toBe(true);
        expect(validateAgainst('ProductSummary', item, false)).toEqual([]);
      }
      const bad = await get(cashier, '/favorites/products?cursor=abc');
      expect(bad.status).toBe(400);
      expect(bad.body.errors[0]).toMatchObject({ rule: 'cursor' });
      expect((await get(cashier, '/favorites/products?limit=201')).status).toBe(400);
    });
  });

  describe('недавние', () => {
    it('запись при просмотре карточки; GET упорядочен по времени просмотра (повторный просмотр поднимает товар); маршрут products/recent не перехватывается products/:id', async () => {
      const [a, b, c] = products.slice(40, 43);
      await view(seller, a);
      await view(seller, b);
      await view(seller, c);
      await view(seller, a);
      const r = await get(seller, '/catalog/products/recent');
      expect(r.status).toBe(200);
      expect(r.headers['cache-control']).toBe('no-store');
      expect((r.body.items as { id: string }[]).map((i) => i.id)).toEqual([a, c, b]);
      for (const item of r.body.items) {
        expect(validateAgainst('CatalogRecentProduct', item, false)).toEqual([]);
        expect(Date.parse(item.viewedAt)).not.toBeNaN();
      }
      const counts = await t.rows<{ product_id: string; view_count: number }>(
        'SELECT product_id, view_count FROM recent_products WHERE user_id = $1',
        [seller.userId],
      );
      expect(counts.find((x) => x.product_id === a)?.view_count).toBe(2);
      // Ошибка карточки (несуществующий товар) отметку не создаёт — тест-карточка отвечает 200, сервис отказывает.
      expect(
        await t.app.get(RecentProductsService).recordView(seller.userId, '01920000-0000-7000-8000-000000000001'),
      ).toBe(false);
    });

    it('T-FAV-004: 55 просмотров → на сервере ≤ 50 последних (N по умолчанию); limit 1…50 (по умолчанию 20); N из app_settings ограничивает список', async () => {
      const svc = t.app.get(RecentProductsService);
      const viewed = products.slice(0, 55);
      for (const p of viewed) {
        expect(await svc.recordView(cashier.userId, p)).toBe(true);
      }
      const stored = await t.rows<{ n: number }>('SELECT count(*)::int AS n FROM recent_products WHERE user_id = $1', [
        cashier.userId,
      ]);
      expect(stored[0].n).toBe(50);
      const dflt = await get(cashier, '/catalog/products/recent');
      expect(dflt.body.items).toHaveLength(20);
      const all = await get(cashier, '/catalog/products/recent?limit=50');
      expect((all.body.items as { id: string }[]).map((i) => i.id)).toEqual([...viewed].reverse().slice(0, 50));
      for (const limit of ['0', '51', 'x']) {
        const r = await get(cashier, `/catalog/products/recent?limit=${limit}`);
        expect(r.status, limit).toBe(400);
        expect(r.body.errors[0]).toMatchObject({ field: 'limit', rule: 'limit' });
      }
      await t.setSetting('recent_products.max_items', 5, 'integer');
      try {
        const capped = await get(cashier, '/catalog/products/recent?limit=50');
        expect((capped.body.items as { id: string }[]).map((i) => i.id)).toEqual([...viewed].reverse().slice(0, 5));
        await svc.recordView(cashier.userId, products[60]);
        const left = await t.rows<{ n: number }>('SELECT count(*)::int AS n FROM recent_products WHERE user_id = $1', [
          cashier.userId,
        ]);
        expect(left[0].n).toBe(5);
      } finally {
        await t.f.pool.query(`DELETE FROM app_settings WHERE key = 'recent_products.max_items'`);
        t.app.get((await import('../../src/common/settings/settings-reader.js')).SettingsReader).invalidate();
      }
    });

    it('снятый с продажи товар не показывается; список — только свой', async () => {
      const svc = t.app.get(RecentProductsService);
      await svc.recordView(customer.userId, products[70]);
      await svc.recordView(customer.userId, deletedProduct);
      const r = await get(customer, '/catalog/products/recent');
      expect(r.status).toBe(200);
      expect((r.body.items as { id: string }[]).map((i) => i.id)).toEqual([products[70]]);
      const other = await get(seller, '/catalog/products/recent');
      expect((other.body.items as { id: string }[]).map((i) => i.id)).not.toContain(products[70]);
    });

    it('DELETE /catalog/products/recent очищает список и идемпотентен (204, 204); чужие списки не затронуты', async () => {
      const before = await t.rows<{ n: number }>('SELECT count(*)::int AS n FROM recent_products WHERE user_id <> $1', [
        cashier.userId,
      ]);
      const d1 = await del(cashier, '/catalog/products/recent');
      const d2 = await del(cashier, '/catalog/products/recent');
      expect([d1.status, d2.status]).toEqual([204, 204]);
      expect((await get(cashier, '/catalog/products/recent')).body.items).toEqual([]);
      const after = await t.rows<{ n: number }>('SELECT count(*)::int AS n FROM recent_products WHERE user_id <> $1', [
        cashier.userId,
      ]);
      expect(after[0].n).toBe(before[0].n);
      expect(after[0].n).toBeGreaterThan(0);
    });

    it('без Bearer → 401; роль integration → 403', async () => {
      expect((await http().get('/api/v1/catalog/products/recent')).status).toBe(401);
      expect((await http().put(`/api/v1/favorites/products/${products[0]}`)).status).toBe(401);
      const integration = await t.actor('integration');
      expect((await get(integration, '/catalog/products/recent')).status).toBe(403);
      expect((await put(integration, `/favorites/products/${products[0]}`)).status).toBe(403);
      expect((await get(integration, '/favorites/products')).status).toBe(403);
    });
  });
});

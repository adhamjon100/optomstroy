import pg from 'pg';
import pino from 'pino';
import request from 'supertest';
import { CatalogSyncCursorCodec } from '../../src/catalog/sync/catalog-sync.cursor.js';
import { CatalogSyncService, scopeFingerprint } from '../../src/catalog/sync/catalog-sync.service.js';
import { CATALOG_SYNC_ENTITIES, type CatalogSyncEntity } from '../../src/catalog/sync/catalog-sync.types.js';
import { CatalogViewerService } from '../../src/catalog/common/catalog-viewer.js';
import { CatalogSnapshotService } from '../../src/catalog/common/catalog-snapshot.js';
import type { PermissionCatalog } from '../../src/common/rbac/permission-catalog.js';
import { PG_POOL } from '../../src/common/db/database.module.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { OnecChangesService } from '../../src/sync/apply/onec-changes.service.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import { contract, validateAgainst } from '../settings/support/openapi-check.js';
import { type Actor, CatalogApiTestApp } from './support/catalog-api-app.js';

/**
 * RM-E-015 `GET /catalog/sync/{entity}` (08 §4.24, ядро §22.7; T-CAT-034, AC-API-171) на embedded PostgreSQL 17 со
 * всеми миграциями и синтетическим каталогом (200 SKU + фикстуры 1С; конвейер применения на FakeOnecGateway).
 * **Тестовые данные** — не реальная интеграция с 1С.
 */
const TOP_KEYS = ['deleted', 'hasMore', 'items', 'nextCursor', 'serverTime'];
const ENTITY_SCHEMA = (
  contract().components.schemas.CatalogSyncResponse as unknown as { 'x-entity-schema': Record<string, string> }
)['x-entity-schema'];

interface Page {
  items: Record<string, unknown>[];
  deleted: string[];
  nextCursor: string;
  hasMore: boolean;
  serverTime: string;
}

describe('RM-E-015 GET /catalog/sync/{entity} (embedded PG17, синтетический каталог)', () => {
  const t = new CatalogApiTestApp();
  let admin: Actor;
  let seller: Actor;
  let cashier: Actor;
  let customer: Actor;

  const http = () => request(t.app.getHttpServer());
  const get = (a: Actor, path: string, headers: Record<string, string> = {}) => {
    let r = http().get(`/api/v1${path}`).set('Authorization', `Bearer ${a.token}`).set('X-Device-Id', a.deviceKey);
    for (const [k, v] of Object.entries(headers)) r = r.set(k, v);
    return r;
  };
  const url = (entity: string, q: { since?: string; limit?: number; warehouseId?: string } = {}) => {
    const p = new URLSearchParams();
    if (q.since !== undefined) p.set('since', q.since);
    if (q.limit !== undefined) p.set('limit', String(q.limit));
    if (q.warehouseId !== undefined) p.set('warehouseId', q.warehouseId);
    const s = p.toString();
    return `/catalog/sync/${entity}${s ? `?${s}` : ''}`;
  };
  const keyOf = (entity: string, item: Record<string, unknown>) =>
    entity === 'stock' ? `${String(item.variantId)}:${String(item.warehouseId)}` : String(item.id);

  async function page(a: Actor, entity: string, q: { since?: string; limit?: number; warehouseId?: string } = {}) {
    const r = await get(a, url(entity, q));
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(TOP_KEYS);
    expect(typeof r.body.nextCursor).toBe('string');
    expect(r.body.items.length).toBeLessThanOrEqual(q.limit ?? 200);
    return r.body as Page;
  }

  /** Выгрузка страницами до hasMore=false; возвращает все элементы, удаления и последний курсор. */
  async function loadAll(
    a: Actor,
    entity: string,
    opts: { since?: string; limit?: number; warehouseId?: string } = {},
  ) {
    const items: Record<string, unknown>[] = [];
    const deleted: string[] = [];
    let since = opts.since;
    let pages = 0;
    for (;;) {
      const p = await page(a, entity, { ...opts, ...(since !== undefined ? { since } : {}) });
      pages += 1;
      items.push(...p.items);
      deleted.push(...p.deleted);
      since = p.nextCursor;
      if (!p.hasMore) break;
      if (pages > 2000) throw new Error('слишком много страниц');
    }
    return { items, deleted, cursor: since, pages };
  }

  const ids = async (text: string, params: unknown[] = []) =>
    (await t.rows<{ id: string }>(text, params)).map((r) => r.id).sort();

  beforeAll(async () => {
    await t.start('pos_catalog_sync', { skuCount: 200 });
    admin = await t.actor('admin');
    seller = await t.actor('seller');
    cashier = await t.actor('cashier');
    customer = await t.actor('customer');
  });

  afterAll(async () => {
    await t.stop();
  });

  it('критерий 1 + 2: каждая из 12 сущностей — тело ровно {items, deleted, nextCursor, hasMore, serverTime}, выгрузка страницами по 200 до hasMore=false = вся реплика без дублей, элементы — по схеме контракта', async () => {
    const expected: Record<CatalogSyncEntity, { live: string; dead?: string }> = {
      units: { live: 'SELECT id FROM units WHERE NOT deletion_mark', dead: 'SELECT id FROM units WHERE deletion_mark' },
      warehouses: {
        live: 'SELECT id FROM warehouses WHERE NOT deletion_mark',
        dead: 'SELECT id FROM warehouses WHERE deletion_mark',
      },
      categories: {
        live: 'SELECT id FROM categories WHERE NOT deletion_mark',
        dead: 'SELECT id FROM categories WHERE deletion_mark',
      },
      products: {
        live: 'SELECT id FROM products WHERE NOT deletion_mark',
        dead: 'SELECT id FROM products WHERE deletion_mark',
      },
      variants: {
        live: 'SELECT id FROM product_variants WHERE NOT deletion_mark',
        dead: 'SELECT id FROM product_variants WHERE deletion_mark',
      },
      packagings: {
        live: 'SELECT id FROM packagings WHERE product_id IS NOT NULL AND NOT deletion_mark',
        dead: 'SELECT id FROM packagings WHERE product_id IS NOT NULL AND deletion_mark',
      },
      barcodes: {
        live: 'SELECT id FROM barcodes WHERE NOT deletion_mark',
        dead: 'SELECT id FROM barcodes WHERE deletion_mark',
      },
      price_lists: { live: 'SELECT id FROM price_lists WHERE NOT deletion_mark' },
      prices: {
        live: `SELECT p.id FROM prices p JOIN price_lists l ON l.id = p.price_list_id WHERE NOT l.deletion_mark`,
      },
      stock: {
        live: `SELECT s.variant_id || ':' || s.warehouse_id AS id FROM stock_balances s
                 JOIN warehouses w ON w.id = s.warehouse_id WHERE w.is_active AND NOT w.deletion_mark`,
      },
      attributes: {
        live: 'SELECT id FROM product_attributes WHERE NOT deletion_mark',
        dead: 'SELECT id FROM product_attributes WHERE deletion_mark',
      },
      images: {
        live: `SELECT id FROM product_images WHERE product_id IS NOT NULL AND deleted_at IS NULL AND status = 'ready'
                 AND checksum_sha256 IS NOT NULL`,
      },
    };
    const report: Record<string, { items: number; deleted: number; pages: number }> = {};
    for (const entity of CATALOG_SYNC_ENTITIES) {
      const all = await loadAll(admin, entity, { limit: 200 });
      const keys = all.items.map((i) => keyOf(entity, i));
      expect(new Set(keys).size, `${entity}: дубли в items`).toBe(keys.length);
      expect(new Set(all.deleted).size, `${entity}: дубли в deleted`).toBe(all.deleted.length);
      expect(keys.sort(), `${entity}: items = реплика`).toEqual(await ids(expected[entity].live));
      expect(all.deleted.sort(), `${entity}: deleted = помеченные`).toEqual(
        expected[entity].dead ? await ids(expected[entity].dead) : [],
      );
      const schema = ENTITY_SCHEMA[entity].replace('#/components/schemas/', '');
      for (const item of all.items) {
        expect(validateAgainst(schema, item, false), `${entity}: ${JSON.stringify(item)}`).toEqual([]);
      }
      report[entity] = { items: all.items.length, deleted: all.deleted.length, pages: all.pages };
    }
    // Фикстура достаточно велика, чтобы выгрузка шла несколькими страницами по 200.
    expect(report.prices.pages).toBeGreaterThan(1);
    expect(report.stock.pages).toBeGreaterThan(1);
    expect(report.barcodes.pages).toBeGreaterThan(1);
    expect(report.products.deleted).toBeGreaterThan(0);
  });

  it('штрихкоды (AC-API-171): страницы по 200 → все штрихкоды фикстуры, последняя страница hasMore=false с nextCursor; деньги и количества — строки', async () => {
    const all = await loadAll(admin, 'barcodes', { limit: 200 });
    const values = (await t.rows<{ value: string }>('SELECT value FROM barcodes WHERE NOT deletion_mark')).map(
      (r) => r.value,
    );
    expect(all.items.map((i) => i.barcode).sort()).toEqual(values.sort());
    const last = await page(admin, 'barcodes', { since: all.cursor });
    expect(last).toMatchObject({ items: [], deleted: [], hasMore: false });
    const prices = await page(admin, 'prices', { limit: 5 });
    for (const p of prices.items) {
      expect(p.price).toEqual({ amount: expect.stringMatching(/^\d+\.\d{2}$/), currency: 'KGS' });
    }
    const stock = await page(admin, 'stock', { limit: 5 });
    for (const s of stock.items) expect(s.available).toMatch(/^-?\d+\.\d{3}$/);
  });

  it('критерий 2: изменения после курсора приходят в items, помеченный на удаление — в deleted[] (изменение 3 товаров и пометка 1 через конвейер 1С)', async () => {
    const start = await loadAll(admin, 'products');
    const m = t.f.gateway.mutateCatalog({ renameProducts: 3 });
    const d = t.f.gateway.mutateCatalog({ deleteProducts: 1 });
    const changes = new OnecChangesService(
      t.f.pool,
      t.f.gateway,
      new CatalogApplier(),
      createRunTracker(t.f.pool),
      pino({ level: 'silent' }),
      { pageSize: 1000, reconcileWithHealth: true },
    );
    const r = await changes.pullOnce();
    expect(r.status).toBe('applied');
    const refOf = (keys: readonly string[]) =>
      keys.filter((k) => k.startsWith('Catalog_Номенклатура:')).map((k) => k.split(':')[1]);
    const renamed = await ids(`SELECT id FROM products WHERE onec_ref = ANY($1::uuid[])`, [refOf(m.changedKeys)]);
    const removed = await ids(`SELECT id FROM products WHERE onec_ref = ANY($1::uuid[])`, [refOf(d.changedKeys)]);
    expect(renamed).toHaveLength(3);
    expect(removed).toHaveLength(1);
    const inc = await loadAll(admin, 'products', { since: start.cursor });
    expect(inc.items.map((i) => String(i.id)).sort()).toEqual(renamed.filter((id) => !removed.includes(id)));
    expect(inc.deleted).toEqual(removed);
    // Повтор с тем же since → те же строки (критерий 4).
    const again = await loadAll(admin, 'products', { since: start.cursor });
    expect(again.items).toEqual(inc.items);
    expect(again.deleted).toEqual(inc.deleted);
  });

  it('одинаковый updated_at у сотен строк (одна транзакция) не теряет и не дублирует строки при limit=7', async () => {
    const base = await loadAll(admin, 'variants');
    const client = new pg.Client({ connectionString: t.f.url });
    await client.connect();
    try {
      await client.query('BEGIN');
      await client.query(`UPDATE product_variants SET sort_order = sort_order WHERE id IN (
                            SELECT id FROM product_variants ORDER BY id DESC LIMIT 150)`);
      await client.query('COMMIT');
    } finally {
      await client.end();
    }
    const touched = await t.rows<{ n: string; ts: number }>(
      `SELECT count(*)::text AS n, count(DISTINCT updated_at)::int AS ts FROM product_variants
        WHERE id IN (SELECT id FROM product_variants ORDER BY id DESC LIMIT 150)`,
    );
    expect(touched[0]).toEqual({ n: '150', ts: 1 });
    const inc = await loadAll(admin, 'variants', { since: base.cursor, limit: 7 });
    // Варианты, помеченные на удаление (служебные варианты удалённых товаров), приходят в deleted[].
    const got = [...inc.items.map((i) => String(i.id)), ...inc.deleted];
    expect(new Set(got).size).toBe(got.length);
    expect(got.sort()).toEqual(await ids('SELECT id FROM product_variants ORDER BY id DESC LIMIT 150'));
    expect(inc.pages).toBe(22); // ⌈150 / 7⌉, последняя страница — 3 строки и hasMore=false
  });

  it('строка, изменённая во время постраничной выгрузки, не теряется: уже выданная приходит в следующем инкременте, ещё не выданная — один раз', async () => {
    const total = await ids('SELECT id FROM products');
    const first = await page(admin, 'products', { limit: 50 });
    const second = await page(admin, 'products', { limit: 50, since: first.nextCursor });
    const delivered = String(first.items[0].id);
    const seen = new Set([...first.items, ...second.items].map((i) => String(i.id)));
    const pending = total.find((id) => !seen.has(id) && !first.deleted.includes(id) && !second.deleted.includes(id))!;
    await t.f.pool.query(`UPDATE products SET brand = coalesce(brand, '') || '' WHERE id = ANY($1::uuid[])`, [
      [delivered, pending],
    ]);
    const rest = await loadAll(admin, 'products', { limit: 50, since: second.nextCursor });
    const keys = [first, second].flatMap((p) => [...p.items.map((i) => String(i.id)), ...p.deleted]);
    keys.push(...rest.items.map((i) => String(i.id)), ...rest.deleted);
    // Все товары выданы (уже выданный — повторно, после изменения), ни один не потерян.
    expect(new Set(keys)).toEqual(new Set(total));
    expect(keys.filter((k) => k === pending)).toHaveLength(1);
    expect(keys.filter((k) => k === delivered)).toHaveLength(2);
    const inc = await loadAll(admin, 'products', { since: rest.cursor });
    expect(inc.items).toEqual([]);
  });

  it('горизонт: строка незавершённой транзакции, начатой раньше зафиксированной, не теряется (курсор не перескакивает)', async () => {
    const base = await loadAll(admin, 'products');
    const [a, b] = await ids('SELECT id FROM products WHERE NOT deletion_mark ORDER BY id LIMIT 2');
    const slow = new pg.Client({ connectionString: t.f.url });
    await slow.connect();
    try {
      await slow.query('BEGIN');
      await slow.query(`UPDATE products SET brand = coalesce(brand, '') || '' WHERE id = $1`, [a]); // updated_at = T0
      await new Promise((r) => setTimeout(r, 20));
      await t.f.pool.query(`UPDATE products SET brand = coalesce(brand, '') || '' WHERE id = $1`, [b]); // T1 > T0, COMMIT
      const during = await loadAll(admin, 'products', { since: base.cursor });
      // b (T1) зафиксирована, но старше горизонта (T0) — не выдаётся, курсор остаётся до T0.
      expect(during.items.map((i) => i.id)).toEqual([]);
      await slow.query('COMMIT');
      const after = await loadAll(admin, 'products', { since: during.cursor });
      expect(after.items.map((i) => String(i.id)).sort()).toEqual([a, b].sort());
    } finally {
      await slow.end();
    }
  });

  it('физически удалённая цена (срез цен) приходит в deleted[] prices; повтор since → те же строки; If-None-Match → 304', async () => {
    const base = await loadAll(admin, 'prices');
    const [victim] = await ids('SELECT id FROM prices ORDER BY id LIMIT 1');
    await t.f.pool.query('DELETE FROM prices WHERE id = $1', [victim]);
    const r1 = await get(admin, url('prices', { since: base.cursor }));
    expect(r1.status).toBe(200);
    expect(r1.body.deleted).toEqual([victim]);
    expect(r1.body.items).toEqual([]);
    expect(r1.headers['cache-control']).toBe('private, no-cache');
    expect(r1.headers.etag).toMatch(/^W\/".+"$/);
    expect(r1.headers['x-data-as-of']).toBeDefined();
    const r2 = await get(admin, url('prices', { since: base.cursor }));
    expect(r2.body.deleted).toEqual(r1.body.deleted);
    expect(r2.headers.etag).toBe(r1.headers.etag);
    const r3 = await get(admin, url('prices', { since: base.cursor }), { 'If-None-Match': r1.headers.etag });
    expect(r3.status).toBe(304);
    // Пустой инкремент: тот же ETag при повторе → 304.
    const empty = await get(admin, url('prices', { since: r1.body.nextCursor }));
    expect(empty.body).toMatchObject({ items: [], deleted: [], hasMore: false });
    const empty304 = await get(admin, url('prices', { since: r1.body.nextCursor }), {
      'If-None-Match': empty.headers.etag,
    });
    expect(empty304.status).toBe(304);
  });

  it('критерий 3: prices/price_lists — только виды цен, разрешённые роли (seller — visible_to_roles; cashier — все; customer — только свой вид цены)', async () => {
    const lists = await t.rows<{ id: string; name: string }>(
      'SELECT id, name FROM price_lists WHERE NOT deletion_mark ORDER BY sort_order, name',
    );
    expect(lists.length).toBeGreaterThanOrEqual(3);
    const hidden = lists.find((l) => /Крупный/.test(l.name)) ?? lists[lists.length - 1];
    const beforeSeller = await loadAll(seller, 'price_lists');
    await t.f.pool.query(
      `UPDATE price_lists SET visible_to_roles = '{cashier,senior_seller,admin,owner}' WHERE id = $1`,
      [hidden.id],
    );
    const sellerLists = await loadAll(seller, 'price_lists');
    expect(sellerLists.items.map((i) => i.id)).not.toContain(hidden.id);
    expect(sellerLists.items).toHaveLength(lists.length - 1);
    // Инкремент seller со старым курсором: область видимости (набор видов цен) изменилась → 409 cursor_expired,
    // клиент загружает сущность заново (ревью E-api-3; полная выгрузка выше уже не содержит скрытый вид цены).
    const sellerInc = await get(seller, url('price_lists', { since: beforeSeller.cursor }));
    expect(sellerInc.status).toBe(409);
    expect(sellerInc.body).toMatchObject({ code: 'VERSION_CONFLICT', reason: 'cursor_expired' });
    const sellerPrices = await loadAll(seller, 'prices');
    expect(sellerPrices.items.length).toBeGreaterThan(0);
    expect(sellerPrices.items.every((p) => p.priceListId !== hidden.id)).toBe(true);
    const expectedSeller = await ids(`SELECT id FROM prices WHERE price_list_id <> $1`, [hidden.id]);
    expect(sellerPrices.items.map((p) => String(p.id)).sort()).toEqual(expectedSeller);

    const cashierLists = await loadAll(cashier, 'price_lists');
    expect(cashierLists.items.map((i) => i.id)).toContain(hidden.id);
    const cashierPrices = await loadAll(cashier, 'prices');
    expect(cashierPrices.items.length).toBe((await ids('SELECT id FROM prices')).length);

    const customerLists = await loadAll(customer, 'price_lists');
    expect(customerLists.items).toHaveLength(1);
    const own = String(customerLists.items[0].id);
    const customerPrices = await loadAll(customer, 'prices');
    expect(customerPrices.items.every((p) => p.priceListId === own)).toBe(true);
    expect(customerPrices.items.length).toBe(
      (await ids('SELECT id FROM prices WHERE price_list_id = $1', [own])).length,
    );
  });

  it('ревью E-api-3: курсор привязан к области видимости — подтверждение привязки клиента (другой вид цены) и смена customer_stock_display → 409 cursor_expired; полная перезагрузка — только новый вид цены', async () => {
    const client = await t.actor('customer');
    const lists = await t.rows<{ id: string; name: string }>(
      'SELECT id, name FROM price_lists WHERE NOT deletion_mark',
    );
    const before = await loadAll(client, 'prices');
    const own = new Set(before.items.map((p) => String(p.priceListId)));
    expect(own.size).toBe(1);
    const other = lists.find((l) => !own.has(l.id) && /Оптов/.test(l.name)) ?? lists.find((l) => !own.has(l.id))!;
    const listsBefore = await loadAll(client, 'price_lists');
    // Привязка к карточке клиента 1С подтверждена (CUST-021): вид цены клиента — `other`.
    const c = await t.rows<{ id: string }>(
      `INSERT INTO customers (onec_ref, onec_code, source, name, customer_type, synced_at, source_hash, onec_status,
                              default_price_list_id)
       VALUES (gen_random_uuid(), 'T-EAPI3', 'onec', 'Тестовый клиент', 'individual', now(), 'test', 'n_a', $1::uuid)
       RETURNING id`,
      [other.id],
    );
    await t.rows(
      `INSERT INTO customer_links (user_id, customer_id, status, match_method, matched_phone_e164, confirmed_at)
       VALUES ($1::uuid, $2::uuid, 'confirmed', 'phone', '+996700000998', now())`,
      [client.userId, c[0].id],
    );
    for (const [entity, cursor] of [
      ['prices', before.cursor],
      ['price_lists', listsBefore.cursor],
    ] as const) {
      const inc = await get(client, url(entity, { since: cursor }));
      expect(inc.status, entity).toBe(409);
      expect(inc.body, entity).toMatchObject({ code: 'VERSION_CONFLICT', reason: 'cursor_expired' });
    }
    const reloaded = await loadAll(client, 'prices');
    expect(new Set(reloaded.items.map((p) => String(p.priceListId)))).toEqual(new Set([other.id]));
    expect(reloaded.items.length).toBe(
      (await ids('SELECT id FROM prices WHERE price_list_id = $1', [other.id])).length,
    );
    // Инкремент с новым курсором работает.
    expect((await get(client, url('prices', { since: reloaded.cursor }))).status).toBe(200);

    // Режим остатков клиента: status → quantity — старый курсор stock недействителен.
    await t.setSetting('customer_stock_display', 'status', 'string');
    const stock = await loadAll(client, 'stock', { limit: 200 });
    await t.setSetting('customer_stock_display', 'quantity', 'string');
    const stale = await get(client, url('stock', { since: stock.cursor }));
    expect(stale.status).toBe(409);
    expect(stale.body.reason).toBe('cursor_expired');
    await t.setSetting('customer_stock_display', 'status', 'string');
    expect((await get(client, url('stock', { since: stock.cursor }))).status).toBe(200);
  });

  // 12 T-CAT-032, T-CAT-036 (офлайн-выгрузка остатков клиента)
  it('stock для customer — по customer_stock_display: status — без количеств; quantity — плюс available; staff — все поля; warehouseId фильтрует', async () => {
    const wh = (
      await t.rows<{ id: string }>('SELECT id FROM warehouses WHERE is_active ORDER BY sort_order, name LIMIT 1')
    )[0].id;
    await t.setSetting('customer_stock_display', 'status', 'string');
    const status = await page(customer, 'stock', { limit: 20, warehouseId: wh });
    expect(status.items.length).toBeGreaterThan(0);
    for (const s of status.items) {
      expect(s.warehouseId).toBe(wh);
      expect(Object.keys(s).sort()).toEqual(
        ['asOf', 'stockLevel', 'variantId', 'warehouseId', 'warehouseName'].filter((k) => k in s).sort(),
      );
      expect(s).not.toHaveProperty('quantity');
      expect(s).not.toHaveProperty('reserved');
      expect(s).not.toHaveProperty('available');
      expect(['in_stock', 'low', 'out', 'unknown']).toContain(s.stockLevel);
    }
    await t.setSetting('customer_stock_display', 'quantity', 'string');
    const qty = await page(customer, 'stock', { limit: 20, warehouseId: wh });
    for (const s of qty.items) {
      expect(s).toHaveProperty('available');
      expect(s).not.toHaveProperty('quantity');
      expect(s).not.toHaveProperty('reserved');
    }
    const staff = await page(seller, 'stock', { limit: 20, warehouseId: wh });
    for (const s of staff.items)
      expect(Object.keys(s)).toEqual(expect.arrayContaining(['quantity', 'reserved', 'available', 'stockLevel']));
    await t.setSetting('customer_stock_display', 'status', 'string');
    const unknown = await get(seller, url('stock', { warehouseId: '00000000-0000-4000-8000-000000000000' }));
    expect(unknown.status).toBe(400);
    expect(unknown.body.errors[0]).toMatchObject({ field: 'warehouseId', rule: 'unknown_reference' });
  });

  it('критерий 1: entity=customers, limit=201, limit=0, подделанный since, курсор другой сущности → 400 VALIDATION_FAILED (enum / limit / cursor); курсор старше 30 дней → 409 cursor_expired', async () => {
    const bad = await get(admin, '/catalog/sync/customers');
    expect(bad.status).toBe(400);
    expect(bad.body).toMatchObject({ code: 'VALIDATION_FAILED', errors: [{ field: 'entity', rule: 'enum' }] });
    for (const limit of ['201', '0', 'abc']) {
      const r = await get(admin, `/catalog/sync/products?limit=${limit}`);
      expect(r.status, limit).toBe(400);
      expect(r.body.errors[0], limit).toMatchObject({ field: 'limit', rule: 'limit' });
    }
    const ok = await page(admin, 'products', { limit: 1 });
    const [body, sig] = ok.nextCursor.split('.');
    const tampered = Buffer.from(
      Buffer.from(body, 'base64url')
        .toString('utf8')
        .replace(/"t":\d+/, '"t":1'),
      'utf8',
    ).toString('base64url');
    for (const since of [
      `${tampered}.${sig}`,
      `${body}.x${sig.slice(1)}`,
      'garbage',
      ok.nextCursor.replace('.', '..'),
    ]) {
      const r = await get(admin, url('products', { since }));
      expect(r.status, since).toBe(400);
      expect(r.body.errors[0], since).toMatchObject({ field: 'since', rule: 'cursor' });
    }
    const foreign = await get(admin, url('variants', { since: ok.nextCursor }));
    expect(foreign.status).toBe(400);
    expect(foreign.body.errors[0]).toMatchObject({ rule: 'cursor' });
    const codec = t.app.get(CatalogSyncCursorCodec);
    const old = codec.encode(
      'products',
      { ts: '2026-01-01T00:00:00.000000Z', key: ['00000000-0000-0000-0000-000000000000'] },
      Date.now() - 31 * 24 * 3600_000,
    );
    const expired = await get(admin, url('products', { since: old }));
    expect(expired.status).toBe(409);
    expect(expired.body).toMatchObject({ code: 'VERSION_CONFLICT', reason: 'cursor_expired' });
    // Курсор несёт отпечаток области видимости зрителя (ревью E-api-3): без него / с чужим — 409 cursor_expired.
    const adminScope = scopeFingerprint(
      'products',
      { role: 'admin', stockDisplay: 'status', lowStockThreshold: '5' },
      [],
      undefined,
    );
    const pos = { ts: '2026-01-01T00:00:00.000000Z', key: ['00000000-0000-0000-0000-000000000000'] };
    const fresh = codec.encode('products', pos, Date.now() - 29 * 24 * 3600_000, adminScope);
    expect((await get(admin, url('products', { since: fresh, limit: 1 }))).status).toBe(200);
    const unscoped = codec.encode('products', pos, Date.now() - 29 * 24 * 3600_000);
    expect((await get(admin, url('products', { since: unscoped, limit: 1 }))).body).toMatchObject({
      code: 'VERSION_CONFLICT',
      reason: 'cursor_expired',
    });
  });

  it('images: готовое фото — элемент по схеме CatalogSyncImage (+ imageIds товара); снятое (deleted_at) и физически удалённое — в deleted[]; pending не выдаётся', async () => {
    const base = await loadAll(admin, 'images');
    const [p1, p2] = await ids('SELECT id FROM products WHERE NOT deletion_mark ORDER BY id LIMIT 2');
    const sha = (n: number) => n.toString(16).padStart(64, 'a');
    const ins = async (productId: string, source: string, status: string, n: number) =>
      (
        await t.rows<{ id: string }>(
          `INSERT INTO product_images (product_id, source_ref, checksum_sha256, status, is_primary, width, height, sort_order)
           VALUES ($1, $2, decode($3, 'hex'), $4::image_status, $5, 800, 600, 0) RETURNING id`,
          [productId, source, sha(n), status, status === 'ready'],
        )
      )[0].id;
    const ready = await ins(p1, 'test:img-ready', 'ready', 1);
    const pending = await ins(p2, 'test:img-pending', 'pending', 2);
    const inc1 = await loadAll(admin, 'images', { since: base.cursor });
    expect(inc1.items.map((i) => i.id)).toEqual([ready]);
    expect(inc1.deleted).toEqual([pending]);
    expect(validateAgainst('CatalogSyncImage', inc1.items[0], false)).toEqual([]);
    expect(inc1.items[0]).toMatchObject({ sha256: sha(1), productId: p1, variantId: null, isPrimary: true });
    const prod = (await loadAll(admin, 'products', { limit: 200 })).items.find((i) => i.id === p1);
    expect(prod?.imageIds).toEqual([ready]);
    await t.f.pool.query(`UPDATE product_images SET deleted_at = now(), is_primary = false WHERE id = $1`, [ready]);
    const inc2 = await loadAll(admin, 'images', { since: inc1.cursor });
    expect(inc2.deleted).toEqual([ready]);
    await t.f.pool.query(`DELETE FROM product_images WHERE id = $1`, [pending]);
    const inc3 = await loadAll(admin, 'images', { since: inc2.cursor });
    expect(inc3).toMatchObject({ items: [], deleted: [pending] });
  });

  it('права: без Bearer → 401; роль integration → 403 FORBIDDEN; без catalog.prices.read → 403 на prices/price_lists, без inventory.read → 403 на stock', async () => {
    expect((await http().get('/api/v1/catalog/sync/products')).status).toBe(401);
    const integration = await t.actor('integration');
    const r = await get(integration, url('products'));
    expect(r.status).toBe(403);
    expect(r.body.code).toBe('FORBIDDEN');

    const limited: Pick<PermissionCatalog, 'effectivePermissions'> = {
      effectivePermissions: () => new Set(['catalog.read'] as const),
    };
    const svc = new CatalogSyncService(
      t.app.get(PG_POOL),
      t.app.get(CatalogViewerService),
      limited as PermissionCatalog,
      t.app.get(CatalogSnapshotService),
      t.app.get(CatalogSyncCursorCodec),
    );
    const principal = { userId: seller.userId, kind: 'staff' as const, roles: ['seller'] };
    for (const entity of ['prices', 'price_lists', 'stock'] as const) {
      await expect(svc.page(principal, { entity, limit: 10 })).rejects.toMatchObject({ code: 'FORBIDDEN' });
    }
    await expect(svc.page(principal, { entity: 'products', limit: 1 })).resolves.toBeDefined();
    await expect(
      svc.page({ userId: seller.userId, kind: 'integration', roles: ['integration'] }, { entity: 'units', limit: 1 }),
    ).rejects.toMatchObject({ code: 'FORBIDDEN' });
  });
});

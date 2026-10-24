import request from 'supertest';
import { deepKeys, validateAgainst } from '../settings/support/openapi-check.js';
import { type Actor, CatalogTestApp } from './support/catalog-app.js';

/**
 * RM-E-004 (Catalog API, /inventory/*), RM-E-014 (сортировки `available:desc`/`sku:asc`, лимит 200,
 * `Variant.multiplicity`, `Product.availableTotal`, INV-052), RM-E-017 серверная часть (цена и остатки для
 * `customer`). Embedded PostgreSQL 17, все миграции; каталог — синтетика + фикстуры 1С, загруженные конвейером
 * применения из FakeOnecGateway (**на фикстурах, не реальная интеграция**). Ответы проверяются по схемам
 * contracts/openapi/pos-api.v1.yaml в строгом режиме (лишние поля — ошибка).
 */
const PAGE_SCHEMA = {
  allOf: [
    { $ref: '#/components/schemas/Page' },
    {
      type: 'object',
      properties: {
        items: { type: 'array', items: { $ref: '#/components/schemas/ProductSummary' } },
        facets: { $ref: '#/components/schemas/CatalogProductFacets' },
      },
    },
  ],
};
const arr = <T>(v: unknown): T[] => v as T[];
const QTY_FIELDS = ['quantity', 'reserved', 'available', 'availableTotal', 'remainingAvailable'];

describe('Catalog API и остатки (RM-E-004, RM-E-014, RM-E-017; embedded PG17 + синтетический каталог)', () => {
  const t = new CatalogTestApp();
  const http = () => request(t.app.getHttpServer());
  const get = (a: Actor | null, path: string, headers: Record<string, string> = {}) => {
    let r = http().get(`/api/v1${path}`);
    if (a) r = r.set('Authorization', `Bearer ${a.token}`).set('X-Device-Id', a.deviceKey);
    for (const [k, v] of Object.entries(headers)) r = r.set(k, v);
    return r;
  };
  const post = (a: Actor | null, path: string, body: unknown) => {
    let r = http()
      .post(`/api/v1${path}`)
      .send(body as object);
    if (a) r = r.set('Authorization', `Bearer ${a.token}`).set('X-Device-Id', a.deviceKey);
    return r;
  };

  let seller: Actor;
  let cashier: Actor;
  let admin: Actor;
  let customer: Actor;
  let wh: string[] = [];
  let retail: string;
  let wholesale: string;
  let bigWholesale: string;
  let anchor: string;

  /** Продаваемые товары каталога (как в списке): без deletion_mark, is_sellable. */
  const sellableCount = async () =>
    Number(
      (
        await t.pool.query<{ n: string }>(
          `SELECT count(*)::text AS n FROM products WHERE NOT deletion_mark AND is_sellable`,
        )
      ).rows[0].n,
    );

  beforeAll(async () => {
    await t.start({ skuCount: 300 });
    seller = await t.actor({ role: 'seller' });
    cashier = await t.actor({ role: 'cashier' });
    admin = await t.actor({ role: 'admin' });
    customer = await t.actor({ role: 'customer' });
    wh = await Promise.all(t.fx.refs.warehouses.slice(0, 3).map((r) => t.idByRef('warehouses', r)));
    const lists = await t.pool.query<{ id: string; name: string }>(`SELECT id, name FROM price_lists ORDER BY name`);
    retail = lists.rows.find((l) => l.name === 'Розничная')!.id;
    wholesale = lists.rows.find((l) => l.name === 'Оптовая')!.id;
    bigWholesale = lists.rows.find((l) => l.name === 'Крупный опт')!.id;
    anchor = await t.idByRef('products', t.fx.refs.anchors.F4252);
  });

  afterAll(async () => {
    await t.stop();
  });

  // ------------------------------------------------------------------ критерий 1: контракт OpenAPI

  it('критерий 1 (RM-E-004): ответы всех эндпоинтов валидны по схемам OpenAPI (staff и customer)', async () => {
    for (const a of [cashier, customer]) {
      const cats = await get(a, '/catalog/categories');
      expect(cats.status).toBe(200);
      expect(validateAgainst('CatalogCategoriesResponse', cats.body)).toEqual([]);
      expect(cats.body.items.length).toBeGreaterThan(0);

      const units = await get(a, '/catalog/units');
      expect(validateAgainst('CatalogUnitsResponse', units.body)).toEqual([]);
      const whs = await get(a, '/catalog/warehouses');
      expect(validateAgainst('CatalogWarehousesResponse', whs.body)).toEqual([]);

      const list = await get(a, '/catalog/products?limit=50');
      expect(list.status).toBe(200);
      expect(validateAgainst(PAGE_SCHEMA, list.body)).toEqual([]);
      expect(list.body.items).toHaveLength(50);

      const withVariants = await t.pool.query<{ id: string }>(
        `SELECT id FROM products WHERE has_variants AND NOT deletion_mark ORDER BY id LIMIT 1`,
      );
      for (const id of [anchor, withVariants.rows[0].id]) {
        const card = await get(a, `/catalog/products/${id}`);
        expect(card.status).toBe(200);
        expect(validateAgainst('Product', card.body)).toEqual([]);
        const vars = await get(a, `/catalog/products/${id}/variants`);
        expect(vars.status).toBe(200);
        expect(validateAgainst('CatalogVariantsResponse', vars.body)).toEqual([]);
        expect(vars.body.items.length).toBeGreaterThan(0);
      }

      const variantIds = arr<{ id: string }>((await get(a, `/catalog/products/${anchor}/variants`)).body.items).map(
        (v) => v.id,
      );
      const bal = await get(a, `/inventory/balances?variantIds=${variantIds.join(',')}`);
      expect(bal.status).toBe(200);
      expect(validateAgainst('InventoryBalancesResponse', bal.body)).toEqual([]);
      expect(bal.headers['cache-control']).toBe('no-store');

      const card = (await get(a, `/catalog/products/${anchor}`)).body;
      const chk = await post(a, '/inventory/check', {
        warehouseId: wh[0],
        items: [{ variantId: card.defaultVariantId, quantity: { value: '1', unitId: card.baseUnit.id } }],
      });
      expect(chk.status).toBe(200);
      expect(validateAgainst('InventoryCheckResponse', chk.body)).toEqual([]);
    }
    const pl = await get(cashier, '/catalog/price-lists');
    expect(pl.status).toBe(200);
    expect(validateAgainst('CatalogPriceListsResponse', pl.body)).toEqual([]);
    expect(arr<{ name: string }>(pl.body.items).map((l) => l.name)).toEqual(
      expect.arrayContaining(['Розничная', 'Оптовая', 'Крупный опт']),
    );
  });

  // 12 T-CAT-001 (цены строкой + KGS, X-Data-As-Of)
  it('критерий 4 (RM-E-004): цены — строки "1234.50" + currency "KGS"; X-Data-As-Of на каталоге', async () => {
    const list = await get(cashier, '/catalog/products?limit=200');
    expect(list.headers['x-data-as-of']).toMatch(/^\d{4}-\d{2}-\d{2}T.*Z$/);
    const prices = arr<{ price?: { price: unknown } }>(list.body.items)
      .filter((p) => p.price)
      .map((p) => p.price?.price);
    expect(prices.length).toBeGreaterThan(50);
    for (const m of prices) {
      expect(m).toEqual({ amount: expect.stringMatching(/^\d{1,12}\.\d{2}$/), currency: 'KGS' });
    }
    const card = (await get(cashier, `/catalog/products/${anchor}`)).body;
    const db = await t.pool.query<{ price: string }>(
      `SELECT x.price::text AS price FROM prices x JOIN product_variants v ON v.id = x.variant_id AND v.is_default
        WHERE v.product_id = $1 AND x.price_list_id = $2 AND x.packaging_id IS NULL`,
      [anchor, retail],
    );
    expect(card.price.price).toEqual({ amount: db.rows[0].price, currency: 'KGS' });
    expect(card.price.priceListName).toBe('Розничная');
  });

  // ------------------------------------------------------------------ критерий 2: ETag / 304

  // 12 T-CAT-001 (ETag/304 на повтор)
  it('критерий 2 (RM-E-004): If-None-Match → 304 без тела; Cache-Control по 08 §2.8', async () => {
    const paths: [string, string][] = [
      ['/catalog/categories', 'private, max-age=300'],
      ['/catalog/units', 'private, max-age=300'],
      ['/catalog/warehouses', 'private, max-age=300'],
      ['/catalog/price-lists', 'private, max-age=300'],
      ['/catalog/products?limit=20&sort=price:asc', 'private, max-age=60'],
      [`/catalog/products/${anchor}`, 'private, max-age=60'],
      [`/catalog/products/${anchor}/variants`, 'private, max-age=60'],
    ];
    for (const [path, cc] of paths) {
      const first = await get(cashier, path);
      expect(first.status, path).toBe(200);
      expect(first.headers['cache-control'], path).toBe(cc);
      const etag = first.headers.etag;
      expect(etag, path).toMatch(/^W\/".+"$/);
      const again = await get(cashier, path, { 'If-None-Match': etag });
      expect(again.status, path).toBe(304);
      expect(again.text ?? '', path).toBe('');
      const other = await get(cashier, path, { 'If-None-Match': 'W/"other"' });
      expect(other.status, path).toBe(200);
    }
    // Изменение остатка меняет ETag карточки (ложного 304 после обновления остатков нет).
    const first = await get(cashier, `/catalog/products/${anchor}?warehouseId=${wh[0]}`);
    const v = first.body.defaultVariantId as string;
    await t.pool.query(
      `INSERT INTO stock_balances (variant_id, warehouse_id, quantity, reserved, onec_snapshot_at, synced_at, source_hash)
       VALUES ($1, $2, 77, 1, now(), now(), 't') ON CONFLICT (variant_id, warehouse_id) DO UPDATE SET quantity = 77, reserved = 1, available_onec = NULL`,
      [v, wh[0]],
    );
    const changed = await get(cashier, `/catalog/products/${anchor}?warehouseId=${wh[0]}`, {
      'If-None-Match': first.headers.etag,
    });
    expect(changed.status).toBe(200);
    expect(changed.body.stock.available).toBe('76.000');
  });

  // ------------------------------------------------------------------ критерий 3: /inventory/check по складам

  // 12 T-CAT-007 (available по складам считает сервер)
  it('критерий 3 (RM-E-004): /inventory/check для 3 вариантов возвращает available по каждому складу', async () => {
    const rows = await t.pool.query<{ variant_id: string; unit_id: string }>(
      `SELECT v.id AS variant_id, p.base_unit_id AS unit_id
         FROM product_variants v JOIN products p ON p.id = v.product_id
        WHERE NOT p.deletion_mark AND NOT v.deletion_mark AND v.is_default = NOT p.has_variants
          AND (SELECT count(*) FROM stock_balances b WHERE b.variant_id = v.id AND b.warehouse_id = ANY($1::uuid[])) = 3
          AND EXISTS (SELECT 1 FROM prices x WHERE x.variant_id = v.id AND x.price_list_id = $2 AND x.packaging_id IS NULL)
        ORDER BY v.id LIMIT 3`,
      [wh, retail],
    );
    expect(rows.rows).toHaveLength(3);
    for (const w of wh) {
      const res = await post(admin, '/inventory/check', {
        warehouseId: w,
        items: rows.rows.map((r) => ({ variantId: r.variant_id, quantity: { value: '99999999', unitId: r.unit_id } })),
      });
      expect(res.status).toBe(200);
      expect(res.body.ok).toBe(false);
      expect(res.body.unavailable).toEqual([]);
      expect(res.body.shortages).toHaveLength(3);
      for (const s of res.body.shortages) {
        const db = await t.pool.query<{ a: string }>(
          `SELECT available::text AS a FROM stock_balances WHERE variant_id = $1 AND warehouse_id = $2`,
          [s.variantId, w],
        );
        expect(s.available).toBe(db.rows[0].a);
        expect(s.requestedBase).toBe('99999999.000');
        expect(s.unitId).toBe(rows.rows.find((r) => r.variant_id === s.variantId)!.unit_id);
      }
      // Запрос в пределах остатка → ok (ничего не резервирует: повтор даёт тот же ответ).
      const avail = await t.pool.query<{ variant_id: string; a: string }>(
        `SELECT variant_id, available::text AS a FROM stock_balances WHERE warehouse_id = $1 AND variant_id = ANY($2::uuid[])`,
        [w, rows.rows.map((r) => r.variant_id)],
      );
      const okItems = rows.rows
        .filter((r) => Number(avail.rows.find((x) => x.variant_id === r.variant_id)!.a) >= 1)
        .map((r) => ({ variantId: r.variant_id, quantity: { value: '1', unitId: r.unit_id } }));
      if (okItems.length > 0) {
        const ok1 = await post(admin, '/inventory/check', { warehouseId: w, items: okItems });
        const ok2 = await post(admin, '/inventory/check', { warehouseId: w, items: okItems });
        expect(ok1.body).toMatchObject({ ok: true, shortages: [], unavailable: [] });
        expect(ok2.body).toEqual(ok1.body);
      }
    }
    // Балансы по всем складам для тех же 3 вариантов.
    const bal = await get(admin, `/inventory/balances?variantIds=${rows.rows.map((r) => r.variant_id).join(',')}`);
    expect(bal.body.source).toBe('snapshot');
    const active = Number(
      (
        await t.pool.query<{ n: string }>(
          `SELECT count(*)::text AS n FROM warehouses WHERE is_active AND NOT deletion_mark`,
        )
      ).rows[0].n,
    );
    expect(bal.body.items).toHaveLength(3 * active);
  });

  it('/inventory/check: упаковка пересчитывается в базовые единицы; неверная единица/формат → VALIDATION_FAILED', async () => {
    const pk = await t.pool.query<{
      product_id: string;
      packaging_id: string;
      unit_id: string;
      factor: string;
      base_unit: string;
    }>(
      `SELECT k.product_id, k.id AS packaging_id, k.unit_id, k.factor::text AS factor, p.base_unit_id AS base_unit
         FROM packagings k JOIN products p ON p.id = k.product_id
        WHERE NOT p.has_variants AND NOT p.deletion_mark AND NOT k.deletion_mark ORDER BY k.id LIMIT 1`,
    );
    const r = pk.rows[0];
    const card = (await get(admin, `/catalog/products/${r.product_id}`)).body;
    const res = await post(admin, '/inventory/check', {
      warehouseId: wh[0],
      items: [
        {
          variantId: card.defaultVariantId,
          quantity: { value: '1000000', unitId: r.unit_id, packagingId: r.packaging_id },
        },
      ],
    });
    expect(res.status).toBe(200);
    const expected = (BigInt(1000000) * BigInt(Math.round(Number(r.factor)))).toString();
    expect(res.body.shortages[0].requestedBase).toBe(`${expected}.000`);
    const bad = await post(admin, '/inventory/check', {
      warehouseId: wh[0],
      items: [{ variantId: card.defaultVariantId, quantity: { value: '1.5', unitId: r.base_unit, extra: 1 } }],
      foo: 1,
    });
    expect(bad.status).toBe(400);
    expect(bad.body.code).toBe('VALIDATION_FAILED');
    const tooMany = await post(admin, '/inventory/check', {
      warehouseId: wh[0],
      items: Array.from({ length: 201 }, () => ({
        variantId: card.defaultVariantId,
        quantity: { value: '1', unitId: r.base_unit },
      })),
    });
    expect(tooMany.status).toBe(400);
    expect(arr<{ rule: string }>(tooMany.body.errors).map((e) => e.rule)).toContain('max_items');
    const prec = await post(admin, '/inventory/check', {
      warehouseId: wh[0],
      items: [{ variantId: card.defaultVariantId, quantity: { value: '1.5', unitId: r.base_unit } }],
    });
    if (card.baseUnit.qtyPrecision === 0) {
      expect(prec.status).toBe(400);
      expect(prec.body.errors[0].rule).toBe('qty_precision');
    }
  });

  // ------------------------------------------------------------------ цены по ролям (D-19, 08 §3.6, INV-030, CUST-021)

  // 12 T-CAT-030 (вид цены определяет сервер; priceListId по правам)
  it('цены по ролям: seller — только price, priceListId → 403; cashier — prices[] и priceListId', async () => {
    const s = await get(seller, `/catalog/products/${anchor}`);
    expect(s.body.price.priceListId).toBe(retail);
    expect(s.body.prices).toBeUndefined();
    expect((await get(seller, `/catalog/products?priceListId=${wholesale}`)).status).toBe(403);
    expect((await get(seller, `/catalog/products/${anchor}?priceListId=${wholesale}`)).body.code).toBe('FORBIDDEN');

    const c = await get(cashier, `/catalog/products/${anchor}?priceListId=${wholesale}`);
    expect(c.status).toBe(200);
    expect(c.body.price.priceListId).toBe(wholesale);
    expect(c.body.price.priceListName).toBe('Оптовая');
    const lists = new Set(arr<{ priceListId: string }>(c.body.prices).map((p) => p.priceListId));
    expect(lists).toEqual(new Set([retail, wholesale, bigWholesale]));
    const list = await get(cashier, `/catalog/products?priceListId=${wholesale}&limit=200`);
    for (const p of list.body.items) if (p.price) expect(p.price.priceListId).toBe(wholesale);
    // Вид цены, не видимый роли → 403; неизвестный → 400.
    await t.pool.query(`UPDATE price_lists SET visible_to_roles = '{owner}' WHERE id = $1`, [bigWholesale]);
    expect((await get(cashier, `/catalog/products?priceListId=${bigWholesale}`)).status).toBe(403);
    const hidden = await get(cashier, `/catalog/products/${anchor}`);
    expect(arr<{ priceListId: string }>(hidden.body.prices).map((p) => p.priceListId)).not.toContain(bigWholesale);
    await t.pool.query(
      `UPDATE price_lists SET visible_to_roles = '{seller,cashier,senior_seller,admin,owner}' WHERE id = $1`,
      [bigWholesale],
    );
    const unknown = await get(cashier, `/catalog/products?priceListId=00000000-0000-7000-8000-00000000dead`);
    expect(unknown.status).toBe(400);
    expect(unknown.body.errors[0].rule).toBe('unknown_reference');
  });

  // 12 T-CAT-030, T-CAT-035 (каталожная часть; checkout-preview — этап F)
  it('RM-E-017 п. 2: customer — вид цены карточки при confirmed, без привязки — is_default, иначе розничный; priceListId → 403', async () => {
    const priceOf = async (a: Actor) => (await get(a, `/catalog/products/${anchor}`)).body.price.priceListId as string;
    // Без привязки и без is_default — розничный.
    expect(await priceOf(customer)).toBe(retail);
    expect((await get(customer, `/catalog/products/${anchor}?priceListId=${wholesale}`)).status).toBe(403);
    expect((await get(customer, `/catalog/products?priceListId=${wholesale}`)).body.code).toBe('FORBIDDEN');
    expect((await get(customer, `/catalog/price-lists`)).status).toBe(403);
    // is_default задан → он.
    await t.pool.query(`UPDATE price_lists SET is_default = true WHERE id = $1`, [wholesale]);
    expect(await priceOf(customer)).toBe(wholesale);
    // Привязка не подтверждена → вид цены карточки не применяется.
    const pending = await t.actor({ role: 'customer' });
    await t.linkCustomer(pending.userId, bigWholesale, 'proposed');
    expect(await priceOf(pending)).toBe(wholesale);
    // Подтверждённая привязка → вид цены карточки 1С.
    const linked = await t.actor({ role: 'customer' });
    await t.linkCustomer(linked.userId, bigWholesale, 'confirmed');
    expect(await priceOf(linked)).toBe(bigWholesale);
    const list = await get(linked, `/catalog/products?limit=100`);
    for (const p of list.body.items) if (p.price) expect(p.price.priceListId).toBe(bigWholesale);
    const card = (await get(linked, `/catalog/products/${anchor}`)).body;
    expect(card.prices).toBeUndefined();
    await t.pool.query(`UPDATE price_lists SET is_default = false WHERE id = $1`, [wholesale]);
  });

  // ------------------------------------------------------------------ RM-E-017 п. 1: остатки для customer (AC-API-180)

  // 12 T-CAT-032, T-CAT-036 (API каталога), T-SEC-017 (часть E: field-level остатков)
  it('RM-E-017 п. 1: при status ответы customer без quantity/reserved/available; при quantity — available без reserved; staff — все поля', async () => {
    const variantIds = arr<{ id: string }>((await get(admin, `/catalog/products/${anchor}/variants`)).body.items).map(
      (v) => v.id,
    );
    const card = (await get(admin, `/catalog/products/${anchor}`)).body;
    const checkBody = {
      warehouseId: wh[0],
      items: [{ variantId: card.defaultVariantId, quantity: { value: '99999999', unitId: card.baseUnit.id } }],
    };
    const customerResponses = async (): Promise<unknown[]> => {
      const out: unknown[] = [
        (await get(customer, '/catalog/products?limit=200')).body,
        (await get(customer, `/catalog/products/${anchor}`)).body,
        (await get(customer, `/catalog/products/${anchor}/variants`)).body,
        (await get(customer, `/inventory/balances?variantIds=${variantIds.join(',')}`)).body,
        (await post(customer, '/inventory/check', checkBody)).body,
      ];
      return out;
    };
    await t.setSetting('customer_stock_display', '"status"');
    for (const body of await customerResponses()) {
      const keys = deepKeys(body);
      for (const f of QTY_FIELDS) expect(keys.has(f), f).toBe(false);
      expect(keys.has('stockLevel')).toBe(true);
    }
    const st = (await post(customer, '/inventory/check', checkBody)).body;
    expect(Object.keys(st.shortages[0]).sort()).toEqual(['stockLevel', 'variantId']);

    await t.setSetting('customer_stock_display', '"quantity"');
    const [list, cardQ, vars, bal, chk] = (await customerResponses()) as [
      unknown,
      Record<string, unknown>,
      unknown,
      unknown,
      { shortages: { available?: string; unitId?: string }[] },
    ];
    for (const body of [list, cardQ, vars, bal, chk]) {
      const keys = deepKeys(body);
      expect(keys.has('quantity')).toBe(false);
      expect(keys.has('reserved')).toBe(false);
    }
    expect(deepKeys(bal).has('available')).toBe(true);
    expect('availableTotal' in cardQ).toBe(true);
    expect(chk.shortages[0].available).toMatch(/^-?\d+\.\d{3}$/);
    expect(chk.shortages[0].unitId).toBeUndefined();
    expect(validateAgainst('Product', cardQ)).toEqual([]);

    const staff = (await get(admin, `/inventory/balances?variantIds=${variantIds.join(',')}`)).body;
    const known = arr<{ stockLevel: string }>(staff.items).filter((i) => i.stockLevel !== 'unknown');
    expect(known.length).toBeGreaterThan(0);
    for (const i of known)
      expect(Object.keys(i)).toEqual(expect.arrayContaining(['quantity', 'reserved', 'available']));
    await t.setSetting('customer_stock_display', '"status"');
  });

  // ------------------------------------------------------------------ пагинация (08 §2.5)

  // 12 T-CAT-001 (курсорная пагинация), T-CAT-016 (страницы без пропусков и дублей)
  it('курсорная пагинация стабильна для всех сортировок: без дублей и пропусков, totalEstimate точный', async () => {
    const expected = await sellableCount();
    const sorts = [
      'name:asc',
      'name:desc',
      'price:asc',
      'price:desc',
      'available:desc',
      'sku:asc',
      'updatedAt:desc',
      'popularity:desc',
    ];
    for (const sort of sorts) {
      const seen: string[] = [];
      let cursor: string | null = null;
      let pages = 0;
      do {
        const q: string = `/catalog/products?limit=37&sort=${sort}&warehouseId=${wh[0]}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`;
        const r = await get(cashier, q);
        expect(r.status, sort).toBe(200);
        // «Найдено: N» — точный счёт на первой странице, далее null.
        expect(r.body.totalEstimate, sort).toBe(pages === 0 ? expected : null);
        expect(r.body.items.length).toBeLessThanOrEqual(37);
        seen.push(...arr<{ id: string }>(r.body.items).map((p) => p.id));
        cursor = r.body.nextCursor;
        expect(r.body.hasMore).toBe(cursor !== null);
        pages += 1;
      } while (cursor && pages < 100);
      expect(new Set(seen).size, sort).toBe(seen.length);
      expect(seen.length, sort).toBe(expected);
    }
  });

  // 12 T-CAT-016 (available:desc, sku:asc; без снимка — в конце)
  it('RM-E-014 п. 1: sort=available:desc и sort=sku:asc дают ожидаемый порядок; без снимка остатка — в конце', async () => {
    const all = async (sort: string) => {
      const out: { id: string; sku?: string; stock?: { available?: string; stockLevel: string } }[] = [];
      let cursor: string | null = null;
      do {
        const r = await get(
          admin,
          `/catalog/products?limit=200&sort=${sort}&warehouseId=${wh[1]}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`,
        );
        out.push(...r.body.items);
        cursor = r.body.nextCursor;
      } while (cursor);
      return out;
    };
    const db = await t.pool.query<{ id: string; sku: string | null; avail: string | null }>(
      `SELECT p.id, p.sku, (SELECT sum(b.available) FROM product_variants v JOIN stock_balances b ON b.variant_id = v.id
                             AND b.warehouse_id = $1 WHERE v.product_id = p.id AND NOT v.deletion_mark
                             AND v.is_default = NOT p.has_variants)::text AS avail
         FROM products p WHERE NOT p.deletion_mark AND p.is_sellable`,
      [wh[1]],
    );
    const cmpId = (a: { id: string }, b: { id: string }) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
    const byAvail = [...db.rows].sort((a, b) => {
      // id — последний ключ в направлении сортировки (desc).
      if (a.avail === null && b.avail === null) return cmpId(b, a);
      if (a.avail === null) return 1;
      if (b.avail === null) return -1;
      const d = Number(b.avail) - Number(a.avail);
      return d !== 0 ? Math.sign(d) : cmpId(b, a);
    });
    expect((await all('available:desc')).map((p) => p.id)).toEqual(byAvail.map((r) => r.id));
    const bySku = [...db.rows].sort((a, b) => {
      if (a.sku === null && b.sku === null) return cmpId(a, b);
      if (a.sku === null) return 1;
      if (b.sku === null) return -1;
      const ab = Buffer.compare(Buffer.from(a.sku), Buffer.from(b.sku));
      return ab !== 0 ? ab : cmpId(a, b);
    });
    expect((await all('sku:asc')).map((p) => p.id)).toEqual(bySku.map((r) => r.id));
    const tail = (await all('available:desc')).slice(-1)[0];
    expect(tail.stock?.stockLevel).toBe(byAvail.at(-1)!.avail === null ? 'unknown' : tail.stock?.stockLevel);
  });

  it('RM-E-014 п. 2: limit=201 → VALIDATION_FAILED, limit=200 → 200; курсор подделан/другой sort → VALIDATION_FAILED', async () => {
    const over = await get(cashier, '/catalog/products?limit=201');
    expect(over.status).toBe(400);
    expect(over.body.code).toBe('VALIDATION_FAILED');
    expect((await get(cashier, '/catalog/products?limit=200')).status).toBe(200);
    expect((await get(cashier, '/catalog/products?sort=weight:asc')).body.errors[0].rule).toBe('sort_field');
    const first = await get(cashier, '/catalog/products?limit=5&sort=price:asc');
    const cursor = first.body.nextCursor as string;
    const forged = `${cursor.slice(0, -2)}xx`;
    const bad = await get(cashier, `/catalog/products?limit=5&sort=price:asc&cursor=${encodeURIComponent(forged)}`);
    expect(bad.status).toBe(400);
    expect(bad.body.errors[0].rule).toBe('cursor');
    const mismatch = await get(cashier, `/catalog/products?limit=5&sort=name:asc&cursor=${encodeURIComponent(cursor)}`);
    expect(mismatch.body.errors[0].rule).toBe('cursor_sort_mismatch');
    expect((await get(cashier, '/catalog/products?priceMin=10')).body.errors[0].rule).toBe('money_format');
  });

  // 12 T-CAT-007 (сумма доступного считает сервер)
  it('RM-E-014 п. 2: Variant.multiplicity и Product.availableTotal (сумма available по складам, считает сервер)', async () => {
    await t.pool.query(`UPDATE products SET multiplicity = 6, min_qty = 12 WHERE id = $1`, [anchor]);
    const card = (await get(admin, `/catalog/products/${anchor}`)).body;
    expect(card.variants[0].multiplicity).toBe('6.000');
    expect(card.minQuantity).toBe('12.000');
    const sum = await t.pool.query<{ s: string | null }>(
      `SELECT sum(b.available)::text AS s FROM stock_balances b JOIN warehouses w ON w.id = b.warehouse_id AND w.is_active
        WHERE b.variant_id = $1`,
      [card.defaultVariantId],
    );
    expect(card.availableTotal).toBe(sum.rows[0].s === null ? null : Number(sum.rows[0].s).toFixed(3));
    expect(card.availableTotal).toMatch(/^\d+\.\d{3}$/);
    const vars = (await get(admin, `/catalog/products/${anchor}/variants`)).body;
    expect(vars.items[0]).toHaveProperty('multiplicity', '6.000');
    const other = (await get(admin, '/catalog/products?limit=3&sort=sku:asc')).body.items[0].id;
    const v2 = (await get(admin, `/catalog/products/${other}/variants`)).body;
    for (const v of v2.items) expect(v.multiplicity === null || /^\d+\.\d{3}$/.test(v.multiplicity)).toBe(true);
  });

  // 12 T-INV-014 (неизвестный остаток — добавить нельзя)
  it('INV-052: нет снимка остатка → stockLevel=unknown без количеств; /inventory/check — нехватка (добавить нельзя)', async () => {
    const row = await t.pool.query<{ product_id: string; variant_id: string; unit_id: string }>(
      `SELECT p.id AS product_id, v.id AS variant_id, p.base_unit_id AS unit_id
         FROM products p JOIN product_variants v ON v.product_id = p.id AND v.is_default
        WHERE NOT p.has_variants AND NOT p.deletion_mark
          AND NOT EXISTS (SELECT 1 FROM stock_balances b WHERE b.variant_id = v.id AND b.warehouse_id = $1)
          AND EXISTS (SELECT 1 FROM prices x WHERE x.variant_id = v.id AND x.price_list_id = $2)
        ORDER BY p.id LIMIT 1`,
      [wh[2], retail],
    );
    const r = row.rows[0];
    const card = (await get(admin, `/catalog/products/${r.product_id}?warehouseId=${wh[2]}`)).body;
    expect(card.stock).toEqual({
      variantId: r.variant_id,
      warehouseId: wh[2],
      warehouseName: expect.any(String),
      stockLevel: 'unknown',
    });
    const chk = await post(admin, '/inventory/check', {
      warehouseId: wh[2],
      items: [{ variantId: r.variant_id, quantity: { value: '1', unitId: r.unit_id } }],
    });
    expect(chk.body.ok).toBe(false);
    expect(chk.body.shortages).toEqual([
      { variantId: r.variant_id, requestedBase: '1.000', unitId: r.unit_id, stockLevel: 'unknown' },
    ]);
  });

  it('уровни остатка: in_stock ≥ порога, low < порога, out ≤ 0 (low_stock_threshold)', async () => {
    const card = (await get(admin, `/catalog/products/${anchor}?warehouseId=${wh[1]}`)).body;
    const v = card.defaultVariantId as string;
    const set = async (q: number, r: number) => {
      await t.pool.query(
        `INSERT INTO stock_balances (variant_id, warehouse_id, quantity, reserved, onec_snapshot_at, synced_at, source_hash)
         VALUES ($1, $2, $3, $4, now(), now(), 't')
         ON CONFLICT (variant_id, warehouse_id) DO UPDATE SET quantity = $3, reserved = $4, available_onec = NULL`,
        [v, wh[1], q, r],
      );
      return (await get(admin, `/catalog/products/${anchor}?warehouseId=${wh[1]}`)).body.stock as {
        stockLevel: string;
        available?: string;
      };
    };
    expect((await set(10, 5)).stockLevel).toBe('in_stock');
    expect((await set(10, 6)).stockLevel).toBe('low');
    expect(await set(3, 5)).toMatchObject({ available: '-2.000', stockLevel: 'out' });
  });

  it('customer при status, sort=available:desc: nextCursor не раскрывает остаток последней строки (ревью E-api-1)', async () => {
    await t.setSetting('customer_stock_display', '"status"');
    const p1 = (await get(customer, '/catalog/products?sort=available:desc&limit=2')).body;
    expect(p1.nextCursor).toBeTruthy();
    const token = String(p1.nextCursor).split('.')[0] ?? '';
    const raw = Buffer.from(token, 'base64url').toString('latin1');
    expect(raw).not.toMatch(/\d+\.\d{3}/);
    expect(raw).not.toContain('available');
    expect(deepKeys(p1).has('available')).toBe(false);
    const p2 = (
      await get(customer, `/catalog/products?sort=available:desc&limit=2&cursor=${encodeURIComponent(p1.nextCursor)}`)
    ).body;
    expect(arr<{ id: string }>(p2.items)).toHaveLength(2);
    expect(arr<{ id: string }>(p2.items).map((i) => i.id)).not.toContain(arr<{ id: string }>(p1.items)[1]?.id);
  });

  it('товар с характеристиками: отрицательный свободный остаток одного варианта не скрывает продаваемый вариант (ревью E-api-4)', async () => {
    const first = await get(seller, '/catalog/products?limit=1');
    const w = first.body.items[0].stock.warehouseId as string;
    const r = await t.pool.query<{ pid: string; cat: string; a: string; b: string; aa: string; bo: string | null }>(
      `SELECT p.id AS pid, p.category_id AS cat, v1.id AS a, v2.id AS b, s1.available::text AS aa,
              s2.available_onec::text AS bo
         FROM products p
         JOIN product_variants v1 ON v1.product_id = p.id AND NOT v1.is_default AND NOT v1.deletion_mark
         JOIN product_variants v2 ON v2.product_id = p.id AND NOT v2.is_default AND NOT v2.deletion_mark AND v2.id > v1.id
         JOIN stock_balances s1 ON s1.variant_id = v1.id AND s1.warehouse_id = $1 AND s1.available > 0
         JOIN stock_balances s2 ON s2.variant_id = v2.id AND s2.warehouse_id = $1
        WHERE p.has_variants AND NOT p.deletion_mark AND p.is_sellable
          AND (SELECT count(*) FROM product_variants x WHERE x.product_id = p.id AND NOT x.is_default AND NOT x.deletion_mark) = 2
        ORDER BY p.id LIMIT 1`,
      [w],
    );
    const row = r.rows[0];
    expect(row, 'товар с двумя вариантами и остатками на складе').toBeDefined();
    await t.pool.query(
      `UPDATE stock_balances SET available_onec = -($2::numeric) - 1 WHERE variant_id = $1 AND warehouse_id = $3`,
      [row.b, row.aa, w],
    );
    try {
      const card = (await get(seller, `/catalog/products/${row.pid}?warehouseId=${w}`)).body;
      expect(card.stock.stockLevel).not.toBe('out');
      expect(Number(card.stock.available)).toBe(Number(row.aa));
      const list = (
        await get(seller, `/catalog/products?inStock=true&limit=200&categoryId=${row.cat}&warehouseId=${w}`)
      ).body;
      expect(arr<{ id: string }>(list.items).some((i) => i.id === row.pid)).toBe(true);
      const name = (await t.pool.query<{ name: string }>(`SELECT name FROM products WHERE id = $1`, [row.pid])).rows[0]
        .name;
      const found = (
        await get(seller, `/search/products?q=${encodeURIComponent(name)}&inStock=true&limit=200&warehouseId=${w}`)
      ).body;
      if (found.items) expect(arr<{ id: string }>(found.items).some((i) => i.id === row.pid)).toBe(true);
    } finally {
      await t.pool.query(
        `UPDATE stock_balances SET available_onec = $2::numeric WHERE variant_id = $1 AND warehouse_id = $3`,
        [row.b, row.bo, w],
      );
    }
  });

  // ------------------------------------------------------------------ фильтры

  // 12 T-CAT-004 (фильтр categoryId включает потомков), T-CAT-017, T-CAT-022 (серверная часть)
  it('фильтры /catalog/products: категория с подкатегориями, наличие, цена, свойства, бренд, избранное, фото', async () => {
    const cat = await t.pool.query<{ id: string; root: string }>(
      `SELECT p.category_id AS id, split_part(c.path, '/', 2)::uuid::text AS root
         FROM products p JOIN categories c ON c.id = p.category_id WHERE p.id = $1`,
      [anchor],
    );
    const { id: leaf, root } = cat.rows[0];
    const inRoot = await get(admin, `/catalog/products?categoryId=${root}&limit=200`);
    expect(arr<{ id: string }>(inRoot.body.items).map((p) => p.id)).toContain(anchor);
    const cats = await t.pool.query<{ id: string }>(
      `SELECT id FROM categories WHERE path LIKE (SELECT path FROM categories WHERE id = $1) || '%'`,
      [root],
    );
    const allowed = new Set(cats.rows.map((c) => c.id));
    for (const p of inRoot.body.items) expect(allowed.has(p.categoryId)).toBe(true);
    const cache = await t.pool.query<{ n: number }>(`SELECT product_count_cache AS n FROM categories WHERE id = $1`, [
      root,
    ]);
    expect(inRoot.body.totalEstimate).toBe(cache.rows[0].n);
    const direct = await get(admin, `/catalog/products?categoryId=${root}&includeSubcategories=false`);
    expect(direct.body.items).toEqual([]);
    expect(
      (await get(admin, `/catalog/products?categoryId=${leaf}&includeSubcategories=false&limit=200`)).body.items.length,
    ).toBeGreaterThan(0);

    const inStock = await get(admin, `/catalog/products?inStock=true&warehouseId=${wh[0]}&limit=200`);
    for (const p of inStock.body.items) expect(Number(p.stock.available)).toBeGreaterThan(0);

    const priced = await get(admin, `/catalog/products?priceMin=1000.00&priceMax=5000.00&limit=200`);
    expect(priced.body.items.length).toBeGreaterThan(0);
    for (const p of priced.body.items) {
      const lo = Number(p.price?.price.amount ?? p.priceRange.min.amount);
      const hi = Number(p.price?.price.amount ?? p.priceRange.max.amount);
      expect(hi >= 1000 && lo <= 5000).toBe(true);
    }
    expect(priced.body.facets.priceRange).toBeDefined();

    const attr = await t.pool.query<{ code: string; value: string }>(
      `SELECT pa.code, vav.value_text AS value FROM variant_attribute_values vav
         JOIN product_attributes pa ON pa.id = vav.attribute_id
         JOIN product_variants v ON v.id = vav.variant_id WHERE v.product_id = $1 AND vav.value_text IS NOT NULL LIMIT 1`,
      [anchor],
    );
    const a = attr.rows[0];
    const byAttr = await get(
      admin,
      `/catalog/products?attr[${encodeURIComponent(a.code)}]=${encodeURIComponent(a.value)}&limit=200`,
    );
    expect(byAttr.status).toBe(200);
    expect(arr<{ id: string }>(byAttr.body.items).map((p) => p.id)).toContain(anchor);
    expect(byAttr.body.totalEstimate).toBeLessThan(await sellableCount());

    await t.pool.query(`UPDATE products SET brand = 'Frap' WHERE id = $1`, [anchor]);
    const byBrand = await get(admin, `/catalog/products?brand=Frap,Nobrand`);
    expect(arr<{ id: string }>(byBrand.body.items).map((p) => p.id)).toEqual([anchor]);
    expect(byBrand.body.facets.brands).toEqual([{ value: 'Frap', count: 1 }]);

    await t.pool.query(`INSERT INTO favorites_products (user_id, product_id) VALUES ($1, $2)`, [
      cashier.userId,
      anchor,
    ]);
    const fav = await get(cashier, `/catalog/products?favorite=true`);
    expect(arr<{ id: string; isFavorite: boolean }>(fav.body.items).map((p) => [p.id, p.isFavorite])).toEqual([
      [anchor, true],
    ]);

    expect((await get(admin, `/catalog/products?hasImage=true`)).body.items).toEqual([]);
    await t.pool.query(
      `INSERT INTO product_images (product_id, source_ref, checksum_sha256, width, height, is_primary, status, storage_key)
       VALUES ($1, 'test:img', decode(repeat('ab', 32), 'hex'), 1200, 900, true, 'ready', 'k')`,
      [anchor],
    );
    const img = await get(admin, `/catalog/products?hasImage=true`);
    expect(img.body.items).toHaveLength(1);
    expect(img.body.items[0].primaryImage).toEqual({
      sha256: 'ab'.repeat(32),
      thumbUrl: `/images/${'ab'.repeat(32)}/thumb`,
      cardUrl: `/images/${'ab'.repeat(32)}/card`,
      fullUrl: `/images/${'ab'.repeat(32)}/full`,
      isPrimary: true,
      width: 1200,
      height: 900,
    });
    expect(validateAgainst(PAGE_SCHEMA, img.body)).toEqual([]);
  });

  // 12 T-CAT-003 (дерево и счётчики), T-CAT-004 (подкатегории)
  it('категории: дерево со счётчиками, parentId/depth/includeEmpty/inStockOnly, неизвестный parentId → 404', async () => {
    const full = (await get(seller, '/catalog/categories')).body;
    const roots = full.items as { id: string; productCount: number; children?: unknown[]; hasChildren: boolean }[];
    const total = roots.reduce((n, r) => n + r.productCount, 0);
    const nulls = Number(
      (
        await t.pool.query<{ n: string }>(
          `SELECT count(*)::text AS n FROM products WHERE NOT deletion_mark AND is_sellable AND category_id IS NULL`,
        )
      ).rows[0].n,
    );
    expect(total + nulls).toBe(await sellableCount());
    expect(full.snapshotVersion).toMatch(/^cat:/);
    const one = (await get(seller, '/catalog/categories?depth=1')).body.items as {
      children?: unknown[];
      hasChildren: boolean;
    }[];
    expect(one.every((n) => n.children === undefined)).toBe(true);
    expect(one.some((n) => n.hasChildren)).toBe(true);
    const sub = (await get(seller, `/catalog/categories?parentId=${roots[0].id}`)).body.items as { parentId: string }[];
    expect(sub.length).toBeGreaterThan(0);
    for (const n of sub) expect(n.parentId).toBe(roots[0].id);
    const inStock = (await get(seller, `/catalog/categories?inStockOnly=true`)).body.items as {
      productCount: number;
    }[];
    expect(inStock.reduce((n, r) => n + r.productCount, 0)).toBeLessThanOrEqual(total);
    const nf = await get(seller, `/catalog/categories?parentId=00000000-0000-7000-8000-00000000beef`);
    expect(nf.status).toBe(404);
    expect(nf.body.code).toBe('NOT_FOUND');
  });

  // 12 T-CAT-009 (удалённый товар), T-CAT-031 (deletion_mark не возвращается)
  it('снятый товар: customer → 404, staff → 200 с deletionMark=true; в списке не показывается', async () => {
    const del = await t.pool.query<{ id: string }>(`SELECT id FROM products WHERE deletion_mark LIMIT 1`);
    const id = del.rows[0].id;
    expect((await get(customer, `/catalog/products/${id}`)).status).toBe(404);
    expect((await get(customer, `/catalog/products/${id}/variants`)).status).toBe(404);
    const staff = await get(admin, `/catalog/products/${id}`);
    expect(staff.status).toBe(200);
    expect(staff.body.deletionMark).toBe(true);
    let cursor: string | null = null;
    const ids: string[] = [];
    do {
      const r = await get(admin, `/catalog/products?limit=200${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`);
      ids.push(...arr<{ id: string }>(r.body.items).map((p) => p.id));
      cursor = r.body.nextCursor;
    } while (cursor);
    expect(ids).not.toContain(id);
    expect((await get(admin, `/catalog/products/00000000-0000-7000-8000-00000000f00d`)).status).toBe(404);
    expect((await get(admin, `/catalog/products/not-a-uuid`)).status).toBe(400);
  });

  // 12 T-CAT-005 (варианты и оси выбора — серверная часть)
  it('варианты: служебный вариант товара с характеристиками не показывается; оси выбора и inStockOnly', async () => {
    const p = await t.pool.query<{ id: string }>(
      `SELECT id FROM products WHERE has_variants AND NOT deletion_mark ORDER BY id LIMIT 1`,
    );
    const vars = (await get(admin, `/catalog/products/${p.rows[0].id}/variants?warehouseId=${wh[0]}`)).body;
    const db = await t.pool.query<{ n: string }>(
      `SELECT count(*)::text AS n FROM product_variants WHERE product_id = $1 AND NOT is_default AND NOT deletion_mark`,
      [p.rows[0].id],
    );
    expect(vars.items).toHaveLength(Number(db.rows[0].n));
    expect(arr<{ isDefault: boolean }>(vars.items).every((v) => !v.isDefault)).toBe(true);
    expect(vars.attributeKeys.length).toBe(1);
    expect(vars.attributeKeys[0].values.length).toBe(vars.items.length);
    const only = (await get(admin, `/catalog/products/${p.rows[0].id}/variants?warehouseId=${wh[0]}&inStockOnly=true`))
      .body;
    for (const v of only.items) expect(Number(v.stock.available)).toBeGreaterThan(0);
    const summary = arr<{ hasVariants: boolean; priceRange?: unknown; price?: unknown }>(
      (await get(admin, `/catalog/products?limit=200&warehouseId=${wh[0]}`)).body.items,
    ).find((x) => x.hasVariants);
    expect(summary?.priceRange).toBeDefined();
    expect(summary?.price).toBeUndefined();
  });

  // ------------------------------------------------------------------ RBAC

  it('RBAC: без Bearer → 401; integration и pending_activation → 403; customer live=true → 403', async () => {
    const card = (await get(admin, `/catalog/products/${anchor}`)).body;
    const paths = [
      '/catalog/categories',
      '/catalog/units',
      '/catalog/warehouses',
      '/catalog/price-lists',
      '/catalog/products',
      `/catalog/products/${anchor}`,
      `/catalog/products/${anchor}/variants`,
      `/inventory/balances?variantIds=${card.defaultVariantId}`,
    ];
    const integration = await t.actor({ kind: 'staff', role: 'integration' });
    const pending = await t.actor({ kind: 'customer', role: null, status: 'pending_activation' });
    for (const path of paths) {
      const anon = await get(null, path);
      expect(anon.status, path).toBe(401);
      expect(anon.body.code).toBe('UNAUTHENTICATED');
      expect((await get(integration, path)).status, path).toBe(403);
      expect((await get(pending, path)).status, path).toBe(403);
    }
    const body = {
      warehouseId: wh[0],
      items: [{ variantId: card.defaultVariantId, quantity: { value: '1', unitId: card.baseUnit.id } }],
    };
    expect((await post(null, '/inventory/check', body)).status).toBe(401);
    expect((await post(integration, '/inventory/check', body)).status).toBe(403);
    expect((await get(customer, `/inventory/balances?variantIds=${card.defaultVariantId}&live=true`)).status).toBe(403);
    const live = await get(admin, `/inventory/balances?variantIds=${card.defaultVariantId}&live=true`);
    expect(live.status).toBe(200);
    expect(live.body.source).toBe('snapshot');
    const many = Array.from({ length: 201 }, (_, i) => `00000000-0000-7000-8000-${String(i).padStart(12, '0')}`);
    expect((await get(admin, `/inventory/balances?variantIds=${many.join(',')}`)).body.errors[0].rule).toBe(
      'max_items',
    );
    expect((await get(admin, `/inventory/balances`)).status).toBe(400);
  });
});

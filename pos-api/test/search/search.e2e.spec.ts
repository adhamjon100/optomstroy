import type { NestExpressApplication } from '@nestjs/platform-express';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PRODUCT_FILTER_PARAMS } from '../../src/catalog/api/product-filters.js';
import { validateAgainst } from '../settings/support/openapi-check.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { createSearchApp, principalHeader } from './support/search-app.js';
import { allMigrations, assertCyrillicCtype, SearchPg } from './support/search-pg.js';

/**
 * RM-E-005 / RM-E-014 (поиск): e2e по HTTP на синтетическом каталоге 400 SKU + фикстуры 1С, загруженных конвейером
 * применения 1С (FakeOnecGateway). Тестовые данные, не реальная интеграция. Эталонные запросы критерия RM-E-005:
 * «смеситель фрап», «Frap F4252», штрихкод, артикул с опечаткой — ожидаемый matchType (T-NFR-027, AC-DATA-242).
 */

const SEARCH_PAGE_SCHEMA = {
  allOf: [
    { $ref: '#/components/schemas/Page' },
    {
      type: 'object',
      properties: {
        items: { type: 'array', items: { $ref: '#/components/schemas/ProductSummary' } },
        query: { type: 'string' },
        matchTypes: { $ref: '#/components/schemas/SearchMatchTypes' },
        suggestedQuery: { type: 'string', nullable: true },
      },
    },
  ],
};

interface Item {
  id: string;
  name: string;
  sku?: string;
  matchType: string | null;
  price?: { price: { amount: string } };
  priceRange?: { min: { amount: string }; max: { amount: string } };
  stock?: Record<string, unknown>;
}
interface SearchBody {
  items: Item[];
  nextCursor: string | null;
  hasMore: boolean;
  totalEstimate: number | null;
  query: string;
  matchTypes: Record<string, number>;
  suggestedQuery: string | null;
}

let server: SearchPg;
let f: CatalogFixture;
let app: NestExpressApplication;
const anchor: Record<string, string> = {};
let anchorBarcode = '';
let packBarcode: { value: string; productId: string; packagingId: string } | undefined;

function get(path: string, role = 'seller', query: Record<string, string> = {}) {
  return request(app.getHttpServer()).get(`/api/v1${path}`).query(query).set('x-test-principal', principalHeader(role));
}

async function search(q: string, extra: Record<string, string> = {}, role = 'seller'): Promise<SearchBody> {
  const res = await get('/search/products', role, { q, ...extra });
  expect(res.status, JSON.stringify(res.body)).toBe(200);
  return res.body as SearchBody;
}

beforeAll(async () => {
  server = new SearchPg();
  await server.start();
  f = await startCatalogFixture({
    pg: server,
    database: 'pos_search',
    skuCount: 400,
    seed: 1,
    migrations: allMigrations(),
  });
  await assertCyrillicCtype(f.pool);
  for (const [sku, ref] of Object.entries(f.refs.anchors)) {
    const r = await f.pool.query<{ id: string }>('SELECT id::text FROM products WHERE onec_ref = $1', [ref]);
    anchor[sku] = r.rows[0].id;
  }
  const b = await f.pool.query<{ value: string }>(
    'SELECT value FROM barcodes WHERE product_id = $1 AND packaging_id IS NULL ORDER BY value LIMIT 1',
    [anchor.F4252],
  );
  anchorBarcode = b.rows[0].value;
  const pb = await f.pool.query<{ value: string; product_id: string; packaging_id: string }>(
    `SELECT b.value, b.product_id::text, b.packaging_id::text FROM barcodes b JOIN products p ON p.id = b.product_id
      WHERE b.packaging_id IS NOT NULL AND NOT p.deletion_mark AND p.is_sellable ORDER BY b.value LIMIT 1`,
  );
  if (pb.rows[0])
    packBarcode = { value: pb.rows[0].value, productId: pb.rows[0].product_id, packagingId: pb.rows[0].packaging_id };
  ({ app } = await createSearchApp(f.pool));
}, 300_000);

afterAll(async () => {
  await app?.close();
  await f?.stop();
  await server?.stop();
});

describe('эталонные запросы D-31 (критерий RM-E-005)', () => {
  it('«смеситель фрап» → fts: товары бренда Frap из «Смесителей» (транслитерация бренда), якоря F4252/F3241', async () => {
    const body = await search('смеситель фрап', { limit: '200' });
    expect(body.matchTypes).toMatchObject({ barcode: 0, sku: 0, trgm: 0 });
    expect(body.matchTypes.fts).toBeGreaterThan(0);
    expect(body.items.length).toBe(body.matchTypes.fts);
    const docs = await f.pool.query<{ id: string; doc: string }>(
      `SELECT id::text, concat_ws(' ', name, category_path_text, description) AS doc FROM products
        WHERE id = ANY($1::uuid[])`,
      [body.items.map((i) => i.id)],
    );
    const docOf = new Map(docs.rows.map((r) => [r.id, r.doc]));
    for (const it of body.items) {
      expect(it.matchType).toBe('fts');
      // Оба слова — в названии (вес A), пути категории «Смесители / …» (C) или описании «Производитель Frap» (D).
      expect(docOf.get(it.id)).toMatch(/frap/i);
      expect(docOf.get(it.id)).toMatch(/смесител/i);
    }
    // Ранжирование ts_rank_cd: совпадение в названии выше совпадения в категории.
    expect(body.items[0].name).toMatch(/^Смеситель .*Frap/);
    const ids = body.items.map((i) => i.id);
    expect(ids).toContain(anchor.F4252);
    expect(ids).toContain(anchor.F3241);
  });

  it('«Frap F4252» → fts, якорный товар первым', async () => {
    const body = await search('Frap F4252');
    expect(body.items[0]).toMatchObject({ id: anchor.F4252, matchType: 'fts', sku: 'F4252' });
    expect(body.matchTypes.fts).toBeGreaterThan(0);
  });

  it('штрихкод → barcode, ровно один товар', async () => {
    const body = await search(anchorBarcode);
    expect(body.matchTypes).toEqual({ barcode: 1, sku: 0, fts: 0, trgm: 0 });
    expect(body.items).toHaveLength(1);
    expect(body.items[0]).toMatchObject({ id: anchor.F4252, matchType: 'barcode' });
  });

  // 12 T-CAT-002 (точный артикул первым, префикс)
  it('артикул «F4252» → sku, точное совпадение первым; префикс «F425» тоже находит', async () => {
    const exact = await search('F4252');
    expect(exact.items[0]).toMatchObject({ id: anchor.F4252, matchType: 'sku' });
    const prefix = await search('f425');
    expect(prefix.items.map((i) => i.id)).toContain(anchor.F4252);
    expect(prefix.items.every((i) => i.matchType === 'sku' && /^F425/i.test(i.sku ?? ''))).toBe(true);
    const dashed = await search('g1017-8');
    expect(dashed.items[0]).toMatchObject({ id: anchor['G1017-8'], matchType: 'sku' });
  });

  it('артикул с опечаткой «SB-1WJ» (вместо SB-1WH) → trgm, нужный товар первым', async () => {
    const body = await search('SB-1WJ');
    expect(body.matchTypes).toMatchObject({ barcode: 0, sku: 0, fts: 0 });
    expect(body.matchTypes.trgm).toBeGreaterThan(0);
    expect(body.items[0]).toMatchObject({ id: anchor['SB-1WH'], matchType: 'trgm' });
    const typo2 = await search('VTP-21');
    expect(typo2.items[0]).toMatchObject({ id: anchor['VTP-20'], matchType: 'trgm' });
  });

  it('AC-DATA-242: «смесител» → fts, «смиситель» (опечатка) → trgm', async () => {
    const fts = await search('смесител');
    expect(fts.items.length).toBeGreaterThan(0);
    expect(fts.items.every((i) => i.matchType === 'fts')).toBe(true);
    const typo = await search('смиситель');
    expect(typo.matchTypes.trgm).toBeGreaterThan(0);
    // Исправление по словарю названий search_words → suggestedQuery (08 §4.5.1).
    expect(typo.suggestedQuery).toBe('смеситель');
    const typo2 = await search('унетаз компакт');
    expect(typo2.suggestedQuery).toBe('унитаз компакт');
    expect(typo2.items[0].name).toMatch(/^Унитаз-компакт/);
    expect(typo.items[0].name).toMatch(/^Смеситель/);
    expect(typo.items.every((i) => i.matchType === 'trgm')).toBe(true);
  });

  it('T-CAT-014: регистр и ё/е не важны («КОТЕЛ» = «Котёл», «шпаклевка» = «Шпаклёвка»)', async () => {
    const kotel = await search('КОТЕЛ');
    expect(kotel.items.length).toBeGreaterThan(0);
    expect(kotel.items.every((i) => /котёл/i.test(i.name))).toBe(true);
    const shp = await search('шпаклевка');
    expect(shp.items.length).toBeGreaterThan(0);
    expect(shp.items.every((i) => /шпаклёвка/i.test(i.name))).toBe(true);
  });

  it('раскладка: «cvtcbntkm» (смеситель в латинской раскладке) → fts', async () => {
    const body = await search('cvtcbntkm');
    expect(body.matchTypes.fts).toBeGreaterThan(0);
    expect(body.items.every((i) => i.matchType === 'fts')).toBe(true);
    expect(body.items[0].name).toMatch(/^Смеситель/);
  });

  it('код 1С (onec_code) → sku', async () => {
    const r = await f.pool.query<{ onec_code: string }>('SELECT onec_code FROM products WHERE id = $1', [
      anchor['SB-1WH'],
    ]);
    const body = await search(r.rows[0].onec_code);
    expect(body.items[0]).toMatchObject({ id: anchor['SB-1WH'], matchType: 'sku' });
  });
});

describe('пустой, короткий и опасный ввод', () => {
  it('q < 2 символов → 422 VALIDATION_FAILED rule q_too_short; пустой — тоже; без q — 400', async () => {
    for (const q of ['с', ' ', '', '%']) {
      const res = await get('/search/products', 'seller', { q });
      expect(res.status, q).toBe(422);
      expect(res.body).toMatchObject({ code: 'VALIDATION_FAILED', errors: [{ field: 'q', rule: 'q_too_short' }] });
    }
    const none = await get('/search/products');
    expect(none.status).toBe(400);
    const long = await get('/search/products', 'seller', { q: 'а'.repeat(201) });
    expect(long.status).toBe(400);
    const suggest = await get('/search/suggest', 'seller', { q: 'с' });
    expect(suggest.status).toBe(422);
  });

  it('одна цифра допустима (цифровая строка ≥ 1)', async () => {
    const res = await get('/search/products', 'seller', { q: '5' });
    expect(res.status).toBe(200);
  });

  // 12 T-CAT-015, T-SEC-027 (класс A: SQL/tsquery-операторы в q; sqlmap класса B — не выполнялся)
  it('спецсимволы и SQL-инъекция безопасны: 200, схема цела', async () => {
    const before = await f.pool.query<{ n: string }>('SELECT count(*) AS n FROM products');
    const evil = [
      "'; DROP TABLE products; --",
      "смеситель' OR '1'='1",
      'смеситель & | ! ( ) :* <-> \\',
      '%%',
      '_%_',
      "f4252'--",
      '"; SELECT pg_sleep(5); --',
      '$1 $2 ::uuid',
      'смеситель\u0000',
      '🙂🙂',
      '((((',
    ];
    for (const q of evil) {
      const res = await get('/search/products', 'seller', { q });
      expect([200, 422], `${q}: ${JSON.stringify(res.body)}`).toContain(res.status);
      const s = await get('/search/suggest', 'seller', { q });
      expect([200, 422], `suggest ${q}`).toContain(s.status);
    }
    const attr = await get('/search/products', 'seller', { q: 'смеситель', "attr[x' OR 1=1 --]": "y'; DROP TABLE x" });
    expect(attr.status).toBe(200);
    expect(attr.body.items).toEqual([]);
    const brand = await get('/search/products', 'seller', { q: 'смеситель', brand: 'a\'b,c"d' });
    expect(brand.status).toBe(200);
    const nul = await get('/search/products', 'seller', {
      q: 'смеситель',
      brand: 'a\u0000b',
      'attr[strana]': 'x\u0000',
    });
    expect(nul.status).toBe(200);
    const after = await f.pool.query<{ n: string }>('SELECT count(*) AS n FROM products');
    expect(after.rows[0].n).toBe(before.rows[0].n);
  });

  // 12 T-CAT-009 (запрос без совпадений)
  it('ничего не найдено → пустая страница, matchTypes нули', async () => {
    const body = await search('ъъъъъъъъ');
    expect(body).toMatchObject({ items: [], hasMore: false, nextCursor: null, totalEstimate: 0 });
    expect(body.matchTypes).toEqual({ barcode: 0, sku: 0, fts: 0, trgm: 0 });
  });
});

describe('страницы, сортировки, фильтры (RM-E-014)', () => {
  it('limit=201 → 400 VALIDATION_FAILED; limit=200 → 200', async () => {
    const bad = await get('/search/products', 'seller', { q: 'смеситель', limit: '201' });
    expect(bad.status).toBe(400);
    expect(bad.body).toMatchObject({ code: 'VALIDATION_FAILED', errors: [{ field: 'limit' }] });
    const ok = await get('/search/products', 'seller', { q: 'смеситель', limit: '200' });
    expect(ok.status).toBe(200);
    expect(ok.body.items.length).toBeLessThanOrEqual(200);
  });

  it('курсор: страницы по 7 без пропусков и повторов совпадают с одной страницей 200', async () => {
    const full = await search('смеситель', { limit: '200' });
    expect(full.hasMore).toBe(false);
    const seen: string[] = [];
    let cursor: string | null = null;
    for (let i = 0; i < 100; i++) {
      const page: SearchBody = await search('смеситель', { limit: '7', ...(cursor ? { cursor } : {}) });
      seen.push(...page.items.map((x) => x.id));
      expect(page.totalEstimate === null || page.totalEstimate === full.totalEstimate).toBe(true);
      cursor = page.nextCursor;
      if (!cursor) break;
    }
    expect(seen).toEqual(full.items.map((x) => x.id));
  });

  it('курсор другой сортировки → cursor_sort_mismatch; подделка → cursor; другой q → cursor', async () => {
    const p1 = await search('смеситель', { limit: '3' });
    expect(p1.nextCursor).toBeTruthy();
    const mism = await get('/search/products', 'seller', {
      q: 'смеситель',
      limit: '3',
      sort: 'name:asc',
      cursor: p1.nextCursor!,
    });
    expect(mism.status).toBe(400);
    expect(mism.body.errors[0].rule).toBe('cursor_sort_mismatch');
    const forged = await get('/search/products', 'seller', {
      q: 'смеситель',
      cursor: `${p1.nextCursor!.slice(0, -2)}xx`,
    });
    expect(forged.body.errors[0].rule).toBe('cursor');
    const otherQ = await get('/search/products', 'seller', { q: 'унитаз', limit: '3', cursor: p1.nextCursor! });
    expect(otherQ.body.errors[0].rule).toBe('cursor');
  });

  it('курсор ступени trgm (исправление → исходный запрос): страницы по 3 совпадают с одной страницей 200 (ревью E-api-2)', async () => {
    for (const q of ['радиатр смеситель', 'смиситель', 'SB-1WJ']) {
      const full = await search(q, { limit: '200' });
      expect(full.hasMore, q).toBe(false);
      const seen: string[] = [];
      let cursor: string | null = null;
      for (let i = 0; i < 200; i++) {
        const page: SearchBody = await search(q, { limit: '3', ...(cursor ? { cursor } : {}) });
        seen.push(...page.items.map((x) => x.id));
        // вариант ступени не меняется между страницами: тот же matchType и та же подсказка
        expect(page.suggestedQuery, q).toBe(full.suggestedQuery);
        if (page.items.length > 0) expect(page.items[0].matchType, q).toBe(full.items[0]?.matchType);
        cursor = page.nextCursor;
        if (!cursor) break;
      }
      expect(seen, q).toEqual(full.items.map((x) => x.id));
    }
    // Эталон дефекта: исправление «радиатор смеситель» по FTS не находит ничего → сравнение триграммами по исходному.
    const raw = await search('радиатр смеситель', { limit: '3' });
    expect(raw.matchTypes.trgm).toBeGreaterThan(3);
    expect(raw.suggestedQuery).toBeNull();
  });

  it('customer + customer_stock_display=status, sort=available:desc: курсор не раскрывает остаток (ревью E-api-1)', async () => {
    const page = await search('смеситель', { limit: '2', sort: 'available:desc' }, 'customer');
    expect(page.nextCursor).toBeTruthy();
    const raw = Buffer.from(page.nextCursor!, 'base64url').toString('latin1');
    expect(raw).not.toMatch(/\d+\.\d{3}/);
    expect(raw).not.toContain('available');
    // Продолжение работает (курсор расшифровывается сервером).
    const next = await search(
      'смеситель',
      { limit: '2', sort: 'available:desc', cursor: page.nextCursor! },
      'customer',
    );
    expect(next.items.length).toBeGreaterThan(0);
    expect(next.items.map((i) => i.id)).not.toContain(page.items[0].id);
  });

  it('sort неизвестный → 400 rule sort_field', async () => {
    const res = await get('/search/products', 'seller', { q: 'смеситель', sort: 'popularity:desc' });
    expect(res.status).toBe(400);
    expect(res.body.errors[0].rule).toBe('sort_field');
  });

  // 12 T-CAT-016
  it('sort=sku:asc и sort=available:desc дают ожидаемый порядок (по всем страницам)', async () => {
    const collect = async (sort: string) => {
      const out: Item[] = [];
      let cursor: string | null = null;
      do {
        const page: SearchBody = await search('смеситель', { sort, limit: '50', ...(cursor ? { cursor } : {}) });
        out.push(...page.items);
        cursor = page.nextCursor;
      } while (cursor);
      return out;
    };
    const bySku = await collect('sku:asc');
    const skus = bySku.map((i) => (i.sku ?? '').replace(/[\s\-_./]+/g, '').toUpperCase());
    const withSku = skus.filter((s) => s !== '');
    expect(withSku).toEqual([...withSku].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)));
    expect(skus.slice(withSku.length).every((s) => s === '')).toBe(true);

    const byAvail = await collect('available:desc');
    const av = byAvail.map((i) => (typeof i.stock?.available === 'string' ? Number(i.stock.available) : null));
    const known = av.filter((x): x is number => x !== null);
    expect(known.length).toBeGreaterThan(0);
    for (let i = 1; i < known.length; i++) expect(known[i - 1]).toBeGreaterThanOrEqual(known[i]);
    // товары без снимка остатка — в конце
    const firstUnknown = av.indexOf(null);
    if (firstUnknown >= 0) expect(av.slice(firstUnknown).every((x) => x === null)).toBe(true);
  });

  // 12 T-CAT-016 (цена не убывает / не возрастает)
  it('sort=price:asc / price:desc: цены монотонны, без цены — в конце', async () => {
    for (const sort of ['price:asc', 'price:desc']) {
      const body = await search('смеситель', { sort, limit: '200' });
      // Ключ сортировки: у товара с характеристиками — min (asc) / max (desc) из priceRange (как /catalog/products).
      const prices = body.items.map((i) =>
        i.priceRange
          ? Number(sort === 'price:asc' ? i.priceRange.min.amount : i.priceRange.max.amount)
          : i.price
            ? Number(i.price.price.amount)
            : null,
      );
      const known = prices.filter((x): x is number => x !== null);
      expect(known.length).toBeGreaterThan(0);
      for (let i = 1; i < known.length; i++) {
        if (sort === 'price:asc') expect(known[i - 1]).toBeLessThanOrEqual(known[i]);
        else expect(known[i - 1]).toBeGreaterThanOrEqual(known[i]);
      }
      const nul = prices.indexOf(null);
      if (nul >= 0) expect(prices.slice(nul).every((x) => x === null)).toBe(true);
    }
  });

  it.each(PRODUCT_FILTER_PARAMS)('фильтр /catalog/products «%s» принимается /search/products', async (param) => {
    const cat = await f.pool.query<{ id: string }>(`SELECT category_id::text AS id FROM products WHERE id = $1`, [
      anchor.F4252,
    ]);
    const wh = await f.pool.query<{ id: string }>(
      `SELECT id::text FROM warehouses WHERE NOT deletion_mark AND is_active LIMIT 1`,
    );
    const pl = await f.pool.query<{ id: string }>(`SELECT id::text FROM price_lists WHERE NOT deletion_mark LIMIT 1`);
    const values: Record<string, Record<string, string>> = {
      categoryId: { categoryId: cat.rows[0].id },
      includeSubcategories: { includeSubcategories: 'false' },
      warehouseId: { warehouseId: wh.rows[0].id },
      priceListId: { priceListId: pl.rows[0].id },
      inStock: { inStock: 'true' },
      priceMin: { priceMin: '100.00' },
      priceMax: { priceMax: '100000.00' },
      brand: { brand: 'Frap,Gappo' },
      attr: { 'attr[strana]': 'Китай' },
      favorite: { favorite: 'true' },
      hasImage: { hasImage: 'false' },
    };
    const role = param === 'priceListId' ? 'cashier' : 'seller';
    const res = await get('/search/products', role, { q: 'смеситель', ...values[param] });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(validateAgainst(SEARCH_PAGE_SCHEMA, res.body)).toEqual([]);
  });

  it('фильтры сужают выдачу: категория, inStock, диапазон цены, attr', async () => {
    const all = await search('смеситель', { limit: '200' });
    const cat = await f.pool.query<{ id: string }>(`SELECT category_id::text AS id FROM products WHERE id = $1`, [
      anchor.F4252,
    ]);
    const inCat = await search('смеситель', {
      limit: '200',
      categoryId: cat.rows[0].id,
      includeSubcategories: 'false',
    });
    expect(inCat.items.length).toBeGreaterThan(0);
    expect(inCat.items.length).toBeLessThanOrEqual(all.items.length);
    const inStock = await search('смеситель', { limit: '200', inStock: 'true' });
    expect(inStock.items.every((i) => Number((i.stock as { available?: string }).available) > 0)).toBe(true);
    const cheap = await search('смеситель', { limit: '200', priceMax: '1000.00' });
    expect(cheap.items.length).toBeLessThan(all.items.length);
    const china = await search('смеситель', { limit: '200', 'attr[strana]': 'Китай' });
    expect(china.items.length).toBeGreaterThan(0);
    expect(china.items.length).toBeLessThan(all.items.length);
  });
});

describe('роли: цены и остатки по правилам Catalog API', () => {
  it('seller: priceListId → 403; cashier — разрешён', async () => {
    const pl = await f.pool.query<{ id: string }>(`SELECT id::text FROM price_lists WHERE NOT deletion_mark LIMIT 1`);
    const seller = await get('/search/products', 'seller', { q: 'смеситель', priceListId: pl.rows[0].id });
    expect(seller.status).toBe(403);
    const cashier = await get('/search/products', 'cashier', { q: 'смеситель', priceListId: pl.rows[0].id });
    expect(cashier.status).toBe(200);
  });

  // 12 T-CAT-032 (customer: чужой priceListId → 403, остаток без количеств)
  it('customer: priceListId → 403; остаток только stockLevel (без quantity/reserved/available)', async () => {
    const pl = await f.pool.query<{ id: string }>(`SELECT id::text FROM price_lists WHERE NOT deletion_mark LIMIT 1`);
    const forbidden = await get('/search/products', 'customer', { q: 'смеситель', priceListId: pl.rows[0].id });
    expect(forbidden.status).toBe(403);
    const body = await search('смеситель', { limit: '50' }, 'customer');
    expect(body.items.length).toBeGreaterThan(0);
    for (const it of body.items) {
      if (it.stock) {
        expect(it.stock).not.toHaveProperty('quantity');
        expect(it.stock).not.toHaveProperty('reserved');
        expect(it.stock).not.toHaveProperty('available');
        expect(it.stock).toHaveProperty('stockLevel');
      }
    }
    expect(validateAgainst(SEARCH_PAGE_SCHEMA, body)).toEqual([]);
  });

  it('staff: цена — Money-строка, остаток — количества строками; ответ по схеме OpenAPI', async () => {
    const res = await get('/search/products', 'cashier', { q: 'Frap F4252' });
    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('private, max-age=30');
    expect(validateAgainst(SEARCH_PAGE_SCHEMA, res.body)).toEqual([]);
    const first = res.body.items[0] as Item;
    expect(first.price?.price.amount).toMatch(/^\d+\.\d{2}$/);
  });

  it('без субъекта → 401; integration → 403', async () => {
    const anon = await request(app.getHttpServer()).get('/api/v1/search/products').query({ q: 'смеситель' });
    expect(anon.status).toBe(401);
    const integ = await get('/search/products', 'integration', { q: 'смеситель' });
    expect(integ.status).toBe(403);
  });
});

describe('GET /search/barcode/{value} и GET /search/suggest', () => {
  // 12 T-CAT-002 (штрихкод варианта ведёт к товару с вариантом), T-CAT-012 (GET /search/barcode)
  it('штрихкод варианта → product + variant, packaging null, предлагаемое количество в базовой единице', async () => {
    const res = await get(`/search/barcode/${anchorBarcode}`, 'cashier');
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.headers['cache-control']).toBe('private, max-age=30');
    expect(validateAgainst('SearchBarcodeResult', res.body)).toEqual([]);
    expect(res.body.product).toMatchObject({ id: anchor.F4252, matchType: 'barcode' });
    expect(res.body.variant.barcodes).toContain(anchorBarcode);
    expect(res.body.packaging).toBeNull();
    expect(res.body.barcodeType).toBe('EAN13');
    expect(res.body.suggestedQuantity).toMatchObject({ value: '1.000', packagingId: null });
  });

  it('штрихкод упаковки → packaging с фактором, предлагается 1 упаковка', async () => {
    expect(packBarcode).toBeDefined();
    const res = await get(`/search/barcode/${packBarcode!.value}`, 'seller');
    expect(res.status).toBe(200);
    expect(validateAgainst('SearchBarcodeResult', res.body)).toEqual([]);
    expect(res.body.packaging).toMatchObject({ id: packBarcode!.packagingId, barcode: packBarcode!.value });
    expect(res.body.suggestedQuantity).toMatchObject({ value: '1.000', packagingId: packBarcode!.packagingId });
    expect(res.body.suggestedQuantity.baseValue).toBe(res.body.packaging.factor);
  });

  // 12 T-CAT-012 (неизвестный код)
  it('неизвестный штрихкод → 404 NOT_FOUND; неверный формат → 400', async () => {
    const nf = await get('/search/barcode/0000000000000');
    expect(nf.status).toBe(404);
    expect(nf.body.code).toBe('NOT_FOUND');
    const bad = await get('/search/barcode/ab');
    expect(bad.status).toBe(400);
    const bad2 = await get(`/search/barcode/${encodeURIComponent("1' OR '1'='1")}`);
    expect(bad2.status).toBe(400);
  });

  // 12 T-CAT-019
  it('подсказки: ≤ 10, виды product/category/sku, по схеме OpenAPI', async () => {
    const res = await get('/search/suggest', 'seller', { q: 'сме' });
    expect(res.status).toBe(200);
    expect(validateAgainst('SearchSuggestResponse', res.body)).toEqual([]);
    const items = (res.body as { items: { kind: string; text: string }[] }).items;
    expect(items.length).toBeGreaterThan(0);
    expect(items.length).toBeLessThanOrEqual(10);
    expect(items.some((i) => i.kind === 'category')).toBe(true);
    expect(items.some((i) => i.kind === 'product')).toBe(true);
    const sku = await get('/search/suggest', 'seller', { q: 'F425', limit: '5' });
    const skuItems = (sku.body as { items: { kind: string }[] }).items;
    expect(skuItems[0]).toMatchObject({ kind: 'sku' });
    expect(skuItems.length).toBeLessThanOrEqual(5);
    const word = await get('/search/suggest', 'seller', { q: 'frap' });
    expect((word.body as { items: { text: string }[] }).items.some((i) => /frap/i.test(i.text))).toBe(true);
    const tooMany = await get('/search/suggest', 'seller', { q: 'сме', limit: '11' });
    expect(tooMany.status).toBe(400);
  });
});

describe('нормализация SQL ↔ TS', () => {
  it('norm_sku(SQL) = normSku(TS) на наборе строк', async () => {
    const { normSku } = await import('../../src/catalog/search/search-text.js');
    const samples = ['СМ-12 a', 'g1017-8', 'F4252', 'a_b.c/d', 'Ёж-1', 'VTP 20'];
    const r = await f.pool.query<{ s: string; n: string }>('SELECT s, norm_sku(s) AS n FROM unnest($1::text[]) AS s', [
      samples,
    ]);
    for (const row of r.rows) expect(normSku(row.s)).toBe(row.n);
  });
});

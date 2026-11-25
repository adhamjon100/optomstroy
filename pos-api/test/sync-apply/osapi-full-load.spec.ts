import pino from 'pino';
import { osApiDerivedRef } from '../../src/integrations/onec/onec-osapi.mapping.js';
import { CatalogApplier } from '../../src/sync/apply/catalog-applier.js';
import { CatalogFullLoadService } from '../../src/sync/apply/catalog-full-load.service.js';
import { OsApiCatalogSource } from '../../src/sync/apply/osapi-catalog.source.js';
import { createRunTracker } from '../../src/sync/apply/run-tracker.js';
import { type CatalogFixture, startCatalogFixture } from '../support/catalog-fixture.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { OSAPI_FIXTURE, OSAPI_REFS, osApiTestClient, standardOsApi } from '../support/osapi-fake.js';

/**
 * ADR-126: полная загрузка каталога из ОС_API (`ONEC_MODE=os_api`) тем же конвейером применения на embedded
 * PostgreSQL 17 (все миграции, без синтетического каталога). Ответы ОС_API — синтетические фикстуры по форме
 * Module.bsl 0.2.9 (вымышленные данные). Проверяется: маппинг справочников, разворот характеристик/упаковок
 * категории, удалённые, цены по видам, остатки (`available_onec` = free 1С), пометка исчезнувших при повторе.
 */
const silent = pino({ level: 'silent' });
const R = OSAPI_REFS;
let server: EmbeddedPg;
let fx: CatalogFixture;

beforeAll(async () => {
  server = new EmbeddedPg();
  await server.start();
  fx = await startCatalogFixture({ pg: server, database: 'osapi_full', skipLoad: true });
});

afterAll(async () => {
  await fx?.stop();
  await server?.stop();
});

describe('ADR-126: ОС_API → реплики каталога', () => {
  it('полная загрузка: товары, варианты, упаковки, штрихкоды, цены, остатки; удалённые помечены', async () => {
    const svc = new CatalogFullLoadService(fx.pool, new CatalogApplier(), createRunTracker(fx.pool), silent);
    const source = new OsApiCatalogSource(osApiTestClient(standardOsApi()), { pageSize: 2 });
    const results = await svc.loadAll(source, 'full', 'manual');
    expect(results.map((r) => r.entity)).toContain('stock');

    const q = async <T extends Record<string, unknown>>(sql: string, params: unknown[] = []): Promise<T[]> =>
      (await fx.pool.query<T>(sql, params)).rows;

    const products = await q<{ ref: string; name: string; deletion_mark: boolean; is_weighted: boolean }>(
      `SELECT onec_ref::text AS ref, name, deletion_mark, is_weighted FROM products
        WHERE onec_ref = ANY($1::uuid[]) ORDER BY onec_ref`,
      [[R.CEM, R.PNT, R.TIL, R.OLD]],
    );
    expect(products.map((p) => [p.ref, p.deletion_mark])).toEqual([
      [R.CEM, false],
      [R.PNT, false],
      [R.TIL, false],
      [R.OLD, true],
    ]);
    expect(products[0]).toMatchObject({ name: 'Смесь тестовая М-1', is_weighted: true });

    const derivedRed = osApiDerivedRef('characteristic', R.CH_R, R.PNT);
    const variants = await q<{ ref: string; product: string; deletion_mark: boolean }>(
      `SELECT v.onec_ref::text AS ref, p.onec_ref::text AS product, v.deletion_mark FROM product_variants v
         JOIN products p ON p.id = v.product_id WHERE NOT v.is_default ORDER BY v.onec_ref`,
    );
    expect(variants).toEqual(
      [
        { ref: R.CH_W, product: R.TIL, deletion_mark: false },
        { ref: derivedRed, product: R.PNT, deletion_mark: false },
        { ref: R.CH_DEL, product: R.TIL, deletion_mark: true },
      ].sort((a, b) => a.ref.localeCompare(b.ref)),
    );

    const packs = await q<{ ref: string; product: string; factor: string }>(
      `SELECT k.onec_ref::text AS ref, p.onec_ref::text AS product, k.factor::text AS factor FROM packagings k
         JOIN products p ON p.id = k.product_id ORDER BY k.onec_ref`,
    );
    expect(packs).toHaveLength(3);
    expect(packs.find((p) => p.ref === R.UN_BAG)).toMatchObject({ product: R.CEM, factor: '50.000' });

    const barcodes = await q<{ value: string }>(`SELECT value FROM barcodes WHERE NOT deletion_mark ORDER BY value`);
    expect(barcodes.map((b) => b.value)).toEqual(['2000000000017', '2000000000024', '2000000000031']);

    const prices = await q<{ product: string; variant: string | null; pack: string | null; price: string }>(
      `SELECT p.onec_ref::text AS product, CASE WHEN v.is_default THEN NULL ELSE v.onec_ref::text END AS variant,
              k.onec_ref::text AS pack, pr.price::text AS price
         FROM prices pr JOIN product_variants v ON v.id = pr.variant_id JOIN products p ON p.id = v.product_id
         JOIN price_lists l ON l.id = pr.price_list_id LEFT JOIN packagings k ON k.id = pr.packaging_id
        WHERE l.onec_ref = $1 ORDER BY pr.price`,
      [R.PT1],
    );
    expect(prices).toEqual([
      { product: R.CEM, variant: null, pack: null, price: '120.50' },
      { product: R.PNT, variant: derivedRed, pack: null, price: '350.00' },
      { product: R.PNT, variant: null, pack: osApiDerivedRef('unit', R.UN_BOX, R.PNT), price: '4000.00' },
      { product: R.CEM, variant: null, pack: R.UN_BAG, price: '6000.00' },
    ]);
    // Цена с тремя знаками не округляется — позиция отклонена с ошибкой VALIDATION (видно в sync_errors).
    const priceErrors = await q<{ error_code: string; message: string }>(
      `SELECT error_code, message FROM sync_errors WHERE entity = 'prices'`,
    );
    expect(priceErrors.some((e) => e.error_code === 'VALIDATION' && /2 знаков/.test(e.message))).toBe(true);
    // Цены и штрихкод на упаковке набора единиц (unitSet) и цена на упаковке вне /units пропускаются источником
    // намеренно: ни NOT_FOUND_LOCAL, ни иных ошибок уровня error, кроме отклонённой цены с тремя знаками.
    const unitErrors = await q<{ entity: string; error_code: string }>(
      `SELECT entity, error_code FROM sync_errors
        WHERE entity IN ('prices', 'barcodes') AND severity = 'error' AND error_code <> 'VALIDATION'`,
    );
    expect(unitErrors).toEqual([]);

    const stock = await q<{ product: string; wh: string; quantity: string; reserved: string; available_onec: string }>(
      `SELECT p.onec_ref::text AS product, w.onec_ref::text AS wh, s.quantity::text AS quantity,
              s.reserved::text AS reserved, s.available_onec::text AS available_onec
         FROM stock_balances s JOIN product_variants v ON v.id = s.variant_id JOIN products p ON p.id = v.product_id
         JOIN warehouses w ON w.id = s.warehouse_id ORDER BY s.quantity DESC`,
    );
    expect(stock).toEqual([
      { product: R.CEM, wh: R.WH1, quantity: '100.000', reserved: '30.000', available_onec: '70.000' },
      { product: R.TIL, wh: R.WH2, quantity: '12.500', reserved: '0.000', available_onec: '12.500' },
      { product: R.PNT, wh: R.WH1, quantity: '5.000', reserved: '8.000', available_onec: '0.000' },
    ]);

    const lists = await q<{ ref: string; deletion_mark: boolean }>(
      `SELECT onec_ref::text AS ref, deletion_mark FROM price_lists WHERE onec_ref IS NOT NULL ORDER BY onec_ref`,
    );
    expect(lists).toEqual([
      { ref: R.PT1, deletion_mark: false },
      { ref: R.PT2, deletion_mark: false },
      { ref: R.PT3, deletion_mark: true },
    ]);
  });

  it('повтор: склад, исчезнувший из /warehouses (помечен в 1С), и пропавший товар помечаются; без изменений — пропуск', async () => {
    const svc = new CatalogFullLoadService(fx.pool, new CatalogApplier(), createRunTracker(fx.pool), silent);
    const items = OSAPI_FIXTURE('items.json') as { items: { id: string }[] };
    const whs = OSAPI_FIXTURE('warehouses.json') as { items: { id: string }[] };
    const t = standardOsApi()
      .on('/items', { body: { items: items.items.filter((i) => i.id !== R.TIL) } })
      .on('/warehouses', { body: { items: whs.items.filter((w) => w.id !== R.WH2) } });
    const source = new OsApiCatalogSource(osApiTestClient(t));
    const res = await svc.run({ entity: 'warehouses', mode: 'full', source });
    expect(res.counts?.markedDeleted).toBe(1);
    const products = await svc.run({ entity: 'products', mode: 'full', source });
    expect(products.counts?.markedDeleted).toBe(1);
    const r = await fx.pool.query<{ ref: string; deletion_mark: boolean }>(
      `SELECT onec_ref::text AS ref, deletion_mark FROM products WHERE onec_ref = ANY($1::uuid[]) ORDER BY onec_ref`,
      [[R.CEM, R.TIL]],
    );
    expect(r.rows).toEqual([
      { ref: R.CEM, deletion_mark: false },
      { ref: R.TIL, deletion_mark: true },
    ]);
    const wh = await fx.pool.query<{ deletion_mark: boolean }>(
      `SELECT deletion_mark FROM warehouses WHERE onec_ref = $1`,
      [R.WH2],
    );
    expect(wh.rows[0]?.deletion_mark).toBe(true);
    expect(t.requests.every((x) => x.method === 'GET')).toBe(true);
  });
});

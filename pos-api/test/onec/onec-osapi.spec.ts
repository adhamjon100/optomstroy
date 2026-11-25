import { createHash } from 'node:crypto';
import type pg from 'pg';
import pino from 'pino';
import { ConfigError, loadAppConfig } from '../../src/common/config/app-config.js';
import { SYNC_ENTITY_VALUES } from '../../src/common/enums.js';
import { createOrdersWorkerWiring } from '../../src/jobs/orders/orders-worker.wiring.js';
import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import { onecAdapters } from '../../src/integrations/onec/onec-adapters.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import { createOnecGateway } from '../../src/integrations/onec/onec-gateway.factory.js';
import { ONEC_OPERATIONS, type OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import { OnecTransportError } from '../../src/integrations/onec/onec-http-transport.js';
import { OnecODataGateway } from '../../src/integrations/onec/onec-odata.gateway.js';
import { OnecOsApiClient } from '../../src/integrations/onec/onec-osapi.client.js';
import { OnecOsApiGateway, osApiVersion } from '../../src/integrations/onec/onec-osapi.gateway.js';
import {
  OSAPI_UNREPRESENTABLE,
  OsApiCatalogIndex,
  osApiDate,
  osApiDerivedRef,
  osApiMoney,
  osApiQty,
} from '../../src/integrations/onec/onec-osapi.mapping.js';
import { OSAPI_FIXTURE, OSAPI_REFS, OSAPI_ROOT, osApiTestClient, osu, standardOsApi } from '../support/osapi-fake.js';
import { createPaymentProvider } from '../../src/integrations/payments/payment-provider.factory.js';
import { isApiVersionCompatible } from '../../src/sync/alerts/onec-api-compat.js';
import type {
  OnecBarcodeItem,
  OnecCatalogItem,
  OnecNomenclatureItem,
  OnecPackagingItem,
  OnecPriceListItem,
  OnecVariantItem,
} from '../../src/integrations/onec/onec-catalog.types.js';
import { ODataCatalogSource } from '../../src/sync/apply/odata-catalog.source.js';
import { OsApiCatalogSource } from '../../src/sync/apply/osapi-catalog.source.js';
import { createCatalogFullSource } from '../../src/sync/apply/sync-apply.module.js';
import { createImageListSource } from '../../src/sync/images/images.module.js';
import { OsApiImageListSource } from '../../src/sync/images/osapi-image-list.source.js';
import { schedulerConfigFromEnv } from '../../src/sync/scheduler/scheduler.config.js';
import { OSAPI_POLLED_ENTITIES, osApiPollCron, scheduledEntities } from '../../src/sync/scheduler/sync-queues.js';

/**
 * ADR-126: режим `ONEC_MODE=os_api` — существующий HTTP-сервис 1С «ОС_API», только чтение. Ответы — синтетические
 * фикстуры по форме `Module.bsl` 0.2.9 (вымышленные данные, test/onec/osapi-fixtures), транспорт — в памяти.
 */

const FIX = OSAPI_FIXTURE;
const ROOT = OSAPI_ROOT;
const U = osu;
const { PT1, PT2, PT3, WH1, WH2, GRP, CEM, PNT, TIL, OLD, KG, SHT, CH_W, CH_R, CH_DEL, UN_BAG, UN_BOX, F1, F2, F3 } =
  OSAPI_REFS;
const standard = standardOsApi;
const client = osApiTestClient;
/** Упаковка набора единиц (`ownerType = unitSet`) из units.json и упаковка, которой нет в `/units`. */
const UN_SET = osu('a2000000', 3);
const UN_MISSING = osu('a2000000', 9);

/** Журнал-шпион предупреждений источника. */
function warnSpy(): { warn(obj: object, msg: string): void; calls: { obj: object; msg: string }[] } {
  const calls: { obj: object; msg: string }[] = [];
  return { calls, warn: (obj, msg) => calls.push({ obj, msg }) };
}

const byOwnerRef = <T extends { ref: string; ownerRef: string }>(list: T[]): T[] =>
  [...list].sort((a, b) => (a.ownerRef < b.ownerRef ? -1 : a.ownerRef > b.ownerRef ? 1 : a.ref < b.ref ? -1 : 1));

async function all<T>(it: AsyncIterable<readonly T[]>): Promise<T[]> {
  const out: T[] = [];
  for await (const page of it) out.push(...page);
  return out;
}

const OSAPI_ENV = {
  MIN_APP_VERSION: 'android=1.2.0,windows=1.2.0',
  DATABASE_URL: 'postgres://env:env@127.0.0.1:5432/env',
  ONEC_MODE: 'os_api',
  ONEC_BASE_URL: 'http://localhost/uk_test',
  ONEC_USER: 'api_test',
  ONEC_PASSWORD: 'test-only', // check-secrets: allow — фиктивное значение теста
  QR_PROVIDER: 'none',
};

function expectConfigError(fn: () => unknown): string {
  try {
    fn();
  } catch (e) {
    expect(e).toBeInstanceOf(ConfigError);
    return (e as ConfigError).problems.join('\n');
  }
  throw new Error('ожидалась ConfigError');
}

describe('ADR-126: клиент ОС_API — только GET, Basic, ошибки → OnecError', () => {
  it('корень публикации + hs/os/api/v1, Basic пользователя публикации, X-Request-Id, таймаут ONEC_TIMEOUT_MS у /ping', async () => {
    const t = standard();
    const c = client(t);
    await c.ping({ requestId: 'req-1' });
    const r = t.requests[0];
    expect(r.method).toBe('GET');
    expect(r.url).toBe(`${ROOT}/ping`);
    expect(r.headers.Authorization).toBe(`Basic ${Buffer.from('api_test:test-only').toString('base64')}`);
    expect(r.headers['X-Request-Id']).toBe('req-1');
    expect(r.headers['X-POS-Client-Key']).toBeUndefined();
    expect(r.timeoutMs).toBe(7000);
    expect(c.serviceRoot).toBe(ROOT);
  });

  it('401 → POS_E_UNAUTHORIZED (не повторяется); 500 → повтор и успех; текст из {error:{message}}', async () => {
    const t = standard()
      .on('/items', { status: 401, body: 'Unauthorized' })
      .on('/units', [
        { status: 500, body: { error: { code: 'internal_error', message: 'Сбой' } } },
        { body: FIX('units.json') },
      ]);
    const c = client(t);
    const e = await c.items().catch((x: unknown) => x);
    expect(e).toBeInstanceOf(OnecError);
    expect((e as OnecError).status).toBe(401);
    expect((e as OnecError).code).toBe('POS_E_UNAUTHORIZED');
    expect((e as OnecError).operation).toBe('osapi:/items');
    expect(t.paths().filter((p) => p === '/items')).toHaveLength(1);
    const units = await c.units();
    expect(units.items).toHaveLength(3);
    expect(t.paths().filter((p) => p === '/units')).toHaveLength(2);
  });

  it('сбой транспорта → OnecError(status 0, TRANSPORT, retryable); не JSON → INVALID_RESPONSE; 404 → POS_E_NOT_FOUND', async () => {
    const t = standard()
      .on('/barcodes', new OnecTransportError('timeout'))
      .on('/units', new OnecTransportError('network'))
      .on('/warehouses', { body: '<html>' });
    const c = client(t);
    const tr = (await c.barcodes().catch((x: unknown) => x)) as OnecError;
    expect(tr.status).toBe(0);
    expect(tr.code).toBe('TRANSPORT');
    expect(tr.retryable).toBe(true);
    // Истёкший таймаут полной выгрузки — не больше одного повтора; прочий сбой сети — обычные 3 попытки.
    expect(t.paths().filter((p) => p === '/barcodes')).toHaveLength(2);
    await expect(c.units()).rejects.toMatchObject({ code: 'TRANSPORT' });
    expect(t.paths().filter((p) => p === '/units')).toHaveLength(3);
    const bad = (await c.warehouses().catch((x: unknown) => x)) as OnecError;
    expect(bad.code).toBe('INVALID_RESPONSE');
    const nf = (await c.stock(WH1).catch((x: unknown) => x)) as OnecError;
    expect(nf.status).toBe(404);
    expect(nf.code).toBe('POS_E_NOT_FOUND');
    expect(nf.message).toContain('Метод не найден');
  });

  it('полные выгрузки — таймаут 120 с (как у шлюза), /ping — ONEC_TIMEOUT_MS; таймаут выгрузки настраивается', async () => {
    const t = standard();
    const c = client(t);
    await c.items();
    await c.prices(PT1);
    await c.stock();
    await c.itemFiles();
    await c.ping();
    const timeouts = new Map(t.requests.map((r) => [r.url.slice(ROOT.length).split('?')[0], r.timeoutMs]));
    expect(timeouts.get('/items')).toBe(120_000);
    expect(timeouts.get('/prices')).toBe(120_000);
    expect(timeouts.get('/stock')).toBe(120_000);
    expect(timeouts.get('/item-files')).toBe(120_000);
    expect(timeouts.get('/ping')).toBe(7000);
    const t2 = standard();
    await new OnecOsApiClient(
      { baseUrl: 'http://localhost/uk_test', user: 'u', fullLoadTimeoutMs: 300_000 },
      t2,
    ).units();
    expect(t2.requests[0].timeoutMs).toBe(300_000);
  });

  it('параметр не UUID — отказ без запроса в 1С', async () => {
    const t = standard();
    const c = client(t);
    await expect(c.prices('../orders')).rejects.toMatchObject({ code: 'POS_E_BAD_REQUEST' });
    await expect(c.file('item', 'x/../../y')).rejects.toMatchObject({ code: 'POS_E_BAD_REQUEST' });
    expect(t.requests).toHaveLength(0);
  });
});

describe('ADR-126: значения ОС_API → формат модели', () => {
  it('деньги — 2 знака, количества — 3; больше знаков — как есть (отказ при применении, без округления)', () => {
    expect(osApiMoney(120.5)).toBe('120.50');
    expect(osApiMoney(6000)).toBe('6000.00');
    expect(osApiMoney(99.999)).toBe('99.999');
    expect(osApiMoney('12.3')).toBe('12.30');
    expect(osApiQty(12.5)).toBe('12.500');
    expect(osApiQty(-3)).toBe('-3.000');
    expect(osApiQty(1.23456)).toBe('1.23456');
    expect(osApiQty(1e-7)).toBe('0.000');
  });

  it('даты 1С без зоны → +06:00 (Asia/Bishkek); пустая дата 1С → null; зона сохраняется', () => {
    expect(osApiDate('2026-11-20T09:00:00')).toBe('2026-11-20T09:00:00+06:00');
    expect(osApiDate('0001-01-01T00:00:00')).toBeNull();
    expect(osApiDate('2026-11-20T09:00:00Z')).toBe('2026-11-20T09:00:00Z');
    expect(osApiDate(undefined)).toBeNull();
  });

  it('производная ссылка (UUID v5) детерминирована и различает пары', () => {
    const a = osApiDerivedRef('characteristic', CH_R, PNT);
    expect(a).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(osApiDerivedRef('characteristic', CH_R, PNT)).toBe(a);
    expect(osApiDerivedRef('characteristic', CH_R, CEM)).not.toBe(a);
    expect(osApiDerivedRef('unit', CH_R, PNT)).not.toBe(a);
  });
});

describe('ADR-126: OsApiCatalogSource — каталог, цены, остатки', () => {
  const read = async (s: OsApiCatalogSource, kind: Parameters<OsApiCatalogSource['read']>[0]) => all(s.read(kind));

  it('склады и виды цен: без групп; deleted → deletionMark; ONEC_OSAPI_PRICE_TYPES ограничивает виды цен', async () => {
    const s = new OsApiCatalogSource(client(standard()));
    const whs = await read(s, 'warehouses');
    expect(whs.map((w) => w.ref).sort()).toEqual([WH1, WH2].sort());
    expect(whs[0]).toMatchObject({ type: 'Catalog_Склады', deletionMark: false, isFolder: false });
    const pls = (await read(s, 'price_lists')) as OnecPriceListItem[];
    // Наборы — в порядке ссылок (продолжение после обрыва по номеру позиции, SYNC-002).
    expect(pls.map((p) => [p.ref, p.deletionMark])).toEqual([
      [PT1, false],
      [PT2, false],
      [PT3, true],
    ]);
    expect(pls[0].currency).toBeNull();
    expect(await s.count('price_lists')).toBe(2);
    const only = new OsApiCatalogSource(client(standard()), { priceTypes: [PT1.toUpperCase()] });
    expect((await read(only, 'price_lists')).map((p) => p.ref)).toEqual([PT1]);
  });

  it('единицы — из baseUnitId/baseUnitName товаров; группы → категории, товары с deleted → deletionMark', async () => {
    const s = new OsApiCatalogSource(client(standard()));
    const units = await read(s, 'units');
    expect(units.map((u) => [u.ref, (u as { description: string }).description])).toEqual([
      [KG, 'кг'],
      [SHT, 'шт'],
    ]);
    const cats = (await read(s, 'categories')) as OnecNomenclatureItem[];
    expect(cats).toHaveLength(1);
    expect(cats[0]).toMatchObject({ ref: GRP, isFolder: true, parentRef: null, description: 'Тестовая группа' });
    const products = (await read(s, 'products')) as OnecNomenclatureItem[];
    expect(products.map((p) => p.ref)).toEqual([CEM, PNT, TIL, OLD]);
    const cem = products[0];
    expect(cem).toMatchObject({
      type: 'Catalog_Номенклатура',
      isFolder: false,
      code: '00010',
      description: 'Смесь тестовая М-1',
      fullName: 'Смесь тестовая М-1 (полное)',
      sku: 'ART-00010',
      parentRef: GRP,
      baseUnitRef: KG,
      isWeighted: true,
      brandUnknown: true,
      deletionMark: false,
      dataVersion: '2026-11-20T08:30:00+06:00',
    });
    expect(products.find((p) => p.ref === OLD)?.deletionMark).toBe(true);
    expect(await s.count('products')).toBe(3);
  });

  it('упаковки: товара — как есть; категории — по каждому товару категории; unitSet пропускается', async () => {
    const s = new OsApiCatalogSource(client(standard()));
    const packs = (await read(s, 'packagings')) as OnecPackagingItem[];
    expect(packs.map((p) => [p.ref, p.ownerRef, p.unitRef, p.factor])).toEqual(
      byOwnerRef([
        { ref: UN_BAG, ownerRef: CEM, unitRef: KG, factor: '50.000' },
        { ref: osApiDerivedRef('unit', UN_BOX, CEM), ownerRef: CEM, unitRef: KG, factor: '12.000' },
        { ref: osApiDerivedRef('unit', UN_BOX, PNT), ownerRef: PNT, unitRef: SHT, factor: '12.000' },
      ]).map((p) => [p.ref, p.ownerRef, p.unitRef, p.factor]),
    );
    expect(packs.every((p) => p.ownerType === 'Catalog_Номенклатура' && p.deletionMark === false)).toBe(true);
  });

  it('характеристики: товара — как есть, удалённая — deletionMark; категории — только товарам с hasCharacteristics', async () => {
    const s = new OsApiCatalogSource(client(standard()));
    const vs = (await read(s, 'variants')) as OnecVariantItem[];
    expect(vs.map((v) => [v.ref, v.ownerRef, v.deletionMark])).toEqual([
      [osApiDerivedRef('characteristic', CH_R, PNT), PNT, false],
      [CH_W, TIL, false],
      [CH_DEL, TIL, true],
    ]);
    expect(vs[1]).toMatchObject({ description: 'Белая', sku: 'W', ownerType: 'Catalog_Номенклатура' });
    expect(await s.count('variants')).toBe(2);
  });

  it('штрихкоды: обрезка пробелов, пустые пропускаются, упаковка и вариант категории переводятся на ссылки модели', async () => {
    const log = warnSpy();
    const s = new OsApiCatalogSource(client(standard()), { log });
    const bcs = (await read(s, 'barcodes')) as OnecBarcodeItem[];
    expect(bcs.map((b) => [b.barcode, b.productRef, b.variantRef, b.packagingRef])).toEqual([
      ['2000000000017', CEM, null, null],
      ['2000000000024', CEM, null, UN_BAG],
      ['2000000000031', PNT, osApiDerivedRef('characteristic', CH_R, PNT), null],
    ]);
    expect(bcs[0].ref).toBe('2000000000017');
    expect(await s.count('barcodes')).toBe(3);
    // Штрихкод на упаковке набора единиц (unitSet) — пропущен намеренно: одно предупреждение, не ошибка.
    expect(bcs.some((b) => b.barcode === '2000000000048')).toBe(false);
    expect(log.calls).toHaveLength(1);
    expect(log.calls[0].obj).toEqual({ entity: 'barcodes', skipped: 1 });
  });

  it('упаковка строки: товара — как есть; категории — производная; unitSet/other, чужая категория, нет в /units — непредставима', () => {
    const items = (OSAPI_FIXTURE('items.json') as { items: never[] }).items;
    const units = (OSAPI_FIXTURE('units.json') as { items: never[] }).items;
    const idx = new OsApiCatalogIndex(items, [], units);
    expect(idx.packagingRef(CEM, UN_BAG, 'package')).toBe(UN_BAG);
    expect(idx.packagingRef(PNT, UN_BOX, 'package')).toBe(osApiDerivedRef('unit', UN_BOX, PNT));
    expect(idx.packagingRef(TIL, UN_BOX, 'package')).toBe(OSAPI_UNREPRESENTABLE);
    expect(idx.packagingRef(CEM, UN_SET, 'package')).toBe(OSAPI_UNREPRESENTABLE);
    expect(idx.packagingRef(CEM, UN_SET)).toBe(OSAPI_UNREPRESENTABLE);
    expect(idx.packagingRef(CEM, UN_MISSING, 'package')).toBe(OSAPI_UNREPRESENTABLE);
    // Без признака вида (штрихкоды) единица вне /units — базовая единица классификатора.
    expect(idx.packagingRef(CEM, KG)).toBeNull();
    expect(idx.packagingRef(CEM, null, 'package')).toBeNull();
  });

  it('readPages: порядок набора не зависит от порядка ответа 1С (продолжение после обрыва — в новой выгрузке)', async () => {
    const items = OSAPI_FIXTURE('items.json') as { items: unknown[] };
    const reversed = standard().on('/items', { body: { items: [...items.items].reverse() } });
    const a = new OsApiCatalogSource(client(standard()), { pageSize: 2 });
    const b = new OsApiCatalogSource(client(reversed), { pageSize: 2 });
    const refs = async (s: OsApiCatalogSource) => {
      const out: string[] = [];
      for await (const p of s.readPages('products', 2)) out.push(...p.items.map((i) => i.ref));
      return out;
    };
    expect(await refs(b)).toEqual(await refs(a));
    expect(await refs(a)).toEqual([TIL, OLD]);
  });

  it('readPages: порции pageSize из памяти, продолжение с nextSkip; выгрузка /items одна на набор сущностей (кэш)', async () => {
    const t = standard();
    const s = new OsApiCatalogSource(client(t), { pageSize: 2 });
    const pages: { n: number; next: number }[] = [];
    for await (const p of s.readPages('products', 1)) pages.push({ n: p.items.length, next: p.nextSkip });
    expect(pages).toEqual([
      { n: 2, next: 3 },
      { n: 1, next: 4 },
    ]);
    await read(s, 'categories');
    await read(s, 'units');
    await read(s, 'packagings');
    expect(t.paths().filter((p) => p === '/items')).toHaveLength(1);
    expect(t.paths().filter((p) => p === '/units')).toHaveLength(1);
  });

  it('кэш выгрузки истекает через cacheTtlMs; ошибка не кэшируется', async () => {
    let now = 0;
    const t = standard().on('/warehouses', [new OnecTransportError('network'), { body: FIX('warehouses.json') }]);
    const s = new OsApiCatalogSource(
      new OnecOsApiClient(
        { baseUrl: 'http://localhost/uk_test', user: 'u', retry: { maxAttempts: 1, baseDelayMs: 0 } },
        t,
      ),
      { cacheTtlMs: 1000, now: () => new Date(now) },
    );
    await expect(read(s, 'warehouses')).rejects.toBeInstanceOf(OnecError);
    expect(await read(s, 'warehouses')).toHaveLength(2);
    now = 500;
    await read(s, 'warehouses');
    now = 1500;
    await read(s, 'warehouses');
    expect(t.paths().filter((p) => p === '/warehouses')).toHaveLength(3);
  });

  it('срез цен: GET /prices?priceType= по виду; деньги 2 знака; package → упаковка; характеристика категории → производный вариант', async () => {
    const t = standard();
    const log = warnSpy();
    const s = new OsApiCatalogSource(client(t), { now: () => new Date('2026-11-24T04:00:00Z'), log });
    const rows = await all(s.priceSlice([PT1, PT2]));
    expect(t.paths().filter((p) => p.startsWith('/prices'))).toEqual([
      `/prices?priceType=${PT1}`,
      `/prices?priceType=${PT2}`,
    ]);
    expect(rows.map((r) => [r.productRef, r.variantRef, r.packagingRef, r.price, r.period])).toEqual([
      [CEM, null, null, '120.50', '2026-11-20T09:00:00+06:00'],
      [CEM, null, UN_BAG, '6000.00', '2026-11-20T09:00:00+06:00'],
      [PNT, osApiDerivedRef('characteristic', CH_R, PNT), null, '350.00', '2026-11-21T00:00:00+06:00'],
      [PNT, null, osApiDerivedRef('unit', UN_BOX, PNT), '4000.00', '2026-11-21T00:00:00+06:00'],
      [TIL, CH_W, null, '99.999', '2026-11-22T00:00:00+06:00'],
    ]);
    expect(rows.every((r) => r.priceListRef === PT1)).toBe(true);
    expect(s.snapshotAt()?.toISOString()).toBe('2026-11-24T04:00:00.000Z');
    // Цены на упаковке набора единиц и на упаковке, которой нет в /units, — пропущены (одно предупреждение за срез).
    expect(rows.some((r) => r.packagingRef === UN_SET || r.packagingRef === UN_MISSING)).toBe(false);
    expect(log.calls).toHaveLength(1);
    expect(log.calls[0].obj).toEqual({ entity: 'prices', skipped: 2 });
  });

  it('срез цен с ONEC_OSAPI_PRICE_TYPES: виды вне списка не запрашиваются', async () => {
    const t = standard();
    const s = new OsApiCatalogSource(client(t), { priceTypes: [PT2] });
    await all(s.priceSlice([PT1, PT2]));
    expect(t.paths().filter((p) => p.startsWith('/prices'))).toEqual([`/prices?priceType=${PT2}`]);
  });

  it('срез остатков: все склады одним /stock; quantity/reserved → onHand/reserved, available = free 1С', async () => {
    const t = standard();
    const s = new OsApiCatalogSource(client(t));
    const rows = await all(s.stockSlice());
    expect(t.paths().filter((p) => p.startsWith('/stock'))).toEqual(['/stock']);
    expect(rows.map((r) => [r.warehouseRef, r.productRef, r.variantRef, r.onHand, r.reserved, r.available])).toEqual([
      [WH1, CEM, null, '100.000', '30.000', '70.000'],
      [WH1, PNT, osApiDerivedRef('characteristic', CH_R, PNT), '5.000', '8.000', '0.000'],
      [WH2, TIL, CH_W, '12.500', '0.000', '12.500'],
    ]);
  });

  it('срез остатков с ONEC_OSAPI_WAREHOUSES: /stock?warehouse= по складу, чужие строки отбрасываются; без free → available null', async () => {
    const t = standard().on(`/stock?warehouse=${WH2}`, {
      body: {
        items: [
          { warehouseId: WH2, itemId: TIL, characteristicId: null, quantity: 3 },
          { warehouseId: WH1, itemId: CEM, characteristicId: null, quantity: 1, reserved: 0, free: 1 },
        ],
      },
    });
    const s = new OsApiCatalogSource(client(t), { warehouses: [WH2] });
    const rows = await all(s.stockSlice());
    expect(t.paths().filter((p) => p.startsWith('/stock'))).toEqual([`/stock?warehouse=${WH2}`]);
    expect(rows).toEqual([
      { warehouseRef: WH2, productRef: TIL, variantRef: null, onHand: '3.000', reserved: '0.000', available: null },
    ]);
  });

  it('ни одного POST: источник каталога только читает', async () => {
    const t = standard();
    const s = new OsApiCatalogSource(client(t));
    for (const k of [
      'units',
      'warehouses',
      'price_lists',
      'categories',
      'products',
      'packagings',
      'variants',
      'barcodes',
    ] as const)
      await read(s, k);
    await all(s.priceSlice([PT1]));
    await all(s.stockSlice());
    expect(t.requests.every((r) => r.method === 'GET' && r.body === undefined)).toBe(true);
  });
});

describe('ADR-126: OnecOsApiGateway — ping, фото, отказ записи', () => {
  it('getHealth = GET /ping: apiVersion "v1" → "1" (защита версии пропускает), serverTime +06:00', async () => {
    const g = new OnecOsApiGateway(client(standard()));
    const h = await g.getHealth();
    expect(h.status).toBe(200);
    expect(h.body).toMatchObject({
      apiVersion: '1',
      extensionVersion: '0.2.9',
      configuration: 'УправлениеНебольшойФирмой',
      configurationVersion: '3.0.2.190',
      serverTime: '2026-11-24T10:15:00+06:00',
      lastAckMessageNumber: 0,
      registrationBacklog: 0,
      status: 'ok',
      osApi: 'v1',
    });
    expect(isApiVersionCompatible(h.body.apiVersion)).toBe(true);
    expect(osApiVersion('v2')).toBe('2');
    expect(isApiVersionCompatible(osApiVersion('v2'))).toBe(false);
    expect(isApiVersionCompatible(osApiVersion(undefined))).toBe(false);
    expect(g.mode).toBe('os_api');
  });

  it('все методы порта, кроме getHealth/getImage, — 501 без запроса в 1С (запись выключена)', async () => {
    const t = standard();
    const g = new OnecOsApiGateway(client(t));
    const calls: [string, () => Promise<unknown>][] = [
      ['getChanges', () => g.getChanges({ since: 0 })],
      ['ackChanges', () => g.ackChanges(1)],
      ['reregisterChanges', () => g.reregisterChanges()],
      ['createOrder', () => g.createOrder({ externalId: U('99000000', 1) })],
      ['getOrderStatus', () => g.getOrderStatus(U('99000000', 1))],
      ['getOrderStatusBatch', () => g.getOrderStatusBatch([U('99000000', 1)])],
      ['cancelOrder', () => g.cancelOrder(U('99000000', 1), {})],
      ['createPayment', () => g.createPayment({})],
      [
        'createQrPayment',
        () =>
          g.createQrPayment({
            externalId: U('99000000', 2),
            orderExternalId: U('99000000', 1),
            orderRef: null,
            customerRef: null,
            amount: '1.00',
            currency: 'KGS',
            purpose: 'x',
            requestedTtlSeconds: 60,
            cashierUserCode: 'c',
          }),
      ],
      ['getQrPaymentStatus', () => g.getQrPaymentStatus(U('99000000', 2))],
      ['cancelQrPayment', () => g.cancelQrPayment(U('99000000', 2), 'voided')],
      ['findCustomersByPhone', () => g.findCustomersByPhone('996700000000')],
      ['createCustomer', () => g.createCustomer({})],
      ['getCustomerReceivables', () => g.getCustomerReceivables(U('99000000', 3))],
      ['createReturnRequest', () => g.createReturnRequest({})],
      ['getReturnRequestStatus', () => g.getReturnRequestStatus(U('99000000', 4))],
      ['checkCart', () => g.checkCart({})],
      ['getCatalogCard', () => g.getCatalogCard(CEM)],
      ['listExternalIds', () => g.listExternalIds({})],
    ];
    expect(calls.map((c) => c[0]).sort()).toEqual(
      Object.keys(ONEC_OPERATIONS)
        .filter((k) => k !== 'getHealth' && k !== 'getImage')
        .sort(),
    );
    for (const [op, call] of calls) {
      const e = (await call().catch((x: unknown) => x)) as OnecError;
      expect(e).toBeInstanceOf(OnecError);
      expect(e.operation).toBe(op);
      expect(e.status).toBe(501);
      expect(e.retryable).toBe(false);
    }
    expect(t.requests).toHaveLength(0);
  });

  it('getImage: вид по /item-files, байты /files/{kind}/{id}, ETag = SHA-256 содержимого, If-None-Match → 304', async () => {
    const bytes = Buffer.from('синтетическая картинка');
    const t = standard()
      .on(`/files/item/${F1}`, { body: bytes, headers: { 'content-type': 'image/jpeg' } })
      .on(`/files/characteristic/${F2}`, { body: Buffer.from('png'), headers: { 'content-type': 'image/png' } });
    const g = new OnecOsApiGateway(client(t));
    const r = await g.getImage(F1.toUpperCase());
    const etag = `"${createHash('sha256').update(bytes).digest('hex')}"`;
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ contentType: 'image/jpeg', etag });
    expect(Buffer.from(r.body!.data).toString()).toBe('синтетическая картинка');
    const again = await g.getImage(F1, etag);
    expect(again).toEqual({ status: 304, body: null });
    const ch = await g.getImage(F2);
    expect(ch.body?.contentType).toBe('image/png');
    expect(t.paths().filter((p) => p === '/item-files')).toHaveLength(1);
    expect(t.requests.every((x) => x.method === 'GET')).toBe(true);
  });

  it('getImage: файла нет в /item-files → 404 (повторное чтение списка не чаще раза в минуту)', async () => {
    const t = standard();
    const g = new OnecOsApiGateway(client(t));
    const unknown = U('a3000000', 99);
    await expect(g.getImage(unknown)).rejects.toMatchObject({ status: 404, code: 'POS_E_NOT_FOUND' });
    await expect(g.getImage(unknown)).rejects.toMatchObject({ status: 404 });
    expect(t.paths().filter((p) => p === '/item-files')).toHaveLength(1);
    expect(t.paths().some((p) => p.startsWith('/files/'))).toBe(false);
  });

  it('список фото: товар → товар, характеристика товара → вариант, версия changedAt|size; характеристика категории — пропуск', async () => {
    const log = warnSpy();
    const src = new OsApiImageListSource(client(standard()), log);
    const entries = await all(src.list());
    expect(entries).toEqual([
      {
        sourceRef: F1,
        ownerRef: CEM,
        sourceVersion: '2026-11-19T03:00:00|1024',
        sortOrder: 0,
        deletionMark: false,
        isMain: true,
      },
      {
        sourceRef: F2,
        ownerRef: CH_W,
        sourceVersion: '2026-11-19T04:00:00|2048',
        sortOrder: 0,
        deletionMark: false,
        isMain: false,
      },
    ]);
    // F3 — фото характеристики категории: ОС_API отдаёт itemId = null (Module.bsl:1048-1050, 1081-1082), варианта
    // с такой ссылкой в реплике нет — файл не отдаётся с висячим владельцем, а пропускается с предупреждением.
    expect(entries.some((e) => e.sourceRef === F3)).toBe(false);
    expect(log.calls).toHaveLength(1);
    expect(log.calls[0].obj).toEqual({ entity: 'images', skipped: 1 });
  });
});

describe('ADR-126: конфигурация ONEC_MODE=os_api', () => {
  it('значения по умолчанию: путь hs/os/api/v1, период 300 с; списки UUID проверяются', () => {
    const c = loadAppConfig(OSAPI_ENV);
    expect(c.ONEC_MODE).toBe('os_api');
    expect(c.ONEC_OSAPI_PATH).toBe('hs/os/api/v1');
    expect(c.ONEC_OSAPI_POLL_SECONDS).toBe(300);
    expect(c.ONEC_OSAPI_PRICE_TYPES).toBeUndefined();
    const ok = loadAppConfig({ ...OSAPI_ENV, ONEC_OSAPI_PRICE_TYPES: `${PT1}, ${PT2}`, ONEC_OSAPI_WAREHOUSES: WH1 });
    expect(ok.ONEC_OSAPI_PRICE_TYPES).toBe(`${PT1}, ${PT2}`);
    const bad = expectConfigError(() =>
      loadAppConfig({ ...OSAPI_ENV, ONEC_OSAPI_WAREHOUSES: 'склад-1', ONEC_OSAPI_POLL_SECONDS: '90' }),
    );
    expect(bad).toContain('ONEC_OSAPI_WAREHOUSES');
    expect(bad).toContain('ONEC_OSAPI_POLL_SECONDS');
  });

  it('обязательны ONEC_BASE_URL, ONEC_USER, ONEC_PASSWORD; QR_PROVIDER=onec и ONEC_ODATA_WRITE_ENABLED — отказ в старте', () => {
    const missing = expectConfigError(() =>
      loadAppConfig({ ...OSAPI_ENV, ONEC_BASE_URL: undefined, ONEC_USER: undefined, ONEC_PASSWORD: undefined }),
    );
    expect(missing).toContain('ONEC_BASE_URL: обязательна при ONEC_MODE=os_api');
    expect(missing).toContain('ONEC_USER: обязательна (ONEC_USER_FILE) при ONEC_MODE=os_api');
    expect(missing).toContain('ONEC_PASSWORD: обязательна (ONEC_PASSWORD_FILE) при ONEC_MODE=os_api');
    const qr = expectConfigError(() => loadAppConfig({ ...OSAPI_ENV, QR_PROVIDER: 'onec' }));
    expect(qr).toContain('QR_PROVIDER: onec недопустим при ONEC_MODE=os_api');
    const qrDefault = expectConfigError(() => loadAppConfig({ ...OSAPI_ENV, QR_PROVIDER: undefined }));
    expect(qrDefault).toContain('QR_PROVIDER');
    const write = expectConfigError(() =>
      loadAppConfig({
        ...OSAPI_ENV,
        ONEC_ODATA_WRITE_ENABLED: 'true',
        ONEC_ODATA_WRITE_USER: 'w',
        ONEC_ODATA_WRITE_PASSWORD: 'w',
      }),
    );
    expect(write).toContain('ONEC_ODATA_WRITE_ENABLED: true допустимо только при ONEC_MODE=odata_only');
    expect(loadAppConfig({ ...OSAPI_ENV, QR_PROVIDER: 'bank' }).QR_PROVIDER).toBe('bank');
  });

  it('http:// вне dev — только адрес этого сервера; https — любой', () => {
    const remote = expectConfigError(() =>
      loadAppConfig({
        ...OSAPI_ENV,
        APP_ENV: 'staging',
        PUBLIC_BASE_URL: 'https://stand.example.test',
        ONEC_BASE_URL: 'http://10.0.0.5/uk_test',
      }),
    );
    expect(remote).toContain('ONEC_BASE_URL: http:// при ONEC_MODE=os_api допустим только для адреса этого сервера');
    for (const url of ['http://localhost/uk_test', 'http://127.0.0.1/uk_test', 'https://1c.example.test/uk']) {
      const text = (() => {
        try {
          loadAppConfig({
            ...OSAPI_ENV,
            APP_ENV: 'staging',
            PUBLIC_BASE_URL: 'https://stand.example.test',
            ONEC_BASE_URL: url,
          });
          return '';
        } catch (e) {
          return e instanceof ConfigError ? e.problems.join('\n') : String(e);
        }
      })();
      expect(text).not.toContain('ONEC_BASE_URL');
    }
  });

  it('фабрика: os_api → OnecOsApiGateway; без учётных данных — ConfigError; QR через 1С — отказ', () => {
    const c = loadAppConfig(OSAPI_ENV);
    const g = createOnecGateway(c, onecAdapters(c, standard()));
    expect(g).toBeInstanceOf(OnecOsApiGateway);
    expect(() =>
      createOnecGateway({ ...c }, onecAdapters({ ...c, ONEC_USER: undefined, ONEC_PASSWORD: undefined })),
    ).toThrow(ConfigError);
    expect(() => createOnecGateway(c, {})).toThrow(/os_api/);
    expect(() =>
      createPaymentProvider({ ...c, QR_PROVIDER: 'onec', ONEC_INBOUND_ENABLED: false }, { onecGateway: g }),
    ).toThrow(/os_api/);
  });

  it('источник каталога и список фото os_api — ОС_API (не OData), хотя ONEC_BASE_URL и ONEC_USER заданы', () => {
    const c = loadAppConfig(OSAPI_ENV);
    const g = createOnecGateway(c, onecAdapters(c, standard()));
    expect(createCatalogFullSource(c, g)).toBeInstanceOf(OsApiCatalogSource);
    expect(createImageListSource(c, g)).toBeInstanceOf(OsApiImageListSource);
    expect(createImageListSource(c)).toBeNull();
  });
});

describe('ADR-126: расписание и outbox при os_api; прежние режимы не изменились (ADR-112)', () => {
  const extension = {
    ...OSAPI_ENV,
    ONEC_MODE: 'extension',
    ONEC_HS_PATH: 'ut/hs',
    ONEC_HS_USER: 'h',
    ONEC_HS_TOKEN: 't',
  };
  const odata = { ...OSAPI_ENV, ONEC_MODE: 'odata_only', ONEC_BASE_URL: 'https://1c.example.test/ut' };

  it('по расписанию — только каталог, цены, остатки и фото; cron из ONEC_OSAPI_POLL_SECONDS', () => {
    expect(scheduledEntities('os_api', SYNC_ENTITY_VALUES).sort()).toEqual([...OSAPI_POLLED_ENTITIES].sort());
    expect(scheduledEntities('os_api', SYNC_ENTITY_VALUES)).not.toContain('order_status');
    expect(scheduledEntities('extension', SYNC_ENTITY_VALUES).sort()).toEqual(
      ['images', 'order_status', 'prices', 'receivables', 'stock'].sort(),
    );
    expect(scheduledEntities('odata_only', SYNC_ENTITY_VALUES)).toHaveLength(17);
    expect(scheduledEntities('fixtures', SYNC_ENTITY_VALUES)).toHaveLength(17);
    expect(osApiPollCron(300)).toBe('*/5 * * * *');
    expect(osApiPollCron(60)).toBe('*/1 * * * *');
    expect(osApiPollCron(3600)).toBe('0 * * * *');
    const os = schedulerConfigFromEnv(loadAppConfig({ ...OSAPI_ENV, ONEC_OSAPI_POLL_SECONDS: '600' }));
    expect(os.cron).toMatchObject({ stock: '*/10 * * * *', prices: '*/10 * * * *', master: '*/10 * * * *' });
    expect(os.cron.orderStatus).toBe('*/5 * * * *');
    const ext = schedulerConfigFromEnv(loadAppConfig({ ...extension, ONEC_OSAPI_POLL_SECONDS: '600' }));
    expect(ext.cron).toMatchObject({ stock: '*/10 * * * *', prices: '*/15 * * * *', master: '*/30 * * * *' });
  });

  it('outbox: при os_api канал записи не подключается (NO_WRITE_CHANNEL); extension — подключён, odata_only — нет', () => {
    const pool = {} as pg.Pool;
    const log = pino({ level: 'silent' });
    const gw = new OnecOsApiGateway(client(standard()));
    const wiring = (cfg: Record<string, string>, gateway: OnecGateway) =>
      createOrdersWorkerWiring({ config: loadAppConfig(cfg), pool, log, gateway, notifications: null });
    expect(wiring(OSAPI_ENV, gw).outboxDelivery).toBeUndefined();
    expect(wiring(extension, new FakeOnecGateway()).outboxDelivery?.configured).toBe(true);
    expect(wiring(odata, new FakeOnecGateway()).outboxDelivery).toBeUndefined();
  });

  it('фабрика прежних режимов: extension/odata_only/fixtures — те же реализации; OData-источник у odata_only', () => {
    const fx = createOnecGateway(loadAppConfig({ ...OSAPI_ENV, ONEC_MODE: 'fixtures' }));
    expect(fx).toBeInstanceOf(FakeOnecGateway);
    const oc = loadAppConfig(odata);
    const og = createOnecGateway(oc, onecAdapters(oc, standard()));
    expect(og).toBeInstanceOf(OnecODataGateway);
    expect(createCatalogFullSource(oc, og)).toBeInstanceOf(ODataCatalogSource);
    const ec = loadAppConfig(extension);
    expect(createOnecGateway(ec, onecAdapters(ec, standard())).mode).toBe('extension');
  });
});

// Типы элементов каталога из источника — из перечня контракта (защита от опечаток в type).
it('ADR-126: типы элементов OsApiCatalogSource — из ONEC_TYPE', async () => {
  const s = new OsApiCatalogSource(client(standard()));
  const seen = new Set<string>();
  for (const k of [
    'units',
    'warehouses',
    'price_lists',
    'categories',
    'products',
    'packagings',
    'variants',
    'barcodes',
  ] as const)
    for (const it of await all<OnecCatalogItem>(s.read(k))) seen.add(it.type);
  expect([...seen].sort()).toEqual(
    [
      'Catalog_ВидыЦен',
      'Catalog_КлассификаторЕдиницИзмерения',
      'Catalog_Номенклатура',
      'Catalog_Склады',
      'Catalog_УпаковкиЕдиницыИзмерения',
      'Catalog_ХарактеристикиНоменклатуры',
      'InformationRegister_ШтрихкодыНоменклатуры',
    ].sort(),
  );
});

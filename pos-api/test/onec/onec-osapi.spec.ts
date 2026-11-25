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
import { ONEC_OPERATIONS, type OnecGateway, type OnecJsonObject } from '../../src/integrations/onec/onec-gateway.js';
import type { OutboxRow } from '../../src/jobs/outbox/outbox-delivery.port.js';
import { normalizeOnecStatus, parseOnecOrderDocument } from '../../src/orders/order-projection.js';
import { classifyOnecResult } from '../../src/sales-domain/outbox/outbox-status.js';
import { OnecOutboxDelivery } from '../../src/sync/outbox/onec-outbox.delivery.js';
import { OnecTransportError } from '../../src/integrations/onec/onec-http-transport.js';
import { OnecODataGateway } from '../../src/integrations/onec/onec-odata.gateway.js';
import { OnecOsApiClient } from '../../src/integrations/onec/onec-osapi.client.js';
import {
  OSAPI_MANUAL_CODE,
  OSAPI_MANUAL_RECHECK_MS,
  OnecOsApiGateway,
  type OnecOsApiGatewayOptions,
  isOsApiOrderNotFound,
  osApiLinePricing,
  osApiLocalDateTime,
  osApiShipmentDate,
  osApiVersion,
} from '../../src/integrations/onec/onec-osapi.gateway.js';
import {
  OSAPI_UNREPRESENTABLE,
  OsApiCatalogIndex,
  osApiDate,
  osApiDerivedRef,
  osApiMoney,
  osApiQty,
} from '../../src/integrations/onec/onec-osapi.mapping.js';
import {
  type FakeOsApiTransport,
  OSAPI_FIXTURE,
  OSAPI_REFS,
  OSAPI_ROOT,
  osApiOrdersStore,
  osApiTestClient,
  osu,
  standardOsApi,
} from '../support/osapi-fake.js';
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

  it('все методы порта, кроме getHealth/getImage/getOrderStatus*, — 501 без запроса в 1С (запись заказов выключена)', async () => {
    const t = standard();
    const g = new OnecOsApiGateway(client(t));
    const calls: [string, () => Promise<unknown>][] = [
      ['getChanges', () => g.getChanges({ since: 0 })],
      ['ackChanges', () => g.ackChanges(1)],
      ['reregisterChanges', () => g.reregisterChanges()],
      ['createOrder', () => g.createOrder({ externalId: U('99000000', 1) })],
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
        .filter((k) => !['getHealth', 'getImage', 'getOrderStatus', 'getOrderStatusBatch'].includes(k))
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
    // order_status в os_api без записи заказов не планируется; его cron — как у перечитки каталога.
    expect(os.cron.orderStatus).toBe('*/10 * * * *');
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

// ---------- Запись заказов черновиком через ОС_API (решение владельца 25.11.2026) ----------

const ORD = U('99000000', 10);
const CUST_1C = U('99100000', 1);
const CUST_RETAIL = U('99100000', 9);
const PHONE = '996700123456';

/** Тело `OrderCreateRequest` POS (как onec-order-payload.ts) с `externalId`. */
function orderPayload(over: Record<string, unknown> = {}): OnecJsonObject {
  return {
    externalId: ORD,
    createdAt: '2026-11-25T12:00:00+06:00',
    createdByUserCode: U('99200000', 1),
    customer: { ref: null, contractorRef: null, agreementRef: null },
    warehouseRef: WH1,
    organizationRef: null,
    priceListRef: PT1,
    paymentMethod: 'cash',
    paymentTerms: 'prepayment',
    delivery: {
      method: 'pickup',
      address: null,
      receiverName: null,
      receiverPhone: null,
      desiredFrom: '2026-11-26T10:00:00+06:00',
      desiredTo: null,
      courierComment: null,
    },
    discountPercent: '0.00',
    comment: `POS ${ORD} · П-000123`,
    lines: [
      // Товар без характеристики, базовая единица; скидка клиента 10 % (сумма 900 из 2 × 500).
      {
        lineNumber: 1,
        productRef: CEM,
        variantRef: null,
        packagingRef: null,
        quantity: '2.000',
        packQuantity: null,
        price: '500.00',
        discountPercent: '0.00',
        amount: '900.00',
        supplyOption: 'КОбеспечению',
      },
      // Характеристика и упаковка КАТЕГОРИИ: производные ссылки POS → ссылки 1С; количество — в упаковках.
      {
        lineNumber: 2,
        productRef: PNT,
        variantRef: osApiDerivedRef('characteristic', CH_R, PNT),
        packagingRef: osApiDerivedRef('unit', UN_BOX, PNT),
        quantity: '36.000',
        packQuantity: '3.000',
        price: '1200.00',
        discountPercent: '0.00',
        amount: '3600.00',
        supplyOption: 'КОбеспечению',
      },
    ],
    totals: { subtotal: '4600.00', discount: '100.00', total: '4500.00', currency: 'KGS' },
    clientChecks: { pricesSnapshotAt: null, stockSnapshotAt: null },
    ...over,
  };
}

function writeGateway(t: FakeOsApiTransport, opts: Partial<OnecOsApiGatewayOptions> = {}): OnecOsApiGateway {
  return new OnecOsApiGateway(client(t), undefined, { writeOrders: true, ...opts });
}

function outboxRow(over: Partial<OutboxRow> = {}): OutboxRow {
  return {
    id: U('99300000', 1),
    aggregateType: 'order',
    aggregateId: ORD,
    externalId: ORD,
    operation: 'create',
    payload: orderPayload(),
    attempts: 1,
    createdAt: new Date('2026-11-25T06:00:00Z'),
    ...over,
  };
}

describe('Решение 25.11.2026: заказ POS → 1С черновиком (POST /orders, post:false, reserve:false)', () => {
  const linked = { customer: { ref: null, contractorRef: CUST_1C, agreementRef: null } };

  it('тело — ровно поля СоздатьЗаказ; post/reserve = false; ответ 201 → ссылка, номер, «Не согласован», сумма', async () => {
    const store = osApiOrdersStore();
    const t = standard().on('POST /orders', store.reply);
    const r = await writeGateway(t).createOrder(orderPayload(linked));
    const posts = t.posts();
    expect(posts).toHaveLength(1);
    expect(posts[0].path).toBe('/orders');
    expect(posts[0].body).toEqual({
      id: ORD,
      customerId: CUST_1C,
      warehouseId: WH1,
      priceTypeId: PT1,
      shipmentDate: '2026-11-26T10:00:00',
      comment: `POS ${ORD} · П-000123`,
      post: false,
      reserve: false,
      lines: [
        { itemId: CEM, characteristicId: null, unitId: null, quantity: 2, price: 500, discountPercent: 10 },
        { itemId: PNT, characteristicId: CH_R, unitId: UN_BOX, quantity: 3, price: 1200, discountPercent: 0 },
      ],
    });
    const req = t.requests.find((x) => x.method === 'POST');
    expect(req?.headers['Content-Type']).toBe('application/json; charset=utf-8');
    expect(req?.headers.Authorization).toMatch(/^Basic /);
    expect(r.status).toBe(201);
    expect(r.body).toMatchObject({
      ref: ORD,
      number: 'ОС-000001',
      date: '2026-11-25T12:00:00+06:00',
      status: 'Не согласован',
      total: '4500.00',
      osApi: { created: true, posted: false, customerId: CUST_1C, warehouseId: WH1 },
    });
    expect(parseOnecOrderDocument(r.body)).toMatchObject({
      ref: ORD,
      number: 'ОС-000001',
      status: 'Не согласован',
      total: '4500.00',
      hasShipment: false,
    });
    expect(normalizeOnecStatus('Не согласован')).toBe('not_approved');
    expect(t.requests.filter((x) => x.method === 'POST').map((x) => x.url)).toEqual([`${ROOT}/orders`]);
  });

  it('повтор того же заказа — 200 created:false, тот же документ (идемпотентность по UUID заказа); канал → sent', async () => {
    const store = osApiOrdersStore();
    const t = standard().on('POST /orders', store.reply);
    const g = writeGateway(t);
    const first = await g.createOrder(orderPayload(linked));
    const again = await g.createOrder(orderPayload(linked));
    expect(again.status).toBe(200);
    expect(again.body).toMatchObject({ ref: ORD, number: first.body.number, osApi: { created: false } });
    expect(store.orders.size).toBe(1);
    const d = new OnecOutboxDelivery(g, { timeoutMs: 5000, routes: ['order/create'], orderCustomerPhone: true });
    expect(await d.deliver(outboxRow({ payload: orderPayload(linked) }))).toMatchObject({
      kind: 'sent',
      onecRef: ORD,
      onecNumber: 'ОС-000001',
      onecStatus: 'Не согласован',
    });
    expect(store.orders.size).toBe(1);
    for (const p of t.posts()) expect(p.body).toMatchObject({ id: ORD, post: false, reserve: false });
  });

  it('без ONEC_OSAPI_WRITE_ORDERS — 501 без запроса в 1С', async () => {
    const t = standard();
    const e = (await new OnecOsApiGateway(client(t))
      .createOrder(orderPayload(linked))
      .catch((x: unknown) => x)) as OnecError;
    expect(e).toBeInstanceOf(OnecError);
    expect(e.status).toBe(501);
    expect(t.requests).toHaveLength(0);
  });

  it('клиент: ссылка 1С → без поиска; иначе единственный действующий покупатель по телефону; иначе ONEC_OSAPI_DEFAULT_CUSTOMER', async () => {
    const t = standard()
      .on('POST /orders', osApiOrdersStore().reply)
      .on(`/customers?phone=${PHONE}`, {
        body: {
          items: [
            { id: CUST_1C, name: 'Иванов', inactive: false },
            { id: U('99100000', 2), inactive: true },
          ],
        },
      })
      .on('/customers?phone=996555000111', { body: { items: [{ id: U('99100000', 3) }, { id: U('99100000', 4) }] } });
    const g = writeGateway(t, { defaultCustomer: CUST_RETAIL });
    await g.createOrder(orderPayload(linked));
    expect(t.paths().some((p) => p.startsWith('/customers'))).toBe(false);

    const byPhone = { customer: { ref: null, contractorRef: null, agreementRef: null, phone: `+${PHONE}` } };
    await g.createOrder(orderPayload({ ...byPhone, externalId: U('99000000', 11) }));
    const ambiguous = { customer: { ref: null, contractorRef: null, agreementRef: null, phone: '996555000111' } };
    await g.createOrder(orderPayload({ ...ambiguous, externalId: U('99000000', 12) }));
    const bodies = t.posts().map((p) => p.body as { customerId: string; comment: string });
    expect(bodies.map((b) => b.customerId)).toEqual([CUST_1C, CUST_1C, CUST_RETAIL]);
    expect(bodies[2].comment).toContain('клиент POS без карточки в 1С');
    expect(t.paths()).toContain(`/customers?phone=${PHONE}`);
  });

  it('клиент не определён (нет ссылки, совпадения и ONEC_OSAPI_DEFAULT_CUSTOMER) → OSAPI_MANUAL, клиент не создаётся, канал паркует', async () => {
    const t = standard()
      .on('POST /orders', osApiOrdersStore().reply)
      .on(`/customers?phone=${PHONE}`, { body: { items: [] } });
    const g = writeGateway(t);
    const payload = orderPayload();
    const e = (await g.createOrder(payload).catch((x: unknown) => x)) as OnecError;
    expect(e.code).toBe(OSAPI_MANUAL_CODE);
    const d = new OnecOutboxDelivery(g, { timeoutMs: 5000, routes: ['order/create'], orderCustomerPhone: true });
    const res = await d.deliver(outboxRow({ payload, customerPhone: PHONE }));
    expect(res.kind).toBe('parked');
    expect((res as { message: string }).message).toContain('клиента в 1С не создаём');
    // Телефон клиента POS канал передал только для поиска (GET); ни одного POST (ни /orders, ни /customers).
    expect(t.paths()).toContain(`/customers?phone=${PHONE}`);
    expect(t.posts()).toHaveLength(0);
  });

  it('склад: ссылка склада POS, иначе единственный из ONEC_OSAPI_WAREHOUSES, иначе OSAPI_MANUAL; товар без ссылки — OSAPI_MANUAL', async () => {
    const t = standard().on('POST /orders', osApiOrdersStore().reply);
    await writeGateway(t, { warehouses: [WH2] }).createOrder(orderPayload({ ...linked, warehouseRef: null }));
    expect((t.posts()[0].body as { warehouseId: string }).warehouseId).toBe(WH2);
    const noWh = (await writeGateway(t, { warehouses: [WH1, WH2] })
      .createOrder(orderPayload({ ...linked, warehouseRef: null, externalId: U('99000000', 13) }))
      .catch((x: unknown) => x)) as OnecError;
    expect(noWh.code).toBe(OSAPI_MANUAL_CODE);
    const noItem = (await writeGateway(t)
      .createOrder(
        orderPayload({
          ...linked,
          externalId: U('99000000', 14),
          lines: [{ productRef: null, variantRef: null, packagingRef: null, quantity: '1.000', price: '1.00' }],
        }),
      )
      .catch((x: unknown) => x)) as OnecError;
    expect(noItem.code).toBe(OSAPI_MANUAL_CODE);
    // Упаковка POS без ссылки 1С (количество в упаковках, цена за упаковку) — не угадываем единицу.
    const noPack = (await writeGateway(t)
      .createOrder(
        orderPayload({
          ...linked,
          externalId: U('99000000', 15),
          lines: [{ productRef: CEM, packagingRef: null, quantity: '50.000', packQuantity: '1.000', price: '450.00' }],
        }),
      )
      .catch((x: unknown) => x)) as OnecError;
    expect(noPack.code).toBe(OSAPI_MANUAL_CODE);
    expect(t.posts()).toHaveLength(1);
  });

  it('422 от 1С → rejected (failed, без повторов) с сообщениями 1С; 500 и сеть → transient; 400 → rejected', async () => {
    const t = standard().on('POST /orders', [
      {
        status: 422,
        body: {
          error: {
            code: 'not_saved',
            message: 'Заказ не записан',
            details: [{ field: 'Организация', message: 'Не заполнено поле «Организация»' }],
          },
        },
      },
      { status: 500, body: { error: { code: 'internal_error', message: 'сбой' } } },
      new OnecTransportError('timeout'),
      { status: 400, body: { error: { code: 'bad_request', message: 'Неизвестный customerId' } } },
    ]);
    const d = new OnecOutboxDelivery(writeGateway(t), { timeoutMs: 5000, routes: ['order/create'] });
    const row = outboxRow({ payload: orderPayload(linked) });
    const r422 = await d.deliver(row);
    expect(r422.kind).toBe('rejected');
    expect(JSON.stringify((r422 as { response: unknown }).response)).toContain('Не заполнено поле «Организация»');
    expect(classifyOnecResult({ ok: false, status: 422, code: 'POS_E_VALIDATION' })).toBe('rejected');
    expect((await d.deliver(row)).kind).toBe('transient');
    expect((await d.deliver(row)).kind).toBe('transient');
    expect((await d.deliver(row)).kind).toBe('rejected');
    // POST внутри клиента не повторяется (повторяет outbox по графику): 4 вызова — 4 запроса.
    expect(t.posts()).toHaveLength(4);
  });

  it('прочие маршруты outbox (отмена, клиент, оплата, возврат) не отправляются: parked без запроса в 1С', async () => {
    const t = standard();
    const g = writeGateway(t);
    const d = new OnecOutboxDelivery(g, { timeoutMs: 5000, routes: ['order/create'] });
    for (const [aggregateType, operation] of [
      ['order', 'cancel'],
      ['customer', 'create'],
      ['payment', 'create'],
      ['return_request', 'create'],
    ] as const) {
      const r = await d.deliver(outboxRow({ aggregateType, operation, payload: { name: 'x', phone: PHONE } }));
      expect(r.kind).toBe('parked');
    }
    // И сам шлюз: отмена/клиент/оплата — 501 без запроса даже с ONEC_OSAPI_WRITE_ORDERS.
    for (const call of [() => g.cancelOrder(ORD, {}), () => g.createCustomer({}), () => g.createPayment({})]) {
      expect(((await call().catch((x: unknown) => x)) as OnecError).status).toBe(501);
    }
    expect(t.requests).toHaveLength(0);
  });

  it('getOrderStatus = GET /orders/{id}: номер, «Согласован» после проведения, чек = отгрузка; пакет — 404 → notFound', async () => {
    const other = U('99000000', 20);
    const missing = U('99000000', 21);
    const t = standard()
      .on(`/orders/${ORD}`, {
        body: {
          id: ORD,
          number: 'ОС-000007',
          date: '2026-11-25T12:00:00',
          posted: true,
          isCompleted: true,
          total: 4500,
          shipments: [],
          receipts: [{ id: U('99400000', 1), number: '7', posted: true, total: 4500 }],
        },
      })
      .on(`/orders/${other}`, { body: { id: other, number: 'ОС-000008', posted: false, total: 10.5 } })
      .on(`/orders/${missing}`, { status: 404, body: { error: { code: 'not_found', message: 'Заказ не найден' } } });
    const g = new OnecOsApiGateway(client(t));
    const one = await g.getOrderStatus(ORD);
    // «Закрыт» не выводится никогда (завершён без накладной ≠ отмена в POS).
    expect(parseOnecOrderDocument(one.body)).toMatchObject({
      ref: ORD,
      number: 'ОС-000007',
      status: 'Согласован',
      total: '4500.00',
      hasShipment: true,
    });
    const batch = await g.getOrderStatusBatch([ORD, missing, other]);
    expect((batch.body.items as OnecJsonObject[]).map((x) => [x.externalId, x.number, x.status])).toEqual([
      [ORD, 'ОС-000007', 'Согласован'],
      [other, 'ОС-000008', 'Не согласован'],
    ]);
    expect(batch.body.notFound).toEqual([missing]);
    expect(t.requests.every((r) => r.method === 'GET')).toBe(true);
  });

  it('пакет статусов: сбой после первого ответа — частичный результат; на первом — ошибка', async () => {
    const second = U('99000000', 22);
    const t = standard()
      .on(`/orders/${ORD}`, { body: { id: ORD, number: '1', posted: false, total: 1 } })
      .on(`/orders/${second}`, new OnecTransportError('timeout'));
    const g = new OnecOsApiGateway(client(t));
    const part = await g.getOrderStatusBatch([ORD, second]);
    expect((part.body.items as OnecJsonObject[]).map((x) => x.externalId)).toEqual([ORD]);
    expect(part.body.notFound).toEqual([]);
    await expect(g.getOrderStatusBatch([second])).rejects.toBeInstanceOf(OnecError);
  });

  it('ONEC_OSAPI_WRITE_ORDERS — только при ONEC_MODE=os_api (иначе отказ в старте); DEFAULT_CUSTOMER — UUID; фабрика передаёт настройки', async () => {
    const c = loadAppConfig({
      ...OSAPI_ENV,
      ONEC_OSAPI_WRITE_ORDERS: 'true',
      ONEC_OSAPI_DEFAULT_CUSTOMER: CUST_RETAIL,
    });
    expect(c.ONEC_OSAPI_WRITE_ORDERS).toBe(true);
    expect(loadAppConfig(OSAPI_ENV).ONEC_OSAPI_WRITE_ORDERS).toBe(false);
    for (const mode of ['extension', 'odata_only', 'fixtures']) {
      const msg = expectConfigError(() =>
        loadAppConfig({
          ...OSAPI_ENV,
          ONEC_MODE: mode,
          ONEC_HS_PATH: 'ut/hs',
          ONEC_HS_USER: 'h',
          ONEC_HS_TOKEN: 't',
          ONEC_OSAPI_WRITE_ORDERS: 'true',
        }),
      );
      expect(msg).toContain('ONEC_OSAPI_WRITE_ORDERS: true допустимо только при ONEC_MODE=os_api');
    }
    expect(expectConfigError(() => loadAppConfig({ ...OSAPI_ENV, ONEC_OSAPI_DEFAULT_CUSTOMER: 'розница' }))).toContain(
      'ONEC_OSAPI_DEFAULT_CUSTOMER',
    );
    // Фабрика: флаг и клиент по умолчанию доходят до шлюза (заказ без клиента 1С — на клиента по умолчанию).
    const t = standard().on('POST /orders', osApiOrdersStore().reply);
    const g = createOnecGateway(c, onecAdapters(c, t));
    await g.createOrder(orderPayload());
    expect((t.posts()[0].body as { customerId: string }).customerId).toBe(CUST_RETAIL);
  });

  it('wiring: os_api + ONEC_OSAPI_WRITE_ORDERS — канал только order/create с телефоном клиента; без флага — канала нет', () => {
    const pool = {} as pg.Pool;
    const log = pino({ level: 'silent' });
    const gw = writeGateway(standard());
    const on = createOrdersWorkerWiring({
      config: loadAppConfig({ ...OSAPI_ENV, ONEC_OSAPI_WRITE_ORDERS: 'true' }),
      pool,
      log,
      gateway: gw,
      notifications: null,
    }).outboxDelivery;
    expect(on?.configured).toBe(true);
    expect(on?.routes).toEqual(['order/create']);
    expect(on?.needsOrderCustomerPhone).toBe(true);
    const off = createOrdersWorkerWiring({
      config: loadAppConfig(OSAPI_ENV),
      pool,
      log,
      gateway: gw,
      notifications: null,
    });
    expect(off.outboxDelivery).toBeUndefined();
    // Прежний режим extension: канал на все маршруты, телефон клиента не читается.
    const ext = createOrdersWorkerWiring({
      config: loadAppConfig({
        ...OSAPI_ENV,
        ONEC_MODE: 'extension',
        ONEC_HS_PATH: 'ut/hs',
        ONEC_HS_USER: 'h',
        ONEC_HS_TOKEN: 't',
      }),
      pool,
      log,
      gateway: new FakeOnecGateway(),
      notifications: null,
    }).outboxDelivery;
    expect(ext?.routes).toBeUndefined();
    expect(ext?.needsOrderCustomerPhone).toBe(false);
  });
});

describe('Ревью 25.11.2026: запись заказов черновиком — восстановимость и точность', () => {
  const linked = { customer: { ref: null, contractorRef: CUST_1C, agreementRef: null } };
  const notFound = { status: 404, body: { error: { code: 'not_found', message: 'Заказ не найден' } } };

  /** `GET /orders/{id}` по содержимому хранилища `POST /orders` (Module.bsl `ДанныеЗаказа`). */
  function withOrderReads(
    t: FakeOsApiTransport,
    store: ReturnType<typeof osApiOrdersStore>,
    ids: string[],
  ): FakeOsApiTransport {
    for (const id of ids) {
      t.on(`/orders/${id}`, () => {
        const o = store.orders.get(id);
        return o ? { body: o } : notFound;
      });
    }
    return t;
  }

  it('повтор после неизвестного результата: сначала GET /orders/{id}; документ есть — sent без сборки тела и без POST', async () => {
    const store = osApiOrdersStore();
    const t = withOrderReads(standard().on('POST /orders', store.reply), store, [ORD]).on(`/customers?phone=${PHONE}`, {
      body: { items: [] },
    });
    const g = writeGateway(t);
    // Попытка 1 записала черновик (ответ потерян — для outbox результат неизвестен).
    await g.createOrder(orderPayload(linked));
    expect(t.posts()).toHaveLength(1);
    // Попытка 2: клиент больше не определяется (нет ссылки, по телефону пусто, клиента по умолчанию нет), но тело
    // не собирается: черновик найден, строка → sent, а не parked с сиротой в 1С.
    const d = new OnecOutboxDelivery(g, { timeoutMs: 5000, routes: ['order/create'], orderCustomerPhone: true });
    const res = await d.deliver(outboxRow({ payload: orderPayload(), attempts: 2, customerPhone: PHONE }));
    expect(res).toMatchObject({ kind: 'sent', onecRef: ORD, onecNumber: 'ОС-000001', onecStatus: 'Не согласован' });
    expect(t.posts()).toHaveLength(1);
    expect(t.paths()).toContain(`/orders/${ORD}`);
    expect(t.paths().some((p) => p.startsWith('/customers'))).toBe(false);
  });

  it('повтор: «Заказ не найден» — тело собирается и POST; иной 404 («Метод не найден») — transient без POST', async () => {
    const store = osApiOrdersStore();
    const fresh = U('99000000', 30);
    const t = withOrderReads(standard().on('POST /orders', store.reply), store, [fresh]);
    const d = new OnecOutboxDelivery(writeGateway(t), { timeoutMs: 5000, routes: ['order/create'] });
    const sent = await d.deliver(
      outboxRow({ externalId: fresh, aggregateId: fresh, payload: orderPayload(linked), attempts: 3 }),
    );
    expect(sent).toMatchObject({ kind: 'sent', onecRef: fresh });
    expect(t.posts().map((p) => (p.body as { id: string }).id)).toEqual([fresh]);
    // Публикация отвечает 404 «Метод не найден» (маршрута в фейке нет): это недоступность, а не отсутствие заказа.
    const lost = U('99000000', 31);
    const r = await d.deliver(
      outboxRow({ externalId: lost, aggregateId: lost, payload: orderPayload(linked), attempts: 2 }),
    );
    expect(r.kind).toBe('transient');
    expect(t.posts()).toHaveLength(1);
    // Первая попытка GET не делает.
    const first = U('99000000', 32);
    await d.deliver(outboxRow({ externalId: first, aggregateId: first, payload: orderPayload(linked), attempts: 1 }));
    expect(t.paths()).not.toContain(`/orders/${first}`);
    expect(t.posts()).toHaveLength(2);
  });

  it('OSAPI_MANUAL → parked с повторной проверкой через час (OSAPI_MANUAL_RECHECK_MS), попытки не тратятся', async () => {
    const t = standard().on(`/customers?phone=${PHONE}`, { body: { items: [] } });
    const d = new OnecOutboxDelivery(writeGateway(t), { timeoutMs: 5000, routes: ['order/create'] });
    const r = await d.deliver(outboxRow({ payload: orderPayload(), customerPhone: PHONE }));
    expect(r).toMatchObject({ kind: 'parked', recheckAfterMs: OSAPI_MANUAL_RECHECK_MS });
    expect(OSAPI_MANUAL_RECHECK_MS).toBe(3_600_000);
    // Маршрут, который канал не пишет, — парковка без повторной проверки (до ручного повтора).
    const other = await d.deliver(outboxRow({ operation: 'cancel', payload: {} }));
    expect(other.kind).toBe('parked');
    expect((other as { recheckAfterMs?: number }).recheckAfterMs).toBeUndefined();
  });

  it('хвост до включения записи: первая попытка без ошибок старше OUTBOX_MAX_AGE_HOURS — parked без запроса в 1С', async () => {
    const store = osApiOrdersStore();
    const t = standard().on('POST /orders', store.reply);
    const day = 24 * 3_600_000;
    const d = new OnecOutboxDelivery(writeGateway(t), {
      timeoutMs: 5000,
      routes: ['order/create'],
      parkStaleAfterMs: day,
    });
    const stale = await d.deliver(
      outboxRow({ payload: orderPayload(linked), ageMs: day + 60_000, lastErrorCode: null }),
    );
    expect(stale.kind).toBe('parked');
    expect((stale as { message: string }).message).toContain('«Повторить»');
    expect((stale as { recheckAfterMs?: number }).recheckAfterMs).toBeUndefined();
    expect(t.requests).toHaveLength(0);
    // После ручного повтора (строка была запаркована) или свежий заказ — уходит.
    const afterRetry = await d.deliver(
      outboxRow({ payload: orderPayload(linked), ageMs: day + 60_000, lastErrorCode: 'NO_WRITE_CHANNEL' }),
    );
    expect(afterRetry.kind).toBe('sent');
    const fresh = U('99000000', 33);
    const freshRes = await d.deliver(
      outboxRow({ externalId: fresh, aggregateId: fresh, payload: orderPayload(linked), ageMs: 3_600_000 }),
    );
    expect(freshRes.kind).toBe('sent');
    // Повторная попытка (attempts > 1) хвостом не считается.
    const retried = U('99000000', 34);
    t.on(`/orders/${retried}`, notFound);
    const retriedRes = await d.deliver(
      outboxRow({
        externalId: retried,
        aggregateId: retried,
        payload: orderPayload(linked),
        ageMs: day * 3,
        attempts: 2,
        lastErrorCode: 'ONEC_UNAVAILABLE',
      }),
    );
    expect(retriedRes.kind).toBe('sent');
  });

  it('производные ссылки: только /characteristics и /units (без /items), своя выгрузка с таймаутом 120 с без сигнала доставки', async () => {
    const t = standard().on('POST /orders', osApiOrdersStore().reply);
    const g = writeGateway(t);
    await g.createOrder(orderPayload(linked), { signal: AbortSignal.timeout(30_000), requestId: 'r-1' });
    const loads = t.requests.filter((r) => /\/(characteristics|units)$/.test(r.url));
    expect(loads.map((r) => r.url.slice(ROOT.length)).sort()).toEqual(['/characteristics', '/units']);
    for (const r of loads) {
      expect(r.timeoutMs).toBe(120_000);
      expect(r.signal).toBeUndefined();
    }
    expect(t.paths().some((p) => p.startsWith('/items'))).toBe(false);
    // POST — под сигналом доставки.
    expect(t.requests.find((r) => r.method === 'POST')?.signal).toBeDefined();
  });

  it('производные ссылки: товар, заведённый после выгрузки, — из кеша; промах по новой характеристике — одна перечитка без ожидания TTL', async () => {
    const t = standard().on('POST /orders', osApiOrdersStore().reply);
    const g = writeGateway(t);
    await g.createOrder(orderPayload(linked));
    const loads = (): number => t.paths().filter((p) => p === '/characteristics').length;
    expect(loads()).toBe(1);
    const line = (variantRef: string, productRef: string = PNT): Record<string, OnecJsonObject[string]> => ({
      lineNumber: 1,
      productRef,
      variantRef,
      packagingRef: null,
      quantity: '1.000',
      packQuantity: null,
      price: '100.00',
      amount: '100.00',
    });
    // Новый товар категории (в /items его ещё нет): производная ссылка той же характеристики — без запросов.
    const NEW_ITEM = U('c1000000', 77);
    await g.createOrder(
      orderPayload({
        ...linked,
        externalId: U('99000000', 40),
        lines: [line(osApiDerivedRef('characteristic', CH_R, NEW_ITEM), NEW_ITEM)],
      }),
    );
    expect(loads()).toBe(1);
    expect((t.posts()[1].body as { lines: { characteristicId: string }[] }).lines[0].characteristicId).toBe(CH_R);
    // Новая характеристика категории появилась в 1С после выгрузки: промах → перечитка → найдена.
    const CH_NEW = osu('f1000000', 7);
    const fixture = OSAPI_FIXTURE('characteristics.json') as { items: Record<string, unknown>[] };
    t.on('/characteristics', {
      body: {
        items: [
          ...fixture.items,
          { id: CH_NEW, ownerId: osu('d1000000', 1), ownerType: 'category', name: 'Зелёная', deleted: false },
        ],
      },
    });
    await g.createOrder(
      orderPayload({
        ...linked,
        externalId: U('99000000', 41),
        lines: [line(osApiDerivedRef('characteristic', CH_NEW, PNT))],
      }),
    );
    expect(loads()).toBe(2);
    expect((t.posts()[2].body as { lines: { characteristicId: string }[] }).lines[0].characteristicId).toBe(CH_NEW);
    // Ссылки нет и после перечитки — OSAPI_MANUAL (канал паркует с повторной проверкой).
    const e = (await g
      .createOrder(
        orderPayload({
          ...linked,
          externalId: U('99000000', 42),
          lines: [line(osApiDerivedRef('characteristic', osu('f1000000', 8), PNT))],
        }),
      )
      .catch((x: unknown) => x)) as OnecError;
    expect(e.code).toBe(OSAPI_MANUAL_CODE);
    expect(loads()).toBe(3);
    expect(t.paths().some((p) => p.startsWith('/items'))).toBe(false);
  });

  it('цена и скидка строки: процент, дающий ровно сумму POS; ступенчатая скидка — цена со скидкой; иначе ближайший процент', () => {
    expect(osApiLinePricing(500, 2, 900)).toEqual({ price: 500, discountPercent: 10 });
    expect(osApiLinePricing(1200, 3, 3600)).toEqual({ price: 1200, discountPercent: 0 });
    expect(osApiLinePricing(1200, 3, null)).toEqual({ price: 1200, discountPercent: 0 });
    // 3 % клиента и 2,5 % вручную: 8750 → 8275,31. Процент с 2 знаками даёт 8275,75 или 8274,87 — расхождение;
    // цена со скидкой 8275,31 × 1 — ровно сумма POS.
    expect(osApiLinePricing(8750, 1, 8275.31)).toEqual({ price: 8275.31, discountPercent: 0 });
    // Ни процент, ни цена с 2 знаками точно не выражают сумму — ближайший процент (1С вернёт свою сумму).
    expect(osApiLinePricing(100, 3, 285.01)).toEqual({ price: 100, discountPercent: 5 });
  });

  it('ступенчатая скидка доходит до POST /orders так, что 1С посчитает ровно сумму POS', async () => {
    const store = osApiOrdersStore();
    const t = standard().on('POST /orders', store.reply);
    await writeGateway(t).createOrder(
      orderPayload({
        ...linked,
        lines: [
          {
            lineNumber: 1,
            productRef: CEM,
            variantRef: null,
            packagingRef: null,
            quantity: '1.000',
            packQuantity: null,
            price: '8750.00',
            amount: '8275.31',
          },
        ],
      }),
    );
    expect((t.posts()[0].body as { lines: unknown[] }).lines[0]).toMatchObject({
      price: 8275.31,
      discountPercent: 0,
      quantity: 1,
    });
    expect(store.orders.get(ORD)?.total).toBe(8275.31);
  });

  it('shipmentDate: начало интервала, иначе конец, иначе дата доставки 00:00; другая зона — в +06:00', () => {
    expect(osApiShipmentDate({ desiredFrom: '2026-11-26T10:00:00+06:00' })).toBe('2026-11-26T10:00:00');
    expect(osApiShipmentDate({ desiredFrom: null, desiredTo: '2026-11-26T04:00:00Z' })).toBe('2026-11-26T10:00:00');
    expect(osApiShipmentDate({ desiredFrom: null, desiredTo: null, desiredDate: '2026-11-28' })).toBe(
      '2026-11-28T00:00:00',
    );
    expect(osApiShipmentDate({ desiredDate: 'завтра' })).toBeNull();
    expect(osApiShipmentDate({})).toBeNull();
    expect(osApiLocalDateTime('2026-11-25T20:30:00.000Z')).toBe('2026-11-26T02:30:00');
    expect(osApiLocalDateTime('2026-11-25T12:00:00')).toBe('2026-11-25T12:00:00');
    expect(osApiLocalDateTime('2026-11-25T12:00:00+05:00')).toBe('2026-11-25T13:00:00');
  });

  it('дата доставки без интервала: канал добавляет delivery.desiredDate из заказа → shipmentDate черновика', async () => {
    const t = standard().on('POST /orders', osApiOrdersStore().reply);
    const d = new OnecOutboxDelivery(writeGateway(t), {
      timeoutMs: 5000,
      routes: ['order/create'],
      orderCustomerPhone: true,
    });
    const payload = orderPayload({
      ...linked,
      delivery: { method: 'delivery', desiredFrom: null, desiredTo: null },
    });
    expect((await d.deliver(outboxRow({ payload, deliveryDate: '2026-11-28' }))).kind).toBe('sent');
    expect((t.posts()[0].body as { shipmentDate?: string }).shipmentDate).toBe('2026-11-28T00:00:00');
    // Сохранённый payload не меняется.
    expect((payload.delivery as Record<string, unknown>).desiredDate).toBeUndefined();
  });

  it('notFound пакета статусов — только «Заказ не найден»; «Метод не найден» на первом — ошибка; сбой /ping — ошибка без запросов заказов', async () => {
    const nf = (message: string, details?: Record<string, unknown>): OnecError =>
      new OnecError('getOrderStatus', 404, 'POS_E_NOT_FOUND', message, details);
    expect(isOsApiOrderNotFound(nf('Заказ не найден', { osApiCode: 'not_found' }))).toBe(true);
    expect(isOsApiOrderNotFound(nf('Метод не найден: orders/x', { osApiCode: 'not_found' }))).toBe(false);
    expect(isOsApiOrderNotFound(nf('Заказ не найден'))).toBe(false);
    const known = U('99000000', 50);
    const missing = U('99000000', 51);
    const unrouted = U('99000000', 52);
    const t = standard()
      .on(`/orders/${known}`, { body: { id: known, number: '1', posted: false, total: 1 } })
      .on(`/orders/${missing}`, notFound);
    const g = new OnecOsApiGateway(client(t));
    // «Метод не найден» на первом заказе — недоступность 1С (а не notFound для всего пакета).
    await expect(g.getOrderStatusBatch([unrouted, known, missing])).rejects.toBeInstanceOf(OnecError);
    // В середине — частичный результат: непрочитанные не попадают в notFound.
    const part = await g.getOrderStatusBatch([known, unrouted, missing]);
    expect((part.body.items as OnecJsonObject[]).map((x) => x.externalId)).toEqual([known]);
    expect(part.body.notFound).toEqual([]);
    expect((await g.getOrderStatusBatch([missing, known])).body.notFound).toEqual([missing]);
    // /ping недоступен — ни одного GET /orders.
    const down = standard().on('/ping', new OnecTransportError('network'));
    await expect(new OnecOsApiGateway(client(down)).getOrderStatusBatch([known])).rejects.toBeInstanceOf(OnecError);
    expect(down.paths().some((p) => p.startsWith('/orders'))).toBe(false);
  });

  it('расписание: order_status в os_api — только с ONEC_OSAPI_WRITE_ORDERS, cron как у перечитки каталога; wiring — ограниченный опрос', () => {
    expect(scheduledEntities('os_api', SYNC_ENTITY_VALUES, { osApiWriteOrders: true })).toContain('order_status');
    expect(scheduledEntities('os_api', SYNC_ENTITY_VALUES, { osApiWriteOrders: false })).not.toContain('order_status');
    const on = schedulerConfigFromEnv(
      loadAppConfig({ ...OSAPI_ENV, ONEC_OSAPI_WRITE_ORDERS: 'true', ONEC_OSAPI_POLL_SECONDS: '600' }),
    );
    expect(on.osApiWriteOrders).toBe(true);
    expect(on.cron.orderStatus).toBe('*/10 * * * *');
    expect(schedulerConfigFromEnv(loadAppConfig(OSAPI_ENV)).osApiWriteOrders).toBe(false);
    const w = createOrdersWorkerWiring({
      config: loadAppConfig({ ...OSAPI_ENV, ONEC_OSAPI_WRITE_ORDERS: 'true' }),
      pool: {} as pg.Pool,
      log: pino({ level: 'silent' }),
      gateway: writeGateway(standard()),
      notifications: null,
    });
    expect(w.handlers.order_status).toBeDefined();
    const h = w.handlers.order_status as unknown as { d: Record<string, unknown> };
    expect(h.d).toMatchObject({ maxOrders: 200, batchSize: 50, recentDays: 30 });
  });

  it('wiring: хвост старше OUTBOX_MAX_AGE_HOURS паркуется каналом без запроса в 1С', async () => {
    const t = standard();
    const w = createOrdersWorkerWiring({
      config: loadAppConfig({ ...OSAPI_ENV, ONEC_OSAPI_WRITE_ORDERS: 'true', OUTBOX_MAX_AGE_HOURS: '24' }),
      pool: {} as pg.Pool,
      log: pino({ level: 'silent' }),
      gateway: writeGateway(t),
      notifications: null,
    });
    const r = await w.outboxDelivery?.deliver(
      outboxRow({ payload: orderPayload(linked), ageMs: 25 * 3_600_000, lastErrorCode: null }),
    );
    expect(r?.kind).toBe('parked');
    expect(t.requests).toHaveLength(0);
  });
});

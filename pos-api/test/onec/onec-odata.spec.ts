import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import YAML from 'yaml';
import type {
  OnecHttpRequest,
  OnecHttpResponse,
  OnecHttpTransport,
} from '../../src/integrations/onec/onec-http-transport.js';
import { ODATA_ALLOWLIST, ODATA_DENIED, ODATA_MAX_TOP } from '../../src/integrations/onec/odata-allowlist.js';
import {
  ODATA_PAGE_TIMEOUT_MS,
  ODataAllowlistError,
  OnecODataClient,
  OnecODataError,
} from '../../src/integrations/onec/onec-odata.client.js';
import { OnecODataGateway } from '../../src/integrations/onec/onec-odata.gateway.js';
import { ODataCatalogSource } from '../../src/sync/apply/odata-catalog.source.js';

const ALLOWLIST_YAML = fileURLToPath(new URL('../../../contracts/onec/odata-allowlist.yaml', import.meta.url));

/** In-memory транспорт: ответы по подстроке декодированного URL; журнал запросов. */
class FakeTransport implements OnecHttpTransport {
  readonly urls: string[] = [];
  readonly headers: Record<string, string>[] = [];
  readonly timeouts: number[] = [];
  private readonly routes: { match: (url: string) => boolean; respond: (url: string) => OnecHttpResponse }[] = [];

  on(match: string | ((url: string) => boolean), respond: (url: string) => { status?: number; body: unknown }): this {
    const m = typeof match === 'string' ? (u: string) => u.includes(match) : match;
    this.routes.unshift({
      match: m,
      respond: (u) => {
        const r = respond(u);
        return {
          status: r.status ?? 200,
          headers: {},
          body: Buffer.from(typeof r.body === 'string' ? r.body : JSON.stringify(r.body), 'utf8'),
        };
      },
    });
    return this;
  }

  request(req: OnecHttpRequest): Promise<OnecHttpResponse> {
    const url = decodeURIComponent(req.url);
    this.urls.push(url);
    this.headers.push({ ...req.headers });
    this.timeouts.push(req.timeoutMs ?? -1);
    const r = this.routes.find((x) => x.match(url));
    return Promise.resolve(
      r
        ? r.respond(url)
        : { status: 404, headers: {}, body: Buffer.from('{"odata.error":{"message":{"value":"Entity not found"}}}') },
    );
  }
}

const cfg = {
  baseUrl: 'https://host-1c.local',
  odataPath: 'ut11/odata/standard.odata',
  user: 'pos_integration',
  password: 'test-only', // check-secrets: allow — фиктивное значение теста/приёмки на мок-сервере
  pageSize: 2,
};

describe('OData фазы 0: allow-list (ONEC-083), $select/$filter/$top/$skip, $format=json, DataVersion', () => {
  it('allow-list в коде совпадает с contracts/onec/odata-allowlist.yaml (коллекции, поля, операции)', () => {
    const y = YAML.parse(readFileSync(ALLOWLIST_YAML, 'utf8')) as {
      odata: { maxTop: number };
      collections: { name: string; kind: string; operations: string[]; fields: string[]; conditional?: boolean }[];
      deniedExamples: string[];
      excluded: { name: string }[];
    };
    expect(ODATA_MAX_TOP).toBe(y.odata.maxTop);
    expect(
      ODATA_ALLOWLIST.map((c) => ({
        name: c.name,
        kind: c.kind,
        operations: [...c.operations],
        fields: [...c.fields],
        conditional: c.conditional,
      })),
    ).toEqual(
      y.collections.map((c) => ({
        name: c.name,
        kind: c.kind,
        operations: c.operations,
        fields: c.fields,
        conditional: c.conditional === true,
      })),
    );
    expect([...ODATA_DENIED].sort()).toEqual([...y.deniedExamples, ...y.excluded.map((e) => e.name)].sort());
  });

  it('коллекция вне allow-list → отказ до отправки запроса (Catalog_Пользователи, AccountingRegister_Хозрасчетный, выдуманная)', async () => {
    const t = new FakeTransport();
    const c = new OnecODataClient(cfg, t);
    for (const name of ['Catalog_Пользователи', 'AccountingRegister_Хозрасчетный', 'Catalog_Чтото']) {
      await expect(c.list(name, { select: ['Ref_Key'] })).rejects.toBeInstanceOf(ODataAllowlistError);
      await expect(c.count(name)).rejects.toBeInstanceOf(ODataAllowlistError);
    }
    expect(t.urls).toHaveLength(0);
  });

  it('поле вне allow-list, пустой $select, $top > 2000, недопустимая виртуальная таблица → отказ', async () => {
    const t = new FakeTransport();
    const c = new OnecODataClient(cfg, t);
    await expect(c.list('Catalog_Номенклатура', { select: ['Ref_Key', 'ЗакупочнаяЦена'] })).rejects.toThrow(
      /поля вне allow-list/,
    );
    await expect(c.list('Catalog_Номенклатура', { select: [] })).rejects.toThrow(/\$select обязателен/);
    await expect(c.list('Catalog_Номенклатура', { select: ['Ref_Key'], top: 5000 })).rejects.toThrow(/\$top/);
    await expect(
      c.list('Catalog_Номенклатура', { select: ['Ref_Key'], virtual: { op: 'balance', params: 'x' } }),
    ).rejects.toThrow(/не разрешена/);
    await expect(c.list('AccumulationRegister_ТоварыНаСкладах', { select: ['Склад_Key'] })).rejects.toThrow(
      /list не разрешена/,
    );
    expect(t.urls).toHaveLength(0);
  });

  it('URL: $format=json, $select, $filter, $top/$skip; Basic pos_integration; X-Request-Id; страницы до короткой', async () => {
    const t = new FakeTransport().on('Catalog_Склады?', (u) => {
      const skip = Number(/\$skip=(\d+)/.exec(u)?.[1] ?? 0);
      const all = [1, 2, 3].map((i) => ({
        Ref_Key: `d4e5f6a7-0000-4000-8000-00000000000${i}`,
        DataVersion: `AAAA${i}`,
        DeletionMark: false,
        IsFolder: false,
        Code: `00${i}`,
        Description: `Склад ${i}`,
      }));
      return { body: { 'odata.metadata': 'x', value: all.slice(skip, skip + 2) } };
    });
    const c = new OnecODataClient(cfg, t);
    const pages: number[] = [];
    for await (const p of c.pages('Catalog_Склады', {
      select: ['Ref_Key', 'DataVersion', 'DeletionMark'],
      filter: 'IsFolder eq false',
    }))
      pages.push(p.rows.length);
    expect(pages).toEqual([2, 1]);
    expect(t.urls[0]).toBe(
      'https://host-1c.local/ut11/odata/standard.odata/Catalog_Склады?$format=json&$select=Ref_Key,DataVersion,DeletionMark&$filter=IsFolder eq false&$top=2&$skip=0',
    );
    expect(t.urls[1]).toContain('$skip=2');
    expect(t.headers[0].Authorization).toBe(`Basic ${Buffer.from('pos_integration:test-only').toString('base64')}`);
    expect(t.headers[0]['X-Request-Id']).toMatch(/^[0-9a-f-]{36}$/);
  });

  it('$count; ошибка OData → OnecODataError с кодом статуса (404 — notFound, 503 — retryable)', async () => {
    const t = new FakeTransport()
      .on('/$count', () => ({ body: '42' }))
      .on('Catalog_ВидыЦен', () => ({
        status: 503,
        body: { 'odata.error': { message: { value: 'база заблокирована' } } },
      }));
    const c = new OnecODataClient(cfg, t);
    expect(await c.count('Catalog_Склады', 'IsFolder eq false')).toBe(42);
    const e = await c.list('Catalog_ВидыЦен', { select: ['Ref_Key'] }).catch((x: unknown) => x);
    expect(e).toBeInstanceOf(OnecODataError);
    expect((e as OnecODataError).retryable).toBe(true);
    expect((e as OnecODataError).message).toContain('база заблокирована');
  });

  it('таймауты (05 SYNC-030, ревью E-onec-sync-7): чтение страницы — 60 с, $count — ONEC_TIMEOUT_MS', async () => {
    // Маршруты FakeTransport: последний зарегистрированный проверяется первым.
    const t = new FakeTransport()
      .on('Catalog_Склады', () => ({ body: { value: [{ Ref_Key: 'a' }] } }))
      .on('/$count', () => ({ body: '3' }));
    const c = new OnecODataClient({ ...cfg, timeoutMs: 30_000 }, t);
    await c.list('Catalog_Склады', { select: ['Ref_Key'] });
    for await (const p of c.pages('Catalog_Склады', { select: ['Ref_Key'] })) expect(p.rows).toHaveLength(1);
    await c.count('Catalog_Склады');
    expect(t.timeouts).toEqual([ODATA_PAGE_TIMEOUT_MS, ODATA_PAGE_TIMEOUT_MS, 30_000]);
    expect(ODATA_PAGE_TIMEOUT_MS).toBe(60_000);
  });

  it('OnecODataGateway: health — лёгкий запрос; методы расширения (запись, /changes) недоступны', async () => {
    const t = new FakeTransport().on('Catalog_Склады', () => ({ body: { value: [] } }));
    const g = new OnecODataGateway(new OnecODataClient(cfg, t));
    expect((await g.getHealth()).body.status).toBe('ok');
    await expect(g.createOrder({})).rejects.toMatchObject({ status: 501 });
    await expect(g.ackChanges(1)).rejects.toMatchObject({ status: 501 });
  });
});

describe('ODataCatalogSource: строки OData → элементы /changes (синтетические строки)', () => {
  const P1 = 'a1b2c3d4-0000-4000-8000-000000000001';
  const UNIT = 'a1b2c3d4-0000-4000-8000-0000000000e1';
  const PROP = 'a1b2c3d4-0000-4000-8000-000000000301';
  const VAL = 'a1b2c3d4-0000-4000-8000-000000000302';
  const PL = 'e5f6a7b8-0000-4000-8000-000000000001';
  const WH = 'd4e5f6a7-0000-4000-8000-000000000001';

  function transport(): FakeTransport {
    return new FakeTransport()
      .on('Catalog_Номенклатура?', () => ({
        body: {
          value: [
            {
              Ref_Key: P1,
              DataVersion: 'AAAAAgAAAAA=',
              DeletionMark: false,
              IsFolder: false,
              Code: '00001234',
              Description: 'Смеситель для кухни однорычажный',
              НаименованиеПолное: 'Смеситель для кухни однорычажный, хром',
              Артикул: 'KX-1245',
              Parent_Key: '00000000-0000-0000-0000-000000000000',
              ЕдиницаИзмерения_Key: UNIT,
              ВидНоменклатуры_Key: '00000000-0000-0000-0000-000000000000',
              Описание: '',
              ФайлКартинки_Key: '00000000-0000-0000-0000-000000000000',
              Весовой: false,
            },
          ],
        },
      }))
      .on('Catalog_Номенклатура_ДополнительныеРеквизиты', () => ({
        body: {
          value: [
            {
              Ref_Key: P1,
              Свойство_Key: PROP,
              Значение: VAL,
              Значение_Type: 'StandardODATA.Catalog_ЗначенияСвойствОбъектов',
            },
          ],
        },
      }))
      .on('ChartOfCharacteristicTypes_ДополнительныеРеквизитыИСведения', () => ({
        body: { value: [{ Ref_Key: PROP, Description: 'Цвет' }] },
      }))
      .on('Catalog_ЗначенияСвойствОбъектов', () => ({ body: { value: [{ Ref_Key: VAL, Description: 'Хром' }] } }))
      .on('InformationRegister_ЦеныНоменклатуры/SliceLast', () => ({
        body: {
          value: [
            {
              Period: '2026-10-20T09:00:00',
              ВидЦены_Key: PL,
              Номенклатура_Key: P1,
              Характеристика_Key: '00000000-0000-0000-0000-000000000000',
              Упаковка_Key: '00000000-0000-0000-0000-000000000000',
              Цена: 2350.5,
            },
          ],
        },
      }))
      .on('AccumulationRegister_СвободныеОстатки/Balance', () => ({
        status: 404,
        body: { 'odata.error': { message: { value: 'Entity not found' } } },
      }))
      .on('AccumulationRegister_ТоварыНаСкладах/Balance', () => ({
        body: {
          value: [
            {
              Номенклатура_Key: P1,
              Характеристика_Key: '00000000-0000-0000-0000-000000000000',
              Склад_Key: WH,
              ВНаличииBalance: 16,
            },
          ],
        },
      }));
  }

  it('товар: поля, нулевые ссылки → null, ДополнительныеРеквизиты → attributes (имя свойства и значение-элемент)', async () => {
    const src = new ODataCatalogSource(new OnecODataClient(cfg, transport()));
    const pages: unknown[] = [];
    for await (const p of src.read('products')) pages.push(...p);
    expect(pages).toEqual([
      expect.objectContaining({
        type: 'Catalog_Номенклатура',
        ref: P1,
        isFolder: false,
        sku: 'KX-1245',
        parentRef: null,
        baseUnitRef: UNIT,
        imageFileRef: null,
        descriptionText: null,
        // Бренд по OData не читается (нет в allow-list) — признак «неизвестен», не `brand: null` (п. 15).
        brandUnknown: true,
        attributes: [
          {
            propertyRef: PROP,
            name: 'Цвет',
            valueType: 'Catalog_ЗначенияСвойствОбъектов',
            valueRef: VAL,
            valueText: 'Хром',
          },
        ],
      }),
    ]);
    expect(pages[0]).not.toHaveProperty('brand');
  });

  // 12 T-SYNC-F03 (05 SYNC-002, AC-SYNC-002: продолжение полной загрузки с cursor_to — $skip без перечитки)
  it('readPages(kind, startSkip): чтение с $skip=startSkip, nextSkip — по числу строк OData (не элементов)', async () => {
    const rows = (from: number, n: number) =>
      Array.from({ length: n }, (_, i) => ({
        Ref_Key: `d4e5f6a7-0000-4000-8000-${String(from + i + 1).padStart(12, '0')}`,
        DataVersion: 'AAAA',
        DeletionMark: false,
        IsFolder: false,
        Code: String(from + i + 1),
        Description: `Склад ${from + i + 1}`,
      }));
    const t = new FakeTransport().on('Catalog_Склады?', (u) => {
      const skip = Number(/\$skip=(\d+)/.exec(u)?.[1] ?? 0);
      return { body: { value: skip === 4 ? rows(4, 2) : skip === 6 ? rows(6, 1) : [] } };
    });
    const src = new ODataCatalogSource(new OnecODataClient(cfg, t));
    const pages: { refs: number; nextSkip: number }[] = [];
    for await (const p of src.readPages('warehouses', 4)) pages.push({ refs: p.items.length, nextSkip: p.nextSkip });
    expect(pages).toEqual([
      { refs: 2, nextSkip: 6 },
      { refs: 1, nextSkip: 7 },
    ]);
    expect(t.urls.filter((u) => u.includes('Catalog_Склады?')).map((u) => /\$skip=(\d+)/.exec(u)?.[1])).toEqual([
      '4',
      '6',
    ]);
  });

  // 12 T-ONEC-017 (даты +06:00)
  it('срез цен SliceLast по виду цены (Period без зоны → +06:00, ONEC-103); остатки: нет СвободныеОстатки → ТоварыНаСкладах', async () => {
    const t = transport();
    const src = new ODataCatalogSource(new OnecODataClient(cfg, t), () => new Date('2026-10-22T04:00:00Z'));
    const prices = [];
    for await (const p of src.priceSlice([PL])) prices.push(...p);
    expect(prices).toEqual([
      {
        priceListRef: PL,
        productRef: P1,
        variantRef: null,
        packagingRef: null,
        price: '2350.5',
        period: '2026-10-20T09:00:00+06:00',
      },
    ]);
    expect(t.urls.find((u) => u.includes('SliceLast'))).toContain(
      "SliceLast(Period=datetime'2026-10-22T10:00:00',Condition='ВидЦены_Key eq guid''e5f6a7b8",
    );
    const stock = [];
    for await (const p of src.stockSlice()) stock.push(...p);
    expect(stock).toEqual([
      { warehouseRef: WH, productRef: P1, variantRef: null, onHand: '16', reserved: '0', available: null },
    ]);
  });
});

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type {
  OnecHttpRequest,
  OnecHttpResponse,
  OnecHttpTransport,
} from '../../src/integrations/onec/onec-http-transport.js';
import { OnecOsApiClient } from '../../src/integrations/onec/onec-osapi.client.js';

/**
 * ОС_API в памяти (ADR-126): синтетические ответы по форме `Module.bsl` 0.2.9 (вымышленные данные,
 * test/onec/osapi-fixtures) и транспорт с журналом запросов. Сети нет.
 */

export const OSAPI_FIXTURE = (name: string): unknown =>
  JSON.parse(
    readFileSync(fileURLToPath(new URL(`../onec/osapi-fixtures/${name}`, import.meta.url)), 'utf8'),
  ) as unknown;

export const OSAPI_ROOT = 'http://localhost/uk_test/hs/os/api/v1';

/** UUID фикстур: `<префикс>-0000-4000-8000-<номер>`. */
export const osu = (p: string, n: number): string => `${p}-0000-4000-8000-${String(n).padStart(12, '0')}`;

/** Ссылки фикстур (совпадают с test/onec/osapi-fixtures/*.json). */
export const OSAPI_REFS = {
  PT1: osu('a1000000', 1),
  PT2: osu('a1000000', 2),
  PT3: osu('a1000000', 3),
  WH1: osu('b1000000', 1),
  WH2: osu('b1000000', 2),
  GRP: osu('c1000000', 1),
  CEM: osu('c1000000', 10),
  PNT: osu('c1000000', 11),
  TIL: osu('c1000000', 12),
  OLD: osu('c1000000', 13),
  KG: osu('e1000000', 1),
  SHT: osu('e1000000', 2),
  CH_W: osu('f1000000', 1),
  CH_R: osu('f1000000', 2),
  CH_DEL: osu('f1000000', 4),
  UN_BAG: osu('a2000000', 1),
  UN_BOX: osu('a2000000', 2),
  F1: osu('a3000000', 1),
  F2: osu('a3000000', 2),
  F3: osu('a3000000', 3),
} as const;

export type OsApiReply = { status?: number; body: unknown; headers?: Record<string, string> } | Error;

/**
 * Транспорт в памяти: ответ по пути после корня сервиса (с параметрами); журнал запросов. Маршрут `'/путь'` — для
 * `GET`; `'POST /путь'` — для `POST` (GET-маршрут на `POST` не отвечает: запись видна явно). Ответ-функция получает
 * разобранное JSON-тело запроса (ОС_API `POST /orders`).
 */
export class FakeOsApiTransport implements OnecHttpTransport {
  readonly requests: OnecHttpRequest[] = [];
  private readonly routes = new Map<string, OsApiReply | OsApiReply[] | ((body: unknown) => OsApiReply)>();

  on(path: string, reply: OsApiReply | OsApiReply[] | ((body: unknown) => OsApiReply)): this {
    this.routes.set(path, reply);
    return this;
  }

  paths(): string[] {
    return this.requests.map((r) => r.url.slice(OSAPI_ROOT.length));
  }

  /** Запросы `POST` (путь и разобранное тело). */
  posts(): { path: string; body: unknown }[] {
    return this.requests
      .filter((r) => r.method === 'POST')
      .map((r) => ({
        path: r.url.slice(OSAPI_ROOT.length),
        body: r.body ? (JSON.parse(r.body.toString('utf8')) as unknown) : undefined,
      }));
  }

  request(req: OnecHttpRequest): Promise<OnecHttpResponse> {
    this.requests.push(req);
    const path = req.url.startsWith(OSAPI_ROOT) ? req.url.slice(OSAPI_ROOT.length) : req.url;
    const route = this.routes.get(req.method === 'POST' ? `POST ${path}` : path);
    let r: OsApiReply | OsApiReply[] | undefined =
      typeof route === 'function'
        ? route(req.body ? (JSON.parse(req.body.toString('utf8')) as unknown) : undefined)
        : route;
    if (Array.isArray(r)) r = r.length > 1 ? r.shift() : r[0];
    if (r === undefined) {
      r = { status: 404, body: { error: { code: 'not_found', message: `Метод не найден: ${path}` } } };
    }
    if (r instanceof Error) return Promise.reject(r);
    const body = Buffer.isBuffer(r.body)
      ? r.body
      : Buffer.from(typeof r.body === 'string' ? r.body : JSON.stringify(r.body), 'utf8');
    return Promise.resolve({ status: r.status ?? 200, headers: r.headers ?? {}, body });
  }
}

/**
 * ОС_API `POST /orders` в памяти по Module.bsl `СоздатьЗаказ`: первый запрос с `id` → 201 `created:true`, повтор того
 * же `id` → 200 `created:false` (тот же документ); `post:false` → `posted:false`. Номер — `ОС-000001`… по порядку.
 */
export function osApiOrdersStore(): {
  readonly reply: (body: unknown) => OsApiReply;
  readonly orders: Map<string, Record<string, unknown>>;
} {
  const orders = new Map<string, Record<string, unknown>>();
  const reply = (raw: unknown): OsApiReply => {
    const b = raw as Record<string, unknown>;
    const id = String(b.id);
    const known = orders.get(id);
    if (known) return { status: 200, body: { ...known, created: false } };
    const lines = (b.lines as Record<string, number>[]).map((l) => ({
      ...l,
      total: Math.round(l.price * l.quantity * (100 - (l.discountPercent ?? 0))) / 100,
    }));
    const doc = {
      id,
      number: `ОС-${String(orders.size + 1).padStart(6, '0')}`,
      date: '2026-11-25T12:00:00',
      posted: b.post !== false,
      customerId: b.customerId,
      warehouseId: b.warehouseId,
      stateName: 'Новый',
      isCompleted: false,
      total: lines.reduce((s, l) => s + l.total, 0),
      currency: 'сом',
      lines,
      shipments: [],
      receipts: [],
      notShippedLines: [],
    };
    orders.set(id, doc);
    return { status: 201, body: { ...doc, created: true } };
  };
  return { reply, orders };
}

/** Все маршруты чтения ОС_API на фикстурах. */
export function standardOsApi(): FakeOsApiTransport {
  const { PT1, PT2 } = OSAPI_REFS;
  return new FakeOsApiTransport()
    .on('/ping', { body: OSAPI_FIXTURE('ping.json') })
    .on('/price-types', { body: OSAPI_FIXTURE('price-types.json') })
    .on('/warehouses', { body: OSAPI_FIXTURE('warehouses.json') })
    .on('/items', { body: OSAPI_FIXTURE('items.json') })
    .on('/characteristics', { body: OSAPI_FIXTURE('characteristics.json') })
    .on('/units', { body: OSAPI_FIXTURE('units.json') })
    .on('/barcodes', { body: OSAPI_FIXTURE('barcodes.json') })
    .on(`/prices?priceType=${PT1}`, { body: OSAPI_FIXTURE('prices-retail.json') })
    .on(`/prices?priceType=${PT2}`, { body: { priceTypeId: PT2, items: [] } })
    .on('/stock', { body: OSAPI_FIXTURE('stock.json') })
    .on('/item-files', { body: OSAPI_FIXTURE('item-files.json') });
}

export function osApiTestClient(t: OnecHttpTransport): OnecOsApiClient {
  return new OnecOsApiClient(
    { baseUrl: 'http://localhost/uk_test/', user: 'api_test', password: 'test-only', timeoutMs: 7000 }, // check-secrets: allow — фиктивное значение теста
    t,
    () => Promise.resolve(),
  );
}

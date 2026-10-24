import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FakeExchangePlan } from './fake-exchange-plan.js';
import type {
  OnecCatalogItem,
  OnecNomenclatureItem,
  OnecPriceListItem,
  OnecPriceRow,
  OnecStockRow,
  OnecWarehouseItem,
} from './onec-catalog.types.js';
import { OnecError } from './onec-error.js';
import {
  ONEC_OPERATIONS,
  type OnecCallOptions,
  type OnecChangesAck,
  type OnecChangesPage,
  type OnecChangesQuery,
  type OnecExternalIdsQuery,
  type OnecGateway,
  type OnecHealth,
  type OnecImage,
  type OnecJson,
  type OnecJsonObject,
  type OnecOperationId,
  type OnecQrCancelReason,
  type OnecQrCancelResponse,
  type OnecQrCreateRequest,
  type OnecQrCreateResponse,
  type OnecQrPaymentStatus,
  type OnecResult,
} from './onec-gateway.js';
import {
  SyntheticCashier,
  type SyntheticCashierOptions,
  SyntheticOnecRejection,
  type SyntheticProductRef,
} from './synthetic-cashier.js';
import {
  SyntheticCatalog,
  type SyntheticCatalogOptions,
  type SyntheticMutation,
  type SyntheticMutationResult,
} from './synthetic-catalog.js';

/** Обязательная маркировка фикстуры (contracts/onec/NOTES.md §1; RM-C-008 «явная маркировка тестовых данных»). */
export const FIXTURE_NOTE = 'тестовые данные';

/** Каталог фикстур по умолчанию: `<repo>/contracts/onec/fixtures` (одинаково из src/ и dist/). */
export const DEFAULT_ONEC_FIXTURES_DIR = fileURLToPath(
  new URL('../../../../contracts/onec/fixtures/', import.meta.url),
);

export interface OnecFixture {
  /** Имя файла без `.json`, например `payments-status.paid.200`. */
  readonly name: string;
  readonly operation: string;
  readonly kind: 'request' | 'response';
  readonly status?: number;
  readonly headers?: Readonly<Record<string, string>>;
  readonly body: OnecJson;
}

/** Ответы по умолчанию (успешный сценарий) — по одной фикстуре на операцию. */
export const DEFAULT_ONEC_SCENARIO: Readonly<Partial<Record<OnecOperationId, string>>> = {
  getHealth: 'health.200',
  getChanges: 'changes.catalog.page1.200',
  ackChanges: 'changes-ack.200',
  createOrder: 'orders-create.201',
  getOrderStatus: 'orders-status.200',
  getOrderStatusBatch: 'orders-status-batch.200',
  cancelOrder: 'orders-cancel.200',
  createPayment: 'payments-create.201',
  createQrPayment: 'payments-qr.201',
  getQrPaymentStatus: 'payments-status.pending.200',
  cancelQrPayment: 'payments-qr-cancel.200',
  findCustomersByPhone: 'customers-search.200',
  createCustomer: 'customers-create.201',
  getCustomerReceivables: 'receivables.200',
  createReturnRequest: 'returns-create.201',
  getReturnRequestStatus: 'returns-status.200',
  checkCart: 'check.stock-prices.200',
  getCatalogCard: 'catalog-card.200',
  listExternalIds: 'external-ids.200',
};

export interface FakeOnecGatewayOptions {
  readonly fixturesDir?: string;
  /** Переопределение сценария: операция → имя фикстуры (успех или ошибка). */
  readonly scenario?: Partial<Record<OnecOperationId, string>>;
  /**
   * Режим синтетического каталога (RM-E-001): `/changes`, `/changes/ack`, `/changes/reregister` и
   * `/catalog/{ref}` обслуживаются моделью плана обмена над `SyntheticCatalog` (детерминированные тестовые данные),
   * а не статическими фикстурами. Остальные операции — как прежде, из фикстур.
   */
  readonly catalog?: SyntheticCatalog | SyntheticCatalogOptions;
  /** Добавить к синтетическому каталогу справочники и срезы из фикстур (`changes.catalog.page1`, `catalog-card`). */
  readonly includeFixtureCatalog?: boolean;
  /** Начальная регистрация всего каталога в плане обмена (как после `reregister`); по умолчанию `true`. */
  readonly registerAll?: boolean;
  /**
   * Режим кассира (этап G, **тестовые данные**): клиенты с телефонами, соглашения, скидки, реализации, оплаты и
   * возвраты в плане обмена (`/changes`), а `findCustomersByPhone`, `createCustomer` (201/200/409),
   * `getCustomerReceivables` (снимок на момент ответа; 404), `createReturnRequest` (201/200/409/422) и
   * `getReturnRequestStatus` — по состоянию `SyntheticCashier`, а не по статическим фикстурам. Без каталога
   * товары строк реализаций — товар фикстуры (`FIXTURE_PRODUCT`), с каталогом — его товары.
   */
  readonly cashier?: SyntheticCashier | SyntheticCashierOptions;
}

export interface FakeOnecCall {
  readonly operation: OnecOperationId;
  readonly args: readonly unknown[];
}

/**
 * `FakeOnecGateway` (05 ONEC-023, RM-C-008): ответы 1С из фикстур `contracts/onec/fixtures/*.json` без сети.
 * Только `ONEC_MODE=fixtures` и только вне prod (проверка — env.schema.ts и createOnecGateway).
 *
 * - Ответ операции — фикстура сценария (`DEFAULT_ONEC_SCENARIO` + `scenario`/`useFixture`); фикстура с HTTP ≥ 400
 *   бросает `OnecError` с кодом `POS_E_*` из её тела — так тестируются ветки ошибок.
 * - Поле `_note` в ответ не попадает, но каждая загруженная фикстура обязана его иметь (иначе — ошибка загрузки).
 * - Идентичность запроса переносится в ответ: `externalId` (заказ, платёж, клиент) и `customerRef` — чтобы потребитель
 *   мог сопоставить ответ своему агрегату; остальные поля — как в фикстуре.
 * - `getChanges`: без `cursor` — первая страница сообщения, с `cursor` первой страницы — вторая (`hasMore=false`).
 * - Журнал вызовов `calls` — для проверок в тестах.
 */
export class FakeOnecGateway implements OnecGateway {
  readonly mode = 'fixtures' as const;
  readonly calls: FakeOnecCall[] = [];
  private readonly fixtures = new Map<string, OnecFixture>();
  private readonly scenario = new Map<OnecOperationId, string>();
  /** Синтетический каталог (режим `catalog`), иначе `undefined`. */
  readonly catalog: SyntheticCatalog | undefined;
  /** План обмена над `catalog` и/или `cashier`. */
  readonly exchange: FakeExchangePlan | undefined;
  /** Синтетика кассира (режим `cashier`), иначе `undefined`. */
  readonly cashier: SyntheticCashier | undefined;

  constructor(options: FakeOnecGatewayOptions = {}) {
    const dir = options.fixturesDir ?? DEFAULT_ONEC_FIXTURES_DIR;
    for (const file of readdirSync(dir).filter((f) => f.endsWith('.json'))) {
      const raw = JSON.parse(readFileSync(join(dir, file), 'utf8')) as Record<string, unknown>;
      const name = file.slice(0, -'.json'.length);
      if (raw._note !== FIXTURE_NOTE) {
        throw new Error(`Фикстура 1С ${file} без маркировки "_note": "${FIXTURE_NOTE}"`);
      }
      this.fixtures.set(name, {
        name,
        operation: String(raw.operation),
        kind: raw.kind === 'request' ? 'request' : 'response',
        status: typeof raw.status === 'number' ? raw.status : undefined,
        headers: raw.headers as Record<string, string> | undefined,
        body: (raw.body ?? null) as OnecJson,
      });
    }
    for (const [op, name] of Object.entries({ ...DEFAULT_ONEC_SCENARIO, ...options.scenario })) {
      this.useFixture(op as OnecOperationId, name);
    }
    if (options.catalog) {
      this.catalog =
        options.catalog instanceof SyntheticCatalog ? options.catalog : new SyntheticCatalog(options.catalog);
      if (options.includeFixtureCatalog) this.mergeFixtureCatalog(this.catalog);
      this.exchange = new FakeExchangePlan(this.catalog);
    }
    if (options.cashier) {
      this.cashier =
        options.cashier instanceof SyntheticCashier
          ? options.cashier
          : new SyntheticCashier({
              ...(this.catalog ? { products: catalogProducts(this.catalog) } : {}),
              ...options.cashier,
            });
      const exchange = this.exchange ?? new FakeExchangePlan(null);
      this.exchange = exchange.addSource(this.cashier);
      this.cashier.subscribe((keys) => exchange.register(keys));
    }
    if (this.exchange && options.registerAll !== false) this.exchange.registerAll();
  }

  /** Изменения «следующей версии» каталога с регистрацией изменённых объектов в плане обмена. */
  mutateCatalog(m: SyntheticMutation): SyntheticMutationResult {
    const { catalog, exchange } = this.requireCatalog();
    const r = catalog.mutate(m);
    exchange.register(r.changedKeys);
    return r;
  }

  /** Срез цен по видам цен (фаза 1 — перечитка по `Document_УстановкаЦенНоменклатуры`; не метод контракта HS). */
  priceSlice(priceListRefs?: readonly string[]): OnecPriceRow[] {
    return this.requireCatalog().catalog.priceSlice(priceListRefs);
  }

  /** Срез остатков по складам (не метод контракта HS: в фазе 1 — OData `Balance`/`/check`, 05 SYNC-014). */
  stockSlice(warehouseRefs?: readonly string[]): OnecStockRow[] {
    return this.requireCatalog().catalog.stockSlice(warehouseRefs);
  }

  private requireCatalog(): { catalog: SyntheticCatalog; exchange: FakeExchangePlan } {
    if (!this.catalog || !this.exchange)
      throw new Error('FakeOnecGateway: режим каталога не включён (options.catalog)');
    return { catalog: this.catalog, exchange: this.exchange };
  }

  /** Справочники и срезы фикстур каталога (05 §6.4) поверх синтетики; недостающие в фикстурах склад/вид цены. */
  private mergeFixtureCatalog(catalog: SyntheticCatalog): void {
    const page = this.fixture('changes.catalog.page1.200').body as { items?: OnecCatalogItem[] };
    const card = this.fixture('catalog-card.200').body as unknown as {
      product: OnecNomenclatureItem;
      prices: Omit<OnecPriceRow, 'productRef'>[];
      stock: (Omit<OnecStockRow, 'productRef' | 'available'> & { available: string })[];
    };
    const items = [...(page.items ?? [])];
    const known = new Set(items.map((i) => i.ref));
    const extraWarehouse = (ref: string): OnecWarehouseItem => ({
      type: 'Catalog_Склады',
      ref,
      dataVersion: 'AAAAAQAAAAA=',
      deletionMark: false,
      isFolder: false,
      code: null,
      description: 'Склад фикстуры',
    });
    const extraPriceList = (ref: string): OnecPriceListItem => ({
      type: 'Catalog_ВидыЦен',
      ref,
      dataVersion: 'AAAAAQAAAAA=',
      deletionMark: false,
      code: null,
      description: 'Вид цены фикстуры',
      currency: 'KGS',
      usedForSales: true,
      priceIncludesVat: true,
    });
    for (const r of new Set(card.stock.map((x) => x.warehouseRef))) if (!known.has(r)) items.push(extraWarehouse(r));
    for (const r of new Set(card.prices.map((x) => x.priceListRef))) if (!known.has(r)) items.push(extraPriceList(r));
    catalog.merge(
      items,
      card.prices.map((x) => ({ ...x, productRef: card.product.ref })),
      card.stock.map((x) => ({ ...x, productRef: card.product.ref })),
    );
  }

  /** Имена загруженных фикстур (для диагностики и тестов). */
  fixtureNames(): string[] {
    return [...this.fixtures.keys()].sort();
  }

  /** Загруженная фикстура (тело без `_note`, копия). */
  fixture(name: string): OnecFixture {
    const f = this.fixtures.get(name);
    if (!f) throw new Error(`Нет фикстуры 1С ${name}`);
    return { ...f, body: structuredClone(f.body) };
  }

  /** Переключить ответ операции на фикстуру (например, `getQrPaymentStatus` → `payments-status.paid.200`). */
  useFixture(operation: OnecOperationId, name: string): void {
    const f = this.fixtures.get(name);
    if (!f) throw new Error(`Нет фикстуры 1С ${name}`);
    if (f.kind !== 'response' || f.operation !== ONEC_OPERATIONS[operation]) {
      throw new Error(`Фикстура ${name} (${f.operation}, ${f.kind}) не является ответом операции ${operation}`);
    }
    this.scenario.set(operation, name);
  }

  /** Вернуть сценарий операций к ответам по умолчанию. */
  reset(): void {
    this.scenario.clear();
    for (const [op, name] of Object.entries(DEFAULT_ONEC_SCENARIO)) this.useFixture(op as OnecOperationId, name);
    this.calls.length = 0;
  }

  async getHealth(opts?: OnecCallOptions): Promise<OnecResult<OnecHealth>> {
    const r = await this.respond<OnecHealth>('getHealth', [opts]);
    if (!this.exchange) return r;
    return {
      ...r,
      body: { ...r.body, lastAckMessageNumber: this.exchange.lastAck, registrationBacklog: this.exchange.backlog },
    };
  }

  getChanges(query: OnecChangesQuery, opts?: OnecCallOptions): Promise<OnecResult<OnecChangesPage>> {
    this.calls.push({ operation: 'getChanges', args: [query, opts] });
    if (this.exchange) {
      try {
        return Promise.resolve({ status: 200, body: this.exchange.getChanges(query) });
      } catch (e) {
        return Promise.reject(e instanceof Error ? e : new Error(String(e)));
      }
    }
    const firstName = this.scenario.get('getChanges') ?? 'changes.catalog.page1.200';
    const first = this.fixtures.get(firstName);
    const firstCursor = isObject(first?.body) ? first.body.cursor : undefined;
    if (query.cursor !== undefined && query.cursor === firstCursor) {
      return this.result<OnecChangesPage>('getChanges', 'changes.documents.page2.200');
    }
    return this.result<OnecChangesPage>('getChanges', firstName);
  }

  async ackChanges(messageNumber: number, opts?: OnecCallOptions): Promise<OnecResult<OnecChangesAck>> {
    if (this.exchange) {
      this.calls.push({ operation: 'ackChanges', args: [messageNumber, opts] });
      return { status: 200, body: this.exchange.ack(messageNumber) };
    }
    const r = await this.respond<OnecChangesAck>('ackChanges', [messageNumber, opts]);
    return r.status < 300 ? { ...r, body: { ...r.body, messageNumber } } : r;
  }

  reregisterChanges(opts?: OnecCallOptions): Promise<OnecResult<null>> {
    this.calls.push({ operation: 'reregisterChanges', args: [opts] });
    this.exchange?.registerAll();
    return Promise.resolve({ status: 202, body: null });
  }

  createOrder(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.respond('createOrder', [request, opts], { externalId: request.externalId });
  }

  getOrderStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.respond('getOrderStatus', [externalId, opts], { externalId });
  }

  getOrderStatusBatch(externalIds: readonly string[], opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.respond('getOrderStatusBatch', [externalIds, opts]);
  }

  cancelOrder(
    externalId: string,
    request: OnecJsonObject,
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecJsonObject>> {
    return this.respond('cancelOrder', [externalId, request, opts], { externalId });
  }

  createPayment(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.respond('createPayment', [request, opts]);
  }

  createQrPayment(request: OnecQrCreateRequest, opts?: OnecCallOptions): Promise<OnecResult<OnecQrCreateResponse>> {
    return this.respond<OnecQrCreateResponse>('createQrPayment', [request, opts], { externalId: request.externalId });
  }

  getQrPaymentStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecQrPaymentStatus>> {
    return this.respond<OnecQrPaymentStatus>('getQrPaymentStatus', [externalId, opts], { externalId });
  }

  cancelQrPayment(
    externalId: string,
    reason: OnecQrCancelReason,
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecQrCancelResponse>> {
    return this.respond<OnecQrCancelResponse>('cancelQrPayment', [externalId, reason, opts], { externalId });
  }

  findCustomersByPhone(phone: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject[]>> {
    const c = this.cashier;
    if (c) {
      return this.stateful('findCustomersByPhone', [phone, opts], () => ({ status: 200, body: c.findByPhone(phone) }));
    }
    return this.respond<OnecJsonObject[]>('findCustomersByPhone', [phone, opts]);
  }

  createCustomer(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    const c = this.cashier;
    if (c) return this.stateful('createCustomer', [request, opts], () => c.createCustomer(request));
    return this.respond('createCustomer', [request, opts], { externalId: request.externalId });
  }

  getCustomerReceivables(ref: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    const c = this.cashier;
    if (c) {
      return this.stateful('getCustomerReceivables', [ref, opts], () => ({ status: 200, body: c.getReceivables(ref) }));
    }
    return this.respond('getCustomerReceivables', [ref, opts], { customerRef: ref });
  }

  createReturnRequest(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    const c = this.cashier;
    if (c) return this.stateful('createReturnRequest', [request, opts], () => c.createReturnRequest(request));
    return this.respond('createReturnRequest', [request, opts]);
  }

  getReturnRequestStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    const c = this.cashier;
    if (c) {
      return this.stateful('getReturnRequestStatus', [externalId, opts], () => ({
        status: 200,
        body: c.getReturnRequestStatus(externalId),
      }));
    }
    return this.respond('getReturnRequestStatus', [externalId, opts]);
  }

  /** Операция режима кассира: журнал вызова, бизнес-отказ синтетики → `OnecError` (как фикстура с HTTP ≥ 400). */
  private stateful<T>(
    operation: OnecOperationId,
    args: readonly unknown[],
    run: () => { readonly status: number; readonly body: T },
  ): Promise<OnecResult<T>> {
    this.calls.push({ operation, args });
    try {
      const r = run();
      return Promise.resolve({ status: r.status, body: structuredClone(r.body) });
    } catch (e) {
      if (e instanceof SyntheticOnecRejection) {
        return Promise.reject(new OnecError(operation, e.status, e.code, e.message, e.details));
      }
      return Promise.reject(e instanceof Error ? e : new Error(String(e)));
    }
  }

  /** Двоичных фикстур нет: изображение отсутствует (`404 POS_E_NOT_FOUND`) — ветка «нет фото» (05 SYNC-072). */
  getImage(ref: string, ifNoneMatch?: string, opts?: OnecCallOptions): Promise<OnecResult<OnecImage | null>> {
    this.calls.push({ operation: 'getImage', args: [ref, ifNoneMatch, opts] });
    return Promise.reject(
      new OnecError(
        'getImage',
        404,
        'POS_E_NOT_FOUND',
        'Изображение не найдено (режим fixtures: двоичных фикстур нет)',
      ),
    );
  }

  checkCart(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.respond('checkCart', [request, opts]);
  }

  getCatalogCard(ref: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    if (this.catalog) {
      this.calls.push({ operation: 'getCatalogCard', args: [ref, opts] });
      const card = this.catalog.card(ref);
      if (card) return Promise.resolve({ status: 200, body: structuredClone(card) as OnecJsonObject });
      return this.result('getCatalogCard', 'catalog-card.404');
    }
    return this.respond('getCatalogCard', [ref, opts]);
  }

  listExternalIds(query: OnecExternalIdsQuery, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.respond('listExternalIds', [query, opts]);
  }

  private respond<T = OnecJsonObject>(
    operation: OnecOperationId,
    args: readonly unknown[],
    bind?: Record<string, OnecJson | undefined>,
  ): Promise<OnecResult<T>> {
    this.calls.push({ operation, args });
    const name = this.scenario.get(operation);
    if (name === undefined) {
      return Promise.reject(new OnecError(operation, 404, 'POS_E_NOT_FOUND', 'Для операции нет фикстуры'));
    }
    return this.result<T>(operation, name, bind);
  }

  private result<T>(
    operation: OnecOperationId,
    name: string,
    bind?: Record<string, OnecJson | undefined>,
  ): Promise<OnecResult<T>> {
    const f = this.fixture(name);
    const status = f.status ?? 200;
    const requestId = f.headers?.['X-Request-Id'];
    if (status >= 400) {
      const body = isObject(f.body) ? f.body : {};
      return Promise.reject(
        new OnecError(
          operation,
          status,
          typeof body.code === 'string' ? body.code : 'POS_E_INTERNAL',
          typeof body.message === 'string' ? body.message : 'ошибка 1С (фикстура)',
          body.details,
          typeof body.requestId === 'string' ? body.requestId : requestId,
        ),
      );
    }
    let body = f.body;
    if (bind && isObject(body)) {
      const bound: Record<string, OnecJson> = { ...body };
      for (const [k, v] of Object.entries(bind)) if (v !== undefined && k in bound) bound[k] = v;
      body = bound;
    }
    return Promise.resolve({ status, body: body as T, ...(requestId ? { requestId } : {}) });
  }
}

/** Товары каталога для строк реализаций кассира: первые `limit` цен базовой единицы первого вида цены генератора. */
export function catalogProducts(catalog: SyntheticCatalog, limit = 24): SyntheticProductRef[] {
  const names = new Map(catalog.productItems().map((p) => [p.ref, p.description]));
  const first = catalog.priceLists[0]?.ref;
  const out: SyntheticProductRef[] = [];
  const seen = new Set<string>();
  for (const r of catalog.priceSlice(first ? [first] : undefined)) {
    if (r.packagingRef !== null || seen.has(r.productRef) || !names.has(r.productRef)) continue;
    seen.add(r.productRef);
    out.push({
      productRef: r.productRef,
      variantRef: r.variantRef,
      name: names.get(r.productRef) ?? '',
      price: r.price,
    });
    if (out.length >= limit) break;
  }
  return out;
}

function isObject(v: unknown): v is { [key: string]: OnecJson } {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

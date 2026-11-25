import { createHash } from 'node:crypto';
import { OnecError } from './onec-error.js';
import type {
  OnecCallOptions,
  OnecChangesAck,
  OnecChangesPage,
  OnecChangesQuery,
  OnecExternalIdsQuery,
  OnecGateway,
  OnecHealth,
  OnecImage,
  OnecJson,
  OnecJsonObject,
  OnecOperationId,
  OnecQrCancelReason,
  OnecQrCancelResponse,
  OnecQrCreateRequest,
  OnecQrCreateResponse,
  OnecQrPaymentStatus,
  OnecResult,
} from './onec-gateway.js';
import {
  type OnecOsApiClient,
  type OsApiOrder,
  type OsApiOrderCreateBody,
  type OsApiOrderLine,
  osApiRef,
} from './onec-osapi.client.js';
import { osApiDate, osApiDerivedRef, osApiMoney } from './onec-osapi.mapping.js';

/** Текст отказа методов, которых в режиме `os_api` нет (ADR-126). */
export const OSAPI_UNSUPPORTED_MESSAGE =
  'метод недоступен в ONEC_MODE=os_api: через ОС_API только чтение каталога, цен, остатков и фото и запись заказа ' +
  'черновиком при ONEC_OSAPI_WRITE_ORDERS=true (ADR-126)';

/**
 * Код отказа `createOrder` без запроса записи в 1С: обязательное поле `POST /orders` нечем заполнить (нет клиента
 * 1С, склада, ссылки товара). Канал записи outbox паркует такой заказ «ждёт оформления в 1С» (`NO_WRITE_CHANNEL`) —
 * без повторов, `dead` и создания клиента в 1С.
 */
export const OSAPI_MANUAL_CODE = 'OSAPI_MANUAL';

/**
 * Через сколько канал записи повторно проверяет запаркованный `OSAPI_MANUAL` заказ (причину могли устранить:
 * задан `ONEC_OSAPI_DEFAULT_CUSTOMER`, склад привязан к 1С, товар появился в выгрузке). Попытки не тратятся.
 */
export const OSAPI_MANUAL_RECHECK_MS = 60 * 60_000;

/** Сколько держать выгрузки `/characteristics` и `/units` для обратного перевода производных ссылок. */
export const OSAPI_REVERSE_TTL_MS = 10 * 60_000;

/** Сообщение ОС_API «заказа нет» (`ЗаказПоИд`, Module.bsl): только оно — признак отсутствия документа. */
const OSAPI_ORDER_NOT_FOUND = 'Заказ не найден';

/**
 * 404 ОС_API именно «заказ не найден» (`{"error":{"code":"not_found","message":"Заказ не найден"}}`). Иной 404 —
 * «Метод не найден» (неверный `ONEC_OSAPI_PATH`, публикация пересоздана) или страница веб-сервера не в JSON —
 * недоступность 1С, а не отсутствие заказа.
 */
export function isOsApiOrderNotFound(e: unknown): boolean {
  if (!(e instanceof OnecError) || e.status !== 404) return false;
  const d = (e.details ?? {}) as Record<string, unknown>;
  // `OnecError.message` = «<операция>: <статус> <код> — <сообщение 1С>»: сравнивается только сообщение 1С.
  const prefix = `${e.operation}: ${e.status} ${e.code} — `;
  const text = e.message.startsWith(prefix) ? e.message.slice(prefix.length) : e.message;
  return d.osApiCode === 'not_found' && text.trim() === OSAPI_ORDER_NOT_FOUND;
}

/** Настройки записи заказов (решение владельца 25.11.2026). */
export interface OnecOsApiGatewayOptions {
  /** `ONEC_OSAPI_WRITE_ORDERS`: `true` — `createOrder` пишет заказ черновиком; иначе 501 без запроса. */
  readonly writeOrders?: boolean;
  /** `ONEC_OSAPI_DEFAULT_CUSTOMER`: контрагент 1С для заказа, клиент которого не найден в 1С. */
  readonly defaultCustomer?: string | null;
  /** `ONEC_OSAPI_WAREHOUSES`: единственный склад списка — склад заказа, если у склада POS нет ссылки 1С. */
  readonly warehouses?: readonly string[];
}

/** Сколько держать карту «файл → вид (item|characteristic)» из `/item-files`, прежде чем перечитать при промахе. */
export const OSAPI_FILE_KINDS_TTL_MS = 60_000;

/**
 * `apiVersion` для защиты версии (onec-api-compat.ts, ONEC-095): ОС_API отвечает `api: "v1"` (Module.bsl:114),
 * а проверка ждёт числовую мажорную часть. `v1` → `1`; иное значение передаётся как есть — несовместимая версия
 * ОС_API (`v2`) честно не пройдёт проверку.
 */
export function osApiVersion(api: unknown): string {
  const s = typeof api === 'string' ? api.trim() : '';
  const m = /^v?(\d+(?:\.\d+)*)$/i.exec(s);
  return m ? m[1] : s;
}

/**
 * `OnecOsApiGateway` — порт `OnecGateway` поверх существующего HTTP-сервиса 1С «ОС_API» (`ONEC_MODE=os_api`;
 * ADR-126, решение владельца 24.11.2026 «Да, с чтения»). Дополнительный режим: контракт `/pos/v1` не отменяется.
 *
 * - `getHealth` → `GET /ping`: `apiVersion` подставляется из `api` (`v1` → `1`), поля плана обмена — нули/пусто.
 * - `getImage` → `GET /item-files` (карта ссылка файла → вид) + `GET /files/{item|characteristic}/{id}`; ETag —
 *   свой, SHA-256 содержимого (`"<hex>"`); совпал с `If-None-Match` → `304` (тело не отдаётся).
 * - Лента изменений (`getChanges`/`ackChanges`/`reregisterChanges`) не поддерживается: каталог читает
 *   `OsApiCatalogSource` полной перечиткой по расписанию (как `odata_only`).
 * - `createOrder` (только при `ONEC_OSAPI_WRITE_ORDERS=true`, решение владельца 25.11.2026) → `POST /orders`
 *   ЧЕРНОВИКОМ: `post:false`, `reserve:false` зашиты (Module.bsl `СоздатьЗаказ`: `Провести = post <> Ложь`,
 *   `Резервировать = reserve <> Ложь`; при `post:false` документ только записывается, `ПроверитьЗаполнение` не
 *   вызывается, резерв в строках 0). `id` = UUID заказа POS — ключ идемпотентности (повтор → 200, `created:false`).
 *   Клиент — ссылка 1С клиента POS, иначе единственный покупатель `GET /customers?phone=`, иначе
 *   `ONEC_OSAPI_DEFAULT_CUSTOMER`; не определён (или нет склада/товара 1С) — `OnecError(OSAPI_MANUAL_CODE)` без
 *   записи: заказ ждёт ручного оформления. Клиент в 1С НЕ создаётся.
 * - `getOrderStatus`/`getOrderStatusBatch` → `GET /orders/{id}` (чтение): номер, дата, сумма, отгрузки/чеки;
 *   статус — по признаку `posted` (см. `osApiOrderDocument`).
 * - Прочие методы записи (отмена, оплата, QR, клиент, заявка на возврат) и прочие чтения вне каталога — отказ
 *   `OnecError(501)` БЕЗ запроса в 1С. Outbox в этом режиме их не захватывает (orders-worker.wiring: канал записи —
 *   только `order/create` при `ONEC_OSAPI_WRITE_ORDERS=true`, иначе не подключён).
 */
export class OnecOsApiGateway implements OnecGateway {
  readonly mode = 'os_api' as const;
  private fileKinds: { at: number; map: Map<string, 'item' | 'characteristic'> } | undefined;
  private readonly shared = new Map<
    'characteristic' | 'unit',
    { at: number; items: readonly { id: string; ownerId: string }[] }
  >();

  constructor(
    readonly client: OnecOsApiClient,
    private readonly now: () => Date = () => new Date(),
    private readonly options: OnecOsApiGatewayOptions = {},
  ) {}

  async getHealth(opts?: OnecCallOptions): Promise<OnecResult<OnecHealth>> {
    const p = await this.client.ping(opts);
    return {
      status: 200,
      body: {
        apiVersion: osApiVersion(p.api),
        extensionVersion: typeof p.extensionVersion === 'string' ? p.extensionVersion : '',
        platform: '',
        configuration: typeof p.configuration === 'string' ? p.configuration : '',
        configurationVersion: typeof p.configurationVersion === 'string' ? p.configurationVersion : '',
        serverTime: osApiDate(p.serverTime) ?? this.now().toISOString(),
        exchangeNode: '',
        registrationBacklog: 0,
        lastAckMessageNumber: 0,
        status: typeof p.status === 'string' ? p.status : 'ok',
        osApi: typeof p.api === 'string' ? p.api : null,
      },
    };
  }

  async getImage(ref: string, ifNoneMatch?: string, opts?: OnecCallOptions): Promise<OnecResult<OnecImage | null>> {
    const id = osApiRef(ref);
    if (!id) throw new OnecError('getImage', 0, 'POS_E_BAD_REQUEST', 'ссылка 1С — не UUID');
    const kind = await this.fileKind(id, opts);
    if (!kind) throw new OnecError('getImage', 404, 'POS_E_NOT_FOUND', 'файла нет в списке /item-files ОС_API');
    const file = await this.client.file(kind, id, opts);
    const etag = `"${createHash('sha256').update(file.data).digest('hex')}"`;
    if (ifNoneMatch !== undefined && sameEtag(ifNoneMatch, etag)) return { status: 304, body: null };
    return { status: 200, body: { contentType: file.contentType, etag, data: new Uint8Array(file.data) } };
  }

  /** Вид файла по карте `/item-files`; промах — перечитать список (не чаще `OSAPI_FILE_KINDS_TTL_MS`). */
  private async fileKind(id: string, opts?: OnecCallOptions): Promise<'item' | 'characteristic' | undefined> {
    const at = this.now().getTime();
    const known = this.fileKinds?.map.get(id);
    if (known) return known;
    if (this.fileKinds && at - this.fileKinds.at < OSAPI_FILE_KINDS_TTL_MS) return undefined;
    const list = await this.client.itemFiles(opts);
    const map = new Map<string, 'item' | 'characteristic'>();
    for (const f of list.items) {
      const r = osApiRef(f.id);
      if (r && (f.kind === 'item' || f.kind === 'characteristic')) map.set(r, f.kind);
    }
    this.fileKinds = { at, map };
    return map.get(id);
  }

  getChanges(_q: OnecChangesQuery, _o?: OnecCallOptions): Promise<OnecResult<OnecChangesPage>> {
    return unsupported('getChanges');
  }
  ackChanges(_n: number, _o?: OnecCallOptions): Promise<OnecResult<OnecChangesAck>> {
    return unsupported('ackChanges');
  }
  reregisterChanges(_o?: OnecCallOptions): Promise<OnecResult<null>> {
    return unsupported('reregisterChanges');
  }
  /**
   * Заказ POS → `POST /orders` черновиком (решение владельца 25.11.2026). Тело `request` — `OrderCreateRequest`
   * (onec-order-payload.ts) с `externalId`; `customer.phone` — телефон клиента POS, который канал записи добавляет
   * в момент доставки (только для поиска покупателя `GET /customers?phone=`, в 1С не пишется).
   */
  async createOrder(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    if (this.options.writeOrders !== true) return unsupported('createOrder');
    // Повтор (прошлая попытка — таймаут/сбой с неизвестным результатом): черновик мог быть уже создан. Сначала
    // `GET /orders/{id}`: есть — это и есть результат (тело заново не собирается, иначе изменившийся поиск клиента
    // или кеш запарковали бы заказ, а черновик в 1С остался бы сиротой); «Заказ не найден» — собрать и записать.
    if ((opts?.attempt ?? 1) > 1) {
      const id = osApiRef(request.externalId);
      if (id) {
        const existing = await this.client.order(id, opts).catch((e: unknown) => {
          if (isOsApiOrderNotFound(e)) return null;
          // Иной 404 («Метод не найден», страница веб-сервера) — публикация недоступна, а не ошибка данных заказа:
          // временная ошибка (повтор по графику outbox), а не `failed`.
          if (e instanceof OnecError && e.status === 404) {
            throw new OnecError(
              'createOrder',
              503,
              'POS_E_MAINTENANCE',
              'проверка заказа GET /orders/{id}: ОС_API ответил 404 не «Заказ не найден» — публикация недоступна',
              e.details,
              e.requestId,
            );
          }
          throw e;
        });
        if (existing) return { status: 200, body: osApiOrderDocument({ ...existing, created: false }) };
      }
    }
    const body = await this.orderBody(request, opts);
    const res = await this.client.createOrder(body, opts);
    return { status: res.status, body: osApiOrderDocument(res.body) };
  }

  async getOrderStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    if (!osApiRef(externalId)) throw new OnecError('getOrderStatus', 0, 'POS_E_BAD_REQUEST', 'id заказа — не UUID');
    return { status: 200, body: osApiOrderDocument(await this.client.order(externalId, opts)) };
  }

  /**
   * Пакет статусов — `GET /ping`, затем `GET /orders/{id}` по одному (пакетного метода в ОС_API нет). Сбой `/ping` —
   * ошибка (1С недоступна, заказы не трогаются). В `notFound` — только ответ «Заказ не найден» (`isOsApiOrderNotFound`);
   * иной 404 («Метод не найден», страница веб-сервера) — недоступность: на первом заказе — ошибка, далее — частичный
   * результат. Сбой после первого ответа (таймаут пакета, сеть) — частичный результат: непрочитанные заказы не
   * попадают ни в `items`, ни в `notFound` и проверяются следующим прогоном.
   */
  async getOrderStatusBatch(
    externalIds: readonly string[],
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecJsonObject>> {
    const items: OnecJsonObject[] = [];
    const notFound: string[] = [];
    if (externalIds.length === 0) return { status: 200, body: { items, notFound } };
    await this.client.ping(opts);
    for (const id of externalIds) {
      if (!osApiRef(id)) continue;
      try {
        items.push({ ...osApiOrderDocument(await this.client.order(id, opts)), externalId: id });
      } catch (e) {
        if (isOsApiOrderNotFound(e)) {
          notFound.push(id);
          continue;
        }
        if (items.length + notFound.length === 0) throw e;
        break;
      }
    }
    return { status: 200, body: { items, notFound } };
  }

  /** Тело `POST /orders` (Module.bsl `СоздатьЗаказ`) из `OrderCreateRequest` POS. */
  private async orderBody(r: OnecJsonObject, opts?: OnecCallOptions): Promise<OsApiOrderCreateBody> {
    const id = osApiRef(r.externalId);
    if (!id) throw new OnecError('createOrder', 0, 'POS_E_BAD_REQUEST', 'externalId заказа — не UUID');
    const warehouseId = osApiRef(r.warehouseRef) ?? single(this.options.warehouses);
    if (!warehouseId) {
      throw manual(
        'у склада заказа нет ссылки 1С, а ONEC_OSAPI_WAREHOUSES не задаёт единственный склад — склад заказа в 1С ' +
          'не определить',
      );
    }
    const customer = await this.orderCustomer(obj(r.customer), opts);
    const lines = await this.orderLines(Array.isArray(r.lines) ? r.lines : [], opts);
    const priceTypeId = osApiRef(r.priceListRef);
    const shipmentDate = osApiShipmentDate(obj(r.delivery));
    const comment = [typeof r.comment === 'string' ? r.comment : '', customer.note]
      .filter((x) => x !== '')
      .join(' · ')
      .slice(0, 1000);
    return {
      id,
      customerId: customer.id,
      warehouseId,
      ...(priceTypeId ? { priceTypeId } : {}),
      ...(shipmentDate ? { shipmentDate } : {}),
      ...(comment ? { comment } : {}),
      // Решение владельца 25.11.2026: в 1С — только черновик. Не настраивается.
      post: false,
      reserve: false,
      lines,
    };
  }

  /**
   * Контрагент 1С заказа: ссылка клиента POS (`contractorRef`, иначе `ref`) → единственный действующий покупатель
   * `GET /customers?phone=` → `ONEC_OSAPI_DEFAULT_CUSTOMER` → отказ `OSAPI_MANUAL_CODE` (клиент в 1С не создаётся).
   */
  private async orderCustomer(
    c: Record<string, unknown>,
    opts?: OnecCallOptions,
  ): Promise<{ id: string; note: string }> {
    const linked = osApiRef(c.contractorRef) ?? osApiRef(c.ref);
    if (linked) return { id: linked, note: '' };
    const phone = typeof c.phone === 'string' ? c.phone.replace(/\D/g, '') : '';
    if (phone.length >= 9) {
      const found = await this.client.customersByPhone(phone, opts).catch((e: unknown) => {
        // 400 — 1С не приняла номер (меньше 9 цифр и т. п.): совпадения нет; прочие ошибки — как обычно.
        if (e instanceof OnecError && e.status === 400) return { items: [] };
        throw e;
      });
      const ids = [...new Set(found.items.filter((x) => x.inactive !== true).map((x) => osApiRef(x.id)))].filter(
        (x): x is string => x !== null,
      );
      if (ids.length === 1) return { id: ids[0], note: '' };
    }
    const fallback = osApiRef(this.options.defaultCustomer);
    if (fallback) return { id: fallback, note: 'клиент POS без карточки в 1С' };
    throw manual(
      'клиент заказа не связан с 1С, по телефону однозначно не найден, ONEC_OSAPI_DEFAULT_CUSTOMER не задан — ' +
        'клиента в 1С не создаём, заказ ждёт оформления в 1С',
    );
  }

  /** Строки `POST /orders`: товар, характеристика и упаковка 1С; количество и цена — в единице строки. */
  private async orderLines(lines: readonly OnecJson[], opts?: OnecCallOptions): Promise<OsApiOrderLine[]> {
    if (lines.length === 0) throw manual('в заказе нет строк');
    const out: OsApiOrderLine[] = [];
    for (const [i, raw] of lines.entries()) {
      const l = obj(raw);
      const n = `строка ${i + 1}`;
      const itemId = osApiRef(l.productRef);
      if (!itemId) throw manual(`${n}: у товара нет ссылки 1С`);
      const characteristicId = await this.sharedRef('characteristic', l.variantRef, itemId, opts);
      const unitId = await this.sharedRef('unit', l.packagingRef, itemId, opts);
      if (characteristicId === undefined) throw manual(`${n}: характеристика не найдена в /characteristics 1С`);
      if (unitId === undefined) throw manual(`${n}: упаковка не найдена в /units 1С`);
      // Упаковка POS без ссылки 1С: количество в упаковках нечем передать (цена — за упаковку) — не угадываем.
      if (unitId === null && l.packQuantity !== null && l.packQuantity !== undefined) {
        throw manual(`${n}: у упаковки нет ссылки 1С`);
      }
      const quantity = num(unitId ? l.packQuantity : l.quantity);
      const price = num(l.price);
      const amount = num(l.amount);
      if (quantity === null || quantity <= 0 || price === null || price < 0) {
        throw manual(`${n}: количество или цена не число`);
      }
      out.push({
        itemId,
        characteristicId,
        unitId,
        quantity,
        ...osApiLinePricing(price, quantity, amount),
      });
    }
    return out;
  }

  /**
   * Ссылка 1С характеристики/упаковки строки. Производная ссылка POS (UUID v5, элемент КАТЕГОРИИ × товар —
   * `osApiDerivedRef`) переводится обратно в ссылку элемента категории: товар строки известен (`itemId`), поэтому
   * достаточно выгрузки `/characteristics` или `/units` (элементы с `ownerType = category`) — `/items` не нужен.
   * Прочие — как есть (ссылки 1С не бывают v5). `null` — нет (служебный вариант / базовая единица); `undefined` —
   * производную не перевести (после перечитки выгрузки).
   */
  private async sharedRef(
    kind: 'characteristic' | 'unit',
    value: unknown,
    itemId: string,
    opts?: OnecCallOptions,
  ): Promise<string | null | undefined> {
    const ref = osApiRef(value);
    if (!ref) return null;
    if (ref[14] !== '5') return ref;
    const find = (items: readonly { id: string; ownerId: string }[]): string | undefined =>
      items.find((x) => osApiDerivedRef(kind, x.id, itemId) === ref)?.id;
    const cached = this.shared.get(kind);
    if (cached && this.now().getTime() - cached.at < OSAPI_REVERSE_TTL_MS) {
      const hit = find(cached.items);
      if (hit) return hit;
    }
    // Нет кеша, устарел или промах (элемент/товар заведён после выгрузки) — перечитать один раз.
    return find(await this.loadShared(kind, opts));
  }

  /**
   * Элементы категорий `/characteristics` или `/units`. Полная выгрузка — со своим таймаутом клиента
   * (`fullLoadTimeoutMs`), а не под сигналом доставки outbox (`ONEC_TIMEOUT_MS`): иначе большой справочник
   * обрывался бы на каждой попытке.
   */
  private async loadShared(
    kind: 'characteristic' | 'unit',
    opts?: OnecCallOptions,
  ): Promise<readonly { id: string; ownerId: string }[]> {
    const own: OnecCallOptions = opts?.requestId ? { requestId: opts.requestId } : {};
    const list = kind === 'characteristic' ? await this.client.characteristics(own) : await this.client.units(own);
    const items: { id: string; ownerId: string }[] = [];
    for (const x of list.items) {
      const id = osApiRef(x.id);
      const ownerId = osApiRef(x.ownerId);
      if (id && ownerId && x.ownerType === 'category') items.push({ id, ownerId });
    }
    this.shared.set(kind, { at: this.now().getTime(), items });
    return items;
  }
  cancelOrder(_id: string, _r: OnecJsonObject, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('cancelOrder');
  }
  createPayment(_r: OnecJsonObject, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('createPayment');
  }
  createQrPayment(_r: OnecQrCreateRequest, _o?: OnecCallOptions): Promise<OnecResult<OnecQrCreateResponse>> {
    return unsupported('createQrPayment');
  }
  getQrPaymentStatus(_id: string, _o?: OnecCallOptions): Promise<OnecResult<OnecQrPaymentStatus>> {
    return unsupported('getQrPaymentStatus');
  }
  cancelQrPayment(
    _id: string,
    _r: OnecQrCancelReason,
    _o?: OnecCallOptions,
  ): Promise<OnecResult<OnecQrCancelResponse>> {
    return unsupported('cancelQrPayment');
  }
  findCustomersByPhone(_p: string, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject[]>> {
    return unsupported('findCustomersByPhone');
  }
  createCustomer(_r: OnecJsonObject, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('createCustomer');
  }
  getCustomerReceivables(_ref: string, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('getCustomerReceivables');
  }
  createReturnRequest(_r: OnecJsonObject, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('createReturnRequest');
  }
  getReturnRequestStatus(_id: string, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('getReturnRequestStatus');
  }
  checkCart(_r: OnecJsonObject, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('checkCart');
  }
  getCatalogCard(_ref: string, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('getCatalogCard');
  }
  listExternalIds(_q: OnecExternalIdsQuery, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('listExternalIds');
  }
}

function sameEtag(a: string, b: string): boolean {
  const norm = (s: string): string => s.trim().replace(/^W\//, '').replace(/"/g, '').toLowerCase();
  return a.split(',').some((x) => norm(x) === norm(b));
}

/**
 * Заказ ОС_API (`GET /orders/{id}`, ответ `POST /orders`) → документ заказа порта (`parseOnecOrderDocument`):
 * `ref` = `id`, дата `+06:00`, сумма строкой, отгрузки — расходные накладные и чеки ККМ (проведённые = отгрузка).
 * Статуса «Заказ клиента» в ОС_API нет; по признаку проведения: черновик (`posted=false`) — «Не согласован»,
 * проведён — «Согласован» (к выполнению). «Закрыт» не выводится никогда: завершение заказа в 1С без расходной
 * накладной (например, только чек ККМ) не должно стать отменой в POS (05 §5.1b P2). Пометки удаления в ответе нет.
 */
export function osApiOrderDocument(o: OsApiOrder): OnecJsonObject {
  const docs = [...(o.shipments ?? []), ...(o.receipts ?? [])];
  const total = osApiMoney(o.total);
  return {
    ref: osApiRef(o.id),
    number: typeof o.number === 'string' && o.number.trim() !== '' ? o.number.trim() : null,
    date: osApiDate(o.date),
    status: o.posted === true ? 'Согласован' : 'Не согласован',
    deletionMark: false,
    total: total === '' ? null : total,
    shipments: docs.map((d) => ({ ref: osApiRef(d.id), posted: d.posted === true })),
    osApi: {
      created: typeof o.created === 'boolean' ? o.created : null,
      posted: o.posted === true,
      stateName: typeof o.stateName === 'string' ? o.stateName : null,
      customerId: osApiRef(o.customerId),
      warehouseId: osApiRef(o.warehouseId),
    },
  };
}

function obj(v: unknown): Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

function single(list: readonly string[] | undefined): string | null {
  const refs = [...new Set((list ?? []).map((x) => osApiRef(x)).filter((x): x is string => x !== null))];
  return refs.length === 1 ? refs[0] : null;
}

function num(v: unknown): number | null {
  const n = typeof v === 'number' ? v : typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v.trim()) ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
}

/** Округление до копеек (тыйынов) как у денежных сумм 1С. */
function round2(x: number): number {
  return Math.round((x + Number.EPSILON) * 100) / 100;
}

/**
 * Сумма строки так, как её посчитает 1С по цене, количеству и проценту (`РассчитатьСуммыВСтрокеТЧ`, Module.bsl):
 * сумма = цена × количество, скидка = сумма × % / 100 (до копеек), итог = сумма − скидка. Модель — только для выбора
 * представления; фактическую сумму 1С возвращает в ответе, и расхождение итога проецируется как обычно.
 */
function onecLineAmount(price: number, quantity: number, pct: number): number {
  const gross = round2(price * quantity);
  return round2(gross - round2((gross * pct) / 100));
}

/**
 * Цена и процент скидки строки `POST /orders`. ОС_API принимает только `discountPercent` (поле
 * `ПроцентСкидкиНаценки`, 2 знака) и считает сумму сама, поэтому ступенчатая скидка (клиента и ручная) или
 * копеечная коррекция последней строки процентом с 2 знаками точно не выражается. Порядок:
 * 1) процент с 2 знаками (и соседние ±0,01), дающий ровно сумму POS;
 * 2) иначе — цена со скидкой (`сумма / количество`, 2 знака) без процента, если она даёт ровно сумму POS;
 * 3) иначе — ближайший процент (расхождение — доли тыйына на единицу, 1С вернёт свою сумму).
 */
export function osApiLinePricing(
  price: number,
  quantity: number,
  amount: number | null,
): { price: number; discountPercent: number } {
  const gross = round2(price * quantity);
  if (amount === null || gross <= 0 || amount >= gross) return { price, discountPercent: 0 };
  const base = Math.min(100, Math.max(0, Math.round((1 - amount / gross) * 10000) / 100));
  const target = round2(amount);
  for (const p of [base, round2(base - 0.01), round2(base + 0.01)]) {
    if (p >= 0 && p <= 100 && onecLineAmount(price, quantity, p) === target) return { price, discountPercent: p };
  }
  const net = round2(amount / quantity);
  if (round2(net * quantity) === target) return { price: net, discountPercent: 0 };
  return { price, discountPercent: base };
}

const BISHKEK_OFFSET_MS = 6 * 3_600_000;

/**
 * Дата и время → местное время Бишкека без зоны (`XMLЗначение(Дата)` 1С): `+06:00` и без зоны — как есть; другая
 * зона (`Z`, `+05:00`…) — пересчёт в +06:00 (в Бишкеке нет перехода на летнее время).
 */
export function osApiLocalDateTime(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const m = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})?$/.exec(v.trim());
  if (!m) return null;
  if (m[2] === undefined || m[2] === '+06:00') return m[1];
  const t = Date.parse(v.trim());
  if (Number.isNaN(t)) return null;
  return new Date(t + BISHKEK_OFFSET_MS).toISOString().slice(0, 19);
}

/**
 * `shipmentDate` заказа: начало желаемого интервала доставки; без начала — конец; без времени — дата доставки
 * (`delivery.desiredDate`, канал записи добавляет её из заказа) с 00:00. Ничего нет — поле не передаётся (1С
 * ставит дату заказа).
 */
export function osApiShipmentDate(d: Record<string, unknown>): string | null {
  const withTime = osApiLocalDateTime(d.desiredFrom) ?? osApiLocalDateTime(d.desiredTo);
  if (withTime) return withTime;
  const date = typeof d.desiredDate === 'string' ? d.desiredDate.trim() : '';
  return /^\d{4}-\d{2}-\d{2}$/.test(date) ? `${date}T00:00:00` : null;
}

function manual(message: string): OnecError {
  return new OnecError('createOrder', 409, OSAPI_MANUAL_CODE, message);
}

function unsupported<T>(op: OnecOperationId): Promise<T> {
  return Promise.reject(new OnecError(op, 501, 'POS_E_NOT_FOUND', OSAPI_UNSUPPORTED_MESSAGE));
}

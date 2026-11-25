import { newId } from '../../common/ids/uuid.js';
import { OnecError, type OnecErrorOperation } from './onec-error.js';
import type { OnecCallOptions } from './onec-gateway.js';
import { type OnecHttpResponse, type OnecHttpTransport, OnecTransportError } from './onec-http-transport.js';

/**
 * Клиент существующего HTTP-сервиса 1С «ОС_API» (расширение шлюза, корень `/hs/os/api/v1`; ADR-126) — ТОЛЬКО
 * ЧТЕНИЕ: метода записи в клиенте нет вовсе (`POST` не отправляется никогда). Решение владельца 24.11.2026:
 * интеграция на стенде начинается с чтения каталога, цен, остатков, проверки связи и фото; запись в 1С через
 * ОС_API — отдельным согласием.
 *
 * Форма ответов — по исходнику расширения 0.2.9 (`HTTPServices/ОС_API/Ext/Module.bsl`): поля ниже ровно те, что
 * отдаёт модуль, лишних не выдумываем. Ссылки — голые UUID (`Ид()`: пустая ссылка → `null`), деньги и количества —
 * JSON-числа, даты — ISO без зоны (`ВариантЗаписиДатыJSON.ЛокальнаяДата`, Module.bsl:2852-2853).
 *
 * Вход — Basic пользователя публикации (`ONEC_USER_FILE`/`ONEC_PASSWORD_FILE`); заголовка `X-POS-Client-Key` у
 * ОС_API нет. Ошибка — `OnecError` (не-2xx → код `POS_E_*` по HTTP-статусу, текст из `{error:{message}}`), сбой
 * транспорта — `OnecError(status=0, 'TRANSPORT')`. Повтор — только временных ошибок (как у `OnecExtensionGateway`).
 *
 * Полные выгрузки (`/items`, `/characteristics`, `/units`, `/barcodes`, `/prices`, `/stock`, `/item-files`,
 * справочники) идут без страниц, поэтому у них свой таймаут — 120 с, как у шлюза на том же API
 * (`ONEC_API_TIMEOUT_SEC || 120`); истёкший таймаут полной выгрузки повторяется не больше одного раза (тяжёлый
 * запрос не гоняется по 1С трижды). `ONEC_TIMEOUT_MS` — только у лёгкой проверки связи `/ping`.
 */

// ---------- ответы ОС_API (Module.bsl 0.2.9) ----------

/** `GET /ping` (Module.bsl:110-121). */
export interface OsApiPing {
  readonly status?: string;
  /** `"v1"` — не номер версии контракта POS. */
  readonly api?: string;
  readonly extensionVersion?: string;
  readonly configuration?: string;
  readonly configurationVersion?: string;
  readonly serverTime?: string;
}

/** `GET /price-types` (Module.bsl:124-147), включая помеченные на удаление. */
export interface OsApiPriceType {
  readonly id: string | null;
  readonly name: string;
  readonly deleted: boolean;
}

/** `GET /warehouses` (Module.bsl:151-184): `Справочник.СтруктурныеЕдиницы` без помеченных на удаление. */
export interface OsApiWarehouse {
  readonly id: string | null;
  readonly name: string;
  readonly parentId?: string | null;
  readonly type?: string | null;
  readonly retailPriceTypeId?: string | null;
  readonly inactive?: boolean;
}

/** `GET /items` (Module.bsl:186-249): номенклатура и группы (`isGroup`); у групп только первые шесть полей. */
export interface OsApiItem {
  readonly id: string | null;
  readonly isGroup: boolean;
  readonly parentId?: string | null;
  readonly code?: string | null;
  readonly name: string;
  readonly deleted: boolean;
  readonly fullName?: string | null;
  readonly sku?: string | null;
  readonly type?: string | null;
  readonly categoryId?: string | null;
  readonly categoryName?: string | null;
  readonly baseUnitId?: string | null;
  readonly baseUnitName?: string | null;
  readonly hasCharacteristics?: boolean;
  readonly weighted?: boolean;
  readonly inactive?: boolean;
  readonly hasPicture?: boolean;
  readonly changedAt?: string | null;
}

/** Владелец характеристики/упаковки (`ТипВладельца`, Module.bsl:2737-2748). */
export type OsApiOwnerType = 'item' | 'category' | 'unitSet' | 'other';

/** `GET /characteristics` (Module.bsl:251-280). */
export interface OsApiCharacteristic {
  readonly id: string | null;
  readonly ownerId: string | null;
  /** `OsApiOwnerType`; иное значение (новая версия ОС_API) — владелец не представим и пропускается. */
  readonly ownerType: string;
  readonly name: string;
  readonly sku?: string | null;
  readonly inactive?: boolean;
  readonly deleted: boolean;
}

/** `GET /units` (Module.bsl:282-309): упаковки `Справочник.ЕдиницыИзмерения` с коэффициентом к базовой единице. */
export interface OsApiUnit {
  readonly id: string | null;
  readonly ownerId: string | null;
  /** `OsApiOwnerType`; иное значение (новая версия ОС_API) — владелец не представим и пропускается. */
  readonly ownerType: string;
  readonly name: string;
  readonly ratio: number | string;
  readonly deleted: boolean;
}

/** `GET /barcodes` (Module.bsl:311-338). `unitId` — упаковка или базовая единица классификатора. */
export interface OsApiBarcode {
  readonly barcode: string;
  readonly itemId: string | null;
  readonly characteristicId: string | null;
  readonly unitId: string | null;
}

/** Строка `GET /prices?priceType=` (Module.bsl:342-379). */
export interface OsApiPrice {
  readonly itemId: string | null;
  readonly characteristicId: string | null;
  readonly price: number | string;
  readonly unitId: string | null;
  /** `base` — базовая единица классификатора, `package` — упаковка (`ВидЕдиницы`, Module.bsl:2751-2758). */
  readonly unitKind: string;
  readonly since?: string | null;
}

export interface OsApiPriceList {
  readonly priceTypeId: string | null;
  readonly items: readonly OsApiPrice[];
}

/** Строка `GET /stock[?warehouse=]` (Module.bsl:381-453), количества в базовых единицах. */
export interface OsApiStock {
  readonly warehouseId: string | null;
  readonly itemId: string | null;
  readonly characteristicId: string | null;
  readonly quantity: number | string;
  readonly reserved?: number | string;
  /** `Макс(quantity − reserved, 0)` (Module.bsl:446). */
  readonly free?: number | string;
}

/** `GET /item-files` (Module.bsl:1023-1099): фото товаров и характеристик без помеченных на удаление. */
export interface OsApiItemFile {
  readonly id: string | null;
  /** `item` | `characteristic`. */
  readonly kind: string;
  readonly itemId: string | null;
  readonly characteristicId: string | null;
  readonly contentType?: string;
  readonly size?: number;
  readonly isMain?: boolean;
  /** `ДатаМодификацииУниверсальная` (UTC без зоны). */
  readonly changedAt?: string | null;
}

export interface OsApiList<T> {
  readonly items: readonly T[];
}

export interface OsApiBinary {
  readonly data: Buffer;
  readonly contentType: string;
}

// ---------- клиент ----------

/** Путь сервиса по умолчанию — `ONEC_OSAPI_PATH` (корень публикации + `hs/os/api/v1`). */
export const ONEC_OSAPI_DEFAULT_PATH = 'hs/os/api/v1';

export interface OnecOsApiConfig {
  /** `ONEC_BASE_URL` — корень публикации, например `http://localhost/uk_main_fr`. */
  readonly baseUrl: string;
  /** `ONEC_OSAPI_PATH` (по умолчанию `hs/os/api/v1`). */
  readonly servicePath?: string;
  readonly user: string;
  readonly password?: string;
  /** `ONEC_TIMEOUT_MS` — лёгкие вызовы (`/ping`). */
  readonly timeoutMs?: number;
  /** Полные выгрузки без страниц (по умолчанию 120 с, как у шлюза). */
  readonly fullLoadTimeoutMs?: number;
  /** Фото (05 SYNC-030: 120 с). */
  readonly imagesTimeoutMs?: number;
  readonly retry?: { readonly maxAttempts: number; readonly baseDelayMs: number };
}

export const ONEC_OSAPI_DEFAULTS = {
  timeoutMs: 30_000,
  fullLoadTimeoutMs: 120_000,
  imagesTimeoutMs: 120_000,
  retry: { maxAttempts: 3, baseDelayMs: 500 },
} as const;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** UUID ОС_API → ссылка модели (нижний регистр); пусто/не UUID → `null`. */
export function osApiRef(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const v = value.trim().toLowerCase();
  return UUID_RE.test(v) ? v : null;
}

const STATUS_CODE: Readonly<Record<number, string>> = {
  400: 'POS_E_BAD_REQUEST',
  401: 'POS_E_UNAUTHORIZED',
  403: 'POS_E_FORBIDDEN',
  404: 'POS_E_NOT_FOUND',
  409: 'POS_E_STATE',
  422: 'POS_E_VALIDATION',
  423: 'POS_E_LOCKED',
  500: 'POS_E_INTERNAL',
  503: 'POS_E_MAINTENANCE',
};

export class OnecOsApiClient {
  private readonly root: string;
  private readonly authHeader: string;
  private readonly timeoutMs: number;
  private readonly fullLoadTimeoutMs: number;
  private readonly imagesTimeoutMs: number;
  private readonly retry: { readonly maxAttempts: number; readonly baseDelayMs: number };

  constructor(
    config: OnecOsApiConfig,
    private readonly transport: OnecHttpTransport,
    private readonly sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
  ) {
    const base = config.baseUrl.replace(/\/+$/, '');
    const path = (config.servicePath ?? ONEC_OSAPI_DEFAULT_PATH).replace(/^\/+|\/+$/g, '');
    this.root = path ? `${base}/${path}` : base;
    this.authHeader = `Basic ${Buffer.from(`${config.user}:${config.password ?? ''}`, 'utf8').toString('base64')}`;
    this.timeoutMs = config.timeoutMs ?? ONEC_OSAPI_DEFAULTS.timeoutMs;
    this.fullLoadTimeoutMs = config.fullLoadTimeoutMs ?? ONEC_OSAPI_DEFAULTS.fullLoadTimeoutMs;
    this.imagesTimeoutMs = config.imagesTimeoutMs ?? ONEC_OSAPI_DEFAULTS.imagesTimeoutMs;
    this.retry = config.retry ?? ONEC_OSAPI_DEFAULTS.retry;
  }

  /** Корень сервиса (для журнала, без учётных данных). */
  get serviceRoot(): string {
    return this.root;
  }

  ping(opts?: OnecCallOptions): Promise<OsApiPing> {
    return this.json('getHealth', '/ping', undefined, opts, 'light');
  }
  priceTypes(opts?: OnecCallOptions): Promise<OsApiList<OsApiPriceType>> {
    return this.list('osapi:/price-types', '/price-types', undefined, opts);
  }
  warehouses(opts?: OnecCallOptions): Promise<OsApiList<OsApiWarehouse>> {
    return this.list('osapi:/warehouses', '/warehouses', undefined, opts);
  }
  items(opts?: OnecCallOptions): Promise<OsApiList<OsApiItem>> {
    return this.list('osapi:/items', '/items', undefined, opts);
  }
  characteristics(opts?: OnecCallOptions): Promise<OsApiList<OsApiCharacteristic>> {
    return this.list('osapi:/characteristics', '/characteristics', undefined, opts);
  }
  units(opts?: OnecCallOptions): Promise<OsApiList<OsApiUnit>> {
    return this.list('osapi:/units', '/units', undefined, opts);
  }
  barcodes(opts?: OnecCallOptions): Promise<OsApiList<OsApiBarcode>> {
    return this.list('osapi:/barcodes', '/barcodes', undefined, opts);
  }
  /** Действующие цены одного вида цен (срез последних, `Актуальность`). */
  async prices(priceTypeRef: string, opts?: OnecCallOptions): Promise<OsApiPriceList> {
    const id = this.uuidParam('osapi:/prices', priceTypeRef);
    const body = await this.json<OsApiPriceList>('osapi:/prices', '/prices', { priceType: id }, opts, 'full');
    if (!Array.isArray(body.items)) throw invalid('osapi:/prices', 'нет массива items');
    return body;
  }
  /** Остатки одного склада или всех (`warehouse` не задан). */
  stock(warehouseRef?: string, opts?: OnecCallOptions): Promise<OsApiList<OsApiStock>> {
    const q = warehouseRef ? { warehouse: this.uuidParam('osapi:/stock', warehouseRef) } : undefined;
    return this.list('osapi:/stock', '/stock', q, opts);
  }
  itemFiles(opts?: OnecCallOptions): Promise<OsApiList<OsApiItemFile>> {
    return this.list('getImage', '/item-files', undefined, opts);
  }

  /** Двоичные данные фото `GET /files/{item|characteristic}/{id}`. */
  async file(kind: 'item' | 'characteristic', fileRef: string, opts?: OnecCallOptions): Promise<OsApiBinary> {
    const id = this.uuidParam('getImage', fileRef);
    const res = await this.get('getImage', `/files/${kind}/${id}`, undefined, this.imagesTimeoutMs, opts, false);
    const contentType = (res.headers['content-type'] ?? 'application/octet-stream').split(';')[0].trim();
    return { data: res.body, contentType };
  }

  private async list<T>(
    op: OnecErrorOperation,
    path: string,
    query: Readonly<Record<string, string>> | undefined,
    opts?: OnecCallOptions,
  ): Promise<OsApiList<T>> {
    const body = await this.json<OsApiList<T>>(op, path, query, opts, 'full');
    if (!Array.isArray(body.items)) throw invalid(op, 'нет массива items');
    return body;
  }

  private async json<T>(
    op: OnecErrorOperation,
    path: string,
    query: Readonly<Record<string, string>> | undefined,
    opts: OnecCallOptions | undefined,
    weight: 'light' | 'full',
  ): Promise<T> {
    const full = weight === 'full';
    const res = await this.get(op, path, query, full ? this.fullLoadTimeoutMs : this.timeoutMs, opts, full);
    let body: unknown;
    try {
      body = JSON.parse(stripBom(res.body.toString('utf8')));
    } catch {
      throw invalid(op, 'ответ 1С — не JSON');
    }
    if (typeof body !== 'object' || body === null || Array.isArray(body)) throw invalid(op, 'ответ 1С — не объект');
    return body as T;
  }

  /**
   * Только `GET`: ОС_API в этом режиме не пишет в 1С (ADR-126). `fullLoad` — полная выгрузка: истёкший таймаут
   * повторяется не больше одного раза.
   */
  private async get(
    op: OnecErrorOperation,
    path: string,
    query: Readonly<Record<string, string>> | undefined,
    timeoutMs: number,
    opts: OnecCallOptions | undefined,
    fullLoad: boolean,
  ): Promise<OnecHttpResponse> {
    const requestId = opts?.requestId ?? newId();
    const qs = Object.entries(query ?? {})
      .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
      .join('&');
    const url = `${this.root}${path}${qs ? `?${qs}` : ''}`;
    const headers = {
      Accept: op === 'getImage' && path.startsWith('/files/') ? 'image/*, application/json' : 'application/json',
      Authorization: this.authHeader,
      'X-Request-Id': requestId,
    };
    const maxAttempts = Math.max(1, this.retry.maxAttempts);
    let timeouts = 0;
    for (let attempt = 1; ; attempt++) {
      try {
        const res = await this.transport
          .request({
            method: 'GET',
            url,
            headers,
            timeoutMs,
            ...(opts?.signal ? { signal: opts.signal } : {}),
          })
          .catch((e: unknown) => {
            if (e instanceof OnecTransportError && e.kind === 'timeout') timeouts++;
            throw e instanceof OnecTransportError
              ? new OnecError(op, 0, 'TRANSPORT', e.message, undefined, requestId)
              : e;
          });
        if (res.status >= 200 && res.status < 300) return res;
        throw toOnecError(op, res, requestId);
      } catch (e) {
        const retry =
          attempt < maxAttempts &&
          e instanceof OnecError &&
          e.retryable &&
          !opts?.signal?.aborted &&
          !(fullLoad && timeouts >= 2);
        if (!retry) throw e;
        await this.sleep(this.retry.baseDelayMs * 2 ** (attempt - 1));
      }
    }
  }

  private uuidParam(op: OnecErrorOperation, value: string): string {
    const v = osApiRef(value);
    if (!v) throw new OnecError(op, 0, 'POS_E_BAD_REQUEST', 'ссылка 1С — не UUID');
    return v;
  }
}

/** Ответ без BOM (ОС_API пишет без BOM, Module.bsl:2858, но веб-сервер/прокси мог добавить). */
function stripBom(s: string): string {
  return s.charCodeAt(0) === 0xfeff ? s.slice(1) : s;
}

function invalid(op: OnecErrorOperation, message: string): OnecError {
  return new OnecError(op, 200, 'INVALID_RESPONSE', message);
}

/** Ошибка ОС_API — `{"error":{"code","message"}}` (Module.bsl:2863-2868); код — по HTTP-статусу. */
function toOnecError(op: OnecErrorOperation, res: OnecHttpResponse, requestId: string): OnecError {
  let message = `HTTP ${res.status}`;
  let details: unknown;
  try {
    const parsed = JSON.parse(stripBom(res.body.toString('utf8'))) as unknown;
    const err = (parsed as { error?: { code?: unknown; message?: unknown } } | null)?.error;
    if (err && typeof err.message === 'string') message = err.message.slice(0, 300);
    if (err && typeof err.code === 'string') details = { osApiCode: err.code };
  } catch {
    // тело не JSON (страница веб-сервера) — только статус
  }
  const code = STATUS_CODE[res.status] ?? (res.status >= 500 ? 'POS_E_INTERNAL' : 'POS_E_BAD_REQUEST');
  return new OnecError(op, res.status, code, message, details, res.headers['x-request-id'] ?? requestId);
}

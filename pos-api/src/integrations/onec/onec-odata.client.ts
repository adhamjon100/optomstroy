import { newId } from '../../common/ids/uuid.js';
import { type OnecHttpTransport, OnecTransportError } from './onec-http-transport.js';
import {
  ODATA_ALLOWLIST,
  ODATA_DEFAULT_PAGE_SIZE,
  ODATA_DENIED,
  ODATA_MAX_TOP,
  type ODataAllowedCollection,
  type ODataOperation,
} from './odata-allowlist.js';

/**
 * Настройки клиента стандартного OData 1С (фаза 0, 05 §4; 16 §4.3): `ONEC_BASE_URL`, `ONEC_ODATA_PATH`
 * (по умолчанию `odata/standard.odata`), секреты `ONEC_USER_FILE`/`ONEC_PASSWORD_FILE` (пользователь
 * `pos_integration`, только чтение — ONEC-052), `ONEC_TIMEOUT_MS`, `ONEC_SYNC_PAGE_SIZE`.
 */
export interface OnecODataConfig {
  readonly baseUrl: string;
  readonly odataPath: string;
  readonly user?: string;
  readonly password?: string;
  /** Прочие запросы (`$count`) — `ONEC_TIMEOUT_MS` (по умолчанию 30 с). */
  readonly timeoutMs?: number;
  /** Чтение страницы коллекции (`list`/`pages`, срезы) — 05 SYNC-030: 60 с. */
  readonly pageTimeoutMs?: number;
  readonly pageSize?: number;
}

/** Таймаут чтения страницы OData (05 SYNC-030: «чтение страницы 60 с»), как `changesTimeoutMs` HS-клиента. */
export const ODATA_PAGE_TIMEOUT_MS = 60_000;

/** Обращение вне allow-list (ONEC-083): коллекция, операция или поле не разрешены — запрос не отправляется. */
export class ODataAllowlistError extends Error {
  override readonly name = 'ODataAllowlistError';
  readonly code = 'ODATA_NOT_ALLOWED';

  constructor(
    readonly collection: string,
    reason: string,
  ) {
    super(`OData allow-list: ${collection} — ${reason}`);
  }
}

/** Ошибка ответа OData (не-2xx) или транспорта (`status = 0`). */
export class OnecODataError extends Error {
  override readonly name = 'OnecODataError';

  constructor(
    readonly collection: string,
    readonly status: number,
    readonly code: string,
    message: string,
    readonly requestId?: string,
  ) {
    super(`OData ${collection}: ${status} ${code} — ${message}`);
  }

  /** Временная ошибка (таймаут, сеть, 5xx, 423) — повтор по графику прогона (05 SYNC-029). */
  get retryable(): boolean {
    return this.status === 0 || this.status >= 500 || this.status === 423;
  }

  /** Коллекция отсутствует в публикации (404 «Entity not found») — для `conditional` объектов шаг пропускается. */
  get notFound(): boolean {
    return this.status === 404;
  }
}

export interface ODataQuery {
  /** Обязателен: только поля allow-list коллекции. */
  readonly select: readonly string[];
  readonly filter?: string;
  readonly top?: number;
  readonly skip?: number;
  /** Виртуальная таблица регистра: `Balance(...)` / `SliceLast(...)` — только если операция разрешена. */
  readonly virtual?: { readonly op: Exclude<ODataOperation, 'list'>; readonly params: string };
}

export type ODataRow = Readonly<Record<string, unknown>>;

const VIRTUAL_NAME: Readonly<Record<Exclude<ODataOperation, 'list'>, string>> = {
  balance: 'Balance',
  sliceLast: 'SliceLast',
};

/** Нулевая ссылка 1С (пустое значение ссылочного реквизита). */
export const ODATA_EMPTY_REF = '00000000-0000-0000-0000-000000000000';

/** Литерал GUID для `$filter` (только канонический UUID — защита от инъекции в фильтр). */
export function odataGuid(ref: string): string {
  const v = ref.trim().toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v)) {
    throw new Error('odataGuid: значение — не UUID');
  }
  return `guid'${v}'`;
}

/** Строковый литерал для `$filter` (кавычка удваивается). */
export function odataString(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

/**
 * Клиент стандартного OData 1С с жёстким allow-list (ONEC-083): разрешены только коллекции и поля
 * `contracts/onec/odata-allowlist.yaml`, только чтение (`GET`), только `$select/$filter/$top/$skip` и
 * `$format=json`; `$top` ≤ 2000 (ONEC-085). Нарушение — `ODataAllowlistError` до отправки запроса.
 */
export class OnecODataClient {
  private readonly root: string;
  private readonly auth: string | undefined;
  private readonly byName: ReadonlyMap<string, ODataAllowedCollection>;
  readonly pageSize: number;

  constructor(
    private readonly config: OnecODataConfig,
    private readonly transport: OnecHttpTransport,
    allowlist: readonly ODataAllowedCollection[] = ODATA_ALLOWLIST,
  ) {
    const base = config.baseUrl.replace(/\/+$/, '');
    const path = config.odataPath.replace(/^\/+|\/+$/g, '');
    this.root = `${base}/${path}`;
    this.auth =
      config.user !== undefined
        ? `Basic ${Buffer.from(`${config.user}:${config.password ?? ''}`, 'utf8').toString('base64')}`
        : undefined;
    this.byName = new Map(allowlist.map((c) => [c.name, c]));
    this.pageSize = Math.min(config.pageSize ?? ODATA_DEFAULT_PAGE_SIZE, ODATA_MAX_TOP);
  }

  /** Описание коллекции из allow-list или `ODataAllowlistError`. */
  allowed(collection: string): ODataAllowedCollection {
    if (ODATA_DENIED.includes(collection)) throw new ODataAllowlistError(collection, 'коллекция запрещена (ONEC-083)');
    const c = this.byName.get(collection);
    if (!c) throw new ODataAllowlistError(collection, 'коллекции нет в allow-list');
    return c;
  }

  /** Одна страница коллекции. */
  async list(collection: string, q: ODataQuery, signal?: AbortSignal): Promise<ODataRow[]> {
    const url = this.buildUrl(collection, q);
    const body = await this.get(collection, url, signal, this.config.pageTimeoutMs ?? ODATA_PAGE_TIMEOUT_MS);
    let parsed: unknown;
    try {
      parsed = JSON.parse(body);
    } catch {
      throw new OnecODataError(collection, 200, 'INVALID_RESPONSE', 'ответ OData — не JSON');
    }
    const value = (parsed as { value?: unknown } | null)?.value;
    if (!Array.isArray(value)) throw new OnecODataError(collection, 200, 'INVALID_RESPONSE', 'нет массива value');
    return value as ODataRow[];
  }

  /** Все страницы (`$top`/`$skip`); последняя страница — короче `$top`. */
  async *pages(
    collection: string,
    q: Omit<ODataQuery, 'top' | 'skip'>,
    startSkip = 0,
  ): AsyncGenerator<{ skip: number; rows: ODataRow[] }> {
    const top = this.pageSize;
    for (let skip = startSkip; ; skip += top) {
      const rows = await this.list(collection, { ...q, top, skip });
      yield { skip, rows };
      if (rows.length < top) return;
    }
  }

  /** `GET …/$count` (сверка количества, 05 SYNC-003, SYNC-068). */
  async count(collection: string, filter?: string, signal?: AbortSignal): Promise<number> {
    this.allowed(collection);
    const qs = filter ? `?$filter=${encodeURIComponent(filter)}` : '';
    const body = await this.get(
      collection,
      `${this.root}/${encodeURIComponent(collection)}/$count${qs}`,
      signal,
      this.config.timeoutMs ?? 30_000,
    );
    const n = Number.parseInt(body.trim(), 10);
    if (!Number.isFinite(n) || n < 0)
      throw new OnecODataError(collection, 200, 'INVALID_RESPONSE', '$count — не число');
    return n;
  }

  buildUrl(collection: string, q: ODataQuery): string {
    const c = this.allowed(collection);
    if (q.select.length === 0) throw new ODataAllowlistError(collection, '$select обязателен');
    const unknown = q.select.filter((f) => !c.fields.includes(f));
    if (unknown.length > 0) throw new ODataAllowlistError(collection, `поля вне allow-list: ${unknown.join(', ')}`);
    if (q.top !== undefined && (!Number.isInteger(q.top) || q.top < 1 || q.top > ODATA_MAX_TOP)) {
      throw new ODataAllowlistError(collection, `$top вне 1…${ODATA_MAX_TOP}`);
    }
    if (q.skip !== undefined && (!Number.isInteger(q.skip) || q.skip < 0)) {
      throw new ODataAllowlistError(collection, '$skip — целое ≥ 0');
    }
    let path = encodeURIComponent(collection);
    if (q.virtual) {
      if (!c.operations.includes(q.virtual.op)) {
        throw new ODataAllowlistError(collection, `операция ${q.virtual.op} не разрешена`);
      }
      path += `/${VIRTUAL_NAME[q.virtual.op]}(${encodeURIComponent(q.virtual.params)})`;
    } else if (!c.operations.includes('list')) {
      throw new ODataAllowlistError(collection, 'операция list не разрешена');
    }
    const parts = ['$format=json', `$select=${encodeURIComponent(q.select.join(','))}`];
    if (q.filter) parts.push(`$filter=${encodeURIComponent(q.filter)}`);
    if (q.top !== undefined) parts.push(`$top=${q.top}`);
    if (q.skip !== undefined) parts.push(`$skip=${q.skip}`);
    return `${this.root}/${path}?${parts.join('&')}`;
  }

  private async get(
    collection: string,
    url: string,
    signal: AbortSignal | undefined,
    timeoutMs: number,
  ): Promise<string> {
    const requestId = newId();
    let res;
    try {
      res = await this.transport.request({
        method: 'GET',
        url,
        headers: {
          Accept: 'application/json',
          'X-Request-Id': requestId,
          ...(this.auth ? { Authorization: this.auth } : {}),
        },
        timeoutMs,
        ...(signal ? { signal } : {}),
      });
    } catch (e) {
      if (e instanceof OnecTransportError) throw new OnecODataError(collection, 0, 'TRANSPORT', e.message, requestId);
      throw e;
    }
    const text = res.body.toString('utf8');
    if (res.status < 200 || res.status >= 300) {
      throw new OnecODataError(collection, res.status, `HTTP_${res.status}`, odataMessage(text), requestId);
    }
    return text;
  }
}

/** Текст ошибки OData 1С (`odata.error.message.value`) без тела целиком. */
function odataMessage(text: string): string {
  try {
    const v = (JSON.parse(text) as { 'odata.error'?: { message?: { value?: unknown } } })['odata.error']?.message
      ?.value;
    if (typeof v === 'string') return v.slice(0, 300);
  } catch {
    /* не JSON */
  }
  return 'ошибка OData';
}

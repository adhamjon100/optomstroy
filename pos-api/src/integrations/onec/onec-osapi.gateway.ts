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
  OnecJsonObject,
  OnecOperationId,
  OnecQrCancelReason,
  OnecQrCancelResponse,
  OnecQrCreateRequest,
  OnecQrCreateResponse,
  OnecQrPaymentStatus,
  OnecResult,
} from './onec-gateway.js';
import { type OnecOsApiClient, osApiRef } from './onec-osapi.client.js';
import { osApiDate } from './onec-osapi.mapping.js';

/** Текст отказа методов, которых в режиме `os_api` нет (ADR-126). */
export const OSAPI_UNSUPPORTED_MESSAGE =
  'метод недоступен в ONEC_MODE=os_api: через ОС_API только чтение каталога, цен, остатков и фото (ADR-126)';

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
 * - ВСЕ методы записи (заказ, отмена, оплата, QR, клиент, заявка на возврат) и прочие чтения вне каталога —
 *   отказ `OnecError(501)` БЕЗ запроса в 1С. Outbox в этом режиме канал записи не подключает (orders-worker.wiring):
 *   элементы паркуются `NO_WRITE_CHANNEL` («ждут оформления в 1С»), а не уходят в повтор/`dead`.
 */
export class OnecOsApiGateway implements OnecGateway {
  readonly mode = 'os_api' as const;
  private fileKinds: { at: number; map: Map<string, 'item' | 'characteristic'> } | undefined;

  constructor(
    readonly client: OnecOsApiClient,
    private readonly now: () => Date = () => new Date(),
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
  createOrder(_r: OnecJsonObject, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('createOrder');
  }
  getOrderStatus(_id: string, _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('getOrderStatus');
  }
  getOrderStatusBatch(_ids: readonly string[], _o?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return unsupported('getOrderStatusBatch');
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

function unsupported<T>(op: OnecOperationId): Promise<T> {
  return Promise.reject(new OnecError(op, 501, 'POS_E_NOT_FOUND', OSAPI_UNSUPPORTED_MESSAGE));
}

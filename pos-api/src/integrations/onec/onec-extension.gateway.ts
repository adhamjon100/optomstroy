import { newId } from '../../common/ids/uuid.js';
import { ONEC_ERROR_CODES, OnecError } from './onec-error.js';
import {
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
import { type OnecHttpResponse, type OnecHttpTransport, OnecTransportError } from './onec-http-transport.js';

/**
 * Настройки `OnecExtensionGateway` — канонические имена 16 §4.3 / R0 §17.7: `ONEC_BASE_URL`, `ONEC_HS_PATH`,
 * секреты `ONEC_HS_USER_FILE`, `ONEC_HS_PASSWORD_FILE` (Basic, пользователь `pos_hs`), `ONEC_HS_TOKEN_FILE`
 * (`X-POS-Client-Key`, ONEC-032); таймауты `ONEC_TIMEOUT_MS`, `ONEC_SYNC_CHECK_TIMEOUT_MS` (05 SYNC-030).
 */
export interface OnecExtensionConfig {
  /** `ONEC_BASE_URL`, например `https://host-1c`. */
  readonly baseUrl: string;
  /** `ONEC_HS_PATH` — путь публикации до сегмента `hs` включительно, например `ut11/hs`. */
  readonly hsPath: string;
  readonly user?: string;
  readonly password?: string;
  /** Значение заголовка `X-POS-Client-Key` (`ONEC_HS_TOKEN_FILE`). */
  readonly clientKey?: string;
  /** Прочие вызовы (`ONEC_TIMEOUT_MS`, по умолчанию 30 с). */
  readonly timeoutMs?: number;
  /** Синхронные вызовы при оформлении (`/check`, точечный долг, QR) — `ONEC_SYNC_CHECK_TIMEOUT_MS` (6 с). */
  readonly syncCheckTimeoutMs?: number;
  /** Чтение страницы `/changes` (05 SYNC-030: 60 с). */
  readonly changesTimeoutMs?: number;
  /** `/images` (05 SYNC-030: 120 с). */
  readonly imagesTimeoutMs?: number;
  /** Повторы только идемпотентных GET при временной ошибке (сеть, 5xx, `POS_E_LOCKED`/`MAINTENANCE`). */
  readonly retry?: { readonly maxAttempts: number; readonly baseDelayMs: number };
}

export const ONEC_HS_DEFAULTS = {
  timeoutMs: 30_000,
  syncCheckTimeoutMs: 6_000,
  changesTimeoutMs: 60_000,
  imagesTimeoutMs: 120_000,
  retry: { maxAttempts: 3, baseDelayMs: 500 },
} as const;

/** Код ошибки адаптера для ответа 2xx, не соответствующего контракту (не код 1С). */
export const ONEC_INVALID_RESPONSE = 'INVALID_RESPONSE';
/** Код ошибки адаптера для сбоя транспорта (`status = 0`, см. OnecError). */
export const ONEC_TRANSPORT = 'TRANSPORT';

const KNOWN_CODES = new Set<string>(ONEC_ERROR_CODES);
const REF_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

type TimeoutKind = 'default' | 'sync' | 'changes' | 'images';

interface CallSpec {
  readonly op: OnecOperationId;
  readonly method: 'GET' | 'POST';
  readonly path: string;
  readonly query?: Readonly<Record<string, string | number | undefined>>;
  readonly body?: unknown;
  readonly timeout?: TimeoutKind;
  readonly headers?: Readonly<Record<string, string>>;
  readonly opts?: OnecCallOptions;
}

/**
 * `OnecExtensionGateway` — HTTP-клиент сервиса расширения «OptomstroyPOS» `/pos/v1/*` по контракту
 * `contracts/onec/onec-http-service.v1.yaml` (фаза 1, `ONEC_MODE=extension`; 05 §6.3, ядро v1.9 §24.3).
 *
 * - Каждый запрос несёт `X-Request-Id` (UUID; ONEC-088) — из `opts.requestId` или новый v7; повтор — с тем же id.
 * - Аутентификация: Basic `pos_hs` + `X-POS-Client-Key` (ONEC-032).
 * - Не-2xx → `OnecError` с кодом `POS_E_*` из тела ошибки (05 §6.5); тело без кода — код по HTTP-статусу.
 * - Сбой транспорта → `OnecError(status=0, code='TRANSPORT')` (временная, `retryable`).
 * - Повтор — только идемпотентных `GET` и только временных ошибок; запись (`POST`) не повторяется никогда
 *   (повторы записи — outbox с тем же `externalId`, 05 §8).
 * - Неизвестные поля ответа не мешают (ONEC-058): тело передаётся потребителю как есть.
 */
export class OnecExtensionGateway implements OnecGateway {
  readonly mode = 'extension' as const;
  private readonly root: string;
  private readonly cfg: Required<Omit<OnecExtensionConfig, 'user' | 'password' | 'clientKey'>>;

  constructor(
    config: OnecExtensionConfig,
    private readonly transport: OnecHttpTransport,
    private readonly sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
  ) {
    const base = config.baseUrl.replace(/\/+$/, '');
    const hs = config.hsPath.replace(/^\/+|\/+$/g, '');
    this.root = hs ? `${base}/${hs}` : base;
    this.cfg = {
      baseUrl: base,
      hsPath: hs,
      timeoutMs: config.timeoutMs ?? ONEC_HS_DEFAULTS.timeoutMs,
      syncCheckTimeoutMs: config.syncCheckTimeoutMs ?? ONEC_HS_DEFAULTS.syncCheckTimeoutMs,
      changesTimeoutMs: config.changesTimeoutMs ?? ONEC_HS_DEFAULTS.changesTimeoutMs,
      imagesTimeoutMs: config.imagesTimeoutMs ?? ONEC_HS_DEFAULTS.imagesTimeoutMs,
      retry: config.retry ?? ONEC_HS_DEFAULTS.retry,
    };
    this.authHeaders = {};
    if (config.user !== undefined) {
      const token = Buffer.from(`${config.user}:${config.password ?? ''}`, 'utf8').toString('base64');
      this.authHeaders.Authorization = `Basic ${token}`;
    }
    if (config.clientKey !== undefined) this.authHeaders['X-POS-Client-Key'] = config.clientKey;
  }

  private readonly authHeaders: Record<string, string>;

  getHealth(opts?: OnecCallOptions): Promise<OnecResult<OnecHealth>> {
    return this.json<OnecHealth>(
      { op: 'getHealth', method: 'GET', path: '/pos/v1/health', ...withOpts(opts) },
      (b) => isObject(b) && typeof b.apiVersion === 'string' && typeof b.lastAckMessageNumber === 'number',
    );
  }

  getChanges(query: OnecChangesQuery, opts?: OnecCallOptions): Promise<OnecResult<OnecChangesPage>> {
    if (!Number.isInteger(query.since) || query.since < 0) {
      return Promise.reject(new OnecError('getChanges', 0, 'POS_E_BAD_REQUEST', 'since — целое ≥ 0'));
    }
    return this.json<OnecChangesPage>(
      {
        op: 'getChanges',
        method: 'GET',
        path: '/pos/v1/changes',
        query: { since: query.since, limit: query.limit, cursor: query.cursor },
        timeout: 'changes',
        ...withOpts(opts),
      },
      (b) =>
        isObject(b) &&
        typeof b.messageNumber === 'number' &&
        typeof b.hasMore === 'boolean' &&
        Array.isArray(b.items) &&
        (b.cursor === null || typeof b.cursor === 'string') &&
        // 05 §6.2 п. 1: при `hasMore=true` курсор следующей страницы обязателен (иначе ack потерял бы страницы).
        (b.hasMore === false || (typeof b.cursor === 'string' && b.cursor !== '')),
    );
  }

  ackChanges(messageNumber: number, opts?: OnecCallOptions): Promise<OnecResult<OnecChangesAck>> {
    return this.json<OnecChangesAck>(
      { op: 'ackChanges', method: 'POST', path: '/pos/v1/changes/ack', body: { messageNumber }, ...withOpts(opts) },
      (b) => isObject(b) && typeof b.messageNumber === 'number',
    );
  }

  async reregisterChanges(opts?: OnecCallOptions): Promise<OnecResult<null>> {
    const r = await this.call({
      op: 'reregisterChanges',
      method: 'POST',
      path: '/pos/v1/changes/reregister',
      ...withOpts(opts),
    });
    return { status: r.status, body: null, ...reqId(r.res) };
  }

  createOrder(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'createOrder',
      method: 'POST',
      path: '/pos/v1/orders',
      body: request,
      timeout: 'sync',
      ...withOpts(opts),
    });
  }

  async getOrderStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'getOrderStatus',
      method: 'GET',
      path: `/pos/v1/orders/${ref('getOrderStatus', externalId)}/status`,
      ...withOpts(opts),
    });
  }

  getOrderStatusBatch(externalIds: readonly string[], opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'getOrderStatusBatch',
      method: 'POST',
      path: '/pos/v1/orders/status',
      body: { externalIds },
      ...withOpts(opts),
    });
  }

  async cancelOrder(
    externalId: string,
    request: OnecJsonObject,
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'cancelOrder',
      method: 'POST',
      path: `/pos/v1/orders/${ref('cancelOrder', externalId)}/cancel`,
      body: request,
      ...withOpts(opts),
    });
  }

  createPayment(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'createPayment',
      method: 'POST',
      path: '/pos/v1/payments',
      body: request,
      ...withOpts(opts),
    });
  }

  createQrPayment(request: OnecQrCreateRequest, opts?: OnecCallOptions): Promise<OnecResult<OnecQrCreateResponse>> {
    return this.json<OnecQrCreateResponse>({
      op: 'createQrPayment',
      method: 'POST',
      path: '/pos/v1/payments/qr',
      body: request,
      timeout: 'sync',
      ...withOpts(opts),
    });
  }

  async getQrPaymentStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecQrPaymentStatus>> {
    return this.json<OnecQrPaymentStatus>({
      op: 'getQrPaymentStatus',
      method: 'GET',
      path: `/pos/v1/payments/${ref('getQrPaymentStatus', externalId)}/status`,
      timeout: 'sync',
      ...withOpts(opts),
    });
  }

  async cancelQrPayment(
    externalId: string,
    reason: OnecQrCancelReason,
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecQrCancelResponse>> {
    return this.json<OnecQrCancelResponse>({
      op: 'cancelQrPayment',
      method: 'POST',
      path: `/pos/v1/payments/${ref('cancelQrPayment', externalId)}/qr/cancel`,
      body: { reason },
      timeout: 'sync',
      ...withOpts(opts),
    });
  }

  findCustomersByPhone(phone: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject[]>> {
    return this.json<OnecJsonObject[]>(
      {
        op: 'findCustomersByPhone',
        method: 'GET',
        path: '/pos/v1/customers',
        query: { phone },
        timeout: 'sync',
        ...withOpts(opts),
      },
      (b) => Array.isArray(b),
    );
  }

  createCustomer(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'createCustomer',
      method: 'POST',
      path: '/pos/v1/customers',
      body: request,
      ...withOpts(opts),
    });
  }

  async getCustomerReceivables(customerRef: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'getCustomerReceivables',
      method: 'GET',
      path: `/pos/v1/customers/${ref('getCustomerReceivables', customerRef)}/receivables`,
      timeout: 'sync',
      ...withOpts(opts),
    });
  }

  createReturnRequest(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'createReturnRequest',
      method: 'POST',
      path: '/pos/v1/returns',
      body: request,
      ...withOpts(opts),
    });
  }

  async getReturnRequestStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'getReturnRequestStatus',
      method: 'GET',
      path: `/pos/v1/returns/${ref('getReturnRequestStatus', externalId)}/status`,
      ...withOpts(opts),
    });
  }

  async getImage(
    imageRef: string,
    ifNoneMatch?: string,
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecImage | null>> {
    const r = await this.call({
      op: 'getImage',
      method: 'GET',
      path: `/pos/v1/images/${ref('getImage', imageRef)}`,
      timeout: 'images',
      ...(ifNoneMatch ? { headers: { 'If-None-Match': ifNoneMatch } } : {}),
      ...withOpts(opts),
    });
    const etag = r.res.headers.etag ?? null;
    if (r.status === 304) return { status: 304, body: null, ...reqId(r.res) };
    return {
      status: r.status,
      body: {
        contentType: r.res.headers['content-type'] ?? 'application/octet-stream',
        etag,
        data: new Uint8Array(r.res.body),
      },
      ...reqId(r.res),
    };
  }

  checkCart(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'checkCart',
      method: 'POST',
      path: '/pos/v1/check',
      body: request,
      timeout: 'sync',
      ...withOpts(opts),
    });
  }

  async getCatalogCard(productRef: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json(
      {
        op: 'getCatalogCard',
        method: 'GET',
        path: `/pos/v1/catalog/${ref('getCatalogCard', productRef)}`,
        ...withOpts(opts),
      },
      (b) => isObject(b) && isObject(b.product) && Array.isArray(b.prices) && Array.isArray(b.stock),
    );
  }

  listExternalIds(query: OnecExternalIdsQuery, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.json({
      op: 'listExternalIds',
      method: 'GET',
      path: '/pos/v1/external-ids',
      query: { since: query.since, type: query.type, limit: query.limit, cursor: query.cursor },
      ...withOpts(opts),
    });
  }

  // ---------------------------------------------------------------- внутреннее

  private async json<T = OnecJsonObject>(spec: CallSpec, valid?: (body: unknown) => boolean): Promise<OnecResult<T>> {
    const r = await this.call(spec);
    let body: unknown = null;
    if (r.res.body.length > 0) {
      try {
        body = JSON.parse(r.res.body.toString('utf8')) as unknown;
      } catch {
        throw new OnecError(spec.op, r.status, ONEC_INVALID_RESPONSE, 'ответ 1С — не JSON', undefined, r.requestId);
      }
    }
    if (valid && !valid(body)) {
      throw new OnecError(
        spec.op,
        r.status,
        ONEC_INVALID_RESPONSE,
        'ответ 1С не соответствует контракту',
        undefined,
        r.requestId,
      );
    }
    return { status: r.status, body: body as T, ...reqId(r.res) };
  }

  private async call(spec: CallSpec): Promise<{ status: number; res: OnecHttpResponse; requestId: string }> {
    const requestId = spec.opts?.requestId ?? newId();
    const url = this.url(spec.path, spec.query);
    const headers: Record<string, string> = {
      Accept: spec.op === 'getImage' ? 'image/*, application/octet-stream, application/json' : 'application/json',
      'X-Request-Id': requestId,
      ...this.authHeaders,
      ...spec.headers,
    };
    let body: Buffer | undefined;
    if (spec.method === 'POST') {
      headers['Content-Type'] = 'application/json; charset=utf-8';
      body = Buffer.from(spec.body === undefined ? '' : JSON.stringify(spec.body), 'utf8');
    }
    const idempotent = spec.method === 'GET';
    const maxAttempts = idempotent ? Math.max(1, this.cfg.retry.maxAttempts) : 1;
    for (let attempt = 1; ; attempt++) {
      try {
        const res = await this.transport
          .request({
            method: spec.method,
            url,
            headers,
            ...(body ? { body } : {}),
            timeoutMs: this.timeout(spec.timeout),
            ...(spec.opts?.signal ? { signal: spec.opts.signal } : {}),
          })
          .catch((e: unknown) => {
            throw e instanceof OnecTransportError
              ? new OnecError(spec.op, 0, ONEC_TRANSPORT, e.message, undefined, requestId)
              : e;
          });
        if ((res.status >= 200 && res.status < 300) || (res.status === 304 && spec.op === 'getImage')) {
          return { status: res.status, res, requestId };
        }
        throw toOnecError(spec.op, res, requestId);
      } catch (e) {
        const retry = attempt < maxAttempts && e instanceof OnecError && e.retryable && !spec.opts?.signal?.aborted;
        if (!retry) throw e;
        await this.sleep(this.cfg.retry.baseDelayMs * 2 ** (attempt - 1));
      }
    }
  }

  private timeout(kind: TimeoutKind = 'default'): number {
    switch (kind) {
      case 'sync':
        return this.cfg.syncCheckTimeoutMs;
      case 'changes':
        return this.cfg.changesTimeoutMs;
      case 'images':
        return this.cfg.imagesTimeoutMs;
      default:
        return this.cfg.timeoutMs;
    }
  }

  private url(path: string, query?: Readonly<Record<string, string | number | undefined>>): string {
    const qs = Object.entries(query ?? {})
      .filter((e): e is [string, string | number] => e[1] !== undefined && e[1] !== '')
      .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
      .join('&');
    return `${this.root}${path}${qs ? `?${qs}` : ''}`;
  }
}

function withOpts(opts?: OnecCallOptions): { opts?: OnecCallOptions } {
  return opts ? { opts } : {};
}

function reqId(res: OnecHttpResponse): { requestId?: string } {
  const id = res.headers['x-request-id'];
  return id ? { requestId: id } : {};
}

/** Ссылка/UUID в пути: только канонический нижний регистр (защита от подстановки пути). */
function ref(op: OnecOperationId, value: string): string {
  const v = value.trim().toLowerCase();
  if (!REF_RE.test(v)) throw new OnecError(op, 0, 'POS_E_BAD_REQUEST', 'ссылка 1С — не UUID');
  return v;
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

function toOnecError(op: OnecOperationId, res: OnecHttpResponse, requestId: string): OnecError {
  let parsed: unknown;
  try {
    parsed = res.body.length > 0 ? JSON.parse(res.body.toString('utf8')) : undefined;
  } catch {
    parsed = undefined;
  }
  const b = isObject(parsed) ? parsed : {};
  const code =
    typeof b.code === 'string' && KNOWN_CODES.has(b.code)
      ? b.code
      : (STATUS_CODE[res.status] ?? (res.status >= 500 ? 'POS_E_INTERNAL' : 'POS_E_BAD_REQUEST'));
  const message = typeof b.message === 'string' ? b.message : `HTTP ${res.status}`;
  return new OnecError(
    op,
    res.status,
    code,
    message,
    b.details,
    typeof b.requestId === 'string' ? b.requestId : (res.headers['x-request-id'] ?? requestId),
  );
}

function isObject(v: unknown): v is { [key: string]: OnecJson } {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

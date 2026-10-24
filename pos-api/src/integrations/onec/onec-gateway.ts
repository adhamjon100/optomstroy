/**
 * Порт `OnecGateway` (05 ONEC-023; 06 §7.3 «Порт OnecGateway», ARCH-007): единственная точка, через которую
 * backend обращается к 1С. Реализации: `OnecExtensionGateway` (HTTP-сервис расширения `/pos/v1/*`, основной путь —
 * ядро v1.9 §24.3), `OnecODataGateway` (запасной, фаза 0) и `FakeOnecGateway` (изолированный тестовый режим на
 * фикстурах `contracts/onec/fixtures`, `ONEC_MODE=fixtures`, RM-C-008). Выбор — `ONEC_MODE` при старте.
 *
 * Состав методов — ровно 21 операция контракта `contracts/onec/onec-http-service.v1.yaml` (таблица 05 §6.3).
 * Тела запросов и ответов — JSON контракта «как есть» (ONEC-058: неизвестные поля игнорируются потребителем);
 * типизированы только поля, на которые опираются порты (`PaymentProvider` — методы QR 05 §6.7, health, changes).
 *
 * Ошибка 1С (не-2xx) — исключение `OnecError` (onec-error.ts) с кодом `POS_E_*` (05 §6.5).
 */

/** Значения `ONEC_MODE` (16 §4.3; R0 §16 п. 3). */
export type OnecMode = 'extension' | 'odata_only' | 'fixtures';

/** DI-токен порта. Строковый литерал — чтобы `payments/**` мог сослаться на него без импорта значения (ARCH-063 п. 4). */
export const ONEC_GATEWAY = 'OnecGateway' as const;
export type OnecGatewayDiKey = typeof ONEC_GATEWAY;

/** Деньги контракта 1С: строка `^-?\d+\.\d{2}$` (ONEC-058). */
export type OnecMoney = string;
/** Дата-время контракта 1С: ISO 8601 с `+06:00` (ONEC-058). */
export type OnecDateTime = string;

export type OnecJson = null | boolean | number | string | OnecJson[] | { [key: string]: OnecJson };
export type OnecJsonObject = { [key: string]: OnecJson };

/** Успешный ответ 2xx: статус различает «создано» (201) и идемпотентный повтор (200). */
export interface OnecResult<T> {
  readonly status: number;
  readonly body: T;
  /** Значение `X-Request-Id` ответа (если 1С его вернула). */
  readonly requestId?: string;
}

/** Общие параметры вызова (ONEC-088: `X-Request-Id` — обязательный заголовок запроса). */
export interface OnecCallOptions {
  readonly requestId?: string;
  readonly signal?: AbortSignal;
}

// ---------- сервис ----------

export interface OnecHealth {
  readonly apiVersion: string;
  readonly extensionVersion: string;
  readonly platform: string;
  readonly configuration: string;
  readonly configurationVersion: string;
  readonly serverTime: OnecDateTime;
  readonly exchangeNode: string;
  readonly registrationBacklog: number;
  readonly lastAckMessageNumber: number;
  readonly status: string;
  readonly [extra: string]: OnecJson;
}

// ---------- обмен (план обмена «POS», 05 §6.2) ----------

export interface OnecChangesQuery {
  readonly since: number;
  readonly limit?: number;
  readonly cursor?: string;
}

export interface OnecChangeItem {
  readonly type: string;
  readonly ref: string;
  readonly [field: string]: OnecJson;
}

export interface OnecChangesPage {
  readonly messageNumber: number;
  readonly hasMore: boolean;
  readonly cursor: string | null;
  readonly generatedAt: OnecDateTime;
  readonly items: readonly OnecChangeItem[];
}

export interface OnecChangesAck {
  readonly messageNumber: number;
  readonly removedRegistrations?: number;
}

export interface OnecExternalIdsQuery {
  readonly since?: OnecDateTime;
  readonly type?: string;
  readonly limit?: number;
  readonly cursor?: string;
}

// ---------- QR-оплата через 1С (05 §6.7, ядро v1.9 §24.4) ----------

export type OnecQrStatus = 'pending' | 'paid' | 'expired' | 'cancelled';

export interface OnecQrCreateRequest {
  readonly externalId: string;
  readonly orderExternalId: string;
  readonly orderRef: string | null;
  readonly customerRef: string | null;
  readonly amount: OnecMoney;
  readonly currency: string;
  readonly purpose: string;
  readonly requestedTtlSeconds: number;
  readonly cashierUserCode: string;
}

export interface OnecQrCreateResponse {
  readonly externalId: string;
  readonly status: OnecQrStatus;
  readonly qrPayload?: string | null;
  readonly qrImagePng?: string | null;
  readonly reference: string;
  readonly amount: OnecMoney;
  readonly createdAt: OnecDateTime;
  readonly expiresAt: OnecDateTime;
}

export interface OnecQrPaymentStatus {
  readonly externalId: string;
  readonly status: OnecQrStatus;
  readonly reference: string;
  readonly amount: OnecMoney;
  readonly paidAmount: OnecMoney | null;
  readonly paidAt: OnecDateTime | null;
  readonly bankReference: string | null;
  readonly expiresAt: OnecDateTime;
  readonly documentRef: string | null;
  readonly documentType: string | null;
}

export type OnecQrCancelReason = 'method_changed' | 'voided' | 'order_cancelled' | 'reissue';

export interface OnecQrCancelResponse {
  readonly externalId: string;
  readonly status: 'cancelled' | 'paid';
  readonly reference?: string | null;
  readonly paidAmount?: OnecMoney | null;
  readonly paidAt?: OnecDateTime | null;
  readonly bankReference?: string | null;
  readonly documentRef?: string | null;
}

// ---------- изображения ----------

export interface OnecImage {
  readonly contentType: string;
  readonly etag: string | null;
  readonly data: Uint8Array;
}

/** Порт 1С. Каждый метод — одна операция контракта (operationId в комментарии). */
export interface OnecGateway {
  /** Активный режим (`ONEC_MODE`); `fixtures` — данные тестовые (баннер «тестовые данные» вне prod). */
  readonly mode: OnecMode;

  /** getHealth — `GET /pos/v1/health`. */
  getHealth(opts?: OnecCallOptions): Promise<OnecResult<OnecHealth>>;
  /** getChanges — `GET /pos/v1/changes?since&limit&cursor`. */
  getChanges(query: OnecChangesQuery, opts?: OnecCallOptions): Promise<OnecResult<OnecChangesPage>>;
  /** ackChanges — `POST /pos/v1/changes/ack`. */
  ackChanges(messageNumber: number, opts?: OnecCallOptions): Promise<OnecResult<OnecChangesAck>>;
  /** reregisterChanges — `POST /pos/v1/changes/reregister` (202 без тела). */
  reregisterChanges(opts?: OnecCallOptions): Promise<OnecResult<null>>;

  /** createOrder — `POST /pos/v1/orders` (идемпотентно по `externalId`). */
  createOrder(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;
  /** getOrderStatus — `GET /pos/v1/orders/{uuid}/status`. */
  getOrderStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;
  /** getOrderStatusBatch — `POST /pos/v1/orders/status`. */
  getOrderStatusBatch(externalIds: readonly string[], opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;
  /** cancelOrder — `POST /pos/v1/orders/{uuid}/cancel`. */
  cancelOrder(externalId: string, request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;

  /** createPayment — `POST /pos/v1/payments`. */
  createPayment(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;
  /** createQrPayment — `POST /pos/v1/payments/qr` (05 §6.7). */
  createQrPayment(request: OnecQrCreateRequest, opts?: OnecCallOptions): Promise<OnecResult<OnecQrCreateResponse>>;
  /** getQrPaymentStatus — `GET /pos/v1/payments/{externalId}/status`. */
  getQrPaymentStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecQrPaymentStatus>>;
  /** cancelQrPayment — `POST /pos/v1/payments/{externalId}/qr/cancel`. */
  cancelQrPayment(
    externalId: string,
    reason: OnecQrCancelReason,
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecQrCancelResponse>>;

  /** findCustomersByPhone — `GET /pos/v1/customers?phone=`. */
  findCustomersByPhone(phone: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject[]>>;
  /** createCustomer — `POST /pos/v1/customers`. */
  createCustomer(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;
  /** getCustomerReceivables — `GET /pos/v1/customers/{ref}/receivables`. */
  getCustomerReceivables(ref: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;

  /** createReturnRequest — `POST /pos/v1/returns`. */
  createReturnRequest(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;
  /** getReturnRequestStatus — `GET /pos/v1/returns/{uuid}/status`. */
  getReturnRequestStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;

  /** getImage — `GET /pos/v1/images/{ref}` (`If-None-Match` → 304, тогда `body = null`). */
  getImage(ref: string, ifNoneMatch?: string, opts?: OnecCallOptions): Promise<OnecResult<OnecImage | null>>;
  /** checkCart — `POST /pos/v1/check` (синхронная проверка, `ONEC_SYNC_CHECK_TIMEOUT_MS`). */
  checkCart(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;
  /** getCatalogCard — `GET /pos/v1/catalog/{ref}`. */
  getCatalogCard(ref: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;
  /** listExternalIds — `GET /pos/v1/external-ids`. */
  listExternalIds(query: OnecExternalIdsQuery, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>>;
}

/** Имена операций порта = operationId контракта; значение — «МЕТОД путь» как в поле `operation` фикстур. */
export const ONEC_OPERATIONS = {
  getHealth: 'GET /pos/v1/health',
  getChanges: 'GET /pos/v1/changes',
  ackChanges: 'POST /pos/v1/changes/ack',
  reregisterChanges: 'POST /pos/v1/changes/reregister',
  createOrder: 'POST /pos/v1/orders',
  getOrderStatus: 'GET /pos/v1/orders/{uuid}/status',
  getOrderStatusBatch: 'POST /pos/v1/orders/status',
  cancelOrder: 'POST /pos/v1/orders/{uuid}/cancel',
  createPayment: 'POST /pos/v1/payments',
  createQrPayment: 'POST /pos/v1/payments/qr',
  getQrPaymentStatus: 'GET /pos/v1/payments/{externalId}/status',
  cancelQrPayment: 'POST /pos/v1/payments/{externalId}/qr/cancel',
  findCustomersByPhone: 'GET /pos/v1/customers',
  createCustomer: 'POST /pos/v1/customers',
  getCustomerReceivables: 'GET /pos/v1/customers/{ref}/receivables',
  createReturnRequest: 'POST /pos/v1/returns',
  getReturnRequestStatus: 'GET /pos/v1/returns/{uuid}/status',
  getImage: 'GET /pos/v1/images/{ref}',
  checkCart: 'POST /pos/v1/check',
  getCatalogCard: 'GET /pos/v1/catalog/{ref}',
  listExternalIds: 'GET /pos/v1/external-ids',
} as const satisfies Record<Exclude<keyof OnecGateway, 'mode'>, string>;

export type OnecOperationId = keyof typeof ONEC_OPERATIONS;

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
import { type OnecODataClient, OnecODataError } from './onec-odata.client.js';

/**
 * `OnecODataGateway` — запасной путь фазы 0 (`ONEC_MODE=odata_only`; 05 §4, ядро v1.9 §24.3): только чтение
 * стандартного OData по allow-list (`OnecODataClient`). Методы HTTP-сервиса расширения (`/changes`, запись
 * заказов/платежей/клиентов, QR, `/check`, картинки) в фазе 0 недоступны — `OnecError(501, POS_E_NOT_FOUND)`;
 * чтение каталога и срезов выполняет `ODataCatalogSource` (sync/apply) через `client`.
 * Ручное оформление фазы 0 (SYNC-066…076) — условный элемент 13 §3.12, вне RM-E-001.
 */
export class OnecODataGateway implements OnecGateway {
  readonly mode = 'odata_only' as const;

  constructor(
    readonly client: OnecODataClient,
    private readonly now: () => Date = () => new Date(),
  ) {}

  /** Доступность: лёгкий запрос `Catalog_Склады?$top=1`. Версии расширения в фазе 0 нет. */
  async getHealth(opts?: OnecCallOptions): Promise<OnecResult<OnecHealth>> {
    try {
      await this.client.list('Catalog_Склады', { select: ['Ref_Key'], top: 1 }, opts?.signal);
    } catch (e) {
      if (e instanceof OnecODataError) {
        throw new OnecError('getHealth', e.status, e.status === 0 ? 'TRANSPORT' : codeFor(e.status), e.message);
      }
      throw e;
    }
    return {
      status: 200,
      body: {
        apiVersion: 'odata',
        extensionVersion: '',
        platform: '',
        configuration: '',
        configurationVersion: '',
        serverTime: this.now().toISOString(),
        exchangeNode: '',
        registrationBacklog: 0,
        lastAckMessageNumber: 0,
        status: 'ok',
      },
    };
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
  getImage(_ref: string, _inm?: string, _o?: OnecCallOptions): Promise<OnecResult<OnecImage | null>> {
    return unsupported('getImage');
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

function unsupported<T>(op: OnecOperationId): Promise<T> {
  return Promise.reject(
    new OnecError(
      op,
      501,
      'POS_E_NOT_FOUND',
      'метод HTTP-сервиса расширения недоступен в ONEC_MODE=odata_only (фаза 0)',
    ),
  );
}

function codeFor(status: number): string {
  if (status === 401) return 'POS_E_UNAUTHORIZED';
  if (status === 403) return 'POS_E_FORBIDDEN';
  if (status === 404) return 'POS_E_NOT_FOUND';
  if (status === 423) return 'POS_E_LOCKED';
  if (status === 503) return 'POS_E_MAINTENANCE';
  return status >= 500 ? 'POS_E_INTERNAL' : 'POS_E_BAD_REQUEST';
}

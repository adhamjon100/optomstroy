import type {
  OutboxDeliveryPort,
  OutboxDeliveryResult,
  OutboxRoute,
  OutboxRow,
} from '../../jobs/outbox/outbox-delivery.port.js';
import { isOnecError } from '../../integrations/onec/onec-error.js';
import { OSAPI_MANUAL_CODE, OSAPI_MANUAL_RECHECK_MS } from '../../integrations/onec/onec-osapi.gateway.js';
import type { OnecGateway, OnecJsonObject, OnecResult } from '../../integrations/onec/onec-gateway.js';
import { classifyOnecResult } from '../../sales-domain/outbox/outbox-status.js';
import { deliverCustomerCreate } from './customer-outbox.route.js';

export interface OnecOutboxDeliveryOptions {
  /** Таймаут одного вызова 1С (мс): по истечении — временная ошибка, строка остаётся `pending` (ядро §22.1). */
  readonly timeoutMs: number;
  /**
   * Маршруты канала; `undefined` — все. ОС_API с `ONEC_OSAPI_WRITE_ORDERS=true` — только `order/create`
   * (решение владельца 25.11.2026); прочие строки не захватываются, а попавшая сюда — паркуется.
   */
  readonly routes?: readonly OutboxRoute[];
  /** Добавлять в тело заказа `customer.phone` (телефон клиента POS) для поиска покупателя 1С (ОС_API). */
  readonly orderCustomerPhone?: boolean;
  /**
   * ОС_API с записью заказов: `order/create`, ни разу не отправлявшийся (`attempts = 1`, ошибок не было) и старше
   * этого возраста (мс, `OUTBOX_MAX_AGE_HOURS`), — хвост, накопленный до включения записи (или после долгого
   * простоя), — в 1С сам не уходит, а паркуется «ждёт решения» до ручного повтора `POST /sync/outbox/{id}/retry`
   * (после повтора возраст отсчитывается заново). Не задан — проверки нет.
   */
  readonly parkStaleAfterMs?: number;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function str(v: unknown): string | null {
  return typeof v === 'string' && v !== '' ? v : null;
}

/**
 * Тело заказа нового POS-клиента дополняется ссылками 1С клиента в момент доставки (05 SYNC-049, контракт 1С
 * `OrderCustomer.ref` обязателен; ревью G-customers-1c-1): сохранённый `payload` (и `payload_hash`) не меняется —
 * при постановке ссылки ещё не было. Заполняются только пустые поля `customer.*`.
 */
export function withDependencyCustomer(payload: OnecJsonObject, dep: OutboxRow['dependencyCustomer']): OnecJsonObject {
  if (!dep?.ref) return payload;
  const cur = (payload.customer ?? {}) as Record<string, unknown>;
  const pick = (k: string, v: string | null): string | null => (typeof cur[k] === 'string' ? cur[k] : v);
  return {
    ...payload,
    customer: {
      ...cur,
      ref: pick('ref', dep.ref),
      contractorRef: pick('contractorRef', dep.contractorRef),
      agreementRef: pick('agreementRef', dep.agreementRef),
    },
  };
}

/**
 * Тело документа оплаты дополняется ссылками 1С заказа-основания в момент доставки (ADR-123; контракт 1С
 * `PaymentCreateRequest.customerRef` обязателен): сохранённый `payload` (и `payload_hash`) не меняется. Заполняются
 * только пустые `orderRef` и `customerRef`.
 */
export function withDependencyOrder(payload: OnecJsonObject, dep: OutboxRow['dependencyOrder']): OnecJsonObject {
  if (!dep) return payload;
  const empty = (k: string) => typeof payload[k] !== 'string' || payload[k] === '';
  return {
    ...payload,
    ...(empty('orderRef') && dep.ref ? { orderRef: dep.ref } : {}),
    ...(empty('customerRef') && dep.customerRef ? { customerRef: dep.customerRef } : {}),
  };
}

/**
 * Канал записи outbox → 1С поверх `OnecGateway` (05 §6, §8; 07 §8.2; ядро §22.1): маршрут
 * `aggregate_type × operation` → метод `/pos/v1/*`. Внешний ключ идемпотентности — `externalId` = UUID агрегата, поэтому
 * повтор после таймаута безопасен (1С вернёт существующий документ, 200 или `POS_E_DUPLICATE` → `sent`).
 *
 * - `order/create` → `createOrder(payload)`; `order/cancel` → `cancelOrder(externalId, payload)`;
 * - `payment/create` → `createPayment(payload)` (документ оплаты, Q-012 — владелец payments);
 * - остальные маршруты (клиент, заявка на возврат) — этап G: ошибка конфигурации → `dead` (не тратить попытки молча).
 *
 * Таймаут / сеть / 5xx / `POS_E_LOCKED` — `transient` (никогда не `sent`); бизнес-отказ — `rejected` (`failed`);
 * 401/403 — `fatal` (`dead`). Ответ 2xx без `ref` — `transient` (результат неизвестен).
 */
export class OnecOutboxDelivery implements OutboxDeliveryPort {
  readonly configured = true;
  readonly routes: readonly OutboxRoute[] | undefined;
  readonly needsOrderCustomerPhone: boolean;

  constructor(
    private readonly gateway: OnecGateway,
    private readonly opts: OnecOutboxDeliveryOptions,
  ) {
    this.routes = opts.routes;
    this.needsOrderCustomerPhone = opts.orderCustomerPhone === true;
  }

  async deliver(row: OutboxRow): Promise<OutboxDeliveryResult> {
    const payload = (row.payload ?? {}) as OnecJsonObject;
    const route: OutboxRoute = `${row.aggregateType}/${row.operation}`;
    if (this.routes && !this.routes.includes(route)) {
      return { kind: 'parked', message: `маршрут ${route} в 1С не отправляется (только ${this.routes.join(', ')})` };
    }
    if (route === 'order/create' && this.isStaleBacklog(row)) {
      const hours = Math.round((this.opts.parkStaleAfterMs ?? 0) / 3_600_000);
      return {
        kind: 'parked',
        message:
          `заказ ждал отправки в 1С дольше ${hours} ч (создан до включения записи заказов или во время простоя) — ` +
          'автоматически не отправляется; отправить: «Повторить» в очереди «в 1С» или отменить заказ',
      };
    }
    const signal = AbortSignal.timeout(this.opts.timeoutMs);
    // `attempt` — номер попытки: ОС_API на повторе сначала проверяет, не создан ли заказ прошлой попыткой.
    const callOpts = { signal, requestId: row.id, attempt: row.attempts };
    let res: OnecResult<OnecJsonObject>;
    try {
      switch (route) {
        case 'order/create':
          res = await this.gateway.createOrder(
            this.withOrderExtras(
              withDependencyCustomer({ ...payload, externalId: row.externalId }, row.dependencyCustomer),
              row,
            ),
            callOpts,
          );
          break;
        case 'order/cancel':
          res = await this.gateway.cancelOrder(row.externalId, payload, callOpts);
          break;
        case 'payment/create':
          res = await this.gateway.createPayment(
            withDependencyOrder({ ...payload, externalId: row.externalId }, row.dependencyOrder),
            callOpts,
          );
          break;
        case 'return_request/create':
          // Заявка на возврат (этап G, RM-G-005; 05 §6.3 `POST /pos/v1/returns`, ONEC-048) — только при
          // `RETURNS_FROM_POS_ENABLED=true` (элемент outbox создаёт модуль returns).
          res = await this.gateway.createReturnRequest({ ...payload, externalId: row.externalId }, callOpts);
          break;
        case 'customer/create':
          // Клиент POS → 1С (этап G, RM-G-001): `POS_E_DUPLICATE` — бизнес-отказ (customer-outbox.route.ts).
          return await deliverCustomerCreate(this.gateway, row, payload, callOpts);
        default:
          return { kind: 'fatal', message: `маршрут outbox ${route} не поддержан каналом записи (этап G)` };
      }
    } catch (e) {
      // ОС_API: обязательное поле заказа нечем заполнить — в 1С не записано; без dead, повторная проверка через час
      // (могли задать ONEC_OSAPI_DEFAULT_CUSTOMER, привязать склад, завести товар), раньше — ручным повтором.
      if (isOnecError(e) && e.code === OSAPI_MANUAL_CODE) {
        return { kind: 'parked', message: e.message.slice(0, 2000), recheckAfterMs: OSAPI_MANUAL_RECHECK_MS };
      }
      if (isOnecError(e)) {
        const kind = classifyOnecResult({ ok: false, status: e.status, code: e.code });
        const message = `${e.status} ${e.code}: ${e.message}`.slice(0, 2000);
        if (kind === 'sent') {
          // POS_E_DUPLICATE: документ уже есть — `sent`, если 1С сообщила ссылку (в деталях), иначе результат неизвестен.
          const details = (e.details ?? {}) as Record<string, unknown>;
          const ref = str(details.ref);
          if (ref && UUID_RE.test(ref)) {
            return {
              kind: 'sent',
              onecRef: ref,
              onecNumber: str(details.number),
              onecStatus: str(details.status),
              response: { duplicate: true, ...details },
            };
          }
          return { kind: 'transient', message: `POS_E_DUPLICATE без ref: ${message}` };
        }
        if (kind === 'rejected') {
          return {
            kind: 'rejected',
            message,
            response: { code: e.code, message: e.message, details: e.details ?? null },
          };
        }
        if (kind === 'fatal') return { kind: 'fatal', message };
        return { kind: 'transient', message };
      }
      return { kind: 'transient', message: e instanceof Error ? e.message : String(e) };
    }
    const body = res.body ?? {};
    const ref = str(body.ref);
    if (!ref || !UUID_RE.test(ref)) {
      return { kind: 'transient', message: `ответ 1С ${res.status} без ref — результат неизвестен` };
    }
    return {
      kind: 'sent',
      onecRef: ref,
      onecNumber: str(body.number),
      onecStatus: str(body.status),
      response: body,
    };
  }

  /** Хвост до включения записи: первая попытка, ошибок не было, возраст больше `parkStaleAfterMs`. */
  private isStaleBacklog(row: OutboxRow): boolean {
    const limit = this.opts.parkStaleAfterMs;
    if (limit === undefined || limit <= 0 || row.ageMs === undefined) return false;
    return row.attempts <= 1 && (row.lastErrorCode ?? null) === null && row.ageMs > limit;
  }

  /**
   * Только по `orderCustomerPhone` (ОС_API) и только пустые поля (сохранённый payload не меняется):
   * `customer.phone` — телефон клиента POS (поиск покупателя 1С), `delivery.desiredDate` — дата доставки заказа
   * (`shipmentDate` черновика без интервала доставки).
   */
  private withOrderExtras(payload: OnecJsonObject, row: OutboxRow): OnecJsonObject {
    if (!this.needsOrderCustomerPhone) return payload;
    let out = payload;
    const phone = row.customerPhone;
    const customer = (out.customer ?? {}) as Record<string, OnecJsonObject[string]>;
    if (phone && !(typeof customer.phone === 'string' && customer.phone !== '')) {
      out = { ...out, customer: { ...customer, phone } };
    }
    const date = row.deliveryDate;
    const delivery = out.delivery;
    if (date && typeof delivery === 'object' && delivery !== null && !Array.isArray(delivery)) {
      const d = delivery as Record<string, OnecJsonObject[string]>;
      if (!(typeof d.desiredDate === 'string' && d.desiredDate !== '')) {
        out = { ...out, delivery: { ...d, desiredDate: date } };
      }
    }
    return out;
  }
}

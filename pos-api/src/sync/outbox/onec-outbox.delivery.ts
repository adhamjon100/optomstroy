import type { OutboxDeliveryPort, OutboxDeliveryResult, OutboxRow } from '../../jobs/outbox/outbox-delivery.port.js';
import { isOnecError } from '../../integrations/onec/onec-error.js';
import type { OnecGateway, OnecJsonObject, OnecResult } from '../../integrations/onec/onec-gateway.js';
import { classifyOnecResult } from '../../sales-domain/outbox/outbox-status.js';
import { deliverCustomerCreate } from './customer-outbox.route.js';

export interface OnecOutboxDeliveryOptions {
  /** Таймаут одного вызова 1С (мс): по истечении — временная ошибка, строка остаётся `pending` (ядро §22.1). */
  readonly timeoutMs: number;
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

  constructor(
    private readonly gateway: OnecGateway,
    private readonly opts: OnecOutboxDeliveryOptions,
  ) {}

  async deliver(row: OutboxRow): Promise<OutboxDeliveryResult> {
    const payload = (row.payload ?? {}) as OnecJsonObject;
    const signal = AbortSignal.timeout(this.opts.timeoutMs);
    const callOpts = { signal, requestId: row.id };
    let res: OnecResult<OnecJsonObject>;
    try {
      const route = `${row.aggregateType}/${row.operation}`;
      switch (route) {
        case 'order/create':
          res = await this.gateway.createOrder(
            withDependencyCustomer({ ...payload, externalId: row.externalId }, row.dependencyCustomer),
            callOpts,
          );
          break;
        case 'order/cancel':
          res = await this.gateway.cancelOrder(row.externalId, payload, callOpts);
          break;
        case 'payment/create':
          res = await this.gateway.createPayment({ ...payload, externalId: row.externalId }, callOpts);
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
}

import type { OutboxDeliveryResult, OutboxRow } from '../../jobs/outbox/outbox-delivery.port.js';
import { isOnecError } from '../../integrations/onec/onec-error.js';
import type { OnecCallOptions, OnecGateway, OnecJsonObject } from '../../integrations/onec/onec-gateway.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Маршрут outbox `customer/create` → `POST /pos/v1/customers` (05 §6.4 ONEC-045, ONEC-046; SYNC-049; RM-G-001):
 * 201 (создан) и 200 (повтор того же `externalId`, `created=false`) → `sent` с Ref партнёра (`onecNumber` — код
 * клиента 1С); `409 POS_E_DUPLICATE` (найден **другой** клиент с тем же телефоном, 05 §6.5) — бизнес-отказ
 * `rejected` → `failed` без автоповтора, кандидаты 1С — в `onec_response.details`. Прочие ошибки классифицирует
 * общий канал (`OnecOutboxDelivery`: таймаут/5xx — `transient`, 401/403 — `fatal`, данные — `rejected`).
 * Ответ 2xx без `ref` — результат неизвестен (`transient`).
 */
export async function deliverCustomerCreate(
  gateway: OnecGateway,
  row: OutboxRow,
  payload: OnecJsonObject,
  opts: OnecCallOptions,
): Promise<OutboxDeliveryResult> {
  try {
    const res = await gateway.createCustomer({ ...payload, externalId: row.externalId }, opts);
    const body = res.body ?? {};
    const ref = typeof body.ref === 'string' ? body.ref : null;
    if (!ref || !UUID_RE.test(ref)) {
      return { kind: 'transient', message: `ответ 1С ${res.status} без ref — результат неизвестен` };
    }
    return {
      kind: 'sent',
      onecRef: ref.toLowerCase(),
      onecNumber: typeof body.code === 'string' ? body.code : null,
      onecStatus: null,
      response: body,
    };
  } catch (e) {
    if (isOnecError(e) && e.code === 'POS_E_DUPLICATE') {
      return {
        kind: 'rejected',
        message: `${e.status} ${e.code}: ${e.message}`.slice(0, 2000),
        response: { code: e.code, message: e.message, details: e.details ?? null },
      };
    }
    throw e;
  }
}

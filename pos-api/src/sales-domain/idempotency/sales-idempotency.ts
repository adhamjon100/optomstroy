import { createHash } from 'node:crypto';
import { canonicalJson } from '../../common/idempotency/fingerprint.js';

/**
 * Идемпотентность операций этапа F (08 §2.7 — владелец перечня; ядро §22.6; 07 §8.1, DATA-263). Серверная часть —
 * существующий механизм этапа C (`@Idempotent`, `IdempotencyInterceptor`, таблица `idempotency_keys`, 24 ч, скоуп
 * `(key, user:<id>, route)`): здесь — только правила домена продаж поверх него.
 *
 * Хранение ключа на клиенте (ядро §22.6): ключ `POST /orders` — в `checkout_draft.order_idempotency_key` (drift),
 * на сервере дополнительно бессрочно в `orders.idempotency_key` (поиск `GET /orders?idempotencyKey=`); ключи
 * платежей (`POST /orders/{id}/payments`, `confirm-manual`, `void`) — **только в памяти** клиента, после
 * перезапуска приём денег автоматически не повторяется.
 */

/** Маршруты этапа F с обязательным `Idempotency-Key` (выдержка из 08 §2.7 «Где обязателен»). */
export const F_IDEMPOTENCY_REQUIRED_ROUTES = [
  'POST /orders',
  'POST /orders/{id}/cancel',
  'POST /orders/{id}/payments',
  'POST /orders/{id}/onec-link',
  'POST /payments/{id}/confirm-manual',
  'POST /payments/{id}/void',
  'POST /cart/park',
  /** Только при `mode=increment` (`requiredWhen`). */
  'PUT /cart/items/{variantId}',
] as const;

/** Где хранит ключ клиент (ядро §22.6) — справочно для клиентских агентов и тестов. */
export const CLIENT_KEY_STORAGE: Readonly<Record<string, 'checkout_draft' | 'memory'>> = {
  'POST /orders': 'checkout_draft',
  'POST /orders/{id}/cancel': 'memory',
  'POST /orders/{id}/payments': 'memory',
  'POST /orders/{id}/onec-link': 'memory',
  'POST /payments/{id}/confirm-manual': 'memory',
  'POST /payments/{id}/void': 'memory',
};

/**
 * `payments.idempotency_key` (NOT NULL, UNIQUE с `created_by_user_id`) начального платежа, созданного в транзакции
 * `POST /orders`: производный от ключа заказа, чтобы не пересечься с ключом последующего `POST /orders/{id}/payments`
 * (FQ-BASE-05).
 */
export function initialPaymentIdempotencyKey(orderIdempotencyKey: string): string {
  return `order:${orderIdempotencyKey}`;
}

/** Окно «мягкой защиты от дубля» `POST /orders` (08 §2.7; POS-021 [НЕ ПОДТВЕРЖДЕНО — 60 с]). */
export const SOFT_DUPLICATE_WINDOW_MS = 60_000;

export interface OrderCompositionInput {
  readonly customerId: string | null;
  readonly paymentMethod: string;
  /** Итог строкой `Money` (`"16007.50"`). */
  readonly total: string;
  readonly items: readonly {
    readonly variantId: string;
    readonly packagingId: string | null;
    readonly quantity: string;
  }[];
}

/** Хэш состава заказа (позиции + клиент + сумма) для мягкой защиты от дубля; порядок строк не влияет. */
export function orderCompositionHash(c: OrderCompositionInput): string {
  const items = [...c.items]
    .map((i) => ({ v: i.variantId, p: i.packagingId, q: i.quantity }))
    .sort((a, b) => (a.v + (a.p ?? '') < b.v + (b.p ?? '') ? -1 : 1));
  return createHash('sha256')
    .update(canonicalJson({ c: c.customerId, m: c.paymentMethod, t: c.total, items }), 'utf8')
    .digest('hex');
}

/** Дубль: тот же хэш состава у успешного заказа того же пользователя в пределах окна, без `confirmDuplicate`. */
export function isSoftDuplicate(
  previous: { readonly compositionHash: string; readonly createdAt: Date } | null,
  currentHash: string,
  now: Date,
  confirmDuplicate: boolean,
): boolean {
  if (confirmDuplicate || !previous) return false;
  return (
    previous.compositionHash === currentHash && now.getTime() - previous.createdAt.getTime() <= SOFT_DUPLICATE_WINDOW_MS
  );
}

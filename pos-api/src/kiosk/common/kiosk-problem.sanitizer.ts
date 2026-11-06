import { ProblemException, type ProblemInit } from '../../common/problem-details/problem.exception.js';
import { toProblemException } from '../../sales-domain/problem.js';

/**
 * Очистка ответов-ошибок планшету магазина (08 §2.4 «Коды и отказы планшета магазина» п. 3, §4.25.2; 11 SEC-141;
 * P-002 §8.4 п. 5, §8.5 п. 7, §12; ADR-115). Применяется ко всем маршрутам планшета, которые отдают Problem (08 §2.4
 * п. 3; 11 SEC-141): `POST /kiosk/orders` (`KioskOrderService`), `PUT`/`DELETE /cart/items/{variantId}` и
 * `POST /cart/checkout-preview` (`CartController`, только `kind=kiosk`). Применяется **до** выхода ошибки из
 * обработчика: интерсептор идемпотентности сохраняет тела `404`/`409`/`422` под ключом
 * (`idempotency.interceptor.ts`), поэтому фильтр исключений для этого поздно. Правило — отказ по умолчанию: из расширений Problem остаются только
 * перечисленные ниже, остальное (`current`, `onec`, суммы, `possibleDuplicate*`, `currentStatus`, `allowedActions`…)
 * на планшет не попадает.
 * - `conflicts[]` любого кода — только `variantId`, `kind`, `stockLevel` (без `oldPrice`, `newPrice`, `available`,
 *   `requested`, `factor`): цена соглашения карточки и количества на складе на экран у входа не выходят;
 * - `409 VERSION_CONFLICT` — без `current` (полная корзина, `CartService.assertVersion`);
 * - `422 ONEC_REJECTED` — без `onec` и без текста 1С: причина может касаться долга клиента; на планшете — нейтральный
 *   текст, причина — кассиру в SCR-24;
 * - `409 DEVICE_MISMATCH` (код с другого планшета) → `404 NOT_FOUND`: этот ответ приложение считает концом своей
 *   сессии (`pos-app/lib/core/network/interceptors/auth_interceptor.dart`);
 * - `409 ORDER_STATE_INVALID` (корзина `cartId` уже не активная корзина планшета; `possible_duplicate` для канала
 *   `kiosk` не возникает — ORD-022 пропущен) → `422 CART_EMPTY` (08 §2.4 строка `CART_EMPTY`).
 * Ошибки не Problem (программные, 500) возвращаются без изменений — их тело и так `INTERNAL` без подробностей.
 */

/** Нейтральный текст отказа 1С (08 §4.25.2; 02 SCR-52 `kiosk_order_failed`). */
export const KIOSK_ONEC_REJECTED_DETAIL = 'Заявку не удалось отправить. Обратитесь к продавцу.';

/** Поля элемента `conflicts[]`, которые получает планшет. */
export const KIOSK_CONFLICT_FIELDS = ['variantId', 'kind', 'stockLevel'] as const;

/**
 * Расширения Problem, которые получает планшет: `errors` (400 тела), `conflicts` (очищенные), `retryAfter`
 * (`OTP_LOCKED`, `IDEMPOTENCY_IN_PROGRESS`), `attemptsLeft` (`OTP_INVALID`), `reason` (`PRICE_CHANGED preview_*`,
 * `FORBIDDEN kiosk_warehouse_unavailable`).
 */
const ALLOWED_EXTENSIONS: ReadonlySet<string> = new Set([
  'errors',
  'conflicts',
  'retryAfter',
  'attemptsLeft',
  'reason',
]);

/** Элемент `conflicts[]` для планшета: только `variantId`, `kind` и (у нехватки остатка) `stockLevel`. */
export function sanitizeKioskConflict(conflict: unknown): Record<string, unknown> {
  if (typeof conflict !== 'object' || conflict === null || Array.isArray(conflict)) return {};
  const c = conflict as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const f of KIOSK_CONFLICT_FIELDS) if (c[f] !== undefined) out[f] = c[f];
  return out;
}

/** Ошибка для ответа планшету (доменная ошибка продаж сначала становится Problem). */
export function sanitizeKioskProblem(error: unknown): unknown {
  const e = toProblemException(error);
  if (!(e instanceof ProblemException)) return e;
  switch (e.code) {
    case 'DEVICE_MISMATCH':
      return new ProblemException('NOT_FOUND', { detail: 'Код не найден. Запросите новый.' });
    case 'ORDER_STATE_INVALID':
      return new ProblemException('CART_EMPTY', { detail: 'Корзина пуста.' });
    case 'ONEC_REJECTED':
      return new ProblemException('ONEC_REJECTED', { detail: KIOSK_ONEC_REJECTED_DETAIL });
    default:
      break;
  }
  const kept: Record<string, unknown> = {};
  let changed = false;
  for (const [k, v] of Object.entries(e.extensions)) {
    if (!ALLOWED_EXTENSIONS.has(k)) {
      changed = true;
      continue;
    }
    if (k === 'conflicts' && Array.isArray(v)) {
      const clean = v.map(sanitizeKioskConflict);
      if (JSON.stringify(clean) !== JSON.stringify(v)) changed = true;
      kept[k] = clean;
      continue;
    }
    kept[k] = v;
  }
  if (!changed) return e;
  const init: ProblemInit = {
    ...kept,
    status: e.getStatus(),
    ...(e.detail !== undefined ? { detail: e.detail } : {}),
    headers: e.headers,
  };
  return new ProblemException(e.code, init);
}

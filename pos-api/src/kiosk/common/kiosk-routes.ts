import { routeKey } from '../../common/http/route-template.js';

/**
 * Закрытый список маршрутов с Bearer для субъекта `kind=kiosk` — планшета магазина (P-002 §8.3; 08 §4.25; 11 SEC-137;
 * 06 ARCH-066; ADR-115). Deny by default: всё, чего нет в списке, с токеном планшета → `403 FORBIDDEN`
 * (`reason: kiosk_closed_list`). Список права не выдаёт, он только сужает: маршрут проходит, только если он здесь
 * **и** у роли `kiosk` есть его право (`RbacGuard`, 11 §4.3.1, SEC-138).
 *
 * Запись — метод и шаблон пути контракта `contracts/openapi/pos-api.v1.yaml` без `/api/v1`; сравнение — по ключу
 * `routeKey(метод, шаблон маршрута запроса)` (параметры `:id` / `{id}` → `{}`), а не по фактическому адресу: так
 * `GET /catalog/products/recent` не совпадает с `GET /catalog/products/{id}`. Состав = операции контракта с `kiosk`
 * в `x-roles` + `GET /catalog/price-lists` (маршрут в списке, но отвечает `403`, как у `customer`, — 08 §4.25,
 * AC-API-186); сверку проводит `test/kiosk/access.spec.ts`.
 */
export const KIOSK_CLOSED_LIST = [
  // Каталог (как `customer` без привязки; `priceListId`, `warehouseId` → 403 — ветки модуля catalog).
  'GET /catalog/categories',
  'GET /catalog/price-lists',
  'GET /catalog/products',
  'GET /catalog/products/{id}',
  'GET /catalog/products/{id}/variants',
  'GET /catalog/units',
  'GET /catalog/warehouses',
  'GET /catalog/sync/{entity}',
  // Поиск (`GET /search/barcode/{value}` в список не входит — Р-15).
  'GET /search/products',
  'GET /search/suggest',
  // Наличие — только склад планшета.
  'GET /inventory/balances',
  'POST /inventory/check',
  // Корзина — только на сервере; предпросмотр — «cart.manage.own и одно из order.create | kiosk.order.submit».
  'GET /cart',
  'PUT /cart/items/{variantId}',
  'DELETE /cart/items/{variantId}',
  'POST /cart/checkout-preview',
  // Отвечают планшету и при KIOSK_MODE=false (KIOSK_DISABLED_EXEMPT).
  'GET /settings/public',
  'GET /me',
  // Операции планшета (08 §4.25.1–§4.25.5).
  'POST /kiosk/order-otp',
  'POST /kiosk/orders',
  'GET /kiosk/orders',
  'POST /kiosk/reset',
  'POST /kiosk/exit',
] as const;

/**
 * Маршруты, которые отвечают планшету и при `KIOSK_MODE=false` (08 §4.25 «Флаги»; 11 SEC-137 (4)): по ним приложение
 * показывает «Сервис временно недоступен» и узнаёт, что режим снова включён. Всё остальное, в том числе все
 * `/kiosk/*` и `POST /kiosk/exit`, — `403 KIOSK_DISABLED` (ADR-115 п. 28).
 */
export const KIOSK_DISABLED_EXEMPT = ['GET /settings/public', 'GET /me'] as const;

function keyOf(op: string): string {
  const [method = '', path = ''] = op.split(' ');
  return routeKey(method, path);
}

const CLOSED_LIST_KEYS: ReadonlySet<string> = new Set(KIOSK_CLOSED_LIST.map(keyOf));
const DISABLED_EXEMPT_KEYS: ReadonlySet<string> = new Set(KIOSK_DISABLED_EXEMPT.map(keyOf));

/**
 * Ключ маршрута запроса для сравнения со списком: метод и шаблон маршрута Express (`baseUrl` + `route.path`). Нет
 * шаблона (`req.route` не определён) — `null`: такой запрос в список не входит (fail-closed; 08 §4.25 п. (3)).
 */
export function kioskRouteKeyOf(req: {
  readonly method?: string;
  readonly baseUrl?: string;
  readonly route?: { readonly path?: unknown };
}): string | null {
  const template = req.route?.path;
  if (typeof template !== 'string' || typeof req.method !== 'string') return null;
  return routeKey(req.method, `${req.baseUrl ?? ''}${template}`);
}

/** Маршрут в закрытом списке планшета (ключ — `kioskRouteKeyOf`; `null` — нет). */
export function isKioskClosedListRoute(key: string | null): boolean {
  return key !== null && CLOSED_LIST_KEYS.has(key);
}

/** Маршрут отвечает планшету и при `KIOSK_MODE=false` (`GET /settings/public`, `GET /me`). */
export function isKioskDisabledExempt(key: string | null): boolean {
  return key !== null && DISABLED_EXEMPT_KEYS.has(key);
}

import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { resolvePriceListId } from '../sales-domain/index.js';
import { rows } from './cart-common.js';
import type { CartRow } from './cart.repository.js';

/**
 * Цена заявки с планшета магазина по найденной карточке (Р-05 (а); 10 KIOSK-015, INV-030; 08 §3.6 «Цены и остатки для
 * планшета», §4.25.2; P-002 §8.4 п. 5; ADR-115 п. 5) — простые функции модуля `cart` без провайдера Nest.
 *
 * Вид цены карточки выбирает сервер **без** `pricing.resolveFor`: ветка покупателя там требует подтверждённой привязки
 * (у технического пользователя планшета её нет и быть не должно), ветка сотрудника — роль в `price_lists.visible_to_roles`
 * (роли `kiosk` там нет). Правило — как у покупателя со своей карточкой: вид цены карточки
 * (`customers.default_price_list_id`; карточка и вид цены не помечены на удаление) без учёта `visible_to_roles`, иначе
 * вид цены по умолчанию (`price_lists.is_default`), иначе розничный («Розничн…»).
 */
export async function kioskCardPriceListId(ex: DbExecutor, customerId: string): Promise<string | null> {
  const r = await rows<{ card_pl: string | null; default_pl: string | null; retail_pl: string | null }>(
    ex,
    sql`SELECT
          (SELECT pl.id FROM customers c JOIN price_lists pl ON pl.id = c.default_price_list_id AND NOT pl.deletion_mark
            WHERE c.id = ${customerId}::uuid AND NOT c.deletion_mark) AS card_pl,
          (SELECT x.id FROM price_lists x WHERE x.is_default AND NOT x.deletion_mark ORDER BY x.sort_order, x.id LIMIT 1) AS default_pl,
          (SELECT x.id FROM price_lists x WHERE NOT x.deletion_mark AND lower(x.name) LIKE 'розничн%'
            ORDER BY x.sort_order, x.name, x.id LIMIT 1) AS retail_pl`,
  );
  const row = r[0];
  if (!row) return null;
  return resolvePriceListId({
    isCustomerMode: false,
    linkConfirmed: false,
    customerPriceListId: row.card_pl,
    customerPriceListVisible: true,
    defaultPriceListId: row.default_pl,
    retailPriceListId: row.retail_pl,
  }).id;
}

/**
 * Корзина планшета «как корзина найденного клиента» — **только в памяти** (10 KIOSK-015; P-002 §8.4 п. 5.2–5.3): та же
 * строка `carts` (id, `row_version`, склад, строки), но `customer_id` — карточка, `price_list_id` — вид цены карточки.
 * Её получают пересчёт цен и скидки клиента 1С, проверка наличия, синхронный `/check` 1С и снимок для `order_items`;
 * в БД ничего не пишется — `GET /cart` планшета остаётся с обычной ценой и без клиента. Вид цены не найден (реплика
 * без видов цен) — прежний вид цены корзины.
 */
export async function kioskCardCart(ex: DbExecutor, cart: CartRow, customerId: string): Promise<CartRow> {
  const priceListId = (await kioskCardPriceListId(ex, customerId)) ?? cart.price_list_id;
  return { ...cart, customer_id: customerId, price_list_id: priceListId };
}

/**
 * Выбор вида цены корзины (10 INV-030, CUST-021; 08 §3.6). Каталог этапа E применяет то же правило к экранам
 * каталога (`CatalogViewerService.priceListFor`); здесь — чистая функция для корзины и заказа, где клиент — это
 * клиент корзины (`carts.customer_id`), а не «активная корзина пользователя».
 *
 * - `customer` (режим клиента): вид цены карточки 1С — только при подтверждённой привязке; иначе по умолчанию;
 * - `staff`: вид цены выбранного клиента корзины (`customers.default_price_list_id`), иначе по умолчанию;
 * - «по умолчанию» = `price_lists.is_default`, а если его нет — розничный («Розничн…», EQ-CAT-03);
 * - выбранный вид цены должен быть видим роли (`visible_to_roles`) — иначе берётся вид цены по умолчанию.
 */
export interface PriceListCandidates {
  readonly isCustomerMode: boolean;
  /** Привязка клиента-пользователя подтверждена (`customer_links.status='confirmed'`). */
  readonly linkConfirmed: boolean;
  /** Вид цены клиента корзины (`customers.default_price_list_id`), если клиент выбран и не удалён. */
  readonly customerPriceListId: string | null;
  /** Виден ли вид цены клиента роли пользователя. */
  readonly customerPriceListVisible: boolean;
  readonly defaultPriceListId: string | null;
  readonly retailPriceListId: string | null;
}

export type PriceListSource = 'customer' | 'default' | 'retail' | 'none';

export function resolvePriceListId(c: PriceListCandidates): { id: string | null; source: PriceListSource } {
  const customerAllowed = c.isCustomerMode ? c.linkConfirmed : true;
  if (customerAllowed && c.customerPriceListId && c.customerPriceListVisible) {
    return { id: c.customerPriceListId, source: 'customer' };
  }
  if (c.defaultPriceListId) return { id: c.defaultPriceListId, source: 'default' };
  if (c.retailPriceListId) return { id: c.retailPriceListId, source: 'retail' };
  return { id: null, source: 'none' };
}

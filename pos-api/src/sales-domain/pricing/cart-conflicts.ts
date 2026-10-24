import type { Money, Quantity } from '../../common/money/money.js';

/**
 * Конфликты строк при пересчёте корзины (`checkout-preview`, `POST /orders`; 08 §3.8 `CartConflict`, 10 CART-,
 * INV-040…INV-052): все найденные конфликты — одним ответом (ядро §19.2). Чистая функция над данными каталога.
 */
export type CartConflictKind =
  'price_changed' | 'stock_insufficient' | 'variant_unavailable' | 'qty_not_multiple' | 'qty_below_min';

export interface ConflictLineInput {
  readonly variantId: string;
  /** `cart_items.price_snapshot`. */
  readonly priceSnapshot: Money;
  /** Текущая цена по виду цены корзины; `null` — цены нет (вариант недоступен). */
  readonly currentPrice: Money | null;
  /** Вариант снят с продажи / помечен на удаление. */
  readonly unavailable: boolean;
  /** Запрошено в базовых единицах. */
  readonly requestedBase: Quantity;
  /** Доступно на складе корзины; `null` — остаток неизвестен (добавление запрещено, INV-052). */
  readonly available: Quantity | null;
  /** Кратность в базовых единицах (`Variant.multiplicity`), `null` — нет. */
  readonly multiplicity: string | null;
  /** Минимальная партия в базовых единицах, `null` — нет. */
  readonly minQty: Quantity | null;
}

export interface CartLineConflict {
  readonly variantId: string;
  readonly kind: CartConflictKind;
  readonly oldPrice?: Money;
  readonly newPrice?: Money;
  readonly requested?: Quantity;
  readonly available?: Quantity | null;
}

export function detectLineConflicts(lines: readonly ConflictLineInput[]): CartLineConflict[] {
  const out: CartLineConflict[] = [];
  for (const l of lines) {
    if (l.unavailable || l.currentPrice === null) {
      out.push({ variantId: l.variantId, kind: 'variant_unavailable' });
      continue;
    }
    if (!l.currentPrice.equals(l.priceSnapshot)) {
      out.push({ variantId: l.variantId, kind: 'price_changed', oldPrice: l.priceSnapshot, newPrice: l.currentPrice });
    }
    if (l.available === null || l.requestedBase.compare(l.available) > 0) {
      out.push({
        variantId: l.variantId,
        kind: 'stock_insufficient',
        requested: l.requestedBase,
        available: l.available,
      });
    }
    if (l.multiplicity !== null && !l.requestedBase.isMultipleOf(l.multiplicity)) {
      out.push({ variantId: l.variantId, kind: 'qty_not_multiple', requested: l.requestedBase });
    }
    if (l.minQty !== null && l.requestedBase.compare(l.minQty) < 0) {
      out.push({ variantId: l.variantId, kind: 'qty_below_min', requested: l.requestedBase });
    }
  }
  return out;
}

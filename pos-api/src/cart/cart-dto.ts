import type { CartActor } from './cart-actor.js';
import { iso, moneyDto } from './cart-common.js';
import { cartItemDto, conflictDto, type EvaluatedCart, type EvaluatedLine, storedConflicts } from './cart-evaluator.js';

/**
 * DTO `Cart` (08 §3.8; OpenAPI `Cart`): полная корзина с пересчитанными сервером итогами и `warnings[]`
 * (`CartConflict`). `customer` — ролевое представление без сумм долга; `receiver` — получатель (0009).
 */
export function cartDto(
  e: EvaluatedCart,
  a: CartActor,
  opts: { readonly customer: Record<string, unknown> | null; readonly revalidate?: boolean },
): Record<string, unknown> {
  const c = e.cart;
  const revalidate = opts.revalidate !== false;
  const lineOf = new Map<string, EvaluatedLine>();
  for (const l of e.lines) if (!lineOf.has(l.item.variant_id)) lineOf.set(l.item.variant_id, l);
  const conflicts = revalidate ? e.conflicts : storedConflicts(e.lines);
  return {
    id: c.id,
    status: c.status,
    name: c.name,
    ownerId: c.owner_user_id,
    customer: opts.customer,
    receiver: {
      kind: c.receiver_kind,
      name: c.receiver_name,
      phone: c.receiver_phone_e164,
    },
    warehouseId: c.warehouse_id,
    priceListId: c.price_list_id,
    items: e.lines.map((l) => cartItemDto(l, a, revalidate)),
    itemsCount: e.lines.length,
    unitsCount: e.unitsCount,
    subtotal: moneyDto(e.priced.subtotal.toString()),
    requestedDiscountPercent: e.discount.requested,
    appliedDiscountPercent: e.discount.applied,
    discountTotal: moneyDto(e.priced.discountTotal.toString()),
    customerDiscountPercent: e.customerDiscountPercent,
    total: moneyDto(e.priced.total.toString()),
    discountLimitPercent: e.discount.limit,
    warnings: conflicts.map((k) => conflictDto(k, lineOf.get(k.variantId), a)),
    restoredFromOrderId: c.restored_from_order_id,
    restoredFromOrder: restoredFromOrderDto(c),
    rowVersion: c.row_version,
    parkedAt: iso(c.parked_at),
    expiresAt: iso(c.expires_at),
    audit: {
      createdAt: iso(c.created_at),
      updatedAt: iso(c.updated_at),
      rowVersion: c.row_version,
    },
  };
}

/** `CartParkedSummary` (OpenAPI): корзина без `items` + владелец. */
export function parkedSummaryDto(
  e: EvaluatedCart,
  owner: { id: string; displayName: string; role?: string },
  customer: Record<string, unknown> | null,
): Record<string, unknown> {
  const c = e.cart;
  return {
    id: c.id,
    status: c.status,
    name: c.name,
    ownerId: c.owner_user_id,
    owner,
    customer,
    warehouseId: c.warehouse_id,
    priceListId: c.price_list_id,
    itemsCount: e.lines.length,
    unitsCount: e.unitsCount,
    subtotal: moneyDto(e.priced.subtotal.toString()),
    discountTotal: moneyDto(e.priced.discountTotal.toString()),
    total: moneyDto(e.priced.total.toString()),
    restoredFromOrderId: c.restored_from_order_id,
    rowVersion: c.row_version,
    parkedAt: iso(c.parked_at),
    expiresAt: iso(c.expires_at),
    audit: { createdAt: iso(c.created_at), updatedAt: iso(c.updated_at), rowVersion: c.row_version },
  };
}

/**
 * `Cart.restoredFromOrder` (OpenAPI 1.2.0; 08 §3.8 «Уточнения CheckoutPreview и Cart» п. 4; FQ-CART-05 (fe)): номер
 * заказа POS и причина отказа 1С (`orders.submit_error_message`, текст без внутренних данных — как `Order.submitError`)
 * для баннера `cart_banner_restored_from_order`; `null` — корзина не восстановлена из заказа.
 */
export function restoredFromOrderDto(c: {
  readonly restored_from_order_id: string | null;
  readonly restored_order_number?: string | null;
  readonly restored_order_reason?: string | null;
}): { readonly number: string; readonly reason: string | null } | null {
  if (!c.restored_from_order_id || !c.restored_order_number) return null;
  return { number: c.restored_order_number, reason: c.restored_order_reason ?? null };
}

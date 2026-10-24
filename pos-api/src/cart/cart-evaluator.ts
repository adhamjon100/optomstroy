import { Money, Quantity } from '../common/money/money.js';
import {
  type CartLineConflict,
  detectLineConflicts,
  hundredthsToPercent,
  type PricedCart,
  type PricedLine,
  type PricingLineInput,
  percentToHundredths,
  priceCart,
} from '../sales-domain/index.js';
import type { CartActor } from './cart-actor.js';
import { dec, imageDto, iso, moneyDto, qty3 } from './cart-common.js';
import type { CartItemRow, CartRow } from './cart.repository.js';
import type { LineQuote } from './catalog-pricing.service.js';

/** `StockLevel` (08 §3.6): `unknown` — нет снимка остатка (добавление запрещено, 10 INV-052). */
export type StockLevel = 'in_stock' | 'low' | 'out' | 'unknown';

export function stockLevelOf(available: string | null, threshold: string): StockLevel {
  if (available === null) return 'unknown';
  const a = dec(available);
  if (a.lte(0)) return 'out';
  return a.gte(dec(threshold)) ? 'in_stock' : 'low';
}

export interface EvaluatedLine {
  readonly item: CartItemRow;
  readonly quote: LineQuote;
  /** Строка участвует в расчёте (вариант продаётся, есть цена). */
  readonly priceable: boolean;
  readonly priced: PricedLine | null;
  readonly conflicts: readonly CartLineConflict[];
  /** Σ base_quantity варианта во всех строках корзины. */
  readonly variantBase: string;
  /** `available − Σ base` (≥ 0), `null` — остаток неизвестен (08 §3.8 `remainingAvailable`). */
  readonly remaining: string | null;
}

export interface DiscountState {
  /** `carts.requested_discount_percent` (канонический `"5.00"`). */
  readonly requested: string;
  /** Применённый процент (в лимите роли или подтверждённый сверх лимита). */
  readonly applied: string;
  /** Лимит роли владельца корзины (`Cart.discountLimitPercent`). */
  readonly limit: string;
  readonly approved: boolean;
}

export interface EvaluatedCart {
  readonly cart: CartRow;
  readonly lines: readonly EvaluatedLine[];
  readonly priced: PricedCart;
  readonly conflicts: readonly CartLineConflict[];
  readonly discount: DiscountState;
  readonly customerDiscountPercent: string;
  readonly unitsCount: string;
}

/**
 * Применённая ручная скидка корзины: запрошенная, если она в лимите роли или подтверждена сверх лимита
 * (`discount_approved_by_user_id`, 10 DISC-010), иначе — лимит роли (окончательная проверка — `checkManualDiscount`
 * при `checkout-preview`/`POST /orders`). Клиенту-покупателю ручная скидка недоступна (CUST-021).
 */
export function discountStateOf(cart: CartRow, limitPercent: string, isCustomer: boolean): DiscountState {
  const requested = hundredthsToPercent(percentToHundredths(cart.requested_discount_percent));
  const limit = hundredthsToPercent(percentToHundredths(limitPercent));
  if (isCustomer) return { requested: '0.00', applied: '0.00', limit: '0.00', approved: false };
  const approved = cart.discount_approved_by_user_id !== null;
  const within = percentToHundredths(requested) <= percentToHundredths(limit);
  return { requested, applied: within || approved ? requested : limit, limit, approved };
}

/**
 * Пересчёт корзины сервером (D-23): цены строк — по виду цены корзины (котировки каталога), скидки — движок
 * `priceCart` (двухэтапная, распределение с коррекцией последней строки, 07 §7.3), конфликты — `detectLineConflicts`
 * (10 CART-013…015, INV-042, INV-052): нехватка считается по Σ базовых количеств варианта во всех строках
 * (упаковках) корзины. Строки без цены или снятые с продажи в итог не входят (они — `variant_unavailable`).
 */
export function evaluateCart(i: {
  readonly cart: CartRow;
  readonly items: readonly CartItemRow[];
  readonly quotes: readonly LineQuote[];
  readonly discount: DiscountState;
  readonly customerDiscountPercent: string | null;
  readonly cashRounding?: 'none' | 'to_som';
  /** Применённый процент для расчёта (по умолчанию `discount.applied`). */
  readonly manualPercentOverride?: string;
}): EvaluatedCart {
  const byVariant = new Map<string, ReturnType<typeof dec>>();
  for (const it of i.items)
    byVariant.set(it.variant_id, (byVariant.get(it.variant_id) ?? dec('0')).plus(dec(it.base_quantity)));
  const pricingLines: PricingLineInput[] = [];
  const prelim: { item: CartItemRow; quote: LineQuote; priceable: boolean; conflicts: CartLineConflict[] }[] = [];
  i.items.forEach((item, idx) => {
    const quote = i.quotes[idx];
    if (!quote) throw new Error(`cart: нет котировки строки ${item.line_no}`);
    const priceable = quote.sellable && quote.unitPrice !== null;
    const totalBase = byVariant.get(item.variant_id) ?? dec(item.base_quantity);
    const otherBase = totalBase.minus(dec(item.base_quantity));
    // Доступно «для этой строки» = остаток − база других строк варианта: requested > этого ⇔ Σ > остатка.
    let availableForLine: Quantity | null = null;
    if (quote.available !== null) {
      const v = dec(quote.available).minus(otherBase);
      availableForLine = Quantity.of(v.lte(0) ? '0' : v.toFixed(3));
    }
    const conflicts = detectLineConflicts([
      {
        variantId: item.variant_id,
        priceSnapshot: Money.of(item.price_snapshot),
        currentPrice: priceable && quote.unitPrice !== null ? Money.of(quote.unitPrice) : null,
        unavailable: !quote.sellable,
        requestedBase: Quantity.of(item.base_quantity),
        available: availableForLine,
        multiplicity: quote.multiplicity,
        minQty: quote.minQty !== null ? Quantity.of(quote.minQty) : null,
      },
    ]).map((c) =>
      c.kind === 'stock_insufficient'
        ? {
            ...c,
            requested: Quantity.of(totalBase.toFixed(3)),
            available: quote.available === null ? null : Quantity.of('0'),
          }
        : c,
    );
    prelim.push({ item, quote, priceable, conflicts });
    if (priceable && quote.unitPrice !== null) {
      pricingLines.push({
        lineNo: item.line_no,
        variantId: item.variant_id,
        packagingId: item.packaging_id,
        quantity: Quantity.of(item.quantity),
        unitPrice: Money.of(quote.unitPrice),
      });
    }
  });
  const priced = priceCart({
    lines: pricingLines,
    customerDiscountPercent: i.customerDiscountPercent,
    manualDiscountPercent: i.manualPercentOverride ?? i.discount.applied,
    ...(i.cashRounding ? { cashRounding: i.cashRounding } : {}),
  });
  const pricedByLine = new Map(priced.lines.map((l) => [l.lineNo, l]));
  const lines: EvaluatedLine[] = prelim.map((p) => {
    const totalBase = byVariant.get(p.item.variant_id) ?? dec(p.item.base_quantity);
    const remaining =
      p.quote.available === null
        ? null
        : (() => {
            const v = dec(p.quote.available).minus(totalBase);
            return qty3(v.lte(0) ? '0' : v.toFixed(3));
          })();
    return {
      item: p.item,
      quote: p.quote,
      priceable: p.priceable,
      priced: pricedByLine.get(p.item.line_no) ?? null,
      conflicts: p.conflicts,
      variantBase: qty3(totalBase.toFixed(3)),
      remaining,
    };
  });
  // Нехватка по варианту — один конфликт на вариант (а не на каждую упаковку).
  const conflicts: CartLineConflict[] = [];
  const stockSeen = new Set<string>();
  for (const l of lines) {
    for (const c of l.conflicts) {
      if (c.kind === 'stock_insufficient') {
        if (stockSeen.has(c.variantId)) continue;
        stockSeen.add(c.variantId);
      }
      conflicts.push(c);
    }
  }
  const unitsCount = qty3([...byVariant.values()].reduce((a, b) => a.plus(b), dec('0')).toFixed(3));
  return {
    cart: i.cart,
    lines,
    priced,
    conflicts,
    discount: i.discount,
    customerDiscountPercent: priced.customerDiscountPercent,
    unitsCount,
  };
}

export interface CartConflictDto {
  readonly variantId: string;
  readonly kind: CartLineConflict['kind'];
  readonly oldPrice?: ReturnType<typeof moneyDto> | null;
  readonly newPrice?: ReturnType<typeof moneyDto> | null;
  readonly requested?: { value: string; unitId: string; baseValue: string } | null;
  readonly available?: string | null;
  readonly stockLevel?: StockLevel;
  readonly factor?: string | null;
}

/**
 * `CartConflict` по роли (08 §3.8, §3.6; 10 CUST-022): `customer` при `customer_stock_display=status` — без
 * количеств (`available` отсутствует, только `stockLevel`).
 */
export function conflictDto(c: CartLineConflict, line: EvaluatedLine | undefined, a: CartActor): CartConflictDto {
  const out: Record<string, unknown> = { variantId: c.variantId, kind: c.kind };
  const quote = line?.quote;
  if (c.kind === 'price_changed') {
    out.oldPrice = c.oldPrice ? moneyDto(c.oldPrice.toString()) : null;
    out.newPrice = c.newPrice ? moneyDto(c.newPrice.toString()) : null;
  }
  if (c.kind === 'stock_insufficient' || c.kind === 'qty_not_multiple' || c.kind === 'qty_below_min') {
    const base = c.kind === 'stock_insufficient' ? (line?.variantBase ?? '0') : qty3(line?.item.base_quantity ?? '0');
    if (a.stockDisplay !== 'status' || c.kind !== 'stock_insufficient') {
      out.requested = { value: base, unitId: quote?.baseUnitId ?? '', baseValue: base };
    }
  }
  if (c.kind === 'stock_insufficient') {
    const available = quote?.available ?? null;
    if (a.stockDisplay !== 'status') out.available = available === null ? null : qty3(available);
    out.stockLevel = stockLevelOf(available, a.lowStockThreshold);
  }
  if (c.kind === 'qty_not_multiple')
    out.factor = quote?.multiplicity !== null && quote?.multiplicity !== undefined ? qty3(quote.multiplicity) : null;
  if (c.kind === 'qty_below_min') out.factor = quote?.minQty ? qty3(quote.minQty) : null;
  return out as unknown as CartConflictDto;
}

const ITEM_WARNINGS = new Set(['price_changed', 'stock_insufficient', 'variant_unavailable', 'qty_not_multiple']);

/** `CartItem` (08 §3.8; поля ядра §19.2 `remainingAvailable`; остатки клиенту — по CUST-022). */
export function cartItemDto(l: EvaluatedLine, a: CartActor, warnings: boolean): Record<string, unknown> {
  const q = l.quote;
  const it = l.item;
  const image = imageDto(q.imageSha, q.imageWidth, q.imageHeight);
  const out: Record<string, unknown> = {
    variantId: it.variant_id,
    productId: q.productId,
    productName: q.productName,
    ...(q.variantName ? { variantName: q.variantName } : {}),
    ...(q.sku ? { sku: q.sku } : {}),
    ...(image ? { image } : {}),
    quantity: {
      value: qty3(it.quantity),
      unitId: q.unitId,
      packagingId: it.packaging_id,
      baseValue: qty3(it.base_quantity),
    },
    ...(q.packaging
      ? {
          packaging: {
            id: q.packaging.id,
            unitId: q.packaging.unitId,
            name: q.packaging.name,
            factor: q.packaging.factor,
            isDefault: q.packaging.isDefault,
            allowFraction: q.packaging.allowFraction,
            barcode: q.packaging.barcode,
          },
        }
      : {}),
    ...(l.priceable && q.unitPrice !== null ? { unitPrice: moneyDto(q.unitPrice) } : {}),
    priceSnapshot: moneyDto(it.price_snapshot),
    ...(l.priced
      ? {
          lineTotal: moneyDto(l.priced.lineTotal.toString()),
          lineDiscount: moneyDto(l.priced.discountAmount.toString()),
        }
      : {}),
    warnings: warnings ? [...new Set(l.conflicts.map((c) => c.kind).filter((k) => ITEM_WARNINGS.has(k)))] : [],
    addedAt: iso(it.added_at),
  };
  if (a.stockDisplay !== 'status') {
    if (q.available !== null) out.available = qty3(q.available);
    out.remainingAvailable = l.remaining;
  }
  return out;
}

/** Флаги строк из сохранённой сверки (`GET /cart?revalidate=false`): без сравнения с текущими ценами. */
export function storedConflicts(lines: readonly EvaluatedLine[]): CartLineConflict[] {
  const out: CartLineConflict[] = [];
  for (const l of lines) {
    if (l.item.price_changed) out.push({ variantId: l.item.variant_id, kind: 'price_changed' });
    if (l.item.stock_insufficient) out.push({ variantId: l.item.variant_id, kind: 'stock_insufficient' });
  }
  return out;
}

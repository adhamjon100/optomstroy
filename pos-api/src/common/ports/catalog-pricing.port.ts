import type { MoneyString, QuantityString, SalesActor, SalesTx } from './sales-context.js';

/**
 * `CatalogPricingPort` — цены и сведения о вариантах по виду цены корзины (каталог этапа E — реплики `prices`,
 * `product_variants`, `packagings`, `units`, `stock_balances`; выбор вида цены — `resolvePriceListId`,
 * sales-domain/pricing/price-list.ts, то же правило, что `CatalogViewerService`). Реализация — агент F-be-cart
 * (read-only запросы над репликами, 06 §7.4 п. (а)); потребители — cart, orders (повтор проверок в транзакции).
 */
export const CATALOG_PRICING_PORT = 'sales.CatalogPricingPort' as const;

export interface VariantQuoteRequest {
  readonly variantId: string;
  readonly packagingId: string | null;
}

export interface VariantQuote {
  readonly variantId: string;
  readonly productId: string;
  readonly packagingId: string | null;
  /** Цена за базовую единицу или за упаковку (`prices.packaging_id`); `null` — цены нет (VARIANT_UNAVAILABLE). */
  readonly unitPrice: MoneyString | null;
  /** Цена задана за упаковку: количество строки — число упаковок (07 §7.3 п. 1). */
  readonly pricePerPackaging: boolean;
  readonly packagingFactor: QuantityString | null;
  readonly unitId: string;
  readonly unitCode: string;
  readonly qtyPrecision: number; // money-double: allow — число знаков единицы (0…3), не количество
  readonly multiplicity: QuantityString | null;
  readonly minQty: QuantityString | null;
  /** Доступно на складе корзины; `null` — неизвестно (добавление запрещено, INV-052). */
  readonly available: QuantityString | null;
  readonly sellable: boolean;
  readonly productName: string;
  readonly variantName: string | null;
  readonly sku: string | null;
  readonly barcode: string | null;
  readonly packagingName: string | null;
}

export interface CatalogPricingPort {
  /** Вид цены корзины по клиенту и роли (INV-030, CUST-021); `null` — видов цен нет. */
  resolvePriceList(actor: SalesActor, input: { readonly customerId: string | null }): Promise<string | null>;
  quote(
    tx: SalesTx | null,
    input: {
      readonly priceListId: string;
      readonly warehouseId: string;
      readonly items: readonly VariantQuoteRequest[];
    },
  ): Promise<readonly VariantQuote[]>;
}

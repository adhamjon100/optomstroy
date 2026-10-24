import type { QuantityString, SalesActor } from './sales-context.js';

/**
 * `InventoryCheckPort` — проверка остатков строк корзины на складе (сервис этапа E `InventoryService.check`,
 * `POST /inventory/check`, 08 §4.6). Адаптер — `CatalogInventoryCheckAdapter` (sales-domain/adapters), привязан по
 * умолчанию в `SalesPortsModule`; потребители — cart (`checkout-preview`, `PATCH /cart`), orders (повтор проверок).
 */
export const INVENTORY_CHECK_PORT = 'sales.InventoryCheckPort' as const;

export interface InventoryCheckLineInput {
  readonly variantId: string;
  /** Количество в единице строки (`unitId`/`packagingId`), до 3 знаков. */
  readonly value: QuantityString;
  readonly unitId: string;
  readonly packagingId: string | null;
}

export interface InventoryShortage {
  readonly variantId: string;
  readonly requestedBase?: QuantityString;
  /** Для `customer` при `customer_stock_display=status` отсутствует (CUST-022). */
  readonly available?: QuantityString;
  readonly stockLevel: string;
}

export interface InventoryCheckOutcome {
  readonly ok: boolean;
  readonly shortages: readonly InventoryShortage[];
  /** Варианты без цены, снятые с продажи или удалённые. */
  readonly unavailable: readonly string[];
  /** Момент снимка остатков 1С. */
  readonly asOf?: string;
}

export interface InventoryCheckPort {
  check(
    actor: SalesActor,
    input: {
      readonly warehouseId: string;
      readonly priceListId?: string | null;
      readonly items: readonly InventoryCheckLineInput[];
    },
  ): Promise<InventoryCheckOutcome>;
}

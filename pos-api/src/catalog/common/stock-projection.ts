import { dec, isoOf, qtyOf } from './catalog-format.js';
import type { CatalogViewer } from './catalog-viewer.js';

/** `StockLevel` (08 §3.6): `unknown` — нет снимка остатка; добавление в корзину запрещено (10 INV-052). */
export type StockLevel = 'in_stock' | 'low' | 'out' | 'unknown';

/** Остаток из реплики (`stock_balances`): NUMERIC-строки; `available` — сумма/значение, посчитанные сервером (D-22). */
export interface StockFigures {
  readonly quantity: string;
  readonly reserved: string;
  readonly available: string;
  readonly asOf?: Date;
}

/** in_stock — available ≥ порога; low — 0 < available < порог; out — ≤ 0; unknown — нет снимка. */
export function stockLevelOf(available: string | null | undefined, threshold: string): StockLevel {
  if (available === null || available === undefined) return 'unknown';
  const a = dec(available);
  if (a.lte(0)) return 'out';
  return a.gte(dec(threshold)) ? 'in_stock' : 'low';
}

export interface StockBalanceDto {
  readonly variantId: string;
  readonly warehouseId: string;
  readonly warehouseName?: string;
  readonly quantity?: string;
  readonly reserved?: string;
  readonly available?: string;
  readonly unitId?: string;
  readonly asOf?: string;
  readonly stockLevel: StockLevel;
}

export interface StockKey {
  readonly variantId: string;
  readonly warehouseId: string;
  readonly warehouseName?: string;
  readonly unitId?: string;
}

/**
 * Проекция `StockBalance` по роли (08 §3.6, 10 CUST-022, 11 §4.4 field-level): staff — `quantity`, `reserved`,
 * `available`; customer при `status` — поля количеств **отсутствуют** (не `null`): только `variantId`,
 * `warehouseId`, `warehouseName`, `stockLevel`, `asOf`; при `quantity` — дополнительно `available`.
 * Нет снимка → `stockLevel: unknown` без количеств для всех ролей.
 */
export function projectStock(
  viewer: Pick<CatalogViewer, 'stockDisplay' | 'lowStockThreshold'>,
  key: StockKey,
  figures: StockFigures | null,
): StockBalanceDto {
  const level = stockLevelOf(figures?.available, viewer.lowStockThreshold);
  const base = {
    variantId: key.variantId,
    warehouseId: key.warehouseId,
    ...(key.warehouseName !== undefined ? { warehouseName: key.warehouseName } : {}),
  };
  if (!figures) return { ...base, stockLevel: level };
  const asOf = isoOf(figures.asOf);
  const tail = { ...(asOf ? { asOf } : {}), stockLevel: level };
  switch (viewer.stockDisplay) {
    case 'status':
      return { ...base, ...tail };
    case 'quantity':
      return { ...base, available: qtyOf(figures.available), ...tail };
    default:
      return {
        ...base,
        quantity: qtyOf(figures.quantity),
        reserved: qtyOf(figures.reserved),
        available: qtyOf(figures.available),
        ...(key.unitId ? { unitId: key.unitId } : {}),
        ...tail,
      };
  }
}

/** `availableTotal` по роли: staff и customer при `quantity` — строка или `null` (нет снимка); при `status` — нет поля. */
export function availableTotalOf(
  viewer: Pick<CatalogViewer, 'stockDisplay'>,
  total: string | null,
): { availableTotal?: string | null } {
  if (viewer.stockDisplay === 'status') return {};
  return { availableTotal: total === null ? null : qtyOf(total) };
}

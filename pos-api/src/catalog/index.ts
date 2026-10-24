/**
 * Публичный интерфейс экранного каталога и остатков (RM-E-004, RM-E-014, RM-E-017) для модулей `search`, `recent`,
 * `favorites`, `cart`: правила зрителя (вид цены/склад/показ остатков), краткие карточки товаров, фильтры списка.
 */
export { CatalogApiModule } from './api/catalog-api.module.js';
export {
  CARD_BLOCKS,
  type CardBlock,
  CatalogProductsService,
  type PriceDto,
  type ProductDto,
  productFilterSql,
  type ProductPage,
  type ProductSummaryDto,
  SqlParams,
  type UnitDto,
  type VariantDto,
} from './api/catalog-products.service.js';
export { CatalogReferenceService } from './api/catalog-reference.service.js';
export {
  DEFAULT_PRODUCT_SORT,
  parseProductFilters,
  parseProductPage,
  parseProductScope,
  PRODUCT_FILTER_PARAMS,
  PRODUCT_SORTS,
  type ProductFilters,
  type ProductPageParams,
  type ProductScopeParams,
  type ProductSort,
  PRODUCTS_LIMIT_DEFAULT,
  PRODUCTS_LIMIT_MAX,
} from './api/product-filters.js';
export {
  CACHE_NO_STORE,
  CACHE_PRODUCTS,
  CACHE_REFERENCE,
  etagMatches,
  etagOfBody,
  sendCached,
} from './common/catalog-http.js';
export { CatalogCommonModule } from './common/catalog-common.module.js';
export { CatalogCursorCodec, type CursorPayload } from './common/catalog-cursor.js';
export { type CatalogSnapshot, CatalogSnapshotService } from './common/catalog-snapshot.js';
export { type CatalogViewer, CatalogViewerService, type StockDisplay } from './common/catalog-viewer.js';
export {
  availableTotalOf,
  projectStock,
  type StockBalanceDto,
  type StockFigures,
  type StockLevel,
  stockLevelOf,
} from './common/stock-projection.js';
export { InventoryModule } from './inventory/inventory.module.js';
export { InventoryService, parseInventoryCheck } from './inventory/inventory.service.js';

import {
  attrParam,
  boolParam,
  enumParam,
  fieldError,
  intParam,
  listParam,
  moneyParam,
  type RawQuery,
  single,
  uuidParam,
} from '../common/catalog-query.js';
import { dec } from '../common/catalog-format.js';

/**
 * Фильтры списка товаров `GET /catalog/products` (08 §4.4.2; OpenAPI `Catalog*` параметры). Тот же разбор
 * принимает `GET /search/products` (13 RM-E-014 п. 1: «каждый фильтр `/catalog/products` принимается
 * `/search/products`») — экспорт для модуля поиска.
 */
export interface ProductFilters {
  readonly categoryId?: string;
  /** По умолчанию true (08 §4.4.2). */
  readonly includeSubcategories: boolean;
  readonly inStock?: boolean;
  /** Money-строки (`"100.00"`). */
  readonly priceMin?: string;
  readonly priceMax?: string;
  readonly brand?: readonly string[];
  /** `attr[<код свойства>]=<значение>` (≤ 10 пар). */
  readonly attr?: Readonly<Record<string, string>>;
  readonly favorite?: boolean;
  readonly hasImage?: boolean;
}

/** Параметры области цены/остатка (не фильтры): склад и вид цены (последний — только staff с `prices.read.all`). */
export interface ProductScopeParams {
  readonly warehouseId?: string;
  readonly priceListId?: string;
}

export const PRODUCT_SORTS = [
  'price:asc',
  'price:desc',
  'name:asc',
  'name:desc',
  'popularity:desc',
  'updatedAt:desc',
  'available:desc',
  'sku:asc',
] as const;
export type ProductSort = (typeof PRODUCT_SORTS)[number];
export const DEFAULT_PRODUCT_SORT: ProductSort = 'name:asc';

export const PRODUCTS_LIMIT_DEFAULT = 40;
export const PRODUCTS_LIMIT_MAX = 200;

/** Имена query-параметров фильтров — для параметризованной сверки `/search/products` (RM-E-014 п. 1). */
export const PRODUCT_FILTER_PARAMS = [
  'categoryId',
  'includeSubcategories',
  'warehouseId',
  'priceListId',
  'inStock',
  'priceMin',
  'priceMax',
  'brand',
  'attr',
  'favorite',
  'hasImage',
] as const;

export function parseProductFilters(q: RawQuery): ProductFilters {
  const priceMin = moneyParam(q, 'priceMin');
  const priceMax = moneyParam(q, 'priceMax');
  if (priceMin !== undefined && dec(priceMin).isNegative()) {
    fieldError('priceMin', 'minimum', 'Цена не может быть отрицательной.');
  }
  if (priceMin !== undefined && priceMax !== undefined && dec(priceMin).gt(dec(priceMax))) {
    fieldError('priceMax', 'range', 'priceMax должна быть не меньше priceMin.');
  }
  const brand = listParam(q, 'brand', 50);
  const attr = attrParam(q);
  return {
    categoryId: uuidParam(q, 'categoryId'),
    includeSubcategories: boolParam(q, 'includeSubcategories') ?? true,
    inStock: boolParam(q, 'inStock'),
    priceMin,
    priceMax,
    ...(brand ? { brand } : {}),
    ...(attr ? { attr } : {}),
    favorite: boolParam(q, 'favorite'),
    hasImage: boolParam(q, 'hasImage'),
  };
}

export function parseProductScope(q: RawQuery): ProductScopeParams {
  return { warehouseId: uuidParam(q, 'warehouseId'), priceListId: uuidParam(q, 'priceListId') };
}

export interface ProductPageParams {
  readonly sort: ProductSort;
  readonly limit: number;
  readonly cursor?: string;
}

export function parseProductPage(q: RawQuery): ProductPageParams {
  const sort = enumParam(q, 'sort', PRODUCT_SORTS, 'sort_field') ?? DEFAULT_PRODUCT_SORT;
  const limit = intParam(q, 'limit', 1, PRODUCTS_LIMIT_MAX, PRODUCTS_LIMIT_DEFAULT) ?? PRODUCTS_LIMIT_DEFAULT;
  const cursor = single(q, 'cursor');
  return { sort, limit, ...(cursor ? { cursor } : {}) };
}

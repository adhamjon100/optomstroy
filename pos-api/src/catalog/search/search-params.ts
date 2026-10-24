import { ProblemException, type ProblemFieldError } from '../../common/problem-details/problem.exception.js';
import {
  parseProductFilters,
  parseProductScope,
  type ProductFilters,
  type ProductScopeParams,
} from '../api/product-filters.js';
import { intParam, type RawQuery, single, uuidParam } from '../common/catalog-query.js';
import { MAX_QUERY_LENGTH } from './search-text.js';

/**
 * Разбор query-параметров поиска (OpenAPI `/search/products`, `/search/suggest`, `/search/barcode/{value}`;
 * 08 §2.5, §2.6, §4.5). Фильтры и область цены/склада — **тот же разбор, что `GET /catalog/products`**
 * (`parseProductFilters`/`parseProductScope` модуля catalog, RM-E-004; ядро §19.2, RM-E-014 п. 1).
 * Неизвестные параметры игнорируются (08 §2.6). Ошибки — `400 VALIDATION_FAILED` (`errors[].rule`), кроме
 * `q_too_short` — `422` (семантическая ошибка, 08 §2.4).
 */

export const SEARCH_SORTS = [
  'relevance:desc',
  'price:asc',
  'price:desc',
  'name:asc',
  'available:desc',
  'sku:asc',
] as const;
export type SearchSort = (typeof SEARCH_SORTS)[number];

/** Лимит страницы (OpenAPI `CatalogProductsLimit`: 1…200, по умолчанию 40; ядро §19.2). */
export const DEFAULT_PAGE_LIMIT = 40;
export const MAX_PAGE_LIMIT = 200;
/** Подсказки: `limit` ≤ 10 (OpenAPI `/search/suggest`). */
export const SUGGEST_MAX_LIMIT = 10;

export interface SearchProductsParams {
  readonly q: string;
  readonly filters: ProductFilters;
  readonly scope: ProductScopeParams;
  readonly sort: SearchSort;
  readonly limit: number;
  readonly cursor?: string;
}

export function validationFailed(errors: readonly ProblemFieldError[], status: 400 | 422 = 400): ProblemException {
  return new ProblemException('VALIDATION_FAILED', { status, detail: 'Запрос не прошёл проверку.', errors });
}

/** `q`: обязателен, 1…200 символов (OpenAPI); короткий текст — отдельная проверка `q_too_short` (422). */
function parseQ(raw: RawQuery): string {
  const q = single(raw, 'q');
  if (q === undefined) throw validationFailed([{ field: 'q', rule: 'required', message: 'Параметр q обязателен.' }]);
  if (q.length > MAX_QUERY_LENGTH) {
    throw validationFailed([
      {
        field: 'q',
        rule: 'max_length',
        message: `Не длиннее ${MAX_QUERY_LENGTH} символов.`,
        params: { maxLength: MAX_QUERY_LENGTH },
      },
    ]);
  }
  return q;
}

export function parseSearchProductsQuery(raw: RawQuery): SearchProductsParams {
  const q = parseQ(raw);
  const filters = parseProductFilters(raw);
  const scope = parseProductScope(raw);
  const sortRaw = single(raw, 'sort');
  let sort: SearchSort = 'relevance:desc';
  if (sortRaw !== undefined && sortRaw !== '') {
    if (!(SEARCH_SORTS as readonly string[]).includes(sortRaw)) {
      throw validationFailed([
        {
          field: 'sort',
          rule: 'sort_field',
          message: 'Недопустимое значение sort.',
          params: { allowed: SEARCH_SORTS },
        },
      ]);
    }
    sort = sortRaw as SearchSort;
  }
  const limit = intParam(raw, 'limit', 1, MAX_PAGE_LIMIT, DEFAULT_PAGE_LIMIT) ?? DEFAULT_PAGE_LIMIT;
  const cursor = single(raw, 'cursor');
  return { q, filters, scope, sort, limit, ...(cursor ? { cursor } : {}) };
}

export interface SuggestParams {
  readonly q: string;
  readonly limit: number;
}

export function parseSuggestQuery(raw: RawQuery): SuggestParams {
  const q = parseQ(raw);
  const limit = intParam(raw, 'limit', 1, SUGGEST_MAX_LIMIT, SUGGEST_MAX_LIMIT) ?? SUGGEST_MAX_LIMIT;
  return { q, limit };
}

/** `GET /search/barcode/{value}`: OpenAPI `pattern: ^[0-9A-Za-z-]{3,64}$`. */
export const BARCODE_PATH_RE = /^[0-9A-Za-z-]{3,64}$/u;

export function parseBarcodeRequest(value: string, raw: RawQuery): { value: string; warehouseId?: string } {
  if (!BARCODE_PATH_RE.test(value)) {
    throw validationFailed([{ field: 'value', rule: 'pattern', message: 'Штрихкод: 3…64 символа [0-9A-Za-z-].' }]);
  }
  const warehouseId = uuidParam(raw, 'warehouseId');
  return { value, ...(warehouseId ? { warehouseId } : {}) };
}

/** `422 VALIDATION_FAILED rule q_too_short` (OpenAPI `q`; 08 §4.5.1, §4.5.3). */
export function qTooShort(min: number): ProblemException {
  return validationFailed(
    [{ field: 'q', rule: 'q_too_short', message: `Введите не меньше ${min} символов.`, params: { minLength: min } }],
    422,
  );
}

import { Controller, Get, Header, Param, Query, Req } from '@nestjs/common';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { parseSearchProductsQuery, parseSuggestQuery } from './search-params.js';
import { stripControls } from './search-text.js';
import {
  type SearchBarcodeResponse,
  type SearchProductsResponse,
  SearchService,
  type SearchSuggestResponse,
} from './search.service.js';

/** `Cache-Control` ответов поиска (08 §2.8: `GET /search/*` — `private, max-age=30`, без ETag). */
export const SEARCH_CACHE_CONTROL = 'private, max-age=30';

/**
 * Управляющие символы в строковых query-параметрах → пробел (PostgreSQL отвергает `\u0000` в text — без этого
 * `brand=a%00` или `q=…%00` давали бы 500). Структура (массивы, объекты `attr`) сохраняется.
 */
export function sanitizeQuery(raw: Record<string, unknown>): Record<string, unknown> {
  const clean = (v: unknown): unknown =>
    typeof v === 'string'
      ? stripControls(v)
      : Array.isArray(v)
        ? v.map(clean)
        : v !== null && typeof v === 'object'
          ? Object.fromEntries(
              Object.entries(v as Record<string, unknown>).map(([k, x]) => [stripControls(k), clean(x)]),
            )
          : v;
  return Object.fromEntries(Object.entries(raw).map(([k, v]) => [stripControls(k), clean(v)]));
}

/**
 * Модуль `search` (D-06: catalog + search; 08 §4.5; OpenAPI тег `search`). Право — `search.read` (все роли R1);
 * цена и `priceListId` — по `catalog.prices.read` / `catalog.prices.read.all` внутри сервиса (field-level, 11 §4.3).
 * Аудит не пишется (чтение без финансовых данных). Query разбирается вручную: неизвестные параметры игнорируются
 * (08 §2.6), а глобальный ValidationPipe для `Record<string, unknown>` проверку не выполняет.
 */
@Controller('search')
export class SearchController {
  constructor(private readonly search: SearchService) {}

  /** `GET /search/products` — search_products_list. */
  @Get('products')
  @RequirePermission('search.read')
  @Header('Cache-Control', SEARCH_CACHE_CONTROL)
  products(@Req() req: RequestWithContext, @Query() raw: Record<string, unknown>): Promise<SearchProductsResponse> {
    return this.search.searchProducts(req.principal, parseSearchProductsQuery(sanitizeQuery(raw)));
  }

  /** `GET /search/suggest` — search_suggest_list. */
  @Get('suggest')
  @RequirePermission('search.read')
  @Header('Cache-Control', SEARCH_CACHE_CONTROL)
  suggest(@Req() req: RequestWithContext, @Query() raw: Record<string, unknown>): Promise<SearchSuggestResponse> {
    return this.search.suggest(req.principal, parseSuggestQuery(sanitizeQuery(raw)));
  }

  /** `GET /search/barcode/{value}` — search_barcode_get (HID-сканер/камера SCR-17, D-42). */
  @Get('barcode/:value')
  @RequirePermission('search.read')
  @Header('Cache-Control', SEARCH_CACHE_CONTROL)
  barcode(
    @Req() req: RequestWithContext,
    @Param('value') value: string,
    @Query() raw: Record<string, unknown>,
  ): Promise<SearchBarcodeResponse> {
    return this.search.barcode(req.principal, value, sanitizeQuery(raw));
  }
}

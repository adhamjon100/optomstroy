import { Controller, Get, Headers, Param, Query, Req, Res } from '@nestjs/common';
import type { Response } from 'express';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { CACHE_PRODUCTS, CACHE_REFERENCE, sendCached } from '../common/catalog-http.js';
import {
  boolParam,
  fieldError,
  intParam,
  type RawQuery,
  single,
  uuidParam,
  uuidPath,
} from '../common/catalog-query.js';
import { CatalogSnapshotService } from '../common/catalog-snapshot.js';
import { CatalogViewerService } from '../common/catalog-viewer.js';
import { RecordsRecentView } from '../common/recent-view.marker.js';
import { CARD_BLOCKS, type CardBlock, CatalogProductsService } from './catalog-products.service.js';
import { CatalogReferenceService } from './catalog-reference.service.js';
import { parseProductFilters, parseProductPage, parseProductScope } from './product-filters.js';

/**
 * Модуль D-06 `catalog` — экранные эндпоинты (08 §4.4.1–§4.4.4, §4.4.6; RM-E-004, RM-E-014, RM-E-017):
 * только чтение реплики 1С (D-28), `ETag` + `Cache-Control` по 08 §2.8, `If-None-Match` → 304, `X-Data-As-Of`.
 * Права: `catalog.read` — обязательный код операции; `catalog.prices.read` — цена по правилам роли;
 * `catalog.prices.read.all` — `prices[]` всех видов и `priceListId` (проверяет `CatalogViewerService`).
 * `GET /catalog/products/recent` — модуль `src/catalog/recent` (регистрируется раньше `products/:id`).
 */
@Controller('catalog')
export class CatalogController {
  constructor(
    private readonly viewers: CatalogViewerService,
    private readonly products: CatalogProductsService,
    private readonly reference: CatalogReferenceService,
    private readonly snapshots: CatalogSnapshotService,
  ) {}

  @Get('categories')
  @RequirePermission('catalog.read')
  async categories(
    @Req() req: RequestWithContext,
    @Query() q: RawQuery,
    @Headers('if-none-match') inm: string | undefined,
    @Res() res: Response,
  ): Promise<void> {
    const parentId = uuidParam(q, 'parentId');
    const depth = intParam(q, 'depth', 1, 5);
    const includeEmpty = boolParam(q, 'includeEmpty') ?? false;
    const inStockOnly = boolParam(q, 'inStockOnly') ?? false;
    const viewer = await this.viewers.resolve(req.principal);
    const [body, snap] = await Promise.all([
      this.reference.categories(viewer, { parentId, depth, includeEmpty, inStockOnly }),
      this.snapshots.read(),
    ]);
    sendCached(res, { body, cacheControl: CACHE_REFERENCE, dataAsOf: snap.catalogAsOf, ifNoneMatch: inm });
  }

  @Get('units')
  @RequirePermission('catalog.read')
  async units(
    @Req() req: RequestWithContext,
    @Headers('if-none-match') inm: string | undefined,
    @Res() res: Response,
  ): Promise<void> {
    this.viewers.assertAllowed(req.principal);
    const [body, snap] = await Promise.all([this.reference.units(), this.snapshots.read()]);
    sendCached(res, { body, cacheControl: CACHE_REFERENCE, dataAsOf: snap.catalogAsOf, ifNoneMatch: inm });
  }

  @Get('price-lists')
  @RequirePermission('catalog.prices.read')
  async priceLists(
    @Req() req: RequestWithContext,
    @Headers('if-none-match') inm: string | undefined,
    @Res() res: Response,
  ): Promise<void> {
    const viewer = await this.viewers.resolve(req.principal);
    const [body, snap] = await Promise.all([this.reference.priceLists(viewer), this.snapshots.read()]);
    sendCached(res, { body, cacheControl: CACHE_REFERENCE, dataAsOf: snap.pricesAsOf, ifNoneMatch: inm });
  }

  @Get('warehouses')
  @RequirePermission('catalog.read')
  async warehouses(
    @Req() req: RequestWithContext,
    @Headers('if-none-match') inm: string | undefined,
    @Res() res: Response,
  ): Promise<void> {
    this.viewers.assertAllowed(req.principal);
    const [body, snap] = await Promise.all([this.reference.warehouses(), this.snapshots.read()]);
    sendCached(res, { body, cacheControl: CACHE_REFERENCE, dataAsOf: snap.catalogAsOf, ifNoneMatch: inm });
  }

  @Get('products')
  @RequirePermission('catalog.read')
  async list(
    @Req() req: RequestWithContext,
    @Query() q: RawQuery,
    @Headers('if-none-match') inm: string | undefined,
    @Res() res: Response,
  ): Promise<void> {
    const filters = parseProductFilters(q);
    const page = parseProductPage(q);
    const viewer = await this.viewers.resolve(req.principal, parseProductScope(q));
    const snap = await this.snapshots.read();
    const body = await this.products.list(viewer, filters, page, snap);
    sendCached(res, { body, cacheControl: CACHE_PRODUCTS, dataAsOf: snap.dataAsOf, ifNoneMatch: inm });
  }

  @Get('products/:id')
  @RequirePermission('catalog.read')
  @RecordsRecentView() // 08 §4.4.3: отметка в «Недавних» после успешного ответа (src/catalog/recent, EQ-CSYNC-06)
  async card(
    @Req() req: RequestWithContext,
    @Param('id') rawId: string,
    @Query() q: RawQuery,
    @Headers('if-none-match') inm: string | undefined,
    @Res() res: Response,
  ): Promise<void> {
    const id = uuidPath(rawId);
    const include = parseInclude(q);
    const viewer = await this.viewers.resolve(req.principal, parseProductScope(q));
    const snap = await this.snapshots.read();
    const body = await this.products.card(viewer, id, include, snap);
    sendCached(res, { body, cacheControl: CACHE_PRODUCTS, dataAsOf: snap.dataAsOf, ifNoneMatch: inm });
  }

  @Get('products/:id/variants')
  @RequirePermission('catalog.read')
  async variants(
    @Req() req: RequestWithContext,
    @Param('id') rawId: string,
    @Query() q: RawQuery,
    @Headers('if-none-match') inm: string | undefined,
    @Res() res: Response,
  ): Promise<void> {
    const id = uuidPath(rawId);
    const inStockOnly = boolParam(q, 'inStockOnly') ?? false;
    const viewer = await this.viewers.resolve(req.principal, parseProductScope(q));
    const snap = await this.snapshots.read();
    const body = await this.products.variants(viewer, id, inStockOnly, snap);
    sendCached(res, { body, cacheControl: CACHE_PRODUCTS, dataAsOf: snap.dataAsOf, ifNoneMatch: inm });
  }
}

/** `include` карточки (08 §4.4.3): через запятую, ≤ 4 значений из перечня; по умолчанию — все блоки. */
export function parseInclude(q: RawQuery): ReadonlySet<CardBlock> {
  const v = single(q, 'include');
  if (v === undefined || v === '') return new Set(CARD_BLOCKS);
  const items = v.split(',').map((s) => s.trim());
  if (items.length > 4) fieldError('include', 'max_items', 'Параметр include: не более 4 значений.');
  for (const i of items) {
    if (!(CARD_BLOCKS as readonly string[]).includes(i)) {
      fieldError('include', 'enum', 'Недопустимое значение include.', { allowed: CARD_BLOCKS });
    }
  }
  return new Set(items as CardBlock[]);
}

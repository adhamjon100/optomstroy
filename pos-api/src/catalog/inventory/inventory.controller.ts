import { Body, Controller, Get, HttpCode, Post, Query, Req, Res } from '@nestjs/common';
import type { Response } from 'express';
import type { RequestWithContext } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { RequirePermission } from '../../common/rbac/rbac.decorators.js';
import { CACHE_NO_STORE, sendCached } from '../common/catalog-http.js';
import { boolParam, fieldError, type RawQuery, single, uuidParam } from '../common/catalog-query.js';
import { CatalogSnapshotService } from '../common/catalog-snapshot.js';
import { CatalogViewerService } from '../common/catalog-viewer.js';
import { INVENTORY_MAX_ITEMS, InventoryService, parseInventoryCheck } from './inventory.service.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * `inventory` (08 §4.6; RM-E-004, RM-E-017): остатки по вариантам и пакетная проверка доступности корзины.
 * `Cache-Control: no-store`, `X-Data-As-Of`; аудит не пишется. Количества для `customer` — по
 * `app_settings.customer_stock_display` (field-level, 11 §4.4). Планшет магазина (`kind=kiosk`, склад закреплён —
 * `CatalogViewer.warehouseLocked`; 08 §4.25, 10 KIOSK-007): только склад планшета — параметр `warehouseId` → `403`,
 * без параметра — склад планшета (не «все склады»); тело `POST /inventory/check` — только склад планшета (другой →
 * `403`).
 */
@Controller('inventory')
export class InventoryController {
  constructor(
    private readonly viewers: CatalogViewerService,
    private readonly inventory: InventoryService,
    private readonly snapshots: CatalogSnapshotService,
  ) {}

  @Get('balances')
  @RequirePermission('inventory.read')
  async balances(@Req() req: RequestWithContext, @Query() q: RawQuery, @Res() res: Response): Promise<void> {
    const raw = single(q, 'variantIds');
    if (raw === undefined || raw.trim() === '') fieldError('variantIds', 'required', 'Параметр variantIds обязателен.');
    const ids = raw
      .split(',')
      .map((s) => s.trim())
      .filter((s) => s !== '');
    if (ids.length > INVENTORY_MAX_ITEMS) {
      fieldError('variantIds', 'max_items', `Не более ${INVENTORY_MAX_ITEMS} вариантов.`, {
        maxItems: INVENTORY_MAX_ITEMS,
      });
    }
    for (const id of ids) if (!UUID_RE.test(id)) fieldError('variantIds', 'format', 'variantIds — список UUID.');
    const warehouseId = uuidParam(q, 'warehouseId');
    const live = boolParam(q, 'live') ?? false;
    const viewer = await this.viewers.resolve(req.principal);
    if (viewer.warehouseLocked && warehouseId !== undefined) throw lockedWarehouseForbidden();
    if (live && viewer.isCustomer) {
      throw new ProblemException('FORBIDDEN', { detail: 'Синхронная проверка 1С доступна только сотрудникам.' });
    }
    const snap = await this.snapshots.read();
    // live=true (staff): синхронный запрос в 1С ≤ 2 с — не подключён (08 §4.6.1: source=live только при включённой
    // проверке и ответе 1С); ответ — снимок реплики, source=snapshot.
    const body = await this.inventory.balances(
      viewer,
      [...new Set(ids.map((s) => s.toLowerCase()))],
      viewer.warehouseLocked ? viewer.warehouse?.id : warehouseId,
      snap,
    );
    sendCached(res, { body, cacheControl: CACHE_NO_STORE, dataAsOf: snap.stockAsOf, etag: false });
  }

  @Post('check')
  @HttpCode(200)
  @RequirePermission('inventory.read')
  async check(@Req() req: RequestWithContext, @Body() body: unknown, @Res() res: Response): Promise<void> {
    const input = parseInventoryCheck(body);
    const viewer = await this.viewers.resolve(req.principal);
    if (viewer.warehouseLocked && input.warehouseId !== viewer.warehouse?.id) throw lockedWarehouseForbidden();
    const snap = await this.snapshots.read();
    const result = await this.inventory.check(viewer, input, snap);
    sendCached(res, { body: result, cacheControl: CACHE_NO_STORE, dataAsOf: snap.stockAsOf, etag: false });
  }
}

/** Склад планшета магазина закреплён (ADR-115 п. 23): другой склад — `403 FORBIDDEN` (в том числе параметром). */
function lockedWarehouseForbidden(): ProblemException {
  return new ProblemException('FORBIDDEN', { detail: 'На планшете магазина доступен только склад планшета.' });
}

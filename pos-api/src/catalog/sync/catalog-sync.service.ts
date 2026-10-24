import { createHash } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../../common/db/database.module.js';
import type { Principal } from '../../common/http/request-context.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { CatalogSnapshotService } from '../common/catalog-snapshot.js';
import { type CatalogViewer, CatalogViewerService } from '../common/catalog-viewer.js';
import { CatalogSyncCursorCodec, type SyncPosition } from './catalog-sync.cursor.js';
import { readSyncHorizon } from './catalog-sync.horizon.js';
import { type MapContext, toSyncItem } from './catalog-sync.mapper.js';
import { fetchSyncPage, keyLengthOf } from './catalog-sync.queries.js';
import {
  CATALOG_SYNC_RETENTION_DAYS,
  type CatalogSyncEntity,
  type CatalogSyncResponse,
  SYNC_STATE_ENTITY,
} from './catalog-sync.types.js';

const NIL_UUID = '00000000-0000-0000-0000-000000000000';
const DAY_MS = 24 * 3600_000;

export interface CatalogSyncRequest {
  readonly entity: CatalogSyncEntity;
  readonly since?: string;
  readonly limit: number;
  readonly warehouseId?: string;
}

export interface CatalogSyncResult {
  readonly body: CatalogSyncResponse;
  /** Слабый ETag = хэш (entity, область видимости роли, since, nextCursor) — 08 §4.24 «Кэширование». */
  readonly etag: string;
  readonly dataAsOf?: Date;
}

/**
 * `GET /catalog/sync/{entity}` (RM-E-015; 08 §4.24, ядро §22.7). Одна страница выгрузки офлайн-кэша:
 * 1) права по сущности: `prices`/`price_lists` — `catalog.prices.read` (виды цен — `price_lists.visible_to_roles`
 *    роли, все — при `catalog.prices.read.all`; `customer` — только свой вид цены по CUST-021/INV-030, правило
 *    `CatalogViewerService`); `stock` — `inventory.read` (`customer` — по `customer_stock_display`);
 * 2) курсор (`since`) — подпись, сущность, срок хранения удалений (30 дней → `409 VERSION_CONFLICT cursor_expired`);
 * 3) горизонт — защита от строк незавершённых транзакций (`catalog-sync.horizon.ts`);
 * 4) строки `(updated_at, ключ) > since` по возрастанию, `limit + 1` — признак `hasMore`; `__live = false` → `deleted[]`.
 * `nextCursor` есть всегда: позиция последней строки страницы; на пустой странице — позиция `since` (или горизонт при
 * первичной загрузке пустой сущности). Повтор с тем же `since` → те же строки.
 */
@Injectable()
export class CatalogSyncService {
  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    private readonly viewers: CatalogViewerService,
    private readonly permissions: PermissionCatalog,
    private readonly snapshots: CatalogSnapshotService,
    private readonly cursors: CatalogSyncCursorCodec,
  ) {}

  /** Текущее время (мс); переопределяется в тестах. */
  protected now(): number {
    return Date.now();
  }

  async page(principal: Principal | undefined, req: CatalogSyncRequest): Promise<CatalogSyncResult> {
    const { entity } = req;
    if (!principal) throw new ProblemException('UNAUTHENTICATED', { detail: 'Требуется вход.' });
    if (principal.kind === 'integration') throw forbidden();
    const granted = this.permissions.effectivePermissions(principal);
    if ((entity === 'prices' || entity === 'price_lists') && !granted.has('catalog.prices.read')) throw forbidden();
    if (entity === 'stock' && !granted.has('inventory.read')) throw forbidden();

    const keyLength = keyLengthOf(entity);
    const decoded = req.since !== undefined ? this.cursors.decode(req.since, entity, keyLength) : undefined;
    if (decoded && decoded.issuedAt < this.now() - CATALOG_SYNC_RETENTION_DAYS * DAY_MS) {
      throw new ProblemException('VERSION_CONFLICT', {
        status: 409,
        detail: 'Курсор старше срока хранения сведений об удалениях — загрузите сущность заново без since.',
        reason: 'cursor_expired',
      });
    }

    const viewer = await this.viewers.resolve(principal);
    if (req.warehouseId !== undefined) await this.assertWarehouse(req.warehouseId);
    const priceListIds = entity === 'prices' || entity === 'price_lists' ? await this.visiblePriceLists(viewer) : [];
    const scope = scopeFingerprint(entity, viewer, priceListIds, req.warehouseId);
    if (decoded && decoded.scope !== scope) {
      // Область видимости изменилась (привязка клиента подтверждена — другой вид цены, `customer_stock_display`,
      // роль, склад): строки новой области не изменялись после `since` и в инкремент не попали бы, а строки старой —
      // не пришли бы в `deleted[]` (ревью E-api-3). Ответ контракта 08 §4.24 — `409 cursor_expired`: загрузка заново.
      throw new ProblemException('VERSION_CONFLICT', {
        status: 409,
        detail:
          'Изменилась область видимости данных (вид цены, режим остатков, роль или склад) — загрузите сущность заново без since.',
        reason: 'cursor_expired',
      });
    }
    const allPriceLists = entity === 'prices' && (await this.coversAllPriceLists(priceListIds));
    const horizon = await readSyncHorizon(this.pool);
    const rows = await fetchSyncPage(this.pool, {
      entity,
      ...(decoded ? { position: decoded.position } : {}),
      horizon: horizon.horizon,
      fetch: req.limit + 1,
      hasSince: decoded !== undefined,
      priceListIds,
      allPriceLists,
      ...(entity === 'stock' && req.warehouseId !== undefined ? { warehouseId: req.warehouseId } : {}),
    });
    const hasMore = rows.length > req.limit;
    const page = hasMore ? rows.slice(0, req.limit) : rows;

    const snap = entity === 'stock' || entity === 'prices' ? await this.snapshots.read() : undefined;
    const ctx: MapContext = {
      viewer,
      ...(snap?.stockAsOf ? { stockAsOf: snap.stockAsOf } : {}),
      ...(snap?.pricesAsOf ? { pricesAsOf: snap.pricesAsOf } : {}),
    };
    const items: unknown[] = [];
    const deleted: string[] = [];
    for (const r of page) {
      const item = r.__live ? toSyncItem(entity, r, ctx) : undefined;
      if (item) items.push(item);
      else if (typeof r.id === 'string') deleted.push(r.id);
    }

    const last = page.at(-1);
    const next: SyncPosition = last
      ? { ts: last.__ts, key: keyLength === 2 ? [last.__k0, last.__k1 ?? NIL_UUID] : [last.__k0] }
      : (decoded?.position ?? { ts: horizon.horizon, key: Array.from({ length: keyLength }, () => NIL_UUID) });
    const nextCursor = this.cursors.encode(entity, next, this.now(), scope);
    const scopeKey = [
      viewer.role,
      viewer.stockDisplay,
      viewer.lowStockThreshold,
      priceListIds.join(','),
      req.warehouseId ?? '',
      String(req.limit),
    ].join('|');
    const etag = weakEtag([entity, scopeKey, positionKey(decoded?.position), positionKey(next)].join('\n'));
    const dataAsOf = await this.dataAsOf(entity);
    return {
      body: { items, deleted, nextCursor, hasMore, serverTime: new Date(horizon.serverTime).toISOString() },
      etag,
      ...(dataAsOf ? { dataAsOf } : {}),
    };
  }

  /**
   * Виды цен выгрузки: `customer` — только вид цены клиента (CUST-021: привязка → `is_default` → розничный);
   * `catalog.prices.read.all` — все неудалённые; иначе — с ролью в `visible_to_roles` (07 DATA-125).
   */
  private async visiblePriceLists(viewer: CatalogViewer): Promise<string[]> {
    if (!viewer.canReadPrice) return [];
    if (viewer.isCustomer) return viewer.priceList ? [viewer.priceList.id] : [];
    const res = await this.pool.query<{ id: string }>(
      viewer.canReadAllPrices
        ? `SELECT id FROM price_lists WHERE NOT deletion_mark ORDER BY id`
        : `SELECT id FROM price_lists WHERE NOT deletion_mark AND $1::text = ANY(visible_to_roles::text[]) ORDER BY id`,
      viewer.canReadAllPrices ? [] : [viewer.role],
    );
    return res.rows.map((r) => r.id);
  }

  /** Видимы все строки `price_lists` (включая помеченные на удаление) — фильтр цен по виду не нужен. */
  private async coversAllPriceLists(ids: readonly string[]): Promise<boolean> {
    const res = await this.pool.query<{ missing: boolean }>(
      `SELECT EXISTS (SELECT 1 FROM price_lists WHERE NOT (id = ANY($1::uuid[]))) AS missing`,
      [ids],
    );
    return res.rows[0]?.missing === false;
  }

  private async assertWarehouse(id: string): Promise<void> {
    const res = await this.pool.query(`SELECT 1 FROM warehouses WHERE id = $1::uuid AND NOT deletion_mark`, [id]);
    if (res.rowCount === 0) {
      throw new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Склад не найден.',
        errors: [{ field: 'warehouseId', rule: 'unknown_reference', message: 'Склад не найден.' }],
      });
    }
  }

  private async dataAsOf(entity: CatalogSyncEntity): Promise<Date | undefined> {
    const res = await this.pool.query<{ at: Date | null }>(
      `SELECT last_success_at AS at FROM sync_state WHERE entity = $1::sync_entity`,
      [SYNC_STATE_ENTITY[entity]],
    );
    return res.rows[0]?.at ?? undefined;
  }
}

/**
 * Отпечаток области видимости выгрузки сущности: роль; для `prices`/`price_lists` — видимые виды цен; для `stock` —
 * режим показа остатков клиенту, порог «мало» и склад запроса. Короткий хэш — в курсоре `since` (не раскрывает id).
 */
export function scopeFingerprint(
  entity: CatalogSyncEntity,
  viewer: Pick<CatalogViewer, 'role' | 'stockDisplay' | 'lowStockThreshold'>,
  priceListIds: readonly string[],
  warehouseId: string | undefined,
): string {
  const parts: string[] = [entity, viewer.role];
  if (entity === 'prices' || entity === 'price_lists') parts.push([...priceListIds].sort().join(','));
  if (entity === 'stock') parts.push(viewer.stockDisplay, viewer.lowStockThreshold, warehouseId ?? '');
  return createHash('sha256').update(parts.join('|')).digest('base64url').slice(0, 22);
}

function forbidden(): ProblemException {
  return new ProblemException('FORBIDDEN', { detail: 'Недостаточно прав для операции.' });
}

function positionKey(p: SyncPosition | undefined): string {
  return p ? [p.ts, ...p.key].join('/') : '-';
}

function weakEtag(s: string): string {
  return `W/"${createHash('sha256').update(s).digest('base64url').slice(0, 32)}"`;
}

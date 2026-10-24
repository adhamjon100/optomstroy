/** Офлайн-API каталога (RM-E-015; 08 §4.24, ядро §22.7). */
export { CATALOG_SYNC_CACHE_CONTROL, CatalogSyncController, parseSyncLimit } from './catalog-sync.controller.js';
export {
  CatalogSyncCursorCodec,
  type DecodedSyncCursor,
  invalidCursor,
  MAX_CURSOR_LENGTH,
  type SyncPosition,
} from './catalog-sync.cursor.js';
export { isoMillis, readSyncHorizon, type SyncHorizon, tsText } from './catalog-sync.horizon.js';
export { type MapContext, type SyncItem, toSyncItem } from './catalog-sync.mapper.js';
export { CatalogSyncModule } from './catalog-sync.module.js';
export { fetchSyncPage, keyLengthOf, type PageQuery, type SyncRow } from './catalog-sync.queries.js';
export { type CatalogSyncRequest, type CatalogSyncResult, CatalogSyncService } from './catalog-sync.service.js';
export {
  CATALOG_SYNC_DEFAULT_LIMIT,
  CATALOG_SYNC_ENTITIES,
  CATALOG_SYNC_LOAD_ORDER,
  CATALOG_SYNC_MAX_LIMIT,
  CATALOG_SYNC_RETENTION_DAYS,
  type CatalogSyncEntity,
  type CatalogSyncResponse,
  isCatalogSyncEntity,
} from './catalog-sync.types.js';

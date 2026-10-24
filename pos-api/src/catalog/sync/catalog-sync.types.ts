/**
 * Офлайн-API каталога `GET /catalog/sync/{entity}` (RM-E-015; 08 §4.24, ядро §22.7, OpenAPI `CatalogSyncEntity`,
 * `CatalogSyncResponse`). Перечень сущностей — ровно ядро §22.7; иное значение пути → `VALIDATION_FAILED` (rule `enum`).
 */
export const CATALOG_SYNC_ENTITIES = [
  'categories',
  'products',
  'variants',
  'units',
  'packagings',
  'barcodes',
  'price_lists',
  'prices',
  'stock',
  'warehouses',
  'attributes',
  'images',
] as const;

export type CatalogSyncEntity = (typeof CATALOG_SYNC_ENTITIES)[number];

export function isCatalogSyncEntity(v: string): v is CatalogSyncEntity {
  return (CATALOG_SYNC_ENTITIES as readonly string[]).includes(v);
}

/** Рекомендуемый порядок загрузки (08 §4.24 «Порядок загрузки»; 07 §11.4). */
export const CATALOG_SYNC_LOAD_ORDER: readonly CatalogSyncEntity[] = [
  'units',
  'categories',
  'attributes',
  'warehouses',
  'price_lists',
  'products',
  'variants',
  'packagings',
  'barcodes',
  'prices',
  'stock',
  'images',
];

/** `limit` 1…200, по умолчанию 200 (08 §4.24; `> 200` → `VALIDATION_FAILED`, rule `limit`). */
export const CATALOG_SYNC_MAX_LIMIT = 200;
export const CATALOG_SYNC_DEFAULT_LIMIT = 200;

/**
 * Срок хранения сведений об удалениях (08 §4.24, 07 §11.4): курсор, выданный раньше, → `409 VERSION_CONFLICT`
 * (`reason: cursor_expired`). Журнал `catalog_sync.deletions` хранит записи 31 день (миграция 0007, +1 день запаса).
 */
export const CATALOG_SYNC_RETENTION_DAYS = 30;

/**
 * Запас горизонта выгрузки, если в БД есть сеансы другой роли, чьи транзакции не видны в `pg_stat_activity`
 * (см. `catalog-sync.horizon.ts`): строки моложе `now() - lag` отдаются в следующем инкременте.
 */
export const CATALOG_SYNC_HIDDEN_SESSION_LAG_SECONDS = 300;

/** Ответ — ровно поля ядра §22.7 (OpenAPI `CatalogSyncResponse`). */
export interface CatalogSyncResponse {
  readonly items: unknown[];
  readonly deleted: string[];
  readonly nextCursor: string;
  readonly hasMore: boolean;
  readonly serverTime: string;
}

/** Сущность `sync_entity` (07 §6.1) для `X-Data-As-Of` (`sync_state.last_success_at`). */
export const SYNC_STATE_ENTITY: Readonly<Record<CatalogSyncEntity, string>> = {
  categories: 'categories',
  products: 'products',
  variants: 'variants',
  units: 'units',
  packagings: 'products',
  barcodes: 'barcodes',
  price_lists: 'prices',
  prices: 'prices',
  stock: 'stock',
  warehouses: 'warehouses',
  attributes: 'attributes',
  images: 'images',
};

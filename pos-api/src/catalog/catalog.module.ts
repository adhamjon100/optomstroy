import { Module } from '@nestjs/common';
import { CatalogApiModule } from './api/catalog-api.module.js';
import { InventoryModule } from './inventory/inventory.module.js';
import { CatalogRecentModule } from './recent/recent.module.js';
import { SearchModule } from './search/search.module.js';
import { CatalogSyncModule } from './sync/catalog-sync.module.js';

/**
 * Модуль D-06 `catalog` — каркас RM-C-005 (пустой). Ответственность, экспорт и эндпоинты — 06 §7.4;
 * правила импорта (MOD-022) — 06 §7.4 «Запрещены циклы».
 */
@Module({
  // RM-E-004: CatalogApiModule (маршрут `products/:id`) — последним: модули с `products/recent` и другими
  // статическими путями под `/catalog/products/*` подключаются выше, чтобы их маршруты регистрировались раньше.
  // RM-E-006/RM-E-015: CatalogRecentModule (`products/recent`) и CatalogSyncModule (`/catalog/sync/{entity}`).
  // RM-E-005: SearchModule (`/search/products|suggest`, `/search/barcode/{value}`) — свой префикс `/search`.
  imports: [CatalogRecentModule, CatalogSyncModule, InventoryModule, SearchModule, CatalogApiModule],
  exports: [CatalogRecentModule, CatalogSyncModule, InventoryModule, CatalogApiModule],
})
export class CatalogModule {}

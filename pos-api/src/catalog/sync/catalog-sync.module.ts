import { Module } from '@nestjs/common';
import { CatalogCommonModule } from '../common/catalog-common.module.js';
import { CatalogSyncController } from './catalog-sync.controller.js';
import { CatalogSyncCursorCodec } from './catalog-sync.cursor.js';
import { CatalogSyncService } from './catalog-sync.service.js';

/**
 * Офлайн-API каталога `GET /catalog/sync/{entity}` (RM-E-015; 08 §4.24, ядро §22.7). Зависимости — глобальные
 * PG_POOL, PermissionCatalog (RbacModule), SettingsReader, APP_CONFIG, OTP_HMAC_SECRET_RING (CryptoModule) и
 * `CatalogCommonModule` (правила зрителя: вид цены клиента, показ остатков — RM-E-004/RM-E-017).
 * Схема БД — миграция 0007 (индексы `(updated_at, id)`, журнал удалений `catalog_sync.deletions`).
 */
@Module({
  imports: [CatalogCommonModule],
  controllers: [CatalogSyncController],
  providers: [CatalogSyncService, CatalogSyncCursorCodec],
  exports: [CatalogSyncService, CatalogSyncCursorCodec],
})
export class CatalogSyncModule {}

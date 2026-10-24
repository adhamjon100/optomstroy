import { Module } from '@nestjs/common';
import { CatalogCursorCodec } from './catalog-cursor.js';
import { CatalogSnapshotService } from './catalog-snapshot.js';
import { CatalogViewerService } from './catalog-viewer.js';

/**
 * Общие службы каталога: правила зрителя (вид цены, склад, показ остатков — 08 §3.6), курсор keyset-пагинации
 * (08 §2.5), моменты снимков (`X-Data-As-Of`). Требует глобальные PG_POOL, APP_CONFIG, PermissionCatalog,
 * SettingsReader и OTP_HMAC_SECRET_RING (CryptoModule).
 */
@Module({
  providers: [CatalogViewerService, CatalogCursorCodec, CatalogSnapshotService],
  exports: [CatalogViewerService, CatalogCursorCodec, CatalogSnapshotService],
})
export class CatalogCommonModule {}

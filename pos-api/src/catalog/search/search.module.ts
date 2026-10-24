import { Module } from '@nestjs/common';
import { OtpHmacService } from '../../common/crypto/otp-hmac.service.js';
import { CatalogApiModule } from '../api/catalog-api.module.js';
import { SearchController } from './search.controller.js';
import { SearchCursorCodec } from './search-cursor.js';
import { SEARCH_CURSOR_CODEC, SearchService } from './search.service.js';

/**
 * Поиск товаров RM-E-005 / RM-E-014 (`/search/products`, `/search/suggest`, `/search/barcode/{value}`).
 *
 * Правила цен, остатков и состав `ProductSummary`/`Variant` — из Catalog API (RM-E-004): `CatalogApiModule`
 * экспортирует `CatalogProductsService` и `CatalogCommonModule` (`CatalogViewerService`, `CatalogSnapshotService`).
 * Глобальные зависимости — PG_POOL, APP_CONFIG, SettingsReader, PermissionCatalog, OtpHmacService (CryptoModule).
 * Подключение в приложение — `imports: [SearchModule]` в CatalogModule.
 */
@Module({
  imports: [CatalogApiModule],
  controllers: [SearchController],
  providers: [
    SearchService,
    {
      provide: SEARCH_CURSOR_CODEC,
      inject: [OtpHmacService],
      useFactory: (hmac: OtpHmacService) =>
        new SearchCursorCodec((body) => hmac.pseudonym('cursor:search.products', body)),
    },
  ],
  exports: [SearchService],
})
export class SearchModule {}

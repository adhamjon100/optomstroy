import { Module } from '@nestjs/common';
import { CatalogCommonModule } from '../common/catalog-common.module.js';
import { CatalogProductsService } from './catalog-products.service.js';
import { CatalogReferenceService } from './catalog-reference.service.js';
import { CatalogController } from './catalog.controller.js';

/**
 * Экранные эндпоинты каталога (08 §4.4.1–§4.4.4, §4.4.6; RM-E-004). `CatalogProductsService.summaries()` и
 * `productFilterSql()` экспортируются для поиска (`src/catalog/search`) и «Недавних» (`src/catalog/recent`).
 */
@Module({
  imports: [CatalogCommonModule],
  controllers: [CatalogController],
  providers: [CatalogProductsService, CatalogReferenceService],
  exports: [CatalogProductsService, CatalogReferenceService, CatalogCommonModule],
})
export class CatalogApiModule {}

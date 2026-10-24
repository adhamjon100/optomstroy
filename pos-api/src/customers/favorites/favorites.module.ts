import { Module } from '@nestjs/common';
import { CatalogApiModule } from '../../catalog/api/catalog-api.module.js';
import { CustomerCoreModule } from '../common/customer-core.module.js';
import { FavoritesCustomersController } from './favorites-customers.controller.js';
import { FavoritesCustomersService } from './favorites-customers.service.js';
import { FavoritesProductsController } from './favorites-products.controller.js';
import { FavoritesProductsService } from './favorites-products.service.js';

/**
 * Избранные товары (RM-E-006; 08 §4.13; модуль D-06 `customers (+favorites)`, 06 §7.4). Краткие карточки и правила
 * зрителя — экспорт каталога (`CatalogApiModule`: `CatalogProductsService.summaries()`, `CatalogViewerService`,
 * `CatalogCursorCodec`); ребро `customers → catalog` ацикличное (`catalog` не импортирует `customers`, MOD-022).
 * Избранные клиенты (`/favorites/customers`, этап G — RM-G-004/RM-G-011): `FavoritesCustomersService` над общими
 * сервисами клиентов (`CustomerCoreModule`), предел 12 карточек.
 */
@Module({
  imports: [CatalogApiModule, CustomerCoreModule],
  controllers: [FavoritesProductsController, FavoritesCustomersController],
  providers: [FavoritesProductsService, FavoritesCustomersService],
  exports: [FavoritesProductsService, FavoritesCustomersService],
})
export class FavoritesModule {}

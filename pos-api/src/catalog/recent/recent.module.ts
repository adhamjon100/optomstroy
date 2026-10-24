import { Module } from '@nestjs/common';
import { APP_INTERCEPTOR } from '@nestjs/core';
import { CatalogApiModule } from '../api/catalog-api.module.js';
import { RecentProductsController } from './recent-products.controller.js';
import { RecentProductsService } from './recent-products.service.js';
import { RecentViewInterceptor } from './recent-view.interceptor.js';

/**
 * «Недавние товары» (RM-E-006; 08 §4.4.5). Краткие карточки — `CatalogProductsService.summaries()` (RM-E-004), правила
 * зрителя — `CatalogViewerService`. Экспорт: `RecentProductsService.recordView()` (06 §7.4: orders/cart →
 * `RecentProductsService`) и `RecentViewInterceptor` (глобальный, APP_INTERCEPTOR) для обработчиков с меткой
 * `@RecordsRecentView()` (`src/catalog/common/recent-view.marker.ts`; карточка товара `GET /catalog/products/{id}`).
 * Подключается в `CatalogModule` **до** `CatalogApiModule` (статический `products/recent` раньше `products/:id`).
 */
@Module({
  imports: [CatalogApiModule],
  controllers: [RecentProductsController],
  // Глобальный интерсептор: действует только на обработчиках с `@RecordsRecentView()` (карточка товара RM-E-004).
  providers: [
    RecentProductsService,
    RecentViewInterceptor,
    { provide: APP_INTERCEPTOR, useExisting: RecentViewInterceptor },
  ],
  exports: [RecentProductsService, RecentViewInterceptor],
})
export class CatalogRecentModule {}

import { SetMetadata } from '@nestjs/common';

/** Ключ метаданных обработчика: «успешный ответ — отметка в «Недавних» (08 §4.4.3)». */
export const RECORDS_RECENT_VIEW = 'catalog:records-recent-view' as const;

/**
 * Метка обработчика карточки товара `GET /catalog/products/{id}` (08 §4.4.3; EQ-CSYNC-06): после успешного ответа
 * (2xx/304) товар записывается в `recent_products` асинхронно. Запись выполняет глобальный `RecentViewInterceptor`
 * модуля `src/catalog/recent` (APP_INTERCEPTOR), поэтому контроллер каталога не зависит от модуля «Недавних»
 * (`CatalogRecentModule` импортирует `CatalogApiModule` — обратный импорт дал бы цикл модулей).
 */
export const RecordsRecentView = (): MethodDecorator & ClassDecorator => SetMetadata(RECORDS_RECENT_VIEW, true);

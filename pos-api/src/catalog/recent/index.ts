/** «Недавние товары» (RM-E-006; 08 §4.4.5). */
export { parseRecentLimit, RecentProductsController } from './recent-products.controller.js';
export {
  RECENT_LIMIT_DEFAULT,
  RECENT_LIMIT_MAX,
  RECENT_MAX_ITEMS_DEFAULT,
  RECENT_MAX_ITEMS_KEY,
  type RecentProductDto,
  RecentProductsService,
} from './recent-products.service.js';
export { RecentViewInterceptor, RecordsRecentView } from './recent-view.interceptor.js';
export { CatalogRecentModule } from './recent.module.js';

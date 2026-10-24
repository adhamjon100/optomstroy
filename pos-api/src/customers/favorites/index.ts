/** Избранные товары (RM-E-006) и клиенты (RM-G-004, RM-G-011; 08 §4.13). */
export { FavoritesProductsController } from './favorites-products.controller.js';
export {
  FAVORITES_LIMIT_DEFAULT,
  FAVORITES_LIMIT_MAX,
  type FavoritesListQuery,
  type FavoritesPage,
  FavoritesProductsService,
} from './favorites-products.service.js';
export { FavoritesModule } from './favorites.module.js';
export { FavoritesCustomersController } from './favorites-customers.controller.js';
export {
  FAVORITE_CUSTOMERS_MAX,
  type FavoriteCustomersPage,
  FavoritesCustomersService,
} from './favorites-customers.service.js';

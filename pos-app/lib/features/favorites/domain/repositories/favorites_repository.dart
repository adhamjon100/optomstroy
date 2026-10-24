// Порты избранного товаров и недавних (08 §4.13: `/favorites/products`; §4.4: `/catalog/products/recent`;
// 07 §11.2: `favorites_products`, `recent_products`; D-32, FAV-). Чистый Dart (FL-01).
//
// Избранное клиента-покупателя и сотрудника — один контракт (`favorites.products.manage`, все роли).
// Офлайн-действия ставит в очередь `outbox_actions` core/sync (`favorite.add|remove`, `recent.clear`):
// репозиторий даёт локальную отметку `markPending` и серверные вызовы с `Idempotency-Key`.
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';

/// Страница избранного (`Page<ProductSummary>` + `count` — бейдж).
final class FavoriteProductsPage {
  const FavoriteProductsPage({required this.items, required this.count, required this.hasMore, this.nextCursor});

  final List<ProductSummary> items;

  /// Всего избранных товаров.
  final int count;
  final bool hasMore;
  final String? nextCursor;
}

abstract interface class FavoritesRepository {
  /// `GET /favorites/products?limit=&cursor=&warehouseId=`. Полный список без курсора (`hasMore=false`)
  /// заменяет локальную копию `favorites_products` (строки с `pending_op` сохраняются).
  Future<Result<FavoriteProductsPage>> list({int limit = 50, String? cursor, String? warehouseId});

  /// `PUT /favorites/products/{id}` (идемпотентно; `Idempotency-Key` — ключ записи outbox) → 204.
  Future<Result<void>> add(String productId, {required String idempotencyKey});

  /// `DELETE /favorites/products/{id}` (идемпотентно) → 204.
  Future<Result<void>> remove(String productId);

  /// Локальная отметка действия пользователя до подтверждения сервером (оптимистичный UI, офлайн).
  Future<Result<void>> markPending(String productId, {required bool add});

  /// Сервер подтвердил действие (`add` → обычная строка, `remove` → строка удалена).
  Future<Result<void>> confirmPending(String productId);

  /// Избранное из кэша с учётом неподтверждённых действий.
  Future<Result<Set<String>>> cachedIds();

  /// Поток избранного из кэша (пустое множество, пока БД пользователя не открыта).
  Stream<Set<String>> watchCachedIds();
}

abstract interface class RecentProductsRepository {
  /// `GET /catalog/products/recent?limit=` (1…50); ответ заменяет локальную копию `recent_products`.
  Future<Result<List<RecentProduct>>> list({int limit = 20});

  /// «Очистить»: `DELETE /catalog/products/recent` (идемпотентно) + локальная очистка.
  /// Офлайн — `clearLocal` + запись outbox `recent.clear` (core/sync).
  Future<Result<void>> clear();

  /// Только локальная очистка `recent_products`.
  Future<Result<void>> clearLocal();

  /// Отметка просмотра карточки в кэше (сервер пишет `recent_products` сам при `GET /catalog/products/{id}`).
  Future<Result<void>> touchLocal(String productId);

  /// Недавние из кэша (новые первыми, ≤ 50).
  Future<Result<List<String>>> cachedIds({int limit = 50});
}

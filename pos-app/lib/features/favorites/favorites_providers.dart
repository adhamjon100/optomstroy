// Публичный контракт фичи favorites (06 §6.1 L-3 (2); FL-07): провайдеры портов domain.
// Реализации — `data/favorites_bindings.dart`, подключаются `app/di/overrides.dart` (L-8).
// В widget-тестах — `favoritesRepositoryProvider.overrideWithValue(fake)`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/favorites/domain/repositories/favorites_repository.dart';

Never _unbound(String name) => throw UnimplementedError('$name: подключите favoritesBindings в app/di/overrides.dart');

/// Избранное товаров (`/favorites/products`).
final favoritesRepositoryProvider = Provider<FavoritesRepository>((ref) => _unbound('favoritesRepositoryProvider'));

/// Недавние товары (`/catalog/products/recent`).
final recentProductsRepositoryProvider = Provider<RecentProductsRepository>(
  (ref) => _unbound('recentProductsRepositoryProvider'),
);

// Привязка реализаций data к провайдерам-интерфейсам фичи favorites (06 §6.10, L-8, FL-06).
// Подключение: `app/di/overrides.dart` → `appOverrides = [..., ...favoritesBindings]`.
// Разбор `ProductSummary` — порт catalog `catalogJsonDecoderProvider` (DAG: favorites → catalog).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/favorites/data/datasources/favorites_remote_data_source.dart';
import 'package:optomstroy/features/favorites/data/repositories/favorites_repositories_impl.dart';
import 'package:optomstroy/features/favorites/favorites_providers.dart';

/// `FavoritesRemoteDataSource` поверх общего Dio (внутренний провайдер data).
final favoritesRemoteDataSourceProvider = Provider<FavoritesRemoteDataSource>(
  (ref) => FavoritesRemoteDataSource(ref.watch(dioProvider), ref.watch(catalogJsonDecoderProvider)),
);

/// Переопределения фичи favorites для композиционного корня.
final List<Override> favoritesBindings = <Override>[
  favoritesRepositoryProvider.overrideWith(
    (Ref ref) => FavoritesRepositoryImpl(
      remote: ref.watch(favoritesRemoteDataSourceProvider),
      dao: () => ref.read(appDatabaseProvider)?.favoritesDao,
      clock: ref.watch(clockProvider),
    ),
  ),
  recentProductsRepositoryProvider.overrideWith(
    (Ref ref) => RecentProductsRepositoryImpl(
      remote: ref.watch(favoritesRemoteDataSourceProvider),
      dao: () => ref.read(appDatabaseProvider)?.favoritesDao,
      clock: ref.watch(clockProvider),
    ),
  ),
];

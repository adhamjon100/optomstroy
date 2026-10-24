// Реализации портов избранного и недавних: сеть — `FavoritesRemoteDataSource`, кэш — `FavoritesDao`
// (07 §11.2). Ошибки — через `ErrorMapper` (06 §6.8); без БД пользователя — `UnknownFailure`.
import 'package:optomstroy/core/database/daos/favorites_dao.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/favorites/data/datasources/favorites_remote_data_source.dart';
import 'package:optomstroy/features/favorites/domain/repositories/favorites_repository.dart';

typedef FavoritesDaoAccess = FavoritesDao? Function();

Future<Result<T>> _local<T>(FavoritesDaoAccess dao, Future<T> Function(FavoritesDao dao) body) async {
  final d = dao();
  if (d == null) return const FailureResult(UnknownFailure(cause: CatalogCacheUnavailable()));
  try {
    return Success<T>(await body(d));
  } on Object catch (e) {
    return FailureResult<T>(UnknownFailure(cause: e));
  }
}

final class FavoritesRepositoryImpl implements FavoritesRepository {
  FavoritesRepositoryImpl({
    required FavoritesRemoteDataSource remote,
    required FavoritesDaoAccess dao,
    required Clock clock,
  }) : _remote = remote,
       _dao = dao,
       _clock = clock;

  final FavoritesRemoteDataSource _remote;
  final FavoritesDaoAccess _dao;
  final Clock _clock;

  int get _now => _clock.nowUtc().millisecondsSinceEpoch;

  @override
  Future<Result<FavoriteProductsPage>> list({int limit = 50, String? cursor, String? warehouseId}) =>
      ErrorMapper.guard(() async {
        final page = await _remote.list(limit: limit, cursor: cursor, warehouseId: warehouseId);
        final dao = _dao();
        if (dao != null && cursor == null && !page.hasMore) {
          await dao.replaceFavoritesFromServer([for (final p in page.items) p.id], nowMs: _now);
        }
        return page;
      });

  @override
  Future<Result<void>> add(String productId, {required String idempotencyKey}) =>
      ErrorMapper.guard(() => _remote.add(productId, idempotencyKey: idempotencyKey));

  @override
  Future<Result<void>> remove(String productId) => ErrorMapper.guard(() => _remote.remove(productId));

  @override
  Future<Result<void>> markPending(String productId, {required bool add}) =>
      _local(_dao, (dao) => dao.markFavoritePending(productId, add: add, nowMs: _now));

  @override
  Future<Result<void>> confirmPending(String productId) => _local(_dao, (dao) => dao.confirmFavorite(productId));

  @override
  Future<Result<Set<String>>> cachedIds() => _local(_dao, (dao) => dao.favoriteProductIds());

  @override
  Stream<Set<String>> watchCachedIds() => _dao()?.watchFavoriteProductIds() ?? Stream<Set<String>>.value(<String>{});
}

final class RecentProductsRepositoryImpl implements RecentProductsRepository {
  RecentProductsRepositoryImpl({
    required FavoritesRemoteDataSource remote,
    required FavoritesDaoAccess dao,
    required Clock clock,
  }) : _remote = remote,
       _dao = dao,
       _clock = clock;

  final FavoritesRemoteDataSource _remote;
  final FavoritesDaoAccess _dao;
  final Clock _clock;

  @override
  Future<Result<List<RecentProduct>>> list({int limit = 20}) => ErrorMapper.guard(() async {
    final items = await _remote.recent(limit: limit);
    await _dao()?.replaceRecentFromServer([
      for (final i in items) (productId: i.product.id, viewedAtMs: i.viewedAt.toUtc().millisecondsSinceEpoch),
    ]);
    return items;
  });

  @override
  Future<Result<void>> clear() => ErrorMapper.guard(() async {
    await _remote.clearRecent();
    await _dao()?.clearRecent();
  });

  @override
  Future<Result<void>> clearLocal() => _local(_dao, (dao) => dao.clearRecent());

  @override
  Future<Result<void>> touchLocal(String productId) =>
      _local(_dao, (dao) => dao.touchRecent(productId, nowMs: _clock.nowUtc().millisecondsSinceEpoch));

  @override
  Future<Result<List<String>>> cachedIds({int limit = 50}) =>
      _local(_dao, (dao) async => [for (final r in await dao.recentProducts(limit: limit)) r.productId]);
}

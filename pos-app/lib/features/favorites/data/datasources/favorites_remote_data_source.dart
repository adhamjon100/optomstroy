// HTTP-вызовы избранного товаров и недавних поверх общего Dio-клиента (core/network).
// `ProductSummary` разбирает порт catalog `CatalogJsonDecoder` (ADR-085; FL-06 — без импорта catalog/data).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_json_decoder.dart';
import 'package:optomstroy/features/favorites/domain/repositories/favorites_repository.dart';

/// Ответ не соответствует контракту.
final class FavoritesDtoException implements Exception {
  const FavoritesDtoException(this.field);

  final String field;

  @override
  String toString() => 'FavoritesDtoException($field)';
}

final class FavoritesRemoteDataSource {
  const FavoritesRemoteDataSource(this._dio, this._decoder);

  final Dio _dio;
  final CatalogJsonDecoder _decoder;

  static const String favoritesPath = '/favorites/products';
  static const String recentPath = '/catalog/products/recent';

  static String favoritePath(String productId) => '$favoritesPath/${Uri.encodeComponent(productId)}';

  static Map<String, dynamic> _json(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    throw const FavoritesDtoException('body');
  }

  static List<Object?> _items(Map<String, dynamic> body) {
    final items = body['items'];
    if (items is List) return items;
    throw const FavoritesDtoException('items');
  }

  /// `GET /favorites/products` → `Page<ProductSummary>` + `count`.
  Future<FavoriteProductsPage> list({int limit = 50, String? cursor, String? warehouseId}) async {
    final r = await _dio.get<Object?>(
      favoritesPath,
      queryParameters: {'limit': limit.clamp(1, 200), 'cursor': ?cursor, 'warehouseId': ?warehouseId},
    );
    final body = _json(r.data);
    final hasMore = body['hasMore'];
    final count = body['count'];
    if (hasMore is! bool) throw const FavoritesDtoException('hasMore');
    if (count is! int) throw const FavoritesDtoException('count');
    final nextCursor = body['nextCursor'];
    return FavoriteProductsPage(
      items: [for (final item in _items(body)) _decoder.productSummary(item)],
      count: count,
      hasMore: hasMore,
      nextCursor: nextCursor is String ? nextCursor : null,
    );
  }

  /// `PUT /favorites/products/{id}` → 204.
  Future<void> add(String productId, {required String idempotencyKey}) =>
      _dio.put<Object?>(favoritePath(productId), options: apiOptions(idempotencyKey: idempotencyKey));

  /// `DELETE /favorites/products/{id}` → 204.
  Future<void> remove(String productId) => _dio.delete<Object?>(favoritePath(productId));

  /// `GET /catalog/products/recent?limit=` (1…50).
  Future<List<RecentProduct>> recent({int limit = 20}) async {
    final r = await _dio.get<Object?>(recentPath, queryParameters: {'limit': limit.clamp(1, 50)});
    return [for (final item in _items(_json(r.data))) _decoder.recentProduct(item)];
  }

  /// `DELETE /catalog/products/recent` → 204.
  Future<void> clearRecent() => _dio.delete<Object?>(recentPath);
}

// Композиция «кэш → сеть» для портов каталога (RM-E-009; D-32; 06 §6.12; 07 §11.4):
// - нет связи (`OnlineStatus.offline`) — сразу локальный кэш drift (без ожидания таймаута сети);
// - иначе — сеть; при `NetworkFailure` (нет соединения, таймаут, 502–504) — тот же запрос из кэша
//   (`CatalogPage.source = cache`, `asOf` — `sync_meta.as_of`); если в кэше ничего нет — исходная ошибка;
// - ошибки сервера (4xx/5xx с problem+json) кэшем не подменяются.
// Сетевые и `cached*` методы базовых реализаций (`CatalogRepositoryImpl` и др.) не меняются — обёртка
// подключается вместо них списком `catalogOfflineFirstBindings` (data/local/catalog_offline_bindings.dart).
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/inventory.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';

/// Текущая доступность backend (`ConnectivityWatcher.current`).
typedef OnlineProbe = OnlineStatus Function();

/// Сеть с переходом на кэш при отсутствии связи.
Future<Result<T>> networkThenCache<T>({
  required OnlineProbe online,
  required Future<Result<T>> Function() network,
  required Future<Result<T?>> Function() cache,
}) async {
  if (online() == OnlineStatus.offline) {
    final cached = await cache();
    final value = cached.valueOrNull;
    if (value != null) return Success<T>(value);
    return FailureResult<T>(cached.failureOrNull ?? const NetworkFailure(NetworkFailureKind.offline));
  }
  final r = await network();
  if (r.failureOrNull is! NetworkFailure) return r;
  final cached = await cache();
  final value = cached.valueOrNull;
  return value != null ? Success<T>(value) : r;
}

final class OfflineFirstCatalogRepository implements CatalogRepository {
  const OfflineFirstCatalogRepository({required CatalogRepository base, required OnlineProbe online})
    : _base = base,
      _online = online;

  final CatalogRepository _base;
  final OnlineProbe _online;

  @override
  Future<Result<CategoryTree>> categories({
    String? parentId,
    int? depth,
    bool includeEmpty = false,
    bool inStockOnly = false,
  }) => networkThenCache(
    online: _online,
    network: () =>
        _base.categories(parentId: parentId, depth: depth, includeEmpty: includeEmpty, inStockOnly: inStockOnly),
    cache: () async {
      final r = await _base.cachedCategories();
      final tree = r.valueOrNull;
      // Пустое дерево кэша — данных нет (первичная загрузка ещё не дошла до категорий).
      if (tree != null && tree.roots.isEmpty) return const Success<CategoryTree?>(null);
      return r;
    },
  );

  @override
  Future<Result<CatalogPage<ProductSummary>>> products(CatalogQuery query) => networkThenCache(
    online: _online,
    network: () => _base.products(query),
    cache: () => _base.cachedProducts(query.next(_offsetCursor(query.cursor))),
  );

  @override
  Future<Result<Product>> product(
    String productId, {
    String? warehouseId,
    String? priceListId,
    Set<ProductInclude> include = ProductInclude.all,
  }) => networkThenCache(
    online: _online,
    network: () => _base.product(productId, warehouseId: warehouseId, priceListId: priceListId, include: include),
    cache: () => _base.cachedProduct(productId, warehouseId: warehouseId, priceListId: priceListId),
  );

  @override
  Future<Result<VariantList>> variants(
    String productId, {
    String? warehouseId,
    String? priceListId,
    bool? inStockOnly,
  }) => networkThenCache(
    online: _online,
    network: () =>
        _base.variants(productId, warehouseId: warehouseId, priceListId: priceListId, inStockOnly: inStockOnly),
    cache: () async {
      final r = await _base.cachedProduct(productId, warehouseId: warehouseId, priceListId: priceListId);
      return r.map((p) {
        if (p == null) return null;
        final items = inStockOnly == true
            ? [
                for (final v in p.variants)
                  if (v.stockByWarehouse.any((s) => s.allowsAddToCart)) v,
              ]
            : p.variants;
        return VariantList(items: items);
      });
    },
  );

  @override
  Future<Result<List<Unit>>> units() => _base.units();

  @override
  Future<Result<List<PriceList>>> priceLists() => _base.priceLists();

  @override
  Future<Result<List<Warehouse>>> warehouses() => _base.warehouses();

  @override
  Future<Result<CategoryTree>> cachedCategories() => _base.cachedCategories();

  @override
  Future<Result<CatalogPage<ProductSummary>>> cachedProducts(CatalogQuery query) => _base.cachedProducts(query);

  @override
  Future<Result<Product?>> cachedProduct(String productId, {String? warehouseId, String? priceListId}) =>
      _base.cachedProduct(productId, warehouseId: warehouseId, priceListId: priceListId);
}

final class OfflineFirstSearchRepository implements SearchRepository {
  const OfflineFirstSearchRepository({required SearchRepository base, required OnlineProbe online})
    : _base = base,
      _online = online;

  final SearchRepository _base;
  final OnlineProbe _online;

  @override
  Future<Result<SearchResult>> searchProducts(SearchQuery query) => networkThenCache(
    online: _online,
    network: () => _base.searchProducts(query),
    cache: () => _base.searchCached(query.next(_offsetCursor(query.cursor))),
  );

  @override
  Future<Result<List<SearchSuggestion>>> suggest(String q, {int? limit}) async {
    // Подсказки офлайн не строятся (SCR-11: офлайн — сразу поиск по кэшу).
    if (_online() == OnlineStatus.offline) return const Success(<SearchSuggestion>[]);
    final r = await _base.suggest(q, limit: limit);
    return r.failureOrNull is NetworkFailure ? const Success(<SearchSuggestion>[]) : r;
  }

  @override
  Future<Result<BarcodeLookup>> barcode(String value, {String? warehouseId}) => networkThenCache(
    online: _online,
    network: () => _base.barcode(value, warehouseId: warehouseId),
    cache: () => _base.barcodeCached(value, warehouseId: warehouseId),
  );

  @override
  Future<Result<SearchResult>> searchCached(SearchQuery query) => _base.searchCached(query);

  @override
  Future<Result<BarcodeLookup?>> barcodeCached(String value, {String? warehouseId, String? priceListId}) =>
      _base.barcodeCached(value, warehouseId: warehouseId, priceListId: priceListId);
}

final class OfflineFirstInventoryRepository implements InventoryRepository {
  const OfflineFirstInventoryRepository({required InventoryRepository base, required OnlineProbe online})
    : _base = base,
      _online = online;

  final InventoryRepository _base;
  final OnlineProbe _online;

  @override
  Future<Result<InventoryBalances>> balances(List<String> variantIds, {String? warehouseId, bool live = false}) =>
      networkThenCache(
        online: _online,
        network: () => _base.balances(variantIds, warehouseId: warehouseId, live: live),
        cache: () async {
          final r = await _base.cachedBalances(variantIds, warehouseId: warehouseId);
          final v = r.valueOrNull;
          if (v != null && v.items.isEmpty) return const Success<InventoryBalances?>(null);
          return r;
        },
      );

  /// Проверка наличия — только онлайн (решение принимает сервер, D-22).
  @override
  Future<Result<InventoryCheckResult>> check(
    String warehouseId,
    List<InventoryCheckLine> lines, {
    String? idempotencyKey,
  }) => _base.check(warehouseId, lines, idempotencyKey: idempotencyKey);

  @override
  Future<Result<InventoryBalances>> cachedBalances(List<String> variantIds, {String? warehouseId}) =>
      _base.cachedBalances(variantIds, warehouseId: warehouseId);
}

/// Курсор сети непрозрачен; в кэше курсор — смещение. Чужой курсор → с начала.
String? _offsetCursor(String? cursor) => cursor != null && int.tryParse(cursor) != null ? cursor : null;

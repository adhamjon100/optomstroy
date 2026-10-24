// Реализации портов каталога: сеть — `CatalogRemoteDataSource` (Dio), кэш — `CatalogDao` (drift).
// Ошибки сети/сервера → `Failure` только через `ErrorMapper` (06 §6.8). Без открытой БД
// пользователя методы кэша возвращают `UnknownFailure(cause: CatalogCacheUnavailable())`.
// Курсор кэшированных страниц — смещение (строка с числом).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/catalog/data/datasources/catalog_remote_data_source.dart';
import 'package:optomstroy/features/catalog/data/dto/catalog_dtos.dart';
import 'package:optomstroy/features/catalog/data/dto/json_read.dart';
import 'package:optomstroy/features/catalog/data/mappers/catalog_mappers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/inventory.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/domain/entities/sync.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_json_decoder.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';

/// Доступ к кэшу: `null` — БД пользователя ещё не открыта (до входа).
typedef CatalogDaoAccess = CatalogDao? Function();

Future<Result<T>> _local<T>(CatalogDaoAccess dao, Future<T> Function(CatalogDao dao) body) async {
  final d = dao();
  if (d == null) return const FailureResult(UnknownFailure(cause: CatalogCacheUnavailable()));
  try {
    return Success<T>(await body(d));
  } on Object catch (e) {
    return FailureResult<T>(UnknownFailure(cause: e));
  }
}

int _offset(String? cursor) => cursor == null ? 0 : (int.tryParse(cursor) ?? 0).clamp(0, 1 << 30);

CatalogLocalFilter _localFilter(CatalogFilter f, {List<String>? productIds}) => CatalogLocalFilter(
  categoryId: f.categoryId,
  includeSubcategories: f.includeSubcategories,
  priceListId: f.priceListId,
  warehouseId: f.warehouseId,
  inStock: f.inStock ?? false,
  priceMinTyiyn: f.priceMin?.tyiyn,
  priceMaxTyiyn: f.priceMax?.tyiyn,
  brands: f.brands,
  attrs: f.attrs,
  favoriteOnly: f.favorite ?? false,
  hasImage: f.hasImage ?? false,
  productIds: productIds,
);

CatalogPage<ProductSummary> _cachedPage(CachedProductPage page, {required int limit, DateTime? asOf}) =>
    CatalogPage<ProductSummary>(
      items: [for (final r in page.rows) summaryFromListRow(r)],
      hasMore: page.hasMore,
      nextCursor: page.hasMore ? '${page.offset + page.rows.length}' : null,
      totalEstimate: page.total,
      asOf: asOf,
      source: DataSource.cache,
    );

Future<DateTime?> _metaAsOf(CatalogDao dao, String entity) async => fromUnixMs((await dao.syncMetaOf(entity))?.asOf);

// ---------------------------------------------------------------------------

final class CatalogRepositoryImpl implements CatalogRepository {
  CatalogRepositoryImpl({required CatalogRemoteDataSource remote, required CatalogDaoAccess dao})
    : _remote = remote,
      _dao = dao;

  final CatalogRemoteDataSource _remote;
  final CatalogDaoAccess _dao;

  @override
  Future<Result<CategoryTree>> categories({
    String? parentId,
    int? depth,
    bool includeEmpty = false,
    bool inStockOnly = false,
  }) => ErrorMapper.guard(() async {
    final r = await _remote.categories(
      parentId: parentId,
      depth: depth,
      includeEmpty: includeEmpty,
      inStockOnly: inStockOnly,
    );
    final tree = r.value.toEntity();
    return CategoryTree(roots: tree.roots, asOf: tree.asOf ?? r.dataAsOf, snapshotVersion: tree.snapshotVersion);
  });

  @override
  Future<Result<CatalogPage<ProductSummary>>> products(CatalogQuery query) => ErrorMapper.guard(() async {
    final r = await _remote.products(query);
    return productPageFromDto(r.value, dataAsOf: r.dataAsOf);
  });

  @override
  Future<Result<Product>> product(
    String productId, {
    String? warehouseId,
    String? priceListId,
    Set<ProductInclude> include = ProductInclude.all,
  }) => ErrorMapper.guard(() async {
    final r = await _remote.product(
      productId,
      warehouseId: warehouseId,
      priceListId: priceListId,
      include: include.length == ProductInclude.all.length ? null : [for (final i in include) i.value],
    );
    return r.value.toEntity();
  });

  @override
  Future<Result<VariantList>> variants(
    String productId, {
    String? warehouseId,
    String? priceListId,
    bool? inStockOnly,
  }) => ErrorMapper.guard(() async {
    final r = await _remote.variants(
      productId,
      warehouseId: warehouseId,
      priceListId: priceListId,
      inStockOnly: inStockOnly,
    );
    return r.toEntity();
  });

  @override
  Future<Result<List<Unit>>> units() =>
      ErrorMapper.guard(() async => [for (final u in await _remote.units()) u.toEntity()]);

  @override
  Future<Result<List<PriceList>>> priceLists() =>
      ErrorMapper.guard(() async => [for (final p in await _remote.priceLists()) p.toEntity()]);

  @override
  Future<Result<List<Warehouse>>> warehouses() =>
      ErrorMapper.guard(() async => [for (final w in await _remote.warehouses()) w.toEntity()]);

  @override
  Future<Result<CategoryTree>> cachedCategories() => _local(
    _dao,
    (dao) async => categoryTreeFromRows(await dao.visibleCategories(), asOf: await _metaAsOf(dao, 'categories')),
  );

  @override
  Future<Result<CatalogPage<ProductSummary>>> cachedProducts(CatalogQuery query) => _local(_dao, (dao) async {
    final page = await dao.listProducts(
      filter: _localFilter(query.filter),
      sort: (query.sort ?? CatalogSort.nameAsc).value,
      limit: query.limit.clamp(1, CatalogQuery.maxLimit),
      offset: _offset(query.cursor),
    );
    return _cachedPage(page, limit: query.limit, asOf: await _metaAsOf(dao, 'products'));
  });

  @override
  Future<Result<Product?>> cachedProduct(String productId, {String? warehouseId, String? priceListId}) =>
      _local(_dao, (dao) async {
        final card = await dao.productCard(productId);
        return card == null ? null : productFromCard(card, priceListId: priceListId, warehouseId: warehouseId);
      });
}

// ---------------------------------------------------------------------------

final class SearchRepositoryImpl implements SearchRepository {
  SearchRepositoryImpl({required CatalogRemoteDataSource remote, required CatalogDaoAccess dao})
    : _remote = remote,
      _dao = dao;

  final CatalogRemoteDataSource _remote;
  final CatalogDaoAccess _dao;

  /// Токен текущего запроса первой страницы поиска: новый запрос (шаг debounce 300 мс) отменяет предыдущий
  /// (06 §6.7 «CancelToken», D-31); ответ отменённого игнорируется и вызывающим (номер запроса).
  CancelToken? _searchToken;

  @override
  Future<Result<SearchResult>> searchProducts(SearchQuery query) => ErrorMapper.guard(() async {
    CancelToken? token;
    if (query.cursor == null) {
      _searchToken?.cancel('superseded');
      token = _searchToken = CancelToken();
    }
    final r = await _remote.searchProducts(
      q: query.q,
      filter: query.filter,
      sort: query.sort,
      limit: query.limit,
      cursor: query.cursor,
      cancelToken: token,
    );
    return searchResultFromDto(r.value, q: query.q, dataAsOf: r.dataAsOf);
  });

  @override
  Future<Result<List<SearchSuggestion>>> suggest(String q, {int? limit}) => ErrorMapper.guard(
    () async => [
      for (final s in await _remote.suggest(q, limit: limit))
        SearchSuggestion(text: s.text, kind: SuggestionKind.parse(s.kind), id: s.id, count: s.count),
    ],
  );

  @override
  Future<Result<BarcodeLookup>> barcode(String value, {String? warehouseId}) => ErrorMapper.guard(() async {
    final r = await _remote.barcode(value, warehouseId: warehouseId);
    final lookup = r.value.toEntity();
    return BarcodeLookup(
      product: lookup.product,
      variant: lookup.variant,
      packaging: lookup.packaging,
      barcodeType: lookup.barcodeType,
      suggestedQuantity: lookup.suggestedQuantity,
      suggestedUnitId: lookup.suggestedUnitId,
      warnings: lookup.warnings,
      asOf: r.dataAsOf,
    );
  });

  @override
  Future<Result<SearchResult>> searchCached(SearchQuery query) => _local(_dao, (dao) async {
    final page = await dao.searchProducts(
      query.q,
      filter: _localFilter(query.filter),
      sort: query.sort.value,
      limit: query.limit.clamp(1, CatalogQuery.maxLimit),
      offset: _offset(query.cursor),
    );
    final items = _cachedPage(page, limit: query.limit, asOf: await _metaAsOf(dao, 'products'));
    var barcode = 0;
    var sku = 0;
    var fts = 0;
    for (final r in page.rows) {
      switch (r.matchType) {
        case 'barcode':
          barcode++;
        case 'sku':
          sku++;
        default:
          fts++;
      }
    }
    return SearchResult(
      page: items,
      query: query.q,
      matchTypes: SearchMatchCounts(barcode: barcode, sku: sku, fts: fts),
    );
  });

  @override
  Future<Result<BarcodeLookup?>> barcodeCached(String value, {String? warehouseId, String? priceListId}) =>
      _local(_dao, (dao) async {
        final row = await dao.barcodeByValue(value.trim());
        if (row == null || row.productId.isEmpty) return null;
        final card = await dao.productCard(row.productId);
        if (card == null) return null;
        final product = productFromCard(card, priceListId: priceListId, warehouseId: warehouseId);
        final variant = product.variants.where((v) => v.id == row.variantId).firstOrNull ?? product.defaultVariant;
        if (variant == null) return null;
        return BarcodeLookup(
          product: product.summary.copyWith(matchType: MatchType.barcode),
          variant: variant,
          packaging: product.packagings.where((p) => p.id == row.packagingId).firstOrNull,
          barcodeType: BarcodeType.tryParse(row.barcodeType) ?? BarcodeType.other,
          source: DataSource.cache,
          asOf: await _metaAsOf(dao, 'stock') ?? await _metaAsOf(dao, 'barcodes'),
        );
      });
}

// ---------------------------------------------------------------------------

final class InventoryRepositoryImpl implements InventoryRepository {
  InventoryRepositoryImpl({required CatalogRemoteDataSource remote, required CatalogDaoAccess dao})
    : _remote = remote,
      _dao = dao;

  final CatalogRemoteDataSource _remote;
  final CatalogDaoAccess _dao;

  @override
  Future<Result<InventoryBalances>> balances(List<String> variantIds, {String? warehouseId, bool live = false}) =>
      ErrorMapper.guard(() async {
        final r = await _remote.balances(variantIds, warehouseId: warehouseId, live: live);
        return r.toEntity();
      });

  @override
  Future<Result<InventoryCheckResult>> check(
    String warehouseId,
    List<InventoryCheckLine> lines, {
    String? idempotencyKey,
  }) => ErrorMapper.guard(() async {
    final body = InventoryCheckRequestDto(
      warehouseId: warehouseId,
      items: [
        for (final l in lines)
          (
            variantId: l.variantId,
            quantity: QuantityDto(value: l.quantity.toApiString(), unitId: l.unitId, packagingId: l.packagingId),
          ),
      ],
    );
    return (await _remote.check(body, idempotencyKey: idempotencyKey)).toEntity();
  });

  @override
  Future<Result<InventoryBalances>> cachedBalances(List<String> variantIds, {String? warehouseId}) =>
      _local(_dao, (dao) async {
        final rows = await dao.stockFor(variantIds, warehouseId: warehouseId);
        final names = {for (final w in await dao.allWarehouses()) w.id: w.name};
        final asOf = rows.isEmpty ? null : rows.map((r) => r.snapshotAt).reduce((a, b) => a > b ? a : b);
        return InventoryBalances(
          items: [for (final r in rows) stockFromRow(r, warehouseName: names[r.warehouseId])],
          asOf: fromUnixMs(asOf),
          origin: DataSource.cache,
        );
      });
}

// ---------------------------------------------------------------------------

final class CatalogSyncRepositoryImpl implements CatalogSyncRepository {
  CatalogSyncRepositoryImpl({
    required CatalogRemoteDataSource remote,
    required CatalogDaoAccess dao,
    required AppMetaDao? Function() appMeta,
    required Clock clock,
  }) : _remote = remote,
       _dao = dao,
       _appMeta = appMeta,
       _clock = clock;

  final CatalogRemoteDataSource _remote;
  final CatalogDaoAccess _dao;
  final AppMetaDao? Function() _appMeta;
  final Clock _clock;

  static const String _cursorExpired = 'cursor_expired';

  static Failure? _check(CatalogSyncEntity entity, CatalogDao? dao) {
    if (dao == null) return const UnknownFailure(cause: CatalogCacheUnavailable());
    if (!entity.cached) return UnknownFailure(cause: ArgumentError.value(entity.value, 'entity', 'не кэшируется'));
    return null;
  }

  @override
  Future<Result<CatalogSyncProgress>> pullPage(CatalogSyncEntity entity, {int limit = 200, String? warehouseId}) async {
    final dao = _dao();
    final invalid = _check(entity, dao);
    if (invalid != null) return FailureResult(invalid);
    try {
      final (progress, _) = await _page(dao!, entity, limit: limit, warehouseId: warehouseId, collectKeys: false);
      return Success(progress);
    } on DioException catch (e) {
      final failure = ErrorMapper.fromDio(e);
      await _recordError(dao!, entity, failure);
      return FailureResult(failure);
    } on Object catch (e) {
      return FailureResult(UnknownFailure(cause: e));
    }
  }

  @override
  Future<Result<CatalogSyncProgress>> syncEntity(
    CatalogSyncEntity entity, {
    bool restart = false,
    int limit = 200,
    String? warehouseId,
    void Function(CatalogSyncProgress progress)? onPage,
  }) async {
    final dao = _dao();
    final invalid = _check(entity, dao);
    if (invalid != null) return FailureResult(invalid);
    var retriedExpired = false;
    var shouldRestart = restart;
    while (true) {
      try {
        if (shouldRestart) await dao!.resetSyncCursor(entity.value);
        final fromStart = (await dao!.syncMetaOf(entity.value))?.serverCursor == null;
        final keys = <String>{};
        var pages = 0;
        var upserted = 0;
        var deleted = 0;
        CatalogSyncProgress last;
        do {
          final (progress, pageKeys) = await _page(
            dao,
            entity,
            limit: limit,
            warehouseId: warehouseId,
            collectKeys: fromStart,
          );
          keys.addAll(pageKeys);
          pages++;
          upserted += progress.upserted;
          deleted += progress.deleted;
          last = CatalogSyncProgress(
            entity: entity,
            pages: pages,
            upserted: upserted,
            deleted: deleted,
            completed: progress.completed,
            cursor: progress.cursor,
            serverTime: progress.serverTime,
            fullReload: fromStart,
          );
          onPage?.call(last);
        } while (!last.completed);
        if (fromStart) {
          await dao.retainOnly(entity.value, keys, nowMs: toUnixMs(_clock.nowUtc()));
        }
        return Success(last);
      } on DioException catch (e) {
        final failure = ErrorMapper.fromDio(e);
        final expired =
            failure is ConflictFailure &&
            failure.kind == ConflictKind.versionConflict &&
            failure.reason == _cursorExpired;
        if (expired && !retriedExpired) {
          // Курсор старше срока хранения удалений (08 §4.24) — повтор сущности без `since`.
          retriedExpired = true;
          shouldRestart = true;
          continue;
        }
        await _recordError(dao!, entity, failure);
        return FailureResult(failure);
      } on Object catch (e) {
        return FailureResult(UnknownFailure(cause: e));
      }
    }
  }

  Future<(CatalogSyncProgress, Set<String>)> _page(
    CatalogDao dao,
    CatalogSyncEntity entity, {
    required int limit,
    required bool collectKeys,
    String? warehouseId,
  }) async {
    final since = (await dao.syncMetaOf(entity.value))?.serverCursor;
    final dto = await _remote.syncPage(entity.value, since: since, limit: limit, warehouseId: warehouseId);
    final page = syncItemsToRows(entity, dto.items, serverTime: dto.serverTime);
    await dao.applySyncPage(
      entity: entity.value,
      rows: page.rows,
      deletedIds: dto.deleted,
      cursor: dto.nextCursor,
      asOfMs: toUnixMs(dto.serverTime),
      nowMs: toUnixMs(_clock.nowUtc()),
      completed: !dto.hasMore,
    );
    return (
      CatalogSyncProgress(
        entity: entity,
        pages: 1,
        upserted: page.rows.length,
        deleted: dto.deleted.length,
        completed: !dto.hasMore,
        cursor: dto.nextCursor,
        serverTime: dto.serverTime,
        fullReload: since == null,
      ),
      collectKeys ? page.keys : const <String>{},
    );
  }

  Future<void> _recordError(CatalogDao dao, CatalogSyncEntity entity, Failure failure) async {
    final code = switch (failure) {
      ServerFailure(:final code) => code,
      NetworkFailure(:final kind) => 'NETWORK_${kind.name}',
      ConflictFailure(:final kind) => 'CONFLICT_${kind.name}',
      _ => failure.runtimeType.toString(),
    };
    try {
      await dao.recordSyncError(entity.value, code);
    } on Object {
      // Метка ошибки — вспомогательная; её сбой не меняет результат загрузки.
    }
  }

  @override
  Future<Result<List<LocalSyncState>>> localStates() =>
      _local(_dao, (dao) async => [for (final r in await dao.allSyncMeta()) ?localSyncStateFromRow(r)]);

  @override
  Future<Result<void>> saveStaleThresholds(SyncStatusInfo status) => _local(_dao, (dao) async {
    for (final e in status.entities) {
      final local = switch (e.entityValue) {
        'stock' ||
        'prices' ||
        'categories' ||
        'products' ||
        'variants' ||
        'units' ||
        'barcodes' ||
        'images' ||
        'warehouses' => e.entityValue,
        _ => null,
      };
      if (local != null) await dao.saveStaleThreshold(local, e.staleAfter?.inSeconds);
    }
  });

  @override
  Future<Result<DateTime?>> fullLoadedAt() async {
    final meta = _appMeta();
    if (meta == null) return const FailureResult(UnknownFailure(cause: CatalogCacheUnavailable()));
    try {
      final v = await meta.read(AppMetaDao.catalogFullLoadedAtKey);
      return Success(v == null ? null : fromUnixMs(int.tryParse(v)));
    } on Object catch (e) {
      return FailureResult(UnknownFailure(cause: e));
    }
  }

  @override
  Future<Result<void>> markFullLoaded(DateTime at) async {
    final meta = _appMeta();
    if (meta == null) return const FailureResult(UnknownFailure(cause: CatalogCacheUnavailable()));
    try {
      await meta.write(AppMetaDao.catalogFullLoadedAtKey, '${toUnixMs(at)}');
      return const Success(null);
    } on Object catch (e) {
      return FailureResult(UnknownFailure(cause: e));
    }
  }

  @override
  Future<Result<int>> cachedProductCount() => _local(_dao, (dao) => dao.productCount());
}

// ---------------------------------------------------------------------------

final class SyncStatusRepositoryImpl implements SyncStatusRepository {
  const SyncStatusRepositoryImpl(this._remote);

  final CatalogRemoteDataSource _remote;

  @override
  Future<Result<SyncStatusInfo>> status() => ErrorMapper.guard(() async => (await _remote.syncStatus()).toEntity());

  @override
  Future<Result<CatalogPage<SyncRun>>> runs({
    String? entity,
    String? status,
    DateTime? from,
    DateTime? to,
    int limit = 50,
    String? cursor,
  }) => ErrorMapper.guard(() async {
    final page = await _remote.syncRuns(
      entity: entity,
      status: status,
      from: from,
      to: to,
      limit: limit,
      cursor: cursor,
    );
    return CatalogPage<SyncRun>(
      items: [for (final r in page.items) r.toEntity()],
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
      totalEstimate: page.totalEstimate,
      isEstimate: page.isEstimate ?? false,
      asOf: page.asOf,
    );
  });

  @override
  Future<Result<SyncRun>> run(String runId) => ErrorMapper.guard(() async => (await _remote.syncRun(runId)).toEntity());

  @override
  Future<Result<CatalogPage<SyncRunError>>> runErrors(String runId, {int limit = 50, String? cursor}) =>
      ErrorMapper.guard(() async {
        final page = await _remote.syncRunErrors(runId, limit: limit, cursor: cursor);
        return CatalogPage<SyncRunError>(
          items: [for (final e in page.items) e.toEntity()],
          nextCursor: page.nextCursor,
          hasMore: page.hasMore,
          totalEstimate: page.totalEstimate,
          isEstimate: page.isEstimate ?? false,
          asOf: page.asOf,
        );
      });

  @override
  Future<Result<SyncRun>> startRun({
    required String entity,
    required SyncRunRequestMode mode,
    required String idempotencyKey,
    String? stepUpToken,
    List<String>? variantIds,
    String? customerId,
  }) => ErrorMapper.guard(() async {
    final r = await _remote.startSyncRun(
      SyncRunsCreateRequestDto(entity: entity, mode: mode.value, variantIds: variantIds, customerId: customerId),
      idempotencyKey: idempotencyKey,
      stepUpToken: stepUpToken,
    );
    return r.toEntity();
  });
}

// ---------------------------------------------------------------------------

/// Разбор `ProductSummary`/`CatalogRecentProduct` для фичи favorites (порт `CatalogJsonDecoder`).
final class CatalogJsonDecoderImpl implements CatalogJsonDecoder {
  const CatalogJsonDecoderImpl();

  @override
  ProductSummary productSummary(Object? json) => ProductSummaryDto.fromJson(asJson(json)).toEntity();

  @override
  RecentProduct recentProduct(Object? json) {
    final dto = RecentProductDto.fromJson(asJson(json));
    return RecentProduct(product: dto.product.toEntity(), viewedAt: dto.viewedAt);
  }
}

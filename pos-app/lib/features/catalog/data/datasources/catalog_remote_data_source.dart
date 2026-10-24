// HTTP-вызовы каталога, поиска, остатков и синхронизации поверх единственного Dio-клиента
// (core/network/dio_client.dart: Bearer, X-App-Version/X-Platform/X-Device-Id, X-Request-Id,
// ETag для `/catalog/*`, автоповтор GET). Тела ответов не логируются (LoggingInterceptor).
// Пути и параметры — contracts/openapi/pos-api.v1.yaml; списки в query — через запятую (08 §1.3),
// характеристики — `attr[<ключ>]=<значение>`.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/features/catalog/data/dto/catalog_dtos.dart';
import 'package:optomstroy/features/catalog/data/dto/json_read.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';

/// Ответ с меткой данных `X-Data-As-Of` (08 §2.3).
final class WithDataAsOf<T> {
  const WithDataAsOf(this.value, this.dataAsOf);

  final T value;
  final DateTime? dataAsOf;
}

final class CatalogRemoteDataSource {
  const CatalogRemoteDataSource(this._dio);

  final Dio _dio;

  static String _id(String id) => Uri.encodeComponent(id);

  /// Выгрузка для кэша: фоновый профиль повтора; тело страницы не кладётся в память ETag-кэша.
  static Options get _background => Options(
    extra: {
      RequestExtra.retryProfile: RetryProfile.background,
      RequestExtra.etagBypass: true, // check-secrets: allow — ключ Options.extra
    },
  );

  static DateTime? _asOf(Response<Object?> r) {
    final v = r.headers.value(ApiHeaders.dataAsOf);
    return v == null ? null : DateTime.tryParse(v);
  }

  /// Параметры фильтров `GET /catalog/products` = `GET /search/products` (ядро §19.2).
  static Map<String, Object?> filterParams(CatalogFilter f) => {
    'categoryId': ?f.categoryId,
    if (f.categoryId != null && !f.includeSubcategories) 'includeSubcategories': false,
    'warehouseId': ?f.warehouseId,
    'priceListId': ?f.priceListId,
    'inStock': ?f.inStock,
    if (f.priceMin != null) 'priceMin': f.priceMin!.toApiString(),
    if (f.priceMax != null) 'priceMax': f.priceMax!.toApiString(),
    if (f.brands.isNotEmpty) 'brand': f.brands.join(','),
    for (final e in f.attrs.entries.take(CatalogFilter.maxAttrs)) 'attr[${e.key}]': e.value,
    'favorite': ?f.favorite,
    'hasImage': ?f.hasImage,
  };

  // --- /catalog ---------------------------------------------------------------

  Future<WithDataAsOf<CategoriesResponseDto>> categories({
    String? parentId,
    int? depth,
    bool includeEmpty = false,
    bool inStockOnly = false,
  }) async {
    final r = await _dio.get<Object?>(
      '/catalog/categories',
      queryParameters: {
        'parentId': ?parentId,
        'depth': ?depth,
        if (includeEmpty) 'includeEmpty': true,
        if (inStockOnly) 'inStockOnly': true,
      },
    );
    return WithDataAsOf(CategoriesResponseDto.fromJson(asJson(r.data)), _asOf(r));
  }

  Future<WithDataAsOf<PageDto<ProductSummaryDto>>> products(CatalogQuery q) async {
    final r = await _dio.get<Object?>(
      '/catalog/products',
      queryParameters: {
        ...filterParams(q.filter),
        if (q.sort != null && q.sort!.forCatalog) 'sort': q.sort!.value,
        'limit': q.limit.clamp(1, CatalogQuery.maxLimit),
        'cursor': ?q.cursor,
      },
    );
    return WithDataAsOf(PageDto.fromJson(asJson(r.data), ProductSummaryDto.fromJson), _asOf(r));
  }

  Future<WithDataAsOf<ProductDto>> product(
    String id, {
    String? warehouseId,
    String? priceListId,
    List<String>? include,
  }) async {
    final r = await _dio.get<Object?>(
      '/catalog/products/${_id(id)}',
      queryParameters: {
        'warehouseId': ?warehouseId,
        'priceListId': ?priceListId,
        if (include != null && include.isNotEmpty) 'include': include.join(','),
      },
    );
    return WithDataAsOf(ProductDto.fromJson(asJson(r.data)), _asOf(r));
  }

  Future<VariantsResponseDto> variants(
    String productId, {
    String? warehouseId,
    String? priceListId,
    bool? inStockOnly,
  }) async {
    final r = await _dio.get<Object?>(
      '/catalog/products/${_id(productId)}/variants',
      queryParameters: {'warehouseId': ?warehouseId, 'priceListId': ?priceListId, 'inStockOnly': ?inStockOnly},
    );
    return VariantsResponseDto.fromJson(asJson(r.data));
  }

  Future<List<UnitDto>> units() async {
    final r = await _dio.get<Object?>('/catalog/units');
    return objectList(asJson(r.data), 'items', UnitDto.fromJson, required: true);
  }

  Future<List<PriceListDto>> priceLists() async {
    final r = await _dio.get<Object?>('/catalog/price-lists');
    return objectList(asJson(r.data), 'items', PriceListDto.fromJson, required: true);
  }

  Future<List<WarehouseDto>> warehouses() async {
    final r = await _dio.get<Object?>('/catalog/warehouses');
    return objectList(asJson(r.data), 'items', WarehouseDto.fromJson, required: true);
  }

  /// `GET /catalog/sync/{entity}?since=&limit=&warehouseId=` (08 §4.24).
  Future<CatalogSyncResponseDto> syncPage(String entity, {String? since, int limit = 200, String? warehouseId}) async {
    final r = await _dio.get<Object?>(
      '/catalog/sync/${_id(entity)}',
      queryParameters: {
        'since': ?since,
        'limit': limit.clamp(1, CatalogQuery.maxLimit),
        if (entity == 'stock') 'warehouseId': ?warehouseId,
      },
      options: _background,
    );
    return CatalogSyncResponseDto.fromJson(asJson(r.data));
  }

  // --- /search ----------------------------------------------------------------

  Future<WithDataAsOf<PageDto<ProductSummaryDto>>> searchProducts({
    required String q,
    required CatalogFilter filter,
    required CatalogSort sort,
    required int limit,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final r = await _dio.get<Object?>(
      '/search/products',
      queryParameters: {
        'q': q,
        ...filterParams(filter),
        if (sort.forSearch) 'sort': sort.value,
        'limit': limit.clamp(1, CatalogQuery.maxLimit),
        'cursor': ?cursor,
      },
      cancelToken: cancelToken,
    );
    return WithDataAsOf(PageDto.fromJson(asJson(r.data), ProductSummaryDto.fromJson), _asOf(r));
  }

  Future<List<SuggestionDto>> suggest(String q, {int? limit}) async {
    final r = await _dio.get<Object?>(
      '/search/suggest',
      queryParameters: {'q': q, if (limit != null) 'limit': limit.clamp(1, 10)},
    );
    return objectList(asJson(r.data), 'items', SuggestionDto.fromJson, required: true);
  }

  Future<WithDataAsOf<BarcodeResultDto>> barcode(String value, {String? warehouseId}) async {
    final r = await _dio.get<Object?>('/search/barcode/${_id(value)}', queryParameters: {'warehouseId': ?warehouseId});
    return WithDataAsOf(BarcodeResultDto.fromJson(asJson(r.data)), _asOf(r));
  }

  // --- /inventory -------------------------------------------------------------

  Future<InventoryBalancesDto> balances(List<String> variantIds, {String? warehouseId, bool live = false}) async {
    final r = await _dio.get<Object?>(
      '/inventory/balances',
      queryParameters: {'variantIds': variantIds.join(','), 'warehouseId': ?warehouseId, if (live) 'live': true},
    );
    return InventoryBalancesDto.fromJson(asJson(r.data));
  }

  Future<InventoryCheckResponseDto> check(InventoryCheckRequestDto body, {String? idempotencyKey}) async {
    final r = await _dio.post<Object?>(
      '/inventory/check',
      data: body.toJson(),
      options: apiOptions(idempotencyKey: idempotencyKey),
    );
    return InventoryCheckResponseDto.fromJson(asJson(r.data));
  }

  // --- /sync ------------------------------------------------------------------

  Future<SyncStatusDto> syncStatus() async {
    final r = await _dio.get<Object?>('/sync/status');
    return SyncStatusDto.fromJson(asJson(r.data));
  }

  Future<PageDto<SyncRunDto>> syncRuns({
    String? entity,
    String? status,
    DateTime? from,
    DateTime? to,
    int limit = 50,
    String? cursor,
  }) async {
    final r = await _dio.get<Object?>(
      '/sync/runs',
      queryParameters: {
        'entity': ?entity,
        'status': ?status,
        if (from != null) 'from': from.toUtc().toIso8601String(),
        if (to != null) 'to': to.toUtc().toIso8601String(),
        'limit': limit.clamp(1, CatalogQuery.maxLimit),
        'cursor': ?cursor,
      },
    );
    return PageDto.fromJson(asJson(r.data), SyncRunDto.fromJson);
  }

  Future<SyncRunDto> syncRun(String id) async {
    final r = await _dio.get<Object?>('/sync/runs/${_id(id)}');
    return SyncRunDto.fromJson(asJson(r.data));
  }

  Future<PageDto<SyncRunErrorDto>> syncRunErrors(String id, {int limit = 50, String? cursor}) async {
    final r = await _dio.get<Object?>(
      '/sync/runs/${_id(id)}/errors',
      queryParameters: {'limit': limit.clamp(1, CatalogQuery.maxLimit), 'cursor': ?cursor},
    );
    return PageDto.fromJson(asJson(r.data), SyncRunErrorDto.fromJson);
  }

  /// `POST /sync/runs` → 202; `Idempotency-Key` обязателен, `X-Step-Up-Token` — для `full`/`reconcile`.
  Future<SyncRunDto> startSyncRun(
    SyncRunsCreateRequestDto body, {
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    final options = apiOptions(idempotencyKey: idempotencyKey);
    if (stepUpToken != null) options.headers![ApiHeaders.stepUpToken] = stepUpToken;
    final r = await _dio.post<Object?>('/sync/runs', data: body.toJson(), options: options);
    return SyncRunDto.fromJson(asJson(r.data));
  }
}

// Порты данных каталога (06 §6.1 L-2; 08 §4.4–§4.6, §4.17, §4.24; 07 §11.2–§11.4). Чистый Dart (FL-01).
//
// Реализации — features/catalog/data/** (Dio + drift), связываются в `data/catalog_bindings.dart`
// и подключаются корнем `app/di/overrides.dart` (L-8). Провайдеры — `catalog_providers.dart`.
// Все методы возвращают `Result`: ошибки сети/сервера — `Failure` (06 §6.8), исключения наружу не выходят.
// Методы `cached*` читают локальный кэш drift (07 §11.2); без открытой БД пользователя
// (до входа) — `UnknownFailure` с причиной `CatalogCacheUnavailable`.
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/inventory.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/domain/entities/sync.dart';

/// Причина `UnknownFailure`, когда локальная БД пользователя не открыта.
final class CatalogCacheUnavailable {
  const CatalogCacheUnavailable();

  @override
  String toString() => 'CatalogCacheUnavailable';
}

/// Варианты товара (`CatalogVariantsResponse`).
final class VariantList {
  const VariantList({required this.items, this.attributeKeys = const <AttributeKey>[], this.asOf});

  final List<Variant> items;

  /// Оси выбора варианта (SCR-15): ключ, имя, значения.
  final List<AttributeKey> attributeKeys;
  final DateTime? asOf;
}

/// Ось характеристик варианта (`CatalogAttributeKey`).
final class AttributeKey {
  const AttributeKey({required this.key, required this.name, required this.values});

  final String key;
  final String name;
  final List<String> values;
}

/// Каталог: категории, товары, карточка, справочники (сеть + локальный кэш).
abstract interface class CatalogRepository {
  /// `GET /catalog/categories` — дерево со счётчиками (ETag).
  Future<Result<CategoryTree>> categories({
    String? parentId,
    int? depth,
    bool includeEmpty = false,
    bool inStockOnly = false,
  });

  /// `GET /catalog/products` — страница товаров (курсор, фильтры, сортировка, фасеты).
  Future<Result<CatalogPage<ProductSummary>>> products(CatalogQuery query);

  /// `GET /catalog/products/{id}?include=` — карточка (ETag); сервер пишет `recent_products`.
  Future<Result<Product>> product(
    String productId, {
    String? warehouseId,
    String? priceListId,
    Set<ProductInclude> include = ProductInclude.all,
  });

  /// `GET /catalog/products/{id}/variants`.
  Future<Result<VariantList>> variants(String productId, {String? warehouseId, String? priceListId, bool? inStockOnly});

  /// `GET /catalog/units`.
  Future<Result<List<Unit>>> units();

  /// `GET /catalog/price-lists` (только виды цен роли).
  Future<Result<List<PriceList>>> priceLists();

  /// `GET /catalog/warehouses`.
  Future<Result<List<Warehouse>>> warehouses();

  /// Дерево категорий из кэша (счётчики — значения последней синхронизации).
  Future<Result<CategoryTree>> cachedCategories();

  /// Страница товаров из кэша (`cursor` — смещение); фасеты не считаются.
  Future<Result<CatalogPage<ProductSummary>>> cachedProducts(CatalogQuery query);

  /// Карточка из кэша (`null` — товара в кэше нет); `asOf` — `sync_meta.as_of` товаров.
  Future<Result<Product?>> cachedProduct(String productId, {String? warehouseId, String? priceListId});
}

/// Поиск товаров (D-31): сервер и локальный кэш.
abstract interface class SearchRepository {
  /// `GET /search/products` (те же фильтры, что каталог; `matchType` у каждого товара).
  Future<Result<SearchResult>> searchProducts(SearchQuery query);

  /// `GET /search/suggest?q=` (≥ 2 символов).
  Future<Result<List<SearchSuggestion>>> suggest(String q, {int? limit});

  /// `GET /search/barcode/{value}` — товар, вариант и упаковка по штрихкоду.
  Future<Result<BarcodeLookup>> barcode(String value, {String? warehouseId});

  /// Поиск по локальному кэшу: штрихкод → артикул → `name_norm` (офлайн SCR-11, DATA-261).
  Future<Result<SearchResult>> searchCached(SearchQuery query);

  /// Штрихкод по локальной таблице `barcodes` (офлайн-сканер, DATA-259); `null` — не найден.
  Future<Result<BarcodeLookup?>> barcodeCached(String value, {String? warehouseId, String? priceListId});
}

/// Остатки (`inventory.read`); клиент `available` не вычисляет (D-22).
abstract interface class InventoryRepository {
  /// `GET /inventory/balances?variantIds=&warehouseId=&live=` (≤ 200 вариантов).
  Future<Result<InventoryBalances>> balances(List<String> variantIds, {String? warehouseId, bool live = false});

  /// `POST /inventory/check` — наличие строк на складе (≤ 200).
  Future<Result<InventoryCheckResult>> check(
    String warehouseId,
    List<InventoryCheckLine> lines, {
    String? idempotencyKey,
  });

  /// Остатки из кэша (`stock_balances`).
  Future<Result<InventoryBalances>> cachedBalances(List<String> variantIds, {String? warehouseId});
}

/// Загрузка локального кэша каталога через `GET /catalog/sync/{entity}` (08 §4.24; 07 §11.4; RM-E-009).
///
/// Страница применяется к drift атомарно вместе с курсором (`sync_meta.server_cursor`):
/// прерванная загрузка продолжается с курсора без дублей (DATA-257).
abstract interface class CatalogSyncRepository {
  /// Одна страница сущности от сохранённого курсора (без курсора — с начала).
  Future<Result<CatalogSyncProgress>> pullPage(CatalogSyncEntity entity, {int limit = 200, String? warehouseId});

  /// Сущность до `hasMore=false`. [restart] — загрузка без `since` (первичная / повторная полная):
  /// по её завершении строки, не пришедшие в выгрузке, удаляются (07 §11.2 «полная замена при full»).
  /// `409 VERSION_CONFLICT` `cursor_expired` → автоматически полная загрузка сущности.
  Future<Result<CatalogSyncProgress>> syncEntity(
    CatalogSyncEntity entity, {
    bool restart = false,
    int limit = 200,
    String? warehouseId,
    void Function(CatalogSyncProgress progress)? onPage,
  });

  /// Метки синхронизации всех сущностей кэша.
  Future<Result<List<LocalSyncState>>> localStates();

  /// Сохранить пороги устаревания из `GET /sync/status` (`2 × intervalSec`) в `sync_meta.stale_after_sec`.
  Future<Result<void>> saveStaleThresholds(SyncStatusInfo status);

  /// `app_meta.catalog_full_loaded_at` — первичная загрузка завершена (`null` — ещё нет).
  Future<Result<DateTime?>> fullLoadedAt();

  /// Отметить завершение первичной загрузки.
  Future<Result<void>> markFullLoaded(DateTime at);

  /// Число товаров в кэше (индикатор первичной загрузки).
  Future<Result<int>> cachedProductCount();
}

/// Статус обмена с 1С и прогоны (08 §4.17; SCR-43, `SyncIndicator`).
abstract interface class SyncStatusRepository {
  /// `GET /sync/status` (`sync.status.read`; полный ответ — `sync.runs.read`).
  Future<Result<SyncStatusInfo>> status();

  /// `GET /sync/runs` (`sync.runs.read`).
  Future<Result<CatalogPage<SyncRun>>> runs({
    String? entity,
    String? status,
    DateTime? from,
    DateTime? to,
    int limit = 50,
    String? cursor,
  });

  /// `GET /sync/runs/{id}`.
  Future<Result<SyncRun>> run(String runId);

  /// `GET /sync/runs/{id}/errors`.
  Future<Result<CatalogPage<SyncRunError>>> runErrors(String runId, {int limit = 50, String? cursor});

  /// `POST /sync/runs` → `202 SyncRun` (права и step-up — правило R0 §17.2; C-2 → `422 inbound_mode`).
  Future<Result<SyncRun>> startRun({
    required String entity,
    required SyncRunRequestMode mode,
    required String idempotencyKey,
    String? stepUpToken,
    List<String>? variantIds,
    String? customerId,
  });
}

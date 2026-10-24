// Фейки и обвязка widget-тестов экранов каталога (RM-E-007). Данные синтетические (не реальная
// интеграция): товары «Смеситель …», категории макета, остатки и цены в целых тыйынах/milli-units.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';

final DateTime kNow = DateTime.utc(2026, 10, 22, 3, 41); // 09:41 в Бишкеке

const Unit kPiece = Unit(id: 'u-pcs', name: 'штука', shortName: 'шт', qtyPrecision: 0);

ProductSummary product(
  int i, {
  String? sku,
  bool noSku = false,
  int priceSom = 2350,
  bool noPrice = false,
  StockLevel level = StockLevel.inStock,
  int available = 24,
  bool hideQty = false,
  bool noStock = false,
  bool hasVariants = false,
  int? variantCount,
  MatchType? matchType,
  String? name,
  DateTime? asOf,
  bool favorite = false,
}) => ProductSummary(
  id: 'p$i',
  name: name ?? 'Смеситель для кухни Frap F42${i.toString().padLeft(2, '0')}',
  sku: noSku ? null : (sku ?? 'F42${i.toString().padLeft(2, '0')}-CR'),
  categoryId: 'c-mix',
  brand: i.isEven ? 'Frap' : 'Grohe',
  hasVariants: hasVariants,
  variantCount: variantCount,
  defaultVariantId: 'v$i',
  baseUnit: kPiece,
  price: noPrice ? null : Price(priceListId: 'pl-retail', priceListName: 'Розничная', amount: Money.som(priceSom)),
  priceRange: hasVariants ? MoneyRange(min: Money.som(priceSom), max: Money.som(priceSom + 500)) : null,
  stock: noStock
      ? null
      : StockBalance(
          variantId: 'v$i',
          warehouseId: 'w-main',
          stockLevel: level,
          available: hideQty ? null : Qty.units(level == StockLevel.out ? 0 : available),
          asOf: asOf ?? kNow.subtract(const Duration(minutes: 5)),
        ),
  matchType: matchType,
  isFavorite: favorite,
);

List<ProductSummary> products(int count, {int from = 0}) => <ProductSummary>[
  for (int i = from; i < from + count; i++) product(i),
];

CatalogPage<ProductSummary> page(
  List<ProductSummary> items, {
  String? next,
  int? total,
  DataSource source = DataSource.network,
  CatalogFacets? facets,
}) => CatalogPage<ProductSummary>(
  items: items,
  hasMore: next != null,
  nextCursor: next,
  totalEstimate: total ?? items.length,
  asOf: kNow.subtract(const Duration(minutes: 2)),
  source: source,
  facets: facets,
);

/// Дерево категорий по макету: «Смесители» с двумя подкатегориями, «Санфаянс» — без детей.
CategoryTree categoryTree() => CategoryTree.fromFlat(const <Category>[
  Category(id: 'c-mix', name: 'Смесители', productCount: 124, iconKey: 'plumbing', hasChildren: true),
  Category(id: 'c-mix-kitchen', parentId: 'c-mix', name: 'Для кухни', productCount: 48),
  Category(id: 'c-mix-bath', parentId: 'c-mix', name: 'Для ванной', productCount: 76),
  Category(id: 'c-sanitary', name: 'Санфаянс', productCount: 56, iconKey: 'bathtub', sortOrder: 1),
  Category(id: 'c-pipes', name: 'Трубы и фитинги', productCount: 0, iconKey: 'valve', sortOrder: 2),
]);

/// Ответ, который можно задержать: `hold()` → запрос ждёт `release()`.
final class Gate {
  Completer<void>? _c;

  void hold() => _c = Completer<void>();

  void release() {
    _c?.complete();
    _c = null;
  }

  Future<void> wait() async {
    final Completer<void>? c = _c;
    if (c != null) {
      await c.future;
    }
  }
}

class FakeCatalogRepository implements CatalogRepository {
  FakeCatalogRepository({List<ProductSummary>? items, CategoryTree? tree}) : tree = tree ?? categoryTree() {
    if (items != null) {
      networkPages.add(Success<CatalogPage<ProductSummary>>(page(items)));
    }
  }

  CategoryTree tree;
  CategoryTree? cachedTree;

  /// Очередь ответов сети; последний повторяется.
  final List<Result<CatalogPage<ProductSummary>>> networkPages = <Result<CatalogPage<ProductSummary>>>[];

  /// Ответ кэша (по умолчанию пусто).
  Result<CatalogPage<ProductSummary>> cached = Success<CatalogPage<ProductSummary>>(
    page(const <ProductSummary>[], source: DataSource.cache),
  );

  /// Ответы по курсору (подгрузка).
  final Map<String, Result<CatalogPage<ProductSummary>>> byCursor = <String, Result<CatalogPage<ProductSummary>>>{};
  final List<CatalogQuery> productCalls = <CatalogQuery>[];
  final List<CatalogQuery> cachedCalls = <CatalogQuery>[];
  int categoryCalls = 0;
  final Gate gate = Gate();
  Result<CategoryTree>? categoriesResult;
  List<Warehouse> warehouseList = const <Warehouse>[
    Warehouse(id: 'w-main', name: 'Основной', isDefaultForPos: true),
    Warehouse(id: 'w-2', name: 'Склад №2'),
  ];

  @override
  Future<Result<CategoryTree>> categories({
    String? parentId,
    int? depth,
    bool includeEmpty = false,
    bool inStockOnly = false,
  }) async {
    categoryCalls++;
    return categoriesResult ?? Success<CategoryTree>(tree);
  }

  @override
  Future<Result<CategoryTree>> cachedCategories() async =>
      Success<CategoryTree>(cachedTree ?? const CategoryTree(roots: <Category>[]));

  @override
  Future<Result<CatalogPage<ProductSummary>>> products(CatalogQuery query) async {
    productCalls.add(query);
    await gate.wait();
    final String? cursor = query.cursor;
    if (cursor != null && byCursor.containsKey(cursor)) {
      return byCursor[cursor]!;
    }
    if (networkPages.isEmpty) {
      return Success<CatalogPage<ProductSummary>>(page(const <ProductSummary>[]));
    }
    return networkPages.length > 1 ? networkPages.removeAt(0) : networkPages.first;
  }

  @override
  Future<Result<CatalogPage<ProductSummary>>> cachedProducts(CatalogQuery query) async {
    cachedCalls.add(query);
    return cached;
  }

  @override
  Future<Result<List<Warehouse>>> warehouses() async => Success<List<Warehouse>>(warehouseList);

  @override
  Future<Result<List<Unit>>> units() async => const Success<List<Unit>>(<Unit>[kPiece]);

  @override
  Future<Result<List<PriceList>>> priceLists() async => const Success<List<PriceList>>(<PriceList>[]);

  @override
  Future<Result<Product>> product(
    String productId, {
    String? warehouseId,
    String? priceListId,
    Set<ProductInclude> include = ProductInclude.all,
  }) async => const FailureResult<Product>(UnknownFailure());

  @override
  Future<Result<VariantList>> variants(
    String productId, {
    String? warehouseId,
    String? priceListId,
    bool? inStockOnly,
  }) async => const FailureResult<VariantList>(UnknownFailure());

  @override
  Future<Result<Product?>> cachedProduct(String productId, {String? warehouseId, String? priceListId}) async =>
      const Success<Product?>(null);
}

class FakeSearchRepository implements SearchRepository {
  final List<String> queries = <String>[];
  final List<SearchQuery> calls = <SearchQuery>[];

  /// Задержка ответа по строке запроса.
  final Map<String, Completer<void>> holds = <String, Completer<void>>{};

  /// Результат по строке запроса; по умолчанию — 2 товара с типами совпадения.
  SearchResult Function(String q) results = (String q) => SearchResult(
    query: q,
    page: page(<ProductSummary>[
      product(1, matchType: MatchType.sku, name: 'Смеситель $q артикул'),
      product(2, matchType: MatchType.fts, name: 'Смеситель $q название'),
    ]),
    matchTypes: const SearchMatchCounts(sku: 1, fts: 1),
  );

  @override
  Future<Result<SearchResult>> searchProducts(SearchQuery query) async {
    queries.add(query.q);
    calls.add(query);
    final Completer<void>? hold = holds[query.q];
    if (hold != null) {
      await hold.future;
    }
    return Success<SearchResult>(results(query.q));
  }

  @override
  Future<Result<SearchResult>> searchCached(SearchQuery query) async => Success<SearchResult>(
    SearchResult(
      query: query.q,
      page: page(const <ProductSummary>[], source: DataSource.cache),
    ),
  );

  @override
  Future<Result<List<SearchSuggestion>>> suggest(String q, {int? limit}) async =>
      const Success<List<SearchSuggestion>>(<SearchSuggestion>[]);

  @override
  Future<Result<BarcodeLookup>> barcode(String value, {String? warehouseId}) async =>
      const FailureResult<BarcodeLookup>(UnknownFailure());

  @override
  Future<Result<BarcodeLookup?>> barcodeCached(String value, {String? warehouseId, String? priceListId}) async =>
      const Success<BarcodeLookup?>(null);
}

final class FakeShelfPort implements CatalogShelfPort {
  FakeShelfPort({Set<String>? favorites, List<RecentProduct>? recent})
    : _favorites = favorites ?? <String>{},
      recent = recent ?? <RecentProduct>[];

  final Set<String> _favorites;
  List<RecentProduct> recent;
  final StreamController<Set<String>> _ids = StreamController<Set<String>>.broadcast();
  Result<void> favoriteResult = const Success<void>(null);
  Result<void> clearResult = const Success<void>(null);
  final List<(String, bool)> favoriteCalls = <(String, bool)>[];
  int clearCalls = 0;

  @override
  Stream<Set<String>> watchFavoriteIds() async* {
    yield Set<String>.of(_favorites);
    yield* _ids.stream;
  }

  @override
  Future<Result<void>> setFavorite(String productId, {required bool favorite}) async {
    favoriteCalls.add((productId, favorite));
    if (favoriteResult is Success<void>) {
      favorite ? _favorites.add(productId) : _favorites.remove(productId);
      _ids.add(Set<String>.of(_favorites));
    }
    return favoriteResult;
  }

  @override
  Future<Result<List<RecentProduct>>> recentProducts({int limit = 5}) async =>
      Success<List<RecentProduct>>(recent.take(limit).toList());

  @override
  Future<Result<void>> clearRecent() async {
    clearCalls++;
    if (clearResult is Success<void>) {
      recent = <RecentProduct>[];
    }
    return clearResult;
  }

  Future<void> dispose() => _ids.close();
}

/// Картинки в тестах не грузятся из сети: прозрачный пиксель.
ImageProvider<Object> transparentImage(String url) => MemoryImage(kTransparentPng);

final Uint8List kTransparentPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

/// Обвязка: фейки + провайдеры по умолчанию.
final class CatalogHarness {
  CatalogHarness({
    FakeCatalogRepository? catalog,
    FakeSearchRepository? search,
    this.shelf,
    this.role = RoleCode.seller,
    CatalogPrefs? prefs,
    this.online = OnlineStatus.online,
    this.name = 'Абдулла',
    this.unread = 3,
    this.extra = const <Override>[],
  }) : catalog = catalog ?? FakeCatalogRepository(items: products(6)),
       search = search ?? FakeSearchRepository(),
       prefs = prefs ?? InMemoryCatalogPrefs();

  final FakeCatalogRepository catalog;
  final FakeSearchRepository search;
  final FakeShelfPort? shelf;
  final RoleCode? role;
  final CatalogPrefs prefs;
  final OnlineStatus online;
  final String? name;
  final int unread;

  /// Дополнительные переопределения (например, `SyncIndicator` шапки в golden SCR-10).
  final List<Override> extra;

  List<Override> get overrides => <Override>[
    catalogRepositoryProvider.overrideWithValue(catalog),
    searchRepositoryProvider.overrideWithValue(search),
    catalogViewerRoleProvider.overrideWithValue(role),
    catalogShelfPortProvider.overrideWithValue(shelf),
    catalogPrefsProvider.overrideWithValue(prefs),
    catalogOnlineStatusProvider.overrideWithValue(online),
    catalogViewerNameProvider.overrideWithValue(name),
    catalogUnreadNotificationsProvider.overrideWithValue(unread),
    clockProvider.overrideWithValue(FixedClock(kNow)),
    ...extra,
  ];
}

/// Приложение для экрана: без маршрутизатора (навигация — no-op) или с [router].
Widget catalogApp(CatalogHarness h, {Widget? home, GoRouter? router, Size? size}) {
  Widget wrap(BuildContext context, Widget? child) {
    final MediaQueryData mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(disableAnimations: true, size: size ?? mq.size, padding: EdgeInsets.zero),
      child: ProductImageScope(providerFor: transparentImage, child: child!),
    );
  }

  return ProviderScope(
    overrides: h.overrides,
    child: router != null
        ? MaterialApp.router(
            theme: AppTheme.light(),
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            debugShowCheckedModeBanner: false,
            routerConfig: router,
            builder: wrap,
          )
        : MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            debugShowCheckedModeBanner: false,
            builder: wrap,
            home: home,
          ),
  );
}

/// Размер окна теста (dpr 1).
void setWindow(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

const Size kCompact = Size(390, 844);
const Size kMedium = Size(820, 1000);
const Size kExpanded = Size(1366, 900);

/// Дать отработать микрозадачам загрузки (кэш → сеть) без бесконечного `pumpAndSettle` (шиммер).
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// `NetworkFailure` офлайн.
const NetworkFailure kOffline = NetworkFailure(NetworkFailureKind.offline);

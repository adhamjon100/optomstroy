// Запрос списка товаров: фильтры, сортировка, страница, фасеты (08 §4.4.2, §4.5.1; SCR-10…SCR-13).
// `GET /search/products` принимает те же фильтры, что `GET /catalog/products` (ядро §19.2). Чистый Dart.
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';

/// Сортировка (`sort`): значения API ровно как в контракте.
enum CatalogSort {
  /// Только `/search/products` (по умолчанию для поиска).
  relevanceDesc('relevance:desc'),
  priceAsc('price:asc'),
  priceDesc('price:desc'),
  nameAsc('name:asc'),

  /// Только `/catalog/products`.
  nameDesc('name:desc'),

  /// Только `/catalog/products`.
  popularityDesc('popularity:desc'),

  /// Только `/catalog/products`.
  updatedAtDesc('updatedAt:desc'),

  /// По доступному остатку на складе запроса, без снимка — в конце (ядро §19.2).
  availableDesc('available:desc'),

  /// По артикулу (ядро §19.2).
  skuAsc('sku:asc');

  const CatalogSort(this.value);

  final String value;

  /// Допустима для `GET /catalog/products`.
  bool get forCatalog => this != relevanceDesc;

  /// Допустима для `GET /search/products`.
  bool get forSearch => switch (this) {
    nameDesc || popularityDesc || updatedAtDesc => false,
    _ => true,
  };

  static CatalogSort? tryParse(String? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

/// Фильтры списка (`FilterPanel`/`FilterSheet` SCR-13).
final class CatalogFilter {
  const CatalogFilter({
    this.categoryId,
    this.includeSubcategories = true,
    this.warehouseId,
    this.priceListId,
    this.inStock,
    this.priceMin,
    this.priceMax,
    this.brands = const <String>[],
    this.attrs = const <String, String>{},
    this.favorite,
    this.hasImage,
  });

  /// Максимум пар `attr[<ключ>]` (OpenAPI `maxProperties: 10`).
  static const int maxAttrs = 10;

  final String? categoryId;
  final bool includeSubcategories;

  /// Склад остатков; `null` — склад по умолчанию (сервер / кэш).
  final String? warehouseId;

  /// Вид цены — только staff с `catalog.prices.read.all` (`customer` — не передаётся, CUST-021).
  final String? priceListId;
  final bool? inStock;
  final Money? priceMin;
  final Money? priceMax;
  final List<String> brands;
  final Map<String, String> attrs;
  final bool? favorite;
  final bool? hasImage;

  /// Число активных фильтров (бейдж кнопки «Фильтры»), без категории, склада и вида цены.
  int get activeCount =>
      (inStock == true ? 1 : 0) +
      (priceMin != null || priceMax != null ? 1 : 0) +
      (brands.isNotEmpty ? 1 : 0) +
      attrs.length +
      (favorite == true ? 1 : 0) +
      (hasImage == true ? 1 : 0);

  CatalogFilter copyWith({
    String? categoryId,
    bool? includeSubcategories,
    String? warehouseId,
    String? priceListId,
    bool? inStock,
    Money? priceMin,
    Money? priceMax,
    List<String>? brands,
    Map<String, String>? attrs,
    bool? favorite,
    bool? hasImage,
  }) => CatalogFilter(
    categoryId: categoryId ?? this.categoryId,
    includeSubcategories: includeSubcategories ?? this.includeSubcategories,
    warehouseId: warehouseId ?? this.warehouseId,
    priceListId: priceListId ?? this.priceListId,
    inStock: inStock ?? this.inStock,
    priceMin: priceMin ?? this.priceMin,
    priceMax: priceMax ?? this.priceMax,
    brands: brands ?? this.brands,
    attrs: attrs ?? this.attrs,
    favorite: favorite ?? this.favorite,
    hasImage: hasImage ?? this.hasImage,
  );
}

/// Запрос страницы `GET /catalog/products` (и локального кэша).
final class CatalogQuery {
  const CatalogQuery({this.filter = const CatalogFilter(), this.sort, this.limit = defaultLimit, this.cursor});

  /// Размер страницы по умолчанию (08 §4.4.2).
  static const int defaultLimit = 40;

  /// Максимум страницы (08 §2.5, ядро §19.2).
  static const int maxLimit = 200;

  final CatalogFilter filter;

  /// `null` — сортировка сервера по умолчанию.
  final CatalogSort? sort;
  final int limit;

  /// Курсор следующей страницы (`nextCursor` предыдущего ответа; для кэша — смещение).
  final String? cursor;

  CatalogQuery next(String? cursor) => CatalogQuery(filter: filter, sort: sort, limit: limit, cursor: cursor);
}

/// Значение фасета (`CatalogFacetValue`).
final class FacetValue {
  const FacetValue({required this.value, required this.count});

  final String value;
  final int count;
}

/// Фасеты списка (`CatalogProductFacets`): бренды, характеристики, диапазон цен.
final class CatalogFacets {
  const CatalogFacets({
    this.brands = const <FacetValue>[],
    this.attrs = const <String, List<FacetValue>>{},
    this.priceRange,
  });

  final List<FacetValue> brands;
  final Map<String, List<FacetValue>> attrs;
  final MoneyRange? priceRange;
}

/// Страница результата (`Page` 08 §2.5) с источником данных: сеть или локальный кэш.
final class CatalogPage<T> {
  const CatalogPage({
    required this.items,
    required this.hasMore,
    this.nextCursor,
    this.totalEstimate,
    this.isEstimate = false,
    this.asOf,
    this.facets,
    this.source = DataSource.network,
  });

  final List<T> items;
  final String? nextCursor;
  final bool hasMore;

  /// «Найдено: N» (для кэша — точное число).
  final int? totalEstimate;
  final bool isEstimate;

  /// Момент данных (`asOf` / `X-Data-As-Of` / `sync_meta.as_of`).
  final DateTime? asOf;
  final CatalogFacets? facets;
  final DataSource source;
}

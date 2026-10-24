// Поиск товаров (08 §4.5; D-31; SCR-11, SCR-17): запрос, результат с `matchType`, подсказки,
// поиск по штрихкоду. Чистый Dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';

/// Запрос `GET /search/products` (те же фильтры, что каталог; ядро §19.2).
final class SearchQuery {
  const SearchQuery({
    required this.q,
    this.filter = const CatalogFilter(),
    this.sort = CatalogSort.relevanceDesc,
    this.limit = CatalogQuery.defaultLimit,
    this.cursor,
  });

  /// Минимальная длина запроса для API на экране SCR-11 (RM-E-007: не вызывать API при < 2 символов;
  /// для штрихкода/артикула из цифр сервер допускает 1 символ — 08 §4.5.1).
  static const int minLength = 2;

  final String q;
  final CatalogFilter filter;
  final CatalogSort sort;
  final int limit;
  final String? cursor;

  SearchQuery next(String? cursor) => SearchQuery(q: q, filter: filter, sort: sort, limit: limit, cursor: cursor);
}

/// Число совпадений по веткам поиска (`SearchMatchTypes`).
final class SearchMatchCounts {
  const SearchMatchCounts({this.barcode = 0, this.sku = 0, this.fts = 0, this.trgm = 0});

  final int barcode;
  final int sku;
  final int fts;
  final int trgm;

  int get total => barcode + sku + fts + trgm;
}

/// Результат поиска: страница товаров + сведения о запросе.
final class SearchResult {
  const SearchResult({
    required this.page,
    required this.query,
    this.matchTypes = const SearchMatchCounts(),
    this.suggestedQuery,
  });

  final CatalogPage<ProductSummary> page;

  /// Запрос, как его понял сервер.
  final String query;
  final SearchMatchCounts matchTypes;

  /// «Возможно, вы искали …» (`suggestedQuery`).
  final String? suggestedQuery;

  List<ProductSummary> get items => page.items;
  DataSource get source => page.source;
}

/// Вид подсказки (`SearchSuggestion.kind`).
enum SuggestionKind {
  product('product'),
  category('category'),
  sku('sku');

  const SuggestionKind(this.value);

  final String value;

  static SuggestionKind parse(String? value) {
    for (final k in values) {
      if (k.value == value) return k;
    }
    return product;
  }
}

/// Подсказка поиска (`SearchSuggestion`).
final class SearchSuggestion {
  const SearchSuggestion({required this.text, required this.kind, this.id, this.count});

  final String text;
  final SuggestionKind kind;
  final String? id;
  final int? count;
}

/// Предупреждение ответа (`Warning`: `STALE_DATA` …).
final class CatalogWarning {
  const CatalogWarning({required this.code, required this.message});

  final String code;
  final String message;
}

/// Результат `GET /search/barcode/{value}` (`SearchBarcodeResult`) или поиска по кэшу (DATA-259).
final class BarcodeLookup {
  const BarcodeLookup({
    required this.product,
    required this.variant,
    required this.barcodeType,
    this.packaging,
    this.suggestedQuantity,
    this.suggestedUnitId,
    this.warnings = const <CatalogWarning>[],
    this.source = DataSource.network,
    this.asOf,
  });

  final ProductSummary product;
  final Variant variant;
  final Packaging? packaging;
  final BarcodeType barcodeType;

  /// Предлагаемое количество (`suggestedQuantity.value`) и его единица.
  final Qty? suggestedQuantity;
  final String? suggestedUnitId;
  final List<CatalogWarning> warnings;

  /// `cache` — найден офлайн по локальной таблице `barcodes` («офлайн, остаток/цена на HH:MM»).
  final DataSource source;
  final DateTime? asOf;
}

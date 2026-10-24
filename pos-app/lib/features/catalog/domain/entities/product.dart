// Товар, вариант, цена, остаток (08 §3.6; OpenAPI `ProductSummary`, `Product`, `Variant`, `Price`,
// `StockBalance`, `CatalogRecentProduct`). Чистый Dart (FL-01).
//
// Деньги — `Money` (тыйыны), количества — `Qty` (milli-units), D-19. Клиент не вычисляет
// `available` и цену (D-22, D-23): значения сервера как есть. Неизвестный остаток —
// `stockLevel = unknown`: добавление в корзину запрещено (INV-052, RM-E-014).
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';

/// Цена варианта по виду цены (`Price`).
final class Price {
  const Price({
    required this.priceListId,
    required this.amount,
    this.priceListName,
    this.packagingId,
    this.currency = 'KGS',
    this.validFrom,
    this.asOf,
  });

  final String priceListId;
  final String? priceListName;

  /// Цена за упаковку `packagingId`; `null` — за базовую единицу.
  final String? packagingId;
  final Money amount;
  final String currency;
  final DateTime? validFrom;
  final DateTime? asOf;
}

/// Диапазон цен товара с вариантами (`MoneyRange`).
final class MoneyRange {
  const MoneyRange({required this.min, required this.max});

  final Money min;
  final Money max;
}

/// Уровень наличия (`StockLevel`).
enum StockLevel {
  inStock('in_stock'),
  low('low'),
  out('out'),
  unknown('unknown');

  const StockLevel(this.value);

  final String value;

  /// Неизвестное значение → [unknown].
  static StockLevel parse(String? value) {
    for (final l in values) {
      if (l.value == value) return l;
    }
    return unknown;
  }
}

/// Остаток варианта на складе (`StockBalance`).
///
/// Количества могут отсутствовать: у роли `customer` при `customer_stock_display = status`
/// сервер присылает только [stockLevel] (ядро v1.9 §24.2, 08 API-180); [available] может быть
/// отрицательным (пересорт в 1С).
final class StockBalance {
  const StockBalance({
    required this.variantId,
    required this.warehouseId,
    required this.stockLevel,
    this.warehouseName,
    this.quantity,
    this.reserved,
    this.available,
    this.unitId,
    this.asOf,
  });

  final String variantId;
  final String warehouseId;
  final String? warehouseName;
  final Qty? quantity;
  final Qty? reserved;

  /// Доступно = остаток − резерв (вычисляет сервер, D-22).
  final Qty? available;
  final String? unitId;

  /// Момент снимка остатка («обновлено HH:MM»).
  final DateTime? asOf;
  final StockLevel stockLevel;

  /// Остаток неизвестен (нет снимка или `stockLevel = unknown`) — «Добавить» недоступна (INV-052).
  bool get isUnknown => stockLevel == StockLevel.unknown;

  /// Количество скрыто сервером (режим `status` у клиента-покупателя).
  bool get quantityHidden => available == null && !isUnknown;

  /// Можно добавить в корзину по наличию: известен и не `out` (окончательная проверка — сервер).
  bool get allowsAddToCart => !isUnknown && stockLevel != StockLevel.out;
}

/// Вариант товара (`Variant`, `CatalogSyncVariant`).
final class Variant {
  const Variant({
    required this.id,
    required this.productId,
    this.isDefault = false,
    this.name,
    this.sku,
    this.attributes = const <String, String>{},
    this.price,
    this.stock,
    this.stockByWarehouse = const <StockBalance>[],
    this.barcodes = const <String>[],
    this.images = const <ProductImageRef>[],
    this.multiplicity,
    this.unitId,
    this.sortOrder = 0,
    this.deletionMark = false,
  });

  final String id;
  final String productId;
  final bool isDefault;
  final String? name;
  final String? sku;

  /// Характеристики варианта («Цвет: хром»).
  final Map<String, String> attributes;
  final Price? price;
  final StockBalance? stock;
  final List<StockBalance> stockByWarehouse;
  final List<String> barcodes;
  final List<ProductImageRef> images;

  /// Кратность количества в базовой единице (`Variant.multiplicity`, ядро §19.2; INV-004).
  final Qty? multiplicity;
  final String? unitId;
  final int sortOrder;
  final bool deletionMark;
}

/// Тип совпадения поиска (`ProductSummary.matchType`, D-31): штрихкод → артикул → FTS → триграммы.
enum MatchType {
  barcode('barcode'),
  sku('sku'),
  fts('fts'),
  trgm('trgm');

  const MatchType(this.value);

  final String value;

  static MatchType? tryParse(String? value) {
    for (final m in values) {
      if (m.value == value) return m;
    }
    return null;
  }
}

/// Товар в списках каталога (`ProductSummary`; единая модель карточки SCR-10/11/12/40, 02 ч. B §2.3).
final class ProductSummary {
  const ProductSummary({
    required this.id,
    required this.name,
    this.sku,
    this.categoryId,
    this.brand,
    this.hasVariants = false,
    this.defaultVariantId,
    this.baseUnit,
    this.primaryImage,
    this.price,
    this.priceRange,
    this.stock,
    this.isFavorite = false,
    this.matchType,
    this.updatedAt,
    this.variantCount,
  });

  final String id;
  final String name;

  /// Артикул варианта по умолчанию.
  final String? sku;
  final String? categoryId;
  final String? brand;
  final bool hasVariants;
  final String? defaultVariantId;
  final Unit? baseUnit;
  final ProductImageRef? primaryImage;

  /// Цена варианта по умолчанию по виду цены роли; `null` — цены нет (INV-023: «Добавить» недоступна).
  final Price? price;

  /// Диапазон цен вариантов (`hasVariants = true`).
  final MoneyRange? priceRange;

  /// Остаток варианта по умолчанию на складе запроса; `null` — снимка нет (неизвестен).
  final StockBalance? stock;
  final bool isFavorite;
  final MatchType? matchType;
  final DateTime? updatedAt;

  /// Число вариантов (из локального кэша; в ответе API поля нет).
  final int? variantCount;

  /// Наличие неизвестно: снимка нет или `stockLevel = unknown` (INV-052).
  bool get stockUnknown => stock == null || stock!.isUnknown;

  ProductSummary copyWith({bool? isFavorite, MatchType? matchType}) => ProductSummary(
    id: id,
    name: name,
    sku: sku,
    categoryId: categoryId,
    brand: brand,
    hasVariants: hasVariants,
    defaultVariantId: defaultVariantId,
    baseUnit: baseUnit,
    primaryImage: primaryImage,
    price: price,
    priceRange: priceRange,
    stock: stock,
    isFavorite: isFavorite ?? this.isFavorite,
    matchType: matchType ?? this.matchType,
    updatedAt: updatedAt,
    variantCount: variantCount,
  );
}

/// Блоки карточки `GET /catalog/products/{id}?include=` (08 §4.4.3).
enum ProductInclude {
  variants('variants'),
  prices('prices'),
  stockByWarehouse('stockByWarehouse'),
  images('images');

  const ProductInclude(this.value);

  final String value;

  static const Set<ProductInclude> all = <ProductInclude>{variants, prices, stockByWarehouse, images};
}

/// Карточка товара (`Product` = `ProductSummary` + детали; SCR-14).
final class Product {
  const Product({
    required this.summary,
    this.description,
    this.attributes = const <String, String>{},
    this.images = const <ProductImageRef>[],
    this.variants = const <Variant>[],
    this.packagings = const <Packaging>[],
    this.barcodes = const <String>[],
    this.stockByWarehouse = const <StockBalance>[],
    this.prices = const <Price>[],
    this.availableTotal,
    this.minQuantity,
    this.onecCode,
    this.deletionMark = false,
    this.units = const <Unit>[],
  });

  final ProductSummary summary;
  final String? description;

  /// Свойства товара («Бренд», «Материал» …).
  final Map<String, String> attributes;
  final List<ProductImageRef> images;
  final List<Variant> variants;
  final List<Packaging> packagings;
  final List<String> barcodes;
  final List<StockBalance> stockByWarehouse;
  final List<Price> prices;

  /// Доступно всего по всем складам (`Product.availableTotal`, ядро §19.2); может быть отрицательным.
  final Qty? availableTotal;

  /// Минимальная партия (`minQuantity`, INV-005).
  final Qty? minQuantity;

  /// Код 1С (у `customer` не показывается, 02 ч. B §2.1).
  final String? onecCode;
  final bool deletionMark;

  /// Единицы, на которые ссылаются варианты и упаковки (из кэша; в ответе API — только `baseUnit`).
  final List<Unit> units;

  String get id => summary.id;
  String get name => summary.name;

  /// Вариант по умолчанию: `isDefault`, иначе `defaultVariantId`, иначе первый по `sortOrder`.
  Variant? get defaultVariant {
    if (variants.isEmpty) return null;
    for (final v in variants) {
      if (v.isDefault) return v;
    }
    for (final v in variants) {
      if (v.id == summary.defaultVariantId) return v;
    }
    return ([...variants]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder))).first;
  }
}

/// Недавно просмотренный товар (`CatalogRecentProduct`).
final class RecentProduct {
  const RecentProduct({required this.product, required this.viewedAt});

  final ProductSummary product;
  final DateTime viewedAt;
}

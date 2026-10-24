// DTO каталога — вручную по contracts/openapi/pos-api.v1.yaml (ADR-085): схемы путей
// `/catalog/*`, `/search/*`, `/inventory/*`, `/catalog/sync/{entity}`, `/sync/status`, `/sync/runs`,
// `/favorites/products`, `/catalog/products/recent`. Деньги и количества остаются строками
// контракта (`MoneyAmount`, `QuantityValue`) — в тыйыны и milli-units их переводит маппер
// (catalog_mappers.dart). `jsonKeys`/`requiredKeys` сверяет с OpenAPI
// test/features/catalog/data/catalog_dto_contract_test.dart (allOf — объединение частей).
import 'package:optomstroy/core/network/models/money_dto.dart';
import 'package:optomstroy/features/catalog/data/dto/json_read.dart';

// ---------------------------------------------------------------------------
// Справочники
// ---------------------------------------------------------------------------

/// `Unit`.
final class UnitDto {
  const UnitDto({required this.id, required this.name, required this.qtyPrecision, this.code, this.shortName});

  factory UnitDto.fromJson(Json j) => UnitDto(
    id: req<String>(j, 'id'),
    code: opt<String>(j, 'code'),
    name: req<String>(j, 'name'),
    shortName: opt<String>(j, 'shortName'),
    qtyPrecision: reqInt(j, 'qtyPrecision'),
  );

  static const Set<String> jsonKeys = {'id', 'code', 'name', 'shortName', 'qtyPrecision'};
  static const Set<String> requiredKeys = {'id', 'name', 'qtyPrecision'};

  final String id;
  final String? code;
  final String name;
  final String? shortName;
  final int qtyPrecision;
}

/// `CatalogWarehouse` (`GET /catalog/warehouses`) и `CatalogSyncWarehouse` (+ `shortName`, `sortOrder`; OpenAPI 1.1.0).
final class WarehouseDto {
  const WarehouseDto({
    required this.id,
    required this.name,
    this.code,
    this.isActive,
    this.isDefaultForPos,
    this.shortName,
    this.sortOrder,
  });

  factory WarehouseDto.fromJson(Json j) => WarehouseDto(
    id: req<String>(j, 'id'),
    name: req<String>(j, 'name'),
    code: opt<String>(j, 'code'),
    isActive: optBool(j, 'isActive'),
    isDefaultForPos: optBool(j, 'isDefaultForPos'),
    shortName: opt<String>(j, 'shortName'),
    sortOrder: optInt(j, 'sortOrder'),
  );

  static const Set<String> jsonKeys = {'id', 'name', 'code', 'isActive', 'isDefaultForPos'};
  static const Set<String> syncJsonKeys = {...jsonKeys, 'shortName', 'sortOrder'};
  static const Set<String> requiredKeys = {'id', 'name'};

  final String id;
  final String name;
  final String? code;
  final bool? isActive;
  final bool? isDefaultForPos;

  /// `CatalogSyncWarehouse.shortName` — только выгрузка.
  final String? shortName;

  /// `CatalogSyncWarehouse.sortOrder` — только выгрузка (локального столбца нет: склады упорядочиваются по имени).
  final int? sortOrder;
}

/// `CatalogPriceList`.
final class PriceListDto {
  const PriceListDto({
    required this.id,
    required this.name,
    this.code,
    this.currency,
    this.isDefault,
    this.visibleToRoles = const <String>[],
  });

  factory PriceListDto.fromJson(Json j) => PriceListDto(
    id: req<String>(j, 'id'),
    name: req<String>(j, 'name'),
    code: opt<String>(j, 'code'),
    currency: opt<String>(j, 'currency'),
    isDefault: optBool(j, 'isDefault'),
    visibleToRoles: stringList(j, 'visibleToRoles'),
  );

  static const Set<String> jsonKeys = {'id', 'name', 'code', 'currency', 'isDefault', 'visibleToRoles'};
  static const Set<String> requiredKeys = {'id', 'name'};

  final String id;
  final String name;
  final String? code;
  final String? currency;
  final bool? isDefault;
  final List<String> visibleToRoles;
}

/// `Packaging` (+ `variantId` в `CatalogSyncPackaging`).
final class PackagingDto {
  const PackagingDto({
    required this.id,
    required this.unitId,
    required this.factor,
    this.name,
    this.isDefault,
    this.allowFraction,
    this.barcode,
    this.variantId,
    this.productId,
    this.sortOrder,
  });

  factory PackagingDto.fromJson(Json j) => PackagingDto(
    id: req<String>(j, 'id'),
    unitId: req<String>(j, 'unitId'),
    name: opt<String>(j, 'name'),
    factor: req<String>(j, 'factor'),
    isDefault: optBool(j, 'isDefault'),
    allowFraction: optBool(j, 'allowFraction'),
    barcode: opt<String>(j, 'barcode'),
    variantId: opt<String>(j, 'variantId'),
    productId: opt<String>(j, 'productId'),
    sortOrder: optInt(j, 'sortOrder'),
  );

  static const Set<String> jsonKeys = {'id', 'unitId', 'name', 'factor', 'isDefault', 'allowFraction', 'barcode'};
  static const Set<String> requiredKeys = {'id', 'unitId', 'factor'};
  static const Set<String> syncJsonKeys = {...jsonKeys, 'variantId', 'productId', 'sortOrder'};
  static const Set<String> syncRequiredKeys = {...requiredKeys, 'variantId'};

  final String id;
  final String unitId;
  final String? name;

  /// `QuantityValue` (`"6.000"`).
  final String factor;
  final bool? isDefault;
  final bool? allowFraction;
  final String? barcode;
  final String? variantId;

  /// `CatalogSyncPackaging.productId` (EQ-FEF-02); нет — DAO вычисляет по варианту.
  final String? productId;

  /// `CatalogSyncPackaging.sortOrder` (локального столбца нет).
  final int? sortOrder;
}

/// `CatalogSyncBarcode`.
final class SyncBarcodeDto {
  const SyncBarcodeDto({
    required this.barcode,
    required this.variantId,
    required this.type,
    this.packagingId,
    this.id,
    this.productId,
  });

  factory SyncBarcodeDto.fromJson(Json j) => SyncBarcodeDto(
    barcode: req<String>(j, 'barcode'),
    variantId: req<String>(j, 'variantId'),
    packagingId: opt<String>(j, 'packagingId'),
    type: req<String>(j, 'type'),
    id: opt<String>(j, 'id'),
    productId: opt<String>(j, 'productId'),
  );

  static const Set<String> jsonKeys = {'id', 'barcode', 'variantId', 'packagingId', 'type', 'productId'};
  static const Set<String> requiredKeys = {'barcode', 'variantId', 'type'};

  /// Серверный uuid строки (`deleted[]` ссылается на него, 08 §4.24.1 п. 1; FIX-EF-01).
  final String? id;

  /// Товар штрихкода (EQ-FEF-02); нет — DAO вычисляет по варианту.
  final String? productId;
  final String barcode;
  final String variantId;
  final String? packagingId;
  final String type;
}

/// `Image` (+ `productId`, `variantId` в `CatalogSyncImage`).
final class ImageDto {
  const ImageDto({
    required this.sha256,
    this.thumbUrl,
    this.cardUrl,
    this.fullUrl,
    this.isPrimary,
    this.width,
    this.height,
    this.productId,
    this.variantId,
    this.id,
    this.sortOrder,
  });

  factory ImageDto.fromJson(Json j) => ImageDto(
    sha256: req<String>(j, 'sha256'),
    thumbUrl: opt<String>(j, 'thumbUrl'),
    cardUrl: opt<String>(j, 'cardUrl'),
    fullUrl: opt<String>(j, 'fullUrl'),
    isPrimary: optBool(j, 'isPrimary'),
    width: optInt(j, 'width'),
    height: optInt(j, 'height'),
    productId: opt<String>(j, 'productId'),
    variantId: opt<String>(j, 'variantId'),
    id: opt<String>(j, 'id'),
    sortOrder: optInt(j, 'sortOrder'),
  );

  static const Set<String> jsonKeys = {'sha256', 'thumbUrl', 'cardUrl', 'fullUrl', 'isPrimary', 'width', 'height'};
  static const Set<String> requiredKeys = {'sha256'};
  static const Set<String> syncJsonKeys = {...jsonKeys, 'id', 'productId', 'variantId', 'sortOrder'};

  /// Серверный uuid строки фото (`deleted[]` ссылается на него, FIX-EF-01); вне выгрузки — `null`.
  final String? id;

  /// `CatalogSyncImage.sortOrder` — порядок фото товара (главное — по `sort_order`, EQ-IMG-04).
  final int? sortOrder;

  final String sha256;
  final String? thumbUrl;
  final String? cardUrl;
  final String? fullUrl;
  final bool? isPrimary;
  final int? width;
  final int? height;
  final String? productId;
  final String? variantId;
}

// ---------------------------------------------------------------------------
// Цены и остатки
// ---------------------------------------------------------------------------

/// `Price` (+ `variantId` в `CatalogSyncPrice`).
final class PriceDto {
  const PriceDto({
    required this.priceListId,
    required this.price,
    this.priceListName,
    this.packagingId,
    this.validFrom,
    this.asOf,
    this.variantId,
    this.id,
  });

  factory PriceDto.fromJson(Json j) => PriceDto(
    priceListId: req<String>(j, 'priceListId'),
    priceListName: opt<String>(j, 'priceListName'),
    packagingId: opt<String>(j, 'packagingId'),
    price: reqMoney(j, 'price'),
    validFrom: optDate(j, 'validFrom'),
    asOf: optDate(j, 'asOf'),
    variantId: opt<String>(j, 'variantId'),
    id: opt<String>(j, 'id'),
  );

  static const Set<String> jsonKeys = {'priceListId', 'priceListName', 'packagingId', 'price', 'validFrom', 'asOf'};
  static const Set<String> requiredKeys = {'priceListId', 'price'};
  static const Set<String> syncJsonKeys = {...jsonKeys, 'id', 'variantId'};
  static const Set<String> syncRequiredKeys = {...requiredKeys, 'variantId'};

  /// Серверный uuid строки цены (`deleted[]` ссылается на него, FIX-EF-01); вне выгрузки — `null`.
  final String? id;

  final String priceListId;
  final String? priceListName;
  final String? packagingId;
  final MoneyDto price;
  final DateTime? validFrom;
  final DateTime? asOf;
  final String? variantId;
}

/// `MoneyRange`.
final class MoneyRangeDto {
  const MoneyRangeDto({required this.min, required this.max});

  factory MoneyRangeDto.fromJson(Json j) => MoneyRangeDto(min: reqMoney(j, 'min'), max: reqMoney(j, 'max'));

  static const Set<String> jsonKeys = {'min', 'max'};
  static const Set<String> requiredKeys = {'min', 'max'};

  final MoneyDto min;
  final MoneyDto max;
}

/// `StockBalance`: количества — строки `QuantityValue` (могут отсутствовать у `customer`, API-180).
final class StockBalanceDto {
  const StockBalanceDto({
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

  factory StockBalanceDto.fromJson(Json j) => StockBalanceDto(
    variantId: req<String>(j, 'variantId'),
    warehouseId: req<String>(j, 'warehouseId'),
    warehouseName: opt<String>(j, 'warehouseName'),
    quantity: opt<String>(j, 'quantity'),
    reserved: opt<String>(j, 'reserved'),
    available: opt<String>(j, 'available'),
    unitId: opt<String>(j, 'unitId'),
    asOf: optDate(j, 'asOf'),
    stockLevel: req<String>(j, 'stockLevel'),
  );

  static const Set<String> jsonKeys = {
    'variantId',
    'warehouseId',
    'warehouseName',
    'quantity',
    'reserved',
    'available',
    'unitId',
    'asOf',
    'stockLevel',
  };
  static const Set<String> requiredKeys = {'variantId', 'warehouseId', 'stockLevel'};

  final String variantId;
  final String warehouseId;
  final String? warehouseName;
  final String? quantity;
  final String? reserved;

  /// Может быть отрицательным (`^-?\d…`).
  final String? available;
  final String? unitId;
  final DateTime? asOf;
  final String stockLevel;
}

// ---------------------------------------------------------------------------
// Категории
// ---------------------------------------------------------------------------

/// `Category` / `CatalogCategoryNode` (с `children`).
final class CategoryDto {
  const CategoryDto({
    required this.id,
    required this.name,
    this.parentId,
    this.code,
    this.productCount,
    this.sortOrder,
    this.iconKey,
    this.imageUrl,
    this.hasChildren,
    this.deletionMark,
    this.onecRef,
    this.children = const <CategoryDto>[],
    this.path,
    this.depth,
    this.isVisible,
    this.updatedAt,
  });

  factory CategoryDto.fromJson(Json j) => CategoryDto(
    id: req<String>(j, 'id'),
    parentId: opt<String>(j, 'parentId'),
    name: req<String>(j, 'name'),
    code: opt<String>(j, 'code'),
    productCount: optInt(j, 'productCount'),
    sortOrder: optInt(j, 'sortOrder'),
    iconKey: opt<String>(j, 'iconKey'),
    imageUrl: opt<String>(j, 'imageUrl'),
    hasChildren: optBool(j, 'hasChildren'),
    deletionMark: optBool(j, 'deletionMark'),
    onecRef: opt<String>(j, 'onecRef'),
    children: objectList(j, 'children', CategoryDto.fromJson),
    path: opt<String>(j, 'path'),
    depth: optInt(j, 'depth'),
    isVisible: optBool(j, 'isVisible'),
    updatedAt: optDate(j, 'updatedAt'),
  );

  static const Set<String> jsonKeys = {
    'id',
    'parentId',
    'name',
    'code',
    'productCount',
    'sortOrder',
    'iconKey',
    'imageUrl',
    'hasChildren',
    'deletionMark',
    'onecRef',
  };
  static const Set<String> requiredKeys = {'id', 'name'};
  static const Set<String> nodeJsonKeys = {...jsonKeys, 'children'};

  /// `CatalogSyncCategory` = `Category` + `path`, `depth`, `isVisible`, `updatedAt` (OpenAPI 1.1.0).
  static const Set<String> syncJsonKeys = {...jsonKeys, 'path', 'depth', 'isVisible', 'updatedAt'};

  final String id;
  final String? parentId;
  final String name;
  final String? code;
  final int? productCount;
  final int? sortOrder;
  final String? iconKey;
  final String? imageUrl;
  final bool? hasChildren;
  final bool? deletionMark;
  final String? onecRef;
  final List<CategoryDto> children;

  /// Только выгрузка: materialized path `/root/…/id` (DAO пересчитывает по `parentId`, если предок ещё не загружен).
  final String? path;

  /// Только выгрузка: глубина, корень — 0.
  final int? depth;

  /// Только выгрузка: показ категории в каталоге (07 `categories.is_visible`).
  final bool? isVisible;

  /// Только выгрузка: момент изменения строки сервера.
  final DateTime? updatedAt;
}

/// `CatalogCategoriesResponse`.
final class CategoriesResponseDto {
  const CategoriesResponseDto({required this.items, this.asOf, this.snapshotVersion});

  factory CategoriesResponseDto.fromJson(Json j) => CategoriesResponseDto(
    items: objectList(j, 'items', CategoryDto.fromJson, required: true),
    asOf: optDate(j, 'asOf'),
    snapshotVersion: opt<String>(j, 'snapshotVersion'),
  );

  static const Set<String> jsonKeys = {'items', 'asOf', 'snapshotVersion'};
  static const Set<String> requiredKeys = {'items'};

  final List<CategoryDto> items;
  final DateTime? asOf;
  final String? snapshotVersion;
}

// ---------------------------------------------------------------------------
// Товары и варианты
// ---------------------------------------------------------------------------

/// `ProductSummary`.
final class ProductSummaryDto {
  const ProductSummaryDto({
    required this.id,
    required this.name,
    this.sku,
    this.categoryId,
    this.brand,
    this.hasVariants,
    this.defaultVariantId,
    this.baseUnit,
    this.primaryImage,
    this.price,
    this.priceRange,
    this.stock,
    this.isFavorite,
    this.matchType,
    this.updatedAt,
  });

  factory ProductSummaryDto.fromJson(Json j) => ProductSummaryDto(
    id: req<String>(j, 'id'),
    name: req<String>(j, 'name'),
    sku: opt<String>(j, 'sku'),
    categoryId: opt<String>(j, 'categoryId'),
    brand: opt<String>(j, 'brand'),
    hasVariants: optBool(j, 'hasVariants'),
    defaultVariantId: opt<String>(j, 'defaultVariantId'),
    baseUnit: _optParse(j, 'baseUnit', UnitDto.fromJson),
    primaryImage: _optParse(j, 'primaryImage', ImageDto.fromJson),
    price: _optParse(j, 'price', PriceDto.fromJson),
    priceRange: _optParse(j, 'priceRange', MoneyRangeDto.fromJson),
    stock: _optParse(j, 'stock', StockBalanceDto.fromJson),
    isFavorite: optBool(j, 'isFavorite'),
    matchType: opt<String>(j, 'matchType'),
    updatedAt: optDate(j, 'updatedAt'),
  );

  static const Set<String> jsonKeys = {
    'id',
    'name',
    'sku',
    'categoryId',
    'brand',
    'hasVariants',
    'defaultVariantId',
    'baseUnit',
    'primaryImage',
    'price',
    'priceRange',
    'stock',
    'isFavorite',
    'matchType',
    'updatedAt',
  };
  static const Set<String> requiredKeys = {'id', 'name'};

  final String id;
  final String name;
  final String? sku;
  final String? categoryId;
  final String? brand;
  final bool? hasVariants;
  final String? defaultVariantId;
  final UnitDto? baseUnit;
  final ImageDto? primaryImage;
  final PriceDto? price;
  final MoneyRangeDto? priceRange;
  final StockBalanceDto? stock;
  final bool? isFavorite;
  final String? matchType;
  final DateTime? updatedAt;
}

/// `Variant` (+ `unitId` в `CatalogSyncVariant`).
final class VariantDto {
  const VariantDto({
    required this.id,
    required this.productId,
    this.isDefault,
    this.name,
    this.sku,
    this.attributes = const <String, String>{},
    this.price,
    this.stock,
    this.stockByWarehouse = const <StockBalanceDto>[],
    this.barcodes = const <String>[],
    this.images = const <ImageDto>[],
    this.multiplicity,
    this.unitId,
    this.sortOrder,
    this.deletionMark,
  });

  factory VariantDto.fromJson(Json j) => VariantDto(
    id: req<String>(j, 'id'),
    productId: req<String>(j, 'productId'),
    isDefault: optBool(j, 'isDefault'),
    name: opt<String>(j, 'name'),
    sku: opt<String>(j, 'sku'),
    attributes: stringMap(j, 'attributes'),
    price: _optParse(j, 'price', PriceDto.fromJson),
    stock: _optParse(j, 'stock', StockBalanceDto.fromJson),
    stockByWarehouse: objectList(j, 'stockByWarehouse', StockBalanceDto.fromJson),
    barcodes: stringList(j, 'barcodes'),
    images: objectList(j, 'images', ImageDto.fromJson),
    multiplicity: opt<String>(j, 'multiplicity'),
    unitId: opt<String>(j, 'unitId'),
    sortOrder: optInt(j, 'sortOrder'),
    deletionMark: optBool(j, 'deletionMark'),
  );

  static const Set<String> jsonKeys = {
    'id',
    'productId',
    'isDefault',
    'name',
    'sku',
    'attributes',
    'price',
    'stock',
    'stockByWarehouse',
    'barcodes',
    'images',
    'multiplicity',
    'sortOrder',
    'deletionMark',
  };
  static const Set<String> requiredKeys = {'id', 'productId'};

  /// `CatalogSyncVariant` — без вычисляемых `price`/`stock`, с `unitId` (08 §4.24).
  static const Set<String> syncJsonKeys = {
    'id',
    'productId',
    'isDefault',
    'name',
    'sku',
    'attributes',
    'barcodes',
    'multiplicity',
    'unitId',
    'sortOrder',
    'deletionMark',
  };

  final String id;
  final String productId;
  final bool? isDefault;
  final String? name;
  final String? sku;
  final Map<String, String> attributes;
  final PriceDto? price;
  final StockBalanceDto? stock;
  final List<StockBalanceDto> stockByWarehouse;
  final List<String> barcodes;
  final List<ImageDto> images;

  /// `QuantityValue`.
  final String? multiplicity;
  final String? unitId;
  final int? sortOrder;
  final bool? deletionMark;
}

/// `Product` = `ProductSummary` + детали карточки.
final class ProductDto {
  const ProductDto({
    required this.summary,
    this.description,
    this.attributes = const <String, String>{},
    this.images = const <ImageDto>[],
    this.variants = const <VariantDto>[],
    this.packagings = const <PackagingDto>[],
    this.barcodes = const <String>[],
    this.stockByWarehouse = const <StockBalanceDto>[],
    this.prices = const <PriceDto>[],
    this.availableTotal,
    this.minQuantity,
    this.onecCode,
    this.deletionMark,
  });

  factory ProductDto.fromJson(Json j) => ProductDto(
    summary: ProductSummaryDto.fromJson(j),
    description: opt<String>(j, 'description'),
    attributes: stringMap(j, 'attributes'),
    images: objectList(j, 'images', ImageDto.fromJson),
    variants: objectList(j, 'variants', VariantDto.fromJson),
    packagings: objectList(j, 'packagings', PackagingDto.fromJson),
    barcodes: stringList(j, 'barcodes'),
    stockByWarehouse: objectList(j, 'stockByWarehouse', StockBalanceDto.fromJson),
    prices: objectList(j, 'prices', PriceDto.fromJson),
    availableTotal: opt<String>(j, 'availableTotal'),
    minQuantity: opt<String>(j, 'minQuantity'),
    onecCode: opt<String>(j, 'onecCode'),
    deletionMark: optBool(j, 'deletionMark'),
  );

  static const Set<String> ownKeys = {
    'description',
    'attributes',
    'images',
    'variants',
    'packagings',
    'barcodes',
    'stockByWarehouse',
    'prices',
    'availableTotal',
    'minQuantity',
    'onecCode',
    'deletionMark',
  };
  static const Set<String> jsonKeys = {...ProductSummaryDto.jsonKeys, ...ownKeys};
  static const Set<String> requiredKeys = ProductSummaryDto.requiredKeys;

  final ProductSummaryDto summary;
  final String? description;
  final Map<String, String> attributes;
  final List<ImageDto> images;
  final List<VariantDto> variants;
  final List<PackagingDto> packagings;
  final List<String> barcodes;
  final List<StockBalanceDto> stockByWarehouse;
  final List<PriceDto> prices;
  final String? availableTotal;
  final String? minQuantity;
  final String? onecCode;
  final bool? deletionMark;
}

/// `CatalogSyncProduct` — `Product` без вычисляемых `price`/`stock` (08 §4.24).
final class SyncProductDto {
  const SyncProductDto({
    required this.id,
    required this.name,
    this.sku,
    this.categoryId,
    this.brand,
    this.hasVariants,
    this.defaultVariantId,
    this.baseUnit,
    this.description,
    this.attributes = const <String, String>{},
    this.imageIds = const <String>[],
    this.barcodes = const <String>[],
    this.minQuantity,
    this.onecCode,
    this.deletionMark,
    this.updatedAt,
    this.multiplicity,
    this.isSellable,
  });

  factory SyncProductDto.fromJson(Json j) => SyncProductDto(
    id: req<String>(j, 'id'),
    name: req<String>(j, 'name'),
    sku: opt<String>(j, 'sku'),
    categoryId: opt<String>(j, 'categoryId'),
    brand: opt<String>(j, 'brand'),
    hasVariants: optBool(j, 'hasVariants'),
    defaultVariantId: opt<String>(j, 'defaultVariantId'),
    baseUnit: _optParse(j, 'baseUnit', UnitDto.fromJson),
    description: opt<String>(j, 'description'),
    attributes: stringMap(j, 'attributes'),
    imageIds: stringList(j, 'imageIds'),
    barcodes: stringList(j, 'barcodes'),
    minQuantity: opt<String>(j, 'minQuantity'),
    onecCode: opt<String>(j, 'onecCode'),
    deletionMark: optBool(j, 'deletionMark'),
    updatedAt: optDate(j, 'updatedAt'),
    multiplicity: opt<String>(j, 'multiplicity'),
    isSellable: optBool(j, 'isSellable'),
  );

  static const Set<String> jsonKeys = {
    'id',
    'name',
    'sku',
    'categoryId',
    'brand',
    'hasVariants',
    'defaultVariantId',
    'baseUnit',
    'description',
    'attributes',
    'imageIds',
    'barcodes',
    'minQuantity',
    'multiplicity',
    'isSellable',
    'onecCode',
    'deletionMark',
    'updatedAt',
  };
  static const Set<String> requiredKeys = {'id', 'name'};

  final String id;
  final String name;
  final String? sku;
  final String? categoryId;
  final String? brand;
  final bool? hasVariants;
  final String? defaultVariantId;
  final UnitDto? baseUnit;
  final String? description;
  final Map<String, String> attributes;

  /// Идентификаторы фото (`sha256`, D-30).
  final List<String> imageIds;
  final List<String> barcodes;
  final String? minQuantity;
  final String? onecCode;
  final bool? deletionMark;
  final DateTime? updatedAt;

  /// Кратность продажи товара (`QuantityValue`); `null` — не ведётся (Q-021).
  final String? multiplicity;

  /// Признак «продаётся» (07 `products.is_sellable`); нет поля — `true`.
  final bool? isSellable;
}

/// `CatalogAttributeKey`.
final class AttributeKeyDto {
  const AttributeKeyDto({required this.key, required this.name, required this.values});

  factory AttributeKeyDto.fromJson(Json j) => AttributeKeyDto(
    key: req<String>(j, 'key'),
    name: req<String>(j, 'name'),
    values: stringList(j, 'values', required: true),
  );

  static const Set<String> jsonKeys = {'key', 'name', 'values'};
  static const Set<String> requiredKeys = {'key', 'name', 'values'};

  final String key;
  final String name;
  final List<String> values;
}

/// `CatalogVariantsResponse`.
final class VariantsResponseDto {
  const VariantsResponseDto({required this.items, this.attributeKeys = const <AttributeKeyDto>[], this.asOf});

  factory VariantsResponseDto.fromJson(Json j) => VariantsResponseDto(
    items: objectList(j, 'items', VariantDto.fromJson, required: true),
    attributeKeys: objectList(j, 'attributeKeys', AttributeKeyDto.fromJson),
    asOf: optDate(j, 'asOf'),
  );

  static const Set<String> jsonKeys = {'items', 'attributeKeys', 'asOf'};
  static const Set<String> requiredKeys = {'items'};

  final List<VariantDto> items;
  final List<AttributeKeyDto> attributeKeys;
  final DateTime? asOf;
}

/// `CatalogSyncAttribute` (в локальный кэш не загружается — 07 §11.4).
final class SyncAttributeDto {
  const SyncAttributeDto({
    required this.id,
    required this.code,
    required this.name,
    this.values = const <String>[],
    this.valueType,
    this.unitLabel,
    this.isFilterable,
    this.isVariantAxis,
    this.sortOrder,
  });

  factory SyncAttributeDto.fromJson(Json j) => SyncAttributeDto(
    id: req<String>(j, 'id'),
    code: req<String>(j, 'code'),
    name: req<String>(j, 'name'),
    values: stringList(j, 'values'),
    valueType: opt<String>(j, 'valueType'),
    unitLabel: opt<String>(j, 'unitLabel'),
    isFilterable: optBool(j, 'isFilterable'),
    isVariantAxis: optBool(j, 'isVariantAxis'),
    sortOrder: optInt(j, 'sortOrder'),
  );

  static const Set<String> jsonKeys = {
    'id',
    'code',
    'name',
    'values',
    'valueType',
    'unitLabel',
    'isFilterable',
    'isVariantAxis',
    'sortOrder',
  };
  static const Set<String> requiredKeys = {'id', 'code', 'name'};

  /// Значения `valueType` (07 §6.1 `attribute_value_type`); неизвестное значение не ломает разбор (08 §2.11).
  static const Set<String> valueTypes = {'text', 'number', 'boolean', 'list'};

  final String id;
  final String code;
  final String name;
  final List<String> values;

  /// `text | number | boolean | list`.
  final String? valueType;

  /// Единица числового свойства («мм», «кг»).
  final String? unitLabel;
  final bool? isFilterable;
  final bool? isVariantAxis;
  final int? sortOrder;
}

/// `CatalogRecentProduct` = `ProductSummary` + `viewedAt`.
final class RecentProductDto {
  const RecentProductDto({required this.product, required this.viewedAt});

  factory RecentProductDto.fromJson(Json j) =>
      RecentProductDto(product: ProductSummaryDto.fromJson(j), viewedAt: reqDate(j, 'viewedAt'));

  static const Set<String> jsonKeys = {...ProductSummaryDto.jsonKeys, 'viewedAt'};
  static const Set<String> requiredKeys = {...ProductSummaryDto.requiredKeys, 'viewedAt'};

  final ProductSummaryDto product;
  final DateTime viewedAt;
}

// ---------------------------------------------------------------------------
// Страницы, фасеты, поиск
// ---------------------------------------------------------------------------

/// `Page` (08 §2.5) с элементами [T] и дополнительными полями ответа в [extra].
final class PageDto<T> {
  const PageDto({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
    this.totalEstimate,
    this.isEstimate,
    this.asOf,
    this.extra = const <String, dynamic>{},
  });

  factory PageDto.fromJson(Json j, T Function(Json item) parse) => PageDto(
    items: objectList(j, 'items', parse, required: true),
    nextCursor: opt<String>(j, 'nextCursor'),
    hasMore: req<bool>(j, 'hasMore'),
    totalEstimate: optInt(j, 'totalEstimate'),
    isEstimate: optBool(j, 'isEstimate'),
    asOf: optDate(j, 'asOf'),
    extra: j,
  );

  static const Set<String> jsonKeys = {'items', 'nextCursor', 'hasMore', 'totalEstimate', 'isEstimate', 'asOf'};
  static const Set<String> requiredKeys = {'items', 'nextCursor', 'hasMore'};

  final List<T> items;
  final String? nextCursor;
  final bool hasMore;
  final int? totalEstimate;
  final bool? isEstimate;
  final DateTime? asOf;

  /// Тело ответа целиком (поля `facets`, `query`, `matchTypes`, `count` …).
  final Json extra;
}

/// `CatalogFacetValue`.
final class FacetValueDto {
  const FacetValueDto({required this.value, required this.count});

  factory FacetValueDto.fromJson(Json j) => FacetValueDto(value: req<String>(j, 'value'), count: reqInt(j, 'count'));

  static const Set<String> jsonKeys = {'value', 'count'};
  static const Set<String> requiredKeys = {'value', 'count'};

  final String value;
  final int count;
}

/// `CatalogProductFacets`.
final class FacetsDto {
  const FacetsDto({
    this.brands = const <FacetValueDto>[],
    this.attrs = const <String, List<FacetValueDto>>{},
    this.priceRange,
  });

  factory FacetsDto.fromJson(Json j) {
    final attrs = optObject(j, 'attrs') ?? const <String, dynamic>{};
    return FacetsDto(
      brands: objectList(j, 'brands', FacetValueDto.fromJson),
      attrs: {for (final key in attrs.keys) key: objectList(attrs, key, FacetValueDto.fromJson)},
      priceRange: _optParse(j, 'priceRange', MoneyRangeDto.fromJson),
    );
  }

  static const Set<String> jsonKeys = {'brands', 'attrs', 'priceRange'};
  static const Set<String> requiredKeys = <String>{};

  final List<FacetValueDto> brands;
  final Map<String, List<FacetValueDto>> attrs;
  final MoneyRangeDto? priceRange;
}

/// `SearchMatchTypes`.
final class MatchTypesDto {
  const MatchTypesDto({required this.barcode, required this.sku, required this.fts, required this.trgm});

  factory MatchTypesDto.fromJson(Json j) => MatchTypesDto(
    barcode: reqInt(j, 'barcode'),
    sku: reqInt(j, 'sku'),
    fts: reqInt(j, 'fts'),
    trgm: reqInt(j, 'trgm'),
  );

  static const Set<String> jsonKeys = {'barcode', 'sku', 'fts', 'trgm'};
  static const Set<String> requiredKeys = {'barcode', 'sku', 'fts', 'trgm'};

  final int barcode;
  final int sku;
  final int fts;
  final int trgm;
}

/// `SearchSuggestion`.
final class SuggestionDto {
  const SuggestionDto({required this.text, required this.kind, this.id, this.count});

  factory SuggestionDto.fromJson(Json j) => SuggestionDto(
    text: req<String>(j, 'text'),
    kind: req<String>(j, 'kind'),
    id: opt<String>(j, 'id'),
    count: optInt(j, 'count'),
  );

  static const Set<String> jsonKeys = {'text', 'kind', 'id', 'count'};
  static const Set<String> requiredKeys = {'text', 'kind'};

  final String text;
  final String kind;
  final String? id;
  final int? count;
}

/// `Quantity`.
final class QuantityDto {
  const QuantityDto({required this.value, required this.unitId, this.packagingId, this.baseValue});

  factory QuantityDto.fromJson(Json j) => QuantityDto(
    value: req<String>(j, 'value'),
    unitId: req<String>(j, 'unitId'),
    packagingId: opt<String>(j, 'packagingId'),
    baseValue: opt<String>(j, 'baseValue'),
  );

  static const Set<String> jsonKeys = {'value', 'unitId', 'packagingId', 'baseValue'};
  static const Set<String> requiredKeys = {'value', 'unitId'};

  final String value;
  final String unitId;
  final String? packagingId;
  final String? baseValue;

  /// Тело запроса (`baseValue` вычисляет сервер — не передаётся).
  Map<String, dynamic> toJson() => {'value': value, 'unitId': unitId, 'packagingId': ?packagingId};
}

/// `Warning`.
final class WarningDto {
  const WarningDto({required this.code, required this.message});

  factory WarningDto.fromJson(Json j) => WarningDto(code: req<String>(j, 'code'), message: req<String>(j, 'message'));

  static const Set<String> jsonKeys = {'code', 'message'};
  static const Set<String> requiredKeys = {'code', 'message'};

  final String code;
  final String message;
}

/// `SearchBarcodeResult`.
final class BarcodeResultDto {
  const BarcodeResultDto({
    required this.product,
    required this.variant,
    required this.barcodeType,
    this.packaging,
    this.suggestedQuantity,
    this.warnings = const <WarningDto>[],
  });

  factory BarcodeResultDto.fromJson(Json j) => BarcodeResultDto(
    product: ProductSummaryDto.fromJson(reqObject(j, 'product')),
    variant: VariantDto.fromJson(reqObject(j, 'variant')),
    packaging: _optParse(j, 'packaging', PackagingDto.fromJson),
    barcodeType: req<String>(j, 'barcodeType'),
    suggestedQuantity: _optParse(j, 'suggestedQuantity', QuantityDto.fromJson),
    warnings: objectList(j, 'warnings', WarningDto.fromJson),
  );

  static const Set<String> jsonKeys = {
    'product',
    'variant',
    'packaging',
    'barcodeType',
    'suggestedQuantity',
    'warnings',
  };
  static const Set<String> requiredKeys = {'product', 'variant', 'barcodeType'};

  final ProductSummaryDto product;
  final VariantDto variant;
  final PackagingDto? packaging;
  final String barcodeType;
  final QuantityDto? suggestedQuantity;
  final List<WarningDto> warnings;
}

// ---------------------------------------------------------------------------
// Остатки
// ---------------------------------------------------------------------------

/// `InventoryBalancesResponse`.
final class InventoryBalancesDto {
  const InventoryBalancesDto({required this.items, required this.source, this.asOf});

  factory InventoryBalancesDto.fromJson(Json j) => InventoryBalancesDto(
    items: objectList(j, 'items', StockBalanceDto.fromJson, required: true),
    asOf: optDate(j, 'asOf'),
    source: req<String>(j, 'source'),
  );

  static const Set<String> jsonKeys = {'items', 'asOf', 'source'};
  static const Set<String> requiredKeys = {'items', 'source'};

  final List<StockBalanceDto> items;
  final DateTime? asOf;
  final String source;
}

/// `InventoryCheckRequest` / `InventoryCheckItem`.
final class InventoryCheckRequestDto {
  const InventoryCheckRequestDto({required this.warehouseId, required this.items});

  static const Set<String> jsonKeys = {'warehouseId', 'items'};
  static const Set<String> requiredKeys = {'warehouseId', 'items'};
  static const Set<String> itemJsonKeys = {'variantId', 'quantity'};

  final String warehouseId;
  final List<({String variantId, QuantityDto quantity})> items;

  Map<String, dynamic> toJson() => {
    'warehouseId': warehouseId,
    'items': [
      for (final i in items) {'variantId': i.variantId, 'quantity': i.quantity.toJson()},
    ],
  };
}

/// `InventoryShortage`.
final class InventoryShortageDto {
  const InventoryShortageDto({
    required this.variantId,
    this.requestedBase,
    this.available,
    this.unitId,
    this.stockLevel,
  });

  factory InventoryShortageDto.fromJson(Json j) => InventoryShortageDto(
    variantId: req<String>(j, 'variantId'),
    requestedBase: opt<String>(j, 'requestedBase'),
    available: opt<String>(j, 'available'),
    unitId: opt<String>(j, 'unitId'),
    stockLevel: opt<String>(j, 'stockLevel'),
  );

  static const Set<String> jsonKeys = {'variantId', 'requestedBase', 'available', 'unitId', 'stockLevel'};
  static const Set<String> requiredKeys = {'variantId'};

  final String variantId;
  final String? requestedBase;
  final String? available;
  final String? unitId;
  final String? stockLevel;
}

/// `InventoryCheckResponse`.
final class InventoryCheckResponseDto {
  const InventoryCheckResponseDto({required this.ok, required this.shortages, required this.unavailable, this.asOf});

  factory InventoryCheckResponseDto.fromJson(Json j) => InventoryCheckResponseDto(
    ok: req<bool>(j, 'ok'),
    shortages: objectList(j, 'shortages', InventoryShortageDto.fromJson, required: true),
    unavailable: stringList(j, 'unavailable', required: true),
    asOf: optDate(j, 'asOf'),
  );

  static const Set<String> jsonKeys = {'ok', 'shortages', 'unavailable', 'asOf'};
  static const Set<String> requiredKeys = {'ok', 'shortages', 'unavailable'};

  final bool ok;
  final List<InventoryShortageDto> shortages;
  final List<String> unavailable;
  final DateTime? asOf;
}

// ---------------------------------------------------------------------------
// Офлайн-выгрузка и статус синхронизации
// ---------------------------------------------------------------------------

/// `CatalogSyncResponse` — ровно поля ядра §22.7; `items` разбираются по сущности (маппер).
final class CatalogSyncResponseDto {
  const CatalogSyncResponseDto({
    required this.items,
    required this.deleted,
    required this.nextCursor,
    required this.hasMore,
    required this.serverTime,
  });

  factory CatalogSyncResponseDto.fromJson(Json j) => CatalogSyncResponseDto(
    items: objectList(j, 'items', (item) => item, required: true),
    deleted: stringList(j, 'deleted', required: true),
    nextCursor: req<String>(j, 'nextCursor'),
    hasMore: req<bool>(j, 'hasMore'),
    serverTime: reqDate(j, 'serverTime'),
  );

  static const Set<String> jsonKeys = {'items', 'deleted', 'nextCursor', 'hasMore', 'serverTime'};
  static const Set<String> requiredKeys = jsonKeys;

  final List<Json> items;
  final List<String> deleted;
  final String nextCursor;
  final bool hasMore;
  final DateTime serverTime;
}

/// `SyncCounts`.
final class SyncCountsDto {
  const SyncCountsDto({this.fetched, this.upserted, this.deleted, this.errors, this.sourceTotal});

  factory SyncCountsDto.fromJson(Json j) => SyncCountsDto(
    fetched: optInt(j, 'fetched'),
    upserted: optInt(j, 'upserted'),
    deleted: optInt(j, 'deleted'),
    errors: optInt(j, 'errors'),
    sourceTotal: optInt(j, 'sourceTotal'),
  );

  static const Set<String> jsonKeys = {'fetched', 'upserted', 'deleted', 'errors', 'sourceTotal'};
  static const Set<String> requiredKeys = <String>{};

  final int? fetched;
  final int? upserted;
  final int? deleted;
  final int? errors;
  final int? sourceTotal;
}

/// `SyncEntityStatus`.
final class SyncEntityStatusDto {
  const SyncEntityStatusDto({
    required this.entity,
    this.lastSuccessAt,
    this.lastRunAt,
    this.running,
    this.runId,
    this.consecutiveErrors,
    this.lastErrorAt,
    this.paused,
    this.nextRunAt,
    this.intervalSec,
    this.ageSec,
    this.isStale,
    this.counts,
  });

  factory SyncEntityStatusDto.fromJson(Json j) => SyncEntityStatusDto(
    entity: req<String>(j, 'entity'),
    lastSuccessAt: optDate(j, 'lastSuccessAt'),
    lastRunAt: optDate(j, 'lastRunAt'),
    running: optBool(j, 'running'),
    runId: opt<String>(j, 'runId'),
    consecutiveErrors: optInt(j, 'consecutiveErrors'),
    lastErrorAt: optDate(j, 'lastErrorAt'),
    paused: optBool(j, 'paused'),
    nextRunAt: optDate(j, 'nextRunAt'),
    intervalSec: optInt(j, 'intervalSec'),
    ageSec: optInt(j, 'ageSec'),
    isStale: optBool(j, 'isStale'),
    counts: _optParse(j, 'counts', SyncCountsDto.fromJson),
  );

  static const Set<String> jsonKeys = {
    'entity',
    'lastSuccessAt',
    'lastRunAt',
    'running',
    'runId',
    'consecutiveErrors',
    'lastErrorAt',
    'paused',
    'nextRunAt',
    'intervalSec',
    'ageSec',
    'isStale',
    'counts',
  };
  static const Set<String> requiredKeys = {'entity'};

  final String entity;
  final DateTime? lastSuccessAt;
  final DateTime? lastRunAt;
  final bool? running;
  final String? runId;
  final int? consecutiveErrors;
  final DateTime? lastErrorAt;
  final bool? paused;
  final DateTime? nextRunAt;
  final int? intervalSec;
  final int? ageSec;
  final bool? isStale;
  final SyncCountsDto? counts;
}

/// `SyncStatus`.
final class SyncStatusDto {
  const SyncStatusDto({
    required this.onecReachable,
    required this.checkedAt,
    required this.overall,
    this.entities = const <SyncEntityStatusDto>[],
    this.outbox,
    this.pendingManualOrders,
  });

  factory SyncStatusDto.fromJson(Json j) => SyncStatusDto(
    onecReachable: req<bool>(j, 'onecReachable'),
    checkedAt: reqDate(j, 'checkedAt'),
    overall: req<String>(j, 'overall'),
    entities: objectList(j, 'entities', SyncEntityStatusDto.fromJson),
    outbox: optObject(j, 'outbox'),
    pendingManualOrders: optObject(j, 'pendingManualOrders'),
  );

  static const Set<String> jsonKeys = {
    'onecReachable',
    'checkedAt',
    'overall',
    'entities',
    'outbox',
    'pendingManualOrders',
  };
  static const Set<String> requiredKeys = {'onecReachable', 'checkedAt', 'overall'};

  final bool onecReachable;
  final DateTime checkedAt;
  final String overall;
  final List<SyncEntityStatusDto> entities;

  /// `{pending, failed, dead}`.
  final Json? outbox;

  /// `{count, oldestAt, slaMin, overSla}`.
  final Json? pendingManualOrders;
}

/// `SyncRun`.
final class SyncRunDto {
  const SyncRunDto({
    required this.id,
    required this.entity,
    required this.mode,
    required this.trigger,
    required this.status,
    this.startedAt,
    this.finishedAt,
    this.triggeredBy,
    this.counts,
    this.errorSummary,
  });

  factory SyncRunDto.fromJson(Json j) => SyncRunDto(
    id: req<String>(j, 'id'),
    entity: req<String>(j, 'entity'),
    mode: req<String>(j, 'mode'),
    trigger: req<String>(j, 'trigger'),
    status: req<String>(j, 'status'),
    startedAt: optDate(j, 'startedAt'),
    finishedAt: optDate(j, 'finishedAt'),
    triggeredBy: optObject(j, 'triggeredBy'),
    counts: _optParse(j, 'counts', SyncCountsDto.fromJson),
    errorSummary: opt<String>(j, 'errorSummary'),
  );

  static const Set<String> jsonKeys = {
    'id',
    'entity',
    'mode',
    'trigger',
    'status',
    'startedAt',
    'finishedAt',
    'triggeredBy',
    'counts',
    'errorSummary',
  };
  static const Set<String> requiredKeys = {'id', 'entity', 'mode', 'trigger', 'status'};

  final String id;
  final String entity;
  final String mode;
  final String trigger;
  final String status;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// `UserRef` `{id, displayName, role}`.
  final Json? triggeredBy;
  final SyncCountsDto? counts;
  final String? errorSummary;
}

/// `SyncRunError` (`payload` не разбирается — может содержать данные 1С).
final class SyncRunErrorDto {
  const SyncRunErrorDto({
    required this.id,
    required this.entity,
    required this.errorCode,
    required this.message,
    this.onecRef,
    this.onecCode,
    this.resolvedAt,
  });

  factory SyncRunErrorDto.fromJson(Json j) => SyncRunErrorDto(
    id: req<String>(j, 'id'),
    entity: req<String>(j, 'entity'),
    onecRef: opt<String>(j, 'onecRef'),
    onecCode: opt<String>(j, 'onecCode'),
    errorCode: req<String>(j, 'errorCode'),
    message: req<String>(j, 'message'),
    resolvedAt: optDate(j, 'resolvedAt'),
  );

  static const Set<String> jsonKeys = {
    'id',
    'entity',
    'onecRef',
    'onecCode',
    'errorCode',
    'message',
    'payload',
    'resolvedAt',
  };
  static const Set<String> requiredKeys = {'id', 'entity', 'errorCode', 'message'};

  final String id;
  final String entity;
  final String? onecRef;
  final String? onecCode;
  final String errorCode;
  final String message;
  final DateTime? resolvedAt;
}

/// `SyncRunsCreateRequest`.
final class SyncRunsCreateRequestDto {
  const SyncRunsCreateRequestDto({required this.entity, required this.mode, this.customerId, this.variantIds});

  static const Set<String> jsonKeys = {'entity', 'mode', 'scope'};
  static const Set<String> requiredKeys = {'entity', 'mode'};

  final String entity;
  final String mode;
  final String? customerId;
  final List<String>? variantIds;

  Map<String, dynamic> toJson() => {
    'entity': entity,
    'mode': mode,
    if (customerId != null || variantIds != null) 'scope': {'customerId': ?customerId, 'variantIds': ?variantIds},
  };
}

T? _optParse<T>(Json j, String key, T Function(Json json) parse) {
  final Json? v = optObject(j, key);
  return v == null ? null : parse(v);
}

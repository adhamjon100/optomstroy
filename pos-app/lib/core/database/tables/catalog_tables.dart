// Кэш каталога (07 §11.2; DATA-251): заполняется только из ответов API
// (`GET /catalog/sync/{entity}`, 08 §4.24), локальных правок нет.
// Деньги — INTEGER тыйыны, количества — INTEGER milli-units; REAL запрещён (DATA-252).
// Все `*_at` — INTEGER unix-ms UTC.
// DSL drift: `.check(column.isIn(...))` ссылается на собственный геттер — это не рекурсия.
// ignore_for_file: recursive_getters
import 'package:drift/drift.dart';

@DataClassName('CategoryRow')
@TableIndex(name: 'categories_parent_idx', columns: {#parentId})
@TableIndex(name: 'categories_path_idx', columns: {#path})
class LocalCategories extends Table {
  @override
  String get tableName => 'categories';

  TextColumn get id => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get name => text()();
  TextColumn get nameNorm => text()();
  TextColumn get path => text()();
  IntColumn get depth => integer()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get iconKey => text().nullable()();
  TextColumn get imageSha => text().nullable()();
  IntColumn get productCount => integer().withDefault(const Constant(0))();
  BoolColumn get isVisible => boolean().withDefault(const Constant(true))();
  BoolColumn get deletionMark => boolean().withDefault(const Constant(false))();
  IntColumn get serverUpdatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Индекс `name_norm` — запасной вариант поиска без FTS5 (07 §11.2, DATA-261).
@DataClassName('ProductRow')
@TableIndex(name: 'products_category_idx', columns: {#categoryId})
@TableIndex(name: 'products_sku_norm_idx', columns: {#skuNorm})
@TableIndex(name: 'products_name_norm_idx', columns: {#nameNorm})
class LocalProducts extends Table {
  @override
  String get tableName => 'products';

  TextColumn get id => text()();
  TextColumn get sku => text()();
  TextColumn get skuNorm => text()();
  TextColumn get name => text()();
  TextColumn get nameNorm => text()();
  TextColumn get brand => text().nullable()();
  TextColumn get categoryId => text().nullable()();
  TextColumn get baseUnitCode => text()();
  IntColumn get qtyPrecision => integer().check(qtyPrecision.isBetweenValues(0, 3))();
  BoolColumn get hasVariants => boolean().withDefault(const Constant(false))();
  BoolColumn get isSellable => boolean().withDefault(const Constant(true))();
  IntColumn get multiplicityMilli => integer().nullable()();
  IntColumn get minQtyMilli => integer().nullable()();
  TextColumn get primaryImageSha => text().nullable()();
  TextColumn get attributesJson => text().nullable()();
  BoolColumn get deletionMark => boolean().withDefault(const Constant(false))();
  IntColumn get serverUpdatedAt => integer()();

  /// `Product.defaultVariantId` (08 §3.6). Схема v3.
  TextColumn get defaultVariantId => text().nullable()();

  /// `Product.baseUnit.id` — серверный UUID единицы (08 `Unit.id`). Схема v3.
  TextColumn get baseUnitId => text().nullable()();

  /// `Product.description` — для карточки офлайн (08 §4.24: «полная карточка»). Схема v3.
  TextColumn get description => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ProductVariantRow')
@TableIndex(name: 'product_variants_product_idx', columns: {#productId})
@TableIndex(name: 'product_variants_sku_norm_idx', columns: {#skuNorm})
class LocalProductVariants extends Table {
  @override
  String get tableName => 'product_variants';

  TextColumn get id => text()();
  TextColumn get productId => text()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  TextColumn get name => text()();
  TextColumn get sku => text().nullable()();
  TextColumn get skuNorm => text().nullable()();
  TextColumn get attributesJson => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get imageSha => text().nullable()();
  BoolColumn get deletionMark => boolean().withDefault(const Constant(false))();
  IntColumn get serverUpdatedAt => integer()();

  /// `Variant.multiplicity` в milli-units (ядро §19.2, RM-E-014). Схема v3.
  IntColumn get multiplicityMilli => integer().nullable()();

  /// `Variant.unitId` (08 §4.24). Схема v3.
  TextColumn get unitId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('UnitRow')
class LocalUnits extends Table {
  @override
  String get tableName => 'units';

  /// Код единицы (`Unit.code`; если сервер код не прислал — `Unit.id`).
  TextColumn get code => text()();
  TextColumn get name => text()();
  IntColumn get qtyPrecision => integer().check(qtyPrecision.isBetweenValues(0, 3))();

  /// `Unit.id` — серверный UUID: на него ссылаются `unitId` варианта, упаковки, остатка. Схема v3.
  TextColumn get id => text().nullable()();

  /// `Unit.shortName` («шт»). Схема v3.
  TextColumn get shortName => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {code};
}

/// `product_id` вычисляется по варианту (`GET /catalog/sync/packagings` отдаёт только `variantId`).
@DataClassName('PackagingRow')
@TableIndex(name: 'packagings_product_idx', columns: {#productId})
@TableIndex(name: 'packagings_variant_idx', columns: {#variantId})
class LocalPackagings extends Table {
  @override
  String get tableName => 'packagings';

  TextColumn get id => text()();
  TextColumn get productId => text()();
  TextColumn get unitCode => text()();
  TextColumn get name => text()();
  IntColumn get factorMilli => integer().check(factorMilli.isBiggerThanValue(0))();
  BoolColumn get allowFraction => boolean().withDefault(const Constant(false))();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

  /// `Packaging.variantId` (08 §4.24). Схема v3.
  TextColumn get variantId => text().nullable()();

  /// `Packaging.unitId` — серверный UUID единицы. Схема v3.
  TextColumn get unitId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Офлайн-сканер работает по этой таблице (DATA-259).
@DataClassName('BarcodeRow')
@TableIndex(name: 'barcodes_variant_idx', columns: {#variantId})
@TableIndex(name: 'barcodes_server_id_idx', columns: {#serverId})
class LocalBarcodes extends Table {
  @override
  String get tableName => 'barcodes';

  TextColumn get value => text()();
  TextColumn get productId => text()();
  TextColumn get variantId => text().nullable()();
  TextColumn get packagingId => text().nullable()();

  /// `BarcodeType` (`EAN13|EAN8|UPC|CODE128|CODE39|QR|other`). Схема v3.
  TextColumn get barcodeType => text().nullable()();

  /// Серверный uuid строки (`barcodes.id`): по нему применяется `deleted[]` (08 §4.24, EQ-CSYNC-02). Схема v4.
  TextColumn get serverId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {value};
}

@DataClassName('WarehouseRow')
class LocalWarehouses extends Table {
  @override
  String get tableName => 'warehouses';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get shortName => text().nullable()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('PriceListRow')
class LocalPriceLists extends Table {
  @override
  String get tableName => 'price_lists';

  TextColumn get id => text()();
  TextColumn get name => text()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  BoolColumn get visible => boolean().withDefault(const Constant(true))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Только виды цен, разрешённые роли (DATA-262).
@DataClassName('PriceRow')
@TableIndex(name: 'prices_list_variant_idx', columns: {#priceListId, #variantId})
@TableIndex(name: 'prices_server_id_idx', columns: {#serverId})
class LocalPrices extends Table {
  @override
  String get tableName => 'prices';

  TextColumn get variantId => text()();
  TextColumn get priceListId => text()();
  TextColumn get packagingId => text().nullable()();
  IntColumn get priceTyiyn => integer()();
  IntColumn get serverSyncedAt => integer()();

  /// Серверный uuid строки (`prices.id`): по нему применяется `deleted[]` (08 §4.24, EQ-CSYNC-02). Схема v4.
  TextColumn get serverId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {variantId, priceListId, packagingId};
}

/// Остатки: клиент не вычисляет `available` (значение с сервера). Под ролью
/// `customer` при `customer_stock_display='status'` столбцы `*_milli` — NULL,
/// хранится только `stock_level` (ядро v1.9 §24.2; DATA-262).
@DataClassName('StockBalanceRow')
@TableIndex(name: 'stock_balances_warehouse_available_idx', columns: {#warehouseId, #availableMilli})
class LocalStockBalances extends Table {
  @override
  String get tableName => 'stock_balances';

  TextColumn get variantId => text()();
  TextColumn get warehouseId => text()();
  IntColumn get quantityMilli => integer().nullable()();
  IntColumn get reservedMilli => integer().nullable()();
  IntColumn get availableMilli => integer().nullable()();

  /// `in_stock | low | out | unknown` (08 `StockBalance.stockLevel`). Схема v2.
  TextColumn get stockLevel => text()
      .withDefault(const Constant('unknown'))
      .check(stockLevel.isIn(const ['in_stock', 'low', 'out', 'unknown']))();
  IntColumn get snapshotAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {variantId, warehouseId};
}

/// Метаданные фото; файлы — дисковый кэш `cached_network_image` (URL с `sha`).
@DataClassName('ProductImageMetaRow')
@TableIndex(name: 'product_images_meta_product_idx', columns: {#productId})
@TableIndex(name: 'product_images_meta_server_id_idx', columns: {#serverId})
class LocalProductImagesMeta extends Table {
  @override
  String get tableName => 'product_images_meta';

  TextColumn get productId => text()();
  TextColumn get variantId => text().nullable()();
  TextColumn get sha => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();
  TextColumn get sizesJson => text().nullable()();

  /// Серверный uuid строки (`product_images.id`): по нему применяется `deleted[]` (08 §4.24, EQ-CSYNC-02). Схема v4.
  TextColumn get serverId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {sha, productId, variantId};
}

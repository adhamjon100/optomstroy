// Маппинг DTO → сущности домена и DTO → строки drift (07 §11.3: "1234.50" → 123450 тыйын,
// "2.500" → 2500 milli-units, ISO-8601 → unix-ms UTC). Деньги — только `Money` (целые тыйыны),
// `double` не используется (D-19). Неверный формат суммы/количества → `AmountException`
// (ответ отклоняется целиком через `ErrorMapper.guard`).
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/database/search_norm.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/catalog/data/dto/catalog_dtos.dart';
import 'package:optomstroy/features/catalog/data/dto/json_read.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/inventory.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/domain/entities/sync.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';

// ---------------------------------------------------------------------------
// Значения контракта
// ---------------------------------------------------------------------------

/// `QuantityValue` / знаковое количество (`available` может быть `-3.000`) → milli-units.
Qty parseSignedQty(String value) {
  if (value.startsWith('-')) return Qty(-Qty.fromString(value.substring(1)).milli);
  return Qty.fromString(value);
}

Qty? parseQtyOrNull(String? value) => value == null ? null : parseSignedQty(value);

int? _ms(DateTime? at) => at?.toUtc().millisecondsSinceEpoch;

DateTime? _fromMs(int? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

// ---------------------------------------------------------------------------
// DTO → домен
// ---------------------------------------------------------------------------

extension UnitDtoMapper on UnitDto {
  Unit toEntity() => Unit(id: id, code: code, name: name, shortName: shortName, qtyPrecision: qtyPrecision);
}

extension WarehouseDtoMapper on WarehouseDto {
  Warehouse toEntity() =>
      Warehouse(id: id, name: name, code: code, isActive: isActive ?? true, isDefaultForPos: isDefaultForPos ?? false);
}

extension PriceListDtoMapper on PriceListDto {
  PriceList toEntity() => PriceList(
    id: id,
    name: name,
    code: code,
    currency: currency ?? 'KGS',
    isDefault: isDefault ?? false,
    visibleToRoles: [for (final r in visibleToRoles) ?RoleCode.tryParse(r)],
  );
}

extension PackagingDtoMapper on PackagingDto {
  Packaging toEntity() => Packaging(
    id: id,
    unitId: unitId,
    name: name,
    factor: Qty.fromString(factor),
    isDefault: isDefault ?? false,
    allowFraction: allowFraction ?? false,
    barcode: barcode,
    variantId: variantId,
  );
}

extension ImageDtoMapper on ImageDto {
  ProductImageRef toEntity({int sortOrder = 0}) => ProductImageRef(
    sha256: sha256,
    thumbUrl: thumbUrl,
    cardUrl: cardUrl,
    fullUrl: fullUrl,
    isPrimary: isPrimary ?? false,
    width: width,
    height: height,
    productId: productId,
    variantId: variantId,
    sortOrder: sortOrder,
  );
}

extension PriceDtoMapper on PriceDto {
  Price toEntity() => Price(
    priceListId: priceListId,
    priceListName: priceListName,
    packagingId: packagingId,
    amount: price.value,
    currency: price.currency,
    validFrom: validFrom,
    asOf: asOf,
  );
}

extension MoneyRangeDtoMapper on MoneyRangeDto {
  MoneyRange toEntity() => MoneyRange(min: min.value, max: max.value);
}

extension StockBalanceDtoMapper on StockBalanceDto {
  StockBalance toEntity() => StockBalance(
    variantId: variantId,
    warehouseId: warehouseId,
    warehouseName: warehouseName,
    quantity: parseQtyOrNull(quantity),
    reserved: parseQtyOrNull(reserved),
    available: parseQtyOrNull(available),
    unitId: unitId,
    asOf: asOf,
    stockLevel: StockLevel.parse(stockLevel),
  );
}

extension CategoryDtoMapper on CategoryDto {
  Category toEntity({int depth = 0}) => Category(
    id: id,
    parentId: parentId,
    name: name,
    code: code,
    productCount: productCount ?? 0,
    sortOrder: sortOrder ?? 0,
    iconKey: iconKey,
    imageUrl: imageUrl,
    hasChildren: (hasChildren ?? false) || children.isNotEmpty,
    depth: depth,
    children: [for (final c in children) c.toEntity(depth: depth + 1)],
  );
}

extension CategoriesResponseDtoMapper on CategoriesResponseDto {
  CategoryTree toEntity() => CategoryTree(
    roots: [
      for (final c in items)
        if (c.deletionMark != true) c.toEntity(),
    ],
    asOf: asOf,
    snapshotVersion: snapshotVersion,
  );
}

extension ProductSummaryDtoMapper on ProductSummaryDto {
  ProductSummary toEntity() => ProductSummary(
    id: id,
    name: name,
    sku: sku,
    categoryId: categoryId,
    brand: brand,
    hasVariants: hasVariants ?? false,
    defaultVariantId: defaultVariantId,
    baseUnit: baseUnit?.toEntity(),
    primaryImage: primaryImage?.toEntity(),
    price: price?.toEntity(),
    priceRange: priceRange?.toEntity(),
    stock: stock?.toEntity(),
    isFavorite: isFavorite ?? false,
    matchType: MatchType.tryParse(matchType),
    updatedAt: updatedAt,
  );
}

extension VariantDtoMapper on VariantDto {
  Variant toEntity() => Variant(
    id: id,
    productId: productId,
    isDefault: isDefault ?? false,
    name: name,
    sku: sku,
    attributes: attributes,
    price: price?.toEntity(),
    stock: stock?.toEntity(),
    stockByWarehouse: [for (final s in stockByWarehouse) s.toEntity()],
    barcodes: barcodes,
    images: [for (var i = 0; i < images.length; i++) images[i].toEntity(sortOrder: i)],
    multiplicity: multiplicity == null ? null : Qty.fromString(multiplicity!),
    unitId: unitId,
    sortOrder: sortOrder ?? 0,
    deletionMark: deletionMark ?? false,
  );
}

extension ProductDtoMapper on ProductDto {
  Product toEntity() => Product(
    summary: summary.toEntity(),
    description: description,
    attributes: attributes,
    images: [for (var i = 0; i < images.length; i++) images[i].toEntity(sortOrder: i)],
    variants: [for (final v in variants) v.toEntity()],
    packagings: [for (final p in packagings) p.toEntity()],
    barcodes: barcodes,
    stockByWarehouse: [for (final s in stockByWarehouse) s.toEntity()],
    prices: [for (final p in prices) p.toEntity()],
    availableTotal: parseQtyOrNull(availableTotal),
    minQuantity: minQuantity == null ? null : Qty.fromString(minQuantity!),
    onecCode: onecCode,
    deletionMark: deletionMark ?? false,
    units: [?summary.baseUnit?.toEntity()],
  );
}

extension VariantsResponseDtoMapper on VariantsResponseDto {
  VariantList toEntity() => VariantList(
    items: [for (final v in items) v.toEntity()],
    attributeKeys: [for (final k in attributeKeys) AttributeKey(key: k.key, name: k.name, values: k.values)],
    asOf: asOf,
  );
}

extension FacetsDtoMapper on FacetsDto {
  CatalogFacets toEntity() => CatalogFacets(
    brands: [for (final b in brands) FacetValue(value: b.value, count: b.count)],
    attrs: {
      for (final e in attrs.entries) e.key: [for (final v in e.value) FacetValue(value: v.value, count: v.count)],
    },
    priceRange: priceRange?.toEntity(),
  );
}

/// Страница `ProductSummary` (`/catalog/products`, `/search/products`, `/favorites/products`).
CatalogPage<ProductSummary> productPageFromDto(PageDto<ProductSummaryDto> page, {DateTime? dataAsOf}) {
  final facets = optObject(page.extra, 'facets');
  return CatalogPage<ProductSummary>(
    items: [for (final p in page.items) p.toEntity()],
    nextCursor: page.nextCursor,
    hasMore: page.hasMore,
    totalEstimate: page.totalEstimate ?? optInt(page.extra, 'count'),
    isEstimate: page.isEstimate ?? false,
    asOf: page.asOf ?? dataAsOf,
    facets: facets == null ? null : FacetsDto.fromJson(facets).toEntity(),
  );
}

/// Результат `/search/products`.
SearchResult searchResultFromDto(PageDto<ProductSummaryDto> page, {required String q, DateTime? dataAsOf}) {
  final match = optObject(page.extra, 'matchTypes');
  final counts = match == null ? null : MatchTypesDto.fromJson(match);
  return SearchResult(
    page: productPageFromDto(page, dataAsOf: dataAsOf),
    query: opt<String>(page.extra, 'query') ?? q,
    matchTypes: counts == null
        ? const SearchMatchCounts()
        : SearchMatchCounts(barcode: counts.barcode, sku: counts.sku, fts: counts.fts, trgm: counts.trgm),
    suggestedQuery: opt<String>(page.extra, 'suggestedQuery'),
  );
}

extension BarcodeResultDtoMapper on BarcodeResultDto {
  BarcodeLookup toEntity() => BarcodeLookup(
    product: product.toEntity(),
    variant: variant.toEntity(),
    packaging: packaging?.toEntity(),
    barcodeType: BarcodeType.tryParse(barcodeType) ?? BarcodeType.other,
    suggestedQuantity: suggestedQuantity == null ? null : Qty.fromString(suggestedQuantity!.value),
    suggestedUnitId: suggestedQuantity?.unitId,
    warnings: [for (final w in warnings) CatalogWarning(code: w.code, message: w.message)],
  );
}

extension InventoryBalancesDtoMapper on InventoryBalancesDto {
  InventoryBalances toEntity() => InventoryBalances(
    items: [for (final s in items) s.toEntity()],
    asOf: asOf,
    source: InventorySource.parse(source),
    origin: DataSource.network,
  );
}

extension InventoryCheckResponseDtoMapper on InventoryCheckResponseDto {
  InventoryCheckResult toEntity() => InventoryCheckResult(
    ok: ok,
    shortages: [
      for (final s in shortages)
        InventoryShortage(
          variantId: s.variantId,
          requestedBase: parseQtyOrNull(s.requestedBase),
          available: parseQtyOrNull(s.available),
          unitId: s.unitId,
          stockLevel: StockLevel.parse(s.stockLevel),
        ),
    ],
    unavailable: unavailable,
    asOf: asOf,
  );
}

extension SyncCountsDtoMapper on SyncCountsDto {
  SyncCounts toEntity() =>
      SyncCounts(fetched: fetched, upserted: upserted, deleted: deleted, errors: errors, sourceTotal: sourceTotal);
}

extension SyncStatusDtoMapper on SyncStatusDto {
  SyncStatusInfo toEntity() => SyncStatusInfo(
    onecReachable: onecReachable,
    checkedAt: checkedAt,
    overall: SyncOverall.parse(overall),
    entities: [
      for (final e in entities)
        SyncEntityStatus(
          entity: SyncEntity.tryParse(e.entity),
          entityValue: e.entity,
          lastSuccessAt: e.lastSuccessAt,
          lastRunAt: e.lastRunAt,
          running: e.running ?? false,
          runId: e.runId,
          consecutiveErrors: e.consecutiveErrors ?? 0,
          lastErrorAt: e.lastErrorAt,
          paused: e.paused ?? false,
          nextRunAt: e.nextRunAt,
          intervalSec: e.intervalSec,
          ageSec: e.ageSec,
          isStale: e.isStale ?? false,
          counts: e.counts?.toEntity(),
        ),
    ],
    outbox: outbox == null
        ? null
        : SyncOutboxCounts(
            pending: optInt(outbox!, 'pending') ?? 0,
            failed: optInt(outbox!, 'failed') ?? 0,
            dead: optInt(outbox!, 'dead') ?? 0,
          ),
    pendingManualOrders: pendingManualOrders == null
        ? null
        : PendingManualOrders(
            count: optInt(pendingManualOrders!, 'count') ?? 0,
            oldestAt: optDate(pendingManualOrders!, 'oldestAt'),
            slaMin: optInt(pendingManualOrders!, 'slaMin'),
            overSla: optBool(pendingManualOrders!, 'overSla') ?? false,
          ),
  );
}

extension SyncRunDtoMapper on SyncRunDto {
  SyncRun toEntity() => SyncRun(
    id: id,
    entityValue: entity,
    modeValue: mode,
    triggerValue: trigger,
    statusValue: status,
    startedAt: startedAt,
    finishedAt: finishedAt,
    triggeredById: triggeredBy == null ? null : opt<String>(triggeredBy!, 'id'),
    triggeredByName: triggeredBy == null ? null : opt<String>(triggeredBy!, 'displayName'),
    counts: counts?.toEntity(),
    errorSummary: errorSummary,
  );
}

extension SyncRunErrorDtoMapper on SyncRunErrorDto {
  SyncRunError toEntity() => SyncRunError(
    id: id,
    entityValue: entity,
    errorCode: errorCode,
    message: message,
    onecRef: onecRef,
    onecCode: onecCode,
    resolvedAt: resolvedAt,
  );
}

// ---------------------------------------------------------------------------
// `GET /catalog/sync/{entity}` → строки drift (07 §11.2)
// ---------------------------------------------------------------------------

/// Строки страницы выгрузки и ключи строк (для «полной замены» после загрузки без `since`).
final class SyncPageRows {
  const SyncPageRows({required this.rows, required this.keys});

  final CatalogRows rows;
  final Set<String> keys;
}

/// Элементы страницы [entity] → строки кэша. Ссылки, которых нет в ответе (`product_id` упаковки
/// и штрихкода, `unit_code` по `unitId`, путь категории), DAO вычисляет после вставки.
SyncPageRows syncItemsToRows(CatalogSyncEntity entity, List<Json> items, {required DateTime serverTime}) {
  final at = _ms(serverTime)!;
  final keys = <String>{};
  switch (entity) {
    case CatalogSyncEntity.categories:
      final rows = [for (final j in items) CategoryDto.fromJson(j)];
      keys.addAll(rows.map((r) => r.id));
      return SyncPageRows(
        rows: CatalogRows(
          categories: [
            for (final c in rows)
              LocalCategoriesCompanion.insert(
                id: c.id,
                parentId: Value(c.parentId),
                name: c.name,
                nameNorm: SearchNorm.text(c.name),
                // `path`/`depth` сервера (`CatalogSyncCategory`); DAO пересчитывает их по `parent_id` после вставки
                // (узел, пришедший раньше предка, временно корень — 07 §11.2, EQ-FEF-03).
                path: c.path ?? '/${c.id}',
                depth: c.depth ?? 0,
                sortOrder: Value(c.sortOrder ?? 0),
                iconKey: Value(c.iconKey),
                productCount: Value(c.productCount ?? 0),
                isVisible: Value(c.isVisible ?? true),
                deletionMark: Value(c.deletionMark ?? false),
                serverUpdatedAt: _ms(c.updatedAt) ?? at,
              ),
          ],
        ),
        keys: keys,
      );
    case CatalogSyncEntity.products:
      final rows = [for (final j in items) SyncProductDto.fromJson(j)];
      keys.addAll(rows.map((r) => r.id));
      return SyncPageRows(
        rows: CatalogRows(products: [for (final p in rows) syncProductToRow(p, at)]),
        keys: keys,
      );
    case CatalogSyncEntity.variants:
      final rows = [for (final j in items) VariantDto.fromJson(j)];
      keys.addAll(rows.map((r) => r.id));
      return SyncPageRows(
        rows: CatalogRows(
          variants: [
            for (final v in rows)
              LocalProductVariantsCompanion.insert(
                id: v.id,
                productId: v.productId,
                isDefault: Value(v.isDefault ?? false),
                name: v.name ?? '',
                sku: Value(v.sku),
                skuNorm: Value(v.sku == null ? null : SearchNorm.sku(v.sku!)),
                attributesJson: Value(v.attributes.isEmpty ? null : jsonEncode(v.attributes)),
                sortOrder: Value(v.sortOrder ?? 0),
                deletionMark: Value(v.deletionMark ?? false),
                serverUpdatedAt: at,
                multiplicityMilli: Value(v.multiplicity == null ? null : Qty.fromString(v.multiplicity!).milli),
                unitId: Value(v.unitId),
              ),
          ],
        ),
        keys: keys,
      );
    case CatalogSyncEntity.units:
      final rows = [for (final j in items) UnitDto.fromJson(j)];
      final units = [for (final u in rows) unitToRow(u)];
      keys.addAll(units.map((u) => u.code.value));
      return SyncPageRows(
        rows: CatalogRows(units: units),
        keys: keys,
      );
    case CatalogSyncEntity.packagings:
      final rows = [for (final j in items) PackagingDto.fromJson(j)];
      final packagings = <LocalPackagingsCompanion>[];
      for (final p in rows) {
        final factor = Qty.fromString(p.factor);
        if (factor.milli <= 0) continue; // CHECK factor_milli > 0: строка без коэффициента не кэшируется
        keys.add(p.id);
        packagings.add(
          LocalPackagingsCompanion.insert(
            id: p.id,
            // `productId` выгрузки (EQ-FEF-02); `''` — DAO вычислит по `variant_id`.
            productId: p.productId ?? '',
            unitCode: p.unitId,
            name: p.name ?? '',
            factorMilli: factor.milli,
            allowFraction: Value(p.allowFraction ?? false),
            isDefault: Value(p.isDefault ?? false),
            variantId: Value(p.variantId),
            unitId: Value(p.unitId),
          ),
        );
      }
      return SyncPageRows(
        rows: CatalogRows(packagings: packagings),
        keys: keys,
      );
    case CatalogSyncEntity.barcodes:
      final rows = [for (final j in items) SyncBarcodeDto.fromJson(j)];
      keys.addAll(rows.map((r) => r.barcode));
      return SyncPageRows(
        rows: CatalogRows(
          barcodes: [
            for (final b in rows)
              LocalBarcodesCompanion.insert(
                value: b.barcode,
                productId: b.productId ?? '',
                variantId: Value(b.variantId),
                packagingId: Value(b.packagingId),
                barcodeType: Value(b.type),
                serverId: Value(b.id),
              ),
          ],
        ),
        keys: keys,
      );
    case CatalogSyncEntity.warehouses:
      final rows = [for (final j in items) WarehouseDto.fromJson(j)];
      keys.addAll(rows.map((r) => r.id));
      return SyncPageRows(
        rows: CatalogRows(warehouses: [for (final w in rows) warehouseToRow(w)]),
        keys: keys,
      );
    case CatalogSyncEntity.priceLists:
      final rows = [for (final j in items) PriceListDto.fromJson(j)];
      keys.addAll(rows.map((r) => r.id));
      return SyncPageRows(
        rows: CatalogRows(priceLists: [for (final p in rows) priceListToRow(p)]),
        keys: keys,
      );
    case CatalogSyncEntity.prices:
      final rows = <LocalPricesCompanion>[];
      for (final j in items) {
        final p = PriceDto.fromJson(j);
        final variantId = p.variantId ?? (throw const CatalogDtoException('variantId'));
        keys.add(CatalogDao.syncKeyOf('prices', [variantId, p.priceListId, p.packagingId]));
        rows.add(priceToRow(p, variantId, at));
      }
      return SyncPageRows(
        rows: CatalogRows(prices: rows),
        keys: keys,
      );
    case CatalogSyncEntity.stock:
      final rows = [for (final j in items) StockBalanceDto.fromJson(j)];
      keys.addAll(rows.map((s) => CatalogDao.syncKeyOf('stock', [s.variantId, s.warehouseId])));
      return SyncPageRows(
        rows: CatalogRows(stock: [for (final s in rows) stockToRow(s, at)]),
        keys: keys,
      );
    case CatalogSyncEntity.images:
      final images = <LocalProductImagesMetaCompanion>[];
      var i = 0;
      for (final j in items) {
        final img = ImageDto.fromJson(j);
        final productId = img.productId;
        if (productId == null) continue; // фото без товара не кэшируется (никогда — фото другого товара, RM-E-003)
        keys.add(CatalogDao.syncKeyOf('images', [img.sha256, productId, img.variantId]));
        // Порядок — `sortOrder` сервера (EQ-IMG-04), без него — порядок страницы.
        final int order = img.sortOrder ?? i;
        i++;
        images.add(imageToRow(img, productId, sortOrder: order));
      }
      return SyncPageRows(
        rows: CatalogRows(images: images),
        keys: keys,
      );
    case CatalogSyncEntity.attributes:
      // Локальной таблицы нет (07 §11.4): разбор только для проверки формата.
      for (final j in items) {
        SyncAttributeDto.fromJson(j);
      }
      return const SyncPageRows(rows: CatalogRows(), keys: <String>{});
  }
}

LocalProductsCompanion syncProductToRow(SyncProductDto p, int serverTimeMs) {
  final sku = p.sku ?? '';
  final precision = p.baseUnit?.qtyPrecision ?? 0;
  return LocalProductsCompanion.insert(
    id: p.id,
    sku: sku,
    skuNorm: SearchNorm.sku(sku),
    name: p.name,
    nameNorm: SearchNorm.text(p.name),
    brand: Value(p.brand),
    categoryId: Value(p.categoryId),
    baseUnitCode: p.baseUnit?.code ?? p.baseUnit?.id ?? '',
    qtyPrecision: precision < 0 ? 0 : (precision > Qty.maxPrecision ? Qty.maxPrecision : precision),
    hasVariants: Value(p.hasVariants ?? false),
    isSellable: Value(p.isSellable ?? true),
    multiplicityMilli: Value(p.multiplicity == null ? null : Qty.fromString(p.multiplicity!).milli),
    minQtyMilli: Value(p.minQuantity == null ? null : Qty.fromString(p.minQuantity!).milli),
    primaryImageSha: Value(p.imageIds.isEmpty ? null : p.imageIds.first),
    attributesJson: Value(p.attributes.isEmpty ? null : jsonEncode(p.attributes)),
    deletionMark: Value(p.deletionMark ?? false),
    serverUpdatedAt: _ms(p.updatedAt) ?? serverTimeMs,
    defaultVariantId: Value(p.defaultVariantId),
    baseUnitId: Value(p.baseUnit?.id),
    description: Value(p.description),
  );
}

LocalUnitsCompanion unitToRow(UnitDto u) => LocalUnitsCompanion.insert(
  code: u.code ?? u.id,
  name: u.name,
  qtyPrecision: u.qtyPrecision,
  id: Value(u.id),
  shortName: Value(u.shortName),
);

LocalWarehousesCompanion warehouseToRow(WarehouseDto w) => LocalWarehousesCompanion.insert(
  id: w.id,
  name: w.name,
  shortName: Value(w.shortName),
  isDefault: Value(w.isDefaultForPos ?? false),
  isActive: Value(w.isActive ?? true),
);

LocalPriceListsCompanion priceListToRow(PriceListDto p) =>
    LocalPriceListsCompanion.insert(id: p.id, name: p.name, isDefault: Value(p.isDefault ?? false));

LocalPricesCompanion priceToRow(PriceDto p, String variantId, int serverTimeMs) => LocalPricesCompanion.insert(
  variantId: variantId,
  priceListId: p.priceListId,
  packagingId: Value(p.packagingId),
  priceTyiyn: p.price.value.tyiyn,
  serverSyncedAt: _ms(p.asOf) ?? serverTimeMs,
  serverId: Value(p.id),
);

LocalStockBalancesCompanion stockToRow(StockBalanceDto s, int serverTimeMs) => LocalStockBalancesCompanion.insert(
  variantId: s.variantId,
  warehouseId: s.warehouseId,
  quantityMilli: Value(parseQtyOrNull(s.quantity)?.milli),
  reservedMilli: Value(parseQtyOrNull(s.reserved)?.milli),
  availableMilli: Value(parseQtyOrNull(s.available)?.milli),
  stockLevel: Value(StockLevel.parse(s.stockLevel).value),
  snapshotAt: _ms(s.asOf) ?? serverTimeMs,
);

LocalProductImagesMetaCompanion imageToRow(ImageDto img, String productId, {int sortOrder = 0}) =>
    LocalProductImagesMetaCompanion.insert(
      productId: productId,
      variantId: Value(img.variantId),
      sha: img.sha256,
      sortOrder: Value(sortOrder),
      isPrimary: Value(img.isPrimary ?? false),
      sizesJson: Value(
        jsonEncode({
          'thumbUrl': ?img.thumbUrl,
          'cardUrl': ?img.cardUrl,
          'fullUrl': ?img.fullUrl,
          'width': ?img.width,
          'height': ?img.height,
        }),
      ),
      serverId: Value(img.id),
    );

// ---------------------------------------------------------------------------
// Строки drift → домен
// ---------------------------------------------------------------------------

Unit unitFromRow(UnitRow u) =>
    Unit(id: u.id ?? u.code, code: u.code, name: u.name, shortName: u.shortName, qtyPrecision: u.qtyPrecision);

Warehouse warehouseFromRow(WarehouseRow w) =>
    Warehouse(id: w.id, name: w.name, shortName: w.shortName, isActive: w.isActive, isDefaultForPos: w.isDefault);

PriceList priceListFromRow(PriceListRow p) => PriceList(id: p.id, name: p.name, isDefault: p.isDefault);

ProductImageRef imageFromMeta({
  required String sha,
  String? sizesJson,
  String? productId,
  String? variantId,
  bool isPrimary = false,
  int sortOrder = 0,
}) {
  Json sizes = const <String, dynamic>{};
  if (sizesJson != null) {
    try {
      sizes = asJson(jsonDecode(sizesJson));
    } on FormatException {
      sizes = const <String, dynamic>{};
    } on CatalogDtoException {
      sizes = const <String, dynamic>{};
    }
  }
  return ProductImageRef(
    sha256: sha,
    thumbUrl: opt<String>(sizes, 'thumbUrl'),
    cardUrl: opt<String>(sizes, 'cardUrl'),
    fullUrl: opt<String>(sizes, 'fullUrl'),
    width: optInt(sizes, 'width'),
    height: optInt(sizes, 'height'),
    productId: productId,
    variantId: variantId,
    isPrimary: isPrimary,
    sortOrder: sortOrder,
  );
}

StockBalance stockFromRow(StockBalanceRow s, {String? warehouseName}) => StockBalance(
  variantId: s.variantId,
  warehouseId: s.warehouseId,
  warehouseName: warehouseName,
  quantity: s.quantityMilli == null ? null : Qty(s.quantityMilli!),
  reserved: s.reservedMilli == null ? null : Qty(s.reservedMilli!),
  available: s.availableMilli == null ? null : Qty(s.availableMilli!),
  asOf: _fromMs(s.snapshotAt),
  stockLevel: StockLevel.parse(s.stockLevel),
);

Map<String, String> _attrs(String? json) {
  if (json == null) return const <String, String>{};
  try {
    return stringMap(<String, dynamic>{'a': jsonDecode(json)}, 'a');
  } on FormatException {
    return const <String, String>{};
  }
}

/// Строка локального списка → `ProductSummary` (цена и остаток варианта по умолчанию).
ProductSummary summaryFromListRow(CachedProductListRow r) {
  final p = r.product;
  return ProductSummary(
    id: p.id,
    name: p.name,
    sku: r.variantSku ?? (p.sku.isEmpty ? null : p.sku),
    categoryId: p.categoryId,
    brand: p.brand,
    hasVariants: p.hasVariants || r.variantCount > 1,
    defaultVariantId: r.variantId ?? p.defaultVariantId,
    baseUnit: r.unit == null ? null : unitFromRow(r.unit!),
    primaryImage: r.imageSha == null ? null : imageFromMeta(sha: r.imageSha!, sizesJson: r.imageSizesJson),
    price: r.priceTyiyn == null || r.priceListId == null
        ? null
        : Price(priceListId: r.priceListId!, amount: Money(r.priceTyiyn!)),
    priceRange: r.variantCount > 1 && r.minPriceTyiyn != null && r.maxPriceTyiyn != null
        ? MoneyRange(min: Money(r.minPriceTyiyn!), max: Money(r.maxPriceTyiyn!))
        : null,
    stock: r.stockLevel == null || r.variantId == null || r.warehouseId == null
        ? null
        : StockBalance(
            variantId: r.variantId!,
            warehouseId: r.warehouseId!,
            available: r.availableMilli == null ? null : Qty(r.availableMilli!),
            asOf: _fromMs(r.stockSnapshotAt),
            stockLevel: StockLevel.parse(r.stockLevel),
          ),
    isFavorite: r.isFavorite,
    matchType: MatchType.tryParse(r.matchType),
    updatedAt: _fromMs(p.serverUpdatedAt),
    variantCount: r.variantCount,
  );
}

/// Карточка из кэша → `Product`. Цена/остаток варианта — по [priceListId]/[warehouseId]
/// (по умолчанию — вид цены `is_default` и склад `is_default`).
Product productFromCard(CachedProductCard card, {String? priceListId, String? warehouseId}) {
  final p = card.product;
  final priceList =
      priceListId ?? (card.priceLists.where((l) => l.isDefault).firstOrNull ?? card.priceLists.firstOrNull)?.id;
  final warehouse =
      warehouseId ?? (card.warehouses.where((w) => w.isDefault).firstOrNull ?? card.warehouses.firstOrNull)?.id;
  final listNames = {for (final l in card.priceLists) l.id: l.name};
  final warehouseNames = {for (final w in card.warehouses) w.id: w.name};
  final unitsById = {for (final u in card.units) u.id ?? u.code: u};
  final unitsByCode = {for (final u in card.units) u.code: u};
  Price toPrice(PriceRow r) => Price(
    priceListId: r.priceListId,
    priceListName: listNames[r.priceListId],
    packagingId: r.packagingId,
    amount: Money(r.priceTyiyn),
    asOf: _fromMs(r.serverSyncedAt),
  );
  final barcodesByVariant = <String, List<String>>{};
  for (final b in card.barcodes) {
    if (b.variantId != null) (barcodesByVariant[b.variantId!] ??= <String>[]).add(b.value);
  }
  final variants = [
    for (final v in card.variants)
      Variant(
        id: v.id,
        productId: v.productId,
        isDefault: v.isDefault,
        name: v.name.isEmpty ? null : v.name,
        sku: v.sku,
        attributes: _attrs(v.attributesJson),
        price: card.prices
            .where((r) => r.variantId == v.id && r.priceListId == priceList && r.packagingId == null)
            .map(toPrice)
            .firstOrNull,
        stock: card.stock
            .where((s) => s.variantId == v.id && s.warehouseId == warehouse)
            .map((s) => stockFromRow(s, warehouseName: warehouseNames[s.warehouseId]))
            .firstOrNull,
        stockByWarehouse: [
          for (final s in card.stock.where((s) => s.variantId == v.id))
            stockFromRow(s, warehouseName: warehouseNames[s.warehouseId]),
        ],
        barcodes: barcodesByVariant[v.id] ?? const <String>[],
        images: [
          for (final img in card.images.where((i) => i.variantId == v.id))
            imageFromMeta(
              sha: img.sha,
              sizesJson: img.sizesJson,
              productId: img.productId,
              variantId: img.variantId,
              isPrimary: img.isPrimary,
              sortOrder: img.sortOrder,
            ),
        ],
        multiplicity: v.multiplicityMilli == null ? null : Qty(v.multiplicityMilli!),
        unitId: v.unitId,
        sortOrder: v.sortOrder,
      ),
  ];
  final defaultVariant =
      variants.where((v) => v.id == p.defaultVariantId).firstOrNull ??
      variants.where((v) => v.isDefault).firstOrNull ??
      variants.firstOrNull;
  final images = [
    for (final img in card.images)
      imageFromMeta(
        sha: img.sha,
        sizesJson: img.sizesJson,
        productId: img.productId,
        variantId: img.variantId,
        isPrimary: img.isPrimary,
        sortOrder: img.sortOrder,
      ),
  ];
  final prices = [for (final r in card.prices.where((r) => r.variantId == defaultVariant?.id)) toPrice(r)];
  final variantPrices = [for (final v in variants) ?v.price];
  final baseUnit = unitsById[p.baseUnitId] ?? unitsByCode[p.baseUnitCode];
  final summary = ProductSummary(
    id: p.id,
    name: p.name,
    sku: defaultVariant?.sku ?? (p.sku.isEmpty ? null : p.sku),
    categoryId: p.categoryId,
    brand: p.brand,
    hasVariants: p.hasVariants || variants.length > 1,
    defaultVariantId: defaultVariant?.id ?? p.defaultVariantId,
    baseUnit: baseUnit == null ? null : unitFromRow(baseUnit),
    primaryImage: images.where((i) => i.sha256 == p.primaryImageSha).firstOrNull ?? images.firstOrNull,
    price: defaultVariant?.price,
    priceRange: variantPrices.length > 1
        ? MoneyRange(
            min: variantPrices.map((x) => x.amount).reduce((a, b) => a < b ? a : b),
            max: variantPrices.map((x) => x.amount).reduce((a, b) => a > b ? a : b),
          )
        : null,
    stock: defaultVariant?.stock,
    isFavorite: card.isFavorite,
    updatedAt: _fromMs(p.serverUpdatedAt),
    variantCount: variants.length,
  );
  return Product(
    summary: summary,
    description: p.description,
    attributes: _attrs(p.attributesJson),
    images: images,
    variants: variants,
    packagings: [
      for (final pk in card.packagings)
        Packaging(
          id: pk.id,
          unitId: pk.unitId ?? unitsByCode[pk.unitCode]?.id ?? pk.unitCode,
          name: pk.name.isEmpty ? null : pk.name,
          factor: Qty(pk.factorMilli),
          isDefault: pk.isDefault,
          allowFraction: pk.allowFraction,
          variantId: pk.variantId,
        ),
    ],
    barcodes: [for (final b in card.barcodes) b.value],
    stockByWarehouse: defaultVariant?.stockByWarehouse ?? const <StockBalance>[],
    prices: prices,
    minQuantity: p.minQtyMilli == null ? null : Qty(p.minQtyMilli!),
    deletionMark: p.deletionMark,
    units: [for (final u in card.units) unitFromRow(u)],
  );
}

/// Плоский список категорий кэша → дерево.
CategoryTree categoryTreeFromRows(List<CategoryRow> rows, {DateTime? asOf}) => CategoryTree.fromFlat([
  for (final c in rows)
    Category(
      id: c.id,
      parentId: c.parentId,
      name: c.name,
      productCount: c.productCount,
      sortOrder: c.sortOrder,
      iconKey: c.iconKey,
      depth: c.depth,
    ),
], asOf: asOf);

/// Метка `sync_meta` → домен (`null` — сущность не из перечня кэша).
LocalSyncState? localSyncStateFromRow(SyncMetaRow r) {
  final entity = CatalogSyncEntity.tryParse(r.entity);
  if (entity == null) return null;
  return LocalSyncState(
    entity: entity,
    lastSuccessAt: _fromMs(r.lastSuccessAt),
    cursor: r.serverCursor,
    lastError: r.lastError,
    asOf: _fromMs(r.asOf),
    staleAfter: r.staleAfterSec == null ? null : Duration(seconds: r.staleAfterSec!),
  );
}

/// Unix-ms UTC (07 §11.2).
int toUnixMs(DateTime at) => _ms(at)!;

/// Из unix-ms UTC.
DateTime? fromUnixMs(int? ms) => _fromMs(ms);

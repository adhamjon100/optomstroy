// ADR-085: ручные DTO каталога сверяются с contracts/openapi/pos-api.v1.yaml —
// набор ключей DTO == properties схемы (allOf — объединение), required DTO == required схемы;
// синтетический пример каждой схемы (значения `example` контракта: "16007.50", "124.000" …)
// разбирается DTO и переводится в сущности без потерь (деньги — тыйыны, количества — milli-units).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/catalog/data/dto/catalog_dtos.dart';
import 'package:optomstroy/features/catalog/data/mappers/catalog_mappers.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/sync.dart';

import 'openapi_support.dart';

const List<String> _schemas = <String>[
  'Unit',
  'CatalogWarehouse',
  'CatalogSyncWarehouse',
  'CatalogPriceList',
  'Packaging',
  'CatalogSyncPackaging',
  'CatalogSyncBarcode',
  'Image',
  'CatalogSyncImage',
  'Price',
  'CatalogSyncPrice',
  'MoneyRange',
  'StockBalance',
  'Category',
  'CatalogSyncCategory',
  'CatalogCategoryNode',
  'CatalogCategoriesResponse',
  'ProductSummary',
  'Variant',
  'CatalogSyncVariant',
  'Product',
  'CatalogSyncProduct',
  'CatalogAttributeKey',
  'CatalogVariantsResponse',
  'CatalogSyncAttribute',
  'CatalogRecentProduct',
  'Page',
  'CatalogFacetValue',
  'CatalogProductFacets',
  'SearchMatchTypes',
  'SearchSuggestion',
  'Quantity',
  'Warning',
  'SearchBarcodeResult',
  'InventoryBalancesResponse',
  'InventoryCheckRequest',
  'InventoryCheckItem',
  'InventoryShortage',
  'InventoryCheckResponse',
  'CatalogSyncResponse',
  'SyncCounts',
  'SyncEntityStatus',
  'SyncStatus',
  'SyncRun',
  'SyncRunError',
  'SyncRunsCreateRequest',
];

void main() {
  final OpenApiFacts? api = OpenApiFacts.load(_schemas);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required) {
    expect(keys, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('DTO каталога == схемы OpenAPI (ключи и обязательные поля)', () {
    matches('Unit', UnitDto.jsonKeys, UnitDto.requiredKeys);
    matches('CatalogWarehouse', WarehouseDto.jsonKeys, WarehouseDto.requiredKeys);
    matches('CatalogSyncWarehouse', WarehouseDto.syncJsonKeys, WarehouseDto.requiredKeys);
    matches('CatalogPriceList', PriceListDto.jsonKeys, PriceListDto.requiredKeys);
    matches('Packaging', PackagingDto.jsonKeys, PackagingDto.requiredKeys);
    matches('CatalogSyncPackaging', PackagingDto.syncJsonKeys, PackagingDto.syncRequiredKeys);
    matches('CatalogSyncBarcode', SyncBarcodeDto.jsonKeys, SyncBarcodeDto.requiredKeys);
    matches('Image', ImageDto.jsonKeys, ImageDto.requiredKeys);
    matches('CatalogSyncImage', ImageDto.syncJsonKeys, ImageDto.requiredKeys);
    matches('Price', PriceDto.jsonKeys, PriceDto.requiredKeys);
    matches('CatalogSyncPrice', PriceDto.syncJsonKeys, PriceDto.syncRequiredKeys);
    matches('MoneyRange', MoneyRangeDto.jsonKeys, MoneyRangeDto.requiredKeys);
    matches('StockBalance', StockBalanceDto.jsonKeys, StockBalanceDto.requiredKeys);
    matches('Category', CategoryDto.jsonKeys, CategoryDto.requiredKeys);
    matches('CatalogSyncCategory', CategoryDto.syncJsonKeys, CategoryDto.requiredKeys);
    matches('CatalogCategoryNode', CategoryDto.nodeJsonKeys, CategoryDto.requiredKeys);
    matches('CatalogCategoriesResponse', CategoriesResponseDto.jsonKeys, CategoriesResponseDto.requiredKeys);
    matches('ProductSummary', ProductSummaryDto.jsonKeys, ProductSummaryDto.requiredKeys);
    matches('Variant', VariantDto.jsonKeys, VariantDto.requiredKeys);
    matches('CatalogSyncVariant', VariantDto.syncJsonKeys, VariantDto.requiredKeys);
    matches('Product', ProductDto.jsonKeys, ProductDto.requiredKeys);
    matches('CatalogSyncProduct', SyncProductDto.jsonKeys, SyncProductDto.requiredKeys);
    matches('CatalogAttributeKey', AttributeKeyDto.jsonKeys, AttributeKeyDto.requiredKeys);
    matches('CatalogVariantsResponse', VariantsResponseDto.jsonKeys, VariantsResponseDto.requiredKeys);
    matches('CatalogSyncAttribute', SyncAttributeDto.jsonKeys, SyncAttributeDto.requiredKeys);
    matches('CatalogRecentProduct', RecentProductDto.jsonKeys, RecentProductDto.requiredKeys);
    matches('Page', PageDto.jsonKeys, PageDto.requiredKeys);
    matches('CatalogFacetValue', FacetValueDto.jsonKeys, FacetValueDto.requiredKeys);
    matches('CatalogProductFacets', FacetsDto.jsonKeys, FacetsDto.requiredKeys);
    matches('SearchMatchTypes', MatchTypesDto.jsonKeys, MatchTypesDto.requiredKeys);
    matches('SearchSuggestion', SuggestionDto.jsonKeys, SuggestionDto.requiredKeys);
    matches('Quantity', QuantityDto.jsonKeys, QuantityDto.requiredKeys);
    matches('Warning', WarningDto.jsonKeys, WarningDto.requiredKeys);
    matches('SearchBarcodeResult', BarcodeResultDto.jsonKeys, BarcodeResultDto.requiredKeys);
    matches('InventoryBalancesResponse', InventoryBalancesDto.jsonKeys, InventoryBalancesDto.requiredKeys);
    matches('InventoryCheckRequest', InventoryCheckRequestDto.jsonKeys, InventoryCheckRequestDto.requiredKeys);
    expect(InventoryCheckRequestDto.itemJsonKeys, api!.props('InventoryCheckItem'));
    matches('InventoryShortage', InventoryShortageDto.jsonKeys, InventoryShortageDto.requiredKeys);
    matches('InventoryCheckResponse', InventoryCheckResponseDto.jsonKeys, InventoryCheckResponseDto.requiredKeys);
    matches('CatalogSyncResponse', CatalogSyncResponseDto.jsonKeys, CatalogSyncResponseDto.requiredKeys);
    matches('SyncCounts', SyncCountsDto.jsonKeys, SyncCountsDto.requiredKeys);
    matches('SyncEntityStatus', SyncEntityStatusDto.jsonKeys, SyncEntityStatusDto.requiredKeys);
    matches('SyncStatus', SyncStatusDto.jsonKeys, SyncStatusDto.requiredKeys);
    matches('SyncRun', SyncRunDto.jsonKeys, SyncRunDto.requiredKeys);
    matches('SyncRunError', SyncRunErrorDto.jsonKeys, SyncRunErrorDto.requiredKeys);
    matches('SyncRunsCreateRequest', SyncRunsCreateRequestDto.jsonKeys, SyncRunsCreateRequestDto.requiredKeys);
  }, skip: skip);

  test('страницы списков: дополнительные поля ответа разбираются маппером', () {
    const page = PageDto.jsonKeys;
    expect(api!.responseProps('/catalog/products').difference(page), {'facets'});
    expect(api.responseProps('/search/products').difference(page), {'query', 'matchTypes', 'suggestedQuery'});
    expect(api.responseProps('/favorites/products').difference(page), {'count'});
    expect(api.responseProps('/sync/runs'), page);
    expect(api.responseProps('/sync/runs/{id}/errors'), page);
  }, skip: skip);

  group('примеры схем → DTO → сущности', () {
    test('ProductSummary / Product: деньги в тыйынах, количества в milli-units, matchType', () {
      final summary = ProductSummaryDto.fromJson(api!.example('ProductSummary')).toEntity();
      expect(summary.name, 'Смеситель для кухни Grohe Eurosmart');
      expect(summary.price!.amount.tyiyn, 1600750);
      expect(summary.priceRange!.max.tyiyn, 1600750);
      expect(summary.stock!.available!.milli, 124000);
      expect(summary.stock!.stockLevel, StockLevel.inStock);
      expect(summary.matchType, MatchType.barcode);
      expect(summary.primaryImage!.sha256, 'a' * 64);

      final product = ProductDto.fromJson(api.example('Product')).toEntity();
      expect(product.variants.single.multiplicity!.milli, 124000);
      expect(product.packagings.single.factor.milli, 124000);
      expect(product.availableTotal!.milli, 124000);
      expect(product.minQuantity!.milli, 124000);
      expect(product.prices.single.amount.tyiyn, 1600750);
      expect(product.attributes, {'color': isA<String>()});
      expect(product.defaultVariant, isNotNull);
    }, skip: skip);

    test('категории, варианты, недавние, поиск по штрихкоду', () {
      final categories = api!.example('CatalogCategoriesResponse');
      final deleted = CategoriesResponseDto.fromJson(categories).toEntity();
      expect(deleted.roots, isEmpty, reason: 'в примере deletionMark=true — категория скрыта');
      ((categories['items'] as List<Object?>).single! as Map<String, dynamic>)['deletionMark'] = false;
      final tree = CategoriesResponseDto.fromJson(categories).toEntity();
      expect(tree.roots.single.name, 'Смесители');
      expect(tree.roots.single.children, isNotEmpty);
      expect(tree.roots.single.children.single.depth, 1);
      final variants = VariantsResponseDto.fromJson(api.example('CatalogVariantsResponse')).toEntity();
      expect(variants.items.single.name, 'Хром, 35 мм');
      expect(variants.attributeKeys.single.values, isNotEmpty);
      final recent = RecentProductDto.fromJson(api.example('CatalogRecentProduct'));
      expect(recent.viewedAt, DateTime.utc(2026, 10, 19, 9));
      final lookup = BarcodeResultDto.fromJson(api.example('SearchBarcodeResult')).toEntity();
      expect(lookup.barcodeType, BarcodeType.ean13);
      expect(lookup.suggestedQuantity!.milli, 124000);
      expect(lookup.warnings.single.code, 'STALE_DATA');
    }, skip: skip);

    test('остатки и проверка наличия: знаковое available, источник', () {
      final balances = InventoryBalancesDto.fromJson(api!.example('InventoryBalancesResponse')).toEntity();
      expect(balances.items.single.available!.milli, 124000);
      final check = InventoryCheckResponseDto.fromJson(api.example('InventoryCheckResponse')).toEntity();
      expect(check.shortages.single.available!.milli, 124000);
      expect(parseSignedQty('-3.500').milli, -3500);
    }, skip: skip);

    test('статус синхронизации и прогоны: consecutiveErrors, trigger, счётчики', () {
      final status = SyncStatusDto.fromJson(api!.example('SyncStatus')).toEntity();
      expect(status.overall, SyncOverall.ok);
      expect(status.entities.single.entity, SyncEntity.categories);
      expect(status.entities.single.consecutiveErrors, 1);
      expect(status.entities.single.staleAfter, const Duration(seconds: 2));
      expect(status.outbox!.pending, 1);
      final run = SyncRunDto.fromJson(api.example('SyncRun')).toEntity();
      expect(
        (run.entity, run.mode, run.trigger, run.status),
        (SyncEntity.categories, SyncMode.full, SyncTrigger.schedule, SyncRunStatus.queued),
      );
      expect(run.triggeredByName, isNotNull);
      final error = SyncRunErrorDto.fromJson(api.example('SyncRunError')).toEntity();
      expect(error.errorCode, 'DUPLICATE_SUSPECTED');
    }, skip: skip);

    test('офлайн-выгрузка: пример каждой сущности превращается в строки кэша', () {
      final serverTime = DateTime.utc(2026, 10, 19, 9);
      final perEntity = <CatalogSyncEntity, String>{
        CatalogSyncEntity.categories: 'CatalogSyncCategory',
        CatalogSyncEntity.products: 'CatalogSyncProduct',
        CatalogSyncEntity.variants: 'CatalogSyncVariant',
        CatalogSyncEntity.units: 'Unit',
        CatalogSyncEntity.packagings: 'CatalogSyncPackaging',
        CatalogSyncEntity.barcodes: 'CatalogSyncBarcode',
        CatalogSyncEntity.warehouses: 'CatalogSyncWarehouse',
        CatalogSyncEntity.priceLists: 'CatalogPriceList',
        CatalogSyncEntity.prices: 'CatalogSyncPrice',
        CatalogSyncEntity.stock: 'StockBalance',
        CatalogSyncEntity.images: 'CatalogSyncImage',
        CatalogSyncEntity.attributes: 'CatalogSyncAttribute',
      };
      expect(perEntity.keys.toSet(), CatalogSyncEntity.values.toSet());
      for (final e in perEntity.entries) {
        final page = syncItemsToRows(e.key, [api!.example(e.value)], serverTime: serverTime);
        expect(page.rows.length, e.key == CatalogSyncEntity.attributes ? 0 : 1, reason: e.key.value);
        expect(page.keys.length, e.key == CatalogSyncEntity.attributes ? 0 : 1, reason: e.key.value);
      }
      // Схема элемента по сущности — `x-entity-schema` контракта (B-AR-14), не догадка теста.
      expect(api!.entitySchemas(), {for (final e in perEntity.entries) e.key.value: e.value});
      final response = CatalogSyncResponseDto.fromJson(api.example('CatalogSyncResponse'));
      expect((response.hasMore, response.serverTime), (true, serverTime));
    }, skip: skip);

    test('тела запросов — подмножество ключей схемы', () {
      const create = SyncRunsCreateRequestDto(entity: 'stock', mode: 'incremental', variantIds: ['v-1']);
      expect(SyncRunsCreateRequestDto.jsonKeys.containsAll(create.toJson().keys), isTrue);
      expect(create.toJson()['scope'], {
        'variantIds': ['v-1'],
      });
      const quantity = QuantityDto(value: '2.500', unitId: 'u-1');
      expect(api!.props('Quantity').containsAll(quantity.toJson().keys), isTrue);
    }, skip: skip);
  });
}

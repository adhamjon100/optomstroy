// Адаптер SearchRepository → ScanBarcodeLookup композиционного корня (app/di/scan_catalog_adapter.dart):
// поля товара/варианта/упаковки, ambiguous_barcode, офлайн-кэш; сценарий LookupScannedBarcode поверх него.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/di/scan_catalog_adapter.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';

class _Search implements SearchRepository {
  Result<BarcodeLookup> online = const FailureResult<BarcodeLookup>(ServerFailure(code: 'NOT_FOUND', status: 404));
  BarcodeLookup? cached;
  String? warehouseSeen;

  @override
  Future<Result<BarcodeLookup>> barcode(String value, {String? warehouseId}) async {
    warehouseSeen = warehouseId;
    return online;
  }

  @override
  Future<Result<BarcodeLookup?>> barcodeCached(String value, {String? warehouseId, String? priceListId}) async =>
      Success<BarcodeLookup?>(cached);

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BarcodeLookup _lookup({
  List<CatalogWarning> warnings = const <CatalogWarning>[],
  DataSource source = DataSource.network,
}) => BarcodeLookup(
  product: const ProductSummary(
    id: 'p1',
    name: 'Смеситель Frap F4252',
    sku: 'F4252',
    baseUnit: Unit(id: 'u-pcs', name: 'штука', shortName: 'шт', qtyPrecision: 0),
  ),
  variant: const Variant(id: 'v1', productId: 'p1', sku: 'F4252-CR', name: 'хром'),
  packaging: Packaging(id: 'pk1', unitId: 'u-box', factor: Qty.units(6), name: 'кор.'),
  barcodeType: BarcodeType.ean13,
  suggestedQuantity: Qty.units(6),
  warnings: warnings,
  source: source,
  asOf: DateTime.utc(2026, 10, 22, 9),
);

void main() {
  test('поля BarcodeLookup → ScanLookupResult; склад передаётся', () async {
    final search = _Search()..online = Success<BarcodeLookup>(_lookup());
    final r = (await CatalogScanBarcodeLookup(search, warehouseId: 'w1').lookupOnline('4607012345678')).valueOrNull!;
    expect(search.warehouseSeen, 'w1');
    expect((r.productId, r.variantId, r.packagingId), ('p1', 'v1', 'pk1'));
    expect(r.sku, 'F4252-CR');
    expect(r.unitLabel, 'кор.');
    expect(r.suggestedQuantity, Qty.units(6));
    expect(r.ambiguous, isFalse);
    expect(r.fromCache, isFalse);
  });

  test('ambiguous_barcode → ambiguous; кэш → fromCache', () async {
    final search = _Search()
      ..online = Success<BarcodeLookup>(
        _lookup(
          warnings: const <CatalogWarning>[CatalogWarning(code: 'ambiguous_barcode', message: '')],
        ),
      )
      ..cached = _lookup(source: DataSource.cache);
    final adapter = CatalogScanBarcodeLookup(search);
    expect((await adapter.lookupOnline('x')).valueOrNull!.ambiguous, isTrue);
    expect((await adapter.lookupCached('x')).valueOrNull!.fromCache, isTrue);
  });

  test('сценарий поверх адаптера: офлайн → кэш', () async {
    final search = _Search()
      ..online = const FailureResult<BarcodeLookup>(NetworkFailure(NetworkFailureKind.offline))
      ..cached = _lookup(source: DataSource.cache);
    final outcome = await LookupScannedBarcode(CatalogScanBarcodeLookup(search))('4607012345678');
    expect((outcome as ScanFound).result.fromCache, isTrue);
  });
}

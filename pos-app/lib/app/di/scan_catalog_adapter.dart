// Адаптер `SearchRepository` каталога → порт `ScanBarcodeLookup` фичи scan (композиционный корень).
//
// Фича scan не импортирует catalog (ребра `scan → catalog` нет в DAG 06 §6.1 / scripts/check_layers.py —
// EQ-FEF-07, EQ-SCAN-03), поэтому адаптер живёт в `app/di/` и подключается в `appOverrides`:
//   scanBarcodeLookupProvider.overrideWith((ref) => CatalogScanBarcodeLookup(ref.watch(searchRepositoryProvider))).
// Тест — `test/features/scan/catalog_scan_adapter_test.dart`.
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';

/// `ScanBarcodeLookup` поверх `SearchRepository.barcode` / `barcodeCached`.
final class CatalogScanBarcodeLookup implements ScanBarcodeLookup {
  /// Создаёт адаптер; [warehouseId] — склад корзины/терминала (по умолчанию — склад сервера).
  CatalogScanBarcodeLookup(this._search, {this.warehouseId});

  final SearchRepository _search;

  /// Склад для остатков в ответе.
  final String? warehouseId;

  @override
  Future<Result<ScanLookupResult>> lookupOnline(String value) async =>
      (await _search.barcode(value, warehouseId: warehouseId)).map(toScan);

  @override
  Future<Result<ScanLookupResult?>> lookupCached(String value) async =>
      (await _search.barcodeCached(value, warehouseId: warehouseId)).map((l) => l == null ? null : toScan(l));

  /// `BarcodeLookup` → `ScanLookupResult`.
  static ScanLookupResult toScan(BarcodeLookup l) => ScanLookupResult(
    productId: l.product.id,
    productName: l.product.name,
    sku: l.variant.sku ?? l.product.sku,
    variantId: l.variant.id,
    variantName: l.variant.name,
    packagingId: l.packaging?.id,
    packagingName: l.packaging?.name,
    suggestedQuantity: l.suggestedQuantity,
    unitLabel: l.packaging?.name ?? l.product.baseUnit?.label,
    ambiguous: l.warnings.any((w) => w.code.toLowerCase() == 'ambiguous_barcode'),
    fromCache: l.source == DataSource.cache,
    asOf: l.asOf,
  );
}

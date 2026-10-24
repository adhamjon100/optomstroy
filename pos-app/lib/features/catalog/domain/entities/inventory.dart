// Остатки и проверка наличия (08 §4.6: `GET /inventory/balances`, `POST /inventory/check`). Чистый Dart.
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';

/// Источник остатков ответа `GET /inventory/balances` (`source`).
enum InventorySource {
  /// Снимок реплики (D-29).
  snapshot('snapshot'),

  /// Живой запрос к 1С (`live=true`).
  live('live');

  const InventorySource(this.value);

  final String value;

  static InventorySource parse(String? value) => value == 'live' ? live : snapshot;
}

/// Остатки вариантов (`InventoryBalancesResponse`).
final class InventoryBalances {
  const InventoryBalances({required this.items, this.asOf, this.source = InventorySource.snapshot, this.origin});

  final List<StockBalance> items;
  final DateTime? asOf;
  final InventorySource source;

  /// Откуда данные на клиенте (сеть / локальный кэш); `null` — сеть.
  final DataSource? origin;
}

/// Строка проверки наличия (`InventoryCheckItem`): количество в единице [unitId] или упаковке [packagingId].
final class InventoryCheckLine {
  const InventoryCheckLine({required this.variantId, required this.quantity, required this.unitId, this.packagingId});

  final String variantId;
  final Qty quantity;
  final String unitId;
  final String? packagingId;
}

/// Нехватка (`InventoryShortage`).
final class InventoryShortage {
  const InventoryShortage({
    required this.variantId,
    this.requestedBase,
    this.available,
    this.unitId,
    this.stockLevel = StockLevel.unknown,
  });

  final String variantId;
  final Qty? requestedBase;
  final Qty? available;
  final String? unitId;
  final StockLevel stockLevel;
}

/// Результат `POST /inventory/check` (`InventoryCheckResponse`).
final class InventoryCheckResult {
  const InventoryCheckResult({
    required this.ok,
    this.shortages = const <InventoryShortage>[],
    this.unavailable = const <String>[],
    this.asOf,
  });

  final bool ok;
  final List<InventoryShortage> shortages;

  /// Варианты, недоступные к продаже.
  final List<String> unavailable;
  final DateTime? asOf;
}

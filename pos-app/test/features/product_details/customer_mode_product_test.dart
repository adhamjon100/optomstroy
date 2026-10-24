// SCR-14 в режиме клиента (RM-E-017; 02 SCR-14 вариант `customer`, SCR-50 UI-50-007; 10 CUST-021,
// CUST-022): вид цены — «Ваш вид цены: …» без подсказки staff; показ остатков берётся из
// `GET /settings/public` через привязку корня (`customerModeOverrides`), а не из значения по умолчанию.
// Синтетические данные (на фикстурах, не реальная интеграция).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/router/shells/customer_mode_bindings.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart' as public_settings;
import 'package:optomstroy/core/enums.dart' show CustomerStockDisplay, RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/components/warehouse_stock_table.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/product_details/product_details_providers.dart';

import 'product_fixtures.dart';

FakeCatalogRepository _catalog() {
  final Product p = singleVariantProduct();
  return FakeCatalogRepository(cached: p, network: Success<Product>(p));
}

/// Переопределения как в приложении: значение `customer_stock_display` приходит из публичных настроек.
List<Override> _rootOverrides(CustomerStockDisplay serverValue) => <Override>[
  ...customerModeOverrides,
  public_settings.customerStockDisplayProvider.overrideWithValue(serverValue),
  catalogRepositoryProvider.overrideWithValue(_catalog()),
  cartDraftRepositoryProvider.overrideWithValue(FakeCartDraftRepository()),
  catalogViewerRoleProvider.overrideWithValue(RoleCode.customer),
  productImageBaseUriProvider.overrideWithValue(Uri.parse('https://pos.test/api/v1')),
];

StockBadge _badge(WidgetTester tester) =>
    tester.widget<StockBadge>(find.byKey(const ValueKey<String>('product-stock-badge')));

void main() {
  testWidgets('customer: чип «Ваш вид цены: …» без подсказки staff; seller — название вида цены', (tester) async {
    await pumpProduct(
      tester,
      overrides: productOverrides(catalog: _catalog(), role: RoleCode.customer),
    );
    StatusChip chip() => tester.widget<StatusChip>(find.byKey(const ValueKey<String>('product-price-list')));
    expect(chip().label, 'Ваш вид цены: Розничная');
    expect(chip().tooltip, isNull);

    await tester.pumpWidget(const SizedBox());
    await pumpProduct(tester, overrides: productOverrides(catalog: _catalog()));
    expect(chip().label, 'Розничная');
    expect(chip().tooltip, isNotNull);
  });

  testWidgets('привязка корня: сервер `status` → без чисел и таблицы складов', (tester) async {
    await pumpProduct(tester, overrides: _rootOverrides(CustomerStockDisplay.status));
    expect(_badge(tester).label, isNot(contains('24')));
    expect(find.textContaining('Доступно 24'), findsNothing);
    expect(find.byType(WarehouseStockTable), findsNothing);
  });

  testWidgets('привязка корня: сервер `quantity` → «В наличии · 24 шт», без «Резерв»/«Остаток»', (tester) async {
    await pumpProduct(tester, overrides: _rootOverrides(CustomerStockDisplay.quantity));
    expect(_badge(tester).label, 'В наличии · 24 шт');
    expect(find.textContaining('Резерв'), findsNothing);
    expect(find.byType(WarehouseStockTable), findsNothing);
  });
}

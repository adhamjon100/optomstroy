// T-CAT-017, T-CAT-022 (widget): SCR-13 «Фильтры» — лист compact/medium (RM-E-007).
// «Показать N» = totalEstimate сервера (limit=1, через 300 мс), 0 — «Нет товаров» недоступна (AC-UI-13-004);
// «от > до» — ошибка и блокировка применения (AC-UI-13-002); фасеты — только при наличии значений
// (AC-UI-13-001); склад скрыт для customer (AC-UI-13-009); бренд OR → `brand=a,b`.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_filters_screen.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_filter_codec.dart';

import 'support/catalog_fakes.dart';

const CatalogFacets _facets = CatalogFacets(
  brands: <FacetValue>[
    FacetValue(value: 'Frap', count: 12),
    FacetValue(value: 'Grohe', count: 3),
  ],
  attrs: <String, List<FacetValue>>{
    'color': <FacetValue>[FacetValue(value: 'хром', count: 9)],
  },
);

Future<void> _pump(WidgetTester tester, CatalogHarness h, {String? f}) async {
  setWindow(tester, kCompact);
  await tester.pumpWidget(catalogApp(h, home: CatalogFiltersScreen(f: f)));
  await settle(tester);
}

AppButton _apply(WidgetTester tester) =>
    tester.widget<AppButton>(find.byKey(const ValueKey<String>('filter-sheet-apply')));

void main() {
  testWidgets('счётчик «Показать N товаров» по totalEstimate (limit=1); фасеты бренда и цвета', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository();
    repo.networkPages.add(Success<CatalogPage<ProductSummary>>(page(products(1), total: 124, facets: _facets)));
    await _pump(tester, CatalogHarness(catalog: repo));
    expect(repo.productCalls.single.limit, 1);
    expect(_apply(tester).label, 'Показать 124 товара');
    expect(find.byKey(const ValueKey<String>('filter-section-brand')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('filter-section-attr-color')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('filter-section-attr-size')),
      findsNothing,
      reason: 'нет значений — нет секции',
    );
    expect(find.byKey(const ValueKey<String>('filter-section-warehouse')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('filter-brand-Frap')));
    await tester.tap(find.byKey(const ValueKey<String>('filter-brand-Grohe')));
    await tester.pump(const Duration(milliseconds: 299));
    expect(repo.productCalls, hasLength(1), reason: 'подсчёт не раньше 300 мс');
    await tester.pump(const Duration(milliseconds: 5));
    await settle(tester);
    expect(repo.productCalls, hasLength(2), reason: 'частые изменения — один подсчёт');
    expect(repo.productCalls.last.filter.brands, <String>['Frap', 'Grohe']);
  });

  testWidgets('0 товаров — «Нет товаров» недоступна + «Ослабьте условия»', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository();
    repo.networkPages.add(Success<CatalogPage<ProductSummary>>(page(const <ProductSummary>[], total: 0)));
    await _pump(tester, CatalogHarness(catalog: repo));
    expect(_apply(tester).label, 'Нет товаров');
    expect(_apply(tester).onPressed, isNull);
    expect(find.text('Ослабьте условия'), findsOneWidget);
  });

  testWidgets('цена «от 3000 до 1500» — ошибка и блокировка применения', (tester) async {
    await _pump(tester, CatalogHarness());
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey<String>('filter-price-from')), matching: find.byType(EditableText)),
      '3000',
    );
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey<String>('filter-price-to')), matching: find.byType(EditableText)),
      '1500',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    expect(find.text('Минимальная цена больше максимальной'), findsOneWidget);
    expect(_apply(tester).onPressed, isNull);
  });

  testWidgets('черновик из f: значения отмечены; «Сбросить» снимает все и пересчитывает', (tester) async {
    final CatalogHarness h = CatalogHarness();
    final String f = CatalogFilterCodec.encode(const CatalogFilter(inStock: true, favorite: true))!;
    await _pump(tester, h, f: f);
    expect(h.catalog.productCalls.first.filter.inStock, isTrue);
    expect(h.catalog.productCalls.first.filter.favorite, isTrue);
    await tester.tap(find.text('Сбросить').first);
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    expect(h.catalog.productCalls.last.filter.inStock, isNull);
    expect(h.catalog.productCalls.last.filter.favorite, isNull);
  });

  testWidgets('customer: секции «Склад» нет', (tester) async {
    await _pump(tester, CatalogHarness(role: RoleCode.customer));
    expect(find.byKey(const ValueKey<String>('filter-section-warehouse')), findsNothing);
  });
}

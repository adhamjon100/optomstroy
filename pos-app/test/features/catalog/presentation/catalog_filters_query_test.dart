// EQ-CAT-12 (перенос этапа E): параметр `q` маршрута SCR-13 `/catalog/filters?f=&q=` (02 SCR-13.6 — данные
// перехода `f`, `categoryId`, `q?`). Лист, открытый из поиска SCR-11, считает «Показать N» и фасеты по
// `GET /search/products?q=…&limit=1`; без `q` (или короче минимума) — по каталогу, как раньше.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/presentation/catalog_paths.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_filters_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_search_screen.dart';

import 'support/catalog_fakes.dart';

const CatalogFacets _facets = CatalogFacets(brands: <FacetValue>[FacetValue(value: 'Frap', count: 7)]);

AppButton _apply(WidgetTester tester) =>
    tester.widget<AppButton>(find.byKey(const ValueKey<String>('filter-sheet-apply')));

CatalogHarness _harness({int total = 37}) {
  final FakeSearchRepository search = FakeSearchRepository()
    ..results = (String q) => SearchResult(
      query: q,
      page: page(products(1), total: total, facets: _facets),
    );
  final FakeCatalogRepository catalog = FakeCatalogRepository();
  catalog.networkPages.add(Success<CatalogPage<ProductSummary>>(page(products(1), total: 500)));
  return CatalogHarness(catalog: catalog, search: search);
}

void main() {
  test('CatalogPaths.filters: q в location листа (пустые параметры не пишутся)', () {
    expect(
      CatalogPaths.filters(f: 'brand=Frap', q: 'смеситель'),
      '/catalog/filters?f=brand%3DFrap&q=%D1%81%D0%BC%D0%B5%D1%81%D0%B8%D1%82%D0%B5%D0%BB%D1%8C',
    );
    expect(CatalogPaths.filters(), '/catalog/filters');
    expect(CatalogPaths.filters(q: ''), '/catalog/filters');
  });

  testWidgets('q в конструкторе: счётчик и фасеты — по поиску (limit=1), каталог не запрашивается', (tester) async {
    final CatalogHarness h = _harness();
    setWindow(tester, kCompact);
    await tester.pumpWidget(
      catalogApp(
        h,
        home: const CatalogFiltersScreen(f: 'brand=Frap', q: ' смеситель '),
      ),
    );
    await settle(tester);

    final SearchQuery call = h.search.calls.single;
    expect(call.q, 'смеситель');
    expect(call.limit, 1);
    expect(call.filter.brands, <String>['Frap']);
    expect(h.catalog.productCalls, isEmpty);
    expect(_apply(tester).label, 'Показать 37 товаров');
    expect(find.byKey(const ValueKey<String>('filter-brand-Frap')), findsOneWidget);

    // Изменение фильтра — повторный подсчёт с той же строкой поиска.
    await tester.tap(find.byKey(const ValueKey<String>('filter-in-stock')));
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    expect(h.search.calls, hasLength(2));
    expect(h.search.calls.last.q, 'смеситель');
    expect(h.search.calls.last.filter.inStock, isTrue);
  });

  testWidgets('q из маршрута go_router `/catalog/filters?f=&q=` (маршрут передаёт в экран только f)', (tester) async {
    final CatalogHarness h = _harness(total: 5);
    final GoRouter router = GoRouter(
      initialLocation: CatalogPaths.filters(q: 'кран'),
      routes: <RouteBase>[
        GoRoute(
          path: '/catalog/filters',
          builder: (BuildContext context, GoRouterState state) =>
              CatalogFiltersScreen(f: state.uri.queryParameters['f']),
        ),
      ],
    );
    addTearDown(router.dispose);
    setWindow(tester, kCompact);
    await tester.pumpWidget(catalogApp(h, router: router));
    await settle(tester);
    expect(h.search.calls.single.q, 'кран');
    expect(h.catalog.productCalls, isEmpty);
    expect(_apply(tester).label, 'Показать 5 товаров');
  });

  testWidgets('без q или q короче минимума — подсчёт по каталогу', (tester) async {
    for (final String? q in <String?>[null, 'а']) {
      final CatalogHarness h = _harness();
      setWindow(tester, kCompact);
      await tester.pumpWidget(
        catalogApp(
          h,
          home: CatalogFiltersScreen(key: ValueKey<String?>(q), q: q),
        ),
      );
      await settle(tester);
      expect(h.search.calls, isEmpty, reason: 'q=$q');
      expect(h.catalog.productCalls.single.limit, 1);
      expect(_apply(tester).label, 'Показать 500 товаров');
    }
  });

  testWidgets('офлайн: подсчёт по кэшу поиска (UI-13-015)', (tester) async {
    final _OfflineSearch search = _OfflineSearch();
    final CatalogHarness h = CatalogHarness(search: search);
    setWindow(tester, kCompact);
    await tester.pumpWidget(catalogApp(h, home: const CatalogFiltersScreen(q: 'смеситель')));
    await settle(tester);
    expect(search.cachedCalls.single.q, 'смеситель');
    expect(h.catalog.productCalls, isEmpty);
  });

  testWidgets('SCR-11 compact: «Фильтры» открывает лист с q текущего поиска', (tester) async {
    final CatalogHarness h = _harness(total: 12);
    setWindow(tester, kCompact);
    await tester.pumpWidget(catalogApp(h, home: const CatalogSearchScreen(q: 'смеситель')));
    await settle(tester);
    final int before = h.search.calls.length;
    await tester.tap(find.byKey(const ValueKey<String>('catalog-filters-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('stub-SCR-13')), findsOneWidget);
    final SearchQuery count = h.search.calls.sublist(before).singleWhere((SearchQuery c) => c.limit == 1);
    expect(count.q, 'смеситель');
    expect(_apply(tester).label, 'Показать 12 товаров');
  });
}

/// Поиск без сети: сервер — `NetworkFailure`, кэш отвечает.
final class _OfflineSearch extends FakeSearchRepository {
  final List<SearchQuery> cachedCalls = <SearchQuery>[];

  @override
  Future<Result<SearchResult>> searchProducts(SearchQuery query) async => const FailureResult<SearchResult>(kOffline);

  @override
  Future<Result<SearchResult>> searchCached(SearchQuery query) async {
    cachedCalls.add(query);
    return super.searchCached(query);
  }
}

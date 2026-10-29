// Паритет функций после переноса прототипа 2026-10-29 (требование пользователя 2026-10-29, ADR-112 «Уточнение —
// паритет функций, раунд 1»): возможности HEAD, которые перенос убрал или урезал, возвращены в стиле прототипа, а
// возможности прототипа работают на настоящих данных:
// - колонка категорий сворачивается до 72 кнопкой внизу и разворачивается; выбор — настройка пользователя
//   `sidebarCollapsed` (читается при старте); свёрнутые плитки — иконки с тултипами;
// - число товаров видно на плитках колонки и карточках ленты, «★ Избранное N» — число избранного;
// - «Недавние» в колонке: миниатюры (тап — SCR-14) и «Очистить» с подтверждением;
// - встроенная панель фильтров: склад корзины по умолчанию с пометкой, бренд с 0 товаров недоступен, «Сбросить
//   фильтры» снимает и «Новые» — включённые кнопкой, из сохранённой настройки и из ссылки `?sort=updatedAt:desc`
//   (раунд 2);
// - SCR-11: «Избранные» в строке управления — фильтр `favorite=true` поиска.
// Данные синтетические (фейки), без сети.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/toolbar_toggle_button.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_search_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/category_screen.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_sidebar.dart';

import 'support/catalog_fakes.dart';

GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: <RouteBase>[
    GoRoute(
      path: '/catalog',
      builder: (BuildContext c, GoRouterState s) => CatalogScreen(
        preset: s.uri.queryParameters['preset'],
        view: s.uri.queryParameters['view'],
        sort: s.uri.queryParameters['sort'],
      ),
      routes: <RouteBase>[
        GoRoute(
          path: 'c/:categoryId',
          builder: (BuildContext c, GoRouterState s) => CategoryScreen(
            categoryId: s.pathParameters['categoryId']!,
            view: s.uri.queryParameters['view'],
            sort: s.uri.queryParameters['sort'],
            f: s.uri.queryParameters['f'],
          ),
        ),
        GoRoute(
          path: 'search',
          builder: (BuildContext c, GoRouterState s) =>
              CatalogSearchScreen(q: s.uri.queryParameters['q'], categoryId: s.uri.queryParameters['categoryId']),
        ),
        GoRoute(
          path: 'p/:productId',
          builder: (BuildContext c, GoRouterState s) =>
              Scaffold(body: Text('product ${s.pathParameters['productId']}')),
        ),
      ],
    ),
    GoRoute(
      path: '/favorites',
      builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text('favorites')),
    ),
  ],
);

Future<GoRouter> _pump(WidgetTester tester, CatalogHarness h, String initial, {Size size = kExpanded}) async {
  setWindow(tester, size);
  final GoRouter router = _router(initial);
  addTearDown(router.dispose);
  await tester.pumpWidget(catalogApp(h, router: router));
  await settle(tester);
  return router;
}

/// Текст пилюли числа товаров плитки [tileKey] (`null` — пилюли нет).
String? _count(WidgetTester tester, String tileKey) {
  final Finder pill = find.descendant(
    of: find.byKey(ValueKey<String>(tileKey)),
    matching: find.byKey(const ValueKey<String>('category-tile-count')),
  );
  if (pill.evaluate().isEmpty) {
    return null;
  }
  return tester.widget<Text>(find.descendant(of: pill, matching: find.byType(Text))).data;
}

void main() {
  testWidgets('колонка категорий: «Свернуть каталог» → 72 (иконки с тултипами), настройка сохраняется и читается при '
      'старте; «Развернуть каталог» → 132', (tester) async {
    final FakeShelfPort shelf = FakeShelfPort();
    addTearDown(shelf.dispose);
    final InMemoryCatalogPrefs prefs = InMemoryCatalogPrefs();
    await _pump(tester, CatalogHarness(shelf: shelf, prefs: prefs), '/catalog/c/c-mix');
    final Finder sidebar = find.byType(CatalogSidebar);
    expect(tester.getSize(sidebar).width, DsBreakpoints.catalogColumn);
    expect(find.byTooltip('Свернуть каталог'), findsOneWidget);

    await tester.tap(find.byKey(CatalogSidebar.toggleKey));
    await settle(tester);
    expect(tester.getSize(sidebar).width, DsBreakpoints.sidebarCollapsed);
    expect(await prefs.sidebarCollapsed(), isTrue, reason: 'выбор — настройка пользователя');
    expect(find.byKey(const ValueKey<String>('sidebar-title')), findsNothing);
    expect(
      tester.widget<CategoryTile>(find.byKey(const ValueKey<String>('sidebar-category-c-mix'))).showLabel,
      isFalse,
      reason: 'свёрнутая — только иконка',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('sidebar-category-c-mix')),
        matching: find.byType(AppTooltip),
      ),
      findsOneWidget,
      reason: 'название и число товаров — в тултипе',
    );
    expect(_count(tester, 'sidebar-category-c-mix'), isNull, reason: 'пилюли нет — число в тултипе');
    expect(find.bySemanticsLabel(RegExp('^Смесители, 124')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('sidebar-favorites')), findsOneWidget, reason: '«★ Избранное» иконкой');

    // Новый экран читает сохранённую настройку: колонка сразу свёрнута.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, CatalogHarness(shelf: shelf, prefs: prefs), '/catalog/c/c-mix');
    expect(tester.getSize(find.byType(CatalogSidebar)).width, DsBreakpoints.sidebarCollapsed);
    expect(find.byTooltip('Развернуть каталог'), findsOneWidget);
    await tester.tap(find.byKey(CatalogSidebar.toggleKey));
    await settle(tester);
    expect(tester.getSize(find.byType(CatalogSidebar)).width, DsBreakpoints.catalogColumn);
    expect(await prefs.sidebarCollapsed(), isFalse);
  });

  testWidgets('medium: колонка категорий тоже сворачивается', (tester) async {
    final InMemoryCatalogPrefs prefs = InMemoryCatalogPrefs();
    await _pump(tester, CatalogHarness(prefs: prefs), '/catalog', size: kMedium);
    await tester.tap(find.byKey(CatalogSidebar.toggleKey));
    await settle(tester);
    expect(tester.getSize(find.byType(CatalogSidebar)).width, DsBreakpoints.sidebarCollapsed);
    expect(tester.takeException(), isNull);
  });

  testWidgets('число товаров: пилюли на плитках колонки и карточках ленты (данные дерева), «★ Избранное N»', (
    tester,
  ) async {
    final FakeShelfPort shelf = FakeShelfPort(favorites: <String>{'p1', 'p2'});
    addTearDown(shelf.dispose);
    await _pump(tester, CatalogHarness(shelf: shelf), '/catalog/c/c-mix');
    expect(_count(tester, 'sidebar-category-c-mix'), '124');
    expect(_count(tester, 'sidebar-category-c-sanitary'), '56');
    expect(_count(tester, 'sidebar-favorites'), '2', reason: 'число избранных товаров пользователя');
    expect(_count(tester, 'chip-sub-all'), '124', reason: '«Все товары» — число товаров раздела');
    expect(_count(tester, 'chip-sub-c-mix-kitchen'), '48');
    expect(_count(tester, 'chip-sub-c-mix-bath'), '76');
  });

  testWidgets('«Недавние» в колонке: миниатюры последних товаров (тап — SCR-14), «Очистить» → подтверждение → '
      'порт clearRecent', (tester) async {
    final FakeShelfPort shelf = FakeShelfPort(
      recent: <RecentProduct>[
        RecentProduct(product: product(7), viewedAt: kNow),
        RecentProduct(product: product(8), viewedAt: kNow),
      ],
    );
    addTearDown(shelf.dispose);
    final GoRouter router = await _pump(tester, CatalogHarness(shelf: shelf), '/catalog');
    final Finder block = find.byKey(const ValueKey<String>('sidebar-recent'));
    expect(block, findsOneWidget);
    expect(find.descendant(of: block, matching: find.text('Недавние')), findsOneWidget);
    expect(find.byTooltip(product(7).name), findsOneWidget, reason: 'название — в тултипе');
    await tester.tap(find.byKey(const ValueKey<String>('sidebar-recent-p7')));
    await settle(tester);
    expect(find.text('product p7'), findsOneWidget);
    router.pop();
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey<String>('sidebar-recent-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Очистить недавние товары?'), findsOneWidget);
    await tester.tap(find.text('Очистить').last);
    await tester.pumpAndSettle();
    expect(shelf.clearCalls, 1);
    expect(find.byKey(const ValueKey<String>('sidebar-recent')), findsNothing, reason: 'пусто — блока нет');
  });

  testWidgets('встроенные фильтры: склад корзины по умолчанию — с пометкой; бренд с 0 товаров недоступен', (
    tester,
  ) async {
    final FakeCatalogRepository repo = FakeCatalogRepository();
    repo.networkPages.add(
      Success<CatalogPage<ProductSummary>>(
        page(
          products(3),
          facets: const CatalogFacets(
            brands: <FacetValue>[
              FacetValue(value: 'Frap', count: 3),
              FacetValue(value: 'Пусто', count: 0),
            ],
          ),
        ),
      ),
    );
    await _pump(tester, CatalogHarness(catalog: repo), '/catalog/c/c-mix');
    await tester.tap(find.byKey(const ValueKey<String>('catalog-filters-button')));
    await settle(tester);
    final AppDropdown<String?> warehouse = tester.widget<AppDropdown<String?>>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('filter-section-warehouse')),
        matching: find.byType(AppDropdown<String?>),
      ),
    );
    expect(warehouse.items.map((AppDropdownItem<String?> i) => i.label), <String>[
      'склад корзины',
      'Основной · склад корзины',
      'Склад №2',
    ]);
    expect(tester.widget<AppCheckbox>(find.byKey(const ValueKey<String>('filter-brand-Frap'))).onChanged, isNotNull);
    expect(
      tester.widget<AppCheckbox>(find.byKey(const ValueKey<String>('filter-brand-Пусто'))).onChanged,
      isNull,
      reason: 'бренд без товаров не отмечается (пустой результат)',
    );
  });

  testWidgets('«Сбросить фильтры» снимает и «Новые» — сортировка возвращается к прежней', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository(items: products(3));
    await _pump(tester, CatalogHarness(catalog: repo), '/catalog/c/c-mix');
    final CatalogSort before = repo.productCalls.last.sort!;
    expect(before, isNot(CatalogSort.updatedAtDesc));
    await tester.tap(find.byKey(const ValueKey<String>('chip-preset-newest')));
    await settle(tester);
    expect(repo.productCalls.last.sort, CatalogSort.updatedAtDesc);
    await tester.tap(find.byKey(const ValueKey<String>('catalog-filters-button')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('catalog-filters-reset')));
    await settle(tester);
    expect(repo.productCalls.last.sort, before, reason: 'прототип: resetFilters снимает и «Новые»');
  });

  // «Новые» подсвечены при любом источнике сортировки updatedAt:desc — сброс снимает их и тогда (паритет, раунд 2).
  bool newestSelected(WidgetTester tester) =>
      tester.widget<ToolbarToggleButton>(find.byKey(const ValueKey<String>('chip-preset-newest'))).selected;

  Future<void> resetFilters(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('catalog-filters-button')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('catalog-filters-reset')));
    await settle(tester);
  }

  testWidgets('«Сбросить фильтры» снимает «Новые» из сохранённой настройки sort = updatedAt:desc → по названию А–Я', (
    tester,
  ) async {
    final FakeCatalogRepository repo = FakeCatalogRepository(items: products(3));
    final InMemoryCatalogPrefs prefs = InMemoryCatalogPrefs();
    await prefs.setSort(CatalogSort.updatedAtDesc, search: false);
    await _pump(tester, CatalogHarness(catalog: repo, prefs: prefs), '/catalog/c/c-mix');
    expect(repo.productCalls.last.sort, CatalogSort.updatedAtDesc);
    expect(
      newestSelected(tester),
      isTrue,
      reason: '«Новые» подсвечены по настройке (кнопку в этом экземпляре не жали)',
    );
    await resetFilters(tester);
    expect(repo.productCalls.last.sort, CatalogDefaults.catalogSort);
    expect(newestSelected(tester), isFalse);
    expect(await prefs.sort(search: false), CatalogDefaults.catalogSort, reason: 'настройка тоже сброшена');
  });

  testWidgets('«Сбросить фильтры» снимает «Новые» из ссылки ?sort=updatedAt:desc → по названию А–Я', (tester) async {
    final FakeCatalogRepository repo = FakeCatalogRepository(items: products(3));
    final GoRouter router = await _pump(tester, CatalogHarness(catalog: repo), '/catalog/c/c-mix?sort=updatedAt:desc');
    expect(repo.productCalls.last.sort, CatalogSort.updatedAtDesc);
    expect(newestSelected(tester), isTrue);
    await resetFilters(tester);
    expect(repo.productCalls.last.sort, CatalogDefaults.catalogSort);
    expect(newestSelected(tester), isFalse);
    expect(router.routerDelegate.currentConfiguration.uri.queryParameters['sort'], isNot('updatedAt:desc'));
  });

  testWidgets('SCR-11: «Избранные» в строке управления — фильтр favorite=true поиска; повтор снимает', (tester) async {
    final FakeShelfPort shelf = FakeShelfPort();
    addTearDown(shelf.dispose);
    final FakeSearchRepository search = FakeSearchRepository();
    await _pump(tester, CatalogHarness(shelf: shelf, search: search), '/catalog/search?q=смеситель');
    expect(search.calls, isNotEmpty);
    expect(search.calls.last.filter.favorite, isNot(true));
    final Finder favorites = find.byKey(const ValueKey<String>('chip-preset-favorites'));
    expect(favorites, findsOneWidget);
    await tester.tap(favorites);
    await settle(tester);
    expect(search.calls.last.q, 'смеситель');
    expect(search.calls.last.filter.favorite, isTrue);
    await tester.tap(favorites);
    await settle(tester);
    expect(search.calls.last.filter.favorite, isNot(true));
    expect(find.byKey(const ValueKey<String>('chip-preset-newest')), findsNothing, reason: 'поиск без updatedAt');
  });
}

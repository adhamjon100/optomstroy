// Паритет функций после переноса прототипа 2026-10-29 (требование пользователя 2026-10-29, ADR-112 «Уточнение —
// паритет функций, раунд 1»): возможности HEAD, которые перенос убрал или урезал, возвращены в стиле прототипа, а
// возможности прототипа работают на настоящих данных:
// - колонка категорий сворачивается до 72 значком «‹‹» строки заголовка «Каталог» и разворачивается «››» сверху
//   свёрнутой (ADR-114); выбор — настройка пользователя `sidebarCollapsed` (читается при старте); свёрнутые плитки —
//   иконки с тултипами;
// - число товаров — в подсказке и Semantics плиток колонки и карточек ленты (пилюль нет, ADR-114), число избранного —
//   у кнопки «Избранные» строки управления (прежняя плитка «★ Избранное N» колонки) и в drawer навигации;
// - «Недавние» — подборка строки управления (прежний блок колонки): товары (тап — SCR-14) и «Очистить» с
//   подтверждением;
// - встроенная панель фильтров: склад корзины по умолчанию с пометкой, бренд с 0 товаров недоступен, «Сбросить
//   фильтры» снимает и «Новые» — включённые кнопкой, из сохранённой настройки и из ссылки `?sort=updatedAt:desc`
//   (раунд 2);
// - SCR-11: «Избранные» в строке управления — фильтр `favorite=true` поиска;
// - ревью второго круга: «Каталог» в колонке 132 открывает «Все товары» (R2C-06), «Все товары» в свёрнутой колонке
//   (PAR-05), пустые «Недавние» в категории — свой текст и «Все недавние» (PAR-04), ссылки `link` (V-03), заголовок
//   поиска после очистки поля (V-04, PAR-02, R2C-02), F2 / Ctrl+F без фокуса внутри экрана (PAR-03).
// Данные синтетические (фейки), без сети.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/toolbar_toggle_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_search_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/category_screen.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_filter_form.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_sidebar.dart';

import '../../../design_system/ds_test_support.dart' show loadInterFont;

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

/// Текст пилюли числа товаров плитки [tileKey] (`null` — пилюли нет; ADR-114 — у плиток и карточек ленты её нет).
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
  testWidgets('колонка категорий: «‹‹» в строке «Каталог» → 72 (иконки с тултипами, «››» сверху), настройка '
      'сохраняется и читается при старте; «››» → 144 (T-CAT-039)', (tester) async {
    await tester.runAsync(loadInterFont);
    final FakeShelfPort shelf = FakeShelfPort();
    addTearDown(shelf.dispose);
    final InMemoryCatalogPrefs prefs = InMemoryCatalogPrefs();
    CatalogHarness harness() => CatalogHarness(
      shelf: shelf,
      prefs: prefs,
      catalog: FakeCatalogRepository(items: products(3), tree: designCategoryTree()),
    );
    await _pump(tester, harness(), '/catalog/c/plumbing', size: const Size(1440, 900));
    final Finder sidebar = find.byType(CatalogSidebar);
    expect(tester.getSize(sidebar).width, 144);
    expect(find.byTooltip('Свернуть каталог'), findsOneWidget);
    // «‹‹» — в строке заголовка «Каталог», у правого края колонки (цель 48).
    final Rect toggle = tester.getRect(find.byKey(CatalogSidebar.toggleKey));
    final Rect title = tester.getRect(find.byKey(const ValueKey<String>('sidebar-title')));
    expect(toggle.size, const Size(48, 48));
    expect(toggle.center.dy, closeTo(title.center.dy, 1), reason: 'одна строка с «Каталог»');
    expect(toggle.right, lessThanOrEqualTo(tester.getRect(sidebar).right), reason: 'цель 48 — внутри колонки');
    expect(toggle.right, greaterThan(tester.getRect(sidebar).right - 24), reason: 'у правого края колонки');
    expect(toggle.top, lessThan(tester.getTopLeft(find.byKey(const ValueKey<String>('sidebar-category-heating'))).dy));

    await tester.tap(find.byKey(CatalogSidebar.toggleKey));
    await settle(tester);
    expect(tester.getSize(sidebar).width, DsBreakpoints.sidebarCollapsed);
    expect(await prefs.sidebarCollapsed(), isTrue, reason: 'выбор — настройка пользователя');
    expect(find.byKey(const ValueKey<String>('sidebar-title')), findsNothing);
    expect(
      tester.widget<CategoryTile>(find.byKey(const ValueKey<String>('sidebar-category-plumbing'))).showLabel,
      isFalse,
      reason: 'свёрнутая — только иконка',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('sidebar-category-plumbing')),
        matching: find.byType(AppTooltip),
      ),
      findsOneWidget,
      reason: 'название и число товаров — в тултипе',
    );
    expect(_count(tester, 'sidebar-category-plumbing'), isNull, reason: 'пилюли нет — число в тултипе');
    expect(find.bySemanticsLabel(RegExp('^Сантехника, 12')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('sidebar-favorites')), findsNothing, reason: 'ADR-114: только категории');
    // «››» — сверху свёрнутой колонки, над первой плиткой.
    expect(
      tester.getRect(find.byKey(CatalogSidebar.toggleKey)).bottom,
      lessThanOrEqualTo(tester.getTopLeft(find.byKey(const ValueKey<String>('sidebar-category-heating'))).dy),
    );

    // Новый экран читает сохранённую настройку: колонка сразу свёрнута.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, harness(), '/catalog/c/plumbing', size: const Size(1440, 900));
    expect(tester.getSize(find.byType(CatalogSidebar)).width, DsBreakpoints.sidebarCollapsed);
    expect(find.byTooltip('Развернуть каталог'), findsOneWidget);
    await tester.tap(find.byKey(CatalogSidebar.toggleKey));
    await settle(tester);
    expect(tester.getSize(find.byType(CatalogSidebar)).width, 144);
    expect(await prefs.sidebarCollapsed(), isFalse);
  });

  testWidgets('medium: колонка категорий тоже сворачивается значком строки «Каталог»', (tester) async {
    final InMemoryCatalogPrefs prefs = InMemoryCatalogPrefs();
    await _pump(tester, CatalogHarness(prefs: prefs), '/catalog', size: kMedium);
    expect(
      tester.getRect(find.byKey(CatalogSidebar.toggleKey)).center.dy,
      closeTo(tester.getRect(find.byKey(const ValueKey<String>('sidebar-title'))).center.dy, 1),
    );
    await tester.tap(find.byKey(CatalogSidebar.toggleKey));
    await settle(tester);
    expect(tester.getSize(find.byType(CatalogSidebar)).width, DsBreakpoints.sidebarCollapsed);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'число товаров: в подсказке и Semantics плиток колонки и карточек ленты (данные дерева), без пилюль; число '
    'избранных — у «Избранные» (ADR-114)',
    (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final FakeShelfPort shelf = FakeShelfPort(favorites: <String>{'p1', 'p2'});
      addTearDown(shelf.dispose);
      await _pump(tester, CatalogHarness(shelf: shelf), '/catalog/c/c-mix');
      for (final String key in <String>[
        'sidebar-category-c-mix',
        'sidebar-category-c-sanitary',
        'chip-sub-all',
        'chip-sub-c-mix-kitchen',
      ]) {
        expect(_count(tester, key), isNull, reason: '$key: пилюли нет (прототип)');
      }
      expect(find.byKey(const ValueKey<String>('category-tile-count')), findsNothing);
      // Плитки колонки: «{название}, N товаров» — подсказка и Semantics.
      expect(find.byTooltip('Смесители, 124 товара'), findsOneWidget);
      expect(find.bySemanticsLabel('Смесители, 124 товара'), findsOneWidget);
      expect(find.bySemanticsLabel('Санфаянс, 56 товаров'), findsOneWidget);
      // Лента: «Все товары» — число раздела (видимая подпись входит в имя, WCAG 2.5.3), подкатегории — свои.
      expect(find.bySemanticsLabel('Все товары: Смесители, 124 товара'), findsOneWidget);
      expect(find.bySemanticsLabel('Для кухни, 48 товаров'), findsOneWidget);
      expect(find.bySemanticsLabel('Для ванной, 76 товаров'), findsOneWidget);
      // «★ Избранное N» колонки → «Избранные» строки управления: число в подсказке и Semantics.
      expect(find.byKey(const ValueKey<String>('sidebar-favorites')), findsNothing);
      final ToolbarToggleButton favorites = tester.widget<ToolbarToggleButton>(
        find.byKey(const ValueKey<String>('chip-preset-favorites')),
      );
      expect(favorites.tooltip, 'Избранные, 2 товара');
      expect(find.bySemanticsLabel('Избранные, 2 товара'), findsOneWidget);
      // Снятие звезды — число обновляется.
      await shelf.setFavorite('p2', favorite: false);
      await settle(tester);
      expect(find.bySemanticsLabel('Избранные, 1 товар'), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets('«Недавние» — подборка строки управления (прежний блок колонки): последние товары (тап — SCR-14), '
      '«Очистить» → подтверждение → порт clearRecent', (tester) async {
    final FakeShelfPort shelf = FakeShelfPort(
      recent: <RecentProduct>[
        RecentProduct(product: product(7), viewedAt: kNow),
        RecentProduct(product: product(8), viewedAt: kNow),
      ],
    );
    addTearDown(shelf.dispose);
    final GoRouter router = await _pump(tester, CatalogHarness(shelf: shelf), '/catalog');
    expect(find.byKey(const ValueKey<String>('sidebar-recent')), findsNothing, reason: 'ADR-114: колонка — категории');
    final Finder recent = find.byKey(const ValueKey<String>('chip-preset-recent'));
    expect(tester.widget<ToolbarToggleButton>(recent).label, 'Недавние');
    await tester.tap(recent);
    await settle(tester);
    expect(tester.widget<ToolbarToggleButton>(recent).selected, isTrue);
    expect(find.text('Недавние товары'), findsOneWidget, reason: 'заголовок подборки');
    expect(find.byKey(const ValueKey<String>('product-p7')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('product-p8')), findsOneWidget);
    await tester.tap(find.text(product(7).name));
    await settle(tester);
    expect(find.text('product p7'), findsOneWidget, reason: 'тап — карточка товара SCR-14');
    router.pop();
    // Переход назад (300 мс) — до конца, иначе уходящая страница перекрывает кнопку.
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(
      tester.widget<ToolbarToggleButton>(recent).selected,
      isTrue,
      reason: 'подборка сохранилась (?preset=recent)',
    );

    await tester.tap(find.byKey(const ValueKey<String>('catalog-recent-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Очистить недавние товары?'), findsOneWidget);
    await tester.tap(find.text('Очистить').last);
    await tester.pumpAndSettle();
    expect(shelf.clearCalls, 1);
    expect(find.byKey(const ValueKey<String>('product-p7')), findsNothing, reason: 'подборка пуста');
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
    // Флажки панели — по прототипу (CatalogFilterCheck, ADR-114 / RV-14); все фильтры приложения сохранены.
    expect(
      tester.widget<CatalogFilterCheck>(find.byKey(const ValueKey<String>('filter-brand-Frap'))).onChanged,
      isNotNull,
    );
    expect(
      tester.widget<CatalogFilterCheck>(find.byKey(const ValueKey<String>('filter-brand-Пусто'))).onChanged,
      isNull,
      reason: 'бренд без товаров не отмечается (пустой результат)',
    );
    final SemanticsHandle semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.byKey(const ValueKey<String>('filter-brand-Пусто'))),
      containsSemantics(label: 'Пусто (0)', hasEnabledState: true, isEnabled: false, hasCheckedState: true),
    );
    semantics.dispose();
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

  // ---------------------------------------------------------------- ревью второго круга (fix2)

  testWidgets('«Каталог» в колонке 132 (короткие названия): нажатие на конец слова открывает «Все товары», а не '
      'сворачивает колонку — цель заголовка поверх цели «‹‹» (ревью R2C-06)', (tester) async {
    await tester.runAsync(loadInterFont);
    final InMemoryCatalogPrefs prefs = InMemoryCatalogPrefs();
    final GoRouter router = await _pump(tester, CatalogHarness(prefs: prefs), '/catalog/c/c-mix', size: kMedium);
    expect(tester.getSize(find.byType(CatalogSidebar)).width, 132);
    final Rect title = tester.getRect(find.byKey(const ValueKey<String>('sidebar-title')));
    final Rect toggle = tester.getRect(find.byKey(CatalogSidebar.toggleKey));
    expect(toggle.left, lessThan(title.right), reason: 'цель «‹‹» 48 заходит на конец текста');
    // Правее текста — «‹‹»: колонка сворачивается и разворачивается.
    await tester.tapAt(Offset(toggle.right - 6, toggle.center.dy));
    await settle(tester);
    expect(tester.getSize(find.byType(CatalogSidebar)).width, DsBreakpoints.sidebarCollapsed);
    await tester.tap(find.byKey(CatalogSidebar.toggleKey));
    await settle(tester);
    expect(tester.getSize(find.byType(CatalogSidebar)).width, 132);
    // Конец слова «Каталог» (над целью «‹‹») — «Все товары», колонка не сворачивается.
    await tester.tapAt(Offset(title.right - 3, title.center.dy));
    await settle(tester);
    expect(router.routeInformationProvider.value.uri.queryParameters['all'], '1', reason: '«Все товары»');
    expect(await prefs.sidebarCollapsed(), isFalse, reason: 'колонка не свернулась');
  });

  testWidgets('свёрнутая колонка 72: «Все товары» — значком под «››» (ревью PAR-05)', (tester) async {
    final InMemoryCatalogPrefs prefs = InMemoryCatalogPrefs();
    await prefs.setSidebarCollapsed(true);
    final GoRouter router = await _pump(tester, CatalogHarness(prefs: prefs), '/catalog/c/c-mix');
    expect(tester.getSize(find.byType(CatalogSidebar)).width, DsBreakpoints.sidebarCollapsed);
    final Finder all = find.byKey(CatalogSidebar.allKey);
    expect(all, findsOneWidget);
    expect(find.byTooltip('Каталог — все товары'), findsOneWidget);
    expect(tester.getRect(all).top, greaterThanOrEqualTo(tester.getRect(find.byKey(CatalogSidebar.toggleKey)).bottom));
    expect(
      tester.getRect(all).bottom,
      lessThanOrEqualTo(tester.getTopLeft(find.byKey(const ValueKey<String>('sidebar-category-c-mix'))).dy),
    );
    await tester.tap(all);
    await settle(tester);
    expect(router.routeInformationProvider.value.uri.queryParameters['all'], '1');
  });

  testWidgets('«Недавние» в категории без её недавних: свой текст и «Все недавние» → весь список (ревью PAR-04)', (
    tester,
  ) async {
    final FakeShelfPort shelf = FakeShelfPort(
      recent: <RecentProduct>[RecentProduct(product: product(7), viewedAt: kNow)],
    );
    addTearDown(shelf.dispose);
    final GoRouter router = await _pump(tester, CatalogHarness(shelf: shelf), '/catalog/c/c-sanitary');
    await tester.tap(find.byKey(const ValueKey<String>('chip-preset-recent')));
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('product-p7')), findsNothing, reason: 'p7 — из «Смесителей» (UI-12-007)');
    expect(find.text('В этой категории вы ещё не открывали товары'), findsOneWidget);
    expect(find.text('Здесь появятся товары, которые вы открывали'), findsOneWidget);
    expect(find.text('В этой категории пока нет товаров'), findsNothing, reason: 'не текст пустой категории');
    await tester.tap(find.text('Все недавние'));
    await settle(tester);
    final Uri uri = router.routeInformationProvider.value.uri;
    expect(uri.path, '/catalog');
    expect(uri.queryParameters, containsPair('preset', 'recent'));
    expect(uri.queryParameters, containsPair('all', '1'));
    expect(find.byKey(const ValueKey<String>('product-p7')), findsOneWidget, reason: 'все недавние');
  });

  testWidgets('«Сбросить все» строки активных фильтров и «Очистить» «Недавних» — ссылки `link` 14/500 (ревью V-03)', (
    tester,
  ) async {
    final FakeShelfPort shelf = FakeShelfPort(
      favorites: <String>{'p1'},
      recent: <RecentProduct>[RecentProduct(product: product(7), viewedAt: kNow)],
    );
    addTearDown(shelf.dispose);
    await _pump(tester, CatalogHarness(shelf: shelf), '/catalog/c/c-mix');
    await tester.tap(find.byKey(const ValueKey<String>('chip-preset-favorites')));
    await settle(tester);
    Color colorOf(String key) => tester
        .widget<Text>(find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(Text)))
        .style!
        .color!;
    final BuildContext ctx = tester.element(find.byType(CatalogSidebar));
    expect(find.byKey(const ValueKey<String>('active-filters-reset')), findsOneWidget);
    expect(colorOf('active-filters-reset'), ctx.colors.link);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey<String>('active-filters-reset')),
              matching: find.byType(Text),
            ),
          )
          .style!
          .fontWeight,
      FontWeight.w500,
    );
    await tester.tap(find.byKey(const ValueKey<String>('chip-preset-recent')));
    await settle(tester);
    expect(colorOf('catalog-recent-clear'), ctx.colors.link);
  });

  testWidgets('поиск: поле очищено (× / Esc / короче 2 символов) — заголовок «Результаты поиска», а не прежний '
      'запрос (ревью V-04, PAR-02, R2C-02)', (tester) async {
    await _pump(tester, CatalogHarness(), '/catalog/search?q=90');
    String? title() => tester.widget<Text>(find.byKey(const ValueKey<String>('catalog-title'))).data;
    final Finder field = find.descendant(
      of: find.byKey(const ValueKey<String>('catalog-search-field')),
      matching: find.byType(EditableText),
    );
    expect(title(), 'Поиск: «90»');
    await tester.enterText(field, 'с');
    await settle(tester);
    expect(title(), 'Результаты поиска', reason: 'короче 2 символов (буква)');
    await tester.enterText(field, '');
    await settle(tester);
    expect(title(), 'Результаты поиска', reason: 'поле пусто');
    await tester.enterText(field, '42');
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    expect(title(), 'Поиск: «42»', reason: 'новый запрос');
  });

  testWidgets('F2 / Ctrl+F без фокуса внутри экрана (веб после входа и разблокировки) — фокус в поле поиска (ревью '
      'PAR-03)', (tester) async {
    await _pump(tester, CatalogHarness(), '/catalog/c/c-mix');
    final EditableText field = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('catalog-search-field')),
        matching: find.byType(EditableText),
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus(disposition: UnfocusDisposition.scope);
    await tester.pump();
    expect(field.focusNode.hasFocus, isFalse);
    expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>(), reason: 'фокус — у области, не у элемента');
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    expect(field.focusNode.hasFocus, isTrue, reason: 'F2');
    FocusManager.instance.primaryFocus?.unfocus(disposition: UnfocusDisposition.scope);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(field.focusNode.hasFocus, isTrue, reason: 'Ctrl+F');
  });
}

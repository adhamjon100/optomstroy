// T-CAT-003, T-CAT-004 (widget): SCR-12 «Категория» и переходы SCR-10/11/12/14 (RM-E-007).
// Подкатегории — только при наличии (AC-UI-12-001); лента — всегда, у корня без детей — только «Все товары», крошки —
// при глубине ≥ 3 (ADR-114; было ≥ 2, AC-UI-12-006),
// удалённая категория (AC-UI-12-007), повторный тап по выбранной — без действия, двойной тап —
// один переход, поиск из шапки SCR-10 → SCR-11 через 300 мс, сохранение вида/сортировки в URL.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_filters_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_search_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/category_screen.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_toolbar.dart';

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
          path: 'search',
          builder: (BuildContext c, GoRouterState s) => CatalogSearchScreen(
            q: s.uri.queryParameters['q'],
            categoryId: s.uri.queryParameters['categoryId'],
            view: s.uri.queryParameters['view'],
            sort: s.uri.queryParameters['sort'],
          ),
        ),
        GoRoute(
          path: 'filters',
          builder: (BuildContext c, GoRouterState s) => CatalogFiltersScreen(f: s.uri.queryParameters['f']),
        ),
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
          path: 'p/:productId',
          builder: (BuildContext c, GoRouterState s) =>
              Scaffold(body: Text('product ${s.pathParameters['productId']} ${s.uri.queryParameters['variantId']}')),
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

String _location(GoRouter r) => r.routeInformationProvider.value.uri.toString();

void main() {
  testWidgets('категория с подкатегориями: лента «Все» + дети, корень выбран в колонке; корень без детей — лента «Все '
      'товары» и подборки (ADR-114)', (tester) async {
    final CatalogHarness h = CatalogHarness();
    final GoRouter router = await _pump(tester, h, '/catalog/c/c-mix');
    expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('catalog-title')), findsOneWidget);
    expect(find.text('Найдено: 6 товаров'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('chip-sub-all')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('chip-sub-c-mix-kitchen')), findsOneWidget);
    // Подкатегории — в ленте над списком, колонка показывает только корни (макет заказчика, CQ-LAY-02).
    expect(find.byKey(const ValueKey<String>('sidebar-category-c-mix-kitchen')), findsNothing);
    expect(find.byKey(const ValueKey<String>('sidebar-category-c-mix')), findsOneWidget);
    final CatalogQuery q = h.catalog.productCalls.singleWhere((CatalogQuery q) => q.filter.categoryId == 'c-mix');
    expect(q.filter.includeSubcategories, isTrue);

    router.go('/catalog/c/c-sanitary');
    await settle(tester);
    // ADR-114 (02 П.3 п. 1): лента в режиме категории — всегда; у корня без детей — одна выбранная «Все товары».
    expect(find.byKey(const ValueKey<String>('catalog-subcategory-ribbon')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('chip-sub-all')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('chip-sub-c-mix-kitchen')), findsNothing);
    expect(tester.widget<CategoryTile>(find.byKey(const ValueKey<String>('chip-sub-all'))).selected, isTrue);
    expect(
      find.byKey(const ValueKey<String>('chip-preset-favorites')),
      findsOneWidget,
      reason: 'подборки остаются (C6)',
    );
  });

  testWidgets('лист и узел: подборки «Недавние» и «Избранное» видимы; «Недавние» — в пределах категории (UI-12-007)', (
    tester,
  ) async {
    final FakeShelfPort shelf = FakeShelfPort(
      recent: <RecentProduct>[
        RecentProduct(product: product(1), viewedAt: kNow),
        RecentProduct(
          product: const ProductSummary(id: 'p-cement', name: 'Цемент М500 50 кг', categoryId: 'c-sanitary'),
          viewedAt: kNow,
        ),
      ],
    );
    addTearDown(shelf.dispose);
    final GoRouter router = await _pump(tester, CatalogHarness(shelf: shelf), '/catalog/c/c-sanitary');
    expect(find.byKey(const ValueKey<String>('chip-preset-recent')), findsOneWidget, reason: 'AC-UI-12-001: лист');
    expect(find.byKey(const ValueKey<String>('chip-preset-favorites')), findsOneWidget);

    router.go('/catalog/c/c-mix');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('chip-preset-recent')));
    await settle(tester);
    Finder inList(String text) => find.descendant(of: find.byType(ProductCardGrid), matching: find.text(text));
    expect(inList(product(1).name), findsOneWidget, reason: 'недавний товар этой категории');
    expect(inList('Цемент М500 50 кг'), findsNothing, reason: 'товар другой категории в списке не показывается');
  });

  testWidgets('крошки при глубине ≥ 3 ведут к уровню; на глубине 2 крошек нет — к родителю ведёт «Все товары» ленты '
      '(ADR-114)', (tester) async {
    final CatalogHarness h = CatalogHarness(
      catalog: FakeCatalogRepository(
        items: products(6),
        tree: CategoryTree.fromFlat(const <Category>[
          Category(id: 'c-mix', name: 'Смесители', productCount: 124, hasChildren: true),
          Category(id: 'c-mix-kitchen', parentId: 'c-mix', name: 'Для кухни', productCount: 48, hasChildren: true),
          Category(id: 'c-mix-k-one', parentId: 'c-mix-kitchen', name: 'Однорычажные', productCount: 30),
          Category(id: 'c-mix-k-two', parentId: 'c-mix-kitchen', name: 'Двухвентильные', productCount: 18),
          Category(id: 'c-mix-bath', parentId: 'c-mix', name: 'Для ванной', productCount: 76),
        ]),
      ),
    );
    // Глубина 2: крошек нет; заголовок — родитель ленты, «Все товары» ведёт к нему.
    final GoRouter router = await _pump(tester, h, '/catalog/c/c-mix-bath');
    expect(find.byType(BackButton), findsNothing);
    expect(find.byType(CatalogBreadcrumbs), findsNothing, reason: 'путь видят плитка корня и «Все товары» ленты');
    await tester.tap(find.byKey(const ValueKey<String>('chip-sub-all')));
    await settle(tester);
    expect(_location(router), startsWith('/catalog/c/c-mix'));
    expect(_location(router), isNot(contains('bath')));

    // Глубина 3: крошки «Каталог › Смесители › Для кухни»; уровень — переход, «Каталог» — весь каталог.
    router.go('/catalog/c/c-mix-k-one');
    await settle(tester);
    expect(find.byType(CatalogBreadcrumbs), findsOneWidget);
    expect(find.text('Каталог'), findsWidgets);
    await tester.tap(find.descendant(of: find.byType(CatalogBreadcrumbs), matching: find.text('Смесители')));
    await settle(tester);
    expect(_location(router), startsWith('/catalog/c/c-mix'));
    expect(_location(router), isNot(contains('k-one')));
    router.go('/catalog/c/c-mix-k-two');
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(CatalogBreadcrumbs), matching: find.text('Каталог')));
    await settle(tester);
    expect(_location(router), startsWith('/catalog?all=1'), reason: 'корень крошек — «Все товары»');
  });

  testWidgets('удалённая категория: «Категория больше не существует» → «К каталогу»', (tester) async {
    final GoRouter router = await _pump(tester, CatalogHarness(), '/catalog/c/gone');
    expect(find.byKey(const ValueKey<String>('category-not-found')), findsOneWidget);
    await tester.tap(find.text('К каталогу'));
    await settle(tester);
    expect(_location(router), '/catalog');
  });

  testWidgets('тап по категории в сайдбаре → SCR-12; повторный тап по выбранной — без перехода', (tester) async {
    final GoRouter router = await _pump(tester, CatalogHarness(), '/catalog');
    await tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-sanitary')));
    await settle(tester);
    expect(_location(router), '/catalog/c/c-sanitary');
    await tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-sanitary')).hitTestable());
    await settle(tester);
    expect(_location(router), '/catalog/c/c-sanitary');
    expect(router.routerDelegate.currentConfiguration.matches, hasLength(2), reason: 'без нового перехода');
  });

  testWidgets('карточка → SCR-14 с variantId (push); двойной тап — один переход', (tester) async {
    final GoRouter router = await _pump(tester, CatalogHarness(), '/catalog');
    final Finder card = find.descendant(
      of: find.byKey(const ValueKey<String>('product-p1')),
      matching: find.byType(ProductCardGrid),
    );
    await tester.tap(card);
    await tester.tap(card, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('product p1 v1', skipOffstage: false), findsOneWidget);
    expect(router.routerDelegate.currentConfiguration.matches.last.matchedLocation, '/catalog/p/p1');
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('product p1 v1', skipOffstage: false), findsNothing);
    expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);
  });

  testWidgets('поиск из шапки SCR-10: ≥ 2 символа + 300 мс → /catalog/search?q=', (tester) async {
    final GoRouter router = await _pump(tester, CatalogHarness(), '/catalog');
    final Finder field = find.descendant(
      of: find.byKey(const ValueKey<String>('catalog-search-field')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, 'с');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_location(router), '/catalog');
    await tester.enterText(field, 'см');
    await tester.pump(const Duration(milliseconds: 310));
    await settle(tester);
    expect(_location(router), '/catalog/search?q=%D1%81%D0%BC');
    expect(find.byKey(const ValueKey<String>('stub-SCR-11')), findsOneWidget);
  });

  testWidgets('поиск из SCR-12 → SCR-11 → «Назад» в ту же категорию без q (02 SCR-11.6, AC-UI-11-009)', (tester) async {
    final GoRouter router = await _pump(tester, CatalogHarness(), '/catalog/c/c-sanitary');
    Finder field() => find.descendant(
      of: find.byKey(const ValueKey<String>('catalog-search-field')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field(), 'смеситель');
    await tester.pump(const Duration(milliseconds: 310));
    await settle(tester);
    // SCR-11 открыт поверх SCR-12 (`push`): его состояние маршрута — `/catalog/search?q=…&categoryId=…`.
    Uri searchUri() => GoRouterState.of(tester.element(find.byKey(const ValueKey<String>('stub-SCR-11')))).uri;
    expect(find.byKey(const ValueKey<String>('stub-SCR-11')), findsOneWidget);
    expect(searchUri().path, '/catalog/search');
    expect(searchUri().queryParameters, <String, String>{'q': 'смеситель', 'categoryId': 'c-sanitary'});

    // Уточнение запроса на SCR-11 заменяет запись, а не добавляет: «Назад» — по-прежнему один шаг.
    // Маркер `stub-SCR-11` — невидимый лист внутри экрана (не предок поля): поле SCR-11 — верхняя запись (последнее).
    await tester.enterText(field().last, 'смеситель кух');
    await tester.pump(const Duration(milliseconds: 310));
    await settle(tester);
    expect(searchUri().queryParameters['q'], 'смеситель кух');
    expect(find.byKey(const ValueKey<String>('stub-SCR-11')), findsOneWidget);

    router.pop();
    await settle(tester);
    expect(_location(router), '/catalog/c/c-sanitary');
    expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);
  });

  testWidgets('вид и сортировка отражаются в URL и переносятся в подкатегорию (AC-UI-12-008)', (tester) async {
    final CatalogHarness h = CatalogHarness();
    final GoRouter router = await _pump(tester, h, '/catalog/c/c-mix');
    await tester.tap(find.byKey(const ValueKey<String>('view-mode-list')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('catalog-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('По убыванию цены').last);
    await settle(tester);
    expect(_location(router), contains('view=list'));
    expect(_location(router), contains('sort=price%3Adesc'));
    await tester.tap(find.byKey(const ValueKey<String>('chip-sub-c-mix-kitchen')));
    await tester.pumpAndSettle();
    final CategoryScreen top = tester.widget<CategoryScreen>(find.byType(CategoryScreen).last);
    expect(top.categoryId, 'c-mix-kitchen');
    expect(top.view, 'list');
    expect(top.sort, 'price:desc');
    expect(router.routerDelegate.currentConfiguration.matches.last.matchedLocation, '/catalog/c/c-mix-kitchen');
    expect(h.catalog.productCalls.last.sort, CatalogSort.priceDesc);
    expect(h.catalog.productCalls.last.filter.categoryId, 'c-mix-kitchen');
    expect(find.byType(ProductCardList), findsWidgets);
  });

  testWidgets('compact: «Все категории ›» открывает лист плиток CategoryTile', (tester) async {
    final GoRouter router = await _pump(tester, CatalogHarness(), '/catalog', size: kCompact);
    await tester.tap(find.byKey(const ValueKey<String>('chip-all-categories')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('all-categories-grid')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('category-tile-c-sanitary')));
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.matches.last.matchedLocation, '/catalog/c/c-sanitary');
    expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);
  });
}

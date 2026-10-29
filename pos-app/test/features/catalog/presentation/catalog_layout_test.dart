// Экран выбора товаров по прототипу 2026-10-29 (SCR-10/SCR-12, expanded/medium; ADR-112): колонка плиток корневых
// категорий 132 (и на medium — без полосы корней), лента подкатегорий 118×148 (одинаковые карточки, стрелки ‹ ›
// с подписями ARB, колесо мыши, выбранная в видимой части, картинка категории или нейтральная заглушка — без фото
// товара), строка управления («Новые» — настоящая сортировка `updatedAt:desc`, «Избранные», «Недавние», «Найдено»,
// вид с подписями), сетка (колонки от 176 по ширине области, «+ Добавить» на одной линии, «В корзине · N — ещё +1»,
// повторные нажатия — без лишних добавлений, крупный шрифт без переполнения), «Список» и «Компакт» по прототипу,
// тексты — из ARB. Данные синтетические.
// Тест-кейсы 12_TEST_PLAN: T-CAT-037 (кнопка карточки по состоянию корзины), T-CAT-038 (сетка auto-fill от 176).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/scroll_ribbon.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/components/toolbar_toggle_button.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/category_screen.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_sidebar.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_toolbar.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_workspace.dart';

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

String _location(GoRouter r) => r.routeInformationProvider.value.uri.toString();

/// «Сантехника» с 12 подкатегориями (первая — с картинкой категории из данных), «Отопление» без детей.
CategoryTree _wideTree() => CategoryTree.fromFlat(<Category>[
  const Category(id: 'c-san', name: 'Сантехника', productCount: 120, hasChildren: true),
  // 20 подкатегорий: лента длиннее двух видимых частей и при широкой области без CP (1366 − 132, ADR-112).
  for (int i = 1; i <= 20; i++)
    Category(
      id: 'c-san-$i',
      parentId: 'c-san',
      name: i == 1 ? 'Унитазы' : 'Подкатегория $i',
      productCount: 10,
      sortOrder: i,
      imageUrl: i == 1 ? 'http://img.test/images/cat-1/thumb.webp' : null,
    ),
  const Category(id: 'c-heat', name: 'Отопление', productCount: 30, sortOrder: 1),
]);

double _ribbonOffset(WidgetTester tester) =>
    tester.widget<ListView>(find.byKey(const ValueKey<String>('scroll-ribbon-list'))).controller!.offset;

/// Порт корзины, ответ которого держится до [release] (сеть медленная).
final class _SlowCartPort implements CatalogCartPort {
  final List<String> added = <String>[];
  Completer<Result<void>>? _pending;

  void release() => _pending?.complete(const Success<void>(null));

  @override
  Future<Result<void>> add(ProductSummary product) {
    added.add(product.id);
    _pending = Completer<Result<void>>();
    return _pending!.future;
  }

  @override
  String? rejectionText(Failure failure, AppLocalizations l10n) => null;
}

/// Количества корзины для теста «В корзине · N» (порт `catalogCartQuantitiesProvider`, в приложении — черновик корзины).
final NotifierProvider<_CartQty, Map<String, Qty>> _cartQty = NotifierProvider<_CartQty, Map<String, Qty>>(
  _CartQty.new,
);

class _CartQty extends Notifier<Map<String, Qty>> {
  @override
  Map<String, Qty> build() => const <String, Qty>{};

  void set(Map<String, Qty> value) => state = value;
}

/// Значения `app_ru.arb` без заполнителей.
Set<String> _arbRu() {
  final Map<String, dynamic> arb = jsonDecode(File('lib/l10n/app_ru.arb').readAsStringSync()) as Map<String, dynamic>;
  return <String>{
    for (final MapEntry<String, dynamic> e in arb.entries)
      if (!e.key.startsWith('@') && e.value is String) e.value as String,
  };
}

/// Строки всех `Text` (и `RichText` без детей) внутри [of].
List<String> _texts(WidgetTester tester, Finder of) => <String>[
  for (final Text t in tester.widgetList<Text>(find.descendant(of: of, matching: find.byType(Text))))
    if (t.data != null) t.data!,
];

void main() {
  testWidgets('колонка плиток: корни настоящего дерева, корень выбран в подкатегории; тап по нему — к корню', (
    tester,
  ) async {
    final GoRouter router = await _pump(tester, CatalogHarness(), '/catalog/c/c-mix-kitchen');
    CategoryTile tile(String id) => tester.widget<CategoryTile>(find.byKey(ValueKey<String>('sidebar-category-$id')));
    expect(tile('c-mix').variant, CategoryTileVariant.sidebar);
    expect(tile('c-mix').selected, isTrue, reason: 'корень пути текущей подкатегории');
    expect(tile('c-sanitary').selected, isFalse);
    expect(find.byKey(const ValueKey<String>('sidebar-category-c-mix-kitchen')), findsNothing, reason: 'только корни');
    final State ws = tester.state(find.byType(CatalogWorkspace));
    final State sidebar = tester.state(find.byType(CatalogSidebar));

    await tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-mix')));
    await settle(tester);
    expect(_location(router), '/catalog/c/c-mix');
    expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue, reason: 'тот же экран');
    expect(identical(tester.state(find.byType(CatalogSidebar)), sidebar), isTrue);
    expect(tile('c-mix').selected, isTrue);
  });

  testWidgets('иконка плитки: ключ 03 §14.4, иначе — по смыслу названия, иначе `category`', (tester) async {
    expect(
      CategoryIcons.resolve(key: 'bathtub', name: 'Отопление'),
      Icons.bathtub_rounded,
      reason: 'ключ важнее',
    );
    expect(CategoryIcons.resolve(name: 'Отопление'), Icons.thermostat_rounded);
    expect(CategoryIcons.resolve(name: 'Сантехника'), Icons.bathtub_rounded);
    expect(CategoryIcons.resolve(name: 'Водоснабжение'), Icons.water_drop_rounded);
    expect(CategoryIcons.resolve(name: 'Электрика'), Icons.electrical_services_rounded);
    expect(CategoryIcons.resolve(name: 'Вентиляция'), Icons.air_rounded);
    expect(CategoryIcons.resolve(name: 'Строительные материалы'), Icons.foundation_rounded);
    expect(CategoryIcons.resolve(name: 'Инструменты'), Icons.handyman_rounded);
    expect(CategoryIcons.resolve(name: 'Крепёж и фурнитура'), Icons.hardware_rounded);
    expect(CategoryIcons.resolve(name: 'Смесители'), Icons.plumbing_rounded);
    expect(CategoryIcons.resolve(name: 'Канализационные трубы и фитинги'), Icons.water_damage_rounded);
    expect(CategoryIcons.resolve(name: 'Прочее'), Icons.category_rounded);
  });

  testWidgets('лента подкатегорий: одинаковые карточки, стрелки ‹ › на ширину видимой части и скрытие на краях', (
    tester,
  ) async {
    final CatalogHarness h = CatalogHarness(
      catalog: FakeCatalogRepository(items: products(6), tree: _wideTree()),
    );
    await _pump(tester, h, '/catalog/c/c-san');
    expect(find.byKey(const ValueKey<String>('catalog-subcategory-ribbon')), findsOneWidget);
    expect(find.text('Сантехника'), findsWidgets, reason: 'заголовок раздела');
    final Size all = tester.getSize(find.byKey(const ValueKey<String>('chip-sub-all')));
    final Size first = tester.getSize(find.byKey(const ValueKey<String>('chip-sub-c-san-1')));
    expect(CategoryTile.ribbonSize, const Size(118, 148), reason: 'прототип 2026-10-29');
    expect(all, CategoryTile.ribbonSize);
    expect(first, CategoryTile.ribbonSize, reason: 'карточки одного размера');
    final CategoryTile allTile = tester.widget<CategoryTile>(find.byKey(const ValueKey<String>('chip-sub-all')));
    expect(allTile.selected, isTrue);
    expect(allTile.label, 'Все товары', reason: 'первая карточка — «Все товары» (catalog_title_all)');
    expect(allTile.imageUrl, isNull, reason: 'без картинки родителя — нейтральная иконка');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('chip-sub-all')),
        matching: find.byWidgetPredicate((Widget w) => w is DsGlyph && w.kind == DsGlyphKind.gridOutline),
      ),
      findsOneWidget,
    );

    expect(find.byKey(ScrollRibbon.previousKey), findsNothing, reason: 'в начале — без «‹»');
    expect(find.byKey(ScrollRibbon.nextKey), findsOneWidget);
    // Подписи стрелок — ключи ARB `category_ribbon_prev/next` (закрывают CQ-LAY-02).
    expect(find.bySemanticsLabel('Прокрутить подкатегории вправо'), findsOneWidget);
    expect(tester.getSize(find.byKey(ScrollRibbon.nextKey)), const Size(48, 48), reason: 'цель 48');
    final Icon chevron = tester.widget<Icon>(
      find.descendant(of: find.byKey(ScrollRibbon.nextKey), matching: find.byIcon(Icons.chevron_right_rounded)),
    );
    expect(chevron.size, 18);
    expect(chevron.color, DsColors.lightB.textSecondary, reason: 'шеврон — textSecondary: синий — только фокус и info');
    final double viewport = tester.getSize(find.byKey(const ValueKey<String>('scroll-ribbon-list'))).width;
    await tester.tap(find.byKey(ScrollRibbon.nextKey));
    await settle(tester);
    final double afterNext = _ribbonOffset(tester);
    expect(afterNext, greaterThan(viewport * 0.6), reason: 'прокрутка примерно на ширину видимой части');
    expect(afterNext, lessThanOrEqualTo(viewport));
    expect(find.byKey(ScrollRibbon.previousKey), findsOneWidget);

    for (int i = 0; i < 5; i++) {
      if (find.byKey(ScrollRibbon.nextKey).evaluate().isEmpty) {
        break;
      }
      await tester.tap(find.byKey(ScrollRibbon.nextKey));
      await settle(tester);
    }
    expect(find.byKey(ScrollRibbon.nextKey), findsNothing, reason: 'в конце — без «›»');
    expect(find.byKey(const ValueKey<String>('chip-sub-c-san-20')).hitTestable(), findsOneWidget);

    expect(find.bySemanticsLabel('Прокрутить подкатегории влево'), findsOneWidget);
    await tester.tap(find.byKey(ScrollRibbon.previousKey));
    await settle(tester);
    expect(_ribbonOffset(tester), lessThan(afterNext * 5));
    expect(find.byKey(ScrollRibbon.nextKey), findsOneWidget);
  });

  testWidgets('вертикальный ритм по прототипу (QA, раунд 2): от верха контента карточка ленты 74, кнопки строки '
      'управления 243, сетка 298; первая плитка колонки 57', (tester) async {
    final CatalogHarness h = CatalogHarness(
      catalog: FakeCatalogRepository(items: products(6), tree: _wideTree()),
    );
    await _pump(tester, h, '/catalog/c/c-san', size: const Size(1440, 1180));
    final double top = tester.getTopLeft(find.byKey(const ValueKey<String>('catalog-product-view'))).dy;
    // Прототип: main 18 + h1 4 → заголовок; h1 14 + поле ленты 2 → карточка 74; 2 + 18 + 1 → кнопки 40 строки 42.
    expect(tester.getTopLeft(find.byKey(const ValueKey<String>('chip-sub-all'))).dy - top, 74);
    const double inset = (ToolbarToggleButton.target - ToolbarToggleButton.height) / 2;
    expect(tester.getTopLeft(find.byKey(const ValueKey<String>('chip-preset-newest'))).dy + inset - top, 243);
    expect(tester.getTopLeft(find.byKey(const ValueKey<String>('product-p0'))).dy - top, 298);
    // Колонка: поле 20 + «Каталог» (строка 23) + 14.
    final double column = tester.getTopLeft(find.byType(CatalogSidebar)).dy;
    expect(column, top);
    expect(tester.getTopLeft(find.byKey(const ValueKey<String>('sidebar-category-c-san'))).dy - column, 57);
  });

  testWidgets('лента: колесо мыши прокручивает ленту; на краю событие уходит странице', (tester) async {
    final CatalogHarness h = CatalogHarness(
      catalog: FakeCatalogRepository(items: products(6), tree: _wideTree()),
    );
    await _pump(tester, h, '/catalog/c/c-san');
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    final Offset at = tester.getCenter(find.byKey(const ValueKey<String>('chip-sub-c-san-2')));
    await tester.sendEventToBinding(mouse.hover(at));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 200)));
    await settle(tester);
    expect(_ribbonOffset(tester), 200, reason: 'вертикальное колесо → горизонтальная прокрутка ленты');
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -5000)));
    await settle(tester);
    expect(_ribbonOffset(tester), 0);
    // В начале ленты колесо «вверх» ленте не нужно — не перехватывается (страница прокручивается сама).
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
    await settle(tester);
    expect(_ribbonOffset(tester), 0);
  });

  testWidgets('лента: выбранная подкатегория в видимой части; смена подкатегории — только список, без пересоздания', (
    tester,
  ) async {
    final CatalogHarness h = CatalogHarness(
      catalog: FakeCatalogRepository(items: products(6), tree: _wideTree()),
    );
    final GoRouter router = await _pump(tester, h, '/catalog/c/c-san-11');
    final Finder selected = find.byKey(const ValueKey<String>('chip-sub-c-san-11'));
    expect(selected.hitTestable(), findsOneWidget, reason: 'выбранная прокручена в видимую часть');
    expect(tester.widget<CategoryTile>(selected).selected, isTrue);
    expect(find.text('Сантехника'), findsWidgets, reason: 'заголовок — родитель ленты');

    final State ws = tester.state(find.byType(CatalogWorkspace));
    final State ribbon = tester.state(find.byType(ScrollRibbon));
    final Element toolbar = tester.element(find.byType(CatalogToolbarControls));
    final int calls = h.catalog.productCalls.length;
    await tester.tap(find.byKey(const ValueKey<String>('chip-sub-c-san-10')));
    await settle(tester);
    expect(_location(router), startsWith('/catalog/c/c-san-10'));
    expect(h.catalog.productCalls.length - calls, 1, reason: 'один запрос списка');
    expect(h.catalog.productCalls.last.filter.categoryId, 'c-san-10');
    expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue);
    expect(identical(tester.state(find.byType(ScrollRibbon)), ribbon), isTrue, reason: 'лента не пересоздаётся');
    expect(identical(tester.element(find.byType(CatalogToolbarControls)), toolbar), isTrue);
    expect(tester.widget<CategoryTile>(find.byKey(const ValueKey<String>('chip-sub-c-san-10'))).selected, isTrue);
  });

  testWidgets('лента: картинка категории из данных; без неё — иконка-заглушка DS, фото товара не подставляется', (
    tester,
  ) async {
    final ProductSummary p = product(1);
    final ProductSummary withPhoto = ProductSummary(
      id: p.id,
      name: p.name,
      sku: p.sku,
      categoryId: 'c-san-2',
      defaultVariantId: p.defaultVariantId,
      baseUnit: p.baseUnit,
      price: p.price,
      stock: p.stock,
      primaryImage: const ProductImageRef(
        sha256: 'sha-p1',
        thumbUrl: 'http://img.test/images/sha-p1/thumb.webp',
        cardUrl: 'http://img.test/images/sha-p1/card.webp',
        isPrimary: true,
      ),
    );
    final CatalogHarness h = CatalogHarness(
      catalog: FakeCatalogRepository(items: <ProductSummary>[withPhoto], tree: _wideTree()),
    );
    await _pump(tester, h, '/catalog/c/c-san');
    final Finder withImage = find.byKey(const ValueKey<String>('chip-sub-c-san-1'));
    final Finder noImage = find.byKey(const ValueKey<String>('chip-sub-c-san-2'));
    expect(find.descendant(of: withImage, matching: find.byType(Image)), findsOneWidget);
    expect(
      find.descendant(of: noImage, matching: find.byKey(const ValueKey<String>('category-tile-placeholder'))),
      findsOneWidget,
    );
    expect(
      find.descendant(of: noImage, matching: find.byType(Image)),
      findsNothing,
      reason: 'без фото товара',
    );
    expect(find.descendant(of: noImage, matching: find.byType(ProductImage)), findsNothing);
  });

  testWidgets('«Новые»: включает сортировку updatedAt:desc с выбранным видом, повторно — прежнюю; '
      'в «Недавних» недоступна', (tester) async {
    final FakeShelfPort shelf = FakeShelfPort(
      recent: <RecentProduct>[RecentProduct(product: product(1), viewedAt: kNow)],
    );
    addTearDown(shelf.dispose);
    final CatalogHarness h = CatalogHarness(shelf: shelf);
    final GoRouter router = await _pump(tester, h, '/catalog/c/c-sanitary');
    final Finder newest = find.byKey(const ValueKey<String>('chip-preset-newest'));
    ToolbarToggleButton chip() => tester.widget<ToolbarToggleButton>(newest);
    expect(chip().label, 'Новые');
    expect(chip().selected, isFalse);
    expect(chip().enabled, isTrue);

    await tester.tap(newest);
    await settle(tester);
    expect(h.catalog.productCalls.last.sort, CatalogSort.updatedAtDesc);
    expect(chip().selected, isTrue);
    expect(_location(router), contains('sort=updatedAt'));
    expect(
      find.descendant(of: find.byKey(const ValueKey<String>('catalog-sort')), matching: find.text('Сначала новые')),
      findsOneWidget,
      reason: 'подпись сортировки — текущая',
    );

    await tester.tap(newest);
    await settle(tester);
    expect(h.catalog.productCalls.last.sort, CatalogSort.nameAsc, reason: 'возврат к прежней сортировке');
    expect(chip().selected, isFalse);

    await tester.tap(find.byKey(const ValueKey<String>('chip-preset-recent')));
    await settle(tester);
    expect(chip().enabled, isFalse, reason: 'у «Недавних» порядок просмотра — сортировка неприменима');
    expect(
      tester.widget<ToolbarToggleButton>(find.byKey(const ValueKey<String>('chip-preset-recent'))).selected,
      isTrue,
    );
  });

  testWidgets('«Избранные» строки управления — настоящий фильтр favorite (залитая звезда); повторно снимается', (
    tester,
  ) async {
    final FakeShelfPort shelf = FakeShelfPort(favorites: <String>{'p1'});
    addTearDown(shelf.dispose);
    final CatalogHarness h = CatalogHarness(shelf: shelf);
    await _pump(tester, h, '/catalog/c/c-sanitary');
    final Finder favorites = find.byKey(const ValueKey<String>('chip-preset-favorites'));
    expect(tester.widget<ToolbarToggleButton>(favorites).label, 'Избранные');
    expect(find.descendant(of: favorites, matching: find.byIcon(Icons.star_outline_rounded)), findsOneWidget);
    await tester.tap(favorites);
    await settle(tester);
    expect(h.catalog.productCalls.last.filter.favorite, isTrue);
    expect(tester.widget<ToolbarToggleButton>(favorites).selected, isTrue);
    expect(
      find.descendant(of: favorites, matching: find.byIcon(Icons.star_rounded)),
      findsOneWidget,
      reason: 'выбранное — не только цветом (A11Y-004)',
    );
    await tester.tap(find.byKey(const ValueKey<String>('chip-preset-favorites')));
    await settle(tester);
    expect(h.catalog.productCalls.last.filter.favorite, isNull);
  });

  testWidgets('сетка: колонки от 176 по ширине области (без CP: продавец и клиент — 6); «+ Добавить» на одной линии', (
    tester,
  ) async {
    Future<void> check(RoleCode role, int expectedCols) async {
      final CatalogHarness h = CatalogHarness(
        role: role,
        catalog: FakeCatalogRepository(items: products(12)),
      );
      await _pump(tester, h, '/catalog/c/c-sanitary');
      final List<double> xs = <double>[];
      final List<double> buttonsY = <double>[];
      final double firstTop = tester.getTopLeft(find.byKey(const ValueKey<String>('product-p0'))).dy;
      for (int i = 0; i < 12; i++) {
        final Finder card = find.byKey(ValueKey<String>('product-p$i'));
        if (card.evaluate().isEmpty || tester.getTopLeft(card).dy != firstTop) {
          continue;
        }
        xs.add(tester.getTopLeft(card).dx);
        final Finder button = find.descendant(of: card, matching: find.byType(AppButton));
        if (button.evaluate().isNotEmpty) {
          buttonsY.add(tester.getBottomLeft(button).dy);
        }
      }
      expect(xs.length, expectedCols, reason: '$role: колонок в первом ряду');
      expect(buttonsY.toSet(), hasLength(1), reason: '$role: кнопки ряда на одной линии');
    }

    // 1366: колонка 132, постоянной CP нет (корзина — drawer по кнопке шапки, ADR-112) → 6 колонок у продавца; у
    // клиента на expanded — прежний сайдбар-список 292 (D6) → 5 колонок.
    await check(RoleCode.seller, 6);
    await check(RoleCode.customer, 5);
    expect(DsBreakpoints.gridColumns(1440 - 132 - 40, 16, minCardWidth: DsBreakpoints.catalogCardMinWidth), 6);
    expect(DsBreakpoints.gridColumns(1280 - 132 - 40, 16, minCardWidth: DsBreakpoints.catalogCardMinWidth), 5);
    expect(DsBreakpoints.gridColumns(1024 - 132 - 40, 16, minCardWidth: DsBreakpoints.catalogCardMinWidth), 4);
  });

  testWidgets('сетка auto-fill от 176 (прототип): окна 1440, 1280 и 1024 — 6, 5 и 4 колонки; зазор 16', (tester) async {
    for (final (Size size, int cols) in <(Size, int)>[
      (const Size(1440, 1180), 6),
      (const Size(1280, 900), 5),
      (const Size(1024, 800), 4),
    ]) {
      final CatalogHarness h = CatalogHarness(catalog: FakeCatalogRepository(items: products(12)));
      await _pump(tester, h, '/catalog/c/c-sanitary', size: size);
      final double firstTop = tester.getTopLeft(find.byKey(const ValueKey<String>('product-p0'))).dy;
      final List<Rect> row = <Rect>[
        for (int i = 0; i < 12; i++)
          if (find.byKey(ValueKey<String>('product-p$i')).evaluate().isNotEmpty &&
              tester.getTopLeft(find.byKey(ValueKey<String>('product-p$i'))).dy == firstTop)
            tester.getRect(find.byKey(ValueKey<String>('product-p$i'))),
      ];
      expect(row, hasLength(cols), reason: '${size.width.toInt()}: колонок в первом ряду');
      expect(row.first.width, greaterThanOrEqualTo(DsBreakpoints.catalogCardMinWidth), reason: '$size');
      expect(row[1].left - row[0].right, closeTo(16, 0.5), reason: '$size: зазор сетки 16');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('«+ Добавить»: сразу загрузка, повторные нажатия до ответа — без лишних добавлений', (tester) async {
    final _SlowCartPort cart = _SlowCartPort();
    final CatalogHarness h = CatalogHarness(extra: <Override>[catalogCartPortProvider.overrideWithValue(cart)]);
    await _pump(tester, h, '/catalog/c/c-sanitary');
    final Finder card = find.byKey(const ValueKey<String>('product-p0'));
    final Finder button = find.descendant(of: card, matching: find.byType(AppButton));
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<AppButton>(button).loading, isTrue, reason: 'мгновенная обратная связь');
    expect(find.descendant(of: card, matching: find.byType(AppProgress)), findsOneWidget);
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    expect(cart.added, <String>['p0'], reason: 'один запрос корзины на серию нажатий до ответа');
    expect(find.text('product p0'), findsNothing, reason: 'нажатие по кнопке в загрузке не открывает карточку товара');
    cart.release();
    await settle(tester);
    expect(tester.widget<AppButton>(button).loading, isFalse);
    await tester.tap(button);
    await tester.pump();
    expect(cart.added, <String>['p0', 'p0'], reason: 'следующее нажатие после ответа — обычное добавление');
    cart.release();
    await settle(tester);
  });

  testWidgets('тексты колонки, ленты и панели управления — из ARB (ru) или настоящие названия категорий', (
    tester,
  ) async {
    final FakeShelfPort shelf = FakeShelfPort();
    addTearDown(shelf.dispose);
    final CatalogHarness h = CatalogHarness(shelf: shelf);
    await _pump(tester, h, '/catalog/c/c-mix-kitchen');
    final Set<String> arb = _arbRu();
    final Set<String> categories = <String>{for (final Category c in categoryTree().all) c.name};
    // «Найдено: N товаров» — ARB с заполнителем (catalog_found_count), проверяется отдельно.
    final Set<String> found = _texts(tester, find.byKey(const ValueKey<String>('catalog-found'))).toSet();
    expect(found, <String>{'Найдено: 6 товаров'});
    final List<String> texts = <String>[
      ..._texts(tester, find.byType(CatalogSidebar)),
      ..._texts(tester, find.byType(ScrollRibbon)),
      ..._texts(tester, find.byKey(const ValueKey<String>('catalog-toolbar'))).where((String t) => !found.contains(t)),
    ];
    expect(texts, isNotEmpty);
    for (final String t in texts) {
      // Числа — счётчики товаров категорий и избранного из данных (паритет функций ADR-112).
      final bool count = RegExp(r'^\d+$').hasMatch(t);
      expect(arb.contains(t) || categories.contains(t) || count, isTrue, reason: '«$t» — не из ARB и не из данных');
    }
    expect(
      texts,
      containsAll(<String>['Каталог', 'Избранное', 'Все товары', 'Новые', 'Избранные', 'Недавние', 'Фильтры']),
    );
    expect(find.byType(ProductCardGrid), findsWidgets);
  });

  testWidgets('medium: корни — колонкой 132 (без полосы корней), подкатегории — лентой, подборки — в строке', (
    tester,
  ) async {
    final GoRouter router = await _pump(
      tester,
      CatalogHarness(shelf: FakeShelfPort()),
      '/catalog/c/c-mix',
      size: kMedium,
    );
    expect(find.byKey(const ValueKey<String>('chip-all-categories')), findsNothing);
    expect(find.byKey(const ValueKey<String>('chip-cat-c-mix')), findsNothing);
    expect(tester.getSize(find.byType(CatalogSidebar)).width, DsBreakpoints.catalogColumn);
    expect(find.byKey(const ValueKey<String>('sidebar-title')), findsOneWidget);
    expect(tester.widget<CategoryTile>(find.byKey(const ValueKey<String>('sidebar-category-c-mix'))).selected, isTrue);
    expect(find.byKey(const ValueKey<String>('chip-sub-c-mix-kitchen')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('chip-preset-newest')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('chip-sub-c-mix-kitchen')));
    await settle(tester);
    // medium: подкатегория — `push` (02 SCR-12.6; системная «Назад» — к родителю): адрес верхней записи стека.
    expect(router.state.uri.toString(), startsWith('/catalog/c/c-mix-kitchen'));
    expect(router.canPop(), isTrue);
    // Корень выбран; тап по нему из подкатегории — к корню (верхняя страница; в приложении запись `push` рисует тот
    // же экран — catalog_stability_test).
    await tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-mix')).last);
    await settle(tester);
    expect(_location(router), startsWith('/catalog/c/c-mix'));
    expect(_location(router), isNot(contains('kitchen')));
  });

  testWidgets('колонка категорий 132: заголовок «Каталог» h3 700, плитки ≥ 88; выбранная — тинт и подпись 700', (
    tester,
  ) async {
    await _pump(tester, CatalogHarness(shelf: FakeShelfPort()), '/catalog/c/c-mix');
    expect(tester.getSize(find.byType(CatalogSidebar)).width, DsBreakpoints.catalogColumn);
    final Text title = tester.widget<Text>(find.byKey(const ValueKey<String>('sidebar-title')));
    expect(title.data, 'Каталог');
    expect(title.style?.fontSize, 20);
    expect(title.style?.fontWeight, FontWeight.w700);
    final Finder selected = find.byKey(const ValueKey<String>('sidebar-category-c-mix'));
    final Finder other = find.byKey(const ValueKey<String>('sidebar-category-c-sanitary'));
    expect(tester.getSize(selected).height, greaterThanOrEqualTo(CategoryTile.sidebarMinHeight));
    Text label(Finder tile) => tester.widget<Text>(
      find.descendant(of: tile, matching: find.byKey(const ValueKey<String>('category-tile-label'))),
    );
    expect(label(selected).style?.fontWeight, FontWeight.w700, reason: 'выбранная — вес 700 (не только цвет)');
    expect(label(other).style?.fontWeight, FontWeight.w600);
    expect(find.byKey(const ValueKey<String>('sidebar-favorites')), findsOneWidget);
  });

  testWidgets('карточка сетки по прототипу: фото 150 contain, звезда 34, название 2 строки, «Арт.», остаток, '
      'цена с «/ шт», «+ Добавить»; нет в наличии — серая «Нет в наличии»', (tester) async {
    final FakeShelfPort shelf = FakeShelfPort();
    addTearDown(shelf.dispose);
    final CatalogHarness h = CatalogHarness(
      shelf: shelf,
      catalog: FakeCatalogRepository(
        items: <ProductSummary>[
          product(0),
          product(1, level: StockLevel.out),
        ],
      ),
    );
    await _pump(tester, h, '/catalog/c/c-sanitary');
    final Finder card = find.byKey(const ValueKey<String>('product-p0'));
    final ProductImage photo = tester.widget<ProductImage>(
      find.descendant(of: card, matching: find.byType(ProductImage)),
    );
    expect(photo.height, kProductCardGridImageHeight);
    expect(photo.fit, BoxFit.contain);
    expect(tester.getSize(find.descendant(of: card, matching: find.byType(ProductImage))).height, 150);
    expect(
      tester.widget<FavoriteToggle>(find.descendant(of: card, matching: find.byType(FavoriteToggle))).variant,
      FavoriteToggleVariant.onImage,
    );
    expect(FavoriteToggle.onImageSize, 34);
    final Text name = tester.widget<Text>(find.descendant(of: card, matching: find.text(product(0).name)));
    expect(name.maxLines, 2);
    expect(name.style?.fontWeight, FontWeight.w600);
    expect(find.descendant(of: card, matching: find.text('Арт. F4200-CR')), findsOneWidget);
    expect(
      tester.widget<StockBadge>(find.descendant(of: card, matching: find.byType(StockBadge))).variant,
      StockBadgeVariant.inline,
    );
    expect(tester.widget<PriceText>(find.descendant(of: card, matching: find.byType(PriceText))).unit, '/ шт');
    final AppButton add = tester.widget<AppButton>(find.descendant(of: card, matching: find.byType(AppButton)));
    expect(add.label, '+ Добавить');
    expect(add.size, AppButtonSize.card);
    expect(add.variant, AppButtonVariant.primary);
    final Finder out = find.byKey(const ValueKey<String>('product-p1'));
    expect(find.descendant(of: out, matching: find.byType(AppButton)), findsNothing);
    expect(
      find.descendant(of: out, matching: find.byKey(const ValueKey<String>('product-card-unavailable'))),
      findsOneWidget,
    );
    expect(find.descendant(of: out, matching: find.text('Нет в наличии')), findsWidgets);
    expect(find.descendant(of: out, matching: find.byIcon(Icons.cancel_rounded)), findsOneWidget);
    // Недоступная кнопка: для экранного диктора — кнопка без действия, нажатие ничего не добавляет.
    final SemanticsHandle semantics = tester.ensureSemantics();
    final Finder unavailable = find.descendant(
      of: out,
      matching: find.byKey(const ValueKey<String>('product-card-unavailable')),
    );
    expect(
      tester.getSemantics(unavailable),
      containsSemantics(isButton: true, hasEnabledState: true, isEnabled: false, hasTapAction: false),
    );
    await tester.tap(unavailable, warnIfMissed: false);
    await tester.pump();
    expect(find.textContaining('Добавлено'), findsNothing);
    semantics.dispose();
  });

  testWidgets('«В корзине · N — ещё +1»: количество из порта корзины; перестраивается только своя карточка', (
    tester,
  ) async {
    final _SlowCartPort cart = _SlowCartPort();
    final CatalogHarness h = CatalogHarness(
      extra: <Override>[
        catalogCartPortProvider.overrideWithValue(cart),
        catalogCartQuantitiesProvider.overrideWith((Ref ref) => ref.watch(_cartQty)),
      ],
    );
    await _pump(tester, h, '/catalog/c/c-sanitary');
    Finder button(String id) =>
        find.descendant(of: find.byKey(ValueKey<String>('product-$id')), matching: find.byType(AppButton));
    expect(tester.widget<AppButton>(button('p0')).label, '+ Добавить');
    final State ws = tester.state(find.byType(CatalogWorkspace));
    final Widget otherCard = tester.widget(
      find.descendant(of: find.byKey(const ValueKey<String>('product-p1')), matching: find.byType(ProductCardGrid)),
    );
    final ProviderContainer container = ProviderScope.containerOf(tester.element(find.byType(CatalogWorkspace)));
    container.read(_cartQty.notifier).set(<String, Qty>{'v0': Qty.units(3)});
    await tester.pump();
    final AppButton inCart = tester.widget<AppButton>(button('p0'));
    expect(inCart.label, 'В корзине · 3 — ещё +1');
    expect(inCart.variant, AppButtonVariant.tint);
    expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue);
    expect(
      identical(
        tester.widget(
          find.descendant(of: find.byKey(const ValueKey<String>('product-p1')), matching: find.byType(ProductCardGrid)),
        ),
        otherCard,
      ),
      isTrue,
      reason: 'карточка другого товара не перестраивается',
    );
    await tester.tap(button('p0'));
    await tester.pump();
    expect(cart.added, <String>['p0'], reason: 'нажатие — ещё шаг в корзину');
    cart.release();
    await settle(tester);
  });

  testWidgets('масштаб текста 1.3: колонка, лента, сетка, «Список» и «Компакт» — без переполнения', (tester) async {
    final CatalogHarness h = CatalogHarness(catalog: FakeCatalogRepository(items: products(8)));
    setWindow(tester, const Size(1440, 1180));
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final GoRouter router = _router('/catalog/c/c-mix');
    addTearDown(router.dispose);
    await tester.pumpWidget(catalogApp(h, router: router));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(ProductCardGrid), findsWidgets);
    expect(find.byKey(const ValueKey<String>('catalog-subcategory-ribbon')), findsOneWidget);
    final double extent = tester.getSize(find.byKey(const ValueKey<String>('product-p0'))).height;
    expect(extent, kProductCardGridExtent(const TextScaler.linear(1.3)));
    expect(extent, greaterThan(kProductCardGridExtent(TextScaler.noScaling)));
    for (final String view in <String>['view-mode-list', 'view-mode-compact']) {
      await tester.tap(find.byKey(ValueKey<String>(view)));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: view);
    }
    expect(find.byType(ProductCardCompact), findsWidgets);
  });

  testWidgets('«Список» medium+ — отдельные карточки с зазором 8; «Компакт» — колонки Артикул · Наименование · '
      'Наличие · Цена · кнопка в контейнере с обводкой', (tester) async {
    final CatalogHarness h = CatalogHarness(catalog: FakeCatalogRepository(items: products(4)));
    await _pump(tester, h, '/catalog/c/c-sanitary');
    await tester.tap(find.byKey(const ValueKey<String>('view-mode-list')));
    await settle(tester);
    final Rect a = tester.getRect(find.byType(ProductCardList).at(0));
    final Rect b = tester.getRect(find.byType(ProductCardList).at(1));
    expect(b.top - a.bottom, 8, reason: 'зазор между карточками');
    expect(a.height, 10 + 60 + 10 + 2, reason: 'прототип: поля 10, фото 60, обводка 1');
    expect(find.descendant(of: find.byType(ProductCardList).first, matching: find.text('+ Добавить')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('view-mode-compact')));
    await settle(tester);
    expect(find.byType(ProductCardCompactHeader), findsOneWidget);
    for (final String col in <String>['Артикул', 'Наименование', 'Наличие', 'Цена']) {
      expect(find.descendant(of: find.byType(ProductCardCompactHeader), matching: find.text(col)), findsOneWidget);
    }
    expect(find.byType(DecoratedSliver), findsWidgets, reason: 'таблица — в белом контейнере с обводкой');
    final Finder row = find.byType(ProductCardCompact).first;
    expect(tester.getSize(row).height, ProductCardCompact.tableRowHeight + 1);
    expect(find.descendant(of: row, matching: find.text('F4200-CR')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('+ Добавить')), findsOneWidget);
    expect(
      tester.widget<AppButton>(find.descendant(of: row, matching: find.byType(AppButton))).size,
      AppButtonSize.cardCompact,
    );
    expect(
      tester.widget<ViewModeSegmented>(find.byType(ViewModeSegmented)).style,
      ViewModeSegmentedStyle.toolbar,
      reason: 'вид — стиль строки управления',
    );
  });
}

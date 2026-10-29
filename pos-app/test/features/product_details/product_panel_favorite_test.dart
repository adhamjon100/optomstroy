// SCR-14: звезда избранного через порт `productFavoritePortProvider` (02 SCR-14 A3, FAV-002; 06 §6.1, EQ-PD-03)
// и панель поверх контент-колонки списка на expanded (02 SCR-14.2, navigation.md §5; EQ-PD-05): маршрут
// `ProductRoute` — прозрачная страница, шапка и колонка категорий под ней видимы, клик вне панели закрывает её.
// Редакция 02 1.16 (ADR-112): постоянной CP под панелью больше нет — кнопка-итог корзины в шапке остаётся доступной
// при открытой панели (сквозная область, как у `CatalogHeader`): нажатие доходит до кнопки, панель не закрывается.
// Синтетические данные (фикстуры, без реальной интеграции).
// Тест-кейсы 12_TEST_PLAN: T-CART-037 (кнопка-итог доступна при открытой панели SCR-14).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/layout/content_region.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/product_details/presentation/screens/product_details_screen.dart';
import 'package:optomstroy/features/product_details/product_details_providers.dart';

import 'product_fixtures.dart';

final class _FakeFavorites implements ProductFavoritePort {
  _FakeFavorites({Set<String> initial = const <String>{}}) : _ids = <String>{...initial};

  final Set<String> _ids;
  final StreamController<Set<String>> _changes = StreamController<Set<String>>.broadcast();
  final List<(String, bool)> calls = <(String, bool)>[];
  bool fail = false;

  @override
  Stream<Set<String>> watchFavoriteIds() async* {
    yield Set<String>.of(_ids);
    yield* _changes.stream;
  }

  @override
  Future<Result<void>> setFavorite(String productId, {required bool favorite}) async {
    calls.add((productId, favorite));
    if (fail) return const FailureResult<void>(ServerFailure(code: 'INTERNAL', status: 500));
    favorite ? _ids.add(productId) : _ids.remove(productId);
    _changes.add(Set<String>.of(_ids));
    return const Success<void>(null);
  }
}

List<Override> _overrides(Product p, {ProductFavoritePort? favorites}) => <Override>[
  ...productOverrides(
    catalog: FakeCatalogRepository(cached: p, network: Success<Product>(p)),
  ),
  productFavoritePortProvider.overrideWithValue(favorites),
];

/// Список-заглушка SCR-10 на expanded по прототипу 2026-10-29 (ADR-112): шапка 68 с полем поиска (SearchBar —
/// сквозная область, закрывает панель) и кнопкой-итогом корзины справа (сквозная область без закрытия — как в
/// `CatalogHeader`), колонка категорий 132, контент-колонка (якорь панели). Постоянной CP нет.
class _FakeCatalog extends StatelessWidget {
  const _FakeCatalog({required this.onSidebarTap, required this.onCartTap, required this.searchFocus});

  final VoidCallback onSidebarTap;
  final VoidCallback onCartTap;
  final FocusNode searchFocus;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: 68,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 300, child: Text('header')),
              SizedBox(
                width: 400,
                child: DsPanelPassThrough(
                  closesPanel: true,
                  child: TextField(key: const ValueKey<String>('fake-search'), focusNode: searchFocus),
                ),
              ),
              const Spacer(),
              DsPanelPassThrough(
                child: SizedBox(
                  width: 160,
                  height: 44,
                  child: TextButton(
                    key: const ValueKey<String>('fake-cart-button'),
                    onPressed: onCartTap,
                    child: const Text('Корзина · 3'),
                  ),
                ),
              ),
              const SizedBox(width: 120, child: Text('bell+user')),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: 132,
                child: TextButton(
                  key: const ValueKey<String>('fake-sidebar'),
                  onPressed: onSidebarTap,
                  child: const Text('sidebar'),
                ),
              ),
              const Expanded(
                child: DsContentRegion(
                  child: ColoredBox(key: ValueKey<String>('fake-list'), color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

void main() {
  group('звезда избранного SCR-14 (EQ-PD-03)', () {
    testWidgets('без порта звезды нет', (WidgetTester tester) async {
      await pumpProduct(tester, overrides: _overrides(singleVariantProduct()));
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('product-favorite')), findsNothing);
    });

    testWidgets('compact: звезда в шапке, optimistic-переключение, снекбар «Добавлено в избранное»', (
      WidgetTester tester,
    ) async {
      final _FakeFavorites fav = _FakeFavorites();
      await pumpProduct(tester, overrides: _overrides(singleVariantProduct(), favorites: fav));
      await tester.pump();
      final Finder star = find.byKey(const ValueKey<String>('product-favorite'));
      expect(star, findsOneWidget);
      expect(tester.widget<FavoriteToggle>(star).selected, isFalse);
      expect(tester.widget<FavoriteToggle>(star).semanticLabel, 'Добавить в избранное');

      await tester.tap(star);
      await tester.pump();
      await tester.pump();
      expect(fav.calls, <(String, bool)>[('p-1', true)]);
      expect(tester.widget<FavoriteToggle>(star).selected, isTrue);
      expect(tester.widget<FavoriteToggle>(star).semanticLabel, 'В избранном');
      expect(find.text('Добавлено в избранное'), findsOneWidget);
    });

    testWidgets('ошибка сохранения — откат и «Не удалось сохранить избранное»', (WidgetTester tester) async {
      final _FakeFavorites fav = _FakeFavorites()..fail = true;
      await pumpProduct(tester, overrides: _overrides(singleVariantProduct(), favorites: fav));
      await tester.pump();
      final Finder star = find.byKey(const ValueKey<String>('product-favorite'));
      await tester.tap(star);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<FavoriteToggle>(star).selected, isFalse);
      expect(find.text('Не удалось сохранить избранное'), findsOneWidget);
    });

    testWidgets('expanded: звезда перед крестиком, товар уже в избранном', (WidgetTester tester) async {
      final _FakeFavorites fav = _FakeFavorites(initial: <String>{'p-1'});
      await pumpProduct(
        tester,
        overrides: _overrides(singleVariantProduct(), favorites: fav),
        size: expandedWindow,
      );
      await tester.pump();
      final Finder star = find.byKey(const ValueKey<String>('product-favorite'));
      expect(tester.widget<FavoriteToggle>(star).selected, isTrue);
      final double starX = tester.getCenter(star).dx;
      final double closeX = tester.getCenter(find.byKey(const ValueKey<String>('product-close'))).dx;
      expect(starX, lessThan(closeX));
    });
  });

  group('панель SCR-14 поверх контент-колонки (expanded, EQ-PD-05)', () {
    Future<GoRouter> pumpRouter(
      WidgetTester tester, {
      required VoidCallback onSidebarTap,
      VoidCallback? onCartTap,
      FocusNode? searchFocus,
      bool animations = false,
    }) async {
      final FocusNode focus = searchFocus ?? FocusNode();
      if (searchFocus == null) addTearDown(focus.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = expandedWindow;
      addTearDown(tester.view.reset);
      final GoRouter router = GoRouter(
        initialLocation: '/catalog',
        routes: <RouteBase>[
          GoRoute(
            path: '/catalog',
            builder: (BuildContext context, GoRouterState state) =>
                _FakeCatalog(onSidebarTap: onSidebarTap, onCartTap: onCartTap ?? () {}, searchFocus: focus),
            routes: <RouteBase>[
              // Второй экран-список со своей контент-колонкой (как SCR-11 поверх SCR-10).
              GoRoute(
                path: 'search',
                builder: (BuildContext context, GoRouterState state) =>
                    _FakeCatalog(onSidebarTap: onSidebarTap, onCartTap: onCartTap ?? () {}, searchFocus: focus),
              ),
              GoRoute(
                path: 'p/:productId',
                pageBuilder: (BuildContext context, GoRouterState state) =>
                    ProductRoute(productId: state.pathParameters['productId']!).buildPage(context, state),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides(singleVariantProduct()),
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: !animations),
              child: child!,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('панель занимает контент-колонку: колонка категорий и кнопка корзины видимы; клик вне панели — pop', (
      WidgetTester tester,
    ) async {
      int sidebarTaps = 0;
      final GoRouter router = await pumpRouter(tester, onSidebarTap: () => sidebarTaps++);
      unawaited(router.push<void>('/catalog/p/p-1'));
      await tester.pumpAndSettle();

      expect(find.byType(ProductDetailsScreen), findsOneWidget);
      // Корень SCR-14 и в раскладке панели несёт ключ `scr-14` (интеграционный catalog_flow_test, RR-1).
      expect(find.byKey(const ValueKey<String>('scr-14')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey<String>('scr-14'))),
        tester.getRect(find.byKey(const ValueKey<String>('product-panel-overlay'))),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('scr-14')),
          matching: find.byKey(const ValueKey<String>('product-name')),
        ),
        findsOneWidget,
      );
      final Rect panel = tester.getRect(find.byKey(const ValueKey<String>('product-panel-overlay')));
      final Rect list = tester.getRect(find.byKey(const ValueKey<String>('fake-list')));
      expect(panel, list, reason: 'панель — ровно контент-колонка (ширина < 1200)');
      // Список под прозрачной страницей остаётся построенным: колонка категорий и кнопка корзины видимы.
      expect(find.byKey(const ValueKey<String>('fake-cart-button')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('fake-sidebar')), findsOneWidget);

      // Клик по сайдбару (вне панели) закрывает панель тем же маршрутом, без действия под ней.
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey<String>('fake-sidebar'))));
      await tester.pumpAndSettle();
      expect(find.byType(ProductDetailsScreen), findsNothing);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/catalog');
      expect(sidebarTaps, 0);
    });

    testWidgets('кнопка-итог корзины в шапке при открытой панели: нажатие доходит до кнопки, панель остаётся '
        '(02 SCR-14.2 ред. 1.16, AC-UI-14-001; ADR-112)', (WidgetTester tester) async {
      int cartTaps = 0;
      final GoRouter router = await pumpRouter(tester, onSidebarTap: () {}, onCartTap: () => cartTaps++);
      unawaited(router.push<void>('/catalog/p/p-1'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('fake-cart-button')));
      await tester.pumpAndSettle();
      expect(cartTaps, 1, reason: 'нажатие доходит до кнопки (в приложении — drawer корзины поверх панели)');
      expect(find.byType(ProductDetailsScreen), findsOneWidget, reason: 'панель остаётся открытой');
      expect(router.canPop(), isTrue, reason: 'маршрут панели в стеке');
      // Пустая область шапки рядом с кнопкой — по-прежнему закрывает панель (navigation.md §5).
      await tester.tapAt(const Offset(150, 34));
      await tester.pumpAndSettle();
      expect(find.byType(ProductDetailsScreen), findsNothing);
    });

    testWidgets('клик по пустой области шапки — pop', (WidgetTester tester) async {
      final GoRouter router = await pumpRouter(tester, onSidebarTap: () {});
      unawaited(router.push<void>('/catalog/p/p-1'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(150, 34));
      await tester.pumpAndSettle();
      expect(find.byType(ProductDetailsScreen), findsNothing);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/catalog');
    });

    testWidgets('клик в SearchBar шапки: поле получает фокус, панель закрывается', (WidgetTester tester) async {
      final FocusNode search = FocusNode();
      addTearDown(search.dispose);
      final GoRouter router = await pumpRouter(tester, onSidebarTap: () {}, searchFocus: search);
      unawaited(router.push<void>('/catalog/p/p-1'));
      await tester.pumpAndSettle();
      expect(search.hasFocus, isFalse);

      await tester.tap(find.byKey(const ValueKey<String>('fake-search')));
      await tester.pumpAndSettle();
      expect(find.byType(ProductDetailsScreen), findsNothing);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/catalog');
      expect(search.hasFocus, isTrue, reason: 'ввод в SearchBar продолжается без панели');
    });

    testWidgets('go на корень каталога при открытой панели над поиском: панель уходит без ошибок', (
      WidgetTester tester,
    ) async {
      // catalog_flow_test (офлайн-шаг): `go('/catalog')` убирает SCR-11 под панелью сразу, а панель ещё
      // перестраивается на обратном переходе — колонка SCR-11 уже неактивна (findRenderObject запрещён).
      final GoRouter router = await pumpRouter(tester, onSidebarTap: () {}, animations: true);
      router.go('/catalog/search');
      await tester.pumpAndSettle();
      unawaited(router.push<void>('/catalog/p/p-1'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('scr-14')), findsOneWidget);

      router.go('/catalog');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ProductDetailsScreen), findsNothing);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/catalog');
    });

    testWidgets('крестик закрывает панель (pop к списку)', (WidgetTester tester) async {
      final GoRouter router = await pumpRouter(tester, onSidebarTap: () {});
      unawaited(router.push<void>('/catalog/p/p-1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('product-close')));
      await tester.pumpAndSettle();
      expect(find.byType(ProductDetailsScreen), findsNothing);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/catalog');
    });
  });
}

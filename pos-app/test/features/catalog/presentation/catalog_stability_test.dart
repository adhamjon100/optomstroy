// Стабильность рабочего пространства каталога при смене категории (заказчик 2026-10-28: «мигает весь экран»).
// Настоящие маршруты приложения (`$appRoutes`: StatefulShellRoute, CatalogRoute → CategoryRoute/CatalogSearchRoute),
// Windows (ZoomPageTransitionsBuilder по умолчанию), expanded 1366×900: /catalog → категория «А» (Смесители) →
// категория «Б» (Санфаянс). Измеряется: пересоздание шапки, сайдбара, панели инструментов, CatalogWorkspace,
// кнопки корзины в шапке (бывшая CP, ADR-112; порт `catalogCartButtonProvider`) и фото товара (идентичность
// Element/State), кадры анимации перехода страницы, кадры скелетона при данных
// в локальном кэше, число запросов списка на одну смену категории. 02 SCR-10.5 ANIM-024 / SCR-12.5: на expanded
// анимируется только контент-колонка, SB и CP — нет; SCR-10.7 «Загрузка (тёплая)»: кэш ≤ 100 мс + тонкий прогресс.
// Данные синтетические (фейки тестов каталога), не реальная интеграция.
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/rendering.dart' show SemanticsData;
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/layout/route_activity.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logo.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_sidebar.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_toolbar.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_workspace.dart';

import 'support/catalog_fakes.dart';

const ValueKey<String> _skeleton = ValueKey<String>('catalog-skeleton');
const ValueKey<String> _refreshBar = ValueKey<String>('catalog-list-refreshing');

/// Товар с фото (sha256 — синтетический).
ProductSummary _withImage(int i) {
  final ProductSummary p = product(i);
  return ProductSummary(
    id: p.id,
    name: p.name,
    sku: p.sku,
    categoryId: p.categoryId,
    brand: p.brand,
    defaultVariantId: p.defaultVariantId,
    baseUnit: p.baseUnit,
    price: p.price,
    stock: p.stock,
    primaryImage: ProductImageRef(
      sha256: 'sha-$i',
      thumbUrl: 'http://img.test/images/sha-$i/thumb.webp',
      cardUrl: 'http://img.test/images/sha-$i/card.webp',
      isPrimary: true,
    ),
  );
}

/// Кнопка корзины шапки со счётчиком монтирований (кнопка-итог и drawer корзины не должны пересоздаваться при смене
/// категории и поиска — 02 SCR-10.5/SCR-12.5; ADR-112: постоянной CP больше нет, корзина — кнопка в шапке).
final class _CartMounts {
  int mounts = 0;
  int disposes = 0;
}

class _FakeCartButton extends StatefulWidget {
  const _FakeCartButton(this.counter);

  final _CartMounts counter;

  @override
  State<_FakeCartButton> createState() => _FakeCartButtonState();
}

class _FakeCartButtonState extends State<_FakeCartButton> {
  @override
  void initState() {
    super.initState();
    widget.counter.mounts++;
  }

  @override
  void dispose() {
    widget.counter.disposes++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 120, height: 44, child: Text('Корзина (тест)'));
}

/// Снимок идентичности частей экрана (видимых, onstage).
final class _Snapshot {
  _Snapshot(WidgetTester tester)
    : workspace = _one<State>(tester, find.byType(CatalogWorkspace), (Element e) => (e as StatefulElement).state),
      header = _one<Element>(tester, find.byType(CatalogHeader), (Element e) => e),
      sidebar = _one<State>(tester, find.byType(CatalogSidebar), (Element e) => (e as StatefulElement).state),
      toolbar = _one<Element>(tester, find.byType(CatalogToolbarControls), (Element e) => e),
      image = _one<Element>(
        tester,
        find.descendant(of: find.byKey(const ValueKey<String>('product-p1')), matching: find.byType(Image)),
        (Element e) => e,
      );

  final State? workspace;
  final Element? header;
  final State? sidebar;
  final Element? toolbar;
  final Element? image;

  static T? _one<T>(WidgetTester tester, Finder f, T Function(Element e) pick) {
    final List<Element> list = f.evaluate().toList();
    return list.isEmpty ? null : pick(list.last);
  }

  /// Какие части пересоздались относительно [before].
  Map<String, bool> remountedSince(_Snapshot before) => <String, bool>{
    'workspace': !identical(workspace, before.workspace),
    'header': !identical(header, before.header),
    'sidebar': !identical(sidebar, before.sidebar),
    'toolbar': !identical(toolbar, before.toolbar),
    'productImage(p1)': !identical(image, before.image),
  };
}

/// Результат одного перехода.
final class _Step {
  _Step(this.name);

  final String name;
  int transitionFrames = 0;
  int transitionWidgetFrames = 0;
  int skeletonFrames = 0;
  int refreshBarFrames = 0;
  int networkCalls = 0;
  Map<String, bool> remounted = const <String, bool>{};

  @override
  String toString() =>
      '$name: transitionFrames=$transitionFrames, transitionWidgets=$transitionWidgetFrames, '
      'skeletonFrames=$skeletonFrames, refreshBarFrames=$refreshBarFrames, networkCalls=$networkCalls, '
      'remounted=${remounted.entries.where((MapEntry<String, bool> e) => e.value).map((MapEntry<String, bool> e) => e.key).toList()}';
}

/// Хоть один маршрут с рабочим пространством анимирует переход (основная или вторичная анимация).
bool _routeAnimating(WidgetTester tester) {
  for (final Element e in find.byType(CatalogWorkspace, skipOffstage: false).evaluate()) {
    final ModalRoute<Object?>? r = ModalRoute.of(e);
    if (r == null) {
      continue;
    }
    if ((r.animation?.isAnimating ?? false) || (r.secondaryAnimation?.isAnimating ?? false)) {
      return true;
    }
  }
  return false;
}

/// Страница рабочего пространства обёрнута переходом Material (Zoom на Windows/Linux) внутри навигатора ветки:
/// предки видимого CatalogWorkspace до ближайшего Navigator.
bool _transitionWidgets() {
  for (final Element e in find.byType(CatalogWorkspace).evaluate()) {
    bool zoom = false;
    e.visitAncestorElements((Element a) {
      if (a.widget is Navigator) {
        return false;
      }
      if (a.widget.runtimeType.toString().contains('ZoomPageTransition')) {
        zoom = true;
        return false;
      }
      return true;
    });
    if (zoom) {
      return true;
    }
  }
  return false;
}

Future<void> _pumpApp(WidgetTester tester, CatalogHarness h, GoRouter router) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[...h.overrides, appModeProvider.overrideWithValue(AppMode.seller)],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: EdgeInsets.zero),
          child: ProductImageScope(providerFor: transparentImage, child: child!),
        ),
      ),
    ),
  );
  await settle(tester, frames: 10);
}

/// Тап и покадровое наблюдение 40 кадров по 16 мс (≈ 640 мс — дольше перехода 300 мс и загрузки).
Future<_Step> _observe(WidgetTester tester, CatalogHarness h, String name, Future<void> Function() action) async {
  final _Step step = _Step(name);
  final _Snapshot before = _Snapshot(tester);
  final int calls = h.catalog.productCalls.length;
  await action();
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (_routeAnimating(tester)) {
      step.transitionFrames++;
    }
    if (_transitionWidgets()) {
      step.transitionWidgetFrames++;
    }
    if (find.byKey(_skeleton).evaluate().isNotEmpty) {
      step.skeletonFrames++;
    }
    if (find.byKey(_refreshBar).evaluate().isNotEmpty) {
      step.refreshBarFrames++;
    }
  }
  step.networkCalls = h.catalog.productCalls.length - calls;
  step.remounted = _Snapshot(tester).remountedSince(before);
  debugPrint('[stability] $step');
  return step;
}

CatalogHarness _harness({required _CartMounts cart, int count = 6}) {
  final List<ProductSummary> items = <ProductSummary>[for (int i = 1; i <= count; i++) _withImage(i)];
  final FakeCatalogRepository repo = FakeCatalogRepository(items: items)
    // Тёплый старт: товары уже в локальном кэше (drift) — 02 SCR-10.7 «Загрузка (тёплая)».
    ..cached = Success<CatalogPage<ProductSummary>>(page(items, source: DataSource.cache));
  return CatalogHarness(
    catalog: repo,
    extra: <Override>[catalogCartButtonProvider.overrideWithValue((BuildContext c) => _FakeCartButton(cart))],
  );
}

GoRouter _appRouter(String initial) => GoRouter(routes: $appRoutes, initialLocation: initial);

String _location(GoRouter r) => r.routeInformationProvider.value.uri.toString();

/// Windows: переходы Material по умолчанию — ZoomPageTransitionsBuilder (как у кассы на ПК).
final TargetPlatformVariant _windows = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  testWidgets('expanded: /catalog → «А» → «Б» — без перехода страницы, пересоздания и скелетона, 1 запрос', (
    tester,
  ) async {
    setWindow(tester, kExpanded);
    final _CartMounts cart = _CartMounts();
    final CatalogHarness h = _harness(cart: cart);
    final GoRouter router = _appRouter('/catalog');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('product-p1')), findsOneWidget);
    final int cartMountsAtStart = cart.mounts;

    final _Step toA = await _observe(
      tester,
      h,
      'root→А',
      () => tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-mix'))),
    );
    expect(_location(router), '/catalog/c/c-mix');
    expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);

    final _Step toB = await _observe(
      tester,
      h,
      'А→Б',
      () => tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-sanitary'))),
    );
    expect(_location(router), '/catalog/c/c-sanitary');
    expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);

    for (final _Step s in <_Step>[toA, toB]) {
      expect(s.transitionFrames, 0, reason: '${s.name}: страница не анимируется (ANIM-024: SB и CP не анимируются)');
      expect(s.transitionWidgetFrames, 0, reason: '${s.name}: нет Zoom-перехода всей страницы');
      expect(s.skeletonFrames, 0, reason: '${s.name}: данные есть в кэше — скелетона сетки нет');
      expect(s.networkCalls, 1, reason: '${s.name}: ровно один запрос списка на смену категории');
      expect(s.remounted, <String, bool>{
        'workspace': false,
        'header': false,
        'sidebar': false,
        'toolbar': false,
        'productImage(p1)': false,
      }, reason: '${s.name}: шапка, SB, панель инструментов, рабочее пространство и фото не пересоздаются');
    }
    expect(cartMountsAtStart, 1, reason: 'кнопка корзины в шапке смонтирована');
    expect(cart.mounts, cartMountsAtStart, reason: 'кнопка корзины в шапке не пересоздаётся');
    expect(cart.disposes, 0);
  }, variant: _windows);

  testWidgets('expanded: при смене категории прежние карточки остаются, пока идёт загрузка (тонкая полоса)', (
    tester,
  ) async {
    setWindow(tester, kExpanded);
    final _CartMounts cart = _CartMounts();
    final CatalogHarness h = _harness(cart: cart);
    // Холодная категория: кэша нет, сеть задержана.
    final GoRouter router = _appRouter('/catalog/c/c-mix');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    expect(find.byKey(const ValueKey<String>('product-p1')), findsOneWidget);
    h.catalog.cached = Success<CatalogPage<ProductSummary>>(page(const <ProductSummary>[], source: DataSource.cache));
    h.catalog.gate.hold();
    await tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-sanitary')));
    await settle(tester);
    expect(find.byKey(_skeleton), findsNothing, reason: 'полносеточный скелетон — только при первой загрузке');
    expect(find.byKey(const ValueKey<String>('product-p1')), findsOneWidget, reason: 'прежние карточки на месте');
    expect(find.byKey(_refreshBar), findsOneWidget, reason: 'локальный индикатор загрузки в области списка');
    h.catalog.gate.release();
    await settle(tester);
    expect(find.byKey(_refreshBar), findsNothing);
    expect(find.text('Найдено: 6 товаров'), findsOneWidget);
  }, variant: _windows);

  testWidgets('expanded: вид «Список» и CP сохраняются при смене категории; подкатегория — go без новой записи', (
    tester,
  ) async {
    setWindow(tester, kExpanded);
    final _CartMounts cart = _CartMounts();
    final CatalogHarness h = _harness(cart: cart);
    final GoRouter router = _appRouter('/catalog/c/c-mix');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    await tester.tap(find.byKey(const ValueKey<String>('view-mode-list')));
    await settle(tester);
    expect(find.byType(ProductImage), findsWidgets);
    final State ws = tester.state(find.byType(CatalogWorkspace));
    final int mounts = cart.mounts;

    await tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-sanitary')));
    await settle(tester);
    expect(_location(router), startsWith('/catalog/c/c-sanitary'));
    expect(_location(router), contains('view=list'), reason: 'вид переносится (navigation.md §3)');
    expect(find.byKey(const ValueKey<String>('product-p1')), findsOneWidget);
    expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue);
    expect(cart.mounts, mounts, reason: 'кнопка корзины в шапке не пересоздаётся');

    // Подкатегория на expanded — `go` (замена), «Назад» к родителю — крошками (02 SCR-12.4).
    router.go('/catalog/c/c-mix');
    await settle(tester);
    final int matches = router.routerDelegate.currentConfiguration.matches.length;
    await tester.tap(find.byKey(const ValueKey<String>('chip-sub-c-mix-kitchen')));
    await settle(tester);
    expect(_location(router), startsWith('/catalog/c/c-mix-kitchen'));
    expect(router.routerDelegate.currentConfiguration.matches.length, matches, reason: 'без новой записи истории');
    expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue);
    expect(find.byType(CatalogBreadcrumbs), findsOneWidget, reason: 'путь к родителю — крошки');
    await tester.tap(find.descendant(of: find.byType(CatalogBreadcrumbs), matching: find.text('Смесители')));
    await settle(tester);
    expect(_location(router), startsWith('/catalog/c/c-mix'));
    expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue);
    expect(cart.disposes, 0);
  }, variant: _windows);

  testWidgets('expanded: поиск в категории → SCR-11 поверх SCR-12, «Назад» — в ту же категорию без пересоздания', (
    tester,
  ) async {
    setWindow(tester, kExpanded);
    final _CartMounts cart = _CartMounts();
    final CatalogHarness h = _harness(cart: cart);
    final GoRouter router = _appRouter('/catalog');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    await tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-sanitary')));
    await settle(tester);
    final State category = tester.state(find.byType(CatalogWorkspace));
    final State sidebar = tester.state(find.byType(CatalogSidebar));
    final State cartButton = tester.state(find.byType(_FakeCartButton));

    final Finder field = find.descendant(
      of: find.byKey(const ValueKey<String>('catalog-search-field')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, 'смеситель');
    await tester.pump(const Duration(milliseconds: 310));
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('stub-SCR-11')), findsOneWidget);
    // Запись SCR-11 открыта `push` поверх SCR-12; экран рисует страница `/catalog` — адрес верхней записи стека.
    final Uri searchUri = router.state.uri;
    expect(searchUri.queryParameters, <String, String>{'q': 'смеситель', 'categoryId': 'c-sanitary'});
    expect(h.search.calls.last.filter.categoryId, 'c-sanitary', reason: 'поиск в пределах категории (UI-11-009)');
    expect(find.byKey(const ValueKey<String>('chip-search-scope')), findsOneWidget);
    expect(identical(tester.state(find.byType(CatalogWorkspace)), category), isTrue, reason: 'SCR-11 — тот же экран');
    expect(identical(tester.state(find.byType(CatalogSidebar)), sidebar), isTrue, reason: 'колонка категорий та же');
    expect(
      identical(tester.state(find.byType(_FakeCartButton)), cartButton),
      isTrue,
      reason: 'кнопка корзины не пересоздаётся',
    );
    expect(router.canPop(), isTrue, reason: 'push: «Назад» — в категорию');
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'catalog-search',
      reason: 'фокус остаётся в поле поиска (ввод и HID-сканер не прерываются)',
    );

    router.pop();
    await settle(tester);
    expect(_location(router), '/catalog/c/c-sanitary');
    expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);
    expect(identical(tester.state(find.byType(CatalogWorkspace)), category), isTrue, reason: 'SCR-12 тот же');
    expect(identical(tester.state(find.byType(CatalogSidebar)), sidebar), isTrue);
    expect(
      identical(tester.state(find.byType(_FakeCartButton)), cartButton),
      isTrue,
      reason: 'кнопка корзины категории та же',
    );
    expect(
      tester.widget<EditableText>(field).controller.text,
      isEmpty,
      reason: 'в категории без поиска строка поиска пустая (не «смеситель»)',
    );
  }, variant: _windows);

  testWidgets('expanded: поиск из шапки SCR-10 → SCR-11 без пересоздания экрана; лого — назад к каталогу', (
    tester,
  ) async {
    setWindow(tester, kExpanded);
    final CatalogHarness h = _harness(cart: _CartMounts());
    final GoRouter router = _appRouter('/catalog');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    final State ws = tester.state(find.byType(CatalogWorkspace));
    final Finder field = find.descendant(
      of: find.byKey(const ValueKey<String>('catalog-search-field')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, 'см');
    await tester.pump(const Duration(milliseconds: 310));
    await settle(tester);
    expect(_location(router), '/catalog/search?q=%D1%81%D0%BC');
    expect(find.byKey(const ValueKey<String>('stub-SCR-11')), findsOneWidget);
    expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue, reason: 'тот же экземпляр');
    expect(tester.widget<EditableText>(field).controller.text, 'см', reason: 'набранный текст не сбрасывается');

    await tester.tap(find.byType(CatalogLogo).first);
    await settle(tester);
    expect(_location(router), '/catalog');
    expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);
    expect(tester.widget<EditableText>(field).controller.text, isEmpty, reason: 'строка поиска очищается на SCR-10');
    expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue);
  }, variant: _windows);

  testWidgets(
    'medium: /catalog → «А» без анимации страницы; «А» → «Б» — тот же экран (go, стабильный ключ страницы)',
    (tester) async {
      setWindow(tester, kMedium);
      final CatalogHarness h = _harness(cart: _CartMounts());
      final GoRouter router = _appRouter('/catalog');
      addTearDown(router.dispose);
      await _pumpApp(tester, h, router);
      // medium (прототип 2026-10-29, ADR-112): корни — колонка плиток 132, как на expanded; полосы корней нет.
      expect(find.byKey(const ValueKey<String>('chip-cat-c-mix')), findsNothing);
      final _Step toA = await _observe(
        tester,
        h,
        'medium root→А',
        () => tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-mix'))),
      );
      expect(_location(router), '/catalog/c/c-mix');
      expect(toA.transitionFrames, 0, reason: 'medium: страница без анимации перехода');
      expect(toA.transitionWidgetFrames, 0);
      expect(toA.skeletonFrames, 0, reason: 'настройки и кэш — без кадра скелетона');
      expect(toA.networkCalls, 1);
      expect(toA.remounted['workspace'], isFalse, reason: 'medium: тот же экран, что и на /catalog (одна страница)');
      expect(toA.remounted['header'], isFalse);
      expect(toA.remounted['sidebar'], isFalse, reason: 'medium: колонка категорий не пересоздаётся');
      expect(toA.remounted['toolbar'], isFalse);

      final _Step toB = await _observe(
        tester,
        h,
        'medium А→Б',
        () => tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-sanitary'))),
      );
      expect(_location(router), startsWith('/catalog/c/c-sanitary'));
      expect(toB.transitionFrames, 0);
      expect(toB.skeletonFrames, 0);
      expect(toB.networkCalls, 1);
      expect(toB.remounted['workspace'], isFalse, reason: 'та же страница категории обновлена, не заменена');
      expect(toB.remounted['header'], isFalse);
      expect(toB.remounted['sidebar'], isFalse);
      expect(toB.remounted['toolbar'], isFalse);
      expect(toB.remounted['productImage(p1)'], isFalse);
    },
    variant: _windows,
  );

  testWidgets('expanded: «Назад» из поиска в категории — к прежней прокрутке списка категории', (tester) async {
    setWindow(tester, kExpanded);
    final CatalogHarness h = _harness(cart: _CartMounts(), count: 40);
    final GoRouter router = _appRouter('/catalog/c/c-sanitary');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    final ScrollController list = tester
        .widget<CustomScrollView>(find.byKey(const ValueKey<String>('catalog-products')))
        .controller!;
    list.jumpTo(600);
    await settle(tester);
    final Finder field = find.descendant(
      of: find.byKey(const ValueKey<String>('catalog-search-field')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, 'смеситель');
    await tester.pump(const Duration(milliseconds: 310));
    await settle(tester, frames: 10);
    expect(find.byKey(const ValueKey<String>('stub-SCR-11')), findsOneWidget);
    expect(list.offset, 0, reason: 'новая выборка (поиск) — с начала');
    router.pop();
    await settle(tester, frames: 10);
    expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);
    expect(list.offset, 600, reason: '«Назад» — к прежней позиции категории (02 SCR-11.6)');
  }, variant: _windows);

  testWidgets(
    'смена класса окна expanded ↔ medium на /catalog/c/{id} — тот же экран, набранный текст сохраняется',
    (tester) async {
      setWindow(tester, kExpanded);
      final CatalogHarness h = _harness(cart: _CartMounts());
      final GoRouter router = _appRouter('/catalog/c/c-mix');
      addTearDown(router.dispose);
      await _pumpApp(tester, h, router);
      final State ws = tester.state(find.byType(CatalogWorkspace));
      final Finder field = find.descendant(
        of: find.byKey(const ValueKey<String>('catalog-search-field')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(field, 'с');
      await settle(tester);
      setWindow(tester, kMedium);
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);
      expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue, reason: 'medium: тот же экземпляр');
      expect(tester.widget<EditableText>(field).controller.text, 'с', reason: 'набранный текст не теряется');
      setWindow(tester, kExpanded);
      await settle(tester);
      expect(
        identical(tester.state(find.byType(CatalogWorkspace)), ws),
        isTrue,
        reason: 'обратно на expanded — тот же',
      );
      expect(tester.widget<EditableText>(field).controller.text, 'с');
      expect(_location(router), '/catalog/c/c-mix');
    },
    variant: _windows,
  );

  testWidgets(
    'expanded: прямая ссылка на поиск в категории — смена вида оставляет SCR-11 (replace только для push)',
    (tester) async {
      setWindow(tester, kExpanded);
      final CatalogHarness h = _harness(cart: _CartMounts());
      final GoRouter router = _appRouter('/catalog/search?q=смеситель&categoryId=c-sanitary');
      addTearDown(router.dispose);
      await _pumpApp(tester, h, router);
      expect(find.byKey(const ValueKey<String>('stub-SCR-11')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('view-mode-list')));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('stub-SCR-11')), findsOneWidget, reason: 'экран поиска не пропадает');
      expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsNothing);
      expect(router.state.uri.path, '/catalog/search');
      expect(router.state.uri.queryParameters['view'], 'list');
      expect(router.state.uri.queryParameters['categoryId'], 'c-sanitary');
    },
    variant: _windows,
  );

  testWidgets('expanded: пока грузится новая категория, прежние карточки неактивны, «Найдено» — прежнее', (
    tester,
  ) async {
    setWindow(tester, kExpanded);
    final CatalogHarness h = _harness(cart: _CartMounts());
    final GoRouter router = _appRouter('/catalog/c/c-mix');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    bool inert() =>
        tester.widget<SliverIgnorePointer>(find.byKey(const ValueKey<String>('catalog-cards-sliver'))).ignoring;
    expect(inert(), isFalse);
    h.catalog.cached = Success<CatalogPage<ProductSummary>>(page(const <ProductSummary>[], source: DataSource.cache));
    h.catalog.gate.hold();
    await tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-sanitary')));
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('product-p1')), findsOneWidget, reason: 'прежние карточки на месте');
    expect(inert(), isTrue, reason: 'карточки прежней выборки не нажимаются (нельзя добавить товар не из категории)');
    expect(find.text('Найдено: 6 товаров'), findsOneWidget, reason: 'подзаголовок не мигает полосой-скелетоном');
    h.catalog.gate.release();
    await settle(tester);
    expect(inert(), isFalse);
  }, variant: _windows);

  testWidgets('medium: подкатегория — push в тот же экран, системная «Назад» — к родителю', (tester) async {
    setWindow(tester, kMedium);
    final CatalogHarness h = _harness(cart: _CartMounts());
    final GoRouter router = _appRouter('/catalog/c/c-mix');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    final State ws = tester.state(find.byType(CatalogWorkspace));
    final _Step toSub = await _observe(
      tester,
      h,
      'medium А→подкатегория',
      () => tester.tap(find.byKey(const ValueKey<String>('chip-sub-c-mix-kitchen'))),
    );
    expect(router.state.uri.path, '/catalog/c/c-mix-kitchen');
    expect(router.canPop(), isTrue, reason: 'push (02 SCR-12.6, navigation.md)');
    expect(toSub.transitionFrames, 0);
    expect(toSub.skeletonFrames, 0);
    expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue, reason: 'тот же экран');
    // Страница `/catalog` под записями без содержимого — активный экран (F4 корзины, клавиши CP).
    final BuildContext wsContext = tester.element(find.byType(CatalogWorkspace));
    expect(ModalRoute.of(wsContext)!.isCurrent, isFalse);
    expect(dsRouteIsCurrent(wsContext), isTrue);
    final bool handled = await tester.binding.handlePopRoute();
    await settle(tester);
    expect(handled, isTrue);
    expect(_location(router), '/catalog/c/c-mix', reason: '«Назад» — к родительской категории, не к /catalog');
    expect(router.state.uri.path, '/catalog/c/c-mix');
    expect(identical(tester.state(find.byType(CatalogWorkspace)), ws), isTrue);
    unawaited(router.push<Object?>('/catalog/p/p1'));
    await settle(tester, frames: 30);
    expect(
      dsRouteIsCurrent(tester.element(find.byType(CatalogWorkspace, skipOffstage: false))),
      isFalse,
      reason: 'под карточкой товара экран каталога не активен',
    );
  }, variant: _windows);

  testWidgets('compact: новый экран категории не показывает карточки корня до своей выборки (скелетон)', (
    tester,
  ) async {
    setWindow(tester, kCompact);
    final CatalogHarness h = _harness(cart: _CartMounts());
    final GoRouter router = _appRouter('/catalog');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    expect(find.byKey(const ValueKey<String>('product-p1')), findsOneWidget);
    h.catalog.cached = Success<CatalogPage<ProductSummary>>(page(const <ProductSummary>[], source: DataSource.cache));
    h.catalog.gate.hold();
    unawaited(router.push<Object?>('/catalog/c/c-sanitary'));
    await settle(tester, frames: 30);
    final Finder scr12 = find.byWidgetPredicate(
      (Widget w) => w is CatalogWorkspace && w.mode == CatalogScreenMode.category,
    );
    expect(scr12, findsOneWidget);
    expect(
      find.descendant(of: scr12, matching: find.byKey(const ValueKey<String>('product-p1'))),
      findsNothing,
      reason: 'товары корня под заголовком категории не показываются',
    );
    expect(find.descendant(of: scr12, matching: find.byKey(_skeleton)), findsOneWidget);
    h.catalog.gate.release();
    await settle(tester, frames: 10);
    expect(find.descendant(of: scr12, matching: find.byKey(const ValueKey<String>('product-p1'))), findsOneWidget);
  }, variant: _windows);

  testWidgets('плитки колонки и ленты — с действием «нажать» для screen reader', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    setWindow(tester, kExpanded);
    final CatalogHarness h = _harness(cart: _CartMounts());
    final GoRouter router = _appRouter('/catalog/c/c-mix');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    for (final String key in <String>['sidebar-category-c-sanitary', 'chip-sub-c-mix-kitchen']) {
      final SemanticsData d = tester.getSemantics(find.byKey(ValueKey<String>(key))).getSemanticsData();
      expect(d.hasAction(SemanticsAction.tap), isTrue, reason: '$key: выбор категории доступен TalkBack/Narrator');
    }
    semantics.dispose();
  }, variant: _windows);

  testWidgets('compact: категория — push, «Назад» возвращает в каталог (navigation.md SCR-10 → SCR-12)', (
    tester,
  ) async {
    setWindow(tester, kCompact);
    final CatalogHarness h = _harness(cart: _CartMounts());
    final GoRouter router = _appRouter('/catalog');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    await tester.tap(find.byKey(const ValueKey<String>('chip-all-categories')));
    await settle(tester, frames: 30);
    await tester.tap(find.byKey(const ValueKey<String>('category-tile-c-mix')));
    await settle(tester, frames: 30);
    expect(router.canPop(), isTrue, reason: 'push: есть куда вернуться');
    expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);
    expect(
      GoRouterState.of(tester.element(find.byKey(const ValueKey<String>('stub-SCR-12')))).uri.path,
      '/catalog/c/c-mix',
    );
    router.pop();
    await settle(tester, frames: 30);
    expect(_location(router), '/catalog');
    expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);
  }, variant: _windows);
}

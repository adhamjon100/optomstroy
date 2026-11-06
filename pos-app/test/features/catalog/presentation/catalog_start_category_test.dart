// T-CAT-040 (ADR-114 решение 4, 02 П.3 п. 11, AC-UI-10-033): каталог сотрудника на medium и шире всегда открыт на
// корневой категории — при первом входе на корне с наибольшим `productCount` (при равенстве — первом по `sortOrder`),
// затем на последнем открытом этим пользователем корне (`catalog_last_root`); «Все товары» — `/catalog?all=1` по
// заголовку «Каталог» колонки (лента — корневые категории); compact и `customer` — без перехода. Поиск в категории —
// «Поиск: «q»», корень выделен, лента корня с выбранной «Все товары»; крошки — только при глубине ≥ 3. Переход на
// стартовую категорию — только пока каталог виден на голом `/catalog`: уход в другой раздел оболочки до перехода
// (настройки или дерево дочитаны позже, уход в том же кадре) адрес раздела не меняет, возврат вкладкой — тот же переход
// (регрессия integration 2026-11-06, cashier_flow_test SCR-47).
// Настоящие маршруты приложения (`$appRoutes`), фейки каталога (данные синтетические). Ревью RP-02: число избранных
// после входа — по серверу (кэш избранного обновляется при подписке, а не только на SCR-40).
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/category_tile.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logo.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_sidebar.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_toolbar.dart';

import '../../admin/support/fake_admin_repository.dart' show FakeAdminUsersRepository;
import '../../admin/support/fake_admin_settings.dart' show FakeAuditLogRepository;
import 'support/catalog_fakes.dart';

GoRouter _appRouter(String initial) => GoRouter(routes: $appRoutes, initialLocation: initial);

String _location(GoRouter r) => r.routeInformationProvider.value.uri.toString();

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
          data: MediaQuery.of(context).copyWith(padding: EdgeInsets.zero, disableAnimations: true),
          child: ProductImageScope(providerFor: transparentImage, child: child!),
        ),
      ),
    ),
  );
  await settle(tester, frames: 10);
}

bool _tileSelected(WidgetTester tester, String key) =>
    tester.widget<CategoryTile>(find.byKey(ValueKey<String>(key))).selected;

String? _title(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey<String>('catalog-title'))).data;

/// Запросы списка товаров без категории — весь каталог.
int _wholeCatalogCalls(CatalogHarness h) =>
    h.catalog.productCalls.where((CatalogQuery q) => q.filter.categoryId == null).length +
    h.catalog.cachedCalls.where((CatalogQuery q) => q.filter.categoryId == null).length;

/// Порт полки с обновлением кэша избранного с сервера (как `FavoritesCatalogShelf`): кэш до обновления пуст.
final class _RefreshingShelf implements CatalogShelfPort, CatalogFavoritesRefresh {
  _RefreshingShelf(this.server);

  final Set<String> server;
  final Set<String> cache = <String>{};
  int refreshCalls = 0;
  final StreamController<Set<String>> _ids = StreamController<Set<String>>.broadcast();

  @override
  Stream<Set<String>> watchFavoriteIds() async* {
    yield Set<String>.of(cache);
    yield* _ids.stream;
  }

  @override
  Future<void> refreshFavorites() async {
    refreshCalls++;
    cache
      ..clear()
      ..addAll(server);
    _ids.add(Set<String>.of(cache));
  }

  @override
  Future<Result<void>> setFavorite(String productId, {required bool favorite}) async => const Success<void>(null);

  @override
  Future<Result<List<RecentProduct>>> recentProducts({int limit = 5}) async =>
      const Success<List<RecentProduct>>(<RecentProduct>[]);

  @override
  Future<Result<void>> clearRecent() async => const Success<void>(null);

  Future<void> dispose() => _ids.close();
}

/// Настройки каталога, чтение которых задерживается до [release] (как медленное чтение drift `settings` после входа).
final class _SlowPrefs implements CatalogPrefs {
  final InMemoryCatalogPrefs _inner = InMemoryCatalogPrefs();
  final Completer<void> _ready = Completer<void>();

  void release() => _ready.complete();

  @override
  Future<ProductViewMode?> viewMode(WindowClass windowClass) => _inner.viewMode(windowClass);

  @override
  Future<void> setViewMode(WindowClass windowClass, ProductViewMode mode) => _inner.setViewMode(windowClass, mode);

  @override
  Future<CatalogSort?> sort({required bool search}) async {
    await _ready.future;
    return _inner.sort(search: search);
  }

  @override
  Future<void> setSort(CatalogSort sort, {required bool search}) => _inner.setSort(sort, search: search);

  @override
  Future<bool?> sidebarCollapsed() => _inner.sidebarCollapsed();

  @override
  Future<void> setSidebarCollapsed(bool value) => _inner.setSidebarCollapsed(value);

  @override
  Future<String?> lastRoot() => _inner.lastRoot();

  @override
  Future<void> setLastRoot(String categoryId) => _inner.setLastRoot(categoryId);
}

/// Раздел другой ветки оболочки, в который сотрудник уходит из каталога (SCR-47, как в регрессии integration).
const String _awayLocation = '/admin/audit';

/// Фейки SCR-47 (журнал и список сотрудников фильтра) — раздел [_awayLocation] строится без сети.
List<Override> _awayOverrides() => <Override>[
  adminUsersRepositoryProvider.overrideWithValue(FakeAdminUsersRepository()),
  auditLogRepositoryProvider.overrideWithValue(FakeAuditLogRepository()),
];

/// Запросы списка товаров стартовой категории (запрос скрытого каталога — признак перехода из другого раздела).
int _startCategoryCalls(CatalogHarness h, String id) =>
    h.catalog.productCalls.where((CatalogQuery q) => q.filter.categoryId == id).length +
    h.catalog.cachedCalls.where((CatalogQuery q) => q.filter.categoryId == id).length;

/// Вернуться в ветку «Каталог» вкладкой оболочки (`goBranch` — сохранённый адрес ветки, голый `/catalog`).
void _goCatalogBranch(WidgetTester tester) =>
    tester.widget<StatefulNavigationShell>(find.byType(StatefulNavigationShell)).goBranch(0);

void main() {
  test('RP-02: число избранных после входа — по серверу; кэш обновляется один раз на пользователя', () async {
    final _RefreshingShelf shelf = _RefreshingShelf(<String>{'SL1001'});
    addTearDown(shelf.dispose);
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        catalogShelfPortProvider.overrideWithValue(shelf),
        catalogSessionUserProvider.overrideWithValue('u-907'),
      ],
    );
    addTearDown(c.dispose);
    final ProviderSubscription<AsyncValue<Set<String>>> sub = c.listen(
      catalogFavoriteIdsProvider,
      (AsyncValue<Set<String>>? _, AsyncValue<Set<String>> _) {},
    );
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(c.read(catalogFavoriteIdsProvider).value, <String>{'SL1001'});
    expect(shelf.refreshCalls, 1);
    await pumpEventQueue();
    expect(shelf.refreshCalls, 1, reason: 'повторно — только при смене пользователя или порта');
  });

  group('catalogStartRoot — правило стартовой категории', () {
    const Category a = Category(id: 'a', name: 'Отопление', productCount: 40, sortOrder: 10);
    const Category b = Category(id: 'b', name: 'Сантехника', productCount: 12, sortOrder: 20);
    const Category c = Category(id: 'c', name: 'Водоснабжение', productCount: 40, sortOrder: 30);

    test('первый вход — наибольший productCount, при равенстве — первый по sortOrder', () {
      expect(catalogStartRoot(const <Category>[a, b, c])?.id, 'a');
      expect(catalogStartRoot(const <Category>[c, b, a])?.id, 'a', reason: 'порядок списка не важен — sortOrder');
      expect(
        catalogStartRoot(const <Category>[
          Category(id: 'x', name: 'X', productCount: 3),
          Category(id: 'y', name: 'Y', productCount: 12, sortOrder: 5),
          Category(id: 'z', name: 'Z', productCount: 7),
        ])?.id,
        'y',
      );
    });

    test('равные productCount и sortOrder — первый в порядке дерева; все пустые — первый по sortOrder', () {
      const Category p = Category(id: 'p', name: 'П', productCount: 5, sortOrder: 1);
      const Category q = Category(id: 'q', name: 'Q', productCount: 5, sortOrder: 1);
      expect(catalogStartRoot(const <Category>[p, q])?.id, 'p');
      expect(
        catalogStartRoot(const <Category>[
          Category(id: 'e1', name: 'E1', sortOrder: 2),
          Category(id: 'e2', name: 'E2', sortOrder: 1),
        ])?.id,
        'e2',
      );
    });

    test('последний открытый корень — если он ещё есть в дереве; иначе правило первого входа', () {
      expect(catalogStartRoot(const <Category>[a, b, c], lastRootId: 'b')?.id, 'b');
      expect(catalogStartRoot(const <Category>[a, b, c], lastRootId: 'deleted')?.id, 'a');
    });

    test('пустое дерево — null (откат к «Все товары»)', () {
      expect(catalogStartRoot(const <Category>[]), isNull);
      expect(catalogStartRoot(const <Category>[], lastRootId: 'a'), isNull);
    });
  });

  group('/catalog сотрудника', () {
    testWidgets('expanded, первый вход: /catalog → корень с наибольшим числом товаров, без запроса всего каталога', (
      tester,
    ) async {
      setWindow(tester, kExpanded);
      final CatalogHarness h = CatalogHarness();
      final GoRouter router = _appRouter('/catalog');
      addTearDown(router.dispose);
      await _pumpApp(tester, h, router);

      expect(_location(router), '/catalog/c/c-mix', reason: 'Смесители — 124 товара, больше всех');
      expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);
      expect(_wholeCatalogCalls(h), 0, reason: 'список всего каталога не запрашивается');
      expect(_tileSelected(tester, 'sidebar-category-c-mix'), isTrue);
      expect(_title(tester), 'Смесители');
      // Лента — всегда: «Все товары» (выбрана) + непустые подкатегории.
      expect(find.byKey(const ValueKey<String>('catalog-subcategory-ribbon')), findsOneWidget);
      expect(_tileSelected(tester, 'chip-sub-all'), isTrue);
      expect(find.byKey(const ValueKey<String>('chip-sub-c-mix-kitchen')), findsOneWidget);
      expect(await h.prefs.lastRoot(), 'c-mix', reason: 'открытый корень запоминается');
    });

    testWidgets('последний открытый корень — при следующем открытии /catalog и после логотипа', (tester) async {
      setWindow(tester, kExpanded);
      final InMemoryCatalogPrefs prefs = InMemoryCatalogPrefs();
      await prefs.setLastRoot('c-sanitary');
      final CatalogHarness h = CatalogHarness(prefs: prefs);
      final GoRouter router = _appRouter('/catalog');
      addTearDown(router.dispose);
      await _pumpApp(tester, h, router);
      expect(_location(router), '/catalog/c/c-sanitary');
      expect(_tileSelected(tester, 'sidebar-category-c-sanitary'), isTrue);
      // Корень без подкатегорий — лента с одной «Все товары».
      expect(find.byKey(const ValueKey<String>('chip-sub-all')), findsOneWidget);
      expect(_title(tester), 'Санфаянс');

      await tester.tap(find.byKey(const ValueKey<String>('sidebar-category-c-mix')));
      await settle(tester);
      expect(_location(router), '/catalog/c/c-mix');
      expect(await prefs.lastRoot(), 'c-mix');

      // Подкатегория не меняет запомненный корень.
      await tester.tap(find.byKey(const ValueKey<String>('chip-sub-c-mix-kitchen')));
      await settle(tester);
      expect(_location(router), startsWith('/catalog/c/c-mix-kitchen'));
      expect(await prefs.lastRoot(), 'c-mix');
      expect(find.byType(CatalogBreadcrumbs), findsNothing, reason: 'крошки — только при глубине ≥ 3');
      expect(_title(tester), 'Смесители', reason: 'заголовок — родитель ленты');

      await tester.tap(find.byType(CatalogLogo));
      await settle(tester, frames: 10);
      expect(_location(router), '/catalog/c/c-mix', reason: 'логотип → /catalog → снова стартовая категория');
    });

    testWidgets('заголовок «Каталог» → «Все товары» (/catalog?all=1): лента — корни, ни одна плитка не выбрана', (
      tester,
    ) async {
      setWindow(tester, kExpanded);
      final CatalogHarness h = CatalogHarness();
      final GoRouter router = _appRouter('/catalog');
      addTearDown(router.dispose);
      await _pumpApp(tester, h, router);
      expect(_location(router), '/catalog/c/c-mix');

      await tester.tap(find.byKey(CatalogSidebar.allKey));
      await settle(tester, frames: 10);
      expect(_location(router), '/catalog?all=1');
      expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);
      expect(_title(tester), 'Все товары');
      expect(_tileSelected(tester, 'sidebar-category-c-mix'), isFalse);
      expect(_tileSelected(tester, 'chip-sub-all'), isTrue);
      expect(find.byKey(const ValueKey<String>('chip-sub-c-mix')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('chip-sub-c-sanitary')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('chip-sub-c-pipes')), findsNothing, reason: 'пустой корень не в ленте');
      expect(_wholeCatalogCalls(h), greaterThan(0), reason: '«Все товары» запрашивает весь каталог');
      final SemanticsHandle semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Каталог — все товары'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('/catalog?all=1 открывается без перехода', (tester) async {
      setWindow(tester, kExpanded);
      final CatalogHarness h = CatalogHarness();
      final GoRouter router = _appRouter('/catalog?all=1');
      addTearDown(router.dispose);
      await _pumpApp(tester, h, router);
      expect(_location(router), '/catalog?all=1');
      expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);
    });

    testWidgets('medium — тот же переход', (tester) async {
      setWindow(tester, kMedium);
      final CatalogHarness h = CatalogHarness();
      final GoRouter router = _appRouter('/catalog');
      addTearDown(router.dispose);
      await _pumpApp(tester, h, router);
      expect(_location(router), '/catalog/c/c-mix');
      expect(_wholeCatalogCalls(h), 0);
    });

    testWidgets('compact — /catalog открывается «Все товары», как прежде', (tester) async {
      setWindow(tester, kCompact);
      final CatalogHarness h = CatalogHarness();
      final GoRouter router = _appRouter('/catalog');
      addTearDown(router.dispose);
      await _pumpApp(tester, h, router);
      expect(_location(router), '/catalog');
      expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);
    });

    // Регрессия integration 2026-11-06 (cashier_flow_test, SCR-47): ветка «Каталог» остаётся смонтированной за другой
    // веткой оболочки; переход на стартовую категорию, назначенный после ухода в другой раздел, возвращал сотрудника
    // из раздела в каталог. Переход выполняется, только пока экран виден на голом `/catalog`; после возврата — тот же.
    group('T-CAT-040: уход в другой раздел до перехода на стартовую категорию', () {
      Future<void> expectStaysAway(WidgetTester tester, CatalogHarness h, GoRouter router) async {
        expect(_location(router), _awayLocation, reason: 'скрытый каталог не возвращает из другого раздела');
        expect(_startCategoryCalls(h, 'c-mix'), 0, reason: 'скрытый каталог не запрашивает стартовую категорию');
        expect(_wholeCatalogCalls(h), 0);
        // Возврат вкладкой — голый `/catalog` ветки и тот же переход на стартовую категорию.
        _goCatalogBranch(tester);
        await settle(tester, frames: 10);
        expect(_location(router), '/catalog/c/c-mix');
        expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);
        expect(_title(tester), 'Смесители');
        expect(_wholeCatalogCalls(h), 0);
      }

      testWidgets('настройки дочитаны после ухода — адрес раздела не меняется', (tester) async {
        setWindow(tester, kExpanded);
        final _SlowPrefs prefs = _SlowPrefs();
        final CatalogHarness h = CatalogHarness(prefs: prefs, extra: _awayOverrides());
        final GoRouter router = _appRouter('/catalog');
        addTearDown(router.dispose);
        await _pumpApp(tester, h, router);
        expect(_location(router), '/catalog', reason: 'настройки ещё читаются — переход не назначен');

        router.go(_awayLocation);
        await settle(tester, frames: 10);
        expect(_location(router), _awayLocation);
        prefs.release();
        await settle(tester, frames: 10);
        await expectStaysAway(tester, h, router);
      });

      testWidgets('дерево категорий пришло после ухода — адрес раздела не меняется', (tester) async {
        setWindow(tester, kExpanded);
        final CatalogHarness h = CatalogHarness(extra: _awayOverrides());
        h.catalog.treeGate.hold();
        final GoRouter router = _appRouter('/catalog');
        addTearDown(router.dispose);
        await _pumpApp(tester, h, router);
        expect(_location(router), '/catalog', reason: 'дерево ещё грузится — переход не назначен');

        router.go(_awayLocation);
        await settle(tester, frames: 10);
        h.catalog.treeGate.release();
        await settle(tester, frames: 10);
        await expectStaysAway(tester, h, router);
      });

      testWidgets('уход в том же кадре, в котором назначен переход, — переход отменяется', (tester) async {
        setWindow(tester, kExpanded);
        final CatalogHarness h = CatalogHarness(extra: _awayOverrides());
        h.catalog.treeGate.hold();
        final GoRouter router = _appRouter('/catalog');
        addTearDown(router.dispose);
        await _pumpApp(tester, h, router);
        expect(_location(router), '/catalog');

        // Дерево пришло: экран перестраивается в следующем кадре и назначает переход после кадра; уход в другой раздел
        // выполняется раньше в том же кадре (обратный вызов зарегистрирован до перестроения).
        h.catalog.treeGate.release();
        await tester.idle();
        bool left = false;
        WidgetsBinding.instance.addPostFrameCallback((Duration _) {
          left = true;
          router.go(_awayLocation);
        });
        await tester.pump();
        expect(left, isTrue);
        await settle(tester, frames: 10);
        await expectStaysAway(tester, h, router);
      });
    });

    testWidgets('пустое дерево — «Все товары»', (tester) async {
      setWindow(tester, kExpanded);
      final FakeCatalogRepository repo = FakeCatalogRepository(
        items: products(3),
        tree: const CategoryTree(roots: <Category>[]),
      );
      final CatalogHarness h = CatalogHarness(catalog: repo);
      final GoRouter router = _appRouter('/catalog');
      addTearDown(router.dispose);
      await _pumpApp(tester, h, router);
      expect(_location(router), '/catalog');
      expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);
      expect(_title(tester), 'Все товары');
    });
  });

  testWidgets('поиск в подкатегории: «Поиск: «q»», корень выделен, лента корня с выбранной «Все товары»', (
    tester,
  ) async {
    setWindow(tester, kExpanded);
    final CatalogHarness h = CatalogHarness();
    final GoRouter router = _appRouter('/catalog/search?q=смеситель&categoryId=c-mix-kitchen');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    expect(find.byKey(const ValueKey<String>('stub-SCR-11')), findsOneWidget);
    expect(_title(tester), 'Поиск: «смеситель»');
    expect(_tileSelected(tester, 'sidebar-category-c-mix'), isTrue);
    expect(_tileSelected(tester, 'chip-sub-all'), isTrue);
    expect(_tileSelected(tester, 'chip-sub-c-mix-kitchen'), isFalse);

    // Карточка ленты — выход из поиска в категорию.
    await tester.tap(find.byKey(const ValueKey<String>('chip-sub-c-mix-bath')));
    await settle(tester, frames: 10);
    expect(_location(router), startsWith('/catalog/c/c-mix-bath'));
    expect(find.byKey(const ValueKey<String>('stub-SCR-12')), findsOneWidget);
  });

  testWidgets('«Избранные»: число избранных — в подсказке и Semantics кнопки строки управления', (tester) async {
    setWindow(tester, kExpanded);
    final FakeShelfPort shelf = FakeShelfPort(favorites: <String>{'p1', 'p2'});
    addTearDown(shelf.dispose);
    final CatalogHarness h = CatalogHarness(shelf: shelf, role: RoleCode.seller);
    final GoRouter router = _appRouter('/catalog/c/c-mix');
    addTearDown(router.dispose);
    await _pumpApp(tester, h, router);
    final SemanticsHandle semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp(r'^Избранные, 2 товара')), findsOneWidget);
    semantics.dispose();
    // Плитки «★ Избранное» и «Недавние» в колонке больше нет (колонка — только категории).
    expect(find.byKey(const ValueKey<String>('sidebar-favorites')), findsNothing);
    expect(find.byKey(const ValueKey<String>('sidebar-recent')), findsNothing);
  });
}

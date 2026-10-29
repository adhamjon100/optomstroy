// Оболочка сотрудника без rail на medium+ (D2, D3, ADR-112; 02 §3.1, §3.2, §3.8; navigation.md §2.1, §2.2, §9):
// - «бургер» шапки открывает drawer навигации: 5 вкладок режима и «Другие разделы» по isPathAllowedForRole;
//   выбор вкладки — goBranch, ссылки — go(path); Esc и затемнение закрывают drawer;
// - на ветке «Каталог» шапку оболочка не рисует (её рисует CatalogWorkspace — одно поле поиска), на прочих — одна
//   шапка StaffShellHeader: поиск → SCR-11, F2 — фокус в поле, меню аватара (Профиль · Настройки · Синхронизация ·
//   Заблокировать · Выйти), кнопка-итог корзины только у ролей с корзиной; часы и дата Бишкека из `clockProvider`
//   по границе минуты (UI-10-005, UI-10-032; на ветке «Касса» — с полной датой, UI-30-013); необязательное шапка
//   сворачивает по доступной ширине (подробно — header_fit_test.dart);
// - Ctrl+1…5 — вкладки режима, Ctrl+Shift+N — уведомления; клиент — rail, compact — BottomNavBar без изменений;
// - кнопка-итог корзины шапки оболочки (`CartHeaderButtonView` на фейковом `CartSync`): число позиций и итог
//   сервера, без ответа сервера — «N поз.»; тап, F4 и пункт «Корзина» — drawer корзины 420, Esc закрывает;
// - на ветке «Каталог» (настоящие маршруты приложения) — ровно одно поле `catalog-search-field`.
// Простые страницы-заглушки на путях приложения; синтетические данные, без сети.
// Тест-кейсы 12_TEST_PLAN: T-UI-114 (оболочка без rail), T-CART-033 и T-CART-037 (кнопка-итог и drawer корзины в
//   шапке оболочки).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/app/router/shells/staff_nav_drawer.dart';
import 'package:optomstroy/app/router/shells/staff_shell_header.dart';
import 'package:optomstroy/core/di/core_providers.dart' show clockProvider;
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/components/navigation_drawer_app.dart';
import 'package:optomstroy/design_system/components/navigation_rail_app.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/layout/shell_scope.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_drawer.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_header_button_view.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' show catalogViewerRoleProvider;
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';

import '../features/cart/support/cart_test_support.dart';
import '../features/catalog/presentation/support/catalog_fakes.dart';
import '../support/f_fakes.dart';

/// Пути веток (как в routes.dart) и корневые маршруты, на которые ведут шапка и drawer.
const Map<ShellBranch, List<String>> _branchPaths = <ShellBranch, List<String>>{
  ShellBranch.catalog: <String>['/catalog', '/catalog/search'],
  ShellBranch.home: <String>['/home'],
  ShellBranch.favorites: <String>['/favorites'],
  ShellBranch.cart: <String>['/cart', '/cart/parked'],
  ShellBranch.customers: <String>['/customers'],
  ShellBranch.cashier: <String>['/cashier'],
  ShellBranch.transactions: <String>['/transactions'],
  ShellBranch.orders: <String>['/orders'],
  ShellBranch.admin: <String>['/admin/users', '/admin/settings', '/admin/audit'],
  ShellBranch.profile: <String>['/profile'],
  ShellBranch.reports: <String>['/reports'],
};

Widget _page(String path) => Scaffold(body: Center(child: Text('page:$path')));

GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: <RouteBase>[
    StatefulShellRoute.indexedStack(
      builder: (BuildContext context, GoRouterState state, StatefulNavigationShell shell) =>
          AppShell(navigationShell: shell),
      branches: <StatefulShellBranch>[
        for (final ShellBranch b in ShellBranch.values)
          StatefulShellBranch(
            routes: <RouteBase>[
              for (final String p in _branchPaths[b]!)
                GoRoute(path: p, builder: (BuildContext context, GoRouterState state) => _page(p)),
            ],
          ),
      ],
    ),
    for (final String p in const <String>['/notifications', '/settings', '/sync', '/scan'])
      GoRoute(path: p, builder: (BuildContext context, GoRouterState state) => _page(p)),
  ],
);

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<GoRouter> _pump(
  WidgetTester tester,
  AppMode mode, {
  String initial = '/catalog',
  Size size = const Size(1280, 800),
  RoleCode? role,
  List<Override> overrides = const <Override>[],
}) async {
  _window(tester, size);
  final GoRouter router = _router(initial);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appModeProvider.overrideWithValue(mode),
        catalogViewerRoleProvider.overrideWithValue(role),
        ...overrides,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String _path(GoRouter r) => r.routerDelegate.currentConfiguration.uri.path;

Finder get _menu => find.byKey(const ValueKey<String>('top-app-bar-menu'));

Finder get _drawer => find.byType(NavigationDrawerApp);

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(_menu);
  await tester.pumpAndSettle();
  expect(_drawer, findsOneWidget);
}

List<String> _links(WidgetTester tester) => <String>[
  for (final Element e in find.byWidgetPredicate((Widget w) {
    final Key? k = w.key;
    return k is ValueKey<String> && k.value.startsWith('shell-nav-link-');
  }).evaluate())
    (e.widget.key! as ValueKey<String>).value.substring('shell-nav-link-'.length),
];

List<String> _tabs(WidgetTester tester) => <String>[
  for (final Element e in find.byWidgetPredicate((Widget w) {
    final Key? k = w.key;
    return k is ValueKey<String> && k.value.startsWith('shell-nav-tab-');
  }).evaluate())
    (e.widget.key! as ValueKey<String>).value.substring('shell-nav-tab-'.length),
];

void main() {
  group('без rail на medium+ (D3)', () {
    for (final AppMode mode in <AppMode>[AppMode.seller, AppMode.cashier, AppMode.admin, AppMode.owner]) {
      for (final Size size in const <Size>[Size(800, 1000), Size(1280, 800)]) {
        testWidgets('${mode.name} ${size.width.toInt()} lp: нет NavigationRailApp и BottomNavBar, есть «бургер»', (
          tester,
        ) async {
          await _pump(tester, mode, initial: '/transactions', size: size);
          expect(find.byType(NavigationRailApp), findsNothing);
          expect(find.byType(BottomNavBar), findsNothing);
          expect(find.byType(StaffShellHeader), findsOneWidget);
          expect(_menu, findsOneWidget);
          await _openDrawer(tester);
          expect(_tabs(tester), hasLength(5), reason: 'все 5 вкладок режима');
        });
      }
    }

    testWidgets('клиент 1280 lp: rail остаётся, «бургера», drawer и шапки оболочки нет (D6)', (tester) async {
      await _pump(tester, AppMode.customer, initial: '/home');
      expect(find.byType(NavigationRailApp), findsOneWidget);
      expect(find.byType(StaffShellHeader), findsNothing);
      expect(_menu, findsNothing);
    });

    testWidgets('compact: BottomNavBar, без шапки оболочки и «бургера»', (tester) async {
      await _pump(tester, AppMode.seller, initial: '/favorites', size: const Size(390, 844));
      expect(find.byType(BottomNavBar), findsOneWidget);
      expect(find.byType(StaffShellHeader), findsNothing);
      expect(_menu, findsNothing);
    });
  });

  group('шапка оболочки (D2)', () {
    testWidgets('ветка «Каталог» — шапку рисует экран каталога, оболочка — нет; прочие ветки — одна шапка', (
      tester,
    ) async {
      final GoRouter router = await _pump(tester, AppMode.seller);
      expect(find.byType(StaffShellHeader), findsNothing);
      expect(find.byKey(StaffShellHeader.searchFieldKey), findsNothing);
      router.go('/orders');
      await tester.pumpAndSettle();
      expect(find.byType(StaffShellHeader), findsOneWidget);
      expect(find.byKey(StaffShellHeader.searchFieldKey), findsOneWidget);
      expect(find.byType(TopAppBarPos), findsOneWidget);
      expect(find.byType(TopAppBarClock), findsOneWidget, reason: 'часы и дата сотрудника (UI-10-005, UI-10-032)');
      expect(tester.getSize(find.byType(TopAppBarPos)).height, 68);
    });

    testWidgets('часы и дата: время Бишкека из clockProvider перед колокольчиком, смена по границе минуты; на «Кассе» '
        '— «Чт, 22 октября 2026» (UI-10-005, UI-10-032, UI-30-013)', (tester) async {
      final FixedClock clock = FixedClock(DateTime.utc(2026, 10, 22, 4, 30, 50)); // 10:30:50 по Бишкеку
      final GoRouter router = await _pump(
        tester,
        AppMode.cashier,
        initial: '/orders',
        role: RoleCode.cashier,
        overrides: <Override>[clockProvider.overrideWithValue(clock)],
      );
      final Finder header = find.byType(StaffShellHeader);
      expect(find.descendant(of: header, matching: find.text('10:30')), findsOneWidget);
      expect(
        find.descendant(of: header, matching: find.text('чт, 22 окт')),
        findsOneWidget,
        reason: 'UI-10-032',
      );
      expect(find.bySemanticsLabel('10:30, чт, 22 окт'), findsOneWidget);
      // Перед колокольчиком (компактный вторичный текст правой группы).
      expect(
        tester.getCenter(find.byType(TopAppBarClock)).dx,
        lessThan(tester.getCenter(find.descendant(of: header, matching: find.byType(NotificationBell))).dx),
      );
      clock.advance(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      expect(
        find.descendant(of: header, matching: find.text('10:31')),
        findsOneWidget,
        reason: 'граница минуты',
      );
      expect(find.text('10:30'), findsNothing);

      router.go('/cashier');
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: header, matching: find.text('Чт, 22 октября 2026')),
        findsOneWidget,
        reason: 'UI-30-013',
      );
      expect(find.descendant(of: header, matching: find.text('10:31')), findsOneWidget);
    });

    testWidgets('medium 800 lp без корзины: шапка сжимается по ширине, а не по классу окна — часы с датой видны, '
        'поле поиска не уже 240 (ADR-112, раунд 2)', (tester) async {
      await _pump(
        tester,
        AppMode.seller,
        initial: '/orders',
        role: RoleCode.seller,
        size: const Size(800, 1000),
        overrides: <Override>[clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 10, 22, 3, 41)))],
      );
      final Finder header = find.byType(StaffShellHeader);
      expect(find.descendant(of: header, matching: find.text('09:41')), findsOneWidget);
      expect(
        find.descendant(of: header, matching: find.text('чт, 22 окт')),
        findsOneWidget,
        reason: 'место есть',
      );
      expect(find.bySemanticsLabel('09:41, чт, 22 окт'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(StaffShellHeader.searchFieldKey)).width,
        greaterThanOrEqualTo(TopAppBarPos.searchMinWidth),
      );
      expect(tester.getSize(find.byType(TopAppBarPos)).height, 68, reason: 'поле поиска — в строке');
      expect(tester.takeException(), isNull);
    });

    testWidgets('поиск: Enter → SCR-11 /catalog/search?q=', (tester) async {
      final GoRouter router = await _pump(tester, AppMode.cashier, initial: '/cashier');
      await tester.enterText(find.byKey(StaffShellHeader.searchFieldKey), 'смеситель');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(_path(router), '/catalog/search');
      expect(router.routerDelegate.currentConfiguration.uri.queryParameters['q'], 'смеситель');
      expect(find.byType(StaffShellHeader), findsNothing, reason: 'на ветке каталога — шапка экрана каталога');
    });

    testWidgets('меню аватара: Профиль · Настройки · Синхронизация · Заблокировать · Выйти', (tester) async {
      int locks = 0;
      await _pump(
        tester,
        AppMode.seller,
        initial: '/orders',
        role: RoleCode.seller,
        overrides: <Override>[catalogHeaderLockProvider.overrideWithValue(() => locks++)],
      );
      await tester.tap(find.byType(TopAppBarUser));
      await tester.pumpAndSettle();
      for (final String k in <String>['profile', 'settings', 'sync', 'lock', 'logout']) {
        expect(find.byKey(ValueKey<String>('profile-menu-$k')), findsOneWidget, reason: k);
      }
      expect(find.text('Заблокировать'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('profile-menu-lock')));
      await tester.pumpAndSettle();
      expect(locks, 1);
    });

    testWidgets('без порта блокировки пункта «Заблокировать» нет', (tester) async {
      await _pump(tester, AppMode.seller, initial: '/orders', role: RoleCode.seller);
      await tester.tap(find.byType(TopAppBarUser));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('profile-menu-lock')), findsNothing);
      expect(find.byKey(const ValueKey<String>('profile-menu-logout')), findsOneWidget);
    });

    testWidgets('кнопка-итог корзины: у продавца есть, у руководителя нет', (tester) async {
      final List<Override> cart = <Override>[
        catalogCartButtonProvider.overrideWithValue((BuildContext context) => const Text('cart-button')),
      ];
      await _pump(tester, AppMode.seller, initial: '/orders', role: RoleCode.seller, overrides: cart);
      expect(find.text('cart-button'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, AppMode.owner, initial: '/transactions', role: RoleCode.owner, overrides: cart);
      expect(find.text('cart-button'), findsNothing);
    });

    testWidgets('DsShellScope.openNavigation: у сотрудника на medium+ есть, на compact и у клиента — нет', (
      tester,
    ) async {
      await _pump(tester, AppMode.seller, initial: '/orders', role: RoleCode.seller);
      expect(tester.widget<DsShellScope>(find.byType(DsShellScope)).openNavigation, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, AppMode.seller, initial: '/orders', role: RoleCode.seller, size: const Size(390, 844));
      expect(tester.widget<DsShellScope>(find.byType(DsShellScope)).openNavigation, isNull);
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, AppMode.customer, initial: '/home', role: RoleCode.customer);
      expect(tester.widget<DsShellScope>(find.byType(DsShellScope)).openNavigation, isNull);
    });

    testWidgets('меню аватара: первым — заголовок с именем и ролью (не пункт); Semantics «Профиль: {имя}, {роль}»', (
      tester,
    ) async {
      await _pump(
        tester,
        AppMode.seller,
        initial: '/orders',
        role: RoleCode.seller,
        size: const Size(1100, 800),
        overrides: <Override>[catalogViewerNameProvider.overrideWithValue('Абдулла')],
      );
      // 1100 lp без корзины: места хватает — у аватара имя и роль (шапка сжимается по ширине, ADR-112); свёрнутые —
      // в Semantics и в заголовке меню (02 A8, SRC-C-004a).
      expect(find.descendant(of: find.byType(TopAppBarUser), matching: find.text('Абдулла')), findsOneWidget);
      expect(find.descendant(of: find.byType(TopAppBarUser), matching: find.text('Продавец')), findsOneWidget);
      // Шапка оболочки видна диктору: барьер страницы ветки (`BlockSemantics`) не скрывает её (AdaptiveScaffold).
      expect(find.bySemanticsLabel('Профиль: Абдулла, Продавец'), findsOneWidget);
      expect(find.bySemanticsLabel('Меню разделов'), findsOneWidget);
      await tester.tap(find.byType(TopAppBarUser));
      await tester.pumpAndSettle();
      final Finder header = find.byKey(const ValueKey<String>('profile-menu-header'));
      expect(header, findsOneWidget);
      expect(find.descendant(of: header, matching: find.text('Абдулла')), findsOneWidget);
      expect(find.descendant(of: header, matching: find.text('Продавец')), findsOneWidget);
      expect(
        tester.getTopLeft(header).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey<String>('profile-menu-profile'))).dy),
        reason: 'заголовок — над пунктами',
      );
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(header, findsOneWidget, reason: 'заголовок не пункт — меню не закрывается');
    });
  });

  group('drawer навигации', () {
    testWidgets('продавец: вкладки режима и «Другие разделы»; вкладка — goBranch, ссылка — go(path)', (tester) async {
      final GoRouter router = await _pump(tester, AppMode.seller, initial: '/orders', role: RoleCode.seller);
      await _openDrawer(tester);
      expect(_tabs(tester), <String>['catalog', 'favorites', 'cart', 'customers', 'profile']);
      expect(_links(tester), <String>['/cart/parked', '/orders', '/transactions']);
      expect(find.text('Другие разделы'), findsOneWidget);
      expect(find.bySemanticsLabel('Навигация'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('shell-nav-tab-favorites')));
      await tester.pumpAndSettle();
      expect(_drawer, findsNothing, reason: 'выбор закрывает drawer');
      expect(_path(router), '/favorites');

      await _openDrawer(tester);
      await tester.tap(find.byKey(const ValueKey<String>('shell-nav-link-/cart/parked')));
      await tester.pumpAndSettle();
      expect(_path(router), '/cart/parked');
    });

    testWidgets('кассир, админ, руководитель: состав «Других разделов»', (tester) async {
      await _pump(tester, AppMode.cashier, initial: '/cashier', role: RoleCode.cashier);
      await _openDrawer(tester);
      expect(_links(tester), <String>['/orders', '/cart/parked', '/favorites', '/cart']);

      await tester.pumpWidget(const SizedBox());
      await _pump(tester, AppMode.admin, initial: '/orders', role: RoleCode.admin);
      await _openDrawer(tester);
      expect(_links(tester), <String>[
        '/reports',
        '/cashier',
        '/admin/audit',
        '/admin/settings',
        '/orders',
        '/cart/parked',
        '/favorites',
        '/cart',
      ]);

      await tester.pumpWidget(const SizedBox());
      await _pump(tester, AppMode.owner, initial: '/reports', role: RoleCode.owner);
      await _openDrawer(tester);
      expect(_links(tester), <String>['/cashier', '/admin/users', '/admin/audit', '/admin/settings', '/orders']);
    });

    testWidgets('старший продавец: в «Других разделах» — «Касса» (SCR-30), у продавца её нет (G-7)', (tester) async {
      final GoRouter router = await _pump(tester, AppMode.seller, initial: '/orders', role: RoleCode.seniorSeller);
      await _openDrawer(tester);
      expect(_links(tester), <String>['/cashier', '/cart/parked', '/orders', '/transactions']);
      await tester.tap(find.byKey(const ValueKey<String>('shell-nav-link-/cashier')));
      await tester.pumpAndSettle();
      expect(_path(router), '/cashier');

      await tester.pumpWidget(const SizedBox());
      await _pump(tester, AppMode.seller, initial: '/orders', role: RoleCode.seller);
      await _openDrawer(tester);
      expect(_links(tester), isNot(contains('/cashier')));
    });

    testWidgets('ссылки фильтруются isPathAllowedForRole (G-7)', (tester) async {
      // Режим «Администратор» при роли seller: касса, отчёты и админ-разделы закрыты роли.
      await _pump(tester, AppMode.admin, initial: '/orders', role: RoleCode.seller);
      await _openDrawer(tester);
      expect(_links(tester), <String>['/orders', '/cart/parked', '/favorites', '/cart']);
    });

    testWidgets('выделение: ссылка на ту же ветку выделяется вместо вкладки', (tester) async {
      final GoRouter router = await _pump(tester, AppMode.admin, initial: '/admin/users', role: RoleCode.admin);
      await _openDrawer(tester);
      NavigationDrawerApp drawer() => tester.widget<NavigationDrawerApp>(_drawer);
      NavigationDrawerItem item(String label) => drawer().groups
          .expand((NavigationDrawerGroup g) => g.items)
          .firstWhere((NavigationDrawerItem i) => i.label == label);
      expect(item('Администратор').selected, isTrue);
      await tester.tap(find.byKey(const ValueKey<String>('shell-nav-link-/admin/audit')));
      await tester.pumpAndSettle();
      expect(_path(router), '/admin/audit');
      await _openDrawer(tester);
      expect(item('Журнал аудита').selected, isTrue);
      expect(item('Администратор').selected, isFalse);
    });

    testWidgets('Esc и тап по затемнению закрывают drawer', (tester) async {
      await _pump(tester, AppMode.seller, initial: '/orders');
      await _openDrawer(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_drawer, findsNothing, reason: 'Esc');
      await _openDrawer(tester);
      await tester.tapAt(const Offset(1200, 400));
      await tester.pumpAndSettle();
      expect(_drawer, findsNothing, reason: 'затемнение');
    });
  });

  group('кнопка-итог и drawer корзины в шапке оболочки (D2, D5)', () {
    late FakeCartRepository repo;
    late FakeCartSync sync;

    setUp(() {
      repo = FakeCartRepository();
      sync = FakeCartSync(repo);
      repo.onListParked = (ParkedScope scope, String? cursor) async =>
          const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
    });

    List<Override> cart() => <Override>[
      ...cartOverrides(sync: sync, repo: repo),
      catalogCartButtonProvider.overrideWithValue((BuildContext context) => const CartHeaderButtonView()),
    ];

    final Finder button = find.byKey(CartHeaderButtonView.buttonKey);
    final Finder drawer = find.byKey(CartDrawer.key);

    testWidgets('число позиций в бейдже и итог сервера; тап — drawer 420 справа; Esc закрывает, фокус — на кнопку', (
      tester,
    ) async {
      final Cart c = canonCart();
      serveCart(repo, c);
      // 1440 lp: шапка ничего не сворачивает и при тестовом шрифте (при видимом имени поле поиска не уже 320 —
      // в 1280 lp строка «Корзина · N шт» свернулась бы; QA паритета функций, ADR-112).
      await _pump(
        tester,
        AppMode.seller,
        initial: '/orders',
        role: RoleCode.seller,
        overrides: cart(),
        size: const Size(1440, 800),
      );
      expect(find.descendant(of: find.byType(StaffShellHeader), matching: button), findsOneWidget);
      final Finder badge = find.descendant(
        of: button,
        matching: find.byKey(const ValueKey<String>('top-app-bar-cart-badge')),
      );
      expect(find.descendant(of: badge, matching: find.text('${c.items.length}')), findsOneWidget);
      // Первая строка — «Корзина · 6 …» (единицы корзины, как прежняя подпись CartFab; паритет функций ADR-112).
      final Text label = tester.widget<Text>(
        find.descendant(of: button, matching: find.byKey(const ValueKey<String>('top-app-bar-cart-label'))),
      );
      expect(label.data, startsWith('Корзина · 6'));
      expect(
        find.descendant(of: button, matching: find.text(PriceText.format(const Money(1600750), fixed2: true))),
        findsOneWidget,
      );

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(drawer, findsOneWidget);
      expect(tester.getSize(drawer).width, DsBreakpoints.cartDrawer);
      expect(tester.getTopRight(drawer).dx, 1440, reason: 'drawer — у правого края окна');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(drawer, findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'cart-header-button', reason: 'A11Y-011');
    });

    testWidgets('medium 800 lp: итог сервера виден одной строкой, без подписи «Корзина» (02 UI-10-041)', (
      tester,
    ) async {
      serveCart(repo, canonCart());
      await _pump(
        tester,
        AppMode.seller,
        initial: '/orders',
        role: RoleCode.seller,
        size: const Size(800, 1000),
        overrides: cart(),
      );
      expect(
        find.descendant(of: button, matching: find.text(PriceText.format(const Money(1600750), fixed2: true))),
        findsOneWidget,
      );
      expect(find.descendant(of: button, matching: find.text('Корзина')), findsNothing);
    });

    testWidgets('пока сервер не ответил — вторая строка «N поз.», без суммы', (tester) async {
      final Completer<Result<Cart>> never = Completer<Result<Cart>>();
      repo.onFetch = () => never.future;
      sync.snapshot = CartLocalSnapshot(
        localCartId: 'local-1',
        dirty: false,
        lines: <CartLocalLine>[
          for (int i = 0; i < 3; i++)
            CartLocalLine(
              key: CartLineKey('v-$i'),
              quantity: Qty.units(1),
              syncState: CartDraftSyncState.synced,
              lineNo: i + 1,
              unitId: 'u-pc',
              unitLabel: 'шт',
              productId: 'p-$i',
              productName: 'Товар $i',
              step: Qty.units(1),
            ),
        ],
      );
      await _pump(tester, AppMode.cashier, initial: '/cashier', role: RoleCode.cashier, overrides: cart());
      final String n = lookupAppLocalizations(const Locale('ru')).cart_positions_short(3);
      expect(find.descendant(of: button, matching: find.text(n)), findsOneWidget);
      expect(find.descendant(of: button, matching: find.textContaining('сом')), findsNothing);
    });

    testWidgets('F4 на ветке вне каталога — drawer корзины; повторный F4 второй корзины не открывает; Esc закрывает', (
      tester,
    ) async {
      serveCart(repo, canonCart());
      await _pump(tester, AppMode.seller, initial: '/customers', role: RoleCode.seller, overrides: cart());
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      expect(drawer, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      expect(drawer, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(drawer, findsNothing);
    });

    testWidgets('Ctrl+3 («Корзина») у продавца на medium+ — drawer корзины, как пункт drawer навигации', (
      tester,
    ) async {
      serveCart(repo, canonCart());
      final GoRouter router = await _pump(
        tester,
        AppMode.seller,
        initial: '/orders',
        role: RoleCode.seller,
        overrides: cart(),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(drawer, findsOneWidget);
      expect(_path(router), '/orders', reason: 'ветка /cart не открыта');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });

    testWidgets('пункт «Корзина» drawer навигации открывает drawer корзины, а не ветку /cart', (tester) async {
      serveCart(repo, canonCart());
      final GoRouter router = await _pump(
        tester,
        AppMode.seller,
        initial: '/orders',
        role: RoleCode.seller,
        overrides: cart(),
      );
      await _openDrawer(tester);
      await tester.tap(find.byKey(const ValueKey<String>('shell-nav-tab-cart')));
      await tester.pumpAndSettle();
      expect(_drawer, findsNothing, reason: 'drawer навигации закрыт');
      expect(drawer, findsOneWidget);
      expect(_path(router), '/orders');
    });
  });

  testWidgets('ветка «Каталог» (маршруты приложения): ровно одно поле catalog-search-field, шапки оболочки нет', (
    tester,
  ) async {
    _window(tester, const Size(1280, 800));
    final CatalogHarness h = CatalogHarness();
    final GoRouter router = GoRouter(routes: $appRoutes, initialLocation: '/catalog');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[...h.overrides, appModeProvider.overrideWithValue(AppMode.seller)],
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (BuildContext context, Widget? child) =>
              ProductImageScope(providerFor: transparentImage, child: child!),
        ),
      ),
    );
    await settle(tester, frames: 10);
    expect(find.byKey(const ValueKey<String>('stub-SCR-10')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('catalog-search-field')), findsOneWidget);
    expect(find.byType(CatalogHeader), findsOneWidget);
    expect(find.byType(StaffShellHeader), findsNothing);
    expect(find.byKey(StaffShellHeader.searchFieldKey), findsNothing);
    expect(_menu, findsOneWidget, reason: '«бургер» шапки каталога открывает drawer оболочки');
    await tester.tap(_menu);
    await settle(tester, frames: 30);
    expect(find.byType(StaffNavigationDrawer), findsOneWidget);
  });

  group('горячие клавиши оболочки (02 §3.8)', () {
    testWidgets('Ctrl+1…5 — вкладки режима по порядку', (tester) async {
      final GoRouter router = await _pump(tester, AppMode.cashier, initial: '/cashier');
      Future<void> ctrl(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      await ctrl(LogicalKeyboardKey.digit2);
      expect(_path(router), '/catalog');
      await ctrl(LogicalKeyboardKey.digit4);
      expect(_path(router), '/transactions');
      await ctrl(LogicalKeyboardKey.digit1);
      expect(_path(router), '/cashier');
    });

    testWidgets('Ctrl+1…5 в поле ввода не перехватываются (02 §3.8)', (tester) async {
      final GoRouter router = await _pump(tester, AppMode.cashier, initial: '/transactions');
      await tester.tap(find.byKey(StaffShellHeader.searchFieldKey));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(_path(router), '/transactions', reason: 'фокус в поле поиска — вкладка не меняется');
    });

    testWidgets('Ctrl+Shift+N — уведомления; F2 — фокус в поле поиска шапки', (tester) async {
      final GoRouter router = await _pump(tester, AppMode.seller, initial: '/orders', size: const Size(800, 1000));
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      final EditableText field = tester.widget<EditableText>(
        find.descendant(of: find.byKey(StaffShellHeader.searchFieldKey), matching: find.byType(EditableText)),
      );
      expect(field.focusNode.hasFocus, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/notifications');
    });
  });

  testWidgets('пути «Других разделов» drawer — маршруты приложения (routes.dart)', (tester) async {
    // Литералы путей ссылок сверяются с типизированными маршрутами: расхождение с routes.dart ловит этот тест.
    final GoRouter router = GoRouter(routes: $appRoutes);
    addTearDown(router.dispose);
    for (final AppMode mode in AppMode.values) {
      for (final ShellLink l in shellLinksFor(mode)) {
        expect(router.configuration.findMatch(Uri.parse(l.path)).isError, isFalse, reason: '${mode.name}: ${l.path}');
      }
    }
  });

  test('shellLinkForPath — самая длинная по префиксу ссылка', () {
    final List<ShellLink> links = shellLinksFor(AppMode.cashier);
    expect(shellLinkForPath(links, '/cart/parked')?.path, '/cart/parked');
    expect(shellLinkForPath(links, '/cart')?.path, '/cart');
    expect(shellLinkForPath(links, '/orders/o-1')?.path, '/orders');
    expect(shellLinkForPath(links, '/catalog'), isNull);
    expect(shellLinksFor(AppMode.customer), isEmpty);
  });
}

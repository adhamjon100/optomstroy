// Шапка телефона и меню профиля по аватару (15 ADR-122, AC-ADR-122; 02 §3.1 п. 8, SCR-41.3; 03 §9.57.1;
// visual/responsive-spec.md §1.1 compact). Тест-кейсы 12_TEST_PLAN: T-UI-118 (шапка телефона на всех ролях, без
// переполнения на 320–480 lp, портрет и ландшафт, масштаб текста 1 / 1,3 / 1,5, цели ≥ 48), T-UI-119 (аватар → лист
// профиля: «История заказов» → SCR-25 `?mine=1`, у `order.read.all` — «Мои / Все»; «Избранное» → SCR-40; затем
// прежние пункты). Оболочка с простыми страницами на путях приложения; синтетические данные, без сети.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/shells/phone_shell_header.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode, UserKind, UserStatus;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/components/phone_top_bar.dart';
import 'package:optomstroy/design_system/components/sync_indicator.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_phone_header.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/screens/orders_screen.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/presentation/widgets/profile_menu_sheet.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_connected_widgets.dart';

import '../features/catalog/presentation/support/catalog_fakes.dart';
import '../features/orders/support/orders_harness.dart';
import '../features/profile/presentation/profile_screen_test.dart' show FakeProfileRepository, TestSession, seedMe;
import '../support/f_fakes.dart';

/// Пути веток (как в routes.dart) и вложенные экраны (свою шапку «Назад» рисуют сами).
const Map<ShellBranch, List<String>> _branchPaths = <ShellBranch, List<String>>{
  ShellBranch.catalog: <String>['/catalog', '/catalog/search'],
  ShellBranch.home: <String>['/home'],
  ShellBranch.favorites: <String>['/favorites'],
  ShellBranch.cart: <String>['/cart', '/cart/parked'],
  ShellBranch.customers: <String>['/customers'],
  ShellBranch.cashier: <String>['/cashier'],
  ShellBranch.transactions: <String>['/transactions'],
  ShellBranch.orders: <String>['/orders', '/orders/o1'],
  // SCR-46, SCR-47, SCR-54 — на одном уровне с `/admin/users` (переход `AdminNavMenu` → `go`).
  ShellBranch.admin: <String>['/admin/users', '/admin/settings', '/admin/audit', '/admin/tablets'],
  ShellBranch.profile: <String>['/profile'],
  ShellBranch.reports: <String>['/reports'],
};

Widget _page(String path) => Scaffold(
  appBar: AppBar(title: Text('title:$path')),
  body: Center(child: Text('page:$path')),
);

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

/// `SyncIndicator` шапки — как в приложении (`ConnectedSyncIndicator(adaptive: true)`, di/overrides.dart; цель
/// касания самого индикатора — 44, в шапке телефона — 48).
final List<Override> _syncOverrides = <Override>[
  catalogSyncIndicatorProvider.overrideWithValue(
    (BuildContext context) => const ConnectedSyncIndicator(adaptive: true),
  ),
  syncIndicatorProvider.overrideWithValue(const SyncIndicatorInfo(status: SyncIndicatorStatus.ok)),
];

Future<GoRouter> _pumpShell(
  WidgetTester tester,
  AppMode mode,
  RoleCode role, {
  String initial = '/orders',
  Size size = const Size(390, 844),
  TestSession? session,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final GoRouter router = _router(initial);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appModeProvider.overrideWithValue(mode),
        catalogViewerRoleProvider.overrideWithValue(role),
        catalogViewerNameProvider.overrideWithValue('Айбек Асанов'),
        catalogUnreadNotificationsProvider.overrideWithValue(3),
        catalogProfileSheetProvider.overrideWithValue(
          (BuildContext context, String name, String role) => showProfileMenuSheet(context, name: name, role: role),
        ),
        profileRepositoryProvider.overrideWithValue(FakeProfileRepository(profile: _me(role))),
        clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 11, 23, 9))),
        onlineStatusProvider.overrideWith((Ref ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
        sessionControllerProvider.overrideWith(() => session ?? TestSession()),
        ..._syncOverrides,
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

/// Профиль `GET /me` роли [role] (клиент — `kind: customer`, без прав на транзакции).
UserProfile _me(RoleCode role) {
  final UserProfile staff = seedMe(roles: <RoleCode>[role]);
  if (role != RoleCode.customer) return staff;
  return UserProfile(
    id: 'c-1',
    kind: UserKind.customer,
    status: UserStatus.active,
    roles: const <RoleCode>[RoleCode.customer],
    permissions: const <String>{'order.read.own'},
    permissionsVersion: 1,
    profile: staff.profile,
  );
}

Finder get _avatar => find.byKey(CatalogPhoneHeader.avatarKey);

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(_avatar);
  await tester.pumpAndSettle();
  expect(find.byType(ProfileMenuSheet), findsOneWidget);
}

/// Ключи пунктов листа сверху вниз.
List<String> _sheetItems(WidgetTester tester) {
  final List<(double, String)> found = <(double, String)>[];
  for (final Element e in find.byWidgetPredicate((Widget w) {
    final Key? k = w.key;
    return k is ValueKey<String> && k.value.startsWith('profile-sheet-') && k.value != 'profile-sheet-card';
  }).evaluate()) {
    final String key = (e.widget.key! as ValueKey<String>).value.substring('profile-sheet-'.length);
    found.add((tester.getTopLeft(find.byKey(e.widget.key!)).dy, key));
  }
  found.sort(((double, String) a, (double, String) b) => a.$1.compareTo(b.$1));
  return <String>[for (final (double, String) f in found) f.$2];
}

void _expectInside(WidgetTester tester, Finder f, Size window, String reason) {
  final Rect r = tester.getRect(f);
  expect(r.left, greaterThanOrEqualTo(0), reason: reason);
  expect(r.right, lessThanOrEqualTo(window.width + 0.01), reason: reason);
  expect(r.top, greaterThanOrEqualTo(0), reason: reason);
}

void main() {
  group('T-UI-118 шапка телефона (AC-ADR-122 (1), (2), (4))', () {
    for (final (AppMode mode, RoleCode role, List<ShellBranch> tabs) in <(AppMode, RoleCode, List<ShellBranch>)>[
      (
        AppMode.seller,
        RoleCode.seller,
        <ShellBranch>[
          ShellBranch.catalog,
          ShellBranch.favorites,
          ShellBranch.cart,
          ShellBranch.customers,
          ShellBranch.profile,
        ],
      ),
      (
        AppMode.cashier,
        RoleCode.cashier,
        <ShellBranch>[
          ShellBranch.cashier,
          ShellBranch.catalog,
          ShellBranch.customers,
          ShellBranch.transactions,
          ShellBranch.profile,
        ],
      ),
      (
        AppMode.admin,
        RoleCode.admin,
        <ShellBranch>[
          ShellBranch.catalog,
          ShellBranch.customers,
          ShellBranch.transactions,
          ShellBranch.admin,
          ShellBranch.profile,
        ],
      ),
      (
        AppMode.owner,
        RoleCode.owner,
        <ShellBranch>[
          ShellBranch.catalog,
          ShellBranch.customers,
          ShellBranch.transactions,
          ShellBranch.reports,
          ShellBranch.profile,
        ],
      ),
      (
        AppMode.customer,
        RoleCode.customer,
        <ShellBranch>[
          ShellBranch.home,
          ShellBranch.favorites,
          ShellBranch.cart,
          ShellBranch.orders,
          ShellBranch.profile,
        ],
      ),
    ]) {
      testWidgets('${role.value}: шапка телефона на корнях веток (кроме каталога и SCR-50), BottomNavBar прежний', (
        tester,
      ) async {
        final GoRouter router = await _pumpShell(tester, mode, role, initial: '/profile');
        expect(find.byType(BottomNavBar), findsOneWidget, reason: 'нижняя навигация остаётся');
        expect(shellTabsFor(mode).map((ShellTab t) => t.branch).toList(), tabs, reason: '02 §3.1: вкладки роли');
        for (final ShellBranch b in tabs) {
          final String root = _branchPaths[b]!.first;
          router.go(root);
          await tester.pumpAndSettle();
          final bool own = root == '/catalog' || root == '/home';
          expect(
            find.byType(PhoneShellHeader),
            own ? findsNothing : findsOneWidget,
            reason: '$root: шапка оболочки (каталог и главная клиента рисуют свою)',
          );
          if (own) continue;
          expect(find.byKey(CatalogPhoneHeader.bellKey), findsOneWidget);
          expect(_avatar, findsOneWidget);
          expect(
            find.byKey(CatalogPhoneHeader.cartKey),
            role == RoleCode.owner ? findsNothing : findsOneWidget,
            reason: 'корзина — у ролей с корзиной',
          );
          expect(
            find.byKey(CatalogPhoneHeader.syncKey),
            role == RoleCode.customer ? findsNothing : findsOneWidget,
            reason: '$root: SyncIndicator — у сотрудника (ADR-122 п. 1), у клиента — нет',
          );
          expect(find.byKey(PhoneShellHeader.searchFieldKey), findsOneWidget, reason: 'поиск');
          expect(find.text('title:$root'), findsOneWidget, reason: 'строка заголовка экрана сохраняется');
        }
        if (role == RoleCode.admin) {
          // Разделы «Админа» того же уровня, что `/admin/users` (без «Назад»): шапка телефона та же.
          for (final String p in const <String>['/admin/settings', '/admin/audit', '/admin/tablets']) {
            router.go(p);
            await tester.pumpAndSettle();
            expect(find.byType(PhoneShellHeader), findsOneWidget, reason: '$p: шапка телефона');
            expect(_avatar, findsOneWidget, reason: '$p: аватар → меню профиля');
            expect(find.text('title:$p'), findsOneWidget);
          }
        }
      });
    }

    testWidgets('вложенный экран ветки — без шапки телефона (своя шапка «Назад»); medium — без неё', (tester) async {
      final GoRouter router = await _pumpShell(tester, AppMode.cashier, RoleCode.cashier);
      expect(find.byType(PhoneShellHeader), findsOneWidget);
      unawaited(router.push<void>('/orders/o1'));
      await tester.pumpAndSettle();
      expect(find.text('page:/orders/o1'), findsOneWidget);
      expect(find.byType(PhoneShellHeader), findsNothing);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(PhoneShellHeader), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await _pumpShell(tester, AppMode.cashier, RoleCode.cashier, size: const Size(800, 1000));
      expect(find.byType(PhoneShellHeader), findsNothing, reason: 'medium+ не меняется (ADR-122 п. 8)');
    });

    testWidgets('системный отступ сверху (статус-бар 24): шапка ниже него, заголовок экрана вплотную под шапкой', (
      tester,
    ) async {
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPadding);
      await _pumpShell(tester, AppMode.cashier, RoleCode.cashier);
      expect(find.byType(PhoneShellHeader), findsOneWidget);
      final Rect header = tester.getRect(find.byKey(CatalogPhoneHeader.headerKey));
      expect(header.top, 0, reason: 'фон шапки — под статус-баром');
      final Rect row = tester.getRect(find.byKey(PhoneTopBar.rowKey));
      expect(row.top, 24, reason: 'строка шапки — ниже статус-бара');
      for (final Key k in <Key>[
        PhoneTopBar.logoKey,
        CatalogPhoneHeader.cartKey,
        CatalogPhoneHeader.syncKey,
        CatalogPhoneHeader.bellKey,
        CatalogPhoneHeader.avatarKey,
      ]) {
        expect(tester.getRect(find.byKey(k)).top, greaterThanOrEqualTo(24), reason: '$k ниже статус-бара');
      }
      final Rect appBar = tester.getRect(find.byType(AppBar));
      expect(appBar.top, header.bottom, reason: 'строка заголовка экрана — вплотную под шапкой');
      expect(appBar.height, kToolbarHeight, reason: 'без второго отступа статус-бара');
    });

    testWidgets('сканер в поле поиска у сотрудника; у клиента — без камеры (10 CUST-021)', (tester) async {
      await _pumpShell(tester, AppMode.seller, RoleCode.seller);
      expect(
        find.descendant(of: find.byKey(PhoneShellHeader.searchFieldKey), matching: find.byIcon(Icons.barcode_reader)),
        findsWidgets,
      );
      await tester.pumpWidget(const SizedBox());
      await _pumpShell(tester, AppMode.customer, RoleCode.customer);
      expect(
        find.descendant(of: find.byKey(PhoneShellHeader.searchFieldKey), matching: find.byIcon(Icons.barcode_reader)),
        findsNothing,
      );
    });

    const List<double> widths = <double>[320, 360, 390, 412, 480];
    const List<double> scales = <double>[1, 1.3, 1.5];
    for (final double w in widths) {
      for (final bool landscape in <bool>[false, true]) {
        // Ландшафт телефона той же ширины класса compact — низкое окно (высота 320); портрет — 844.
        final Size size = Size(w, landscape ? 320 : 844);
        testWidgets('SCR-10 и SCR-25 на ${size.width.toInt()}×${size.height.toInt()}: без переполнения, цели ≥ 48, '
            'масштаб 1 / 1,3 / 1,5', (tester) async {
          for (final double scale in scales) {
            setWindow(tester, size);
            // Масштаб текста системы (MaterialApp берёт его из окна).
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            await tester.pumpWidget(
              catalogApp(
                CatalogHarness(extra: _syncOverrides),
                home: const CatalogScreen(),
                size: size,
              ),
            );
            await settle(tester);
            expect(MediaQuery.textScalerOf(tester.element(find.byType(CatalogPhoneHeader))).scale(10), 10 * scale);
            expect(tester.takeException(), isNull, reason: 'SCR-10 $size × $scale');
            for (final Key k in <Key>[
              PhoneTopBar.logoKey,
              CatalogPhoneHeader.avatarKey,
              CatalogPhoneHeader.bellKey,
              CatalogPhoneHeader.cartKey,
              CatalogPhoneHeader.syncKey,
              SyncIndicator.tapTargetKey,
            ]) {
              final Finder f = find.byKey(k);
              expect(f, findsOneWidget, reason: '$k');
              _expectInside(tester, f, size, '$k $size × $scale');
              final Size s = tester.getSize(f);
              expect(s.width, greaterThanOrEqualTo(48), reason: '$k цель $s');
              expect(s.height, greaterThanOrEqualTo(48), reason: '$k цель $s');
            }
            // Поле поиска: в портрете — второй строкой шапки; на 480 ландшафте — тоже (иконки не оставляют 240).
            expect(find.byKey(PhoneTopBar.searchRowKey), findsOneWidget, reason: 'поле второй строкой при $size');
            await tester.pumpWidget(const SizedBox());
          }
        });
      }
    }

    testWidgets('ландшафт 568×320 и 599×360: поле поиска в первой строке', (tester) async {
      for (final Size size in const <Size>[Size(568, 320), Size(599, 360)]) {
        setWindow(tester, size);
        await tester.pumpWidget(catalogApp(CatalogHarness(), home: const CatalogScreen(), size: size));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byKey(PhoneTopBar.searchRowKey), findsNothing, reason: '$size');
        expect(find.byKey(CatalogPhoneHeader.avatarKey), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('оболочка: SCR-25 под шапкой телефона без переполнения на 320–480 × 1 / 1,3 / 1,5 (кассир: корзина, '
        'синхронизация, колокольчик, аватар)', (tester) async {
      for (final double w in widths) {
        for (final double scale in scales) {
          final Size size = Size(w, 844);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          final GoRouter router = _router('/orders');
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                appModeProvider.overrideWithValue(AppMode.cashier),
                catalogViewerRoleProvider.overrideWithValue(RoleCode.cashier),
                catalogViewerNameProvider.overrideWithValue('Айбек Асанов'),
                catalogUnreadNotificationsProvider.overrideWithValue(12),
                clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 11, 23, 9))),
                ..._syncOverrides,
              ],
              child: MaterialApp.router(
                routerConfig: router,
                theme: AppTheme.light(),
                locale: const Locale('ru'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (BuildContext context, Widget? child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$size × $scale');
          expect(find.byType(PhoneShellHeader), findsOneWidget);
          for (final Key k in <Key>[
            PhoneTopBar.logoKey,
            CatalogPhoneHeader.cartKey,
            CatalogPhoneHeader.syncKey,
            CatalogPhoneHeader.bellKey,
            CatalogPhoneHeader.avatarKey,
          ]) {
            final Finder f = find.byKey(k);
            expect(f, findsOneWidget, reason: '$k $size × $scale');
            _expectInside(tester, f, size, '$k $size × $scale');
            final Size s = tester.getSize(f);
            expect(s.width, greaterThanOrEqualTo(48), reason: '$k цель $s');
            expect(s.height, greaterThanOrEqualTo(48), reason: '$k цель $s');
          }
          await tester.pumpWidget(const SizedBox());
          router.dispose();
        }
      }
      tester.view.reset();
    });
  });

  group('T-UI-119 меню профиля по аватару (AC-ADR-122 (1))', () {
    testWidgets('лист: карточка, «История заказов», «Избранное», затем прежние пункты (staff)', (tester) async {
      await _pumpShell(tester, AppMode.cashier, RoleCode.cashier);
      await _openSheet(tester);
      expect(find.byKey(ProfileMenuSheet.cardKey), findsOneWidget);
      expect(find.text('История заказов'), findsOneWidget);
      expect(find.text('Избранное'), findsOneWidget);
      expect(_sheetItems(tester), <String>[
        'open-profile',
        'orders',
        'favorites',
        'transactions',
        'notifications',
        'sync',
        'settings',
        'phone-change',
        'lock',
        'logout',
        'logout-all',
      ]);
    });

    testWidgets('лист клиента: без транзакций, синхронизации и блокировки', (tester) async {
      await _pumpShell(tester, AppMode.customer, RoleCode.customer);
      await _openSheet(tester);
      final List<String> items = _sheetItems(tester);
      expect(items.take(3).toList(), <String>['open-profile', 'orders', 'favorites']);
      expect(items, isNot(contains('sync')));
      expect(items, isNot(contains('lock')));
    });

    testWidgets('аватар → «История заказов» → SCR-25 со своими заказами (`mine=1`)', (tester) async {
      final GoRouter router = await _pumpShell(tester, AppMode.seller, RoleCode.seller, initial: '/favorites');
      await _openSheet(tester);
      await tester.tap(find.byKey(ProfileMenuSheet.ordersKey));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileMenuSheet), findsNothing, reason: 'лист закрыт');
      expect(router.routerDelegate.currentConfiguration.uri.path, '/orders');
      expect(router.routerDelegate.currentConfiguration.uri.queryParameters['mine'], '1');
      expect(find.text('page:/orders'), findsOneWidget);
    });

    testWidgets('аватар → «Избранное» → SCR-40', (tester) async {
      final GoRouter router = await _pumpShell(tester, AppMode.admin, RoleCode.admin, initial: '/customers');
      await _openSheet(tester);
      await tester.tap(find.byKey(ProfileMenuSheet.favoritesKey));
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/favorites');
      expect(find.text('page:/favorites'), findsOneWidget);
    });

    testWidgets('«Открыть профиль» → SCR-41; «Выйти» — подтверждение и выход', (tester) async {
      final TestSession session = TestSession();
      final GoRouter router = await _pumpShell(tester, AppMode.seller, RoleCode.seller, session: session);
      await _openSheet(tester);
      await tester.tap(find.byKey(ProfileMenuSheet.openProfileKey));
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/profile');
      await _openSheet(tester);
      await tester.ensureVisible(find.byKey(ProfileMenuSheet.logoutKey));
      await tester.tap(find.byKey(ProfileMenuSheet.logoutKey));
      await tester.pumpAndSettle();
      expect(find.text('Выйти из аккаунта?'), findsOneWidget);
      await tester.tap(find.text('Выйти').last);
      await tester.pumpAndSettle();
      expect(session.logouts, 1);
    });

    for (final RoleCode role in <RoleCode>[RoleCode.cashier, RoleCode.seniorSeller, RoleCode.admin, RoleCode.owner]) {
      testWidgets('«История заказов» у ${role.value} (`order.read.all`): SCR-25 `mine=1` — «Мои» выбрано, есть «Все»', (
        tester,
      ) async {
        final FakeOrdersRepository repo = FakeOrdersRepository()
          ..onList = (_) async => Success<OrdersPage>(ordersPage(<OrderSummary>[summary(1)]));
        await OrdersHarness(
          orders: repo,
          role: role,
          userId: 'u7',
        ).pump(tester, const OrdersScreen(mine: '1'), size: kWindows['compact']!);
        expect(find.byKey(const ValueKey<String>('orders-scope-mine')), findsOneWidget);
        expect(find.byKey(const ValueKey<String>('orders-scope-all')), findsOneWidget);
        final FakeCall list = repo.calls.lastWhere((FakeCall c) => c.method == 'list');
        expect((list.args.single! as OrdersQuery).createdBy, 'u7', reason: 'свои заказы');
      });
    }

    testWidgets('«История заказов» у продавца (`order.read.own`): без «Мои / Все»', (tester) async {
      final FakeOrdersRepository repo = FakeOrdersRepository()
        ..onList = (_) async => Success<OrdersPage>(ordersPage(<OrderSummary>[summary(1)]));
      await OrdersHarness(
        orders: repo,
        role: RoleCode.seller,
      ).pump(tester, const OrdersScreen(mine: '1'), size: kWindows['compact']!);
      expect(find.byKey(const ValueKey<String>('orders-scope-mine')), findsNothing);
    });
  });
}

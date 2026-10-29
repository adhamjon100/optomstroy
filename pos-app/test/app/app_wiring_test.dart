// Интеграция этапа E в композиционном корне и оболочке (RM-E-012; D-18; 03 §9.54–§9.56; 02 §2 «Оболочка»):
// - оболочка: compact — `BottomNavBar`; medium/expanded у сотрудника — без rail, drawer по «бургеру» шапки оболочки
//   (ADR-112), у клиента — `NavigationRailApp`; переключение веток;
//   HID-сканер включён для режимов сотрудников и выключен для клиента;
// - корень: адаптер штрихкода каталога → порт фичи scan, имя пользователя и `SyncIndicator` в шапке каталога,
//   «Сразу в корзину» по роли, настройки отображения SCR-42 (размер текста, уменьшение анимаций),
//   «Открыть настройки» ОС только на Android/iOS.
// Синтетические данные, без сети (не реальная интеграция).
// Тест-кейсы 12_TEST_PLAN: T-UI-101, T-UI-114 (вкладки режима достижимы из drawer навигации).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/app.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/app/di/scan_catalog_adapter.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/shells/seller_shell.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/app/router/shells/staff_nav_drawer.dart';
import 'package:optomstroy/app/router/shells/staff_shell_header.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/hardware/hardware_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/sync/sync_journal_api.dart';
import 'package:optomstroy/core/sync/sync_providers.dart' show syncJournalPortProvider;
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/components/navigation_rail_app.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_drawer.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';
import 'package:optomstroy/features/scan/presentation/hid_scan_scope.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/settings_providers.dart' as settings_providers;

import '../features/cart/support/cart_test_support.dart';
import '../support/f_fakes.dart';

final class _Net implements NetworkSignalSource {
  @override
  Future<bool> hasNetwork() async => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

/// Контейнер корня с метаданными клиента (в приложении их читает bootstrap).
ProviderContainer _root() {
  final ProviderContainer c = ProviderContainer(
    overrides: [
      ...appOverrides,
      connectivityWatcherProvider.overrideWithValue(ConnectivityWatcher(_Net())),
      clientMetaProvider.overrideWithValue(
        const ClientMeta(
          appVersion: '0.1.0+1',
          platform: ClientPlatform.windows,
          deviceId: '3f2b8c1e-5d4a-4b6c-9e7f-0a1b2c3d4e5f',
        ),
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Оболочка над всеми ветками `ShellBranch` (порядок как в routes.dart) с простыми страницами.
GoRouter _router() => GoRouter(
  initialLocation: '/b0',
  routes: <RouteBase>[
    StatefulShellRoute.indexedStack(
      builder: (BuildContext context, GoRouterState state, StatefulNavigationShell shell) =>
          AppShell(navigationShell: shell),
      branches: <StatefulShellBranch>[
        for (final ShellBranch b in ShellBranch.values)
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/b${b.index}',
                builder: (BuildContext context, GoRouterState state) => Text('page-${b.name}'),
              ),
            ],
          ),
      ],
    ),
  ],
);

Future<GoRouter> _pumpShell(WidgetTester tester, AppMode mode, {List<Override> overrides = const <Override>[]}) async {
  final GoRouter router = _router();
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appModeProvider.overrideWithValue(mode), ...overrides],
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump();
  return router;
}

void main() {
  group('оболочка AppShell (D-18)', () {
    testWidgets('compact: BottomNavBar с 5 вкладками продавца, тап переключает ветку', (tester) async {
      _window(tester, const Size(390, 844));
      final GoRouter router = await _pumpShell(tester, AppMode.seller);
      expect(find.byType(BottomNavBar), findsOneWidget);
      expect(find.byType(NavigationRailApp), findsNothing);
      expect(tester.widget<BottomNavBar>(find.byType(BottomNavBar)).destinations, hasLength(5));
      expect(find.text('page-catalog'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(BottomNavBar), matching: find.text('Корзина')));
      await tester.pump();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/b${ShellBranch.cart.index}');
    });

    for (final Size size in const <Size>[Size(800, 1000), Size(1280, 800)]) {
      testWidgets('${size.width.toInt()} lp: без rail и нижней панели; «бургер» открывает drawer навигации (ADR-112)', (
        tester,
      ) async {
        _window(tester, size);
        final GoRouter router = await _pumpShell(tester, AppMode.seller);
        expect(find.byType(NavigationRailApp), findsNothing);
        expect(find.byType(BottomNavBar), findsNothing);
        expect(find.text('page-catalog'), findsOneWidget);
        // На ветке «Каталог» шапку рисует экран каталога (здесь — заглушка), на прочих — оболочка.
        expect(find.byType(StaffShellHeader), findsNothing);
        router.go('/b${ShellBranch.favorites.index}');
        await tester.pumpAndSettle();
        expect(find.byType(StaffShellHeader), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey<String>('top-app-bar-menu')));
        await tester.pumpAndSettle();
        expect(find.byType(StaffNavigationDrawer), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey<String>('shell-nav-tab-customers')));
        await tester.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/b${ShellBranch.customers.index}');
        expect(find.byType(StaffNavigationDrawer), findsNothing);
      });
    }

    testWidgets('1280 lp: каждая вкладка sellerShellTabs достижима из drawer; «Корзина» — drawer корзины 420', (
      tester,
    ) async {
      _window(tester, const Size(1280, 800));
      final FakeCartRepository repo = FakeCartRepository();
      serveCart(repo, canonCart());
      repo.onListParked = (ParkedScope scope, String? cursor) async =>
          const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
      final GoRouter router = await _pumpShell(
        tester,
        AppMode.seller,
        overrides: cartOverrides(sync: FakeCartSync(repo), repo: repo),
      );
      for (final ShellTab tab in sellerShellTabs) {
        // С раздела вне каталога: на ветке «Каталог» шапку рисует экран каталога (здесь — заглушка без «бургера»).
        router.go('/b${ShellBranch.orders.index}');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey<String>('top-app-bar-menu')));
        await tester.pumpAndSettle();
        expect(find.byType(StaffNavigationDrawer), findsOneWidget, reason: tab.branch.name);
        await tester.tap(find.byKey(ValueKey<String>('shell-nav-tab-${tab.branch.name}')));
        await tester.pumpAndSettle();
        expect(find.byType(StaffNavigationDrawer), findsNothing, reason: '${tab.branch.name}: выбор закрывает drawer');
        if (tab.branch == ShellBranch.cart) {
          // medium+: корзина — drawer 420 поверх текущего раздела (02 SCR-20.2, ADR-112), ветка не меняется.
          expect(find.byKey(CartDrawer.key), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byKey(CartDrawer.key), findsNothing);
        } else {
          expect(router.routerDelegate.currentConfiguration.uri.path, '/b${tab.branch.index}');
          expect(find.text('page-${tab.branch.name}'), findsOneWidget);
        }
      }
    });

    testWidgets('1280 lp: клиент — NavigationRailApp, как раньше (D6)', (tester) async {
      _window(tester, const Size(1280, 800));
      await _pumpShell(tester, AppMode.customer);
      expect(find.byType(NavigationRailApp), findsOneWidget);
      expect(find.byType(StaffShellHeader), findsNothing);
    });

    testWidgets('HID-сканер: сотрудники — включён, клиент — выключен', (tester) async {
      _window(tester, const Size(390, 844));
      await _pumpShell(tester, AppMode.cashier);
      expect(tester.widget<HidScanScope>(find.byType(HidScanScope)).enabled, isTrue);
      await _pumpShell(tester, AppMode.customer);
      await tester.pump();
      expect(tester.widget<HidScanScope>(find.byType(HidScanScope)).enabled, isFalse);
      expect(hidScannerEnabledFor(AppMode.seller), isTrue);
      expect(hidScannerEnabledFor(AppMode.admin), isTrue);
    });
  });

  group('композиционный корень', () {
    test('штрихкод: scanBarcodeLookupProvider — адаптер SearchRepository каталога', () {
      final ProviderContainer c = _root();
      expect(c.read(scanBarcodeLookupProvider), isA<CatalogScanBarcodeLookup>());
      expect(c.read(catalog.searchRepositoryProvider), isNotNull);
    });

    test('этап G: секция «Принтер» SCR-42, журнал SCR-43 и шапка SCR-30 подключены корнем', () {
      final ProviderContainer c = _root();
      expect(c.read(settings_providers.settingsPrinterSectionProvider), isNotNull);
      expect(c.read(syncJournalPortProvider), isA<DioSyncJournal>());
      expect(c.read(cashierLogoProvider), isNotNull);
      expect(c.read(cashierSyncIndicatorProvider), isNotNull);
      expect(c.read(cashierLogoutProvider), isNotNull);
      expect(c.read(cashierLockProvider), isNotNull);
    });

    test('шапка каталога: SyncIndicator подключён; БД пользователя до входа не открыта', () {
      final ProviderContainer c = _root();
      expect(c.read(catalogSyncIndicatorProvider), isNotNull);
      expect(c.read(catalogHeaderLockProvider), isNotNull, reason: '«Заблокировать» в меню аватара (02 SCR-10.3 A9)');
      expect(c.read(catalogShelfPortProvider), isNotNull);
      expect(c.read(appDatabaseProvider), isNull, reason: 'userId сессии неизвестен');
      expect(c.read(catalogViewerNameProvider), isNull);
    });

    test('«Сразу в корзину» по умолчанию: cashier — вкл., прочие — выкл.; без роли — выкл.', () {
      expect(scanAddsToCartByDefault(RoleCode.cashier), isTrue);
      for (final RoleCode role in <RoleCode>[RoleCode.seller, RoleCode.seniorSeller, RoleCode.admin, RoleCode.owner]) {
        expect(scanAddsToCartByDefault(role), isFalse, reason: role.name);
      }
      expect(scanAddsToCartByDefault(null), isFalse);
      final ProviderContainer c = _root();
      expect(c.read(scanAddsToCartProvider), isFalse, reason: 'до входа роль неизвестна');
    });
  });

  group('БД пользователя (appDatabaseProvider)', () {
    test('не зависит от контроллера сессии (иначе цикл через Dio → CircularDependencyError)', () {
      final ProviderContainer c = _root();
      expect(c.read(appDatabaseProvider), isNull);
      expect(c.exists(sessionControllerProvider), isFalse, reason: 'appDatabaseProvider ← sessionUserIdProvider');
    });

    test('история поиска — только текущего пользователя: выход и смена пользователя очищают её (SCR-10.4.A)', () {
      final ProviderContainer c = _root();
      c.read(sessionUserIdProvider.notifier).set('user-a');
      final ProviderSubscription<List<String>> sub = c.listen(searchHistoryProvider, (_, _) {});
      addTearDown(sub.close);
      c.read(searchHistoryProvider.notifier).add('смеситель');
      expect(c.read(searchHistoryProvider), <String>['смеситель']);

      c.read(sessionUserIdProvider.notifier).set(null); // «Выйти» / SESSION_REVOKED
      expect(c.read(searchHistoryProvider), isEmpty);

      c.read(sessionUserIdProvider.notifier).set('user-a');
      c.read(searchHistoryProvider.notifier).add('труба');
      c.read(sessionUserIdProvider.notifier).set('user-b'); // вход другого сотрудника на том же ПК
      expect(c.read(searchHistoryProvider), isEmpty);
    });

    test('идентификатор не UUID — БД не открывается', () {
      final ProviderContainer c = _root();
      c.read(sessionUserIdProvider.notifier).set('not-a-uuid');
      expect(c.read(appDatabaseProvider), isNull);
    });
  });

  group('настройки отображения SCR-42', () {
    const MediaQueryData base = MediaQueryData(size: Size(390, 844), textScaler: TextScaler.linear(1.2));

    test('размер текста (UI-42-025): max(системный, выбранный), clamp 1,3 (expanded) / 1,5 (compact, medium)', () {
      double scaleOf(MediaQueryData d) => d.textScaler.scale(100) / 100;
      const MediaQueryData phone = MediaQueryData(size: Size(390, 844), textScaler: TextScaler.linear(1.2));
      const MediaQueryData desk = MediaQueryData(size: Size(1280, 800), textScaler: TextScaler.linear(1.2));
      expect(displayMediaQuery(phone, DisplayPreferences.defaults).textScaler, phone.textScaler, reason: 'системный');
      expect(
        scaleOf(displayMediaQuery(phone, const DisplayPreferences(textScale: TextScaleOption.large))),
        closeTo(1.2, 1e-9),
      );
      expect(
        scaleOf(displayMediaQuery(phone, const DisplayPreferences(textScale: TextScaleOption.xlarge))),
        closeTo(1.3, 1e-9),
      );
      expect(
        scaleOf(displayMediaQuery(desk, const DisplayPreferences(textScale: TextScaleOption.xlarge))),
        closeTo(1.3, 1e-9),
      );
      const MediaQueryData bigPhone = MediaQueryData(size: Size(390, 844), textScaler: TextScaler.linear(1.8));
      const MediaQueryData bigDesk = MediaQueryData(size: Size(1280, 800), textScaler: TextScaler.linear(1.8));
      expect(
        scaleOf(displayMediaQuery(bigPhone, const DisplayPreferences(textScale: TextScaleOption.large))),
        closeTo(1.5, 1e-9),
      );
      expect(
        scaleOf(displayMediaQuery(bigDesk, const DisplayPreferences(textScale: TextScaleOption.large))),
        closeTo(1.3, 1e-9),
      );
      expect(maxTextScaleFor(WindowClass.medium), 1.5);
      expect(maxTextScaleFor(WindowClass.large), 1.3);
    });

    test('«Уменьшить анимации» → disableAnimations', () {
      expect(displayMediaQuery(base, DisplayPreferences.defaults).disableAnimations, isFalse);
      expect(displayMediaQuery(base, const DisplayPreferences(reduceMotion: true)).disableAnimations, isTrue);
    });
  });

  test('«Открыть настройки» ОС: на Windows/Linux/macOS — false без вызова плагина', () async {
    for (final TargetPlatform p in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    ]) {
      expect(await openOsAppSettings(p), isFalse, reason: p.name);
    }
  });
}

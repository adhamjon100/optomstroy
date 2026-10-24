// Навигация роли `customer` (RM-E-017 п. 3–4; R0 §9; 02 §4.1, SCR-50 UI-50-012; navigation.md G-7, G-8;
// 10 CUST-021): оболочка клиента — «Каталог · Избранное · Корзина · Мои заказы · Профиль» без кассовых,
// отчётных и админ-разделов; staff-маршруты для клиента недостижимы (guard → /home); при выключенном
// `CUSTOMER_SELF_SERVICE` SCR-50 недостижим (→ SCR-07); привязки корня берут `customer_stock_display` и
// `customerSelfService` из `GET /settings/public`. Синтетические данные (на фейках, не реальная интеграция).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/shells/customer_mode_bindings.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart' as public_settings;
import 'package:optomstroy/core/enums.dart' show CustomerLinkStatus, CustomerStockDisplay;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/components/nav_destination.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/customer_home_view.dart';
import 'package:optomstroy/features/home/home_providers.dart';
import 'package:optomstroy/features/product_details/product_details_providers.dart' as product_details;

import 'support/home_fakes.dart';

const List<String> kStaffPaths = <String>[
  '/catalog',
  '/scan?mode=search',
  '/sync',
  '/cashier',
  '/customers',
  '/customers/new',
  '/transactions',
  '/transactions/t1',
  '/admin/users',
  '/reports',
  '/cart/parked',
];

void main() {
  String? redirect(String location, {bool selfService = true}) => appRedirect(
    status: SessionStatus.authenticated,
    uri: Uri.parse(location),
    mode: AppMode.customer,
    customerSelfService: selfService,
  );

  test('вкладки клиента: Каталог (/home) · Избранное · Корзина · Мои заказы · Профиль', () {
    expect(shellTabsFor(AppMode.customer).map((ShellTab t) => t.branch), <ShellBranch>[
      ShellBranch.home,
      ShellBranch.favorites,
      ShellBranch.cart,
      ShellBranch.orders,
      ShellBranch.profile,
    ]);
    for (final ShellBranch staff in <ShellBranch>[
      ShellBranch.catalog,
      ShellBranch.cashier,
      ShellBranch.customers,
      ShellBranch.transactions,
      ShellBranch.admin,
    ]) {
      expect(shellTabsFor(AppMode.customer).any((ShellTab t) => t.branch == staff), isFalse, reason: staff.name);
    }
  });

  test('guard: staff-маршруты для customer → /home; каталог клиента доступен', () {
    for (final String path in kStaffPaths) {
      expect(redirect(path), '/home', reason: path);
    }
    for (final String path in <String>[
      '/home',
      '/home?view=list&sort=price%3Aasc',
      '/catalog/search?q=F4252',
      '/catalog/c/c-mix',
      '/catalog/filters',
      '/catalog/p/p1',
      '/favorites',
      '/cart',
      '/orders',
      '/profile',
    ]) {
      expect(redirect(path), isNull, reason: path);
    }
  });

  test('CUSTOMER_SELF_SERVICE=false: SCR-50 и каталог клиента недостижимы (→ SCR-07)', () {
    for (final String path in <String>['/home', '/catalog/search?q=ab', '/catalog/p/p1', '/favorites', '/cart']) {
      expect(redirect(path, selfService: false), '/pending-activation', reason: path);
    }
  });

  test('привязки корня: customer_stock_display и customerSelfService — из GET /settings/public', () {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...customerModeOverrides,
        public_settings.customerStockDisplayProvider.overrideWithValue(CustomerStockDisplay.quantity),
        public_settings.publicCustomerSelfServiceProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(catalogCustomerStockDisplayProvider), CustomerStockDisplay.quantity);
    expect(container.read(product_details.customerStockDisplayProvider), CustomerStockDisplay.quantity);
    expect(container.read(catalogCustomerSelfServiceProvider), isFalse);
    expect(container.read(customerSelfServiceEnabledProvider), isFalse, reason: 'guard G-8 по серверному флагу');
    expect(container.read(customerHomeBodyProvider), isNotNull);

    final ProviderContainer defaults = ProviderContainer(
      overrides: <Override>[
        ...customerModeOverrides,
        public_settings.customerStockDisplayProvider.overrideWithValue(CustomerStockDisplay.status),
        public_settings.publicCustomerSelfServiceProvider.overrideWithValue(true),
      ],
    );
    addTearDown(defaults.dispose);
    expect(defaults.read(catalogCustomerStockDisplayProvider), CustomerStockDisplay.status);
    expect(defaults.read(customerSelfServiceEnabledProvider), isTrue);
  });

  test('GET /me → сводка «Мой кабинет»: статус привязки, customerId только при confirmed', () {
    final CustomerHomeSummary proposed = MeCustomerHomePort.summaryFromMe(<String, Object?>{
      'customerLink': <String, Object?>{'status': 'proposed', 'displayNameMasked': 'ОсОО «С***»', 'customerId': 'x'},
    });
    expect(proposed.linkStatus, CustomerLinkStatus.proposed);
    expect(proposed.linkName, 'ОсОО «С***»');
    expect(proposed.customerId, isNull);
    expect(proposed.linked, isFalse);
    final CustomerHomeSummary confirmed = MeCustomerHomePort.summaryFromMe(<String, Object?>{
      'customerLink': <String, Object?>{'status': 'confirmed', 'customerId': 'cust-1'},
    });
    expect(confirmed.linked, isTrue);
    expect(confirmed.customerId, 'cust-1');
    expect(MeCustomerHomePort.summaryFromMe(const <String, Object?>{}).linkStatus, isNull);
  });

  testWidgets('оболочка customer: 5 вкладок без кассы/отчётов/админки; staff-адреса возвращают на /home', (
    WidgetTester tester,
  ) async {
    setWindow(tester, kCompact);
    final HomeHarness h = HomeHarness();
    addTearDown(() => disposeHome(h));
    final GoRouter router = GoRouter(
      routes: $appRoutes,
      initialLocation: '/home',
      redirect: (BuildContext context, GoRouterState state) => appRedirect(
        status: SessionStatus.authenticated,
        uri: state.uri,
        mode: AppMode.customer,
        customerSelfService: true,
      ),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[...h.overrides, appModeProvider.overrideWithValue(AppMode.customer)],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (BuildContext context, Widget? child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
        ),
      ),
    );
    await settle(tester, frames: 10);

    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byKey(CustomerHomeKeys.root), findsOneWidget);
    // compact — `BottomNavBar` оболочки (AdaptiveScaffold, D-18).
    final List<String> labels = tester
        .widget<BottomNavBar>(find.byType(BottomNavBar))
        .destinations
        .map((NavDestination d) => d.label)
        .toList();
    expect(labels, <String>['Каталог', 'Избранное', 'Корзина', 'Мои заказы', 'Профиль']);
    for (final String forbidden in <String>['Касса', 'Клиенты', 'Транзакции', 'Отчёты', 'Админ']) {
      expect(labels.any((String l) => l.contains(forbidden)), isFalse, reason: forbidden);
    }

    String current() => router.routerDelegate.currentConfiguration.uri.path;
    for (final String path in kStaffPaths) {
      router.go(path);
      await settle(tester, frames: 4);
      expect(current(), '/home', reason: path);
      expect(find.byKey(CustomerHomeKeys.root), findsOneWidget, reason: path);
    }

    router.go(const CatalogSearchRoute(q: 'F4252').location);
    await settle(tester, frames: 4);
    expect(current(), '/catalog/search', reason: 'поиск клиента доступен');
  });
}

// HID-скан при открытом drawer корзины (D5, ADR-112; 02 SCR-20.4 «Клавиатура и сканер»): оболочка (`AppShell`) с
// портом «скан в корзину» добавляет найденный товар в корзину, снекбар «Отсканировано … · Отменить» — в drawer, drawer
// остаётся открытым; без порта drawer сначала закрывается, затем — прежнее действие (SCR-14), карточка не оказывается
// под затемнением; drawer под другим экраном (SCR-26 «Новый клиент») скан не получает. Кнопка-итог шапки — `CartHeaderButtonView` на фейковом `CartSync`; синтетические данные, без сети.
// Тест-кейсы 12_TEST_PLAN: T-CART-035 (HID-скан при открытом drawer).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/app/router/shells/shell_tab.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_drawer.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_header_button_view.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' show catalogViewerRoleProvider;
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';

import '../features/cart/support/cart_test_support.dart';
import '../features/scan/support/scan_fakes.dart';
import '../support/f_fakes.dart';

LogicalKeyboardKey _digit(String ch) => LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + int.parse(ch));

/// Пути веток (как в routes.dart); SCR-14 — в ветке каталога.
const Map<ShellBranch, List<String>> _branchPaths = <ShellBranch, List<String>>{
  ShellBranch.catalog: <String>['/catalog', '/catalog/p/:productId', '/catalog/search'],
  ShellBranch.home: <String>['/home'],
  ShellBranch.favorites: <String>['/favorites'],
  ShellBranch.cart: <String>['/cart'],
  ShellBranch.customers: <String>['/customers'],
  ShellBranch.cashier: <String>['/cashier'],
  ShellBranch.transactions: <String>['/transactions'],
  ShellBranch.orders: <String>['/orders'],
  ShellBranch.admin: <String>['/admin/users'],
  ShellBranch.profile: <String>['/profile'],
  ShellBranch.reports: <String>['/reports'],
};

void main() {
  late FakeCartRepository repo;
  late FakeCartSync sync;
  late FakeScanLookup lookup;
  late Duration now;

  setUp(() {
    repo = FakeCartRepository();
    sync = FakeCartSync(repo);
    lookup = FakeScanLookup()..online[eanFound] = const Success<ScanLookupResult>(frap);
    now = Duration.zero;
  });

  Future<GoRouter> pumpApp(WidgetTester tester, {ScanCartPort? port}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    serveCart(repo, canonCart());
    repo.onListParked = (ParkedScope scope, String? cursor) async =>
        const Success<PageResult<CartParkedSummary>>(PageResult<CartParkedSummary>(items: <CartParkedSummary>[]));
    final GoRouter router = GoRouter(
      initialLocation: '/orders',
      routes: <RouteBase>[
        StatefulShellRoute.indexedStack(
          builder: (BuildContext context, GoRouterState state, StatefulNavigationShell shell) =>
              AppShell(navigationShell: shell),
          branches: <StatefulShellBranch>[
            for (final ShellBranch b in ShellBranch.values)
              StatefulShellBranch(
                routes: <RouteBase>[
                  for (final String p in _branchPaths[b]!)
                    GoRoute(
                      path: p,
                      builder: (BuildContext context, GoRouterState state) =>
                          Scaffold(body: Center(child: Text('page:${state.uri}'))),
                    ),
                ],
              ),
          ],
        ),
        // SCR-26 «Новый клиент» — корневой маршрут: из выбора клиента в drawer он ложится поверх drawer.
        GoRoute(
          path: '/customers/new',
          builder: (BuildContext context, GoRouterState state) => const Scaffold(body: Center(child: Text('SCR-26'))),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appModeProvider.overrideWithValue(AppMode.seller),
          catalogViewerRoleProvider.overrideWithValue(RoleCode.seller),
          catalogCartButtonProvider.overrideWithValue((BuildContext context) => const CartHeaderButtonView()),
          ...cartOverrides(sync: sync, repo: repo),
          scannerWedgeServiceProvider.overrideWith((Ref ref) {
            final ScannerWedgeService s = ScannerWedgeService(now: () => now);
            ref.onDispose(s.dispose);
            return s;
          }),
          scanBarcodeLookupProvider.overrideWithValue(lookup),
          scanCartPortProvider.overrideWithValue(port),
          scanAddsToCartProvider.overrideWithValue(false),
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

  Future<void> scan(WidgetTester tester, String code) async {
    for (final String ch in code.split('')) {
      now += const Duration(milliseconds: 8);
      await tester.sendKeyDownEvent(_digit(ch), character: ch);
      await tester.sendKeyUpEvent(_digit(ch));
    }
    now += const Duration(milliseconds: 8);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byKey(CartHeaderButtonView.buttonKey));
    await tester.pumpAndSettle();
    expect(find.byKey(CartDrawer.key), findsOneWidget);
  }

  testWidgets('с портом «скан в корзину»: товар добавлен, снекбар в drawer, drawer открыт, карточка не открыта', (
    tester,
  ) async {
    final FakeScanCart cart = FakeScanCart();
    final GoRouter router = await pumpApp(tester, port: cart);
    await openDrawer(tester);
    await scan(tester, eanFound);
    expect(cart.added, <String>[frap.variantId]);
    expect(cart.keys.single, isNotEmpty, reason: 'ключ идемпотентности на каждый скан');
    expect(find.byKey(CartDrawer.key), findsOneWidget, reason: 'drawer остаётся открытым');
    expect(find.textContaining('Отсканировано $eanFound'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(ScaffoldMessenger).last, matching: find.textContaining('Отсканировано')),
      findsOneWidget,
      reason: 'снекбар — в ScaffoldMessenger drawer (над затемнением)',
    );
    expect(router.routerDelegate.currentConfiguration.uri.path, '/orders', reason: 'SCR-14 не открыт');
    await tester.pumpAndSettle(const Duration(seconds: 9));
  });

  testWidgets('drawer под SCR-26 «Новый клиент»: скан корзине не уходит — действует обычный путь сканера', (
    tester,
  ) async {
    final FakeScanCart cart = FakeScanCart();
    final GoRouter router = await pumpApp(tester, port: cart);
    await openDrawer(tester);
    unawaited(router.push<void>('/customers/new?returnTo=cart'));
    await tester.pumpAndSettle();
    expect(find.text('SCR-26'), findsOneWidget);
    expect(CartDrawer.isOpen, isTrue, reason: 'drawer под SCR-26 остаётся открытым');
    expect(CartDrawer.isCurrent, isFalse);
    // Неизвестный код: корзина (скрытый drawer) показала бы «не найдено» у себя и осталась на SCR-26; обычный путь
    // HidScanScope — снекбар оболочки и SCR-11 с кодом (02 SCR-10.4.A).
    await scan(tester, eanMissing);
    await tester.pumpAndSettle();
    expect(cart.added, isEmpty);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/catalog/search', reason: 'обычный путь сканера');
    CartDrawer.close();
    await tester.pumpAndSettle(const Duration(seconds: 9));
  });

  testWidgets('без порта: drawer закрывается, затем прежнее действие — SCR-14 найденного товара', (tester) async {
    await pumpApp(tester);
    await openDrawer(tester);
    await scan(tester, eanFound);
    await tester.pumpAndSettle();
    expect(find.byKey(CartDrawer.key), findsNothing, reason: 'drawer закрыт до перехода');
    expect(find.textContaining('page:/catalog/p/${frap.productId}'), findsOneWidget);
  });
}

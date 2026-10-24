// HID-скан кассы в оболочке (02 п. 2.2.11; SCR-30 UI-30-019, AC-UI-30-009; SCR-38.12; ревью G-flutter-ui-3,
// G-trace-3): на SCR-30 код заказа → `GET /orders?q=&status=…` → один заказ → SCR-38 `?orderId=` (без поиска товара
// по штрихкоду); ноль/несколько — лист «Найти заказ» с кодом; на SCR-38 (root-маршрут над оболочкой) скан
// игнорируется с подсказкой `payment_scan_disabled`; роль без приёма оплаты — обычный поиск товара.
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/shells/app_shell.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cashier/cashier_providers.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/cashier/presentation/widgets/cashier_sheets.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/scan/presentation/hid_scan_scope.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';

import '../features/cashier/support/cashier_harness.dart' show awaiting;
import '../features/scan/support/scan_fakes.dart';
import '../support/f_fakes.dart';

LogicalKeyboardKey _digit(String ch) => LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + int.parse(ch));

const String _code = '2026000123';

void main() {
  late FakeScanLookup lookup;
  late FakeOrdersRepository orders;
  late Duration now;

  setUp(() {
    lookup = FakeScanLookup();
    orders = FakeOrdersRepository();
    now = Duration.zero;
  });

  Future<GoRouter> pumpApp(WidgetTester tester, {RoleCode role = RoleCode.cashier}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1366, 900);
    addTearDown(tester.view.reset);
    final GlobalKey<NavigatorState> root = GlobalKey<NavigatorState>();
    final GoRouter router = GoRouter(
      navigatorKey: root,
      initialLocation: '/cashier',
      routes: <RouteBase>[
        // SCR-38 — root-маршрут над оболочкой (как в routes.dart).
        GoRoute(
          path: '/payments/new',
          parentNavigatorKey: root,
          builder: (_, GoRouterState s) => Scaffold(body: Text('loc:${s.uri}')),
        ),
        ShellRoute(
          builder: (BuildContext context, GoRouterState state, Widget child) => Consumer(
            builder: (BuildContext context, WidgetRef ref, _) =>
                HidScanScope(onEvent: (HidScanEvent e) => cashierHidOverride(context, ref, e), child: child),
          ),
          routes: <RouteBase>[
            GoRoute(
              path: '/cashier',
              builder: (_, _) => const Scaffold(body: Text('cashier')),
            ),
            GoRoute(
              path: '/catalog/search',
              builder: (_, GoRouterState s) => Scaffold(body: Text('search:${s.uri}')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          scannerWedgeServiceProvider.overrideWith((ref) {
            final ScannerWedgeService s = ScannerWedgeService(now: () => now);
            ref.onDispose(s.dispose);
            return s;
          }),
          scanBarcodeLookupProvider.overrideWithValue(lookup),
          scanCartPortProvider.overrideWithValue(null),
          scanAddsToCartProvider.overrideWithValue(false),
          cashierViewerRoleProvider.overrideWithValue(role),
          debtPaymentsFromPosProvider.overrideWithValue(false),
          ordersRepositoryProvider.overrideWithValue(orders),
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
    await tester.pumpAndSettle();
  }

  Result<OrdersPage> page(List<OrderSummary> items) =>
      Success<OrdersPage>(OrdersPage(page: PageResult<OrderSummary>(items: items)));

  testWidgets('SCR-30: скан кода заказа, один заказ → SCR-38 этого заказа (AC-UI-30-009), товар не ищется', (
    tester,
  ) async {
    orders.onList = (OrdersQuery q) async => page(<OrderSummary>[awaiting('o1', 123)]);
    await pumpApp(tester);
    await scan(tester, _code);
    final OrdersQuery q = orders.calls.single.args.single! as OrdersQuery;
    expect(q.q, _code);
    expect(q.statuses, kLookupPayableStatuses);
    expect(find.text('loc:/payments/new?orderId=o1'), findsOneWidget);
    expect(lookup.onlineCalls, isEmpty);
  });

  testWidgets('SCR-30: ни одного/несколько заказов — лист «Найти заказ» с введённым кодом', (tester) async {
    orders.onList = (OrdersQuery q) async => page(<OrderSummary>[awaiting('o1', 123), awaiting('o2', 124)]);
    await pumpApp(tester);
    await scan(tester, _code);
    expect(find.byType(CashierLookupSheet), findsOneWidget);
    final SearchBar field = tester.widget<SearchBar>(find.byKey(const ValueKey<String>('cashier-lookup-field')));
    expect(field.controller!.text, _code);
    expect(find.text('cashier'), findsOneWidget);
    expect(lookup.onlineCalls, isEmpty);
  });

  testWidgets('SCR-38: скан игнорируется — подсказка «Сканирование недоступно во время оплаты»', (tester) async {
    final GoRouter router = await pumpApp(tester);
    // SCR-38 открывается `push` поверх оболочки (cashierPush): HidScanScope оболочки остаётся в дереве.
    unawaited(router.push('/payments/new?orderId=o1'));
    await tester.pumpAndSettle();
    expect(find.text('loc:/payments/new?orderId=o1'), findsOneWidget);
    await scan(tester, _code);
    expect(find.text('Сканирование недоступно во время оплаты'), findsOneWidget);
    expect(orders.calls, isEmpty);
    expect(lookup.onlineCalls, isEmpty);
    expect(find.text('loc:/payments/new?orderId=o1'), findsOneWidget);
  });

  testWidgets('admin на SCR-30 (без приёма оплаты) — касса скан не перехватывает', (tester) async {
    await pumpApp(tester, role: RoleCode.admin);
    await scan(tester, _code);
    expect(orders.calls, isEmpty);
    expect(lookup.onlineCalls, <String>[_code]);
  });
}

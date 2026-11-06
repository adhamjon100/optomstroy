// SCR-38 «Приём оплаты» по настоящему маршруту `PaymentNewRoute` (`/payments/new?orderId=`; 02 SCR-38; 10 KIOSK-019 —
// кассир принимает заявки с планшета как обычные заказы): `go('/payments/new?orderId=o2')` сразу после заказа o1
// строит новый экран — начальная загрузка `GET /orders/o2` выполняется, экран выходит из загрузки. Раньше `State`
// переиспользовался (ключ страницы go_router один для пути без query), `open()` не вызывался и экран оставался пустым
// (ревью P-002 spec-drift-16; WP-A11 #384 обходил это переходом через `/cashier` в
// `integration_test/kiosk_flow_test.dart`).
// Трассировка: 12 T-CASH-016 (точки входа SCR-38 с `orderId`), T-KIOSK-027 (касса принимает заявку с планшета).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cashier/presentation/screens/payment_screen.dart';
import 'package:optomstroy/features/cashier/presentation/state/payment_controller.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';

import '../support/cashier_harness.dart';

const Size _window = Size(1366, 900);

Future<GoRouter> _pumpRoute(WidgetTester t, CashierHarness h, String initial) async {
  final GoRouter router = GoRouter(
    initialLocation: initial,
    routes: <RouteBase>[
      $paymentNewRoute,
      GoRoute(path: '/cashier', builder: (BuildContext c, GoRouterState s) => const Text('SCR-30')),
    ],
  );
  addTearDown(router.dispose);
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = _window;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: h.overrides,
      child: MaterialApp.router(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true, size: _window),
          child: child!,
        ),
      ),
    ),
  );
  await CashierHarness.settle(t);
  return router;
}

List<Object?> _gets(CashierHarness h) =>
    h.orders.calls.where((c) => c.method == 'get').map((c) => c.args.first).toList();

PaymentScreenState _stateOf(WidgetTester t, String orderId) {
  final ProviderContainer c = ProviderScope.containerOf(t.element(find.byType(PaymentScreen)));
  return c.read(paymentControllerProvider((orderId: orderId, customerId: null, method: null)));
}

void main() {
  testWidgets('T-CASH-016 SCR-38: go() на другой orderId — новый экран, GET /orders/o2 и выход из загрузки', (
    WidgetTester t,
  ) async {
    final CashierHarness h = CashierHarness();
    h.orders.onGet = (String id, bool refresh) async => Success<OrderDetails>(
      OrderDetails(order: payOrder(id: id), allowedActions: <OrderAction>{OrderAction.pay}),
    );
    final GoRouter router = await _pumpRoute(t, h, '/payments/new?orderId=o1');
    expect(find.byKey(PaymentScreen.rootKey), findsOneWidget);
    expect(_gets(h), <Object?>['o1']);
    expect(_stateOf(t, 'o1').phase, PaymentPhase.ready);
    final State<StatefulWidget> first = t.state(find.byType(PaymentScreen));

    router.go('/payments/new?orderId=o2');
    await CashierHarness.settle(t);

    expect(find.byKey(PaymentScreen.rootKey), findsOneWidget);
    expect(t.widget<PaymentScreen>(find.byType(PaymentScreen)).orderId, 'o2');
    expect(t.state(find.byType(PaymentScreen)), isNot(same(first)), reason: 'новый State — open() для o2');
    expect(_gets(h), <Object?>['o1', 'o2']);
    final PaymentScreenState s = _stateOf(t, 'o2');
    expect(s.phase, isNot(PaymentPhase.loading));
    expect(s.phase, PaymentPhase.ready);
    expect(s.order?.id, 'o2');
    await h.payments.dispose();
  });

  testWidgets('T-CASH-016 SCR-38: тот же адрес — тот же экран, повторной начальной загрузки нет', (
    WidgetTester t,
  ) async {
    final CashierHarness h = CashierHarness();
    h.orders.onGet = (String id, bool refresh) async => Success<OrderDetails>(
      OrderDetails(order: payOrder(id: id), allowedActions: <OrderAction>{OrderAction.pay}),
    );
    final GoRouter router = await _pumpRoute(t, h, '/payments/new?orderId=o1&method=cash');
    final State<StatefulWidget> first = t.state(find.byType(PaymentScreen));

    router.go('/payments/new?orderId=o1&method=cash');
    await CashierHarness.settle(t);

    expect(t.state(find.byType(PaymentScreen)), same(first));
    expect(_gets(h), <Object?>['o1']);
    await h.payments.dispose();
  });
}

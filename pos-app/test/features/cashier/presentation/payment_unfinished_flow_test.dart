// P-IDEMP для ручного подтверждения QR и аннулирования (02 ч. D §0.3 п. 5(б); SCR-30 п. 11, AC-UI-30-017;
// SCR-38.11; ревью G-flutter-ui-2): сеть пропала в `confirm-manual` / `void` → «Результат неизвестен» на SCR-38;
// уход с экрана → баннер SCR-30 → SCR-38 того же заказа снова в состоянии «Результат неизвестен», «Проверить» —
// тот же запрос с тем же `Idempotency-Key`; «Отменить операцию» удаляет сведения любого вида (баннер исчезает).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/cashier/presentation/screens/cashier_dashboard_screen.dart';
import 'package:optomstroy/features/cashier/presentation/screens/payment_screen.dart';
import 'package:optomstroy/features/cashier/presentation/state/unfinished_operations.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

import '../support/cashier_harness.dart';

const NetworkFailure _timeout = NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true);

Payment _paid(String id, Money amount) =>
    Payment(id: id, orderId: 'o1', method: PaymentMethod.qrBakai, status: PaymentStatus.received, amount: amount);

/// SCR-30 (`/cashier`) и SCR-38 (`/payments/new?orderId=`) с настоящими экранами.
Future<GoRouter> _pumpApp(WidgetTester t, CashierHarness h) async {
  final GoRouter router = GoRouter(
    initialLocation: '/cashier',
    routes: <RouteBase>[
      GoRoute(path: '/cashier', builder: (BuildContext c, GoRouterState s) => const CashierDashboardScreen()),
      GoRoute(
        path: '/payments/new',
        builder: (BuildContext c, GoRouterState s) => PaymentScreen(orderId: s.uri.queryParameters['orderId']),
      ),
    ],
  );
  addTearDown(router.dispose);
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(1366, 900);
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
          data: MediaQuery.of(context).copyWith(disableAnimations: true, size: const Size(1366, 900)),
          child: child!,
        ),
      ),
    ),
  );
  await CashierHarness.settle(t);
  return router;
}

CashierHarness _harness(Payment qr) {
  final CashierHarness h = CashierHarness();
  final Order o = payOrder(method: PaymentMethod.qrBakai, payments: <Payment>[qr]);
  h.orders.onGet = (String id, bool refresh) async =>
      Success<OrderDetails>(OrderDetails(order: o, allowedActions: <OrderAction>{OrderAction.pay}));
  h.cashier.onDashboard = () async => Success<PosDashboard>(dashboard());
  return h;
}

Future<void> _tap(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey<String>(key)));
  await t.tap(find.byKey(ValueKey<String>(key)));
  await CashierHarness.settle(t);
}

List<({String method, List<Object?> args})> _callsOf(CashierHarness h, String method) =>
    h.payments.calls.where((({String method, List<Object?> args}) c) => c.method == method).toList();

void main() {
  testWidgets('confirm-manual: сеть пропала → уход → баннер SCR-30 → SCR-38 «Проверить» тем же ключом', (
    WidgetTester t,
  ) async {
    // AC-UI-30-021: незавершённая операция не отправляется автоматически; повтор — только «Проверить» тем же ключом.
    final CashierHarness h = _harness(qrPayment(autoConfirm: false));
    int n = 0;
    h.payments.onConfirmManual = (String id, ConfirmManualRequest r, String key, String? token) async =>
        ++n == 1 ? const FailureResult<Payment>(_timeout) : Success<Payment>(_paid(id, r.receivedAmount));
    final GoRouter router = await _pumpApp(t, h);
    expect(find.byKey(const ValueKey<String>('cashier-unfinished-check')), findsNothing);

    unawaited(router.push('/payments/new?orderId=o1'));
    await CashierHarness.settle(t);
    await _tap(t, 'payment-confirm-manual');
    await t.enterText(find.byKey(const ValueKey<String>('payment-manual-ref')), 'BK-77123');
    await CashierHarness.settle(t, 2);
    await _tap(t, 'payment-manual-submit');
    // Результат неизвестен — на самом экране (UI-38-018), повторное «Подтвердить вручную» недоступно.
    expect(find.byKey(const ValueKey<String>('payment-unknown')), findsOneWidget);
    expect(t.widget<AppButton>(find.byKey(const ValueKey<String>('payment-confirm-manual'))).onPressed, isNull);

    // Уход со SCR-38 (контроллер экрана уничтожен) → SCR-30 показывает баннер.
    router.pop();
    await CashierHarness.settle(t);
    expect(find.text('Незавершённая операция: подтверждение QR по заказу № POS-2026-000123'), findsOneWidget);
    await _tap(t, 'cashier-unfinished-check');
    expect(find.byKey(PaymentScreen.rootKey), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('payment-unknown')), findsOneWidget);

    await _tap(t, 'payment-unknown-check');
    final List<({String method, List<Object?> args})> calls = _callsOf(h, 'confirmManual');
    expect(calls, hasLength(2));
    expect(calls[1].args[2], calls[0].args[2]); // тот же Idempotency-Key
    expect(calls[1].args[0], 'pay-qr');
    expect((calls[1].args[1]! as ConfirmManualRequest).bankReference, 'BK-77123'); // то же тело
    expect(h.stepUps, <String>['payment.qr.confirm_manual', 'payment.qr.confirm_manual']); // P-STEPUP-PRE
    expect(find.byKey(const ValueKey<String>('payment-success')), findsOneWidget);

    // Окончательный ответ — сведения удалены, баннера SCR-30 нет.
    final ProviderContainer c = ProviderScope.containerOf(t.element(find.byType(PaymentScreen)));
    expect(c.read(cashierUnfinishedOperationsProvider), isEmpty);
    await h.payments.dispose();
  });

  testWidgets('void: сеть пропала → «Проверить» на SCR-38 тем же ключом; затем SCR-38 заново — без «неизвестен»', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _harness(
      qrPayment(status: PaymentStatus.manualConfirm, review: ReviewReason.amountMismatch),
    );
    int n = 0;
    h.payments.onVoid = (String id, VoidPaymentRequest r, String key, String? token) async => ++n == 1
        ? const FailureResult<Payment>(_timeout)
        : Success<Payment>(
            Payment(
              id: id,
              orderId: 'o1',
              method: PaymentMethod.qrBakai,
              status: PaymentStatus.voided,
              amount: const Money(1600750),
            ),
          );
    final GoRouter router = await _pumpApp(t, h);
    unawaited(router.push('/payments/new?orderId=o1'));
    await CashierHarness.settle(t);
    await _tap(t, 'payment-void');
    await _tap(t, 'void-reason-customer_refused');
    await _tap(t, 'void-submit');
    expect(find.byKey(const ValueKey<String>('payment-unknown')), findsOneWidget);

    router.pop();
    await CashierHarness.settle(t);
    expect(find.text('Незавершённая операция: аннулирование платежа № POS-2026-000123'), findsOneWidget);
    await _tap(t, 'cashier-unfinished-check');
    expect(find.byKey(const ValueKey<String>('payment-unknown')), findsOneWidget);
    await _tap(t, 'payment-unknown-check');
    final List<({String method, List<Object?> args})> calls = _callsOf(h, 'voidPayment');
    expect(calls, hasLength(2));
    expect(calls[1].args[2], calls[0].args[2]);
    expect((calls[1].args[1]! as VoidPaymentRequest).reasonCode, PaymentVoidReasonCode.customerRefused);
    expect(find.byKey(const ValueKey<String>('payment-unknown')), findsNothing);
    await h.payments.dispose();
  });

  testWidgets('«Отменить операцию» удаляет незавершённое подтверждение QR — баннера SCR-30 больше нет', (
    WidgetTester t,
  ) async {
    final CashierHarness h = _harness(qrPayment(autoConfirm: false));
    h.payments.onConfirmManual = (String id, ConfirmManualRequest r, String key, String? token) async =>
        const FailureResult<Payment>(_timeout);
    final GoRouter router = await _pumpApp(t, h);
    unawaited(router.push('/payments/new?orderId=o1'));
    await CashierHarness.settle(t);
    await _tap(t, 'payment-confirm-manual');
    await t.enterText(find.byKey(const ValueKey<String>('payment-manual-ref')), 'BK-77123');
    await CashierHarness.settle(t, 2);
    await _tap(t, 'payment-manual-submit');
    expect(find.byKey(const ValueKey<String>('payment-unknown')), findsOneWidget);

    await _tap(t, 'payment-unknown-discard');
    // ConfirmDialog «Отменить операцию» (деструктивная кнопка с тем же текстом).
    await t.tap(find.text('Отменить операцию').last);
    await CashierHarness.settle(t);
    expect(find.byKey(const ValueKey<String>('payment-unknown')), findsNothing);
    final ProviderContainer c = ProviderScope.containerOf(t.element(find.byType(PaymentScreen)));
    expect(c.read(cashierUnfinishedOperationsProvider), isEmpty);

    router.pop();
    await CashierHarness.settle(t);
    expect(find.byKey(const ValueKey<String>('cashier-unfinished-check')), findsNothing);
    await h.payments.dispose();
  });
}

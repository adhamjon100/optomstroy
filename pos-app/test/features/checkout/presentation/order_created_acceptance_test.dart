// T-UI-022 (12 §3.9) — недостающие кейсы приёмочного набора SCR-22 «Заказ создан / QR» (02 SCR-22.13): AC-UI-22-005,
// 006, 009, 010, 011. Остальные — order_created_screen_test.dart. Фейки — checkout_test_support.dart; данные
// синтетические, без реальной 1С и банка.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart' show CheckoutQrMode;
import 'package:optomstroy/features/checkout/presentation/screens/order_created_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

import '../checkout_test_support.dart';

const OrderCreatedScreen screen = OrderCreatedScreen(orderId: 'order-1', paymentId: 'pay-1');

CheckoutHarness harness({
  RoleCode role = RoleCode.cashier,
  required Order order,
  Set<PaymentAction> actions = const <PaymentAction>{},
  CheckoutQrMode qr = const CheckoutQrMode(provider: QrProviderMode.onec, autoConfirm: true),
}) {
  final CheckoutHarness h = CheckoutHarness(role: role, qr: qr);
  h.fakes.orders.onGet = (String id, bool refresh) async => Success<OrderDetails>(OrderDetails(order: order));
  h.fakes.payments.onGet = (String id, bool refresh) async =>
      Success<PaymentDetails>(PaymentDetails(payment: order.payments.first, allowedActions: actions));
  addTearDown(h.fakes.payments.dispose);
  return h;
}

Order qrOrder(Payment p) => createdOrder(
  method: PaymentMethod.qrBakai,
  status: OrderStatus.awaitingPayment,
  payments: <Payment>[p],
  onecNumber: 'УТ-0001234',
);

int watchCalls(CheckoutHarness h) => h.fakes.payments.calls.where((c) => c.method == 'watch').length;

void main() {
  testWidgets('AC-UI-22-005: ручное подтверждение с другой суммой — предупреждение до отправки, после ответа «Требует '
      'разбора»; заказ не отмечается оплаченным', (WidgetTester tester) async {
    final CheckoutHarness h = harness(
      order: qrOrder(qrPayment(autoConfirm: false)),
      qr: const CheckoutQrMode(),
      actions: const <PaymentAction>{PaymentAction.confirmManual},
    );
    h.fakes.payments.onConfirmManual = (String id, ConfirmManualRequest r, String key, String? stepUp) async =>
        Success<Payment>(qrPayment(status: PaymentStatus.manualConfirm, reviewReason: ReviewReason.amountMismatch));
    await h.pump(tester, screen);
    await tapKey(tester, const ValueKey<String>('order-created-confirm-manual'));
    Finder field(String key) =>
        find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(EditableText));
    await tester.enterText(field('manual-amount'), '16000');
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('manual-mismatch')), findsOneWidget, reason: 'до отправки');
    await tester.enterText(field('manual-ref'), 'BK-778812');
    await tapKey(tester, const ValueKey<String>('manual-submit'));
    final ConfirmManualRequest req =
        h.fakes.payments.calls.firstWhere((c) => c.method == 'confirmManual').args[1]! as ConfirmManualRequest;
    expect(req.receivedAmount, Money.som(16000));
    expect(find.text('Сумма оплаты не совпадает с заказом — требуется разбор кассиром'), findsOneWidget);
    expect(find.text('Оплата получена'), findsNothing, reason: 'заказ не отмечен оплаченным');
    expect(h.nav.calls, isNot(contains('order:order-1')));
  });

  testWidgets('AC-UI-22-006: QR_WEBHOOK_ENABLED=false — нет «Получено автоматически» и обещания автоотметки', (
    WidgetTester tester,
  ) async {
    final CheckoutHarness h = harness(
      order: qrOrder(qrPayment(autoConfirm: false)),
      qr: const CheckoutQrMode(provider: QrProviderMode.bakai, autoConfirm: false),
      actions: const <PaymentAction>{PaymentAction.confirmManual},
    );
    await h.pump(tester, screen);
    expect(textContaining('автоматически'), findsNothing);
    h.fakes.payments.watchController.add(
      Success<PaymentDetails>(
        PaymentDetails(
          payment: qrPayment(
            status: PaymentStatus.received,
            autoConfirm: false,
            confirmation: PaymentConfirmationKind.manual,
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.text('Оплата получена'), findsOneWidget);
    expect(find.text('Получено автоматически'), findsNothing);
  });

  testWidgets('AC-UI-22-009: «Новый заказ», «Назад» и Esc ведут на главный экран роли; в SCR-21 не вернуться', (
    WidgetTester tester,
  ) async {
    final CheckoutHarness h = harness(order: createdOrder(status: OrderStatus.awaitingPayment));
    await h.pump(tester, screen);
    await tapKey(tester, const ValueKey<String>('order-created-new'));
    expect(h.nav.calls.where((String c) => c == 'home'), hasLength(1));
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(h.nav.calls.where((String c) => c == 'home'), hasLength(2), reason: 'системный «Назад»');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(h.nav.calls.where((String c) => c == 'home'), hasLength(3));
    expect(h.nav.calls.where((String c) => c.startsWith('backToCart')), isEmpty);
    expect(find.byType(OrderCreatedScreen), findsOneWidget, reason: 'маршрут не снят «Назад» (PopScope)');
  });

  testWidgets('AC-UI-22-010: ошибка принтера — «Не удалось напечатать · Повторить» в строке документа; статус '
      'заказа не меняется', (WidgetTester tester) async {
    final CheckoutHarness h = harness(order: qrOrder(qrPayment()))..printerOk = false;
    h.fakes.orders.onDocument = (String id, OrderDocumentKind kind, PrintPaper f, bool copy) async =>
        const Success<OrderDocumentFile>(OrderDocumentFile(bytes: <int>[1, 2, 3], fileName: 'invoice.pdf'));
    await h.pump(tester, screen);
    await tapKey(tester, const ValueKey<String>('order-created-doc-print-invoice'));
    expect(find.text('Не удалось напечатать · Повторить'), findsOneWidget);
    expect(find.text('Ожидаем оплату'), findsOneWidget, reason: 'оплата/статус не затронуты');
    h.printerOk = true;
    await tapKey(tester, const ValueKey<String>('order-created-doc-retry-invoice'));
    expect(h.printed, <String>['invoice.pdf', 'invoice.pdf']);
    expect(find.text('Напечатан'), findsOneWidget);
  });

  testWidgets('AC-UI-22-011: long-polling приостанавливается при idle-блокировке, сворачивании и уходе с экрана, '
      'возобновляется после; одновременно — один ожидающий запрос', (WidgetTester tester) async {
    final CheckoutHarness h = harness(order: qrOrder(qrPayment()));
    final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    await h.pump(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (BuildContext context, bool v, Widget? child) => TickerMode(enabled: v, child: child!),
        child: screen,
      ),
    );
    // ignore: close_sinks — поток фейка закрывает harness (addTearDown dispose)
    final StreamController<Result<PaymentDetails>> polls = h.fakes.payments.watchController;
    expect(watchCalls(h), 1);
    expect(polls.hasListener, isTrue);

    // Idle-блокировка SCR-08.
    final ProviderContainer c = ProviderScope.containerOf(tester.element(find.byType(OrderCreatedScreen)));
    c.read(testSessionLockedProvider.notifier).set(true);
    await settle(tester);
    expect(polls.hasListener, isFalse, reason: 'заблокировано — запроса нет');
    c.read(testSessionLockedProvider.notifier).set(false);
    await settle(tester);
    expect((polls.hasListener, watchCalls(h)), (true, 2), reason: 'возобновлено после разблокировки');

    // Приложение свёрнуто.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle(tester);
    expect(polls.hasListener, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect((polls.hasListener, watchCalls(h)), (true, 3));

    // Экран перекрыт другим маршрутом / неактивная ветка (TickerMode выключен).
    visible.value = false;
    await settle(tester);
    expect(polls.hasListener, isFalse);
    visible.value = true;
    await settle(tester);
    expect((polls.hasListener, watchCalls(h)), (true, 4));
  });
}

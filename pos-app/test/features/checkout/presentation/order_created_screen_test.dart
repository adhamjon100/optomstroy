// Widget-тесты SCR-22 «Заказ создан / QR для оплаты» (RM-F-006, RM-F-013; 02 AC-UI-22-001…014): QR-состояния
// (ожидание long-polling, оплачено, истёк и перевыпуск, ручное подтверждение со step-up, QR не получен из 1С),
// баннер «Ожидает отправки в 1С», действия по ролям и способам оплаты.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
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

Order qrOrder(
  Payment p, {
  List<ApiWarning> warnings = const <ApiWarning>[],
  OrderStatus status = OrderStatus.awaitingPayment,
}) => createdOrder(
  method: PaymentMethod.qrBakai,
  status: status,
  payments: <Payment>[p],
  warnings: warnings,
  onecNumber: 'УТ-0001234',
);

void main() {
  group('SCR-22 QR', () {
    testWidgets(
      'AC-UI-22-001, AC-UI-22-013: QR из 1С, сумма, таймер, «Ожидаем оплату»; long-polling; оплачено → SCR-24 через 2 с',
      (WidgetTester tester) async {
        final CheckoutHarness h = harness(order: qrOrder(qrPayment()));
        await h.pump(tester, screen);
        expect(find.byKey(const ValueKey<String>('order-created-qr-shown')), findsOneWidget);
        expect(find.byKey(const ValueKey<String>('qr-panel-image')), findsOneWidget);
        expect(find.text('Ожидаем оплату'), findsOneWidget);
        expect(textContaining('осталось 15:00'), findsOneWidget);
        expect(textContaining('Оплата заказа POS-2026-000123'), findsOneWidget);
        expect(h.fakes.payments.calls.where((c) => c.method == 'watch').single.args.first, 'pay-1');
        // Автоподтверждение 1С — ручного подтверждения нет.
        expect(find.byKey(const ValueKey<String>('order-created-confirm-manual')), findsNothing);

        h.fakes.payments.watchController.add(
          Success<PaymentDetails>(
            PaymentDetails(
              payment: qrPayment(status: PaymentStatus.received, confirmation: PaymentConfirmationKind.webhook),
            ),
          ),
        );
        await settle(tester);
        expect(find.text('Оплата получена'), findsOneWidget);
        expect(find.text('Получено автоматически'), findsOneWidget);
        await tester.pump(OrderCreatedScreen.paidRedirect);
        await settle(tester);
        expect(h.nav.calls, contains('order:order-1'));
      },
    );

    testWidgets('AC-UI-22-003: истёк → «Перевыпустить QR» — тот же payment_id, QR снова показан', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = harness(order: qrOrder(qrPayment(status: PaymentStatus.qrExpired)));
      h.fakes.payments.onCreateForOrder = (String orderId, OrderPaymentRequest r, String key) async =>
          Success<OrderPaymentResult>(
            OrderPaymentResult(
              payment: qrPayment(expiresAt: testNow.add(const Duration(minutes: 15))),
              orderPaidAmount: Money.zero,
              orderIsPaid: false,
              created: false,
            ),
          );
      await h.pump(tester, screen);
      expect(find.text('Срок QR истёк'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('order-created-confirm-manual')), findsNothing);
      await tapKey(tester, const ValueKey<String>('order-created-reissue'));
      final ({String method, List<Object?> args}) call = h.fakes.payments.calls.firstWhere(
        (c) => c.method == 'createForOrder',
      );
      expect((call.args[1]! as OrderPaymentRequest).reissueQr, isTrue);
      expect(find.byKey(const ValueKey<String>('order-created-qr-shown')), findsOneWidget);
    });

    testWidgets('AC-UI-22-004/005: ручное подтверждение (QR_PROVIDER=none) — кассир со step-up; сумма отличается — '
        'предупреждение', (WidgetTester tester) async {
      final CheckoutHarness h = harness(
        order: qrOrder(qrPayment(autoConfirm: false)),
        qr: const CheckoutQrMode(),
        actions: const <PaymentAction>{PaymentAction.confirmManual},
      );
      h.fakes.payments.onConfirmManual = (String id, ConfirmManualRequest r, String key, String? stepUp) async =>
          Success<Payment>(qrPayment(status: PaymentStatus.received, confirmation: PaymentConfirmationKind.manual));
      await h.pump(tester, screen);
      await tapKey(tester, const ValueKey<String>('order-created-confirm-manual'));
      // Пустой референс — ошибка, запроса нет.
      await tapKey(tester, const ValueKey<String>('manual-submit'));
      expect(find.text('Введите референс из выписки банка (не короче 4 символов)'), findsOneWidget);
      Finder field(String key) =>
          find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(EditableText));
      await tester.enterText(field('manual-amount'), '16000');
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('manual-mismatch')), findsOneWidget);
      await tester.enterText(field('manual-amount'), '16007,50');
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('manual-mismatch')), findsNothing);
      await tester.enterText(field('manual-ref'), 'BK-778812');
      await tapKey(tester, const ValueKey<String>('manual-submit'));
      expect(h.stepUps, <String>['payment.qr.confirm_manual']);
      final ({String method, List<Object?> args}) call = h.fakes.payments.calls.firstWhere(
        (c) => c.method == 'confirmManual',
      );
      expect((call.args[1]! as ConfirmManualRequest).bankReference, 'BK-778812');
      expect((call.args[1]! as ConfirmManualRequest).receivedAmount, const Money(1600750));
      expect(call.args[3], 'step-up-token');
      expect(find.text('Оплата получена'), findsOneWidget);
      expect(find.text('Оплата подтверждена вручную'), findsOneWidget);
    });

    testWidgets('AC-UI-22-004: продавец не видит «Подтвердить оплату вручную» и «Другой способ оплаты»', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = harness(
        role: RoleCode.seller,
        order: qrOrder(qrPayment(autoConfirm: false)),
        qr: const CheckoutQrMode(),
        actions: const <PaymentAction>{PaymentAction.confirmManual},
      );
      await h.pump(tester, screen);
      expect(find.byKey(const ValueKey<String>('qr-panel-image')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('order-created-confirm-manual')), findsNothing);
      expect(find.byKey(const ValueKey<String>('order-created-other-method')), findsNothing);
      expect(find.text('Сменить способ оплаты может кассир'), findsOneWidget);
    });

    testWidgets('«Требует разбора»: manual_confirm с late_payment', (WidgetTester tester) async {
      final CheckoutHarness h = harness(
        order: qrOrder(qrPayment(status: PaymentStatus.manualConfirm, reviewReason: ReviewReason.latePayment)),
      );
      await h.pump(tester, screen);
      expect(find.text('Оплата поступила после истечения QR — требуется разбор кассиром'), findsOneWidget);
    });

    testWidgets('AC-UI-22-014: QR не получен из 1С — кассир: текст и «Другой способ оплаты»; клиент: «в кассе»', (
      WidgetTester tester,
    ) async {
      final Order order = qrOrder(
        qrPayment(status: PaymentStatus.qrPending, withQr: false),
        warnings: const <ApiWarning>[ApiWarning(rawCode: 'QR_UNAVAILABLE')],
      );
      final CheckoutHarness h = harness(order: order);
      await h.pump(tester, screen);
      expect(textContaining('QR не получен из 1С'), findsOneWidget);
      await tapKey(tester, const ValueKey<String>('order-created-other-method'));
      expect(h.nav.calls, contains('acceptPayment:order-1:-'));
    });

    testWidgets('AC-UI-22-012: клиент — QR не сформирован → «Оплатите заказ в кассе магазина», без кассовых кнопок', (
      WidgetTester tester,
    ) async {
      final Order order = qrOrder(
        qrPayment(status: PaymentStatus.qrPending, withQr: false),
        warnings: const <ApiWarning>[ApiWarning(rawCode: 'QR_UNAVAILABLE')],
      );
      final CheckoutHarness h = harness(role: RoleCode.customer, order: order);
      await h.pump(tester, screen);
      expect(find.text('Оплатите заказ в кассе магазина'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('order-created-confirm-manual')), findsNothing);
      expect(find.byKey(const ValueKey<String>('order-created-other-method')), findsNothing);
      expect(find.byKey(const ValueKey<String>('order-created-accept')), findsNothing);
      expect(find.byKey(const ValueKey<String>('order-created-documents')), findsNothing);
    });
  });

  group('SCR-22 статус и способы', () {
    testWidgets('AC-UI-22-002: 202 / submitting — «Ожидает отправки в 1С», счёт «Ожидает номер 1С»', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = harness(order: createdOrder());
      await h.pump(tester, screen);
      expect(find.byKey(const ValueKey<String>('order-created-onec-pending')), findsOneWidget);
      expect(find.text('Ожидает отправки в 1С'), findsWidgets);
      expect(find.text('Ожидает номер 1С'), findsOneWidget);
      expect(find.text('Заказ № POS-2026-000123'), findsOneWidget);
    });

    testWidgets('AC-UI-22-007: кассир при cash — «Принять оплату» → SCR-38 (method=cash), без автоперехода', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = harness(order: createdOrder(payments: <Payment>[qrPayment()]));
      await h.pump(tester, screen);
      expect(h.nav.calls, isEmpty);
      await tapKey(tester, const ValueKey<String>('order-created-accept'));
      expect(h.nav.calls, contains('acceptPayment:order-1:cash'));
    });

    testWidgets('AC-UI-22-007: продавец при cash — «Передайте клиента в кассу»', (WidgetTester tester) async {
      final CheckoutHarness h = harness(
        role: RoleCode.seller,
        order: createdOrder(payments: <Payment>[qrPayment()]),
      );
      await h.pump(tester, screen);
      expect(find.byKey(const ValueKey<String>('order-created-cash-handoff')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('order-created-accept')), findsNothing);
    });

    testWidgets('AC-UI-22-008: admin при QR — без QR и кнопок оплаты, «Оплату примет кассир»', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = harness(role: RoleCode.admin, order: qrOrder(qrPayment()));
      await h.pump(tester, screen);
      expect(find.byKey(const ValueKey<String>('qr-panel-image')), findsNothing);
      expect(find.text('Оплату примет кассир. Заказ № POS-2026-000123'), findsOneWidget);
    });

    testWidgets('AC-UI-22-012: клиент при cash — «Оплата при получении…»; «Новый заказ» → главный экран', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = harness(
        role: RoleCode.customer,
        order: createdOrder(payments: <Payment>[qrPayment()]),
      );
      await h.pump(tester, screen);
      expect(find.byKey(const ValueKey<String>('order-created-customer-cash')), findsOneWidget);
      await tapKey(tester, const ValueKey<String>('order-created-new'));
      expect(h.nav.calls, contains('home'));
    });

    testWidgets('печать счёта после номера 1С: «Печать» → PDF на принтер, статус «Напечатан»', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = harness(order: qrOrder(qrPayment()));
      h.fakes.orders.onDocument = (String id, OrderDocumentKind kind, PrintPaper f, bool copy) async =>
          const Success<OrderDocumentFile>(OrderDocumentFile(bytes: <int>[1, 2, 3], fileName: 'invoice.pdf'));
      await h.pump(tester, screen);
      await tapKey(tester, const ValueKey<String>('order-created-doc-print-invoice'));
      expect(h.printed, <String>['invoice.pdf']);
      expect(find.text('Напечатан'), findsOneWidget);
    });
  });

  group('F-flutter-ui-6/11', () {
    for (final (String name, String? restoredFrom, String expected) in <(String, String?, String)>[
      ('восстановленная корзина активна → SCR-20', 'order-1', 'backToCart'),
      ('текущая корзина не пуста — восстановленная отложена → SCR-23', null, 'parked'),
    ]) {
      testWidgets('UI-22-014: submit_failed — «1С отклонила заказ» + «Открыть восстановленную корзину»: $name', (
        WidgetTester tester,
      ) async {
        final CheckoutHarness h = harness(
          order: createdOrder(
            status: OrderStatus.submitFailed,
            payments: <Payment>[qrPayment()],
            submitError: const OrderSubmitError(code: 'ONEC_REJECTED', message: 'Нет остатка'),
          ),
        );
        h.fakes.cart.onFetch = () async => Success<Cart>(
          Cart(
            id: 'cart-r',
            status: CartStatus.active,
            rowVersion: 1,
            items: const <CartLine>[],
            restoredFromOrderId: restoredFrom,
          ),
        );
        await h.pump(tester, screen);
        expect(textContaining('1С отклонила заказ: Нет остатка'), findsOneWidget);
        await tapKey(tester, const ValueKey<String>('order-created-open-restored-cart'));
        expect(h.nav.calls, contains(expected));
      });
    }

    testWidgets('SCR-22.7 «Нет сети»: OfflineBanner, ожидание оплаты (long-polling) не запускается', (
      WidgetTester tester,
    ) async {
      final CheckoutHarness h = harness(order: qrOrder(qrPayment()))..online = false;
      await h.pump(tester, screen);
      expect(find.byType(OfflineBanner), findsOneWidget);
      expect(h.fakes.payments.calls.where((c) => c.method == 'watch'), isEmpty);
    });
  });

  testWidgets('F-trace-4 (RM-F-013 п. 4): SCR-22 после перезапуска (без ответа POST /orders в памяти) — только чтение: '
      'GET заказа и ожидание оплаты; «Проверить» — GET /payments/{id}; повторного POST нет', (
    WidgetTester tester,
  ) async {
    final CheckoutHarness h = harness(order: qrOrder(qrPayment()));
    await h.pump(tester, screen);
    expect(h.fakes.orders.calls.map((c) => c.method), <String>['get']);
    await tapKey(tester, const ValueKey<String>('order-created-check-payment'));
    final List<String> payments = <String>[for (final c in h.fakes.payments.calls) c.method];
    expect(payments, containsAll(<String>['watch', 'get']));
    expect(payments.where((String m) => m != 'watch' && m != 'get'), isEmpty, reason: 'приём денег не повторяется');
  });
}

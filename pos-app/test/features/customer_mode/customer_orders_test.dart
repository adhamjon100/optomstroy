// Режим клиента: свои заказы и статусы (RM-G-014 п. 2; 10 CUST-023, CUST-024, CUST-025; 02 SCR-24.10, SCR-25.10,
// AC-UI-24-014; 12 T-PAY-042): SCR-24 своего заказа без служебных действий (принять оплату, привязать к 1С, заявка
// на возврат, товарный чек и накладная, служебный баннер сопоставления 1С); платёж `manual_confirm` — клиентская
// подпись без причины разбора и без сотрудника; «Показать QR» — только при `QR_PROVIDER=onec`; SCR-22 — перевыпуск QR
// своего заказа на том же `payment_id` без ручного подтверждения; SCR-25 — без «Мои / Все» и фильтра по клиенту.
// Синтетические данные (фейки, не реальная интеграция), деньги — целые тыйыны.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/checkout/presentation/screens/order_created_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';
import 'package:optomstroy/features/orders/presentation/screens/orders_screen.dart';

import '../../support/f_fakes.dart';
import '../checkout/checkout_test_support.dart' as co;
import '../orders/support/orders_harness.dart' as oh;

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

/// Свой заказ клиента: QR-платёж на разборе (`manual_confirm`, оплата после истечения QR), сопоставление с 1С
/// неоднозначно, сервер прислал служебные действия (клиент всё равно не должен их видеть).
OrderDetails reviewOrder() => oh.details(
  oh.order(
    status: OrderStatus.awaitingPayment,
    method: PaymentMethod.qrBakai,
    syncState: OnecSyncState.ambiguous,
    payments: <Payment>[
      Payment(
        id: 'pay-r',
        orderId: 'o1',
        method: PaymentMethod.qrBakai,
        status: PaymentStatus.manualConfirm,
        amount: const Money(1600750),
        reviewReason: ReviewReason.latePayment,
        confirmedBy: const UserRef(id: 'u2', displayName: 'Айгуль'),
        confirmedAt: DateTime.utc(2026, 10, 22, 4, 15),
        transactionId: 'tx-1',
      ),
    ],
  ),
  <OrderAction>{OrderAction.pay, OrderAction.cancel, OrderAction.returnRequest, OrderAction.printInvoice},
);

/// Свой заказ с неоплаченным QR.
OrderDetails qrOrder() => oh.details(
  oh.order(
    status: OrderStatus.pendingApproval,
    method: PaymentMethod.qrBakai,
    payments: <Payment>[oh.payment(id: 'pay-q', method: PaymentMethod.qrBakai, status: PaymentStatus.qrShown)],
  ),
  <OrderAction>{OrderAction.cancel},
);

oh.OrdersHarness customer(OrderDetails d, {bool qrOnec = true}) => oh.OrdersHarness(
  role: RoleCode.customer,
  userId: 'cust-user',
  qrShowEnabled: qrOnec,
  orders: FakeOrdersRepository()..onGet = (String id, bool refresh) async => Success<OrderDetails>(d),
);

void main() {
  group('SCR-24 свой заказ', () {
    testWidgets('manual_confirm — клиентская подпись без причины разбора и сотрудника (CUST-024, T-PAY-042 (5))', (
      WidgetTester tester,
    ) async {
      final oh.OrdersHarness h = customer(reviewOrder());
      await h.pump(tester, const OrderDetailsScreen(orderId: 'o1'));
      expect(find.byKey(const ValueKey<String>('payment-status-customer-pay-r')), findsOneWidget);
      expect(find.text(OrdersTexts.customerPaymentStatus(l10n, PaymentStatus.manualConfirm)), findsOneWidget);
      expect(find.text(l10n.status_payment_manual_confirm), findsNothing, reason: '«Подтверждён вручную» — служебно');
      expect(find.text(l10n.payment_review_late_payment), findsNothing, reason: 'причина разбора — для кассира');
      expect(find.textContaining('Айгуль'), findsNothing, reason: 'сотрудник, подтвердивший платёж, не показывается');
      expect(find.byKey(const ValueKey<String>('payment-open-pay-r')), findsNothing, reason: 'журнал операций');
    });

    testWidgets('нет служебных действий: оплата, привязка 1С, возврат, товарный чек, накладная, баннер 1С', (
      WidgetTester tester,
    ) async {
      final oh.OrdersHarness h = customer(reviewOrder());
      await h.pump(tester, const OrderDetailsScreen(orderId: 'o1'));
      for (final String key in <String>['action-pay', 'action-onec-link', 'action-return', 'order-customer-card']) {
        expect(find.byKey(ValueKey<String>(key)), findsNothing, reason: key);
      }
      expect(find.byKey(const ValueKey<String>('banner-match-ambiguous')), findsNothing);
      expect(find.text(OrdersTexts.receipt(l10n)), findsNothing);
      expect(find.text(OrdersTexts.waybill(l10n)), findsNothing);
      expect(find.text(OrdersTexts.invoice(l10n)), findsOneWidget, reason: 'клиенту — только счёт (SCR-24.10)');
      // Отмена своей заявки до согласования без полученных платежей — доступна (ORD-050 (а)), без «Запросить отмену».
      expect(find.byKey(const ValueKey<String>('action-cancel')), findsOneWidget);
      expect(find.text(l10n.order_action_cancel_request), findsNothing);
    });

    testWidgets('сотрудник на том же заказе видит причину разбора и служебные действия (контроль)', (
      WidgetTester tester,
    ) async {
      final oh.OrdersHarness h = oh.OrdersHarness(
        orders: FakeOrdersRepository()..onGet = (String id, bool refresh) async => Success<OrderDetails>(reviewOrder()),
      );
      await h.pump(tester, const OrderDetailsScreen(orderId: 'o1'));
      expect(find.text(l10n.payment_review_late_payment), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('action-pay')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('action-return')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('banner-match-ambiguous')), findsOneWidget);
    });

    testWidgets('«Показать QR» своего заказа — только при QR_PROVIDER=onec (AC-UI-24-014)', (
      WidgetTester tester,
    ) async {
      final oh.OrdersHarness onec = customer(qrOrder());
      await onec.pump(tester, const OrderDetailsScreen(orderId: 'o1'));
      expect(find.byKey(const ValueKey<String>('action-show-qr')), findsOneWidget);

      final oh.OrdersHarness none = customer(qrOrder(), qrOnec: false);
      await none.pump(tester, const OrderDetailsScreen(orderId: 'o1'));
      expect(find.byKey(const ValueKey<String>('action-show-qr')), findsNothing);
    });
  });

  group('SCR-25 мои заказы', () {
    testWidgets('без «Мои / Все» и без фильтра по автору (свои — на сервере)', (WidgetTester tester) async {
      final List<OrdersQuery> queries = <OrdersQuery>[];
      final oh.OrdersHarness h = oh.OrdersHarness(
        role: RoleCode.customer,
        userId: 'cust-user',
        orders: FakeOrdersRepository()
          ..onList = (OrdersQuery q) async {
            queries.add(q);
            return Success<OrdersPage>(oh.ordersPage(<OrderSummary>[oh.summary(123, onecNumber: 'УТ-1')], total: 1));
          },
      );
      await h.pump(tester, const OrdersScreen(mine: '1'));
      expect(find.byKey(const ValueKey<String>('orders-scope-mine')), findsNothing);
      expect(find.byKey(const ValueKey<String>('orders-scope-all')), findsNothing);
      expect(queries, isNotEmpty);
      expect(queries.every((OrdersQuery q) => q.createdBy == null), isTrue, reason: '«свои» обеспечивает сервер');
    });
  });

  group('SCR-22 QR своего заказа', () {
    co.CheckoutHarness harness(Payment p, {QrProviderMode provider = QrProviderMode.onec}) {
      final co.CheckoutHarness h = co.CheckoutHarness(
        role: RoleCode.customer,
        qr: CheckoutQrMode(provider: provider, autoConfirm: provider == QrProviderMode.onec),
      );
      final Order order = co.createdOrder(
        method: PaymentMethod.qrBakai,
        status: OrderStatus.awaitingPayment,
        payments: <Payment>[p],
        onecNumber: 'УТ-0001234',
      );
      h.fakes.orders.onGet = (String id, bool refresh) async => Success<OrderDetails>(OrderDetails(order: order));
      h.fakes.payments.onGet = (String id, bool refresh) async =>
          Success<PaymentDetails>(PaymentDetails(payment: p, allowedActions: const <PaymentAction>{}));
      addTearDown(h.fakes.payments.dispose);
      return h;
    }

    testWidgets('истёк → «Перевыпустить QR» на том же payment_id; ручного подтверждения и смены способа нет', (
      WidgetTester tester,
    ) async {
      final co.CheckoutHarness h = harness(co.qrPayment(status: PaymentStatus.qrExpired));
      h.fakes.payments.onCreateForOrder = (String orderId, OrderPaymentRequest r, String key) async =>
          Success<OrderPaymentResult>(
            OrderPaymentResult(
              payment: co.qrPayment(expiresAt: co.testNow.add(const Duration(minutes: 15))),
              orderPaidAmount: Money.zero,
              orderIsPaid: false,
              created: false,
            ),
          );
      await h.pump(tester, const OrderCreatedScreen(orderId: 'order-1', paymentId: 'pay-1'));
      expect(find.byKey(const ValueKey<String>('order-created-confirm-manual')), findsNothing);
      expect(find.byKey(const ValueKey<String>('order-created-other-method')), findsNothing);
      expect(find.byKey(const ValueKey<String>('order-created-check-payment')), findsNothing);
      await co.tapKey(tester, const ValueKey<String>('order-created-reissue'));
      final ({String method, List<Object?> args}) call = h.fakes.payments.calls.firstWhere(
        (c) => c.method == 'createForOrder',
      );
      expect(call.args.first, 'order-1');
      expect((call.args[1]! as OrderPaymentRequest).reissueQr, isTrue);
      expect(find.byKey(const ValueKey<String>('order-created-qr-shown')), findsOneWidget);
      expect(h.fakes.payments.calls.where((c) => c.method == 'confirmManual' || c.method == 'void'), isEmpty);
    });

    testWidgets('QR_PROVIDER=none — QR клиенту не показывается и не перевыпускается (PAY-022)', (
      WidgetTester tester,
    ) async {
      final co.CheckoutHarness h = harness(
        co.qrPayment(status: PaymentStatus.qrExpired, autoConfirm: false),
        provider: QrProviderMode.none,
      );
      await h.pump(tester, const OrderCreatedScreen(orderId: 'order-1', paymentId: 'pay-1'));
      expect(find.byKey(const ValueKey<String>('qr-panel-image')), findsNothing);
      expect(find.byKey(const ValueKey<String>('order-created-reissue')), findsNothing);
    });
  });
}

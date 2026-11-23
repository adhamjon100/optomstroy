// T-UI-117: прогон адаптивности SCR-24 «Заказ», SCR-25 «Список заказов», SCR-30 «Дашборд кассира», SCR-38 «Приём
// оплаты» (наличные, QR), SCR-36 «Журнал операций», SCR-37 «Операция» по окнам 360…2560 (портрет и ландшафт, окна
// масштаба страницы веб-демо) при масштабе текста 1 и 1,3 — без переполнения и недоступных элементов (03 §8.8;
// указание владельца 2026-11-18, 15 §5.8 (3)). Данные — как у эталонов (синтетические, деньги — целые тыйыны).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/cashier/presentation/screens/cashier_dashboard_screen.dart';
import 'package:optomstroy/features/cashier/presentation/screens/payment_screen.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';
import 'package:optomstroy/features/orders/presentation/screens/orders_screen.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transaction_details_screen.dart';
import 'package:optomstroy/features/transactions/presentation/screens/transactions_screen.dart';

import '../features/cashier/support/cashier_harness.dart' as ch;
import '../features/orders/support/orders_harness.dart' as oh;
import '../support/f_fakes.dart';
import '../support/responsive_audit.dart';

oh.OrdersHarness _ordersList() => oh.OrdersHarness(
  orders: FakeOrdersRepository()
    ..onList = (OrdersQuery q) async => Success<OrdersPage>(
      oh.ordersPage(
        <OrderSummary>[
          oh.summary(123, onecNumber: 'УТ-0001234'),
          oh.summary(122, status: OrderStatus.awaitingPayment, totalSom: 8450, paidSom: 4000, onecNumber: 'УТ-0001233'),
          oh.summary(121, status: OrderStatus.submitting, totalSom: 2350),
          oh.summary(120, status: OrderStatus.shipped, totalSom: 41200, method: PaymentMethod.credit),
          oh.summary(119, status: OrderStatus.closed, totalSom: 9400, isPaid: true, paidSom: 9400),
          oh.summary(118, status: OrderStatus.cancelled, totalSom: 1650, onecNumber: 'УТ-0001228'),
        ],
        total: 31,
        counts: oh.kCounts,
      ),
    ),
);

oh.OrdersHarness _orderDetails() => oh.OrdersHarness(
  orders: FakeOrdersRepository()
    ..onGet = (String id, bool refresh) async => Success<OrderDetails>(
      oh.details(
        oh.order(
          status: OrderStatus.awaitingPayment,
          method: PaymentMethod.qrBakai,
          paidTyiyn: 800000,
          payments: <Payment>[
            oh.payment(tyiyn: 800000),
            oh.payment(id: 'pay-2', method: PaymentMethod.qrBakai, status: PaymentStatus.qrShown, tyiyn: 800750),
          ],
          totalsDiffer: true,
        ),
        <OrderAction>{OrderAction.pay, OrderAction.cancel, OrderAction.printInvoice},
      ),
    ),
);

ch.CashierHarness _dashboard() {
  final ch.CashierHarness h = ch.CashierHarness();
  h.cashier.onDashboard = () async => Success<PosDashboard>(ch.dashboard());
  return h;
}

ch.CashierHarness _payment({Order? order}) {
  final ch.CashierHarness h = ch.CashierHarness();
  final Order o = order ?? ch.payOrder();
  h.orders.onGet = (String id, bool refresh) async =>
      Success<OrderDetails>(OrderDetails(order: o, allowedActions: const <OrderAction>{OrderAction.pay}));
  return h;
}

ch.CashierHarness _transactions() {
  final ch.CashierHarness h = ch.CashierHarness();
  h.transactions.onList = (TransactionsQuery q) async => Success<TransactionsPage>(
    ch.txPage(<Transaction>[
      ch.tx('t1', at: DateTime.utc(2026, 10, 22, 4, 10)),
      ch.tx(
        't2',
        kind: TransactionKind.paymentVoided,
        sign: TransactionSign.minus,
        group: TransactionStatusGroup.voided,
        tyiyn: 235000,
        number: '1025',
        at: DateTime.utc(2026, 10, 22, 3),
      ),
      ch.tx(
        't3',
        kind: TransactionKind.manualQrConfirm,
        number: '1022',
        tyiyn: 845000,
        at: DateTime.utc(2026, 10, 22, 2),
      ),
      ch.tx(
        't4',
        kind: TransactionKind.orderCreated,
        group: TransactionStatusGroup.onecError,
        number: '1023',
        source: TransactionSource.onec,
        at: DateTime.utc(2026, 10, 21, 9),
      ),
    ], summary: const TransactionsSummary(count: 4, sumIn: Money(4046750), sumOut: Money(235000))),
  );
  return h;
}

ch.CashierHarness _transactionDetails() {
  final ch.CashierHarness h = ch.CashierHarness();
  h.transactions.onGet = (String id) async => Success<TransactionDetail>(
    ch.txDetail(
      ch.tx(
        id,
        related: const <TransactionRelated>[
          TransactionRelated(type: TransactionRelatedType.order, id: 'o1', number: 'POS-2026-000123'),
          TransactionRelated(type: TransactionRelatedType.payment, id: 'pay-1', number: 'PAY-77'),
        ],
      ),
    ),
  );
  h.payments.onGet = (String id, bool refresh) async => const Success<PaymentDetails>(
    PaymentDetails(
      payment: Payment(
        id: 'pay-1',
        orderId: 'o1',
        method: PaymentMethod.qrBakai,
        status: PaymentStatus.manualConfirm,
        amount: Money(1600750),
        bankAmount: Money(1600000),
        reviewReason: ReviewReason.amountMismatch,
      ),
      allowedActions: <PaymentAction>{PaymentAction.voidPayment, PaymentAction.confirmManual},
    ),
  );
  h.orders.onGet = (String id, bool refresh) async =>
      Success<OrderDetails>(OrderDetails(order: ch.payOrder(), allowedActions: const <OrderAction>{OrderAction.pay}));
  return h;
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, RespBuild> scenes = <String, RespBuild>{
    'scr25_orders': (Size s, double _) => _ordersList().app(const OrdersScreen(), size: s),
    'scr24_order': (Size s, double _) => _orderDetails().app(const OrderDetailsScreen(orderId: 'o1'), size: s),
    'scr30_cashier': (Size s, double _) => _dashboard().app(const CashierDashboardScreen(), size: s),
    'scr38_cash': (Size s, double _) => _payment().app(
      const PaymentScreen(orderId: 'o1', method: 'cash'),
      size: s,
    ),
    'scr38_qr': (Size s, double _) => _payment(
      order: ch.payOrder(method: PaymentMethod.qrBakai, payments: <Payment>[ch.qrPayment()]),
    ).app(const PaymentScreen(orderId: 'o1'), size: s),
    'scr36_transactions': (Size s, double _) => _transactions().app(const TransactionsScreen(), size: s),
    'scr37_transaction': (Size s, double _) =>
        _transactionDetails().app(const TransactionDetailsScreen(transactionId: 't1'), size: s),
  };

  for (final MapEntry<String, RespBuild> scene in scenes.entries) {
    testWidgets('T-UI-117 ${scene.key}: окна 360…2560 × текст 1 / 1,3', (WidgetTester tester) async {
      final RespAudit audit = RespAudit(scene.key);
      await audit.run(tester, scene.value);
      audit.expectNoBlocking();
    });
  }
}

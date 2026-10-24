// Адреса переходов SCR-24/25 совпадают с маршрутами основы (routes.dart); правила SCR-24 (документы, действия) —
// чистая логика (02 SCR-24.3, SCR-24.10; ядро §19.4, §22.5, §24.4).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/presentation/orders_locations.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/orders/presentation/state/order_view_rules.dart';
import 'package:optomstroy/features/orders/presentation/state/orders_filters.dart';

import '../support/orders_harness.dart';

void main() {
  test('адреса совпадают с типизированными маршрутами', () {
    expect(OrdersLocations.order('o-1'), const OrderRoute(orderId: 'o-1').location);
    expect(OrdersLocations.acceptPayment('o-1'), const PaymentNewRoute(orderId: 'o-1').location);
    expect(OrdersLocations.showQr('o-1', 'p-1'), const OrderCreatedRoute(orderId: 'o-1', paymentId: 'p-1').location);
    expect(OrdersLocations.returnRequest('o-1'), const ReturnNewRoute(orderId: 'o-1').location);
    expect(OrdersLocations.customer('c-1'), const CustomerRoute(customerId: 'c-1').location);
    expect(OrdersLocations.cart, const CartRoute().location);
    expect(OrdersLocations.product('p-1'), const ProductRoute(productId: 'p-1').location);
    expect(
      OrdersLocations.orders(<String, String>{'status': 'awaiting_payment', 'customerId': 'k1', 'mine': '1'}),
      const OrdersRoute(status: 'awaiting_payment', customerId: 'k1', mine: '1').location,
    );
  });

  test('фильтры ↔ query маршрута: статусы, период, клиент, «Мои»', () {
    final OrdersFilters f = OrdersFilters.defaults(
      kNow,
    ).copyWith(statuses: OrdersStatusGroup.cancelled.statuses, mine: true, customerId: () => 'k1');
    final Map<String, String> q = f.toRouteQuery();
    final OrdersFilters back = OrdersFilters.fromRoute(
      nowUtc: kNow,
      status: q['status'],
      from: q['from'],
      to: q['to'],
      customerId: q['customerId'],
      mine: q['mine'],
    );
    expect(back, f);
    expect(back.group, OrdersStatusGroup.cancelled);
    expect(OrdersFilters.fromRoute(nowUtc: kNow, status: 'closed,unknown').statuses, <OrderStatus>{OrderStatus.closed});
  });

  test('«Мои» → createdBy только при order.read.all', () {
    final OrdersFilters f = OrdersFilters.defaults(kNow).copyWith(mine: true);
    expect(f.toQuery(const OrdersViewer(role: RoleCode.cashier, userId: 'u1')).createdBy, 'u1');
    expect(f.toQuery(const OrdersViewer(role: RoleCode.seller, userId: 'u1')).createdBy, isNull);
    expect(f.toQuery(const OrdersViewer(role: RoleCode.customer, userId: 'u1')).createdBy, isNull);
    expect(f.toQuery(const OrdersViewer(role: RoleCode.owner, userId: 'u1')).withStatusCounts, isTrue);
    expect(
      f
          .toQuery(
            const OrdersViewer(role: RoleCode.owner, userId: 'u1'),
            cursor: 'c',
          )
          .withStatusCounts,
      isFalse,
    );
  });

  group('документы по моменту печати (ядро §19.4)', () {
    const OrdersViewer cashier = OrdersViewer(role: RoleCode.cashier);
    OrderDocView doc(List<OrderDocView> docs, String kind) => docs.firstWhere((OrderDocView d) => d.kind == kind);

    test('submitting: счёт ждёт номер 1С, чек — после оплаты, накладная — из 1С', () {
      final List<OrderDocView> docs = OrderViewRules.documents(
        details(order(status: OrderStatus.submitting, onecNumber: null), <OrderAction>{OrderAction.printInvoice}),
        cashier,
      );
      expect(doc(docs, 'invoice').available, isFalse);
      expect(doc(docs, 'invoice').reason, DocUnavailable.waitingNumber);
      expect(doc(docs, 'receipt').reason, DocUnavailable.afterPayment);
      expect(doc(docs, 'waybill').available, isFalse);
      expect(doc(docs, 'waybill').reason, DocUnavailable.fromOnec);
    });

    test('оплачен: счёт и товарный чек доступны', () {
      final List<OrderDocView> docs = OrderViewRules.documents(
        details(order(isPaid: true), <OrderAction>{OrderAction.printInvoice, OrderAction.printReceipt}),
        cashier,
      );
      expect(doc(docs, 'invoice').available, isTrue);
      expect(doc(docs, 'receipt').available, isTrue);
    });

    test('customer — только счёт', () {
      final List<OrderDocView> docs = OrderViewRules.documents(
        details(order(isPaid: true), <OrderAction>{OrderAction.printInvoice, OrderAction.printReceipt}),
        const OrdersViewer(role: RoleCode.customer),
      );
      expect(docs.map((OrderDocView d) => d.kind), <String>['invoice']);
    });
  });

  test('«Показать QR» — неоплаченный QR-платёж; «Принять оплату» не для credit (ядро §22.5)', () {
    final OrderDetails qr = details(
      order(
        method: PaymentMethod.qrBakai,
        payments: <Payment>[payment(method: PaymentMethod.qrBakai, status: PaymentStatus.qrExpired)],
      ),
      <OrderAction>{OrderAction.pay},
    );
    expect(
      OrderViewRules.actions(qr, const OrdersViewer(role: RoleCode.seller), repeatAvailable: false).showQrPaymentId,
      'pay-1',
    );
    expect(
      OrderViewRules.actions(qr, const OrdersViewer(role: RoleCode.admin), repeatAvailable: false).showQrPaymentId,
      isNull,
    );
    final OrderDetails credit = details(order(method: PaymentMethod.credit), <OrderAction>{OrderAction.pay});
    expect(
      OrderViewRules.actions(credit, const OrdersViewer(role: RoleCode.cashier), repeatAvailable: false).pay,
      isFalse,
    );
  });
}

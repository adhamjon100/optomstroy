// Поддержка тестов SCR-24/SCR-25 (агент F-fe-orders): синтетические заказы (деньги — целые тыйыны, D-19), фейки
// портов печати / повтора / step-up и обёртка приложения (тема B, локаль ru, размер окна, без анимаций).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';

import '../../../support/f_fakes.dart';

/// «Сейчас» тестов: 22.10.2026 10:30 по Бишкеку (04:30 UTC).
final DateTime kNow = DateTime.utc(2026, 10, 22, 4, 30);

/// Размеры окон D-18.
const Map<String, Size> kWindows = <String, Size>{
  'compact': Size(390, 844),
  'medium': Size(820, 1000),
  'expanded': Size(1366, 900),
};

const Customer kCustomer = Customer(
  id: 'cu-1',
  name: 'ОсОО «СтройМир»',
  displayName: 'ОсОО «СтройМир»',
  phoneMasked: '+996 555 ** ** 12',
);

/// Строка списка.
OrderSummary summary(
  int n, {
  OrderStatus status = OrderStatus.pendingApproval,
  int totalSom = 16007,
  int paidSom = 0,
  bool isPaid = false,
  PaymentMethod method = PaymentMethod.cash,
  String? onecNumber,
}) => OrderSummary(
  id: 'o$n',
  publicNumber: 'POS-2026-${n.toString().padLeft(6, '0')}',
  status: status,
  total: Money(totalSom * 100 + 50),
  paymentMethod: method,
  paidAmount: Money(paidSom * 100),
  isPaid: isPaid,
  customer: kCustomer,
  onec: onecNumber == null ? null : OrderOnecInfo(number: onecNumber, date: DateTime.utc(2026, 10, 21, 6)),
);

/// Страница списка.
OrdersPage ordersPage(
  List<OrderSummary> items, {
  String? next,
  int? total,
  Map<OrderStatus, int> counts = const <OrderStatus, int>{},
}) => OrdersPage(
  page: PageResult<OrderSummary>(items: items, nextCursor: next, hasMore: next != null, totalEstimate: total),
  statusCounts: counts,
);

/// Набор счётчиков для чипов.
const Map<OrderStatus, int> kCounts = <OrderStatus, int>{
  OrderStatus.submitting: 1,
  OrderStatus.pendingApproval: 5,
  OrderStatus.approved: 4,
  OrderStatus.awaitingShipment: 2,
  OrderStatus.awaitingPayment: 3,
  OrderStatus.shipped: 6,
  OrderStatus.closed: 9,
  OrderStatus.cancelled: 1,
};

List<OrderLine> _lines() => <OrderLine>[
  OrderLine(
    lineNo: 1,
    variantId: 'v1',
    productId: 'p1',
    productName: 'Смеситель для кухни Frap F4252',
    variantName: 'хром',
    sku: 'F4252-CR',
    quantity: const LineQuantity(value: Qty(2000), unitId: 'pcs'),
    unitPrice: Money.som(2350),
    lineTotal: Money.som(4700),
  ),
  OrderLine(
    lineNo: 2,
    variantId: 'v2',
    productId: 'p2',
    productName: 'Унитаз-компакт Santek Бриз',
    sku: 'SN-1WH302',
    quantity: const LineQuantity(value: Qty(1000), unitId: 'pcs'),
    unitPrice: Money.som(9400),
    discountAmount: const Money(84250),
    lineTotal: const Money(855750),
  ),
  OrderLine(
    lineNo: 3,
    variantId: 'v3',
    productId: 'p3',
    productName: 'Труба полипропиленовая PN20 20 мм',
    quantity: const LineQuantity(value: Qty(25000), unitId: 'm'),
    unitPrice: Money.som(110),
    lineTotal: Money.som(2750),
  ),
];

/// Заказ SCR-24.
Order order({
  String id = 'o1',
  OrderStatus status = OrderStatus.pendingApproval,
  PaymentMethod method = PaymentMethod.cash,
  String? onecNumber = 'УТ-0001234',
  bool isPaid = false,
  int paidTyiyn = 0,
  List<Payment> payments = const <Payment>[],
  OnecSyncState? syncState = OnecSyncState.linked,
  bool cancelRequested = false,
  bool totalsDiffer = false,
  OrderDocuments? documents,
}) => Order(
  id: id,
  publicNumber: 'POS-2026-000123',
  status: status,
  total: const Money(1600750),
  subtotal: const Money(1685000),
  discountPercent: const Percent(500),
  discountTotal: const Money(84250),
  totalToPay: const Money(1600750),
  paymentMethod: method,
  paidAmount: Money(paidTyiyn),
  isPaid: isPaid,
  customer: kCustomer,
  delivery: const Delivery.pickup(),
  receiver: const Receiver.customer(),
  onecSyncState: syncState,
  onecTotal: totalsDiffer ? const Money(1610000) : null,
  totalsDiffer: totalsDiffer,
  cancelRequested: cancelRequested,
  cancelRequestedAt: cancelRequested ? DateTime.utc(2026, 10, 22, 4) : null,
  onec: onecNumber == null
      ? null
      : OrderOnecInfo(
          number: onecNumber,
          date: DateTime.utc(2026, 10, 22, 3, 12),
          status: 'Не согласован',
          lastSyncAt: DateTime.utc(2026, 10, 22, 4, 25),
        ),
  documents: documents,
  items: _lines(),
  payments: payments,
  history: <OrderStatusEntry>[
    OrderStatusEntry(
      status: OrderStatus.submitting,
      at: DateTime.utc(2026, 10, 22, 3, 10),
      source: StatusChangeSource.posUser,
      by: const UserRef(id: 'u1', displayName: 'Абдулла'),
    ),
    if (status != OrderStatus.submitting)
      OrderStatusEntry(
        status: OrderStatus.pendingApproval,
        at: DateTime.utc(2026, 10, 22, 3, 12),
        source: StatusChangeSource.onecResponse,
      ),
    if (status == OrderStatus.awaitingShipment || status == OrderStatus.shipped || status == OrderStatus.closed)
      OrderStatusEntry(
        status: OrderStatus.approved,
        at: DateTime.utc(2026, 10, 22, 4),
        source: StatusChangeSource.onecSync,
      ),
    if (status == OrderStatus.awaitingShipment || status == OrderStatus.shipped || status == OrderStatus.closed)
      OrderStatusEntry(status: status, at: DateTime.utc(2026, 10, 22, 4, 20), source: StatusChangeSource.onecSync),
  ],
);

/// Платёж.
Payment payment({
  String id = 'pay-1',
  PaymentMethod method = PaymentMethod.cash,
  PaymentStatus status = PaymentStatus.received,
  int tyiyn = 800000,
  ReviewReason? review,
}) => Payment(
  id: id,
  orderId: 'o1',
  method: method,
  status: status,
  amount: Money(tyiyn),
  confirmedAt: status == PaymentStatus.received ? DateTime.utc(2026, 10, 22, 4, 15) : null,
  confirmedBy: status == PaymentStatus.received ? const UserRef(id: 'u2', displayName: 'Айгуль') : null,
  confirmationKind: status == PaymentStatus.received ? PaymentConfirmationKind.cash : null,
  reviewReason: review,
);

/// Ответ `GET /orders/{id}`.
OrderDetails details(Order o, [Set<OrderAction> actions = const <OrderAction>{}]) =>
    OrderDetails(order: o, allowedActions: actions);

/// Фейк печати: журнал вызовов.
final class FakeDocumentPrinter implements OrderDocumentPrinter {
  final List<String> calls = <String>[];

  @override
  Future<void> preview(BuildContext context, OrderDocumentFile file) async => calls.add('preview:${file.fileName}');

  @override
  Future<bool> print(OrderDocumentFile file) async {
    calls.add('print:${file.fileName}');
    return true;
  }
}

/// Фейк повтора заказа.
final class FakeRepeatPort implements OrderRepeatPort {
  FakeRepeatPort({this.cartCount = 0, this.unavailable = const <String>{}});

  int cartCount;
  final Set<String> unavailable;
  final List<String> calls = <String>[];

  @override
  Future<Result<int>> activeCartItemsCount() async => Success<int>(cartCount);

  @override
  Future<Result<bool>> addLine(OrderLine line, {required String idempotencyKey}) async {
    calls.add('add:${line.variantId}');
    return Success<bool>(!unavailable.contains(line.variantId));
  }

  @override
  Future<Result<void>> parkActiveCart({required String idempotencyKey}) async {
    calls.add('park');
    return const Success<void>(null);
  }
}

/// Тестовая обвязка экранов заказов.
final class OrdersHarness {
  OrdersHarness({
    FakeOrdersRepository? orders,
    FakeCustomersRepository? customers,
    this.role = RoleCode.cashier,
    this.userId = 'u1',
    this.online = OnlineStatus.online,
    this.qrShowEnabled = true,
    this.repeat,
    this.stepUpCancelled = false,
  }) : orders = orders ?? FakeOrdersRepository(),
       customers = customers ?? FakeCustomersRepository();

  final FakeOrdersRepository orders;
  final FakeCustomersRepository customers;
  final FakeDocumentPrinter printer = FakeDocumentPrinter();
  final RoleCode? role;
  final String? userId;
  final OnlineStatus online;
  final bool qrShowEnabled;
  final FakeRepeatPort? repeat;
  final bool stepUpCancelled;
  final List<String> stepUps = <String>[];

  /// Часы экрана (AC-UI-25-009: «Данные от HH:MM» через 5 мин).
  final FixedClock clock = FixedClock(kNow);

  /// Дополнительные подмены теста.
  final List<Override> extraOverrides = <Override>[];

  List<Override> get overrides => <Override>[
    ...extraOverrides,
    ordersRepositoryProvider.overrideWithValue(orders),
    customersRepositoryProvider.overrideWithValue(customers),
    ordersViewerProvider.overrideWithValue(OrdersViewer(role: role, userId: userId, qrShowEnabled: qrShowEnabled)),
    ordersOnlineStatusProvider.overrideWithValue(online),
    clockProvider.overrideWithValue(clock),
    orderDocumentPrinterProvider.overrideWithValue(printer),
    orderRepeatPortProvider.overrideWithValue(repeat),
    ordersStepUpProvider.overrideWithValue((String op) async {
      stepUps.add(op);
      return (cancelled: stepUpCancelled, token: stepUpCancelled ? null : 'step-up-token');
    }),
  ];

  /// Приложение с экраном [home] в окне [size].
  Widget app(Widget home, {Size size = const Size(1366, 900)}) => ProviderScope(
    // Новый контейнер на каждую обвязку: повторный `pump` в одном тесте не наследует состояние провайдеров.
    key: ObjectKey(this),
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true, size: size, padding: EdgeInsets.zero),
        child: child!,
      ),
      home: home,
    ),
  );

  /// Показать [home] в окне [size] и дождаться загрузки.
  Future<void> pump(WidgetTester tester, Widget home, {Size size = const Size(1366, 900)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(home, size: size));
    await tester.pump();
    await tester.pump();
  }
}

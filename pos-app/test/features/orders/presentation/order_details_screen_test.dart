// SCR-24 «Заказ: детали и статус» (агент F-fe-orders; 02 SCR-24.13 AC-UI-24-001…017; 13 RM-F-004 (клиентская часть),
// RM-F-006, RM-F-015): права действий по ролям, отмена / запрос отмены (одна операция, ключ идемпотентности),
// документы (доступность по статусу), ручная привязка к документу 1С (step-up), режим клиента, «Обновить» из 1С.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';
import 'package:optomstroy/features/orders/presentation/screens/order_details_screen.dart';

import '../../../support/f_fakes.dart';
import '../support/orders_harness.dart';

const ValueKey<String> _pay = ValueKey<String>('action-pay');
const ValueKey<String> _cancel = ValueKey<String>('action-cancel');
const ValueKey<String> _onecLink = ValueKey<String>('action-onec-link');
const ValueKey<String> _showQr = ValueKey<String>('action-show-qr');
const ValueKey<String> _return = ValueKey<String>('action-return');

FakeOrdersRepository _repo(OrderDetails d) =>
    FakeOrdersRepository()..onGet = (String id, bool refresh) async => Success<OrderDetails>(d);

Future<OrdersHarness> _open(
  WidgetTester t,
  OrderDetails d, {
  RoleCode role = RoleCode.cashier,
  Size size = const Size(1366, 900),
  bool qr = true,
  FakeRepeatPort? repeat,
  bool stepUpCancelled = false,
}) async {
  final OrdersHarness h = OrdersHarness(
    orders: _repo(d),
    role: role,
    qrShowEnabled: qr,
    repeat: repeat,
    stepUpCancelled: stepUpCancelled,
  );
  await h.pump(t, const OrderDetailsScreen(orderId: 'o1'), size: size);
  return h;
}

AppButton _button(WidgetTester t, ValueKey<String> key) => t.widget<AppButton>(find.byKey(key));

void main() {
  testWidgets('AC-UI-24-001: № POS, № 1С, статус с текстом и история с источником', (WidgetTester t) async {
    await _open(t, details(order(status: OrderStatus.awaitingShipment)));
    expect(find.text('Заказ № POS-2026-000123'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('order-onec-number')), findsOneWidget);
    expect(find.textContaining('УТ-0001234'), findsWidgets);
    expect(find.text('Ожидает отгрузки'), findsWidgets);
    expect(find.textContaining('· Приложение · Абдулла'), findsOneWidget);
    expect(find.textContaining('· 1С'), findsWidgets);
    expect(find.text('Смеситель для кухни Frap F4252 · хром'), findsOneWidget);
    expect(find.text('F4252-CR'), findsOneWidget);
  });

  testWidgets('AC-UI-24-002: частично оплачен — «Оплачено X из Y», статус не «Оплачен»', (WidgetTester t) async {
    await _open(
      t,
      details(order(status: OrderStatus.awaitingPayment, paidTyiyn: 800000, payments: <Payment>[payment()])),
    );
    final String paid = OrdersFormat.amount(const Money(800000));
    final String total = OrdersFormat.money(const Money(1600750));
    expect(find.text('Оплачено $paid из $total'), findsOneWidget);
    expect(find.text('Ожидает оплаты'), findsWidgets);
    expect(find.text('Оплачен'), findsNothing);
    expect(find.byKey(const ValueKey<String>('payment-pay-1')), findsOneWidget);
    expect(find.text('Получен'), findsOneWidget);
  });

  testWidgets('AC-UI-24-007: «Принять оплату» — cashier и senior_seller; нет у seller, admin, owner', (
    WidgetTester t,
  ) async {
    final OrderDetails d = details(order(), <OrderAction>{OrderAction.pay});
    for (final RoleCode r in <RoleCode>[RoleCode.cashier, RoleCode.seniorSeller]) {
      await _open(t, d, role: r);
      expect(find.byKey(_pay), findsOneWidget, reason: r.value);
    }
    for (final RoleCode r in <RoleCode>[RoleCode.seller, RoleCode.admin, RoleCode.owner, RoleCode.customer]) {
      await _open(t, d, role: r);
      expect(find.byKey(_pay), findsNothing, reason: r.value);
    }
  });

  testWidgets(
    'AC-UI-24-004, AC-UI-24-013: автор отменяет свой заказ без step-up; без причины кнопка неактивна; один запрос',
    (WidgetTester t) async {
      final OrderDetails d = details(order(), <OrderAction>{OrderAction.cancel});
      final OrdersHarness h = await _open(t, d, role: RoleCode.seller);
      int cancels = 0;
      h.orders.onCancel = (String id, OrderCancelRequest req, String key, String? stepUp) async {
        cancels++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return Success<Order>(order(status: OrderStatus.cancelled));
      };
      expect(_button(t, _cancel).label, 'Отменить заказ');
      expect(_button(t, _cancel).variant, AppButtonVariant.danger);
      await t.tap(find.byKey(_cancel));
      await t.pumpAndSettle();
      expect(find.text('Отменить заказ № POS-2026-000123?'), findsOneWidget);
      expect(_button(t, const ValueKey<String>('cancel-confirm')).onPressed, isNull);
      await t.tap(find.byKey(const ValueKey<String>('cancel-reason-customer_refused')));
      await t.pump();
      expect(
        _button(t, const ValueKey<String>('cancel-confirm')).onPressed,
        isNull,
        reason: 'текст причины обязателен',
      );
      await t.enterText(
        find.descendant(
          of: find.byKey(const ValueKey<String>('cancel-reason-text')),
          matching: find.byType(EditableText),
        ),
        'Клиент передумал',
      );
      await t.pump();
      expect(
        find.byKey(const ValueKey<String>('cancel-refund')),
        findsNothing,
        reason: 'платежей нет — refundIntent не нужен',
      );
      await t.tap(find.byKey(const ValueKey<String>('cancel-confirm')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey<String>('cancel-confirm')), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(cancels, 1);
      final FakeCall call = h.orders.calls.firstWhere((FakeCall c) => c.method == 'cancel');
      final OrderCancelRequest req = call.args[1]! as OrderCancelRequest;
      expect(req.reason, 'Клиент передумал');
      expect(req.reasonCode, CancelReasonCode.customerRefused);
      expect(req.refundIntent, isNull);
      expect(call.args[2], isA<String>().having((String k) => k.length, 'uuid', 36));
      expect(call.args[3], isNull, reason: 'без step-up');
      expect(find.text('Заказ отменён'), findsOneWidget);
    },
  );

  testWidgets('AC-UI-24-005: awaiting_shipment у кассира — «Запросить отмену», метка «запрос отправлен»', (
    WidgetTester t,
  ) async {
    final OrderDetails d = details(
      order(
        status: OrderStatus.awaitingShipment,
        paidTyiyn: 1600750,
        isPaid: true,
        payments: <Payment>[payment(tyiyn: 1600750)],
      ),
      <OrderAction>{OrderAction.cancel},
    );
    final OrdersHarness h = await _open(t, d);
    h.orders.onCancel = (String id, OrderCancelRequest req, String key, String? stepUp) async =>
        Success<Order>(order(status: OrderStatus.awaitingShipment, cancelRequested: true));
    h.orders.onGet = (String id, bool refresh) async => Success<OrderDetails>(
      details(order(status: OrderStatus.awaitingShipment, cancelRequested: true, isPaid: true, paidTyiyn: 1600750)),
    );
    expect(_button(t, _cancel).label, 'Запросить отмену');
    await t.tap(find.byKey(_cancel));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey<String>('cancel-reason-duplicate')));
    await t.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('cancel-reason-text')),
        matching: find.byType(EditableText),
      ),
      'Дубль заказа',
    );
    await t.pump();
    expect(_button(t, const ValueKey<String>('cancel-confirm')).onPressed, isNull, reason: 'нужен refundIntent');
    await t.tap(find.byKey(const ValueKey<String>('cancel-advance')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey<String>('cancel-confirm')));
    await t.pumpAndSettle();
    final OrderCancelRequest req =
        h.orders.calls.firstWhere((FakeCall c) => c.method == 'cancel').args[1]! as OrderCancelRequest;
    expect(req.refundIntent, RefundIntent.advance);
    expect(find.text('Запрос отмены отправлен в 1С'), findsWidgets);
    expect(find.byKey(const ValueKey<String>('order-cancel-requested')), findsOneWidget);
  });

  testWidgets('AC-UI-24-006: shipped / closed — кнопки отмены нет; 409 — «Отмена недоступна в статусе …»', (
    WidgetTester t,
  ) async {
    await _open(t, details(order(status: OrderStatus.shipped)));
    expect(find.byKey(_cancel), findsNothing);
    await _open(t, details(order(status: OrderStatus.closed), <OrderAction>{OrderAction.cancel}));
    expect(find.byKey(_cancel), findsNothing, reason: 'закрыт — действия скрыты, кроме печати и повтора');

    final OrdersHarness h = await _open(t, details(order(), <OrderAction>{OrderAction.cancel}));
    h.orders.onCancel = (String id, OrderCancelRequest req, String key, String? stepUp) async =>
        const FailureResult<Order>(ConflictFailure(ConflictKind.orderStateInvalid, currentStatus: 'shipped'));
    await t.tap(find.byKey(_cancel));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey<String>('cancel-reason-other')));
    await t.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('cancel-reason-text')),
        matching: find.byType(EditableText),
      ),
      'Причина',
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey<String>('cancel-confirm')));
    await t.pumpAndSettle();
    expect(find.text('Отмена недоступна в статусе «Отгружен»'), findsOneWidget);
  });

  testWidgets('AC-UI-24-012: «Заявка на возврат» — только при return_request в allowedActions', (WidgetTester t) async {
    await _open(t, details(order(status: OrderStatus.shipped)));
    expect(find.byKey(_return), findsNothing);
    await _open(
      t,
      details(order(status: OrderStatus.shipped), <OrderAction>{OrderAction.returnRequest}),
      role: RoleCode.seller,
    );
    expect(find.byKey(_return), findsOneWidget);
    await _open(t, details(order(status: OrderStatus.pendingApproval)));
    expect(find.byKey(_return), findsNothing);
  });

  testWidgets('AC-UI-24-008: документы в submitting — счёт «Ожидает номер 1С», чек «После оплаты», накладная из 1С', (
    WidgetTester t,
  ) async {
    await _open(t, details(order(status: OrderStatus.submitting, onecNumber: null, syncState: OnecSyncState.pending)));
    expect(find.byKey(const ValueKey<String>('doc-invoice-reason')), findsOneWidget);
    expect(find.text('Ожидает номер 1С'), findsWidgets);
    expect(find.byKey(const ValueKey<String>('doc-invoice-print')), findsNothing);
    expect(find.text('После оплаты'), findsWidgets);
    expect(find.text('Печатается из 1С при отгрузке'), findsWidgets);
    expect(find.byKey(const ValueKey<String>('banner-submitting')), findsOneWidget);
  });

  testWidgets('RM-F-004: счёт после номера 1С (A4), товарный чек только после оплаты (80 мм) — печать', (
    WidgetTester t,
  ) async {
    final OrderDetails unpaid = details(order(), <OrderAction>{OrderAction.printInvoice});
    final OrdersHarness h = await _open(t, unpaid);
    h.orders.onDocument = (String id, OrderDocumentKind kind, PrintPaper paper, bool copy) async =>
        Success<OrderDocumentFile>(
          OrderDocumentFile(bytes: const <int>[37, 80, 68, 70], fileName: '${kind.value}-POS.pdf'),
        );
    expect(find.byKey(const ValueKey<String>('doc-invoice-print')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('doc-receipt-print')), findsNothing);
    await t.tap(find.byKey(const ValueKey<String>('doc-invoice-print')));
    await t.pumpAndSettle();
    final FakeCall doc = h.orders.calls.lastWhere((FakeCall c) => c.method == 'document');
    expect(doc.args[1], OrderDocumentKind.invoice);
    expect(doc.args[2], PrintPaper.a4);
    expect(h.printer.calls, <String>['print:invoice-POS.pdf']);

    final OrdersHarness h2 = await _open(
      t,
      details(order(isPaid: true, paidTyiyn: 1600750, payments: <Payment>[payment(tyiyn: 1600750)]), <OrderAction>{
        OrderAction.printInvoice,
        OrderAction.printReceipt,
      }),
    );
    h2.orders.onDocument = h.orders.onDocument;
    await t.tap(find.byKey(const ValueKey<String>('doc-receipt-preview')));
    await t.pumpAndSettle();
    final FakeCall receipt = h2.orders.calls.lastWhere((FakeCall c) => c.method == 'document');
    expect(receipt.args[1], OrderDocumentKind.receipt);
    expect(receipt.args[2], PrintPaper.thermal80);
    expect(h2.printer.calls, <String>['preview:receipt-POS.pdf']);
    expect(
      find.byKey(const ValueKey<String>('doc-receipt-download')),
      findsNothing,
      reason: 'без системного диалога сохранения',
    );
  });

  testWidgets(
    'AC-UI-24-015: ORDER_MATCH_AMBIGUOUS — баннер; кнопка у senior_seller/admin/owner, нет у seller/cashier',
    (WidgetTester t) async {
      final OrderDetails amb = details(
        order(status: OrderStatus.submitting, onecNumber: null, syncState: OnecSyncState.ambiguous),
      );
      for (final RoleCode r in <RoleCode>[RoleCode.seniorSeller, RoleCode.admin, RoleCode.owner]) {
        await _open(t, amb, role: r);
        expect(find.byKey(const ValueKey<String>('banner-match-ambiguous')), findsOneWidget, reason: r.value);
        expect(find.byKey(_onecLink), findsOneWidget, reason: r.value);
      }
      for (final RoleCode r in <RoleCode>[RoleCode.seller, RoleCode.cashier]) {
        await _open(t, amb, role: r);
        expect(find.byKey(const ValueKey<String>('banner-match-ambiguous')), findsOneWidget);
        expect(find.byKey(_onecLink), findsNothing, reason: r.value);
      }
      await _open(t, details(order()), role: RoleCode.seniorSeller);
      expect(find.byKey(_onecLink), findsNothing, reason: 'без проблемы сопоставления — скрыта');
    },
  );

  testWidgets('AC-UI-24-016: «Привязать» без причины неактивна; step-up; один POST с ключом и токеном; баннер скрыт', (
    WidgetTester t,
  ) async {
    final OrderDetails amb = details(
      order(status: OrderStatus.submitting, onecNumber: null, syncState: OnecSyncState.ambiguous),
    );
    final OrdersHarness h = await _open(t, amb, role: RoleCode.seniorSeller);
    final Order linked = order(status: OrderStatus.awaitingPayment, onecNumber: 'УТ-0009999');
    h.orders.onLinkOnec = (String id, OrderOnecLinkRequest req, String key, String? stepUp) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return Success<Order>(linked);
    };
    h.orders.onGet = (String id, bool refresh) async => Success<OrderDetails>(details(linked));
    await t.tap(find.byKey(_onecLink));
    await t.pumpAndSettle();
    expect(find.text('Привязка к документу 1С'), findsOneWidget);
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey<String>('onec-link-number')), matching: find.byType(EditableText)),
      'УТ-0009999',
    );
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey<String>('onec-link-reason')), matching: find.byType(EditableText)),
      'abc',
    );
    await t.pump();
    expect(_button(t, const ValueKey<String>('onec-link-confirm')).onPressed, isNull, reason: 'причина < 5 символов');
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey<String>('onec-link-reason')), matching: find.byType(EditableText)),
      'Оформлен вручную в 1С',
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey<String>('onec-link-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey<String>('onec-link-confirm')), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(h.stepUps, <String>['order.onec_link']);
    final List<FakeCall> links = h.orders.calls.where((FakeCall c) => c.method == 'linkOnec').toList();
    expect(links, hasLength(1));
    final OrderOnecLinkRequest req = links.single.args[1]! as OrderOnecLinkRequest;
    expect(req.onecNumber, 'УТ-0009999');
    expect(req.reason, 'Оформлен вручную в 1С');
    expect(links.single.args[2], isA<String>().having((String k) => k.length, 'uuid', 36));
    expect(links.single.args[3], 'step-up-token');
    expect(find.byKey(const ValueKey<String>('banner-match-ambiguous')), findsNothing);
    expect(find.text('Заказ привязан к документу 1С № УТ-0009999'), findsOneWidget);
    expect(find.text('Ожидает оплаты'), findsWidgets, reason: 'статус по 10 §2.2 без ожидания confirmed');
  });

  testWidgets('onec-link: отмена step-up — запрос не отправляется, диалог остаётся', (WidgetTester t) async {
    final OrderDetails amb = details(
      order(status: OrderStatus.submitting, onecNumber: null, syncState: OnecSyncState.ambiguous),
    );
    final OrdersHarness h = await _open(t, amb, role: RoleCode.admin, stepUpCancelled: true);
    await t.tap(find.byKey(_onecLink));
    await t.pumpAndSettle();
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey<String>('onec-link-number')), matching: find.byType(EditableText)),
      'УТ-1',
    );
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey<String>('onec-link-reason')), matching: find.byType(EditableText)),
      'Причина привязки',
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey<String>('onec-link-confirm')));
    await t.pumpAndSettle();
    expect(h.orders.calls.where((FakeCall c) => c.method == 'linkOnec'), isEmpty);
    expect(find.byKey(const ValueKey<String>('order-dialog-error')), findsOneWidget);
  });

  testWidgets('режим клиента (RM-F-015, AC-UI-24-014): свой заказ — без служебных действий, только счёт; QR при onec', (
    WidgetTester t,
  ) async {
    final OrderDetails d = details(
      order(
        method: PaymentMethod.qrBakai,
        payments: <Payment>[payment(method: PaymentMethod.qrBakai, status: PaymentStatus.qrShown, tyiyn: 1600750)],
        syncState: OnecSyncState.ambiguous,
      ),
      <OrderAction>{OrderAction.cancel, OrderAction.printInvoice, OrderAction.pay},
    );
    await _open(t, d, role: RoleCode.customer, size: kWindows['compact']!);
    expect(find.byKey(_pay), findsNothing);
    expect(find.byKey(_onecLink), findsNothing);
    expect(find.byKey(_showQr), findsOneWidget);
    expect(_button(t, _cancel).label, 'Отменить заказ');
    expect(find.byKey(const ValueKey<String>('doc-invoice')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('doc-receipt')), findsNothing);
    expect(find.byKey(const ValueKey<String>('doc-waybill')), findsNothing);
    expect(find.byKey(const ValueKey<String>('order-customer-card')), findsNothing);
    expect(find.byKey(const ValueKey<String>('order-refresh-onec')), findsNothing, reason: '«Обновить» из 1С — staff');

    await _open(t, d, role: RoleCode.customer, size: kWindows['compact']!, qr: false);
    expect(find.byKey(_showQr), findsNothing, reason: 'QR_PROVIDER=none');
  });

  testWidgets('AC-UI-24-010: чужой заказ (404) — «Заказ не найден или недоступен»', (WidgetTester t) async {
    final OrdersHarness h = OrdersHarness(
      orders: FakeOrdersRepository()
        ..onGet = (String id, bool r) async =>
            const FailureResult<OrderDetails>(ServerFailure(code: 'NOT_FOUND', status: 404)),
      role: RoleCode.seller,
    );
    await h.pump(t, const OrderDetailsScreen(orderId: 'foreign'));
    expect(find.text('Заказ не найден или недоступен'), findsOneWidget);
  });

  testWidgets('AC-UI-24-011: «Обновить» из 1С при недоступной 1С — снекбар с временем данных', (WidgetTester t) async {
    final OrdersHarness h = await _open(t, details(order()));
    h.orders.onGet = (String id, bool refresh) async =>
        refresh ? const FailureResult<OrderDetails>(OnecUnavailableFailure()) : Success<OrderDetails>(details(order()));
    await t.tap(find.byKey(const ValueKey<String>('order-refresh-onec')));
    await t.pump();
    await t.pump();
    expect(h.orders.calls.where((FakeCall c) => c.method == 'get' && c.args[1] == true), hasLength(1));
    expect(find.text('1С недоступна, показаны данные от 10:25'), findsOneWidget);
  });

  testWidgets('AC-UI-24-009: «Повторить заказ» при непустой корзине — диалог; снятые с продажи пропущены', (
    WidgetTester t,
  ) async {
    final FakeRepeatPort port = FakeRepeatPort(cartCount: 2, unavailable: <String>{'v2'});
    await _open(
      t,
      details(order(status: OrderStatus.closed)),
      role: RoleCode.seller,
      repeat: port,
    );
    await t.tap(find.byKey(const ValueKey<String>('action-repeat')));
    await t.pumpAndSettle();
    expect(
      find.text('В корзине 2 позиций. Добавить позиции заказа к текущей корзине или отложить текущую?'),
      findsOneWidget,
    );
    await t.tap(find.byKey(const ValueKey<String>('repeat-park')));
    await t.pumpAndSettle();
    expect(port.calls, <String>['park', 'add:v1', 'add:v2', 'add:v3']);
    expect(find.text('Не добавлено: 1 (снято с продажи)'), findsOneWidget);
  });

  testWidgets('офлайн: OfflineBanner, действия disabled (D-32)', (WidgetTester t) async {
    final OrdersHarness h = OrdersHarness(
      orders: _repo(details(order(), <OrderAction>{OrderAction.pay, OrderAction.cancel, OrderAction.printInvoice})),
      online: OnlineStatus.offline,
    );
    await h.pump(t, const OrderDetailsScreen(orderId: 'o1'));
    expect(_button(t, _pay).onPressed, isNull);
    expect(_button(t, _cancel).onPressed, isNull);
    expect(_button(t, const ValueKey<String>('doc-invoice-print')).onPressed, isNull);
  });

  testWidgets('compact: история свёрнута до 3 событий, «Показать всю историю»', (WidgetTester t) async {
    final Order base = order(status: OrderStatus.closed);
    final Order o = Order(
      id: base.id,
      publicNumber: base.publicNumber,
      status: base.status,
      total: base.total,
      paymentMethod: base.paymentMethod,
      items: base.items,
      history: <OrderStatusEntry>[
        for (final (int i, OrderStatus s) in <OrderStatus>[
          OrderStatus.submitting,
          OrderStatus.pendingApproval,
          OrderStatus.approved,
          OrderStatus.awaitingShipment,
          OrderStatus.shipped,
        ].indexed)
          OrderStatusEntry(status: s, at: DateTime.utc(2026, 10, 22, 3, i), source: StatusChangeSource.onecSync),
      ],
    );
    await _open(t, details(o), size: kWindows['compact']!);
    expect(
      find.byKey(ValueKey<String>('history-submitting-${DateTime.utc(2026, 10, 22, 3).toIso8601String()}')),
      findsNothing,
    );
    await t.scrollUntilVisible(
      find.byKey(const ValueKey<String>('history-toggle')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.byKey(const ValueKey<String>('history-toggle')));
    await t.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('history-submitting-${DateTime.utc(2026, 10, 22, 3).toIso8601String()}')),
      findsOneWidget,
    );
    expect(find.text('Свернуть историю'), findsOneWidget);
  });

  testWidgets(
    'F-flutter-ui-6: UI-24-015 submit_failed — «Открыть восстановленную корзину» (SCR-20 / SCR-23, ORD-027)',
    (WidgetTester t) async {
      final List<String> asked = <String>[];
      final OrdersHarness h = OrdersHarness(orders: _repo(details(order(status: OrderStatus.submitFailed))));
      h.extraOverrides.add(
        orderRestoredCartLocatorProvider.overrideWithValue((String orderId) async {
          asked.add(orderId);
          return '/cart/parked';
        }),
      );
      await h.pump(t, const OrderDetailsScreen(orderId: 'o1'));
      expect(find.byKey(const ValueKey<String>('banner-rejected')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey<String>('order-open-restored-cart')));
      await t.pump();
      expect(asked, <String>['o1']);
    },
  );

  testWidgets('F-flutter-ui-6: без корзины у роли (owner) кнопки «Открыть восстановленную корзину» нет', (
    WidgetTester t,
  ) async {
    await _open(t, details(order(status: OrderStatus.submitFailed)), role: RoleCode.owner);
    expect(find.byKey(const ValueKey<String>('banner-rejected')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('order-open-restored-cart')), findsNothing);
  });
}

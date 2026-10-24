// Что показывать на SCR-24 (02 SCR-24.3, SCR-24.10; 10 ORD-050…053; ядро §19.2, §19.4, §22.5, §22.9, §24.4):
// кнопки строятся по `allowedActions` ответа сервера и роли зрителя (сервер всё равно проверяет), документы —
// по моменту печати (счёт — после номера 1С, товарный чек — после оплаты, накладная — из 1С). Чистая логика.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';

/// Почему документ недоступен.
enum DocUnavailable {
  /// Счёт: «Ожидает номер 1С».
  waitingNumber,

  /// Товарный чек: «После оплаты».
  afterPayment,

  /// Накладная: «Печатается из 1С при отгрузке».
  fromOnec,

  /// Нет права/действия по статусу (без подписи-причины — строка показывается как недоступная).
  notAllowed,
}

/// Строка документа SCR-24 (UI-24-009).
final class OrderDocView {
  const OrderDocView({required this.kind, required this.available, this.reason});

  /// `invoice`, `receipt`, `waybill`.
  final String kind;
  final bool available;
  final DocUnavailable? reason;
}

/// Видимость действий SCR-24 (зона I).
final class OrderActionsView {
  const OrderActionsView({
    this.pay = false,
    this.showQrPaymentId,
    this.onecLink = false,
    this.repeat = false,
    this.returnRequest = false,
    this.cancel = false,
    this.cancelIsRequest = false,
    this.cancelPending = false,
  });

  /// «Принять оплату» → SCR-38.
  final bool pay;

  /// «Показать QR» → SCR-22 (`paymentId`); `null` — кнопки нет.
  final String? showQrPaymentId;

  /// «Привязать к документу 1С».
  final bool onecLink;

  /// «Повторить заказ».
  final bool repeat;

  /// «Заявка на возврат» → SCR-39.
  final bool returnRequest;

  /// «Отменить заказ» / «Запросить отмену».
  final bool cancel;

  /// Подпись «Запросить отмену» (согласованный, отгружаемый или с полученными платежами — ORD-051).
  final bool cancelIsRequest;

  /// Запрос отмены уже отправлен (`cancelRequested`) — кнопка disabled.
  final bool cancelPending;

  bool get any => pay || showQrPaymentId != null || onecLink || repeat || returnRequest || cancel;
}

/// Правила SCR-24.
abstract final class OrderViewRules {
  static const Set<OrderStatus> _beforeOnecNumber = <OrderStatus>{OrderStatus.submitting, OrderStatus.submitFailed};

  static const Set<OrderStatus> _final = <OrderStatus>{OrderStatus.cancelled, OrderStatus.closed};

  static const Set<PaymentStatus> _qrUnpaid = <PaymentStatus>{
    PaymentStatus.initiated,
    PaymentStatus.qrPending,
    PaymentStatus.qrShown,
    PaymentStatus.qrExpired,
  };

  /// Есть полученные деньги по заказу (для «Запросить отмену» и выбора `refundIntent`).
  static bool hasReceivedMoney(Order o) =>
      (o.paidAmount != null && !o.paidAmount!.isZero) ||
      o.payments.any((Payment p) => p.status == PaymentStatus.received);

  /// Неоплаченный QR-платёж заказа (для «Показать QR»).
  static Payment? unpaidQr(Order o) {
    for (final Payment p in o.payments.reversed) {
      if (p.method == PaymentMethod.qrBakai && _qrUnpaid.contains(p.status)) return p;
    }
    return null;
  }

  /// Действия по заказу, правам зрителя и сети.
  static OrderActionsView actions(OrderDetails d, OrdersViewer viewer, {required bool repeatAvailable}) {
    final Order o = d.order;
    final Set<OrderAction> a = d.allowedActions;
    final bool repeat = repeatAvailable && viewer.canRepeat && o.items.isNotEmpty;
    // Отменён / закрыт: действия скрыты, кроме печати и «Повторить заказ» (SCR-24.7).
    if (_final.contains(o.status)) return OrderActionsView(repeat: repeat);
    final Payment? qr = o.isPaid || !viewer.canShowQr ? null : unpaidQr(o);
    final bool cancel = a.contains(OrderAction.cancel);
    final bool request =
        o.status == OrderStatus.approved || o.status == OrderStatus.awaitingShipment || hasReceivedMoney(o);
    return OrderActionsView(
      pay:
          a.contains(OrderAction.pay) &&
          viewer.canAcceptPayment &&
          !o.isPaid &&
          o.paymentMethod != PaymentMethod.credit,
      showQrPaymentId: qr?.id,
      onecLink: viewer.canOnecLink && o.onecSyncState == OnecSyncState.ambiguous,
      repeat: repeat,
      // Заявка на возврат — только сотрудникам (`return.create`); клиенту — через магазин (02 SCR-24.10, CUST-023).
      returnRequest: a.contains(OrderAction.returnRequest) && !viewer.isCustomer,
      cancel: cancel,
      cancelIsRequest: cancel && request && !viewer.isCustomer,
      cancelPending: o.cancelRequested,
    );
  }

  /// Документы заказа; `customer` видит только счёт (02 SCR-24.10).
  static List<OrderDocView> documents(OrderDetails d, OrdersViewer viewer) {
    if (!viewer.canPrint) return const <OrderDocView>[];
    final Order o = d.order;
    final bool hasNumber = o.onec?.number != null && !_beforeOnecNumber.contains(o.status);
    final bool invoiceOk = d.allowedActions.contains(OrderAction.printInvoice) || o.documents?.invoicePath != null;
    final bool receiptOk = d.allowedActions.contains(OrderAction.printReceipt) || o.documents?.receiptPath != null;
    final DocumentAvailability? waybill = o.documents?.waybill;
    return <OrderDocView>[
      OrderDocView(
        kind: 'invoice',
        available: invoiceOk && hasNumber,
        reason: invoiceOk && hasNumber ? null : (hasNumber ? DocUnavailable.notAllowed : DocUnavailable.waitingNumber),
      ),
      if (!viewer.isCustomer)
        OrderDocView(
          kind: 'receipt',
          available: receiptOk && o.isPaid,
          reason: receiptOk && o.isPaid ? null : (o.isPaid ? DocUnavailable.notAllowed : DocUnavailable.afterPayment),
        ),
      if (!viewer.isCustomer)
        OrderDocView(
          kind: 'waybill',
          available: false,
          reason: waybill?.available ?? false ? DocUnavailable.notAllowed : DocUnavailable.fromOnec,
        ),
    ];
  }

  /// Печать из строки SCR-25 (UI-25-009): недоступна для `submitting`/`submit_failed`; товарный чек — после оплаты.
  static bool rowPrintEnabled(OrderSummary s) => !_beforeOnecNumber.contains(s.status);
}

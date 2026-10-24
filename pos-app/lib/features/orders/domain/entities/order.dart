// Заказ (08 §3.9 `Order`, `OrderItem`, `OrderSummary`; статусы — проекция 1С, D-20). Суммы — расчёт сервера (D-23),
// клиент их только показывает. Список заказов и заказ держатся только в памяти (Riverpod), на диск не пишутся
// (07 §11.2: таблиц `orders`/`payments` в drift нет). Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// Строка заказа (`OrderItem`, снимок на момент создания).
final class OrderLine {
  const OrderLine({
    required this.lineNo,
    required this.variantId,
    required this.quantity,
    this.productId,
    this.productName,
    this.variantName,
    this.sku,
    this.baseQuantity,
    this.unitPrice,
    this.discountPercent,
    this.discountAmount,
    this.lineTotal,
    this.shippedQuantity,
    this.returnedQuantity,
  });

  final int lineNo;
  final String variantId;
  final String? productId;
  final String? productName;
  final String? variantName;
  final String? sku;
  final LineQuantity quantity;
  final Qty? baseQuantity;
  final Money? unitPrice;
  final Percent? discountPercent;
  final Money? discountAmount;
  final Money? lineTotal;
  final Qty? shippedQuantity;
  final Qty? returnedQuantity;
}

/// Проекция документа 1С (`OrderOnecInfo`).
final class OrderOnecInfo {
  const OrderOnecInfo({this.number, this.date, this.ref, this.status, this.lastSyncAt});

  /// Номер документа 1С (`УТ-0001234`); `null` — документ ещё не создан (`submitting`).
  final String? number;
  final DateTime? date;
  final String? ref;

  /// Статус документа в 1С как есть («Не согласован»).
  final String? status;

  /// Время последнего статуса из 1С («Статус из 1С: HH:MM»).
  final DateTime? lastSyncAt;
}

/// Переход статуса (`OrderStatusHistoryEntry`).
final class OrderStatusEntry {
  const OrderStatusEntry({required this.status, required this.at, required this.source, this.by});

  final OrderStatus status;
  final DateTime at;
  final UserRef? by;
  final StatusChangeSource source;
}

/// Доступность документа (`OrderDocumentAvailability`).
final class DocumentAvailability {
  const DocumentAvailability({required this.available, this.reason});

  final bool available;

  /// `waybill_from_onec` — накладная печатается из 1С (D-27).
  final String? reason;
}

/// Документы заказа (`OrderDocuments`): ссылка → документ доступен.
final class OrderDocuments {
  const OrderDocuments({this.invoicePath, this.receiptPath, this.waybill});

  /// Счёт — после создания заказа (R0 §19.4).
  final String? invoicePath;

  /// Товарный чек — после получения оплаты.
  final String? receiptPath;

  /// Накладная — из 1С (`available:false` по умолчанию).
  final DocumentAvailability? waybill;
}

/// Ошибка отправки в 1С (`Order.submitError`).
final class OrderSubmitError {
  const OrderSubmitError({this.code, this.message});

  final String? code;
  final String? message;
}

/// Поля, общие для заказа и строки списка (`Order` ⊇ `OrderSummary`).
abstract base class OrderHeader {
  const OrderHeader({
    required this.id,
    required this.publicNumber,
    required this.status,
    required this.total,
    required this.paymentMethod,
    this.onec,
    this.onecSyncState,
    this.onecTotal,
    this.totalsDiffer = false,
    this.customer,
    this.receiver,
    this.delivery,
    this.warehouseId,
    this.priceListId,
    this.subtotal,
    this.discountPercent,
    this.customerDiscountTotal,
    this.discountTotal,
    this.cashRounding = Money.zero,
    this.totalToPay,
    this.paidAmount,
    this.isPaid = false,
    this.paymentDueDate,
    this.paidAt,
    this.documents,
    this.printOptions,
    this.comment,
    this.cancelReason,
    this.cancelReasonCode,
    this.refundIntent,
    this.cancelRequested = false,
    this.cancelRequestedAt,
    this.submitError,
    this.createdFromCartId,
    this.idempotencyKey,
    this.createdAt,
    this.createdBy,
  });

  final String id;

  /// `POS-2026-000123`.
  final String publicNumber;
  final OrderStatus status;
  final OrderOnecInfo? onec;
  final OnecSyncState? onecSyncState;

  /// Итог 1С (истина, D-23); при расхождении — [totalsDiffer] и баннер «Итог уточнён 1С».
  final Money? onecTotal;
  final bool totalsDiffer;
  final Customer? customer;
  final Receiver? receiver;
  final Delivery? delivery;
  final String? warehouseId;
  final String? priceListId;
  final Money? subtotal;
  final Percent? discountPercent;
  final Money? customerDiscountTotal;
  final Money? discountTotal;
  final Money total;

  /// Округление наличных (Q-016), по умолчанию 0.
  final Money cashRounding;
  final Money? totalToPay;
  final PaymentMethod paymentMethod;
  final Money? paidAmount;

  /// Флаг оплаты — не статус заказа (D-21).
  final bool isPaid;
  final DateTime? paymentDueDate;
  final DateTime? paidAt;
  final OrderDocuments? documents;
  final PrintOptions? printOptions;
  final String? comment;
  final String? cancelReason;
  final CancelReasonCode? cancelReasonCode;
  final RefundIntent? refundIntent;
  final bool cancelRequested;
  final DateTime? cancelRequestedAt;
  final OrderSubmitError? submitError;
  final String? createdFromCartId;
  final String? idempotencyKey;

  /// Момент создания заказа (`audit.createdAt`, 08 §3.5 AuditMeta) — шапка SCR-24 и столбец «Дата» SCR-25.
  final DateTime? createdAt;

  /// Автор заказа (`audit.createdBy`, UserRef без телефона) — шапка SCR-24.
  final UserRef? createdBy;
}

/// Строка списка заказов (`OrderSummary`).
final class OrderSummary extends OrderHeader {
  const OrderSummary({
    required super.id,
    required super.publicNumber,
    required super.status,
    required super.total,
    required super.paymentMethod,
    super.onec,
    super.onecSyncState,
    super.onecTotal,
    super.totalsDiffer,
    super.customer,
    super.receiver,
    super.delivery,
    super.warehouseId,
    super.priceListId,
    super.subtotal,
    super.discountPercent,
    super.customerDiscountTotal,
    super.discountTotal,
    super.cashRounding,
    super.totalToPay,
    super.paidAmount,
    super.isPaid,
    super.paymentDueDate,
    super.paidAt,
    super.documents,
    super.printOptions,
    super.comment,
    super.cancelReason,
    super.cancelReasonCode,
    super.refundIntent,
    super.cancelRequested,
    super.cancelRequestedAt,
    super.submitError,
    super.createdFromCartId,
    super.idempotencyKey,
    super.createdAt,
    super.createdBy,
    this.itemsCount,
    this.paymentsSummary = const <String, Object?>{},
  });

  final int? itemsCount;

  /// Сводка платежей (`paymentsSummary`; состав 08 не задан — открытый объект).
  final Map<String, Object?> paymentsSummary;
}

/// Заказ (`Order`).
final class Order extends OrderHeader {
  const Order({
    required super.id,
    required super.publicNumber,
    required super.status,
    required super.total,
    required super.paymentMethod,
    required this.items,
    super.onec,
    super.onecSyncState,
    super.onecTotal,
    super.totalsDiffer,
    super.customer,
    super.receiver,
    super.delivery,
    super.warehouseId,
    super.priceListId,
    super.subtotal,
    super.discountPercent,
    super.customerDiscountTotal,
    super.discountTotal,
    super.cashRounding,
    super.totalToPay,
    super.paidAmount,
    super.isPaid,
    super.paymentDueDate,
    super.paidAt,
    super.documents,
    super.printOptions,
    super.comment,
    super.cancelReason,
    super.cancelReasonCode,
    super.refundIntent,
    super.cancelRequested,
    super.cancelRequestedAt,
    super.submitError,
    super.createdFromCartId,
    super.idempotencyKey,
    super.createdAt,
    super.createdBy,
    this.payments = const <Payment>[],
    this.history = const <OrderStatusEntry>[],
    this.warnings = const <ApiWarning>[],
  });

  final List<OrderLine> items;
  final List<Payment> payments;
  final List<OrderStatusEntry> history;

  /// `warnings[]` ответа (`STALE_DATA` у `202` создания, `QR_UNAVAILABLE`).
  final List<ApiWarning> warnings;
}

/// Действие над заказом, доступное по статусу и правам (`OrdersAllowedAction`).
enum OrderAction {
  cancel('cancel'),
  pay('pay'),
  printInvoice('print_invoice'),
  printReceipt('print_receipt'),
  returnRequest('return_request');

  const OrderAction(this.value);

  final String value;

  static OrderAction? tryParse(String? value) {
    for (final OrderAction a in values) {
      if (a.value == value) return a;
    }
    return null;
  }
}

/// `GET /orders/{id}` (`OrdersGetResponse`): заказ + допустимые действия.
final class OrderDetails {
  const OrderDetails({required this.order, this.allowedActions = const <OrderAction>{}});

  final Order order;
  final Set<OrderAction> allowedActions;
}

/// Сортировка списка (`GET /orders?sort=`).
enum OrdersSort {
  createdAtDesc('createdAt:desc'),
  totalDesc('total:desc'),
  statusAsc('status:asc');

  const OrdersSort(this.value);

  final String value;
}

/// Параметры `GET /orders` (SCR-25: `/orders?status=&from=&to=&customerId=&mine=`).
final class OrdersQuery {
  const OrdersQuery({
    this.statuses = const <OrderStatus>{},
    this.customerId,
    this.createdBy,
    this.from,
    this.to,
    this.paymentMethod,
    this.isPaid,
    this.q,
    this.withStatusCounts = false,
    this.sort = OrdersSort.createdAtDesc,
    this.limit = 50,
    this.cursor,
  });

  final Set<OrderStatus> statuses;
  final String? customerId;

  /// Автор заказа — только при `order.read.all` («Мои» для кассира = свой id).
  final String? createdBy;
  final DateTime? from;
  final DateTime? to;
  final PaymentMethod? paymentMethod;
  final bool? isPaid;

  /// Поиск (≤ 200).
  final String? q;

  /// `include=statusCounts` — счётчики для чипов SCR-25.
  final bool withStatusCounts;
  final OrdersSort sort;
  final int limit;
  final String? cursor;
}

/// Страница `GET /orders` (+ `statusCounts`).
final class OrdersPage {
  const OrdersPage({required this.page, this.statusCounts = const <OrderStatus, int>{}});

  final PageResult<OrderSummary> page;

  /// Число заказов по статусам при всех фильтрах, кроме `status` (только при `include=statusCounts`).
  final Map<OrderStatus, int> statusCounts;
}

/// Тело `POST /orders/{id}/cancel` (`OrdersCancelRequest`); [refundIntent] обязателен при полученных платежах.
final class OrderCancelRequest {
  const OrderCancelRequest({required this.reason, required this.reasonCode, this.refundIntent});

  /// 1…500.
  final String reason;
  final CancelReasonCode reasonCode;
  final RefundIntent? refundIntent;
}

/// Тело `POST /orders/{id}/onec-link` (`OrdersOnecLinkRequest`; step-up `order.onec_link`).
final class OrderOnecLinkRequest {
  const OrderOnecLinkRequest({required this.onecNumber, required this.reason, this.onecDate});

  /// Номер документа 1С как есть (1…32).
  final String onecNumber;
  final DateTime? onecDate;

  /// 5…500.
  final String reason;
}

/// Печатная форма заказа (08 §4.8.5).
enum OrderDocumentKind {
  /// Счёт на оплату — после создания заказа (нужен номер 1С; иначе `409 ORDER_STATE_INVALID`).
  invoice('invoice'),

  /// Нефискальный товарный чек — после получения оплаты.
  receipt('receipt');

  const OrderDocumentKind(this.value);

  final String value;
}

/// PDF печатной формы (байты — только в памяти; содержит ПДн клиента — `order_doc_pdn_warning`).
final class OrderDocumentFile {
  const OrderDocumentFile({required this.bytes, required this.fileName, this.etag});

  final List<int> bytes;

  /// Из `Content-Disposition` (`invoice-<publicNumber>.pdf`).
  final String fileName;
  final String? etag;
}

/// Статус накладной (`OrdersWaybillStatus`; R1 — `available:false`, печать из 1С).
final class WaybillStatus {
  const WaybillStatus({required this.available, required this.reason, this.onecNumber});

  final bool available;
  final String reason;
  final String? onecNumber;
}

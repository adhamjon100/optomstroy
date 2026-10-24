// DTO-кодеки заказов и платежей (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `Order`,
// `OrderSummary`, `OrdersGetResponse`, `OrderItem`, `OrderOnecInfo`, `OrderStatusHistoryEntry`, `OrderDocuments`,
// `OrderDocumentAvailability`, `OrdersWaybillStatus`, `Payment`, `QrInfo`, `PaymentAllocation`, `PaymentOnecInfo`,
// `PaymentsGetResponse`, `OrdersPaymentResult`, `OrdersPaymentsListResponse` и тела запросов
// `OrdersCancelRequest`, `OrdersOnecLinkRequest`, `OrdersPaymentCreateRequest`, `PaymentsConfirmManualRequest`,
// `PaymentsVoidRequest`. Сверка — test/features/orders/data/order_dtos_contract_test.dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// Разбор вложенного `Customer` (кодек фичи customers подставляют bindings; FL-06).
typedef OrderCustomerDecoder = Customer Function(JsonMap json);

/// Минимальный разбор клиента заказа (id, name, displayName, флаги) — по умолчанию.
Customer minimalOrderCustomer(JsonMap j) => Customer(
  id: jReq<String>(j, 'id'),
  name: jReq<String>(j, 'name'),
  displayName: jOpt<String>(j, 'displayName'),
  isRetailDefault: jBool(j, 'isRetailDefault') ?? false,
  hasDebt: jBool(j, 'hasDebt'),
  isOverdue: jBool(j, 'isOverdue'),
);

/// `OrderItem`.
abstract final class OrderItemDto {
  static const Set<String> jsonKeys = {
    'lineNo',
    'variantId',
    'productId',
    'productName',
    'variantName',
    'sku',
    'quantity',
    'baseQuantity',
    'unitPrice',
    'discountPercent',
    'discountAmount',
    'lineTotal',
    'shippedQuantity',
    'returnedQuantity',
  };
  static const Set<String> requiredKeys = {'lineNo', 'variantId', 'quantity'};

  static OrderLine fromJson(JsonMap j) => OrderLine(
    lineNo: jReqInt(j, 'lineNo'),
    variantId: jReq<String>(j, 'variantId'),
    productId: jOpt<String>(j, 'productId'),
    productName: jOpt<String>(j, 'productName'),
    variantName: jOpt<String>(j, 'variantName'),
    sku: jOpt<String>(j, 'sku'),
    quantity: QuantityDto.fromJson(jReqObject(j, 'quantity')),
    baseQuantity: jQty(j, 'baseQuantity'),
    unitPrice: jMoney(j, 'unitPrice'),
    discountPercent: jPercent(j, 'discountPercent'),
    discountAmount: jMoney(j, 'discountAmount'),
    lineTotal: jMoney(j, 'lineTotal'),
    shippedQuantity: jQty(j, 'shippedQuantity'),
    returnedQuantity: jQty(j, 'returnedQuantity'),
  );
}

/// `OrderOnecInfo`.
abstract final class OrderOnecInfoDto {
  static const Set<String> jsonKeys = {'number', 'date', 'ref', 'status', 'lastSyncAt'};
  static const Set<String> requiredKeys = <String>{};

  static OrderOnecInfo fromJson(JsonMap j) => OrderOnecInfo(
    number: jOpt<String>(j, 'number'),
    date: jDate(j, 'date'),
    ref: jOpt<String>(j, 'ref'),
    status: jOpt<String>(j, 'status'),
    lastSyncAt: jDate(j, 'lastSyncAt'),
  );
}

/// `OrderStatusHistoryEntry`.
abstract final class OrderStatusEntryDto {
  static const Set<String> jsonKeys = {'status', 'at', 'by', 'source'};
  static const Set<String> requiredKeys = {'status', 'at', 'source'};

  static OrderStatusEntry fromJson(JsonMap j) => OrderStatusEntry(
    status: jReqEnum(j, 'status', OrderStatus.tryParse),
    at: jReqDate(j, 'at'),
    by: UserRefDto.optional(j, 'by'),
    source: jReqEnum(j, 'source', StatusChangeSource.tryParse),
  );
}

/// `OrderDocumentAvailability`.
abstract final class DocumentAvailabilityDto {
  static const Set<String> jsonKeys = {'available', 'reason'};
  static const Set<String> requiredKeys = {'available'};

  static DocumentAvailability fromJson(JsonMap j) =>
      DocumentAvailability(available: jBool(j, 'available') ?? false, reason: jOpt<String>(j, 'reason'));
}

/// `OrderDocuments`.
abstract final class OrderDocumentsDto {
  static const Set<String> jsonKeys = {'invoice', 'receipt', 'waybill'};
  static const Set<String> requiredKeys = <String>{};

  static OrderDocuments fromJson(JsonMap j) {
    final JsonMap? waybill = jObject(j, 'waybill');
    return OrderDocuments(
      invoicePath: jOpt<String>(j, 'invoice'),
      receiptPath: jOpt<String>(j, 'receipt'),
      waybill: waybill == null ? null : DocumentAvailabilityDto.fromJson(waybill),
    );
  }
}

/// `OrdersWaybillStatus`.
abstract final class WaybillStatusDto {
  static const Set<String> jsonKeys = {'available', 'reason', 'onecNumber'};
  static const Set<String> requiredKeys = {'available', 'reason'};

  static WaybillStatus fromJson(JsonMap j) => WaybillStatus(
    available: jBool(j, 'available') ?? false,
    reason: jReq<String>(j, 'reason'),
    onecNumber: jOpt<String>(j, 'onecNumber'),
  );
}

/// `QrInfo`.
abstract final class QrInfoDto {
  static const Set<String> jsonKeys = {
    'provider',
    'payload',
    'imageUrl',
    'bankReference',
    'amount',
    'expiresAt',
    'issuedAt',
    'autoConfirm',
  };
  static const Set<String> requiredKeys = {'provider', 'issuedAt', 'autoConfirm'};

  static QrInfo fromJson(JsonMap j) => QrInfo(
    rawProvider: jReq<String>(j, 'provider'),
    payload: jOpt<String>(j, 'payload'),
    imageUrl: jOpt<String>(j, 'imageUrl'),
    bankReference: jOpt<String>(j, 'bankReference'),
    amount: jMoney(j, 'amount'),
    expiresAt: jDate(j, 'expiresAt'),
    issuedAt: jReqDate(j, 'issuedAt'),
    autoConfirm: jBool(j, 'autoConfirm') ?? false,
  );
}

/// `PaymentAllocation`.
abstract final class PaymentAllocationDto {
  static const Set<String> jsonKeys = {'documentNumber', 'amount'};
  static const Set<String> requiredKeys = {'documentNumber', 'amount'};

  static PaymentAllocation fromJson(JsonMap j) =>
      PaymentAllocation(documentNumber: jReq<String>(j, 'documentNumber'), amount: jReqMoney(j, 'amount'));
}

/// `PaymentOnecInfo`.
abstract final class PaymentOnecInfoDto {
  static const Set<String> jsonKeys = {'ref', 'docType', 'status'};
  static const Set<String> requiredKeys = <String>{};

  static PaymentOnecInfo fromJson(JsonMap j) => PaymentOnecInfo(
    ref: jOpt<String>(j, 'ref'),
    docType: jOpt<String>(j, 'docType'),
    status: jEnum(j, 'status', OutboxStatus.tryParse),
  );
}

/// `Payment`.
abstract final class PaymentDto {
  static const Set<String> jsonKeys = {
    'id',
    'orderId',
    'customerId',
    'method',
    'status',
    'amount',
    'receivedAmount',
    'changeAmount',
    'qr',
    'externalRef',
    'confirmedBy',
    'confirmedAt',
    'confirmationKind',
    'reviewReason',
    'bankAmount',
    'voidReason',
    'warnings',
    'allocation',
    'onec',
    'idempotencyKey',
    // OpenAPI 1.2.0 (08 §3.10): транзакция журнала для перехода UI-24-008 → SCR-37.
    'transactionId',
  };
  static const Set<String> ignoredKeys = {'audit'};
  static const Set<String> requiredKeys = {'id', 'method', 'status', 'amount'};

  static Payment fromJson(JsonMap j) {
    final JsonMap? qr = jObject(j, 'qr');
    final JsonMap? onec = jObject(j, 'onec');
    return Payment(
      id: jReq<String>(j, 'id'),
      orderId: jOpt<String>(j, 'orderId'),
      customerId: jOpt<String>(j, 'customerId'),
      method: jReqEnum(j, 'method', PaymentMethod.tryParse),
      status: jReqEnum(j, 'status', PaymentStatus.tryParse),
      amount: jReqMoney(j, 'amount'),
      receivedAmount: jMoney(j, 'receivedAmount'),
      changeAmount: jMoney(j, 'changeAmount'),
      qr: qr == null ? null : QrInfoDto.fromJson(qr),
      externalRef: jOpt<String>(j, 'externalRef'),
      confirmedBy: UserRefDto.optional(j, 'confirmedBy'),
      confirmedAt: jDate(j, 'confirmedAt'),
      confirmationKind: jEnum(j, 'confirmationKind', PaymentConfirmationKind.tryParse),
      reviewReason: jEnum(j, 'reviewReason', ReviewReason.tryParse),
      bankAmount: jMoney(j, 'bankAmount'),
      voidReason: jOpt<String>(j, 'voidReason'),
      warnings: WarningDto.listOf(j),
      allocation: jObjects(j, 'allocation', PaymentAllocationDto.fromJson),
      onec: onec == null ? null : PaymentOnecInfoDto.fromJson(onec),
      idempotencyKey: jOpt<String>(j, 'idempotencyKey'),
      transactionId: jOpt<String>(j, 'transactionId'),
    );
  }
}

/// `PaymentsGetResponse` = Payment + `allowedActions`.
abstract final class PaymentDetailsDto {
  static const Set<String> jsonKeys = {...PaymentDto.jsonKeys, 'allowedActions'};
  static const Set<String> requiredKeys = {...PaymentDto.requiredKeys, 'allowedActions'};

  static PaymentDetails fromJson(JsonMap j) => PaymentDetails(
    payment: PaymentDto.fromJson(j),
    allowedActions: <PaymentAction>{
      for (final String a in jStrings(j, 'allowedActions'))
        if (PaymentAction.tryParse(a) case final PaymentAction known) known,
    },
  );
}

/// `OrdersPaymentResult` = Payment + `order { paidAmount, isPaid }`.
abstract final class OrderPaymentResultDto {
  static const Set<String> jsonKeys = {...PaymentDto.jsonKeys, 'order'};
  static const Set<String> requiredKeys = {...PaymentDto.requiredKeys, 'order'};

  /// `OrdersPaymentOrderState`.
  static const Set<String> orderStateKeys = {'paidAmount', 'isPaid'};

  static OrderPaymentResult fromJson(JsonMap j, {required bool created}) {
    final JsonMap order = jReqObject(j, 'order');
    return OrderPaymentResult(
      payment: PaymentDto.fromJson(j),
      orderPaidAmount: jReqMoney(order, 'paidAmount'),
      orderIsPaid: jBool(order, 'isPaid') ?? false,
      created: created,
    );
  }
}

/// Общая часть `Order` и `OrderSummary`.
abstract final class OrderHeaderDto {
  static const Set<String> commonKeys = {
    'id',
    'publicNumber',
    'status',
    'onec',
    'onecSyncState',
    'onecTotal',
    'totalsDiffer',
    'customer',
    'receiver',
    'delivery',
    'warehouseId',
    'priceListId',
    'subtotal',
    'discountPercent',
    'customerDiscountTotal',
    'discountTotal',
    'total',
    'cashRounding',
    'totalToPay',
    'paymentMethod',
    'paidAmount',
    'isPaid',
    'paymentDueDate',
    'paidAt',
    'documents',
    'printOptions',
    'comment',
    'cancelReason',
    'cancelReasonCode',
    'refundIntent',
    'cancelRequested',
    'cancelRequestedAt',
    'submitError',
    'createdFromCartId',
    'idempotencyKey',
  };
  static const Set<String> requiredKeys = {'id', 'publicNumber', 'status', 'total', 'paymentMethod'};

  /// `submitError` (`{code, message}`).
  static OrderSubmitError? submitError(JsonMap j) {
    final JsonMap? e = jObject(j, 'submitError');
    return e == null ? null : OrderSubmitError(code: jOpt<String>(e, 'code'), message: jOpt<String>(e, 'message'));
  }

  static OrderOnecInfo? onec(JsonMap j) {
    final JsonMap? v = jObject(j, 'onec');
    return v == null ? null : OrderOnecInfoDto.fromJson(v);
  }

  static OrderDocuments? documents(JsonMap j) {
    final JsonMap? v = jObject(j, 'documents');
    return v == null ? null : OrderDocumentsDto.fromJson(v);
  }

  /// `audit.createdAt` (AuditMeta, 08 §3.5).
  static DateTime? createdAt(JsonMap j) {
    final JsonMap? audit = jObject(j, 'audit');
    return audit == null ? null : jDate(audit, 'createdAt');
  }

  /// `audit.createdBy` (UserRef без телефона, 08 §3.5).
  static UserRef? createdBy(JsonMap j) {
    final JsonMap? audit = jObject(j, 'audit');
    return audit == null ? null : UserRefDto.optional(audit, 'createdBy');
  }

  static Customer? customer(JsonMap j, OrderCustomerDecoder decode) {
    final JsonMap? v = jObject(j, 'customer');
    return v == null ? null : decode(v);
  }
}

/// `Order`.
abstract final class OrderDto {
  static const Set<String> jsonKeys = {
    ...OrderHeaderDto.commonKeys,
    'items',
    'payments',
    'history',
    'warnings',
    // `audit.createdAt` / `audit.createdBy` — шапка SCR-24 (контракт не меняется).
    'audit',
  };
  static const Set<String> ignoredKeys = <String>{};
  static const Set<String> requiredKeys = {...OrderHeaderDto.requiredKeys, 'items'};

  static Order fromJson(JsonMap j, {OrderCustomerDecoder customer = minimalOrderCustomer}) => Order(
    id: jReq<String>(j, 'id'),
    publicNumber: jReq<String>(j, 'publicNumber'),
    status: jReqEnum(j, 'status', OrderStatus.tryParse),
    onec: OrderHeaderDto.onec(j),
    onecSyncState: jEnum(j, 'onecSyncState', OnecSyncState.tryParse),
    onecTotal: jMoney(j, 'onecTotal'),
    totalsDiffer: jBool(j, 'totalsDiffer') ?? false,
    customer: OrderHeaderDto.customer(j, customer),
    receiver: ReceiverDto.optional(j, 'receiver'),
    delivery: DeliveryDto.optional(j, 'delivery'),
    warehouseId: jOpt<String>(j, 'warehouseId'),
    priceListId: jOpt<String>(j, 'priceListId'),
    items: jObjects(j, 'items', OrderItemDto.fromJson, required: true),
    subtotal: jMoney(j, 'subtotal'),
    discountPercent: jPercent(j, 'discountPercent'),
    customerDiscountTotal: jMoney(j, 'customerDiscountTotal'),
    discountTotal: jMoney(j, 'discountTotal'),
    total: jReqMoney(j, 'total'),
    cashRounding: jMoneyAmount(j, 'cashRounding') ?? Money.zero,
    totalToPay: jMoney(j, 'totalToPay'),
    paymentMethod: jReqEnum(j, 'paymentMethod', PaymentMethod.tryParse),
    paidAmount: jMoney(j, 'paidAmount'),
    isPaid: jBool(j, 'isPaid') ?? false,
    paymentDueDate: jDate(j, 'paymentDueDate'),
    paidAt: jDate(j, 'paidAt'),
    payments: jObjects(j, 'payments', PaymentDto.fromJson),
    documents: OrderHeaderDto.documents(j),
    printOptions: PrintOptionsDto.optional(j, 'printOptions'),
    comment: jOpt<String>(j, 'comment'),
    cancelReason: jOpt<String>(j, 'cancelReason'),
    cancelReasonCode: jEnum(j, 'cancelReasonCode', CancelReasonCode.tryParse),
    refundIntent: jEnum(j, 'refundIntent', RefundIntent.tryParse),
    cancelRequested: jBool(j, 'cancelRequested') ?? false,
    cancelRequestedAt: jDate(j, 'cancelRequestedAt'),
    submitError: OrderHeaderDto.submitError(j),
    history: jObjects(j, 'history', OrderStatusEntryDto.fromJson),
    createdFromCartId: jOpt<String>(j, 'createdFromCartId'),
    idempotencyKey: jOpt<String>(j, 'idempotencyKey'),
    createdAt: OrderHeaderDto.createdAt(j),
    createdBy: OrderHeaderDto.createdBy(j),
    warnings: WarningDto.listOf(j),
  );
}

/// `OrdersGetResponse` = Order + `allowedActions`.
abstract final class OrderDetailsDto {
  static const Set<String> jsonKeys = {...OrderDto.jsonKeys, 'allowedActions'};
  static const Set<String> requiredKeys = OrderDto.requiredKeys;

  static OrderDetails fromJson(JsonMap j, {OrderCustomerDecoder customer = minimalOrderCustomer}) => OrderDetails(
    order: OrderDto.fromJson(j, customer: customer),
    allowedActions: <OrderAction>{
      for (final String a in jStrings(j, 'allowedActions'))
        if (OrderAction.tryParse(a) case final OrderAction known) known,
    },
  );
}

/// `OrderSummary`.
abstract final class OrderSummaryDto {
  static const Set<String> jsonKeys = {...OrderHeaderDto.commonKeys, 'itemsCount', 'paymentsSummary', 'audit'};
  static const Set<String> ignoredKeys = <String>{};
  static const Set<String> requiredKeys = OrderHeaderDto.requiredKeys;

  static OrderSummary fromJson(JsonMap j, {OrderCustomerDecoder customer = minimalOrderCustomer}) => OrderSummary(
    id: jReq<String>(j, 'id'),
    publicNumber: jReq<String>(j, 'publicNumber'),
    status: jReqEnum(j, 'status', OrderStatus.tryParse),
    onec: OrderHeaderDto.onec(j),
    onecSyncState: jEnum(j, 'onecSyncState', OnecSyncState.tryParse),
    onecTotal: jMoney(j, 'onecTotal'),
    totalsDiffer: jBool(j, 'totalsDiffer') ?? false,
    customer: OrderHeaderDto.customer(j, customer),
    receiver: ReceiverDto.optional(j, 'receiver'),
    delivery: DeliveryDto.optional(j, 'delivery'),
    warehouseId: jOpt<String>(j, 'warehouseId'),
    priceListId: jOpt<String>(j, 'priceListId'),
    itemsCount: jInt(j, 'itemsCount'),
    subtotal: jMoney(j, 'subtotal'),
    discountPercent: jPercent(j, 'discountPercent'),
    customerDiscountTotal: jMoney(j, 'customerDiscountTotal'),
    discountTotal: jMoney(j, 'discountTotal'),
    total: jReqMoney(j, 'total'),
    cashRounding: jMoneyAmount(j, 'cashRounding') ?? Money.zero,
    totalToPay: jMoney(j, 'totalToPay'),
    paymentMethod: jReqEnum(j, 'paymentMethod', PaymentMethod.tryParse),
    paidAmount: jMoney(j, 'paidAmount'),
    isPaid: jBool(j, 'isPaid') ?? false,
    paymentDueDate: jDate(j, 'paymentDueDate'),
    paidAt: jDate(j, 'paidAt'),
    paymentsSummary: jObject(j, 'paymentsSummary') ?? const <String, Object?>{},
    documents: OrderHeaderDto.documents(j),
    printOptions: PrintOptionsDto.optional(j, 'printOptions'),
    comment: jOpt<String>(j, 'comment'),
    cancelReason: jOpt<String>(j, 'cancelReason'),
    cancelReasonCode: jEnum(j, 'cancelReasonCode', CancelReasonCode.tryParse),
    refundIntent: jEnum(j, 'refundIntent', RefundIntent.tryParse),
    cancelRequested: jBool(j, 'cancelRequested') ?? false,
    cancelRequestedAt: jDate(j, 'cancelRequestedAt'),
    submitError: OrderHeaderDto.submitError(j),
    createdFromCartId: jOpt<String>(j, 'createdFromCartId'),
    idempotencyKey: jOpt<String>(j, 'idempotencyKey'),
    createdAt: OrderHeaderDto.createdAt(j),
    createdBy: OrderHeaderDto.createdBy(j),
  );

  /// Ответ `GET /orders` (`Page<OrderSummary>` + `statusCounts`).
  static OrdersPage page(JsonMap j, {OrderCustomerDecoder customer = minimalOrderCustomer}) {
    final JsonMap? counts = jObject(j, 'statusCounts');
    return OrdersPage(
      page: PageDto.fromJson(j, (JsonMap item) => fromJson(item, customer: customer)),
      statusCounts: <OrderStatus, int>{
        if (counts != null)
          for (final MapEntry<String, dynamic> e in counts.entries)
            if (OrderStatus.tryParse(e.key) case final OrderStatus status)
              if (e.value is int) status: e.value as int,
      },
    );
  }
}

/// Тела запросов заказов и платежей (все — `additionalProperties: false`).
abstract final class OrderRequestDto {
  /// `OrdersCancelRequest`.
  static const Set<String> cancelKeys = {'reason', 'reasonCode', 'refundIntent'};
  static const Set<String> cancelRequired = {'reason', 'reasonCode'};

  static JsonMap cancel(OrderCancelRequest r) => <String, dynamic>{
    'reason': r.reason,
    'reasonCode': r.reasonCode.value,
    if (r.refundIntent != null) 'refundIntent': r.refundIntent!.value,
  };

  /// `OrdersOnecLinkRequest`.
  static const Set<String> onecLinkKeys = {'onecNumber', 'onecDate', 'reason'};
  static const Set<String> onecLinkRequired = {'onecNumber', 'reason'};

  static JsonMap onecLink(OrderOnecLinkRequest r) => <String, dynamic>{
    'onecNumber': r.onecNumber,
    if (r.onecDate != null) 'onecDate': _date(r.onecDate!),
    'reason': r.reason,
  };

  /// `OrdersPaymentCreateRequest`.
  static const Set<String> paymentKeys = {'method', 'receivedAmount', 'comment', 'reissueQr', 'manualOnly'};
  static const Set<String> paymentRequired = {'method'};

  static JsonMap payment(OrderPaymentRequest r) => <String, dynamic>{
    'method': r.method.value,
    if (r.receivedAmount != null) 'receivedAmount': moneyJson(r.receivedAmount!),
    if (r.comment != null && r.comment!.isNotEmpty) 'comment': r.comment,
    if (r.reissueQr) 'reissueQr': true,
    if (r.manualOnly) 'manualOnly': true,
  };

  /// `PaymentsConfirmManualRequest`.
  static const Set<String> confirmManualKeys = {'bankReference', 'receivedAmount', 'receivedAt', 'comment'};
  static const Set<String> confirmManualRequired = {'bankReference', 'receivedAmount'};

  static JsonMap confirmManual(ConfirmManualRequest r) => <String, dynamic>{
    'bankReference': r.bankReference,
    'receivedAmount': moneyJson(r.receivedAmount),
    if (r.receivedAt != null) 'receivedAt': r.receivedAt!.toUtc().toIso8601String(),
    if (r.comment != null && r.comment!.isNotEmpty) 'comment': r.comment,
  };

  /// `PaymentsVoidRequest`.
  static const Set<String> voidKeys = {'reason', 'reasonCode'};
  static const Set<String> voidRequired = {'reason', 'reasonCode'};

  static JsonMap voidPayment(VoidPaymentRequest r) => <String, dynamic>{
    'reason': r.reason,
    'reasonCode': r.reasonCode.value,
  };

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

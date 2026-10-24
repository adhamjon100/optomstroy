// ADR-085, RM-F-002/RM-F-003: ручные DTO заказов и платежей == contracts/openapi/pos-api.v1.yaml 1.2.0 (ключи,
// required, разбор синтетических примеров, тела запросов без суммы платежа — её формирует сервер).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/orders/data/dto/order_dtos.dart';
import 'package:optomstroy/features/orders/data/repositories/dio_orders_repository.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

import '../../../support/openapi_schemas.dart';

const List<String> _schemas = <String>[
  'Order',
  'OrderSummary',
  'OrdersGetResponse',
  'OrderItem',
  'OrderOnecInfo',
  'OrderStatusHistoryEntry',
  'OrderDocuments',
  'OrderDocumentAvailability',
  'OrdersWaybillStatus',
  'Payment',
  'QrInfo',
  'PaymentAllocation',
  'PaymentOnecInfo',
  'PaymentsGetResponse',
  'OrdersPaymentResult',
  'OrdersPaymentOrderState',
  'OrdersPaymentsListResponse',
  'OrdersCancelRequest',
  'OrdersOnecLinkRequest',
  'OrdersPaymentCreateRequest',
  'PaymentsConfirmManualRequest',
  'PaymentsVoidRequest',
];

const String _ordersList = '/orders get 200';

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(_schemas, responses: const <String>[_ordersList]);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required, {Set<String> ignored = const <String>{}}) {
    expect(keys.intersection(ignored), isEmpty, reason: '$name: ключ одновременно разбирается и игнорируется');
    expect(<String>{...keys, ...ignored}, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля ответов == схемы OpenAPI', () {
    matches('Order', OrderDto.jsonKeys, OrderDto.requiredKeys, ignored: OrderDto.ignoredKeys);
    matches(
      'OrderSummary',
      OrderSummaryDto.jsonKeys,
      OrderSummaryDto.requiredKeys,
      ignored: OrderSummaryDto.ignoredKeys,
    );
    matches('OrdersGetResponse', OrderDetailsDto.jsonKeys, OrderDetailsDto.requiredKeys, ignored: OrderDto.ignoredKeys);
    matches('OrderItem', OrderItemDto.jsonKeys, OrderItemDto.requiredKeys);
    matches('OrderOnecInfo', OrderOnecInfoDto.jsonKeys, OrderOnecInfoDto.requiredKeys);
    matches('OrderStatusHistoryEntry', OrderStatusEntryDto.jsonKeys, OrderStatusEntryDto.requiredKeys);
    matches('OrderDocuments', OrderDocumentsDto.jsonKeys, OrderDocumentsDto.requiredKeys);
    matches('OrderDocumentAvailability', DocumentAvailabilityDto.jsonKeys, DocumentAvailabilityDto.requiredKeys);
    matches('OrdersWaybillStatus', WaybillStatusDto.jsonKeys, WaybillStatusDto.requiredKeys);
    matches('Payment', PaymentDto.jsonKeys, PaymentDto.requiredKeys, ignored: PaymentDto.ignoredKeys);
    matches('QrInfo', QrInfoDto.jsonKeys, QrInfoDto.requiredKeys);
    matches('PaymentAllocation', PaymentAllocationDto.jsonKeys, PaymentAllocationDto.requiredKeys);
    matches('PaymentOnecInfo', PaymentOnecInfoDto.jsonKeys, PaymentOnecInfoDto.requiredKeys);
    matches(
      'PaymentsGetResponse',
      PaymentDetailsDto.jsonKeys,
      PaymentDetailsDto.requiredKeys,
      ignored: PaymentDto.ignoredKeys,
    );
    matches(
      'OrdersPaymentResult',
      OrderPaymentResultDto.jsonKeys,
      OrderPaymentResultDto.requiredKeys,
      ignored: PaymentDto.ignoredKeys,
    );
    matches('OrdersPaymentOrderState', OrderPaymentResultDto.orderStateKeys, OrderPaymentResultDto.orderStateKeys);
    expect(api!.props('OrdersPaymentsListResponse'), <String>{'items'});
  }, skip: skip);

  test('ответ GET /orders: Page<OrderSummary> + statusCounts', () {
    expect(api!.responseProps(_ordersList), <String>{
      'items',
      'nextCursor',
      'hasMore',
      'totalEstimate',
      'isEstimate',
      'asOf',
      'statusCounts',
    });
    final Map<String, dynamic> body = jsonCopy(api.responseExample(_ordersList))
      ..['statusCounts'] = <String, dynamic>{'submitting': 2, 'pending_approval': 5, 'future_status': 1};
    final OrdersPage page = OrderSummaryDto.page(body);
    expect(page.page.items.single.total, const Money(1600750));
    expect(page.statusCounts, <OrderStatus, int>{OrderStatus.submitting: 2, OrderStatus.pendingApproval: 5});
  }, skip: skip);

  test('тела запросов: ключи и обязательные поля == схемы OpenAPI', () {
    matches('OrdersCancelRequest', OrderRequestDto.cancelKeys, OrderRequestDto.cancelRequired);
    matches('OrdersOnecLinkRequest', OrderRequestDto.onecLinkKeys, OrderRequestDto.onecLinkRequired);
    matches('OrdersPaymentCreateRequest', OrderRequestDto.paymentKeys, OrderRequestDto.paymentRequired);
    matches('PaymentsConfirmManualRequest', OrderRequestDto.confirmManualKeys, OrderRequestDto.confirmManualRequired);
    matches('PaymentsVoidRequest', OrderRequestDto.voidKeys, OrderRequestDto.voidRequired);
  }, skip: skip);

  test('пример Order разбирается: строки, платежи с QR, история, документы', () {
    final Order order = OrderDto.fromJson(jsonCopy(api!.example('Order')));
    expect(order.publicNumber, 'POS-2026-000123');
    expect(order.status, OrderStatus.draft);
    expect(order.total, const Money(1600750));
    expect(order.cashRounding, const Money(1600750));
    expect(order.paymentMethod, PaymentMethod.cash);
    expect(order.items.single.quantity.value, const Qty(124000));
    expect(order.items.single.discountPercent, const Percent(500));
    expect(order.onec!.number, 'УТ-0001234');
    final Payment payment = order.payments.single;
    expect(payment.amount, const Money(1600750));
    expect(payment.qr!.provider, QrProvider.onec);
    expect(payment.qr!.autoConfirm, isTrue);
    expect(payment.confirmationKind, PaymentConfirmationKind.webhook);
    expect(payment.allocation.single.documentNumber, 'УТ-000123');
    expect(order.history.single.source, StatusChangeSource.posUser);
    expect(order.documents!.waybill!.reason, 'waybill_from_onec');
    expect(order.submitError!.code, 'ONEC_REJECTED');
    // OpenAPI 1.2.0: Payment.transactionId (UI-24-008 → SCR-37); шапка — из audit (08 §3.5).
    expect(payment.transactionId, isNotEmpty);
    expect(order.createdAt, DateTime.utc(2026, 10, 19, 9));
    expect(order.createdBy!.displayName, isNotEmpty);
  }, skip: skip);

  test('Payment без transactionId и заказ без audit — поля null (сервер этапа F их не передаёт)', () {
    final Map<String, dynamic> j = jsonCopy(api!.example('Order'));
    j.remove('audit');
    for (final Object? p in j['payments'] as List<Object?>) {
      (p! as Map<String, dynamic>).remove('transactionId');
    }
    final Order order = OrderDto.fromJson(j);
    expect(order.createdAt, isNull);
    expect(order.createdBy, isNull);
    expect(order.payments.single.transactionId, isNull);
    final Map<String, dynamic> summary = jsonCopy(api.example('OrderSummary'));
    expect(OrderSummaryDto.fromJson(summary).createdAt, DateTime.utc(2026, 10, 19, 9));
  }, skip: skip);

  test('примеры OrdersGetResponse, PaymentsGetResponse, OrdersPaymentResult, OrdersWaybillStatus разбираются', () {
    final OrderDetails details = OrderDetailsDto.fromJson(jsonCopy(api!.example('OrdersGetResponse')));
    expect(details.allowedActions, <OrderAction>{OrderAction.cancel});
    final PaymentDetails p = PaymentDetailsDto.fromJson(jsonCopy(api.example('PaymentsGetResponse')));
    expect(p.allowedActions, <PaymentAction>{PaymentAction.confirmManual});
    final OrderPaymentResult r = OrderPaymentResultDto.fromJson(
      jsonCopy(api.example('OrdersPaymentResult')),
      created: true,
    );
    expect((r.orderPaidAmount, r.orderIsPaid, r.created), (const Money(1600750), true, true));
    final WaybillStatus w = WaybillStatusDto.fromJson(jsonCopy(api.example('OrdersWaybillStatus')));
    expect((w.available, w.reason, w.onecNumber), (false, 'waybill_from_onec', 'УТ-0001234'));
  }, skip: skip);

  test('тело POST /orders/{id}/payments: сумму клиент не передаёт; варианты cash / reissueQr / manualOnly', () {
    expect(OrderRequestDto.payment(OrderPaymentRequest.cash(received: Money.som(17000))), <String, dynamic>{
      'method': 'cash',
      'receivedAmount': <String, dynamic>{'amount': '17000.00', 'currency': 'KGS'},
    });
    expect(OrderRequestDto.payment(const OrderPaymentRequest.reissueQr()), <String, dynamic>{
      'method': 'qr_bakai',
      'reissueQr': true,
    });
    expect(OrderRequestDto.payment(const OrderPaymentRequest.manualQr()), <String, dynamic>{
      'method': 'qr_bakai',
      'manualOnly': true,
    });
    expect(
      OrderRequestDto.voidPayment(
        const VoidPaymentRequest(reason: 'ошибка', reasonCode: PaymentVoidReasonCode.cashierError),
      ),
      <String, dynamic>{'reason': 'ошибка', 'reasonCode': 'cashier_error'},
    );
  });

  test('имя файла PDF из Content-Disposition', () {
    expect(contentDispositionFileName('inline; filename="invoice-POS-2026-000123.pdf"'), 'invoice-POS-2026-000123.pdf');
    expect(contentDispositionFileName("inline; filename*=UTF-8''receipt-1.pdf"), 'receipt-1.pdf');
    expect(contentDispositionFileName('inline; filename="../../etc/x.pdf"'), 'x.pdf');
    expect(contentDispositionFileName(null), isNull);
  });
}

// Порты заказов и платежей (08 §4.8, §4.9). Только онлайн: заказы и платежи в outbox не ставятся (DATA-254).
// Ключи идемпотентности платежей и отмены — только в памяти (ядро §22.6); автоповтора приёма денег нет
// (RetryInterceptor не повторяет `POST /orders/{id}/payments`, `/payments/{id}/confirm-manual|void`). Чистый Dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

abstract interface class OrdersRepository {
  /// Список заказов (`GET /orders`).
  Future<Result<OrdersPage>> list(OrdersQuery query);

  /// Поиск заказа по ключу `POST /orders` после перезапуска (`GET /orders?idempotencyKey=`; 0 или 1 элемент,
  /// только заказы текущего пользователя — DATA-263).
  Future<Result<OrderSummary?>> findByIdempotencyKey(String idempotencyKey);

  /// Заказ (`GET /orders/{id}`); [refreshFromOnec] — только staff: синхронный запрос статуса в 1С (6 с).
  Future<Result<OrderDetails>> get(String orderId, {bool refreshFromOnec = false});

  /// Отмена / запрос отмены (`POST /orders/{id}/cancel`, `Idempotency-Key` обязателен; чужой заказ —
  /// step-up `order.cancel.request.any`).
  Future<Result<Order>> cancel(
    String orderId,
    OrderCancelRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  });

  /// PDF счёта / товарного чека (`GET /orders/{id}/documents/{invoice|receipt}.pdf`).
  Future<Result<OrderDocumentFile>> document(
    String orderId,
    OrderDocumentKind kind, {
    PrintPaper format = PrintPaper.a4,
    bool copy = false,
  });

  /// Накладная: статус документа 1С (`GET /orders/{id}/documents/waybill.pdf` → JSON в R1).
  Future<Result<WaybillStatus>> waybill(String orderId);

  /// Ручная привязка к документу 1С (`POST /orders/{id}/onec-link`; senior_seller/admin/owner, step-up).
  Future<Result<Order>> linkOnec(
    String orderId,
    OrderOnecLinkRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  });
}

abstract interface class PaymentsRepository {
  /// Платежи заказа (`GET /orders/{id}/payments`) — проверка статуса после перезапуска (ядро §22.6).
  Future<Result<List<Payment>>> listForOrder(String orderId);

  /// Принять оплату / сформировать или обновить QR (`POST /orders/{id}/payments`, `Idempotency-Key` — в памяти).
  Future<Result<OrderPaymentResult>> createForOrder(
    String orderId,
    OrderPaymentRequest request, {
    required String idempotencyKey,
  });

  /// Платёж (`GET /payments/{id}`); [refreshStatus] — синхронно опросить провайдера QR.
  Future<Result<PaymentDetails>> get(String paymentId, {bool refreshStatus = false});

  /// Ожидание смены статуса: long-polling `GET /payments/{id}?wait=25` по кругу (08 §4.9.2, Q-167) до конечного
  /// статуса платежа (`received`, `credit`, `voided`, `refunded`, `qr_expired`). Отмена подписки отменяет текущий
  /// запрос (CancelToken). Если сервер отклоняет `wait` (`400 VALIDATION_FAILED`) — опрос каждые 3 с.
  /// Ошибки сети не завершают поток: элемент `FailureResult`, затем повтор с паузой.
  Stream<Result<PaymentDetails>> watch(String paymentId, {Duration wait = const Duration(seconds: 25)});

  /// Ручное подтверждение QR (`POST /payments/{id}/confirm-manual`; step-up `payment.qr.confirm_manual`).
  Future<Result<Payment>> confirmManual(
    String paymentId,
    ConfirmManualRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  });

  /// Аннулировать неполученный платёж (`POST /payments/{id}/void`; step-up `payment.void`).
  Future<Result<Payment>> voidPayment(
    String paymentId,
    VoidPaymentRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  });
}

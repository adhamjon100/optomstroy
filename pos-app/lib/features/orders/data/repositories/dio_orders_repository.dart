// `OrdersRepository` и `PaymentsRepository` поверх единственного Dio-клиента (08 §4.8, §4.9). Ошибки → Failure только
// через ErrorMapper (06 §6.8). Тела, PDF и QR не логируются и на диск не пишутся (07 §11.2: заказов и платежей в
// drift нет). Приём денег автоматически не повторяется (RetryInterceptor, ядро §22.6) — ключи платежей передаёт
// вызывающий из памяти.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/features/orders/data/dto/order_dtos.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/orders/domain/repositories/orders_repository.dart';

/// Пути API заказов и платежей (08 §4.8, §4.9).
abstract final class OrdersApiPaths {
  static const String orders = '/orders';
  static String order(String id) => '/orders/${Uri.encodeComponent(id)}';
  static String cancel(String id) => '${order(id)}/cancel';
  static String onecLink(String id) => '${order(id)}/onec-link';
  static String payments(String id) => '${order(id)}/payments';
  static String document(String id, OrderDocumentKind kind) => '${order(id)}/documents/${kind.value}.pdf';
  static String waybill(String id) => '${order(id)}/documents/waybill.pdf';
  static String payment(String id) => '/payments/${Uri.encodeComponent(id)}';
  static String confirmManual(String id) => '${payment(id)}/confirm-manual';
  static String voidPayment(String id) => '${payment(id)}/void';
}

Options _opts({
  String? idempotencyKey,
  String? stepUpToken,
  RetryProfile retry = RetryProfile.interactive,
  Duration? receiveTimeout,
  bool longPoll = false,
}) {
  final Options o = apiOptions(
    idempotencyKey: idempotencyKey,
    retry: retry,
    receiveTimeout: receiveTimeout,
    longPoll: longPoll,
  );
  if (stepUpToken != null) o.headers![ApiHeaders.stepUpToken] = stepUpToken; // check-secrets: allow (имя заголовка)
  return o;
}

String _date(DateTime d) => d.toUtc().toIso8601String();

final class DioOrdersRepository implements OrdersRepository {
  DioOrdersRepository(this._dio, {OrderCustomerDecoder customer = minimalOrderCustomer}) : _customer = customer;

  final Dio _dio;
  final OrderCustomerDecoder _customer;

  @override
  Future<Result<OrdersPage>> list(OrdersQuery query) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      OrdersApiPaths.orders,
      queryParameters: <String, Object?>{
        if (query.statuses.isNotEmpty) 'status': query.statuses.map((OrderStatus s) => s.value).join(','),
        'customerId': ?query.customerId,
        'createdBy': ?query.createdBy,
        if (query.from != null) 'from': _date(query.from!),
        if (query.to != null) 'to': _date(query.to!),
        if (query.paymentMethod != null) 'paymentMethod': query.paymentMethod!.value,
        'isPaid': ?query.isPaid,
        if (query.q != null && query.q!.isNotEmpty) 'q': query.q,
        if (query.withStatusCounts) 'include': 'statusCounts',
        'sort': query.sort.value,
        'limit': query.limit,
        'cursor': ?query.cursor,
      },
      options: _opts(),
    );
    return OrderSummaryDto.page(jsonObject(r.data), customer: _customer);
  });

  @override
  Future<Result<OrderSummary?>> findByIdempotencyKey(String idempotencyKey) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      OrdersApiPaths.orders,
      queryParameters: <String, Object?>{'idempotencyKey': idempotencyKey, 'limit': 1},
      options: _opts(),
    );
    final OrdersPage page = OrderSummaryDto.page(jsonObject(r.data), customer: _customer);
    return page.page.items.isEmpty ? null : page.page.items.first;
  });

  @override
  Future<Result<OrderDetails>> get(String orderId, {bool refreshFromOnec = false}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      OrdersApiPaths.order(orderId),
      queryParameters: <String, Object?>{if (refreshFromOnec) 'refreshFromOnec': true},
      options: _opts(),
    );
    return OrderDetailsDto.fromJson(jsonObject(r.data), customer: _customer);
  });

  @override
  Future<Result<Order>> cancel(
    String orderId,
    OrderCancelRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      OrdersApiPaths.cancel(orderId),
      data: OrderRequestDto.cancel(request),
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return OrderDto.fromJson(jsonObject(r.data), customer: _customer);
  });

  @override
  Future<Result<OrderDocumentFile>> document(
    String orderId,
    OrderDocumentKind kind, {
    PrintPaper format = PrintPaper.a4,
    bool copy = false,
  }) => ErrorMapper.guard(() async {
    final Options o = _opts(receiveTimeout: ApiTimeouts.pdf)
      ..responseType = ResponseType.bytes
      ..headers!['Accept'] = 'application/pdf';
    final Response<List<int>> r = await _dio.get<List<int>>(
      OrdersApiPaths.document(orderId, kind),
      queryParameters: <String, Object?>{'format': format.value, if (copy) 'copy': true},
      options: o,
    );
    final List<int> bytes = r.data ?? (throw const DtoFormatException('body'));
    return OrderDocumentFile(
      bytes: bytes,
      fileName: contentDispositionFileName(r.headers.value('content-disposition')) ?? '${kind.value}-$orderId.pdf',
      etag: r.headers.value(ApiHeaders.etag),
    );
  });

  @override
  Future<Result<WaybillStatus>> waybill(String orderId) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(OrdersApiPaths.waybill(orderId), options: _opts());
    final String type = r.headers.value(Headers.contentTypeHeader) ?? '';
    // Режим «печатная форма из 1С» (Q-019): PDF вместо статуса — документ доступен.
    if (type.startsWith('application/pdf')) return const WaybillStatus(available: true, reason: 'pdf_from_onec');
    return WaybillStatusDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<Order>> linkOnec(
    String orderId,
    OrderOnecLinkRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      OrdersApiPaths.onecLink(orderId),
      data: OrderRequestDto.onecLink(request),
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return OrderDto.fromJson(jsonObject(r.data), customer: _customer);
  });
}

/// Имя файла из `Content-Disposition: inline; filename="invoice-POS-2026-000123.pdf"`.
String? contentDispositionFileName(String? header) {
  if (header == null) return null;
  final RegExpMatch? m = RegExp(r'filename\*?=(?:UTF-8\x27\x27)?"?([^";]+)"?', caseSensitive: false).firstMatch(header);
  final String? name = m?.group(1)?.trim();
  if (name == null || name.isEmpty) return null;
  // Только имя файла: путь из заголовка не используется.
  return name.split(RegExp(r'[\\/]')).last;
}

final class DioPaymentsRepository implements PaymentsRepository {
  DioPaymentsRepository(this._dio, {Duration pollInterval = const Duration(seconds: 3), Duration? errorPause})
    : _pollInterval = pollInterval,
      _errorPause = errorPause ?? const Duration(seconds: 3);

  final Dio _dio;

  /// Интервал опроса, если сервер не поддерживает `wait` (08 §4.9.2, Q-167: «не нужен» → опрос каждые 3 с).
  final Duration _pollInterval;

  /// Пауза после ошибки сети в [watch].
  final Duration _errorPause;

  @override
  Future<Result<List<Payment>>> listForOrder(String orderId) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(OrdersApiPaths.payments(orderId), options: _opts());
    return jObjects(jsonObject(r.data), 'items', PaymentDto.fromJson, required: true);
  });

  @override
  Future<Result<OrderPaymentResult>> createForOrder(
    String orderId,
    OrderPaymentRequest request, {
    required String idempotencyKey,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      OrdersApiPaths.payments(orderId),
      data: OrderRequestDto.payment(request),
      options: _opts(idempotencyKey: idempotencyKey, retry: RetryProfile.none),
    );
    return OrderPaymentResultDto.fromJson(jsonObject(r.data), created: r.statusCode == 201);
  });

  @override
  Future<Result<PaymentDetails>> get(String paymentId, {bool refreshStatus = false}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      OrdersApiPaths.payment(paymentId),
      queryParameters: <String, Object?>{if (refreshStatus) 'refreshStatus': true},
      options: _opts(),
    );
    return PaymentDetailsDto.fromJson(jsonObject(r.data));
  });

  Future<Result<PaymentDetails>> _longPoll(String paymentId, Duration wait, CancelToken cancel) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.get<Object?>(
          OrdersApiPaths.payment(paymentId),
          queryParameters: <String, Object?>{'wait': wait.inSeconds.clamp(1, 25)},
          options: _opts(longPoll: true, retry: RetryProfile.none, receiveTimeout: ApiTimeouts.longPoll(wait)),
          cancelToken: cancel,
        );
        return PaymentDetailsDto.fromJson(jsonObject(r.data));
      });

  /// Статусы, при которых ожидание имеет смысл (деньги ещё не получены, решение не принято).
  static bool _awaiting(PaymentStatus s) => switch (s) {
    PaymentStatus.initiated ||
    PaymentStatus.cashPending ||
    PaymentStatus.qrPending ||
    PaymentStatus.qrShown ||
    PaymentStatus.manualConfirm => true,
    _ => false,
  };

  @override
  Stream<Result<PaymentDetails>> watch(String paymentId, {Duration wait = const Duration(seconds: 25)}) {
    late final StreamController<Result<PaymentDetails>> controller;
    CancelToken? token;
    Completer<void>? sleeping;
    bool active = true;
    bool longPolling = true;

    Future<void> pause(Duration d) {
      final Completer<void> done = sleeping = Completer<void>();
      final Timer timer = Timer(d, () {
        if (!done.isCompleted) done.complete();
      });
      return done.future.whenComplete(timer.cancel);
    }

    Future<void> run() async {
      while (active) {
        token = CancelToken();
        final Result<PaymentDetails> r = longPolling ? await _longPoll(paymentId, wait, token!) : await get(paymentId);
        if (!active) break;
        switch (r) {
          case Success<PaymentDetails>(:final PaymentDetails value):
            controller.add(r);
            if (!_awaiting(value.payment.status)) {
              active = false;
              break;
            }
            if (!longPolling) await pause(_pollInterval);
          case FailureResult<PaymentDetails>(:final Failure failure):
            // Таймаут long-polling — штатный конец ожидания без смены статуса.
            if (longPolling && failure is NetworkFailure && failure.kind == NetworkFailureKind.timeout) continue;
            // Сервер не поддерживает `wait` (Q-167) — переходим на опрос каждые 3 с.
            if (longPolling && failure is ValidationFailure) {
              longPolling = false;
              continue;
            }
            controller.add(r);
            if (failure is PermissionFailure || failure is AuthFailure || failure is AppUpdateRequiredFailure) {
              active = false;
              break;
            }
            if (failure case ServerFailure(:final String code) when code == ProblemCode.notFound.value) {
              active = false;
              break;
            }
            await pause(_errorPause);
        }
      }
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<Result<PaymentDetails>>(
      onListen: () => unawaited(run()),
      onCancel: () {
        active = false;
        token?.cancel('payment watch cancelled');
        final Completer<void>? s = sleeping;
        if (s != null && !s.isCompleted) s.complete();
      },
    );
    return controller.stream;
  }

  @override
  Future<Result<Payment>> confirmManual(
    String paymentId,
    ConfirmManualRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      OrdersApiPaths.confirmManual(paymentId),
      data: OrderRequestDto.confirmManual(request),
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken, retry: RetryProfile.none),
    );
    return PaymentDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<Payment>> voidPayment(
    String paymentId,
    VoidPaymentRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      OrdersApiPaths.voidPayment(paymentId),
      data: OrderRequestDto.voidPayment(request),
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken, retry: RetryProfile.none),
    );
    return PaymentDto.fromJson(jsonObject(r.data));
  });
}

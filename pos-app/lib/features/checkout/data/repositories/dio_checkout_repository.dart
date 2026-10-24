// `CheckoutRepository` поверх единственного Dio-клиента (08 §4.7.7, §4.8.1). `POST /orders` — с `Idempotency-Key`
// из `checkout_draft.order_idempotency_key` (ядро §22.6), таймаут ответа — `ApiTimeouts.orderCreate` (синхронная
// проверка 1С до 6 с). При обрыве (`NetworkFailure.outcomeUnknown`) повтор — тем же ключом; RetryInterceptor
// повторяет POST только с ключом (08 §2.10). Тела запросов и ответов не логируются.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_json_decoder.dart';
import 'package:optomstroy/features/checkout/data/dto/checkout_dtos.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/domain/repositories/checkout_repository.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/repositories/order_json_decoder.dart';

/// Пути API оформления.
abstract final class CheckoutApiPaths {
  static const String preview = '/cart/checkout-preview';
  static const String orders = '/orders';
}

final class DioCheckoutRepository implements CheckoutRepository {
  DioCheckoutRepository(
    this._dio, {
    required CartJsonDecoder cart,
    required OrderJsonDecoder order,
    Clock clock = const SystemClock(),
  }) : _cart = cart,
       _order = order,
       _clock = clock;

  final Dio _dio;
  final CartJsonDecoder _cart;
  final OrderJsonDecoder _order;
  final Clock _clock;

  /// Ключ `details` с минутами с момента создания похожего заказа (UI-21-029 «N минут назад»): считается из
  /// `possibleDuplicateCreatedAt` (OpenAPI 1.2.0; 08 §4.8.1 «Уточнения POST /orders» п. 4). Не поле контракта —
  /// производное значение data-слоя; `possibleDuplicatePublicNumber` передаётся как есть.
  static const String possibleDuplicateMinutesAgoKey = 'possibleDuplicateMinutesAgo';

  static Options _opts({String? idempotencyKey, String? stepUpToken, Duration? receiveTimeout}) {
    final Options o = apiOptions(idempotencyKey: idempotencyKey, receiveTimeout: receiveTimeout);
    if (stepUpToken != null) o.headers![ApiHeaders.stepUpToken] = stepUpToken; // check-secrets: allow (имя заголовка)
    return o;
  }

  @override
  Future<Result<CheckoutPreview>> preview(CheckoutPreviewRequest request, {String? idempotencyKey}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.post<Object?>(
          CheckoutApiPaths.preview,
          data: CheckoutRequestDto.preview(request),
          options: _opts(idempotencyKey: idempotencyKey, receiveTimeout: ApiTimeouts.orderCreate),
        );
        return CheckoutPreviewDto.fromJson(jsonObject(r.data), cart: _cart, order: _order);
      });

  @override
  Future<Result<OrderCreateResult>> createOrder(
    OrderCreateRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    final Result<OrderCreateResult> result = await ErrorMapper.guard(() async {
      final Response<Object?> r = await _dio.post<Object?>(
        CheckoutApiPaths.orders,
        data: CheckoutRequestDto.create(request),
        options: _opts(
          idempotencyKey: idempotencyKey,
          stepUpToken: stepUpToken,
          receiveTimeout: ApiTimeouts.orderCreate,
        ),
      );
      return OrderCreateResult(
        order: _order.order(jsonObject(r.data)),
        accepted: r.statusCode == 202,
        replayed: r.headers.value(ApiHeaders.idempotentReplayed) == 'true',
      );
    });
    return switch (result) {
      FailureResult<OrderCreateResult>(failure: final ConflictFailure f) when f.reason == 'possible_duplicate' =>
        FailureResult<OrderCreateResult>(_withDuplicateAge(f)),
      _ => result,
    };
  }

  /// `409 possible_duplicate`: добавляет [possibleDuplicateMinutesAgoKey] по `possibleDuplicateCreatedAt` (если сервер
  /// его передал и минут ещё нет). Неразбираемая дата или момент в будущем — без изменений (08 §2.11).
  ConflictFailure _withDuplicateAge(ConflictFailure f) {
    final Object? raw = f.details['possibleDuplicateCreatedAt'];
    if (raw is! String || f.details.containsKey(possibleDuplicateMinutesAgoKey)) return f;
    final DateTime? createdAt = DateTime.tryParse(raw);
    if (createdAt == null) return f;
    final Duration age = _clock.nowUtc().difference(createdAt.toUtc());
    if (age.isNegative) return f;
    return ConflictFailure(
      f.kind,
      currentStatus: f.currentStatus,
      reason: f.reason,
      retryAfter: f.retryAfter,
      details: <String, Object?>{...f.details, possibleDuplicateMinutesAgoKey: age.inMinutes},
      requestId: f.requestId,
    );
  }

  @override
  Future<Result<OrderSummary?>> findSubmittedOrder(String idempotencyKey) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      CheckoutApiPaths.orders,
      queryParameters: <String, Object?>{'idempotencyKey': idempotencyKey, 'limit': 1},
      options: _opts(),
    );
    final List<OrderSummary> items = jObjects(jsonObject(r.data), 'items', _order.summary, required: true);
    return items.isEmpty ? null : items.first;
  });
}

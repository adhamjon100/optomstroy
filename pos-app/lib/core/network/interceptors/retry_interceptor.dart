// Автоповтор запросов по 08 §2.10 и 06 §6.7 (собственный, dio_smart_retry отклонён).
//
// Повторяются: GET/HEAD/OPTIONS; PUT/DELETE (идемпотентны по семантике), кроме
// `PUT /cart/items/{id}` с `mode=increment` без ключа; POST/PATCH — только с
// `Idempotency-Key`, ключ интерсептор никогда не создаёт и не меняет.
// НЕ повторяются автоматически операции приёма денег (ядро §22.6, §19.2; 08 §2.10
// «Приём денег»): `POST /orders/{id}/payments`, `POST /payments`,
// `POST /payments/{id}/confirm-manual`, `POST /payments/{id}/void` — после
// обрыва кассир проверяет статус и повторяет явным действием тем же ключом.
// Условия: сетевой сбой, таймаут, 502/504, 503 без problem-кода, 429 и
// 409 IDEMPOTENCY_IN_PROGRESS (по Retry-After). Backoff 1-2-4-8 с + джиттер;
// Retry-After приоритетнее. Число повторов — [RetryProfile] (2 / 4 / 0).
import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/problem.dart';

final class RetryInterceptor extends Interceptor {
  RetryInterceptor(this._dio, {Future<void> Function(Duration delay)? sleep, Random? random})
    : _sleep = sleep ?? _defaultSleep,
      _random = random ?? Random();

  /// Пауза Retry-After больше этого значения автоматически не выжидается.
  static const Duration maxRetryAfter = Duration(seconds: 30);

  /// Пути приёма денег (без базового префикса `/api/v1`).
  static final List<RegExp> moneyOperations = [
    RegExp(r'/orders/[^/]+/payments$'),
    RegExp(r'/payments$'),
    RegExp(r'/payments/[^/]+/(confirm-manual|void)$'),
  ];

  final Dio _dio;
  final Future<void> Function(Duration delay) _sleep;
  final Random _random;

  static Future<void> _defaultSleep(Duration delay) => Future<void>.delayed(delay);

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final attempt = options.retryAttempt;
    if (attempt >= options.retryProfile.maxRetries || !isRetryableRequest(options) || !isRetryableError(err)) {
      return handler.next(err);
    }
    final retryAfter = retryAfterOf(err.response);
    if (retryAfter != null && retryAfter > maxRetryAfter) return handler.next(err);
    await _sleep(retryAfter ?? backoff(attempt));
    options.extra[RequestExtra.retryAttempt] = attempt + 1;
    try {
      handler.resolve(await _dio.fetch<dynamic>(options));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  /// `1 с, 2 с, 4 с, 8 с` (+ джиттер до 20 %) для попытки [attempt] (с 0).
  Duration backoff(int attempt) {
    final base = 1000 * (1 << min(attempt, 3));
    return Duration(milliseconds: base + _random.nextInt(base ~/ 5 + 1));
  }

  /// Можно ли повторять запрос по его методу, пути и наличию ключа.
  static bool isRetryableRequest(RequestOptions options) {
    final method = options.method.toUpperCase();
    final path = options.uri.path;
    if (method == 'POST' && moneyOperations.any((re) => re.hasMatch(path))) return false;
    switch (method) {
      case 'GET' || 'HEAD' || 'OPTIONS':
        return true;
      case 'PUT' || 'DELETE':
        final data = options.data;
        final increment = data is Map && data['mode'] == 'increment';
        return !increment || options.idempotencyKey != null;
      case 'POST' || 'PATCH':
        return options.idempotencyKey != null;
      default:
        return false;
    }
  }

  /// Можно ли повторять при такой ошибке.
  static bool isRetryableError(DioException err) {
    switch (err.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return true;
      case DioExceptionType.receiveTimeout:
        // Таймаут long-poll — штатный конец ожидания: повтор решает вызывающий.
        return !err.requestOptions.isLongPoll;
      case DioExceptionType.badResponse:
        final status = err.response?.statusCode;
        final code = Problem.codeOf(err.response?.data);
        return switch (status) {
          502 || 504 || 429 => true,
          503 => code == null,
          409 => code == 'IDEMPOTENCY_IN_PROGRESS',
          _ => false,
        };
      case DioExceptionType.transformTimeout:
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return false;
    }
  }
}

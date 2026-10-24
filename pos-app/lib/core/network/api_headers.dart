// Имена заголовков и ключи `RequestOptions.extra` (08 §2.3).
import 'package:dio/dio.dart';

abstract final class ApiHeaders {
  static const String authorization = 'Authorization';
  static const String deviceId = 'X-Device-Id';
  static const String appVersion = 'X-App-Version';
  static const String platform = 'X-Platform';
  static const String minAppVersion = 'X-Min-App-Version';
  static const String recommendedAppVersion = 'X-Recommended-App-Version';
  static const String requestId = 'X-Request-Id';
  static const String idempotencyKey = 'Idempotency-Key';
  static const String idempotentReplayed = 'Idempotent-Replayed';
  static const String ifNoneMatch = 'If-None-Match';
  static const String etag = 'ETag';
  static const String acceptLanguage = 'Accept-Language';
  static const String stepUpToken = 'X-Step-Up-Token'; // check-secrets: allow — имя заголовка
  static const String retryAfter = 'Retry-After';
  static const String dataAsOf = 'X-Data-As-Of';
  static const String cacheControl = 'Cache-Control';
}

/// Профиль автоповтора (08 §2.10): 2 повтора для интерактивных запросов,
/// 4 — для фоновых GET; `none` — без автоповтора.
enum RetryProfile {
  interactive(2),
  background(4),
  none(0);

  const RetryProfile(this.maxRetries);

  final int maxRetries;
}

/// Таймауты клиента — единственный источник значений 08 §2.10 (06 §6.7).
abstract final class ApiTimeouts {
  static const Duration connect = Duration(seconds: 5);
  static const Duration receive = Duration(seconds: 15);

  /// `POST /orders` с синхронной проверкой 1С.
  static const Duration orderCreate = Duration(seconds: 30);

  /// PDF документов.
  static const Duration pdf = Duration(seconds: 60);

  /// Long-polling `GET /payments/{id}?wait=N`: `wait + 10` с.
  static Duration longPoll(Duration wait) => wait + const Duration(seconds: 10);
}

/// Ключи `RequestOptions.extra`, которыми пользуются интерсепторы core.
abstract final class RequestExtra {
  /// `true` — публичный эндпоинт без Bearer (08 §2.2 «Публичные эндпоинты»).
  static const String skipAuth = 'optomstroy.skipAuth';

  /// [RetryProfile]; по умолчанию — `interactive`.
  static const String retryProfile = 'optomstroy.retryProfile';

  /// `true` — long-polling: таймаут ответа — штатный конец ожидания (не ошибка сети).
  static const String longPoll = 'optomstroy.longPoll';

  /// Служебные (выставляют интерсепторы).
  static const String retryAttempt = 'optomstroy.retryAttempt';
  static const String authRetried = 'optomstroy.authRetried';
  static const String startedAt = 'optomstroy.startedAt';
  static const String etagCacheHit = 'optomstroy.etagCacheHit';
  static const String etagBypass = 'optomstroy.etagBypass'; // check-secrets: allow — ключ Options.extra
}

/// Опции запроса для слоя data.
Options apiOptions({
  bool skipAuth = false,
  RetryProfile retry = RetryProfile.interactive,
  bool longPoll = false,
  String? idempotencyKey,
  Duration? receiveTimeout,
}) => Options(
  receiveTimeout: receiveTimeout,
  headers: {ApiHeaders.idempotencyKey: ?idempotencyKey},
  extra: {RequestExtra.skipAuth: skipAuth, RequestExtra.retryProfile: retry, RequestExtra.longPoll: longPoll},
);

extension RequestOptionsExtra on RequestOptions {
  bool get skipAuth => extra[RequestExtra.skipAuth] == true;
  bool get isLongPoll => extra[RequestExtra.longPoll] == true;
  RetryProfile get retryProfile => extra[RequestExtra.retryProfile] as RetryProfile? ?? RetryProfile.interactive;
  int get retryAttempt => extra[RequestExtra.retryAttempt] as int? ?? 0;

  /// Значение `Idempotency-Key` без учёта регистра имени заголовка.
  String? get idempotencyKey {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'idempotency-key' && entry.value != null) return '${entry.value}';
    }
    return null;
  }
}

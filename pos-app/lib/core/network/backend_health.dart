// Проверка доступности backend: `GET /health` (liveness pos-api, 08 §3; R0 §16 п. 8).
//
// `/health` живёт вне префикса `/api/v1` (pos-api PREFIX_EXCLUDED_PATHS; pos-proxy: `handle /health*`),
// поэтому адрес строится от origin `API_BASE_URL`. Запрос идёт отдельным «голым» Dio без интерсепторов
// авторизации и повторов: liveness не требует сессии и не проверяет версию клиента (RM-C-015 п. 4).
// Используется при старте (RM-C-014: Splash → «нет сессии» → GET /health).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/network/api_headers.dart';

/// Итог одной проверки `GET /health`.
final class BackendHealthReport {
  const BackendHealthReport({required this.ok, this.httpStatus, this.requestId, this.errorType});

  /// `true` — 200 и тело `{status: "ok"}`.
  final bool ok;

  /// HTTP-статус ответа; `null` — ответа не было (сеть, таймаут).
  final int? httpStatus;

  /// `X-Request-Id` ответа (сквозной requestId, RM-C-010).
  final String? requestId;

  /// Тип ошибки транспорта (`DioExceptionType.name`), без текста и адресов.
  final String? errorType;

  @override
  String toString() =>
      'BackendHealthReport(ok: $ok, httpStatus: $httpStatus, requestId: $requestId, error: $errorType)';
}

/// Порт проверки доступности backend (в тестах — фейк).
abstract interface class BackendHealthProbe {
  /// Выполнить `GET /health`; не бросает исключений.
  Future<BackendHealthReport> check();

  /// Освободить ресурсы.
  void close();
}

/// Реализация на Dio.
final class DioBackendHealthProbe implements BackendHealthProbe {
  DioBackendHealthProbe(AppConfig config, {Dio? dio, Duration timeout = const Duration(seconds: 5)})
    : healthUri = healthUriFor(config.apiBaseUrl),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: timeout,
              receiveTimeout: timeout,
              sendTimeout: timeout,
              responseType: ResponseType.json,
            ),
          );

  /// `https://host[:port]/api/v1` → `https://host[:port]/health`.
  static Uri healthUriFor(Uri apiBaseUrl) => Uri(
    scheme: apiBaseUrl.scheme,
    userInfo: apiBaseUrl.userInfo,
    host: apiBaseUrl.host,
    port: apiBaseUrl.hasPort ? apiBaseUrl.port : null,
    path: '/health',
  );

  /// Адрес проверки.
  final Uri healthUri;
  final Dio _dio;

  @override
  Future<BackendHealthReport> check() async {
    try {
      final response = await _dio.getUri<Object?>(
        healthUri,
        options: Options(headers: <String, String>{'Accept': 'application/json'}, validateStatus: (_) => true),
      );
      final body = response.data;
      final ok = response.statusCode == 200 && body is Map && body['status'] == 'ok';
      return BackendHealthReport(
        ok: ok,
        httpStatus: response.statusCode,
        requestId: response.headers.value(ApiHeaders.requestId),
      );
    } on DioException catch (e) {
      return BackendHealthReport(ok: false, httpStatus: e.response?.statusCode, errorType: e.type.name);
    }
  }

  /// Без `force`: проверка «в полёте» (планировщик синхронизации проверяет `/health` при недоступном сервере)
  /// завершается штатно и попадает в `catch` вызывающего. `force: true` отменял попытку соединения внутри адаптера
  /// Dio, и `SocketException: Connection attempt cancelled` уходила необработанной в зону (найдено
  /// integration_test/catalog_flow_test.dart: закрытие приложения сразу после остановки стека).
  @override
  void close() => _dio.close();
}

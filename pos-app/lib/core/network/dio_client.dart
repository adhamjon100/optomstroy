// Единственный HTTP-клиент приложения (06 §6.7). Создаётся в core/di/core_providers.dart.
//
// Порядок интерсепторов (onRequest и onError выполняются в порядке добавления):
//   RequestId → ClientMeta → AppVersion → OnlineStatus → Logging → ETag → Auth → Retry.
// AppVersion и OnlineStatus видят каждый ответ, Logging — каждую попытку,
// ETag разрешает 304 до Auth/Retry, Auth обновляет токен до Retry.
// Refresh (`POST /auth/refresh`) идёт через отдельный Dio без Auth/Retry/ETag.
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/network/auth/token_refresher.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/network/etag_cache.dart';
import 'package:optomstroy/core/network/interceptors/app_version_interceptor.dart';
import 'package:optomstroy/core/network/interceptors/auth_interceptor.dart';
import 'package:optomstroy/core/network/interceptors/client_meta_interceptor.dart';
import 'package:optomstroy/core/network/interceptors/etag_interceptor.dart';
import 'package:optomstroy/core/network/interceptors/logging_interceptor.dart';
import 'package:optomstroy/core/network/interceptors/online_status_interceptor.dart';
import 'package:optomstroy/core/network/interceptors/request_id_interceptor.dart';
import 'package:optomstroy/core/network/interceptors/retry_interceptor.dart';

/// Зависимости клиента.
final class DioClientDeps {
  const DioClientDeps({
    required this.config,
    required this.meta,
    required this.tokens,
    required this.appVersion,
    required this.etagCache,
    this.onOutcome,
    this.onSessionEvent,
    this.refresher,
    this.adapter,
    this.logger,
    this.sleep,
  });

  final AppConfig config;
  final ClientMeta Function() meta;
  final TokenStore tokens;
  final AppVersionController appVersion;
  final EtagCache etagCache;
  final void Function(RequestOutcome outcome)? onOutcome;
  final void Function(SessionEvent event)? onSessionEvent;

  /// По умолчанию — [DioTokenRefresher] поверх «голого» Dio.
  final TokenRefresher? refresher;

  /// Транспорт (в тестах — фейк).
  final HttpClientAdapter? adapter;
  final Logger? logger;
  final Future<void> Function(Duration delay)? sleep;
}

abstract final class DioClient {
  static BaseOptions baseOptions(AppConfig config) => BaseOptions(
    baseUrl: config.apiBaseUrl.toString(),
    connectTimeout: ApiTimeouts.connect,
    receiveTimeout: ApiTimeouts.receive,
    sendTimeout: ApiTimeouts.receive,
    contentType: Headers.jsonContentType,
    responseType: ResponseType.json,
  );

  /// Основной клиент API.
  static Dio create(DioClientDeps deps) {
    final dio = Dio(baseOptions(deps.config));
    if (deps.adapter != null) dio.httpClientAdapter = deps.adapter!;
    final refresher = deps.refresher ?? DioTokenRefresher(_bare(deps));
    dio.interceptors.addAll([
      ..._common(deps),
      EtagInterceptor(dio, deps.etagCache),
      AuthInterceptor(dio: dio, tokens: deps.tokens, refresher: refresher, onSessionEvent: deps.onSessionEvent),
      RetryInterceptor(dio, sleep: deps.sleep),
    ]);
    return dio;
  }

  /// Клиент для `POST /auth/refresh`: общие заголовки и журнал, без Auth/Retry/ETag.
  static Dio _bare(DioClientDeps deps) {
    final dio = Dio(baseOptions(deps.config));
    if (deps.adapter != null) dio.httpClientAdapter = deps.adapter!;
    dio.interceptors.addAll(_common(deps));
    return dio;
  }

  static List<Interceptor> _common(DioClientDeps deps) => [
    RequestIdInterceptor(),
    ClientMetaInterceptor(deps.meta),
    AppVersionInterceptor(deps.appVersion),
    if (deps.onOutcome != null) OnlineStatusInterceptor(deps.onOutcome!),
    LoggingInterceptor(logger: deps.logger),
  ];
}

// Журнал HTTP без ПДн (06 §6.7, NFR-LOG-001): метод, путь, имена query-параметров
// (без значений), статус, длительность, requestId, код ошибки. Тела запросов и
// ответов, заголовки (Authorization, X-Step-Up-Token, телефоны, OTP, токены) не
// пишутся никогда; путь дополнительно маскируется PiiMasker.
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/models/problem.dart';
import 'package:optomstroy/core/utils/pii_masker.dart';

final class LoggingInterceptor extends Interceptor {
  LoggingInterceptor({Logger? logger, DateTime Function()? now})
    : _log = logger ?? Logger('http'),
      _now = now ?? DateTime.now;

  final Logger _log;
  final DateTime Function() _now;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[RequestExtra.startedAt] = _now();
    _log.fine(() => '→ ${options.method} ${describe(options)}');
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final o = response.requestOptions;
    _log.fine(() => '← ${o.method} ${describe(o)} ${response.statusCode} ${_elapsed(o)}ms rid=${_rid(response, o)}');
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final o = err.requestOptions;
    final response = err.response;
    final status = response?.statusCode ?? '-';
    final code = Problem.codeOf(response?.data) ?? '-';
    _log.warning(
      '✕ ${o.method} ${describe(o)} ${err.type.name} $status $code ${_elapsed(o)}ms '
      'rid=${_rid(response, o)} attempt=${o.retryAttempt}',
    );
    handler.next(err);
  }

  /// Путь без значений query: `/catalog/products?q=…&limit=…` → `/catalog/products ?[q,limit]`.
  static String describe(RequestOptions options) {
    final uri = options.uri;
    final names = uri.queryParameters.keys.toList()..sort();
    final query = names.isEmpty ? '' : ' ?[${names.join(',')}]';
    return '${PiiMasker.mask(uri.path)}$query';
  }

  int _elapsed(RequestOptions options) {
    final started = options.extra[RequestExtra.startedAt];
    return started is DateTime ? _now().difference(started).inMilliseconds : -1;
  }

  static String _rid(Response<dynamic>? response, RequestOptions options) =>
      response?.headers.value(ApiHeaders.requestId) ?? '${options.headers[ApiHeaders.requestId] ?? '-'}';
}

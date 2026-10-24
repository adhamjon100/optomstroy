// `X-Request-Id: <UUIDv7>` на каждый запрос (06 §6.7, 08 §2.3). Повтор того же
// запроса (retry/refresh) сохраняет идентификатор — корреляция в логах сервера.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:uuid/uuid.dart';

final class RequestIdInterceptor extends Interceptor {
  RequestIdInterceptor({String Function()? generate}) : _generate = generate ?? const Uuid().v7;

  final String Function() _generate;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers.putIfAbsent(ApiHeaders.requestId, _generate);
    handler.next(options);
  }
}

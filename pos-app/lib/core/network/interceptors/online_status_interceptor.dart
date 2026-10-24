// Исход запросов → OnlineStatus (06 §6.7): любой ответ сервера — online; нет
// соединения — offline; таймаут ответа или 502/503/504 без problem+json — serverDown.
// Таймаут long-poll — штатное завершение ожидания, статус не меняет.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/models/problem.dart';

final class OnlineStatusInterceptor extends Interceptor {
  OnlineStatusInterceptor(this._report);

  final void Function(RequestOutcome outcome) _report;

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _report(RequestOutcome.responded);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final outcome = outcomeOf(err);
    if (outcome != null) _report(outcome);
    handler.next(err);
  }

  /// Классификация ошибки; `null` — не влияет на статус (отмена, long-poll, прочее).
  static RequestOutcome? outcomeOf(DioException err) {
    switch (err.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
        return RequestOutcome.connectionFailed;
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return err.requestOptions.isLongPoll ? null : RequestOutcome.serverUnavailable;
      case DioExceptionType.badResponse:
        final status = err.response?.statusCode;
        final gateway = status == 502 || status == 503 || status == 504;
        return gateway && Problem.codeOf(err.response?.data) == null
            ? RequestOutcome.serverUnavailable
            : RequestOutcome.responded;
      case DioExceptionType.transformTimeout:
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return null;
    }
  }
}

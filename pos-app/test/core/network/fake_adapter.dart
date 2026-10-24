// Фейковый транспорт dio для тестов интерсепторов.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

typedef FakeHandler = Future<ResponseBody> Function(RequestOptions options);

ResponseBody json(int status, Object? body, {Map<String, String> headers = const {}}) => ResponseBody.fromString(
  body == null ? '' : jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [status >= 400 ? 'application/problem+json' : Headers.jsonContentType],
    for (final e in headers.entries) e.key.toLowerCase(): [e.value],
  },
);

Map<String, Object?> problem(String code, int status, {Map<String, Object?> extra = const {}}) => {
  'type': 'https://api.example/problems/${code.toLowerCase()}',
  'title': code,
  'status': status,
  'code': code,
  'requestId': 'rid-$code',
  ...extra,
};

final class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this._handler);

  final FakeHandler _handler;

  /// Все отправленные запросы (копия заголовков на момент отправки).
  final List<({String method, String path, Map<String, Object?> headers, Object? data})> requests = [];

  int countPath(String path) => requests.where((r) => r.path == path).length;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add((
      method: options.method,
      path: options.uri.path.replaceFirst('/api/v1', ''),
      headers: Map.of(options.headers),
      data: options.data,
    ));
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// Ошибка транспорта (нет соединения / таймаут).
Never transportError(RequestOptions options, DioExceptionType type) =>
    throw DioException(requestOptions: options, type: type, message: 'fake ${type.name}');

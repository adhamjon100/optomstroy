// Мост CancelSignal → CancelToken (06 §6.7, D-31; ревью G-flutter-data-3): отмена сигнала отменяет HTTP-запрос dio;
// серия сигналов отменяет предыдущий при новом.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/network/cancel_signal_dio.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';

/// Адаптер, который не отвечает, пока запрос не отменят.
final class _HangingAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) {
    requests++;
    final Completer<ResponseBody> c = Completer<ResponseBody>();
    unawaited(
      cancelFuture?.then((_) => c.completeError(DioException.requestCancelled(requestOptions: options, reason: 'x'))),
    );
    return c.future;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('без сигнала — без CancelToken', () {
    expect(dioCancelToken(null), isNull);
  });

  test('уже отменённый сигнал — токен отменён сразу', () {
    final CancelSignal s = CancelSignal()..cancel();
    expect(dioCancelToken(s)!.isCancelled, isTrue);
  });

  test('отмена сигнала отменяет запрос dio (DioExceptionType.cancel)', () async {
    final _HangingAdapter adapter = _HangingAdapter();
    final Dio dio = Dio()..httpClientAdapter = adapter;
    final CancelSignal s = CancelSignal();
    final Future<Response<Object?>> call = dio.get<Object?>('http://127.0.0.1/x', cancelToken: dioCancelToken(s));
    for (int i = 0; i < 20 && adapter.requests == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(adapter.requests, 1);
    s.cancel();
    await expectLater(
      call,
      throwsA(isA<DioException>().having((DioException e) => e.type, 'type', DioExceptionType.cancel)),
    );
  });

  test('CancelSignalSeries: next() отменяет предыдущий, cancel() — текущий', () {
    final CancelSignalSeries series = CancelSignalSeries();
    final CancelSignal a = series.next();
    final CancelSignal b = series.next();
    expect(a.isCancelled, isTrue);
    expect(b.isCancelled, isFalse);
    series.cancel();
    expect(b.isCancelled, isTrue);
    series.cancel(); // повторно — без ошибок
  });
}

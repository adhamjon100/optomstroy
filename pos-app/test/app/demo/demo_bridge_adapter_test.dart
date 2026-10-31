// Адаптер Dio веб-демо поверх моста к серверу в Web Worker (12 T-DEMO-012; 15 ADR-113 п. 2; 06 §6.10):
// - ответы 200 JSON, problem+json, PDF (байты), 204, 304 разбираются без потерь; тело запроса копируется;
// - отмена вызывает `cancel` моста и даёт `DioException` отмены;
// - чужой origin и путь вне `/api/v1/**` и `/health` — `connectionError` без вызова моста;
// - «Нет сети (имитация)» — `connectionError`;
// - таймауты отсчитываются от готовности воркера и начала выполнения, а не от постановки в очередь; `POST /orders` —
//   30 с, long-poll — wait + 10 с (core/network/api_headers.dart); до `ready` запрос ждёт `ready` или `fatal` без
//   предела (медленный старт показывает страница), заданный предел без `progress` — `receiveTimeout`.
// VM, фейковый мост (fake_demo_bridge.dart), ручное время; синтетические данные, без сети.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/demo/demo_bridge.dart';
import 'package:optomstroy/app/demo/demo_bridge_adapter.dart';
import 'package:optomstroy/app/demo/demo_overrides.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart' show RequestOutcome;
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dio_client.dart';
import 'package:optomstroy/core/network/interceptors/online_status_interceptor.dart';

import 'fake_demo_bridge.dart';

final class _Harness {
  _Harness({
    bool ready = true,
    FutureOr<DemoBridgeResponse> Function(FakeBridgeCall call)? handler,
    Duration? readyStallTimeout,
  }) {
    bridge = FakeDemoBridge(ready: ready, handler: handler);
    adapter = DemoBridgeAdapter(
      bridge,
      origin: demoTestOrigin,
      timer: timers.create,
      readyStallTimeout: readyStallTimeout,
    );
    // Те же BaseOptions, что у основного Dio приложения: connect 5 с, receive 15 с (08 §2.10).
    dio = Dio(DioClient.baseOptions(demoAppConfig(demoTestOrigin, constants: const <String, String>{'ENV': 'dev'})))
      ..httpClientAdapter = adapter;
  }

  final ManualTimers timers = ManualTimers();
  late final FakeDemoBridge bridge;
  late final DemoBridgeAdapter adapter;
  late final Dio dio;
}

/// Итог фьючерса без `await`: для проверок «ещё ждёт» под ручным временем.
final class _Pending<T> {
  _Pending(Future<T> future) {
    unawaited(
      future.then<void>(
        (T v) {
          value = v;
          done = true;
        },
        onError: (Object e, StackTrace _) {
          error = e;
          done = true;
        },
      ),
    );
  }

  bool done = false;
  T? value;
  Object? error;

  DioException get dioError => error! as DioException;
}

TypeMatcher<DioException> _dioError(DioExceptionType type) =>
    isA<DioException>().having((DioException e) => e.type, 'type', type);

Future<List<int>> _readAll(ResponseBody body) async {
  final List<int> out = <int>[];
  await body.stream.forEach(out.addAll);
  return out;
}

void main() {
  group('ответы моста разбираются без потерь', () {
    test('200 JSON: в мост — метод, путь с query, заголовки и тело; из моста — статус, заголовки и JSON', () async {
      final _Harness h = _Harness(
        handler: (FakeBridgeCall c) => bridgeJson(
          200,
          <String, Object?>{'id': 'c-1', 'rowVersion': 4},
          headers: <(String, String)>[
            ('etag', '"v4"'),
            ('x-request-id', 'rid-1'),
            ('x-data-as-of', '2026-10-29T10:00:00Z'),
            ('x-multi', 'a'),
            ('x-multi', 'b'),
          ],
        ),
      );

      final Response<Map<String, dynamic>> r = await h.dio.put<Map<String, dynamic>>(
        '/cart/items/p-1',
        data: <String, Object?>{'productId': 'p-1', 'qtyMilli': 2000},
        queryParameters: <String, Object?>{'mode': 'increment'},
        options: Options(
          headers: <String, Object?>{
            ApiHeaders.idempotencyKey: 'k-1',
            'X-Many': <String>['x', 'y'],
          },
        ),
      );

      expect(r.statusCode, 200);
      expect(r.data, <String, Object?>{'id': 'c-1', 'rowVersion': 4});
      expect(r.headers.value('etag'), '"v4"');
      expect(r.headers.value(ApiHeaders.requestId), 'rid-1');
      expect(r.headers.value(ApiHeaders.dataAsOf), '2026-10-29T10:00:00Z');
      expect(r.headers['x-multi'], <String>['a', 'b']);
      final FakeBridgeCall call = h.bridge.calls.single;
      expect(call.request.method, 'PUT');
      expect(call.url, '/api/v1/cart/items/p-1?mode=increment');
      expect(call.header(ApiHeaders.idempotencyKey), 'k-1');
      expect(call.header('content-type'), startsWith('application/json'));
      expect(
        <String>[
          for (final (String k, String v) in call.request.headers)
            if (k == 'X-Many') v,
        ],
        <String>['x', 'y'],
      );
      expect(call.jsonBody, <String, Object?>{'productId': 'p-1', 'qtyMilli': 2000});
    });

    test('problem+json 409 → badResponse с разобранным телом problem', () async {
      final _Harness h = _Harness(
        handler: (FakeBridgeCall c) => bridgeJson(409, <String, Object?>{
          'type': 'https://api.test/problems/version_conflict',
          'title': 'VERSION_CONFLICT',
          'status': 409,
          'code': 'VERSION_CONFLICT',
          'requestId': 'rid-2',
        }, contentType: 'application/problem+json'),
      );

      final DioException e = await h.dio
          .get<Object?>('/cart')
          .then<DioException>((_) => fail('ожидался 409'), onError: (Object e) => e as DioException);

      expect(e.type, DioExceptionType.badResponse);
      expect(e.response?.statusCode, 409);
      expect(e.response?.headers.value('content-type'), 'application/problem+json');
      expect((e.response?.data as Map<String, dynamic>)['code'], 'VERSION_CONFLICT');
    });

    test('PDF: байты без преобразований (ResponseType.bytes)', () async {
      final Uint8List pdf = Uint8List.fromList(<int>[
        ...ascii.encode('%PDF-1.7\n'),
        ...List<int>.generate(256, (i) => i),
      ]);
      final _Harness h = _Harness(
        handler: (FakeBridgeCall c) => DemoBridgeResponse(
          status: 200,
          headers: <(String, String)>[
            ('content-type', 'application/pdf'),
            ('content-disposition', 'attachment; filename="order-OS00-004601.pdf"'),
          ],
          body: pdf,
        ),
      );

      final Response<List<int>> r = await h.dio.get<List<int>>(
        '/orders/o-1/documents/invoice.pdf',
        options: Options(responseType: ResponseType.bytes),
      );

      expect(r.data, pdf);
      expect(r.headers.value('content-disposition'), contains('order-OS00-004601.pdf'));
    });

    test('204 без тела', () async {
      final _Harness h = _Harness(
        handler: (FakeBridgeCall c) =>
            DemoBridgeResponse(status: 204, headers: const <(String, String)>[], body: Uint8List(0)),
      );

      final Response<Object?> r = await h.dio.delete<Object?>('/favorites/p-1');

      expect(r.statusCode, 204);
      expect(r.data == null || r.data == '', isTrue);
      expect(h.bridge.calls.single.request.method, 'DELETE');
    });

    test('304 с ETag: статус и заголовки как есть (кэш разрешает EtagInterceptor)', () async {
      final _Harness h = _Harness(
        handler: (FakeBridgeCall c) =>
            DemoBridgeResponse(status: 304, headers: const <(String, String)>[('etag', '"v7"')], body: Uint8List(0)),
      );

      final Response<Object?> r = await h.dio.get<Object?>(
        '/catalog/products',
        options: Options(
          headers: <String, Object?>{ApiHeaders.ifNoneMatch: '"v7"'},
          validateStatus: (int? s) => s != null && s < 400,
        ),
      );
      expect(r.statusCode, 304);
      expect(r.headers.value('etag'), '"v7"');
      expect(h.bridge.calls.single.header(ApiHeaders.ifNoneMatch), '"v7"');

      // Без своего validateStatus — badResponse 304, как от настоящего сервера.
      await expectLater(
        h.dio.get<Object?>('/catalog/products'),
        throwsA(_dioError(DioExceptionType.badResponse).having((e) => e.response?.statusCode, 'status', 304)),
      );
    });

    test('тело запроса копируется в собственный буфер точной длины; буфер Dart не меняется', () async {
      final _Harness h = _Harness(
        handler: (FakeBridgeCall c) =>
            DemoBridgeResponse(status: 200, headers: const <(String, String)>[], body: Uint8List.fromList(<int>[7])),
      );
      final Uint8List original = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final Uint8List view = Uint8List.sublistView(original, 8, 40);
      final RequestOptions options = RequestOptions(
        baseUrl: '$demoTestOrigin/api/v1',
        path: '/uploads',
        method: 'POST',
      );

      final ResponseBody res = await h.adapter.fetch(
        options,
        Stream<Uint8List>.fromIterable(<Uint8List>[
          view,
          Uint8List.fromList(<int>[1, 2, 3]),
        ]),
        null,
      );

      expect(await _readAll(res), <int>[7]);
      final Uint8List sent = h.bridge.calls.single.request.body!;
      expect(sent, <int>[...view, 1, 2, 3]);
      expect(sent.offsetInBytes, 0);
      expect(sent.buffer.lengthInBytes, sent.length);
      expect(identical(sent.buffer, original.buffer), isFalse);
      sent[0] = 99;
      expect(original[8], 8);
      expect(view[0], 8);
    });

    test('GET без тела — body null; /health того же origin проходит', () async {
      final _Harness h = _Harness(handler: (FakeBridgeCall c) => bridgeJson(200, <String, Object?>{'status': 'ok'}));

      final Response<Object?> r = await h.dio.getUri<Object?>(Uri.parse('$demoTestOrigin/health'));

      expect(r.data, <String, Object?>{'status': 'ok'});
      expect(h.bridge.calls.single.url, '/health');
      expect(h.bridge.calls.single.request.body, isNull);
    });

    test('id запросов уникальны и между экземплярами адаптера (мост держит общий список ожидающих)', () async {
      final _Harness h = _Harness(handler: (FakeBridgeCall c) => bridgeJson(200, <String, Object?>{}));
      final Dio other = Dio(BaseOptions(baseUrl: '$demoTestOrigin/api/v1'))
        ..httpClientAdapter = DemoBridgeAdapter(h.bridge, origin: demoTestOrigin);

      await h.dio.get<Object?>('/me');
      await other.get<Object?>('/me');
      await h.dio.get<Object?>('/me');

      final List<String> ids = h.bridge.calls.map((FakeBridgeCall c) => c.id).toList();
      expect(ids.toSet(), hasLength(3));
    });
  });

  group('защита хоста: в сеть и мимо API ничего не уходит', () {
    for (final String url in <String>[
      'https://evil.test/api/v1/me',
      'http://optomstroy-demo.test/api/v1/me',
      'https://optomstroy-demo.test:8443/api/v1/me',
      'https://u:x@optomstroy-demo.test/api/v1/me',
      '$demoTestOrigin/images/0a1b/320.webp',
      '$demoTestOrigin/api/v10/me',
      '$demoTestOrigin/api/v1/%2e%2e/%2e%2e/__demo/reset',
      '$demoTestOrigin/api/v1%5C..%5C__demo/state',
      '$demoTestOrigin/__demo/state',
      '$demoTestOrigin/healthz',
      '$demoTestOrigin/',
    ]) {
      test('$url → connectionError без вызова моста', () async {
        final _Harness h = _Harness(handler: (FakeBridgeCall c) => bridgeJson(200, <String, Object?>{}));

        await expectLater(h.dio.getUri<Object?>(Uri.parse(url)), throwsA(_dioError(DioExceptionType.connectionError)));
        expect(h.bridge.calls, isEmpty);
      });
    }

    test('разрешены ровно /health, /api/v1 и /api/v1/** того же origin', () {
      final DemoBridgeAdapter a = DemoBridgeAdapter(FakeDemoBridge(), origin: demoTestOrigin);
      expect(a.bridgeUrlOf(Uri.parse('$demoTestOrigin/health')), '/health');
      expect(a.bridgeUrlOf(Uri.parse('$demoTestOrigin/api/v1')), '/api/v1');
      expect(
        a.bridgeUrlOf(Uri.parse('$demoTestOrigin/api/v1/search/products?q=%D0%BA%D1%80%D0%B0%D0%BD&limit=20')),
        '/api/v1/search/products?q=%D0%BA%D1%80%D0%B0%D0%BD&limit=20',
      );
      expect(a.bridgeUrlOf(Uri.parse('${demoTestOrigin.toUpperCase()}/api/v1/me')), '/api/v1/me');
      expect(a.bridgeUrlOf(Uri.parse('$demoTestOrigin:443/api/v1/me')), '/api/v1/me');
      expect(a.bridgeUrlOf(Uri.parse('$demoTestOrigin/health/deep')), isNull);
    });
  });

  group('«Нет сети» и остановленный сервер', () {
    test('включено «Нет сети (имитация)» → connectionError без вызова моста', () async {
      final _Harness h = _Harness(handler: (FakeBridgeCall c) => bridgeJson(200, <String, Object?>{}));
      h.bridge.offline = true;

      final DioException e = await h.dio
          .get<Object?>('/me')
          .then<DioException>((_) => fail('ожидалась ошибка'), onError: (Object e) => e as DioException);

      expect(e.type, DioExceptionType.connectionError);
      expect(e.error, isA<DemoBridgeException>().having((x) => x.code, 'code', DemoBridgeErrorCode.offline));
      expect(OnlineStatusInterceptor.outcomeOf(e), isNotNull);
      expect(h.bridge.calls, isEmpty);
    });

    test('«Нет сети» включили во время запроса (мост отклонил кодом offline) → connectionError', () async {
      final _Harness h = _Harness();
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/orders'));
      await settle();
      h.bridge.calls.single
        ..start()
        ..fail(const DemoBridgeException(DemoBridgeErrorCode.offline, 'Нет сети (имитация в демо-панели)'));
      await settle();

      expect(p.dioError.type, DioExceptionType.connectionError);
    });

    test('«Нет сети» включили, пока воркер запускался → connectionError, запрос в мост не ушёл', () async {
      final _Harness h = _Harness(ready: false);
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/me'));
      await settle();
      h.bridge
        ..offline = true
        ..becomeReady();
      await settle();

      expect(p.dioError.type, DioExceptionType.connectionError);
      expect(h.bridge.calls, isEmpty);
    });

    test('fatal воркера при старте → connectionError; запрос в мост не ушёл', () async {
      final _Harness h = _Harness(ready: false);
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/me'));
      await settle();
      h.bridge.failReady(DemoBridgeErrorCode.fatal, 'База демо не открылась');
      await settle();

      expect(p.dioError.type, DioExceptionType.connectionError);
      expect(h.bridge.calls, isEmpty);
      expect(h.bridge.progressListeners, 0);
      expect(h.timers.active, 0);
    });

    for (final String code in <String>[DemoBridgeErrorCode.fatal, DemoBridgeErrorCode.fenced]) {
      test('мост отклонил запрос кодом $code → connectionError', () async {
        final _Harness h = _Harness();
        final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/me'));
        await settle();
        h.bridge.calls.single.fail(DemoBridgeException(code, 'Сервер демо остановлен'));
        await settle();

        expect(p.dioError.type, DioExceptionType.connectionError);
        expect(p.dioError.error, isA<DemoBridgeException>().having((x) => x.code, 'code', code));
      });
    }
  });

  group('отмена', () {
    test('CancelToken во время выполнения → cancel(id) моста и DioException отмены', () async {
      final _Harness h = _Harness();
      final CancelToken token = CancelToken();
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(
        h.dio.get<Object?>('/search/products', queryParameters: <String, Object?>{'q': 'кран'}, cancelToken: token),
      );
      await settle();
      final FakeBridgeCall call = h.bridge.calls.single..start();

      token.cancel('новый ввод');
      await settle();

      expect(p.dioError.type, DioExceptionType.cancel);
      expect(h.bridge.cancelled, <String>[call.id]);
      expect(h.timers.active, 0);
    });

    test('отмена до готовности воркера — без обращения к мосту', () async {
      final _Harness h = _Harness(ready: false);
      final CancelToken token = CancelToken();
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/me', cancelToken: token));
      await settle();

      token.cancel();
      await settle();
      h.bridge.becomeReady();
      await settle();

      expect(p.dioError.type, DioExceptionType.cancel);
      expect(h.bridge.calls, isEmpty);
      expect(h.bridge.cancelled, isEmpty);
      expect(h.bridge.progressListeners, 0);
      expect(h.timers.active, 0);
    });

    test('cancelFuture адаптера (long-poll) → requestCancelled и cancel(id)', () async {
      final _Harness h = _Harness();
      final Completer<void> cancel = Completer<void>();
      final RequestOptions options = RequestOptions(
        baseUrl: '$demoTestOrigin/api/v1',
        path: '/payments/pay-1',
        queryParameters: <String, Object?>{'wait': 25},
      );
      final _Pending<ResponseBody> p = _Pending<ResponseBody>(h.adapter.fetch(options, null, cancel.future));
      await settle();
      h.bridge.calls.single.start();

      cancel.complete();
      await settle();

      expect(p.dioError.type, DioExceptionType.cancel);
      expect(h.bridge.cancelled, <String>[h.bridge.calls.single.id]);
    });

    test('close(force: true) отменяет запросы в полёте; close() адаптер не выключает', () async {
      final _Harness h = _Harness();
      final _Pending<Response<Object?>> first = _Pending<Response<Object?>>(h.dio.get<Object?>('/me'));
      await settle();

      h.adapter.close();
      await settle();
      expect(first.done, isFalse);

      h.adapter.close(force: true);
      await settle();
      expect(first.dioError.type, DioExceptionType.cancel);

      h.bridge.handler = (FakeBridgeCall c) => bridgeJson(200, <String, Object?>{'ok': true});
      final Response<Object?> again = await h.dio.get<Object?>('/me');
      expect(again.data, <String, Object?>{'ok': true});
    });
  });

  group('таймауты: от готовности воркера и начала выполнения, а не от постановки в очередь', () {
    test('холодный старт: запрос ждёт ready, пока идёт progress, дольше 5 с соединения — и выполняется', () async {
      final _Harness h = _Harness(ready: false);
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/me'));

      for (var i = 0; i < 5; i++) {
        await h.timers.elapse(const Duration(seconds: 20));
        h.bridge.progress();
      }
      expect(p.done, isFalse);
      expect(h.bridge.calls, isEmpty);

      h.bridge.becomeReady();
      await settle();
      final FakeBridgeCall call = h.bridge.calls.single;
      // connectTimeout (5 с) — от готовности: 4 с после ready ещё не таймаут.
      await h.timers.elapse(const Duration(seconds: 4));
      expect(p.done, isFalse);
      call
        ..start()
        ..respond(bridgeJson(200, <String, Object?>{'id': 'u-1'}));
      await settle();

      expect(p.value?.data, <String, Object?>{'id': 'u-1'});
      expect(h.bridge.progressListeners, 0);
    });

    test('холодный старт без progress (как в demoOverrides): запрос ждёт ready без предела — не «нет сети»', () async {
      // Медленный старт показывает страница (90 с — «Запуск занимает больше обычного»); отказ по таймеру оставил бы
      // после ready офлайн-статус и закэшированный «Сервер недоступен» (ревью DB-2).
      final _Harness h = _Harness(ready: false);
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/me'));

      await h.timers.elapse(const Duration(minutes: 10));
      expect(p.done, isFalse);
      expect(h.bridge.calls, isEmpty);
      expect(h.bridge.progressListeners, 0);

      h.bridge.becomeReady();
      await settle();
      h.bridge.calls.single
        ..start()
        ..respond(bridgeJson(200, <String, Object?>{'id': 'u-1'}));
      await settle();
      expect(p.value?.data, <String, Object?>{'id': 'u-1'});
    });

    test('холодный старт без progress: fatal воркера → connectionError, в мост не ушёл', () async {
      final _Harness h = _Harness(ready: false);
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/me'));

      await h.timers.elapse(const Duration(minutes: 3));
      h.bridge.failReady(DemoBridgeErrorCode.fatal, 'База демо не открылась');
      await settle();

      expect(p.dioError.type, DioExceptionType.connectionError);
      expect(h.bridge.calls, isEmpty);
    });

    test('заданный readyStallTimeout без progress → receiveTimeout («сервер недоступен»), в мост не ушёл', () async {
      final _Harness h = _Harness(ready: false, readyStallTimeout: const Duration(seconds: 180));
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/me'));

      await h.timers.elapse(const Duration(seconds: 120));
      h.bridge.progress();
      await h.timers.elapse(const Duration(seconds: 179));
      expect(p.done, isFalse);
      await h.timers.elapse(const Duration(seconds: 2));

      expect(p.dioError.type, DioExceptionType.receiveTimeout);
      expect(OnlineStatusInterceptor.outcomeOf(p.dioError), RequestOutcome.serverUnavailable);
      expect(h.bridge.calls, isEmpty);
      expect(h.bridge.progressListeners, 0);
    });

    test('воркер готов, но не начал запрос за connectTimeout → connectionTimeout, запрос снят в воркере', () async {
      final _Harness h = _Harness();
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/me'));

      await h.timers.elapse(const Duration(milliseconds: 4900));
      expect(p.done, isFalse);
      await h.timers.elapse(const Duration(milliseconds: 200));

      expect(p.dioError.type, DioExceptionType.connectionTimeout);
      expect(h.bridge.cancelled, <String>[h.bridge.calls.single.id]);
    });

    test('занятый воркер: пока соседние запросы продвигаются, таймаут соединения не наступает', () async {
      final _Harness h = _Harness();
      final _Pending<Response<Object?>> a = _Pending<Response<Object?>>(h.dio.get<Object?>('/catalog/sync/products'));
      final _Pending<Response<Object?>> b = _Pending<Response<Object?>>(h.dio.get<Object?>('/me'));
      await settle();
      final FakeBridgeCall callA = h.bridge.calls[0]..start();
      final FakeBridgeCall callB = h.bridge.calls[1];

      await h.timers.elapse(const Duration(seconds: 4));
      callA.respond(bridgeJson(200, <String, Object?>{'items': <Object?>[]}));
      await h.timers.elapse(const Duration(seconds: 4)); // 8 с от передачи B, но 4 с от ответа A
      expect(b.done, isFalse);
      callB
        ..start()
        ..respond(bridgeJson(200, <String, Object?>{'id': 'u-1'}));
      await settle();

      expect(a.value?.statusCode, 200);
      expect(b.value?.statusCode, 200);
      expect(h.bridge.cancelled, isEmpty);
    });

    test('receiveTimeout (15 с) — от начала выполнения: 4 с в очереди + 14 с выполнения — не таймаут', () async {
      final _Harness h = _Harness();
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/orders'));
      await h.timers.elapse(const Duration(seconds: 4));
      final FakeBridgeCall call = h.bridge.calls.single..start();

      await h.timers.elapse(const Duration(seconds: 14));
      expect(p.done, isFalse);
      call.respond(bridgeJson(200, <String, Object?>{'items': <Object?>[]}));
      await settle();

      expect(p.value?.statusCode, 200);
    });

    test('начатый запрос без ответа за receiveTimeout → receiveTimeout, запрос снят в воркере', () async {
      final _Harness h = _Harness();
      final _Pending<Response<Object?>> p = _Pending<Response<Object?>>(h.dio.get<Object?>('/orders'));
      await settle();
      final FakeBridgeCall call = h.bridge.calls.single..start();

      await h.timers.elapse(const Duration(milliseconds: 14900));
      expect(p.done, isFalse);
      await h.timers.elapse(const Duration(milliseconds: 200));

      expect(p.dioError.type, DioExceptionType.receiveTimeout);
      expect(OnlineStatusInterceptor.outcomeOf(p.dioError), isNotNull);
      expect(h.bridge.cancelled, <String>[call.id]);
    });

    test('POST /orders: ApiTimeouts.orderCreate (30 с), а не 15 с', () async {
      final _Harness h = _Harness();
      Options order() => apiOptions(idempotencyKey: 'ord-1', receiveTimeout: ApiTimeouts.orderCreate);

      final _Pending<Response<Object?>> ok = _Pending<Response<Object?>>(
        h.dio.post<Object?>('/orders', options: order()),
      );
      await settle();
      final FakeBridgeCall first = h.bridge.calls.single..start();
      await h.timers.elapse(const Duration(seconds: 25));
      expect(ok.done, isFalse);
      first.respond(bridgeJson(201, <String, Object?>{'id': 'o-1'}));
      await settle();
      expect(ok.value?.statusCode, 201);

      final _Pending<Response<Object?>> slow = _Pending<Response<Object?>>(
        h.dio.post<Object?>('/orders', options: order()),
      );
      await settle();
      h.bridge.calls.last.start();
      await h.timers.elapse(const Duration(milliseconds: 29900));
      expect(slow.done, isFalse);
      await h.timers.elapse(const Duration(milliseconds: 200));
      expect(slow.dioError.type, DioExceptionType.receiveTimeout);
    });

    test(
      'long-poll GET /payments/{id}?wait=25: ApiTimeouts.longPoll (wait + 10 с); таймаут не меняет статус сети',
      () async {
        final _Harness h = _Harness();
        Future<Response<Object?>> poll() => h.dio.get<Object?>(
          '/payments/pay-1',
          queryParameters: <String, Object?>{'wait': 25},
          options: apiOptions(
            longPoll: true,
            retry: RetryProfile.none,
            receiveTimeout: ApiTimeouts.longPoll(const Duration(seconds: 25)),
          ),
        );

        final _Pending<Response<Object?>> ok = _Pending<Response<Object?>>(poll());
        await settle();
        expect(h.bridge.calls.single.url, '/api/v1/payments/pay-1?wait=25');
        h.bridge.calls.single.start();
        await h.timers.elapse(const Duration(seconds: 34));
        expect(ok.done, isFalse);
        h.bridge.calls.single.respond(bridgeJson(200, <String, Object?>{'status': 'pending'}));
        await settle();
        expect(ok.value?.statusCode, 200);

        final _Pending<Response<Object?>> tooLate = _Pending<Response<Object?>>(poll());
        await settle();
        h.bridge.calls.last.start();
        await h.timers.elapse(const Duration(milliseconds: 34900));
        expect(tooLate.done, isFalse);
        await h.timers.elapse(const Duration(milliseconds: 200));
        expect(tooLate.dioError.type, DioExceptionType.receiveTimeout);
        expect(tooLate.dioError.requestOptions.isLongPoll, isTrue);
        expect(OnlineStatusInterceptor.outcomeOf(tooLate.dioError), isNull);
        expect(h.bridge.cancelled, <String>[h.bridge.calls.last.id]);
      },
    );
  });
}

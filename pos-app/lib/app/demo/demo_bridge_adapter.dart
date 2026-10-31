// Транспорт Dio веб-демо: запросы API уходят не в сеть, а в сервер в Web Worker страницы (15 ADR-113 п. 2;
// 06 §6.10). Адаптер получают и основной Dio, и Dio для `POST /auth/refresh` (core/network/dio_client.dart), а также
// проверка `/health` (demo_health_probe.dart) — один экземпляр на приложение (demo_overrides.dart).
//
// Правила:
// 1. Защита хоста. Только тот же origin и пути `/api/v1/**` и `/health`; иначе `connectionError` без вызова моста.
//    В сеть адаптер не ходит никогда: запасного сетевого транспорта у него нет.
// 2. «Нет сети (имитация)» демо-панели — `connectionError` (и до, и во время запроса).
// 3. Тело запроса копируется в собственный буфер точной длины до передачи мосту: передаваемый воркеру `ArrayBuffer`
//    не отсоединяет буфер Dart.
// 4. Ответ — статус, заголовки и байты без преобразований: JSON, problem+json, PDF, 204 и 304 разбирает сам Dio.
// 5. Отмена Dio → `cancel(id)` моста (ещё не начатый запрос снимается из очереди воркера) и `DioException` отмены.
// 6. Таймауты Dio (06 §6.7, core/network/api_headers.dart) реализует адаптер, отсчёт — не от постановки в очередь:
//    - пока воркер не прислал `ready` (холодный старт: PGlite, снимок, сид), запрос ждёт готовности, а не падает
//      через 5 с. По умолчанию (веб-демо) — без предела: ожидание кончается `ready` или `fatal` (`connectionError`).
//      Медленный и неудачный старт показывает сама страница (через 90 с — «Запуск занимает больше обычного» и
//      «Сбросить демо», по `fatal` — экран ошибки), пока экран загрузки закрывает приложение; ответ «нет сети»
//      по таймеру оставил бы после `ready` офлайн-статус и закэшированный «Сервер недоступен». Если задан
//      [DemoBridgeAdapter.readyStallTimeout], ожидание без `progress` дольше него — `receiveTimeout` («сервер
//      недоступен»), а не `connectionTimeout` («нет сети»);
//    - `connectTimeout` — от готовности воркера (или от вызова, если он уже готов) до начала выполнения запроса в
//      воркере (`onStart`). Пока воркер продвигает соседние запросы этого адаптера (начал или ответил), отсчёт
//      начинается заново: «занят» не значит «недоступен»;
//    - `receiveTimeout` запроса (по умолчанию 15 с; `POST /orders` — `ApiTimeouts.orderCreate` 30 с; long-poll
//      `GET /payments/{id}?wait=N` — `ApiTimeouts.longPoll` N + 10 с; PDF — 60 с) — от начала выполнения до ответа;
//    - `sendTimeout` — чтение тела запроса из потока Dio.
//    По таймауту адаптер отменяет запрос в воркере.
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/app/demo/demo_bridge.dart';

/// Таймер (в тестах — ручное время).
typedef DemoTimerFactory = Timer Function(Duration duration, void Function() callback);

final Logger _log = Logger('demo.bridge');

/// [HttpClientAdapter] поверх [DemoBridge].
final class DemoBridgeAdapter implements HttpClientAdapter {
  DemoBridgeAdapter(this._bridge, {String? origin, DemoTimerFactory timer = Timer.new, this.readyStallTimeout})
    : origin = origin ?? _bridge.origin,
      _timer = timer;

  /// Origin сайта демо (`https://host[:port]`).
  final String origin;

  /// Предел ожидания `ready` без `progress` воркера; превышение — `receiveTimeout`. `null` (по умолчанию, так в
  /// `demoOverrides`) — ждать `ready` или `fatal` без предела: медленный старт показывает страница.
  final Duration? readyStallTimeout;

  final DemoBridge _bridge;
  final DemoTimerFactory _timer;
  final Set<_BridgeCall> _calls = <_BridgeCall>{};

  /// Id запросов уникальны в пределах страницы: мост держит общий список ожидающих.
  static int _seq = 0;

  /// Путь с query для моста; `null` — запрос не к серверу демо (чужой origin, путь вне `/api/v1/**` и `/health`).
  String? bridgeUrlOf(Uri uri) {
    if (!(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    if (uri.origin != origin) return null;
    final String path = uri.path;
    if (path.contains(r'\') || path.toLowerCase().contains('%5c')) return null;
    if (uri.pathSegments.any((String s) => s == '.' || s == '..')) return null;
    if (!(path == '/health' || path == '/api/v1' || path.startsWith('/api/v1/'))) return null;
    return uri.hasQuery ? '$path?${uri.query}' : path;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Uri uri;
    try {
      uri = options.uri;
    } on FormatException catch (e) {
      throw _connectionError(options, 'адрес запроса не разобран', e);
    }
    final String? url = bridgeUrlOf(uri);
    if (url == null) {
      _log.warning('демо: запрос вне сервера демо не отправлен (${uri.scheme}://${uri.host}${uri.path})');
      throw _connectionError(options, 'в веб-демо запросы идут только к серверу демо ($origin/api/v1, /health)');
    }
    if (_bridge.offline) throw _offlineError(options);
    final Uint8List? body = requestStream == null ? null : await _readBody(requestStream, options);
    final _BridgeCall call = _BridgeCall(this, options, 'dio-${++_seq}', url, body);
    return call.run(cancelFuture);
  }

  /// Тело запроса — в собственный буфер точной длины (не представление буфера Dart-запроса).
  static Future<Uint8List> _readBody(Stream<Uint8List> stream, RequestOptions options) async {
    final List<Uint8List> chunks = <Uint8List>[];
    Future<void> read = stream.forEach(chunks.add);
    final Duration? send = options.sendTimeout;
    if (send != null && send > Duration.zero) {
      read = read.timeout(
        send,
        onTimeout: () => throw DioException.sendTimeout(timeout: send, requestOptions: options),
      );
    }
    await read;
    var length = 0;
    for (final Uint8List chunk in chunks) {
      length += chunk.length;
    }
    final Uint8List copy = Uint8List(length);
    var offset = 0;
    for (final Uint8List chunk in chunks) {
      copy.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return copy;
  }

  /// Воркер продвинул запрос [source] (начал выполнение или ответил): ожидающие начала отсчитывают соединение заново.
  void _workerProgressed(_BridgeCall source) {
    for (final _BridgeCall call in _calls.toList()) {
      if (!identical(call, source)) call.restartConnectTimer();
    }
  }

  /// `force: true` — отменить запросы в полёте. Иначе адаптер остаётся рабочим: один экземпляр делят несколько Dio
  /// (основной, refresh, `/health`), и `Dio.close()` при пересоздании провайдера не должен его выключать.
  @override
  void close({bool force = false}) {
    if (!force) return;
    for (final _BridgeCall call in _calls.toList()) {
      call.cancel('адаптер закрыт');
    }
  }

  static DioException _connectionError(RequestOptions options, String reason, [Object? error]) =>
      DioException.connectionError(requestOptions: options, reason: reason, error: error);

  static DioException _offlineError(RequestOptions options) => _connectionError(
    options,
    'нет сети (имитация в демо-панели)',
    const DemoBridgeException(DemoBridgeErrorCode.offline, 'нет сети (имитация в демо-панели)'),
  );
}

/// Один запрос: ожидание готовности воркера → передача мосту → начало выполнения → ответ.
final class _BridgeCall {
  _BridgeCall(this._adapter, this._options, this._id, this._url, this._body);

  final DemoBridgeAdapter _adapter;
  final RequestOptions _options;
  final String _id;
  final String _url;
  final Uint8List? _body;
  final Completer<ResponseBody> _done = Completer<ResponseBody>();

  Timer? _timer;
  void Function()? _unsubscribeProgress;
  bool _sent = false;
  bool _started = false;

  DemoBridge get _bridge => _adapter._bridge;

  Future<ResponseBody> run(Future<void>? cancelFuture) {
    _adapter._calls.add(this);
    if (cancelFuture != null) {
      unawaited(cancelFuture.then<void>((_) => cancel('запрос отменён'), onError: (Object _, StackTrace _) {}));
    }
    if (_bridge.isReady) {
      _send();
    } else {
      _waitReady();
    }
    return _done.future;
  }

  void _waitReady() {
    if (_adapter.readyStallTimeout != null) {
      _unsubscribeProgress = _bridge.onProgress(_armStallTimer);
      _armStallTimer();
    }
    unawaited(
      _bridge.whenReady().then<void>(
        (_) {
          if (_done.isCompleted) return;
          _stopWaitingReady();
          _send();
        },
        onError: (Object error, StackTrace _) {
          if (_done.isCompleted) return;
          _fail(DemoBridgeAdapter._connectionError(_options, 'сервер демо не запустился', error));
        },
      ),
    );
  }

  void _armStallTimer() {
    final Duration? stall = _adapter.readyStallTimeout;
    if (stall == null || _done.isCompleted || _sent) return;
    _timer?.cancel();
    _timer = _adapter._timer(stall, () {
      if (_done.isCompleted || _sent) return;
      _log.warning('демо: сервер демо не готов и не присылал прогресс ${stall.inSeconds} с');
      // «Сервер недоступен», а не «нет сети»: связь с воркером есть, он не запустился.
      _fail(
        DioException.receiveTimeout(
          timeout: stall,
          requestOptions: _options,
          error: const DemoBridgeException(DemoBridgeErrorCode.unknown, 'сервер демо не запустился'),
        ),
      );
    });
  }

  void _stopWaitingReady() {
    _unsubscribeProgress?.call();
    _unsubscribeProgress = null;
    _timer?.cancel();
    _timer = null;
  }

  void _send() {
    if (_bridge.offline) {
      _fail(DemoBridgeAdapter._offlineError(_options));
      return;
    }
    _sent = true;
    restartConnectTimer();
    final Future<DemoBridgeResponse> response;
    try {
      response = _bridge.request(
        DemoBridgeRequest(
          id: _id,
          method: _options.method.toUpperCase(),
          url: _url,
          headers: _headerPairs(_options.headers),
          body: _body,
          onStart: _onStart,
        ),
      );
    } on Object catch (error) {
      _onBridgeError(error);
      return;
    }
    unawaited(response.then<void>(_onResponse, onError: (Object error, StackTrace _) => _onBridgeError(error)));
  }

  /// Отсчёт `connectTimeout` с начала: запрос передан мосту, но воркер его ещё не начал.
  void restartConnectTimer() {
    if (!_sent || _started || _done.isCompleted) return;
    _timer?.cancel();
    _timer = null;
    final Duration? connect = _options.connectTimeout;
    if (connect == null || connect <= Duration.zero) return;
    _timer = _adapter._timer(connect, () {
      if (_started || _done.isCompleted) return;
      _log.warning('демо: воркер не начал ${_options.method} ${_options.uri.path} за ${connect.inMilliseconds} мс');
      _timeout(DioException.connectionTimeout(timeout: connect, requestOptions: _options));
    });
  }

  void _onStart() {
    if (_started || _done.isCompleted) return;
    _started = true;
    _timer?.cancel();
    _timer = null;
    final Duration? receive = _options.receiveTimeout;
    if (receive != null && receive > Duration.zero) {
      _timer = _adapter._timer(receive, () {
        if (_done.isCompleted) return;
        _timeout(DioException.receiveTimeout(timeout: receive, requestOptions: _options));
      });
    }
    _adapter._workerProgressed(this);
  }

  void _onResponse(DemoBridgeResponse response) {
    if (_done.isCompleted) return;
    final Map<String, List<String>> headers = <String, List<String>>{};
    for (final (String name, String value) in response.headers) {
      (headers[name.toLowerCase()] ??= <String>[]).add(value);
    }
    _finish();
    _done.complete(ResponseBody(Stream<Uint8List>.value(response.body), response.status, headers: headers));
    _adapter._workerProgressed(this);
  }

  void _onBridgeError(Object error) {
    if (_done.isCompleted) return;
    if (error is DemoBridgeException) {
      switch (error.code) {
        case DemoBridgeErrorCode.offline:
          _fail(DemoBridgeAdapter._offlineError(_options));
        case DemoBridgeErrorCode.cancelled:
          _fail(DioException.requestCancelled(requestOptions: _options, reason: error));
        default:
          _fail(DemoBridgeAdapter._connectionError(_options, 'сервер демо недоступен (${error.code})', error));
      }
      return;
    }
    _fail(DioException(requestOptions: _options, error: error, message: 'мост веб-демо: неизвестная ошибка'));
  }

  /// Таймаут: запрос отменяется и в воркере.
  void _timeout(DioException error) {
    if (_done.isCompleted) return;
    if (_sent) _bridge.cancel(_id);
    _fail(error);
  }

  void cancel(String reason) {
    if (_done.isCompleted) return;
    if (_sent) _bridge.cancel(_id);
    _fail(DioException.requestCancelled(requestOptions: _options, reason: reason));
  }

  void _fail(DioException error) {
    if (_done.isCompleted) return;
    _finish();
    _done.completeError(error, StackTrace.current);
  }

  void _finish() {
    _stopWaitingReady();
    _adapter._calls.remove(this);
  }

  /// Заголовки Dio → пары; список значений — отдельными парами, `null` пропускается.
  static List<(String, String)> _headerPairs(Map<String, dynamic> headers) {
    final List<(String, String)> pairs = <(String, String)>[];
    headers.forEach((String name, Object? value) {
      if (value == null) return;
      if (value is Iterable<Object?>) {
        for (final Object? item in value) {
          if (item != null) pairs.add((name, '$item'));
        }
      } else {
        pairs.add((name, '$value'));
      }
    });
    return pairs;
  }
}

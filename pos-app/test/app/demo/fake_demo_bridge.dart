// Фейковый мост веб-демо и ручное время для VM-тестов (12 T-DEMO-001, T-DEMO-012; 15 ADR-113 п. 2).
// Повторяет поведение demo/web/site-src/demo-bridge.js: `request` → промис ответа, `onStart` — начало выполнения в
// воркере, `cancel(id)` отклоняет промис кодом `cancelled`. Синтетические данные, без сети.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:optomstroy/app/demo/demo_bridge.dart';

/// Origin синтетического сайта демо (зарезервированный домен `.test`).
const String demoTestOrigin = 'https://optomstroy-demo.test';

/// Ответ моста с JSON-телом.
DemoBridgeResponse bridgeJson(
  int status,
  Object? body, {
  String contentType = 'application/json; charset=utf-8',
  List<(String, String)> headers = const <(String, String)>[],
}) => DemoBridgeResponse(
  status: status,
  headers: <(String, String)>[('content-type', contentType), ...headers],
  body: body == null ? Uint8List(0) : Uint8List.fromList(utf8.encode(jsonEncode(body))),
);

/// Один запрос к фейковому мосту.
final class FakeBridgeCall {
  FakeBridgeCall(this.request);

  final DemoBridgeRequest request;
  final Completer<DemoBridgeResponse> _response = Completer<DemoBridgeResponse>();
  bool started = false;

  String get id => request.id;
  String get url => request.url;
  bool get isDone => _response.isCompleted;
  Future<DemoBridgeResponse> get future => _response.future;

  /// Заголовок запроса без учёта регистра имени.
  String? header(String name) {
    for (final (String k, String v) in request.headers) {
      if (k.toLowerCase() == name.toLowerCase()) return v;
    }
    return null;
  }

  /// Тело запроса как JSON.
  Object? get jsonBody => request.body == null ? null : jsonDecode(utf8.decode(request.body!));

  /// Воркер начал выполнение (`http:start`).
  void start() {
    if (started) return;
    started = true;
    request.onStart?.call();
  }

  void respond(DemoBridgeResponse response) {
    if (!isDone) _response.complete(response);
  }

  void fail(Object error) {
    if (!isDone) _response.completeError(error);
  }
}

/// Фейк `globalThis.__posDemo`.
final class FakeDemoBridge implements DemoBridge {
  FakeDemoBridge({this.origin = demoTestOrigin, bool ready = true, this.handler, this.protocol = demoBridgeProtocol})
    : _isReady = ready {
    if (ready) _ready.complete();
  }

  @override
  final String origin;

  @override
  final int? protocol;

  /// Автоответ: запрос сразу «начинается» и получает ответ; `null` — тест ведёт запрос вручную.
  FutureOr<DemoBridgeResponse> Function(FakeBridgeCall call)? handler;

  final Completer<void> _ready = Completer<void>();
  final List<void Function()> _progress = <void Function()>[];
  bool _isReady;

  @override
  bool offline = false;

  /// Все запросы в порядке поступления.
  final List<FakeBridgeCall> calls = <FakeBridgeCall>[];

  /// Id отменённых запросов.
  final List<String> cancelled = <String>[];

  int get progressListeners => _progress.length;

  void becomeReady() {
    _isReady = true;
    if (!_ready.isCompleted) _ready.complete();
  }

  void failReady(String code, String message) {
    if (!_ready.isCompleted) _ready.completeError(DemoBridgeException(code, message));
  }

  /// Событие `progress` воркера.
  void progress() {
    for (final void Function() listener in List<void Function()>.of(_progress)) {
      listener();
    }
  }

  @override
  bool get isAvailable => true;

  @override
  bool get isReady => _isReady;

  @override
  Future<void> whenReady() => _ready.future;

  @override
  void Function() onProgress(void Function() listener) {
    _progress.add(listener);
    return () => _progress.remove(listener);
  }

  @override
  Future<DemoBridgeResponse> request(DemoBridgeRequest request) {
    final FakeBridgeCall call = FakeBridgeCall(request);
    calls.add(call);
    final FutureOr<DemoBridgeResponse> Function(FakeBridgeCall call)? auto = handler;
    if (auto != null) {
      call.start();
      unawaited(Future<DemoBridgeResponse>.sync(() => auto(call)).then(call.respond, onError: call.fail));
    }
    return call.future;
  }

  @override
  void cancel(String id) {
    cancelled.add(id);
    for (final FakeBridgeCall call in calls) {
      if (call.id == id) call.fail(const DemoBridgeException(DemoBridgeErrorCode.cancelled, 'Запрос отменён'));
    }
  }
}

/// Ручное время для `DemoTimerFactory`: таймеры срабатывают только в [elapse].
final class ManualTimers {
  Duration now = Duration.zero;
  final List<_ManualTimer> _timers = <_ManualTimer>[];

  Timer create(Duration duration, void Function() callback) {
    final _ManualTimer timer = _ManualTimer(now + duration, callback);
    _timers.add(timer);
    return timer;
  }

  int get active => _timers.where((_ManualTimer t) => t.isActive).length;

  /// Сдвинуть время на [duration], выполняя наступившие таймеры по порядку.
  Future<void> elapse(Duration duration) async {
    final Duration target = now + duration;
    await settle();
    while (true) {
      final List<_ManualTimer> due = _timers.where((_ManualTimer t) => t.isActive && t.at <= target).toList()
        ..sort((_ManualTimer a, _ManualTimer b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      now = due.first.at;
      due.first.fire();
      await settle();
    }
    now = target;
    await settle();
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this.at, this._callback);

  final Duration at;
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick = 1;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}

/// Дать отработать микрозадачам и событиям нулевой задержки (цепочка интерсепторов Dio).
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

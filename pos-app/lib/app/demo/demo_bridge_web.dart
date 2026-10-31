// Мост веб-демо в браузере: `dart:js_interop` к `globalThis.__posDemo` (demo/web/site-src/demo-bridge.js,
// протокол 1; 15 ADR-113 п. 2). Новых пакетов нет — только SDK.
//
// Промисы моста разбираются через `then(onFulfilled, onRejected)` с Dart-колбэками: причина отказа приходит как
// `JSAny?`, и поле `code` читается одинаково в dart2js и dart2wasm.
// Тело запроса уже скопировано адаптером в собственный буфер; мост копирует его ещё раз перед transfer, поэтому
// буфер Dart не отсоединяется.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:optomstroy/app/demo/demo_bridge.dart';

/// Реализация для браузера.
DemoBridge createPlatformDemoBridge() => JsDemoBridge();

@JS('__posDemo')
external _PosDemo? get _posDemoGlobal;

@JS('__posShowStartError')
external JSAny? get _showStartErrorHook;

/// Ошибка запуска → `globalThis.__posShowStartError(message)` (web/flutter_bootstrap.js): текст на экране загрузки.
void reportPlatformStartError(String message) {
  final JSAny? hook = _showStartErrorHook;
  if (hook != null && hook.isA<JSFunction>()) (hook as JSFunction).callAsFunction(null, message.toJS);
}

extension type _PosDemo._(JSObject _) implements JSObject {
  external JSNumber? get protocol;
  external JSObject? get ready;
  external JSBoolean? get isReady;
  external JSBoolean? get offline;
  external JSObject request(_JsRequest request);
  external JSAny? cancel(JSString id);
  external JSFunction? on(JSString type, JSFunction listener);
}

extension type _Thenable._(JSObject _) implements JSObject {
  external JSAny? then(JSFunction onFulfilled, JSFunction onRejected);
}

extension type _JsRequest._(JSObject _) implements JSObject {
  external factory _JsRequest({
    JSString id,
    JSString method,
    JSString url,
    JSArray<JSArray<JSString>> headers,
    JSUint8Array? body,
    JSFunction? onStart,
  });
}

extension type _JsResponse._(JSObject _) implements JSObject {
  external JSNumber? get status;
  external JSArray<JSArray<JSString>>? get headers;
  external JSUint8Array? get body;
}

extension type _JsError._(JSObject _) implements JSObject {
  external JSAny? get code;
  external JSAny? get message;
}

/// `globalThis.__posDemo`.
final class JsDemoBridge implements DemoBridge {
  Future<void>? _ready;

  _PosDemo get _api {
    final _PosDemo? api = _posDemoGlobal;
    if (api == null) throw StateError('нет моста веб-демо globalThis.__posDemo');
    return api;
  }

  @override
  bool get isAvailable => _posDemoGlobal != null;

  @override
  int? get protocol => _posDemoGlobal?.protocol?.toDartInt;

  @override
  String get origin => Uri.base.origin;

  @override
  bool get isReady => _posDemoGlobal?.isReady?.toDart ?? false;

  @override
  bool get offline => _posDemoGlobal?.offline?.toDart ?? false;

  @override
  Future<void> whenReady() => _ready ??= _awaitReady();

  Future<void> _awaitReady() async {
    final JSObject? promise = _api.ready;
    if (promise == null) throw const DemoBridgeException(DemoBridgeErrorCode.unknown, '__posDemo.ready отсутствует');
    await _settle(promise);
  }

  @override
  void Function() onProgress(void Function() listener) {
    final JSFunction? unsubscribe = _api.on('progress'.toJS, ((JSAny? _) => listener()).toJS);
    return () => unsubscribe?.callAsFunction();
  }

  @override
  Future<DemoBridgeResponse> request(DemoBridgeRequest request) async {
    final void Function()? onStart = request.onStart;
    final JSObject promise = _api.request(
      _JsRequest(
        id: request.id.toJS,
        method: request.method.toJS,
        url: request.url.toJS,
        headers: <JSArray<JSString>>[
          for (final (String name, String value) in request.headers) <JSString>[name.toJS, value.toJS].toJS,
        ].toJS,
        body: request.body?.toJS,
        onStart: onStart?.toJS,
      ),
    );
    final JSAny? value = await _settle(promise);
    if (value == null || !value.isA<JSObject>()) {
      throw const DemoBridgeException(DemoBridgeErrorCode.unknown, 'мост вернул пустой ответ');
    }
    final _JsResponse response = value as _JsResponse;
    final List<(String, String)> headers = <(String, String)>[];
    for (final JSArray<JSString> pair in response.headers?.toDart ?? const <JSArray<JSString>>[]) {
      final List<JSString> parts = pair.toDart;
      if (parts.length >= 2) headers.add((parts[0].toDart, parts[1].toDart));
    }
    return DemoBridgeResponse(
      status: response.status?.toDartInt ?? 0,
      headers: headers,
      body: response.body?.toDart ?? Uint8List(0),
    );
  }

  @override
  void cancel(String id) => _posDemoGlobal?.cancel(id.toJS);

  /// Итог промиса моста; отказ — [DemoBridgeException] с `code` и `message` из `Error` моста.
  static Future<JSAny?> _settle(JSObject promise) {
    final Completer<JSAny?> done = Completer<JSAny?>();
    // Сигнатуры колбэков — только JS-типы (требование `toJS`), поэтому не tear-off `done.complete`.
    void fulfilled(JSAny? value) => done.complete(value);
    void rejected(JSAny? reason) => done.completeError(_exception(reason));
    (promise as _Thenable).then(fulfilled.toJS, rejected.toJS);
    return done.future;
  }

  static DemoBridgeException _exception(JSAny? reason) {
    if (reason != null && reason.isA<JSObject>()) {
      final _JsError error = reason as _JsError;
      final JSAny? code = error.code;
      final JSAny? message = error.message;
      return DemoBridgeException(
        code != null && code.isA<JSString>() ? (code as JSString).toDart : DemoBridgeErrorCode.unknown,
        message != null && message.isA<JSString>() ? (message as JSString).toDart : 'ошибка моста',
      );
    }
    if (reason != null && reason.isA<JSString>()) {
      return DemoBridgeException(DemoBridgeErrorCode.unknown, (reason as JSString).toDart);
    }
    return const DemoBridgeException(DemoBridgeErrorCode.unknown, 'мост отклонил запрос без причины');
  }
}

// Шлюз passkey веб-демо в браузере: `dart:js_interop` к `globalThis.__posPasskey` (demo/web/site-src/demo-passkey.js,
// протокол 1; 15 ADR-116 п. 1, п. 4). Новых пакетов нет — только SDK (по образцу demo_bridge_web.dart).
//
// Вызываются только методы протокола ([DemoPasskeyMethod.all]); аргументы — простой объект (`jsify`), ответ — простой
// объект (`dartify`). Промис разбирается через `then(onFulfilled, onRejected)` с Dart-колбэками, как у моста: отказ
// (страница так не делает — её методы не бросают) и исключение вызова дают `failed`. Значения не журналируются.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:optomstroy/app/demo/demo_passkey_gateway.dart';

/// Реализация для браузера.
DemoPasskeyGateway createPlatformDemoPasskeyGateway() => const JsDemoPasskeyGateway();

@JS('__posPasskey')
external JSAny? get _posPasskeyGlobal;

extension type _Thenable._(JSObject _) implements JSObject {
  external JSAny? then(JSFunction onFulfilled, JSFunction onRejected);
}

/// `globalThis.__posPasskey`.
final class JsDemoPasskeyGateway implements DemoPasskeyGateway {
  const JsDemoPasskeyGateway();

  static JSObject? get _api {
    final JSAny? api = _posPasskeyGlobal;
    return api != null && api.isA<JSObject>() ? api as JSObject : null;
  }

  @override
  bool get isAvailable => _api != null;

  @override
  int? get protocol {
    final JSObject? api = _api;
    if (api == null) return null;
    final JSAny? raw = api['protocol'];
    if (raw == null || !raw.isA<JSNumber>()) return null;
    try {
      return (raw as JSNumber).toDartInt;
    } on Object {
      // Не целое число — не номер протокола.
      return null;
    }
  }

  @override
  Future<Map<String, Object?>> invoke(String method, [Map<String, Object?> args = const <String, Object?>{}]) async {
    final JSObject? api = _api;
    if (api == null || !DemoPasskeyMethod.all.contains(method)) return demoPasskeyNotAvailable;
    final JSAny? fn = api[method];
    if (fn == null || !fn.isA<JSFunction>()) return demoPasskeyNotAvailable;
    try {
      final JSAny? returned = (fn as JSFunction).callAsFunction(api, args.jsify());
      return _plain((await _settle(returned)).dartify());
    } on Object {
      return demoPasskeyFailed;
    }
  }

  /// Итог промиса (или само значение, если страница вернула не промис); отказ — исключение (→ `failed`).
  static Future<JSAny?> _settle(JSAny? value) {
    if (value == null || !value.isA<JSObject>()) return Future<JSAny?>.value(value);
    final JSAny? then = (value as JSObject)['then'];
    if (then == null || !then.isA<JSFunction>()) return Future<JSAny?>.value(value);
    final Completer<JSAny?> done = Completer<JSAny?>();
    // Сигнатуры колбэков — только JS-типы (требование `toJS`), поэтому не tear-off `done.complete`.
    void fulfilled(JSAny? result) => done.complete(result);
    void rejected(JSAny? reason) => done.completeError(StateError('__posPasskey: промис отклонён'));
    (value as _Thenable).then(fulfilled.toJS, rejected.toJS);
    return done.future;
  }

  /// Ответ страницы → словарь со строковыми ключами; не объект — `failed`.
  static Map<String, Object?> _plain(Object? value) {
    if (value is! Map) return demoPasskeyFailed;
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> e in value.entries)
        if (e.key case final String key) key: e.value,
    };
  }
}

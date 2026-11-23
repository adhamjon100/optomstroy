// Dart-сторона канала `kg.optomstroy/windows_hello` (C++/WinRT в pos-app/windows/runner/hello_channel.{h,cpp};
// 15 ADR-116 п. 3; 06 §6.2, §16.1; 09 BIO-038, BIO-039). Протокол — в шапке hello_channel.h:
// - `availability` → `{availability, keysSupported}` — без диалога;
// - `createKey {name}` → `{status: ok, publicKey}` | `{status}` — диалог Windows Hello;
// - `sign {name, data}` → `{status: ok, signature}` | `{status}` — диалог Windows Hello;
// - `deleteKey {name}` → `{status: ok | failed}` — без диалога.
// Нативная сторона принимает только имена `optomstroy.hello.v1.<userId>` и только challenge входа. Канала нет (сборка
// без него, тесты без подмены) — `availability` отвечает `unknown`, остальные — [statusUnavailable]; исключений
// наружу нет. Ключи и подписи не журналируются; `toString` — без байтов.
import 'package:flutter/services.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';

/// Ответ `createKey` / `sign` / `deleteKey`: [status] канала и байты ([HelloChannelReply.bytes]) при `ok`.
final class HelloChannelReply {
  const HelloChannelReply(this.status, [this.bytes]);

  final String status;

  /// `publicKey` (SPKI DER) у `createKey`, `signature` у `sign`; иначе `null`.
  final Uint8List? bytes;

  bool get isOk => status == WindowsHelloKeyChannel.statusOk;

  @override
  String toString() => 'HelloChannelReply($status)';
}

/// Обёртка канала ключа Windows Hello.
final class WindowsHelloKeyChannel {
  WindowsHelloKeyChannel([MethodChannel? channel]) : _channel = channel ?? const MethodChannel(name);

  static const String name = 'kg.optomstroy/windows_hello';

  /// Статусы канала (`KeyCredentialStatus` и сбои; hello_channel.h).
  static const String statusOk = 'ok';
  static const String statusCancelled = 'cancelled';
  static const String statusNotFound = 'not_found';
  static const String statusUserPrefersPassword = 'user_prefers_password';
  static const String statusAlreadyExists = 'already_exists';
  static const String statusSecurityDeviceLocked = 'security_device_locked';
  static const String statusUnknownError = 'unknown_error';
  static const String statusFailed = 'failed';

  /// Только Dart: канала нет (`MissingPluginException`).
  static const String statusUnavailable = 'unavailable';

  final MethodChannel _channel;

  /// Доступность Windows Hello и поддержка ключей (без диалога).
  Future<WindowsHelloStatus> availability() async {
    try {
      final Map<Object?, Object?>? r = await _channel.invokeMapMethod<Object?, Object?>('availability');
      if (r == null) return WindowsHelloStatus.unknown;
      return WindowsHelloStatus(
        availability: WindowsHelloAvailability.parse(r['availability']),
        keysSupported: r['keysSupported'] == true,
      );
    } on MissingPluginException {
      return WindowsHelloStatus.unknown;
    } on PlatformException {
      return WindowsHelloStatus.unknown;
    }
  }

  /// Создать ключ [keyName] (диалог Windows Hello); при `ok` — открытый ключ SPKI DER.
  Future<HelloChannelReply> createKey(String keyName) =>
      _call('createKey', <String, Object?>{'name': keyName}, bytesField: 'publicKey');

  /// Подписать [data] (UTF-8 challenge входа) ключом [keyName] (диалог Windows Hello); при `ok` — подпись.
  Future<HelloChannelReply> sign(String keyName, Uint8List data) =>
      _call('sign', <String, Object?>{'name': keyName, 'data': data}, bytesField: 'signature');

  /// Удалить ключ [keyName] (без диалога).
  Future<HelloChannelReply> deleteKey(String keyName) => _call('deleteKey', <String, Object?>{'name': keyName});

  Future<HelloChannelReply> _call(String method, Map<String, Object?> arguments, {String? bytesField}) async {
    try {
      final Map<Object?, Object?>? r = await _channel.invokeMapMethod<Object?, Object?>(method, arguments);
      final Object? status = r?['status'];
      if (status is! String || status.isEmpty) return const HelloChannelReply(statusFailed);
      if (status != statusOk || bytesField == null) return HelloChannelReply(status);
      final Object? bytes = r?[bytesField];
      // `ok` без байтов — ответ не по протоколу.
      if (bytes is! Uint8List || bytes.isEmpty) return const HelloChannelReply(statusFailed);
      return HelloChannelReply(status, bytes);
    } on MissingPluginException {
      return const HelloChannelReply(statusUnavailable);
    } on PlatformException {
      return const HelloChannelReply(statusFailed);
    }
  }
}

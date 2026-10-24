// Реализация [SecureScreen] на Android через канал `kg.optomstroy/biometric_crypto` (метод `secureScreen`,
// `MainActivity` → `BiometricCryptoChannel.kt`: `FLAG_SECURE` окна). На других платформах — без действия.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/session/secure_screen.dart';

final Logger _log = Logger('auth.secure_screen');

final class ChannelSecureScreen implements SecureScreen {
  ChannelSecureScreen({MethodChannel? channel, TargetPlatform? platform})
    : _channel = channel ?? const MethodChannel(channelName),
      _platform = platform ?? defaultTargetPlatform;

  /// Канал криптопривязки биометрии (core/biometrics) — тот же `MethodChannel` в `MainActivity`.
  static const String channelName = 'kg.optomstroy/biometric_crypto';

  /// Метод канала: аргумент `enabled` (bool).
  static const String method = 'secureScreen';

  final MethodChannel _channel;
  final TargetPlatform _platform;

  @override
  Future<void> setSecure({required bool enabled}) async {
    if (kIsWeb || _platform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(method, <String, Object?>{'enabled': enabled});
    } on PlatformException catch (e) {
      _log.warning('secureScreen: ${e.code}');
    } on MissingPluginException {
      _log.warning('secureScreen: канал не зарегистрирован');
    }
  }
}

// Dart-сторона собственного platform channel криптопривязки (Android Kotlin `BiometricCryptoChannel.kt`,
// iOS Swift `BiometricCrypto` в ios/Runner/AppDelegate.swift). Протокол — словари, без исключений:
//   capability            → {kind, availability, cryptoBinding, reason?}
//   store {secret, title, subtitle?, cancel} → {ok: true} | {ok: false, error}
//   read  {title, subtitle?, cancel}         → {ok: true, value} | {ok: false, error}
//   replace {secret, title, subtitle?, cancel} → {ok: true} | {ok: false, error} — тем же ключом (AU-07)
//   has                   → bool
//   clear                 → null
// `error` ∈ cancelled | invalidated | lockout | not_enrolled | not_available | no_credential | failed.
// Секрет передаётся только по каналу в памяти процесса и не логируется ни на одной стороне.
import 'package:flutter/services.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';

/// Android/iOS: ключ Keystore/Keychain с обязательной биометрией (D-13).
final class BiometricCryptoChannel implements BiometricAuthenticator, BiometricSecretReplacer {
  BiometricCryptoChannel({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  /// Имя канала — одинаково в Kotlin и Swift.
  static const String channelName = 'kg.optomstroy/biometric_crypto';

  final MethodChannel _channel;

  @override
  Future<BiometricCapability> capability() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('capability');
      if (raw == null) return BiometricCapability.none;
      return BiometricCapability(
        kind: _kind(raw['kind']),
        availability: _availability(raw['availability']),
        cryptoBinding: raw['cryptoBinding'] == true,
        reason: raw['reason'] as String?,
      );
    } on PlatformException {
      return BiometricCapability.none;
    } on MissingPluginException {
      return BiometricCapability.none;
    }
  }

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async {
    final raw = await _invoke('store', <String, Object?>{'secret': secret, ..._prompt(prompt)});
    if (raw == null) return const BiometricResult.failure(BiometricError.failed);
    return raw['ok'] == true
        ? const BiometricResult<void>.success(null)
        : BiometricResult.failure(parseError(raw['error']));
  }

  @override
  Future<BiometricResult<void>> replace(String secret, BiometricPromptText prompt) async {
    final raw = await _invoke('replace', <String, Object?>{'secret': secret, ..._prompt(prompt)});
    if (raw == null) return const BiometricResult.failure(BiometricError.failed);
    return raw['ok'] == true
        ? const BiometricResult<void>.success(null)
        : BiometricResult.failure(parseError(raw['error']));
  }

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async {
    final raw = await _invoke('read', _prompt(prompt));
    if (raw == null) return const BiometricResult.failure(BiometricError.failed);
    final value = raw['value'];
    if (raw['ok'] == true && value is String && value.isNotEmpty) return BiometricResult.success(value);
    return BiometricResult.failure(raw['ok'] == true ? BiometricError.failed : parseError(raw['error']));
  }

  @override
  Future<bool> hasStoredSecret() async {
    try {
      return await _channel.invokeMethod<bool>('has') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } on PlatformException {
      // Нечего удалять или хранилище недоступно — состояние «нет секрета» равнозначно.
    } on MissingPluginException {
      // Платформа без канала.
    }
  }

  /// На Android/iOS гейт без криптопривязки не используется: вход — только через [read] (09 §9.7).
  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);

  Future<Map<String, Object?>?> _invoke(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMapMethod<String, Object?>(method, args);
    } on PlatformException {
      return const <String, Object?>{'ok': false, 'error': 'failed'};
    } on MissingPluginException {
      return const <String, Object?>{'ok': false, 'error': 'not_available'};
    }
  }

  static Map<String, Object?> _prompt(BiometricPromptText p) => <String, Object?>{
    'title': p.title,
    'subtitle': p.subtitle,
    'cancel': p.cancel,
  };

  /// Код ошибки канала → [BiometricError] (неизвестный → `failed`).
  static BiometricError parseError(Object? code) => switch (code) {
    'cancelled' => BiometricError.cancelled,
    'invalidated' => BiometricError.invalidated,
    'lockout' => BiometricError.lockout,
    'not_enrolled' => BiometricError.notEnrolled,
    'not_available' => BiometricError.notAvailable,
    'no_credential' => BiometricError.noCredential,
    _ => BiometricError.failed,
  };

  static BiometricKind _kind(Object? raw) => switch (raw) {
    'android_class3' => BiometricKind.androidClass3,
    'ios' => BiometricKind.ios,
    _ => BiometricKind.none,
  };

  static BiometricAvailability _availability(Object? raw) => switch (raw) {
    'available' => BiometricAvailability.available,
    'not_enrolled' => BiometricAvailability.notEnrolled,
    'locked_out' => BiometricAvailability.lockedOut,
    _ => BiometricAvailability.unsupported,
  };
}

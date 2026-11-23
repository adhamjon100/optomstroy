// Windows Hello — только необязательный UX-гейт перед PIN приложения (D-13, D-48; 09 §9.2, §9.4).
// `local_auth` возвращает bool без криптопривязки (MASWE-0020): результат не открывает сессию,
// не вызывает /auth/refresh и не хранит секретов; `biometric_refresh` на Windows не выдаётся.
//
// Здесь же шлюз `local_auth` ([LocalAuthGateway]) для уровня W Android (15 ADR-116 п. 2): тексты диалога —
// `AndroidAuthMessages` из `local_auth_android` — Android-реализации `local_auth` 3.0.2 (федеративный плагин).
// Без них BiometricPrompt показывал бы английские тексты пакета по умолчанию («Authentication required», «Cancel»).
// Импорт нужен: Android-реализация берёт тексты только из экземпляра `AndroidAuthMessages` (`local_auth_android` 2.0.8,
// `_pigeonStringsFromAuthMessages`: `entry is AndroidAuthMessages`), а `local_auth` 3.0.2 этот класс не реэкспортирует
// (только `LocalAuthentication`, `BiometricType`, `LocalAuthException*`). Поэтому `local_auth_android` — прямая
// зависимость в `pubspec.yaml` (`^2.0.8`; в `pubspec.lock` та же 2.0.8, прежде транзитивная; новых пакетов нет,
// `flutter pub get --offline` — пакет wave2:APP-POLISH 2026-11-19), без `ignore: depend_on_referenced_packages`.
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart' show AndroidAuthMessages, AuthMessages;
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';

/// Обёртка над `local_auth` для подмены в тестах. Пользователи: гейт Windows Hello ([WindowsHelloGate], режим W1) и
/// уровень W Android (`AndroidBiometricAuthenticator`; 09 BIO-030, BIO-033; 15 ADR-116 п. 2).
abstract interface class LocalAuthGateway {
  /// Android: защищённая блокировка экрана или биометрия (`isDeviceSecure() || canAuthenticate(BIOMETRIC_WEAK)`);
  /// Windows: Windows Hello настроен.
  Future<bool> isDeviceSupported();

  /// Есть ли датчик биометрии (`local_auth` `canCheckBiometrics`; Android — `canAuthenticate(BIOMETRIC_WEAK)` ≠
  /// `NO_HARDWARE`): отличает «биометрия не настроена» от «датчика нет».
  Future<bool> canCheckBiometrics();

  /// Биометрия, которую приложение может использовать сейчас (`local_auth` `getAvailableBiometrics`; Android —
  /// [BiometricType.weak] и/или [BiometricType.strong] по `BiometricManager.canAuthenticate`).
  Future<List<BiometricType>> availableBiometrics();

  /// Системный диалог. Windows (гейт W1) — прежний вызов: только [reason], параметры `local_auth` по умолчанию
  /// (`biometricOnly: true` на Windows не поддерживается — `UnsupportedError`). Уровень W Android —
  /// `biometricOnly: true`, `sensitiveTransaction: false` (BiometricPrompt `BIOMETRIC_WEAK|BIOMETRIC_STRONG` без
  /// `CryptoObject` и без подтверждения после лица) и тексты диалога [texts]. `true` — успех; иначе `false` или
  /// [LocalAuthException].
  Future<bool> authenticate(
    String reason, {
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    BiometricPromptText? texts,
  });
}

/// Реализация на пакете `local_auth` 3.x.
final class LocalAuthPackageGateway implements LocalAuthGateway {
  LocalAuthPackageGateway([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isDeviceSupported() => _auth.isDeviceSupported();

  @override
  Future<bool> canCheckBiometrics() => _auth.canCheckBiometrics;

  @override
  Future<List<BiometricType>> availableBiometrics() => _auth.getAvailableBiometrics();

  @override
  Future<bool> authenticate(
    String reason, {
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    BiometricPromptText? texts,
  }) {
    // Гейт Windows Hello: вызов, как до ADR-116 (параметры по умолчанию).
    if (!biometricOnly && sensitiveTransaction && texts == null) return _auth.authenticate(localizedReason: reason);
    return _auth.authenticate(
      localizedReason: reason,
      biometricOnly: biometricOnly,
      sensitiveTransaction: sensitiveTransaction,
      authMessages: <AuthMessages>[
        if (texts != null)
          AndroidAuthMessages(signInTitle: texts.title, signInHint: texts.subtitle ?? '', cancelButton: texts.cancel),
      ],
    );
  }
}

/// Windows: [capability] — `windowsHello` без криптопривязки; [store]/[read] недоступны.
final class WindowsHelloGate implements BiometricAuthenticator {
  WindowsHelloGate([LocalAuthGateway? gateway]) : _gateway = gateway ?? LocalAuthPackageGateway();

  final LocalAuthGateway _gateway;

  @override
  Future<BiometricCapability> capability() async {
    try {
      final supported = await _gateway.isDeviceSupported();
      return BiometricCapability(
        kind: BiometricKind.windowsHello,
        availability: supported ? BiometricAvailability.available : BiometricAvailability.notEnrolled,
        cryptoBinding: false,
        reason: 'no_crypto_binding_on_platform',
      );
    } on Object {
      return const BiometricCapability(
        kind: BiometricKind.windowsHello,
        availability: BiometricAvailability.unsupported,
        cryptoBinding: false,
        reason: 'no_crypto_binding_on_platform',
      );
    }
  }

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);

  @override
  Future<bool> hasStoredSecret() async => false;

  @override
  Future<void> clear() async {}

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async {
    try {
      final ok = await _gateway.authenticate(prompt.title);
      return ok ? const BiometricResult<void>.success(null) : const BiometricResult.failure(BiometricError.cancelled);
    } on LocalAuthException catch (e) {
      return BiometricResult.failure(mapLocalAuthCode(e.code));
    } on Object {
      return const BiometricResult.failure(BiometricError.failed);
    }
  }

  /// Код `local_auth` → [BiometricError] (09 §9.3: lockout, notEnrolled, иное).
  static BiometricError mapLocalAuthCode(LocalAuthExceptionCode code) => switch (code) {
    LocalAuthExceptionCode.userCanceled ||
    LocalAuthExceptionCode.systemCanceled ||
    LocalAuthExceptionCode.timeout ||
    LocalAuthExceptionCode.userRequestedFallback => BiometricError.cancelled,
    LocalAuthExceptionCode.temporaryLockout || LocalAuthExceptionCode.biometricLockout => BiometricError.lockout,
    LocalAuthExceptionCode.noBiometricsEnrolled ||
    LocalAuthExceptionCode.noCredentialsSet => BiometricError.notEnrolled,
    LocalAuthExceptionCode.noBiometricHardware ||
    LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable => BiometricError.notAvailable,
    _ => BiometricError.failed,
  };
}

// Windows Hello — только необязательный UX-гейт перед PIN приложения (D-13, D-48; 09 §9.2, §9.4).
// `local_auth` возвращает bool без криптопривязки (MASWE-0020): результат не открывает сессию,
// не вызывает /auth/refresh и не хранит секретов; `biometric_refresh` на Windows не выдаётся.
import 'package:local_auth/local_auth.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';

/// Обёртка над `local_auth` для подмены в тестах.
abstract interface class LocalAuthGateway {
  Future<bool> isDeviceSupported();
  Future<bool> authenticate(String reason);
}

/// Реализация на пакете `local_auth` 3.x.
final class LocalAuthPackageGateway implements LocalAuthGateway {
  LocalAuthPackageGateway([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isDeviceSupported() => _auth.isDeviceSupported();

  @override
  Future<bool> authenticate(String reason) => _auth.authenticate(localizedReason: reason);
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

// Адаптер порта core/biometrics для регистрации (D-13; 09 §9.4). Секрет `biometric_refresh` уходит
// напрямую в platform channel и нигде больше не сохраняется; флаг «биометрия включена» — secure storage.
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';

final class DeviceBiometricsImpl implements DeviceBiometrics {
  DeviceBiometricsImpl(this._auth, this._storage);

  final BiometricAuthenticator _auth;
  final SecureStorage _storage;

  @override
  Future<BiometricOption> option() async => optionOf(await _auth.capability());

  /// Возможность устройства → вариант плитки SCR-04 (02 UI-04-006).
  static BiometricOption optionOf(BiometricCapability c) {
    if (c.kind == BiometricKind.windowsHello) {
      return c.isAvailable ? BiometricOption.windowsHelloGate : BiometricOption.unsupported;
    }
    return switch (c.availability) {
      BiometricAvailability.available => c.cryptoBinding ? BiometricOption.cryptoLogin : BiometricOption.unsupported,
      BiometricAvailability.notEnrolled => BiometricOption.notEnrolled,
      BiometricAvailability.lockedOut => BiometricOption.unsupported,
      BiometricAvailability.unsupported => BiometricOption.unsupported,
    };
  }

  @override
  Future<String?> apiClass() async => (await _auth.capability()).kind.apiClass;

  /// `AuthDeviceInfo.biometricClass` (08): Android — `class3` при сильном датчике, иначе `none`;
  /// iOS — не передаётся (сервер считает iOS пригодным); Windows — `windows_hello` / `none`.
  Future<String?> deviceClass() async {
    final c = await _auth.capability();
    return switch (c.kind) {
      BiometricKind.androidClass3 => c.availability == BiometricAvailability.unsupported ? 'none' : 'class3',
      BiometricKind.ios => null,
      BiometricKind.windowsHello => c.isAvailable ? 'windows_hello' : 'none',
      BiometricKind.none => 'none',
    };
  }

  @override
  Future<BiometricEnrollmentResult> bind(String biometricRefreshToken, BiometricPromptCopy copy) async {
    final res = await _auth.store(biometricRefreshToken, _prompt(copy));
    if (res.isSuccess) {
      await _storage.write(SecureKey.biometricsEnabled, 'true');
      return BiometricEnrollmentResult.enabled;
    }
    return mapError(res.error!);
  }

  @override
  Future<BiometricEnrollmentResult> confirmPresence(BiometricPromptCopy copy) async {
    final res = await _auth.confirmPresence(_prompt(copy));
    if (res.isSuccess) {
      // Windows: локальная настройка «Windows Hello перед вводом PIN» (сервер токен не выдаёт).
      await _storage.write(SecureKey.biometricsEnabled, 'windows_hello');
      return BiometricEnrollmentResult.enabled;
    }
    return mapError(res.error!);
  }

  @override
  Future<void> discard() async {
    await _auth.clear();
    await _storage.delete(SecureKey.biometricsEnabled);
  }

  static BiometricEnrollmentResult mapError(BiometricError e) => switch (e) {
    BiometricError.cancelled => BiometricEnrollmentResult.cancelled,
    BiometricError.lockout => BiometricEnrollmentResult.lockout,
    BiometricError.notEnrolled => BiometricEnrollmentResult.notEnrolled,
    BiometricError.invalidated ||
    BiometricError.notAvailable ||
    BiometricError.noCredential ||
    BiometricError.failed => BiometricEnrollmentResult.failed,
  };

  static BiometricPromptText _prompt(BiometricPromptCopy c) =>
      BiometricPromptText(title: c.title, subtitle: c.subtitle, cancel: c.cancel);
}

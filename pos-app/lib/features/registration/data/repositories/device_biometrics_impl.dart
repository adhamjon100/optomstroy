// Адаптер порта core/biometrics для регистрации (D-13; 09 §9.4). Секрет `biometric_refresh` уходит
// напрямую в platform channel и нигде больше не сохраняется; флаг «биометрия включена» — secure storage.
// Windows Hello (режим W1; 15 ADR-116 п. 3; 09 BIO-034): гейт включается после `201 /registration/complete` — сессия
// уже открыта, признак пишется по её `userId` (`auth.hello_gate_users`, core/biometrics/hello_gate_users.dart).
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';

final class DeviceBiometricsImpl implements DeviceBiometrics {
  /// [currentUserId] — `userId` сессии после `201` (гейт Windows Hello по пользователю); без него гейт не включается.
  DeviceBiometricsImpl(this._auth, this._storage, {String? Function()? currentUserId}) : _currentUserId = currentUserId;

  final BiometricAuthenticator _auth;
  final SecureStorage _storage;
  final String? Function()? _currentUserId;

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

  /// `AuthDeviceInfo.biometricClass` (08): Android — `class3` при сильном датчике, `class2` на устройстве только с
  /// уровнем W (15 ADR-116; при регистрации уровень W не включается — сервер не выставляет `biometricRefreshOffered`,
  /// плитка SCR-04 — [optionOf]), иначе `none`; iOS — не передаётся (сервер считает iOS пригодным);
  /// Windows — `windows_hello` / `none`.
  Future<String?> deviceClass() async {
    final c = await _auth.capability();
    return switch (c.kind) {
      BiometricKind.androidClass3 => c.availability == BiometricAvailability.unsupported ? 'none' : 'class3',
      BiometricKind.androidClass2 => c.weakAvailability == BiometricAvailability.unsupported ? 'none' : 'class2',
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
    final String? userId = _userId();
    if (userId == null) return BiometricEnrollmentResult.failed;
    final res = await _auth.confirmPresence(_prompt(copy));
    if (res.isSuccess) {
      // Windows: локальная настройка «Windows Hello перед вводом PIN» этого пользователя (сервер токен не выдаёт).
      return await HelloGateUsers(_storage).add(userId)
          ? BiometricEnrollmentResult.enabled
          : BiometricEnrollmentResult.failed;
    }
    return mapError(res.error!);
  }

  @override
  Future<void> discard() async {
    await _auth.clear();
    await _storage.delete(SecureKey.biometricsEnabled);
    final String? userId = _userId();
    if (userId != null) await HelloGateUsers(_storage).remove(userId);
  }

  String? _userId() {
    try {
      return _currentUserId?.call();
    } on Object {
      return null;
    }
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

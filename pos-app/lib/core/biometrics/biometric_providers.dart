// Провайдер порта биометрии (core; 06 §6.10). Выбор реализации — по платформе сборки;
// в тестах переопределяется моком (`biometricAuthenticatorProvider.overrideWithValue(...)`).
// Android — композит уровней S и W (`AndroidBiometricAuthenticator`, 15 ADR-116 п. 2); iOS — канал ADR-087;
// Windows — гейт Windows Hello (W1) и ключ Windows Hello (W2, `WindowsHelloKeyAuthenticator`, 15 ADR-116 п. 3); web —
// без биометрии (веб-демо переопределяет провайдер своим корнем, ADR-113).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/biometrics/android_biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_crypto_channel.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key_authenticator.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

/// Реализация для платформы [platform] (web — без биометрии). [storage] — секрет уровня W Android
/// (`auth.biometric_refresh_weak`); [isProd] — `ENV=prod`: уровень W только на физическом устройстве в release-сборке
/// (11 SEC-090).
BiometricAuthenticator biometricAuthenticatorFor(
  TargetPlatform platform, {
  required SecureStorage storage,
  required bool isProd,
  bool isWeb = kIsWeb,
}) {
  if (isWeb) return const NoBiometricAuthenticator();
  return switch (platform) {
    TargetPlatform.android => AndroidBiometricAuthenticator(storage: storage, requireReleaseDevice: isProd),
    TargetPlatform.iOS => BiometricCryptoChannel(),
    TargetPlatform.windows => WindowsHelloKeyAuthenticator(),
    _ => const NoBiometricAuthenticator(),
  };
}

/// Порт биометрии устройства (D-13).
final biometricAuthenticatorProvider = Provider<BiometricAuthenticator>(
  (ref) => biometricAuthenticatorFor(
    defaultTargetPlatform,
    storage: ref.watch(secureStorageProvider),
    isProd: ref.watch(appConfigProvider).isProd,
  ),
);

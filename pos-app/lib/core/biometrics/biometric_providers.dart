// Провайдер порта биометрии (core; 06 §6.10). Выбор реализации — по платформе сборки;
// в тестах переопределяется моком (`biometricAuthenticatorProvider.overrideWithValue(...)`).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_crypto_channel.dart';
import 'package:optomstroy/core/biometrics/windows_hello_gate.dart';

/// Реализация для платформы [platform] (web — без биометрии).
BiometricAuthenticator biometricAuthenticatorFor(TargetPlatform platform, {bool isWeb = kIsWeb}) {
  if (isWeb) return const NoBiometricAuthenticator();
  return switch (platform) {
    TargetPlatform.android || TargetPlatform.iOS => BiometricCryptoChannel(),
    TargetPlatform.windows => WindowsHelloGate(),
    _ => const NoBiometricAuthenticator(),
  };
}

/// Порт биометрии устройства (D-13).
final biometricAuthenticatorProvider = Provider<BiometricAuthenticator>(
  (ref) => biometricAuthenticatorFor(defaultTargetPlatform),
);

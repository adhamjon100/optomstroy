// Адаптер порта SCR-08 [BiometricUnlock] к `BiometricAuthenticator` core/biometrics (RM-D-008;
// D-13; ядро §21 п.2 — собственный platform channel: Android Keystore + BiometricPrompt.CryptoObject,
// iOS Keychain biometryCurrentSet; Windows Hello — только UX-гейт перед PIN).
// Секрет (`biometric_refresh`) не логируется; биометрические данные приложение не получает.
import 'dart:ui' show Locale;

import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';

final class BiometricUnlockAdapter implements BiometricUnlock {
  BiometricUnlockAdapter({
    required BiometricAuthenticator authenticator,
    required SecureStorage storage,
    String Function()? languageCode,
  }) : _auth = authenticator,
       _storage = storage,
       _languageCode = languageCode ?? _ru;

  static String _ru() => 'ru';

  /// Значение `SecureKey.biometricsEnabled` для локального гейта Windows Hello (RB-09, RM-D-008).
  static const String windowsHelloFlag = 'windows_hello';

  final BiometricAuthenticator _auth;
  final SecureStorage _storage;
  final String Function() _languageCode;

  /// Тексты системного диалога — ARB (`unlock_bio_button`, `ds_button_cancel`).
  BiometricPromptText get _prompt {
    final AppLocalizations l10n = lookupAppLocalizations(Locale(_languageCode()));
    return BiometricPromptText(title: l10n.unlock_bio_button, cancel: l10n.ds_button_cancel);
  }

  @override
  Future<BiometricUnlockKind> capability() async {
    final BiometricCapability c = await _auth.capability();
    if (c.supportsCryptoLogin) {
      return BiometricUnlockKind.cryptoBound;
    }
    if (c.kind == BiometricKind.windowsHello && c.isAvailable) {
      return BiometricUnlockKind.windowsHelloGate;
    }
    return BiometricUnlockKind.none;
  }

  @override
  Future<BiometricUnlockKind> kind() async {
    final BiometricCapability c = await _auth.capability();
    if (c.supportsCryptoLogin && await _auth.hasStoredSecret()) {
      return BiometricUnlockKind.cryptoBound;
    }
    if (c.kind == BiometricKind.windowsHello && c.isAvailable) {
      final String? flag = await _readFlag();
      return flag == windowsHelloFlag ? BiometricUnlockKind.windowsHelloGate : BiometricUnlockKind.none;
    }
    return BiometricUnlockKind.none;
  }

  @override
  Future<BiometricSecretResult> readSecret() async {
    final BiometricResult<String> r = await _auth.read(_prompt);
    if (r.isSuccess && r.value != null) {
      return BiometricSecretOk(r.value!);
    }
    return switch (r.error) {
      BiometricError.cancelled => const BiometricSecretCancelled(),
      BiometricError.lockout => const BiometricSecretLockedOut(),
      BiometricError.invalidated => const BiometricSecretInvalidated(),
      _ => const BiometricSecretUnavailable(),
    };
  }

  /// Новый biometric refresh после `/auth/unlock {method: biometric}` (02 SCR-08.4 п. 3; AU-07): тем же ключом
  /// (`BiometricSecretReplacer.replace`); ключа нет или канал без метода `replace` — `store` (новый ключ).
  @override
  Future<bool> storeSecret(String secret) async {
    final BiometricAuthenticator auth = _auth;
    if (auth is BiometricSecretReplacer) {
      final BiometricResult<void> replaced = await (auth as BiometricSecretReplacer).replace(secret, _prompt);
      if (replaced.isSuccess) return true;
      if (replaced.error != BiometricError.noCredential && replaced.error != BiometricError.notAvailable) {
        return false;
      }
    }
    return (await auth.store(secret, _prompt)).isSuccess;
  }

  @override
  Future<void> clear() => _auth.clear();

  @override
  Future<bool> confirmPresence() async => (await _auth.confirmPresence(_prompt)).isSuccess;

  Future<String?> _readFlag() async {
    try {
      return await _storage.read(SecureKey.biometricsEnabled);
    } on Object {
      return null;
    }
  }
}

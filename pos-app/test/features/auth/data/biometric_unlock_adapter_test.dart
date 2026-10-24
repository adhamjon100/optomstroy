// Адаптер SCR-08 → BiometricAuthenticator (core/biometrics, RM-D-008): отображение
// возможностей и ошибок ОС, гейт Windows Hello по локальному флагу, тексты диалога — ARB.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';

import '../../../core/storage/in_memory_secure_storage.dart';

final class _FakeAuthenticator implements BiometricAuthenticator {
  _FakeAuthenticator(this.cap, {this.hasSecret = true});

  BiometricCapability cap;
  bool hasSecret;
  BiometricResult<String> readResult = const BiometricResult<String>.success('bio-secret');
  final List<String> prompts = <String>[];
  final List<String> stored = <String>[];

  @override
  Future<BiometricCapability> capability() async => cap;

  @override
  Future<bool> hasStoredSecret() async => hasSecret;

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async {
    prompts.add(prompt.title);
    return readResult;
  }

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async {
    stored.add(secret);
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<void> clear() async => hasSecret = false;

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult<void>.success(null);
}

const BiometricCapability _class3 = BiometricCapability(
  kind: BiometricKind.androidClass3,
  availability: BiometricAvailability.available,
  cryptoBinding: true,
);

const BiometricCapability _hello = BiometricCapability(
  kind: BiometricKind.windowsHello,
  availability: BiometricAvailability.available,
  cryptoBinding: false,
);

void main() {
  test('Android class3 с сохранённым секретом → cryptoBound; без секрета — кнопки нет', () async {
    final _FakeAuthenticator a = _FakeAuthenticator(_class3);
    final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: a, storage: InMemorySecureStorage());
    expect(await adapter.capability(), BiometricUnlockKind.cryptoBound);
    expect(await adapter.kind(), BiometricUnlockKind.cryptoBound);
    a.hasSecret = false;
    expect(await adapter.kind(), BiometricUnlockKind.none);
  });

  test('T-BIO-004: Windows Hello — гейт только при локальном флаге windows_hello (RB-09)', () async {
    final InMemorySecureStorage storage = InMemorySecureStorage();
    final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
      authenticator: _FakeAuthenticator(_hello, hasSecret: false),
      storage: storage,
    );
    expect(await adapter.capability(), BiometricUnlockKind.windowsHelloGate);
    expect(await adapter.kind(), BiometricUnlockKind.none);
    await storage.write(SecureKey.biometricsEnabled, BiometricUnlockAdapter.windowsHelloFlag);
    expect(await adapter.kind(), BiometricUnlockKind.windowsHelloGate);
    expect(await adapter.confirmPresence(), isTrue);
  });

  test('read: секрет, отмена, lockout, инвалидация, прочее; заголовок диалога из ARB', () async {
    final _FakeAuthenticator a = _FakeAuthenticator(_class3);
    final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: a, storage: InMemorySecureStorage());
    expect(await adapter.readSecret(), isA<BiometricSecretOk>());
    expect(a.prompts.single, 'Войти по биометрии');
    final Map<BiometricError, Type> map = <BiometricError, Type>{
      BiometricError.cancelled: BiometricSecretCancelled,
      BiometricError.lockout: BiometricSecretLockedOut,
      BiometricError.invalidated: BiometricSecretInvalidated,
      BiometricError.notEnrolled: BiometricSecretUnavailable,
      BiometricError.noCredential: BiometricSecretUnavailable,
      BiometricError.failed: BiometricSecretUnavailable,
    };
    for (final MapEntry<BiometricError, Type> e in map.entries) {
      a.readResult = BiometricResult<String>.failure(e.key);
      expect((await adapter.readSecret()).runtimeType, e.value, reason: e.key.name);
    }
  });

  test('storeSecret передаёт новый biometric refresh в порт core', () async {
    final _FakeAuthenticator a = _FakeAuthenticator(_class3);
    final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: a, storage: InMemorySecureStorage());
    expect(await adapter.storeSecret('next'), isTrue);
    expect(a.stored, <String>['next']);
    await adapter.clear();
    expect(a.hasSecret, isFalse);
  });
}

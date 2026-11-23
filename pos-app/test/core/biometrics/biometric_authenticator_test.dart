// Типы порта core/biometrics для двух уровней входа (15 ADR-116 п. 2; 09 §9.2, BIO-030…BIO-033; 11 RR-9):
// вид `androidClass2` (`class2`), уровни S и W, поля уровня W в `BiometricCapability` (по умолчанию — «недоступно»,
// прежнее поведение реализаций без уровня W), необязательный интерфейс `BiometricWeakStore` (по образцу
// `BiometricSecretReplacer`) и потребители исчерпывающих switch по виду (регистрация SCR-04).
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_crypto_channel.dart';
import 'package:optomstroy/core/biometrics/windows_hello_gate.dart';
import 'package:optomstroy/features/registration/data/repositories/device_biometrics_impl.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';

import '../storage/in_memory_secure_storage.dart';

class _MockAuthenticator extends Mock implements BiometricAuthenticator {}

/// Реализация с уровнем W: порт + необязательные интерфейсы (как композит Android, 06 §6.2).
final class _WeakCapable implements BiometricAuthenticator, BiometricSecretReplacer, BiometricWeakStore {
  String? weak;
  int prompts = 0;

  @override
  Future<BiometricCapability> capability() async => BiometricCapability(
    kind: BiometricKind.androidClass2,
    availability: BiometricAvailability.unsupported,
    cryptoBinding: false,
    reason: 'no_hardware_or_weak_only',
    weakAvailability: BiometricAvailability.available,
    storedTier: weak == null ? null : BiometricTier.weak,
  );

  @override
  Future<BiometricResult<void>> storeWeak(String secret, BiometricPromptText prompt) async {
    prompts++;
    weak = secret;
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<BiometricResult<void>> replace(String secret, BiometricPromptText prompt) async {
    if (weak == null) return const BiometricResult.failure(BiometricError.noCredential);
    weak = secret;
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async {
    prompts++;
    final String? value = weak;
    return value == null ? const BiometricResult.failure(BiometricError.noCredential) : BiometricResult.success(value);
  }

  @override
  Future<bool> hasStoredSecret() async => weak != null;

  @override
  Future<void> clear() async => weak = null;

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);
}

const BiometricPromptText _prompt = BiometricPromptText(title: 'Вход по лицу или отпечатку', cancel: 'Отмена');

BiometricCapability _android({
  BiometricKind kind = BiometricKind.androidClass3,
  BiometricAvailability strong = BiometricAvailability.available,
  BiometricAvailability weak = BiometricAvailability.unsupported,
  BiometricTier? stored,
}) => BiometricCapability(
  kind: kind,
  availability: strong,
  cryptoBinding: strong != BiometricAvailability.unsupported,
  weakAvailability: weak,
  storedTier: stored,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BiometricKind.apiClass — значения MeBiometricsRequest.biometricClass (08 §4.3.6)', () {
    test('каждый вид: class3, class2, ios, windows_hello; «нет» — поле не передаётся', () {
      expect(
        <BiometricKind, String?>{for (final BiometricKind k in BiometricKind.values) k: k.apiClass},
        <BiometricKind, String?>{
          BiometricKind.androidClass3: 'class3',
          BiometricKind.androidClass2: 'class2',
          BiometricKind.ios: 'ios',
          BiometricKind.windowsHello: 'windows_hello',
          BiometricKind.none: null,
        },
      );
    });
  });

  group('BiometricCapability: поля уровня W', () {
    test('по умолчанию уровень W недоступен и уровень секрета неизвестен — прежние реализации без изменений', () {
      const BiometricCapability legacy = BiometricCapability(
        kind: BiometricKind.androidClass3,
        availability: BiometricAvailability.available,
        cryptoBinding: true,
      );
      expect(legacy.weakAvailability, BiometricAvailability.unsupported);
      expect(legacy.weakReason, isNull);
      expect(legacy.storedTier, isNull);
      expect(legacy.supportsWeakLogin, isFalse);
      expect(legacy.supportsCryptoLogin, isTrue);
      expect(BiometricCapability.none.supportsWeakLogin, isFalse);
      expect(BiometricCapability.none.preferredTier, isNull);
    });

    test('supportsWeakLogin — только при weakAvailability = available; уровень S от него не зависит', () {
      for (final BiometricAvailability a in BiometricAvailability.values) {
        final BiometricCapability c = _android(strong: BiometricAvailability.unsupported, weak: a);
        expect(c.supportsWeakLogin, a == BiometricAvailability.available, reason: a.name);
        expect(c.supportsCryptoLogin, isFalse, reason: a.name);
      }
    });

    test('preferredTier: S надёжнее и предлагается первым (Q-354); иначе W; иначе ничего', () {
      expect(_android(weak: BiometricAvailability.available).preferredTier, BiometricTier.strong);
      expect(_android().preferredTier, BiometricTier.strong);
      expect(
        _android(
          kind: BiometricKind.androidClass2,
          strong: BiometricAvailability.unsupported,
          weak: BiometricAvailability.available,
        ).preferredTier,
        BiometricTier.weak,
      );
      expect(
        _android(strong: BiometricAvailability.notEnrolled, weak: BiometricAvailability.available).preferredTier,
        BiometricTier.weak,
        reason: 'отпечаток Class 3 не настроен, а лицо Class 2 есть',
      );
      expect(
        _android(strong: BiometricAvailability.lockedOut, weak: BiometricAvailability.lockedOut).preferredTier,
        isNull,
      );
      const BiometricCapability hello = BiometricCapability(
        kind: BiometricKind.windowsHello,
        availability: BiometricAvailability.available,
        cryptoBinding: false,
      );
      expect(hello.preferredTier, isNull, reason: 'Windows Hello — гейт, а не вход по biometric_refresh');
    });

    test('kindFor: уровень W — всегда class2; уровень S — вид устройства; без датчика Class 3 — без класса', () {
      final BiometricCapability both = _android(weak: BiometricAvailability.available);
      expect(both.kindFor(BiometricTier.weak), BiometricKind.androidClass2);
      expect(both.kindFor(BiometricTier.weak).apiClass, 'class2');
      expect(both.kindFor(BiometricTier.strong), BiometricKind.androidClass3);
      final BiometricCapability weakOnly = _android(
        kind: BiometricKind.androidClass2,
        strong: BiometricAvailability.unsupported,
        weak: BiometricAvailability.available,
      );
      expect(weakOnly.kindFor(BiometricTier.strong), BiometricKind.none);
      expect(weakOnly.kindFor(BiometricTier.strong).apiClass, isNull);
      const BiometricCapability ios = BiometricCapability(
        kind: BiometricKind.ios,
        availability: BiometricAvailability.available,
        cryptoBinding: true,
      );
      expect(ios.kindFor(BiometricTier.strong).apiClass, 'ios');
    });

    test('storedTier различает уровень сохранённого секрета; toString — без секретов, с полями уровня W', () {
      expect(_android(stored: BiometricTier.weak).storedTier, BiometricTier.weak);
      expect(_android(stored: BiometricTier.strong).storedTier, BiometricTier.strong);
      final String text = const BiometricCapability(
        kind: BiometricKind.androidClass3,
        availability: BiometricAvailability.available,
        cryptoBinding: true,
        weakAvailability: BiometricAvailability.unsupported,
        weakReason: 'emulator',
        storedTier: BiometricTier.strong,
      ).toString();
      expect(text, contains('weak: unsupported emulator'));
      expect(text, contains('stored: strong'));
      expect(
        const BiometricResult<String>.success('biometric-refresh-value').toString(),
        isNot(contains('biometric-refresh')),
      );
    });
  });

  group('BiometricWeakStore — необязательный интерфейс порта', () {
    test('реализации без уровня W его не реализуют: «нет», канал v1 (S и iOS), гейт Windows Hello', () {
      expect(const NoBiometricAuthenticator() is BiometricWeakStore, isFalse);
      expect(BiometricCryptoChannel() is BiometricWeakStore, isFalse);
      expect(WindowsHelloGate() is BiometricWeakStore, isFalse);
    });

    test('реализация с уровнем W: storeWeak → read (диалог) → replace без диалога → clear', () async {
      final _WeakCapable auth = _WeakCapable();
      final BiometricAuthenticator port = auth;
      expect(port, isA<BiometricWeakStore>());
      expect((await port.capability()).supportsWeakLogin, isTrue);
      expect((await port.capability()).storedTier, isNull);

      expect((await (port as BiometricWeakStore).storeWeak('w-1', _prompt)).isSuccess, isTrue);
      expect((await port.capability()).storedTier, BiometricTier.weak);
      expect((await port.read(_prompt)).value, 'w-1');
      expect(auth.prompts, 2);

      expect((await (port as BiometricSecretReplacer).replace('w-2', _prompt)).isSuccess, isTrue);
      expect(auth.prompts, 2, reason: 'перешифровка уровня W — без второго диалога');
      expect(await port.hasStoredSecret(), isTrue);

      await port.clear();
      expect(await port.hasStoredSecret(), isFalse);
      expect((await port.capability()).storedTier, isNull);
    });
  });

  group('регистрация (SCR-04) и вид androidClass2', () {
    late _MockAuthenticator auth;

    setUp(() => auth = _MockAuthenticator());

    test('плитка SCR-04 уровень W не предлагает (нет криптопривязки)', () {
      expect(
        DeviceBiometricsImpl.optionOf(
          _android(
            kind: BiometricKind.androidClass2,
            strong: BiometricAvailability.unsupported,
            weak: BiometricAvailability.available,
          ),
        ),
        BiometricOption.unsupported,
      );
      expect(
        DeviceBiometricsImpl.optionOf(_android(weak: BiometricAvailability.available)),
        BiometricOption.cryptoLogin,
        reason: 'Class 3 и Class 2 — плитка уровня S, как прежде',
      );
    });

    test('AuthDeviceInfo.biometricClass при регистрации: class2 только у устройства с одним уровнем W', () async {
      Future<String?> classOf(BiometricCapability c) async {
        when(() => auth.capability()).thenAnswer((_) async => c);
        return DeviceBiometricsImpl(auth, InMemorySecureStorage()).deviceClass();
      }

      expect(
        await classOf(
          _android(
            kind: BiometricKind.androidClass2,
            strong: BiometricAvailability.unsupported,
            weak: BiometricAvailability.available,
          ),
        ),
        'class2',
      );
      expect(
        await classOf(
          _android(
            kind: BiometricKind.androidClass2,
            strong: BiometricAvailability.unsupported,
            weak: BiometricAvailability.notEnrolled,
          ),
        ),
        'class2',
        reason: 'как у class3: датчик есть, биометрия не настроена',
      );
      expect(
        await classOf(_android(kind: BiometricKind.androidClass2, strong: BiometricAvailability.unsupported)),
        'none',
      );
      expect(await classOf(_android(weak: BiometricAvailability.available)), 'class3');
    });
  });
}

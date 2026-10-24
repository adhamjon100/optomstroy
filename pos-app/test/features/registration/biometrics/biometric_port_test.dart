// Порт биометрии core/biometrics (D-13): протокол platform channel (Kotlin/Swift ↔ Dart) на моке канала,
// Windows Hello как UX-гейт без секретов, адаптер регистрации поверх порта-мока (T-BIO-008: доступ к токену —
// только через platform channel, `local_auth` секретов не отдаёт).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_crypto_channel.dart';
import 'package:optomstroy/core/biometrics/windows_hello_gate.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/registration/data/repositories/device_biometrics_impl.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';

import '../../../core/storage/in_memory_secure_storage.dart';

class MockAuthenticator extends Mock implements BiometricAuthenticator {}

class FakeGateway implements LocalAuthGateway {
  FakeGateway({this.supported = true, this.result = true, this.error});

  bool supported;
  bool result;
  LocalAuthException? error;

  @override
  Future<bool> authenticate(String reason) async {
    if (error != null) throw error!;
    return result;
  }

  @override
  Future<bool> isDeviceSupported() async => supported;
}

const BiometricPromptText _prompt = BiometricPromptText(title: 'Вход', cancel: 'Отмена', subtitle: 's');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(_prompt));

  group('BiometricCryptoChannel (протокол канала)', () {
    const channel = MethodChannel(BiometricCryptoChannel.channelName);
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    void handle(Object? Function(MethodCall call) reply) {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return reply(call);
      });
    }

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('capability: Android Class 3 с криптопривязкой', () async {
      handle((_) => <String, Object?>{'kind': 'android_class3', 'availability': 'available', 'cryptoBinding': true});
      final cap = await BiometricCryptoChannel().capability();
      expect(cap.kind, BiometricKind.androidClass3);
      expect(cap.supportsCryptoLogin, isTrue);
      expect(cap.kind.apiClass, 'class3');
    });

    test('T-BIO-005 (часть): capability: API < 30 — не предлагается (09 §9.4)', () async {
      handle(
        (_) => <String, Object?>{
          'kind': 'none',
          'availability': 'unsupported',
          'cryptoBinding': false,
          'reason': 'api_level',
        },
      );
      final cap = await BiometricCryptoChannel().capability();
      expect(cap.supportsCryptoLogin, isFalse);
      expect(cap.reason, 'api_level');
    });

    test('store: секрет и тексты уходят только в канал; ok', () async {
      handle((_) => <String, Object?>{'ok': true});
      final res = await BiometricCryptoChannel().store('refresh-secret', _prompt);
      expect(res.isSuccess, isTrue);
      expect(calls.single.method, 'store');
      expect(calls.single.arguments, <String, Object?>{
        'secret': 'refresh-secret', // check-secrets: allow — тестовое значение
        'title': 'Вход',
        'subtitle': 's',
        'cancel': 'Отмена',
      });
      expect(res.toString(), isNot(contains('refresh-secret')));
    });

    test('read: инвалидация ключа (KeyPermanentlyInvalidatedException / errSecItemNotFound) → invalidated', () async {
      handle((_) => <String, Object?>{'ok': false, 'error': 'invalidated'});
      final res = await BiometricCryptoChannel().read(_prompt);
      expect(res.error, BiometricError.invalidated);
    });

    test('read: успех возвращает расшифрованный секрет', () async {
      handle((_) => <String, Object?>{'ok': true, 'value': 'decrypted'});
      final res = await BiometricCryptoChannel().read(_prompt);
      expect(res.value, 'decrypted');
    });

    test('коды ошибок канала', () {
      expect(BiometricCryptoChannel.parseError('cancelled'), BiometricError.cancelled);
      expect(BiometricCryptoChannel.parseError('lockout'), BiometricError.lockout);
      expect(BiometricCryptoChannel.parseError('not_enrolled'), BiometricError.notEnrolled);
      expect(BiometricCryptoChannel.parseError('no_credential'), BiometricError.noCredential);
      expect(BiometricCryptoChannel.parseError('???'), BiometricError.failed);
    });

    test('нет реализации канала (Windows/тест) → биометрии нет, без исключений', () async {
      final cap = await BiometricCryptoChannel().capability();
      expect(cap.supportsCryptoLogin, isFalse);
      expect((await BiometricCryptoChannel().store('x', _prompt)).error, BiometricError.notAvailable);
      expect(await BiometricCryptoChannel().hasStoredSecret(), isFalse);
    });

    test('гейт без криптопривязки на Android/iOS не используется', () async {
      expect((await BiometricCryptoChannel().confirmPresence(_prompt)).error, BiometricError.notAvailable);
    });
  });

  group('T-BIO-004: WindowsHelloGate (UX-гейт, D-13/D-48)', () {
    test('нет криптопривязки, store/read недоступны', () async {
      final gate = WindowsHelloGate(FakeGateway());
      final cap = await gate.capability();
      expect(cap.kind, BiometricKind.windowsHello);
      expect(cap.cryptoBinding, isFalse);
      expect(cap.supportsCryptoLogin, isFalse);
      expect((await gate.store('secret', _prompt)).error, BiometricError.notAvailable);
      expect((await gate.read(_prompt)).error, BiometricError.notAvailable);
      expect(await gate.hasStoredSecret(), isFalse);
    });

    test('подтверждение присутствия и отмена', () async {
      expect((await WindowsHelloGate(FakeGateway()).confirmPresence(_prompt)).isSuccess, isTrue);
      expect(
        (await WindowsHelloGate(FakeGateway(result: false)).confirmPresence(_prompt)).error,
        BiometricError.cancelled,
      );
      final locked = FakeGateway(error: const LocalAuthException(code: LocalAuthExceptionCode.biometricLockout));
      expect((await WindowsHelloGate(locked).confirmPresence(_prompt)).error, BiometricError.lockout);
    });

    test('Hello не настроен → notEnrolled', () async {
      final cap = await WindowsHelloGate(FakeGateway(supported: false)).capability();
      expect(cap.availability, BiometricAvailability.notEnrolled);
    });
  });

  group('DeviceBiometricsImpl поверх мока порта', () {
    late MockAuthenticator auth;
    late InMemorySecureStorage storage;

    setUp(() {
      auth = MockAuthenticator();
      storage = InMemorySecureStorage();
    });

    test('вариант плитки SCR-04 по возможностям устройства', () {
      BiometricOption of(BiometricKind k, BiometricAvailability a, {bool crypto = true}) =>
          DeviceBiometricsImpl.optionOf(BiometricCapability(kind: k, availability: a, cryptoBinding: crypto));
      expect(of(BiometricKind.androidClass3, BiometricAvailability.available), BiometricOption.cryptoLogin);
      expect(of(BiometricKind.ios, BiometricAvailability.available), BiometricOption.cryptoLogin);
      expect(of(BiometricKind.androidClass3, BiometricAvailability.notEnrolled), BiometricOption.notEnrolled);
      expect(of(BiometricKind.none, BiometricAvailability.unsupported, crypto: false), BiometricOption.unsupported);
      expect(
        of(BiometricKind.windowsHello, BiometricAvailability.available, crypto: false),
        BiometricOption.windowsHelloGate,
      );
    });

    test('T-BIO-010: bind: секрет — только в порт; в secure storage — лишь флаг', () async {
      when(() => auth.store(any(), any())).thenAnswer((_) async => const BiometricResult<void>.success(null));
      final res = await DeviceBiometricsImpl(
        auth,
        storage,
      ).bind('biometric-refresh-value', const BiometricPromptCopy(title: 't', cancel: 'c'));
      expect(res, BiometricEnrollmentResult.enabled);
      verify(() => auth.store('biometric-refresh-value', any())).called(1);
      expect(storage.values[SecureKey.biometricsEnabled], 'true');
      expect(storage.values.values.any((v) => v.contains('biometric-refresh-value')), isFalse);
    });

    test('bind: отмена → cancelled, флаг не пишется', () async {
      when(
        () => auth.store(any(), any()),
      ).thenAnswer((_) async => const BiometricResult<void>.failure(BiometricError.cancelled));
      final res = await DeviceBiometricsImpl(
        auth,
        storage,
      ).bind('x', const BiometricPromptCopy(title: 't', cancel: 'c'));
      expect(res, BiometricEnrollmentResult.cancelled);
      expect(storage.values, isEmpty);
    });

    test('класс устройства для AuthDeviceInfo', () async {
      when(() => auth.capability()).thenAnswer(
        (_) async => const BiometricCapability(
          kind: BiometricKind.androidClass3,
          availability: BiometricAvailability.notEnrolled,
          cryptoBinding: true,
        ),
      );
      expect(await DeviceBiometricsImpl(auth, storage).deviceClass(), 'class3');
      when(() => auth.capability()).thenAnswer(
        (_) async => const BiometricCapability(
          kind: BiometricKind.ios,
          availability: BiometricAvailability.available,
          cryptoBinding: true,
        ),
      );
      expect(await DeviceBiometricsImpl(auth, storage).deviceClass(), isNull, reason: 'iOS — поле не передаётся');
    });

    test('discard удаляет ключ и флаг', () async {
      when(() => auth.clear()).thenAnswer((_) async {});
      await storage.write(SecureKey.biometricsEnabled, 'true');
      await DeviceBiometricsImpl(auth, storage).discard();
      verify(() => auth.clear()).called(1);
      expect(storage.values.containsKey(SecureKey.biometricsEnabled), isFalse);
    });
  });
}

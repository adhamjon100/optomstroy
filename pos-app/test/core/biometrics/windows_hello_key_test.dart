// Ключ Windows Hello (W2; 15 ADR-116 п. 3; 09 §9.2 «Вход по ключу Windows Hello», BIO-038…BIO-040): Dart-обёртка канала
// `kg.optomstroy/windows_hello` на подменном канале, `WindowsHelloKeyAuthenticator`, признак `auth.hello_key_users`
// и сверка протокола Dart с нативом windows/runner/hello_channel.{h,cpp} (12 T-BIO-036 (2), T-BIO-032 — статическая
// часть; сам натив собирается и опрашивается `availability` в integration_test/windows_hello_channel_test.dart).
// Диалог Windows Hello не вызывается: канал подменён.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/biometrics/hello_key_users.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key_authenticator.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key_channel.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

import '../storage/in_memory_secure_storage.dart';

const String _userA = '0192F3A1-6C3E-7A1B-9F00-2B7C1D3E4F01';
const String _userB = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f02';
const String _challenge = 'optomstroy-hello-unlock/v1:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
const MethodChannel _channel = MethodChannel(WindowsHelloKeyChannel.name);

/// Подменный натив канала: ответы задаёт тест, вызовы записываются (без диалогов ОС).
final class _Native {
  final List<MethodCall> calls = <MethodCall>[];
  Map<String, Object?> availability = <String, Object?>{'availability': 'available', 'keysSupported': true};
  Map<String, Object?> create = <String, Object?>{
    'status': 'ok',
    'publicKey': Uint8List.fromList(<int>[0x30, 0x82, 0x01, 0x22, 0xfb, 0xff]),
  };
  Map<String, Object?> sign = <String, Object?>{
    'status': 'ok',
    'signature': Uint8List.fromList(<int>[1, 2, 3, 0xfe, 0xff]),
  };
  Map<String, Object?> delete = <String, Object?>{'status': 'ok'};
  PlatformException? error;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final PlatformException? e = error;
    if (e != null) throw e;
    return switch (call.method) {
      'availability' => availability,
      'createKey' => create,
      'sign' => sign,
      'deleteKey' => delete,
      _ => throw MissingPluginException(),
    };
  }

  Iterable<String> get methods => calls.map((MethodCall c) => c.method);
}

/// Гейт W1 (подмена `WindowsHelloGate`): возможности и счёт диалогов `local_auth`.
final class _Gate implements BiometricAuthenticator {
  int presence = 0;
  int clears = 0;

  @override
  Future<BiometricCapability> capability() async => const BiometricCapability(
    kind: BiometricKind.windowsHello,
    availability: BiometricAvailability.available,
    cryptoBinding: false,
    reason: 'no_crypto_binding_on_platform',
  );

  @override
  Future<bool> hasStoredSecret() async => false;

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async =>
      const BiometricResult<String>.failure(BiometricError.notAvailable);

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async =>
      const BiometricResult<void>.failure(BiometricError.notAvailable);

  @override
  Future<void> clear() async => clears++;

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async {
    presence++;
    return const BiometricResult<void>.success(null);
  }
}

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Native native;
  late _Gate gate;
  late WindowsHelloKeyAuthenticator auth;

  setUp(() {
    native = _Native();
    gate = _Gate();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, native.handle);
    auth = WindowsHelloKeyAuthenticator(gate: gate);
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null),
  );

  group('T-BIO-036 (2): availability канала', () {
    test('ответы натива → WindowsHelloStatus; ключ — только при available и keysSupported', () async {
      for (final (String raw, WindowsHelloAvailability expected) in <(String, WindowsHelloAvailability)>[
        ('available', WindowsHelloAvailability.available),
        ('device_not_present', WindowsHelloAvailability.deviceNotPresent),
        ('not_configured', WindowsHelloAvailability.notConfigured),
        ('disabled_by_policy', WindowsHelloAvailability.disabledByPolicy),
        ('device_busy', WindowsHelloAvailability.deviceBusy),
        ('something_new', WindowsHelloAvailability.unknown),
      ]) {
        native.availability = <String, Object?>{'availability': raw, 'keysSupported': true};
        final WindowsHelloStatus s = await auth.helloStatus();
        expect(s.availability, expected, reason: raw);
        expect(s.supportsKey, expected == WindowsHelloAvailability.available, reason: raw);
      }
      native.availability = <String, Object?>{'availability': 'available', 'keysSupported': false};
      expect((await auth.helloStatus()).supportsKey, isFalse, reason: 'ключи не поддерживаются — режим гейта W1');
      expect(native.methods.toSet(), <String>{'availability'}, reason: 'createKey и sign без нажатия не вызываются');
    });

    test('канала нет или сбой — unknown, без исключений', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
      expect(await auth.helloStatus(), WindowsHelloStatus.unknown);
      expect(await auth.createHelloKey(_userA), isA<BiometricResult<String>>());
      expect((await auth.createHelloKey(_userA)).error, BiometricError.notAvailable);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        native.handle,
      );
      native.error = PlatformException(code: 'bad_args');
      expect(await auth.helloStatus(), WindowsHelloStatus.unknown);
      expect((await auth.signHelloChallenge(_userA, _challenge)).error, BiometricError.failed);
    });
  });

  group('T-BIO-036: WindowsHelloKeyAuthenticator (подменный канал)', () {
    test('createKey: имя optomstroy.hello.v1.<userId строчными>, открытый ключ — base64url без «=»', () async {
      final BiometricResult<String> r = await auth.createHelloKey(_userA);
      expect(r.isSuccess, isTrue);
      expect(r.value, _b64(<int>[0x30, 0x82, 0x01, 0x22, 0xfb, 0xff]));
      expect(r.value, isNot(contains('=')));
      expect(native.calls.single.method, 'createKey');
      expect(native.calls.single.arguments, <String, Object?>{'name': 'optomstroy.hello.v1.${_userA.toLowerCase()}'});
      expect(helloKeyName(_userA), helloKeyName(_userA.toLowerCase()));
    });

    test('sign: UTF-8 challenge входа → подпись base64url; не challenge входа — без вызова канала', () async {
      final BiometricResult<String> r = await auth.signHelloChallenge(_userB, _challenge);
      expect(r.value, _b64(<int>[1, 2, 3, 0xfe, 0xff]));
      final MethodCall call = native.calls.single;
      expect(call.method, 'sign');
      final Map<Object?, Object?> args = call.arguments as Map<Object?, Object?>;
      expect(args['name'], 'optomstroy.hello.v1.$_userB');
      expect(args['data'], utf8.encode(_challenge));
      expect(
        (await auth.signHelloChallenge(_userB, 'произвольная строка')).error,
        BiometricError.failed,
        reason: 'ключ подписывает только challenge входа',
      );
      expect((await auth.signHelloChallenge('  ', _challenge)).error, BiometricError.failed);
      expect(native.calls, hasLength(1));
    });

    test('статусы натива → BiometricError: отмена, «предпочитаю пароль», пропажа ключа, блокировка, сбой', () async {
      for (final (String status, BiometricError create, BiometricError sign)
          in <(String, BiometricError, BiometricError)>[
            ('cancelled', BiometricError.cancelled, BiometricError.cancelled),
            ('user_prefers_password', BiometricError.cancelled, BiometricError.cancelled),
            ('not_found', BiometricError.notEnrolled, BiometricError.noCredential),
            ('security_device_locked', BiometricError.lockout, BiometricError.lockout),
            ('unknown_error', BiometricError.failed, BiometricError.failed),
            ('already_exists', BiometricError.failed, BiometricError.failed),
            ('failed', BiometricError.failed, BiometricError.failed),
          ]) {
        native
          ..create = <String, Object?>{'status': status}
          ..sign = <String, Object?>{'status': status};
        expect((await auth.createHelloKey(_userA)).error, create, reason: 'createKey $status');
        expect((await auth.signHelloChallenge(_userA, _challenge)).error, sign, reason: 'sign $status');
      }
      native.create = <String, Object?>{'status': 'ok'};
      expect(
        (await auth.createHelloKey(_userA)).error,
        BiometricError.failed,
        reason: 'ok без ключа — не по протоколу',
      );
    });

    test('порт: возможности и диалог — гейт W1; clear ключ не удаляет (ключ переживает выход, BIO-040)', () async {
      final BiometricCapability c = await auth.capability();
      expect(c.kind, BiometricKind.windowsHello);
      expect(c.cryptoBinding, isFalse);
      expect((await auth.confirmPresence(const BiometricPromptText(title: 't', cancel: 'c'))).isSuccess, isTrue);
      expect(gate.presence, 1);
      expect(await auth.hasStoredSecret(), isFalse);
      expect((await auth.read(const BiometricPromptText(title: 't', cancel: 'c'))).error, BiometricError.notAvailable);
      await auth.clear();
      expect(native.calls, isEmpty, reason: 'выход, logout-all и SESSION_REVOKED ключ Windows Hello не трогают');
      expect(await auth.deleteHelloKey(_userA), isTrue);
      expect(native.calls.single.method, 'deleteKey');
      native.delete = <String, Object?>{'status': 'failed'};
      expect(await auth.deleteHelloKey(_userA), isFalse);
    });
  });

  group('признак auth.hello_key_users (09 §8.5, BIO-038; 11 SEC-145)', () {
    test('вне ключей сессии и планшета; по userId; гейт W1 — отдельный список', () async {
      expect(SecureKey.helloKeyUsers.storageKey, 'auth.hello_key_users');
      expect(SecureKey.session, isNot(contains(SecureKey.helloKeyUsers)));
      expect(SecureKey.kiosk, isNot(contains(SecureKey.helloKeyUsers)));
      expect(
        SecureKey.values,
        contains(SecureKey.helloKeyUsers),
        reason: 'becomeKiosk удаляет все ключи, кроме device.id',
      );
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final HelloKeyUsers keys = HelloKeyUsers(storage);
      expect(await keys.add(_userA), isTrue);
      expect(await keys.contains(_userA.toLowerCase()), isTrue);
      expect(await keys.contains(_userB), isFalse);
      expect(await HelloGateUsers(storage).contains(_userA), isFalse);
      // Выход и SESSION_REVOKED удаляют только ключи сессии.
      for (final SecureKey k in SecureKey.session) {
        await storage.delete(k);
      }
      expect(await keys.contains(_userA), isTrue);
      expect(await keys.remove(_userA), isTrue);
      expect(storage.values.containsKey(SecureKey.helloKeyUsers), isFalse);
    });
  });

  group('T-BIO-032 (статическая часть): протокол Dart = натив windows/runner', () {
    final File cpp = File('windows/runner/hello_channel.cpp');
    final File header = File('windows/runner/hello_channel.h');

    test('имя канала, методы, поля, статусы и префиксы совпадают с hello_channel.cpp', () {
      final String src = cpp.readAsStringSync();
      for (final String literal in <String>[
        WindowsHelloKeyChannel.name,
        'availability',
        'keysSupported',
        'createKey',
        'publicKey',
        'sign',
        'signature',
        'deleteKey',
        'name',
        'data',
        'status',
        WindowsHelloKeyChannel.statusOk,
        WindowsHelloKeyChannel.statusCancelled,
        WindowsHelloKeyChannel.statusNotFound,
        WindowsHelloKeyChannel.statusUserPrefersPassword,
        WindowsHelloKeyChannel.statusAlreadyExists,
        WindowsHelloKeyChannel.statusSecurityDeviceLocked,
        WindowsHelloKeyChannel.statusUnknownError,
        WindowsHelloKeyChannel.statusFailed,
        helloKeyPrefix,
        helloChallengePrefix,
        for (final WindowsHelloAvailability a in WindowsHelloAvailability.values) a.value,
      ]) {
        expect(src, contains('"$literal"'), reason: literal);
      }
      // Ключ создаётся с заменой прежнего и отдаёт только SPKI; challenge и имя проверяются до WinRT.
      expect(src, contains('KeyCredentialCreationOption::ReplaceExisting'));
      expect(src, contains('X509SubjectPublicKeyInfo'));
      expect(src, contains('IsChallenge'));
      expect(src, contains('IsKeyName'));
      expect(header.readAsStringSync(), contains('class HelloChannel'));
    });

    test('канал зарегистрирован в окне и собирается с C++/WinRT из Windows SDK', () {
      final String window = File('windows/runner/flutter_window.cpp').readAsStringSync();
      expect(window, contains('std::make_unique<optomstroy::HelloChannel>'));
      expect(window.indexOf('hello_channel_ = nullptr'), lessThan(window.indexOf('flutter_controller_ = nullptr')));
      final String cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
      expect(cmake, contains('add_library(hello_channel STATIC'));
      expect(cmake, contains('target_link_libraries(\${BINARY_NAME} PRIVATE hello_channel)'));
      expect(cmake, contains('windowsapp.lib'));
    });
  });
}

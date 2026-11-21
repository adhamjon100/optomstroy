// Вход по ключу Windows Hello без PIN приложения (W2; 15 ADR-116 п. 3; 09 §9.2 «Вход по ключу Windows Hello» п. 2–4,
// BIO-039; 08 §4.1.8, §4.1.10) — 12 T-BIO-036 (3)–(7), уровни data и domain: тела `POST /auth/unlock/challenge` и
// `POST /auth/unlock {method: hello_key}`, `helloKeyInvalidated` с PIN, адаптер SCR-08 (кнопка по признаку
// `auth.hello_key_users`, подпись, снятие признака), use case `UnlockWithHelloKey` (порядок: challenge → диалог →
// вход; отказы). Диалог Windows Hello не вызывается: порт и транспорт подменены.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/biometrics/hello_key_users.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/network/dio_client.dart';
import 'package:optomstroy/core/network/etag_cache.dart';
import 'package:optomstroy/core/network/models/problem.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';
import 'package:optomstroy/features/auth/data/datasources/auth_remote_data_source.dart';
import 'package:optomstroy/features/auth/data/device_info_source.dart';
import 'package:optomstroy/features/auth/data/dto/auth_dtos.dart';
import 'package:optomstroy/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/domain/usecases/unlock_session.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../core/storage/in_memory_secure_storage.dart';
import '../support/fakes.dart';

const String _deviceId = '1b4e28ba-2d11-4d4f-9f4a-0c3a6f6e7d01';
const ClientMeta _meta = ClientMeta(appVersion: '1.4.2+87', platform: ClientPlatform.windows, deviceId: _deviceId);
const String _userA = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f01';
const String _userB = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f02';
const String _signature = 'c2lnbmF0dXJl';

Map<String, Object?> _unlockOk(String access, String refresh) => <String, Object?>{
  'accessToken': access,
  'accessExpiresIn': 900,
  'refreshToken': refresh,
  'refreshExpiresAt': '2026-10-29T09:00:00Z',
  'sid': 's',
  'amr': <String>['sms', 'bio'],
};

Map<String, Object?> _unlockRequired(String reason) =>
    problem('UNLOCK_REQUIRED', 401, extra: <String, Object?>{'reason': reason});

final class _Device implements DeviceInfoSource {
  @override
  Future<AuthDeviceInfoDto> read() async => const AuthDeviceInfoDto(
    name: 'POS-1',
    platform: 'windows',
    appVersion: '1.4.2+87',
    osVersion: '23H2',
    biometricClass: 'windows_hello',
  );
}

/// AuthRepositoryImpl поверх настоящего DioClient и подменного транспорта.
final class _Env {
  _Env(FakeHandler handler) {
    adapter = FakeAdapter(handler);
    storage = InMemorySecureStorage(<SecureKey, String>{
      SecureKey.refreshToken: 'ref-1', // check-secrets: allow (тестовое значение)
    });
    tokens = TokenStore(storage);
    final Dio dio = DioClient.create(
      DioClientDeps(
        config: AppConfig.fromMap(const <String, String>{'API_BASE_URL': 'https://api.test/api/v1', 'ENV': 'dev'}),
        meta: () => _meta,
        tokens: tokens,
        appVersion: AppVersionController(currentVersion: '1.4.2+87', platform: 'windows', sink: (_, _) async {}),
        etagCache: EtagCache(),
        adapter: adapter,
        sleep: (_) async {},
      ),
    );
    repo = AuthRepositoryImpl(
      remote: AuthRemoteDataSource(dio),
      tokens: tokens,
      device: _Device(),
      clock: FixedClock(DateTime.utc(2026, 11, 8, 9)),
    );
  }

  late final FakeAdapter adapter;
  late final InMemorySecureStorage storage;
  late final TokenStore tokens;
  late final AuthRepositoryImpl repo;
}

Map<String, Object?> _body(Object? data) => Map<String, Object?>.from(data! as Map<dynamic, dynamic>);

/// Порт core Windows с ключом Windows Hello: исход подписи задаёт тест.
final class _KeyAuth implements BiometricAuthenticator, BiometricHelloKey {
  BiometricResult<String> signResult = const BiometricResult<String>.success(_signature);
  final List<(String, String)> signed = <(String, String)>[];
  final List<String> deleted = <String>[];

  @override
  Future<BiometricCapability> capability() async => const BiometricCapability(
    kind: BiometricKind.windowsHello,
    availability: BiometricAvailability.available,
    cryptoBinding: false,
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
  Future<void> clear() async {}

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult<void>.success(null);

  @override
  Future<WindowsHelloStatus> helloStatus() async =>
      const WindowsHelloStatus(availability: WindowsHelloAvailability.available, keysSupported: true);

  @override
  Future<BiometricResult<String>> createHelloKey(String userId) async => const BiometricResult<String>.success('spki');

  @override
  Future<BiometricResult<String>> signHelloChallenge(String userId, String challenge) async {
    signed.add((userId, challenge));
    return signResult;
  }

  @override
  Future<bool> deleteHelloKey(String userId) async {
    deleted.add(userId);
    return true;
  }
}

/// Порт без ключа (гейт W1 до ADR-116).
final class _GateOnly implements BiometricAuthenticator {
  @override
  Future<BiometricCapability> capability() async => const BiometricCapability(
    kind: BiometricKind.windowsHello,
    availability: BiometricAvailability.available,
    cryptoBinding: false,
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
  Future<void> clear() async {}

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult<void>.success(null);
}

/// Порт SCR-08 с ключом для use case: исход подписи и снятия признака задаёт тест.
final class _KeyUnlock implements BiometricUnlock, HelloKeyUnlock {
  HelloKeySignResult sign = const HelloKeySigned(_signature);

  @override
  Future<BiometricUnlockKind> capability() async => BiometricUnlockKind.windowsHelloGate;

  @override
  Future<BiometricUnlockKind> kind() async => BiometricUnlockKind.windowsHelloKey;

  @override
  Future<BiometricSecretResult> readSecret() async => const BiometricSecretUnavailable();

  @override
  Future<bool> storeSecret(String secret) async => false;

  @override
  Future<void> clear() async {}

  @override
  Future<bool> confirmPresence() async => false;

  final List<String> challenges = <String>[];
  int forgotten = 0;

  @override
  Future<HelloKeySignResult> signHelloChallenge(String challenge) async {
    challenges.add(challenge);
    return sign;
  }

  @override
  Future<void> forgetHelloKey() async => forgotten++;
}

void main() {
  test('HelloKeyRefusal = причины UNLOCK_REQUIRED контракта (hello_key_unavailable, hello_key_invalid)', () {
    expect(HelloKeyRefusal.unavailable, UnlockRequiredReason.helloKeyUnavailable.value);
    expect(HelloKeyRefusal.invalid, UnlockRequiredReason.helloKeyInvalid.value);
    expect(UnlockMethod.helloKey.value, AuthUnlockRequestDto.methodHelloKey);
  });

  group('T-BIO-036 (4)–(6): AuthRepositoryImpl, тела W2', () {
    test(
      'challenge: POST /auth/unlock/challenge {method: hello_key, refreshToken}, публичный; refresh не ротируется',
      () async {
        final _Env env = _Env(
          (RequestOptions o) async =>
              json(200, <String, Object?>{'challenge': kHelloChallenge, 'expiresAt': '2026-11-08T09:02:00Z'}),
        );
        expect((await env.repo.helloKeyChallenge()).valueOrNull, kHelloChallenge);
        final ({Object? data, Map<String, Object?> headers, String method, String path}) req =
            env.adapter.requests.single;
        expect(req.path, AuthRemoteDataSource.unlockChallengePath);
        expect(req.method, 'POST');
        expect(_body(req.data), <String, Object?>{'method': 'hello_key', 'refreshToken': 'ref-1'});
        expect(req.headers.containsKey(ApiHeaders.authorization), isFalse);
        expect(req.headers[ApiHeaders.deviceId], _deviceId);
        expect(await env.storage.read(SecureKey.refreshToken), 'ref-1');
      },
    );

    test(
      'challenge: 401 UNLOCK_REQUIRED hello_key_unavailable → причина в AuthFailure, без /auth/refresh, сессия цела; '
      'чужой challenge — ошибка разбора, подписи нет',
      () async {
        int call = 0;
        final _Env env = _Env((RequestOptions o) async {
          call++;
          return call == 1
              ? json(401, _unlockRequired('hello_key_unavailable'))
              : json(200, <String, Object?>{'challenge': 'anything-else', 'expiresAt': '2026-11-08T09:02:00Z'});
        });
        final AuthFailure f = (await env.repo.helloKeyChallenge()).failureOrNull! as AuthFailure;
        expect(f.reason, AuthReason.unlockRequired);
        expect(f.unlockReason, HelloKeyRefusal.unavailable);
        expect(env.adapter.countPath('/auth/refresh'), 0);
        expect(await env.storage.read(SecureKey.refreshToken), 'ref-1');
        expect((await env.repo.helloKeyChallenge()).isSuccess, isFalse);
      },
    );

    test('вход: POST /auth/unlock {method: hello_key, refreshToken, signature} → токены сохранены (ротация)', () async {
      final _Env env = _Env((RequestOptions o) async => json(200, _unlockOk('acc-2', 'ref-2')));
      expect((await env.repo.unlockWithHelloKey(signature: _signature)).isSuccess, isTrue);
      expect(env.adapter.requests.single.path, AuthRemoteDataSource.unlockPath);
      expect(_body(env.adapter.requests.single.data), <String, Object?>{
        'method': 'hello_key',
        'refreshToken': 'ref-1',
        'signature': _signature,
      });
      expect(env.tokens.accessToken, 'acc-2');
      expect(await env.storage.read(SecureKey.refreshToken), 'ref-2');
    });

    test(
      'вход: 401 hello_key_invalid — причина, refresh не тронут; без сессии — SESSION_REVOKED без запроса',
      () async {
        final _Env env = _Env((RequestOptions o) async => json(401, _unlockRequired('hello_key_invalid')));
        final AuthFailure f = (await env.repo.unlockWithHelloKey(signature: _signature)).failureOrNull! as AuthFailure;
        expect(f.unlockReason, HelloKeyRefusal.invalid);
        expect(await env.storage.read(SecureKey.refreshToken), 'ref-1');
        await env.storage.delete(SecureKey.refreshToken);
        final int before = env.adapter.requests.length;
        expect(((await env.repo.helloKeyChallenge()).failureOrNull! as AuthFailure).reason, AuthReason.sessionRevoked);
        expect(
          ((await env.repo.unlockWithHelloKey(signature: _signature)).failureOrNull! as AuthFailure).reason,
          AuthReason.sessionRevoked,
        );
        expect(env.adapter.requests, hasLength(before));
      },
    );

    test('(6) PIN после пропажи ключа: {method: pin, …, helloKeyInvalidated: true}; без пропажи поля нет', () async {
      final _Env env = _Env((RequestOptions o) async => json(200, _unlockOk('acc-2', 'ref-2')));
      await env.repo.unlockWithPin(pin: '482913', helloKeyInvalidated: true);
      expect(_body(env.adapter.requests.last.data), <String, Object?>{
        'method': 'pin',
        'refreshToken': 'ref-1',
        'pin': '482913',
        'helloKeyInvalidated': true,
      });
      await env.repo.unlockWithPin(pin: '482913');
      expect(_body(env.adapter.requests.last.data).containsKey('helloKeyInvalidated'), isFalse);
    });
  });

  group('T-BIO-036 (3), (5)–(7): адаптер SCR-08 и признак auth.hello_key_users', () {
    late InMemorySecureStorage storage;
    late _KeyAuth key;

    setUp(() {
      storage = InMemorySecureStorage();
      key = _KeyAuth();
    });

    BiometricUnlockAdapter adapter(BiometricAuthenticator auth, [String? userId = _userA]) =>
        BiometricUnlockAdapter(authenticator: auth, storage: storage, currentUserId: () async => userId);

    test('кнопка «Войти через Windows Hello» — только у пользователя с признаком; ключ важнее гейта', () async {
      await HelloGateUsers(storage).add(_userA);
      expect(await adapter(key).kind(), BiometricUnlockKind.windowsHelloGate);
      await HelloKeyUsers(storage).add(_userA);
      expect(await adapter(key).kind(), BiometricUnlockKind.windowsHelloKey);
      expect(await adapter(key, _userB).kind(), BiometricUnlockKind.none, reason: 'признак A не виден B');
      expect(await adapter(key, null).kind(), BiometricUnlockKind.none, reason: 'кэш без userId — кнопки нет');
      expect(
        await adapter(_GateOnly()).kind(),
        BiometricUnlockKind.windowsHelloGate,
        reason: 'порт без ключа — режим гейта W1',
      );
      expect(await adapter(key).capability(), BiometricUnlockKind.windowsHelloGate, reason: 'biometricClass прежний');
    });

    test('(7) выход, SESSION_REVOKED и вход по SMS признак не снимают (ключи сессии удалены)', () async {
      await HelloKeyUsers(storage).add(_userA);
      storage.values[SecureKey.refreshToken] = 'ref-1'; // check-secrets: allow (тестовое значение)
      for (final SecureKey k in SecureKey.session) {
        await storage.delete(k);
      }
      await key.clear();
      expect(await adapter(key).kind(), BiometricUnlockKind.windowsHelloKey);
      expect(key.deleted, isEmpty);
    });

    test('подпись: успех, отмена, пропажа ключа, иная ошибка; пользователь неизвестен — без диалога', () async {
      expect(await adapter(key).signHelloChallenge(kHelloChallenge), isA<HelloKeySigned>());
      expect(key.signed.single, (_userA, kHelloChallenge));
      for (final (BiometricError e, Type expected) in <(BiometricError, Type)>[
        (BiometricError.cancelled, HelloKeySignCancelled),
        (BiometricError.noCredential, HelloKeyLost),
        (BiometricError.lockout, HelloKeySignFailed),
        (BiometricError.failed, HelloKeySignFailed),
      ]) {
        key.signResult = BiometricResult<String>.failure(e);
        expect((await adapter(key).signHelloChallenge(kHelloChallenge)).runtimeType, expected, reason: e.name);
      }
      final int before = key.signed.length;
      expect(await adapter(key, null).signHelloChallenge(kHelloChallenge), isA<HelloKeySignFailed>());
      expect(await adapter(_GateOnly()).signHelloChallenge(kHelloChallenge), isA<HelloKeySignFailed>());
      expect(key.signed, hasLength(before));
    });

    test('forgetHelloKey: признак ключа своего пользователя снят, ключ удалён; гейт и чужой ключ — на месте', () async {
      await HelloKeyUsers(storage).add(_userA);
      await HelloKeyUsers(storage).add(_userB);
      await HelloGateUsers(storage).add(_userA);
      await adapter(key).forgetHelloKey();
      expect(await HelloKeyUsers(storage).read(), <String>{_userB});
      expect(key.deleted, <String>[_userA]);
      expect(await adapter(key).kind(), BiometricUnlockKind.windowsHelloGate);
    });
  });

  group('T-BIO-036 (4)–(6): UnlockWithHelloKey', () {
    late FakeAuthRepository repo;
    late _KeyUnlock port;

    setUp(() {
      repo = FakeAuthRepository();
      port = _KeyUnlock();
    });

    test('challenge → подпись → вход без PIN', () async {
      final HelloKeyUnlockOutcome out = await UnlockWithHelloKey(repo, port).call();
      expect(out, isA<HelloKeyUnlocked>());
      expect(repo.helloChallenges, 1);
      expect(port.challenges, <String>[kHelloChallenge]);
      expect(repo.helloKeyUnlocks, <String>[_signature]);
      expect(repo.pinUnlocks, isEmpty);
    });

    test('challenge отклонён hello_key_unavailable — диалога нет, признак снят', () async {
      repo.challengeResult = const FailureResult<String>(
        AuthFailure(AuthReason.unlockRequired, unlockReason: 'hello_key_unavailable'),
      );
      expect(await UnlockWithHelloKey(repo, port).call(), isA<HelloKeyUnlockUnavailable>());
      expect(port.challenges, isEmpty);
      expect(port.forgotten, 1);
    });

    test('отмена диалога и hello_key_invalid — ключ не трогается; пропажа ключа — признак снят', () async {
      port.sign = const HelloKeySignCancelled();
      expect(await UnlockWithHelloKey(repo, port).call(), isA<HelloKeyUnlockRejected>());
      expect(repo.helloKeyUnlocks, isEmpty);
      port.sign = const HelloKeySigned(_signature);
      repo.helloKeyResult = const FailureResult<UnlockSuccess>(
        AuthFailure(AuthReason.unlockRequired, unlockReason: 'hello_key_invalid'),
      );
      expect(await UnlockWithHelloKey(repo, port).call(), isA<HelloKeyUnlockRejected>());
      expect(port.forgotten, 0);
      repo.helloKeyResult = const FailureResult<UnlockSuccess>(
        AuthFailure(AuthReason.unlockRequired, unlockReason: 'hello_key_unavailable'),
      );
      expect(await UnlockWithHelloKey(repo, port).call(), isA<HelloKeyUnlockUnavailable>());
      expect(port.forgotten, 1);
      port.sign = const HelloKeyLost();
      expect(await UnlockWithHelloKey(repo, port).call(), isA<HelloKeyUnlockKeyLost>());
      expect(port.forgotten, 2);
    });

    // Пакет own-server:GAP-APP (пробел 9 итогового отчёта): отказ по сессии и просроченный challenge ключ не удаляют
    // (09 BIO-040); путь через слой сессии и настоящий адаптер — `session_ui/hello_key_refusal_keeps_key_test.dart`.
    test('T-BIO-036 (8): challenge → SESSION_REVOKED — диалога нет, ключ не трогается; POST /auth/unlock → '
        'SESSION_REVOKED и просроченный challenge (hello_key_invalid) — тоже', () async {
      repo.challengeResult = const FailureResult<String>(AuthFailure(AuthReason.sessionRevoked));
      final HelloKeyUnlockOutcome revoked = await UnlockWithHelloKey(repo, port).call();
      expect(revoked, isA<HelloKeyUnlockFailed>());
      expect(((revoked as HelloKeyUnlockFailed).failure as AuthFailure).reason, AuthReason.sessionRevoked);
      expect(port.challenges, isEmpty, reason: 'отказ challenge — до диалога Windows Hello');
      expect(repo.helloKeyUnlocks, isEmpty);
      expect(port.forgotten, 0);

      repo.challengeResult = const Success<String>(kHelloChallenge);
      repo.helloKeyResult = const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.sessionRevoked));
      expect(await UnlockWithHelloKey(repo, port).call(), isA<HelloKeyUnlockFailed>());
      expect(port.challenges, <String>[kHelloChallenge]);
      expect(port.forgotten, 0);

      // Challenge живёт 120 с (08 `AuthUnlockChallenge.expiresAt`); после — `UNLOCK_REQUIRED hello_key_invalid`.
      repo.helloKeyResult = const FailureResult<UnlockSuccess>(
        AuthFailure(AuthReason.unlockRequired, unlockReason: HelloKeyRefusal.invalid),
      );
      expect(await UnlockWithHelloKey(repo, port).call(), isA<HelloKeyUnlockRejected>());
      expect(port.forgotten, 0);
    });

    test('сеть и отзыв сессии — как у PIN; порт без ключа — без запросов', () async {
      repo.challengeResult = const FailureResult<String>(NetworkFailure(NetworkFailureKind.offline));
      final HelloKeyUnlockOutcome offline = await UnlockWithHelloKey(repo, port).call();
      expect(offline, isA<HelloKeyUnlockFailed>());
      expect((offline as HelloKeyUnlockFailed).failure, isA<NetworkFailure>());
      repo.challengeResult = const Success<String>(kHelloChallenge);
      repo.helloKeyResult = const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.sessionRevoked));
      expect(await UnlockWithHelloKey(repo, port).call(), isA<HelloKeyUnlockFailed>());
      final int calls = repo.helloChallenges;
      expect(
        await UnlockWithHelloKey(repo, FakeBiometricUnlock(kindValue: BiometricUnlockKind.windowsHelloGate)).call(),
        isA<HelloKeyUnlockUnavailable>(),
      );
      expect(repo.helloChallenges, calls);
    });
  });
}

// SCR-42 «Защита входа» на Windows: ключ Windows Hello (W2 — вход без PIN приложения; 15 ADR-116 п. 3; 09 §9.2
// «Вход по ключу Windows Hello» п. 1, §9.5 п. 3–4, BIO-038, BIO-040; 02 SCR-42.4 UI-42-010, UI-42-029,
// AC-UI-42-021, AC-UI-42-022) — 12 T-BIO-036 (1), (2) на уровне data: режим ключа или гейта по
// `security.windowsHelloKeyAllowed` и `availability` канала, тело `POST /me/biometrics` с `helloKey`, отказы сервера
// (созданный ключ удаляется), выключение, признак `auth.hello_key_users` по `userId`, сверка с `GET /me`. Порт core —
// подмена с `BiometricHelloKey` (диалог Windows Hello не вызывается).
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/biometrics/hello_key_users.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/network/interceptors/session_hooks.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/settings/data/datasources/settings_api.dart';
import 'package:optomstroy/features/settings/data/repositories/login_protection_repository_impl.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../core/storage/in_memory_secure_storage.dart';
import '../support/settings_fakes.dart';

const String _userA = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f01';
const String _userB = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f02';
const String _spki = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA';
const BiometricPromptCopy _copy = BiometricPromptCopy(title: 't', cancel: 'c');

/// Порт Windows с ключом Windows Hello: доступность и исходы задаёт тест, вызовы записываются.
final class _HelloKeyAuth implements BiometricAuthenticator, BiometricHelloKey {
  WindowsHelloStatus status = const WindowsHelloStatus(
    availability: WindowsHelloAvailability.available,
    keysSupported: true,
  );
  BiometricResult<String> createResult = const BiometricResult<String>.success(_spki);
  final List<String> created = <String>[];
  final List<String> deleted = <String>[];
  int presence = 0;

  @override
  Future<BiometricCapability> capability() async => BiometricCapability(
    kind: BiometricKind.windowsHello,
    availability: status.isAvailable ? BiometricAvailability.available : BiometricAvailability.notEnrolled,
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
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async {
    presence++;
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<WindowsHelloStatus> helloStatus() async => status;

  @override
  Future<BiometricResult<String>> createHelloKey(String userId) async {
    created.add(userId);
    return createResult;
  }

  @override
  Future<BiometricResult<String>> signHelloChallenge(String userId, String challenge) async =>
      const BiometricResult<String>.failure(BiometricError.failed);

  @override
  Future<bool> deleteHelloKey(String userId) async {
    deleted.add(userId);
    return true;
  }
}

Map<String, Object?> _me({bool keyAllowed = true, bool pinSet = true, String platform = 'windows_hello_gate'}) =>
    <String, Object?>{
      'id': _userA,
      'kind': 'staff',
      'status': 'active',
      'roles': <String>['seller'],
      'permissions': <String>[],
      'permissionsVersion': 1,
      'security': <String, Object?>{
        'pinSet': pinSet,
        'biometricsEnabled': false,
        'biometricsPlatform': platform,
        'biometricWeakAllowed': false,
        'windowsHelloKeyAllowed': keyAllowed,
      },
      'settings': <String, Object?>{'idleLockMinutes': 30, 'rowVersion': 1},
    };

Map<String, Object?> _consents() => <String, Object?>{
  'items': <Object?>[],
  'required': <Object?>[
    <String, Object?>{'kind': 'biometrics_device', 'currentVersion': '2026-10-01'},
  ],
};

Dio _dio(FakeAdapter adapter) => Dio(BaseOptions(baseUrl: 'https://api.test/api/v1'))..httpClientAdapter = adapter;

void main() {
  late InMemorySecureStorage storage;
  late _HelloKeyAuth bio;

  /// Запросы `POST /me/biometrics` (с `extra` — операция step-up).
  late List<RequestOptions> posts;

  setUp(() {
    storage = InMemorySecureStorage();
    bio = _HelloKeyAuth();
    posts = <RequestOptions>[];
  });

  LoginProtectionRepositoryImpl repo(FakeAdapter adapter, {String? userId = _userA}) => LoginProtectionRepositoryImpl(
    api: SettingsApi(_dio(adapter), newKey: () => 'idem-1'),
    biometrics: bio,
    storage: storage,
    obtainStepUp: (_) async => 'step-up-token',
    clock: FixedClock(DateTime.utc(2026, 11, 8, 9)),
    fallbackLabel: BiometricPlatformLabel.windows,
    currentUserId: () async => userId,
  );

  /// Транспорт: `GET /me` — [me], `GET /me/consents`, `POST /me/biometrics` — [biometrics].
  FakeAdapter server(Map<String, Object?> me, {ResponseBody Function(RequestOptions o)? biometrics}) =>
      FakeAdapter((RequestOptions o) async {
        if (o.path.endsWith('/me/consents')) return json(200, _consents());
        if (o.path.endsWith('/me/biometrics')) {
          posts.add(o);
          return biometrics?.call(o) ?? json(200, <String, Object?>{'enabled': true});
        }
        return json(200, me);
      });

  Iterable<RequestOptions> biometricsPosts(FakeAdapter a) => posts;

  group('T-BIO-036 (2): режим UI-42-010 и причина UI-42-029', () {
    test('ключ разрешён сервером и поддерживается — режим ключа (W2); иначе гейт (W1)', () async {
      expect((await repo(server(_me())).load()).valueOrNull!.support, BiometricSupport.windowsHelloKey);
      expect(
        (await repo(server(_me(keyAllowed: false))).load()).valueOrNull!.support,
        BiometricSupport.windowsHelloGate,
        reason: 'windowsHelloKeyAllowed=false (AUTH_WINDOWS_HELLO_KEY=off, правило personal) — гейт',
      );
      bio.status = const WindowsHelloStatus(availability: WindowsHelloAvailability.available, keysSupported: false);
      expect(
        (await repo(server(_me())).load()).valueOrNull!.support,
        BiometricSupport.windowsHelloGate,
        reason: 'KeyCredentialManager.IsSupportedAsync = false — гейт',
      );
    });

    test('Windows Hello недоступен — тумблер disabled с причиной канала', () async {
      for (final (WindowsHelloAvailability a, WindowsHelloIssue issue)
          in <(WindowsHelloAvailability, WindowsHelloIssue)>[
            (WindowsHelloAvailability.notConfigured, WindowsHelloIssue.notConfigured),
            (WindowsHelloAvailability.deviceNotPresent, WindowsHelloIssue.noDevice),
            (WindowsHelloAvailability.disabledByPolicy, WindowsHelloIssue.disabledByPolicy),
            (WindowsHelloAvailability.deviceBusy, WindowsHelloIssue.busy),
          ]) {
        bio.status = WindowsHelloStatus(availability: a, keysSupported: false);
        final LoginProtectionState s = (await repo(server(_me())).load()).valueOrNull!;
        expect(s.support, BiometricSupport.unavailable, reason: a.value);
        expect(s.helloIssue, issue, reason: a.value);
      }
    });

    test('windowsSupportOf: канал не ответил — как до канала (local_auth), режим гейта', () {
      const BiometricCapability available = BiometricCapability(
        kind: BiometricKind.windowsHello,
        availability: BiometricAvailability.available,
        cryptoBinding: false,
      );
      expect(
        LoginProtectionRepositoryImpl.windowsSupportOf(
          available,
          WindowsHelloStatus.unknown,
          keyAllowed: true,
          keyCapable: true,
        ),
        (support: BiometricSupport.windowsHelloGate, issue: null),
      );
      expect(
        LoginProtectionRepositoryImpl.windowsSupportOf(
          windowsHello,
          const WindowsHelloStatus(availability: WindowsHelloAvailability.available, keysSupported: true),
          keyAllowed: true,
          keyCapable: false,
        ).support,
        BiometricSupport.windowsHelloGate,
        reason: 'порт без ключа (сборка без канала) — гейт',
      );
    });
  });

  group('T-BIO-036 (1): включение ключа Windows Hello (AC-UI-42-021, AC-UI-42-022)', () {
    test('createKey → POST /me/biometrics {windows_hello, helloKey, consent} без токена → признак по userId; '
        'гейт этого пользователя снят, гейт другого — нет', () async {
      await HelloGateUsers(storage).add(_userA);
      await HelloGateUsers(storage).add(_userB);
      final FakeAdapter adapter = server(_me());
      final LoginProtectionRepositoryImpl r = repo(adapter);
      expect((await r.load()).valueOrNull!.biometricsEnabled, isFalse, reason: 'гейт включён, ключ — нет ([ВЫВОД])');
      expect(await r.enableBiometrics(_copy), BiometricToggleOutcome.enabled);
      expect(bio.created, <String>[_userA]);
      expect(bio.presence, 0, reason: 'в режиме ключа диалог гейта не показывается');
      final RequestOptions post = biometricsPosts(adapter).single;
      expect(post.method, 'POST');
      expect(post.extra[SessionRequestExtra.stepUpOperation], SettingsStepUpOperations.biometricsToggle);
      expect(Map<String, Object?>.from(post.data as Map<dynamic, dynamic>), <String, Object?>{
        'enabled': true,
        'biometricClass': 'windows_hello',
        'helloKey': <String, Object?>{'publicKey': _spki, 'algorithm': 'RS256', 'source': 'windows_hello'},
        'consent': <String, Object?>{'kind': 'biometrics_device', 'version': '2026-10-01', 'granted': true},
      });
      expect(await HelloKeyUsers(storage).read(), <String>{_userA});
      expect(await HelloGateUsers(storage).read(), <String>{_userB});
      expect(bio.deleted, isEmpty);
      expect((await r.load()).valueOrNull!.biometricsEnabled, isFalse, reason: '/me ещё без ключа устройства — сверка');
    });

    test(
      'после включения: свежий /me с windows_hello_key — тумблер вкл.; без ключа на сервере — признак снят',
      () async {
        await HelloKeyUsers(storage).add(_userA);
        expect((await repo(server(_me(platform: 'windows_hello_key'))).load()).valueOrNull!.biometricsEnabled, isTrue);
        expect(await HelloKeyUsers(storage).contains(_userA), isTrue);
        expect((await repo(server(_me())).load()).valueOrNull!.biometricsEnabled, isFalse);
        expect(
          await HelloKeyUsers(storage).contains(_userA),
          isFalse,
          reason: 'ключ отозван на сервере (logout-all, смена номера, personal) — SCR-08 его не предлагает',
        );
      },
    );

    for (final (String reason, BiometricToggleOutcome outcome) in <(String, BiometricToggleOutcome)>[
      ('hello_key_shared_device', BiometricToggleOutcome.helloKeySharedDevice),
      ('hello_key_disabled', BiometricToggleOutcome.helloKeyDisabled),
    ]) {
      test('200 {enabled:false, reason:$reason} → созданный ключ удалён, признака нет, исход $outcome', () async {
        await HelloGateUsers(storage).add(_userA);
        final FakeAdapter adapter = server(
          _me(),
          biometrics: (_) => json(200, <String, Object?>{'enabled': false, 'reason': reason}),
        );
        final LoginProtectionRepositoryImpl r = repo(adapter);
        await r.load();
        expect(await r.enableBiometrics(_copy), outcome);
        expect(bio.deleted, <String>[_userA]);
        expect(await HelloKeyUsers(storage).read(), isEmpty);
        expect(await HelloGateUsers(storage).contains(_userA), isTrue, reason: 'гейт не снимается при отказе');
      });
    }

    test('отмена диалога Windows Hello — запроса нет; отмена step-up и ошибка сервера — ключ удалён', () async {
      final FakeAdapter adapter = server(_me());
      final LoginProtectionRepositoryImpl r = repo(adapter);
      await r.load();
      bio.createResult = const BiometricResult<String>.failure(BiometricError.cancelled);
      expect(await r.enableBiometrics(_copy), BiometricToggleOutcome.cancelled);
      expect(biometricsPosts(adapter), isEmpty);

      bio.createResult = const BiometricResult<String>.success(_spki);
      final FakeAdapter stepUp = server(_me(), biometrics: (_) => json(403, problem('STEP_UP_REQUIRED', 403)));
      final LoginProtectionRepositoryImpl s = repo(stepUp);
      await s.load();
      expect(await s.enableBiometrics(_copy), BiometricToggleOutcome.stepUpCancelled);
      expect(bio.deleted, <String>[_userA]);
      final FakeAdapter failing = server(_me(), biometrics: (_) => json(400, problem('VALIDATION_FAILED', 400)));
      final LoginProtectionRepositoryImpl f = repo(failing);
      await f.load();
      expect(await f.enableBiometrics(_copy), BiometricToggleOutcome.failed);
      expect(bio.deleted, <String>[_userA, _userA]);
      expect(await HelloKeyUsers(storage).read(), isEmpty);
    });

    test('пользователь неизвестен — ключ не создаётся', () async {
      final LoginProtectionRepositoryImpl r = repo(server(_me()), userId: null);
      await r.load();
      // Без сессии `userId` — `Me.id` последнего GET /me.
      expect(await r.enableBiometrics(_copy), BiometricToggleOutcome.enabled);
      expect(bio.created, <String>[_userA]);
      final LoginProtectionRepositoryImpl none = repo(
        FakeAdapter((RequestOptions o) async => json(500, problem('INTERNAL', 500))),
        userId: null,
      );
      expect(await none.enableBiometrics(_copy), BiometricToggleOutcome.failed);
      expect(bio.created, hasLength(1));
    });
  });

  group('выключение ключа (09 §9.5 п. 4; 02 SCR-42.4)', () {
    test('POST {enabled:false} → ключ в Windows удалён, признак снят; гейт не включается', () async {
      await HelloKeyUsers(storage).add(_userA);
      await HelloKeyUsers(storage).add(_userB);
      final FakeAdapter adapter = server(
        _me(platform: 'windows_hello_key'),
        biometrics: (_) => json(200, <String, Object?>{'enabled': false}),
      );
      final LoginProtectionRepositoryImpl r = repo(adapter);
      expect((await r.load()).valueOrNull!.biometricsEnabled, isTrue);
      expect(await r.disableBiometrics(), BiometricToggleOutcome.disabled);
      final RequestOptions post = biometricsPosts(adapter).single;
      expect(Map<String, Object?>.from(post.data as Map<dynamic, dynamic>), <String, Object?>{'enabled': false});
      expect(bio.deleted, <String>[_userA]);
      expect(await HelloKeyUsers(storage).read(), <String>{_userB});
      expect(await HelloGateUsers(storage).read(), isEmpty);
    });

    test('сервер не ответил — ключ и признак остаются; в режиме гейта выключается гейт, ключ не трогается', () async {
      await HelloKeyUsers(storage).add(_userA);
      final FakeAdapter offline = FakeAdapter((RequestOptions o) async {
        if (o.path.endsWith('/me/biometrics')) {
          posts.add(o);
          transportError(o, DioExceptionType.connectionError);
        }
        return json(200, _me(platform: 'windows_hello_key'));
      });
      final LoginProtectionRepositoryImpl r = repo(offline);
      await r.load();
      expect(await r.disableBiometrics(), BiometricToggleOutcome.offline);
      expect(bio.deleted, isEmpty);
      expect(await HelloKeyUsers(storage).contains(_userA), isTrue);

      await HelloGateUsers(storage).add(_userA);
      posts.clear();
      final FakeAdapter gateMode = server(_me(keyAllowed: false, platform: 'windows_hello_key'));
      final LoginProtectionRepositoryImpl g = repo(gateMode);
      expect((await g.load()).valueOrNull!.support, BiometricSupport.windowsHelloGate);
      expect(await g.disableBiometrics(), BiometricToggleOutcome.disabled);
      expect(biometricsPosts(gateMode), isEmpty, reason: 'гейт — только на устройстве');
      expect(await HelloGateUsers(storage).read(), isEmpty);
      expect(await HelloKeyUsers(storage).contains(_userA), isTrue);
    });
  });
}

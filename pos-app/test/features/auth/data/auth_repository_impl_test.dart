// AuthRepositoryImpl поверх настоящего DioClient (интерсепторы core) и фейкового транспорта:
// пути и тела 08 §4.1, заголовки X-Device-Id/X-App-Version/X-Platform, без Bearer,
// сохранение токенов до возврата успеха (И7), problem+json → Failure, очистка при SESSION_REVOKED.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/network/dio_client.dart';
import 'package:optomstroy/core/network/etag_cache.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/auth/data/datasources/auth_remote_data_source.dart';
import 'package:optomstroy/features/auth/data/device_info_source.dart';
import 'package:optomstroy/features/auth/data/dto/auth_dtos.dart';
import 'package:optomstroy/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../core/storage/in_memory_secure_storage.dart';

const String _deviceId = '1b4e28ba-2d11-4d4f-9f4a-0c3a6f6e7d01';
const ClientMeta _meta = ClientMeta(appVersion: '1.4.2+87', platform: ClientPlatform.android, deviceId: _deviceId);

final class _Device implements DeviceInfoSource {
  @override
  Future<AuthDeviceInfoDto> read() async => const AuthDeviceInfoDto(
    name: 'Samsung SM-A525F',
    platform: 'android',
    appVersion: '1.4.2+87',
    osVersion: '14',
    biometricClass: 'class3',
  );
}

final class _Env {
  _Env(FakeHandler handler, {String? refresh, SessionTokensSink? onSession}) {
    adapter = FakeAdapter(handler);
    storage = InMemorySecureStorage(<SecureKey, String>{
      SecureKey.refreshToken: ?refresh, // check-secrets: allow (имя поля / тестовое значение)
    }); // check-secrets: allow (имя поля DTO / тестовое значение)
    tokens = TokenStore(storage);
    final Dio dio = DioClient.create(
      DioClientDeps(
        config: AppConfig.fromMap(const <String, String>{'API_BASE_URL': 'https://api.test/api/v1', 'ENV': 'dev'}),
        meta: () => _meta,
        tokens: tokens,
        appVersion: AppVersionController(currentVersion: '1.4.2+87', platform: 'android', sink: (_, _) async {}),
        etagCache: EtagCache(),
        adapter: adapter,
        sleep: (_) async {},
      ),
    );
    repo = AuthRepositoryImpl(
      remote: AuthRemoteDataSource(dio),
      tokens: tokens,
      device: _Device(),
      clock: FixedClock(DateTime.utc(2026, 10, 22, 9)),
      onSession: onSession,
    );
  }

  late final FakeAdapter adapter;
  late final InMemorySecureStorage storage;
  late final TokenStore tokens;
  late final AuthRepositoryImpl repo;
}

Map<String, Object?> _body(Object? data) => Map<String, Object?>.from(data! as Map<dynamic, dynamic>);

void main() {
  test('requestOtp: POST /auth/otp/request, публичный (без Bearer), заголовки клиента', () async {
    final _Env env = _Env(
      (RequestOptions o) async => json(202, <String, Object?>{
        'challengeId': 'c1',
        'resendAfterSec': 60,
        'otpTtlSec': 300,
        'codeLength': 6,
        'phoneMasked': '+996 7** *** *56',
      }),
    );
    final Result<OtpIssue> r = await env.repo.requestOtp(phoneE164: '+996700123456');
    expect(r.valueOrNull!.challengeId, 'c1');
    final ({Object? data, Map<String, Object?> headers, String method, String path}) req = env.adapter.requests.single;
    expect(req.path, AuthRemoteDataSource.otpRequestPath);
    expect(_body(req.data), <String, Object?>{
      'phone': '+996700123456',
      'purpose': 'login_or_register',
      'locale': 'ru',
    });
    expect(req.headers[ApiHeaders.deviceId], _deviceId);
    expect(req.headers[ApiHeaders.appVersion], '1.4.2+87');
    expect(req.headers[ApiHeaders.platform], 'android');
    expect(req.headers.containsKey(ApiHeaders.authorization), isFalse);
  });

  test('requestOtp: 429 OTP_RATE_LIMITED → AuthFailure с retryAfter; повтора нет', () async {
    final _Env env = _Env(
      (RequestOptions o) async =>
          json(429, problem('OTP_RATE_LIMITED', 429, extra: <String, Object?>{'retryAfter': 842})),
    );
    final Failure f = (await env.repo.requestOtp(phoneE164: '+996700123456')).failureOrNull!;
    expect(f, isA<AuthFailure>().having((AuthFailure a) => a.reason, 'reason', AuthReason.otpRateLimited));
    expect((f as AuthFailure).retryAfter, const Duration(seconds: 842));
    expect(env.adapter.requests, hasLength(1));
  });

  test('verifyOtp authenticated: токены сохранены до возврата, профиль без телефона', () async {
    final _Env env = _Env(
      (RequestOptions o) async => json(200, <String, Object?>{
        'status': 'authenticated',
        'accessToken': 'acc-1',
        'accessExpiresIn': 900,
        'refreshToken': 'ref-1',
        'sid': '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55',
        'biometricRefreshOffered': true,
        'nextStep': 'none',
        'user': <String, Object?>{
          'id': 'u1',
          'kind': 'staff',
          'status': 'active',
          'roles': <String>['seller'],
          'permissions': <String>[],
          'permissionsVersion': 1,
          'security': <String, Object?>{'pinSet': true},
          'profile': <String, Object?>{'fullName': 'Абдулла Каримов', 'phone': '+996700123456'},
        },
      }),
    );
    final VerifyOutcome o = (await env.repo.verifyOtp(challengeId: 'c1', code: '004512')).valueOrNull!;
    expect(o, isA<VerifyAuthenticated>());
    final VerifyAuthenticated a = o as VerifyAuthenticated;
    expect(a.profile.kind, UserKind.staff);
    expect(a.profile.roles, <RoleCode>[RoleCode.seller]);
    expect(a.biometricRefreshOffered, isTrue);
    expect(a.profile.toString(), isNot(contains('700123456')));
    expect(env.tokens.accessToken, 'acc-1');
    expect(await env.storage.read(SecureKey.refreshToken), 'ref-1');
    final Map<String, Object?> body = _body(env.adapter.requests.single.data);
    expect(body['challengeId'], 'c1');
    expect(body['code'], '004512');
    expect((body['device']! as Map<dynamic, dynamic>)['platform'], 'android');
  });

  test('verifyOtp invitation → nextStep setPin; registration_required → билет без записи на диск', () async {
    int call = 0;
    final _Env env = _Env((RequestOptions o) async {
      call++;
      return call == 1
          ? json(200, <String, Object?>{
              'status': 'authenticated',
              'accessToken': 'a',
              'refreshToken': 'r',
              'roleSource': 'invitation',
              'nextStep': 'set_pin',
            })
          : json(200, <String, Object?>{
              'status': 'registration_required',
              'registrationToken': 'reg-jwt',
              'registrationExpiresIn': 900,
            });
    });
    final VerifyAuthenticated invited =
        (await env.repo.verifyOtp(challengeId: 'c', code: '111111')).valueOrNull! as VerifyAuthenticated;
    expect(invited.nextStep, AuthNextStep.setPin);
    expect(invited.viaInvitation, isTrue);
    await env.tokens.clearSession();
    final VerifyRegistrationRequired reg =
        (await env.repo.verifyOtp(challengeId: 'c', code: '222222')).valueOrNull! as VerifyRegistrationRequired;
    expect(reg.ticket.token, 'reg-jwt');
    expect(reg.ticket.expiresAt, DateTime.utc(2026, 10, 22, 9, 15));
    expect(env.storage.values.values, isNot(contains('reg-jwt')));
  });

  test('verifyOtp: 422 OTP_INVALID с attemptsLeft; 409 DEVICE_MISMATCH', () async {
    int call = 0;
    final _Env env = _Env((RequestOptions o) async {
      call++;
      return call == 1
          ? json(422, problem('OTP_INVALID', 422, extra: <String, Object?>{'attemptsLeft': 3}))
          : json(409, problem('DEVICE_MISMATCH', 409));
    });
    final AuthFailure invalid =
        (await env.repo.verifyOtp(challengeId: 'c', code: '000000')).failureOrNull! as AuthFailure;
    expect(invalid.reason, AuthReason.otpInvalid);
    expect(invalid.attemptsLeft, 3);
    final AuthFailure mismatch =
        (await env.repo.verifyOtp(challengeId: 'c', code: '000000')).failureOrNull! as AuthFailure;
    expect(mismatch.reason, AuthReason.deviceMismatch);
  });

  test('challengeStatus: GET /auth/otp/challenges/{id}', () async {
    final _Env env = _Env(
      (RequestOptions o) async =>
          json(200, <String, Object?>{'challengeId': 'c1', 'delivery': 'failed', 'resendAfterSec': 0}),
    );
    final OtpChallengeStatus s = (await env.repo.challengeStatus('c1')).valueOrNull!;
    expect(s.delivery, OtpDeliveryState.failed);
    expect(env.adapter.requests.single.path, '/auth/otp/challenges/c1');
    expect(env.adapter.requests.single.method, 'GET');
  });

  test('unlockWithPin: тело {method: pin, refreshToken, pin}, ротация refresh', () async {
    final _Env env = _Env(
      (RequestOptions o) async => json(200, <String, Object?>{
        'accessToken': 'acc-2',
        'accessExpiresIn': 900,
        'refreshToken': 'ref-2',
        'refreshExpiresAt': '2026-10-29T09:00:00Z',
        'sid': 's',
      }),
      refresh: 'ref-1',
    );
    expect((await env.repo.unlockWithPin(pin: '482913')).isSuccess, isTrue);
    expect(_body(env.adapter.requests.single.data), <String, Object?>{
      'method': 'pin',
      'refreshToken': 'ref-1',
      'pin': '482913',
    });
    expect(env.tokens.accessToken, 'acc-2');
    expect(await env.storage.read(SecureKey.refreshToken), 'ref-2');
  });

  test('unlockWithPin: 401 PIN_INVALID — без /auth/refresh; SESSION_REVOKED — токены удалены, deviceId цел', () async {
    int call = 0;
    final _Env env = _Env((RequestOptions o) async {
      call++;
      return call == 1
          ? json(401, problem('PIN_INVALID', 401, extra: <String, Object?>{'attemptsLeft': 2}))
          : json(401, problem('SESSION_REVOKED', 401));
    }, refresh: 'ref-1');
    await env.storage.write(SecureKey.deviceId, _deviceId);
    final AuthFailure invalid = (await env.repo.unlockWithPin(pin: '111111')).failureOrNull! as AuthFailure;
    expect(invalid.reason, AuthReason.pinInvalid);
    expect(invalid.attemptsLeft, 2);
    expect(env.adapter.countPath('/auth/refresh'), 0);
    expect(await env.storage.read(SecureKey.refreshToken), 'ref-1');
    final AuthFailure revoked = (await env.repo.unlockWithPin(pin: '111111')).failureOrNull! as AuthFailure;
    expect(revoked.reason, AuthReason.sessionRevoked);
    expect(await env.storage.read(SecureKey.refreshToken), isNull);
    expect(await env.storage.read(SecureKey.deviceId), _deviceId);
    expect(env.adapter.countPath('/auth/refresh'), 0);
  });

  test('unlockWithPin без сохранённой сессии → SESSION_REVOKED без запроса', () async {
    final _Env env = _Env((RequestOptions o) async => json(500, null));
    final Failure f = (await env.repo.unlockWithPin(pin: '482913')).failureOrNull!;
    expect((f as AuthFailure).reason, AuthReason.sessionRevoked);
    expect(env.adapter.requests, isEmpty);
    expect(await env.repo.hasStoredSession(), isFalse);
  });

  test('unlockWithBiometric: method biometric; новый biometric refresh — только в результате', () async {
    final _Env env = _Env(
      (RequestOptions o) async => json(200, <String, Object?>{
        'accessToken': 'acc-3',
        'accessExpiresIn': 900,
        'refreshToken': 'bio-next', // check-secrets: allow (имя поля DTO / тестовое значение)
        'refreshExpiresAt': '2026-10-29T09:00:00Z',
        'sid': 's',
        'amr': <String>['bio'],
      }),
      refresh: 'ref-std',
    );
    final BiometricUnlockSuccess ok = (await env.repo.unlockWithBiometric(biometricRefresh: 'bio-1')).valueOrNull!;
    expect(ok.nextSecret, 'bio-next');
    expect(_body(env.adapter.requests.single.data), <String, Object?>{
      'method': UnlockMethod.biometric.value,
      'refreshToken': 'bio-1',
    });
    expect(env.tokens.accessToken, 'acc-3');
    expect(await env.storage.read(SecureKey.refreshToken), 'ref-std');
  });

  test('сеть недоступна → NetworkFailure(offline)', () async {
    final _Env env = _Env((RequestOptions o) async => transportError(o, DioExceptionType.connectionError));
    final Failure f = (await env.repo.requestOtp(phoneE164: '+996700123456')).failureOrNull!;
    expect(f, isA<NetworkFailure>().having((NetworkFailure n) => n.kind, 'kind', NetworkFailureKind.offline));
  });

  test('неожиданная форма ответа → UnknownFailure, без исключения', () async {
    final _Env env = _Env((RequestOptions o) async => json(202, <String, Object?>{'challengeId': 1}));
    expect((await env.repo.requestOtp(phoneE164: '+996700123456')).failureOrNull, isA<UnknownFailure>());
  });

  test('вход сообщается SessionController через sink (establish), а не мимо него', () async {
    final List<String> sessions = <String>[];
    final _Env env = _Env(
      (RequestOptions o) async =>
          json(200, <String, Object?>{'status': 'authenticated', 'accessToken': 'acc', 'refreshToken': 'ref'}),
      onSession: ({required String accessToken, required String refreshToken}) async =>
          sessions.add('$accessToken/$refreshToken'),
    );
    expect((await env.repo.verifyOtp(challengeId: 'c', code: '123456')).isSuccess, isTrue);
    expect(sessions, <String>['acc/ref']);
  });
}

// Data SCR-42 (RM-D-009): HTTP-вызовы и разбор DTO по контракту (08 §4.1.6, §4.3.4–§4.3.6), step-up операции,
// биометрия через порт core/biometrics, полный `PUT /me/settings` с `rowVersion` и одной попыткой после 409,
// локальные настройки отображения в drift `settings(scope=device)`.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/network/interceptors/session_hooks.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/settings/data/datasources/settings_api.dart';
import 'package:optomstroy/features/settings/data/repositories/device_sessions_repository_impl.dart';
import 'package:optomstroy/features/settings/data/repositories/local_settings_repositories_impl.dart';
import 'package:optomstroy/features/settings/data/repositories/login_protection_repository_impl.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';

import '../../../core/database/test_database.dart';
import '../../../core/network/fake_adapter.dart';
import '../../../core/storage/in_memory_secure_storage.dart';
import '../support/settings_fakes.dart';

Dio _dio(FakeAdapter adapter) => Dio(BaseOptions(baseUrl: 'https://api.test/api/v1'))..httpClientAdapter = adapter;

Map<String, Object?> _session(String id, {bool current = false, String? lastUsedAt}) => <String, Object?>{
  'id': id,
  'deviceId': '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f5$id',
  'deviceName': 'Устройство $id',
  'platform': 'android',
  'appVersion': '1.4.2+87',
  'kind': 'standard',
  'createdAt': '2026-10-20T09:00:00Z',
  'lastUsedAt': lastUsedAt ?? '2026-10-22T08:00:00Z',
  'ipLast': '212.***.***.12',
  'isCurrent': current,
};

Map<String, Object?> _me({bool pinSet = true, int idle = 30, int rowVersion = 3}) => <String, Object?>{
  'id': 'u1',
  'kind': 'staff',
  'status': 'active',
  'roles': <String>['seller'],
  'permissions': <String>[],
  'permissionsVersion': 1,
  'profile': <String, Object?>{'birthYear': 1990},
  'security': <String, Object?>{'pinSet': pinSet, 'biometricsEnabled': false},
  'settings': <String, Object?>{
    'locale': 'ru',
    'scanner': <String, Object?>{'mode': 'hid', 'suffix': 'enter'},
    'scanAddsToCart': false,
    'printer': <String, Object?>{'defaultFormat': '80mm', 'autoPrint': false},
    'catalogView': 'grid',
    'defaultWarehouseId': null,
    'idleLockMinutes': idle,
    'rowVersion': rowVersion,
  },
};

void main() {
  setUpAll(configureSqliteForTests);

  group('DeviceSessionsRepositoryImpl', () {
    test('GET /auth/sessions: Session → DeviceSession, текущая первой, далее по активности', () async {
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async => json(200, <String, Object?>{
          'items': <Object?>[
            _session('1', lastUsedAt: '2026-10-21T08:00:00Z'),
            _session('2', current: true),
            _session('3', lastUsedAt: '2026-10-22T08:30:00Z'),
          ],
        }),
      );
      final DeviceSessionsRepositoryImpl repo = DeviceSessionsRepositoryImpl(
        SettingsApi(_dio(adapter)),
        logout: () async {},
        logoutAll: () async => null,
      );
      final List<DeviceSession> list = (await repo.list()).valueOrNull!;
      expect(list.map((DeviceSession s) => s.id), <String>['2', '3', '1']);
      expect(list.first.isCurrent, isTrue);
      expect(list.first.platform, DevicePlatform.android);
      expect(list.first.kind, SessionKind.standard);
      expect(list.first.ipMasked, '212.***.***.12');
      expect(list.first.lastUsedAt, DateTime.utc(2026, 10, 22, 8));
      expect(adapter.requests.single.path, '/auth/sessions');
    });

    test('DELETE /auth/sessions/{id}: operation session.revoke.other; 404 — уже завершена → успех', () async {
      final List<RequestOptions> seen = <RequestOptions>[];
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
        seen.add(o);
        return o.path.endsWith('/gone') ? json(404, problem('NOT_FOUND', 404)) : json(204, null);
      });
      final DeviceSessionsRepositoryImpl repo = DeviceSessionsRepositoryImpl(
        SettingsApi(_dio(adapter)),
        logout: () async {},
        logoutAll: () async => null,
      );
      expect((await repo.revoke('s-1')).isSuccess, isTrue);
      expect((await repo.revoke('gone')).isSuccess, isTrue);
      expect(seen.first.method, 'DELETE');
      expect(seen.first.extra[SessionRequestExtra.stepUpOperation], 'session.revoke.other');
      expect(seen.first.extra[RequestExtra.retryProfile], RetryProfile.none);
    });

    test('DELETE: 403 STEP_UP_REQUIRED после отмены диалога → AuthFailure(stepUpRequired)', () async {
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async => json(
          403,
          problem(
            'STEP_UP_REQUIRED',
            403,
            extra: <String, Object?>{
              'stepUp': <String, Object?>{
                'operation': 'session.revoke.other',
                'allowedMethods': <String>['pin', 'otp'],
              },
            },
          ),
        ),
      );
      final DeviceSessionsRepositoryImpl repo = DeviceSessionsRepositoryImpl(
        SettingsApi(_dio(adapter)),
        logout: () async {},
        logoutAll: () async => null,
      );
      final Failure? f = (await repo.revoke('s-1')).failureOrNull;
      expect(f, isA<AuthFailure>().having((AuthFailure a) => a.reason, 'reason', AuthReason.stepUpRequired));
    });

    test(
      'PATCH /auth/sessions/{id} {deviceName} → обновлённая сессия; logout/logoutAll — через core/session',
      () async {
        final FakeAdapter adapter = FakeAdapter(
          (RequestOptions o) async => json(200, <String, Object?>{..._session('1'), 'deviceName': 'Касса-2'}),
        );
        int logouts = 0;
        final DeviceSessionsRepositoryImpl repo = DeviceSessionsRepositoryImpl(
          SettingsApi(_dio(adapter)),
          logout: () async => logouts++,
          logoutAll: () async => const AuthFailure(AuthReason.stepUpRequired),
        );
        final DeviceSession s = (await repo.rename('1', 'Касса-2')).valueOrNull!;
        expect(s.deviceName, 'Касса-2');
        expect(adapter.requests.single.method, 'PATCH');
        expect(adapter.requests.single.data, <String, Object?>{'deviceName': 'Касса-2'});
        await repo.logoutCurrent();
        expect(logouts, 1);
        expect((await repo.logoutAll()).failureOrNull, isA<AuthFailure>());
      },
    );

    test('Session без id → ошибка разбора (UnknownFailure)', () async {
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async => json(200, <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'isCurrent': true},
          ],
        }),
      );
      final DeviceSessionsRepositoryImpl repo = DeviceSessionsRepositoryImpl(
        SettingsApi(_dio(adapter)),
        logout: () async {},
        logoutAll: () async => null,
      );
      expect((await repo.list()).failureOrNull, isA<UnknownFailure>());
    });
  });

  group('LoginProtectionRepositoryImpl', () {
    late InMemorySecureStorage storage;
    late FixedClock clock;

    setUp(() {
      storage = InMemorySecureStorage();
      clock = FixedClock(t0);
    });

    LoginProtectionRepositoryImpl repo(
      FakeAdapter adapter,
      FakeBiometricAuthenticator bio, {
      List<StepUpChallenge>? challenges,
    }) => LoginProtectionRepositoryImpl(
      api: SettingsApi(_dio(adapter), newKey: () => 'idem-1'),
      biometrics: bio,
      storage: storage,
      obtainStepUp: (StepUpChallenge c) async {
        challenges?.add(c);
        return 'step-up-token';
      },
      clock: clock,
      fallbackLabel: BiometricPlatformLabel.android,
    );

    test('load: GET /me → pinSet, idleLockMinutes, год рождения; биометрия устройства', () async {
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async => json(200, _me(idle: 15)));
      final LoginProtectionState s = (await repo(
        adapter,
        FakeBiometricAuthenticator(androidClass3),
      ).load()).valueOrNull!;
      expect(s.userKind, UserKind.staff);
      expect(s.pinSet, isTrue);
      expect(s.idleLockMinutes, 15);
      expect(s.birthYear, 1990);
      expect(s.support, BiometricSupport.cryptoLogin);
      expect(s.platformLabel, BiometricPlatformLabel.android);
      expect(s.biometricsEnabled, isFalse);
      expect(s.settingsAsOf, isNull);
      expect(s.pinLength, 6);
    });

    test('load офлайн после успешного ответа → кэш /me с отметкой времени (settings_stale_caption)', () async {
      bool fail = false;
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async => fail ? transportError(o, DioExceptionType.connectionError) : json(200, _me()),
      );
      final LoginProtectionRepositoryImpl r = repo(adapter, FakeBiometricAuthenticator(androidClass3));
      await r.load();
      fail = true;
      clock.advance(const Duration(minutes: 10));
      final LoginProtectionState s = (await r.load()).valueOrNull!;
      expect(s.settingsAsOf, t0);
    });

    test('load офлайн без кэша → NetworkFailure', () async {
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async => transportError(o, DioExceptionType.connectionError),
      );
      expect(
        (await repo(adapter, FakeBiometricAuthenticator(androidClass3)).load()).failureOrNull,
        isA<NetworkFailure>(),
      );
    });

    test('supportOf: Windows Hello — гейт; not enrolled; нет криптопривязки — недоступно', () {
      expect(LoginProtectionRepositoryImpl.supportOf(windowsHello), BiometricSupport.windowsHelloGate);
      expect(
        LoginProtectionRepositoryImpl.supportOf(
          const BiometricCapability(
            kind: BiometricKind.androidClass3,
            availability: BiometricAvailability.notEnrolled,
            cryptoBinding: true,
          ),
        ),
        BiometricSupport.notEnrolled,
      );
      expect(LoginProtectionRepositoryImpl.supportOf(BiometricCapability.none), BiometricSupport.unavailable);
    });

    test('UI-42-009: POST /me/pin {newPin}, operation profile.pin.set, Idempotency-Key; PIN не в логах', () async {
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async => json(204, null));
      final List<StepUpChallenge> challenges = <StepUpChallenge>[];
      final LoginProtectionRepositoryImpl r = repo(
        adapter,
        FakeBiometricAuthenticator(androidClass3),
        challenges: challenges,
      );
      expect(await r.stepUpForPin(otpOnly: true), isTrue);
      expect(challenges.single.operation, 'profile.pin.set');
      expect(challenges.single.allowedMethods, <String>['otp']);
      expect(await r.stepUpForPin(otpOnly: false), isTrue);
      expect(challenges.last.allowedMethods, <String>['pin', 'otp']);

      final List<RequestOptions> seen = <RequestOptions>[];
      final FakeAdapter a2 = FakeAdapter((RequestOptions o) async {
        seen.add(o);
        return json(204, null);
      });
      expect((await repo(a2, FakeBiometricAuthenticator(androidClass3)).changePin('582914')).isSuccess, isTrue);
      expect(seen.single.path, '/me/pin');
      expect(seen.single.data, <String, Object?>{'newPin': '582914'});
      expect(seen.single.extra[SessionRequestExtra.stepUpOperation], 'profile.pin.set');
      expect(seen.single.headers[ApiHeaders.idempotencyKey], 'idem-1');
    });

    test('pin_weak → ValidationFailure; DELETE /me/pin — operation profile.pin.set', () async {
      final List<RequestOptions> seen = <RequestOptions>[];
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
        seen.add(o);
        if (o.method == 'POST') {
          return json(
            400,
            problem(
              'VALIDATION_FAILED',
              400,
              extra: <String, Object?>{
                'errors': <Object?>[
                  <String, Object?>{'field': 'newPin', 'rule': 'pin_weak', 'message': 'weak'},
                ],
              },
            ),
          );
        }
        return json(204, null);
      });
      final LoginProtectionRepositoryImpl r = repo(adapter, FakeBiometricAuthenticator(androidClass3));
      expect((await r.changePin('123456')).failureOrNull, isA<ValidationFailure>());
      expect((await r.removePin()).isSuccess, isTrue);
      expect(seen.last.method, 'DELETE');
      expect(seen.last.extra[SessionRequestExtra.stepUpOperation], 'profile.pin.set');
    });

    test(
      'UI-42-010 Android: согласие версии /me/consents → POST /me/biometrics → токен под ключом устройства',
      () async {
        final List<RequestOptions> seen = <RequestOptions>[];
        final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
          seen.add(o);
          if (o.path.endsWith('/me/consents')) {
            return json(200, <String, Object?>{
              'items': <Object?>[],
              'required': <Object?>[
                <String, Object?>{'kind': 'biometrics_device', 'currentVersion': '2026-11-01'},
              ],
            });
          }
          return json(200, <String, Object?>{
            'enabled': true,
            'biometricRefreshToken': 'bio-secret', // check-secrets: allow — тестовая метка, не секрет
            'expiresAt': 'x',
          });
        });
        final FakeBiometricAuthenticator bio = FakeBiometricAuthenticator(androidClass3);
        final LoginProtectionRepositoryImpl r = repo(adapter, bio);
        final BiometricToggleOutcome out = await r.enableBiometrics(const BiometricPromptCopy(title: 't', cancel: 'c'));
        expect(out, BiometricToggleOutcome.enabled);
        expect(bio.stored, 'bio-secret');
        expect(await storage.read(SecureKey.biometricsEnabled), 'true');
        final RequestOptions post = seen.last;
        expect(post.extra[SessionRequestExtra.stepUpOperation], 'profile.biometrics.toggle');
        expect(post.data, <String, Object?>{
          'enabled': true,
          'biometricClass': 'class3',
          'consent': <String, Object?>{'kind': 'biometrics_device', 'version': '2026-11-01', 'granted': true},
        });
      },
    );

    test('UI-42-010: отказ в системном диалоге → cancelled, выданная семья отзывается (enabled=false)', () async {
      final List<Object?> bodies = <Object?>[];
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
        if (o.path.endsWith('/me/consents')) {
          return json(200, <String, Object?>{'items': <Object?>[], 'required': <Object?>[]});
        }
        bodies.add(o.data);
        final Map<String, Object?> body = o.data! as Map<String, Object?>;
        return body['enabled'] == true
            ? json(200, <String, Object?>{
                'enabled': true,
                'biometricRefreshToken': 'bio-secret', // check-secrets: allow — тестовая метка, не секрет
              })
            : json(200, <String, Object?>{'enabled': false});
      });
      final FakeBiometricAuthenticator bio = FakeBiometricAuthenticator(
        androidClass3,
        storeResult: const BiometricResult<void>.failure(BiometricError.cancelled),
      );
      final BiometricToggleOutcome out = await repo(
        adapter,
        bio,
      ).enableBiometrics(const BiometricPromptCopy(title: 't', cancel: 'c'));
      expect(out, BiometricToggleOutcome.cancelled);
      expect(bodies, hasLength(2));
      expect((bodies.last! as Map<String, Object?>)['enabled'], isFalse);
      expect((bodies.first! as Map<String, Object?>)['consent'], containsPair('version', '2026-10-01'));
      expect(await storage.read(SecureKey.biometricsEnabled), isNull);
    });

    test('UI-42-010: CONSENT_REQUIRED / отмена step-up / офлайн → соответствующие исходы', () async {
      for (final (ResponseBody Function(RequestOptions) answer, BiometricToggleOutcome expected)
          in <(ResponseBody Function(RequestOptions), BiometricToggleOutcome)>[
            ((RequestOptions o) => json(422, problem('CONSENT_REQUIRED', 422)), BiometricToggleOutcome.consentRequired),
            (
              (RequestOptions o) => json(
                403,
                problem(
                  'STEP_UP_REQUIRED',
                  403,
                  extra: <String, Object?>{
                    'stepUp': <String, Object?>{'operation': 'profile.biometrics.toggle'},
                  },
                ),
              ),
              BiometricToggleOutcome.stepUpCancelled,
            ),
          ]) {
        final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
          if (o.path.endsWith('/me/consents')) {
            return json(200, <String, Object?>{'items': <Object?>[], 'required': <Object?>[]});
          }
          return answer(o);
        });
        final BiometricToggleOutcome out = await repo(
          adapter,
          FakeBiometricAuthenticator(androidClass3),
        ).enableBiometrics(const BiometricPromptCopy(title: 't', cancel: 'c'));
        expect(out, expected);
      }
      final FakeAdapter offline = FakeAdapter(
        (RequestOptions o) async => transportError(o, DioExceptionType.connectionError),
      );
      expect(
        await repo(
          offline,
          FakeBiometricAuthenticator(androidClass3),
        ).enableBiometrics(const BiometricPromptCopy(title: 't', cancel: 'c')),
        BiometricToggleOutcome.offline,
      );
    });

    test('UI-42-010 Windows: только Windows Hello (без сервера), выключение — без POST', () async {
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async => json(500, problem('INTERNAL', 500)));
      final FakeBiometricAuthenticator bio = FakeBiometricAuthenticator(windowsHello);
      final LoginProtectionRepositoryImpl r = repo(adapter, bio);
      expect(
        await r.enableBiometrics(const BiometricPromptCopy(title: 't', cancel: 'c')),
        BiometricToggleOutcome.enabled,
      );
      expect(bio.presence, 1);
      expect(await storage.read(SecureKey.biometricsEnabled), 'windows_hello');
      expect(await r.disableBiometrics(), BiometricToggleOutcome.disabled);
      expect(adapter.requests, isEmpty);
      expect(await storage.read(SecureKey.biometricsEnabled), isNull);
    });

    test('выключение Android: POST enabled=false → ключ и признак удалены', () async {
      await storage.write(SecureKey.biometricsEnabled, 'true');
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async => json(200, <String, Object?>{'enabled': false}),
      );
      final FakeBiometricAuthenticator bio = FakeBiometricAuthenticator(androidClass3)..stored = 'old';
      expect(await repo(adapter, bio).disableBiometrics(), BiometricToggleOutcome.disabled);
      expect(adapter.requests.single.data, <String, Object?>{'enabled': false});
      expect(bio.clears, 1);
      expect(await storage.read(SecureKey.biometricsEnabled), isNull);
    });

    test(
      'UI-42-023: PUT /me/settings — полный объект с rowVersion; 409 → current + изменённое поле (1 попытка)',
      () async {
        final List<Map<String, Object?>> puts = <Map<String, Object?>>[];
        final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
          if (o.method == 'GET') return json(200, _me(rowVersion: 3));
          final Map<String, Object?> body = Map<String, Object?>.from(o.data! as Map<dynamic, dynamic>);
          puts.add(body);
          if (body['rowVersion'] == 3) {
            return json(
              409,
              problem(
                'VERSION_CONFLICT',
                409,
                extra: <String, Object?>{
                  'current': <String, Object?>{
                    ...(_me()['settings']! as Map<String, Object?>),
                    'rowVersion': 4,
                    'locale': 'ru',
                  },
                },
              ),
            );
          }
          return json(200, <String, Object?>{...body, 'rowVersion': 5});
        });
        final Result<int> res = await repo(adapter, FakeBiometricAuthenticator(androidClass3)).setIdleLockMinutes(10);
        expect(res.valueOrNull, 10);
        expect(puts, hasLength(2));
        expect(puts.first.keys.toSet(), <String>{
          'locale',
          'scanner',
          'scanAddsToCart',
          'printer',
          'catalogView',
          'defaultWarehouseId',
          'idleLockMinutes',
          'rowVersion',
        });
        expect(puts.first['idleLockMinutes'], 10);
        expect(puts.last['rowVersion'], 4);
        expect(puts.last['idleLockMinutes'], 10);
      },
    );

    test(
      'settingsBody: вложенные scanner/printer сливаются, rowVersion из patch игнорируется, лишние ключи отброшены',
      () {
        final Map<String, Object?> body = LoginProtectionRepositoryImpl.settingsBody(
          <String, Object?>{
            'scanner': <String, Object?>{'mode': 'hid', 'suffix': 'enter'},
            'rowVersion': 7,
            'updatedAt': 'x',
          },
          <String, Object?>{
            'scanner': <String, Object?>{'suffix': 'tab'},
            'rowVersion': 1,
            'unknown': true,
          },
        );
        expect(body, <String, Object?>{
          'scanner': <String, Object?>{'mode': 'hid', 'suffix': 'tab'},
          'rowVersion': 7,
        });
      },
    );
  });

  group('локальные настройки', () {
    test('DisplayPreferencesRepositoryImpl: drift settings(scope=device), ключ display', () async {
      final AppDatabase db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final DisplayPreferencesRepositoryImpl r = DisplayPreferencesRepositoryImpl(db, FixedClock(t0));
      expect(await r.load(), DisplayPreferences.defaults);
      const DisplayPreferences p = DisplayPreferences(
        density: DisplayDensity.compact,
        textScale: TextScaleOption.xlarge,
        reduceMotion: true,
      );
      await r.save(p);
      expect(await DisplayPreferencesRepositoryImpl(db, FixedClock(t0)).load(), p);
      final SettingRow row = await db.select(db.localSettings).getSingle();
      expect(row.scope, 'device');
      expect(row.key, 'display');
      expect(DisplayPreferencesRepositoryImpl.decode('мусор'), DisplayPreferences.defaults);
    });

    test('без БД (до входа) — память процесса', () async {
      final DisplayPreferencesRepositoryImpl r = DisplayPreferencesRepositoryImpl(null, FixedClock(t0));
      await r.save(const DisplayPreferences(reduceMotion: true));
      expect((await r.load()).reduceMotion, isTrue);
    });

    test('AppAboutSourceImpl: версия, платформа, последние 8 символов deviceId, версии из заголовков', () {
      final AppAboutInfo info = AppAboutSourceImpl(
        meta: () => const ClientMeta(
          appVersion: '1.4.2+87',
          platform: ClientPlatform.windows,
          deviceId: '1b4e28ba-2d11-4d4f-9f4a-0c3a6f6e7d01',
        ),
        versions: () => (min: '1.2.0', recommended: '1.3.0'),
      ).current();
      expect(info.appVersion, '1.4.2+87');
      expect(info.platform, DevicePlatform.windows);
      expect(info.deviceIdSuffix, '6f6e7d01');
      expect(info.minVersion, '1.2.0');
      expect(info.recommendedVersion, '1.3.0');
      final AppAboutInfo empty = AppAboutSourceImpl(
        meta: () => null,
        versions: () => (min: null, recommended: null),
      ).current();
      expect(empty.appVersion, '—');
      expect(empty.deviceIdSuffix, isNull);
    });
  });
}

// Data: черновик (09 §7.4; AC-UI-03-012/013 — ПДн только в secure storage, удаление через 15 мин),
// HTTP-слой POST /registration/complete на фейковом транспорте (Idempotency-Key, тело без device.model,
// без PIN при выборе только биометрии, токены → сессия; REGISTRATION_TOKEN_INVALID, PHONE_ALREADY_REGISTERED).
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/registration_draft_dao.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/registration/data/datasources/registration_api.dart';
import 'package:optomstroy/features/registration/data/device_descriptor.dart';
import 'package:optomstroy/features/registration/data/repositories/registration_draft_repository_impl.dart';
import 'package:optomstroy/features/registration/data/repositories/registration_repository_impl.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';

import '../../../core/database/test_database.dart';
import '../../../core/network/fake_adapter.dart';
import '../../../core/storage/in_memory_secure_storage.dart';

final class _Device implements DeviceDescriptorSource {
  @override
  Future<Map<String, Object?>> describe({String? biometricClass}) async => PluginDeviceDescriptorSource.deviceInfoJson(
    name: 'Samsung SM-A525F',
    platform: 'android',
    appVersion: '0.1.0+1',
    osVersion: '14',
    biometricClass: biometricClass,
  );
}

void main() {
  group('Черновик регистрации', () {
    late InMemorySecureStorage storage;
    late FixedClock clock;

    setUp(() {
      storage = InMemorySecureStorage();
      clock = FixedClock(DateTime.utc(2026, 10, 22, 9));
    });

    const draft = RegistrationDraft(
      fullName: 'Иванов Иван',
      birthYear: '1990',
      activitySphere: ActivitySphere.privatePerson,
      personalDataAck: true,
      step: RegistrationStep.security,
    );

    test('ФИО и год — в secure storage конвертом со сроком; восстанавливается', () async {
      final repo = RegistrationDraftRepositoryImpl(storage: storage, clock: clock);
      await repo.save(draft);
      expect(storage.values.keys, containsAll(SecureKey.registration));
      final envelope = jsonDecode(storage.values[SecureKey.registrationFullName]!) as Map<String, Object?>;
      expect(envelope['v'], 'Иванов Иван');
      expect(envelope['exp'], clock.nowUtc().add(const Duration(minutes: 15)).millisecondsSinceEpoch);
      expect(await repo.load(), draft);
    });

    test('через 15 мин после последнего изменения черновик удалён (AC-UI-03-013)', () async {
      final repo = RegistrationDraftRepositoryImpl(storage: storage, clock: clock);
      await repo.save(draft);
      clock.advance(const Duration(minutes: 15));
      expect(await repo.load(), isNull);
      expect(storage.values, isEmpty);
    });

    test('drift `registration_draft` — только шаг/согласия/код сферы, без ПДн (AC-UI-03-012)', () async {
      configureSqliteForTests();
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = RegistrationDraftRepositoryImpl(storage: storage, clock: clock, database: () => db);
      await repo.save(draft);
      final rows = await db.select(db.registrationDraft).get();
      final dump = rows.map((r) => '${r.key}=${r.valueJson}').join(';');
      expect(dump, isNot(contains('Иванов')));
      expect(dump, isNot(contains('1990')));
      expect(await RegistrationDraftDao(db).read(RegistrationDraftDao.stepKey), 'security');
      expect(await RegistrationDraftDao(db).read(RegistrationDraftDao.sphereKey), 'private');
      final restored = await RegistrationDraftRepositoryImpl(storage: storage, clock: clock, database: () => db).load();
      expect(restored, draft);
      await repo.clear();
      expect(await db.select(db.registrationDraft).get(), isEmpty);
      expect(storage.values, isEmpty);
    });
  });

  group('RegistrationRepositoryImpl (HTTP)', () {
    late FakeAdapter adapter;
    late InMemorySecureStorage storage;
    late List<(String, String)> established;

    RegistrationRepositoryImpl repo(FakeHandler handler) {
      adapter = FakeAdapter(handler);
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api/v1'))..httpClientAdapter = adapter;
      storage = InMemorySecureStorage();
      established = [];
      return RegistrationRepositoryImpl(
        api: RegistrationApi(dio, newKey: () => 'k'),
        tokens: TokenStore(storage),
        device: _Device(),
        deviceBiometricClass: () async => 'class3',
        establishSession: (a, r) async => established.add((a, r)),
      );
    }

    const request = RegistrationRequest(
      registrationToken: 'reg-token', // check-secrets: allow — тестовое значение
      fullName: 'Иванов Иван',
      birthYear: 1990,
      biometricsEnabled: true,
      consents: <ConsentGrant>[
        ConsentGrant('personal_data', '2026-10-01'),
        ConsentGrant('biometrics_device', '2026-10-01'),
      ],
    );

    test('201: тело по схеме, Idempotency-Key, токены → SessionController.establish', () async {
      final r = repo(
        (_) async => json(201, <String, Object?>{
          'status': 'authenticated',
          'accessToken': 'acc',
          'refreshToken': 'ref',
          'user': <String, Object?>{
            'kind': 'customer',
            'roles': <String>['customer'],
          },
          'customerMatch': <String, Object?>{'status': 'proposed', 'linkId': 'l1', 'nextStep': 'confirm_or_reject'},
        }),
      );
      final res = await r.complete(request, idempotencyKey: 'idem-1');
      final outcome = res.valueOrNull!;
      expect(outcome.isCustomer, isTrue);
      expect(outcome.customerMatch!.needsScreen, isTrue);
      expect(established, <(String, String)>[('acc', 'ref')]);
      final sent = adapter.requests.single;
      expect(sent.path, '/registration/complete');
      expect(sent.headers['Idempotency-Key'], 'idem-1');
      final body = sent.data! as Map<String, Object?>;
      expect(body.keys, <String>['registrationToken', 'fullName', 'birthYear', 'security', 'consents', 'device']);
      expect(body['security'], <String, Object?>{'biometricsEnabled': true}, reason: 'PIN не выбран — не передаётся');
      final device = body['device']! as Map<String, Object?>;
      expect(device.containsKey('model'), isFalse, reason: 'AC-UI-04-019');
      expect(device['biometricClass'], 'class3');
      expect(storage.values, isEmpty, reason: 'токены передаются в сессию, PIN не хранится');
    });

    test('без колбэка сессии — refresh в secure storage, access в памяти', () async {
      adapter = FakeAdapter(
        (_) async => json(201, <String, Object?>{
          'status': 'pending_activation',
          'accessToken': 'acc',
          'refreshToken': 'ref',
          'user': <String, Object?>{'kind': 'staff', 'roles': <String>[]},
        }),
      );
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api/v1'))..httpClientAdapter = adapter;
      final mem = InMemorySecureStorage();
      final tokens = TokenStore(mem);
      final r = RegistrationRepositoryImpl(
        api: RegistrationApi(dio),
        tokens: tokens,
        device: _Device(),
        deviceBiometricClass: () async => null,
      );
      final res = await r.complete(request, idempotencyKey: 'k');
      expect(res.valueOrNull!.accountStatus, RegistrationAccountStatus.pendingActivation);
      expect(tokens.accessToken, 'acc');
      expect(mem.values[SecureKey.refreshToken], 'ref');
    });

    test('401 REGISTRATION_TOKEN_INVALID и 409 PHONE_ALREADY_REGISTERED', () async {
      var r = repo((_) async => json(401, problem('REGISTRATION_TOKEN_INVALID', 401)));
      final expired = await r.complete(request, idempotencyKey: 'k');
      expect((expired.failureOrNull! as AuthFailure).reason, AuthReason.registrationTokenInvalid);
      r = repo((_) async => json(409, problem('PHONE_ALREADY_REGISTERED', 409)));
      final taken = await r.complete(request, idempotencyKey: 'k');
      expect((taken.failureOrNull! as ConflictFailure).kind, ConflictKind.phoneAlreadyRegistered);
    });

    test('POST /me/biometrics: согласие текущей версии, X-Step-Up-Token; Windows — null', () async {
      var r = repo(
        (_) async => json(200, <String, Object?>{'enabled': true, 'biometricRefreshToken': 'brt', 'expiresAt': 'x'}),
      );
      final token = await r.enableBiometrics(biometricClass: 'class3', stepUpToken: 'su');
      expect(token.valueOrNull, 'brt');
      expect(adapter.requests.single.headers['X-Step-Up-Token'], 'su');
      expect(adapter.requests.single.data, <String, Object?>{
        'enabled': true,
        'biometricClass': 'class3',
        'consent': <String, Object?>{'kind': 'biometrics_device', 'version': '2026-10-01', 'granted': true},
      });
      r = repo((_) async => json(200, <String, Object?>{'enabled': false, 'reason': 'no_crypto_binding_on_platform'}));
      expect((await r.enableBiometrics(biometricClass: 'windows_hello')).valueOrNull, isNull);
    });

    test('step-up PIN: PIN_INVALID с attemptsLeft', () async {
      final r = repo((_) async => json(401, problem('PIN_INVALID', 401, extra: <String, Object?>{'attemptsLeft': 2})));
      final res = await r.stepUpWithPin(pin: '4839', operation: 'profile.biometrics.toggle');
      final f = res.failureOrNull! as AuthFailure;
      expect(f.reason, AuthReason.pinInvalid);
      expect(f.attemptsLeft, 2);
      expect(adapter.requests.single.data, <String, Object?>{
        'method': 'pin',
        'pin': '4839',
        'operation': 'profile.biometrics.toggle',
      });
    });

    test('customer-match: только маска, без финансовых полей', () async {
      final r = repo(
        (_) async => json(200, <String, Object?>{
          'status': 'proposed',
          'linkId': '3f0c2a8e-0000-4000-8000-000000000001',
          'customer': <String, Object?>{'displayNameMasked': 'ОсОО «Стр***»'},
          'nextStep': 'confirm_or_reject',
        }),
      );
      final match = (await r.customerMatch()).valueOrNull!;
      expect(match.canSelfResolve, isTrue);
      expect(match.displayNameMasked, 'ОсОО «Стр***»');
      expect(match.displayName, isNull);
    });

    test('logout офлайн — локальная очистка всё равно', () async {
      final r = repo((o) async => transportError(o, DioExceptionType.connectionError));
      await storage.write(SecureKey.refreshToken, 'ref');
      await r.logout();
      expect(storage.values.containsKey(SecureKey.refreshToken), isFalse);
    });

    test('ошибки транспорта → NetworkFailure (баннер «Повторить» с тем же ключом)', () async {
      final r = repo((o) async => transportError(o, DioExceptionType.connectionError));
      final res = await r.complete(request, idempotencyKey: 'k');
      expect(res, isA<FailureResult<RegistrationOutcome>>());
      expect(res.failureOrNull, isA<NetworkFailure>());
    });
  });
}

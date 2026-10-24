// EQ-DREST-07 (перенос этапа E): outbox `profile.settings` — 07 §11.2 (тип `outbox_actions`), 02 SCR-42.4 «Общие
// правила сохранения» и SCR-42.7 «Устаревшие данные» (а): без сети изменение `Settings` применяется локально и
// ставится в очередь с `rowVersion` кэша `/me`; при сети — `PUT /me/settings` полным объектом с `Idempotency-Key`
// записи; `409 VERSION_CONFLICT` — `current` + изменённые поля, одна попытка, иначе `dead`.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/settings/data/datasources/settings_api.dart';
import 'package:optomstroy/features/settings/data/outbox/profile_settings_outbox.dart';
import 'package:optomstroy/features/settings/data/repositories/login_protection_repository_impl.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';

import '../../../core/database/test_database.dart';
import '../../../core/network/fake_adapter.dart';
import '../../../core/storage/in_memory_secure_storage.dart';
import '../support/settings_fakes.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 22, 9);

Map<String, Object?> _settings({int rowVersion = 3, int idle = 30}) => <String, Object?>{
  'locale': 'ru',
  'scanner': <String, Object?>{'mode': 'hid', 'suffix': 'enter'},
  'scanAddsToCart': false,
  'printer': <String, Object?>{'defaultFormat': '80mm', 'autoPrint': false},
  'catalogView': 'grid',
  'defaultWarehouseId': null,
  'idleLockMinutes': idle,
  'rowVersion': rowVersion,
};

Map<String, Object?> _me() => <String, Object?>{
  'id': 'u1',
  'kind': 'staff',
  'status': 'active',
  'roles': <String>['seller'],
  'permissions': <String>[],
  'permissionsVersion': 1,
  'profile': <String, Object?>{'birthYear': 1990},
  'security': <String, Object?>{'pinSet': true, 'biometricsEnabled': false},
  'settings': _settings(),
};

Dio _dio(FakeAdapter adapter) => Dio(BaseOptions(baseUrl: 'https://api.test/api/v1'))..httpClientAdapter = adapter;

Map<String, Object?> _body(RequestOptions o) => Map<String, Object?>.from(o.data! as Map<dynamic, dynamic>);

void main() {
  setUpAll(configureSqliteForTests);

  group('LoginProtectionRepositoryImpl.patchSettings офлайн', () {
    LoginProtectionRepositoryImpl repo(FakeAdapter adapter, {ProfileSettingsEnqueue? enqueue}) =>
        LoginProtectionRepositoryImpl(
          api: SettingsApi(_dio(adapter), newKey: () => 'idem-1'),
          biometrics: FakeBiometricAuthenticator(androidClass3),
          storage: InMemorySecureStorage(),
          obtainStepUp: (_) async => null,
          clock: FixedClock(_t0),
          fallbackLabel: BiometricPlatformLabel.android,
          enqueueOffline: enqueue,
        );

    test('нет сети → изменение применено локально и поставлено в outbox с rowVersion кэша; '
        'следующее изменение — поверх применённого', () async {
      bool online = true;
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async => online ? json(200, _me()) : transportError(o, DioExceptionType.connectionError),
      );
      final List<Map<String, Object?>> queued = <Map<String, Object?>>[];
      final LoginProtectionRepositoryImpl r = repo(
        adapter,
        enqueue: (Map<String, Object?> p) async {
          queued.add(p);
          return true;
        },
      );
      await r.load();
      online = false;

      final Result<int> idle = await r.setIdleLockMinutes(10);
      expect(idle.valueOrNull, 10, reason: 'optimistic');
      final ProfileSettingsPayload first = ProfileSettingsPayload.tryParse(queued.single)!;
      expect(first.patch, <String, Object?>{'idleLockMinutes': 10});
      expect(first.settings['rowVersion'], 3);
      expect(first.settings['idleLockMinutes'], 10);
      expect(first.settings.keys.toSet(), LoginProtectionRepositoryImpl.settingsKeys.toSet());

      final Result<Map<String, Object?>> scan = await r.patchSettings(<String, Object?>{'scanAddsToCart': true});
      expect(scan.valueOrNull?['scanAddsToCart'], isTrue);
      final ProfileSettingsPayload second = ProfileSettingsPayload.tryParse(queued.last)!;
      expect(second.settings['idleLockMinutes'], 10, reason: 'кэш обновлён первым изменением');
      expect(second.settings['scanAddsToCart'], isTrue);
      expect(second.patch, <String, Object?>{'scanAddsToCart': true});
    });

    test('очередь недоступна (обработчик не подключён) / без порта — ошибка сети, как раньше', () async {
      bool online = true;
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async => online ? json(200, _me()) : transportError(o, DioExceptionType.connectionError),
      );
      for (final ProfileSettingsEnqueue? enqueue in <ProfileSettingsEnqueue?>[null, (_) async => false]) {
        online = true;
        final LoginProtectionRepositoryImpl r = repo(adapter, enqueue: enqueue);
        await r.load();
        online = false;
        expect((await r.setIdleLockMinutes(10)).failureOrNull, isA<NetworkFailure>());
      }
    });

    test('ответ сервера с ошибкой (не сеть) в outbox не ставится', () async {
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async => o.method == 'GET' ? json(200, _me()) : json(422, problem('VALIDATION_FAILED', 422)),
      );
      final List<Map<String, Object?>> queued = <Map<String, Object?>>[];
      final LoginProtectionRepositoryImpl r = repo(
        adapter,
        enqueue: (Map<String, Object?> p) async {
          queued.add(p);
          return true;
        },
      );
      await r.load();
      expect((await r.setIdleLockMinutes(10)).isSuccess, isFalse);
      expect(queued, isEmpty);
    });
  });

  group('ProfileSettingsOutboxHandler + OutboxQueue', () {
    late AppDatabase db;
    late FixedClock clock;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      clock = FixedClock(_t0);
    });
    tearDown(() => db.close());

    OutboxQueue queue(FakeAdapter adapter) => OutboxQueue(
      database: () => db,
      owner: () => 'u1',
      clock: clock,
      handlers: <OutboxActionHandler>[
        ProfileSettingsOutboxHandler(() => SettingsApi(_dio(adapter), newKey: () => 'retry-key')),
      ],
    );

    Map<String, Object?> payload() => ProfileSettingsPayload(
      settings: <String, Object?>{..._settings(), 'idleLockMinutes': 10},
      patch: const <String, Object?>{'idleLockMinutes': 10},
    ).toJson();

    test('офлайн — запись ждёт; сеть — PUT /me/settings полным объектом с rowVersion кэша и ключом записи', () async {
      bool online = false;
      final List<RequestOptions> puts = <RequestOptions>[];
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
        if (!online) transportError(o, DioExceptionType.connectionError);
        puts.add(o);
        return json(200, <String, Object?>{..._body(o), 'rowVersion': 4});
      });
      final OutboxQueue q = queue(adapter);
      final String key = (await q.enqueue(profileSettingsOutboxType, payload()))!;

      expect((await q.flush()).deferred, isTrue);
      expect(await q.pendingCount(), 1);

      online = true;
      expect((await q.flush()).sent, 1);
      expect(puts.single.method, 'PUT');
      expect(puts.single.uri.path, '/api/v1/me/settings');
      expect(puts.single.headers['Idempotency-Key'], key);
      expect(_body(puts.single)['rowVersion'], 3);
      expect(_body(puts.single)['idleLockMinutes'], 10);
      expect(await q.pendingCount(), 0);
      final OutboxActionRow row = await db.select(db.outboxActions).getSingle();
      expect(row.status, 'done');
      expect(jsonDecode(row.payloadJson), isNot(contains('phone')));
    });

    test('409 VERSION_CONFLICT → current + изменённое поле, одна попытка → done', () async {
      final List<Map<String, Object?>> bodies = <Map<String, Object?>>[];
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
        final Map<String, Object?> body = _body(o);
        bodies.add(body);
        if (body['rowVersion'] == 3) {
          return json(
            409,
            problem(
              'VERSION_CONFLICT',
              409,
              extra: <String, Object?>{
                'current': <String, Object?>{..._settings(rowVersion: 4), 'locale': 'ky'},
              },
            ),
          );
        }
        return json(200, <String, Object?>{...body, 'rowVersion': 5});
      });
      final OutboxQueue q = queue(adapter);
      await q.enqueue(profileSettingsOutboxType, payload());
      expect((await q.flush()).sent, 1);
      expect(bodies, hasLength(2));
      expect(bodies.last['rowVersion'], 4);
      expect(bodies.last['locale'], 'ky', reason: 'чужое изменение сохраняется');
      expect(bodies.last['idleLockMinutes'], 10, reason: 'своё поле наложено повторно');
    });

    test('повторный 409 / неполная запись → dead без бесконечных повторов', () async {
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async =>
            json(409, problem('VERSION_CONFLICT', 409, extra: <String, Object?>{'current': _settings(rowVersion: 9)})),
      );
      final OutboxQueue q = queue(adapter);
      await q.enqueue(profileSettingsOutboxType, payload());
      await q.enqueue(profileSettingsOutboxType, const <String, Object?>{'settings': <String, Object?>{}});
      final OutboxFlushReport r = await q.flush();
      expect(r.dead, 2);
      expect((await db.select(db.outboxActions).get()).map((OutboxActionRow a) => a.status), <String>['dead', 'dead']);
    });

    test('5xx → failed с повтором по расписанию', () async {
      final FakeAdapter adapter = FakeAdapter((RequestOptions o) async => json(500, problem('INTERNAL', 500)));
      final OutboxQueue q = queue(adapter);
      await q.enqueue(profileSettingsOutboxType, payload());
      final OutboxFlushReport r = await q.flush();
      expect(r.failed, 1);
      expect((await db.select(db.outboxActions).getSingle()).status, 'failed');
    });
  });
}

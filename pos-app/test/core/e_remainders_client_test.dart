// Остатки этапов D/E на клиенте (E_spec_sync.md §3; OpenAPI 1.1.0):
// - Problem.until (423 PIN_LOCKED) и причина UNLOCK_REQUIRED; причина отказа refresh (D SS-03);
// - кэш профиля для холодного старта (D AU-06) и его очистка вместе с сессией;
// - замена biometric_refresh тем же ключом (D AU-07);
// - R1-N-01: чтение настроек сканера из закрытой БД не даёт необработанной асинхронной ошибки;
// - единый presenter наименования клиента (D PR-09).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/hardware/hardware_providers.dart';
import 'package:optomstroy/core/hardware/scanner_settings_store.dart';
import 'package:optomstroy/core/hardware/scanner_wedge_config.dart';
import 'package:optomstroy/core/network/auth/token_refresher.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/problem.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/customer_display_name.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';

import 'storage/in_memory_secure_storage.dart';

DioException _problem(int status, Map<String, Object?> body) {
  final RequestOptions options = RequestOptions(path: '/x');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<Object?>(requestOptions: options, statusCode: status, data: body),
  );
}

Map<String, Object?> _body(String code, int status, [Map<String, Object?> extra = const <String, Object?>{}]) =>
    <String, Object?>{'type': 't', 'title': 't', 'status': status, 'code': code, 'requestId': 'r', ...extra};

final class _Replacer implements BiometricAuthenticator, BiometricSecretReplacer {
  _Replacer(this.replaceResult);

  BiometricResult<void> replaceResult;
  final List<String> calls = <String>[];

  @override
  Future<BiometricCapability> capability() async => BiometricCapability.none;

  @override
  Future<bool> hasStoredSecret() async => true;

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async => const BiometricResult<String>.success('s');

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async {
    calls.add('store');
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<BiometricResult<void>> replace(String secret, BiometricPromptText prompt) async {
    calls.add('replace');
    return replaceResult;
  }

  @override
  Future<void> clear() async {}

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult<void>.failure(BiometricError.notAvailable);
}

void main() {
  group('Problem 1.1.0', () {
    test('423 PIN_LOCKED: until → AuthFailure.lockedUntil (UTC)', () {
      final Failure f = ErrorMapper.fromDio(
        _problem(423, _body('PIN_LOCKED', 423, <String, Object?>{'until': '2026-10-22T09:15:00+06:00'})),
      );
      expect(f, isA<AuthFailure>());
      final AuthFailure auth = f as AuthFailure;
      expect(auth.reason, AuthReason.pinLocked);
      expect(auth.lockedUntil, DateTime.utc(2026, 10, 22, 3, 15));
      expect(
        Problem.fromJson(_body('PIN_LOCKED', 423, <String, Object?>{'until': '2026-10-22T03:15:00Z'})).until,
        DateTime.utc(2026, 10, 22, 3, 15),
      );
    });

    test('401 UNLOCK_REQUIRED: известные и неизвестная причины', () {
      UnlockRequiredReason? of(String? reason) =>
          Problem.fromJson(_body('UNLOCK_REQUIRED', 401, <String, Object?>{'reason': ?reason})).unlockReason;
      expect(of('idle_lock'), UnlockRequiredReason.idleLock);
      expect(of('refresh_replay'), UnlockRequiredReason.refreshReplay);
      expect(of('emergency_code'), UnlockRequiredReason.emergencyCode);
      expect(of('новая_причина'), UnlockRequiredReason.unknown, reason: 'неизвестное — как SCR-08');
      expect(of(null), UnlockRequiredReason.unknown);
      expect(Problem.fromJson(_body('FORBIDDEN', 403, <String, Object?>{'reason': 'idle_lock'})).unlockReason, isNull);
      final AuthFailure f =
          ErrorMapper.fromDio(
                _problem(401, _body('UNLOCK_REQUIRED', 401, <String, Object?>{'reason': 'emergency_code'})),
              )
              as AuthFailure;
      expect((f.reason, f.unlockReason), (AuthReason.unlockRequired, 'emergency_code'));
    });

    test('refresh: причина UNLOCK_REQUIRED и SESSION_REVOKED сохраняется (D SS-03)', () async {
      Future<RefreshResult> run(Map<String, Object?> body, int status) {
        final Dio dio = Dio()
          ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) => h.reject(_problem(status, body))));
        return DioTokenRefresher(dio).refresh('r');
      }

      final RefreshResult unlock = await run(
        _body('UNLOCK_REQUIRED', 401, <String, Object?>{'reason': 'refresh_replay'}),
        401,
      );
      expect((unlock as RefreshUnlockRequired).reason, UnlockRequiredReason.refreshReplay);
      final RefreshResult ended = await run(_body('SESSION_REVOKED', 401, <String, Object?>{'reason': 'admin'}), 401);
      expect(((ended as RefreshSessionEnded).code, ended.reason), ('SESSION_REVOKED', 'admin'));
    });
  });

  group('кэш профиля (D AU-06)', () {
    test('запись/чтение без телефона; ФИО — отдельный ключ; очищается вместе с refresh', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final ProfileCacheStore cache = ProfileCacheStore(storage);
      expect(await cache.read(), isNull);
      await cache.write(
        const CachedProfile(
          kind: UserKind.staff,
          status: UserStatus.active,
          roles: <RoleCode>[RoleCode.cashier],
          pinSet: true,
          biometricsEnabled: false,
          displayName: 'Тестов Кассир',
        ),
      );
      expect(await storage.read(SecureKey.profileCache), isNot(contains('Тестов')));
      expect(await storage.read(SecureKey.profileDisplayName), 'Тестов Кассир');
      final CachedProfile? read = await cache.read();
      expect((read!.kind, read.pinSet, read.displayName), (UserKind.staff, true, 'Тестов Кассир'));
      expect(read.roles, <RoleCode>[RoleCode.cashier]);
      expect(read.toString(), isNot(contains('Тестов')));

      await storage.write(SecureKey.refreshToken, 'r');
      await TokenStore(storage).clearSession();
      expect(await cache.read(), isNull, reason: 'logout / SESSION_REVOKED удаляют SecureKey.session');
      expect(CachedProfile.decode('{broken'), isNull);
    });
  });

  group('biometric_refresh тем же ключом (D AU-07)', () {
    test('replace успешен — store не вызывается; нет ключа — store; отказ ОС — без store', () async {
      final _Replacer ok = _Replacer(const BiometricResult<void>.success(null));
      expect(
        await BiometricUnlockAdapter(authenticator: ok, storage: InMemorySecureStorage()).storeSecret('n'),
        isTrue,
      );
      expect(ok.calls, <String>['replace']);

      final _Replacer missing = _Replacer(const BiometricResult<void>.failure(BiometricError.noCredential));
      expect(
        await BiometricUnlockAdapter(authenticator: missing, storage: InMemorySecureStorage()).storeSecret('n'),
        isTrue,
      );
      expect(missing.calls, <String>['replace', 'store']);

      final _Replacer cancelled = _Replacer(const BiometricResult<void>.failure(BiometricError.cancelled));
      expect(
        await BiometricUnlockAdapter(authenticator: cancelled, storage: InMemorySecureStorage()).storeSecret('n'),
        isFalse,
      );
      expect(cancelled.calls, <String>['replace']);
    });
  });

  group('R1-N-01: настройки сканера и закрытая БД', () {
    test('чтение из БД, закрытой во время запроса, не бросает асинхронную ошибку; остаются умолчания', () async {
      final AppDatabase db = AppDatabase(NativeDatabase.memory());
      await DriftScannerSettingsStore(db).load();
      await db.close();
      // Источник ошибки R1-N-01: запрос к закрытой БД бросает (раньше — из `unawaited(_load(store))`).
      await expectLater(DriftScannerSettingsStore(db).load(), throwsA(isA<StateError>()));
      final List<Object> uncaught = <Object>[];
      await runZonedGuarded(() async {
        final ProviderContainer c = ProviderContainer(
          overrides: <Override>[scannerSettingsStoreProvider.overrideWithValue(DriftScannerSettingsStore(db))],
        );
        expect(c.read(scannerConfigProvider), const ScannerWedgeConfig());
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(c.read(scannerConfigProvider), const ScannerWedgeConfig());
        await c.read(scannerConfigProvider.notifier).setInterKeyThresholdMs(80);
        c.dispose();
      }, (Object e, StackTrace _) => uncaught.add(e));
      expect(uncaught, isEmpty);
    });

    test('смена хранилища (другой пользователь): результат прежнего чтения не применяется', () async {
      final Completer<ScannerWedgeConfig> slow = Completer<ScannerWedgeConfig>();
      final _SlowStore first = _SlowStore(slow.future);
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[scannerSettingsStoreProvider.overrideWith((ref) => ref.watch(_storeSwitch))],
      );
      addTearDown(c.dispose);
      c.read(_storeSwitch.notifier).set(first);
      c.read(scannerConfigProvider);
      c.read(_storeSwitch.notifier).set(MemoryScannerSettingsStore());
      expect(c.read(scannerConfigProvider), const ScannerWedgeConfig());
      slow.complete(const ScannerWedgeConfig(interKeyThreshold: Duration(milliseconds: 100)));
      await Future<void>.delayed(Duration.zero);
      expect(c.read(scannerConfigProvider), const ScannerWedgeConfig());
    });
  });

  test('presenter наименования клиента (D PR-09)', () {
    expect(
      CustomerDisplayName.of(confirmed: false, displayName: 'ОсОО «Строй»', displayNameMasked: 'ОсОО «Стр***»'),
      'ОсОО «Стр***»',
    );
    expect(
      CustomerDisplayName.of(confirmed: true, displayName: '  ОсОО  «Строй» ', displayNameMasked: 'x'),
      'ОсОО «Строй»',
    );
    expect(CustomerDisplayName.of(confirmed: true, displayNameMasked: 'ОсОО «Стр***»'), 'ОсОО «Стр***»');
    expect(CustomerDisplayName.of(confirmed: false, displayNameMasked: '   '), isNull);
  });

  test('clockProvider доступен без привязок (для DriftCatalogUserSettingsStore)', () {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(clockProvider), isNotNull);
  });
}

final class _SlowStore implements ScannerSettingsStore {
  _SlowStore(this._value);

  final Future<ScannerWedgeConfig> _value;

  @override
  Future<ScannerWedgeConfig> load() => _value;

  @override
  Future<void> save(ScannerWedgeConfig config) async {}
}

final _storeSwitch = NotifierProvider<_StoreSwitch, ScannerSettingsStore>(_StoreSwitch.new);

final class _StoreSwitch extends Notifier<ScannerSettingsStore> {
  @override
  ScannerSettingsStore build() => MemoryScannerSettingsStore();

  void set(ScannerSettingsStore value) => state = value;
}

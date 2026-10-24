// Провайдеры core (06 §6.10): сборка Dio, состояние версии клиента, OnlineStatus.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/network/auth/token_refresher.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/utils/clock.dart';

import '../connectivity/connectivity_watcher_test.dart' show FakeSignal;
import '../database/test_database.dart';
import '../network/fake_adapter.dart';
import '../storage/in_memory_secure_storage.dart';

void main() {
  configureSqliteForTests();

  test('сборка Dio, OnlineStatus и запись версии в app_meta', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final watcher = ConnectivityWatcher(FakeSignal(true));
    final container = ProviderContainer(
      overrides: [
        clientMetaProvider.overrideWithValue(
          const ClientMeta(appVersion: '1.0.0+1', platform: ClientPlatform.windows, deviceId: 'd'),
        ),
        secureStorageProvider.overrideWithValue(InMemorySecureStorage()),
        appDatabaseProvider.overrideWithValue(db),
        connectivityWatcherProvider.overrideWithValue(watcher),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    expect(container.read(clockProvider), isA<SystemClock>());
    expect(container.read(appConfigProvider).apiBaseUrl.path, '/api/v1');
    expect(container.read(appVersionStateProvider), AppVersionState.initial);

    final dio = container.read(dioProvider);
    final adapter = FakeAdapter(
      (o) async =>
          json(200, {}, headers: {'X-Min-App-Version': 'windows=2.0.0', 'X-Recommended-App-Version': 'windows=2.1.0'}),
    );
    dio.httpClientAdapter = adapter;
    final statuses = <AsyncValue<OnlineStatus>>[];
    container.listen(onlineStatusProvider, (_, next) => statuses.add(next), fireImmediately: true);

    await dio.get<Object?>('/settings/public', options: apiOptions(skipAuth: true));
    await pumpEventQueue();

    expect(adapter.requests.single.headers[ApiHeaders.platform], 'windows');
    expect(container.read(appVersionStateProvider).status, AppVersionStatus.updateRequired);
    expect(await db.appMetaDao.read(AppMetaDao.minAppVersionSeenKey), '2.0.0');
    expect(await db.appMetaDao.read(AppMetaDao.recommendedAppVersionSeenKey), '2.1.0');
    expect(statuses.last.value, OnlineStatus.online);
  });

  test('clientMetaProvider без переопределения — явная ошибка конфигурации', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(() => container.read(clientMetaProvider), throwsA(anything));
    expect(container.read(appDatabaseProvider), isNull);
  });

  test('DioTokenRefresher: 5xx/429/сеть → transient; 400 → ended', () async {
    Future<RefreshResult> run(FakeHandler handler) {
      final dio = Dio(BaseOptions(baseUrl: 'https://api.test/api/v1'))..httpClientAdapter = FakeAdapter(handler);
      return DioTokenRefresher(dio).refresh('r');
    }

    expect(await run((o) async => json(503, null)), isA<RefreshTransientFailure>());
    expect(await run((o) async => json(429, problem('RATE_LIMITED', 429))), isA<RefreshTransientFailure>());
    expect(await run((o) async => transportError(o, DioExceptionType.connectionError)), isA<RefreshTransientFailure>());
    expect(await run((o) async => json(400, problem('VALIDATION_FAILED', 400))), isA<RefreshSessionEnded>());
  });
}

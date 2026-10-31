// Корень DI веб-демо (12 T-DEMO-001 (2); 15 ADR-113 п. 1; 06 §6.10):
// - `demoOverrides` — ровно три провайдера ядра, ни одного из них нет в `appOverrides`: контейнер
//   `[...appOverrides, ...demoOverrides]` собирается без AssertionError (контроль: двойное переопределение ловится);
// - `API_BASE_URL` — от origin сайта; основной Dio (`dioProvider`) и Dio для `POST /auth/refresh` идут через мост, как и
//   `/health`; ни одного HttpClient dart:io (в сеть мимо моста ничего не уходит);
// - точка входа запускается только при `DEMO_BACKEND=browser`, `ENV` ≠ `prod` и мосте протокола 1; проверка синхронна,
//   а ошибка запуска после первого `await` доходит до страницы (ревью DB-3).
// Часть (1) T-DEMO-001 — правило DM-01 в `python -I -X utf8 scripts/check_layers.py --self-test`.
// VM, фейковый мост; синтетические данные, без сети.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/app/demo/demo_bridge.dart';
import 'package:optomstroy/app/demo/demo_bridge_adapter.dart';
import 'package:optomstroy/app/demo/demo_bridge_stub.dart';
import 'package:optomstroy/app/demo/demo_health_probe.dart';
import 'package:optomstroy/app/demo/demo_overrides.dart';
import 'package:optomstroy/app/demo/main_web_demo.dart';
import 'package:optomstroy/app/demo/main_web_demo.dart' as entry show main;
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/backend_health.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

import '../../core/storage/in_memory_secure_storage.dart';
import 'fake_demo_bridge.dart';

const String _deviceId = '7c9e6679-7425-40de-944b-e07fc1f90ae7';
const Map<String, String> _devConstants = <String, String>{'ENV': 'dev', 'LOG_LEVEL': 'info'};

final class _Net implements NetworkSignalSource {
  @override
  Future<bool> hasNetwork() async => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

/// Любая попытка создать HttpClient dart:io — обращение в сеть мимо моста.
final class _NoNetwork extends HttpOverrides {
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('веб-демо: запрос в сеть мимо моста');
  }
}

/// Сервер демо в фейковом мосте: refresh, профиль, `/health`.
DemoBridgeResponse _server(FakeBridgeCall call) => switch (call.url) {
  '/api/v1/auth/refresh' => bridgeJson(200, <String, Object?>{
    'accessToken': 'a9',
    'accessExpiresIn': 900,
    'refreshToken': 'r9',
    'refreshExpiresAt': '2026-11-28T00:00:00.000Z',
    'sid': '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55',
  }),
  '/api/v1/me' => bridgeJson(200, <String, Object?>{'id': 'u-1'}),
  '/health' => bridgeJson(
    200,
    <String, Object?>{'status': 'ok'},
    headers: const <(String, String)>[('x-request-id', 'rid-health')],
  ),
  _ => bridgeJson(404, <String, Object?>{'code': 'NOT_FOUND', 'status': 404}, contentType: 'application/problem+json'),
};

/// Корень приложения веб-демо: `[...appOverrides, ...demoOverrides]` + то, что в приложении даёт bootstrap и платформа
/// (метаданные клиента, secure storage, сеть ОС).
ProviderContainer _root(FakeDemoBridge bridge, {Map<SecureKey, String> secure = const <SecureKey, String>{}}) {
  final ProviderContainer c = ProviderContainer(
    overrides: <Override>[
      ...appOverrides,
      ...demoOverrides(bridge, origin: demoTestOrigin, constants: _devConstants),
      clientMetaProvider.overrideWithValue(
        const ClientMeta(appVersion: '0.1.0+1', platform: ClientPlatform.windows, deviceId: _deviceId),
      ),
      secureStorageProvider.overrideWithValue(InMemorySecureStorage(secure)),
      connectivityWatcherProvider.overrideWithValue(ConnectivityWatcher(_Net())),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('demoOverrides', () {
    test('ровно три провайдера ядра; контейнер [...appOverrides, ...demoOverrides] без AssertionError', () {
      final FakeDemoBridge bridge = FakeDemoBridge();
      final List<Override> demo = demoOverrides(bridge, origin: demoTestOrigin, constants: _devConstants);

      expect(demo, hasLength(3));
      final ProviderContainer c = ProviderContainer(overrides: <Override>[...appOverrides, ...demo]);
      addTearDown(c.dispose);
      expect(c.read(httpClientAdapterProvider), isA<DemoBridgeAdapter>());

      // Контроль: двойное переопределение Riverpod ловит в debug — значит, проверка выше настоящая.
      expect(() => ProviderContainer(overrides: <Override>[...demo, ...demo]), throwsA(isA<AssertionError>()));
      for (final Override o in demo) {
        expect(
          () => ProviderContainer(overrides: <Override>[...appOverrides, ...demo, o]),
          throwsA(isA<AssertionError>()),
        );
      }
    });

    test('API_BASE_URL — origin сайта + /api/v1, остальное из констант сборки; ENV не prod', () {
      final ProviderContainer c = _root(FakeDemoBridge());

      final AppConfig config = c.read(appConfigProvider);
      expect(config.apiBaseUrl, Uri.parse('$demoTestOrigin/api/v1'));
      expect(config.environment, AppEnvironment.dev);
      expect(config.logLevel, LogLevel.info);
      expect(config.appDataDir, isNull);
      expect(DioBackendHealthProbe.healthUriFor(config.apiBaseUrl), Uri.parse('$demoTestOrigin/health'));
    });

    test('dioProvider и Dio для POST /auth/refresh идут через мост; HttpClient dart:io не создаётся', () async {
      final FakeDemoBridge bridge = FakeDemoBridge(handler: _server);
      final _NoNetwork network = _NoNetwork();

      await HttpOverrides.runWithHttpOverrides(() async {
        // Холодный старт: access-токена нет, refresh есть → сначала POST /auth/refresh «голым» Dio, затем запрос.
        final ProviderContainer c = _root(bridge, secure: <SecureKey, String>{SecureKey.refreshToken: 'r1'});
        final Dio dio = c.read(dioProvider);
        expect(identical(dio.httpClientAdapter, c.read(httpClientAdapterProvider)), isTrue);

        final Response<Object?> me = await dio.get<Object?>('/me');

        expect(me.data, <String, Object?>{'id': 'u-1'});
      }, network);

      expect(bridge.calls.map((FakeBridgeCall x) => '${x.request.method} ${x.url}'), <String>[
        'POST /api/v1/auth/refresh',
        'GET /api/v1/me',
      ]);
      final FakeBridgeCall refresh = bridge.calls[0];
      final FakeBridgeCall me = bridge.calls[1];
      expect(refresh.jsonBody, <String, Object?>{'refreshToken': 'r1'});
      expect(refresh.header(ApiHeaders.authorization), isNull);
      expect(me.header(ApiHeaders.authorization), 'Bearer a9');
      for (final FakeBridgeCall call in bridge.calls) {
        expect(call.header(ApiHeaders.deviceId), _deviceId);
        expect(call.header(ApiHeaders.appVersion), '0.1.0+1');
        expect(call.header(ApiHeaders.requestId), isNotNull);
      }
      expect(network.attempts, 0);
    });

    test('backendHealthProbeProvider: /health через тот же мост', () async {
      final FakeDemoBridge bridge = FakeDemoBridge(handler: _server);
      final _NoNetwork network = _NoNetwork();
      late BackendHealthReport report;

      await HttpOverrides.runWithHttpOverrides(() async {
        final ProviderContainer c = _root(bridge);
        final BackendHealthProbe probe = c.read(backendHealthProbeProvider);
        expect(probe, isA<DemoHealthProbe>());
        expect((probe as DemoHealthProbe).healthUri, Uri.parse('$demoTestOrigin/health'));

        report = await c.read(backendHealthReportProvider.future);
        expect(await c.read(backendHealthProvider.future), BackendHealthStatus.ok);
      }, network);

      expect(report.ok, isTrue);
      expect(report.httpStatus, 200);
      expect(report.requestId, 'rid-health');
      expect(bridge.calls.map((FakeBridgeCall x) => x.url), <String>['/health']);
      expect(network.attempts, 0);
    });

    test('сервер демо остановлен (fatal) → /health недоступен, без сети', () async {
      final FakeDemoBridge bridge = FakeDemoBridge(ready: false);
      final ProviderContainer c = _root(bridge);
      final Future<BackendHealthReport> pending = c.read(backendHealthProbeProvider).check();
      await settle();

      bridge.failReady(DemoBridgeErrorCode.fatal, 'База демо не открылась');
      final BackendHealthReport report = await pending;

      expect(report.ok, isFalse);
      expect(report.errorType, DioExceptionType.connectionError.name);
      expect(bridge.calls, isEmpty);
    });
  });

  group('запуск точки входа (main_web_demo.dart)', () {
    test('DEMO_BACKEND=browser, ENV dev/staging (или пусто — dev) и мост протокола 1 — можно', () {
      for (final String env in <String>['dev', 'staging', '', ' DEV ']) {
        expect(
          () => ensureDemoLaunchAllowed(demoBackend: 'browser', environment: env, bridge: FakeDemoBridge()),
          returnsNormally,
        );
      }
    });

    final Map<String, void Function()> refused = <String, void Function()>{
      'DEMO_BACKEND не задан': () =>
          ensureDemoLaunchAllowed(demoBackend: '', environment: 'dev', bridge: FakeDemoBridge()),
      'DEMO_BACKEND=server': () =>
          ensureDemoLaunchAllowed(demoBackend: 'server', environment: 'dev', bridge: FakeDemoBridge()),
      'ENV=prod': () => ensureDemoLaunchAllowed(demoBackend: 'browser', environment: 'prod', bridge: FakeDemoBridge()),
      'ENV неизвестен': () =>
          ensureDemoLaunchAllowed(demoBackend: 'browser', environment: 'production', bridge: FakeDemoBridge()),
      'нет моста (VM-заглушка)': () =>
          ensureDemoLaunchAllowed(demoBackend: 'browser', environment: 'dev', bridge: createDemoBridge()),
      'мост другого протокола': () =>
          ensureDemoLaunchAllowed(demoBackend: 'browser', environment: 'dev', bridge: FakeDemoBridge(protocol: 2)),
    };
    refused.forEach((String name, void Function() launch) {
      test('$name → StateError с понятным текстом', () {
        expect(
          launch,
          throwsA(isA<StateError>().having((StateError e) => e.message, 'message', startsWith('Веб-демо:'))),
        );
      });
    });

    test('main(): проверка сборки синхронна — StateError до первого await, а не в брошенном Future', () {
      // Загрузчик Flutter web вызывает main() как VoidCallback и Future не ждёт: только синхронное исключение
      // отклоняет appRunner.runApp() и показывает ошибку на экране загрузки (ревью DB-3). В тесте DEMO_BACKEND пуст.
      Future<void>? started;
      Object? thrown;
      try {
        started = entry.main();
      } on StateError catch (e) {
        thrown = e;
      }
      expect(started, isNull);
      expect(thrown, isA<StateError>().having((StateError e) => e.message, 'message', startsWith('Веб-демо:')));
    });

    test('runWebDemo: ошибка до runApp (после первого await) — в журнал и странице, Future без ошибки', () async {
      final List<Object> reported = <Object>[];
      final List<LogRecord> logs = <LogRecord>[];
      final StreamSubscription<LogRecord> sub = Logger.root.onRecord.listen(logs.add);
      addTearDown(sub.cancel);

      await runWebDemo(
        FakeDemoBridge(),
        start: (DemoBridge _) async {
          await Future<void>.delayed(Duration.zero);
          throw const _VersionJsonUnavailable();
        },
        onStartError: reported.add,
      );

      expect(reported.single, isA<_VersionJsonUnavailable>());
      expect(
        logs.where((LogRecord r) => r.loggerName == 'demo' && r.level == Level.SEVERE).single.error,
        isA<_VersionJsonUnavailable>(),
      );
    });

    test('runWebDemo: удачный запуск — странице ничего не сообщается', () async {
      final List<Object> reported = <Object>[];
      DemoBridge? used;
      final FakeDemoBridge bridge = FakeDemoBridge();

      await runWebDemo(
        bridge,
        start: (DemoBridge b) async {
          used = b;
        },
        onStartError: reported.add,
      );

      expect(used, same(bridge));
      expect(reported, isEmpty);
    });

    test('VM: reportDemoStartError без страницы ничего не делает', () {
      expect(() => reportDemoStartError(StateError('x')), returnsNormally);
    });

    test('VM: createDemoBridge — заглушка без моста, запросы отклоняются', () async {
      final DemoBridge bridge = createDemoBridge();

      expect(bridge, isA<UnavailableDemoBridge>());
      expect(bridge.isAvailable, isFalse);
      expect(bridge.protocol, isNull);
      expect(() => bridge.origin, throwsStateError);
      await expectLater(bridge.whenReady(), throwsA(isA<DemoBridgeException>()));
    });
  });
}

/// Сбой до `runApp` (например, `version.json` не загрузился).
final class _VersionJsonUnavailable implements Exception {
  const _VersionJsonUnavailable();
}

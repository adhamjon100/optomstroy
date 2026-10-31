// Композиционный корень ядра (06 §6.10, L-8): провайдеры core.
//
// Переопределяются в app/bootstrap.dart (RM-C-004 → FE, см. lib/core/README.md):
// - [clientMetaProvider] — `ClientMeta.load(secureStorage)` (версия, платформа, deviceId);
// - [appDatabaseProvider] — `AppDatabase.forUser(userId)` после входа (07 §11.1 п.2).
// Presentation читает только read-only провайдеры состояния (L-9):
// [onlineStatusProvider], [appVersionStateProvider], [backendHealthProvider].
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/backend_health.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/network/dio_client.dart';
import 'package:optomstroy/core/network/etag_cache.dart';
import 'package:optomstroy/core/network/interceptors/auth_interceptor.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.fromEnvironment());

final clockProvider = Provider<Clock>((ref) => const SystemClock());

final secureStorageProvider = Provider<SecureStorage>((ref) => FlutterSecureStorageAdapter());

/// Метаданные клиента; переопределяется в bootstrap значением `ClientMeta.load`.
final clientMetaProvider = Provider<ClientMeta>(
  (ref) => throw UnimplementedError('clientMetaProvider: переопределите в bootstrap (ClientMeta.load)'),
);

/// БД текущего пользователя; `null` — пользователь ещё не известен (до входа).
final appDatabaseProvider = Provider<AppDatabase?>((ref) => null);

final tokenStoreProvider = Provider<TokenStore>(_tokenStore); // check-secrets: allow (имя провайдера)

TokenStore _tokenStore(Ref ref) => TokenStore(ref.watch(secureStorageProvider));

final etagCacheProvider = Provider<EtagCache>((ref) => EtagCache());

final connectivityWatcherProvider = Provider<ConnectivityWatcher>((ref) {
  final watcher = ConnectivityWatcher(ConnectivityPlusSource());
  unawaited(watcher.start());
  ref.onDispose(watcher.dispose);
  return watcher;
});

/// Доступность backend (OfflineBanner, SCR-90) — read-only для presentation (L-9).
final onlineStatusProvider = StreamProvider<OnlineStatus>((ref) {
  final watcher = ref.watch(connectivityWatcherProvider);
  final controller = StreamController<OnlineStatus>();
  controller.add(watcher.current);
  final sub = watcher.status.listen(controller.add);
  ref.onDispose(() async {
    await sub.cancel();
    await controller.close();
  });
  return controller.stream;
});

final appVersionControllerProvider = Provider<AppVersionController>((ref) {
  final meta = ref.watch(clientMetaProvider);
  final controller = AppVersionController(
    currentVersion: meta.appVersion,
    platform: meta.platform?.name,
    sink: (key, value) async => ref.read(appDatabaseProvider)?.appMetaDao.write(key, value),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// Состояние версии клиента: SCR-90 «требуется обновление» / мягкий баннер (RM-C-015).
final appVersionStateProvider = NotifierProvider<AppVersionStateNotifier, AppVersionState>(AppVersionStateNotifier.new);

final class AppVersionStateNotifier extends Notifier<AppVersionState> {
  @override
  AppVersionState build() {
    final controller = ref.watch(appVersionControllerProvider);
    void listener() => state = controller.value;
    controller.addListener(listener);
    ref.onDispose(() => controller.removeListener(listener));
    return controller.value;
  }
}

/// События сессии из AuthInterceptor для core/session (SessionController, RM-D-*).
final sessionEventsProvider = Provider<StreamController<SessionEvent>>((ref) {
  final controller = StreamController<SessionEvent>.broadcast();
  ref.onDispose(controller.close);
  return controller;
});

/// Транспорт Dio: `null` — по умолчанию платформы. Переопределяется тестами (integration_test: потеря ответа
/// `POST /orders` для проверки неизвестного результата, ядро §22.6) и веб-демо (`app/demo/demo_overrides.dart`: мост
/// к серверу в Web Worker страницы, 15 ADR-113); приложение (`lib/main.dart`) его не задаёт. Адаптер получают и
/// основной Dio, и Dio для `POST /auth/refresh` (`DioClient`).
final httpClientAdapterProvider = Provider<HttpClientAdapter?>((ref) => null);

final dioProvider = Provider<Dio>((ref) {
  final watcher = ref.watch(connectivityWatcherProvider);
  final dio = DioClient.create(
    DioClientDeps(
      config: ref.watch(appConfigProvider),
      meta: () => ref.read(clientMetaProvider),
      tokens: ref.watch(tokenStoreProvider),
      appVersion: ref.watch(appVersionControllerProvider),
      etagCache: ref.watch(etagCacheProvider),
      onOutcome: watcher.report,
      onSessionEvent: ref.watch(sessionEventsProvider).add,
      adapter: ref.watch(httpClientAdapterProvider),
    ),
  );
  ref.onDispose(dio.close);
  return dio;
});

/// Доступность backend по `GET /health` для presentation (L-9): заглушка «нет сессии» (RM-C-014),
/// далее — OfflineBanner / SCR-90.
enum BackendHealthStatus {
  /// `GET /health` → 200 `{status: ok}`.
  ok,

  /// Нет ответа или ответ не 200.
  unavailable,
}

/// Порт проверки `GET /health`; в тестах переопределяется фейком.
final backendHealthProbeProvider = Provider<BackendHealthProbe>((ref) {
  final probe = DioBackendHealthProbe(ref.watch(appConfigProvider));
  ref.onDispose(probe.close);
  return probe;
});

/// Последняя проверка `GET /health` (полный итог — для диагностики и integration-теста RM-C-014).
final backendHealthReportProvider = FutureProvider<BackendHealthReport>(
  (ref) => ref.watch(backendHealthProbeProvider).check(),
);

/// Доступность backend — read-only для presentation (L-9). Повтор — `ref.invalidate(backendHealthReportProvider)`.
final backendHealthProvider = FutureProvider<BackendHealthStatus>((ref) async {
  final report = await ref.watch(backendHealthReportProvider.future);
  return report.ok ? BackendHealthStatus.ok : BackendHealthStatus.unavailable;
});

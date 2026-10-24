// Общая обвязка тестов сессии (RM-D-009): настоящий DioClient (все интерсепторы) с фейковым транспортом,
// in-memory secure storage, управляемые часы и ProviderContainer с SessionController.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/network/dio_client.dart';
import 'package:optomstroy/core/network/etag_cache.dart';
import 'package:optomstroy/core/network/interceptors/auth_interceptor.dart';
import 'package:optomstroy/core/session/pending_logout.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_policy.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';

import '../network/fake_adapter.dart';
import '../storage/in_memory_secure_storage.dart';

export '../network/fake_adapter.dart';

const String testDeviceId = '1b4e28ba-2d11-4d4f-9f4a-0c3a6f6e7d01';
const String staffUserId = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f01';
const String otherUserId = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f02';
final DateTime t0 = DateTime.utc(2026, 10, 22, 9);

/// JWT без подписи (клиент подпись не проверяет; сервер — да): только payload для UX-claims.
String fakeJwt({String kind = 'staff', String sub = staffUserId, DateTime? exp, String tag = 'a'}) {
  String part(Map<String, Object?> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  // AuthInterceptor сравнивает `exp` с системными часами — срок от реального «сейчас».
  final expiry = exp ?? DateTime.now().toUtc().add(const Duration(minutes: 15));
  return '${part({'alg': 'EdDSA', 'typ': 'JWT'})}.'
      '${part({
        'sub': sub,
        'kind': kind,
        'sid': 'sid-1',
        'roles': <String>['cashier'],
        'exp': expiry.millisecondsSinceEpoch ~/ 1000,
        'tag': tag,
      })}.'
      'sig';
}

Map<String, Object?> tokenPair(String access, String refresh) => <String, Object?>{
  'accessToken': access,
  'accessExpiresIn': 900,
  'refreshToken': refresh,
  'refreshExpiresAt': '2026-10-29T00:00:00.000Z',
  'sid': '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55',
};

Map<String, Object?> stepUpToken(String token, String operation, {DateTime? expiresAt}) => <String, Object?>{
  'stepUpToken': token,
  'expiresAt': (expiresAt ?? t0.add(const Duration(minutes: 15))).toIso8601String(),
  'method': 'pin',
  'scope': <String>[operation],
};

Map<String, Object?> stepUpRequired(String operation) => problem(
  'STEP_UP_REQUIRED',
  403,
  extra: <String, Object?>{
    'stepUp': <String, Object?>{
      'operation': operation,
      'allowedMethods': <String>['pin', 'otp'],
    },
  },
);

/// Обвязка: [handler] получает каждый запрос (путь без `/api/v1`).
final class SessionHarness {
  SessionHarness(
    FakeHandler handler, {
    String? refresh,
    String? access,
    SessionPolicy policy = const SessionPolicy(),
    String appVersion = '1.4.2+87',
    bool withDatabase = false,
    List<Override> overrides = const <Override>[],
    BiometricAuthenticator biometrics = const NoBiometricAuthenticator(),
    bool pendingLogoutAutoRetry = false,
  }) {
    storage = InMemorySecureStorage(<SecureKey, String>{
      SecureKey.deviceId: testDeviceId,
      SecureKey.refreshToken: ?refresh, // check-secrets: allow (тест)
    });
    tokens = TokenStore(storage);
    if (access != null) unawaited(tokens.saveTokens(accessToken: access, refreshToken: refresh ?? 'r0'));
    adapter = FakeAdapter(handler);
    clock = FixedClock(t0);
    appVersionController = AppVersionController(currentVersion: appVersion, platform: 'android');
    dio = DioClient.create(
      DioClientDeps(
        config: AppConfig.fromMap(const <String, String>{'API_BASE_URL': 'https://api.test/api/v1', 'ENV': 'staging'}),
        meta: () => const ClientMeta(appVersion: '1.4.2+87', platform: ClientPlatform.android, deviceId: testDeviceId),
        tokens: tokens,
        appVersion: appVersionController,
        etagCache: EtagCache(),
        onSessionEvent: events.add,
        adapter: adapter,
        sleep: (_) async {},
      ),
    );
    if (withDatabase) db = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: <Override>[
        secureStorageProvider.overrideWithValue(storage),
        tokenStoreProvider.overrideWithValue(tokens),
        dioProvider.overrideWithValue(dio),
        clockProvider.overrideWithValue(clock),
        sessionPolicyProvider.overrideWithValue(policy),
        clientMetaProvider.overrideWithValue(
          const ClientMeta(appVersion: '1.4.2+87', platform: ClientPlatform.android, deviceId: testDeviceId),
        ),
        appVersionControllerProvider.overrideWithValue(appVersionController),
        // Порт биометрии: хук очистки сессии вызывает `clear` (D-MN-04); без канала платформы в unit-тестах.
        biometricAuthenticatorProvider.overrideWithValue(biometrics),
        if (db != null) appDatabaseProvider.overrideWithValue(db),
        // Отложенный выход (RC-1/SS-07): без таймера повтора — тесты вызывают `deliver()` сами.
        pendingLogoutServiceProvider.overrideWith(
          (ref) => PendingLogoutService(
            storage: ref.watch(secureStorageProvider),
            dio: () => ref.read(dioProvider),
            clock: ref.watch(clockProvider),
            autoRetry: pendingLogoutAutoRetry,
          ),
        ),
        ...overrides,
      ],
    );
  }

  late final InMemorySecureStorage storage;
  late final TokenStore tokens;
  late final FakeAdapter adapter;
  late final FixedClock clock;
  late final AppVersionController appVersionController;
  late final Dio dio;
  late final ProviderContainer container;
  AppDatabase? db;
  final List<SessionEvent> events = <SessionEvent>[];

  SessionController get controller => container.read(sessionControllerProvider.notifier);
  SessionState get state => container.read(sessionControllerProvider);
  PendingLogoutService get pendingLogout => container.read(pendingLogoutServiceProvider);

  /// Создать контроллер (подключает хуки к AuthInterceptor).
  SessionController start() {
    container.read(sessionControllerProvider);
    return controller;
  }

  bool _disposed = false;

  /// Освободить контейнер (таймеры контроллера) и БД; повторный вызов — без действия.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
    await db?.close();
  }
}

/// Дождаться выполнения микрозадач/цепочки интерсепторов.
Future<void> settle([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Ждать (реальное время, до [timeout]), пока [condition] не станет истинным.
Future<void> until(bool Function() condition, {Duration timeout = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('условие не выполнилось за $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<DioException> fails(Future<Object?> call) async {
  try {
    await call;
  } on DioException catch (e) {
    return e;
  }
  throw StateError('ожидалась DioException');
}

// Обвязка тестов жизненного цикла планшета магазина (13 TAB-2-10; ADR-115): технический пользователь `kind=kiosk`,
// признак планшета в in-memory secure storage, фейковый порт закрепления, быстрый хэш аварийного кода (мало итераций —
// параметры по умолчанию проверяет emergency_exit_test.dart) и роутер с настоящими guard-ами режима.
// Данные тестовые: id — UUID-заглушки, номеров телефонов и имён людей нет.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/kiosk_routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/hardware/kiosk_lock.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/kiosk_exit_code_hash.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';

import '../../core/session/session_harness.dart';

export '../../core/session/session_harness.dart';

/// Технический пользователь планшета (`sub`) и запись `store_tablets` — тестовые UUID.
const String kioskUserId = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4fa1';
const String kioskTabletId = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4fb1';
const String kioskTabletName = 'Планшет у входа';

/// Аварийный код теста (8 цифр) и неверный код.
const String kioskExitCode = '24681357';
const String wrongExitCode = '11112222';

/// Итераций PBKDF2 в тестах (в приложении — 210 000, `KioskExitCodeStore.defaultIterations`).
const int testExitIterations = 16;

/// Access JWT планшета.
String kioskJwt({String tag = 'k', DateTime? exp}) => fakeJwt(kind: 'kiosk', sub: kioskUserId, tag: tag, exp: exp);

/// Признак планшета в secure storage (как после подключения, FLOW-043.S6).
void writeKioskMarker(Map<SecureKey, String> storage) {
  storage[SecureKey.kioskTabletId] = kioskTabletId;
  storage[SecureKey.kioskTabletName] = kioskTabletName;
  storage[SecureKey.kioskUserId] = kioskUserId;
}

/// Порт закрепления: запоминает вызовы; [locked] — снимок `status` с полным закреплением (`X-Kiosk-Lock: on`).
final class FakeKioskLock implements KioskLock {
  FakeKioskLock({this.locked = false});

  bool locked;
  final List<String> calls = <String>[];

  KioskLockStatus get _snapshot => locked
      ? KioskLockStatus(
          supported: true,
          deviceOwner: true,
          lockTaskActive: true,
          homeApp: true,
          activeRestrictions: kioskLockPolicy.userRestrictions.toSet(),
          lockTaskFeatures: const <String>{},
        )
      : KioskLockStatus.unsupported;

  int count(String method) => calls.where((String c) => c == method).length;

  @override
  Future<KioskLockStatus> status() async {
    calls.add('status');
    return _snapshot;
  }

  @override
  Future<KioskLockStatus> enable() async {
    calls.add('enable');
    locked = true;
    return _snapshot;
  }

  @override
  Future<KioskLockStatus> disable() async {
    calls.add('disable');
    locked = false;
    return _snapshot;
  }
}

/// Хранилище аварийного кода с малым числом итераций и вычислением в текущем изоляте.
KioskExitCodeStore fastExitStore(Ref ref) => KioskExitCodeStore(
  storage: ref.watch(secureStorageProvider),
  clock: ref.watch(clockProvider),
  iterations: testExitIterations,
  runner: deriveKioskExitHashNow,
);

/// Переопределения режима планшета для [SessionHarness]: порт закрепления, быстрый хэш, без автообновления настроек.
List<Override> kioskOverrides(FakeKioskLock lock, {bool autoRefreshSettings = false}) => <Override>[
  kioskLockProvider.overrideWithValue(lock),
  kioskExitCodeStoreProvider.overrideWith(fastExitStore),
  publicSettingsAutoRefreshProvider.overrideWithValue(autoRefreshSettings),
];

/// Обвязка сессии планшета: признак в хранилище ([marked]), refresh ([refresh]), access ([access]); [biometrics] —
/// порт биометрии core (T-BIO-033: подменный со счётчиком вызовов).
SessionHarness kioskHarness(
  FakeHandler handler, {
  required FakeKioskLock lock,
  bool marked = true,
  String? refresh = 'rk1',
  String? access,
  List<Override> overrides = const <Override>[],
  bool autoRefreshSettings = false,
  BiometricAuthenticator biometrics = const NoBiometricAuthenticator(),
}) {
  final SessionHarness h = SessionHarness(
    handler,
    refresh: refresh,
    access: access,
    biometrics: biometrics,
    overrides: <Override>[
      ...kioskOverrides(lock, autoRefreshSettings: autoRefreshSettings),
      ...overrides,
    ],
  );
  if (marked) writeKioskMarker(h.storage.values);
  return h;
}

/// Записать хэш [kioskExitCode] (как `establishKiosk` при подключении).
Future<void> rememberExitCode(SessionHarness h) =>
    h.container.read(kioskExitCodeStoreProvider).remember(code: kioskExitCode, tabletId: kioskTabletId);

/// Ответ `GET /settings/public` с `features.storeTablet`.
Map<String, Object?> publicSettingsBody({bool storeTablet = true, bool customerSelfService = true}) =>
    <String, Object?>{
      'features': <String, Object?>{'storeTablet': storeTablet, 'customerSelfService': customerSelfService},
      'kiosk': <String, Object?>{'idleSeconds': 120, 'idleWarningSeconds': 15, 'doneSeconds': 60},
    };

/// Роутер с настоящими guard-ами (`guardRedirect`: G-0, G-0a, G-1, G-15) над контейнером [SessionHarness]: маршруты
/// режима планшета и заглушки SCR-00 / SCR-01.
GoRouter kioskGuardRouter(ProviderContainer container, {String initialLocation = '/splash'}) {
  final ValueNotifier<int> refresh = ValueNotifier<int>(0);
  container
    ..listen<AsyncValue<SessionStatus>>(sessionStatusProvider, (_, _) => refresh.value++)
    ..listen<bool>(kioskRouteHoldProvider, (_, _) => refresh.value++)
    ..listen<AppMode>(kioskTestModeProvider, (_, _) => refresh.value++);
  GuardInputs inputs() => (
    status: container.read(sessionStatusProvider).value ?? SessionStatus.unknown,
    mode: container.read(kioskTestModeProvider),
    customerSelfService: true,
    role: null,
    endReason: container.read(sessionEndReasonProvider),
    lock: container.read(sessionLockProvider),
    cameraSupported: true,
  );
  final GoRouter router = GoRouter(
    initialLocation: initialLocation,
    refreshListenable: refresh,
    routes: <RouteBase>[
      GoRoute(path: '/splash', builder: (_, _) => const _Page('splash')),
      GoRoute(path: '/auth/phone', builder: (_, GoRouterState s) => _Page('phone ${s.uri.query}')),
      GoRoute(path: '/catalog', builder: (_, _) => const _Page('catalog')),
      ...kioskRoutes(),
    ],
    redirect: (BuildContext context, GoRouterState state) =>
        guardRedirect(context, state, inputs(), kioskHold: container.read(kioskRouteHoldProvider)),
  );
  return router;
}

/// Режим оболочки по сессии (как `appModeProvider` без профиля входа фичи auth).
final kioskTestModeProvider = Provider<AppMode>(
  (ref) => appModeFor(kind: ref.watch(sessionControllerProvider.select((s) => s.userKind))),
);

/// Приложение теста: роутер, тема и локаль ru.
Widget kioskTestApp(ProviderContainer container, GoRouter router) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    routerConfig: router,
    theme: AppTheme.light(),
    locale: const Locale('ru'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    debugShowCheckedModeBanner: false,
    builder: (BuildContext context, Widget? child) =>
        MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
  ),
);

class _Page extends StatelessWidget {
  const _Page(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: Text(name, key: ValueKey<String>('page-$name'))),
  );
}

/// Ключ заглушки страницы [name] (`splash`, `phone <query>`, `catalog`).
Key pageKey(String name) => ValueKey<String>('page-$name');

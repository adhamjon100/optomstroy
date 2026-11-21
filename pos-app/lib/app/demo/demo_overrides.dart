// Переопределения веб-демо (15 ADR-113 п. 1, уточнён ADR-116 п. 1; 06 §6.10): `bootstrap(overrides:
// demoOverrides(bridge))` применяет их после `appOverrides`. Четыре провайдера — три из `core/di/core_providers.dart` и
// порт биометрии `biometricAuthenticatorProvider` (`core/biometrics/biometric_providers.dart`), и ни одного из них нет в
// `appOverrides` (двойное переопределение Riverpod падает в debug — проверяет test/app/demo/demo_root_wiring_test.dart):
// - `appConfigProvider` — константы сборки `env/web_demo.json`, но `API_BASE_URL` = `<origin сайта>/api/v1`: фото
//   `/images/...` и адреса превью берутся с того же сайта без пересборки под адрес Netlify; `ENV_BANNER=false` — без
//   полосы «DEV · TEST DATA» (решение владельца, 15 ADR-114 п. 9 (5); пометку тестовых данных несут вкладка и панель
//   «ДЕМО»), в dev-сборках Windows и Android полоса остаётся;
// - `httpClientAdapterProvider` — мост к серверу в Web Worker ([DemoBridgeAdapter]); его получают основной Dio и Dio для
//   refresh, поэтому интерсепторы, refresh, step-up, ETag, повторы и разбор DTO остаются настоящими;
// - `backendHealthProbeProvider` — `/health` через тот же адаптер ([DemoHealthProbe]);
// - `biometricAuthenticatorProvider` — вход по лицу или отпечатку через passkey страницы ([WebPasskeyAuthenticator];
//   ADR-116 п. 1, п. 4): режим — по платформе устройства браузера, запись привязки — пользователя из кэша профиля.
//   Продукт web (`lib/main.dart`) остаётся без биометрии (`NoBiometricAuthenticator`, DM-01).
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/app/demo/demo_bridge.dart';
import 'package:optomstroy/app/demo/demo_bridge_adapter.dart';
import 'package:optomstroy/app/demo/demo_health_probe.dart';
import 'package:optomstroy/app/demo/demo_passkey.dart';
import 'package:optomstroy/app/demo/demo_passkey_gateway.dart';
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

/// Константы сборки (`--dart-define-from-file=env/web_demo.json`), которые читает `AppConfig`; `API_BASE_URL` задаётся
/// во время работы, `APP_DATA_DIR` в веб-демо не используется.
const Map<String, String> demoBuildConstants = <String, String>{
  'ENV': String.fromEnvironment('ENV'),
  'ENVIRONMENT': String.fromEnvironment('ENVIRONMENT'),
  'LOG_LEVEL': String.fromEnvironment('LOG_LEVEL'),
  'FEATURE_FLAGS': String.fromEnvironment('FEATURE_FLAGS'),
  'FEATURE_FACE_SCAN': String.fromEnvironment('FEATURE_FACE_SCAN'),
  'FEATURE_CUSTOMER_SELF_SERVICE': String.fromEnvironment('FEATURE_CUSTOMER_SELF_SERVICE'),
};

/// Конфигурация веб-демо: [constants] сборки, `API_BASE_URL` = `[origin]/api/v1` и `ENV_BANNER=false` (без полосы
/// `EnvBanner`, 15 ADR-114 п. 9 (5)).
AppConfig demoAppConfig(String origin, {Map<String, String> constants = demoBuildConstants}) =>
    AppConfig.fromMap(<String, String>{...constants, 'API_BASE_URL': '$origin/api/v1', 'ENV_BANNER': 'false'});

/// Четыре переопределения веб-демо поверх [bridge]; [origin] — origin сайта (по умолчанию — от моста); [passkey] — шлюз
/// passkey страницы (по умолчанию — `globalThis.__posPasskey`, на VM — заглушка без страницы).
List<Override> demoOverrides(
  DemoBridge bridge, {
  String? origin,
  Map<String, String> constants = demoBuildConstants,
  DemoPasskeyGateway? passkey,
}) {
  final String site = origin ?? bridge.origin;
  // Один адаптер на основной Dio, Dio для refresh и `/health`: таймаут соединения учитывает их общую очередь.
  final DemoBridgeAdapter adapter = DemoBridgeAdapter(bridge, origin: site);
  final DemoPasskeyGateway gateway = passkey ?? createDemoPasskeyGateway();
  return <Override>[
    appConfigProvider.overrideWith((Ref ref) => demoAppConfig(site, constants: constants)),
    httpClientAdapterProvider.overrideWithValue(adapter),
    backendHealthProbeProvider.overrideWith((Ref ref) {
      final DemoHealthProbe probe = DemoHealthProbe(ref.watch(appConfigProvider), adapter);
      ref.onDispose(probe.close);
      return probe;
    }),
    biometricAuthenticatorProvider.overrideWith((Ref ref) => demoBiometricAuthenticator(ref, gateway)),
  ];
}

/// Порт биометрии веб-демо (15 ADR-116 п. 1): режим — по ОС браузера из метаданных клиента ([demoPasskeyModeFor];
/// без метаданных — по `defaultTargetPlatform`, из которого их и собирает `ClientMeta.load`), запись привязки —
/// `userId` кэша профиля (02 §0.4).
WebPasskeyAuthenticator demoBiometricAuthenticator(Ref ref, DemoPasskeyGateway gateway) {
  final SecureStorage storage = ref.watch(secureStorageProvider);
  return WebPasskeyAuthenticator(
    gateway: gateway,
    mode: demoPasskeyModeFor(_browserOs(ref)),
    owner: () async => (await ProfileCacheStore(storage).read())?.userId,
  );
}

ClientPlatform? _browserOs(Ref ref) {
  try {
    return ref.watch(clientMetaProvider).platform;
  } on Object {
    // bootstrap не прочитал метаданные клиента (сбой хранилища, виджет-тесты): та же ОС браузера, что в `ClientMeta.load`.
    return ClientPlatform.of(defaultTargetPlatform);
  }
}

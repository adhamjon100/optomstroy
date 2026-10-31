// Переопределения веб-демо (15 ADR-113 п. 1; 06 §6.10): `bootstrap(overrides: demoOverrides(bridge))` применяет их
// после `appOverrides`. Ровно три провайдера `core/di/core_providers.dart`, и ни одного из них нет в `appOverrides`
// (двойное переопределение Riverpod падает в debug — проверяет test/app/demo/demo_root_wiring_test.dart):
// - `appConfigProvider` — константы сборки `env/web_demo.json`, но `API_BASE_URL` = `<origin сайта>/api/v1`: фото
//   `/images/...` и адреса превью берутся с того же сайта без пересборки под адрес Netlify;
// - `httpClientAdapterProvider` — мост к серверу в Web Worker ([DemoBridgeAdapter]); его получают основной Dio и Dio для
//   refresh, поэтому интерсепторы, refresh, step-up, ETag, повторы и разбор DTO остаются настоящими;
// - `backendHealthProbeProvider` — `/health` через тот же адаптер ([DemoHealthProbe]).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/app/demo/demo_bridge.dart';
import 'package:optomstroy/app/demo/demo_bridge_adapter.dart';
import 'package:optomstroy/app/demo/demo_health_probe.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/di/core_providers.dart';

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

/// Конфигурация веб-демо: [constants] сборки и `API_BASE_URL` = `[origin]/api/v1`.
AppConfig demoAppConfig(String origin, {Map<String, String> constants = demoBuildConstants}) =>
    AppConfig.fromMap(<String, String>{...constants, 'API_BASE_URL': '$origin/api/v1'});

/// Три переопределения веб-демо поверх [bridge]; [origin] — origin сайта (по умолчанию — от моста).
List<Override> demoOverrides(DemoBridge bridge, {String? origin, Map<String, String> constants = demoBuildConstants}) {
  final String site = origin ?? bridge.origin;
  // Один адаптер на основной Dio, Dio для refresh и `/health`: таймаут соединения учитывает их общую очередь.
  final DemoBridgeAdapter adapter = DemoBridgeAdapter(bridge, origin: site);
  return <Override>[
    appConfigProvider.overrideWith((Ref ref) => demoAppConfig(site, constants: constants)),
    httpClientAdapterProvider.overrideWithValue(adapter),
    backendHealthProbeProvider.overrideWith((Ref ref) {
      final DemoHealthProbe probe = DemoHealthProbe(ref.watch(appConfigProvider), adapter);
      ref.onDispose(probe.close);
      return probe;
    }),
  ];
}

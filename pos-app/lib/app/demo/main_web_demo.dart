// Точка входа веб-демо «Оптомстрой POS» (15 ADR-113 п. 1; 06 §6.10) — только для показа заказчику, не релизная сборка:
//   flutter build web -t lib/app/demo/main_web_demo.dart --dart-define-from-file=env/web_demo.json
// Страница сайта (demo/web/site-src) до загрузки Flutter создаёт мост `globalThis.__posDemo` и запускает сервер —
// скомпилированный pos-api — в module Web Worker. Приложение то же, что `lib/main.dart`: тот же `bootstrap`, а
// `demoOverrides` меняют только транспорт Dio, `/health` и `API_BASE_URL`.
//
// `lib/main.dart` этот файл не импортирует (DM-01, scripts/check_layers.py), поэтому в сборки Windows и Android демо-код
// не попадает.
//
// Ошибки запуска должны дойти до страницы. Загрузчик Flutter web вызывает `main()` как `VoidCallback` и его Future не
// ждёт, поэтому:
// - проверки сборки и моста идут синхронно, до первого `await`: исключение отклоняет `appRunner.runApp()` в
//   web/flutter_bootstrap.js, и экран загрузки показывает ошибку с кнопками «Обновить страницу» и «Сбросить демо»;
// - ошибку после первого `await` (до `runApp`) [runWebDemo] сам передаёт странице (`reportDemoStartError`).
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show BrowserContextMenu, MissingPluginException, PlatformException;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:logging/logging.dart';
import 'package:optomstroy/app/bootstrap.dart';
import 'package:optomstroy/app/demo/demo_bridge.dart';
import 'package:optomstroy/app/demo/demo_overrides.dart';
import 'package:optomstroy/core/config/environment.dart';

final Logger _log = Logger('demo');

/// Значение константы сборки `DEMO_BACKEND` для сервера в браузере.
const String demoBackendBrowser = 'browser';

/// Точка входа. Не `async`: [ensureDemoBuildLaunchAllowed] бросает синхронно, до первого `await`.
Future<void> main() {
  final DemoBridge bridge = createDemoBridge();
  ensureDemoBuildLaunchAllowed(bridge);
  return runWebDemo(bridge);
}

/// Проверки [ensureDemoLaunchAllowed] с константами этой сборки (`DEMO_BACKEND`, `ENV`/`ENVIRONMENT`).
void ensureDemoBuildLaunchAllowed(DemoBridge bridge) {
  // ENV, а без него ENVIRONMENT — как в `AppConfig.fromMap`.
  final String env = demoBuildConstants['ENV']!.trim();
  ensureDemoLaunchAllowed(
    demoBackend: const String.fromEnvironment('DEMO_BACKEND'),
    environment: env.isNotEmpty ? env : demoBuildConstants['ENVIRONMENT']!,
    bridge: bridge,
  );
}

/// Запуск веб-демо после проверок: меню браузера отключено → `bootstrap(overrides: demoOverrides)`.
///
/// Ошибка до `runApp` (например, `ClientMeta.load` или `bootstrap`) записывается в журнал и передаётся странице
/// [onStartError] (по умолчанию — экран загрузки, `reportDemoStartError`), иначе страница крутила бы «загружаем
/// приложение…» без текста и без кнопок. [start] подменяют тесты.
Future<void> runWebDemo(
  DemoBridge bridge, {
  Future<void> Function(DemoBridge bridge) start = _startDemoApp,
  void Function(Object error) onStartError = reportDemoStartError,
}) async {
  try {
    await start(bridge);
  } on Object catch (error, stackTrace) {
    _log.severe('веб-демо: запуск не удался', error, stackTrace);
    onStartError(error);
  }
}

Future<void> _startDemoApp(DemoBridge bridge) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _disableBrowserContextMenu();
  await bootstrap(overrides: demoOverrides(bridge));
}

/// Запуск разрешён только при `DEMO_BACKEND=browser`, `ENV` ≠ `prod` и мосте `globalThis.__posDemo` протокола
/// [demoBridgeProtocol]; иначе — [StateError] с понятным текстом (до `runApp`, в сеть ничего не уходит).
void ensureDemoLaunchAllowed({required String demoBackend, required String environment, required DemoBridge bridge}) {
  if (demoBackend.trim() != demoBackendBrowser) {
    throw StateError(
      'Веб-демо: main_web_demo.dart запускается только со сборкой DEMO_BACKEND=$demoBackendBrowser '
      '(--dart-define-from-file=env/web_demo.json); получено DEMO_BACKEND="$demoBackend".',
    );
  }
  final String envRaw = environment.trim().isEmpty ? AppEnvironment.dev.name : environment;
  final AppEnvironment? env = AppEnvironment.tryParse(envRaw);
  if (env == null) {
    throw StateError('Веб-демо: неизвестное значение ENV="$environment" (ожидается dev или staging).');
  }
  if (env == AppEnvironment.prod) {
    throw StateError(
      'Веб-демо: сборка с ENV=prod запрещена (15 ADR-113) — демо собирается только с ENV=dev или staging.',
    );
  }
  if (!bridge.isAvailable) {
    throw StateError(
      'Веб-демо: нет моста globalThis.__posDemo. Откройте страницу сайта демо (demo/web/site, demo-bridge.js), '
      'а не страницу сборки по умолчанию.',
    );
  }
  if (bridge.protocol != demoBridgeProtocol) {
    throw StateError(
      'Веб-демо: мост __posDemo.protocol=${bridge.protocol}, приложение ожидает $demoBridgeProtocol — '
      'страница и приложение из разных сборок.',
    );
  }
}

/// Меню браузера по правой кнопке перекрыло бы контекстные меню приложения (15 ADR-113 п. 1).
Future<void> _disableBrowserContextMenu() async {
  if (!kIsWeb) return;
  try {
    await BrowserContextMenu.disableContextMenu();
  } on PlatformException catch (e) {
    _log.warning('меню браузера не отключено: ${e.code}');
  } on MissingPluginException catch (e) {
    _log.warning('меню браузера не отключено: ${e.message}');
  }
}

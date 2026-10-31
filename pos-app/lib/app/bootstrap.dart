import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:logging/logging.dart';
import 'package:optomstroy/app/app.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/core/config/app_data_directory.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

final Logger _log = Logger('bootstrap');

/// Инициализация приложения (06 §6.10).
///
/// Порядок по 06: `ensureInitialized` → `AppConfig` → secure storage →
/// `AppDatabase` (миграции drift) → `SessionController.restore()` → `runApp`.
/// Этап C: метаданные клиента (`X-App-Version`, `X-Platform`, `X-Device-Id`) читаются
/// до `runApp` (`ClientMeta.load`, RM-C-004/RM-C-015); `AppDatabase.forUser` подключается
/// после входа (RM-D), восстановление сессии идёт на Splash через `sessionStatusProvider`.
/// [overrides] (тесты, integration_test) применяются последними.
/// dev/staging-сборка с `APP_DATA_DIR` переносит данные приложения (drift, secure storage, кэш) в этот каталог до
/// первого обращения к ним (`AppDataDirectory`, lib/core/config/app_data_directory.dart); в prod не действует.
Future<void> bootstrap({List<Override> overrides = const <Override>[]}) async {
  WidgetsFlutterBinding.ensureInitialized();
  _applyAppDataDirectory();
  final core = await _coreOverrides();
  runApp(ProviderScope(overrides: <Override>[...core, ...appOverrides, ...overrides], child: const App()));
}

/// `APP_DATA_DIR` (константа сборки). Неверная конфигурация здесь не роняет запуск: ту же [ConfigException]
/// покажет `appConfigProvider`.
void _applyAppDataDirectory() {
  try {
    if (AppDataDirectory.apply(AppConfig.fromEnvironment())) _log.info('APP_DATA_DIR: данные приложения перенесены');
  } on ConfigException catch (e) {
    _log.warning('APP_DATA_DIR: ${e.message}');
  }
}

/// Переопределения ядра, которым нужен асинхронный старт.
Future<List<Override>> _coreOverrides() => coreOverrides(() => ClientMeta.load(FlutterSecureStorageAdapter()));

/// Метаданные клиента [load] → `clientMetaProvider`.
///
/// Ошибка secure storage или package_info не роняет запуск: без `clientMetaProvider`
/// приложение доходит до Splash/«нет сессии», а запросы API с метаданными появятся на этапе D.
/// Только в браузере ([isWeb], веб-демо ADR-113) ещё два случая — запись в журнал, без белого экрана до `runApp`:
/// - вне secure context (http:// не на localhost) flutter_secure_storage_web бросает `UnsupportedError`;
/// - package_info_plus читает `version.json` по сети (package:http): сетевая ошибка (`http.ClientException`, любое
///   [Exception]) повторяется один раз.
/// В Windows и Android это не так: `UnsupportedError`, в том числе `UnimplementedError` незарегистрированного плагина
/// (он — подтип `UnsupportedError`), и прочие исключения пробрасываются, чтобы причина была видна, а не всплыла
/// позже у потребителей `clientMetaProvider`. `UnimplementedError` пробрасывается и в браузере.
@visibleForTesting
Future<List<Override>> coreOverrides(Future<ClientMeta> Function() load, {bool isWeb = kIsWeb}) async {
  for (var attempt = 1; ; attempt++) {
    try {
      final meta = await load();
      return <Override>[clientMetaProvider.overrideWithValue(meta)];
    } on PlatformException catch (e) {
      _log.warning('ClientMeta.load: ${e.code}');
    } on MissingPluginException catch (e) {
      _log.warning('ClientMeta.load: плагин недоступен (${e.runtimeType})');
    } on UnsupportedError catch (e) {
      if (!isWeb || e is UnimplementedError) rethrow;
      _log.warning('ClientMeta.load: не поддерживается в браузере (${e.message})');
    } on Exception catch (e) {
      if (!isWeb) rethrow;
      if (attempt < 2) {
        _log.info('ClientMeta.load: повтор после ошибки (${e.runtimeType})');
        continue;
      }
      _log.warning('ClientMeta.load: ${e.runtimeType} ($e)');
    }
    return const <Override>[];
  }
}

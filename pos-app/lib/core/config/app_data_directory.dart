// Каталог данных приложения для dev/staging-сборок (`APP_DATA_DIR`, lib/core/config/environment.dart).
//
// Зачем: integration_test и запуск на машине разработки пишут БД drift (`pos_<user_id>.db`, 07 §11.1), файл
// secure storage и кэш изображений в каталог ОС (Windows — `%APPDATA%\com.example\optomstroy` на C:). Сборка dev или
// staging с `--dart-define=APP_DATA_DIR=<абсолютный путь>` переносит их в указанный каталог: подменяется
// `PathProviderPlatform.instance`, поэтому `getApplicationSupportDirectory()` и др. возвращают подкаталоги
// APP_DATA_DIR для всех пользователей path_provider (drift_flutter, flutter_secure_storage_windows,
// flutter_cache_manager).
//
// Безопасность: путь — только константа сборки (`String.fromEnvironment`), не пользовательский ввод; в prod
// `AppConfig.appDataDir` всегда `null` и подмена не выполняется (test/core/config/app_data_directory_test.dart).
// В браузере (веб-демо, ADR-113) каталогов ОС нет (path_provider без web-реализации, dart:io `Directory` бросает
// UnsupportedError до `runApp`): подмена не выполняется никогда.
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:optomstroy/core/config/environment.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Подмена каталогов path_provider на подкаталоги [AppConfig.appDataDir].
abstract final class AppDataDirectory {
  /// Перенаправить каталоги приложения, если [config] задаёт `APP_DATA_DIR` (не prod). Повторный вызов с тем же
  /// каталогом (перезапуск приложения в integration_test) ничего не меняет. `true` — подмена действует.
  /// [isWeb] — сборка для браузера (тесты подставляют `true`): подмены нет.
  static bool apply(AppConfig config, {bool isWeb = kIsWeb}) {
    if (isWeb) return false;
    final String? root = config.isProd ? null : config.appDataDir;
    if (root == null) return false;
    final PathProviderPlatform current = PathProviderPlatform.instance;
    if (current is RedirectedPathProvider) {
      if (current.root == root) return true;
      PathProviderPlatform.instance = RedirectedPathProvider(root, current.delegate);
      return true;
    }
    PathProviderPlatform.instance = RedirectedPathProvider(root, current);
    return true;
  }
}

/// `PathProviderPlatform` с каталогами приложения внутри [root]; внешние каталоги и «Загрузки» — от [delegate].
final class RedirectedPathProvider extends PathProviderPlatform {
  RedirectedPathProvider(this.root, this.delegate);

  /// Абсолютный нормализованный каталог (`AppConfig.parseAppDataDir`).
  final String root;

  /// Исходная реализация платформы.
  final PathProviderPlatform delegate;

  /// Подкаталоги внутри [root].
  static const String support = 'support';
  static const String documents = 'documents';
  static const String cache = 'cache';
  static const String temporary = 'tmp';
  static const String library = 'library';

  Future<String> _dir(String name) async {
    final Directory dir = Directory(p.join(root, name));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getApplicationSupportPath() => _dir(support);

  @override
  Future<String?> getApplicationDocumentsPath() => _dir(documents);

  @override
  Future<String?> getApplicationCachePath() => _dir(cache);

  @override
  Future<String?> getTemporaryPath() => _dir(temporary);

  @override
  Future<String?> getLibraryPath() => _dir(library);

  @override
  Future<String?> getDownloadsPath() => delegate.getDownloadsPath();

  @override
  Future<String?> getExternalStoragePath() => delegate.getExternalStoragePath();

  @override
  Future<List<String>?> getExternalCachePaths() => delegate.getExternalCachePaths();

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      delegate.getExternalStoragePaths(type: type);
}
